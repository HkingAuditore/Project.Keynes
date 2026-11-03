# 军事地图部队编队视觉设计 v0.5.0

- 状态：正式设计冻结；v4.0 文本直出动作板已否决，v4.1 动作板作为运行时过渡基线，v4.2 迁移到 video-first
- 日期：2026-11-03
- 适用对象：Project.Keynes `MilitaryCore` / `MilitaryRenderFeed` 的地图视觉投影
- 原型范围：4 套动作原型 × 4 个动作 × 每动作 8 帧；1–5 成员；3 档 LOD
- 正式验收入口：`res://tests/military/military_formation_map_visual_harness.gd`
- 权威边界：不修改 `MilitaryCore`、PKMI 或 state hash；视觉层只读

本文中的“已实现”只表示工作区已有对应源码或资产接口，不等于已经完成运行验证。除“已通过”或“已验证”明确标注的项目外，其余实现都仍需按第 15 节验收。

## 1. 决策摘要

1. 地图部队采用“兵种配比 + 兵力规模 + 动作原型”驱动的图像编队，不再只显示完全相同的纸片棋子。
2. 首期只制作四套动作原型：`foot`、`mounted`、`artillery`、`armored`。每套包含 `idle`、`move`、`attack`、`hit`，每个动作 8 帧。
3. 一支地图部队显示 1–5 个成员。成员数量由总人数决定；各成员使用哪套原型由兵种配比决定。
4. 地图缩放使用 `aggregate`、`representative`、`formation` 三档 LOD，并用滞回避免阈值抖动。
5. 全部游戏单位采用严格 90° 正俯视。素材统一朝东，运行时只旋转 quad 表达地图朝向，不制作八方向帧。
6. 兵种图像只能由生图模型生成，不允许使用 SVG、矢量图标、代码绘制或程序化补画兵种形体。
7. “动态不够”明确指生图动作帧本身相邻帧差异不足，不能用运行时平移动画、队伍位移、闪光或烟尘遮盖。核心身体、武器、轮履和队形的 pose-to-pose 轮廓必须在帧内发生明显变化。
8. formation shader 与贸易商队共用地图光照计算：昼夜、地表法线、horizon、GI、太阳/月亮方向及软投影必须来自同一套地图参数。
9. 部队体和投影共用同一个 `MultiMesh` 实例缓冲，以两个 `MultiMeshInstance2D` 分别执行 body/shadow pass，避免两套动画状态漂移。
10. 首期不铺开 24 个兵种专属动画。24 个 catalog 兵种只映射到四套动作原型，该映射是数据一致性要求，不代表制作 24 套美术。
11. 最终生产流程不使用“一次生成整张 4×2 动作板”作为主路径，而是固定单帧母版后生成固定镜头短片，再从稳定窗口抽取 8 帧。
12. 一个动作的所有帧只能共用一次裁切和一次缩放；禁止逐帧 recenter、逐帧 rescale，也禁止靠运行时位移掩盖源帧注册漂移。

### 1.1 AI 生帧工作流调研

对公开工作流的核对结论一致：成熟方案普遍采用“单张角色/单位母版 → image-to-video 或逐帧图生图 → 从稳定片段抽帧 → 背景去除/透明化 → 固定裁切拼图”，而不是要求图片模型一次画完整张 sprite sheet。

- Scenario 的 Action Sprite 公开工作流明确把 image-to-video 结果导出为 spritesheet：
  <https://help.scenario.com/en/articles/9331645-action-sprite>
- ComfyUI 的 image-to-video 工作流把锚帧、视频生成、帧采样和 contact sheet 拆成独立节点：
  <https://comfyui.org/en/comfyui-video-workflows-for-high-quality-ai-animation>
- Runway 的 Motion Brush 和 Gen-4 References 使用同一静止图/角色参考驱动短动作，并在视频阶段保持镜头和主体身份：
  <https://help.runwayml.com/hc/en-us/articles/20251263824915-How-to-Create-Stunning-Videos-with-Runway-Gen-2-Motion-Brush-for-Still-Images>
  <https://help.runwayml.com/hc/en-us/articles/37223431974163-Using-References-in-Gen-4-Video>
- Vibe Game Dev 的 Godot 教程采用“生图母版 → 视频 → FFmpeg 抽帧 → Aseprite/拼图 → AnimatedSprite2D”的完整链路：
  <https://vibegamedev.com/tutorials/character-animation-with-ai/>
- PixelAI 的像素角色教程同样要求逐帧生成或从视频提取，再固定尺寸拼接，不能依赖一次生成整张表：
  <https://pixelai.co/blog/ai-pixel-art-animation/>

因此项目采用以下迁移结论：

1. `idle / move`：单母版 → 固定镜头 image-to-video → 稳定循环窗口 → 8 fps 抽 8 帧。
2. `attack / hit`：中性首帧、动作峰值、恢复末帧作为起止/参考条件，按一次性动作窗口抽 8 帧。
3. 视频不原生透明时使用纯色背景键控；键控、边缘去色、固定裁切、固定缩放和拼图属于允许的确定性后处理。
4. 视频生成模型必须锁定 camera、主体数量、体量和道具相对位置；炮兵 idle 额外执行双炮相对位移 QC。
5. 当前 v4.1 动作板只作为可运行的过渡基线；正式 video-first 版本仍需重新通过源板、atlas、运行时和地图内验收。

