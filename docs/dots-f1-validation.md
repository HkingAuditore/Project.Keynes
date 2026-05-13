# F.1 weather field solve — C++ 实装验收 SOP

> 状态：**算法已实装，等用户本地编译 + 启用 flag + 跑游戏验收**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §F.1 / [`performance-charter.md`](./performance-charter.md) §7 P0
> 创建：2026-05-13 / 责任：weather + co-processor 联调

---

## 1. 这次 PR 改了什么

| 文件 | 改动 |
| ---- | ---- |
| `gdext/src/world_ext.h` | F.1 签名收敛为单 `Dictionary` 入参；详细 contract 文档 |
| `gdext/src/world_ext.cpp` | 替换 F.1 stub → ~520 行真实算法（8 个 anon-ns helper + 主循环 1:1 mirror `weather_system.gd:678-757`） |
| `gdext/src/world_ext.cpp` (`_bind_methods`) | F.1 D_METHOD 签名改成 `("knobs")` 单参 |
| `Project/.../weather/weather_system.gd` | + `configure_gdext_acceleration()` setter<br>+ `set_field_verify_mode()` setter<br>+ `_build_weather_field_knobs()` / `_try_run_weather_field_solve_gdext()` / `_pull_gdext_field_results_to_next()` / `_verify_gdext_field_against_gdscript()` / `_run_weather_field_gdscript_loop_inplace()` 5 个 helper<br>+ `run_weather_field_solve_slice()` 头部 GDExt fast path 分支 |
| `Project/.../geography/map_generator.gd` | DCWorldExt bind 完成后自动调 `_weather_system.configure_gdext_acceleration(ext, cp.use_gdext_weather_field)` |
| `docs/dots-migration-roadmap.md` | F.1 行从 "stub" 改为 "实装完成 / 待用户编译验收" |

---

## 2. 验收 5 步走（用户本地）

### 步骤 1 — 编译 GDExtension

```powershell
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
scons platform=windows target=template_release dev_build=no -j8
# 或者 charter §0 的 release-with-debug：
# scons platform=windows target=editor dev_build=yes -j8
```

确认产物 `gdext/bin/*.dll` 时间戳是新的。

### 步骤 2 — 打开 use_gdext_weather_field flag

编辑 `Project/.../scripts/data/climate_profile.gd`（或修改任何继承的 ClimateProfile 资源 `.tres`）：

```gdscript
@export var use_gdext_weather_field: bool = true   # 从 false 改 true
```

ClimateProfile 资源里其他相关 flag：
- `use_data_core: bool = true`（必须 true 才会 instantiate DCWorldExt）

### 步骤 3 — 启游戏，观察启动日志

期望看到：

```
[DataCore] _data_core_world_ext bound=true (climate co-processor; class=DCWorldExt)
[weather] gdext acceleration ON (use_gdext_weather_field=true; class=DCWorldExt)
```

如果看到 `gdext acceleration requested but ext lacks run_weather_field_solve_pass` —— GDExt 没 rebuild，回到步骤 1。

### 步骤 4 — 跑 30 个 in-game day 看 SUS 日志

期望看到 `weather_refresh` 这一行的 `avg` 从 ~13ms 跌到 ~2ms 以内。
配合 `[fast tick WARN]` 行的 `sus=` 总耗时也应同步降。

### 步骤 5 — A/B 运行时验证（一次性）

在 main.gd 任意位置（比如玩家按键 / 编辑器调试器）调一次：

```gdscript
_weather_system.set_field_verify_mode(true)   # 默认 tol = 1e-4
```

期望下一 tick 见到 console 一条：

```
[weather] field A/B verify ON (tol=1.0e-04); next tick will run both paths
[weather/F.1 verify] PASS — all 2400 cells within tol (max abs deltas: vapor=...
```

如果是 FAIL：

```
[weather/F.1 verify] FAIL — first divergence cell=123 field=vapor cpp=0.421 gdscript=0.420 delta=1.20e-03 (tol=1.0e-04). max abs deltas: ...
```

把这条日志贴回来，我会按 cell idx + field 反查 C++ 翻译里哪一行算错了。验完关掉：

```gdscript
_weather_system.set_field_verify_mode(false)
```

---

## 3. 已知风险（C++ 翻译时主动标注）

### 3.1 `_sample_terrain_wind` fallback 未翻译（中风险）

**触发条件**：cell 的 `wind_x_arr[i]` 与 `wind_y_arr[i]` 都接近 0（length² < 0.0001）。

**GDScript 行为**（weather_system.gd:687-691）：
- 落入 `_sample_terrain_wind(map, world, pos, ny, _season_phase)`
- 该 helper 会调 `WorldData.iter_winds()` 做 LRU 季节插值

**C++ 当前行为**（world_ext.cpp F.1 主循环 wind 分支注释）：
- 直接给 `wind_dir = (1, 0)`，`wind_mag = 0`
- 等价于"无风、风带方向 +x"

**bit-equal 影响**：
- 风场求解器在生产环境通常给非零风（除了赤道平静带的极少数 cell）
- A/B verify 出现差异时，先看是否仅集中在风=0 的 cell；如果是，可接受
- 如果差异铺满全图，说明翻译有别的 bug，按 cell idx 跟踪

