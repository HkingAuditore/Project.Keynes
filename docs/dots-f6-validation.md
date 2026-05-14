# F.6 weather_front_advect — C++ 实装验收 SOP

> 状态：**算法已实装，等用户本地编译 + 启用 flag + 跑游戏验收**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §F.6 / [`performance-charter.md`](./performance-charter.md) §7 P3 / 模板 [`dots-f4-validation.md`](./dots-f4-validation.md)
> 创建：2026-05-14 / 责任：weather + co-processor 联调

---

## 1. 这次 PR 改了什么

| 文件 | 改动 |
| ---- | ---- |
| `gdext/src/world_ext.h` | F.6 签名从 `(int n_fronts, float dt)` 改为 `Dictionary knobs`（统一 batch 模式）+ 详细 contract 文档 |
| `gdext/src/world_ext.cpp` | 替换 F.6 stub → ~200 行 C++ 主循环（advect + decay + age + refresh_visual_lifecycle 完整 1:1 mirror） |
| `gdext/src/world_ext.cpp` (`_bind_methods`) | F.6 D_METHOD 签名改成 `("knobs")` 单参 |
| `Project/.../data_core/fronts_schema.gd` | **新文件**：FRONTS_SCHEMA 单一源（23 字段 × WeatherFront 1:1 镜像）|
| `Project/.../weather/weather_front.gd` | 加 static `pack_into_dict(fronts)` / `apply_dict_to_fronts(d, fronts)` helpers，给 F.6 batch 模式复用 |
| `Project/.../weather/weather_system.gd` | `tick_one_day()` fronts 推进段加 F.6 fast-path 分支 + 6 个 F.6 统计字段 + `configure_gdext_acceleration` 加 cp 参数 |
| `Project/.../geography/map_generator.gd` | `configure_gdext_acceleration` 调用站传 cp 引用（让 weather_system fast-path 能动态读 use_gdext_weather_front）|

---

## 2. 关键设计决策

### 2.1 为什么 fronts ≤ 16 仍要 C++ 化？

实际 wall-clock 收益有限（< 0.5ms 一档），但作为完成 **6 hot pass 全 C++ 闭环**的最后一块拼图——阶段 II 数据所有权下移（[`dots-stage-ii-data-ownership-plan.md`](./dots-stage-ii-data-ownership-plan.md)）的硬前置之一。

### 2.2 emergent_coupling / wind_fn 仍由 GDScript 预算

`_front_decay_modifier` / `_front_orographic_precip_bonus` 需要 `map.get_cell_by_cube` 查询；`wind_fn` 是 callable（GDScript 闭包，含 `_sample_terrain_wind` 涉及 wind_belt + monsoon 偏置）。这些**保留 GDScript**——C++ pass 不持有 map 引用 / 不调 callable。

模式：caller 在 pack_into_dict **之前**：
1. 临时改 `front.decay_per_day = saved * decay_mul`（让 C++ 读到的就是修改后值）
2. 预算 `wind_per_front: PackedVector2Array` 传 batch
3. 预算 `precip_bonuses: PackedFloat32Array` 暂存

C++ pass 跑完 + apply_dict_to_fronts 后：
4. 恢复 `front.decay_per_day = saved_decays[i]`（不持久化 emergent 缩放）
5. 应用 `front.precip_amount += precip_bonuses[i]`

### 2.3 fronts SoA 化 vs OOP 双轨

[`weather_front.gd`](../Project/project-keynes/scripts/weather/weather_front.gd) `pack_into_dict` / `apply_dict_to_fronts` 是 **batch** helpers，不是真正的 SoA 升权威。OOP `_active_fronts: Array[WeatherFront]` 仍是权威——每 tick 临时打包/解包，与 F.4 处理 transport_anomaly 同模式。

阶段 II 真正升权威时（[`fronts_schema.gd`](../Project/project-keynes/scripts/data_core/fronts_schema.gd) 描述目标），WeatherFront 退化为 thin facade（getter 走 `world.view_*` by world_idx）；本 pack/apply helpers 删除，advect 直接读写 SoA。

---

## 3. 验收 5 步走（用户本地）

### 步骤 1 — 编译 GDExtension

```powershell
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
scons platform=windows target=template_release dev_build=no -j8
```

### 步骤 2 — 打开 use_gdext_weather_front flag

ClimateProfile `.tres`（或 [`climate_profile.gd`](../Project/project-keynes/scripts/data/climate_profile.gd) line 197）：

