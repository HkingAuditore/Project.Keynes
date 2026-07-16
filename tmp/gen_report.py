import csv, collections

BASE = "economy_record_20260716_113937_v5_cell643_q-5_r16_"
coh = list(csv.DictReader(open(BASE + "cohorts.csv", encoding="utf-8-sig")))
byep = collections.OrderedDict()
for r in coh:
    e = r["epoch_id"]; byep.setdefault(e, 0); byep[e] += int(r["population"])

mk = list(csv.DictReader(open(BASE + "market.csv", encoding="utf-8-sig")))
byg = collections.defaultdict(list)
for r in mk:
    byg[r["good_id"]].append(r)
def mx(g, f): return max(int(x[f]) for x in byg[g])
foods = []
for g in byg:
    d = mx(g, "demand_ema"); s = mx(g, "shortage_q16"); st = max(int(x["stock"]) for x in byg[g])
    if d > 0 or s > 0:
        foods.append((g, d, s, st))
foods.sort(key=lambda t: (-t[1]))
foods = foods[:8]

# ---- SVG: population collapse ----
W, H = 660, 260; x0, y0, x1, y1 = 55, 25, 625, 215
pts = []
n = len(byep); maxpop = 50
for i, (e, p) in enumerate(byep.items()):
    X = x0 + (x1 - x0) * i / (n - 1)
    Y = y1 - (y1 - y0) * p / maxpop
    pts.append((X, Y))
poly = " ".join("%.1f,%.1f" % (X, Y) for X, Y in pts)
grid = ""
for p in [0, 10, 20, 30, 40, 50]:
    Y = y1 - (y1 - y0) * p / maxpop
    grid += '<line x1="%g" y1="%.1f" x2="%g" y2="%.1f" stroke="#30363d" stroke-width="1"/>' % (x0, Y, x1, Y)
    grid += '<text x="%g" y="%.1f" fill="#8b949e" font-size="11" text-anchor="end">%d</text>' % (x0 - 8, Y + 4, p)
xt = ""
for lbl, ep in [("d105", 1), ("d350", 50), ("d550", 100), ("d750", 150), ("d955", 191), ("d1430", 266)]:
    if ep in byep:
        i = list(byep).index(ep); X = x0 + (x1 - x0) * i / (n - 1)
        xt += '<text x="%.1f" y="%g" fill="#8b949e" font-size="10" text-anchor="middle">%s</text>' % (X, y1 + 18, lbl)
svg_pop = ('<svg viewBox="0 0 %g %g" xmlns="http://www.w3.org/2000/svg">'
           '<rect width="%g" height="%g" fill="#0d1117"/>'
           '<text x="%g" y="16" fill="#c9d1d9" font-size="13" text-anchor="middle" font-family="sans-serif">'
           'Population collapse (cell 643, %d epochs / 1430 days)</text>%s%s'
           '<polyline points="%s" fill="none" stroke="#f0883e" stroke-width="2.5"/>'
           '<circle cx="%.1f" cy="%.1f" r="3" fill="#3fb950"/>'
           '<circle cx="%.1f" cy="%.1f" r="3" fill="#f85149"/>'
           '<text x="%.1f" y="%.1f" fill="#3fb950" font-size="11">start 50</text>'
           '<text x="%.1f" y="%.1f" fill="#f85149" font-size="11">end 1</text>'
           '</svg>') % (W, H, W, H, W/2, n, grid, xt, poly,
                        pts[0][0], pts[0][1], pts[-1][0], pts[-1][1],
                        pts[0][0] + 4, pts[0][1] - 6, pts[-1][0] - 40, pts[-1][1] - 6)

# ---- SVG: food demand/shortage bars ----
BW, BH = 660, 250; bx0 = 150; by_top = 20; rowh = 26
bars = ""
for i, (g, d, s, st) in enumerate(foods):
    Y = by_top + i * rowh
    bw = min(d, 25000) / 25000 * (BW - bx0 - 150)
    col = "#f85149" if s >= 65535 else "#d29922"
    bars += '<text x="%g" y="%.1f" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">%s</text>' % (bx0 - 8, Y + 13, g)
    bars += '<rect x="%g" y="%.1f" width="%.1f" height="16" fill="%s"/>' % (bx0, Y + 2, bw, col)
    bars += '<text x="%.1f" y="%.1f" fill="#8b949e" font-size="10" font-family="sans-serif">demand %d / shortage %d / stock %d</text>' % (bx0 + bw + 6, Y + 14, d, s, st)
svg_food = ('<svg viewBox="0 0 %g %g" xmlns="http://www.w3.org/2000/svg">'
            '<rect width="%g" height="%g" fill="#0d1117"/>'
            '<text x="%g" y="14" fill="#c9d1d9" font-size="13" text-anchor="middle" font-family="sans-serif">'
            'Food goods with demand (red = persistent max shortage 65535)</text>%s'
            '</svg>') % (BW, BH, BW, BH, BW/2, bars)

