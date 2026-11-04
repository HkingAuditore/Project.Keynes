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
| 驻军条 | `present` / `post_count` / `pending_enlist` / `paused` / `disrepair` / owner≠controller | 手绘进度条 + 两端数字；状态只在成立时贴小签（征召/暂停/失修/占领） |
| 部队 | `armies[]`（handle、headcount、foreign） | 一行一支：番号 + 兵力；点行开军务档案 |
| 训练 | `training[]`（from/to、count、days_done、days_total） | 一行一单：目标兵种纸贴 + `目标兵种 ← 来源兵种` + 人数 + 进度条 + 剩 N 日 |
| 官营建筑 | `barracks_tiers` / `fort_tier` / `college_tier` / `construction_*` + 目录 | 三行：纸贴图标 + 名称（×座数）+ 效果 + 右侧一个动作键 |

兵种中文名取自编译目录 `catalog.units[i].name`，图标走
`IconCatalog.military_unit_semantic_for_id()`；建筑图标走 `military_building_semantic()`。
数字一律 `UITokens.format_compact_number_cn()`，不出现英文 k/M 或货币记号。

## 2. 三行官营建筑

顺序固定：**兵营 / 城防 / 军校**（`STATE_BUILDING_ROLES`，`role` 对齐 `MilitaryStateRole`）。

每一行由视图模型判定出**一个**动作，控件右侧只出现这一个纸片键：

| 判定条件 | 动作 | 命令 |
| --- | --- | --- |
| 该角色有在建工程 | `building`（在建 · 剩 N 日，无按钮） | — |
| 非本国领土 / 被占领 / 旧 DLL 无分档座数 | `unavailable`（无按钮，数据照显） | — |
| 没有该角色建筑，且存在已解锁档位 | `build`（建造） | `state.build` + 最高已解锁档下标 |
| 有建筑，且存在更高且已解锁档位 | `upgrade`（升级） | `state.build` + 最高已解锁档下标（原生按 `max(tier)` 生效） |
| 有建筑且已在最高可建档 | `demolish`（拆除） | `state.demolish` + 现档下标 |
| 没有建筑且所有档位都锁着 | `locked`（原位一枚锁纸贴，tooltip 写缺的科技） | — |

- **科技闸门**：目录每行的 `unlock_tech_id` 与 `CountryFacade.snapshot().technology_ids`
  比对；科技快照不可读时不过滤（宁可见不误藏）。
- **命令参数是整型 dense 下标**（`{cell, role, op, building:int}`），由
  `PlayerController` 再拦一次科技与领土，避免旧 UI 缓存越过门槛。
- 兵营允许叠加，但按钮只在"存在更高档"时给建造/升级；到顶档后转为拆除，不会无限刷同档。
- 战校在 `military_catalog.json` 里的 `national` / `national_extra` 字段没有被编译器编译，
  所以界面**不显示**它们（不写无法验证的效果）。

## 3. 交互

| 事件 | 结果 |
| --- | --- |
| 点部队行 | `GameUIManager.open_military_dossier("army", handle, 当前格)`，右栏变宽、地块目录列保留 |
| 点动作键 | 发 `military_state_building_requested` → `PlayerController.request_command`，结果复用营造反馈条 |
| 按下动作键 | 按钮先禁用，等下一次模型落地再解锁（防同日重复下单） |
| 每已提交日 | 750 ms 合并窗口内重算模型；结构不变就只 `set_model()`，不重建节点 |
| 切页/换格 | 整块重建（既有行为），滚动位置按页签恢复 |

## 4. 性能

- 打开页签 / 每日补丁：一次 `cell_snapshot` + 每日缓存一次的科技 id 列表；目录只在
  facade 身份变化时缓存重排。
- 绘制全是 `_draw()`：驻军条、部队行、训练行、三行建筑都自绘，只有三个动作键是真实
  `Button`；同一模型重复 `set_model` 节点数不变（`military_cell_ledger_test` 断言）。
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

截图输出在 `res://tmp/military_cell_tab_qa/`（424 px 与 604 px 两种页宽 × 常规 / 城防在建）。
两条踩过的坑写在代码注释里，改样式时别踩回去：

- 建筑名用 `sans_strong`，不要用 `serif`：显示字体在 15px 下缺「戍 / 砌 / 馆」这类字，会出方框。
- 三行建筑之间只留每行自己的手绘底线，不要再插 `MilitaryPaperRule`，否则两层线叠在一起。
