# 格子场（cell field）Web / Compatibility 解禁方案

> 状态：**已实施（W1–W4、W6；W0/W5 的浏览器矩阵待跑）**，2026-11-18 起草并当日落地。
> 实施记录见 §9。上游：`terrain-hex-mesh-implementation-plan.md`（总方案，下称「总方案」）、`terrain-cell-field-contract.md`（实现契约，下称「契约」）。
> 本文替代总方案 P6 和契约 §8.1 第 3 条里「Web 等旧数据通道全部退役后再启用」的说法：Web 解禁**不依赖** P6，可以单独推进。

---

## 0. 一页结论

- **卡点只有采样槽。** 场函数用到的 GLSL 特性（`sampler2DArray` + `texelFetch(ivec3)`、`fwidth`、highp float、整数位运算）在 WebGL2 / GLSL ES 3.00 里都有，不需要扩展。v1 排除 Web 的唯一硬理由是：预算变体（`PK_WEB_TEXTURE_BUDGET`）的陆地 program 已经用满 8 个 sampler，`cell_table` 会是第 9 个，被引擎静默替换成白纹理（契约 §4.5、D4）。
- **旧三槽在 Web 上可以提前退役。** Web 预算变体本来就不声明 `bounce_lut`（`uniforms.gdshaderinc:85`）。启用新路径后，Web 对 `map_index_atlas` / `enum_lut` / `dyn_lut` 唯一不可替代的依赖是 GI 弹射近似 `gi_packed_bounce_color(cid)`（`brdf.gdshaderinc:81`）：遮挡层存的是 `cell.index`，要按它查 biome。给 `cell_table` 加一层**按 `cell.index` 排列的镜像**，这条依赖就解开了。四个 Web/Compat 前缀的陆地与水面 program 槽位都从 **8 降到 6**。
- **`PK_WEB_WORLD_MIN` 与场函数正交。** world-min 的作用是把**水面着色源搬到第二 pass**（避开 FXC 双着色源悬崖），它并不是「不渲染陆地」；它提供的叶子只有 `cell_lut_uv` / `water_wrap_*`，完全不引用被退役的三张表。因此 Web LOW 陆地**可以**既保留 world-min 又走场函数 —— 否则 Web LOW 会变成「陆地用索引图判水陆、水面用场函数判水陆」，海岸必然错开 1~2 px。**初稿把 world-min 列为「继续走旧路径」是错的，已修正（§1.2）。**
- **稳健的核心是让错误报出来，不是把槽位数对。** Web 上最危险的是三种不报错的失败：sampler 超限变白纹理；纹理不完整，采样恒为黑；水陆判定不一致，海岸出洞。本方案按这三条设计防线：
  1. 在宏下**删掉旧声明**，残留引用直接变成编译错误；
  2. 测试**逐个变体统计 sampler 数**，不再靠注释记上限；
  3. 启动时跑**离屏自检**，不通过就自动回退旧路径；
  4. 陆地和水面**由同一个判断口决定开关**。
- **只编一套变体。** WebGL 没有 program 二进制缓存，首编就是 warmup 的大头（world_map 约 4.6 s，总 warmup 约 35 s）。新旧路径的选择必须在 warmup **之前**定下来，只预热选中的那一套。

---

## 1. 范围

### 1.1 本方案覆盖

| 变体 | 前缀来源（`renderer_shader_water.gd`） | 本方案后 |
|---|---|---|
| Web LOW 陆地（MICRO / NO_MICRO） | `WORLD_MAP_WEB_PREFIX_MICRO` / `WORLD_MAP_WEB_PREFIX` | 可带 `PK_CELL_FIELD`（**保留** `PK_WEB_WORLD_MIN`：水面仍在第二 pass） |
| Web LOW 水面第二 pass | `WATER_PASS_PREFIX` + `world_water_web.gdshader` | 迁移到场函数，宏 `PK_WATER_FIELD_MATCHES_LAND` 跟随陆地 program 的数据源 |
| Web PC-HIGH 陆地 / 水面 | `WORLD_MAP_WEB_HIGH_PREFIX` / `WATER_WEB_HIGH_PREFIX` | 可带 `PK_CELL_FIELD` |
| 桌面 Compatibility（同为预算变体） | 同上 | 随 Web 一起解禁 |

