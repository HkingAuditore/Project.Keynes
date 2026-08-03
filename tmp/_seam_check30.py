import csv
import json
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37')):
    with open(path, encoding='utf-8-sig') as f:
        lines = [f.readline().strip() for _ in range(6)]
    print('=== %s ===' % tag)
    for line in lines:
        s = line.lstrip('#').strip()
        if not s:
            continue
        if s.startswith('{'):
            try:
                d = json.loads(s)
                for k in sorted(d.keys()):
                    vs = json.dumps(d[k], ensure_ascii=False)
                    print('  %s: %s' % (k, vs[:400]))
            except Exception as e:
                print('  (json parse fail: %s) %s' % (e, s[:120]))
        else:
            print('  HDR: %s' % s[:300])
    print()
