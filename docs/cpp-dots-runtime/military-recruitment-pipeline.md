# 军事征召与随军人口链路（Military ↔ Economy）

> 2026-11-03 定稿。本文补充 [military-runtime.md](./military-runtime.md)：那份文档记录 Military 自身的
> 日阶段，本文记录**士兵从经济人口里来、并跟随部队移动**这两条跨域链路。
> 设计依据 `docs/plans/military-system-design.md` §5.1–§5.7；接口契约见
> `docs/plans/army-personnel-implementation-contract.md`。

## 1. 为什么不复用旧入口

Economy 有两条写入通道：

| 通道 | 整图 ACTIVE 下 |
| --- | --- |
| `submit_economy_commands` → `NativeEconomyRuntime::submit_commands` | 关闭，返回 `economy_legacy_ingress_disabled` |
| `submit_economy_pod_commands` → POD 队列 → `_command_executor->apply` → `apply_pod_command` | 可用 |

军事的结构性人口命令只能走 POD。注意：`RuntimeEconomyOwnedState.structural_commands` 的导入路径
（`apply_owned_mirror`）在本模式下不会被调用，所以**不要**把命令塞进 POD 结构队列——会被"接受"然后
永远不执行，且不报错。

## 2. 征召链路（士兵从平民来）

```text
MilitaryCore::run_recruitment        配额 = 兵额 - 在驻 - 待征；缺口 = 目标 - 士兵
  └ MILITARY_INTENT_ENLIST / _LEVY   count = 人头，source_id 打包 (cell, slot, requested)
     并发令即预扣（同 DISCHARGE），名册不落后于实际
DCWorldExt::translate_military_intent
  ├ 解析源 cohort    military_cohort_handle_any_ethnicity(cell, unemployed | 可征召职业)
  ├ 解析目标签名      military_signature_for_cell_ethnicity(cell, soldier)   ← 由经济侧解析
  └ 发出 24 号命令    payload0=人头, payload1=源签名, target_country=目标签名, target_cell=格
POD 入口               opcode 24 在准入白名单内
plan_day               _command_executor->apply → NativeEconomyRuntime::apply_pod_command
command_from_pod       车道映射：i32_0=target_cell, i32_1=target_country, i64_0=payload0, i64_1=payload1
apply_command          case COMMAND_MILITARY_CONVERT_COHORT
                       压入 _structural_commands（COMMAND_CHANGE_SIGNATURE），由经济自己的
                       结构提交执行——绝不直接写 population
回执 fold               POD 行（request_id == 0）在已提交日边界结算，读回
                       military_soldier_heads(cell)，只入册经济真实持有的人数
MilitaryCore::reconcile_receipts   短差从批次里扣回（与退伍对称）
MilitaryCore::reconcile_soldier_roster  每日按 digest.cell_soldiers 对账，
                       上限 = 经济士兵 + pending_enlist；digest 无该格人口时跳过
```

## 3. 随军人口车道（士兵跟着部队走）

四个经济 opcode，全部走 POD 车道，全部**按签名命名 cohort，不传 slot id**：

| opcode | 名称 | payload0 | payload1 | target_cohort | target_cell | target_country |
| --- | --- | --- | --- | --- | --- | --- |
| 30 | `ARMY_EMBARK` | 人数 | — | army handle | 来源格 | 源签名 |
| 31 | `ARMY_DISEMBARK` | 人数 | — | army handle | 目标格 | 目标签名 |
| 32 | `ARMY_MERGE_LANES` | — | dst army | src army | — | — |
| 33 | `ARMY_SPLIT_LANES` | 人数（≤0 = 整条） | dst army | src army | — | — |
| 34 | `ARMY_LANE_PAY` | 金额（MONEY_SCALE） | 国家句柄 | army handle | — | — |

- 30/31 在 `commit_structural` 顶部派发到 `commit_structural_army_lane`：人口与资金**按比例**移动，
  只从指定格取、只写指定格，源 cohort 清空时走已有的"空 cohort 余额归国库"路径。
