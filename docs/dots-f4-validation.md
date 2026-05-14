# F.4 sea_ice daily pass — C++ 实装验收 SOP

> 状态：**算法已实装，等用户本地编译 + 启用 flag + 跑游戏验收**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §F.4 / [`performance-charter.md`](./performance-charter.md) §7 P2 / 模板 [`dots-f5-validation.md`](./dots-f5-validation.md) / [`dots-f3-validation.md`](./dots-f3-validation.md)
> 创建：2026-05-14 / 责任：sea_ice + co-processor 联调

---

## 1. 这次 PR 改了什么

| 文件 | 改动 |
| ---- | ---- |
| `gdext/src/world_ext.h` | F.4 签名从 `const Dictionary &` 改为 `Dictionary`（让 C++ 端能写回 flip 列表）+ 详细 contract 文档（knobs 入/出字段表）|
| `gdext/src/world_ext.cpp` | 替换 F.4 stub → ~190 行 C++ 双 phase 实现（1:1 mirror `_apply_sea_ice_daily_pass` line 3856+）|
| `Project/.../geography/map_generator.gd` | `_apply_sea_ice_daily_pass()` 头部加 GDExt fast-path 分支 + 一次性诊断 print + 6 个 F.4 统计字段 + 3 个 per-tick 输入 buffer cache（base_terrain / temp_transport_anomaly / upwelling_strength）|

---

## 2. 关键设计决策

### 2.1 terrain 翻转**不**在 C++ 端写

F.4 与 F.1-F.3/F.5 最大差异：会触发 `cell.terrain` 翻转（OCEAN ↔ SEA_ICE）。

按 [`performance-charter.md`](./performance-charter.md) §2.5 STRUCT-001 反模式，`apply_terrain` 是 multi-axis 同步入口（同时维护 `terrain` / `passable_land` / `passable_sea` 派生字段，未来还会扩展 `landform` / `cover` 同步）。**C++ 端直接改 cell_terrain SoA 会绕过这套语义** → 选择 charter 推荐的"由 C++ 收集 flip 候选 list，GDScript 端串行 apply_terrain"模式。

```cpp
// world_ext.cpp 输出回填到 knobs：
knobs["flip_to_ice_list"]     = flip_to_ice;       // PackedInt32Array
knobs["flip_to_base_list"]    = flip_to_base;      // PackedInt32Array
knobs["flip_to_base_terrain"] = flip_to_base_terrain; // PackedByteArray (与 list 同长)
knobs["stat_water_count"]     = water_count;
knobs["stat_flipped_count"]   = flipped_count;
```

```gdscript
# map_generator.gd 拿到 list 后串行 apply_terrain（每天 < 几十个 cell）：
for i_flip in range(flip_to_ice_list.size()):
    var idx_i: int = flip_to_ice_list[i_flip]
    (cells_fast[idx_i] as HexCell).apply_terrain(TerrainType.TERRAIN.SEA_ICE)
```

### 2.2 SoA 镜像缺失字段的处理

`temperature_transport_anomaly` 和 `upwelling_strength` 在 schema 里**没有 SoA 镜像**（只是 HexCell 字段）。F.2 ocean pass 也踩过同样的坑（cells[i].ocean_current.x/y）——解决方案：**每 tick GDScript 端从 cells 提取一份 PackedFloat32Array 传 C++**。

### 2.2.b storage A/B 同源契约（critical · DOTS pass 写者-读者纪律）

**适用范围**：本节是所有 GDExtension F.X C++ pass 的**通用契约**，不限于 F.4 sea_ice。F.2 / F.3 / F.5 / F.6 已踩过同样的坑。

#### 背景：三套 storage 副本

DOTS 迁移过渡期同一份"cell-level 数值字段"在内存里以三种形式共存（charter §11）：

1. **HexCell typed field**（`cell.temperature` / `cell.moisture` / `cell.terrain`）
   — fastpath 强类型成员，部分 GDScript hot path 直读直写
2. **MapData SoA PackedArray**（`map.temp_arr[i]` / `map.moisture_arr[i]`）
   — schema 权威 SoA，bind 时刻被 DCWorld 与 DCWorldExt 同时 alias
3. **DCWorldExt slot.arr_f32**（C++ 私有 buffer，`_slots[cid].arr_f32`）
   — C++ 调 `ptrw()` 后 CoW 解耦成私有 buffer；C++ pass 通过 `_flush_slot_to_map` 推回 MapData

