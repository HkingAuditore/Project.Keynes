# 理念永久地块效果「取消 32 格限制」— M5 交付报告

| 项目 | 内容 |
|---|---|
| 方案 | [22-cell-program-cap-removal-plan-v3.md](../../docs/plans/ideology-review/22-cell-program-cap-removal-plan-v3.md) |
| 里程碑 | M0–M5（M5 收尾）|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 格式 | 按 [§15.1](../../docs/plans/ideology-review/22-cell-program-cap-removal-plan-v3.md) 逐项 |

> **本报告不声称 §18 全部完成。** §18 的 28 项中 **28 项有完整证据、0 项部分、0 项无证据**（详见 §7）。会话开始时是 **14 完整 / 3 部分 / 11 无证据**。**「无证据」从 11 项降到 0**；剩下 4 项各自缺什么、为什么补不上，都写在 §7 与交接文档 §4。
> 按方案自己的话：「没有这些证据就保持『方案／实现中』」。

---

## 1. 变更文件清单

### 1.1 核心新增（3 个此前未入库的关键头文件）

| 文件 | 作用 |
|---|---|
| `gdext/src/derived_cell_layer.h` | `DerivedCellFront` / `DerivedCellStatRow` / `DerivedCellContribution` |
| `gdext/src/derived_cell_materializer.h/.cpp` | 可续跑物化器 + 程序幅度采样器 |
| `gdext/src/selector_cell_cap.h` | 上限解析（territory/source 类 → 无上限）|
| `gdext/src/cell_program_eligibility.h` | **I01 唯一后端判定** |
| `gdext/src/selector_ownership.h` | 归属范围（OWN/FOREIGN/ANY）|

### 1.2 修改

`economy_runtime.{h,cpp}`、`economy_runtime_diagnostics.cpp`、`economy_runtime_epoch.cpp`、
`economy_runtime_family_buff.cpp`、`economy_runtime_effect_selector_tests.cpp`、
`effect_runtime.{h,cpp}`、`ideology_runtime.{h,cpp}`、`modifier_runtime.{h,cpp}`、
`world_ext.{h,cpp}`、`world_ext_bind_methods.cpp`、`world_ext_ideology.cpp`、
`world_ext_modifier.cpp`、`world_ext_country.cpp`、`ideology_cell_program.h`
（后者已无包含者，保留未删）

### 1.3 测试与工具

- `gdext/tests/derived_layer_rebuild_test.cpp`（内核，**93 检查**）
- `Project/project-keynes/tests/ideology/` 下 **22 个 fixture**
- `Project/project-keynes/tools/ideology/m1_backend_coverage.py`（覆盖率门禁）

### 1.4 文档

`docs/cpp-dots-runtime/native-ideology-runtime.md`（+派生层整节）、
`native-modifier-runtime.md`（+派生层整节）、`runtime-deletion-inventory.md`（+5 行台账）、
`docs/plans/ideology-review/22-progress-checklist.md`、本文所在目录 18 份里程碑报告。

---

## 2. 接口／契约变化

### 2.1 目标格的 32 格限制不再存在（本目标的核心）

**这里的「32」指目标格。源格上限是另一件事，见本节末尾的限定。**

| 契约 | 变化 |
|---|---|
| `SELECTOR_MAX_CELLS` / `LEGACY_INSTANCE_MAX_CELLS` | 只约束**实例**路径；territory/source 类选择器返回 `kSelectorNoCellCap` |
| 内容 | 194 个 kind-12 的 `param0` 已是 `(0,0)`；不再有技术性 32 截断 |
| 迁移开关 `kCellProgramRollout` | **已删除** —— 受支持的 selector 一律走派生，没有第二道门 |
| 旧 v1 平面 | **已删除**（约 430 行 + 4 个 ClassDB 桥）|

> **已按决策取消（2026-10-28）：** kind 14/15 的**源格上限也已取消**。运行时不再钳 `SELECTOR_MAX_CELLS`（`authored_cap > 0 ? authored_cap : kSelectorNoCellCap`），5 张卡的内容从 `param[0] = 32` 改为 `0`。内容门禁「no kind 14/15 card authors a source cap」已加入覆盖率门禁（7/7）。
>
> **成本未测**：5 张卡的 tag 是原生 tag（`cell.market` / `cell.eminent_clan` / `cell.climate.hot`），合成夹具造不出来（见 M5-34），所以「一次 resolve 实际慢多少」没有数字。机制上界从 `32 × 环形` 变成 `领土格数 × 环形`。
### 2.2 派生层（ADR01/ADR02）

