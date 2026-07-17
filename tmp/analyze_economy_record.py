from pathlib import Path
import csv, re, json, html
from collections import defaultdict, Counter
ROOT=Path('D:/Godot/ProjectKeynes/Project.Keynes')
PREFIX=ROOT/'tmp/economy_record_20260717_104150_v5_cell1110_q21_r18'
OUT_HTML=ROOT/'tmp/economy_diagnosis_cell1110_20260717.html'
OUT_JSON=ROOT/'tmp/economy_diagnosis_cell1110_20260717_metrics.json'
MONEY=10000; GOODS=1000; Q16=65536

def read_csv(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))

def to_int(x, default=0):
    try:
        return default if x in (None, '') else int(float(x))
    except Exception:
        return default

def to_float(x, default=0.0):
    try:
        return default if x in (None, '') else float(x)
    except Exception:
        return default

paths={k: Path(str(PREFIX)+'_'+k+'.csv') for k in ['summary','cohorts','market','buildings','resources']}
rows={k: read_csv(v) for k,v in paths.items()}

# ---------- parse current catalog resources ----------
FIELD_PAT={}
def read_text(p): return p.read_text(encoding='utf-8', errors='ignore')
def field(txt, name):
    pat=FIELD_PAT.get(name)
    if pat is None:
        pat=re.compile(r'(?m)^'+re.escape(name)+r'\s*=\s*(.+)$')
        FIELD_PAT[name]=pat
    m=pat.search(txt)
    return m.group(1).strip() if m else ''
def sfield(txt, name):
    m=re.match(r'&?"([^"]*)"', field(txt,name))
    return m.group(1) if m else ''
def ifield(txt, name, default=0):
    m=re.match(r'(-?\d+)', field(txt,name))
    return int(m.group(1)) if m else default
def bfield(txt, name, default=False):
    v=field(txt,name).lower()
    if v.startswith('true'): return True
    if v.startswith('false'): return False
    return default
def arr_s(txt, name): return re.findall(r'"([^"]*)"', field(txt,name))
def arr_i(txt, name): return [int(x) for x in re.findall(r'-?\d+', field(txt,name))]
ID_PAT=re.compile(r'(?m)^id\s*=\s*&?"([^"]+)"')
DISP_PAT=re.compile(r'(?m)^display_name\s*=\s*"([^"]*)"')
def parse_dir(path, extra=None):
    out=[]
    for p in sorted(Path(path).glob('*.tres')):
        txt=read_text(p); m=ID_PAT.search(txt)
        if not m: continue
        d={'id':m.group(1),'display_name':(DISP_PAT.search(txt).group(1) if DISP_PAT.search(txt) else ''),'file':str(p.relative_to(ROOT)).replace('\\','/')}
        if extra: d.update(extra(txt))
        out.append(d)
    out.sort(key=lambda x:x['id'])
    return out
prof=parse_dir(ROOT/'Project/project-keynes/data/economy/professions', lambda t:{'plan':sfield(t,'default_consumption_plan_id')})
needs=parse_dir(ROOT/'Project/project-keynes/data/economy/needs')
goods=parse_dir(ROOT/'Project/project-keynes/data/goods', lambda t:{'category':sfield(t,'category_id'),'default_price':ifield(t,'default_price'),'max_price':ifield(t,'max_price'),'price_adjust_q16':ifield(t,'price_adjust_q16'),'merchant_buy_price_factor_q16':ifield(t,'merchant_buy_price_factor_q16',62259),'trade_enabled':bfield(t,'trade_enabled',True)})
blds=parse_dir(ROOT/'Project/project-keynes/data/economy/buildings', lambda t:{
    'kind':sfield(t,'building_kind'), 'tech':arr_s(t,'technology_tags'), 'owner_profession_id':sfield(t,'owner_profession_id'), 'owner_slots_per_building':ifield(t,'owner_slots_per_building',1),
    'employee_profession_ids':arr_s(t,'employee_profession_ids'), 'employee_slots_per_building':arr_i(t,'employee_slots_per_building'),
    'input_good_ids':arr_s(t,'input_good_ids'), 'input_quantities_per_day':arr_i(t,'input_quantities_per_day'), 'input_category_ids':arr_s(t,'input_category_ids'), 'input_min_quality_levels':arr_i(t,'input_min_quality_levels'),
    'output_good_ids':arr_s(t,'output_good_ids'), 'output_quantities_per_day':arr_i(t,'output_quantities_per_day'),
    'resource_ids':arr_s(t,'resource_ids'), 'resource_quantities_per_day':arr_i(t,'resource_quantities_per_day'), 'resource_interaction_modes':arr_s(t,'resource_interaction_modes'),
    'target_operating_margin_q16':ifield(t,'target_operating_margin_q16',9830), 'supply_price_elasticity_q16':ifield(t,'supply_price_elasticity_q16',65536), 'behavior_id':sfield(t,'behavior_id')})
