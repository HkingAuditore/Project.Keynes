# 理念系统 Review（四）：对前三份评估的复核

> 对象：`01-issues-and-fixes.md`、`02-capability-gap-and-solutions.md`、`03-performance-and-optimization.md`。
> 问题：这三份评估能不能直接当作施工规格？
> 答案：**结论和优先级可以照用，但 01 的 P1-A 规格必须改，否则它会推翻 03 自己的验收标准。**
> 本文只做一件事：把三份文档里「与代码不符」和「文档之间互相打架」的地方挑出来，给出可直接替换的写法。
> 行号取自 2026-10-21 12:30 的工作区；工作区是脏的，动手前仍要用 `rg` 按函数名复核。

---

## 0. 判定

| 维度 | 结论 |
|---|---|
| 事实准确性 | **高。** 抽查 20 余处行号与结构断言全部命中，可见是照代码树写的，不是凭印象生成 |
| 缺陷定性 | **基本成立。** P1-A/B/C/D、P2-B/C、P3-B 都能在源码里复现 |
| 修复规格 | **P1-A 有致命挂点错误**，P2-C 的定性需要拆开，其余可照写 |
| 结构性缺口 | 缺双权威等价性判据；Doc 03 的系数平面缺「同一 stat 第二个写者」的收敛规则 |
| 是否阻塞开工 | P1-C 可以立刻做；P1-A **改完规格再做**；P1-D 可以照写 |

一句话：**这不是一份需要重写的评估，是一份需要打三个补丁再交付的评估。**

---

## 1. 复核方法

1. 对每一条带行号的断言，按函数名 `rg` 重定位，再读上下文判断语义，不只看行号对不对。
2. 对「版本号 / 上限 / 计数器」这类常量，直接读定义处，拒绝引用文档里的二手数字。
3. 对「测试抓不到」这类否定性断言，打开测试文件看它到底推不推进时间。
4. 只记录分歧，不复述三份文档已经写清楚的内容。

---

## 2. 逐条验证结果

### 2.1 成立的（可直接施工）

| 编号 | 断言 | 证据 |
|---|---|---|
| P1-A | `reconcile_effect_activations` 只在过渡成功分支和恢复时被调用，`run_daily` 不碰实例 | 调用点 `ideology_runtime.cpp:1923 / 2008 / 807(经 1743) / 4184`；`run_daily` 在 2696，函数体内无实例相关代码 |
| P1-B | `apply_pod_snapshot` 整体替换国家表且不搬运 `effect_instances`，随后全量 reconcile | 636 建 `next_countries` → 778 `_countries = std::move(...)` → 805-809 对所有国家调 `reconcile_country_effect_activations` |
| P1-C | metric 发布无条件推进 revision，不比较值 | `set_metric_pod`(`effect_runtime.cpp:2727`)：2740 只挡旧 revision，2743 直接写值，2746-2749 才 bump，2750 无条件 `advance_committed_generation()`；ideology 侧 `revision = day * 4 + 1`(1697-1698) |
| P1-C | 修完 P1-A 后会每天一笔无意义事务 | `managed_update_due` 看 `input_revision > applied_input_revision`(5046)，与 P1-C 叠加成立 |
| P1-D 洞 1 | 协同翻转不重算在场卡 | `magnitude_scale_for` 只在 reconcile 内被读 |
| P1-D 洞 2 | present 判断忽略 scale | 1590-1597 只比 `instance_id + generation` |
| P1-D 洞 3 | worker 路径整个丢掉 scale | `effect_instance_forwarder.cpp:162` 起只读 12 列，无 `magnitude_scales`；`RuntimeEffectPodInstanceInput`(262) / `RuntimeEffectPodInstance`(282) 无 scale 字段；`RUNTIME_EFFECT_POD_ABI_VERSION = 1`(`runtime_effect_pod.h:18`) |
| P2-B | 32 格截断按 cell id 升序，且三处各截一次 | `economy_runtime_family_buff.cpp:1235/1265/1305/1323`、`ideology_runtime.cpp:1398` |
| P3-B | 惰性缓存在 const 方法里构建 | `ensure_epoch_tag_bits()`(`economy_runtime_family_buff.cpp:1010`)、`ensure_country_tag_counts()`(1072) 均为 const，写 `mutable` 成员 |
| 常量 | PKID 7 / IDP2 5 / PKEF 12 / Modifier 3 / `FAMILY_METRIC_COUNT=68` / `SELECTOR_MAX_CELLS=32` / `max_instances=4096` | `ideology_runtime.h:36`、`runtime_ideology_pod.h:18`、`effect_runtime.h:37`、`modifier_runtime.h:30`、`economy_runtime.h:476`、`effect_runtime.h:193`、`effect_runtime.h:931` |
| 无基准 | stress 测试没有每格 program | `tests/ideology/ideology_runtime_stress_test.gd` 只合成 `stress.idea.%04d` 假卡，不加载真实目录 |
| 无覆盖 | metric 发布测试不推进时间 | `ideology_effect_metric_publish_test.gd` 内无任何日期循环 |

