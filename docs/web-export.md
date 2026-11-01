# Web 导出（Project.Keynes → 浏览器）

## 2026-10-31：Web 运行期画质恢复

Web 高档现在有独立的 PC 画质变体；低、中档保留较轻的预热程序。

| 档位 | 地形 atlas 最长边 / 材质 | 光照与植被 |
| --- | --- | --- |
| 自动 / 低 | 512 / 程序底色 | 既有 Blinn-Phong、远景简化植被 |
| 中 | 1024 / 512 材质数组 | 地形与紧凑水面 PBR、四类近景植被与法线着色 |
| 高 | 2048 / 1024 材质数组 | PC 陆地与完整水面管线、完整植被形态与软阴影 |

运行中从设置切到高档会继续使用 Web 共享程序，恢复地形高度细节、侵蚀沟谷、
坡面层次、材质采样和迷雾 q1/q2 分层；不会临时编译完整 PC 程序。页面启动时使用
`?quality=high` 才会选择完整 PC 变体。完整高档 `PK_WEB_PC_HIGH` 不定义 `MOBILE_QUALITY_*`，直接复用 PC 的地形细节法线、
沟谷/沙丘/岩层、河流法线与动态水纹、GGX/Smith/Schlick、线性光与 ACES。
水面复用 `water_pipeline.gdshaderinc`，保留完整波浪、Fresnel 天空反射、SSS 与岸线特效。
陆地使用 `PK_WEB_SPLIT_WATER`，水面使用 `PK_WEB_WATER_ONLY`：两片调用同一份 PC
管线，避免在一个 fragment 中联合编译水陆。高档植被也不走移动端宏，使用全部近景
形态、PC 的 3px LOD 阈值及解析软阴影。低档、中档、高档实际程序全部进入菜单预热。

两张高档地表程序各保持独立 sampler 预算（陆地 8、水面 6）。Web 高档会在地图生成时烘焙 horizon，
地形和普通近景植被读取真实投影遮蔽、天空可见度与 bent normal；为腾出这一槽位，
高档地形保留距离场连续过渡，省略次级邻格索引。家族植被批次释放 horizon 槽，
仍使用完整形态、地面法线和软阴影。GI 弹射仍受预算限制。
独立天气层仍使用 Web 简化云体（云量、晨昏色与云影保留）。这些差距不能靠高档标签消除。

atlas 与材质数组尺寸在生成时选择；要获得对应静态精度，需要以所选画质重新生成地图。
导出不再把 `material_1024_*.res` 替换成 256 占位，因为 Web 高档已实际使用这组资源。
低/中档共享程序，通过 uniform 切换 PBR 与四类近景；跨入/退出高档则选择预热过的 PC
变体并重新绑定材质输入，实例预算变化仍可能触发分帧重建。第一次预热开销相应增加。

验证入口：`tests/rendering/web_quality_render_test.gd` 用 Compatibility 真 GPU
检查实际低/中/高像素和四类植被；`terrain_shader_variant_test.gd` 检查变体，
`web_water_pass_node_test.gd` 检查水面节点。Web 自动测试新增
`?autotest=1&quality=high`（也接受 `low/medium`），通过正式 GameSettings 更新且不保存；
原 `tier=` 是编译档诊断探针，不代表玩家画质。

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
| 音频 | Web 使用 Godot/Vorbis 完整混音：菜单、四时代组曲、三首升级过渡、UI 与游戏事件音效；Windows 继续使用 FMOD | `scripts/audio/native_audio_backend.gd` |
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

### 6.5 已修：左侧地图图层工具条压住顶栏日历（2026-11-01）

现象（Web 截图）：左上角 4 个图层按钮（地理/气候/资源/生物）竖排纸条第 1 个
盖住顶栏的日历图标，"第1年" 左半边被切掉。桌面端同尺寸（1556x761）复现不出来。

定位：`HUDLayer/MapOverlayToolbar` 是 HUD 里最后一个**只靠 `.tscn` 静态
anchor+offset 摆位、运行期从不重新结算**的节点。`PlayerTopBar` / `RightPanel`
早前是同一类症状（`[web-layout-guard]`，见 `game_ui_manager.gd` 里的注释），
已经改成运行期兜底；工具条漏在外面，于是 Web 上它的 rect 退化成默认的 `(0,0)`，
`PrimaryPanel` 被摆到屏幕左上角（80x272），正好盖住顶栏左侧 `DateBlock`
（16,22,294x48）里的日历图标与日期文字。

修复：`GameUIManager._layout_map_overlay_toolbar()` 走与顶栏/详情面板完全相同的
运行期路径 —— `set_anchors_preset(PRESET_FULL_RECT)` + 写回
左 16 / 顶（顶栏实时高度 + 12）/ 右 -16 / 底 -16。绑定工具条时执行一次，
之后每次 `_layout_top_bar()`（含视口 `size_changed`）都会级联重算，数值与
`map_overlay_toolbar.tscn` 声明一致，桌面端幂等。

回归测试：`tests/ui/hud_topleft_layout_test.gd`（headless）。六个视口尺寸下断言
纸面板与日期纸框/日历图标零相交、四条内边距与 `.tscn` 一致，并显式模拟
"声明式布局丢失 → rect 退化到 (0,0)" 的 Web 症状，验证运行期兜底能恢复。

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
  **注（2026-11-01）**：web 上是否真的绘制由 `WeatherLayer.set_render_gate()` 的画质门决定
  —— 只有高画质才画，低/中/auto 关门（见 9.21 的修正段）；
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

**修复（2026-10-31）**：`hex_renderer.gd` 新增 `PK_WEB_ENABLE_WEATHER_LAYER`——web 上天气层
**仍然创建、所有 set_* 调用照常**，只是不绘制。天气**模拟**完全不受影响，只是少一层云。
验证：连续多次 `?autotest=1&days=365&speed=10` 跑到 day 365、`autotest_start` 只出现 1 次
（**没有 reload**）、beat 间隔稳定 2 秒。

**修正（2026-11-01）：当时的 `visible = false` 并不生效，现已改成画质门。**
`WeatherLayer._refresh_visibility()` 会在 `setup()`（`_apply_uniforms()` 每次都会调，而初始
cell-LUT bake 在渲染器绑定前就已发布 weather LUT）和 fronts 更新时把 `visible` 重新置 true
—— 也就是说上面那次"不绘制"实际只覆盖 `_ready` 到首次 `set_map` 之间的一小段。

现落地：`WeatherLayer.set_render_gate()` 把画质门与 fronts/LUT 条件取与
（`_refresh_visibility()` 里唯一的 AND 项）；`hex_renderer._apply_weather_layer_render_gate()`
在 web 上只有**高画质**（`visual_quality >= 2`，或 QA 的 `?tier=high`）才开门，
低 / 中 / auto 关门。关门时天气层连 `_process` 都直接返回（不付逐帧 uniform/粒子/雨幕同步的
CPU）。桌面 / 移动门恒开，行为不变；天气层对象仍创建、模拟与 LUT 刷新照常。
切画质（`set_visual_quality`）与切档（`set_mobile_quality_tier`）都会即时重算，
首个状态变化打一行 `[hex_renderer] web: WeatherLayer drawn=...`。

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
> > `runtime_web_worker` 导出项 > web 平台默认 `true`。worker 启动失败会自动回退 inline；
> 如果 side module 缺少 `environment_ring_has_capacity()` 或
> `runtime_committed_day()`，启动边界也会强制回退 inline，避免旧 Web 包把 worker
> 停在 `PAUSED` 等不到环境帧并卡住第 1 天。重新执行 `Build-Web.cmd`（不要使用
> `skip-native`）可恢复 worker 路径。
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

### 9.22 「海量报错」定案：2 GiB wasm 堆耗尽 + 每次输入重入（2026-10-31）

**症状**（玩家控制台原文）

```
ProjectKeynes.js:467 Cannot enlarge memory, requested 2147487744 bytes, but the limit is 2147483648 bytes!
ProjectKeynes.js:467 ERROR: Parameter "mem" is null.
ProjectKeynes.js:467    at: alloc_static (core/os/memory.cpp:114)
099dddfe:0x20970be Uncaught RuntimeError: table index is out of bounds
    at move_cb (ProjectKeynes.js:1:713785)      ← 每次鼠标移动/滚轮/点击各来一对
```

同一份控制台里还有 `chrome-extension://…/scripts/content.js` 的
`Permissions policy violation: unload …`、`Unchecked runtime.lastError`、
`Cannot read properties of undefined (reading 'rotate')`。**那些是浏览器扩展自己的
报错，与本项目无关**：干净 profile（`--user-data-dir` 指向空目录）下它们一条都不会
出现；排查 Web 问题时先关掉扩展，否则会把扩展噪音当成引擎问题。

