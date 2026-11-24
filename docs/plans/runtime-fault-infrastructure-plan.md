# 运行时故障基建计划（R1–R6）

> 状态：**R1–R6 全部落地并实测**（R4 的旧批次快照受 catalog 漂移限制，见下）
> 日期：2026-11-19（计划）/ 2026-11-19（执行）
> 触发：2026-11-19 玩家报错批次（9 份日志 + 1 张 GM 截图 + 4 份 `economy_fatal_*.json`）
> 范围：故障取证与复现、断言台账、构建标识、无头复现提速、CI 与产物治理
> 不含：LFS 迁移、经济模型改动、玩家侧上传服务器、引擎升级
>
> **执行结果与逐项实测数字**见 `runtime-fault-infrastructure-checklist.md`；
> 现状结论与验证证据见 `docs/architecture/feature-status.md` 的「运行时故障基建 R1–R6」一节。
> 与本文的偏差（已实现侧）：台账实际 2731 条而非预估 150–300 条；`PK_BUILD_ID` 走
> 生成的 `pk_build_id_generated.h` 而非逐 TU `-DPK_BUILD_ID`；`tools/ci` 实际 33 个 `.py`
> 而非 23 个；`--load-forensics` 用 configure-only 世界而非 load 请求路径
> （原因见 feature-status）。唯一仍受限的是**旧批次全量快照**：catalog 自 2026-11-18 起漂移，
> `end_country_restore` 按 fail-closed 报 `catalog_hash_mismatch` —— 旧现场请走 `.pkinc` 重放。

---

## 0. 一句话

把「玩家报错 → 我们定位到根因」从**平均 7 轮文件往返**压到**1 轮**：
现场自带构建 ID、断言 ID 与过程量；故障快照可以直接加载；一条命令离线复现；任何新增 fatal
必须先在台账登记，否则 CI 红。

---

## 1. 现状证据（全部来自本机实测，不是估计）

| # | 现状 | 量化 |
|---|---|---|
| E1 | 一次玩家批次的定位往返 | **7 轮**（日志 → 追问 → 截图 → 4 份 JSON → 仍缺存档） |
| E2 | 故障快照可用性 | `runtime_snapshots_economy_fatal_*` **131 份 / 1.07 GB**，全部 `restore_eligible:false`、`native_generation:0`、`state_hash:0` → **能写不能读** |
| E3 | `tmp/` 体积 | **7.75 GB**，无轮转 |
| E4 | 无头复现速度 | debug DLL、6400 格 ≈ **11 s/天**；玩家 day 2506 的现场要 2506 天 ⇒ ≈ 7.6 h，等于不可用 |
| E5 | 交付物体积 | debug 包单 exe **294 MB**（内嵌 pck）；无版本号，报告里看不出玩家跑的是哪次构建 |
| E6 | fatal 表达 | 本批 3 个不同 reason（`building_investment_capital_preflight_drift` / `building_construction_preflight_funds_drift` / `save_family_expedition_person_invalid`），修复前 `fatal_context` 全是 `FatalContext{}` 默认 0，**没有 cell / type / 金额** |
| E7 | 断言标识 | fatal 是裸字符串，无 ID、无 schema、无台账；同一类停机重复发生时无法自动关联 |
| E8 | CI | `tools/ci` 已有 23 个检查 + `Invoke-SaveReplay.ps1`，但**没有统一入口**，Windows 上要手动拼命令，提交前靠人记 |
| E9 | 构建产物体积与仓库 | `Build/`、`tmp/` 已 gitignore；但工作区仍会出现 `.so`/`.res` 二进制改动，缺少"单文件体积"闸门（不启用 LFS 的前提下） |

---

## 2. 目标与非目标

### 2.1 目标

