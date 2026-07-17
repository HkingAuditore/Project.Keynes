import csv, json, os, re, html
from collections import defaultdict, Counter
from pathlib import Path

ROOT = Path('D:/Godot/ProjectKeynes/Project.Keynes')
PREFIX = 'economy_record_20260717_152531_v7_cell1166_q17_r19'
paths = {k: ROOT / 'tmp' / f'{PREFIX}_{k}.csv' for k in ['summary','buildings','cohorts','market','resources']}
OUT_HTML = ROOT / 'tmp' / f'{PREFIX}_analysis.html'
OUT_JSON = ROOT / 'tmp' / f'{PREFIX}_analysis_summary.json'
Q16 = 65536.0

def read_csv(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))

def num(v, default=0.0):
    if v is None or v == '': return default
    try:
        s = str(v)
        if any(c in s for c in '.eE'):
            return float(s)
        return int(s)
    except Exception:
        try: return float(v)
        except Exception: return default

def irow(r, k, default=0): return int(num(r.get(k,''), default))
def frow(r, k, default=0.0): return float(num(r.get(k,''), default))
def day_key(r): return (irow(r,'epoch_id'), irow(r,'day_index'))

def parse_txt(path):
    try: return path.read_text(encoding='utf-8', errors='ignore')
    except Exception: return ''

def parse_string_array(txt, name):
    m = re.search(r'^' + re.escape(name) + r'\s*=\s*PackedStringArray\((.*?)\)', txt, re.M|re.S)
    return re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', m.group(1)) if m else []

def parse_int_array(txt, name):
    m = re.search(r'^' + re.escape(name) + r'\s*=\s*Packed(?:Int32|Int64)Array\((.*?)\)', txt, re.M|re.S)
    return [int(x) for x in re.findall(r'-?\d+', m.group(1))] if m else []

def parse_scalar(txt, name):
    m = re.search(r'^' + re.escape(name) + r'\s*=\s*(.+)$', txt, re.M)
    if not m: return None
    val = m.group(1).strip()
    sm = re.match(r'&?"([^"]*)"', val)
    if sm: return sm.group(1)
    nm = re.match(r'-?\d+(?:\.\d+)?(?:e[+-]?\d+)?', val, re.I)
    if nm:
        s = nm.group(0)
        return float(s) if ('.' in s or 'e' in s.lower()) else int(s)
    return val

def profile_items(dirpath, extra=False):
    items = []
    if not dirpath.exists(): return items
    for p in dirpath.glob('*.tres'):
        txt = parse_txt(p)
        mid = re.search(r'^id\s*=\s*&?"([^"]+)"', txt, re.M)
        if not mid: continue
        d = {'id': mid.group(1), 'file': p.name, 'path': str(p)}
        disp = re.search(r'^display_name\s*=\s*"([^"]*)"', txt, re.M)
        d['display_name'] = disp.group(1) if disp else ''
        if extra:
            for k in ['building_kind','owner_profession_id','owner_slots_per_building','wage_policy_id','wage_per_employee_per_day','behavior_id','category_id','base_price']:
                v = parse_scalar(txt, k)
                if v is not None: d[k] = v
            for k in ['input_good_ids','input_quantities_per_day','input_candidate_good_ids','output_good_ids','output_quantities_per_day','resource_ids','resource_quantities_per_day','employee_profession_ids','employee_slots_per_building','technology_tags']:
                if k.endswith('_ids') or k in ['input_candidate_good_ids','output_good_ids','resource_ids','employee_profession_ids','technology_tags']:
                    d[k] = parse_string_array(txt, k)
                else:
                    d[k] = parse_int_array(txt, k)
        items.append(d)
    items.sort(key=lambda x: (x['id'], x['file']))
    return items

def map_item(items, idx):
    return items[idx] if 0 <= idx < len(items) else {'id': f'#{idx}', 'display_name':'未映射', 'file':''}

summary, buildings, cohorts, market, resources = [read_csv(paths[k]) for k in ['summary','buildings','cohorts','market','resources']]
cell_meta_row = (cohorts or market or buildings or resources or [{}])[0]
cell_meta = {
    'selected_cell': int(cell_meta_row.get('cell_idx', 0) or 0),
    'q': int(cell_meta_row.get('q', 0) or 0),
    'r': int(cell_meta_row.get('r', 0) or 0),
    's': int(cell_meta_row.get('s', 0) or 0),
}
base = ROOT / 'Project' / 'project-keynes' / 'data'
goods = profile_items(base / 'goods', True)
building_profiles = profile_items(base / 'economy' / 'buildings', True)
professions = profile_items(base / 'economy' / 'professions', True)
needs = profile_items(base / 'economy' / 'needs', True)
resource_profiles = profile_items(base / 'resources', True)
id_to_gid = {g['id']: i for i, g in enumerate(goods)}
resource_by_id = {r['id']: r for r in resource_profiles}

def good_name(idx):
    if isinstance(idx, str) and not idx.lstrip('-').isdigit():
        return idx
    return map_item(goods, int(idx))['id']