### 1.2 不覆盖

- **`PK_WEB_WORLD_MIN` 降级程序的「形式」不变，但它不再排除场函数。** 它的职责是「水面交给第二 pass」，与格界来源正交；W2 之后 `world-min + PK_CELL_FIELD` 编译通过且是 6 槽（初稿把这条写成「继续走旧路径」是错的，见 §0 第三条）。
- **迷雾、天气、军事等独立 shader**：属于总方案 P5，桌面也还没迁。v1 的已知差异（迷雾边和地形边不完全重合）在 Web 上同样存在，不额外处理。
- **桌面 Vulkan / 移动的旧三槽退役**：仍归 P6。本方案在 cell_table 里新增的那一层对它们也适用，但这次不动它们的声明。

---

## 2. 依赖盘点：启用新路径后谁还在读旧三槽

按 `PK_CELL_FIELD && PK_WEB_TEXTURE_BUDGET` 展开后仍可达的读取点：

| 读取点 | 读什么 | 处理 |
|---|---|---|
| `brdf.gdshaderinc:90` `gi_packed_bounce_color(cid)` | `enum_lut[cell.index].r`（biome） | 改读 `cell_table` 新增的 layer3（§3.1） |
| `cell_indirect.gdshaderinc:21,45` `decode` / `decode_dyn` | `map_index` 的 gb → cid → `dyn_lut` | 场函数路径下应已不调用；W2 删声明后由编译器确认 |
| `world_map.gdshader:597` `_Hf = visual_static_texture_size().y` | `map_index_atlas` 的尺寸，用来算 `lat_norm` | 改为 uniform（或由 `world_pos` / `world_size` 推算），不再借纹理尺寸 |
| `terrain_surface_debug_color` 档 1–10 | enum / dyn | Web 预算变体 + PK 下编译剔除，输出品红色占位 |
| `water.gdshaderinc` `water_biome_weights(uv, …)` 环形采样 | `map_index` | 确认 PK 下只走 `water_biome_weights_field`；W2 删声明后由编译器确认 |
| `world_water_web.gdshader:48-49,503` | enum / dyn / `map_index` | W3 整体迁移 |

表里标「由编译器确认」的几项，**不靠人工 grep**，靠的是 §3.2 的删声明。漏掉任何一处都会直接编不过。

---

## 3. 设计

### 3.1 `cell_table` 新增 layer3：`class_by_index`

| layer | 空间 | R | G | B | A | 更新 |
|---|---|---|---|---|---|---|
| 0 class | offset | 已有 | | | | |
| 1 state | offset | 已有 | | | | |
| 2 aux | offset | 已有 | | | | |
| **3 class_by_index** | **index**：第 i 格放在 `(i % W, i / W)` | biome | vegetation | cover | landform | 与 layer0 同步 |

- 内容就是今天 `enum_lut` 的 RGBA，只是放进同尺寸的数组层里，所以不新增 sampler。
- 前提条件：`cells.size() ≤ map_w × map_h`，`cell_table_layout_test` 里加一条断言守住。如果将来出现非满格地图，index 空间就按 `ceil(n / W)` 行排布，层尺寸不变。
- 弹射路径改成 `texelFetch(cell_table, ivec3(cid % W, cid / W, 3), 0)`。遮挡层的 C++ 编码（存 `cell.index`）不用改，桌面路径也不受影响。
- **否决的另一种做法**：把遮挡层改成存 offset 坐标。这要改 C++ 烘焙、tiled halo 和桌面的 `bounce_lut` 消费，波及面大，收益只是省一层 10 KB 量级的数据。

### 3.2 删声明，让漏改变成编译错误

