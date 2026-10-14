import json
d = json.load(open(r"Project/project-keynes/data/technology/technology_network.json", encoding="utf-8"))
ids = {t["id"]: t for t in d["nodes"]}
for w in ["tech.food_storage","tech.public_health","tech.refrigeration"]:
    t = ids[w]; print(w, t["effect_summary"]); print([ (m["stat"], m["value"], m["effect_class"]) for m in t["modifier_terms"]]); print(t.get("effect_design_review"))
