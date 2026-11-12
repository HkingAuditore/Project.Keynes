# Military formation prototype art v4.1

本目录服务 M0 独立视觉预览、M2 `MilitaryArmyTokenLayer` 的只读 formation
backend，以及正式 `player_game.tscn` 地图内验收。运行时不会读取或写回
`MilitaryCore` 状态，也不会修改 PKMI 或 state hash。

## 当前结论

v4.1 已替代 v3 成为当前运行时过渡基线：

- 16 张动作板全部从模型生成/图生图流程选定；
- 炮兵 idle 无乘员、无炮口焰、无烟、无后坐，双炮相对位置保持锁定；
- v4 atlas 已通过 strict source-contract、固定注册、动态核心轮廓和透明边界 QC；
- `MilitaryArmyTokenLayer`、preview layer、visual catalog 和测试均已引用 v4；
- v4.1 不是最终方案，下一步使用 `tools/military/formation_video_pipeline.py` 接入固定镜头 image-to-video 的 v4.2 生产流程。

## v3 历史结论

v3 专门修复两类可见问题：

- v2 的合并动作大图存在武器、烟尘或炮口效果跨过等分格线的情况；
- v2 一次性动作的成员相位逆序，且 mipmap 会把 atlas 相邻格融合，导致切图
  不连贯或从图像中间被截断。

v3 改为每个“原型 × 动作”单独生成一张 4 列 × 2 行、共 8 帧的透明底动作板，
再进行统一裁剪和 atlas 拼装。兵种图形全部由内置生图模型生成，未使用 SVG，
也未用代码绘制单位。

## 美术来源

- 16 张 `source/v3/{prototype}_{action}.png` 生图动作板；
- 每张固定 4 列 × 2 行，共 8 帧；
- 读取顺序为从左到右，再读取下一行；
- 所有单位采用严格垂直正俯视，统一朝东；
- 攻击火光、烟尘和受击效果都留在地图平面内，不使用斜向投影；
- Pillow 工具只做 alpha 清理、统一裁剪、缩放、透明 padding 和 atlas
  拼装，不绘制或补画兵种形体。

完整提示词与负面约束见 `source/prompts_v3.md`。贸易车队参考图只用于统一
正俯视相机、材质和色板，不重用贸易单位轮廓。

## v4.1 文件

| 文件 | 内容 |
| --- | --- |
| `source/v4/selected/{prototype}_{action}.png` | 16 张 4×2 最终选材动作板 |
| `source/v4/identity/` | 单帧母版、身份板和 v4.1 图生图提示词 |
| `source/source_manifest_v4.json` | 源板、固定注册、动态 QC、候选来源和 SHA-256 |
| `military_formation_prototype_v4.png` | 当前运行时 1024×2048 RGBA atlas |

## v3 历史文件

| 文件 | 内容 |
| --- | --- |
| `source/v3/foot_{idle,move,attack,hit}.png` | 步兵 4 张 4×2 动作板 |
| `source/v3/mounted_{idle,move,attack,hit}.png` | 骑乘 4 张 4×2 动作板 |
| `source/v3/artillery_{idle,move,attack,hit}.png` | 炮兵 4 张 4×2 动作板 |
| `source/v3/armored_{idle,move,attack,hit}.png` | 装甲/机械 4 张 4×2 动作板 |
| `source/prompts_v3.md` | 共享提示词、分原型提示词与生图边界 |
| `source/source_manifest_v3.json` | 源图、裁剪、逐帧边界、差异帧和 SHA-256 |
| `military_formation_prototype_v3.png` | 历史 1024×2048 RGBA atlas |

## 切帧与 atlas 契约

- atlas：1024 × 2048 RGBA8；
- 单帧：128 × 128；
- atlas：8 列 × 16 行；
- 帧内有效内容四周保留 12 px 透明 padding；
- 同一动作的 8 帧共用一个中心裁剪框，禁止逐帧按 bbox 重新居中或缩放；
- 每张源动作板的 8 格都必须有透明周边，不允许武器或特效触碰格线；
- 每个 atlas 帧边界 alpha 必须为 0，避免 linear 采样吃到相邻格；
- 每个动作 8 帧均非空，且至少 7 帧不同；
- `attack/hit` 的末帧可因闭包修复替换为 `idle` frame 0，因此允许至少 7 个唯一帧；
- Godot 导入必须使用 `mipmaps/generate=false`；
- shader 使用 `filter_linear`，不得使用 `filter_linear_mipmap`；
- v4.1 SHA-256：`849939cc4b60ad3d5910dd2e9060566ae0aa2721ccf2b54f1bccc9e7440a8497`。

