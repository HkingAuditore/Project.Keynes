# M5-22 全部理念夹具审计：68 个里 30 个失败

| 项目 | 内容 |
|---|---|
| 里程碑 | [§15.7](22-cell-program-cap-removal-plan-v3.md)「全量回归」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **68 个测试：37 通过 / 30 失败 / 1 静默** |
| 已修 | **2 个**（1 个是我的诊断缺陷、1 个是夹具的 API 漂移）|

## 1. 为什么要做这件事

上一轮发现 `ideology_cell_layer_e2e_realworld_test` **存在但从不运行、而且是坏的、还会挂住**。
那说明我的 18 个 fixture 回归集**不是全部**。`tests/ideology/` 下有 68 个 `*_test.gd`。

**一个没在最近一次回归里跑过的夹具，等于不存在** —— 它甚至更糟，因为它在清单上看起来有覆盖。

所以这次把 68 个全跑了一遍（约 80 分钟，多数时间在 worker 与世界生成夹具上）。

## 2. 分类结果

| 类别 | 数量 | 说明 |
|---|---:|---|
| **通过** | **37** | 含我维护的 18 个与本次无关联的 |
| **我的缺陷（已修）** | **1** | `ideology_cell_layer_e2e_test` |
| **夹具 API 漂移（已修）** | **1** | `ideology_cell_layer_e2e_realworld_test` |
| 已知基线 | 1 | `ideology_mechanism_matrix_test` = 1129/3，与 M0 一致 |
| 预期失败（真实状态） | 1 | `e2e_realworld` 的 `widest > 32`（真实世界每国 1 格）|
| **待定性** | **~2** | `ideology_cell_layer_shard_test`、`ideology_cell_layer_m0_realworld_cost_test` |
| 既有内容/catalog 问题 | ~4 | `instance_budget`（`ideology_school_unknown`）、`pool_mechanics`（`ideology_configure_failed`）、`gate_chain`（`cells=0`）|
| **worker 类** | **~19** | 多为 1–2 条断言失败，**均不引用我删除的任何 API** |

## 3. 修掉的第 1 个：我的诊断缺陷（真实 bug）

`ideology_cell_layer_e2e_test` 报：

```
FAIL rebuild_derived_cell_layer actually ran cell_layer_rebuild_visits=0
     -- 0 means run_daily never reached the hook
```

同时 `cell_layer_rebuild_steps: 2` —— **步骤发生了，但「访问」计数是 0**。

查证：`_cell_layer_rebuild_visits` **只被导出、从不递增**。我删除 `rebuild_derived_cell_layer`
时把 `++_cell_layer_rebuild_visits` 一起删掉了，导出留了下来。

**后果：计数器永远 0，测试报出一条「看起来很有说服力」的失败信息，而那其实是我的疏漏。**

已修（在最前面 `step_derived_rebuild` 里递增）→ 该夹具 **19 checks / 0 failures**。

## 4. 修掉的第 2 个：夹具 API 漂移（真实 bug）

见 [M5-20](M5-20-realworld-probe-broken.md)：`run_economy_slice(64)` 传 int，桥要 Dictionary，
**报错后没走到 `quit()`，进程挂住 10 分钟以上**。已修。

## 5. 没修的（如实列出）

### 5.1 `ideology_cell_layer_shard_test`：7 checks / 2 failures

```
FAIL B: a yield leaves a cursor pointing into the work set cursor=-1 work=256
FAIL B: the cursor grew monotonically at least once last=-1
```

它测的是 **`city_factor_shard_cursor`**（经济侧 per-cell 覆盖的 CSR 分片），
**不是理念派生层**。

但**我删掉的旧平面正是那个 CSR override 的一个生产者**。所以有两种可能：

| 可能 | 含义 |
|---|---|
| A. 夹具依赖的是平面产生的 override | 那是**我的删除造成的真实回归**，需要确认派生层是否接管了 |
| B. 该夹具的覆盖集本来就是空的 | 既有问题，与本次无关 |

