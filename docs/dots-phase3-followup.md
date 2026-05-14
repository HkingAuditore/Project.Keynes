> **DEPRECATED 2026-05-14**：本文档已被
> [`dots-master-execution-handbook.md`](./dots-master-execution-handbook.md) §6 替代。
> Phase 3 巨石拆分完整方案（map_baker / weather_system / map_generator / main 共 50-65 PR）现集中在 master 手册。
> 本文档保留以便 git history 追溯，**不再维护**。

# Phase 3 — 巨石拆分 Follow-up 设计

> 状态：与 Phase 2 解耦，可与 Phase 2 并行启动；约 100 个 PR / 16 周
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §E / §G.2 / §G.3
> 创建：2026-05-14

---

## 0. 现状监控（启动前 baseline）

| 文件 | 当前行数 | Phase 3 目标 | 拆分子类数 |
|---|---|---|---|
| `map_generator.gd` | 5,241 | ≤ 200 | ~10 子模块 |
| `map_baker.gd` | 2,604 | ≤ 150 | 5 sub-baker |
| `weather_system.gd` | 2,495 | ≤ 150 | 5 facade |
| `main.gd` | 1,757 | ≤ 400 | 4 bootstrap + 1 panel controller |

完成后 4 个文件累计减少 ~9,000 行（搬到 ~25 个新文件，平均每个 < 400 行）。

---

## Phase 3.1 — map_baker 拆分（W7-W14，~30-40 PR）

### 骨架目录

```
scripts/rendering/bakers/
├── baker_context.gd          # 共享上下文（map / world / cfg / hex_size / atlases）
├── atlas_encoders.gd         # 静态 enum atlas 编码（最独立，先抽）
├── terrain_baker.gd          # 一次性烘焙
├── climate_baker.gd          # 增量重烘焙
├── weather_baker.gd          # 天气贴图
└── overlay_baker.gd          # data overlay
```

### 迁移顺序（roadmap §G.2 推荐）

按"独立性递减"顺序，每抽一个 sub-baker 都独立 PR + 截图像素 diff 验收：

1. **atlas_encoders**（5-8 PR）：抽 cell terrain enum / weather enum / vegetation enum 等的纯函数 atlas 编码
2. **terrain_baker**（8-12 PR）：bake_terrain_atlas / bake_passable_atlas / bake_river_atlas 等一次性 GPU upload
3. **climate_baker**（6-10 PR）：bake_temp_atlas / bake_moisture_atlas / bake_sea_ice_atlas 等增量重烘焙
4. **weather_baker**（5-7 PR）：bake_weather_field / bake_front_atlas / bake_precip_atlas
5. **overlay_baker**（3-5 PR）：data overlay 各 channel 的 bake

### 共享验收

- 每 PR 独立截图像素 diff < 0.1%
- SUS 30-tick avg ±3%

---

## Phase 3.2 — weather_system 拆分（W9-W14，~20-25 PR）

**前置**：Phase 1.2 SoA 化已就位（FRONTS_SCHEMA + pack/apply helpers ✅）。
**注意**：Phase 1.5 inline 后 [`simulation/systems/weather_system.gd`](../Project/project-keynes/scripts/simulation/systems/weather_system.gd)（DCSystem 调度）变成完整 system；本 phase 拆的是 [`weather/weather_system.gd`](../Project/project-keynes/scripts/weather/weather_system.gd)（业务 WeatherSystem）。

### 骨架目录

```
scripts/weather/
├── weather_system.gd       # 总入口（~150 行，仅 facade）
├── field_solver.gd         # weather field 7 字段求解（已 F.1 C++ 化的 GDScript fallback）
├── front_advect.gd         # 锋面推进（已 F.6 C++ 化）
├── front_spawn.gd          # 锋面生成 + 季节调制
├── feedback.gd             # weather → 慢层反馈
└── summary_builder.gd      # weather summary / debug breakdown
```

### 迁移顺序

1. **field_solver**（4-5 PR）：line 641-1024 范围已是独立函数集，整段抽取（已 F.1 C++ 化，搬迁是 GDScript fallback）
2. **front_advect**（3-4 PR）：line ~280-310（Phase 1.3 F.6 fast-path 与 fallback 路径都搬过去）
3. **front_spawn**（4-5 PR）：line ~310-450 季节生成 + ITCZ 偏置 + 类型决定
4. **feedback**（3-4 PR）：_apply_weather_to_map_feedback_pass + soil_moisture / vegetation_growth_pressure 累积
5. **summary_builder**（3-4 PR）：_last_breakdown / weather_summary / 各 _diag_* 段

### 共享验收

- 每 PR 独立 30-day soak bit-equal
- weather front 数 / 类型分布 / 视觉无 diff
- weather_system 残留 ≤ 150 行（仅 facade + tick 入口）

