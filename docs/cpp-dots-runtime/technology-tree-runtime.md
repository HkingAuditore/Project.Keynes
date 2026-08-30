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
technology reveal conditions and the unified research condition (hard prerequisites,
milestone candidates, alternative authored routes, and previous-era entry only on
era-milestone nodes) to postfix dense IR and
includes that IR, the signal catalog, unique Effect recipe identity and explicit Modifier term IR in
the technology catalog identity. `EconomyCatalog` adds the complete content-binding summary and
Trigger definition identity before native country configuration. Research eligibility is evaluated as:
the compiled unified research condition (hard prerequisites or milestone candidate
threshold, any authored alternative route, and previous-era milestone **only for
era-milestone nodes**). Player, AI and low-level enqueue commands share this native
check.

The active reveal subset is `TECH_COMPLETED`, `SIGNAL_PRESENT`, `SIGNAL_COUNT`, `ALL_OF`, `ANY_OF`,
`AT_LEAST`, and `NOT`. Signal predicates only discover/reveal nodes. Missing hard prerequisites keep
the node non-researchable; signals cannot bypass them. Deferred domain points do not spill to another
domain, and `pending` activation does not re-evaluate a gate. `COUNTRY_FLAG`, statistics, buildings,
transient event sequences and `WITHIN_DAYS` remain unsupported authoring extensions.

Static signal discovery is country-local. A 0→1 explored-cell transition submits landform/resource
CSR plus the cell's **current** `bio.*` occupancy bits. Occupancy 0→1 on an already-explored cell
submits `DISCOVER` again. Local extinction does not delete country evidence. The first native
generation pass builds landform CSR only; after natural-resource reserves exist, `run_bio_seed_pass`
writes `cell.bio_occupancy_bits` (carrier-gated origin stands filling the
origin landmass envelope; vacant habitat-class niches packed on other continents;
cosmopolitan reed may
span continents; continent-scale landmasses keep a food + fiber/livestock floor; satellite
islets skipped unless they are the unique argmax). A later native
pass appends every `resource.*` fact to the same sorted CSR. GDScript only assembles the returned
arrays. `NativeCountryRuntime` owns whether a country has observed them. Goods stock and cross-border
trade never imply Bio occupancy; trade still yields `contact.*` knowledge only. Agricultural
production of mapped goods can introduce occupancy on the producing cell if the climate envelope and
carrier reserve still hold.

Inspector 认矿与科技树揭示分开：可见格（含无主地）只按观察者国家**已掌握**科技的
`discovery_technology_tags` 列出储量；开局视野证据可以揭示石器时代节点，但不会因此把邻格
写成「尚未配置自然资源类型」，也不会用已揭示未完成的识别科技打开对应矿种。开局视野里的
铜矿储量只揭示自然铜辨识；自然铜辨识、自然铜冷锤、铜退火、锡矿辨识与铜矿焙烧均从
农耕时代开始。自然铜冷锤在本时代提供可用铜，浅层锡矿与土法炼锡炉提供锡，铜锡配比与
露天青铜作坊由此在农耕时代形成第一条完整青铜工具闭环；王国时代的青铜工具工坊负责规模化。
稳定 ID 为 `tech.copper_metallurgy` 的“木炭坩埚炼铜”是探索时代的高温扩产方法，不再承担
青铜时代的首条铜供给。帝国铜矿和蒸汽浅层铜矿是后续采掘升级，不会反向阻塞早期用铜。打制石器、
土建筑、野生块茎挖掘、野生韧皮采集、芦苇收割和粗陶淘金同样先要求本对象辨识，目击只
揭示辨识节点。块茎保存、野生香料采集、野生割胶和手制陶器也先要求本对象辨识（陶器还
要求黏土调制）。
亚麻/香料/橡胶辨识不再挂在后续处理上；铁矿与露头煤辨识以农耕时代门为硬前置，不再要求
先炼铁或先拣铁。非石器专业科技硬前置已经没有数量槽位或入度上限；时代入口只作为**时代里程碑节点**的研究门槛
（`entry_milestone_id` / `technology_entry_milestone_indices`），不再注入普通节点的研究 IR。
已揭示且硬前置与路线完成的下一时代科技可以在不完成上一时代里程碑的情况下入队。块炼铁、地表用煤等复合节点可以同时保留
材料、燃料、炉温、测量与组织基础。棉花园圃以定居知识和野生棉铃采集为硬前置，不再要求
先完成香料栽培。同泳道按 layout 串起来的无关对象也已拆开：棉花去籽挂棉铃采集，乳胶烟熏
挂橡胶加工，乳品/鞣革/毛用畜牧/屠宰并行挂畜群管理，玻璃挂窑烧，垄作块茎挂块茎保存，
煤矿平硐挂地表煤采集，佃作谷物挂留种选育。捕鱼、枯枝采集、火种控制和季节历仍不挂辨识。

