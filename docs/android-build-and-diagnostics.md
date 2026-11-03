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

### 2.5 安卓上"经济完全不动"：day 1 的 worker 死锁（2026-11-01 实测修复）

现象：进游戏后日期在走（或停住），但 GDP/人口永远停在 bootstrap 值；`[heartbeat]` 里
`day` 涨而 `eco_day` 不动，或者两者一起停。

用 `--headless` APK 在模拟器上抓到现场：

```
[sim/graph-barrier/host] day=1 state=PAUSED econ_granted=false attempt_slices=0 ... stall=fiscal_peer@1
[sim/graph-barrier/day]  day=1 ... env_day=0 ring=0 missing=input_capture|climate|country|...
```

worker 停在"等环境帧"（`ring=0`、`attempt_slices=0`），主线程在等 worker 提交 —— 互锁。
Windows 上同一份代码靠启动时序能抢过去，安卓上抢不过。

修法：**移动端改用内联日执行者**（`world_runtime_host._native_daily_inline_requested()` 对
mobile 返回 true），即 web 上已验证多年的"主线程跑 12 域"路径，不依赖 worker 线程与
环境环。想恢复实验性 worker：`PK_MOBILE_NATIVE_WORKER=1`。

修后同一回路实测：

```
[runtime-worker] production ACTIVE started mask=4095 ... inline=true
[autotest] autotest_pass {"day":20,...}
[heartbeat] day=116 ... eco_day=116 graph=true     ← 时钟与经济日结同步
```

### 2.6 手机档着色器编译失败：`visual_sample_horizon`

```
SHADER ERROR: No matching function found for: 'visual_sample_horizon'.
ERROR: Shader compilation failed.
```

手机档（`MOBILE_QUALITY_*`、web-min 变体）不定义 `VT_USE_HORIZON`，但
`vegetation_impostor.gdshaderinc` 的灌木遮蔽采样直接调用 `visual_sample_horizon()`；
`terrain_horizon` 的"中性叶子"只覆盖 `terrain_horizon_evaluate`，覆盖不到它。
修法：`visual_tile_sampling.gdshaderinc` 在 `#ifndef VT_USE_HORIZON` 下补一个返回
`vec4(0.0)` 的中性实现，并在 web-min 档把灌木的采样点短路。修后安卓 headless 日志
`SHADER ERROR` 计数为 0。

### 2.7 音频默认：安卓走 portable 全混音

FMOD Android 路径在模拟器上会停在 `GDExtensionManager.load_extension`
（logcat 只到 `Loading FMOD extension (Android)` / `fmod jni prime ok` 就没有下一行，
主循环永远不开始）。因此 `GameAudio._ready()` **第一行**就对安卓短路到
`_start_native_backend("android")`，并让 `native_backend_reason_for()` 对安卓返回
`"android"`；FMOD 改成显式开关 `PK_FMOD_ANDROID=1`，等真机验证（fmod.jar + JNI 引导）
通过再改默认。

配套改动：`addons/FmodGodot/FmodGodot.gdextension` 与
`addons/fmod_android_bootstrap/fmod_bootstrap.gdextension` 的 **android 段已注释**，
否则 Godot 启动时会自动加载 FMOD 扩展并打一串
`JNI_OnLoad has not run` / `Failed to initialize FmodAudioServer`。
真机验证通过后，两处 android 段与 `PK_FMOD_ANDROID=1` 一起恢复即可。

修后实测：`[audio] backend=native platform=Android reason=android mix=full_mix`，
且同一局里 day/eco_day 正常推进到 107。注意：`adb install` 有时只打印 `Serving...`
不打印 `Success`，装完务必用 `dumpsys package <pkg> | grep lastUpdateTime` 确认时间戳，
否则会拿旧包误判"修了没用"。

### 2.8 真机 UI 截断 / 每日 SCRIPT ERROR（2026-11-02 真机实测）

**右侧详情面板被屏幕右缘切掉**（页签"市场"、KPI"就业率"、关闭按钮都看不见）：

- `_layout_right_panel()` 的宽度按 `detail_open()` 算，但它以前只在 viewport 尺寸变化时重算，
  地块档案打开后不会重排；同时触摸档页签抬到 44dp 后，面板内层只有 424 设计像素，
  5 个页签 + 4 列 KPI 装不下。
- 修法：① 触摸档面板宽度 460 → 532 设计像素；② 在 `show_cell_panel` /
  `show_object_detail` / `show_family_workspace` / `close_detail` 之后
  `call_deferred("_layout_right_panel")`，让面板跟着内容重排。
- 真机核对：2670×1200@520dpi，`viewport=(2053,923)`，面板 `pos=(1505,92) size=(532,815)`，
  右缘 2037.8 < 2053.8-16，五个页签与关闭按钮全部在屏内。

