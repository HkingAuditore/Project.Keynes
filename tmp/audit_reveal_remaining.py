import json
from pathlib import Path

p = Path(
    r"D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/data/technology/technology_network.json"
)
data = json.loads(p.read_text(encoding="utf-8"))
HAB = {
    "resource.pasture",
    "resource.arable_land",
    "resource.fertile_soil",
    "resource.plantation_land",
    "resource.paddy_land",
}
ALLOW = {
    "tech.reed_identification",
    "tech.reed_harvesting",
    "tech.gold_placer_identification",
}


def collect_anyof(spec, packs):
    if not spec or "kind" in spec:
        return
    children = spec.get("children") or []
    if int(spec.get("operator", -1)) == 2:
        leaves = []
        for child in children:
            if not isinstance(child, dict):
                continue
            if "kind" in child and int(child.get("kind", -1)) == 1:
                leaves.append(child.get("id", ""))
            else:
                collect_anyof(child, packs)
        if leaves:
            packs.append(leaves)
        return
    for child in children:
        if isinstance(child, dict):
            collect_anyof(child, packs)


hits = []
for node in data["nodes"]:
    if node.get("is_milestone"):
        continue
    packs = []
    collect_anyof(node.get("reveal_condition") or {}, packs)
    for pack in packs:
        has_object = False
        has_proxy = False
        for sid in pack:
            if sid.startswith("landform.") or sid.startswith("weather.") or sid in HAB:
                has_proxy = True
            elif (
                sid.startswith("bio.")
                or sid.startswith("contact.")
                or (sid.startswith("resource.") and sid not in HAB)
            ):
                has_object = True
        if has_object and has_proxy and node["id"] not in ALLOW:
            hits.append(
                {
                    "id": node["id"],
                    "name": node.get("display_name"),
                    "pack": pack,
                    "hard": node.get("hard_prerequisite_ids"),
                    "starting": node.get("is_starting"),
                    "role": node.get("node_role"),
                }
            )

print("remaining habitat OR bypass:", len(hits))
for h in hits:
    print(
        "%s | %s | %s | hard=%s starting=%s role=%s"
        % (h["id"], h["name"], h["pack"], h["hard"], h["starting"], h["role"])
    )
