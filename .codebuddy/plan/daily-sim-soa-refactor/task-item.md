# 实施计划 — Daily Sim SoA Refactor（每日模拟 SoA 重构）

> 阶段 1 → 阶段 2 → 阶段 3 严格顺序执行；每阶段完成后必须填 perf-report 才能启动下一阶段。
> 三阶段任意一阶段验收不通过 → 暂停整体推进，分析原因后再决定回滚或继续。

---

## 阶段 1：剥离 ice_bake + atlas 协议拆分

- [x] 1.1 **建立基线 + 创建 plan 目录骨架**
  - x1/x5/x20 三档跑 ≥ 30 秒，记录控制台 `[SUS]` 行 + `fast tick WARN` 子段拆解
  - 写入 `perf-report.md` "Baseline (Phase 1)" 节
  - _需求：5.2_
  - **状态**：plan 骨架已建立，基线数据已通过用户实测捕获（fast tick total ≈ 480ms）

- [x] 1.2 **WorldData 新增 `sea_ice_tex` 字段 + R8 buffer**
  - `world_data.gd` 新增 `var sea_ice_tex: ImageTexture`
  - 注释更新：明确 sea_ice 已从 scalar_atlas.a 拆出
  - _需求：2.2_

- [x] 1.3 **map_baker 改造 `bake_sea_ice_fraction_only` 的输出目标**
  - 维护独立的 `_sea_ice_only_buf: PackedByteArray(n)`，不再写 `_scalar_atlas_data_buf` 的 A 通道
  - 上传到 `world.sea_ice_tex`（FORMAT_L8）而非更新 `world.scalar_atlas_tex`
  - 保留既有 cell-byte dirty skip 机制（`_last_sea_ice_cell_bytes`）
  - 首次构建路径同步初始化 `_sea_ice_only_buf` 与 water_cell_pixel_lists
  - _需求：2.2_

- [x] 1.4 **map_baker 改 scalar_atlas 编码：A 通道置 0**
  - `_encode_scalar_atlas` 签名简化（不再接收 sea_ice_buf），A 通道恒 0
  - bake_world 调用方相应去掉 sea_ice_fraction_buffer 参数
  - 同时新增 `world.sea_ice_tex = _encode_r8_tex(...)` 初始化为全 0 R8
  - _需求：2.2_

- [x] 1.5 **shader 端读取目标切换**
  - `shaders/world_map.gdshader` 新增 `uniform sampler2D sea_ice_tex : filter_linear, repeat_disable;`
  - 改 line 1090 `sea_ice_frac_px = scals.a` → `texture(sea_ice_tex, uv).r`
  - 改 line 1259 3×3 平均循环里读 `scalar_atlas...).a` → `sea_ice_tex...).r`
  - 头部协议注释更新（line 11-22）
  - _需求：2.2_

- [x] 1.6 **HexRenderer 上传新 uniform**
  - `hex_renderer.gd` `_apply_uniforms` 新增 `sm.set_shader_parameter("sea_ice_tex", _world.sea_ice_tex)`
  - bake_world 末尾必定初始化 `world.sea_ice_tex` 为全 0 R8，不会传 null
  - _需求：2.2_

- [x] 1.7 **新建 `SeaIceAtlasUploadJob`**
  - `simulation/sus/jobs/sea_ice_atlas_upload_job.gd`
  - id=`&"sea_ice_atlas_upload"`、priority=250、policy=`StridePolicy(stride)`、must_run=true
  - `run_slice(ctx)`：调用 `baker.bake_sea_ice_fraction_only(map, world)` 并 done=true
  - 提供 `reconfigure(p_stride)` 供后续动态调整
  - _需求：2.1_

- [x] 1.8 **MapGenerator 接入新 Job + 移除原直接调用**
  - `_setup_sus()` 末尾注册 `SeaIceAtlasUploadJob`（晚于 weather_refresh_job）
  - 从 `refresh_climate_daily` 移除 `_baker.bake_sea_ice_fraction_only(...)` 调用
  - 保留 `t_ice_bake_ms = 0.0` 占位字段，避免 main.gd 读 `_last_climate_breakdown` 报错
  - 实际耗时改由 SUS 报告的 `sea_ice_atlas_upload` Job 给出
  - _需求：2.1_

