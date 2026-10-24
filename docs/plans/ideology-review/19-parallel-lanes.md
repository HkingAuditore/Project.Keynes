# 19 - Doc 02 能力并行实现方案（车道划分）

> 日期：2026-10-23。作者：reviewer。用途：回答「X4/5/6/8/9 等 Doc 02 能力能否并行」，并给出可直接执行的车道划分与协作规则。
> 前提：只走 worker 路径；parity 冻结；不做数值平衡；cap=3（见 11 §1）。

## 0. 结论

**能部分并行，最多两条 R 会话（R1 + R2）。** 不建议三条以上：

- 单一 DLL、单一 scons、单个 worker 测试 1-2 分钟，三条会话会互相抢 CPU、互相覆盖 DLL。
- 各能力共享少数几个「热点文件」和「版本号」，冲突是结构性的，必须靠预留和合并 bump 才能拆开。
- DeepSeek 会话彼此没有上下文，并行越多，reviewer 对账成本越高。

## 1. 为什么不能全并行：共享冲突点（代码事实）

| 冲突点 | 位置 | 谁会改 |
|---|---|---|
| metric 总数 | `gdext/src/economy_runtime.h:552` `FAMILY_METRIC_COUNT = 70`，`:111` `PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY = 70`（static_assert 绑定） | X13(70-74)、X12(75-76)、X14(77-78)、X10(79-83)、X9-a(84-86) |
| Effect POD ABI | `gdext/src/runtime_effect_pod.h:28` 当前 `3u` | 14（托管生命周期）、X4（层环） |
| PKEF | `gdext/src/effect_runtime.h:41` 当前 13 | 14、X4 |
| PKID / IDP2 | `ideology_runtime.h:48` 当前 8；`runtime_ideology_pod.h` ABI 6 | X6-b/c（free_draws、slot_index）、意识形态侧标量 |
| Economy schema | economy 存档 56 | X13-a、X4-b |
| 实例解析热路径 | `ideology_runtime.cpp` `collect_effect_activations` / `resolve_effect_targets` / 签名 | X1-b、X5、X4、X6-c、标量 |
| worker Effect | `runtime_effect_pod.cpp` | 14、X4 |
| commit 尾 / 环境采集 | `economy_runtime.cpp` commit tail、`capture_environment`、metric 填充 | X12、X14、X10、X9-a、X13、X4 事件快照 |
| 生成器 | `generate_ideology_catalog.py` 单文件（能力开关、metric 表、tag） | 全部 |
| GDScript metric 名 | `effect_domain_catalog.gd` `metric_keys` | 所有新 metric |

硬依赖：X4 依赖 14；X13-b 依赖 X4；X6-b 依赖 X4；X10 的事件部分依赖 X4；X8 复用 X1-b 内核。

## 2. 车道划分

| 车道 | 内容（按顺序） | 主要文件 | 版本影响 |
|---|---|---|---|
| **L1 核心（关键路径，R1）** | 12-r7 收尾 → 14 → 12-r7 F/G → X1-b → X5 → X4 → X8 → X6-c → X13-b | `ideology_runtime.cpp`、`runtime_effect_pod.*`、`effect_runtime.cpp`、`effect_instance_forwarder.cpp` | Effect POD ABI / PKEF（一次合并 bump，见 §3.2） |
| **L2 Economy 派生列（R2）** | X12 → X14 → X10 计数部分 → X9-a → X13-a | `economy_runtime*.cpp` commit 尾、`target_tag.h`、`country_runtime` 只读接口 | Economy schema（与 X4-b 合并 bump） |
| **L3 Ideology POD（R2，L2 之后或穿插）** | 意识形态侧标量（equipped/route/synergy count、unlocked_era）→ X6-a → X6-b（需 X4 的接口冻结后） | `runtime_ideology_pod.*`、`ideology_runtime.cpp` 的 POD 字段段 | PKID / IDP2 一次 bump |

L2 基本只做「COMMIT 时算新列 + 注册 metric 号 + 生成器开关」，与 L1 的实例解析路径几乎不重叠，这是最值得并行的部分。

L3 与 L1 都碰 `ideology_runtime.cpp`，但区域不同（POD 字段 vs 实例解析）。L3 排在 R2 的 L2 之后，降低同期冲突。

## 3. 协作规则（并行前必须先做）

### 3.1 先提交现有成果（硬前提）

当前只有一个 worktree，HEAD `2c1f7a00`，所有 R 的成果都是**未提交**的脏改动。`git worktree add` 只会从提交出发，不会带上脏改动。所以：

1. R 收尾当前 12-r7（删 `PK_X16_PROBE` 探针，构建与测试通过）。
2. 把 ideology / effect / economy / 生成器 / 测试 / 文档相关改动提交到一个分支，例如 `codex/ideology-infra-base`。**不要把无关的音频改动混进去**，按路径挑选 `git add`。
3. 之后两条车道都从这个提交分出。

### 3.2 一次性预留（在基线提交里或紧接着的单独提交里完成，由 R1 做）

- **metric 号段预留**：把 `FAMILY_METRIC_COUNT` 与 `PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY` 一次性提到 87，70-86 按 16/17 号文档的分配填占位名（`RESERVED_X13_ANNUAL_TEMP` 等），`effect_domain_catalog.gd` 同步占位 key。之后各车道只「填实现」，不再改总数。
- **合并 bump**：
  - Effect POD ABI 3→4 与 PKEF 13→14：覆盖 14 + X4 的全部新字段，由 L1 独占。
  - Economy schema 56→57：覆盖 X13-a 持久字段 + X4-b 计数，由 L2 独占；L1 的 X4-b 需要的字段由 L2 先放好。
  - PKID 8→9 / IDP2 6→7：覆盖 X6 + 标量，由 L3 独占。
  - 规则：**每个版本号只归一条车道**；别的车道需要字段时提需求，不自己 bump。