- 32/33 是 lane→lane，不碰 cohort，因此不需要结构命令。34 只动国库与 lane 现金，同样不需要结构命令。
- 五者都按 `sequence` 幂等（POD plan 与 epoch drain 会到同一个 switch）。
- 守恒口径：lane 人口与资金计入 `audit_totals` 的 `army_lane_population/funds`；一旦 lane 在一个
  epoch 内变化，收尾审计强制走全量，且**跳过增量/全量对比**（增量影子读的是 lane 实时值）。

### 3.4 军饷跟着人走（opcode 34）

`MilitaryCore::run_wages_and_upkeep` 按**持有人**拆开军饷：

- `MILITARY_LOT_GARRISON` → `MILITARY_INTENT_PAY_WAGES`（国库 → 该格士兵 cohort，原路径不变）；
- `MILITARY_LOT_ARMY` → `MILITARY_INTENT_ARMY_PAY`（国库 → 该部队 lane），
  `count = 人头`、`amount = 人头 × 人均日薪`、`country_a = 国家句柄`、`source_id = army handle`。

人均日薪只有一处计算：`MilitaryCore::soldier_daily_wage`（`ABSOLUTE` = 政策值，
`AUTO` = 生存成本 × `MSTAT_WAGE`）。驻防与随军共用它，所以两边永远不会算出不同的值。

现金上限共用一个：驻防行先按格序排，随军行再拿剩下的，`planned` 合计进同一份
`pay_ratio_30_q16` / `spend_payroll_30`。日报里另有 `payroll_garrison` / `payroll_army`
两列（当日实际计划额，不入档、不参与哈希），用来分辨"今天到底谁拿了钱"。

回执：POD 行的 `count` 存**付款前 lane 资金**，结算时读 `military_army_funds(handle)`，
`applied = max(0, now - prev)` 再按请求金额截断。l一套账不能只看请求量：国库可能只付得出
一部分，而 lane 同日还会被客籍消费花掉，所以只有"涨了多少"才是真到账。

**worker 侧必须走 peer 路由**：`military_collect_cash()` 是同步的 reserve+collect，
整图 ACTIVE 下 Country 由 worker 独占，同步写被拒（`country_worker_unique_writer`），
lane 会永远收不到钱。所以 34 先走 `block_or_enqueue_country_worker_asset(
ECONOMY_ASSET_TREASURY_SPEND, …, target_handle=army)`，由 peer 结算后在
`apply_peer_asset_side_effects` 里给 lane 入账；只有 `NOT_APPLICABLE`（Country 仍是
同步持有者）才回退到 `military_collect_cash`。这条是最容易白忙的坑：行发了、报表有数字、
现金没动。

### 3.0 分兵与转移

- `army.split`：搬完 lot 后按**实际搬走的人头数**发 33（不是模板数），两支部队人口之和不变。
- `army.transfer`：源部队还留有 lot 时发 33（部分搬迁），整支部队走光时发 32。
- `army.merge`：32。
- 转移要求两支部队**同格**（`command_armies_not_colocated`）；分出去的部队先叫回来再测。
- 拆编/转移后，指向已销毁部队的批次必须在 `destroy_army` 里释放，`transfer_army_to_army` 也要把
  搬空的源批次置为非活跃；否则 PKMI 恢复时报 `pkmi_lot_army_missing`（地形季节刷新那条路径会踩到）。
- 车道有在途迁移时，名册会比经济多出"在途"那几个人，次日对齐；对账上限已包含 `pending_enlist`。

### 3.1 客籍消费

`run_army_personnel_consumption(market, result)` 在 `process_market_cell` 的居民清算之后运行：

- 只对「该格 owner == lane 所属国 且该格有活商人」的 lane 生效（controller 在 Military，经济只能近似
  用地块 owner）；
- 只用士兵消费计划里**非军供**的需求（`state_supplied_need_ids` 跳过）；
- 军供需求（staple_food / protein）的满足率取 `lane.ration_q16`，由 Military 每日
  `set_military_army_ration(handle, q16[, cell])` 发布；
- 扣减的市场库存与支付给商人的现金必须同时记入 `result.consumed_goods` 与 `result.revenue`。

### 3.2 按位置供粮

