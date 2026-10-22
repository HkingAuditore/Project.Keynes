# 理念系统 Review（六）：第一轮实施的复核与纠偏清单

日期：2026-10-21。复核对象：按 Doc 01~04 实施的第一轮改动，以及 Doc 05 的自评。
读者：执行下一轮的 AI。本文是**执行清单**，不是设计讨论；设计理由仍以 01~04 为准。

> 复核方式：只读代码（未编译、未跑测试）。凡标注「需验证」的条目，请先写测试证明或证伪，再动手修。
> 行号以本次复核时的工作区为准，可能已漂移，请以函数名定位。

---

## 0. 总体结论

**方向大体正确，但节奏偏了。**

- M0（P1-A/B/C/D、P2-B/C）的代码基本到位，与 01/03/04 的路线一致，这部分认可。
- 但 M0 尚未收尾（P3-B、parity 测试、B1~B6 基线都没有），就提前接入了 M2 的系数平面（coefficient plane）。
- 平面 v1 目前存在若干**正确性**问题，并且破坏了 03 的核心性能目标「空闲 = 0」。
- P1-A 的 digest 门控粒度是全局的，在活的经济里几乎每天都会触发全量 reconcile，「idle=0」只在冻结的世界里成立。

| 阶段 | 计划 | 实际 | 估计完成度 |
|---|---|---|---|
| M0 正确性 | P1-A/B/C/D、P2-B/C 关闭，并有 parity 与基线 | 代码基本到位；P1-A 门控过粗；`latched` forwarder 列缺；P3-B、parity、基线缺 | 70~80% |
| M1 基建 | P2-D、P3-A/B、反向索引、基准 | 部分 stat 校验与文档；锁/快照与基准为 0 | ~30% |
| M2 系数平面 | 先定三条规则，再接 Economy | v1 已接入但有 P0 级问题；三条规则（单一读者、explain/UI 读平面、PKEF 绑定审计豁免）未落地 | 10~15%（当前接入反而是负收益） |
| M3~M5 | X4 / X5 形态 / X9 / X13 等 | 未开始 | 0% |
| §19 目标 | 新卡 = 只改生成器 | 179 张卡中大部分仍需 C++ | 远 |

**下一轮的原则：先止血（关平面），再收 M0，再按规则重做平面。不要继续往平面上加功能（列、X2 计数等）。**

---

## 1. 认可的部分（不要回退）

| 项 | 落点 | 评价 |
|---|---|---|
| P1-C | `EffectRuntime::set_metric_pod` 用独立的 `metric_observed_revision`，值不变直接返回；Ideology 侧每行 `metric_digest` 跳过发布，计数 `_metric_publishes_skipped` | 正确，符合 01 |
| P1-B | `apply_pod_snapshot` 搬移 `effect_instances` 与 `activation_signature`，去掉内联全量 reconcile，改为 `mark_instance_refresh_dirty()` + `recount_managed_active()` | 正确 |
| P1-A 刷新阶段 | `step_effect_instance_refresh()`：只在 pass 起点采纳新目标、cursor 不因新目标重置、按签名跳过、`should_run` 唤醒、worker 路径经 `DCWorldExt::step_ideology_instance_refresh` | 结构正确（吸收了 04 的意见）；问题在门控粒度，见 §3 |
| P1-D | `effect_magnitude.h`；reconcile 的 present 比较已含 `magnitude_scale_q16`（`ideology_runtime.cpp` ~1704）；forwarder 两条路径都写 `input.magnitude_scale_q16`（`effect_instance_forwarder.cpp` ~245/~312）；Effect POD ABI 1→2 | 正确 |
| P2-B | `effect_selector_cap.h` 稳定哈希截断，三处统一 | 正确 |
| P2-C（PKEF 半） | PKEF 12→13，`latched` 入档 | 正确；wire 半见 §4 |
| P1-A digest 去掉 state_hash | 只哈希归属列，不哈希现金/货物 | 正确方向，但见 §3 |

---

## 2. 系数平面 v1：问题与修复（最高优先级）