- **生成器分块**：在 `generate_ideology_catalog.py` 里给每个能力留独立的 `# === CAP Xn BEGIN/END ===` 区块（metric 表、tag、能力开关各一段），减少文本合并冲突。`AVAILABLE_CAPABILITIES` 每车道只改自己那一行。

### 3.3 工作区与构建

- R1 留在主目录 `D:\Godot\ProjectKeynes\Project.Keynes`（分支 `codex/ideology-lane1`）。
- R2 用独立 worktree：`git worktree add ..\pk-lane2 -b codex/ideology-lane2 codex/ideology-infra-base`。
  - 注意 `gdext/godot-cpp` 是子模块：新 worktree 里需 `git submodule update --init`，godot-cpp 首次要完整编译一次（较慢）。
  - R2 的 DLL 只在 `..\pk-lane2` 里构建与测试，**绝不覆盖主目录的 DLL**。
- 两条车道错开跑测试（同时跑 Godot headless 会让计时测试不稳）。
- 删 worktree 时用 `git worktree remove --force ..\pk-lane2`（之前 `../tmp/wt_base` 失败多半是里面有未跟踪的构建产物），或先 `git worktree prune`。

### 3.4 集成节奏

- 每完成一个能力，R2 rebase 到最新的 lane1（或反向合并），由**一个会话**负责合并与重建主 DLL。
- 每个能力合入前必须有自己的 worker 测试：装配 → 生效 → 卸下 → 恢复（11 §2 第 4 条）。
- 合入后在主目录重跑：`runtime_domain_pod_test`、`runtime_ideology_save_roundtrip_test`、`ideology_card_content_test`、该能力的 worker 测试、审计脚本。

## 4. 不并行的情况

如果用户不想处理 worktree / 子模块 / 合并，那就保持单 R 串行。单 R 估计 15-20 轮；双车道理论上把 L2+L3（约 7-8 轮）从关键路径上拿掉，关键路径变成 L1 的约 10-12 轮，外加 2-3 轮集成成本。**实际节省约 25-35%，不是一半。**

## 5. 可直接粘贴的会话提示

### 5.1 发给现有 R（R1，先做基线和预留）

```text
先收尾 12-r7 当前项：删除 world_ext_economy.cpp 里的 PK_X16_PROBE 临时探针，构建末行必须是 scons: done building targets.，跑 X16、身份、P1-b 重启、save roundtrip 测试，贴末行原文。

然后为并行做准备（见 docs/plans/ideology-review/19-parallel-lanes.md §3）：
1. 只挑 ideology/effect/economy/runtime/生成器/测试/ideology-review 文档相关路径 git add，提交到新分支 codex/ideology-infra-base。不要提交音频等无关改动，不要 revert 任何东西。
2. 单独一个提交做预留：FAMILY_METRIC_COUNT 与 PK_EFFECT_INPUT_METRIC_REVISION_CAPACITY 提到 87，70-86 按 16/17 号文档填占位名，effect_domain_catalog.gd 同步占位 key；生成器加每能力的 BEGIN/END 区块。预留不改行为，所有现有测试必须保持原结果。
3. 报告提交 hash。之后你是 L1 车道：14 → 12-r7 F/G → X1-b → X5 → X4 → X8 → X6-c → X13-b。Effect POD ABI 与 PKEF 只归你 bump，一次合并覆盖 14+X4。Economy schema 和 PKID/IDP2 不归你，需要字段时写进 19 号文档 §6 需求栏。
```

### 5.2 新开 R2（在 R1 报告基线提交 hash 之后）

```text
你是 Project.Keynes 意识形态基建的 L2/L3 车道。先读：
- docs/plans/ideology-review/11-infra-first-roadmap.md（目标与 DoD）
- docs/plans/ideology-review/19-parallel-lanes.md（车道规则，必须遵守）
- docs/plans/ideology-review/16-x13-brief.md、17-x10-x12-x14-x9-brief.md、18-x6-x8-brief.md
- 技能 project-keynes-ideology-runtime（含 references/pitfalls-and-build.md）、project-keynes-economy-runtime

工作区：在 ..\pk-lane2 新建 worktree，分支 codex/ideology-lane2，基于 <R1 给的基线提交>。git submodule update --init 后在该目录构建。绝不修改主目录 D:\Godot\ProjectKeynes\Project.Keynes 的任何文件或 DLL。

顺序：X12 → X14 → X10 计数部分 → X9-a → X13-a，然后 L3：意识形态侧标量 → X6-a → X6-b（等 L1 的 X4 接口冻结）。
规则：metric 号只用预留号段里属于你的号；Economy schema 56→57 和 PKID/IDP2 由你独占、各只 bump 一次；不碰 Effect POD ABI/PKEF、不碰 collect_effect_activations/resolve_effect_targets。
每个能力：实现 → 生成器开关 → worker 测试（装配→生效→卸下→恢复）→ 贴构建末行与测试末行原文 → 提交。不做数值平衡，不做 parity。
```

## 6. 跨车道需求栏

| 提出方 | 需要什么 | 归属车道 | 状态 |
|---|---|---|---|
| L1 X4-b | Economy 存档里的新职业 / 工人增量计数字段 | L2（schema 57） | 待定 |
| L3 X6-b | X4 的事件入口接口（`on_event` 结构） | L1 | 待 X4 冻结 |
