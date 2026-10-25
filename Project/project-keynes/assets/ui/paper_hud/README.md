# 彩铅剪纸 HUD 与原生控件材质

- `skin_source.png`：内置生图工具生成的原始 RGBA，包含横/纵纸质面板和四态按钮。
- `panel_*.png`、`button_*.png`：`tools/bake_paper_hud_skin.gd` 的切片/导入缩放输出。
- `control_icons/*.png`：`tools/bake_paper_control_icons.gd` 从 IconCatalog 纸贴生成的原生控件尺寸，
  复选框/单选 18 px，箭头 12 px，开关 32×18 px，滑杆手柄 14 px。
- `native-theme-manifest.json`：84 个 Godot 原生控件图标项的明确映射，两套主题各安装一份。
- `app_icon.png`：由 `tools/bake_paper_app_icon.gd` 从新家族纹章导出，供应用窗口使用。

玩家 Theme 与菜单 Theme 使用相同的控件图标素材。Checkbox/CheckButton/SpinBox 等的图标颜色保持白色调制，
禁用状态由透明度区分；不把彩铅图案染成原图标库的单色。
原生图标名已通过当前 Godot 4.6.2 的默认 Theme 查询，见 `.codex-tmp/full-paper-control-dump.log`。

此处只做 UI 导入尺寸与主题绑定，不绘制替代图案。艺术原图与完整提示词在
`assets/icons/paper/manifest.json` 和本目录 `manifest.json` 中保留。
