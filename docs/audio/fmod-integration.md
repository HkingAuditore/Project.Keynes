# FMOD 接入与验收

## 加载期间音乐连续性（2026-10-25）

主菜单退出和地图重生成不停止全局 `GameAudio` 音乐实例。场景载入、世界生成以及
生成失败后的加载画面继续播放当前音乐，世界就绪后由 `PlayerController._sync_era_music`
按玩家国家时代接管；相同石器时代组曲复用现有实例。退出应用仍由 `GameAudio._exit_tree`
释放音乐和 Bank。此行为同时覆盖新游戏与读取存档共用的场景切换路径。

`tests/audio/loading_music_continuity_test.tscn` 使用真实菜单和加载画面验证菜单移除后实例
保留、加载期间 FMOD 时间轴持续推进，以及世界就绪后石器/王国时代组曲接管。

## 当前状态（2026-10-23）

首轮 Windows 音频基础接入已实现：正式项目注册 `GameAudio` 表现层服务，加载真实
Bank，复用现有音量设置，并提供独立分层音乐试听场景。现有 UI 已接入八种 CC0
纸张与轻敲操作音，见 [UI 音效](ui-feedback.md)。Kingdom 和 Empire 已接入五声部
时代组曲（Base/Pulse/Theme/Color/Impact），并支持 Population、CameraZoom、LoopSection、
Tension、War、Ceremony 参数；Stone 和 Agrarian 保留三层兼容结构。
Kingdom/Empire 保持一套连贯的 A/B/C 主题弧线，每段 50 秒；含 Intro 的完整时长分别为
166 秒和 165 秒。更长的播放时长应通过轮换独立创作、各自闭合的套曲实现，避免把不相关的
25 秒片段拼进同一次长生成而破坏主题叙事。

- 本机引擎实测：Godot `4.6.2.stable.official.71f334935`。
- 候选插件：`marcozee03/FMOD-GODOT`，固定发行版 `v1.1.3`。
- 下载包中的 `FmodGodot.gdextension` 声明 `compatibility_minimum = 4.6`。
- Windows 包包含 editor/debug/release 插件 DLL，以及 FMOD Core/Studio 的普通、logging DLL。
- Windows `fmod.dll` 文件版本为 `2.3.15 (build 168126)`，对应产品版本 `2.03.15`。
- FMOD Studio 2.03.15 已从用户提供的签名有效安装包解包到
  `tools/fmod-studio/2.03.15/`，实际启动出现 `FMOD Studio 2.03.15` 窗口。
  已建立 `Audio/ProjectKeynes/ProjectKeynes.fspro`、Metadata 和四份自制合成音频。
- 正式项目新增 `GameAudio` Autoload、Windows 插件文件、Bank 和音频导出插件。
  `GameSettings` 原实现不变；音频服务监听其 `settings_changed` 并回读初值。

独立验证工程位于 `tmp/fmod-integration-probe-20261020/project`。导入完成后，
`probe.gd` 检查 `FmodAudioServer` 单例和四种事件/Bank 类，输出
`FMOD_PROBE_OK=true`，进程退出码为 0。

后续验证使用真实工程构建的四个 Bank：Master、Master.strings、Music、UI。
正式项目内测试和隔离 Windows Release 测试均输出 `FMOD_AUDIO_TEST_OK=true`：
事件启动、一次性音效、情绪参数写入读回、输入范围限制、Master 音量与静音、八秒循环
回绕和持久实例释放均通过。Release 从 PCK 读取 Bank，并加载随发布目录携带的 DLL。
Studio 工程完整性诊断已通过（退出码 0），包括两条分轨音量自动化曲线的参数绑定。
隔离 Web PCK 导出通过，打包清单不包含 FMOD 扩展、DLL 或 Bank；这是打包边界验证，
不代表浏览器端音频运行验收。

无活动调试器的开发运行仍输出 `Can't send message. No active debugger` 和
`Capture not registered: 'fmod'`；隔离 Release 测试没有这两条消息。
正式项目的导入/运行/导出还存在退出时的纹理、字体和资源泄漏日志，不将它们视作无错误通过。
本次完整 Windows 游戏导出另外报告既有 `economy_catalog.gd:91` 的 PackedStringArray
转换错误，经 `loading_prebake` 插件报出目录预烘焙失败，因此不宣称完整游戏发布验收完成。

本机未找到 `gda` 命令，基础验证使用现有 Godot console 可执行文件完成。

## 第一步：安装制作工具

