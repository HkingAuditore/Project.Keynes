# 09 内容落地状态（C 轨：C0 / C1 / C2）

> 读者：会话 R 与下一轮会话 C。
> 分工依据：`08-next-phase-plan.md` §3.6。本文件是会话 C 的状态文档，§3.6 第 4 条要求
> 「每次重新生成 catalog 后在顶部写一行时间和新 hash」。

---

## 0. catalog 重新生成记录（§3.6 第 4 条）

每次跑 `tools/ideology/generate_ideology_catalog.py` 就在此追加一行。三个 `.tres` 都是生成物，
hash 是 **sha256 全文摘要**；R 若遇到 `catalog_mismatch` / `ideology_save_catalog_mismatch`
先查这张表的时间戳。

| 时间 | 生成者 | ideology catalog | effects | modifier | 说明 |
|---|---|---|---|---|---|
| 2026-10-22 15:48:06 | 会话 C | `d5bc2de5…`（338563 → 373126 B） | `be24e303…` | `c70deb3c…` | C0 首次生成：9 张卡按 L1/L2/L3 落地；此时 `ideology.city.*` 与 `modifier_catalog.gd` 的 `card_target_stats` 撞键，**Modifier catalog 编不过**（见 §3.1） |
| 2026-10-22 15:56:22 | 会话 C | `d5bc2de5…`（373126 → 346903 B） | `be24e303…` | `1f…`（184631 B，去重后） | 修撞键：`ideology_city_blocks()` 跳过 `modifier_catalog.gd` 已生成的键；`city_definitions` 62 → 24 |
| 2026-10-22 16:29:47 | 会话 C | `d5bc2de50a22705566075f85dfc77aba21035ab546c37fa77f74ce2402214718` | `be24e303e9e4837492861f99261c1e6a413c42fd8cd808ef6a2ab4ff39e31e67` | `dafd94c380a585d1d7824f241cd1e054873b9a6d072f975a29e23c8d031f93ea` | 去掉 `LEVEL_TERMS` 卡的重复 `CARDS` 项列表（同 key 双定义）；洪灾损失加成无法表达（stat clamp），换成本轮可收费的代价 |
| 2026-10-22 20:59:35 | 会话 C | `fb8a46b5efc830a96b4afb311c810ed1997533cfc984ffc9eedb80edeeeb00a6`（346903 → 340566 B） | `be24e303e9e4837492861f99261c1e6a413c42fd8cd808ef6a2ab4ff39e31e67`（161726 B，未变） | `297abf0011ba43570eeb2536d7f344fd328b0a7fbbb8587e01629ed65a19594e`（175503 → 165433 B） | **C-a**：V1 硬失败（禁 `country.tax.*`）、V3 扩到全部卡、§47.7 三张旧卡改写；`land_tax_reform` + `excise` 按 §47.5 重写但**暂存不发布**（缺 X16 / metric68）；发布卡数 87 → 85 |
| 2026-10-22 21:24:11 | 会话 C | `fb8a46b5efc830a96b4afb311c810ed1997533cfc984ffc9eedb80edeeeb00a6`（340566 B，**未变**） | `be24e303e9e4837492861f99261c1e6a413c42fd8cd808ef6a2ab4ff39e31e67`（未变） | `297abf0011ba43570eeb2536d7f344fd328b0a7fbbb8587e01629ed65a19594e`（未变） | **C-a 补丁**：新增能力名 `reserve_ratio`；`excise` 的 L3 不再沿用 L2，改为「国库储备率每档建造成本 -0.5%（上限 -4%）」并随整卡暂存（`requires=("X16", "reserve_ratio")`）。三者 hash 全未变是**预期**：变更全在暂存卡上，暂存卡不写任何产物 |
| 2026-10-22 22:00:15 | 会话 C | `fb8a46b5efc830a96b4afb311c810ed1997533cfc984ffc9eedb80edeeeb00a6`（340566 B，**未变**） | `be24e303e9e4837492861f99261c1e6a413c42fd8cd808ef6a2ab4ff39e31e67`（未变） | `297abf0011ba43570eeb2536d7f344fd328b0a7fbbb8587e01629ed65a19594e`（未变） | **C-b**：写入 §47.5 的 8 张 X16 卡（`progressive_tax` / `tax_farming` / `land_value` / `petition_box` / `ancestral_hall` / `gentry_patronage` / `tax_holiday` / `light_levy`），全部暂存；卡表 87 → 95，发布仍 85。hash 未变是**预期**：8 张全在暂存区 |
| 2026-10-23 00:53:04 | 会话 C | `57e9760f447b551d5dc66d940f1990b4988e47f7ae73a962ccbddf25d8c1ffc0`（340566 → 369919 B） | `abca2753942678a05b3c94d25f9f9dd2b94e982d12685c959436cb8cc56a3eef`（161726 → 206645 B） | `9f2c5524b6c142eee4df190c1aca23ed2fef3bd61c137c72fb9f3093676e3204`（165433 → 168387 B） | **C-c**：§7.6 DSL（kind 16 + 位打包 + 9 条 lint + T11 往返断言）落地；33 张卡的 X1 形态全部写就（23 张改写：旧版继续发布、v1 目标暂存；10 张新写）。卡表 95 → 105，发布 85 → 92（7 张新卡只依赖现有能力，直接上线） |
| 2026-10-23 10:31:00 | 会话 C | `fb8a46b5efc830a96b4afb311c810ed1997533cfc984ffc9eedb80edeeeb00a6`（369919 → 340566 B） | `328d030c136c298a8469655ea360a5ae72135136f9759f4641222afd1e65900b`（206645 → 161726 B） | `297abf0011ba4350eeb2536d7f344fd328b0a7fbbb8587e01629ed65a19594e`（168387 → 165433 B） | **C-d**：Ramp 单位修正（`cap` 用 metric 自己的单位、`per` 是每单位增益的小数）+ 3 条硬失败 lint；新增「下一级不能比上一级弱」lint（修 `basic_income_l3` / `automation_line_l3` / `maritime_insurance_l3`）；描述与 stat 对齐（8 张卡）+ 词表 lint；X1b 开关拆成 `X1b`(9) / `X1_PLAIN_SWITCH`(24)；kind-16 漏出防护；预埋 `card_expectations.json`。卡表 105，发布 92 → **85**
| 2026-10-23 11:10:00 | 会话 C | `fb8a46b5efc830a96b4afb311c810ed1997533cfc984ffc9eedb80edeeeb00a6`（340566 B，未变）| `9becd567f61bb44ffddca808a2f2964fe8f30ca067fd5fa7d65e63cfd8baa9e4`（161762 B）| `297abf0011ba4350eeb2536d7f344fd328b0a7fbbb8587e01629ed65a19594e`（165433 B，未变）| **C-e**：ramp 上限换算修正（`basic_income` / `automation_line` L2-L3，另抓出 `salt_monopoly` / `chartered_route` / `semiconductor` 6 处已发布卡的同类错误）+ 新 lint `ramp_ceiling_error`；主线程冒烟接上 `card_expectations.json` 表驱动（1698 checks / 0 failures）。**ideology 与 modifier 未变，effects 变了**：ramp 数值改动写在 program 里（effects 目录），不碰 Modifier 目录；ideology 目录只记卡号与阈值，所以也不变

**对旧存档的影响**：`default_ideology_catalog.tres` 的卡表变了（新增 2 张、9 张数值重写），
`NativeIdeologyRuntime::compute_catalog_hash()` 会把 `stable_id / rarity_weight /
stance / level threshold` 全部混进去，所以 hash 必然变化 → **旧 PKID 以
`ideology_save_catalog_mismatch` fail-closed**（`ideology_runtime.cpp:4651`）。
POD 侧同理（`world_ext_ideology.cpp` 的 `worker_catalog_hash`）。这是设计预期，不是缺陷。

---

## 1. 本轮范围与结论

C0 = 只改生成器，不编译 C++。矩阵里「可直接做」的 9 张卡按设计文档重写数值。

