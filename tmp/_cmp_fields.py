import re
from pathlib import Path

p = Path("Project/project-keynes/scripts/data/building_profile.gd").read_text(encoding="utf-8")
s = Path("tools/_patch_soft_inputs.py").read_text(encoding="utf-8")
print("PROFILE")
for x in re.findall(r"@export var (\w+)", p):
    if any(k in x for k in ("input_", "output_", "resource_", "building_kind", "economic_sector", "owner_slots", "employee_slots", "upgrade_")):
        print(repr(x))
print("PATCH set_line")
for x in re.findall(r'set_line\(text, "([^"]+)"', s):
    print(repr(x))
print("PATCH f.get")
for x in re.findall(r'f\.get\("([^"]+)"', s):
    print(repr(x))
