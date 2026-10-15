// Part of the LinGo project (soc/ Cheshire integration).
//
// Cheshire-to-LinGo adapter wrapper.
//
// Bridges the LinGo CGRA (Chisel-generated `LinGoWithAXI`) to Cheshire's
// external ports:
//
//   * CGRA AXI4 SPM port (native 128-bit data, 8-bit ID)  <-  Cheshire
//     `axi_ext_slv` port (64-bit data, 5-bit ID) via an `axi_dw_converter`
//     upsizer. The CGRA keeps its native data width; the conversion is
//     entirely on the SoC side.
//   * CGRA AXI4-Lite register port  <-  Cheshire `reg_ext_slv` RegBus port
//     via `lingo_regbus_to_axilite`.
//
// ID handling: the CGRA scratchpad only echoes transaction IDs and processes
// one transaction at a time, so IDs are zero-extended towards the CGRA and
// truncated on return. Width mismatches after a hardware regeneration fail
// loudly at simulation start (initial assertions below).
//
// Both CGRA ports are slaves, so the CGRA appears as a pure memory-mapped
// peripheral; data is moved in and out of its private scratchpad by the host
// core or the built-in iDMA.

module lingo_wrap #(
  /// Cheshire configuration, used to check the CGRA port widths
  parameter cheshire_pkg::cheshire_cfg_t Cfg = cheshire_pkg::DefaultCfg,
  /// Cheshire AXI slave types (from `CHESHIRE_TYPEDEF_ALL)
  parameter type axi_slv_req_t           = logic,
  parameter type axi_slv_rsp_t           = logic,
  /// Cheshire RegBus types (from `CHESHIRE_TYPEDEF_ALL)
  parameter type reg_req_t               = logic,
  parameter type reg_rsp_t               = logic,
  /// LinGo-side AXI types (128-bit data, Cheshire slave ID width)
  parameter type axi_cgra_req_t          = logic,
  parameter type axi_cgra_rsp_t          = logic,
  parameter type axi_cgra_w_chan_t       = logic,
  parameter type axi_cgra_r_chan_t       = logic,
  /// Cheshire slave channel types (AW/AR/B are shared with the CGRA side)
  parameter type axi_slv_aw_chan_t       = logic,
  parameter type axi_slv_w_chan_t        = logic,
  parameter type axi_slv_b_chan_t        = logic,
  parameter type axi_slv_ar_chan_t       = logic,
  parameter type axi_slv_r_chan_t        = logic,
  /// LinGo SPM AXI4 port configuration (from `lingo_soc_pkg`, generated)
  parameter int unsigned CgraDataWidth   = lingo_soc_pkg::LingoAxiDataWidth,
  parameter int unsigned CgraAddrWidth   = lingo_soc_pkg::LingoAxiAddrWidth,
  parameter int unsigned CgraIdWidth     = lingo_soc_pkg::LingoAxiIdWidth,
  parameter int unsigned CgraAxilAddrWidth = lingo_soc_pkg::LingoAxilAddrWidth
) (
  input logic clk_i,
  input logic rst_ni,

  // SoC AXI4 slave port towards the CGRA scratchpad (Cheshire side)
  input  axi_slv_req_t axi_spm_req_i,
  output axi_slv_rsp_t axi_spm_rsp_o,

  // SoC RegBus port towards the CGRA registers (Cheshire side)
  input  reg_req_t reg_req_i,
  output reg_rsp_t reg_rsp_o,

  // LinGo AXI4 slave port (scratchpad data), flat ports
  input  logic                        io_s_axi_aw_ready,
  output logic                        io_s_axi_aw_valid,
  output logic [CgraIdWidth-1:0]      io_s_axi_aw_bits_id,
  output logic [CgraAddrWidth-1:0]    io_s_axi_aw_bits_addr,
  output logic [7:0]                  io_s_axi_aw_bits_len,
  output logic [2:0]                  io_s_axi_aw_bits_size,
  output logic [1:0]                  io_s_axi_aw_bits_burst,
  output logic                        io_s_axi_aw_bits_lock,
  output logic [3:0]                  io_s_axi_aw_bits_cache,
  output logic [2:0]                  io_s_axi_aw_bits_prot,
  output logic [3:0]                  io_s_axi_aw_bits_qos,
  input  logic                        io_s_axi_w_ready,
  output logic                        io_s_axi_w_valid,
  output logic [CgraDataWidth-1:0]    io_s_axi_w_bits_data,
  output logic [CgraDataWidth/8-1:0]  io_s_axi_w_bits_strb,
  output logic                        io_s_axi_w_bits_last,
  output logic                        io_s_axi_b_ready,
  input  logic                        io_s_axi_b_valid,
  input  logic [CgraIdWidth-1:0]      io_s_axi_b_bits_id,
  input  logic [1:0]                  io_s_axi_b_bits_resp,
  input  logic                        io_s_axi_ar_ready,
  output logic                        io_s_axi_ar_valid,
  output logic [CgraIdWidth-1:0]      io_s_axi_ar_bits_id,
  output logic [CgraAddrWidth-1:0]    io_s_axi_ar_bits_addr,
  output logic [7:0]                  io_s_axi_ar_bits_len,
  output logic [2:0]                  io_s_axi_ar_bits_size,
  output logic [1:0]                  io_s_axi_ar_bits_burst,
  output logic                        io_s_axi_ar_bits_lock,
  output logic [3:0]                  io_s_axi_ar_bits_cache,
  output logic [2:0]                  io_s_axi_ar_bits_prot,
  output logic [3:0]                  io_s_axi_ar_bits_qos,
  output logic                        io_s_axi_r_ready,
  input  logic                        io_s_axi_r_valid,
  input  logic [CgraIdWidth-1:0]      io_s_axi_r_bits_id,
  input  logic [CgraDataWidth-1:0]    io_s_axi_r_bits_data,
  input  logic [1:0]                  io_s_axi_r_bits_resp,
  input  logic                        io_s_axi_r_bits_last,

  // LinGo AXI4-Lite slave port (registers), flat ports
  input  logic                          io_s_axilite_aw_ready,
  output logic                          io_s_axilite_aw_valid,
  output logic [CgraAxilAddrWidth-1:0]  io_s_axilite_aw_bits_addr,
  output logic [2:0]                    io_s_axilite_aw_bits_prot,
  input  logic                          io_s_axilite_w_ready,
  output logic                          io_s_axilite_w_valid,
  output logic [31:0]                   io_s_axilite_w_bits_data,
  output logic [3:0]                    io_s_axilite_w_bits_strb,
  output logic                          io_s_axilite_b_ready,
  input  logic                          io_s_axilite_b_valid,
  input  logic [1:0]                    io_s_axilite_b_bits_resp,
  input  logic                          io_s_axilite_ar_ready,
  output logic                          io_s_axilite_ar_valid,
  output logic [CgraAxilAddrWidth-1:0]  io_s_axilite_ar_bits_addr,
  output logic [2:0]                    io_s_axilite_ar_bits_prot,
  output logic                          io_s_axilite_r_ready,
  input  logic                          io_s_axilite_r_valid,
  input  logic [31:0]                   io_s_axilite_r_bits_data,
  input  logic [1:0]                    io_s_axilite_r_bits_resp
);

  import cheshire_pkg::*;

  // Cheshire slave IDs carry the originating master index on top of the
  // master IDs; this is the ID width seen at the SoC's slave ports.
  localparam axi_in_t AxiIn = gen_axi_in(Cfg);
  localparam int unsigned SlvIdWidth = Cfg.AxiMstIdWidth + $clog2(AxiIn.num_in);

  // The width relationship between the SoC port and the CGRA is fixed by
  // design; a regenerated CGRA that violates it fails at simulation start.
  initial begin
    assert (CgraDataWidth % Cfg.AxiDataWidth == 0)
      else $fatal(1, "LinGo CGRA data width %0d is not a multiple of Cheshire AXI data width %0d",
                  CgraDataWidth, Cfg.AxiDataWidth);
    assert (CgraIdWidth >= SlvIdWidth)
      else $fatal(1, "LinGo CGRA ID width %0d < Cheshire slave ID width %0d",
                  CgraIdWidth, SlvIdWidth);
    assert ((64'd1 << CgraAddrWidth) >= lingo_soc_pkg::LingoSpmBytes)
      else $fatal(1, "LinGo SPM (%0d B) does not fit the CGRA AXI address width (%0d)",
                  lingo_soc_pkg::LingoSpmBytes, CgraAddrWidth);
  end

  ////////////
  //  SPM   //
  ////////////

  // Data-width conversion 64 -> 128 between Cheshire and the CGRA. AW, AR
  // and B channels are width-agnostic (same ID width on both ports), only W
  // and R are repacked.
  axi_cgra_req_t cgra_req;
  axi_cgra_rsp_t cgra_rsp;

  axi_dw_converter #(
    .AxiMaxReads         ( 8                  ),
    .AxiSlvPortDataWidth ( Cfg.AxiDataWidth   ),
    .AxiMstPortDataWidth ( CgraDataWidth      ),
    .AxiAddrWidth        ( Cfg.AddrWidth      ),
    .AxiIdWidth          ( SlvIdWidth         ),
    .aw_chan_t           ( axi_slv_aw_chan_t  ),
    .mst_w_chan_t        ( axi_cgra_w_chan_t  ),
    .slv_w_chan_t        ( axi_slv_w_chan_t   ),
    .b_chan_t            ( axi_slv_b_chan_t   ),
    .ar_chan_t           ( axi_slv_ar_chan_t  ),
    .mst_r_chan_t        ( axi_cgra_r_chan_t  ),
    .slv_r_chan_t        ( axi_slv_r_chan_t   ),
    .axi_mst_req_t       ( axi_cgra_req_t     ),
    .axi_mst_resp_t      ( axi_cgra_rsp_t     ),
    .axi_slv_req_t       ( axi_slv_req_t      ),
    .axi_slv_resp_t      ( axi_slv_rsp_t      )
  ) i_dw_converter (
    .clk_i      ( clk_i        ),
    .rst_ni     ( rst_ni       ),
    .slv_req_i  ( axi_spm_req_i ),
    .slv_resp_o ( axi_spm_rsp_o ),
    .mst_req_o  ( cgra_req      ),
    .mst_resp_i ( cgra_rsp      )
  );

  // Converter master port -> CGRA inputs (struct to flat; ID zero-extended,
  // address truncated to the CGRA's local offset bits)
  assign io_s_axi_aw_valid      = cgra_req.aw_valid;
  assign io_s_axi_aw_bits_id    = CgraIdWidth'(cgra_req.aw.id);
  assign io_s_axi_aw_bits_addr  = cgra_req.aw.addr[CgraAddrWidth-1:0];
  assign io_s_axi_aw_bits_len   = cgra_req.aw.len;
  assign io_s_axi_aw_bits_size  = cgra_req.aw.size;
  assign io_s_axi_aw_bits_burst = cgra_req.aw.burst;
  assign io_s_axi_aw_bits_lock  = cgra_req.aw.lock;
  assign io_s_axi_aw_bits_cache = cgra_req.aw.cache;
  assign io_s_axi_aw_bits_prot  = cgra_req.aw.prot;
  assign io_s_axi_aw_bits_qos   = cgra_req.aw.qos;

  assign io_s_axi_w_valid     = cgra_req.w_valid;
  assign io_s_axi_w_bits_data = cgra_req.w.data;
  assign io_s_axi_w_bits_strb = cgra_req.w.strb;
  assign io_s_axi_w_bits_last = cgra_req.w.last;

  assign io_s_axi_b_ready     = cgra_req.b_ready;

  assign io_s_axi_ar_valid      = cgra_req.ar_valid;
  assign io_s_axi_ar_bits_id    = CgraIdWidth'(cgra_req.ar.id);
  assign io_s_axi_ar_bits_addr  = cgra_req.ar.addr[CgraAddrWidth-1:0];
  assign io_s_axi_ar_bits_len   = cgra_req.ar.len;
  assign io_s_axi_ar_bits_size  = cgra_req.ar.size;
  assign io_s_axi_ar_bits_burst = cgra_req.ar.burst;
  assign io_s_axi_ar_bits_lock  = cgra_req.ar.lock;
  assign io_s_axi_ar_bits_cache = cgra_req.ar.cache;
  assign io_s_axi_ar_bits_prot  = cgra_req.ar.prot;
  assign io_s_axi_ar_bits_qos   = cgra_req.ar.qos;

  assign io_s_axi_r_ready = cgra_req.r_ready;

  // CGRA outputs -> converter master response (flat to struct; ID truncated,
  // no user signals on the CGRA side)
  assign cgra_rsp.aw_ready = io_s_axi_aw_ready;
  assign cgra_rsp.w_ready  = io_s_axi_w_ready;
  assign cgra_rsp.b_valid  = io_s_axi_b_valid;
  assign cgra_rsp.b.id     = io_s_axi_b_bits_id[SlvIdWidth-1:0];
  assign cgra_rsp.b.resp   = axi_pkg::resp_t'(io_s_axi_b_bits_resp);
  assign cgra_rsp.b.user   = '0;
  assign cgra_rsp.ar_ready = io_s_axi_ar_ready;
  assign cgra_rsp.r_valid  = io_s_axi_r_valid;
  assign cgra_rsp.r.id     = io_s_axi_r_bits_id[SlvIdWidth-1:0];
  assign cgra_rsp.r.data   = io_s_axi_r_bits_data;
  assign cgra_rsp.r.resp   = axi_pkg::resp_t'(io_s_axi_r_bits_resp);
  assign cgra_rsp.r.last   = io_s_axi_r_bits_last;
  assign cgra_rsp.r.user   = '0;

  ////////////////////
  //  Registers     //
  ////////////////////

  lingo_regbus_to_axilite #(
    .AxiliteAddrWidth ( CgraAxilAddrWidth ),
    .reg_req_t        ( reg_req_t         ),
    .reg_rsp_t        ( reg_rsp_t         )
  ) i_reg_bridge (
    .clk_i               ( clk_i    ),
    .rst_ni              ( rst_ni   ),
    .reg_req_i           ( reg_req_i  ),
    .reg_rsp_o           ( reg_rsp_o  ),
    .axilite_aw_valid_o  ( io_s_axilite_aw_valid      ),
    .axilite_aw_ready_i  ( io_s_axilite_aw_ready      ),
    .axilite_aw_addr_o   ( io_s_axilite_aw_bits_addr  ),
    .axilite_aw_prot_o   ( io_s_axilite_aw_bits_prot  ),
    .axilite_w_valid_o   ( io_s_axilite_w_valid       ),
    .axilite_w_ready_i   ( io_s_axilite_w_ready       ),
    .axilite_w_data_o    ( io_s_axilite_w_bits_data   ),
    .axilite_w_strb_o    ( io_s_axilite_w_bits_strb   ),
    .axilite_b_valid_i   ( io_s_axilite_b_valid       ),
    .axilite_b_ready_o   ( io_s_axilite_b_ready       ),
    .axilite_b_resp_i    ( io_s_axilite_b_bits_resp   ),
    .axilite_ar_valid_o  ( io_s_axilite_ar_valid      ),
    .axilite_ar_ready_i  ( io_s_axilite_ar_ready      ),
    .axilite_ar_addr_o   ( io_s_axilite_ar_bits_addr  ),
    .axilite_ar_prot_o   ( io_s_axilite_ar_bits_prot  ),
    .axilite_r_valid_i   ( io_s_axilite_r_valid       ),
    .axilite_r_ready_o   ( io_s_axilite_r_ready       ),
    .axilite_r_data_i    ( io_s_axilite_r_bits_data   ),
    .axilite_r_resp_i    ( io_s_axilite_r_bits_resp   )
  );

endmodule
