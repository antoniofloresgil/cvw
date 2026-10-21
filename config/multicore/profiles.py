# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Multicore topology policy, independent of cvw_t. See schema.json."""

import argparse
import ast
import hashlib
import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCHEMA = json.loads((HERE / 'schema.json').read_text())
FIELDS = SCHEMA['fields']
LINUX = SCHEMA['linux_platform']
HEADER = ROOT / 'config/shared/multicore-config.vh'
# CLI aliases are preserved; their parameter names and defaults have one owner.
ALIASES = {'cores': 'NCORES', 'shared_cache': 'SHARED_CACHE', 'cache_words': 'PRIVATE_DCACHE_WORDS',
           'cache_line_words': 'PRIVATE_DCACHE_LINE_WORDS', 'icache_words': 'PRIVATE_ICACHE_WORDS',
           'icache_line_words': 'PRIVATE_ICACHE_LINE_WORDS'}


def power2(value):
    return value > 0 and value & (value - 1) == 0


def expression(source, values, core=None):
    # Only repository-owned expressions are evaluated; the same AST generates SV.
    sv_expression(ast.parse(source, mode='eval').body)
    return eval(source, {'__builtins__': {}}, {**values, 'P': SimpleNamespace(**(core or {})), 'power2': power2})


def sv_expression(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, bool)):
        return str(int(node.value))
    if isinstance(node, ast.Name):
        if node.id == 'AHBW':
            return 'AHB_WIDTH'
        if node.id in FIELDS:
            return 'M.' + node.id
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == 'P':
        return 'P.' + node.attr
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'power2' and len(node.args) == 1:
        return 'multicore_power2(' + sv_expression(node.args[0]) + ')'
    if isinstance(node, ast.BoolOp):
        op = ' && ' if isinstance(node.op, ast.And) else ' || '
        return '(' + op.join(sv_expression(v) for v in node.values) + ')'
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return '(!' + sv_expression(node.operand) + ')'
    if isinstance(node, ast.BinOp):
        op = {ast.Add: '+', ast.Sub: '-', ast.Mult: '*', ast.FloorDiv: '/', ast.BitAnd: '&'}.get(type(node.op))
        if op:
            return '(' + sv_expression(node.left) + ' ' + op + ' ' + sv_expression(node.right) + ')'
    if isinstance(node, ast.Compare) and len(node.ops) == 1:
        op = {ast.Eq: '==', ast.NotEq: '!=', ast.Gt: '>', ast.GtE: '>=', ast.Lt: '<', ast.LtE: '<='}.get(type(node.ops[0]))
        if op:
            return '(' + sv_expression(node.left) + ' ' + op + ' ' + sv_expression(node.comparators[0]) + ')'
    raise ValueError(f'Unsupported policy expression: {ast.dump(node)}')


def defaults(ahbw=64):
    return {key: expression(spec['default'], {'AHBW': ahbw}) if isinstance(spec['default'], str) else spec['default']
            for key, spec in FIELDS.items()}


def resolve(name='default', ahbw=64, **overrides):
    values = defaults(ahbw)

    def apply(profile):
        data = SCHEMA['profiles'][profile]
        if 'extends' in data:
            apply(data['extends'])
        values.update({k: v for k, v in data.items() if k != 'extends'})
    apply(name)
    for key, value in overrides.items():
        if key not in FIELDS:
            raise ValueError(f'Unknown multicore parameter: {key}')
        if value is not None:
            values[key] = int(value)
    validate(values)
    return values


def validate(values, core=None):
    if set(values) != set(FIELDS):
        raise ValueError('Multicore profile fields differ from the schema')
    for key, value in values.items():
        if not isinstance(value, int) or value < 0 or value > 0xffffffff or (FIELDS[key]['type'] == 'bit' and value not in (0, 1)):
            raise ValueError(f'Invalid value for {key}: {value}')
    for rule in SCHEMA['rules']:
        if 'P.' in rule['when'] and core is None:
            continue
        if not expression(rule['when'], values, core):
            raise ValueError(rule['message'])


def verilator_args(values):
    return [f"-G{key}={1 if FIELDS[key]['type'] == 'bit' else 32}'d{value}" for key, value in values.items()]


def add_arguments(parser, default='stress', linux=False, multiple_cores=False):
    parser.add_argument('--profile', choices=list(SCHEMA['profiles']), default=default)
    if linux:
        parser.add_argument('--cache-mode', choices=['shared', 'msi'])
    for key, spec in FIELDS.items():
        if linux and key in ('SHARED_CACHE', 'SHARED_CACHE_WORDS', 'PRIVATE_DCACHE'):
            continue
        alias = next((a for a, k in ALIASES.items() if k == key), key.lower())
        option = '--' + alias.replace('_', '-')
        if spec['type'] == 'bit':
            parser.add_argument(option, action=argparse.BooleanOptionalAction, default=None)
        else:
            parser.add_argument(option, type=int, default=None, **({'nargs': '+'} if key == 'NCORES' and multiple_cores else {}))