**根因链（按发生顺序）**

1. Godot Web 跑在**单个 wasm32 线性内存**里，官方 4.6 模板写死
   `MAXIMUM_MEMORY = 2 GiB`；Emscripten 日志里的 `limit is 2147483648` 就是这个值。
   `requested 2147487744 = 2 GiB + 4 KiB` 说明堆顶已经顶到墙上（只差一页），
   **不是某一次超大分配，而是堆被填满了**。
2. 堆满后 `Memory::alloc_static` 返回 null，引擎没有就此停住，继续跑 `move_cb`
   （Emscripten 挂在 canvas 上的输入回调）。每次输入都重新进 wasm → 重新 malloc
   失败 → 再打印一轮 `Cannot enlarge memory` + `mem is null`。
3. 内存耗尽后函数表索引损坏，于是同一批回调抛
   `RuntimeError: table index is out of bounds`。这就是"控制台看起来在无限刷报错"：
   **一条错误 × 每一次鼠标事件**，而不是引擎在循环打印。
4. 现场事件流（`tmp/web_events.jsonl`）里这次会话是 10× 从 day 0 连续跑到
   **day 1460（第 4 年）** 才暂停/崩，说明是**长跑累积**，不是启动即崩。

**结论**：这是 Web 平台 2 GiB 上限 + 长跑内存增长共同导致的硬上限，不是资源损坏、
不是 WebGL 上下文丢失，也不是扩展把游戏搞崩（扩展只是噪音）。

**已落地：页面侧 watchdog（`tools/web/pk_web_watchdog.js`）**

`Build-Web.cmd` 在每次导出成功后调用 `tools/patch_web_shell.py`，把
`pk_web_watchdog.js` 拷到导出目录并往 `ProjectKeynes.html` 里注入一行
`<script src="pk_web_watchdog.js"></script>`（幂等，带 `<!-- pk-web-watchdog -->` 标记）。
它只做页面侧的事，不依赖引擎内部：

| 行为 | 说明 |
| --- | --- |
| `pk_heap` 事件 | 每 10 s 把 `engine.rtenv.HEAPU8.length`（MB）POST 到 `/_log`，长跑得到 **堆大小 vs 天数** 曲线 |
| `pk_heap_start` / `pk_heap_high` / `pk_heap_critical` | 启动值、1900 MB 警告、2000 MB 临界 |
| 1900 MB 顶部提示条 | 不挡画布，提示保存后刷新 |
| `pk_heap_fatal` + 全屏遮罩 | 首次检测到 `Cannot enlarge memory` / `mem is null` / `table index is out of bounds` 时：显示一块可读的中文提示（含刷新按钮）、`engine.requestQuit()`、**替换 canvas 节点**（Emscripten 的输入监听器随节点一起消失）、并抑制后续重复错误（只放行前 6 条） |

这样即使再次撞墙，控制台也只会看到**一条**真正的错误 + 一个明确提示，而不是几千条
输入回调刷屏；同时事件流里留下完整的堆增长曲线，下一轮就能定位是哪个子系统在涨。
页面侧脚本的逻辑有独立单测（不需要浏览器/引擎）：`node tools/web/test_pk_web_watchdog.js`。

**已落地：GDScript 侧内存遥测**

- `scripts/game/web_telemetry.gd` 新增 `wasm_heap_mb()`：通过 `JavaScriptBridge`
  读 `engine.rtenv.HEAPU8.length`；`memory_mb()`（Godot 静态内存）保留作对账。
- `world_runtime_host._web_barrier_diag()` 把 `wasm_heap_mb` / `memory_static_mb`
  写进 `diag` 事件（每 ~10 s 一条）。
- 浏览器侧钩子（`webglcontextlost` / `pagehide` / `js_error`）放在页面侧
  `pk_web_watchdog.js` 里。`WebTelemetry.install_page_hooks()` 仍保留但**不要**
  从 GDScript 调用：早先试过 `JavaScriptBridge.eval` 注入，实测页面只跑一帧就静默
  （见 `world_runtime_host.gd` 里那条“已撤”注释）。页面侧脚本是普通 `<script>`，
  不经过 eval，行为可控。

> 注意：GDScript 部分在 pck 里，必须重新导出才生效；`pk_web_watchdog.js` 是
> Build-Web 每次导出自动注入的，不需要改导出预设。

**判读方法**

崩了一次之后，按下面三步读：

```powershell
# 1) 堆曲线（MB）。斜率 ≈ 每游戏日涨多少 MB
Select-String tmp\web_events.jsonl -Pattern '"e": "pk_heap"' | Select-Object -Last 20
# 2) 崩溃时刻（有 pk_heap_fatal 就说明走的是 watchdog 路径）
Select-String tmp\web_events.jsonl -Pattern 'pk_heap_(fatal|high|critical)'
# 3) 域级状态 + 堆大小（diag 事件，键名 wasm_heap_mb）
Select-String tmp\web_events.jsonl -Pattern '"e": "diag"' | Select-Object -Last 2
```

如果 `wasm_heap_mb` 随天数线性上涨（而不是阶跃），下一步就用
`?autotest=1&days=…&speed=…` 配合关层/关 UI 的 A/B 找增长源（同 §9.20 的做法），
不要再去调 `threads/*_pool_size`——那和 2 GiB 上限无关。

### 9.23 2 GiB 的真正大头：年度自动存档的「边界空转」每年抬 ~600 MB（2026-10-31）

§9.22 的曲线只是症状。用**桌面 headless 复现同一条生产路径**就能把增长拆开：

复现命令（headless 也能跑 autotest；`PK_SAVE_SYNC_WRITE=1` 强制走 web 的同步写存档路径）：

```bat
set PK_AUTOTEST_QUERY=autotest=1&days=800&speed=10&seed=20260101&size=60x40
set PK_SAVE_SYNC_WRITE=1
"%GODOT%" --headless --path Project\project-keynes --log-file tmp\soak.log
```

每 30 个游戏日从 `[autotest] autotest_progress` 读 `mem_static_mb` / `nodes` / `objects`
（这三个字段就是为这次排查加进进度事件的）。实测（60×40，10×，干净 user://）：

| 天数 | mem_static | nodes | 事件 |
| ---: | ---: | ---: | --- |
| 360 | 686 MB | 2203 | 年报打开前 |
| 390 | **1308 MB** | 2526 | 年报跨年后：**+622 MB** |
| 690 | 1378 MB | 2526 | 一年后仍不归还 |
| 750 | **1953 MB** | 2521 | 第 2 个跨年后：**再 +569 MB** |

对照实验（决定性）：

| 配置 | 跨年那一跳 |
| --- | ---: |
| 自动存档开（默认） | **+570 ~ +620 MB** |
| `autosave_enabled=false` | **+50 MB**（只是年报 UI 的常驻节点） |
| 自动存档开 + `PK_SAVE_SYNC_WRITE=1`（web 路径） | **+622 MB**（同样复现） |

所以大头不是 wasm 上限、不是年报 UI，而是**年度自动存档失败前的边界等待**：
`GameSaveCoordinator._wait_for_safe_boundary()` 在时钟已 `pause(true)` 的状态下最多等
1800 帧，每帧调 `advance_save_boundary()`，而后者会把 trigger/ideology/effect/
modifier/gameplay_effect 整条日系统链 + economy inflight 重跑一遍。跨年时阻塞码是
`save_requires_idle_effect_country`——年度奖励的 Effect 要等**下一个游戏日**才 ACK，
暂停期间永远等不到；于是 1800 帧 × 重跑日系统 = **Godot 静态内存 +600 MB 且不归还**。
每个游戏年重复一次，web 的 2 GiB 堆在第 2–4 年必爆；同时这 1800 帧还是 30 秒主线程
卡死（web 上就是"页面无响应"）。

**修复**（`game_save_coordinator.gd` `_wait_for_safe_boundary`，纯 GDScript，随 pck 生效）：

1. **同一个 blocking code 连续出现就认输**：web 90 帧 / 桌面 240 帧；
2. 墙钟上限：web 3 s / 桌面 8 s；
3. 空转期间 `advance_save_boundary()` 改成**隔帧**调用，内存/CPU 增速再减半；
4. 失败仍然走原来的 `_last_autosave_year = year - 1`（下一个年份再试），功能语义不变。

**修复后实测**（同一 soak 流程，`PK_SAVE_SYNC_WRITE=1`）：

