# 电台音乐整理与 FMOD 测试方案

扫描日期：2026-10-20
源目录：`E:\CloudMusic\电台节目`
规模：**1018 首 MP3 / 62.50 小时 / 7.13 GB**（无子目录，文件名即元数据）

---

## 一、结论：可行，但有三个必须先定的约束

技术上完全可行 —— 全部文件是标准 320 kbps 上下的 44.1k/48k 立体声 MP3，
FFprobe 全量探测 1018/1018 成功、零损坏，批量导入 FMOD 没有格式障碍。

但有三件事如果不先决定，接进去会立刻出问题：

| 约束 | 现状 | 后果 | 建议 |
|---|---|---|---|
| **版权** | EU4 / 文明6 / 帝国时代4 / 纪元1800 的商业 OST（电台搬运） | 可内部技术验证，**不可随发行包分发** | 素材与 bank 只进本地/测试分支，发行前整体剥离 |
| **仓库体积** | 项目 `.git` 已 5.2 GB；现有 `Music.bank` 仅 88 KB（8 秒合成音） | 12 首真实曲进 bank 后 → **数十 MB 量级**；全库 PCM 会到几百 MB | 长曲在 FMOD 里设为 **Streaming**，bank 只留索引，体积几乎不涨 |
| **MP3 循环缝隙** | 全部是 MP3，带 encoder delay/padding | 无缝 loop 点会有咔哒或静缝 | **循环类素材转 WAV**；转场/一次性 cue 保留 MP3 即可 |

---

## 二、目录画像

这批不是"一个游戏的原声"，而是**五个来源混在一起**：

| 来源（文件名前缀） | 实际出处 | 数量 | 时长 | 特征 |
|---|---|---:|---:|---|
| `Melody_WQ` | 欧陆风云4（EU4） | 184 | 11.18 h | 38 个成套音乐包，大战略气质，**与 Project.Keynes 最贴** |
| `Yeckham` | 文明6（Civ6） | 537 | 26.59 h | 每文明「主题曲 × 4 时代」+ 环境音碎片 |
| `来孤` | 帝国时代4（AoE4） | 235 | 20.94 h | 「文明 × 时代 × 作战/探索」+ 升级/胜利短句 |
| `帐号已注销` | 疑似纪元1800 / 素材库 | 56 | 3.25 h | 单曲 OST + 5 个 `stinger_*` |
| `Wesaturn` | 人类（Humankind） | 6 | 0.54 h | 散曲，不成套 |

命名格式极不统一：389 首是 `艺术家 - 系列 - 曲名`，598 首是 `艺术家 - 曲名`
（系列藏在曲名里），另有 `文明-时代-用途`、`国家_The X Era` 等多种形态。
**靠目录结构分不了类，只能按语义分。**

---

## 三、四类整理结果

按**播放角色**（而不是按来源）分成四类，这直接对应 FMOD 的事件结构：

| 类别 | 数量 | 总时长 | 中位时长 | 时长区间 | 说明 |
|---|---:|---:|---:|---|---|
| **转场音乐** | **132** | 0.56 h | 16.7 s | 6.7 – 37.0 s | 5 个通用 `stinger_*`（21–37s）+ 127 个 AoE4 时代升级/胜利 cue |
| **主题音乐** | **146** | 8.89 h | 233.1 s | 51.9 – 362.4 s | Civ6 每文明 4 个时代版本，同旋律不同编配 |
| **系列音乐** | **290** | 17.09 h | 207.9 s | 57.5 – 425.1 s | EU4 38 个音乐包 + Civ6 106 首成套曲 |
| **轮播音乐** | **285** | 11.79 h | 130.3 s | 46.0 – 520.1 s | 全是 Civ6 环境音碎片 + 即兴片段 |
| （时代套装主体） | 114 | 20.96 h | 341.9 s | 158.1 – 2067.0 s | AoE4「作战/探索」，**部分单曲长达 16–34 分钟** |

### 几个值得注意的发现

1. **转场是这批素材里最值钱的部分。** AoE4 的 76 个「时代升级」片段（中位 19.0 s）
   和 51 个「胜利」短句（中位 7.7 s），正好是"时代推进"这种游戏事件的现成音效，
   而且是按文明 × 时代成套的。

2. **时代套装里有 47 首「探索」时长 16–34 分钟**（最长 2067 s）。
   这类很可能是把整段时代氛围串成了长轨，**不适合当单曲用**，要么切分要么排除。

