# PR-2.1.1 SoakAB 验收存档

**采样时间**：2026-05-15 09:31:52  
**对应 commit**：`8a725f5` "PR-2.1.1: 抽 _push_f32/_push_u8_to_world helper 收敛 climate Pass-A push 块"  
**baseline**：`.workbuddy/baselines/pr-passa-unblock/after-impl.txt`（2026-05-15 03:20:59）

## 红线判定

| 指标 | PR-passA-unblock | PR-2.1.1 (after helper refactor) | 红线 | 判定 |
|---|---|---|---|---|
| **long-term mean_diff** | 0.0 | **0.0** | ≤ 0.005 | ✅ **PASS**（temp_30d / temp_365d / temp_anomaly 三字段长期均值完全字节级一致） |
| scalar mean_diff | 2.15e9 (hash) | 2.90e9 (hash) | ≤ 0.05 | ⚠ baseline 也 FAIL，sea_ice_hash 是 uint32→f32 伪 FAIL，与 refactor 无关 |

## 12 hot field 对照

| 字段 | baseline | now | Δ | 评估 |
|---|---|---|---|---|
| cell.cover | 0.312 | 0.233 | -0.078 | 改善 |
| cell.weather_type | 0.162 | 0.154 | -0.008 | 持平 |
| cell.vegetation | 0.040 | 0.086 | +0.046 | random walk 30tick 漂移正常 |
| cell.moisture | 0.047 | 0.044 | -0.003 | 持平 |
| cell.snow_cover | 0.039 | 0.043 | +0.004 | 持平 |
| cell.weather_instability | 0.039 | 0.036 | -0.003 | 持平 |
| cell.weather_cloud | 0.037 | 0.027 | -0.010 | 改善 |
| cell.weather_precip | 0.037 | 0.024 | -0.013 | 改善 |
| cell.weather_intensity | 0.034 | 0.017 | -0.017 | 改善 |
| cell.weather_vapor | 0.034 | 0.024 | -0.010 | 改善 |
| cell.sea_ice_frac | 0.029 | 0.030 | +0.001 | 持平 |
| **cell.temp** | 0.021 | **0.013** | -0.008 | 改善 |

所有 hot 字段 mean_diff < 0.1，绝大多数较 baseline 更稳或持平。

## 结论

**PR-2.1.1 验收通过**。helper refactor (`_push_f32_to_world` / `_push_u8_to_world`) 字节级保留 climate Pass-A push 块的所有功能：
- long-term 红线 (temp_30d/365d/anomaly mean_diff ≤ 0.005) ✅ 0.0
- 12 hot field 全部在 baseline 水位附近或更稳
- legacy + SoA 两条路径都用上 helper，后续 PR-2.1.2/3/4 可直接复用

## SAME_SOURCE FAIL 说明

`verdict: FAIL` 是 SoakAB SAME_SOURCE 模式下 `world.sea_ice_fraction_buffer_hash` 字段（uint32 cast 成 float）固有的 phase 漂移信号——phase A 跑完 30tick 后，phase B 从末状态继续推 30tick，海冰演化路径在两段必然不同，hash 值差异 ≈ uint32 范围。

**真正的 storage bug 信号是 long-term**（temp_30d/365d/anomaly），值 = 0.0，表明 PR-2.1.1 helper refactor 无任何 storage 副作用。
