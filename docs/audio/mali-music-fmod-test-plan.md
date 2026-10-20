# 马里文明音乐接入 FMOD 测试方案

日期：2026-10-20
素材源：`E:\CloudMusic\电台节目`
范围：**只用一个文明（马里）**，只做探索类音乐
工作目录：`tmp/fmod_mali_test/`（**全部在仓库外**，不污染 git）

---

## 一、范围说明

两件事先定清楚：

**1. 只用一个文明。** 素材里 12 个文明都有完整的 4 时代探索曲，但测试不需要铺开 ——
一个文明的四个时代就足够验证"时代切换 + 同代轮播"这条主链路。
多文明只会把 bank 撑大，测不出新东西。

**2. 只要探索。** 作战整类移除（原本占 20% 体积却是另一条独立测试线）。
保留探索、探索态时代升级、胜利 stinger。

> 顺带纠正一个容易有的误会：素材是按 `文明-时代-用途` 命名的，
> 每首探索本身是**该文明该时代的合辑**，不是"多文明混在一起"。
> 一个文明 = 四首文件。

---

## 二、马里素材现状

### 四首探索，全部可切

| 时代 | 时长 | 静音缝 | 可用段落 | 选中 3 段 |
|---|---:|---:|---:|---|
| 黑暗 | 1675 s | 22 + | 22 | 285.0 / 81.2 / 139.9 s |
| 封建 | 1173 s | 42 | 11 | 248.1 / 288.7 / 91.4 s |
| 城堡 | 979.5 s | 9 | 6 | 443.7 / 245.7 / 103.7 s |
| 帝王 | 981.8 s | 6 | 5 | 531.5 / 99.9 / 234.5 s |

用 `silencedetect -45dB/0.8s` 扫描，**四个时代全部能干净切开**，
切成 12 段共 **46.6 分钟**。

> 对比：中国文明的帝王探索切不开（首段 872 s 连续混音、无缝隙），
> 马里这首有 6 处缝隙，反而更适合做轮播。

### 为什么用切片而不是整曲

探索素材本来是 16–28 分钟的合辑，游戏里"探索音乐"的实际形态就是
**一组短曲随机轮换**，整首播 28 分钟不现实。切片才是它的正确用法，
顺带把 bank 从 53 MB 压到 34 MB。

---

## 三、事件树（已建并构建成功）

```
Music/
  Era/
    Explore/   explore_dark_01..03      285.1 / 81.2 / 139.9 s
               explore_feudal_01..03    248.1 / 288.8 / 91.5 s
               explore_castle_01..03    443.8 / 245.7 / 103.8 s
               explore_imperial_01..03  531.6 / 99.9 / 234.5 s
  Transition/  trans_explore_{feudal,castle,imperial}   23.1 / 19.0 / 19.2 s
  Stinger/     sting_{dark,feudal,castle,imperial}       7.7 / 7.4 / 7.6 / 6.9 s
```

**19 个事件，48.1 分钟**，全部建在 `tmp/fmod_mali_test/project/`。

- `-diagnostic` 通过、`-build` 通过
- `Music.bank` = **33.67 MB**，FSB5 `numSamples = 22`（原 3 + 新增 19，全部真正入库）
- 探索 12 段 `loop=true`，过渡与 stinger `loop=false`

---

## 四、FMOD CLI 脚本的三个静默失败（复用价值最高）

用 `fmodstudiocl.exe -script` 自动建事件树时，有三个**不报错**的坑。
每一个都会让 build "成功"但结果是空的。

### 坑 1：`addSound` 第一个参数必须是 Parameter，不是 masterTrack

```js
// 错：返回了 SingleSound 对象，看起来成功，但 parameter 关系是坏的
track.addSound(ev.masterTrack, "SingleSound", 0, len);

// 对：
track.addSound(ev.timeline, "SingleSound", 0, len);
```

传错时日志里只飘一句
`Relationship 'parameter' expects a destination of entity type 'Parameter'`，
但 **`addSound` 照样返回非空对象**，`snd.audioFile = af` 也能成功赋值。
结果是事件里有个"悬空"的 sound，build 时被静默跳过。