plans=parse_dir(ROOT/'Project/project-keynes/data/economy/consumption_plans', lambda t:{'need_ids':arr_s(t,'need_ids'),'component_good_ids':arr_s(t,'component_good_ids'),'component_qty_per_need':arr_i(t,'component_qty_per_need')})
prof_by_idx={i:d for i,d in enumerate(prof)}; need_by_idx={i:d for i,d in enumerate(needs)}; bld_by_idx={i:d for i,d in enumerate(blds)}; good_by_id={d['id']:d for d in goods}

# ---------- basic info and audits ----------
info={k:{'rows':len(v),'cols':len(v[0]) if v else 0} for k,v in rows.items()}
for k,v in rows.items():
    days=[to_int(r.get('day_index')) for r in v]
    if days:
        info[k].update(day_min=min(days), day_max=max(days), epoch_min=min(to_int(r.get('epoch_id')) for r in v), epoch_max=max(to_int(r.get('epoch_id')) for r in v))
audit={f:max(abs(to_int(r.get(f))) for r in rows['summary']) for f in ['population_error','money_error','goods_error']}
summary_first=rows['summary'][0]
summary_last=rows['summary'][-1]
summary_unemp_max_row=max(rows['summary'], key=lambda r:to_int(r['unemployed_population']))
global_unemp_first=to_int(summary_first['unemployed_population'])
global_unemp_final=to_int(summary_last['unemployed_population'])
global_unemp_max=to_int(summary_unemp_max_row['unemployed_population'])
global_unemp_max_day=to_int(summary_unemp_max_row['day_index'])
global_filled_owner_first=to_int(summary_first['filled_owner_jobs'])
global_filled_owner_final=to_int(summary_last['filled_owner_jobs'])
global_loss_suspended_final=to_int(summary_last['loss_suspended_building_groups'])

# ---------- cohort aggregation ----------
coh_by_epoch=defaultdict(list)
for r in rows['cohorts']: coh_by_epoch[to_int(r['epoch_id'])].append(r)
coh_ts=[]; sig_seen=defaultdict(list)
for ep in sorted(coh_by_epoch):
    rr=coh_by_epoch[ep]; day=to_int(rr[0]['day_index']); worst=Counter()
    total=sum(to_int(r['population']) for r in rr)
    merch=sum(to_int(r['population']) for r in rr if to_int(r['is_merchant']))
    unemp=sum(to_int(r['unemployed']) for r in rr)
    owner=sum(to_int(r['owner_employed']) for r in rr); employee=sum(to_int(r['employee_employed']) for r in rr)
    funds=sum(to_int(r['funds']) for r in rr); merch_funds=sum(to_int(r['funds']) for r in rr if to_int(r['is_merchant']))
    min_sat=65535
    for r in rr:
        pop=to_int(r['population'])
        if pop<=0: continue
        wid=to_int(r['worst_need_id'],-1); worst[wid]+=pop; min_sat=min(min_sat,to_int(r['satisfaction_q16']))
        sig_seen[to_int(r['signature_id'])].append((day,pop,to_int(r['funds']),to_int(r['satisfaction_q16']),wid,to_int(r['profession_id']),to_int(r['is_merchant']),to_int(r['unemployed']),to_int(r['owner_employed']),to_int(r['employee_employed'])))
    wid=worst.most_common(1)[0][0] if worst else -1
    coh_ts.append({'epoch':ep,'day':day,'total_pop':total,'merchant_pop':merch,'nonmerchant_pop':total-merch,'unemployed':unemp,'owner':owner,'employee':employee,'funds':funds,'merchant_funds':merch_funds,'nonmerchant_funds':funds-merch_funds,'merchant_funds_share':merch_funds/funds if funds else 0,'min_satisfaction_q16':min_sat,'dominant_worst_need_id':wid,'dominant_worst_need':need_by_idx.get(wid,{}).get('id',str(wid))})

sig_events=[]
for sig, arr in sig_seen.items():
    arr=sorted(arr); init=arr[0]; last=arr[-1]
    low=next((x for x in arr if x[3] < 32768), None); crit=next((x for x in arr if x[3] < 16384), None)
    near_cash=next((x for x in arr if x[2] <= max(1,x[1])*MONEY), None)
    loss=None; prev=init[1]
    for x in arr[1:]:
        if x[1] < prev: loss=x; break
        prev=x[1]
    pid=last[5]
    sig_events.append({'signature_id':sig,'profession_id':pid,'profession':prof_by_idx.get(pid,{}).get('id',str(pid)),'is_merchant':bool(last[6]),'initial_pop':init[1],'final_pop':last[1],'initial_funds':init[2],'final_funds':last[2],'final_sat':last[3],'final_worst_need':need_by_idx.get(last[4],{}).get('id',str(last[4])),'first_sat_below_50_day':low[0] if low else None,'first_sat_below_25_day':crit[0] if crit else None,'first_near_zero_funds_day':near_cash[0] if near_cash else None,'first_population_loss_day':loss[0] if loss else None,'final_unemployed':last[7],'final_owner':last[8],'final_employee':last[9]})
