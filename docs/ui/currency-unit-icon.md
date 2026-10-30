# 货币单位统一为金币图标

结论先说：玩家界面里**不再出现「¥ / ￥ / $ / 货币 / 元 / 货币单位」这类单位记号**。
金额只写数字本体，单位一律由 `assets/ui/country_status/Gold.png`（手绘纸贴金币，
1024×1024 RGBA）画在数字左边。唯一入口是 `scripts/ui/money_display.gd`
（`class_name MoneyDisplay`）。

## 一、扫描口径

扫描范围：`Project/project-keynes` 下全部 `*.gd / *.tscn / *.tres / *.json / *.cfg`
（排除 `.godot/`、`tmp/`、`test_output/`），共 2301 个文件。按五类记号逐条读命中行，
再人工判定「单位记号」与「概念词」：

| 记号 | 命中 | 属于货币单位 | 说明 |
| --- | --- | --- | --- |
| `货币单位` | 3（含 2 条注释） | 1 | 见第二节 C |
| `货币` | 54 | 11 | 其余是科技名「货币」、注释、GM 面板与家族说明 |
| `¥` (U+00A5) | 8 处 UI 文本 | 8 | 界面里真正在用的单位符号 |
| `￥` (U+FFE5) | 0 | 0 | 全项目没有 |
| `$` | 只出现在 GDScript 节点路径 `$Node` 与正则行尾锚点 | 0 | 没有 `$100` 这类金额写法 |
| `元` | 只出现在「元数据」「单位圆」「三元组」等复合词 | 0 | 没有「元」当货币单位的写法 |

也就是说：这个项目从来没有用过 `元 / ￥ / $` 当货币单位，实际载体是 **`¥` 前缀** 与
**「货币」二字后缀** 两种，共 19 处渲染点。

## 二、命中与处理

### A. `¥` 前缀（金额读数的单位）—— 改成「金币 + 数字」

| 位置 | 迁移前 | 迁移后 |
| --- | --- | --- |
| `scripts/ui/hud_status_view_model.gd` → `_money_text()` | `"¥" + 紧凑数字` | 纯数字；HUD 悬浮卡在读数左边放金币（`ValueIcon`） |
| 同上 → `_money_segments()` | 给每个构成段补 `¥` 前缀 | 不再补；改由 `DossierStackedBar.money_icon` 统一画 |
| 同上 → 收支合计 / 净额默认值 | `"¥0"` | `"0"` |
| `scripts/ui/economy_dossier_view_model.gd` → `build_cashflow()` | `income_text / expense_text / net_text` 带 `¥` | 去符号（`+61` / `−25`） |
| `scripts/ui/components/dossier/dossier_gdp_band.gd` → `_money()` | `"¥" + 数字` | 纯数字；主数字与「人均累计 / 日均」整句混排画金币 |
| `scripts/ui/components/dossier/dossier_trend_lines.gd` | 净额默认 `"¥0"`，右端净额带 `¥` | 默认 `"0"`；净额前画金币 |
| `scenes/ui/hud_status_card.tscn` | `NetValue` 默认文本 `"¥0"` | `"0"`，并新增 `ValueIcon` / `NetIcon` 两个 `TextureRect` |
| `scripts/ui/components/hud_status_card.gd` | 直接显示带 `¥` 的读数 | 挂金币图标；人口页（人数）不显示 |

### B. `货币` 字样（单位后缀）—— 改成金币图标

| 位置 | 迁移前 | 迁移后 |
| --- | --- | --- |
| `tax_lane_editor.gd` → `_configure_spin_for_mode()` | `_spin.suffix = "货币"` | 后缀置空；行尾 `MoneyIcon` 节点亮起 |
| `tax_lane_editor.gd` → `_ready()` | `add_item("定额（货币）")` | `add_icon_item(金币, "定额")`（`OptionButton` 原生图标项） |
| `tax_lane_editor.gd` → `_format_value()` | `"%s 货币"` | 纯数字 |
| `tax_lane_editor.gd` → `parse_value_text()` | 硬编码 `.replace("货币", "")` | `MoneyDisplay.strip_unit()`，同时兼容 `¥ / ￥ / $ / 元` |
| `tax_lane_editor.gd` tooltip | 「定额税按货币计，单位：货币/人/天」 | 「定额税：每人每天缴纳的金额」 |
| `economy_workspace.gd` → `_configure_spin_for_mode()` | 同上（suffix / tooltip） | 同上，图标由 `_set_lane_money_icon()` 开关 |
| `economy_workspace.gd` → `_ensure_card()` | `add_item("定额（货币）")` | `add_icon_item(金币, "定额")` |
| `scenes/ui/object_tax_lane.tscn`、`scenes/ui/economy_tax_lane.tscn` | 无货币图标节点 | 新增 `MoneyIcon`（默认隐藏，定额模式显示） |

