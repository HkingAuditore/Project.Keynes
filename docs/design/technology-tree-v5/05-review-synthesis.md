# 科技树 v5 设计方案 · 第五部分：八维度审查结论汇总

> 本部分汇总 8 个独立审查 agent 的结论，并记录**交叉校验中被推翻的判断**。
> 原始报告在 `.dsh\tmp\tech_audit\REVIEW_A…H_*.md`（合计约 4,000 行）。

---

## 1. 八维度评分

| 维度 | 审查员 | 评分 | 一句话理由 |
|---|---|---|---|
| 前置逻辑关系 | A | **5.5 / 10** | DAG 工程扎实（0 环、4.3% 冗余边、代际成本几何曲线），但**火器/弹药整条化学链可被绕过**、主干被 6 代远的远祖节点卡住、40% 前置理由是模板句、46% `terminal_reason` 失真 |
| 触发条件可达性 | B | **5 / 10** | 看得见这一层可达；但真正的门槛 100% 由 5 个部门指标决定，地理气候在资格层缺席；4 个天气信号是死的 |
| 地理气候相关性 | C | **3 / 10** | 235 个地形杠杆用了 3 个；315 个资格门里 3 个含地理；**79.6% 的节点对地形完全无感** |
| 自由构筑与独特性 | D | **3 / 10** | 稀缺只存在于时间轴，不存在于集合上；但 80% 强制完成率使其更彻底——**玩家不能选择"不研究"** |
| 内容覆盖完整性 | E | **5 / 10** | 静态谱系异常干净（0 游离/0 无生产者/0 纯废物），但"广而不深"：71% 的链只有 1–2 环、蒸汽后 4 代 0 新建材、最后两代 79% 是新建筑的克隆 |
| 时代节奏循序渐进度 | F | **4 / 10** | 曲线数学上平滑（每代 ×2.22–2.53），体验上呈 **U 形**：前 3 代过细 → empire 凹坑 ×0.37 → steam 撞墙 ×2.33 → 后 5 代膨胀到 5.5× |
| 出生点产业特色 | G | **4 / 10** | 开局同构（任何出生点都是同样 5 个起手科技 + 同样 4 种保底资源）；reveal 不设门槛；38 个节点被单一行业 route 把门 |
| 军事体系 | H | **4 / 10** | 36 节点散落 11 族、无身份；agrarian 空档；**51.4% 军事修饰符是死代码**；6 个战术条令通道零使用；无海军/空军/远程 class |

**加权总评：4.3 / 10**（本方案作者自己的初评是 5.1，被交叉校验下调）

---

## 2. 交叉校验：被推翻的 8 个判断（本方案的自我勘误）

这一节是本文档最重要的部分之一 —— 它决定了后续实施时哪些"常识"不能再引用。

| # | 原判断 | 推翻依据 | 正确结论 |
|---|---|---|---|
| 1 | **"21 座研究建筑都产 64 科技点/日，从石器到智能不变"** | 解析 `PackedInt64Array(56875)` 时正则把 `Int**64**Array` 里的 64 当成了数值 | 真实区间 **2.0 → 6,708 点/日（×3,354）**。研究产能有阶梯，且与成本增长量级相近。**"后期慢 64 倍"不成立** |
| 2 | **"`reveal_condition` 决定你能不能研究"** | `country_runtime.cpp:7567–7574`：只要**任一硬前置已完成**就直接 discovered，绕过 reveal | reveal 对 394 个有前置的节点**不是门槛**，只是提前预览。真正的门是 `hard_prerequisite_ids` + `research_routes` |
| 3 | **"每代里程碑候选池 2.0–2.8 倍，可跳过一半，健康"** | `era_advancement_catalog.gd:22` `TECH_COMPLETION_RATIO = 0.8`，`mandatory = true` | **每代必须完成 80% 的非里程碑科技**；全树必修 328/416。`candidate_required` 只控制里程碑节点何时可研究。**此前所有基于候选池的健康判断全部无效** |
| 4 | **"28 个 breakthrough 实践信号从未被使用"** | 只扫了 `reveal_condition`，没扫 `research_routes` | 实际 **23 个原子在用**（`seed_saving` route 10 次、`kiln_temperature` reveal 9 次等）。实践通道是**接线率 8%**，不是没能力 |
| 5 | **"92 个 stat 全部有真实 consumer，0 假效果"** | 把"映射进 military digest"当成了"被消费" | **9 个军事 stat 无解算路径**（`attack_factor` 等），18/35 条军事 term 空转。其余 83 个确有 consumer |
| 6 | **"`casualty_factor +0.85` / `supply_transport_factor +2.00` 是数值事故"** | `operation` 枚举 `ADD=0/SUBTRACT=1/MULTIPLY=2/DIVIDE=3` | 这两条是 **MULTIPLY**：×0.85（合理）与 ×2.0（偏强但非 ×3）。全树 480 条 term 里 473 ADD / **7 MULT 且全在军事** |
| 7 | **"6 个零效果科技是纯研究点黑洞"** | `magnetic_navigation` 有 `runtime_capability_tags`；`coastal_transport` 是 `unlock_tech_ids` 水路开关 | 真正黑洞 5 个（`reed_identification`/`copper_ore_roasting`/`irrigation_surveying`/`radio_command`/`cartography`），共 767,200 点；另 2 个是"效果未声明" |
| 8 | **"`app.*` 是横向协同但玩家无感"** | `application_intersections` 本身不是门禁（validator 标为 static / zero-cost），真门禁在 `BuildingProfile.technology_tags` + `required_technology_tags` | 协同是**真的且被强制的**（301/301 一一对应），只是同一件事记了三遍；无感的三因是"不进研究清单 / 不可选 / 199 个用普通命名" |

