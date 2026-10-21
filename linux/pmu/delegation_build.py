#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Build an isolated Linux image that probes direct S-mode counter delegation."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

from build import HERE, ROOT, hexfile, run

PROBE = r'''
/* Temporary integration probe: kernel perf still configures counters through SBI. */
static void __init wally_smcdeleg_probe(void)
{
    unsigned long select, inhibit, value, event, got, stopped;
    bool ok;

    select = csr_read(0x150);      /* siselect */
    inhibit = csr_read(0x120);     /* scountinhibit */
    csr_write(0x150, 0x43);       /* delegated mhpmcounter3 */
    value = csr_read(0x151);      /* sireg */
    event = csr_read(0x152);      /* sireg2 = mhpmevent3 */
    csr_write(0x120, inhibit | BIT(3));
    csr_write(0x152, 1);
    csr_write(0x151, 17);
    got = csr_read(0x151);
    stopped = csr_read(0x120);
    ok = got == 17 && csr_read(0x152) == 1 && (stopped & BIT(3));
    csr_write(0x152, event);
    csr_write(0x151, value);
    csr_write(0x120, inhibit);
    csr_write(0x150, select);
    if (ok)
        pr_info("WALLY_SMCDELEG_PASS direct_smode_counter_access\n");
    else
        pr_err("WALLY_SMCDELEG_FAIL direct_smode_counter_access got=%lu inhibit=%lu\n",
               got, stopped);
}

'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-work", type=Path, required=True)
    parser.add_argument("--kernel-source", type=Path, required=True)
    parser.add_argument("--cross-prefix", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--sampling", action="store_true", help="Boot the Sscofpmf perf record workload")
    args = parser.parse_args()
    base = args.base_work.resolve()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    base_manifest = json.loads((base / "manifest.json").read_text())
    if base_manifest["kind"] != "wally-native-single-core-pmu":
        parser.error("Base image is not the Wally PMU image")
    for name, digest in base_manifest["sha256"].items():
        if sha(base / name) != digest:
            parser.error(f"Base image digest mismatch: {name}")

    source = work / "kernel-source"
    if not source.exists():
        run(["cp", "-as", f"{args.kernel_source.resolve()}/.", source])
    driver = source / "drivers/perf/riscv_pmu_sbi.c"
    original = (args.kernel_source.resolve() / "drivers/perf/riscv_pmu_sbi.c").read_text()
    needle = 'static int pmu_sbi_device_probe(struct platform_device *pdev)\n'
    if original.count(needle) != 1:
        parser.error("Unexpected Linux PMU driver layout")
    patched = original.replace(needle, PROBE + needle).replace(
        'pr_info("SBI PMU extension is available\\n");',
        'pr_info("SBI PMU extension is available\\n");\n\twally_smcdeleg_probe();',
        1,
    )
    if driver.is_symlink() or driver.read_text() != patched:
        driver.unlink()
        driver.write_text(patched)

    for name, source_path in [
        ("perf", base / "perf-build/perf"),
        ("fw_jump.bin", base / "opensbi/platform/generic/firmware/fw_jump.bin"),
        ("boot.memfile", base / "boot.memfile"),
    ]:
        shutil.copy2(source_path, work / name)
    if args.sampling:
        for name, source_name in (("init", "sampling_init.c"), ("workload", "branch_workload.c")):
            run([args.cross_prefix + "gcc", "-O2", "-static", "-march=rv64imafdc_zicsr_zifencei",
                 "-mabi=lp64d", HERE / source_name, "-o", work / name])
    else:
        for name, source_path in (("init", base / "init"), ("workload", base / "workload")):
            shutil.copy2(source_path, work / name)
    cpio = work / "initramfs.list"
    cpio.write_text(
        "dir /dev 0755 0 0\ndir /proc 0755 0 0\ndir /sys 0755 0 0\n"
        "dir /tmp 1777 0 0\n"
        "nod /dev/console 0600 0 0 c 5 1\n"
        + "".join(f"file /{name} {work / name} 0755 0 0\n" for name in ("init", "workload", "perf"))
    )
    kout = work / "kernel"
    kout.mkdir(exist_ok=True)
    config_text = (HERE / "kernel.config").read_text() + f'\nCONFIG_INITRAMFS_SOURCE="{cpio}"\n'
    if not (kout / ".config").exists() or (kout / ".config").read_text() != config_text:
        (kout / ".config").write_text(config_text)
    env = {k: v for k, v in os.environ.items() if k not in ("LD_LIBRARY_PATH", "DEBUG")}
    command = ["make", "-C", source, f"O={kout}", "ARCH=riscv", f"CROSS_COMPILE={args.cross_prefix}"]
    run([*command, "olddefconfig"], env=env)
    for symbol in ("PERF_EVENTS", "RISCV_PMU", "RISCV_PMU_SBI"):
        if f"CONFIG_{symbol}=y" not in (kout / ".config").read_text():
            parser.error(f"Kernel did not enable {symbol}")
    run([*command, f"-j{args.jobs}", "Image"], env=env)

    dts = (ROOT / "linux/devicetree/wally-virt.dts").read_text()
    dts = re.sub(r'    linux,initrd-(?:end|start) = .*;\n', '', dts)
    # Kernel pr_info() messages use level 6 and need a console threshold > 6.
    dts = dts.replace('bootargs = "root=/dev/vda ro";', 'bootargs = "earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 loglevel=7 rdinit=/init";')
    dts = dts.replace('0x00 0x10000000>;', '0x00 0x08000000>;')
    dts = dts.replace('"zihpm";', '"zihpm", "sscofpmf", "smcntrpmf", "smcdeleg", "ssccfg", "sscsrind";')
    (work / "wally-pmu.dts").write_text(dts)
    run(["dtc", "-i", ROOT / "linux/devicetree", "-I", "dts", "-O", "dtb", "-o", work / "wally-pmu.dtb", work / "wally-pmu.dts"])

    ram = work / "ram.memfile"
    ram.write_text("")
    hexfile(work / "fw_jump.bin", ram)
    hexfile(kout / "arch/riscv/boot/Image", ram, 0x200000)
    hexfile(work / "wally-pmu.dtb", ram, 0x7000000)
    files = [ram, work / "boot.memfile", work / "wally-pmu.dtb", kout / "arch/riscv/boot/Image", kout / ".config", work / "fw_jump.bin", work / "init", work / "workload", work / "perf"]
    manifest = {
        "kind": "wally-native-single-core-pmu",
        "config": "pmu_deleg_linux",
        "counters": 32,
        "sampling": args.sampling,
        "delegation_probe": True,
        "sha256": {str(p.relative_to(work)): sha(p) for p in files},
        "kernel_release": subprocess.check_output([*map(str, command), "-s", "kernelrelease"], env=env, text=True).strip(),
        "base_manifest_sha256": sha(base / "manifest.json"),
        "probe_source_sha256": sha(driver),
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Delegated PMU Linux image ready: {work}", flush=True)


if __name__ == "__main__":
    main()
