// Part of the LinGo project (soc/ Cheshire integration).
//
// Testbench fixture for `cheshire_top_lingo`, mirroring
// `fixture_cheshire_soc` but with the LinGo CGRA integration as DUT.
// Derived from the AuFORA integration (fixture_cheshire_top_aufora).
//
// Signal names are kept identical to `fixture_cheshire_soc` so the stock
// `vip_cheshire_soc` (`.*` binding, hierarchical references to `fix.vip`)
// works unchanged. Peripherals not exposed by `cheshire_top_lingo`
// (I2C, SPI host, GPIO, VGA, USB, Serial Link) are left dangling; use the
// JTAG (PRELMODE=0) or MEMH (PRELMODE=3) preload flows.

module fixture_cheshire_top_lingo #(
  parameter bit UseDramSys = 1'b0
);

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;
  import cheshire_top_lingo_pkg::*;

  localparam cheshire_cfg_t DutCfg = LingoCfg;

  `CHESHIRE_TYPEDEF_ALL(, DutCfg)

  ///////////
  //  DUT  //
  ///////////

  logic       clk;
  logic       rst_n;
  logic       test_mode;
  logic [1:0] boot_mode;
  logic       rtc;

  axi_llc_req_t axi_llc_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_tx;
  logic uart_rx;

  // Undriven: no I2C/SPI host ports on the LinGo top level; the EEPROM and
  // flash models inside the VIP see an idle bus (I2C needs a pullup).
  tri1       i2c_sda;
  tri1       i2c_scl;
  wire       spih_sck = 1'b0;
  wire [SpihNumCs-1:0] spih_csb = '1;
  wire [3:0] spih_sd;

  // Undriven: Serial Link not exposed by the LinGo top level
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_i;
  logic [SlinkNumChan-1:0]                    slink_rcv_clk_o;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_i;
  logic [SlinkNumChan-1:0][SlinkNumLanes-1:0] slink_o;

  assign slink_rcv_clk_o = '0;
  assign slink_o         = '0;

  cheshire_top_lingo i_dut (
    .clk_i              ( clk       ),
    .rst_ni             ( rst_n     ),
    .test_mode_i        ( test_mode ),
    .boot_mode_i        ( boot_mode ),
    .rtc_i              ( rtc       ),
    .axi_llc_mst_req_o  ( axi_llc_mst_req ),
    .axi_llc_mst_rsp_i  ( axi_llc_mst_rsp ),
    .jtag_tck_i         ( jtag_tck    ),
    .jtag_trst_ni       ( jtag_trst_n ),
    .jtag_tms_i         ( jtag_tms    ),
    .jtag_tdi_i         ( jtag_tdi    ),
    .jtag_tdo_o         ( jtag_tdo    ),
    .uart_tx_o          ( uart_tx ),
    .uart_rx_i          ( uart_rx )
  );

  ///////////
  //  VIP  //
  ///////////

  axi_mst_req_t axi_slink_mst_req;
  axi_mst_rsp_t axi_slink_mst_rsp;

  assign axi_slink_mst_req = '0;

  vip_cheshire_soc #(
    .DutCfg            ( DutCfg ),
    .UseDramSys        ( UseDramSys ),
    .axi_ext_llc_req_t ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t ( axi_mst_rsp_t )
  ) vip (.*);

endmodule
