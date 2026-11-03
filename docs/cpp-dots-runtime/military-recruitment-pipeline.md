# 军事征召链路（Military ↔ Economy 兵员转换）

> 2026-11-03 定稿。本文补充 [military-runtime.md](./military-runtime.md)：
> 那条文档记录 Military 自身的日阶段，本文记录**士兵从经济人口里来**的这一条跨域链路。
> 设计依据 `docs/plans/military-system-design.md` §5.1–§5.6；实现落在 B 方案（经济在自身日阶段内
> 按签名搬人）。

## 为什么不复用旧入口

Economy 有两条写入通道：

| 通道 | 整图 ACTIVE 下 |
| --- | --- |
| `submit_economy_commands` → `NativeEconomyRuntime::submit_commands` | 关闭，直接返回 `economy_legacy_ingress_disabled` |
| `submit_economy_pod_commands` → POD 队列 → `_command_executor->apply` → `apply_pod_command` | 可用 |

所以军事的结构性人口命令只能走 POD。**注意**：POD 队列里 `RuntimeEconomyOwnedState.structural_commands`
的导入路径（`apply_owned_mirror`）在当前模式下不会被调用，因此不要试图把 `CHANGE_SIGNATURE` 塞进
POD 结构队列——它会被"接受"然后永远不执行，且不报错。

## 链路

```text
MilitaryCore::run_recruitment        配额 = 兵额 - 在驻 - 待征；缺口 = 目标 - 士兵
  └ MILITARY_INTENT_ENLIST / _LEVY   count = 人头，source_id = 格
DCWorldExt::translate_military_intent
  ├ 解析源 cohort    military_cohort_handle_any_ethnicity(cell, unemployed | 可征召职业)
  ├ 解析目标签名      military_signature_for_cell_ethnicity(cell, soldier)   ← 由经济侧解析
  └ 发出 24 号命令    payload0=人头, payload1=源签名, target_country=目标签名, target_cell=格
POD 入口               opcode 24 必须位于准入范围（1..23 之外单独放行）
plan_day               _command_executor->apply → NativeEconomyRuntime::apply_pod_command
command_from_pod       车道映射：i32_0=target_cell, i32_1=target_country, i64_0=payload0, i64_1=payload1
apply_command          case COMMAND_MILITARY_CONVERT_COHORT
                       同一 store 内 find(源签名) / find-or-allocate(目标签名)，就地搬人，不跨格
回执 fold               POD 行（request_id == 0）在已提交日边界结算，
                       读回 military_soldier_heads(cell)，只入册经济真实持有的人数
MilitaryCore::reconcile_receipts   建驻防批次（命令里从不出现 slot id）
```

## 不改就会踩的坑（都真实发生过）

1. **不要把 cohort slot id 跨边界传。** POD 镜像与主运行时的 slot 编号不是同一空间，陈旧 slot 会静默空转
   或直接触发 `structural_target_invalid`。一律用 `(cell, signature)` 命名 cohort。
2. **签名 id 不是职业 id。** 目标签名必须用执行侧的表解析（`military_signature_for_cell_ethnicity`），
   否则人会被搬进别的职业：失业池下降、士兵 cohort 恒为 0。
3. **桥接行必须带 `row.count`。** 回执按 `min(实际, row.count)` 结算，漏赋值等于每次征召都判定"未执行"并退回。
4. **国家供给职业要豁免本地就业门槛。** 兵营是 Military 建筑，经济看不到"士兵岗位"：
   - `profession_available()` 检查要跳过 `state_service_only` 职业；
   - `non_unemployed_cohort_has_idle_population` 审计也要跳过，否则招到兵那一刻经济 fatal。
5. **转换必须走经济的结构提交路径，不要直接写人口。** 直接写 `population` 绕过了槽位/分页簿记，
   长跑到第 70 天会让 `validate_shape_and_values()` 失败（`economy_pod_ledger_shape_invalid`，
   整个 worker fatal、时钟暂停）。正确做法是压入 `_structural_commands`（`COMMAND_CHANGE_SIGNATURE`）。
6. **同一条转换命令会被执行两次**（POD plan 与 epoch drain 都会经过同一个 switch）。
   必须按 `sequence` 幂等去重，否则经济里会多出一批人（economy 15 vs military 12）。
7. **征召要"发令即预扣、回执补差"**，和退伍对称。只在回执时入册会让名册晚一天，配额持续开着，
   于是超额征召（economy 19 vs military 6）。回执只负责把"经济没搬走的人"从批次里扣回。
8. **名册对账不能裁掉在途征召。** 对账的裁剪上限是 `经济士兵 + pending_enlist`；否则刚预扣的批次当天就被裁掉，
   配额重开、再征一次，形成重复转换。
9. **经济读视图忙时 digest 会全是 0。** 对账必须要求该格 digest 带真实人口才参与，否则会把名册清零。
10. **军队专属命令可以不带国家。** `MilitaryCore::submit` 必须在 `country == 0` 闸门**之前**从部队归属国推导，
    否则地图层会收到 `command_missing_country`。
