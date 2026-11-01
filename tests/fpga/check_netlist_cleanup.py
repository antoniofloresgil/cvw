#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check the open FPGA handoff preserves buffered signals and inout pads."""

import json
import subprocess
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[2]
    cleanup = root / 'fpga/generator/prepare-nextpnr.ys'
    with tempfile.TemporaryDirectory(prefix='wally-netlist-') as directory:
        work = Path(directory)
        (work / 'fixture.v').write_text('''
(* blackbox *) module IOBUF(input I, T, output O, inout IO); endmodule
module leaf(input [7:0] data, output [7:0] result);
  (* keep *) wire [7:0] alias_data = data;
  assign result = alias_data;
endmodule
module top(input [7:0] data, input tristate, output [7:0] result,
           output sense, inout pad);
  leaf child(.data(data), .result(result));
  IOBUF io(.I(data[0]), .T(tristate), .O(sense), .IO(pad));
endmodule
''')
        prefix = ('read_verilog fixture.v; hierarchy -top top; proc; flatten; '
                  'bufnorm -buf -output -public; ')
        command = (prefix + 'write_json before.json; '
                   f'script {cleanup}; write_json after.json')
        result = subprocess.run(['yosys', '-Q', '-T', '-p', command], cwd=work,
                                capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        before = json.loads((work / 'before.json').read_text())['modules']['top']
        after = json.loads((work / 'after.json').read_text())['modules']['top']
        if not any(cell['type'] == '$buf' for cell in before['cells'].values()):
            raise SystemExit('Fixture did not exercise buffered connections')
        if any(cell['type'] in ('$buf', '$_BUF_', '$scopeinfo') for cell in after['cells'].values()):
            raise SystemExit('Unmapped handoff cell remains')
        if after['ports']['data']['bits'] != after['ports']['result']['bits']:
            raise SystemExit('Data aliases were disconnected')
        pads = [cell for cell in after['cells'].values() if cell['type'] == 'IOBUF']
        if len(pads) != 1 or pads[0]['connections']['IO'] != after['ports']['pad']['bits']:
            raise SystemExit('Bidirectional pad alias was disconnected')
        mutation = subprocess.run(['yosys', '-Q', '-T', '-p',
                                   prefix + 'delete t:$buf; delete t:$scopeinfo; check -assert'],
                                  cwd=work, capture_output=True, text=True)
        if mutation.returncode == 0 or 'no driver' not in mutation.stdout + mutation.stderr:
            raise SystemExit('Original buffer-deletion defect was not detected')
    print('PASS: signal/inout aliases preserved; original deletion rejected')


if __name__ == '__main__':
    main()
