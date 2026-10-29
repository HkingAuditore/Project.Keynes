# 理念派生地块层 —— **UI 消费指南**

| 项目 | 内容 |
|---|---|
| 用途 | 将来做界面时**查这里**：能调什么、必须遵守什么、拿到什么形状、有哪些坑 |
| 不做什么 | **不设计 UI、不规定视觉**。方案里关于 UI 的三处提法**全部是约束**，没有一处要求交付界面 |
| 现状 | **目前没有任何 UI 脚本消费这一层** —— 接口有、夹具在用、界面无 |
| 依据 | 下面的签名与形状**大部分是实测的**（探针 `tests/ideology/ui_surface_probe.gd` + 既有夹具日志），**推断的部分单独标出** |

---

## 1. 三条必须遵守的规则（来自方案，原文引用）

| # | 规则 | 原文 | 落地含义 |
|---|---|---|---|
| **I12** | explain 用它实际生效的基础 | 「explain 使用实际生效基础，**不用 UI 自行重做选择器**」 | **UI 不许自己实现一遍目标选择逻辑**。要「这些格为什么被覆盖」，调 `explain_ideology` / `explain_effect`，不要拿 selector 参数自己算 |
| **§7 角色** | UI 只读 | 「UI \| Facade／ViewModel \| **查询，不执行 selector，不修改派生状态**」 | UI **不写**派生层。任何 `install_*` / `apply_*` 都不是 UI 的接口 |
| **§377** | 分页不是语义 | 「**UI sampling 是输出分页，永远不参与选择器语义**」 | 「为了分页只算前 N 格」**不改变**哪些格被覆盖。别把分页参数传进选择器 |

**一句话**：UI 是**读者**，而且**只读已经算好的答案**。

---

## 2. 能调的接口（签名实测）

### 2.1 逐格读数 —— UI 最常用的一个

```gdscript
var r: Dictionary = ext.get_effective_stat_value(
    "economy.city.birth_factor",  # stat_key：String（不是 StringName）
    cell_index,                   # cell：地块索引
    0,                            # entity_handle
    base_value)                   # base_value：未加成前的原值
```

**返回 `Dictionary`，不是数字**（实测，`world_ext_modifier.cpp:779-827`）：

| 键 | 类型 | 含义 |
|---|---|---|
| `ok` | bool | 调用是否成功 |
| `reason` | String | 失败时：`modifier_runtime_unavailable` / `stat_unknown` |
| `stat_id` | int | 这个 stat 的内部 id |
| `value` | **double** | **生产用的最终值**（`effective_value(ECONOMY, stat_id, entity_handle, cell, base_value)`）|
| `derived_present` | bool | **这一格有没有派生层贡献** |
| `derived_add` | double | 派生层这一格的加数 —— **仅当 `derived_present`** |
| `derived_factor` | double | 派生层的乘数 —— 同上 |
| `derived_zero_factor_count` | int | 乘数里出现 0 的次数（诊断为 0 时原因为此）|
| `derived_contributors` | int | 这一格有多少条贡献 |
| `derived_source_country` | int | 贡献来自哪个国家 |

**这个返回形状对 UI 特别好用**：一次调用同时给你「最终值」和「其中理念贡献了多少」，正好够做「基础 4.2 → 4.25（+0.05 理念）」。

**`base_value` 必须传原值**：这一层是**加成平面**，不是绝对值的来源。`value` 是用你的 `base_value` 算出来的，**传 0 会得到一个只有加成的数** —— 那是调试点，不是显示值。

**`entity_handle`**：直接转交给 Modifier 运行时作为 entity。**地块级 stat 传 0**；国家/建筑级 stat 要传对应的 handle（当前没有 UI 消费方使用非 0 值，这一条**属推断**，用时先验）。

### 2.2 报表（全部零参数）

| 接口 | 返回 | 用途 |
|---|---|---|
| `get_derived_cell_layer_report()` | dict | **层的整体状态**：装没装、多少格、多少 stat、第几代、采样日 |
| `get_derived_materialize_report()` | dict | 上一次物化的计数器（`programs_seen` / `cells_visited` / `rows_emitted` 等）|
| `get_modifier_report()` | dict | Modifier 域状态（含派生层字段）|
| `get_ideology_report()` | dict | 理念运行时状态、计数器、`execution_contract_hash` |
| `get_effect_report()` | dict | Effect 域状态、事务、实例 |
| `get_cell_program_rollout()` | dict | 哪些 selector kind 走派生（实测 5 键：`ok` / `enabled_any` / `enabled_kinds` / `rollout` / `rollout_stage_removed`）|

