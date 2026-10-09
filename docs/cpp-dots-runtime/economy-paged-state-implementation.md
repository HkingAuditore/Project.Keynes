# 分页经济状态实施记录

本记录对应完整 dirty 登记、提交视图、输入捕获及原生异步存档实施。
它记录实际接入范围，不能作为四项已完成或 50× 达标声明。

## 已接入的写入边界

- `RuntimeEconomyMarketStore` 的 stock、price、demand EMA、shortage 四列使用
  `EconomyTrackedColumn`；不存在可写 vector 转换、element 引用或 iterator。
- `RuntimeEconomyPopulationStore` 的 27 个 SoA 列使用同一接口；active count
  和 high-water slots 使用 `EconomyTrackedScalar`。
- 市场映射、市场数量及物资数量，资源库存、资源格子版本及尺寸元数据也已
  接入。资源格子版本的 Native 源与 OwnedState 投影仍需在最终字段目录中
  明确唯一权威来源，不能将两份物理存储当成两个业务字段。
- 建筑存储 79 列及 Native 角色权威 9 列接入登记。建筑 row 引用由共享
  write lease 管理；最后一份引用释放时登记，存活期间禁止结构变动。
- 家族身份、人物、分支影响力、远征身份及贸易订单的权威 SoA 已接入；
  相应 active count 与贸易 next id 也有独立绑定。贸易到达日桶仍是缓存。
- 远征路线等五个原始类型旁表使用自持有登记器的 `EconomyOwnedColumn`。
  七类家族／远征记录使用 `EconomyTrackedRecords`，通过明确字段 visitor
  更新规范字节列；不读取 padding，远征 payload 的 reserved_slot 不参与。
- scalar 相同值写入不登记；range guard 只登记实际改变的连续段；结构变动
  保留独立 revision。存档解码先读取普通标量，再通过登记入口安装。
- 并行任务仅写私有 `EconomyWorkerChanges`；协调线程按原任务顺序合并到
  对应领域，每份私有列表只遍历一次。没有每 lane 共享 revision 原子操作
  或共享哈希集合。
- 登记器包含可选的首次修改前值组件，独立审计 epoch 去重；worker 在
  修改前保留 preimage，协调线程保留稳定顺序。结构改变强制要求全量参考。
  此组件目前通过独立测试，尚未替换生产审计或启用新的审计快路。
- `ChangeRegistry` 提供 Hash、Audit、Publish 独立的页消费状态和批次水位。
  Hash 消费不会清掉审计及发布所需的登记。
- 财政事务以真实 request ID 登记稀疏 key；配置标量、命令、每日信号、
  cadence、环境量化列和持久化目录 ID 已有稳定绑定。行业维护周期数组也
  通过标量写入入口安装。仍需逐项区分权威、投影和临时数据。
- 家族可变记录、价格上限、运河项目和报价以连续计算行加独立不可变编码行
  保存。改单行长度不会重编码后续全部行。运河报价的活跃 token 索引也登记
  删除；已消费 token 不会留在下一版页目录。
- 稀疏 key stamp 在全部页消费者完成后按 touched key 回收；不扫描整个 key
  表。批次队列独立持有 key 列表，慢批次消费者不依赖已回收 stamp。

## 页目录及哈希

`EconomyPagedColumn` 是 v3 的不可变页目录组件：4 KiB 规范 little-endian
整数字节，类型、领域、列、块位置和有效长度明确；目录按 dirty 路径复制，
旧 root 保持有效。仅比较 dirty 页；实际改写后又恢复原值的页复用原页。
缺失新页登记、尾页长度错误或字段解释改变会拒绝更新。