河流、湖泊和湿地发布 `landform.freshwater_access`（“河湖水系”）地貌证据，供淡水捕鱼、
淘金、芦苇和水利路线的揭示条件使用。它不是 `ResourceProfile`，也没有储量、采集或商品
配方；实际可采集的水生自然资源只有 `freshwater_fish` 等明确资源条目。

Temporary weather is only a fact. Economy publishes sparse committed practice facts; PKTR v5
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

当前 schema v3 目录包含 671 个稳定 ID 的定义：7 个只允许区域开局求解器授予的零成本生存核心
处理节点，以及 664 个可研究节点，覆盖 11 个时代和农业、工程、科学、社会四领域。不存在全球
统一开局科技。各时代里程碑候选数依次为 `8/9/10/11/12/13/14/15/16/17/18`，达标数依次为
`4/4/4/4/5/5/5/6/6/7/7`；候选分组只用于 UI。里程碑不直接解锁 Good、Resource、建筑或
生产方式，只执行时代奖励 Effect，并作为下一时代里程碑的研究门槛。普通节点的研发不再被该门槛挡住。

拓扑由四条公共主干与 24 个动态主题家族组成，不再要求每个家族每时代占一个槽位。揭示条件、核心知识硬边、
里程碑候选阈值与替代路线统一编译为一条研究条件 IR；上一时代里程碑只编译进时代里程碑节点，不再成为普通节点的研究门槛。实践、接触、资源
和地理证据负责揭示问题，路线内的 `ANY_OF` / `AT_LEAST` 负责不同解决能力，不能冒充核心知识。
当前目录有 2321 条硬边、648 条研究路线包、670 条替代可视边、19 条应用交汇边、7 条显式分支边和
143 条里程碑候选边；没有
authoring-side `research_condition`。王国时代以后的主干、制度和生产系统节点通常保留两到三条
类型不同的路线；不可替代知识已由可见硬前置完整表达时可以明确豁免，不得保留被硬前置传递闭包
完全蕴含的伪路线。研究路线可以引用同代已经完成的科技，但不得自引用或引用未来时代；最大硬入度只是当前
内容结果，运行时和 schema 均不设置上限。显式应用关系独立保存，
不再从数组相邻项或同车道自动生成。