| 检查点 | 修复前 | 修复后 |
| --- | ---: | ---: |
| 380 天进程 WS | 2068 MB | **1357 MB** |
| 第 1 个跨年跳（360→420 天） | +622 MB | **~+90 MB** |
| 第 2 个跨年跳（720→750 天） | +569 MB | **+83 MB** |
| 800 天 `mem_static` | 1961 MB | **977 MB** |

```text
day 360 mem_static=684 MB
WARNING: [save] boundary timeout blocking=save_requires_idle_effect_country stalled_frames=240
day 390 mem_static=...            （修复后第 1 跳只有年报 UI 的 ~50 MB + 少量空转残留）
day 800 autotest_pass  mem_static=977 MB
```

即跨年残留从 ~600 MB 降到几十 MB 量级（web 上等待上限更短，残留更小），等待也从
30 s 降到 ~4 s（web 上 ~3 s）。如果以后想彻底消掉这一次年度存档失败，应当让年度
奖励 Effect 在暂停前先 ACK（native/日图时序问题），而不是继续加长等待——**不要再
把 `MAX_WAIT_FRAMES` 调回 1800，那等于每年主动吃掉 600 MB**。

> 剩余 ~0.2 MB/天 的稳态增长（mem_static 629→686 MB / 120→360 天，objects/
> resources 基本不变）还没定位，属于既有数据结构的缓慢膨胀；有了 `wasm_heap_mb`
> 遥测和上面的复现命令，下一步可以按关层 A/B 继续缩小范围。

### 9.24 地形 Shader：烘焙法线/起伏/地平线取代运行期高度差分（2026-11-01）

> **历史快照（A 方案完成时）**：本节表格里的 2 层 surface array、桌面 Compatibility 7 槽、
> HIGH 水面 6 槽、桌面 legacy 16 槽等数字是 A 方案状态。B 方案（**§9.25**）在此基础上把
> surface array 扩为 **4 层**、material array 扩为 **5 层**、HIGH water **6→7**、compact water
> **4→5**、桌面 Compatibility 纯预算 **7→8**、桌面 legacy **16→15**。**当前契约以 §9.25 为准。**

**结论先行：桌面端与 Web 端都不再有"运行期高度差分法线"。** 地形法线全部来自生成期
烘焙纹理（tiled 桌面走两个 `Texture2DArray`；Web 与桌面 legacy 走整图单 tile，其中
normal+relief 合并成**一个 2 层 `sampler2DArray`**，另有一张 2D `terrain_normal_tex` 供
只读法线的其它层使用），运行期只做解码、按 `camera_zoom` 淡入和裁剪。这条不变量由
§9.24 末尾的 grep + 测试守住。

> **v2（方案 A，2026-11-01）**：normal+relief 合并成 2 层 `terrain_surface_tex` 后，
> Web 陆地程序从"normal+relief 各占一槽、noise 无槽可放"的 9 槽形态压缩回 **8 槽**，
> 腾出的槽**恢复 `noise_tex`**（`pixel_noise` / `fbm` / 雪 / 植被 / 全局调整都在消费它）。
> v1 曾短暂用程序化噪声填补该槽，v2 已整体删除，`common_noise.gdshaderinc` 恢复单一的
> `noise_tex` 快路径。

#### 为什么改

旧的 Web-LOW/legacy 路径在 `hillshade_tod.gdshaderinc` 里用 `height_tex` 邻域中心差分
现算 `compute_terrain_normal`，再叠一大套分地形细节法线（沟谷/台坎/沙丘/圆丘）与
`terrain_apply_landform_detail`。Web 端为了压采样数，长期只给粗法线和 `noise_tex`，
细节法线在 `MOBILE_QUALITY_*` 下被整个编译掉——所以 Web 的地形永远读不出起伏。上一轮
用 `PK_WEB_TERRAIN_DETAIL` 局部恢复它的代价是运行期重新引入高度差分采样，与本轮诉求
（法线一律烘焙、离线成本换运行期成本）冲突，删除该宏。

#### Web 地形程序的 8 槽预算（GLES3/WebGL2 材质 sampler unit 1..8）

| # | sampler | 来源 | 备注 |
| --- | --- | --- | --- |
| 1 | `height_tex` | `VT_USE_HEIGHT` | RG=16-bit 高程，B=flow |
| 2 | `map_index_atlas` | `VT_USE_MAP_INDEX` | biome / cell id / landform |
| 3 | `enum_lut` | `uniforms` 无条件 | per-cell biome/veg/cover/迷雾知识度 |
| 4 | `dyn_lut` | `uniforms` 无条件 | per-cell 温度/湿度/雪/海冰 |
| 5 | `terrain_material_tex` (array) | `uniforms` 无条件 | 材质族 |
| 6 | `terrain_surface_tex`（`sampler2DArray`，**6 层 RGBA8**） | `VT_USE_TERRAIN_SURFACE_ARRAY`（+ `NORMAL`/`RELIEF`/`DETAIL`） | **layer0 = 粗法线（0.5+n·0.5）+ BA 近景高度细节坡度；layer1 = relief 粗段/细段坡度**（均 `encode_slope`）；layer2 = detail；layer3 = occluder ids；**layer4 = edge_distance（R 距离/G crease/BA 海岸占比）；layer5 = edge_neighbor（RG 次生 id；B 水深）** |
| 7 | `terrain_horizon_tex` | `VT_USE_HORIZON` | 8 方向 4-bit nibble 地平线 |
| 8 | `noise_tex`（恢复） | `uniforms` 无条件 | 预烘 4 通道 noise pack；`fbm()` 回到 1 次采样 |

**为什么是 `noise_tex` 而不是 `water_depth_tex`**：Web 把水陆拆成两个程序（陆地 pass +
`world_water_web.gdshader` 第二 pass），`water_depth_tex` 只被水面 pass 消费，放进陆地
程序只会是死槽；`noise_tex` 则是陆地程序自己消费的（`pixel_noise` / `fbm` / 雪 / 植被 /
全局调整）。恢复它让 `fbm()` 从"每像素多 octave hash 程序化"回到 1 次纹理采样，Web 的
ALU 压力更小，且与桌面同一套谱形。**零画质损失**：array 的 layer0/layer1 就是原来的两张图，
通道布局与语义完全不变。当时放弃的两个旧槽是 `terrain_edge_neighbor_tex` 与
`terrain_edge_distance_tex`（Web 次生生态过渡退化为硬主 cell 边界、海岸 halo 用邻域代理）；
**2026-11-02 起它们以同一个 array 的 layer4/layer5 形式回来**（见 §9.26），槽数不变。

**第三种预算：桌面 Compatibility 的 MID/HIGH。** 它同样只带 `PK_WEB_TEXTURE_BUDGET`、
不带 `PK_WEB_HORIZON`（纯诊断/回退渲染路径，不是 Web 产品路径）：**7 槽** =
height / map_index / terrain_surface_tex / noise / enum / dyn / material；`VT_USE_HORIZON`
不开，horizon 由 `terrain_horizon.gdshaderinc` 的中性叶子兜底——**没有地平线遮蔽，但
法线/relief 仍是烘焙纹理**。

**sampler 统计（v4，实测于 `terrain_shader_variant_test`）**：Web 陆地 **8**、
桌面 Compatibility 纯预算（非 tiled）**8**、桌面 Compatibility tiled 预算 **8**（不打开
water_depth/detail，诊断路径）、Web HIGH 水面 **8**、Web compact 水面 **6**、
桌面 tiled **17**、桌面 Vulkan legacy **13**（v4 非 tiled 的 normal/relief/detail/occluder/
edge 全部收进一个 array，2D `terrain_edge_*_tex` 不再进地形程序；
tiled 的 normal/relief 仍是两个数组：relief 是 `relief_scale` 倍分辨率，不能与 normal 同
array）。Web HIGH 的水面程序（`WATER_WEB_HIGH_PREFIX` + `PK_WEB_WATER_ONLY`）是**独立
程序、独立预算**：8 槽 = height / map_index / noise / water_depth + enum / dyn / material
+ **surface array**（v4 新增的那 1 槽，用来恢复 edge_mix / shore_frac / 次生水格）；
`hex_renderer._apply_water_uniforms()` 会为这个 pass **显式补绑** surface array /
`noise_tex` / `water_depth_tex` 与层数门控（独立程序不经过陆地程序的 uniform 推送）。

#### 烘焙来源：复用现有 native pass，整图单 tile

