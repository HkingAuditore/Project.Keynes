# 贸易载具验证记录（2026-10-19）

## 环境与构建

Windows，AMD Ryzen 9 5900X，NVIDIA RTX 3070 Ti，Godot 4.6.2。
GDExtension `template_debug`、`template_release` 均完成 scons 构建。
功能及图形检查使用桌面 Godot console / debug 扩展；没有把这些结果标成移动真机或
独立 release 导出程序的实测。静态 `git diff --check` 通过。

## 正确性与图形

| 检查 | 结果 |
| --- | --- |
| 原生贸易视觉专项 | 69 项通过：真实陆/水订单、无订单、权限、视野、拓扑失效、重绑、预算、接缝与 A/B |
| 渲染层专项 | 26 项通过：固定批次/容量、低画质、选择优先、暂停、快进、远景、淡出、时代、路径复用与镜头裁剪 |
| ACTIVE worker | 通过：正确的 Country/Economy mask `0x104`，真实订单、正式 facade、后续 worker 提交视图 |
| 正式 player_game | 通过：完整 `0xFFF` worker 推进到约 302 日，无贸易的新局不生成装饰运输；无空路径纹理上传 |
| 原有地图活动 | 29 项通过 |
| 玩家控制器契约 | 通过 |
| OpenGL Compatibility | shader 编译、26 项检查、六组陆/水外观截图通过 |
| Vulkan Mobile renderer | shader 编译、26 项检查、外观与 reduce_motion 截图通过 |

600 点搜索跨片完成，1030 点路线因超过 1024 点上限而省略。
每片 heap pop 不超过 256；这两组样本的原生观察片最大耗时分别约 17µs / 14µs，
缓存报告内存分别约 15.6KiB / 16.2KiB。

A/B 固定 seed 和既有测试 cadence 覆盖值 N/P/I=1/5/10，避免机器计时自适应成为混杂变量。
连续 24 日视觉开/关的经济权威 hash 一致，钱款审计为零，货物审计数值两组一致。
**当前基线货物审计不是零**：例如第 2 日两组都为 `-329808`。因此这里验证了观察者
没有改变结算，不能作为整个经济引擎已经零误差的证明。

原有 `economy_trade_runtime_test.gd` 仍有 8 项失败，涉及既有精度前沿、存档/恢复、
外国路线、卖方重绑与守恒断言。该套件不调用新视觉 API；本改动没有更改对应模拟算法。
原始记录为 `tmp/trade_visual_economy_regression.log`，应另行排查。
Godot 退出还打印项目既有的 RID/ObjectDB/资源释放警告；没有将退出警告算作 shader 或脚本通过。

## 首版性能（历史，未包含本轮地形光照与投影）

1920×1080，单个固定批次，最多 32 路线/96 载具。CPU 每帧取 360 样本，
GPU 分别取开启 360、关闭 240 样本，另取 100 次纯原生路径上传烘焙。
GPU 增量是两组 viewport GPU 时间 p95 的差，不是整个游戏的 GPU 帧时间。

| 场景 | CPU 每帧 p95 | 低频刷新 p95 | 原生上传烘焙 p95 | GPU 增量 p95 |
| --- | ---: | ---: | ---: | ---: |
| 60×40 / Vulkan / 32 点每路线 | 0.053ms | 0.234ms | 0.045ms | 0.027ms |
| 500×400 / Vulkan / 1024 点每路线，跨圆柱接缝平移 | 0.101ms | 0.737ms | 0.407ms | 0.033ms |
| 500×400 / OpenGL / 1024 点每路线，固定镜头 | 0.067ms | 0.259ms | 0.416ms | 0.037ms |

稳定路径不重复上传 512KiB 纹理。表中的 Vulkan 平移样本包括兴趣格重建和裁剪范围更新，
低频刷新仍可能比常规帧耗时高；每帧 p95 小于 0.3ms 的目标，GPU 增量 p95 小于 0.5ms。
新路径的首次固定缓冲上传单独有成本，不承诺每次冷刷新也小于 0.3ms。

这组 500×400 检查使用 20 万格地址空间和最大视觉几何负载，**不是 20 万市场完整经济仿真**。
原生缓存对 20 万格的独立搜索列占约 3.1MiB，heap 与路径均有固定工作/容量上限；
未实测完整 20 万格原生经济进程的新增峰值常驻内存，64MiB 总增量仍需该场景复核。
低画质/移动端 12 路线/24 载具上限已验证，移动真机 GPU/内存尚未测量。

JSON 数据在 `Project/project-keynes/tmp/trade_activity_qa/perf_*.json`，
截图在该目录的 `opengl/`、`vulkan/`。可复现命令：

```powershell
& $godot --headless --path Project/project-keynes --script tests/trade_visual_runtime_test.gd
& $godot --headless --path Project/project-keynes --script tests/trade_visual_worker_test.gd
& $godot --headless --path Project/project-keynes --script tests/trade_activity_runtime_integration_test.gd
& $godot --path Project/project-keynes --rendering-method gl_compatibility --script tests/trade_activity_layer_test.gd -- capture_dir=res://tmp/trade_activity_qa/opengl
& $godot --path Project/project-keynes --rendering-method mobile --rendering-driver vulkan --script tests/trade_activity_perf.gd
& $godot --path Project/project-keynes --rendering-method mobile --rendering-driver vulkan --script tests/trade_activity_perf.gd -- normal
```

