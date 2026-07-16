# Cell 643 经济崩溃诊断报告

**数据文件**: `economy_record_20260716_113937_v5_cell643_q-5_r16_*.csv`
**地块参数**: cell_idx=643, q=-5, r=16, s=-11（石器时代 tier）
**时间跨度**: day 105 -> 1430（266 个经济周期，每周期 5 天）

## 一、结论（一句话）

这是一个**石器时代地块，食物供给结构性断裂 + 中间投入品级联断供**：它只有一座狩猎营能提供肉食（game_meat），
而占需求前两位的 **gathered_plants（采集植物，需求 22000）** 和 **processed_food（加工食品，需求 11998）**
在本格**根本没有对应生产建筑**，从第一天起就处于最大短缺（shortage=65535）。更致命的是：狩猎营生产 game_meat 需要
**chipped_stone_tools 作为中间投入**，而石器工具坊的业主群体（prof2 artisan）先因买不起食物资金枯竭、槽位空缺（d405），
导致 chipped_stone_tools 库存 325→1（d410→d420）断供；狩猎营随之 `last_input` 143→0（d425）、game_meat 产出 62204→426（−99.3%），
于是唯一食物源断供 -> 人口从 50 缓慢饿死到 1 -> 所有建筑正反馈停产 -> 经济彻底崩塌。
（注意：狩猎营停产时其业主槽位仍填满、产能想开却无料可买；真正先死的是上游工具链，而非狩猎营业主。）

## 二、人口轨迹

