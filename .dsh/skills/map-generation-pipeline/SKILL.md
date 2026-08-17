---
name: map-generation-pipeline
description: >
  Project.Keynes 地图生成管线（base/post_base 地理生成 → HexCell 装配 → MapBaker.bake_world
  几何场/物理环流/纹理烘焙 → bind + 初始仿真 publish）的架构、C++↔GDScript 数据契约、pass 清单、
  扩展 SOP 与性能热点参考。**只要任务涉及地图/世界生成（generate / bake_world / 地形 / 河流 /
  火山 / 侵蚀 / 洋流环流 / 风场 / SLP / 温度 / 纬度场 / 纹理烘焙 / map_baker.gd / map_generator.gd /
  world_ext.cpp 里的 run_bake_*/run_native_world_generate_*/run_*_field_pass），或要把生成期计算
  从 GDScript 迁到 C++（dots-total-cpp）、新增一个 bake pass、排查生成耗时/视觉回归时，都应加载本
  skill**。它记录了已完成的迁移现状与"GDScript 只发请求+解包、C++ 算全部"的目标架构，避免重复 grounding。
---

# Project.Keynes 地图生成管线

本 skill 是 `Project.Keynes` 地图生成链路的领域知识库。核心理念（用户的"理想架构"）：

> **地图生成只有三阶段：① GDScript 发请求 → ② C++ 算完全部 → ③ C++ 返回结果、GDScript 只解包。**
> 所有 O(n_cells) / O(n_pixels) 热循环与中间数据都在 C++ 内；GDScript 侧只剩"解包"
> （`HexCell` 对象装配 + `ImageTexture` GPU 上传，都是 Godot 对象层、0 计算、不可迁）。

迁移代号 **dots-total-cpp**。权威设计文档：
`Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md`（改动后必须同步更新）。
开始任何生成相关改动前，先读它 + 本 skill，不要凭空假设。

## 关键文件

| 角色 | 路径 |
|---|---|
| 生成编排（GDScript） | `Project.Keynes/Project/project-keynes/scripts/geography/map_generator.gd` |
| bake 编排（GDScript） | `Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd` |
| C++ 权威实现 | `Project.Keynes/gdext/src/world_ext.cpp`（注意：大文件，用 grep 定位，勿整文件重写） |
| C++ 方法声明 | `Project.Keynes/gdext/src/world_ext.h` |
| C++ 方法绑定 | `Project.Keynes/gdext/src/world_ext_bind_methods.cpp` |
| 并行设施 | `Project.Keynes/gdext/src/parallel_dispatcher.h`（`pk::parallel_for_range`） |
| 设计文档 | `Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md` |

`gdext` 是 GDExtension：**改 C++ 后必须 rebuild DLL + 重启 Godot 才生效**。无法在本机编译时，
写好 C++ + GDScript wrapper 交用户编译。用户通常会跑一遍地图生成、贴日志/视觉结论来验证。

## 生成全链路（按时间顺序）

```
① MapGenerator.generate()
   └─ _generate_cells_native_base(cfg, seed)            [map_generator.gd]
        └─ run_native_world_generate_full_pass(seed,cfg,profile)   [C++，step4 融合]
             ├─ run_native_world_generate_base_pass      基础地理 SoA（cube/elev/moist/temp/terrain/landform/veg/cover）
             └─ run_native_world_generate_post_base_pass  Priority-Flood 水文/湖盆/河流 flow-accum/河岸生态/地标/水体变种
                                                          └─ 末尾把 river 拓扑暂存到 ext 成员 _gen_river_*
② _assemble_native_generation_map(final_res)            [GDScript 解包] new HexCell ×n + current_state（不可迁）
③ MapBaker.bake_world(map,cfg,hex_size,seed)            [map_baker.gd]
   ├─ _bake_geometry_fields_native()                    [step2 融合] 一次 run_bake_geometry_fields_pass：
   │     terrain-index → erosion → river SDF → latitude → volcano（中间 height 不跨语言）
   │     失败回退旧 per-pass 编排
   ├─ _bake_initial_physical_circulation → _physical_solve_for_phase
   │     └─ _physical_solve_native_oneshot()            [step3] 一次 run_physical_solve_pass：
   │           SLP → wind → PSI → upwelling（读 bound slot，仅生成期一次性路径）
   │           失败回退 _physical_solve_step_one 逐 stage loop
   ├─ encode：encode_height_tex / enum_atlas / flow_tex / r8(volcano)（C++ byte → GDScript 上传）
   │     cell_luts 不在这里烘 —— 它读 bound slot，此刻未 bind，见 ④
   ├─ VisionSolver.bake_static_fields()                  静态视野场 cell_view_height / cell_view_block
   │     此刻 SoA 未初始化（init_soa_from_bake 在 bake_world 返回后才跑），必须能从 HexCell 读
   └─ _bake_initial_vector_buffers（风/洋流像素 buffer 光栅化）
④ _setup_sus → bind_map_data（DCWorld + DCWorldExt）
   ├─ _publish_native_generation_from_slots → run_native_world_generate_pass  [C++] bind 后初始仿真温度场 republish
   ├─ run_deferred_initial_physical_circulation()   bake 期 defer 下来的物理环流
   └─ run_deferred_initial_cell_luts()              bake 期 defer 下来的四张 per-cell LUT
         encode_cell_luts 走 C++（此刻已 bind），读到的是 publish 后的权威气候值；
         enum_lut 是 RGBA8，A = 迷雾知识度 fog_k（未解算时恒 255）
```

