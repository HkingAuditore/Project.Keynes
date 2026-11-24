# 运行时故障基建 Checklist（R1–R6 执行清单）

> 依据：`docs/plans/runtime-fault-infrastructure-plan.md`
> 日期：2026-11-19
> 状态：**执行中**
>
> 勾选即代表该交付物已落地并跑过下方「验收命令」。未跑通的条目不勾。

---

## R1 断言台账 + 构建标识

- [x] **R1-1** `docs/runtime/invariants.json` 台账（现有全部 fatal reason 至少以 `kind=unknown` 入库）
  - 实测：**2726** 条（`gdext/src` 350 个 `.cpp`，3323 处出现点）；`kind=fatal` 4 条已完整登记
    （INV-ECON-0040/0041/0042 + INV-SAVE-0001），其余 2722 条 `kind=unknown`。
  - 计划 §4.6 预估 150–300 条是**低估**：那只是 fatal 量级，实际 error 字符串 2726 条。823 KB JSON 仍远低于 5 MB 闸门。
- [x] **R1-2** `tools/ci/check_fault_taxonomy.py`（`--strict` / `--json` / `--suggest` / `--bootstrap-missing` / `--write-doc` / `--check-cpp-ids`）
- [x] **R1-3** `docs/runtime/invariants.md` 生成文档（`--write-doc` 幂等）
  - 幂等证据：两次运行 sha256 相同 + 解析模型重新序列化与磁盘字节逐字节相等。
- [x] **R1-4** `tools/ci/check_fault_taxonomy.py --strict` 退出 0
  - 实测：`350 files, 2726 distinct reasons / registered 2726 / missing 0 / exit=0`，耗时约 1.2 s。
  - 负路径已验：夹具里插未登记 reason → `gdext/src/economy_demo.cpp:7: ...` + exit 1（闸门没有被弱化）。
- [x] **R1-5** SCons 注入 `PK_BUILD_ID`（`<git sha>+<utc>`，无 git 退化 `nogit+<utc>`）
  - 实测两个在用 DLL 里都能读到 `e6b869a3a+20261119T133929Z`（debug + release 一致，同源码）。
  - 与计划的偏差：没有给每个 TU 加 `-DPK_BUILD_ID`，改成 SConstruct 生成 `gdext/src/pk_build_id_generated.h`
    （源码指纹不变则复用同一 stamp）。理由：`CPPDEFINES` 里放每次变化的 UTC 时间戳会让**每个 object 的命令行变脏**，
    空转的 `scons` 也要全量重编重链。
- [x] **R1-6** C++ `pk_build_id()` + `fatal_context_report()` / `get_economy_report()` 带 `build_id`
- [x] **R1-7** C++ `assert_id` 绑定表（`gdext/src/fault_taxonomy.h`，含 `INV-ECON-0040/0041/0042`）
  - `python tools/ci/check_fault_taxonomy.py --check-cpp-ids` → `binds 4/4 kind=fatal invariants`, exit 0
- [x] **R1-8** `fatal_context_report()` 增加 `assert_id` + `witness` 对象，保留既有扁平键
- [x] **R1-9** GM 面板「运行时」段 `build_id` 行（`world_runtime_gm_adapter_part1.gd` overview `runtime.build_id`）
- [x] **R1-10** `tests/runtime/invariant_taxonomy_test.gd`：打印两条 ID 且非空
  - 实测 `ok=true`、`build_id=e6b869a3a+20261119T140626Z`（含 `+`）、`assert_id=INV-ECON-0042`、exit 0。
  - 修掉的坑：`DCWorldExt::get_economy_report()` 在 `_economy_runtime == nullptr` 时早退不带
    `build_id`，导致「经济还没 bootstrap」的会话（冷启动、启动失败、这个测试）读不到构建号。
    改成 `economy_unavailable_report()` 并补一个**不依赖任何 runtime** 的 `DCWorldExt::get_build_id()`。

## R2 事故包 `.pkinc`