<svg viewBox="0 0 660 260" xmlns="http://www.w3.org/2000/svg"><rect width="660" height="260" fill="#0d1117"/><text x="330" y="16" fill="#c9d1d9" font-size="13" text-anchor="middle" font-family="sans-serif">Population collapse (cell 643, 266 epochs / 1430 days)</text><line x1="55" y1="215.0" x2="625" y2="215.0" stroke="#30363d" stroke-width="1"/><text x="47" y="219.0" fill="#8b949e" font-size="11" text-anchor="end">0</text><line x1="55" y1="177.0" x2="625" y2="177.0" stroke="#30363d" stroke-width="1"/><text x="47" y="181.0" fill="#8b949e" font-size="11" text-anchor="end">10</text><line x1="55" y1="139.0" x2="625" y2="139.0" stroke="#30363d" stroke-width="1"/><text x="47" y="143.0" fill="#8b949e" font-size="11" text-anchor="end">20</text><line x1="55" y1="101.0" x2="625" y2="101.0" stroke="#30363d" stroke-width="1"/><text x="47" y="105.0" fill="#8b949e" font-size="11" text-anchor="end">30</text><line x1="55" y1="63.0" x2="625" y2="63.0" stroke="#30363d" stroke-width="1"/><text x="47" y="67.0" fill="#8b949e" font-size="11" text-anchor="end">40</text><line x1="55" y1="25.0" x2="625" y2="25.0" stroke="#30363d" stroke-width="1"/><text x="47" y="29.0" fill="#8b949e" font-size="11" text-anchor="end">50</text><polyline points="55.0,25.0 57.2,25.0 59.3,28.8 61.5,32.6 63.6,32.6 65.8,32.6 67.9,32.6 70.1,32.6 72.2,32.6 74.4,32.6 76.5,36.4 78.7,36.4 80.8,36.4 83.0,36.4 85.1,36.4 87.3,36.4 89.4,36.4 91.6,36.4 93.7,36.4 95.9,36.4 98.0,36.4 100.2,40.2 102.3,40.2 104.5,40.2 106.6,40.2 108.8,40.2 110.9,40.2 113.1,44.0 115.2,44.0 117.4,44.0 119.5,44.0 121.7,44.0 123.8,44.0 126.0,44.0 128.1,44.0 130.3,44.0 132.4,44.0 134.6,47.8 136.7,47.8 138.9,47.8 141.0,47.8 143.2,47.8 145.3,47.8 147.5,47.8 149.6,47.8 151.8,47.8 153.9,51.6 156.1,51.6 158.2,51.6 160.4,51.6 162.5,51.6 164.7,51.6 166.8,51.6 169.0,51.6 171.2,51.6 173.3,55.4 175.5,55.4 177.6,55.4 179.8,55.4 181.9,59.2 184.1,59.2 186.2,59.2 188.4,59.2 190.5,59.2 192.7,63.0 194.8,63.0 197.0,70.6 199.1,70.6 201.3,78.2 203.4,78.2 205.6,82.0 207.7,82.0 209.9,89.6 212.0,93.4 214.2,97.2 216.3,97.2 218.5,101.0 220.6,101.0 222.8,108.6 224.9,108.6 227.1,112.4 229.2,116.2 231.4,116.2 233.5,120.0 235.7,123.8 237.8,123.8 240.0,127.6 242.1,127.6 244.3,127.6 246.4,127.6 248.6,139.0 250.7,139.0 252.9,139.0 255.0,142.8 257.2,142.8 259.3,142.8 261.5,142.8 263.6,146.6 265.8,150.4 267.9,150.4 270.1,150.4 272.2,154.2 274.4,154.2 276.5,158.0 278.7,158.0 280.8,161.8 283.0,161.8 285.2,161.8 287.3,165.6 289.5,165.6 291.6,169.4 293.8,169.4 295.9,169.4 298.1,169.4 300.2,169.4 302.4,169.4 304.5,173.2 306.7,173.2 308.8,173.2 311.0,173.2 313.1,173.2 315.3,177.0 317.4,180.8 319.6,184.6 321.7,184.6 323.9,184.6 326.0,184.6 328.2,184.6 330.3,184.6 332.5,184.6 334.6,184.6 336.8,188.4 338.9,188.4 341.1,188.4 343.2,188.4 345.4,188.4 347.5,188.4 349.7,188.4 351.8,188.4 354.0,188.4 356.1,188.4 358.3,196.0 360.4,196.0 362.6,196.0 364.7,196.0 366.9,196.0 369.0,196.0 371.2,196.0 373.3,196.0 375.5,196.0 377.6,196.0 379.8,196.0 381.9,196.0 384.1,196.0 386.2,196.0 388.4,199.8 390.5,199.8 392.7,199.8 394.8,199.8 397.0,199.8 399.2,199.8 401.3,199.8 403.5,199.8 405.6,203.6 407.8,203.6 409.9,203.6 412.1,203.6 414.2,203.6 416.4,203.6 418.5,203.6 420.7,203.6 422.8,203.6 425.0,203.6 427.1,203.6 429.3,203.6 431.4,203.6 433.6,203.6 435.7,203.6 437.9,203.6 440.0,203.6 442.2,207.4 444.3,207.4 446.5,207.4 448.6,207.4 450.8,207.4 452.9,207.4 455.1,207.4 457.2,207.4 459.4,207.4 461.5,207.4 463.7,211.2 465.8,211.2 468.0,211.2 470.1,211.2 472.3,211.2 474.4,211.2 476.6,211.2 478.7,211.2 480.9,211.2 483.0,211.2 485.2,211.2 487.3,211.2 489.5,211.2 491.6,211.2 493.8,211.2 495.9,211.2 498.1,211.2 500.2,211.2 502.4,211.2 504.5,211.2 506.7,211.2 508.8,211.2 511.0,211.2 513.2,211.2 515.3,211.2 517.5,211.2 519.6,211.2 521.8,211.2 523.9,211.2 526.1,211.2 528.2,211.2 530.4,211.2 532.5,211.2 534.7,211.2 536.8,211.2 539.0,211.2 541.1,211.2 543.3,211.2 545.4,211.2 547.6,211.2 549.7,211.2 551.9,211.2 554.0,211.2 556.2,211.2 558.3,211.2 560.5,211.2 562.6,211.2 564.8,211.2 566.9,211.2 569.1,211.2 571.2,211.2 573.4,211.2 575.5,211.2 577.7,211.2 579.8,211.2 582.0,211.2 584.1,211.2 586.3,211.2 588.4,211.2 590.6,211.2 592.7,211.2 594.9,211.2 597.0,211.2 599.2,211.2 601.3,211.2 603.5,211.2 605.6,211.2 607.8,211.2 609.9,211.2 612.1,211.2 614.2,211.2 616.4,211.2 618.5,211.2 620.7,211.2 622.8,211.2 625.0,211.2" fill="none" stroke="#f0883e" stroke-width="2.5"/><circle cx="55.0" cy="25.0" r="3" fill="#3fb950"/><circle cx="625.0" cy="211.2" r="3" fill="#f85149"/><text x="59.0" y="19.0" fill="#3fb950" font-size="11">start 50</text><text x="585.0" y="205.2" fill="#f85149" font-size="11">end 1</text></svg>

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