**每天一条 `Trying to assign value of type 'int' to a variable of type 'PackedInt64Array'`**：

- `scripts/narrative/narrative_context_sampler.gd:241` 把 `population_cell_snapshot(cell,false)`
  的 `funds` 直接当 `PackedInt64Array` 接，但 `include_details=false` 时 native 只回标量汇总。
- 修法：`handles/populations/funds` 三个键按类型收，缺数组就走"无明细"分支。

**手机帧率**：同一台手机（2670×1200@520dpi、2400 格）

| 画质设置 | 实测 fps（`[heartbeat]`） |
| --- | --- |
| `render_quality="high"` | 23.7 |
| `render_quality="low"` | 40 ~ 57 |

慢的主因是手机档跑 HIGH 着色器，不是仿真本身（`[clock/step] cost` 45~69ms/天）。
设置里"自动"在移动端本来就解析成 LOW；如果玩家手动选"高"，会掉到 20fps 出头。

### 2.9 导出前必须清 `.godot/exported`（否则打进旧字节码）

2026-11-02 真机踩到：改了 GDScript、重新导出、装到手机上仍然报旧代码的错
（`Parse Error: Identifier "profession_state_service_only" not declared`、
`Nonexistent function 'get_economy_facade'`）。原因是 Godot 把编译好的脚本字节码
缓存在 `.godot/exported/<hash>/`，导出直接复用，源码改了它也不重编。

```powershell
Remove-Item Project\project-keynes\.godot\exported -Recurse -Force
# 然后再 --export-debug
```

清掉之后同一份源码：
- `gameplay_start_failed`（旧 `economy_catalog.gd` 的作用域错误）消失；
- 之前"改了没生效"的修复全部生效。

同轮修掉的还有 `MapGenerator.get_economy_facade()` —— 军事运行时落地时被误删，
但 player_game / 存档 / 心跳诊断都在调用，导致每帧 `Nonexistent function`、
经济水位 `eco_day` 恒为 -1。已补回。

### 2.10 10 倍速到底几天/秒（真机实测）

改前 `sim_budget_ms()` 只在 Web 按倍速放大，安卓固定 8ms，吞吐上限
= 8ms / 单日成本（50~70ms）≈ 0.13 天/帧，×10 实际只有 **5.4 天/秒**。
移动端也按倍速放大后（×10 → 40ms，上限 60ms），真机 `[clock/rate]`：

```
dps=9.95 speed=10x cap=1.08d/f cost=37ms fps=17.9
dps=10.09 speed=10x cap=1.26d/f cost=32ms fps=23.5
```

即 ×10 真的跑到 ~10 天/秒，代价是 fps 从 ~30 掉到 ~18-24（玩家按倍速时的预期取舍）。

### 2.11.1 移动端编译期档固定 LOW（2026-11-02 落地）

真机同图同视角（小米 15 / 2670×1200 / 2400 格 / ×1）逐项二分后的结论：

| 配置 | fps | 单日成本 |
| --- | --- | --- |
| `MOBILE_QUALITY_MID` | 31 ~ 33 | 28 ~ 36 ms |
| `MOBILE_QUALITY_HIGH` | 26.5 | — |
| `MOBILE_QUALITY_MID` + `visual_quality=0` | 35 ~ 38 | — |
| `MOBILE_QUALITY_MID` + 关掉植被/资源/雾/天气层 | 28 ~ 33 | — |
| `MOBILE_QUALITY_LOW` + `visual_quality=1` | **60.7** | 7 ~ 9 ms |
| `MOBILE_QUALITY_LOW` + `visual_quality=2` | **56 ~ 61** | 7 ~ 9 ms |

也就是说：**贵的不是运行期画质（PBR/线性光照/ACES 几乎免费），而是 `PK_QUALITY_MID/HIGH`
编译进去的那些每像素分支**（`water_pipeline` / `world_map` / `country_border` /
`hex_edge_overlay` 的 `#if !defined(PK_QUALITY_LOW)` 段）。

处理：`player_game._shader_quality_define_from_setting()` 在移动端也固定返回
`MOBILE_QUALITY_LOW`（Web 早就是这个策略），画质由 `visual_quality`（0/1/2）决定。
实测把设置切到"高"后：**26.5 fps → 60 fps**，单日成本 28~36ms → 7~10ms。
逃生口：`pk_debug.cfg` 的 `[render] mobile_shader_tier` 或环境变量 `PK_MOBILE_SHADER_TIER`。

### 2.13 安卓真机渲染线程崩溃（VkThread 栈溢出）

真机（小米 15）进世界后 10~60 秒内必崩：