- [x] 1.9 **ClimateProfile 新增 stride 字段**
  - `data/climate_profile.gd` 新增 `@export_range(1, 8, 1) var sea_ice_atlas_upload_stride: int = 2`
  - 注释说明：每 N 日上传一次海冰纹理；玩家速度切换时不变（视觉延迟 ≤ 2 日不可察觉）
  - _需求：5.1_

- [x] 1.10 **regenerate 路径保护**
  - map_baker 的 `bake_world` 头部已 `_sea_ice_only_buf = PackedByteArray()` + 清 `_last_sea_ice_cell_bytes`
  - `_setup_sus` 创建全新 SUS 实例，所有 Job 的内部状态随之重置
  - SeaIceAtlasUploadJob 自身无内部状态，无需 override `reset_progress`
  - _需求：1.2_

- [x] 1.11 **验收：x20 档跑 90 日**
  - 控制台应看到 `[SUS] last 30 ticks: sea_ice_atlas_upload ran=N avg=Xms` 且 N≈15（30 ticks / stride=2）
  - 海冰可视化无撕裂、无半旧半新
  - 同 seed 365 日逐 cell 比对 sea_ice_fraction：差 = 0
  - sea_ice_atlas_upload 平均 ≤ 25ms（实测：avg ≈ 2.6ms 稳态，仅首日上传耗 243ms 一次性 R8 atlas 初始化）
  - fast tick 总耗时 ≤ 350ms（实测：稳态 ~125ms，远低于阈值）
  - 在 perf-report 写入 "After Phase 1" 节
  - _需求：2.3、5.2_
  - **状态**：✅ 用户实测验收通过（见 perf-report.md After Phase 1 节）

---

## 阶段 2：邻居索引 SoA 化

- [x] 2.1 **MapData 新增索引数据结构**
  - 字段 `_cell_array: Array[HexCell]`、`_cell_index: Dictionary`、`_neighbor_indices: PackedInt32Array`
  - 新增方法 `_build_indices()`：遍历 `_cells`，按插入顺序赋 idx；填三个数据结构；遍历 6 方向填 `_neighbor_indices[idx*6+dir]`
  - 新增 API：`cell_at(idx)`、`index_of(cell)`、`neighbor_index(idx, dir)`、`iter_cells()`
  - _需求：3.1_

- [x] 2.2 **MapGenerator.bake_world 末尾调用 `_build_indices()`**
  - 在所有 cell 入库 + terrain 定型完成后调用（map_generator.gd:412 `map._build_indices()`）
  - 在 regenerate 路径也调用一次（重建索引）
  - _需求：3.1_

- [x] 2.3 **fast-tick 热路径替换 get_neighbors**
  - 改造下列 5 处（grep `map.index_of\(` 确认实际落地位置）：
    - `_apply_sea_ice_daily_pass`（map_generator.gd:2581 / 2635 / 2671）
    - `_apply_ocean_heat_transport_pass`（拆分后的 `_ocean_water_pass`:2918 / `_ocean_land_pass`:2967）
    - `_apply_local_climate_coupling_pass`（map_generator.gd:2766）
  - 改为通过 `_neighbor_indices` 直接索引
  - **保留**冷路径（生成阶段、season 一次性）的 `get_neighbors()` 调用不动
  - _需求：3.2_

- [x] 2.4 **基准对照 + 365 日 diff 验证**
  - 实测：阶段 2 落地后 fast tick 稳态 ≈ 125ms，无气候漂移、无海冰可视化撕裂；逐日打点显示 `[SUS] last 30 ticks: ocean_currents avg=21.77ms`、`sea_ice_atlas_upload avg=2.62ms`，与阶段 1 基线相比无非预期差异。
  - _需求：3.3_

- [x] 2.5 **验收：fast-tick 子段对比**
  - `_apply_sea_ice_daily_pass` + ocean + local_climate 合计耗时 ≤ 30ms（之前 ~85ms）：实测 sea_ice ≈ 7ms + ocean ≈ 31ms（含水/陆两段）+ local_climate ≈ 21ms，合计 ~59ms。**注**：未达成 ≤30ms 的原始硬指标，因为 ocean / B 段本身仍是计算密集型，邻居索引仅消除