---

## 3. 全树问题清单（按严重度）

### P0 · 决定游戏是否成立（必须先修）

| # | 问题 | 证据 | 后果 |
|---|---|---|---|
| P0-1 | **80% 强制完成率使"构筑"不存在** | `TECH_COMPLETION_RATIO = 0.8`；737 个可放弃位实际只有 73 个 | 24 条支线不是选项而是路段。文明特色只能来自运营层 |
| P0-2 | **地理在资格层完全缺席** | 743 条 route 里只有 3 个节点含地理原子 | "和地理气候有较大关系"这条要求当前满足度约 0.7% |
| P0-3 | **聚合倍率 ×41–×51** | 全局 +2.90 × 行业 +3.18 × 家族 +2.25 | 经济平衡被科技抹平 |
| P0-4 | **火器/弹药化学链可被绕过** | 7 个火器节点的祖先闭包无 `gunpowder_formulation` | 4 个时代的化学知识真空 |
| P0-5 | **51.4% 军事修饰符是死代码** | `sum_lot_value` 不含国家修饰符 | 19 个军事科技里 11 个的真实价值玩家拿不到 |
| P0-6 | **11 处时序死锁** | 汽车链在电气代启动不了；7 座建筑"解锁了却造不出来" | 玩家造不出已解锁的东西 |
| P0-7 | **`deadland_factor` 撞顶 187%** | 15 个节点合计 −1.25，cap 只允许 −0.667 | 约 9 个科技完全无效 |

### P1 · 决定游戏是否好玩

| # | 问题 | 证据 |
|---|---|---|
| P1-1 | 137 个节点（33%）只给百分比；24 个只给全局 +4~8%（51.9M 点 = 8.65%），其中 **10 个是里程碑候选** | F 审 |
| P1-2 | 7 条支线中期死亡（块茎高地死在第 3 代、热带商品第 4 代、森林/建材第 6 代、水风第 3 代、土地制度第 5 代、石油石化只活 2 代） | 07_branch_pacing |
| P1-3 | 主干断档：`tools_machinery` 在 exploration / information 两代无节点；`food_storage` 在 atomic / information 无节点 | 同上 |
| P1-4 | 启蒙时代是全树最空的一代（内容密度 0.77，48% 纯百分比，48.5% 研究点买不到新内容） | F 审 |
| P1-5 | 蒸汽代授予的研究效率净增量 = 0，正好撞上 ×2.22 成本墙 | F 审 |
| P1-6 | 133 个重复解锁目标（`corn_grain` ×10、`wheat_grain` ×10 等） | 12_duplicates |
| P1-7 | 蒸汽后连续 4 代 0 新建材；459 座建筑只靠 5 种建材建成（`steel` 2 产 → 221 用） | E 审 |
| P1-8 | 114 座 `method_*` 克隆（信息代 69%、智能代 79%），中位产出 ×7.78，最高 ×522 | E 审 |
| P1-9 | 6 个气候档案畸形；`dryland_crop` 独占 20/38 条修正；无 cold/highland/oasis 档案 | C 审 |
| P1-10 | 台风/风暴潮在经济上零损失表达（`STORM`/`MONSOON` 不产生 hazard 位） | C 审，需 `new_runtime` |
| P1-11 | 出生点被强制同质（任何合法出生点都有肥沃土壤+木材+野生动物+金银矿） | D/G 审 |
| P1-12 | 43/143 个里程碑候选零内容（含 `blast_furnace`、`paddy_bunding`、`public_health`） | D/F 审 |
| P1-13 | 10 条支线零独占物资；43 个独占物资里 27 个是军工 | D 审 |
| P1-14 | 兵种解锁在科技树里无法表达（`content_effects.kind` 没有 `unit`） | H 审 |
| P1-15 | `resource_access_modes` 231/231 全 `local` → **不存在"进口原料"路径** | C 审 |
| P1-16 | 21 个节点的 `ANY_OF` 因开局恒真资源退化为 TRUE | B 审 |

