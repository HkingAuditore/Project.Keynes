# 脊抬升重构——实现契约（Agent Teams 内部规格）

> 配套：[terrain-ridge-uplift-plan.md](terrain-ridge-uplift-plan.md)（设计权威）
> 　　　[terrain-ridge-uplift-checklist.md](terrain-ridge-uplift-checklist.md)（进度权威）
> 本文件只固定「计划没说死」的接口与指标定义。**与计划冲突以计划为准**，§D 的裁决除外。

## §0 文件所有权（互不重叠）

| 所有者 | 文件 |
|---|---|
| `ridge-core` | `gdext/src/world_ext_generate_base.cpp`、`gdext/src/world_ext_internal.h` |
| `profile-plumbing` | `Project/project-keynes/scripts/data/climate_profile.gd`、`Project/project-keynes/scripts/geography/map_generation/native_generation_bridge.gd` |
| `ridge-metrics` | `Project/project-keynes/tests/world/ridge_drainage_metrics_test.gd`（**新建**） |
| root(lead) | 基线冻结/编译/标定/验收/文档、`tmp/p5_calib/**`、checklist |

**禁止**：改 `Project/perf-validation/**`（计划 §7 明确不同步）、post-base 任何 pass、bake 层、
`save_repository.gd`、存档 schema、`map_generator.gd` 的生成编排顺序。

## §A profile knob 契约（`native_generation_profile_dict` keys）

### A.1 新增（3 项，`climate_profile.gd` 加 `@export`，bridge keys 数组加名字）

| 键 | 类型/范围 | 默认 | 说明 |
|---|---|---:|---|
| `spl_ridge_uplift` | `@export_range(0.0, 0.20, 0.001)` | **0.012** | **每轮**脊抬升系数；14 轮累计 ≈ 14×该值×ridge_add |
| `spl_hillslope_diffusion` | `@export_range(0.0, 0.45, 0.005)` | **0.08** | 坡面扩散 κ（显式稳定上限 < 1，留足余量） |
| `ridge_residual_frac` | `@export_range(0.0, 0.30, 0.01)` | **0.15** | §5' 脊线残差比例（×`ridge_boost_amp`）；0 = 完全内生；**上限 0.30** |

### A.2 删除（已确认仅被删掉的分支消费，见 §D-3）

`climate_profile.gd` 的 `@export` 与 bridge keys 数组同步删除：
`spl_headroom_knee`（C++-only，GDScript 本就没有）、`erosion_droplet_factor`、`erosion_max_lifetime`、
`erosion_capacity`、`erosion_deposit_rate`、`erosion_erode_rate`、`erosion_evaporation`、`erosion_gravity`、
`erosion_min_slope`、`erosion_thermal_iters`、`erosion_thermal_talus`、`erosion_thermal_rate`。

### A.3 保留（语义不变）

`spl_iters`、`spl_erodibility`、`spl_area_exp`、`spl_uplift_rate`、`spl_headroom_frac`、
`ridge_boost_amp`、`ridge_debug_dump`（P5-0 加的诊断开关，见 §B）。

## §B 诊断输出（P5-0.1，已由 lead 落地，`ridge-core` **保留不动**）

- `profile["ridge_debug_dump"] = 1` 时 base pass 额外返回 `ridge_add_arr`（PackedFloat32Array, n）。
- 纯诊断：不参与计算、不改变任何输出数组。默认不传该键 → 行为逐位不变。
- `ridge-core` 改动后**必须继续支持**这个键，且语义仍然是「未乘预算缩放 g 的脊增量场」，
  对应新实现里 `§R` 算出的 `ridge_add`。

## §C M1–M5 定义（`ridge-metrics` 按此实现，lead 的标定脚本也用同一套）

公共前置（**同一份实现，基线/新版都用**）：
- 陆地格：`elevation_arr[i] >= sea_level`。
- 排水网：D6 邻接（`index_for_qr` 同款坐标：`col = q + (r - (r&1))/2`，经度环绕），
  在 **Priority-Flood 填洼后的面** 上取**最陡下降**受体；`proc` = 出栈序（下游先）。
