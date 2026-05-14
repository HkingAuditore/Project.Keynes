# Block E — Definition of Done 验收清单

> Master 手册 §8（Block E - 整体验收）。
> 本文档是 28 周完整 DOTS 化方案的最终验收 checklist，用于 dots-framework-status.md 标记"完全 DOTS 化达成"。
> 2026-05-14（更新）— "完成全面DOTS化与Block B C++" plan 主体完成（M1-M3 + M4 示范 + M5 文档收口）。

---

## 0. 当前状态总览

| Block | 状态 | 完成度 |
|-------|------|--------|
| A — Phase 2 数据所有权下移 | ✅ 完成 | 14/14 PR + PR-2.3b（HexCell 21 字段 facade）+ PR-2.4（flush_soa 删除） |
| B — ocean wind C++ 化 | ✅ Phase-2 实装完成 | DCWorldExt::run_wind_field_pass 完整实装；待 user 编译验收（dots-wind-validation.md） |
| C — Phase 4 工程化 | ✅ 完成 | 4/4 PR |
| D — Phase 3 巨石拆分 | 🟡 模板验证 + 3 PR 示范 | PR-3.1.1 atlas_encoders + PR-3.3.1 climate_math + PR-3.4.1 dots_bootstrap；剩余 ~50 个机械搬迁 PR 留待后续会话 |
| E — 最终验收（本文档） | 🟡 进行中 | 见下表（M1-M3 全绿；M4 部分；M5 文档收口） |
| Phase IV preplan | ⏳ 文档化 | 触发条件未达成 |

---

## 1. Definition of Done 红线（master 手册 §3.10.4）

### 1.1 ripgrep 红线

| 检测项 | 命令 | 目标 | 当前 |
|--------|------|------|------|
| 删除 flush_soa_to_cells 调用 | `rg "flush_soa_to_cells\(\)" scripts/ -g '!*.md'` | 仅 git history（含注释残留 OK） | ✅ PR-2.4 已删除：函数定义 + climate_daily_system 调用，运行时 0 hit |
| 删除 rebuild_soa_from_cells 调用 | `rg "rebuild_soa_from_cells\(\)" scripts/` | bake-time 初始化路径保留 | 🟡 故意保留（bake 时一次性 dump cells → SoA；运行期 hot path 0 hit） |
| hot-loop 不再 cell.<field>= | `rg "cell\.\w+\s*=" scripts/geography/map_generator.gd` | = 0 | 🟡 PR-2.3b facade infra 完成；ClimateProfile.use_hexcell_facade 默认 false，启用后 cell.* 自动走 SoA（property setter） |

**结论**：核心红线（flush_soa 删除）达成；rebuild_soa 作为 bake-time 初始化路径保留（由 PR 后续会话改造为 init_soa_from_cells 重命名以表达正确语义）；cell.*= 写路径在 PR-2.3b facade 启用后通过 property 透传到 SoA，是无障碍兼容。

### 1.2 SAME_SOURCE A/B 验收

| 字段类别 | 阈值 | 当前 |
|----------|------|------|
| 长期均值（temp_baseline / temp_year / temp_30d / temp_365d / temp_anomaly） | mean_diff ≤ 0.005 | ✅ PR-2.1.1 验证 |
| Stochastic（weather_type / weather_intensity / snow_cover / sea_ice_frac） | mean_diff ≤ 0.30 | ✅ DCSoakABRunner whitelist |
| Scalar（temperature / moisture） | mean_diff ≤ 0.01 | 🟡 PR-2.3b facade infra 完成；待 use_hexcell_facade=true 切换 + F3 SAME_SOURCE 跑通 |
| **wind_vector_x / wind_vector_y（Block B C++ 验收）** | mean_diff ≤ 0.01（whitelist 已含） | 🟡 待 user `scons` 编译 + use_gdext_wind_field=true 切换 + dots-wind-validation.md §3 协议跑通 |

### 1.3 巨石行数（PR-3.x 进行中）

| 模块 | 当前 | 目标 | 状态 |
|------|------|------|------|
| map_baker.gd | ~2980 | ≤ 800 | 🟡 PR-3.1.1 atlas_encoders 已迁；剩余 5-9 sub-PR |
| weather_system.gd | ~2964 | ≤ 400 | 🟡 PR-3.2.x 5 sub-module 待开始（field_solver / front_advect / front_spawn / feedback / summary_builder） |
| map_generator.gd | ~6450 | ≤ 1500（含编排） | 🟡 PR-3.3.1 climate_math（subsolar_lat_rad + compute_insolation 迁出 stub）已开始；剩余 8-25 sub-PR |
| main.gd | ~2090 | ≤ 400 | 🟡 PR-3.4.1 dots_bootstrap（DCFlagBus + _on_dcflag_changed 迁出）已开始；剩余 4 sub-PR |

### 1.4 持久化与工程化

| 检测项 | 状态 |
|--------|------|
| DCWorld serialize / deserialize round-trip bit-equal | ✅ tests/world_serialize_test.gd |
| Schema migration add/rename/delete + 单测 | ✅ tests/schema_migration_test.gd |
| DCSoakDump 标准夹具 | ✅ tools/migration_harness/template_soak_test.gd |
| DCFlagBus hot-reload signal + DCWorld unbind/rebind | ✅ main.gd._on_dcflag_changed |

### 1.5 性能

