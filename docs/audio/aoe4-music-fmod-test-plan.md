# AoE4 音乐接入 FMOD 测试方案

> **⚠️ 已被 `马里音乐FMOD测试方案.md` 取代。**
> 此文档用的是"中国"文明、四类素材全测（71.71 MB）。范围已收窄为
> **只用一个文明（马里）、只做探索**，终版工程量与数字以马里那份为准。
> 本文保留的价值在于：12 文明覆盖矩阵的论证、四类素材的完整分类、
> 以及体积对照的完整实验数据。

日期：2026-10-20
素材源：`E:\CloudMusic\电台节目`（`来孤 - 中国-*` 共 19 首）
工作目录：`tmp/fmod_aoe4_test/`（**全部在仓库外**，不污染 git）

---

## 一、为什么 AoE4 这批确实最适合测 FMOD

不是"好听"，是**结构**。这批素材自带一套完整的游戏状态机语义，是四个来源里唯一做到的：

| 素材类别 | 数量 | 中位时长 | 对应 FMOD 能力 |
|---|---:|---:|---|
| `文明-时代-作战` | 47 | 330.7 s | 长曲 loop / Streaming |
| `文明-时代-探索` | 47 | **1056.8 s** | 超长流式播放、轮播池 |
| `文明_时代升级_战斗/探索` | 76 | 19.0 s | Transition（两版**等长**，可互换） |
| `文明_时代_胜利` | 51 | 7.7 s | Stinger 叠加 |

**关键点：同一时代的「升级_战斗」和「升级_探索」时长完全相同**（18.9/18.9、18.0/18.0、20.8/20.8），
但 MD5 不同 —— 这是刻意做的**等长互换版本**，配合 FMOD 的 transition region 可以无缝切换。

文明 × 时代覆盖度（12 个文明齐全，每文明约 100 分钟）：

```
中国  主体 8/8   升级 6/8   胜利 4/4   102.2 min
奥斯曼 主体 8/8   升级 6/8   胜利 4/4   100.2 min
德裏苏丹国 / 拜占庭 / 日本 / 法兰西 / 神圣罗马帝国 / 罗斯 /
英格兰 / 马里 / 黑衣大食王朝 / 蒙古  同样 8/8
宋朝  0/8（只有 2.6 分钟，不成套）
金朝  只有升级/胜利，无主体曲
```

「升级 6/8」不是缺漏 —— 黑暗时代是最初时代，本来就没有"进入黑暗时代"的升级。

---

## 二、素材现状：两个必须先知道的事实

### 事实 1：「作战」是单曲，「探索」是合辑

用 `silencedetect`（-45 dB / 0.8 s）扫描的结果：

| 曲目 | 时长 | 静音缝 | 结论 |
|---|---:|---:|---|
| 中国-封建时代-作战 | 275.9 s | **1 处**（仅结尾） | 完整单曲，可整曲 loop |
| 中国-封建时代-探索 | 1055.3 s | 11 处 | **合辑**，由多首拼成 |
| 中国-黑暗时代-探索 | 1570.6 s | 35 处 | 合辑，可切 20 段 |
| 中国-帝王时代-探索 | 979.5 s | 3 处（首段 872 s 无缝隙） | **连续混音，切不开** |

切分结果（≥20 秒的段落）：

| 时代 | 可切段数 | 段落时长 |
|---|---:|---|
| 黑暗 | 20 | 22.4 – 138.7 s |
| 封建 | 7 | 49.8 – 263.9 s |
| 城堡 | 7 | 47.0 – 277.2 s |
| 帝王 | 3 | 872.1 / 52.8 / 46.4 s（实际不可切） |

**合计 34 段可用轮播片段**（黑暗 20 + 封建 7 + 城堡 7），已全部切好放在 `audio/mp3/explore_*_NN.mp3`。
帝王那首保留整首，正好当"26 分钟长曲流式播放"的极端测试样本。

### 事实 2：响度差 11.66 dB，而且错在最要命的地方

实测整合响度（LUFS）：

| 用途 | 黑暗 | 封建 | 城堡 | 帝王 |
|---|---:|---:|---:|---:|
| 作战 | -18.64 | -18.38 | -18.46 | -16.53 |
| 探索 | -20.29 | -21.04 | -21.64 | -17.95 |
| **升级_战斗** | — | **-12.68** | **-12.44** | **-12.50** |
| **升级_探索** | — | -21.78 | -20.46 | -20.60 |
| 胜利 | -17.12 | -13.88 | -11.87 | -12.38 |

规律很清楚，而且有一个明显的异类：

- `升级_探索`(-20.6) 和 `探索`(-21) 基本对齐 ✓
- **`升级_战斗`(-12.5) 比它要衔接的 `作战`(-18.5) 响 6 dB，比 `探索` 响 8 dB** ✗