11. **不要给回执加"到期即视为已执行"的捷径。** 那会让军事名册虚增；必须读回经济真实人数。

## 验证

```powershell
# 全图验收（必须 0 failures）：兵营 → 征召 → 编队 → 宣战 → 移动 → 第 31 天地形刷新后存读档一致
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path Project/project-keynes -s res://tests/military/military_runtime_smoke_test.gd

# 活世界报告探针（只报告不断言）：每 5 天一行 JSON，第 40 天自动设目标并建 3 座兵营
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path Project/project-keynes -s res://tests/military/military_living_world_probe.gd -- --days=120
# 去掉 --headless 即可在运行中的游戏里做同样的观测

# 经济日是否真的在推进（怀疑"命令没落地"先跑这个）
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path Project/project-keynes -s res://tests/military/economy_day_progress_probe.gd
```

实测基线（v48，debug + release）：第 51 天兵营建成（12 兵额），第 60 天首都 `soldier=12`、失业池 0；
120 天全程名册与经济**逐点一致**（12/12、10/10、11/11、12/12），无 worker fault，`last_step_day` 推到 116；
全图 smoke `0 failures`；内核自测 0 失败；2,400 格基准 p95 0.26 ms。

名册对账（`reconcile_soldier_roster`）在此之上的两条硬规则：裁剪上限是 `经济士兵 + 在途征召`；
digest 必须带该格真实人口才参与（读视图忙时全 0）。合成自测要把 `enlist_by_cell` 发布成
`dg.cell_soldiers`，否则会把自己裁到 0。

## 已知未做

- 随军人口的**军事侧**未接：经济侧 `ArmyPersonnelStore`、opcode 30/31/32、客籍消费与 PKEC v59 lane 段已落地
  （见下节），但 `translate_military_intent` 尚未发这三条命令，部队移动时名册仍只搬批次账本。
- 口粮军供（§9.2）尚未按实物扣减，士气里口粮项读的是经济满足度。
- 征召的"从非商人雇员抽人"目前只按失业池；`levy` 分支的候选职业列表已接好但没有实际抽取测试。
- 100k 格压测 p95 约 18 ms（目标 2 ms），瓶颈是市场索引冷启动与消耗聚合。

## 随军人口车道（经济侧，2026-11-03）

契约 `docs/plans/army-personnel-implementation-contract.md` §1。士兵编入部队后不再占格内 cohort，人口与资金
进入 `ArmyPersonnelStore`（`gdext/src/runtime_economy_army_personnel.h/.cpp`），按 **army handle** 稠密成行。

```text
opcode 30 ARMY_EMBARK      payload0=人头 target_cohort=army target_cell=来源格 target_country=源 signature
opcode 31 ARMY_DISEMBARK   payload0=人头 target_cohort=army target_cell=目标格 target_country=目标 signature
opcode 32 ARMY_MERGE_LANES payload0=0    target_cohort=src army  payload1=dst army
POD 准入                   单独放行 30/31/32（与 24 同规格），其余仍限 1..23
apply_command              30/31 只压结构命令（STRUCTURAL_ARMY_EMBARK=1 / _DISEMBARK=2），
                           commit_structural 顶部派发到 commit_structural_army_lane：
                           人口与资金按比例搬（向下取整，余数留源），空 cohort 的余款走国库、释放槽位
32                         lane→lane，不碰 cohort，因此不需要结构命令
```

同样按 `sequence` 去重（POD plan + epoch drain 都会到同一个 switch）。守恒口径：lane 人口与资金计入
`audit_totals()` 的 `transit_population` / `escrow_cash`（`army_lane_population` / `army_lane_funds` 单独报告），
`audit_totals_from_shadow()` 每次重读，所以增量审计不需要按 lane 打点；只有 **lane 持仓在 epoch 内变化**时才强制
全量收尾审计。客籍消费在 `process_market_cell` 末尾（居民清算之后）跑 `run_army_personnel_consumption`：
只有本国所有 + 有活商人时才买 `soldier_household` 的**非军供需求**，军供需求按 `lane.ration_q16` 记账；
钱按商人人口比例分配（绝不多发），买不到就记 0 满足。

```powershell
# 只覆盖准入半（不需要新世界）：30/31/32 必须 Accepted，29/33 必须 RejectedAtAdmission
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path Project/project-keynes -s res://tests/military/army_personnel_lane_admission_test.gd
```

已知缺口：`set_military_army_ration(handle, q16)` 不搬 lane 的 `cell`，军事侧要同时发布位置时用三参重载
`set_military_army_ration(handle, q16, cell)`；"控制"只能由经济侧按格 owner 近似（controller 在 Military）。
家族子账与人物句柄的存储/合并路径已就绪，但编入/拆编目前不生成它们（契约 §3 允许）。

