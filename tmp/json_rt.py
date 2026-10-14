import json
p = r"Project/project-keynes/data/technology/technology_network.json"
raw = open(p, encoding="utf-8").read()
d = json.loads(raw)
out = json.dumps(d, ensure_ascii=False, indent="\t")
print(out == raw, out + "\n" == raw, len(out), len(raw), repr(raw[-3:]))
