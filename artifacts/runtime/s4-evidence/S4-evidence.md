# S4 证据 — Climate 单域 ACTIVE 落地（2026-09-07）

原计划 S4 是 1000 日 OFF/SHADOW 逐日 hash。P3 90 日双 seed 已把准入线改成
「稳态绿 + 首次执行钉死、不累积」。P7 之后 Climate 单独转 ACTIVE，S4 收的是
这条线上的生产证据，不是全域 0xFFF。

## 1. 机制

| 项 | 值 |
|---|---|
| 生产默认 | `WorldRuntimeHost.runtime_climate_authority_enabled = true` |
| worker 模式 | ACTIVE，`authoritative_domain_mask = 0x802`（CLIMATE\|COMMIT） |
| 主线程 | `dispatch_system_schedule` / `run_native_daily_slice` 抑制 climate |
| MapData | `RuntimeClimateWritebackRing` → `apply_runtime_climate_writeback` |
| 日历 | 滞后一日：worker day N 在 main tick N+1 落地 |
| 回退 | GM「Climate worker 权威」或 `set_runtime_climate_authority_enabled(false)` |
| 整图门 | 仍关。`authority_ready` 仍要 0xFFF |

## 2. 测试

| 测试 | 结果 |
|---|---|
| `climate_authority_test.gd` | 12/12。授予、抑制、回灌 2262 格、撤销恢复 |
| `runtime_climate_save_roundtrip_test.gd` | 37/37 CLM2 字节往返（SHADOW 路径，显式关掉权威） |
| `runtime_climate_authority_test` / protocol / domain POD | S0 套件 12/13，唯一失败是既有 `dots_completion_gate` |
| `canal_runtime_test.gd` | 27/27（schema 51） |
| `native_sea_ice_state_machine_test.gd` | 12/12（日变化上限） |
| `native_daily_graph_order_test.gd` | 25/25（蒸腾改读共享内核；flush 带抑制守卫） |

## 3. SHADOW 90 日（P3 准入）

`artifacts/runtime/s2-divergence/long90*` / `long90b*`：

| | seed 20260906 | seed 424242 |
|---|---|---|
| compared / matched / forced | 90 / 87 / 3 | 90 / 87 / 3 |
| 真对拍日 | 9 | 9 |
| 绿 | 6 / 9 | 6 / 9 |

day 7 = 首个满 13 stage 天气日；day 28 = 首次季末。day 58/88 同是季末却全绿。
无字段跨日累积。详见 `artifacts/runtime/s2-divergence/P3-findings.md` §30。

## 4. ACTIVE 对生产 MapData（滞后对齐）

`tests/climate_active_parity_probe.gd`，seed=20260906，40 日，
`writeback_last_day == N`。

`active-parity-active40-s20260906.csv`：day 7 温度 2202 格 @ 0.174，
与 SHADOW 的 6 格 @ 0.021 **不是同一条分叉**。原因是生产 `native_daily_sim_stride=10`，
worker 每天 commit。这条对比不能当物理等价门。day 7 的 vapor/snowpack/paw 仍为 0 差，
生成初值一致。见 P3-findings §31。

## 5. 50 日生产 soak

```
.\.codex\skills\project-keynes-headless-perf\scripts\run_headless_perf.ps1 `
  -Days 50 -Speed 50 -Seed 20260718 -Label climate-active-default
```

| 项 | 值 |
|---|---|
| 正式开局 | 是，4 国，人口 80 |
| ledger_failures | 0 |
| fatal | false |
| CSV 行 | 50 / 50 |
| climate enabled | true |
| worker_authoritative | true |
| writeback_days | 49 |
| writeback_last_day | 49 |
| mask | 0x802 |
| generation_ms | 16514.8 |
| run_ms | 3268.3 |
| CSV | `tmp/perf_record_20260907_164332.csv` |
| log | `tmp/headless_perf_20260907_164308_climate-active-default.log` |

SceneTree `-s` 不泵 `_process`，headless 里每 tick 显式
`_consume_runtime_commit_if_ready()`，并把 worker 时钟解开。

## 6. 未做 / 仍关

- 全域 ACTIVE（其余十域仍在主线程）
- 1000 日 OFF/SHADOW hash（被 90 日稳态线替代）
- ACTIVE 与 stride-1 主线程的逐格物理等价（要另开 stride=1 对拍）
- `dots_completion_gate` 宏观行数门（既有，与本次无关）

## 7. 判定

Climate 单域可以进生产默认。回退开关在，整图门仍关。