### 坑 2：新建事件默认不挂 bank，build 会直接无视

```js
ev.relationships.banks.add(studio.project.lookup("bank:/Music"));
```

不挂的话：`Master.strings.bank` 里没有事件路径，`Music.bank` 里没有音频，
build 依然报 `Build completed successfully`。
**唯一判据是 `Music.bank` 的体积有没有变。**

### 坑 3：`isStreaming = true` 写进 XML 也不生效

`audioFile.isStreaming` 可写、XML 里也确确实实写了
`<property name="isStreaming"><value>true</value></property>`，
但 build 后 19 个音频**全部嵌进 bank**。

判断依据：

- Build 目录里**没有 `.fsb` 文件**（streaming 素材本该输出成外部 fsb）
- `Music.bank` 的 FSB5 样本数 = 22，体积随时长线性变化
- 把 `isStreaming` 在 true/false 之间切换，bank 体积**零差别**

也就是说 `-build` 命令行模式不采纳 per-asset 的 streaming 设置。
想真正拿到"bank 只剩几 KB + 外部流文件"，得在 Studio GUI 里 build 验证。

---

## 五、体积：33.67 MB，构成如下

| 组 | 时长 | 折算体积 |
|---|---:|---:|
| 探索 12 段 | 2793 s | ~32.4 MB |
| 大厅替代/转场 3 个 | 61 s | ~0.7 MB |
| 胜利 4 个 | 30 s | ~0.3 MB |

实测对照（同一工程只改一个变量）：

| 手段 | 体积 |
|---|---:|
| quality=37（默认） | **33.67 MB** |
| quality=25 | 约 26 MB |
| quality=0（最低） | 约 24 MB |

**降质量收益快速衰减**（37→0 只省三成），砍素材才是主杠杆。
想改质量直接改 `Metadata/EncodingSetting/*.xml` 里的 `quality` 数值即可
（这个设置没有脚本 API）。

**还能更小的唯一手段**：`explore_castle_01`（443.8 s）+ `explore_imperial_01`（531.6 s）
两首就占了 20%。如果只留短段，能到 20 MB 以内，代价是没有长曲样本。

### 一劳永逸：bank 不进 git

`Build-FmodBanks.ps1` 每次把 bank 拷到
`Project/project-keynes/assets/audio/banks/Desktop/`，而该目录是**被跟踪的**
（README 说为了"开箱即玩"）。

对一个 5.2 GB 的仓库，为这个背 34 MB 二进制不划算：

```gitignore
Project/project-keynes/assets/audio/banks/**/*.bank
```

构建脚本本来就会生成，代价只是新克隆要跑一次 `Build-FMOD-Banks.cmd`。

---

## 六、响度：三层目标 + 峰值上限

马里探索切片的响度跨度比整曲大（切片各自是合辑里的不同段落）：

| 组 | LUFS 范围 | gain 目标 |
|---|---|---:|
| 探索 12 段 | -17.32 ~ -22.70 | -20 |
| 时代升级 3 个 | -14.70 ~ -17.05 | -18 |
| 胜利 4 个 | -12.08 ~ -16.12 | -16 |

**分层而不是拉平**：stinger 本来就该比背景音乐突出 4 dB，
如果全部对齐到 -20，胜利音效会变得没有存在感。

另外每个 gain 都受**峰值上限**约束（`gain ≤ -0.3 - TP`），
避免把本来就压得紧的段落推到削顶。三首被这个上限压住了实际增益：

| 曲目 | 原 LUFS | 原 TP | 目标 gain | 实际 gain | 削顶原因 |
|---|---:|---:|---:|---:|---|
| explore_dark_03 | -22.45 | -2.40 | +2.45 | +2.10 | 动态范围小 |
| explore_imperial_03 | -22.70 | -4.86 | +2.70 | +2.70 | 余量够，未受限 |
| explore_castle_01 | -18.41 | -1.43 | +1.59 | +1.13 | 峰值高 |