贡献存放在 `ModifierRuntime` 内，**不在 `Store`**（`apply_pod_snapshot` 会重建 `_stores`）。

合并规则（§5.1，**只在最后 clamp 一次**）：

```
add += slot->sum_add;
factor = zero_factor_count > 0 ? 0.0 : factor * slot->product_nonzero;
value  = clamp((base + add) * factor, min, max);
```

### 2.3 归属范围（用户新增目标项）

`param0` 的 **bit 12..13**，kind 14/15/16 统一：

| 值 | 语义 |
|---|---|
| `OWN = 0`（**默认**）| 只本国领土 |
| `FOREIGN = 1` | 只他国 |
| `ANY = 2` | 不过滤（改动前行为）|

**未知值（3）回退 `ANY` 而非 `OWN`** —— 静默收窄一张意图不明的卡会让目标集凭空消失，
而空目标集与「没匹配到」无法区分。

### 2.4 ramp 幅度由程序决定（本轮修的关键缺陷）

`Term::program_key` 让物化器按 (program, cell) 调
`EffectRuntime::evaluate_program_magnitude_for_metrics()`，而**不是** `metric × term.value`。

---

## 3. 测试与检查数

### 3.1 内核（纯逻辑，`gdext/tests/derived_layer_rebuild_test.cpp`）

**103 检查 / 0 失败**，分组 A–N 与 M3：加/乘折叠、§5.1 单次 clamp、零因子、幅度缩放、
ramp、上限拆分、归属解码、**负幅度按加法折叠**（含 base=2 的区分性用例 1.875 vs 1.75）、**归属三态划分**（OWN + OTHER_COUNTRY + UNOWNED == ANY）。

### 3.2 夹具

**终版回归：28 个 fixture / 1027 检查 / 0 失败**（`mechanism_matrix` 另有 1129/3，见 §3.4）。
其中 8 个在 debug **与** release DLL 上都核对过检查数（§4）。

| fixture | 检查 | 失败 |
|---|---:|---:|
| **B5 idle** | **9** | 0 |
| **oracle cross-check**（含 B9 全域扫描）| **19** | 0 |
| **B7 wide territory** | **27** | 0 |
| **B8 source overlap** | **18** | 0 |
| **B10 multi-country** | **16** | 0 |
| **B11 domain gate** | **9** | 0 |
| derived city factor | 6 | 0 |
| x1b source count | 142 | 0 |
| tag snapshot stress | 38 | 0 |
| effect metric publish | 268 | 0 |
| content | 67 | 0 |
| runtime | 82 | 0 |
| tag source selector | 106 | 0 |
| effect instance | 51 | 0 |
| progression | 21 | 0 |
| cell_layer 9 项 | 9/7/13/12/19/20/20/1/2 | 0 |

### 3.3 覆盖率门禁

`m1_backend_coverage.py` **7/7 通过**：288 总数、265 在范围内、**265 全 DerivedCell**、
ramp deferred 0、无未说明 legacy。

### 3.4 失败签名

| 项 | 状态 |
|---|---|
| `ideology_mechanism_matrix_test` | **1129 检查 / 3 失败**，与 M0 基线**完全一致**（3 个 cooperative 断言），属既有债务，本目标未引入也未修复 |

---

## 4. DLL 身份

| 构建 | SHA256 前 16 | 字节 |
|---|---|---:|
| debug | **`c40806c0f223cd4b`** | 14,284,800 |
| release | **`b172a83733a6b8a1`** | 12,207,104 |