也就是说：从探索状态升级进战斗，音量会突然涨 8 dB。这是接入后第一个会被听出来的事故。

另有 3 首 true peak 已 > 0 dBTP（最高 +0.43），源头就削顶过，别再往上推。

处理方式：**不预处理文件，在 FMOD 的 track mixerGroup 上设 gain**（可回调、不破坏源）。
脚本里已经按 -18 LUFS 目标写好了逐条 gain 值。

`hall.wav` 是特例：-31.44 LUFS，几乎听不见，gain 保持 0，需要人工判断它是不是本来就该这么轻。

---

## 三、事件树（已建好并构建成功）

```
Music/
  Era/
    Combat/     era_combat_dark / _feudal / _castle / _imperial      4 个，loop=true
    Explore/    era_explore_dark / _feudal / _castle / _imperial     4 个，loop=true
  Transition/   trans_combat_{feudal,castle,imperial}                3 个，不 loop
                trans_explore_{feudal,castle,imperial}               3 个，不 loop
  Stinger/      sting_dark / _feudal / _castle / _imperial           4 个，不 loop
  Hall/         hall                                                1 个，loop=true
```

共 **19 个事件**，全部建在 `tmp/fmod_aoe4_test/project5/`，`-diagnostic` 通过、`-build` 通过。

构建产物：`project5/Build/Desktop/Music.bank` = **71.71 MB**（22 个 sample = 原有 3 个 stem + 新增 19 个）。

> 上面是**完整覆盖**的蓝图（四类素材都测）。实际采用的范围已收窄为"只要探索"，
> 见第五节 —— 终版是 `project_explore/`（17 个事件，33.50 MB），
> 只含探索轮播 + 探索态升级 + 胜利，不含作战。

---

## 四、这次踩到的三个坑（复用价值最高）

用 `fmodstudiocl.exe -script` 自动建事件树时，有三个不会报错的静默失败。
每一个都会让 build "成功"但结果是空的，值得记下来。

### 坑 1：`addSound` 的第一个参数必须是 Parameter，不是 masterTrack

```js
// 错：返回了 SingleSound 对象，看起来成功，但 parameter 关系是坏的
track.addSound(ev.masterTrack, "SingleSound", 0, len);

// 对：
track.addSound(ev.timeline, "SingleSound", 0, len);
```

传错时日志里会飘一条
`Relationship 'parameter' expects a destination of entity type 'Parameter'`，
但 **`addSound` 照样返回一个非空对象**，后续 `snd.audioFile = af` 也能成功赋值。
结果是事件里有个"悬空"的 sound，build 时被静默跳过。

### 坑 2：新建事件默认不挂 bank，build 会直接无视

```js
ev.relationships.banks.add(studio.project.lookup("bank:/Music"));
```

不挂的话：`Master.strings.bank` 里没有事件路径，`Music.bank` 里没有音频，
build 依然报 `Build completed successfully`。
**判据：`Music.bank` 体积有没有变。**

### 坑 3：`isStreaming = true` 写进 XML 也不生效

这是最反直觉的一个。`audioFile.isStreaming` 可写、XML 里也确确实实写了
`<property name="isStreaming"><value>true</value></property>`，
但 build 后 **19 个音频全部进了 bank**（72 MB），Streaming 完全没起作用。

所以想控制体积，不能靠这个属性，得在 Studio 里对资产显式设置
Load Type，或者改 Bank 的 Encoding Setting。

---

## 五、体积优化（实测数据）

`Music.bank` 一开始是 **71.71 MB**。拆开看，问题不在压缩率，在**内容结构**：

| 组 | 时长 | 占比 | 折算体积 |
|---|---:|---:|---:|
| **探索 × 4** | 4592 s | **74.9%** | **53.7 MB** |
| 作战 × 4 | 1230 s | 20.1% | 14.4 MB |
| 大厅 × 1 | 164 s | 2.7% | 1.9 MB |
| 升级 × 6 | 115 s | 1.9% | 1.4 MB |
| 胜利 × 4 | 29 s | 0.5% | 0.3 MB |

**探索四首占了四分之三，作战只占 20%。** 这点很容易误判 ——
"砍掉作战"直觉上应该省很多，实际只省 14 MB。

### 实测对照

| 手段 | 体积 | 相对 |
|---|---:|---:|
| 默认 quality=37，全部素材 | 71.71 MB | — |
| quality 37 → 15（不删素材） | 48.14 MB | -33% |
| quality 37 → 0（不删素材） | 33.28 MB | -54% |
| 砍 3 首长探索（保留作战）+ quality 37 | 30.44 MB | -58% |
| 砍 3 首长探索（保留作战）+ quality 25 | 23.93 MB | -67% |
| **只留探索（轮播化）+ quality 37** | **33.50 MB** | **-53%** |
| **只留探索（轮播化）+ quality 25** | **26.14 MB** | **-64%** |

