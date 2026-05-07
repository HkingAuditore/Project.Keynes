---
name: hex-map-natural-boundary-polish
overview: 优化 Godot 六边形地图的地形/海岸边界表现，弱化格子硬分界，让视觉更接近参考图中的真实地理地图。重点在现有 HexRenderer 与 shader 管线内改进边界融合、覆盖层和参数，不引入新渲染子系统。
todos:
  - id: verify-rendering-chain
    content: 使用 [skill:civ-grounded-development] 与 [subagent:code-explorer] 复核渲染链路
    status: completed
  - id: fix-neighbor-packing
    content: 修复 hex_renderer.gd 邻居地形权重打包
    status: completed
    dependencies:
      - verify-rendering-chain
  - id: tune-terrain-shader
    content: 调优 hex_terrain.gdshader 有机融合与格纹弱化
    status: completed
    dependencies:
      - fix-neighbor-packing
  - id: soften-edge-overlay
    content: 重做 hex_edge_overlay.gdshader 柔和边界覆盖
    status: completed
    dependencies:
      - tune-terrain-shader
  - id: align-palette-verify
    content: 微调地形配色并验证 60x40 地图性能
    status: completed
    dependencies:
      - soften-edge-overlay
---

## User Requirements

- 优化当前六边形地图的地形视觉表现，重点解决六边形与六边形之间分界线过于生硬、规则、拼块感强的问题。
- 参考用户提供的真实地理地图效果，让陆地、海岸、山地、森林、平原、沙漠等区域更像连续自然地貌，而不是单个六边形色块拼接。
- 保留策略地图的六边形格子可读性，但弱化地形边界的硬折线和深色切割感。

## Product Overview

当前地图是程序化生成的六边形地理地图，需要通过渲染层优化，让地貌色带、海岸线和不同地形之间的过渡更柔和、更有机，整体观感接近参考图中的连续地理地图。

## Core Features

- 地形交界自然融合：相邻不同地形之间加入柔和渗透、噪声破碎和宽过渡带。
- 海岸线真实化：水陆边界形成不规则、柔和、带浅滩和沙滩晕染的连续海岸效果。
- 弱化六边形拼块感：减少单格亮度差、硬边暗线和规则边界强调。
- 保持玩法数据不变：不改变地图生成结果、地形类型、通行性和河流逻辑，只优化视觉呈现。

## Tech Stack Selection

- 引擎与语言：沿用当前 Godot 项目与 GDScript。
- 渲染方式：复用现有 `Node2D`、`MeshInstance2D`、`ArrayMesh` 和 `canvas_item` shader。
- 着色器：继续使用 `Project/project-keynes/shaders/hex_terrain.gdshader` 与 `Project/project-keynes/shaders/hex_edge_overlay.gdshader`。
- 数据来源：沿用 `MapData`、`HexCell`、`TerrainType`、`HexUtils`，不改地图生成与玩法规则。

## Implementation Approach

本次优化以“修复已存在但未真正生效的邻居融合机制 + 降低边界覆盖层硬线感 + 增强海岸与地貌的连续晕染”为核心。当前代码中 `hex_terrain.gdshader` 已具备邻居地形混合、domain warp、边缘噪声等能力，但 `hex_renderer.gd` 实际传入的 perimeter 顶点仍主要是 self 数据，并且 shader 参数把混合权重关闭，因此视觉上仍像离散六边形拼块。

关键技术决策：

- 不新增地图生成子系统，避免影响地形分布、通行性和存档语义。
- 在 `hex_renderer.gd` 中启用并修正邻居地形属性打包，让 shader 能在六边形边缘实际采样相邻地形颜色。
- 保留 `CUSTOM1.xy` 作为当前格 cube 坐标用于 shader 归属裁切，同时使用 `CUSTOM1.zw` 存放左右邻居方向权重，避免新增不确定的顶点通道。
- 将陆地交界从“深色细线”调整为“宽、低透明、色彩渗透的柔和过渡带”，减少像棋盘格边界的割裂感。
- 海岸线继续复用现有 coast shape overlay 和 coastline ribbon，但降低单段 hex 边的规则感，提高连续链条的视觉主导性。
- 性能上仍是一次性重建网格，复杂度约为 O(cell_count + boundary_count)。60x40 地图约 2400 格，边界 overlay 与 shader 额外采样可控；避免每帧 CPU 重算，仅在重新生成、缩放参数变更时重建。

## Implementation Notes

