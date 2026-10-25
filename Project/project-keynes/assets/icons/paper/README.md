# 彩铅剪纸图标

通过内置 `image_gen` 生成，使用用户提供的 ToyEmpires 图标作为风格参考。
特点：粗黑铅笔轮廓、彩铅颗粒、少量设色、不规则白纸裁边、透明背景。
参考图仅用于风格引导，不作为游戏中的贴图直接使用。

## 覆盖范围

- 134 种物资，4 张图集。
- 45 种职业，2 张图集。
- 37 个自然资源语义图标，1 张图集。
- 17 个建筑类别，1 张图集。
- 26 个地图 HUD、二级图层与时间控制图标，另附纸质面板和四态按钮素材。
- 56 个通用操作、生活水平、税收、家族导航与科研状态图标，8 个近景告警，1 个理念封蜡。
- 8 个复选框、单选、开关和滚动握柄图案；玩家与菜单主题各绑定 84 个原生控件图标项。
- 按产物绑定的建筑图标由建筑类别纸贴和物资纸贴组合，首次显示后缓存。

总计 332 个原始图案、43 个明确复用映射，覆盖 375 个内置玩家语义键和 398 项按产物绑定的建筑图标。

`IconCatalog.PAPER_TEXTURES` 是运行时入口，既有语义 ID、registry 和 view model 不变。
`IconBadge`、`IconButton`、科研树、图表、地图活动标记都只绘制纸贴位图；没有图标字体回退。
主菜单、设置、地图栏、国家/经济/科研/理念/家族工作区、地块档案、按钮、标签和状态共用此目录。
未知键也使用同风格问号。旧 SVG/图标库/金属徽章文件保留为历史素材，不再作为玩家图标加载。
理念学派、科研领域与状态、家族场景直连纹章和近景告警均已接入中央目录。
原生控件使用 `tools/bake_paper_control_icons.gd` 从纸贴生成 12–32 px 的导入尺寸，
防止直接将大图集切片交给 CheckBox/SpinBox 导致最小布局膨胀。映射见
`assets/ui/paper_hud/native-theme-manifest.json`。应用窗口图标也复用新纸贴纹章。
纸质底板与按钮四态在 `assets/ui/paper_hud/`，由玩家主题统一引用。

## 素材与制作记录

- `*.png`：内置生图输出的原始 RGBA 图集。
- `*.tres`：Godot `AtlasTexture` 切片；保留源图像像素和 alpha，不重新绘制图案。
- `manifest.json`：语义 ID、初始完整提示词、实际行数和逐图标切片范围。
- `revision-prompts.json`：矿石/建筑/木板/蒸汽机等语义修正提示词。

生成图集不是精确像素网格。`tools/art/build_paper_icon_atlases.py` 分析透明间隙和
纸贴的连通边界，只生成切片元数据，避免邻格碎片进入图标，不修改 PNG。
更新源图集后运行该脚本，再由 Godot 导入。
`tools/art/prepare_paper_icon_manifest.py` 仅用于重新盘点并创建初始生成清单，
会重建 manifest；不要用它覆盖已经人工复核的排布记录。

验证：`tests/ui/icon_catalog_audit_test.gd` 检查资源、唯一语义、透明切片、
建筑类别差异与组合贴图缓存。`tools/preview_paper_icons.gd` 使用真实 UI 组件
输出六张完整目录预览到仓库 `artifacts/paper-icons/`，`all_ui.png` 为全部界面标识总览。
`tools/export_paper_icon_audit.gd` 输出逐项语义/材质审计到 `artifacts/paper-icons/full-ui/icon-audit.json`。
`tools/preview_paper_hud.gd` 通过正式玩家场景生成地图内 HUD 截图；文件名含
`terrain_no_fog` 的额外画面仅在该预览会话关闭迷雾，不改变正式对局设置或存档。
