# 地块档案 · 军事页（驻军 / 部队 / 训练 / 官营建筑）

右栏地块档案的「军事」页签。整页是**一张撕纸台账**（`PKPaperNote`），自上而下读：
驻军条 → 当地部队 → 本地训练 → 手绘分隔 → 三行官营建筑。**页面上不写解释性句子**：
没有部队、没有训练、没有兵额时整组隐藏，只有快照读不到时留一行错误态。

```
CellInspectorViewModel._military_category(cell)
  → category = { "military_cell": { garrison, troops, training, buildings[3] } }
  → InspectorPanel._build_military_ledger()      （建一次节点）
  → MilitaryCellLedger.set_model()               （每日只写值）
```

## 1. 数据来源

一个只读查询 `get_military_cell_snapshot(cell, observer)`（字段见
`docs/cpp-dots-runtime/military-runtime.md` §6.1）+ 编译军事目录 `facade.catalog()`：

| 区块 | 读什么 | 画法 |
| --- | --- | --- |
| 驻军数据带 | `present` / `post_count` / `pending_enlist` / `barracks_tiers` / `college_tier`→训练速度 / `paused` / `disrepair` / owner≠controller | 手绘容量条（`在驻 12 / 兵额 50`）+ 第二行四格读数 `空额 / 征召 / 军营 / 训练 ×1.5`；状态只在成立时贴小签（暂停/失修/占领） |
| 部队 | `armies[]`（handle、headcount、foreign） | 一行一支：番号 + 兵力；点行开军务档案 |
| 训练 | `training[]`（from/to、count、days_done、days_total） | 一行一单：目标兵种纸贴 + `目标兵种 ← 来源兵种` + 人数 + 进度条 + 剩 N 日 |
| 官营建筑 | `barracks_tiers` / `fort_tier` / `college_tier` / `construction_*` + 目录 | 三行：纸贴图标 + 名称（×座数）+ 效果 + 成本段 + 右侧主键（悬停时另显拆除键，见 §2、§3） |

读数一律**照实显示（含 0）**：开局没有兵营时这一页也要看得到 `在驻 0 / 0`、
`空额 0 · 征召 0 · 军营 0 · 训练 ×1`，玩家据此判断缺的是容量、兵员还是军校。
"容量"取自 `post_count`（逐档兵营容量之和），"军营"是逐档座数之和（解释容量从哪来），
"训练速度"取自军校档位的 `training_speed`（无军校 = 1.0）。不写引导句，只给数字。

兵种中文名取自编译目录 `catalog.units[i].name`，图标走
`IconCatalog.military_unit_semantic_for_id()`；建筑图标走 `military_building_semantic()`。
数字一律 `UITokens.format_compact_number_cn()`，不出现英文 k/M 或货币记号。

## 2. 三行官营建筑

顺序固定：**兵营 / 城防 / 军校**（`STATE_BUILDING_ROLES`，`role` 对齐 `MilitaryStateRole`）。

视图模型为每一行判定**两个正交字段**，控件据此最多出现两个纸片键：

- `primary_action`：建设性动作，取值 `build` / `upgrade` / `rebuild` / `none`。
- `can_demolish` + `demolish_target`：破坏性动作，独立于 `primary_action`。

二者**不允许互相顶替**。旧实现把「拆除」塞进同一个动作位，玩家在到顶档后按下那颗键，
结果建筑被拆掉——这正是"点了不知道会发生什么"的根源。

