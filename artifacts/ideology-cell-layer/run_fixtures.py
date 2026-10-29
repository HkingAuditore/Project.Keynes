#!/usr/bin/env python3
"""Run a LIST of ideology fixtures sequentially and print one summary line each.

Used for regression evidence around a save-format change: 61-fixture gate runs are
the parent's job, but the fixtures that capture/restore PKID are mine to check.

Usage:  python run_fixtures.py name1 name2 ...
"""

import os
import re
import subprocess
import sys

ROOT = r'D:\Godot\ProjectKeynes\Project.Keynes'
GODOT = (r'D:\Godot\Godot_v4.6.2-stable_win64.exe'
         r'\Godot_v4.6.2-stable_win64.exe')
LOG_DIR = os.path.join(ROOT, 'artifacts', 'ideology-cell-layer', 'fx_batch')


def run(name: str) -> str:
    rel = 'tests/ideology/%s.gd' % name
    env = dict(os.environ, PK_TAG_FORCE_ALL='0', PK_PLANE_IGNORE_I01='0')
    proc = subprocess.run(
        [GODOT, '--headless', '--path', 'Project/project-keynes', '-s', rel],
        cwd=ROOT, capture_output=True, text=True, encoding='utf-8',
        errors='replace', env=env)
    text = (proc.stdout or '') + (proc.stderr or '')
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(os.path.join(LOG_DIR, '%s.log' % name), 'w',
              encoding='utf-8') as handle:
        handle.write(text)
    found = re.findall(r'(\d+) checks?, (\d+) failures?', text)
    if not found:
        return '%-55s NO SUMMARY (exit %d)' % (name, proc.returncode)
    checks, failures = found[-1]
    line = '%-55s %4s checks, %s failures' % (name, checks, failures)
    if int(failures):
        fails = [l.strip() for l in text.splitlines() if l.strip().startswith('FAIL')]
        line += '\n' + '\n'.join('    ' + f for f in fails[:12])
    return line


def main() -> int:
    for name in sys.argv[1:]:
        print(run(name), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
