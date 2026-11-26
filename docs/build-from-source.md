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
| Web 全流程（推荐） | `scripts/Build-Web.cmd` | `WebBuild/` |
| Web 只重新导出 | `scripts/Build-Web.cmd skip-native` | `WebBuild/` |
| 本地预览 WebBuild | `scripts/serve_web.bat` | `http://127.0.0.1:8060/ProjectKeynes.html` |
| Windows PC 导出（推荐） | `scripts/Build-Windows.cmd`（`debug` / `release` / `skip-native`） | `Build/ProjectKeynes-{debug,release}/` |

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

## 3. 原生扩展 `dots_ext`（更新后先重新编译）

正式项目（`Project/project-keynes`）的 macOS `dots_ext` dylib 由本地构建，Git 会忽略它们。首次检出或更新 C++ 源码后，
运行 `gdext/rebuild.sh` 生成 debug/release 两份库，再完全重启 Godot。仓库中其他平台
的二进制也可能落后于源码。`SConstruct` 默认启用
`disable_exceptions=no`，因为当前原生模拟需要捕获 C++ 异常；关闭会编译失败。

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

命名规则：Windows 默认 basename 从 `dots_ext.gdextension` 对应映射读取
（当前为 `dots_ext_state_snap_v1`），其它平台是 `dots_ext`，
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

`scripts/Build-Web.cmd` 假定 emsdk 在**仓库根目录的 `emsdk/`**（该目录已被 `.gitignore` 忽略）。

### 4.2 三个必须记住的编译约束

| 约束 | 取值 | 不遵守的后果 |
| --- | --- | --- |
| `threads` | `yes`（对齐预设 `variant/thread_support=true`） | 原生 host 的 `std::thread` worker 不推进，页面卡在「进入世界」98% |
| `disable_exceptions` | `no` | `economy_*.h` 等 11 个文件用 `throw` 报不变量错误，编译直接失败 |
| `lto` | `none` | 用默认 `full` 时每次链接要等很久，联调期不划算 |

对应的编译命令（`scripts/Build-Web.cmd` 内部就是这条）：

```bat
scons platform=web arch=wasm32 threads=yes lto=none disable_exceptions=no -j16 target=template_release dev_build=no
```

### 4.3 一键导出

```bat
scripts/Build-Web.cmd              :: release：编 native → 预烘目录 → 导出 release 包
scripts/Build-Web.cmd debug        :: 同上，debug 变体
scripts/Build-Web.cmd both         :: 两套都做
scripts/Build-Web.cmd skip-native  :: 不重编 wasm，只预烘 + 重新导出（改 GDScript 后最快的选项）
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

### 4.5 线程版与无线程兼容版

正式 Web 导出用 `threads=yes` 和 `variant/thread_support=true`，默认后台模拟。
无线程构建使用同步兼容执行器。历史加载卡顿与当前验证范围见 [Web 导出](web-export.md)。

### 4.6 本地预览与验证

```bat
scripts/serve_web.bat            :: 默认 8060 端口，会自己开浏览器
scripts/serve_web.bat 8080       :: 换端口
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

推荐使用仓库自带的一键脚本（依次完成 `dots_ext` 原生库编译、FMOD 音频资产检查、`--import`、`Windows Desktop` 导出以及无参启动冒烟校验）：

```bat
scripts\Build-Windows.cmd                 :: 编 template_debug + 导 Build\ProjectKeynes-debug\
scripts\Build-Windows.cmd release         :: 编 template_release + 导 Build\ProjectKeynes-release\
scripts\Build-Windows.cmd skip-native     :: 跳过 C++ 重编，直接导 debug 包
```

也可手动在编辑器里「项目 → 导出」或命令行调用：

```bat
"%GODOT_BIN%" --headless --path Project\project-keynes --export-debug   "Windows Desktop" Build\ProjectKeynes-debug\ProjectKeynes-debug.exe
"%GODOT_BIN%" --headless --path Project\project-keynes --export-release "Windows Desktop" Build\ProjectKeynes-release\ProjectKeynes.exe
```

