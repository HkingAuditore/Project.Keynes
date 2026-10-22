# 理念系统 Review（一）：主要问题与修复方案

> 对象：`docs/plans/ideology-build-redesign.md`（下称「设计文档」）在现有代码里能不能落地。
> 读者：接手修复的下一个 AI。本文只讲已经确认的缺陷：现象、证据、根因、修法、存档/ABI 影响和测试。
> 姊妹篇：`02-capability-gap-and-solutions.md`（设计能力对照）、`03-performance-and-optimization.md`（性能）。
> 行号取自 2026-10-21 的工作区，工作区是脏的，而且有人在并行改（比如 `FAMILY_METRIC_COUNT` 在 review 过程中从 63 变成了 68）。**动手前先用 `rg` 按函数名重新定位，别直接信行号。**

---

## 0. 开工前必读

### 0.1 先加载的 skill

- `project-keynes-ideology-runtime`：先读 `SKILL.md`，再读 `references/pitfalls-and-build.md`
- `project-keynes-effect-runtime`：实例 / 事务 / ACK / PKEF
- `project-keynes-modifier-runtime`：聚合策略 / stat 读取
- `project-keynes-economy-runtime`：COMMIT、epoch、tag 位图、每格 CSR
- `project-keynes-runtime-architecture`：worker 权威、POD 快照、确定性

### 0.2 构建（只有这一种方式）

```bash
cd gdext && PYTHONPATH= VSLANG=1033 "C:/Users/hkinghuang/AppData/Local/Programs/Python/Python313/Scripts/scons.exe" platform=windows target=template_debug dev_build=no -j8
```

- 只有输出里出现 `scons: done building targets.` 才算构建成功。没有这行就是失败，哪怕没看到报错。
- 不要用 `rebuild.bat`。
- Godot 进程开着时 DLL 会被锁。如果链接失败，先关掉编辑器或残留的 headless 进程。

### 0.3 测试

```bash
godot --headless --path Project/project-keynes -s tests/ideology/<name>.gd
```

- 一次只跑一个。并行跑会抢 DLL 和用户目录。
- 每项修复至少要跑：本文点名的新测试或扩展测试、`tests/ideology/` 下已有的 effect 相关测试、`runtime_worker_source_scan_test`（只要碰了 worker 代码就要跑）。

### 0.4 当前版本号（全部 fail-closed）

| 名称 | 位置 | 当前值 |
|---|---|---|
| PKID（理念存档） | `ideology_runtime.h` `SAVE_SCHEMA_VERSION` | 7 |
| IDP2（理念 POD ABI） | `runtime_ideology_pod.h` | 5 |
| PKEF（Effect 存档） | `effect_runtime.h` `SAVE_SCHEMA_VERSION` | 12 |
| Effect POD ABI | `runtime_effect_pod.h` | 1 |
| Modifier 存档 | modifier runtime | 3 |

只要改了存档或 wire 布局，就必须升版本号。旧档读到新版本要明确拒绝，不能静默兼容。另外，目录（catalog）hash 一变，旧档本来就会 fail-closed，这一点要在提交说明里写清楚。

### 0.5 纪律

- 工作区里有别人的改动，不许 revert，也不许格式化无关文件。
- 每修一项都要更新三处：设计文档对应章节、这份文档里该项的状态、skill 里过时的描述（P3-A）。
- 所有切片预算都按**确定的计数**来切（比如每天访问 N 个实例），不要按耗时切，否则会破坏确定性重放。

---

## 1. 结论速览

总判断：设计文档里的「基建已完成」（§35）不成立。L0~L6 的大部分零件确实存在，但**每格实例的生命周期在运行时是不闭环的**：目标集合和 metric 不会每天刷新；worker 路径每拿到一个快照就全量重算；metric 每次发布都会触发 Modifier 重放；X5 倍率在已经装备的卡上不生效，在 worker 路径上会被直接丢掉。这些不修，往上加内容卡只会把 bug 放大。