在 `uniforms.gdshaderinc`、`visual_tile_sampling.gdshaderinc` 和 `world_water_web.gdshader` 里：

```glsl
#if defined(PK_CELL_FIELD) && defined(PK_WEB_TEXTURE_BUDGET)
#define PK_CELL_FIELD_NO_LEGACY_LUT
#endif

#ifndef PK_CELL_FIELD_NO_LEGACY_LUT
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut  : filter_nearest, repeat_disable;
#endif
// VT_USE_MAP_INDEX 同理：PK_CELL_FIELD_NO_LEGACY_LUT 下不定义该开关。
```

- **不写**「声明保留、只是不调用」。那样做，槽位统计是对的，但下一次有人在新路径里误调 `visual_sample_map_index()`，就又回到第 9 槽白纹理的静默错误。
- GDScript 侧的推送（`_shader_mat.set_shader_parameter("enum_lut", …)`）对不存在的 uniform 只会静默忽略，不需要改。但 §3.3 的测试会断言「这些 uniform 在该变体里不存在」，防止有人把声明加回来。
- OFF 路径（不带 `PK_CELL_FIELD`）的前缀和展开结果**逐字节不变**。这条沿用现有的前缀字节契约测试。

### 3.3 sampler 普查：上限变成测试，不再写在注释里

扩展 `tests/world/terrain_shader_variant_test.gd` 现有的 sampler 普查：

1. 枚举 §1.1 表里**所有 Web 和 Compatibility 前缀**，每个前缀分 OFF / PK 两份，用 `RenderingServer.shader_get_parameter_list` 或展开后的源码统计 sampler uniform 数。
2. 断言每份 **≤ 8**，超出时打印完整 sampler 清单。
3. 目标值写成**等值断言**（比阈值更严，多一个、少一个都要人来确认）。**实测值（W2 实施后）**：

   | 前缀 | OFF | PK | PK 清单 |
   |---|---|---|---|
   | `WORLD_MAP_WEB_PREFIX` | 8 | **6** | `height_tex / terrain_horizon_tex / noise_tex / terrain_material_tex / terrain_surface_tex / cell_table` |
   | `WORLD_MAP_WEB_PREFIX_MICRO` | 8 | **6** | 同上 |
   | `WORLD_MAP_WEB_HIGH_PREFIX` | 8 | **6** | 同上 |
   | `WATER_WEB_HIGH_PREFIX` | 8 | **6** | `height_tex / terrain_surface_tex / water_depth_tex / ocean_current_flow_tex / noise_tex / cell_table` |
   | `world_water_web.gdshader`（第二 pass，独立程序） | 7 | **4** | `height_tex / terrain_surface_tex / ocean_current_flow_tex / cell_table` |

   初稿把水面 HIGH 写成「OFF − 2 + 1」，实际是 **OFF − 2**（`map_index_atlas` 与 `enum_lut`/`dyn_lut` 一起退役，只补 `cell_table`）；第二 pass 是 **OFF − 4 + 1**（另加 `water_depth_tex` 也失去全部读者）。
4. 断言 PK 变体里不存在 `enum_lut` / `dyn_lut` / `map_index_atlas` 三个 uniform。
5. 修正 `uniforms.gdshaderinc:108` 那段已经过时的槽位注释（写的是 7 个、留 1 个余量，实际是 8 个），改成「以 `terrain_shader_variant_test` 为准」。

### 3.4 WebGL 专属的静默坑

