# M5-29 §16.5 完成：9/9 文档 + 3/3 skill

| 项目 | 内容 |
|---|---|
| 里程碑 | [§16.5](22-cell-program-cap-removal-plan-v3.md) 文档与 skill 同步 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **9 份文档全部补齐，3 个相关 skill 全部补齐** |

## 1. 本轮补的三份

| 文档 | 章节 | 关键内容 |
|---|---|---|
| `gdscript-cpp-data-bridge.md` | 「理念派生地块层的桥」| 7 个桥的字段表 + **三个必知参数细节**：① `entity_handle` 必须是 0、cell 放 `cell` 参数（传错会看起来像「派生不存在」）② `install_..._for_test` 的列名是 `source_countries`/`adds` ③ metric 数组按 `metric_keys` 索引填，当前与 `FamilyEffectMetricId` 恒等但**不要假设永远如此** |
| `runtime-authority-matrix.md` | 「理念派生地块层的权威归属」| 4 类数据的权威与是否持久化对照；**三条权威规则**（派生层不放 Store、后端判定只有一处、I01 一个 program 一个后端）；读档后的权威时序 |
| `game-flow-start-save.md` | 「理念派生地块层不参与存档」| 格式版本未变、旧档可读、`serialize_domain`/`restore_domain` 完全不碰 front；**为什么可以这样**（front 完全由已恢复输入决定）；**不要做的两件事**（别把 front 塞进存档「修复」窗口、别在读档路径直接读派生层当已就绪）|

## 2. §16.5 的九项逐项状态

| # | 文档 | 轮次 |
|---|---|---|
| 1 | `native-ideology-runtime` | M5-21 |
| 2 | `native-modifier-runtime` | M5-21 |
| 3 | `native-economy-runtime` | M5-28 |
| 4 | `runtime-authority-matrix` | **M5-29** |
| 5 | `scheduling-and-job-graph` | M5-28 |
| 6 | `gdscript-cpp-data-bridge` | **M5-29** |
| 7 | `performance-diagnostics-playbook` | M5-28 |
| 8 | `game-flow-start-save` | **M5-29** |
| 9 | `runtime-deletion-inventory` | M5-10 |

**9 / 9。**

| skill | 状态 |
|---|---|
| `project-keynes-ideology-runtime` | ✅ `references/runtime-contract.md` +§7 |
| `project-keynes-modifier-runtime` | ✅ `references/architecture-and-data.md` + Derived Cell Layer |
| `project-keynes-economy-runtime` | ✅ `references/architecture-and-data.md` + 经济侧影响 |

**3 / 3。** 三个都在 `.claude` 与 `.agents` 双镜像上验证过。

## 3. 这次同步累积发现的既有问题（都不是我造成的）

| 位置 | 问题 | 处理 |
|---|---|---|
| modifier skill | 4 个文件双镜像不一致（`.agents` 更新）| 修 2 个严格超集；**拒绝 2 个**（`.claude` 有 `PKEC v33` 独有行，无法判定哪边权威）|
| economy skill | HEAD 里就有 6 行分歧 | **记录不覆盖** |
| `docs/cpp-dots-runtime/` | §16.5 的九项里**大部分是文档不是 skill** | 纠正了我自己的假设 |

**这三条都写进了对应的里程碑报告，没有为了让「同步完成」好看而强行覆盖。**

## 4. 对 §18 的影响

| 项 | 之前 | 现在 |
|---|---|---|
| §18.4「native docs、架构边界、skill、内容文案与 UI 同步」| debug/release ✅、文档部分 | **文档 ✅ 9/9、skill ✅ 3/3；内容文案与 UI 仍缺** |

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md` | +1 节（1737 行）|
| `docs/cpp-dots-runtime/runtime-authority-matrix.md` | +1 节（449 行）|
| `docs/cpp-dots-runtime/game-flow-start-save.md` | +1 节（642 行）|
