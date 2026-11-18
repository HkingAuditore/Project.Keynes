# 地形解析格界（cell field）落地契约

> 上游方案：`docs/plans/terrain-hex-mesh-implementation-plan.md`（下称「方案」）
> 本文只写**实现契约**：跨语言、跨模块的命名、单位、层布局、函数签名。改任何一侧
> 之前先看这里；与方案冲突时以方案为准，并同步改本文。
> 日期：2026-11-18

## 0. 一句话

像素归属由 `pk_hex_cell_field()`（shader）/ `DCHexCellField.field_at()`（GDScript 镜像）
解析算出；per-cell 属性走一张 offset 空间的 `cell_table`（Texture2DArray，**4 层**：
class / state / aux / class_by_index）；
扭曲场由 C++ 烘焙成 RG8 buffer，进 `terrain_surface_tex` 的 layer6（非 tiled）或
warp tile kind（tiled）。开关 `PK_CELL_FIELD`，**2026-11-18 第二轮末尾起出货默认开**
（关闭时 shader 前缀逐字节还原，可整体回退）。

## 1. 不变量（三处实现必须逐点一致）

| 量 | 定义 | 备注 |
|---|---|---|
| 分数 axial | `q = (√3/3·x − y/3)/s`，`r = (2/3·y)/s` | 与 `HexUtils.world_to_cube` 同式 |
| 对偶三角 | `up = step(1, t.x+t.y)`；`t = fract(a)`；`o = floor(a)` | `c0 = o+(u,u)`、`c1 = o+(1−u,u)`、`c2 = o+(u,1−u)` |
| 重心 | up: `(1−tx−ty, tx, ty)` / down: `(tx+ty−1, 1−tx, 1−ty)` | 顺序固定 c0,c1,c2 |
| 归属 `dom` | `argmax(w_raw)`，平局次序 **0 > 1 > 2** | 三处同一注释锚点，parity 测试依赖 |
| `gap` | `(w_dom − w_i) · √3` ∈ [0, √3] | 沿中心连线 `gap = 2d/hex_size`；与 C++ `edge_distance` 同单位 |
| 带宽上限 | `PK_FIELD_BAND_MAX = 0.86` | 第三格在共享边 gap ≥ √3/2 ≈ 0.866，超过出接缝 |
| 锐化 | `k = 1 − smoothstep(0, band, gap)`；`w = k/Σk` | 类别量用 `w`，连续量用 `w_raw` |
| **AA 带宽** | `band = clamp(max(band_gap, aa), 1e-4, 0.86)`；`aa = 2/hex_size · max(|fwidth(world_pos).x|, |fwidth(world_pos).y|) · terrain_edge_screen_width_px()` | `\|∇gap\| = 2/hex_size` 是精确值；导数**必须取自未回绕的世界坐标**（review 2026-11-18 第 1 条，否则经线接缝炸成 0.86） |
| offset 换算 | `col = q + (r − (r&1))/2`，`row = r` | odd-r |
| 回绕 | 只对 `col` 做 `posmod(map_w)`；**不在 axial 空间取模** | `row` 越界 = padding |
| warp 解码 | `w = (rg·2−1) · terrain_warp_range · hex_size · terrain_warp_amp` | `range=1.6`、`amp=0.4` |

## 2. C++ → GDScript 数据契约

`DCWorldExt::run_bake_terrain_index_pass(knobs)` 返回值**新增**三个键（不改既有键）：

| 键 | 类型 | 尺寸/含义 |
|---|---|---|
| `boundary_warp_buffer` | `PackedByteArray` | `W*H*2`，RG8：`R = clamp_x`、`G = clamp_y` |
| `boundary_warp_range` | `float` | `= 1.6`（编码归一化分母） |
| `boundary_warp_clamped` | `int` | 被 clamp 的通道数（应为 0；非 0 进报告） |

编码（C++ 侧）：

```
total_x = warp_x + hi_x            // 单位：与 C++ 里 (warp_x + hi_x) * warp_scale 的括号内一致
v = clamp(total_x / PK_WARP_RANGE, -1.0, 1.0)
byte = round((v * 0.5 + 0.5) * 255)
```

`PK_WARP_RANGE = 1.6`（`|warp| ≤ 1`，`hi` 再乘 `WARP_HIGH_AMP_RATIO = 0.55` ⇒ 理论上界 1.55）。
写入必须与 height/moist 等 buffer 同行并行、每像素只写自己的 2 字节，无跨行共享写。