## 2. 目标与非目标

### 2.1 目标

- 让玩家不打开军事面板也能从地图读出部队类型、规模、混合构成和当前动作。
- 在 48–64 屏幕像素尺度上仍能辨认原型和动作阶段。
- 让部队与真实地图的昼夜、地形明暗、遮挡和投影融为一体。
- 先用有限原型验证动作质量、编队可读性、LOD 和批量渲染成本。
- 保持 24 兵种内容扩展能力，但不让每个兵种重复制作完整逐帧动画。

### 2.2 非目标

- 不修改军事战斗、行军、伤亡、补给、组织度或 AI 数值。
- 不修改 `MilitaryCore` 权威状态、PKMI 布局或 state hash。
- 不在本阶段制作 24 套兵种专属美术。
- 不在本阶段制作八方向动作帧。
- 不用 SVG、代码绘制或程序化几何替代生图单位。
- 不用运行时位移伪装动作帧差异。
- 不把独立隔离场景视为最终视觉验收；最终必须在正式 `player_game.tscn` 地图内检查。
- 不用交战 flag 伪造真实攻击/受击事件。真实战斗 cue 仍属于后续事件接线。

## 3. 当前状态

| 项目 | 本文修订时的事实 | 结论 |
| --- | --- | --- |
| v4 提示词 | `formation_v4_prompts.py` 已生成 16 份原型×动作提示词 | 合同已建立 |
| v4.0 文本直出动作板 | `source/v4/candidates/` 已完成 16/16，但逐张检查发现整组朝向漂移、马/车体随机转向、枪炮越格、装甲炮塔被画框裁断 | 整批否决，不进入图集 |
| v4.1 母版与身份板 | `source/v4/identity/` 已制作四套固定正俯视、统一朝东的 4×2 身份板；artillery 使用人工筛选的无乘员朝东母版并跳过旧的双重旋转，armored 使用一次固定 90° 栅格旋转 | 身份和方向合同已建立 |
| v4.1 动作板 | `source/v4/selected/` 已完成 16/16；炮兵 idle 重新生成为无乘员、无炮口焰、无烟、无后坐的锁定双炮动作 | 完成，作为过渡基线 |
| v4.1 图集与清单 | `military_formation_prototype_v4.png` 与 `source_manifest_v4.json` 已生成；strict QC 通过，manifest 为 `ready` / `runtime_ready=true` | 自动资产闭环已建立 |
| 当前运行时图集 | `MilitaryArmyTokenLayer`、preview layer 和 `military_visual_catalog.json` 已切到 v4.1 | v4.1 过渡基线，不是 video-first 最终版 |
| video-first 工具 | `tools/military/formation_video_pipeline.py` 已支持视频/透明帧序列、稳定窗口、固定裁切缩放、4×2 拼图和炮兵双炮锁位 QC | 待接入真实 image-to-video 模型 |
| 地图光照 shader | 已新增共享 include，formation body/shadow pass 已接源码；修复 Godot 4.6 fragment `return` 编译错误 | headless Compatibility 已通过 |
| 体影共享 MultiMesh | body 与 shadow 引用同一个 MultiMesh；昼夜、法线、horizon、GI 和 tiled 变体参数已通过专用测试 | 自动测试 432 checks / 0 failures；仍待地图内目视验收 |
| 现有自动测试 | `military_formation_visual_test.gd` 已针对 v4.1，校验 atlas、manifest、固定注册和至少 7 个唯一帧；token/render feed/map layers/shader 测试全部通过 | 当前 v4.1 自动门槛通过 |
| 正式地图夹具 | 已直接加载 `player_game.tscn` 并输出四动作序列 | 本次重跑被 runtime day-wait 阻塞，不能把旧图视为 v4.1 证据 |

结论：

- v3 的地图截图和测试结果不能替代 v4.1 验收。
- v4.0 已证明“仅凭文字让模型一次生成整张 4×2 动作表”不可控，不能通过后期裁切修复随机朝向和跨格武器。
- v4.1 必须先锁定模型生成的正俯视朝东单帧母版，再由该母版复制成八格身份板作为图生图参考；动作编辑不得改变身份、方向、成员数、整体比例和格内注册点。
- v4.1 已完成动作板筛选、strict 图集打包、catalog 切换和 headless 动作可读性验收；正式地图内昼夜/地形目视仍待重新执行。
- v4.1 只是当前可回退的运行时过渡基线；video-first 正式版通过全部门槛前，不能标记为“最终美术完成”。

## 4. 视角、方向与地图内验收

### 4.1 严格正俯视

所有源帧必须是 90° 垂直正交正俯视，等价于相机从天顶垂直向下看地图：

- 北向上，东向右。
- 可见面只包括盔顶、肩顶、盾顶、背脊、马背、车顶、炮架顶面、履带顶面和炮管顶面。
- 禁止透视、三视角、侧视、三分之四视角和地平线。
- 禁止可见人脸、马脸侧影、车体侧壁、履带侧面和等距投影。
- 火光、烟尘、碎片和冲击效果必须留在地图水平平面内。
- 源图禁止烘焙斜向地面阴影；地图阴影由运行时 shader 生成。

