# S22：年度读档继续态与边界

本文区分实测、源码核查和未覆盖范围。证据目录：`/tmp/keynes-arch-phase1/stage22/`。

## 真实年度分叉：五个根因

| 分叉 / 分类 | 定位证据 | 修复位置与约束 |
| --- | --- | --- |
| 就业人口不同，缺失继续态 | **不是槽位交换**：签名仍为13、17、28、26、44，21/20是人口数。`economy_runtime_building_employment.cpp:1270–1298`读取/写入职业移动冷却，保存日365存在cell247、source2、target3、until368。原保存遗漏它；`control-cooldown`控制实验消除了人口差异 | `economy_runtime_mobility_checkpoint.cpp:38,51,58`按原顺序保存/校验/恢复所有记录（包括已过期记录，不在保存时清理）；`economy_runtime_persistence.cpp:1970,2105`接入ECP2 |
| 人口修复后EMA等列仍丢失，恢复所有者错误 | `annual-v57`仍分叉；`annual-promotion`显示恢复公式留在`ner_local`，阻塞原因`pending_command_queue`。连续运行早已使用完整OwnedState，恢复后的年度奖励未来命令却挡住普通运行时晋升 | `economy_authority_transfer.cpp:50`及`native_simulation_host_startup.cpp:1064`仅在已恢复ECP2、ACTIVE经济、auto_pod_active条件下，执行线程启动前绑定恢复的所有者；不放宽普通运行时切换条件 |
| Events排序/Trigger重复接收，缺失传输游标 | 恢复把经济事实sequence和Trigger转发id/sequence置0；`annual-restored-owner`、`matrix-annual`保留先后两个失败。旧8192条事件以2048条/日重新转发，挤占真实新事件 | `native_simulation_host_persistence.cpp:308,946,1323`保存/恢复三个游标，`native_simulation_host_startup.cpp:455`安装；TPD1原有在途队列不变 |
| 本地入口ID与worker记录ID混淆，恢复重建问题 | journal含worker记录ID，但`next_event_id`属于入口；恢复取最大记录ID把独立入口计数232抬到758 | `world_ext_events.cpp:1384`保留显式存储的入口计数；只有不含该字段的旧形状才从记录推导。`runtime_event_restore_cursor_test.gd`4项验证，不改journal字节 |
| 第364日保存后漏发第365日天气观察，缺失发布门槛 | `weather-resume.log`恢复首日`_native_daily_last_result.rc=-1`，连续有0；`map_generator.gd:8766–8779`用该缓存决定WEATHER_OBSERVED是否发布。只将rc恢复为0的`weather-control.log`即八日无差异，未改天气值/事件比较 | `save_modules/geography_state.gd:42–52`保存并恢复原rc；`world_state_bindings.gd:18`提供小能力，environment provider升3；无旧版本默认值降级 |

S21“槽位重建/排序”只是当时假设，现已撤回；没有排序人口、排序摘要或改变就业公式。连续运行与黄金算法不变。

## 已运行的年度场景

| 场景 | 保存后比较 | 实测结果 | 耗时 |
| --- | --- | --- | --- |
| 真实365日年、年度自动保存日365 | 366–373，8日 | original/replay/checkpoint/resume均valid，first_difference=None | `matrix-annual-transport/matrix.json` 83.75秒 |
| 真实365日年、手动保存日364 | 365–372，8日 | 同上，天气继续态修复后全域一致 | `neighbors-weather-restored/matrix.json` 81.81秒 |
| 真实365日年、手动保存日366 | 367–374，8日 | 同上 | 同文件82.83秒 |

每项比较八个域、整体经济hash、军事快照、资源摘要；日历场景还比较季节/年/RNG，自动保存场景还比较年度报告。固定40×28、seed20260727、零士兵；不是所有地图/战争/全部保存点的证明。最终默认入口会再次运行365日场景，结果见migration。

## 格式与逐字节证据

- ECP2 **56→57**，OSOA仍3，新块10：u32数量，每条i32 cell/source/target及i64 until_day，20字节。严格校验后安装；旧ECP2明确报需要57。PKEC59及`economy_runtime.h`不改。
- PKSR **2→3**，原生产者游标之后追加三个64位游标，共24字节；旧版明确拒绝。各业务子段的独立ABI不变。
- environment保存provider **2→3**，在原字典追加`adapter_version=3`与`native_daily_weather_rc`；原生EnvironmentRuntime内层schema不变。旧provider或缺字段明确拒绝，不能静默恢复成-1。
- `save-byte-comparison.json`同种子/日/命令比较32个单元，28个逐字节相同；仅两份ECP2、PKSR头和environment改变。`save-inner-byte-proof.json`验证旧ECP2域、OSOA块1–9、旧environment字段均逐字节相同；头仅版本和新增24字节不同。不是只比hash。
- 新金样`tests/runtime/fixtures/climate_save_v9/day2.pksv`继续保留目录名；manifest明确各段版本。新块10、传输游标和environment即时重存相同。第2日冷却为空；另以第366日的10条非空冷却（204字节）验证即时重存逐字节相同，传输游标与environment也相同，恢复后八日仍无差异（`annual-roundtrip-proof.json`）；完整PKSV/ECP2的既存AUDIT/Modifier重编码差异不归一化。

## 其他年度量：源码核查范围

| 量 | 写入/权威证据 | 本轮结论 |
| --- | --- | --- |
| 基础湿度 | `world_runtime_host.gd:6026`调用`map_generator.gd:21348`年度漂移；season capture另写native+MapData；保存旧DCWorld副本是S21根因 | 沿用S21保存采样修复，不改live副本；年度场景Climate八日一致 |
| 年温度基线 | `map_generator.gd:15055`在绑定后按纬度原生烘焙，slot并回写MapData；`refresh_yearly`不写该列 | 没有独立年度重算入口；本例未发现同类分叉，不声称所有镜像时刻相同 |
| 植被与地形 | `refresh_yearly`只读取vegetation/biome history来改湿度，不创建职业、不直接重排人口；`refresh_seasonal:15074`只改季节与atlas脏标志；植被历史更新在`:12589,12751,12859`日/慢层路径 | 旧注释称季节/年度会重置地形不符合当前函数体；保留日/慢层实现，未改玩法。未全面证明全部历史数组的独立保存契约 |

## 在途保存与新读边

`inflight_save_boundary_test.gd`：真实Country资产事务begin后保存拒绝，prepared→commit→applied后允许；真实GameSaveCoordinator等待循环由测试观察序列驱动，前三次未发布、第四次就绪；终止故障立即拒绝。7项通过。它没有将真实worker冻结在任意Plan指令，也不宣称覆盖所有在途组合。

新读边为Economy已发布意见→Ideology、Ideology已提交发布→年度报告。`native_simulation_host_committed_views.cpp`从原不可变发布点复制，`runtime_published_view.h`携带generation/day，消费者断言版本不倒退。SHADOW原已完成意见选择不变；缺快照仍走原缺失路径。没有把Country计划预览误称为已提交快照。`view-negative-evidence.json`记录两条边各直接/别名/成员指针的6个真实源码反例全部exit1，删除反例后exit0。

宿主仅提取错误文本格式函数到已有`world_runtime_host_values.gd`，时间采样保留在host，公开方法不变，7036→7029行。冻结参照保留原文本与分支，99项固定输入对照通过；不是完成World owner全部抽取。perf-validation副本不动。

最终统一回归：改前49/49，改后52/52，exit0；默认内真实365日场景83.51秒并再次全域一致。核心3/3、外围2/2，两组独立运行均保持五链。护栏906文件、6视图、16项单测全绿。详见migration末尾。