区域开局只完成生存核心：`tech.gathering`、`tech.hunting`、`tech.early_trade`、金淘或银拣、
`tech.deadwood_collection`，寒冷另加 `tech.hide_scraping`。知识机构不作为第八项开局科技，也不
直接预建：开局求解器统一揭示 `tech.early_knowledge_institution`，并根据海岸、洪泛平原、
牧场/草原、森林或一般生存观察生成五条替代研究路线。国库只预存该科技的 3000 作者点科技值，
并按 `early_knowledge_institution` 配方预存建材；科技完成后才解锁待建知识机构并开始产出科技点。
五个区域知识科技保留为后续分支，不再各自解锁建筑。沿岸捕鱼与淡水捕鱼均以统一知识机构为入口；
渔舟移至农耕时代，并以完成二者任一项作为显式替代路线。辨识节点维持有成本、
需目击/储量信号，开局不赠送。芦苇、草皮、湿地、洪泛、旱作、水田、高地、河运与风力等节点
使用科技级精确证据，避免从宽泛路线继承无关信号。国内水运能力由四个硬编码科技门控，不走
Modifier、也不另开 capability 子系统：`tech.river_transport` 开河运与湖泊，
`tech.celestial_navigation` 开浅海（探索时代才开海；`tech.fishing_boats` 只解锁渔舟生产建筑，
不开放航区），
`tech.oceanic_navigation` 开远海，`tech.oceanic_ship_design` 开深海。海事等级嵌套，河运独立。
`node_role == identification` 的 18 个
辨识节点只允许本对象目击/储量、对应 `contact.*`，或目录用来定义该对象的栖息地（芦苇保留
沼泽与河湖，砂金保留河湖）；种植园容量、跨物种/跨矿种第三条和 `breakthrough.*` 不得作为
辨识启发。王国铁矿、王国露头煤和启蒙煤层地质仍把上一时代里程碑包在 `ALL_OF` 外层。
采集、沤麻、冷锤、地表采矿等处理节点不再继承辨识的第三条代理证据；纤维捻制/织造仍可
同时看见亚麻与棉花，但沤麻只认亚麻。铁矿与煤炭拆开；高炉冶炼由铁矿、煤炭和金属加工
揭示，不再误用皮革词元 `fur`。航海揭示去掉渔获代理，物流不再共用海事三元组。
处理与生产节点不得把地貌/承载力写成对象目击的 `ANY_OF` 旁路：羊毛毡制只认羊，狩猎只认
野生动物，韧皮采集只认亚麻/韧皮，毛用畜牧只认羊，乳品只认牛。芦苇与砂金辨识仍可用目录
定义的栖息地。跨国贸易实际送达 `bast_fiber` 时发布 `contact.bast_fiber`，可作为亚麻与韧皮辨识及
纤维捻制的实物证据；仅存在贸易路线或远方库存不会揭示。开局求解器不再预建韧皮衣物；寒冷路线
授予刮皮并预建生皮刮制棚，暖地不预建衣着。
通用采集与狩猎不依赖辨识，辨识只控制地图与 Inspector 是否点名；对象专属的第一处理
（打制石器、土建筑、块茎挖掘、韧皮采集、芦苇收割、粗陶淘金、银矿拣采以及玉米/麦/稻/
棉/香料/橡胶/铜等既有链）必须先完成辨识才能研究。
开局建筑的开工门只看生产/产出/资源科技。出生点由 `StartLocationProfile` 把木材补到保底，
因此生存核心授予并预建一座 `deadwood_gathering_camp`；土坑、芦苇、草皮、毛石、韧皮仍是
知识门槛后的可研发 leftover，其采集营零建材即可立营。其它建筑仍用这些货物作建造配方。
帝国制度不再共用「印刷 + 校准 + 航运」：农奴/庄园走土地与留种，行会走工艺实践，活字/大学走印刷，
航海商社才保留航运。原子与信息科学不再共用「自动化 + 稀土」：核裂变走电气与化工控制，
运筹学走工业组织，计算节点走数字控制，气候/遥感走气候建模。电气动力不再共用绕组与流水线：
电动机保留绕组，电网/发电走电气化本身，质量控制走流水线。王国文字、手稿和官僚用黏土与木材，
皮纸用兽皮，不再继承石器时代的季风/霜冻/河谷兜底。

`tech.early_trade`（“早期贸易”）是生存核心开局包中的贸易节点。它由出生地可见的天然金矿
或银矿揭示，解锁零建造成本的 `early_merchant_post`（“早期商栈”），并作为石器时代制度/
交换骨干的入口。每个正式新游戏国家都必须在本地路线闭包中获得该科技并预建一座早期商栈。