| 坑 | 表现 | 约束 |
|---|---|---|
| 纹理不完整（要求 mipmap 过滤，但没有 mip 层级） | 采样恒为 (0,0,0,1)，不报错 | `cell_table` 必须 `filter_nearest`，创建时不生成 mip；自检里读金丝雀 texel 能抓到 |
| sRGB 转换 | 查到的 id 被 gamma 改写 | `cell_table` **不加** `source_color`，图像格式是 `FORMAT_RGBA8`，不用 SRGB8_ALPHA8 |
| 整数纹理格式 | 各浏览器支持和过滤规则差异最大 | 只用归一化 RGBA8，16 位 index 拆进两个通道，解码 `int(x * 255.0 + 0.5)` |
| 负数 `%` / `/` | ES 3.00 未定义 | 沿用 `pk_posmod`；`cid % W` 只在 `cid ≥ 0` 后求值 |
| 数组层单独更新 | WebGL2 上 `update_layer` 是否只传一层还没验证 | 不成立就整张重建。60×40×4 层×4B ≈ 38 KB，每天一次，可以忽略；重建后重新绑定 uniform |
| FXC 编译悬崖（Windows Chrome / Edge 经 ANGLE 转 D3D11） | 首编从几秒变成二十秒级 | 遵守总方案 §3.9：过滤采样不进非一致控制流，三格循环手动展开；W5 实测 |

### 3.5 启动自检 + 自动回退

**目的**：把「某个浏览器、某个驱动上的静默错误」变成「自动降级，再打一条遥测」。

**时机**：主菜单 boot 阶段，**在 `WebShaderWarmup.begin()` 之前**。不依赖真实地图。

**做法**：
1. 新建一个专用的小 shader `shaders/debug/cell_field_web_probe.gdshader`，include 同一份 `hex_cell_field.gdshaderinc`，绑定一张合成的 8×6 `cell_table`（4 层，每层内容已知，含一个金丝雀 texel）。
2. 在 16×16 的 `SubViewport`（`UPDATE_ONCE`）里画一个 `ColorRect`，每个像素对应一个预设的世界坐标。输出：
   - R、G：主导格 offset 坐标；
   - B：layer3 按 index 查出的 biome；
   - A：金丝雀 texel 的值。
3. 等两帧后 `get_texture().get_image()` 回读，逐像素和 CPU 的 `DCHexCellField.dom_at` 以及合成表的期望值比对。
4. 全部一致就判 `pass`，否则判 `fail`，并带上第一个不一致像素的坐标和数值。

**判定与回退**：
- 结果写入 Engine meta `pk_web_cell_field_boot`（boot 后固定，沿用 `PK_WEB_MICRO_BOOT_META` 的模式），`_cell_field_active()` 在 Web 上读这个值。
- 结果按 `get_video_adapter_name()` + 驱动版本 + 引擎构建号缓存到 `user://`（Web 上落在 IndexedDB）。同一设备第二次启动跳过自检。构建号变了就重新检查。
- `fail` 时回退旧路径，并上报遥测 `cell_field_probe_fail{adapter, first_mismatch}`。
- URL 参数 `?cellfield=off|on` 作为强制开关，优先级高于自检和缓存，用于线上排查。纯映射函数单独写测试，和 `micro_url_value_enabled` 同构。

**这一层管不到的**：自检用的是专用小 shader，验证的是功能和数学是否一致，**不是**真实 world_map program 的槽位分配。槽位这一项由 §3.2 和 §3.3 在编译期和测试期保证。两层合起来，才覆盖「功能不可用」和「槽位超限」这两类问题。

**代价**：一个约 30 行 shader 的首编（毫秒级），一次 16×16 的同步回读。只在首次启动或构建更新后发生。

### 3.6 warmup：只预热选中的那一套

- `WebShaderWarmup._collect_codes()` 里的 world_map / world_water_web / PC-HIGH 三组前缀，统一改由 `RendererShaderWater` 的同一个函数给出。这个函数读 §3.5 的 boot 结果，和运行期用的是同一个口。
- 现有不变量「预热 = 运行期，逐字节一致」扩展到 PK 变体：测试分别模拟 meta = pass / fail，断言 warmup 计划里的每个 code 都和运行期拼出来的完全相同。
- **禁止**新旧两套同时预热。否则首编时间翻倍，Web LOW 首次进图要多等 3～5 s。

### 3.7 `world_water_web.gdshader` 迁移

