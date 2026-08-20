# 显赫家族原生运行时

## 目标与边界

家族系统只模拟对城市经济有可见影响的“显赫家族”，不为全部人口创建对象。未加入家族的人口仍
留在原有 `PopulationCohort` 中，称为匿名人口。`NativeEconomyRuntime` 是家族、成员关系和
建筑所有权的唯一可变权威；GDScript 只编译姓氏目录与策略、提交经济 bootstrap，并执行只读查询。

家族层包含形成、分支迁移、远程开拓、产业扩张、特性与行为偏好、地块威望、城市效果、衰退和消亡。
分支迁移可进入本国已有人口格：同 signature 合并进既有 cohort，本家族已在目标有成员则加强该分支，
否则长出新分支。远程开拓的
冻结路线、在途守恒载荷与跨域领土事务见[家族远程开拓运行时](./family-colonization-runtime.md)，家族内部的重要人物稀疏层见
[家族重要人物原生运行时](./notable-person-runtime.md)。系统仍不包含谱系树、婚姻、继承份额、家族合并、
经理代理或跨国汇款。跨国影响只能通过现有人口迁移和本地投资产生；收入、消费和企业税仍按交易
发生地与 cohort/building 所属地的冻结国家映射结算。

家族文化身份由民族显式映射到稳定文化组。姓氏在文化组目录内按权重确定性抽取；城市家族名只在
Facade 查询边界组合当前 `origin_cell` 的聚落显示名、文化组格式和姓氏文本，因此改城市名只改展示，
不改 FamilyStore 或 state hash。非起源地块分支达到 100 人时，`FAMILY_COMMIT` 按父 stable ID、目标
cell 顺序执行一次整支分裂；membership、cash claim、建筑 ownership 与重要人物只改归属，不复制账本。
分裂后的特性混合采用“去一增一至二”：从父家族稳定排序后的特性中确定性移除一个，再按权重和稳定
hash 从满足前置、排斥和强度规则的合法池中加入 1–2 个新特性。保留特性保留原强度；新增特性从其
合法 Q16 最小强度开始。子家族 Modifier/Trigger 只依据最终特性和新分支威望重新计算。

## 权威数据模型

`FamilyStore` 是 generation-safe SoA：

- `stable_id`：存档和确定性身份；运行时引用使用 `(generation,index)` 句柄。
- `surname_id + surname_disambiguator`：指向稳定排序的姓氏包，不把显示文本作为身份。
- `founded_day`、可变运营归属 `home_cell`、不可变 `origin_cell`、`origin_ethnicity`、
  `culture_group_id`、`split_sequence`、`decline_reviews`、`flags`。

关系使用两个稀疏边表：

- `FamilyMembershipEdge(family_handle, cohort_handle, people, cash_claim, ...)`。
- `FamilyBuildingOwnership(family_handle, building_handle, owned_count, filled_owner)`。

成员边只表示 cohort 的一个子集，因此对每个 cohort 恒有：

```text
sum(family.people) <= cohort.population
sum(family.cash_claim) <= cohort.funds
```

`cash_claim` 是 cohort 资金中的守恒归属，不是第二个钱包。生产收入、工资、税、消费、补贴和迁移
仍只改原有 cohort/merchant/country 账本；家族提交阶段按人口与资金基数重新归一化 claim。因此
家族财产查询不会重复计入 money audit，也不会绕过税务。

建筑组仍按 `(cell, building_type, owner_signature)` 聚合。家族所有权是附着于稳定
`BuildingIdentityStore` handle 的 `owned_count`，不会把 `family_id` 放入建筑组 key，从而避免
家族数量放大生产热循环、市场信号和建筑 CSR。

## 特性、偏好与地块威望

`FamilyTraitCatalog` 在冷启动将 stable ID、产业部门、类别、替代类别和语义标签选择器展开为
dense ID CSR。建筑、职业、需求、商品和自然资源 profile 可提供 `semantic_tags`；native 热循环
只读取 exact dense edge。家族成立时按 `world_seed + family_stable_id + trait_catalog_version`
确定性无放回抽取 2–4 个核心特性及 Q16 强度；核心特性不可删除。附加特性只通过按
`effective_day/priority/sequence/submit_order` 排序的命令授予、移除或调强度。

