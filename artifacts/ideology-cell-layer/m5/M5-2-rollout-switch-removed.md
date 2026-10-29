# M5-2 删除迁移开关：rollout 不再是门控

| 项目 | 内容 |
|---|---|
| 里程碑 | [M5](../22-cell-program-cap-removal-plan-v3.md) §15.7 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **`kCellProgramRollout` 与 `CellProgramRollout` 枚举已删除** |
| 验证 | 全回归 **18/18**、覆盖率门禁 **6/6**、内核 **67/0**，行为零变化 |

## 1. 删了什么

| 项 | 处置 |
|---|---|
| `CellProgramRollout` 枚举（Off/Constants/Continuous/Sources）| **删除** |
| `kCellProgramRollout` 常量 | **删除** |
| `cell_program_rollout_enabled` 的四段 switch | **改为一行**：`return cell_program_selector_supported(selector_kind);` |
| `get_cell_program_rollout()` 的 `out["rollout"]` 枚举回显 | 改为 `1` + 新增 `rollout_stage_removed = true` |

## 2. 为什么现在可以删

§15.7 原文：「生产固化执行后端；删除迁移期开关、tier 分支及仅为旧平面存在的逻辑。」

分阶段开关存在的唯一理由是「每个里程碑单独评审后再改变生产行为」。四个阶段都跑完了：

| 阶段 | 结果 |
|---|---|
| `Off` → `Constants` → `Continuous` | 15-fixture 回归无变化 |
| `Continuous` → `Sources`（**I01 修复前**）| `x1b` 142/0 → 142/13，其中 12 条数值分歧（1.23999 vs 1.12）|
| **I01 修复后** | 13 → 4，全是实例列表断言 |
| 断言迁移为 `_target_count()` 后 | **142/0** |
| 最终 | B7 15/0、B8 18/0、B10 16/0、x1b 142/0、stress 38/0 |

**继续保留它意味着：出厂行为取决于一个没人会再翻的常量，而读者要追四个枚举值才能知道运行时会做什么。**

## 3. 删后的一致性问题

删掉开关后，代码里只剩一个问题：**这个 selector 能被派生层表达吗？**

```cpp
inline bool cell_program_rollout_enabled(int32_t selector_kind) {
    // No switch: expressible means enabled.
    return cell_program_selector_supported(selector_kind);
}
```

**注意**：这不是「所有卡都派生」——`decide_cell_program_backend` 仍按 9 条理由逐条判定。删除的是「表达能力」之外的第二道门。

保留函数名是因为报告里还有字段要取它，且让读者一眼看到「现在是无条件的」。

## 4. 关键验证：行为零变化

| 项 | 结果 |
|---|---|
| 全回归 | **18 / 18** |
| 覆盖率门禁 | **6 / 6**（288 总数、265 在范围内、265 全派生、ramp deferred 0）|
| 内核单测 | **67 / 0** |

**18 个 fixture 覆盖了 B7（1600 格）、B8（144 来源）、B10（两国）、x1b（kind 16 来源计数）、tag 翻转压力等，全部与删除前一致。**

这是「开关已经无效」的证据，而不是「我删了它居然没坏」。

## 5. §15.7 进度

| 任务 | 状态 |
|---|---|
| 全部 A–F 在受测配置 ON | ✅ 265/265 |
| 删除旧 v1 平面 | ✅ M5-1：144 行死代码 |
| **删除迁移开关** | ✅ **本次完成** |
| 32 常量改 legacy 名 | ✅ `LEGACY_INSTANCE_MAX_CELLS` |
| 全量构建、回归、B1–B12、save/load、权威翻转、UI | ⬜ 18 fixture 已跑，其余未测 |
| 文档与 skill 同步（§16.5）| ⬜ |

## 6. 局限

- `build_cell_program_table` 等旧平面 API 未审计是否还有读者。
- B1–B12 只覆盖了 B7/B8/B10；B1–B6、B9、B11、B12 未测。
- save/load、权威翻转、UI 高亮未测。
- 文档与 skill 未同步。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `cell_program_eligibility.h` | 枚举与常量删除；predicate 改为无条件 |
| `world_ext_modifier.cpp` | `rollout` 字段改为布尔语义 + `rollout_stage_removed` |