**bind 前后是硬边界**：凡是读 bound slot 的东西（物理环流、`encode_cell_luts`）都不能在
`bake_world` 内部算 —— `bind_map_data` 要等 `bake_world` 返回、`init_soa_from_bake` 跑完
才发生，就地算 100% 退回 GDScript。统一用 defer 标志推到 ④，那里仍在 `generate()` 内，
早于渲染器绑定纹理。新增此类 pass 时照抄 `_initial_physical_deferred` /
`_initial_cell_luts_deferred` 这套模式，别在 bake 期临时判 `has_method` 了事。

**defer 会改变数据快照时点**，要顺带检查依赖：`fog_k_arr` 在 `init_soa_from_bake` 后
是"尺寸够但全 0"，与"全图未探索"无法区分，所以判据必须是 `MapData.fog_solved` 而不是
数组大小（踩过：`enum_lut.a` 均值从 255 掉到 0，首帧全图黑）。

## C++↔GDScript 数据传输三种机制

1. **knobs Dictionary**（GDScript→C++ 输入）：标量 + 少量 PackedArray。
2. **返回 Dictionary 里的 PackedArray**（C++→GDScript 结果）：bind 前的 pass 都走这个。
3. **bind 后 slot publish + `_flush_slot_to_map`**：C++ 写绑定 slot 并 flush 回 MapData，
   `published_to_slot=true` 时 GDScript 跳过重复拷贝。flush 用 `set()` reseat PackedArray，
   故 flush 后要 `rebind_map_data` 避免 scheduler/facade 持悬垂引用。

## 已 C++ 化的 pass 清单（生成期）

| pass（C++ 方法） | 作用 | slot 依赖 |
|---|---|---|
| `run_native_world_generate_base_pass` | 基础地理 SoA | 无（纯结果包） |
| `run_native_world_generate_post_base_pass` | 水文/湖/河/生态后处理 + 暂存河流拓扑 | 无 |
| `run_native_world_generate_full_pass` | base+post_base 融合（base bundle 不出境） | 无 |
| `run_bake_geometry_fields_pass` | terrain-index→erosion→river→latitude→volcano 融合 | 无（纯 buffer-encoder） |
| `run_bake_terrain_index_pass` | per-pixel height/biome/moist/veg/cover + Bayer dither + CSR | 无 |
| `run_bake_erosion_pass` | droplet 水力侵蚀（`Ref<RandomNumberGenerator>` 同 seed） | 无 |
| `run_bake_river_sdf_pass` | 读 `_gen_river_*` 拓扑 → trace+CR+warp(FastNoiseLite)+stamp+chamfer+归一化 | 无 |
| `run_bake_latitude_field_pass` | per-pixel ny | 无 |
| `run_bake_volcano_field_pass` | per-pixel 径向衰减 | 无 |
| `run_physical_solve_pass` | SLP→wind→PSI→upwelling 融合（生成期一次性） | **读 bound slot** |
| `run_slp_field_pass`/`run_wind_field_pass`/`run_psi_solver_pass`/`run_physical_circulation_pass` | 物理环流各 kernel | **读 bound slot**，published_to_slot |
| `run_native_world_generate_pass` | bind 后初始温度仿真场 republish | **读 bound slot** |

**已是 C++、刻意不动**：bind 后 republish（`run_native_world_generate_pass`）——删它不减少 GDScript
计算，只会重构脆弱的 bind/flush/rebind 时序，零收益高风险。

**仍在 GDScript（属"解包"，不可迁）**：`_assemble_native_generation_map`（HexCell 是 GDScript 脚本类）、
GPU 纹理上传（`ImageTexture.update`/`create_from_image`）。

**运行期不动**：物理环流季节切换的逐帧分摊路径（`ocean_currents_job.gd` 驱动
`_physical_solve_step_one`）保持不变——只迁了生成期一次性路径。

## Static research / bio occupancy

