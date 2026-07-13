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
| 石器时代 | `tech.hunting`, `tech.gathering`, `tech.stone_knapping`, `tech.fire_control` | 狩猎/采集、燧石采集、石器打制、公共火塘 |
| 青铜时代 | `tech.pottery`, `tech.bronze_casting` | 陶器；铜与锡合金、青铜工具 |
| 古典时代 | `tech.writing`, `tech.masonry` | 莎草纸、手抄文书、档案；古典砌石与公共工程 |
| 封建时代 | `tech.manuscript_culture`, `tech.guild_organization` | 羊皮纸、典籍、修院抄写；手工业行会制品 |
| 探索时代 | `tech.oceanic_navigation`, `tech.printing_press` | 帆布、航海仪器、远洋船舶与船舶拆解 |
| 启蒙时代 | `tech.experimental_science`, `tech.precision_engineering` | 科学仪器、精密工具、科学院技术转化 |
| 蒸汽时代 | `tech.coke_smelting`, `tech.steam_power` | 焦炭、蒸汽机、蒸汽铁路设备 |
| 电气时代 | `tech.electrification`, `tech.radio`, `tech.electrochemistry` | 绝缘电缆、无线电网络；锂电化学精炼 |
| 原子时代 | `tech.geological_prospecting`, `tech.advanced_metallurgy`, `tech.nuclear_fission` | 锂/钴/石墨勘探，反应堆部件、医用同位素 |
| 信息时代 | `tech.digital_computing`, `tech.fiber_optics`, `tech.networked_computing` | 软件资本、光纤、数据中心与数字服务 |
| 人工智能时代 | `tech.machine_learning`, `tech.autonomous_systems` | 先进芯片、AI 模型、自主系统与机器人集成 |
| 轨道/深空阶段 | `tech.orbital_flight` 至 `tech.deep_space_systems` | 航天器部件、卫星、轨道科研、聚变燃料、抽象轨道回收和深空探测器 |

轨道与深空当前仍使用地表 MarketStore 和 BuildingGraph：所谓“抽象轨道资源回收”是消耗航天器部件与聚变燃料的地表/国家级计划，不把小行星矿藏伪装成地表自然资源。真实星外节点、独立市场和跨节点物流属于后续需要单独批准的子系统。

## 新资源与内容规模

新增四种陆地资源：燧石、锂矿、钴矿石和天然石墨。燧石开局可见；锂、钴和石墨需要地质勘探后显示。所有四种资源都具有 reserve/extra-change DataCore slots、ResourceProfile 和对应 collector。

当前目录为 164 goods、203 buildings、39 professions、41 terrestrial resources。软件、AI 模型与数字服务按现有 ABI 作为耐久库存资本品；`cycle_flow` 仍严格只有电力，避免把算力或软件引入第二套未审计的流量账本。

## 维护规则

新增可执行标签必须使用 `tech.*`，并至少被一个 Good、Building、Profession 或 ResourceProfile 引用，才能进入编译目录。内容必须形成生产者与下游用途闭环。新增自然资源仍须同步 component IDs、MapData 数组、component schema、生成的 C++ bind table、ResourceProfile、registry、collector、构建和资源链测试。
