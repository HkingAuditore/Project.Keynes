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

### 4.1 Web 字体子集化（2026-10-31，已落地）

> 本节取代上面那句"字体子集化（未做）"。纹理那几项仍未做。

`.fontdata` 是 pck 里第二大的单项（**56.73 MB / 9 个字体**）。gzip 压不动它
（纹理已经是 VRAM 压缩格式，整个 pck 只有 0.45% 的压缩余量），所以只能裁内容：
把字体裁成"游戏真正会渲染的字符"。

**为什么不能只是"换掉字体文件"**：Godot 打包的是导入产物
`res://.godot/imported/<name>.fontdata`，而 `res://assets/fonts/...` 的引用、
`.import` 的 remap 路径都是固定的。改源文件会污染 git、影响桌面构建；改引用又会
让桌面构建一起用子集。所以 `tools/subset_fonts.py` 走"借用导入缓存"：

1. 扫 `Project/project-keynes/**/*.gd|*.tscn|*.tres|*.json|*.csv|*.cfg|*.txt` 里的非 ASCII
   字符（含 `\uXXXX` 转义）+ ASCII 全集 + 标点/符号/全角/拉丁扩展冗余区段 +
   脚本顶部 `EXTRA_SAFE_CHARS` 白名单 + **GB2312 一级汉字（3755 常用字）**。
   最后一项是给"玩家自己输入的文字"兜底的：主菜单的国名输入框、各处搜索框都是
   `LineEdit`，IME 打的字不可能出现在源码里，而国名还会以手写体印在年度报告封面
   （漏字 = 直接可见的方块）。不想要这份保险：`PK_WEB_FONT_SUBSET_NO_GB2312=1`
   （pck 再小 ~5 MB，但玩家输入的生僻常用字会变方块）；
2. fontTools 逐字体子集化 → `tmp/web_font_subset/fonts/`（缓存，gitignored；
   `assets/fonts/` 里的源文件一个字节都不动）；
3. 在 `tmp/web_font_subset/import_proj/` 建一次性迷你 Godot 工程，沿用原 `.import`
   的 `[params]`，让**真正的导入器**生成 `.fontdata`（不手写引擎格式）；
4. 备份 `.godot/imported/<name>.fontdata` → 覆盖成子集产物 → 导出 → `restore` 还原。

**自检**（任何一项失败都不出包）：

| 检查 | 做法 | 结果 |
| --- | --- | --- |
| 子集丢字 | 逐字体比对子集前后 cmap，原字库能渲染的字符必须一个不少 | 丢失 0 |
| 导入产物丢字 | 子集 `.fontdata` 让 Godot `load()` 后逐字 `Font.has_char()` | 35545 字符，缺失 0 |
| 打包打错 | 导出后解析 pck 目录，比对每个 `.fontdata` 的 md5 与子集产物 | 8/8 命中 |
| 未知缺字 | 源码里出现、但没有任何随包字体能渲染的字符 | 已知 16 个（见下），新增即失败 |

**实测**（2026-10-31，`Build-Web.cmd skip-native`）：

| 项 | 前 | 后 |
| --- | --- | --- |
| `.fontdata` 合计 | 56.73 MB | **12.71 MB**（-77.6%） |
| `ProjectKeynes.pck` | 282.76 MB | **238.74 MB**（-44.0 MB / -15.6%） |
| `WebBuild/` 合计 | ~342 MB | ~298 MB |

> 关掉 GB2312 兜底（`PK_WEB_FONT_SUBSET_NO_GB2312=1`）的话是 `.fontdata` 8.04 MB /
> pck 234.08 MB（-48.7 MB / -17.2%）。默认选择多花 ~4.7 MB 换"玩家自己输入的中文不会
> 变方块"，理由见上面字符集第 4 层。

逐字体（`kept` = 子集保留的字符数；体积是 pck 里那 9 个 `.fontdata` 的实际大小）：

| 字体 | kept | .fontdata 前 → 后 |
| --- | --- | --- |
| `swei/SweiGothicLegCJKsc-Regular.ttf` | 4857 | 10.13 → 1.01 MB |
| `swei/SweiGothicLegCJKsc-Bold.ttf` | 4799 | 9.84 → 0.99 MB |
| `noto_serif_sc/NotoSerifSC-SemiBold.otf` | 4815 | 10.27 → 1.33 MB |
| `source_han_serif/SourceHanSerifCN-Regular.otf` | 4817 | 10.10 → 1.32 MB |
| `source_han/SourceHanSansCN-VF.woff2` | 4817 | 7.38 → 1.11 MB |
| `annual_pencil/Muyao-Softbrush-2.ttf` | 3967 | 2.69 → 1.80 MB |
| `annual_pencil/PFanHuTuTi_Min.ttf` | 3506 | 3.51 → 3.25 MB（该字体只有 3718 个字形，几乎裁不动） |
| `muyao/Muyao-Softbrush-2.ttf` | 3967 | 2.69 → 1.80 MB |
| `fontawesome/fa-solid-900.woff2` | 2009 | 0.12 → 0.12 MB（图标字体，保持完整） |

**单独跑**（只子集 + 自检，不动 `.godot`，不导出）：

```bat
python tools\subset_fonts.py              :: = subset，打印覆盖率，exit 0
python tools\subset_fonts.py prepare --godot "%GODOT_BIN%"   :: 子集 + 注入（Build-Web.cmd 做的事）
python tools\subset_fonts.py status       :: 看 .godot 是否还残留注入
python tools\subset_fonts.py restore      :: 手动还原
```

**回退**：`set PK_WEB_SKIP_FONT_SUBSET=1` 再跑 `Build-Web.cmd` → 跳过整个步骤，
按老样子打全字库（pck 回到 ~282 MB）。构建被强杀导致 `.godot` 残留子集时，下一次
`prepare` 会先自动还原（`tmp/web_font_subset/pending_restore.json`）。

**边界 / 风险**：

- 字符集 = 源码扫描 + GB2312 一级汉字，所以玩家输入的中文只要在 3755 常用字内就正常；
  **生僻字 / 繁体字 / 日韩文输入**仍可能缺字（这类字符不在常用字表里）。
- 字符集来自源码扫描，**新写的文案**（新 `.gd`/`.json` 字符串）会自动进入下次构建；
  但"运行期才拼出来、字符不在任何源文件里"的字扫不到 —— 目前游戏文本全部来自
  `.gd/.tscn/.tres/data/*.json`，且导出前 prebake 会按这些源码重建 `.res` 目录，
  所以这个缺口是空的；真出现时把字加进 `tools/subset_fonts.py` 的
  `EXTRA_SAFE_CHARS` / `EXTRA_SAFE_HANZI` 即可。
- `allow_system_fallback=true` 在 Web 上没有系统字体可回落，所以"所有随包字体都没有
  的字符"一律是方块。已知这类字符记在 `KNOWN_UNCOVERED_CHARS`（含位置注释）。
  其中 **`▴ ▾ ▸` 是家族卡 / 殖民面板的真实 UI 箭头**（桌面靠系统字体渲染，
  Web 上本来就是方块）——这是子集化之前就存在的问题，建议后续把文案换成
  `▲ ▼ ▶`（这三颗字 Swei 有）。
- `fontawesome/fa-solid-900.woff2` 保持完整：图标码位是 PUA（U+E000..），源码里
  以数字/名称引用，按文本裁会丢图标（且它只有 118 KB）。实际上图标走
  `assets/icons/**` 的纹理，这个字体目前并不参与绘制。
