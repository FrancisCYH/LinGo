// Part of the LinGo project (soc/ Cheshire integration).
//
// Configuration and bus types for `cheshire_top_lingo`.
// Derived from the AuFORA integration (cheshire_top_aufora_pkg).
//
// Kept in a package so the typed ports of the top level (e.g. the LLC DRAM
// port) are visible in the module header, mirroring `cheshire_soc`.
//
// Two AXI type families are defined:
//   * `lingo_axi_*`   : Cheshire-side types (64-bit data), from the cfg
//   * `lingo_axi_cgra_*` : LinGo-side types (native 128-bit data, same ID
//                          width), used between `axi_dw_converter` and the
//                          flat Chisel ports inside `lingo_wrap`

`include "cheshire/typedef.svh"

package cheshire_top_lingo_pkg;

  import cheshire_pkg::*;
  import lingo_soc_pkg::*;

  // Use default config as far as possible
  function automatic cheshire_cfg_t gen_cheshire_lingo_cfg();
    cheshire_cfg_t ret = DefaultCfg;
    // LinGo scratchpad: AXI4 slave in the CIE region
    ret.AxiExtNumSlv         = 1;
    ret.AxiExtNumRules       = 2;
    ret.AxiExtRegionIdx[0]   = 0;
    ret.AxiExtRegionStart[0] = SocSpmCachedBase;
    ret.AxiExtRegionEnd[0]   = SocSpmCachedBase + SocSpmRegionBytes;
    // Uncached alias of the same port in the non-CIE region, for driver
    // access without cache-coherence concerns
    ret.AxiExtRegionIdx[1]   = 0;
    ret.AxiExtRegionStart[1] = SocSpmUncachedBase;
    ret.AxiExtRegionEnd[1]   = SocSpmUncachedBase + SocSpmRegionBytes;
    // LinGo registers: RegBus slave in the uncached region
    ret.RegExtNumSlv         = 1;
    ret.RegExtNumRules       = 1;
    ret.RegExtRegionIdx[0]   = 0;
    ret.RegExtRegionStart[0] = SocCsrBase;
    ret.RegExtRegionEnd[0]   = SocCsrBase + SocCsrRegionBytes;
    return ret;
  endfunction

  localparam cheshire_cfg_t LingoCfg = gen_cheshire_lingo_cfg();

  `CHESHIRE_TYPEDEF_ALL(lingo_, LingoCfg)

  // LinGo native port types: spec data width, Cheshire slave ID width
  localparam type lingo_cgra_data_t = logic [LingoAxiDataWidth-1:0];
  localparam type lingo_cgra_strb_t = logic [LingoAxiDataWidth/8-1:0];
  `CHESHIRE_TYPEDEF_AXI_CT(lingo_axi_cgra, lingo_addr_t,
      lingo_axi_slv_id_t, lingo_cgra_data_t, lingo_cgra_strb_t, lingo_axi_user_t)

endpackage
