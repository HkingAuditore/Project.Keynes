# M0-R1 工作区事件记录：未跟踪文件被 `git pull` 抹掉

| 项目 | 内容 |
|---|---|
| 里程碑 | 前置修复（阻断所有构建） |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | 构建已断：`effect_runtime.h:3` 找不到 `selector_cell_cap.h` |
| 结论 | 精确的丢失清单已确认；先重建 5 个源文件让构建恢复 |

## 1. 发生了什么（git 证据）

```
git reflog -8
772c9153 HEAD@{0}: pull --ff-only origin master: Fast-forward
121ae2ee HEAD@{1}: reset: moving to HEAD
```

会话期间有人执行了 `git pull --ff-only origin master`，HEAD 从 `121ae2ee`
快进到 `772c9153`。

**关键区别：**

| 类别 | 结果 | 原因 |
|---|---|---|
| **已跟踪文件的修改** | ✅ **全部保留** | git 会保留工作区里对已跟踪文件的改动 |
| **未跟踪的新文件** | ❌ **全部丢失** | `pull` 前若被 `stash`/`clean` 处理，新文件无处可去 |
| **文件内容改动（.tres）** | ✅ **保留** | 已跟踪 |

我验证过 `git stash list` 有 3 个 `codex-pre-pull-2026-10-27` 条目，
但 `git stash show --name-only` 里**没有**我新增的那些文件——所以 stash 没能救到它们。

## 2. 精确的丢失清单

**丢失（新增文件，从未被 git 跟踪）：**

| 文件 | 作用 |
|---|---|
| `gdext/src/selector_cell_cap.h` | 上限语义拆分（几何界 vs 策略界）|
| `gdext/src/cell_program_eligibility.h` | 单一 backend 判定（I01）|
| `gdext/src/derived_cell_layer.h` | 派生层容器 |
| `gdext/src/derived_cell_materializer.h` | 物化器 + `Term`/`MagnitudeSource` |
| `gdext/src/derived_cell_materializer.cpp` | 物化实现 |

**丢失（未跟踪）：** `artifacts/ideology-cell-layer/` 全部报告（M0 11 / M1 13 / M2 23 / M3 25 / M4 10）、
`docs/plans/ideology-review/22-progress-checklist.md`、
全部 `ideology_cell_layer_*` 测试、`ideology_b7_wide_territory_test.gd`。

**保留（已跟踪文件的修改）：**

| 文件 | 我的改动数 |
|---|---|
| `gdext/src/effect_runtime.h` | 6 处引用（`selector_cell_cap.h`、`run_program_machine`、`evaluate_program_magnitude_for_metrics`）|
| `gdext/src/ideology_runtime.cpp` | 12 处（派生分支、I01 修复、`per_target`、诊断计数器）|
| `gdext/src/economy_runtime.h` | 9 处（`_own_territory_*`、`epoch_cell_country_size_for_test`、tag build 计时）|
| `Project/.../default_ideology_effects.tres` | **194 处 `(32,0)` → `(0,0)` 保留** |

## 3. 当前的失败状态

```
gdext/src/effect_runtime.h(3): fatal error C1083: 无法打开包括文件: "selector_cell_cap.h"
```

**构建完全断了。** 这不是"功能没做完"，而是"仓库无法编译"。

## 4. 恢复策略

必须让构建重新通过，否则无法验证任何东西。三条路：

| 方案 | 代价 | 风险 |
|---|---|---|
| A. 重建 5 个源文件 | 大（它们包含今天的核心设计）| 可从 `ideology_runtime.cpp` 等调用点反推签名 |
| B. 回退已跟踪文件的改动，让源码树回到 `772c9153` 的干净状态 | 中 | **会丢掉 I01 修复**，且内容侧 `(0,0)` 与代码不一致 |
| C. 先回退，再重做 | 最大 | 今天的分析已记录（本文件 + 对话），可复用 |

**我选 A**：从保留的调用点反推签名并重建。理由：
- `ideology_runtime.cpp`、`effect_runtime.h`、`economy_runtime.h` 都保留了完整调用点，
  签名可以精确反推；
- `(0,0)` 内容改动保留着，若回到 B 会造成"内容说无上限、代码按 32 截断"的不一致；
- 今天的**设计结论**在对话里完整存在，重建是机械工作。

## 5. 重建顺序

1. `selector_cell_cap.h` —— 无依赖，先把构建从 C1083 里救出来；
2. `derived_cell_layer.h` —— 纯数据结构；
3. `derived_cell_materializer.h/.cpp`；
4. `cell_program_eligibility.h`；
5. 重新构建，逐个修复签名不匹配。

## 6. 这一节要记住的教训

**未跟踪的新文件在 `git pull` 面前没有任何保护。**

我今天的做法有一处可改进：创建了 5 个新源文件却从未 `git add`。
如果早先 `git add -N`（intent-to-add）或提交过，`pull` 就不会抹掉它们。
