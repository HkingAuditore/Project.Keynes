from pathlib import Path
import re

text = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\tools\build_technology_network_authoring.gd").read_text(encoding="utf-8")
start = text.find('"tech.electrification":')
end = text.find('"tech.steam_sawmilling":')
end = text.find("\n", end)
block = text[start:end].strip()
out = "const WAVE4_EVIDENCE := {\n\t" + block + "\n}\n"
Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wave4_evidence.gd.txt").write_text(out, encoding="utf-8")
print("ok", out.count("\n"))
