# Performance Baseline：DOTS Roadmap to GDExtension

> 本文档锁定**动手前的性能基线数字**，作为 I1 / I2 / I3 各阶段验收的标尺。
> 没有基线 = 没法判断 GDExtension 加速比；基线必须**在 I1.A 收尾的同时就抓**，
> 之后只允许"超过基线"或"在容差内持平"，**不允许回归**。
>
> **数据来源**：用户已有的老性能数据（已确认）+ I1.A-2 的 4 个 30-tick 窗口实测。

---

## 1. 测量约定

### 1.1 测量环境

| 项目 | 规格 |
|---|---|
| 主机 | 用户开发机（待用户填写具体 CPU / RAM） |
| 操作系统 | Windows |
| Godot 版本 | 4.4.x |
| 网格规模 | earth_like preset（1024 × 606 = 620,544 cells）|
| 运行模式 | Editor 内启动 + `--headless` 双采样 |
| 编译模板 | template_debug（避免 release 内联干扰） |

### 1.2 测量协议

每次取数：
1. 启动游戏，加载 earth_like preset
2. 让 SUS 跑空 5 个 game-day 让稳态成型（预热）
3. 抓接下来 30 个 game-day 的 SUS 30-tick 汇总日志
4. 重复 4 次（4 个独立窗口），取**均值 + 最大值 + 标准差**

### 1.3 关键指标

| 指标 | 含义 | 来源日志 |
|---|---|---|
| `refresh_climate_daily.avg` | climate 整 round 平均耗时（ms / day）| SUS 30-tick 汇总 |
| `refresh_climate_daily.max` | 30 day 内最大单 round 耗时 | 同上 |
| `pass_a / pass_b / ocean / sea_ice / transp` | 各 sub-pass 累积（ms / round）| partial breakdown 行 |
| `weather_refresh.avg / max` | weather 整 round 平均/最大耗时 | SUS 30-tick |
| `slices/round` | 平均切片数 | SUS 30-tick |
| `frame_budget_exhausted` | 30 day 内 budget 用尽次数 | 异常计数 |

---

## 2. Pre-I1 Baseline（GDScript + GDScript hot loop）

> **抓取时机**：I1.A-2 跑 4 个 30-tick 窗口时同步记录。
> **路径切换**：F11 toggle，分别抓 legacy 路径 和 data_core 路径。

### 2.1 Climate 基线（earth_like / 1024×606）

| 指标 | Legacy 路径（map.xxx_arr 直读）| DataCore 路径（view_f32）| 容差 |
|---|---|---|---|
| `refresh_climate_daily.avg` | TBD ms | TBD ms | DC ≤ Legacy × 105% |
| `refresh_climate_daily.max` | TBD ms | TBD ms | DC ≤ Legacy × 108% |
| `pass_a.avg` | TBD ms | TBD ms | — |
| `pass_b.avg` | TBD ms | TBD ms | — |
| `ocean_water + ocean_land.avg` | TBD ms | TBD ms | — |
| `sea_ice.avg` | TBD ms | TBD ms | — |
| `transp.avg` | TBD ms | TBD ms | — |
| `slices/round` | TBD | TBD | 持平 |
| `frame_budget_exhausted / 30 day` | TBD | TBD | 持平 |

> **填表来源**：[`climate-datacore-migration/task-item.md`](../climate-datacore-migration/task-item.md) §B 阶段验收记录的 4 窗口实测 → 取均值。

### 2.2 Weather 基线（同规格）

| 指标 | Legacy 路径（AoS）| DataCore 路径（SoA 镜像，I1 之后）| 容差 |
|---|---|---|---|
| `weather_refresh.avg` | TBD ms | TBD ms | DC ≤ Legacy × 110% |
| `weather_refresh.max` | TBD ms | TBD ms | DC ≤ Legacy × 115% |
| 活跃 front 数（30 day 均值）| TBD | TBD | 0 误差 |
| `_step_active_fronts.avg` | TBD ms | TBD ms | — |
| `_apply_field_advection.avg` | TBD ms | TBD ms | — |
| `pack_to_uniforms.avg` | TBD ms | TBD ms | — |

> **填表来源**：用户已有的老性能数据（确认中）+ I1.B 完成后实测。

### 2.3 综合 daily-tick 基线

| 指标 | 数值 | 备注 |
|---|---|---|
| daily-tick 总耗时（ms / day）| TBD ms | 含 climate + weather + ocean_currents + sea_ice + 其他 SUS Job |
| 60 FPS 下单 day 实际耗费帧数 | TBD 帧 | total_ms / 16.67ms |
| 大头排序（前 5 名 Job） | TBD | refresh_climate_daily / weather_refresh / ... |

---

## 3. I1 出口验收数字（I1.A + I1.B 完成时）

| 指标 | 红线 | 实测 |
|---|---|---|
| climate avg vs Pre-I1 Legacy | ≤ 105% | TBD% |
| climate max vs Pre-I1 Legacy | ≤ 108% | TBD% |
| weather avg vs Pre-I1 Legacy | ≤ 110% | TBD% |
| weather max vs Pre-I1 Legacy | ≤ 115% | TBD% |
| weather L2 误差（field grid）| ≤ 1e-5 | TBD |
| 活跃 front 30-day 直方图（KS 检验）| p > 0.05 | TBD |

**未达标处置**：
- climate 超 105% → 走 climate plan B-4 优化
- weather 超 110% → 排查"循环内反射 component_id"等已知踩坑（参考 climate B-4 经验）+ archetype 标记位查询热点
- L2 误差超 1e-5 → 强制回滚到 legacy 路径，定位算法等价性问题

---

## 4. I2 出口验收数字（I2.A + I2.B 完成时）

