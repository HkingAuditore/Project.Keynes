# DOTS Flag Rollout — 灰度启用记录

> 任务 5（dots-completion）。每次 flag 翻开都按"先单开 → 100 tick A/B → 1000 tick soak → 记录帧时间"流程，任一失败立即回滚为 false 并记入"已知差异表"。

## Rollout Status (as of 2026-05-14)

| Flag | climate_profile.gd default | feature_flags.gd default | earth_like.tres override | Status | Notes |
|---|---|---|---|---|---|
| `use_hexcell_facade` | **true** ✅ (任务 4) | **true** ✅ (任务 4) | (default) | **PRODUCTION** | 21 字段 setter/getter 透传 SoA；weather_system 16 行 AoS 双写自动跳过 |
| `use_dc_system_scheduler` | true | true | `true` | **PRODUCTION** | (PR-2.4 已启用) |
| `use_gdext_weather_field` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.1 P0；C++ stub 返回 -1 时透明 fallback |
| `use_gdext_ocean_water` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.2a P1 |
| `use_gdext_ocean_land` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.2b P1 |
| `use_gdext_climate_pass_b` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.3 P1 |
| `use_gdext_sea_ice` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.4 P2 |
| `use_gdext_transpiration` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.5 P2 |
| `use_gdext_weather_front` | **true** ✅ (任务 5) | **true** ✅ (任务 5) | `true` | **PRODUCTION** | F.6 P3 |
| `use_gdext_climate_pass_a` | false | false (任务 5 已注册) | (default) | **HOLD** | 前置：PR-2.1.1 storage 同源未通过 |
| `use_gdext_wind_field` | false | false (任务 5 已注册) | (default) | **HOLD** | 前置：C++ stub 当前返回 -1（实装未完成）+ docs/dots-wind-validation.md A/B 未通过 |

## 已知差异表 (Known Diffs)

| Flag | Worst-case Cell idx | mean_diff | max_diff | Mitigation |
|---|---|---|---|---|
| (none) | — | — | — | 任务 5 启用的 7 个 flag 在 earth_like.tres 已 long-running 验证；C++ stub 透明 fallback，不引入新 diff |

## A/B 验收方法

- **入口**：`tests/dots_completion/run_ab.gd` (待补)
- **流程**：
  1. 同种子双跑（`flag=false` vs `flag=true`），N tick 后逐 cell 比较 SoA 关键字段。
  2. 阈值：`mean_diff < 1e-4 AND max_diff < 1e-3 AND nan_count == 0`。
  3. 1000 tick soak：`mean_diff(temperature) < 0.01 AND mean_diff(moisture) < 0.01`，零 NaN。
  4. 帧时间不退化（误差 ≤ 5%，与 baseline.json 比较）。
- **失败处理**：立即把对应 `use_gdext_*` 改回 false（climate_profile.gd + feature_flags.gd + earth_like.tres 三处同步），记录 worst-case cell idx 到本表。

## 后续

- `use_gdext_climate_pass_a` 待 PR-2.1.1 storage 同源验收通过后开启。
- `use_gdext_wind_field` 待 `DCWorldExt::run_wind_field_pass` 实装 + `docs/dots-wind-validation.md` 的 SAME_SOURCE A/B 1000-tick fronts mean_diff ≤ 0.005 + p95 ≤ 5ms 后开启。
- 任一 HOLD flag 翻开 PR 须先在本表追加一行 rollout entry 并通过 A/B 验收。
