---
name: keynes-packaging
description: Project.Keynes（凯恩斯）PC / Android / Web 三平台出包与验收流程。给出包前的前置硬门、每平台必过判据、报告模板与事故档案。做 Windows debug/release 导出、Android APK 构建与装机、Web 导出与 pages 部署，或排查"包能启动但效果不对/没声音/线上不是这一版"时使用。
---

# 凯恩斯出包（PC / Android / Web）

把本仓库变成三个能交付的包，并**证明它们真的能用**。

- 仓库：`D:\Godot\ProjectKeynes\Project.Keynes`（主线工作树，`master`）
- 第二工作树：`D:\Godot\ProjectKeynes\pk-latest`（常挂在别的分支上，工作区脏）
- Godot 工程：`<仓库>\Project\project-keynes`
- 引擎：Godot 4.6.2-stable
- 预设（`export_presets.cfg`）：`[preset.0]` Windows Desktop、`[preset.1]` Android、`[preset.2]` Web、`[preset.3]` iOS

**不负责**：改玩法/渲染代码、做 git 提交、决定要不要发版。

---

## 零、五条铁律

1. **同一棵树同时只许一个构建。** 构建之间会互相踩产物。开包前先数进程（scons / gradle / godot --export）。
2. **`scons.exe` 是 shim，会立刻返回。** 它返回不代表编译结束。判据是 python 子进程还在不在，或产物 DLL 的时间戳有没有变新。
3. **`-j20` 要空闲内存 ≥ 60 GiB**，不到就降 `-j`。本机 127.6 GiB 物理内存，常只剩 16 GiB。
4. **同一个 gradle 工程同时只许一个构建。** 并发会静默产出残次 pck（不报错，只是包小了、缺东西）。
5. **出包的人不判定"能用"。** 能装、能启动、有声、线上 200 —— 这些要各自用设备/网络实测，不能靠"脚本 exit 0"。

---

## 一、第 0 步：前置硬门（四个全过才准开包）

### 0.1 现场门

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'scons|python|godot|java|gradle' } |
  Select-Object Id,ProcessName,StartTime
```

- 有别的构建在跑 → **停**，问清楚是谁的、什么时候完。
- 看 `git -C <仓库> status --porcelain` 的条数，以及**谁正在改哪批文件**。这棵树常被多个会话共用（渲染 / 税表 / 网包各改各的），改动重叠会互相覆盖。
- **在做长时间真机测试的期间，不许出包装机、不许跑 gradle。**

### 0.2 导入门（改过 `.glsl` 就必须过，这是最容易静默失败的一关）

`.glsl` 在 Godot 里是被导入成 SPIR-V 的 `.res`。**只改源文件、不重导入，pck 里打进去的是旧 SPIR-V —— 不报错，但效果全丢**（表现为"大部分山地没阴影"这种鬼故事）。

```powershell
# 1) 重导入（改过 shader 后必做）
Godot_v4.6.2-stable_win64.exe --headless --path <工程> --import   # 必须 exit 0

# 2) 判据：导入件的 mtime 必须晚于源文件
Get-ChildItem <工程>\.godot\imported\*.glsl-*.res | Select-Object Name,Length,LastWriteTime
Get-ChildItem <工程>\shaders\compute\*.glsl        | Select-Object Name,Length,LastWriteTime
```

**附加判据**：`.res` 的字节数应该变化（例：`visual_tile_horizon_trace.glsl` 加 push constant 后 28,899 → 29,147，+248 B）。**字节数没变 + mtime 没前进 = 导入没跑成**，不许开包。

### 0.3 preset 门

`export_presets.cfg` 是多人共用的文件，经常有人在做未提交的改动（Web 的 DPI 策略、console 转发垫片、FMOD 注册）。

```
规则：导出前【快照当前文件】（字节数 + sha256 + mtime）→ 导出 → 还原到【这份快照】
禁止：还原到任何"基线 sha"。按基线还原 = 删掉别人未提交的活。
禁止：用"sha 不等于某个值"来判定"上一轮没自还原"。
```

### 0.4 身份门（报告里必须写，写错等于报告作废）

```
HEAD       <sha>  <分支>
脏度       git status --porcelain 共 N 条
基线说明   基于 <HEAD> + 当时工作区未提交改动导出，不是干净树
```

**不许写"基于干净提交"**，除非 `git status` 真的为空。

---

## 二、PC（Windows Desktop）

### 出包

```powershell
scripts\Build-Windows.cmd                 # 编 native debug + 导出（= tools\build_windows.ps1 -Mode debug）
scripts\Build-Windows.cmd release
scripts\Build-Windows.cmd skip-native     # 复用现有 DLL，只导出