| ID | 目标 | 客观判据 |
|---|---|---|
| G1 | 任何 fatal 报告自带**构建 ID + 断言 ID + witness** | 一份 `.pkinc` / `economy_fatal_*.json` 即可命名 cell/type/数值 |
| G2 | 任何 fatal 可**离线复现**，不需要玩家存档 | `--replay-incident x.pkinc` 返回 `reproduced=true` 且 witness 一致 |
| G3 | 故障时的**全量快照可加载** | `--load-forensics <dir>` 能起世界并跑到下一日 |
| G4 | 从玩家存档到复现 ≤ 15 分钟；400 天 soak ≤ 10 分钟 | `Invoke-SaveReplay.ps1` / `Invoke-Soak.ps1` 计时 |
| G5 | 新增 fatal 必须登记，否则 CI 失败 | `check_fault_taxonomy.py` 非零退出 |
| G6 | `tmp/` 与构建产物有自动治理 | 快照保留 ≤ 20 份；单文件 > 5 MB 拒绝入库 |

### 2.2 非目标

- N1 不做 LFS 迁移，也不引入新的二进制分发渠道（除 GitHub Release asset，另议）。
- N2 不重构经济账本与投资组合的写入顺序（那是 bugfix 任务，本计划只提供诊断与复现能力）。
- N3 不做玩家端自动上传（无端点；先落地本地 `.pkinc`）。
- N4 不把 witness 变成"保存格式"：`.pkinc` 是诊断产物，不进 PKEC/PKSV，不参与状态哈希。

---

## 3. 总体架构

```
        ┌───────────────────── 生产运行（玩家机器）─────────────────────┐
        │  NativeEconomyRuntime  fail()                                 │
        │      ├─ assert_id + witness(POD) ──▶ fatal_context_report()    │
        │      └─ 失败格切片（cohort/merchant/building/pending）          │
        │                        │                                       │
        │            runtime_forensics.gd（现有落盘点）                   │
        │                        ▼                                       │
        │        economy_fatal_*.json（7 KB） + x.pkinc（<200 KB）        │
        └────────────────────────┼───────────────────────────────────────┘
                                 │  玩家/测试者发一个文件
                                 ▼
        ┌───────────────────── 开发机（离线）───────────────────────────┐
        │  incident_replay.gd -- --incident x.pkinc                      │
        │      ├─ EconomyInvariantProbe::replay_incident(witness)        │
        │      ├─ reproduced? 一致 → 根因已知                             │
        │      └─ --emit-fixture → 落成常驻 fixture（CI 回归）            │
        │                                                                │
        │  --load-forensics <dir>（可选，全量快照）                       │
        └────────────────────────────────────────────────────────────────┘

        invariants.json（台账：定义 + witness schema + playbook）
              ▲                    ▲
   check_fault_taxonomy.py     docs/runtime/invariants.md（生成）
```

四个面：**定义**（台账）→ **产生**（witness + 构建 ID）→ **传输**（`.pkinc`）→ **消费**（离线重放 / fixture / 文档）。

---

## 4. R1 断言台账 + 构建标识（2–3 天，先做）

### 4.1 为什么先做这条

最便宜，且立刻改变现状：现在连"玩家跑的是哪次构建"都不知道（本批只能靠二进制里有没有
`investment_row` 字符串反推）。台账一旦存在，后续 R2/R3/R4 的 witness 字段才有统一规格。

### 4.2 `docs/runtime/invariants.json`

单文件（JSON，便于工具读取），每条一个对象：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | ✓ | 稳定 ID，`INV-ECON-####`；**永不复用** |
| `reason` | string | ✓ | 代码里实际使用的 error 字符串 |
| `kind` | enum | ✓ | `fatal` / `rejection`（命令拒绝不算停机）/ `backpressure` |
| `stage` | string | ✓ | `building_commit` / `ledger_apply` / `save_restore` … |
| `invariant` | string | ✓ | 人话不变量，例如「owner 到手资金 ≥ 建材计划 total_cost」 |
| `witness` | object | ✓ | 字段名 → 类型（与 C++ struct 一一对应） |
| `owner` | string | ✓ | 模块负责人（模块 map 的 module id） |
| `first_seen` | string | | 首次现场（玩家日志名 / 日期） |
| `playbook` | string[] | ✓ | 排查步骤（发现→定位→修复→回归） |
| `status` | enum | ✓ | `active` / `retired`（合并到其他 ID 时保留墓碑） |

示例：