涉及代码：
- `gdext/src/ideology_cell_program.h`（`CellProgramEntry` / `CellProgramTable`）
- `NativeIdeologyRuntime::build_cell_program_table`（`ideology_runtime.cpp` ~3446）
- `DCWorldExt::publish_ideology_cell_programs` / `run_ideology_daily`（`world_ext_ideology.cpp` ~256 / ~265）
- `NativeEconomyRuntime::set_ideology_cell_programs` / `refresh_city_output_modifier_factors`（`economy_runtime.cpp` ~6569 / ~6579）

### 2.0 立即止血（第一件事）

在修好 2.1~2.6 之前，平面**不得**影响正式数值：

1. 加一个默认关闭的开关（例如 `NativeIdeologyRuntime::_cell_plane_enabled`，或 `DCWorldExt` 层的 feature flag），`run_ideology_daily` 中仅在开关打开时调用 `publish_ideology_cell_programs()`。
2. 开关关闭时 Economy 的 `_ideology_cell_programs` 必须为空表（`entries.empty()`），确保 `refresh_city_output_modifier_factors` 的合并分支不执行。
3. 测试 `_test_cell_program_table` 与 X2 列测试改为显式打开开关，或改用 `set_ideology_cell_program_entry_for_test`。
4. 跑一遍 `tests/ideology/` 全套 + `family_buff_runtime_test` + `economy_trade_runtime_test`，确认失败数与 Doc 05 §3 的基线一致（4 / 8），没有新增。

### 2.1 P0：generation 永远是 1，平面内容变化被忽略

**现象**
- `_cell_program_generation`（`ideology_runtime.h:750`）从不赋值；`build_cell_program_table` 是 const，只写 `out.generation = _cell_program_generation + 1`，所以永远是 1。
- Economy 早退条件（`economy_runtime.cpp` ~6602）：`valid && shape_valid && stat_version == version && ideology_generation == table.generation`。
- 第一次发布后，装卡 / 卸卡 / 升级 / synergy 翻转都不会让 generation 变化 → 只要 Modifier 的 stat 版本没变，新表完全被忽略。
- `filter_tag` 条目依赖格子标签，但缓存键里没有 `effect_input_revision` → 标签变化后结果过期。
- `column_kind = NEIGHBOR_COUNT` 依赖邻接与标签，同样过期。

**修复**
1. generation 改为**内容 digest**：在 `build_cell_program_table` 末尾对 `country_offsets` 与每条 entry 的全部字段做 FNV/mix，写入 `out.content_digest`。由发布方（非 const 上下文）维护：
   ```cpp
   // DCWorldExt::publish_ideology_cell_programs
   if (table.content_digest == _last_plane_digest) return;   // 无变化：零开销
   _last_plane_digest = table.content_digest;
   table.generation = ++_plane_generation;
   economy->set_ideology_cell_programs(std::move(table));
   ```
2. Economy 缓存键增加两项：`_effect_input_revision`（或更细的 tag revision，见 §3）与 territory revision。早退条件改为四元组全等。
3. 新测试 `ideology_cell_plane_invalidation_test.gd`（单世界）：
   - 装卡 → 格子因子变化；卸卡 → 恢复 1.0（这条今天会失败，是本 bug 的回归测试）。
   - 改变某格标签（例如人口跨阈值）→ `filter_tag` 条目随之出现 / 消失。
   - 连续 10 天无变化 → Economy 合并分支执行次数为 0（新增计数器 `city_output_plane_merges`）。

### 2.2 P0：平面与 Effect 实例重复计算（需验证后修）

**现象**
- 没有任何「此卡归平面管」的标记：生成器、Effect、Ideology 中 `rg -i plane` 只有注释。
- `collect_effect_activations`（`ideology_runtime.cpp` ~1540）对 domain 2/5 卡照常生成实例 → Modifier 在目标格写一条 GROUP 行。
- `refresh_city_output_modifier_factors` 的合并分支把 Modifier 的单格 override 作为 `base`，再叠加平面系数（`economy_runtime.cpp` ~6676 起）。
- 因此同一张卡在锚点格上可能被算两次。
- 现有 `_test_cell_program_table` 期望 cell 0 = 3.0（1.0 + 2.0），如果实例也落地应得 5.0。测试结果需要解释：要么实例没落地（夹具原因），要么测试没有覆盖到重复路径。**不要把这个测试通过当作「没有重复」的证据。**