注意事项：
- **声音资产**：公开仓库不含 FMOD 原生 DLL（`addons/FmodGodot/bin/windows/x86_64/`）和 Desktop `.bank`（`assets/audio/banks/Desktop/`），两者均已在 `.gitignore` 中忽略。若本地未补齐，`scripts/Build-Windows.cmd` 与 `addons/keynes_audio_export/plugin.gd` 会打印告警并继续导出**无声版本**；补齐方式见 `docs/bootstrap.md` §4–§5。
- **导出包文件日志**：`Project/project-keynes/project.godot` 已设置 `debug/file_logging/enable_file_logging.template=false`（仅对导出模板关闭，编辑器日志不受影响），用于规避 Godot 4.6.2 官方 Windows 导出模板在启动轮转 `user://logs/godot.log` 时的 `signal 11` 崩溃。请勿在导出模板中重新开启。

### 5.2 Android

1. 装 Android Studio → SDK Tools → **NDK (Side by side)**；脚本会自己找
   `%ANDROID_HOME%\ndk\<版本>`，也可以直接设 `ANDROID_NDK_ROOT`。
2. 编原生库：`gdext\build_android.bat`（`release` / `debug` / `both`）。
3. 编辑器里配好 keystore，用 `Android` 预设导出 `Build/ProjectKeynes.apk`；
   一键装机脚本是仓库根目录的 `scripts/build_install_android.bat`（需 adb）。
4. 只看日志：`scripts/capture_android_log.bat`。

Android 预设里的 `godot-lib.*.aar` 已经在仓库中（`android/build/libs/`），无需额外下载。

---

## 6. FMOD 音频（可选）

因 FMOD 第三方授权限制与大体积二进制不入库策略，公共仓库**不再提交** `addons/FmodGodot/bin/` 下的预编译库以及 `Project/project-keynes/assets/audio/banks/Desktop/` 下的 `.bank` 文件（已在 `.gitignore` 忽略）。缺这两项时游戏画面与逻辑完全正常，只是没有声音；补齐与已知限制见 `docs/bootstrap.md` §4–§5。

只有改了 `Audio/ProjectKeynes/ProjectKeynes.fspro` 或音源时才需要：

