# SPEC CPU 2026 on the FPGA Linux: first benchmark on the board

Date: 2026-11-14. Branch `spec-linux`. Question: does a SPEC CPU 2026 binary (static rv64gc, built on a PC with Debian trixie GCC 14, glibc 2.41) run on Wally's Linux
on the Nexys Video, and is its output correct?

## Setup

- Bitstream: the Vivado `fpganexysvideo` build of 2026-10-20 (`/datos/cvw-artifacts/nexysvideo-vivado-20261020/fpgaTop.bit`, base revision `82d0b80f`), 20 MHz,
  programmed with `openFPGALoader -b nexysVideo`. Linux boots from the SD image of 2026-10-15 (kernel 6.19.14, OpenSBI 1.8.1 announces the PMU extension).
- That image has **no `perf`** and its kernel has no `PERF_EVENTS` (`/sys/bus/event_source` does not exist), so no counters were read. A new image with both
  (`wally_defconfig`, Buildroot 2026.02.3) was built on the PC the same day and is not yet on the SD card.
- The binary (777.zstd_r, stripped, 1 MB) went up through the console UART with `linux/spec/uart-upload.py`, into `/tmp` (the root file system is an initramfs in RAM, 503 MB total).

## Observations

- UART transfer: the UART has no FIFO. At 16 bytes per burst characters were lost or doubled; at 2 bytes per millisecond about one error per 20 KB remained, so each 8 KB
  chunk is checked with md5sum and resent: 25 retries in 100 chunks, 800 KB (gzip + base64) in 16 minutes. The gzip's sha256 on the board equals the PC's.
- `./zstd -b3 --verbose -i1` (the `test` workload; 10 MB of generated text, no input file): exit status 0, **2 min 54 s** wall (165.4 s user, 7.6 s system, 99 % CPU),
  maximum resident set 31 MB, 7,625 minor page faults, 872 involuntary context switches.
- The output is identical to SPEC's `data/test/output/zstd.b3_verbose_i1.out` (last checksum `ad7d1279`, 2,985,407 bytes compressed, ratio 3.350). The MB/s lines in that file are fixed
  by SPEC's modification of zstd, they are not measurements.

## Limits and next steps

- Not measured: any hardware counter (needs the new image on the SD card), the other benchmarks, the multiplexing of events.
- Upload by UART is only for files of a few hundred KB; larger binaries and inputs go on the SD card.
- Next: flash the new image, check `perf stat -e cycles,instructions true`, run `perf-run.sh` on zstd, sqlite, sealcrypto, then the rest that fit in 512 MiB.
