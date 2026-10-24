# 11. 基建优先路线图（2026-10-23 起取代 10 §3-§8 的排期）

> 目标（用户 10-23）：**先把代码基建做完**，性能优化和测试细节之后再做。
> 本文只回答三件事：哪些冻结、基建按什么顺序做、每一步交付什么、怎么算做完。
> 所有行号在 2026-10-23 11:00 的工作树上核过；动手前 `rg` 复核一次。

---

## 0. 现状快照（证据）

| 项 | 证据 | 结论 |
|---|---|---|
| 生成器能力开关 | `generate_ideology_catalog.py:103` `AVAILABLE_CAPABILITIES` = X1 X2 X3 X7 X11 X15 | 10-21 以来**没有新增任何能力** |
| 可达性 | `audit_card_reachability.py`：可直接做 7 / 缺 1 项 79 / 缺 2 项及以上 93（共 179） | 卡住最多的是 X1（单独卡 54 张） |
| 已发布 | 85 张；暂存 10 张在 X16/metric68/reserve_ratio/X9 上（`generate_ideology_catalog.py:1890-2031`） | 暂存卡全部等 R |
| 版本 | PKID 8、IDP2 ABI 6、Effect POD ABI 3、PKEF 13、`FAMILY_METRIC_COUNT` 68（`economy_runtime.h:524`） | |
| R-3d | `artifacts/r3d/daydbg.log` 11:17：`[wait] calls=0 total_ms=144017`；`probe_day.log`：`ideology_pod_committed_day=MISSING` | wait 信号仍未接通，24/0 仍靠超时 |
| 10-21 以来 C++ 增量 | 约 5.5k 行；粗估 30-35% 是 parity，25% 是 01 的 P1/P2，15% metric/tag，5% 系数平面 v1 | parity 已冻结，平面未用 |

---

## 1. 冻结清单（本期不做，不进任何一轮的范围）

- parity（主线程 vs worker 比对）及其护栏、夹具、hash 适配器。只走 worker。
- Doc 03 的 B1-B6 基准、O 系列优化、idle-zero 计数调优、按国家脏化。
- 系数平面 v1 的修复（generation 冻结、MUL 语义、worker 发布）。**保持默认不生效**，到 M3 再决定是否重做。
- `latched` 的 wire 半边（ABI 3→4）、注释乱码、测试夹具美化、legacy 对照实验。
- 数值与平衡：一律照抄设计表或按 cap=3 反推，登记 09 §8，不问用户。

例外：如果某个冻结项**挡住了一张卡在 worker 上生效**，它就不是冻结项，按 bug 修。

---

## 2. 「基建做完」的定义（DoD）

全部满足才算 01/02 落地完成：

1. Doc 02 §2 的 X1-X16 和四个横向项，每一项要么在 `AVAILABLE_CAPABILITIES` 里，要么在本文 §6 写明「有意不做」和理由。
2. 审计「可直接做」= 179 − 有意不做的卡；暂存卡 = 0。
3. 01 的 P1/P2 里**会影响真实游戏**的项全部关闭（P1-A/B/C/D、P1-E、P2-B/C/D）；P3 可留。
4. 每项能力至少有一条 **worker 路径**测试，断言「装卡 → 下游真的变 → 卸卡 → 恢复」。
5. 新卡只改生成器（02 §19）：写一张用到已有能力的新卡，不碰 C++、不碰 GDScript 目录代码。

每轮汇报只看一个指标：**`cards_published` 从多少变成多少，worker 上验收通过几张**。

---

## 3. 顺序（按解锁卡数排，R 独占 C++）

