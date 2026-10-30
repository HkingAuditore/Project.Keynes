# Web 导出（Project.Keynes → 浏览器）

本文记录 Web 导出的完整链路、两个必须对齐的编译约束，以及当前验证到什么程度。
一键脚本是仓库根目录的 `Build-Web.cmd`，产物落在 `WebBuild/`。

> 结论摘要：**可以导出，并且已经跑通到可玩状态**（threads 变体：主菜单 → 新游戏
> → 世界生成 → 进入世界、HUD 与模拟正常）。`nothreads` 变体只能到"进入世界"98%
> 就冻结，原因见 §6.1；所以预设固定 `variant/thread_support=true`。

---

## 1. 前置条件

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| Godot 编辑器 | 4.6.2.stable | `GODOT_BIN` 环境变量可覆盖；脚本还会找 `<repo>\..\..\Godot_v4.6.2-stable_win64.exe[\]...]` 与 PATH |
| Web 导出模板 | 4.6.2.stable | `%APPDATA%\Godot\export_templates\4.6.2.stable\web*_release.zip` |
| Emscripten SDK | **4.0.20** | 官方 4.6 模板就是用 4.0.20 编译的，版本不一致会导致加载 side module 失败 |
| Python + SCons | 任意近期版本 | 脚本通过 `emsdk_env.bat` 拿 emcc，SCons 来自系统 Python |

`emsdk` 放在仓库根目录 `emsdk/`（已是这个布局）；激活一次即可：
`emsdk\emsdk install 4.0.20 && emsdk\emsdk activate 4.0.20`。

## 2. 一键导出

```bat
Build-Web.cmd                 :: 重编 native release + 导出 release 包
Build-Web.cmd debug           :: 重编 native debug   + 导出 debug 包
Build-Web.cmd both            :: 两套都做
Build-Web.cmd skip-native     :: 只重新导出（复用现有 .wasm）
```

脚本做两件事：

1. `gdext/` 里按下面的固定 flag 编 wasm side module；
2. 用 Godot headless 导出 `Web` 预设到 `WebBuild/ProjectKeynes.html`。

日志：`tmp/web_native_<target>.log`、`tmp/web_export_release.log`。

本地起服务：

```bat
serve_web.bat          :: = python tools/serve_web.py --port 8060 --root WebBuild
```

`tools/serve_web.py` 会补 `.wasm/.pck` 的 MIME，并发送
`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`
（threads 变体需要 SharedArrayBuffer；nothreads 变体发也无害）。
**不要用 `python -m http.server`**，那样浏览器会拒绝流式实例化 wasm。

## 3. 两个必须对齐的编译约束

### 3.1 threads 必须和导出预设一致

- 预设 `variant/thread_support=true` ↔ 编 wasm 时 `threads=yes`（**当前采用**）
  → 产物名 `libdots_ext.web.template_release.wasm32.wasm`
- 预设 `variant/thread_support=false` ↔ 编 wasm 时 `threads=no`
  → 产物名 `libdots_ext.web.template_release.wasm32.nothreads.wasm`

两边不一致会让 pthread ABI 对不上，浏览器里表现为 side module 静默加载失败。
`addons/dots_ext/dots_ext.gdextension` 里 `web.*.threads.wasm32` 与 `web.*.wasm32`
两条 key 分别对应上面两种产物。`Build-Web.cmd` 默认 `threads=yes`，可用
`PK_WEB_THREADS=no` 临时切回 nothreads。

threads 变体需要页面处于 **cross-origin isolated** 状态（SharedArrayBuffer）：
`tools/serve_web.py` 已经发 `Cross-Origin-Opener-Policy` + `Cross-Origin-Embedder-Policy`。
部署到静态托管时若不能设置这两个响应头，浏览器会拒绝启动。

### 3.2 必须 `disable_exceptions=no`

godot-cpp 默认给所有平台加 `-fno-exceptions`，而 native 运行时里
`economy_change_registry.h` / `economy_tracked_journal.h` / `economy_runtime.h`
等 11 个头/实现文件用 `throw` 报经济不变量错误。不改这个选项，编译直接失败：

```
src\economy_change_registry.h:148:13: error: cannot use 'throw' with exceptions disabled
```

Godot 4.6 的 dlink 主模块自带 wasm exception tag，所以打开异常后的 side module
可以正常导入 `env.__cxa_throw` / tag 并加载（已实测）。

## 4. 产物与体积

`Build-Web.cmd` 导出后 `WebBuild/` 约 **345 MB**：

| 文件 | 体积 | 说明 |
| --- | --- | --- |
| `ProjectKeynes.pck` | ~282 MB | 全部资源（主要是纹理 ctex + 字体） |
| `ProjectKeynes.side.wasm` | ~38 MB | dlink 主模块侧的扩展容器 |
| `libdots_ext.web.template_release.wasm32.wasm` | ~12.5 MB | dots_ext side module |
| `ProjectKeynes.js` / `.wasm` | ~5.5 / 1.5 MB | 引擎 glue 与主模块 |

`Web` 预设的 `exclude_filter` 已经把 web 上不需要的东西剔出 pck：
`addons/FmodGodot/*`（FMOD 没有 web 库）、`assets/audio/banks/*`（91 MB FMOD bank）、
`tests/ tmp/ test_output/ tools/ android/ docs/`。

继续压缩的方向（未做）：纹理走 VRAM 压缩 / mobile import 预设、字体子集化、
按场景拆分 PCK。

## 5. Web 平台能力边界（代码里已有的）