sig_events.sort(key=lambda d:(d['first_sat_below_50_day'] is None, d['first_sat_below_50_day'] or 999999, d['signature_id']))

# ---------- market aggregation ----------
market_by_good=defaultdict(list)
for r in rows['market']: market_by_good[r['good_id']].append(r)
market_summary=[]
for gid, arr in market_by_good.items():
    arr=sorted(arr,key=lambda r:to_int(r['day_index'])); first=arr[0]; last=arr[-1]
    first_short=next((to_int(r['day_index']) for r in arr if to_int(r['shortage_q16'])>=32768 and (to_int(r['demand_ema'])>0 or to_int(r['business_demand_ema'])>0)), None)
    p0=to_int(first['price']); p1=to_int(last['price'])
    market_summary.append({'good_id':gid,'display_name':good_by_id.get(gid,{}).get('display_name',''),'category':last.get('category_id') or good_by_id.get(gid,{}).get('category',''),'first_price':p0,'final_price':p1,'max_price':max(to_int(r['price']) for r in arr),'price_ratio':p1/p0 if p0 else None,'first_stock':to_int(first['stock']),'final_stock':to_int(last['stock']),'final_available':to_int(last['household_available_stock']),'final_input_reserve':to_int(last['production_input_reserve']),'max_shortage_q16':max(to_int(r['shortage_q16']) for r in arr),'final_shortage_q16':to_int(last['shortage_q16']),'max_pressure_q16':max(to_int(r['price_pressure_total_q16']) for r in arr),'max_demand_ema':max(to_int(r['demand_ema']) for r in arr),'final_demand_ema':to_int(last['demand_ema']),'max_business_demand_ema':max(to_int(r['business_demand_ema']) for r in arr),'final_business_demand_ema':to_int(last['business_demand_ema']),'first_shortage_day':first_short,'procurement_shortfall_final':to_int(last['merchant_procurement_shortfall'])})
market_summary.sort(key=lambda d:(d['final_shortage_q16'], d['final_demand_ema']+d['final_business_demand_ema'], d['price_ratio'] or 0), reverse=True)
focus_goods=['processed_food','gathered_plants','game_meat','chipped_stone_tools','flint','cloth','fur','raw_hide','stone','gold','silver','logs','fish','grain']
focus_market=[d for d in market_summary if d['good_id'] in focus_goods]
def series_good(gid, field, scale=1): return [{'day':to_int(r['day_index']),'v':to_float(r[field])/scale} for r in sorted(market_by_good.get(gid,[]),key=lambda r:to_int(r['day_index']))]

# ---------- building aggregation ----------
bld_by_epoch=defaultdict(list)
for r in rows['buildings']: bld_by_epoch[to_int(r['epoch_id'])].append(r)
bld_ts=defaultdict(list); bld_summary=[]
for ep in sorted(bld_by_epoch):
    day=to_int(bld_by_epoch[ep][0]['day_index'])
    for r in bld_by_epoch[ep]:
        tid=to_int(r['type_id']); bid=bld_by_idx.get(tid,{}).get('id',str(tid))
        bld_ts[bid].append({'day':day,'type_id':tid,'count':to_int(r['count']),'owner_capacity':to_int(r['owner_capacity']),'owner_required':to_int(r['owner_required']),'filled_owner':to_int(r['filled_owner']),'owner_openings':to_int(r['owner_openings']),'employee_required':to_int(r['employee_required']),'employee_filled':to_int(r['employee_filled']),'capacity_q16':to_int(r['capacity_q16']),'planned_utilization_q16':to_int(r['planned_utilization_q16']),'last_input':to_int(r['last_input']),'last_output':to_int(r['last_output']),'last_revenue':to_int(r['last_revenue']),'last_input_cost':to_int(r['last_input_cost']),'last_wages_paid':to_int(r['last_wages_paid']),'last_expected_revenue':to_int(r['last_expected_revenue']),'last_margin_gap_q16':to_int(r['last_margin_gap_q16']),'operating_state':to_int(r['operating_state']),'severe_loss_cycles':to_int(r['severe_loss_cycles'])})
