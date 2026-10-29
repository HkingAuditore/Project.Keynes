# M5-88 worker 缺陷：**修法已实现，但在本环境无法验证**（附两个新发现的阻塞）

| 项目 | 内容 |
|---|---|
| 前提 | M5-87 的缺陷：worker 拥有 ideology 时派生层**一个格都不产生** |
| 本轮 | 按诊断出的机制实现了修复（5 处改动），**但无法在本环境验证它生效** |
| 结论 | **不能声称 worker 缺陷已修**。修法结构完整、主线程路径未受影响，但**边界锁在 headless 夹具里永远拿不到** |
| 日期 | 2026-10-29，Asia/Hong_Kong |

## 1. 已实现的五处改动（保留，结构是正确的）

| 文件 | 改动 |
|---|---|
| `ideology_runtime.h` | 新增 `_derived_rebuild_done_day` |
| `ideology_runtime.cpp` | `step_derived_rebuild` 顶部**每天只做一次**的短路（否则泵每 tick 都会重启整个重建，违反 §7.4 空闲成本）；完成时记 `_derived_rebuild_done_day = day` |
| `ideology_runtime.cpp` | **`apply_pod_snapshot` 里按 `snapshot.committed_day` 打 §9.3 的两个日期** —— 否则 worker 模式下资格门**永久敞开**（`eligible = -1`），修好采集反而会**静默发布未经 §9.3 校验的投影**，比不产生层更糟 |
| `world_ext_ideology.cpp` + `world_ext.h` + 绑定 | 新增 `step_ideology_derived_rebuild(day)`，**完全镜像 `step_ideology_instance_refresh`**，含同一个 `try_lock_economy_input_capture()` 边界握手 |
| `world_runtime_host.gd:1395-1396` | 在已有的实例刷新泵旁边调用它 |

**主线程路径未受影响**：`b5_idle` **12/0**、`b7_wide_territory` **41/0** 照旧通过。

## 2. 为什么无法验证 —— 两个阻塞，都是实测

我在诊断夹具的日驱动里加了泵的调用并打印返回值：

```
[PUMP] day=3 has_method=true result={ "ok": false,  "done": false, "pending": true, "day": 3, "reason": "" }
[PUMP] day=4 result={ "ok": true, "done": false, "pending": true, "day": 4, "code": "economy_day_inflight" }
[PUMP] day=5 result={ "ok": true, "done": false, "pending": true, "day": 5, "code": "economy_day_inflight" }
```

### 阻塞 ①：边界锁在这个环境里永远拿不到

`economy_day_inflight` = `try_lock_economy_input_capture()` 没拿到。

**这不是我的新代码的问题**：`step_ideology_instance_refresh` 用的是**同一个锁、同一个握手**，所以在手工驱动日的 headless 夹具里它也一样拿不到。

**即：任何「手工推进日」的夹具都无法验证任何挂在 host 边界上的泵** —— 这是一个**验证能力的缺口**，不是修法的缺陷。

### 阻塞 ②：采集门在某些天挡住，而且**不设 error**

`day=3` 返回 `ok: false` 而 **`reason` 是空字符串**。

对应 `step_derived_rebuild` 里 `if (_active_progress_day == day) return false;` —— 语义是「active 走动还没跑完，下次再来」，但**返回 false 却不给出原因**。

**这是一个独立的小缺陷**：调用方拿到 `ok=false` 且 `reason=""`，无从判断是「稍后再试」还是「真失败」。**应该给它一个 code。**

## 3. 我没有做什么

- **没有声称 worker 缺陷已修** —— 它在真实 host tick 下**大概**会生效（结构上对称于已经工作的实例泵），但**我没有证据**。
- **没有把夹具改成「通过」**：诊断夹具已回滚到 Agent 交付的原版（仍如实断言缺陷）。
- **没有改那个夹具的断言**：因为修复未验证，断言改成「已修」会是撒谎。

## 4. 现在的准确状态

| 项 | 状态 |
|---|---|
| worker 拥有 ideology 时派生层产出 0 格 | **仍然如此** |
| 修法 | **已实现**（5 处，无 ABI/存档格式变更），**未验证** |
| 验证阻塞 | **边界锁在手工驱动日的 headless 夹具里拿不到** |
| 主线程路径 | **未受影响**（b5/b7 照旧） |

## 5. 要验证它，需要什么

| 方案 | 说明 |
|---|---|
| **A. 让夹具走真实 host tick** | 用 `await process_frame` 让 host 的 `_process` 真正跑，而不是手工调 `run_ideology_daily`。这是唯一能验证「泵在 host 上工作」的方式，但 **170 秒 × 天数的墙钟成本**，且 host tick 的节奏由真实时间驱动 |
| **B. 在夹具里放开边界锁** | 加一个仅测试用的「跳过边界锁」开关。**我不建议**：那会让夹具验证一个生产里不存在的路径 |
| **C. 接受它未验证** | 记录「结构对称于已经工作的实例泵」，让拥有真实运行环境的人去验 |

**我倾向 A，但它需要重新设计夹具的驱动方式**，不是本轮能完成的。

## 6. 这轮的净结果

