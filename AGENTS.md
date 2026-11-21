# Project.Keynes

A procedural hex-world economy and civilization simulation. Godot 4.6 runs the UI and orchestration in GDScript; the simulation runs in a C++ GDExtension (`gdext/`). Current work: moving each simulated day's computation from the main thread to one background executor. Target and status: `docs/architecture/design.md`, `docs/architecture/migration.md`.

## Setup

- Clone with submodules: `git clone --recurse-submodules` (godot-cpp is required).
- Build the native extension: `gdext/rebuild.sh` (macOS), `gdext\rebuild.bat` (Windows). Toolchains and exports: `docs/build-from-source.md`.
- Open `Project/project-keynes/` in Godot 4.6; main scene `scenes/main.tscn`.

## Verify

- Static architecture guards, the list CI runs: `.github/workflows/runtime-checks.yml`, step "Static architecture guards" (run each `python tools/ci/<guard>.py`).
- Factory tests: `python -m unittest discover -s tools/factory/tests`.
- Runtime and save regressions (needs Godot and the built extension): `python tools/ci/run_regression_checks.py --import --roundtrip`.
- Same-input, same-result checks: `python tools/ci/check_golden_determinism.py`, `python tools/ci/check_replay_matrix.py`.

## Project rules

Each rule says where it applies, why, and what enforces it. The full list of 32 rules and their enforcement is in `docs/factory/rule-coverage.md`; the 13 that only review can judge are Qodo rules in `docs/factory/qodo-rules.json`.

1. **Load must not decide results.** Where: everything that computes a simulated day (C++ runtime, GDScript adapters). Why: the same seed, content and sealed commands must give the same day, byte for byte; when machine load once changed the economy's cadence, the same world diverged. Enforced by: `check_golden_determinism.py`, `check_replay_matrix.py`, Qodo rule "simulation results must not depend on timing or load".
2. **The front end only reads published frames.** Where: `scripts/ui/`, `scripts/rendering/`. Why: the simulation is one timeline owned by the executor; a UI that reads live state shows a mix of days. Enforced by: `check_script_native_access.py` (native access only), Qodo rule "the front end only reads published frames".
3. **Modules meet only through their API header and committed views.** Where: C++ runtime modules. Why: a module should be changeable by reading only it and the headers it depends on. Enforced by: `check_module_api.py`, `check_cpp_deps.py`, `check_committed_views.py`, Qodo rule "cross-module hand-offs go through committed views or intents".
4. **Fix the root cause.** Where: every failing test and every fix handed to an agent. Why: loosened asserts, longer timeouts and retries hide the bug that broke determinism. Enforced by: Qodo rule "fix the root cause instead of relaxing the check", factory prompts.
5. **New continuation state is versioned and installed whole.** Where: save sections and state that later days read. Why: a missing field only shows up as a cold-load divergence days later. Enforced by: `check_save_contracts.py`, `check_replay_matrix.py`, Qodo rule "new continuation state is versioned, validated and installed atomically".

## Harness

- 找模块的文件、接口、存档段、测试和 skill，先查 `docs/architecture/module-map.md`；功能专项约束写入 `docs/architecture/feature-guides.md`，带日期的现状与验证记录写入 `docs/architecture/feature-status.md`，不写进通用开发指南。
- 新增系统或功能前，阅读 `docs/architecture/design.md` 和 `docs/architecture/development-guide.md`，确定数据归属、模块依赖及接入位置。为后续扩展保留明确接口，并同步维护开发指南和实际迁移状态。
- 架构迁移应先明确目标与模块契约，再接入既有功能并验证；区分目标设计、已实现部分与验证证据，不以拆文件或文档完成代替功能迁移完成。
- 开始修改及推送 PR 前，先拉取上游并核对分支差异；有新改动时先同步，再完成本地验证。
- 上游改动也容易出错，不能默认正确；合入前独立审查，合入后用实际测试验证。
- 排查高负载、并发或结果不一致的问题时，先写目标行为测试并保留复现证据，再通读相关完整计算与状态交接逻辑定位根因，不以针对失败用例的局部补丁替代根因修复。
- 模拟结果一致性优先于推进速度；同样输入必须得到相同的逐日结果，机器负载只影响计算安排与完成时间，不得改变生产、消费、价格更新或命令生效日期。
- 模拟的判断和计算全部在后台完成；前台只读后台发布的内容、把玩家请求转发给后台，不读模拟状态做判断，也不直接写模拟状态。需要玩家操作的点由后台判定，后台算到那里自己停下等玩家。画面渲染和把已发布内容排成文案、界面属于前台。
- 推送或更新 PR 前，本地修复审查和测试中已发现的问题并完成回归，不能仅因属于既有失败就留待提交后处理。
- 交给外部 AI 的修复任务，提示词要求它先写清根因证据（复现条件、日志或代码路径）再改代码；靠放宽断言、加长超时、加重试绕过问题的补丁不采用。
- 评估 Shader 优化时，按 GPU 实际执行的工作量判断。同一批像素走不同的 `if` 分支时，许多 GPU 会执行两条路径，驱动也可能把分支展开。优先省掉整批工作或在编译期裁掉不用的路径，收益用相同画质和分辨率的实际帧时间验证。
- 工厂（`tools/factory/`）定时查看 fork 上打开的 PR，Qodo 评审出阻塞项后让 Codex 在 PR 分支上修复；它不自动认领 issue，issue 模式只能手动运行（`run.py --issue N`）。流程、关卡和规则覆盖见 `docs/factory/README.md`。工厂的结论由 `tools/factory/verdict.py` 从事实算出，agent 的自述不算数；Qodo 对头部提交的评审没有未关闭的阻塞项、CI 全部成功时，工厂自动合并（`config.json` 的 `autoMerge` 可关闭）。`tools/factory/sync_rules.py` 只创建缺失的规则。修改已有规则先用 `qodo rules update`，再同步 `docs/factory/qodo-rules.json`。
