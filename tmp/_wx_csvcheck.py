import pandas as pd, sys, csv
from collections import Counter
CSV = sys.argv[1]
hdr = pd.read_csv(CSV, nrows=0)
cols = list(hdr.columns)
print('ncols(header)=', len(cols))
dup = {k: v for k, v in Counter(cols).items() if v > 1}
print('dup_cols=', dup)

with open(CSV, newline='', encoding='utf-8', errors='replace') as f:
    rd = csv.reader(f)
    h = next(rd); nh = len(h)
    bad = 0; total = 0; maxc = nh; minc = nh; lastlen = None
    for i, row in enumerate(rd):
        total += 1
        lc = len(row)
        if lc != nh:
            bad += 1
            if bad <= 8:
                print(f'  bad line #{i+2}: {lc} cols (hdr={nh})')
        maxc = max(maxc, lc); minc = min(minc, lc); lastlen = lc
    print(f'total_data_rows={total} bad={bad} minc={minc} maxc={maxc} hdr_cols={nh} last_row_cols={lastlen}')
