# Two harts on the Nexys Video (Vivado)

`fpganexysvideosmp` (`config/derivlist.txt`) is the Nexys Video configuration with the SoC's multicore memory system:
two harts, a private MSI data cache and a private instruction cache per hart, cache-to-cache transfers and pipelined
cache-line bursts to the DDR3 (`src/ebu/ahbmsicache.sv`, `ahbmulticore.sv`). The core's own caches are off.

## Build

The multicore parameters are module parameters of the SoC, not `config.vh` settings: the Nexys boards' top
(`fpga/src/fpgaTopNexysA7.sv`) passes them on, and `SOCGENERICS` sets them as Vivado generics. `NHARTS` makes the ZSBL
wake the other harts (`fpga/zsbl/bios.S`: harts other than 0 wait for a software interrupt); `NO_ILA=1` leaves the
logic analyzer out, whose probes name single-core nets.

```bash
cd fpga/generator
make nexysvideo VIVADOCONFIG=fpganexysvideosmp NHARTS=2 NO_ILA=1 \
  SOCGENERICS="NCORES=2 PRIVATE_DCACHE=1'b1 PRIVATE_ICACHE=1'b1 LOCAL_DCACHE_READS=1'b1 LOCAL_DCACHE_WRITES=1'b1 \
  CACHE_TO_CACHE=1'b1 CACHE_BURSTS=1'b1 COHERENCE_BANKS=2 PRIVATE_DCACHE_WORDS=1024 PRIVATE_ICACHE_WORDS=1024 \
  PRIVATE_DCACHE_LINE_WORDS=4 PRIVATE_ICACHE_LINE_WORDS=4"
```

With 8 KiB private D- and I-caches per hart the build takes 90.6k LUT (68 %) and 57 block RAMs and meets 20 MHz
(WNS +0.54 ns, 2026-11-24). The caches' data are in block RAM and their tags in LUT RAM
([ADR 0025](engineering/decisions/0025-multicore-caches-in-block-ram.md)); before that, the arrays were flip-flops
and multiplexers, and even 512-byte caches took 114k LUT (8 KiB needed 514k).

## SD card

The board's Buildroot kernel is built without SMP. Copy its tree and turn SMP on (here from a Buildroot output in
`/datos/tmp/br-spec`):

```bash
K=/datos/tmp/br-smp-kernel; cp -a <buildroot output>/build/linux-6.19.14 $K; cd $K
./scripts/config --enable SMP --set-val NR_CPUS 8 --disable HOTPLUG_CPU \
  --disable HZ_250 --enable HZ_100 --set-val HZ 100 --set-str INITRAMFS_SOURCE <buildroot output>/images/rootfs.cpio
make ARCH=riscv CROSS_COMPILE=<buildroot output>/host/bin/riscv64-buildroot-linux-gnu- olddefconfig Image modules
linux/smp/board/build.sh <buildroot output> $K/arch/riscv/boot/Image <out dir> <out dir>/sd-smp.img
```

**`HZ=100` was required with 512-byte caches.** With the board kernel's `HZ=250` (a tick every 80,000 cycles at
20 MHz) both harts spent all their time in the timer tick with those small caches, and the boot stops after the unaligned-access probe with
`watchdog: BUG: soft lockup - CPU#0 stuck`. Linux SMP on the RTL with the board's SoC parameters shows the same
(`linux/smp/run.py`, 2026-11-24): `HZ=250` alone hangs, the board kernel's other options (`NO_HZ_IDLE`, the
unaligned-access probe, the soft-lockup detector) with `HZ=100` reach `WALLY_SMP_PASS` after 495 M cycles.

On the board, as root: `sh /mnt/d/stage/run.sh` lists the harts Linux brought up and runs `smpcheck`
(`linux/smp/board/smpcheck.c`): exact totals of an `amoadd` counter, an LR/SC spin lock and a token passed through
plain loads and stores between the two harts, then the DDR3 read, write and copy throughput of each hart alone and of
both at once. The ZSBL loads the card in about 7 minutes, as the core's caches are off.
