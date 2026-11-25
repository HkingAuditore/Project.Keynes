# 审美设计 / 剪纸撕纸手绘风格

## 1. 风格基准

唯一正确方向：**剪纸 / 撕纸 / 手绘的纸片仪表**。玩家读到的应该像一本被剪贴、撕边、手写批注过的科学文明档案，而不是深墨黄铜的历史地图集，也不是通用 SaaS 仪表盘。

旧 `UI_ART_DIRECTION.md` 的「深墨 / 胡桃木 / 羊皮纸 / 黄铜、参考文明7 / EU5 / V3 / CK3」章节**已废弃**。`scripts/ui/ui_tokens.gd:273-298` 的主色板仍残留旧方向，改动时以资产实际风格为准，不要照着旧色板继续堆。

判据：新界面里必须能看到**纸的边缘**（撕边、毛边、九宫格纸纹理）或**手写笔触**，而不只是米色背景加圆角卡片。

## 2. 既有资产（先接线，再新造）

| 类别 | 路径 | 说明 |
|---|---|---|
| 撕纸便签 | `assets/ui/paper_aux_v1/torn_note_v1.png` / `.tres` | 主题 `PaperPopup` 的底图 |
| 纸片纹理 | `assets/themes/player_session_theme.tres`、`menu_atlas_theme.tres`、`family_workspace_theme.tres` | 41 个 `StyleBoxTexture`，`PK*` variation 的单一真源 |
| 语义图标 | `assets/icons/paper/*.tres` | **332 个**，必须用于数据编码而非仅装饰 |
| 剪纸浮雕 | `shaders/papercut_relief_map.gdshader`、`scripts/ui/components/papercut_atlas_backdrop.gd` | 地图预览与背景层 |
| 军事剪纸图集 | `assets/military/papercut/military_atlas_v1.png` + `regions.json` | 41 个区域，历史实测仅 7/41 生效 |
| 纸皮主题族 | `assets/ui/` 下 13 个子目录 | `paper_hud`、`dossier_shell`、`archive_material_v1`、`ideology_paper_v3`、`era`、`annual_chronicle`、`family_workspace` 等 |
| 手写字体 | `assets/fonts/` | `Muyao-Softbrush-2.ttf`、`PFanHuTuTi_Min.ttf`、`SweiGothicLegCJKsc-*`、`NotoSerifSC-SemiBold.otf`、`SourceHanSerifCN-Regular.otf` |

**引用率核查**：资产存在 ≠ 上屏。2026-11-05 实测 558 个资源中总体 81% 有引用，但 `assets/ui` 仅 **57.1%**（196 个里 84 个未上屏）、`assets/military/papercut` **0%**、`family_workspace/bitmap` 18 个 `.tres` 中 **16 个零引用**（region 坐标本身合法，断链在 UI 消费侧）。每次做完界面，用资产文件名反查 `.gd` / `.tscn`，给出未引用清单。

## 3. 样式接线（最高频缺陷）

主题里 `PK*` variation 指向 `StyleBoxTexture`（`player_session_theme.tres:1005-1018` 的 `PaperPopup` 用 `torn_note`，32px 九宫格边距、8/10px 扩展边距）。

**硬规则**：设了 `theme_type_variation` 之后禁止再用运行时 stylebox 覆盖同一节点的 `panel`。

```gdscript
# 正确（参见 scripts/ui/components/military/military_building_row.gd:101-106）
var panel := PanelContainer.new()
panel.theme_type_variation = &"PKPaperPopup"
panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

# 错误：下一行把撕纸边顶成圆角纯色板
panel.add_theme_stylebox_override("panel", _tooltip_panel_style())
```

真实反例（2026-11-05 已修）：
- `scripts/ui/components/military/military_unit_roster.gd:181,188` —— 同函数内先设 variation 再 override。
- `scenes/ui/cell_hover_card.tscn:77-78`、`building_hover_card.tscn:60-61` —— `.tscn` **同节点** `theme_type_variation` + `theme_override_styles/panel`（扫描脚本最容易漏的形态）。
- `scripts/ui/components/ideology_workspace.gd:558..927` 6 处 + `ideology_workspace.tscn` —— 主界面 chrome 整批架空主题。
- `scripts/ui/components/ideology_slot_niche.gd:251,503-506` —— **跨函数**覆盖，最隐蔽。

统计背景：全库 `add_theme_*_override` 951 行 / 66 文件、硬编码 `Color(...)` 918 行。规范里写了的 `UITokens.make_player_theme()` / `button_style()` 在工程中并不存在——不要引用不存在的 API，先读 `ui_tokens.gd`。

## 4. 字体与排版

- 面板标题 18–22px；主数值 20–26px；次级标签 12–14px；长说明短行、不写密集段落。
- 中文数字用 `UITokens.format_compact_number_cn()`（`1.25万`、`3.56亿`），禁止 `k` / `M` / `B`。
- 手写体用于标题 / 批注 / 印章，正文与数值用可读性更高的字体；小字号手写正文不可读。
- 短标签与右对齐数值显式 `AUTOWRAP_OFF`。注意 **Godot `Label` 默认就是 `AUTOWRAP_OFF`**；项目里 69 处显式 `WORD_SMART` 才是折行风险源。别把「没写 OFF」当缺陷（2026-11-05 曾据此误判 29 条）。

## 5. 图标

- 用 `IconCatalog.resolve_key()` / `IconBadge` 的语义键；映射集中在组件内，不在 view model 里散落码点。
- 禁止 Unicode / emoji 占位：`△ ☼ ♣ ◆ ▲ ▼ ◀ ▶ › — · 🔒 ⚙ ⚔` 等。**纯符号行没有中文，容易被可见性过滤判成 `code_only` 而漏扫**，扫描词表要显式包含符号。
- 语义色只做图标 / 边框 / 细侧边 / badge 边 / 图表线 / gauge 填充；不要在大面积高饱和色上放文字。

## 6. 按钮与控件材质

- 必须有 normal / hover / pressed / active / toggled / disabled 六种可辨状态；active 不能只靠颜色区分，要结合边框强度、按下态、字重或图标。
- 全局状态从 Theme 取；不要在每个控件里手写 `StyleBoxFlat` 圆角色块。
- `paper_hud` / `dossier_shell` 等纸皮族已提供材质，先复用。

## 7. 验收自查

- [ ] 新界面能看到纸边 / 撕边 / 手绘笔触，而不只是圆角米色板？
- [ ] 没有 `theme_type_variation` 与 `panel` override 同时落在同一节点（含 `.tscn` 同节点、跨函数）？
- [ ] 用到的资产确实被引用；新增资产没有变成死资产？
- [ ] 图标全部来自 `IconCatalog`，没有 Unicode 占位？
- [ ] 颜色走 `UITokens`，文字对比度在纸底上可读？
- [ ] 字体层级正确，没有小字号手写正文？