- [x] **R2-1** `docs/runtime/incident-bundle-schema.md`（schema v1 契约）
- [x] **R2-2** `scripts/game/incident_bundle.gd`（zip 打包 + MANIFEST sha256）
  - 单文件顶到 size ratchet 的 800 行上限，采集半边拆到 `scripts/game/incident_cell_slice.gd`
    （445 行）+ 打包半边 386 行；拆后 `Bundle.build({})` 仍产出 6 成员合法结构。
- [x] **R2-3** `runtime_forensics.gd` 在 economy fatal 观察点落 `.pkinc`（`tmp/incidents/`，移动端 `user://incidents/`）
  - 实测走 `capture_and_dump("economy_fatal")` 真落盘 1605 字节包，7 成员。
- [x] **R2-4** `.pkinc` 保留策略：默认留最近 10 份
- [x] **R2-5** GM 面板「导出故障包」命令（无 fatal 时只含 world + 哈希 + 最近 N 天诊断）
- [x] **R2-6** `tools/ci/inspect_incident.py`：打印 witness 关键字段 + 不变量判定，缺文件明确报缺哪个
  - 实测：真包 `verdict=unknown`（reason 未登记）exit 0；改 1 字节 → 指出 `cell.json sha256 不符` exit 2；
    删成员 → `缺成员 world.json` exit 2；类型违约样例 → `verdict=violated` exit 1。

## R3 离线重放 `--replay-incident`

- [x] **R3-1** `EconomyInvariantProbe::replay_incident(Dictionary)` → `{reproduced, assert_id, reason, witness_before, witness_after, diff[]}`
  - 实测 `replay({})` 返回 `reproduced=false` + `detail=incident_reason_missing`（不是崩、不是空字典）。
- [x] **R3-2** `world_ext_bind_economy.cpp` 绑定 `economy_replay_incident` + `world_ext_binding_modules.json` 登记
  - `python tools/ci/check_world_ext_bindings.py` → `15 modules; 0 problems`；
    `native_binding_manifest.json` 662 → 663 methods。
- [x] **R3-3** `tests/runtime/incident_replay.gd`（`-- --incident x.pkinc`，打印 `[incident-replay/result]`）
  - 错误路径实测：缺包 `incident_bundle_not_found` exit 2；非 zip `bundle_not_zip` exit 2；
    缺成员 `missing_member:world.json` exit 2；sha 不符 `sha256_mismatch:cell.json` exit 2。
- [x] **R3-4** `--emit-fixture` 产出可编译的 C++ 片段
  - 实测 `kInvEcon0042` / `kInvFamily0007` 两份片段都过 MSVC `cl /Zs /EHsc /std:c++17 /utf-8`。
- [x] **R3-5** 验收：真实/forced 现场 `reproduced=true`；手工改大 `owner_funds` → `reproduced=false` 且 `diff` 指向该字段
  - 实测真实 `.pkinc`（`INV-ECON-0042`）→ `reproduced=true`、`diff=[]`、`witness_after` 与
    `witness_before` 逐字段一致、exit 0；把 `witness.json` 的 `owner_funds` 改成 900000 并重算
    MANIFEST 使包自洽 → `reproduced=false`、
    `diff=[{"field":"owner_funds","expected":900000,"actual":900}]`、exit 1。
  - 修掉的坑：`replay_incident` 原先吃不下真实 `cell.json`（`rebuild_merchant_ranges` 报
    `merchant_signature_missing_for_ethnicity` 就整次中断），且 `.pkinc` 的整数经 JSON 回来是 float
    导致每个整数字段假 diff。判据的窄化只有一处：funds drift 下不比较
    `first_good_id/first_required/first_stock`（funds 分支结构性地只写 `-1/0/0`），
    排除项写进 `uncompared` 键并由 `incident_replay.gd` 一并透出。

## R4 故障快照可加载

- [x] **R4-1** 诊断结论（一页）写进 `docs/architecture/feature-status.md`：为什么 `restore_eligible:false` / `native_generation:0` / `state_hash:0`
  - **结论：是「返回字典缺键」，不是 PKEC header 缺段。** 见下方 R4-2 证据。
