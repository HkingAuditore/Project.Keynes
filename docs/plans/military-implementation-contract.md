# Military v1 实现契约（协调者维护，子 agent 只读）

设计依据：`docs/plans/military-system-design.md` v1.3。本文冻结跨模块接口，任何子 agent
不得修改他人拥有的文件；需要改接口时在回报里提出，由协调者统一调整。

## 0. 已确认的工程决定（相对设计稿的落地取舍）

1. **不新增 RuntimeDomainId**（12 阶段 ABI 冻结）。Military 是主线程同步 runtime：
   `DCWorldExt` 持有 `pk::MilitaryCore`，GDScript `MilitaryDailySystem`（DCSystem，在
   `map_generator.gd::_setup_sus` 的 native/legacy 分叉**之前**注册）在非整图权威路径调用
   `run_military_daily`；整图 ACTIVE 路径由 `WorldRuntimeHost._consume_runtime_commit_if_ready`
   在每个已提交日之后补跑（与 natural resource commit drain 同一模式，每帧最多追 4 日）。
2. **读 D 日已提交数据、产出 D+1 意图**。Military 只写自己的 store；对 Country / Economy
   的所有修改都通过各自已有的命令入口（`submit_country_commands` / `submit_economy_commands`
   字典批次，二者已自带 worker/sync 路由），生效日 D+1。
3. **控制权（controller）v1 由 Military 持有**（`MilitaryCore::_cell_controller`，PKMI 存档），
   通过 `get_military_control_snapshot()` 暴露给 UI/渲染；Economy 的占领税/补贴归属 v1
   暂不切换（文档登记为后续门禁）。所有权变更（割地、吞并）走 Country 命令，照常触发
   `country_committed`。
4. **Country 新增 opcode**（同步 + worker 共享内核 `country_core_apply_command` 都要实现）：
   - 23 `TRANSFER_CASH_BETWEEN_COUNTRIES`：`target_handle`=付款国；收款国句柄拆成
     `cell` = 收款国 slot、`aux` = 收款国 generation（重组为 `(aux<<32)|cell` 后用
     `country_core_validate_target` 校验）；`value` = 金额（MONEY_SCALE）。
     余额不足时按余额转移，实转额写入事件 value。
   - 24 `TRANSFER_GOODS_BETWEEN_COUNTRIES`：同上编码收款国，`domain` = dense good，
     `value` = 数量（GOODS_SCALE），不足按余额。
   - 27 `ANNEX_COUNTRY`：`target_handle`=受害国，`cell`/`aux`=吞并国 slot/generation。
     同一批次内：受害国全部领土 → 吞并国，现金和物资全部转移，受害国 `active=0`、
     `generation+1`、`territory_count=0`；"活跃国家必须有领土"检查对已失效国家豁免；
     受害国 cell tax policy 清空。事件 opcode 27 计入 territory evidence（`country_facade.gd`
     的 territory opcode 过滤要加 27）。
   - 22/25/26 保留不用（controller 在 Military）。
5. **Economy 侧兵员**复用现有命令，不新增 Economy opcode（第一版）：
   - 入伍/征召：`COMMAND_CHANGE_SIGNATURE`（cohort handle → soldier 签名，`i32_0`=新 signature，
     `i64_0`=人数）。
   - 退伍：同上，soldier → unemployed。
   - 伤亡：`COMMAND_ADD_POPULATION` 负数。
   - 军饷：`COMMAND_TRANSFER_TO_COHORT`（国库 → soldier cohort，`i64_1`=国家句柄）。
   - 军需采购：`COMMAND_MARKET_GOOD_TO_COUNTRY`（市场 → 国库，按 Economy 现有政府采购口径付款给商人）；
     Military 记账后用 Country opcode 21 `CONSUME_TREASURY_GOODS` 每日消耗（守恒：物资离开国库=被消耗）。
   - 征发：`COMMAND_REMOVE_STOCK`（显式 stock delta，计入 Military 账本 `requisitioned`）。
   - 官营建筑：`COMMAND_TREASURY_SPONSORED_BUILD`；`building_kind="state"` 由 Economy agent
     在投资评审/恢复期/亏损停业/家族产业中排除。
   如果 Economy agent 证明某一项无法用现有命令守恒完成，再新增 opcode 24+。
