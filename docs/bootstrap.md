# 新设备一键构建

克隆这个仓库后**不能直接打开就跑**：仓库里不含任何编译产物（GDExtension 的 `.dll/.so/.wasm`、
FmodGodot 的原生库、FMOD 的 `.bank`），它们要么用本机工具链编，要么受第三方授权限制必须由你自己取。

一条命令把能编的都编出来：

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```

```bash
# macOS / Linux
./scripts/setup.sh
```

脚本按依赖顺序跑六个阶段，每步失败都给出可执行的下一步，而不是抛堆栈。**幂等**：重复跑不报错，
已有的产物会跳过并标注 `skip`。

---

## 前置依赖

| 依赖 | 用在哪 | 怎么装 |
|---|---|---|
| Git | 拉子模块 | [git-scm.com](https://git-scm.com/downloads) |
| Python 3.10+ | 构建脚本、工具链 | [python.org](https://www.python.org/downloads/)（Windows 安装时勾 *Add to PATH*） |
| SCons | 编译 GDExtension | `python -m pip install --user scons` |
| Godot 4.6.x | 导出 Web/Android、跑 headless；**编 dots_ext 不需要** | 解压后在当前终端设 `GODOT_BIN` |
| Emscripten **4.0.20** | 只有 Web 目标需要 | 见下方「Emscripten 版本为什么必须是 4.0.20」 |
| Android SDK + NDK | 只有 Android 目标需要 | Android Studio 勾 *NDK (Side by side)*，设 `ANDROID_HOME` |
| FMOD Engine（HTML5） | 只有 Web 的 FMOD 需要，**带授权，仓库不带** | [fmod.com/download](https://www.fmod.com/download) |
| FMOD Studio | 只有生成 `.bank` 需要，**带授权** | 同上，注意是 Studio 不是 Engine |

环境变量（都在当前终端里设，不要写进仓库）：

```powershell
$env:GODOT_BIN = "<Godot 解压目录>\Godot_v4.6.2-stable_win64_console.exe"
$env:ANDROID_HOME = "<Android\Sdk>"
$env:FMOD_SDK = "<仓库上级>\sdk\fmod\html5-20400"
```

```bash
export GODOT_BIN="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export FMOD_SDK="$(cd .. && pwd)/sdk/fmod/html5-20400"
```

---

## 六个阶段

### 1. 前置检查

检查 git / python / scons / Godot / emcc / FMOD SDK，缺什么当场报，并给出安装方式。
这里**不会**因为缺 Godot 就中止 —— 编 dots_ext 用不到它。

### 2. 子模块

```bash
git submodule update --init --recursive
```

`gdext/godot-cpp` 是 submodule。不 init 的话下一步 scons 会在 `SConscript("../godot-cpp/SConstruct")`
处直接失败。脚本会先看 `gdext/godot-cpp/SConstruct` 在不在，在就跳过。

如果你拿到的是压缩包而不是 git 克隆，这一步没法自动做，脚本会明确报出来让你手工补。

### 3. dots_ext GDExtension

在 `gdext/` 下编译：

| 平台 | 命令 |
|---|---|
| Windows | `scons platform=windows target=template_debug dev_build=no` |
| macOS | `scons platform=macos target=template_debug dev_build=no` |
| Linux | `scons platform=linux target=template_debug dev_build=no` |
| Android | `gdext/build_android.bat release`（SDK/NDK 由它自己解析 `ANDROID_HOME`） |
| Web | `gdext/build_web.bat`（需要 emcc 在 PATH 上） |

产物落在 `Project/project-keynes/addons/dots_ext/bin/<平台>/`。

Windows 上建议用 **VS 2022 x64 Native Tools** 命令提示符跑；编译前关掉 Godot 编辑器，
否则已加载的 `.dll` 被锁住会导致链接失败。

### 4. FMOD 插件链

这一层受授权限制，分三种情况：

| 目标 | 来源 | 脚本做什么 |
|---|---|---|
| Web | **从源码编**：`gdext/fmod_godot`，链接 FMOD HTML5 SDK 的静态库 | 找 `$FMOD_SDK` → 找不到就告诉你去哪下、放哪，**不替你下载** |
| Android | **从源码编**：`gdext/fmod_bootstrap`，只依赖 NDK | 需要 `ANDROID_HOME`；产物目录由 SConstruct 决定（见下方注意事项） |
| Windows / Android 的 FmodGodot 原生库 | **上游预编译件**（`FMOD-GODOT` v1.1.3） | 只检测在不在；不在就提示把它放到 `addons/FmodGodot/bin/<平台>/` |

缺 FMOD 的共同后果：**画面和逻辑正常，只是没有声音。**

### 5. FMOD banks

`scripts/Build-FMOD-Banks.cmd` 从 `Audio/ProjectKeynes/ProjectKeynes.fspro` 生成 `.bank`。

- 需要本机装 **FMOD Studio**（不是 Engine）
- 已有 `.bank` 会跳过（要重出请先删掉）
- `-SkipBanks` / `--skip-banks` 可以跳过
- **mac/Linux 不支持**：这条链是 Windows 的 PowerShell + FMOD Studio GUI，脚本会明确报「不支持」

### 6. AI skill 与自检

`python tools/sync_skills.py link` 把 36 个 skill 的真源（根目录 `skills/`）链到 7 个 AI 工具目录，
然后逐项报告产物是否齐全：`dots_ext`、`FmodGodot` 原生库、`fmod_bootstrap`、`.bank`、Godot 可执行。

---

## 开关

`scripts/setup.ps1`：

| 参数 | 作用 |
|---|---|
| `-Platform windows\|android\|web\|all` | 默认 `windows`；`all` = 三个都编 |
| `-SkipBanks` | 跳过 bank 生成 |
| `-SkipSkills` | 跳过 skill 链接 |
| `-GodotBin <路径>` | 覆盖 `GODOT_BIN` |
| `-FmodSdk <路径>` | 覆盖 `FMOD_SDK` |
| `-Jobs N` | scons 并行度，默认 CPU 核数 |

`scripts/setup.sh` 用同名长参数：`--platform / --skip-banks / --skip-skills / --godot-bin / --fmod-sdk / --jobs`。

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `SConscript("../godot-cpp/SConstruct")` 报找不到文件 | 子模块没 init | `git submodule update --init --recursive` |
| 链接阶段报 `.dll` 被占用 | Godot 编辑器开着 | 关掉编辑器重编 |
| Web side module 加载时报 `failed to load dynamic library` | Emscripten 版本不是 4.0.20 | 见下节 |
| `missing FMOD HTML5 archive: ...` | `fmod_sdk` 路径不对或缺 SDK | 设 `FMOD_SDK` 指向含 `api/studio/lib` 的目录 |
| 游戏能跑但没声音 | `.bank` 没生成，或 `FmodGodot` 原生库缺失 | 装 FMOD Studio 重出 bank；补齐第 4 阶段 |
| Android 构建找不到 NDK | `ANDROID_HOME` 未设或 NDK 未装 | Android Studio 装 *NDK (Side by side)* |

### Emscripten 版本为什么必须是 4.0.20

官方 Godot 4.6 的 web 导出模板就是用 4.0.20 编的。用别的版本编出的 side module 在浏览器里
通常只报一句 `failed to load dynamic library`，看不出真正原因。

```bash
git clone https://github.com/emscripten-core/emsdk
cd emsdk
./emsdk install 4.0.20 && ./emsdk activate 4.0.20
source ./emsdk_env.sh          # Windows: emsdk_env.bat
```

---

## 已知缺口（不是脚本 bug）

1. **Windows/Android 的 FmodGodot 原生库**：上游 `FMOD-GODOT` 只发 Windows/Android 预编译件，
   本仓库不能带（FMOD 授权）。要声音就手工从上游取一次。
2. **`gdext/fmod_bootstrap/SConstruct` 的输出目录**是
   `Project/project-keynes/addons/fmod_android_bootstrap/bin/android`，而 addon 目录叫
   `0_fmod_bootstrap`。编完如果声音链没生效，先确认这两个名字是否被合并过。
3. **mac/Linux 不支持 banks**，也没有 FmodGodot 的非 web 原生库 —— 这两项缺了就是没有声音。