- 依赖 `python -m pip install fonttools brotli`；缺了会直接报错并打印安装命令。
- 子集缓存按"字体文件 + 字符集 + 参数版本"做指纹：只改文案会重跑（约 2 分钟，
  其中思源黑体 VF 的 gvar 子集占 80 秒），不改则命中缓存（约 10 秒）。

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
## 9. Web 加载耗时实测与 web 专用开关（2026-10-30 晚）

用 `tools/serve_web.py` 的 `POST /_log` 事件通道实时观测（写 `tmp/web_events.jsonl`，
agent 侧 tail 即可，不需要截图轮询）。60×40 = 2400 cell 的一次新游戏：

| 阶段 | 修复前 | 现在 | 说明 |
| --- | --- | --- | --- |
| 加载目录（effect_catalog 等） | 3742 ms | **67 ms** | 预烘快照命中 |
| 资源矿藏 bootstrap | 1167 ms | **100 ms** | `run_resource_deposit_pass`（C++），与旧路径逐 bit 相同 |
| 植被图层构建 | 17 层 × 200–400 ms | **每层 0.5–1.6 ms** | 加载期只 defer，进世界后分帧补 |
| 建筑外观 catalog | 42 s | **7 ms**（延后） | web 上改为进世界后 3s 再补 |
| 定居点标签层 | 45 s 量级 | **延后** | web 上改为进世界后 4s 再补 |
| 气候 prewarm | 63 s | **跳过** | web 上第一个 daily tick 会重算 |
| worker 启动/输入 capture | 5.7 s + 卡死 | **跳过** | 浏览器里 native host 的 day barrier 收不了尾 |

**web 专用开关（都在代码里，带中文注释）**

- `player_game._configure_runtime()` / `world_runtime_host._start_production_shadow_worker()`：
  web 不请求 worker 权威、也不起 SHADOW worker。
- `map_generator._try_register_native_daily_sim_job()`：web 直接回退 legacy 协作 SUS。
- `map_generator._c()`：web 关掉 `use_climate_round_async`（线程池打满后
  `pthread_create` 失败，等待退化成超时 = 63s）。
- `world_runtime_host`：web 跳过 `refresh_climate_loading` / worker input capture /
  `refresh_building_visual_catalog` / `_bind_settlement_labels`（后两者进世界后 timer 补）。

**已进一步压缩（2026-10-30 深夜）**

- `RuntimeForensics.dump()` 在 web 上整段跳过（原来 `JSON.stringify` ×2 + `duplicate(true)`
  + 把数 MB JSON 打进浏览器控制台，实测单次 45 s），改为只发一条 `forensics_skipped` 事件。
- 低配档 shader 前缀补上 `PK_QUALITY_LOW` / `PK_MOBILE_ANY`（原来只给
  `MOBILE_QUALITY_LOW`，于是浏览器一直在编译桌面重型分支）：`_renderer.set_map`
  从 **5.5 s → 0.32 s**。

**当前仍剩的一次约 45 秒首帧**：`start_worker` 之后的那一帧（第一次真正把地图画出来），
是 ANGLE/FXC 编译全屏着色器（world_map / weather_overlay / fog_of_war 三个 29–43 KB 的大
shader）的耗时；事件通道显示这一帧前后相邻步骤只隔 40 ms，纯 GPU 侧。
下一步候选：web 上关掉 weather overlay 图层、给 fog/world 用裁剪版 shader，或做 shader 预编译清单。
### 9.1 首帧 ~45–50 s 的定位记录（2026-10-30 深夜，两轮探针）

已排除的假设（都做了实测探针）：

1. **不是 world_map 材质编译**：web 上把世界材质换成 3 行内联 shader，`start_worker_step → post_worker_frame` 仍需 45 s。
2. **不是迷雾 shader**：web 上关掉 `fog_of_war` 图层，同样 45 s。
3. **不是低配宏没生效**：补上 `PK_QUALITY_LOW` / `PK_MOBILE_ANY` 后 `_renderer.set_map` 从 5.5 s → 0.31 s（这步确实有效），但长帧不变。
4. **不是加载逻辑的 `await`**：web 上把 `start_worker` / `visual_done` 两处 `await get_tree().process_frame` 去掉后，`ready` 紧贴绑定链发出（5 ms 内），长帧只是换了个位置。

剩下的最强嫌疑：**pthread 池耗尽**。控制台在长帧前后反复打印
`Tried to spawn a new thread, but the thread pool is exhausted`；Emscripten 的固定池由官方
模板编译期决定，导出预设里的 `threads/emscripten_pool_size=16` 只能写进 HTML 的
`GODOT_CONFIG.emscriptenPoolSize`，改不了模板里的固定值。引擎侧一旦在池满时反复
`pthread_create`，就会退化成"自旋等空位"，表现为**一整帧卡 45 s**（这也解释了为什么换
shader、换路径都不影响它）。

下一步（按性价比）：
- web 上把 `LoadingCatalogCache.prepare()` 与 player 场景加载从 `load_threaded_request`
  改成同步加载（池里少占线程）；
- 或定位到具体在 spawn 的调用（`WorkerThreadPool` 任务 / 扩展里的 `parallel_for_range`），
  在 web 上把这些并行 pass 退化成串行。
### 9.2 45 秒长帧已定位并解决：weather_overlay shader（2026-10-30 定案）

**结论**：`res://shaders/weather_overlay.gdshader`（35 KB 全屏 canvas shader）的**首次绘制编译**
在 ANGLE 上要 45 秒。它就是"进世界卡 98%"的唯一原因。

排除过程（每条都是一次真实浏览器会话 + 事件流）：

| 探针 | 改动 | 长帧 |
| --- | --- | --- |
| 世界材质 | web 上把 `world_map` 换成 3 行内联 shader | 仍 45 s |
| 迷雾 | web 上关 `fog_of_war` 图层 | 仍 45 s |
| 线程池 | 统计 `thread pool is exhausted` | 全集中在 t=19 s（烘焙期），不在长帧附近 |
| 天气层 | web 上不创建 `WeatherLayer` | **消失**，整链 7.2 s ready |
| 天气层（隐藏） | `visible=false`（层内 SubViewport 仍渲染） | 仍 45 s |
| 天气 shader | 把 overlay shader 换成全透明 stub | **消失**，7.3 s ready |

**落地做法**：`weather_layer.gd` 里 `PK_WEB_ENABLE_WEATHER_SHADERS := false`，web 上
overlay/curtain 两套大 shader 用全透明 stub 顶替（天气叠层在 web 暂时不可见，不影响模拟）。
`hex_renderer.gd` 保留 `PK_WEB_TRIVIAL_WORLD_SHADER_PROBE` 探针常量（默认 false）与说明。

**实测结果（最终交付 build）**：`day 0 → ready` = **7.3 秒**（`set_map` 0.33 s、bind 1.45 s、
building visual 12 ms、worker 6 ms）。加载条按阶段文案走完，不再钉在 98%。

### 9.3 仍未解决：ready 之后的一次 ~49 秒顿挫

`ready` 之后第一帧到第二帧之间仍有 ~49 秒。已排除：天气 shader、世界材质 shader（stub 后
依旧）、fog、"逐层 await"（已去掉）。剩下嫌疑：首帧的贴图上传（enum/dyn LUT、图集）、
建筑/植被的首次填充，或第一个 daily tick 本身。下一轮用 `_process` 分阶段打点定位。
### 9.4 ready 之后的 50 秒顿挫已解决：植被首帧全量填充（定案）

天气 shader stub 之后仍剩一次 ~50 秒（`frames 1 → 2`）。逐项排除：

- fog shader（43 KB）换成纯色极简版 → 仍是 50 s；
- 世界材质 trivial shader → 仍是 50 s；
- **植被层 disabled（keep ratio 0）→ 顿挫消失**（frames 1→14 只用 5 s）。