---

## Phase 3.3 — map_generator 拆分（W11-W20，~40-50 PR）

最大的拆分工作；与 Phase 2 并行启动。

### 骨架目录

```
scripts/simulation/
├── climate/
│   ├── pass_a.gd        # 已存在；抽剩余写路径
│   └── pass_b.gd        # 已存在
├── ocean/
│   ├── water_pass.gd    # 已存在
│   └── land_pass.gd     # 已存在
├── sea_ice/
│   └── daily_pass.gd    # 已存在
└── biology/
    └── transpiration_pass.gd  # 已存在

scripts/geography/
├── map_generator.gd          # ≤ 200 行（仅 facade + regenerate 入口）
├── map_generation/
│   └── terrain_gen.gd        # 一次性烘焙：terrain / landform / vegetation / cover
└── diagnostics_bus.gd        # 各 _last_*_breakdown 中央仓库
```

### 迁移顺序（roadmap §E.4-E.6 line range 已写好）

1. **terrain_gen**（最独立，6-8 PR）：line 1100-2400 一次性世界生成
2. **pass_a fallback** 完善（已存在文件，3-4 PR）：把 map_generator._climate_pass_a 完全搬过去
3. **pass_b fallback** 完善（同上，3-4 PR）
4. **water_pass / land_pass** 完善（同上，4-5 PR 各）
5. **sea_ice / transpiration** 完善（同上，3-4 PR 各）
6. **diagnostics_bus**（最后抽，3-4 PR）：承载所有 _last_*_breakdown / _gdext_*_runs 等运行时统计

### 共享验收

- 每 PR 独立验收 SUS 30-tick avg / p95 / slices ±5%
- 截图像素 diff < 0.1%
- map_generator.gd 残留 ≤ 200 行

---

## Phase 3.4 — main.gd 拆分（W13-W18，~15-20 PR）

**前置**：Phase 1.4 sus_systems_bootstrap 接口骨架已就位 ✅

### 骨架目录

```
scripts/bootstrap/
├── dots_bootstrap.gd            # DataCore CLI / runtime hot-toggle / flag snapshot
├── sus_systems_bootstrap.gd     # 已存在；本 phase 收尾真正搬迁注册逻辑
├── demo_bootstrap.gd            # demo_thermal_gradient / debug overlay 启动
└── visual_bootstrap.gd          # renderer / camera / hud 初始化

scripts/ui/
└── info_panel_controller.gd     # 选中地块面板 4 行 + emergent lines
```

### 迁移顺序（roadmap §G.3）

1. **dots_bootstrap**（3-4 PR）：DCWorld instantiate / bind / flag snapshot 段
2. **sus_systems_bootstrap**（3-5 PR）：把 generator._setup_sus 的 6 个 register_system 搬到本类的 bootstrap()；map_generator 那段保留 forward
3. **demo_bootstrap**（2-3 PR）：_run_demo_thermal_gradient_pass_if_enabled / set_field_verify_mode 等
4. **visual_bootstrap**（3-4 PR）：renderer / camera / hud / pause_btn / speed_btn
5. **info_panel_controller**（4-5 PR）：_refresh_weather_line / _refresh_vitality_line / _refresh_climate_line / _refresh_emergent_lines + _refresh_info_panel

### 共享验收

- main.gd 残留 ≤ 400 行（仅 _ready 顶级编排 + _on_day_changed fast-tick）
- fast-tick 函数残留 ≤ 50 行（理想：仅调度 + render sync + ui sync）

---

## Phase 3 总验收

```bash
# 巨石源文件行数（roadmap §4.2）
wc -l Project/project-keynes/scripts/{geography/map_generator,weather/weather_system,rendering/map_baker,main}.gd
```

期望：

| 文件 | 起始 | 目标 |
|---|---|---|
| map_generator.gd | 5,241 | ≤ 200 |
| weather_system.gd | 2,495 | ≤ 150 |
| map_baker.gd | 2,604 | ≤ 150 |
| main.gd | 1,757 | ≤ 400 |

- 30-day SUS 日志 avg / p95 / slices ±5%
- 截图像素 diff < 0.1%

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 100 个 PR 量大、跨多个月 | 每周 review 进度；可接受 Phase 3 持续到 Phase 4 之后（不阻塞阶段 III）|
| Phase 2 写路径下移与 Phase 3 拆分冲突 | 锁文件协议：拆分中的 sub-module 在 PR 描述里标"暂不接受写路径修改"，Phase 2 PR 跳过该模块直到拆完 |
| 拆分时丢失 cross-call（generator._climate_pass_a 这类 self.method 调用）| 每 PR 拆完后 `rg "func _<method>"` 与 `rg "_<method>\("` 双向校对调用图 |

---

**END.**
