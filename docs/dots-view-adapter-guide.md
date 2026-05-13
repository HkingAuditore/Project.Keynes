# Project.Keynes — DCViewAdapter 维护者手册（B2）

> 本文档是 UI / renderer / baker / debug 维护者的操作指南——告诉你 ViewAdapter 是什么、怎么用、怎么加新字段 getter、怎么 A/B 切换两个实现。
>
> 配套实现：[`scripts/data_core/view_adapter.gd`](../Project/project-keynes/scripts/data_core/view_adapter.gd) + [`tests/view_adapter_test.gd`](../Project/project-keynes/tests/view_adapter_test.gd)
>
> 配套阅读：[`dots-migration-roadmap.md §3 B2`](./dots-migration-roadmap.md)（设计动因）+ [`dots-component-schema.md`](./dots-component-schema.md)（schema 单一源——adapter 字段必须在 schema 里）。

---

## 1. ViewAdapter 是什么 / 解决什么问题

### 1.1 问题（B.1 接入前的状态）

UI / renderer / baker / debug 各处直接读 `cell.<field>`：

```gdscript
# data_overlay_baker.gd
"value": clampf(float(cell.temperature), 0.0, 1.0),
# main.gd info_panel
var temp: float = cell.temperature
# weather_layer.gd
if cell.weather_field_initialized: ...
```

每加一个新字段或更名旧字段，要 grep 全代码库找散落的 `cell.<field>` 直读。更糟糕的是，未来阶段 II 把 `cell.temperature` 退化为只读 facade（`func get_temperature() -> float: return _world.read_f32(...)`）时，所有这些直读路径都是潜在性能黑洞——每次 `cell.temperature` 都变成一次方法调用 + 跨界。

### 1.2 解法（B2）

引入读侧 facade `DCViewAdapter`，所有只读消费者通过 `adapter.get_<field>(cell.index)` 访问：

```gdscript
# data_overlay_baker.gd（B.1 改造后）
"value": clampf(adapter.get_temp(idx), 0.0, 1.0),
# main.gd info_panel（B.1 改造后）
var temp: float = ad.get_temp(idx) if ad != null else float(cell.temperature)
```

后续切换数据源（HexCell → DCWorld view_f32）只需把 `adapter` 实例从 `Cell` 换成 `World`——消费者一行不用动。

---

## 2. 双实现概览

| 类 | 数据源 | 性能特征 | 用途 |
|---|---|---|---|
| `DCViewAdapter.Cell` | 直读 `_cells[idx].<field>` | 与未引入 adapter 之前完全等价 | 阶段 I/II 默认；保证 bit-equal 兜底 |
| `DCViewAdapter.World` | 缓存 `world.view_f32(cid)` 引用 | hot path 索引零跨界，冷 path 与 .Cell 同档 | 阶段 II 数据所有权下移之后默认 |

### 2.1 选择路径

由 `ClimateProfile.use_world_view_adapter` 决定（默认 false）。判定逻辑（[`main.gd::_rebuild_view_adapter`](../Project/project-keynes/scripts/main.gd)）：

```
if cp.use_world_view_adapter and DCWorld bound and is_bound():
    → DCViewAdapter.World.new(world)
else:
    → DCViewAdapter.Cell.new(map.iter_cells())
```

不满足 World 前置条件时 **silently 退到 Cell** 并 push_warning 一次（不会 crash）。

### 2.2 在 debug menu / CLI 切换

切换 `ClimateProfile.use_world_view_adapter` 之后，调用 `_rebuild_view_adapter()` 重建实例。截图比对应像素级一致——这是 B.3 的核心验收。

---

## 3. 加新字段 getter SOP（30 分钟内完成）

> 假设要加 `cell.gdp`（F32，模块 economy）：

### Step 1 — 先把字段进 schema

按 [`dots-component-schema.md §3`](./dots-component-schema.md) 走完 5 步：

1. `DCComponentIds.CELL_GDP` 常量
2. `MapData.gdp_arr` PackedArray 字段 + alloc/rebuild 挂载
3. `CELL_SCHEMA` 加一行
4. 跑 codegen
5. rebuild gdext

### Step 2 — 在 ViewAdapter 加 getter 三个地方

```gdscript
# scripts/data_core/view_adapter.gd

# 2a. 抽象基类加默认实现（返回 0）
func get_gdp(_idx: int) -> float: return 0.0

# 2b. Cell 实现（直读 HexCell 强类型成员；如果 HexCell 没有同名成员就跳过 2b）
class Cell extends DCViewAdapter:
    func get_gdp(idx: int) -> float: return float(_cells[idx].gdp)

# 2c. World 实现（从 view_f32 拿）
class World extends DCViewAdapter:
    var _v_gdp: PackedFloat32Array = PackedFloat32Array()
    func setup() -> void:
        # ... 既有 ...
        _v_gdp = _resolve_f32(DCComponentIds.CELL_GDP)
    func get_gdp(idx: int) -> float: return _f(_v_gdp, idx)
```

### Step 3 — 调用方使用

```gdscript
# 任何 UI / baker
var gdp: float = adapter.get_gdp(cell.index)
# 永远不要走 cell.gdp 直读 —— 阶段 II 后 cell.gdp 会变成方法调用，性能黑洞
```