### 2.2 有问题的（见 §3、§4）

| 编号 | 问题性质 |
|---|---|
| P1-A | 修订号挂点错误，导致门控恒失效 |
| P1-A | 游标「新修订即归零」会饿死尾部国家 |
| P2-C | 把有意设计写成隐藏缺陷，ABI 影响被高估 |
| Doc 03 §4 | 系数平面缺写者收敛规则，与 skill 的 PKEF binding 不变量冲突 |

---

## 3. 必须修正的三处规格

### 3.1 P1-A：修订号不能挂在 `capture_country_epoch()` 末尾

**文档原文**（01 §3.4 第 1 步）：

> 以下三处 `++_effect_input_revision`：`capture_country_epoch()` 末尾（领土/国家 epoch 变化）……

**实际情况**：`capture_country_epoch()` 不是「领土变化时才跑」的函数，它是 **epoch 起始路径的一部分**，
每个经济 epoch 都无条件执行（`economy_runtime_epoch.cpp:905`，紧接 `clear_epoch_metrics()` 与
`rebuild_family_demography_weights()` 之后）。函数体本身也没有任何变化检测——它在 4769 重建领土索引、
在 4773-4777 无条件把 tag 位图与国家计数置失效。

**后果**（这是文档内部的矛盾，不是外部批评）：

- 修订号每天 +1 → `rev == _effect_input_revision_seen` 永不成立 → 每天全量刷新。
- `_instance_refresh_pending` 永不落回 false → `should_run` 永真 → 图永不进入空闲。
- 于是 **03 §6.2 的「B5：空闲 5 天计数器必须为 0」在实现上不可达**。两份文档互相否定。

这正好重演 P1-C 的形态：把「时间过去了」当成「输入变了」。

**替换写法**：修订号的语义必须是**输入内容摘要**，不是时间戳。

```cpp
// economy_runtime.h —— 派生量，不进存档
uint64_t effect_input_revision() const {
    return _effect_input_revision.load(std::memory_order_acquire);
}

// economy_runtime_family_buff.cpp —— ensure_epoch_tag_bits() 真正重建位图之后
uint64_t digest = fnv1a64(_epoch_tag_bits.data(), _epoch_tag_bits.size());
// 目录声明了哪些非 tag 的每格 metric（如 cell.population）就读哪些列一起摘要，
// 否则「只按人口比较、不带 tag」的卡永远刷不到。
digest = fnv1a64_mix(digest, sample_declared_cell_columns_digest());
if (digest != _published_effect_input_digest) {
    _published_effect_input_digest = digest;
    _effect_input_revision.fetch_add(1, std::memory_order_release);
}
```

- 摘要只覆盖**目录真正消费的输入**：tag 位图联合体 + 被 `metric_mask` 引用到的非 tag 每格列。
  列清单在 `configure_ideologies()` 时由 catalog 交出，Economy 存一份位图即可；N = 8192 时摘要成本是微秒级。
- `capture_country_epoch()` **不要**动修订号。它只负责让缓存失效，失效 ≠ 内容变了。
- 这样「输入不变 ⇒ 没有任何卡被访问」（03 §3 O1 的不变量）才在语义上成立，B5 才可能为 0。

### 3.2 P1-A：刷新游标不能在每轮开头归零

**文档原文**（01 §3.4 第 3 步的伪代码）：

```cpp
if (!_instance_refresh_pending || rev != _effect_input_revision_target) {
    // 刷新途中又来新修订：从头开始，保证结果只取决于最终输入
    _instance_refresh_pending = true;
    _effect_input_revision_target = rev;
    _instance_refresh_country_cursor = 0;
    _instance_refresh_item_cursor = 0;
}
```

**问题**：预算 `INSTANCE_REFRESH_BUDGET = 64` 是按 idea 数切的，而 `run_daily` 每天至少被调一次
（`should_run` 在 `_last_day < day` 时返回 true，2839-2843），同日续跑依赖 `_active_progress_day == day`，
不是刷新游标那条路径。规模代入：512 国 × 12 张在场卡 = 6144 项，一轮需要 96 次切片。
配合 §3.1 的「每天 +1」，游标每天被清零，**第 65 项之后永远刷不到**，而且不会有任何报错。

