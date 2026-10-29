# M5-28 文档同步第二轮（§16.5）

| 项目 | 内容 |
|---|---|
| 里程碑 | [§16.5](22-cell-program-cap-removal-plan-v3.md) 文档与 skill 同步 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | 3 份 native 文档 + 1 个 skill（双镜像）补齐派生层内容 |

## 1. 补了什么

| 文件 | 新增章节 | 关键内容 |
|---|---|---|
| `native-economy-runtime.md` | 「城市因子 CSR 现在包含派生层覆盖的格」| `collect_scope_stat_entries` 的并集（`modifier_runtime.cpp:1571-1584`）；**不加这条并集，只有派生贡献的格不在工作集里，读者会静默退回 `shared`**；逐格取值走 `effective_value`（`:7327`）|
| `scheduling-and-job-graph.md` | 「派生地块层重建进入每日图」| 单步 0.45 ms 预算、采集与折叠**必须分两步**（合起来首步 1.03 ms）、`done()` 的 `_started` 细节、换日丢半成品、空闲日不重建；**片数随形态变化**（常数卡 6400 格 3 片 / ramp 卡 1600 格 25 片）|
| `performance-diagnostics-playbook.md` | 「派生地块层的诊断口径」| 8 个计数器**哪些是累积量、哪些是本次运行量**的对照表；两个必记口径；一个真实教训（`cell_layer_rebuild_visits` 丢了 `++` 导致假失败）|
| `project-keynes-economy-runtime` skill | 「Derived cell layer 对经济侧的影响」| 与文档同源的短版，指向具体行号 |

## 2. 我先前的一个错误假设

我以为 `gdscript-cpp-data-bridge` 和 `performance-diagnostics-playbook` 是 **skill**，
去 `.claude/skills` 下找，**没找到**——它们是 `docs/cpp-dots-runtime/` 下的**文档**。

**§16.5 的九项里，大部分是文档，不是 skill。** 我按 skill 去查证了半轮才发现。
正确的读法是：`native-*` / `runtime-*` / `scheduling-*` / `-bridge` / `-playbook` 都是文档名。

## 3. 顺带确认的两处镜像状态

| skill | 我改的部分 | 镜像 | 既有分歧 |
|---|---|---|---|
| `project-keynes-ideology-runtime` | 双镜像**完全一致** | ✓ | 无 |
| `project-keynes-modifier-runtime` | 双镜像一致 | ✓ | 4 个文件既有分歧，修了 2 个、拒绝 2 个（见 M5-21）|
| `project-keynes-economy-runtime` | **我新增的 14 行在两边逐字节相同**（`tail_equal=True`）| ✓ | **既有 6 行分歧**（`.claude` 289 / `.agents` 295，`git diff HEAD` 显示两边各 +14 即我的改动）|

经济 skill 的既有分歧是 `.agents` 多一段「生产气候损失适配」的内容，**在 HEAD 里就存在**，
不是我造成的。我按 M5-21 的同一原则**记录而不强制覆盖**。

## 4. §16.5 的完成度

| 项 | 状态 |
|---|---|
| `native-ideology-runtime` | ✅ M5-21 |
| `native-modifier-runtime` | ✅ M5-21 |
| `runtime-deletion-inventory` | ✅ M5-10 |
| `native-economy-runtime` | ✅ **本轮** |
| `scheduling-and-job-graph` | ✅ **本轮** |
| `performance-diagnostics-playbook` | ✅ **本轮** |
| `gdscript-cpp-data-bridge` | ⬜ 未补（新增的桥还没写进去）|
| `runtime-authority-matrix` | ⬜ 未补 |
| `game-flow-start-save` | ⬜ 未补（派生层不持久化这一条值得写）|
| skill：ideology / modifier / economy | ✅ 三个都补了 |

**6 / 9 文档 + 3 / 3 相关 skill。**

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `docs/cpp-dots-runtime/native-economy-runtime.md` | +1 节（2229 行）|
| `docs/cpp-dots-runtime/scheduling-and-job-graph.md` | +1 节（1498 行）|
| `docs/cpp-dots-runtime/performance-diagnostics-playbook.md` | +1 节（2897 行）|
| `.claude` / `.agents` × `economy-runtime/references/architecture-and-data.md` | 各 +14 行，逐字节相同 |