| ID | 级别 | 一句话 | 是否阻塞内容 | 存档/ABI |
|---|---|---|---|---|
| P1-A | 严重 | 主线程权威下，每格实例的目标集合和 metric 永不刷新 | 是：所有条件/每格卡 | 无 |
| P1-B | 严重 | worker 权威下，每次 apply 快照都重算全部国家，并丢掉 `effect_instances` | 是：性能、重复提交 | 无 |
| P1-C | 严重 | metric revision 每天单调前进，值没变也会 bump，导致 Modifier 每天重放 | 是：性能、事务膨胀 | 无（语义变化） |
| P1-D | 严重 | X5 倍率不作用于已在场的卡；worker 的 Effect POD 根本没有 scale 字段 | 是：X5 全系 | Effect POD ABI 1→2 |
| P1-E | 中 | L2-8 的「层数」是静态展开，不是 X4 事件叠层 | 是：X4 卡 | 无（先禁用） |
| P2-A | 中 | L1-6 聚合策略按 stat 生效，粒度不对，理念不能用 | 否（别用就行） | 无 |
| P2-B | 中 | 32 格上限按 cell id 升序截断，结果有地理偏置，而且对玩家不可见 | 部分 | 无 |
| P2-C | 中 | tag 没有迟滞；`STATE_LATCHED` 不进存档也不上 wire | 部分 | PKEF 12→13 + Effect POD ABI |
| P2-D | 中 | 每格贸易 stat 没有读者；`ideology.city.*` 只能加减；×3 软上限无法表达 | 是：对应卡 | 目录 hash |
| P3-A | 低 | 设计文档、skill 和代码三者漂移 | 否 | 无 |
| P3-B | 低→中 | Economy 的 `mutable` 惰性缓存在 const 方法里构建，跨线程不安全 | 潜在崩溃 | 无 |

---

## 2. 修复顺序与依赖

```
P1-C ──> P1-A ──> P1-B ──> P1-D ──> P2-C ──> P1-E ──> P2-B ──> P2-A / P2-D ──> P3
 (值不变不bump) (每日刷新) (快照增量) (scale)  (latched+迟滞) (X4禁用) (截断)   (stat)      (文档)
```

为什么按这个顺序：

1. **先修 P1-C。** P1-A 的每日刷新会把 metric 发布频率变高。如果 revision 还是无条件 bump，修完 P1-A 之后 Modifier 重放会更严重。
2. **P1-A 和 P1-B 共用一套「签名/修订号 + 切片刷新」机制。** 先在主线程把它做出来，再给 worker 路径复用。
3. **P1-D 要升 Effect POD ABI，P2-C 也要改 Effect POD 和 PKEF。** 能合在一个提交就合，少升一次版本。
4. P1-E 和 P2-* 主要是生成器校验和 stat 补洞，不依赖前面的修复，可以并行做，但要等 P1 全绿后再合入。

---

## 3. P1-A：主线程权威下实例永不刷新

### 3.1 现象

一张「本格人口 ≥ P1 时 +x%」的每格卡装备之后，人口后来涨过阈值，效果不会出现；人口跌回去，效果也不会消失。目标集合（哪些格命中 tag）同样冻结在装备那一刻。

### 3.2 证据

- `NativeIdeologyRuntime::reconcile_effect_activations`（`ideology_runtime.cpp` 约 1558 行）只有这几个调用点：
  - `start_transition` 同步成功分支（约 1923 行）
  - `poll_pending_transition` 成功分支（约 2008 行）
  - `reconcile_country_effect_activations`（约 1743 行），它只被 `apply_pod_snapshot`（约 807 行）和 restore（约 4184 行）调用
- `run_daily`（约 2696 行）不碰实例。
- Economy 每个 epoch 都会让 tag 位图失效（`economy_runtime.cpp` 约 4772 行），但没有人再去解析它。
- 现有测试抓不到这个问题：`ideology_effect_metric_publish_test` 和 `ideology_gate_chain_test` 都是「造两个世界分别比对」，没有在同一个世界里推进时间，看实例集合会不会变。

### 3.3 根因

实例集合被当成「装备状态的函数」来维护，实际上它是「装备状态 × Economy 当期输入」的函数。后一个因素没有失效通知。

### 3.4 修复方案

**第 1 步：Economy 暴露输入修订号。**

