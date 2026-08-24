import os
import re

root = r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\goods"
ids = []
for fn in os.listdir(root):
    if not fn.endswith(".tres"):
        continue
    txt = open(os.path.join(root, fn), encoding="utf-8").read()
    m = re.search(r'id = &"([^"]+)"', txt)
    n = re.search(r'display_name = "([^"]+)"', txt)
    if m:
        ids.append((m.group(1), n.group(1) if n else m.group(1)))
ids.sort()
for i in (19, 20, 21, 42, 43, 44, 68, 121):
    if i < len(ids):
        print(i, ids[i][0], ids[i][1])
