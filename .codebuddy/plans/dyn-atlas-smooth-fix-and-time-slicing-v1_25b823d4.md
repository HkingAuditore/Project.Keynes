---
name: dyn-atlas-smooth-fix-and-time-slicing-v1
overview: 修复 `rebake_dyn_atlas_smooth` 的邻居感知 sig bug（C），并把 `DynamicVisualAtlasUploadSystem.tick()` 改造成"细粒度时间切片"状态机（D，每 tick ≤500 cells），消除每 stride 日 ~15-20ms（移动端预估 ~80-120ms）的烘焙尖峰，确保桌面无感、手机平滑。
todos:
  - id: explore-baker-chunk-boundaries
    content: 使用 [subagent:code-explorer] 摸清 5 个 baker（dynamic_cell / ecology_visual / dyn_atlas_smooth / ice_state / wet_mark）的 buffer 字段 / cache dict / pixel_list 来源 / finalize 触发条件，产出对照表
    status: completed
  - id: implement-neighbor-aware-sig
    content: 在 map_baker.gd 实现 `_dyn_smooth_neighborhood_sig` FNV-1a 28-byte 哈希，修复邻居感知问题（方案 C 核心）
    status: completed
    dependencies:
      - explore-baker-chunk-boundaries
  - id: refactor-bakers-to-chunk-api
    content: 将 5 个 baker 拆出 chunk_begin / chunk_step / chunk_finalize 三段式接口，原 `rebake_*_only` 改为薄包装，保持签名与返回 Dictionary 完全兼容
    status: completed
    dependencies:
      - explore-baker-chunk-boundaries
  - id: rewrite-system-state-machine
    content: 重写 DynamicVisualAtlasUploadSystem.tick() 为 phase+cursor 状态机，引入 MAX_CELLS_PER_TICK / enable_time_slicing / aggregated_report，遵循 SUS done/progress_ratio 协议
    status: completed
    dependencies:
      - refactor-bakers-to-chunk-api
      - implement-neighbor-aware-sig
  - id: add-diagnostics-and-fallback
    content: 添加诊断字段（_total_ticks_used / avg_phase_ms 采样打印）与 enable_time_slicing=false 回退路径，复用现有 _wf_diag_* 风格
    status: completed
    dependencies:
      - rewrite-system-state-machine
  - id: verify-and-tune
    content: 运行 synthesize_world + ≥60 仿真日，验证视觉无回归、单 tick elapsed_ms ≤ 0.9ms、stride 跨 tick 数合理，按需调整 MAX_CELLS_PER_TICK
    status: completed
    dependencies:
      - add-diagnostics-and-fallback
---

## 用户需求

针对"地图烘焙体系移动端性能压力"问题，本期聚焦两项可立即落地的优化（方案 C + 方案 D），E 方案（MultiMesh 装饰层）单独成 plan，本次不涉及。

## 核心改造

### C. 邻居感知签名（Neighbor-aware Signature）—— 鲁棒性修复

- 修复 `rebake_dyn_atlas_smooth` 现有 dirty 比对的隐性精度损失问题：当前用"输出 byte 拼接"作 sig，int 除法 + clampi 量化可能淹没真实的邻居变动，造成视觉滞后。
- 改造为"自己 4-byte + 6 邻居 4-byte 共 28-byte 稳定哈希"作 cache sig，自动捕获邻居变动。
- 同时复用 `_last_dynamic_cell_sigs` 缓存避免邻居 sig 重算。

### D. 细粒度时间切片（Time-Sliced Baking）

- 把 `DynamicVisualAtlasUploadSystem.tick()` 从"一锤子 6 步全跑"重写为 phase + cursor 状态机；
- 每 tick 在 budget 内推进，单 tick 最多扫 ~500 cells；
- baker 端新增 `*_chunk` 子集调用入口，仅在 phase 完成时（`finalize=true`）触发 GPU upload；
- 一轮 stride 跨 ~5-10 tick 完成；dirty cell 少时几乎瞬完。

## 验收

| 指标 | 当前 | 目标 |
| --- | --- | --- |
| 桌面单 stride tick 峰值 | ~15-20ms | ≤ 5ms |
| 移动端单 stride tick 峰值（估） | ~80-120ms | ≤ 25ms |
| 单 tick `elapsed_ms` | 不受控 | ≤ 0.9ms（≈ 2× slice_budget_ms） |
| 视觉一致性 | smooth 邻居滞后 | smooth 邻居 1 tick 内可见 |


## 非目标