```cpp
// economy_runtime.h
uint64_t effect_input_revision() const { return _effect_input_revision; }
// 以下三处 ++_effect_input_revision：
//   capture_country_epoch() 末尾（领土/国家 epoch 变化）
//   COMMIT 发布新一期每格数据时（tag 位图、人口、产出等变化的唯一入口）
//   clear / reset（约 24510 行）
```

- 这个修订号是派生量，不进存档。restore 之后 Ideology 会走一次全量 reconcile（约 4184 行已有），天然对齐。
- 如果 worker 线程会写它，就用 `std::atomic<uint64_t>`，读用 acquire，写用 release。

**第 2 步：Ideology 预计算哪些（理念, 等级）需要刷新。**

- 目录编译时为每个 `(ideology_id, level)` 生成：
  - `has_managed_program`：存在 cell/条件/tag 选择器的 program
  - `managed_program_dense_ids`：这些 program 的 dense id 列表
- 只有 `has_managed_program` 的卡才进入刷新队列。纯 SELF 常量卡永远不需要刷新。

**第 3 步：独立的切片刷新阶段。**

```cpp
// ideology_runtime.h（新增，均不进存档）
uint64_t _effect_input_revision_seen = 0;
uint64_t _effect_input_revision_target = 0;
bool     _instance_refresh_pending = false;
uint32_t _instance_refresh_country_cursor = 0;
uint32_t _instance_refresh_item_cursor = 0;
static constexpr int32_t INSTANCE_REFRESH_BUDGET = 64; // 每次最多 reconcile 的 idea 数

bool NativeIdeologyRuntime::step_effect_instance_refresh(int64_t day) {
    if (_economy_runtime == nullptr) return false;
    const uint64_t rev = _economy_runtime->effect_input_revision();
    if (!_instance_refresh_pending && rev == _effect_input_revision_seen) return false;
    if (!_instance_refresh_pending || rev != _effect_input_revision_target) {
        // 刷新途中又来新修订：从头开始，保证结果只取决于最终输入
        _instance_refresh_pending = true;
        _effect_input_revision_target = rev;
        _instance_refresh_country_cursor = 0;
        _instance_refresh_item_cursor = 0;
    }
    int32_t budget = INSTANCE_REFRESH_BUDGET;
    for (; _instance_refresh_country_cursor < _countries.size(); ++_instance_refresh_country_cursor) {
        CountryState &c = _countries[_instance_refresh_country_cursor];
        if (c.handle == 0) { _instance_refresh_item_cursor = 0; continue; }
        for (; _instance_refresh_item_cursor < c.active_indices.size(); ++_instance_refresh_item_cursor) {
            if (budget <= 0) return true;              // 下次接着做
            IdeaState &s = c.ideas[c.active_indices[_instance_refresh_item_cursor]];
            if (!has_managed_program(s.ideology_id, s.level)) continue;
            if (has_pending_transition(c, s)) continue; // 过渡中的卡由 ACK 分支负责
            std::string ignored;
            reconcile_effect_activations(c, s, day, ignored);
            ++_counters.instance_refresh_visits;
            --budget;
        }
        _instance_refresh_item_cursor = 0;
    }
    _effect_input_revision_seen = _effect_input_revision_target;
    _instance_refresh_pending = false;
    return true;
}
```

- `run_daily` 在命令处理和过渡轮询之后调用它。
- `should_run` 增加条件：`_instance_refresh_pending || (_economy_runtime && _economy_runtime->effect_input_revision() != _effect_input_revision_seen)`。
- **worker 权威路径也要调用它。** worker 模式下实例仍由主线程门面管理，所以要在宿主每 tick 的钩子里（`world_runtime_host.gd` 的 `_consume_ideology_worker_snapshot_if_authoritative` 之后）调用一个导出方法 `step_effect_instance_refresh(day)`。不要把它塞进 `apply_pod_snapshot`，那会重新引入 P1-B。
- 计数器：`instance_refresh_visits`、`instance_refresh_passes`、`instance_refresh_restarts`，都要能从报告接口读到。

### 3.5 存档 / ABI

无。所有新字段都是派生量。restore 后把 `_effect_input_revision_seen` 置成当前值，因为 restore 本身已经做过一次全量 reconcile。

