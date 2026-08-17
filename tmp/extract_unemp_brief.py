import json
import re
from pathlib import Path

d = json.loads(Path(
    r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_unemployment_diag.json"
).read_text(encoding="utf-8"))

goods_dir = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\goods")
pat = re.compile(r'^id\s*=\s*&?"([^"]+)"', re.MULTILINE)
ids = []
for path in goods_dir.glob("*.tres"):
    m = pat.search(path.read_text(encoding="utf-8", errors="ignore"))
    if m:
        ids.append(m.group(1))
ids.sort()
print("driver maps")
for n in (20, 43, 69, 87):
    print(n, ids[n] if n < len(ids) else "?")

print("\nYEARS")
print("y pop unemp rate births deaths inv jobs catchup gap")
for y in d["years"]:
    print(
        y["year"], y["population"], y["unemployed"], round(y["unemp_rate"], 3),
        y["births"], y["deaths"], y["investments_started"], y["jobs_started"],
        y["catchup_cells"], y["employment_gap"],
    )

print("\nSERIES every 180d")
for s in d["series_30d"]:
    if s["day"] % 180 == 10 or s["day"] in (10, 40, 70, 5650, 7750, 8890, 8916):
        print(s["day"], round(s["unemp_rate"], 3), s["unemployed"], s["population"], s["owners"])

print("\npotatoes", d["market_last"].get("potatoes"))
print("last openings", d["last_openings"])
print("investment totals", d["investment_totals"])
print("correlations", d["correlations"])
