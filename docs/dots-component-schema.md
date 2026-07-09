# Project.Keynes — DOTS Component Schema 单一源（A1）使用手册

> 本文档配套实现：
> - GDScript 单一源 → [`scripts/data_core/component_schema.gd`](../Project/project-keynes/scripts/data_core/component_schema.gd)
> - C++ 自动派生头 → [`gdext/src/component_bind_table.gen.h`](../gdext/src/component_bind_table.gen.h)（**autogen，禁止手改**）
> - codegen 脚本 → [`tools/codegen/gen_cpp_bind_table.py`](../tools/codegen/gen_cpp_bind_table.py)
> - GDScript 消费者 → [`scripts/data_core/world.gd`](../Project/project-keynes/scripts/data_core/world.gd) 的 `bind_map_data`
> - C++ 消费者 → [`gdext/src/world_ext.cpp`](../gdext/src/world_ext.cpp) 的 `bind_map_data` + `_debug_poke_f32_with_flush`
>
> 配套阅读：[`dots-migration-roadmap.md §3 A1`](./dots-migration-roadmap.md)（设计动因）+ [`performance-charter.md §11.2 / §12.4`](./performance-charter.md)（边界契约）+ [`DOTS review.md §P0-1`](./DOTS%20review.md)（架构债历史）。

---

## 1. 这是什么 / 为什么需要

### 1.1 问题（A1 改造前的状态）

加一个新的 cell-level 字段（如 `cell.soil_carbon`）需要改 **6 处**：

```
hex_cell.gd          : var soil_carbon: float
map_data.gd          : var soil_carbon_arr: PackedFloat32Array (×3 — alloc/rebuild/flush)
component_ids.gd     : const CELL_SOIL_CARBON: StringName = &"cell.soil_carbon"
world.gd             : _bind_register_and_attach(CELL_SOIL_CARBON, F32, false, map.soil_carbon_arr)  # 在 bind_map_data 38 行手写区域里
*_job.gd             : 在 _on_world_bound 缓存 _cid_soil_carbon
world_ext.cpp        : 在 BIND_TABLE[] 里加一行 {"cell_soil_carbon", "soil_carbon_arr", SlotDType::F32}
```

历史上这种"两侧手写表"已经造成过 **静默失同步 bug**，例如：

- `cell_snow_cover` ↔ `snow_cover_arr`：曾经 C++ 端写成 `snow_arr`（不是 `snow_cover_arr`），整个 component 静默 no-bind
- `cell_climate_dirty` ↔ `climate_dirty_mask`：C++ 端曾写 `climate_dirty_arr`，同样静默
- `cell_sea_ice_frac` ↔ `sea_ice_frac_arr`：曾经 C++ 端漏写 `_frac` 后缀

> 这些 bug 不是逻辑错——是"两份手写表偏离"的物理事实。来源 `gdext/src/world_ext.cpp` Phase 3a Step 2.0 注释（已替换）。

### 1.2 解法（A1）

把 GDScript 与 C++ 两侧的 BIND_TABLE 合并到 **一份单一源**：

- **写**：[`component_schema.gd`](../Project/project-keynes/scripts/data_core/component_schema.gd) 的 `CELL_SCHEMA` 数组（人手维护）
- **派生 1（GDScript）**：`world.gd::bind_map_data` 直接遍历 schema，零代码生成
- **派生 2（C++）**：`tools/codegen/gen_cpp_bind_table.py` 离线把 schema 解析成 `gdext/src/component_bind_table.gen.h`
- **消费**：`world_ext.cpp::bind_map_data` `#include "component_bind_table.gen.h"` 后用 `BIND_TABLE_AUTOGEN`

加新字段从 **6 处** 压缩到 **5 步**（schema 1 行 + MapData 1 字段 + codegen 1 命令 + rebuild + 完成）。

---

## 2. Schema 字段规范