当前默认目录（`data/economy/default_family_traits.tres`，version 2）用互斥组保证门第可读：
生计门第（采集/狩猎/渔户/畜群/垄亩/林薮/矿业）两两互斥；机杼与炉锤互斥；寒门与丰盛餐桌/锦衣高门互斥；
河洛观象与观潮门风互斥。工艺与门风可叠在一条生计之上。选择器依赖建筑/职业 `semantic_tags`；
城市制造/能源/知识产出走 `economy.city.building.*_output_factor`。改目录身份会改
`family_trait_catalog_hash`，旧存档按 catalog mismatch 拒绝。

`FamilyCellInfluenceStore` 为 `(family, settlement cell)` 保存 generation-safe 分支。只要本地仍有
成员、现金 claim 或建筑所有权，分支就存在。威望分固定为：

```text
25% * population_share + 35% * cash_share + 40% * building_asset_share
```

三个分母分别包含地块全部人口、资金和已建建筑重置资本估值；零分母维度贡献 0，不重新归一化。
建筑估值使用冻结本地价格的建材成本加标准运营资本，包含暂停建筑，不含待建队列。每 30 日按
稳定分支相位错峰评审，I–V 升级阈值为 2/5/10/20/40%，降级阈值为对应 80%；连续两次同向后
直接切换到计算出的目标等级。

分支另存 `satisfaction_q16`：成员 cohort 的
[综合满意度](./satisfaction-runtime.md) composite 按 membership 人口加权。
**威望公式一字未改**；满意度只作为**晋升**的否决条件——成员满意度低于社会压力阈值 1 的分支
无论掌握多少现金与土地都不得上升。降级永不被阻塞，因此这只会减慢晋升。
`get_family_branches` 与 `family_branches` 字典同时发布 `satisfaction_q16` /
`satisfactions_q16`，该列进 family state hash 与 PKEC v41。

行为偏好不随威望缩放，只在合法投资、职业迁移和 cohort 消费候选中调整 Q16 分数，不能绕过
科技、资本、建材、资源、岗位或盈利门槛。`FamilyBehaviorPreference` 复用 `EffectCondition` IR；
条件只在 `FAMILY_COMMIT`（以及随后的 CSR 重建）对 `(family, cell)` 求值，失败则该边本轮因子为 1。
通过的边冻成 family→`(cell, score_term, axis, dense_id)` CSR + Q16，投资/招工/消费热循环只读这张
表，禁止按候选重跑条件或扫描全部 trait roll。`score_term` 冷编译为 packed 列：候选权重、税率敏感度、
本地储量分位、`upgrade_tier`、本地热门、职业流动率；这些标量在候选循环里几次 `mul_div_sat`，负向
流动率必须降低实际迁出人数。乘积帽默认 4×。商品偏好按家族人口占 cohort 的份额合成，并同时影响
variant 份额和普通需求量；生存需求下限不下降。投资建设持久保存 sponsor family。

核心特性抽取与 FamilyEffect 共用科技前列：`FamilyTraitDefinition.prerequisite_technology_keys`
在 `assign_core_family_traits` 用 origin/home cell 的 `cell_has_technology` 过滤候选。未解锁特性
仍可通过附加特性命令授予。改 catalog hash 会拒绝旧档，与现有约定一致。

## 家族效果目录与执行

`FamilyEffectDefinition` 是纯 authoring resource，只在冷启动编译为共享 `EffectDefinition` IR。
它声明六类来源（Trait、随机池、事件、玩家命令、科技、国家状态）、六类目标（家族、分支、
聚落格、国家、气候格、格内建筑/商品/资源）、五类运算、三类生命周期、五类 stack policy 和
六类 target selector。`default_family_effects.tres` 当前有意保持为空；案件中的示例不作为默认
平衡内容，后续内容包只需追加资源，不需要扩展热循环分支。

Trait 引用在 `EconomyCatalog` 冷编译为稳定 effect ID CSR。Economy 按实际 family/branch/cell
稀疏建立 `FamilyEffectBinding`，并只发布效果程序声明使用的 metric mask。dense metric 0–9 已占用
且不得重排：家族强度/人口/现金 claim、分支威望/人口、格温度/降水/短缺/贸易事件/人口。追加 id 只能
接在末尾：10 `cell.landform`、11 `cell.essentials_shortage_q16`、12 `branch.is_local_prestige_max`、
13 `cell.rain_event`、14 `cell.resource_abundance_q16`。发布走既有 branch/cell 反向索引，缺 metric
读 0。EffectRuntime 按
`(target_domain,target_handle,target_generation,stack_key_hash)` 建组，确定性执行
`REPLACE / REFRESH / ADD_STACK / MAX / MIN` 仲裁；同一权威 upsert 幂等，不会把每日协调误当成
新增 stack 或刷新 duration。

