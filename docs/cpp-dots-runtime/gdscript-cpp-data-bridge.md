# GDScript / C++ Data Bridge

本文记录 GDScript、DataCore、C++ GDExtension 之间的数据传递契约。性能问题里大量“明明设计上应该走 C++，日志却显示 `path=gdscript`”或“C++ 已经算完但画面/后续 pass 没变”的原因，都来自这里的同步边界。

## 参与者

| 角色 | 文件 | 职责 |
| --- | --- | --- |
| `MapData` | `Project/project-keynes/scripts/geography/map_data.gd` | 地图级 SoA 镜像，保存 terrain/temp/moisture/ocean/weather 等 PackedArray。 |
| `DCWorld` | `Project/project-keynes/scripts/data_core/world.gd` | GDScript DataCore world，绑定 `MapData`，提供 `write_*`、dirty mask、view API。 |
| `DCWorldExt` | `gdext/src/world_ext.cpp` | C++ DataCore world，保存 C++ slot/SoA，执行 native pass。 |
| schema | `component_schema.gd` | component 单一源，声明 GDScript name、C++ name、dtype、map_field、owner。 |
| C++ bind table | `component_bind_table.gen.h` | schema 的 C++ mirror，供 `DCWorldExt.bind_map_data()` 使用。 |
| `HexCell` facade | `Project/project-keynes/scripts/geography/hex_cell.gd` | 兼容 `cell.temperature = v` 等旧写法，底层转成 `world.write_f32()`。 |

## Schema 绑定契约

`component_schema.gd` 是 DataCore component 的单一源。每条 schema 记录至少包含：

- `name`：GDScript 侧 dot name，例如 `cell.temp`。
- `cpp_name`：C++ 侧 underscore name，例如 `cell_temp`。
- `dtype`：`F32` / `I32` / `U8`。
- `map_field`：`MapData` 上的 PackedArray 字段名。
- `owner`：该字段主要由哪个机制写入。

`DCWorld.bind_map_data()` 直接读 schema 并把 `MapData` 字段挂到 GDScript slot。`DCWorldExt.bind_map_data()` 读 `component_bind_table.gen.h`，注册 C++ slot 并绑定对应 `MapData` 字段。

约束：

- 改 schema 后必须同步更新 C++ generated bind table。
- C++ pass 内 `component_id("cell_temp")` 使用的是 `cpp_name`，不是 GDScript dot name。
- `map_field` 拼错会导致 bind 静默偏离或 slot size 为 0，后续 C++ pass 可能 fallback。
- dtype 不一致会让 `arr_f32` / `arr_i32` / `arr_u8` 访问错槽，必须在 bind 阶段报错处理。

## PackedArray CoW 公理

Godot `PackedFloat32Array` / `PackedInt32Array` / `PackedByteArray` 是 Copy-on-Write。当前架构不依赖双向可变零拷贝。

必须按以下事实开发：

- `bind_map_data()` 初始可以让两侧看到同一份 backing。
- C++ 一旦对 PackedArray 调 `ptrw()` 写入，可能 detach，C++ 侧持有自己的 buffer。
- GDScript 修改 `map.temp_arr[i]` 不保证 C++ slot 看到。
- GDScript 修改 `world.view_f32(cid)[i]` 不会写回 world。
- C++ 写 slot 不保证 GDScript 读者看到。
- 两侧同步必须走显式 API。

因此，“C++ 算过”与“GDScript/渲染读到新值”是两个事件，中间必须有 publish/flush/snapshot。

## GDScript 写入 C++ 可见数据

### 单点写

`DCWorld.write_f32(comp_id, idx, v)` / `write_i32` / `write_u8`

用途：

- 兼容 `HexCell` facade setter。
- 少量实体或 debug 写入。

副作用：

- 写入 GDScript slot。
- 标记 dirty mask 单点。

风险：

- 在 N=2400 或更大全图 hot-loop 内逐 cell 调用会产生 `_dirty_mark_one` 风暴。
- 全图或大批量更新应改用 indexed/dense API。

### 连续区间写

