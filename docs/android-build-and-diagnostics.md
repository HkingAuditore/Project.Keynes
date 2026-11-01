# 安卓打包与三大问题的排查手册

> 2026-11-01。对应问题：① 手机按钮太小点不中 ② 安卓没有音乐 ③ 创建地图直接 `map_generator_failed`。
> 本文记录**根因、修法、验证口径**，以及下次再出问题时的取证步骤。

## 1. 构建链（一条命令即可出包）

```bat
rem 1) 原生库（arm64 debug + release）。必须带 disable_exceptions=no，脚本已内置。
gdext\build_android.bat

rem 2) 导出 APK（编辑器 / 命令行二选一）
"D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" ^
  --headless --path Project\project-keynes --export-debug "Android" Build\ProjectKeynes.apk

rem 3) 装机 + 抓日志
build_install_android.bat          rem 或 capture_android_log.bat
```

要求：

| 项 | 值 | 说明 |
| --- | --- | --- |
| Godot | 4.6.2 | 导出模板 4.6.2.stable |
| NDK | 30.0.14904198（r30） | `ANDROID_NDK_ROOT` 可由脚本自动发现 |
| SCons | 已装即可 | `gdext\build_android.bat` 会找 `scons` |
| 架构 | arm64-v8a | 模拟器调试另建 x86_64，见 §6 |

## 2. 三个根因与修法

### 2.1 按钮太小：设计像素被当成物理像素

- `project.godot` 没有 `window/stretch/mode`（默认 disabled），`GameSettings` 又把 `ui_scale_percent`
  直接写进 `content_scale_factor`，默认 100 → 1.0。于是 2220×1080@440dpi 的手机上
  1 物理像素 = 0.36dp，52px 的章节按钮只有 **18.9dp**（≈3mm），文字 7.3dp。
- 修法：新增 `scripts/ui/mobile_ui_scaling.gd`（由 `GameSettings` 持有），公式
  `总缩放 S = 0.5 × dpi/160`（即 1 设计像素 ≡ 0.5dp），并把逻辑短边钳在 560–1600 设计像素；
  移动端 `CANVAS_ITEMS + 1600×960 + EXPAND`，`content_scale_factor = S / 基础拉伸 × 用户倍率`；
  桌面/Web 仍 `DISABLED + 用户倍率`（零回归）。安全区用 `DisplayServer.get_display_safe_area()`
  换算成设计像素后内缩 `PageMargin` / `UIRoot`；方向设为 `handheld/orientation=4`（Sensor Landscape）。
- **为什么是 0.5 而不是更大**：第一版取 0.85（440dpi 上总缩放 2.34、逻辑 949×462），
  真机实测「按钮太大、面板被裁、比改之前更难用」——1600×960 的桌面排版被压进半屏。
  0.5 在 2670×1200@440dpi 上给逻辑 1941×872，版面接近桌面、命中区整体抬 37%：
  章节按钮 52→71.5 物理像素（26dp），主菜单/新游戏页完整可见。
  需要更大/更小时用设置里的「UI 缩放」80/100/125/150% 再乘一层（只乘一次）。
- 代价：地图与 UI 同倍缩放，`MapCamera` 用逻辑视口算 zoom 会自动补偿，所以同屏世界范围不变。

### 2.2 没有音乐：音频文件根本没进 APK

- 真正原因不是后端开关，而是 `addons/keynes_audio_export/plugin.gd` 在导出时把
  `res://assets/audio/native/**`（29 个 portable OGG）对非 Web 平台**全部 skip** 掉了。
  baseline APK 里 `.oggvorbisstr` = 0 → 安卓上没有任何可播的音频。
- 修法：该插件对 web/android/mobile 都保留 native 音频（Windows 仍用 FMOD）；
  `game_audio_service._uses_native_audio()` 扩到移动端，Android 走 `native_audio_backend.gd`
  的 Godot 全混音后端；`[preset.1]` 显式 `exclude_filter="assets/audio/banks/*"`（桌面 FMOD bank 不塞进手机包）。

