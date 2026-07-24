# 跨时代经济内容与科技标签

当前经济目录覆盖石器时代至人工智能时代的地表物质生产。时代名称只用于设计、UI 分组和审计；
运行时不读取年代或时代序号，建筑、物资、职业与资源可见性完全由国家拥有的 `tech.*` 标签决定。
服务经济、轨道与深空市场本轮明确不在目录中。

## 运行时契约

- `EconomyCatalog` 收集 Good、Building、Profession 和 ResourceProfile 的 `tech.*` 标签，排序为稳定 `technology_ids`。旧 `industry.*` 等命名空间继续作为描述元数据，不执行门控。
- `NativeCountryRuntime` 为每个国家保存 dense technology bitset。新游戏的起始科技由国家启动包决定；缺省国家使用配置的起始科技。
- 经济周期开始时冻结 `cell → country`、国家 generation/hash 和科技 bitset。物资替代、职业就业、建造和生产都读取冻结副本；周期中提交的国家解锁命令从下个经济周期起生效。
- `CountryFacade` 提交 `GRANT_TECHNOLOGY` stable-ID 命令，只允许授予、不允许撤销，避免既有职业和建筑在周期内失去前提。
- 自然资源储量始终真实存在于 DataCore。`discovery_technology_tags` 只控制地图和 Inspector 是否可见；能否开采由采集建筑自己的 `technology_tags` 独立决定。
- PKCN v1 保存国家科技；当前 PKEC v19 保存匹配的 PKCN schema/generation/hash、企业三态及 pending/cooldown、聚合商人债务、实物收入、国内在途贸易、每 cell 结算日/generation 与 dirty generations。PKEC v18 以 `pending=NONE, cooldown=0` 兼容恢复；PKEC v2-v17 统一返回 `legacy_economy_save_unsupported`。
- 每个 need 最多支持 4 个替代 variant。32 个职业映射到 survival、agrarian、extractive、
  industrial_worker、artisan、technical、merchant、owner 八套计划；共同覆盖主食、衣着、住房、
  蛋白质、果蔬、卫生与医疗，并按职业加入工作装备、交通、耐用品、奢侈品和身份消费。
  `survival_household` 同时是自适应工资的生活成本基准。电力在专门家庭公用事业结算完成前不进入家庭能源替代。
- 建筑输入槽可使用精确 good、category 或显式候选 CSR，三者逐槽互斥。显式候选携带配方级 Q16
  效率并按 stable good ID 编译；native 继续使用既有 InputCandidate 选择逻辑，不新增配方运行时。
  建筑 snapshot 额外报告每个 group/input slot 上次实际选品，供 Inspector 展示；该诊断不持久化。

## 内容分层

| 设计时代 | 代表科技标签 | 主要新增链条 |
|---|---|---|
| 石器时代 | `tech.hunting`, `tech.gathering`, `tech.stone_knapping`, `tech.fire_control` | 狩猎/采集、家庭手织、早期金银矿点、燧石采集、石器打制、公共火塘；生产者本人持有设施 |
| 早期农业/青铜时代 | `tech.pottery`, `tech.bronze_casting` | 早期自耕农田与家庭织机、陶器；铜锡合金与青铜工具；小规模工匠—学徒和地主—奴隶劳工 |
| 古典时代 | `tech.writing`, `tech.masonry` | 统一手抄本、砖石/石灰/玻璃、金银匠、酿造和直接产建筑构件的石作；少量帮工与依附劳工 |
| 封建时代 | `tech.manuscript_culture`, `tech.guild_organization` | 轮作、行会直接织布、裁缝、鞋匠、华服和精美家具；地主—农奴、地主—佃农和行会师徒 |
| 探索时代 | `tech.oceanic_navigation`, `tech.printing_press` | 碎布造纸、印刷、蒸馏、跨洋作物和直接使用布料的远洋船舶 |
| 启蒙时代 | `tech.experimental_science`, `tech.precision_engineering` | 罐藏、炸药、实验化学、科学仪器、精密工具和早期机器零件；研究人员成为独立岗位 |
| 蒸汽时代 | `tech.coke_smelting`, `tech.steam_power` | 焦炭直接炼钢、机械织造、工业造纸、水泥混凝土、铁路、机械化食品和早期油井 |
| 电气时代 | `tech.electrification`, `tech.radio`, `tech.electrochemistry` | 电机、铝、电化学、化肥、炼油、汽车、家电和批量高级消费品 |
| 原子时代 | `tech.geological_prospecting`, `tech.advanced_metallurgy`, `tech.nuclear_fission` | 战略矿产勘探/精炼、核燃料、反应堆部件与核医学制药 |
| 信息时代 | `tech.digital_computing`, `tech.networked_computing` | 半导体、计算机、通信设备等实体工业品 |
| 人工智能时代 | `tech.machine_learning`, `tech.autonomous_systems` | 先进芯片与自主系统；不建立 AI 模型伪商品或服务市场 |

