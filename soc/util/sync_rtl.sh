#!/usr/bin/env bash
# Sync generated LinGo hardware artifacts into soc/.
#   ../hardware/verilog/clean.v            -> rtl/lingo/LinGoWithAXI.v
#   ../hardware/verilog/lingo-spec/*.json  -> spec/
# Run after `bash genRTL.sh` in ../hardware. Never edit the copies by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

HW_VERILOG=../hardware/verilog

install -D -m 644 "$HW_VERILOG/clean.v" rtl/lingo/LinGoWithAXI.v
install -D -m 644 "$HW_VERILOG/lingo-spec/lingo_spec.json"    spec/lingo_spec.json
install -D -m 644 "$HW_VERILOG/lingo-spec/axilite_spec.json"  spec/axilite_spec.json
install -D -m 644 "$HW_VERILOG/lingo-spec/lingo_adg.json"     spec/lingo_adg.json

echo "synced LinGoWithAXI.v and lingo-spec JSONs from $HW_VERILOG"
