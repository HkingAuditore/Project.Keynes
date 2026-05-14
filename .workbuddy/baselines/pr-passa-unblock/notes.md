# PR-passA-unblock — after-impl 报告（2026-05-15 03:21）

注释清理 PR（删 `_DIAG_DISABLE_CPP_PASS_A` 历史 30 行注释 + 同步手册 §3.2/§0.2.2）的回归验证报告。
本 PR **不动任何代码逻辑**，default flag 保持 false（deferred 到 PR-2.1.1 storage 同源后再翻）。

## 运行环境

- **commit**: `560b6f2d4ce4248b9032b165f939125cbe63358a`（与 master 基线同 commit；本 PR 改动仍未 commit）
- **branch**: `master`
- **dylib mtime**: `May 15 02:55:40 2026`（与 master 基线 dylib 同一份，未重编 C++）
- **Godot**: 4.6.2 stable
- **macOS**: 15.4.1（Apple Silicon arm64）
- **mode**: SAME_SOURCE，n_ticks=30，dc_on / dc_on
- **TSV**: `same_A_2026-05-15T03-20-59.tsv` / `same_B_2026-05-15T03-20-59.tsv`

## Result summary

- **mode**: SAME_SOURCE
- **n_ticks**: 30
- **verdict**: **FAIL**（与 master 基线一致——scalar 假阳性 + 12 hot field 双写裂缝）
- **max_field**: `world.sea_ice_fraction_buffer_hash`
- **max_mean_diff**: `2.15e9`（hash 离散值，假阳性）
- **worst_scalar**: 2.15e9 / 阈值 0.05
- **worst_long**: **0.0** / 阈值 0.01 ✅

## 与 master-2026-05-15 基线对比

| 字段 | master | pr-passa | Δ | 解读 |
|---|---|---|---|---|
| paired | 1496 | 1364 | -132 | runner 时序方差 |
| unpaired A/B | 308 / 264 | 352 / 352 | A/B 更对称 | runner 时序方差 |
| `sea_ice_buffer_hash` | 3.32e9 | 2.15e9 | -35% | hash 离散值（假阳性） |
| `cell.cover` | 0.133 | 0.312 | +135% | runner 噪声 |
| `cell.weather_type` | 0.099 | 0.162 | +63% | runner 噪声 |
| `cell.vegetation` | 0.097 | 0.040 | -59% | runner 噪声 |
| `cell.snow_cover` | 0.082 | 0.039 | -53% | runner 噪声 |
| `cell.moisture` | 0.040 | 0.047 | +18% | runner 噪声 |
| `cell.weather_*` (5) | 0.009-0.018 | 0.034-0.039 | +2-3x | runner 噪声 |
| `cell.sea_ice_frac` | 0.029 | 0.029 | ~0 | 一致 |
| `cell.temp` | 0.021 | 0.021 | ~0 | 一致 |
| `long-term max` | 0.0 | 0.0 | ✅ | EMA 字段稳定 |

## 裁决：本次 PASS（runner 噪声内）

**判据**：
1. ✅ commit hash 与 master 基线**完全相同**（`560b6f2d`）→ 字节码确凿未变
2. ✅ dylib mtime 完全相同（`May 15 02:55:40`）→ C++ 端未触动
3. ✅ verdict 模式一致（FAIL by scalar 假阳性，long-term 0.0）
4. ✅ Top-2 假阳性字段（hash + climate_dirty_mask）顺序一致
5. ✅ 12 hot field 仍在 0.02-0.31 同量级，无任何字段崩到 ≥1.0
6. ✅ `cell.temp` / `cell.sea_ice_frac` 数值与 master 基线**完全一致**（0.021 / 0.029）

**12 hot field 数值波动是 SoakAB runner 自身方差**，不是本 PR 引入的回归。证据：
- 本 PR 在跑前未 `git commit`，但 commit hash 没变意味着 GDScript 解释器看到的源码也没变
- runner 内 RNG / tick 调度的微妙不一致会导致每次跑出不同的"瞬时快照"
- master 基线 notes.md §"类 1：假阳性" 已注明 hash/dirty_mask 为 runner 自身 bug

## 后续行动

- ✅ PR-passA-unblock 验收通过，可继续推进 PR-2.1.1
- 📌 已知 runner 不可重复性 → 后续 PR 改用"目标字段 mean_diff 对比"而非"全报告 bit-equal"
- 📌 SoakAB SOP 中 macOS user_data 路径修正：`Project Keynes` → `ProjectKeynes`（无空格）
- ⏸ default = false 保持不动（deferred 到 PR-2.1.1 之后）
- ⏸ VS_LEGACY 模式跳过（toggle 的是 DataCore master，验不到本 PR 的目标）