| 步 | 内容 | 解锁 | 预计 |
|---|---|---|---|
| R-3d 收口 | 只修 3 件影响游戏的：wait 信号、升级/换位旧行是否撤、intent ACK 门收窄 | 0（防回归） | ≤1 轮，时间盒 |
| **R-4** | X16 + metric68 + reserve_ratio（§4） | 8 张暂存卡 + `labour_legislation` 改写 | 1-2 轮 |
| R-5 | X1-b（09 §7.11 六步）+ X1_PLAIN 24 张 worker 验收后打开开关 | 9 + 24，并让 X1 不再单独卡 54 张 | 2-3 轮 |
| R-6 | X5 范围/阈值/上限/条件（02 §4.5） | 8 | 1-2 轮 |
| R-7 | X4 事件叠层 + P1-E 生成器拦截（02 §4.4） | 5 + L2-8 的 13 张 | 2-3 轮 |
| R-8 | X13 气候（灾害事件走 X4，干旱天数/年均温） | 5 | 1-2 轮 |
| R-9 | 剩余：X7 理念侧计数、X2 列、X9、X10、X12、X14、X3、X8、X6 | X1 落地后重跑审计再排 | 3-5 轮 |

R-5 之后**重跑审计**，按「缺 1 项」表重排 R-6 以后的顺序；表里的数字会变。

**2026-10-23 21:40 插队（reviewer）**：`14-worker-managed-lifecycle.md`。worker Effect POD
没有 managed 生命周期：条件跌破不撤行、每天重发交易、ACKED 交易永不压缩（存档每天涨）。
这是生产路径的正确性缺口，排在 12-r7 的 A-D 之后、F 之前；F 的格子卡验收要连带断言
「条件跌破 / 卸下后格子回到基线」。

**2026-10-23 21:55（reviewer）**：X4 规格已写成 `15-x4-brief.md`（层环放 Effect POD 实例、一格一实例、
层数走 magnitude、事件由 Economy 提交尾发布；X4-a = 降雨日 + 建筑完工，X4-b = 新职业/增工需 Economy
schema 56→57）。依赖 14 先落地。

**2026-10-23 22:05（reviewer）**：X13 规格 `16-x13-brief.md`。X13-a = 输入扩宽（temp_365d / weather_type / cover）
+ metric 70-74 + 3 个气候 tag，不依赖 X4；X13-b = 灾害事件走 15 的层环。雨季按月统计列为待定排除。

**2026-10-23 22:15（reviewer）**：X12/X14/X10/X9-a + 理念侧标量规格 `17-x10-x12-x14-x9-brief.md`。
全部只读已冻结数据、不动 schema；X12/X14 可插到 X1-b 之后任意位置。排除项：流域 id（map 域）、X9-b。
至此 Doc 02 每个能力都有规格：X1-b(09 §7) / X5(13) / X4(15) / X13(16) / X9-X14(17) / 14（生命周期）；
尚无规格的只有 X6（槽位顺序、免费抽取）与 X8（上下游，依赖 X1-b 核）。

**2026-10-23 22:25（reviewer）**：X6/X8 规格 `18-x6-x8-brief.md`。**Doc 02 全部能力现在都有可执行规格**；
各规格里的「明确排除」项就是 DoD 里「显式排除」的候选清单，由用户/C 确认。
完整 R 队列：12-r7 A-D → 14 → 12-r7 F/G → X1-b(09 §7) → X12/X14(17) → X5(13) → X4(15) → X13(16) →
X10 + 理念标量(17) → X6(18) → X9-a(17) → X8(18) → 重跑审计，暂存卡归零即基建完成。

---

## 4. R-4 实现规格（可以直接照做）

三项同轮做，共用一次目录重建。存档：Modifier/Effect catalog hash 变 → 旧档 fail-closed；PKEF/PKID/IDP2 **不变**（全是派生量）。

### 4.1 X16：按职业的税负容忍度与满意度偏置

设计依据：`ideology-build-redesign.md` §47.3。

**C++**

1. 解析 stat id：`economy_runtime_configuration.cpp:151-161` 仿资源写法，按 `_profession_ids` 顺序解析
   `economy.profession.<pid>.tax_tolerance_factor` → `_profession_tax_tolerance_stat_ids`，
   `economy.profession.<pid>.satisfaction_bp` → `_profession_satisfaction_stat_ids`。缺失为 -1。