`world_ext_bake_visual_tiles.cpp`：tiled bundle 新增 warp 纹理（kind 名 `boundary_warp`），
占用 `visual_map_index_tiles` 腾出的槽位，槽数持平。

## 3. `cell_table` 层契约（Texture2DArray，RGBA8，`map_w × map_h`，1 texel = 1 格）

**offset 空间**（`row * map_w + col`），不是 `cell.index` 空间。发布时按
`DCTerrainIndexBaker.build_cell_inputs()` 产出的 `offset_to_index` 把同一份字节重排一次。

| layer | R | G | B | A | 更新频率 |
|---|---|---|---|---|---|
| 0 `class` | biome | vegetation | cover | landform | 生成期 / 地形改变 |
| 1 `state` | temp | wet | snow | vitality（陆）/ sea_ice（水） | 每日（随 `dyn_lut_changed`） |
| 2 `aux` | fog_k | water_depth（8bit，与 layer5.B 同精度） | flags（预留） | 预留 | 探索 / 水深变化 |

层号常量：shader `PK_CELL_LAYER_CLASS/STATE/AUX = 0/1/2`；
GDScript `DCCellTableBaker`（或 `cell_lut_baker.gd` 内常量）同值。

## 4. Shader 契约

### 4.1 uniforms（新增，由 GDScript 推送）

| uniform | 类型 | 默认 | 说明 |
|---|---|---|---|
| `cell_table` | `sampler2DArray : filter_nearest, repeat_disable` | — | 三层 per-cell 表 |
| `cell_table_dims` | `ivec2` | `ivec2(1,1)` | `(map_w, map_h)` |
| `cell_table_bound` | `bool` | `false` | 数据是否就绪（诊断 + 变体选择依据） |
| `terrain_warp_layer_bound` | `bool` | `false` | layer6 / warp tile 是否烘出来了 |
| `terrain_warp_range` | `float` | `1.6` | 与 C++ 报告同源 |
| `terrain_warp_amp` | `float` | `0.4` | 与 `map_baker.gd::WARP_AMP` 同源 |

`cell_table` + `cell_table_dims` + `cell_table_bound` 放在 `visual_tile_sampling.gdshaderinc`
的 `VT_USE_CELL_TABLE` 块里；`terrain_warp_layer_bound` + `terrain_warp_range` +
`terrain_warp_amp` 放在 `VT_USE_BOUNDARY_WARP` 块里。`cell_table` 一个 sampler 替换陆地
program 里的 `map_index_atlas` + `enum_lut` + `dyn_lut` 三个 ⇒ 净省 2 槽。

### 4.2 `terrain_surface_tex` 第 7 层

```
layer6 = boundary_warp   RG = warp xy（LINEAR，双线性插值保证场连续），BA 预留
```

- `visual_tile_sampling`：`#define TS_LAYER_BOUNDARY_WARP 6.0`，`visual_sample_boundary_warp(uv)`。
- tiled 走 `visual_warp_tiles`（`sampler2DArray` + `visual_tile_address(uv)`）。
- `terrain_surface_layer_count`（GDScript `MapBaker.SURFACE_ARRAY_LAYERS`）`6 → 7`。

### 4.3 define 与 include 顺序

`world_map.gdshader` 在 `VT_USE_*` 段末尾：

```glsl
#ifdef PK_CELL_FIELD
#ifndef PK_WEB_WORLD_MIN
#define VT_USE_CELL_TABLE
#ifndef MAP_VISUAL_TILED
#define VT_USE_BOUNDARY_WARP
#else
#define VT_USE_BOUNDARY_WARP
#endif
#endif
#endif
```

include 位置：`hex_cell_field.gdshaderinc` 必须在 `terrain_surface_detail.gdshaderinc`
之后 include（依赖 `terrain_edge_screen_width_px()` / `terrain_static_biome_is_water()`），
且在 `land_pipeline` / `water_pipeline` 之前：

```glsl
#include "res://shaders/include/terrain_surface_detail.gdshaderinc"
#include "res://shaders/include/hex_cell_field.gdshaderinc"     // 新增
```

### 4.4 公开函数（`hex_cell_field.gdshaderinc`）

