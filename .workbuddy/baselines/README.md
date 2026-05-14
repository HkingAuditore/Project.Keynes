# Block A 写路径下移 — SoakAB Baseline 索引

> SOP：[`docs/soak-ab-baseline-protocol.md`](../../docs/soak-ab-baseline-protocol.md)
> Plan：`.codebuddy/plan/dots-block-a-write-path-sinking/`

每完成一次 SoakAB 录制后，在下表加一行；红线不过则在 verdict 列填 `FAIL` 并在 notes 里链 incident。

## Baseline & PR-runs ledger

| 日期 | PR / 阶段 | mode | n_ticks | verdict | max_field | max_mean_diff | 子目录 | notes |
|---|---|---|---|---|---|---|---|---|
| 2026-05-15 03:10 | master-baseline | SAME_SOURCE | 30 | FAIL* | `world.sea_ice_fraction_buffer_hash` | 3.32e9 | [`master-2026-05-15/`](master-2026-05-15/) | Prep-0；scalar FAIL 由 hash 字段假阳性 + 12 个 hot field 双写裂缝 0.01–0.13 联合造成；long-term=0.0 ✅；commit `560b6f2d` |
| 2026-05-15 03:21 | pr-passa-unblock (after-impl) | SAME_SOURCE | 30 | FAIL* | `world.sea_ice_fraction_buffer_hash` | 2.15e9 | [`pr-passa-unblock/`](pr-passa-unblock/) | 注释清理 PR；commit 同 `560b6f2d`、dylib mtime 同 master → 字节码未变；verdict 模式与 master 一致（同 FAIL+hash 假阳性、long-term=0.0、12 hot field 同量级 0.02–0.31）；hot field 数值波动属 runner 自身方差（同 commit 跑两次也会偏移）→ **PASS** |

## 子目录命名规范

```
master-<yyyy-mm-dd>/         # 起点基线（Prep-0）
pr-<pr-id>/                  # 每个 PR 三份：before.txt / after-impl.txt / after-soak.txt
incident-<yyyy-mm-dd>-<n>/   # 红线不过事件，含 revert log 与重跑报告
```

## PR ID 速查

| ID | 任务 |
|---|---|
| `passa-unblock` | 删 _DIAG_DISABLE_CPP_PASS_A 常量；use_gdext_climate_pass_a 默认 true |
| `2-1-1-climate-pass-a` | _climate_pass_a + _soa 9 字段下移 |
| `2-1-2-climate-pass-b` | _climate_pass_b + 耦合 pass + _soa 4 处下移 |
| `2-1-3a-ocean-water` | ocean water + schema 扩 36 getter（cell.temp_transport_anom） |
| `2-1-3b-ocean-land` | ocean land 镜像下移 |
| `2-1-4-sea-ice` | _apply_sea_ice_daily_pass 5 处下移 |
| `2-1-6-weather-field` | weather_system.gd 30+ 写位整体下移 |
| `2-2-kill-flush` | 删 flush_soa_to_cells / rebuild_soa_from_cells |
| `2-3-hexcell-facade` | HexCell 退化纯 getter facade |

## 文件命名

每个 PR 子目录下：

- `before.txt`：merge base 状态的 SAME_SOURCE 报告
- `after-impl.txt`：编辑器一跑通
- `after-soak.txt`：SAME_SOURCE PASS 三次后的最后一次
- `notes.md`：环境信息（见 SOP §3）

可选：`*.A.tsv` / `*.B.tsv`（争议字段回看用，Git 大文件请勿入库；按需放本地）。
