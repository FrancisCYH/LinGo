#!/usr/bin/env python3
"""Directed AXI audit of default RTL. FAIL results are findings, not xfails.

python3 hardware/audit_axi.py [RTL.v]
Requires iverilog/vvp. Writes hardware/axi_audit_results.json.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def simulate(rtl, module, body):
    header = re.search(rf"module {module}\((.*?)\);", rtl.read_text(), re.S)[1]
    header = re.sub(r"//[^\n]*", "", header)
    ports = re.findall(r"(input|output)\s*(\[[^\]]+\])?\s*(\w+)\s*[,\n]", header)
    declarations = [f"{'reg' if d == 'input' else 'wire'} {w} {n}"
                    + (" = 0;" if d == 'input' else ";") for d, w, n in ports]
    tb = ("module tb;\n" + "\n".join(declarations) + "\n" + module + " dut("
          + ",".join(f".{n}({n})" for _, _, n in ports) + ");\n"
          + 'initial begin #5000000; $fatal(1, "timeout"); end\n'
          + body + "\nendmodule\n")
    with tempfile.TemporaryDirectory() as tmp:
        source, binary = Path(tmp) / "tb.sv", Path(tmp) / "tb"
        source.write_text(tb)
        result = subprocess.run(["iverilog", "-g2012", "-s", "tb", "-o", str(binary),
                                 str(rtl), str(source)], capture_output=True, text=True)
        if result.returncode:
            return {"status": "COMPILE_ERROR", "output": result.stderr}
        result = subprocess.run(["vvp", str(binary)], capture_output=True, text=True)
        return {"status": "PASS" if result.returncode == 0 else "FAIL",
                "output": result.stdout.strip() + result.stderr.strip()}


SPM_COMMON = r'''
always #5 clock = ~clock;
always @* io_aclk = clock;
task tick; begin @(posedge clock); #1; @(negedge clock); end endtask
function [7:0] byte_value(input integer address);
  byte_value = ((address * 7) ^ (address >> 5) ^ 'h5a) & 255;
endfunction
function [127:0] word_value(input integer address);
  integer k;
  begin for(k=0;k<16;k=k+1) word_value[k*8+:8] = byte_value(address+k); end
endfunction
task initialize;
  integer i;
  begin
    tick; io_aresetn = 1;
    // Initialize banks 0 and 1 through independent B ports.
    io_srams_0_en = 1; io_srams_0_we = 15;
    io_srams_1_en = 1; io_srams_1_we = 15;
    for(i=0;i<1024;i=i+1) begin
      io_srams_0_addr = i; io_srams_0_din = word_value(i*4);
      io_srams_1_addr = i; io_srams_1_din = word_value('h1000+i*4);
      tick;
    end
    io_srams_0_en = 0; io_srams_0_we = 0;
    io_srams_1_en = 0; io_srams_1_we = 0;
    // The top-level config B port is read-only and its write inputs are optimized out.
    aw('hc000,256,4,1);
    for(i=0;i<256;i=i+1) w(word_value('hc000+i*16),'1,i==255);
    b;
  end
endtask
task ar(input integer address, input integer length, input integer size, input integer burst);
  begin
    io_s_axi_ar_valid = 1; io_s_axi_ar_bits_addr = address;
    io_s_axi_ar_bits_len = length-1; io_s_axi_ar_bits_size = size;
    io_s_axi_ar_bits_burst = burst; io_s_axi_ar_bits_id = 'ha5;
    #1; if(!io_s_axi_ar_ready) $fatal(1,"AR not ready");
    tick; io_s_axi_ar_valid = 0;
  end
endtask
task aw(input integer address, input integer length, input integer size, input integer burst);
  begin
    io_s_axi_aw_valid = 1; io_s_axi_aw_bits_addr = address;
    io_s_axi_aw_bits_len = length-1; io_s_axi_aw_bits_size = size;
    io_s_axi_aw_bits_burst = burst; io_s_axi_aw_bits_id = 'h5a;
    #1; if(!io_s_axi_aw_ready) $fatal(1,"AW not ready");
    tick; io_s_axi_aw_valid = 0;
  end
endtask
task w(input [127:0] value, input [15:0] mask, input last);
  begin
    io_s_axi_w_valid = 1; io_s_axi_w_bits_data = value;
    io_s_axi_w_bits_strb = mask; io_s_axi_w_bits_last = last;
    #1; if(!io_s_axi_w_ready) $fatal(1,"W not ready");
    tick; io_s_axi_w_valid = 0;
  end
endtask
task b;
  begin
    #1; if(!io_s_axi_b_valid || io_s_axi_b_bits_id !== 'h5a) $fatal(1,"B response");
    repeat(3) begin
      tick;
      if(!io_s_axi_b_valid || io_s_axi_b_bits_id !== 'h5a) $fatal(1,"B unstable");
    end
    io_s_axi_b_ready = 1; tick; io_s_axi_b_ready = 0;
  end
endtask
function integer next_address(input integer address, input integer length,
                             input integer size, input integer burst);
  integer n, bound;
  begin
    n = ((address >> size)+1) << size;
    bound = (address / (length * (1 << size))) * length * (1 << size);
    if(burst == 0) next_address = address;
    else if(burst == 2 && n == bound+length*(1<<size)) next_address = bound;
    else next_address = n;
  end
endfunction
task wait_r;
  integer cycles;
  begin
    cycles=0;
    #1;
    while(!io_s_axi_r_valid && cycles<32) begin tick; #1; cycles=cycles+1; end
    if(!io_s_axi_r_valid) $fatal(1,"read response timeout");
  end
endtask
task check_r(input integer address, input integer size, input last);
  integer lane, lo, hi;
  reg [127:0] expected;
  begin
    // AXI specifies handshakes, not a fixed SRAM-to-R response latency.
    wait_r;
    if(!io_s_axi_r_valid || io_s_axi_r_bits_last !== last || io_s_axi_r_bits_id !== 'ha5)
      $fatal(1,"R metadata addr=%h valid=%b last=%b expected_last=%b id=%h",
             address,io_s_axi_r_valid,io_s_axi_r_bits_last,last,io_s_axi_r_bits_id);
    expected = word_value(address & ~15);
    lo = address & 15; hi = (((address >> size)+1)<<size) - (address & ~15);
    for(lane=lo;lane<hi;lane=lane+1)
      if(io_s_axi_r_bits_data[lane*8+:8] !== expected[lane*8+:8])
        $fatal(1,"R data addr=%h lane=%0d got=%h expected=%h",address,lane,
               io_s_axi_r_bits_data,expected);
  end
endtask
'''


READ_MATRIX = r'''
reg [31:0] seed = 32'h19adbeef;
task read_burst(input integer address, input integer length, input integer size,
                input integer burst, input integer stalls);
  integer beat, current, cycles;
  reg held;
  reg started;
  reg [127:0] held_data;
  reg held_last;
  begin
    io_s_axi_r_ready = 0; ar(address,length,size,burst);
    beat = 0; current = address; cycles = 0; held = 0; started = 0;
    while(beat<length && cycles<length*20+20) begin
      seed = {seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
      io_s_axi_r_ready = stalls ? seed[0] && seed[2] : 1;
      #1;
      if(!stalls && started && !io_s_axi_r_valid)
        $fatal(1,"bubble in unstalled read burst");
      if(held && (!io_s_axi_r_valid || io_s_axi_r_bits_data !== held_data ||
                  io_s_axi_r_bits_last !== held_last)) $fatal(1,"R changed while stalled");
      held = io_s_axi_r_valid && !io_s_axi_r_ready;
      held_data = io_s_axi_r_bits_data; held_last = io_s_axi_r_bits_last;
      if(io_s_axi_r_valid) begin
        started = 1;
        check_r(current,size,beat==length-1);
        if(io_s_axi_r_ready) begin
          beat = beat+1; current = next_address(current,length,size,burst);
        end
      end
      tick; cycles = cycles+1;
    end
    if(beat != length) $fatal(1,"R missing beats");
    io_s_axi_r_ready = 0;
    #1; if(io_s_axi_r_valid) $fatal(1,"extra R beat");
  end
endtask
integer size, mode, bank, count;
initial begin
  initialize;
  count = 0;
  for(bank=0;bank<3;bank=bank+1)
    for(size=0;size<=4;size=size+1)
      for(mode=0;mode<2;mode=mode+1) begin
        read_burst((bank==2?'hc000:bank*'h1000)+'h100,1,size,1,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000)+'h100,16,size,0,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000)+'h100,17,size,1,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000),256,size,1,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000)+'h100+(1<<size),2,size,2,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000)+'h100+(3<<size),4,size,2,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000)+'h100+(7<<size),8,size,2,mode); count=count+1;
        read_burst((bank==2?'hc000:bank*'h1000)+'h100+(15<<size),16,size,2,mode); count=count+1;
        if(size>0) begin
          read_burst((bank==2?'hc000:bank*'h1000)+'h103,7,size,1,mode); count=count+1;
          read_burst((bank==2?'hc000:bank*'h1000)+'h103,7,size,0,mode); count=count+1;
        end
      end
  $display("PASS read matrix: %0d transactions",count); $finish;
end
'''


READ_STALL_CONFLICT = r'''
reg [127:0] saved;
initial begin
  initialize; aw('h300,1,4,1); ar('h100,4,4,1);
  tick; #1;
  check_r('h100,4,0); saved = io_s_axi_r_bits_data;
  w('h1234,'1,1);
  #1;
  if(!io_s_axi_r_valid || io_s_axi_r_bits_data !== saved)
    $fatal(1,"pending RVALID/data withdrawn by same-bank write under RREADY=0");
  $display("PASS pending read retained"); $finish;
end
'''


READ_RESUME_CONFLICT = r'''
initial begin
  initialize; aw('h300,1,4,1); ar('h100,4,4,1);
  tick; io_s_axi_r_ready = 1;
  check_r('h100,4,0);
  w('h1234,'1,1); // Accept first read while its SRAM prefetch is denied.
  io_s_axi_r_ready = 0; tick;
  #1; check_r('h110,4,0);
  io_s_axi_r_ready = 1; tick;
  #1; check_r('h120,4,0); tick;
  #1; check_r('h130,4,1); tick;
  $display("PASS read resumed after arbitration"); $finish;
end
'''


READ_AFTER_STALLED_CONFLICT = r'''
initial begin
  initialize; aw('h300,1,4,1); ar('h100,4,4,1);
  tick; check_r('h100,4,0);
  w('h1234,'1,1);
  // Allow the withdrawn response to reappear, then verify the remaining sequence.
  tick; #1; check_r('h100,4,0);
  io_s_axi_r_ready=1; tick;
  #1; check_r('h110,4,0); tick;
  #1; check_r('h120,4,0); tick;
  #1; check_r('h130,4,1); tick;
  $display("PASS no skipped beat after stalled arbitration"); $finish;
end
'''


CONFIG_VIRTUAL_CONFLICT = r'''
initial begin
  initialize; aw('hd300,1,4,1); ar('hc100,1,4,1);
  w('h11223344,'1,1);
  #1;
  if(io_s_axi_r_valid) check_r('hc100,4,1);
  else begin tick; #1; check_r('hc100,4,1); end
  $display("PASS shared config SRAM port arbitration"); $finish;
end
'''


BROADCAST_CONFLICT = r'''
initial begin
  initialize;
  io_bcast_en = 1; io_bcast_bank_mask = 2; io_bcast_base_addr_1 = 'h30;
  aw(0,1,4,1); ar('h1100,1,4,1);
  // SRAM read issuance and broadcast write coincide, to different addresses
  // within physical bank 1. The read must wait or return the initialized word.
  w('h11223344,'1,1);
  #1;
  if(io_s_axi_r_valid) check_r('h1100,4,1);
  else begin tick; #1; check_r('h1100,4,1); end
  $display("PASS broadcast read conflict"); $finish;
end
'''


OTHER_BANK_CONCURRENT = r'''
initial begin
  initialize; aw('h300,1,4,1); ar('h1100,1,4,1);
  w('h11223344,'1,1);
  #1; check_r('h1100,4,1);
  io_s_axi_r_ready=1; tick; io_s_axi_r_ready=0;
  b;
  $display("PASS concurrent read/write to distinct physical banks"); $finish;
end
'''


INVALID_ADDRESS = r'''
initial begin
  initialize;
  aw('he100,1,4,1); w('h1234,'1,1);
  #1; if(!io_s_axi_b_valid) $fatal(1,"missing invalid-address response");
  $display("OBSERVED unmapped write acknowledged BID=%h; inspect constant BRESP=OKAY in source",
           io_s_axi_b_bits_id);
  b;
  ar('he100,1,4,1); wait_r;
  #1; if(!io_s_axi_r_valid) $fatal(1,"missing invalid-address read response");
  $display("OBSERVED unmapped read data=%h; inspect constant RRESP=OKAY in source",
           io_s_axi_r_bits_data);
  $finish;
end
'''


WRITE_MATRIX = r'''
reg [7:0] model [0:65535];
reg [31:0] random_state = 32'h55f01234;
task verify_word(input integer address);
  integer k, part;
  reg [127:0] expected;
  begin
    for(k=0;k<16;k=k+1) expected[k*8+:8] = model[(address&~15)+k];
    if(address >= 'hc000) begin
      io_sram_last_en = 1; io_sram_last_addr = (address-'hc000)>>4;
      tick;
      if(io_sram_last_dout !== expected) $fatal(1,"config write mismatch addr=%h",address);
      io_sram_last_en = 0;
    end else begin
      for(part=0;part<4;part=part+1) begin
        if(address < 'h1000) begin
          io_srams_0_en=1; io_srams_0_addr=(address>>2)+part;
        end else begin
          io_srams_1_en=1; io_srams_1_addr=((address-'h1000)>>2)+part;
        end
        tick;
        if((address<'h1000 ? io_srams_0_dout : io_srams_1_dout) !== expected[part*32+:32])
          $fatal(1,"write mismatch addr=%h part=%0d",address,part);
      end
      io_srams_0_en=0; io_srams_1_en=0;
    end
  end
endtask
task write_burst(input integer address, input integer length, input integer size,
                 input integer burst, input integer order);
  integer current, beat, lane, lo, hi, i, start, limit;
  reg [15:0] mask;
  reg [127:0] value;
  begin
    current=address;
    // Early WVALID is held until AW is sent and the slave accepts W.
    if(order>0) begin
      for(lane=0;lane<16;lane=lane+1) value[lane*8+:8] = (address+lane*17)&255;
      lo=current&15; hi=(((current>>size)+1)<<size)-(current&~15);
      mask=0; for(lane=lo;lane<hi;lane=lane+1) mask[lane]=1;
      io_s_axi_w_valid=1; io_s_axi_w_bits_data=value; io_s_axi_w_bits_strb=mask;
      io_s_axi_w_bits_last=length==1;
      if(order==1) repeat(3) begin
        #1; if(io_s_axi_w_ready) $fatal(1,"early W accepted without address"); tick;
      end
    end
    aw(address,length,size,burst);
    for(beat=0;beat<length;beat=beat+1) begin
      if(beat>0 || order==0) begin
        io_s_axi_w_valid=0; io_s_axi_w_bits_data='hdead; io_s_axi_w_bits_strb='1;
        repeat(beat%3) tick;
        for(lane=0;lane<16;lane=lane+1) value[lane*8+:8] = (address+beat*13+lane*17)&255;
        lo=current&15; hi=(((current>>size)+1)<<size)-(current&~15);
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        mask=0;
        for(lane=lo;lane<hi;lane=lane+1) mask[lane] = (beat%4==0) ? 0 : random_state[lane];
      end
      for(lane=0;lane<16;lane=lane+1)
        if(mask[lane]) model[(current&~15)+lane]=value[lane*8+:8];
      w(value,mask,beat==length-1);
      current=next_address(current,length,size,burst);
    end
    b;
    // Verify the touched region including all bytes disabled by WSTRB.
    start=(burst==2 ? (address/(length*(1<<size)))*length*(1<<size) : address)&~15;
    limit=(burst==0 ? (address&~15)+16 : start+length*(1<<size)+16);
    if(limit>((address&~4095)+4096)) limit=(address&~4095)+4096;
    for(i=start;i<limit;i=i+16) verify_word(i);
  end
endtask
integer bank,size,order,i,count;
initial begin
  for(i=0;i<65536;i=i+1) model[i]=byte_value(i);
  initialize; count=0;
  for(bank=0;bank<3;bank=bank+1)
    for(size=0;size<=4;size=size+1)
      for(order=0;order<3;order=order+1) begin
        write_burst((bank==2?'hc000:bank*'h1000)+'h100,1,size,1,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000)+'h103,7,size,1,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000)+'h103,16,size,0,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000),256,size,1,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000)+'h100+(1<<size),2,size,2,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000)+'h100+(3<<size),4,size,2,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000)+'h100+(7<<size),8,size,2,order); count=count+1;
        write_burst((bank==2?'hc000:bank*'h1000)+'h100+(15<<size),16,size,2,order); count=count+1;
      end
  $display("PASS write matrix: %0d transactions",count); $finish;
end
'''


AXI_RESET = r'''
initial begin
  initialize;
  ar('h100,1,4,1); wait_r;
  if(!io_s_axi_r_valid) $fatal(1,"read not pending");
  aw('h200,1,4,1); w('h1234,'1,1);
  io_aresetn=0; tick;
  if(io_s_axi_r_valid || io_s_axi_b_valid) $fatal(1,"reset did not clear response");
  io_aresetn=1; tick;
  if(io_s_axi_r_valid || io_s_axi_b_valid) $fatal(1,"stale response after reset");
  // Abort AW while waiting for W; the next transaction must start cleanly.
  aw('h300,1,4,1); io_aresetn=0; tick; io_aresetn=1; tick;
  aw('h400,1,4,1); w('h5678,'1,1); b;
  $display("PASS AXI response and AW-to-W reset abort"); $finish;
end
'''


LARGE_CONFIG_ACCESS = r'''
reg [127:0] value;
task read_value(input integer address, input [127:0] expected);
  begin
    ar(address,1,4,1); wait_r;
    if(io_s_axi_r_bits_data !== expected || !io_s_axi_r_bits_last)
      $fatal(1,"large config data/alias error addr=%h got=%h expected=%h",address,
             io_s_axi_r_bits_data,expected);
    io_s_axi_r_ready=1; tick; io_s_axi_r_ready=0;
  end
endtask
initial begin
  initialize;
  value=128'hfedcba98765432100123456789abcdef;
  aw('h10000,1,4,1); w(value,'1,1); b;
  read_value('h10000,value);
  // A high config address must not alias the low data bank after truncation.
  read_value(0,word_value(0));
  // Also verify the final config beat, including all high address-bank bits.
  aw(__LAST_CFG_ADDR__,1,4,1); w(~value,'1,1); b;
  read_value(__LAST_CFG_ADDR__,~value);
  $display("PASS high config addresses, final beat and no low-bank alias"); $finish;
end
'''


CONCURRENT_STRESS = READ_MATRIX[:READ_MATRIX.index("integer size, mode, bank, count;")] + r'''
integer read_done=0;
initial begin
  initialize;
  fork
    begin : reader
      integer i;
      for(i=0;i<90;i=i+1)
        read_burst((i%3==2?'hc000:(i%3)*'h1000)+'h100,16,4,1,1);
      read_done=1;
    end
    begin : writer
      integer i,j,base;
      for(i=0;i<90;i=i+1) begin
        // Different words within the read banks: collision is on the physical
        // port, not the memory address. Broadcast also exercises mask exclusions.
        io_bcast_en=(i%4==0);
        io_bcast_bank_mask=(i%8==0)?2:3;
        io_bcast_base_addr_0='h30; io_bcast_base_addr_1='h30;
        base=(i%3==2?'hc000:(i%3)*'h1000)+'h300;
        aw(base,8,4,1);
        repeat(i%3) tick;
        for(j=0;j<8;j=j+1) begin
          w('h12345678+i*8+j,'1,j==7);
          repeat(j%3) tick;
        end
        b;
      end
      io_bcast_en=0;
    end
  join
  if(!read_done) $fatal(1,"read stress did not finish");
  $display("PASS 90 read bursts with 90 ordinary/broadcast writes and random R backpressure");
  $finish;
end
'''


LITE = r'''
always #5 clock = ~clock;
task tick; begin @(posedge clock); #1; @(negedge clock); end endtask
integer cfg_pulses=0, exe_pulses=0, i;
always @(posedge clock) if(!reset) begin
  if(dut.cfgCtrl_io_start) cfg_pulses=cfg_pulses+1;
  if(dut.fgra_io_start) exe_pulses=exe_pulses+1;
end
task lite_write(input [6:0] address, input [31:0] value, input [3:0] mask,
                input integer order);
  begin
    io_s_axilite_aw_bits_addr = address;
    io_s_axilite_w_bits_data = value; io_s_axilite_w_bits_strb = mask;
    if(order==1) begin
      io_s_axilite_w_valid = 1;
      repeat(3) begin #1; if(io_s_axilite_w_ready || io_s_axilite_b_valid)
        $fatal(1,"W accepted before AW unexpectedly"); tick; end
    end
    io_s_axilite_aw_valid = 1;
    if(order==2) io_s_axilite_w_valid = 1;
    #1; if(!io_s_axilite_aw_ready) $fatal(1,"Lite AW not ready");
    tick; io_s_axilite_aw_valid = 0;
    if(order==0) repeat(3) begin tick; if(io_s_axilite_b_valid) $fatal(1,"phantom Lite B"); end
    io_s_axilite_w_valid = 1;
    #1; if(!io_s_axilite_w_ready) $fatal(1,"Lite W not ready");
    tick; io_s_axilite_w_valid = 0;
    if(!io_s_axilite_b_valid) $fatal(1,"Lite missing B");
    repeat(4) begin
      io_s_axilite_w_bits_data = 'hdeadbeef; io_s_axilite_aw_bits_addr = 'h20;
      tick; if(!io_s_axilite_b_valid || io_s_axilite_aw_ready || io_s_axilite_w_ready)
        $fatal(1,"Lite B not held / extra acceptance");
    end
    io_s_axilite_b_ready = 1; tick; io_s_axilite_b_ready = 0;
  end
endtask
task lite_read(input [6:0] address, input [31:0] expected);
  begin
    io_s_axilite_ar_valid = 1; io_s_axilite_ar_bits_addr = address;
    #1; if(!io_s_axilite_ar_ready) $fatal(1,"Lite AR not ready");
    tick; io_s_axilite_ar_valid = 0;
    repeat(4) begin
      if(!io_s_axilite_r_valid || io_s_axilite_r_bits_data !== expected)
        $fatal(1,"Lite R unstable/wrong: got=%h expected=%h",io_s_axilite_r_bits_data,expected);
      tick;
    end
    io_s_axilite_r_ready = 1; tick; io_s_axilite_r_ready = 0;
  end
endtask
initial begin
  reset = 1; tick; reset = 0;
  lite_write(0,'h11223344,15,0); lite_read(0,'h11223344);
  lite_write(0,'haabbccdd,5,1); lite_read(0,'h11bb33dd);
  lite_write(0,'h12345678,0,2); lite_read(0,'h11bb33dd);
  lite_write(0,'h55667788,15,2); lite_read(0,'h55667788);
  // A pending R response is a snapshot, even if a later write changes its CSR.
  io_s_axilite_ar_valid = 1; io_s_axilite_ar_bits_addr = 0;
  tick; io_s_axilite_ar_valid = 0;
  lite_write(0,'h87654321,15,0);
  if(!io_s_axilite_r_valid || io_s_axilite_r_bits_data !== 'h55667788)
    $fatal(1,"Lite R changed by concurrent write");
  io_s_axilite_r_ready = 1; tick; io_s_axilite_r_ready = 0;
  lite_read(0,'h87654321);
  // Exercise every writable CSR, including all per-bank broadcast bases.
  lite_write('h04,'h10203040,15,0); lite_read('h04,'h10203040);
  lite_write('h08,'h12345678,15,1); lite_read('h08,'h12345678);
  lite_write('h10,'h00000a55,15,2); lite_read('h10,'h00000a55);
  lite_write('h14,'h23456788,15,0); lite_read('h14,'h23456788);
  lite_write('h20,1,15,1); lite_read('h20,1);
  if(io_bcast_en !== 1) $fatal(1,"broadcast enable decode");
  lite_write('h24,'ha55af00f,15,2); lite_read('h24,'ha55af00f);
  if(io_bcast_bank_mask !== 'h00f) $fatal(1,"broadcast mask decode");
  for(i=0;i<12;i=i+1) begin
    lite_write('h28+i*4,'h01020304+i,15,i%3);
    lite_read('h28+i*4,'h01020304+i);
  end
  if(io_bcast_base_addr_0 !== 4 || io_bcast_base_addr_11 !== 15)
    $fatal(1,"broadcast base decode/truncation");
  lite_read('h0c,0); lite_read('h18,0); lite_read('h1c,1);
  lite_write('h1c,0,15,0); lite_read('h1c,1);
  lite_write('h7c,'h12345678,15,0); lite_read('h7c,0);
  // Command pulses require byte 0's strobe and data bit 0.
  lite_write('h04,0,15,0); lite_write('h08,1,15,0);
  lite_write('h10,0,15,0); lite_write('h14,1,15,0);
  lite_write('h0c,1,0,0); lite_write('h18,1,0,0);
  if(cfg_pulses || exe_pulses) $fatal(1,"command triggered with zero strobe");
  lite_write('h0c,1,1,0);
  if(cfg_pulses != 1) $fatal(1,"config pulse missing/duplicated");
  lite_write('h18,1,1,0);
  if(exe_pulses != 1) $fatal(1,"execution pulse missing/duplicated");
  // Abort a transaction with reset; no stale response may survive.
  io_s_axilite_aw_valid = 1; tick; io_s_axilite_aw_valid = 0;
  reset = 1; tick; reset = 0;
  if(io_s_axilite_b_valid || io_s_axilite_r_valid) $fatal(1,"Lite reset response");
  lite_read(0,0);
  $display("PASS AXI-Lite ordering, all default CSRs, strobes, command pulses, B/R backpressure, concurrent access, reset");
  $finish;
end
'''


if __name__ == "__main__":
    rtl = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).parent / "verilog/LinGoWithAXI.v"
    cases = {
        "read_matrix": ("AXI4Scratchpad", SPM_COMMON + READ_MATRIX),
        "write_matrix": ("AXI4Scratchpad", SPM_COMMON + WRITE_MATRIX),
        "read_stall_same_bank_write": ("AXI4Scratchpad", SPM_COMMON + READ_STALL_CONFLICT),
        "read_resume_same_bank_write": ("AXI4Scratchpad", SPM_COMMON + READ_RESUME_CONFLICT),
        "read_after_stalled_conflict": ("AXI4Scratchpad", SPM_COMMON + READ_AFTER_STALLED_CONFLICT),
        "broadcast_read_target_bank": ("AXI4Scratchpad", SPM_COMMON + BROADCAST_CONFLICT),
        "other_bank_concurrent": ("AXI4Scratchpad", SPM_COMMON + OTHER_BANK_CONCURRENT),
        "concurrent_read_write_stress": ("AXI4Scratchpad", SPM_COMMON + CONCURRENT_STRESS),
        "unmapped_address_behavior": ("AXI4Scratchpad", SPM_COMMON + INVALID_ADDRESS),
        "axi_reset": ("AXI4Scratchpad", SPM_COMMON + AXI_RESET),
        "axilite": ("LinGoController", LITE),
    }
    results = {}
    for name, (module, body) in cases.items():
        result = simulate(rtl, module, body)
        if name == "unmapped_address_behavior" and result["status"] == "PASS":
            result["status"] = "OBSERVED"
        results[name] = result
        print(f"{name}: {result['status']}\n{result['output']}", flush=True)
    multi_cfg = Path("/tmp/lingo-axi-audit-multicfg/AXI4Scratchpad.v")
    if multi_cfg.exists():
        result = simulate(multi_cfg, "AXI4Scratchpad", SPM_COMMON + CONFIG_VIRTUAL_CONFLICT)
        results["config_virtual_bank_conflict"] = result
        print(f"config_virtual_bank_conflict: {result['status']}\n{result['output']}", flush=True)
    else:
        results["config_virtual_bank_conflict"] = {
            "status": "NOT_RUN", "output": f"Generate required variant first: {multi_cfg}"
        }
    for name, path in [("large_config", "/tmp/lingo-axi-audit-largecfg/AXI4Scratchpad.v"),
                       ("128k_config", "/tmp/lingo-axi-audit-128kcfg/AXI4Scratchpad.v")]:
        large_cfg = Path(path)
        if not large_cfg.exists():
            results[name + "_address_width"] = {
                "status": "NOT_RUN", "output": f"Generate required variant first: {large_cfg}"
            }
            continue
        header = re.search(r"module AXI4Scratchpad\((.*?)\);", large_cfg.read_text(), re.S)[1]
        width = int(re.search(r"input\s*\[(\d+):0\]\s*io_s_axi_aw_bits_addr", header)[1])+1
        cfg_depth = int(re.search(r"input\s*\[(\d+):0\]\s*io_sram_last_addr", header)[1])+1
        expected = (12*4096 + (1 << (cfg_depth+4)) - 1).bit_length()
        results[name + "_address_width"] = {
            "status": "PASS" if width==expected else "FAIL",
            "output": f"Generated AXI address width {width}; capacity requires {expected} bits"
        }
        print(name + "_address_width: " + str(results[name + "_address_width"]), flush=True)
        final_address = 12*4096 + (1 << (cfg_depth+4)) - 16
        body = LARGE_CONFIG_ACCESS.replace("__LAST_CFG_ADDR__", str(final_address))
        result = simulate(large_cfg, "AXI4Scratchpad", SPM_COMMON + body)
        results[name + "_high_address_access"] = result
        print(f"{name}_high_address_access: {result['status']}\n{result['output']}", flush=True)
    output = Path(__file__).parent / "axi_audit_results.json"
    output.write_text(json.dumps(results, indent=2) + "\n")
    sys.exit(int(any(r["status"] in {"FAIL", "COMPILE_ERROR", "NOT_RUN"} for r in results.values())))