没有新增 C++ pass——`MapBaker._bake_legacy_static_surface()` 直接复用已有的
`run_bake_visual_tile_layer_pass`，以"整图一个 tile"参数调用：

- `origin/size = world_bounds`、`relief_supersample = 1`；
- 长边封顶：`LEGACY_STATIC_SURFACE_MAX_DIM_WEB = 1024`，与桌面 legacy
  `LEGACY_STATIC_SURFACE_MAX_DIM = 1024` 一致，实际尺寸再被 `world.hm_size` 最大边钳住
  （Web LOW 的 hm=512 → 512；Web MID/HIGH hm≥1024 → 1024），按 world_bounds 宽高比取偶数 w/h；
- 返回 `terrain_normal` / `terrain_relief` 两个 RGBA8 payload：normal 同时上传为
  `WorldData.terrain_normal_tex`（2D，供植被/建筑/资源/贸易/ground cover 等只读法线的层）
  和 `WorldData.terrain_surface_tex` 的 **layer0**；relief 上传为 **layer1**。
  `terrain_surface_tex` 是 2 层同尺寸 `Texture2DArray`
  （`Texture2DArray.create_from_images([normal_img, relief_img])`，校验返回 OK；
  失败则 `push_error` + 置 null）。
- **内存取舍（如实记录）**：normal 数据在 2D 与 array layer0 各存一份——这是为了让其它
  图层继续用 2D sampler 的显式选择。Web LOW（512×~300）约 **+0.6 MB**，桌面 legacy
  （1024×762）约 **+3 MB**；烘焙本身的耗时与 payload 字节数不变。
- 失败（`fallback=true` 或尺寸不符）→ `push_warning`，退回旧的 RG8
  `encode_bake_terrain_normal_tex_data` 单张粗法线：把 RG8 扩成 RGBA8（BA=128=0 坡度）
  作为 2D normal 与 layer0，layer1 填中性 128，array 照建 → shader 走完整路径但细节为 0，
  等价于原来的"仅粗法线"兜底。**旧 RG8 只是兜底，不是主路径。**

桌面 tiled 路径不变：`visual_terrain_normal_tiles` / `visual_terrain_relief_tiles`
（`relief_scale` 倍分辨率）继续由 `run_bake_visual_tile_layer_pass` 逐 tile 烘焙。
tiled 成功时 `terrain_normal_tex` / `terrain_surface_tex` 都置 null（避免白占显存）。

#### Web horizon：全档位 CPU 烘焙

旧行为只有 Web **HIGH** 才付 horizon 的一次性 CPU 烘焙成本，LOW/MID 完全无地平线。
现在 Web 所有档位都 CPU 烘 horizon（`TERRAIN_HORIZON_STEPS_WEB = 128`，其余参数不变；
`max_distance` 会自然截断有效步数），并用 `PK_WEB_HORIZON` 让 `terrain_horizon_evaluate`
在 `MOBILE_QUALITY_LOW/MID` 下也真正解码，而不是被编译成中性值。桌面 tiled 仍走
`VisualTileHorizonBaker` 的 GPU 金字塔路径；只有桌面 GPU 烘焙关闭时才落 CPU fallback。

#### 画质影响

| 档位 | 法线/起伏来源 | 结果 |
| --- | --- | --- |
| 桌面 tiled | tile 数组（normal + relief 2×，17 槽） | 与上一轮一致，不回归 |
| 桌面 legacy | 整图单 tile：2D normal + 2 层 surface array（cap 1024） | **不再**运行期高度差分 |
| 桌面 Compatibility MID/HIGH | 7 槽预算程序（surface array + noise，无 horizon） | 法线/relief 烘焙，无 horizon 遮蔽（诊断路径） |
| Web LOW/MID/HIGH 陆地 | 整图单 tile：2D normal + 2 层 surface array（长边 ≤1024，Web LOW 实际 512）+ CPU horizon（8 槽） | 起伏/细节坡度/地平线遮蔽 + 恢复预烘噪声 |
| Web HIGH 水面 | 独立水面程序，8 槽（含 `noise_tex` / `water_depth_tex` / surface array） | PC 水面管线不变；v4 起恢复 edge_mix / shore_frac / 次生水格 |

`hillshade_tod.gdshaderinc` 的唯一法线入口是 `terrain_baked_normal()`：粗法线取
`terrain_surface_tex` layer0 的 RG，近景高度细节取 layer0 的 BA
（`smoothstep(1.35,2.10,camera_zoom)` 门控），分地形粗/细段取 layer1 的 RGBA
（`smoothstep(3,7,48·scale·zoom)` / `(3,7,14·scale·zoom)`）；tiled 走同名 helper
（内部寻址到 `visual_terrain_normal_tiles` / `visual_terrain_relief_tiles` 的 layer 0/1）。
`PK_WEB_HORIZON` 让 Web LOW 也编译这条细节路径（代价只是已绑定的 1–2 次采样）。
原来的 `#if defined(PK_MOBILE_ANY) || defined(PK_QUALITY_LOW) return 仅粗法线` 早退已删除。

#### 生成期成本

数字来自 `map_baker.gd` 常量注释里的 native 探针（RTX、native 多线程，非 wasm）。wasm
nothreads 未单独实测，按经验预计 3–5×，相对地图生成总预算仍可接受；真机耗时以
`[terrain-baked-surface] ... elapsed_ms` 日志为准。

| 项 | 像素尺寸 | native 探针 |
| --- | --- | ---: |
| 单 tile normal+relief（`relief_supersample=1`） | 512×298 | 68 ms |
|  | 1024×596 | 265 ms |
|  | 1024×762（真实 legacy 小图） | 端到端实测 native 372.6 ms / wall 388 ms（另一次 v2 实测 383.3/388）；其他探针 506–571 ms（均含 halo/terrain-index） |
| Web horizon（`TERRAIN_HORIZON_STEPS_WEB=128`） | 512×298 | 15 ms |
|  | 1024×596 | 79 ms |
|  | 2048×1192 | 489 ms |

horizon 的 `max_distance = 24 hex` 会自然截断有效 marching 步数，所以实际步数常远小于
128。v2 的 array 上传只是多一次 `Texture2DArray.create_from_images()`（可忽略），
烘焙 payload 字节数与上表耗时不变。两者都只发生在地图生成期，运行期零额外采样
（除已绑定的 surface array 2 层 + horizon 各 1–2 次）。

#### 不变量与验证入口

源码 grep（`Project/project-keynes/{shaders,scripts,tests,docs}` 应 0 命中）：

```
PK_WEB_TERRAIN_DETAIL
terrain_add_height_detail
terrain_coarse_normal
terrain_apply_landform_detail
compute_terrain_normal
```

v2 另加：v1 为省 sampler 而引入的"Web 程序化噪声"宏已整体删除；旧的 2D relief
字段/sampler 也已删除（只保留 relief 对应的 bound bool，按契约 §1.6 由 HexRenderer 推送）。

测试入口：

- `tests/world/terrain_shader_variant_test.gd`：变体编译、Web 8 槽名单（surface array +
  `noise_tex` + horizon、无 2D normal/relief）、桌面 Compatibility 纯预算 7 槽、
  HIGH 水面 6 槽、桌面 tiled 17 槽、前缀链逐字节一致；
- `tests/world/web_static_surface_bake_test.gd`：整图单 tile normal/relief 尺寸/hash/
  非平坦性 + 2 层 array 可创建；
- `tests/world/terrain_gi_test.gd`：GI/horizon 解码与变体 uniform（非 tiled 断言
  `terrain_surface_tex` + bound flags）；
- `tests/rendering/web_quality_render_test.gd`（Compatibility 真 GPU）：合成 2 层
  `Texture2DArray`（layer0 normal、layer1 relief），断言 land 程序恰 8 槽名单、
  改 layer0/layer1 内容都会改变最终像素（证明两层都被采样）、HIGH water 仍 6 槽；
- **端到端 legacy 单 tile 生成**（桌面，强制 legacy 视觉模式）：

  ```powershell
  $env:PK_LOADING_SIZE='8x6'
  & $godot --headless --path Project\project-keynes ^
      --script res://tests/world/cooperative_world_generation_test.gd -- --map-visual-mode=legacy
  ```

  日志应出现 `visual tiles: legacy ()` 与
  `[terrain-baked-surface] desktop-legacy single-tile 1024x762 relief_supersample=1 ... surface_array=ok layers=4 detail_layer=1 occluder_layer=0`；
  B 冻结后实测 native 359.1 ms / wall 361 ms（`layers_ms=22`，normal/relief payload 各
  3121152 B；另一探针 506.9/508）。A 方案 2 层时期为 372.6/388。B 方案起 surface array 为
  4 层、material array 为 5 层（见 §9.25）。