```
F libc : Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0x6d…  in tid VkThread
F DEBUG: backtrace:
    #00 pc … libgodot_android.so
    #01 pc … libgodot_android.so
    #02 pc … libgodot_android.so
    #03 pc … = #01
    #04 pc … = #02     ← 三帧循环重复
```

fault 地址落在栈区（0x6d…），backtrace 是三帧一循环 —— 判定为**渲染线程栈溢出/无限递归**，
发生在引擎（`libgodot_android.so`）内部。`libgodot_android.so` 是发行模板，符号已剥离，
`llvm-addr2line` 只能给出 `??`，所以只能靠二分定位。

已加的二分开关（`user://pk_debug.cfg`，正常玩家无此文件 ⇒ 完全 no-op）：

```ini
[render]
skip_lut_sync = true          # 跳过每日 LUT 纹理重绑/重传
tier_override = "MOBILE_QUALITY_LOW"
visual_quality = 0
hide = "weather,fog,shrub"
mobile_shader_tier = "MOBILE_QUALITY_MID"
```

### 2.17 无真机的移动端 UI 验收回路（2026-11-02 新增）

性能/真机问题之外，UI 版面可以完全在桌面上验：

```powershell
$env:PK_UI_QA_PROFILE='profile=mobile,dpi=520'   # 移动档缩放
$env:PK_SCREENSHOT_AFTER_MS='22000'                # 进世界后自动截 HUD
$env:PK_UI_SHOT_PANEL='country:economy'            # 或 gm；打开指定面板再截
$env:PK_UI_SHOT_DELAY_MS='16000'
& '<godot-gui-exe>' --path <project> --autotest-query=autotest=1&days=5&speed=1&size=40x28
# 产物：%APPDATA%\Godot\app_userdata\ProjectKeynes\debug_shot_*_panel_*.png
```

同轮改掉的触摸档尺寸（`scripts/ui/touch_ui.gd`，桌面档全程 no-op）：

| 常量 | 改前 | 改后 | 理由 |
| --- | --- | --- | --- |
| `TOUCH_MIN_DP` | 44 | **34** | 44dp 套到所有按钮 = 真机每个按钮 12% 屏高；命中区本来就由 `touch_hit_button._has_point` 扩到 44dp |
| `TOUCH_DENSE_DP` | 36 | **28** | 数据网格一行原本只有 30~34 设计像素，36dp 会压成一屏 8 行 |
| `SCROLLBAR_MIN_DP` | 32 | **12** | 32dp 是一条 42px 的棕色厚带（玩家："很诡异的滚动条"） |

另外：触摸档把 `ScrollBar` 的 `scroll`（轨道）样式覆盖为 `StyleBoxEmpty`，只保留滑块，
纸纹轨道不再被拉伸成贯穿面板的浅棕宽带。

**compact 版面核对（2026-11-02 补）**：桌面模拟器受总缩放上限 2.0 限制，逻辑高压不到
手机那种 923，所以永远进不了 compact。新增 QA 开关 `PK_UI_FORCE_COMPACT=1`
（`touch_ui.is_short_viewport()` 直接返回 true），配合上面的截图回路即可复现真机 compact：

```
PK_UI_QA_PROFILE='profile=mobile,dpi=520' PK_UI_FORCE_COMPACT=1 PK_UI_SHOT_PANEL='country:economy'
```

核对结果：compact 下国家事务面板收成单行顶级页签（科技/理念/经济/军事/外交）+ 单行 section 页签
（总览/阶层民生/…/国库）+ 右侧「范围」下拉，面板不再溢出；GM 面板（`PK_UI_SHOT_PANEL=gm`）
在 compact 下是左侧深色面板 + 图标页签 + 细滚动条，可读可用。

**已知破损（非本轮回路问题）**：`res://scenes/ui/military_workspace.tscn` 目前加载报
`Parse Error: Expected '['`（该文件未被 git 跟踪，属军事 v1 在写的文件），军事页签会打开失败。

> **已修（2026-11-02 当轮）**：根因是文件带 **UTF-8 BOM**（`EF BB BF`）。Godot 的
> `.tscn` / `.gd` 文本解析器不接受 BOM，报错行号还会指向第 1 行。全项目扫出 16 个带 BOM
> 的文本文件并统一剥掉，其中两处是真正的功能破损：
> `scenes/ui/military_workspace.tscn`（军事页签场景）、
> `scripts/ideology/ideology_effect_definition.gd`（理念系统定义脚本）。
> 剥掉后 `--quit` 全项目零 SCRIPT ERROR，军事场景可以正常 instantiate。
>
> 排查命令（PowerShell）：读每个文本文件前 3 字节，等于 `EF BB BF` 就剥掉重写。