report = """# Cell 643 经济崩溃诊断报告

**数据文件**: `economy_record_20260716_113937_v5_cell643_q-5_r16_*.csv`
**地块参数**: cell_idx=643, q=-5, r=16, s=-11（石器时代 tier）
**时间跨度**: day 105 -> 1430（266 个经济周期，每周期 5 天）

## 一、结论（一句话）

这是一个**石器时代地块，食物供给结构性断裂**：它只有一座狩猎营能提供肉食（game_meat），
而占需求前两位的 **gathered_plants（采集植物，需求 22000）** 和 **processed_food（加工食品，需求 11998）**
在本格**根本没有对应生产建筑**，从第一天起就处于最大短缺（shortage=65535）。唯一的肉食来源又因业主群体死亡而停摆，
于是食品需求全面崩溃 -> 人口从 50 缓慢饿死到 1 -> 所有建筑因业主消失而产能归零 -> 经济彻底停产。

## 二、人口轨迹

%s

| 周期(day) | 人口 | 阶段 |
|---|---|---|
| 1 (105) | 50 | 起点：4 个群体（sig 2/9/12/20） |
| 50 (350) | 43 | 慢速萎缩，食品需求已长期未满足 |
| 100 (550) | 17 | **陡降段**：狩猎营产能崩塌，肉食耗尽 |
| 150 (750) | 5 | 加速死亡 |
| 191 (955) | 1 | 仅剩 1 个商人型群体(sig 20) |
| 266 (1430) | 1 | 终态：1 人、满意度 0、失业、资金 8.9M |

> 每个群体从第一天起 `worst_need_id=13`，即 **staple_food（食品，"食品"）需求**始终未被满足。

## 三、根因：食物供给的两大缺口

本格全部 6 座建筑（按 type_id 映射）：

| type_id | 建筑 | 产出 | 是否食物 |
|---|---|---|---|
| 237 | stone_age_hunting_camp（狩猎营） | game_meat / raw_hide / fur | 唯一食物源 |
| 65 | flint_quarry（燧石矿） | flint | 否 |
| 90 | knapping_workshop（打制石器） | chipped_stone_tools | 否 |
| 238 | stone_collector（采石） | raw_stone | 否 |
| 202 | placer_gold_working（砂金） | gold | 否 |
| 241 | surface_silver_working（地表银） | silver | 否 |

全局建筑目录里 **能产 gathered_plants 的是 `gathering_ground`、能产 processed_food 的是 `processed_food_plant`/`communal_hearth`**——
**本格两样都没有**。于是：

%s

- **gathered_plants** 需求 22000，库存 0，短缺 65535（全期最大）—— 没有任何采集场。
- **processed_food** 需求 11998，库存 0，短缺 65535 —— 没有加工/公共炉灶建筑。
- **game_meat** 需求 22000，前期有库存（峰值 293630，来自狩猎营），但后期耗尽 -> 短缺 65535。
- fish / logs / chipped_stone_tools / cloth 也全在最大短缺，但非主因。

此外本格明明拥有 `arable_land=125000`、`pasture=125000`、`fertile_soil`（可再生）、`wild_game`（可再生），
却**未放置任何农场/牧场/采集场**——农业用地完全闲置，进一步印证是**建筑布置缺口**而非资源短缺。

## 四、崩溃的放大器（为什么雪崩）

1. **单一故障点（SPOF）**：唯一食物源 = 一座狩猎营，且其业主是 sig 12 群体。
   狩猎营 `capacity_q16`：17420(day105) -> 110(day500) -> 0(day1100，业主消亡)。
   业主一死，产能归零，肉食停产，库存被吃完。
2. **零贸易缓冲**：所有食物物资 `trade_inbound=0`（鱼/加工食品/采集植物全为 0 进口）。
   全局 `trade_runtime_mode=ACTIVE` 且 `trade_topology_ready=true`，但**本格孤立**，无法进口食物续命。
3. **正反馈**：人口饿死 -> 建筑业主消失 -> 所有建筑 `capacity->0`、全部停产（非亏损停摆，
   `operating_state` 全程=0=ACTIVE，无 loss-suspension）-> 经济彻底停摆。
4. **疑似分配 bug（待查源码确认）**：狩猎营在 day105 当周期 `last_sold=0 / last_discarded=10441 / out=10725`——
   产出几乎全部被丢弃、零成交。若建筑产能按"实际售出/利用率"节流，则"有食物却送不到人手里->产能被压垮->停产"
   会把 shortages 进一步放大。需核对 `economy_runtime.cpp` 中 `capacity_q16` 的更新逻辑。

## 五、终态

- 仅剩 1 个群体：sig 20（商人型，is_merchant=1），人口 1，资金 8.9M，满意度 0，失业 1。
- 6 座建筑全部 `capacity=0`、output=0；所有食物物资库存 0、短缺 65535。
- 守恒检查：`population_error / money_error / goods_error` 全为 0（无数值泄漏，是真实的经济死亡）。

## 六、修复建议（按优先级）

**P0 — 补上石器时代食物建筑（内容/布置缺口）**
- 给此类石器时代地块强制布置 `gathering_ground`（产 gathered_plants）与 `communal_hearth`
  （产 processed_food / 熟食）；否则食品需求结构性不可满足。
- 校验建筑布置逻辑：当 cell 拥有 `arable_land`/`pasture`/`fertile_soil` 时，应至少放置 1 座农场/牧场/采集场。

**P1 — 打通贸易缓冲**
- 排查为何该格 `trade_inbound=0`：食物短缺格应能从邻格进口 game_meat/processed_food，避免单格孤立致崩。

**P2 — 核实产能节流逻辑**
- 确认 `capacity_q16` 是否因"售出=0/利用率低"被压到接近 0；若是，需让"本地有库存但家庭未购买"
  不再反向掐死产能（否则会自我实现食物断供）。

**P2 — 监控指标**
- 对任何 `worst_need_id` 持续 = staple_food 且 `shortage_q16=65535` 超过 N 周期的地块告警；
  当前该格从 day105 起即触发，属典型"出生即饿死"配置。
""" % (svg_pop, svg_food)

open("cell643_经济崩溃诊断.md", "w", encoding="utf-8").write(report)
open("cell643_pop.svg", "w", encoding="utf-8").write(svg_pop)
open("cell643_food.svg", "w", encoding="utf-8").write(svg_food)
print("report + svgs written")
print("top foods:", foods)