- 不改分辨率 / `HM_MAX_DIM`（方案 B 独立 plan）
- 不引入 MultiMesh 装饰层（方案 E 独立 plan）
- 不动 shader / weather_field / sea_ice 旧路径
- 不引入 GPU partial upload（Godot 4 `ImageTexture` 无 partial 接口，本期接受整张 update）

## Tech Stack

- 沿用现有 Godot 4 GDScript + DCSystem / SUS 调度框架
- 不引入任何新依赖、新插件、新文件类型

## 实施策略

### 一、调度协议（沿用现有 SUS 切片契约）

`DCSystem` 已支持切片协议：`tick()` 返回 `{done: false, progress_ratio: 0.x}` 即让出；`done: true` 表示本轮结束、由 `StridePolicy` 决定下一轮何时启动。本方案不动框架，只把单个 system 内部从 one-shot 改成 state-machine。

### 二、状态机设计（DynamicVisualAtlasUploadSystem）

新增 system 内字段：

- `_phase: int`（0..6；0=idle/start_of_stride, 1=wet_drought, 2=dynamic_cell, 3=ecology_visual, 4=dyn_smooth, 5=ice_state, 6=wet_mark）
- `_phase_cursor: int`（当前 phase 已处理的 cell 索引）
- `_phase_cell_keys: Array[HexCell]`（每 phase 入口快照 `map.all_cells()` 或 dirty 子集，避免迭代器中断风险）
- `_total_ticks_used: int`（诊断：一轮 stride 跨几 tick）
- `_aggregated_report: Dictionary`（合并 5 个 baker 的 dirty_cells / pixels_written 累计值，stride 结束时一次性回报）
- 常量 `MAX_CELLS_PER_TICK = 500`（可调）

`tick()` 主循环：

```
1. 若 _phase == 0：进入新 stride，初始化所有 cursor / aggregated_report，_phase = 1
2. while _phase <= 6 and elapsed < soft_budget:
     - 调用对应 phase 的 chunk handler，处理 ≤ MAX_CELLS_PER_TICK 个 cell
     - 若 phase 内 cursor 到末尾 → 调用对应 baker 的 finalize（仅触发 ImageTexture.update）→ _phase++
     - 否则 break 让出
3. 若 _phase > 6 → done=true，回写 _aggregated_report；_phase 归 0
4. 否则 done=false，progress_ratio = _phase/6 + 子进度
```

时序契约保持不变：phase 顺序就是当前 tick 内的顺序（wet/drought → dynamic_cell → ecology → smooth → ice → wet_mark），smooth 永远在 dynamic_cell 完整 finalize 之后才开始。

### 三、Baker chunk 化（map_baker.gd）

5 个 baker 当前都是"遍历 `map.all_cells()` → 比对 sig → 写 buffer → 一次 ImageTexture.update"的单函数。改造方式：**保持现有 `rebake_*_only` 函数 100% 行为不变（全量入口仍可用）**，**额外提供 chunk 接口**：

每个 baker 拆出三个函数（以 `rebake_dyn_atlas_smooth` 为例）：

- `dyn_atlas_smooth_chunk_begin(map, world) -> Dictionary`：分配 / 校验 buffer，返回 ctx（含 `W/H/n/cache_valid/use_pixel_lists`）
- `dyn_atlas_smooth_chunk_step(map, world, ctx, cells: Array, &report: Dictionary)`：处理传入的 cell 子集，更新 buffer + cache
- `dyn_atlas_smooth_chunk_finalize(world, ctx, &report)`：若 dirty → 触发 `ImageTexture.update`

原 `rebake_dyn_atlas_smooth` 重写为 `chunk_begin → chunk_step(all_cells) → chunk_finalize` 的 thin wrapper，保证既有调用方（`synthesize_world` 初始烘 line 540-542）零行为变化。

### 四、Neighbor-aware Signature（方案 C 核心）

`_dynamic_cell_signature(cell) -> int` 现产出 32-bit packed RGBA（保留）。新增：

```
# 28-byte 稳定哈希：自己 RGBA + 6 邻居 RGBA（缺邻按 0），FNV-1a 32-bit。
func _dyn_smooth_neighborhood_sig(cell: HexCell) -> int:
    var h: int = 0x811C9DC5
    var c: int = _dynamic_cell_signature(cell)
    h = ((h ^ (c & 0xFF)) * 0x01000193) & 0xFFFFFFFF
    h = ((h ^ ((c >> 8) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
    h = ((h ^ ((c >> 16) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
    h = ((h ^ ((c >> 24) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
    for nb in map.get_neighbors(cell):
        var ns: int = 0 if nb == null else _dynamic_cell_signature(nb)
        # 4 byte fold-in 同上
        ...
    return h
```

