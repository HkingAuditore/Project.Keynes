# Native Daily P0 Handoff 工作记录（2026-05-24）

## 背景与目标

本次工作的目标是把运行期 daily simulation 从 legacy SUS/GDScript 链路推进到
C++ `SCHEDULE_GRAPH` 可接管状态，为后续 native daily 单权威化做基础铺垫。

本次完成的是 P0 handoff 基础：让 native daily bundle 能覆盖主要 daily pass，
并让 Active 注册由 native probe gate 决定。本文档不声称 P1-P4 已完成；世界生成
C++ 化、WeatherFront packed snapshot、NativeSystemScheduler 和 fallback 收敛仍是
后续工作。

## 本次已完成

- `map_generator.gd` 现在会构建 native daily bundle，包含：
  - `climate_pass_a_struct`
  - `climate_pass_b_knobs`
  - `ocean_water_knobs`
  - `ocean_land_knobs`
  - `sea_ice_knobs`
  - `transpiration_knobs`
  - `stage_b_knobs`
  - `weather_knobs`
- `native_daily_authoritative_ready = false` 的硬编码闸门已移除，改为 C++ probe gate：
  - `run_native_daily_tick({ "probe": true, ... })`
  - 返回 `authoritative_ready`
  - 返回 `pass_keys`
  - 返回 `required_pass_keys`
  - 返回 `missing_pass_keys`
- Active native daily 注册现在依赖 probe 结果：
  - required pass 全部存在
  - C++ probe 返回 `authoritative_ready == true`
  - 不满足时继续 fallback 到 legacy SUS jobs，并输出明确缺失项。
- 海冰 C++ pass 新增 `apply_terrain_flips`：
  - native active 路径可直接提交 `sea_ice_frac`
  - 可直接提交 `terrain` 的 SEA_ICE/base terrain flip
  - 会更新 native dirty report 中的 `sea_ice_atlas_dirty` 和 `sea_ice_terrain_flip_count`
- `system_schedule.cpp` 修正了 ocean water 到 ocean land 的数据传递：
  - ocean water 运行后从 `water_knobs["anomaly_out"]` 取最新数组
  - 写入 `ocean_land_knobs["anomaly_inout"]`
  - 避免 graph 内 water pass 的 CoW 输出没有传给 land pass。
- debug/release GDExtension dylib 已重建。

## 当前仍然保留的边界

- 默认仍应以 Shadow/Probe 为主。
- Active native daily 需要 hash diff、headless 测试和 perf 记录通过后再放开。
- GDScript 仍负责：
  - native daily bundle 打包
  - Godot 侧 adapter
  - 部分 fallback
  - UI/debug 对象和兼容层
- 运行期仍未完成的迁移：
  - WeatherFront packed snapshot
  - C++ `NativeSystemScheduler`
  - profiler UI 的 native graph 展示
  - fallback 策略收敛
- 生成期仍未完成的迁移：
  - `NativeWorldGenerator`
  - 大陆形态、elevation、slope、river/hydrology、biome/ecology 初判 C++ 化
  - 生成期禁止逐 `HexCell` 写字段的完整落地

## 验证记录

- `git diff --check` 通过。
- `cd gdext && ./rebuild.sh` 通过。
  - template_debug dylib 构建通过
  - template_release dylib 构建通过
- 未运行 Godot headless tests。
  - 原因：当前 shell `PATH` 中没有 `godot` 命令。
  - 需要 Godot CLI 可用后补跑 headless 回归。

## 下一步计划

1. 新增 `native_daily_shadow_test.gd`。
   - 同 seed、同 profile 下跑 legacy SUS 与 native shadow/probe。
   - 对比 temp、moisture、snow、sea_ice_frac、terrain、weather/fronts、vegetation。
   - 浮点字段允许 epsilon，离散字段必须一致或输出差异 cell 列表。

2. 新增 `native_sea_ice_state_machine_test.gd`。
   - 覆盖 dt compensation。
   - 覆盖 terrain flip。
   - 覆盖 abort/restart。
   - 覆盖不同 stride / slice budget 下的确定性。

3. 扩展 profiler UI。
   - 显示 native graph pass 列表。
   - 显示 missing pass。
   - 显示 fallback count。
   - 显示 C++ / GDScript 运行期模拟占比。
   - 显示 marshal / flush / adapter ms。

4. 完成 WeatherFront packed snapshot。
   - C++ 保存 fronts 为 SoA/packed snapshot。
   - 新增 `get_native_fronts_snapshot_packed()`。
   - renderer 优先消费 packed 数据。
   - GDScript `WeatherFront` 对象只保留 UI/debug 兼容用途。

5. 实施 C++ `NativeSystemScheduler`。
   - C++ 内管理 job graph。
   - C++ 内管理 stride policy、depends、frame budget、starvation 和 report。
   - graph 使用 component read/write masks。
   - Active 模式下 GDScript `sus_tick_daily()` 只调用 `run_native_sim_tick(ctx)`。

6. 启动 `NativeWorldGenerator` 分阶段迁移。
   - 第一阶段迁移生成期纯数组算法。
   - 接口固定为 `start_native_generation(seed, cfg, profile)`、
     `run_native_generation_slice(budget)`、`finish_native_generation()`。
   - 生成完成后再按需创建/绑定 `HexCell` facade。

## Active Gate 原则

Active native daily 不应只因为 C++ 方法存在就接管。

必须同时满足：

- native probe 返回 `authoritative_ready == true`
- required pass 无缺失
- shadow hash diff 通过
- headless 回归通过
- perf record 证明 `t_sus_ms p95 <= sim_frame_budget_ms`
- fallback count 可观测，且失败时有明确 `fail_stage` / `reason`

在这些条件满足前，legacy SUS 仍是运行期权威路径。
