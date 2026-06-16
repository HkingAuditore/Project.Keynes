# Ocean Stage 诊断 cheat-sheet（Phase 2 of "稳/长期/性能" 计划）

## 跑 mobile bench 后该 grep 什么

### A. 稳态 SUS slice timing（最重要）

```
rg "ocean_currents/STAGE-DIAG" tmp/log.txt | head -30
```

每个 phys stage 在 mobile D 桶（stride=8 phase=0）每 8 tick 跑一次：
- 前 3 次 `init` 必打
- 之后只在 `elapsed_ms >= 5.0` 时打 `warn`

格式：
```
[ocean_currents/STAGE-DIAG] init tick=N round=M stage=X/<name> path=<gdext|gdscript|...> next=<name> 
    elapsed_ms=A.AA slp_native=B.BB psi_native=C.CC wind_dp95=... ocean_dp95=... slp_dp95=...
```

**判读**：
- `elapsed_ms < 1.0` → stage 在 SUS slice 上没问题（C++ wrapper 干净）
- `elapsed_ms 1-5ms` → 正常 wrapper overhead（iter_cells + Dict 构造）
- `elapsed_ms >= 5.0` → **真正的问题**，看 path + native 字段定位：
  - `path=gdscript` → DLL 没工作，全部 fallback
  - `path=gdext native < 1` → wrapper（refresh_slots / iter_cells / Dict）异常重
  - `path=gdext native >= 5` → C++ kernel 自己慢，看具体 stage 的 native ms

### B. baker stage wall timing（startup + SUS slice 共用）

```
rg "STAGE-TOTAL" tmp/log.txt
```

每个 stage 单独的 wall：
```
[slp_field/STAGE-TOTAL]    call#N wall=X.XXms native=Y.YYms path=... commit_ok=...
[wind_field/STAGE-TOTAL]   call#N wall=X.XXms native=Y.YYms path=... commit_ok=...
[upwelling/STAGE-TOTAL]    warn wall=X.XXms cpp=...           # only if >= 5ms after call#1
[upwelling/DIAG#1]         STAGE-TOTAL=X.XXms                  # call#1 only
[psi_iters/STAGE-TOTAL]    wall=X.XXms iters_done=K/40 ...    # 仅 fallback 路径出现
[psi_finalize/STAGE-TOTAL] wall=X.XXms ...                     # 仅 fallback 路径出现
[wind_raster/STAGE-TOTAL]  warn slice wall=X.XXms (pix S..E / total)  # mobile 不应触发
[psi_solver/BREAKDOWN]     call#N STAGE=X.XXms T1=... T2=... T3=... T4=...
```

**重要陷阱**：`call#1 wall` 被 Windows stdout flush 污染（path-decision / commit-diag / DIAG / ACTIVE 等 print 一行 ~12-15ms）。真实 stage 耗时只能从 `call# >= 4` 或 `warn` 路径读，那些已经命中 print budget 静音了。

### C. Fallback 信号（不该出现的）

如果 mobile DLL 工作正常，**这些都不应该出现**：

```
rg "psi_iters/STAGE-TOTAL|psi_finalize/STAGE-TOTAL" tmp/log.txt
```

→ 出现 = C++ PSI 失败，退回 GDScript SOR 40 iters + GDScript psi_to_ocean_current（很慢）。

```
rg "FALLBACK to GDScript" tmp/log.txt
```

→ 出现 = SLP / WIND / PSI / UPWELLING 任一 stage 退回 GDScript。

```
rg "wind_raster/STAGE-TOTAL" tmp/log.txt
```

→ mobile 上 Fix #1 已禁用 `_phys_need_visual`，**stage 7 不应该被进入**。出现 = 视觉禁用逻辑有 bug。

## 给 ocean async round 决策的判据

如果跑 30+ 仿真日 mobile bench 后：

### 情况 1：稳态 STAGE-DIAG 全部 < 1ms（**最理想**）
- B 路径分析正确：ocean 已 100% C++ 化
- **不做 ocean async round**（zero ROI）
- 转向找其他热点（renderer fragment / atlas upload / sea_ice / sus_scheduler 自身）

### 情况 2：稳态 STAGE-DIAG 全部 1-3ms，偶尔 5-8ms 峰值
- wrapper overhead 是 stable 的
- 偶发峰值很可能是 GC / page fault 类一次性
- **不做 ocean async round**，加 must_run=false 兜底防 budget 吃光

### 情况 3：某个 stage 持续 > 5ms
- 看 path 字段：
  - `gdscript` → 修 DLL 加载问题，或确认 has_indices() / heat_transport 等 gate
  - `gdext native < 1ms` → wrapper 慢，可能是 `refresh_slots_from_map` 或 `iter_cells` 或 Dict 构造
  - `gdext native ≥ 5ms` → 真正的 C++ kernel 慢，需要 SIMD / 优化 kernel 本身

### 情况 4：全部正常但 ocean 还是慢
- 看 `[ocean_currents/RT] pixel#N` 是否在 mobile 上仍然触发（应该 Fix #1 已禁用）
- 看 `_run_visual_slice` 是否在 commit-only slice 上花长时间

## 当前已落地的诊断 print 配额

| Stage | 前 N 次必打 | warn 阈值 |
|---|---|---|
| ocean_currents/STAGE-DIAG | 3 / stage | 5.0ms |
| slp_field/STAGE-TOTAL | 3 | 5.0ms |
| wind_field/STAGE-TOTAL | 3 | 5.0ms |
| upwelling/STAGE-TOTAL | 1 (legacy) + warn-only thereafter | 5.0ms |
| psi_solver/BREAKDOWN | 3 | 5.0ms |
| psi_iters/STAGE-TOTAL | 每次都打 | n/a (fallback only) |
| psi_finalize/STAGE-TOTAL | 每次都打 | n/a (fallback only) |
| wind_raster/STAGE-TOTAL | warn-only | 5.0ms |