dyn_smooth chunk_step 内：

- 用 `_dyn_smooth_neighborhood_sig(cell)` 作 cache key 比对 `_last_dyn_smooth_cell_sigs[cell]`
- 若命中 cache → 整 cell skip（包括邻居均值计算，~70% CPU 省下）
- 不命中 → 走原 RGBA 邻居均值算法，写 buffer，更新 cache

**复用 dynamic_cell 缓存**：因为 phase 顺序保证 dyn_smooth 跑时 `_last_dynamic_cell_sigs[nb_cell]` 已是本轮最新值，邻居 sig 直接查 dict 即可，无需重新计算 `_dynamic_cell_signature(nb)`。需在 dyn_smooth chunk_begin 时打 flag `cache_dynamic_fresh = true`，否则 fallback 重算。

### 五、性能与正确性分析

**复杂度**：

- 现状：每 stride 一次 tick，6 个 baker 串行扫 `N_cells = 2400`，dyn_smooth 额外 ×7 邻居访问 → 主成本约 `O(6N + 6N) = 12N` GDScript op
- 改造后：cache 命中时 dyn_smooth 单 cell `O(1)` 哈希比对，未命中才 `O(7)` 计算；典型日 dirty < 30 → 实际 op 量 ~ `N + 30*7 ≈ 1.01N`，**降 10×+**
- 切片：单 tick 工作量限 500 cells → 桌面 ≤ 0.5ms / 移动端 ≤ 3ms 预估

**正确性边界**：

- phase 跨 tick 期间，cell 状态可能被其它 system 写（climate / weather daily）。但 `DynamicVisualAtlasUploadSystem.priority = 250`（晚于 climate=100/weather=150/ocean=200），且 stride=2 → 一轮 stride 内一般不会被打断；即使被打断，因为 sig 比对发生在 chunk_step 实时读 cell 字段，新值会进入 dirty，下一轮会自然修正
- `_phase_cell_keys` 在 phase 进入时快照 `map.all_cells()`，防止迭代过程中 cell 集合变化（典型不会变，地图初始化后 cell 数固定）
- GPU upload 必须等 phase 完整 finalize 才触发，绝不能跨 tick 在中间 update（中间状态会撕裂）

**回归保护**：

- 保留 `rebake_*_only` 全量入口的现有签名和行为，`synthesize_world` 初始烘路径完全不动
- 新增 `_total_ticks_used / phase / phase_cursor` 字段到回报 dict，原有 `*_dirty_cells / *_ms / wet_mark_writes` 字段在 stride 完成 tick 仍然返回（累计值），中间 tick 返回部分进度
- 提供 feature flag：`var enable_time_slicing: bool = true`，false 时走旧 one-shot 路径（紧急回退用）

## Implementation Notes

- **日志**：复用现有 baker `report` Dictionary 模式；新增 `phase / phase_cursor / total_ticks_used` 字段，**仅在 done=true 时**打 1 行 `print_rich` 汇总（沿用 `dynamic_visual_atlas_upload` id），避免每 tick 输出造成日志洪水
- **性能护栏**：`MAX_CELLS_PER_TICK` 设为常量便于后续按 `visual_quality` 档位区分；当前固定 500，留 TODO 注释指向未来联动点
- **诊断**：扩展 `_wf_diag_*` 同模式新增 `_dvas_diag_ticks_per_stride / _dvas_diag_avg_phase_ms`，每 30 stride 打 1 行均值（采样模式，0 额外热路径开销）
- **GDScript 类型**：`Array[HexCell]` 在 4.x 必须显式声明，避免 dynamic dispatch；`Dictionary[HexCell, int]` 保留现状（GDScript 不支持类型化 dict key，已是性能上限）
- **Blast radius**：5 个 baker 的 chunk_begin/step/finalize 全部独立，互不耦合；任何一个 phase 出错可单独回退到旧函数路径

## Architecture

```mermaid
flowchart TD
    A[SUS Scheduler] -->|stride=2, every 2 sim-days| B[DynamicVisualAtlasUploadSystem.tick]
    B --> C{_phase}
    C -->|0| D[init stride: snapshot cells, reset cursors, aggregated_report]
    C -->|1| E[wet/drought chunk_step ≤500 cells]
    C -->|2| F[dynamic_cell chunk_step]
    C -->|3| G[ecology_visual chunk_step]
    C -->|4| H[dyn_smooth chunk_step<br/>neighbor-aware sig + cache reuse]
    C -->|5| I[ice_state chunk_step]
    C -->|6| J[wet_mark chunk_step]
    E -.cursor done.-> F
    F -.cursor done + finalize ImageTexture.update.-> G
    G -.finalize.-> H
    H -.finalize.-> I
    I -.finalize.-> J
    J -.finalize.-> K[done=true, return aggregated_report]
    K --> A
```