## 正俯视与地形光照修正（2026-10-19）

实际资源切换到 `vehicles_topdown_v2.png`，严格垂直正俯视，2 列 × 6 行、每格 2:1，
单个朝东资产按路线旋转；旧斜视八方向图集保留但不引用。本轮只修改美术、GDScript
装配与 shader，没有改动原生交易、寻路、存档和权威 hash 代码。

- Vulkan Mobile 和 OpenGL Compatibility 各 15 项真实 GPU 检查通过：本地昼夜、
  地形坡向、Horizon 直射遮挡、独立天空 GI、legacy/tiled 解码一致、画质门控、
  动态投影及反向太阳、夜间消隐、载具转向比例和解除旧地图纹理。
- 原渲染层 26 项通过；远景断言同时检查载具和阴影批次隐藏。
- 真实订单 ACTIVE worker 回归通过；正式 `player_game` 在 OpenGL 图形模式中通过
  完整 `0xFFF` worker、地图法线纹理引用与可用性、日相位向两个材质同步检查。
- 本轮未触及原生 C++，没有把历史构建或原生 69 项检查标成本轮重新执行。

Vulkan 同一静止货车的平均像素亮度：白昼约 0.344、夜间 0.115；迎光坡约 0.441、
背光坡约 0.184；高 Horizon 遮挡约 0.098。太阳正上方、直射保留时，仅打开天空 GI
使亮度从约 0.465 降至 0.408。legacy 与 tiled 的该组结果一致。开启投影后的覆盖
像素从 3793 增加到 4549，太阳反向时投影方向反转。

性能仍使用上面的 Ryzen 9 5900X / RTX 3070 Ti / Godot 4.6.2，1920×1080。
现在绑定真实 GPU tiled 法线和 Horizon 小纹理、16 项 GI LUT，开启投影，两个绘制批次
共享同一个 96 实例 MultiMesh。CPU 每帧测量还包含渲染器推送的整组 TOD 参数检查，
其中日相位和季节每帧变化；数据刷新、GPU 与原生上传采样数量沿用上文。

| 场景 | CPU 每帧 p95 | 低频刷新 p95 | 原生上传烘焙 p95 | GPU 增量 p95 |
| --- | ---: | ---: | ---: | ---: |
| 60×40 / Vulkan / 32 点每路线 | 0.120ms | 0.710ms | 0.082ms | 0.018ms |
| 500×400 / Vulkan / 1024 点每路线 | 0.141ms | 0.640ms | 0.400ms | 0.073ms |
| 500×400 / OpenGL / 1024 点每路线 | 0.093ms | 0.756ms | 0.383ms | 0.085ms |

这仍是视觉地址空间与几何压力测试，使用合成常量地形纹理来稳定比较光照成本，
不是完整 20 万市场地图或大型地形纹理缓存的端到端测试。所有测试均保留 96 载具容量，
没有为达到指标降低数量。稀疏刷新仍有约 0.6–0.8ms 尖峰，主线程每帧 p95 指标不代表
每一次冷上传、兴趣格重建或低频刷新也小于 0.3ms。移动真机及完整增量 RSS 限制沿用上文。

最终图形夹具截图为 `Project/project-keynes/tmp/trade_activity_qa/lighting_vulkan/`
和 `lighting_opengl/`；`all_styles_topdown.png` 为放大后的六组陆/水外观，
`cast_shadow.png`、`opposite_sun_shadow.png`、`vertical_heading.png` 分别检查投影与转向。
可复现光照检查：

```powershell
& $godot --path Project/project-keynes --rendering-method mobile --rendering-driver vulkan --script tests/trade_activity_lighting_test.gd -- capture_dir=res://tmp/trade_activity_qa/lighting_vulkan
& $godot --path Project/project-keynes --rendering-method gl_compatibility --script tests/trade_activity_lighting_test.gd -- capture_dir=res://tmp/trade_activity_qa/lighting_opengl
```

## 椭圆阴影修正（2026-10-20）

用户实机反馈商队出现多重轮廓。原因是此前阴影 fragment 对载具图集做四次错位轮廓采样，
相邻投影之间仍留下离散轮廓；实际绘制批次一直是本体一次、阴影一次。
现改为每辆载具一个解析柔边椭圆，参照植被的粗略阴影表现，不再读取阴影图集或叠加轮廓。
太阳偏移与长度上限、Horizon 遮挡、夜间消隐及载具中心的 TOD/法线/GI 保持原有边界。

Vulkan Mobile、OpenGL Compatibility 各 16 项图形检查通过；新增仅绘制阴影的 GPU 截图，
验证每条扫描线透明度只有一个连续峰／平台，避免再出现重复轮廓。
方向检查改为比较隔离后的椭圆位置，避免把载具美术轮廓的包围盒误作阴影中心。
原渲染层 26 项回归通过。未重新测量性能，上面的历史计时不代表此次椭圆版实测。

截图在 `Project/project-keynes/tmp/trade_activity_qa/ellipse_vulkan/` 与 `ellipse_opengl/`；
`ellipse_only.png` 为隔离的单个阴影，`ellipse_preview.png` 为色块地面上的放大预览。