**验证步骤**
1. 在同一夹具中同时断言：`effect_instance_report(handle)` 的实例数、`explain_effect` 的 Modifier 行、`get_city_output_factor_q16(anchor, good)`。
2. 确保夹具中实例**确实**提交到 Modifier（检查 `present`、`managed_active_total`）。

**修复（二选一，推荐 A）**
- **A. 归属标记（推荐）**：
  1. 生成器对满足平面条件的程序输出 `plane = true`（编入 Effect 程序元数据，例如 `FamilyEffectMetadataPod::plane_owned`）。平面条件 = domain 2/5、selector ∈ {0, 12, 13}、所有命令 `stacks == 1`、所有 stat 都有平面读者（见 2.4）。
  2. `collect_effect_activations` 遇到 `plane_owned` 直接跳过，不建实例；`level_managed_info` 的 `has_managed_program` 也排除它。
  3. `build_cell_program_table` 只收 `plane_owned` 的程序，不再自己猜「能不能上平面」——判定逻辑只放在生成器一处。
  4. catalog hash 改变 → 旧存档按 PKID/PKEF fail-closed（预期行为，在 05 中记录）。
  5. 04 的规则 3：PKEF 的实例绑定审计要豁免 `plane_owned` 卡（它们本来就没有实例）。
- **B. 保留实例、平面只做覆盖**：不推荐，因为 32 格上限、每格 ACK、空闲开销都还在，平面失去意义。

**测试**：同一张 plane 卡，装备后实例数 = 0，所有领土格因子 = 期望值；非 plane 卡行为不变。

### 2.3 P0：覆盖范围两条路径不一致

- 平面把 selector kind 0 解释为「整片领土」（注释称这是 X1 解锁）；实例路径把 kind 0 解析为锚点格（`resolve_effect_targets` 中 `country_anchor_cell`）。
- 同一张卡在两种模式下效果相差 N 倍（N = 领土格数），这是**设计语义变更**，不能作为副作用悄悄发生。

**修复**
1. 在生成器中显式区分：`selector=ANCHOR`（单格）与 `selector=OWN_TERRITORY`（全领土）。kind 0 的语义保持「锚点格」不变。
2. 平面 v1 只接受 `OWN_TERRITORY(12)` 与 `TAG_ANY_CELL(13)`；kind 0 不上平面（或在平面里也只作用于锚点格）。
3. 主文档的卡牌数值要按新语义重新校准（全领土 +5% 与锚点 +5% 不是一回事），把这条加入 §46。

### 2.4 P0/P1：系数语义与 Modifier 不一致

对照 `ModifierRuntime::scaled_add` / `scaled_factor`（`modifier_runtime.cpp` ~757）：
- ADD：`term.add × stacks × magnitude`
- MULTIPLY：`(1 + (term.factor − 1) × magnitude) ^ stacks`

平面现状（`build_cell_program_table` ~3533；合并 ~6700）：
- ADD：`coef = ±magnitude`，只取 `term.value` 的符号，忽略其大小。今天生成器的 `ideology.city.*` / `economy.city.*` ADD 项 `value = 1.0`，所以**目前恰好正确**；一旦有定义的 `value ≠ 1`（手写定义、默认 catalog 中的其它 economy.city 项），结果就错了。属于潜在 bug。
- MULTIPLY：合并时用 `base × coef / Q16`，即把 magnitude 当作因子本身。Modifier 的语义是插值。特别地，`resolve_definition_terms` 会对 `MULTIPLY 1.0` 的「命名项」也返回一条 MULTIPLY（`modifier_runtime.cpp` ~1636 注释），Modifier 对它的结果是 1.0（无效果），平面却会乘以 magnitude。**两者明确不一致。**
- `stacks != 1` 直接跳过并计入 `unsupported_stack`。
- 合并只在 `good_by_stat` 命中时生效，即只有 `economy.city.good.*.output_factor`。表里其它 city stat（birth、need.*、resource.*、building.*、`economy.city.output_factor`）**没有读者**，但会被收进表、计入「已上平面」。