```json
{
  "id": "INV-ECON-0042",
  "reason": "building_construction_preflight_funds_drift",
  "kind": "fatal",
  "stage": "building_commit",
  "invariant": "committed owner funds >= material_plan.total_cost at invoice time",
  "witness": {
    "cell": "i32", "type_id": "i32", "allocated_count": "i64",
    "total_cost": "i64", "owner_slot": "i32", "owner_funds": "i64",
    "funding_gap": "i64", "material_feasible": "bool",
    "good_count": "i32", "first_good_id": "i32",
    "first_required": "i64", "first_stock": "i64",
    "portfolio_index": "i32", "portfolio_size": "i32"
  },
  "owner": "economy.building_investment",
  "first_seen": "2026-11-19T16:18:49 day=2506",
  "playbook": [
    "先看 investment_legs：每条腿 carried/correction/credit 与 owner_funds_at_material",
    "对比预检投影：materials[i] <= allocated*(funding_capital+merchant_credit)",
    "若 owner_funds_at_material < total_cost，检查同 owner 多候选 / family 拆分 / credit 分配"
  ],
  "status": "active"
}
```

### 4.3 C++ 绑定约定

- witness 结构命名 `PkInv<Reason>Witness`，只放 POD，禁止 Godot 类型（与 `FatalContext` 同规格）。
- `fatal_context_report()` 增加两个键：`assert_id`（字符串）与 `witness`（Dictionary），
  **保留现有扁平键**（`investment_row` / `construction_row` / `investment_legs`）以兼容既有日志与 fixture。
- 现有三处 witness 直接登记：
  - `INV-ECON-0040 building_investment_capital_preflight_drift`（`investment_row`）
  - `INV-ECON-0041 building_construction_preflight_stock_drift`（`construction_row`）
  - `INV-ECON-0042 building_construction_preflight_funds_drift`（`construction_row`）
- 迁移办法：先登记台账 + 加 `assert_id`，**不改**任何断言逻辑；`witness` 对象可以逐步补齐。

### 4.4 `tools/ci/check_fault_taxonomy.py`

| 项 | 规则 |
|---|---|
| 扫描范围 | `gdext/src/**/*.cpp`（本期）；后续可扩到 GDScript 的 `_result(false, "..."` |
| 提取 | 正则 `error\s*=\s*"([a-z0-9_]{8,})"` + `fail\("...")` |
| 判定 | 命中 `invariants.json` 的 `reason` → 通过；否则 → 失败并列出文件:行 |
| 白名单 | `test_only_` / `probe_` 前缀；以及台账里 `status=retired` 的墓碑 |
| 输出 | 人读表格 + `--json` 机读；`--suggest` 生成待填条目 |
| 首次落地 | 允许一次性 `--bootstrap-missing` 自动生成 `kind=unknown` 条目清单，人工一天内分批补 `kind/playbook` |

接入：`verify.ps1` 的 static 阶段，约 2 s。

### 4.5 构建 ID

| 位置 | 做法 |
|---|---|
| SCons | 构建时注入 `-DPK_BUILD_ID="\"<git short sha>+<utc timestamp>\""`（`SConstruct` 里 `env.Append(CPPDEFINES=[...])`，取不到 git 时退化为 `nogit+<timestamp>`） |
| C++ | `pk_build_id()` 返回该常量；`fatal_context_report()`、`[runtime-forensics/*]`、`get_economy_report()` 都带上 |
| GM 面板 | 「运行时」段新增 `build_id` 行（和 Fast tick 同级） |
| 导出包 | 导出脚本额外写 `build_info.json`（git commit / 构建时间 / DLL 哈希），随包分发 |
| 存档 | **不写入** PKEC/PKSV（避免影响状态哈希与跨版本兼容） |

### 4.6 交付物与验收

| 交付物 | 验收命令 |
|---|---|
| `docs/runtime/invariants.json`（≥ 现有全部 fatal 字符串） | `python tools/ci/check_fault_taxonomy.py --strict` 退出 0 |
| `docs/runtime/invariants.md`（生成，供客服/文档查） | `--write-doc` 后 `git diff --exit-code`（幂等） |
| `assert_id` + `build_id` | `godot --headless --script tests/runtime/invariant_taxonomy_test.gd` 打印两条 ID 且非空 |