```bat
scripts/Build-FMOD-Banks.cmd      :: 用 tools/fmod-studio/2.03.15/fmodstudiocl.exe 重烘并同步到 banks/Desktop
scripts/Open-FMOD-Studio.cmd      :: 打开 FMOD Studio GUI
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

普通 PR 更新运行 `.github/workflows/runtime-checks.yml`（Runtime quick checks）：
只取地图作者工具、原生源码及测试，运行地图工具测试、两个独立线程检查和气候源码编译检查。
不下载游戏素材和引擎，不编译完整原生库，不启动游戏；新提交自动取消同一 PR 尚未完成的旧检查。

完整 Linux 构建、Godot 导入、默认游戏回归与真实存读档保留在
`.github/workflows/runtime-full-checks.yml`（Runtime full checks），仅手动触发。
该文件合入默认分支后，可在 Actions 中选择它并点击 Run workflow。
本地仍可构建原生库后运行 `python3 tools/ci/run_regression_checks.py --import --roundtrip`。
快速检查通过只代表上述小范围通过，不代表完整游戏或全部平台通过；完整检查失败仍需保留和处理。

`.github/workflows/web-build.yml`（手动触发 `workflow_dispatch`）：

1. checkout（含子模块）→ 装 Python + SCons；
2. 装 emsdk 4.0.20（带缓存）；
3. 下载 Godot 4.6.2 win64 编辑器 + Web 导出模板；
4. 跑 `scripts/Build-Web.cmd release`；
5. 把 `WebBuild/` 作为 **artifact** 上传；推 tag `v*` 时再附加到 Release。

下载产物：仓库页 → Actions → 选中那次运行 → 页面底部 Artifacts。

> 这个 workflow 与本地流程一一对应（就是把 `scripts/Build-Web.cmd` 搬上 runner），
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
- [ ] 要 Web：装 emsdk 4.0.20 到仓库根 `emsdk/`，跑 `scripts/Build-Web.cmd`
- [ ] `scripts/serve_web.bat` + `python tools\verify_web_export.py` 过一遍
- [ ] 要 Android：装 NDK，`gdext\build_android.bat`，再导 APK

---

## 10. Windows 单机核验（运行时故障基建 R6）

> 本节落地 `docs/plans/runtime-fault-infrastructure-plan.md` §9。目标只有一个：
> **改完运行时相关代码，用一条命令就知道自己有没有把东西弄坏**，不用再凭记忆拼
> python / scons / godot 的命令行。实跑环境：Windows 11 + Windows PowerShell 5.1 +
> Godot 4.6.2 console + Python 3.13 + SCons 4.x。

### 10.1 一条命令 `tools\ci\verify.ps1`

```bat
.\tools\ci\verify.ps1              :: 全套：static + build + suites
.\tools\ci\verify.ps1 -Quick       :: 只跑 static；改 GDScript / 文档时用这个
.\tools\ci\verify.ps1 -SkipBuild   :: 跳过 C++ 构建（扩展已编好、或只改脚本）
.\tools\ci\verify.ps1 -WithSoak    :: 追加 soak 阶段（默认不跑，10 min 量级）
.\tools\ci\verify.ps1 -Strict      :: 发布前用：known-red 也当失败
.\tools\ci\verify.ps1 -DryRun      :: 只打印将要执行的命令，一个进程都不起
```

其它参数：`-GodotExe`（不给就按 `GODOT_BIN` → `tools\runtime\Resolve-GodotBin.ps1`
里的已知安装路径 → PATH 依次解析）、`-RepoRoot`、`-Jobs 4`（传给 `scons -j`）、
`-StrictBuildId`（DLL 里找不到 `build_id` 符号从 WARN 升级为 FAIL）。

**执行策略踩坑**：本机默认策略是 `Restricted` 时，直接 `.\tools\ci\verify.ps1`
会报"在此系统上禁止运行脚本"。两种解法：

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ci\verify.ps1 -Quick
:: 或者一次性放开当前用户
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

`verify.ps1` 内部再拉起 `tools\runtime\*.ps1` 时自带 `-ExecutionPolicy Bypass`，
嵌套那一层不用另外处理。

#### 四个阶段做什么

| 阶段 | 内容 | 时长目标 |
| --- | --- | --- |
| `static` | `check_fault_taxonomy.py --strict`、`check_cpp_deps.py`、`check_size_ratchet.py`、`check_module_map.py`、`check_module_api.py`、`check_module_contracts.py`、`check_script_native_access.py`、`.gdextension` 防呆（§10.2）、`git diff --check`、`check_large_blobs.py`（§10.4） | ≤ 2 min（实测 10 项 ≈ 22 s） |
| `build` | `cd gdext` → `scons platform=windows target=template_debug -j <Jobs>`，再扫生成的 DLL 里有没有 `PK_BUILD_ID` / `pk_build_id` 及它的值 | ≤ 6 min |
| `suites` | 调 `tools\runtime\Invoke-RuntimeTests.ps1`，日志和 `test-summary.json` 落到 `tmp\verify_<ts>\runtime-tests\` | ≤ 15 min |
| `soak` | 调 `tools\runtime\Invoke-Soak.ps1`；脚本还不存在时记 `skipped` | ≤ 10 min |

- **`suites` 是串行的，别指望 4 路并行**：`Invoke-RuntimeTests.ps1` 的测试清单
  写死在文件里，也不接受子集/并发参数。"切 4 组并发"要么改那个脚本，要么在
  `verify.ps1` 里复制一份清单——两份清单一定会漂。所以当前按脚本原样串行跑，
  摘要里显式标 `suites=serial`，JSON 里也有 `suites_mode`/`suites_reason`。
  要真并行，得先给 `Invoke-RuntimeTests.ps1` 加 `-Tests`/`-Jobs` 参数。
- **`build` 阶段找不到 build_id 只算 WARN**：本地 dll 可能是 R1 之前的产物。
  发布前用 `-StrictBuildId` 让它变红。
- 构建会抢 dll 锁：**编之前把 Godot 完全关掉**（见 §3.1），否则报 `LNK1104`。
  另一个 agent/终端正在编同一个目录时，跑 `-Quick` 就够，别并发 scons。

#### 退出码，和三种"没绿"

| 退出码 | 含义 |
| --- | --- |
| `0` | 请求的检查全部通过，且**没有任何 skipped** |
| `1` | 有 check 失败；或有 skipped（skipped 不算绿）；`-Strict` 下 known-red 也算失败 |
| `2` | 环境问题：python / git / scons / godot 找不到、目录不对（什么都没验证） |

三种非绿状态在摘要里分开列，不要混着看：

| 状态 | 含义 | 影响退出码 |
| --- | --- | --- |
| `FAIL` | 真失败，红色列出，附最后 40 行输出 | 是 |
| `KNOWN-RED` | 本检查里已登记的既有基线漂移（见脚本顶部 `$knownRed` 表），**照常运行、照常打印、不隐藏** | 否；`-Strict` 下是 |
| `SKIP` | 脚本还不存在（如 R1 台账未落地、soak 未落地），黄色单列 | 是（`-Strict` 与否都一样：缺检查不能算通过） |
| `WARN` | 只提醒（如 dll 里没有 build_id） | 否 |

当前 `$knownRed` 只有两条，都是**与本基建无关的既有漂移**，改的是别人的活：

- `check_cpp_deps.py`：HEAD 上 `economy → family` 的引用已超出
  `tools/ci/cpp_deps_baseline.json`（6 条 key，`total 2175 > 2170`）。
- `check_size_ratchet.py`：21 个文件超出 `tools/ci/size_baseline.json`（含
  `scripts/ui/debug_console.gd 1736 > 1698`、`scripts/ui/icon_catalog.gd 1413 > 1406`、
  `scripts/ui/perf_recorder.gd 977 > 966`）。

**不要为了让 verify 变绿去改这两个 baseline**，也不要把它塞进 skipped；
各自的功能落地时由各自的改动收紧基线，然后从 `$knownRed` 里删掉那一行
（脚本会在该项通过时提示 `known-red entry now passes`）。

#### 报告文件

`tmp\verify_<yyyyMMdd_HHmmss>.json`，每次非 dry-run 运行都会写（红了也写）：

```text
schema / generated_utc / repo_root / godot / python
modes          -Quick / -WithSoak / -SkipBuild / -Strict / -StrictBuildId / jobs
suites_mode    "serial" + suites_reason
stages[]       name、status、elapsed_seconds、items[]
items[]        name、command、status、exit_code、elapsed_seconds、
               known_red、known_red_reason、note、failure_output(最多 40 行)
