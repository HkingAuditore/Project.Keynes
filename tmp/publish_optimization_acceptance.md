# Economy 发布优化验收（2026-09-20）

## 修改

- ACTIVE_ONLY 无待执行命令日移除一次重复 domain 投影；存在命令时移到 commit_epoch 执行命令之前，Host 最终刷新仍保留。
- building/family/trade 序列化与内容哈希、ledger wire哈希共用字段遍历。哈希直接流式读取字节，保持字节顺序、长度前缀及算法；不再分配临时wire数组。
- 最终账本导出复用私有双缓冲容量；完整valid与ledger hash成功后才交换published账本。reset释放scratch。增加一个账本容量的常驻内存（本地图仅market列约8.59 MiB），不增加权威副本。
- 新增每100日aggregate业务/最终native hash，以及ledger复制/验证/hash分段日志；不更改公式、schema、authority mask、cadence或校验强度。

## 正确性

Debug编译通过。最终POD自测8/0、30日StageOps/compact对拍190/0、阶段顺序18/0、M5/M6门禁22/0。POD自测包含已有存储roundtrip、畸形账本拒绝，以及新增连续缓冲交换、错误内容哈希拒绝后再成功发布。独立参考程序分别编译修改前/后的building/family/trade源码，12个空/零/非零/高位样本的序列化长度、内容哈希和ledger混入哈希完全一致。参考程序及构造脚本在tmp/publish_wire_test/、tmp/build_wire_reference.py；原始源备份在tmp/publish_optimization_originals/。未运行完整玩家保存后加载交互验收。

## 最终同构建重复soak

正式Stage C PlayerGame headless；Debug，60×40、seed1735228708、双大陆、6国、speed50、预热5秒，每轮60秒。自动POD使用玩家默认；年度自动存档保留。

|轮次|权威日|日/秒|最大提交间隔ms|worker fault|
|---|---:|---:|---:|---:|
|publish_final60_1|2683|44.622|763.436|0|
|publish_final60_2|2684|44.727|712.026|0|
|publish_final60_3|2630|43.827|796.497|0|
|publish_final60_4|2663|44.381|777.115|0|
|publish_final60_5|2696|44.929|719.097|0|

吞吐median=44.622日/秒，范围43.827–44.929。严格验收要求≥49日/秒且提交间隔≤1000ms；吞吐未达门槛，不能宣称50倍速验收通过。

各轮包围计时均值（每100日采样，不是全体日统计）：

|轮次|formula ms|mirror ms|ledger copy ms|worker日执行ms|
|---|---:|---:|---:|---:|
|publish_final60_1|6.859|3.006|0.494|13.751|
|publish_final60_2|6.857|2.959|0.493|13.768|
|publish_final60_3|7.934|3.181|0.575|15.327|
|publish_final60_4|7.584|3.041|0.501|14.788|
|publish_final60_5|6.661|2.843|0.425|13.352|

修改前120秒参考：formula avg/p95/max=7.303/8.828/10.068ms、mirror=4.234/4.955/5.092ms、worker日执行=15.419/17.715/20.479ms，吞吐43.660。旧60秒吞吐44.912。旧构建未重新跑5轮，因此不把两版吞吐差视为统计显著收益。确定性收益是无命令日少一次domain刷新、wire临时数组消除、导出容量复用。

中间版本（仅流式哈希和移除重复刷新、尚无scratch复用）120秒：复制平均1.124ms，mirror平均3.946ms。最终重复轮的复制降低与容量复用机制相符，但仍是墙钟样本。

完整avg/median/p95/p99/max及authority字段：tmp/publish_acceptance_summary.json。原始记录：tmp/publish_final60_1/至_5/中的session.json、perf.csv、frame_samples.csv和对应.log。最终Debug DLL SHA256：50BF96CDDEEC93576DD3840012F5CA78BC53F80F1DD17CF14046207F941CA03C。

此次只优化第2、3项。年度存档停顿仍存在，完整native/ledger/POD哈希与全量导出复制仍有剩余成本。保留所有校验，无GPU/FPS性能结论。
