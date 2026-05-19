---
name: sea-ice-and-snowline-tuning-plan-c
overview: 采用方案 C（保持 ice_state_atlas 独立，不与 dyn_atlas_smooth_atlas 合并），通过 climate_profile 阈值调参 + CPU/Shader 雪线公式同步收窄 + 海冰量化兜底，修复"海冰几乎不出现"和"地块要么常年有雪要么常年无雪"两个表现问题。
todos:
  - id: locate-shader-anchors
    content: 使用 [subagent:code-explorer] 精确定位 snow_cover.gdshaderinc 的 cold_lo/cold_hi、climate_season.gdshaderinc 的 season_temp_amp（如有）、map_baker.gd 的海冰 byte 写入行
    status: completed
  - id: tune-climate-profile
    content: 修改 climate_profile.gd 默认值：season_temp_amp、sea_ice_freeze/melt_rate、terrain_threshold/hysteresis、form/melt_threshold 共 7 项，并同步注释
    status: completed
    dependencies:
      - locate-shader-anchors
  - id: sync-snow-formula
    content: 同步修改 _derived_snow_cover（CPU）与 apply_snow_cover（Shader）的雪线带宽 [0.30, 0.48] 与强度 0.55，保持 SAME_SOURCE
    status: completed
    dependencies:
      - tune-climate-profile
  - id: tune-sea-ice-shader
    content: 调整 water_pipeline.gdshaderinc 海冰 smoothstep 阈值为 (0.02, 0.85)；如 climate_season.gdshaderinc 存在 season_temp_amp 常量则同步为 0.32
    status: completed
    dependencies:
      - tune-climate-profile
  - id: fix-ice-quantization
    content: 在 map_baker.gd::rebake_ice_state_atlas 中为非零海冰 fraction 添加 max(1, ceil(...)) 量化兜底，不改全局 _q01_byte
    status: completed
    dependencies:
      - tune-climate-profile
  - id: verify-runtime
    content: 运行游戏验证：高纬海域冬季海冰可见、雪线随季节南北推移、单 cell 全年完整循环；按需准备 P0/P1/P2 分档回滚
    status: completed
    dependencies:
      - sync-snow-formula
      - tune-sea-ice-shader
      - fix-ice-quantization
---

## 产品概述

针对 Project Keynes 真实地形模拟中"海冰几乎不出现"和"地块降雪全有或全无（雪线不随季节移动）"两个视觉表现问题，按方案 C（保持 `ice_state_atlas` 独立纹理不合并）进行调参 + 公式微调，让海冰能在高纬冬季稳定形成、雪线能在地图上随季节南北推移。

## 核心特性

- 雪线在年度气温循环中真实移动：高纬地块经历"满雪 → 退雪 → 满雪"循环，中纬地块出现春秋过渡态
- 海冰在高纬海域冬季稳定可见：从微量结冰（fbm 撕碎）→ 厚冰（terrain 翻转）→ 融化的完整年度循环
- CPU 端 `_derived_snow_cover` 与 Shader 端 `apply_snow_cover` 保持 SAME_SOURCE 一致
- 不改架构、不改调度、不改 atlas 通道布局，仅参数和阈值调整，可逐项回滚

## 技术方案概览

### 实现策略

方案 C：保持 `ice_state_atlas` 独立 R8 纹理（不与 `dyn_atlas_smooth_atlas` 合并），在**逻辑参数 + Shader 阈值**两层做对称调整，根因聚焦在"温度场年振幅 0.20 << 雪线带宽 0.26"的结构性失衡。

### 关键技术决策

| 决策 | 选择 | 理由 |
| --- | --- | --- |
| 合并纹理？ | **不合并** | 海冰边缘要 fbm 撕碎，雪盖边缘要 box-blur 平滑，滤波需求相反 |
| 优先调参 vs 改公式 | **先调参** | 改动 ~15 行，无 schema 变化、无调度变化，可快速 A/B |
| CPU/Shader 同步 | **强制 SAME_SOURCE** | SHADER_DEV_GUIDE.md 硬约定，雪线公式必须双侧一致 |
| C++ 路径处理 | **不改 C++** | `DCWorldExt.run_sea_ice_daily_pass` 参数从 `climate_profile` 读取，自动跟随 |
| 量化损失修复范围 | **仅海冰写入路径局部 ceil** | 不改全局 `_q01_byte`（避免影响 temp/moist/snow/vitality 其他通道） |
| 数值激进度 | **采用激进档** (`season_temp_amp 0.32`, `freeze_rate 0.32`) | 用户已批准；保守档（0.28 / 0.25）作为回滚备选 |


