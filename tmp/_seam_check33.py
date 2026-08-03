import sys
import io
import json

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

for path, tag in ((r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv', '11:26'),
                  (r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv', '12:37')):
    print('=== %s ===' % tag)
    with open(path, encoding='utf-8-sig') as f:
        for _ in range(8):
            line = f.readline()
            if not line:
                break
            s = line.strip().lstrip('#').strip()
            if s.startswith('{'):
                try:
                    d = json.loads(s)
                    for k in sorted(d.keys()):
                        vs = json.dumps(d[k], ensure_ascii=False)
                        print('  %s: %s' % (k, vs[:500]))
                except Exception as e:
                    print('  parse fail: %s' % e)
            elif s:
                print('  HDR: %s' % s[:250])
    print()