### 2.3 创建地图失败：安卓原生库从 10-20 起就编不出来

两层原因，缺一不可：

1. **构建断了**：godot-cpp 对所有非 MSVC 平台默认强制 `-fno-exceptions`，而本项目
   `src/economy_change_registry.h` 故意 `throw std::logic_error`（Windows 靠 `/EHsc` 过）。
   `annual_development_host.cpp` 于 2026-10-20 加入后，安卓编译直接报
   `cannot use 'throw' with exceptions disabled` → **再也产不出新 .so，只能一直用 10-16 的旧库**。
   修法：`gdext/build_android.bat` 传 `disable_exceptions=no`（与 `Build-Web.cmd` 一致），未改 C++。
2. **旧库与新脚本契约不一致**：旧 arm64 .so 只命中 709 个绑定方法里的 268（缺整个线程化加载 API、
   `run_bake_visual_tile_layer_pass`、`run_resource_deposit_pass`、104 个 `get_*`），
   代码代次比文件时间还老。重建后命中 707/709（余下 2 个是测量地板，与 Windows DLL 一致）。
3. **重建后仍会加载失败（易被忽略）**：NDK r30 的 libc++ 比 Godot 4.6.2 模板自带的
   `libc++_shared.so` 新，新 .so 会引用 `__hash_memory` 等符号，真机 `dlopen` 报
   `cannot locate symbol _ZNSt6__ndk113__hash_memoryEPKvm` → `dots_ext_init` 解析失败。
   修法：`gdext/SConstruct` 对 android 加 `-static-libstdc++ -Wl,--exclude-libs,ALL`，
   重建后三个库的 undefined libc++ 符号为 0，`dots_ext_init` 正常导出。

### 2.4 错误可诊断（"不知道去哪看报错"）

- `MapGenerator.last_generation_error` 在 generate() 的**全部失败分支**填充
  （stage / reason / summary / hint / preflight / native_report / os / arch / map_size / seed / elapsed_ms），
  大数组会折叠成 `<PackedFloat32Array len=N>`，避免几 MB JSON 卡死加载页。
- `world_runtime_host` 生成前跑 `generation_preflight()`（扩展是否加载、native_mode 是否 ACTIVE、
  world_ext 能否实例化、4 个生成必需方法是否齐全），缺什么直接用中文点名，不再只发一个
  `map_generator_failed`。
- 失败面板（`world_loading_overlay.tscn`）现在有：摘要、可滚动可全选详情、**复制详情**按钮、
  日志落盘 `user://logs/map_generation_failure_<时间戳>.txt`。
- 单行日志便于 logcat 过滤：`[mapgen][fatal] stage=… reason=… platform=… map=… seed=…`。

## 3. 取证速查

```bash
adb logcat -c
adb logcat -v time godot:V *:S > godot_android.log

# 一条命令看关键行
grep -E "\[mapgen\]\[(fatal|preflight|selfcheck)\]" godot_android.log

# 正常应看到（进游戏前自动跑）：
#   [mapgen][preflight] ok platform=android/arm64 extension_loaded=true native_mode=2
#   [audio] backend=native platform=Android reason=android mix=full_mix
#   [mobile-ui-scaling] touch dpi=440 … logical=949x462

# 失败详情文件（debug 包）
adb shell run-as com.projectkeynes.game cat files/logs/map_generation_failure_<时间戳>.txt > detail.txt
```

纯自检（不建图）：启动参数 `--mapgen-selfcheck` 或环境变量 `PK_MAPGEN_SELFCHECK=1`，
输出 `[mapgen][selfcheck] {... "native_smoke": {"ok": true, "n_cells": 192 ...}}`。
`native_smoke` 会用 16×12 小图**真调一次**原生生成，证明内核能跑，而不只是方法名存在。

### 卡死/巨慢怎么定位

`player_game.gd` 里有两行哨兵，进游戏后一直打：