6. **兵种/装备/官营建筑目录**：`data/military/military_catalog.json`（单文件，GDScript
   `MilitaryCatalogCompiler` 编译成字典 → `configure_military`）。军需物资、军工建筑、
   士兵职业、科技节点、Modifier stat 进各自现有目录。

## 1. C++ 文件归属

| 文件 | 负责人 | 内容 |
| --- | --- | --- |
| `gdext/src/military_bridge.h` | 协调者 | 冻结：digest / intent / event / receipt POD |
| `gdext/src/military_core.h` | 协调者 | 冻结：MilitaryCore 状态与阶段函数签名 |
| `military_core.cpp`, `military_core_path.cpp`, `military_core_save.cpp` | A1 | 生命周期、命令、招募训练、部队、移动寻路、PKMI |
| `military_core_logistics.cpp`, `military_core_war.cpp` | A2 | 后勤、车队、威胁场、战争、交战、会战、占领、和议、吞并、战线 |
| `military_core_ai.cpp`, `military_core_selftest.cpp` | A3 | AI 议程、自测、合成压测 |
| `world_ext_military.cpp` + `world_ext.h` 中 Military 段 + `world_ext_bind_methods.cpp` 中 Military 段 | B | Godot 桥：digest 采集、意图提交、查询、存档 |
| `country_runtime.*`, `country_core_apply.*`, `runtime_pod_protocol.h`（仅 Country 部分）, `effect_runtime.cpp` opcode cap | B | Country opcode 23/24/27 |
| `economy_runtime*.cpp/.h` | C | soldier 职业校验、state 建筑排除、`state_payroll`、军供需求跳过购买 |

## 2. DCWorldExt 绑定（B 实现，E/F 调用）

所有返回 `Dictionary` 带 `ok` 与失败时的 `reason`。

| 方法 | 说明 |
| --- | --- |
| `configure_military(catalog: Dictionary, seed: int) -> Dictionary` | 目录见 §3 |
| `set_military_terrain(t: Dictionary) -> Dictionary` | `cell_count,width,height,neighbors(PackedInt32Array 6n),landform,vegetation,cover,is_water,has_river,settlement_tier(PackedByteArray)` |
| `submit_military_commands(batch: Array) -> Dictionary` | 每项 `{op:String, country:int, army:int, other:int, cell:int, radius:int, unit_from:String, unit_to:String, count:int, value:int, cells:PackedInt32Array, units:Dictionary(unit_id->int), terms:Array}`；返回 `{ok, accepted, rejected:[{index,reason}]}` |
| `military_should_run(day: int) -> bool` | |
| `run_military_daily(ctx: Dictionary) -> Dictionary` | `ctx.day_index`；采集 digest、`step_day`、提交意图；返回 report 字段 + `intents_submitted` + `country_ops` + `economy_ops` |
| `get_military_report() -> Dictionary` | §21.9 计数器 |
| `get_military_country_snapshot(country: int) -> Dictionary` | 兵力总览、目标、配置、政策、军费、实付率、士气、战争卡、兵营列表、训练队列 |
| `get_military_armies(country: int) -> Array` | 部队卡列表 |
| `get_military_army(army: int) -> Dictionary` | 编成、品质、攻防速、补给天数（按类）、车队、士气分解、组织度、任务、统帅空位 `commander:{open:false}` |
| `get_military_cell_snapshot(cell: int, observer: int) -> Dictionary` | 兵额、在驻（本地/外地）、空额、配额、征召、训练队列、城防、军校、控制者 |
| `get_military_render_snapshot(after_revision: int) -> Dictionary` | `revision, armies:{handle(PackedInt64), owner_slot, cell, prev_cell, moved_day, unit_class, headcount, flags(PackedInt32: bit0 低补给 bit1 缺粮 bit2 欠饷 bit3 低士气 bit4 交战 bit5 撤退), composition_offsets, composition_unit, composition_weight, heading_q16, attack_seq, hit_seq}, engagements:{cell_a,cell_b,progress_q16,attacker_slot}, convoys:{current_cell,dest_cell,country_slot,risk_q16}, control_revision, controller_cells, controller_slots, front_revision, front_edges(PackedInt32 key=cell*6+dir)`；composition CSR 每军最多 3 项，weight 降序、同 weight dense unit id 升序；其余新字段当前为 0 只读占位 |
| `get_military_control_snapshot() -> Dictionary` | `{revision, cells, controller_slots}` 稀疏 |
| `poll_military_events(after_id: int, limit: int) -> Array` | `{id, day, type, cell, i0..i3, value}` |
| `preview_military_path(army: int, cell: int) -> Dictionary` | `{ok, cells, days}` |
| `evaluate_military_peace(war_id: int, proposer: int, terms: Array) -> Dictionary` | `{ok, price, willing, band:"low|mid|high", reason}` |
| `get_military_catalog_view() -> Dictionary` | 兵种与装备图鉴用 |
| `encode_military_state() -> PackedByteArray` / `restore_military_state(bytes) -> Dictionary` | PKMI |
| `runtime_military_self_test() -> Dictionary` / `run_military_bench(cfg) -> Dictionary` | |