目录编译器为每项科技生成唯一 Effect recipe、唯一永久 Modifier definition、显式 Modifier
term CSR、路线标签、每路线独立 postfix IR 与总 `ANY_OF`、prerequisite CSR、milestone-candidate CSR、反向
解锁索引和拓扑序。`EconomyCatalog` 另外生成科技到 Good/生产方式/Resource 的反向绑定 CSR，
并验证 130 个 Good、351 个生产方式、45 个职业和 31 个 Resource 均有合法科技标签，职业不得直接持有
`tech.*` 门槛。任一内容缺绑定、引用未知科技，或科技没有内容/Modifier/Effect 消费者都会
导致冷启动编译失败。

每个节点都携带作者侧 `knowledge_basis`：`required_ids` 必须位于硬前置传递闭包，
`alternative_groups` 必须由可见研究路线表达，`exemption_reason` 只允许开局科技、时代里程碑和
纯观察辨识节点使用。该字段编译为 `technology_knowledge_basis_json` 并参与目录身份哈希，不新增
国家运行时状态、研究谓词或存档字段。

权威目录直接使用 671 项中文名称和中文效果摘要，`TechnologyCatalog.public_definitions()`
同时提供中文路线标签；玩家界面不显示内部 `tech.*`/`route.*` ID。稳定 ID、dense 顺序、
Effect/Trigger/经济绑定与这些目录文本共同参与精确 catalog identity，因此本轮不迁移旧目录存档；
旧目录存档明确返回 `catalog_hash_mismatch`。

内容解锁审计验证每项绑定存在且确有消费者。当前 351 项活动建筑都恰好保留一个可见的直接
`tech.*` 标签，`required_technology_tags` 必须为空；多项知识汇合时由显式应用科技吸收硬前置，
再由该应用科技单独解锁一栋建筑。目录包含 298 个至少汇合两项真实知识的 application anchor，
另有 11 个单一知识递进的普通 `tech.method.*` 方法节点；单前置的纯延迟 application 已删除。
科技详情因此可以展示全部真实建筑效果，不再依赖隐藏复合绑定名单。里程碑直接建筑绑定仍必须为 0。数值效果必须显式填写
作用类别、机制说明与原生消费者；生成器不得按名称、家族、首个建筑或数组位置补 Modifier。同一科技
不得解锁并立即固定加成同一物资、建筑、方法或自然资源。大气式
蒸汽机先解锁低产原型工坊，蒸汽动力再解锁通用蒸汽机工厂，蒸汽抽水单独解锁蒸汽矿井；
热力学不解锁新建筑，而是降低全社会生产链的动力煤投入；实验科学作为后续科学与研究机构的知识
消费者，不再借用造纸业填空。谷物脱粒显式作用于通用谷物、小麦、稻谷和玉米四种商品，不再把
“大田作物农业”家族当作伪商品。地产/租佃制度不再只加玉米庄园；其价值由庄园、稻作与种植园的
生产方法、岗位和后续土地制度共同消费。基础肥料加工与合成肥料、铜冶炼与青铜铸造、数字控制与
自主系统均保持“发明—扩散—标准化—规模化”的渐进职责。

数值层同时允许四种尺度：全社会产出/投入/居民消费，精确物资产出/投入/消费，自然资源回采与
经营性恢复，以及 `terrain|landform × sector` 地理适应。目录当前显式审查产生 358 条数值 term：
245 条社会/部门影响、53 条精确物资产出、9 条精确物资投入、5 条居民物资消费、16 条自然资源
影响和 30 条地理×产业影响。没有数值 term 的科技仍可通过解锁、硬前置、替代入口、标签或应用边
成为真实内容消费者；完成流程不得等待不存在的 Modifier ACK。

