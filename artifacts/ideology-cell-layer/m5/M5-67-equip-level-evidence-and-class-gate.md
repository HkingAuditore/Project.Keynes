# M5-67 装卸与升级的机制证据 + 一条会挡住所有后续夹具的门

| 项目 | 内容 |
|---|---|
| 覆盖 | plan §18.1「装卸、升级」两项（此前为「无证据」）|
| 夹具 | `tests/ideology/ideology_mechanism_equip_level_test.gd` |
| 结果 | **133 checks / 0 failures**（我独立复跑确认）|
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 一条会挡住所有后续夹具的门：class-opinion 支持度

**`unequip` 会被职业阶层支持度挡住**，而错误码看起来像「转移卡住」，很容易误判。

`unequip` 调 `support_gate(SUPPORT_REPEAL)`（`ideology_runtime.cpp:4582` → `:1303`），
它比较**按影响力加权**的阶层立场与卡片的 `repeal_threshold_q16`。

`idea.public_hygiene` 的撤回立场是 farmer **+8192** / general **−8192** / worker **−24576**。

**关键坑**：`subsistence_farmer` 和 `serf` 的 `profession_class_id` **都是 "general"**。
所以常见夹具的人口混合是 **100% general** → 支持度 **−8192 < 0** → `ideology_support_threshold_not_met`。

### 实测（夹具里的负向对照，world C）

| 人口 | `support_q16` | `allowed` | unequip |
|---|---|---|---|
| 0 farmer + 80 general | `[16384, **−8192**, 20480]` | `[1, **0**, 1]` | **拒绝** `ideology_support_threshold_not_met`，`pending_transitions=0` |
| `household_farmer` **3:1** over `subsistence_farmer` | `[10743, **3088**, 12019]` | `[1, **1**, 0]` | **接受** |

**这是门拒绝，不是挂死**（`pending_transitions=0` 说明没有转移在飞）。

**任何需要 UNEQUIP 的夹具都必须用 farmer-heavy 的人口混合**，或者选撤回立场非负的卡。

### 诊断工具

`explain_ideology(handle, id)` 直接返回 `support_q16` / `support_thresholds_q16` / `support_allowed` /
`support_available` / `class_influence` / `*_stances_q16`——**排查任何装备/卸下拒绝的最快路径**。

## 2. 我指令里的一处错误（已被夹具纠正）

我在派单时写「有转移在飞时第二次装备会报 `ideology_transition_pending`」。**这只在目录没有 synergy 时成立。**

守卫顺序（我核实过）：

```cpp
:4550  if (country.pending_transition_count > 0 && !_synergies.empty()) {
:4551      error = "ideology_country_transition_pending"; return false;   // ← 先
:4555  if (state->transition.active != 0) {
:4556      error = "ideology_transition_pending"; return false;           // ← 后
```

**出厂目录有 68 条 synergy**，所以实际报的是**国家级**的 `ideology_country_transition_pending`。

夹具用两个世界同时证明了这两条守卫（world A 用出厂目录、world B 把 `synergies=[]`），
**两个都是正确的拒绝，都不是缺陷**。

第二次卸下同理：world A 报 `ideology_country_transition_pending`，
world B 报 `ideology_not_equipped`（因为请求已经先把 location 改成 INACTIVE，`:4580` 先于 `:4581` 命中）。

## 3. 阶段数字（8×8 世界，1 国，42 个有主格 → 卡片占 84 行）

| 阶段 | 容量 | levels / understanding | pending | front |
|---|---|---|---|---|
| 装备 d0 | 1/2 | [0] / 205 | **1** | 84 行，add **+0.05000305**（3277/65536）|
| 转移在飞时再装备 | 1/2 | — | 1 | `status=3 ideology_country_transition_pending` |
| 握手后 | 1/2 | [0] / 615 | **0** | 84/84；**presence 只在 42 个有主格，22 个无主格为 0** |
| 升级 d3 | 1/2 | **[1]** / **525108**（阈值 524288）| 1 | gen 1→2，add **+0.08000183**（5243/65536），cut →**−0.10000610** |
| 升级结算 | 1/2 | [1] | **0** | gen 不变（I13 内容相同不重装），L2 保留 |
| 卸下 d5 | **0/2** | [0] | 1 | 空 |
| 转移在飞时再卸下 | 0/2 | — | 1 | `status=3 ideology_country_transition_pending` |
| 卸下结算 | 0/2 | [0] | **0** | **84→0 行 / 84→0 contrib** = 恰好是这张卡的行数 |
| 重新装备 d8 | **1/2** | [1] 保留 | 0 | 回到 84 行，**携带 L2 数值** |

**每个幅度都精确等于目录里的 Q16 值**（3277/65536 = 0.05000305；5243/65536 = 0.08000183；
−5243/65536 = −0.08000183；−6554/65536 = −0.10000610）。**不是「非零」这种弱断言。**

握手序列（不可省）：

```
dispatch_effect_native_modifier() -> run_modifier_daily(day) -> ack_effect_native_modifier()
```

**`run_modifier_daily` 在 dispatch 与 ack 之间是必需的**，否则 ack 永远报 `pending`。

## 4. 另外三条值得传下去的事实

| 事实 | 说明 |
|---|---|
| 无 front 时报告**省略** `contribution_count` | `world_ext_modifier.cpp:1082-1086`；**缺键 = 零行，不是 −1** |
| `levels_advanced` **含**装备时 −1→0 的首次物化 | 所以断言要取**增量**，不能取绝对值 |
| `get_ideology_snapshot()` 有 `ideology_slots_used` / `ideology_slots_capacity` | 比数 `locations` 可靠得多 |

## 5. 未覆盖

- **容量超限拒绝**（`ideology_slot_capacity_exceeded`）：需要第二张卡自己的 ADOPT 门也通过，
  而**出厂 113 张卡全部带阶层立场**。容量释放是用 `ideology_slots_used` **1→0→1** 数值证明的。
- **部分 front 下降**（两卡只卸一张）：同上原因；实测的下降是 84→0，恰好是这张卡的行数。