| 判定条件 | `primary_action` | `can_demolish` | 命令 |
| --- | --- | --- | --- |
| 该角色有在建工程 | `none`（行内写「在建 · 剩 N 日」） | `false` | — |
| 非本国领土 / 被占领 / 旧 DLL 无分档座数 | `none`（数据照显） | `false` | — |
| 没有该角色建筑，且存在已解锁档位 | `build`（建造）→ 发 `state.build` + 最高已解锁档下标 | `false` | `state.build` |
| 有建筑，且存在更高且已解锁档位 | `upgrade`（升级）→ 同上 | `true`（可拆现档） | `state.build` / `state.demolish` |
| 兵营已在最高可建档 | `rebuild`（再建）→ 同档下标，叠加一座 | `true` | `state.build` / `state.demolish` |
| 城防 / 军校已在最高可建档 | `none` | `true`（只给拆除） | `state.demolish` |
| 没有建筑且所有档位都锁着 | `none`（原位一枚锁纸贴，tooltip 写缺的科技；行内照旧写出**最低一档**的名称与效果，不留空行） | `false` | — |

- **科技闸门**：目录每行的 `unlock_tech_id` 与 `CountryFacade.snapshot().technology_ids`
  比对；科技快照不可读时不过滤（宁可见不误藏）。
- **命令参数是整型 dense 下标**（`{cell, role, op, building:int}`），由
  `PlayerController` 再拦一次科技与领土，避免旧 UI 缓存越过门槛。
- **为什么只有兵营有「再建」**：原生 `barracks_count` 是逐档的计数数组，兵额按
  `count × capacity` 累加，同档多座确实生效；城防与军校在原生侧是单值取最大档，
  叠加没有意义，所以到顶档后不给这个入口。
- **`demolish_target` 不能复用 `target`**：可升级时 `target` 指向更高档，拿它去拆除
  会拆掉一个还不存在的档位。两个字段分开存，是这条规则的实现落点。
- 战校在 `military_catalog.json` 里的 `national` / `national_extra` 字段没有被编译器编译，
  所以界面**不显示**它们（不写无法验证的效果）。

### 2.1 建材成本从哪来，以及为什么不做经济侧双写

成本是**目录里的权威值**，不是按经济目录现算的：译者把 `materials` 折成 dense 的
`material_goods` / `material_qty`（`military_catalog_compiler.gd`），门面的
`state_building_materials(index)` 把 dense id 还原成 `{good_id, qty}`（qty 为
GOODS_SCALE，1000 = 1 单位）。视图模型只做排版，不再回查经济目录。

结算边界必须说清楚，否则界面会显示一个不会真正扣掉的价格：

- 军事 `state.build` 目前是 **cash-only**（`military_core.cpp` 的 `MCMD_STATE_BUILD`
  注释写明）：它按 `MILITARY_GOODS_SCALE` 把建材折算成现金估值，经
  `MILITARY_INTENT_SPEND_CASH` 记账，并记录完成日。
- 经济侧的真正建材结算走 `TREASURY_SPONSORED_BUILD`，但那条路径要求目标建筑在
  **经济目录**里有同名类型；当前经济建筑表里没有官营建筑，所以
  `state_buildings[i].economy_building_id` 恒为 `-1`（`_index_optional` 未命中）。
- 因此**不能**在发出 `state.build` 后再补一条 `treasury_sponsored_build`：它会在
  `treasury_build_owner_signature` 处拿不到签名而立即 `construction_*` 拒绝，等于给玩家
  一个必定失败的二次请求。等经济目录真的定义了 `building_kind == "state"` 的类型，
  再把 `economy_building_id >= 0` 作为接入条件（门面已提供
  `state_building_economy_id()` 供这条判断使用）。

界面上的成本就是「这一座要吃掉多少建材」，并按国库可得量与本地市场可得量做卡点判断
（与营造提示卡同一口径）；现金那一栏显示军事侧此刻的现金估值。

## 3. 交互

### 3.1 行内信息与成本展示约定

每行固定两行文字（第三行状态位按需）：

| 位置 | 内容 | 缺省态 |
| --- | --- | --- |
| 第一行 | 建筑名（×座数，>1 才写） | 锁定时仍写出最低一档名称 |
| 第二行 | 效果（`+50 兵额` 之类） | 待确认态改写为「将拆除 · {名称}」 |
| 状态行 | 回执 > 成本 > 效果 的优先级 | 无回执时显示成本 |

