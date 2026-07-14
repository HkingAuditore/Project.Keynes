import os, re

base = "D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes"
dirs = {
    "goods": "data/goods",
    "buildings": "data/economy/buildings",
    "professions": "data/economy/professions",
    "resources": "data/resources",
    "needs": "data/economy/needs",
    "ethnicities": "data/economy/ethnicities",
}

def is_cjk(s):
    return any('\u4e00' <= ch <= '\u9fff' for ch in s)

rows = []
for kind, d in dirs.items():
    full = os.path.join(base, d)
    if not os.path.isdir(full):
        continue
    for fn in sorted(os.listdir(full)):
        if not fn.endswith(".tres"):
            continue
        p = os.path.join(full, fn)
        txt = open(p, encoding="utf-8").read()
        idm = re.search(r'id\s*=\s*&?"([^"]*)"', txt)
        dnm = re.search(r'display_name\s*=\s*"([^"]*)"', txt)
        dn = dnm.group(1) if dnm else ""
        rid = idm.group(1) if idm else ""
        eng = (dn != "") and (not is_cjk(dn))
        rows.append((kind, fn, rid, dn, "EN" if eng else ("CN" if dn else "EMPTY")))

from collections import Counter
c = Counter((r[0], r[4]) for r in rows)
print("=== SUMMARY (kind, status) ===")
for k in sorted(c):
    print(f"  {k[0]:12s} {k[1]:6s} {c[k]}")
print(f"\nTOTAL files: {len(rows)}")
print("\n=== ENGLISH / EMPTY display_name (needs translation) ===")
for r in rows:
    if r[4] in ("EN", "EMPTY"):
        print(f"{r[0]:12s} {r[1]:45s} id={r[2]:30s} dn={r[3]}")
