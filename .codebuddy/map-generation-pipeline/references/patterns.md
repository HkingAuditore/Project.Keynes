# C++ Pass 代码范式（map-generation-pipeline）

本文件是 SKILL.md 的补充，写/改 `world_ext.cpp` 里生成期 pass 时参考。

## 1. buffer-encoder pass 范式

纯计算 pass（不读 slot、不要求 bind），输入经 knobs、输出经返回 Dictionary。
与 `encode_bake_*` / `run_bake_terrain_index_pass` / `run_bake_volcano_field_pass` 同构。

```cpp
godot::Dictionary DCWorldExt::run_bake_xxx_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;   // 按需
    using godot::String;

    Dictionary out;
    out["fallback"] = true;            // 初始 true，成功结尾才置 false
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;                    // 提前返回，caller 据 fallback 决定回退/报错
    };

    // ── 循环外：解析 knobs + 尺寸校验 ──
    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");
    // ...解析标量 / 取输入 PackedArray，校验尺寸...

    PackedFloat32Array out_buf;
    out_buf.resize(n);
    float * const __restrict DST = out_buf.ptrw();   // 裸指针 + __restrict

    auto t0 = std::chrono::high_resolution_clock::now();

    // ── 循环内：裸指针热循环，零 Variant / 零 Dictionary 访问 ──
    for (int i = 0; i < n; ++i) { /* ... */ }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["out_buf"] = out_buf;          // 结果数组
    out["width"] = w; out["height"] = h;
    return out;
}
```

GDScript wrapper：
```gdscript
if _world_ext == null or not _world_ext.has_method("run_bake_xxx_pass"):
    push_error("...缺失（DLL 未 rebuild?）...")   # 或回退旧路径，按任务要求
    return <empty>
var rep: Dictionary = _world_ext.run_bake_xxx_pass({...})
var ok: bool = rep != null and typeof(rep) == TYPE_DICTIONARY and not bool(rep.get("fallback", true))
var out = rep.get("out_buf", ...) if ok else <empty>
if not ok or out.size() != expected:
    push_error("...fallback（reason=%s）..." % String(rep.get("reason", "?")))
    return <empty>
return out
```

## 2. 读 bound slot 的 pass 范式（物理环流类）

需先 `bind_map_data`。从 slot 读 map 字段，knobs 只传 neighbor_indices / 标量 / 外部输入。

```cpp
if (!_bound) return fail("not _bound");
const int sid_terrain = component_id(godot::StringName("cell_terrain"));
const int sid_wind_x  = component_id(godot::StringName("cell_wind_x"));
if (sid_terrain < 0 || sid_wind_x < 0) return fail("missing slot id");
Slot &s_terr = _slots.write[sid_terrain];
if (s_terr.arr_u8.size() != n_cells) return fail("slot size mismatch");
const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
float * const __restrict WX = _slots.write[sid_wind_x].arr_f32.ptrw();
// ... 计算并写 slot；kernel 通常 published_to_slot=true 并 flush 回 map ...
```

常用 slot 名：`cell_pos_x/cell_pos_y`、`cell_terrain`、`cell_landform`、`cell_elevation`、
`cell_lat_norm`、`cell_wind_x/cell_wind_y/cell_wind_speed`、`cell_slp`、`cell_ocean_current_x/y`、
`cell_ocean_psi`、`cell_wind_stress_curl`、`cell_upwelling_strength`、`cell_temp`/`cell_temp_baseline`/
`cell_temp_30d`/`cell_temp_baseline_year`。water 判定用 `pk_is_water_terrain(t)`（= OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE）。

## 3. 融合 orchestrator 范式（step2/3/4）

C++ 内按序调用已验证子 pass，中间量在 C++ 串联，GDScript 一次请求。

```cpp
godot::Dictionary DCWorldExt::run_fused_pass(godot::Dictionary knobs) {
    Dictionary a = run_sub_pass_a(knobs);
    if (bool(a.get("fallback", true))) return fail("a_fallback");
    // 把 a 的输出注入 b 的输入（in-process，仅内存拷贝，非跨语言）
    knobs["chained_input"] = a.get("a_out", PackedFloat32Array());
    Dictionary b = run_sub_pass_b(knobs);
    if (bool(b.get("fallback", true))) return fail("b_fallback");
    // 若 b 写了 slot，从 slot 读出注入 c：
    //   PackedFloat32Array tmp; copy from _slots[sid].arr_f32; knobs["c_in"]=tmp;
    Dictionary c = run_sub_pass_c(knobs);
    // 合并 bundle + 各 stage 诊断 *_ms / *_ok
    out["fallback"] = false; /* ...merge... */ return out;
}
```

GDScript：构造一次 combined knobs（子 pass 输入并集，chained 键由 C++ 注入），调用后解包；
失败 → 回退旧逐 pass 路径（融合优先）。

实例参考（grep 定位）：
- `run_bake_geometry_fields_pass`（terrain→erosion→river→latitude→volcano）
- `run_physical_solve_pass`（SLP→wind→PSI→upwelling；wind 写 slot 后读出喂 PSI）
- `run_native_world_generate_full_pass`（base→post_base）

## 4. 并行化范式（性能优化）

per-pixel/per-cell 无跨元素依赖的循环用 `pk::parallel_for_range`（`#include "parallel_dispatcher.h"`）：

```cpp
#include "parallel_dispatcher.h"
// 把热循环按行切分；WorkerThreadPool 缺失时自动单线程 fallback，结果 bit-equal
pk::parallel_for_range("pk_bake_terrain", h, [&](int y0, int y1) {
    for (int y = y0; y < y1; ++y)
        for (int x = 0; x < w; ++x) { /* per-pixel，只写本像素，不跨行写 */ }
});
```

注意：有跨元素 reduce/emit（如 CSR 构建、flip list）的部分用 `parallel_for_range_with_emit`
或放到并行后的串行第二趟，保证顺序确定性。

## 常见坑

- **漏 bind**：新方法只声明实现没在 `world_ext_bind_methods.cpp` 绑定 → GDScript `has_method` 永远 false → 静默走 fallback、没提速。
- **knobs 键重名**：同一 Dictionary 键唯一（`height` 维度 vs `height_buffer` 缓冲）。
- **大文件编辑**：`world_ext.cpp` 很大，用 grep/search 定位精确替换，**绝不整文件重写**。
- **GDScript 三元 + or 优先级**：复杂条件拆成显式 `var ok: bool = ...` 再判断，别堆在一行三元里。
- **改 C++ 必 rebuild**：否则 `has_method` 探测不到新方法。交付时明确告知用户。