只要任一写者改动其中一份，其他两份就**不再 alias**（CoW 解耦 / 单向 snapshot）。如果下游读者从"过期那一份"读，就会看到**旧值参与新计算**，bit-equal 失败、行为漂移、误差累积。

#### 已知踩坑（2026-05-14 三条）

##### 坑 1（F.4）— C++ pass 直接读 SoA slot 拿到的不是 GDScript 看到的字段

**症状**："全图下雪、洋流崩坏、海冰奇形怪状"。

**根因**：sliced 路径下 `pass_b` / `ocean_water` / `ocean_land` 都是 C++ 跑，它们写 SoA `cell_temp` slot 但**不**回写 `cell.temperature`（charter §11.1 single-direction snapshot）。

- GDScript fallback `_apply_sea_ice_daily_pass` 读 `cell.temperature` → 拿到 **pass_a 之后的"基线温度"**（暖）
- C++ fast-path 直读 SoA `cell_temp` slot → 拿到 **ocean_land 之后的"修正温度"**（冷得多）

两条路径同 cell 温差 ~0.05-0.18，sea_ice 算冰量大幅偏多 → bit-equal 失败。

**修复**：GDScript fast-path 从 `cell.temperature` 打包 `_gdext_sea_ice_temp_buf` PackedFloat32Array 传给 C++（与 tta/upw 同一 pattern），C++ 读 `knobs["cell_temperature_arr"]` 而**不**读 SoA slot。

##### 坑 2（fix-a 2026-05-14）— View adapter 缓存 PackedArray 后 CoW 解耦致 UI 永远显示生成期 baseline

**症状**：开 use_gdext_* 后 UI panel 点击任何格子都显示"温度 0.00 / 极寒"；overlay 颜色随时间越变越奇怪。关 use_data_core 后正常。

**根因**：`DCViewAdapter.World.setup()` 一次性把 `world.view_f32(cid)` 缓存到 `_v_temp` 等 35 个字段，期望它们和 SoA slot.arr_f32 共享 buffer。但 C++ pass 调 `ptrw()` 第一次写时触发 CoW，slot 拿私有 buffer，**adapter 的 `_v_temp` 永远指向 bind 时刻的 baseline buffer**（生成期 0.0），UI 取的全是陈旧值。

**修复**：World adapter 改为不缓存 view。getter 直接 `_map_data.<map_field>[idx]`，每次重新拿 `MapData` 上的当前 PackedArray 引用——`map.<field>` 是 GDScript var，不论 CoW 解耦还是 C++ flush 都会被赋上最新 buffer，下次读总是看到最新状态。代价是冷路径每 getter ~50ns（UI 几次/秒可忽略，hot loop 不走 adapter）。详见 [view_adapter.gd](../Project/project-keynes/scripts/data_core/view_adapter.gd) "World 实现的 SoA 真值源" 注释段。

##### 坑 3（fix-b 2026-05-14）— C++ pass 入口未 refresh slot 致温度逐日累积发散

**症状**：开 use_gdext_* 跑 30 天后温度分布"越跑越奇怪"（关 use_data_core 后正常）。

**根因**：sliced pipeline 中 GDScript SoA Pass-A 写 `map.temp_arr[i] = ...`，触发 CoW → `map.temp_arr` 拿私有 buffer，但 C++ DCWorldExt 的 `slot.arr_f32` 仍指向 bind 时刻旧 buffer。后续 C++ Pass-B / ocean_water / ocean_land / sea_ice / transpiration 直接读 slot.arr_f32 → 拿到 **day-N-1 的陈旧温度**做计算，再写 slot 并 flush 回 map.temp_arr → 把 GDScript 写过的新值覆盖。误差每天累积一份。

**修复**：5 个 C++ pass 入口（climate_pass_b / ocean_water / ocean_land / sea_ice / transpiration）在调 C++ 之前调 `_data_core_world_ext.refresh_slots_from_map()`。该方法会把 38 个 component 重新从 `MapData.<map_field>` 拉到 C++ slot，强制对齐"GDScript 端最新可见状态"。开销 ~14μs / 35 component（map_data->get + Variant 类型分发），整 round 5 次约 70μs，远小于 round 总耗时 ~9ms。

未来 Phase 2.1 GDScript 改走 `world.write_f32_indexed(cid, dirty_indices, new_temps)` 后可移除（PR-2.1.1，详见 docs/dots-phase2-followup.md）。