- 部队口粮从**部队自己持有的库存**消耗（`run_consumption` 的 army holder），行军途中照常。
- 满足率按部队发布给经济（不是按老家格），所以随军的人在前线饿肚子，老家的名册不会背锅。

## 3.3 海运运兵

依据设计 §7.4，水域**默认不可通行**，解锁后才能过：

| 科技 | 能力 |
| --- | --- |
| `tech.military.coastal_transport`（近海运兵） | 连续水格 ≤ 3，且出发/登陆必须是陆地 |
| `tech.military.naval_transport`（远洋运兵） | 取消连续水格上限（以近海为前提） |

- 门控读 `MilitaryCatalog.coastal_transport_bit / ocean_transport_bit`（由
  `MilitaryCatalogCompiler` 从科技 id 解析，默认 -1 = 未解锁），判定用 digest 的
  `country_unlock_bits`；两个位参与 catalog hash，改了就等于换目录（旧 PKMI 会被拒）。
- `find_path` 搜索 `(cell, 已过连续水格数)` 状态；`preview_path` 同样门控，天数按陆 1.0 / 水 1.5。
- 在海格上姿态强制 `EMBARKED`，登陆恢复；海上每日 0.2% 损耗，不计陆地恶劣环境减员，不参与陆战。
- 未解锁时 `find_path` 与 `preview_path` 必须拒绝水域（不得静默放行）。
- `MSTAT_NAVAL_TRANSPORT` 只影响海运消耗，不参与门控。

## 4. 车道踩过的坑（按发现顺序，全部真实发生过）

### 4.1 征召（详见 §2）

1. 把 cohort **slot id** 跨边界传 → POD 镜像与主运行时 slot 编号不同，静默空转或
   `structural_target_invalid`。一律用 `(cell, signature)`。
2. **签名 id ≠ 职业 id**；必须用执行侧的表解析，否则人会被搬进别的职业（失业池下降、士兵恒 0）。
3. 桥接行漏写 `row.count` → 回执按 `min(实际, 0)` 结算，每次都判"未执行"并退回。
4. 国家供给职业漏豁免 `profession_available()` 与 `non_unemployed_cohort_has_idle_population`
   → 招到兵那一刻经济 fatal。
5. **直接写人口数组**绕过经济账本 → 第 70 天 `economy_pod_ledger_shape_invalid`，worker fatal。
   必须走 `_structural_commands`。
6. 同一条转换命令被执行两次（POD plan + epoch drain）→ 经济多出人。按 `sequence` 去重。
7. 征召只在回执入册 → 名册晚一天、配额重开、超额征召。改为发令即预扣、回执补差。
8. 名册对账把在途征召裁掉 → 配额重开、重复转换。裁剪上限必须是 `经济士兵 + pending_enlist`。
9. 读视图忙时 digest 全 0 → 对账把名册清零。要求该格 digest 带真实人口才参与。

### 4.2 随军车道

1. **客籍消费必须把成交量记进 `result.consumed_goods`**：`audit_touch_market_lane()` 只让增量审计
   "看得见"库存变化，而 `goods_expected` 是按 `opening - _consumed_goods` 算的；只 touch 不记消耗，
   第一次编队就 `goods_conservation_failed`。卖出的收入同理要进 `result.revenue`。
2. **POD 命令在当日 publish 之后才 drain**：日边界（`_epoch_active == false`）把 30/31 只压进
   `_structural_commands` 要等到下一个 epoch 才提交，D+1 的编队要 D+2 才看得见（读回 `personnel=0`）。
   `queue_or_commit_army_lane()` 在 epoch 内走结构阶段，在 epoch 外直接执行同一个
   `commit_structural_army_lane`，并补 `_deferred_population_reconcile_cells`。
3. **`audit_totals_from_shadow()` 里的 `transit_population` 是"远征 + 车道"合计数**：远征差额原本直接
   减 `totals.transit_population`，车道有持仓时会多减一次、之后不再加回，增量人口比全量少一整个车道
   → 任何触发全量收尾的 epoch 都报 `incremental_audit_mismatch`。远征差额要减去
   `army_lane_population`，车道差额只加一次。