根因：`_seed_deferred_detail_chunks_for_deferred_fill()` 按 **整张世界 bounds** 登记 deferred
chunk，视野覆盖全图时第一帧就把 `12 chunk × 9 层` 全排进补建队列，浏览器上一整帧跑完。

修法：web 上只登记**当前相机视野 ×1.25**（相机未就绪时只种世界中心 1/4 区域），其余 chunk
等玩家移动时按既有 prefetch 视口再补。`WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO` 保持 0.5（用户已
批准减半）。

**最终实测（交付 build，60×40 图）**

```
day 0（生成开始） 41396 ms
ready（进世界）   48854 ms   ← 7.5 秒
frames 1→9        53949 ms   ← 5 秒内 8 帧，无长帧
day 1             81614 ms   ← 日历开始推进（随后因经济 fatal 暂停，见 9.5）
```

### 9.5 未解决：day 1 经济 fatal（`country_fiscal_peer_apply_ack_failed`）

web 上为了绕开 native worker 的 day-barrier 死锁，权威位退回主线程；但 economy 的 fiscal
资产协调要求一个 worker "peer" 完成 apply→ack，主线程权威下 ACK 回不来，于是
`NativeEconomyRuntime` 在 day 1 fatal 并把仿真暂停（日历能推，但经济结果不可信）。

修法选项（native 改动）：`economy_runtime.cpp` 的 `coordinate_country_fiscal()` 在没有 worker
peer 时走同步 ack 分支（把"主线程即 peer"当作合法身份），或 web 上跳过 fiscal 协调。
### 9.6 最后一处 ~50 s：植被层 shader 的首次编译（2026-10-30 收尾）

天气 / 迷雾 stub 之后，`ready` 之后仍有 ~50 s 一次长帧。用同一 build 连跑三次得
`ready` 分别 7.5 s / 62 s / 8.0 s —— 说明这 ~50 s 始终存在，只是按帧序落在 `ready` 前或后，
不是缓存问题。

进一步收窄：

- 把初始 deferred chunk 从"整图 / 整幅视野"缩到"世界 12% 见方（约 1 个 chunk）"后，
  长帧仍是 52 s（frames 1→2 49778 → 101892 ms）→ 不是 chunk 填充量；
- 但把植被层整体关掉（`WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO = 0`）时长帧消失 →
  是**植被层本身**，最可能是那套 `vegetation_impostor` + forms 的大 shader 首次编译
  （9 层共用同一 shader，只编译一次，但那一次就是几十秒）。

下一步候选（未做）：给 web 出一个裁剪版植被 shader（例如只保留 `vf_far` 远景 LOD、
砍掉 `vf_eval` 的近景分支），代价是近处植被形状变简单。
### 9.7 最后 50 秒已消除：web 植被 shader 只编远景 LOD（定案，2026-10-30 收尾）

`ready` 之后那次 ~50 s 最终确认是**植被层 shader 的首次编译**（关掉植被层即消失，缩 chunk
不变）。落地做法：

1. `shrub_layer._shader_quality_define_prefix()` 原来只判 `OS.has_feature("mobile")`，
   **web 一直被当成桌面**、编译近景 form 全套。现在 web 也走受限平台档
   （`MOBILE_QUALITY_*` + `PK_SHADER_TIER_*`）。
2. web 额外加 `#define PK_VEG_FAR_ONLY`：`vegetation_impostor.gdshaderinc` 里
   `vf_eval(...)` 分支整段被 `#ifdef` 掉，只调远景 `vf_far(...)`，编译器把
   broadleaf/conifer/palm/… 那一整套近景函数整段丢弃。
3. fog shader **恢复完整版**（`PK_WEB_ENABLE_FOG_FULL_SHADER := true`）：早先的纯色 stub
   会把整幅地图盖住，实测完整 fog shader 并不慢，不需要降级。
4. 初始植被 deferred chunk 只种“世界 12% 见方 ≈ 1 个 chunk”，其余随相机流式补齐。

**最终实测（交付 build，60×40）**

```
day 0（生成开始） 42476 ms
ready（进世界）   50269 ms   ← 7.8 秒
frames 1→9        55793 ms   ← 5.5 秒内 8 帧，无长帧
day 1             83983 ms   ← 首次 daily tick（~28 s，主线程权威）
```

视觉：地形、迷雾边沿、植被均正常（植被是远景 LOD 形态）。加载条按阶段推进，不再钉 98%。
### 9.8 撤回 web 的运行时降级 + 日历推进现状（2026-10-30 深夜）

shader 裁剪修好之后，之前为了绕开"卡死"而做的运行时降级都不再需要，已全部撤回：

| 曾经的 web 降级 | 撤回理由 |
| --- | --- |
| worker input capture 跳过 | capture 本身没问题，卡死是 shader 编译堵住整帧 |
| SHADOW worker 不启动 | 停 worker 后日历完全不推进 |
| 权威位退回主线程（mask=0） | **只有 ACTIVE 才 commit day**，SHADOW 会停在 day 1 |
| `_try_register_native_daily_sim_job()` 回退 GDScript SUS | 该守卫让 worker 图没有 daily job，时钟被看门狗暂停 |

保留的 web 专用改动（都是必要的性能/正确性修复）：

- 天气层 shader 换成全透明 stub（`PK_WEB_ENABLE_WEATHER_SHADERS := false`）；
- 植被 shader 只编远景 LOD（`PK_VEG_FAR_ONLY`）+ web 走受限平台档；
- 初始植被 chunk 只种约 1 个；
- `RuntimeForensics.dump()` web 跳过；
- 加载期 defer 建筑外观 / 定居点标签；
- fiscal `peer-applied ack` 在无 worker 权威时不再升级为 fatal（`economy_runtime.cpp`）。

**当前实测**：`ready` = 7.7 s（`day0 43775 → ready 51441`），无 fatal、时钟保持 `paused=false`，
但 `fast_ticks` 停在 1、day 停在 1 —— 即 **day barrier 在浏览器里仍收不了尾**（缺哪个域尚未定位；
native 侧的 `sim/graph-barrier/day` 这次没有打印，说明还没走到 barrier 汇总）。

下一步：给 day barrier 加 web 侧的域级打点（哪个域没 commit），再决定是补 commit 还是放宽 barrier。
### 9.9 day barrier 诊断（2026-10-30 深夜，已进事件流）

`stall` 事件现在带域级诊断（`WebTelemetry`，小 payload）：

```json
{"e":"stall","day":1,"fast_ticks":1,"paused":false,"mask":0,
 "coverage":"runtime_graph_not_ready","economy_commits":0,"country_commits":-1}
```

对照 `native_simulation_host.cpp` 的 `report()`：

- `coverage_blocker = "runtime_graph_not_ready"` 只在
  `authority_ready == false && missing_domain_mask == 0` 时产生；
- 也就是说域处理器都实现了（不缺 handler），但**worker 从未上报 authority ready**，
  所以 `authoritative_domain_mask` 一直是 0、economy 一次都没 commit，日历停在 day 1。

下一步（round 9）：把 `report()` 里剩下的字段也打进事件流 ——
`requested_authority_mask` / `implemented_domain_mask` /
`completion_gate_missing_domain_mask` / `active_gate_blocked` / `state` / `mode`，
定位是哪个 gate 没开（很可能是 `active_gate_blocked` 或 completion gate 里某个域）。
### 9.10 day barrier 定案（2026-10-30 收尾）

用事件流里的 `diag`（每 ~10 s 一次，字段取自 `get_runtime_perf_snapshot`）：

**起 worker 时**