| 卡 | 设计来源 | 现状 | 备注 |
|---|---|---|---|
| 梯田 `terrace_farming` | §5 Ⅰ 田垄 | **已按新设计实现** | L1/L2/L3 = +10/+15/+15，丘陵+山地；L3 子句用 `cell.terrain.hill` 近似（真「相邻 ≥2」需 X2） |
| 治水营田 `water_works` | §5 Ⅰ 田垄 | **已按新设计实现** | 农业 +8/+12/+12，洪灾 -7/-10/-10，建造成本 +3%；L3 外溢走 `SEL_TAG_SOURCE_R1` |
| 穴居聚落 `pit_dwelling` | §5 Ⅱ 仓廪 | **已按新设计实现** | 冷害 -6/-9，建造成本 -5/-7，丘陵农业 -2%；L3 聚落出生率 +5% 为 cell 程序 |
| 水电 `hydroelectric` | §5 Ⅲ 矿冶 | **已按新设计实现** | 河谷(terrain `floodplain`)+裂谷+峡谷 能源 +12/+18/+18；代价改 `INPUT 1.03`（原「洪灾 +2%」无法收费） |
| 采集游群 `forager_band` | §5 Ⅸ 生灵 | **已按新设计实现** | 森林+雨林农业 +8/+12/+12，野味开采 +5% |
| 逐水而居 `riverside_camp` | §5 Ⅰ 田垄 | **已按新设计实现** | 三角洲+泛滥平原农业 +6/+9/+9；代价改 `INPUT 1.02`；L3 外溢 `cell.landform.delta` |
| 寒暑历法 `seasonal_calendar` | §5 Ⅸ 生灵 | **已按新设计实现** | 冷害 -6/-9、热害 -5/-7.5、旱地旱灾 -6/-9、理念点 -3%；L3 降雨日农业支柱 +5% 为 cell 程序（`cell.rain` & `cell.sector.agriculture` 交集标签） |
| 摊丁入亩 `land_tax_reform` | §5 Ⅹ 度支 | **新建（原未实现）** | 自耕农/佃农/农工所得税率 ×0.90/0.85、地主 ×1.10/1.15；**「地主强烈反对」无法表达**（`landlord` 是职业不是阶层，见 §3.2），代价落到 `R_SOC 0.97` |
| 消费税制 `excise` | §5 Ⅹ 度支 | **新建（原未实现）** | 珠宝/精致服装/饮料消费税率 **+300 / +400 bp**（`operation = Add`）；代价 = 同三货 `GC 0.98` |

生成器侧改动（`generate_ideology_catalog.py`）：

- 新增 `LEVEL_TERMS`（每级国家级数值，解决「L2 永远是 L1×1.6」）、`ADD_TERMS`（加算模板，
  解决「税率 +3 个百分点」无法用乘法表达）、`OP_ADD_DOWNSCALE/OP_ADD_TRANSFER` 标注、
  `C0_CARDS` 白名单、`_clamped_noop_reason()` 死项 lint、`_all_terms()`。
- 修 `PROFILE` 名字遮蔽：`PROFILE` 既是 stat-key 构造函数又是 profile 列字典，后者改名
  `PROFILE_COLUMNS`（否则在字典之后写卡会拿到 dict 而不是 stat key）。
- 修 `ideology.city.*` 与 `modifier_catalog.gd` 的撞键（见 §3.1）。

---

## 2. 测试

> **验收以 worker 路径为准**（2026-10-22 方向调整：游戏只走 worker）。

新增两个文件：

| 文件 | 作用 | 验收地位 |
|---|---|---|
| `tests/ideology/ideology_card_content_test.gd` | 主线程合成 12 格夹具，9 张卡 × 3 级 × 多统计口径 | **快速单测，不作验收** |
| `tests/ideology/ideology_card_content_worker_test.gd` | 真 `WorldRuntimeHost` + 真 worker 线程 + `EFFECT` 归 worker，每进程验一张卡 | **C0 验收** |

worker 版基于 `runtime_ideology_parity_test.gd::_run_production_shadow_parity` 的生产夹具。
**夹具已于 2026-10-22 晚改成与 `player_game.gd:89-117` 完全一致**：`climate_authority=true`、
`economy_auto_pod_active=true`、`authority_domain_mask=0xFFF`、`set_climate_authority_override("force_on")`，
并断言 `authoritative_domain_mask` 的 IDEOLOGY 位（`0x10`，`1 << (5-1)`）为 1。
不再使用 `set_effect_forwarder_authority_for_test` 这个测试 seam。

每卡一条端到端断言：**装备后目标 stat 等于设计值；卸下后恢复**。

> ✅ **2026-10-23：卸下不恢复（§3.7）已由会话 R 修好。**
> 主线程冒烟测试从 `452 checks / 2 failures` 变成 **`452 checks / 0 failures`**，
> 两条 failure 正是 `unequip retires the national modifier row` 与
> `unequip restores the terrain factor to its base`。
> 2026-10-22 19:26 之前（旧 DLL、SHADOW 夹具）的 worker 数字仍作废，但那批结论已经不影响判断。
>
> **worker 测试文件与 `tmp/run_worker_cards.ps1` 现在归会话 R**（C-d 起 C 侧不再修改）。

主线程版（`ideology_card_content_test`，快速冒烟）：

| 轮次 | DLL | 结果 |
|---|---|---|
| C-c | `2026-10-23 00:52:36` | `452 checks, 2 failures`（均为卸下） |
| C-d | `2026-10-23 02:57:19` | **`452 checks, 0 failures`** |

### 2.1 验收表（C-d 预埋，C-e 接进主线程冒烟）

`tests/ideology/generated/card_expectations.json` 由生成器写出，**只生成数据**：

- 每张已发布的卡、每一级，列出 stat key、作用范围（`country`，或 `cell` + tag + selector
  + radius/cap）、期望值；
- `constant` = 可精确断言；`dynamic` = ramp 或带条件项，**只断言方向与上限**；
- 输出稳定：`json.dumps(sort_keys=True, indent=1)` + 浮点 6 位，重跑字节相同。

规模：**85 张卡 × 3 级 = 255 条**，其中 country/constant **528** 行、
country/dynamic 0 行、cell/constant 86 行、cell/dynamic 27 行。

> **⚠️ 一个差点被当成 78 条「卡写错了」的坑（C-e 查清）。**
> 运行时对「用 `CARDS` 单一 term 表」的卡（84 张已发布卡）**按等级缩放**
> `LEVEL_MAGNITUDES = 1.0 / 1.6 / 2.2`（Q16 `65536 / 104858 / 144179`）。
> 实测验证：`fire_keeping` 冷害 `0.92` 在 L2 读回 `1-(1-0.92)×1.6 = 0.872`，逐位吻合。
> JSON 第一版把三个等级都写成 L1 的值，于是 84 张卡全红。
> 现在 JSON 按 `1+(v-1)×mag`（乘法）或 `v×mag`（加法）写出每级的期望值，
> 并带一个 `level_magnitude` 字段便于核对。

#### 主线程表驱动模式（`_test_expectations_table`）

读 JSON，对 85 张已发布卡的每一级断言 `scope=country` + `kind=constant` 的行。
**这是冒烟测试，不是验收**；正式验收仍是 worker 测试（归 R）。

地块级（`scope=cell`）能测的一起测，测不了的**逐条列出原因**，见 §2.4。
环境变量 `C0_EXPECT_CARDS=n` 可只跑前 n 张卡，便于调试。

### 2.2 C-e 表驱动冒烟实测

DLL `2026-10-23 02:57:19`（测试前后未变），耗时 185 s。

```
ideology card content: 1698 checks, 0 failures
SCRIPT ERROR: 0
expectations: cards checked = 55 of 85 of 85, country/constant rows = 528
expectations: cell rows measurable = 19, skipped = 94
```

**为什么这么慢、以及为什么慢是必要的**：**一个国家同时只能装备 1 张卡**。
实测把 10 张卡塞进同一个世界，`slots_used` 仍然是 1 —— 所以一张卡必须一个世界。
85 张卡 ≈ 85 个世界 ≈ 7 分钟。中间试过「每级一个世界」（255 个世界，跑 25 分钟没跑完被杀）
和「多卡共用一个世界」（`slots_used=1`，剩余 9 张读到的都是基准值 → 假失败），两版都已废弃。

### 2.2b X1_PLAIN_SWITCH 打开时（临时，已还原）

把 `"X1_PLAIN_SWITCH"` 临时加进 `AVAILABLE_CAPABILITIES`，重新生成、跑同一套冒烟测试，
再还原并逐字节比对：

```
[off/baseline] rc=0 ['cards_published=85 of 105']
[on]           rc=0 ['cards_published=92 of 105']
  smoke with switch ON:
    ideology card content: 1349 checks, 0 failures
    expectations: cards checked = 39 of 92, country/constant rows = 387
    expectations: cell rows measurable = 54, skipped = 147
[off/restore]  rc=0 ['cards_published=85 of 105']
  byte-identical after restore: True
```

- 发布 85 → **92**（开 24 张改写后，17 张改写的旧版被新版替换、7 张新卡入池；
  68 张卡总量不变的那部分是纯新增）
- **0 failures**：新上线的 24 张卡里，39 张有国家级常量的卡全部断言通过
- 地块级可测行从 19 涨到 **54**（新上线的卡里有 terrain/metropolis 形态的程序）
- 还原后四个产物 sha256 与开关前**完全一致**

### 2.3 只能覆盖一部分行的原因（不是测试偷懒）

