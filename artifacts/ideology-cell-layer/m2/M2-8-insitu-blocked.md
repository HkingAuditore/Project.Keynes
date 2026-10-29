# M2-8 in-situ measurement attempt — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §14.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `tests/ideology/ideology_city_factor_insitu_test.gd`（可运行，**未通过**） |
| 结果 | **未能取得 in-situ 数据**；但排除了三个此前不确定的假设 |
| 结论 | 缺口确认，且这次的排除性证据比上次更具体 |

## 1. 目标

M2-6 的 38.4 ms 是「6400 格 × 156 查询 × 6.0 us」的**外推**，其中 6.0 us 来自 O2 微基准。§14.4 要求 in-situ 读数，而此前所有优化决策都缺这个输入。

本轮想用真实 `run_economy_slice` 测出三个量：`epoch_begin_city_factor_ms`、`city_factor_work_cells`、`modifier query_count_by_domain[ECONOMY]`，从中反推 us/覆盖格与 queries/覆盖格。

## 2. 实际得到的结果

```
[insitu] scale=32  modifier buckets=[0, 0, 32, 0]  economy_queries=4386
[insitu] scale=32:  no work set. stage=environment_snapshot done=true
                    epoch_ms=0.201 country_ms=0.000 shard_cursor=-1
[insitu] scale=128 stat_id=10 collect_scope_ids=128 cells
[insitu] scale=128 modifier buckets=[0, 0, 128, 0]  economy_queries=4386
```

## 3. 排除了三个假设（这是本轮的实质收获）

前几轮反复猜测「读者没跑」的原因，这次逐条证伪：

| 假设 | 证据 | 结论 |
|---|---|---|
| 「桶没建好」 | `bucket_count_by_domain = [0, 0, 32, 0]` / `[0, 0, 128, 0]` | **否**。GROUP 桶确实建成，数量正好等于提交数 |
| 「枚举看不到格」 | `collect_scope_ids(ECONOMY, GROUP, [stat_id])` 返回 **128 格** | **否**。M1-4 的并集工作正常 |
| 「读者完全没执行」 | `epoch_ms = 0.201`（非零）；`economy_queries = 4386`（非零） | **否**。读者执行过，查询发生过 |

**真正的原因在第 4 条。**

## 4. 决定性观察：两次测量的 queries 完全相同

```
scale=32   economy_queries = 4386
scale=128  economy_queries = 4386     ← 一模一样
```

若读者的工作量随覆盖格数变化，这两个数应当不同。**它们相同，说明这 4386 次查询发生在导入我的桶之前**——即 configure/bootstrap 阶段的那一次，之后 epoch 再没跑到读者。

配合 `stage = environment_snapshot`、`done = true`、`country_ms = 0.000`：

```cpp
// economy_runtime.cpp:4217-4220
if (needs_environment_capture(input.day)) {
    if (input.climate_u8[0].size() != count || ...) {
        error = "economy_environment_snapshot_invalid";
        return false;
    }
```

`run_economy_slice` 在环境快照阶段返回 `done=true`，`start_epoch` 从未进入 `capture_country_epoch`，因此读者**没有在一次真实 epoch 内运行过**。

**这是 M1-8 与 M1-13 记录的同一个前置条件，第三次以不同面貌出现。**

## 5. 为什么这次不能像 M1-13 那样绕过

M1-13 的结论是：`_epoch_cell_country` 只在 `capture_country_epoch` 里由 `copy_economy_snapshot` 填充。要让它有内容就必须真的打开 epoch，而打开 epoch 需要：

1. 9 个环境 DataCore 槽有 `cell_count` 尺寸的数据（**已证实可满足**，M1-12 实测 10/10）；
2. `MapData` 提供 `neighbor_indices_packed()` 且尺寸精确（手写 stub **会崩溃**，M1-8 实测 `0xC0000005`）；
3. 因此唯一可行路径是 `host.generate_world()` 生成真实 MapData；
4. 而真实世界的 worker 协作又带来 M0-7c 的 day-4 `money_conservation_failed`。

本轮再次确认：**这条链没有捷径**。

## 6. 我建议停止在 M2 内零散尝试

这是第 **三** 轮试图在裸 `SceneTree` 里打开真实 epoch（M1-8、M2-13、本轮），三次都停在同一个门槛的不同表现上。

继续尝试的边际收益在下降，而代价明确：每轮消耗大量时间在夹具脚手架，没有推进产品能力。

**建议把「worker + generate_world 协作夹具」单列为一项独立工作**，而不是继续在里程碑内部消化。方案 §14.3 已经写明它是 M1 的退出门槛之一，现在看它同时是 M2 的。

## 7. 当前 M2 的完整状态

| 能力 | 状态 | 证据 |
|---|---|---|
| 32 上限在**目标解析层**消失 | ✅ 完成 | `cap_removed_test.cpp` 12 checks |
| 内容 194 处不再写 32 | ✅ 完成 | 同上，直读 `.tres` 断言 |
| 两层校验按种类放宽 | ✅ 完成 | `ceiling_test` 19 / 35 checks |
| 成本结构（预算外推） | ✅ 完成 | `cap_cost_model_test.cpp` 28 checks |
| 快路径评估（决定不做） | ✅ 完成 | `cell_factor_fastpath_bench.cpp` |
| **in-situ 实测** | ❌ **阻塞** | 本轮，需 epoch 级夹具 |
| rollout ON | ❌ 未做 | 依赖 in-situ 验证 |

**目标解析层的限制确实消失了，这是本方案的核心目标。** 未完成的是性能验证与 ON 开关。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_city_factor_insitu_test.gd'
# => collect_scope_ids 返回 32/128 格；economy_queries 两次相同；
#    stage=environment_snapshot；city_factor_work_cells=0
```

排除性证据可从以下位置核对，无需运行：

| 结论 | 核对位置 |
|---|---|
| 读者在 capture_country_epoch 内计时 | `economy_runtime.cpp:5540-5542` |
| 环境门在 epoch 之前 | `economy_runtime.cpp:4217-4220` |
| collect_scope_ids 的派生并集 | `modifier_runtime.cpp:1506-1517` |
| 领土 CSR 只在 epoch 内填充 | `economy_runtime.cpp:4986` |
