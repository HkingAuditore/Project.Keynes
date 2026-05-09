# 每日模拟 SoA 重构 — 需求文档

> **背景**：当前 fast tick 总耗时约 430-490ms，其中 `refresh_climate_daily`
> 占 200-220ms，`weather_refresh` 占 100-160ms，`ocean_currents` 占 20-180ms（峰值）。
> 用户在 [019e0bb491fc79968e8eda9f3b3dede3] 中明确要求："没必要遍历像素级别的气候数据，
> 实际上我只关心六边形级别的气候数据。像素只和现实挂钩，唯一参与游戏逻辑的只有
> 六边形级别的数据。"
>
> 本计划是对该要求的"完整改造"实施方案，分三阶段交付：
>
> 1. **阶段 1：剥离 ice_bake → 模拟管线只剩纯六边形工作**
>    - 把 `bake_sea_ice_fraction_only` 整体从 `refresh_climate_daily` 摘出，
>      改为独立 SUS Job（`SeaIceAtlasUploadJob`），每 N tick 才上传一次
>    - 把 `scalar_atlas.a` 通道（sea_ice_fraction）拆分成独立 R8 纹理 `sea_ice_tex`，
>      减少 GPU 上传体积（RGBA8 → R8 即 -75% 字节量）
>
> 2. **阶段 2：邻居索引 SoA 化**
>    - `MapData` 增加 `neighbor_indices: PackedInt32Array(cells*6)` 与 `cell_index: Dictionary<HexCell,int>`
>    - 改造 31 处 `map.get_neighbors(cell)` 调用为 `map.iter_neighbors_by_index(idx, callback)` 或
>      直接读 `neighbor_indices`，避免每次创建新 Array
>
> 3. **阶段 3：核心字段 SoA 化**
>    - 把 `temperature / moisture / snow_cover / sea_ice_fraction` 4 个 fast-tick 热点字段
>      从 `HexCell` 移到 `MapData` 中的 `PackedFloat32Array`
>    - HexCell 上保留只读 getter（`temperature` 等）作为兼容层
>    - 写路径全部走 `MapData.set_temperature(idx, v)` 或直接索引数组

---

## 1. 整体目标与不变量

### 1.1 性能目标
- fast tick 总耗时（x1 档）：从 ~430ms 降至 ≤ 220ms（-49%）
- `refresh_climate_daily`：从 ~200ms 降至 ≤ 80ms（-60%）
- `ice_bake` 子段：从 ~105ms 降至 ≤ 25ms（-76%）+ 移出每日热路径
- 阶段 1 单独可交付 -25%，阶段 2 再 -15%，阶段 3 再 -10%

### 1.2 强制不变量（每个阶段都不得破坏）
- ✅ 同 seed 同 climate_profile 跑 365 日，模拟结果与基线 cell 字段值差 ≤ 1e-4
- ✅ 视觉无撕裂条纹、无半旧半新 atlas
- ✅ Save/Load 兼容性：阶段 3 改 SoA 后老存档应能加载（一次性迁移到 PackedArray）
- ✅ regenerate（按 R 键）路径：所有缓存（neighbor_indices / atlas buffer / packed arrays）正确失效重建
- ✅ SUS Job 调度自身开销 ≤ 0.2ms / tick

---

## 2. 阶段 1 需求 · ice_bake 剥离 + atlas 协议拆分

### 2.1 剥离 ice_bake 为独立 SUS Job
- **新增** `simulation/sus/jobs/sea_ice_atlas_upload_job.gd`：
  - id = `&"sea_ice_atlas_upload"`
  - priority = 250（晚于 ocean_currents 的 200）
  - policy 用 `StridePolicy(stride=climate_profile.sea_ice_atlas_upload_stride, default=2)`
  - 持有 `_baker, _map, _world` 引用
  - `run_slice(ctx)` 内部调用 `_baker.bake_sea_ice_fraction_only(_map, _world)` 并 `done=true`
- **从 `refresh_climate_daily` 中移除** `_baker.bake_sea_ice_fraction_only(...)` 调用
  （map_generator.gd line 2451）
- **MapGenerator._setup_sus** 中注册新 Job
- 视觉验收：x20 档跑 90 日，海冰可视化每 2 日推进一次（stride=2），玩家不可察觉延迟

### 2.2 atlas 协议拆分（sea_ice 独立 R8 纹理）
- **WorldData 新增** `sea_ice_tex: ImageTexture`（R8 LINEAR，derived_size）
- **map_baker `bake_sea_ice_fraction_only`** 改造：
  - 不再写 `_scalar_atlas_data_buf` 的 A 通道
  - 改为维护独立的 `_sea_ice_only_buf: PackedByteArray(n)`，每日 dirty water cells 写入
  - 上传到 `world.sea_ice_tex`（`Image.create_from_data(W, H, false, FORMAT_L8, ...)`）