### 9.25 Web 中/高画质地表特性包（B）：detail/micro/occluder 入 array + 水面 depth（2026-11-01）

**结论：Web 陆地程序仍然恰 8 个材质 sampler。** 用户要求 Web HIGH（并尽量迁到 medium）
支持 `terrain_detail_tex`、`terrain_micro_tex`、`gi_occluder_tex`、`water_depth_tex`；实现
沿用方案 A 的手段——**把数据塞进已绑定的 array/已有 sampler，而不是要新槽**；低画质
（`visual_quality=0`）的像素行为与 B 之前完全一致，性能由运行时门控保证。

#### 4 个资源的新位置

| 旧资源 | B 方案位置 | 新增 sampler | 生效档位 |
| --- | --- | --- | --- |
| `terrain_detail_tex`（R8 derived，烘焙 biome 细节） | 非 tiled `terrain_surface_tex` **layer2**（R=detail，world UV） | 无 | MID/HIGH（vq>=1；LOW 恒等 1.0 不变） |
| `terrain_micro_tex`（RGBA8 256² 平铺微表面） | 共享 `terrain_material_tex` **layer4**（第 5 层，平铺 UV） | 无 | **MID/HIGH 默认生效**（C 轮 A/B 安全后，共享程序默认用带 micro 的 `WORLD_MAP_WEB_PREFIX_MICRO`；HIGH 独立程序必然有；`?micro=off` 可一键关闭） |
| `water_depth_tex`（**RGBA8**，C 轮升级） | 两个**水面程序**的独立槽：HIGH water 6→7、compact water 4→5；桌面 Compatibility 主 pass 7→8 | +1（仅水面程序） | Web 全档位水面：**R=归一深度**（湖泊用烘焙值、海面用连续 elev），**G/B/A=湖/礁/海带 3×3 软权重**（compact 水面消费） |
| `gi_occluder_tex`（RGBA8，两个 16-bit cell id） | 非 tiled `terrain_surface_tex` **layer3**，shader 用 `texelFetch` 读取 | 无；**不再需要 `bounce_lut`** | **Web MID/HIGH（vq>=1；MID 强度 0.6，LOW 关）**（C 轮从 HIGH 扩到 MID） |

非 tiled `terrain_surface_tex` 固定 **6 层**（layer0 normal、1 relief、2 detail、3 occluder、
4 edge_distance、5 edge_neighbor），`terrain_surface_layer_count` 运行期告诉 shader 实际层数；
`terrain_detail_layer_bound` / `terrain_occluder_layer_bound` / `terrain_edge_layers_bound` 是
运行时门控 bool（旧图/兜底时 detail 返回恒等、occluder 返回 0xFFFF 哨兵、edge 距离返回 1.0
且次生 id 返回 0xFFFF ⇒ 次生混合整条关闭）。tiled 桌面不走这套：detail/water/edge 仍用原
tile 数组。

#### 预算（v4）

| 程序 | 槽数 | 组成 |
| --- | ---: | --- |
| **Web 陆地（LOW / MID / HIGH land）** | **8** | height / map_index / enum / dyn / material(5 层) / terrain_surface_tex(**6 层**) / terrain_horizon / **noise_tex** |
| Web HIGH 水面（`PK_WEB_WATER_ONLY`） | **8** | 上述 6 槽 + **water_depth_tex**（含 noise_tex）+ **surface array**（v4：edge_mix/shore_frac） |
| Web compact 水面（`world_water_web.gdshader`） | **6** | height / map_index / enum / dyn / **water_depth_tex** / **surface array**（v4） |
| 桌面 Compatibility 完整主 pass（非 tiled） | **8** | 预算内完整 path + **water_depth_tex**（没有第二 pass） |
| 桌面 Compatibility tiled 预算变体 | **8** | 方案 A 的 8 槽（不打开 water_depth/detail，诊断路径） |
| 桌面 tiled（Vulkan） | 17 | 不变（detail/water/edge 仍走原数组） |
| 桌面 Vulkan legacy | 13 | v4 非 tiled 的 detail/occluder/edge 全部收进 surface array |

实测汇总（v4 `terrain_shader_variant_test`，含共享 micro 变体）：
`desktop(legacy)=13 | desktop(tiled)=17 | web_low=8 web_mid=8 web_high_land=8 web_micro_shared=8 web_high_water=8 compact_water=6 | plain_budget=8 tiled_budget=8`。

Web 陆地**不得**再声明 2D `terrain_detail_tex` / `terrain_micro_tex` / `gi_occluder_tex` /
`bounce_lut`——它们是 B 方案打包进 array 后应消失的旧采样器（测试按 8 槽名单 + 负向断言守）。
packed GI 弹射的颜色不再采样 `bounce_lut`，而是用已绑的 `enum_lut` 查遮挡 cell 的 biome，
经 `hypsometric_tint()` + `biome_hue_modulate()` 近似弹射代表色（视觉等价，省一个 sampler）。

#### LOW（vq=0）不变的门控

运行时门控保证 B 前后 LOW 像素一致（测试里是硬断言 `pixel delta < 0.001`）：

- detail：`visual_quality <= 0` → `procedural_biome_detail` 返回 1.0，layer2 不参与；
- micro：`visual_quality <= 0` 或 `terrain_material_micro_layer < 0` → 直接返回 surface；
- bounce：**C 轮门控改为 `visual_quality < 1`**（MID/HIGH 开、LOW=0）；
- 水面 depth/软权重属于 CPU 烘焙数据，不改变水面程序在 LOW 的既有公式（只多 1 次已绑采样），
  LOW 水面也消费软权重（水面 pass 是独立程序，不影响 land 8 槽）。

#### 内存增量与性能取舍

- surface array 2→4 层：Web LOW（hm=512，512×~300）约 **+1.2 MB**；
  Web MID/HIGH（1024×~600）约 **+6 MB**。
- material array 4→5 层：mobile/512² 约 **+1 MB**，high/1024² 约 **+4 MB**（micro 图
  resize 到目标尺寸 + mipmaps，RGBA8）。
- detail：从 v1 时代的 4-tap 高度差分/无采样 → **1 次 array 采样**；
  材质族激活时（Web MID/HIGH 的正常路径）再叠 1 次 layer2 采样 + ALU 乘法，
  让 baked detail 也参与材质 albedo（LOW 不受影响）；
- micro：**1 次 array 采样**（原 Web 预算下该功能被裁掉，0 成本 0 效果）；
- bounce：**1 次 texelFetch + 1 次 enum_lut 采样**，替代旧桌面路径的 bounce_lut 采样；
  C 轮扩到 MID 后 MID 走同一路径并乘 0.6（无额外采样）；
  occluder 随 Web horizon 的 CPU marching 顺带产出（native 探针增量：512×298 horizon
  11.98 ms → **+0.17 ms**；1024×596 49.16 ms → **+0.62 ms**，几乎免费）；
- water depth：**1 次采样**替代湖泊多 tap/多半径邻域估算（Web 水面从"湖心湖岸同色"
  恢复出深度层次）。C 轮升级 RGBA8 后仍是 1 次采样：R 深度 + GBA 软权重一次读齐
  （compact 水面 w_lake/w_reef/w_kelp = max(binary, GBA)）；内存每像素 +3 B——
  Web LOW（derived 512×~381）约 **+0.45 MB**、Web MID/HIGH（1024×~762）约 **+2.3 MB**；
  GBA=0（旧 R8/兜底）自动退化为旧二元权重。

#### 实现边界与 C 收尾（2026-11-01，如实记录）