failed[] / known_red[] / skipped[]
summary         verdict、total/passed/failed/known_red/skipped/warned、elapsed_seconds
exit_code
```

`tmp\verify_*.json` 会一直堆，用 §10.5 的 `prune_tmp.ps1` 轮转。

### 10.2 `.gdextension` release 映射残留（最容易变成"假故障"的坑）

`Project/project-keynes/addons/dots_ext/dots_ext.gdextension` 的
`windows.debug.x86_64` 必须指向 `.template_debug.` 的 dll。为了复现一个 release
行为、或者用 release 库做 A/B 时把它改成 `template_release`，改完忘了改回来，
**编辑器照样能启动，但加载的是另一套 ABI/断言级别**，之后所有运行时现象都是假的
（历史现象：调试用 release 库跑集成，`build_id` 对不上、断言全被 NDEBUG 关掉）。

`verify.ps1 -Quick` 的 `gdextension-mapping` 项就是防这个：读该文件、
取 `windows.debug.x86_64` 的值，不是 `.template_debug.` 直接 FAIL（不是 WARN），
并在输出里给出恢复命令。

```bat
:: 正常状态（当前仓库就是）
windows.debug.x86_64 = "res://addons/dots_ext/bin/windows/dots_ext_country_border_fix.windows.template_debug.x86_64.dll"