def need_name(idx): return map_item(needs, int(idx))['id']
def resource_name(idx):
    if isinstance(idx, str) and not idx.lstrip('-').isdigit():
        r = resource_by_id.get(idx, {'id': idx, 'display_name': ''})
    else:
        r = map_item(resource_profiles, int(idx))
    return r['id'] + (f" / {r.get('display_name')}" if r.get('display_name') else '')
def building_label(idx):
    b = map_item(building_profiles, int(idx)); return b['id'] + (f" / {b.get('display_name')}" if b.get('display_name') else '')

summary_ts = []
for r in summary:
    summary_ts.append({
        'epoch': irow(r,'epoch_id'), 'day': irow(r,'day_index'),
        'cohort_count': irow(r,'cohort_count'), 'building_group_count': irow(r,'building_group_count'),
        'unemployed_population': irow(r,'unemployed_population'),
        'production_output_stock': frow(r,'production_output_stock'),
        'producer_support_money_issued': frow(r,'producer_support_money_issued'),
        'building_wages_paid': frow(r,'building_wages_paid'),
        'building_wages_unpaid': frow(r,'building_wages_unpaid'),
        'merchant_procurement_budget': frow(r,'merchant_procurement_budget'),
        'merchant_procurement_spent': frow(r,'merchant_procurement_spent'),
        'population_error': frow(r,'population_error'), 'money_error': frow(r,'money_error'), 'goods_error': frow(r,'goods_error')})
summary_ts.sort(key=lambda x:(x['epoch'], x['day']))
audit = {'max_population_error': max((abs(x['population_error']) for x in summary_ts), default=0), 'max_money_error': max((abs(x['money_error']) for x in summary_ts), default=0), 'max_goods_error': max((abs(x['goods_error']) for x in summary_ts), default=0)}

# Cohort aggregation
gc = defaultdict(list)
for r in cohorts: gc[day_key(r)].append(r)
cohort_ts, cohort_sig_milestones, first_by_sig = [], {}, {}
for key in sorted(gc):
    rows = gc[key]; epoch, day = key
    total_pop = sum(irow(r,'population') for r in rows)
    merchant_pop = sum(irow(r,'population') for r in rows if irow(r,'is_merchant'))
    nonmerchant_pop = total_pop - merchant_pop
    merchant_funds = sum(frow(r,'funds') for r in rows if irow(r,'is_merchant'))
    nonmerchant_funds = sum(frow(r,'funds') for r in rows if not irow(r,'is_merchant'))
    unemployed = sum(irow(r,'unemployed') for r in rows)
    owner_emp = sum(irow(r,'owner_employed') for r in rows)
    employee_emp = sum(irow(r,'employee_employed') for r in rows)
    income = sum(frow(r,'epoch_income') for r in rows)
    expense = sum(frow(r,'epoch_expense') for r in rows)
    sat_min = min((irow(r,'satisfaction_q16') for r in rows if not irow(r,'is_merchant')), default=65535)
    sat_num = sum(irow(r,'satisfaction_q16')*irow(r,'population') for r in rows if not irow(r,'is_merchant'))
    sat_den = max(1, sum(irow(r,'population') for r in rows if not irow(r,'is_merchant')))
    worst_counter = Counter()
    for r in rows:
        if not irow(r,'is_merchant'): worst_counter[need_name(irow(r,'worst_need_id'))] += irow(r,'population')
    worst_need, worst_need_pop = (worst_counter.most_common(1)[0] if worst_counter else ('',0))
    cohort_ts.append({'epoch':epoch,'day':day,'total_pop':total_pop,'merchant_pop':merchant_pop,'nonmerchant_pop':nonmerchant_pop,'merchant_funds':merchant_funds,'nonmerchant_funds':nonmerchant_funds,'unemployed':unemployed,'owner_employed':owner_emp,'employee_employed':employee_emp,'epoch_income':income,'epoch_expense':expense,'sat_min':sat_min,'sat_avg':sat_num/sat_den,'worst_need':worst_need,'worst_need_pop':worst_need_pop,'cohort_count':len(rows)})
    for r in rows:
        sig = irow(r,'signature_id'); pop = irow(r,'population')
        if sig not in first_by_sig:
            first_by_sig[sig] = {'signature_id':sig,'profession_id':irow(r,'profession_id'),'first_day':day,'first_pop':pop,'first_funds':frow(r,'funds')}
        m = cohort_sig_milestones.setdefault(sig, {'signature_id':sig,'profession_id':irow(r,'profession_id'),'first_sat_below_half':None,'first_near_zero_funds':None,'first_population_loss':None,'last_pop':pop,'last_funds':frow(r,'funds'),'last_unemployed':irow(r,'unemployed'),'last_worst_need':need_name(irow(r,'worst_need_id'))})
        if m['first_sat_below_half'] is None and irow(r,'satisfaction_q16') < 32768 and not irow(r,'is_merchant'):
            m['first_sat_below_half'] = {'epoch':epoch,'day':day,'satisfaction_q16':irow(r,'satisfaction_q16'),'worst_need':need_name(irow(r,'worst_need_id')),'population':pop}
        if m['first_near_zero_funds'] is None and frow(r,'funds') <= max(1, first_by_sig[sig]['first_funds']*0.01) and not irow(r,'is_merchant'):
            m['first_near_zero_funds'] = {'epoch':epoch,'day':day,'funds':frow(r,'funds'),'population':pop}
        if m['first_population_loss'] is None and pop < first_by_sig[sig]['first_pop'] and not irow(r,'is_merchant'):
            m['first_population_loss'] = {'epoch':epoch,'day':day,'population':pop,'initial_population':first_by_sig[sig]['first_pop']}
        m['last_pop'] = pop; m['last_funds'] = frow(r,'funds'); m['last_unemployed'] = irow(r,'unemployed'); m['last_worst_need'] = need_name(irow(r,'worst_need_id'))