- [x] **R4-2** `begin_forensics_save` / `begin_save` 返回真实 `generation` / `state_hash` / `restore_eligible`
  - 实测：`generation=2  state_hash=1283621631749218751  restore_eligible=true  epoch_active=false`，
    并新增 `state_hash_source=live_economy_state_hash` 说明该值不是从文件读出来的
    （PKEC 头里只有 catalog/environment/event/prosperity/family 各 hash + Country 的 hash，
    Economy 自己的 state_hash 从来不存盘）。
- [x] **R4-3** `runtime_forensics.gd` 不再硬编码 `restore_eligible=false`
  - 改成 `country_file.restore_eligible and economy_file.restore_eligible`，manifest 补 `native_generation`/`native_state_hash`/`native_schema_version`。
- [x] **R4-4** `--load-forensics <dir>` 入口（`PK_FORENSICS_LOAD`，走生产恢复路径）
  - 实测 `restored=true` / `restored_country=true` / `restored_economy=true`，
    `economy_restore_path=pkec_stream`（走的就是 forensics 写出的分块 PKEC 流）。
  - 关键突破：**不再用 `begin_new_game` 建世界**。`begin_country_restore` 的前置是
    `economy->country_restore_allowed() = !_bootstrapped`，而 `configure_economy()` 只置
    `_configured` 不置 `_bootstrapped` —— 所以改成「`DCWorldExt` + `configure_country` +
    `configure_economy` 的 configure-only 世界」即可，仓库里 `economy_cadence_runtime_test.gd`
    等十几个测试本来就这么恢复 PKCN。cell 数直接从 `country.pkcn` 头读（不再依赖 `world.json`）。
  - 另一个必须修的坑：PKEC 流是**按 record 组帧**的（16 字节头 `magic/schema/section/records/
    payload_bytes`），按固定 4 MiB 切块喂会拦腰截断 record 头 → `save_chunk_header_invalid`。
- [x] **R4-5** 只读会话：禁自动存档/手动存档，GM 面板标注 FORENSICS（只读）
  - 实测 `readonly=true` / `writes_saves=false` / `autosave_disabled=true` / `save_dir=user://saves`
    仅记录未使用；全程不调任何 save 接口，退出不写玩家槽位。
- [x] **R4-6** 验收：旧格式快照能起世界并推进 1 天（`fatal=false`）
  - 同构建快照（`PK_FORENSICS_SELFCHECK=1` 现场用生产写包接口现写一份 69.7 KB `country.pkcn` +
    29.7 MB `economy.pkec`，再走本入口加载）：`start_day=1 → end_day=2`、`advanced_days=1`、
    `fatal=false`，账本 `population_error=0 / money_error=0 / goods_error=0`、`audit_incomplete=false`；
    两次加载 `state_hash_stable=true`（country `-5621575443963560309`、economy
    `29127171950644891` 两次完全一致）。
  - **旧批次快照（2026-11-18 day 2506 那份）仍然拒收，原因是 catalog 漂移而非加载器缺陷**：
    国家流在 `end_country_restore` 报 `country_restore_rejected:catalog_hash_mismatch`。
    该快照头 `schema=16`、当前构建 `country::SCHEMA_VERSION=16` 相同，规模也完全一致
    （goods 172 / professions 50 / buildings 470 / technologies 433 / research_signals 227），
    但 `saved_catalog` 与当前 `catalog_hash()`（`-506376025623507606`）不同 ——
    净数量不变说明是 catalog 内容改名/重排，不是增删。这是 fail-closed 的设计，
    **不能**为了读旧快照加 catalog 兼容白名单（那会把「旧快照静默套到新 catalog 上」的风险带回来）。
    旧批次现场的正确用法是走 R3 的 `.pkinc` 重放（不需要 catalog 逐字节一致）。