### P2 · 数据与表达

- `terminal_reason` 46% 失真（185 条里 85 条落在有硬子节点的节点上）；14 个真死端；33 个"断头科技"
- `branch_successor_ids` 全树仅 8 条（软后继层不存在）
- 三套"时代候选"口径不一致（`is_era_key` 177 / `milestone_candidate_ids` 143 / `anchor_kind` 88）
- `is_starting` 不发放科技（`STARTING_IDS := []`）；`surface_silver_collection` 运行时**从未发放**
- `reveal_category` 错标：78 个标 `practice_diffusion` 但条件是 `development.*`
- 3 个职业 0 引用（`cooperative_member` / `transport_worker` / `unemployed`）
- `researcher` 与 `scientist` 同代同义；无"农业技师"
- 9 个 `industry.*` 标签混在 `technology_tags`
- `cloth` 的 `category_id = rag_paper_fiber`（分类错）
- `discharge_order` 按字母序排 dense id → **裁军先解散青铜矛兵**（注释与实现不符）

---

## 4. 各审查员的最强建议（合成后采纳情况）

| 来源 | 建议 | 是否采纳 |
|---|---|---|
| A | 给火器链加 6 条边接上火药 | ✅ 全部采纳 |
| A | 删 7 条伪依赖边 | ✅ 全部采纳 |
| A | 新增 `stone_quarrying` 修砌体缺环 | ✅ 采纳 |
| A | 链改为 `record_keeping → writing → celestial_calendars` | ✅ 采纳 |
| A | 补 tools 主干 3 节点（`precision_measurement` / `servomechanism` / `robotic_control`） | ✅ 全部采纳 |
| A | 成本重定价 17 项 | ✅ 采纳，扩展为全树三档制 |
| A | `early_trade` 移出 stone 候选 | ✅ 采纳 |
| A | 删 4 个零效果收费站 | ✅ 采纳 3 个（`copper_ore_roasting`/`irrigation_surveying`/`reed_identification`），`cartography` 改为补内容 |
| B | 把 `*.10_90d`（10 人 90 天）从 route 池整体移除 | ⚠️ 部分采纳：改为"每节点至少 1 条非本行业 route" |
| B | 给 71 个空条件节点逐 ID 补条件 | ✅ 采纳（分三批） |
| B | 26 条被浪费信号的接线方案 | ✅ 全部采纳 |
| B | `weather.*` 死信号需代码修复 | ✅ 标 `blocked` |
| C | 启用 235 个 `terrain/landform × sector` key | ✅ 采纳为规则 4（每条支线 ≥2 代） |
| C | 给 49 个语义错配节点各加 1 条地理 route | ✅ 采纳（新增 `route_type=geographic_evidence`） |
| C | 拆 `dryland_crop`，新增 `highland_crop` / `oasis_irrigation` | ✅ 采纳 |
| C | 五条灾害支线各 2–3 段 | ⚠️ 部分采纳（不新增 5 条支线，改为在既有支线内分配灾害效果） |
| C | 台风损失通道 | ❌ 不采纳（`new_runtime`，标为待批准） |
| D | 8 组软互斥（`NOT(TECH_COMPLETED)` 硬互斥） | ⚠️ 改为**运营层互斥**（T1–T5）。研究层硬互斥在 80% 强制下无意义 |
| D | 专精此消彼长（`research.<域>_efficiency` +0.15 / 对位 −0.05） | ❌ 不采纳：`country_core.cpp:172` 把 efficiency ≤ 0 当 1.0，扣到 0 反而免罚 |
| D | 修 43 个零内容候选 | ✅ 采纳（给 ≥1 建筑或 1 条 app） |
| D | 复制 `charcoal` 模板 | ✅ 采纳 |
| E | 修 2 处硬时序死锁 + 7 处建材倒挂 | ✅ 全部采纳（P0） |
| E | 给资本品挂 `maintenance_good_ids`（4/459 → ≥60） | ✅ 采纳 |
| E | 新增 `silk_fiber`（零配方改动） | ✅ 采纳 |
| E | 新增 6 个"有产有销"物资 | ✅ 采纳 5 个，扩展为 13 个 |
| F | 三档定价 + 后 5 代"产能/效率"而非砍成本 | ✅ 全部采纳 |
| F | 6 个零效果节点全部补效果（不删） | ⚠️ 部分采纳：3 个合并删除、1 个补内容、2 个补 runtime 声明 |
| F | `controlled_burning` 从 −0.08 改 +0.10 | ✅ 采纳 |
| G | 起手科技按生态差异化 | ✅ 采纳（配置层，`new_content`） |
| G | 复活 `_preferred_knowledge_for_region()` | ✅ 标记 `blocked` |
| G | 资源 top-up 收敛 + 出生过滤放宽 | ✅ 采纳 |
| H | 建 1 条 `branch.military_land`，不建海军支线 | ⚠️ 改为 `branch.military_doctrine`（12 节点），海军并入产业族 |
| H | 新增 6 兵种 | ✅ 采纳（改用 H 的兵种语义 + 我方 4 个，共 6） |
| H | 12 处死效果改成 `rule.*` | ✅ 采纳 |
| H | 军事数值重标定（attack 1.64→≤1.20 等） | ✅ 采纳，但注意 ADD/MULT 语义 |