| 指标 | 红线 | 实测 |
|---|---|---|
| climate avg vs I1 出口 | ±2% | TBD% |
| weather avg vs I1 出口 | ±2% | TBD% |
| ECB flush 耗时 | ≤ 0.5ms / day | TBD ms |
| ECB buffer.count() 峰值 | ≤ 32 / day | TBD |
| pool 扩容次数 / 30 day | ≤ 2 次 | TBD |

**未达标处置**：
- ±2% 红线超出 → 排查 query.in_pool 是否触发额外分支预测失败
- ECB flush 超 0.5ms → 检查批量 resize 是否一次完成（避免多次 PackedArray 分裂）

---

## 5. I3 出口验收数字（核心目标）

### 5.1 单 hot loop 加速比（I3.B + I3.C-1~4 各自验收）

| Hot loop | GDScript baseline | C++ 实测 | 加速比 | 红线 |
|---|---|---|---|---|
| `climate_pass_a` | TBD ms | TBD ms | TBDx | ≥ 3x |
| `climate_pass_b` | TBD ms | TBD ms | TBDx | ≥ 3x |
| `ocean_water_pass` | TBD ms | TBD ms | TBDx | ≥ 2.5x |
| `ocean_land_pass` | TBD ms | TBD ms | TBDx | ≥ 2.5x |
| `weather_field_advection` | TBD ms | TBD ms | TBDx | ≥ 3x |

### 5.2 综合性能（I3.D）

| 指标 | Pre-I1 baseline | I3.D 实测 | 加速比 | 红线 |
|---|---|---|---|---|
| `refresh_climate_daily.avg` | TBD ms | TBD ms | TBDx | ≥ 2x |
| `weather_refresh.avg` | TBD ms | TBD ms | TBDx | ≥ 2x |
| daily-tick 总耗时 | TBD ms | TBD ms | TBDx | **≥ 2.5x** |
| frame_budget_exhausted / 30 day | TBD | TBD | — | ≤ Pre-I1 |

### 5.3 行为验收（I3.D）

| 验收项 | 红线 | 实测 |
|---|---|---|
| GDScript path vs C++ path L2 误差（climate temp）| ≤ 1e-5 | TBD |
| GDScript path vs C++ path L2 误差（climate moisture）| ≤ 1e-5 | TBD |
| GDScript path vs C++ path L2 误差（weather field）| ≤ 1e-5 | TBD |
| 30-day 30 个统计指标（temp.mean / temp.max / front_count / ...）的相对误差 | ≤ 1e-4 | TBD |

---

## 6. 跨平台基线（I3.D 强制）

> 三平台跑相同 30-day 测试，验证 GDExtension 跨平台一致性。

### 6.1 Windows x86_64（开发机基线）

| 指标 | C++ path | GDScript path |
|---|---|---|
| daily-tick.avg | TBD ms | TBD ms |
| 加速比 | TBDx | — |

### 6.2 Linux x86_64（CI 基线）

| 指标 | C++ path | GDScript path |
|---|---|---|
| daily-tick.avg | TBD ms | TBD ms |
| 加速比 | TBDx | — |
| vs Windows 数值差 | ≤ 1e-6 | — |

### 6.3 Android arm64（移动端基线）

| 指标 | C++ path | GDScript path |
|---|---|---|
| daily-tick.avg | TBD ms | TBD ms |
| 加速比（vs Android GDScript） | TBDx（预期 ≥ 4x，移动端 CPU 弱）| — |
| vs Windows 数值差 | ≤ 1e-6 | — |

---

## 7. 数据归档约定

每次实测：
1. 保留 SUS 完整日志到 `Project.Keynes/Build/<phase>_<date>_<window>.log`（用户已有这个习惯，参考 `ab_test*.log`）
2. 把均值数据回填到本文件对应表格
3. 在末尾"实测档案"小节追加一条记录：日期 / 阶段 / 主要发现

---

## 8. 实测档案（按时间倒序）

> 完成 I1.A-2、I1.B-9、I2.A-6、I2.B-5、I3.B-5、I3.C-5、I3.D-1 时各填一条。

### 8.1 [模板]

```
日期：2026-XX-XX
阶段：I1.A 完成
主要发现：
- climate DataCore vs Legacy avg 差 X%
- pass_a / pass_b 占大头比例 X% / Y%
- frame_budget_exhausted 0 次
日志归档：Project.Keynes/Build/I1A_2026XXXX_w1~w4.log
```

（待补）

---

## 9. 红线汇总表（一页速查）

| 阶段 | 关键红线 |
|---|---|
| I1.A 出口 | climate avg ≤ Pre-I1 × 105%，max ≤ × 108% |
| I1.B 出口 | weather avg ≤ Pre-I1 × 110%，L2 ≤ 1e-5 |
| I2.A 出口 | 整体 SUS 指标 ±2% |
| I2.B 出口 | ECB flush ≤ 0.5ms/day |
| I3.B 出口 | climate_pass_a 加速 ≥ 3x，L2 ≤ 1e-5 |
| I3.C 出口 | 4 个 hot loop 单段 ≥ 2.5x，整体 ≥ 2x |
| **I3.D 出口** | **daily-tick 综合加速 ≥ 2.5x，三平台过线** |

---

## 10. 决策日志

- **2026-05-11**：基线文档创建。Pre-I1 数字待 I1.A-2 实测填入。
- **2026-05-11**：综合加速目标 ≥ 2.5x（保守）；单 hot loop 目标 ≥ 3x（GDScript→C++ 典型加速比，参考 Godot 官方 GDExtension 性能测试）。
- **2026-05-11**：移动端目标加速比 ≥ 4x（移动端 GDScript 解释器开销更大）。