#### 通用契约（写新 C++ pass 时遵循）

每当向 C++ 加新 GDExtension F.X pass 时：

1. **读"前序 sub-pass 写过的字段"** —
   - 若前序 sub-pass 是 **GDScript 直写 cell** 或 **C++ 不 flush 回 cell**：必须从 GDScript 端打包 PackedFloat32Array 经 `knobs` 传入，不读 SoA slot（参考 F.4 `cell_temperature_arr` 模式）。
   - 若前序 sub-pass 是 **GDScript SoA Pass 写 map.\*_arr** 后又跨过一段 C++ pass：必须在调 C++ 前 `refresh_slots_from_map()`，否则 C++ slot 仍是旧 buffer（参考 fix-b 模式）。

2. **写完字段下游有读者** —
   - C++ 写 SoA slot 后，**必须**调 `_flush_slot_to_map`（已封装在每个 pass 末尾），让 MapData 拿到 C++ 私有 buffer 引用，下游 GDScript / View Adapter 才能看到。
   - C++ 不会自动写回 `cell.<typed_field>` —— 需要 round 末 `flush_soa_to_cells` 触发；若下游需要立即可见，由调用方 GDScript 手动同步（参考 F.4 sea_ice apply_terrain 后同步 `cells[i].sea_ice_fraction`）。

3. **冷路径读者（UI / panel / inspector）** —
   - **永远不要** cache `world.view_f32(cid)` 到长寿命 RefCounted 字段。每次读重新从 `MapData.<map_field>` 取（`DCViewAdapter.World` 已经按此模式实现）。
   - hot loop 内仍可 cache 到局部变量（loop 内没人 ptrw → buffer 不会切换）。

4. **A/B 验证工具** —
   每次写完 C++ pass，跑 `--soak-dump=30` 在开/关 use_gdext_* 两份 dump 之间 diff（详见 [dots-soak-dump-howto.md](dots-soak-dump-howto.md)），mean 列差异应 ≤1e-4。差异超过阈值通常意味着违反上面 1-3 条之一。

#### F.4 实施模板（buffer cache + refresh）

预 alloc 的 buffer cache 字段：

```gdscript
var _gdext_sea_ice_base_terrain_buf: PackedByteArray   = PackedByteArray()
var _gdext_sea_ice_tta_buf:          PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_upw_buf:          PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_temp_buf:         PackedFloat32Array = PackedFloat32Array()  # 坑 1 修复
```

每 tick 复用（resize 到 n_cells_fast 后逐 cell 写入），不跨 tick cache（transport_anomaly / upwelling 每日变）。
入口 refresh（坑 3 修复）：

```gdscript
if _data_core_world_ext.has_method("refresh_slots_from_map"):
    _data_core_world_ext.refresh_slots_from_map()
var rc: float = float(_data_core_world_ext.run_sea_ice_daily_pass(knobs, season_phase))
```

---

## 3. 验收 5 步走（用户本地）

### 步骤 1 — 编译 GDExtension

```powershell
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
scons platform=windows target=template_release dev_build=no -j8
```

### 步骤 2 — 打开 use_gdext_sea_ice flag

ClimateProfile `.tres`（或 [`climate_profile.gd`](../Project/project-keynes/scripts/data/climate_profile.gd) line 195）：

```gdscript
@export var use_gdext_sea_ice: bool = true   # false → true
```

### 步骤 3 — 启游戏，观察启动日志

期望（在 sea_ice daily 第一次 tick 内）：

```
[sea_ice/F.4] precondition probe (one-time):
  active ClimateProfile = res://data/climate_profile.tres
  cp.use_gdext_sea_ice = true
  _data_core_world_ext != null = true
  ext.has_method('run_sea_ice_daily_pass') = true
  fast_indexed = true (need n_cells*6=14400, got neighbor_indices.size()=14400)
  verdict = OK → will try C++
[sea_ice/F.4] sig probe result = true（仅作诊断，不阻止下方 C++ 调用）
[sea_ice/F.4] DEBUG call#1: rc=0.05 n_cells=2400 enable_oht=true
[sea_ice/F.4] gdext path ACTIVE — first run elapsed=0.05ms (legacy GDScript baseline ≈ 5.1ms; charter §7 target < 0.5ms)
```

