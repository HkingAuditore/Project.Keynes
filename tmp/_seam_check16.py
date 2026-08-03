import csv
import numpy as np

path = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_123739.csv'
rows = list(csv.DictReader(open(path, encoding='utf-8')))
print('rows:', len(rows))

r0 = rows[0]
for k in ['tick_idx', 'phys_sim_day', 'phys_stage_name', 'phys_psi_mode', 'phys_psi_path',
          'phys_run_ocean', 'phys_ocean_period_ticks', 'phys_slp_delta_p95',
          'phys_daily_wind_slp_delta_p95', 'phys_ocean_delta_p95', 'phys_slp_commit_ok',
          'phys_daily_wind_slp_commit_ok', 'phys_physical_round_id']:
    if k in r0:
        print('  %s = %s' % (k, r0[k]))

def f_(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r
W = max(c[0] for c in cells) + 1
H = max(c[1] for c in cells) + 1
print('W x H =', W, 'x', H)

FIELDS = ['slp_arr', 'ocean_psi_arr', 'wind_x_arr', 'wind_y_arr',
          'ocean_current_x_arr', 'ocean_current_y_arr']
print()
print('field | seam_jump | interior_jump | ratio   (11:26 录制对照: slp 0.0210/6.7x psi 1.038/7.6x ocx 0.032/3.4x ocy 0.105/5.5x)')
for k in FIELDS:
    seam, interior = [], []
    for rr in range(H):
        seam.append(abs(f_(cells[(W-1, rr)], k) - f_(cells[(0, rr)], k)))
        for c in range(W-1):
            interior.append(abs(f_(cells[(c+1, rr)], k) - f_(cells[(c, rr)], k)))
    ms = sum(seam)/len(seam); mi = sum(interior)/len(interior)
    print('%-22s | %.4f | %.4f | %.1fx' % (k, ms, mi, ms/mi if mi > 1e-9 else float('inf')))

# slp 锚定行数
slp = np.zeros((H, W))
for (c, rr), r in cells.items():
    slp[rr, c] = f_(r, 'slp_arr')
seam = np.abs(slp[:, -1] - slp[:, 0])
interior_max = np.abs(np.diff(slp, axis=1)).max(axis=1)
anchored = int((seam > interior_max).sum())
print()
print('slp anchored rows = %d/%d (11:26 为 38/64)' % (anchored, H))