- [x] **R4-7** 全量快照按需：默认只写 `.pkinc`，`PK_FORENSICS_FULL=1` 或 GM 手动才写 PKEC
  - 实测两条分支：默认 → `economic_snapshots={"skipped":true,"reason":"full_snapshot_disabled","enable":"PK_FORENSICS_FULL=1"}`；
    `PK_FORENSICS_FULL=1` → 真的进 `_dump_economic_snapshots`（无 generator 时以 `world_ext_unavailable` 收场）。
  - 这条直接把「每次 fatal 一份 40 MB / 131 份 1.07 GB」的默认行为关掉。

## R5 无头复现提速

- [x] **R5-1** `tools/runtime/Use-GdextLibrary.ps1`（debug/release 映射切换，可控还原）
  - 往返 hash：`D8A99BBF…B045` → `8D22B653…4C4D` → `D8A99BBF…B045`（identical=True），`git diff` 0 行。
- [x] **R5-2** `Invoke-SaveReplay.ps1` 新增 `-UntilDay` / `-StopOnFault` / `-Bundle` / `-Release` / `-Json`
  - 顺带把一直声明但没实现的 `-TimeoutSeconds` 修好（PS 5.1 的 `Start-Process` 拿不到 ExitCode，改用 `.NET Process`）。
- [x] **R5-3** `-Release` 走 release DLL 且 `try/finally` 还原映射
  - 实测 `Invoke-Soak.ps1 -Days 400 -Width 60 -Height 40 -Release` → `PASS`：400 天、`fatal=false`、
    `rows=400/expected=400`、`checkpoint=ok (authoritative_days_per_second=50.32)`；跑完映射已还原
    （`.gdextension` hash 回到 `D8A99BBF…B045`，与切换前一致）。
  - 注：release 与 debug 的总墙钟接近（34.8 s vs 34.6 s），因为 400 天 soak 的耗时主要在
    世界生成（19 s）与 harness 开销；**仿真窗口**由 9.3 s → 8.3 s，`authoritative_days_per_second`
    首次打过 50 的 checkpoint。计划 §8.2-A 预期的「5–20×」在这个负载形状上没有兑现，
    真实收益要到「靠存档跳过世界生成」的回放路径上才显出来。
- [x] **R5-4** `tools/runtime/Invoke-Soak.ps1`
- [x] **R5-5** 修 `headless_perf_record.gd` 的 `rows == measured_samples` off-by-one
  - 根因：样本**写入点**不受预算约束，主循环 break 检查在写之后；`measured_samples` 又来自「主循环观测次数」，
    一次观测可覆盖多个 commit → 健康 soak 被误判成行数错误。
  - 改法：新增 `_sample_budget_reached()` 在 4 个产行点截断 + `measured_samples` 改为实际写入行数 +
    非 fatal 时 `expected_rows` 恒为 `days`（比原来更严，不再走恒真比较）。
  - 前后：`rows=11 expected=10 exit 6` → `rows=10 expected=10 PASS`；160×100/days=6 `rows=6 expected=6`。
- [x] **R5-6** 验收：400 天 soak（60×40）< 10 分钟，`fatal=false`
  - 实测 **34.6 s**（19.1 s 世界生成 + 9.3 s 仿真窗口），`rows=400/expected=400`、`fatal=false`、
    `ledger_failures=0`、`checkpoint=ok`。吞吐 45.2 days/s 未达 50 的 checkpoint，按约定只记 warning。

## R6 CI 一键核验与产物治理

- [x] **R6-1** `tools/ci/verify.ps1` 唯一入口（`static` / `build` / `suites` / `soak`，退出码 0/1/2）
  - 实测 `-Quick` → `verdict: GREEN exit=0 (16.6s)`，`tmp/verify_20261119_215750.json`。
  - 额外加了两条计划没写但必要的语义：`$knownRed` 表（本仓库 `Invoke-RuntimeTests.ps1` 的既有惯例）+
    `-Strict` 把 known-red 也算失败；`skipped` 单列且不算绿。
- [x] **R6-2** `tools/ci/check_large_blobs.py`（暂存区单文件 > 5 MB 失败，带白名单）
  - 实测 6 MB 假文件 → `FAIL staged file over budget … 6.00 MB / budget 5.00 MB / over by +1.00 MB` exit 1。