**仍待真机/后续**：国家事务-国民经济面板在**宽屏逻辑尺寸**下仍走桌面板式
（左侧竖排书脊 + 宽表格），手机逻辑高 923 < 1000 才会折叠成 compact；桌面模拟器
因为总缩放上限 2.0 很难复现 1080→923 的逻辑高，需要在真机上确认 compact 后的版面。

### 2.18 渲染线程崩溃的排除记录（2026-11-02 最新）

到本轮为止，已用**模拟器**（x86_64 + SwiftShader 软件 Vulkan）做了三次对照，结论修正了
此前"每日 LUT 重绑是根因"的猜测：

| 实验 | 结果 |
| --- | --- |
| 每日 LUT 双缓冲改原地 `update()`（两处） | 桌面上 `rebind` 从 ~1 次/秒 降到 **0**（只剩开局 3 次首建） |
| 模拟器跑带全部修复的包 | 经济 `ACTIVE`、`SCRIPT ERROR=0`、`rebind=0`，**仍在 ~15 秒后 SIGSEGV VkThread** |
| 再加 `[render] skip_lut_publish=true`（完全不往 GPU 传每日 LUT） | 仍然 SIGSEGV VkThread |
| `--rendering-driver opengl3` | 未生效（日志仍是 Vulkan 路径），仍 SIGSEGV |
| 项目设置 `rendering/renderer/rendering_method.mobile="gl_compatibility"`（清 `.godot/exported` 后） | 生效（`OpenGL API OpenGL ES 3.0 ... Compatibility`），**仍在 `GLThread` 里 SIGSEGV** |
| 隐藏植被/资源/建筑/细节层 | 仍崩（day≈18） |
| 隐藏天气/雾层 | 仍崩（day≈3） |

⇒ 崩溃**与图形后端无关**（Vulkan 的 `VkThread` 和 GL 的 `GLThread` 同签名 SEGV_ACCERR），
也**不是** LUT 重绑/上传、植被/建筑/天气层引起的。同时观察到
`[weather-layer][lut] update_usec=27599200` 每帧都取同一个值（疑似计时器不重置、
高频重传），是一个独立的 perf 缺陷，但不是崩溃点。

⇒ 崩溃**不是**每日 LUT 重绑/上传引起的；模拟器（软件 Vulkan）与真机（Adreno）同签名，
更可能是引擎 Vulkan 渲染路径上的问题。`libgodot_android.so` 是剥离符号的发行模板，
`llvm-addr2line` 无法解析 backtrace；`android_source.zip` 里没有独立符号文件，要符号化只能
自建引擎。

**当前可用的二分开关**（都用 `user://pk_debug.cfg`，正常玩家无此文件）：
`skip_lut_sync`、`skip_lut_publish`、`tier_override`、`visual_quality`、`hide`、
`mobile_shader_tier`。

**本地验证平台现状**：桌面 worker 路径停在
`stall=fiscal_peer@1 / park=effect:effect_parked_climate_input`（env_day 永远 0，
非安卓内联路径问题）；模拟器的 qemu 自身会在 15~60 秒内崩、`adb` 掉线。
所以剩余的真机项（长时间稳定性、compact 版面手感）只能在手机上做。

### 2.22 安卓包瘦身与一个自己踩的坑（2026-11-03）

**FMOD 桌面 bank 会进安卓包**：`assets/audio/banks/Desktop/Music.bank` 有 91 MB，
即使 `exclude_filter` 写了 `assets/audio/banks/*`、`*.bank` 也照样被打进去（它是被
项目引用到的依赖资源，导出器的依赖收集会覆盖排除表）。安卓走 portable 后端，这些
bank 完全用不到。

处理：`tools/android_trim_apk.ps1`（本轮新增）—— 打开 APK 的 `ZipArchive` 更新模式
删除匹配条目，再 `zipalign -p 4` + `apksigner`。用**Godot 自己的 keystore**
（`%APPDATA%\Godot\keystores\debug.keystore`，不是 `~/.android/debug.keystore`）
签名才能覆盖安装、保住存档：

```powershell
powershell -File tools\android_trim_apk.ps1 -Apk Build\ProjectKeynes.apk `
  -RemovePattern 'assets/assets/audio/banks/*' -Out D:\pk\ship.apk `
  -Keystore "$env:APPDATA\Godot\keystores\debug.keystore"
```

结果：APK 542.3 MB → **451.5 MB**（删掉 91 MB bank，保留 7 条 portable 音乐）。

**坑（已修）**：我在给安卓排除表加 `assets/audio/native/music/*` 时把**便携音乐**
排掉了，真机日志立刻报 `WARNING: [audio] Missing portable audio:
res://assets/audio/native/music/stone.ogg` —— 那正是用户最早反馈的"没有音乐"。
正式包的排除表**只能排除 `assets/audio/banks`（FMOD bank）**，绝不能再碰
`assets/audio/native/music`。修好后真机不再出现该 warning。