### 4.2 统一朝东

- 所有原型的武器、车头、马首和攻击方向统一朝东。
- 运行时通过 `heading_q16` 旋转整个成员布局和 sprite transform。
- 禁止非等比拉伸来模拟方向。
- 不维护八方向重复帧。

### 4.3 地图内验收

最终验收必须在正式 `player_game.tscn`、真实 `MapData`、真实地形、正式 `MapCamera` 和生产 `MilitaryArmyTokenLayer` 中完成。独立 harness 只用于定位动作和图集问题，不能作为最终视觉签收依据。

验收图必须同时展示：

- 真实地图地形和正式相机缩放；
- 1–5 成员编队；
- 四套动作原型的四类动作；
- 三档 LOD；
- 白天、夜间或不同太阳高度下的光照差异；
- 地形法线、horizon、GI 和软投影对 formation 的影响；
- 图集 fallback 与迷雾规则。

## 5. 四套动作原型

首期只有四套动作骨架。24 个兵种全部映射到其中之一：

| 原型 | id | 视觉重点 |
| --- | --- | --- |
| 步兵 | `foot` | 密集横队或楔形，强调盾墙、枪矛投影和正面宽度 |
| 骑乘 | `mounted` | 纵深交错，强调马体伸缩、骑手前倾和冲锋节奏 |
| 炮兵 | `artillery` | 横向间隔更大，强调车轮、炮架、后坐和烟尘 |
| 装甲/机械 | `armored` | 楔形或菱形队列，强调车体俯仰、炮塔偏转、履带和炮口冲击 |

规则：

- catalog 的 `class` 不能直接猜视觉原型。必须由 dense unit id 经视觉 catalog 映射。
- `combined_arms` 当前归入步兵骨架，其“合成”通过配比和未来附件表达。
- `drone_swarm` 当前归入装甲/机械骨架，不额外制作第五套原型。
- 未来差异优先通过轮廓附件、材质色板、体量和动作节奏表达。
- 只有四套骨架无法表达兵种身份且影响玩法识别时，才批准新增动作原型。

## 6. 1–5 成员编队

### 6.1 人数档位

| 总人数 | 可见成员数 |
| --- | --- |
| 1–299 | 1 |
| 300–999 | 2 |
| 1,000–2,999 | 3 |
| 3,000–7,999 | 4 |
| 8,000+ | 5 |

人数决定“最多显示几组”，不直接决定兵种。一个成员代表一组视觉编队，不代表一名士兵。

### 6.2 配比压缩

一支部队最多取三个正权重兵种进入地图摘要：

1. 按人数权重降序排序；
2. 权重相同时按 dense unit id 稳定排序；
3. 先为每个入选兵种保留一个成员；
4. 剩余成员使用最大余数法分配；
5. 未进入摘要的兵种仍完整保留在军事面板；
6. 缺少配比、非法权重或未知 dense id 时，整支部队保守回退到纸片 token。

示例：五个成员、前三类权重 `50 / 30 / 20`，分配结果为 `2 / 2 / 1`。

### 6.3 成员布局

每套原型为 1–5 成员分别定义布局：

- `foot`：密集横队/楔形；
- `mounted`：前后交错的骑乘队列；
- `artillery`：更大横向间隔，避免炮架重叠；
- `armored`：楔形或菱形，突出突破方向。

布局偏移和 sprite 使用同一个朝向旋转。成员必须有确定性的动画相位偏移，不能让五组 sprite 完全同步。

## 7. 动作设计

每套原型包含四行动作，每行 8 帧：

| 动作 | 循环 | 帧率 | 必须可读的阶段 |
| --- | --- | --- | --- |
| `idle` 待命 | 是 | 8 fps | 重心变化、盾/枪/炮塔/天线的非微动摆动、回到半步相位 |
| `move` 行军 | 是 | 8 fps | 接触、压缩、推进或腾跃、再次接触；轮履和队形轮廓必须变化 |
| `attack` 攻击 | 否 | 8 fps | 蓄力、爆发/齐射/突刺、最大后坐或伸展、回收 |
| `hit` 受击 | 否 | 8 fps | 接触、压缩或错位、最大失衡、恢复 |

动画规则：

- `idle` 与 `move` 由全局视觉时间循环。
- `attack` 与 `hit` 是一次性动作，完成后回 `idle`。
- 一次性动作的成员按序号正向错峰，每个成员延后 `0.025 s`；五成员完整窗口为 `1.1 s`。
- 暂停时冻结 `visual_seconds`。
- `reduced_motion` 使用代表帧，不播放连续帧。
- 动画状态只存在渲染层，不写模拟状态。

## 8. 生图资产约束

### 8.1 生成方式