for bid, arr in bld_ts.items():
    arr=sorted(arr,key=lambda x:x['day']); last=arr[-1]; tid=last['type_id']; profid=bld_by_idx.get(tid,{}).get('owner_profession_id','')
    bld_summary.append({'building_id':bid,'display_name':bld_by_idx.get(tid,{}).get('display_name',''),'type_id':tid,'count_final':last['count'],'owner_capacity_final':last['owner_capacity'],'owner_req_final':last['owner_required'],'owner_fill_final':last['filled_owner'],'owner_openings_final':last['owner_openings'],'owner_fill_ratio_final':last['filled_owner']/last['owner_capacity'] if last['owner_capacity'] else None,'employee_req_final':last['employee_required'],'employee_fill_final':last['employee_filled'],'capacity_final_q16':last['capacity_q16'],'capacity_min_q16':min(x['capacity_q16'] for x in arr),'planned_final_q16':last['planned_utilization_q16'],'last_input_final':last['last_input'],'last_output_final':last['last_output'],'last_revenue_final':last['last_revenue'],'last_input_cost_final':last['last_input_cost'],'last_expected_revenue_final':last['last_expected_revenue'],'last_margin_gap_final_q16':last['last_margin_gap_q16'],'operating_state_final':last['operating_state'],'severe_loss_cycles_final':last['severe_loss_cycles'],'first_zero_owner_day':next((x['day'] for x in arr if x['owner_required']>0 and x['filled_owner']==0),None),'first_low_capacity_day':next((x['day'] for x in arr if x['capacity_q16']<32768),None),'owner_profession_id':profid,'inputs':list(zip(bld_by_idx.get(tid,{}).get('input_good_ids',[]), bld_by_idx.get(tid,{}).get('input_quantities_per_day',[]))),'input_categories':bld_by_idx.get(tid,{}).get('input_category_ids',[]),'outputs':list(zip(bld_by_idx.get(tid,{}).get('output_good_ids',[]), bld_by_idx.get(tid,{}).get('output_quantities_per_day',[]))),'resources':list(zip(bld_by_idx.get(tid,{}).get('resource_ids',[]), bld_by_idx.get(tid,{}).get('resource_quantities_per_day',[]), bld_by_idx.get(tid,{}).get('resource_interaction_modes',[])))})
bld_summary.sort(key=lambda d:d['type_id'])

# ---------- resources ----------
res_by_id=defaultdict(list)
for r in rows['resources']: res_by_id[r['resource_id']].append(r)
res_summary=[]
for rid, arr in res_by_id.items():
    arr=sorted(arr,key=lambda r:to_int(r['day_index'])); first=to_float(arr[0]['reserve']); last=to_float(arr[-1]['reserve'])
    res_summary.append({'resource_id':rid,'first':first,'final':last,'delta':last-first,'min':min(to_float(r['reserve']) for r in arr),'max':max(to_float(r['reserve']) for r in arr)})
res_summary.sort(key=lambda d:abs(d['delta']), reverse=True)
res_focus=[r for r in res_summary if r['resource_id'] in ['wild_game','fertile_soil','timber','stone','flint','gold_ore','silver_ore']]

first_coh=coh_ts[0]; last_coh=coh_ts[-1]
first_unemp=next((d for d in coh_ts if d['unemployed']>0), None)
first_death_day=None; prev=coh_ts[0]['total_pop']
for d in coh_ts[1:]:
    if d['total_pop']<prev: first_death_day=d['day']; break
    prev=d['total_pop']
min_sat_row=min(coh_ts,key=lambda d:d['min_satisfaction_q16'])
active_prof_ids=sorted({to_int(r['profession_id']) for r in rows['cohorts']})
active_prof=[prof_by_idx.get(pid,{'id':str(pid),'display_name':''}) for pid in active_prof_ids]

metrics={'info':info,'audit':audit,'global_unemployment':{'first':global_unemp_first,'max':global_unemp_max,'max_day':global_unemp_max_day,'final':global_unemp_final,'filled_owner_first':global_filled_owner_first,'filled_owner_final':global_filled_owner_final,'loss_suspended_building_groups_final':global_loss_suspended_final},'first_cohort':first_coh,'last_cohort':last_coh,'first_unemployment':first_unemp,'first_death_day':first_death_day,'min_sat_row':min_sat_row,'signature_events':sig_events,'focus_market':focus_market,'top_market':market_summary[:30],'buildings':bld_summary,'resources_focus':res_focus,'resources_top':res_summary[:20],'active_professions':active_prof}
OUT_JSON.write_text(json.dumps(metrics,ensure_ascii=False,indent=2),encoding='utf-8')

# ---------- HTML helpers ----------
def esc(x): return html.escape(str(x))
def money(x): return f'{x/MONEY:,.1f}'
def qty(x): return f'{x/GOODS:,.1f}'
def pctq(x): return f'{100*x/Q16:.1f}%'
def day(x): return '—' if x is None else str(x)
def recipe(items): return '—' if not items else ', '.join(f'{a}:{b/GOODS:g}/日' for a,b in items)
def resline(items): return '—' if not items else ', '.join(f'{a}:{b/GOODS:g}/日({c})' for a,b,c in items)
def table(headers, data, keys, fmt=None, max_rows=None):
    fmt=fmt or {}; data=data[:max_rows] if max_rows else data
    s='<table><thead><tr>'+''.join(f'<th>{esc(h)}</th>' for h in headers)+'</tr></thead><tbody>'
    for r in data:
        s+='<tr>'
        for k in keys:
            v=r.get(k,'')
            if k in fmt: v=fmt[k](v,r)
            s+=f'<td>{esc(v)}</td>'
        s+='</tr>'
    return s+'</tbody></table>'