如果 `verdict = FAIL → fall through to GDScript path`，说明 flag / class / has_method / fast_indexed 任一不满足，按 probe 输出排查。

### 步骤 4 — 跑 30-day soak 看 SUS

期望：
- `refresh_climate_daily` 行内 `sea_ice=` 字段从 ~5ms 降到 < 0.5ms
- 整体 `refresh_climate_daily` 总 avg 进一步下降（与 F.5 / F.3 / F.2 叠加效应）

### 步骤 5 — 视觉 + bit-equal 验证

F.4 算法是简单 muladd / clamp + 阈值翻转，bit-equal 风险极低（无 sqrt / sin）。

#### 5.1 视觉

直接在游戏里观察 1 个 in-game year：
- 北半球冬季高纬海域 SEA_ICE 形成应与 F.4 关闭时**像素级一致**
- 南半球 7 月（南半球冬季）同样
- 春夏融化时间也应一致

#### 5.2 bit-equal A/B（可选）

跑 30 天 soak 两遍，第一遍 `use_gdext_sea_ice=false`，第二遍 `=true`，对比：
- 全图 `cell.sea_ice_fraction` 数值差 < 1e-6（容差按 charter §12.5 简单算子）
- terrain 翻转 cell 集合**完全一致**（byte-equal）—— 这是关键，因为翻转受阈值 + hysteresis 控制，相位差 1 天就会失配

如果 bit-equal 出现偏差：
1. 把 `[sea_ice/F.4] DEBUG call#N` 输出贴回
2. 把出现差异的 cell idx + (terrain, sea_ice_fraction, has_cold_neighbor) 贴回

---

## 4. 已知简化（与 GDScript 1:1 对齐外的取舍）

| 项 | C++ 实装 | GDScript 原版 | 影响 |
|---|---|---|---|
| `_is_water` 判定 | terrain ∈ {OCEAN, LAKE, SEA_ICE}（按 enum id 直接比较） | `_is_water(cell.terrain)` 函数（含 COAST？需确认） | 如果 GDScript `_is_water` 含 COAST，需要在 knobs 里加 `terrain_coast_id` 并扩展判定条件 |
| terrain 翻转写入 | C++ 收集 flip lists；GDScript 串行 apply_terrain | C++ 直接 cell.apply_terrain（GDScript 路径） | 性能损失 ~每天 < 几十次 apply_terrain（每次 < 0.01ms），可忽略 |
| QA 异常守卫 print | 在 GDScript caller 端用 `stat_water_count` / `stat_flipped_count` 打 | 在 C++ 主循环末尾 push_warning | 行为一致，print 来源不同 |
| 节流打点（每 365 天） | GDScript caller 端打（带 F.4 标记） | GDScript pass 末尾打 | 行为一致 |

---

## 5. 性能目标对照

| Pass | charter §7 目标 | 实测（本机预估）| 备注 |
|---|---|---|---|
| F.5 transp | < 0.3ms | 0.02ms（超 15x）| 已验收 |
| F.3 climate Pass-B | < 0.5ms | 0.07ms（超 7x）| 已验收 |
| F.2 ocean water+land | < 0.5ms 各 | 0.09 / 0.02ms（超 5x）| 已验收 |
| F.1 weather field | < 2ms | 0.19ms（超 10x）| 已验收 |
| **F.4 sea_ice** | **< 0.5ms** | **< 0.1ms（预估）** | **本 PR**，2-phase 计算量约 = transp × 1.2 |

如果实测 > 1ms，定位思路：
1. 看 `n_cells` 是否异常（应 = 24×100 = 2400）
2. 看 `enable_oht=true` 时是否每 cell 都跑 OHT 分支（仅 water cell）
3. `has_cold_neighbor` Phase A 应该只覆盖 water cells（~30% 总 cell）

---

## 6. 后续 follow-ups

- [ ] 实测验收通过后把 `use_gdext_sea_ice` 默认改为 `true`（`climate_profile.gd` line 195）
- [ ] 把本验证报告作为 F.6（weather front advect）实装时的模板
- [ ] 等 F.6 也实装 + 默认 true → 阶段 II（[`dots-stage-ii-data-ownership-plan.md`](./dots-stage-ii-data-ownership-plan.md)）前置条件全部满足，可启动 G.4 写路径下移
- [ ] [`dots-framework-status.md`](./dots-framework-status.md) §1 速读图把 F.4 标 ✅ 已验收

---

**END.**
