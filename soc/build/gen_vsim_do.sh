#!/usr/bin/env bash
# Regenerate lingo.vsim.do: bender-generated compile script + the DPI elf
# loader (elfloader.cpp is C++, not tracked by bender).
set -e
cd "$(dirname "$0")"

bender --dir .. script vsim \
    -t sim -t test -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb -t lingo \
    --vlog-arg="-sv -timescale 1ns/1ps" > lingo.vsim.do
echo "vlog \"../cheshire/target/sim/src/elfloader.cpp\" -ccflags \"-std=c++11\" -cpppath \"$(which g++)\"" >> lingo.vsim.do