```
fault_code            = day_wait_peer_stall_timeout
simulation_thread_mode = OFF   (requested = ACTIVE)
planned_mask = 0 / committed_mask = 0 / missing_domain_mask = 0
simulation_worker_ready = False
```

即：浏览器里 host 把 ACTIVE 降级成 OFF，worker 线程仍在等永远不来的 peer，
day barrier 超时 → `FAULTED` → 时钟停住。

**不起 worker 时**（当前交付配置）

```
fault_code = ""  / mode = OFF / planned = 0 / committed = 0
日历 0 → 1 正常推进，之后停在 day 1
```

结论：web 上"worker 线程 + POD/peer 交接"这条路径在 wasm 里走不通（缺一个能在
浏览器里回得来的 peer）。当前交付选择**不起 worker**：不会 FAULT、不会卡帧，
日历能走到 day 1；再往后的推进需要给 native daily graph 做一条真正的
单线程内联路径（不依赖 peer handoff），属于新的 native 工作项，不在本次
"加载优化"的 5 项范围内。
### 9.11 天气云层恢复：web 裁剪变体（2026-10-31）

`weather_overlay.gdshader` 的编译成本主因不是体积，而是**一个函数的内联份数**：
`cloud_density_soft()` 的包装 `sample_cumulus_density()` 在 fragment 里被调 7 次、每次还有接缝
伙伴采样 ×2 ⇒ 编译单元里约 16 份副本，每份最多 5 次 `cloud_fbm_evolve()`，而它的 `octaves`
是 **uniform int**（编译期无法折叠），每轮 4 次 `cloud_hash22` = 8 个 `sin()` ⇒ 最坏量级约
3800 个 `sin()`。

落地：

- 新增 `shaders/include/weather_overlay_web_min.gdshaderinc`（5.3 KB，无 `sin`、无循环的双
  octave 值噪声）与 `#define PK_WEB_WEATHER_MIN`；
- `weather_layer.gd`：`PK_WEB_ENABLE_WEATHER_SHADERS := true`（stub 降级为应急开关），
  新增 `WEB_WEATHER_MIN_DEFINE`，web 上 prepend，且排在质量档宏之前；
- 保留：三层云（cumulus / cirrus / 低雾）、覆盖度→密度→不透明度的逐字 remap、昼夜光照
  （`eval_earth_daylight` + `compute_cloud_lighting`）、直接云影、降水 alpha、逐帧 LUT 插值、
  迷雾 gate、完整 uniform 契约；
- 去掉：Perlin fbm 栈、域扭曲、q2 四采样法线梯度、偏移投影阴影、接缝伙伴采样、山雾四点
  抖动权重（改为中心格权重）、云路径上的全部 `sin()`。

桌面路径逐字未变（uniform 集合与 `git HEAD` 一致，已用投毒测试证明桌面专用代码不进 web 编译）。

### 9.12 植被近景恢复 + 实测编译耗时（2026-10-31）

`shrub_layer.gd` 新增两个常量：

| 常量 | 默认 | 作用 |
| --- | --- | --- |
| `PK_WEB_ENABLE_VEG_NEAR_FORMS` | `true` | master 开关；置 `false` 即回到旧的 far-only 行为（无需改 shader） |
| `PK_WEB_VEG_NEAR_FULL_FORMS` | `false` | `false` = `#define PK_VEG_NEAR_MIN`（只编 4 个族：broadleaf/conifer/shrub/grass，占 form 代码 28.8%）；`true` = 全 17 族 |

另外两处避免重复编译：`_ready()` 阶段（还没有 world）保持 far-only 原型，等 `setup()` 才编
近景变体；family-batch 材质在被真正使用前也保持 far-only。

**实测（浏览器事件流，`veg_shader` 事件）**

```
s=body  near=min  layers=9  n=1  ms=8.96     ← 近景变体真正的编译耗时
s=body  near=far  layers=9  n=1  ms=12.55    ← _ready() 的远景原型
s=shadow near=min layers=9  n=1  ms=1.43
```

即"恢复近景"只花了 **约 9 毫秒**，远不是当初的 45 秒；`n=1` 说明每个变体只编译一次。

### 9.13 日历恢复推进：native daily 单线程内联路径（2026-10-31）

day barrier 等的 "peer" 其实就是**主线程自己**：INPUT_CAPTURE 需要主线程发布 day-N 的
`RuntimeEnvironmentSnapshot`，Country 侧 `CountryPeerIntent` 需要主线程
`service_peer_intents_main_thread()`，economy 的 asset/cohort-cash terminal 也由主线程产出。
在 wasm 里这个 pump 被它自己要解开的日历门控住，所以永远等不到 → 5 s →
`day_wait_peer_stall_timeout` → FAULTED。

落地：新增 `native_daily_inline`（`start_runtime_worker(config)` 的配置键，GDScript 只在 web 打开；
桌面用 `PK_NATIVE_DAILY_INLINE=1` 复现）。

- `NativeSimulationHost::run_inline_day()`：同一条 `build_day_plan → execute_day_plan → publish_day`
  链在调用线程上跑完，不 spawn、不 CV 等待、不因 peer pending 设 fault，返回
  `continuation_pending` 让调用方 pump；
- `DCWorldExt::run_native_daily_inline_day()`：同线程 `service_peer_intents_main_thread()` 后重试同一天；
- 顺带修掉一个真正的单线程阻塞点：`prepare_worker_cohort_cash` / `finish_worker_country_asset`
  原先比较 `std::this_thread::get_id() != _worker.get_id()`，内联模式下 `_worker` 不存在，
  会在 day 2 触发 `country_worker_cohort_cash_terminal_missing` → 经济 fatal。现统一走
  语义放宽后的 `on_worker_thread()`。

**实测**

- 桌面 headless（`tests/probes/_probe_native_daily_inline.gd`）：inline ON 6/6 天、12/12 天推进，
  10–20 ms/天；inline OFF（新旧 DLL 都一样）停在 committed_day=1 —— 完整复现了 web 症状。
- 浏览器事件流：`day=113 fast_ticks=113 paused=false worker=RUNNING`，
  `thread_mode=ACTIVE / worker_ready=True / coverage=complete`。

### 9.14 仍存在：第一个内联日约 24 秒（一次性）

逐帧探针（`frame` 事件）实测卡住那一帧：`dt=23 842 ms`，而 `setup=279 ms`、
下一帧 `proc=23 842 ms` —— 时间在主线程 CPU（`_process`），不是 GPU、也不是 shader。

结论：这是**第一个内联日**的一次性原生初始化成本（首日跑完 12 个域），之后每天 10–20 ms。
它落在加载条最后一格，观感就是"卡在 98%"。下一步：给内联日加分域耗时打点，定位并砍掉。
### 9.15 验收工具链：debug 导出 + 无点击自动化 + 看门狗（2026-10-31）

**问题**：之前用 Selenium 点画布坐标驱动测试，两次整轮报废（`开始游戏` 点空，事件流一条没有），
而且 release 构建出问题时没有任何断言/栈信息。

**改动**

1. `Build-Web.cmd`：
   - `debug` 模式以前是**假的**（编 debug wasm，但 `:export_web` 永远 `--export-release` 到同一
     目录）。现在 `:export_web` 按模式选 `--export-debug` + 输出到 `WebBuildDebug/`；
   - 新增 `skip-native-debug`（只导 debug、复用现成 wasm），release/debug 产物彻底分开。
2. `tools/serve_web.py`：新增 `--events`（每个服务用独立事件流，避免 release/debug 交织）
   与 `--no-truncate`。
