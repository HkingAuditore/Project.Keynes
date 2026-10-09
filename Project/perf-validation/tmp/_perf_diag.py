import csv
from collections import Counter

with open('perf_record_20260520_140700.csv', encoding='utf-8') as f:
    rows = list(csv.DictReader(f))
print('rows=', len(rows))

print('\n=== climate-related columns ===')
for c in rows[0].keys():
    if 'partial' in c or 'pa_' in c or 'climate_total' in c or 'pass_a' in c or 'current_pass' in c or 'progress_ratio' in c:
        print(' ', c)

# partial 分布
c = Counter(str(r.get('bd_climate_partial', '')) for r in rows)
print('\nbd_climate_partial dist:', dict(c))

c2 = Counter(str(r.get('bd_climate_current_pass', '')) for r in rows)
print('bd_climate_current_pass dist:', dict(c2))

c3 = Counter(str(r.get('bd_climate_pa_pushed_cells', '')) for r in rows)
print('bd_climate_pa_pushed_cells unique vals (first 20):', list(c3.items())[:20])

c4 = Counter(str(r.get('bd_climate_pa_total_cells', '')) for r in rows)
print('bd_climate_pa_total_cells unique vals (first 20):', list(c4.items())[:20])

# 查看是否有时候 pa_total != 0
nonzero_total = [r for r in rows if str(r.get('bd_climate_pa_total_cells', '')) not in ('', '0', 'None')]
print('\nrows with pa_total > 0:', len(nonzero_total))
if nonzero_total:
    sample = nonzero_total[0]
    print('sample row pa_pushed=', sample.get('bd_climate_pa_pushed_cells'),
          'pa_total=', sample.get('bd_climate_pa_total_cells'),
          'partial=', sample.get('bd_climate_partial'),
          'current_pass=', sample.get('bd_climate_current_pass'),
          'progress=', sample.get('bd_climate_progress_ratio'))

# DVA mask_dirty
print('\nbd_dynamic_visual_atlas_mask_dirty_count unique:')
c5 = Counter(str(r.get('bd_dynamic_visual_atlas_mask_dirty_count', '')) for r in rows)
print(' ', list(c5.items())[:10])

print('\nbd_dynamic_visual_atlas_dynamic_dirty_cells unique:')
c6 = Counter(str(r.get('bd_dynamic_visual_atlas_dynamic_dirty_cells', '')) for r in rows)
print(' ', list(c6.items())[:10])