4. **EMBARK 回执读到 lane=0 不等于"没搬人"**：结构提交可能还在路上，按 0 结算会把真实编队记成失败。
   读到 0 保持 pending，等下一轮或回执超时；只有 lane>0 才按读回值结算。
5. **商人不变量的修补不能只看"最大 cohort"**：纯驻军格（部队在野外解散）里唯一的 cohort 是士兵，
   需要把 1 人转为商人，否则该格居民收入无主，结算直接
   `market_revenue_has_no_merchant_owner` fatal；转了则名册对账会把军方批次裁到经济实际持有数。
   所以拆编断言要看**该格总人口**，士兵数会少掉那个商人。

## 5. 验证

```powershell
# 全图验收（必须 0 failures）
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
  --headless --path Project/project-keynes -s res://tests/military/military_runtime_smoke_test.gd
# 覆盖：征召 → 编队（老家 cohort 减少、部队人口相等）→ 行军（人口不变、口粮下降）
#      → 拆编（人口回到目标格）→ 宣战 → 第 31 天地形刷新后存读档哈希一致

# 活世界报告探针（只报告不断言，每 5 天一行 JSON）
& "..." -s res://tests/military/military_living_world_probe.gd -- --days=120
# 去掉 --headless 即可在运行中的游戏里做同样的观测

# 经济日是否真的在推进（怀疑"命令没落地"先跑这个）
& "..." -s res://tests/military/economy_day_progress_probe.gd

# 随军车道探针
& "..." -s res://tests/military/army_personnel_probe.gd
```

实测基线（`dots_ext_army_v9`，debug + release）：
- smoke `0 failures`：`capital=0 before=9 embarked=9`、`personnel=9 headcount=9`、
  `march 9 -> 9`、`army.station` 拆编后 `population 0->9 (+9 of +9)`、无 push_error。
- 120 天活世界：`{"day":120,"errors":0,"halted":false}`，无 worker fault，`last_step_day` 推进到 116，
  名册与经济士兵逐点一致（12/12、10/10、11/11、12/12）。
- 内核自测通过；2,400 格基准 p95 ≈ 0.26 ms。

## 6. 已知未做

- 军饷现在按**人在的地方**发（§3.4）：驻防进格 cohort，随军进 lane（opcode 34）。
  worker 侧走同步 peer（prepare → service → finish 同一 epoch），**不要**改成
  `block_or_enqueue_country_worker_asset`：那条路把国库扣款与 lane 入账分到两个审计窗口，
  每个 epoch 收盘都会 `money_conservation_failed`。
- `MSTAT_NAVAL_TRANSPORT` 的消耗缩放尚未接入（只做了门控与 1.5 倍海运消耗）。
- 家族子账与重要人物句柄只做到"能存能并"，编成/拆编目前不生成它们，也没有家族效果联动。
- 没有海军单位、海战与封锁；海运只是"更贵的陆地移动力"，没有运兵船与航渡时间。
- 100k 格压测 p95 ≈ 18 ms（目标 2 ms），瓶颈是市场索引冷启动与消耗聚合。

## 7. 当前基线（`dots_ext_army_v11`，debug + release）

- 全图 smoke：**0 failures**（征召 → 编队 → 行军 → 拆编 → 分兵 → 部分/全部转移 → 宣战 →
  地形刷新后存读档一致）。
- 分兵守恒：`personnel 8+4 (baseline 12)`、`headcount 8+4 (baseline 12)`，分出的部队能独立行军且带人。
- 转移守恒：部分 `12 -> 12`、全部 `12 -> 12 (parent 12 detached 0)`。
- 内核自测：通过，含 39 条海运断言（无科技拒绝、近海 3 格可过 / 4 格不可、远洋 4 格可过、
  海路 6 天 vs 陆路 3 天、海上 `EMBARKED` 与登陆恢复、精确海运损耗）。
- 120 天活世界：`{"day":120,"errors":0,"halted":false}`，无 worker fault，名册与经济士兵逐点一致
  （采到的 13 vs 12 是当日 "在途"，次日对齐）。