### C. `货币单位` 字样（说明文字）

| 位置 | 迁移前 | 迁移后 |
| --- | --- | --- |
| `scripts/ui/era_indicator_view_model.gd` → `per_capita_gdp_tooltip` | 「…与年度 GDP 使用相同货币单位。」 | 「…与年度 GDP 同口径（读数前的金币图标即单位）。」 |

### D. 保留未改（附理由）

| 位置 | 原文 | 保留理由 |
| --- | --- | --- |
| `scripts/ui/annual_report_view_model.gd` 原始账目脚注 | 「金额单位为 1/10000 游戏货币」 | 这是**纯文本**（年报全文 / 剪贴板导出）里的精度说明，`[img]` 内联不进去；改词反而丢精度口径 |
| `scripts/ui/debug_console.gd` GM 提示 | 「增加到玩家国库的货币数量」 | GM 面板的概念描述，不是数值旁的单位记号 |
| `scripts/game/world_runtime_host.gd` | GM 命令名「从阶层销毁货币」 | 同上 |
| `data/technology/technology_network.json` | 科技名「货币」「商品货币与集市」「货币知识整合」 | 内容文本（科技树节点名），不是单位 |
| `data/economy/family_official_buffs.json` | 解锁条件「国家已解锁“货币”」 | 引用科技名 |
| 多处 view model 注释 | 「金额单位为 1/10000 货币」 | 代码注释，说明原生定点数口径 |

## 三、统一方案：`MoneyDisplay`

一个图标源 + 三种联排，覆盖项目里全部三种渲染层：

```gdscript
MoneyDisplay.ICON                     # preload 的 Gold.png
MoneyDisplay.ICON_SCENE               # res://scenes/ui/money_icon.tscn（容器行用场景，禁止脚本 new Control）
MoneyDisplay.icon_size(font_size)     # 字号 → 图标边长（1.05×，最小 12px）
MoneyDisplay.strip_unit("+¥61")       # → "+61"；也摘「货币 / ￥ / $ / 元」
MoneyDisplay.draw_on_baseline(...)    # 自绘图表：按基线画，返回占位宽度
MoneyDisplay.bbcode(13)               # RichTextLabel：[img=14x14]…[/img]
MoneyDisplay.bbcode_value(text, 13)   # 富文本「金币 + 数值」
MoneyDisplay.apply_icon(rect, 13)     # 把场景里的 TextureRect 配成金币（尺寸/居中/鼠标策略）
```

尺寸取 `1.05 ×` 字号、下限 12px：图标的可见金币只占画布约七成（外圈是纸边），
所以这个倍率下金币直径正好贴着数字的 cap height，再大就会压过数字本身。
`Gold.png` 的导入已开 **mipmap**（`mipmaps/generate=true`），缩到 12px 图例里也不抖。

1. **容器行（Control 场景）**：`scenes/ui/player_top_bar.tscn` 的
   `CountryStatus/TreasuryButton/Row/{Icon, TreasuryValue}` 就是原型——
   `HBoxContainer` + `TextureRect` + `Label`，图标 `expand_mode=IGNORE_SIZE`、
   `stretch_mode=KEEP_ASPECT_CENTERED`。HUD 悬浮卡与税额行照这个结构加节点；
   需要现成的图标节点就实例化 `scenes/ui/money_icon.tscn`（玩家 UI 不允许脚本
   运行时 `new` 出 Control，见 `tests/ui/ui_scene_structure_test.gd`）。
2. **自绘图表**：`dossier_chart.gd` 里三个入口，全部按字号自动摆图标：
   - `_money_text(pos, text, size, color, kind)` —— 基线左端画「金币 + 数字」；
   - `_money_text_right(right_x, baseline_y, ...)` —— 整段右对齐（堆叠条合计、净额）；
   - `_mixed_line(pos, runs, size, color)` —— 整句混排，`runs` 里放
     `MoneyDisplay.MONEY` 就在该处插一枚金币，用于「人均累计 [金币]12.3万 · 日均…」。
3. **富文本**：`MoneyDisplay.bbcode(font_size)` 产出 `[img=WxH]res://…[/img]`，
   需要把图标内联进整句说明时用（`RichTextLabel.bbcode_enabled = true`）。

图标是手绘纸贴、带一圈纸边，所以**永远保持原色**（`modulate = Color.WHITE`），
不要按语义色染色。

## 四、顺带覆盖的金额读数

