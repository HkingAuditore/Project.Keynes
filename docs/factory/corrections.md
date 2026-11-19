# 人工纠正记录

每次人不得不纠正 agent 或工厂时，记一行：日期、发生了什么、变成了哪条检查（护栏、测试、Qodo 规则、工厂关卡）。还没变成检查的写“待定”，并说明打算怎么做。

| 日期 | 发生了什么 | 变成的检查 |
|---|---|---|
| 2026-11-19 | 搭工厂时发现 master 上 `check_size_ratchet.py`（5 个文件超限）和 `check_cpp_deps.py`（economy→family 新增依赖）已经失败 | 工厂在 base 上先跑检查，只把新增失败算作改动的问题；master 上有失败时结论为 NEEDS_HUMAN |
| 2026-11-19 | 第一次对工厂分支跑 Qodo 本地评审：先因为 `origin` 指向未连接的上游失败，改用 `--repo` 后又因评审服务检出 base 超时（120 秒，两次）失败 | 本地评审改为显式 `--repo`；新增 `localReviewRequired: false`，失败写进运行记录和 PR 正文；READY 仍要求 PR 上对头部提交的 Qodo 评审完成（`verdict.py`） |
| 2026-11-19 | 工厂处理 PR #3 时，agent 工作树继承了轮询工作树的稀疏设置，Codex 只能看到少量代码，修复前的检查也因脚本缺失全部失败，导致新增失败的判断失去作用。 | `work.prepare()` 检查稀疏状态和跟踪文件是否齐全，`checks.Runner` 遇到缺失的检查脚本或测试目录直接报错，新增真实 Git 工作树、缺失检查入口和停机记录测试。 |
| 2026-11-19 | 仓库所有者决定，当前头部提交通过 Qodo 评审且 CI 全部成功时，由工厂合并符合条件的 PR。 | `watch_prs.py` 的 `decide()` 检查评审、CI、标签和可合并状态，`tools/factory/tests/test_watch.py` 覆盖合并和停止条件。 |
| 2026-11-19 | 仓库所有者决定，由工厂把有冲突的 PR 分支更新到 master。 | `watch_prs.py` 的 `decide()` 选择更新，`test_watch.py` 和 `test_workflow.py` 覆盖判断和工作流程。 |
| 2026-11-19 | PR #2 上 Codex 修完 19 项评审问题，只因一处 C++ 编译错误和一处脚本原生访问计数超 1 就整轮放弃，修复没有推送。 | `watch_prs.py` 的 `_fix()` 把新增失败的检查报错交回同一个 Codex 会话（`agent.codex(session=...)`），最多 `checkFixRounds` 轮；`checks.feedback()` 先列出报错行；`test_workflow.py` 和 `test_native.py` 覆盖重试成功、达到上限停下和 Codex 失败。 |