软件、数字服务、AI 模型、轨道科研、遥测、卫星、深空探测、轨道回收与聚变燃料链已删除。
真实服务结算、星外节点、独立市场和跨节点物流属于后续需要单独设计的系统。

## 自给升级族

食物 `subsistence_food` 与布料 `household_cloth` 各有四档：`tech.gathering`、`tech.pottery`、
`tech.guild_organization`、`tech.steam_power`。全部无商品投入、无雇员、零建设期，并受真实土地容量
约束。食物总日产量为 3000、8000、12000、16000，布料为 120、220、400、600；蒸汽档封顶。
解锁高档后低档不得新建，但既有建筑继续生产，不自动升级或拆除。

## 劳动关系与职业抽象

职业仍是 cohort signature 的一个维度，本次没有新增 `legal_status` ABI。`enslaved_laborer`、
`serf`、`tenant_farmer` 和 `indentured_laborer` 因此是内容层近似：它们能区分消费计划、科技
可用性、岗位容量和参考报酬，但不能表达人员所有权、迁徙禁令、地租倒流或绑定具体 owner-lot。
`apprentice` / `journeyman` 表达行会内部层级；`industrial_worker` / `technician` / `engineer` /
`manager` / `researcher` 使大规模、复杂的工资关系只在工业化后出现。

依附岗位仍配置正的固定参考报酬，作为食宿和维持费用的货币化代理，避免 cohort 因无法购买
生存品而立即耗尽资金；这不代表历史上的自由工资合同。蒸汽时代后的企业岗位改用 role-level
adaptive 工资。完整法律身份、地租/分成、强制劳动和身份解放仍是明确非目标。

建筑经营结构与配方同时参与内容审计。商业化的行会/科学农场采用地主—佃农关系；机械化和电气化
只把劳动组织转为地主—农业工人—经理，并增加机械、肥料和电力，不会仅因资本密集度提高就把土地
业主改写成工业资本家。未来只有在加入独立的农场主或农业资本家职业后，家庭农场和农业公司才另行
分化。行会工坊必须具有与产品复杂度相称的学徒和熟练工，不能把精美家具
等高级产品建模为单一业主无工具生产。蒸汽工厂引入产业工人、行业专门人员和经理；电气、原子、
信息及 AI 工厂继续增加技术员、工程师和研究员，岗位规模与结构不再按粗行业复制同一模板。

配方除主要原料外还表达经常性生产资料：适用作坊和所有成熟工厂消费维护工具；电气时代后的
工厂消费电力，且除发电和工业机械自身外消费工业机械。橡胶、塑料、木材、金属、润滑剂、化学品
仍按具体工艺使用显式候选或精确输入，不作为无差别的全行业税。该扩展只改变 catalog 内容；输入
继续一次编译为 native CSR，岗位和工资继续由既有原生建筑图结算。

该分层参考 IISH Global Labour History 对自给、雇佣、自营、分成和强制劳动的跨区域分类，
以及 ILO 对奴役、农奴制、债役和强迫劳动的定义；不把单一欧洲序列视为全球必经阶段：

- https://iisg.amsterdam/en/introduction-why-labour-relations-and-social-inequality
- https://www.ilo.org/topics/forced-labour-modern-slavery-and-trafficking-persons/what-forced-labour
- https://www.ilo.org/media/443241/download

## 2026-07-22 建设闭包契约

全部 261 种建筑都由代码生成器写入非空、正数量的显式建造清单，成本按业主与雇员岗位总数线性缩放。建筑不得使用自己的输出作为建材；原木、原石、砖、木材、建筑构件、钢、混凝土和玻璃等骨干生产者只能读取已处于更早拓扑层的建材。蒸汽时代的煤矿、焦炉、炼钢顺序被显式固定为“煤 → 焦炭 → 钢”，避免钢成为自身上游入口。

累计时代审计从采集营地、商栈、伐木场、采石场及一次性桥接库存（原木 1000、采集物 250、燧石 500）出发，同时检查建造材料、日常投入、科技和自然资源条件。每个 rank 都反复扩张到固定点；不可达建筑会报告缺失入口和强连通闭环。测试 bootstrap 只在开局投放一次桥接库存，之后所有扩建仍支付目录中的非零成本；每个有人口市场保留商栈和可运行食物根。常规初始采集规模继续要求十年资源储量；为避免有真实矿藏却不足十年满负荷的地图被误判为空经济，建设闭包所需的最小伐木场和采石场允许按一年本地资源储量各保留一座。它们仍使用并扣减真实本地资源。随机地图上的连通候选区域只有同时具备上述资源安全来源时才会生成初始人口、建筑和桥接库存；缺少入口的孤立区域保持无人状态，并写入 `construction_source_skipped_components` 诊断。初始容量仍优先使用单格自给的严格路径；若该路径把原本具备木材、石材、食物、衣着和强制投入闭环的全部连通贸易区裁空，则以连通分量汇总产能和强制投入覆盖率，确定性地分配人口，并报告 `regional_capacity_fallback=true`。此回退不跨海岛借用资源，也不放宽缺失生产入口。整张地图不存在任何可闭合候选区域时，bootstrap 才以 `bootstrap_construction_source_missing` 明确失败，并报告三种根资源的正储量地块数、峰值和根建筑数量。