- 汇水面积 `A[i]`：初值 1（单位=格），沿 `proc` 逆序累加到受体。
- `L[i]`：沿受体链到出口（`rcv<0`）的**步数**；`outlet[i]`：该链的出口下标。

| # | 指标 | 定义 | 目标（计划 §6.2） |
|---|---|---|---|
| M1 | 脊–水系一致性 | 陆地格 **Spearman(`ridge_add`, log10(`A`))**，取 `ridge_add > 0` 且 `A ≥ 1` | ≤ **−0.3**（基线预计 ≈0） |
| M2 | 脊坝盆地 | (a) 陆地 pit 格数：填洼面 > 原面 + 1e−6；(b) 其中 `ridge_add ≥ p75(ridge_add)` 的格数 | 较基线**降 ≥ 50%** |
| M3 | Hack 律 | 对 `A ≥ 100` 的格回归 `log10(L)` ~ `log10(A)`，斜率 h | ∈ **[0.5, 0.65]** |
| M4 | 流路直线度 | 对 `A ≥ 100` 的格，`L / euclid_dist(i, outlet[i])` 的均值（经度环绕取最短） | 较基线**上升** |
| M5 | 平顶率 | 陆地且 `elevation − sea_level > 0.6` 的格中，`max−min`(自身+6邻) < **0.02** 的比例 | 较基线**下降** |

辅助（§6.3 分布带，直接读 base/post 输出）：`water_count`/`land_count`、`terrain_arr` 直方图、
`landform_arr` 直方图、`lake_count`、`river_count`、`highland_river_count`、`stage_counts`、
陆地 `land_h = elevation − sea_level` 的 p50/p90/p99。

## §D 裁决（计划未覆盖处）

### D-1 「代表性 profile」用于标定
标定必须在**同一份显式 profile** 下前后对比，不能依赖 C++ 默认值。lead 的基线与标定统一用：
`native_generation_mode=2, ridge_boost_amp=0.60, spl_iters=14, spl_erodibility=1.2, spl_area_exp=0.45,
spl_uplift_rate=0.10, ridge_debug_dump=1` + 三个新键（基线里不含新键，走 C++ 缺省）。
cfg 统一：`num_continents=3, continent_size=0.9, sea_level=0.64, river_count=12`；
种子 = `20260718 + i`（60×40 取 i∈[0,32)，200×150 取 i∈[0,8)）。

### D-2 高度预算的口径
§3.5「统一缩放使 p99 落在 soft_max」沿用在用定义：
`soft_max = land_elev_cap − (land_elev_cap − sea_level) × 0.06`，
`land_elev_cap = max(0.93, sea_level + (1 − sea_level) × 0.94)`（与现 §5 同值，别新造）。
缩放**只对陆地**、对 `h = E − sea_level` 乘同一系数（保序）；系数 > 1 时不放大（只压不抬）。

### D-3 删除键的安全性（已由 lead 验证）
`erosion_*` 全部 11 个键在 `Project/project-keynes` 内**只**被 `climate_profile.gd` 的 export 与
`native_generation_bridge.gd` 的 keys 数组引用，无第三个消费者；`spl_headroom_knee` 只有 C++ 默认读取。
`Project/perf-validation/**` 里同名文件自带这些键，按计划**不同步**，C++ 忽略未知键即可。

### D-4 `spl+carve` 式的双模式回退**不提供**
计划 §2.3 明确「不保留旧算法、不做版本分派」。旧行为只能靠 git 回退，不设 knob。
但三个新 knob 提供了**强度调节**（`ridge_residual_frac=1.0` + `spl_ridge_uplift=0` 可近似回到
「脊在侵蚀之后」的老观感），用于 A/B 对照。

## §E 验证命令（root 执行）

```powershell
# 编译
cmd /c "`"%ProgramFiles%\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && scons platform=windows target=template_debug"   # workdir: gdext
# 指标（capture 模式产出 JSON 供 lead 与基线比对；assert 模式跑门禁）
cd Project/project-keynes
& '<GODOT_BIN>' --headless -s res://tests/world/ridge_drainage_metrics_test.gd
```
