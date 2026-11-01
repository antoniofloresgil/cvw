#!/bin/bash
###########################################
## Open-source FPGA toolchain installation
##
## Purpose: Install a Vivado-free Xilinx 7-series synthesis, place-and-route,
## bitstream generation, and programming toolchain.
##
## A component of the CORE-V-WALLY configurable RISC-V project.
## https://github.com/openhwfoundation/cvw
##
## SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
################################################################################################

OSS_CAD_SUITE_VERSION=2026-09-25
PRJXRAY_VERSION=c9f02d8576042325425824647ab5555b1bc77833
# openXC7 release 0.9.8. The older gatecat revision produced DDR3 bitstreams
# whose LiteDRAM reads always failed on the Nexys Video.
NEXTPNR_XILINX_VERSION=cbabb65139c3d82f0a05b670b5869e1b512b69e8
XC7_DEVICES=(xc7a100tcsg324-1 xc7a200tsbg484-1)
XC7_CHIPDBS=(xc7a100t xc7a200t)
XC7_DEVICE_SET=xc7a100t+xc7a200t

set -e # break on error

# If run standalone, check environment. Otherwise, use info from main install script.
if [ -z "$FAMILY" ]; then
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WALLY="$(dirname "$(dirname "$dir")")"
    export WALLY
    source "${dir}"/../wally-environment-check.sh
fi

case "$(uname -m)" in
    x86_64)
        OSS_CAD_SUITE_ARCH=linux-x64
        OSS_CAD_SUITE_SHA256=67eb8eb6a46b280419fb9f3a65eec792e9034e009cf7c2e933d9805b2a387533
        ;;
    aarch64 | arm64)
        OSS_CAD_SUITE_ARCH=linux-arm64
        OSS_CAD_SUITE_SHA256=c8cabe35a3d0719aeebf59bf7049d77918f0e61afc13f50c761cfeb122f802fd
        ;;
    *)
        echo -e "${FAIL_COLOR}OSS CAD Suite does not provide a Linux build for $(uname -m).${ENDC}"
        return 1
        ;;
esac

# OSS CAD Suite supplies compatible builds of Yosys, the yosys-slang
# SystemVerilog frontend, Slang, and openFPGALoader.
STATUS="oss-cad-suite"
if check_tool_version "$OSS_CAD_SUITE_VERSION"; then
    section_header "Installing/Updating OSS CAD Suite"
    cd "$RISCV"
    archive="oss-cad-suite-${OSS_CAD_SUITE_ARCH}-${OSS_CAD_SUITE_VERSION//-/}.tgz"
    wget -nv --retry-connrefused $retry_on_host_error \
        "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_VERSION}/${archive}"
    printf '%s  %s\n' "$OSS_CAD_SUITE_SHA256" "$archive" | sha256sum --check
    rm -rf "$RISCV/oss-cad-suite"
    tar xzf "$archive" -C "$RISCV"
    rm -f "$archive"
    echo "$OSS_CAD_SUITE_VERSION" > "$RISCV/versions/$STATUS.version"
    echo -e "${SUCCESS_COLOR}OSS CAD Suite successfully installed/updated!${ENDC}"
else
    echo -e "${SUCCESS_COLOR}OSS CAD Suite already up to date.${ENDC}"
fi
export PATH="$RISCV/oss-cad-suite/bin:$PATH"

