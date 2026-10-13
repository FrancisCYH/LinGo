#!/usr/bin/env bash
# LinGo CGRA simulation: waveform logging on CGRA internals.
# Runs from the directory containing the Questa work library; waveforms go
# to vsim.wlf, log to sim_lingo.log. First argument: ELF path
# (default: the gemm kernel test).
set -euo pipefail
cd "$(dirname "$0")"

vsim -c -t 1ps tb_cheshire_top_lingo \
  -voptargs="-O5 +acc=p+tb_cheshire_top_lingo. +acc=r+i_lingo_cgra. -permissive" \
  +BOOTMODE=0 +PRELMODE=3 \
  +BINARY="${1:-../sw/tests/lingo_gemm.dram.elf}" \
  -suppress 3009 -suppress 8386 -error 7 -cpppath "$(which g++)" \
  -do "do run_lingo.do" | tee sim_lingo.log
