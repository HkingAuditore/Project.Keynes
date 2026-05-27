#!/usr/bin/env python3
import pandas as pd
df = pd.read_csv('d:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260527_142740.csv', nrows=0)
print('Columns:')
for i, col in enumerate(df.columns):
    print(f'{i}: {col}')
