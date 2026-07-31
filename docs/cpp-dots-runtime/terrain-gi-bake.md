# 地形 GI 烘焙设计方案

本文描述在现有 8 方向 horizon 图之上补齐地形全局光照的三档实施方案：天空可见度（AO）、
方向化天光（bent normal），以及基于遮挡源 cell 的单次弹射色彩溢出。方案的核心约束是
**几何与颜色解耦**：遮挡几何静态烘焙，地表颜色运行期从 per-cell LUT 实时查取，
因此季节、雪盖、植被枯荣、迷雾等动态变化不触发任何重烘。

配套文档：`visual-tile-rendering.md`（Tile 契约与 horizon compute）、
`computation-pipelines.md`（生成期 pass 清单）。实施完成后两者都必须同步。

## 权威边界

- GI 是纯视觉派生量。不写回 `HexCell`、`MapData`、DataCore slot，不进 PKSV，
  不改变生成 hash、仿真结果或存档。
- 遮挡几何来源仅限 `run_bake_geometry_fields_pass` 产出的全局 `height_buffer`
  与其 Tile 重采样结果，与 horizon 同源同精度。
- 弹射颜色不烘焙。烘焙层只记录"遮挡源是哪个 cell"，颜色由运行期 `bounce_lut` 提供。
- 档 0/1 不新增任何纹理、buffer 或烘焙时间，是纯 shader 改动。

## 现状基线

| 能力 | 现状 | 位置 |
| --- | --- | --- |
| 8 方向 horizon 角 | 已有，4-bit/方向，RGBA8 nibble packed | `visual_tile_horizon_trace.glsl` |
| 直射光遮蔽 | 已有，按太阳方位插值 | `terrain_horizon.gdshaderinc` |
| 环境光 | L1 解析天光 `earth_sky_sh`，非烘焙 | `earth_daylight.gdshaderinc:211` |
| AO | 法线 z 启发式，与遮挡无关 | `land_pipeline.gdshaderinc:123` |
| 天空可见度 / bent normal / 弹射 | 无 | — |

horizon 契约（本方案完全继承）：方向顺序 E/NE/N/NW/W/SW/S/SE 从 +X 逆时针步长 π/4；
每方向存最大遮挡仰角的弧度值，量化到 4-bit 映射 `[0, terrain_horizon_max_angle]`，
默认 `max_angle = 1.309`（75°）；R=E/NE、G=N/NW、B=W/SW、A=S/SE 的 high/low nibble；
高度场在 decode 阶段已用 `max(height, sea_level)` 把海底抬到水面。

## 档 0：天空可见度（AO）

### 推导

设仰角 θ 自水平面 0 到天顶 π/2，天顶角 z = π/2 − θ。cosine-weighted 半球积分的
微元为 `cos(z) dω`，`dω = sin(z) dz dφ`。在单个方位扇区内，遮挡仰角 h 以上的部分可见：

```text
∫[z=0 .. π/2-h] cos(z)·sin(z) dz = ½·sin²(π/2-h) = ½·cos²(h)
```

归一化因子为整个半球的 `∫cos(z)dω = π`。8 个扇区各占 Δφ = π/4，求和后：

```text
V_sky = Σ_d (π/4)·½·cos²(h_d) / π = (1/8)·Σ_{d=0..7} cos²(h_d)
```

这就是 HBAO/GTAO 的解析形式。因为 h_d 只有 16 个离散取值，`cos²` 用 16 项常量表
`GI_COS2_LUT[16]` 查表即可，**不需要任何三角函数调用**。

`max_angle = 75°` 意味着峡谷底的 AO 下限为 `cos²(75°) ≈ 0.067`，天然避免死黑。

### 倾斜法线修正

平法线的 V_sky 用于朝上的面。对倾斜法线按 GTAO 的做法在扇区内做投影修正代价较高，
本方案采用轻量近似：以 bent normal 与几何法线的夹角做一次余弦加权

```text
V_sky_N = V_sky · clamp(dot(N, bent_normal), gi_normal_floor, 1.0)
```

`gi_normal_floor` 默认 0.55，防止陡坡被过度压暗。

### 采样成本