- **micro 的共享程序 A/B（C 轮实测，默认已放开）**：环境 **Edge 156 / WebGL2
  `MAX_TEXTURE_IMAGE_UNITS=16` / ANGLE(NVIDIA RTX 3070 Ti) → D3D11 → FXC**，
  `--headless=new`、每样本全新 profile（冷 shader 缓存）。方法：同一份 Web 导出，
  A=默认前缀（保留 `PK_PROBE_NO_MICRO`）、B=`?micro=shared`；每组 3 个冷样本，顺序
  A1,A2,B1,B2,B3,A3 抵消漂移；plan 指纹差 26 B = `#define PK_PROBE_NO_MICRO\n` 长度，
  证明两组编的是不同前缀。

  | 指标（均值） | A（默认裁 micro） | B（`?micro=shared`） | B−A | 阈值 |
  | --- | ---: | ---: | ---: | --- |
  | `world_map` 单张编译 | **5417 ms**（5208–5615） | **4582 ms**（4347–4880） | **−835 ms（−15.4%）** | ≤ +3000 ms ✅ |
  | 总 `sum_shader_ms` | 36978 ms | 34934 ms | −2045 ms（−5.5%） | ≤ +20% ✅ |

  boot/menu 差值在噪声内（+281/+279 ms）；21/21 张全部编译、无 JS/GL 错误；
  `probe_trivial_first` 一次性首编译 ~12–17 s 两组相同。**判定 SAFE → 共享 Web 程序默认
  启用 micro（MID/HIGH 设置档都有 micro），HIGH 独立程序同样有；保留
  `?micro=off|0|false` kill-switch 退回旧行为，`?micro=shared|on` 可显式开，非 web 恒关。**
  历史 Intel UHD + Chrome 的 20.7 s 悬崖在当前重构后的 shader 上未复现（normal/relief
  烘焙 array、水面拆 pass、`PK_WEB_LAND_ONLY`、horizon 烘焙等已移走联合编译/寄存器压力
  来源）；风险：本机 GPU 与历史悬崖机器不同（Intel UHD 未复测），故保留逃生开关；
  冷启动首访 ~45–50 s 与 micro 无关。完整数据与复现：`tmp/webbuild_ab/REPORT.md`、
  `samples.csv`、`verdict.json`。测试侧仍然用"去掉 `#define PK_PROBE_NO_MICRO\n` 的
  共享前缀"构造程序验证 vq=1/2 生效、vq=0 不变（不依赖默认值）。
- **baked detail（layer2）双路径消费**：材质族未绑/回退时走 `procedural_biome_detail`；
  Web/Compatibility 预算程序在材质族激活时也会把 layer2 乘进材质 albedo
  （`#if defined(PK_WEB_TEXTURE_BUDGET) && defined(VT_USE_TERRAIN_DETAIL)`，vq>=1 且
  `terrain_detail_available()`）。MID/HIGH 的真实产品路径能看到 baked detail；
  `web_quality_render_test` 两条路径都验证（材质关闭 delta 0.0284；材质激活另有专项断言），
  LOW 档另验证门控不变。
- **baked detail / bounce 生效档位（C 轮更新）**：packed GI bounce 门控从 `vq>=2` 放宽到
  **`vq>=1`**：MID 乘 0.6、HIGH 乘 1.0、LOW 恒 0；颜色近似与 HIGH 相同（enum_lut biome +
  `hypsometric_tint()`/`biome_hue_modulate()`，不再采样 `bounce_lut`）。surface layer3
  （occluder）在桌面 legacy 的 GPU horizon 路径不产出 → 全 0xFF（无弹射）；Web 由 CPU
  horizon bundle 产出（e2e 日志 `occluder_layer=0/1` 表示层是否填充）。
- **water_depth RGBA8（C 轮升级）**：非 tiled 的 `water_depth_tex` 由 static surface bake
  的 native bundle 直接上传 RGBA8（R=深度、G/B/A=湖/礁/海带 3×3 软权重，日志
  `water_depth=RGBA8`）；compact 水面在 render 函数里追加 `vec4 water_depth_px`，
  `w_lake/w_reef/w_kelp = max(binary, wd.g/b/a)`（保持无 if/else 直线写法）；R 深度语义不变
  （湖心用烘焙值、海面用连续 elev）。static bake 失败兜底：R=旧 `water_depth_buffer`、GBA=0，
  自动退化为旧二元权重。tiled 路径仍走原 R8/数组逻辑。

#### 风险（记录，不阻塞）

Web 共享程序（LOW/MID 运行档，C 轮起默认带 micro）编译体因 detail/micro/bounce 分支增大：
A/B 实测 world_map 编译 5417→4582 ms（−15.4%）、总 warmup −5.5%，无 10× 悬崖；历史悬崖
机器（Intel UHD 770 + Chrome）未复测，故保留 `?micro=off` kill-switch。Compatibility 真 GPU
已覆盖编译通过；冷启动首访 ~45–50 s 主要是浏览器/wasm 与一次性首编译，与 micro 无关。

#### 验证入口

- `tests/rendering/web_quality_render_test.gd`（Compatibility 真 GPU，**v4，冻结后 116 checks / 0 failures**）：
  - 4 层 surface array + 5 层 material array 合成；land 仍 8 槽名单；
  - MID(vq=1)/HIGH(vq=2) 改 layer2 detail / layer4 micro（`camera_zoom=2`）→ 像素变化
    （实测 delta：detail 0.028431；材质族激活路径 baked detail 0.011765；
    HIGH 程序 micro 0.009804/0.012745）；
  - **C 轮：HIGH 与 MID(vq=1，0.6 强度) 改 layer3 occluder → GI 弹射像素变化
    （HIGH 0.002941 / MID 0.001961）**；
  - **C 轮：共享 micro 程序（`WORLD_MAP_WEB_PREFIX_MICRO`，并断言与"去 NO_MICRO
    字符串"逐字节等价）vq=1/2 改 material layer4 → 像素变化（0.001961 / 0.008824），
    vq=0 不变（0.000000）**；A/B 默认值钩子（Engine meta 模拟 web boot）：true →
    MICRO 前缀、false → NO_MICRO 前缀、真实非 web → NO_MICRO；HIGH 独立程序 micro 断言保留；
  - **LOW(vq=0) 改 detail/micro/occluder → 像素不变（严格 <0.001，实测 0.000000）**；
  - HIGH 水面 7 槽、compact 水面 5 槽，均含 `water_depth_tex`；改 depth 内容 → 水面像素变化
    （HIGH 0.021969 / compact 0.079067）；**C 轮：compact 水面 RGBA8 软权重——
    OCEAN 格改 G/B/A → 0.072227，LAKE 格二元权重 1 饱和软 G → 0.000000（等价旧二元行为）**；
  - `_apply_water_uniforms()` 显式补绑 noise_tex 的源码断言保留。
- `tests/world/terrain_shader_variant_test.gd`：LOW/land 8、纯预算 8（桌面 compat）、
  HIGH water 7、compact 5、tiled 17；非 tiled 有 4 个 v3 门控 uniform、无 2D detail sampler；
  另含"去掉 NO_MICRO 的共享前缀仍编译 / sampler 8"用例（冻结后 **533 checks / 0 failures**，
  sampler 行 `web_micro_shared=8`）；
- `tests/world/web_static_surface_bake_test.gd`：4 层 surface array / 5 层 material array /
  horizon bundle 返回 occluder / `water_depth=RGBA8` 契约 / A/B 默认值（冻结后 **127/0**）；
- `tests/world/web_water_pass_node_test.gd`（22/0）、`terrain_gi_test.gd`（PASS，含 C 轮
  bounce MID 门控源码断言）；
- e2e legacy 生成：日志确认
  `[terrain-baked-surface] ... surface_array=ok layers=4 detail_layer=1 occluder_layer=0 water_depth=RGBA8`
  （`water_bytes=3121152`）与 `[terrain-material-tiles] layers=5 target=1024 micro_layer=4`
  （冻结后实测 native 363.5 / wall 372 ms、`layers_ms=23`）。

### 9.26 陆地/水面双 program 全平台拆分 + 保守覆盖 mesh（2026-11-02）

> 桌面（Forward+/GLES3）与移动（Vulkan/Mobile）也把主地形拆成两个 fragment program，
> 配合 `TerrainCoverageMesh` 产出的两张保守覆盖 mesh：纯区域只光栅化自己那条管线，
> 海岸混合 block 两侧都画、shader 内逐像素 `is_water` 互补 discard。Web 既有路径
> （LOW/MID 共享 land 程序 + compact 水面 / HIGH 独立两片）**行为与字节前缀均不变**。

#### 宏与前缀契约

- 新宏：`PK_LAND_ONLY`（陆地 program）/ `PK_WATER_ONLY`（水面 program）。
  陆地 program 不 include `water_pipeline.gdshaderinc`（保留 `water.gdshaderinc` 供
  河面法线 `sample_water_normal`）；水面 program 不 include `land_pipeline.gdshaderinc`。
- Web 的 `PK_WEB_LAND_ONLY` / `PK_WEB_WATER_ONLY` 前缀常量（`WORLD_MAP_WEB_PREFIX(_MICRO)` /
  `WORLD_MAP_WEB_HIGH_PREFIX` / `WATER_WEB_HIGH_PREFIX` / `WATER_PASS_PREFIX`）**一个字节都没改**；
  shader 顶部只做「Web 宏 → 通用宏」的别名归一。
