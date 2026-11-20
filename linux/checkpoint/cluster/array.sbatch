#!/bin/bash
#SBATCH --job-name=wally-ckpt
#SBATCH --partition=erc-all
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=2G
#SBATCH --time=2:00:00
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# One Wally checkpoint per array task (1 CPU, 2 GB).  The checkpoints stay on the PC (they hold SPEC data): the task
# pulls only its own ram.bin, bootmem.bin and info.txt into node-local $TMPDIR with the read-only key (rrsync -ro on
# the PC), runs warm-up + interval as measure.py does, copies back only the logs and deletes the checkpoint.
# Task N = line N of $LIST, "<bench>/<interval>" relative to wally/ on the PC.  LIMIT overrides the instruction limit
# (whole-region references) and EXTRA adds plusargs (e.g. +HPM_PERIOD=10000000).
set -uo pipefail
: "${LIST:?LIST}" "${SIF:?SIF}" "${BIN:?BIN}" "${RES:?RES}"
: "${PC:?PC (user@address of the PC, from cluster.sh)}"; KEY=${KEY:-$HOME/.ssh/pc-cpt-ro}
export PATH=$HOME/opt/apptainer-el7/bin:$PATH
rel=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$LIST"); [ -n "$rel" ] || { echo "no line $SLURM_ARRAY_TASK_ID in $LIST"; exit 1; }
R=$RES/$rel
D=${TMPDIR:-/tmp}/wally-$SLURM_JOB_ID-$SLURM_ARRAY_TASK_ID
mkdir -p "$D" "$R"
trap 'rm -rf "$D"' EXIT
echo "== $(date -Is) host=$(hostname) task=$SLURM_ARRAY_TASK_ID $rel bin=$BIN"
[ -f "$R/DONE" ] && { echo "already done: $(cat "$R/DONE")"; exit 0; }
# up to 8 tries with a random pause: when many tasks start together the PC's sshd refuses some connections (MaxStartups)
ok=0
for try in 1 2 3 4 5 6 7 8; do
  rsync -e "ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20" -a \
    --include=ram.bin --include=bootmem.bin --include=info.txt --exclude='*' "$PC:wally/$rel/" "$D/" \
    && [ "$(stat -c %s "$D/ram.bin" 2>/dev/null)" = 268435456 ] && [ "$(stat -c %s "$D/bootmem.bin" 2>/dev/null)" = 4096 ] \
    && [ -s "$D/info.txt" ] && { ok=1; break; }   # whole files only (the RAM image and the BOOTROM of the buildroot configuration)
  echo "fetch try $try failed, retrying"; sleep $(( 10 + RANDOM % 50 ))
done
[ $ok = 1 ] || { echo "FETCH FAILED"; exit 2; }
W=$(awk '$1 == "warmup" {print $2}' "$D/info.txt"); I=$(awk '$1 == "interval" {print $2}' "$D/info.txt")
LIMIT=${LIMIT:-$((W + I))}
ARGS="+TEST=buildroot +LinuxRam=$D/ram.bin +LinuxBootmem=$D/bootmem.bin +INSTR_LIMIT=$LIMIT +UART_LOG_FILE=$D/uart.out"
[ "$W" -gt 0 ] && ARGS+=" +HPM_WARMUP=$W"
ARGS+=" ${EXTRA:-}"
echo "fetched $(stat -c %s "$D/ram.bin") bytes; $ARGS"
cd "$D"
/usr/bin/time -v -o "$D/time.log" apptainer exec --cleanenv --bind "$D" "$SIF" "$BIN/Vtestbench" $ARGS > "$D/wsim.log" 2>&1
rc=$?
cp "$D/wsim.log" "$D/uart.out" "$D/time.log" "$R/" 2>/dev/null
grep -E "Elapsed|Maximum resident" "$D/time.log"
# the verdict is the testbench's own counter line at the limit, not the exit code or Slurm's state
if grep -q "^HPM $LIMIT " "$D/wsim.log"; then
  echo "$(date -Is) $(hostname) limit $LIMIT reached" > "$R/DONE"; echo "OK"; exit 0
fi
echo "NO HPM LINE AT $LIMIT (rc=$rc)"; tail -n 5 "$D/wsim.log"; exit 3