建筑解锁按时代分布严格为 `15/17/20/24/28/32/36/40/44/46/49`，其中帝国时代及以后占
299/351。石器时代固定包含狩猎营、采集地、早期商栈、砂金采集、枯枝采集、生皮刮制、统一知识机构、
公共火塘、燧石采石场、石器打制工坊、采石场、淡水捕鱼、沿岸捕鱼、野生韧皮纤维营地和韧皮裹衣棚
共 15 项；露天银采移出石器时代。完成打制石器后直接解锁燧石采石场和石器打制工坊并可实际生产
打制石器；野生韧皮采集先提供韧皮纤维与采集营，纤维捻制再消费该知识并解锁基础衣物与韧皮裹衣棚。
狩猎营在 committed economy cycle 实际产出生皮后，通过既有
`Economy → technology.practice.hide_working → Trigger → Effect → Country` 路径授予永久
`breakthrough.hide_working` 证据；它与野生动物目击二选一揭示生皮刮制。狩猎营与生皮刮制棚施工
均只使用原木，不再反向依赖尚未解锁的韧皮纤维。石器狩猎营每劳动日副产 `110` 生皮子单位，使一座营地
在中性衣着需求下约能支撑 15 人的生皮衣物链；刮制棚仍按实际生皮库存部分开工，不凭空生成衣物。
农耕时代为
17 项，后续时代缓慢递增，避免把石器时代压力平移到农耕时代，且建筑解锁主体位于帝国时代以后。

Good 的 `tech.*` 标签是生产许可，不再只是可见性标签：每个 Good 的标签集合必须精确等于全部
实际生产者的直接科技集合，每个标签都必须有同科技直接解锁的活动生产者。
目录测试从七项开局科技和预建产出开始，对每个首次解锁商品的硬前置闭包做固定点推演；替代知识入口
逐路线单独推演。建筑只有在科技、建材候选、必需投入候选和资源辨识全部满足后才算可运行。首个生产者
不得依赖自己的首次产出；同投入同产出只有在硬前置闭包内已有更早生产者时才合法。`required_q16 <= 0`
的软投入仍会形成市场需求，但不会编译为隐藏科技门。操作闭包与包含建材的施工闭包分别守门；开局预建
建筑的建材组只在施工闭包中豁免。跨目录产业审计还要求每种实际产出 Good 都有居民、生产、建设或
硬编码运行时消费渠道，且首个有效需求最晚不超过首产出一个时代；每项非辨识知识也必须在本时代或
下一时代进入解锁、Modifier 或硬编码运行时消费者。远洋船舶、铁路设备等资本品进入后续船运、港口、
铁路、钢铁、油井和矿山升级的建设清单，避免只生产不投资。生成器使用同一供给拓扑分配时代名额，
连续运行两次必须保持网络、建筑、商品资源及组合 SHA-256 不变。

本轮增加 11 个纯内容生产方式：蒸汽航运、自动化港口、自主航运、水力发电、流域治理、智能
水网、森林遥感、自主林业、高地精准农业、智能牧业和专用商品作物。每项生产方式只绑定自己的
显式应用科技；例如蒸汽航运应用科技硬前置吸收蒸汽密封、远洋航海、蒸汽动力与海岸船厂知识，
再单独解锁蒸汽船坞。它们只使用现有岗位、商品、
资源、配方、气候与 postfix 建设条件。自动化方法把对应普通岗位减少 20%-50%，同时把机械、
电力、计算、自治系统或科技值投入价值提高至少 15%；河流、森林、高地、牧场和种植园方法在
目标条件下的基础产出至少高于对照方法 20%，不满足条件时不可建设。

## 发展成就与连续资格

`DevelopmentAchievementCatalog` 是静态目录，不拥有独立运行时。它定义稳定
`development.*` 信号、时代、目标文案、指标类型、主体、阈值与持续日数。Economy 在现有
实践事实扫描中按国家聚合人口、聚落等级、建筑装机/活跃规模、产业就业与产出、人口加权满意度
以及贸易量、基础价值、订单、商品和伙伴数；只遍历活跃聚落、建筑组和贸易聚合行。