这不是切片，是抽样。且它破坏确定性重放：哪些国家被刷新取决于当天调用了几次，而不是输入。

**替换写法**：**一轮未跑完之前不采纳新目标。**

```cpp
if (!_instance_refresh_pending) {
    const uint64_t rev = _economy_runtime->effect_input_revision();
    if (rev == _effect_input_revision_seen) return false;
    _instance_refresh_pending = true;
    _effect_input_revision_target = rev;   // 只在开新一轮时采纳
    _instance_refresh_country_cursor = 0;
    _instance_refresh_item_cursor = 0;
}
// ……按预算推进……
// 一轮结束：
_effect_input_revision_seen = _effect_input_revision_target;
_instance_refresh_pending = false;          // 下一轮再采纳当时的最新值
++_instance_refresh_passes;
```

- 中途修订前进时，本轮继续用旧目标跑完；跑完后 `seen != 当前 rev`，下一轮自然重新开始。
  结果仍然只取决于最终输入（会多一轮），但**每一轮都是完整的**，尾部不会饿死。
- 计数器相应改为 `instance_refresh_passes`（证明轮次有限）+ `instance_refresh_lag_revisions`
  （`rev - seen`，用于观察经济比理念快多少）。`instance_refresh_restarts` 不再需要。
- 预算取值要满足「一轮在有限切片内跑完」：把 `INSTANCE_REFRESH_BUDGET` 定为
  `ceil(managed_idea_count / 期望切片数)`，或者干脆按国家数切（每片 8 个国家）。
  **不要按毫秒切**，否则破坏确定性。
- `should_run` 的新增条件要加门：`_managed_idea_count > 0`。没有任何托管卡时，
  修订号怎么变都不该让图醒过来。

### 3.3 P2-C：拆成「PKEF 缺」与「wire 有意省略」两半

**文档原文**（01 §10.1）：

> `latched` 不在 PKEF 里，也不在 worker wire 上……读档或者 worker 回写之后，锁存状态就丢了。

**实际情况**：wire 那一半是**写在注释里的自觉取舍**。`runtime_effect_pod.h:311-315`：

> Last evaluation's raw condition result, mirroring `EffectRuntime::Instance::latched`.
> **Not part of any wire format: the worker owns its own latch and a resync simply resets it,
> which costs one cadence of "must re-cross the upper threshold".**

代价被量化过：一个 cadence 的重穿越。把它和「PKEF 没存」并列成一条「中级缺陷」，会让接手者
以为挖到了未记录的 bug，实际只是没读注释。修法上两者也不该绑在一起：

| 半边 | 是不是真缺口 | 什么时候必须修 |
|---|---|---|
| PKEF 不存 `latched` | 是。读档后滞后行为与连续运行不一致 | 只要接受 §10.3 的「存档前后逐位一致」标准，就必须修 → PKEF 12→13 |
| POD wire 不带 `latched` | 不是缺口，是取舍 | 只有在「worker 回写后也必须与同步路径逐位一致」成为验收标准时才修 → 顺带升 Effect POD ABI |

建议的定性：**P2-C 拆成 P2-C1（PKEF，必修，PKEF 12→13）与 P2-C2（POD，可选，与 P1-D 的 ABI 1→2 合并）**。
这样 P1-D 那次 ABI 升级不会被一个「其实可以不修」的需求拖动，也不会被它拖住。

---

## 4. 两处结构性缺口

### 4.1 没有双权威等价性判据

三份文档的全部 P1 验收都是**计数器**（`submit_batch` 增量为 0）或**单世界断言**（实例出现/消失）。
而 P1-B 这一整类缺陷的本质是：主线程权威与 worker 权威对同一个种子给出不同结果。

计数器只能证明「没有重复提交」，证明不了「提交的东西一样」。单世界断言只能证明「这一条路径对」。
唯一能覆盖这一族的是**同一 seed、两种权威、逐位比对终态**：

```
同一 seed → 主线程权威跑 30 天 → 记录 per-country: 活跃卡集合 / 等级 / 协同位 /
                                       每格实例集合 / stat 读数 / 事务数与 id 序列
同一 seed → worker 权威跑 30 天 → 同上
断言：两侧逐位相等；实例集合按 (source_id, program_id, target, layer) 归一后相等
```

- 放在 `tests/ideology/ideology_authority_parity_test.gd`，并在 DoD 里立一条。
- 这个测试本来就能在 P1-B 上线前抓住它，也是后续 P1-A/P1-D 唯一不会漏的回归网。
- 注意 headless fixture 必须先 `bind_map_data()` 再跑一次 economy slice，否则邻居图是空的，
  所有环选择器都返回空集，测试会**空过**（skill 里已记录过这个陷阱）。

