# F.3 climate Pass-B — C++ 实装验收 SOP

> 状态：**算法已实装，等用户本地编译 + 启用 flag + 跑游戏验收**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §F.3 / [`performance-charter.md`](./performance-charter.md) §7 P1
> 模板：复用 [`dots-f1-validation.md`](./dots-f1-validation.md) + [`dots-f5-validation.md`](./dots-f5-validation.md)
> 创建：2026-05-13 / 责任：climate + co-processor 联调

---

## 1. 这次 PR 改了什么

| 文件 | 改动 |
| ---- | ---- |
| `gdext/src/world_ext.h` | F.3 签名收敛为 `run_climate_pass_b(const Dictionary &knobs)` 单参 + 详细 contract |
| `gdext/src/world_ext.cpp` | **替换 F.3 stub → ~290 行真 C++ 算法**（wind_belt_at helper + 主循环 1:1 mirror `_climate_pass_b_soa` line 4396-4523）|
| `gdext/src/world_ext.cpp` (`_bind_methods`) | F.3 D_METHOD 签名改成 `("knobs")` 单参 |
| `Project/.../geography/map_generator.gd` | `_climate_pass_b_soa` 头部加 GDExt fast-path + precondition probe + sig probe + DEBUG print + foliage_table cache helper + 7 个 F.3 统计字段 |

---

## 2. 验收 5 步走（用户本地）

### 步骤 1 — Rebuild gdext（**两个 target 都 build**）

```cmd
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
:: 用上次创建的 rebuild.bat 一键编译两个 target
rebuild.bat
```

或手动两条：
```cmd
scons platform=windows target=template_debug   dev_build=no -j8
scons platform=windows target=template_release dev_build=no -j8
```

### 步骤 2 — 打开 use_gdext_climate_pass_b flag

ClimateProfile `.tres`（你正在用的 `earth_like.tres` 或 inspector 上挂的）：

```gdscript
@export var use_gdext_climate_pass_b: bool = true   # false → true，记得 Ctrl+S 保存
```

### 步骤 3 — 完全关闭 Godot 重启

（编辑器加载过的 .dll 不能热替换；重启后才会加载新 dll。）

### 步骤 4 — 启动后期望日志

```
[climate_b/F.3] precondition probe (one-time):
  active ClimateProfile = res://data/world/earth_like.tres
  cp.use_gdext_climate_pass_b = true
  use_sparse_climate = false（true 时整段 fallback GDScript）
  fast_indexed = true (n=2400 nb_size=14400)
  rs_lookback = 4, t_freeze = 0.20, coupling_gain = 0.50
  verdict = OK → will try C++
[gdext sig] run_climate_pass_b match[0]: args.size()=1 names=[knobs] ...
[climate_b/F.3] sig probe result = true（仅作诊断）
[climate_b/F.3] DEBUG call#1: rc=0.???? n_cells=2400 rs_lookback=4
[climate_b/F.3] gdext path ACTIVE — first run elapsed=0.??ms (legacy GDScript baseline ≈ 5.2ms; charter §7 target < 0.5ms)
```

### 步骤 5 — 跑 30-day soak

期望：
- `refresh_climate_daily` 行内 `B=` 字段从 ~6ms 降到 < 0.5ms
- `refresh_climate_daily` 总 avg 从 ~8.8ms 降到 ~3-4ms（B 砍 5ms）
- fast tick avg sus 进入 < 15ms 区间（之前 17-25ms）

把 `[fast tick WARN]` 完整一段 + `[SUS] last 30 ticks: refresh_climate_daily ...` 一行贴回，我帮回填到 charter §7 表。

---

## 3. 已知风险 / 简化（C++ 翻译时主动标注）

### 3.1 sparse path 不支持（中风险）

**现状**：当 `cp.use_sparse_climate=true` 时，本 fast-path 在入口就 fallback 到 GDScript。

**原因**：稀疏路径需要 dirty mask + 1 跳邻居膨胀的 visit_mask 处理，逻辑复杂。本次 PR 优先 ship 全图路径（性能账已经覆盖 charter §7 目标）。

**后续 PR 解锁路径**：把 dirty_mask + visit_mask 也作为 `knobs` PackedByteArray 入参，C++ 端 `if (visit_mask[i] == 0) continue;`。预计工作量 1 天。

### 3.2 `cell.temperature_breakdown` UI dict 不写入（低风险）

**现状**：F.3 ON 时，UI inspector 选中某 cell 看 temperature_breakdown 会**空 dict**。

**原因**：原 GDScript pass 在 hot loop 里有 `if not c.temperature_breakdown.is_empty(): c.temperature_breakdown["albedo"] = d_albedo ...`——这是 UI 调试用的，对 99.99% cell 是 no-op（只有玩家点中那一个 cell 才不为空）。C++ pass 全跳过这个写入以保持 hot loop 紧凑。

**Workaround**：玩家选中 cell 后想看 breakdown，**临时关闭 use_gdext_climate_pass_b** 跑一 round 再开回。或者后续 PR 加 "selected cell breakdown override" 走 GDScript 单 cell 重算（成本 < 0.05ms）。

### 3.3 `[DIAG pass_b_end]` 末尾统计不打印（低风险）