工作量 2–3 天；风险：字符串数量大（预计 150–300 条），首轮以 `kind=unknown` 入库、两周内补全。

---

## 5. R2 事故包 `.pkinc`（3–5 天）

### 5.1 目标

玩家只发一个 **< 200 KB 的 zip**，我们就能拿到"复现根因所需的全部输入"，不再需要 40 MB 存档。

### 5.2 文件布局（zip，schema v1）

```
MANIFEST.json          # 版本、生成时间、文件清单+sha256
incident.json          # assert_id/reason/stage/day/epoch/build_id/world_id
witness.json           # 该断言的 witness（与台账同字段）
cell.json              # 失败格切片：cohorts/merchants/buildings/pending/market lanes
commands.json          # 该 epoch 的结构性命令 + 账本命令（可裁剪到相关格）
world.json             # seed/尺寸/是否 formal start/catalog hashes/国家数
hashes.txt             # state_hash / ledger hash / catalog hash
```

### 5.3 采集规则（决定体积与隐私）

| 对象 | 采集内容 | 上限 |
|---|---|---|
| `cell.json` | 只采失败格：cohort 行（signature/population/funds/就业/满意度）、merchant 现金、该格建筑组（type/units/filled_owner/债务）、pending construction、该格市场 lane（good/price/stock） | 单格 ≤ 64 KB |
| `commands.json` | 该 epoch 内 `structural_commands` + `epoch_commands` 的相关子集（按 cell 过滤） | ≤ 128 条 |
| 全局 | 只有标量与哈希，不含人口/资金明细 | ≤ 8 KB |

**不含**：玩家姓名/家族全表/全图 cohort、完整 PKEC、原始 `.pksv`。

### 5.4 产生路径

1. `runtime_forensics.gd`：在现有 economy fatal 观察点（已有 `[runtime-forensics/economy_fatal/...]` 两段）
   之后追加"写 `.pkinc`"，路径与现有快照同目录（`<res>/../../tmp/incidents/`，移动端 `user://incidents/`）。
2. GM 面板新增按钮「导出故障包」：随时手动生成（无 fatal 时只含 world + 哈希 + 最近 N 天诊断）。
3. 保留策略：默认保留最近 10 份，超出按时间删（与 R6 的 prune 共用）。

### 5.5 验收

| 项 | 判据 |
|---|---|
| 体积 | day 2506 类现场单包 < 200 KB（当前快照 40 MB） |
| 完整性 | `MANIFEST.json` 的 sha256 全部匹配；缺文件时 replay 明确报缺哪一项 |
| 可读性 | `python tools/ci/inspect_incident.py x.pkinc` 打印 witness 关键字段与不变量判定 |

---

## 6. R3 离线重放 `--replay-incident`（3–4 天）

### 6.1 目标

用 `.pkinc`（无存档、无 GPU、无玩家机器）在开发机上**复现同一个断言**，并可一键转成常驻 fixture。

### 6.2 入口

```powershell
godot --headless --path Project/project-keynes `
  --script res://tests/runtime/incident_replay.gd -- --incident tmp/incidents/x.pkinc
