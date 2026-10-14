import json
d = json.load(open(r"Project/project-keynes/data/technology/technology_network.json", encoding="utf-8"))
techs = d["technologies"] if "technologies" in d else d.get("nodes")
print(list(d.keys())[:10])
ids = {t["id"]: t for t in techs}
want = ['fire_control','food_storage','medicinal_herb_identification','public_storehouses','permanent_settlements','regional_granaries','urban_waterworks','urban_sanitation','public_health','modern_medicine','refrigeration','public_health_systems']
for w in want:
    t = ids.get("tech."+w)
    print(w, t and t["era_id"], t and len(t["modifier_terms"]))
import re
cand = [i for i in ids if re.search(r"medic|health|sanit|water|granar|storehouse|hygien|vaccin|herb|clinic|hospital|sewer|aqueduct|quarantine|nutrition", i)]
print([(c, ids[c]["era_id"]) for c in cand])
for t in techs:
    if t["modifier_terms"]:
        print(json.dumps(t["modifier_terms"][0], ensure_ascii=False, indent=1)); break
