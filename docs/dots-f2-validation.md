# F.2 ocean water + land — C++ 实装验收 SOP

> 状态：**算法已实装，等用户本地编译 + 启用 flag + 跑游戏验收**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §F.2 / [`performance-charter.md`](./performance-charter.md) §7 P1
> 模板：复用 [`dots-f1-validation.md`](./dots-f1-validation.md) + [`dots-f3-validation.md`](./dots-f3-validation.md) + [`dots-f5-validation.md`](./dots-f5-validation.md)
> 创建：2026-05-13

---

## 1. 这次 PR 改了什么

| 文件 | 改动 |
| ---- | ---- |
| `gdext/src/world_ext.h` | F.2a / F.2b 签名都收敛为 `Dictionary` 单参 + 详细 contract（含 anomaly_inout 双写设计）|
| `gdext/src/world_ext.cpp` | **替换 F.2 stub → ~270 行 C++**：water pass（advect chain + lerp）+ land pass（weighted nb anomaly sum + temp 累加）|
| `gdext/src/world_ext.cpp` (`_bind_methods`) | F.2 D_METHOD 都改成 `("knobs")` 单参 |
| `Project/.../geography/map_generator.gd` | `_ocean_water_pass_soa` + `_ocean_land_pass_soa` 头部加 fast-path + precondition probe + sig probe + DEBUG print + 共享 anomaly buffer cache（water 写完 land 复用，省一次 cells→array 拷贝）|

---

## 2. 验收 5 步走

### 步骤 1 — Rebuild gdext

```cmd
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
rebuild.bat
```

### 步骤 2 — 翻 2 个 flag

ClimateProfile `.tres`（你的 `earth_like.tres`）：

```gdscript
@export var use_gdext_ocean_water: bool = true   # 默认 false → true
@export var use_gdext_ocean_land:  bool = true   # 默认 false → true
```

**注意**：两个 flag 独立，可以单独开一个做 A/B 比对。如果只开 water 不开 land，C++ 会处理 water cell，land 走 GDScript 用 cells 里的 anomaly（无问题）。

记得 Ctrl+S 保存 .tres。

### 步骤 3 — 完全关闭 Godot 重启

### 步骤 4 — 启动后期望日志

```
[ocean_water/F.2a] precondition probe (one-time):
  active ClimateProfile = res://data/world/earth_like.tres
  cp.use_gdext_ocean_water = true
  _data_core_world_ext != null = true
  ext.has_method('run_ocean_water_pass') = true
  fast_indexed = true (n=2400 nb=14400)
  advect_steps=4 heat_mix=0.0500
  verdict = OK → will try C++
[ocean_water/F.2a] sig probe result = true（仅作诊断）
[ocean_water/F.2a] DEBUG call#1: rc=0.???? n=2400 advect=4
[ocean_water/F.2a] gdext path ACTIVE — first run elapsed=0.??ms (legacy GDScript baseline ≈ 3.4ms; charter §7 target < 0.5ms)

[ocean_land/F.2b] precondition probe (one-time):
  ... verdict = OK → will try C++
[ocean_land/F.2b] DEBUG call#1: rc=0.???? n=2400 effective_leak=0.????
[ocean_land/F.2b] gdext path ACTIVE — first run elapsed=0.??ms ...
```

### 步骤 5 — 跑 30-day soak

期望：
- `refresh_climate_daily` breakdown 内 `ocean=` 字段从 6.3-7.0ms 降到 < 1ms
- `refresh_climate_daily` total avg 从 8.54ms 降到 ~3-5ms
- `ocean_currents` job 不再被 `frame_budget_exhausted` 频繁 skip

把 `[fast tick WARN]` 完整一段 + `[SUS] last 30 ticks: refresh_climate_daily ran=...avg=...` 贴回。

---

## 3. 已知风险 / 简化

### 3.1 `anomaly_in.0 < 1e-5` 时 temp_a 不动（GDScript 等价）

**现状**：与 GDScript 一致——只在 anomaly 显著时才把扰动加到 temp_a。
**影响**：无（行为完全等价）。

### 3.2 `T[i] <= 0` 时 fallback 到 baseline（**已修复 2026-05-13**）

**原 bug**（首版 land pass C++ 实装时的"已知简化"）：
- 我用 `t_prev = max(T[i], 0)` 替代 GDScript 的 `t_prev = baseline_fallback`
- 触发正反馈：cell temp clamp 到 0 → +负 anomaly → C++ 算 `0 + (-anomaly)` = 负值 → 又 clamp 0 → 永久卡在 0
- 第二 tick F.3 读到 0 anomaly + 邻居 anomaly → 算更负 d_coastal → 沿海 cascading
- **2026-05-13 用户验收时 12 in-game year 后整图 temp = 0、weather 全 CLEAR、ocean 热输运全空白**

