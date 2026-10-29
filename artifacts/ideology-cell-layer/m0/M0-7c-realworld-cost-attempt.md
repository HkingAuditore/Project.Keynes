# M0-7c real-world cost baseline — attempt & findings (round 2)

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) §14.3 / M1 前置 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 夹具 | `Project/project-keynes/tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd` |
| 状态 | **`loaded` 档仍未取得；本轮新增 3 个有效性门禁与 2 个根因** |
| 结论 | 真实世界 idle 稳态 ~0.003 ms；`loaded` 档被两个独立的环境限制挡住，见 §4 |

## 1. 已取得的可靠数据

真实生产世界（60×40 = **2400 格**，正式多国开局，`generate_test_economy_data=false`）：

| 档位 | n | p50 | 原始 |
|---|---:|---:|---|
| `idle`（无卡） | 6 | **0.003 ms** | `[0.568, 0.0028, 0.0028, 0.0028, 0.0028, 0.0028]` |

首个样本是冷启动（首次分配 + 首次 `collect_scope_ids`），已作为 warmup 标记并保留在原始串里。

## 2. 本轮新增的三条有效性门禁

首轮与次轮的教训是同一个：**夹具能产出一个数字，不代表那个数字测的是它声称的东西。** 现在每条都是一个显式断言。

### 门禁 A：注入的行可读

```gdscript
var live := ext.evaluate_modifier_stat(2, 0, 0, "economy.city.birth_factor", 1.0)
_require("injected row is readable (else `loaded` == `idle`)",
    not is_equal_approx(live, 1.0), ...)
```

实测通过：`cell511 = 1.000015`，`cell512 = 1.000000` —— 512 行确实落在预期的格上。

### 门禁 B：经济未 fatal

```gdscript
if bool(report.get("fatal", false)):
    _require("%s: economy still healthy" % label, false,
        "economy went fatal; every reading after this is stale")
```

**触发过。** 一次运行里 `country=29.059` 在 **13 个连续 epoch 完全相同**。`_epoch_begin_country_ms` 在 `clear_epoch_metrics`（`economy_runtime_epoch.cpp:463`）每轮清零，13 次相同在物理上不可能 —— 那是经济在 day 4 `money_conservation_failed` 后停止开 epoch，读的是陈旧值。

### 门禁 C：A/B 对照

同一覆盖率跑两组，若 `loaded == idle` 就打印 `NOT RESOLVED` 并明确写出「本夹具无法测量 loaded 成本，不要把 idle 数字当作功能成本」，而不是输出一个自信的 0.003 ms。

## 3. 两个根因（本轮定位）

### 3.1 `MODIFIER` 位必须在 worker 掩码外

`runtime_domain_mask(N) == 1 << (N-1)`（`runtime_pod_protocol.h:569-573`），`RuntimeDomainId::MODIFIER == 7` → `0x040`。

worker 权威下 `submit_modifier_commands` 是**队列**（`world_ext_modifier.cpp:159-160`：「E8: Host is the sole writer. Never apply to legacy first.」），主线程注入的 GROUP 行永远到不了被测量的 store。

### 3.2 `ECONOMY` 位也必须在 worker 掩码外 —— 但代价是无法取数

`ECONOMY == 9` → `0x100`。若 ECONOMY 在 worker 上，主线程从不执行 `start_epoch`/`capture_country_epoch`，DETAIL 报告里的 `epoch_begin_*` 是**配置期的陈旧值**。

把 ECONOMY 拨回主线程后，经济在 **day 4** 以 `money_conservation_failed` 致命（`economy_runtime.cpp:14667`、`economy_runtime_publish.cpp:399,433`）。

对照：基线里 `runtime_ideology_parity_test`（ECONOMY 在 worker 上）**没有**这个失败。所以它是「主线程跑经济」这条路径的既有问题，不是本夹具引入的缺陷，也不是本方案的范围。

**day 4 之前只有 3 天可用，不足以取样。** 这条路走不通。

## 4. `loaded` 档为什么仍然没有

完整排除链（每行都有日志）：

| 尝试 | 结果 | 根因 |
|---|---|---|
| `facade.equip()` | 0 张 | 新局 `known_ids` 为空 |
| discover → offer → choose → equip 循环 | 挂起 20+ 分钟 | 抽卡循环不收敛 |
| discover + equip 批量，无支持门 | 0 张 | `support_gate(SUPPORT_ADOPT)` 拒绝 |
| 同上 + `PK_DISABLE_SUPPORT_GATE=1` | 0 张 | `path=IDEOLOGY_WORKER, applied=0`，命令只进队列 |
| 轮询等 worker 提交日 | worker day 9 FAULTED | `day_wait_peer_stall_timeout` |
| + peer 服务调用 | 仍 FAULTED | 需真实帧循环 |
| **改注入 Modifier 行（绕过理念）** | 行可读但读数不变 | 见 §3.2：ECONOMY 在 worker 上 → 计数器陈旧 |
| **ECONOMY 拨回主线程** | 经济 day 4 fatal | `money_conservation_failed` |

## 5. 对 M1 的三条结论

1. **真实世界 idle 冷建成本 ~0.003 ms**，比合成夹具（同量级地图 0.418 ms）低两个数量级。合成夹具的绝对值不可作门槛（已写入方案 §14.3）。
2. **`loaded` 档需要一套真正的帧循环 + worker 协作脚手架**，本轮 8 种路径全部失败于同一个位置：`SceneTree` 脚本无法满足 worker 的 peer 服务需求。这与 M0-2 基线里两个卡住的 worker fixture 是同一类缺口。
3. **主线程执行 ECONOMY 会触发 `money_conservation_failed`**（day 4）。这是一个**既有的、独立的**问题，值得单独记录——任何想让经济在主线程跑的验收路径都会撞上它。

## 6. 局限（必须与 §1 的数字一起引用）

- **只有 `idle` 数据**，一次会话、6 个样本。不足以给 p95/p99。
- 只测 debug DLL。
- `player owned cells=-1`：三项候选键在 `country.report()` 里都不存在，领土格数未取到。
- 未测 `_building_factor_refresh_ms`、峰值内存、slice 数、恢复耗时。
- §3.2 的「ECONOMY 在 worker 上 → 计数器陈旧」是由「13 次相同读数」反推的，**没有直接读到 `_fatal` 之外的状态确认跳过机制**。它是强推断，不是直接证明。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/m0/realworld_cost.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/m0/realworld_cost.stderr.log
```

夹具当前**通过**（10 checks 0 failures），但它会显式打印 `NOT RESOLVED`，明确声明 `loaded` 档未测到。这是刻意的：一个静默把 `loaded` 等于 `idle` 的夹具，会让那个数字被当成功能成本。