### 性能与可靠性

- 改动范围：~15 行实质代码，无新系统、无 schema、无调度变更
- 性能影响：忽略不计（仅 baker 中海冰写入处多 1 次 `max(1, ceil(...))` 计算）
- 回滚成本：所有数值集中在 `climate_profile.gd`（6 处）+ 雪盖公式 2 处 + shader 阈值 3 处，可按 P0/P1/P2 分档回滚

### 实施要点（执行细节）

1. **SAME_SOURCE 严格对齐**：`_derived_snow_cover`（CPU）的 `smoothstep` 阈值必须与 `apply_snow_cover`（Shader）的 `cold_lo/cold_hi` 在去掉 jitter 后的中心值一致。雪线收窄到 [0.30, 0.48]，强度系数同步从 0.50 抬到 0.55。
2. **shader 端 `season_temp_amp` 常量定位**：先在 `climate_season.gdshaderinc` 中精确定位是否存在该常量；存在则同步改为 0.32，不存在（即 shader 不直接消费此常量，温度通过 `dyn_atlas` 间接传递）则跳过此项，避免无效改动。
3. **量化兜底语义**：`rebake_ice_state_atlas` 中仅当 `frac > 0.0` 时使用 `max(1, int(ceil(clamp(frac, 0, 1) * 255)))`，保证微量海冰首日可见；`frac == 0` 时仍写 0，避免水域全黑像素被错误抬到 byte=1。
4. **dirty cache 兼容**：ceil 兜底改变 byte 值时会自然触发 dirty cache 更新，无需调整 `_last_ice_state_cell_bytes` 字典逻辑。
5. **不污染其他通道**：`_q01_byte` 工具函数本身**不改**——只在海冰路径局部使用新的 ceil 公式（snow/temp/moisture/vitality 仍走旧量化）。
6. **C++ fallback 链验证**：确认 `_apply_sea_ice_daily_pass` 优先走 `DCWorldExt.run_sea_ice_daily_pass`，C++ 侧通过 `climate_profile` 字段读取参数；本次只改 GDScript 默认值，C++ 自动跟随，无需重新编译扩展。
7. **earth_like.tres 不改**：避免在用户配置文件中硬编码这些调优值，让 `climate_profile.gd` 默认值成为单一来源。
8. **日志策略**：调试期建议在 `_apply_sea_ice_daily_pass` 末尾加 1 条按低频采样（每 30 日一次）的统计日志（max_fraction / fraction>0 cell 数），不夯爆 log。本次任务不强制加，留作可选。

### 验证策略

- 跟随单个高纬海域 cell 跑一年（year_progress 0.0→1.0），应观察到完整的"无冰 → 薄冰（fbm 撕碎）→ 厚冰（B_SEA_ICE 翻转）→ 融化"循环
- 极地海域（ny≈0.05）冬季 `sea_ice_fraction` 应达到 0.6+
- 高纬陆地（ny≈0.15）`snow_cover` 春季应从 1.0 衰减至 ~0.3
- 中纬陆地（ny≈0.40）`snow_cover` 全年应在 [0, 0.5] 间往复
- 视觉验证：地图全景下应能看到雪线南北推移

## 目录结构（涉及文件）

```
Project/project-keynes/
├── scripts/
│   ├── data/
│   │   └── climate_profile.gd                # [MODIFY] 调整 6 个默认值（season_temp_amp / sea_ice_*）
│   ├── geography/
│   │   └── map_generator.gd                  # [MODIFY] _derived_snow_cover 内 smoothstep 阈值与强度
│   └── rendering/
│       └── map_baker.gd                      # [MODIFY] rebake_ice_state_atlas 海冰量化兜底（局部 ceil）
└── shaders/include/
    ├── snow_cover.gdshaderinc                # [MODIFY] apply_snow_cover 中 cold_lo/cold_hi 同步
    ├── water_pipeline.gdshaderinc            # [MODIFY] compute_water_biome_weights 海冰 smoothstep 阈值
    └── climate_season.gdshaderinc            # [MODIFY?] 若存在 season_temp_amp 常量则同步；不存在则跳过
```

### 改动总览（6 文件，~15 行实质代码）

**`scripts/data/climate_profile.gd`** [MODIFY]