### 3.6 测试：新增 `tests/ideology/ideology_instance_refresh_test.gd`

在同一个世界里按天推进，分四段：

1. 装备一张「本格人口 ≥ P1」的每格卡，目标格人口低于 P1 → 断言该格没有实例。
2. 把人口推过 P1，跑到下一次 COMMIT → 断言出现实例，Modifier 读数改变。
3. 把人口降回去 → 断言实例退役，读数恢复。
4. 不改任何输入，空跑 5 天 → 断言 `instance_refresh_visits` 增量为 0。

另加一个 tag 目标集合变化的用例：领土扩张后，`OWN_TERRITORY` 的命中格增加。

---

## 4. P1-B：worker 权威下每次快照全量重算

### 4.1 证据

- `apply_pod_snapshot`（约 615 行）用 `next_countries` 整体替换 `_countries`（约 778 行），但从不搬运 `IdeaState::effect_instances`。新的 `IdeaState` 里 `effect_instances` 是空的。
- 紧接着（约 807 行）对**所有国家的所有 idea** 调用 reconcile。因为 held 是空的，desired 里的每一项都会被当成 `added`，于是所有实例重新 `submit_batch` 一遍，再把 metric 全部重发一遍。
- 宿主每 tick 都会调用 `_consume_ideology_worker_snapshot_if_authoritative`（`world_runtime_host.gd` 约 1355 行）。只要 worker 产出了新的 generation（generation 回退保护只挡住旧快照），就会执行上面这一套。
- 还有一个连带问题：retire 环节也失效了。held 是空的，被替换掉的实例就不会被退役，只能靠 Effect 侧的 id 去重来兜底。

### 4.2 修复方案

**第 1 步：在替换前搬运实例引用。** 按 `(country_handle, ideology_id)` 作为 key：

```cpp
// apply_pod_snapshot 中，_countries = std::move(next_countries) 之前
for (CountryState &next : next_countries) {
    if (next.handle == 0) continue;
    const CountryState *prev = find_country_by_handle(next.handle); // 旧 _countries
    if (prev == nullptr) continue;
    for (IdeaState &s : next.ideas) {
        const IdeaState *old = prev->find_idea(s.ideology_id);
        if (old == nullptr) continue;
        s.effect_instances     = std::move(old->effect_instances); // 要求 prev 可变
        s.activation_signature = old->activation_signature;
    }
}
```

**第 2 步：引入派生的激活签名（不存档）。**

```cpp
uint64_t activation_signature(const CountryState &c, const IdeaState &s) const {
    uint64_t h = mix(s.ideology_id, s.level, s.location, s.generation);
    h = mix(h, scale_epoch_for(c, s));            // P1-D：影响该卡倍率的协同位
    if (uses_economy_inputs(s.ideology_id, s.level))
        h = mix(h, _economy_runtime->effect_input_revision());
    return h;
}
```

**第 3 步：只 reconcile 签名变化的卡。**

- 新签名 == 旧签名就跳过。
- 签名不同的卡放进 P1-A 的同一个切片队列，不要在 `apply_pod_snapshot` 里同步全量执行。
- 只有 authority epoch 翻转（约 1760 行那段清空逻辑）时才强制全量。

**第 4 步：metric mask 收窄。** `all_declared` 会连带触发 X7 的全图计数，具体见 Doc 03 §3.2。

### 4.3 测试：扩展 `ideology_effect_worker_forward_test`

- 连续 apply 10 个内容不变的快照（只有 generation +1）→ 断言 forwarder `submit_batch` 调用数增量为 0、metric 发布数为 0。
- 在其中一个快照里升一张卡的等级 → 断言只有这一张卡被重新提交。
- authority epoch 翻转 → 断言全量重提交一次。
- 被替换的实例确实收到了 retire：Effect 侧实例数不会单调增长。

---

## 5. P1-C：metric revision 无条件前进

### 5.1 证据