### 2.21 真机 UI 三个观感问题的定位与修复（2026-11-03）

**① 地图边缘"闪烁"，且与缩放相关（玩家诊断正确：dither 边界）**

`shaders/include/terrain_surface_detail.gdshaderinc` 的移动端 8×8 Bayer dither
用**图集纹素**坐标取样（`floor(uv * dims)`）决定每像素走主/副材质。当缩放让
**一个 dither 纹素小于 1 个屏幕像素**时，相机的亚像素移动会让相邻像素在两种材质间
来回翻转 → 走动/缩放时闪烁。

修法：新增 `terrain_dither_subpixel_fade()`，按"一个 dither 纹素占几个屏幕像素"
淡出（<0.85px 关掉、>2.2px 全开），关掉后回落到平滑 `edge_w` 过渡（不产生硬边）。
仅 `PK_MOBILE_ANY` 生效，桌面不变。

**② 低倍率下地图"拖不动"**

`map_camera._clamped_position()` 旧约束是"视口必须完全落在世界内"；缩放到整图
（真机 `zoom≈0.94`）时 `min_p≈max_p`，相机被钉死。改为"至少保留约 40% 视口可见"，
允许把地图推到边缘外一定距离。

**③ 细线/边缘在移动时的走样**

触摸档给 `Viewport.msaa_2d = MSAA_2X`（桌面关闭，避免影响既有截图与性能基线），
开关在 `player_game._push_visual_toggles()`。

**④ 地图提示标志错位（已修，2026-11-03 · 含一次错误修复的记录）**

`CellSituationLayer` 在 `player_game.tscn` 里是 **`UI/UIRoot/HUDLayer` 下的 `Control`**
（挂在 `CanvasLayer` 里），所以它的**绘制空间本来就是屏幕空间**，`_screen_center()`
（`get_canvas_transform() * world`）给的也已经是屏幕坐标。

**错误修复（已撤销）**：一度以为 `draw_texture_rect()` 在本地空间、相机变换被应用了
两次，于是加了 `draw_set_transform(canvas_inverse)`。结果图标被推得更远、还被 1/scale
缩小（真机反馈"彻底漂移，找都找不到"）。教训：**先确认节点挂在 CanvasLayer 还是
世界坐标的 Node2D 下**，再谈坐标空间。

**真正的 bug**：图标抬升量用了相机 zoom 而不是 canvas 缩放，漏了 content_scale
（移动端 `CANVAS_ITEMS` ≈ 1.375），少算 37%，图标压到格子上沿而不是浮在格子上方：

```gdscript
# 旧
top = center + Vector2(-columns*side*0.5, -_hex_size * _camera.zoom.x * 0.5 - row_count*side)
# 新：世界半径 → 屏幕像素要乘 canvas 缩放
var s := get_viewport().get_canvas_transform().get_scale().x
var hex_screen_r := _hex_size * s
top = center + Vector2(-columns*side*0.5, -hex_screen_r*0.5 - row_count*side)
```

`tests/world/cell_situation_layer_test.gd`：18 checks, 0 failures。
定位锚点开关：`pk_debug.cfg [render] situation_anchor=true` 会在每格中心画品红十字。

**移动端 dither 关闭**：关掉战争迷雾后"地块中间全是花斑"，来源是 8×8 Bayer dither
按图集纹素取样、低倍率下把材质过渡打成斑块。移动端 `terrain_land_dither_zoom_strength()
直接返回 0，退回平滑 `edge_w` 过渡（注释里写了怎么恢复）。

**QA 探针（保留）**：`pk_debug.cfg` 写 `[render] badge_probe_cell=<格号>|"center"`
会在该格挂一个永久 `PROBE` 徽章并打印世界坐标；`[camera] zoom=3.0` 可让相机开局
强制停在该倍率 8 秒（相机装配后会被 fit_to_viewport 拉回整图，所以要每帧压住）。
两者都只在存在 `pk_debug.cfg` 时生效，正常包无感。

### 2.20 崩溃符号化流水线（2026-11-02 备好，等引擎编完）

`libgodot_android.so` 发行模板剥离了符号，`llvm-addr2line` 只能出 `??`。要拿到可读
backtrace 必须用**同版本、同配置、不剥符号**的引擎库替换进 APK：

```powershell
# 1) 一次性：克隆 4.6.2 源码并编带符号的 arm64 模板库（背景跑，20~60 分钟）
git clone --depth 1 --branch 4.6.2-stable https://github.com/godotengine/godot.git D:\godot-src\godot
cd D:\godot-src\godot
$env:ANDROID_HOME='<Android SDK>'; $env:ANDROID_NDK_ROOT='<SDK>\ndk\30.0.14904198'
scons platform=android target=template_debug arch=arm64 strip=no debug_symbols=yes -j8
# 产物：bin\libgodot_android.*.so（带符号）