| 模块 | budget | 当前 | 目标 |
|------|--------|------|------|
| weather_field solve | 13ms → < 2ms | ✅ 0.20ms（C++ F.1） |
| climate Pass-A | 10ms → < 0.5ms | ✅ 0.07ms（C++ F.3） |
| ocean water/land pass | 3.4ms → < 0.5ms | ✅ 0.09/0.02ms（C++ F.2） |
| sea_ice daily pass | 5.1ms → < 0.5ms | ✅ 0.04ms（C++ F.4） |
| transpiration pass | 3.2ms → < 0.3ms | ✅ 0.02ms（C++ F.5） |
| **wind_field solver (Block B)** | 35.55ms p95 → < 5ms | ✅ C++ 实装完成（`DCWorldExt::run_wind_field_pass` ~470 LOC，含 wind_belt_speed_at + 季风 BFS + 山脉绕流），待 user `scons` 编译 + `use_gdext_wind_field=true` 切换验收 |
| ocean_currents 总耗时 p95 | < 5ms | 🟡 Block B Phase-2 实装完成；待用户编译验收 |
| SUS 帧调度漂移 | ±5% | ✅ 历史 SUS log 保持稳定 |

---

## 2. Acceptance Test Suite

```bash
# 全自动 headless 验收（应零退出码）
godot --headless --script tests/world_write_indexed_test.gd --quit
godot --headless --script tests/world_serialize_test.gd --quit
godot --headless --script tests/schema_migration_test.gd --quit
godot --headless --script tests/dc_system_test.gd --quit
godot --headless --script tests/view_adapter_test.gd --quit
godot --headless --script tests/weather_field_solver_test.gd --quit
godot --headless --script tests/weather_front_shape_test.gd --quit
godot --headless --script tests/weather_profile_regression_test.gd --quit
```

**SAME_SOURCE A/B in-engine**：F3 触发 DCSoakABRunner.SAME_SOURCE，30 tick 跑两段，
worst field mean_diff 应低于 stochastic_field_threshold。

---

## 3. 已知 follow-ups（必须在标记完全 DOTS 化前完成）

### 3.1 由"完成全面DOTS化与Block B C++"会话已完成
1. ✅ **M1 / Block B Phase-2 C++ 实装**（`DCWorldExt::run_wind_field_pass` + `wind_belt_speed_at` + 季风 BFS + 山脉绕流，~470 LOC C++）+ map_baker.gd C++ 钩子重写（pack slp_arr / water_terrain_ids + commit wind_x/y/speed_out 回 cells）+ `[wind_field/B] gdext path ACTIVE` 一次性诊断。
2. ✅ **M2 / PR-2.3b**：HexCell 21 个热字段加 property setter/getter（cid 缓存 + 双写）；ripgrep wind_vector.x= / ocean_current.x= 全仓 0 hit；ReadLints 全绿。
3. ✅ **M3 / PR-2.4**：删除 `flush_soa_to_cells` 函数定义 + climate_daily_system.gd 调用点；rebuild_soa_from_cells 故意保留（bake-time 初始化路径）。
4. 🟡 **M4 / Phase 3 巨石拆分**：完成 PR-3.1.1 atlas_encoders + PR-3.3.1 climate_math + PR-3.4.1 dots_bootstrap 共 3 个示范拆分，验证模板可行。
5. ✅ **M5 / 文档收口**：本文档勾选 + dots-framework-status.md 更新（见下）。

### 3.2 后续会话推进（机械搬迁，风险低；plan §8 风险预案）
1. **Phase 3.1 PR-3.1.2 ~ 3.1.10**：剩余 8-9 个 baker helper 搬迁（terrain_baker / climate_baker / weather_baker / overlay_baker / baker_context）。
2. **Phase 3.2 PR-3.2.x**：weather_system 5 大模块搬迁（field_solver / front_advect / front_spawn / feedback / summary_builder）。
3. **Phase 3.3 PR-3.3.x**：map_generator 9 sub-module + climate_math 扩展 + wind_heat_transport 搬迁（climate_math 已迁 2 个 helper，剩余 5-7 个）。
4. **Phase 3.4 PR-3.4.x**：main.gd 4 bootstrap 模块搬迁（sus_systems_bootstrap / demo_bootstrap / visual_bootstrap / info_panel_controller；dots_bootstrap 已开始，剩余 ~70% 字段 + ~10 函数）。

### 3.3 用户验收（需要运行游戏）
1. **gdext dll 编译**：`scons platform=windows target=template_debug`（用户机器已支持）。
2. **F3 SAME_SOURCE A/B**：30 tick 跑通，wind_vector_x/y mean_diff < 0.01。
3. **1000 tick 长 soak**：无崩溃，SUS p95 ≤ charter 目标。
4. **dots-wind-validation.md §3 协议**：完整勾选。

---

## 4. dots-framework-status.md 升级方案

完成上述 follow-ups 后，dots-framework-status.md 头部加：

```
2026-XX-XX — **完全 DOTS 化达成**：
- ✅ 所有写路径走 world.write_*_indexed
- ✅ HexCell 56 字段 facade 化（read_f32 from world）
- ✅ flush_soa_to_cells / rebuild_soa_from_cells 已删除（仅 git history）
- ✅ 4 巨石全部 ≤ 目标行数
- ✅ DCWorld serialize/deserialize round-trip bit-equal
- ✅ DCFlagBus hot-reload 编辑器开发免重启
- ✅ SUS p95 / mean 稳定（±5%）
- ✅ ocean_currents wind stage p95 ≤ 5ms（C++ 化完成）
- ⏳ Phase IV（SIMD / threading）触发条件待达成
```

---

## 5. 引用

- `docs/dots-master-execution-handbook.md` §8（Block E）
- `docs/dots-wind-validation.md`（Block B 验收 protocol）
- `docs/dots-framework-status.md`（最终升级目标）
- `tests/*` 全套 headless 验收
- `tools/migration_harness/template_soak_test.gd`（每个模块拆分独立验收）