def line_chart(series_list, title, width=980, height=300, yfmt=None, colors=None):
    colors=colors or ['#60a5fa','#f97316','#34d399','#e879f9','#f43f5e','#facc15']
    padL=58; padR=18; padT=35; padB=42; xs=[]; ys=[]
    for _,ser in series_list: xs += [p['day'] for p in ser]; ys += [p['v'] for p in ser]
    if not xs or not ys: return ''
    xmin,xmax=min(xs),max(xs); ymin,ymax=min(ys),max(ys)
    if ymin==ymax: ymin-=1; ymax+=1
    if ymin>0: ymin=0
    def sx(x): return padL+(x-xmin)/(xmax-xmin or 1)*(width-padL-padR)
    def sy(y): return height-padB-(y-ymin)/(ymax-ymin)*(height-padT-padB)
    out=f'<svg class="chart" viewBox="0 0 {width} {height}"><text x="{padL}" y="26" fill="#e2e8f0" font-size="15" font-weight="700">{esc(title)}</text>'
    for i in range(5):
        y=ymin+(ymax-ymin)*i/4; yy=sy(y); label=yfmt(y) if yfmt else f'{y:.0f}'
        out+=f'<line x1="{padL}" y1="{yy:.1f}" x2="{width-padR}" y2="{yy:.1f}" stroke="#334155"/><text x="{padL-8}" y="{yy+4:.1f}" text-anchor="end" fill="#94a3b8" font-size="11">{esc(label)}</text>'
    out+=f'<line x1="{padL}" y1="{height-padB}" x2="{width-padR}" y2="{height-padB}" stroke="#475569"/><line x1="{padL}" y1="{padT}" x2="{padL}" y2="{height-padB}" stroke="#475569"/>'
    for i in range(6):
        x=xmin+(xmax-xmin)*i/5; out+=f'<text x="{sx(x):.1f}" y="{height-16}" text-anchor="middle" fill="#94a3b8" font-size="11">D{int(round(x))}</text>'
    for idx,(name,ser) in enumerate(series_list):
        c=colors[idx%len(colors)]; pts=' '.join(f'{sx(p["day"]):.1f},{sy(p["v"]):.1f}' for p in ser); lx=padL+idx*160
        out+=f'<rect x="{lx}" y="10" width="10" height="10" fill="{c}"/><text x="{lx+16}" y="19" fill="#cbd5e1" font-size="12">{esc(name)}</text><polyline points="{pts}" fill="none" stroke="{c}" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>'
    return out+'</svg>'

pop_series=[{'day':d['day'],'v':d['total_pop']} for d in coh_ts]; unemp_series=[{'day':d['day'],'v':d['unemployed']} for d in coh_ts]
merch_funds=[{'day':d['day'],'v':d['merchant_funds']/MONEY} for d in coh_ts]; non_funds=[{'day':d['day'],'v':d['nonmerchant_funds']/MONEY} for d in coh_ts]
sat_series=[{'day':d['day'],'v':d['min_satisfaction_q16']/Q16*100} for d in coh_ts]
short_proc=series_good('processed_food','shortage_q16',Q16/100); short_game=series_good('game_meat','shortage_q16',Q16/100); short_tool=series_good('chipped_stone_tools','shortage_q16',Q16/100)
price_proc=series_good('processed_food','price',MONEY); price_game=series_good('game_meat','price',MONEY); price_tool=series_good('chipped_stone_tools','price',MONEY)
bld_cap=[]
for bid in ['gathering_ground','stone_age_hunting_camp','knapping_workshop','communal_hearth','household_weaving_shelter']:
    if bid in bld_ts:
        nm=next((x['display_name'] for x in bld_summary if x['building_id']==bid),bid)
        bld_cap.append((nm,[{'day':x['day'],'v':x['capacity_q16']/Q16*100} for x in bld_ts[bid]]))