# 2) 换进 APK（tools/swap_android_engine_lib.ps1 已在本轮写好并自测通过）
powershell -File tools\swap_android_engine_lib.ps1 `
    -Apk Build\ProjectKeynes.apk `
    -EngineLib D:\godot-src\godot\bin\<带符号的 libgodot_android.so> `
    -Out D:\pk\keynes-sym.apk

# 3) 装机复现崩溃，抓 backtrace 地址，然后
llvm-addr2line -f -C -e <同一个 .so> 0x1615ab4 0x15f5b24 0x3ff5394 0x1620344
```

脚本实现要点（踩过的坑都写进注释）：APK 必须用 `ZipArchive` 的 **Update 模式**原地替换
`.so`（手工整包重压会被 apksigner 判成 `not a ZIP archive`）；`.so` 条目必须**不压缩**；
之后 `zipalign -p 4` + `apksigner sign`（debug keystore，alias `androiddebugkey`）。
自测结果：替换后 v2/v3 双通过。

**一键复现 + 抓地址**：`tools/android_crash_repro.ps1 -Apk <签名后的带符号 APK>`
会推包安装、保持亮屏、启动并轮询到进程死亡，然后把 logcat 里的
`#NN pc 0x…` 全部抽出来，直接打印成一行 `llvm-addr2line -f -C -e <so> <地址…>`。
该抽取逻辑已用模拟器真实崩溃日志验证：一次抓到 512 个地址，其中就能看到三帧循环
（`0x15b29db / 0x15845df / 0x44405ff` 反复出现）——只是那是 x86_64 模拟器的地址，
要和**同架构**的带符号库配对才能翻译。

因此符号化有两条并行路线：

| 目标 | 需要的带符号库 | 复现环境 |
| --- | --- | --- |
| 真机（arm64） | `scons platform=android target=template_debug arch=arm64 strip=no debug_symbols=yes` | 用户手机 |
| 模拟器（x86_64） | 同上，`arch=x86_64` | 本机 emulator（qemu 会自己崩，但应用崩溃的 logcat 通常已经拿到） |

第二条不需要手机，是当前可推进的那条。

**当前实测瓶颈（2026-11-03）**：模拟器（`pk_small` 480x800 / `pk_probe` 1080x2220，都是
`-no-window -gpu swiftshader_indirect`）在**应用还没进世界时** `qemu` 进程就会自己退出，
`adb` 随之消失。已按"先开流式 `adb logcat > host.log` 再启动应用"的方式抓取
（`Build\logs\stream_crash.log`），8.6MB 日志里只到 shader 缓存回退，没有任何
`Fatal signal`——说明这一轮是模拟器本身死了，不是应用崩。三种 GPU 配置
（`swiftshader_indirect` / 低分辨率 AVD / `guest`）都试过，结论一致：**本机模拟器不能作为
稳定性验证平台**。

**已就绪、等真机的两件东西**：

- `D:\pk\keynes-sym.apk`（1.17GB，arm64，带符号引擎，v2/v3 签名通过）；
- `tools/android_crash_repro.ps1`（推包装机 → 保持亮屏 → 轮询到崩溃 → 抽 backtrace 地址）。

手机接上后执行一次即可拿到可读栈：

```powershell
adb shell pm uninstall com.projectkeynes.game      # 换库后签名不同，必须先卸
powershell -File tools\android_crash_repro.ps1 -Apk D:\pk\keynes-sym.apk
llvm-addr2line -f -C -e D:\godot-src\godot\platform\android\java\lib\libs\debug\arm64-v8a\libgodot_android.so <地址…>
```

### 2.19 导出到长路径时签名会失败（2026-11-02）

现象：`--export-debug` 跑到
`[98%] 正在签名调试 APK……` 之后进程退出、目标 APK 不存在，stderr 里是
`apksigner` 的 `Unicode parsing error: Invalid unicode codepoint (671f)`。

