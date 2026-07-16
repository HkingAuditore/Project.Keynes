import csv, collections
BASE="economy_record_20260716_113937_v5_cell643_q-5_r16_"
rows=list(csv.DictReader(open(BASE+"market.csv",encoding="utf-8-sig")))
bygood=collections.defaultdict(list)
for r in rows: bygood[r["good_id"]].append(r)
def mx(g,f): return max(int(x[f]) for x in bygood[g])
def firstpos(g,f):
    for x in bygood[g]:
        if int(x[f])>0: return int(x[f])
    return 0
print("good : max_demand_ema / max_shortage_q16 / stock_ever>0 / max_trade_in")
data=[]
for g in bygood:
    d=mx(g,"demand_ema"); s=mx(g,"shortage_q16"); st=max(int(x["stock"]) for x in bygood[g]); tin=mx(g,"trade_inbound")
    data.append((g,d,s,st,tin))
# sort by max shortage desc, then max demand desc
data.sort(key=lambda t:(-t[2],-t[1]))
print("=== TOP by shortage ===")
for g,d,s,st,tin in data[:25]:
    print(f"  {g:22s} dem={d:8d} sh={s:6d} stock={st:9d} tin={tin}")
print("=== goods with ANY demand (demand_ema>0 ever) ===")
anydem=[t for t in data if t[1]>0]
for g,d,s,st,tin in sorted(anydem,key=lambda t:-t[1]):
    print(f"  {g:22s} dem={d:8d} sh={s:6d} stock={st:9d} tin={tin}")
print("=== goods with ANY stock ever ===")
anyst=[t for t in data if t[3]>0]
for g,d,s,st,tin in sorted(anyst,key=lambda t:-t[3]):
    print(f"  {g:22s} stock={st:9d} dem={d:8d} sh={s:6d} tin={tin}")
