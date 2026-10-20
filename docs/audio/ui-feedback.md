# 卷轴与剪纸 UI 音效

Windows 沿用 `GameSettings -> GameAudio -> FMOD UI.bank`。进入主菜单即启用，
没有额外初始化步骤。总音量和静音继续由现有设置控制；暂停不暂停 UI 音效。
其他平台仍遵循 FMOD 基础接入的平台边界。

| 操作 | cue / FMOD event | 材质与声音 |
| --- | --- | --- |
| 普通按钮、下拉选项 | click / UI/Click | 克制的短促干响 |
| 页签、纪事翻页和章节跳转 | page / UI/Page | 真实纸页摩擦 |
| 打开菜单、国家卷宗、展开高级设置 | open / UI/Open | 较长、较厚的纸张展开 |
| 返回、合卷、收起 | close / UI/Close | 较短、反向纸页收拢 |
| 开始游戏、应用设置、确认 | confirm / UI/Confirm | 低沉的落印式轻敲 |
| 开关启用 / 关闭 | toggle_on、toggle_off / UI/ToggleOn、UI/ToggleOff | 音高和滤波不同的两种干响 |
| 滑块拖动后松手 | tick / UI/Tick | 很轻的短擦声 |

默认不给悬停、连续滚轮、每日数据刷新、程序赋值加音效。各 cue 有 45–120 ms
冷却，音频文件最长约 0.44 秒，控制连续点击时的叠音。

## 接线与扩展

`GameAudio` 初始化成功后拥有一个 `ui_audio_feedback.gd` 子节点。它仅在进入
场景时扫描一次已有节点，再监听 `SceneTree.node_added` 为动态控件连接信号；
不逐帧扫描。默认处理 `BaseButton`（包括 LinkButton / TextureButton）、
`OptionButton`、`TabBar.tab_clicked` 和 `Slider.drag_ended`。
鼠标与 `ui_accept` 按钮激活走同一条路径；不监听程序同步常用的 `toggled` / `value_changed`。

语义通过控件 `metadata/ui_sound` 指定，不依赖中文按钮文字：

```gdscript
button.set_meta(&"ui_sound", &"page")
button.set_meta(&"ui_sound", &"fold") # toggle_mode：开→open，关→close
button.set_meta(&"ui_sound", &"none") # 本控件及子控件不自动发声
```

`IconButton` 对返回、关闭、确认、设置等已有图标语义补充默认 cue。
主菜单、国家卷宗入口、公共页签按钮有明确覆盖；年度纪事的自绘封面与章节轨
只在接受点击时调用 `UIAudioFeedback.play_for`，不会因渲染或滚动刷新发声。
自绘控件可同样调用该 helper。手动调用 `GameAudio.play_ui(cue)` 的标准按钮应
关闭自动反馈，避免重复接线。

`pressed` 回调可能先隐藏面板；适配器在 `button_down` 记录可交互状态，只在
最终激活时播放，取消拖出不响。离树回调使用弱引用，释放的按钮不会留存。
每个 FMOD 单次实例启动后立即 release，由 FMOD 在声音结束时回收。

## 素材与构建

原始 CC0 文件、作者、许可链接及校验值见 [来源清单](../../Audio/Sources/UI/README.md)。
选用 Kenney Interface Sounds 与 StarNinjas 真实翻页录音；处理配方位于
`tools/audio/prepare_ui_sounds.py`。生成后运行 `Build-FMOD-Banks.cmd`。
8 个事件保存在原有 Studio 工程的 UI 文件夹和 UI Bank，Click 原 GUID 保持不变；
正式事件已替换原来的合成测试按钮音。音乐原型不受影响。

`Run-FMOD-Demo.cmd` 可分别试听八种声音与原有分层音乐。素材、元数据、Bank
均为小文件，按普通 Git 管理，无 LFS；Studio 本体仍为本地工具。

## 验证

使用 Godot 4.6.2，设置 `PK_FMOD_TEST=1` 后运行：

- `res://tests/ui_audio_feedback_test.tscn`：八事件、真实鼠标与 ui_accept、动态
  按钮、重复绑定、禁用/静音标记、程序赋值、开关两态、隐藏回调、暂停、冷却、
  实例归零，以及正式主菜单设置页的打开/返回。
- `res://tests/fmod_audio_smoke_test.tscn`：八事件、设置同步与主音量静音、音乐
  Tension 参数、循环及实例释放。可在隔离 Windows Release 导出中运行。

这两项不启动世界模拟。音效属于表现层，不修改经济数值、每日运行时或存档。