**修复路径**（后续 PR）：
- 把 `_sample_terrain_wind` 的 LUT 从 GDScript 提取到 PackedFloat32Array（256~1024 entry）
- 在 knobs dict 里附 `wind_lut` 入参；C++ 端做线性插值

### 3.2 `temperature_transport_anomaly` 未在 schema 中（小开销）

**当前**：`_build_weather_field_knobs()` 每 tick 从 cells 提取一次成 PackedFloat32Array 传给 C++。
- N=2400：约 0.05ms 开销
- 远小于 C++ 节省的 11ms，可接受

**长远**：F.x phase II 数据所有权下移 PR 把这个字段加到 `component_schema.gd`，届时改一行：
```gdscript
"temp_transport_anomaly": map.temperature_transport_anomaly_arr,  # SoA 直接传
```

### 3.3 切片预算 < n 时 fallback（功能限制）

**当前**：`run_weather_field_solve_pass` 要求 `start_idx == 0 && end_idx == n_cells`。
- map_generator 的 `tick_one_day` 内部 `_solve_weather_field` 用 INT_MAX budget 单 shot 调用，**总是触发 C++ 路径**
- map_generator 的 `weather_refresh_job` SUS 调度可能传 budget < n（如 1200/tick × 2 tick）
- 那种 SUS 切片场景下 C++ pass 返回 -1.0 → 透明 fallback 到 GDScript

**影响**：
- 主路径（一次成型）走 C++，性能收益拿到
- SUS 调度切片时回退 GDScript（性能不如全 C++ 但与改动前等价）

**修复路径**（后续 PR）：
- C++ pass 接收 `out_*` PackedArray 输出缓冲（替换"写 SoA"模式）
- 配合 dirty-flag 双缓冲，让 mid-slice 写出不污染下一 slice 的 SoA 读
- 工作量 ~2-3 天，charter §7 P0 收益已经主路径拿到，**不阻塞主路径采纳**

---

## 4. 性能预算回填（charter §7 表 1）

| 项 | charter 目标 | 落地状态 |
| -- | ----------- | -------- |
| weather field solve N=2400 | 13ms → < 2ms | ⏳ 等用户验收数字 |
| F.1 SUS slice 内 use_gdext_weather_field=true 整 tick avg | < 4ms | ⏳ 等用户 30-day soak 数字 |

跑完一次 30-tick soak 后请把以下数据贴回来：
- `weather_refresh` 的 `avg` / `p95`
- `[fast tick WARN]` 行 `sus=` 数字
- A/B verify 的 `PASS` 或 `FAIL` + max abs deltas

我会把数字回填到 `dots-migration-roadmap.md` §F.1 + `performance-charter.md` §7 表 1。

---

## 5. 下一个 PR 入口（顺位）

| 优先级 | PR | 工作量 | 入口位置 |
| ----- | -- | ----- | ------- |
| **P1.a** | F.2 ocean water + land C++ 化 | 2-3 天 | `world_ext.cpp:1745+`（stub）+ `simulation/ocean/water_pass.gd` 与 `land_pass.gd`（facade） |
| **P1.b** | F.3 climate Pass-B C++ 化 | 1-2 天 | `world_ext.cpp:1757+`（stub）+ `simulation/climate/pass_b.gd`（facade） |
| **P2.a** | F.4 sea ice daily C++ 化 | 1 天 | `world_ext.cpp:1764+`（stub）+ `simulation/sea_ice/daily_pass.gd` |
| **P2.b** | F.5 transp pass C++ 化 | 1 天（最简，~80 行算法）| `world_ext.cpp:1770+`（stub）+ `simulation/biology/transpiration_pass.gd` |
| **P3** | F.6 weather front advect | 2 天 | `world_ext.cpp:1777+`（stub）+ `weather/front_advect.gd` |

每个 PR 模板（按 F.1 这次 PR 复盘）：
1. 读 GDScript 主循环 + 所有 helper（30 min - 2h，看复杂度）
2. 查 component_schema 是否覆盖所有读字段（缺的字段：要么加 schema 要么 GDScript 端临时打包）
3. 在 world_ext.h 改 stub 签名（如果当前签名不够用）
4. 写 anonymous-namespace helper（每个 helper 1:1 翻 GDScript，注释里贴行号）
5. 写主循环（1:1 翻，注释里贴 GDScript 行号）
6. 改 _bind_methods 签名（如果改过）
7. 在 GDScript caller 写 fast-path 分支（`configure_gdext_xxx` setter + `_try_run_xxx` helper + `_pull_xxx_results_to_next`）
8. 加 A/B verify mode（按 F.1 模板）
9. 跑 lint + 跑现有单测确认无破坏
10. 创建 `dots-fX-validation.md` 文档（按本文模板）
11. 更新 dots-migration-roadmap.md §F.x 行状态

---

## 6. 出 bug 时怎么找我

把以下 4 件事贴回来即可：
1. A/B verify 的 FAIL 日志原文
2. `[fast tick WARN]` 最近一段
3. `print("[weather/dbg] cell ", idx, " temp=", soa_temp[idx], ...)` 之类自定义 dump（只挑发散 cell）
4. C++ rebuild 时间戳确认（`gdext/bin/*.dll` mtime）

我会按 cell idx 反查 GDScript 与 C++ 哪一行算错。