和桌面水面 P3 一样，用同一套函数：
- 水陆判定调用 `hex_cell_field.gdshaderinc`，和陆地 program 同源；
- 水深、海冰改用 `w_raw` 插值（读 state / aux 层）；
- 岸距改用解析计算，删掉对 `map_index` 的环形采样；
- 下层 program 放宽 ε。**W3 之前先在 Web 上实测绘制顺序**，确认陆地在下、水面第二 pass 在上，和桌面一致；如果 Web 上顺序相反，ε 就放到另一侧。

---

## 4. 阶段

| 阶段 | 内容 | 判据 |
|---|---|---|
| **W0 平台探针** | `cell_table_platform_probe` 跑一次 WebGL2：`texelFetch(ivec3)` 分层读回、`update_layer` 单层更新（或确认整张重建可行）、highp `fract` 精度 | Windows Chrome、macOS Safari、Firefox 各 0 failures |
| **W1 数据** | `cell_table` 增加 layer3 `class_by_index`；`lat_norm` 不再依赖 `visual_static_texture_size()`；layout 测试加 layer3 逐字节比对和 `cells ≤ W×H` 断言 | `cell_table_layout_test` 全绿；桌面截图 diff = 0（layer3 还没有读者） |
| **W2 shader 去旧槽** | `PK_CELL_FIELD_NO_LEGACY_LUT`；改写 `gi_packed_bounce_color`；debug 档 1–10 在该组合下剔除；§3.3 sampler 普查 | 所有 Web / Compatibility 前缀 × {OFF, PK} 编译 0 错误；PK 陆地 = 6 槽；OFF 前缀逐字节不变 |
| **W3 Web 水面** | `world_water_web.gdshader` 迁移（§3.7）；确认 Web 绘制顺序 | `web water pass` 测试扩展后全绿；海岸两边都 discard 的像素数 = 0 |
| **W4 自检与回退** | probe shader、boot 判定、`user://` 缓存、URL 强制开关、遥测；warmup 只编选中的一套 | 模拟 pass / fail 两种 meta，warmup 计划与运行期逐字节一致；人为破坏 cell_table（去掉金丝雀）时判 `fail` 并回退 |
| **W5 实测矩阵** | 见 §5 | §5 全部达标 |
| **W6 解禁** | `cell_field_variant_allowed()` 去掉 `budget_variant` 排除，保留 `world_min` 排除；更新契约 D4 / §8.1 和总方案 P6 | 总开关默认仍为关；发布一版观察遥测后，再单独决定 Web 是否默认开启 |

W0 可以和 W1 并行。W2 依赖 W1。W3、W4 都依赖 W2，两者可以并行。

---

## 5. 验收

| 项 | 标准 | 环境 |
|---|---|---|
| sampler 数 | 每个 Web / Compatibility PK 变体 ≤ 8，且等于 §3.3 的目标值 | CI（变体测试） |
| 关闭即还原 | 开关关闭时前缀逐字节不变，截图 diff = 0 | 桌面 Compatibility + Web |
| 首次编译 | world_map PK 变体 ≤ 现在的 1.2 倍；warmup 总耗时 ≤ 现在 + 10% | Windows Chrome / Edge（ANGLE→D3D11）、macOS Safari、Firefox、Android Chrome |
| 帧时间 | Web LOW / HIGH 在 zoom 1、3、6 三档，帧时间 ≤ 现在的 1.1 倍 | 同上 |
| 自检 | 四个环境全部 `pass`；人为破坏时 `fail` 并回退 | 同上 |
| 视觉 | 任意缩放无纹素台阶；角点无楔形；回绕接缝无亮线（契约 §9.1）；海岸无洞 | 同上，截图存档 |
| 体积 | pck 增量 < 50 KB（多一个 probe shader 和少量代码） | 导出包审计 |

---

## 6. 风险