2. 冻结：在 `capture_country_epoch`（`economy_runtime.cpp:4743`）里，
   与 `_epoch_country_resource_use_factor_q16` 同处：`:5072` 附近 `assign(country_count × P, …)`，`:5137` 的国家循环里填：
   - `_epoch_country_profession_tax_tolerance_q16[c*P+p] = modifier_factor_q16(effective_value(COUNTRY, id, handle, 0, 1.0))`，再钳到 [0.5, 3.0]；
   - `_epoch_country_profession_satisfaction_bp[c*P+p] = round(effective_value(COUNTRY, id, handle, 0, 0.0))`，钳到 [-2500, 2500]。
   stat id 为 -1 时填默认值（1.0 / 0），不调 Modifier。
3. 读取：`update_cohort_satisfaction`（`economy_runtime.cpp:6192`）。
   - 用 `cell_country_slot(cell)` 和 `signature.profession_id` 取下标；越界一律用默认值。
   - `:6265` 把 `_satisfaction_tax_tolerance_q16` 换成 `tolerance = mul_div_sat(_satisfaction_tax_tolerance_q16, factor_q16, Q16_ONE)`，至少为 1。
   - `:6290` 算出 `raw_q16` 后：`raw_q16 = clamp(raw_q16 + bias_bp * Q16_ONE / 10000, 0, Q16_ONE-1)`，**然后**才与 `ceiling_q16` 取 min（`:6297-6299`）。正偏置不能突破生存天花板。
   - 这个函数在 worker 上也走同一份代码（调用点 `economy_runtime_market.cpp:2403`），不需要单独接 worker。
4. 可观测：`economy_runtime_queries_market_building.cpp:502` 旁边加 `effective_tax_tolerance_q16`、`ideology_satisfaction_bias_bp`（按该 cohort 的国家和职业）。UI 分项以后再做，字段先有。

**GDScript 目录**

5. `scripts/modifier/modifier_catalog.gd:309` 的 `tax_stat_groups` 之后，按 `economy.profession_ids` 追加两族：
   `tax_tolerance_factor`：domain 1，min 0.5，max 3.0，只允许 MULTIPLY；`satisfaction_bp`：domain 1，min -2500，max 2500，只允许 ADD。
   `allowed_operations` 的位值照该文件已有常量写，不要用 15。
6. `scripts/modifier/stat_key_families.gd:137` 附近加两族，`consumer` 写 `economy_runtime.cpp update_cohort_satisfaction`。
7. `modifier_catalog.gd:634` 的显示名分支加两种：「<职业> 税负容忍度」「<职业> 满意度」。

**生成器**

8. `AVAILABLE_CAPABILITIES` 加 `"X16"`；`labour_legislation` 按 09 §5.1 换成 v1 写法并加 `CARD_REQUIRES = ("X16",)`。

### 4.2 metric 68 `cell.net_tax_burden_q16`

设计依据：§47.9。

1. `economy_runtime.h:518` 之后追加 `FAMILY_METRIC_CELL_NET_TAX_BURDEN_Q16 = 68`；`FAMILY_METRIC_COUNT` 68 → 70（同时给 4.3 留 69）。`MetricMask::CAPACITY` 是 256，不用加宽。
2. 采样：在 `fill_family_behavior_metrics` 里已经遍历本格 cohort 的那个循环（产出 unemployment / metric 51-53 的循环）里顺手累加：
   ```
   parity = (_epoch_id & 1) ? 0x8000 : 0          // 与 touch_accounting_slot (economy_runtime.cpp:590-603) 同一规则
   if ((flags[slot] & 0x8000) != parity) skip     // 本期没记过账的 cohort 按 0 计，避免读到上期残值
   net   += epoch_tax_paid - epoch_subsidy_received
   gross += max(0, epoch_income) + max(0, epoch_in_kind_income)
   结果：gross<=0 → Q16_ONE；net<=0 → 0；否则 clamp(net*Q16_ONE/gross, 0, Q16_ONE)
   ```
   只在 `requested(...)` 时算。口径与满意度税维度（`economy_runtime.cpp:6251-6266`）一致。
