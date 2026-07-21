import re, glob, os
files = sorted(glob.glob("Project/project-keynes/data/economy/consumption_plans/*.tres"))
for f in files:
    txt = open(f, encoding="utf-8").read()
    def arr(name):
        m = re.search(name + r" = PackedStringArray\((.*?)\)", txt, re.S)
        if m: return [x.strip().strip('"') for x in m.group(1).split(",") if x.strip()!=""]
        m = re.search(name + r" = PackedInt32Array\((.*?)\)", txt, re.S)
        if m: return [int(x) for x in m.group(1).split(",") if x.strip()!=""]
        return None
    vids = arr("variant_ids") or []
    offs = arr("variant_component_offsets") or []
    comps = arr("component_good_ids") or []
    if not vids or not offs:
        print(f"{os.path.basename(f)}: no variant data"); continue
    multi=[]
    for i in range(len(vids)):
        s=offs[i]; e=offs[i+1]
        c=comps[s:e]
        if len(c)>1:
            multi.append((vids[i], c))
    print(f"--- {os.path.basename(f)}: {len(vids)} variants, {len(multi)} multi-component")
    for v,c in multi:
        print(f"    {v}: {c}")
