#!/usr/bin/env python3
"""AXI write regression for default generated RTL (requires iverilog and vvp).

Generate standalone engine in hardware with:
  conda run -n lingo sbt 'Test/runMain fgramemfp.axi.WriteEngineVerilogGen'
Then run: python3 hardware/test_axi_write.py [path/to/RTL.v] [path/to/WriteEngine.v]
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def run(rtl, module, body):
    header = re.search(rf"module {module}\((.*?)\);", rtl.read_text(), re.S)[1]
    header = re.sub(r"//[^\n]*", "", header)
    ports = re.findall(r"(input|output)\s*(\[[^\]]+\])?\s*(\w+)\s*[,\n]", header)
    declarations = []
    connections = []
    for direction, width, name in ports:
        declarations.append(f"{'reg' if direction == 'input' else 'wire'} {width} {name}"
                            + (" = 0;" if direction == 'input' else ";"))
        connections.append(f".{name}({name})")
    tb = ("module tb;\n" + "\n".join(declarations) + "\n"
          + module + " dut(" + ",".join(connections) + ");\n"
          + "initial begin #10000; $fatal(1, \"timeout\"); end\n"
          + body + "\nendmodule\n")
    with tempfile.TemporaryDirectory() as tmp:
        source, binary = Path(tmp) / "tb.sv", Path(tmp) / "tb"
        source.write_text(tb)
        subprocess.run(["iverilog", "-g2012", "-s", "tb", "-o", str(binary),
                        str(rtl), str(source)], check=True)
        subprocess.run(["vvp", str(binary)], check=True)


ENGINE = r'''
always #5 aclk = ~aclk;
task tick; begin @(posedge aclk); #1; @(negedge aclk); end endtask
initial begin
  tick; aresetn = 1; ready = 1;
  s_axi_aw_valid = 1; s_axi_aw_bits_addr = 'h100;
  s_axi_aw_bits_len = 1; s_axi_aw_bits_size = 4; s_axi_aw_bits_burst = 1;
  s_axi_aw_bits_id = 7;
  tick; s_axi_aw_valid = 0;
  // Nonzero stale data, strobes, and LAST must be ignored during the AW-to-W gap.
  s_axi_w_bits_strb = '1; s_axi_w_bits_data = 'hdead; s_axi_w_bits_last = 1;
  repeat (3) begin
    #1; if (valid || s_axi_b_valid || addr !== 'h100) $fatal(1, "AW gap");
    tick;
  end
  s_axi_w_valid = 1; s_axi_w_bits_last = 0; ready = 0;
  repeat (3) begin
    #1; if (s_axi_w_ready || addr !== 'h100) $fatal(1, "backpressure");
    tick;
  end
  ready = 1; #1;
  if (!s_axi_w_ready || !valid) $fatal(1, "failed to resume");
  tick; s_axi_w_valid = 0;
  repeat (3) begin
    #1; if (valid || addr !== 'h110 || s_axi_b_valid) $fatal(1, "burst gap");
    tick;
  end
  s_axi_w_valid = 1; s_axi_w_bits_last = 1; ready = 0;
  tick;
  if (s_axi_b_valid || addr !== 'h110) $fatal(1, "unaccepted LAST");
  ready = 1; tick; s_axi_w_valid = 0;
  if (!s_axi_b_valid || s_axi_b_bits_id !== 7) $fatal(1, "missing response");
  repeat (2) begin tick; if (!s_axi_b_valid) $fatal(1, "response backpressure"); end
  s_axi_b_ready = 1; tick;
  if (!s_axi_aw_ready || valid) $fatal(1, "not idle");
  $display("PASS WriteEngine: gaps, backpressure, LAST and response"); $finish;
end
'''


SCRATCHPAD = r'''
always #5 clock = ~clock;
always @* io_aclk = clock;
task tick; begin @(posedge clock); #1; @(negedge clock); end endtask
task aw(input [15:0] address); begin
  io_s_axi_aw_valid = 1; io_s_axi_aw_bits_addr = address;
  io_s_axi_aw_bits_len = 1; io_s_axi_aw_bits_size = 4; io_s_axi_aw_bits_burst = 1;
  #1; if (!io_s_axi_aw_ready) $fatal(1, "AW not ready");
  tick; io_s_axi_aw_valid = 0;
end endtask
task beat(input [127:0] value, input last); begin
  io_s_axi_w_valid = 1; io_s_axi_w_bits_data = value; io_s_axi_w_bits_last = last;
  #1; if (!io_s_axi_w_ready) $fatal(1, "W not ready");
  tick; io_s_axi_w_valid = 0;
end endtask
task gap; begin
  io_s_axi_w_bits_data = 'hdead; io_s_axi_w_bits_last = 1;
  repeat (3) begin
    #1;
    if (!io_s_axi_w_ready || io_s_axi_b_valid) $fatal(1, "gap readiness/response");
    tick;
  end
end endtask
integer writes = 0;
// Observe actual SRAM enables, including banks outside the broadcast mask.
__MONITORS__
initial begin
  tick; io_aresetn = 1;
  io_s_axi_w_bits_strb = '1;
  // Normal data bank: read the first beat while the second beat is stalled.
  aw('h100); gap; beat('h1234, 0); gap;
  io_srams_0_en = 1; io_srams_0_addr = 'h40;
  tick;
  if (io_srams_0_dout !== 'h1234) $fatal(1, "normal memory corrupted in gap");
  io_srams_0_en = 0;
  beat('h5678, 1);
  if (!io_s_axi_b_valid || writes != 2) $fatal(1, "normal write count/response");
  io_s_axi_b_ready = 1; tick; io_s_axi_b_ready = 0;
  // Config bank has its own write-enable path.
  aw('hc100); gap; beat('habcd, 0); gap;
  io_sram_last_en = 1; io_sram_last_addr = 'h10;
  tick;
  if (io_sram_last_dout !== 'habcd) $fatal(1, "config memory corrupted in gap");
  io_sram_last_en = 0;
  beat('hef01, 1);
  if (!io_s_axi_b_valid || writes != 4) $fatal(1, "config write count/response");
  io_s_axi_b_ready = 1; tick; io_s_axi_b_ready = 0;
  // Broadcast to banks 0 and 1 with independent base addresses.
  io_bcast_en = 1; io_bcast_bank_mask = 3;
  io_bcast_base_addr_0 = 'h20; io_bcast_base_addr_1 = 'h30;
  aw(0); gap; beat('h2468, 0); gap;
  io_srams_0_en = 1; io_srams_0_addr = 'h80;
  io_srams_1_en = 1; io_srams_1_addr = 'hc0;
  tick;
  if (io_srams_0_dout !== 'h2468 || io_srams_1_dout !== 'h2468)
    $fatal(1, "broadcast data/address corrupted");
  io_srams_0_en = 0; io_srams_1_en = 0;
  beat('h1357, 1);
  if (!io_s_axi_b_valid || writes != 8) $fatal(1, "broadcast count/response");
  io_srams_0_en = 1; io_srams_0_addr = 'h84;
  io_srams_1_en = 1; io_srams_1_addr = 'hc4;
  tick;
  if (io_srams_0_dout !== 'h1357 || io_srams_1_dout !== 'h1357)
    $fatal(1, "broadcast counter advanced during gap");
  $display("PASS AXI4Scratchpad: normal/config/broadcast writes and memory readback");
  $finish;
end
'''


if __name__ == "__main__":
    rtl = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "verilog/LinGoWithAXI.v"
    monitors = []
    for bank in range(13):
        instance = ("TrueDualPortSRAMAsym" + (f"_{bank}" if bank else "")
                    if bank < 12 else "TrueDualPortSRAM_128_8")
        monitors.append(f'''always @(posedge clock) if (io_aresetn &&
          dut.{instance}.io_a_en && |dut.{instance}.io_a_we) begin
            if (!(io_s_axi_w_valid && io_s_axi_w_ready))
              $fatal(1, "phantom write bank {bank}");
            if (io_bcast_en && ({bank} > 1)) $fatal(1, "broadcast mask");
            writes = writes + 1;
          end''')
    engine_rtl = (Path(sys.argv[2]) if len(sys.argv) > 2
                  else Path(__file__).parent / "verilog/WriteEngine.v")
    run(engine_rtl, "WriteEngine", ENGINE)
    run(rtl, "AXI4Scratchpad", SCRATCHPAD.replace("__MONITORS__", "\n".join(monitors)))
