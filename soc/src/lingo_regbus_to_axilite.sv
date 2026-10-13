// Part of the LinGo project (soc/ Cheshire integration).
//
// RegBus-to-AXI4-Lite adapter for the LinGo CGRA register interface.
// Derived from the AuFORA integration (aufora_regbus_to_axilite).
//
// Cheshire's external register port (`reg_ext_slv_req_o/rsp_i`) speaks the
// 32-bit RegBus protocol, while the LinGo CGRA exposes a flat AXI4-Lite
// slave port. This bridge forwards one request at a time, which is
// sufficient for the CGRA's doorbell-style register file.

module lingo_regbus_to_axilite #(
  /// Address width of the AXI4-Lite slave port (lingo_soc_pkg::LingoAxilAddrWidth)
  parameter int unsigned AxiliteAddrWidth = 7,
  /// RegBus request type (from `REG_BUS_TYPEDEF_ALL)
  parameter type         reg_req_t        = logic,
  /// RegBus response type
  parameter type         reg_rsp_t        = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  // RegBus master side (towards Cheshire)
  input  reg_req_t reg_req_i,
  output reg_rsp_t reg_rsp_o,

  // AXI4-Lite slave side (towards LinGo, flat ports)
  output logic                        axilite_aw_valid_o,
  input  logic                        axilite_aw_ready_i,
  output logic [AxiliteAddrWidth-1:0] axilite_aw_addr_o,
  output logic [2:0]                  axilite_aw_prot_o,
  output logic                        axilite_w_valid_o,
  input  logic                        axilite_w_ready_i,
  output logic [31:0]                 axilite_w_data_o,
  output logic [3:0]                  axilite_w_strb_o,
  input  logic                        axilite_b_valid_i,
  output logic                        axilite_b_ready_o,
  input  logic [1:0]                  axilite_b_resp_i,
  output logic                        axilite_ar_valid_o,
  input  logic                        axilite_ar_ready_i,
  output logic [AxiliteAddrWidth-1:0] axilite_ar_addr_o,
  output logic [2:0]                  axilite_ar_prot_o,
  input  logic                        axilite_r_valid_i,
  output logic                        axilite_r_ready_o,
  input  logic [31:0]                 axilite_r_data_i,
  input  logic [1:0]                  axilite_r_resp_i
);

  // The upstream `axi_to_reg_v2` issues RegBus requests as single-cycle valid
  // pulses (pulp register_interface semantics: valid is not held until
  // acceptance, the response comes back later via rsp.ready). The request must
  // therefore be captured immediately and driven onto the AXI4-Lite channels
  // from registers until accepted.
  typedef enum logic [2:0] {Idle, WrAddr, WrWaitB, RdAddr, RdWaitR} state_e;

  state_e state_d, state_q;

  logic [AxiliteAddrWidth-1:0] addr_q;
  logic [31:0]                 wdata_q;
  logic [3:0]                  wstrb_q;
  // AW and W are independent AXI4-Lite channels and may be accepted in
  // different cycles (the LinGo slave asserts aw_ready and w_ready in
  // mutually exclusive FSM states), so each handshake is tracked separately.
  logic                        aw_done_d, aw_done_q;
  logic                        w_done_d,  w_done_q;

  // Latched request fields, driven onto the AXI4-Lite channels
  assign axilite_aw_addr_o = addr_q;
  assign axilite_ar_addr_o = addr_q;
  assign axilite_aw_prot_o = 3'b000;
  assign axilite_ar_prot_o = 3'b000;
  assign axilite_w_data_o  = wdata_q;
  assign axilite_w_strb_o  = wstrb_q;

  always_comb begin
    state_d              = state_q;
    aw_done_d            = aw_done_q;
    w_done_d             = w_done_q;
    axilite_aw_valid_o   = 1'b0;
    axilite_w_valid_o    = 1'b0;
    axilite_b_ready_o    = 1'b0;
    axilite_ar_valid_o   = 1'b0;
    axilite_r_ready_o    = 1'b0;
    reg_rsp_o.rdata      = '0;
    reg_rsp_o.error      = 1'b0;
    reg_rsp_o.ready      = 1'b0;

    unique case (state_q)
      // Capture the incoming RegBus request pulse
      Idle: begin
        if (reg_req_i.valid) begin
          aw_done_d = 1'b0;
          w_done_d  = 1'b0;
          state_d   = reg_req_i.write ? WrAddr : RdAddr;
        end
      end
      // Hold each of AW and W valid until individually accepted
      WrAddr: begin
        axilite_aw_valid_o = ~aw_done_q;
        axilite_w_valid_o  = ~w_done_q;
        aw_done_d          = aw_done_q | axilite_aw_ready_i;
        w_done_d           = w_done_q  | axilite_w_ready_i;
        if (aw_done_d && w_done_d) begin
          aw_done_d = 1'b0;
          w_done_d  = 1'b0;
          state_d   = WrWaitB;
        end
      end
      // Write address and data accepted; wait for write response
      WrWaitB: begin
        axilite_b_ready_o = 1'b1;
        if (axilite_b_valid_i) begin
          reg_rsp_o.error = |axilite_b_resp_i;
          reg_rsp_o.ready = 1'b1;
          state_d         = Idle;
        end
      end
      // Hold AR valid until accepted
      RdAddr: begin
        axilite_ar_valid_o = 1'b1;
        if (axilite_ar_ready_i) state_d = RdWaitR;
      end
      // Read address accepted; wait for read data
      RdWaitR: begin
        axilite_r_ready_o = 1'b1;
        if (axilite_r_valid_i) begin
          reg_rsp_o.rdata = axilite_r_data_i;
          reg_rsp_o.error = |axilite_r_resp_i;
          reg_rsp_o.ready = 1'b1;
          state_d         = Idle;
        end
      end
      default: state_d = Idle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_q  <= '0;
      wdata_q <= '0;
      wstrb_q <= '0;
    end else if (state_q == Idle && reg_req_i.valid) begin
      addr_q  <= reg_req_i.addr[AxiliteAddrWidth-1:0];
      wdata_q <= reg_req_i.wdata;
      wstrb_q <= reg_req_i.wstrb;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= Idle;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
    end else begin
      state_q   <= state_d;
      aw_done_q <= aw_done_d;
      w_done_q  <= w_done_d;
    end
  end

endmodule
