# 地图信息菜单复用调研

## 结论

采用项目现有 Font Awesome Solid 字体、`IconBadge`、`UITokens`、`UIAnimation`、
`DataOverlayLayer` 和 cell-index LUT 架构，不引入第三方 UI/overlay 插件。

## 候选与证据

| 候选 | 成熟度与适配 | 结果 |
| --- | --- | --- |
| [Font Awesome](https://github.com/FortAwesome/Font-Awesome) | 已在仓库内随许可证分发；现有 `IconBadge` 和 Theme 已接入；战略地图所需地理、天气、资源轮廓覆盖充分。 | 采用，扩展语义键。 |
| [Material Design Icons](https://github.com/Templarian/MaterialDesign) | 图标覆盖广，但会新增字体、许可证资产和第二套语义映射。 | 不采用。 |
| [Material Symbols](https://github.com/google/material-design-icons) | 可变轴与样式完整，但视觉重量与现有 Font Awesome/黄铜 UI 不一致，集成成本更高。 | 不采用。 |

按维护活跃度、许可证、离线可用、现有设计一致性、Godot 集成成本和所需轮廓覆盖评分，
Font Awesome 为 99/100，Material Design Icons 为 90/100，Material Symbols 为 81.5/100。

## 仓库复用落点

- 渲染：扩展 `DataOverlayLayer` 与 `data_overlay.gdshader`，沿用
  `enum_atlas_tex.GB → cell ID → lut_dims`。
- 编码：在 `DataOverlayBaker` 增加 `bake_cell_lut()`；旧 `bake()`/`encode_overlay_atlas`
  保持 debug 兼容。
- UI：新增一个薄的 `MapOverlayToolbar` 组件，复用 `UITokens`/Theme/`UIAnimation`；
  不建立平行 UI 框架。
- 资源：复用 `ResourceProfileRegistry` 的顺序、发现条件、reserve schema binding，
  并集中注册语义图标和固定参考储量。

## 风险与缓解

- 字体图标无法表达全部资源细节：profile 的 `Texture2D icon` 优先；语义键作为统一轮廓 fallback，
  未注册项开发期告警。
- 旧 debug overlay 与玩家路径混用：接口和文档明确拆分，玩家专项测试断言 path 为 `cell_lut`。
- LUT 尺寸有尾部空 texel：遵守 `WorldData.lut_dims`，尾部保持透明；仍远小于 derived-size atlas。
