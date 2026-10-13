// Part of the LinGo project (soc/ Cheshire integration).
//
// Cheshire top level integrating the LinGo CGRA accelerator.
// Derived from the AuFORA integration (cheshire_top_aufora).
//
// Address map (on top of the default Cheshire map, from lingo_soc_pkg):
//
//   * 0x2000_0000 - 0x2001_0000 : LinGo scratchpad via AXI4 ext slave
//                                 (CIE region: cached, idempotent, executable)
//   * 0x4000_0000 - 0x4001_0000 : uncached alias of the same scratchpad
//   * 0x4300_0000 - 0x4300_0400 : LinGo registers via RegBus ext slave
//                                 (uncached doorbell-style register file)
//
// The LLC (DRAM) master port is exposed for connection to a memory model in
// simulation or FPGA DRAM, mirroring `fixture_cheshire_soc`.

module cheshire_top_lingo
  import cheshire_top_lingo_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic test_mode_i,
  input  logic [1:0] boot_mode_i,
  input  logic rtc_i,

  // External AXI LLC (DRAM) port
  output lingo_axi_llc_req_t axi_llc_mst_req_o,
  input  lingo_axi_llc_rsp_t axi_llc_mst_rsp_i,

  // JTAG debug interface
  input  logic jtag_tck_i,
  input  logic jtag_trst_ni,
  input  logic jtag_tms_i,
  input  logic jtag_tdi_i,
  output logic jtag_tdo_o,

  // UART
  output logic uart_tx_o,
  input  logic uart_rx_i
);

  import cheshire_pkg::*;
  import lingo_soc_pkg::*;

  ///////////////////////////
  //  External CGRA Wires  //
  ///////////////////////////

  lingo_axi_slv_req_t [0:0] axi_ext_slv_req;
  lingo_axi_slv_rsp_t [0:0] axi_ext_slv_rsp;

  lingo_reg_req_t [0:0] reg_ext_slv_req;
  lingo_reg_rsp_t [0:0] reg_ext_slv_rsp;

  // Flat wires between adapter wrapper and Chisel-generated CGRA
  // (widths from lingo_soc_pkg, checked by assertions in lingo_wrap)
  logic [LingoAxiIdWidth-1:0]     cgra_axi_aw_id;
  logic [LingoAxiAddrWidth-1:0]   cgra_axi_aw_addr;
  logic [LingoAxiDataWidth-1:0]   cgra_axi_w_data;
  logic [LingoAxiDataWidth/8-1:0] cgra_axi_w_strb;
  logic [LingoAxiIdWidth-1:0]     cgra_axi_b_id;
  logic [LingoAxiIdWidth-1:0]     cgra_axi_ar_id;
  logic [LingoAxiAddrWidth-1:0]   cgra_axi_ar_addr;
  logic [LingoAxiIdWidth-1:0]     cgra_axi_r_id;
  logic [LingoAxiDataWidth-1:0]   cgra_axi_r_data;
  logic [LingoAxilAddrWidth-1:0]  cgra_axilite_aw_addr;
  logic [LingoAxilAddrWidth-1:0]  cgra_axilite_ar_addr;

  logic        cgra_axi_aw_ready, cgra_axi_aw_valid;
  logic [7:0]  cgra_axi_aw_len;
  logic [2:0]  cgra_axi_aw_size;
  logic [1:0]  cgra_axi_aw_burst;
  logic        cgra_axi_aw_lock;
  logic [3:0]  cgra_axi_aw_cache;
  logic [2:0]  cgra_axi_aw_prot;
  logic [3:0]  cgra_axi_aw_qos;
  logic        cgra_axi_w_ready, cgra_axi_w_valid;
  logic        cgra_axi_w_last;
  logic        cgra_axi_b_ready, cgra_axi_b_valid;
  logic [1:0]  cgra_axi_b_resp;
  logic        cgra_axi_ar_ready, cgra_axi_ar_valid;
  logic [7:0]  cgra_axi_ar_len;
  logic [2:0]  cgra_axi_ar_size;
  logic [1:0]  cgra_axi_ar_burst;
  logic        cgra_axi_ar_lock;
  logic [3:0]  cgra_axi_ar_cache;
  logic [2:0]  cgra_axi_ar_prot;
  logic [3:0]  cgra_axi_ar_qos;
  logic        cgra_axi_r_ready, cgra_axi_r_valid;
  logic [1:0]  cgra_axi_r_resp;
  logic        cgra_axi_r_last;

  logic        cgra_axilite_aw_ready, cgra_axilite_aw_valid;
  logic [2:0]  cgra_axilite_aw_prot;
  logic        cgra_axilite_w_ready, cgra_axilite_w_valid;
  logic [31:0] cgra_axilite_w_data;
  logic [3:0]  cgra_axilite_w_strb;
  logic        cgra_axilite_b_ready, cgra_axilite_b_valid;
  logic [1:0]  cgra_axilite_b_resp;
  logic        cgra_axilite_ar_ready, cgra_axilite_ar_valid;
  logic [2:0]  cgra_axilite_ar_prot;
  logic        cgra_axilite_r_ready, cgra_axilite_r_valid;
  logic [31:0] cgra_axilite_r_data;
  logic [1:0]  cgra_axilite_r_resp;

  ///////////
  //  SoC  //
  ///////////

  cheshire_soc #(
    .Cfg                ( LingoCfg ),
    .ExtHartinfo        ( '0 ),
    .axi_ext_llc_req_t  ( lingo_axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( lingo_axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( lingo_axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( lingo_axi_mst_rsp_t ),
    .axi_ext_slv_req_t  ( lingo_axi_slv_req_t ),
    .axi_ext_slv_rsp_t  ( lingo_axi_slv_rsp_t ),
    .reg_ext_req_t      ( lingo_reg_req_t ),
    .reg_ext_rsp_t      ( lingo_reg_rsp_t )
  ) i_cheshire_soc (
    .clk_i              ( clk_i ),
    .rst_ni             ( rst_ni ),
    .test_mode_i        ( test_mode_i ),
    .boot_mode_i        ( boot_mode_i ),
    .rtc_i              ( rtc_i ),
    .axi_llc_mst_req_o  ( axi_llc_mst_req_o ),
    .axi_llc_mst_rsp_i  ( axi_llc_mst_rsp_i ),
    .axi_ext_mst_req_i  ( '0 ),
    .axi_ext_mst_rsp_o  ( ),
    .axi_ext_slv_req_o  ( axi_ext_slv_req ),
    .axi_ext_slv_rsp_i  ( axi_ext_slv_rsp ),
    .reg_ext_slv_req_o  ( reg_ext_slv_req ),
    .reg_ext_slv_rsp_i  ( reg_ext_slv_rsp ),
    .intr_ext_i         ( '0 ),
    .intr_ext_o         ( ),
    .xeip_ext_o         ( ),
    .mtip_ext_o         ( ),
    .msip_ext_o         ( ),
    .dbg_active_o       ( ),
    .dbg_ext_req_o      ( ),
    .dbg_ext_unavail_i  ( '0 ),
    .jtag_tck_i         ( jtag_tck_i    ),
    .jtag_trst_ni       ( jtag_trst_ni  ),
    .jtag_tms_i         ( jtag_tms_i    ),
    .jtag_tdi_i         ( jtag_tdi_i    ),
    .jtag_tdo_o         ( jtag_tdo_o    ),
    .jtag_tdo_oe_o      ( ),
    .uart_tx_o          ( uart_tx_o ),
    .uart_rx_i          ( uart_rx_i ),
    .uart_rts_no        ( ),
    .uart_dtr_no        ( ),
    .uart_cts_ni        ( 1'b0 ),
    .uart_dsr_ni        ( 1'b0 ),
    .uart_dcd_ni        ( 1'b0 ),
    .uart_rin_ni        ( 1'b0 ),
    .i2c_sda_o          ( ),
    .i2c_sda_i          ( 1'b0 ),
    .i2c_sda_en_o       ( ),
    .i2c_scl_o          ( ),
    .i2c_scl_i          ( 1'b0 ),
    .i2c_scl_en_o       ( ),
    .spih_sck_o         ( ),
    .spih_sck_en_o      ( ),
    .spih_csb_o         ( ),
    .spih_csb_en_o      ( ),
    .spih_sd_o          ( ),
    .spih_sd_en_o       ( ),
    .spih_sd_i          ( '0 ),
    .gpio_i             ( '0 ),
    .gpio_o             ( ),
    .gpio_en_o          ( ),
    .slink_rcv_clk_i    ( '0 ),
    .slink_rcv_clk_o    ( ),
    .slink_i            ( '0 ),
    .slink_o            ( ),
    .vga_hsync_o        ( ),
    .vga_vsync_o        ( ),
    .vga_red_o          ( ),
    .vga_green_o        ( ),
    .vga_blue_o         ( ),
    .usb_clk_i          ( 1'b0 ),
    .usb_rst_ni         ( 1'b1 ),
    .usb_dm_i           ( '0 ),
    .usb_dm_o           ( ),
    .usb_dm_oe_o        ( ),
    .usb_dp_i           ( '0 ),
    .usb_dp_o           ( ),
    .usb_dp_oe_o        ( )
  );

  //////////////////////////////
  //  Adapter & CGRA Wrapper  //
  //////////////////////////////

  lingo_wrap #(
    .Cfg              ( LingoCfg ),
    .axi_slv_req_t    ( lingo_axi_slv_req_t     ),
    .axi_slv_rsp_t    ( lingo_axi_slv_rsp_t     ),
    .reg_req_t        ( lingo_reg_req_t         ),
    .reg_rsp_t        ( lingo_reg_rsp_t         ),
    .axi_cgra_req_t   ( lingo_axi_cgra_req_t    ),
    .axi_cgra_rsp_t   ( lingo_axi_cgra_rsp_t    ),
    .axi_cgra_w_chan_t( lingo_axi_cgra_w_chan_t ),
    .axi_cgra_r_chan_t( lingo_axi_cgra_r_chan_t ),
    .axi_slv_aw_chan_t( lingo_axi_slv_aw_chan_t ),
    .axi_slv_w_chan_t ( lingo_axi_slv_w_chan_t  ),
    .axi_slv_b_chan_t ( lingo_axi_slv_b_chan_t  ),
    .axi_slv_ar_chan_t( lingo_axi_slv_ar_chan_t ),
    .axi_slv_r_chan_t ( lingo_axi_slv_r_chan_t  )
  ) i_lingo_wrap (
    .clk_i  ( clk_i  ),
    .rst_ni ( rst_ni ),
    .axi_spm_req_i ( axi_ext_slv_req[0] ),
    .axi_spm_rsp_o ( axi_ext_slv_rsp[0] ),
    .reg_req_i     ( reg_ext_slv_req[0] ),
    .reg_rsp_o     ( reg_ext_slv_rsp[0] ),

    .io_s_axi_aw_ready    ( cgra_axi_aw_ready ),
    .io_s_axi_aw_valid    ( cgra_axi_aw_valid ),
    .io_s_axi_aw_bits_id    ( cgra_axi_aw_id    ),
    .io_s_axi_aw_bits_addr  ( cgra_axi_aw_addr  ),
    .io_s_axi_aw_bits_len   ( cgra_axi_aw_len   ),
    .io_s_axi_aw_bits_size  ( cgra_axi_aw_size  ),
    .io_s_axi_aw_bits_burst ( cgra_axi_aw_burst ),
    .io_s_axi_aw_bits_lock  ( cgra_axi_aw_lock  ),
    .io_s_axi_aw_bits_cache ( cgra_axi_aw_cache ),
    .io_s_axi_aw_bits_prot  ( cgra_axi_aw_prot  ),
    .io_s_axi_aw_bits_qos   ( cgra_axi_aw_qos   ),
    .io_s_axi_w_ready     ( cgra_axi_w_ready  ),
    .io_s_axi_w_valid     ( cgra_axi_w_valid  ),
    .io_s_axi_w_bits_data ( cgra_axi_w_data   ),
    .io_s_axi_w_bits_strb ( cgra_axi_w_strb   ),
    .io_s_axi_w_bits_last ( cgra_axi_w_last   ),
    .io_s_axi_b_ready     ( cgra_axi_b_ready  ),
    .io_s_axi_b_valid     ( cgra_axi_b_valid  ),
    .io_s_axi_b_bits_id   ( cgra_axi_b_id     ),
    .io_s_axi_b_bits_resp ( cgra_axi_b_resp   ),
    .io_s_axi_ar_ready    ( cgra_axi_ar_ready ),
    .io_s_axi_ar_valid    ( cgra_axi_ar_valid ),
    .io_s_axi_ar_bits_id    ( cgra_axi_ar_id    ),
    .io_s_axi_ar_bits_addr  ( cgra_axi_ar_addr  ),
    .io_s_axi_ar_bits_len   ( cgra_axi_ar_len   ),
    .io_s_axi_ar_bits_size  ( cgra_axi_ar_size  ),
    .io_s_axi_ar_bits_burst ( cgra_axi_ar_burst ),
    .io_s_axi_ar_bits_lock  ( cgra_axi_ar_lock  ),
    .io_s_axi_ar_bits_cache ( cgra_axi_ar_cache ),
    .io_s_axi_ar_bits_prot  ( cgra_axi_ar_prot  ),
    .io_s_axi_ar_bits_qos   ( cgra_axi_ar_qos   ),
    .io_s_axi_r_ready     ( cgra_axi_r_ready  ),
    .io_s_axi_r_valid     ( cgra_axi_r_valid  ),
    .io_s_axi_r_bits_id   ( cgra_axi_r_id     ),
    .io_s_axi_r_bits_data ( cgra_axi_r_data   ),
    .io_s_axi_r_bits_resp ( cgra_axi_r_resp   ),
    .io_s_axi_r_bits_last ( cgra_axi_r_last   ),

    .io_s_axilite_aw_ready    ( cgra_axilite_aw_ready ),
    .io_s_axilite_aw_valid    ( cgra_axilite_aw_valid ),
    .io_s_axilite_aw_bits_addr  ( cgra_axilite_aw_addr  ),
    .io_s_axilite_aw_bits_prot  ( cgra_axilite_aw_prot  ),
    .io_s_axilite_w_ready     ( cgra_axilite_w_ready  ),
    .io_s_axilite_w_valid     ( cgra_axilite_w_valid  ),
    .io_s_axilite_w_bits_data ( cgra_axilite_w_data   ),
    .io_s_axilite_w_bits_strb ( cgra_axilite_w_strb   ),
    .io_s_axilite_b_ready     ( cgra_axilite_b_ready  ),
    .io_s_axilite_b_valid     ( cgra_axilite_b_valid  ),
    .io_s_axilite_b_bits_resp ( cgra_axilite_b_resp   ),
    .io_s_axilite_ar_ready    ( cgra_axilite_ar_ready ),
    .io_s_axilite_ar_valid    ( cgra_axilite_ar_valid ),
    .io_s_axilite_ar_bits_addr  ( cgra_axilite_ar_addr  ),
    .io_s_axilite_ar_bits_prot  ( cgra_axilite_ar_prot  ),
    .io_s_axilite_r_ready     ( cgra_axilite_r_ready  ),
    .io_s_axilite_r_valid     ( cgra_axilite_r_valid  ),
    .io_s_axilite_r_bits_data ( cgra_axilite_r_data   ),
    .io_s_axilite_r_bits_resp ( cgra_axilite_r_resp   )
  );

  // Chisel-generated CGRA; note the active-high synchronous reset
  LinGoWithAXI i_lingo_cgra (
    .clock ( clk_i  ),
    .reset ( ~rst_ni ),
    .io_s_axi_aw_ready    ( cgra_axi_aw_ready ),
    .io_s_axi_aw_valid    ( cgra_axi_aw_valid ),
    .io_s_axi_aw_bits_id    ( cgra_axi_aw_id    ),
    .io_s_axi_aw_bits_addr  ( cgra_axi_aw_addr  ),
    .io_s_axi_aw_bits_len   ( cgra_axi_aw_len   ),
    .io_s_axi_aw_bits_size  ( cgra_axi_aw_size  ),
    .io_s_axi_aw_bits_burst ( cgra_axi_aw_burst ),
    .io_s_axi_aw_bits_lock  ( cgra_axi_aw_lock  ),
    .io_s_axi_aw_bits_cache ( cgra_axi_aw_cache ),
    .io_s_axi_aw_bits_prot  ( cgra_axi_aw_prot  ),
    .io_s_axi_aw_bits_qos   ( cgra_axi_aw_qos   ),
    .io_s_axi_w_ready     ( cgra_axi_w_ready  ),
    .io_s_axi_w_valid     ( cgra_axi_w_valid  ),
    .io_s_axi_w_bits_data ( cgra_axi_w_data   ),
    .io_s_axi_w_bits_strb ( cgra_axi_w_strb   ),
    .io_s_axi_w_bits_last ( cgra_axi_w_last   ),
    .io_s_axi_b_ready     ( cgra_axi_b_ready  ),
    .io_s_axi_b_valid     ( cgra_axi_b_valid  ),
    .io_s_axi_b_bits_id   ( cgra_axi_b_id     ),
    .io_s_axi_b_bits_resp ( cgra_axi_b_resp   ),
    .io_s_axi_ar_ready    ( cgra_axi_ar_ready ),
    .io_s_axi_ar_valid    ( cgra_axi_ar_valid ),
    .io_s_axi_ar_bits_id    ( cgra_axi_ar_id    ),
    .io_s_axi_ar_bits_addr  ( cgra_axi_ar_addr  ),
    .io_s_axi_ar_bits_len   ( cgra_axi_ar_len   ),
    .io_s_axi_ar_bits_size  ( cgra_axi_ar_size  ),
    .io_s_axi_ar_bits_burst ( cgra_axi_ar_burst ),
    .io_s_axi_ar_bits_lock  ( cgra_axi_ar_lock  ),
    .io_s_axi_ar_bits_cache ( cgra_axi_ar_cache ),
    .io_s_axi_ar_bits_prot  ( cgra_axi_ar_prot  ),
    .io_s_axi_ar_bits_qos   ( cgra_axi_ar_qos   ),
    .io_s_axi_r_ready     ( cgra_axi_r_ready  ),
    .io_s_axi_r_valid     ( cgra_axi_r_valid  ),
    .io_s_axi_r_bits_id   ( cgra_axi_r_id     ),
    .io_s_axi_r_bits_data ( cgra_axi_r_data   ),
    .io_s_axi_r_bits_resp ( cgra_axi_r_resp   ),
    .io_s_axi_r_bits_last ( cgra_axi_r_last   ),
    .io_s_axilite_aw_ready    ( cgra_axilite_aw_ready ),
    .io_s_axilite_aw_valid    ( cgra_axilite_aw_valid ),
    .io_s_axilite_aw_bits_addr  ( cgra_axilite_aw_addr  ),
    .io_s_axilite_aw_bits_prot  ( cgra_axilite_aw_prot  ),
    .io_s_axilite_w_ready     ( cgra_axilite_w_ready  ),
    .io_s_axilite_w_valid     ( cgra_axilite_w_valid  ),
    .io_s_axilite_w_bits_data ( cgra_axilite_w_data   ),
    .io_s_axilite_w_bits_strb ( cgra_axilite_w_strb   ),
    .io_s_axilite_b_ready     ( cgra_axilite_b_ready  ),
    .io_s_axilite_b_valid     ( cgra_axilite_b_valid  ),
    .io_s_axilite_b_bits_resp ( cgra_axilite_b_resp   ),
    .io_s_axilite_ar_ready    ( cgra_axilite_ar_ready ),
    .io_s_axilite_ar_valid    ( cgra_axilite_ar_valid ),
    .io_s_axilite_ar_bits_addr  ( cgra_axilite_ar_addr  ),
    .io_s_axilite_ar_bits_prot  ( cgra_axilite_ar_prot  ),
    .io_s_axilite_r_ready     ( cgra_axilite_r_ready  ),
    .io_s_axilite_r_valid     ( cgra_axilite_r_valid  ),
    .io_s_axilite_r_bits_data ( cgra_axilite_r_data   ),
    .io_s_axilite_r_bits_resp ( cgra_axilite_r_resp   )
  );

endmodule