```

### 6.3 C++ 侧

`EconomyInvariantProbe::replay_incident(const godot::Dictionary &incident, std::string &error)`
（沿用现有 `friend class EconomyInvariantProbe` 权限与 fixture 构造器）：

1. 用 `cell.json` 搭最小 runtime：`_cell_count = 1`、按 signature 建 cohort、写 population/funds、
   建 merchant CSR、建建筑组与 pending、写市场 lane；
2. 按 `witness.kind` 直接调用对应断言点（如 `commit_preflighted_build_command` /
   `investment_commit_portfolio`）；
3. 返回 `{reproduced, reason, witness_before, witness_after, diff[]}`。

绑定：`world_ext_bind_economy.cpp` 增 `economy_replay_incident(Dictionary) -> Dictionary`，
并在 `tools/ci/world_ext_binding_modules.json` 登记（模块 = economy）。

### 6.4 输出契约

| 字段 | 含义 |
|---|---|
| `reproduced` | 同一 reason + witness 关键字段一致 |
| `diff` | 逐字段差异（预期 vs 重放），为空表示完全一致 |
| `assert_id` | 便于与台账、CI 关联 |

`--emit-fixture` 时把 `cell.json` 转成 `economy_invariant_probe.cpp` 的 C++ 片段（人工 review 后入库），
让每个玩家现场都变成一条常驻回归。

### 6.5 验收

- 用 R1/R2 生成的一份真实（或 forced）现场：`reproduced=true`，且 `--emit-fixture` 产出能编译的代码片段。
- 反证：手工把 witness 的 `owner_funds` 改大 → `reproduced=false` 且 `diff` 指向该字段。

---

## 7. R4 故障快照可加载（2–4 天）

### 7.1 先诊断（0.5 天，必须先做）

现状：`economy.pkec` 40 MB 可写出，但 `restore_eligible:false`、`native_generation:0`、`state_hash:0`。
候选原因（按可能性排序，逐条验证）：

| # | 假设 | 判定方法 |
|---|---|---|
| H1 | 捕获发生在 `fail()` 之后，`_epoch_active=false` 且 generation 未被写入 header | 在捕获函数入口打印 `_committed_generation` / `_epoch_active` |
| H2 | 捕获用的是"候选 scratch"对象，从未 `begin_restore` 前的 bootstrap 标记 | 对比正常存档 header 与 forensics header 的字段差异 |
| H3 | 捕获为了体积裁剪了 header 的某些段（catalog hash / 国家哈希） | 读 PKEC header 段长度与 `SAVE_SECTION_HEADER` 写入路径 |

产出：一页结论写进 `feature-status.md`（"为什么不可加载"），再决定 R4 的实现形态。

### 7.2 捕获契约（据诊断结果二选一）

- **优先**：在 committed boundary 的**拷贝**上捕获：先把 `_fatal`/`_epoch_active` 排除在捕获条件之外，
  显式写 `generation = _committed_generation`、`state_hash = 当前提交哈希`、catalog hash、国家指纹；
- 兜底：捕获时额外写 `header_rebuild.json`（最小重建信息），`--load-forensics` 用它在内存里补 header。

### 7.3 加载入口

`--load-forensics <dir>`（新入口，走生产恢复路径，不另写一套 restore）：

- 校验 `country.pkcn` + `economy.pkec` 配对与 schema；
- 载入后进入 **只读会话**：禁用自动存档/手动存档，GM 面板显著标注 "FORENSICS（只读）"；
- 允许推进 N 天用于复现，退出时不写任何玩家槽位。

### 7.4 体积与留存

- 全量快照改为**按需**：默认只写 R2 的 `.pkinc`；全量 PKEC 需 `PK_FORENSICS_FULL=1` 或 GM 手动导出；
- 留存：默认 20 份 / 30 天，超限自动删（`tools/ci/prune_tmp.ps1`）；
- 预计 `tmp/` 从 7.75 GB 降到 < 1 GB。

### 7.5 验收

- 取一份今天的玩家 `runtime_snapshots_economy_fatal_*`（旧格式）能在本机跑起来（若 header 缺失则走兜底）；
- 新格式快照：`--load-forensics` → 推进 1 天后 `fatal=false` 且状态哈希稳定（两次加载一致）。

---

## 8. R5 无头复现提速（2–3 天）

### 8.1 现状

debug DLL 下 6400 格 ≈ 11 s/天（`commit_us ≈ 11.2e6`）；`speed=50` 还会撞 throughput gate
（`--jobs` 并行时更容易触发，与正确性无关但拖时间）。

### 8.2 三条路径（按优先级）

| 路径 | 做法 | 预期 |
|---|---|---|
| A（默认） | 构建脚本切换 `.gdextension` 映射到 **release DLL**（`dots_ext…template_release.dll`），跑完还原；编辑器进程不重启，只需新起的 headless 进程 | 5–20×（目标 ≥ 100 天/分钟） |
| B | 导出 release 包，包内走 `PK_SAVE_REPLAY` / 新增 `PK_SOAK_REPLAY` 内置入口（不依赖编辑器） | 用于分发验证与"玩家机器同构"复现 |
| C | 编译 profile：给复现专用 target 打开 `-O2`、关 debug 断言 | 仅在 A/B 都不够时评估 |

注意：A 必须处理"映射切换后忘记还原"的风险 —— 脚本用 `try/finally`，并在 `verify.ps1` 里检查
`.gdextension` 是否指向 debug（防止误提交 release 映射）。

### 8.3 工具增强

`tools/runtime/Invoke-SaveReplay.ps1` 增加：

| 参数 | 作用 |
|---|---|
| `-UntilDay N` | 跑到指定日即停（而不是固定跑 N 天） |
| `-StopOnFault` | 首次 fatal 立即退出并返回 code 2 |
| `-Bundle` | fatal 时自动生成 `.pkinc`（复用 R2 的 GM 导出路径） |
| `-Release` | 走 8.2-A 的 release DLL |
| `-Json` | 机读汇总（day、fatal、耗时、consecutive ok days） |

新增 `tools/runtime/Invoke-Soak.ps1` 包装 `headless_perf_record.gd`，统一输出目录与摘要。

### 8.4 验收

- 400 天 soak（60×40）< 10 分钟；`fatal=false`、账本零错误；
- 从玩家 `.pksv` 到复现（含构建/加载/推进）< 15 分钟；
- 修复 `rows == measured_samples` 的既有 off-by-one（`headless_perf_record.gd`），让 soak 不再误报。

---

## 9. R6 CI 一键核验与产物治理（2–3 天）

### 9.1 `tools/ci/verify.ps1`（唯一入口）

| 阶段 | 内容 | 时长目标 |
|---|---|---|
| `static` | `check_fault_taxonomy.py`、`check_cpp_deps.py`、`check_module_*`、`check_script_native_access.py`、`git diff --check` | ≤ 2 min |
| `build` | debug（必要时 release）增量编译 + DLL 符号表自检（含 `build_id`） | ≤ 6 min |
| `suites` | 27 套件按 4 路并行，汇总 JSON；失败附最后 40 行 | ≤ 15 min |
| `soak`（可选 `-WithSoak`） | 400 天 soak + 守恒断言 | ≤ 10 min |

输出：`tmp/verify_<timestamp>.json` + 人读摘要；退出码：0 全绿 / 1 失败 / 2 环境问题。

### 9.2 现有 23 个 `tools/ci` 脚本的 Windows 适配清单

先跑一遍 `--dry-run` 分类：可直接跑 / 需路径适配（macOS 默认路径）/ 需 Godot 参数。
产出清单写进 `docs/build-from-source.md`（"Windows 单机核验"一节），避免下一个人再摸一遍。

### 9.3 产物与磁盘治理

| 项 | 规则 |
|---|---|
| 仓库 | `Build/`、`WebBuild*/`、`tmp/`、`tests/probes/_tmp_*` 继续 gitignore（已就位） |
| 大文件闸门 | 新增 `tools/ci/check_large_blobs.py`：`git diff --cached --stat` 中单文件 > 5 MB 直接失败（白名单：已入库的历史二进制） |
| **不使用 LFS** | `.gitattributes` 不添加任何 `filter=lfs`；大文件应放 Release asset 或网络盘 |
| tmp 轮转 | `tools/ci/prune_tmp.ps1 --keep-incidents 20 --keep-days 30 --dry-run`；可挂到 `verify.ps1` 尾部 |
| 调试包 | `--export-debug` + `embed_pck=false`，补丁只发 `.pck`（294 MB → 增量约 100 MB），并在包内附 `build_info.json` |

### 9.4 验收

- 一条命令 `.\tools\ci\verify.ps1` 全绿（含新 taxonomy 与 blob 闸门）；
- 故意 `git add` 一个 6 MB 文件 → 被拦并提示替代方案；
- `prune_tmp.ps1 --dry-run` 能列出将被删除的 130 份快照。

---

## 10. 里程碑

| 里程碑 | 内容 | 预计 | DoD |
|---|---|---|---|
| M1 | R1 台账 + 构建 ID | 第 1 周 | CI 有 taxonomy；报告有 `assert_id`/`build_id` |
| M2 | R2 事故包 + R3 离线重放 | 第 2 周 | 一份真实 `.pkinc` → `reproduced=true`；可 `--emit-fixture` |
| M3 | R4 快照可加载 | 第 3 周 | 旧快照 + 新快照都能 `--load-forensics` |
| M4 | R5 提速 + R6 CI/治理 | 第 4 周 | soak ≤ 10 min；`verify.ps1` 一条命令全绿 |

依赖：R3 依赖 R2 的 schema；R4 与 R2/R3 独立（可并行）；R5/R6 依赖 R1 的 `build_id` 自检。

---

## 11. 风险与回滚

| 风险 | 影响 | 缓解 | 回滚 |
|---|---|---|---|
| witness schema 漂移 | 旧 `.pkinc` 读不了 | `MANIFEST.schema` 版本化；replay 支持 n-1 | 保留旧字段扁平输出 |
| 离线重放"貌似复现"但根因不同 | 误判 | 要求 witness 关键字段逐一相等才算 `reproduced`；`diff` 非空即失败 | 退回人工对比 |
| 快照加载污染玩家存档 | 数据事故 | 只读会话 + 禁存 + 独立临时目录；启动时高亮提示 | 删除临时会话目录 |
| `--load-forensics` 绕过校验扩大攻击面 | 误用 | 仅桌面调试入口、需显式 `--load-forensics`；导出包内编译期关闭 | 编译开关关闭 |
| CI 时长超 30 min | 没人跑 | 分层 `-Quick`；增量缓存；soak 默认关闭 | 退回手工命令清单 |
| 台账首轮 300 条压不住 | 半途而废 | `--bootstrap-missing` 先入库 `kind=unknown`，按模块分批补 | 只对 `kind=fatal` 强制 |
| release 映射切换残留 | 提交进 release 路径 | `verify.ps1` 检查 `.gdextension` + `try/finally` | 脚本自动还原并报错 |

---

## 12. 验收总表

| 检查 | 命令 |
|---|---|
| 台账完整 | `python tools/ci/check_fault_taxonomy.py --strict` |
| 构建 ID 可见 | `godot --headless --path Project/project-keynes --script tests/runtime/invariant_taxonomy_test.gd` |
| 事故包体积/完整 | `python tools/ci/inspect_incident.py tmp/incidents/x.pkinc` |
| 离线复现 | `tests/runtime/incident_replay.gd -- --incident x.pkinc` → `reproduced=true` |
| 快照可加载 | `--load-forensics <dir>` 后推进 1 天，`fatal=false` |
| 复现速度 | `Invoke-SaveReplay.ps1 -SavePath x.pksv -UntilDay N -Release` 计时 |
| CI | `.\tools\ci\verify.ps1` |
| 磁盘 | `prune_tmp.ps1 --dry-run` |

---

## 13. 待决问题（需要拍板）

1. **CI 形态**：本机 `verify.ps1` 为主（推荐，native 构建走 Windows），还是加自托管 runner？
   GitHub Actions 的 Linux runner 无法跑这套 Windows + native 构建。
2. **`.pkinc` 回收**：只落本地让测试者发群，还是提供一个上传端点（需要对象存储与合规确认）？
3. **全量快照策略**：默认关（只留 `.pkinc`）还是保留"每次 fatal 一份全量"？（当前 1.07 GB / 131 份）
4. **发布通道**：debug 包是否走 GitHub Release asset（不走 LFS，单文件上限 2 GB）？
5. **降级策略**：在 R1–R4 就位后，是否把"不可兑付的投资腿"从 fatal 改为"裁剪 + 留痕"？

---

## 14. 本轮不做

- 不改任何断言逻辑与账本顺序（R1–R6 都是"看得见、跑得动、拦得住"，不改经济行为）；
- 不引入 LFS / 不改 `.gitattributes` 的过滤器；
- 不把 `.pkinc` 或 witness 写进 PKEC/PKSV；
- 不做玩家端 UI 大改（只在 GM 面板加两个按钮/一行构建 ID）。
