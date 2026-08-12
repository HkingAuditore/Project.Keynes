# 科技树、科技值与科研经济运行时

本文记录完整科技树的当前权威边界、数据契约、日结算顺序与存档版本。实现不包含独立
`TechnologyRuntime`。

## 权威边界

| 状态 | 唯一权威 |
| --- | --- |
| 科技领域、时代、节点、成本、前置、布局和效果引用 | `TechnologyCatalog` |
| 已揭示、已完成、待生效、稀疏进度、四领域队列、权重和采购政策 | `NativeCountryRuntime` |
| 科技值生产、市场库存、私人购买、国内贸易和国家采购 | `NativeEconomyRuntime` |
| 科技提供的数值效果 | Country domain `ModifierRuntime` |
| 科技界面显示和交互 | `TechnologyWorkspace`（全屏），只读快照；正式写操作经 `PlayerController.request_command()` 白名单网关提交 |
| 科技树静态几何 | `TechnologyTreeLayout` 纯函数，一次性烘焙 |

`EconomyCatalog` 只接受权威科技目录，并验证所有 `tech.*` 标签。科技 dense ID 采用目录
拓扑顺序；经济编译期把字符串标签解析成 dense ID，运行热循环不查找字符串。

唯一作者数据是 `data/technology/technology_network.json`。`TechnologyCatalog` 在冷启动时
严格解析该文件并继续作为编译与运行时唯一权威；旧的 `TECHNOLOGY_ROWS`、条件字典和按
`effect_profile + route_tags` 推断 Modifier 的路径不再参与目录生成。作者辅助脚本
`tools/build_technology_network_authoring.gd` 只用于确定性重建与校验 JSON，连续运行必须得到
相同 SHA-256。

## Research prerequisites and discovery signals (PKCN v11)

`ResearchSignalCatalog` is static content, not another runtime. It compiles stable signal IDs for
Bio, resource, landform, weather and breakthrough observations. `TechnologyCatalog` compiles
technology reveal conditions to postfix dense IR and includes that IR, the signal catalog, unique Effect
recipe identity and explicit Modifier term IR in the technology catalog identity. `EconomyCatalog`
adds the complete content-binding summary and Trigger definition identity before native country
configuration. `prerequisite_ids` is the sole research-eligibility gate.

The active reveal subset is `TECH_COMPLETED`, `SIGNAL_PRESENT`, `SIGNAL_COUNT`, `ALL_OF`, `ANY_OF`,
`AT_LEAST`, and `NOT`. Signal predicates only discover/reveal nodes. Missing hard prerequisites keep
the node non-researchable; signals cannot bypass them. Deferred domain points do not spill to another
domain, and `pending` activation does not re-evaluate a gate. `COUNTRY_FLAG`, statistics, buildings,
transient event sequences and `WITHIN_DAYS` remain unsupported authoring extensions.

Static signal discovery is country-local and is initiated only by a 0→1 explored-cell transition.
The first native generation pass builds Bio/landform CSR; after natural-resource reserves exist, a
second native pass appends every `resource.*` fact to the same sorted CSR. GDScript only assembles
the returned arrays. `NativeCountryRuntime` owns whether a country has observed them. Goods stock
never implies Bio discovery, and countries do not automatically share evidence.

河流、湖泊和湿地发布 `landform.freshwater_access`（“河湖水系”）地貌证据，供淡水捕鱼、
淘金、芦苇和水利路线的揭示条件使用。它不是 `ResourceProfile`，也没有储量、采集或商品
配方；实际可采集的水生自然资源只有 `freshwater_fish` 等明确资源条目。

Temporary weather is only a fact. Economy publishes sparse committed practice facts; PKTR v4
persists their threshold accumulation, and Effect issues idempotent `DISCOVER_COUNTRY_SIGNAL`
commands for permanent `breakthrough.*` evidence while retaining the first practice cell.

实践规则按有效生产日分层：留种等基础处理为 120 日；雨养适应、水田控制和梯田维护为
240 日，并要求相应气候/地貌经验；矿井支护、排水、炉温、印刷校准、蒸汽密封、电机绕组、
流水线和数字控制为 360 日。就业率与产能利用率会折算事实值，空建筑不能刷取突破。玉米
选育、长期旱作、水利、金属加工、印刷、蒸汽、电气、工业组织、自动化和气候建模还保留
各自更高的专项阈值。重复事件、重试和恢复都沿用 Trigger fire sequence 与 Effect command
idempotency key，不会重复发现。

网状目录补充航运运营、流域治理、林业经营、化工过程控制和能源控制五类 360 日实践事实。
它们复用同一个建筑实践掩码、提交事实、Trigger 累计、Effect 发现和 ACK 链；目录编译期解析
建筑 ID/科技标签，日结算只遍历已有稠密掩码，不增加字符串、Dictionary、国家持久状态或调度节点。

