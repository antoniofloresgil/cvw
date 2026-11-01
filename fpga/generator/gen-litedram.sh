#!/bin/bash
###########################################
## gen-litedram.sh
##
## Purpose: Generate the LiteDRAM DDR3 controller/PHY Verilog used by the
##          CORE-V-Wally open-source FPGA flow.  Replaces Vivado's MIG so the
##          whole design can be built with Yosys and nextpnr-xilinx.
##
## A component of the CORE-V-WALLY configurable RISC-V project.
## https://github.com/openhwfoundation/cvw
##
## SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
################################################################################################

set -e

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$dir/opensource-litedram"

if [ -z "$LITEX_VENV" ]; then
    echo "Error: LITEX_VENV is not set. Source setup.sh and install LiteX with" >&2
    echo "bin/wally-tool-chain-install.sh (or bin/installation/litex-install.sh)." >&2
    exit 1
fi

PATH="$LITEX_VENV/bin:$PATH" "$LITEX_VENV/bin/python" "$dir/gen_litedram.py" --output-dir "$out" "$@"

# The open-source flow builds from CopiedFiles_do_not_add_to_repo; stage the
# generated gateware there when that tree exists.
dest="$dir/../src/CopiedFiles_do_not_add_to_repo"
if [ -d "$dest" ]; then
    cp "$out/litedram_ddr.v"   "$dest/"
    cp "$out/litedram_ddr.xdc" "$dest/"
fi

echo "LiteDRAM gateware generated in $out"
