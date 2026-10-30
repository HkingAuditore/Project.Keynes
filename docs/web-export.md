# Web 导出（Project.Keynes → 浏览器）

本文记录 Web 导出的完整链路、两个必须对齐的编译约束，以及当前验证到什么程度。
一键脚本是仓库根目录的 `Build-Web.cmd`，产物落在 `WebBuild/`。

> `WebBuild/` **不进版本库**（pck 约 282 MB，超过 GitHub 单文件 100 MiB 硬限制），
> 已加入 `.gitignore`；发布走 `.github/workflows/web-build.yml` 的 artifact / Release。
> 新机器从零构建的完整前置条件与各平台工具链见
> [`docs/build-from-source.md`](./build-from-source.md)。

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

脚本做三件事：

1. `gdext/` 里按下面的固定 flag 编 wasm side module；
2. 在独立 headless 进程里预烘加载目录快照（见 §8，失败即中止导出）；
3. 用 Godot headless 导出 `Web` 预设到 `WebBuild/ProjectKeynes.html`。

日志：`tmp/web_prebake.log`、`tmp/web_native_<target>.log`、`tmp/web_export_release.log`。

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

`Build-Web.cmd` 导出后 `WebBuild/` 约 **345 MB**（本地产物，不提交；体积构成与瘦身方向见
[`build-from-source.md` §7.1](./build-from-source.md#71-pck-现在-282-mb-花在哪实测目录明细)）：

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

## 8. 预烘加载目录（loading catalog prebake）

新开游戏时要编译 effect / economy / technology / research / display 五套目录。
实测（headless，win64）：`EffectDomainCatalog.build()` **4.47 s**，
`EconomyCatalog.compile_native_catalog()` **1.71 s**，每次新游戏都付一次。

`Project/project-keynes/data/loading_catalog_v1/*.res` 就是这些编译结果的快照，
由 `scripts/game/loading_catalog_cache.gd`（`LoadingCatalogCache`）加载。
命中与不命中的差距是数量级的：

| 入口 | 未命中（现编译） | 命中（预烘快照） |
| --- | --- | --- |
| `LoadingCatalogCache.prepare()` | — | 0.24 s（含 860 条指纹校验 + 6 个 .res 反序列化） |
| `EffectDomainCatalog.build()` | 4472.8 ms | **0.10 ms** |
| `EconomyCatalog.compile_native_catalog()` | 1713.3 ms | **1.79 ms**（返回前仍 duplicate 一份 457 keys 字典） |

也就是说**缓存不命中 = 每个新游戏多花 4–5 秒**（还伴随几百 MB 的 .tres 重新读取）；
而且编辑器进程里编译会直接失败（见 §8.2），所以"快照过期"不是小事。

### 8.1 预烘命令

```bat
:: 独立进程预烘，成功 exit 0 / 任何一步失败 exit 1
"%GODOT%" --headless --path Project\project-keynes ^
    --script res://tools/prebake_loading_catalogs.gd
```

输出示例（会打印每个 `.res` 的字节数、各阶段耗时、`sources.json` 条目数）：

```
[loading-catalog] economy     1921 ms  457 keys
[loading-catalog] effect      5215 ms
[loading-catalog] display      325 ms
[loading-catalog] saved     economy.res              280342 bytes     18 ms
...
[loading-catalog] saved     sources.json             102713 bytes    143 ms  860 entries
[loading-catalog] bake OK, 7 files, total 7982 ms
[loading-catalog] PREBAKE OK: 860 entries, 8.0s
```

`Build-Web.cmd` 在导出前跑的就是这条命令（日志 `tmp/web_prebake.log`），
`errorlevel 1` 直接 `exit /b 1` 中止，不导出——宁可构建失败，也不发一个
"每次新开游戏慢 5 秒"的包。

### 8.2 为什么必须独立进程、且必须早于导出

`addons/loading_prebake/plugin.gd` 的 `_export_begin` 跑在编辑器进程里。
这时 GDScript 的 scripting 是关闭的，非 `@tool` 脚本挂到 Resource 上只会得到
占位脚本实例（`PlaceHolderScriptInstance`），`.tres` 里没有显式存储的属性
（即脚本默认值）全部读成 `null`：

- 表面现象：`economy_catalog.gd:91` 的 `need.use_tags as PackedStringArray`
  在 `null` 上抛 `Invalid cast`，编译中断，`bake()` 返回 `ERR_INVALID_DATA`；
  旧日志里就是 `ERROR: Loading catalog export bake failed: Invalid data`，
  随后插件把 `sources.json` 写成 `{}`，让导出包 100% miss。
- 更危险的是：即便绕开这处 cast，`satisfaction_weight_q16` 之类的默认值也会
  静默变成 `0`，烘出一份"能加载但内容错"的快照。所以**编辑器进程内根本不允许
  编译目录**，不是加个 try/catch 能解决的。

现在的导出 hook 只做校验与打包：先比对 `sources.json` 与当前源文件 sha256；
不一致就 `OS.execute` 拉起一个独立 headless 子进程重烘（同步阻塞，不需要
await/线程）；仍然不一致就 `push_error` 给出可直接照抄的命令，并继续打包磁盘上
已有的快照（**不再写 `{}`**），同时打印每个文件的字节数，便于在导出日志里确认。

### 8.3 快照文件

目录：`Project/project-keynes/data/loading_catalog_v1/`（7 个文件，均被 git 跟踪）

| 文件 | 内容 | 当前大小 |
| --- | --- | --- |
| `economy.res` | `EconomyCatalog.compile_native_catalog()` | 280342 B（457 keys） |
| `effect.res` | `EffectDomainCatalog.build()` 的 Effect IR | 237428 B |
| `effect_extensions.res` | 上面 IR 的 `native_extensions`（family/era 扩展 IR） | 12276 B |
| `display.res` | 经济面板显示名（profession/ethnicity/building/need/good/family） | 61165 B |
| `technology.res` | `TechnologyCatalog.compile_native_catalog()` | 165209 B |
| `research.res` | `ResearchSignalCatalog.compile_native_catalog()` | 6684 B |
| `sources.json` | 860 条源文件 sha256 指纹（判定快照是否新鲜） | 102713 B |

指纹覆盖 `res://scripts/{research,economy,family,effect,ideology,modifier,trigger,data,country}`
与整个 `res://data/` 下的 `.gd/.tres/.json/.csv`。改过这些文件后必须重烘；
否则 `LoadingCatalogCache.prepare()` 会打印
`[loading-catalog] 预烘快照未命中：…（原因）` 并回退源编译器。