| 能力 | Web 上的行为 | 出处 |
| --- | --- | --- |
| 作者地图（PKMAP） | 隐藏，只能用程序生成 | `scripts/ui/main_menu.gd` `_configure_map_source_options()` |
| 地图尺寸 | 上限 100 × 70（桌面 500 × 400） | `scripts/data_core/feature_flags.gd` `max_map_width/height` |
| 渲染 | Compatibility/WebGL2，shader 走 mobile 质量档 | `feature_flags.uses_shader_quality_tier()` |
| 地形烘焙 | 跳过 GPU horizon bake，降纹理尺寸 | `scripts/rendering/map_baker.gd` |
| 建筑/植被细节 | 降低常驻实例上限、关影子 | `building_visual_layer.gd`、`trade_activity_layer.gd` |
| FMOD 音频 | 不加载（extension 只声明了 windows/linux/android/mac 库），回落原生音频 | `scripts/audio/game_audio_service.gd` |
| 存档后台写 | 关掉后台线程写 | `scripts/game/game_save_coordinator.gd` |
| 仿真线程 | nothreads 变体全在主线程；threads 变体才有 worker | 见 §6 |

## 6. 已知问题

### 6.1 `nothreads` 变体会卡在"进入世界"98%（不要用这个变体）

`threads=no` + `variant/thread_support=false` 能进主菜单、开新游戏、生成世界，
但加载条到 98% 后**主线程硬卡死**（画面完全冻结，两次截图逐像素相同），
`_loading_profile_step` 最后一条日志停在
`_publish_bootstrapped_natural_resources_to_runtime` / `_try_register_native_daily_sim_job`
附近，而且两次运行的卡点并不完全一致。

根因是 native 运行时的工作线程：`gdext/src/native_simulation_host.cpp` 用
`std::thread` 工作线程 + `std::condition_variable`（`_control_cv.wait(...)`、
`_climate_wait_cv.wait_for(..., 100ms)` 重试循环）驱动每日仿真，全仓**没有**
无 pthread 时的单线程内联分支（唯一的 `__EMSCRIPTEN__` 判断在
`world_ext_loading.cpp:177`）。没有 pthread 的 wasm 里 worker 不会推进，任何等
worker 的条件变量循环只能空转 → 页面冻结。

`threads=yes`（现状）没有这个问题：同一套流程在真实 GPU 的浏览器里
约 10 秒就走过资源/生态/bootstrap 段并进入世界。

真正的"永久修复"是给 native host 加单线程内联模式（web 上不 spawn worker，
直接同步跑切片），这属于 `native_simulation_host.cpp` 的架构改动，尚未做。

### 6.2 浏览器主线程会被阻塞

threads 变体下控制台会打印：

```
Blocking on the main thread is very dangerous, see
https://emscripten.org/docs/porting/pthreads.html#blocking-on-the-main-browser-thread
```

也就是说 native host 在等 worker 时把浏览器主线程堵住了。短时间没问题（加载
阶段实测约 10~20 秒的停顿），但长仿真日或低端机器上可能出现"页面无响应"。
后续方向同上：host 侧改异步/切片，或在 web 上降低 `native_daily_sim_stride`。

### 6.3 `FamilyFoundingDialog` 的 `%CardsScroll` / `%Status` 取不到

新游戏时控制台会报：

```
ERROR: Node not found: "%CardsScroll" (relative to ".../FamilyFoundingDialog").
ERROR: Node not found: "%Status" (...)
```

`scenes/ui/family/family_founding_dialog.tscn` 里两个节点没标
`unique_name_in_owner = true`，而脚本用 `%` 唯一名访问。**与平台无关**
（桌面同样会报），属于顺带发现的既有 bug。

### 6.4 已修：植被 shader 在 WebGL2 上编译失败

`shaders/include/vegetation_impostor.gdshaderinc` 原来写
`VegSurf s = far ? vf_far(...) : vf_eval(...);`，GLSL ES 3.0 不允许
`?:` 的操作数是 struct：

```
ERROR: 0:2563: '?:' : ternary operator is not allowed for structures in ESSL 1.0 and webgl
```

已改成 `if/else` 分支（桌面 SPIR-V 行为不变）。修之前这行会让整片植被 shader
绑定失败并往控制台 dump 近 3000 行 GLSL。

## 7. 验证方法

```bat
:: 1) 只验"页面能不能起来"（headless 即可，30~60s）
python tools\verify_web_export.py  --url http://127.0.0.1:8060/ProjectKeynes.html

:: 2) 验完整会话：点新游戏 → 开始游戏 → 等世界加载（需要真实 GPU）
python tools\verify_web_session.py --url http://127.0.0.1:8060/ProjectKeynes.html --no-headless
```

两个脚本都用本机 Selenium 缓存里的 Chrome，把浏览器控制台、截图写到
`artifacts/web_export_verify/`（会话脚本用 `--out` 换目录）。判定项：

- `Build configuration: ... multi-threaded, GDExtension support.`
  （引擎起来了、线程变体、扩展支持开）
- `[native_generation/base] path=gdext ...`（C++ 世界生成真的在跑，不是回落 GDScript）
- `[loading-substep]` 一路推进到加载结束
- 无 `CanvasShaderGLES3` 编译错误
- 最终截图里出现顶栏日期 / 人口 / 详情面板（= 真的进世界了）

**注意**：`--headless` 下 Chrome 走 SwiftShader（软件 WebGL），加载会慢到
`2%` 就不再动，只适合做第 1 步的启动检查；完整会话请用 `--no-headless`
（会短暂开一个 Chrome 窗口）。

手动验证顺序：主菜单 → 新游戏 → 开始游戏 → 加载完成 → 地图与 HUD。

本次验证留档（2026-10-30）：
- 启动检查：`artifacts/web_export_verify/web_boot.png`
- 会话：`artifacts/web_export_threads/wait_final.png`（第 1 年 1 月 1 日，
  人口 40，满意度 100%，就业率 75%，详情面板「奈良 · 聚落」）