目标路由固定如下：Family/Branch 使用 Economy `ENTITY`，SettlementCell 与
BuildingResource 使用 Economy `GROUP`，Country 与 Climate 使用各自 `ENTITY`。producer `161`
的 Family/Branch handle 在 Modifier safe commit 前再次向 Economy 校验 generation；陈旧目标返回
`modifier_family_effect_handle_stale`。精确 selector 在冷边界强制绑定对应 stat：

```text
good     -> economy.city.good.<id>.output_factor
building -> economy.city.building.<id>.output_factor
resource -> economy.city.resource.<id>.regen_factor
```

商品输出采用 shared-per-good 加稀疏 `(cell,good)` CSR override；建筑类型复用现有按 type cache，
资源复用冻结 regen cache。不存在 `cell_count * good_count` 新矩阵。所有 cache、binding 反向索引和
stack group 都是 transient；权威实例/事务由 PKEF 保存，家族/分支与环境 lane 由 PKEC 保存。

永久、限时与 EVENT_ONCE 都由 ACK 决定已应用/更新/回收状态。领域拒绝不是生命周期决定：实例保留
最后一次 ACK 状态并排到下一日重试；EVENT_ONCE 只在完整 ACK 后回收，显式 retire 的 REMOVE 被拒绝
后也保持可重试。

威望分档效果在 `FAMILY_COMMIT` 协调到 settlement-cell Economy Modifier bucket 和动态 Trigger
binding。分支/特性/等级无变化时不更新；降级、特性移除或分支消失立即解绑并清 Trigger 累计。
建筑完工与跨 cell 国内贸易事实只发布一次，按 `(event_type, cell)` 扇出。免费建筑不扣资金或
材料但遵守工期、科技、地块和资源预算；`i32_1` 非法时回退施工 fact / payload 的 `type_id`
（好事成双）。人口奖励写显式 `POPULATION_SOURCE` 账本事件。奖励建筑使用负 sequence，不能递归
计入自己的完成触发。守恒型独立效果走 Economy `EVENT_COMMAND`，禁止把现金/人口/商品注册成
Modifier stat，也禁止家族第二钱包：

- `family.absorb_anonymous`（opcode 21）：把匿名人口吸收进本家族 membership，总量不变；或 SET
  家庭规模吸收加成。
- `family.purchase_discount`（opcode 22）：只对该家族在 cohort 内的需求份额套买方折扣，价差走
  现有消费补贴/财政 escrow（国库封顶）。无预算则折扣为 0。
- `SETTLE_FAMILY_EXPEDITION.i32_1>0`：开拓 ACK 后打一条可选 `population_reward`。内置开拓事务把
  该值放在 Effect payload[3]，避免改 payload[0] 破坏 CLAIM/SETTLE 的 PKEF 相等校验。
  `family.population_reward` 的 `i32_0=-1` 只把人数冻进家族开拓奖励，不立即铸造人口。

## 形成与消亡

默认策略只在乡村及以上、人口至少 100 的地块评审，每格最多 8 家族；评审以 cell/day 相位
错开。候选建筑必须同时满足：

1. 正常营业，存在稳定 building identity；
2. 至少一栋尚属匿名所有，且一栋所需业主岗位已实际填满；
3. 实际利润率达到建筑目标；
4. 预计每名业主日收入高于当地同 signature 生活成本；
5. 匿名业主人口拥有至少 30 天的创始人生计现金储备。

候选按利润率、收入、建筑类型和业主 signature 确定性择优。家庭规模按该家族在该格
**全部业主槽**乘以 `family_household_people_per_owner_slot`（默认 256，上限
`family_household_max_people` 默认 1024）计算，因此一槽作坊约 256 人、两槽营地约 512 人，
四槽起碰到 1024 封顶。创始人口只从业主 signature 的剩余匿名人口吸收，并把 `filled_owner`
记为业主槽位数。当日 `FAMILY_COMMIT` 在形成之后再吸收一次：只继续吸收业主职业的匿名人口，
每个 cohort 至少留 1 名匿名者，并且同一地块所有家族合计不超过当地人口一半，其余保持匿名。
不把待业或其他职业整城吞进第一家。开局 20 人首都因此仍是两名采集业主加匿名多数。
初始 cash claim 按其在 cohort 中的人口比例取得；
首栋建筑的 `owned_count=1`。每一轮 `FAMILY_COMMIT` 在归一化后（phase 0）以及形成后
（phase 2、重建 CSR 前）按当前拥有的业主槽位把偏小的既有家族吸收到同一家庭规模，
不新增人口、不改账本总量。`family_max_per_cell` 写进 PKEC family policy header，
改这个值会使旧存档在 restore 时返回 `save_family_policy_profile_mismatch`；
`family_household_*` 不在该 header 里。