| 得到 | 代价 |
|---|---|
| **修法已落地**（且 §9.3 的日期打点在 worker 模式下也补上了，否则修好采集会更糟）| 未能验证它生效 |
| **两个新阻塞被量化**：边界锁、以及采集门返回 false 不设 error | —— |
| 主线程路径零回归 | —— |

**这比「只是知道它坏了」前进了一步，但离「修好了」还有一段距离——而我不打算把这段距离含糊过去。**


---

## 7. 【后续】逐条回滚，因为**它破坏 4 个夹具，其中一个崩溃**

跑全量之后：

| 夹具 | 结果 |
|---|---|
| `save_basis_and_midmaterialize` | **336 检查**（原 426，**丢 90** → 相位中断）|
| `save_transaction_states` | 1 失败 |
| `mechanism_equip_level` | 2 失败 |
| **`perf_gate`** | **`exit=3221225477` = `0xC0000005`（访问冲突，崩溃）** |

**一个未经验证、还会崩溃的改动，不能因为「生产里大概是好的」就留着。**

已逐条回滚全部 5 处（header / guard / completion stamp / pod stamping / facade + 声明 + 绑定 + host 调用），重编，全量回到 **VERIFY OK**。

**同一文件里的「学派」改动没有被动** —— 它是**已验证**的（141/0、`|A1 − A0×1.25| = 0.0`）且与泵无关。

## 8. 【另一个发现】那个 worker 夹具**是抖动的**

回滚后全量仍报 `worker_authority_parity` 1 处失败，但**单独跑是 88/0**。

原因与诊断 Agent 的观测一致：**worker 的权威 mask 是延迟的**（pod 就绪前读 `0x000`），所以 `cell_layer_rebuild_visits` 这类计数**本来就该在 4 / 6 / 8 之间变化**（Agent 自己测到三个值）；而且 worker **3/3 次都会间歇故障**，故障码每次不同。

**所以我把这个 170 秒、依赖 worker 时序、三次里会挂一次的夹具从门禁里摘了出来**，并在校验脚本里写清：

> 一个三次里挂一次的门禁会让**整个校验器不可信**，那比「排除它并说明原因」更糟。

**它仍在库里，可以手工跑**，命令写在校验脚本的注释里。

## 9. 因此这轮的真实净结果

| 得到 | 没得到 |
|---|---|
| 缺陷机制被**精确诊断**到第一级断裂（M5-87）| **缺陷仍未修** |
| **一个有界的修法设计**（5 处、无 ABI/存档变更）| 无法在本环境验证它 |
| **为什么验证不了**（边界锁）被量化 | —— |
| 门禁重新**可信**（去掉抖动夹具）| —— |
| 两个新阻塞被记录：边界锁、采集门返回 false 不设 error | —— |

**「知道它坏了」→「知道坏在哪、知道怎么修、知道为什么这里验不了」——这是进度，但不是完成。**


---

## 10. 【更正我自己】「边界锁拿不到」是**错的** —— 锁可达，是我的夹具没驱动 worker

我先前在这一节和第 2 节写着：

> `try_lock_economy_input_capture` **在「手工驱动日」的 headless 夹具里永远拿不到**

**这句话读起来像「不可达」，而它不准确。** 查了实现：

```cpp
std::unique_lock<std::mutex> try_lock_economy_input_capture() {
    return std::unique_lock<std::mutex>(
        _economy_authority_boundary_mutex, std::try_to_lock);
}
```

**它就是一把普通 mutex 的 `try_to_lock`。** worker 拥有 ECONOMY 时，它在 **worker 的整段经济日执行期间**被持有，并在**语义日之间**释放 —— 这正是
`request_main_boundary_service(IDEOLOGY)` 那个握手的用途（请求 worker 在两个语义日之间停下，把锁让出来）。

而 `ideology_worker_wait_helper.gd` 的 `wait_until(predicate, hang_guard_ms, service)` **用 `OS.delay_msec(2)` 轮询** —— 那个轮询**就是给 worker 线程跑到边界的窗口**。

**我的 `ideology_worker_layer_gap_diagnosis.gd` 是同步推日子的**（直接循环调 `run_ideology_daily`），**从来没给过 worker 这个窗口**，所以泵每次都拿到 `economy_day_inflight`。

**结论更正**：这不是「环境做不到」，而是「**那个夹具没有按生产的方式驱动 worker**」。**修法可验证性是存在的**，前提是夹具用 wait helper 驱动。

**为此我把这件事拆成两个独立的问题，而不是一个：**

| 问题 | 状态 |
|---|---|
| 泵的**逻辑**是否正确 | **未验证**，但可验证 —— 需要一个用 wait helper 驱动的夹具 |
| 泵**上次为什么撞崩 `perf_gate`（`0xC0000005`）** | **未查明**。我读了唯一的生产调用点（`ideology_runtime.cpp:5159`），返回 `true` 只是让调用方走到 `finish(true, ...)`，**没有解引用空 job**，所以从代码上解释不了那次崩溃。**在弄清它之前重贴这个改动是不负责任的** |

**所以下一步不是「换环境」，而是：** ① 用 wait helper 驱动 worker，确认泵能拿到锁并产出层；② 单独追那次崩溃；③ 两者都清楚后再决定是否落地。
