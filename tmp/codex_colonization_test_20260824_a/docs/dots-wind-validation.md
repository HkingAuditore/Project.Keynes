# DOTS Block B —— Wind Solver C++ 化验收方案

> **Master 手册** §4（Block B）：ocean_currents wind solver C++ 化（gdext run_wind_field_pass）
> **Status**：Phase-1 infrastructure ready；Phase-2 C++ implementation deferred。
> **Last update**：2026-05-14

---

## 1. 背景

`PhysicalCirculationSolver.solve_wind_field`（`scripts/rendering/physical_circulation_solver.gd`）
是 ocean_currents bake 流水线的核心 stage（`_PHYS_STAGE_WIND`），负责：

- 纬度风基线（西风带 / 信风带 / 极地东风）×（来自 wind_belt.gd）
- 压力梯度风（−∇slp，含 Coriolis 偏转）
- 海陆季风（沿海格 BFS 距离衰减）
- 山地绕流偏转（_WIND_MOUNTAIN_DEFLECT_W = 0.85）
- 地形摩擦（陆地 0.85 / 山地 0.55 / 丘陵 0.85）

实测性能（dots-master-execution-handbook §3.3 ground truth，2400 cells）：

| metric | 数值 | 备注 |
|--------|------|------|
| 单 cell mean | ~6 μs | 小负载稳定 |
| stage total（均值）| ~12.55 ms | 30-tick 窗口 |
| stage total（p95）| **35.55 ms** | 高峰 spike |
| budget 上限 | 5 ms | charter §7 P1 |

**结论**：在切片 budget 内偶尔超预算 7×，是 ocean_currents tick warning 的主要来源之一。

---

## 2. Phase-1：Infrastructure（已完成）

本次 PR（master 手册 Block B Phase-1）已就位：

### 2.1 ClimateProfile flag

```gdscript
# scripts/data/climate_profile.gd
@export var use_gdext_wind_field: bool = false      # Block B P1：35.55ms → < 5ms
```

### 2.2 MapBaker C++ hook

```gdscript
# scripts/rendering/map_baker.gd
func set_world_ext(ext) -> void:
    _world_ext = ext

# _physical_solve_step_one() 内 _PHYS_STAGE_WIND：
if profile.use_gdext_wind_field and _world_ext != null \
    and _world_ext.has_method("run_wind_field_pass"):
    var rc = _world_ext.run_wind_field_pass({...})
    if rc >= 0.0:
        _wind_done_by_cpp = true
if not _wind_done_by_cpp:
    PhysCircSolverScript.solve_wind_field(map, ...)
```

### 2.3 MapGenerator 注入

```gdscript
# scripts/geography/map_generator.gd
if _baker != null and _baker.has_method("set_world_ext"):
    _baker.set_world_ext(_data_core_world_ext)
```

### 2.4 默认行为

- `use_gdext_wind_field = false` → 永远走 GDScript path
- `_world_ext == null`（gdext 未加载）→ 永远走 GDScript path
- `run_wind_field_pass` 不存在 / 返回 -1 → 退回 GDScript path

**零行为回归保证**：开启 flag 但 C++ stub 未实现时仍走 GDScript。

---

## 3. Phase-2：C++ Implementation（deferred）

### 3.1 触发条件（master 手册 §3.3）

至少满足以下一个：

1. ocean_currents stage p95 持续 > 30ms 影响游戏体验
2. Phase 3.3 map_generator 拆分完成后 wind solver 移到 simulation/ocean/wind_solver.gd
   并通过 SAME_SOURCE A/B 验收
3. 用户主动启用 use_gdext_wind_field=true 进行 dev 验证

### 3.2 C++ 实现路径

`gdext/src/world_ext.cpp` 新增：

```cpp
// 入参 knobs Dictionary：hex_size, bounds_x0/y0/w/h, season_phase, terrain_aware
// 返回 float：耗时 ms（>= 0 表示成功 + 已写 SoA）；-1 表示未实现 / fallback
double DCWorldExt::run_wind_field_pass(const Dictionary& knobs) {
    // 1. 校验 _bound + slot 存在（slp/wind_x/wind_y/wind_speed/landform/elevation/...）
    // 2. 读 SoA 指针：_slot[CELL_SLP].arr_f32.ptr() 等
    // 3. 实现 5-stage 算法（与 GDScript solve_wind_field 1:1）
    //    a) 纬度基线（wind_belt.gd const 表 → C++ const）
    //    b) ∇slp 计算（每 cell 6 邻居）
    //    c) Coriolis 偏转（latitude → angle）
    //    d) 季风渗透（沿海 BFS / per-cell distance LUT）
    //    e) 山地偏转（grad-based mountain detect）
    // 4. 写 wind_x_arr/wind_y_arr/wind_speed_arr（ptrw + flush_slot_to_map）
    // 5. 返回 elapsed ms
}
```