- 当前工作区已有未提交改动，实施时必须只做定点修改，避免覆盖 `main.gd`、`main.tscn`、`terrain_type.gd` 等已有用户改动。
- `hex_renderer.gd` 的 `_collect_corner_neighbors()` 已存在但当前 terrain mesh 没有真正用于 perimeter 顶点，应优先复用。
- `hex_terrain.gdshader` 当前同时把 `v_cust1.xy` 当作 cube 坐标、又用 `v_cust1.x - v_cust1.y` 做方向信号；需要改为 `v_cust1.z - v_cust1.w`，避免 q/r 坐标污染混合方向。
- `domain_warp_amp` 不宜一次调太大；需与 `hex_overscan` 配套，避免 fragment 裁切后出现孔洞或拖尾。
- 陆地边界 overlay 应降低暗色中心线权重，优先使用地形混合色、浅色沉积、湿润/风化色块。
- 减少 shader 内每格随机亮度差，改为更连续的世界坐标噪声，避免同类地形内部也出现六边形马赛克感。
- 不记录大规模日志；如需警告，沿用现有 `push_warning`，不输出地图完整数据。

## Architecture Design

现有渲染链路保持不变：

1. `main.gd` 生成 `MapData`。
2. `HexRenderer.set_map()` 接收地图并触发 `_rebuild()`。
3. `_rebuild_terrain_mesh()` 生成基础地形 mesh，并向 shader 传入地形、海拔、海岸度、邻居权重与当前格坐标。
4. `hex_terrain.gdshader` 根据本格与邻居地形，在边缘区域做有机混合、噪声扰动和连续纹理着色。
5. `_rebuild_edge_overlay()` 生成水陆与陆地交界 overlay。
6. `hex_edge_overlay.gdshader` 负责柔化边界、海岸泡沫、浅滩、沙滩与低透明色彩渗透。
7. 河流渲染保持现有层级，不作为本次主要改动目标。

## Directory Structure

本次为现有 Godot 渲染效果优化，只修改渲染相关文件。

```text
Project/project-keynes/
├── scripts/
│   ├── rendering/
│   │   └── hex_renderer.gd
│   │       # [MODIFY] 六边形地图主渲染器。
│   │       # 修复 terrain mesh 顶点邻居数据打包，启用 _collect_corner_neighbors()。
│   │       # 调整 shader 参数、hex_overscan/domain_warp 配套值、陆地与海岸 overlay 宽度和透明度。
│   │       # 保持 _rebuild() 流程与现有 MeshInstance2D 层级不变。
│   └── terrain_type.gd
│       # [MODIFY, 可选] 地形基础颜色表。
│       # 仅在需要统一 overlay/detail 取色时微调颜色协调性。
│       # 不改变地形枚举、通行性、移动消耗和玩法属性。
└── shaders/
    ├── hex_terrain.gdshader
    │   # [MODIFY] 主地形 canvas_item shader。
    │   # 修正邻居混合方向权重读取，启用柔和边缘融合。
    │   # 降低每格随机亮度差和硬边暗化，增强跨格连续地貌纹理。
    └── hex_edge_overlay.gdshader
        # [MODIFY] 地形交界与海岸覆盖层 shader。
        # 陆地交界改为低透明、宽过渡、少暗线。
        # 海岸边保留浅滩、沙滩、泡沫和连续 coastline ribbon 的自然晕染。
```

## Key Code Structures

无需新增公共接口。核心调整集中在既有顶点属性契约：

- `COLOR.rgba`：继续承载本格地形、海拔、海岸度、seed/river proximity。
- `UV.xy`：继续承载局部 hex 坐标。
- `CUSTOM0`：承载 self/left/right 地形 id 与 self 权重。
- `CUSTOM1.xy`：继续承载当前格 q/r 坐标，用于 shader 归属裁切。
- `CUSTOM1.zw`：改为承载 left/right 邻居方向权重，用于 shader 判断边缘更靠近哪个邻居。

## Agent Extensions

### Skill

- **civ-grounded-development**
- Purpose: 按项目既有架构复核 Godot 六边形地图生成、渲染、地形与玩法数据边界。
- Expected outcome: 确保优化只影响视觉渲染，不误改地图生成、地形规则和通行性。

### SubAgent

- **code-explorer**
- Purpose: 在实施前进一步定位渲染链路、shader 参数和相关回归点。
- Expected outcome: 明确所有受影响文件与调用关系，避免遗漏或覆盖已有改动。