# 军务档案（右栏部队页 / 战线页）

地图上点部队棋子或战线纸带，右侧档案面板切到对应的「军务档案」。它与地块档案、
对象详情共用同一个 `InspectorPanel`（`UIRoot/PanelLayer/RightPanel`），因此共享页头、
加宽分栏、开合动效与 ESC 关闭。

```
点击地图 (tile_tapped)
  → PlayerController._on_tile_tapped
      ├ 部队指令模式 → 目标格预览（固定确认键提交）
      ├ MilitaryMapLayers.pick_at_world(world)
      │    ├ MilitaryArmyTokenLayer.pick_army_at  （棋子半径，迷雾门控）
      │    └ MilitaryFrontLayer.pick_edge_at       （边中点在 0.42×hex 内）
      ├ 命中 → GameUIManager.open_military_dossier(kind, id, cell)
      └ 未命中 → select_cell(cell)                （地块档案不变）
```

## 1. 材料与动效

- **一张撕纸**：整页是一张 `PKPaperNote` 手撕纸（毛边 + 纸纤维投影），压在档案页上。
  卡片不再各套一个方框，段落之间只用手绘分隔线（`MilitaryPaperRule`：起笔墨点 + 确定性抖动）。
- **剪纸标签**：段标题是 `PKPaperTag`（右侧斜切的剪纸小标签），贴纸徽记用军事纸贴图标。
- **手绘**：所有横线、旗标中线、比例带描边、量尺轨道都由 `MilitaryPaperStyle` 画，
  带确定性抖动（同帧重绘稳定，不会闪），两端收敛成起笔/收笔。
- **入场动效**：整页先淡入（0.16s），随后每个内容块按 45ms 间隔依次落下
  （alpha 0→1、轻微旋转 -0.35°→0、纵向 0.985→1，0.20s）。数值由 KPI 卡片自己补间，
  比例带与对阵条从中缝/左端起生长。`UIAnimation.reduced_motion()` 下全部直出。

## 2. 部队档案（数据层级）

页头（`部队档案` + 番号 + `格名 · 归属国 · 姿态`）之下先放固定指挥区：当前任务、定位/行军/区域控制/停止任务、姿态与选点草稿。其余战力和后勤内容滚动阅读；交互契约见 [部队指挥交互](military-army-controls.md)。

| 块 | 内容 | 组件 |
| --- | --- | --- |
| **战力三联** | **攻击 / 防御 / 速度**——三者平级：同一行、同一 26px 字号、同一墨色、同一基线 | `MilitaryPeerStats`（自绘） |
| 状态读数 | 兵力（人）/ 士气（%）/ 补给（%+口粮）/ 军饷（%） | `DossierKpiCard` ×4 |
| 编成 | 按「兵种 + 品阶」分段的比例带 + 图例（人数），最多 6 段 | `DossierStackedBar` |
| 补给 | 6 类可支撑天数横条，7 日警戒刻度 | `DossierBarList` |
| 状态 | 交战 / 缺粮 / 欠饷 / 士气低（0–4 枚剪纸徽记） | `BadgeRow` |
| 行军 | 一行 `行军 · 剩 N 格`（不在行军则整行隐藏） | `Label(PKDossierCaption)` |
| 固定指挥区 | 定位 / 行军 / 区域控制 / 停止任务、姿态、预览/确认/取消 | `PKMilitaryCommandButton` + 容器 |
| 同格部队 | 只在同格 >1 支时出现，点行切页 | `DossierLedgerTable` |

硬规则：**攻击、防御、速度不得被写成"主数据/副数据"**（上一版把攻击做成大数、
防御塞进小字、速度根本不显示，已删除该写法）。编成不再同时给"比例带 + 名录表"，
图例承担名录职责；「完好」这种形容词列已删除。

## 3. 战线档案（对阵表）

页头之下是**一张对阵表**（`MilitaryVersusChart`），这是本页唯一的数据可视化：

