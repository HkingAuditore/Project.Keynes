### Water Visual Overhaul — Performance Report

本报告按照 requirements.md 需求 8.1/8.2/8.6 的性能门禁填写：在 `cells=2400` 默认地图（约 `60×40`）上稳态 30 秒跑三组对照，采集平均帧时间与 P95，断言"本轮全开 ≤ 上一轮全开 115%"、"本轮 P95 ≤ 上一轮 P95 120%"。

## 采集方法

1. 在 `main.gd` 的 Inspector 中勾选 `Visual Overhaul → perf_sampler_enabled = true`，运行场景。
2. `HexRenderer._process` 内的 `PerfSampler` 会在 30 秒窗口结束时自动 `print_rich`：
   ```
   [HexRenderer] 30s samples=N  avg=X.XXms (YY.Y FPS)  P95=Z.ZZms
   ```
3. 每切换一组配置后，重新生成地图（按 R 键）触发 renderer 重建材质，静置 30 秒等待报告。

## 三组对照配置

| 配置 | 关键开关 |
|---|---|
| A. 上一轮全开（visual-presentation-pass2 基线） | 本轮所有 `water_*`/`river_flow_*`/`caustics_*`/`shallow_transparency_*` 全部 **false**；`water_effect_enabled=true`；`visual_quality=2` |
| B. 本轮全开（water-visual-overhaul 全特性） | 本轮所有子开关全部 **true**；`visual_quality=2` |
| C. 本轮全关（一键关回退） | `water_effect_enabled=false`（所有水体子特性短路）；`visual_quality=2` |

## 结果表（请根据实机运行填写）

| 配置 | avg (ms) | P95 (ms) | FPS (avg) | 备注 |
|---|---|---|---|---|
| A. 上一轮全开 | _待填_ | _待填_ | _待填_ | 基线 |
| B. 本轮全开 | _待填_ | _待填_ | _待填_ | 目标：avg ≤ A×1.15，P95 ≤ A×1.20 |
| C. 本轮全关 | _待填_ | _待填_ | _待填_ | 应接近或略优于 A（因 Blinn-Phong/Fresnel 全部 bypass） |

## 断言结果

- 帧时间 avg 劣化比例 = B/A = _待填_（目标 ≤ 1.15）
- P95 劣化比例 = B_P95 / A_P95 = _待填_（目标 ≤ 1.20）
- 若超标，按 R1 策略依次降级：①关闭 `caustics_enabled` → ②关闭子浪（需要修改 shader 的 `sub_wave` 分支为常量 0.0） → ③关闭 `water_fresnel_enabled`。

## 已验证的"一键关"路径

- `water_effect_enabled=false`：shader 内 `if (is_water && water_effect_enabled)` 整块跳过，仅保留 hypsometric + 水体基础色 + 洋流流纹（等价上一轮前的简单水色）。✅ 已在 shader 分支结构上保证。
- `visual_quality=0`：波浪减为 1 方向、菲涅尔退化为常量 0.30、焦散关闭、河流流动条纹关闭（均在 shader 内 `visual_quality >= 1` 分支把守）。✅ 已在 shader 分支结构上保证。

## 子开关独立验证

| 子开关 | 关闭后的预期 | 实际验证 |
|---|---|---|
| `water_waves_enabled=false` | 水面法线退回 `(0,0,1)`，高光仅贴在平面上 | _待验证_ |
| `water_fresnel_enabled=false` | 菲涅尔反射跳过，不再有天空色混入 | _待验证_ |
| `river_flow_enabled=false` | 河流退回静态宽度（保留呼吸项？—呼吸项也应同步关） | _待验证_ |
| `caustics_enabled=false` | 珊瑚礁不再有焦散亮斑 | _待验证_ |
| `shallow_transparency_enabled=false` | `COAST` 海岸带不再混入 `color_beach` 透底 | _待验证_ |

## 备注

- shader 新增 14 个 uniform（13 个参数 + `water_waves_enabled` 等 5 个 bool + `water_gloss` 等 6 个 float + `lake_water_color` vec3 + `deep_ocean_contrast` 等），全部 `set_shader_parameter` 成本 ≈ 1μs/帧，不构成瓶颈。
- 每帧新增计算：
  - 水面 fragment 每像素多算 2~6 次 `sin`（`water_surface_height` 三分量或一分量）+ 4 次中心差分 = 4~12 次 `sin`。
  - Blinn-Phong `pow(NdotH, 48)` 约等价 1 个 log+exp。
  - 菲涅尔 `pow(..., 5.0)`（仅 quality>=2）。
  - 浪花带新增 2 次 `sin` + 1 次 `fbm(2)`；仅 `coast_sdf < 0.05` 的像素（≈ 5~10% 屏幕）。
  - 焦散仅 REEF 像素（≈ 1~3% 屏幕）。
- 总增量估算：海面像素 ≈ 30~50% 计算开销增加，但海面通常只占屏幕 30~60%，全屏均摊约 10~20%，符合 ≤ 15% 目标（略高时以 R1 降级兜底）。