sig_table=table(['signature','职业','初始人','最终人','最终失业','最终资金','最终满意','最终worst','<50%日','首次减员日'], sig_events, ['signature_id','profession','initial_pop','final_pop','final_unemployed','final_funds','final_sat','final_worst_need','first_sat_below_50_day','first_population_loss_day'], {'final_funds':lambda v,r:money(v),'final_sat':lambda v,r:pctq(v),'first_sat_below_50_day':lambda v,r:day(v),'first_population_loss_day':lambda v,r:day(v)}, 16)
market_table=table(['商品','类别','最终价','涨幅','最终库存','可消费库存','最终短缺','需求EMA','商业需求EMA','首个短缺日'], focus_market, ['good_id','category','final_price','price_ratio','final_stock','final_available','final_shortage_q16','final_demand_ema','final_business_demand_ema','first_shortage_day'], {'final_price':lambda v,r:money(v),'price_ratio':lambda v,r:'—' if v is None else f'{v:.1f}×','final_stock':lambda v,r:qty(v),'final_available':lambda v,r:qty(v),'final_shortage_q16':lambda v,r:pctq(v),'final_demand_ema':lambda v,r:qty(v),'final_business_demand_ema':lambda v,r:qty(v),'first_shortage_day':lambda v,r:day(v)})
bld_table=table(['type_id','建筑','业主职业','数量','owner填充/容量','生产capacity','首个owner归零日','最终输入','最终输出','输入配方','输出配方','资源约束'], bld_summary, ['type_id','building_id','owner_profession_id','count_final','owner_fill_ratio_final','capacity_final_q16','first_zero_owner_day','last_input_final','last_output_final','inputs','outputs','resources'], {'owner_fill_ratio_final':lambda v,r:'—' if v is None else f'{r["owner_fill_final"]}/{r["owner_capacity_final"]} ({100*v:.1f}%)','capacity_final_q16':lambda v,r:pctq(v),'first_zero_owner_day':lambda v,r:day(v),'last_input_final':lambda v,r:qty(v),'last_output_final':lambda v,r:qty(v),'inputs':lambda v,r:recipe(v),'outputs':lambda v,r:recipe(v),'resources':lambda v,r:resline(v)})
res_table=table(['资源','初始reserve','最终reserve','变化','最小','最大'], res_focus, ['resource_id','first','final','delta','min','max'], {'first':lambda v,r:f'{v:,.2f}','final':lambda v,r:f'{v:,.2f}','delta':lambda v,r:f'{v:,.2f}','min':lambda v,r:f'{v:,.2f}','max':lambda v,r:f'{v:,.2f}'})

