# -*- coding: utf-8 -*-
import pathlib
import subprocess
import os
from collections import Counter

root = pathlib.Path(".")
samples = [
    "Project/project-keynes/data/goods/grain.tres",
    "Project/project-keynes/data/goods/tools.tres",
    "Project/project-keynes/data/economy/professions/miner.tres",
    "Project/project-keynes/data/economy/professions/merchant.tres",
    "Project/project-keynes/data/economy/buildings/silver_mine.tres",
    "Project/project-keynes/data/economy/buildings/gathering_ground.tres",
]
out = []
for p in samples:
    text = pathlib.Path(p).read_text(encoding="utf-8")
    for line in text.splitlines():
        if line.startswith("id =") or line.startswith("display_name"):
            out.append(f"{p}: {line}")
pathlib.Path(".codex-temp/display_name_probe.txt").write_text(
    "\n".join(out) + "\n", encoding="utf-8"
)

raw = subprocess.check_output(["git", "show", "c2b2977:tmp/display_name_translations.csv"])
text = raw.decode("utf-8-sig")
lines = text.splitlines()
c = Counter(l.split(",")[0] for l in lines[1:] if l.strip())
summary = [
    "header=" + lines[0],
    "total=" + str(len(lines) - 1),
    "kinds=" + str(dict(c)),
]
for k in sorted(c):
    examples = [l for l in lines[1:] if l.startswith(k + ",")][:2]
    summary.append(k + ":")
    summary.extend("  " + e for e in examples)


def ascii_or_empty(directory):
    bad = []
    for fn in os.listdir(directory):
        if not fn.endswith(".tres"):
            continue
        t = pathlib.Path(directory, fn).read_text(encoding="utf-8")
        for line in t.splitlines():
            if line.startswith("display_name"):
                val = line.split("=", 1)[1].strip().strip('"')
                if not val or all(ord(ch) < 128 for ch in val):
                    bad.append(fn + ":" + val)
                break
    return bad


empty_goods = ascii_or_empty("Project/project-keynes/data/goods")
empty_prof = ascii_or_empty("Project/project-keynes/data/economy/professions")
empty_bldg = ascii_or_empty("Project/project-keynes/data/economy/buildings")
summary.append(
    "ascii_or_empty_goods count=%d sample=%s" % (len(empty_goods), empty_goods[:15])
)
summary.append(
    "ascii_or_empty_prof count=%d sample=%s" % (len(empty_prof), empty_prof[:15])
)
summary.append(
    "ascii_or_empty_bldg count=%d sample=%s" % (len(empty_bldg), empty_bldg[:15])
)
pathlib.Path(".codex-temp/display_name_csv_summary.txt").write_text(
    "\n".join(summary) + "\n", encoding="utf-8"
)
print("ok")