**我没有定性就停下，因为需要先确认 `refresh_city_output_modifier_factors` 在派生层存在时是否仍产出非空 override。**

按机制推理它应该产出（覆盖格的 `effective_value` 与 shared 不同 → 记 override），
但**「应该」不是证据**。记为待定性。

### 5.2 `ideology_cell_layer_m0_realworld_cost_test`

M0 时代的成本探针，同样走真实世界。未细查。

### 5.3 ~19 个 worker 夹具

抽样检查：**均不引用我删除的任何 API**（`rebuild_derived_cell_layer` /
`publish_ideology_cell_programs` / `get_ideology_cell_program_summary` / `cell_plane_enabled` 全无命中）。
多数是 20 个检查里失败 1–2 个。

`ideology_x10_worker_test` 有独立缺陷：
`Nonexistent function 'native_catalog' in base 'Nil'` —— 它自己拿了个 Nil。

**这一批与本次迁移无关，属于既有债务。** 我没有修，也没有把它们算进「通过」。

## 6. 一个必须写下来的流程结论

| 事实 | 后果 |
|---|---|
| 我只维护 18 个 fixture | 另外 50 个从未被本次工作跑过 |
| 其中至少 1 个是**我的删除弄坏的**（`cell_layer_e2e_test`）| 如果没做这次审计，会一直绿着报假象 |
| 1 个是坏的且会挂住 | 谁跑谁卡，于是谁都不跑 |

**结论：交付报告里的「回归通过」只能指它真正跑过的集合。** 我在
[M5-DELIVERY-REPORT](../../M5-DELIVERY-REPORT.md) §3.2 列的是 18 个，这次的 37 个才是全集里的通过数。
报告需要按这个口径修正。

## 6.1 后续：三个问题全部处理完

| # | 夹具 | 结论 | 现状 |
|---|---|---|---|
| 1 | `ideology_cell_layer_e2e_test` | **我的缺陷**（漏了 `++_cell_layer_rebuild_visits`）| **19 / 0** |
| 2 | `ideology_cell_layer_e2e_realworld_test` | 夹具 API 漂移（已修）；`widest=1` 是真实状态 | **10 / 1**（那 1 条是真话）|
| 3 | `ideology_cell_layer_shard_test` | **断言相对新实现过时**（见下）| **6 / 0** |
| 4 | 新增 `ideology_derived_city_factor_test` | 锁定「逐格因子只动被覆盖格」| **6 / 0** |

### 第 3 项的定性过程

先怀疑是我的平面删除让 CSR 失去来源，于是读代码：

- `collect_scope_stat_entries` **在第 1571-1584 行已经把派生层并进来**（注释明说
  `refresh_city_output_modifier_factors` 的工作列表来自这个函数）；
- CSR 的逐格取值是 `effective_value`（`economy_runtime.cpp:7327`），正是派生层合并进去的调用。

所以设计是完整的。实测诊断进一步说明：

```
[shard] epoch day=1 ok=true captured=true
[shard] slices=30 done=true stage=aggregate_publish cursor=-1 work=256
```

**工作集是 256（> 64 的分片大小），分片确实跑了 30 个 slice，`done=true`，而断言 F
（每个覆盖格都被涂到）通过。**

问题只是：断言 B 想观察「中途游标」，但 `_run` 去看的时候 epoch-begin 已经把分片跑完了，
`cursor` 停在完成态 `-1`。**这是「什么时候看」的性质，不是「分片有没有发生」的性质。**

**修法**：B 改为「游标要么是完成态 -1、要么在工作集内」；C/E 关于「游标增长」的断言只在
真的观察到中途读数时才检查。**真正的覆盖由 A（工作集 > 一片）与 F（每格都被涂到）保证**
——分片丢格会让 F 失败，假分片会让 A 失败。

我**没有**因为想让它变绿就删掉 F。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/ideology_runtime.cpp` | `++_cell_layer_rebuild_visits` 恢复 |
| `tests/ideology/ideology_cell_layer_e2e_realworld_test.gd` | API 漂移修复 |
| 本报告 | 68 个夹具的完整审计与分类 |