`write_f32_range(comp_id, start, src)` / `write_i32_range` / `write_u8_range`

用途：

- 把一整段 PackedArray 推入 `DCWorld`。
- 常见于 weather field solver 或初始化同步。

副作用：

- 标记 `[start, start + n)` dirty range。

适用条件：

- 输入天然连续。
- 变化范围本身就是整段，不需要 value-diff 降低 dirty。

### 稀疏索引写

`write_f32_indexed(comp_id, indices, values)` / `write_i32_indexed` / `write_u8_indexed`

用途：

- hot pass 在 GDScript fallback 中收集 dirty indices 后一次性提交。
- weather distribute、feedback、Pass-B、sea ice 等稀疏更新。

特性：

- 对每个 index 做 value-diff：只有值变化才写入并标 dirty。
- 越界 index 静默跳过，避免批量场景刷屏。

建议：

- hot loop 中先收集 `PackedInt32Array indices` 和 values。
- 循环结束一次 `write_*_indexed`。

### Dense 写

`write_f32_dense(comp_id, values)` / `write_i32_dense` / `write_u8_dense`

用途：

- 整个 component 全量替换。
- C++ snapshot 或 GDScript pass 已经有完整输出 buffer。

特性：

- value-diff 后标 dirty，避免“全图值几乎没变但 atlas 全脏”。

风险：

- 如果每 tick 都 dense 写大量字段，即使 value-diff 已优化，仍会有遍历成本。

## Cell-index 间接寻址 LUT 是渲染产物，不进 schema

plan: *cell-index atlas indirection*（详见 computation-pipelines.md「Cell-index 间接寻址」节）。

- `cell_index_tex` / `enum_lut_tex` / `dyn_lut_tex` / `eco_lut_tex` 是
  **渲染层产物（`WorldData` 上的 `ImageTexture`）**，不是 DataCore slot：
  **schema / `component_bind_table.gen.h` 无需改动**。
- **编码权威路径是 C++（DCWorldExt）**，GDScript 仅做薄壳 + fallback（2026-06-16，用户
  决策"严格按 skill，哪怕只有 2400 个 cell 也在 CPP 做"）：
  - `encode_cell_luts(opts) → Dictionary{enum_lut/dyn_lut/eco_lut: PackedByteArray,
    path, elapsed_ms, fallback, published_to_slot=false}`：C++ 读 8 个 SoA slot
    （`cell_temp/cell_moisture/cell_snow_cover/cell_vegetation_vitality/cell_sea_ice_frac/
    cell_terrain/cell_vegetation/cell_cover`，全部已在 schema），输出 3 张 LUT 的
    `PackedByteArray`；GDScript 只负责 `Image.create_from_data` + `ImageTexture.update`。
  - `encode_cell_index_tex(opts) → Dictionary{index_tex: PackedByteArray, path, fallback}`：
    C++ 反射读 `world.cell_first_px_arr/cell_px_count_arr/flat_px_indices_arr`（CSR）→ RG8 buffer。
  - LUT/index 不写 slot（`published_to_slot=false`）——它们是 GPU 纹理，不是 DataCore 数据，
    无 `flush`/`snapshot` 需求；C++ 直接把字节缓冲塞进返回 Dict，GDScript 端零额外 marshalling 拷贝
    （CoW 引用传递）。
  - eco `transition_age` 的 per-cell prev 状态由 C++ 端 `AtlasPipelineState::lut_prev_veg/
    lut_prev_vit/lut_transition_age` 持久维护（`invalidate_atlas_csr_cache` 同步失效），
    **不经 GDScript 来回传**——`map_baker` 不再持有该状态。
- 量化公式与 fan-out 编码器同源（C++ `pk_atlas_sig_dynamic` / `pk_atlas_sig_ecology`，
  GDScript fallback `_dynamic_cell_signature` / `_ecology_visual_signature`），保证 LUT 与旧
  per-pixel atlas **bit-equivalent**。
- fan-out 方向反转：旧 `n_cells → n_pix` 直写 atlas_buffer（每日数 MB）改为
  `n_cells → n_cells` LUT（~7KB）；`cell_index_tex` 静态，不进 DataCore、不参与每日 sync。
