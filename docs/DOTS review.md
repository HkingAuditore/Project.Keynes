# Project.Keynes 彻底 DOTS 化 — 架构现状评估与缺口

> 🟢 **框架硬化已完成**（2026-05-13）：本文档列出的 P0–P2 七条架构债已通过
> dots-migration-roadmap §4 的 Phase A+B+C+D 四阶段落地（详见
> [`module-ownership-map.md`](./module-ownership-map.md) +
> [`dots-framework-status.md`](./dots-framework-status.md)）。本文档保留作"为什么
> 这么做"的历史决策记录；新加入开发者请直接读 dots-framework-status.md 入门。
>
> **本文档定位**：现状评估 + 缺口盘点（"为什么要做"）。
> **配套实施规划** → [`dots-migration-roadmap.md`](./dots-migration-roadmap.md)
> （5 阶段路线图 + 单模块 7 步 SOP + 第一刀建议，"具体怎么做"）。
> **onboarding 入口** → [`dots-framework-status.md`](./dots-framework-status.md)

## 一、当前架构的真实状态（实事求是）

### 1. DOTS 基础设施 — 已经搭起一个相当完整的 ECS 雏形

| 层 | 文件 | 状态 |
|---|---|---|
| Component registry | `scripts/data_core/world.gd` + `component_ids.gd` | ✅ 完整（dtype/stride/track_prev/external_ref） |
| Query DSL | `scripts/data_core/query.gd` | ✅ 完整（with_dirty_mask / with_archetype / with_index_list / in_pool / for_each_chunk） |
| Command Buffer | `scripts/data_core/command_buffer.gd` | ✅ 完整（CREATE / DESTROY / SET_ARCH / pool-aware） |
| Entity Pool + free-list | `world.gd` `create_pool / _pool_alloc / _pool_free` | ✅ 完整 |
| Double-buffer / sub-pass guard | `world.gd` `swap_double_buffer / commit_round / _pending_passes` | ✅ 完整 |
| C++ Mirror | `gdext/src/world_ext.{h,cpp}` (DCWorldExt) | ✅ 完整 + snapshot_f32/write_*_range/indexed + 3 个 demo pass + D-async |
| 调度器 (按 tick 切片) | `simulation/sus/sus_scheduler.gd` | ✅ 完整，已挂 5 个生产 Job |
| 调度器 (声明式 DAG) | `ecs/dc_ecs_scheduler.gd` | ✅ 完整，仅在 `demo_thermal_gradient` 路径使用 |

### 2. 但**真正"彻底 DOTS 化"的进度只完成了 30~40%**，原因是：

```
┌── HexCell (AoS)         ←─ UI / Baker / Info Panel / Debug 仍在这里读
│   .temperature
│   .moisture
│   .weather_*  (≥50 字段)
│
├── MapData SoA           ←─ Climate Pass-A 已 SoA 化，写入这里
│   .temp_arr / .moisture_arr / ... (35 个 PackedArray)
│
└── DCWorldExt._slots[]   ←─ C++ hot pass 写这里（被迫，因为 ABI 强制 detach）
    .arr_f32              ←─ snapshot_f32 → set(prop) → ↑ 回灌
```

**同一份 temperature 数据物理上存在 3~4 处副本**，靠 `rebuild_soa_from_cells` / `flush_soa_to_cells` / `snapshot_f32` 三个同步函数串起来。这是后续任何 DOTS 化工作的隐形税。

---

## 二、要彻底 DOTS 化，代码层面还缺这些东西（按优先级）

### 🔴 P0-1：缺少 **Component Schema 单一源（Single Source of Truth）**

**问题**：现在加一个新 cell-level 字段（比如 `cell.soil_carbon`）需要改 **6 处**：

```text
hex_cell.gd          : var soil_carbon: float
map_data.gd          : var soil_carbon_arr: PackedFloat32Array (×3 — alloc/rebuild/flush)
component_ids.gd     : const CELL_SOIL_CARBON: StringName = &"cell.soil_carbon"
world.gd             : _bind_register_and_attach(CELL_SOIL_CARBON, F32, false, map.soil_carbon_arr) (in bind_map_data)
*_job.gd             : 在 _on_world_bound 里缓存 _cid_soil_carbon = world.component_id(CELL_SOIL_CARBON)
world_ext.cpp        : (如果做 C++ hot pass) 重新发版才能拿到 slot id
```

`world.gd`（`bind_map_data` line 668~712）我数了一下，已经有 **38 个手写的 `_bind_register_and_attach(...)` 行**——这就是典型的 boilerplate 失控征兆。