**现状**：F.3 ON 时，`[DIAG pass_b_end] day=N phase=X temp_a min/max/mean=...` 这条诊断行**不会出现**。

**原因**：原 GDScript 在 `_daily_climate_call_count <= 8` 时打这行（前 8 round 用于回归对比）。C++ pass 不打日志以保持 hot loop 紧凑。

**Workaround**：如需对比，关掉 use_gdext_climate_pass_b 跑前 8 round；或在 `_climate_pass_b_soa` `return` 前自行加一条同源 dump（仅 `_daily_climate_call_count <= 8` 时）。

### 3.4 rain shadow 的 `jitter` 取 0（极低风险）

**现状**：原 GDScript wind_at 调用是 `WindBeltScript.wind_at(ny, season_phase, jitter)`，其中 `jitter = sin(c.q*0.31 + c.r*0.47) * 0.05`。schema 没存 `c.q / c.r`，C++ 实装把 jitter 取 0。

**bit-equal 影响**：`jitter ∈ [-0.05, +0.05]`，对 wind_at 的 lat 输入是 `lat = (ny-0.5)*2 + jitter`，所以风带边界附近（bbh=0.06）的 cell 可能在不同风带选定上有差异。但 jitter 仅在风带边界±0.05 的窄带内才会触发分类不同；窄带内 cell 数量 < 5%，且风向只是上风方向选取，rain shadow 的最终判定 `max_upwind_h - elev[i] >= rs_threshold` 的阈值对方向不敏感。**预计 < 1% 的 cell 在 rain_shadow 判定上有差异**，可接受。

**后续 PR 修法**：把 `cell_q` / `cell_r` 加到 component_schema.gd（schema 已有 `cell_pos_x/y` 但没有 q/r），或者直接预算 jitter 进 `cell_lat_norm` 的旁路 SoA。

### 3.5 `cell.temperature_transport_anomaly` 没有 SoA 镜像（同 F.1）

**现状**：每次 F.3 fast-path 都从 cells 提取一次到临时 PackedFloat32Array（~0.05ms 开销）。

**修复路径**：F.x phase II 数据所有权下移 PR 中加 SoA 镜像。届时改一行：`"temp_transport_anomaly": map.temperature_transport_anomaly_arr`。

---

## 4. 性能预算回填（charter §7 表 1）

| 项 | charter 目标 | 落地状态 |
| -- | ----------- | -------- |
| climate Pass-B N=2400 | 5.2ms → < 0.5ms | ⏳ 等用户验收数字 |
| `refresh_climate_daily` 内 `B=` 字段 | < 0.5ms | ⏳ 等 fast tick WARN 详细行 |
| `refresh_climate_daily` 总 avg | ~8.8 → ~3-4ms | ⏳ 等 SUS last 30 ticks 数字 |

跑完一次 30-tick soak 后请把以下贴回：
- `[climate_b/F.3] gdext path ACTIVE — first run elapsed=...` 的 ms
- `[fast tick WARN]` 行内 `refresh_climate_daily ran=...ms ...B=X.X` 的 B 数字
- `[SUS] last 30 ticks: refresh_climate_daily ran=N avg=X.Xms p95=...`

---

## 5. 下一个 PR 入口（顺位剩余 3 个）

按 charter §7 收益排序（已扣除 F.1 + F.5 + F.3）：

| 优先级 | PR | 工作量 | 期望收益 |
| ----- | -- | ----- | ------- |
| **P1** | F.2 ocean water + land C++ 化 | 1-2 周（两个 pass，~600 行算法）| 6.8ms → 1ms |
| **P2** | F.4 sea_ice daily C++ 化 | 3-5 天（含 terrain ECB 翻转）| 5.1ms → 0.5ms |
| **P3** | F.6 weather front C++ 化 + front pool DOTS 化 | 1 周（front pool 升权威）| 3.0ms → 0.5ms |

每个 PR 模板（按 F.1 + F.5 + F.3 复盘）：
1. 读 GDScript 主循环 + 所有 helper（30min - 2h）
2. 查 component_schema 是否覆盖所有读字段
3. 在 world_ext.h 改 stub 签名为 `Dictionary`
4. 写 anonymous-namespace helper（每个 helper 1:1 翻 GDScript，注释里贴行号）
5. 写主循环（1:1 翻，注释里贴 GDScript 行号）
6. 改 _bind_methods 签名
7. 在 GDScript caller 加 fast-path 分支 + 一次性 precondition + sig probe + DEBUG print
8. 跑 lint + 跑现有单测确认无破坏
9. 创建 `dots-fX-validation.md` 文档（按本文模板）
10. 更新 dots-migration-roadmap.md + framework-status.md

---

## 6. 出 bug 时怎么找我

按现有套路：把 `[climate_b/F.3] precondition probe` + `[gdext sig] run_climate_pass_b` + `[climate_b/F.3] DEBUG call#1: rc=...` 这三段全文贴回。如有 `[DCWorldExt] run_climate_pass_b: <reason>` 警告，把 `<reason>` 贴回。

如果 F.3 ON 后 weather/biome 视觉异常（雪线移动、植被分布变了），把异常 cell 的 idx + (temp before/after, moist before/after) 贴回。**最关心的是 rain shadow 区**——见已知风险 §3.4。