每条 `CELL_SCHEMA` 项是一个 GDScript Dictionary：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | `StringName` | ✅ | GDScript-side 名（dot 形式，如 `&"cell.temp"`），等同 `DCComponentIds.CELL_*` |
| `cpp_name` | `String` | ✅ | C++-side 名（underscore 形式，如 `"cell_temp"`），等同 `world_ext.cpp` 内 slot 名 |
| `dtype` | `int` | ✅ | `F32` / `I32` / `U8`（DCComponentIds 枚举值，schema 里有别名） |
| `track_prev` | `bool` | ✅ | 是否分配 `_prev` 镜像（用于 `swap_double_buffer`） |
| `map_field` | `String` | ✅ | `MapData` 上对应的 `PackedArray` 属性名（如 `"temp_arr"`） |
| `prev_field` | `String` | 当 track_prev=true 必填 | `MapData` 上对应的 prev 字段名（如 `"temp_arr_prev"`），否则填 `""` |
| `owner` | `String` | ✅ | 业务模块归属（如 `"climate.pass_a"`），仅文档/lint 用 |
| `demo` | `bool` | optional | 标记为 demo-only，仅在 `ClimateProfile.demo_thermal_gradient_enabled=true` 时 attach |

### 2.1 命名约定（强约束）

- `name` 形如 `cell.<field_name>`（dot 命名，与 DCComponentIds 常量值匹配）
- `cpp_name` 形如 `cell_<field_name>`（underscore 命名，与 C++ pass 内 `component_id("cell_xxx")` 调用匹配）
- `map_field` 形如 `<field_name>_arr` 或 `cell_<field_name>_arr`（与 `MapData` 既有 38 个属性命名约定一致）

> 历史遗留：`name` / `cpp_name` 命名不同是 GDScript 与 C++ 双侧分别独立注册时形成的，本规范不强制统一（统一会破坏现有 C++ pass 调用）。Schema 同时承载两种命名解决偏移问题。

### 2.2 dtype 与 PackedArray 类型对应

| dtype | PackedArray | 典型字段 |
|---|---|---|
| `F32` | `PackedFloat32Array` | temperature / moisture / elevation / wind_x / ocean_current_y |
| `U8` | `PackedByteArray` | terrain / landform / vegetation / has_river (bool) / dirty_mask |
| `I32` | `PackedInt32Array` | （当前 schema 未使用——cell-level 没有 32-bit 整数；保留给未来 entity_id 等场景）|

---

## 3. 加新字段 SOP（5 分钟流程）

> 假设我们要加 `cell.soil_carbon`（F32，无双缓冲）：

### Step 1：在 `DCComponentIds` 加常量

```gdscript
# scripts/data_core/component_ids.gd
const CELL_SOIL_CARBON: StringName = &"cell.soil_carbon"
```

### Step 2：在 `MapData` 加同名 PackedArray + 在 `_alloc_soa` / `rebuild_soa_from_cells` 里挂

```gdscript
# scripts/geography/map_data.gd
var soil_carbon_arr: PackedFloat32Array = PackedFloat32Array()

func _alloc_soa(n: int) -> void:
    # ... 既有 ...
    soil_carbon_arr.resize(n)

func rebuild_soa_from_cells() -> void:
    # ... 既有 ...
    for i in range(n):
        var c: HexCell = _cell_array[i]
        # ... 既有字段镜像 ...
        soil_carbon_arr[i] = c.soil_carbon  # 假设 HexCell 上有这个字段
```

### Step 3：在 `CELL_SCHEMA` 末尾加一行

```gdscript
# scripts/data_core/component_schema.gd
const CELL_SCHEMA: Array = [
    # ... 既有 38 条 ...
    { name = &"cell.soil_carbon", cpp_name = "cell_soil_carbon",
      dtype = F32, track_prev = false,
      map_field = "soil_carbon_arr", prev_field = "",
      owner = "biology.soil" },
]
```

### Step 4：跑 codegen

```bash
python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py
# → [gen_cpp_bind_table] wrote 39 entries → gdext/src/component_bind_table.gen.h
```

把生成的 `gdext/src/component_bind_table.gen.h` **commit 到仓库**（其他没装 Python 的开发者也能直接 build）。