- 单位美术必须使用生图模型生成。当前生产候选使用 `GPT-Image-2.5-Sunburst` 最高质量档。
- v4.1 过渡动作表使用“身份板 Reference A + 图生图”。正式 v4.2 生产路径使用“单帧母版 + 固定镜头 image-to-video + 稳定窗口抽帧”；文本直出 4×2 动作板只允许作为概念草图，禁止直接进入图集。
- 每个原型先从模型生成的候选帧中选定一张正俯视、统一朝东的母版。只允许对母版做透明清理、固定比例缩放和固定 90° 栅格旋转，不允许代码补画单位。
- 母版按同一比例、同一格内中心复制为 4×2 身份板。该身份板作为每张动作提示词的 Reference A，锁定成员数、装备、材质、面数、比例、朝向和格内注册点。
- 动作编辑只改变局部姿态、武器投影、车体/马体压缩、轮履、烟尘和冲击。禁止模型重新设计单位、改变朝向或重排画框。
- 禁止 SVG、矢量平面图标、代码绘制、程序化几何建模或手工补画兵种形体。
- Pillow 等脚本只允许做透明清理、固定裁剪、缩放、padding、切片、拼图和 QA 统计。
- 生图 API token 只能通过环境变量或本地密钥注入，不得写入仓库、manifest 或设计文档。

### 8.2 单动作源板

每张源动作板固定为：

- 4 列 × 2 行；
- 共 8 帧；
- 先从左到右读取上排，再从左到右读取下排；
- 真透明 RGBA 背景；
- 八格之间和整张图外围均保留透明 gutter；
- 任何身体、武器、烟尘、枪焰和碎片不得触碰或跨越格线。

v4.1 的过渡参考链固定为：

```text
model-generated neutral cell
  -> deterministic alpha cleanup / fixed 90-degree raster rotation
  -> canonical prototype master
  -> eight identical copies in a fixed 4x2 identity board
  -> image-to-image action edit
  -> source-contract QC and dynamic silhouette QC
```

v4.2 的正式生产链固定为：

```text
model-generated neutral master
  -> fixed-camera image-to-video action clip
  -> stable 8-frame window
  -> optional chroma-key alpha cleanup / despill
  -> one shared crop and one shared scale
  -> 4x2 source sheet
  -> source-contract QC, motion QC and pair-registration QC
  -> atlas
```

原始 artillery 母版曾朝北，armored 母版曾朝南；v4.1 的原始母版分支分别使用一次确定性的 `-90°` 和 `+90°` 栅格旋转统一为朝东。当前 artillery 使用已朝东的无乘员人工筛选母版，因此跳过旧旋转，避免双重旋转。该步骤只旋转模型生成的像素，不生成或补画单位。任何动作候选若重新出现整组 90°/180° 转向、镜像、成员数变化、车体/马首反向、炮兵乘员或炮口焰，直接拒绝，不进入自动裁切。

### 8.3 pose-to-pose 与固定注册

“固定注册点”指固定 cell 画布、固定视觉中心和固定整体比例，不表示身体轮廓必须固定：

- 不允许逐帧按 alpha bbox 重新居中；
- 不允许逐帧独立缩放；
- 允许身体、底盘、武器、轮履和队形在固定画布内大幅压缩、伸展、偏转、后坐、分离和重组；
- 8 帧采用“准备—动作峰值—恢复”的 pose-to-pose 节奏；
- 动作姿势幅度应约为参考微动版本的 2–3 倍；
- 所有帧的有效并集应控制在约 `1.30×` 中立轮廓包络内；
- 主体应位于中央约 80% 安全区内；
- 同一动作的八帧共用同一个中心裁剪框。

### 8.4 小尺度可读性

- 在 48–64 屏幕像素下，相邻帧仅看 alpha 轮廓也应可区分。
- 不允许把轻微呼吸、单个高光变化或一两个像素摆动计为有效新帧。
- 烟尘、枪焰、火星和闪光可以增强动作，但不能成为唯一差异来源。

### 8.5 负面约束

每个提示词必须明确排除：

- 复制帧或近似复制帧；
- 微动式 idle；
- 透视、侧视、三视角、三分之四视角；
- 可见人脸或马脸侧影；
- 竖向跳起、离地俯视漂移；
- 斜向烘焙投影；
- SVG/vector-flat 图标、像素画、低模或塑料质感；
- 字母、数字、网格、边框、水印和棋盘格背景。

## 9. 帧间动态验收指标

### 9.1 为什么不能只检查哈希

“8 帧哈希不同”只能证明像素不完全相同，无法证明动作可读。v3 的失败说明：即使帧、边界和连续性都合法，动作主体也可能几乎没有变化。

### 9.2 高不透明核心轮廓差

对每个原型×动作的 8 帧执行固定注册、固定裁剪和固定缩放后，定义：

- 核心像素：`alpha >= 0.85`；
- 主体掩码：只包含身体、武器、轮履、炮塔和队形本体；
- 效果掩码：烟尘、枪焰、火星和碎片单独记录，不计入核心轮廓差；
- 对帧 `i`、`j`：

```text
D(i,j) = |CoreMask_i XOR CoreMask_j| / max(|CoreMask_i OR CoreMask_j|, 1)
```

当自动效果分离不可靠时，必须使用固定的主体 ROI 或人工标注效果掩码。不能通过增加烟尘、枪焰或闪光提高核心指标。

### 9.3 门槛

帧编号在本文中使用 F1–F8，shader 中使用 0–7。目标值以核心轮廓差计算：