**修复**
1. 平面条目存「已求值的增量」，在构建时完全按 Modifier 的公式计算，Economy 侧只做加法/乘法合并：
   ```cpp
   // ADD
   entry.add_q16 = q16(term.value * stacks * magnitude);
   // MULTIPLY
   entry.factor_q16 = q16(pow(1.0 + (term.value - 1.0) * magnitude, stacks));
   ```
   这样 `stacks` 也能支持，不必跳过。
2. 合并顺序与 Modifier bucket 一致：先 Σadd，再 Πfactor（`(base + Σadd) × Πfactor`，以 `ModifierRuntime::effective_value` 的实际实现为准）。不要在遍历中边加边乘——当前实现的结果依赖条目顺序。
3. 平面条件（2.2-A）要求每个 stat 都有平面读者。v1 只开放 `economy.city.good.*.output_factor`；其它 stat 在生成器中判定为 not-plane，继续走实例。
4. 测试：同一张卡分别走实例与平面，在锚点格上因子必须**逐位相等**（ADD、MULTIPLY、cut、stacks=2 各一例）。这是平面正确性的金标准，04 的「单一读者」规则也靠它保证。

### 2.5 P1：worker 权威模式下平面缺失

- `run_ideology_daily` 在 IDEOLOGY 为 worker 权威时提前返回（`world_ext_ideology.cpp` ~267），`publish_ideology_cell_programs` 不会执行。
- `world_ext_ideology.cpp` ~314 处的另一个 `set_ideology_cell_programs` 调用位于测试入口 `set_ideology_cell_program_entry_for_test`（硬编码 `generation = 1`），不是正式发布点。正式路径只有主线程 `run_ideology_daily` 一处。修 2.1 时注意：该测试入口也要改为递增 generation，否则连续两次调用会被缓存吞掉。

**修复**
1. 发布点只保留一个：「Ideology 结构变化（装 / 卸 / 升级 / synergy 翻转 / 快照应用）→ 标脏 → 在 Ideology 状态的拥有线程上构建表 → 通过不可变快照交给 Economy」。
2. worker 模式：在 `apply_pod_snapshot` 成功后（主线程拿到 Ideology 快照之时）标脏，由同一个发布函数处理。
3. parity：同一种子跑主线程与 worker 两种模式，平面 digest 与格子因子必须一致。

### 2.6 P1：线程安全

- `set_ideology_cell_programs` 在主线程直接改写 `_city_output_*` CSR 并立即 `refresh_city_output_modifier_factors()`（`economy_runtime.cpp` ~6569）。
- Economy worker 在 step 中读取同一 CSR（`city_good_output_factor_q16`）。没有看到锁或双缓冲。
- `country_cell_count` / `country_cell_at` / `cell_has_target_tag` / `neighbor_count_with_tag` 在主线程上调用，后两者可能触发 mutable 懒缓存（与 P3-B 同类）。

**修复**
1. `set_ideology_cell_programs` 只做「存入待生效表 + 原子置位」，不立即重建：
   ```cpp
   std::lock_guard lock(_plane_mutex);   // 或 atomic shared_ptr 交换
   _pending_plane = std::make_shared<const CellProgramTable>(std::move(table));
   _pending_plane_dirty.store(true, std::memory_order_release);
   ```
2. Economy 在自己的 COMMIT 阶段（拥有 CSR 的线程）交换并重建，重建结果随 epoch 发布。
3. 「发布后立即读到新因子」的需求只在测试中存在：测试调用一次 economy step 或显式 `flush_plane_for_test()`，不要为测试破坏线程模型。
4. 与 P3-B 一起做：COMMIT 时构建不可变的标签位 / 邻接计数快照，平面合并只读快照。

### 2.7 P1：每日全量重建，空闲开销不为 0