- **scalar_atlas** 改回 RGB8（M=moisture / G=flow / B=latitude），地形烘焙后**永久不变**
- **shader 端**（`shaders/world_map.gdshader`）：
  - 新增 `uniform sampler2D sea_ice_tex : filter_linear, repeat_disable;`
  - 把读 `scalar_atlas.a` 的代码改为 `texture(sea_ice_tex, uv).r`（line 1080-1088 附近）
- **HexRenderer** `_apply_uniforms`：新增 `sm.set_shader_parameter("sea_ice_tex", _world.sea_ice_tex)`
- 性能预期：每日 GPU 上传字节量从 8.4 MB（RGBA8 7044x300）降至 2.1 MB（R8）

### 2.3 阶段 1 验收
- ice_bake 平均耗时从 105ms → ≤ 25ms（stride=2 + R8 上传）
- 但因 stride=2，每秒 ice_bake 平均频率 50%，**实际每秒摊薄到 ~12.5ms**
- 视觉：海冰可视化连续平滑无撕裂；x20 档跑 90 日肉眼无可察觉延迟
- 同 seed 365 日逐 cell 比对 sea_ice_fraction：差 = 0（纯渲染层改动）

---

## 3. 阶段 2 需求 · 邻居索引 SoA 化

### 3.1 MapData 增加邻居索引
- `MapData` 新增字段：
  - `_cell_array: Array[HexCell]`（按 cell_index 顺序存）
  - `_cell_index: Dictionary` (HexCell → int)
  - `_neighbor_indices: PackedInt32Array`（长度 = cells \* 6，无邻居处填 -1）
- `MapData._init` 末尾或 `MapGenerator.bake_world` 末尾调用一次 `_build_indices()`：
  - 遍历所有 cell，按插入顺序赋 idx；填 `_cell_array` / `_cell_index`
  - 对每个 cell，遍历 6 个 cube 方向查邻居，写入 `_neighbor_indices[idx*6+dir]`
- 新增 API：
  - `cell_count() -> int`（已有）
  - `cell_at(idx: int) -> HexCell`
  - `index_of(cell: HexCell) -> int`
  - `neighbor_index(idx: int, dir: int) -> int`（无邻居返回 -1）
  - `iter_cells() -> Array[HexCell]`（替代 `all_cells()`，但保持 `all_cells()` 不动以兼容下游）

### 3.2 替换 31 处 get_neighbors 调用
- 优先级 1（fast-tick 热路径）：
  - `_apply_sea_ice_daily_pass`（line 2541, 2581, 2603, 2674）
  - `_apply_ocean_heat_transport_pass`
  - `_apply_local_climate_coupling_pass`
  - 改为：
    ```gdscript
    var idx := map.index_of(cell)
    var nb_indices := map._neighbor_indices  # 直接读 PackedInt32Array
    for dir in range(6):
        var nb_idx := nb_indices[idx * 6 + dir]
        if nb_idx == -1:
            continue
        var nb := map.cell_at(nb_idx)
        ...
    ```
- 优先级 2（baker / weather_system / map_generator 其他位置）：可改可不改，性能影响小
- 不必"为改而改"——只改命中 fast tick 的 5-8 处，其余保持不动

### 3.3 阶段 2 验收
- `_apply_sea_ice_daily_pass` + `_apply_local_climate_coupling_pass` + `_apply_ocean_heat_transport_pass`
  合计耗时从 ~85ms → ≤ 30ms（-65%）
- 同 seed 365 日 cell 字段差 = 0（纯访问路径改动）
- regenerate 路径：`MapData._build_indices()` 在 `MapGenerator.bake_world` 末尾被调用一次，索引正确

---

## 4. 阶段 3 需求 · 核心字段 SoA 化

### 4.1 字段迁移范围（最小集）
仅迁移真正在 fast tick 中被读写、且**值是 float**的 4 个字段：
- `cell.temperature`
- `cell.moisture`
- `cell.snow_cover`
- `cell.sea_ice_fraction`

不迁移的字段（保持在 HexCell 上）：
- `temp_baseline / temp_season_offset`（仅 Pass A/B 读写一次，加速收益小）
- `temp_30d_mean / temp_365d_mean / temp_dev_from_annual`（EMA，每帧只算一次）
- `vegetation_vitality / vegetation / cover / landform / terrain`（语义复杂，不是 fast tick 真正瓶颈）

