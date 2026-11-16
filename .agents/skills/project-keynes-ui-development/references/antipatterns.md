# 反模式清单与误判教训

来源：2026-11-05 两次全量 UI 扫描（20 条机械规则 + 用户追加 2 条），全部反例来自本项目真实代码。规则可用 `scripts/audit_ui.py` 复现。

## 1. 规则表

| ID | 类别 | 定义 | 本项目真实反例 |
|---|---|---|---|
| P01 | 风格 | `PK*` theme variation 被 `panel` stylebox 覆盖 | `military_unit_roster.gd:181,188`；`.tscn` 同节点 `cell_hover_card.tscn:77-78`、`building_hover_card.tscn:60-61`；跨函数 `ideology_slot_niche.gd:251,503-506` |
| P02 | 风格 | 自造圆角纯色 `StyleBoxFlat` 而非纸纹理 | `player_ui_theme.tres` 21 个纯 StyleBoxFlat / 0 纹理 |
| P03 | 风格 | 硬编码 `Color(...)` / 十六进制绕过 `UITokens` | 918 行（v2 口径），`ui_tokens.gd` 定义之外的 375 行 |
| P04 | 风格 | 运行时 `add_theme_*_override` 架空集中 Theme | 951 行 / 66 文件；规范中的 `make_player_theme()` / `button_style()` 全工程不存在 |
| P05 | 风格 | Unicode / emoji 占位图标 | `colonization_planner_panel.tscn:139,160`、`military_workspace.tscn:180` 的 `▶ › ▼`；纯符号行易被「无中文」过滤掉 |
| P06 | 术语 | 内部量纲外泄 | 「百人日 / 每百人」、`annual_report_view_model.gd:227` 的 `1/10000` `1/1000` `1/65536`；v1 词表只报 0 条，补词后 11 条 |
| P07 | 术语 | 实现术语进玩家文案 | `economy_workspace.gd:387`「原生军事核心未就绪」、`dossier_gdp_band.gd:208`「原生汇总」、`national_procurement_slider.gd:139` |
| P08 | 术语 | 测试 / 临时 / 占位文案 | `world_setup.gd:36`「生成测试经济数据」、`scenes/main.tscn:208`「天气：晴朗」 |
| P09 | 术语 | 内部标识前缀出现在展示文本 | `debug_console.gd` 50/53 条为同一脚本刷屏，真正印进 tooltip 的只 `:1249` |
| P10 | 术语 | 英文数字后缀 `k/M/B` | 应用 `format_compact_number_cn()` |
| P11 | 排版 | **显式** `AUTOWRAP_WORD_SMART` + HBox 内短标签 / 数值 | 兵种卡「攻击」被 16px 图标挤成「攻 / 击」；注意 Label 默认即 OFF，未写 OFF 不构成问题 |
| P12 | 排版 | 固定数值最小宽 + 右对齐无 ellipsis | `military_spending_block.gd:402,:510` 长中文塞进 104px |
| P13 | 排版 | 硬编码 `separation` 字面量 | 652 行 / 20 种取值、含负间距；断点 token 零引用 |
| P14 | 排版 | 硬编码绝对坐标 / offset | 401 行 / 63 文件；另一轮口径统计为 1261 行 |
| P15 | 排版 | 硬编码字号 | 172 行；`FONT_TITLE/SECTION` 近乎零引用 |
| P16 | 信息 | 空态套话 / 占位 | 「无需…」「暂无…」「不计」「—」「读取中…」；`family_workspace.gd:1659` 56px × 8 处 |
| P17 | 信息 | 同函数多处百分比格式化（疑似同值重复） | 需人工复核，误报率高 |
| P19 | 交互 | `FOCUS_NONE` / `focus_mode=0` | 86 行 / 43 文件；合法边界仅地图覆盖层按钮 |
| P20 | 交互 | 布尔 `visible` 显隐替代屏幕栈 | 548 行（v2）/ 741 行（另一轮口径）；`dismiss_overlay_menu()` 12 分支 |
| P21 | 交互 | `_process` / `_physics_process` 逐帧 | 14 文件；每日 tick 重建节点树另见 `interaction-motion.md` |
| P22 | 内容 | **自证性 / 脚注式说明** | 「战力 · 条长按当前兵种集归一」（用户点名删除）、`era_indicator_view_model.gd:14` 人均 GDP 脚注、`annual_report_view_model.gd:227` |
| P23 | 内容 | **空态套话与空容器** | 「维护物资 无需额外消耗」、「暂无数据」、写死假读数、为不存在的数据保留 section title 或固定高度 |