## 动画相位

- `idle / move` 使用全局视觉时间加成员确定性相位循环；
- `attack / hit` 是一次性动作，成员按序号正向错峰；
- 成员 `0` 立即启动，后续成员分别延后 `0.025 s`；
- 5 成员完整动作窗口为 `1.0 + 4 × 0.025 = 1.1 s`；
- 一次性动作播完才回 `idle`，不会在最后一名成员完成前提前切断。

## 运行时入口

- 独立四原型四动作预览：
  `res://tests/military/military_formation_visual_harness.tscn`
- 生产 token backend 演示：
  `res://tests/military/military_formation_token_harness.tscn`
- 正式游戏地图内验收：
  `res://tests/military/military_formation_map_visual_harness.gd`

地图验收命令必须使用图形渲染，不能加 `--headless`：

```powershell
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --path Project\project-keynes `
  --rendering-method gl_compatibility `
  --resolution 1600x900 `
  --script res://tests/military/military_formation_map_visual_harness.gd
```

默认输出到 `res://tmp/military_formation_map_visual/`。00–07 是真实地图
广角、三档 LOD 和 fallback 证据；08–11 是四个动作近景；12–15 是四组
8 帧地图动作序列。序列使用生产 `MilitaryArmyTokenLayer` 的显示世界坐标，
经正式 `MapCamera.safe_world_to_screen()` 投影后动态居中裁切，不再使用固定
屏幕矩形。

将地图序列编码为 GIF：

```powershell
python tools/military/build_formation_map_sequence_gifs.py
```

输出：

- `military_formation_v4_idle_map.gif`
- `military_formation_v4_move_map.gif`
- `military_formation_v4_attack_map.gif`
- `military_formation_v4_hit_map.gif`
- `military_formation_v4_all_actions_map.gif`

## 民兵动作预览

民兵首版动作候选暂存于 `res://tmp/military_militia_animation_preview/`。通过 QC 的
`idle/move/attack` 源板已经接入正式 `foot` atlas 的对应动作行；`hit` 继续沿用原
动作板，避免把未通过连续性检查的受击过渡带进运行时。源板采用原地图动作板的正
俯视编队画风，GIF 由固定 4×2 帧切片工具生成：

```powershell
python tools/military/build_militia_behavior_gif.py `
  --source Project/project-keynes/assets/military/formations/prototype/source/v4/selected/foot_move.png `
  --output Project/project-keynes/tmp/military_militia_animation_preview/militia_move_runtime_v1.gif
```

该预览同时保留生成前后的 GIF 联系图，后续可按同一流程继续更新 mounted、artillery
和 armored 三类原型。

## 重建 atlas

在仓库根目录执行：

```powershell
python tools/military/generate_formation_prototype_v4.py `
  --source-dir Project/project-keynes/assets/military/formations/prototype/source/v4/selected `
  --source-pattern "{prototype}_{action}.png" `
  --strict
```

## video-first 源板

`tools/military/formation_video_pipeline.py` 不生成视频，只处理模型产出的
固定镜头视频或已经透明的 RGBA 帧序列：

```powershell
python tools/military/formation_video_pipeline.py `
  --prototype artillery `
  --action idle `
  --input <model-video.mp4> `
  --key-color 00ff00 `
  --output Project/project-keynes/assets/military/formations/prototype/source/v4/video_selected/artillery_idle.png
```

工具会自动选择稳定 8 帧窗口，使用整个窗口的并集 bbox 做一次共享裁切和
一次共享缩放，然后输出 1792×896 RGBA 4×2 源板及 `.video_report.json`。
炮兵 idle 还会额外验证双炮相对位置；任一 QC 失败时默认不返回成功。

重建后让 Godot 重新导入：

```powershell
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --headless --path Project/project-keynes --import
```

## 历史来源

v2/v3 的合并动作大图、旧动作板和旧 atlas 仅保留为迭代记录，不再被运行时
或正式测试引用。正式验收入口以 v4.1 的 16 张独立动作板、
`source_manifest_v4.json` 和 `military_formation_prototype_v4.png` 为准。