def from_args(args, ahbw=64, linux=False, cores=None, base=None):
    overrides = {}
    for key in FIELDS:
        alias = next((a for a, k in ALIASES.items() if k == key), key.lower())
        value = getattr(args, alias, None)
        if value is not None:
            overrides[key] = value if key != 'NCORES' or not isinstance(value, list) else value[0]
    if cores is not None:
        overrides['NCORES'] = cores
    name = args.profile
    if linux and args.cache_mode is not None:
        overrides.update(SHARED_CACHE=int(args.cache_mode == 'shared'), PRIVATE_DCACHE=int(args.cache_mode == 'msi'))
    values = {**base, **overrides} if base is not None else resolve(name, ahbw, **overrides)
    if 'PRIVATE_DCACHE_WORDS' in overrides and values['SHARED_CACHE']:
        values['SHARED_CACHE_WORDS'] = overrides['PRIVATE_DCACHE_WORDS']
    validate(values)
    return values


def legacy_options(values):
    """Compatibility fields for existing Linux image/checkpoint manifests."""
    return {'cores': values['NCORES'], 'cache_mode': 'msi' if values['PRIVATE_DCACHE'] else 'shared',
            'cache_words': values['PRIVATE_DCACHE_WORDS'] if values['PRIVATE_DCACHE'] else values['SHARED_CACHE_WORDS'],
            **{next((a for a, k in ALIASES.items() if k == key), key.lower()): values[key]
               for key in FIELDS if key not in ('NCORES', 'PRIVATE_DCACHE', 'PRIVATE_DCACHE_WORDS', 'SHARED_CACHE', 'SHARED_CACHE_WORDS')}}


def generated_header():
    lines = ['// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1',
             '// Generated by config/multicore/profiles.py; edit schema.json, then regenerate.',
             '// Included inside package cvw, after cvw_t. Topology is not a cvw_t field.',
             'typedef struct packed {']
    lines += [f"  {spec['type']} {key};" for key, spec in FIELDS.items()]
    lines += ['} multicore_t;', '', 'function automatic bit multicore_power2(input int unsigned value);',
              '  return value > 0 && (value & (value-1)) == 0;', 'endfunction', '',
              'function automatic int multicore_config_error(input cvw_t P, input multicore_t M);']
    for number, rule in enumerate(SCHEMA['rules'], 1):
        lines += [f"  if (!{sv_expression(ast.parse(rule['when'], mode='eval').body)}) return {number};"]
    lines += ['  return 0;', 'endfunction', '',
              'function automatic string multicore_config_message(input int error);', '  case (error)']
    lines += [f"    {i}: return {json.dumps(r['message'])};" for i, r in enumerate(SCHEMA['rules'], 1)]
    lines += ['    default: return "Valid multicore configuration";', '  endcase', 'endfunction', '']
    params = []
    for key, spec in FIELDS.items():
        value = spec['default']
        default = sv_expression(ast.parse(value, mode='eval').body).replace('AHB_WIDTH', '(AHB_WIDTH)') if isinstance(value, str) else (f"1'b{value}" if spec['type'] == 'bit' else f"32'd{value}")
        params.append(f"parameter {spec['type']} {key} = {default}")
    for macro, items in [('CVW_MULTICORE_PARAMS(AHB_WIDTH)', params),
                         ('CVW_MULTICORE_CONNECT', [f'.{k}({k})' for k in FIELDS]),
                         ('CVW_MULTICORE_VALUE', [f"{k}: {1 if spec['type'] == 'bit' else 32}'({k})" for k, spec in FIELDS.items()])]:
        if macro == 'CVW_MULTICORE_VALUE':
            lines += ["`define " + macro + " '{ \\"]
            lines += ['  ' + item + (', \\' if i < len(items)-1 else ' }') for i, item in enumerate(items)]
        else:
            lines += ['`define ' + macro + ' \\']
            lines += ['  ' + item + (', \\' if i < len(items)-1 else '') for i, item in enumerate(items)]
        lines.append('')
    return '\n'.join(lines)


def check_generated():
    if HEADER.read_text() != generated_header():
        raise ValueError('Stale multicore-config.vh; run python3 config/multicore/profiles.py --generate')


def probe(config, values, work, use_defaults=False):
    """Evaluate actual config.vh/shared derivations in SV, not a Python VH parser."""
    check_generated()
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    output = work / 'effective.json'
    output.unlink(missing_ok=True)
    command = ['verilator', '--binary', '--assert', '-j', '2', '--top-module', 'config_tb',
               '--Mdir', str(work / 'model'), f'-I{ROOT}/config/shared', f'-I{ROOT}/config/{config}',
               *([] if use_defaults else verilator_args(values)), str(ROOT / 'src/cvw.sv'), str(ROOT / 'tests/multicore/config_tb.sv')]
    with (work / 'build.log').open('w') as stream:
        subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT)
    with (work / 'run.log').open('w') as stream:
        subprocess.run([str(work / 'model/Vconfig_tb'), f'+output={output}'], check=True, stdout=stream, stderr=subprocess.STDOUT)
    effective = json.loads(output.read_text())
    if effective['multicore'] != values:
        raise ValueError('Elaborated multicore parameters differ from the requested profile')
    validate(values, effective['core'])
    effective['schema_version'] = SCHEMA['version']
    effective['policy_sha256'] = hashlib.sha256((HERE / 'schema.json').read_bytes()).hexdigest()
    return effective


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generate', action='store_true')
    args = parser.parse_args()
    if args.generate:
        HEADER.write_text(generated_header())
    else:
        check_generated()


if __name__ == '__main__':
    main()
