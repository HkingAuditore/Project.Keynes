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

### Wind vector contract

风场有两个不同语义的表示，不能混用：

- `cell_wind_x` / `cell_wind_y`：DataCore slot 与 `MapData.wind_x_arr/y_arr` 中的单位方向向量。
- `cell_wind_speed`：真实风速强度。天气平流、降水 carryover、气团热输运、surface injection、PSI/upwelling 风应力都应读这个 slot 做强度权重。
- `WorldData.wind_field_buffer` 与 vector atlas BA：渲染用速度向量，写入 `dir * clamp(wind_speed / 1.7, 0, 1)`。shader 对 BA 求长度时得到归一化风速。

如果某个 C++ 或 GDScript 消费端用 `sqrt(wind_x^2 + wind_y^2)` 当风速，结果会因为单位方向模长接近 1 而退化成全图恒定强风。

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