# Project X-Ray converts nextpnr's FASM output into a Xilinx 7-series bitstream.
STATUS="prjxray"
if check_tool_version "$PRJXRAY_VERSION"; then
    section_header "Installing/Updating Project X-Ray"
    cd "$RISCV"
    git_checkout "prjxray" "https://github.com/f4pga/prjxray" "$PRJXRAY_VERSION"
    cd "$RISCV/prjxray"
    git submodule update --init --recursive
    # Older X-Ray headers rely on transitive stdint includes removed by GCC 15.
    cmake -S . -B build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_CXX_FLAGS="-include cstdint" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$RISCV"
    cmake --build build --target xc7frames2bit --parallel "$NUM_THREADS" 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    install -Dm755 build/tools/xc7frames2bit "$RISCV/bin/xc7frames2bit"

    rm -rf "$RISCV/share/prjxray/venv"
    python3 -m venv "$RISCV/share/prjxray/venv"
    "$RISCV/share/prjxray/venv/bin/python" -m pip install \
        "$RISCV/prjxray/third_party/fasm" -e "$RISCV/prjxray" 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    ln -vsf "$RISCV/share/prjxray/venv/bin/fasm2frames" "$RISCV/bin/fasm2frames"
    echo "$PRJXRAY_VERSION" > "$RISCV/versions/$STATUS.version"
    echo -e "${SUCCESS_COLOR}Project X-Ray successfully installed/updated!${ENDC}"
else
    echo -e "${SUCCESS_COLOR}Project X-Ray already up to date.${ENDC}"
fi

# nextpnr-xilinx includes the Project X-Ray databases and metadata used to
# generate device-specific chip databases for the supported Artix-7 boards.
STATUS="nextpnr-xilinx"
if check_tool_version "$NEXTPNR_XILINX_VERSION-$XC7_DEVICE_SET"; then
    section_header "Installing/Updating nextpnr-xilinx"
    cd "$RISCV"
    git_checkout "nextpnr-xilinx-openxc7" "https://github.com/openXC7/nextpnr-xilinx" "$NEXTPNR_XILINX_VERSION"
    cd "$RISCV/nextpnr-xilinx-openxc7"
    # The placer lets flip-flops share a half-slice with LUT-RAM of the other
    # clock polarity (Wally's negedge register file), which fasm then rejects.
    git apply "$WALLY/bin/installation/nextpnr-xilinx-lutram-clkinv.patch"
    git submodule update --init --recursive
    cmake -S . -B build \
        -DARCH=xilinx \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_CXX_FLAGS="-include cstdint" \
        -DBUILD_GUI=OFF \
        -DBUILD_PYTHON=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$RISCV"
    cmake --build build --target bbasm --parallel "$NUM_THREADS" 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    mkdir -p "$RISCV/share/nextpnr/xilinx" "$RISCV/share/prjxray/database"
    for i in "${!XC7_DEVICES[@]}"; do
        "$RISCV/share/prjxray/venv/bin/python" xilinx/python/bbaexport.py \
            --device "${XC7_DEVICES[$i]}" \
            --bba "xilinx/${XC7_CHIPDBS[$i]}.bba" 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
        build/bbasm --l "xilinx/${XC7_CHIPDBS[$i]}.bba" "$RISCV/share/nextpnr/xilinx/${XC7_CHIPDBS[$i]}.bin"
    done
    cmake --build build --parallel "$NUM_THREADS" 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    cmake --install build 2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    rsync -a --delete xilinx/external/prjxray-db/artix7/ "$RISCV/share/prjxray/database/artix7/"
    echo "$NEXTPNR_XILINX_VERSION-$XC7_DEVICE_SET" > "$RISCV/versions/$STATUS.version"
    if [ "$clean" = true ]; then
        rm -rf "$RISCV/prjxray/build" "$RISCV/nextpnr-xilinx-openxc7"
    fi
    echo -e "${SUCCESS_COLOR}nextpnr-xilinx and the Artix-7 chip databases successfully installed/updated!${ENDC}"
else
    echo -e "${SUCCESS_COLOR}nextpnr-xilinx already up to date.${ENDC}"
fi

export XRAY_DATABASE_DIR="$RISCV/share/prjxray/database/artix7"
export NEXTPNR_XILINX_CHIPDB="$RISCV/share/nextpnr/xilinx/xc7a100t.bin"
export NEXTPNR_XILINX_CHIPDB_XC7A100T="$RISCV/share/nextpnr/xilinx/xc7a100t.bin"
export NEXTPNR_XILINX_CHIPDB_XC7A200T="$RISCV/share/nextpnr/xilinx/xc7a200t.bin"