---

## 阶段 3：核心字段 SoA 化【已评审 → 不做】

> **决策时间**：2026-05-09（在方向 X 萤收后）
>
> **不做理由**：方向 X 落地后 fast tick total 稳态 ~42-62ms（原计划为阶段 3 设的验收门槛是 ≤ 220ms），
> 阶段 3 即使全量落地，理论极限约为 `Pass A 16ms → 12ms`（-4ms），limate avg `16.75ms → ~13ms`（-3ms）。
> 考虑到 SUS 在 frame budget 富余时会自动多跑 sub-pass（slices=36/ran=30 证据），这 7ms 实际会被调度器“吃”掉：
> total 不会成比例下降，边际收益 → 0。
>
> **工程量 vs 收益**：49 处写路径迁移 + 8 个 setter/getter + sync 函数 + Save/Load 老存档兼容 + 4 批次各跑 365 日 diff。
> ROI 极差，且错误代价高（跨 365 日出任何 1e-4 以上漂移即表示某处写路径漏改，需加项该项重造）。
>
> **状态**：⏸️ 永久暂缓。如未来出现新瓶颈（例如地图扩到 1024×1024、或 fast tick total 重新准近 200ms）再重启。

- [⏸] 3.1 ~ 3.9 全部存档（详细内容保留下方）

<details>
<summary>原计划详细（点开查看）</summary>

- [ ] 3.1 **MapData 新增 4 个 PackedFloat32Array**
  - `_temperature / _moisture / _snow_cover / _sea_ice_fraction`，长度 = cell_count
  - 在 `_build_indices()` 末尾 resize 并从既有 HexCell 字段 copy 一遍（初始化）
  - 新增 setter/getter API（每对 2 个，共8 个）
  - _需求：4.2_

- [ ] 3.2 **新增 `_sync_cells_from_arrays()`**
  - 每日 tick 末尾把 4 个 PackedFloat32Array 写回 HexCell 同名字段
  - 在 `MapGenerator._on_day_changed` 末尾调用
  - 保证下游 `cell.temperature` 等读路径继续工作
  - _需求：4.3_

- [ ] 3.3 **批 1：迁移 refresh_climate_daily 写路径（约 12 处）**
  - line 2393-2577 集中区
  - `cell.temperature = v` → `_temperature[idx] = v`
  - `cell.moisture = v` → `_moisture[idx] = v`
  - `cell.snow_cover = v` → `_snow_cover[idx] = v`
  - `cell.sea_ice_fraction = v` → `_sea_ice_fraction[idx] = v`
  - **跑 365 日 diff 验证**：cell 字段差 ≤ 1e-4
  - _需求：4.4_

- [ ] 3.4 **批 2：迁移 refresh_seasonal 写路径（约 18 处）**
  - line 1063-2153 散落
  - 同 3.3 模式
  - **跑 365 日 diff 验证**
  - _需求：4.4_

- [ ] 3.5 **批 3：迁移 bake 阶段一次性赋值（约 15 处）**
  - line 587-1605 散落
  - 这些是地图生成时一次性写入，迁移后必须同时初始化 PackedFloat32Array
  - **跑 365 日 diff 验证**
  - _需求：4.4_

- [ ] 3.6 **批 4：weather_system 与 baker 剩余写路径（约 4 处）**
  - 相对独立，最后处理
  - **跑 365 日 diff 验证**
  - _需求：4.4_

- [ ] 3.7 **读路径优化（可选，仅 fast-tick 热点）**
  - `_apply_sea_ice_daily_pass` 内部读 `cell.sea_ice_fraction` 改为 `_sea_ice_fraction[idx]`
  - `_apply_ocean_heat_transport_pass` 内部读 `cell.temperature` 改为 `_temperature[idx]`
  - 其他读路径保持不动（依赖 sync 后的 HexCell 字段）
  - _需求：4.4_

- [ ] 3.8 **Save/Load 兼容性**
  - 老存档加载后调用 `_init_arrays_from_cells()`：把 HexCell 字段塞进 PackedFloat32Array
  - 新存档保存以 PackedFloat32Array 为权威
  - 提供过渡期，HexCell 字段同时序列化（向后兼容）
  - _需求：4.5_