| 类别 | 行数 | 处置 |
|---|---|---|
| `country` + `constant` | **528** | ✅ 全部逐级断言 |
| `cell` + `constant`（夹具能满足） | **19** | ✅ 一起断言 |
| `cell` + `constant`（夹具满足不了） | **94** | ❌ 逐条列出原因，见下表 |
| `country` + `dynamic` | 0 | — |
| `cell` + `dynamic` | 27 | ❌ ramp / 带条件，只由生成器 lint 保证方向与上限 |

地块级测不了的，按原因分组（数字来自实测日志）：

| 原因 | 说明 |
|---|---|
| `fixture has no cell carrying cell.produces.<good>` | 夹具是固定 12 格，不造任何物资产出格 |
| `fixture has no cell carrying cell.sector.<sector>` | 同上，不造部门支柱格 |
| `no fixture rule for tag cell.chained / cell.diversified / cell.shortage / cell.frontier / cell.abundant / cell.depleted / cell.rain / cell.specialized_high` | 这些 tag 由经济运行态决定，静态夹具造不出来 |

**这些是「测试夹具不够」，不是「卡写错」。** 补齐它们要么让夹具跑出真实经济状态
（成本远高于冒烟测试的定位），要么等 worker 测试用真实世界覆盖 —— 后者才是验收路径。

### 2.4 C-d 验收原文（保留）

```
[run 1] rc=0
[run 2] rc=0
  two-run identical: True
[switch ON "X1b",] rc=0
[switch OFF "X1b",] rc=0
  restored identical: True  (['cards_published=87 of 105'])
[switch ON "X1_PLAIN_SWITCH",] rc=0
[switch OFF "X1_PLAIN_SWITCH",] rc=0
  restored identical: True  (['cards_published=92 of 105'])
[final] rc=0
  cards_published=85 of 105
```

两次翻转开关都**恢复后字节一致**（四个产物 sha256 全等）。

---

## 3. 实测发现（都不是「卡写错了」，而是引擎侧约束）

### 3.1 `ideology.city.*` 与 `modifier_catalog.gd` 撞 definition key（会整份目录编不过）

`modifier_catalog.gd` 的 `card_target_stats` 循环自己生成
`economy.city.good.*.output_factor`、`economy.city.building.*_output_factor`、
`economy.city.need.*.consumption_factor`、`economy.city.birth_factor`（含 `.cut`）；
生成器的 `ideology_city_blocks()` 又把同一批 key 再写一遍。
`compile_native_catalog()` 见重复 key 直接返回 `modifier_definition_invalid_or_duplicate`，
**整个 Modifier catalog 编不过**，所有理念卡一起死。

- 现象：`MOD_OK=false REASON=modifier_definition_invalid_or_duplicate`；
  `ideology_content_test` 的部分断言连带红。
- 修法：`_city_generated_keys()` 镜像那张循环，`ideology_city_blocks()` 跳过已生成的键；
  `city_definitions` 62 → 24；`validate_city_family()` 加重复 key 断言。
- 这是**两个未提交改动之间的潜在冲突**，不是我引入的：只要跑一次生成器就会触发。

### 3.2 「地主阶层强烈反对」写成 stance —— **已有方案：§47 的 X16**

`IdeologyClassStance.class_id` 必须是 `economy_catalog.profession_class_ids` 里的四个之一
（`general` / `farmer` / `technology` / `worker`）。`landlord` 是**职业**
（`profession_class_id = general`），不是阶层，所以「地主阶层强烈反对」写不成 stance。

**已有方案**（设计文档 §47.3）：不再依赖阶层，改成按**职业**生效的两族 stat ——
`economy.profession.<pid>.tax_tolerance_factor`（MULTIPLY）与
`economy.profession.<pid>.satisfaction_bp`（ADD）。「地主反对」就写成
`PROF_SATISFACTION("landlord") -800`（即满意度 -8），既不依赖阶层划分，也是可读的实数代价（V4）。

- 生成器侧**已落地**：`PROF_TOLERANCE()` / `PROF_SATISFACTION()` / `PROFESSION_GROUPS`，
  `land_tax_reform` 已按这个写法重写，并标 `requires=("X16", "metric68")` 暂存不发布。
- **C++ 部分归 R**：两族 stat、`country × profession` 冻结表、`update_cohort_satisfaction`
  里的读取与偏置（§47.3 的实现要点 1–4）。

### 3.3 灾害损失类 stat 被 clamp 在 1.0，「洪灾损失 +2%/+4%」无法收费

`modifier_catalog.gd` 的 `TECHNOLOGY_STATS` 声明
`country.climate.{drought,flood,cold,heat}_loss_factor` 都是 `[0.20, 1.0]`，
`ModifierRuntime::effective_value` 末尾 `std::clamp(value, min, max)`。
于是任何 **> 1.0** 的灾害损失项都恒等于 1.0 —— 卡面印着代价，运行时一分钱不收。

- `riverside_camp`（+4%）、`hydroelectric`（+2%）已换成本轮真能收费的代价
  （`country.production.input_factor`），卡注释写明原因。
- **C-a 已修**：`land_reclamation` 的 `FLOOD 1.03` → `B_COST 1.02`；
  `agricultural_chemistry` 的 `FLOOD 1.02` 删除（§47.7）。
- 生成器的 `_clamped_noop_reason` 现在**对所有卡**硬失败（V3），不再只对 `C0_CARDS`，
  所以这类空代价不会再进目录。

### 3.4 「每级不同数值」在旧 emitter 里根本不存在

旧 emitter 对每张卡只写一行 definition，三级用 `LEVEL_MAGNITUDES = 1.0 / 1.6 / 2.2`
缩放。所以设计文档的「L2：+15%」实际是 +10%（卡面 L1）经 1.6 倍变成 +16%，
既不是 10 也不是 15。`LEVEL_TERMS` 就是为这件事加的：每级一个 definition，数值照抄设计表。

> 顺带：`LEVEL_TERMS` 与 `CARDS` 的项列表**不能同时非空**。两者都在，就会生成两个
> definition（同统计口径一个 Add、一个 Multiply），运行时按 key 各取一个，行为不可预测。
> `validate_cards()` 现在会硬失败报 `authors LEVEL_TERMS but CARDS still has terms`。

### 3.5 X2/X11 缺口 —— **已有方案：§47 的 metric 68，C++ 归 R**

| 设计子句 | 原缺口 | 已有方案 |
|---|---|---|
| 梯田 L3「相邻 ≥2 个农业支柱丘陵/山地 再 +6%」 | X2（邻格计数当数值） | 仍缺；当前按 `cell.terrain.hill` 全量近似，已写进 summary |
| 逐水而居 / 治水营田 L3 外溢 | 源格 → 周围 | 已用 `SEL_TAG_SOURCE_R1` 表达（并集语义，非叠加） |
| 摊丁入亩 L3「轻税地块出生率 +8%」 | X11 只有全国平均税率 | **metric 68 `cell.net_tax_burden_q16`**（§47.9）：按地块汇总实测净税负，轻税 = 实测 ≤ 8%，**C++ 归 R** |
| 消费税制 L3「国库比每 10% 建造成本 -0.5%」 | 没有国库比 metric | §47.4 的**国库储备率**（国库现金 ÷ 上一年全国人口总收入）；**归 R** |

生成器侧写法已就位：`land_tax_reform` 的 L3 是
`conds=(cond_metric_lte("cell.net_tax_burden_q16", int(0.08 * Q16)),)` + 农业支柱标签，
由 `metric_available()` 守卫——metric 68 不存在时这一级留空，卡本身也还是暂存状态
（`requires=("X16", "metric68")`），所以不会发布半张卡。

---

## 3.7 卸下缺口（给会话 R）— 正式路径复核

> 复核 2026-10-22 晚：夹具已改成与 `player_game.gd:89-117` 完全一致
> （`climate_authority=true`、`auto_pod_active=true`、`mask=0xFFF`、`force_on`，
> 去掉 `set_effect_forwarder_authority_for_test`）。下面第一条在正式路径上仍复现。

### 现象（实测，正式路径，`C0_ONLY_CARD=terrace_farming`）

```
[FAIL] terrace_farming releases its ideology slot on unequip (production path) (slots_used=1)
[FAIL] terrace_farming retires its national modifier row (production path) (rows=["ideology.terrace_farming.l1"])
[FAIL] terrace_farming restores country.output.terrain.hill.agriculture_factor to the base (after=1.10000)
```

`[runtime-day-wait] stall=0x1`（第二次装备卡死）在正式路径上**没有复现**：重新装备后
worker 继续提交日，`worker keeps committing days after a second equip` 通过。

**注意**：worker 夹具下槽位**不**释放（`slots_used=1`）；主线程夹具下槽位**会**释放
（`slots_used=0`）。两者都留下国家行。