成本段的格式是 `{建材} · {工期}`，建材最多列 3 项、超出写「等 N 项」，无建材写
「无需建材」。缺料或缺资金时，行内成本段改写为短因由（「缺建材」/「资金不足」）并转
OXBLOOD 色，主键禁用；完整的建材明细仍留在 `materials_text` 与 tooltip 里，玩家顺着
提示卡能看到差多少、差哪一样。

**行内截断只发生在行内。** tooltip 必须逐项列全，一种都不能省：

| tooltip 段 | 内容 | 说明 |
| --- | --- | --- |
| 名称 | 目标档名称 | 升级时是**要建的那一档**，不是现有档 |
| 效果 | 该档给的效果 | 与名称同档 |
| 建材 | 每种一行：`建材：名称 数量（国库 X / 市购 Y / 缺 Z）` | 缺料时才写「缺」 |
| 建材合计 | `建材合计：总量，缺 N` | 建材多于一种时追加 |
| 现金 | `现金：X（一次性）` | 原生按建材估值扣款，与建材不重复计 |
| 维护 | `维护：X/日` 或 `X/日（现有 N 座，共 Y/日）` | 见下 |
| 建成后维护 | `建成后维护：…` | 仅在它与「维护」不同的时候出现，见下 |
| 工期 | `工期：N 日` | 取目标档 |
| 卡点 | `卡点：缺建材` / `资金不足` | 仅在被卡时出现 |

维护成本取目录的 `upkeep`（每日货币单位），原生按 `barracks_count[tier] × upkeep_per_day`
逐档累加；城防与军校是单值取最大档。因此兵营多座时必须写出合计，单座时不写「现有 1 座」。
维护与「能不能下单」无关：已建成、在建、锁定之外的所有行都要显示它，玩家判断该不该留着
这座建筑靠的就是这个数字。

「建成后维护」是**下单这一刻**真正要回答的问题，三种情形分别写：同档再建写
`建成后 N+1 座，共 Y/日`；升级写 `升级后 X/日`（旧档被替换，不是两档相加）；首次建造
`建成后 X/日`。它与「维护」相同时不重复显示。

`barracks_tiers` 的下标就是目录的 `tier` 值（原生 `barracks_count[tier]`，`tier` 从 1 起），
下标 0 恒为空。现存档必须由这个下标反查目录行才能算维护；反查不到就说明没有可数的存量，
此时不能写出「现有 N 座」或「建成后 N+1 座」——那两个数字描述的存量并不存在。

**整行必须描述同一座建筑。** 升级行的名称、效果、工期、建材、维护统一指向目标档；旧实现
名称取现有档、报价取目标档，玩家会看到「戍卫营」却报着别的档的料，这是「不明所以」的
一个直接来源。

现金未知（`country_cash() < 0`）时跳过资金判断，只判建材，避免读不到国库就整行锁死。

提示卡走 `PKPaperPopup` 纸片样式 + `AUTOWRAP_WORD_SMART` + 390 px 版心，**不使用**原生
`tooltip_text`：原生提示只按最宽一行折、不保证竖向空间，建材三五项时会被压成一条横贯屏幕
的长句甚至被裁掉。两个纸片键各自覆写 `_make_custom_tooltip`（Godot 只问被悬停的控件，
不会代问父行），否则按钮会退回不换行的默认 TooltipPanel。

### 3.2 交互通道

