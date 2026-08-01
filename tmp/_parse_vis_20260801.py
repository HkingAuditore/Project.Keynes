import re, os, sys

log = os.path.expandvars(r'%APPDATA%\Godot\app_userdata\ProjectKeynes\logs\godot.log')

def g(line, key):
    m = re.search(r'"' + key + r'":\s*([^,}]+)', line)
    return m.group(1).strip() if m else '?'

rows = []
for line in open(log, encoding='utf-8', errors='replace'):
    if 'detail_scatter/VIS' not in line:
        continue
    rows.append('%s inst=%s far_inst=%s chunk_vis_sum=%s chunks=%s vis_chunks=%s zoom=%s lod_t=%s eff_frac=%s far_frac=%s' % (
        g(line, 'name'), g(line, 'instance_count'), g(line, 'lod_far_instance_count'),
        g(line, 'chunk_visible_sum'), g(line, 'chunk_nodes'), g(line, 'chunk_nodes_visible'),
        g(line, 'camera_zoom'), g(line, 'lod_zoom_t'), g(line, 'lod_effective_visible_fraction'),
        g(line, 'lod_far_visible_fraction')))

# 只保留每组最后一次（启动 dump 可能多轮）
for r in rows[-3:]:
    print(r)
print('--- total VIS lines:', len(rows))

# total_instances 曲线（DONE 行）
tot = []
for line in open(log, encoding='utf-8', errors='replace'):
    if 'detail_scatter/DONE' in line or 'detail_scatter/REBUILD' in line:
        m = re.search(r'"total_instances":\s*(\d+)', line)
        if m:
            tot.append(int(m.group(1)))
if tot:
    print('total_instances curve: start=%d end=%d min=%d points=%d' % (tot[0], tot[-1], min(tot), len(tot)))
    print('tail:', tot[-8:])