### 4.2 数据结构
- MapData 新增：
  ```gdscript
  var _temperature: PackedFloat32Array
  var _moisture: PackedFloat32Array
  var _snow_cover: PackedFloat32Array
  var _sea_ice_fraction: PackedFloat32Array
  ```
- 在 `_build_indices()` 中按 cell_count resize 并初始化
- 新增 setter/getter API：
  - `get_temperature(idx) -> float` / `set_temperature(idx, v)`
  - 4 字段对称，签名一致

### 4.3 兼容层（HexCell 渐进迁移）
- HexCell 上 4 个字段**保留**为成员变量，但作为**只读快照**，由 SoA 数组反向同步
- 每日 tick 末尾增加 `MapData._sync_cells_from_arrays()`：把 PackedFloat32Array 写回 HexCell 字段
- 这样下游所有读 `cell.temperature` 的代码（UI 面板、debug 视图、save/load）继续工作
- 下游写路径（`cell.temperature = v`）改为 `map.set_temperature(idx, v)`，HexCell 字段在 sync 阶段被覆盖

### 4.4 写路径迁移（map_generator.gd 49 处）
按文件分批迁移，**每批迁移完都要跑一次 365 日 diff 验证**：
- 批 1：`refresh_climate_daily` Pass A/B/ocean/sea_ice/transp（line 2393-2577 集中区，约 12 处）
- 批 2：`refresh_seasonal` 与季节决策（line 1063-2153 散落，约 18 处）
- 批 3：bake 阶段一次性赋值（line 587-1605 散落，约 15 处）
- 批 4：weather_system 与 baker（剩余 4 处）

### 4.5 Save/Load 兼容
- 老存档加载后，HexCell 字段仍有值；MapData 在 `_init_arrays_from_cells()` 中扫一遍 cells 把字段值塞进 PackedFloat32Array
- 新存档保存：以 MapData PackedFloat32Array 为权威；HexCell 字段不再单独序列化
- 提供过渡期 6 个月的兼容窗口

### 4.6 阶段 3 验收
- `refresh_climate_daily` Pass A 从 22ms → ≤ 8ms
- 全管线 `refresh_climate_daily` 从 ~200ms → ≤ 80ms
- 同 seed 365 日 cell 字段值差 ≤ 1e-4（浮点累积）
- 老存档可加载，加载后行为一致

---

## 5. 跨阶段共同约束

### 5.1 SUS 集成
- 不绕开 SUS：阶段 1 新 Job 必须挂在 SlicedUpdateScheduler，stride 通过 ClimateProfile 暴露
- 阶段 2/3 不引入新 Job，只是优化既有 Job 的 run_slice 内部实现

### 5.2 渐进式与可回滚
- 每阶段单独有 git commit 节点，allow `git revert` 单阶段
- 每阶段独立 perf-report 一节，跑完就填基线对照
- 阶段 1 不引入 SoA 概念；阶段 2 不引入 atlas 改动；阶段 3 不引入新调度行为

### 5.3 文档与命名
- plan 目录：`.codebuddy/plan/daily-sim-soa-refactor/`
- 性能埋点延用既有 SUS 打点格式 `[SUS] last 30 ticks: <job> ran=N avg=Xms ...`
- 注释里所有提到"sea_ice 在 scalar_atlas.a"的地方必须更新为"sea_ice 在 sea_ice_tex.r"

### 5.4 不做的事
- ❌ 不改 shader 计算逻辑（仅改 sampler 名）
- ❌ 不改 SUS 调度算法
- ❌ 不改既有 stride 字段名
- ❌ 不改 HexCell 上其他字段（landform/vegetation/cover/etc）
- ❌ 不引入多线程/Worker 并行

---

## 6. 实施顺序约束

1. **阶段 1 必须先做完并验证收益符合预期**，再决定是否启动阶段 2
2. **阶段 2 验证后**，再决定是否启动阶段 3
3. **不允许跳过阶段直接做阶段 3**（数据结构层改动必须建立在邻居访问已优化基础上）

---

## 7. 验收路径

### 阶段 1 验收
- ✅ x20 档跑 90 日，无可察觉海冰延迟
- ✅ ice_bake 平均 ≤ 25ms（之前 105ms）
- ✅ fast tick 总耗时 ≤ 350ms

### 阶段 2 验收
- ✅ x1 档跑 365 日 cell 字段 diff = 0
- ✅ fast tick 总耗时 ≤ 290ms

### 阶段 3 验收
- ✅ x1 档跑 365 日 cell 字段 diff ≤ 1e-4
- ✅ fast tick 总耗时 ≤ 220ms（用户最终需求 SUS plan 的目标）
- ✅ 老存档加载后可玩
