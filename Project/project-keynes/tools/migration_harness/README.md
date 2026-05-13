# Migration Harness — 单模块 DOTS 迁移 SOP

> 本目录是 dots-migration-roadmap §3 B3（MigrationHarness）的物理产物。
> 任何模块（economy / unit / AI / pollution / 旧 climate sub-pass …）做 DOTS 化都按本目录的 7 步 SOP + 4 个模板走。
>
> 详细背景：[`docs/dots-migration-roadmap.md §5`](../../../../docs/dots-migration-roadmap.md#5-单模块-dots-迁移-sop7-步检查清单)（设计哲学）+ [`docs/performance-charter.md §12`](../../../../docs/performance-charter.md)（性能契约）。

---

## 文件清单

| 文件 | 用途 | 何时复制 |
|---|---|---|
| `template_bench.gd` | 单 pass 微基准 + bit-equal 对照（拷自 [`tmp/bench_temp_drift.gd`](../../tmp/bench_temp_drift.gd)）| Step 5 验收前 |
| `template_module_test.gd` | 30-tick 双路径回归（feature_flag on/off 对照）| Step 5 验收前 |
| `template_overlay.gd` | 接 Data Overlay 调试通道的 9 步检查清单（纯文档）| Step 7（仅当模块有 overlay）|
| `README.md` | 本文件——7 步 SOP 概览 |  入门必读 |

---

## 7 步 SOP（dots-migration-roadmap §5 镜像）

> **时间盒**：Step 1-5 应在 2-3 个工作日内走完。超时说明你陷入业务逻辑细节而不是模板套用——先停下来重读 dots-migration-roadmap §2.1。

### Step 1 — 写 `module_manifest.tres`

在你的模块根目录（如 `scripts/simulation/economy/`）创建一份资源：

```gdscript
# 在 Godot editor: New Resource → DCModuleManifest
# 然后填写：
@export var module_id: StringName = &"economy"
@export var feature_flag: StringName = &"use_dots_economy"
@export var reads: Array[StringName] = [&"cell.population", &"cell.tax_base"]
@export var writes: Array[StringName] = [&"cell.gdp", &"cell.unemployment"]
@export var pools: Array[StringName] = [&"cells"]
@export var dispatch_paths: PackedStringArray = ["legacy", "dots_gdscript"]
@export var owner: String = "economy.team"
```

> **没声明的 component 一概不许碰**。DCSystemScheduler debug 构建会校验。

### Step 2 — 在 `DCComponentSchema.CELL_SCHEMA` 加新字段（如有）

```gdscript
# scripts/data_core/component_schema.gd
const CELL_SCHEMA: Array = [
    # ... 既有 38 条 ...
    { name = &"cell.gdp",          cpp_name = "cell_gdp",
      dtype = F32, track_prev = true,
      map_field = "gdp_arr", prev_field = "gdp_arr_prev",
      owner = "economy" },
    { name = &"cell.unemployment", cpp_name = "cell_unemployment",
      dtype = F32, track_prev = false,
      map_field = "unemployment_arr", prev_field = "",
      owner = "economy" },
]
```

跑 codegen：

```bash
python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py
```

一处改动自动派生 GDScript `bind_map_data` + C++ `BIND_TABLE` 头文件。

> 在 `MapData` 上同步加同名 `<name>_arr` 字段并在 `_alloc_soa` / `rebuild_soa_from_cells` / `flush_soa_to_cells` 里挂入。

### Step 3 — 写新 `DCSystem` 子类（GDScript，先用 dots_gdscript 路径）

```gdscript
# scripts/simulation/economy/economy_system.gd
class_name EconomySystem extends DCSystem

func declare_reads() -> Array[StringName]:
    return [&"cell.population", &"cell.tax_base"]
func declare_writes() -> Array[StringName]:
    return [&"cell.gdp", &"cell.unemployment"]
func declare_pools() -> Array[StringName]: return [&"cells"]
func feature_flag() -> StringName: return &"use_dots_economy"

func tick(ctx) -> Dictionary:
    var pop := _world.view_f32(_cid_population)
    var gdp := _world.view_f32(_cid_gdp)
    # 算法主体——只能读 declare_reads / 写 declare_writes 内的 component
    return {"done": true}
```

> 不准触碰 manifest 之外的 component——manifest 是契约，违约 debug 报错。

### Step 4 — 接入 `DCFeatureFlags`

```gdscript
# scripts/data_core/feature_flags.gd
const FLAGS: Array = [
    # ... 既有 ...
    {
        name = &"use_dots_economy",
        owner = "economy.team",
        default = false,
        resource = "ClimateProfile",
        description = "经济模块走 DCSystemScheduler；false 时回退到 legacy",
        pending = true,  # 还没在 ClimateProfile 加 @export 字段时打 pending
    },
]
```

调用点（main.gd / bootstrap）：

```gdscript
if DCFeatureFlags.is_on(&"use_dots_economy", cp):
    scheduler.register_system(EconomySystem.new())
else:
    scheduler.register_job(EconomyLegacyJob.new())
```

> 单点 toggle，A/B 切换一行代码；A/B 共存便于回归对照。

### Step 5 — 跑 bench 验收

复制 `template_bench.gd` 到 `tmp/bench_economy.gd`，按 `⚙️ MODULE-CUSTOM` 注释改 8 处：

```bash
# Editor 内 File → Run；headless 改 extends SceneTree + func _init() 入口
godot --editor --script tmp/bench_economy.gd
```

通过标准（与 [`docs/performance-charter.md §6.2`](../../../../docs/performance-charter.md) 对齐）：

| 指标 | 红线 |
|---|---|
| bit-equal: legacy vs dots_gdscript | 容差按 §12.5 政策选定（金额/比率类 < 1e-6；计数 / 离散 = 0） |
| micro-bench: 单 tick µs | dots_gdscript 不慢于 legacy × 1.2 |
| 30-tick SUS 日志（用 template_module_test.gd） | avg / p95 / 各字段均值 ±5% |
| 截图（如有 overlay）| 像素 diff < 0.1% |

### Step 6 —（仅当 Step 5 显示 ≥ 5 ms 且 N ≥ 1k）→ C++ 化

按 [`performance-charter.md §12.4`](../../../../docs/performance-charter.md#124-用模板做下一个-pass--7-步操作清单) 的 7 步走。在 `module_manifest.tres` 的 `dispatch_paths` 加 `"dots_cpp"`。重跑 Step 5 bench；C++ ≥ GDScript 5× 才合入（charter 铁律 3）。

### Step 7 —（仅当模块需要 UI / overlay 消费）接入 ViewAdapter / Overlay

在 `DCViewAdapter.World.setup()` 里把新字段缓存：

```gdscript
# scripts/data_core/view_adapter.gd → World class
var _v_gdp: PackedFloat32Array = PackedFloat32Array()
func setup() -> void:
    # ... 既有 ...
    _v_gdp = _resolve_f32(DCComponentIds.CELL_GDP)
func get_gdp(idx: int) -> float: return _f(_v_gdp, idx)
```

如果需要 demo overlay，按 `template_overlay.gd` 的 9 步清单接入。

UI / renderer / baker 通过 adapter 读 → 模块 dispatch_path 切换对它们透明。

---

## 互不影响的物理保证

| 隔离手段 | 保证 |
|---|---|
| Module Manifest 声明 reads/writes | 调度器 debug 校验：模块 A 不能写模块 B 的 component |
| FeatureFlagRegistry 单 flag toggle | 模块 A 走 dots_cpp、模块 B 仍 legacy → 零耦合 |
| ViewAdapter 读侧隔离 | renderer/UI 一行不动地从 cell.* 切到 view_f32 |
| ComponentSchema owner 字段 | 后续 dots_lint 自动检测"声明 owner=X 但实际有 Y 在写"→ 跨模块写入报警 |
| 命名空间约定 | `cell.<field>` / `front.<field>` / `<module>.<field>` 不互相污染 |

---

## 进度追踪

完成迁移后请在 [`docs/dots-migration-roadmap.md §9 已迁移模块清单`](../../../../docs/dots-migration-roadmap.md#9-已迁移模块清单) 追加一行：

```markdown
| 模块名 | 状态 | dispatch_path | 完成日 | commit | 备注 |
|---|---|---|---|---|---|
| economy | dots_gdscript | dots_gdscript | 2026-XX-XX | abc1234 | 首期不上 C++（N=2400 无瓶颈）|
```