### 3.3 验收 Protocol

#### 3.3.1 SAME_SOURCE A/B（基础正确性）

```bash
# Phase A：use_gdext_wind_field=false 跑 30-tick → user://soak/wind_A.tsv
# Phase B：use_gdext_wind_field=true 跑 30-tick → user://soak/wind_B.tsv（同一 seed / 同一 phase）
# 验收：F3 触发 DCSoakABRunner.SAME_SOURCE
```

通过条件：

| 字段 | 阈值 | 备注 |
|------|------|------|
| cell.wind_x | mean_diff ≤ 0.005 | 风方向 east/+ |
| cell.wind_y | mean_diff ≤ 0.005 | 风方向 south/+ |
| cell.wind_speed | mean_diff ≤ 0.005 | 风强度 |
| cell.slp | mean_diff ≤ 0.001 | 上游不变（同 GDScript path）|
| cell.ocean_psi | mean_diff ≤ 0.005 | ψ 是 wind_stress_curl 下游 |
| cell.ocean_current_x/y | mean_diff ≤ 0.005 | curl(τ) → ψ → 海流 |

#### 3.3.2 1000-tick fronts mean_diff（长期稳定性）

```
weather front spawn / advect 路径读 cell.wind_vector → 累积偏差不超过 0.005
```

#### 3.3.3 性能（charter §7 P1）

- p50 ≤ 1ms
- p95 ≤ 5ms
- p99 ≤ 8ms

### 3.4 风险登记

| 风险 | 概率 | 缓解 |
|------|------|------|
| C++ floating-point 与 GDScript 不严格 bit-equal | 高 | 接受 mean_diff ≤ 0.005，不要求 bit-equal |
| 山地 BFS 在 C++ 内分配开销 | 中 | 用 thread_local 缓冲 + cell.index 直查 |
| Coriolis 角公式微小差异 | 中 | 写一个 GDScript-C++ 对照单测 |
| 季风 BFS 早期种子依赖顺序 | 中 | 严格按 cell.index 升序遍历种子 |
| _world_ext == null 边界 | 低 | Phase-1 已防御 |

---

## 4. Phase-3：默认开启（远期）

完整通过 Phase-2 验收 + 持续 1 周无 wind 相关 issue 后：

1. ClimateProfile.use_gdext_wind_field 默认 → true
2. 旧 GDScript path 加 `@deprecated` 注释（保留至 Phase III 拆分时移到 archive/）
3. master 手册 Block B 状态 → DONE，记入 dots-framework-status.md

---

## 5. 与其它 ocean_currents stages 的关系

ocean_currents 总耗时 = SLP + WIND + ψ + UPWELLING + WIND_RASTER

| stage | 当前耗时 | C++ 化优先级 | flag |
|-------|----------|---------------|------|
| SLP | ~5ms | 低（已可接受）| 暂无 |
| **WIND** | **5-15ms（p95=35ms）** | **高（本文档）** | **use_gdext_wind_field** |
| ψ_INIT | ~3ms | 中 | 待加 |
| ψ_ITERS × 5 | ~10ms | 低（已切片）| 待加 |
| ψ_FINAL | ~3ms | 低 | 待加 |
| UPWELLING | ~5ms | 低 | 待加 |
| WIND_RASTER | ~3ms | 低 | 待加 |

Block B 仅覆盖 WIND stage；其他 stage 视性能 baseline 决定。

---

## 6. 引用

- `docs/dots-master-execution-handbook.md` §4（Block B）
- `scripts/rendering/physical_circulation_solver.gd` `solve_wind_field`
- `scripts/rendering/map_baker.gd` `_physical_solve_step_one` _PHYS_STAGE_WIND
- `gdext/src/world_ext.cpp` 待加 `run_wind_field_pass`
- charter §7 P1（性能 budget）