| 风险 | 后果 | 对策 |
|---|---|---|
| 某个浏览器 / 驱动上 `sampler2DArray` 的 `texelFetch` 行为异常 | 格界错乱或全图同色 | §3.5 自检判 `fail`，自动回退；遥测按显卡统计 |
| FXC 编译悬崖 | Windows 上首次进图卡顿十几秒 | 遵守总方案 §3.9；W5 实测；超标时先查有没有过滤采样进了非一致分支 |
| 删声明后某个 include 编不过 | 开发期编译错误 | 这正是想要的效果，按 §2 表逐项改写 |
| 新增 layer3 被遗漏同步（地形改变时只更新了 layer0） | Web 上 GI 弹射颜色过时 | layer0 和 layer3 由同一个发布函数写入；layout 测试断言两层内容一致（重排后） |
| 自检通过，但真实 program 槽位超限 | 白纹理 | 由 §3.3 测试在 CI 拦截；自检本来就不承担这一项 |
| `user://` 缓存的结论过期（浏览器升级后驱动行为变化） | 带着旧结论跑出错误画面 | 缓存键包含驱动版本；URL 强制开关兜底；遥测看到同一显卡出现 fail 时，清掉该键 |
| world-min 降级档和正常档格界形状不同 | 切换画质时边界跳一下 | 接受。降级档只在性能不足时启用 |

---

## 7. 否决的方案

| 方案 | 否决理由 |
|---|---|
| 等 P6 旧通道全部退役后再解禁 | P6 还要处理桌面的 `bounce_lut`、`cell_indirect`、debug 档等一整套依赖，而 Web 只需要解开其中一处。没必要绑在一起 |
| 只在 Web 上砍掉 `map_index_atlas`，腾出 1 个空槽 | 槽位凑得上，但长期停在 8 个用满的边缘，下次加功能又会撞上限；enum / dyn 仍按 `cell.index` 排列，两套坐标系长期并存 |
| 把 `cell_table` 塞进 `terrain_surface_tex` 当新的一层 | 数组纹理各层必须同尺寸：几十 KB 的数据要占一整层全图大小的 RGBA8（好几 MB）；state 每天更新，就要每天上传整层 |
| 新旧两套变体都预热，运行时再切换 | WebGL 没有 program 二进制缓存，首编时间翻倍 |
| 不做自检，只靠测试矩阵 | 浏览器和驱动组合太多，测试矩阵覆盖不全；没有自检的话，线上某块显卡出错时只能靠玩家截图发现 |

---

## 8. 未决问题

1. **Web 默认开启**：**已定 —— 2026-11-18 第二轮末尾把总开关打开**（`project.godot` 的
   `rendering/map_tiles/terrain_cell_field_enabled=true`，代码 fallback 也是 `true`），
   所以 Web / Compatibility 的解禁是**实际生效**的，不再等遥测。受限平台仍由 §3.5 的
   boot 自检兜底：自检 fail 或未判定 ⇒ 自动退回旧路径。是否要在自检 fail 率高的设备上
   收回来，看上线后的遥测。**风险自认**：浏览器矩阵（§5）尚未跑，见 §9.4。
2. **桌面 Vulkan / 移动是否顺手去掉旧三槽**：layer3 对它们同样适用。但桌面还有 `bounce_lut` 和 `cell_indirect` 的其他读者，按计划仍在 P6 处理，本方案不扩大范围。
3. **自检要不要覆盖 tiled 路径**：Web 目前只走非 tiled 路径。如果以后 Web 启用 tiled，probe 需要再加一组 `visual_warp_tiles` 的读回。

---

## 9. 实施记录（2026-11-18）

### 9.1 落地内容