<svg viewBox="0 0 660 250" xmlns="http://www.w3.org/2000/svg"><rect width="660" height="250" fill="#0d1117"/><text x="330" y="14" fill="#c9d1d9" font-size="13" text-anchor="middle" font-family="sans-serif">Food goods with demand (red = persistent max shortage 65535)</text><text x="142" y="33.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">game_meat</text><rect x="150" y="22.0" width="316.8" height="16" fill="#f85149"/><text x="472.8" y="34.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 22002 / shortage 65535 / stock 293630</text><text x="142" y="59.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">gathered_plants</text><rect x="150" y="48.0" width="316.8" height="16" fill="#f85149"/><text x="472.8" y="60.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 22000 / shortage 65535 / stock 0</text><text x="142" y="85.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">processed_food</text><rect x="150" y="74.0" width="172.8" height="16" fill="#f85149"/><text x="328.8" y="86.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 11998 / shortage 65535 / stock 0</text><text x="142" y="111.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">logs</text><rect x="150" y="100.0" width="45.2" height="16" fill="#f85149"/><text x="201.2" y="112.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 3136 / shortage 65535 / stock 0</text><text x="142" y="137.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">fish</text><rect x="150" y="126.0" width="25.9" height="16" fill="#f85149"/><text x="181.9" y="138.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 1801 / shortage 65535 / stock 0</text><text x="142" y="163.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">fur</text><rect x="150" y="152.0" width="13.5" height="16" fill="#d29922"/><text x="169.5" y="164.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 940 / shortage 0 / stock 505863</text><text x="142" y="189.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">chipped_stone_tools</text><rect x="150" y="178.0" width="5.4" height="16" fill="#f85149"/><text x="161.4" y="190.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 372 / shortage 65535 / stock 13980</text><text x="142" y="215.0" fill="#c9d1d9" font-size="11" text-anchor="end" font-family="sans-serif">cloth</text><rect x="150" y="204.0" width="0.1" height="16" fill="#f85149"/><text x="156.1" y="216.0" fill="#8b949e" font-size="10" font-family="sans-serif">demand 10 / shortage 65535 / stock 0</text></svg>

- **gathered_plants** 需求 22000，库存 0，短缺 65535（全期最大）—— 没有任何采集场。
- **processed_food** 需求 11998，库存 0，短缺 65535 —— 没有加工/公共炉灶建筑。
- **game_meat** 需求 22000，前期有库存（峰值 293630，来自狩猎营），但后期耗尽 -> 短缺 65535。
- fish / logs / chipped_stone_tools / cloth 也全在最大短缺，但非主因。

此外本格明明拥有 `arable_land=125000`、`pasture=125000`、`fertile_soil`（可再生）、`wild_game`（可再生），
却**未放置任何农场/牧场/采集场**——农业用地完全闲置，进一步印证是**建筑布置缺口**而非资源短缺。

## 四、崩溃的放大器（为什么雪崩）

1. **单一故障点（SPOF）+ 上游工具链先死**：唯一有效食物源 = 一座狩猎营（237, game_meat），
   且它依赖 `chipped_stone_tools` 作中间投入。断链顺序：
   - 石器工具坊（90 knapping_workshop）业主 = prof2（artisan，单人），长期买不到食物 → 资金 d340 从 3.2万 跌到 64；
   - **d405 工具坊 owner 槽位空缺**（filled_owner 1→0）→ chipped_stone_tools 产出→0；
   - 库存 d410=325 → d420=1 → 家庭可用量 hhAvail=0；
   - **d425 狩猎营（237）断料**：`last_input` 143→0，game_meat 产出 62204→426（−99.3%），`last_sold` 16126→110。
     关键：此时狩猎营 `filled_owner` 仍=3甚至升到 23、planned_utilization 拉满、expected_revenue 仍高 —— **想生产但无投入品可买**。
   所以产能归零的真正触发是"工具断供"，不是"业主死亡"；业主死亡是更晚的二次后果。
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