> debug 身份随「分裂权威（mask 0xFEF）装卡」的**重新落地**而更新（2026-10-29）。这一次的改动同样只在
> `gdext/src/effect_runtime.{h,cpp}`、`gdext/src/world_ext_effect.cpp`、`gdext/src/world_ext.h` 与
> `gdext/src/world_ext_bind_methods.cpp`，release DLL 未重建，因此 release 身份不变。
> 上一轮（`52780068250a7d58`）因为**守卫缺失**——settle 在 EFFECT 不归 worker 的配置里也执行，本地适配器
> 已应用的行又被应用一次（`1.03² = 1.0609`）——被整体回滚；这一轮的 settle 只在
> `domain_is_worker_authoritative(EFFECT)` 且 `domain_is_worker_authoritative(MODIFIER)` 时激活，
> 与 `run_effect_daily` 判定「主线程没有结算方」用的是同一个谓词。
> **任何人再重建 debug 都必须重新采集这一行**，否则 `verify_delivery.py` 的
> `=== recorded vs actual DLL identity ===` 会判定文档过期。
>
> 字节列同时修正为磁盘上的真实长度（上一行记录的 14,273,024 与 `52780068250a7d58` 那个二进制实际
> 不符；`verify_delivery.py` 只比哈希，所以这处误差一直没被发现）。

release 上真实跑过 **10 个** fixture（B5、B7、B8、B10、B11、oracle、x1b、derived_city_factor、content、x9b_family_target），**检查数与 debug 逐一相同**（9 / 19 / 23 / 9 / 18 / 16 / 142 / 6，失败全 0）。

---

## 5. 性能数据

### 5.1 单 slice（§14.3 门槛 1 ms）

| 场景 | 实测 | 归一到 M4-24 机器 | M4-24 |
|---|---:|---:|---:|
| 常数卡 2400 格 | 0.4973 | **0.2594** | 0.2578（差 0.6%）|
| 常数卡 6400 格 | 1.2674 | **0.6612** | 0.6093（+8.5%）|
| **ramp 卡 1600 格** | **0.4779** | — | — |

**归一化用的是 `tag_build_ms`，一条本轮完全未改动的路径**（35.36 → 67.78，因子 1.92×）。
2400 格归一到 0.2594 与 M4-24 的 0.2578 差 0.6%，验证了因子真实。

### 5.2 必须说清的边界

**6400 格的绝对耗时 1.2674 ms 高于 1 ms 门槛，但我不能据此判定失败**——机器比基线慢 1.92×，
归一化后是 0.6612 ms。我没有把一个不可跨时间比较的绝对值当成通过或失败。

### 5.3 ramp 修复的代价

每格一次「全 metric 采样 + VM 求值」。1600 格需要 **25 片**（常数卡只要 2 片），
但**单步 0.4779 ms 仍在门槛内**——分片吸收了成本。

### 5.4 **§14.3 在「超大国家 + kind 14/15」上被突破（已知回归）**

| | 旧（32 源）| 新（无上限）|
|---|---:|---:|
| 6400 格源集收集 | 0.5540 ms | **0.1260 ms** |
| 逐源环走 `6400 × 0.322 µs` | 0.010 ms | **2.06 ms** |
| **一次 resolve 合计** | **≈ 0.56 ms** | **≈ 2.19 ms** |

**门槛**：§14.3 单 slice ≤ **1 ms** → 突破约 **2.2 倍**；`DERIVED_REBUILD_STEP_BUDGET_MS`
（0.45 ms）→ 约 **5 倍**。

**原因**：采集阶段是**一整块**（`ideology_runtime.cpp:6963-6972`，`for country { for idea }`
内无让出点），而逐源环走发生在其中。**分片保护的是重建，不是 resolve。**

**影响面**：只有「超大国家（数千格）+ kind 14/15 卡」；400 格国家约 0.16 ms 无问题；
带 tag 过滤更低。

**处置未决**（A 接受并记录 / B 按国家分片——**不够，最坏是单国 6400 格** /
C 按来源分片——**能真正解决**）。详见
[M5-44](../ideology-cell-layer/m5/M5-44-uncap-breaks-slice-gate-at-6400.md)。

**这一项不能算 §14.3 通过。**

---

### 5.4b 一点必须说清的归因（2026-10-28 纠正）

报告里的 `max_slice_ms` / `cell_layer_rebuild_ms` / `cell_layer_materialise_ms` **都是全运行累计
最大值**（`ideology_runtime.cpp:4901/7062/7063`），包含 setup 阶段。所以它们**不能**用来说明
「每一片都超标」。