- 桌面前缀常量（`HexRenderer`，测试逐字节断言）：
  - 陆地：`[MAP_VISUAL_TILED] + [MOBILE_QUALITY_*] + [PK_WEB_TEXTURE_BUDGET（仅 Compatibility）] + "#define PK_LAND_ONLY\n"`
  - 水面：同顺序，末段换成 `#define PK_WATER_ONLY\n`（`SPLIT_LAND_ONLY_DEFINE` / `SPLIT_WATER_ONLY_DEFINE`）。

#### 运行时开关与回退

- `@export var split_land_water_passes = true`（全平台默认开）、
  `@export var terrain_coverage_mesh_enabled = true`（覆盖 mesh 可用性 A/B）。
- `_split_active()`：开关 && `terrain_surface_debug_view == 0` && 非（Compatibility + tiled）。
  debug 视图（13/14/16/17 等）必须回退单 program + 整张 quad（诊断画面不能有洞）。
- `_water_pass_active()`：拆分激活 + Web 维持既有子条件（只有 world-min/PC-HIGH 才有第二 pass；
  Web MID 的 world_map 自己画水）。
- 安全回退：水面材质 `get_shader_uniform_list().is_empty()` → 置 `_split_program_failed`，
  下一帧重编**不带** `PK_LAND_ONLY` 的陆地变体 + 整张 quad（**整条**回退，不许只回退一半）。
  Web 保持既有降级（land-only + 暗海蓝占位色，字节契约不动）。
- F9 `toggle_world_shader_disabled()` 两片一起关；shader 热重载两片都从磁盘重取并清失败标记；
  `set_mobile_quality_tier` / `set_map` / `set_map_cooperative` 都经 `_apply_uniforms()` →
  `_sync_water_quad()` 统一重建。

#### 覆盖几何（`scripts/rendering/terrain_coverage_mesh.gd`）

- 契约：`TerrainCoverageMesh.build(world, world_bounds, wrap_period_x, block_world=16.0)` →
  `{ok, reason, land_mesh, water_mesh, stats}`；失败返回 `ok=false` + reason，不抛异常。
- 分类源与 shader 同源：`world.pixel_to_cell_lookup` → `cell.terrain` → `MapData.is_water_render_lut()`；
  `null`（地图外 padding）归 water（shader 里是 `B_SEA_ICE` 水面管线）。
- 保守超集：block 内含该类像素即入选，随后两张 mesh 各自外扩 1 block；边界 quad 裁剪到
  世界矩形内；wrap P>0 时 −P/0/+P 三份整份几何进同一个 ArrayMesh（与
  `HexRenderer._build_world_quad_mesh()` 逐位一致）。
- 成功时 land/water mesh 一定是 ArrayMesh（可能是 0-surface 的合法空 mesh：全水/全陆地图）；
  渲染器只按 `ok` 判断成功，不用"空 mesh"当失败。
- 生产规模（60×40 / derived 1024×606 / P=2286.31 / block16）headless `build_ms≈100–119`，
  `blocks 143×89`、`land_tris 54876 / water_tris 30342`（含 wrap 3×）；只在 `set_map` /
  `_rebuild` / 开关切换时构建，运行期不重建；模块缺失/构建失败/开关关闭 → 两片共享整张 quad。
- **只有真的会画两个 program 时才用覆盖 mesh**（`_water_pass_active()`）：单 program 状态
  （Web MID、拆分关闭、编译失败回退）必须让陆地 quad 铺满整张地图，否则水面像素露背景。

#### 水面 program 的 uniform 对齐与迷雾

- 走 `world_map.gdshader` 的水面 program（Web HIGH / 桌面拆分）在材质创建后从主材质
  **整表拷贝** uniform，并显式补绑 `noise_tex` / `water_depth_tex` / tiled `visual_*_tiles`；
  运行期所有世界 uniform 推送经 `_push_world_uniform()` 镜像到水面材质（只写它声明过的键），
  保证 season/TOD/fog/羊皮纸/光照/wrap/cell LUT/camera zoom 等与陆地**逐项同值**。
- 未探索像素：拆分后纯水 block 没有陆地 pass 兜底（Web 上 Fog 层还可能被裁掉），
  所以**每个 program 自己画同值 `fog_unexplored_color`**：桌面水面 program 沿用 world_map 的
  fog 出口；Web compact 水面程序新增 `uniform vec3 fog_unexplored_color` 并在
  `fog_early_out` 命中时直接输出该色（不再 discard），两片同色幂等。

#### 采样预算（不变）

| 平台 / 变体 | 陆地 program | 水面 program |
|---|---|---|
| 桌面 legacy（含 mobile 三档） | 13 | 13 |
| 桌面 tiled（含 mobile 三档） | 17 | 17 |
| 桌面 Compatibility（非 tiled，8 槽预算） | 8 | 8 |
| Web LOW/MID 陆地 + compact 水面 | 8 / — | — / 6 |
| Web HIGH 陆地 + HIGH 水面 | 8 | 8 |

桌面拆分变体的采样集/ uniform 集与今天完整主 pass **逐一相同**（`terrain_shader_variant_test`
逐名断言）。v4 起桌面 legacy 的两个 2D edge sampler 收进 surface array（15→13）；
Web compact 水面与 HIGH 水面各 +1（surface array），见 §9.27。

#### 验证入口

- `tests/world/terrain_shader_variant_test.gd`：**615 checks / 0 failures**。新增桌面拆分断言
  （legacy/tiled × 4 质量档两个 program 都编译、采样集相同、tiled 保留
  `VT_USE_WATER_DEPTH`/`terrain_static_baked`、compat 预算 8、`PK_LAND_ONLY` 不进河面法线压平条件、
  覆盖 mesh 动态接线/失败回退源码断言）；原 533 条 Web 断言全部保留，Web sampler dump 不变。
- `tests/world/land_water_split_node_test.gd`（新增）：**57 checks / 0 failures**。含真实
  `TerrainCoverageMesh` 集成（合成 4×4 texel 世界 → 两张 mesh 分别上两块 quad）、模块缺失/
  数据缺失优雅失败回退整 quad、拆分闸门（debug/关闭/编译失败）、uniform 镜像、tiled 重编、
  编译失败整条回退单 program。
- `tests/world/web_water_pass_node_test.gd`：**25 checks / 0 failures**（用
  `_forced_water_program_kind="web_min"` 继续守 Web 紧凑水面字节契约 + fog 色推送断言）。
- 诊断：`HexRenderer.land_water_split_diagnostics()` 返回 `split_active` / `water_pass_active` /
  `split_program_failed` / `water_pass_failed` / `coverage_ok` / `coverage_reason` /
  `coverage_stats` / `land_program_land_only` / `water_program_kind`。

#### 真机验收清单（需要用户/Lead 在真实 GPU 上做，headless 覆盖不到）

1. PC Vulkan（legacy 与 tiled 两套 world）：与拆分前同机位/同种子截图逐像素对比海岸线、湖泊、
   河流、雾边界；OSD 确认 `land_water_split_diagnostics().split_active == true` 且
   `coverage_ok == true`。
2. GPU-time A/B：F9 关闭地形 shader 的 ΔFPS 探针、`split_land_water_passes=false` 对照；
   重点看海岸密集视角与全海洋视角（模型 B 下预期接近中性，模型 F 下应有明显下降）。
3. 移动端（Vulkan；GLES3 Compatibility 走单 program 回退）：q0/q1/q2 三档各跑一段，
   确认画面一致、无空洞/接缝、无 shader 编译失败日志。
4. Web 回归：LOW/MID/HIGH 三档各进一次世界，确认水面/迷雾与 2026-11-01 版本一致
   （warmup 指纹对账仍应通过；compact 水面的 fog 色只在未探索纯水区域可见）。
5. 交互边界：GM 面板切换 debug 视图（13/14/16/17）→ 自动回退单 program 且有画面；
   切回 0 恢复拆分；F9 两片一起关；画质档切换后水面仍正确重编。

#### 残余风险

- 桌面拆分后的**帧时间收益未在真机测量**（本任务是架构落地）；若目标设备分支是真分支
  （模型 B），收益可能接近中性甚至略负（多一个 draw + 覆盖 mesh 重叠块）。
- 覆盖 mesh 构建 ~100ms 落在加载边界；`set_map` 若在加载链里被连续触发两次会重复构建
  （当前未见；如出现可按 (world/bounds/wrap/开关) 加缓存）。
- Web compact 水面把未探索像素从 discard 改为画 fog 色：视觉应完全一致（同色幂等），
  但真机仍需确认 Fog 层与水面 pass 的绘制顺序/裁剪组合没有意外差异。
