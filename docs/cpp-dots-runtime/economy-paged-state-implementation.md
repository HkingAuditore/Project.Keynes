# 分页经济状态实施记录

本记录对应完整 dirty 登记、提交视图、输入捕获及原生异步存档实施。
它记录实际接入范围，不能作为四项已完成或 50× 达标声明。

## 已接入的写入边界

- `RuntimeEconomyMarketStore` 的 stock、price、demand EMA、shortage 四列使用
  `EconomyTrackedColumn`；不存在可写 vector 转换、element 引用或 iterator。
- `RuntimeEconomyPopulationStore` 的 27 个 SoA 列使用同一接口；active count
  和 high-water slots 使用 `EconomyTrackedScalar`。
- scalar 相同值写入不登记；range guard 只登记实际改变的连续段；结构变动
  保留独立 revision。存档解码先读取普通标量，再通过登记入口安装。
- 并行任务仅写私有 `EconomyWorkerChanges`；协调线程按原任务顺序合并到
  对应领域。没有每 lane 共享 revision 原子操作或共享哈希集合。
- `ChangeRegistry` 提供 Hash、Audit、Publish 独立的页消费状态和批次水位。
  Hash 消费不会清掉审计及发布所需的登记。

## 页目录及哈希

`EconomyPagedColumn` 是 v3 的不可变页目录组件：4 KiB 规范 little-endian
整数字节，类型、领域、列、块位置和有效长度明确；目录按 dirty 路径复制，
旧 root 保持有效。仅比较 dirty 页；实际改写后又恢复原值的页复用原页。
缺失新页登记、尾页长度错误或字段解释改变会拒绝更新。

生产哈希仍为 v2，完整 v3 字段覆盖和格式升级尚未安装。v2 市场缓存现在
通过 tracked revision 和 Hash 消费页更新：共享 Native/POD 缓存的重复查询
不比较全表字节；只比较实际 dirty 页。初始化、shape 改变或未共享的观察者
执行完整重建。`PK_ECONOMY_HASH_VERIFY=1` 仍对照全量参考，包括缓存直接命中。

## 证据和未完成项

优化前 debug/release DLL 与源差异保留在 `tmp/four_parts_baseline`。
静态 inventory 初版列出 440 个 store 列、92 个旧哈希 member 依赖、119 个
store 依赖和 550 个写入候选。它是检查清单，不是已完成覆盖证明。

独立 `economy_paged_state_test.cpp` 覆盖同值写入、跨页、500 次随机扩容／
删除／重排、旧页保留、慢消费者水位、私有并行写入、v2 增量／重建对照、
未登记新页以及有符号／无符号解释。人口和市场接入的 POD 自检通过，后期
100 日开启逐日全量审计及复算通过，固定 cadence 30 日对拍 190 项通过。
这些诊断运行的吞吐不能作为性能验收结果。

建筑、人物、家族、贸易、远征、资源、配置／命令和跨域引用的完整接入仍在
实施；命令后统一提交、生产分页消费者、分层输入和原生异步存档仍未完成。
新字段目录和分页组件目前不作为权威存档内容。
