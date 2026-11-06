# R3：Resolve / Apply 已落地切片

本轮不重排阶段，不新建第二份请求队列，不改存档字节、军饷或维护费口径。R3最终批次（修复兼容债登记后）已完成：生产构建和财政 probe 构建均 exit 0；静态护栏全过（size 920 文件 0 违规；C++ 496 引用键/484 债务键、header_exposed=518、total=2210、Country direct writes=0；Resolve/Apply 3 队列/3 Apply 入口 0 违规；架构单测 24 项）。主链 runs=3、外部 runs=2 均 first_difference=None。默认回归 exit 0，耗时 807.05 秒；full 矩阵 7 场景 exit 0，410.73 秒；annual exit 0，83.58 秒；military-annual exit 0，91.41 秒。默认回归含 61 个日志项及保存续跑/矩阵/年度检查。

## 请求契约（M1）

`runtime_resolve_contract.h` 给现有所有者队列提供 ResolveFlow、ResolveOrder、ResolveResult、resolve_enqueue 和 resolve_find_receipt。Country/Trigger 的排序改为共享顺序键，字段次序与原比较器一致；Economy 保留接纳顺序与原回执重放优先级。共享契约不把各域不同的语义去重强行替换为一个全局 ID，也不复制 PKSR5 已保存的继续态。

| 请求流 | 产生 / 消费位置 | 原顺序与去重 | 保存位置 | 本轮 |
|---|---|---|---|---|
| Host 通用命令 | world_ext submit → Host enqueue_batch → 各域 | submit_order、producer/sequence；既有收件与回执 | PKSR5 pending_commands | 已登记，未改队列 |
| Country 命令 | Host/Country AI → Country plan_day | effective_day,sequence,submit_order,request_id；业务提交消费 pending | Country save | 接入共享入队与顺序键 |
| Economy 命令（含军事24/30–34） | Host/军事桥 → Economy commit_pending_commands | 原接纳顺序；先终态再普通回执按request_id重放 | PKSR economy_command_bytes (EQC1) | 接入共享入队/回执查找 |
| Trigger 命令 | Events/回执桥 → Trigger plan_day | day,producer,sequence,request_id；事件源游标；ACK合并 | TPD1 + PKSR TCQ1 | 接入共享入队与顺序键；ACK合并不变 |
| Country/Economy资产 | 各财政/采购端口 → Country/peer协调 | transaction/session/generation；prepared→commit→applied | Country资产journal + PKSR D7T1 | 现有端口保持，本轮清掉最后军事绕行 |
| Military 命令/征召/军饷 | Military日入口 → Economy/Country | 原军事序号、receipt cursor、next-day命令 | PKMI2、MILB3、MDJ1、EQC1 | 通过Economy接入；军事自身队列未迁移 |
| Effect → Modifier / Events | Effect计划 → Modifier/Events阶段 | instance/idempotency/transaction ACK | EFP1及各域存档 | 未迁移共享入队；已有确定性协议保留 |
| Ideology → Modifier | Ideology转换计划 → Modifier批次ACK | transition身份、目标generation | IPD/PKID与Modifier继续态 | 未迁移共享入队 |
| 同步 Effect 各外部批次 | Trigger/家族/运河等 → EffectRuntime | 原批次身份与事务协议 | 现有Effect保存 | 仅登记，未迁移 |

`resolve_apply_contracts.json` 登记现有 queue_command / submit_*command / enqueue_* 入口。新增这些形态的入口或已接入函数直接 push/emplace/insert 会失败。它不是全库任意命名 API 的语义分析；修改入口命名、别名传递或新类型仍需审查。结果/拒绝原因继续由原回执返回；共享 admission 不等于全日统一 Resolve 调度。

## Country 两处直接写（M2）

`military_collect_cash` 改为 `fiscal_return_port().resolve_cash(reserve_intent/collect_intent)`。Country 内部仍通过 `complete_economy_asset_compatibility` 执行 submit→prepared→commit→applied，每笔的原 epoch/stage=-1、ID和排序不变。最后两处旧 wrapper 原本就走同一事务协议，因此本次是将写权限收回所有者端口，不是改变维护费会计口径。`country_writes` 和例外表清空；直接调用、别名与成员指针均不得重引入。

## Apply 写集合（M3）

十二域写集合直接与 Host 现有模块描述符逐项比较，不改变执行顺序。对 Country::commit_day、Economy::commit_pending_commands、Military::reconcile_receipts 增加已审查成员访问集合、只读输入和已知跨域写调用检查。Country写snapshot/generation/pending/receipts；Economy写自己的命令与回执并调用既有executor；Military写lot、army pending与报告。catalog/terrain/bootstrap/authority mode不得在这些入口赋值。

这是入口级文本检查，覆盖新增成员、直接外国写调用及对应别名/方法指针反例；尚不是全调用树的C++别名分析，尤其既有executor和辅助函数内部写集合未逐一证明。不能声称已形成全域事务、失败回滚或完整Apply隔离。

## soft-complete（M4）

| 路径 | 结论 / 本轮处理 |
|---|---|
| Ideology invalid/shape invalid及任意opinion前缀 | 原来可算完成；现在不再软完成，记录停车原因 |
| Ideology首个意见快照/国家快照未发布、未配置 | 保留首次装配兼容债；不产生伪ACK，ready=false。未消除：需把启动时授权与首份快照登记共同迁移 |
| Trigger ACK barrier/retry/stale/rejected与未配置/未启动 | 原先在前序阶段发意图，后序Effect才产生ACK；保留明确列出的原策略及fallback原因，不制造新ACK。仍属于未消除的兼容债；拒绝与retry的后续统一政策未改 |
| Effect同日已提交重访 | 保留幂等重访及ACK重新交接；原来忽略drain/catchup错误还设ready，现遇错误停车，不宣布完成 |
| Country/Economy peer等待 | 现有stall、continuation_pending及超时故障保留；部分旧注释仍称soft，实际已不完成 |
| Modifier上游未授权、SHADOW/OFF/旧Web回退 | 按原授权策略保留；不是本轮退役范围 |

保留原因清单由护栏核对，新增软完成原因不能静默加入。**M4只完成收紧与盘点，没有消除所有soft-complete。**

## 游离文件（M5）

根因已由源码与定向测试确认：`native_simulation_day_support.cpp` 将 PK_SIM_DAY_TRACE 直接交给 fopen；`native_simulation_golden.cpp` 在同名后追加 `.continuation`。传入字符串 `1` 就会写到工作目录。现有日志不足以定位上一轮究竟哪条临时命令设置了这个值，不能指认某个已删除的启动脚本。

`runtime_switch_registry.cpp` 对四个文件型诊断开关拒绝相对路径。默认测试将开启的追踪重定向到当前绝对日志目录；黄金检查器也将日志路径resolve。`runtime_test_hygiene.py` 对每个Godot测试前后的git未跟踪集合取差，新增非源码文件会令测试失败；不删除现场文件。定向测试包括 `1`、相对目录、合法绝对路径及 `1.continuation` 的检测。

## 范围与后续

R3本轮完成的是可回放的切片，M1全域共同去重与M3全调用树隔离未完成，M4保留显式债务。R4仍负责宿主≤3000及全部C++日模块统一存档段；R2未做的Economy cpp/宿主/视图工作随R4。R5负责战争/多国/多种子、性能、旧路径清理与终稿。外围按日对齐与真实Web验证仍单列。29份规格/设计文档沿S20保留分级，不改玩法设计依据。