### Step 4 — 跑单测

把新 getter 加到 [`tests/view_adapter_test.gd`](../Project/project-keynes/tests/view_adapter_test.gd) 的 `_run` 循环里：

```gdscript
_expect_f("gdp", i, cell_adapter.get_gdp(i), world_adapter.get_gdp(i))
```

跑 `godot --headless --script tests/view_adapter_test.gd --quit`，确保 0 failures。

---

## 4. 反模式黑名单

| ❌ 反模式 | 后果 | 正确做法 |
|---|---|---|
| 在 hot path（每帧 / 每 cell）调 `adapter.get_<field>(idx)` | 每次走 facade 调用有开销，hot path 应直接拿 PackedArray | 循环外 `var arr := world.view_f32(world.component_id(...))`，循环内 `arr[idx]` |
| Cell adapter 用于 World 数据源（bind_map_data 后还构造 Cell） | UI 读旧 HexCell 数据，不是 SoA | flag flip 时调 `_rebuild_view_adapter()` |
| 加新字段时只改 Cell 实现忘了 World 实现 | World 实现 getter 永远返回 0，UI 显示空 | 单测必须覆盖两实现的 cross-impl 一致性 |
| Adapter 暴露非 schema 字段（如 `cell.passable_sea`、`cell.vegetation_vitality`）| 设计混乱：adapter 应只覆盖 SoA 化的字段 | 非 schema 字段（HexCell-only）继续 cell.* 直读，不进 adapter |
| 在 hot pass 里写 adapter（adapter 是只读的）| ViewAdapter 是只读 facade，写应走 `world.write_*` | 写路径走 DCWorld.write_* / DCWorldExt.write_*_range |
| 跨 regenerate 重用旧 adapter | 旧 adapter 持的 cell 数组引用已失效 | regenerate 末尾必须调 `_rebuild_view_adapter()` |

---

## 5. A/B 切换的物理保证（B.3 核心）

| 保证 | 实现 |
|---|---|
| Cell ↔ World 切换对 caller 透明 | 两个实现遵守同一份 abstract base 接口；caller 只调 `adapter.get_<field>(idx)` |
| World 不可用时安全退到 Cell | `_rebuild_view_adapter` 检查 `dc_world.is_bound()`；不满足时 silently fall back + warn |
| 切换后立即生效 | 切 flag → 调 `_rebuild_view_adapter` → 下一帧 UI / baker 自动用新实例 |
| Hot reload / 存档加载后不污染 | adapter 是 RefCounted，每次 generate 必新建；旧实例被 GC |

---

## 6. 当前接入清单（截至 2026-05-13 / Phase B.1 完成）

| 文件 | 接入路径 | schema-mirrored 读取数 |
|---|---|---|
| [`data_overlay_baker.gd`](../Project/project-keynes/scripts/rendering/data_overlay_baker.gd) | `_sample_cell` 接受 `adapter` 参数，从 `bake()` 传入 | 15 / 15 ✅ |
| [`main.gd`](../Project/project-keynes/scripts/main.gd) | `_view_adapter` 类成员，在 `generate` / `_rebuild_view_adapter` 时构造 | ~30 / 30 ✅ |
| `hex_renderer.gd` | 不读 schema 字段（纯 atlas/node 协调） | 0 / 0 ✅ |
| `weather_layer.gd` | 不读 schema 字段（粒子 / shader uniform 上传） | 0 / 0 ✅ |
| `debug_console.gd` | 不读 schema 字段（命令解析 / 切换 flag） | 0 / 0 ✅ |

> `hex_renderer / weather_layer / debug_console` 在 plan 估算时被列为 ~80 / 40 / 10 个 cell.* reads，实际 grep 显示这三个文件根本不直接读 cell schema 字段（它们走更高级的 atlas / shader uniform 接口）。这是好事——B.1 实质工作量比预期减少了 ~70%。

---

## 7. 调试 / 排错

### 7.1 切到 World 之后 UI 显示全 0

可能原因：
1. `_v_<field>` 没在 `setup()` 里 resolve（getter 返回 view 是空数组）
2. `cell.index` 是 -1（MapData 没跑 `_build_indices()`）
3. World 还没 `bind_map_data`（`is_bound() == false`，应自动退到 Cell）

排错：在 `_rebuild_view_adapter()` 末尾的 print 看 `kind=World` 还是 `kind=Cell`；World 实现的 `describe()` 会打 entity_count + component_count。

### 7.2 截图对比有微小差异

可能原因：
1. `WorldViewAdapter._f()` 越界返回 0，而 `CellViewAdapter` 读的是 HexCell 默认值（也是 0），但某些字段默认值非 0（如 `vegetation_vitality = 0.7`）
2. PackedArray COW detach 后 view 与 cell.<field> 短暂偏离（理论上不应发生，bind_map_data 后两侧应共享 buffer）

排错：跑 [`view_adapter_test.gd`](../Project/project-keynes/tests/view_adapter_test.gd)，逐字段比对找出是哪个 getter 返回不同。

---

**END of dots-view-adapter-guide.md.**