## Directory Structure

```
Project/project-keynes/
├── scripts/
│   ├── simulation/systems/
│   │   └── dynamic_visual_atlas_upload_system.gd  # [MODIFY] 重写 tick() 为 phase+cursor 状态机
│   │                                              #   - 新增字段：_phase / _phase_cursor / _phase_cell_keys
│   │                                              #     / _aggregated_report / _total_ticks_used / enable_time_slicing
│   │                                              #   - 常量 MAX_CELLS_PER_TICK = 500
│   │                                              #   - 6 phase 状态机；每 tick 在 soft budget 内推进
│   │                                              #   - finalize 时机严格遵循"phase 完整结束才 GPU upload"
│   │                                              #   - feature flag false 时走旧 one-shot 路径（回退）
│   └── rendering/
│       └── map_baker.gd                           # [MODIFY] 5 个 baker 拆出 chunk_begin / step / finalize
│                                                  #   - rebake_dynamic_cell_atlas_only：现函数改为薄包装
│                                                  #   - rebake_ecology_visual_atlas_only：同上
│                                                  #   - rebake_dyn_atlas_smooth：同上 + 引入
│                                                  #     _dyn_smooth_neighborhood_sig(cell) FNV-1a 哈希
│                                                  #     + cache_dynamic_fresh 标志复用 _last_dynamic_cell_sigs
│                                                  #   - rebake_ice_state_atlas：同上（仅水域）
│                                                  #   - rebake_wet_mark_atlas：同上（仅陆地）
│                                                  #   - 保持原全量函数签名 / 返回 Dictionary 字段完全一致
│                                                  #   - 新增诊断 _dvas_diag_* 字段（采样模式打印）
```

## Key Code Structures

```
# DynamicVisualAtlasUploadSystem 状态机骨架
const MAX_CELLS_PER_TICK: int = 500
const PHASE_IDLE := 0
const PHASE_WET_DROUGHT := 1
const PHASE_DYNAMIC := 2
const PHASE_ECOLOGY := 3
const PHASE_SMOOTH := 4
const PHASE_ICE := 5
const PHASE_WET_MARK := 6
const PHASE_DONE := 7

var _phase: int = PHASE_IDLE
var _phase_cursor: int = 0
var _phase_cell_keys: Array = []
var _phase_ctx: Dictionary = {}   # 当前 phase baker 的 chunk ctx
var _aggregated_report: Dictionary = {}
var _total_ticks_used: int = 0
var enable_time_slicing: bool = true

func tick(_ctx) -> Dictionary

# MapBaker chunk 接口（每 baker 一组，签名一致）
func dyn_atlas_smooth_chunk_begin(map: MapData, world: WorldData) -> Dictionary
func dyn_atlas_smooth_chunk_step(map: MapData, world: WorldData,
        ctx: Dictionary, cells: Array, report: Dictionary) -> void
func dyn_atlas_smooth_chunk_finalize(world: WorldData,
        ctx: Dictionary, report: Dictionary) -> void

# Neighbor-aware sig（C 核心）
func _dyn_smooth_neighborhood_sig(map: MapData, cell: HexCell) -> int
```

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 在 plan 执行阶段定位 `rebake_dynamic_cell_atlas_only` / `rebake_ecology_visual_atlas_only` / `rebake_ice_state_atlas` / `rebake_wet_mark_atlas` 四个未深读 baker 的精确边界（buffer 字段名、cache dict 名、is-water 判定路径），避免 chunk 拆分时遗漏字段或重复初始化。
- Expected outcome: 产出"5 个 baker 的字段 / cache / buffer / pixel_list_source"对照表，确保 chunk 化时签名一致、无遗漏初始化、无误删旧路径。

### Skill

- **civ-grounded-development**
- Purpose: 强制 read-first 流程，在动手前先核对 `map_baker.gd` 5 个 baker 的实际行为差异（dirty 判定细节、buffer 复用方式、GPU upload 触发条件），并复用现有 dirty 基建而非新建子系统。
- Expected outcome: 改造方案严格沿用现有 cache / pixel_list / report Dictionary 模式，无新增子系统、无破坏既有调用方。