```glsl
struct HexCellField {
    ivec2 c0, c1, c2; vec3 w_raw, w, gap; int dom;
    float band;            // [review 2026-11-18] 实际用的带宽（含 AA 下限），view 23 用
};

int  pk_posmod(int a, int m);
ivec2 pk_axial_to_offset(ivec2 qr);
ivec2 pk_axial_to_offset_wrapped(ivec2 qr);
vec2 pk_boundary_warp_world(vec2 wp_wrapped);
// world_pos = **未回绕**的顶点世界坐标；AA 导数取自它（见 §1「AA 带宽」）
HexCellField pk_hex_cell_field(vec2 world_pos, float band_gap);
HexCellField pk_hex_cell_field_default(vec2 world_pos);   // band = terrain_ecotone_width
// 只求归属、**不含 fwidth**：给 P4-1 纹样锚点这类非一致控制流里的调用
ivec2 pk_hex_dom_offset(vec2 world_pos);
ivec2 pk_cell_field_offset(HexCellField f, int i);
ivec2 pk_cell_field_dom_offset(HexCellField f);
float pk_cell_field_dom_weight(HexCellField f);
float pk_cell_field_edge_gap(HexCellField f);
int  pk_cell_field_least(HexCellField f);
int  pk_cell_field_rank(HexCellField f, int rank);
vec4 pk_cell_field_ranked_class(HexCellField f, int rank, vec4 e0, vec4 e1, vec4 e2);
float pk_cell_field_ranked_weight(HexCellField f, int rank);
float pk_cell_field_ranked_weight_raw(HexCellField f, int rank);
vec4 pk_cell_table_fetch(ivec2 c, int layer);
vec4 pk_cell_class_at(ivec2 c) / pk_cell_state_at / pk_cell_aux_at;
void pk_cell_field_classes(HexCellField f, out vec4 e0, out vec4 e1, out vec4 e2);
int  pk_byte_of(float v);
int  pk_cell_biome_of(vec4) / pk_cell_veg_of / pk_cell_cover_of / pk_cell_landform_of;
float pk_pk_field_blend_channel(int channel, vec3 weights, vec4 e0, vec4 e1, vec4 e2);
float pk_field_blend_class_raw(int channel, HexCellField f, vec4 e0, vec4 e1, vec4 e2);
vec4 pk_field_class_of(HexCellField f, vec4 e0, vec4 e1, vec4 e2);
int  pk_cell_field_dom_biome(HexCellField f, vec4 e0, vec4 e1, vec4 e2);
bool pk_cell_field_is_water_dom(HexCellField f, vec4 e0, vec4 e1, vec4 e2);
float pk_cell_hash01(ivec2 c);
ivec3 pk_cell_field_gate_class(HexCellField f, vec4 e0, vec4 e1, vec4 e2, vec4 pixel_noise);
```

### 4.5 采样预算与采样槽（方案 §3.8 / §3.4，评审按此逐条检查）

**采样次数**（最坏情况，分支展平后）：陆地 MID/HIGH = warp 1 + class 3 + state 3 + aux 1
+ `edge_distance` 1（沟谷 crease）+ height 1 + noise 1 + 静态材质 2 = **13**；
LOW = warp 1 + class 3 + state 1 + aux 1 + edge 1 + height 1 + noise 1 + 材质 1 = **10**。
（方案 §3.8 写 12，差的那 1 次是 crease；见 §8 D7。）

**采样槽**（§3.4 原文「净省 2 槽」在 v1 **不成立**，见 §8 D4）：
`cell_table` 是**新增**的 1 个 sampler，旧的 `map_index_atlas` / `enum_lut` / `dyn_lut`
在 P2 仍被声明（`lat_norm` 用 `visual_static_texture_size()`；`cell_indirect` 的 GI 弹射
需要 `cell.index`，而 `cell_table` 是 offset 空间）。实测各变体 sampler 增量：

| 变体 | OFF | PK | Δ |
|---|---|---|---|
| desktop / mobile_low | 14 | 15 | +1 |
| desktop_tiled / mobile_low_tiled | 18 | 20 | +2（+`visual_warp_tiles`） |
| land_only / water_only | 13 | 14 | +1 |
| `PK_WEB_TEXTURE_BUDGET`（**排除**） | 8 | 9 > 8 | 设备上限，故不启用 |

P6 退役三个 legacy sampler 后回到「净省 2」。演练断言由
`tests/world/terrain_shader_variant_test.gd` 的 sampler 普查守着（逐变体等值，不是阈值）。