first_cohort = cohort_ts[0] if cohort_ts else {}
last_cohort = cohort_ts[-1] if cohort_ts else {}
first_unemp = next((x for x in cohort_ts if x['unemployed'] > 0), None)
max_unemp = max(cohort_ts, key=lambda x:x['unemployed']) if cohort_ts else None
first_sat_crash = next((x for x in cohort_ts if x['sat_min'] < 32768), None)
first_cell_death = next((x for x in cohort_ts if first_cohort and x['nonmerchant_pop'] < first_cohort['nonmerchant_pop']), None)

# Consumption plan parsing
plans = {}
for plan_path in (base / 'economy' / 'consumption_plans').glob('*.tres'):
    txt = parse_txt(plan_path); pid = parse_scalar(txt,'id') or plan_path.stem
    need_ids, base_qty = parse_string_array(txt,'need_ids'), parse_int_array(txt,'base_qty_per_person')
    offsets, variants = parse_int_array(txt,'need_variant_offsets'), parse_string_array(txt,'variant_ids')
    comp_offsets, comps = parse_int_array(txt,'variant_component_offsets'), parse_string_array(txt,'component_good_ids')
    plan_needs = []
    for ni, need in enumerate(need_ids):
        vb = offsets[ni] if ni < len(offsets) else 0; ve = offsets[ni+1] if ni+1 < len(offsets) else vb
        goods_for_need = []
        for vi in range(vb, ve):
            cb = comp_offsets[vi] if vi < len(comp_offsets) else 0; ce = comp_offsets[vi+1] if vi+1 < len(comp_offsets) else cb
            goods_for_need.extend(comps[cb:ce])
        plan_needs.append({'need':need, 'base_qty_per_person': base_qty[ni] if ni < len(base_qty) else None, 'goods': sorted(set(goods_for_need))})
    plans[pid] = {'id':pid, 'file':plan_path.name, 'needs':plan_needs}
survival_goods = sorted({g for need in plans.get('survival_household',{}).get('needs',[]) for g in need['goods']})
unemployed_goods = sorted({g for need in plans.get('plan_unemployed',{}).get('needs',[]) for g in need['goods']})

# Market per good
mg = defaultdict(list)
for r in market:
    mg[r.get('good_id','')].append(r)
market_stats = []
for gid, rows in mg.items():
    rows.sort(key=day_key); first, last = rows[0], rows[-1]
    prices = [frow(r,'price') for r in rows]; stock = [frow(r,'stock') for r in rows]; hh = [frow(r,'household_available_stock') for r in rows]
    demand = [frow(r,'demand_ema') for r in rows]; bdemand = [frow(r,'business_demand_ema') for r in rows]
    shortage = [frow(r,'shortage_q16') for r in rows]; pressure = [frow(r,'price_pressure_total_q16') for r in rows]
    shortfall = [frow(r,'merchant_procurement_shortfall') for r in rows]; reserve = [frow(r,'production_input_reserve') for r in rows]
    market_stats.append({'good_id':gid, 'good':good_name(gid), 'first_price':frow(first,'price'), 'last_price':frow(last,'price'), 'max_price':max(prices), 'price_x':(max(prices)/prices[0]) if prices and prices[0] else None, 'first_stock':frow(first,'stock'), 'last_stock':frow(last,'stock'), 'min_stock':min(stock), 'max_stock':max(stock), 'min_household_available':min(hh), 'last_household_available':frow(last,'household_available_stock'), 'max_demand_ema':max(demand), 'last_demand_ema':frow(last,'demand_ema'), 'max_business_demand_ema':max(bdemand), 'max_shortage_q16':max(shortage), 'last_shortage_q16':frow(last,'shortage_q16'), 'max_pressure_q16':max(pressure), 'max_procurement_shortfall':max(shortfall), 'max_input_reserve':max(reserve), 'shortage_days':sum(1 for x in shortage if x>0)})
market_stats.sort(key=lambda x:(x['max_shortage_q16'], x['max_demand_ema'], x['max_price']), reverse=True)

