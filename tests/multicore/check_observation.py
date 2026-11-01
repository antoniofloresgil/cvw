#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check passive observation mapping, rejection and independence of DUT encodings."""

import argparse
import hashlib
import json
import os
import resource
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    if 'WALLY' not in os.environ:
        parser.error('Source ./setup.sh first')
    root = Path(os.environ['WALLY']).resolve()
    tests = root / 'tests/multicore'
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    summary = work / 'results.json'
    summary.unlink(missing_ok=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    rtl_names = ('ahbmulticore', 'ahbmsicache', 'ahbmsifabric', 'ahblineburst', 'ahbburstmux',
                 'corebus_contract', 'multicore_reservations', 'multicore_icache_bank', 'multicore_dcache_data')
    rtl = [root / f'src/ebu/{name}.sv' for name in rtl_names]
    observers = [tests / f'{name}.sv' for name in ('observation_pkg', 'cache_observer', 'bridge_observer', 'word_observer')]
    inputs = [root / 'src/cvw.sv', *rtl, *observers, tests / 'observation_tb.sv', tests / 'msi_tb.sv',
              tests / 'msifabric_tb.sv', tests / 'fabric_observer.svh', tests / 'mesi_checks.vh', Path(__file__).resolve(),
              *sorted((root / 'config/shared').glob('*.vh')),
              *(root / f'config/{cfg}/config.vh' for cfg in ('rv32gc', 'rv64gc'))]
    report = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
              'verilator': subprocess.check_output(['verilator', '--version'], text=True).strip(),
              'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, 'results': []}

    def build(name, top, cfg, params=(), replacements=None):
        case = work / name
        case.mkdir(exist_ok=True)
        replacements = replacements or {}
        sources = [root / 'src/cvw.sv', *observers, tests / f'{top}.sv', *rtl]
        sources = [replacements.get(p, p) for p in sources]
        command = ['verilator', '--binary', '--timing', '--assert', '--output-split', '0', '-j', '2',
                   '--top-module', top, '--Mdir', str(case / 'model'), f'-I{root}/config/shared',
                   f'-I{root}/config/{cfg}', f'-I{tests}', *params, *map(str, sources)]
        (case / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
        with (case / 'build.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        return case / f'model/V{top}'

    def run(name, binary, plusargs=(), expected_failure=None):
        result = subprocess.run([str(binary), *plusargs], capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        (work / f'{name}.log').write_text(output)
        if expected_failure:
            if not result.returncode or expected_failure not in output:
                raise RuntimeError(f'{name}: expected named failure missing')
        elif result.returncode or 'PASS:' not in output:
            raise RuntimeError(f'{name}: observation test failed')
        report['results'].append({'case': name, 'verdict': 'PASS', 'expected_failure': expected_failure,
                                  'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()})
        print(f'PASS: {name}', flush=True)
        return [line for line in output.splitlines() if line.startswith(('PASS:', 'AHB SEQ beats:'))]

    try:
        for cfg in ('rv32gc', 'rv64gc'):
            for banks, line, icache in ((1, 1, 32), (2, 4, 64), (2, 1, 16)):
                name = f'snapshot-{cfg}-b{banks}-l{line}-i{icache}'
                binary = build(name, 'observation_tb', cfg,
                               [f'-GBANKS={banks}', f'-GLINE_WORDS={line}', f'-GICACHE_WORDS={icache}'])
                run(name, binary)
                run(name + '-duplicate', binary, ['+DUPLICATE'], 'observation contract: multiple dirty owners')
        # Mutate only ignored fixture copies, never the working source or expected values.
        mapping = work / 'bad-word-observer.sv'
        original = (tests / 'word_observer.sv').read_text()
        old = 'word = Lines[bank][h][data_index];'
        assert original.count(old) == 1
        mapping.write_text(original.replace(old, 'word = Lines[bank][h][(data_index+1)%DW];'))
        binary = build('bad-mapping', 'observation_tb', 'rv64gc', replacements={tests / 'word_observer.sv': mapping})
        run('bad-mapping', binary, expected_failure='observation contract: word mapping mismatch')
        # Both topology scenarios run unchanged against a different internal encoding.
        alternate = work / 'reencoded-ahbmsicache.sv'
        text = (root / 'src/ebu/ahbmsicache.sv').read_text()
        for before, after in (
            ('{I, S, M, E}', "{I = 0, S = 3, M = 1, E = 2}"),
            ('{IDLE, LOOKUP, SNOOP, ADDRESS, DATA, COMPLETE, REPLY, ERROR_REPLY}',
             '{IDLE = 9, LOOKUP = 10, SNOOP = 11, ADDRESS = 12, DATA = 13, COMPLETE = 14, REPLY = 15, ERROR_REPLY = 8}'),
            ('{EVICT, FLUSH, FILL, BYPASS, IFILL}', '{EVICT = 7, FLUSH = 6, FILL = 5, BYPASS = 4, IFILL = 3}'),
        ):
            assert text.count(before) == 1
            text = text.replace(before, after)
        alternate.write_text(text)
        report['mutation_sources'] = {str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in (mapping, alternate)}
        for top in ('msi_tb', 'msifabric_tb'):
            for cfg in ('rv32gc', 'rv64gc'):
                params = ['-GWORDS=32', '-GICACHE_WORDS=32', '-GLINE_WORDS=4', '-GICACHE_LINE_WORDS=4',
                          "-GPRIVATE_ICACHE=1'b1", "-GMESI=1'b1", "-GLOCAL_DCACHE_READS=1'b1", "-GLOCAL_DCACHE_WRITES=1'b1", '-GLATENCY=3']
                signatures = []
                for changed in (False, True):
                    name = f'{top}-{cfg}-' + ('reencoded' if changed else 'original')
                    binary = build(name, top, cfg, params,
                                   {root / 'src/ebu/ahbmsicache.sv': alternate} if changed else None)
                    signatures.append(run(name, binary))
                if signatures[0] != signatures[1]:
                    raise RuntimeError(f'{top}/{cfg}: reencoding changed semantic/traffic signatures')
        report['verdict'] = 'PASS'
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, RuntimeError, AssertionError) as error:
        report.update(verdict='FAIL', error=str(error))
    summary.write_text(json.dumps(report, indent=2) + '\n')
    print(f"{report['verdict']}: observation boundary; see {work}", flush=True)
    return int(report['verdict'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
