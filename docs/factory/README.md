# 工厂

工厂主要做**审查后的修复**：fork（`hrhgit/Project.Keynes`）上每个打开的 PR，Qodo 评审完头部提交后，如果有阻塞项（action_required / remediation_recommended），工厂就让 Codex 在这个 PR 的分支上修，跑检查，没有新增失败才推送；推送后 Qodo 会评审新提交，下一轮再看。工厂**不会自动认领 issue**，issue 模式只能手动运行。**工厂从不合并**，合并由人决定，合到 fork 后再由人向上游提 PR。

代码在 `tools/factory/`，配置在 `tools/factory/config.json`，Qodo 评审规则在 [qodo-rules.json](qodo-rules.json)，每条规则由什么强制见 [rule-coverage.md](rule-coverage.md)，人工纠正记录在 [corrections.md](corrections.md)。

## PR 模式（定时运行）

`tools/factory/watch_prs.py`，每 600 秒由 launchd 运行一次。每个 PR 的处理由 `decide()` 决定（纯函数，测试在 `tests/test_watch.py`）：

| 情况 | 动作 |
|---|---|
| 草稿、分支在别的仓库、带 `blocked` / `needs-investigation` | 跳过 |
| Qodo 还没评审头部提交，或评审进行中 | 跳过，下一轮再看 |
| 评审以 failed 等非 completed 状态结束，或评审项的状态或未关闭项的处理级别无法识别 | 停下，打 `agent-needs-help` |
| 头部提交上没有未关闭的阻塞项 | 跳过 |
| 有阻塞项 | 修复：检出头部提交，先跑一遍检查记下已有失败，Codex 成功退出后再跑检查，没有新增失败才推送（`--force-with-lease` 指定原头部提交），在 PR 上评论 |
| 工作树不完整，或检查脚本、测试目录缺失 | 停下，打 `agent-needs-help`，把错误写入运行记录 |
| Codex 退出失败或超时 | 停下，打 `agent-needs-help`，保存本地补丁并列出路径 |
| 工厂修过之后又出现同一批问题，或连续修了 3 轮还不干净 | 停下，打 `agent-needs-help` |
| Codex 有异议且改了文件 | 按修复流程跑检查，异议写进评论由人决定 |
| Codex 没改文件 | 停下，打 `agent-needs-help`。有异议的条目交给人判断，其余阻塞项列出 ID |
| 异议格式有误，或 ID 不在本次交给 Codex 的评审项中 | 停下，打 `agent-needs-help`，列出有问题的行，保存本地补丁并列出路径 |
| 检出时发现头部提交已变 | 停掉本次修复，记入运行记录，下一轮查看新提交 |
| 修复改到 C++、子模块、基线或契约文件、`.github/`、`tools/factory/`、`tools/ci/` 或 `.qodo/` | 停下交给人，保存本地补丁并列出路径。跑检查前和提交前各查一次范围 |

人往分支上推了新提交，轮数重新计算。同一个由人推送的头部提交最多交给 Codex 一次。每次修复结束都移除 `agent-working`。每个 PR 的状态存在 `~/.keynes-factory/prs/<编号>.json`，每次修复的记录存在 `~/.keynes-factory/runs/pr-<编号>-<时间>.json`。工厂的提交带 `Fixed-By: keynes-factory` 和 `Implemented-By: Codex`。注意：工厂会往你的 PR 分支推提交，本地继续改之前先 `git pull`。

两种模式都从仓库根目录的 `.factory-disagree.md` 读取异议，每行严格按 `- <评审项 ID>: <证据>` 写一项。ID 必须和交给 Codex 时给出的一致，可以直接写，也可以用一对反引号包住。证据写明相关文件和行号。空行可跳过。格式有误或 ID 不认识时保存补丁，列出问题行交给人处理。

补丁都保存在本次日志目录。主仓库的补丁是 `fix.patch`，有改动的子模块各有一份以子模块路径命名的补丁，例如 `fix.gdext__godot-cpp.patch`。停下时会列出所有保存的路径。

## Issue 模式（只能手动）