- 每天主线程：遍历全部国家与卡 → `effect_program_key`（字符串）→ `family_effect_metadata_pod`（字符串查找）→ `program_modifier_commands` → `resolve_definition_terms`（**线性扫描全部 definition 并做字符串比较**）。
- Economy 合并：`unordered_map` 合并 + 全领土 × 条目的双重循环 + CSR 重建。今天因 generation 冻结而被「碰巧」跳过；2.1 修好后会每天执行。
- `country_cell_at(country_slot)` 用的是 Ideology 的国家槽位去索引 Economy 的国家，两边槽位一致性没有校验。

**修复**
1. 在 catalog 配置时预编译 `program dense id → 平面条目模板`（stat_id、operation、预求值增量、filter_tag、column），运行期零字符串操作。
2. 表只在结构变化时重建（同 2.5 的标脏）；有 digest 短路后，重复发布也是零开销。
3. Economy 合并改为按国家增量：缓存每国「上一份条目 + 领土 revision + tag revision」，只有变化的国家重算其格子。
4. 国家用 handle（含 generation）而不是 slot 传递；Economy 侧解析 handle → slot，不一致则 fail-closed 并计数。
5. 计数器：`plane_builds`、`plane_publish_skipped`、`city_output_plane_merges`、`plane_country_merges`。空闲日四者中的 build/merge 必须为 0。

---

## 3. P1-A digest：门控粒度过粗

**现象**（`refresh_effect_input_digest`，`economy_runtime_family_buff.cpp` ~1090；调用点 `economy_runtime_publish.cpp:725`）
- 每次 commit：哈希全部格子的归属 + 全部标签位字 + **全部格子的全部已声明指标原始值**，即 O(cells × metrics)，并强制 `ensure_epoch_tag_bits()`。
- 活的经济中人口、份额等每天变化 → 全局 `_effect_input_revision` 几乎每天 +1。
- `compute_activation_signature`（`ideology_runtime.cpp` ~1976）对所有 `uses_economy_inputs` 卡混入同一个全局 revision → 所有这类卡每天签名变化 → 每天全量 reconcile。
- 结论：「idle = 0」只在冻结世界成立；P1-A 的增量收益在真实对局中接近 0，只是把每日成本从 run_daily 挪到了 refresh 阶段（外加 commit 尾部的 digest 成本）。

**修复**
1. **拆分 revision**：Economy 维护
   - `territory_revision`（归属列变化）
   - `tag_revision[tag]`（按标签：比较本 epoch 与上 epoch 的该标签位平面，按字比较，变化才 +1）
   - `metric_column_revision[metric]`（按指标列）
2. **指标列的变化判定要量化**：对用于条件判断的指标，按程序中出现的阈值做分桶（或按 Q16 量化到条件精度），只有跨桶才算变化；纯人口小幅波动不应触发。生成器可以输出每个 metric 的阈值集合供 Economy 使用。
3. **签名只混入该卡消费的输入**：`LevelManagedInfo` 预编译 `consumed_tags` / `consumed_metrics` / `uses_territory`，签名 = mix(结构字段, territory_revision?, Σ tag_revision[t], Σ metric_column_revision[m])。
4. 进一步（推荐）：按国家给出 revision——标签变化发生在哪些国家的领土内，只脏这些国家。Economy 在比较标签位平面时顺手产出「变化格子列表」，经归属列映射到国家。
5. digest 本身的成本：标签位平面比较是 O(cells × tags / 64)，指标列在 COMMIT 中本就会写，改为写入时比较即可，不必再整体重新采样。
6. 测试：
   - 只有国家 A 的人口跨阈值 → 只有 A 的相关卡被 reconcile（`instance_refresh_visits` 精确等于 A 的相关卡数）。
   - 全图人口小幅波动、不跨任何阈值 → visits = 0。
   - 标签 T 变化 → 不消费 T 的卡 visits = 0。

---

## 4. 其它未收尾项

