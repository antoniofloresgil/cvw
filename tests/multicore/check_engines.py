#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Exercise the extracted reservation and storage event/latency contracts."""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    if 'WALLY' not in os.environ:
        parser.error('Source ./setup.sh first')
    root = Path(os.environ['WALLY']).resolve()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    summary = work / 'results.json'
    summary.unlink(missing_ok=True)
    sources = [root / 'src/cvw.sv', root / 'tests/multicore/engines_tb.sv',
               *(root / 'src/ebu' / name for name in ('multicore_reservations.sv', 'multicore_icache_bank.sv', 'multicore_dcache_data.sv'))]
    inputs = [*sources, Path(__file__).resolve(), *sorted((root / 'config/shared').glob('*.vh')),
              *(root / 'config' / cfg / 'config.vh' for cfg in ('rv32gc', 'rv64gc'))]
    result = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
              'verilator': subprocess.check_output(['verilator', '--version'], text=True).strip(),
              'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, 'results': []}
    try:
        for config in ('rv32gc', 'rv64gc'):
            case = work / config
            case.mkdir(exist_ok=True)
            command = ['verilator', '--binary', '--timing', '--assert', '-j', '2', '--top-module', 'engines_tb',
                       '--Mdir', str(case / 'model'), f'-I{root}/config/shared', f'-I{root}/config/{config}', *map(str, sources)]
            (case / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
            with (case / 'build.log').open('w') as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
            run = subprocess.run([str(case / 'model/Vengines_tb')], capture_output=True, text=True, timeout=30)
            (case / 'run.log').write_text(run.stdout + run.stderr)
            if run.returncode or 'PASS: extracted' not in run.stdout:
                raise RuntimeError(f'Engine fixture failed: {case}')
            result['results'].append({'config': config, 'verdict': 'PASS',
                                      'binary_sha256': hashlib.sha256((case / 'model/Vengines_tb').read_bytes()).hexdigest()})
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, RuntimeError) as error:
        result.update(verdict='FAIL', error=str(error))
        summary.write_text(json.dumps(result, indent=2) + '\n')
        print(f'FAIL: {error}')
        return 1
    result['verdict'] = 'PASS'
    summary.write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: extracted engine contracts, RV32/RV64')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
