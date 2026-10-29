# M3-22 理念激活已达成，但派生贡献仍为 0（调查收束）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **理念 ACTIVE（`locations=[1]`）；`rebuild_visits=5`；但 `seen=0 taken=0`** |
| 决定 | 收束这条支线，转 M4/M5 主线 |

## 1. 本轮已确证的重大进展

### 1.1 理念首次成功激活

```
[q] economy epoch ok=true
[q] bootstrap_economy ok=true
[q] economy day 0 finished after 14 slices
[q] receipts statuses=[2,2,2,1]  reasons=["","","",""]
[q] equip-settle locations=[1] levels=[2] active=1 applied=1
[q] ACTIVE!
```

`status=1` 表示 `equip` **真的成功了**（M3-18 时是 `status=3` + `ideology_class_opinion_unavailable`）。
`locations=[1]` 就是 `Location::IDEOLOGY`。

### 1.2 派生重建确实在跑

```
[q] cell_layer_rebuild_visits=5    （激活后又跑了一次，从 4 涨到 5）
```

### 1.3 但贡献仍为 0

```
[q] ramp_samples_taken=0 memoised=0 evaluated=0 deferred=0
[q] materialise seen=0 derived=0 legacy=0 truncated=0
```

## 2. 已排除的假设（本轮新增）

| # | 假设 | 反证 |
|---|---|---|
| 13 | 重建没在激活后跑 | `visits` 4→5 |
| 14 | 理念没激活 | `locations=[1] active=1` |
| 15 | 等级超出 `level_count`（`:2165`）| 把 understanding 设为 0（`levels=[0]`）后仍 `seen=0` |
| 16 | `_countries` 与 `get_ideology_snapshot` 是两套存储 | 都是 `_countries`（`country_state_for:1182`）|

## 3. 现在剩下的可能原因（未验证）

`collect_effect_activations` 的提前返回点（`ideology_runtime.cpp:2161-2190`）：

```cpp
:2161  return true;                                    // 未配置
:2162  if (state.location == INACTIVE || level < 0) return true;   // 已排除
:2165  if (state.level >= definition.level_count) return true;     // 已排除
:2167  if (definition.copy_left_programs != 0) { ... }             // ← 未查
:2182  if (program.empty()) continue;                              // ← 未查
:2184  if (!family_effect_metadata_pod(program, metadata)) continue;  // ← 未查
:2188  resolve_effect_targets(...)                                  // ← 未查
:2190  if (!targets_ok) continue;                                   // ← 未查
```

**最可能的是 `:2184 family_effect_metadata_pod` 返回 false**——廉价探针的 `configure_effects`
用的目录可能不包含理念卡的程序定义（理念 program 是 `ideology.effect.*` 命名空间，
而 `configure_effects` 期望的是 effect 域目录）。

**这是一个具体、可验证的下一个检查点。**

## 4. 为什么收束

| 事实 | 影响 |
|---|---|
| 真实世界验证支线已用 **10 轮**（M3-12 → M3-22） | 60 轮已用 55 |
| 每轮都有实质进展，但答案仍未到手 | 边际收益递减 |
| **M4 与 M5 完全未开始** | 目标是做到 M5 |
| M3 的**功能实现**完整 | 265/265、求值器、物化器、rollout、回归零变化 |

## 5. 完整的交接（下一步极其具体）

在廉价探针（10 秒/轮）里加一条断言：

```gdscript
var pod: Dictionary = ext.probe_family_effect_metadata(dense_program_key)
print(pod)   // 若 ok=false，就是 :2184 在拒绝
```

若 `pod` 失败，则需在 `configure_effects` 时传入包含理念程序的定义
（`ideology.effect.salt_monopoly` 一类），而不是通用的 effect 域目录。

**这条检查只需 10 秒，且能直接判定。**

## 6. 十轮的净收获（全部可复用）

| 项 | 价值 |
|---|---|
| **完整 12 步激活序列** | 已验证可让理念 ACTIVE |
| `sequences` 幂等键 | 我自己的真 bug |
| `create_entities` 决定槽长度 | 卡 4 轮的真因 |
| `run_economy_slice` 需跑到 done | 一片不够（14 片）|
| 回执诊断法 | status=1 成功 / 2 已应用 / 3 被拒 |
| 并行数组快照 | `idea_ids`/`locations`/`levels` |
| 廉价探针 | 10 秒 vs 10 分钟（60×）|
| **16 项否定清单** | 后续者不必重复试错 |

## 7. 验证

| 项 | 值 |
|---|---|
| 理念 ACTIVE | ✅ `locations=[1]` |
| `equip` status | **1（成功）** |
| rebuild_visits | 5 |
| `seen` / `taken` | **0 / 0** |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / coverage 6-6 全 0 |
| 回归（rollout ON） | 零判定变化 |

## 8. 局限

- **仍未取得 ramp 真实幅度。**
- 未验证 `:2184` 的 `family_effect_metadata_pod`。
- 真实世界夹具（6144 格）仍未复现激活；廉价探针能，两者差异未查明。