| 事件 | 结果 |
| --- | --- |
| 点部队行 | `GameUIManager.open_military_dossier("army", handle, 当前格)`，右栏变宽、地块目录列保留 |
| 点主键 | 发 `military_state_building_requested` → `PlayerController.request_command`；回执（已排队 / 被拒理由）写回**刚按下的那一行**的状态行，3.5 秒后恢复成本或效果数字 |
| 按下主键 | 按钮先禁用，等下一次模型落地再解锁（防同日重复下单） |
| 悬停 / 聚焦行 | 拆除键才显形；离开即隐藏。**默认不显形**是刻意的：破坏性动作不该常驻在建设性动作旁边 |
| 首次点拆除键 | 不 emit。键文本变「确认拆除」，行内第二行改写为「将拆除 · {名称}」并转 OXBLOOD，3 秒内无第二次点击自动取消 |
| 二次点拆除键 | 取消确认态并 emit `demolish_pressed` → `state.demolish` + `demolish_target` |
| 键盘 | 两个键都是 `FOCUS_ALL`，Tab 可达；焦点进入等同悬停（拆除键显形），`Enter`/`Space` 触发同一次按下逻辑 |
| 每已提交日 | 750 ms 合并窗口内重算模型；结构不变就只 `set_model()`，不重建节点 |
| 切页/换格 | 整块重建（既有行为），滚动位置按页签恢复 |

踩过的坑：动作键背后是一条**真实命令**，命令侧必须经 `runtime_host.generator()`
取军事 facade（`WorldRuntimeHost` 只是宿主，本身没有同名访问器）。如果只问宿主，
每条玩家军事命令都会判成 `runtime_unavailable`——面板照样读得到数据、按钮却没
任何反应，是这一页最难查的故障。`player_controller_contract_test` 的
`military facade resolves through the host generator` 就是钉这条的。

## 4. 性能

- 打开页签 / 每日补丁：一次 `cell_snapshot` + 每日缓存一次的科技 id 列表；目录只在
  facade 身份变化时缓存重排。
- 绘制全是 `_draw()`：驻军条、部队行、训练行、三行建筑都自绘；按钮只有每行的主键 +
  拆除键（最多 3×2 = 6 颗，且拆除键常驻隐藏，不参与排版占位）。同一模型重复 `set_model`
  节点数不变（`military_cell_ledger_test` 断言）。
- 触摸档行高取 `TouchUI.dense_units()`，桌面保持 27/36/46px 原值。

## 5. 验证

```text
godot --headless --path Project/project-keynes -s res://tests/ui/military_cell_ledger_test.gd
godot --headless --path Project/project-keynes -s res://tests/military/military_dossier_test.gd
godot --headless --path Project/project-keynes -s res://tests/ui/inspector_responsive_layout_test.gd
godot --path Project/project-keynes --resolution 1920x1080 \
  -s res://tests/qa/military_cell_tab_screenshot_qa.gd
```

`military_cell_ledger_test` 覆盖：只产出 `military_cell`（旧 `metrics/gauges/military_context`
不再出现）、三行顺序、科技闸门（锁定无 target、解锁指向最高档）、现存档位与座数、在建剩余日、
训练进度与兵种名、部队 handle、动作请求形状、424px 目录列不溢出、以及重复补丁的节点数不变。
本轮新增断言：成本字段存在（`materials_text` / `cost_days_text` / `cost_cash_text`）、
「无需建材」分支（目录未配建材时不卡建造且提示卡写明）、缺料时 `cost_reason == "缺建材"`
且主键判不可点而建材明细仍保留、兵营到顶档 `primary_action == "rebuild"` /
`action_label == "再建"` / `demolish_target == 1`、拆除键默认不显形、首次按下只进待确认态
（不 emit）、二次才发 `state.demolish`、三条撤回路径（移开指针 / 新模型落地 / 超时）
都不发命令、主键与拆除键在 424px 行宽下互不重叠且文本区不被挤压。

提示卡完整性与维护成本（本轮补的回归点）：