### 2.3 explain —— 「为什么是这样」

| 接口 | 参数 | 用途 |
|---|---|---|
| `explain_ideology(country_handle, ideology_id)` | 2 | 单张卡的完整解释：立场门槛、支持度、为什么能/不能采纳 |
| `explain_ideologies(country_handle, ideology_ids)` | 2（第二个是**数组**）| 批量版 |
| `explain_effect(instance_id)` | 1 | Effect 实例的解释（含 `latched` 等）|

**`explain_ideology` 返回里 UI 常用到的键**（实测出处：`ideology_capacity_exceeded_test.gd`）：
`support_allowed` / `support_available` / `support_blocking_classes` / `stance_class_indices`，
以及卡片的 `locations` / `levels`。

### 2.4 选择器自检（**UI 一般不该用**）

```gdscript
query_effect_target_cells(source_cell, selector_kind, param0, param1)
query_country_anchor_cell(country_slot)
```

这两个**会执行选择器**。按 I12，UI 不该靠它们去重建「哪些格被覆盖」；它们存在的意义是**调试与对照**。你如果发现自己在 UI 里调它，多半是在重做已经被 explain 覆盖的东西。

---

## 3. 数据形状（实测）

### `get_derived_cell_layer_report()` —— 已装层时的真实返回

```json
{ "ok": true, "installed": true, "layer_generation": 1, "stat_count": 1,
  "cell_count": 400, "stat_ids": [6], "sample_day": 0, "epoch_id": 0 }
```

**字段怎么读**

| 键 | 含义 | UI 该怎么用 |
|---|---|---|
| `installed` | 这一层现在有没有装 | **先查它**。`false` 时其余计数都是 0，不是「没有效果」而是「还没层」 |
| `layer_generation` | 每次重装 +1 | **可以用作缓存失效的键**：它变了才需要重读逐格值 |
| `cell_count` | 覆盖了多少格 | 显示「影响 N 格」 |
| `stat_count` / `stat_ids` | 这层覆盖了几个 stat、它们的 id | `stat_ids` 是**内部 id**，UI 显示要用 `stat_key` |
| `sample_day` | 这一层采的是哪一天的数据 | **不是「今天」**，见下面的 §9.3 |
| `epoch_id` | **结构性为 0** | **不要拿它做身份**，恒为 0 |

### 没装层时的返回

```json
{ "ok": true, "installed": false, "layer_generation": 0, "stat_count": 0,
  "cell_count": 0, "stat_ids": [] }
```

### **未配置的运行时**

**每一个报表都只返回 `{ "ok": ..., "reason": ... }`**（实测：探针在未配置的 `DCWorldExt` 上调了 6 个报表，全部是这 2 个键）。

**这是 UI 最可能踩的第一个坑**：界面刚打开、世界还没配置完，你去读 `cell_count` 会拿到 `null`。**先判 `installed` 是否存在**。

---

## 4. 时间语义 —— UI 显示「已生效」前必须知道的两条

这两条**已经让至少三个夹具写出过错误结论**，所以单列。

### §9.3 资格日：结算日 D，最早 **D+1** 才发布

一张卡在第 D 天结算完成，**它的投影不会在 D 天出现在层里**，最早 **D+1**。

**UI 影响**：玩家刚装备完一张卡，界面上可能**当天看不到变化**。这不是 bug。 `sample_day` 会告诉你这一层是哪天的。

### §10.1 pending：转移在飞时，**旧值**仍然生效

一张卡正在升级（pending），层里显示的是**升级前**的值，**不是新值**。

**UI 影响**：想在界面上做「即将变成 X」的预览，**得自己标注这是预览**，不能直接把新值当当前值显示 —— 层里没有那个数。

---

## 5. 权威模式 —— 界面不必关心，但会看到差异

游戏可以让 **worker 线程**拥有「理念」域。此时主线程的日循环被抑制（`path = IDEOLOGY_WORKER`）。

**UI 侧要知道的**：

| 现象 | 原因 |
|---|---|
| `installed = false`、`cell_count = 0`，但卡片明明是激活的 | **worker 拥有理念域时，派生层目前完全不产生**（缺陷，见 §6）|
| 卡片状态读得到（`locations = [1]`）| 卡片状态走的是 worker → 主线程的镜像，**与派生层不是同一条通路** |

**换句话说**：worker 模式下**卡片对、层空**。

---

## 6. **已知缺陷：不要为它写 UI 兜底逻辑**

**worker 拥有理念域时，派生层一个格都不产生。**

