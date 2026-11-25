#!/bin/bash
#SBATCH --job-name=wally-image
#SBATCH --partition=erc-all
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=2G
#SBATCH --time=1:00:00
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Apptainer image for Wally's Verilator simulations on the cluster: Verilator's own Docker image of the version
# the PC uses, pinned by digest (SIF, DIGEST come from cluster.sh).  The host (glibc 2.27) has no Verilator, so the
# simulator is built and run inside this image.
set -euo pipefail
: "${SIF:?SIF}" "${DIGEST:?DIGEST}"
export PATH=$HOME/opt/apptainer-el7/bin:$PATH
export APPTAINER_CACHEDIR=$HOME/.apptainer/cache APPTAINER_TMPDIR=${TMPDIR:-/tmp}/apptainer-$SLURM_JOB_ID
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$(dirname "$SIF")"
trap 'rm -rf "$APPTAINER_TMPDIR" "$SIF.new"' EXIT
echo "== $(date -Is) host=$(hostname) pulling verilator/verilator@$DIGEST"
apptainer pull -F "$SIF.new" "docker://verilator/verilator@$DIGEST"
apptainer exec --cleanenv "$SIF.new" sh -c 'verilator --version; make --version | head -n 1; g++ --version | head -n 1; perl -v | sed -n 2p'
mv "$SIF.new" "$SIF"
echo "IMAGE OK $SIF $(sha256sum "$SIF" | cut -c1-16)"