`sample_terrain_horizon_angle` 已经为规避 nibble 的硬件滤波问题做了 4 次 NEAREST tap
手动 bilinear，但每 tap 只解 2 个 nibble。档 0 需要解满 8 个 nibble，**纹理采样次数为零增量**。
方案要求把该函数重构为一次采样同时产出 `direct_visibility` 与 `V_sky` 的
`TerrainHorizonSample` struct，避免两条路径各采 4 次。

估算增量约 60 ALU/陆地像素。

## 档 1：Bent normal 与方向化天光

### 推导

第 d 个扇区的可见锥在仰角上从 h_d 张到 π/2，其 cosine-weighted 质心仰角近似取中点
`m_d = (h_d + π/2)/2`，扇区权重即该扇区的可见度 `w_d = cos²(h_d)`。方位方向沿用
trace shader 的 `DIRECTIONS[8]`：

```text
bent_normal = normalize( Σ_d w_d · vec3(DIR_d.xy · cos(m_d), sin(m_d)) )
```

`cos(m_d)` 与 `sin(m_d)` 同样只有 16 个取值，用 `GI_BENT_XY_LUT[16]` /
`GI_BENT_Z_LUT[16]` 查表。全部 w_d 为零（完全封闭）时退化为几何法线。

### 接入

现有环境光项：

```text
ambient = max(sky_sh_ambient_brdf(lc, N), ambient_floor) · albedo · s.ao
```

改为以 bent normal 求天光、以 V_sky_N 作遮蔽：

```text
ambient = max(sky_sh_ambient_brdf(lc, bent_N), ambient_floor) · albedo · V_sky_N
```

`earth_sky_sh` 内已有 `EARTH_SKY_SUNWRAP` 方位散射项，因此山谷朝天空开口的方向
会自动获得对应时刻的天光色温：清晨朝东开口的谷偏暖，被南侧山脊遮住的北坡偏冷。
这是本方案中"看得出是 GI"的主要来源。

估算增量约 30 ALU/陆地像素，仍为零纹理增量。

## 档 2：单次弹射色彩溢出

### 原理

弹射辐照度 `E(p) = Σ_q F(p,q)·ρ(q)·E_direct(q)`。其中 form factor F 是纯几何量（静态），
ρ 是 albedo（动态）。项目里所有随时间改变 albedo 的成分——`dyn_lut` 的温度/湿度/雪盖/
植被活力、`eco_lut` 的叶量/胁迫——**全部是 per-cell 的**，由 `refresh_cell_luts_daily`
每仿真日全量重编码一次。因此把 F 与 ρ 拆开、只烘 F 侧的"遮挡源 cell id"，
运行期查 LUT 取 ρ，即可让弹射色自动跟随所有动态变化。

国界、data overlay、weather overlay、迷雾厚云、BRDF、tonemap 均为独立层或后处理，
不进 `base_color`，与 GI 无关。

### 双遮挡源

按用户选定的双源方案：记录遮挡贡献最大的两个方向上的落点 cell。方向 id 不入库——
运行期从同一张 horizon 图取 top-2 nibble 即可复现，烘焙期与运行期共用同一 argmax 规则：

```text
d0 = argmax_d h_d
d1 = argmax_{d ≠ d0} h_d
w_i ∝ 1 - cos²(h_{d_i})     （归一化到 w0 + w1 = 1）
```

一致性风险：运行期 horizon 走手动 bilinear，4 个 tap 的 argmax 可能不同。缓解方式是
GI occluder 图与 horizon 同为 NEAREST，且 argmax **只用中心 tap 的原始 nibble**，
不使用 bilinear 结果。该规则必须在 shader 注释中显式声明。

退化处理：`cid0 == cid1` 时合并为单源，权重全给 w0；cell id 为 0xFFFF（map 外）或
落点低于海平面时该源权重归零。

### 弹射合成

```text
bounce_albedo = w0 · bounce_lut[cid0].rgb + w1 · bounce_lut[cid1].rgb
bounce = bounce_albedo · lc.sun_color_linear · lc.local_day
       · (1 - V_sky) · gi_bounce_strength
ambient += bounce
```

`(1 - V_sky)` 直接复用档 0 的结果，遮挡权重无需入库。