| 动作 | 相邻帧目标 | 强制要求 |
| --- | --- | --- |
| `idle` | 2–3% | 所有相邻帧不得低于 2%；F2 与 F6 对比达到 4–5% |
| `move` | 6–8% | 所有相邻帧不得低于 6%；至少一组动作峰值达到 15–18% |
| `attack` | 6–8% | 所有相邻帧不得低于 6%；蓄力与最大伸展/后坐对比达到 15–18% |
| `hit` | 6–8% | 所有相邻帧不得低于 6%；最大失衡与恢复对比达到 15–18% |

补充规则：

- 指标必须在源动作板和最终 atlas 中都通过。
- 源动作板先通过动态指标，才允许进入 atlas。
- 单个动作失败时只重生成该原型×动作，不牵动已通过动作。
- `idle/move` 的 F8 应接近 F1，但保留半步相位差；`attack/hit` 的 F8 应接近中立待命姿态。
- 自动指标通过后仍须做 48–64 px 的人工轮廓检查。
- 最终验收必须记录每张动作板的相邻帧矩阵、关键帧对比和效果掩码说明。

## 10. 源动作板与运行时图集

### 10.1 最终图集

| 项 | 规格 |
| --- | --- |
| 源动作板 | 16 张，每张 4×2，共 8 帧 |
| 最终文件 | `assets/military/formations/prototype/military_formation_prototype_v4.png` |
| 格式 | RGBA8 PNG |
| 单帧 | 128×128 px |
| 图集 | 1024×2048 px |
| 列 | 8 帧 |
| 行 | 4 原型 × 4 动作 = 16 行 |
| 有效内容安全边 | 每帧至少 12 px 透明 padding |
| 采样 | `linear`、`repeat_disable`、禁止 mipmap |
| Pivot | `[64, 64]` |
| 投影 | `strict_vertical_orthographic_overhead` |
| 朝向 | 东 |

atlas 行号：

```text
atlas_row = prototype_row * 4 + action_row
```

原型行固定为 `foot=0`、`mounted=1`、`artillery=2`、`armored=3`；动作行固定为 `idle=0`、`move=1`、`attack=2`、`hit=3`。

### 10.2 采样和切图

- 运行时 atlas 禁止生成 mipmap，避免相邻动画格在低尺度下互相融合。
- 每帧四条边的 alpha 必须为 0。
- 同一动作的八帧必须共用一个裁剪框。
- 若模型把上、下两排画在不同格内中心，打包器可对每一整排施加一个共享平移，把该排四帧一起对齐到固定中心；禁止逐帧按 alpha bbox 重新居中。该校正必须写入 manifest。
- 只允许清理低透明烟尘/噪点的跨格溢出；若身体、武器、轮履或炮管形成高不透明核心跨格连接，必须重建该动作，不能靠裁切掩盖。
- shader 的局部 UV 只能在当前 cell 内采样。
- `INSTANCE_CUSTOM` 继续使用：
  - `x`：prototype row；
  - `y`：action row；
  - `z`：循环相位或一次性动作开始时间；
  - `w`：成员序号/变体。
- `INSTANCE_COLOR` 只能做轻微阵营/原型偏色，不能覆盖生图材质。

### 10.3 v4 清单

必须生成 `source/source_manifest_v4.json`，至少记录：

- 16 张候选源板及其最终选用文件；
- 生图模型、质量档、输入参考和 prompt 文件；
- 每张源板的 4×2 格检查；
- 每帧透明边界、主体 bbox、固定裁剪框和缩放；
- 每个动作的相邻帧核心轮廓差矩阵；
- 关键帧对比和效果掩码说明；
- 最终 atlas 尺寸、排序、frame padding、SHA-256；
- 被拒绝候选和重生成原因。

当前 v4.1 atlas、manifest、headless 测试和独立视觉夹具已接通，运行时 catalog、preview layer、`MilitaryArmyTokenLayer.FORMATION_ATLAS_PATH` 与测试路径均已切到 v4。v4.1 仅作为过渡基线；后续 video-first 版本必须重新执行 manifest、Godot 测试、正式地图动作序列和昼夜/地形验收后才能替换。

## 11. 运行时 Shader 与地图光照

### 11.1 与贸易商队共享光照

formation 不单独计算“游戏时间亮度”。它通过共享 include：

`res://shaders/include/terrain_instance_lighting.gdshaderinc`

与贸易商队使用完全相同的：

- `day_phase`、`season_phase`、`day_night_enabled`；
- 太阳/月亮方向和高度；
- `tod_exposure`；
- 地表法线纹理与 `terrain_normal_influence`；
- terrain horizon 遮挡与 softness；
- GI horizon LUT、AO 和 bent normal；
- tiled / non-tiled 地图采样变体；
- `visual_quality`。

每个 formation 实例在 vertex 阶段以实例世界中心采样一次地图光照，不在 fragment 阶段逐像素读取地形纹理。

### 11.2 体与影

formation body 与 shadow 使用同一个 shader 和两个材质参数：

- body：`shadow_pass=false`；
- shadow：`shadow_pass=true`。

阴影要求：