3. `tools/verify_web_session.py`：
   - `--stall-timeout`（事件流静默即判定卡死，截图+打印最后事件+退出码 2）、`--max-seconds`；
   - `--speed-clicks` / `--speed-at` / `--target-day`（HUD 速度档 1/2/5/10，3 次到 10×）；
   - 点完 `开始游戏` 会**验证事件流有增长**，否则重试一次并截图留证；
   - `atexit` 保证任何退出路径都关浏览器。
4. `tools/web_verify_cycle.py`：进程外看门狗（事件文件静默 = 强杀会话树，且 `wait()` 到真的
   退出，避免孤儿进程）、`--url/--events/--speed-clicks/--target-day`、报告里增加
   **天/秒速率**、出现过的速度档、`diag` 的 fault 字段。

**为什么必须 debug 构建**：release 下 `web.debug.threads.wasm32` 指向的
`libdots_ext.web.template_debug.wasm32.wasm` 从来没有编过（仓库里只有 nothreads debug），
所以 `--export-debug` 会直接失败；而 release 包在模拟卡死时既没有断言也没有栈。
### 9.16 地表发白（world_map shader 解析失败）根因与修复 —— 2026-10-31

**症状**：web 上已探索区域整片白，未探索区（迷雾）正常；控制台每次启动有 1–2 条
`ERROR: shader type  not supported in OpenGL renderer @ shader_set_code`。

**根因**：`shaders/include/shader_quality.gdshaderinc` 里已经有

```
#if defined(MOBILE_QUALITY_LOW)
#define PK_QUALITY_LOW
#define PK_MOBILE_ANY
#endif
```

而 `hex_renderer._shader_quality_define_prefix()` 为压低编译时间，又在 `MOBILE_QUALITY_LOW`
之外**重复** `#define PK_QUALITY_LOW` / `#define PK_MOBILE_ANY`。重复定义让 Godot 的
shader 预处理器失败 → `shader->get_mode()` 为空 → `shader_set_code` 报 "shader type ''"
→ 材质退回默认白纹理 → **已探索区全白**。错误条数与重复宏的数量一一对应
（0 个宏 0 条、1 个宏 1 条、2 个宏 2 条），这也是判定的直接证据。

**修复**：前缀只保留 `#define MOBILE_QUALITY_LOW` + `#define PK_SHADER_TIER_LOW`
（低配档由 include 自行展开成 `PK_QUALITY_LOW`/`PK_MOBILE_ANY`）。修复后：
`shader type` 错误 0 条、脚本编译错误 0 条、`[vision] fog=ON visible=55 explored=55/2400`、
截图确认地表颜色与迷雾均正常。

### 9.17 另一处隐蔽回归：LUT 纹理每帧重绑

`_sync_cell_lut_textures()` 原来用 `_shader_mat.get_shader_parameter(lut_name) == world_tex`
判断纹理是否漂移。**web/GLES3 上这个回读不可靠**（返回的不是同一对象），于是每帧都判成
"过期"，打印 `dyn_lut rebind (material held a stale LUT texture object)` 并把 enum_lut 的
迷雾 uniform 一起重推。改为本地记账 `_lut_bound`（新材质创建时清空），不再依赖回读。
### 9.18 Boot facade 合并（item 5）+ 当前 web 状态（2026-10-31 收尾）

**已落地：`DCWorldExt::run_boot_facade_pass(knobs)`**（`gdext/src/world_ext_boot_facade.cpp`）
把「资源栖息掩码 → 河口强度 → 矿藏 → 研究信号 → 生物占领 → 陆地诊断聚合」这一整条尾部链
合成一次 C++ 调用，并把 `HexCell.bind_world()` 的 39 项 cid 缓存从「每格重算」改成
「第 0 格算一次、其余注入」。

桌面 headless（2400 格、同一 DLL）实测：

| 步骤 | 之前 | 之后 |
| --- | --- | --- |
| `cell_facade_bind` | 299.1 ms | **< 30 ms** |
| 尾部链（resources→signals→bio） | 709.5 ms | **349.0 ms** |
| `autotest_ready` 总时长 | 10 187 ms | **8 954 ms** |

A/B 探针（`PK_BOOT_FACADE_AB=1`）：`moved_mismatch = 0`（habitat / estuary / bio / bio_log 全 0）。
顺带修掉 `run_resource_deposit_pass` 里 `PackedFloat32Array::resize()` 不清零的真实 bug。

**Web 侧 shader 预热（`scripts/rendering/web_shader_warmup.gd`）**：菜单阶段用 1×1 离屏
CanvasItem 预编译 world_map / 迷雾 / 天气 / 植被 body+shadow / 国界线共 6 张 shader。
注意每层前缀必须与运行期**逐字一致**（world_map 带 `PK_WEB_TEXTURE_BUDGET`，迷雾不带），
否则驱动缓存不命中、预热白做。

**植被层 setup 延后**：`_defer_vegetation_layers_after_bind()` 把 9 层植被的构建
（实测 4.1 秒）挪到进世界后 2.5 秒，`veg_deferred_done layers=9 ms≈1.5s`。

**已达成**：进世界最好 **10 012 ms**（60×40）、`shader type` 错误 0、`[vision]` 正常、
10× 跑到 **day 365** 无 FAULT。

**未达成 / 已知问题**：
1. **第一个游戏日偶发硬挂**：`beat` 停在 `day=1 frames=4`、事件流静默、页面画面仍正常
   （截图显示 HUD/年份/10× 都在）。已排除：所有节点 `_process`（曾给 27 个文件加计时包装，
   无一条 >300ms）、host 各阶段、`day_changed` 链、四个大 shader、线程池、Chrome 遮挡节流。
   最新一次排查还用 debug 包（旧 wasm）复现，说明**不是**本轮 native 合并引入的。
2. **进世界时间波动 10–14.3 秒**，未稳定 ≤10s。
3. 10× 下日历速率 1.3–2.9 天/秒（headless 为 9.3），存在 30–50 秒长帧。

**已清理**：27 个文件的临时 `_process` 计时包装、`slow_node` / `slow_phase` / `slow_cb` 探针
已全部撤回（撤包装时还修掉了我自己造成的 `cell_situation_layer.gd` tab 缩进报错）。
`gen_step` / `visual_step` 的耗时字段改名为 `dur`（原先与时间戳 `ms` 混用，导致分析失真）。
### 9.19 「跑不到一年」的根因与修复（2026-10-31 定案）

**症状**：进入世界后日历在 day 6–9 附近整帧不返回——事件流静默、画面冻结在最后一帧、
心跳停止、`setup` 逐帧爬升。曾连续 3 次稳定复现。

**定位链条（每条都有证据）**

1. `slow_frame_trace` 探针（记录每帧各阶段进入时刻，仅在 >2s 帧后补发）证明：
   那次 8.5 秒的帧里，**`_process` 全部阶段加起来只有 4 ms**
   （`proc_begin@0 liveness_begin@0 liveness_end@3 progress_begin@3 progress_end@4`）。
   → 阻塞完全不在 GDScript 逻辑。
2. 用 **SwiftShader（软件光栅）** 跑同一 build，**同样挂在 day 9** → 不是显卡/驱动问题。
3. 关掉植被、关掉内联日、关掉建筑外观+定居点标签延后，挂点只是**移动**（day 6 → day 9），
   → 它们只是改变了时间线，不是根因。
4. 逐层关渲染层（迷雾 / 国界 / 天气）都能跑到 day 365 → 不是这些层。

**根因**：`scripts/rendering/cell_situation_layer.gd` **脚本加载失败**
（`Used tab character for indentation instead of space`，是诊断期批量加计时包装时误引入的）。
脚本挂不上 → `UI/UIRoot/HUDLayer/CellSituationLayer` 节点没有脚本 →
`@onready var _cell_situations` 绑定异常，每帧被调用时反复失败，最终把整帧拖死。

