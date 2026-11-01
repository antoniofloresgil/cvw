#!/bin/bash
###########################################
## LiteX installation script.
##
## Purpose: Install LiteX and LiteDRAM in a dedicated Python virtual environment.
##          The open-source FPGA flow uses LiteX to generate the LiteDRAM DDR3
##          controller and PHY for boards with external DRAM (no Vivado MIG).
##
## A component of the CORE-V-WALLY configurable RISC-V project.
## https://github.com/openhwfoundation/cvw
##
## SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
##
## Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
## except in compliance with the License, or, at your option, the Apache License version 2.0. You
## may obtain a copy of the License at
##
## https://solderpad.org/SHL-2.1/
##
## Unless required by applicable law or agreed to in writing, any work distributed under the
## License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
## either express or implied. See the License for the specific language governing permissions
## and limitations under the License.
################################################################################################

# Pinned commits. LiteX emits different gateware between releases, so the
# generator must be pinned for the open-source flow to be reproducible.
MIGEN_VERSION=4c2ae8dfeea37f235b52acb8166f12acaaae4f7c
LITEX_VERSION=8c01073afb71aa0a0709f02f8e24247589e8f5e4
LITEDRAM_VERSION=74522f715d7b10163ef6f6caa09887a90874be83
LITEETH_VERSION=e3ebe03be76f33e0c2b2a024a1d0f19c99b7e96a
LITEX_BOARDS_VERSION=10debf146d433ce8ac8aedcac84e97d252ff4d5b
VEXRISCV_DATA_VERSION=1.0.1.post407
PICOLIBC_DATA_VERSION=6a13ccce7c575b32c102dd9dc52178505b81fe39
COMPILER_RT_DATA_VERSION=0.0.post6206
LITEX_VERSION_SET="$LITEX_VERSION+$MIGEN_VERSION+$LITEDRAM_VERSION+$LITEETH_VERSION+$LITEX_BOARDS_VERSION+$VEXRISCV_DATA_VERSION+$PICOLIBC_DATA_VERSION+$COMPILER_RT_DATA_VERSION"

set -e # break on error
# If run standalone, check environment. Otherwise, use info from main install script
if [ -z "$FAMILY" ]; then
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WALLY="$(dirname $(dirname "$dir"))"
    export WALLY
    source "${dir}"/../wally-environment-check.sh
fi

# LiteX (https://github.com/enjoy-digital/litex)
# LiteX is a Python-based SoC/controller generator. Wally only consumes the
# LiteDRAM DDR3 controller/PHY, so a minimal set of repositories is installed:
# migen, litex, litedram, and litex-boards (board descriptors). Liteeth is the
# DDR3 PHY's only extra dependency. CPU cores would additionally need the
# pythondata-cpu-* packages.
section_header "Installing/Updating LiteX"
STATUS="litex"
cd "$RISCV"
if check_tool_version "$LITEX_VERSION_SET"; then
    # Dedicated virtual environment so LiteX's Python dependencies do not
    # conflict with the system Python or the rest of the toolchain.
    if [ ! -d "$RISCV/litex-venv" ]; then
        python3 -m venv "$RISCV/litex-venv"
    fi
    "$RISCV/litex-venv/bin/pip" install --upgrade pip 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]

    # Fetch the pinned sources. Non-editable installs are used because the
    # editable (PEP 660) install of packages whose name matches their repository
    # directory is unreliable with recent setuptools/Python.
    src="$RISCV/litex-venv/src"
    mkdir -p "$src"
    repos=(
        "migen|https://github.com/m-labs/migen.git|$MIGEN_VERSION"
        "litex|https://github.com/enjoy-digital/litex.git|$LITEX_VERSION"
        "litedram|https://github.com/enjoy-digital/litedram.git|$LITEDRAM_VERSION"
        "liteeth|https://github.com/enjoy-digital/liteeth.git|$LITEETH_VERSION"
        "litex-boards|https://github.com/litex-hub/litex-boards.git|$LITEX_BOARDS_VERSION"
    )
    for spec in "${repos[@]}"; do
        IFS='|' read -r repo url version <<< "$spec"
        # git_checkout changes the working directory, so return to the source root each time.
        cd "$src"
        git_checkout "$repo" "$url" "$version"
    done
    cd "$src"
    "$RISCV/litex-venv/bin/pip" install ./migen ./litex ./litedram ./liteeth ./litex-boards 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    # The standalone DDR core uses upstream firmware on a service CPU for
    # JEDEC initialization, PHY training, and its initial memory test.
    "$RISCV/litex-venv/bin/pip" install \
        "pythondata-cpu-vexriscv==$VEXRISCV_DATA_VERSION" \
        "pythondata-software-picolibc @ git+https://github.com/litex-hub/pythondata-software-picolibc.git@$PICOLIBC_DATA_VERSION" \
        "pythondata-software-compiler-rt==$COMPILER_RT_DATA_VERSION" \
        meson ninja 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]

    # LiteX derives the nextpnr chipdb filename from the full part name (e.g.
    # xc7a200t-sbg484), but the FPGA toolchain installs package-independent
    # chipdbs named after the die (xc7a200t.bin). Add the expected aliases.
    if [ -d "$RISCV/share/nextpnr/xilinx" ]; then
        [ -f "$RISCV/share/nextpnr/xilinx/xc7a100t.bin" ] && \
            ln -sf xc7a100t.bin "$RISCV/share/nextpnr/xilinx/xc7a100tcsg324.bin"
        [ -f "$RISCV/share/nextpnr/xilinx/xc7a200t.bin" ] && \
            ln -sf xc7a200t.bin "$RISCV/share/nextpnr/xilinx/xc7a200t-sbg484.bin"
    fi

    echo "$LITEX_VERSION_SET" > "$RISCV"/versions/$STATUS.version # Record installed version
    if [ "$clean" = true ]; then
        rm -rf "$RISCV/litex-venv/src"
    fi
    echo -e "${SUCCESS_COLOR}LiteX successfully installed/updated!${ENDC}"
else
    echo -e "${SUCCESS_COLOR}LiteX already up to date.${ENDC}"
fi