## 2. 三条误判教训（比规则本身更重要）

### 2.1 P01 的 8 条脚本命中全部是误报
初版判据是「同一 `.gd` 函数块内既有 `theme_type_variation` 又有 `add_theme_stylebox_override("panel")`」。真实问题在：
- `.tscn` **同节点**覆盖（`theme_type_variation` + `theme_override_styles/panel`）；
- **跨函数**覆盖（variation 在 A 函数、override 在 B 函数）；
- **跨文件**覆盖（场景设 variation、脚本运行时改）。

修正后才找到 10 处新增 / 9 处确认 / 4 文件。**扫描规则必须覆盖 `.tscn` 节点块，不能只扫脚本函数块。**

### 2.2 P11 的 29 条命中全部是误报
初版判据是「HBox 内有 Label 但函数块未出现 `AUTOWRAP_OFF`」。**Godot `Label` 默认就是 `AUTOWRAP_OFF`**；项目里 69 处显式 `WORD_SMART` 才是折行风险源。兵种卡当时正是显式开了 `WORD_SMART` 才把「攻击」拆成两行。修正为「显式 WORD_SMART + HBox」后命中降到 14。

**不要把「代码里没写某个防御性调用」当成缺陷，先确认默认值。**

### 2.3 五个数字与另一轮统计全部不等
v2 口径：硬编码色 918 / override 951 / separation 652 / 硬编码坐标 401 / 布尔 visible 548；另一轮：379 / 933 / 614 / 1261 / 741。v2 自身可独立复现，差异逐项落在正则口径、是否含 `.tscn`、是否含注释、是否含 ext 文件。

**报数必须写口径与分母；不同口径的数字不可直接比较，更不可相加。**

### 2.4 整体误报率
2026-11-05 逐条复核样本内误报率 **61.2%**（463/757），P22/P23 专项 47.7%（201/421）。文案复核 396 条中真泄露 257、误报 139（35.1%）。

**机械命中 4240 条 ≠ 4240 个问题。** 扫描只是线索生成器，必须人工确认赋值链：中文字符串是否真的赋给 `text` / `tooltip_text` / `label` / `title` / `hint`，还是落在注释、日志、`print`、纯代码标识符、内部字典 key。

## 3. 判定边界

| 判为「真问题」 | 判为「必要信息，保留」 |
|---|---|
| 实现自述、图形脚注、单位括号注释 | 单位标注（`/ 人·日`、`%`、`件`） |
| 空态套话、破折号占位、写死假读数 | 禁用原因（`需研究 X 才能编入`） |
| 测试 / 临时 / 开发入口 | 后果提示（`次日生效`、确认弹窗） |
| 同一数值同屏重复 | 量程端点数值、图表刻度 |
| 内部量纲 / 缩放因子 | 结论性文字（真正回答玩家问题） |

`reason` 字段、`military_reason()` 之类的禁用原因一律保留；`经济系统尚未就绪，请稍后再试` 这类属边界项，需产品定状态文案表后再统一改写，不要单点硬删。

## 4. 已知扫描盲点

- **纯符号行**：`▶ › ▼ — ·` 没有 CJK，容易被可见性启发式判成 `code_only` 直接过滤。符号词表要单独维护。
- **跨文件语义**：「同一 key 被两个组件渲染」「标题与内容量纲不符」「循环写 4 个状态色却只写 1 个」「写死数量词与数组长度不符」「无数据伪造读数」——正则抓不到，必须读代码上下文。
- **桩场景注入链**：≤10 行的 `.tscn` 本身没问题，问题在父场景注入 text / theme 后是否补状态、换行、溢出策略。
- **运行时行为**：静态扫描无法验证闪烁、遮挡、焦点、快进重建，需截图 / 真机。

## 5. 使用方式

```bash
PYTHONPATH= python scripts/audit_ui.py --root <ROOT> --out <OUT>
```

读 `pattern_stats.md` 看分布，读 `player_visible_hits.md` 看玩家可见线索，再逐条打开源码确认。**不要直接把 CSV 当工单发给人**——先按「真问题 / 必要信息 / 误报」三分类。批量修复时再走 `scripts/build_workorders.py` 做无冲突分区。
