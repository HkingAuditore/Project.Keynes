#!/usr/bin/env python3
"""Sync the DLL identity claims in the delivery documents to the files on disk.

WHY THIS IS A TOOL AND NOT A ONE-OFF

Every rebuild changes both hashes, and three documents state them. Twice now the
documents kept a stale pair after a rebuild -- once noticed only by reading the binaries
by hand, once by `verify_delivery.py`. The rewrite was itself an ad-hoc script each time,
and one of those hard-coded the "old" values and silently did nothing on the next build.

So the operation is a tool:

    python Project/project-keynes/tools/ideology/update_dll_identity.py

It only rewrites lines that are CLAIMS:
  * a table row whose first cell is exactly `debug` or `release`, or
  * a line that names both builds and carries both hashes.

Historical mentions (a milestone log quoting the hash that was current three rounds ago)
are deliberately left alone -- they are history, not claims.
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]
BIN = ROOT / 'Project' / 'project-keynes' / 'addons' / 'dots_ext' / 'bin' / 'windows'
DBG = BIN / 'dots_ext_annual_v1.windows.template_debug.x86_64.dll'
REL = BIN / 'dots_ext_annual_v1.windows.template_release.x86_64.dll'

DOCS = [
    ROOT / 'docs' / 'plans' / 'ideology-review' / '22-progress-checklist.md',
    ROOT / 'docs' / 'plans' / 'ideology-review'
    / '22-cell-program-cap-removal-plan-v3.md',
    ROOT / 'artifacts' / 'ideology-cell-layer' / 'M5-DELIVERY-REPORT.md',
]

TABLE_ROW = re.compile(r'^\|\s*(debug|release)\s*\|', re.IGNORECASE)
PAIRED_ROW = re.compile(r'^(.*\bdebug\b.*\brelease\b.*)$', re.IGNORECASE)
HASH = re.compile(r'\b[0-9a-f]{16}\b')


def sha16(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()[:16]


def main() -> int:
    for path in (DBG, REL):
        if not path.exists():
            print('missing DLL:', path)
            return 2
    actual = {'debug': sha16(DBG), 'release': sha16(REL)}
    print('debug   =', actual['debug'])
    print('release =', actual['release'])
    print()

    total = 0
    for doc in DOCS:
        if not doc.exists():
            print('MISSING', doc)
            continue
        changed = 0
        out = []
        for line in doc.read_text(encoding='utf-8').split('\n'):
            row = TABLE_ROW.match(line)
            if row:
                which = row.group(1).lower()
                found = HASH.findall(line)
                if found and found[0] != actual[which]:
                    line = line.replace(found[0], actual[which], 1)
                    changed += 1
                out.append(line)
                continue
            if PAIRED_ROW.match(line):
                found = HASH.findall(line)
                if len(found) == 2 and (found[0] != actual['debug']
                                        or found[1] != actual['release']):
                    line = line.replace(found[0], actual['debug'], 1)
                    line = line.replace(found[1], actual['release'], 1)
                    changed += 1
            out.append(line)
        if changed:
            doc.write_text('\n'.join(out), encoding='utf-8')
        print('%-64s %d claim line(s) updated' % (doc.name, changed))
        total += changed

    print()
    print('total updated:', total)
    # Re-read and refuse to exit happily if anything is still stale.
    stale = 0
    for doc in DOCS:
        if not doc.exists():
            continue
        for line in doc.read_text(encoding='utf-8').split('\n'):
            row = TABLE_ROW.match(line)
            if row:
                found = HASH.findall(line)
                if found and found[0] != actual[row.group(1).lower()]:
                    stale += 1
                    print('STILL STALE:', doc.name, line.strip()[:90])
            elif PAIRED_ROW.match(line):
                found = HASH.findall(line)
                if len(found) == 2 and (found[0] != actual['debug']
                                        or found[1] != actual['release']):
                    stale += 1
                    print('STILL STALE:', doc.name, line.strip()[:90])
    if stale:
        print('FAILED: %d stale claim line(s)' % stale)
        return 1
    print('OK: every current-identity claim matches the files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