结果是探索组实际落在 -20 ~ -21.5 之间，差 1.5 dB —— 听感上可以接受，
但**如果要求严格一致，就得在 FMOD 里加 limiter，而不是靠 gain**。

---

## 七、测试矩阵

| # | 验证项 | 用哪个事件 | 看什么 |
|---|---|---|---|
| 1 | 单曲 loop 有无接缝 | `explore_castle_01`（443.8 s） | 循环点听不到咔哒 |
| 2 | 8.9 分钟长曲能否播 | `explore_imperial_01`（531.6 s） | 启动延迟、内存 |
| 3 | 四时代切换是否顺 | `explore_dark_01 → feudal_01 → castle_01 → imperial_01` | 交界不突兀 |
| 4 | 同代轮播交叉淡化 | `explore_dark_01/02/03` 互相切 | 能否无感轮换 |
| 5 | 时代升级过渡 | `trans_explore_*` 插在两首之间 | 过渡接不接得住 |
| 6 | Stinger 是否打断主体 | 任意 loop + `sting_*` | 叠加而非替换 |
| 7 | 响度是否对齐 | 第六节 | 切曲音量不跳（探索组差 ≤1.5 dB） |
| 8 | bank 加载与内存 | `Music.bank` 33.67 MB | 首屏加载时间 |

---

## 八、接入 Godot（已完成）

### 新增文件

| 文件 | 作用 |
|---|---|
| `scripts/audio/music_event_catalog.gd` | 事件表（`MUSIC` / `TRANSITION` / `STINGER` / `EXPLORE_BY_ERA`），纯数据，换文明只改这一张表 |
| `tests/mali_music_demo.gd` + `.tscn` | 试听台：四时代按钮、三个过渡、四个胜利、停止、主音量 |

### 边界文件只做追加

`scripts/audio/game_audio_service.gd` 里加了三样东西，**没有改任何已有行**：

```gdscript
const MusicCatalog := preload("res://scripts/audio/music_event_catalog.gd")
var _music_key := &""            # 当前在播的 key，避免同曲重复重启
var _music_descriptions: Dictionary = {}

func play_music(key: StringName) -> bool          # 换循环音乐
func play_explore(era: StringName, pick_random := true) -> bool   # 按时代随机轮播
func play_transition(key: StringName) -> bool     # 时代升级，叠加不打断
func play_stinger(key: StringName) -> bool        # 胜利，叠加不打断
```

`play_prototype` / `set_tension` **原样保留**（只补了一行 `_music_key = &"__prototype"`），
旧调用点不会因为接入真实音乐而报错。但要注意：真实曲目没有分层，
`set_tension` 对它们**是空操作**，别指望它还有效果。

`play_transition` / `play_stinger` 用的是 `create → start → release` 的
fire-and-forget 写法（和 `play_ui` 一致），所以 stinger 会叠在音乐上而不是替换它。

### bank 已替换

`assets/audio/banks/Desktop/` 下的 4 个 bank 已换成马里的构建产物
（`Music.bank` 88 KB → 33.67 MB）。原文件备份在
`tmp/banks_backup_20261020-215229/`。

> ⚠️ 这 33.67 MB 目前是**未提交**状态。要不要进库需要你定 ——
> 见第五节末尾的 `.gitignore` 方案。

### 怎么试听

双击 `tmp/fmod_mali_test/Run-Mali-Music-Demo.cmd`，或：

```
Godot --path Project.Keynes/Project/project-keynes res://tests/mali_music_demo.tscn
```

点时代按钮会换探索曲（同代三段随机），点过渡/胜利会叠一发而不打断当前音乐。
状态栏会显示当前曲目和 `后端: ready`；如果显示 `bank_load_failed` 说明 bank 没放对位置。

### 还没接的一环

**游戏侧没有"当前时代"这个信号进音频层。** 试听台是手动点按钮，
真正接入要由时代推进逻辑调用 `play_explore(era)`，并在升级时先播 `play_transition`。

---

## 九、文件位置

