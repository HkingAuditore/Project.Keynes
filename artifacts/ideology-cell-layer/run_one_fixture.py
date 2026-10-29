#!/usr/bin/env python3
"""Run ONE ideology fixture the way verify_delivery.py runs it.

WHY THIS EXISTS: Godot's Windows binary is a GUI-subsystem executable, so
PowerShell's `& $exe ... *> log` returns before the child writes anything and
leaves an empty log. Python's subprocess.run waits and captures the pipes, which
is exactly what the verifier does -- so a single-fixture check here and the
verifier's own run cannot disagree about the harness.

Usage:  python run_one_fixture.py <fixture-name-without-.gd>
"""

import os
import subprocess
import sys

ROOT = r'D:\Godot\ProjectKeynes\Project.Keynes'
GODOT = (r'D:\Godot\Godot_v4.6.2-stable_win64.exe'
         r'\Godot_v4.6.2-stable_win64.exe')
LOG_DIR = os.path.join(ROOT, 'artifacts', 'ideology-cell-layer')


def main() -> int:
    name = sys.argv[1]
    rel = 'tests/ideology/%s.gd' % name
    env = dict(os.environ, PK_TAG_FORCE_ALL='0', PK_PLANE_IGNORE_I01='0')
    proc = subprocess.run(
        [GODOT, '--headless', '--path', 'Project/project-keynes', '-s', rel],
        cwd=ROOT, capture_output=True, text=True, encoding='utf-8',
        errors='replace', env=env)
    text = (proc.stdout or '') + (proc.stderr or '')
    log = os.path.join(LOG_DIR, 'fx_%s.log' % name)
    with open(log, 'w', encoding='utf-8') as handle:
        handle.write(text)
    kept = 0
    for line in text.splitlines():
        if ('checks' in line or 'FAIL' in line or 'reason=' in line
                or 'SCRIPT ERROR' in line or 'basis' in line.lower()
                or 'remap' in line):
            print(line)
            kept += 1
    print('--- exit=%d bytes=%d kept=%d log=%s'
          % (proc.returncode, len(text), kept, log))
    return 0


if __name__ == '__main__':
    sys.exit(main())
