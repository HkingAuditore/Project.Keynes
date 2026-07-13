# 跨时代经济内容与科技标签

本版本把经济内容从单一的现代工业目录扩展到石器时代至约 2200 年的地表、轨道与深空产业。时代名称只用于设计、UI 分组和审计；运行时不读取年代或时代序号，建筑、物资、职业与资源可见性完全由地块拥有的 `tech.*` 标签决定。“中世纪”统一命名为“封建时代”。

## 运行时契约

- `EconomyCatalog` 收集 Good、Building、Profession 和 ResourceProfile 的 `tech.*` 标签，排序为稳定 `technology_ids`。旧 `industry.*` 等命名空间继续作为描述元数据，不执行门控。
- `NativeCountryRuntime` 为每个国家保存 dense technology bitset。新游戏的起始科技由国家启动包决定；缺省国家使用配置的起始科技。
- 经济周期开始时冻结 `cell → country`、国家 generation/hash 和科技 bitset。物资替代、职业就业、建造和生产都读取冻结副本；周期中提交的国家解锁命令从下个经济周期起生效。
- `CountryFacade` 提交 `GRANT_TECHNOLOGY` stable-ID 命令，只允许授予、不允许撤销，避免既有职业和建筑在周期内失去前提。
- 自然资源储量始终真实存在于 DataCore。`discovery_technology_tags` 只控制地图和 Inspector 是否可见；能否开采由采集建筑自己的 `technology_tags` 独立决定。
- PKCN v1 保存国家科技；PKEC v11 保存匹配的 PKCN schema/generation/hash 以及国内在途贸易状态。v10 迁移为空贸易状态；PKEC v2-v9 不再兼容读取，返回 `legacy_countryless_economy_save_unsupported`。
- 每个 need 最多支持 8 个替代 variant；五套家庭计划已加入石器食物、猎物、陶器、无线电、数字服务、手抄文献和自主系统等随科技出现的替代品。

## 内容分层

| 设计时代 | 代表科技标签 | 主要新增链条 |
|---|---|---|
| 石器时代 | `tech.hunting`, `tech.gathering`, `tech.stone_knapping`, `tech.fire_control` | 狩猎/采集、燧石采集、石器打制、公共火塘；生产者本人持有设施，不生成成批雇员 |
| 青铜时代 | `tech.pottery`, `tech.bronze_casting` | 陶器；铜与锡合金、青铜工具；小规模工匠—学徒和地主—奴隶劳工 |
| 古典时代 | `tech.writing`, `tech.masonry` | 莎草纸、手抄文书、档案；古典砌石与公共工程；少量帮工与依附劳工 |
| 封建时代 | `tech.manuscript_culture`, `tech.guild_organization` | 羊皮纸、典籍、修院抄写；地主—农奴、地主—佃农和行会师徒 |
| 探索时代 | `tech.oceanic_navigation`, `tech.printing_press` | 帆布、航海仪器、远洋船舶；种植园使用契约劳工，城镇生产使用帮工 |
| 启蒙时代 | `tech.experimental_science`, `tech.precision_engineering` | 科学仪器、精密工具、科学院技术转化；研究人员开始成为独立岗位 |
| 蒸汽时代 | `tech.coke_smelting`, `tech.steam_power` | 焦炭、蒸汽机、蒸汽铁路；工业业主、产业工人、工程师和经营管理者分层 |
| 电气时代 | `tech.electrification`, `tech.radio`, `tech.electrochemistry` | 绝缘电缆、无线电网络；产业工人、技术工人、工程师和管理岗位并存 |
| 原子时代 | `tech.geological_prospecting`, `tech.advanced_metallurgy`, `tech.nuclear_fission` | 抽象稀土勘探/精炼、反应堆部件、医用同位素 |
| 信息时代 | `tech.digital_computing`, `tech.fiber_optics`, `tech.networked_computing` | 软件资本、光纤、数据中心与数字服务 |
| 人工智能时代 | `tech.machine_learning`, `tech.autonomous_systems` | 先进芯片、AI 模型、自主系统与机器人集成 |
| 轨道/深空阶段 | `tech.orbital_flight` 至 `tech.deep_space_systems` | 航天器部件、卫星、轨道科研、聚变燃料、抽象轨道回收和深空探测器 |

轨道与深空当前仍使用地表 MarketStore 和 BuildingGraph：所谓“抽象轨道资源回收”是消耗航天器部件与聚变燃料的地表/国家级计划，不把小行星矿藏伪装成地表自然资源。真实星外节点、独立市场和跨节点物流属于后续需要单独批准的子系统。

## 劳动关系与职业抽象

职业仍是 cohort signature 的一个维度，本次没有新增 `legal_status` ABI。`enslaved_laborer`、
`serf`、`tenant_farmer` 和 `indentured_laborer` 因此是内容层近似：它们能区分消费计划、科技
可用性、岗位容量和参考报酬，但不能表达人员所有权、迁徙禁令、地租倒流或绑定具体 owner-lot。
`apprentice` / `journeyman` 表达行会内部层级；`industrial_worker` / `technician` / `engineer` /
`manager` / `researcher` 使大规模、复杂的工资关系只在工业化后出现。

依附岗位仍配置正的固定参考报酬，作为食宿和维持费用的货币化代理，避免 cohort 因无法购买
生存品而立即耗尽资金；这不代表历史上的自由工资合同。蒸汽时代后的企业岗位改用 role-level
adaptive 工资。完整法律身份、地租/分成、强制劳动和身份解放仍是明确非目标。

该分层参考 IISH Global Labour History 对自给、雇佣、自营、分成和强制劳动的跨区域分类，
以及 ILO 对奴役、农奴制、债役和强迫劳动的定义；不把单一欧洲序列视为全球必经阶段：

- https://iisg.amsterdam/en/introduction-why-labour-relations-and-social-inequality
- https://www.ilo.org/topics/forced-labour-modern-slavery-and-trafficking-persons/what-forced-labour
- https://www.ilo.org/media/443241/download

## 资源抽象与内容规模

当前目录为 153 goods、190 buildings、32 professions、35 terrestrial resources。锂、钴、天然
石墨、镍、铂族和铀的独立矿藏、goods 与采选建筑已收敛为
`rare_earth → rare_earth_ore → rare_earth_metals` 两级加工链。这里的“稀土”是玩家可读的
战略稀有矿物总称，不是化学分类；现实中的锂、钴、镍、铀和铂都不是稀土元素。该取舍有意减少
横向物资数量，同时保留勘探、采矿和精炼深度。定义差异可核对 USGS：
https://www.usgs.gov/programs/mineral-resources-program/science/about-2025-list-critical-minerals

退役资源的 DataCore reserve/extra-change slots 暂时保留为未注册的兼容列，不进入 35-resource
catalog，不触发 C++ ABI 或 MapData 布局迁移。软件、AI 模型与数字服务继续作为耐久库存资本品；
`cycle_flow` 仍严格只有电力。

本次有意改变 profession/good/building/resource stable-ID 表，旧 PKEC catalog 存档会以明确的
catalog mismatch 拒绝恢复，不提供静默 remap。

## 维护规则

新增可执行标签必须使用 `tech.*`，并至少被一个 Good、Building、Profession 或 ResourceProfile 引用，才能进入编译目录。内容必须形成生产者与下游用途闭环。新增自然资源仍须同步 component IDs、MapData 数组、component schema、生成的 C++ bind table、ResourceProfile、registry、collector、构建和资源链测试。