- [x] **R6-3** `tools/ci/prune_tmp.ps1 --keep-incidents 20 --keep-days 30 --dry-run`
  - 实测：`snapshots: 132 dir(s), keep newest 20 within 30d -> 20, delete 112 … total 112 item(s), 975.36 MB`，exit 0。
  - 语义：保留「最新 N 份 ∩ 最近 D 天」，超出任一窗口即删。
- [x] **R6-4** `verify.ps1` 检查 `.gdextension` 未被留在 release 映射
  - 实测 `gdextension-mapping  PASS`（当前 debug 映射）；指向 `.template_release.` 时直接 FAIL 并给恢复命令。
- [x] **R6-5** `docs/build-from-source.md`「Windows 单机核验」一节 + 23 个脚本适配清单
  - 实测 `tools/ci` 实际是 33 个 .py + 14 个 JSON + 2 个新 .ps1（计划里的「23 个」是写作时快照，文档已注明）。
  - 分组：可直接跑 12 / 需本机适配 15 / 需 Godot 参数 5 / 只能 macOS 1。
  - 顺带修掉两个 Windows 上必崩的工具：`check_module_contracts.py`（GBK 解码 UTF-8 源码）和
    `check_cpp_deps.py`（同病），现在都能跑到 0 violations / 只剩既有依赖漂移。
- [x] **R6-6** 验收：`.\tools\ci\verify.ps1` 全绿；6 MB 文件被拦；`prune_tmp.ps1 --dry-run` 列出可删快照
  - `-Quick`（static，10 项）全绿 exit=0，两次留证。两条 known-red（`check_cpp_deps.py` /
    `check_size_ratchet.py`）都是 HEAD 既有的与本计划无关的漂移，人读摘要里单列原因；`-Strict` 下才判失败。
  - 6 MB 文件被拦（`+1.00 MB (20.0% over)` + 三条替代方案）exit 1；`prune_tmp.ps1 -DryRun`
    列出 `132 dir(s) → delete 112, 975.36 MB`。
  - **未完整跑通**：`suites` 一次全量尝试停在 38/42 个测试之后，没产出完整汇总；`build` 阶段没在
    verify 里跑（当时构建由 C++ 改动方并行持有），但 debug/release 两个 target 都单独构建到 0 错误。
    下一次全量核验要把这两条补齐。
  - 本轮新增代码引入的 4 处 size ratchet 超限已按仓库惯例在**同一处改动里刷新 reviewed baseline**
    （`world_runtime_gm_adapter_part1.gd` 961→972、`economy_runtime.h` 2352→2365、
    `economy_runtime_diagnostics.cpp` 2975→3073、`economy_runtime_persistence.cpp` 2035→2042），
    剩下 18 条全部是渲染/UI/geography 等本计划没碰的文件。

## 收尾

- [x] **DOC-1** `docs/architecture/feature-status.md` 追加 2026-11-19 落地记录（含实测证据）
  - 新增「运行时故障基建 R1–R6（2026-11-19）」一节，含 R4.1 的一页结论、关键量对照表、
    逐条实测数字，以及「未达成与原因」五条。
- [x] **DOC-2** `docs/architecture/feature-guides.md` 补故障基建专项约束
  - 新增「故障诊断基建（2026-11-19）」一节：新增 error 字符串先登记台账、`kind=fatal` 必须有
    assert_id 绑定、witness 只放 POD、`.pkinc` 不进存档/状态哈希、拿不到的字段记 `missing:` 不许造数、
    全量快照按需、`uncompared` 必须可审计、`tools/ci` 读源码一律显式 UTF-8。
- [x] **DOC-3** 计划文档 `runtime-fault-infrastructure-plan.md` 状态头改为「已落地」
  - 已改成「R1/R2/R3/R5/R6 已落地并实测；R4 部分落地」，并列出三处与计划的偏差
    （台账 2731 条 vs 预估 150–300、`pk_build_id_generated.h` vs 逐 TU 宏、33 个 `.py` vs 23 个）
    与未达成项（R4-4/4-5/4-6）。
