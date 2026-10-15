# CGRA waveform logging for LinGo simulation debug.
# Usage: vsim ... -do "do log_lingo.do; run 30 ms; quit"
# Hierarchy: tb -> fix (fixture) -> i_dut (cheshire_top_lingo) -> i_lingo_cgra
# Notes:
#   * vopt drops bare scope objects and some folded ports; wildcards avoid
#     "No objects found" errors that would abort this macro mid-way.
#   * Do NOT add "log -r $CGRA" (whole CGRA): the PE array is huge and the
#     log will be far too slow. Keep it to the controller + bus ports.
set CGRA /tb_cheshire_top_lingo/fix/i_dut/i_lingo_cgra

# Controller FSM and internals (execution state, config control, done bits)
log -r $CGRA/controller/*

# Config chain SPM read port (if this never toggles after cfg_en, the
# bitstream is not being consumed)
log $CGRA/controller_io_sram_cfg_*

# CGRA AXI4 data port (valid/ready/last + payload). To pinpoint register
# writes in the wave viewer, search io_s_axilite_aw_bits_addr == 0x0c
# (cfg_en) and == 0x18 (start).
log $CGRA/io_s_axi_aw_*
log $CGRA/io_s_axi_w_*
log $CGRA/io_s_axi_b_*
log $CGRA/io_s_axi_ar_*
log $CGRA/io_s_axi_r_*

# CGRA AXI4-Lite register port
log $CGRA/io_s_axilite_aw_*
log $CGRA/io_s_axilite_w_*
log $CGRA/io_s_axilite_b_*
log $CGRA/io_s_axilite_ar_*
log $CGRA/io_s_axilite_r_*
