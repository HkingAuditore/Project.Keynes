#!/usr/bin/env python3
"""Check repeated external results and the experimental same-day boundary."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

from check_golden_determinism import daily_evidence_errors, difference, read_result, records
from run_regression_checks import ROOT


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--log-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 2 or not Path(args.godot).is_absolute() or not args.log_dir.is_absolute():
        parser.error('at least two runs and absolute Godot/log paths required')
    logs = args.log_dir
    logs.mkdir(parents=True, exist_ok=True)
    if any(logs.iterdir()):
        parser.error('use an empty log directory')
    command = [args.godot, '--headless', '--path', str(ROOT / 'Project/project-keynes'),
               '--script', 'res://tests/runtime/golden_external_day_alignment_test.gd']
    rows = []
    first = {}
    for index in range(1, args.runs + 1):
        for mode in ('0', '1'):
            env = os.environ.copy()
            env['PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT'] = mode
            env['PK_GOLDEN_DIAGNOSTICS'] = '1'
            log = logs / f'run-{index}-mode-{mode}.log'
            with log.open('w') as output:
                process = subprocess.run(command + ['--log-file', str(logs / f'engine-{index}-mode-{mode}.log')], cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=False)
            lines = log.read_text(errors='replace').splitlines()
            actual, errors = read_result(lines, 'GOLDEN_EXTERNAL_RESULT=', process.returncode)
            try:
                if actual is not None:
                    errors.extend(daily_evidence_errors(actual, lines, external=True))
                alignment = records(lines, 'EXTERNAL_DAY_ALIGNMENT=')
            except (ValueError, TypeError, KeyError, AttributeError) as error:
                errors.append(f'invalid day alignment evidence: {error}')
                alignment = []
            repeated_difference = difference(first.setdefault(mode, actual), actual)
            boundary_ok = (not alignment if mode == '0' else
                           len(alignment) == 4 and all(r['ok'] and r['day'] == i + 1
                           and r['after'] == [i + 1, i + 1] and r['worker_day_inflight'] == 0
                           for i, r in enumerate(alignment)))
            valid = (process.returncode == 0 and not errors and actual is not None
                     and boundary_ok and repeated_difference is None)
            rows.append({'run': index, 'mode': mode, 'valid': valid, 'exit': process.returncode,
                         'errors': errors,
                         'repeat_difference': repeated_difference, 'boundaries': alignment,
                         'chain': actual['days'][-1]['chain'] if actual and actual['days'] else None})
            summary = {'command': command, 'runs_per_mode': args.runs, 'results': rows,
                       'stable_and_valid': len(rows) == args.runs * 2 and all(r['valid'] for r in rows)}
            (logs / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(f"run {index} mode={mode}: valid={valid}; chain={rows[-1]['chain']}; first_difference={repeated_difference}", flush=True)
            if not valid:
                return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