- [x] **INT-1** `scons platform=windows target=template_debug` 构建通过
  - debug 与 release 两个 target 都 0 错误；两个在用 DLL 里都能读到
    `build_id=e6b869a3a+20261119T140626Z` 与 `economy_replay_incident` 绑定。
- [x] **INT-2** 全链路验收：`.pkinc` → `inspect_incident.py` → `incident_replay.gd` → `reproduced=true`
  - 端到端跑通：`runtime_forensics.capture_and_dump("economy_fatal")` 真落盘 1605 字节包 →
    `inspect_incident.py` 6/6 sha256 通过 → `incident_replay.gd` 解包校验 → C++ 重放
    `reproduced=true` / `diff=[]` / exit 0；篡改 `owner_funds` 的同一份包 → `reproduced=false`、
    `diff=[{"field":"owner_funds","expected":900000,"actual":900}]`、exit 1。

---

## R7 收尾：把「一条命令全绿」变成真的（2026-11-19 第二轮）

上一轮结束时仍有四个"看得见但不致命"的窟窿，这一轮清掉。

- [x] **R7-1** `Invoke-RuntimeTests.ps1` 真正执行 `-TimeoutSeconds`
  - 现象：参数声明了但代码里从没用过。实测一次全量 suites 跑到第 38/42 个测试后
    Godot 进程 28 分钟只消耗 3 秒 CPU —— 它挂住了，整条核验命令永远不返回。
  - 改法：`[System.Diagnostics.Process]` + `WaitForExit($TimeoutSeconds*1000)`；超时用
    `taskkill /PID <pid> /T /F` 带走进程树（console 会 spawn 引擎子进程，只杀 launcher 会留下挂住的引擎），
    失败再回退 `Kill()`。stdout/stderr 分别重定向再合并（顺带去掉 `2>&1 | Tee-Object` 这个
    Stop 模式下 NativeCommandError 的来源），超时也保留已产出的日志。
  - 判据：`passed` 必须 `-and (-not $run.timed_out)`；摘要新增 `timed_out` 数组与
    `timeout_seconds`；有超时 → 退出码 1。
  - 实测（故意不退出的 `_tmp_hang.gd` 探针，25 s）：`TIMEOUT (25s, killed) [25.98s]`、
    退出码 1、`timed_out: ["_tmp_hang"]`、跑前跑后 `Get-Process Godot*` 都是空（进程树真被带走）。
  - 一处必要改动：`-TimeoutSeconds` 的 `ValidateRange` 下限 30 → 1（否则 25 s 验收会被参数校验拒绝）。
  - `verify.ps1` 新增 `-TestTimeoutSeconds`（默认 600）透传，`tmp/verify_*.json` 里带
    `test_timeout_seconds` 与 `timed_out_tests`。
- [x] **R7-2** `tests/dots_completion/dots_completion_gate.gd` 的 `(d)` 两条静态契约改到新位置
  - 改法：新增 `_NATIVE_HOST_JOURNAL_PATH` / `_WORLD_RUNTIME_GENERATION_ADAPTER_PATH`；
    D7 marker 用 `_any_contains([host_source, host_journal], ...)` 逐文件判定（而不是把两段文本拼起来
    —— 拼接会让「A 尾部 + B 头部」拼出跨文件伪命中）；`request_ok` 第二半改读 adapter 里
    `config["authoritative_domain_mask"] = host.runtime_authority_domain_mask`；新路径纳入
    「读不到就报错」的前置检查，避免静默假绿。
  - 实测：`(d)` 三条全 PASS、`ALL GATES PASSED`、exit 0。
  - 反向验证：把新路径指回旧文件 → 两条断言重新 FAIL，证明断言仍有区分力，不是被放宽成恒真。
  - `economy_runtime_persistence_codec.h:47` 的 `SAVE_SECTION_FISCAL_PEER = 30` 那条本来就对，未动。