| 阶段 | 结果 |
|---|---|
| **W0 平台探针** | `tests/world/cell_table_platform_probe.gd` 升到 4 层，在 **GLES3(OpenGL3 3.3) 与 Vulkan** 各 0 failures：分层 `texelFetch` 读回一致、`update_layer` 单层且可重复。**浏览器矩阵未跑**（见 §9.4） |
| **W1 数据** | `cell_table` 增加 layer3 `class_by_index`（`DCCellTableCodec.LAYER_CLASS_BY_INDEX = 3` / `LAYER_COUNT = 4`）；`WorldData.cell_table_layers`（0/3/4 三态，降级时不越界写）；`cell_class_index_bound` 由陆地与水面两处推送；`lat_norm` 改用 `derived_resolution.y`（与旧 `textureSize(map_index_atlas)` 逐值相等，证据见 `renderer_material_publish.gd` 的 `derived_resolution` 推送）。`cell_table_layout_test` **29 → 48 断言**，含 `layer3[o2i[o]] == layer0[o]` 与 `cells ≤ W×H` 断言 |
| **W2 shader** | `PK_CELL_FIELD_NO_LEGACY_LUT`；`enum_lut`/`dyn_lut` 声明删除、`VT_USE_MAP_INDEX` 不定义；`brdf` 的 GI 弹射改读 layer3（`cid % W` 在 `cid ≥ 0` 早退之后求值）；`cell_indirect` 两入口包门；debug 档 1–10 品红占位；`world-min` 与场函数正交化。**四个 Web/Compat 前缀 PK 全部 8 → 6**，OFF 全部保持 8 且清单不变；桌面非预算变体增量仍 +1（tiled +2） |
| **W2 测试** | `terrain_shader_variant_test` **292 → 367 断言**：四前缀 × {OFF,PK} 的 compile/≤8/等值/清单/类型（`sampler2DArray` vs `sampler2D`）普查、旧三槽逐名缺席、`#undef` 归一化不再出现、`PK_WEB_WORLD_MIN` 仍在前缀里 |
| **W3 水面** | `world_water_web.gdshader` 迁到场函数，宏 `PK_WATER_FIELD_MATCHES_LAND` 跟随**陆地 program 的数据源**。sampler **7 → 4**；`web_water_pass_node_test` **28 → 86 断言**，含真后端「两边都 discard 的像素 = 0」与「水面画出的水集合 == CPU 场 100%（19200 px）」。绘制顺序证据：`renderer_scene_services.gd:91-94` 建陆地 quad，`renderer_shader_water.gd:935/940` 把 water quad 移到陆地后一位且**无平台分支** ⇒ 陆地在下、水面在上，ε 放宽在陆地侧 |
| **W4 自检** | `shaders/debug/cell_field_web_probe.gdshader`（3 sampler，`blend_disabled` 保证四通道可回读）+ `CellFieldWebProbe`（`run()` / `ensure_decided()`）；boot meta `pk_web_cell_field_boot` 三态；`user://pk_web_cell_field_probe.cfg` 按 adapter+driver+build 缓存；`?cellfield=off\|on` 强制开关；遥测 `cell_field_probe` / `cell_field_probe_fail`；warmup 在 `_collect_codes()` 前 `await ensure_decided()`，只预热选中那一套。`cell_field_web_probe_test` 91（headless，1 skipped）/ 100（opengl3）/ 99（vulkan）断言 0 failures，含「去掉金丝雀 / 破坏 layer3 ⇒ fail 并回退旧路径」 |
| **W6 解禁** | `cell_field_variant_allowed()` 的两个排除（budget / world_min）都已失效并移除；桌面 Compatibility 增加 boot 自检调用点；**总开关已打开**（见 §8 第 1 条） |

### 9.0 开关状态（2026-11-18 收尾）

总开关 `project_keynes/rendering/map_tiles/terrain_cell_field_enabled` **= `true`**，三处一致：

| 位置 | 值 |
|---|---|
| `project.godot` 的 `[project_keynes]` | `rendering/map_tiles/terrain_cell_field_enabled=true` |
| `RendererShaderWater.cell_field_setting_enabled()` 的 fallback | `true`（读不到键也不会悄悄关掉） |
| `HexRenderer.terrain_cell_field_enabled` 的 export 初值 | `true`（`_init` 再从设置覆盖） |