### 根因（已定位到函数，但不在本会话文件范围）

主线程夹具逐步量出的链条：

| 观测 | 值 | 含义 |
|---|---|---|
| `ideology_slots_used` | 0 | 槽位确实释放 → transition 跑了 |
| `transition_transaction_offsets` | `[0, 0]` | 卸下**没有入队任何事务** |
| effect `commands_emitted` | 2（卸前后不变） | 从未发出 REMOVE 命令 |
| modifier `remove_events_by_domain` | `[0,0,0,0]` | Modifier 侧没收到任何 REMOVE |
| 存活行 `source_type` / `source_id` | `1229210959` / `356482285572` | `0x4944454F`("IDEO") / `83<<32｜4` |

所以**不是** `modifier_runtime.cpp:1161` 的 source 身份不匹配（REMOVE 根本没到那里）。
断点在 `ideology_runtime.cpp` 的 `start_transition` → `emit_level_effects(remove=true)` →
`emit_templates(remove=true)`：返回成功但产出的命令数为 0。

### 本轮已修（`gdext/src/ideology_runtime.cpp`，effect activation 范围内）

`emit_templates` 的 `effect_id` 哈希把 `remove` 混了进去：

```cpp
hash = mixv(hash, begin + offset); hash = mixv(hash, salt); hash = mixv(hash, remove);  // 修前
hash = mixv(hash, begin + offset); hash = mixv(hash, salt);                            // 修后
```

`enqueue_external_effect_batch_pod` 用
`(source_type, transition_source_id, first.effect_id, first.fire_sequence)` 派生 instance id，
而该 instance id 就是 Modifier 行的 `source_id`
（`effect_runtime.cpp` 的 `NATIVE_MODIFIER_IDEOLOGY`：`source_id = source_instance->id`）。
把 `remove` 混进哈希保证 APPLY 与 REMOVE 的 effect_id 必然不同 → instance id 不同 →
`remove_unique_command` 在 `unique_instances` 里查不到 → 返回 `already_removed` 并留下行。
修完后身份一致；但这只是**必要**条件，REMOVE 命令仍未生成（`emitted=2`）。

### 建议（会话 R）

1. 在 `start_transition` 打印 `transition.previous_location` / `previous_level` 与
   `emit_level_effects` 的实参，确认 `remove_previous_persistent` 分支真的进了
   `emit_templates` 且 `row.persistent_count > 0`。
2. 重点看 `emit_templates` 开头的早退：`count <= 0`、`_effect_runtime == nullptr`、
   以及 `salt == 0 && family_effect_metadata_pod(program)` 那条 `continue` —— 后者用
   `"ideology.effect." + definition_key` 探测；本项目的卡行 definition_key 已是
   `ideology.<card>.l<n>`，探测串为 `ideology.effect.ideology.<card>.l<n>`，理论上不匹配，
   但一旦误匹配就会静默 `continue`，与观测完全一致。
3. worker 权威下 `run_ideology_daily` 被 suppress，卸下的 reconcile 必须由 worker 侧推进。

### 本轮的规避

`ideology_card_content_worker_test.gd` **每进程只验一张卡**（`C0_ONLY_CARD=<key>`），
`tmp/run_worker_cards.ps1` 逐张调用。每张卡基线都是干净的 1.0/1.0，不依赖卸下。
缺口修好后 worker 测试里那三条断言会自然变绿。

---
## 3.8 `ideology_effect_metric_publish_test` 的键名收尾（本轮已修）

`ideology_effect_metric_publish_test.gd:497` 原先写死
`"ideology.city.birth_factor.cut"`，而工作树里那份**未提交**的生成器迁移
（`generate_ideology_catalog.py:241` 的 `city_stat_key()`）已把该族定义为
`economy.city.*`（理由：`ideology.city.*` 是只写族，gdext 从不读它）。

- 定义没有丢：`economy.city.birth_factor` / `.cut` 由 `modifier_catalog.gd` 的
  `card_target_stats` 循环生成，`ideology_city_blocks()` 跳过它们（否则撞键、整份
  Modifier catalog 编不过，见 §3.1）。
- **本轮已改**该断言的 key 为 `economy.city.birth_factor.cut`，测试转绿：
  `ideology effect metric publish: 283 checks, 0 failures`。

---

## 4. 能力开关（C-a 新增，`requires=`）

生成器里的 `AVAILABLE_CAPABILITIES` 是**唯一**的「今天能做什么」事实来源，
`audit_card_reachability.py` 通过 AST 读同一个常量，所以卡能不能发、矩阵怎么算，
两处永远一致。

```python
AVAILABLE_CAPABILITIES = frozenset({"X1", "X2", "X3", "X7", "X11", "X15"})
KNOWN_CAPABILITIES = AVAILABLE_CAPABILITIES | frozenset({
    "X1b", "X16", "metric68", "reserve_ratio",
    "X4", "X5", "X6", "X8", "X9", "X10", "X12", "X13", "X14"})
CARD_REQUIRES["land_tax_reform"] = ("X16", "metric68")
CARD_REQUIRES["excise"] = ("X16", "reserve_ratio")
```

`reserve_ratio` 是**内容侧新增的名字**，不是 Doc 02 的 codename：§47.4 把 X11 的「国库比」
重定义为「国库储备率 = 国库现金 ÷ 上一年全国人口总收入（1 档 = 1%）」，并且有多张卡按档
线性缩放，所以要单独一个开关名。审计脚本的 `CONTENT_ONLY_CAPABILITIES` 表里登记了
`X1b / X16 / metric68 / reserve_ratio` 四个内容侧名字，未实现时在 stderr 逐条报出。

规则：

1. **缺能力的卡照常全量校验**（数值、stat 声明、程序 key、重复项、V1/V3 都跑），
   只是**不写进 catalog**——否则卡池里会多一张静默无效的卡，正是 §47 在治的那个病。
2. `requires=` 写了 `KNOWN_CAPABILITIES` 以外的名字 → 硬失败（拼错不能静默通过）。
3. 暂存卡的 stat 允许尚未被 Modifier catalog 声明（X16 的两族还不存在），
   但 V1、死键、方向钳制三条仍然生效。
4. 生成器末尾打印暂存清单与各自缺的能力。
5. 三个 emitter（catalog / effects / modifier）都从 `cards_to_emit()` 取卡，
   所以暂存的卡不会留下孤儿 definition。
6. `RampTerm`（按档线性缩放的行，如 `excise` L3）**不能**由 Modifier definition 表达，
   `add()` 会跳过它；`validate_cards` 禁止它出现在**已发布**卡上——否则那一级会静默消失。

**当前暂存 10 张**（见生成器输出，卡表 95 / 发布 85）：

| 卡 | 缺能力 |
|---|---|
| `land_tax_reform` | `X16, metric68` |
| `excise` | `X16, reserve_ratio` |
| `progressive_tax` | `X16, reserve_ratio` |
| `tax_farming` | `X16, metric68` |
| `petition_box` | `X16, metric68` |
| `light_levy` | `X16, metric68` |
| `land_value` | `X16` |
| `tax_holiday` | `X16` |
| `ancestral_hall` | `X16, X9` |
| `gentry_patronage` | `X16, X9` |

C++ 部分都归 R；R 合并后把能力名加进 `AVAILABLE_CAPABILITIES` 即可发布。
`ancestral_hall` / `gentry_patronage` 的「名门地块」收益属 X9，本轮只写了 X16 能表达的
代价部分，收益那一半等 X9 —— **没有写假 tag 顶替**。

---

## 5. X16 上线后的两张卡改写目标（待办）

### 5.1 `labour_legislation`（劳动立法）—— 现在是临时写法

| | 内容 | 状态 |
|---|---|---|
| **v0（已发布，临时）** | `CONSUME 0.98` + `INPUT 1.02` | 上线中，**不是设计** |
| **v1（目标，等 X16）** | L1/L2 不变；**L3 = 产业工人、矿工满意度 +4** | 未做 |

v0 为什么只能是临时的：原写法 `TAX("industrial_worker") 0.95` 违反 V1（§47.2）——
税率是玩家自己拨的，改它等于白送一次政策点击。临时换成 `CONSUME 0.98` 是为了让这张卡
在线上**不是零价值**，代价方向也对（家计负担下降），但它没有体现「限定工时、承认工会」
真正该给的**劳动者满意度**，也就没有 §47.5 里那句「L3 产业工人、矿工满意度 +4」。

v1 的两行改动：

```python
# 1) 把 CARDS 里的 term 列表换成空 []，改由 LEVEL_TERMS 提供三级数值：
LEVEL_TERMS["labour_legislation"] = [
    [(CONSUME, 0.98), (INPUT, 1.02)],
    [(CONSUME, 0.98), (INPUT, 1.02)],
    [(CONSUME, 0.98), (INPUT, 1.02),
     (PROF_SATISFACTION("industrial_worker"), 400.0),
     (PROF_SATISFACTION("miner"), 400.0)],
]
# 2) CARD_REQUIRES["labour_legislation"] = ("X16",)
```

