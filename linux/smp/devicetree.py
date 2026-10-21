# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate a Wally shared-cache or private-MSI SMP device tree; hart IDs are contiguous."""

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'config/multicore'))
import profiles


def generate(effective, memory_mb=None, frequency=None, **overrides):
    memory_mb = profiles.LINUX['ram_mb'] if memory_mb is None else memory_mb
    frequency = profiles.LINUX['frequency_hz'] if frequency is None else frequency
    values = effective['multicore']
    profiles.validate(values, effective['core'])
    options = profiles.legacy_options(values)
    for key, value in overrides.items():
        if key not in options or (value is not None and value != options[key]):
            raise ValueError('Device-tree options differ from the elaborated RTL profile')
    cores, cache_mode, cache_words = options['cores'], options['cache_mode'], options['cache_words']
    private_icache, icache_words = options['private_icache'], options['icache_words']
    cache_line_words, icache_line_words = options['cache_line_words'], options['icache_line_words']
    core = effective['core']
    if not 1 <= cores <= profiles.LINUX['max_harts'] or core['XLEN'] != 64 or not core['SV39_SUPPORTED']:
        raise ValueError('The Linux image flow requires RV64/Sv39 and 1..8 harts')
    if any(not core['MISA'] & (1 << (ord(letter)-ord('a'))) for letter in 'imafdc') or not (core['ZICSR_SUPPORTED'] and core['ZIFENCEI_SUPPORTED']):
        raise ValueError('Linux binaries require RV64IMAFDC, Zicsr and Zifencei')
    for device in ('UART', 'CLINT', 'PLIC', 'UNCORE_RAM'):
        if not core[device + '_SUPPORTED']:
            raise ValueError(f'Linux platform requires {device}')
    if memory_mb * 1024 * 1024 != core['UNCORE_RAM_RANGE'] + 1:
        raise ValueError('Device-tree RAM capacity differs from RTL')
    cache_words = values['PRIVATE_DCACHE_WORDS'] if cache_mode == 'msi' else values['SHARED_CACHE_WORDS']
    uart, ram, clint_base, plic_base = [core[k + '_BASE'] for k in ('UART', 'UNCORE_RAM', 'CLINT', 'PLIC')]
    extensions = [letter for letter in 'imafdc' if core['MISA'] & (1 << (ord(letter)-ord('a')))]
    for extension, field in [('zicsr', 'ZICSR_SUPPORTED'), ('zifencei', 'ZIFENCEI_SUPPORTED'), ('sstc', 'SSTC_SUPPORTED')]:
        if core[field]:
            extensions.append(extension)
    if not core['SVADU_SUPPORTED']:
        extensions.append('svade')
    if core['SVPBMT_SUPPORTED']:
        extensions.append('svpbmt')
    isa = 'rv64' + ''.join(e for e in extensions if len(e) == 1) + '_' + '_'.join(e for e in extensions if len(e) > 1)
    isa_extensions = ', '.join('"' + e + '"' for e in extensions)
    mmu = next('sv' + str(n) for n in (57, 48, 39, 32) if core['SV' + str(n) + '_SUPPORTED'])
    word_bytes = core['AHBW'] // 8
    private = cache_mode == "msi" and cores > 1
    cpu_cache = (f"d-cache-size = <{cache_words * word_bytes}>; d-cache-block-size = <{cache_line_words * word_bytes}>; d-cache-sets = <{cache_words // cache_line_words}>;"
                 if private else "next-level-cache = <&shared_cache>;" if cache_mode == "shared" else "")
    if private and private_icache:
        cpu_cache += f" i-cache-size = <{icache_words * word_bytes}>; i-cache-block-size = <{icache_line_words * word_bytes}>; i-cache-sets = <{icache_words // icache_line_words}>;"
    cache_node = f"""shared_cache: cache {{
        compatible = "cache"; cache-level = <1>; cache-unified;
        cache-size = <{cache_words * word_bytes}>; cache-line-size = <{word_bytes}>; cache-sets = <{cache_words}>;
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
            riscv,isa = "{isa}";
            riscv,isa-base = "rv64i";
            riscv,isa-extensions = {isa_extensions};
            mmu-type = "riscv,{mmu}"; clock-frequency = <{frequency}>;
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
        stdout-path = "/soc/serial@{uart:x}";
        bootargs = "earlycon=uart8250,mmio,0x{uart:x} console=ttyS0,115200 loglevel=4 rdinit=/init";
    }};
    memory@{ram:x} {{ device_type = "memory"; reg = <{ram >> 32} 0x{ram & 0xffffffff:x} 0 0x{memory_mb * 1024 * 1024:x}>; }};
    cpus {{
        #address-cells = <1>; #size-cells = <0>; timebase-frequency = <{frequency}>;
        {"".join(cpus)}
    }};
    {cache_node}
    soc {{
        #address-cells = <2>; #size-cells = <2>; compatible = "simple-bus"; ranges;
        serial@{uart:x} {{
            compatible = "ns16550a"; reg = <{uart >> 32} 0x{uart & 0xffffffff:x} 0 0x{core['UART_RANGE']+1:x}>;
            clock-frequency = <{frequency}>; current-speed = <115200>;
            interrupt-parent = <&plic>; interrupts = <{core['PLIC_UART_ID']}>;
        }};
        clint@{clint_base:x} {{
            compatible = "sifive,clint0", "riscv,clint0";
            reg = <{clint_base >> 32} 0x{clint_base & 0xffffffff:x} 0 0x{core['CLINT_RANGE']+1:x}>; interrupts-extended = <{clint}>;
        }};
        plic: interrupt-controller@{plic_base:x} {{
            compatible = "sifive,plic-1.0.0", "riscv,plic0";
            reg = <{plic_base >> 32} 0x{plic_base & 0xffffffff:x} 0 0x{core['PLIC_RANGE']+1:x}>;
            interrupt-controller; #interrupt-cells = <1>; #address-cells = <0>;
            riscv,ndev = <{core['PLIC_NUM_SRC']}>; interrupts-extended = <{plic}>;
        }};
    }};
}};
"""


def verify_images(work, effective, manifest):
    """Reject independently stale RTL, manifest, DTS, DTB and image artifacts."""
    if manifest.get('effective_configuration') != effective:
        raise ValueError('Elaborated RTL configuration differs from image manifest; regenerate images')
    options = profiles.legacy_options(effective['multicore'])
    if any(manifest.get(k) != v for k, v in options.items()):
        raise ValueError('Image metadata differs from effective topology')
    for name, digest in manifest['sha256'].items():
        if hashlib.sha256((work / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f'Image manifest mismatch: {name}')
    if (work / 'wally-smp.dts').read_text() != generate(**options, effective=effective):
        raise ValueError('Device tree differs from effective RTL configuration; regenerate images')
    checked_dtb = work / 'configuration/checked.dtb'
    checked_dtb.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', str(checked_dtb), str(work / 'wally-smp.dts')], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if checked_dtb.read_bytes() != (work / 'wally-smp.dtb').read_bytes():
        raise ValueError('DTB differs from effective device-tree source; regenerate images')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    profiles.add_arguments(parser, default='linux-shared', linux=True)
    parser.add_argument('--work-dir', type=Path, required=True, help='Configuration model and logs')
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        values = profiles.from_args(args, linux=True)
        effective = profiles.probe('deriv/multicore_linux', values, args.work_dir)
        args.output.write_text(generate(**profiles.legacy_options(values), effective=effective))
    except ValueError as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