## 资源抽象与内容规模

当前目录为 120 goods、261 production-method buildings、33 professions、18 needs、8 consumption plans 和
31 registered resources。锂、钴、天然
石墨、镍、铂族和铀的独立矿藏、goods、DataCore slots 与采选建筑已收敛为
内部稳定 ID 为 `rare_earth → rare_earth_ore → rare_earth_metals`、玩家显示为“战略矿产”的
两级加工链，并新增 `nuclear_fuel` 加工。该取舍有意减少
横向物资数量，同时保留勘探、采矿和精炼深度。定义差异可核对 USGS：
https://www.usgs.gov/programs/mineral-resources-program/science/about-2025-list-critical-minerals

自然资源储量不是可直接消费的 goods 库存。所有 `extract` 建筑以独立的资源投入列和物资产出列
表达换算；换算由具体配方和利润校准决定，同资源的后期建筑通常比早期建筑高，
狩猎等多副产品配方按输出之和计算。`capacity` 边不参与该比例，也不会扣减储量。新地图初始
储量额外采用内容级 abundance 倍率：农业 capacity `1×`、可再生资源 `2×`、矿物/油气等地质
资源 `8×`。倍率只改变已有矿脉内的数量，不改变矿脉位置、habitat 或每日再生系数。

畜牧物种、马匹和旧战略矿物拆分项不再占用 DataCore reserve/extra-change；淡水鱼恢复为湖泊/湖岸自然资源
slots。当前资源 schema 与 30 个注册资源对齐，生成的 C++ bind table 为 138 entries；本次
有意触发 schema/catalog 变化，需重 build GDExtension。`cycle_flow` 严格只有电力。

马匹仍作为前工业交通与上层娱乐消费品：青铜时代的 `horse_breeding_camp` 和封建时代的
`horse_breeder` 使用 `pasture` 容量生产。此后不再生成科学化、先进化或数字化养马场；旧养马场
可以继续运行，但养马业不会被夸大为值得玩家单独扩建的后期宏观产业升级族。

生产方式生成采用显式生命周期分类。主粮、布料、基础冶金、机械、电力等宏观产业可持续升级；
采集、燧石、狩猎、陶器、香料、药材、传统榨油/制皂、包装、印刷、传统作物、砖石与造船等产业
在指定时代收敛，不再为了填满时代建筑数量而自动产生信息化或智能化伪升级。未分类的早期单一
生产源会令 codegen 失败。纸草和羊皮纸作为单下游中间品已删除，古典和修道院抄写室分别直接
消费采集植物与生皮；食用油加入加工食品配方，获得明确的规模化下游用途。
工业制鞋使用两个相互独立的配方候选槽：皮革或布料作为鞋面，天然乳胶或合成橡胶作为鞋底；
候选按材料适用性配置效率，不把鞋履成品与原料塞进同一替代类目。
全目录输入槽复查后，包装材料可由纸、玻璃、钢、铝或塑料加工；家具包覆可用布料或皮革；
肥皂可用植物油或畜产油脂；早期机器零件可低效使用食用油，后期改用矿物润滑剂；铜/铝导体、
塑料/合成橡胶绝缘层、铅/战略矿物电池化学、煤/焦炭非铁冶炼等均通过配方级候选表达。
`wire` 只表示裸导体，`insulated_cable` 明确由 wire 加绝缘材料生产，纠正了旧配方中电线先耗
塑料、绝缘电缆反而只耗铜的工艺倒置。以上候选在配置时编译为既有 native CSR，不增加运行期
字符串分类或 GDScript 配方选择。

本次有意改变 profession/good/building/resource stable-ID 表，旧 PKEC catalog 存档会以明确的
catalog mismatch 拒绝恢复，不提供静默 remap。

## 维护规则

新增可执行标签必须使用 `tech.*`，并至少被一个 Good、Building、Profession 或 ResourceProfile 引用，才能进入编译目录。内容必须形成生产者与下游用途闭环。新增自然资源仍须同步 component IDs、MapData 数组、component schema、生成的 C++ bind table、ResourceProfile、registry、collector、构建和资源链测试。