禁止出现「权重 > 0 才采」的条件采样；过滤采样（材质、warp、噪声）必须在一致控制流里
或用 `textureGrad`；`texelFetch` 无导数，可在任何位置。

## 5. GDScript 契约

### 5.1 `WorldData`（`scripts/geography/world_data.gd`）

```gdscript
var cell_table_tex: Texture2DArray = null        # 三层 per-cell 表
var cell_table_dims: Vector2i = Vector2i.ZERO    # (map_w, map_h)
var boundary_warp_buf: PackedByteArray           # W*H*2，RG8
var boundary_warp_range: float = 1.6
var boundary_warp_clamped: int = 0
var terrain_warp_layer_bound: bool = false
```

### 5.2 CPU 镜像（新 `scripts/geography/hex_cell_field.gd`）

`class_name DCHexCellField extends RefCounted`，纯静态函数，只给测试与 debug 用：

```gdscript
const PK_FIELD_BAND_MAX := 0.86
const PK_FIELD_SQRT3 := 1.7320508075688772
const WARP_RANGE := 1.6
const WARP_AMP := 0.4

static func posmod_int(a: int, m: int) -> int
static func axial_to_offset(q: int, r: int) -> Vector2i
static func warp_world_at(world: WorldData, wp_wrapped: Vector2, hex_size: float) -> Vector2
static func field_at(wp: Vector2, hex_size: float, warp_world: Vector2, band_gap: float) -> Dictionary
    # → { c0, c1, c2, w_raw, w, gap, dom }；c* 为 Vector2i offset
static func dom_at(wp: Vector2, hex_size: float, warp_world: Vector2) -> Vector2i
```

`field_at()` 不得依赖任何纹理；warp 由调用方以 `Vector2`（世界单位）传入，测试可传 `Vector2.ZERO`。

### 5.3 发布（`scripts/rendering/bakers/cell_lut_baker.gd`）

- 发布 `enum_lut` / `dyn_lut` 的同时写 `cell_table` 的 layer0 / layer1。
- `set_cell_fog(offsets)` 之类的新入口写 layer2（fog 变化时）。
- `Texture2DArray.update_layer()` 是否在 GLES3 / WebGL2 上成立由 P0 探针验；不成立则
  退回三张独立 `Texture2D`（槽数与今天相同，不更差），并在 `WorldData` 上换成
  `cell_class_tex / cell_state_tex / cell_aux_tex` 三字段 + shader 三条 `texelFetch` 分支。

## 6. 测试契约（方案 §4.4）

| 测试 | 断言 |
|---|---|
| `tests/world/hex_cell_field_parity_test.gd` | 随机 10 万点：`dom_at` == `cube_round(p+warp)`，100%；纹素中心处 dom == 烘焙 `map_index` 的 cell id ≥ 99.9% |
| 同上 | gap 镜像 vs `edge_distance.R`：`gap < 0.86` 内绝对误差 < 0.02 |
| `tests/world/cell_table_layout_test.gd` | layer0/1/2 每个 texel 与 `cells_by_index[o2i[...]]` 逐字节一致；回绕列正确 |
| `tests/world/terrain_shader_variant_test.gd`（扩展） | `PK_CELL_FIELD` 变体源码不含 `visual_sample_map_index` / `enum_lut` / `dyn_lut` / `decode_edge_secondary_index` / `compute_lake_shore_proxy` |
| `tests/world/terrain_index_edge_bake_test.gd`（扩展） | warp buffer 尺寸、clamp 数为 0、跨经线接缝连续 |
| `tests/world/cell_table_platform_probe.gd`（**需真渲染后端**） | `texelFetch(ivec3)` 分层读写回一致；`update_layer` 单层更新、可重复 |
| `tests/world/cell_field_gpu_parity_probe.gd`（**需真渲染后端**，review 2026-11-18 第 3 条） | view 22 回读 `dom` offset 逐像素对 `DCHexCellField.dom_at`（含回绕接缝 pass）；view 23 回读 `band` 断言接缝处无 0.86 竖线 |

> **headless 陷阱**：Godot 的 `--headless` 用 dummy 渲染器，`get_layer_data` / `Image` 回读全部返回 `null`，
> 这两条测试在 headless 下只能 SKIP。凡涉及「GPU 到底画了什么」的断言都必须用
> `--rendering-driver opengl3` / `vulkan` 真跑；headless 通过 **不能** 作为视觉正确性的证据。