- flag 关时本路径零触达，CoW 公理 / `published_to_slot` / `flush` / `snapshot`
  语义均不受影响。

## C++ 读取 GDScript 最新值

`DCWorldExt.refresh_slots_from_map()`

含义：

- 从当前 `MapData` / GDScript 侧镜像拉取数据到 C++ slot。
- 让 C++ pass 看到 GDScript 自上次同步后的写入。

使用规则：

- 一轮 native chain 开始前调用一次通常足够。
- 多个 stage 共享同一轮输入时，不要每个 stage 都重复调用。
- 如果前一个 GDScript fallback 写了 `MapData` / `DCWorld`，下一个 C++ pass 依赖这些字段，则必须 refresh。
- 如果前一个 C++ pass 已直接写 slot，并且下一个 C++ pass 读同一 slot，通常不需要 refresh。

常见优化：

- `MapGenerator` 内有“round 启动时 refresh 一次”的缓存语义，用来避免每个 stage helper 都做一次 `refresh_slots_from_map()`。
- 日志里 `sync=...` 或 `refresh=...` 变大时，先检查是否重复 refresh。

## C++ 写入 GDScript 可见数据

### Slot 写入

C++ pass 的理想输出方式：

1. 循环外解析 `sid = component_id("cell_xxx")`。
2. 获取 `Slot &s = _slots.write[sid]`。
3. 用 `ptrw()` 取得裸指针。
4. hot loop 写入 slot。
5. 结束后按需要 flush/publish。

slot 写入本身只保证 C++ 后续 pass 可见。

### Flush 到 MapData

`flush_slots_to_map()` 或内部 `_flush_slot_to_map(sid)`

含义：

- 把 C++ slot 写回绑定的 `MapData` 字段。
- GDScript 读 `map.xxx_arr` 才能看到 C++ 输出。

适用：

- pass 输出要被渲染、debug、GDScript fallback 或后续 GDScript stage 读取。
- SLP/PSI 等 C++ pass 返回 `published_to_slot=true` 并在 C++ 内 flush 对应 slot 时，GDScript caller 可以跳过重复拷贝。
- 生成期 `run_native_world_generate_base_pass` 是无 bind 的结果包 API：GDScript 传入 cfg/profile，C++ 直接返回 q/r/s、elevation、moisture/base_moisture、terrain/is_water、temp/temp_baseline/temp_30d/temp_365d、lat/temp_year、landform/vegetation/cover 等 PackedArrays。它不写 slot，返回 `published_to_slot=false`；调用方只做数组尺寸校验。
- 生成期 `run_native_world_generate_post_base_pass` 同样是无 bind 的结果包 API：GDScript 把 base 结果包原样传入，C++ 在 SoA 内完成 lake BFS、rain shadow、river flow、river ecology、vegetation feedback、shrubland/mangrove/glacier/swamp、volcano、delta/oasis/salt flat/badlands、reef/kelp/pelagic bloom，并返回最终 terrain/base terrain、landform/base landform、vegetation/base vegetation、cover、is_water、has_river、has_volcano 等 PackedArrays。它也不写 slot，返回 `published_to_slot=false`；调用方只装配 `MapData`/`HexCell`，失败时才在 C++ base 结果上跑 GDScript post-base fallback。
- 生成期 `run_native_world_generate_pass` / `run_native_generation_slice` 仍采用 bind 后 publish 路径：C++ 读取 bind 后的 `cell_lat_norm` / `cell_elevation` / `cell_terrain` 等 slot，发布 `cell_temp*`、`cell_temp_baseline_year`、`cell_thermal_energy`、`cell_ema_initialized`、`cell_is_water` 等初始仿真 slot，并 `_flush_slot_to_map` 回 `MapData`。GDScript wrapper 成功后必须重绑 `DCWorld.rebind_map_data(map, demo_flag)`，因为 C++ flush 可能 reseat `MapData.xxx_arr`，旧的 GDScript `DCWorld` slot 引用不会自动跟随。
- 生成期 `run_temp_baseline_year_bake`（cell_temp_baseline_year 权威烘焙）即采用此路径：以 `lat_norm` knob 入参，C++ 写 `cell_temp_baseline_year` slot 后 `_flush_slot_to_map` 回 `MapData.temp_baseline_year_arr`，返回 `published_to_slot=true`；ext 不可用时 GDScript `bake_lat_temp_year_lut` 兜底（详见 computation-pipelines.md "Temp baseline year bake"）。