# Building per type
bg = defaultdict(list)
for r in buildings: bg[irow(r,'type_id')].append(r)
building_stats, active_building_goods = [], set()
for tid, rows in bg.items():
    rows.sort(key=day_key); prof = map_item(building_profiles, tid)
    for k in ['input_good_ids','output_good_ids']:
        for x in prof.get(k,[]): active_building_goods.add(x)
    first, last = rows[0], rows[-1]
    vals = lambda k: [frow(r,k) for r in rows]
    util = [frow(r,'planned_utilization_q16')/Q16 for r in rows]; cap = [frow(r,'capacity_q16')/Q16 for r in rows]
    op_states = Counter(r.get('operating_state','') for r in rows)
    building_stats.append({'type_id':tid,'building':prof['id'],'label':building_label(tid),'display_name':prof.get('display_name',''),'kind':prof.get('building_kind',''),'owner_profession_id':prof.get('owner_profession_id',''),'owner_slots_per_building':prof.get('owner_slots_per_building',0),'profile_inputs':prof.get('input_good_ids',[]),'profile_outputs':prof.get('output_good_ids',[]),'profile_resources':prof.get('resource_ids',[]),'first_count':frow(first,'count'),'last_count':frow(last,'count'),'max_count':max(vals('count')),'first_owner_required':frow(first,'owner_required'),'last_owner_required':frow(last,'owner_required'),'first_filled_owner':frow(first,'filled_owner'),'last_filled_owner':frow(last,'filled_owner'),'first_employee_required':frow(first,'employee_required'),'last_employee_required':frow(last,'employee_required'),'first_employee_filled':frow(first,'employee_filled'),'last_employee_filled':frow(last,'employee_filled'),'avg_utilization':sum(util)/len(util),'min_utilization':min(util),'last_utilization':frow(last,'planned_utilization_q16')/Q16,'avg_capacity':sum(cap)/len(cap),'min_capacity':min(cap),'last_capacity':frow(last,'capacity_q16')/Q16,'total_input':sum(vals('last_input')),'total_output':sum(vals('last_output')),'total_sold':sum(vals('last_sold')),'total_revenue':sum(vals('last_revenue')),'total_input_cost':sum(vals('last_input_cost')),'total_wages_paid':sum(vals('last_wages_paid')),'total_wages_due':sum(vals('last_wages_due')),'last_output':frow(last,'last_output'),'last_input':frow(last,'last_input'),'last_margin_gap_q16':frow(last,'last_margin_gap_q16'),'state_mode':op_states.most_common(1)[0][0] if op_states else ''})
building_stats.sort(key=lambda x:(x['total_output'],x['total_revenue'],x['last_count']), reverse=True)

# Resources
rg = defaultdict(list)
for r in resources:
    rg[r.get('resource_id','')].append(r)
resource_stats = []
for rid, rows in rg.items():
    rows.sort(key=day_key); vals = [frow(r,'reserve') for r in rows]; first, last = vals[0], vals[-1]
    resource_stats.append({'resource_id':rid,'resource':resource_name(rid),'first_reserve':first,'last_reserve':last,'min_reserve':min(vals),'max_reserve':max(vals),'delta':last-first,'delta_pct':((last-first)/first*100 if abs(first)>1e-9 else None)})
resource_stats.sort(key=lambda x:abs(x['delta']), reverse=True)

# Focus market goods
focus_good_ids = set(g for g in survival_goods + unemployed_goods if g in id_to_gid)
focus_good_ids.update(g for g in active_building_goods if g in id_to_gid)
focus_good_ids.update(x['good_id'] for x in market_stats[:20])
focus_market_stats = [x for x in market_stats if x['good_id'] in focus_good_ids]
focus_market_stats.sort(key=lambda x:(x['max_shortage_q16'],x['max_demand_ema'],x['max_price']), reverse=True)

# Milestone market snapshots
milestone_days = []
for label,obj in [('起点',first_cohort),('首次失业',first_unemp),('首次满意度<50%',first_sat_crash),('首次人口下降',first_cell_death),('失业峰值',max_unemp),('终点',last_cohort)]:
    if obj: milestone_days.append((label,obj['epoch'],obj['day']))
seen=set(); mdedup=[]
for m in milestone_days:
    if (m[1],m[2]) not in seen: mdedup.append(m); seen.add((m[1],m[2]))
market_by_day_good = {(irow(r,'epoch_id'), irow(r,'day_index'), r.get('good_id','')): r for r in market}
key_goods_names = ['gathered_plants','grain','prepared_staples','bread','game_meat','processed_food','vegetables','construction_components','pottery','logs','flint','chipped_stone_tools']
key_goods = [g for g in key_goods_names if g in id_to_gid]
market_snapshots = []
for label,epoch,day in mdedup:
    for gid in key_goods:
        r = market_by_day_good.get((epoch,day,gid))
        if r: market_snapshots.append({'milestone':label,'epoch':epoch,'day':day,'good':good_name(gid),'stock':frow(r,'stock'),'household_available':frow(r,'household_available_stock'),'price':frow(r,'price'),'demand_ema':frow(r,'demand_ema'),'business_demand_ema':frow(r,'business_demand_ema'),'shortage_q16':frow(r,'shortage_q16'),'input_reserve':frow(r,'production_input_reserve'),'shortfall':frow(r,'merchant_procurement_shortfall')})

cohort_milestones = []
for sig,m in cohort_sig_milestones.items():
    if m['first_sat_below_half'] or m['first_near_zero_funds'] or m['first_population_loss'] or m['last_unemployed'] > 0:
        prof = map_item(professions, m['profession_id'])
        cohort_milestones.append({**m, 'profession': prof['id'], 'profession_display': prof.get('display_name','')})