## 数据契约

### 新增 Tile 字段 `gi_occluder`

| 项 | 值 |
| --- | --- |
| Image 格式 | `Image.FORMAT_RGBA8` |
| bytes/texel | 4 |
| R / G | 主导遮挡源 cell id 的低 / 高字节 |
| B / A | 次遮挡源 cell id 的低 / 高字节 |
| sampler | `filter_nearest, repeat_disable` |
| 哨兵 | `0xFFFF` = 无有效遮挡源 |
| gutter | 与其他字段同一世界坐标契约，2 px |
| 就绪标志 | 与 horizon 共用 `horizon_ready`（同一 compute 产出，原子发布） |

`BYTES_PER_PHYSICAL_TEXEL` 由 18 提升到 22（+22%）。`COMPUTE_TEMP_BYTES_PER_TEXEL`
由 12 提升到 16（compute 期多一份 map_index 输入与一份 occluder 输出）。
两者都会收紧 layout resolver 的密度求解，大地图可能比现在早一档降级，
必须在 `visual_tile_layout_test.gd` 里更新预算断言。

### 新增 per-cell `bounce_lut`

| 项 | 值 |
| --- | --- |
| 格式 | `Image.FORMAT_RGBA8`，NEAREST |
| 尺寸 | 与 `enum_lut` / `dyn_lut` / `eco_lut` 同一 `lut_dims` 网格 |
| RGB | 该 cell 当前地表代表色（sRGB 域） |
| A | 有效性 / 弹射强度缩放，0 表示不参与弹射（水体、map 外） |
| 更新时机 | 并入 `bake_cell_luts` 与 `refresh_cell_luts_daily`，与 dyn/eco 同刷 |
| 字节量 | 6400 cell 约 25 KB，日刷总量 77 → 102 KB |

**代表色是近似量，不追求与 fragment albedo 精确一致。** 弹射项乘了 `(1-V_sky)` 和
一个上限 0.3 的 strength，能量占比极低，公式偏差不可见。刻意不做 CPU/GPU 公式镜像，
避免再引入一处必须永久同步维护的双份实现。CPU 侧近似：

```text
base = biome_base_color[terrain]
base = mix(base, phenology_tint(temp, moist, vitality), phenology_weight)
base = mix(base, SNOW_ALBEDO, snow_cover)
```

### Compute pipeline 增量

`visual_tile_horizon_trace.glsl` 增加一个输入（`map_index` 的 Texture2DArray）与一个
输出 storage buffer（`physical_pixels × 4` bytes）。trace 主循环在 level-0 命中处
额外维护 `best_hit_px[8]`，循环结构与迭代次数不变。conservative tail 与 global fallback
路径下遮挡源置 `0xFFFF`（该射线不参与弹射，但仍参与 horizon 角）。

`visual_tile_horizon_baker.gd` 相应增加一次 `map_index.get_layer_data()` 逐层读取、
一个 storage buffer、一次 readback 与逐层 upload。按 Desktop Auto 15 层 × 516² ≈ 4M
physical texel 估算，增量约 8 MB 传输，horizon bake 总时长预计 +40~50%。
该 compute 在静态 Tile 发布后异步执行，表现为后台补齐延后数百毫秒，不产生卡帧。

### Legacy 全局路径

`encode_bake_horizon_tex_data` 增加可选 knob `emit_occluder_cells`（默认 false，
保持现有调用点逐字节不变）。开启时额外返回 `occluder_data`（RGBA8，与 horizon 同尺寸），
需要 `map_index` 的 R/G/B 输入或等价的 per-pixel cell id buffer。
`run_resample_visual_horizon_layer_pass` 增加对应的 occluder 重采样输出，
供 GPU compute 失败时的 fallback 使用；重采样必须用 NEAREST，禁止对 cell id 做插值。

## 实施分期与文件清单

### 阶段 A：档 0 + 档 1（纯 shader，无需 rebuild DLL、无需重烘地图）