tools\pack.ps1 -Targets windows -Mode debug   # 统一打包器，带 build_info.json / zip / sha256
```

产物：`<仓库>\_builds\pc-debug-<yyyyMMdd-HHmm>\ProjectKeynes-debug.exe`

### 必过判据

| 项 | 判据 |
|---|---|
| FMOD 运行时 | 包内 **7 个 DLL**：`fmod`、`fmodL`、`fmodstudio`、`fmodstudioL`、`libFmodGodot.editor`、`libFmodGodot.template_debug`、`libFmodGodot.template_release` |
| 音频数据 | Desktop banks **8 条**全部 savepack 进包 |
| 导出日志 | `export_err.log` 只允许 loading-catalog 快照过期一类 warning；**出现 audio / 缺件 警告就是废包** |
| 启动 | `run_out.log` 有 banner，`run_err.log` 为 0 行，exit 0 |

**注意**：headless 跑出来的 `[audio] backend=none status=headless_disabled` 是**门禁噪声，不能拿来断言"有声"**。PC 有声必须非 headless 启动、或真机听音。

---

## 三、Android

### 出包

```powershell
scripts\build_install_android.bat    # 编 GDExtension → 导出 APK → 装机 → 抓 logcat
```

预设 `Android`，包名 `com.projectkeynes.game`。

### 必过判据

| 项 | 判据 |
|---|---|
| debuggable | manifest 里有 `application-debuggable` |
| 签名 | v2 + v3 都要有；证书 `CN=Android Debug` |
| 原生库 | 包内 so 含 `libFmodGodot.template_debug.so`、`libfmodL.so`、`libfmodstudioL.so` |
| 音频数据 | banks 全部进 pck（约 26 MB） |
| Java 侧 | `android\build\src\main\java\org\fmod\` 下 `AudioDevice.java`、`FMOD.java`、`MediaCodec.java` 必须都在树里 |
| 装机 | `adb install -r`，然后 **`lastUpdateTime` 必须变了** |
| 出声 | logcat 有 `[audio] backend=fmod platform=Android banks=4 status=ready`、`[audio] fmod jni prime=0 ok`、`FmodStub: AudioTrack started rate=48000 channels=2` |

**装机判据是 `lastUpdateTime`，不是"命令没报错"**：

```powershell
adb shell dumpsys package com.projectkeynes.game | Select-String 'lastUpdateTime|codePath'
adb shell pm path com.projectkeynes.game
```

装之前记一次 `lastUpdateTime`，装完再记一次；**数字没变就是没装上**（出过"以为覆盖了、其实还是旧包"的误判）。

**`jni prime -8` 的含义**：Java 侧 `org.fmod` 类找不到或版本对不上，结果是**没声音但不一定崩**。补了 java 类还报 -8，说明还有别的环境没对齐，不要当成"已修好"。

---

## 四、Web

### 出包

```powershell
scripts\Build-Web.cmd    # 串完：side module → loading catalog 预烘焙 → 字体子集 → 导出
```

脚本内部顺序**不能拆**，拆了就有静默坑：

1. **编 dots_ext wasm32 side module**：`threads=yes`（**必须匹配 preset 的 `thread_support=true`**，否则 pthread ABI 不同、模块加载失败、浏览器卡在"进入世界"98%）；`disable_exceptions=no`（原生运行时的经济不变量校验用 C++ 异常）。
2. **loading catalog 预烘焙**：必须独立 headless 进程，不能在导出钩子里跑（编辑进程里 GDScript 被禁用，脚本资源读回 null，会烘出坏快照）。**预烘焙失败必须中止导出**。
3. **CJK 字体子集化**：`.fontdata` 是 pck 里的大头（约 57 MB）。
4. 导出。

环境要点：

- **FMOD SDK 用 `html5-20315`**。2.04.00 的 HTML5 SDK 编不过。
- **godot-cpp 位宽按 arch 走**：web 用独立的 32 位份（`godot-cpp-web`），桌面/安卓用 64 位共享份。
- `FmodGodot` 的 web side module 不在库里，必须本机现编。
- **Web 侧 debug 包不加载 FMOD 是正常的**（登记缺 debug 变体），不要当缺陷查。

### 部署

```powershell
# 0) 先抓【线上现状】：pck 长度 + 下载回来算 sha256。线上可能已经被人改过。
# 1) 造回滚件并三层验证（7z t / 条目数 / 抽出 pck 复算 sha256）
# 2) 预演
python D:\Godot\ProjectKeynes\_local_deploy\deploy_pages.py --root <导出目录> --cname <站点> --dry-run
# 3) 上线
python ...\deploy_pages.py --root <导出目录> --cname <站点>
python ...\deploy_pages.py --cname <站点> --zip tmp\<站点>.zip --skip-zip   # 复用已打好的 zip
```

参数：`--root` `--cname` `--zip` `--skip-zip` `--level` `--visibility` `--dry-run` `--no-verify`。

### 必过判据（全部从线上实测，不看脚本自报）

| 项 | 判据 |
|---|---|
| 文件集 | `N/N 个文件 200 且字节一致` |
| pck | **下载回来**算 sha256，与本地逐字节相同 |
| html | `/`、`/index.html`、`/ProjectKeynes.html` 三个 URL 都要对 |
| Service Worker | `CACHE_VERSION` 已换新（老客户端要拉全量） |
| 缓存 | 加 `?cb=<随机>` 再请求一遍，结果必须相同 |
| 音频数据 | bank 必须都在线上（只验主包会漏，玩到有年代音乐才炸） |

**部署前必须已经有一份验证过的回滚件**，否则不许上线。回滚件三层验证：`7z t` 通过、条目数对得上源目录、抽出 pck 复算 sha256 一致。

**部署前先抓线上现状**：线上可能已经被别人改过（出现过人工回滚），脚本自以为的"线上版本"不可信。

---

## 五、验收

| 平台 | 最低验收 |
|---|---|
| PC | 非 headless 启动到主菜单；7 DLL + 8 bank 在包内；`export_err.log` 干净 |
| Android | 装上新包（`lastUpdateTime` 变了）；进世界；`backend=fmod status=ready`；真听有声 |
| Web | 线上能打开；pck/html 长度与 sha 对得上；扩展加载无报错；四个时代 bank 都在 |

---

## 六、报告模板（照抄，不许省字段）

```
包基线：<HEAD sha>（<分支>），工作区 N 条未提交改动，不是干净树
产物：<绝对路径>   <字节数>   <sha256>
必需件：<DLL/so/bank 的条数与字节数>
日志：export_err.log <行数与内容摘要>
验收：<每一项实测值>
回滚：<回滚件路径 + 字节数 + sha256>
未验项：<明确写出没验的，不要留空>
```

---

## 七、事故档案（每一条都是真发生过的）

| 症状 | 真因 | 防线 |
|---|---|---|
| 画面大面积没阴影，不报错 | `.glsl` 改了没重导入，pck 里是旧 SPIR-V | 0.2 导入门：mtime + `.res` 字节数双判据 |
| 按"基线"还原预设，别人的改动蒸发了 | `export_presets.cfg` 是多人共用文件 | 0.3：快照-还原，禁止基线比对 |
| 包能用但 pck 偏小 / 缺东西 | 两个 gradle 构建并发，产出残次 pck | 铁律 4：一次一个 |
| 以为编译完了，其实还在编 | `scons.exe` 是 shim，立刻返回 | 铁律 2：看 python 子进程 / 产物时间戳 |
| 以为装了新包，其实还是旧包 | `adb install` 没落地 | 用 `lastUpdateTime` 判据 |
| 安卓包没声音，只报 `jni prime -8` | Java 侧 `org.fmod` 缺失或版本不一致 | 核 `android/build/.../org/fmod/` 三个 java + so 版本 |
| 源码被缩小了却打印"已还原" | 某个降级脚本谎报还原 | 用 `git show HEAD:<path>` 写回原始字节 + `git hash-object` 逐个比对，不信脚本自报 |
| 线上包被换回旧版 | 有人绕过流程直接推同一站点 | 部署前抓线上现状；每次部署前先备好回滚件 |
| headless 跑完就宣称"有声" | headless 有门禁 `status=headless_disabled` | 有声必须非 headless 或真机 |
| 长测中途结果作废 | 同一台手机被别的会话装包覆盖 | 长测期间锁设备，出包前问一句 |
| Web 卡在"进入世界"98% | side module 的 `threads=` 与 preset `thread_support` 不匹配 | 出包前核这两处一致 |

---

## 八、命令速查

```powershell
# 现场
Get-Process | Where-Object { $_.ProcessName -match 'scons|godot|java' } | Select Id,ProcessName,StartTime
git -C <仓库> status --porcelain | Measure-Object -Line
git -C <仓库> log -1 --format='%h %ci %s'

# 导入
& <godot> --headless --path <工程> --import

# 出包
scripts\Build-Windows.cmd [debug|release|skip-native]
scripts\build_install_android.bat
scripts\Build-Web.cmd
tools\pack.ps1 -Targets windows,web -Mode debug [-SkipNative] [-NoZip] [-NoFmod]

# 设备
adb install -r <apk>
adb shell dumpsys package com.projectkeynes.game | Select-String 'lastUpdateTime'
adb logcat -s godot:V        # 复现期间不要 -c 清缓冲

# 部署
python D:\Godot\ProjectKeynes\_local_deploy\deploy_pages.py --root <dir> --cname <站点> [--dry-run] [--skip-zip]
```

---

## 九、一句话总结

**出包 90% 的时间花在"证明它不是假货"上。** 脚本 exit 0、文件存在、大小差不多 —— 这三样都不能证明包能用。要么量 mtime 和字节数，要么下载回来复算 sha256，要么把设备打开听声音。
