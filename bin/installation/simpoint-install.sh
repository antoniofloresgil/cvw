#!/bin/bash
###########################################
## Tool chain install script.
##
## Written: Antonio Flores Gil
## Created: November 19 2026
## Modified:
##
## Purpose: SimPoint installation script
##
## A component of the CORE-V-WALLY configurable RISC-V project.
## https://github.com/openhwfoundation/cvw
##
## Copyright (C) 2021-26 Harvey Mudd College & Oklahoma State University
##
## SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
##
################################################################################################

SIMPOINT_VERSION=3.2 # Last release (2006)
SIMPOINT_SHA256=ec86447ebc58966ed53d9291fa7e154b843ae24181aefed79cda3f1f0c09e132

set -e # break on error
# If run standalone, check environment. Otherwise, use info from main install script
if [ -z "$FAMILY" ]; then
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WALLY="$(dirname $(dirname "$dir"))"
    export WALLY
    source "${dir}"/../wally-environment-check.sh
fi

# SimPoint (https://cseweb.ucsd.edu/~calder/simpoint/)
# SimPoint picks the representative intervals of a program, and their weights, from its basic block vectors.
# Used by linux/checkpoint to sample SPEC runs. Only released as a tarball; its licence allows educational,
# non-profit and industry research use. The 2006 sources rely on headers that modern libstdc++ no longer pulls in
# and on C++98's stream-to-void* conversion, so they are compiled as C++98 with those headers forced in, unpatched.
section_header "Installing/Updating SimPoint"
STATUS="simpoint"
cd "$RISCV"
if check_tool_version $SIMPOINT_VERSION; then
    rm -rf SimPoint.$SIMPOINT_VERSION
    wget -nv --retry-connrefused $retry_on_host_error --output-document=simpoint.tar.gz \
        "https://cseweb.ucsd.edu/~calder/simpoint/releases/SimPoint.$SIMPOINT_VERSION.tar.gz"
    echo "$SIMPOINT_SHA256  simpoint.tar.gz" | sha256sum -c -
    tar xzf simpoint.tar.gz
    rm -f simpoint.tar.gz
    cd "$RISCV"/SimPoint.$SIMPOINT_VERSION
    make -C analysiscode simpoint CXX="g++ -std=c++98 -include iostream -include cstring -include cstdlib -include climits" \
        2>&1 | logger; [ "${PIPESTATUS[0]}" == 0 ]
    mkdir -p "$RISCV"/bin
    cp analysiscode/simpoint "$RISCV"/bin/simpoint
    if [ "$clean" = true ]; then
        cd "$RISCV"
        rm -rf SimPoint.$SIMPOINT_VERSION
    fi
    echo "$SIMPOINT_VERSION" > "$RISCV"/versions/$STATUS.version # Record installed version
    echo -e "${SUCCESS_COLOR}SimPoint successfully installed/updated!${ENDC}"
else
    echo -e "${SUCCESS_COLOR}SimPoint already up to date.${ENDC}"
fi