| 路径 | 内容 |
|---|---|
| **`tmp/fmod_mali_test/project/`** | **终版 FMOD 工程，`Music.bank` = 33.67 MB（19 个事件）** |
| `tmp/fmod_mali_test/build_mali.js` | 建 19 个事件的脚本（坑 1、2 的正确写法都内置了） |
| `tmp/fmod_mali_test/audio/mp3/` | 马里探索 12 段切片 |
| `tmp/fmod_mali_test/audio/wav/` | 时代升级 3 个 + 胜利 4 个（48k/16bit） |
| `tmp/fmod_mali_test/picked.json` | 12 段的选取记录（源文件 / 起止点 / 时长） |
| `tmp/fmod_mali_test/mali_split.txt` | 四个时代的静音检测明细与段落列表 |
| `tmp/music_catalog/aoe4_matrix.txt` | 12 文明 × 4 时代 × 用途 覆盖矩阵（换文明时查这个） |
| `tmp/music_catalog/music_catalog.csv` | 1018 首全量分类表 |
| `tmp/fmod_mali_test/Run-Mali-Music-Demo.cmd` | 双击启动试听台 |
| `tmp/fmod_mali_test/Open-Mali-FMOD.cmd` | 双击打开 FMOD Studio（载入马里工程） |
| `tmp/banks_backup_20261020-215229/` | 替换前的原 bank 备份（88 KB） |
| `Project.Keynes/Project/project-keynes/scripts/audio/music_event_catalog.gd` | 事件表（**新增**） |
| `Project.Keynes/Project/project-keynes/tests/mali_music_demo.gd` `.tscn` | 试听台（**新增**） |

原工程 `Audio/ProjectKeynes` **没有动过** —— 它有未提交的改动
（`Click` 事件被改过、一批未跟踪的 XML 和 `Audio/Sources/`），不适合直接覆盖。

---

## 十、进度与下一步

已完成（端到端打通）：

- [x] 马里四个时代探索切片、响度分层、事件树 19 个
- [x] FMOD `-build` 通过，`Music.bank` 33.67 MB
- [x] **Studio 里核对：19 个事件全部有波形**
- [x] 事件表 + 播放接口接入 `game_audio_service.gd`（只追加，未改已有行）
- [x] bank 已放入游戏目录，已提交入库并推送（`9db1d743`）
- [x] **试听台实测出声**：四时代轮播、过渡、胜利全部正常

### 排查没声音的正确顺序

遇到点了按钮没反应，先分清是**事件没播**还是**播了但听不见**：

```gdscript
# 临时探针：PK_FMOD_TEST=1 让 headless 也初始化 FMOD
var ok = audio.play_music(&explore_dark_03)
for i in range(6):
    await get_tree().create_timer(0.5).timeout
    print(audio.diagnostics())        # 看 timeline_ms
```

- **`timeline_ms` 在增长** → 事件真的在播，问题在输出端。
  首选查 `master_muted`：`game_settings_service.gd` 默认是 false，
  但**保存下来的用户设置**可能把它置成 true，那样整个游戏所有声音都会静音。
  这个症状极具迷惑性 —— 事件、bank、事件路径全都正常，就是没声。
- **`timeline_ms` 一直是 0** → 事件没起来，回 FMOD 侧查 bank 与事件路径。

试听台状态栏现在常驻显示 `后端 / banks / 音乐 / 主音量 / 静音 / 时间轴`，
外加一个「静音主总线」开关，不用再写探针也能看出是哪一侧的问题。

> 教训：UI 里显示诊断信息时，别让某个 handler 直接覆盖整块 text。
> 上一版 `_on_stinger` 就这么干，把最该看的后端/静音行冲掉了，
> 白绕了一圈才发现是静音。

待做，按优先级：

1. **把时代信号接进音频层。** 现在试听台是手动点按钮，
   真正串起来要：时代推进时调 `play_explore(era)`、升级时先 `play_transition`。
2. **做 State/Parameter 化**：时代用 State 统一管理，同代三段用 Multi Instrument
   随机轮播（这次是用 12 个独立事件绕开了 MultiSound，它的 playlist 接口没探通）。
3. 若要换文明：改 `music_event_catalog.gd` 一张表 + 用 `build_mali.js` 改 JOBS 重建 bank。