```
          我方                     敌方
 兵力     1000   ▉▉▉▉▉▉|▉▉▉   600
 攻击     12.4   ▉▉▉▉▉ |▉▉    8.1
 防御      8.1   ▉▉▉   |▉▉▉▉   9.4
 士气      60%   ▉▉▉   |▉      40%
 补给      55%   ▉▉▉   |▉▉     62%
```

- 五行同指标并排，双方以中缝为界向两侧生长；每行的条归一化到「双方较大值」，
  读的是"谁更多"，不是绝对值大小。
- 数值直接标在两侧（我方右对齐、敌方左对齐），标题行只写 `我方 / 敌方`，
  国名放在页头副标题。
- 数据来源：兵力来自渲染快照（受迷雾门控，看不见的敌人不计）；攻击/防御按部队求和、
  士气/补给按兵力加权，单侧最多读 12 支部队（`facade.army()`，模型构建时一次）。
- 页脚一行：`推进 62% · 交战 3 段 · 接触 9 边`。

下表：**在场部队**（番号 / 兵力 / 攻击 / 归属，点行切到该部队档案）、
**交战段**（区域 / 进度 / 攻方，点行定位）、`定位` 按钮。

**没有的东西（上一版有、已删除）**：战线断面图（每条边一根条的装饰性图表）、
士气/组织圆环、"接触边/推进度/在场兵力"KPI 带（数值改由对阵表与页脚承担）。

## 4. 面板行为

| 事件 | 结果 |
| --- | --- |
| 点击部队棋子 | 520 设计像素单页，不携带地块目录，保留地图空间 |
| 点击战线纸带 | 沿用 `min(1040, max(860, 视口×0.62))` 分栏军务档案 |
| 战线面板宽度 ≥ 800 | 地块档案作为目录列保留；更窄时军务页独占面板 |
| 再点同一实体 | 部队保持档案与草稿；战线继续收起（toggle） |
| 点另一个实体 | 换页（身份变化才重播入场动画） |
| 点任意地块 | 关闭军务页，回到该格地块档案 |
| × / ESC | 关闭详情；有地块档案则回到目录列，没有则面板整体收起 |
| 发起「行军 / 区域控制」 | 保留档案，地图点击只做预览，固定确认键提交；右键/Esc 取消草稿 |
| 已提交日 | 200 ms 合并窗口内重建一次模型，只写值不建节点 |

## 5. 性能

| 操作 | 复杂度 | 频率 | 预算 |
| --- | --- | --- | --- |
| 拾取 | O(armies) + 42 条边 | 每次点击 | p95 ≤ 0.12 ms |
| 战线边集合 | O(front_edges) | 开页 + 前线变化 | ≤ 3.5 ms |
| 扇区 BFS | O(≤96 边 × 6) | 同上 | ≤ 0.3 ms |
| 部队页模型 | 1 × `facade.army()` | 开页 + 每日合并 | p95 ≤ 1.5 ms |
| 战线页模型 | 扇区可见部队 ≤ 24 × `facade.army()`（有缓存） | 同上 | p95 ≤ 2 ms |
| 每日 patch | 只写文本 / 数组 | ≤ 1 次 / 200 ms | ≤ 0.25 ms |

刷新契约：同一身份只走值写入（`DossierKpiCard` 先比签名，`BadgeRow` 数量不变时走
`update_badges`），节点数在刷新前后必须相等（`military_dossier_test` 断言）。
入场动画只动 alpha / rotation / scale，不动 position（容器布局会覆盖它）。

## 6. 验证

```text
godot --headless --path Project/project-keynes -s res://tests/military/military_map_pick_test.gd
godot --headless --path Project/project-keynes -s res://tests/military/military_dossier_test.gd
godot --path Project/project-keynes --resolution 1920x1080 \
  -s res://tests/qa/military_dossier_screenshot_qa.gd
```

截图输出在 `res://tmp/military_dossier_qa/`（424 px 与 604 px 两种页宽 × 部队/战线）。