- reconcile 发布 metric 时使用 `revision = day * 4 + 1`（`ideology_runtime.cpp` 约 1697 行）。
- `EffectRuntime::set_metric_pod`（`effect_runtime.cpp` 约 2727~2752 行）只要 `revision > instance.input_revision` 就 bump `input_revision` 并 `mark_family_effect_group_dirty`，**完全不比较值**。另外，每次调用都会执行 `advance_committed_generation()`。
- 评估阶段的 `managed_update_due`（约 5044 行）看到 `input_revision > applied_input_revision`，就会生成一笔新事务，接着走 Modifier 移除/重加和 ACK。
- 修完 P1-A 之后，每天都会发布，于是每个每格实例每天都会生成一笔无意义的事务。
- 同类写法还有：约 3894~3908 行（批量 revision 写入）、约 6865 行，以及 worker 侧的 `runtime_effect_pod.cpp`。

### 5.2 修复方案：两侧都改，各管一层

**Ideology 侧：发布前去重。**

```cpp
struct EffectInstanceRef {
    int64_t  instance_id;
    int64_t  generation;
    uint64_t metric_digest = 0;  // 新增，不存档
};
// reconcile 末尾重建 effect_instances（约 1736 行）时，按 instance_id 把旧 digest 带过去。
// 发布前：digest = hash(该 activation 的 metric_mask 下所有值)
// digest == held.metric_digest 就整行跳过；否则发布并更新 digest。
```

**Effect 侧：值变才算变。** 同时把「过期判断」和「变化判断」拆成两个字段：

```cpp
// Instance 新增（不存档；restore 时令 observed = input）
int64_t metric_observed_revision = 0;

if (revision < instance.metric_observed_revision) return true;  // 真正的旧快照
instance.metric_observed_revision = std::max(instance.metric_observed_revision, revision);
int64_t *metric = metric_ptr(instance, metric_id);
uint8_t &present = _metric_present[base + metric_id];
const bool changed = !present || *metric != value_q16;
if (!changed) return true;                                   // 不 bump，不推进 generation
*metric = value_q16;
present = 1;
if (revision > instance.input_revision) {
    instance.input_revision = revision;
    mark_family_effect_group_dirty(index);
}
advance_committed_generation();
```

- 同一个逻辑行有多列时，第一列变化会让 `input_revision` 等于 revision，后面的列用同一个 revision 写入就不再 bump。行为和原来的注释（「equal revisions are part of the same atomic logical row」）一致。
- 改完要审计所有读 `input_revision` 的地方，可以 `rg -n "input_revision" gdext/src`。重点看三处：
  - `STATE_INPUT_REVISION` 条件（约 3978 行）：有没有内容用它当「每天都会变」的时钟？如果有，改用 day。
  - ACK 推进 `applied_input_revision`（约 4145~4162 行）。
  - 约 4674 行的 dirty 判定。
- worker 侧 `runtime_effect_pod.cpp` 的同名逻辑要逐行对齐，再用 `runtime_worker_source_scan_test` 确认没有漏掉的分支。

### 5.3 存档 / ABI

布局不变。但事务数量会减少，导致事务 id 和序号不同，以「事务序列」为 golden 的测试需要更新基线。提交说明里写明这是**预期内**的变化。

### 5.4 测试

- 新增或扩展 `ideology_effect_metric_publish_test`：连续 5 天发布同样的值 → 事务数增量为 0，Modifier 版本不变；第 6 天改一个值 → 恰好 1 笔事务。
- 乱序用例：先发 rev 41 值 5，再发 rev 37 值 9 → 值仍为 5。

---

## 6. P1-D：X5 倍率覆盖失效（三个洞）

### 6.1 洞 1：协同翻转后不重算在场的卡

- `collect_affected_synergies`（约 1040 行）只翻转协同位，不会找出「倍率依赖这个协同」的已装备卡来重算。
- `magnitude_scale_for`（约 2102 行）只在 reconcile 时被读到。
- 结果：先装备 A，再装备触发协同的 B，A 的倍率保持 1.0，直到 A 自己升级。

### 6.2 洞 2：reconcile 的 present 判断忽略 scale

- 约 1590~1597 行只比较 `instance_id + generation`。scale 变了但 id 没变，就不会进 `added`，也就不会重新提交。
- 其实 `EffectRuntime::submit_instances` 本身支持「同 id 不同 scale → 原地更新」（约 3820~3831 行），只是根本没被调用到。

