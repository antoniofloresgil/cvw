#!/bin/bash
#SBATCH --job-name=wally-build
#SBATCH --partition=erc-all
#SBATCH --cpus-per-task=8
#SBATCH --mem-per-cpu=2G
#SBATCH --time=2:00:00
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Builds Wally's buildroot simulator (Verilator) inside the image from the sources cluster.sh copied to $SRC, and
# installs it as $BIN/Vtestbench (a new directory per source hash, so a running array never sees its binary change).
set -euo pipefail
: "${SIF:?SIF}" "${SRC:?SRC}" "${BIN:?BIN}"
export PATH=$HOME/opt/apptainer-el7/bin:$PATH
echo "== $(date -Is) host=$(hostname) src=$SRC"
[ -x "$BIN/Vtestbench" ] && { echo "BUILD OK (already built) $BIN/Vtestbench"; exit 0; }
/usr/bin/time -v -o "$SRC/build-time.log" \
  apptainer exec --cleanenv --env WALLY="$SRC" "$SIF" \
  make -C "$SRC/sim/verilator" WALLYCONF=buildroot TESTBENCH=testbench JOBS="${SLURM_CPUS_PER_TASK:-8}"
grep -E "Elapsed|Maximum resident" "$SRC/build-time.log"
mkdir -p "$BIN.new"
cp "$SRC/sim/verilator/wkdir/buildroot_testbench/Vtestbench" "$BIN.new/"
mv "$BIN.new" "$BIN"
echo "BUILD OK $BIN/Vtestbench $(sha256sum "$BIN/Vtestbench" | cut -c1-16)"