`PROF_SATISFACTION` 的 400 bp = 满意度 +4（满分 100 点，§47.3）。加 `requires` 之前
**不要**动：X16 不在 `AVAILABLE_CAPABILITIES` 时，卡会带着没人读的 stat 发布出去。

---

## 6. C-c 落地状态（33 张已写完，等 X1-b 的 C++）

### 6.1 生成器侧已完成

| 项 | 状态 |
|---|---|
| §7.6 DSL：`SEL_TAG_SOURCE_COUNT = 16` + `radius` / `cap` / `per_source` | ✅ |
| 位打包 `pack_source_count` / `unpack_source_count`（`param[0]` 5+3+4 位） | ✅ |
| 9 条非法组合 lint（`_validate_source_count_program`） | ✅ 每条一个反例，`self_test_source_count_lint()` 每次生成都跑 |
| T11 打包往返（4×15×4 组合 + 发射行文本 + 14/15 不受影响） | ✅ 同上 |
| `requires=("X1b",)` 自动派生（不用作者手写） | ✅ 在 `validate_requires` 里从程序推导 |
| 33 张卡的 X1 形态 | ✅ 23 改写 + 10 新写 |

**X1-b 开关翻转的端到端验证**（`tmp/sim_x1b.py`，把 `X1b` 临时加进
`AVAILABLE_CAPABILITIES` 跑一遍再还原）：
- 生成器 **rc=0**，`kind 16 programs emitted: 27`
- 打包解码抽查：`packed=800 → radius 1 / cap 3`，`packed=832 → radius 2 / cap 3`
- 发布卡数 92 → **95**，`idea.enclosure` / `idea.suburbanization` / `idea.communal_feast` 全部出现
- 还原后三个 `.tres` 与原状态 **byte-identical**（hash 比对通过）

这一步是必须做的：不翻开关的话 kind 16 的发射路径是死代码，永远测不到。

### 6.2 23 张改写的处理方式（你要求的「不能消失」）

**旧版继续发布，X1 形态作为 v1 目标暂存。** 具体由 `merge_x1_targets()` 三分支决定：

| 情形 | 行为 |
|---|---|
| X1-b 可用 | `X1_TARGETS` 覆盖 `LEVEL_ROWS`，同时**移除该卡 `CARDS` 里的国家级收益项**、保留代价项（否则违反「收益写程序、代价写项」） |
| X1-b 不可用 + 10 张新卡 | 目标写入 `LEVEL_ROWS` 供全量校验，再由 `("X1b",)` 暂存挡在 catalog 外 |
| X1-b 不可用 + 23 张老卡 | **不动**。旧版照常发布，v1 目标由 `validate_x1_targets()` 单独校验 |

第三分支是关键：早期版本用「有没有 `LEVEL_ROWS` 条目」判断老卡，结果
`colonial_plantation`（收益写在 `CARDS` 项里）被误判成新卡、目标被合并，随即被
「程序卡不得保留收益项」挡住。现在改成显式名册 `X1_BRAND_NEW`（10 张），不再靠推断。

### 6.3 两个设计限制（写卡时撞到的，不是 bug）

1. **程序卡只能写 `ideology.city.*`**。`double_entry` 的设计是纯国家级
   （「全国日贸易基础值每档，生产投入 -1%」），写不成 cell program，
   已移到 `X1_NATIONAL_TERMS`，用 `LEVEL_TERMS` 表达三级。
2. **kind 16 的源 tag 只能一个**（lint R3）。`container_port` 设计写「海岸繁市地块」，
   两个 tag 需要 DNF（属 X2），所以源 tag 取 `cell.terrain.coast`，
   「繁市」这个**目标侧**限定本轮没写 —— 已在卡 summary 里写明，记入 §8 待办。

### 6.4 待下一轮

1. ~~**§3.7 的卸下缺口**~~ —— **已由 R 修好**（C-d 冒烟 452/0）。§3.7 保留为历史记录。
2. **X16 + metric 68 + reserve_ratio 的 C++ 部分** —— R。
3. **X1-b 的 C++ 部分** —— R，按 §7 实施。注意 C-d 把开关**拆成两个**：
   只需把 `"X1_PLAIN_SWITCH"` 加进 `AVAILABLE_CAPABILITIES` 就能让 16 张改写 +
   7 张新卡上线（**不需要任何 C++**）；`"X1b"` 单独控制 6 张改写 + 3 张新卡。
4. **worker 端到端断言表驱动** —— 数据已预埋（§2.1 的 `card_expectations.json`），
   接线等 R 交回 worker 测试所有权。
5. `container_port` 的「繁市」目标侧过滤（需 X2 或给 kind 16 加目标 tag 槽）。
6. §3.5 的 X2 邻格计数（梯田 L3 真子句）仍缺。
7. 标签阈值标定：`CALIBRATION_IS_PROVISIONAL` 仍为 `true`。

### 6.5 C-d 修掉的四类正确性问题（都是单位/一致性，不是平衡）

| 类 | 实例 | 现在的 lint |
|---|---|---|
| ramp 单位 | `basic_income` `cap=15.0` 打在 0..1 的 `*_q16` 上（等于没有上限）；`manufactory_regulation` `per=2.0`（每座 +200%） | (a) `*_q16` 的 cap ≤ 1.0；(b) `per×cap` ≤ 1.0；(c) 计数类 metric 的 `per` ≤ 0.1 |
| 升级反降 | `basic_income_l3` / `automation_line_l3` 丢掉 L2 的 ramp；`maritime_insurance_l3` 丢掉 L2 的产出加成 | 单调性 lint（收益不得缩小/消失，代价不得变重；**代价变轻是合法升级**） |
| 描述≠stat | 8 张卡写 `output_factor`（全部产出）却说「贸易产出」；`circular_economy` 写 regen 却说「消耗」；`enclosure`/`chemical_industry` 同类 | 词表 lint `STAT_WORD`（每条命令的 stat 必须有一个中文词出现在 summary 里） |
| 开关粒度 | 33 张卡共用一个 `X1b`，其中 24 张根本不需要 C++ | 拆成 `X1b`(9) 与 `X1_PLAIN_SWITCH`(24)，生成器分组打印 |

**5 条新 lint 各自都有反例自测**，每次生成都会跑（`self_test_ramp_lint` +
`self_test_source_count_lint` + 三条 `validate_*`）。

### 6.6 C-d 踩到的坑（给下一次的自己）

**`_publishes_old_definition` 改了 6 次才对。** 每次都是「按形状找旧内容」，每次漏一种形状：

1. 把**任何** `LEVEL_TERMS` 当「已发布」→ X16 的 `economy.profession.*` 进了 Modifier
   catalog，`modifier_term_invalid` 让**整份目录编不过**（不只是那张卡）。
2. 把非空 `LEVEL_ROWS` 当旧行 → `land_value` 的成本程序被当成旧内容。
3. 「所有开关都关 → 一律暂存」→ 23 张改写的旧版被从 catalog 里删掉（62 张）。
4. 只看 `LEVEL_TERMS` → 又回到第 1 条。
5. `X1_BRAND_NEW` 放最后 → `communal_feast` / `supermarket` 带着 kind-16 程序发布了。

**正确的顺序**（现在的实现）：① `X1_BRAND_NEW` 先挡；② 有 `CARDS` 项 → 旧版照发；
③ 所有 `requires` 都不可用 → 暂存；④ 否则发 `LEVEL_ROWS`/`LEVEL_TERMS`。
教训：这类判定要用「闸门」提问（这张卡有没有**不受开关控制**的内容？），
不要用「形状」提问。

---

## 6bis. 历史待办（C-b 时的记录，保留备查）

1. ~~C-b：X1-b 设计文档~~ → 已完成，见 §7。
2. ~~C-c：把 55 张卡写进生成器~~ → 已完成，见 §6。
3. `09` 的 hash 表在**每次**重新生成后追加；本轮 6 行。

---


---

## 7. X1-b 需求规格（评审后修订版，只写文档，未写代码）

> 状态：**设计稿 v2**。v1 的四条实现意见已并入，来源是 reviewer 对运行时现状的核对。
> 依据：10-roadmap §4.2 / §4.3、02 §4.1、03 的 bitset 与 O9、设计文档 §5 / §14 的卡表。

### 7.0 一句话

现在的 `SEL_TAG_SOURCE_R1/R2`（kind 14/15）是「源格各展开一圈，取**并集**」：
一格夹在两个矿场中间只吃一份。X1-b 要的是**逐源计数叠加**。

### 7.1 语义