## 目录

当前目录包含 361 个定义：23 个只允许区域开局求解器授予的零成本原始处理节点，以及 338 个
可研究节点，覆盖 11 个时代和农业、工程、科学、社会四领域。不存在全球统一开局科技。每时代
里程碑严格使用 16 个本时代唯一候选中的任意 5 个；候选分组只用于 UI。里程碑不直接解锁
Good、Resource、建筑或生产方式，只执行时代奖励 Effect 并开放下一时代。

拓扑固定为四条跨时代骨干和十六条跨时代专业泳道。每条泳道每时代恰有一个路线锚点；非石器
专业锚点的硬前置是“上一时代里程碑 AND 上一时代同路线锚点”；骨干锚点以时代里程碑为硬
前置。实践、接触、资源和地理证据仅写入揭示条件，用来启发并显示科技，不能替代知识链。
当前目录有 462 条硬边、0 条替代研究边、505 条应用交汇边和 176 条里程碑候选边，总计
1,143 条静态可视边；节点硬入度上限 2。

区域开局处理科技也保留发现条件，用于说明其地理/资源来源，但仍只由区域开局求解器授予；
发现条件不改变其研究资格。芦苇、草皮、湿地、洪泛、旱作、水田、高地、河运与风力等节点
使用科技级精确证据，避免从宽泛路线继承无关信号。

`tech.early_trade`（“早期贸易”）是第 23 个零成本区域开局节点。它由出生地可见的天然金矿
或银矿揭示，解锁零建造成本的 `early_merchant_post`（“早期商栈”），并作为石器时代制度/
交换骨干的入口。每个正式新游戏国家都必须在本地路线闭包中获得该科技并预建一座早期商栈。

目录编译器为每项科技生成唯一 Effect recipe、唯一永久 Modifier definition、显式 Modifier
term CSR、路线标签、研究条件 postfix IR、prerequisite CSR、milestone-candidate CSR、反向
解锁索引和拓扑序。`EconomyCatalog` 另外生成科技到 Good/生产方式/Resource 的反向绑定 CSR，
并验证 132 个 Good、348 个生产方式、45 个职业和 31 个 Resource 均有合法科技标签，职业不得直接持有
`tech.*` 门槛。任一内容缺绑定、引用未知科技，或科技没有内容/Modifier/Effect 消费者都会
导致冷启动编译失败。

权威目录直接使用 361 项中文名称和中文效果摘要，`TechnologyCatalog.public_definitions()`
同时提供中文路线标签；玩家界面不显示内部 `tech.*`/`route.*` ID。稳定 ID、dense 顺序、
Effect/Trigger/经济绑定与这些目录文本共同参与精确 catalog identity，因此本轮不迁移旧目录存档。

内容解锁审计把单项科技的直接经济绑定限制在 4 项以内、建筑/生产方式绑定限制在 2 项以内；
里程碑直接绑定必须为 0。`BuildingProfile.technology_tags` 保持直接应用科技的 ANY 语义，
`required_technology_tags` 编译为全部满足的 ALL 支撑轴，原生建设、投资、生产和查询路径使用
同一判定。大气式
蒸汽机先解锁低产原型工坊，蒸汽动力再解锁通用蒸汽机工厂，蒸汽抽水单独解锁蒸汽矿井；
基础肥料加工与合成肥料、铜冶炼与青铜铸造、数字控制与自主系统均保持渐进职责。

本轮增加 11 个纯内容生产方式：蒸汽航运、自动化港口、自主航运、水力发电、流域治理、智能
水网、森林遥感、自主林业、高地精准农业、智能牧业和专用商品作物。它们只使用现有岗位、商品、
资源、配方、气候与 postfix 建设条件。自动化方法把对应普通岗位减少 20%-50%，同时把机械、
电力、计算、自治系统或科技值投入价值提高至少 15%；河流、森林、高地、牧场和种植园方法在
目标条件下的基础产出至少高于对照方法 20%，不满足条件时不可建设。

## 国家研究状态与日结算

PKCN v11 为每个国家保存：

- discovered/completed/pending 三个 bitset；
- 仅保存非零项的排序稀疏进度表；
- 四个固定领域、每领域最多八项的队列；
- 合计严格为 10,000 的四个 basis-point 权重；
- 自动采购开关、每日预算、暂缓库存与累计审计计数。

研究日使用整数最大余数法分配科技值。10 点在 70%/30% 下严格产生 7/3；领域内完成后的
溢出进入同领域下一项目。空队列或阻塞队列的份额进入 `deferred_unallocated_points`，
不会泄漏到其他领域；调整权重或向空领域入队后重新释放。移出队列不删除已投入进度。