结论：**降质量只能到 -54%（37→0 也只省一半），砍素材才是主杠杆。**

### 最终形态：只保留探索（`project_explore/`）

需求确定后重做的版本 —— 作战整类移除，探索从「整曲」改成「轮播片段」：

| 事件 | 数量 | 来源 |
|---|---:|---|
| `explore_{dark,feudal,castle}_NN` | 9 | 每时代取**最长的 3 段**切片 |
| `explore_imperial` | 1 | 帝王探索整首（979.5 s，切不开的连续混音） |
| `trans_explore_*` | 3 | 探索态时代升级 |
| `sting_*` | 4 | 胜利 stinger |

共 **17 个事件，46.3 分钟**，`Music.bank` = **33.50 MB**（quality 37）/ **26.14 MB**（quality 25）。

```
Music/
  Era/
    Explore/   explore_dark_01..03  (138.8 / 138.6 / 123.3 s)
               explore_feudal_01..03 (263.9 / 203.3 / 168.8 s)
               explore_castle_01..03 (277.3 / 275.5 / 124.2 s)
               explore_imperial      (979.5 s)
  Transition/  trans_explore_{feudal,castle,imperial}
  Stinger/     sting_{dark,feudal,castle,imperial}
```

**为什么用轮播片段而不是整曲**：探索素材本来是 16–26 分钟的合辑，
游戏里"探索音乐"的实际形态就是一组短曲随机轮换，整首播 26 分钟不现实。
所以切片才是它的正确用法，顺带把 53.7 MB 压到 33.5 MB。

**还能再小的唯一手段**：`explore_imperial` 那首 979.5 s 一个人占 35%。
去掉它 → 约 22 MB；换成片段里的短段 → 约 24 MB。

### 为什么不能指望 Streaming（重要）

文档说 10 秒以上的资产导入时自动设为 streaming，`combat_dark.wav`（278 s）
的 `isStreaming` 确实读出来是 `true`，XML 里也写进了
`<property name="isStreaming"><value>true</value></property>`。

但 build 后 **19 个音频全部嵌进了 bank**。判断依据：

- Build 目录里**没有 `.fsb` 文件**（streaming 素材本该输出成外部 `.fsb`）
- `Music.bank` 的 FSB5 块 `numSamples = 22`（原 3 + 新 19），且体积随时长线性变化
- 把 `isStreaming` 改成 false 或 true，bank 体积**没有任何差别**

也就是说 **`-build` 命令行模式没有采纳 per-asset 的 streaming 设置**。
想真正拿到"bank 只剩几 KB + 外部流文件"，得在 Studio GUI 里做一次 build 验证，
或者查 Preferences → Build 里的加载模式默认值。

在没验证之前，**不要把 72 MB 的 bank 交给 git**。

### 一劳永逸的方案：bank 不进 git

`Build-FmodBanks.ps1` 每次都会把 bank 拷到
`Project/project-keynes/assets/audio/banks/Desktop/`，而这个目录是被跟踪的
（README 写着 "The synchronized game banks are versioned for immediate play"）。

对一个 5.2 GB 的仓库来说，为了"开箱即玩"把 24–72 MB 的二进制放进版本库，
代价远大于收益。更合理的是：

```gitignore
Project/project-keynes/assets/audio/banks/**/*.bank
```

配合构建时自动生成（脚本已经会做）。代价是新克隆要跑一次 `Build-FMOD-Banks.cmd`，
收益是仓库不再随音频素材膨胀。

---

## 六、接入 Godot 要改的地方

现有边界只有 `scripts/audio/game_audio_service.gd`（153 行），
其中 `MUSIC_EVENT` 硬编码为 `event:/Music/Prototype`。

需要做的：

1. 把单个 `MUSIC_EVENT` 换成事件表：

```gdscript
const MUSIC_EVENTS := {
    &"era_combat_dark":     "event:/Music/Era/Combat/era_combat_dark",
    &"era_combat_feudal":   "event:/Music/Era/Combat/era_combat_feudal",
    &"era_explore_dark":    "event:/Music/Era/Explore/era_explore_dark",
    &"sting_war_start":     "event:/Music/Stinger/sting_castle",
    ...
}
func play_music(key: StringName) -> bool
func play_stinger(key: StringName) -> bool
```

2. `play_prototype(tension)` / `set_tension()` 保留但降级 —— 真实曲目没有分层，
   `Tension` 参数第一轮应该是空操作，否则调用方会以为它还生效。

3. 换曲用 `StudioEventInstance.stop(fadeout)` + 新实例 start，
   过渡优先用 `Transition` 事件，而不是硬切。

4. **游戏侧目前没有"当前时代"这个信号进音频层**，要么先做手动切曲验证，
   要么顺手把时代状态接到 `game_audio_service` 上。

