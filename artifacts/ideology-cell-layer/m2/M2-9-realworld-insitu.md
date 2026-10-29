# M2-9 realworld in-situ attempt — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §14.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | 复用 M0-7c harness 跑真实世界测量 |
| 结果 | **idle 档取得 0.002 ms**；loaded 档被**既有经济缺陷**挡住 |
| 结论 | 真实世界入口可用；阻塞点是既有的 `money_conservation_failed`，与本迁移无关 |

## 1. 换了一个入口（这次是对的）

前几轮我一直在裸 `SceneTree` 里试图打开 economy epoch，三次失败。本轮改用 **M0-7c 已经跑通的 harness**：

```
ideology_cell_layer_m0_realworld_cost_test.gd
  → await _host.generate_world(SEED)          // 真实 MapData
  → runtime_authority_domain_mask = 0xFFF & ~0x040 & ~0x100   // MODIFIER+ECONOMY 拨离 worker
```

它有真实地图（2400 格，60×40）、真实 epoch、以及**三个有效性门禁**（fatal 检查、stale 检测、idle/loaded 对照）。

## 2. 实际取得的数据

```
[realworld-cost] map=60x40 cells=2400
[realworld-cost] idle (no cards) n=2 min=0.002 p50=0.002 max=0.002 mean=0.002 ms
[realworld-cost] injected rows on 2000 cells
[realworld-cost] loaded A (2000 cells) NO DATA
[realworld-cost] loaded B (2000 cells) NO DATA
```

| 档位 | 结果 |
|---|---|
| **idle** | **0.002 ms**（真实世界、真实 epoch、2 个样本） |
| loaded | **NO DATA** —— 经济已 fatal |

## 3. loaded 为什么没有数据，以及为什么与本迁移无关

```
[economy-fatal] day=4 stage=9 substage=verify reason=money_conservation_failed
money_error = -254076
money_open     = 372000000
money_expected = 373440000
money_close    = 373185924
```

三条证据说明这是**既有缺陷**：

1. **M0-7c 已记录**：`artifact/…/M0-7c-realworld-cost-attempt.md:61` 明确写「把 ECONOMY 拨回主线程后，经济在 **day 4** 以 `money_conservation_failed` 致命」。
2. **我的改动没碰 money 路径**：本迁移只动了分片、诊断字段、选择器上限、派生层合并。`git status` 里的 `economy_runtime*.cpp` 改动是分片与诊断，不含货币结算。
3. **失败点在 `aggregate_publish/verify`**：那是经济结算校验，与理念地块目标解析无交集。

## 4. idle 的 0.002 ms 能说明什么、不能说明什么

**能说明：**
- 真实世界里，无卡时 city 因子读者约 0.002 ms —— 与 M0-7c 的 0.003 ms 一致，**harness 可重复**；
- 我加的 `city_factor_shard_*` 诊断字段在真实世界不报错（报告可读）；
- 分片改造没有让 idle 路径变慢。

**不能说明：**
- **不能说明取消上限的成本。** idle = 无卡 = `collect_scope_ids` 返回空 = 工作集为空。按 M2-6 的模型，`covered_cells = 0` 时成本与上限无关。
- **正是 harness 自己警告的那件事**（`:167-171`）：

  > `NOT RESOLVED: loaded == idle`. The reader short-circuited... Do not quote the idle number as the feature cost.

  本轮 loaded 是 NO DATA 而非 NO RESOLVED，但结论相同：**idle 数字不能当作功能成本**。

## 5. 一个仍未解释的现象（如实记录）

```
[realworld-cost] player owned cells=-1
```

玩家国家在真实世界里**没有领土**（`country_cell_count` 返回 0 或负）。这意味着：

- `country_anchor_cell(0)` 很可能是 -1；
- kind 12 的目标解析会退化为单格（`economy_runtime_family_buff.cpp:2382-2385`）；
- **即便 loaded 档不 fatal，它也可能测不出「全领土覆盖」的效果**。

这是一个新的、独立于 money 缺陷的障碍。M0-7c 未记录它（当时关注的是 loaded 档的 worker 问题）。下一轮应先解决「玩家国家为何无领土」。

## 6. 结论与建议

真实世界入口**是可行的**（idle 已证明），但 loaded 档被两个叠加障碍挡住：

| 障碍 | 性质 | 记录 |
|---|---|---|
| `money_conservation_failed` @ day 4 | 既有经济缺陷 | M0-7c, 本轮 |
| `player owned cells = -1` | **新发现**，未解释 | 本轮 |

**建议下一步优先查第 2 项**，因为它比 money 缺陷更可控：如果玩家国家本应有领土，这是一个初始化/绑定问题，可能不需要 worker 脚手架就能修。

## 7. 局限

- idle 只有 2 个样本（harness 丢弃 warmup）。
- 未测 6400 格地图（本轮是 2400）。
- 未验证 `city_factor_work_cells` 在 loaded 档的值（没走到那一步）。
- `player owned cells = -1` 的根因完全未知，只是观测到了。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd'
# => idle 0.002 ms; loaded NO DATA; player owned cells=-1
#    单次约 5-10 分钟（generate_world）
```