### 6.3 洞 3：worker 路径整个丢掉了 scale（本轮新发现）

- `EffectInstanceForwarder::submit_batch`（`effect_instance_forwarder.cpp` 约 162 行）不读 `magnitude_scales`。
- `RuntimeEffectPodInstanceInput` / `RuntimeEffectPodInstance`（`runtime_effect_pod.h` 约 262 行起）没有 scale 字段。
- `EffectRuntime::apply_pod_snapshot`（`effect_runtime.cpp` 约 503~530 行）不设置 `magnitude_scale_q16`。所以每次 worker 回写快照，主线程上的 scale 都会被重置为 1.0。
- PKEF 早就保存 scale（约 7006 / 7187 行，合法范围是 [0.25, 4.0]），所以存档没问题，问题全在 wire 上。

### 6.4 修复方案

1. **反向索引（目录编译时生成）。**
   - `synergy_id -> [program_dense_id]`：哪些 program 的倍率受这个协同影响。
   - `program_dense_id -> [(ideology_id, level)]`
   - 有了它们，`magnitude_scale_for` 也可以改成查表，见 Doc 03。
2. **只在 ACK 成功之后标脏。**
   - 在 `start_transition` 同步成功分支和 `poll_pending_transition` 成功分支里，读 `transition.changed_synergy_ids`。
   - 用反向索引找出本国受影响的在场卡，把它们放进 P1-A 的刷新队列（或者同一帧直接 reconcile，因为数量很小）。
   - 事务被拒绝时什么都不做。
3. **present 判断加入 scale。**
   - `EffectInstanceRef` 增加 `int32_t magnitude_scale_q16`。
   - `present` 的条件改为 `id`、`generation`、`scale` 三者都相等。
   - scale 不同的项进入 `added`，由 `submit_instances` 原地更新。不要先退役再新建，否则会丢掉 latched、叠层等状态。
4. **worker wire 补字段。**
   - `RuntimeEffectPodInstanceInput` 和 `RuntimeEffectPodInstance` 增加 `int32_t magnitude_scale_q16`。
   - forwarder 的 worker 路径和 shadow 路径都要写入它。
   - worker 侧生成命令时带上它；`EffectRuntime::apply_pod_snapshot` 回写时设置它，并按 PKEF 的同一范围做校验，越界拒绝。
   - `RUNTIME_EFFECT_POD_ABI_VERSION` 从 1 升到 2。
   - 最后跑 `runtime_worker_source_scan_test`。

### 6.5 测试：端到端扩展 `ideology_effect_scale_override_test`

1. 装备 A（等级不变）。
2. 装备 B 触发协同 → 断言 A 的实例 scale 等于覆盖值，Modifier 读数按倍率变化。
3. 卸下 B → scale 回到 1.0。
4. 让 B 的过渡事务被拒绝 → scale 不变。
5. 上面每一步都在 worker 权威下再跑一遍，额外断言：经过 N 次 Effect 快照回写后，scale 仍然保持。

---

## 7. P1-E：L2-8 的「层数」不是 X4 事件叠层

### 7.1 证据

- 层数在 `ideology_runtime.cpp` 约 1466~1471 行按 `templ.stacks` 静态展开成 N 层。
- 所有层共享同一个 `expires_day`（`effect_runtime.cpp` 约 2462 行）。层过期后不会再生，因为没有事件源去补层。
- 设计文档的 X4 要的是：「每发生一次事件叠一层，每层独立计时，有上限」。

### 7.2 修复方案

短期（本轮必须做）：

- **改文档。** 设计文档 §36 里 L2-8 的状态改为「静态多层已实现，事件叠层未实现」。
- **生成器拦截。** 在 `generate_ideology_catalog.py` 的 program 校验处（约 2228 行附近），遇到 `ADD_STACK + DURATION` 组合时，如果 program 没有绑定 X4 事件入口，就报错退出。这样内容作者没法写出「看起来会叠、实际上不叠」的卡。

长期：完整的 X4 设计见 Doc 02 §4.4。

### 7.3 测试

在生成器单测里加一个非法组合的样例，断言报错信息里包含 program key。

---

## 8. P2-A：L1-6 聚合策略粒度错误