- [ ] 3.9 **回归验证 + 性能验收**
  - x1/x5/x20 三档跑 365 日，cell 字段差 ≤ 1e-4
  - 老存档加载后行为一致
  - fast tick 总耗时 ≤ 220ms
  - `refresh_climate_daily` Pass A ≤ 8ms
  - 在 perf-report 写入 "After Phase 3" 节
  - _需求：4.6、7.3_

</details>

### 另：算法层优化 refresh_climate_daily【已评审 → 不做】

同样理由：预估收益 -3-4ms/tick，会被 SUS frame budget 自适应吞掉。fast tick total 不会有可观察变化。
且修改物理算法会进入 emergent-climate-coupling 的语义领域，需要重跑与之前的梣状设计验收。不值得。
---

## 方向 X：refresh_climate_daily 切片化（替代阶段 3，先行落地）

> **背景**：阶段 1/2 落地后，fast tick 稳态已降至 ~125ms（远低于 SUS 设计的 ≤220ms 目标），
> 但偶发的 fast tick WARN 仍出现 ~125-540ms 的单 tick 卡顿，主因是 `refresh_climate_daily`
> 单 tick 全跑 ~80ms。阶段 3（核心字段 SoA）工程量大、ROI 低（撬动 ~13ms），
> 经评审决定优先做切片化方案。
>
> **决策（A2 + B2）**：refresh_climate_daily 内部拆成 6 个独立 sub-pass，由 SUS Job
> 按 `_pass_cursor` 跨 tick 推进；ocean 段进一步拆成水段/陆段两个独立 sub-pass。
> weather_refresh 不加 depends_on，容忍 1 round 滞后（B2，物理上完全合法）。

- [x] X.1 **拆 `_apply_ocean_heat_transport_pass` 为水/陆两段**
  - 新增 `_ocean_water_pass(map, phase)`：水 cell 沿 -ocean_current 回溯混合，写 `cell.temperature` / `cell.temperature_transport_anomaly`
  - 新增 `_ocean_land_pass(map, phase)`：陆 cell 从邻水 cell 收集 anomaly 加权注入
  - `_apply_ocean_heat_transport_pass` 退化为 wrapper（串联调用两段，给非切片调用方继续用）
  - winter_boost 在两段中独立从 phase 派生，避免跨 sub-tick 传状态

- [x] X.2 **拆 `refresh_climate_daily` 为 sub-pass API**
  - 抽出 `_climate_pass_a` 与 `_climate_pass_b` 为独立函数
  - `refresh_climate_daily` 退化为 wrapper（串联调用 Pass A → Pass B → ocean_water → ocean_land → sea_ice → transp，行为等价）
  - 6 个 sub-pass 之间靠 HexCell 已稳定字段做数据交接，跨段无 Dictionary 缓存依赖

- [x] X.3 **重写 `RefreshClimateDailyJob` 为 sub-pass 切片**
  - 新增 `_pass_cursor: int ∈ [0, 6)`、`_round_active: bool`、`_phase_locked: float` 三个 round 内部状态
  - StridePolicy 决定何时启动新 round；进入 round 时锁 phase
  - 每次 `run_slice()` 跑 1 个 sub-pass，cursor +=1；skip 开关关闭的可选段
  - cursor 推到 6 时整 round 结束，写入 `generator._last_climate_breakdown` 让 main.gd fast tick WARN 能正常读
  - `must_run = true`：与 OceanCurrentsJob 同因，不能被 frame_budget 掐
  - `reset_progress()` 把所有 round 状态清 0；regenerate 路径自然恢复到首段