提交事实使用 `EVENT_COUNTRY_DEVELOPMENT_METRIC = 17` 与
`PAYLOAD_COUNTRY_DEVELOPMENT_V1 = 10`。Trigger protocol v3 的
`CONSECUTIVE_DURATION` 每个提交日最多推进一次，跌破阈值清零，同日重复不累计，采样日空洞
重新起算。达标后沿 Effect/Country ACK 路径授予永久 `development.*` 信号；Economy 不直接
写国家研究状态。科技 UI 只查询当前最高开放时代的中性目标和进度，并在选中科技时分别解释
核心知识与每个研究条件分支，未知科技不会泄露名称、效果或条件细节。

## 国家研究状态与日结算

PKCN v11 为每个国家保存：

- discovered/completed/pending 三个 bitset；
- 仅保存非零项的排序稀疏进度表；
- 四个固定领域、每领域最多八项的队列；
- 合计严格为 10,000 的四个 basis-point 权重；
- 自动采购开关、每日预算、暂缓库存与累计审计计数。

研究日使用整数最大余数法分配科技值。10 点在 70%/30% 下严格产生 7/3；领域内完成后的
溢出进入同领域下一项目。阻塞队列（队列头无法推进）的剩余份额进入
`deferred_unallocated_points`，不会泄漏到其他领域。空队列的份额留在国库，后续研究日
按当时权重再分配——否则默认 25/25/25/25 会在第一天后把剩余库存全部锁死，必须把某
一方向拉满才能继续累积。调整权重或入队后会释放已暂缓库存。移出队列不删除已投入进度。

完成节点先进入 pending，并在同一研究日登记稳定 Effect instance。生产调度里
`effect_runtime`（priority 85）早于 `country_daily`（255），若等到下一个国家激活循环
才 upsert，当天 Effect 已经跑完，ACK 会对不上，节点会一直停在待生效。国家 slice 在
Effect 仍有到期工作时会升起 `country_day_barrier`（研究日结束后 `country_should_run`
已为假），让 continuation **循环**抽干 Effect→Modifier→gameplay ACK。Trigger/Ideology
的 `should_run` 不算硬 ACK，不能单独钉死日历。经济 epoch 仍在进行时，即使硬 ACK
尚未空闲也要继续 catchup；硬 ACK 仍到期但经济已抽干时，放下 `country_day_barrier`，
让下一渲染帧能进入下一个国家日。下一个国家日先确认 Effect 事务已 ACK，或确认该科技的 `UNIQUE_SOURCE`
Modifier 已经落地；若 instance 仍未 ACK，则在该国家日直接套用同一 UNIQUE_SOURCE
（幂等替换），避免漏掉 Effect 早晨、抽干一轮不够、或 Effect 跨日切片卡死时永远待生效。
研究分配本身仍严格按国家日执行一次；但同一国家日的 continuation 允许再次进入
`run_research_day`，只处理已经 ACK 的 `pending` 激活，不重复消耗科技值或推进研究进度。
因此单项队列在达到成本后不会因为没有下一项或没有新的入队命令而停留在“研发中”。
已登记但未 ACK 的 instance 每个国家日会被重新排入 Effect 队列。GM “揭示全部未来科技”只写 discovered bit。

## 科技值经济

`technology_points` 是可库存、可国内贸易的普通 Good，数量缩放使用 `GOODS_SCALE=1000`。
科研机构沿用工业建筑结算：真实就业和普通投入满足后生产，产出先进入当地市场并由商人
收购。开局五座观察建筑仍是两人传知者作坊、无日常原料，但按路线分化：口述记忆圈日产
`1000` 且无地理/气候门；物候观察棚日产 `1500` 并走 `phenology_observation` 气候；牧群
议事帐日产 `1600`，要求本地 `pasture` 承载力并用草皮建造；潮汐观察屋/洪水历法祭所分别
日产 `1700`/`1800`，优先消耗芦苇，祭所还要求 `paddy_land`。它们不进
`research_institution` 升级族，只吃知识部门产出因子。现代技术知识家庭在教育文化 bundle
中少量消费；启蒙以后的指定产业把科技值列为
显式软投入，完全缺货只降低 5%–15% 产量。