由人对一张打了 `ready-for-agent` 的 issue 运行 `run.py --issue N` 才会开始，定时任务不会运行它。Codex 在实现或修复期间退出失败或超时，当场停下，保存本地补丁并列出路径。

```mermaid
flowchart TD
  T[人运行 run.py --issue N<br/>issue 带 ready-for-agent] --> G0{G0 工单检查<br/>有标题、有验收标准条目、<br/>没有 blocked / needs-investigation}
  G0 -- 不通过 --> H[agent-needs-help<br/>移除 ready-for-agent，评论写明原因]
  G0 -- 通过 --> W[认领：agent-working<br/>工作树重置到 fork/master]
  W --> B[在 base 上跑检查<br/>按提交缓存通过项]
  B --> P[计划：Codex 只读<br/>读 AGENTS.md 和模块地图<br/>写 Fit / Reuse / Affected / Plan / Checks / Questions]
  P -- 有问题或检查命令被拒绝 --> H
  P --> I[实现：Codex 可写<br/>最多 3 次]
  I -- Codex 退出失败或超时 --> H
  I --> S{范围检查<br/>不许改 .github/ tools/factory/ tools/ci/ .qodo/}
  S -- 越界 --> I
  S --> C{检查<br/>静态护栏（取自 runtime-checks.yml）<br/>地图单测、C++ 改了就构建<br/>默认回归、计划里要求的检查}
  C -- 比 master 多出失败 --> I
  C -- 3 次仍失败 --> H
  C -- 通过 --> L{Qodo 本地评审<br/>未提交的改动，最多 2 轮}
  L -- 有阻塞项 --> F1[Codex 修复或写出反驳证据] --> C
  F1 -- Codex 退出失败或异议格式有误 --> H
  L -- 结束 --> S2{提交前重查范围}
  S2 -- 触及受保护文件或 C++ --> H
  S2 -- 通过 --> PR[提交、推送、在 fork 开 PR]
  PR --> R{Qodo PR 评审完成于头部提交<br/>+ CI 结束}
  R -- 有阻塞项且未到 3 轮 --> F2[Codex 修复 → 检查 → 推送] --> R
  F2 -- Codex 退出失败或异议格式有误 --> H
  R -- 同一批问题重复 / 没有改动 --> H
  R --> V[结论由 verdict.py 从事实算出]
  V -- READY --> D[agent-done<br/>人决定是否合并]
  V -- NEEDS_FIX / NOT_DONE / NEEDS_HUMAN --> H
```

## 质量关卡

| 关卡 | 必须满足 | 证据 | 不满足时 |
|---|---|---|---|
| G0 工单 | 标题；`## Acceptance criteria` 或 `## 验收标准` 下有勾选框或编号条目；没有跳过标签 | issue 正文和标签 | `agent-needs-help`，移除 `ready-for-agent`，评论列出原因 |
| 计划 | 六个小节齐全，Questions 为 `none`，额外检查命令符合允许格式 | Codex 只读输出，贴在 issue 上 | 有问题或命令被拒绝时交给人 |
| 范围 | 禁止修改 `.github/`、`tools/factory/`、`tools/ci/` 和 `.qodo/`。基线、契约文件和 C++（含子模块）由人处理 | 每次提交前重查 `git diff`、未跟踪文件和子模块状态 | 提交前发现越界就停下 |
| 检查 | 工作树完整，检查脚本和测试目录齐全；在 base 上通过的检查，在改动后也要通过。每次执行回归都先导入候选项目 | 每项检查的日志，存在 `~/.keynes-factory/logs/` | 工作树不完整或检查入口缺失时立即停下，记录错误并打 `agent-needs-help`。普通检查失败时把日志尾部发给 Codex，最多 3 次 |
| 本地评审（默认尽力而为） | Qodo 对未提交改动没有阻塞项（action_required / remediation_recommended） | `qodo review --repo hrhgit/Project.Keynes --json` | 评审失败或覆盖不完整时记入运行记录和 PR 正文，继续走 PR 评审。若配置要求本地评审，则停下交给人 |
| PR 评审 | Qodo 对**当前头部提交**的评审已完成，没有未关闭的阻塞项 | `qodo read pr-review-session findings` | 最多 3 轮修复；同一批问题重复就停 |
| CI | 头部提交至少有一次 GitHub Actions 工作流运行，所有工作流和检查都已结束，检查全部成功 | GitHub Actions 和 check runs | 等待中为 NOT_DONE，检查失败为 NEEDS_FIX，查询失败时立即停下并给出 NEEDS_HUMAN |

