# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate a Wally shared-cache or private-MSI SMP device tree; hart IDs are contiguous."""

import argparse
from pathlib import Path


def generate(cores, memory_mb=128, frequency=20000000, cache_words=256, cache_mode="shared", private_icache=False, icache_words=256, local_dcache_reads=False, local_dcache_writes=False):
    if cache_mode not in ("shared", "msi") or cache_words < 2 or cache_words & (cache_words - 1):
        raise ValueError("Expected shared/msi and a power-of-two cache capacity >= 2 words")
    if (private_icache or local_dcache_reads or local_dcache_writes) and cache_mode != "msi":
        raise ValueError("Private cache local paths require MSI mode")
    if icache_words < 2 or icache_words & (icache_words - 1):
        raise ValueError("I-cache capacity must be a power of two >= 2 words")
    private = cache_mode == "msi" and cores > 1
    cpu_cache = (f"d-cache-size = <{cache_words * 8}>; d-cache-block-size = <8>; d-cache-sets = <{cache_words}>;"
                 if private else "next-level-cache = <&shared_cache>;" if cache_mode == "shared" else "")
    if private and private_icache:
        cpu_cache += f" i-cache-size = <{icache_words * 8}>; i-cache-block-size = <8>; i-cache-sets = <{icache_words}>;"
    cache_node = f"""shared_cache: cache {{
        compatible = "cache"; cache-level = <1>; cache-unified;
        cache-size = <{cache_words * 8}>; cache-line-size = <8>; cache-sets = <{cache_words}>;
    }};""" if cache_mode == "shared" else ""
    model = "a shared physical cache" if cache_mode == "shared" else "private MSI data caches" if private else "uncached single-core execution"
    if private and private_icache:
        model += " and private instruction caches"
    cpus = []
    for hart in range(cores):
        cpus.append(f"""
        cpu@{hart:x} {{
            device_type = "cpu"; reg = <{hart}>; status = "okay";
            compatible = "riscv"; enable-method = "riscv,sbi";
            riscv,isa = "rv64imafdc_zicsr_zifencei_sstc_svade";
            riscv,isa-base = "rv64i";
            riscv,isa-extensions = "i", "m", "a", "f", "d", "c", "zicsr", "zifencei", "sstc", "svade";
            mmu-type = "riscv,sv39"; clock-frequency = <{frequency}>;
            {cpu_cache}
            cpu{hart}_intc: interrupt-controller {{
                compatible = "riscv,cpu-intc"; interrupt-controller;
                #interrupt-cells = <1>; #address-cells = <0>;
            }};
        }};""")
    clint = " ".join(f"&cpu{h}_intc 3 &cpu{h}_intc 7" for h in range(cores))
    plic = " ".join(f"&cpu{h}_intc 11 &cpu{h}_intc 9" for h in range(cores))
    return f"""/dts-v1/;
/ {{
    #address-cells = <2>; #size-cells = <2>;
    compatible = "openhwgroup,wally-smp", "riscv-virtio";
    model = "CORE-V Wally SMP with {model}";
    chosen {{
        stdout-path = "/soc/serial@10000000";
        bootargs = "earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 loglevel=4 rdinit=/init";
    }};
    memory@80000000 {{ device_type = "memory"; reg = <0 0x80000000 0 0x{memory_mb * 1024 * 1024:x}>; }};
    cpus {{
        #address-cells = <1>; #size-cells = <0>; timebase-frequency = <{frequency}>;
        {"".join(cpus)}
    }};
    {cache_node}
    soc {{
        #address-cells = <2>; #size-cells = <2>; compatible = "simple-bus"; ranges;
        serial@10000000 {{
            compatible = "ns16550a"; reg = <0 0x10000000 0 0x100>;
            clock-frequency = <{frequency}>; current-speed = <115200>;
            interrupt-parent = <&plic>; interrupts = <10>;
        }};
        clint@2000000 {{
            compatible = "sifive,clint0", "riscv,clint0";
            reg = <0 0x02000000 0 0x10000>; interrupts-extended = <{clint}>;
        }};
        plic: interrupt-controller@c000000 {{
            compatible = "sifive,plic-1.0.0", "riscv,plic0";
            reg = <0 0x0c000000 0 0x{0x200000 + 2 * cores * 0x1000:x}>;
            interrupt-controller; #interrupt-cells = <1>; #address-cells = <0>;
            riscv,ndev = <14>; interrupts-extended = <{plic}>;
        }};
    }};
}};
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cores", type=int, default=2)
    parser.add_argument("--cache-mode", choices=["shared", "msi"], default="shared")
    parser.add_argument("--cache-words", type=int, default=256)
    parser.add_argument("--private-icache", action="store_true")
    parser.add_argument("--icache-words", type=int, default=256)
    parser.add_argument("--local-dcache-writes", action="store_true")
    parser.add_argument("--local-dcache-reads", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.cores <= 8:
        parser.error("This Linux configuration supports 1..8 harts")
    if args.cache_words < 2 or args.cache_words & (args.cache_words - 1):
        parser.error("--cache-words must be a power of two >= 2")
    args.output.write_text(generate(args.cores, cache_words=args.cache_words, cache_mode=args.cache_mode,
                                    private_icache=args.private_icache, icache_words=args.icache_words,
                                    local_dcache_reads=args.local_dcache_reads, local_dcache_writes=args.local_dcache_writes))


if __name__ == "__main__":
    main()
