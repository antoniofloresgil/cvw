# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate a Wally shared-cache SMP device tree; hart IDs are contiguous."""

import argparse
from pathlib import Path


def generate(cores, memory_mb=128, frequency=20000000, cache_words=256):
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
            next-level-cache = <&shared_cache>;
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
    model = "CORE-V Wally SMP with a shared physical cache";
    chosen {{
        stdout-path = "/soc/serial@10000000";
        bootargs = "earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 loglevel=4 rdinit=/init";
    }};
    memory@80000000 {{ device_type = "memory"; reg = <0 0x80000000 0 0x{memory_mb * 1024 * 1024:x}>; }};
    cpus {{
        #address-cells = <1>; #size-cells = <0>; timebase-frequency = <{frequency}>;
        {"".join(cpus)}
    }};
    shared_cache: cache {{
        compatible = "cache"; cache-level = <1>; cache-unified;
        cache-size = <{cache_words * 8}>; cache-line-size = <8>; cache-sets = <{cache_words}>;
    }};
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
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.cores <= 8:
        parser.error("This Linux configuration supports 1..8 harts")
    args.output.write_text(generate(args.cores))


if __name__ == "__main__":
    main()