回退办法（按代价从小到大）：① GM 面板 / inspector 把 `terrain_cell_field_enabled` 关掉；
② URL `?cellfield=off`；③ 把设置改成 `false`（此时 shader 前缀逐字节还原，等于这套功能不存在）。
**受限平台（Web / 桌面 Compatibility）还多一道 boot 自检**：fail 或未判定一律退回旧路径。

同步更新了 5 条「出货默认关」的断言（`terrain_shader_variant_test` ×2、
`cell_field_web_probe_test` ×2、`web_water_pass_node_test` 的 legacy 组改成显式关设置再建
renderer），全部改成等值断言并保留「怎么才会失败」的能力。

### 9.2 与初稿不同的三处判断

1. **world-min 不排除**（§0 第三条 / §1.2）。否则 Web LOW 会是「陆地 legacy + 水面 field」，海岸错开 1~2 px —— 正是本方案 §3.7 要防的那类问题。
2. **水面 HIGH 是 OFF − 2、第二 pass 是 OFF − 4 + 1**（§3.3），不是初稿的「OFF − 2 + 1」。
3. **`world_water_web` 不 include `terrain_surface_detail`**：实测会因 `pixel_world_size` / `terrain_material_tex` / `biome_*` 一整条链失败，且要多 3 个 sampler。改为逐字复制它需要的 8 个纯函数（`wrap_world_pos` / `terrain_static_biome_is_water` / `terrain_edge_screen_width_px` / `shore_*` / `water_biome_weights_field` 等），并由测试**逐函数与源文件比对**，漂移即红。

### 9.3 已知的视觉语义变化（需真机截图确认）

- **岸线**：旧 `edge_distance.BA` 的 B 通道实际是「8 邻域水邻居占比」，开阔洋面恒 1.0 ⇒ 旧代码把整片洋面混向浅滩色。解析岸距换成「贴岸度」后，开阔洋面不再被拉浅、海岸带才出现浅滩。这是有意的修正，也是 PK 路径上最明显的视觉差。
- **次生水格混合权重**从 `terrain_static_edge_weight(gap)`（峰值 0.5）换成 rank-1 `w_raw`（峰值 ≈0.33），海/湖交界混合更淡。

### 9.4 未覆盖

1. **浏览器 / 真机矩阵（W0 的浏览器部分、W5 全部）**：只在桌面 GLES3(OpenGL3) 与 Vulkan 验过。Chrome/Edge(ANGLE→D3D11)、Safari、Firefox、Android Chrome 的 `sampler2DArray` + `texelFetch` 行为、FXC 首编时长、帧时间，仍需按 §5 跑一遍并截图存档。
2. **自检不覆盖真实 program 的槽位分配**（§3.5 末段已声明）：槽位由 W2 的编译期普查守。
3. `?cellfield=` 的真实 JS 读取未在浏览器里验过（非 web 恒空串）。

### 9.5 开关打开后的一轮复核（2026-11-18 收尾）

| 项 | 结果 |
|---|---|
| headless 三份核心测试 | `terrain_shader_variant_test` **367/0**、`web_water_pass_node_test` **86/0**、`cell_field_web_probe_test` **91/0（1 skipped）** |
| 真后端复跑（opengl3 / vulkan） | 同上三份全绿（web_water 91/0、probe_test 100 与 99）；`cell_field_gpu_parity_probe` 两后端各 **19/0**；`cell_table_platform_probe` 两后端各 **0 failures** |
| 端到端世界生成（开关开） | `fatal=false`、`ledger_failures=0`、`rows=expected_rows` |
| `--headless --quit` | 无 SCRIPT ERROR / Parse Error / SHADER ERROR |

**一条既有失败（与本开关无关，已用「把设置改回 false 复跑」证明）**：
`tests/economy/resource_visual_render_regression.gd` 在 `--rendering-driver opengl3` 下
`17 checks / 1 failure`（`horizon shadow reduces direct and sky lighting`）；把
`terrain_cell_field_enabled` 改回 `false` 后同样 1 failure。另外该测试在 headless 下会挂住
（它是渲染测试，需要真后端），也是既有行为。
