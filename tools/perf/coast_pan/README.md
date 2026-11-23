# 海岸平移性能场景

`coast-pan-v1` 在正式玩家场景中运行。桌面、Android 和 iOS 共用地图、镜头和采样脚本。日常回归看完整水面，隐藏水面的两段用于判断水面绘制开销。首份参考来自 iPhone 16e。

## 运行

使用项目对应的 Godot、已经导入的游戏和为当前提交构建的 DOTS 扩展。使用 Mobile 渲染器和横屏，测试期间让游戏保持可见。桌面从仓库根运行（Windows PowerShell 中先设置 `$env:PK_MOBILE_SHADER_TIER="MOBILE_QUALITY_LOW"`）。

```sh
PK_MOBILE_SHADER_TIER=MOBILE_QUALITY_LOW godot --path Project/project-keynes \
  --windowed --resolution 1600x960 --rendering-method mobile -- --coast-pan
```

移动端使用专用应用标识与发布构建，正常启动测试包即可。Godot 导出预设的自定义特性 `coast_pan` 会启用与命令行相同的入口。Android 复制现有 Android 预设，添加该特性，改成独立包名，包含对应架构的 DOTS 库，按游戏正常流程导出。iOS 使用仓库中的 **iOS Coast Pan** 预设；在 Mac 上执行：

```sh
git submodule update --init gdext/godot-cpp
tools/perf/coast_pan/build_ios_libs.sh -j6
```

安装对应 Godot 版本的 iOS 导出模板，在预设里选自己的开发团队、唯一的测试包标识和横屏配置，导出 Xcode 项目，使用 Release 在手机上运行。复现旧 iPhone 基准使用 Metal。macOS 的 Metal 和 Android 的 Vulkan 可以各自保留独立基准。

每次运行写入新的 `user://coast-pan/<时间-进程号>/` 目录，包括四个 JSON、四张终点截图和 `outcome.txt`。桌面完成后打印绝对路径并退出；移动端保持前台。iOS 可在 Xcode 的 Devices and Simulators 下载测试应用容器，从其中查找 `coast-0.json`；Android 可以用支持读取应用数据的测试安装，通过 Android Studio Device Explorer 取回同一目录。

## 与基准比较

在 Mac、Linux 或 Windows 使用 Python 3.10+ 处理取回的结果目录。默认参考 [iPhone 16e 实测](iphone-16e.json)。给同一台设备一直使用相同的标签。

```sh
python3 tools/perf/coast_pan/report.py RUN_DIR --device iphone-16e
python3 tools/perf/coast_pan/report.py FIRST_RUN --device pixel-test --save pixel-baseline.json
python3 tools/perf/coast_pan/report.py NEXT_RUN --device pixel-test --baseline pixel-baseline.json
```

报告列出每组样本数、帧间隔 P95、超过 25 毫秒的次数。同条件时输出相对基准的差值；设备、绘制尺寸、画面覆盖、同步设置或驱动等不同时显示差异和参考数值。单次差值应和同设备重复运行的波动一起解释。不同系统的刷新策略、调试构建和后台负载都会影响结果。

游戏记录的是两次 Godot 绘制回调之间的时间。需要 GPU 执行时间和真实屏幕间隔时，在 Apple 设备上用 Instruments 的 Game Performance 模板从游戏启动前录到第四段完成，保存含 Metal 命令缓冲、GPU 活动和内屏换面事件的跟踪，然后运行：

```sh
python3 tools/perf/coast_pan/report.py RUN_DIR --device iphone-16e --trace RUN.trace
```

## 固定条件与历史参考

- 四国、60×40、种子 20260718，按同一组领地命令建立探索记忆，保留迷雾，暂停在第 3 天。移动低档、地表 100%、迷雾 50%、垂直同步开启。窗口尺寸和实际绘制尺寸分别保存。
- 镜头缩放 1.75，从世界坐标 (1059.36377, 924) 向右移动 320。每段预热 60 个绘制帧，再在 240 个绘制帧中匀步走完；顺序固定为完整、隐藏水面、完整、隐藏水面。隐藏只改变水面绘制层。按绘制帧推进，确保慢设备也经过相同的地点。对照工具会检查四段实际镜头位置和输出截图的尺寸。
- 2026-11-23 的 iPhone 16e 使用 A18、60 Hz、Metal、Release；屏幕窗口 2532×1170，游戏绘制缓冲 1950×1170。完整与隐藏水面的游戏绘制间隔 P95 分别为 17.152 和 19.290 ms，各 480 个样本。原始脚本的两条桌面断言错误地要求关闭同步，手机实测为开启。报告工具只对原始四份文件的精确校验值识别这次历史例外。
- 当时系统跟踪只覆盖后两段的共同末段。因此系统指标固定比较第 3、4 段索引 130–239：同一帧内 GPU 活动区间取并集（各 110 帧）；按游戏请求的表面 ID 关联内屏真实换面，再计算相邻间隔（各 109 个）。GPU P95 为 17.056 / 14.333 ms，换面 P95 为 16.674 / 16.672 ms。系统记录覆盖不匹配时，仍可单独运行游戏回调比较。其他平台以后可以使用自己的系统跟踪；当前跨平台共有指标是游戏绘制回调。