cohort_milestones.sort(key=lambda x:(x['first_sat_below_half']['day'] if x['first_sat_below_half'] else 10**9, x['first_population_loss']['day'] if x['first_population_loss'] else 10**9, x['signature_id']))

resource_depletion_flags = [r for r in resource_stats if r['min_reserve'] <= 0 or (r['delta_pct'] is not None and r['delta_pct'] < -20)]
capacity_low = [b for b in building_stats if b['min_capacity'] < 0.75 or b['last_capacity'] < 0.75]
util_low = [b for b in building_stats if b['avg_utilization'] < 0.75 or b['last_utilization'] < 0.75]
input_costly = [b for b in building_stats if b['total_input_cost'] > b['total_revenue']*1.1 and b['total_input_cost'] > 0]
analysis = {'record_prefix':PREFIX,'paths':{k:str(v) for k,v in paths.items()},'row_counts':{k:len(read_csv(v)) for k,v in paths.items()},'catalog_counts':{'goods':len(goods),'buildings':len(building_profiles),'professions':len(professions),'needs':len(needs),'resources':len(resource_profiles)},'scope':{**cell_meta,'summary_scope':'global/runtime summary','other_csv_scope':'selected-cell recorder'},'audit':audit,'summary_ts':summary_ts,'cohort_ts':cohort_ts,'events':{'first_unemployment':first_unemp,'max_unemployment':max_unemp,'first_satisfaction_below_half':first_sat_crash,'first_nonmerchant_population_drop':first_cell_death},'market_top_shortage':market_stats[:30],'focus_market_stats':focus_market_stats[:80],'market_snapshots':market_snapshots,'building_stats':building_stats,'resource_stats':resource_stats,'cohort_milestones':cohort_milestones[:80],'plans':{k:v for k,v in plans.items() if k in ['plan_unemployed','survival_household','owner_household']},'signals':{'resource_depletion_flags':resource_depletion_flags[:20],'capacity_low':capacity_low[:20],'util_low':util_low[:20],'input_cost_exceeds_revenue':input_costly[:20]}}
OUT_JSON.write_text(json.dumps(analysis, ensure_ascii=False, indent=2), encoding='utf-8')

def fmt(v):
    if v is None: return '—'
    if isinstance(v, dict): return html.escape(json.dumps(v, ensure_ascii=False))
    if isinstance(v, list): return html.escape(', '.join(map(str,v)))
    if isinstance(v, float):
        av=abs(v)
        if av >= 1e9: return f'{v/1e9:.2f}B'
        if av >= 1e6: return f'{v/1e6:.2f}M'
        if av >= 1e3: return f'{v/1e3:.2f}K'
        if av != 0 and av < 0.01: return f'{v:.3e}'
        return f'{v:.2f}'
    if isinstance(v, int): return f'{v:,}'
    return html.escape(str(v))

def table(rows, cols, max_rows=30):
    if not rows: return '<p class="muted">无数据</p>'
    s = '<table><thead><tr>' + ''.join(f'<th>{html.escape(label)}</th>' for _,label in cols) + '</tr></thead><tbody>'
    for r in rows[:max_rows]: s += '<tr>' + ''.join(f'<td>{fmt(r.get(key))}</td>' for key,_ in cols) + '</tr>'
    s += '</tbody></table>'
    if len(rows) > max_rows: s += f'<div class="table-note">仅显示前 {max_rows} / {len(rows)} 行；完整聚合见 JSON。</div>'
    return s