---

## 七、测试矩阵（按能力逐项验证）

针对 `project_explore/` 的 17 个事件：

| # | 验证项 | 用哪个事件 | 看什么 |
|---|---|---|---|
| 1 | 单曲 loop 有无接缝 | `explore_dark_01`（138.8 s） | 循环点听不到咔哒 |
| 2 | 16 分钟长曲能否播 | `explore_imperial`（979.5 s） | 启动延迟、内存占用 |
| 3 | 四时代切换是否顺 | `explore_dark_01 → feudal_01 → castle_01 → imperial` | 交界处不突兀 |
| 4 | 同代轮播交叉淡化 | `explore_dark_01/02/03` 互相切 | 是否能无感轮换 |
| 5 | 时代升级过渡 | `trans_explore_*` 插在两首之间 | 过渡是否接得住 |
| 6 | Stinger 是否打断主体 | 任意 loop + `sting_*` | 叠加而非替换 |
| 7 | 响度是否对齐 | 见下方响度表 | 切曲音量不跳 |
| 8 | bank 加载与内存 | `Music.bank` 33.5 MB | 首屏加载时间 |

### 探索版的响度关系（去掉作战后重新看）

| 组 | LUFS 范围 | 相对探索音乐 |
|---|---|---|
| 探索 | -20.29 ~ -21.64 | — |
| **升级_探索** | **-20.46 ~ -21.78** | **基本重合 ✓** |
| 胜利 stinger | -11.87 ~ -17.12 | 响 3.5 ~ 9.8 dB |

好消息：**探索态升级和探索音乐几乎完全对齐**（差 0.2 dB 以内），
所以"探索 → 升级 → 探索"这条链路天然顺，不用额外调。

要留意的是胜利音效比探索音乐响 3.5–9.8 dB。stinger 本来就该突出，
但这个跨度（同一功能 6 dB 差异）说明四首胜利是不同来源拼的，
建议在 FMOD 里再对齐一档，否则"打赢时音量忽大忽小"是随机事件。

---

## 八、文件位置

| 路径 | 内容 |
|---|---|
| **`tmp/fmod_aoe4_test/project_explore/`** | **终版工程，`Music.bank` = 33.50 MB（quality 37，17 个探索事件）** |
| `tmp/fmod_aoe4_test/build_explore_only.js` | 建探索版 17 个事件的脚本 |
| `tmp/fmod_aoe4_test/audio/mp3/` | 34 段探索切片 + 4 首探索整曲 |
| `tmp/fmod_aoe4_test/audio/wav/` | 15 个 WAV 48k/16bit（探索版只用到升级 3 个 + 胜利 4 个） |
| `tmp/fmod_aoe4_test/manifest.json` | 50 个文件的映射表（目标名 / 原名 / 用途 / LUFS / 起点终点） |
| `tmp/fmod_aoe4_test/build_aoe4_events.js` | 建完整版 19 个事件的脚本（含坑 1 的正确写法） |
| `tmp/fmod_aoe4_test/fix_banks.js` | 挂 bank 的脚本（坑 2，探索版已内置该步骤） |
| `tmp/fmod_aoe4_test/slim_bank.js` | 把事件移出 bank 的写法参考 |
| `tmp/fmod_aoe4_test/project5/` | 完整覆盖版，71.71 MB（四类素材都测，供参考） |
| `tmp/fmod_aoe4_test/project_slim/` | 备选版，23.93 MB（砍探索留作战 —— 与最终需求相反，仅存档） |
| `tmp/music_catalog/aoe4_matrix.txt` | 文明 × 时代 × 用途 覆盖矩阵 |
| `tmp/music_catalog/aoe4_split.txt` | 探索合辑的切分点明细 |

原工程 `Audio/ProjectKeynes` **没有动过** —— 它有未提交的改动
（`Click` 事件被改过、一批未跟踪的 XML 和 `Audio/Sources/`），不适合直接覆盖。

---

## 九、下一步建议

如果要接着做，优先级是：

1. **决定 33.50 MB 能不能接受**。还想更小只有三条路：
   去掉 `explore_imperial`（省 ~11 MB，代价是没有长曲样本）、
   降到 quality 25（26.14 MB）、或者把 bank 从 git 里摘出去。
2. 在 GUI 里打开 `project_explore` 核对 17 个事件是否都有波形
   （这是坑 1/2 的最终验收）。
3. 把 `game_audio_service.gd` 的事件表改好，跑通 1–2 个事件的真机播放。
4. 再做 State/Parameter 化：时代用 State，同代三段用 Multi Instrument 随机轮播
   （这次是用脚本建 9 个独立事件绕开了 MultiSound，它的 playlist 接口没探通）。
   这一层是原方案里最有价值但没动到的部分。