原来「只写数字、没有任何单位」的金额读数，凡是能声明「这一格是金额」的渲染层，
都补上了金币（否则同一页里有的金额带图标、有的不带）。声明方式统一成两种：

- **表格**：列定义里写 `"kind": "money"`（`DossierLedgerTable` 新增的列类型，
  右对齐 + 数字前画金币 + 超宽时先截数字再留图标宽度）。已改的列：
  阶层「人均收入 / 人均支出」、城市「人均收入」、产业「营收 / 日」、
  总览收支明细「税基 / 实收 / 补贴申请 / 补贴实付」、贸易「进口额 / 出口额 / 关税」、
  家族成员账本「个人净资产 / 周期净收支」、商队订单「单价」。
- **数据里标 `"money": true`**：
  - `InspectorFactGrid`（地块档案事实表）：居民存款、商家现金、贸易净额、库存估值、
    商业资产、采购毛利、本地年度产值、人均年度产值、本期利润、个人净资产、周期净收支；
  - `MetricCard`（财政摘要卡，新增 `set_data(..., money := false)`）：
    国库现金、昨日税收、补贴缺口、昨日进口额 / 出口额 / 净出口、关税净收入；
    补贴兑现率是百分比，不配金币。
- **自绘图表**：`dossier_kpi_card`（`kind == "money"` 自动配图标，含差值行）、
  `dossier_spark_value`（人均产值读数与日变化）、`dossier_stacked_bar`
  （`set_segments(..., money_icon := true)` 的合计与图例）。

## 五、仍未带图标的金额

这些位置金额嵌在**整句散文**里（前后跟着「营收 / 扶持 / 亏损」等词），一枚行首图标
会被读成「金币 营收 1.2万」，所以这次没有强塞：

- `industry_page.gd` → `_mix_bar` 的合计（「营收 %s + 扶持 %s · 亏损 %s」）；
- `object_detail_dialog.gd` → 阶层「日均开销 %s/人」、「现金 %.2f」等 Label 文案；
- `family_workspace.gd` → 「人口 %s · 现金 %s · 建筑 %s」这类混排副行。

要推进的话，最小改动是把这些 Label 换成 `RichTextLabel`（`fit_content = true`）并用
`MoneyDisplay.bbcode_value(text, font_size)` 拼串。

## 六、踩过的坑：`OptionButton` 的 item 图标按原生像素算尺寸

第一版把 `Gold.png`（1024×1024）直接喂给 `OptionButton.add_icon_item()`，
下拉按钮的最小尺寸变成 **1100×1032**，税额卡片被撑成一张巨型纸，整页税收界面报废
（卡片最小尺寸从 284×191 变成 1284×3191）。

修复：`OptionButton` / 菜单类控件一律用 `MoneyDisplay.MENU_ICON`
（`Gold_Menu24.png`，由 Gold.png 用 LANCZOS 缩到 24×24）。这类控件**没有**图标缩放
参数，只能喂尺寸合适的图；`TextureRect` / `draw_texture_rect` / `[img=WxH]` 才有缩放。

## 七、验证

```
Godot_v4.6.2 --headless --path Project/project-keynes \
  --script res://tests/ui/hud_status_card_test.gd
Godot_v4.6.2 --headless --path Project/project-keynes \
  --script res://tests/economy/economy_dossier_view_model_test.gd
```

断言口径同步改为「读数不含 `¥`，`ValueIcon` 可见且贴图为 `MoneyDisplay.ICON`」，
金额文本断言从 `+¥61` / `−¥25` 改为 `+61` / `−25`。

渲染校验留了三张截图（临时脚本已删，图留在 `test_output/hud_status/`）：

- `money_icon_check.png` —— 顶栏国库悬浮卡：页头读数、两条构成条的合计与图例、
  当日净额，每个金额前都是一枚金币；
- `money_charts_check.png` —— 卷宗自绘控件：GDP 横幅（含「人均累计 / 日均」整句
  混排）、堆叠条图例、收支趋势净额、money 口径 KPI 与迷你趋势，人口那张 KPI
  没有金币（人数不是金额）；
- `tax_page_check.png` —— 税收页：卡片回到 284×191，下拉项「定额」是 24px 金币，
  定额行的输入框右侧亮起金币；「补贴兑现率 100.0%」不配金币；
- `ledger_money_check.png` —— 账簿金额列与事实表金额格。

已知观感问题：悬浮卡页头现在是「分类徽标（金币堆）+ 国库 + 金币 + 读数」，
两枚金币挨着。如果觉得重复，可以在 `value_money` 为真时把 `HeaderIcon` 收起，
让金币只出现在读数前——这属于设计取舍，这次没有擅自改。