```
[heartbeat] day=12 speed=1.00 fps=28.9 stalls=0 scale=1.375 window=2670x1200
[stall] frame_ms=2600 day=13 speed=1.00 stalls=1        # 单帧 ≥2s 才打
```

- `[heartbeat]` 在、`day` 在涨 → 仿真正常，只是渲染慢（看 fps）；
- `[heartbeat]` 在、`day` 不涨 → 时钟/调度被卡住；
- 只有 `[stall]` → 主线程周期性被阻塞，`frame_ms` 就是阻塞时长；
- 两行都没有 → 主线程彻底卡死，日志最后一行就是现场。

另：原生加载任务现在有 60s 看门狗（`scripts/geography/native_loading_tasks.gd`），
线程任务超时会打 `[native-loading][watchdog]` 并改走同步路径，不会无限等。

## 3.1 手机上的 GM 面板

安卓没有 F1，GM 面板用**三指双击**（三根手指同时按下再抬起，两次间隔 ≤800ms）；
两指缩放、单指拖动都不会误触。只在 debug 包里生效（`is_gm_available()`）。
实现见 `scripts/game/player_controller.gd` 的 `_handle_touch_gm_gesture()`。

## 4. 已验收 / 未验收

| 项 | 证据 |
| --- | --- |
| APK 可签名导出 | apksigner `Signed`，0 个重复 ZIP 条目（`loading_prebake` 的 `add_file` 与 `all_resources` 曾写出两份同名条目） |
| arm64 .so 进包且 ABI 正确 | `lib/arm64-v8a/libdots_ext…arm64.so` 13.64MB，ELF64 AArch64，`dots_ext_init` 导出，undefined libc++ = 0 |
| 音频资源进包 | `oggvorbisstr` 29 条 / `.ogg.import` 29 条 / `banks` 0 条 |
| 安卓 UI 缩放 | 模拟器 logcat：`[mobile-ui-scaling] touch dpi=440 total=2.337 logical=949x462` |
| 安卓音频后端 | 模拟器 logcat：`[audio] backend=native platform=Android`；`dumpsys audio` 有 started 的 AudioPlayer |
| Windows 地图生成 | 40×28 seed=20261101 成功（1120 cells，2590ms），失败/自检/overlay 测试全绿 |
| **安卓真机地图生成** | **未验证**：模拟器（Vulkan/SwiftShader 均失败）跑不动 600MB 的包，必须在真机上点一次"创建地图"确认 |

## 5. APK 体积

当前 debug APK ≈ 660MB，其中 `assets/.godot/imported/**` ≈ 512MB（导入后的纹理/字体），
`libgodot_android.so` 71MB，`libdots_ext` 14MB。要减小：删除未使用的 4K 源图、降低纹理导入
尺寸/改用 VRAM 压缩、给 Android 预设加 `exclude_filter` 去掉 `tests/ tmp/ test_output/ tools/`。

## 6. 可选：x86_64 模拟器调试

```powershell
$env:ANDROID_HOME='C:\Users\<you>\AppData\Local\Android\Sdk'
$env:ANDROID_NDK_ROOT="$env:ANDROID_HOME\ndk\30.0.14904198"
cd gdext
scons platform=android target=template_debug arch=x86_64 ndk_version=30.0.14904198 disable_exceptions=no -j8
```

然后在 `addons/dots_ext/dots_ext.gdextension` 临时加
`android.debug.x86_64 = "res://addons/dots_ext/bin/android/libdots_ext.android.template_debug.x86_64.so"`，
并把 `export_presets.cfg` 的 `architectures/x86_64` 设为 true、`arm64-v8a` 设为 false 后导出。
实测：本项目 600MB 的包在 Pixel_3a_API_36 模拟器上无法稳定渲染（Vulkan `QueuePresentKHR failed`、
SwiftShader 直接崩），**模拟器只适合验证启动、UI 缩放、音频后端，不适合验证地图生成**。