## 7. 写入域划分（并行实现时不要越界）

| 任务 | 允许修改的文件 |
|---|---|
| T1 C++ warp | `gdext/src/world_ext_bake.cpp`、`gdext/src/world_ext_bake_visual_tiles.cpp` |
| T2 GDScript 数据 | `scripts/rendering/bakers/{terrain_index_baker,surface_baker,cell_lut_baker,visual_tile_layout,atlas_encoders}.gd`、`scripts/rendering/visual_tile_set.gd`、`scripts/geography/world_data.gd`、`scripts/rendering/map_baker.gd`、`scripts/rendering/renderer_material_publish.gd`、`scripts/rendering/renderer_lighting_bindings.gd` |
| T3 CPU 镜像 + 测试 | `scripts/geography/hex_cell_field.gd`（新）、`tests/world/hex_cell_field_parity_test.gd`（新）、`tests/world/cell_table_layout_test.gd`（新）、`tests/world/terrain_index_edge_bake_test.gd` |
| T4 shader 核心 | `shaders/include/visual_tile_sampling.gdshaderinc`、`shaders/world_map.gdshader`、`shaders/include/uniforms.gdshaderinc`（仅新增块） |
| T5 陆地管线 | `shaders/include/terrain_surface_detail.gdshaderinc`、`shaders/include/land_pipeline.gdshaderinc` |
| T6 水面管线 | `shaders/include/water_pipeline.gdshaderinc`、`shaders/include/water.gdshaderinc`、`shaders/include/shore_common.gdshaderinc` |
| T7 变体/warmup | `scripts/rendering/renderer_shader_water.gd`、`scripts/rendering/web_shader_warmup.gd`、`tests/world/terrain_shader_variant_test.gd` |

`hex_cell_field.gdshaderinc` 由 lead 独占（已落地，改动需 lead 同意）。

---

## 8. 与方案的偏离记录（实施中确认，方案 §3.x 未覆盖或需修正）

每条都附「为什么」与「谁受影响」，P6 收尾时逐条复核。

| # | 方案原文 | 实施 | 理由 |
|---|---|---|---|
| **D1** | `hex_cell_field.gdshaderinc` 是叶子模块，仅依赖 `uniforms` + `visual_tile_sampling` | 额外依赖 `terrain_surface_detail`（`terrain_edge_screen_width_px()` / `terrain_static_biome_is_water()`）与经它引入的 `pixel_scale`，因此必须**在 `terrain_surface_detail` 之后** include | Godot shader 语言没有函数前向声明。把这两个函数搬进 `pixel_scale` 能恢复「叶子」性质，但会改动 3 个文件的公共契约，收益小于风险；改为在 include 顺序上表达依赖 |
| **D2** | 门控阶段「每格一份世界锚定噪声」（纹理采样） | 复用 SETUP 已采的 `pixel_noise.r`：`jitter_i = fract(pixel_noise.r·3 + hash(cell_i)) − 0.5` | 抖动**必须随位置变化**。整格常量只会把边界整体平移一个固定量（且各对邻格不同），得到光滑但与颜色边界错开的线，不是碎边 —— 这一点在 review 2026-11-18 第 2 条里被指出并改正。复用 `pixel_noise` 不新增采样，仍比"按格采样噪声"省 3 次 |
| **D3** | `aux 1（主导格；水面 program 为 3）` + 「fog 早退改为三格均未探索」 | `fog_k` 取**主导格 1 次 `texelFetch`**；早退改为 `fog_k ≤ k && pk_cell_field_edge_gap(f) >= PK_FIELD_BAND_MAX` | 「三格未探索」等价于「不在任何过渡带里且主导格未探索」，后者只用已有的 `gap` 就能算出，省 2 次采样。也顺带修正了 §3.3 把 `fog_k` 列为类别量（应走 `w`）却被传成 `w_raw` 的问题 —— 取主导格后该歧义消失 |
| **D4** | 陆地 program 净省 2 采样槽 | **桌面/Vulkan 与移动的 PK 变体净 +1（tiled +2）**；**Web/Compatibility 预算变体已解禁**（`terrain-cell-field-web-plan.md`）：旧三槽在 `PK_CELL_FIELD_NO_LEGACY_LUT` 下从**声明**里删掉，四个 Web/Compat 前缀 **8 → 6**，第二 pass 水面 **7 → 4** | 8 槽是 `PK_WEB_TEXTURE_BUDGET` 的**设备**上限（`uniforms.gdshaderinc` 的 `[pk-web-texture-budget]` 注释：第 9 张起被内建白纹覆盖，不报编译错）。Web 上能退役的前提是给 `cell_table` 加一层 `cell.index` 序的镜像（layer3）解掉 GI 弹射对 `enum_lut` 的唯一依赖；桌面的 `bounce_lut` / `cell_indirect` 还有其他读者，仍归 P6 |
| **D5** | `uniform ivec2 map_dims` | `uniform vec2 cell_table_size` | 本项目 shader 侧整数尺寸一律 `vec2`（`lut_dims` / `hm_resolution` / `derived_resolution`），GDScript 用 `Vector2` 推送，跨后端零风险；`ivec2` uniform 在 Compatibility 路径上不可靠 |
| **D6** | `aux.G = water_depth（8bit，与今天 layer5.B 同精度）` | 同一**公式与量化**，但是**格心值**：`cell.water_depth` 是水面高度而非深度，按 `world_ext_bake.cpp:1099-1115` 的同一公式在格心求值 | layer5.B 是逐像素（雕刻后高度），`cell_table` 是逐格 —— 不可能逐字节相同。P3 已把水深改走 `w_raw` 插值，逐像素台阶消失，差异不可见 |
| **D7** | §3.8 陆地 MID/HIGH ≈ 12 | 实际 ≈ 13（`edge_distance` 的 crease 仍要 1 次），LOW ≈ 10 | 方案自己也注明「crease 并入 layer6.BA 前实际 +1」。P6 把 crease 并进 layer6 的 BA 后回到 12 |