### Snapshot

`snapshot_f32(comp_id)` / `snapshot_i32` / `snapshot_u8`

含义：

- 返回 C++ slot 当前值的 PackedArray 快照。

适用：

- GDScript 端需要手动拉取 C++ 输出。
- benchmark / debug / save / A-B 对比。

注意：

- snapshot 是数据传递，不是共享可变引用。
- snapshot 后如果 GDScript 修改这个 PackedArray，不会自动写回 C++ slot。

### `published_to_slot`

部分 C++ pass 返回 Dictionary，其中 `published_to_slot` 表示：

- C++ 已经把结果写入 slot。
- 对应输出已经 flush 或可被 DataCore slot 消费。
- GDScript caller 不应再做昂贵的 array unpack/copy，除非 fallback reason 说明未发布。

当前 SLP 和 PSI 链路已经使用该字段避免重复 copy。排查 ocean currents 时，应把 `published=true` 视为 C++ slot publish 生效的强信号。

### Atlas buffer 直写发布（CSR fan-out 家族）

视觉 / 调试 atlas 的 byte-fill pass（`encode_dynamic_cell_atlas` /
`encode_ecology_visual_atlas` / `encode_dyn_smooth_atlas` /
`encode_ice_state_atlas` / `encode_overlay_atlas`）走另一种发布形态：

- 不写 DataCore slot，而是 GDScript 把一块 `atlas_buffer: PackedByteArray`（长度
  `n_pix * stride`）连同 CSR pixel 列表（`cell_first_px` / `cell_px_count` /
  `flat_px_indices`，复用 `WorldData` 持久 SoA，按 `cell.index` 索引）传入。
- C++ 端 `ptrw()` 直写该 buffer（必要时先 `memset` 清零），再把它原样放回返回
  Dictionary 的 `atlas_buffer` 字段。CoW 公理下，GDScript caller **必须**用返回的
  buffer（`buf = res["atlas_buffer"]`）而不是假设入参被原地改写。
- 失败时返回 `fallback=true` + `reason`，caller 走 GDScript 等价 fan-out。
- `encode_overlay_atlas`（debug-overlay-perf v2）是其中唯一**不读 `_slots`、不要求
  `_bound`** 的成员：overlay 的 per-cell R/G/valid 全部由 GDScript 预采样按
  `cell.index` 喂入，因此地图刚生成 / climate slot 未绑定也能工作。GDScript 侧
  `_fanout_cell_bytes_soa` 是其 bit-equal 兜底。

### Recorder CSV byte buffer

`DCWorldExt.encode_tile_csv_rows(knobs)` 是 tile data recorder 专用的
buffer encoder，不是 slot pass：

- GDScript 仍是权威 orchestration 层：选择 `MapData` 当前 SoA PackedArrays、
  生成固定诊断列、检查 row limit、决定 fallback。
- C++ 不读 `_slots`，也不需要 `refresh_slots_from_map()`；它只接收
  `q_arr/r_arr/s_arr` 和 `arrays: Array[PackedFloat32Array|PackedInt32Array|PackedByteArray]`，
  按既有 CSV 列顺序把一个 tick 的所有 cell 行编码成 UTF-8 `PackedByteArray`。
- GDScript caller 用 `FileAccess.store_buffer()` 写返回 bytes。返回空
  `PackedByteArray` 表示参数非法或旧方法不可用，caller 必须回退到 GDScript
  `_format_record_line()`，不能丢 tick、丢 cell 或丢字段。
- 该路径不发布 DataCore slot，不使用 `published_to_slot`。诊断看
  `tile_encoder_path` / 日志 `encoder=gdext|gdscript`。