| 项 | 现状 | 要做的事 | 验收 |
|---|---|---|---|
| P2-C wire 半 | forwarder 未读 `latched` 列（05 §2.3 已列为欠债） | worker POD input 增加 `latched`，forwarder 两条路径写入，`EffectRuntime::apply_pod_snapshot` 回写；若与 P1-D 合并 ABI 则 Effect POD ABI 2→3 | worker 模式下保存→加载后 `explain_effect(...).latched` 不变 |
| P3-B | 未做；平面又新增了主线程读 Economy 懒缓存的路径 | COMMIT 时构建不可变快照（标签位、国家标签计数、邻接计数），以 generation 发布；const 方法不再写 mutable | 开启 TSan 或加断言「懒缓存只在 owner 线程构建」 |
| synergy 反向索引 | `magnitude_scale_for` 仍 O(S) | catalog 配置时构建 `program → [synergy]`；`collect_affected_synergies` 后只标脏受影响卡 | 计数器 `synergy_scale_scans` 空闲为 0 |
| 双权威 parity | 未做（headless 无 Climate trace） | 写一个确定性的 climate fixture（固定温度 / 降水 / 事件序列），注入 headless；同种子跑主线程与 worker，比对实例集合、metric digest、平面 digest、格子因子 | 逐位相等 |
| P1-E | 未做 | 先做 01 中的「最小修复」：生成器拒绝 ADD_STACK + DURATION（无 X4 事件入口时）；主文档改正 L2-8 描述 | 生成器单测 |
| B1~B6 基线 | 未跑 | 按 03 §6 跑一次基线并落档（commit hash、DLL 时间戳、机器），之后每轮对比 | 基线文件存在 |
| 贸易因子语义 | 从产能改为按成交量（05 §1.6） | 在主文档 §46 标注为数值变更，并在 economy 分析 CSV 中跑一次前后对比 | 记录在案 |
| 未跟踪文件 | `tests/probes/_tmp_pkcm_restore_probe.gd`、`_probe_card_cell_plane.gd` | 临时探针要么删除、要么转为正式测试；不要留在 tests 里被误跑 | — |

---

## 5. Doc 05 需要更正的地方

1. P1-A 标「完成」→ 改为「结构完成，门控粒度未达标（见 06 §3）」。
2. P2-C 标「完成」，表中写「POD wire 带 latched」，与 05 §2.3 的欠债矛盾 → 改为「PKEF 完成，wire 未完成」。
3. 增加一行「系数平面 v1：实验性，默认关闭，存在 06 §2 所列问题」。
4. 增加「性能：未测量」——在 B1~B6 跑完之前，任何「零开销」表述都只是推断。

---

## 6. 下一轮执行顺序

每一步都要：编译成功（唯一信号 `scons: done building targets.`）+ 相关测试单独跑通 + 基线失败数不增加。

1. **§2.0 关平面**（开关默认关闭），确认基线。
2. **§4 B1~B6 基线**：先测，后优化，避免盲改。
3. **§3 digest 拆分**与按卡签名；补三条门控测试。
4. **§4 P3-B** 不可变快照（同时为平面的线程模型铺路）。
5. **§4 收尾**：`latched` wire、synergy 反向索引、P1-E 最小修复。
6. **§4 parity**：climate fixture + 双权威对比测试。
7. **§2 重做平面**，按此顺序：
   1. 2.2-A `plane_owned` 标记（生成器单一判定）+ 实例排除 + PKEF 审计豁免；
   2. 2.4 预求值增量与 Modifier 同公式，实例 vs 平面逐位对比测试；
   3. 2.3 selector 语义显式化；
   4. 2.1 内容 digest generation + Economy 缓存键；
   5. 2.6 双缓冲交接 + 2.5 单一发布点（含 worker）；
   6. 2.7 预编译与按国家增量合并；
   7. 04 规则 2：explain/UI 从平面读取格子因子来源。
8. **复跑 B1~B6**，与第 2 步的基线对比，结果写进 05。
9. 之后才进入 M3（X2 / X12 / X10 / X14 的廉价读取，再 X4）。

---

## 7. 每步必须提交的证据

给下一轮的复核者（以及用户）看的，不要只写「完成」：

- 编译日志末行。
- 每个相关测试的通过 / 失败数，以及与基线的差异。
- 新增计数器在「空闲 10 天」场景下的数值（应为 0 的必须是 0）。
- 若改动存档 / ABI：版本号前后值，以及旧档 fail-closed 的测试名。
- 若是数值语义变更：变更前后的对比数据。
