# 从源码构建（跨设备 / 新机器）

本文是「换一台机器，从零把它跑起来 / 打出包」的唯一入口。
`WebBuild/`、`Build/` 里的产物**不再进版本库**（见 §7），所以新设备要么自己构建，
要么下载 CI 产物（见 §8）。

> 已在本机验证过的组合：Windows 10/11 + VS 2022 + Godot 4.6.2 + emsdk 4.0.20。
> macOS / Linux / Android 的脚本与路径见各节，命令来自仓库里现成的脚本，
> 但**没有在本文写作时的那台机器上实跑**，首次使用请按 §9 的清单逐项确认。

---

## 0. 速查表

| 目标 | 一条命令 | 产物目录 |
| --- | --- | --- |
| Windows 原生扩展 | `gdext\rebuild.bat` | `Project/project-keynes/addons/dots_ext/bin/windows/` |
| macOS 原生扩展 | `cd gdext && ./rebuild.sh` | `.../bin/macos/` |
| Linux 原生扩展 | `cd gdext && scons platform=linux target=template_release -j8` | `.../bin/linux/` |
| Android 原生扩展 | `gdext\build_android.bat` | `.../bin/android/` |
| Web 全流程（推荐） | `Build-Web.cmd` | `WebBuild/` |
| Web 只重新导出 | `Build-Web.cmd skip-native` | `WebBuild/` |
| 本地预览 WebBuild | `serve_web.bat` | `http://127.0.0.1:8060/ProjectKeynes.html` |
| 桌面导出 | Godot 编辑器 → 导出 → `Windows Desktop` 预设 | `Build/ProjectKeynes.exe` |

---

## 1. 克隆与子模块

```bash
git clone --recurse-submodules https://github.com/HkingAuditore/Project.Keynes.git
```

已经克隆过、但没初始化子模块（`git submodule status` 前面是 `-` 号就是这么回事）：

```bash
git submodule update --init --recursive
```

- `gdext/godot-cpp` 是子模块，**钉死在某个 commit**（当前目标 Godot 4.6 的 API）。
  不初始化就一定编不过，报错通常是 `gdextension_interface.h: No such file`。
- 仓库本身较大（`addons/` 里有历史遗留的调试二进制），首次 clone 会慢，属正常。

---

## 2. 工具链

| 依赖 | 版本 | 谁需要 | 说明 |
| --- | --- | --- | --- |
| Python 3 | 3.10+ | 全部 | 装 SCons：`python -m pip install scons` |
| SCons | 4.x | 全部 | `scons --version` 能跑通即可；注意它必须和 Godot 用的不是同一个东西，只是构建用 |
| Godot 编辑器 | **4.6.2.stable** | 导出 / 预烘 | 用 `GODOT_BIN` 环境变量指定路径最省事 |
| 导出模板 | **4.6.2.stable** | 导出 | 编辑器 → 管理导出模板，或手动解压到 `%APPDATA%\Godot\export_templates\4.6.2.stable\` |
| MSVC | VS 2022（x64） | Windows / Android | 从「x64 Native Tools Command Prompt for VS 2022」启动，否则 `cl.exe` 找不到 |
| Xcode CLT | 最新 | macOS | `xcode-select --install` |
| Emscripten | **4.0.20**（不能用别的版本） | Web | 见 §4.1 |
| Android SDK + NDK | Side-by-side | Android | 见 §5.2 |
| FMOD Studio | **2.03.15** | 仅改音频时 | 见 §6；日常构建**不需要** |

版本是**硬约束**的两个地方：Emscripten 4.0.20、Godot 4.6.2。其它工具版本宽松。

---

## 3. 原生扩展 `dots_ext`（必须先编，否则游戏会回落到 GDScript 慢路径）

### 3.1 Windows

```bat
cd gdext
rebuild.bat
```

脚本会先找 `scons`（PATH → `%APPDATA%\Python\Python314\Scripts`），
然后连编 `template_debug` 和 `template_release` 两个 target。

**编之前必须完全关掉 Godot**，否则 dll 被占用，链接阶段报 `LNK1104: cannot open file`。
首次构建会顺带编 godot-cpp 本体（约 10–20 分钟），之后是增量的。

等价的裸命令（自己控制参数时用）：

```bat
scons platform=windows target=template_debug   dev_build=no -j8
scons platform=windows target=template_release dev_build=no -j8
```

### 3.2 macOS

```bash
cd gdext
chmod +x rebuild.sh   # 仅第一次
./rebuild.sh
```

脚本会自动判断 Apple Silicon / Intel 并传 `arch=arm64` 或 `arch=x86_64`。
同样要先退出 Godot（dylib 会被锁）。

### 3.3 Linux

仓库没有 Linux 一键脚本，直接用 SCons：

```bash
cd gdext
scons platform=linux target=template_debug   dev_build=no -j"$(nproc)"
scons platform=linux target=template_release dev_build=no -j"$(nproc)"
```

### 3.4 产物在哪、名字必须对得上

`SConstruct` 直接把二进制写进项目目录，**不需要手动拷贝**：

| 平台 | 产物 |
| --- | --- |
| Windows | `addons/dots_ext/bin/windows/dots_ext_*.windows.template_{debug,release}.x86_64.{dll,exp,lib}` |
| macOS | `addons/dots_ext/bin/macos/libdots_ext.macos.template_*.{arm64,x86_64}.dylib` |
| Linux | `addons/dots_ext/bin/linux/libdots_ext.linux.template_*.x86_64.so` |
| Web | `addons/dots_ext/bin/web/libdots_ext.web.template_*.wasm32[.threads].wasm` |
| Android | `addons/dots_ext/bin/android/libdots_ext.android.template_*.arm64.so` |

命名规则：Windows 默认 basename 是 `dots_ext_annual_v1`，其它平台是 `dots_ext`，
可用环境变量 `DOTS_EXT_OUTPUT_BASENAME` 覆盖。

**改过 basename 就必须同时改 `addons/dots_ext/dots_ext.gdextension` 的 `[libraries]` 段**，
两边必须逐字一致，否则编辑器启动时报 `Can't open dynamic library` / 类全部丢失。
这是本仓库最容易踩的坑之一：历史上很多 `dots_ext_hotloop_v12`、`..._fiscal_cashcap_v1` 之类的
实验产物，就是靠改这个变量编出来的，**不要把它们提交**（见 §7）。

