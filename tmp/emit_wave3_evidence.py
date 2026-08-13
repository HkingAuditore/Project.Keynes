from pathlib import Path
import re

text = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\tools\build_technology_network_authoring.gd").read_text(encoding="utf-8")
start = text.find('"tech.guild_organization":')
end = text.find('"tech.industrial_research":')
end = text.find("\n", end)
block = text[start:end].strip()
out = "const WAVE3_EVIDENCE := {\n\t" + block + "\n}\n"
Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wave3_evidence.gd.txt").write_text(out, encoding="utf-8")
print("lines", out.count("\n"), "chars", len(out))