### 8.1 问题

- 聚合策略（MAX / 最高 N 个等非 SUM 策略）是按 **stat** 配置的。
- 理念卡、家族、科技都写 `economy.city.output_factor` 这一个 stat。只要给它配 MAX，家族加成和科技加成就会跟理念互相吞掉。
- 来源 id 是 Effect instance id。而 X1 的并集解析让每格只剩一个实例，所以「多个来源叠加」在 Modifier 层根本看不到。

### 8.2 修复方案

- 理念不使用 L1-6。设计文档里 L1-6 改为「通用能力，理念不适用」。
- 生成器加约束：`economy.city.*` 和 `ideology.city.*` 只允许 SUM 策略，其他策略报错。
- 「多源叠加」改在 Ideology 侧计算：数来源个数 → 换算成 magnitude，见 Doc 02 X1-b。

---

## 9. P2-B：32 格截断有地理偏置

### 9.1 证据

截断按 cell id 升序取前 32，在三个地方各截一次：

- `economy_runtime_family_buff.cpp` 的 `OWN_TERRITORY` 分支
- X1 的 resize（`ideology_runtime.cpp` 约 1425~1431 行）
- 约 1462 行

cell id 通常是行优先排列，所以大国永远是西北角的格子吃到加成。

### 9.2 短期修复

1. 解析时统计 `matched_total`，写入 L6 的报告和 UI 字段，显示成「命中 N 格，生效 32 格」。
2. 改成按稳定 hash 排序后截断：`key = splitmix64(country_handle ^ (cell << 1) ^ program_dense_id)`，取最小的 32 个，用 `std::nth_element`，复杂度 O(n)。
   - 同一国家、同一格、同一 program 的选择是稳定的，扩张时不会大面积抖动。
   - 三个截断点都换成同一个函数。
3. 截断发生时计数器 `selector_truncations++`。

### 9.3 长期

改成位图 + 系数平面模型，彻底取消上限，见 Doc 03 §4。

### 9.4 测试

造一个拥有超过 32 个命中格的国家：断言命中格不全在最小 id 区间，`matched_total` 正确，跑两次结果一致。

---

## 10. P2-C：tag 没有迟滞，`STATE_LATCHED` 不持久

### 10.1 证据

- 条件锁存在 `effect_runtime.cpp` 约 5027 行。
- `latched` 不在 PKEF 里，也不在 worker wire 上（`runtime_effect_pod.h` 约 312 行附近）。读档或者 worker 回写之后，锁存状态就丢了。
- tag 只有一个阈值。人口在阈值附近来回波动时，实例会每天创建/退役，再叠加 P1-C，就是每天两笔事务。

### 10.2 修复方案

1. **持久化 latched。**
   - PKEF 12→13，`Instance` 序列化时增加 `uint8_t latched`。
   - Effect POD 的 instance 结构也加上它。和 P1-D 合并成一次 ABI 升级（1→2）。
   - 读到 12 版存档直接拒绝，保持 fail-closed。
2. **tag 迟滞。**
   - tag 定义增加可选的 `exit_threshold`，语义是：进入看 `threshold`，退出看 `exit_threshold`。
   - Economy 在 COMMIT 时保留上一期的 tag 位图平面 `prev_bits`。判定规则：`bit = prev ? (value >= exit) : (value >= enter)`。
   - `prev_bits` 必须进 Economy 存档，否则读档后第一天的判定会和连续运行的结果不同。Economy 存档版本要 +1。
   - 生成器校验：`exit_threshold` 必须在 `threshold` 的「宽松侧」。

### 10.3 测试

- 人口在阈值 ±1 内来回振荡 10 天 → 实例只创建一次。
- 存档/读档后继续跑 → 与不存档连续跑的结果逐位一致。
- worker 模式下 latched 跨快照保持。

---

## 11. P2-D：三个直接卡内容的 stat 缺口

### 11.1 每格贸易 stat 没有读者

- `economy.city.trade_output_factor` 在生成器的 `DEAD_STAT_KEYS` 里（约 136 行）。也就是说，写了也不会生效。
- 修法：照 `economy_runtime.cpp` 约 6555~6625 行的 `_city_output_*` 模式，给贸易加一套带版本门控的每格 CSR 读取：Modifier 版本变了才重建，否则直接复用。
- 在贸易结算处乘上这个因子，然后从 `DEAD_STAT_KEYS` 里移除。