3. **轮播池 100% 来自 Civ6**，风格单一。想验证"跨文明轮播不违和"，
   现有素材做不到 —— 需要混入 EU4 的「通用音乐」24 首（81 分钟）。

4. **EU4「通用音乐」那 24 首其实是最适合轮播的**：不绑定任何特定 DLC，
   气质统一（"马基雅维利""论人的尊严""一个时代的终结"），
   反而被我按命名规则归到了"系列音乐"里。

---

## 四、12 首测试集（已备好）

选曲原则：覆盖 FMOD 接入后必须验证的 4 件事，且题材贴合项目（中国 / 大战略 / 时代推进）。

| # | 角色 | 曲目 | 时长 | 采样率 | 验证点 |
|---|---|---|---:|---|---|
| 1 | 主题·远古 | 文明6 中国茉莉花 The Ancient Era | 115.9 s | 44.1k | 时代切换基准 |
| 2 | 主题·中世纪 | 文明6 中国茉莉花 The Medieval Era | 216.2 s | 44.1k | 同旋律换编配 |
| 3 | 主题·工业 | 文明6 中国茉莉花 The Industrial Era | 214.6 s | 44.1k | 段落推进 |
| 4 | 主题·原子 | 文明6 中国茉莉花 The Atomic Era | 199.4 s | 44.1k | 终局版本 |
| 5 | 系列 | EU4 通用音乐 - 一个时代的终结 | 217.9 s | 44.1k | 长曲 loop |
| 6 | 系列 | EU4 通用音乐 - 马基雅维利 | 149.9 s | 44.1k | 政治主题 playlist |
| 7 | 轮播 | 文明6中国配乐 - 古筝即兴1 | 132.9 s | 44.1k | 随机池成员 |
| 8 | 轮播 | 文明6中国配乐 - 古筝即兴2 | 133.7 s | 44.1k | 同风格交叉淡化 |
| 9 | 轮播 | 文明6中国配乐 - 渔舟唱晚 | 278.2 s | 44.1k | 长尾曲目 |
| 10 | 转场 | stinger_war_start_01 | 21.0 s | 48k | 战争爆发，叠在音乐上 |
| 11 | 转场 | stinger_law_changed | 24.1 s | 48k | 法律变更，不打断音乐 |
| 12 | 转场 | AoE4 中国_封建时代升级_战斗 | 18.9 s | 48k | 时代升级过渡 |

合计 **31.9 分钟，63 MB**，已复制到：

```
D:\Godot\ProjectKeynes\tmp\fmod_music_test\
```

> 放在 workspace 根的 `tmp/` 而不是 `Project.Keynes/Audio/`，因为后者在 git 仓库内。
> 63 MB 素材进仓库会重演 `tile_data.csv` 那类事故（见项目记忆）；
> 转成 WAV 后还会涨到 300 MB 量级。
>
> **2026-10-20 已清理**：这 12 首随"改用马里、只要探索"的需求一并删除。
> 需要时用 `tmp/prepare_aoe4_assets.py` 从 `E:\CloudMusic\电台节目` 重新生成。

---

## 五、接入前必须处理：响度差了 11.7 dB

实测这 12 首的整合响度（LUFS）：

| 曲目 | LUFS | True Peak | 分布 |
|---|---:|---:|---|
| 文明6 中国茉莉花 The Industrial Era | **-11.82** | +0.43 | 最响 |
| 一个时代的终结 | -13.00 | +0.29 | |
| 中国茉莉花 The Atomic Era | -13.14 | +0.24 | |
| 中国_封建时代升级_战斗 | -12.68 | -1.29 | |
| 渔舟唱晚 | -15.07 | -0.87 | |
| stinger_war_start_01 | -15.94 | -2.66 | |
| 中国茉莉花 The Medieval Era | -16.08 | +0.07 | |
| 古筝即兴1 | -17.03 | -1.07 | |
| 马基雅维利 | -17.24 | -0.09 | |
| 古筝即兴2 | -17.78 | -0.51 | |
| stinger_law_changed | -19.15 | -6.81 | |
| 中国茉莉花 The Ancient Era | **-23.48** | -6.20 | 最轻 |

**同一套「中国茉莉花」，远古版比工业版轻了 11.66 dB。**
直接接进去，"时代推进"会变成"音量暴增"，这是第一个会暴露的体验事故。

另外有 4 首 true peak 已经超过 0 dBTP（0.43 / 0.29 / 0.24 / 0.07），
说明源头已经削顶过，别再往上推。

### 处理方式：在 FMOD 里设 gain，不要改文件