**修复**：撤掉全部临时 `_process` 计时包装（27 个文件），该文件恢复空格缩进、
正常加载。修复后 **连续 5 次** soak 全部跑满一年：

```
day=365  fast_ticks=365  speed=10.0  frames=108,943
最大帧间隔 2,030 ms      ← 无长帧
thread_mode=ACTIVE / worker_ready=True / coverage=complete / fault_code 空
```

这是**正式渲染配置**（迷雾+国界+天气+建筑外观+植被 50% 全开，无任何层裁剪）。

**教训（写进流程）**：给运行时节点批量加计时包装时，必须保持文件原有缩进风格；
`--check-only` 对"tab/空格混用"这类错误只在**加载时**才报，静态检查抓不到全部。

**遗留**：跑满一年后页面出现过一次重载（截图停在 6% 的生成条），疑似年结/年报流程后
WebGL 上下文丢失触发 Godot 的自动 reload；不影响"一年可达标"，但需要单独排查。
### 9.20 「切到高画质就彻底全白」——同一类重复宏 bug（2026-10-31）

**症状**：web 上低画质地面有颜色（但明显偏灰偏糊），用户在设置里切到中/高画质后
**地面彻底全白**。

**根因**：9.16 只修了 `MOBILE_QUALITY_LOW` 这一档的前缀，而
`hex_renderer._shader_quality_define_prefix()` 的 **MID / HIGH 两档仍然重复
`#define PK_MOBILE_ANY`**：

```gdscript
"MOBILE_QUALITY_HIGH": return "...PK_SHADER_TIER_HIGH\n#define PK_MOBILE_ANY\n"
_:                     return "...PK_SHADER_TIER_MID\n#define PK_MOBILE_ANY\n"
```

而 `shaders/include/shader_quality.gdshaderinc` 里已经按档位展开出 `PK_MOBILE_ANY`：

```glsl
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID) || defined(MOBILE_QUALITY_HIGH)
#define PK_MOBILE_ANY
#endif
```

重复定义 → Godot shader 预处理器失败 → `shader type ''` → 材质退回默认白纹理 → 全白。

**修复**：三档前缀只保留「档位」宏，别名一律交给 include 展开。
修复后用 `?tier=low|mid|high`（autotest 新增参数，走
`renderer.set_mobile_quality_tier()` 真实热切档路径）逐档验证：

| 档位 | `shader type` 错误 | 结果 |
| --- | --- | --- |
| low | 0 | 正常 |
| mid | 0 | **正常（此前全白）** |
| high | 0 | **正常（此前全白）** |

同时说明：低画质档本身就是给低端设备准备的（`PK_QUALITY_LOW` 会裁掉大量细节），
偏灰偏糊属预期；想要接近桌面的观感请切到中/高档。
### 9.21 「跑不到一年」的真正根因：天气层把 GPU 拖死（2026-10-31 定案）

前一节把「首日挂死」归到 `cell_situation_layer.gd` 的缩进 bug，那一层修好后确实好过一阵，
但长跑仍会 **偶发 30–50 秒整帧**（`autotest_fail reason=day_stall`），严重时触发
WebGL 上下文丢失 → Godot 自动 reload（这就是"跑满一年后页面回到 6% 生成条"的来源）。

**决定性证据：Chrome DevTools CPU 采样**（`tools/verify_web_session.py --profile`，
卡死时也落盘 `profile.cpuprofile`）：

```
30,017 个采样里 28,176 个（94%）落在 getParameter
调用栈：getParameter ← blitOffscreenFramebuffer ← _emscripten_webgl_do_commit_frame ← MainLoop_runner
```

即每帧一次的**离屏帧缓冲回拷**在 ANGLE 上等 GPU 排队（`blitOffscreenFramebuffer` 里连串
`glGetParameter` 都是同步跨进程调用）。而罪魁是**天气层**：它带 SubViewport 云层，
关掉它之后同一张图、同一份代码立刻顺畅：

| 配置 | 结果 |
| --- | --- |
| 全层（含天气） | 30–50 秒整帧，偶发 reload |
| **只关天气层**（迷雾+国界+植被+建筑全开） | **day 365 / 28,042 帧 / 最大帧间隔 2,049 ms** |

**修复**：`hex_renderer.gd` 新增 `PK_WEB_ENABLE_WEATHER_LAYER := false`——web 上天气层
**仍然创建、所有 set_* 调用照常**，但 `visible = false`（不绘制）。天气**模拟**完全不受影响，
只是少一层云。验证：连续多次 `?autotest=1&days=365&speed=10` 跑到 day 365、
`autotest_start` 只出现 1 次（**没有 reload**）、beat 间隔稳定 2 秒。

**遗留**：进世界仍是 13–16 秒（目标 ≤10s），最大头是 `_bind_country_visuals` 与
`build_indices_cooperative` / bake；下一步按 9.19 的清单继续压。

### 9.20 三项性能目标达成（2026-10-31，钉住 RTX 4080 实测）

本节是这个文件的**结论段**。上面 9.x 的很多数字是在混合显卡机器上测的（Chrome 会在
Intel UHD 770 与 RTX 4080 之间换卡，两者的编译耗时差一个量级），所以那些数字只能当
历史记录看；本节所有数字都在 `--force_high_performance_gpu` 钉住的独显 + 持久浏览器
profile 下测，各 2 轮。

#### 结果

| 目标 | 要求 | 起点 | 现在 |
| --- | --- | --- | --- |
| ① 页面加载 → **主菜单**可见 | ≤20 s | 58.9 s（页面→进世界） | **5.2–6.1 s**（冷/热 profile 一致） |
| ② 点「新游戏」→ 进世界 | ≤15 s | 16.1 s | **9.5–9.8 s**（热 profile） |
| ③ 10× 连续跑一个游戏年 | 无 40 s 级冻结 | 45.9 s 冻结 / 卡在 day 10 | **全年 36.5 s，最长帧 1 350 ms，beat 停顿 0 次** |
| ③ 10× 稳态速率 | — | 2.36 天/秒 | **9.86 天/秒**（9.08–10.22） |

指标口径说明：①**只算到主菜单可见**，不含世界生成（那属于②）。②的 9.5 s 是
`autotest_start → ready`。③的速率取新增 `clock_rate` 事件的中位数 —— 用 beat 跨度算
会把启动阶段平均进去，实测会把 9.86 低估成 1.78。

#### 最重要的一个发现：16–19 秒不属于任何 shader

把一张 **64 字符**的最简 shader 排到预热清单第一位，它自己吃掉 **15 968 / 19 017 ms**，
紧随其后的 `world_map` 只要 **1 943 / 2 200 ms**。再对比：

| 口径 | 预热合计 |
| --- | --- |
| 全新 profile 首次访问 | 30 102 ms |
| 同会话 reload | **1 348 ms** |
| **同 profile、全新浏览器进程** | **2 548 ms**（首张 106 ms） |

⇒ 那是 **D3D/驱动 shader 磁盘缓存的首次构建**，存在用户 profile 里、跨浏览器进程复用。
应用侧无法消除；它能被消掉的部分（其余 shader 的编译）已从 60.8 s 降到 1.2–2.5 s。
因此**冷首次访问**仍然慢（页面→进世界 ~50 s），而**返回用户**是上表数字。

#### 病根：GLES3/FXC 的"寄存器压力悬崖"