结论的先后顺序：NEEDS_HUMAN → NOT_DONE（证据不全）→ NEEDS_FIX → READY。以下情况一律交给人：master 本身就有检查失败（AGENTS.md 要求推送前修掉已发现的问题）；改了 C++（两种 macOS 库都要重编并提交，再跑 `check_macos_runtime_extension.py`，工厂不提交二进制）；Codex 对某条评审有不同意见；状态无法识别的评审结果。仅供参考的评审结果会列出来，由人决定。

## 运行

```bash
python3 tools/factory/watch_prs.py --dry        # 只打印每个 PR 的决定，不写任何东西
python3 tools/factory/watch_prs.py --pr 5       # 只看一个 PR
python3 tools/factory/run.py --issue 12 --dry   # issue 模式：只跑 G0
python3 tools/factory/run.py --issue 12         # issue 模式：处理一张指定工单
tools/factory/install_poller.sh                 # 每 600 秒运行一次 watch_prs.py（launchd）
tools/factory/install_poller.sh --remove
python3 tools/factory/sync_rules.py [--apply]   # 把 qodo-rules.json 里缺的规则建到 Qodo
python3 -m unittest discover -s tools/factory/tests
```

本机目录 `~/.keynes-factory/`：`runner/` 是轮询用的稀疏工作树，只检出 `tools/factory/` 和 `.github/`，固定在 fork/master。即使从 `runner/` 创建，agent 使用的 `work/` 也是完整工作树。每次准备会关闭主工作树和 `gdext/godot-cpp` 子模块已有的稀疏检出，重置主工作树并更新、清理子模块，保留忽略的 `.godot` 和 SCons 缓存，最后检查主工作树和子模块是否还有稀疏设置或缺失的跟踪文件。`runs/` 存每次运行的 JSON 记录；`logs/` 存检查和 Codex 的日志；`base-checks/` 按提交缓存通过项，下次重跑失败项和缺失项。

安装轮询任务时，脚本把配置里的 `tools.python` 写进 launchd。更改路径后再运行一次安装脚本。手动运行 `poll.sh` 时，未设置 `KEYNES_FACTORY_PYTHON` 就使用 PATH 上的 `python3`。fork/master 尚无工厂目录时轮询正常退出，目录已存在但启动脚本缺失时则报错。

`sync_rules.py --apply` 创建缺失规则，有任何创建失败就返回非零。修改已有规则先用 `qodo rules update`，再更新 JSON。

工作树基于 `fork/master`。上游有新提交时，先同步 fork：`gh repo sync hrhgit/Project.Keynes --source HkingAuditore/Project.Keynes`。

## 已知限制

- Codex 在沙箱里运行，不能联网，所以计划步骤没有调用 Qodo Codebase Wisdom，只读本地代码和文档。
- C++ 改动交给人重建两种 macOS 库并提交。
- 本地没有跑 CI 里的 C++ sanitizer 用例；这部分以 PR 上的 CI 结果为准。
- Qodo 本地评审目前跑不起来：评审服务在 120 秒内检出不了这个仓库的 base（2026-11-19 两次都超时）。所以 `localReviewRequired` 设为 `false`，本地评审失败时只记录，不拦；把关的是 PR 上对头部提交的 Qodo 评审，`verdict.py` 没有它就不会给 READY。
- 工作树的 `origin` 是上游，Qodo 里没有连上游，所以本地评审显式传 `--repo hrhgit/Project.Keynes`。
- 计划里要求的额外检查只接受 `tools/ci/<脚本>.py [--参数]` 这种格式。被拒绝的命令会写进运行记录和结论。