:: 被留在 release 映射上时，恢复：
.\tools\runtime\Use-GdextLibrary.ps1 -Variant debug -Restore
```

改 `.gdextension` 时另有一条老规矩（§3.4）：**dll 的 basename 必须和这里的
`[libraries]` 段逐字一致**。切换变体只允许改 `template_debug` ↔ `template_release`
这一段，不要顺手换 basename，也不要 `git add` 实验产物。

会临时改这个文件的脚本有两个来源：`tools/runtime/Invoke-Soak.ps1 -Release`（soak
提速，用 `finally` 还原 debug 映射）和手工 A/B。前者正常结束会自己还原，但进程被
强杀时还原不执行——所以**任何"奇怪"的运行时结果，先跑一次 `verify.ps1 -Quick`
看 `gdextension-mapping` 那一项**，比翻日志快得多。

### 10.3 `tools/ci` 脚本的 Windows 适配清单

`tools/ci` 里现有 33 个 Python 脚本、14 个 JSON 注册表/基线，加上本轮新增的
2 个 PowerShell 脚本（`verify.ps1`、`prune_tmp.ps1`）共 49 个文件。计划文档里写的
"23 个脚本"是写作时的快照，**以本节实测为准**；下面逐个列，判断来自**实跑**，
不是看文件名猜的。
「可直接跑」= Windows 上不做任何改动就能跑完（退出码取决于各自基线状态，
不一定 0）；「需本机适配」= 现在跑会崩或根本跑不了。

**A. 可直接跑（12 个）**

| 脚本 | 说明 |
| --- | --- |
| `check_fault_taxonomy.py --strict` | R1 台账；已进 `verify.ps1` static |
| `check_cpp_deps.py` | 已补 `encoding="utf-8"`（R6 修复），否则 GBK 解码崩 |
| `check_size_ratchet.py` | 行数棘轮；当前 22 条超出基线（known-red） |
| `check_module_map.py` | `docs/architecture/module-map.md` 里的路径必须存在 |
| `check_module_api.py` | 模块 API 边界契约 |
| `check_module_contracts.py` | 已补 `encoding="utf-8"`（R6 修复） |
| `check_script_native_access.py` | GDScript 跨模块 DCWorldExt 访问棘轮 |
| `check_skill_mirrors.py` | 检查根目录的 skill 源文件及误提交的工具目录副本 |
| `check_world_ext_bindings.py` | binding 归属模块一致性 |
| `world_ext_bindings.py` | 上者的清单库；`--json/--refs` 直接可跑 |
| `inspect_incident.py` | R2 事故包检查（读 zip + JSON，不碰文本编码） |
| `check_large_blobs.py` | R6 新增大文件闸门（§10.4） |

**B. 需本机适配（15 个）** —— 三类原因：Windows 默认 GBK 编码、macOS/Linux 专属
路径或系统 API、需要本机没有的 C/C++ 编译器。

| 脚本 | 适配点 |
| --- | --- |
| `check_cross_domain_inventory.py` | GBK：`read_text()` 未指定编码 → `UnicodeDecodeError: 'gbk'` |
| `check_resolve_apply.py` | 同上 GBK |
| `check_runtime_advancers.py` | 同上 GBK |
| `check_runtime_switches.py` | 同上 GBK |
| `check_save_contracts.py` | 同上 GBK |
| `check_save_section_contracts.py` | 同上 GBK |
| `check_committed_views.py` | 同上 GBK（`run_regression_checks.py` 的守卫清单里也有它，所以那条链在 Windows 上会一起断） |
| `runtime_test_hygiene.py` | 硬编码 `/usr/bin/git`（`untracked()`）→ Windows 上找不到该路径 |
| `run_regression_checks.py` | 导入上面的 `runtime_test_hygiene`，且 `--godot` 默认是 `godot`；两处都要给 |
| `check_runtime_load_consistency.py` | `rg`（本机无）、`ps -Ao`（Unix）、`os.getloadavg()`（Windows 没有） |
| `check_mobile_runtime_consistency.py` | 导入上一个模块 |
| `test_runtime_load_consistency.py` | 断言里直接调 `os.getloadavg()` → `AttributeError` |
| `test_regression_evidence.py` | `os.symlink` 需要开发者模式/管理员 → `OSError: [WinError 1314] 客户端没有所需的特权` |
| `test_architecture_guards.py` | 需要 `clang++` 或 `g++` 编译 `gdext/tests/runtime_control_wakeup_test.cpp`；本机两者都没有 |
| `main_boundary_wakeup_fixture.py` | 同上，是 `test_architecture_guards.py` 的编译夹具，无独立 CLI |

GBK 那一批的统一修法就是显式 `encoding="utf-8"`（**不要**用
`errors="ignore"` 把问题吞掉，那会把真正的编码错误藏起来）。R6 只修了
`check_cpp_deps.py` / `check_module_contracts.py` 两个（它们在 static 链路上），
其余谁改谁补。

**C. 需 Godot 参数（5 个）** —— 都能跑，但必须把 Godot 可执行文件告诉它；
注意 Windows 上要用 **console 版**（`..._console.exe`），普通 GUI 版 headless
时 stdout 抢不到。

| 脚本 | 适配点 |
| --- | --- |
| `check_committed_replay.py` | `--godot` 必填，`--log-dir` 必填 |
| `check_replay_matrix.py` | `--godot`、`--log-dir` 都必填；`--full` 才有年度保存点 |
| `check_golden_determinism.py` | `--godot` 默认取 `GODOT_BIN`，`--log-dir` 必填 |
| `check_intent_baselines.py` | 同上，`--log-dir` 必填 |
| `check_military_continuation.py` | `--godot` + `--military-fiscal-probe`（要单独编的测试扩展） |

另外 `check_macos_runtime_extension.py` 不属于以上三类：它开头就
`sys.platform != "darwin"` 直接报错，**只能在 macOS arm64 上跑**，Windows 上跳过。

### 10.4 大文件闸门 `check_large_blobs.py`

仓库**不使用 Git LFS**（`.gitattributes` 里没有任何 `filter=lfs`，也不打算加）。
大文件一律放 GitHub Release asset 或网络盘；已经入库的历史产物在白名单里。

```bat
python tools/ci\check_large_blobs.py                     :: 查暂存区（默认 --staged）
python tools/ci\check_large_blobs.py --max-mb 3          :: 收紧到 3 MB
python tools/ci\check_large_blobs.py --path tmp\x.bin    :: 单测一个文件
```

- 只看**索引**（`git diff --cached`），也就是"这次 commit 会真的塞进仓库的东西"；
  工作区里没 `git add` 的大文件不管。
- 体积取自索引里的 blob（`git cat-file -s :<path>`）。`--numstat` 对二进制只给
  `-`，所以它只用来标注"这个文件是二进制"，不用来算大小。
- 白名单：`tools/ci/large_blobs_allowlist.json`，结构
  `{"allow": [{"path": "...", "max_mb": 300, "why": "..."}]}`，`path` 支持
  `fnmatch` 通配，`why` 必填（白名单是给评审看的理由，不是静音开关）。
- 超标输出会写清路径、体积、超了多少、替代方案，以及"本项目不使用 LFS"。
- 退出码：`0` 通过 / `1` 有超标（含 git 不可用等异常，闸门 fail-closed）。

`verify.ps1` 的 static 阶段已经跑它，所以一次 commit 里混进 6 MB 文件会在
`verify.ps1 -Quick` 直接红。

### 10.5 tmp 产物轮转 `prune_tmp.ps1`

`tmp/` 下的运行时产物（全量快照、事故包、replay 日志、verify 报告）会无限增长：
本机实测 `tmp/runtime_snapshots_*` 有 **131 份、约 1.07 GB**，最新 20 份之外基本
都是历史失败现场。

```bat
.\tools\ci\prune_tmp.ps1 -DryRun                     :: 先看要删什么（推荐：永远先 dry-run）
.\tools\ci\prune_tmp.ps1                             :: 默认保留最新 20 份 + 最近 30 天
.\tools\ci\prune_tmp.ps1 -KeepIncidents 5 -KeepDays 7
```

| 对象 | 规则 |
| --- | --- |
| `tmp/runtime_snapshots_*` | 目录名里的时间戳（解析不到就用 mtime）排序，**保留最新 `-KeepIncidents` 份且最近 `-KeepDays` 天**；超出数量窗口或超出时间窗口之一即删 |
| `tmp/incidents/*.pkinc` | 保留最近 `-KeepIncidents` 个 |
| `tmp/save_replay_*.log`、`tmp/verify_*.json` | 按 `-KeepDays` 删旧的 |

`-DryRun` 打印每条要删的路径 + 单条体积 + 合计，一个字节都不动；非 dry-run 才真删。
脚本只碰 `tmp/`，退出码恒为 `0`（它是维护步骤，不是闸门），所以没有挂进
`verify.ps1` 尾部——**要不要删快照是你的决定，不该由一条核验命令替你做**。

按默认参数实测：131 份快照里保留 20 份、列出 111 份待删、合计约 974 MB
（`tmp/runtime_snapshots_*` 的旧现场都是全量快照，单份 9–29 MB）。