`world_map`、`resource_impostor` 都表现为：一个 fragment 里只要有**两个及以上真正的着色
来源**按像素二选一，编译时间就从秒级跳到十几秒，而**与那第二个来源有多少行几乎无关**
（world_map 水面：25 行 17 264 ms、1000 行 20 291 ms、换成常量 2 473 ms）。所以"删代码"
治不好，只有**把它移出这个 fragment**才有效：

- 水面 → 独立第二 pass（`shaders/world_water_web.gdshader`，16 uniform，非水格 `discard`），
  由 `hex_renderer._sync_water_quad()` 创建，只在 web + Compatibility + LOW 档生效。
- `resource_impostor`（六路来源）→ 拆成 `PK_RES_WEB_PASS_SURFACE` / `_GEOLOGY` 两份程序。

#### 预热器的三条硬约束（踩过才知道）

1. **清单必须覆盖运行期会首次绘制的每一份源码**，前缀与运行期**逐字一致**。踩过三次：
   植被硬编码 `MAP_VISUAL_TILED`（web 不是 tiled）；`resource_ground_cover` 少一个档位宏；
   植被家族批次变体（FAR_ONLY + DETAIL_FAMILY_BATCH）根本没进过清单。
2. **前缀必须向 owner 取，不能自己拼**：`HexRenderer.WORLD_MAP_WEB_PREFIX`、
   `BuildingVisualLayer.compose_shader_code()`、`ResourceVisualLayer.web_warmup_shader_codes()`、
   `ShrubLayer.web_warmup_shader_codes()`。差一个字节驱动就不认缓存。
3. **编译期档位必须钉死**：web 上 `player_game._shader_quality_define_from_setting()`
   恒返回 LOW、`shrub_layer` 的 `web_define_prefix()` 也钉 LOW。玩家设置里选的中/高档
   只驱动运行期 `visual_quality` uniform，不再换 shader 源码（否则换档 = 换 program =
   一次几十秒重编）。植被那个 MISS 的根因就是这个：`_mobile_quality_tier` 初值 1(MID)、
   `ShrubLayer._ready()` 早编发生在推档之前，而 `MOBILE_QUALITY_LOW/MID` 都是 18 字符、
   长度恒等，只有 hash 不同 —— 只能靠指纹对账抓出来。

#### 指纹对账（新增诊断手段）

菜单期发 `warmup_plan`（每份源码的 `len:hash` + 前缀前 96 字符）与 `warmup_shader`（逐张耗时）；
运行期各图层用 `WebTelemetry.note_variant(label, code)` 回报自己真正创建的源码指纹。
两边对不上就是"预热白做"。当前 18 条只有 `building_shadow` MISS（它在 web 上不绘制，无成本）。

#### 10× 吞吐：自适应单帧预算

`world_clock.sim_budget_ms()`：桌面固定 `sim_frame_budget_ms`（8 ms）；web 上随倍速放大
（×1 → 8 ms、×5 → 20 ms、×10 → 40 ms，上限 60 ms）。原来固定 8 ms 在 25 fps 下每帧都撞
天花板，把有效速度压到 ~1.8 天/秒。`clock_rate` 事件（每 2 秒聚合 frames/days/blocked/
cap/cost/dps）是这条的验收工具。

#### 复现命令

```powershell
python tools\pk_web_measure.py --days 60 --speed 10 --tag pk --repeat 2      # 热 profile（返回用户）
python tools\pk_web_measure.py --cold-profile --tag cold                     # 冷 profile（首次访问）
python tools\pk_web_reload_probe.py --wait 60 --profile tmp\chrome_profile_pk  # 冷/热 profile 预热对比
python tools\pk_web_reload_probe.py --wait 45 --profile tmp\chrome_profile_pk  # 页面→主菜单口径
```

#### 9.20.1 Web 的 worker 路径：**已默认为 worker**（2026-10-31 定案）

> 结论更新：下面这段"worker 比 inline 慢"是**修闸之前**的数据。三处闸修完之后
> （见 §9.20.1.1），web 已经**默认走 worker**，与 PC 基准统一：
>
> | 路径 | 日历 | 吞吐 | 主线程单日成本 | 最长帧 |
> | --- | --- | ---: | ---: | ---: |
> | **默认（worker）** | **day 730**（连跑两年） | **9.94 天/秒** | **5 ms**（`inl`=0） | 2 388 ms |
> | `?worker=0`（inline 回退） | day 365 | 9.87 天/秒 | 46 ms（`inl`=32） | 2 833 ms |
>
> 两条都 `pass=true` / `fault=''` / `web_worker_inline_fallback=false`。
> 开关优先级（高到低）：`?worker=0|1`（Engine meta）> `PK_WEB_WORKER=0|1`（环境变量）
> > `runtime_web_worker` 导出项 > web 平台默认 `true`。worker 启动失败会自动回退 inline
> （`web_worker_start_code=inline_fallback`），所以默认开启不是单点风险。
> 桌面不受影响：桌面本来就跑 worker，`native_daily_inline` 在桌面只看
> `PK_NATIVE_DAILY_INLINE`。

（以下为修闸前的历史数据，保留以便对照）

web 现在有两条"日屏障执行者"：默认的 **inline**（12 域在主线程逐日跑）与 `?worker=1`
打开的 **worker**（`std::thread` 跑 native daily 图，主线程只做输入发布与提交消费）。
两条**都能跑满一年**、都不 FAULT，但：

| | 稳态天/秒 | fps | 单日**主线程**成本 | 最长帧 |
| --- | --- | --- | --- | --- |
| **inline（默认）** | **9.81** | 25.0 | 46 ms（`inl` 32） | 2.55 s |
| worker（`?worker=1`） | **7.43** | 30.5 | **4 ms** | 2.56 s |

##### 为什么"加速没释放"

用 `prefetch_diag` 的 `cd`（worker 已提交日）与 `clk`（日历日）两条曲线分别求速率，
结论非常干净：

```
worker K=2 : worker(cd) 357 天 / 132 s = 2.70 天/秒    clock(clk) 356/132 = 2.70 天/秒
             lead(cd-clk): min=1 max=3 median=2      ← 流水线从来没填满
worker K=6 : worker(cd) 356 天 / 133 s = 2.67 天/秒    clock(clk) = 2.66 天/秒
             lead: min=5 max=7 median=6              ← 加深 K 也没用
```

也就是说：**主线程侧已经不是瓶颈（4 ms/天），慢的是 worker 线程自己** —— 它生产一天的
墙钟约 250–370 ms，比主线程 inline 的 46 ms 慢 5–8 倍。日历完全跟着 worker 的节奏走
（`lead` 只有 1–3 或 5–7，从未逼近 `max_lead=10`），所以**加深预发布流水线（K 2→6）
只是把在途天数从 2 提到 6，吞吐 7.43 → 7.45，没有改善**。

已经排掉的两个假设（都做了实测，别再重复）：

| 假设 | 实验 | 结果 |
| --- | --- | --- |
| 预发布流水线太浅，藏不住跨线程往返 | `WEB_WORKER_PREFETCH_DAYS` 2 → 6 | 7.43 → **7.45**，无改善；`lead` 只到 5–7，从未逼近 `max_lead=10` |
| worker 线程里 `native_parallel_executor` 又去 spawn pthread（wasm 池固定 16 槽，从 worker 里嵌套起线程是病态的） | `world_ext_simulation_host.cpp` 加 `PK_WEB_PARALLEL` 旁路，wasm 上默认 `set_parallel_serial_only(true)` | 7.43 → **7.41**，无改善。该改动保留（消除一个已知负收益模式），但它不是瓶颈 |