### Wind vector contract

风场有两个不同语义的表示，不能混用：

- `cell_wind_x` / `cell_wind_y`：DataCore slot 与 `MapData.wind_x_arr/y_arr` 中的单位方向向量。
- `cell_wind_speed`：真实风速强度。天气平流、降水 carryover、气团热输运、surface injection、PSI/upwelling 风应力都应读这个 slot 做强度权重。
- `WorldData.wind_field_buffer` 与 vector atlas BA：渲染用速度向量，写入 `dir * clamp(wind_speed / 1.7, 0, 1)`。shader 对 BA 求长度时得到归一化风速。

如果某个 C++ 或 GDScript 消费端用 `sqrt(wind_x^2 + wind_y^2)` 当风速，结果会因为单位方向模长接近 1 而退化成全图恒定强风。

### Wind air-mass publish contract

`run_wind_air_mass_pass` 与 GDScript fallback `_wind_air_mass_pass` 只写
`cell_air_mass_temp_anomaly` / `MapData.air_mass_temp_anomaly_arr`，并 flush 该
slot 供后续 surface pass 读取。它们不发布 `cell_temp`，也不应调用
`_flush_slot_to_map(cell_temp)`。

`run_wind_surface_pass` / `_wind_surface_pass` 是气团异常写入 `cell_temp` 的
唯一阶段。这个边界用于避免同一 climate round 内先由 air-mass 覆盖当前温度、
再由 surface pass 二次注入造成局部温度 ping-pong。

## C++ Pass 返回契约

简单 pass 可能返回 `elapsed_ms` 浮点数，复杂 pass 应返回 Dictionary。

推荐 Dictionary 字段：

| 字段 | 含义 |
| --- | --- |
| `elapsed_ms` / `native_ms` | C++ 内部耗时。 |
| `path` | 实际路径，例如 `gdext`、`gdext_raster`、`data_core`、`gdscript_sliced`。 |
| `published_to_slot` | 输出是否已经发布到 slot/MapData。 |
| `fallback_reason` | fallback 原因；成功时为空或不写。 |
| `compute_ms` | C++ tight-loop 纯计算成本。 |
| `apply_ms` | 写 output slot / apply diff 成本。 |
| `flush_ms` | slot flush 到 MapData 成本。 |
| `refresh_ms` | `refresh_slots_from_map()` 成本。 |
| `sync_ms` | caller 侧同步/等待/拉取成本。 |
| `dirty_count` | 输出实际变更数量。 |

返回字段要服务调试，不要只返回一个大 `elapsed_ms`。最近的性能误判通常来自总耗时无法区分 compute、flush、sync 和旧窗口 spike。

## 标准 Native Pass 模板

GDScript caller：

```gdscript
func run_my_pass_native(map: MapData) -> Dictionary:
    if _data_core_world_ext == null:
        return {"path": "gdscript", "fallback_reason": "no_ext"}
    if not _data_core_world_ext.has_method("run_my_pass"):
        return {"path": "gdscript", "fallback_reason": "missing_method"}

    _data_core_world_ext.refresh_slots_from_map()

    var knobs := {
        "season_phase": _phase,
        "some_scale": scale,
    }
    var ret = _data_core_world_ext.run_my_pass(knobs)
    if ret is Dictionary and bool(ret.get("published_to_slot", false)):
        return ret

    return _run_my_pass_gdscript_fallback(map)
```

C++ pass：

```cpp
Dictionary DCWorldExt::run_my_pass(Dictionary knobs) {
    Dictionary out;
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_out = component_id(StringName("cell_my_output"));
    if (sid_temp < 0 || sid_out < 0) {
        out["path"] = "gdscript";
        out["fallback_reason"] = "missing_slot";
        out["published_to_slot"] = false;
        return out;
    }

    const Slot &temp_s = _slots[sid_temp];
    Slot &out_s = _slots.write[sid_out];
    const float *temp = temp_s.arr_f32.ptr();
    float *dst = out_s.arr_f32.ptrw();

    // Tight loop only: no Variant, no Object get/set, no StringName lookup.
    for (int i = 0; i < _entity_count; ++i) {
        dst[i] = temp[i];
    }

    _flush_slot_to_map(sid_out);
    out["path"] = "gdext";
    out["published_to_slot"] = true;
    return out;
}
```