```
count(c)     = |{ s ∈ 本国自有格 : tag(s) ∧ dist(s, c) ≤ R ∧ s ≠ c }|
magnitude(c) = per_source × cap × min(count(c), cap) / cap
```

最后一项就是 `min(count, cap) / cap`，所以实际写法是

```
基础值 base   = per_source × cap                    # 编译期常量，一个完整的满叠加
缩放 scale(c) = min(count(c), cap) / cap            # 运行时按格算，Q16
magnitude(c)  = base × scale(c)
```

- `dist` 是六边形格距，与现有 `SELECTOR_NEIGHBORS_R1/R2`、`SEL_DISTANCE_N` 同一套。
- **源格不含目标格自身**：与 kind 14/15 一致；自环会让每块源格白得一层。
- **只算本国自有格**，跨国源格不算。理由：现有 `collect_effect_target_cells(OWN_TERRITORY)`
  就是本国领土；跨国会把「抢邻居一块矿田」变成隐式增益，与征服/外交纠缠（那是 X12/X14
  级别的设计问题）；性能上要把邻居表扩到全图。将来要做就开显式参数，默认关。
- **`R ∈ 1..4`**：`R≤2` 查邻居表（6 / 18 邻），`R 3..4` 有界 BFS（最多 61 格）。
  设计表没有一张卡需要 `R>3`。生成器与 C++ 两处都拒绝 `R>4`，不静默截断。
- **`cap` 是计数上限**，`cap × per_source` 就是满叠加值，受 `MAX_MAGNITUDE_Q16`（4×）约束。

### 7.2 `magnitude_scale_q16`：不新增指令

> **v1 的错误**：v1 提议新增 `READ_SOURCE_COUNT` 指令 + 64 个全网格派生列。
> 两者都不需要 —— `EffectRuntime::Instance` 已有
> `int32_t magnitude_scale_q16 = Q16_ONE;`（`effect_runtime.h:724`），
> 注释写得很清楚：程序编译出的 `value_q16` 是基础值，这个字段**只为该实例**缩放它。
> L3-9 第二片就是用它做「卡改卡倍率」的，批量入口是
> `effect_instance_forwarder.cpp:253/322` 的 `input.magnitude_scale_q16`
> 与 `batch.magnitude_scales` 列。

所以 X1-b 只做一件事：**给每个目标格的实例填一个 scale**。

```
value_q16        = per_source × cap        （编译期，program 常量）
magnitude_scale_q16 = min(count(c), cap) × Q16_ONE / cap   （reconcile 时按格算）
```

- `cap=1` 时 scale 恒为 `1.0` 或 `0`，退化成现在的行为 —— 兼容路径天然存在。
- 不需要新 opcode、不需要改 program 指令序列、不需要碰 metric 表。

### 7.3 count 在 reconcile 时现算，不做 COMMIT 全网格派生列

> **v1 的错误**：v1 提议在 Economy COMMIT 尾部为每个 `(tag, R)` 组合算一整列
> `uint8` 并塞进 `TagSnapshot`。这会让每个 epoch 的代价变成 `格数 × 组合数`，
> 而实际用到的格只是**被卡命中的那几十格**。

正确做法：**在 reconcile 时按目标格现算**。

- 时机：`reconcile_effect_activations` 解析目标集时，对每个候选格算 `count(c)`。
- 输入：`TagSnapshot` 已有的 `tag_bits`（`economy_runtime.h:124`，`[tag * tag_words + word]`）
  与 `_building_neighbors`（`capture_building_context` 填的 6 邻）。
- 算法：
  - `R ≤ 2`：BFS 一层/两层，每个候选格最多 `6 + 12` 次位查。
  - `R 3..4`：有界 BFS，最多 61 次位查。
- **代价**：`候选格数 × 邻居数`。候选格来自 tag 位图（源格），实际是「源格数 × 每源扇出」，
  与 v1 的「全图每格都算」相比小一到两个数量级。
- **缓存**：同一次 reconcile 内，多个卡可能问同一个 `(tag, R)`。按 `(tag, R, cell)`
  在 reconcile 的临时 map 里记忆化即可，**不跨 epoch 保留**（跨 epoch 才需要 revision 校验，
  那一层已经由 `TagSnapshot.generation` 提供了）。
- **没有消费者时开销为 0**：没有卡声明 kind 16 时，reconcile 不会走进这段代码。
  这与「声明-驱动」的既有思路一致（`EffectInputConsumers.metric_mask`
  只算 `requested()` 的列），但落点在 reconcile 而不是 COMMIT。

### 7.4 selector 参数：两个 int 的打包方案

> **v1 的错误**：v1 说「`param` 是 `PackedInt32Array`，长度自由」。
> 实际是 `int32_t target_selector_param[2] = {0, 0};`（`effect_runtime.h`），
> **只有两个 int**，且 `ideology_effect_definition.gd` 的 `_to_pod` 也只转发前两个
> （`if target_selector_param.size() > 1`）。加第三、第四个参数需要改 POD ABI。

kind 16 用现有两个 int，**位打包**：

| 槽 | 位 | 含义 | 取值 |
|---|---|---|---|
| `param[0]` | 0–4 (5 bit) | 目标格上限 `target_cap` | 1–31（0 = 默认 32） |
| | 5–7 (3 bit) | `radius` | 1–4 |
| | 8–11 (4 bit) | `cap`（计数上限） | 1–16 |
| `param[1]` | 0–15 (16 bit) | 源 tag id（1-based，与 `tag_bits` 同源） | 1–65535 |

```cpp
// 解码（C++ 与 GDScript 各一份，逐位一致）
const int32_t packed = metadata.target_selector_param[0];
const int32_t target_cap = (packed & 0x1F) == 0 ? 32 : (packed & 0x1F);
const int32_t radius     = (packed >> 5) & 0x07;
const int32_t cap        = (packed >> 8) & 0x0F;
const int32_t source_tag = metadata.target_selector_param[1] & 0xFFFF;
```

```gdscript
# 编码（生成器与 ideology_effect_definition.gd 共用同一个函数）
static func pack_source_count(target_cap: int, radius: int, cap: int, tag_id: int) -> PackedInt32Array:
	# 全部先夹到合法域，越界由 validate() 报，不在这里静默截断
	var packed := (target_cap & 0x1F) | ((radius & 0x07) << 5) | ((cap & 0x0F) << 8)
	return PackedInt32Array([packed, tag_id & 0xFFFF])
```

- 为什么不用 `param[1]` 放 radius：`param[1]` 在 12/13/14/15 里已经是 tag id，
  保持「tag 永远在 `param[1]`」让 4 个 kind 的解码逻辑同形，少一处分支。
- `target_cap` 占低 5 位是因为现有校验
  （`ideology_effect_definition.gd` 的 `target_selector_param[0] > SELECTOR_MAX_CELLS`）
  把它当整数值读；kind 16 必须**跳过那条校验**，否则 `packed` 总大于 32 而永远失败。
  这是 R 落地时必须改的一行，v1 没看到。
- `radius` 3 位（1–7）、`cap` 4 位（1–15）足够：设计表最大 `R=3`、最大 `cap=6`。

### 7.5 同分截断用 `effect_stable_cap`

> **v1 的错误**：v1 说「按 `count` 降序截断到 32」。运行时已有统一的截断器
> `effect_stable_cap(cells, cap, anchor, salt, stats)`（`effect_selector_cap.h:37`），
> 它按 `effect_selection_key(anchor, cell, salt)` 的哈希排序截断，并用 cell id 破平，
> **保证结果是 (anchor, salt, cell 集合) 的纯函数**。自己写一个「按 count 降序」的排序
> 会引入第二条截断规则，且 count 相同的格之间按什么排会变成隐患。

所以：**先算 `count`，再用 `effect_stable_cap` 截断到目标上限**。

- `count` 只决定每个格的 `magnitude_scale_q16`，**不参与**「谁被留下」。
  这样「哪些格被卡命中」与现有所有 selector 完全同构，不会出现「同一张图换布局就换命中集」
  这种诊断噩梦。
- `salt` 用 `effect_program_hash(program)`，与现有 kind 14/15 的调用点一致
  （`ideology_runtime.cpp:1559`）。
- 代价：截断可能留下 `count` 较低的格。这是**已知且可接受**的取舍 ——
  `effect_stable_cap` 的注释解释了为什么「按 id 或按值排序」都不如哈希采样：
  前者让每张卡都偏爱地图同一角，后者让排序规则变成卡的业务语义。
- `stats.matched_total` / `truncated` 会如实记进 `_selector_stats`，
  截断可在诊断报告里看到。

### 7.6 生成器 DSL

