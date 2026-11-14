# 移动端 UI 缩放验收 harness

问题 1/3（安卓包「按钮特别小、点不中」）的验收工具。它在**真实窗口**里跑主菜单，
按尺寸档位截图并实测关键控件的 `get_global_rect()`，再换算成物理像素与 dp。

- 脚本：`tests/ui/mobile_ui_scaling_qa.gd`
- 像素对比：`tests/tools/image_diff.py`
- 缩放策略：`scripts/ui/mobile_ui_scaling.gd`（由 autoload `GameSettings` 持有）

## 运行

在 `Project/project-keynes` 目录下（console 版才有 stdout）：

```powershell
$godot = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"

# 1) 桌面档（= 改动前的行为，用于「1600x960 零回归」）
& $godot --path . --resolution 1600x960 -s res://tests/ui/mobile_ui_scaling_qa.gd -- `
    --out=test_output/mobile_ui/after --label=after_desktop --profile=desktop `
    --sizes=2400x1080,1600x960,1280x720

# 2) 移动档（在桌面上模拟 Pixel 3a：2220x1080 @440dpi）
& $godot --path . --resolution 2220x1080 -s res://tests/ui/mobile_ui_scaling_qa.gd -- `
    --out=test_output/mobile_ui/after --label=after_mobile --profile=mobile --dpi=440 `
    --sizes=2220x1080,2400x1080

# 3) 安全区 / 刘海（把安全区按物理像素设成「左边被挖 96px」）
& $godot --path . --resolution 2220x1080 -s res://tests/ui/mobile_ui_scaling_qa.gd -- `
    --out=test_output/mobile_ui/after --label=after_notch --profile=mobile --dpi=440 `
    --safe=96,0,2124,1080 --sizes=2220x1080

# 4) 设置里的 UI 缩放（80/100/125/150）是否只乘一次
& $godot --path . --resolution 2220x1080 -s res://tests/ui/mobile_ui_scaling_qa.gd -- `
    --out=test_output/mobile_ui/after --label=after_ui125 --profile=mobile --dpi=440 `
    --ui-scale=125 --sizes=2220x1080

# 5) 像素对比（before 目录 vs after 目录，可只比某个标签 / 或某个矩形区域）
python tests/tools/image_diff.py test_output/mobile_ui/before test_output/mobile_ui/after after_desktop
```

## 参数

| 参数 | 含义 |
| --- | --- |
| `--out=<目录>` | 截图与 `metrics_<label>.json` 输出目录（默认 `user://mobile_ui_qa`） |
| `--label=<名字>` | 文件名前缀 / metrics 标签 |
| `--profile=auto\|mobile\|desktop` | `mobile` 强制走触摸档（桌面模拟移动端）；`desktop` 强制桌面档（倍率 1.0） |
| `--dpi=<数字>` | dp 换算用的假设 dpi（真机由 `screen_get_dpi()` 上报） |
| `--safe=x,y,w,h` | 安全区覆盖（物理像素，屏幕坐标）。桌面模拟时默认按无刘海处理 |
| `--sizes=WxH,...` | 尺寸清单，默认 `2400x1080,2220x1080,1600x960,1280x720` |
| `--ui-scale=<80\|100\|125\|150>` | 设置里的 UI 缩放（persist=false，不会写用户存档） |

## 输出

- `<out>/<label>_<page>_<W>x<H>.png`：`home` / `new` / `load` / `settings` 四页 + 一帧 `hud`
  （顶栏 + 主操作栏，按 `player_game.tscn` 的锚点摆放）。
- `<out>/metrics_<label>.json`：每个关键控件的 `rect`（设计像素）、`px_*`（物理像素）、
  `dp_*`（按假设 dpi 换算）、`in_scroll`、`inside`（是否被裁）。
- stdout 末尾的 TSV 表格与 `failures` 计数；退出码 0 表示没有控件被裁/缺失。

## 读数须知

- 2200 行以上文本的 `dp` 一律按 `1dp = dpi/160` 物理像素换算；报告里的 440dpi 即
  `1dp = 2.75px`。
- `inside=false` 只对**不在 ScrollContainer 里**的控件算「被裁」；滚动容器内的控件
  只要求横向不出框（纵向由滚动条负责）。
- 主菜单背景是每次运行都随机重生成的装饰地图，且纸卷有 TIME 驱动的颗粒 shader：
  跨进程截图的像素差**不能**直接当回归判据（用同代码重跑做噪声对照）。
  布局回归请看 metrics 表（矩形完全一致）与静态区域（HUD / 读档 / 设置）的 0 差像素。

