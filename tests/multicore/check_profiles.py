#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Cross-language policy, elaborated defaults and Linux DT consistency checks."""

import argparse
import copy
import hashlib
import json
import os
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'config/multicore'))
sys.path.insert(0, str(ROOT / 'linux/smp'))
import profiles  # noqa: E402 -- repository-local scripts share the policy module
from devicetree import generate, verify_images  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    if 'WALLY' not in os.environ:
        parser.error('Source ./setup.sh first')
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    summary = work / 'results.json'
    summary.unlink(missing_ok=True)
    profiles.check_generated()
    original_header = profiles.HEADER
    stale_header = work / 'stale.vh'
    stale_header.write_text(original_header.read_text() + '// stale\n')
    try:
        profiles.HEADER = stale_header
        try:
            profiles.check_generated()
        except ValueError:
            pass
        else:
            raise AssertionError('Stale generated policy was accepted')
    finally:
        profiles.HEADER = original_header
    effective = profiles.probe('deriv/multicore_linux', profiles.resolve('linux-msi'), work / 'linux')
    rng = random.Random(20261021)
    mutations = {1: ('DCACHE_SUPPORTED', 1), 2: ('ZICBOM_SUPPORTED', 1), 3: ('SVADU_SUPPORTED', 1),
                 4: ('SVPBMT_SUPPORTED', 1), 5: ('AHBW', 32)}
    vectors = []
    for i in range(300):
        values = profiles.resolve('ci-msi')
        if i >= 6:
            for key in profiles.FIELDS:
                if profiles.FIELDS[key]['type'] == 'bit':
                    values[key] = rng.randrange(2)
                else:
                    values[key] = rng.choice([0, 1, 2, 3, 4, 8, 16, 32, 64, 4096])
        mutation = i if i < 6 else rng.randrange(6)
        core = dict(effective['core'])
        if mutation:
            key, value = mutations[mutation]
            core[key] = value
        expected = next((n for n, r in enumerate(profiles.SCHEMA['rules'], 1)
                         if not profiles.expression(r['when'], values, core)), 0)
        encoded = 0
        for key, spec in profiles.FIELDS.items():
            encoded = (encoded << (1 if spec['type'] == 'bit' else 32)) | values[key]
        vectors.append(f'{encoded:x} {mutation} {expected}\n')
    (work / 'vectors.txt').write_text(''.join(vectors))
    command = ['verilator', '--binary', '--assert', '-j', '2', '--top-module', 'policy_tb',
               '--Mdir', str(work / 'policy-model'), f'-I{ROOT}/config/shared', f'-I{ROOT}/config/deriv/multicore_linux',
               str(ROOT / 'src/cvw.sv'), str(ROOT / 'tests/multicore/policy_tb.sv')]
    with (work / 'policy-build.log').open('w') as stream:
        subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT)
    with (work / 'policy-run.log').open('w') as stream:
        subprocess.run([str(work / 'policy-model/Vpolicy_tb'), f'+vectors={work}/vectors.txt'], check=True,
                       stdout=stream, stderr=subprocess.STDOUT, timeout=30)
    # Generated SV defaults must agree with Python, including width-dependent 8 KiB defaults.
    cases = []
    for config, ahbw in [('rv32gc', 32), ('rv64gc', 64)]:
        item = profiles.probe(config, profiles.resolve(ahbw=ahbw), work / config, use_defaults=True)
        cases.append(item)
    for mode in ('shared', 'msi'):
        topology = profiles.resolve('linux-' + mode)
        item = profiles.probe('deriv/multicore_linux', topology, work / mode)
        dts = generate(**profiles.legacy_options(topology), effective=item)
        source = work / f'{mode}.dts'
        source.write_text(dts)
        subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', str(work / f'{mode}.dtb'), str(source)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # A changed RTL address/IRQ must change the generated tree, not retain a hardcoded value.
        changed = copy.deepcopy(item)
        changed['core'].update(UART_BASE=0x10001000, PLIC_UART_ID=6, PLIC_NUM_SRC=31)
        changed_dts = generate(**profiles.legacy_options(topology), effective=changed)
        assert 'serial@10001000' in changed_dts and 'interrupts = <6>' in changed_dts and 'riscv,ndev = <31>' in changed_dts
        for key, value in [('NCORES', 3), ('PRIVATE_ICACHE', 1)]:
            changed = copy.deepcopy(item)
            changed['multicore'][key] = value
            try:
                generate(**profiles.legacy_options(topology), effective=changed)
            except ValueError:
                pass
            else:
                raise AssertionError('DT/profile mismatch was accepted')
        fixture = work / ('images-' + mode)
        fixture.mkdir(exist_ok=True)
        (fixture / 'wally-smp.dts').write_text(dts)
        (fixture / 'wally-smp.dtb').write_bytes((work / f'{mode}.dtb').read_bytes())
        manifest = {'effective_configuration': item, **profiles.legacy_options(topology),
                    'sha256': {name: hashlib.sha256((fixture / name).read_bytes()).hexdigest()
                               for name in ('wally-smp.dts', 'wally-smp.dtb')}}
        verify_images(fixture, item, manifest)
        for mutation in ('manifest', 'rtl', 'dts', 'dtb'):
            altered = copy.deepcopy(manifest)
            current = copy.deepcopy(item)
            if mutation == 'manifest':
                altered['cache_words'] *= 2
            elif mutation == 'rtl':
                current['core']['PLIC_UART_ID'] = 6
            elif mutation == 'dts':
                (fixture / 'wally-smp.dts').write_text(dts.replace(f"interrupts = <{item['core']['PLIC_UART_ID']}>", 'interrupts = <0>'))
                altered['sha256']['wally-smp.dts'] = hashlib.sha256((fixture / 'wally-smp.dts').read_bytes()).hexdigest()
            else:
                (fixture / 'wally-smp.dtb').write_bytes(b'incompatible dtb')
                altered['sha256']['wally-smp.dtb'] = hashlib.sha256((fixture / 'wally-smp.dtb').read_bytes()).hexdigest()
            try:
                verify_images(fixture, current, altered)
            except ValueError:
                pass
            else:
                raise AssertionError(f'{mutation} mismatch was accepted')
            (fixture / 'wally-smp.dts').write_text(dts)
            (fixture / 'wally-smp.dtb').write_bytes((work / f'{mode}.dtb').read_bytes())
        cases.append(item)
    sources = [ROOT / 'config/multicore/schema.json', ROOT / 'config/multicore/profiles.py',
               ROOT / 'config/shared/multicore-config.vh', ROOT / 'config/shared/multicore-memory.vh',
               ROOT / 'tests/multicore/config_tb.sv', ROOT / 'tests/multicore/policy_tb.sv', Path(__file__)]
    summary.write_text(json.dumps({'verdict': 'PASS', 'vectors': len(vectors), 'configurations': cases,
                                  'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}, indent=2) + '\n')
    print('PASS: shared policy, RV32/RV64 profiles, Linux RTL/DT consistency and negative checks')


if __name__ == '__main__':
    main()