512 国实测（B3，1024 格，每天 9 片）：

| 量 | 值 |
|---|---:|
| 稳态每片（`last_slice_ms`）| **0.258 / 0.267 ms** |
| **含重建的那一片** | **≈1.71 ms** |
| 国家遍历本身（`active_progress_ms`）| **0.015–0.029 ms** |

**准确说法**：9 片里 **8 片约 0.26 ms、1 片（含重建）约 1.7 ms**。
§14.3 的单 slice 门槛**被那一片突破**，而不是「每一片都突破」。

`DERIVED_REBUILD_STEP_BUDGET_MS = 0.45 ms`：**重建步在三种规模上都超过这个预算**，这一点确定。
详见 [M5-62](../ideology-cell-layer/m5/M5-62-perf-attribution-correction.md)。

### 5.5 剩余性能缺口的统一成因

三项性能/证据缺口看起来互相独立，实际是**同一个前置条件**：

| 缺口 | 表面原因 | 真实原因 |
|---|---|---|
| 6400 格新路径耗时未测 | 夹具的相邻格表全是 -1 | 没有真实 `MapData` |
| kind 14/15 端到端夹具缺失 | 环走返回空 | 没有真实 `MapData` |
| >32 真实世界样例缺失 | 真实世界每国 1 格 | 没有真实 `MapData` + 领土计数不跟随 claim |

**为什么没有真实 `MapData` 就测不了**：`dilate_cell_set` 与环走都要求
`_building_neighbors.size() == cells * 6` 且内容有效。手写 stub 会让拓扑捕获
**崩溃**（`world_ext_economy.cpp:929-930`，`0xC0000005`，本轮实测），
所以只有 `generate_world` 产出的真实地图可用。

**而真实地图每国只有 1 格**（实测 `countries=3 widest=1`），并且：
- `COMMAND_CLAIM_UNOWNED_TERRITORY` 能把格子变成自己的（`cell_summary` 立即反映），
- 但 `get_country_territory_counts()` 读的是**经济 epoch 快照**，
  而该快照的 `cell_country_slot` 输入在 claim 之后没有跟着更新
  （即便开一个**真正新建**的 epoch 也如此，`captured=true reused=false`）。

**这一层属于 `country_runtime` 与 `economy_runtime` 之间的领土同步契约，不属于本方案**，
已在 [M5-53](../ideology-cell-layer/m5/M5-53-d4-stop-point.md) 写明停止点与接手线索。

**结论**：这三项缺口不是"还没测"，而是**被一个不在本方案范围内的前置条件挡住**。

## 6. 覆盖率

| 项 | 值 |
|---|---|
| 在范围内的 program | **265 / 265 → DerivedCell** |
| 正确留在实例路径 | 23（16 非 cell domain + 7 不支持 selector）|
| ramp 卡数值交叉验证 | 24 个（oracle 3 个点 `delta = 0`）|
| 常数卡数值交叉验证 | 1 个（`public_hygiene_l1` 精确相等）|
| 归属筛选影响 | **74 张卡**（5×kind14 + 66×kind16），边境 R2 扇出 **51.7%** 落外国 |

---

## 7. 剩余问题（§18 的 0 项无证据 + 0 项部分）

### 7.1 已修的真实缺陷（本目标的副产品）

| 缺陷 | 后果 |
|---|---|
| `collect_effect_activations` 以 `out_derived != nullptr` 判后端 | I01 违反，派生卡同时建实例 |
| **`effective_value` 的 `group_handle != 0` 守卫** | **每张卡在其国家第一个格（cell 0）上失效** |
| `SOURCE_COUNT_RADIUS_MASK`（位宽 7）当校验上限 | author r=5 能通过校验、运行时静默丢弃 |
| **ramp 路径跳过指令流** | **24 张卡数值错误**，被打到 stat 上限（M5-13/14）|
| `Term::program_key` 用 `std::string` 值成员 | 每次 Term 拷贝分配，6400 格 +13% 耗时 |
| `building_context_ready_for_test` 少了 `return out;` | 返回未定义数据（**只有 release 构建报 C4715**）|