### 11.2 `ideology.city.*` 只有加减

- 生成器约 2060 行只生成 gain/cut 两个变体。
- 修法：增加 `.mul` 变体，按 `modifier_runtime.cpp` 约 765 行的因子插值 `1 + (factor - 1) * magnitude` 计算。
- 运行时的读点也要识别 mul 分量，组合顺序是 `(base + add) * mul`，并写进 skill。

### 11.3 ×3 每格软上限无法表达

- 推荐的做法是在 stat 读点做 clamp：给 stat 定义增加 `soft_cap_factor`，读每格 stat 时执行 `min(value, base * cap)`。这样不需要 Modifier 聚合策略。

### 11.4 共同要求

- 每新增一个 stat，都要同步 `stat_key_families.gd`。
- 目录 hash 会变，旧存档会 fail-closed，在提交说明里写明。
- 每个新读点都要有一个最小的 headless 测试：装一张卡，读数按预期变化。

---

## 12. P3-A：文档与 skill 漂移

| 位置 | 现在写的 | 应改为 |
|---|---|---|
| 设计文档 §35 | 基建已完成 | 列出 P1-A~D 未闭环 |
| §36 L2-8 | 已完成 | 静态多层；X4 未做 |
| §36 L1-6 | 已完成 | 通用能力，理念禁用 |
| §37.7 | 只缺端到端断言 | 补上洞 1~3 |
| §41.5 | X7 未做 | X7 已在 §42/§43 落地，metric 56..67 |
| skill 的 metric 列表 | 51..55 | 0..67，并标出 X7 段 |

skill 有五份副本：`.agents/`、`.claude/`、`.codex/`、`.cursor/`、`.dsh/`。改的时候五份一起改，用 `rg -l "project-keynes-ideology-runtime" -g SKILL.md` 找全。

---

## 13. P3-B：`mutable` 惰性缓存的线程安全

### 13.1 证据

- `_epoch_tag_bits` 和 `_country_tag_counts`（`economy_runtime.h` 约 6396 行）在 const 方法里惰性构建（`economy_runtime_family_buff.cpp` 约 1007、1063 行）。
- worker 快照路径持有 `try_lock_economy_input_capture`（`world_ext_ideology.cpp` 约 303 行）。
- 但 `start_transition` 和 `poll_pending_transition` 走到 reconcile 时，没看到持有这把锁。如果此时 Economy worker 正在 COMMIT，就可能读到写了一半的缓存。

### 13.2 修复方案（二选一，推荐 B）

- **A：加锁。** 所有可能触发惰性构建的 Ideology 入口都持有同一把输入捕获锁。实现简单，但会扩大锁的范围。
- **B：COMMIT 时构建不可变快照。**
  - Economy worker 在 COMMIT 末尾构建 tag 位图和国家计数，打包成 `std::shared_ptr<const EffectInputSnapshot>`，原子发布，并附带 generation（就是 P1-A 的修订号）。
  - 读者拿到 shared_ptr 之后，整个读取过程都不需要锁。
  - 惰性构建路径删掉。
  - 这个方案同时是 Doc 03 目标架构的第一步。

### 13.3 测试

在 `runtime_*_soak` 里开启 worker 模式，长时间运行，期间不断装备/卸下每格卡，跑 TSAN 风格的断言（如果没有 TSAN，就用调试构建下的「构建中」标志断言）。

---

## 14. 完成定义（DoD）

- [ ] P1-A~D 的测试全部通过，主线程和 worker 两种权威都覆盖到。
- [ ] 空闲 5 天时，`instance_refresh_visits`、`instance_submit_batches` 和事务数增量都为 0。
- [ ] 每次升级的版本号都写在提交说明里：Effect POD ABI 1→2、PKEF 12→13、Economy 存档 +1。
- [ ] 设计文档 §35~§37、§41.5 和五份 skill 都已同步。
- [ ] Doc 03 §6 的基准在修复前后各跑一次，结果附在设计文档 §38。