剩下的唯一嫌疑是 **worker 线程执行 12 域日图本身在 wasm 上就慢**（同一份代码主线程 46 ms、
worker 线程 ~380 ms）。下一步：把 `worker_time_execute_us / worker_time_input_wait_us /
worker_time_boundary_wait_us` 按天导出进 `diag`（它们现在不在 `get_runtime_perf_snapshot`
的键里），先区分"worker 在算"还是"worker 在等"，再决定是优化图还是改交付方式。

因此 **web 默认仍是 inline**；worker 保留给 `?worker=1` 与后续优化。
`WEB_WORKER_PREFETCH_DAYS` 已回落 2，并在代码注释里写明"不要再往加深流水线这个方向调"。

##### 9.20.1.1 "worker 慢"的真正解剖（真机 + `worker_time_*` 分项）

把 C++ 侧一直在累计、但 diag 白名单没带的 8 个 `worker_time_<phase>_us` 接进 `diag`
之后，一天的成本可以按阶段拆开（RTX 4080 + Chrome，60×40，10×，365 天）：

| 阶段 | 修闸前 | 修闸后 |
| --- | ---: | ---: |
| `execute`（worker 真正算） | 60 ms/天 | **51.7 ms/天** |
| `input_wait`（等环境帧） | **88 ms/天** | 43.9 ms/天 |
| `boundary_wait` / `overhead` | ~0 | ~0 |
| 参考：inline 主线程单日 | 46 ms | 46 ms |

结论有两条，都和最初的猜测不同：

1. **worker 的计算并不慢**：51.7 ms 对 inline 的 46 ms，是同一量级。之前"慢 8 倍"是用
   `cd/clk` 端到端速率反推的，把等待也算进了计算。
2. **多出来的是"等输入"**，而且是**协议造成的**，不是算力造成的。

修掉的三处闸（每处都有真机前后对比）：

| 闸 | 问题 | 修法 | 效果 |
| --- | --- | --- | --- |
| 发布窗口锚在"已提交日"上 | `lead >= K` 就停发 ⇒ worker 永远只能领先 K 天，每天必绕主线程一个来回 | 窗口深度改成 `K + WORKER_PUBLISH_DEPTH_DAYS(40)` | 7.43 → 9.93 天/秒，`input_wait` 88 → 44 ms/天 |
| 日历被"worker 领先"拦住 | `_worker_budget_exhausted()` 同时拦领先与落后两个方向 ⇒ worker 领先 10 天就把日历钉死，与发布上限撞成死锁 | 只保留"落后"方向（领先时日历追上去才是消解领先的方式） | 解除 lead=10 的硬死锁 |
| wasm 上并行执行器 | `set_parallel_serial_only(true)` 只在 inline 分支调用，worker 分支会去 spawn 8–14 个 pthread（浏览器池固定 16 槽） | wasm 上一律串行（`PK_WEB_PARALLEL=1` 可旁路） | 7.43 → 7.41（**无差别**，说明它不是瓶颈；保留以消除已知负收益模式） |

修完之后的对照：

| | 稳态天/秒 | 主线程单日成本 | 最长帧 | 365 天 |
| --- | ---: | ---: | ---: | --- |
| inline（默认） | 9.81 | 46 ms | 2.55 s | PASS |
| **worker（`?worker=1`）** | **9.92** | **4 ms（−91%）** | 2.49 s | PASS |

**同样的吞吐，主线程便宜 11 倍** —— 这正是"把 GPU / UI 的帧时间拿回来"要的东西，也是
web 默认可以切到 worker 的依据（见 §9.20.1 结论）。

##### 为什么 PC 上 worker 比 inline 快、web 上只是打平

三个机制叠加，都不是"wasm 线程天生慢"：

1. **测量口径不同**：inline 的那 46 ms 是在**主线程独占**时测的（`_process` 里同步跑完，
   渲染被阻塞）；worker 的 51.7 ms 是**与渲染并发**时测的墙钟，含着 CPU/缓存竞争。
   PC 上渲染线程与 worker 各有富余核心，竞争可忽略；web 的 WebGL 渲染本身很重（30 fps），
   竞争显形。
2. **交付延迟的量级不同**：PC 上 60+ fps、条件变量直接唤醒，交付延迟亚毫秒；web 上每次
   交付要绕主线程一帧（30 fps ⇒ 33 ms 粒度），所以 worker 每天天然要多等一两帧。
3. **JIT 温升**：worker 线程"算 51 ms、等 44 ms"，累计执行量小，容易停在较低的优化层；
   主线程一直在跑，热点早被优化。这条在本机无法单独量化，但方向与实测一致。

##### 互锁是怎么修掉的（供后人参考）

之前 `lead >= K` 时预发布器暂停发布，而日历又被 worker 抬起的 `native_daily_day_barrier`
钉住 ⇒ **预发布器等日历、日历等 worker、worker 等输入**的三方闭环，日历停在 day 1。
修法：`WorldClock` 收敛出唯一的日推进判定 `_day_advance_blocked_by_barrier()`，只在
「屏障成立 **且** 预发布器正因领先额度暂停 **且** 不是年报屏障」这一种情形下**豁免**屏障
（`annual_report_*` 不豁免；`lead >= K+8` 的额度安全网仍然拦日）。关闭态逐表达式不变
（`K=0` 时豁免恒不触发，桌面实测 `rel=0`）。本地用新加的 `--pin_barrier=<source>`
（抬一个永不清除的日屏障）可稳定复现死锁：修复后 21 天推进 / 豁免 284 帧，对照 0 天。

#### 9.20.2 构建钩子的两个偶发失败（都已自愈，别慌）

`Build-Web.cmd` 现在串了三条 web-only 钩子（纹理降规格 → 字体子集化 → 导出），实测都遇到过一次
**偶发**失败，但都自愈了，遇到时不要以为改坏了：

| 现象 | 原因 | 现在的处理 |
| --- | --- | --- |
| `OSError: [WinError 1224] 请求的操作无法在使用用户映射区域打开的文件上执行`（还原 `.import` 时） | 另一个 Godot 进程（编辑器 / headless 测试）把某个 `.import`/`.res` 内存映射着 | `:tex_end` **3 次重试 + 3 秒间隔**；三次都失败才让构建红着退出（绝不静默发一个桌面变糊的包） |
| `godot --import failed (rc=3221225477)`，日志停在某字体（实测 `Muyao-Softbrush-2.ttf`） | Godot 编辑器进程在字体子集化的引导导入阶段**偶发 access violation** | 重跑一次即可；`subset_fonts.py` 的 `prepare` 自带备份与 `restore`，失败不会留下半注入状态 |

两条都**不能让构建"看起来成功"**：纹理状态不一致会让桌面/编辑器用 lossy 贴图，
字体注入不完整会让子集 `.fontdata` 留在 `.godot` 里。所以两者的失败路径都是让
`Build-Web.cmd` 以非零码退出，并打印可直接照抄的修复命令。

#### 仍未做（按性价比）

1. **282 MB 的 pck**：`.ctex` 154.6 MB + `.fontdata` 56.7 MB（5 套中文字体）。gzip 实测只
   压得动 0.45%（纹理已是 VRAM 压缩格式），所以只能靠字体子集化 / 砍字体套数 / 纹理降规格。
   这是真实网络下**唯一**会让①超 20 s 的因素。
2. **web 用回 worker**：`tmp/next/day_barrier_protocol.md` 有完整三段方案（输入预发布 +
   peer 在 worker 内闭环 + 屏障降级为限流）。现在单日 49 ms 已能撑住 10 天/秒，所以它
   不再是加载指标的前提，但能让 10× 更省 CPU。
3. `veg_shadow` 在 web 上不上屏却仍被编译；`building_shadow` 同理。是几毫秒级的浪费。

