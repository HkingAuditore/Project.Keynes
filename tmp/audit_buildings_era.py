import re,glob,os
BD="D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/data/economy/buildings/"
def parse(path):
    txt=open(path,encoding='utf-8').read()
    def arr(name):
        m=re.search(name+r'\s*=\s*PackedStringArray\((.*?)\)',txt,re.S)
        if not m: return []
        return [x.strip().strip('"&') for x in m.group(1).split(',') if x.strip() not in ('','""','&','"')]
    def iarr(name):
        m=re.search(name+r'\s*=\s*PackedInt64Array\((.*?)\)',txt,re.S)
        if not m: return []
        return [int(x) for x in m.group(1).split(',') if x.strip()!='']
    def sv(name):
        m=re.search(name+r'\s*=\s*&?"?([^"\n]*)"?',txt)
        return m.group(1).strip().strip('"') if m else ''
    return {
      'id':sv('id'),'tags':arr('technology_tags'),
      'cg':arr('construction_good_ids'),'cq':iarr('construction_quantities'),
      'cdays':sv('construction_days'),'owner':sv('owner_profession_id'),
      'out':arr('output_good_ids'),'oq':iarr('output_quantities_per_day')}

rows=[]
for f in glob.glob(BD+"*.tres"):
    d=parse(f)
    if d['id']: rows.append(d)

# era rank by primary tech tag
ERA={'tech.gathering':0,'tech.hunting':0,'tech.stone_knapping':0,'tech.fire_control':0,
 'tech.pottery':1,'tech.masonry':1,'tech.bronze_casting':1,'tech.writing':1,'tech.manuscript_culture':1,
 'tech.guild_organization':2,'tech.printing_press':2,'tech.coke_smelting':2,'tech.electrification':3,
 'tech.steam_power':3,'tech.electrochemistry':3,'tech.machinery':3,
 'tech.advanced_metallurgy':4,'tech.precision_engineering':4,'tech.oceanic_navigation':4,
 'tech.networked_computing':5,'tech.experimental_science':5,'tech.radio':5,
 'tech.nuclear_fission':6,'tech.digital_computing':6,'tech.autonomous_systems':6,'tech.machine_learning':6}
# good era (rough) for construction goods
GOOD_ERA={'raw_stone':0,'flint':0,'timber':0,'logs':0,'clay':0,'thatched':0,'mud':0,'thatch':0,
 'stone':0,'wood':0,'gathered_plants':0,'game_meat':0,'fish':0,'fur':0,'raw_hide':0,
 'bricks':1,'pottery':1,'bronze_tools':1,'lime':1,'limestone':1,'chipped_stone_tools':0,
 'cloth':2,'iron_ore':2,'copper':1,'copper_ore':1,'coal':2,'charcoal':2,
 'steel':3,'construction_components':3,'glass':2,'paper':2,'manuscript':2,
 'refined_fuel':3,'cement':3,'concrete':3,'machinery':3,'engines':3,'electric_motor':3,
 'aluminum':4,'advanced_metallurgy':4,'precision_tools':4,'electronics':5,'computers':6,
 'semiconductors':6,'autonomous_systems':6}

print("=== BUILDINGS WHOSE CONSTRUCTION GOOD IS FROM A LATER ERA THAN THE BUILDING ===")
flagged=0
for d in sorted(rows,key=lambda x:x['id']):
    eramin=min([ERA.get(t,9) for t in d['tags']],default=9)
    for g,q in zip(d['cg'],d['cq']):
        ge=GOOD_ERA.get(g,9)
        if ge>eramin:
            print(f"  [{d['id']}] era~{eramin} tags={d['tags']} REQUIRES {g} (era {ge}) x{q}")
            flagged+=1
print("flagged count:",flagged)

print("\n=== ALL STONE-AGE buildings (era 0) with their construction goods ===")
for d in sorted(rows,key=lambda x:x['id']):
    eramin=min([ERA.get(t,9) for t in d['tags']],default=9)
    if eramin==0:
        cg = dict(zip(d['cg'],d['cq'])) if d['cg'] else 'NONE'
        print(f"  {d['id']:28s} owner={d['owner']:10s} cdays={d['cdays']:4s} constr={cg} out={dict(zip(d['out'],d['oq']))}")

print("\n=== construction_components required by which buildings (any era) ===")
for d in sorted(rows,key=lambda x:x['id']):
    if 'construction_components' in d['cg']:
        eramin=min([ERA.get(t,9) for t in d['tags']],default=9)
        print(f"  {d['id']:28s} era~{eramin} tags={d['tags']} qty={dict(zip(d['cg'],d['cq'])).get('construction_components')}")
