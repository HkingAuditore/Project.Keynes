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
| 科技界面显示和交互 | `TechnologyWorkspace`（全屏），只读快照加命令提交 |
| 科技树静态几何 | `TechnologyTreeLayout` 纯函数，一次性烘焙 |

`EconomyCatalog` 只接受权威科技目录，并验证所有 `tech.*` 标签。科技 dense ID 采用目录
拓扑顺序；经济编译期把字符串标签解析成 dense ID，运行热循环不查找字符串。

## Research-signal conditions (PKCN v5)

`ResearchSignalCatalog` is static content, not another runtime. It compiles stable signal IDs for
Bio, resource, landform, weather and breakthrough observations. `TechnologyCatalog` compiles
technology conditions to postfix dense IR and includes that IR plus the signal catalog in the country
catalog hash. Legacy `prerequisite_ids` remains the compatibility structural gate.

The active native condition subset is `TECH_COMPLETED`, `SIGNAL_PRESENT`, `SIGNAL_COUNT`,
`ALL_OF`, `ANY_OF`, `AT_LEAST`, and `NOT`. The queue head blocks when an active condition fails but
keeps its progress; deferred domain points do not spill to another domain. `pending` activation does
not re-evaluate a condition. `COUNTRY_FLAG`, statistics, buildings, transient weather/event windows,
sequence, and reveal-condition evaluation are authoring extension points, not active v1 semantics.

Static signal discovery is country-local and is initiated only by a 0→1 explored-cell transition.
The map stores a CSR of possible signals; `NativeCountryRuntime` owns whether a country has observed
them. Goods stock never implies Bio discovery, and countries do not automatically share evidence.

## 目录

首版目录包含 81 个定义：4 个开局完成根科技和 77 个可研究科技，覆盖 11 个时代以及农业、
工程、科学、社会四领域。普通节点要求全部直接前置；时代节点还要求上一时代里程碑；每时代
里程碑使用四个候选中的任意两个。只在直接前置完成后揭示后继，揭示不会递归完成科技。

目录编译器生成 prerequisite CSR、milestone-candidate CSR、反向解锁索引、拓扑序和 catalog
hash，并验证重复 ID、缺失引用、环、时代倒置、不可达里程碑、无效 Modifier definition 与
经济内容标签。

## 国家研究状态与日结算

PKCN v3 为每个国家保存：

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
时间以及国内贸易容量/速度。建筑目录编译唯一主经济部门 ID，生产热循环按国家查询 frozen
factor；不会为每个建筑实例创建科技 Modifier。

Modifier 只改变配方结果、科技值到进度的转换、施工参数和贸易能力，不直接增删现金或商品。

## UI

`CountryPanel` 只是全屏 shell：一条 section 标题条加内容区，不再叠加国家档案、摘要卡或
section tab；section 切换只由底栏 `CountryActionBar` 驱动。经济 section 挂载只读
`EconomyWorkspace`，经 `CountryFacade.treasury_snapshot()` 展示国家现金与全部非零国库物资；
政治/军事/外交暂用统一 `SectionPlaceholderScreen`。科技 section 挂载全屏
`TechnologyWorkspace`：顶部 icon 化状态条、左侧研究方针栏、中央科技树、右侧详情卡。

科技树是单个自绘 `TechnologyTreeView`，不再使用 `GraphEdit`，也不为 81 个节点创建子节点。
几何由纯函数 `TechnologyTreeLayout` 一次性烘焙：全局 DAG 层号、时代分带、同层重心排序、
里程碑居中并终结所在时代、三次贝塞尔连线采样点。坐标烘焙后永不变动。

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
重建前后置行。

## 启动、存档与兼容性

- `NewGameConfig v3` 保存外国数量、起始国家现金、每日科研采购预算、四领域权重和自动采购开关；
  v2 迁移时外国数量为 0。
- PKCN v3 保存完整研究状态和目录 hash。
- PKEC v21 保存采购累计、科技值市场/在途状态及联合审计基线。
- PKSV 恢复顺序保持 PKCN 在 PKEC 之前。
- 旧科技树存档明确返回 `legacy_technology_tree_save_unsupported`，不做静默迁移。

## 聚焦验证

- `technology_catalog_test.gd`
- `technology_research_runtime_test.gd`
- `technology_procurement_runtime_test.gd`
- `technology_modifier_activation_test.gd`
- `technology_workspace_smoke_test.gd`
- `country_runtime_test.gd`
- `economy_rolling_runtime_test.gd`
- `economy_trade_runtime_test.gd`

## Effect Runtime 接入

科技研究、发现、前置条件和完成位仍归 `NativeCountryRuntime` 所有。完成
科技后，原生运行时建立稳定的 `(country_handle, technology_dense_id)`
Effect instance；`technology.modifier` 在 Effect safe boundary 生成已有的
Modifier apply command。Modifier definition key 继续由科技目录编译，未在
Effect 目录中复制一份数值配置；PKCN 仍只保存科技权威状态，PKEF 保存
Effect instance/transaction。