完成节点先进入 pending。下一个国家日先用 `UNIQUE_SOURCE` 永久来源应用科技 Modifier，
成功后才设置完成标签；因此数值效果与经济解锁在同一日可见。GM “揭示全部未来科技”
只写 discovered bit。

## 科技值经济

`technology_points` 是可库存、可国内贸易的普通 Good，数量缩放使用 `GOODS_SCALE=1000`。
科研机构沿用工业建筑结算：真实就业和普通投入满足后生产，产出先进入当地市场并由商人
收购。现代技术知识家庭在教育文化 bundle 中少量消费；启蒙以后的指定产业把科技值列为
显式软投入，完全缺货只降低 5%–15% 产量。

经济周期的采购顺序为：

1. 建筑预留生产投入；
2. 家庭与企业完成私人购买；
3. `government_research_procurement` 按 `(price, cell_id)` 扫描国家属地剩余库存；
4. 国家现金减少、市场库存减少、当地商人按人口获得同额现金、国家商品国库增加；
5. 剩余库存再进入国内贸易。

采购受每日预算、国库现金、市场库存与队列剩余成本限制，并计入需求 EMA、价格形成及现金/
商品守恒。国家研究在下一日消费国库科技值，形成明确的一日经济边界延迟。v1 不允许跨国采购。

## Modifier 消费者

科技目录生成永久 Country definition，source type 为 `TECH`，source ID 为科技 dense ID + 1。
已接入消费者包括四领域研究效率、研究成本、科研机构产出、五类经济部门产出、施工成本/
时间、国内贸易容量/速度、全部 Building upgrade family 产出、按稳定建筑类型生成的精确产出
因子，以及旱灾、洪灾、寒冷和热害损失。Economy 在 epoch capture 一次性冻结国家×生产家族、
国家×建筑类型和四类气候适应 Q16 因子；生产热循环只读连续 POD，不查询字符串或
ModifierStore，也不会为每个建筑实例创建 Country Modifier。

当前 338 个可研究节点共显式定义 381 个 Modifier term，其中 43 个节点含小幅全国研究、贸易
或部门溢出，但每个这类节点同时拥有生产家族或精确建筑定向效果，不存在只有全国泛化效果的
科技。结构化内容摘要使用资源自身的中文名称，覆盖建筑、物资、阶层、资源、地块、地形、
地貌和气候条件，不向玩家显示内部稳定 ID。

Modifier 只改变配方结果、科技值到进度的转换、施工参数和贸易能力，不直接增删现金或商品。

## UI

`CountryPanel` 只是全屏 shell：一条 section 标题条加内容区，不再叠加国家档案、摘要卡或
section tab；section 切换只由底栏 `CountryActionBar` 驱动。经济 section 挂载只读
`EconomyWorkspace`，经 `CountryFacade.treasury_snapshot()` 展示国家现金与全部非零国库物资；
政治/军事/外交暂用统一 `SectionPlaceholderScreen`。科技 section 挂载全屏
`TechnologyWorkspace`：顶部 icon 化状态条、左侧研究方针栏、中央科技树、右侧详情卡。

工作区不持有 `CountryFacade`、玩家国家句柄或命令序列。权重、预算和队列操作只发出结构化玩家意图，由 `PlayerController` 解析正式会话、分配下一日生效日与单调 sequence，再委托 `NativeCountryRuntime`。

科技树是单个自绘 `TechnologyTreeView`，不再使用 `GraphEdit`，也不为 361 个节点创建子节点。
几何由纯函数 `TechnologyTreeLayout` 一次性烘焙：以主要路线泳道组织全局 DAG、时代分带、
同层重心排序、里程碑居中并终结所在时代、三次贝塞尔连线采样点和边包围盒缓存。硬前置、
替代证据、应用交汇和里程碑候选四类关系使用不同线型；16 条候选边只在焦点相关时显示。节点和边执行视口裁剪，
视口外内容不逐帧完整重绘。

迷雾按「已揭示集合 ∪ 其直接未知后继」裁剪：未触达节点不绘制、不进包围盒，可平移范围
等于可见集包围盒，最深可见时代下方以虚线与「未知时代」封口，因此玩家看不到科技总数或
剩余时代数。未知前沿只画暗轮廓与 `?` 角标，不显示名称、成本、效果。hover 或选中节点会
高亮完整前置链与直接后继链，无关连线降到 10% 不透明度，前后置关系由树形本身表达。

视图永远 1:1 绘制，没有缩放：滚轮上下平移时代栈，`Shift` 或横向滚轮左右平移，左键拖背景
自由平移；已经装得下的轴向固定居中，因此树不会被滚出屏幕。

