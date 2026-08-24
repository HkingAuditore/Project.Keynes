import re
from pathlib import Path

p = Path("Project/project-keynes/scripts/data/building_profile.gd").read_text(encoding="utf-8")
s = Path("tools/_patch_soft_inputs.py").read_text(encoding="utf-8")
a = re.search(r"@export var (input_\w+_ids)", p).group(1)
b = re.search(r"set_line\(text, \"(input_\w+_ids)\"", s).group(1)
print("profile", a, list(map(ord, a)))
print("patch  ", b, list(map(ord, b)))
print("equal", a == b)
# also show hunting file current input lines
h = Path("Project/project-keynes/data/economy/buildings/stone_age_hunting_camp.tres").read_text(encoding="utf-8")
for line in h.splitlines():
    if line.startswith("input_"):
        print("HUNT", line)
t = Path("Project/project-keynes/data/economy/buildings/timber_collector.tres").read_text(encoding="utf-8")
for line in t.splitlines():
    if line.startswith("input_"):
        print("TIMB", line)