- 与世界太阳方向 `sun_dir` 一致；
- 由当前实例高度、footprint 和最大投影长度计算；
- 受 `local_day`、`direct_visibility` 和太阳在地平线上方的条件门控；
- 使用软边 alpha，不引入斜向烘焙阴影；
- 仅在高质量桌面路径显示，低画质和 Web 路径关闭；
- 阴影完整留在水平地图平面内。

body 和 shadow 必须共享同一个 `MultiMesh` 实例缓冲。两个 `MultiMeshInstance2D` 可以有不同的材质和可见性，但实例矩阵、custom data、动画帧和阵营 tint 必须同源。

### 11.3 当前实现状态

- 共享 include 和贸易 shader 重构已在源码中存在。
- formation shader 已包含 body/shadow 分支、地图光照采样和 tiled 变体接线。
- body/shadow 两个节点已在源码中引用同一个 MultiMesh。
- 以上均尚未完成 v4 shader 编译、两种地图采样变体测试和正式地图昼夜/地形目视验收，不能标记为通过。

## 12. 三档 LOD

| LOD | 缩放 | 地图表现 | 目标 |
| --- | --- | --- | --- |
| `aggregate` | `< 0.35` | 每格一个代表 token | 保持战略态势，限制实例数 |
| `representative` | `0.35–0.70` | 每支部队一个代表 sprite | 低成本读出主导原型 |
| `formation` | `> 0.70` | 每支部队 1–5 个成员 | 读出规模、配比和动作 |

滞回：

- 聚合进入 `< 0.35`，退出 `> 0.37`；
- 代表进入区间约 `0.35–0.70`；
- 代表退出到聚合 `< 0.33`，退出到编队 `> 0.72`；
- 编队退出 `< 0.68`。

注意：正式相机 `fit_to_viewport(..., fill_safe_area=true)` 可能把初始缩放写成交互缩放下限，因此默认地图通常无法自然进入 aggregate。aggregate 截图只能作为测试夹具证据，除非后续相机策略提供正式可达路径。

降级顺序：

```text
formation 1–5 成员
  -> representative 单 sprite
  -> paper token
```

任何一档都不得只画半支编队。预算不足、缺配比、未知 dense unit、缺 atlas 或 shader 无效时，整支部队降级。

## 13. 迷雾、状态与 Fallback

- 己方部队显示。
- 外国部队只在不透明迷雾可见格显示。
- 攻击/受击 cue 必须经过同一迷雾门控。
- 低补给、缺粮、欠饷、低士气、交战、撤退仍由独立状态标记表达。
- 选中圆圈、路径和军事控制区域不进入 formation MultiMesh。
- 缺少图集、composition CSR、shader 或合法映射时回退纸片 token。
- v4 试接入阶段只对玩家部队启用 formation；外国可见部队继续纸片 fallback，后续再评估是否放开。

## 14. 权威数据与只读快照

`MilitaryCore` 仍是军事唯一权威。渲染层只能消费派生只读快照：

| 字段 | 用途 | 是否写 PKMI |
| --- | --- | --- |
| `composition_offsets` | 前三兵种 CSR 行偏移 | 否 |
| `composition_unit` | 前三兵种 dense id | 否 |
| `composition_weight` | 聚合后人数权重 | 否 |
| `heading_q16` | 地图朝向，东为 0 | 否 |
| `attack_seq` | 攻击视觉 cue 序号 | 否 |
| `hit_seq` | 受击视觉 cue 序号 | 否 |

约束：

- CSR offset 必须单调并以 `composition_unit.size()` 结束。
- 每个 army 行最多三个 composition 项。
- dense id 必须通过 catalog view 映射，不能按 `unit_class` 猜原型。
- `army_signature` 与 `army_formation_signature` 分离；cue 变化只更新 custom data，不重建无关布局。
- 行顺序或 handle 变化不得继承旧部队的一次性动作或位置插值。
- 读快照不能 bump revision；revision 只由既有成功写路径推进。
- 旧 DLL 或旧存档缺少新字段时继续使用纸片 token。
- `attack_seq/hit_seq` 当前没有权威事件生产者，不能用交战 flag 伪造；真实 cue 接线属于后续阶段。

## 15. 测试与验收

### 15.1 当前状态声明

现有 v3 atlas、旧地图截图和旧 headless 结果只能证明 v3 管线曾经工作。v4.0 文本直出动作板已整批否决。v4.1 已完成 16/16 动作板、strict atlas/manifest、运行时切换、独立视觉夹具和全部军事 formation headless 测试。正式地图内动作序列仍受当前 runtime day-wait 阻塞，不能把旧地图截图视为 v4.1 证据。

### 15.2 测试命令

纯逻辑测试：

```powershell
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --headless --path Project\project-keynes `
  -s res://tests/military/military_formation_visual_test.gd

& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --headless --path Project\project-keynes `
  -s res://tests/military/military_formation_render_feed_test.gd

& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --headless --path Project\project-keynes `
  -s res://tests/military/military_formation_token_layer_test.gd

& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --headless --path Project\project-keynes `
  -s res://tests/military/military_formation_map_layers_test.gd

& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --headless --path Project\project-keynes `
  --rendering-method gl_compatibility `
  -s res://tests/military/military_formation_shader_lighting_test.gd
```

正式地图视觉验收：

