# Economy mirror / aggregate 调查

本次为源代码调用链调查，使用此前两轮60×40实测作为包围计时证据；没有新增探针、重编译或修改生产代码。沿用 cpp-dots-runtime-development、economy-runtime、runtime-architecture 和 hotloop skill 的权威与计时口径。

## 结论

第2、3项有共同成本：同一提交的多次兼容投影构造、完整扫描和哈希。当前证据能确认调用次数与数据流，不能把每个子步骤的毫秒数从已有包围计时反推出来。

120秒soak的52个每100日探针：formula avg/p95/max=7.303/8.828/10.068ms，stage合计5.688/7.227/8.119ms，mirror包围计时4.234/4.955/5.092ms。formula包含stage与prelude，stage包含aggregate，不能相加。mirror包围计时还包含Host最后的POD state_hash，不应解释成纯复制或纯导出耗时。

## 当前 ACTIVE_ONLY + StageOps + OwnedState 提交流程

1. native_simulation_host.cpp:1865 的 worker_run_stage_ops_slice 经Prelude、PlanEpoch、AdvanceStages执行13阶段。
2. economy_graph_stage_dispatch.cpp:245 的AGGREGATE_PUBLISH调用run_aggregate_publish_drain。后者在economy_runtime.cpp:19641连续排空publish_epoch_slice，并非只执行一个有界chunk。
3. aggregate完成后，dispatch:258调用第一次flush_formula_owned_domain_mirrors。
4. finish_ok（dispatch:11）对最终阶段调用NativeEconomyRuntime::state_hash；ACTIVE_ONLY仅省略中间阶段哈希，最终完整哈希仍执行。runtime_economy_pod.cpp:1069附近的run_bound_stage把以上全部包进stage_ms。
5. Host进入POD commit_epoch（runtime_economy_pod.cpp:1127），生成提交元数据、发布snapshot header，并在:1184执行commit_pending_commands。
6. Host检查NER committed_generation有更新后，再flush一次domain mirrors，然后publish_owned_committed_mirror（native_simulation_host.cpp:9119附近）。
7. publish_owned_committed_mirror（runtime_economy_pod.cpp:438）调用export_committed_ledger（:460），复制population/market/domain列到新ledger，执行valid，recompute_hash，再move到_committed_ledger_state。之前移除的第二份完整committed副本没有重新出现，但导出本身仍是完整复制。
8. Host在:9162附近重新计算RuntimeEconomyPodAuthority::state_hash，扫描population核心列和全market stock/price/demand/shortage，然后才结束mirror_ms计时。
9. Host在:9234附近还会再次drain pending commands；若此处有实际mutation，条件分支会再次flush/publish。该分支不应算进普通无命令路径的固定次数。

## 同一提交的重复工作

在两次flush均执行、building/trade/family已captured且content_hash非零的正常提交路径中：

| 操作 | building/trade/family各执行次数 | 代码依据 |
|---|---:|---|
| live domain → committed block复制 | 2 | economy_runtime.cpp:2398–2437；每次flush调用fill_ledger_* |
| block → 导出ledger复制 | 1 | runtime_economy_pod.cpp:493附近 |
| 内容哈希生成时append_wire | 2 | 两次flush中的recompute_content_hash |
| 导出valid重新append_wire并校验内容哈希 | 1 | runtime_economy_state.cpp:291、312、319 |
| ledger computed_hash重新append_wire | 1 | runtime_economy_state.cpp:373开始 |

因此每个上述domain至少4次wire序列化构造，不是4次完全相同的ledger hash。BuildingStore与FamilyStore的wire_content_hash都创建局部std::vector<uint8_t>，append_wire后再逐字节计算FNV；TradeEscrow同样如此。临时wire allocation与反复扫描是明确存在的工作，不需要猜测。

此外sync_owned_family_store（economy_runtime.cpp:2123）每次clear后遍历family、membership、ownership、person等重建投影；sync_owned_trade_escrow_store（:2061）重建订单投影。building live store已经同址，sync不必完整复制live，但fill_ledger_building_from_store仍复制committed block。不能把所有sync都说成同等大小的复制。

注意：export先clear ledger，所以valid时ledger_hash为0；这次valid会重新验证各domain content hash，但不会额外再算一次完整ledger computed_hash。随后recompute_hash才算完整ledger hash。publish_mirror_features只读形状/标签，不做完整校验；不是剩余热点。

## 两次刷新为何不能直接删

POD commit_epoch中的commit_pending_commands（runtime_economy_pod.cpp:1327）会调用_command_executor->apply，并记录mutated数量；这不是仅改receipt状态。命令可以改变资金、库存、人口或family等数据。首次投影位于此操作之前，第二次导出位于之后。

空命令队列下，这个间隙没有此处命令造成的domain修改，因此存在复用机会。但commit_epoch当前丢弃了commit_pending_commands的返回值，Host没有一个可证明“哪些domain自第一次投影以来未变”的标记。安全的合并需要传递mutation/domain revision，保留命令修改后的重建，并在失败/恢复/authority switch时正确失效。

还需区分三种hash：NativeEconomyRuntime最终stage hash覆盖NER完整公式状态（还调用Country state hash）；ledger hash覆盖传输账本结构和内容；POD state_hash仅扫描其定义的population/market核心列及身份。三者不等价，不能拿其中一个直接代替另外两个。

## 第3项真正包含的工作

aggregate内部publish_epoch_slice（economy_runtime_publish.cpp）包含：按策略完整/增量closing audit、watermark/交易计划、逐格commit、shortage/resource派生值、family effect metrics、社会/科技/国家facts、generation推进、drain_due_effect_pending_commands等。

这些之后还叠加第一次mirror刷新与native完整hash。此前末次aggregate=2.182ms只是单个快照，不能作为纯业务聚合的平均时间。PERSON_COMMIT=1.269ms、HOUSEHOLD_MARKET=0.861ms也是末次快照；没有全程逐stage分布，不能据此证明人物算法比消费算法更值得优化。

## 优化优先级与验证要求

1. 给aggregate增加互斥的publish_drain / first_mirror / native_hash子计时；给Host增加second_mirror / ledger_copy / shape-content_validation / ledger_hash / pod_core_hash计时，并同时记录calls、command mutations、vector元素/字节数。保持epoch快照及线程发布契约，避免只输出last slice造成误归因。
2. 在相同wire ABI下使用流式哈希或复用wire scratch，先去掉内容哈希中临时字节数组的分配与复制。ledger hash包含wire长度，必须保留原始字节顺序、长度混入和hash算法，不能用content_hash替代wire内容。
3. 通过明确domain mutation/revision复用无变化投影，优先消除空命令边界的重复flush；不要用“看起来没有命令”或毫秒时钟决定权威逻辑。
4. 只有拆分计时后仍然较重，才优化publish业务或person/household内核。不要降低审计频率或删最终hash来制造性能提升。

任何实现都需覆盖无命令与真实mutating command、StageOps/compact完整hash对拍、OwnedState切换、保存恢复、畸形ledger拒绝，再做同构建同seed重复soak。当前调查没有给出未经实测的预计节省毫秒数。