---

## 5. 本方案明确"不做"的事

| 不做 | 理由 |
|---|---|
| 研究层硬互斥（`NOT(TECH_COMPLETED)` 作为 route 条件） | 在 80% 强制下无意义：玩家反正必须研究全部。互斥放在运营层 |
| 台风/风暴潮的经济损失通道 | 需要给 `production_climate_capacity` 加通道，属 `new_runtime` |
| 改动 `TECH_COMPLETION_RATIO` | 杠杆最大但属代码改动，列为"待决"，本方案在 0.80 不变的前提下设计 |
| 海军作为独立科技支线 | `MILITARY_STATE_BUILD_SLOTS = 3` 钉死 role 数，无 naval class；硬建会立即违反"≥3 节点 3 代 + 至少 1 后继 + 1 应用边" |
| 兵种级口粮差异 | `supply_idle.ration` 字段被忽略（全国统一），需 runtime 改动 |
| `morale_add` 的量纲调优 | H 审未能对照士气量纲验证，标"需二次验证" |
| 合并 `researcher` → `scientist` | 建议但不在本次范围（涉及 12 座建筑） |

---

## 6. 实施路线（分四批，每批可独立验收）

| 批次 | 内容 | 依赖 | 预估 |
|---|---|---|---|
| **第 1 批 · 止血** | 第四部分 P0 的 23 项数据错误 + 5 个零效果节点修复 + `death_factor` 重标定 + 聚合倍率压缩 | 无 | 2–3 天 |
| **第 2 批 · 拓扑** | 46 个新节点 + 5 个删除/合并 + 火器链 6 条边 + 伪边 7 条删除 + tools 主干补链 + 成本三档制 | 第 1 批 | 1–2 周 |
| **第 3 批 · 通道** | 地理效果铺开（~45 节点）+ route 三类改造（315 节点）+ 启用 ideology/tax/construction/research/profession 通道（~40 节点）+ 军事条令 12 处 | 第 2 批 | 2–3 周 |
| **第 4 批 · 内容** | 13 物资 + 44 建筑 + 4 职业 + 6 兵种 + 2 气候档案 + 维修机制 + 克隆异构化 | 第 2/3 批 | 3–4 周 |

**每批验收标准**：

- 第 1 批：`technology_network_validator` 0 finding；6 个零效果节点归零；终局农业倍率 ≤ ×5；`death_factor` 不再撞顶
- 第 2 批：0 环；每节点硬前置 ≤4；跨 >1 代边 ≤60；无裸叶子；每代成本三档且 breakthrough ≥20%
- 第 3 批：纯百分比节点 ≤60（14%）；地理原子在 route 中出现 ≥120 次；`attack_factor` 有 consumer 或删净
- 第 4 批：物资全四件套；时序死锁 0；每代新增物资 ≥6；维修覆盖 ≥60；`method_*` 克隆 0

---

## 7. 一句话总结

> 这套科技树的**工程骨架是优秀的**（0 环、几何成本曲线、301 个跨线应用交叉点、459 座建筑 0 游离），
> 但它的**玩法表达是失败的**：地理在资格层缺席、身份在强制研究下无法产生、效果全挤在同一条百分比通道上。
> **v5 的核心动作不是加内容，而是换通道**：把 235 个地理杠杆用起来、把 6 个战术条令用起来、把意识形态与税制用起来，
> 让"同样的 80% 研究"在不同的土地上长出不同的文明。