所有政策控件改完即生效，界面上没有任何提交按钮：`ResearchWeightDial` 是四轴菱形雷达盘，
抓取区是整条轴臂（轴线两侧各 26px），不是顶点小圆点——权重接近均衡时四个顶点会挤在圆心
附近，逐个瞄准必然误触；圆心 18px 是无主死区，斜向空隙不响应。拖动按「按下点到当前点的
径向位移」做相对调整，因此误点不会让权重跳变，按下未移动则一条命令都不发。拖动一轴时其余
三域按原比例缩放，最大余数法保证 `sum == 10000`，松手提交一次 `SET_RESEARCH_WEIGHTS`，
双击圆心恢复各 25%。半径按份额的平方根映射（`DISPLAY_GAMMA=0.5`）：线性半径会让 25%
基准下四个顶点全叠在圆心针脚上，而这正是盘面绝大多数时间的状态，开方后 25% 落在半径一半
处的黄铜「均衡圈」上，刻度圈 25/50/75/100% 随之向外收窄；拖动在绘制空间里做相对位移，
所以顶点仍然逐像素跟手，畸变对手感不可见。盘面只在轴端画领域 icon，百分比由「研究队列」表头常驻显示并随拖动
实时更新，当前操作的轴臂旁再浮一枚读数标签；`ProcurementBudgetSlider` 以「国库百分比/日」
为量纲，最左端即关闭，实时预览每日上限与可支撑天数，松手提交 `SET_RESEARCH_BUDGET`。
队列排序完全依赖拖放，队列行只有 icon 化状态、进度微条与移出按钮。

日 tick 只走 `TechnologyWorkspace.refresh_research()`：`patch_states` 更新状态数组并
`queue_redraw()`，队列行仅在队列构成签名变化时重建，详情卡仅在选中项或相关状态变化时
重建前后置行。已揭示节点显示路线标签、当前阻塞谓词、证据数量、首次发现日和第一证据格；
未知节点仍不读取或显示名称、效果、前置、路线或辅助文字。

已揭示科技的名称、效果摘要、路线徽章、前置科技名称和发现证据均显示中文；内部稳定 ID 只用于
索引与命令提交。未揭示前置仍显示为“未知科技”，不会通过条件详情泄露名称。

## 启动、存档与兼容性

- `NewGameConfig v3` 保存外国数量、起始国家现金、每日科研采购预算、四领域权重和自动采购开关；
  v2 迁移时外国数量为 0。
- PKCN v11 保存完整研究/信号状态，并把科技与研究信号、揭示条件 IR、Effect recipe/Modifier term IR、
  Trigger 定义摘要和全部内容绑定摘要混入 catalog identity。
- PKEF v9 保存 Effect program hash、实例、事务/ACK 和时代奖励冻结计划；PKTR v4 保存突破
  阈值累计、来源游标和未派发效果。
- PKEC v34 保存采购累计、科技值市场/在途状态、实践发布所需的经济权威与联合审计基线。
- PKSV 恢复顺序保持 PKCN 在 PKEC 之前。
- PKCN/PKEF/PKTR 的旧 schema 或任何相关 catalog identity 变化统一返回
  `catalog_hash_mismatch`，不做 ID 映射、默认补齐或静默迁移。

## 聚焦验证

- 分布排查工具：`tools/export_technology_tree.gd`（headless 运行）生成 Civ 式交互报告页
  `tools/technology_tree/technology_tree_report.html`。报告直接消费 `public_visual_edges()`，
  区分硬前置、替代说明、应用交汇和里程碑候选，并展示结构化内容效果与机会成本；
  `-- --check` 只读模式用于拒绝陈旧 HTML/Markdown，详见该目录 README。
- `technology_catalog_test.gd`
- `technology_network_design_test.gd`
- `technology_content_binding_audit_test.gd`
- `technology_research_runtime_test.gd`
- `technology_breakthrough_trigger_test.gd`
- `technology_procurement_runtime_test.gd`
- `technology_modifier_activation_test.gd`
- `technology_workspace_smoke_test.gd`
- `country_runtime_test.gd`
- `economy_rolling_runtime_test.gd`
- `economy_trade_runtime_test.gd`

## Effect Runtime 接入

科技研究、发现、前置条件和完成位仍归 `NativeCountryRuntime` 所有。完成
科技后，原生运行时建立稳定的 `(country_handle, technology_dense_id)`
Effect instance；其专属 recipe 至少生成永久 `technology.modifier` 和
`technology.adopted` 事件，必要的 Country/Economy 命令与它们共享一个事务。Modifier
definition key 和 term IR 继续由科技目录编译，未在 Effect 目录中复制数值配置。PKCN
仍只保存科技权威状态，PKEF v9 保存 Effect instance/transaction；所有要求的 adapter ACK
到齐之前，pending 位不会转成 completed。