- 已诊断到第一级断裂：**重建从未被 step**（`cell_layer_rebuild_visits` 增量 **0**，主线程腿是 **4**）
- 根因：`run_ideology_daily` 被抑制，而它是 `step_derived_rebuild` 的唯一生产调用方
- 修法已设计（对称于已经工作的实例刷新泵），**实现过但撞崩了一个夹具，已回滚**
- 详见 `artifacts/ideology-cell-layer/m5/M5-87-*.md` 与 `M5-88-*.md`

**给 UI 的建议**：**不要在界面上为这个缺陷加「为什么没效果」的兜底文案**。修好之后那段文案会变成错的。**要显示就显示 `installed` 这个事实本身。**

---

## 7. 缓存与刷新 —— 可以照抄的模式

```gdscript
var layer: Dictionary = ext.get_derived_cell_layer_report()
if not bool(layer.get("installed", false)):
    return  # 没有层：清空显示，不要显示 0 值

var generation: int = int(layer.get("layer_generation", 0))
if generation != _cached_generation:
    _cached_generation = generation
    _cached_values.clear()      # 只有换代才值得重读逐格值
    # ... 重读
```

**为什么按 `layer_generation`**：它是「层被重装过」的唯一信号。**`cell_count` 不变不代表值没变**（同一批格、不同的数），所以不要拿它做缓存键。

**不要按天刷**：`sample_day` 会因为 §9.3 落后一天，按它刷会漏。

---

## 8. 明确**不存在**的东西

| 你以为有 | 实际 |
|---|---|
| 「影响地块高亮」的现成接口 | **没有**。要显示就到 `get_derived_cell_layer_report()` 拿 `cell_count`，逐格用 `get_effective_stat_value` 自己算差异 |
| 层的「来源列表」查询（哪些卡贡献了这格）| **没有直接接口**。`explain_ideology` 是**按卡**解释，不是**按格**反查 |
| 层的 `world_identity` / `map_generation` | **结构性为 0**，不能做身份 |
| 分配计数 | **本构建没有任何分配计数接口** |

**这几条我查过才写**：`cell_program_layer` 的身份四元组（`epoch_id` / `world_identity` / `map_generation` / 早期的 `execution_contract_hash`）在结构上都是 0；最后那个现在已经是真值（`get_ideology_report().execution_contract_hash`），**但前三个仍是 0**。

---

## 9. 怎么在本地验证你在读的东西

```powershell
# 看一眼层的真实状态（世界要先配置）
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
& $exe --headless --path Project/project-keynes -s tests/ideology/ui_surface_probe.gd
```

`tests/ideology/ui_surface_probe.gd` 会把每个接口**实测**的键打印出来（它不断言任何值，只报形状）。**这份文档里的形状如果和它打印的不一致，以它为准** —— 它是活的，文档会腐烂。

**要看到「已装层」的真实形状**，需要跑一个真的配置了世界的夹具，例如：

```
tests/ideology/ideology_derived_copier_scale_test.gd     # 110 检查，会打印层状态
tests/ideology/ideology_capacity_exceeded_test.gd        # 147 检查，含 explain 的键
```

---

## 10. 这份文档的可靠性声明

| 部分 | 来源 |
|---|---|
| 三条规则 | **方案原文引用**（§244 / I12 / §377）|
| 所有签名 | **从 `world_ext_bind_methods.cpp` 的 `bind_method` 解析**，再用探针确认 `has_method` |
| `get_effective_stat_value` 的返回形状 | **读实现**（`world_ext_modifier.cpp:779-827`）。**我第一版把它写成 `float` 是错的** —— 它是 Dictionary，而且里面还带派生层的那一份。**验证过的错误，留在这里当警示** |
| `get_derived_cell_layer_report` 的形状 | **实测**（`b5d.log` 里一个已装层的世界）|
| `{ok, reason}` 未配置形状 | **实测**（探针）|
| `get_cell_program_rollout` 的 5 键 | **实测**（探针）|
| `explain_ideology` 的键 | **实测**（`ideology_capacity_exceeded_test.gd` 打印过）|
| §9.3 / §10.1 的时间语义 | **实测**（多个夹具的通过条件建立在这两条上）|
| **worker 模式下层的状态** | **实测**（M5-87 / M5-88）|
| 「不存在的东西」那一节 | **查过绑定与结构体字段**，不是印象 |
| **`entity_handle` 非 0 的用法** | **推断**（唯一实测的用法是 0）。**这一行是本文档里唯一标「推断」的实质结论** |

**我没有为这份文档新增任何测试**（除了那个探针）。它记录的是**已经存在且被别处验证过的东西**。