经济周期的采购顺序为：

1. 建筑预留生产投入；
2. 家庭与企业完成私人购买；
3. `government_research_procurement` 按 `(price, cell_id)` 扫描国家属地剩余库存；只向
   `population > 0` 的活商人付款。家庭人口结算可以当场把商人 cohort 清零，但
   `STRUCTURAL_REMOVE_EMPTY` 与商人修复要等到结构提交之后才发生，因此过期 CSR
   巷不是做市商：该市场本周期跳过采购，不扣国库、不把整张经济图打成 FATAL。
4. 国家现金减少、市场库存减少、当地活商人按人口获得同额现金、国家商品国库增加；
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

Modifier 不再是非开局科技的强制模板；当前有 90 个可研究节点采用纯解锁/纯内容效果，空
Modifier key 不发送 Modifier 命令、不等待 Modifier ACK，但仍发送 `technology.adopted`。
数值效果只保留给已有建筑、方法或领域消费者，专业路线用真实投入、岗位、配方、地理与制度差异
形成 build 身份。作者合计上限为家族/建筑
+400%、全国部门/研究/贸易 +400%；目录把家族/建筑/五部门/贸易钳在 `[0, 8]`，四领域研究
效率 `[0, 6]`，气候损失 `[0.20, 1]`，建设成本/时间 `[0.40, 4]`。不存在只有全国泛化效果的科技。
结构化内容摘要使用资源自身的中文名称，覆盖建筑、物资、阶层、资源、地块、地形、
地貌和气候条件，不向玩家显示内部稳定 ID。

Modifier 只改变配方结果、科技值到进度的转换、施工参数和贸易能力，不直接增删现金或商品。

## UI

`CountryPanel` 只是全屏 shell：一条 section 标题条加内容区，不再叠加国家档案、摘要卡或
section tab；section 切换只由底栏 `CountryActionBar` 驱动。经济 section 挂载只读
`EconomyWorkspace`，经 `CountryFacade.treasury_snapshot()` 展示国家现金与全部非零国库物资；
政治/军事/外交暂用统一 `SectionPlaceholderScreen`。科技 section 挂载全屏
`TechnologyWorkspace`：顶部状态条与紧凑导航工具栏，中央为聚焦研究/网络总览二选一视图，
左侧 280px 研究管理栏与右侧 320px 科技详情均为常驻列并参与中央树排版；窄屏分别收至
220/260px。右栏内容在固定宽度内换行并纵向滚动，不允许横向裁切。四大研究领域画在同一张
聚焦图上，各自占用一条随中央画布均分的垂直泳道；顶栏不再用领域 Tab 切树。搜索框保持
紧凑固定宽度，工具栏剩余空间由 Spacer 吸收。

工作区不持有 `CountryFacade`、玩家国家句柄或命令序列。权重、预算和队列操作只发出结构化玩家意图，由 `PlayerController` 解析正式会话、分配下一日生效日与单调 sequence，再委托 `NativeCountryRuntime`。

完整 DAG 仍由 `TechnologyTreeLayout.build()` 一次性烘焙，供详情关系、目录审计与迷雾计算使用。
玩家日常操作使用自绘 `TechnologyTreeView` 的聚焦几何：农业、工程、科学、社会四个权威领域
同图展示。每次取前一、当前、下一可见时代；时代内按硬前置深度分层，同深度同领域的兄弟在本泳道
内向下叠放，避免横向溢出。列宽随中央画布均分，节点不超出画布；内容较短时垂直居中，较高时只
允许纵向平移。每个可见时代带底部显示时代里程碑关隘；未揭示时只标“时代里程碑”与候选进度，
不泄露名称与效果。细分 `main_lane` 只保留为节点路线信息和同层排序依据，不再为每条路线单独留出整张画布。
窗口内跨领域硬前置画实线；窗口外时代关系由时代翻页承接，选中节点时才显示其真正的相邻时代可点击入口；
应用交汇只在选中端点时显示细线。里程碑候选仍用节点底边进度条表达“已完成/要求”，不铺开候选边。