html_doc=f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Project.Keynes 选中格经济运行诊断</title><style>
:root{{--bg:#0f172a;--panel:#111827;--panel2:#1e293b;--text:#e5e7eb;--muted:#94a3b8;--line:#334155;--accent:#60a5fa;--bad:#fb7185;--warn:#fbbf24;--good:#34d399}}*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif}}.wrap{{max-width:1180px;margin:0 auto;padding:28px}}h1{{font-size:28px;margin:0 0 6px}}h2{{font-size:21px;margin:32px 0 12px;border-left:4px solid var(--accent);padding-left:10px}}h3{{font-size:16px;color:#dbeafe}}.muted{{color:var(--muted)}}.grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:18px 0}}.card{{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:14px;padding:14px}}.k{{color:var(--muted);font-size:12px}}.v{{font-size:24px;font-weight:750}}.bad{{color:var(--bad)}}.warn{{color:var(--warn)}}.good{{color:var(--good)}}table{{width:100%;border-collapse:collapse;margin:10px 0 18px;background:var(--panel);border:1px solid var(--line)}}th,td{{border-bottom:1px solid var(--line);padding:7px 9px;vertical-align:top}}th{{text-align:left;background:#1f2937;color:#bfdbfe}}code{{background:#020617;border:1px solid #1e293b;padding:1px 5px;border-radius:5px}}.chart{{width:100%;background:#111827;border:1px solid var(--line);border-radius:14px;margin:12px 0;padding:8px}}.note{{border-left:4px solid var(--warn);background:#1f2937;padding:12px 14px;border-radius:10px;margin:12px 0}}.danger{{border-left-color:var(--bad)}}li{{margin:5px 0}}.two{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}@media(max-width:900px){{.grid,.two{{grid-template-columns:1fr}}}}</style></head><body><div class="wrap">
<h1>Project.Keynes 选中格经济运行诊断</h1><div class="muted">记录前缀：<code>economy_record_20260717_104150_v5_cell1110_q21_r18</code>；选中格 cell=1110 / q=21 r=18。summary 为全局运行时汇总；cohorts/market/buildings/resources 为选中格视角。</div>
<div class="grid"><div class="card"><div class="k">选中格人口</div><div class="v bad">{last_coh['total_pop']} / {first_coh['total_pop']}</div><div class="muted">下降 {first_coh['total_pop']-last_coh['total_pop']}，首个减员日 D{first_death_day}</div></div><div class="card"><div class="k">全局失业 max / final</div><div class="v warn">{global_unemp_max} / {global_unemp_final}</div><div class="muted">峰值日 D{global_unemp_max_day}；选中格 final={last_coh['unemployed']}</div></div><div class="card"><div class="k">最终最低满意度</div><div class="v bad">{last_coh['min_satisfaction_q16']/Q16*100:.1f}%</div><div class="muted">主导 worst need：{esc(last_coh['dominant_worst_need'])}</div></div><div class="card"><div class="k">审计错误</div><div class="v good">0 / 0 / 0</div><div class="muted">population/money/goods 最大绝对误差：{audit['population_error']}/{audit['money_error']}/{audit['goods_error']}</div></div></div>
<h2>0. 当前经济运行体现出的特点</h2><ul><li><b>账本守恒但局部经济衰退</b>：审计全程为 0；选中格人口从 {first_coh['total_pop']} 降到 {last_coh['total_pop']}，最低满意度曾降至 {min_sat_row['min_satisfaction_q16']/Q16*100:.1f}%，最终回到 {last_coh['min_satisfaction_q16']/Q16*100:.1f}%。</li><li><b>“大量失业”在这份记录里不是持续终态</b>：全局失业峰值 {global_unemp_max}（D{global_unemp_max_day}），最终 {global_unemp_final}；选中格最终失业 {last_coh['unemployed']}。更显著的是 owner 岗位/建筑产能塌缩：全局 owner jobs 从 {global_filled_owner_first} 降到 {global_filled_owner_final}，loss-suspended groups 最终 {global_loss_suspended_final}。</li><li><b>商人吸纳资金，非商户现金枯竭</b>：最终商人资金 {money(last_coh['merchant_funds'])}，非商户资金 {money(last_coh['nonmerchant_funds'])}，商人持有本格资金 {last_coh['merchant_funds_share']*100:.1f}%。</li><li><b>生存品和工具链一起短缺</b>：<code>processed_food</code>、<code>game_meat</code>、<code>chipped_stone_tools</code> 高短缺/高价格，蛋白与熟食供应不足成为满意度和死亡核心压力。</li><li><b>就业是真实 cohort 迁移</b>：未被建筑保留/招募的人迁往 <code>unemployed|eth</code>，失业者退化消费并因低满意度自然死亡。</li></ul>{line_chart([('总人口',pop_series),('失业人口',unemp_series)],'选中格人口与失业')}{line_chart([('商人资金',merch_funds),('非商户资金',non_funds)],'选中格资金分布（货币单位）',yfmt=lambda y:f'{y/1000:.0f}k')}
<h2>1. 经济运行是否健康？</h2><div class="note danger"><b>结论：不健康，但不是账本腐坏。</b> 这是“守恒的萎缩/饥饿经济”：市场与建筑结算闭合，但早期内容配置和就业/供给反馈导致食物、蛋白、工具同时吃紧，建筑产能与人口下降。</div><ul><li>健康侧：审计全零、资源未耗尽、价格按短缺上涨，说明 C++ authority 路径基本在运行。</li><li>不健康侧：D{first_death_day} 开始人口净损，最终人口损失 {first_coh['total_pop']-last_coh['total_pop']}；全局 owner jobs 大幅缩水，选中格狩猎营地/打制工坊等关键建筑后期停摆。</li></ul>{line_chart([('最低满意度%',sat_series),('processed_food短缺%',short_proc),('game_meat短缺%',short_game),('工具短缺%',short_tool)],'满意度与关键短缺')}
<h2>2. 为什么会产生大量失业者？</h2><ul><li><b>先校正数据口径</b>：这份导出里，选中格并没有持续大量失业（最终 0），全局失业也是 D{global_unemp_max_day} 峰值 {global_unemp_max}、最终 {global_unemp_final}。真正大的问题是“潜在岗位/建筑产能闲置 + 人口死亡吸收了失业压力”。</li><li><b>直接机制</b>：<code>run_building_employment_cell()</code> 的 A1 逻辑先按建筑目标保留在岗人口，<code>surplus = population - retained</code> 迁入 unemployed 池；再按利润、计划利用率和 group_index 招人。</li><li><b>本格触发链</b>：狩猎营地和打制工坊后期 owner 填充归零/接近归零，食物与工具产出下降；产出下降让生产者收入下降，低满意度和死亡随后发生。</li><li><b>建筑结构原因</b>：早期多数建筑只有 owner 岗，岗位数与建筑数直接决定吸纳能力；食物链、工具链失效后没有替代岗位。</li><li><b>优先级副作用</b>：招人按利润优先，贵金属/商栈等可盈利或保底岗位可能挤压食物链岗位。</li></ul>{sig_table}
<h2>3. 建筑原材料与产出设计是否科学？</h2><div class="note"><b>局部不科学：早期生命线过窄、互锁过硬。</b> 狩猎依赖工具，工具依赖燧石/打制工坊，火塘又同时依赖植物+肉；一处就业或输入不足会级联到蛋白、熟食和满意度。</div><ul><li><code>gathering_ground</code> 2 owner/栋，产 gathered_plants 7/日，作为主食底座合理但对岗位数敏感。</li><li><code>stone_age_hunting_camp</code> 2 owner/栋，消耗 tools 类 0.005/日，产 game_meat/raw_hide/fur；工具短缺会直接切断 protein。</li><li><code>communal_hearth</code> 植物+肉转 processed_food；营养逻辑合理，但会把蛋白短缺放大成全体熟食短缺。</li><li>生产比率有调参空间：火塘 1.0 植物 + 0.5 肉 → 1.804 熟食；狩猎 0.005 工具 → 3.728 肉；打制 3 flint → 4.124 tools。</li></ul>{line_chart(bld_cap,'核心建筑 capacity_q16（%）')}{bld_table}
<h2>4. 市场机制、物价机制是否科学？</h2><ul><li><b>机制有经济学骨架</b>：需求按人口、财富、环境、民族系数计算；消费按 priority 与预算约束；价格压力综合需求、库存、短缺、成本锚和 inactive reversion。</li><li><b>当前参数放大危机</b>：生存品涨价会把贫困 cohort 挤出消费；商人买入产出默认接近零售价 95%，但建筑停产/失业时缺少向失业者回流的渠道。</li><li><b>单格市场太局部</b>：一格一市场让蛋白/工具断供无法被邻格缓冲，价格只能报警，不能修复供给。</li><li><b>缺少社会优先级</b>：短缺时市场利润优先可能让非生存部门仍有吸引力，而食物链因为输入或利润问题失去岗位。</li></ul>{line_chart([('processed_food价格',price_proc),('game_meat价格',price_game),('chipped_stone_tools价格',price_tool)],'关键商品价格（货币单位/单位）',yfmt=lambda y:f'{y:.0f}')}{market_table}
<h2>5. 阶层流动、消费、存款变化是否科学？</h2><ul><li><b>方向合理</b>：就业状态由建筑需求决定，失业池可跨职业招募；消费不足降低满意度，低于阈值后增加 starvation death rate。</li><li><b>但缺少早期社会缓冲</b>：石器时代更像家庭/氏族共享，而这里已高度货币化；失业者只有退化消费，没有公共粮储、亲族再分配、非市场自给或季节性储备。</li><li><b>阶层流动过机械</b>：岗位完全由建筑 groups 提供，没有兼职、自给采集、临时劳动、公共工程时，失业池会成为死亡池。</li><li><b>存款分布不健康</b>：最终商人资金占比 {last_coh['merchant_funds_share']*100:.1f}%，交易收益沉淀到商人。</li></ul>
<h2>6. 如何改进经济模型？</h2><h3>P0：先救石器时代生命线</h3><ul><li>给 <code>unemployed</code> 或所有早期职业增加低产自给能力：foraging/fishing/firewood fallback。</li><li>降低公共火塘对 <code>game_meat</code> 的刚性：植物可低效率产熟食，肉作为 protein/效率加成。</li><li>狩猎工具改耐久/资本品消耗，或把工具短缺改成 capacity multiplier，而不是让蛋白归零。</li><li>食物/蛋白/基础保暖建筑获得 survival priority，不完全按利润招人。</li></ul><h3>P1：调市场与货币回流</h3><ul><li>给生存品更低价格弹性/价格上限或公共采购机制。</li><li>引入村社粮仓或 merchant reserve release，在 food/protein shortage 高且失业高时释放库存。</li><li>把一格一市场扩展为早期邻接互助/低容量贸易，先对 food/tools/clothing 开放。</li><li>动态化商人 margin/buy factor，避免短缺期利润长期沉淀。</li></ul><h3>P2：让内容配置可验证</h3><ul><li>建立石器时代生存闭环验算表：每 100 人需要多少 staple/protein/clothing/tools，默认建筑是否能覆盖 120 天。</li><li>自动计算每个建筑：日输入价值、日输出价值、owner slots、人均食物覆盖、关键输入断供风险。</li><li>新增回归场景：N=1 与 N=5 下，早期标准格 1 年内不应因工具/蛋白链断供自然崩溃；审计仍为 0。</li></ul>
<h2>数据与源码依据</h2><div class="two"><div>{res_table}</div><div><table><thead><tr><th>依据</th><th>位置/规则</th></tr></thead><tbody><tr><td>需求计算</td><td><code>gdext/src/economy_runtime.cpp:881</code>：population × base_qty × N × wealth/env/ethnicity/composite</td></tr><tr><td>就业迁移</td><td><code>gdext/src/economy_runtime.cpp:4328</code>：未保留就业人口迁入 unemployed，按利润/利用率招回</td></tr><tr><td>价格机制</td><td><code>gdext/src/economy_runtime.cpp:3883</code> 与 <code>:8672</code>：短缺、库存、成本锚、需求压力更新价格</td></tr><tr><td>建筑 profile</td><td><code>Project/project-keynes/data/economy/buildings/*.tres</code>，按 <code>BuildingProfile.id</code> 字符串排序映射 type_id</td></tr><tr><td>消费计划</td><td><code>Project/project-keynes/data/economy/consumption_plans/*.tres</code>：need→variant→component goods</td></tr></tbody></table></div></div><p class="muted">本报告只读分析生成，没有修改运行时代码或资源配置。详细聚合指标另存为 <code>{OUT_JSON.name}</code>。</p></div></body></html>'''
OUT_HTML.write_text(html_doc,encoding='utf-8')
print(json.dumps({'html':str(OUT_HTML),'json':str(OUT_JSON),'summary':{'record_info':info,'audit':audit,'first_cohort':first_coh,'last_cohort':last_coh,'first_death_day':first_death_day,'first_unemployment_day':first_unemp['day'] if first_unemp else None,'top_focus_market':focus_market[:8]}},ensure_ascii=False,indent=2))