### 4.2 系数平面缺「同一 stat 第二个写者」的收敛规则

`ideology.city.*` 现在是通过 Modifier 写进 `economy.city.*` 的。Doc 03 §4 的系数平面等于
给同一个每格 stat 加了**第二个写者**，但 §4.3 只写了「结果接入现有的 stat 读取」，
§4.5 只说「PKEF 布局不变，内容变少」。三件事没有交代：

1. **读取点必须收成一个。** 现在每格 stat 有 `_city_output_*` 式的带版本门控缓存（`economy_runtime.cpp:6555-6625`）。
   平面要么复用这条缓存（把 `ideology_add` 作为缓存的一部分），要么新增一条读取路径 ——
   后者会让同一格在不同系统里读到不同值，且不会报错。
2. **`explain` 与卡面必须从平面读。** §4.6 只覆盖了「命中哪些格」，没覆盖「每格数值从哪来」。
   实例消失后，`get_ideology_effect_instance_report()` 对平面卡返回空，卡面会显示「无效果」——
   这正是**静默失真**，且和现有 `present` 列那类「归属位不是生效位」的历史坑同形。
3. **PKEF binding 审计要显式豁免。** skill 的不变量是：**每个在场理念都必须解析到自己的 PKEF v10
   external binding**，否则读档 fail-closed。平面卡不再建 Effect 实例，这条审计会把它们全部判为损坏。
   §4.5 必须补一句：审计范围改为「`plane == false` 的在场卡」，且平面卡的等价保证由
   `CellProgramTable` 的重建确定性承担。

第 3 条是硬的：不补，平面开关一打开，所有带平面卡的存档都读不进来。

---

## 5. 其他偏差（不阻塞）

| 位置 | 文档写的 | 实际 |
|---|---|---|
| 02 §0 | 已上线 program 卡约 26 张（12 SELF + 9 溢出 + 5 条件） | skill 记 30 张（另有 2 张 X7、2 张 X7b 国家级计数卡）；26 是「用到格选择器」的数目，不是 program 卡总数 |
| 01 §3.2 | 两个测试「都是造两个世界分别比对」 | `ideology_gate_chain_test.gd:228` 有 `for day in range(1, 4)`。结论（没有跨阈值推进）仍成立，措辞过宽 |
| 01 §12 | skill 五份副本在 `.agents/ .claude/ .codex/ .cursor/ .dsh/` | 正确，但这五个目录在 **`Project.Keynes/`** 下，不在 workspace 根；workspace 根只有 `.cursor` |

---

## 6. 施工建议

顺序沿用 01 §2（P1-C → P1-A → P1-B → P1-D），但：

1. **P1-C 立刻做。** 它不依赖任何别的改动，且是 P1-A 的前置——否则修完 P1-A 事务会更多。
2. **P1-A 按 §3.1 + §3.2 改规格后再动手。** 先落地「输入摘要式修订号」，
   再谈切片；两者顺序反了会得到一个永远不空闲的图。
3. **P1-A 不要做精致。** M2 上系数平面后这套刷新机器整体删除。
   够用、确定性、可观测三条满足即可，别优化常数。
4. **P1-D 照写**，但把 P2-C2（POD latched）并进同一次 ABI 升级，P2-C1（PKEF）独立。
5. **§4.1 的等价性测试与 P1-C 同批提交。** 它便宜，而且它是后面每一步的回归网。
6. 每步完成后，把 03 §6 的 B1~B6 与 01 §14 的 DoD 各跑一次；B5 的计数器为 0 是
   「修订号语义正确」的唯一物证，比任何 review 结论都硬。

---

## 7. 一页纸

- [ ] P1-A 修订号改为「tag 位图 + 被消费的每格列」的摘要，挂在 `ensure_epoch_tag_bits()` 之后，不挂在 `capture_country_epoch()` 末尾
- [ ] P1-A 刷新游标改为「一轮未完成不采纳新目标」，预算按确定计数切
- [ ] `should_run` 的门控加 `managed_idea_count > 0`
- [ ] P2-C 拆成 PKEF（必修）与 POD wire（可选，随 P1-D 的 ABI 1→2）
- [ ] 新增 `ideology_authority_parity_test` 并写进 DoD
- [ ] 系数平面补三条：读取点唯一、explain 读平面、PKEF binding 审计豁免平面卡
- [ ] 02 的「26 张」与 skill 的「30 张」对齐口径