initial, final = first_cohort or {}, last_cohort or {}
nonmerchant_change = final.get('nonmerchant_pop',0)-initial.get('nonmerchant_pop',0) if initial and final else 0
funds_change = final.get('nonmerchant_funds',0)-initial.get('nonmerchant_funds',0) if initial and final else 0
merchant_funds_change = final.get('merchant_funds',0)-initial.get('merchant_funds',0) if initial and final else 0
chart_data = {'cohort_ts':cohort_ts,'summary_ts':summary_ts,'focus_market':focus_market_stats[:25],'market_snapshots':market_snapshots,'building_stats':building_stats[:20],'resource_stats':resource_stats[:20]}
css = ''':root{--bg:#0f172a;--panel:#111c33;--panel2:#16233d;--text:#e5e7eb;--muted:#9ca3af;--line:#2c3a57;--accent:#60a5fa;--warn:#f59e0b;--bad:#f87171;--good:#34d399}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif;line-height:1.55}.container{max-width:1500px;margin:0 auto;padding:24px}header{background:linear-gradient(135deg,#13213d,#1e1b4b);border:1px solid var(--line);border-radius:18px;padding:24px;margin-bottom:18px}h1{margin:0 0 8px;font-size:26px}h2{margin:28px 0 12px;font-size:20px}h3{margin:14px 0 10px;font-size:16px}.muted{color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px;box-shadow:0 8px 24px rgba(0,0,0,.18)}.kpi .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em}.kpi .value{font-size:25px;font-weight:800;margin:4px 0}.kpi .sub{color:var(--muted);font-size:12px}.good{color:var(--good)}.bad{color:var(--bad)}.warn{color:var(--warn)}.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(460px,1fr));gap:14px}canvas{width:100%;height:320px}table{width:100%;border-collapse:collapse;font-size:12.5px}th,td{border-bottom:1px solid var(--line);padding:8px 9px;vertical-align:top}th{color:#cbd5e1;background:var(--panel2);position:sticky;top:0;text-align:left}tr:hover td{background:rgba(96,165,250,.07)}.table-wrap{overflow:auto;max-height:560px;border:1px solid var(--line);border-radius:12px}.table-note{color:var(--muted);font-size:12px;margin-top:6px}blockquote{margin:12px 0;padding:12px 14px;border-left:4px solid var(--accent);background:rgba(96,165,250,.08);border-radius:8px}code{background:rgba(255,255,255,.08);padding:1px 5px;border-radius:5px;color:#bfdbfe}.finding{border-left:4px solid var(--warn)}.ok{border-left:4px solid var(--good)}.risk{border-left:4px solid var(--bad)}'''
html_doc = f'''<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Project.Keynes 经济运行诊断：{PREFIX}</title><script src="https://cdn.jsdelivr.net/npm/chart.js@4.5.1"></script><style>{css}</style></head><body><div class="container"><header><h1>Project.Keynes 早期石器经济运行诊断</h1><div class="muted">记录：<code>{PREFIX}</code>；选中 cell={cell_meta['selected_cell']} / q={cell_meta['q']} / r={cell_meta['r']} / s={cell_meta['s']}。summary 为全局口径，其余四张表为选中地块口径。</div></header>
<section class="grid"><div class="card kpi"><div class="label">审计误差</div><div class="value {'good' if audit['max_population_error']==audit['max_money_error']==audit['max_goods_error']==0 else 'bad'}">pop {fmt(audit['max_population_error'])} / money {fmt(audit['max_money_error'])} / goods {fmt(audit['max_goods_error'])}</div><div class="sub">守恒审计最大绝对误差</div></div><div class="card kpi"><div class="label">非商人人口</div><div class="value">{fmt(initial.get('nonmerchant_pop'))} → {fmt(final.get('nonmerchant_pop'))}</div><div class="sub">变化 {fmt(nonmerchant_change)}</div></div><div class="card kpi"><div class="label">失业人口峰值</div><div class="value {'bad' if max_unemp and max_unemp.get('unemployed',0)>0 else 'good'}">{fmt(max_unemp.get('unemployed') if max_unemp else 0)}</div><div class="sub">day {max_unemp.get('day') if max_unemp else '—'}；首次失业 day {first_unemp.get('day') if first_unemp else '—'}</div></div><div class="card kpi"><div class="label">非商人资金</div><div class="value">{fmt(initial.get('nonmerchant_funds'))} → {fmt(final.get('nonmerchant_funds'))}</div><div class="sub">变化 {fmt(funds_change)}</div></div><div class="card kpi"><div class="label">商人资金</div><div class="value">{fmt(initial.get('merchant_funds'))} → {fmt(final.get('merchant_funds'))}</div><div class="sub">变化 {fmt(merchant_funds_change)}</div></div><div class="card kpi"><div class="label">首次满意度崩落</div><div class="value {'bad' if first_sat_crash else 'good'}">{('day ' + str(first_sat_crash.get('day'))) if first_sat_crash else '未低于 50%'}</div><div class="sub">最差 need：{first_sat_crash.get('worst_need') if first_sat_crash else '—'}</div></div></section>
<h2>结论摘要</h2><div class="grid"><div class="card ok"><h3>0. 经济运行体现出的特点</h3><p>这是一套<strong>守恒完整、但分配和就业脆弱</strong>的早期地块经济：全局人口/货币/物资审计误差为 0，说明不是账本损坏；选中 cell 内，商人库存/现金承接交易，居民通过建筑 owner/employee 岗位获得收入，失业 cohort 退化为只消费 staple_food 的生存计划。</p></div><div class="card risk"><h3>1. 健康性判断</h3><p>当前不是健康稳态，而是<strong>模拟上自洽的贫困化/失业化路径</strong>：消费仍在从居民向商人转移，但建筑岗位、工资或利润没有稳定把购买力回流给居民。</p></div><div class="card finding"><h3>2. 失业根因</h3><p>源码中就业目标由 <code>count × slots × planned_utilization_q16</code> 决定；owner 岗在建筑不可用或 utilization 为 0 时清零。因而大量失业不是“闲置字段”，而是建筑容量/利用率/输入盈利/岗位容量不能吸收人口后，C++ A1 机制把未被雇佣者迁入 unemployed cohort。</p></div><div class="card finding"><h3>3-6. 设计改进方向</h3><p>优先处理三类问题：① 石器时代建筑岗位与基础食物链是否足以吸收初始人口；② 商人采购/零售价差是否造成早期现金单向蓄水；③ survival 与 plan_unemployed 的基础消费是否过宽/过硬，导致早期社会在未解锁建筑时追逐住房、卫生、医疗等不可得品。</p></div></div>
<h2>关键时间序列</h2><div class="charts"><div class="card"><h3>人口、失业与满意度</h3><canvas id="cohortChart"></canvas></div><div class="card"><h3>居民/商人资金变化</h3><canvas id="fundsChart"></canvas></div><div class="card"><h3>全局生产与工资</h3><canvas id="summaryChart"></canvas></div><div class="card"><h3>重点商品短缺强度 Top</h3><canvas id="shortageChart"></canvas></div></div>
<h2>市场：重点商品与短缺</h2><p class="muted">包含 survival/失业消费品、当前地块活跃建筑的输入/输出品，以及短缺/需求/价格压力最高的商品。<code>shortage_q16=65535</code> 约等于 100% 短缺。</p><div class="table-wrap">{table(focus_market_stats[:50], [('good','商品'),('max_shortage_q16','最大短缺Q16'),('shortage_days','短缺记录数'),('max_demand_ema','最大家庭需求EMA'),('max_business_demand_ema','最大企业需求EMA'),('first_price','初价'),('max_price','最高价'),('last_price','终价'),('min_household_available','最低家庭可得库存'),('max_input_reserve','最大生产预留'),('max_procurement_shortfall','最大商人采购缺口')], 50)}</div>
<h2>里程碑商品快照</h2><div class="table-wrap">{table(market_snapshots, [('milestone','节点'),('day','day'),('good','商品'),('stock','库存'),('household_available','家庭可得'),('price','价格'),('demand_ema','家庭需求EMA'),('business_demand_ema','企业需求EMA'),('shortage_q16','短缺Q16'),('input_reserve','生产预留'),('shortfall','采购缺口')], 120)}</div>
<h2>建筑：就业、产出与资源链</h2><p class="muted">type_id 按当前 building profile id 排序映射；如果 catalog 编译顺序改变，应以 native catalog dump 再校验一次。</p><div class="table-wrap">{table(building_stats, [('type_id','type_id'),('building','建筑'),('kind','类型'),('owner_profession_id','owner'),('last_count','终点数量'),('last_filled_owner','终点 owner'),('last_employee_filled','终点雇员'),('avg_utilization','平均利用率'),('min_capacity','最低容量'),('profile_inputs','profile投入'),('profile_outputs','profile产出'),('profile_resources','资源'),('total_input','总投入'),('total_output','总产出'),('total_revenue','总收入'),('total_input_cost','总输入成本'),('total_wages_paid','已付工资'),('state_mode','主状态')], 80)}</div>
<h2>资源：是否存在自然资源耗竭</h2><div class="table-wrap">{table(resource_stats, [('resource','资源'),('first_reserve','首值'),('last_reserve','末值'),('min_reserve','最小'),('max_reserve','最大'),('delta','变化'),('delta_pct','变化%')], 40)}</div>
<h2>Cohort 事件：满意度、资金、人口损失</h2><div class="table-wrap">{table(cohort_milestones, [('signature_id','signature'),('profession','职业'),('last_pop','终点人口'),('last_funds','终点资金'),('last_unemployed','终点失业'),('last_worst_need','终点 worst_need'),('first_sat_below_half','首次满意度<50%'),('first_near_zero_funds','首次近零资金'),('first_population_loss','首次人口损失')], 80)}</div>
<h2>模型机制对照</h2><blockquote>就业：<code>planned_role_demand = count × employee slots × planned_utilization_q16</code>；<code>planned_owner_demand</code> 在 utilization &gt; 0 时保留 full owner，否则为 0。未被任何建筑岗位吸收的非商人人口会迁移到 unemployed signature。</blockquote><blockquote>消费：<code>plan_unemployed</code> 只消费 staple_food，候选为 <code>{', '.join(unemployed_goods)}</code>；<code>survival_household</code> 同时覆盖食物、蛋白、蔬果、衣物、住房、家用品、卫生、医疗、能源。</blockquote><blockquote>市场：household 支出直接进入本地 merchant；建筑生产输入从 merchant 库存购买，输出由 merchant 预算采购。价格压力同时包含家庭需求、企业需求、目标库存、短缺、成本锚和闲置回归。</blockquote>
<h2>建议修正优先级</h2><div class="grid"><div class="card risk"><h3>P0：先稳住石器时代闭环</h3><ul><li>验证 <code>gathered_plants/game_meat/processed_food/grain</code> 是否足以覆盖 <code>plan_unemployed</code> 与 <code>survival_household</code> 的 staple/protein/produce。</li><li>给石器时代基础建筑设计最低就业吸纳与最低现金回流；否则人口一旦转为失业者，只剩消费泄漏。</li><li>对不可得高阶 survival need 在早期时代降权或移出 survival，避免“石器时代追求现代家庭篮子”。</li></ul></div><div class="card finding"><h3>P1：修商人现金蓄水</h3><ul><li>给本地 merchant 引入最低采购义务/库存目标约束，减少只收零售款、不足额采购的早期蓄水。</li><li>检查 merchant buy factor 与 price cap，确保基础食品短缺时生产者仍能获得收入信号。</li><li>将采购缺口、discarded output、price cap hits 暴露到 recorder，便于下一轮定位。</li></ul></div><div class="card finding"><h3>P1：建筑 profile 复核</h3><ul><li>对本报告中的 active building 表逐项检查投入产出比、资源 capacity、owner slots 和 wage_policy。</li><li>石器采集/狩猎/火塘链应尽量少依赖现金购买中间品，否则早期市场尚未成形时容易锁死。</li><li>对 <code>planned_utilization_q16</code> 的盈利反馈加平滑和下限，防止一次短缺后岗位雪崩。</li></ul></div><div class="card ok"><h3>P2：下一轮验证</h3><ul><li>保留当前 CSV 作为 baseline；修改 profile 或公式后重复 recorder。</li><li>要求审计误差继续为 0，并比较 N=5 默认周期下 unemployment、sat_min、merchant_funds 三条曲线。</li><li>如怀疑 frozen-cycle 放大震荡，再与 N=1 reference 对照，不能只看守恒。</li></ul></div></div><footer class="muted" style="margin-top:28px">生成文件：<code>{OUT_HTML.name}</code>；完整聚合数据：<code>{OUT_JSON.name}</code>。</footer></div>
<script>const DATA = {json.dumps(chart_data, ensure_ascii=False)}; const COLORS = ['#60a5fa','#f87171','#34d399','#f59e0b','#a78bfa','#22d3ee','#fb7185','#c084fc']; function fmtNum(v){{if(v===null||v===undefined)return '—'; const a=Math.abs(v); if(a>=1e9)return (v/1e9).toFixed(2)+'B'; if(a>=1e6)return (v/1e6).toFixed(2)+'M'; if(a>=1e3)return (v/1e3).toFixed(1)+'K'; return Number(v).toFixed(2);}} Chart.defaults.color='#cbd5e1'; Chart.defaults.borderColor='#2c3a57'; new Chart(document.getElementById('cohortChart'),{{type:'line',data:{{labels:DATA.cohort_ts.map(x=>x.day),datasets:[{{label:'非商人人口',data:DATA.cohort_ts.map(x=>x.nonmerchant_pop),borderColor:COLORS[0],yAxisID:'y'}},{{label:'失业',data:DATA.cohort_ts.map(x=>x.unemployed),borderColor:COLORS[1],yAxisID:'y'}},{{label:'最低满意度Q16',data:DATA.cohort_ts.map(x=>x.sat_min),borderColor:COLORS[3],yAxisID:'y1'}}]}},options:{{responsive:true,maintainAspectRatio:false,interaction:{{mode:'index',intersect:false}},scales:{{y:{{beginAtZero:true}},y1:{{position:'right',beginAtZero:true,max:65535,grid:{{drawOnChartArea:false}}}}}}}}}}); new Chart(document.getElementById('fundsChart'),{{type:'line',data:{{labels:DATA.cohort_ts.map(x=>x.day),datasets:[{{label:'非商人资金',data:DATA.cohort_ts.map(x=>x.nonmerchant_funds),borderColor:COLORS[2]}},{{label:'商人资金',data:DATA.cohort_ts.map(x=>x.merchant_funds),borderColor:COLORS[4]}}]}},options:{{responsive:true,maintainAspectRatio:false,interaction:{{mode:'index',intersect:false}},scales:{{y:{{ticks:{{callback:fmtNum}}}}}}}}}}); new Chart(document.getElementById('summaryChart'),{{type:'line',data:{{labels:DATA.summary_ts.map(x=>x.day),datasets:[{{label:'生产输出库存',data:DATA.summary_ts.map(x=>x.production_output_stock),borderColor:COLORS[0]}},{{label:'建筑工资已付',data:DATA.summary_ts.map(x=>x.building_wages_paid),borderColor:COLORS[2]}},{{label:'商人采购支出',data:DATA.summary_ts.map(x=>x.merchant_procurement_spent),borderColor:COLORS[3]}}]}},options:{{responsive:true,maintainAspectRatio:false,interaction:{{mode:'index',intersect:false}},scales:{{y:{{ticks:{{callback:fmtNum}}}}}}}}}}); new Chart(document.getElementById('shortageChart'),{{type:'bar',data:{{labels:DATA.focus_market.slice(0,15).map(x=>x.good),datasets:[{{label:'最大短缺Q16',data:DATA.focus_market.slice(0,15).map(x=>x.max_shortage_q16),backgroundColor:'#f87171cc'}}]}},options:{{responsive:true,maintainAspectRatio:false,indexAxis:'y',plugins:{{legend:{{display:false}}}},scales:{{x:{{beginAtZero:true,max:65535}}}}}}}});</script></body></html>'''
OUT_HTML.write_text(html_doc, encoding='utf-8')
print(json.dumps({'outputs':{'html':str(OUT_HTML),'json':str(OUT_JSON)},'row_counts':analysis['row_counts'],'catalog_counts':analysis['catalog_counts'],'audit':audit,'events':analysis['events'],'first':first_cohort,'last':last_cohort,'top_focus_market':focus_market_stats[:10],'top_buildings':building_stats[:10],'resource_flags':resource_depletion_flags[:10]}, ensure_ascii=False, indent=2))
