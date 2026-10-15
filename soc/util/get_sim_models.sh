#!/usr/bin/env bash
# Download the (partially non-free) VIP device models needed to compile
# cheshire's vip_cheshire_soc.sv, mirroring the targets in cheshire.mk.
# They are not tracked in cheshire's git; upstream downloads them on demand.
set -e
cd "$(dirname "$0")/.."
MODELS=cheshire/target/sim/models
mkdir -p "$MODELS"

wget --no-check-certificate \
    https://freemodelfoundry.com/fmf_vlog_models/flash/s25fs512s.v \
    -O "$MODELS/s25fs512s.v"

wget https://ww1.microchip.com/downloads/en/DeviceDoc/24xx1025_Verilog_Model.zip
unzip -p 24xx1025_Verilog_Model.zip 24FC1025.v > "$MODELS/24FC1025.v"
rm 24xx1025_Verilog_Model.zip