```python
prog("iron_smelting_l1",
     "主产铁矿石的地块周围 1 格（每源 +6%，最多 3 源 = +18%）",
     tags=("cell.produces.iron_ore",),
     selector=SEL_TAG_SOURCE_COUNT,   # kind 16
     radius=1,
     cap=3,
     per_source=cell(6),
     cmds=(mod(city_stat_key("building.manufacturing_output_factor"), RAMPED),))
```

- `Prog` 加三个字段：`radius: int = 0`、`cap: int = 0`、`per_source: float | None = None`。
- 发射时 `value_q16 = per_source × cap`，`param = pack_source_count(...)`。
- `requires=("X1b",)` **自动**加到所有用 kind 16 的卡上，不靠作者手写。

**非法组合硬失败（`validate_programs`）**：

| 组合 | 拒绝理由 |
|---|---|
| kind 16 但 `per_source is None` | 没有强度 |
| kind 16 但没有 `tags` | 源 tag 必需 |
| kind 16 且 `len(tags) != 1` | 源格只能一个 tag（多 tag 属 X2 的 DNF） |
| kind 16 且 `radius ∉ 1..4` | §7.1 |
| kind 16 且 `cap ∉ 1..15` | 4 位打包域 |
| kind 16 且 `len(cmds) != 1` | 一条命令一个 scale |
| kind 16 且 `cap × per_source > 4.0` | 超 `MAX_MAGNITUDE_Q16` |
| 非 kind 16 却给了 `radius/cap/per_source` | 参数用在不认识它的 selector 上 |
| kind 14/15 给了 `per_source` | 14/15 是并集，混用会被误读成叠加 |

### 7.7 卡表与分布（脚本生成，数字可复现）

生成脚本：`tools/ideology/x1b_inventory.py`（本轮新增，见 7.7.4），
输出直接贴在这里，避免手数。

#### 7.7.1 54 张的分布

```
X1-blocked total: 54
  already implemented, SELF/COUNTRY: 12
  already implemented, kind 14/15 union: 9
  not written yet: 33
```

- **12 张已实现且不依赖 X1-b**（SELF/COUNTRY 形态）：
  `three_field_rotation`、`settle_and_farm`、`ever_normal_granary`、`public_hygiene`、
  `urban_sanitation`、`coal_basin`、`standardization`、`free_exchange`、`antitrust`、
  `computing_networks`、`coppice_rotation`、`ecological_balance`
- **33 张尚未实现** —— C-c 的主体
- **9 张已在 54 张内且用 kind 14/15**，见 7.7.2

#### 7.7.2 T12 的 **12 张**（全量，不只是 54 张内的 9 张）

「X1-b 落地后一次性全部切换」的对象是**全仓所有 kind 14/15 卡**，共 12 张
（脚本枚举，含 54 张之外的 3 张）：

| # | 卡 | 现 selector | 源 tag | 在 54 张内 |
|---|---|---|---|---|
| 1 | `water_works` | R1 | `cell.terrain.floodplain` | 否（已发布） |
| 2 | `riverside_camp` | R1 | `cell.landform.delta` | 否（已发布） |
| 3 | `hydroelectric` | R2 | `cell.sector.energy` | 否（已发布） |
| 4 | `iron_smelting` | R1 | `cell.produces.iron_ore` | 是 |
| 5 | `flint_knapping` | R1 | `cell.produces.flint` | 是 |
| 6 | `sericulture` | R1 | `cell.produces.cloth` | 是 |
| 7 | `cotton_gin` | R2 | `cell.produces.cotton_fiber` | 是 |
| 8 | `agricultural_chemistry` | R2 | `cell.produces.fertilizer` | 是 |
| 9 | `petrochemical` | R2 | `cell.produces.crude_oil` | 是 |
| 10 | `collective_stewardship` | R1 | `cell.sector.agriculture` | 是 |
| 11 | `electrification` | R2 | `cell.sector.energy` | 是 |
| 12 | `motorization` | R2 | `cell.market` | 是 |

> `land_reclamation` 一度被脚本误报为第 13 张，实际它只是注释里提到
> `cell.frontier`，`selector=` 出现 0 次 —— 脚本已修正（改成匹配 `selector=` 而不是散串）。

**T12 = 这 12 张一起回归**：切换后每张的 stat 必须等于重新标定后的设计值，
且卡池容量、命中格数、`matched_total` 三项一起对比。

#### 7.7.3 需要 X1-b 计数的卡与取值（照抄设计 · 反推值单列）

设计表真正写「多源叠加 / 每源」的卡（脚本扫出 6 张，加上「周围 N 格」形态共 19 张）：

| 卡 | 源 tag | R | per_source | cap | cap 来源 |
|---|---|---|---|---|---|
| `enclosure` | `cell.produces.livestock_products` | 1 | +10% 畜产 / -5% 粮作 | **3** | 用户指定 |
| `agricultural_chemistry` | `cell.produces.fertilizer` | 2 | +8% | 3 | 反推（+24% ÷ 8%） |
| `collective_stewardship` | `cell.sector.agriculture` | 1 | +3% | 3 | 反推（取 3） |
| `settle_and_farm` | `cell.sector.agriculture` | 1 | +8% | 4 | 反推（取设计 L3 的 4 邻） |
| `flint_knapping` | `cell.produces.flint` | 1 | +4% | 3 | 反推（取 3） |
| `iron_smelting` | `cell.produces.iron_ore` | 1 | +10% | 3 | 设计原文「最多吃 3 个来源」 |
| `chemical_industry` | `cell.produces.salt` | 2 | +15% | 3 | 反推（取 3） |
| `electrification` | `cell.sector.energy` | 2 | +8% | 3 | 反推（+24% ÷ 8%） |
| `sericulture` | `cell.produces.cloth` | 1 | +12% | 3 | 反推（取 3） |
| `cotton_gin` | `cell.produces.cotton_fiber` | 2 | +10% | 3 | 反推（取 3） |
| `petrochemical` | `cell.produces.crude_oil` | 2 | +12% | 3 | 反推（取 3） |
| `postal_horse` | `cell.produces.horses` | 2 | +6% | 3 | 反推（取 3） |
| `motorization` | `cell.market` | 2 | +4% | 3 | 反推（+12% ÷ 4%） |
| `container_port` | `cell.market`（海岸繁市） | 2 | +10% | 3 | 反推（取 3） |
| `department_store` | `cell.metropolis` | 1 | +4% | 3 | 反推（取 3） |
| `suburbanization` | `cell.metropolis` | 2 | +5% | 3 | 反推（取 3） |
| `offshore_drilling` | `cell.terrain.coast` | 1 | +10% | 3 | 反推（取 3） |
| `supermarket` | `cell.settlement` | 1 | +6% | 3 | 反推（取 3） |
| `arcology` | `cell.metropolis` | 2 | +8% | 3 | 反推（取 3） |
| `communal_feast` | `cell.produces.game_meat` 等 | 1 | +3% | 3 | 设计原文「多源叠加，上限 +9%」 |

**「反推（取 3）」= 设计没写 cap，按用户规则默认取 3**，全部登记进 09 §8 待调清单。
**数值本期不讨论**，写卡时照抄本表。

#### 7.7.4 生成脚本

新增 `tools/ideology/x1b_inventory.py`：读生成器 + 设计文档，输出上面三张表的数字。
它让 7.7.1 的「54 / 12 / 9 / 33」与 7.7.2 的 12 张名单可**一键复现**，
而不是靠这次对话里的手数。

### 7.8 超过 32 格的卡

`SELECTOR_MAX_CELLS = 32` 不解除，`effect_stable_cap` 按哈希截断。以下卡可能超：

| 卡 | 设计文字 | 处理 |
|---|---|---|
| `electrification` | 2 格内（最多 18 格） | 设计自写 18，不超 |
| `motorization` | 2 格内 | 3 源 × 6 邻 ≈ 18，不超 |
| `container_port` / `arcology` / `suburbanization` | 周围 2 格 | 可能超 → `effect_stable_cap` 截断，卡面写「最多 32 格」 |

**没有一张卡必须 >32 格才能表达设计意图。** 若将来有卡要全覆盖，才需要 03 §4 的系数平面。

### 7.9 存档与 ABI

- **无存档变化**：`count` 是 reconcile 时现算的派生量，`magnitude_scale_q16` 已经是
  `EffectRuntime::Instance` 的现有字段、本来就在 PKEF 里。
- **无 POD ABI 变化**：`magnitude_scale_q16` 在 `runtime_effect_pod.h:291/307` 已有，
  `effect_instance_forwarder` 已在转发 `magnitude_scales` 列。X1-b 只是多一个填值来源。
- **无 Modifier catalog hash 变化**：不新增 stat。
- **ideology catalog hash 会变**：新卡 + 12 张重标定。
- **worker 侧**：不需要新字段。唯一要核的是 `runtime_effect_pod` 的 selector 白名单
  是否枚举到 kind 16（它会拒绝未知 kind），以及 `POD_MAX_SELECTOR_KIND` 要不要
  从 15 提到 16（`effect_catalog.gd:25` 的 GDScript 镜像同改）。
  **这是 R 落地时唯一需要动的常量。**