`run_research_signal_generation_pass` writes landform CSR only. Bio presence is
`cell.bio_occupancy_bits` from `run_bio_seed_pass`: UNIQUE_HEARTH species fill 100% of
envelope∩carrier on one origin landmass; vacant `habitat_class` niches on other
continent-scale landmasses get a matching secondary fill. Cosmopolitan reed covers
continent wetlands. Same-class origins repel; food and grazer guilds still share at most
one species per cell. Continent-scale landmasses keep a playable food + fiber/livestock
floor. Satellite islets are skipped unless they are the unique argmax. `realm.*` is
display metadata; seeding does not read it.

## 核心模式（写新 pass / 改 pass 时遵循）

详见 `references/patterns.md`。要点速记：

- **buffer-encoder pass 范式**：循环外解析 knobs（含尺寸校验、提前 return fallback），循环内用裸指针
  （`ptr()`/`ptrw()` + `__restrict`），返回统一 report `{ fallback, reason, path, elapsed_ms, <data...>, ... }`。
  初始 `out["fallback"]=true`，成功结尾才置 `false`。
- **融合 orchestrator 范式**（step2/3/4）：C++ 内按序调用已验证的子 pass，中间量经返回 dict / 读 slot
  在 C++ 内串联，**不跨语言往返**；GDScript 只发一次 combined knobs + 解包。
- **fallback 纪律**：用户要求"全 C++、不降级"时，wrapper 在 ext/方法缺失或返回 fallback 时
  `push_error` 返回空 buffer（不静默退回 GDScript 计算）；但**融合 pass 通常保留"融合优先 + 旧路径回退"**，
  让 DLL 未 rebuild 时仍能跑。两者区别按任务要求定。
- **三处必须同步**：`world_ext.h`（声明）+ `world_ext.cpp`（实现）+ `world_ext_bind_methods.cpp`（`ClassDB::bind_method`）。
  漏 bind → GDScript `has_method` 探测不到 → 走 fallback。
- **knobs 键名唯一**：同一 Dictionary 里键不能重名（踩过坑：`height` 既当维度又当 buffer → 用 `height_buffer`）。
- **bit-equal 不强求**：用户一般迁完自己验证；几何用 float 复刻 Godot `Vector2` real_t、scalar 用 double，
  噪声/RNG 用 Godot 同引擎实例（`FastNoiseLite`/`RandomNumberGenerator`）同 seed。

## 性能热点（截至 6400 cell / 高分辨率 heightmap 实测）

bake 总耗时大头**不是跨语言开销，是真实 per-pixel 计算**：
- `terrain-index` ~517ms（per-pixel warp 噪声+cube_round+dither，**单线程**）← 最大单点
- `encode` ~415ms（纹理 byte 编码 + GPU 上传）
- per-cell 装配 ~133ms（HexCell，不可迁）
- base/post_base/physical/river/erosion/volcano 都已 <20ms

**优化方向**：bake 期 per-pixel pass 是天然可并行的，用现成的 `pk::parallel_for_range`
（`parallel_dispatcher.h`，WorkerThreadPool 封装，climate/ocean pass 已在用）按行/像素切分；
terrain-index 并行预计 4–8x。降 `derived_size` 分辨率会让 terrain+encode 成比例下降（视觉权衡）。

## SOP：新增一个生成期 bake pass

1. **grounding**：读对应 GDScript ground-truth 实现 + 现有同范式 C++ pass + 设计文档。
2. **C++**：在 `world_ext.h` 声明、`world_ext.cpp` 实现（buffer-encoder 范式）、`world_ext_bind_methods.cpp` 绑定。
3. **GDScript wrapper**：native-first（`has_method` 探测）+ 按任务要求决定是否保留 fallback。
4. **文档**：更新 `computation-pipelines.md`（状态表 + 专节 + I/O 契约）。改到 LUT 通道布局、
   `encode_cell_luts` 入参或迷雾/国界视觉时，同步 `vision-fog-and-borders.md`；
   新增进存档的生成期产物时，同步 `game-flow-start-save.md` 的 section 清单。
5. **校验**：`read_lints` 两侧 0 错误；grep 确认方法名跨 `.h`/`.cpp`/bind/GDScript/doc 对齐；交用户编译跑 A/B。

## 验证清单（交付给用户编译后看日志）

- `geometry fields (fused C++): Xms` + `[fused] terrain=.. erosion=.. river=.. latitude=.. volcano=..`
- `[phys_solve][oneshot] OK slp=.. wind=.. psi=..(ran=true) upwelling=..`
- `[native_generation/base|post_base] path=gdext ...`
- 无 `fallback` / `push_error` / `phys_field_nan_guard>0`
- 视觉：地形/河流/火山辉光/海岸/洋流方向与迁移前一致
