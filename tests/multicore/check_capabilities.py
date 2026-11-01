#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check honest capability metadata, requirement rejection and the full-core guard."""

import argparse
import copy
import hashlib
import json
import os
import resource
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'config/multicore'))
import profiles  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    if 'WALLY' not in os.environ:
        parser.error('Source ./setup.sh first')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    summary = work / 'results.json'
    summary.unlink(missing_ok=True)
    reports = []
    for profile, overrides, path in [
        ('default', {}, 'native_single_hart'), ('stress', {'NCORES': 3}, 'uncached_serialized'),
        ('linux-shared', {'NCORES': 1}, 'shared_write_through'), ('ci-msi', {}, 'private_write_back'),
        ('ci-mesi-banked', {}, 'private_write_back'), ('linux-msi', {'NCORES': 1}, 'native_single_hart')]:
        values = profiles.resolve(profile, **overrides)
        report = profiles.capability_report(values)
        assert report['path'] == path
        assert report['qualification']['fpga_multicore'] == 'unverified'
        assert report['qualification']['simulation_evidence'] == 'per_revision_case_configuration_and_test'
        for name in ('external_dma_coherence', 'precise_cpu_bus_errors', 'fpga_multicore_qualified', 'arbitrary_hart_count_qualified'):
            try:
                profiles.require_capabilities(values, [name])
            except ValueError as error:
                assert name in str(error)
            else:
                raise AssertionError(f'Unsupported/unverified capability accepted: {name}')
        if path != 'native_single_hart':
            profiles.require_capabilities(values, ['coherent_hart_ports'])
        else:
            assert report['requirements']['coherent_hart_ports']['status'] == 'outside_scope'
        profiles.check_capability_report({'multicore': values, 'capabilities': report})
        false_claim = copy.deepcopy(report)
        false_claim['requirements']['external_dma_coherence']['status'] = 'implemented'
        try:
            profiles.check_capability_report({'multicore': values, 'capabilities': false_claim})
        except ValueError:
            pass
        else:
            raise AssertionError('Forged DMA capability was accepted')
        reports.append(report)
    for count in (2, 3, 4, 8, 4095):
        report = profiles.capability_report(profiles.resolve('stress', NCORES=count))
        assert report['requirements']['arbitrary_hart_count_qualified']['status'] == 'unverified'
    for name, options, diagnostic in [
        ('dma', ['--profile', 'ci-msi', '--require-capability', 'external_dma_coherence'],
         'Required capability external_dma_coherence is unsupported'),
        ('mixed-harts', ['--profile', 'ci-msi', '--cores', '1', '2', '--require-capability', 'coherent_hart_ports'],
         'Required capability coherent_hart_ports is outside_scope')]:
        build = work / ('rejected-' + name)
        rejected = subprocess.run([sys.executable, str(ROOT / 'tests/multicore/run.py'), *options, '--work-dir', str(build)],
                                  capture_output=True, text=True, timeout=30)
        (work / f'rejected-{name}.log').write_text(rejected.stdout + rejected.stderr)
        assert rejected.returncode and diagnostic in rejected.stderr
        assert not build.exists(), 'Unsupported requirement started a build'
    sources = [ROOT / 'testbench/common/bus_fault_guard.sv', ROOT / 'tests/multicore/fault_guard_tb.sv']
    command = ['verilator', '--binary', '--timing', '--assert', '-j', '2', '--top-module', 'fault_guard_tb',
               '--Mdir', str(work / 'model'), *map(str, sources)]
    (work / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (work / 'build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    for mode in ('positive', 'BAD_GLOBAL', 'BAD_HART'):
        run = subprocess.run([str(work / 'model/Vfault_guard_tb'), *([] if mode == 'positive' else ['+' + mode])],
                             capture_output=True, text=True, timeout=30)
        output = run.stdout + run.stderr
        (work / f'{mode}.log').write_text(output)
        if mode == 'positive':
            assert run.returncode == 0 and 'PASS: full-core fault guard' in output
        else:
            assert run.returncode != 0 and 'Full-core execution requires fault-free bus: HRESP recovery is transport-only' in output
    inputs = [*sources, ROOT / 'config/multicore/schema.json', ROOT / 'config/multicore/profiles.py', Path(__file__)]
    summary.write_text(json.dumps({'verdict': 'PASS', 'reports': reports, 'guard_negative_cases': ['BAD_GLOBAL', 'BAD_HART'],
                                  'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}, indent=2) + '\n')
    print('PASS: capability boundaries, rejected requirements/false claims and full-core fault guard')


if __name__ == '__main__':
    main()