3. `scripts/effect/effect_domain_catalog.gd:151` 后同序追加 `"cell.net_tax_burden_q16"`。
4. 写死 68 的地方：`tests/ideology/ideology_mechanism_matrix_test.gd:39` 改 70，`:224` 旁补 `keys[68]`、`keys[69]` 两条断言；
   `tests/ideology/ideology_effect_metric_publish_test.gd:539` 改 70。改完再 `rg -n "\b68\b"` 一遍。
5. 生成器 `AVAILABLE_CAPABILITIES` 加 `"metric68"`。

### 4.3 metric 69 `country.treasury_reserve_ratio_pct`

设计依据：§47.4（国库储备率 = 国库现金 ÷ 上一年全国人口总收入，1 档 = 1%）。生成器已经按这个 key 写了 Ramp（`generate_ideology_catalog.py:1913-1923`、`:5069`、`:5177`），所以必须是 **metric**，不是 stat。

1. 枚举 `FAMILY_METRIC_COUNTRY_TREASURY_RESERVE_RATIO_PCT = 69`。
2. 冻结（`capture_country_epoch` 里，每 epoch 一次，按国家）：
   - `cash = _country_runtime->cash_for_slot(slot)`（`country_runtime.cpp:7232`，worker 权威时自动读 audit snapshot）；
   - **v0 分母**：`annual_income = Σ_本国 cohort income_ema[slot] × 365`。`income_ema` 是日净收入的 EMA，已经在存档里，所以**不新增存档状态**。
     真正的「上一年累计」要一个按年滚动的累加器，会改 Economy 存档；放到 M4，登记 09 §8。
   - `pct = annual_income > 0 ? clamp(cash*100/annual_income, 0, 1000) : 0`，存 `_epoch_country_reserve_pct[country]`。
3. 采样：仿 metric 55（`economy_runtime.cpp:16404-16421`），`metrics[69] = count_q16(_epoch_country_reserve_pct[cell_country_slot(cell)])`。
   单位是「档」的计数，Ramp 的 `per=0.005/0.01` 是每档的比例，与 lint 的约定一致。
4. `effect_domain_catalog.gd` 同序追加 `"country.treasury_reserve_ratio_pct"`；生成器加 `"reserve_ratio"`。

### 4.4 R-4 验收

1. 构建末行 `scons: done building targets.`。
2. 生成器输出：`cards_published` 85 → 93 左右。剩下的暂存只能是 `ancestral_hall`、`gentry_patronage`（缺 X9）。数字不一致就逐张列原因。
3. 新增一个 worker 路径测试 `tests/ideology/ideology_x16_worker_test.gd`：
   - 同税率的两个国家，一国装 `land_value`（只依赖 X16）：地主 cohort 的税维度更高，`effective_tax_tolerance_q16` = 默认 × 1.15；卸下后恢复。
   - 负偏置（`tax_holiday` 的商人 -200 bp）在综合值被天花板压住时仍然生效。
   - metric 68：用 `set_effect_metric_override_for_test` 之外的**真实路径**跑一格：把一格的税设为 0，跑过一个 epoch，metric 68 = 0；空地块 = Q16_ONE。
   - metric 69：给国库加钱，跑过一个 epoch，metric 69 增加，`excise` L3 的建造成本系数随之变化。
4. 回归：`ideology_runtime_test`、`ideology_card_content_test`、`ideology_mechanism_matrix_test`、`ideology_effect_metric_publish_test`。
   如有红项，与 05 §3 的既有基线对照，只修本轮引入的。

### 4.5 新增能力：国家级 ramp 承载（排在 R-5 X1-b 之后）