- 行 109：`season_temp_amp: 0.20 → 0.32`（P0-1）
- 行 505：`sea_ice_freeze_rate: 0.18 → 0.32`（P1-1）
- 行 506：`sea_ice_melt_rate: 0.22 → 0.40`（P1-1）
- 行 507：`sea_ice_terrain_threshold: 0.55 → 0.40`（P1-1）
- 行 508：`sea_ice_terrain_hysteresis: 0.10 → 0.12`（P1-1）
- 行 668：`sea_ice_form_threshold: 0.07 → 0.10`（P2）
- 行 669：`sea_ice_melt_threshold: 0.12 → 0.16`（P2）
- 同步更新各字段的 GDScript 注释中提到的旧默认值（避免文档漂移）

**`scripts/geography/map_generator.gd::_derived_snow_cover`** [MODIFY]

- 函数体内 `cold_snow` 表达式：`smoothstep(0.26, 0.52, temp_now) × 0.50` → `smoothstep(0.30, 0.48, temp_now) × 0.55`
- 顶部注释更新雪线带宽说明（提及与 shader SAME_SOURCE 锚点）

**`shaders/include/snow_cover.gdshaderinc::apply_snow_cover`** [MODIFY]

- `cold_lo = 0.26 + jitter` → `0.30 + jitter`
- `cold_hi = 0.52 + jitter` → `0.48 + jitter`
- 强度系数（与 CPU `× 0.55` 对齐）若 shader 端有显式系数则同步抬高
- 顶部 SAME_SOURCE 注释指向 `_derived_snow_cover`

**`shaders/include/water_pipeline.gdshaderinc::compute_water_biome_weights`** [MODIFY]

- 行 197：`smoothstep(0.05, 0.95, ice_frac + (ridge_n - 0.5) * 0.18)` → `smoothstep(0.02, 0.85, ice_frac + (ridge_n - 0.5) * 0.18)`

**`shaders/include/climate_season.gdshaderinc`** [MODIFY?]

- 由 planner 子代理在执行前精确定位 `season_temp_amp` 常量；存在则 `0.20 → 0.32`，不存在则跳过此文件
- 若存在但语义为"shader 内独立振幅"（不消费 GDScript 端 SAME_SOURCE），同样需同步以保持一致性

**`scripts/rendering/map_baker.gd::rebake_ice_state_atlas`** [MODIFY]

- 海冰 byte 写入逻辑：当 `frac > 0.0` 时使用 `max(1, int(ceil(clamp(frac, 0, 1) * 255.0)))`，确保 fraction ∈ (0, 1/255) 也能产生 byte=1（消除微量海冰量化吞没）
- `frac == 0.0` 时仍写 0（避免水域全黑像素被误抬）
- 不修改 `_q01_byte` 全局工具函数（保持其他通道不变）

## 不在本次改动范围

- 不合并 `ice_state_atlas` 到 `dyn_atlas_smooth_atlas`（方案 C 核心）
- 不修改 box-blur 平滑（`rebake_dyn_atlas_smooth` 保持原貌）
- 不改 SUS 调度（`SeaIceAtlasUploadJob` stride=2 日不变）
- 不改全局 `_q01_byte` 工具函数
- 不改 C++ `DCWorldExt.run_sea_ice_daily_pass`（自动跟随 GDScript 参数）
- 不修改 `earth_like.tres`（保持极简覆盖原则）

## Agent Extensions

### Skill

- **civ-grounded-development**
- Purpose: 在执行任何修改前强制完成"读优先、理解优先"流程，确保 SAME_SOURCE 双侧对齐、不引入新子系统、复用现有 climate_profile 配置入口
- Expected outcome: 改动严格限定在已确认的 6 个文件、~15 行实质代码内，无架构变更、无调度变更、无 schema 变更

### SubAgent

- **code-explorer**
- Purpose: 在执行 P0-2 同步阶段，精确定位 `shaders/include/climate_season.gdshaderinc` 中是否存在 `season_temp_amp` 常量、`shaders/include/snow_cover.gdshaderinc` 中 `cold_lo/cold_hi/jitter` 的精确表达式、`scripts/rendering/map_baker.gd::rebake_ice_state_atlas` 中海冰 byte 写入的实际行号与上下文
- Expected outcome: 给出每处改动的精确行号、变量名、上下文片段，避免改错位置或遗漏 SAME_SOURCE 同步点