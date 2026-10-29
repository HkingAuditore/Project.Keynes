# M3-18 完整根因：`ideology_class_opinion_unavailable`

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **理念命令全部打通**；`equip` 被拒的确切原因已查明 |
| 结论 | 只差 **class opinion**（政治阶级支持度），其余全部就绪 |

## 1. 决定性证据：回执里的原因

```
receipts count=4 statuses=[2, 2, 2, 3] reasons=["", "", "", "ideology_class_opinion_unavailable"]
```

| # | 命令 | status | 含义 |
|---|---|---|---|
| 1 | grant points | 2 | **成功** |
| 2 | discover | 2 | **成功** |
| 3 | understanding | 2 | **成功**（levels 升到 2）|
| 4 | **equip** | 3 | **被拒：`ideology_class_opinion_unavailable`** |

**三条命令成功、一条被拒，原因精确到字符串。**

## 2. 本轮真正解决的核心问题：`sequences` 幂等键

这是五轮调查的关键突破：

```gdscript
// 错误：每批都从 1 开始
sequences.append(i + 1)

// 正确：跨批单调递增
_seq += 1
sequences.append(_seq)
```

`submit_commands` 会丢弃 `sequence <= producer_high_watermark` 的命令
（`ideology_runtime.cpp:4536-4539`）。我每批都重置为 1，所以**第一条之后的命令全被当作重复静默丢弃**，
表现为 `accepted=0 duplicates=1`、`pending_commands=0`、`receipts=0`。

改掉之后：`duplicates=0` → `commands_applied=1` → `receipts count=4`。

## 3. 另外两个读错的结构

| 我的假设 | 实际 |
|---|---|
| `snapshot["ideas"]` 是 dict 列表 | 实际是**并行数组** `idea_ids` / `locations` / `levels` / `understanding_q16` / `slot_indices` / `transition_pending` |
| `poll_receipts` 在日推前调 | 必须在**日推之后**调；被拒命令的收据在 `apply_command` 里才写入（`:4672`）|

## 4. `ideology_class_opinion_unavailable` 是什么

`equip` → `support_gate(country, ideology_id, SUPPORT_ADOPT, error)`（`ideology_runtime.cpp:4290-4292`）。

这个门需要政治阶级对理念的支持度，而支持度来自 Economy 的 class opinion 快照——也就是
**economy 必须跑过至少一次 epoch**（`required_environment_slot_missing` 那道门）。

**完整因果闭环：**

```
equip
  -> support_gate(SUPPORT_ADOPT)
     -> 需要 class opinion
        -> 需要 economy epoch
           -> 需要 10 个环境槽（M3-15 记录）
              -> 需要真实 MapData 或手工注册槽
```

## 5. 五轮调查的完整否定清单

| # | 曾怀疑 | 反证 |
|---|---|---|
| 1 | rollout 关闭 | 打开后仍 `seen=0` |
| 2 | 国家无理念 | 采纳后仍 `seen=0` |
| 3 | 结算阶段不足 | 补 5 阶段后仍失败 |
| 4 | dense id 错 | `dense=87` 后仍失败 |
| 5 | 需 economy opinion | `GRANT_IDEOLOGY_POINTS` 后仍 `ideas=0` |
| 6 | `validate_country` 失败 | 补 country 配置后仍失败 |
| 7 | 命令被拒 | `receipts=0`（时机不对）|
| 8 | **`sequences` 幂等键** | ✅ **是**（`duplicates=1`）|
| 9 | **class opinion 缺失** | ✅ **是**（`equip` 的确切拒绝原因）|

**两个真问题，一个是我夹具的错（`sequences`），一个是真实依赖（class opinion）。**

## 6. 验证

| 项 | 值 |
|---|---|
| grant / discover / understanding | **status=2（成功）** |
| equip | status=3，`ideology_class_opinion_unavailable` |
| `duplicates` | 0 |
| levels | 00 → **2**（理解度生效）|
| 探针耗时 | 约 10 秒 |
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 7. 剩余的一步

要让 `equip` 成功，需要 class opinion，即 economy epoch。而上轮的 10 个环境槽 `filled=0`
（`component_id` 返回 -1，槽未注册）。

**下一步只有一件事**：注册那 10 个环境槽。M1-8 已确认 `write_f32_range` / `write_u8_range` 可用，
缺的是**槽本身的注册**（`component_schema.gd` 通过 `bind_map_data` 完成，需要真实 MapData 或等价注册入口）。

## 8. 局限

- **仍未取得 ramp 真实幅度。** `equip` 未成功，理念未激活，`seen` 仍会是 0。
- 10 个环境槽的注册路径未找到。
- 未尝试直接给 `support_gate` 一个绕过开关（若有）。

## 9. 五轮的净收获

| 项 | 价值 |
|---|---|
| **秒级探针** | 10 秒 vs 10 分钟，60 倍提升 |
| 完整的命令协议 | grant/discover/understanding/equip + 并行数组快照 + 收据时机 |
| 9 项否定清单 | 后续者不必重复试错 |
| **两个真问题** | `sequences` 幂等键（已修）+ class opinion（真实依赖）|
| 回执诊断法 | 无回执=未处理，status=2 成功、3 被拒且带原因 |