### Step 5：重 build GDExtension

```bash
cd Project.Keynes/gdext
scons platform=windows target=template_debug
```

完成。新字段在两端自动注册，C++ pass 可立刻 `component_id("cell_soil_carbon")`，GDScript 可立刻 `world.view_f32(world.component_id(&"cell.soil_carbon"))`。

> **真实示例（economy.resources）**：自然资源字段如 `cell.res_timber_reserve` / `cell.res_timber_extra_change` / `cell.res_iron_ore_reserve`（`F32`，`track_prev=false`，`owner="economy.resources"`）按本 SOP 加入。当前 28 种自然资源均遵循 reserve + extra_change 双字段约定。区别于上面的模板：这些字段在 `MapData` 是**纯运行期 SoA（无 HexCell 镜像）**，所以 `rebuild_soa_from_cells` 只在末尾把它们 `=0.0`（参照 `ocean_thermal_anomaly_arr`）；reserve 初值由 `MapGenerator._bootstrap_natural_resource_deposits` 在 `init_soa_from_bake` 之后写，extra_change 默认 0 并由自然资源 pass 消费后清零。每新增一种资源，除本 5 步外还要在 `ResourceProfileRegistry._PROFILE_PATHS` 登记对应 `.tres`（详见 computation-pipelines.md "Natural resources" 节）。

---

## 4. Codegen 脚本工作流

[`tools/codegen/gen_cpp_bind_table.py`](../tools/codegen/gen_cpp_bind_table.py) 是**无依赖**（Python 3.7+ 标准库）的离线脚本。

### 4.1 输入 / 输出

```
入：  Project/project-keynes/scripts/data_core/component_schema.gd
出：  gdext/src/component_bind_table.gen.h
```

### 4.2 验证项（runtime sanity）

脚本会在生成前做这些检查（任一失败 → exit 1，build 中断）：

1. 每条 entry 必须有 `name / cpp_name / dtype / map_field` 四个非空字段
2. `dtype` 必须是 `F32 / I32 / U8` 之一
3. `cpp_name` 跨条目必须唯一（避免 C++ 端 `component_id()` 命名冲突）
4. `map_field` 跨条目必须唯一（避免 `MapData.set(prop, arr)` 反复覆盖同一属性）

### 4.3 mtime 优化

脚本比对生成内容与磁盘上现有 `.gen.h`，**完全相同时不写文件**——SCons 不会触发整个 GDExtension rebuild。改 schema 但 codegen 输出无变化（如只调整注释）时不会拖慢 build。

### 4.4 CI 集成（推荐）

CI 应在 build 前先跑 codegen，并 fail-on-diff（确保任何人改了 schema 都同步 commit 了 .gen.h）：

```bash
python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py
git diff --exit-code Project.Keynes/gdext/src/component_bind_table.gen.h
```

---

## 5. 双侧消费者契约

### 5.1 GDScript 侧（`world.gd::bind_map_data`）

```gdscript
# 启动期 sanity check：让 schema 错误（typo / 缺字段 / dtype 非法）
# 在 bind 第一时间报出来。
if _debug:
    var schema_err: String = DCComponentSchema.validate_all()
    if schema_err != "":
        push_error("[DCWorld] bind_map_data: schema invalid — %s" % schema_err)
        return
for entry in DCComponentSchema.entries():
    var is_demo: bool = bool(entry.get("demo", false))
    if is_demo and not demo_thermal_gradient_enabled:
        continue
    # ... attach by dtype ...
```

### 5.2 C++ 侧（`world_ext.cpp::bind_map_data`）

```cpp
#include "component_bind_table.gen.h"  // pk::BIND_TABLE_AUTOGEN

namespace {
constexpr auto &BIND_TABLE      = BIND_TABLE_AUTOGEN;
constexpr int   BIND_TABLE_SIZE = BIND_TABLE_AUTOGEN_SIZE;
} // namespace

bool DCWorldExt::bind_map_data(Object *map_data) {
    // ... existing loop using BIND_TABLE / BIND_TABLE_SIZE ...
}
```