**建议**：建立一个 `scripts/data_core/component_registry.gd`（一份资源/常量表），用一个 Array of dict 集中描述所有 component；再写一个 `_register_all_from_schema(map_data)` 替换 `bind_map_data` 里手写的那 38 行。HexCell 字段、MapData SoA 字段、bind 调用都从这一份表自动派生（脚本 codegen 或运行时反射均可）。

```gdscript
# 草案：cells schema 的 single source of truth
const CELL_SCHEMA: Array = [
    { name = &"cell.temp",      dtype = F32, track_prev = true,  owner = "climate.pass_a"   },
    { name = &"cell.moisture",  dtype = F32, track_prev = true,  owner = "climate.pass_b"   },
    { name = &"cell.has_river", dtype = U8,  track_prev = false, owner = "map_generation"   },
    ...
]
```

收益：新字段从 6 改成 1，能写 lint 工具检测"声明 owner=X 但实际有 Y 在写"。

---

### 🔴 P0-2：缺少 **数据所有权(authority)的最终归宿**

`docs/performance-charter.md §11~12` 已经写明 **Mode-B (Owned-by-C++)** 是契约目标，但代码现实是：

- `weather_system.gd` 仍然把 `_active_fronts: Array[WeatherFront]` 持有为 GDScript 对象池
- `map_generator.gd` 写到 `MapData.temp_arr`，C++ pass 调用前先 `ext.write_f32_range(cid_t, 0, map.temp_arr)` 推一份过去（main.gd L1380–1386 你能看到这种"防御性 push"）
- `flush_soa_to_cells` 每天还要把 SoA 倒回 HexCell

**等价的物理事实**：每个 hot tick 数据在 3 处往返一次（AoS → SoA → C++ slot → snapshot → AoS）。

**建议（去 AoS 的临门一脚）**：
1. **冻结 HexCell 写入**：所有 game logic 经 `world.write_*` 写 C++ slot。
2. **把 HexCell 改写成只读 facade**：`cell.temperature` 变成 `func get_temperature() -> float: return _world.read_f32(_cid_temp, _index)`，UI/Baker 一行不用改。
3. **删除 `flush_soa_to_cells`**：等所有读者都改成 read-from-world 后，这个每日 O(N) 同步函数可以整段砍掉。
4. **MapData 退化为"序列化容器 + topology + dirty mask"**：不再持有运行期权威数据，仅在 save/load 时与 World 交换。

---

### 🟠 P1-1：两套调度器并行 + 不互通

```
SusScheduler            (sus_scheduler.gd, 373 行)
  ↳ 按 tick budget 切片
  ↳ depends_on 是 StringName，不带 reads/writes 信息
  ↳ 5 个 production job 全挂这里

DCEcsScheduler          (dc_ecs_scheduler.gd, 157 行)
  ↳ reads/writes 声明 + Kahn 拓扑 + 环检测
  ↳ 但 *不支持* 切片/budget/policy
  ↳ 只在 demo_thermal_gradient 一处用
```

`dots-experiment-report.md §3.6` 已经实测 J=8 时 DCEcsScheduler 的开销只 +5%，技术上完全可量产。但你**永远不应该同时维护两套调度器**，等 production pass 数过 10 个就会变成一坨乱麻（看 main.gd 那一长串 fast-tick 顺序 + sus_tick_daily 的 register 顺序就能感觉到这个味道了）。

**建议**：把两者**合并成 `DCSystemScheduler`**：

| 维度 | 现 SUS | 现 DCEcs | 合并后 |
|---|---|---|---|
| 触发模型 | tick-based + policy | one-shot | tick-based + policy（保留） |
| 依赖描述 | depends_on (StringName) | reads/writes (comp_id) | **两者都接受**（depends_on 仍可用作业务硬序，reads/writes 用于自动校验/排序） |
| 切片预算 | frame_budget_ms + slice_budget_ms | 无 | 保留 |
| 自动 swap | 无 | 无 | **新增**：调度器自动 `world.swap_double_buffer(writes)` |
| starvation | 有 | 无 | 保留 |
| reads/writes 校验 | 无 | 无 | **新增**：debug 构建检测"声明 write A 但实际写了 B"等违约 |

这一步做完后，`scripts/main.gd` 那个 1000+ 行的 fast-tick 函数能压缩到几十行。

---

### 🟠 P1-2：缺少 **`DCSystem` 抽象**（System 概念缺位）

现在每个业务 pass 是这样的：

