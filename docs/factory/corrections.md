# 人工纠正记录

每次人不得不纠正 agent 或工厂时，记一行：日期、发生了什么、变成了哪条检查（护栏、测试、Qodo 规则、工厂关卡）。还没变成检查的写“待定”，并说明打算怎么做。

| 日期 | 发生了什么 | 变成的检查 |
|---|---|---|
| 2026-11-19 | 搭工厂时发现 master 上 `check_size_ratchet.py`（5 个文件超限）和 `check_cpp_deps.py`（economy→family 新增依赖）已经失败 | 工厂在 base 上先跑检查，只把新增失败算作改动的问题；master 上有失败时结论为 NEEDS_HUMAN |
| 2026-11-19 | 第一次对工厂分支跑 Qodo 本地评审：先因为 `origin` 指向未连接的上游失败，改用 `--repo` 后又因评审服务检出 base 超时（120 秒，两次）失败 | 本地评审改为显式 `--repo`；新增 `localReviewRequired: false`，失败写进运行记录和 PR 正文；READY 仍要求 PR 上对头部提交的 Qodo 评审完成（`verdict.py`） |
| 2026-11-19 | 工厂处理 PR #3 时，agent 工作树继承了轮询工作树的稀疏设置，Codex 只能看到少量代码，修复前的检查也因脚本缺失全部失败，导致新增失败的判断失去作用。 | `work.prepare()` 检查稀疏状态和跟踪文件是否齐全，`checks.Runner` 遇到缺失的检查脚本或测试目录直接报错，新增真实 Git 工作树、缺失检查入口和停机记录测试。 |
| 2026-11-19 | 仓库所有者决定，当前头部提交通过 Qodo 评审且 CI 全部成功时，由工厂合并符合条件的 PR。 | `watch_prs.py` 的 `decide()` 检查评审、CI、标签和可合并状态，`tools/factory/tests/test_watch.py` 覆盖合并和停止条件。 |
| 2026-11-19 | 仓库所有者决定，由工厂把有冲突的 PR 分支更新到 master。 | `watch_prs.py` 的 `decide()` 选择更新，`test_watch.py` 和 `test_workflow.py` 覆盖判断和工作流程。 |
| 2026-11-20 | Issue #11 第一次运行：master 默认回归有 4 项失败，工厂按"只看新增失败"放行，但回归整体算一项检查，master 已失败就看不出改动又弄坏了哪个测试；而 AGENTS.md 要求推送前修复已发现的失败。同时计划里的验收命令 `python3 tools/ci/run_regression_checks.py tests/...gd` 被白名单拒绝，issue 模式开的 PR 也没有标签，PR 轮询可能同时修它或提前合并。 | `run.py` 的 `run_checks()` 把所有失败（含 master 已有的）都算作推送阻塞，反馈里标出哪些是 master 已有的；`verdict.py` 不再因 base 失败单独要人；白名单接受 `python3` 前缀和 `tests/<路径>.gd`；PR 轮询默认跳过 `agent/issue-` 分支，READY 后加 `factory-handoff` 才接手（Qodo 在 PR #17 上指出先建 PR 再加标签会留下无标签的窗口，`gh pr create --label` 也是先建后加，所以改成"无标签即安全"）。`test_workflow.py`、`test_factory.py`、`test_watch.py` 覆盖。上一行 11-19 的"master 有失败时 NEEDS_HUMAN"由此取代。 |
| 2026-11-19 | PR #2 上 Codex 修完 19 项评审问题，只因一处 C++ 编译错误和一处脚本原生访问计数超 1 就整轮放弃，修复没有推送。 | `watch_prs.py` 的 `_fix()` 把新增失败的检查报错交回同一个 Codex 会话（`agent.codex(session=...)`），最多 `checkFixRounds` 轮；`checks.feedback()` 先列出报错行；`test_workflow.py` 和 `test_native.py` 覆盖重试成功、达到上限停下和 Codex 失败。 |
| 2026-11-21 | Issue #23–#26 四次运行都停在计划检查：`tools/ci/run_regression_checks.py --jobs 4` 被白名单拒绝（11-20 放宽的正则不接受数字参数值），#24 还列了带占位符的 `check_macos_runtime_extension.py --library <debug library path>`。两条都是工厂本来就会跑的检查。 | `checks.already_run()` 把默认回归和原生运行时检查识别为已覆盖，记进运行记录的 `extraChecks.alreadyRun`，不再算作拒绝；白名单接受数字参数值；计划提示写明这两项自动运行、不写占位符。`test_factory.py` 用这四次运行里的原命令覆盖；用新代码重放四份运行记录，被拒项都为 0。 |