### 7.10 测试清单

| # | 用例 | 断言 |
|---|---|---|
| T1 | 两源夹一格 | 中间格 `count=2`，`scale = 2/cap`，magnitude = `2 × per_source` |
| T2 | 移除一源 | `count` 2→1，magnitude 减半；位翻转后一个 reconcile 内生效 |
| T3 | R=3 走 BFS | 距离 3 计入、距离 4 不计；与手算一致 |
| T4 | cap 生效 | `cap=2` 时 3 个源只给 `2 × per_source`（`scale` 饱和在 `Q16_ONE`） |
| T5 | 无消费者零开销 | 没有 kind 16 卡时不进入计数路径；新计数器 `source_count_evaluations == 0` |
| T6 | 源格不计自身 | 孤立格 `count=0`，`scale=0`，不吃加成 |
| T7 | 只算本国 | 邻国同 tag 格不增加 `count` |
| T8 | 截断走 `effect_stable_cap` | 超 32 时保留集合是 `(anchor, salt, cell 集)` 的纯函数；同输入两次运行集合相同；`stats.truncated=1` |
| T9 | worker 端到端 | 生产夹具装备 X1-b 卡 → stat == 设计值；卸下恢复（依赖 §3.7 修复） |
| T10 | 生成器 lint | §7.6 的 9 条非法组合各一条反例 |
| T11 | 打包位布局 | `pack_source_count` / 解码在 GDScript 与 C++ 两侧对同一组输入产出相同四元组（含边界 31/4/15/65535） |
| T12 | 12 张一起回归 | 7.7.2 的 12 张切换后 stat == 重标定值，命中格数与 `matched_total` 一起对比 |

> v1 的 T11「双权威 count 列逐格相等」已删除：count 不再是持久列，
> 而是 reconcile 时的临时量，没有「两边的列」可以比。双权威一致性由 T9 端到端覆盖。

### 7.11 落地顺序（给 R）

1. `POD_MAX_SELECTOR_KIND` 15 → 16（C++ + GDScript 镜像），kind 16 解析 + 打包解码 + T11。
2. reconcile 内 `count(c)` 现算（`R≤2` 邻居表）+ T1/T2/T4/T6/T7。
3. `R 3..4` BFS + T3。
4. 填 `magnitude_scale_q16` + `effect_stable_cap` 截断 + T8。
5. C 侧 DSL + lint（T10）+ 单卡端到端（`iron_smelting` 先做，它是教学卡）+ T9。
6. 12 张一次性重标定 + T12；然后批量写卡（C-c）。

---

---

## 8. 待调数值清单（本期不讨论，登记备查）

用户规则：**照抄设计文档；设计没写的用反推规则或取 3**，列在这里，不再提问、不挡进度。

| # | 卡 / 位置 | 数值 | 来源 | 备注 |
|---|---|---|---|---|
| 1 | `enclosure` cap | **3** | 用户指定 | 唯一被明确指定的 cap |
| 2 | `agricultural_chemistry` cap | 3 | 反推 +24% ÷ 8% | 设计写了效果上限 +24% |
| 3 | `electrification` cap | 3 | 反推 +24% ÷ 8% | 同上 |
| 4 | `motorization` cap | 3 | 反推 +12% ÷ 4% | 同上 |
| 5 | `iron_smelting` cap | 3 | 设计原文 | 「最多吃 3 个来源」 |
| 6 | `communal_feast` cap | 3 | 设计原文 | 「上限 +9%」÷ 3% |
| 7 | `collective_stewardship` cap | 3 | 取 3 | 设计未写 |
| 8 | `settle_and_farm` cap | 4 | 取设计 L3 的 4 邻 | 设计未写 cap |
| 9 | `flint_knapping` / `sericulture` / `chemical_industry` / `cotton_gin` / `petrochemical` / `postal_horse` / `container_port` / `department_store` / `suburbanization` / `offshore_drilling` / `supermarket` / `arcology` cap | 3 | 取 3 | 设计均未写 |
| 10 | `excise` L3 ramp | `per=0.005, cap=8.0` | 用户指定「最多 -4%」 | 每档 0.5%，8 档封顶 |
| 11 | `excise` 三货产出 | 0.96（-4%） | 反推 | 设计未给具体点数 |
| 12 | `land_tax_reform` 地主满意度 | -8 / -10 | 反推 | 设计写「强烈反对」，无点数 |
| 13 | `petition_box` 满意度 | +4 / +6（bp 400/600） | 设计原文 | — |
| 14 | `progressive_tax` 资本方容忍度 | 0.80 | 设计原文 | — |
| 15 | `tax_holiday` 商人满意度 | -2（bp -200） | 设计原文 | — |
| 16 | `light_levy` L3 农耕满意度 | +3（bp 300） | 设计原文 | — |
| 17 | `ancestral_hall` / `gentry_patronage` 佃农层满意度 | -3 / -2 | 设计原文 | — |

**「取 3」的规则**：叠加型外溢卡的 `cap` 设计没写时默认 3，
因为「每源 +X%」三源即 `3X`，与设计表里最常见的「上限 ≈ 3 倍单源值」一致。

### 8.1 C-d 新增的反推值

| # | 卡 / 位置 | 数值 | 来源 |
|---|---|---|---|
| 18 | `basic_income` cap | 0.15（= +15%） | 设计「上限 +15%」按 ramp 单位换算 |
| 19 | `automation_line` L2 cap | 0.20（= +20%） | 设计「上限 +20%」 |
| 20 | `gig_economy` cap | 0.12 / 0.16（= +12% / +16%） | 设计原文上限 |
| 21 | `manufactory_regulation` per | 0.02 / 0.03 | 设计「每座 +2% / +3%」 |
| 22 | `manufactory_regulation` cap | 8 / 8 / 10 座 | 设计「上限 +16% / +24% / +32%」÷ per |
| 23 | `maritime_insurance` L3 全部产出 | +15%（承袭 L2） | 修单调性时补回，设计 L3 未单列 |
| 24 | `enclosure` 牧场再生 | +30% / +45% / +45% | 设计写「畜产 +10%/+15%」，可写的 stat 是牧场再生 |
| 25 | `chemical_industry` 化肥产出 | +45% / +60% / +60% | 设计写「工业化学品、化肥 +15%」，可写的只有化肥 |
| 26 | `financialization` 工业惩罚 | **删除**（原「工业 ×0.92」） | `output_factor` 没有分产业变体，无法只罚工业 |
| 27 | `container_port` 「繁市」限定 | **未写** | 源 tag 只能一个（lint R3），繁市过滤需 X2 |
| 28 | `gene_editing` | +12% / +16% / +20% 平台值 | 设计是「专精度线性」，线性 ramp 需要逐格专精度 metric，本轮用平台值 |

### 8.2 C-e 修掉的 ramp 上限换算（单位错误，不是平衡）

约定：`value = per × min(metric, cap)`，`per` 是**每单位 metric 的增益（小数）**，
`cap` 用 **metric 自己的单位**。说明里写「上限 +N%」时，必须满足 `per × cap == N%`。

| 卡 | 改前 | 改后 | 原因 |
|---|---|---|---|
| `basic_income` L2/L3 | `per=1.5, cap=0.15` → 实际 +22.5% | `cap=0.10` → +15% | cap 误用了「效果上限」而不是「上限 ÷ per」 |
| `automation_line` L2/L3 | `per=1.5, cap=0.20` → 实际 +30% | `cap=0.1333` → +20% | 同上 |
| `salt_monopoly` L2/L3 | `per=0.015/0.02, cap=15` → +22.5% / +30% | `cap=10 / 7.5` → +15% | 已发布卡，同类错误 |
| `chartered_route` L2/L3 | 同上 | `cap=10 / 7.5` → +15% | 同上 |
| `semiconductor` L2/L3 | `per=0.025/0.03, cap=20` → +50% / +60% | `cap=16 / 13.3334` → +40% | 同上 |

**新增 lint `ramp_ceiling_error`**：从 summary 里正则抓「上限 ±N%」，与 `per × cap` 比较，
容差 0.1 个百分点。反例（必须被拒）：`per=1.5, cap=0.15` 配「上限 +15%」。
这条 lint 第一次跑就抓出 6 个**已发布**卡的同类错误 —— 也就是说这个单位 bug
在本轮之前一直存在于线上。

**注意 #26/#27 是「设计做不到」而不是「数值待调」**：它们需要 X2 / 分产业 stat。
**#28 是近似**：设计要线性，实际是平台值，等有专精度 metric 再改。

---