| 文件 | 改动 |
| --- | --- |
| `shaders/include/terrain_horizon.gdshaderinc` | 新增 `TerrainHorizonSample` struct 与一次采样双输出；`GI_COS2_LUT` / bent LUT；`V_sky`、`bent_normal` 求值 |
| `shaders/include/uniforms.gdshaderinc` | 新增 `gi_ao_strength`、`gi_bent_strength`、`gi_normal_floor`、`gi_debug_view` |
| `shaders/include/brdf.gdshaderinc` | `LightingContext` 增加 `sky_visibility` / `bent_normal`；ambient 项改用两者 |
| `shaders/include/land_pipeline.gdshaderinc` | 移除法线启发式 AO；重调 `terrain_horizon_cast_floor` 与 hillshade 避免双重压暗 |
| `shaders/include/water_pipeline.gdshaderinc` | 同步 AO 来源 |
| `scripts/rendering/shrub_layer.gd` | 内联 shader 同步 AO / bent normal，与现有 contact AO 归一 |
| `scripts/rendering/hex_renderer.gd` | 推送新 uniform |
| `materials/world_map_material.tres` | 默认值 |

### 阶段 B：档 2 GPU 路径

| 文件 | 改动 |
| --- | --- |
| `shaders/compute/visual_tile_horizon_trace.glsl` | map_index 输入、occluder 输出、level-0 命中记录 |
| `scripts/rendering/visual_tile_horizon_baker.gd` | 新增 buffer / uniform / readback / upload |
| `scripts/rendering/visual_tile_set.gd` | `FIELD_FORMATS` 与 `upload_gi_occluder_layer` |
| `scripts/rendering/visual_tile_layout.gd` | `BYTES_PER_PHYSICAL_TEXEL` 18→22、`COMPUTE_TEMP_BYTES_PER_TEXEL` 12→16 |
| `shaders/include/visual_tile_sampling.gdshaderinc` | `VT_USE_GI_OCCLUDER` 分支与 tiled/legacy 双实现 |

### 阶段 C：`bounce_lut` 与弹射合成

| 文件 | 改动 |
| --- | --- |
| `scripts/rendering/map_baker.gd` | `bake_cell_luts` / `refresh_cell_luts_daily` 增产 `bounce_lut` |
| `scripts/geography/world_data.gd` | `bounce_lut_tex` 字段 |
| `gdext/src/world_ext_atlas.cpp` | `encode_cell_luts` 增产 bounce 通道（C++ 优先路径） |
| `shaders/include/uniforms.gdshaderinc` | `bounce_lut` sampler、`gi_bounce_strength` |
| `shaders/include/brdf.gdshaderinc` | 弹射项合成 |

### 阶段 D：legacy 与 fallback 对齐

| 文件 | 改动 |
| --- | --- |
| `gdext/src/world_ext.h` / `world_ext_bake.cpp` | `encode_bake_horizon_tex_data` 的 `emit_occluder_cells`；`run_resample_visual_horizon_layer_pass` 的 occluder 输出 |
| `scripts/rendering/bakers/atlas_encoders.gd` | 全局 occluder 纹理上传 |
| `scripts/rendering/hex_renderer.gd` | fallback 路径同步 occluder |

阶段 A 独立可交付可回滚。阶段 B/C/D 必须一起上线：只有 B 而无 C 时 occluder 图无消费者，
只有 C 而无 D 时 legacy 与 fallback 路径会与 tiled 视觉不一致。

## 参数

| uniform | 默认 | 作用 |
| --- | ---: | --- |
| `gi_ao_strength` | 1.0 | V_sky 对 ambient 的作用强度，0 = 回退到现有行为 |
| `gi_bent_strength` | 1.0 | bent normal 相对几何法线的混合量，0 = 用几何法线 |
| `gi_normal_floor` | 0.55 | 倾斜法线修正下限，防陡坡过暗 |
| `gi_bounce_strength` | 0.18 | 弹射项增益，建议不超过 0.30 |
| `gi_debug_view` | 0 | 0=off 1=V_sky 2=bent normal 3=occluder cell id 4=bounce only |

每一档都能通过把强度归零精确回退到当前行为，这是视觉回归定位的主要手段。

## 风险与缓解