**修复**：
- C++ land pass 新增必填 `fallback_baseline_arr` 入参
- t_prev 兜底从 `max(T[i], 0)` 改为 `T[i] > 0 ? T[i] : fallback_baseline[i]`
- GDScript caller 复用 water pass 已计算的 `baseline_arr`（含 ema_init 分支 + `_compute_temperature` 兜底），通过新 cache `_gdext_ocean_baseline_arr_cached` 跨 pass 传递

**验收**（修复后）：
- 启 F.2b 后世界自动从 0 状态恢复 — 因为 t_prev=baseline (>0) 时 tnew = baseline ± anomaly 不会卡 0
- 已 corrupted 的 save 让 simulation 跑几个 tick 后自动愈合（温度场重新 settle）
- 如需立即看到正常温度，regenerate 一下地图或回到旧 save

### 3.3 `cell.temperature_transport_anomaly` 没有 SoA 镜像

**现状**：每次 water/land pass 在 GDScript 端做一次 `cells→PackedArray` (in) + `PackedArray→cells` (out) 拷贝。每次约 0.05ms × 2 = 0.1ms 开销。

**优化**：water + land 串联调用时 cache 中间 buffer，省 1 次拷贝（已实现：`_gdext_ocean_anomaly_buf_cached`）。

**长远**：F.x phase II 数据所有权下移 PR 中加 `cell_temperature_transport_anomaly` SoA mirror。

### 3.4 `cell.ocean_current` SoA stale 必须从 cells 提取（**已修复 2026-05-13**）

**bug**（首版 F.2 实装时遗漏）：
- C++ pass 直接读 `cell_ocean_current_x/y` slot
- 但 schema 里这俩 SoA 镜像由 `rebuild_soa_from_cells` 仅在世界生成时填一次
- `physical_circulation_solver` 每 round 改的是 `HexCell.ocean_current`，从来不回写 SoA
- C++ 拿到的是初始（多为 0 或近 0）值 → advect 方向几乎全是 fallback → temp_mixed = lerp(self, self, ...) ≈ self
- 结合 land pass 正反馈 bug（§3.2），全图温度雪崩到 0
- **2026-05-13 用户验收时 F.2 land 正反馈 + ocean_current stale 双重 bug 同时暴露，温度场 12 in-game year 后全部归零**

**修复**：
- C++ water/land pass 都新增必填 `ocean_current_x_arr` + `ocean_current_y_arr` 入参
- GDScript caller 每 tick 从 `cells[i].ocean_current.x/y` 提取到 PackedFloat32Array 传过去
- water + land 串联时 cache 这俩 buffer 复用（同 anomaly_buf 套路）

**教训**：参考 Demo Complex Pass 的对应历史 bug——bind_map_data 之后 CoW 已分裂，任何 GDScript→C++ 的字段同步必须显式做（`write_f32_range` 或 knobs PackedArray 入参），不能假设 SoA slot 与 GDScript 写入自动一致。

---

## 4. 性能预算回填（charter §7 表 1）

| 项 | charter 目标 | 落地状态 |
| -- | ----------- | -------- |
| ocean water pass N=2400 | 3.4ms → < 0.5ms | ⏳ 等用户验收数字 |
| ocean land pass N=2400  | 3.4ms → < 0.5ms | ⏳ 等用户验收数字 |
| `refresh_climate_daily` 内 `ocean=` 字段 | 6.8 → < 1ms 总 | ⏳ 等 fast tick WARN 详细行 |

跑完一次 30-tick soak 后请把以下贴回：
- `[ocean_water/F.2a] gdext path ACTIVE — first run elapsed=X.XXms`
- `[ocean_land/F.2b] gdext path ACTIVE — first run elapsed=X.XXms`
- `[fast tick WARN]` 行内 `refresh_climate_daily ran=...ms ...ocean=X.X` 的 ocean 数字

---

## 5. 下一个 PR 入口（顺位剩余 2 个）

| 优先级 | PR | 工作量 | 期望收益 |
| ----- | -- | ----- | ------- |
| **P2** | F.4 sea_ice daily C++ 化 | 3-5 天（含 terrain ECB 翻转）| 5.1ms → 0.5ms |
| **P3** | F.6 weather front C++ 化 + front pool DOTS 化 | 1 周 | 3.0ms → 0.5ms |

F.4 是下一站。F.6 因为牵扯 front pool DOTS 化（POOL_WEATHER_FRONTS 升为权威），单独一周工程量。

---

## 6. 出 bug 时怎么找我

按现有套路，把以下 4 段贴回：
1. `[ocean_water/F.2a] precondition probe` 全文
2. `[ocean_land/F.2b] precondition probe` 全文
3. `[ocean_water/F.2a] DEBUG call#N: rc=...` 前 3 行
4. `[ocean_land/F.2b] DEBUG call#N: rc=...` 前 3 行

如果 rc<0，同时贴 `[DCWorldExt] run_ocean_*_pass: <reason>` warning。

如果开了 F.2 后温度场有视觉异常（沿岸 cell 暖/冷化方向反了等），关掉 land flag 单独验 water；问题在 water 时把异常 water cell idx + (temp before/after, anomaly before/after) 贴回。