`BIND_TABLE` / `BIND_TABLE_SIZE` 是 legacy 名称，通过 `constexpr auto &` 引用到 autogen 表。所有原来的调用点（`bind_map_data` / `_debug_poke_f32_with_flush`）零修改。

---

## 6. 反模式黑名单

| ❌ 反模式 | 后果 | 正确做法 |
|---|---|---|
| 直接编辑 `component_bind_table.gen.h` | 下次 codegen 被覆盖 | 改 schema → 跑 codegen |
| GDScript 端用魔法字符串 `world.component_id(StringName("cell.temp"))` | 改名时一处遗漏 | 用 `DCComponentIds.CELL_TEMP` 常量 |
| C++ 端用魔法字符串 `component_id(StringName("cell_temp"))` | 同上 | 暂时仍是字符串（无 C++ 常量），但建议在 `world_ext.cpp` 内用 `static const StringName CELL_TEMP = "cell_temp";` 缓存 |
| 加新字段时跳过 schema 直接改 world.gd 手写 attach | bind_map_data 双源失同步 | bind_map_data 已无手写区域，schema 是唯一入口 |
| `cpp_name` 与 `name` 一致（如都是 `"cell.temp"`）| C++ 端 StringName 含 dot 字符可能导致 hash 表查询异常 | 严格守"GDScript dot / C++ underscore"约定 |
| 把 demo entry 没加 `demo = true` | demo_thermal_gradient_enabled=false 时也 attach，浪费 N×4 字节 | demo entry 必须显式打 `demo = true` |
| 改 dtype（F32 → I32）后没跑 codegen | C++ 端 `slot.arr_f32` vs GDScript 端 PackedInt32Array 类型不匹配，bind 时静默 push_warning | 任何 dtype 改动都必须 rerun codegen |

---

## 7. 验收：30 分钟挑战

> Phase A.5 验收标准（dots-migration-roadmap §4.3 I.7）：
>
> "让一个新加入的开发者按 dots-component-schema.md 加一个 dummy `cell.dummy` 字段，能在 30 分钟内跑通 GDScript bind + C++ pass 调用，无需问任何问题。"

执行步骤（自检：你应该能在 30 分钟内做完）：

1. 按 §3 SOP 加 `cell.dummy: F32, owner = "demo.dummy"`
2. 跑 `python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py`
3. 在 `world_ext.cpp` 加一个 stub pass：
   ```cpp
   void DCWorldExt::run_dummy_pass() {
       int sid = component_id(StringName("cell_dummy"));
       if (sid < 0) return;
       Slot &s = _slots.write[sid];
       float *p = s.arr_f32.ptrw();
       for (int i = 0; i < s.arr_f32.size(); ++i) p[i] = 1.0f;
   }
   ```
4. `_bind_methods` 里加 `ClassDB::bind_method(D_METHOD("run_dummy_pass"), &DCWorldExt::run_dummy_pass);`
5. `scons platform=windows target=template_debug`
6. 在 GDScript 里：
   ```gdscript
   var ext = ClassDB.instantiate("DCWorldExt")
   ext.bind_map_data(map)
   ext.run_dummy_pass()
   var snap = ext.snapshot_f32(ext.component_id(&"cell.dummy"))
   assert(snap[0] == 1.0)
   ```

完成。整段过程 0 处改 `world.gd` / 0 处改 `world_ext.cpp` 的 `BIND_TABLE`。

---

## 8. 维护守则

- 任何 PR 改 `component_schema.gd` 都必须 commit `component_bind_table.gen.h`（一份 PR 两份文件同时入库）
- CI 应跑 codegen + git diff --exit-code 防漂移
- 改字段命名（rename）的 PR 必须同步：schema entry / DCComponentIds 常量 / MapData 字段 / 所有调用方（grep `cell.<old_name>`）
- 永远不要在 `world.gd::bind_map_data` 重新引入手写 `_bind_register_and_attach` 调用——所有新字段一律走 schema

---

**END of dots-component-schema.md.**