不预处理音频（不破坏源文件、随时可回调），在每个 event 的 volume 上做线性偏移。
以 **-18 LUFS** 为目标：

| 曲目 | 建议 gain |
|---|---:|
| 中国茉莉花 The Ancient Era | **+5.0 dB**（注意 TP 余量，别推到 +5.5） |
| 马基雅维利 | -0.8 dB |
| 古筝即兴2 | -0.2 dB |
| 古筝即兴1 | -1.0 dB |
| The Medieval Era | -1.9 dB |
| stinger_war_start_01 | -2.1 dB |
| 渔舟唱晚 | -2.9 dB |
| The Atomic Era | -4.9 dB |
| 一个时代的终结 | -5.0 dB |
| 中国_封建时代升级_战斗 | -5.3 dB |
| The Industrial Era | -6.2 dB |
| stinger_law_changed | +1.2 dB |

---

## 六、接入路径

现有工程：`Audio/ProjectKeynes/ProjectKeynes.fspro`（Studio 2.03.15），
4 个 bank（Master / Master.strings / Music / UI），9 个事件
（`Prototype` + 8 个 UI cue），Godot 侧只有一个边界 `scripts/audio/game_audio_service.gd`（153 行），
其中 `MUSIC_EVENT` 硬编码为 `event:/Music/Prototype`。

### 1. 循环素材转 WAV

只转需要无缝循环的（第 1–9 首），转场保留 MP3：

```bash
ffmpeg -i "input.mp3" -ar 48000 -c:a pcm_s16le "output.wav"
```

统一到 48 kHz / 16-bit —— 转场那 3 首本来就是 48k，剩下 9 首是 44.1k，
混用会让 FMOD 逐个重采样，bank 里多一层不必要的转换。

### 2. FMOD Studio 里建结构（不要改 `Prototype`）

```
Music/
  Era/            era_china_ancient / _medieval / _industrial / _atomic
  Series/         series_eu4_end_of_era / series_eu4_machiavelli
  Rotation/       rot_china_guzheng_1 / _2 / rot_china_fishing_boat
  Transition/     stinger_war_start / stinger_law_changed / trans_upgrade_feudal
```

保留 `Prototype` 做对照，新建 12 个 event。长曲设 **Streaming**，
并在 transport 上标 loop region（循环素材）。

### 3. Godot 侧改一处

`game_audio_service.gd` 目前只有一个 `play_prototype(tension)`。
需要把硬编码的 `MUSIC_EVENT` 抽成事件表，并加一个换曲接口：

```gdscript
const MUSIC_EVENTS := {
    &"era_ancient":    "event:/Music/Era/era_china_ancient",
    &"era_medieval":   "event:/Music/Era/era_china_medieval",
    ...
}
func play_music(key: StringName) -> bool
```

`set_tension()` 可以保留 —— 真实曲目没有分层，第一轮先让它变成空操作，
否则调用方会以为参数还生效。

### 4. 构建与侧听

```bash
Project.Keynes\Build-FMOD-Banks.cmd      # diagnostic → build → 拷 4 个 bank
Project.Keynes\Run-FMOD-Demo.cmd         # Godot 4.6.2 里侧听
```

构建脚本会校验后把 bank 同步到
`Project/project-keynes/assets/audio/banks/Desktop/`。

---

## 七、需要你定的三件事

1. **这批音乐是"临时技术验证"还是"要进游戏"？**
   前者可以随便放，后者必须先解决版权和仓库体积。

2. **第一轮只验证 Windows 桌面吗？**
   现有集成是 Windows-only（`game_audio_service.gd` 里对平台做了硬判断，
   headless 也默认禁用）。Web/Android 这轮不在范围内。

3. **时代切换要不要一次做完？**
   4 个时代版本现成可测，但游戏侧还没有"当前时代"这个信号传给音频层。
   要么先只做手动切曲（验证 FMOD 能切），要么顺手把时代状态接出来。

---

## 八、产出文件

| 文件 | 内容 |
|---|---|
| `tmp/music_catalog/music_catalog.csv` | 1018 首全量分类表（角色 / 来源 / 系列 / 时代 / 用途 / 时长 / 采样率） |
| `tmp/music_catalog/summary.txt` | 统计汇总（角色、来源、系列包、用途、时长分布） |
| `tmp/music_catalog/role_*.txt` | 按角色拆开的清单，共 8 个 |
| `tmp/fmod_music_test/` | 12 首测试素材（63 MB） |
| `tmp/music_probe.csv` | FFprobe 原始探测数据 |