---

# 触摸命中区验收 harness（点得到 / 滚得动 / 关得掉）

缩放对了不等于点得中：`--profile=mobile` 只把整体倍率抬到 1.375，页签本身仍然只有
34 设计像素（17dp）。第二个 harness 专门量「命中区」：

- 脚本：`tests/ui/mobile_touch_targets_qa.gd`
- 命中区实现：`scripts/ui/touch_ui.gd`（+ `scripts/ui/components/touch_hit_button.gd`）

## 运行

```powershell
$godot = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"

# 1) 手机档（2670x1200 @440dpi，总缩放 1.375 → 1 设计像素 = 0.5dp）
& $godot --path . -s res://tests/ui/mobile_touch_targets_qa.gd -- `
    --out=test_output/mobile_ui/touch --label=after_touch --profile=mobile --dpi=440 `
    --size=2400x1080

# 2) 桌面回归（同一份代码，TouchUI 应当全程 no-op，尺寸与改动前逐像素一致）
& $godot --path . -s res://tests/ui/mobile_touch_targets_qa.gd -- `
    --out=test_output/mobile_ui/touch --label=after_desktop --profile=desktop --dpi=96 `
    --size=1600x960
```

## 判据

| 档位 | 目标 | 覆盖对象 |
| --- | --- | --- |
| `chrome` | ≥ 44dp | 页签、关闭/返回、下拉、搜索框、列表行、主操作按钮 |
| `dense` | ≥ 36dp | 密集数据网格方格、政策滑条行（44dp 会把一屏数据撑成三屏） |
| `scrollbar` | ≥ 32dp | `ScrollContainer` 滚动条宽度 |

`hit_dp_h` 是**真实可点高度**：本体矩形 + `touch_hit_button` 通过 `_has_point` 扩展出来
的上下命中带。页签还会跑一次**输入注入**（`纸签命中带-真实点击注入`）：往「纸签本体之外、
命中带之内」的点 `Input.parse_input_event()` 一次按下+抬起，`tab_selected` 必须真的触发。
`Control.has_point()` 在 Godot 4 没有暴露给脚本，所以只能走输入管线验证。

`must_visible` 的探测（关闭/返回、面板本体）额外要求 `visible_in_tree()` 且整块落在视口内；
hidden 的探测记 `skipped:"invisible"`（隐藏控件不参与布局，尺寸不可判）。

## 输出

- `<out>/<label>_<case>.png`：`economy` / `pause` / `technology` / `colonization` /
  `era_reward` / `family_founding` / `annual_report` 各一张。
- `<out>/touch_metrics_<label>.json` + stdout TSV：`w/h`（设计像素）、`dp_*`、`hit_dp_h`、
  `tier`、`expected_dp`、`pass`、`inside`（是否整块在视口内）。
- 退出码 0 = 全部达标；1 = 有未达标项（逐条打印）。
- `--debug-layout`：暂停菜单布局插桩（排查「按钮被压扁」这类容器塌陷）。

## 首轮实测结论（2026-11-01，2400×1080 @440dpi，dp_per_unit=0.5）

- `_has_point` 命中带**真的参与拾取**：注入点在纸签外侧（`inside_visual_rect=false`），
  `tab_selected` 仍然触发 → 纸签保持 56 设计像素（28dp）的视觉，命中带 88（44dp）。
- 修掉两个真回归：
  1. `pause_menu` 触摸档把 `Rows` 塞进 ScrollContainer 后，ScrollContainer **不会**在非滚动轴
     撑满子节点（按钮塌成 8px 宽）；必须给子节点 `SIZE_EXPAND_FILL` 并在 `resized` 时对齐宽度。
  2. `annual_reader_view` 页脚按 `AnnualReportTokens.FOOTER_HEIGHT`(40) 预留，但触摸档按钮
     88 高 → 页脚整块溢出屏幕下方 48px，「关闭」点不到。改为 `maxf(令牌, 页脚最小高)`。

## 桌面回归口径

桌面档（`--profile=desktop`）下 `TouchUI.is_touch()` 恒为 false，`watch()` 立刻返回，
所以本 harness 在桌面档只记录基线尺寸、不做 44dp 判定：`pass` 恒为 true，
`touch_metrics_after_desktop.json` 与改动前的 `metrics_*.json` 可直接逐项对比。