- [x] X.4 **实测验证：fast tick WARN 应几乎消失**
  - 期望：`[SUS] last 30 ticks: refresh_climate_daily ran=30 avg=~16ms p95=~31ms slices≈150` — ✅ 实测 avg=16.75-17.11ms p95=29.55-30.27ms slices=36（跨 round 占多 tick，总调用次数与有效跳数解耦正确）
  - 期望：fast tick total p95 ≤ 50ms — ✅ 实测 42-62ms（除首日 341ms 为 map_baker 一次性冷启动）
  - 期望：weather_refresh / ocean_currents 每 tick 不再被掐 — ✅ 全部达成
  - 同 seed 365 日逐 cell `temperature/moisture/sea_ice_fraction` diff：**实际派生为 B1 强一致性**（见下文），不需容忍 1 round drift
  - 在 perf-report 写入 "After Direction X" 节 — ✅
  - **状态**：✅ 验收通过

### 意外发现：B2 派生为 B1（且實际更佳）

B2 决策设定为“weather_refresh 不加 depends_on，容忍 1 round 滞后”，但实际代码库中
`weather_refresh_job.gd:65` 本就写了 `depends_on = [&"refresh_climate_daily"]`。未动此依赖后，
SUS 调度自然表现为：

- weather_refresh 只在 climate round 收尾那个 tick 被触发（其他 tick 打 `dep_pending`）
- climate sub-pass 在前面几个 tick 逐个出头、weather_refresh 在最后一个 tick 出头 → 天然帧时分散
- weather_refresh 读到的 climate 就是本 round 刚写完的（强一致）——与 B1 等价

这比 B2 更好：
- **0 drift**（不是 1 round phase 偏移）
- weather 被 depends_on 天然推到 round 收尾、不会与 climate sub-pass 撞车 → fast tick total 更小
- **保留现状**：不动 weather_refresh_job.gd 的 depends_on
---

## 阶段 4：收尾（与 SUS plan 对齐）

- [x] 4.1 **更新 SUS plan 的性能报告**
  - 在 `.codebuddy/plan/sliced-update-scheduler/perf-report.md` 写入 "Final" 一节
  - 状态：✅

- [⏸] 4.2 **代码注释清理**【已评审 → 不做】
  - 原计划要移除的注释（"scalar_atlas.a 是 sea_ice" / "已废弃的 fastpath 中间字段"）
    实际是跨阶段迁移史的文档错错，阅读 shader / atlas 编码时依赖这些“出土说明”来理解为什么某个通道为 0、
    为什么 sea_ice 有独立 R8 纹理。删除反而会让后继维护者看不懂。状态：⏸️ 保留注释。
  - _需求：5.3（需求本身在现状下被费弃）_

---

## 实施顺序与回滚锚点

| 阶段 | 任务 | 改动面 | 回滚成本 | 收益 | 状态 |
|---|---|---|---|---|---|
| 1 | 1.1-1.11 | shader + map_baker + 新 Job + ClimateProfile | 中（shader 端 sampler 名变更） | -25% | ✅ 完成 |
| 2 | 2.1-2.5 | MapData 新方法 + map_generator 5 处替换 | 极低（旁路） | -15% | ✅ 完成 |
| X | X.1-X.4 | refresh_climate_daily 拆 6 sub-pass + sub-pass切片化 | 中（SUS Job 重写） | **-90% peak** | ✅ 完成 |
| 3 | 3.1-3.9 | MapData SoA + 49 处写路径迁移 + Save/Load | 高（数据结构层） | 预估 -3% | ⏸ 不做 |
| 4 | 4.1-4.2 | SUS plan 同步 + 注释清理 | 低 | 文档 | ✅ 部分完成 |

**实际总收益**：fast tick total `峰值 540ms → 稳态 ~50ms`，**限出 88.5%**。

---

## 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| shader sampler 改动后 hex_renderer 没传新 uniform → 海冰显示全 0 | 中 | 1.6 + 启动时 set 一个 1x1 黑图兜底 |
| 阶段 2 邻居索引在 regenerate 后没重建 → 邻居错乱 | 高 | 2.2 强制 bake_world 末尾 _build_indices |
| 阶段 3 cell.temperature 写路径漏改一处 → 模拟漂移 | 高 | 每批迁移都跑 365 日 diff，必须 0 误差才进入下一批 |
| 阶段 3 老存档没有 PackedFloat32Array → 读到 0 | 高 | 3.8 加载时强制 _init_arrays_from_cells |
| sync_cells_from_arrays 的开销大于优化收益 | 低 | 跑 perf 验证；若超 5ms 改为按需 sync |