```gdscript
# refresh_climate_daily_job.gd 类继承 SusJob，run_slice() 里面手写 cursor / 双缓冲 / dirty 维护
# weather_refresh_job.gd 同上，stage_a / stage_b 是字段
# main.gd 里 _run_demo_thermal_gradient_pass_if_enabled() 直接调 ext.run_demo_complex_pass
```

每个 pass 有自己的"工程纪律"，没有共同基类强制契约。一旦人多就会乱。

**建议**：在 `data_core/` 下新增一个 `dc_system.gd`：

```gdscript
class_name DCSystem extends RefCounted

# 声明（_on_world_bound 时调一次）
func declare_reads() -> Array[StringName]: return []
func declare_writes() -> Array[StringName]: return []
func declare_pools() -> Array[StringName]: return []
func declare_archetypes() -> Array[StringName]: return []

# 运行
func setup(world: DCWorld) -> void: pass     # 解析 comp_id 缓存
func tick(ctx: SusTickContext) -> Dictionary: return {"done": true}
```

让 `RefreshClimateDailyJob` / `WeatherRefreshJob` / 未来的 `EconomySystem` / `AgentMovementSystem` 全部继承自它。

收益：（a) 调度器从 declare_writes 自动算 DAG；(b) hot loop 军规可以用 declare_* 元数据自动校验；(c) 给后续做 hot-reload / scriptable test harness 留接口。

---

### 🟠 P1-3：C++ 端 `_slots[].arr_f32` 还是"扁平 SoA"，没有 archetype/chunk 物理布局

A1 实验（dots-experiment-report §2）已经实测：**作为逻辑过滤器的 archetype 净收益 ≈ 0**。  
B0 实验（§B0）已经实测：**物理 chunk 重排相对自然顺序加速 0.31–0.73x**，但 **repack 占 70–89% 总耗时**——意味着只有 mask 准静态才有收益。

**当前项目恰好满足这个前提**（climate 路径的 LAND/OCEAN mask 在地图生成后就不再变）。

**建议（中期，不急）**：在 DCWorldExt 内部为每个 Pool 加一个可选的 `_chunk_remap` 表：

```cpp
struct Pool {
    StringName name;
    int start, capacity;
    Vector<int> free_list;
    // ↓ NEW: optional physical chunk remap (only built when sort enabled)
    bool         chunk_sorted = false;
    PackedInt32Array logical_to_physical;  // [entity_idx] -> phys_idx in chunked layout
    PackedInt32Array physical_to_logical;  // reverse
    Vector<int>      chunk_offsets;        // archetype A starts at phys_idx[k], ...
};
```

外加 `void DCWorldExt::sort_pool_by_archetype(int pool_id)` 一次性 API。Stencil 类 pass 内部加一个 `if (s.chunk_sorted) { run_chunked() } else { run_flat() }` 分支。

收益：**保留现有所有调用代码 0 改动**（snapshot_f32 / write_f32 等返回的"逻辑顺序"不变）；只有 archetype-aware pass 内部能透明拿到 chunk 加速。

不过这步**绝不要现在做**——A2-RealJobs 报告也明确说"先调度器后重排"。等真有 4ms/帧瓶颈再启动。

---

### 🟡 P2-1：缺少 **运行期纪律的自动校验**

`performance-charter.md §4 反模式黑名单` 里写了一堆 grep-only 的禁令（不能在 hot loop 调 `cell.get(...)` / `obj.set` / `push_back` 等），但目前**没有一个自动机制**能在 debug 构建里抓住违约。

**建议**：在 DCSystem 基类的 setup() 里植入 debug-only assertion：

```gdscript
# 在 hot pass 入口
if OS.is_debug_build():
    _world._debug_begin_pass(declare_writes(), declare_reads())
# pass body
if OS.is_debug_build():
    _world._debug_end_pass()   # 这里检查 entity_count 是否变、write_* 是否落在 declare_writes 内
```

加上一个 GDScript-side `DotsLint`（编辑器插件或 pre-commit hook）扫描 `*.gd` 找：
- hot 函数（命名以 `run_` / `_pass` / `_step` 结尾的）里 `cell.` 出现
- hot 函数里 `Dictionary.get(`、`push_back`、`.duplicate()`

---

### 🟡 P2-2：渲染端和 UI 端**完全没 DOTS 化**

- `info_panel`、`debug_console`、`map_baker`、`data_overlay_baker`、`hex_renderer` 几乎全部是 `for c in map.all_cells(): c.temperature` 风格
- `cell.weather_field_initialized` / `cell.weather_intensity` 这种字段在 weather_layer.gd 被频繁访问
- 这是 `flush_soa_to_cells` 之所以还存在的唯一理由

