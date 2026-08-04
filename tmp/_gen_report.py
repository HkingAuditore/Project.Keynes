import io
import json
import sys


def read(path):
    with open(path, 'rb') as f:
        head = f.read(2)
    enc = 'utf-16' if head == b'\xff\xfe' else 'utf-8'
    return io.open(path, encoding=enc, errors='replace').read()


def report(path):
    raw = read(path)
    print('=== %s' % path)
    for key in ('MapGenerator v7: per-cell', '[fused]', 'geometry fields',
                '  encode:', 'MapBaker v6: total', 'MapGenerator v7: bake'):
        for line in raw.splitlines():
            if key in line:
                print('  ' + line.strip()[:140])
                break
    i = raw.find('visual tiles: ')
    if i < 0:
        print('  (no visual tile report)')
        return
    d, _ = json.JSONDecoder().raw_decode(raw[i + len('visual tiles: '):])
    layers = d['layers']
    bake = [x['bake_ms'] for x in layers]
    print('  visual tiles: n=%d  bake min=%.0f max=%.0f sum=%.0f  total=%.0f'
          % (len(layers), min(bake), max(bake), sum(bake), d['total_ms']))
    print('  per-layer   : %s' % ' '.join('%.0f' % x for x in bake))
    names = sorted(layers[0]['hashes'].keys())
    print('  hashes[L0]  : %s' % ' '.join(
        '%s=%d' % (n, layers[0]['hashes'][n]) for n in names))
    combined = [tuple(x['hashes'][n] for n in names) for x in layers]
    print('  all-layer hash digest: %d' % hash(tuple(combined)))


for arg in sys.argv[1:]:
    report(arg)
    print()