### 8.1 已知未完成（P5/P6 范围，v1 不做）

1. **`enum_lut` / `dyn_lut` / `map_index_atlas` 在桌面非预算变体里仍未退役**（D4）。`cell_indirect` 的 `decode_dyn` / GI 弹射、`brdf` 的 bounce albedo、`terrain_surface_debug_color` 的 1–10 档仍读它们。**Web / Compatibility 预算变体已经退役**（`PK_CELL_FIELD_NO_LEGACY_LUT`），见 `terrain-cell-field-web-plan.md`。
2. **调试视图 18 不做「dom vs 烘焙 map_index」比对**：PK 变体不允许采 `map_index`，所以 18 改为「重心 argmax vs 由 offset 反算最近格心」的双路自检；「dom 与烘焙 cell id 一致」这半条断言留在 CPU 侧（`hex_cell_field_parity_test.gd`）。
3. **Web（含桌面 Compatibility）已解禁**（`terrain-cell-field-web-plan.md` W1–W6，2026-11-18 同日落地）：cell_table 增 layer3 `class_by_index` 吸收 GI 弹射对 `enum_lut` 的依赖，四个 Web/Compat 前缀 sampler **8 → 6**，`world_water_web.gdshader` 迁到场函数（7 → 4 槽）。**默认开关仍为关**；浏览器/真机矩阵（W5）待跑。
4. **P4-1 纹样锚点选格**（程序化树点 / 斜线在锚点处调 `dom` 决定画不画）未做。
5. **`WorldData.terrain_warp_layer_bound`** 已由 `surface_baker` 精确置位，但推送侧目前用 `surface_layers >= 7` / `visual_warp_tiles != null`（中性层解码出 0 偏移，视觉无害，只是多 1 次采样）。收口时改成读该字段。

---

## 9. 评审修复记录（2026-11-18 review）

四项全部确认为真问题，均已修。**本节的编号在代码注释里以「review 2026-11-18 第 N 条」引用。**

### 9.1 回绕接缝的 AA 带宽（第 1 条，bug）

旧实现 `float aa = length(fwidth(a)) * √3 * edge_px`，其中 `a` 来自**已回绕**的坐标
（入参 `wp` 已 wrap，函数内又 wrap 一次）。屏幕上跨过经线的 2×2 像素块里 `q` 突然跳
`map_w`（60 格），`fwidth` 爆掉 ⇒ 带宽被 clamp 到 `PK_FIELD_BAND_MAX` ⇒ 接缝处一条
1~2 px 宽、混合拉满的竖线。旧路径没有这个问题，因为它对**采样出来的** `edge_distance`
求导，那个值跨接缝连续。