- 桌面 tiled 拆分水面 program 与陆地共享完整 VT 预算（17 sampler）；桌面/移动 Vulkan/Mobile
  32+ 无压力，但若将来把 tiled 开到 GLES3（当前已回退单 program）需重新核算 8 槽。

### 9.27 per-world surface array 扩到 6 层：Web 恢复次生生态过渡 / crease / 海岸占比 / 次生水格（2026-11-02）

> **一句话**：把 `terrain_surface_tex` 从 4 层扩到 6 层（layer4 = `edge_distance` RGBA、
> layer5 = `edge_neighbor` RG + `water_depth` R），陆地与两个水面程序读同一个 array，
> 于是 Web 上"次生 biome 混合 / DitherUV 远景过渡 / 沟谷 crease / 海岸 halo / 次生水格"
> 全部回来，而**材质 sampler 数量一个都没涨**（陆地仍 8；compact 水面 5→6、HIGH 水面 7→8）。

#### 数据从哪来（零新增烘焙）

`run_bake_visual_tile_layer_pass` 的返回 bundle 本来就有 `edge_distance`（RGBA8）与
`edge_neighbor`（RG8）——tiled 桌面一直用它。单 tile 路径只是原来没打包，现在多填两层：

| 层 | 内容 | 过滤 | 消费方 |
| --- | --- | --- | --- |
| layer4 | `bundle.edge_distance`：R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比 | LINEAR | 陆地（secondary blend + DitherUV + crease + `shore_frac`）、两个水面程序（`shore_frac` + edge 权重） |
| layer5 | RG = `bundle.edge_neighbor` 16-bit 次生 cell id；B = `bundle.water_depth` R；A 预留 | **texelFetch** | 陆地 / 水面：`decode_edge_secondary_index()` 等价实现 |

中性层（单 tile 失败 / 旧图）：layer4 = `R=255`（权重 0）/ `G=BA=0`，layer5 = `RG=0xFFFF`
（无次生格）/ `B=A=0`。**绝不能**用整通道 255 的中性图——那会画出假 crease 与假海岸占比。
运行期门控 `terrain_edge_layers_bound = (layers>=6)`，helper 在 false 时直接返回中性值，
**绝不采样越界层**（GLES3 对越界 array layer 的返回值未定义）。

#### 陆地程序恢复的四项

- **secondary biome 混合 + DitherUV 远景过渡**：`VT_USE_EDGE_DISTANCE` / `VT_USE_EDGE_NEIGHBOR`
  在 Web 预算变体里重新定义，`terrain_edge_secondary_weight_d()` / `terrain_hybrid_static_weight()`
  与桌面走**同一份**代码（移动端分支的权重公式抽到
  `visual_tile_sampling::terrain_static_edge_weight()`，水面共用）。
- **crease**：`scals.a = edge_distance.g` 直接进 `terrain_baked_normal(uv, quality, scals.a)`。
- **coast_smooth / 海岸 halo**：`shore_frac = edge_distance.ba` 进 `sample_shore_neighborhood()`；
  因为 `PK_TERRAIN_STATIC_PACKED` 让非 tiled 也命中"已烘焙"快路径，海岸邻域从 **8 次
  `map_index` fetch 降为 0 次**（Web 陆地与 HIGH 水面同时受益）。`coast_smooth` 的 band 用的
  `shore_w` 因此也从硬计数变成双线性连续场。
- **不新增 sampler**：以上全部读已绑的 `terrain_surface_tex`。

#### 水面程序恢复的三项

- **compact 水面（`world_water_web.gdshader`，5→6）**：新增
  `VT_USE_TERRAIN_SURFACE_ARRAY + VT_USE_EDGE_DISTANCE + VT_USE_EDGE_NEIGHBOR`，在
  `fragment()` 前导段（**不是**着色函数里，着色本体仍零分支）查一次次生格：
  `secondary_biome/cover` + `static_edge_mix`（连续距离权重，不转 DitherUV）+
  `shore_frac`。海/湖/礁/海带交界因此不再是一个个方块，浅滩也变成连续带。
  权重宽度 = `terrain_ecotone_width * WATER_EDGE_LOW_SCALE(0.58)`，与 LOW 陆地同一档缩放。
- **HIGH 水面（`PK_WEB_WATER_ONLY`，7→8）**：world_map 的 `#if !defined(PK_QUALITY_LOW)`
  次生水格块本来就在，只缺 sampler；补上 surface array 后 `render_water_pipeline()` 直接吃到
  `water_secondary_biome` / `water_static_edge_mix` / `shore_frac`，PC 水面管线一行没改。
- **推送**：`_apply_water_uniforms()` 的非 tiled 分支显式补 `terrain_surface_tex` /
  `terrain_surface_layer_count` / `terrain_edge_layers_bound` / `has_terrain_edge_data` /
  `terrain_static_baked` / `terrain_ecotone_width`（独立程序不经过陆地材质的推送；
  world_map 水面程序还会整表拷贝一次，两处同值）。

#### 代价与验收

- 显存：surface 4→6 层 Web LOW（512×~300）约 **+1.2 MB**、MID/HIGH（1024×~600）约 **+6 MB**；
  生成时间：**不变**（edge payload 本来就在 bundle 里，只多一次 GDScript 交织循环，
  日志里单列为 `edge_ms`）。
- 日志：`[terrain-baked-surface] ... layers=6 edge_layers=ok|neutral edge_ms=..`。
- 测试：`terrain_shader_variant_test` 里非 tiled 的 edge 断言从"2D sampler 存在"翻成
  "surface array + `terrain_edge_layers_bound` 存在、2D edge sampler 不存在"，
  Web 陆地仍 `<= 8` 槽，compact 水面 = 6 槽。
- **待真机量（用户复核项）**：Web LOW 是否再 include `shore_common`（海岸 halo）。
  它只增加共享程序的编译体、不增加采样槽；用现成的 Edge/ANGLE A/B 手段
  （`WebShaderWarmup.PROBE_WORLD_LAND_SPLIT` + `?micro=off` 对照、真机 `warmup_shader`
  逐张耗时）先量 `world_map` 编译增量再决定，默认**不开**。

### 9.28 Web 存档失败定案：「边界空转」没有 country 推进者（2026-11-01）

**症状**：浏览器里点保存，界面报超时，控制台只有一条

```text
WARNING: [save] boundary timeout blocking=save_requires_idle_country stalled_frames=90 detail={"day":6, ...}
```

`GameSaveCoordinator._wait_for_safe_boundary()` 在时钟已经 `pause(true)` 的状态下
每帧调 `MapGenerator.advance_save_boundary()`，而它只排 Effect ACK 链 + economy
inflight，**没有推进 country**。暂停期间能推进 country 的两条路都断了：

- `_continue_economy_inflight()` 的 runtime-graph 分支要先过
  `needs_continuation_pulse()`；暂停时没人举 barrier，恒为假 → 直接 return；
- `CountryDailySystem.should_run()` 在 runtime graph / worker 拥有 country 时直接
  返回 false，`_sus` 也不会给它切片。

于是 `country_should_run(day)` 保持为真，web 的 90 帧 / 3 s 停顿上限一到就
`save_boundary_timeout`（这个上限是 §9.23 故意压短的，本次不动）。

**修复**（`scripts/geography/map_generator.gd`，纯 GDScript，随 pck 生效）：
`advance_save_boundary()` 按 country 当前 owner 补推一次 ——

- runtime graph 拥有 country：直接 `_advance_runtime_graph_pulse(day)`（与正常帧同一条链路）；
- GDScript `country_daily` 拥有 country：`continue_system(&"country_daily")` 切片，
  单次调用上限 `SAVE_BOUNDARY_COUNTRY_MAX_SLICES = 8`，每片后继续排 Effect ACK 链，
  避免「country 等 ACK → `should_run` 仍为真」再死一次。

country 已经空闲时不进循环，两个分支都幂等。

**配套诊断**（`game_save_coordinator.gd::_boundary_diagnostics`）：超时告警现在额外带
`country_should_run` / `country_busy` / `country_stage` / `runtime_graph_active`，
下次卡住可以直接判断是哪个 owner 没排空。

> 未覆盖：若 WorldClock 的 `day_index()` 与 `simulation_committed_day` 本身就不一致
> （例如加载存档后 native 侧领先很多天），`country_should_run(day)` 会在一个
> 「已经过去的日子」上被反复问真。那属于载入/时钟一致性问题，不在本节修复范围；
> 上面的诊断字段可以先把这类情况识别出来。