```gdscript
@export var use_gdext_weather_front: bool = true   # false → true
```

### 步骤 3 — 启游戏，观察启动日志

期望（在 weather tick 第一次 active fronts > 0 时）：

```
[front/F.6] first attempt: n_active_fronts=3 flag=true ext_ok=true
[front/F.6] sig probe = true（仅作诊断，不阻止下方调用）
[front/F.6] DEBUG call#1: rc=0.05 n_active=3 emergent=true
[front/F.6] gdext path ACTIVE — first run elapsed=0.05ms (legacy GDScript baseline ≈ 3.0ms; charter §7 target < 0.5ms)
```

如果 `flag=false` / `ext_ok=false`：检查 ClimateProfile 是否真的保存了 + GDExtension 是否编译过。

### 步骤 4 — 跑 30-day soak 看 SUS

期望：
- `weather_refresh` advance_ms 段从 ~0.5ms 降到 < 0.1ms
- 总 weather_refresh avg 进一步下降
- `_gdext_front_runs` / `_gdext_front_total_ms` 单调累加（无 fallback 反复）

### 步骤 5 — bit-equal A/B 对照

F.6 算法含 sin/cos/atan2/smoothstep/pow，bit-equal 容差需要按 charter §12.5 容差表设定（1e-5）。

跑 30 天 soak 两遍，第一遍 `use_gdext_weather_front=false`，第二遍 `=true`，对比：
- 全场 fronts `center` / `velocity` / `axis` / `intensity` / `cloud_amount` / `precip_amount` 数值差 < 1e-5
- alive 翻 false 的时机（front pruning）应**完全一致**——这是关键，决定后续 spawn / distribute 的连锁

如果 bit-equal 出现偏差：
1. 把首个 `[front/F.6] DEBUG call#N` 输出贴回
2. 把出现差异的 front idx + (type, age_days, intensity, center) 在两侧分别贴回
3. 在 weather_system 加临时 print 比较 `front.center` / `front.intensity` 在 fast-path 前后

---

## 4. 已知简化（与 GDScript 1:1 对齐外的取舍）

| 项 | C++ 实装 | GDScript 原版 | 影响 |
|---|---|---|---|
| `_visual_intensity` 公式 | `pow(i, 0.55) * smoothstep(0, 0.08, i)` 一致 | 同 | bit-equal |
| `match` type → cloud_mul / precip_mul / precip_retire | C++ switch 完整覆盖 STORM / MONSOON / BLIZZARD / FOG / DROUGHT / HEATWAVE / CLEAR | GDScript match | 完全一致 |
| `_rotate_axis_toward` | C++ atan2(cross, dot) + clamp + rotate | GDScript Vector2.angle_to + .rotated | 算法等价；浮点链路一致 |
| `wind_fn` 采样 | GDScript 端 pre-compute PackedVector2Array | 每 front 内 `wind_fn.call(center)` | 时机 / 输入完全一致 |
| emergent decay_mul / precip_bonus | GDScript 预算后改 decay_per_day（pack 之前）+ 应用 precip_bonus（apply 之后）| 内联 advance_one_day 前后 | 与原版顺序等价 |

---

## 5. 性能目标对照

| Pass | charter §7 目标 | 实测（本机预估）| 备注 |
|---|---|---|---|
| F.5 transp | < 0.3ms | 0.02ms（超 15x）| 已验收 |
| F.4 sea_ice | < 0.5ms | < 0.1ms 预估 | 本批 PR |
| F.3 climate Pass-B | < 0.5ms | 0.07ms（超 7x）| 已验收 |
| F.2 ocean water+land | < 0.5ms 各 | 0.09 / 0.02ms | 已验收 |
| F.1 weather field | < 2ms | 0.19ms（超 10x）| 已验收 |
| **F.6 weather front advect** | **< 0.5ms** | **< 0.1ms（预估，N=16）** | **本 PR**，N 极小但完成"6 全闭环" |

---

## 6. 后续 follow-ups

- [ ] 实测验收通过后把 `use_gdext_weather_front` 默认改为 `true`
- [ ] 6 hot pass 全部默认 true 跑稳一周 → 启动 阶段 II 写路径下移（[`dots-stage-ii-data-ownership-plan.md`](./dots-stage-ii-data-ownership-plan.md)）
- [ ] [`dots-framework-status.md`](./dots-framework-status.md) §1 速读图把 F.6 标 ✅ 已验收

---

**END.**