**要解决什么**：`excise` L3 与 `progressive_tax` L1-L3 各有一条按「国库储备率」分档的
`RampTerm`，目标是国家域 stat（建造成本、死亡率）。ramp 是 Effect 指令序列
（CONST per → READ_METRIC → CONST cap → MIN → MUL_Q16 → EMIT），不能写进 Modifier 定义；
而生成器现在只允许卡程序命名 `ideology.city.*` 定义：

```
card programs must use an ideology.city.* definition
```

两者相加的结果是：**metric 69 已经存在，这两张卡却仍然发布不了**——照旧发布只会得到
11 条 tolerance，第 12 条 ramp 静默消失（实测到过）。R-4 因此给生成器加了一条硬规则：
`LEVEL_TERMS` 里含 `RampTerm` 的卡不算已发布，除非它的 metric 有程序载体。
加之前 `cards_published` 是 95，加之后是 93 —— 93 才是诚实的数字。

**要做的事**：

1. 允许卡程序以 `target_domain = DOMAIN_COUNTRY` + `selector = SEL_OWNER` 命名
   `country.*` 定义（新增 `ideology.country.*` 定义族，或在现有定义上开一个
   `scope = country` 变体），并让 `EffectRuntime` 的 `NATIVE_MODIFIER_IDEOLOGY`
   写入路径接受国家域目标。
2. 放开生成器里那条 `city_keys` 检查：`target_domain == DOMAIN_COUNTRY` 时改查
   允许的国家域定义集合。
3. 把 `excise` / `progressive_tax` 的 ramp 从 `LEVEL_TERMS` 移到 `LEVEL_ROWS` 程序行，
   删掉 §4.5 这条硬规则的例外项，重跑生成器确认 `cards_published` 回到 95。
4. 新增 worker 路径测试：装备 `progressive_tax`，把国库储备率推高，断言死亡率确因
   ramp 下降、卸下后恢复。

**验收**：`cards_published` 93 → 95；`excise` / `progressive_tax` 在 worker 上验收通过；
两卡 L3 的 ramp 条款在产物 tres 里可见（不是 11 条 tolerance）。

**为什么排在 R-5 X1-b 之后**：它解锁 2 张卡 + 一个通用承载，而 X1-b 解锁 9 张卡并让 X1
不再单独卡住 54 张；且国家域程序的写入路径与 X1-b 的 per-source 目标共用同一段
`EffectRuntime` 目标解析，先做 X1-b 不会返工。

---

## 5. R-5 以后

- **R-5 X1-b**：规格已在 09 §7（v2），按 §7.11 六步做。最后一步 12 张 kind 14/15 卡的重标定按 cap=3 反推，不讨论数值。
  同一轮把 X1_PLAIN 的 24 张跑 worker 验收（读 `card_expectations.json`），通过就把 `X1_PLAIN_SWITCH` 加进开关。
- **R-6 X5**：02 §4.5 的覆盖表方案，复用 P1-D 的反向索引。
- **R-7 X4 + P1-E**：02 §4.4。PKID 8→9、IDP2 ABI 6→7，层环进 POD。
- **R-8 X13**：灾害作为 X4 事件源；干旱天数、年均温先查 climate runtime 是否已有累计量。
- **R-9**：X1 落地后重跑审计，按「缺 1 项」重排。

每一步都按同一个模板交付：C++ 读者 → 目录/元数据 → 生成器开关 → 重跑生成器 → 一条 worker 测试 → 报 `cards_published`。

---

## 6. 已知内容侧小问题（C 恢复后处理，不阻塞 R）

- `petition_box` 挂的是 `("X16", "metric68")`，但它真正缺的是 X14（民意条件），没有用到 metric 68（`generate_ideology_catalog.py:1978`）。R-4 之后它会以「没有民意档位」的形式发布；C 恢复后改成 `("X16",)` 并把民意那一半挂 X14。
- `basic_income` L2/L3 cap 应为 0.10，`automation_line` L2/L3 应为 0.133（C-e 范围）。