`EconomyVersionedFieldTree` 使用持久化领域／列目录，单独组合日与 generation。
构建候选与已提交 root 分离；缺字段、重复字段或失败重试不能发布部分结果。
放弃构建后重新开始会清掉候选缓存并全量重建，覆盖 dirty 已被消费的情况。
字段类型／宽度／布局变更明确拒绝。稀疏全量参考从当前合法 key 重建，不保留
已删除旧 key。这仍是内部组件，不是生产 `EconomyCommitView`。

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
未登记新页、有符号／无符号解释、跨世界句柄拒绝及重叠写入的首次 preimage。
`economy_identity_change_test.cpp` 覆盖删除／slot 复用、generation、复制和
移动后的独立登记，以及贸易缓存不改变权威。`economy_record_change_test.cpp`
覆盖跨页记录、旧页不变、guard 存活时禁止结构修改、显式字段编码及临时字段
排除。上述独立测试通过。

人口、市场、资源、建筑、人物及家族身份接入的 POD 自检通过，后期 100 日
开启逐日全量审计及复算通过，固定 cadence 30 日对拍 190 项通过。
包括贸易、角色及元数据的 dirty14 构建完成后期 1,000 日回放，逐日全量
审计及哈希 oracle 均通过，三项守恒差为零。记录旁表的生产检查正在继续。
这些诊断运行的吞吐不能作为性能验收结果。

字段 inventory v3 目前列出 503 个稳定绑定，并补充 Native 私有列、标量和
持久化引用位置。`coverage_proven=false`；候选引用不是权威分类或覆盖证明。
检查入口为 `tools/runtime/Inspect-EconomyFieldCoverage.py`。
跨域引用、权威／投影去重及完整消费者覆盖仍在实施；
命令后统一提交、生产分页消费者、分层输入和原生异步存档仍未完成。
新字段目录和分页组件目前不作为权威存档内容。

2026-10-09：dirty26 长回放曾在约第 14 日发生 Windows C++ 异常退出，没有
正常结果，原因尚未确认。dirty28 从同一副本连续两次完成 1,000 日回放，
开启逐日完整审计及 v2 哈希复算，三项守恒差为零；不能因此宣称原异常已修复。
日志为 `tmp/four_parts_dirty28_1000.log` 和
`tmp/four_parts_dirty28_repeat_1000.log`。

dirty29 固定 cadence 对拍 190 项、0 失败；dirty30 运河回归 28 项、0 失败；
dirty31 Country/Economy transaction 回归 43 项、0 失败。独立页／记录／稀疏
目录测试包含失败重试、字段冲突、稀疏删除／复用及 10,000 次 key 周转后 stamp
和已确认批次归零。诊断构建为 debug，后期夹具仍为 60×40，不能作为正式性能
验收证据；100×64 release 和图形自动存档验收尚未执行。

dirty31 的 1,000 日逐日审计／v2 复算回放也通过，D7 gate 4 项、0 失败。
报告内存计数补充变长记录和财政／运河 key 编码缓存，避免遗漏缓存占用。

桥接报告读取增加临时并发保护：worker 拥有边界时返回私有缓存的深副本并
标记 `report_boundary_pending`，取得边界才读取 live 业务数组。bootstrap／恢复
建立缓存，configure 清理缓存。该路径尚不是命令后的分页提交报告，也不消除
取得边界后的完整 DETAIL 构建成本；旧异常的因果关系仍未证明。

dirty31 的 1,000 日逐日审计／v2 复算回放也通过，D7 gate 4 项、0 失败。报告内存计数补充变长记录和财政／运河 key 编码缓存，避免遗漏缓存占用。

桥接报告读取增加临时并发保护：worker 拥有边界时返回私有缓存的深副本并标记 `report_boundary_pending`，取得边界才读取 live 业务数组。bootstrap／恢复建立缓存，configure 清理缓存。该路径尚不是命令后的分页提交报告，也不消除取得边界后的完整 DETAIL 构建成本；旧异常的因果关系仍未证明。

dirty35 的 20 日回放通过，最终报告等待 263 ms 后拿到安全边界报告；无守恒差、无范围诊断。长回放仍需使用修复后的脚本重新运行。