在 [FMOD 下载页](https://www.fmod.com/download)登录个人账号，下载 Windows 版
**FMOD Studio 2.03.15**。此版本选择来自实际下载包的运行库版本，不沿用另一个
Godot 插件的 2.03.06 基线。若官网下载列表无法提供该版本，先重新确定插件与运行库组合，
不要随意替换其中一个 DLL。

账号登录由用户在官网完成，不需要将密码提供给开发脚本或聊天。
当前候选插件已包含 Windows 运行库；首轮 Windows 验证无需先下载 Engine SDK。
从源码编译或支持其他平台时，再核对所需 SDK。

### 随项目目录携带与 Git/LFS

用户选择同时携带 Studio 软件本体与音频制作工程。约定：

- `tools/fmod-studio/`：本地 Studio 安装文件或程序目录，已加入根 `.gitignore`。
  不提交到 Git，也不经过 LFS；整目录手工备份或在自己的设备间复制时应包含此目录。
- `Audio/ProjectKeynes/`：制作工程、工程元数据及自有素材。放在 Godot 资源根目录之外，
  可使用普通 Git；当前生效的 Git attributes 没有为该路径指定 LFS filter。
- 通过 `git clone/pull` 只能获得已提交的制作工程，无法获得被忽略的 Studio 本体。
  “不进入版本库”和“通过 Git 同步工具本体”不能同时实现。

### 双击启动与克隆后自动准备

仓库根目录的 `Open-FMOD-Studio.cmd` 调用 `tools/audio/Start-FmodStudio.ps1`。
默认打开 `Audio/ProjectKeynes/ProjectKeynes.fspro`；工程不存在时打开 Studio 欢迎界面。
可使用 `-ProjectPath` 指定其他 `.fspro`，`-SetupOnly` 只部署而不打开编辑器。

运行过程：

1. 优先复用本克隆 `tools/fmod-studio/2.03.15/` 中的已准备程序。
2. 尚未准备时，使用 `%LOCALAPPDATA%/ProjectKeynes/Tools/FMOD/` 中缓存的固定版本安装包。
3. 缓存不存在时，从当前用户的 `Downloads/fmodstudio20315win64-installer.exe`
   读取，或通过 `-InstallerPath` 显式指定。此步骤之后会建立本机共享缓存。
4. 校验固定 SHA-256 和 Firelight Technologies 的 Authenticode 签名，再通过
   7-Zip 解包到项目工具目录。不会执行 NSIS 安装器或注册文件关联。

已用独立目录模拟新克隆：没有本地程序时，仅依赖共享缓存即可自动解包，退出码 0。
已验证重复运行复用现有程序、错误安装包被拒绝。签名安装包 SHA-256：
`5CAE0B04DA481EEB54095F03C231A2A12BE9E46E5EC3CBAB046D5E0FEEE2AB1F`。

Windows 初次自动解包需要已安装 7-Zip；新机器没有缓存时仍须在官网取得安装包。
脚本不会代替用户登录、保存密码或将安装包上传到仓库。跨设备后的用户偏好、缓存和
系统依赖不保证随程序目录迁移。本机启动测试不代表其他 Windows 机器已完成验证。

[FMOD EULA](https://www.fmod.com/legal) 1.1 明确禁止再分发 Studio 本体，
因此不得将它作为项目公共下载或发行包的一部分；个人工具目录忽略规则不等于获得再分发许可。
FMOD 运行库随游戏分发是另一个授权范围。音频素材和 Bank 的体积仍需单独管理，
普通 Git 并不会因文件很大自动转为 LFS。

## 第二步：建立最小制作工程

建议把 Studio 源工程放在仓库顶层独立目录 `Audio/ProjectKeynes/`，位于 Godot
资源根目录 `Project/project-keynes/` 之外。该目录现已创建，`.fspro`、`Metadata/` 和
自有 `Assets/` 必须一起纳入版本管理。

第一轮只做一组音乐，验证分层能力，不先制作全部时代曲库：

1. 已建立 `event:/Music/Prototype`，使用基础氛围、旋律和鼓点三个分轨。
2. 三个分轨使用相同起点、速度、长度和循环边界，持续同步播放。
3. 添加连续参数 `Tension`，范围 0 到 1，以音量自动化控制各分轨进入和退出。
4. 建立 `event:/UI/Click` 作为一次性音效。
5. 建立 Music、SFX、Ambience 混音总线。
6. 创建 `Music`、`UI` Bank，并将事件显式分配到对应 Bank。
7. Desktop 构建输出为 `Audio/ProjectKeynes/Build/Desktop`。

双击 `Build-FMOD-Banks.cmd`，或运行 `tools/audio/Build-FmodBanks.ps1`，会使用固定版本
Studio CLI 先进行工程完整性诊断，通过后构建 Desktop Bank 并同步四个文件到
`Project/project-keynes/assets/audio/banks/Desktop/`。中间构建目录忽略，游戏侧 Bank
随项目保存，克隆后试听不需要先重新构建。测试 WAV 来源为仓库自己的合成器脚本；
不包含 FMOD 示例包的音频素材。当前事件直接路由至 Master；分类混音后续制作。

双击 `Run-FMOD-Demo.cmd` 可试听，用 Tension 滑块加入旋律/鼓点，用按钮试听 Click，
调整 Master 音量或静音。试听不保存设置。Godot 可执行文件可通过 `GDA_GODOT` 指定，
也可给 `tools/audio/Run-FmodDemo.ps1` 传 `-GodotExe`。

Studio 的分轨和过渡设计由音频内容定义。后续接时代曲库时，再约定 `Era` 参数或
独立事件映射，并核对正式国家科技时代字段；此准备阶段未新增游戏状态或推断时代编号。

## 第三步：独立验证后再接正式项目

先在现有独立验证工程中配置 Bank 目录，完成：

- 播放 Prototype 和 Click，手动从 0 到 1 调整 Tension。
- 验证循环接缝、分轨同步、参数变化速度和事件实例释放。
- 交互运行时复核 headless 调试器错误是否仍出现。
- Windows Debug、Release 导出到干净目录运行，确认 DLL 与 Bank 完整打包。

`scripts/audio/game_audio_service.gd` 已集中管理 Bank、持久音乐实例和一次性音效。
该服务属于表现层，不进入每日模拟任务，不修改 DataCore 权威。当前公开入口为
`play_prototype(tension)`、`set_tension(value)`、`play_ui_click()`、`stop_music()` 和
`diagnostics()`。普通 headless 仿真默认不加载 FMOD；音频测试设置 `PK_FMOD_TEST=1`。
`PK_FMOD_DISABLE=1` 可以显式停用音频后端。

插件目录带 `.gdignore`，避免 Godot 在不支持的平台自动加载它；Windows 由服务调用
`GDExtensionManager.load_extension`。使用动态 ClassDB 调用，脚本不硬引用原生类型，
因此 Web/Android 不依赖这些类解析。现阶段不提供 Godot 内的 FMOD 事件浏览器。
音频导出插件对 Windows 显式打包扩展描述、DLL 和 Bank；运行时通过插件的
Godot FileAccess 回调读取 PCK 内资源。未采用经验证有波形加载错误的 load_bank_memory 路线。

正式项目测试命令（已有 Godot 4.6.2 引擎时）：先设置 `PK_FMOD_TEST=1`，再以
`--headless --path Project/project-keynes res://tests/fmod_audio_smoke_test.tscn` 运行。
发布模板禁用路径覆盖，因此 Release 验收使用以该测试场景为主场景的隔离音频项目，
而不是试图向正式 Release 传 `--script` 或覆盖场景参数。

复用现有 `GameSettings.settings_changed` 和 `values()`，将已保存的
`master_volume` / `master_muted` 应用到 FMOD Master，初始化或加载 Master Bank 后
也应重新应用一次。现有 Godot AudioServer 设置继续控制 Godot 路径上的声音。

音乐参数读取已发布状态。时代变化切换曲组，局势变化更新 Tension、War、Ceremony；应有平滑、
滞回或最短保持时间，避免高速模拟和日间波动造成频繁切歌。游戏时间暂停是否影响
音乐需显式规定，首轮建议音乐和 UI 音效继续播放。

## 第四步：平台边界

- Windows 已完成音频模块的 Bank/播放/参数/混音/循环和隔离 Release 验收。
- 此插件 README 将 Android 标为未测试；现有 Android 配置需后续核对实际插件要求。
- 此发行包没有 Web 平台 library 映射，不能直接启用到现有 Web 发布链路。
  当前导出插件只对 Windows 打包 FMOD；其他平台不加载扩展，保留原生音频路径。
  尚未进行 Android/Web 上的音频功能验收，不能据此宣称已支持 FMOD。
- 不把其他 FMOD Godot 插件的类名、设置路径或 Android 构建步骤混用到此插件。

## 首轮交付标准

本轮已完成八种 UI 音效及正式 UI 接线、Kingdom/Empire 五声部素材、三类情绪参数、总音量与静音、
时代过渡、试听场景退出清理，以及 Windows 音频模块 Release 独立运行。完整游戏发布预烘焙错误仍需
另行处理。

## 来源

- [固定发行版 v1.1.3](https://github.com/marcozee03/FMOD-GODOT/releases/tag/v1.1.3)
- [该发行版 README](https://github.com/marcozee03/FMOD-GODOT/blob/v1.1.3/README.md)
- [插件文档](https://fmod-godot.readthedocs.io/)
- [FMOD 事件分配与 Bank 构建](https://www.fmod.com/docs/2.03/studio/getting-events-into-your-game.html)
- [FMOD 授权](https://www.fmod.com/licensing)