正式新游戏是唯一显式例外：`StarterSettlementBootstrap v3` 为每个首都声明一栋采集营地，原生
bootstrap 将其两个实际采集者业主直接建立为一个创始家族，并立即重建全部家族 CSR 与
`FamilyCellInfluence`。`get_family_branches` 因此在第一日 `FAMILY_COMMIT` 之前就有
generation-safe handle；账本命令（含 `family.population_reward` 的 `i32_0=-1` 开拓冻结）
不能等 4 个 epoch 才出现分支句柄。`FAMILY_COMMIT` 在存在 membership 但没有活跃 influence
行时也会补建。该操作不降低全局形成门槛，不增加人口、资金、商品或建筑数量；测试夹具和普通
经济 bootstrap 未提供声明时仍从空家族状态开始。

为防止长驻编辑器仍发出 v2 packet，原生 bootstrap 还会从“`forced_named_cells` 中的首都 +
该地块真实存在的 `gathering_ground`”派生同一声明。仅强制命名、但没有采集营地的测试/普通
bootstrap 不触发。若旧会话已在无家族状态下运行，日常 `FAMILY_COMMIT` 会在第 0..30 天检查
上述权威不变量，并在 owner 岗确已占满时补建一次；权威 membership 边防止同批次重复创建。

每个家族按 `stable_id % family_review_days` 分摊生命周期复核。人口归零立即消亡；无产业且人口
低于活跃阈值连续达到 `family_decline_reviews` 次后消亡。home cell 取成员最多的分支，同人口时取
较小 cell。空槽采用最低 index 确定性复用，并递增 generation，旧句柄不能指向新家族。

## 业主岗位与职业统计

家族拥有某建筑不等于自动填满业主岗。每轮 `building_employment` 在原有岗位分配后执行约束：

- 家族所属建筑的业主岗，只能由同一地块、同一 owner signature 的该家族成员填充；
- 匿名建筑只能使用该 cohort 中未归属任何家族的人口；
- 任一成员不能同时填多个业主岗；缺少合格成员的岗位保持空缺并自然降低产能/收益；
- 第一版没有经理或代理经营的替代通道。

`FAMILY_COMMIT` 将建筑 `filled_owner` 回写到成员边，并按剩余成员容量确定性分摊 employee
employment。因此 `get_family_snapshot()` 可按 profession 汇总家族人口、业主就业和雇员就业；
这些是 cohort 与建筑岗位的派生归因，不是独立劳动力账本。

## 迁移、投资与经济结算

人口换职业、换 signature 或迁移时，`move_cohort_population()` 同步按实际移动人口和资金比例移动
成员边；由此自然形成家族分支。家族成员作为内生投资 sponsor 完工时，新增建筑所有权归给该
家族。非家族 sponsor 仍生成匿名建筑。

所有生产、销售、工资、消费和税务事件继续走原经济流水：

```text
building/market transaction
  -> cohort or merchant funds
  -> source-local tax withholding / fiscal escrow
  -> country treasury commit
  -> FAMILY_COMMIT normalizes cash_claim and employment attribution
```

家族总财产为成员 `cash_claim` 加其拥有建筑的只读资产估值；资产估值不参与守恒账本。不存在
家族钱包向 cohort 注资、跨境汇回或二次征税。

## 调度与性能

经济图在 `BUILDING_COMMIT` 后依次执行 `FAMILY_COMMIT=16`、`PERSON_COMMIT=17`，再进入
`AGGREGATE_PUBLISH`。家族阶段：

1. 归一化成员人口/现金 claim，并按业主槽把偏小家族吸收到家庭规模目标，再更新职业就业归因；
2. 按确定 cell work budget 评审形成；
3. 对当日新家族再吸收一次依附人口，复核衰退/消亡，压缩边表并重建索引。