**双重压暗（最高风险，属调参而非技术）。** 目前已有三层独立暗化叠加：`hillshade`
作为直射乘子、`terrain_horizon_cast_floor` 的制图学投影（`land_pipeline.gdshaderinc:601-607`）、
以及被替换掉的法线启发式 AO。接入真 AO 后山谷必然过暗，`cast_floor` 与
`hillshade_strength` 必须重调。阶段 A 单独交付正是为了隔离这一组调参。

**4-bit 量化 banding。** `d(cos²h)/dh = -sin(2h)`，在 h ≈ 45° 处绝对值取最大 1。
5°/级折合单扇区 ΔV ≈ 0.087/8 ≈ 1.1%，八扇区量化误差不相关，合成 RMS ≈ 0.4%。
叠加已有的手动 bilinear 后预期不可见。若实测出现 banding：优先把
`terrain_horizon_max_angle` 由 75° 降到 60° 换取有效精度，其次加 dither，
最后才考虑升 RGBA16（+4 B/texel）。

**8 扇区星芒。** 长直山脊上分段常数扇区会产生八重对称伪影。缓解方式是对相邻扇区
做仰角线性插值后再积分（GTAO 内积分做法），纯 ALU，可作为 `visual_quality >= 2` 的增强档。

**argmax 一致性。** 见档 2 一节，必须用中心 tap 原始 nibble，且烘焙与运行期规则同源。

**预算降级。** +4 B/texel 会让 layout resolver 更早触发密度降级。上线前需要在
100×64 / `hex_size=22` 的大地图上确认 Desktop Auto 与 High 的解析结果，
若掉档超过一级则考虑把 occluder 降为单源 RG8。

**档位门控。** 现有 `terrain_horizon_direct_visibility` 在 `MOBILE_QUALITY_LOW/MID`
直接返回 1.0。AO 比直射遮蔽便宜（无需按太阳方位插值，可完全静态），
建议移动端 MID 开 AO 但仍关直射遮蔽与弹射；LOW 全关。

**水下地形。** decode 阶段的 `max(height, sea_level)` 使海底不自遮蔽，海底峡谷无 AO。
这是既有的、也是期望的行为，仅需在文档与测试注释中记录，不做修改。

## 测试与验收

新增自动测试：

- `terrain_gi_horizon_math_test.gd`：对若干解析构型（平地、45° 单侧墙、
  全封闭井）校验 V_sky 闭式解与数值半球积分的偏差在 2% 内；校验全零 horizon 时
  V_sky = 1、bent normal = 几何法线。
- `visual_tile_gi_occluder_test.gd`：occluder 图尺寸、hash 确定性、
  环绕 gutter 一致性、`0xFFFF` 哨兵覆盖率；同一世界坐标在不同 Tile 分辨率下
  解析到同一 cell id。
- `visual_tile_layout_test.gd`（扩充）：22 B/texel 下的 resident/peak 预算断言，
  以及大地图不因新字段直接跌回 legacy。
- `visual_tile_horizon_smoke_test.gd`（扩充）：双 buffer dispatch / readback / upload。

诊断报告增量：horizon 报告增加 `occluder_output_bytes`、`occluder_hash`、
`occluder_sentinel_ratio`（哨兵占比，异常偏高说明 trace 命中记录有问题）；
LUT 报告增加 `bounce_lut_bytes` 与编码耗时。

人工验收（headless 不可替代）：

- 雪山邻谷与红色荒漠峡谷（badlands / mesa）两类场景的弹射色可辨识度。
- 一整个昼夜循环内山谷天光色温随太阳方位的变化连续、无跳变。
- 跨季节切换与一次降雪事件后弹射色跟随变化，且**未触发任何重烘**。
- Windows D3D12 与 Android Vulkan 真机的 LOW/MID/HIGH 编译与截图。
- 峰值内存与 GPU p95 相对基线的回归幅度。

## 文档同步

实施完成后必须同步：

- `visual-tile-rendering.md`：`Texture2DArray` 契约表新增 `gi_occluder` 行；
  bytes/texel 合计由 18 改 22；Horizon Compute 一节补充 occluder 输出；
  诊断与验收一节补充新报告字段与新测试入口。
- `computation-pipelines.md`：生成期 pass 清单补充 occluder 产出；
  若 `encode_cell_luts` 增产 bounce 通道，同步其 I/O 契约。
