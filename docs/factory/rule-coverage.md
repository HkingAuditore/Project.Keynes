# 规则由什么强制

确定性检查优先：类型 → 静态护栏 → 测试 → 运行时校验 → Qodo 评审规则 → 文字说明。能用前面的就不用后面的。下表把 `AGENTS.md` 和架构文档里的规则逐条对应到实际执行它的东西。“Qodo”指 [qodo-rules.json](qodo-rules.json) 里的同名规则。

| 规则 | 出处 | 由什么强制 |
|---|---|---|
| 同样输入得到相同逐日结果，负载只影响完成时间 | AGENTS.md、design.md | 测试：`check_golden_determinism.py`、`check_replay_matrix.py`；Qodo：timing or load |
| 前台只读已发布内容，不读写模拟状态 | AGENTS.md、module-map.md | 护栏：`check_script_native_access.py`（只管原生绑定访问）；Qodo：front end |
| 模块之间只经接口头 | module-boundaries.md | 护栏：`check_module_api.py`、`check_cpp_deps.py` |
| 跨域读取只经已提交视图，不持有 snapshot/plan 引用 | module-boundaries.md | 护栏：`check_committed_views.py`；Qodo：committed views or intents（补指针和别名绕行） |
| 新请求入口要登记 | module-boundaries.md | 护栏：`check_resolve_apply.py` |
| 域对要登记并标明状态 | module-boundaries.md | 护栏：`check_cross_domain_inventory.py` |
| 每日模块的 reads/writes 与描述符一致 | development-guide.md | 护栏：`check_module_contracts.py` |
| 环境开关经 registry 读取，不直接 `getenv` | development-guide.md | 护栏：`check_runtime_switches.py` |
| 存档段有契约（版本、依赖、旧版拒绝） | development-guide.md | 护栏：`check_save_contracts.py`；Qodo：continuation state |
| 新继续态冻结、校验、完整解码后才安装 | development-guide.md | 测试：`check_replay_matrix.py`；Qodo：continuation state |
| 只在已提交边界保存，超容量明确失败 | development-guide.md | 测试：`runtime_inline_save_restore_test.gd` 等；Qodo：committed boundary |
| 不靠放宽断言、加长超时、加重试修测试 | AGENTS.md | Qodo：root cause；工厂提示词 |
| 出错时直接报错，不悄悄回退（气候 native 入口完全不许回退） | development-guide.md、用户 2026-11-19 | Qodo：errors fail loudly |
| 阶段函数不碰 Godot 对象，返回值不表示业务成功 | development-guide.md | Qodo：daily stage functions |
| 手动推进后台日的测试要等已提交日期并接收结果 | development-guide.md | Qodo：background-day tests |
| 会话组件只拿窄依赖，不建第二个日推进入口 | development-guide.md | Qodo：session components |
| GDScript 拆分保留公开接口和字面量 | development-guide.md | Qodo：GDScript splits |
| 新文件行数不超限，基线内文件最多比记录多 50 行且增长告警，基线只收紧 | module-boundaries.md | 护栏：`check_size_ratchet.py` |
| 模块地图里的路径存在 | module-map.md | 护栏：`check_module_map.py` |
| skill 源文件统一放在 `skills/`，各工具目录的副本不进版本库 | development-guide.md | 护栏：`check_skill_mirrors.py` |
| 脚本接口绑定归属正确 | development-guide.md | 护栏：`world_ext_bindings.py`、`check_world_ext_bindings.py` |
| 国库建造检查体制能力位 | development-guide.md | Qodo：treasury construction |
| Shader 少用 if，优化按 GPU 实际工作量判断 | AGENTS.md、用户 2026-11-19 | Qodo：shaders keep if-branches few（warning） |
| 推送前先修掉已发现的问题，包括既有失败 | AGENTS.md | 工厂：master 上有失败时结论为 NEEDS_HUMAN |
| 基线只能用脚本收紧，不能手改 | development-guide.md | 工厂：基线和契约文件改动交给人 |
| 改 C++ 后两种 macOS 库都要重编并验证 | development-guide.md | 工厂：重编、导入项目、逐库跑运行验证，构建产物留在本地，库目录变更交给人处理 |
| 开始改动前先同步上游 | AGENTS.md | 文字说明（工厂基于 fork/master，同步由人做） |
| 上游改动合入前独立审查 | AGENTS.md | 文字说明 |
| 交给外部 AI 的修复先写根因证据 | AGENTS.md | 工厂提示词（implement.md、fix-review.md） |
| 工厂结论只来自事实 | 本目录 | 测试：`tools/factory/tests/test_factory.py`；变异检查见 [verdict-mutations.txt](verdict-mutations.txt) |
| PR 在当前头部提交评审通过、CI 全部成功且 GitHub 确认可合并时才自动合并 | 仓库所有者 2026-11-19 | 工厂：`watch_prs.py` 的 `decide()` 和 `--match-head-commit`；测试：`tools/factory/tests/test_watch.py` |
| 工厂把有冲突的 PR 分支更新到 master，遇到受保护路径、子模块或二进制冲突时交给人 | 仓库所有者 2026-11-19 | 工厂：`watch_prs.py` 的 `decide()` 和更新流程；测试：`test_watch.py`、`test_workflow.py` |
| 关口、解析器、白名单和校验器要用它们必须拒绝的输入来测 | AGENTS.md 规则 6 | 测试：`tools/factory/tests/test_gates_refuse.py`（名字像关口的函数没登记拒绝用例就失败）；Qodo 规则“gates are tested with inputs they must refuse” |

合计 33 条规则：至少有一项护栏或测试的 19 条（其中“前台只读”一条，护栏只管到原生绑定访问）；只靠 Qodo 规则的 7 条；靠工厂关卡或提示词的 5 条（“找根因”一条另有 Qodo 规则）；只有文字说明的 2 条。
