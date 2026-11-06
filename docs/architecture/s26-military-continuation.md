# R2：军事索引与年度继续态

本记录取代 J1/K1 的“保留全局过滤”结论。目标是读档忠实延续既有运行，不修改兵力、军饷或维护费规则。

## 三层分叉与证据

| 分叉 | 根因与对照 | 修复位置 |
| --- | --- | --- |
| day20 barracks present 4→1 | 连续 lot0 为 inactive、garrison/cell247/count3，cell head=0；PKMI1 只写 active 行，恢复把该槽位写成 location=-1/count0，再重建 active-only 链。`lot_find_or_create` 依赖原链找到该槽位，不能全局过滤。证据：`stage26/index-trace`、`l1-military` | `military_core_save.cpp` PKMI2 section22；直接安装原始链、槽位与空闲顺序 |
| day366 税务满意度 | PAGES 未保存 `epoch_in_kind_income`，恢复置0；`economy_runtime_satisfaction.cpp` 的 gross_income 分母读取它。保存时槽位132为87821。只增加这一列恢复后，八个业务域中的 Economy 首差消失，剩下 Trigger ACK 边界 | `economy_runtime_population_checkpoint.cpp`；ECP2 58→59，OSOA3 block12 |
| day366 Trigger 仍在364日 | 原运行保存点已收到 Trigger 计划的 ACK，但 Host 的 `_trigger_acks`、待发 intents 和 `_trigger_published_intent_id` 未保存；恢复再次遇到 ACK barrier。保留它们后 Trigger 逐日摘要一致 | `native_simulation_host_trigger_checkpoint.cpp`；PKSR4→5 的 TCQ1 |
| 整体经济哈希不同 | 临时逐输入比较把首差定位到财政记录请求ID：1459 vs 4996253404381577449，金额与操作相同。恢复用混有外部编号的最大 journal ID 推进 Host 自有编号。恢复必须保留实际 allocator cursor，而非推导最大值 | 同一 TCQ1 保存 `_command_request_id`，在启动末尾安装；哈希算法未改 |

证据位于 `/tmp/keynes-arch-phase1/stage26/`：`l2-pkmi2`、`l2-annual`、`l3-in-kind`、`in-kind-evidence.json`、`l3-transport`、`whole-pair2/journal-differences.json`。临时哈希和索引探针已删除；失败实验保留在临时目录，不作为通过证据。

### 额外军事事件继续态

最终严格场景进一步发现重复的旧宣战事件（source5/type40、tick=-1）。`MilitaryDailySystem` 的 `_event_cursor` 未保存，恢复后从0重读原生事件环。军事 provider 现在在自己的 pkmi 片段中追加 MDJ1：event_cursor、last_day、events_forwarded，各int64。因为 provider 恢复早于日任务创建，MilitaryFacade 只暂存这三项，任务构造时一次性交接；不移动装配顺序。缺少MDJ1明确拒绝。新增定向检查覆盖旧宣战只转发一次、先恢复后建job、非法值不改变当前游标。

## 原计数语义保留

`military_for_each_lot_ordered` 恢复原实现。inactive 行可在槽位复用前留在链上；不同调用方自行决定如何读取，变更型查找也必须看到它们。原连续 day20：驻军0、总兵力1、30日军饷141819。错误全局过滤曾使其变为3、4、158220，已经撤回，不能称为“去除幽灵兵力”。

PKMI2 保存各 lot 的完整 payload（包含 inactive）、free-list顺序、index_ok、army/cell heads、next、link kind/location，以及 army generation/free-list 和已接纳人员继续态。没有按当前人数补兵，没有改索引重建或遍历顺序。读档先校验长度、范围、空闲集合和无环链，再安装候选。旧 PKMI1 明确拒绝。

ECP2 block12 保存完整槽位顺序的 int64 实物收入累计列，先检查槽位数与已有 cohort 块一致。旧 ECP2≤58 明确拒绝。TCQ1 按固定小端字段保存发布游标、Host编号游标、待发请求及回执；PKSR≤4 明确拒绝。没有改变 CLM2、Country、Trigger authority 的格式。

## 新增字节字段

| 所有者/版本 | 新字段与编码 | 验证 |
| --- | --- | --- |
| Military / PKMI2 section22 | 各列 `u32 count + i64 lanes`；lot原始payload、free-list、next/link/head、army generation/free-list/待接纳列；index_ok为u8 | 限长、窄类型范围、空闲槽位集合、链归属与无环；临时候选全部通过后交换 |
| Economy / ECP2 59，OSOA3 block12 | `u32 slot_count + i64 epoch_in_kind_income[slot_count]` | 与既有cohort槽位数一致，不排序、不剔除inactive |
| Host / PKSR5 TCQ1 | magic、i64 published_intent_id、u64自有请求cursor、u32请求数+108字节/请求、u32回执数+53字节/ACK | 队列容量、长度、标识与枚举；验证阶段不安装，启动末尾安装 |
| 军事脚本provider / MDJ1 | u32 magic、i64 event_cursor/last_day/events_forwarded，共28字节 | 版本必需、游标非负（last_day允许-1）；恢复可早于任务创建 |

均按小端逐字段编码，不写C++结构体填充。CLM2仍为9、PKEC与其他模块格式未变；黄金算法未变。

## 验证边界

定向原生用例构造 inactive 链上复用行，逐字段比较 head/next/link、payload、free-list、army generation/待接纳状态；检查字节往返、旧版拒绝、环形链拒绝及失败不改原对象。默认入口为 `tests/runtime/military_index_continuation_test.gd`。

真实军事场景含非零兵力、军饷和战争。该夹具没有实际占领：命令准入不等于执行成功，观察到 army 仍在cell247、mission0、target=-1；`MCMD_ARMY_MOVE` 在未获得路径时直接返回。尚未证明该地图目标能到达，不能把战争存在当作占领通过。原生 military self-test 另有合成地图占领用例，覆盖范围不同。

最终实跑结果与耗时以 current-state 的 L1–L5 收尾记录及 `stage26/l-final-commands.json` 为准。

## 本轮已完成的验证

- 主链3次、外部2次通过，五条末日链不变；`l-final-golden` / `l-final-external`。
- 非零军事20日、365日保存续跑均四进程全域一致。最终full为9场景/36进程、409.9秒；普通annual4进程、83.2秒。新两个军事场景加入默认矩阵，约额外133秒。
- 年度保存/立即重存：index section22为74721字节、MDJ1为28字节、TCQ1为134字节（2个ACK、cursor1458）、population为1540字节、cadence48字节，全部精确相等。
- `l-annual-index-field-proof.json`保留完整头、next、active/location/payload、free-slot数组和逐字段比较；原始日20再次为驻军0/总兵力1/军饷141819。
- 32个业务比较单元28个不变。ECP2旧OSOA块1–10、其余15域payload及PKMI原section1–21完全相同；块11真实耗时跨进程可变，但从同一存档立即重存相同。

默认回归结果及本轮最终状态另见current-state文末，不能以上述专项替代默认回归。