独立自绘 `TechnologyOverviewView` 以四领域为行、可见时代为列，每个单元格只画状态刻度。
它不显示完整卡片或连线，点击单元格返回聚焦视图。初次打开优先定位最高权重领域的队列首项，
没有队列则定位最深可研究前沿；搜索、队列行、相邻时代入口和总览单元格统一跳转到同一聚焦路径。

迷雾按「可研究集合 ∪ 其直接未知后继」裁剪聚焦视图。只有揭示条件已满足且全部硬前置已完成
的节点才显示名称；已揭示但前置未完成的节点与未发现节点一样只画暗轮廓。总览固定显示四个领域，但只创建至少一个
可研究节点的时代列，不显示未发现路线、未来时代名称或节点数量。未知前沿只画暗轮廓，不显示名称、成本、
效果、搜索文本或辅助文字。hover 或选中节点会高亮完整前置链与直接后继，无关节点降低对比度。

两种视图永远 1:1 绘制，没有缩放。聚焦视图依靠有界节点集保持文字清晰，必要时可拖动背景；
总览使用固定密度刻度，不把缩小文字当成信息压缩手段。

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

日 tick 只走 `TechnologyWorkspace.refresh_research()`：状态数组未变化时，树只替换进度并
`queue_redraw()`，不重算局部几何或迷雾；隐藏总览不刷新单元格；队列行仅在队列构成签名变化时
重建，详情卡仅在选中项或相关状态变化时重建前后置行，其余 tick 只更新进度与按钮。可研究节点显示路线标签、当前阻塞谓词、证据数量、首次发现日和第一证据格；
未知节点仍不读取或显示名称、效果、前置、路线或辅助文字。

可研究科技的名称、效果摘要、路线徽章、前置科技名称和发现证据均显示中文；内部稳定 ID 只用于
索引与命令提交。未可研究的前置仍显示为“未知科技”，不会通过条件详情泄露名称。

## 启动、存档与兼容性

- `NewGameConfig v3` 保存外国数量、起始国家现金、每日科研采购预算、四领域权重和自动采购开关；
  v2 迁移时外国数量为 0。
- PKCN v11 保存完整研究/信号状态，并把科技与研究信号、揭示条件 IR、Effect recipe/Modifier term IR、
  Trigger 定义摘要和全部内容绑定摘要混入 catalog identity。
- PKEF v10 保存 Effect program hash、实例、事务/ACK 和时代奖励冻结计划；PKTR v5 保存突破
  与发展成就阈值累计、最后采样日、连续进度、来源游标和未派发效果。
- PKEC v36 保存采购累计、科技值市场/在途状态、实践发布所需的经济权威与联合审计基线。
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
- `technology_unlock_closure_audit_test.gd`（普通与 `--construction` 两种闭包）
- `technology_industry_chain_balance_test.gd`
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
仍只保存科技权威状态，PKEF v10 保存 Effect instance/transaction。正常路径仍等 adapter ACK
到齐；若下一国家日 UNIQUE_SOURCE 仍未落地，Country 直接套用同一 UNIQUE_SOURCE 后才把
pending 转成 completed。

## 运行时 capability（2026-08-25）

`TechnologyCatalog` 将 `runtime_capability_tags` 编译为扁平 offsets/tags；稳定
字符串只在配置期解析。当前远程观察能力
`research.observe_visible_foreign` 由 `tech.magnetic_navigation` 提供，效果为
“当前物理视野内的境外地块可以提供研究证据”。国家完成位仍是唯一权威，
`CountryFacade.has_completed_technology(handle, dense_id)` 做 O(1) bit 查询；不新增
Modifier、第二 TechnologyRuntime 或存档字段。catalog identity 因内容变化而改变，
旧 PKCN 按现有 `catalog_hash_mismatch` 策略拒绝。