修法（两处一起改）：
1. 场函数入参语义改为**未回绕**世界坐标（`world_pos`），内部第一句 `wrap_world_pos(world_pos)`；
2. AA 直接取精确梯度：`|∇gap| = 2/hex_size` ⇒
   `aa = 2/hex_size · max(|fwidth(world_pos).x|, |fwidth(world_pos).y|) · terrain_edge_screen_width_px()`。
   取两轴最大值而不是 `length()`：轴对齐缩放下 `length` 会多算 √2（与 `pk_world_per_px_at` 同一取舍）。

回归守：`cell_field_gpu_parity_probe.gd` Pass C —— `terrain_ecotone_width = 0.02` 时
`max(band) < 0.10`。旧实现会在接缝列给出 0.86。

### 9.2 门控抖动做不出碎边（第 2 条）

见 D2。整格常量 jitter ⇒ 胜负线 `w_A − w_B = j_B − j_A` 右侧是常数 ⇒ 边界整体平移，
光滑且与颜色边界错开。改为 `fract(pixel_noise.r·3 + hash(cell_i))`：抖动随位置变化、
三格相位解相关，才是碎边。LOW 档（`PK_QUALITY_LOW`）直接 `argmax(w)`，与 §3.8 的
「LOW 只读主导格」预算一致。

### 9.3 缺 GPU↔CPU 坐标系测试（第 3 条）

见 §6 的两条真后端测试（`cell_table_platform_probe.gd` / `cell_field_gpu_parity_probe.gd`）。
根因是 headless 的 dummy 渲染器读不回像素，而原有 400+ 断言全部在 CPU 侧自比。

**坐标系链条实测属实**（`renderer_map_assets.gd:5-30` → `renderer_scene_services.gd:91-94` →
`world_map.gdshader` 的 `vertex()` → `renderer_material_publish.gd:394-398`）：quad 顶点就是
世界坐标、节点无额外 transform、`v_world` 恒等插值出的世界坐标、五个世界 uniform 全部取
权威来源（`world_bounds.position/size`、`host.hex_size`、`host._wrap_period_x()`、`0.0`）；
像素中心 = `origin + (i+0.5)·step`，与 C++ 烘焙 `world_ext_bake.cpp:1501,1505` 同一约定。

**一处需要澄清的因果**（review 后修正）：`world_origin` / `world_size` **不参与 `dom` 归属**
—— 无 warp 时场函数只用 `v_world`；它们只决定 `pk_boundary_warp_world()` 的采样 uv 与视觉
atlas 的 uv。所以「`world_origin` 推错 ⇒ 整张地图整体错位」的准确表现是 **warp / atlas 错位**，
而不是 hex 归属错位；真正直接进场函数的是 `hex_size`。探针因此加了 **Pass D**：烘一张逐像素
warp 场、开 `terrain_warp_layer_bound`，CPU 用同一批字节重算 —— 只有 uv 映射正确才可能 100% 一致。

新增可回读视图两条：

| view | 内容 | 约束 |
|---|---|---|
| 22 | `dom` offset：`R,G = col 低/高字节；B = row 低字节；A = 1.0` | **A 不能承担 `row` 高字节**：`world_map.gdshader` 是 `render_mode blend_mix`，`alpha = 0` 的片元会把 rgb 一起乘成 0，回读得到清屏色，与"没画"无法区分。`row < 256` 时高字节恒 0，故无损 |
| 23 | 实际带宽 `band / PK_FIELD_BAND_MAX` | 需要 `HexCellField.band` 成员（CPU 镜像不产出，等价物是 `clamp(band_gap,1e-4,0.86)`） |

### 9.4 P4-1 的 fwidth 坑（第 4 条）

`pk_hex_cell_field` 含 `fwidth`，而 P4-1 要在「画不画这个纹样」的分支里按锚点坐标调它 ——
分支内导数未定义（方案 §3.9 第 3 条）。已提供 **`pk_hex_dom_offset(vec2 world_pos)`**：
只做 floor/fract + 平局判定，无导数、无 AA，可在任意控制流里调用。
P4-1 实现时必须用它，不得复用 `pk_hex_cell_field`。

### 9.5 文档修正

§4.5 原来沿用方案 §3.4 的「净省 2 槽」，与 D4 矛盾 —— 已改为「v1 净 **+1**，P6 退役
三个 legacy sampler 后才是 −2」，并给出逐变体的 sampler 实测表。