```powershell
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' `
  --path Project\project-keynes `
  --rendering-method gl_compatibility `
  --resolution 1600x900 `
  --script res://tests/military/military_formation_map_visual_harness.gd
```

视觉验收命令不能加 `--headless`。默认输出到 `res://tmp/military_formation_map_visual/`。

### 15.3 v4 资产门槛

- [x] 16 张源动作板全部生成并选定，不允许缺原型或动作。
- [x] 每张源板严格 4×2，八格均有主体。
- [ ] 每格有透明 gutter，主体、武器和效果均不跨格。
- [ ] 严格正俯视、统一朝东，无透视、侧壁、人脸和地平线。
- [x] 八帧固定注册，不逐帧重新居中或缩放。
- [x] 高不透明核心轮廓差满足第 9 节门槛。
- [ ] 只在 48–64 px 可见的烟尘/闪光不能作为区分帧的主要依据。
- [x] v4 atlas 为 1024×2048 RGBA8，8×16，每帧 128×128。
- [x] atlas 禁用 mipmap，采样为 linear，帧边界 alpha 为 0。
- [x] `source_manifest_v4.json` 记录候选、拒绝原因、指标和 SHA-256。

### 15.4 运行时门槛

- [x] v4 catalog 和 `FORMATION_ATLAS_PATH` 已切换，未误用 v3。
- [x] 4 套原型、4 个动作、每动作 8 帧均可采样到。
- [x] 1–5 成员人数档、最大余数分配和布局通过自动测试。
- [x] aggregate/representative/formation 三档及全部滞回边界通过。
- [x] 实例不足时整军降级，不出现半编队。
- [x] body/shadow 的 `MultiMesh` 引用相同，动画帧和 custom data 不漂移。
- [x] shadow pass 使用世界太阳方向、地图 horizon/法线和质量门控。
- [x] tiled 与 non-tiled 两种 shader 变体均能编译并保持参数。
- [x] `clear()` 后重新绑定时，地图光照参数仍能恢复。
- [x] 缺配比、未知 dense unit、缺 atlas、旧 DLL 和不可见敌军的 fallback 正确。

### 15.5 正式地图目视门槛

- [ ] 地图内四套原型均能辨认，不是三视角或纸片轮廓。
- [ ] 四动作各 8 帧连续播放时，相邻帧本身有清晰动作变化。
- [ ] 1–5 成员在近景可读，五成员不互相压成不可分团块。
- [ ] 1–5 成员和 representative/aggregate 切换无明显跳变。
- [ ] 白天和夜间亮度与地形一致。
- [ ] 山地、背坡、森林边缘等 horizon/GI 差异能在 formation 上看到。
- [ ] 投影方向与贸易商队、建筑和地图太阳方向一致。
- [ ] 软投影不穿出地图平面，不产生烘焙式斜向贴片。
- [ ] 雾、顶栏、面板和地图边缘不会导致整批 formation 被错误裁剪。
- [ ] 每类动作必须输出地图内 8 帧序列和 contact sheet/GIF，不能只给单帧。

### 15.6 性能门槛

- [ ] 桌面 1600×900 下记录 formation 实例数、draw call、CPU 上传和帧时间。
- [ ] 400 部队、平均 3 成员、单军最多 5 成员的场景不突破共享 2,048 实例预算。
- [ ] 摄像机连续缩放和跨地图 wrap 不触发每帧全量重建。
- [ ] 低画质和 Web 路径关闭阴影后仍可读。
- [ ] 长时间 soak 未出现 atlas 泄漏、句柄继承或 LOD 抖动。

## 16. 性能预算

| 指标 | 设计要求 |
| --- | --- |
| 原型 fixture | 4 原型 × 5 成员档 × 最多 5 成员 = 60 实例 |
| 正式平均 | 400 部队 × 平均 2–3 成员 ≈ 800–1,200 |
| 实例上限 | 沿用 2,048 共享逻辑上限 |
| v4 atlas 显存 | 1024×2048×4 ≈ 8 MiB 未压缩 RGBA |
| CPU 重建 | 仅 composition、LOD、布局、fallback 或 handle 变化时 |
| 每帧 CPU | 只推进视觉时间、cue 和移动中实例 |
| 地形光照 | 每实例 vertex 采样一次，不在 fragment 逐像素采样 |
| 阴影 | body/shadow 共享 MultiMesh；高质量桌面才启用 |
| 采样 | linear、无 mipmap、透明 gutter |
| 裁剪 | formation 使用世界级 `custom_aabb`；屏幕矩形裁剪仍待实现 |

尚未完成真实 draw call、填充率、shader 编译时长和长时间 soak 测量。性能章节中的数值是预算和验收目标，不是当前实测通过值。

## 17. 风险与缓解