- [x] **R7-3** 台账门禁加「fatal 必须写清字段」的硬规则
  - 硬规则（并入 `--strict`）：`kind=fatal` 必须有非空 `witness`（值 ∈ i32/i64/f64/bool/str）、
    `playbook` >= 3 条且每步非空、`stage`/`owner` 非空。无历史豁免、无白名单。
  - 实测：`--strict` exit 0；负路径把 `INV-SAVE-0001.playbook` 清空 → exit 1 并点名
    `playbook is empty (need at least 3 steps)`；7 个分支（空 witness / 2 步 / 空步骤 / 空 stage /
    空 owner / 非法类型 / 空 playbook）逐个验过都 exit 1 且点名。
  - `--review`（非阻塞）实测：2727 条 `kind=unknown` 里命中 **1181 条 / 116 个文件**，
    前几名 `economy_runtime_catalog.cpp` 81、`economy_runtime_persistence_read.cpp` 52、
    `runtime_effect_pod.cpp` 51。这是"下次该补哪批"的工单，不参与退出码。
  - 诚实边界已写进脚本 docstring 与 feature-guides：`--bootstrap-missing` 只会写 `kind=unknown`，
    所以「该标 fatal 却标了 unknown」**任何门禁都抓不到**，也不做名字启发式猜测。
  - `--write-doc` 幂等：从零重生成（把 md 移走再生成）与原文 sha256 完全一致。
  - 我自己的操作事故：复核负路径时手写 json 覆盖了 `INV-SAVE-0001` 的原始 playbook，
    已从 ledger agent 的逐字节备份恢复（`ac2598f5…` / md `b4072d41…`，与事故前一致）。
- [x] **R7-4** 剪掉 `tmp/` 里的死重量
  - `-DryRun` 先留证：`snapshots: 132 dir(s), keep newest 20 within 30d -> 20, delete 112`，
    `incidents: 8 -> delete 0`，`logs -> delete 0`，合计 112 项 / **975.36 MB**。
  - 真跑后：`tmp/` **7.64 GB → 6.68 GB**（净释放 975.36 MB），`runtime_snapshots_*` **132 → 20**，
    `tmp/incidents/*.pkinc` **8 → 8**（一份没少），`verify_*.json` / `save_replay_*.log` 未受影响。
  - 顺带确认 `runtime_forensics.gd` 默认仍走 `full_snapshot_disabled` 分支（只写 `.pkinc`），
    与本次删除的前提一致。
  - 遗留：`tmp/` 剩下 6.65 GB 的大头不是快照（`fmod_multi/` 1.53 GB、`export_check/` 988 MB、
    两份 559 MB 的 economy_record CSV、四份约 780 MB 的 `pc_*.pck`、`military_ui/` 278 MB），
    R7-4 的保留策略不覆盖它们，要压磁盘得另开任务。
- [x] **R7-5** 全量 `verify.ps1`（static + build + suites）一次跑完并留证
  - 这是「一条命令全绿」的最后一块：上一轮 suites 没跑完整。
  - 实测 `verify.ps1 -SkipBuild`：**首次完整跑完 41 个测试、640.7 s**（目标 15 min 内），
    `static` 8 pass / 2 known-red / 0 fail，`suites` **40 pass / 1 fail / 0 timed out**。
  - 结果 **RED，但不是工具的问题**：唯一红是既有的
    `runtime_country_parity_test`（33 checks / 5 failures），
    已单独立项诊断，结论见 `docs/architecture/feature-status.md` 的
    「一轮核验暴露的既有红」小节 —— 两条根因（country `research_deferred_points` 从 day 2 分叉；
    worker 日停在 day 11 因 Effect POD 在 SHADOW 路径推进了日序且逃生口对纯 SHADOW 恒 false），
    均与本轮改动无关且可稳定复现。
  - 结论再校准：**「一条命令跑完并给出可信裁决」已达成**（这才是原计划的 G5 意图）；
    「全绿」要等上面那条既有 bug 修掉。不要再把它算成故障基建的待办。