### 3.5 编不过时的检查顺序

1. 是不是在 VS 的普通 `cmd` 里编的（没进 x64 Native Tools 环境）？
2. `git submodule status` 是不是带 `-`（子模块没初始化）？
3. Godot 是不是开着（dll 占用）？
4. `scons --version` 是否在你当前的 Python 环境里？
5. 只改 GDScript 时**不需要**重编扩展，别白等。

---

## 4. Web（wasm side module + 导出）

### 4.1 为什么 Emscripten 必须是 4.0.20

Godot 4.6 官方 Web 导出模板就是用 4.0.20 编的。版本不一致时，side module 的
pthread/异常 ABI 对不上，浏览器控制台只会给一句
`failed to load dynamic library`，非常难查。

```bash
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install 4.0.20
./emsdk activate 4.0.20
# Linux/macOS
source ./emsdk_env.sh
# Windows
emsdk_env.bat
```

`Build-Web.cmd` 假定 emsdk 在**仓库根目录的 `emsdk/`**（该目录已被 `.gitignore` 忽略）。

### 4.2 三个必须记住的编译约束

| 约束 | 取值 | 不遵守的后果 |
| --- | --- | --- |
| `threads` | `yes`（对齐预设 `variant/thread_support=true`） | 原生 host 的 `std::thread` worker 不推进，页面卡在「进入世界」98% |
| `disable_exceptions` | `no` | `economy_*.h` 等 11 个文件用 `throw` 报不变量错误，编译直接失败 |
| `lto` | `none` | 用默认 `full` 时每次链接要等很久，联调期不划算 |

对应的编译命令（`Build-Web.cmd` 内部就是这条）：

```bat
scons platform=web arch=wasm32 threads=yes lto=none disable_exceptions=no -j16 target=template_release dev_build=no
```

### 4.3 一键导出

```bat
Build-Web.cmd              :: release：编 native → 预烘目录 → 导出 release 包
Build-Web.cmd debug        :: 同上，debug 变体
Build-Web.cmd both         :: 两套都做
Build-Web.cmd skip-native  :: 不重编 wasm，只预烘 + 重新导出（改 GDScript 后最快的选项）
```

脚本能用的前提：
- `emsdk/emsdk_env.bat` 存在；
- Godot 4.6.x 能找到（`GODOT_BIN`，或按脚本里的候选路径搜索）；
- 4.6.2 的 Web 导出模板已安装。

日志全在 `tmp/`：`web_native_<target>.log`、`web_prebake.log`、`web_export_release.log`。
任何一步失败脚本都会 `exit /b 1`，**不会**产出一个半成品包。

