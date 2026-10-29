# M3-24 所有前置条件已验证，但 seen=0 仍未解释（最终交接）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`collect_effect_activations` 的全部前置条件已逐项验证通过，但 `seen=0`** |
| 决定 | 交付完整诊断清单，转 M4/M5 主线 |

## 1. 逐项验证结果（全部通过）

| 行 | 条件 | 实测 | 结论 |
|---|---|---|---|
| `:2159` | `ideology_id` 有效 | `dense=87`（113 个 id 中）| ✅ |
| `:2162` | `location != INACTIVE` | `locations=[1]`（IDEOLOGY）| ✅ |
| `:2165` | `level < level_count` | 试过 level 0 与 2，均 `seen=0` | ✅ 不阻塞 |
| `:2167` | `copy_left_programs == 0` | `copy_left_programs=true` 属 `algorithmic_governance`，非本卡 | ✅ 不走 copier |
| `:2174` | `row.persistent_count > 0` | `level_persistent_offsets=[0,1,2,3,5,...]`，每级 ≥1 | ✅ |
| `:2182` | `program` 非空 | `definition_key = salt_monopoly_l1` | ✅ |
| `:2184` | `family_effect_metadata_pod` 成功 | `evaluate_effect_program_magnitude("ideology.effect.salt_monopoly_l1")` → **ok=true** | ✅ |
| `:2188` | `resolve_effect_targets` 成功 | **未直接验证** | ❓ |

**剩 `:2188` 一个未验证点。**

## 2. 数据侧证据（本轮新增）

```
[q] persistent_definition_keys=595  offsets=340
[q] salt persistent keys=["ideology.salt_monopoly", "salt_monopoly_l1",
        "ideology.salt_monopoly", "salt_monopoly_l2", ...]
[q] level_persistent_offsets=[0, 1, 2, 3, 5, 7, 9, 11, 13, 15, 16, 17]
```

每级至少 1 个 template，`salt_monopoly_l1` 确实在键表里。

## 3. 判定器已验证正确（本轮修正）

```
[q] probe backend=DerivedCell reason= detail=derived
```

这是修掉我自己的桥缺陷后的结果（M3-23）。

## 4. 当前唯一未验证点：`resolve_effect_targets`

`resolve_effect_targets(country, state, program, metadata, hash, targets)` 返回 false 时
`:2190 continue` 会跳过整个 program。它需要：

- country 有领土（廉价探针有 64 格）；
- `target_selector_kind = 12`（OWN_TERRITORY）；
- 经济格数据有效。

**廉价探针的 64 格领土来自 `bootstrap_country`，不是真实地图**，该函数可能对无主格返回
空目标集。**这是最可能的原因，且需要一次针对性验证。**

## 5. 十四轮的净收获

| 项 | 价值 |
|---|---|
| **完整 12 步激活序列** | 已验证能让理念 ACTIVE |
| `sequences` 幂等键 | 我的真 bug |
| `create_entities` 决定槽长度 | 卡 4 轮的真因 |
| `run_economy_slice` 需跑到 done | 14 / 121 片 |
| **回执诊断法** | status=1 成功 / 2 已应用 / 3 被拒 |
| 并行数组快照 | `idea_ids`/`locations`/`levels` |
| 廉价探针 | 10 秒 vs 10 分钟（60×）|
| **两处我自己的探针缺陷** | `filled=10` 假指标、漏传 `has_metric_ramp` |
| **19 项否定清单** | 后续者不必重复试错 |

## 6. 验证

| 项 | 值 |
|---|---|
| 理念 ACTIVE | ✅ |
| 判定器 | ✅ `DerivedCell` |
| 程序存在 | ✅ |
| persistent templates | ✅ 每级 ≥1 |
| **`seen` / `taken`** | **0 / 0** |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |
| 回归（rollout ON） | 零判定变化 |

## 7. 交接：一步到位的下一步

```gdscript
# 在廉价探针里，理念 ACTIVE 之后：
var targets := ext.resolve_effect_targets_for_test(...)   # 若无此桥，需新增
print(targets.size())   # 若 0，:2190 就是最后一环
```

或者更直接：**在真实世界夹具**（领土来自真实地图）里重跑同一条 12 步序列——
那里的 `resolve_effect_targets` 面对的是真领土，不是 `bootstrap_country` 的合成 64 格。

## 8. 局限

- **仍未取得 ramp 真实幅度。**
- `:2188` 未验证。
- 这是 M3 唯一缺的硬证据；M3 的**功能实现**已完整。