**建议**：渲染 / UI 接入"读侧 snapshot 视图"：

```gdscript
# 一次取，常驻
var _temp_view: PackedFloat32Array = world.view_f32(cid_temp)

# 每帧（或事件触发）只刷新 dirty 的 UI 部分：
func on_day_changed():
    if _selected_index >= 0:
        _temp_label.text = "%.2f" % _temp_view[_selected_index]
```

Renderer/baker 也一样——这一步做完后 flush_soa_to_cells 可整段砍掉，每天省一次 O(N) 拷贝（虽然量不大但是是干净代码的标志）。

---

### 🟡 P2-3：保存/加载、热重载、测试夹具都还没 DOTS 化的入口

- 当前 save 隐式假设 HexCell 是权威（虽然你还没接 save 系统，但代码已经在 hex_cell.gd 注释里暗示了 `current_state: Dictionary` 是给序列化用的）
- 没有 `DCWorld.serialize() / deserialize()` API

**建议**：在 `data_core/world.gd` 加 `func serialize() -> Dictionary` + `func deserialize(d)`。所有用 schema 注册的 component 自动 round-trip（用 `cell.demo.*` 命名空间过滤 demo 字段，正好对应 `component_ids.gd` L86-90 你已经标注的纪律）。

---

## 三、建议的执行顺序（一份"DOTS 化路线图"骨架）

```
┌─ 阶段 I：消除架构债（不优化性能，只让代码自洽） ─────────────
│  I.1  建立 ComponentSchema 单一源，自动派生 bind_map_data
│  I.2  抽出 DCSystem 基类，把 RefreshClimateDailyJob / WeatherRefreshJob 改写
│  I.3  合并 SusScheduler + DCEcsScheduler → DCSystemScheduler
│  I.4  Debug-build 自动校验 reads/writes 违约 + hot-loop 军规 lint
├─ 阶段 II：数据所有权下移到 DCWorld(Ext) ──────────────────
│  II.1 把所有 GDScript 写路径改成 world.write_*；hot pass 内部禁止 cell.x = y
│  II.2 把渲染 / UI / Baker / info panel 全部改读 world.view_* 或 snapshot
│  II.3 删除 flush_soa_to_cells；MapData 退化成 IO facade
│  II.4 HexCell 改为只读 facade，property → world.read_*
├─ 阶段 III：序列化/测试基建 ───────────────────────────────
│  III.1 DCWorld.serialize / deserialize（按 schema 自动遍历）
│  III.2 标准化 bench 模板（dots-experiment-report §5 已暗示）
├─ 阶段 IV（条件触发，不要主动启动）：物理优化 ────────────────
│  IV.1 D-async 接入 production climate Pass-A（已有沙盒）
│  IV.2 DCWorldExt 加 _chunk_remap，stencil pass 透明走 chunked
│  IV.3 SIMD（仅当达到 charter §3.1 全部触发条件时）
└─────────────────────────────────────────────────────────
```

阶段 I 是**净收益**（代码量减少、入门门槛降低、bug 概率下降），不打扰任何运行期数值；  
阶段 II 是**关键转折**，做完之后才能说"项目彻底 DOTS 化"；  
阶段 III 是**工程化**，跟性能无关但是项目长寿的标志；  
阶段 IV **不要主动启动**——`dots-experiment-report` 三份实验已经反复证明"过早优化是错的"，等真出现瓶颈再启动。

---

## 四、对你之前工作的一点平心而论的评价

代码里能清晰看到 DOTS 化是被"逐 milestone 增量推进"的（component_ids.gd 上的 B-full Step-2 / Phase 3a Step 2.1.a 等注释，main.gd 里 F8/F9/F10/F11/F12 调试键的 A/B 验证机制），思路非常对。`docs/dots-experiment-report.md` 这种"先在 tmp/ 里把假设证伪/证实再决定要不要做"的工程纪律是好的。

但目前的"DOTS 化"集中在**数据移到 SoA + 部分 hot pass 移到 C++**这两件事上，缺一个**让"加一个新 system"变得机械、可重复、不易错**的统一抽象层（就是上面 P0/P1 几条）。否则项目越大越难维护，3 个 system 还能手写，10 个就会失控。

如果你认同这条路线、想立刻开始动手，我建议先做 **P0-1 (Component Schema 单一源)** 一件事就好：它最不侵入运行期，做完之后你能用客观指标看到代码 boilerplate 缩减 ~60% 以上，给后续每一步都铺平了路。