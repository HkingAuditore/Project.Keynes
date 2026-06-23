import pandas as pd, numpy as np
f = r'tmp/tile_data_record_20260622_211953.csv'
cols = ['tick_idx','phys_sim_day','phys_daily_wind_season_phase','weather_cold_front_count',
        'weather_warm_front_count','weather_transitioning_count','active_weather_ratio',
        'weather_dirty_count','was_skipped_day','weather_field_commit_path']
it = pd.read_csv(f, usecols=cols, chunksize=400000)
seen = {}
for ch in it:
    g = ch.drop_duplicates('tick_idx', keep='first')
    for _, row in g.iterrows():
        t = int(row['tick_idx'])
        if t not in seen:
            seen[t] = row
df = pd.DataFrame(list(seen.values())).sort_values('tick_idx')
print('n_ticks', len(df))
print('sim_day range', df['phys_sim_day'].min(), df['phys_sim_day'].max(), 'unique days', df['phys_sim_day'].nunique())
print('season_phase range', round(df['phys_daily_wind_season_phase'].min(),4), round(df['phys_daily_wind_season_phase'].max(),4))
for c in ['weather_cold_front_count','weather_warm_front_count','weather_transitioning_count','active_weather_ratio','weather_dirty_count']:
    a = pd.to_numeric(df[c], errors='coerce').dropna()
    print(c, 'min', round(a.min(),3), 'mean', round(a.mean(),3), 'max', round(a.max(),3))
print('skipped_day true', (df['was_skipped_day'].astype(str).str.lower()=='true').sum(), 'of', len(df))
print('commit paths', df['weather_field_commit_path'].value_counts().to_dict())
# day span
print('approx days covered =', df['phys_sim_day'].max()-df['phys_sim_day'].min()+1)