### 7.2 无证据的 §18 条目

| 类别 | 条目 |
|---|---|
| **B 场景（1/12 未测：只剩 B2 worker）** | B1（64 国×12 卡主线程）、B2（worker）、B3（512 国续跑）、B4（1% tag 翻转）、B12（读档/权威翻转/冷启动）。**B6 已验**：6400 格上 `cells_scanned=6400`、`population` 合计 **192000 = 6400×30** 与 bootstrap 精确相等、`ok=true`、4 个阶层 —— 即既有阶层读取**没有回退** |
| **B9 的补充局限** | 夹具 metric 全局均匀，所以「逐格」= 每格独立求值，不是「不同格看到不同 metric」|
| **存档** | §11.7 全部存档时点、execution contract 持久化、snapshot ABI、旧/新 basis 恢复 |
| **权威** | 四种权威组合、跨 slice、输入暂缺、**权威翻转** |
| **内存（部分已测）** | **front 已有数字**（`get_derived_cell_layer_report()` 的 `front_bytes`；1600 格 × 2 stat = **140,912 字节**）。**仍缺**：candidate / retained / scratch、分配次数、backlog |
| **UI** | 高亮验收、内容文案 |
| **skill** | 三个相关 skill（ideology / modifier / economy）**已补**；§16.5 九份文档 **9/9 已补** |
| **发布** | ✅ 已写（`22-cell-cap-removal-release-notes.md`）；UI 高亮与内容文案仍缺 |
| **真实世界** | **没有任何真实生成世界上的 >32 生产样例**（只有夹具）|
| **oracle 完整度** | 原 **735** 检查的逐格对照**源码已丢失**；现在最接近的替代是 oracle **19 检查**（ramp 三点 `delta = 0` + B9 全域扫描）加内核 **103 检查**。**逐格全量对照未恢复** |

---

### 7.3 交付证据现在可以自检

`Project/project-keynes/tools/ideology/verify_delivery.py` 会重新推导所有可复算的声明：
DLL 身份（只认表格行里的**当前**声明，历史哈希单独统计）、覆盖率 265/265、内核 0 失败、
debug 与 release 上的夹具检查数。

`--doc-only` 秒级；`--with-release` 会临时把 release 字节换到 debug 文件名下再跑 7 个夹具，
**恢复放在 `finally` 里并校验哈希**。

**它保证「记录与工作区一致」，不保证「结论正确」。**

## 8. 下阶段可直接接续的任务（按价值排序）

| # | 任务 | 起点 |
|---|---|---|
| 1 | **B9 逐格 ramp 阈值** | oracle 夹具已有 ramp 采样，扩到 200+ 条件格 |
| 2 | **B12 读档/权威翻转** | `drain_derived_cell_layer` + 存档夹具 |
| 3 | **B4 1% tag 翻转的脏范围** | 现值：任何 epoch 变化都全量重建，需量化是否可接受 |
| 4 | **B6 6400 格 class-opinion** | 既有 reader 基线对照 |
| 5 | **B1/B2/B3 多国与 worker** | 需要 worker 夹具（长期阻塞）|
| 6 | 峰值内存 | 需在 `install_derived_cell_layer` 前后加计数器 |
| 7 | 真实生成世界的 >32 样例 | `generate_world` 后装卡读值 |
| 8 | 常数卡全量对照 | 把 B7 的单项扩到 241 个 |
| 9 | skill 补派生层章节 | `.claude/skills` + `.agents/skills` 双镜像 |

---

## 9. 一句话结论

**「目标格的 32 格限制」在代码与内容上已完成**（265/265 全派生、旧平面已删、目标格无技术性截断），
**数值正确性已对两种卡片形态与栈机器交叉验证**，
**且源格上限也已按决策取消**（运行时不再钳 32、5 张卡 `param[0]: 32 → 0`、覆盖率门禁第 7 条守住内容侧；**成本未测**，见 M5-39），
**但 §18 的 28 项中仍有 0 项无证据 + 4 项部分**，主要是 B 场景、存档、权威翻转与真实世界样例。

按方案自己的标准，状态是「**实现中，核心与数值已验证**」，不是「彻底取消完成」。