| 风险 | 后果 | 缓解 |
| --- | --- | --- |
| 生图模型回到微动 | 8 帧合法但看不出动作 | pose-to-pose 提示、核心轮廓差门槛、单动作重生成 |
| 固定注册误解为固定身体 | 模型只做呼吸微动 | 明确固定 cell 和 pivot，允许身体/武器/队形大幅变化 |
| 模型漂向侧视或三视角 | 与正俯视地图冲突 | 提示词硬约束、源板和地图内双重验收 |
| 武器/烟尘跨格 | 切图从中间截断 | 每格透明 gutter、边界 alpha 检查、固定裁剪框 |
| 逐帧 bbox 重居中 | 播放时抖动或缩放 | 同动作共用裁剪框和整体比例 |
| 只靠烟尘/闪光制造差异 | 主体动作仍不可读 | 高不透明核心轮廓差和效果掩码分离 |
| atlas mipmap 融合邻格 | 武器跨格或残影 | 禁止 mipmap，linear 采样，padding |
| 光照公式不一致 | 部队与贸易/地形脱节 | 共享 `terrain_instance_lighting.gdshaderinc` |
| 体影动画不同源 | 阴影滞后或错帧 | body/shadow 共享同一个 MultiMesh |
| shader 变体参数丢失 | tiled 地图下变黑或未受光 | 变体切换后重放全部参数，专项测试 |
| LOD 阈值抖动 | 编队闪烁 | 双阈值滞回和整军降级 |
| 24 兵种内容爆炸 | 资产和测试成本失控 | 四套骨架复用，只有明确玩法需求才新增原型 |

## 18. 里程碑与后续

### v4.1：当前过渡基线

1. 16/16 动作板完成并通过 strict source-contract 与动态轮廓 QC。
2. 炮兵 idle 使用无乘员、无射击效果、锁定双炮的专用母版和提示词。
3. v4 atlas 为 `1024×2048` RGBA，SHA-256 为 `e17a9a80c3be7e80d36a1d075c3e20167e3331bb31a721c5d859d21f0787a9c7`。
4. 运行时 catalog、preview layer、生产 token layer 和测试路径已切到 v4。
5. 独立视觉夹具已输出 7 张带 v4 图集的截图；正式地图序列仍待解除 runtime day-wait 阻塞。

### v4.2：video-first 正式生产

1. 为每个原型确定唯一模型生成母版和固定镜头描述。
2. 生成 `idle / move` 循环短片与 `attack / hit` 一次性短片。
3. 使用 `formation_video_pipeline.py` 选择稳定窗口、统一裁切/缩放并生成 4×2 源板。
4. 对炮兵 idle 执行双炮相对位置锁位 QC；对全动作执行核心轮廓、闭包和透明边界 QC。
5. 重建 atlas 后重新执行全部 headless、独立视觉和正式地图内验收。
6. 验收通过前保留 v4.1 作为可回退运行时基线。

### v4.0：已否决

v4.0 的“仅凭文字一次生成整张 4×2 动作板”已被随机朝向、成员变化、跨格武器和动作串戏证伪。该批次只保留为失败样本，不再作为生产流程。

### 后续：真实战斗 cue

- 从战斗结算和交战段落产生只读 `attack_seq/hit_seq`。
- 视觉层消费序号触发一次性动作。
- 同帧 cue 合并、数量上限和迷雾门控。
- cue 不进入布局签名，不写 PKMI 或 state hash。

### 后续：24 兵种内容扩展

1. 24 个 catalog 兵种先完整映射到四套动作原型。
2. 差异优先通过时代装备附件、材质色板、体量和节奏表达。
3. 不默认给每个兵种新增 4×8 专属动作。
4. 只有轮廓无法承载玩法识别时，才新增动作原型。
5. 新原型继续使用同一 8×16 图集契约；超过一页时使用独立 atlas page，不在单页无限加行。
6. 每个新增原型必须重新通过正俯视、朝东、8 帧动态、LOD、光照、阴影和性能验收。
7. 24 兵种映射是数据完整性要求，不是首期美术范围。

## 19. 相关实现与资产

| 路径 | 作用 |
| --- | --- |
| `docs/plans/military-formation-visual.md` | 本文，正式设计合同 |
| `tools/military/formation_v4_prompts.py` | 生成 16 份 v4 生图提示词 |
| `tools/military/formation_v4_identity_pipeline.py` | 单帧母版 → 身份板与 v4.1 图生图提示词 |
| `tools/military/formation_video_pipeline.py` | 视频/透明帧序列 → 稳定窗口 → 固定裁切缩放 → 4×2 源板与 QC |
| `tools/military/generate_formation_prototype_v4.py` | strict 源板 QC、固定注册、atlas 拼装和 manifest |
| `Project/project-keynes/assets/military/formations/prototype/source/v4/prompts/` | v4 单动作提示词 |
| `Project/project-keynes/data/military/military_visual_catalog.json` | 原型、动作、LOD、人数档和 dense unit 映射 |
| `Project/project-keynes/scripts/rendering/military_army_token_layer.gd` | 生产 formation backend、布局、LOD、body/shadow 节点 |
| `Project/project-keynes/shaders/military_formation_sprite.gdshader` | atlas 采样、动作帧、地图光照和 shadow pass |
| `Project/project-keynes/shaders/include/terrain_instance_lighting.gdshaderinc` | 贸易商队与部队共享的地图光照 |
| `Project/project-keynes/tests/military/military_formation_visual_test.gd` | 资产、图集、数值契约和 fallback 测试 |
| `Project/project-keynes/tests/military/military_formation_map_visual_harness.gd` | 正式地图内截图、动作序列和 LOD 验收 |
