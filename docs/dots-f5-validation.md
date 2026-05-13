# F.5 transpiration pass — C++ 实装验收 SOP

> 状态：**算法已实装，等用户本地编译 + 启用 flag + 跑游戏验收**
> 关联：[`dots-migration-roadmap.md`](./dots-migration-roadmap.md) §F.5 / [`performance-charter.md`](./performance-charter.md) §7 P2 / 模板 [`dots-f1-validation.md`](./dots-f1-validation.md)
> 创建：2026-05-13 / 责任：biology + co-processor 联调

---

## 1. 这次 PR 改了什么

| 文件 | 改动 |
| ---- | ---- |
| `gdext/src/world_ext.h` | F.5 签名收敛为单 `Dictionary` 入参；详细 contract 文档 |
| `gdext/src/world_ext.cpp` | 替换 F.5 stub → ~110 行 C++ 双 phase 实现（1:1 mirror `_apply_transpiration_pass` line 4938+）|
| `gdext/src/world_ext.cpp` (`_bind_methods`) | F.5 D_METHOD 签名改成 `("knobs")` 单参 |
| `Project/.../geography/map_generator.gd` | `_apply_transpiration_pass()` 头部加 GDExt fast-path 分支 + 一次性诊断 print + `_build_transpiration_donor_table()` cache helper + 5 个 F.5 统计字段 |

---

## 2. 验收 5 步走（用户本地）

### 步骤 1 — 编译 GDExtension

```powershell
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
scons platform=windows target=template_release dev_build=no -j8
```

### 步骤 2 — 打开 use_gdext_transpiration flag

ClimateProfile `.tres`（或 `climate_profile.gd:196`）：

```gdscript
@export var use_gdext_transpiration: bool = true   # false → true
```

### 步骤 3 — 启游戏，观察启动日志

期望（在 climate refresh 第一次 tick 内）：

```
[transp/F.5] first fast-path attempt: n_cells=2400 outflow=0.0250 self=0.0150
[transp/F.5] gdext path ACTIVE — first run elapsed=0.05ms (legacy GDScript baseline ≈ 3.2ms; charter §7 target < 0.3ms)
```

### 步骤 4 — 跑 30-day soak 看 SUS

期望：
- `refresh_climate_daily` 行内 `transp=` 字段从 ~4ms 降到 < 0.3ms（看 fast tick WARN 详细行）
- `refresh_climate_daily` 总 avg 从 10.75ms 降到 ~7-8ms

### 步骤 5 — 视觉验证（无 A/B verify 需要）

F.5 算法纯标量加法 + clamp，bit-equal 风险极低。直接在游戏里观察 1 个 in-game year：
- 雨林 / 沼泽 / 红树林 cell 周围的 land cell moisture 应该有微弱湿度反馈
- `cell.moisture` overlay 不应有突兀变化
- `[DIAG pass_b_end]` 行的 mean moisture 与 F.5 关闭时偏差应 < 0.001

如有视觉异常，把以下贴回：
1. `cell.moisture` 异常 cell 的 idx + (vegetation, landform, before/after value)
2. `_apply_transpiration_pass` 前一行的 `[DIAG pass_b_end]` 数值

---

## 3. 已知风险（C++ 翻译时主动标注）

### 3.1 累加顺序差异（极低风险）

**触发条件**：phase 1 累加 `deltas[nb_idx] += nb_share` 时，邻居 cell 的累加顺序与 GDScript 的 i 遍历顺序应该 1:1 一致（i=0 → 6 邻居先累加；i=1 → 6 邻居后累加 ...）。

**bit-equal 影响**：浮点加法非结合，不同顺序累加同一组数，结果可能差 1-2 ULP。但 phase 1 单线程 i=0..n 顺序与 GDScript 完全一致，所以应该无差异。

**验证**：A/B verify 没做（算法太简单不值得），如果异常就在 GDScript 一侧 dump deltas 数组对照。

### 3.2 `donor_table` cache 失效（中风险）

**触发条件**：运行期切换 ClimateProfile 资源 / hot-reload VegetationProfileRegistry。

**症状**：F.5 用旧 transpiration 值跑。

**修复路径**：在 `_setup_sus` 里 `_gdext_transp_donor_table_cached = PackedFloat32Array()` 重置。如果你不会改 ClimateProfile 中的 vegetation profile，无需关心。

### 3.3 SoA 写入与 GDScript fastpath 一致性（已确认）

**契约**：F.5 直接写 `cell_moisture` slot（CoW alias 到 `map.moisture_arr`）。GDScript 一侧 `cell.moisture` 已经是 SoA alias（启动日志 `[fastpath] HexCell typed fields active (SoA)`），所以 `cell.moisture` 读到的就是 C++ 写的值，不需要再 `cell.moisture = soa[i]` 兜底。**与 F.1 同模式，已实测验证。**

---

## 4. 性能预算回填（charter §7 表 1）

| 项 | charter 目标 | 落地状态 |
| -- | ----------- | -------- |
| transp pass N=2400 | 3.2ms → < 0.3ms | ⏳ 等用户验收数字 |
| `refresh_climate_daily` 内 `transp=` 字段 | < 0.3ms | ⏳ 等 fast tick WARN 详细行 |

跑完一次 30-tick soak 后请把以下数据贴回：
- `refresh_climate_daily ran=Xms` 的 `transp=` 字段
- `[transp/F.5] gdext path ACTIVE — first run elapsed=...` 的 ms 数字

---

## 5. 下一个 PR 入口（顺位剩余 4 个）

按 charter §7 收益排序（已扣除 F.1 + F.5）：

| 优先级 | PR | 工作量 | 期望收益 |
| ----- | -- | ----- | ------- |
| **P1.a** | F.3 climate Pass-B C++ 化 | 4-6 天（算法 ~400 行）| 5.2ms → 0.5ms |
| **P1.b** | F.2 ocean water + land C++ 化 | 1-2 周（两个 pass，~600 行算法）| 6.8ms → 1ms |
| **P2** | F.4 sea_ice daily C++ 化 | 3-5 天（含 terrain ECB 翻转）| 5.1ms → 0.5ms |
| **P3** | F.6 weather front C++ 化 + front pool DOTS 化 | 1 周（front pool 升权威）| 3.0ms → 0.5ms |

每个 PR 模板（按 F.1 + F.5 复盘）：
1. 读 GDScript 主循环 + 所有 helper（30min - 2h，看复杂度）
2. 查 component_schema 是否覆盖所有读字段
3. 在 world_ext.h 改 stub 签名为 `Dictionary`
4. 写 anonymous-namespace helper（每个 helper 1:1 翻 GDScript，注释里贴行号）
5. 写主循环（1:1 翻，注释里贴 GDScript 行号）
6. 改 _bind_methods 签名
7. 在 GDScript caller 加 fast-path 分支 + 一次性诊断 print
8. 跑 lint + 跑现有单测确认无破坏
9. 创建 `dots-fX-validation.md` 文档（按本文模板）
10. 更新 dots-migration-roadmap.md + framework-status.md

---

## 6. 出 bug 时怎么找我

- `[transp/F.5] first fast-path attempt: ...` **没出现** → flag 是 false 或 ext 没 bind
- `first_attempt` 出了但 `gdext path ACTIVE` 没出 → C++ 端某个 precondition 返回 -1.0；console 会有 `[DCWorldExt] run_transpiration_pass: <reason> — fallback to GDScript`
- `gdext path ACTIVE elapsed=Xms` 出现但 transp 视觉异常 → 把异常 cell idx + (veg, lf, moisture before/after) 贴回，按 i 反查 phase 1 / phase 2 哪一段算错