命令 `op` 字符串：`force.set_target, force.set_levy, force.set_auto_discharge, config.set,
config.set_quality_policy, config.auto_retrain, barracks.pause, train, state.build,
state.demolish, policy.set_wage, policy.set_procurement, army.create, army.station,
army.transfer, army.merge, army.split, army.set_template, army.reinforce, army.move,
army.area_control, army.stop, army.stance, army.rename, army.disband, war.declare,
peace.propose, peace.respond`。terms：`[{kind:"white|cede|annex|lump_sum|installments|goods|return", cell, n, good, amount}]`。

## 3. 目录格式 `data/military/military_catalog.json`

```json
{
  "schema": 1,
  "units": [{"id","name","description","class":"line|mobile|artillery","era","tech":"tech.x|''",
             "militia":false,"attack","defense","speed","fortification_ignore":0.0,"training_days",
             "equipment":[{"category","min_quality","per_100","weight"}],
             "supply_idle":{"ration":0,"fodder":0,"ammunition":0,"fuel":0,"upkeep":0.05},
             "supply_combat":{...},"icon":"unit.<class>"}],
  "equipment_categories": [{"id","name","goods":[{"good","quality"}]}],
  "state_buildings": [{"id","name","role":"barracks|fortification|war_college","tier","tech",
             "capacity","fort_bonus","training_speed","upkeep","build_days","materials":{"good":qty}}],
  "supply": {"fodder":["grain",...], "ammunition":"@ammunition", "fuel":["refined_fuel"], ...}
}
```
`MilitaryCatalogCompiler`（GDScript，E 负责）把 good/tech id 解析成 dense id，口粮候选从
`soldier_household` 的 staple_food/protein 变体读取并给出 `supply_yield_q16`。

## 4. GDScript 文件归属

| 文件 | 负责人 |
| --- | --- |
| `scripts/military/military_facade.gd`、`military_catalog_compiler.gd`、`scripts/simulation/systems/military_daily_system.gd`、`map_generator.gd`/`world_runtime_host.gd`/`game_save_coordinator.gd` 的接线、`gameplay_event_bus.gd` / `trigger_catalog.gd` 事件登记 | E |
| `data/military/military_catalog.json`、`data/economy/**`（物资、建筑、职业、消费计划）、`data/technology/technology_network.json`、`data/modifiers/**`、理念卡、家族内容 | D |
| `scripts/ui/components/military_workspace.gd`（+ 子组件 `military_*`）、`country_panel.gd`/`country_action_bar.gd` 开放、Inspector 军事页、`scripts/rendering/military_*_layer.gd`、`assets/military/**`、icon_catalog 新键 | F |
| `docs/cpp-dots-runtime/military-runtime.md`、authority matrix / scheduling / system-map 同步、`.dsh/skills/project-keynes-military-runtime/` | G（最后） |

## 5. 性能红线

- 热循环禁止 Dictionary/Variant/String/new；scratch 数组 stamp 复用。
- 和平且无移动：`military_should_run` 返回 false（零 slice）。
- 标准图 400 部队 p95 ≤ 0.5ms；合成 100k 格 / 2048 部队 / 4096 交战段 ≤ 2ms（`run_military_bench`）。
- RNG：`splitmix64(seed ^ key ^ day)`，与线程无关。