## 反模式

| 反模式 | 后果 | 替代 |
| --- | --- | --- |
| GDScript hot loop 内逐 cell 调 `write_f32` | 跨界/dirty storm，atlas 全脏 | 收集后 `write_f32_indexed` 或 dense。 |
| C++ hot loop 内读 Dictionary / Object property | Variant 和 Object call 吃掉 C++ 收益 | 循环外解析 knobs 和 slot。 |
| 假设 `bind_map_data()` 后永远共享 buffer | CoW 后读旧值 | 显式 `refresh` / `flush` / `snapshot`。 |
| C++ pass 写 slot 后 caller 继续全量 unpack | 重复拷贝，日志显示 sync/apply 偏高 | 使用 `published_to_slot` 跳过。 |
| 每个 stage 都 `refresh_slots_from_map()` | sync 成本累积 | round 开始一次 refresh，stage 间沿用 C++ slot。 |
| fallback 没有 `fallback_reason` | 日志只看到 `path=gdscript`，无法定位 | 返回具体原因：missing_method、missing_slot、bad_size、stale_dll。 |

## 排查 checklist

1. `world bound=true` 吗？
2. `component_count` / slot size 与 `MapData.cell_count()` 一致吗？
3. C++ method 是否已 `ClassDB::bind_method` 注册？
4. GDScript caller 是否通过 `has_method()` 进入了 native 分支？
5. native pass 返回的是 Dictionary 还是旧 float stub？
6. `fallback_reason` 是什么？
7. C++ pass 输出是否写 slot？
8. 输出是否 `_flush_slot_to_map()` 或 `snapshot_*`？
9. caller 是否识别 `published_to_slot=true` 并跳过重复 copy？
10. 后续 GDScript/C++ stage 是否需要 `refresh_slots_from_map()`？

## Climate stability bridge notes

The current climate/weather/ocean stability fixes intentionally reuse existing
bridge surfaces and component slots.

- `cell_temperature_transport_anomaly` remains the bridge slot for ocean heat
  transport anomaly state. `MapData.temperature_transport_anomaly_arr` is the
  GDScript mirror consumed by fallback code and diagnostics. Do not add a
  parallel TTA array unless the schema/codegen workflow explicitly requires it.
- `HexCell.temperature_transport_anomaly` is a facade-backed compatibility
  property, but its getter intentionally reads GDScript `DCWorld` instead of
  `DCWorldExt`. The climate finalizer writes this value through
  `DCWorld.write_f32_dense()` / `MapData` and only marks the C++ mirror stale for
  the next round, so an ext read can observe a previous native snapshot.
- Ocean water and land native passes receive the previous TTA state through the
  existing anomaly array knobs and publish the stabilized value back through the
  same slot/mirror boundary. Callers must keep honoring `published_to_slot` and
  dense writes so later climate stages do not read stale state.
- `cell_ocean_current_x/y` are still independent float slots, but the physical
  expectation is a final vector-magnitude limit. Diagnostics should compute
  `sqrt(x*x + y*y)` when validating saturation, not inspect per-component max
  values alone.
- PSI clamp diagnostics are pass reports, not schema slots. `DCWorldExt`
  returns `ocean_current_preclamp_p95`, `ocean_current_preclamp_max`,
  `ocean_current_clamp_count`, `ocean_current_clamp_ratio`, and
  `ocean_current_max_magnitude`; `MapBaker` caches them for
  `OceanCurrentsJob`, and the tile recorder exports the same values with a
  `phys_` prefix.
- Weather CSV diagnostics are not slot schema. They are sampled reports from
  `sample["weather"]`. `weather_dirty_count`, `weather_convergence_dirty_count`,
  and `weather_convergence_delta_p95` must be interpreted as weather commit
  report fields, not as climate pass fields.