- `materials_detail` 与 tooltip 逐项对应：四项建材的档位行内写「等 N 项」，tooltip 一种不漏并带「建材合计」。
- tooltip 必含「维护」段；两座兵营写「现有 2 座，共 X/日」，单座不出现「现有 1 座」的噪音。
- 升级行整行描述目标档：名称、`cost_days_text` 与提示卡同为目标档（先建 tier 1 再升级，断言 30 日而非 10 日）。
- 「建成后维护」按情形分写：同档再建写 `建成后 3 座，共 0.45/日`，升级写 `升级后 0.15/日` 且不得出现两档相加的 0.17。
- `barracks_tiers` 下标即目录 `tier`（1 起，下标 0 恒空）；夹具写成 `[1,0,…]` 会被读成不存在的档位 0，这类写法会让维护计算失去现存档。

截图输出在 `res://tmp/military_cell_tab_qa/`（424 px 与 604 px 两种页宽 × 常规 / 城防在建 / 开局三态）。
两条踩过的坑写在代码注释里，改样式时别踩回去：

- 建筑名用 `sans_strong`，不要用 `serif`：显示字体在 15px 下缺「戍 / 砌 / 馆」这类字，会出方框。
- 三行建筑之间只留每行自己的手绘底线，不要再插 `MilitaryPaperRule`，否则两层线叠在一起。

## 6. 营造窗口的「军事」部门

官营建筑**同时**出现在建筑页签的营造窗口里，作为部门索引签的最后一格「军事」
（`CONSTRUCTION_MILITARY_SECTOR`，`CellInspectorViewModel.build_construction_model`）。
两个入口共享同一套数据与同一条命令，区别只在呈现：

| | 地块档案 · 军事页 | 营造窗口 · 军事部门 |
| --- | --- | --- |
| 粒度 | 每类角色一行（兵营/城防/军校），显示该格现存档位与一个动作 | 每座建筑一行（17 座全平铺），可搜索、可排序、可分页 |
| 数据源 | `facade.cell_snapshot` + 目录 | 同左 |
| 可建判定 | 科技 → 在建 → 有无更高档 | 科技 → 在建 → 该档已建成（仅城防/军校）→ 建材/现金 |
| 命令 | `state.build` / `state.demolish` | `state.build`（条目带 `military_index`，走同一路口） |

**为什么军事建筑不进经济部门循环**：营造窗口的民用部门全部来自经济目录
（`construction_candidates` / `construction_quotes` / `building_sector_ids`），而经济目录
没有 `building_kind == "state"` 的建筑类型——`data/economy/buildings/` 下 442 份档案
无一带 `state_role`。若为了「让它出现在目录里」而给 17 座建筑各造一份经济档案，会撞上
三条硬约束：`building_technology_binding_must_be_single`（每座经济建筑只能绑一个科技）、
`technology_content_binding_audit_test` 的 `_assert_required_bindings`（每座经济建筑都要有
科技绑定）、以及经济侧就业/生产/投资系统对 `kind == 3` 的 state 分支接管
（`economy_runtime_building_employment.cpp:528` 等）。因此军事部门**读军事目录**，
在营造窗口里自成一体，不写经济档案。

**方向性差异（刻意）**：军事页的主键是「建设性动作」，到顶档给「再建」；营造窗口是
「目录」，每一座建筑都是独立条目，因此兵营同档可再建（原生 `barracks_count[tier]` 是计数
数组），城防/军校同档会写「该档已建成」（原生 `std::max` 覆盖，叠加无意义）。

**成本口径**：复用 `_state_building_cost()`，但整部门共用一次国库与市场快照
（`treasury_cache` / `market_cache` 参数），避免 17 座各拉一次。现金估值必须与原生同口径：
`material_qty * MILITARY_MONEY_SCALE / MILITARY_GOODS_SCALE = qty * 10`。早期实现按
`qty / 1000` 折算，界面报出的现金比真正扣掉的少 100 倍——这条换算写死在
`_state_building_cost()` 的注释里。

**入口计数**：建筑页签那张营造纸笺的「目录 N 项」把军事目录也算进去
（`_construction_military_count()`），但它只读缓存里的行数，不读国库/市场、不算成本。