热循环只遍历当前建筑格和稀疏关系边。提交后重建以下 transient CSR：family→cohort、
cohort→membership、family→building、building→ownership、cell→family，以及冻结的
family→`(cell, score_term, axis, id)` 行为因子表。CSR 不进入存档或状态哈希，恢复后确定性重建。
`family_cells_per_slice` 控制形成扫描的 continuation 工作上限；成员与产业边受
`family_max_per_cell` 的稀疏上限约束，在冷路径提交点统一归一化和重建 CSR。
`OFF` 且无历史家族时为常数时间跳过。

玩家接口完全只读：

- `get_family_cell_snapshot(cell, offset, limit)`：地块家族分页摘要；
- `get_family_snapshot(handle)`：身份、人口、财产和职业统计；
- `get_family_traits(handle)`：核心/附加特性、强度和已编译行为偏好；`EconomyFacade` 再附加中文 `descriptions` 与 `effect_display_names`，不进入 native catalog hash 或 PKEC。
- `get_family_branches(handle, offset, limit)`：地理分支；
- `get_family_branch_effects(handle, cell)`：威望拆分、Modifier 贡献和 Trigger 进度；`EconomyFacade` 再附加 modifier/trigger 的中文 `display_names` 与 `descriptions`。
- `get_family_industries(handle, offset, limit)`：产业与业主占岗；
- `get_building_cell_snapshot(cell)`：附带所有权 CSR。

查询只允许在 native slice 间读取，不复制全图、不产生命令、不进入 state hash。

## PKEC v41

当前 writer/reader 均严格要求 PKEC v41。FamilyStore 记录包含 `origin_cell`、`culture_group_id` 和
`split_sequence`，family policy header 固定 `family_split_population_threshold=100`；section 15–17 保存 FamilyStore、membership 与 ownership，
section 18–19 保存人物与人物需求，section 20–22 保存 trait rolls、cell influences 和 pending trait
commands，section 23 为 END。v41 的 cell record 将降水加入环境快照，七条环境 lane 按固定顺序
进入 restore hash；旧 schema 不做隐式迁移。cell influence 记录自 v30 起包含分支
`satisfaction_q16`。
恢复校验 generation handle、目录 hash、强度步长、核心数量、唯一
分支 stable ID、威望范围、连续评审状态和全部引用，再重建 CSR、selector cache、Modifier/Trigger
binding 与冻结消费/资源因子。FamilyEffect binding 由 trait CSR 和当前权威分支重新协调，不在 PKEC
复制 EffectRuntime 的实例权威。派生缓存不进入 PKEC 或 state hash。当前 reader 只接受 v41。

## 验证要求

最低验收包括：家族形成门槛、实际业主占岗、职业统计、所有权 CSR、人口/货币/商品守恒、PKEC
v41 hash round-trip、旧 schema 明确拒绝、特性抽取/命令排序、分支威望滞回、分支满意度门控只挡晋升不挡降级、
六类目标路由、五类 stack policy、EVENT_ONCE/retire 拒绝重试、精确 selector/stat 校验、
稀疏 exact-good override、奖励防递归、generation 旧句柄拒绝、行为条件冻结 CSR、打分轴、
科技门、匿名吸收/买方折扣守恒、payload 复制免费建筑，以及家族/人物关闭与
开启的目标规模性能对比。

## 维护入口

- 后续开发先加载仓库 Skill：
  [project-keynes-family-runtime](../../.codex/skills/project-keynes-family-runtime/SKILL.md)。
- 家族行为、重要人物、守恒、职业统计、所有权 CSR 与当前 PKEC 的最小回归入口是
  `Project/project-keynes/tests/family_runtime_test.gd`；行为条件、打分轴、科技门与守恒命令
  见 `family_behavior_effect_runtime_test.gd`、`family_effect_*_test.gd`、
  `trigger_family_branch_test.gd`。
- 影响通用经济、税务、国家或调度时，同时加载相应 Economy、Tax、Country 与 Runtime
Architecture Skill；本页仍是家族模型的项目文档单一事实源。

## Effect Runtime 接入

旧的 Trait 威望档 Modifier 继续通过 `family.modifier.*` 程序兼容执行；新
`family.effect.*` 程序使用独立 catalog identity、typed target resolver 和 producer `161`。
两者都不改变 FamilyStore、分支 generation、Trigger binding 或人口/现金/建筑守恒边界；
grant/remove/set-strength 仍只走家族命令。EffectRuntime 从不拥有家族、成员、建筑所有权或环境
状态，Economy 也不直接写 Effect transaction/ACK。