规避：**导出到短的纯 ASCII 路径，再拷贝到 Build/**。

```powershell
& '<godot>' --headless --path <project> --export-debug Android D:\pk\build.apk
Copy-Item D:\pk\build.apk <repo>\Build\ProjectKeynes.apk -Force
```

导出成功后 `apksigner verify` 仍是 v2/v3 双通过。同一份源码换成长路径导出会复现失败，
换回短路径即成功，所以与内容无关。

另：`res://assets/military/papercut/military_atlas_v1.png` 是新增资源，需要先跑一次
`--headless --import` 生成 `.godot/imported/*.ctex`，否则
`assets/military/plan_target.tres` 会报 `referenced non-existent resource` 并中断导出。

### 2.16 2026-11-02 收尾状态（真机最后一轮实测）

**已修好并真机验证通过**

- 经济日结：`[heartbeat] day=2 … eco_day=2` —— 修法见下条。
  `profession_state_supplied_need_out_of_range:soldier` 的根因是
  `gdext/src/economy_runtime_catalog.cpp` 里"国家供给需求"校验排在
  `_need_ids = packed_strings(catalog,"need_ids")` **之前**，校验时 `_need_ids` 为空，
  任何非负下标都越界。现把 need 列表提前解析（`catalog_need_ids`）并用于掩码/越界判断。
  军事 v1 之前没有 profession 声明 `state_supplied_need_ids`，所以这个顺序问题一直潜伏。
- 地图生成、音频（portable 全混音）、触屏命中区、60fps（移动端编译期档固定 LOW）、
  ×10 吞吐（`[clock/rate] dps≈10`）均有真机证据。

**仍未解决**

1. **渲染线程崩溃**：`Fatal signal 11 … in tid VkThread`，SEGV_ACCERR、fault 地址在栈区、
   backtrace 三帧循环（引擎内部无限递归/栈溢出）。
   **已定位并修掉触发链（待真机复验）**：`map_baker.gd` 有**两处**对 `dyn_lut_tex` 做
   前后台双缓冲交换（初版 bake 一处、每日刷一处），每天换一个 Texture 对象 ⇒
   `hex_renderer._sync_cell_lut_textures()` 每天命中 stale-rebind 分支，在同一帧给两张
   world_map 材质换 sampler。两处都改成原地 `update()`（`dyn_lut_tex_back` 无任何读者）。
   桌面实测：20+ 模拟日 `rebind (material held a stale LUT texture object)` 计数 **0**
   （改前约 1 次/秒），`lut_dims resync` 也是 0。真机是否还崩，等手机充好电复验。
2. 安卓启动仍先试 FMOD 再回退 portable（`jni_prime_failed`，多花 1~2 秒 + 一条 WARNING）。

### 2.15 三类"内容文件损坏"的症状（本轮真机连续踩到）

| 症状 | 真实原因 | 处理 |
| --- | --- | --- |
| `modifier_stat_key_invalid_or_duplicate` → `[modifier] configure failed` | 同一 stat 同时登记在 `.tres` 资源目录与脚本内 `TECHNOLOGY_STATS` | 资源目录优先、脚本表重复行跳过（`modifier_catalog.gd`） |
| `res://data/modifiers/default_modifier_catalog.tres:NNNN - Parse Error` | `.tres` 被写成非法数组（`stats` 行没有 `[ ]`，且条目重复 N 次） | 从 git HEAD 恢复该文件；军事 stat 仍由 `TECHNOLOGY_STATS` 提供，两边不再重复 |
| `[economy] configure failed: profession_state_supplied_need_out_of_range:soldier` | `profession_profile.state_supplied_need_ids` 的校验在 native 侧 | 待查：soldier 声明了 2 个供给需求（staple_food / protein），native 校验判为越界 |

共同点：这些失败都会让 **经济运行时为空**，随后 `[runtime-worker] FAULTED` +
`world_clock.pause(true)`，症状就是「日期停在 day 0、fps 正常」。

### 2.14 经济 worker 输入形状校验（`economy_worker_input_shape_invalid`）

`NativeEconomyRuntime::capture_worker_day_input()` 会校验：

| 条件 | 含义 |
| --- | --- |
| `input.day >= 0` | 抓到的是有效日 |
| `input.cell_count == _cell_count` | 格子数一致 |
| `reserves.size() == _resource_ids.size()` | 资源列表长度一致 |
| `changes.size() == reserves.size()` | 变化表与资源表同长 |
| `neighbors.size() == cell_count * 6` | 邻居表是六邻接 |

任一不满足 → `world_clock.pause(true)`，表现就是「日期停在 day 0/1、fps 正常」。
排查时在抓取侧把上面四个 size 打出来和期望值对比即可。

### 2.12 原生库必须跟着 C++ 源码重建

`addons/dots_ext/bin/android/*.so` 是导出时打进 APK 的原生实现。C++ 源码改了
（本轮 `world_ext_military.cpp` / `world_ext.cpp` / `country_runtime.cpp` 等）
但 .so 还是旧的，运行期就会看到 `country_runtime_unavailable`
→ 经济日结被拒（`ACTIVE refused: Country capture incomplete`）→ 心跳里 `eco_day=-1`。
判据：`Get-Item addons\dots_ext\bin\android\libdots_ext.android.template_debug.arm64.so`
的修改时间早于 `gdext\src\*.cpp` 的最新时间就必须重建（`gdext\build_android.bat`）。

### 2.11 画质档位实测（同一台小米 15，2670×1200，×1 速度）

| 档位 | fps |
| --- | --- |
| low | 45 ~ 55 |
| medium | 29 ~ 33 |
| high | 26.5 |

**HIGH 只比 MEDIUM 低一点点，真正的大台阶在 LOW → MEDIUM**。也就是说开销主要来自
MEDIUM 起才启用的那批特性（地形 PBR / 线性光照 / ACES、植被近景形态与法线着色），
而不是 HIGH 独有项——优化应该盯着这条路径，而不是把目标放在"HIGH 太重"。

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

### 无人值守跑一局（安卓自动化回路）

```powershell
# 1) 导出带自动测试参数的包（模拟器用 x86_64；真机用 arm64 并把 query 换成你要的天数）
#    export_presets.cfg 里临时设：
#      architectures/x86_64=true, arm64-v8a=false
#      command_line/extra_args="--headless --autotest-query=autotest=1&days=20&speed=3&size=40x28&seed=20260101"
# 2) 一键跑：起模拟器 → 安装 → 启动 → 抓日志 → 打印关键行
powershell -ExecutionPolicy Bypass -File tools\android_headless_probe.ps1 -Restart -RunSeconds 90
```

要点：`--headless` 让 Godot 不建 Vulkan 表面——模拟器的 present 路径不可用
（`QueuePresentKHR failed`），带窗口跑必然黑屏/进程退出；`--autotest-query` 来自
`web_autotest.gd` 的命令行支持，让游戏无需触摸即可开局。模拟器建议
`-gpu angle_indirect -memory 8192 -cores 6`，swiftshader 跑十几分钟会自己退出。

### 真机验证（同一套脚本，换成手机即可）

```powershell
adb devices                                  # 记下 serial
powershell -ExecutionPolicy Bypass -File tools\android_headless_probe.ps1 `
    -Serial <serial> -Apk Build\ProjectKeynes.apk -RunSeconds 150
```

手机用的是**正常包**（不带 `--headless`、不带 autotest），脚本只负责：推包 →
`pm install` → 启动 → 等你手动点进世界 → 抓 logcat。观察窗口里请依次做：

1. 主菜单 → 新游戏 → 开始游戏（确认地图能生成、加载条走完）；
2. 等 10~20 秒，看日期是否在走、右侧详情面板的 GDP/人口是否在变；
3. 点开经济面板，切「国库/税制/贸易」三个页签（验证触屏命中区）；
4. 三指双击（三指同时按下再抬起，两次间隔 ≤800ms）开 GM 面板。

脚本最后会打印关键行；判读口径：

| 行 | 含义 |
| --- | --- |
| `[mapgen][preflight] ok ... extension_loaded=true` | 原生库加载正常，地图能生成 |
| `[heartbeat] day=.. eco_day=..` 两者一起涨 | 日结与经济都在跑；只有 day 涨 = 经济没推进 |
| `[economy-stall] ...` | 连续 3 天经济没提交，这一行直接给了 stage/graph |
| `[audio] backend=native platform=Android` | 音频走 portable 全混音 |
| `SHADER ERROR` | 着色器变体回归（真机才看得到） |

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
| 安卓 UI 缩放（布局） | 模拟器 logcat：`[mobile-ui-scaling] touch dpi=440 ...`；触屏命中区用 Windows harness 的真实输入注入验证 |
| 安卓音频后端 | 模拟器 logcat：`[audio] backend=native platform=Android reason=android mix=full_mix` |
| 安卓地图生成 | 模拟器 headless：`[mapgen][preflight] ok platform=android/x86_64 extension_loaded=true` + 世界生成成功 |
| **安卓经济日结** | 模拟器 headless：`[heartbeat] day=107 eco_day=107 graph=true`、fps ≈113；`autotest_pass day=20`；连续多次运行均推进（含 116 天那次） |
| 安卓手机档着色器 | 修复 `visual_sample_horizon` 后 headless 日志 `SHADER ERROR` = 0 |
| 手机档 GL 渲染 | Windows `--rendering-method gl_compatibility` + mobile 档截图：手机版式正常、无 SHADER ERROR、day/eco 同步到 95/94 |
| **安卓真机渲染/触屏目视** | **未验证**：模拟器无论 Vulkan 还是 GL 都会把 qemu 带崩（`emu-crash-*.db`），只能你在手机上确认 |

> 模拟器限制（2026-11-01 多轮实测）：`-gpu host` / `swiftshader_indirect` / `angle_indirect`
> 三种模式在渲染路径下都会让模拟器进程崩溃；`--headless` + `-gpu swiftshader_indirect`
> 可以稳定跑完 100+ 天。所以自动化只验证逻辑与着色器编译，画面必须真机看。

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