可选环境变量：`GODOT_BIN`、`PK_WEB_JOBS`（默认 16）、`PK_WEB_THREADS`（默认 `yes`，改成 `no` 前先读 §4.5）。

### 4.4 手动分步（脚本坏了 / 想插桩时）

```bat
:: 1) 原生 wasm
cd gdext
scons platform=web arch=wasm32 threads=yes lto=none disable_exceptions=no -j16 target=template_release dev_build=no

:: 2) 预烘加载目录（必须在导出之前，且必须是独立进程）
"%GODOT_BIN%" --headless --path Project\project-keynes --script res://tools/prebake_loading_catalogs.gd

:: 3) 导出
"%GODOT_BIN%" --headless --path Project\project-keynes --export-release Web WebBuild\ProjectKeynes.html
```

第 2 步不能省、也不能拿到编辑器导出 hook 里做：编辑器进程里 GDScript 的 scripting
是关闭的，脚本化 `.tres` 的默认值会读成 `null`，烘出来的快照是错的（历史现象：
`Loading catalog export bake failed: Invalid data`）。细节见 [`docs/web-export.md` §8](./web-export.md#8-预烘加载目录loading-catalog-prebake)。

### 4.5 `nothreads` 变体是个陷阱

`threads=no` + `variant/thread_support=false` 能进主菜单、能生成世界，但加载到 98%
主线程硬卡死（画面完全冻结）。原因是 `gdext/src/native_simulation_host.cpp` 用
`std::thread` + 条件变量驱动每日仿真，没有 pthread 时 worker 不推进。
**除非你先把 host 改成单线程内联模式，否则不要用这个变体。**

### 4.6 本地预览与验证

```bat
serve_web.bat            :: 默认 8060 端口，会自己开浏览器
serve_web.bat 8080       :: 换端口
```

**不要用 `python -m http.server`**：它不发 `.wasm` 的正确 MIME，也不发
`Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` —— threads 变体需要
SharedArrayBuffer，缺这两个响应头浏览器会直接拒绝启动。

自动化验证：

```bat
python tools\verify_web_export.py  --url http://127.0.0.1:8060/ProjectKeynes.html
python tools\verify_web_session.py --url http://127.0.0.1:8060/ProjectKeynes.html --no-headless
```

第一个只验「页面能起来」（`--headless` 下 Chrome 走 SwiftShader，够了）；
第二个验完整会话（新游戏 → 进世界），**必须 `--no-headless`**，需要真实 GPU。

---

## 5. 桌面 / 移动端导出

### 5.1 Windows

预设 `Windows Desktop`，输出 `Build/ProjectKeynes.exe`。
在编辑器里「项目 → 导出」或：

```bat
"%GODOT_BIN%" --headless --path Project\project-keynes --export-release "Windows Desktop" Build\ProjectKeynes.exe
```

### 5.2 Android

1. 装 Android Studio → SDK Tools → **NDK (Side by side)**；脚本会自己找
   `%ANDROID_HOME%\ndk\<版本>`，也可以直接设 `ANDROID_NDK_ROOT`。
2. 编原生库：`gdext\build_android.bat`（`release` / `debug` / `both`）。
3. 编辑器里配好 keystore，用 `Android` 预设导出 `Build/ProjectKeynes.apk`；
   一键装机脚本是仓库根目录的 `build_install_android.bat`（需 adb）。
4. 只看日志：`capture_android_log.bat`。

Android 预设里的 `godot-lib.*.aar` 已经在仓库中（`android/build/libs/`），无需额外下载。

---

## 6. FMOD 音频（可选）

四个 bank（`Master.bank`、`Master.strings.bank`、`Music.bank`、`UI.bank`）**已入库**，
放在 `Project/project-keynes/assets/audio/banks/Desktop/`。日常构建不用碰 FMOD。

只有改了 `Audio/ProjectKeynes/ProjectKeynes.fspro` 或音源时才需要：

```bat
Build-FMOD-Banks.cmd      :: 用 tools/fmod-studio/2.03.15/fmodstudiocl.exe 重烘并同步到 banks/Desktop
Open-FMOD-Studio.cmd      :: 打开 FMOD Studio GUI
```

FMOD Studio 版本固定在 **2.03.15**，命令行工具路径写死在
`tools/audio/Build-FmodBanks.ps1` 里。Web 平台没有 FMOD 库，Web 预设已把
`addons/FmodGodot/*` 和 `assets/audio/banks/*` 排除在 pck 之外。

---

## 7. 为什么 `WebBuild/` 和 `Build/` 不进版本库

- **体积**：Web 产物约 345 MB，其中 `ProjectKeynes.pck` 约 **282 MB**，
  超过 GitHub 单文件 100 MiB 硬限制，**推不上去**。
- **性质**：它们是可重建的构建产物，每次构建内容全变，进 git 等于给每个历史版本
  都存一份二进制。本仓库的历史已经因此膨胀（`addons/` 里躺着 2.1 GB 的历史 dll）。
- pck 是**单体格式**（`GDPC` 头 + 目录 + 连续数据区），引擎没有分卷支持，
  「切成 3 个 94 MB 再让浏览器读」这件事在 Godot 里不存在；

因此：
- `WebBuild/`、`Build/` 已从版本库移除并加入 `.gitignore`；
- 发布走 **GitHub Actions 产物 / Release**（见 §8）；
- 需要时用 `git add -f` 强制加回是**不推荐**的。

### 7.1 pck 现在 282 MB 花在哪（实测目录明细）

| 类型 | 体积 | 备注 |
| --- | --- | --- |
| `.ctex` | 154.6 MB | 导入后的纹理 |
| `.fontdata` | 56.7 MB | 中文字体：NotoSerifSC 10.3 / SweiGothic-Regular 10.1 / SourceHanSerif 10.1 / SweiGothic-Bold 9.8 / SourceHanSans-VF 7.4 … |
| `.res` | 30.5 MB | 其中 `assets/textures/loading_prebaked_v1/material_1024_{0..3}.res` 各 5.33 MB |
| `.ctexarray` | 30.1 MB | s3tc + etc2 双套（浏览器兼容需要） |
| 其余 | ~9 MB | `.gdc` / `.json` / shader |

想压下来的顺序（收益大、风险小优先）：

1. **字体子集化**或砍到 2 套字体 → 约省 40–50 MB；
2. `loading_prebaked_v1` 的 4 张 1024² 改成导入压缩纹理 → 约省 20 MB；
3. 纹理走 VRAM 压缩 / mobile import 预设；
4. 关掉 s3tc 或 etc2 其中一套 → 再省 ~15 MB，**但会丢浏览器兼容**（Safari 只认 ETC2），不建议；
5. 真要多包：Godot 支持运行时 `ProjectSettings.load_resource_pack()` 加载第二个 pck，
   需要自己导出第二个包并在 Web 端 fetch 后加载——工程量大，且**不解决 git 体积问题**。

---

## 8. CI（GitHub Actions）

`.github/workflows/web-build.yml`（手动触发 `workflow_dispatch`）：

1. checkout（含子模块）→ 装 Python + SCons；
2. 装 emsdk 4.0.20（带缓存）；
3. 下载 Godot 4.6.2 win64 编辑器 + Web 导出模板；
4. 跑 `Build-Web.cmd release`；
5. 把 `WebBuild/` 作为 **artifact** 上传；推 tag `v*` 时再附加到 Release。

下载产物：仓库页 → Actions → 选中那次运行 → 页面底部 Artifacts。

> 这个 workflow 与本地流程一一对应（就是把 `Build-Web.cmd` 搬上 runner），
> 但**首次运行请自己看一遍日志**：runner 的镜像、emsdk 下载源、模板解压路径
> 都可能随 GitHub 更新漂移。版本号集中在 workflow 顶部的 `env:` 里，改一处即可。

---

## 9. 新机器清单（照这个顺序做，基本不会卡）

- [ ] `git clone --recurse-submodules`，确认 `git submodule status` 没有前缀 `-`
- [ ] `python -m pip install scons`，`scons --version` 有输出
- [ ] 装 Godot 4.6.2，设 `GODOT_BIN`，确认 `%GODOT_BIN% --version` 是 4.6.2
- [ ] 编辑器里装 4.6.2 导出模板
- [ ] 关掉 Godot，跑 `gdext\rebuild.bat`（Windows）→ 确认 `bin\windows\` 有时间戳是今天的 dll
- [ ] 打开 Godot 跑一次游戏，确认 C++ 路径生效（控制台会出现 `[native_generation/base] path=gdext`）
- [ ] 要 Web：装 emsdk 4.0.20 到仓库根 `emsdk/`，跑 `Build-Web.cmd`
- [ ] `serve_web.bat` + `python tools\verify_web_export.py` 过一遍
- [ ] 要 Android：装 NDK，`gdext\build_android.bat`，再导 APK
