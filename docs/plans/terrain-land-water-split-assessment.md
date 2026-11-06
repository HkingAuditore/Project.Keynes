# 陆地 / 水面拆两个 mesh + 两个 shader 的可行性评估

- 日期：2026-11-01（v4：双 program + 保守覆盖 mesh 已在工作树落地，见 §8；未 commit）
- 范围：主地形渲染 `world_map.gdshader` + `scripts/rendering/hex_renderer.gd`
- 工作树状态：HEAD `999fff4e7`（2026-10-31）+ 2026-11-01/02 未提交改动。本评估基于**工作树代码**，不是 HEAD。
- 行号说明：`world_map.gdshader` 在 2026-11-01 的 P0 修复中新增了 1 行 touch 注释；本文引用的该文件行号是**修复前**的行号，实际使用请 +1。
- 结论级别：先给结论，再给逐像素账、方案对比、实施陷阱、测量方案。

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| 能拆成两个 **shader program** 吗？ | **能，且已有先例**：Web 的陆地 / 水面已经是两个 program（`world_map.gdshader` + `world_water_web.gdshader`），由 `hex_renderer._sync_water_quad()` 画两个 pass。桌面/Android 目前仍是单 program。 |
| 能拆成两个 **mesh** 吗？ | **不是可选项，而是让拆分收益"确定化"的条件（v3 修正）。** 不分 mesh 时两个全屏 pass 每像素仍发生两次 fragment invocation，另一侧能否提前退场只取决于 **wave 级 discard** —— 这依赖 GPU/驱动/当前 zoom 下的区域连通性，不能当生产契约（最坏就是整张地图两遍）。分 mesh 后纯区域根本不生成对方的 fragment，收益由光栅化保证；只有窄的海岸混合带依赖 discard。 |
| 能省下"大量计算"吗？ | **取决于两件事：①移动端是否把 land/water if/else 摊平/发散（模型 F），②有没有分 mesh 让纯区域只跑一条管线。** 若模型 F 且分 mesh：纯区域每像素从"SETUP + 两条管线"降到"SETUP + 一条管线"，fragment 采样量可能接近减半；若模型 F 但只用 discard 剪枝：收益随 zoom/驱动波动，不可保证；若模型 B：拆分接近中性。见 §2 / §2.1。 |
| 用 **Alpha Clip Dither** 做岸边混合？ | **不建议**。项目没有 MSAA 2D / TAA / FXAA；现有 dither 都是 texture-space 锚定、近景会淡出；桌面海岸现在是双侧 fwidth 平滑色带（mobile 端已被编译裁掉），clip dither 会把平滑带换成噪点。两个 pass 用 per-pixel discard 本身已经像素精确，不需要 dither。 |
| 真正的大头在哪？ | **桌面 / Android（以及 Web HIGH）每个像素在跑 16 步 insolation 积分（≈68 个 transcendental）**，结果对 on-map 像素被 `dyn_temp` 完全覆盖 —— 纯死代码；只有 Web LOW/MID 的共享变体（`PK_WEB_WORLD_MIN`）编译裁掉了它。约 3 行修复，见 §5 P0。 |

一句话：**你的方向（拆 program + 拆 mesh）是对的：不看 discard，纯区域就只跑自己那条管线；两个 mesh 只负责"光栅化阶段不生成对方的 fragment"，不做 dither。而且不管拆不拆，先把每像素白算的 insolation 积分删掉。**

## 1. 现状：到底画了什么、算了什么

### 1.1 渲染路径

- 地图 = **一个 `MeshInstance2D` + 一张 ArrayMesh（4 顶点 / 2 三角形，横向环绕时 3 份拷贝 12 顶点）**，挂 `canvas_item` shader，在 `Camera2D` 下按世界坐标绘制：`hex_renderer.gd:728-736`、`hex_renderer.gd:4264-4289`、`hex_renderer.gd:4271-4274`。
- shader 的一切（LUT 寻址、wrap、fog）都读插值出来的**世界坐标 `v_world`**，不读 UV：`world_map.gdshader:235-237`、`:246-247`。因此"换一张覆盖同一世界空间的 mesh"对 shader 是透明的 —— 这是"两个 mesh 可行"的技术基础。
- 纯 2D canvas：**没有 depth/stencil**，绘制顺序只由 `z_index` + 树序决定（web 水面 pass 就是这么钉的：`hex_renderer.gd:1179-1188`）。所以两个 mesh 不可能靠深度解决重叠，只能"互补 discard / 保守覆盖"。
- 默认地图 60×40（菜单档 40×28 / 60×40 / 100×64），`hex_size=22`，`world_bounds` ≈ 2393×1419，烘焙分辨率 `derived_size = hm_size` = 1024×606（桌面基线）：`map_baker.gd:981-991`、`map_baker.gd:1063-1065`。视口 1600×960，缩放 0.25–6.0（`project.godot:32-35`、`map_camera.gd:29-30`）；适屏约 0.64 zoom，此时地图覆盖 ≈1524×914 ≈ 1.39M 像素。

### 1.2 fragment 的真实结构

```
SETUP（无条件，world_map.gdshader:246-437）
  6 次采样：noise_tex(:267) / height_tex(:274) / edge_distance(:291) /
            map_index_atlas(:301) / dyn_lut(:307) / enum_lut(:323)
  is_water = biome ∈ {OCEAN, COAST, LAKE, REEF, KELP, SEA_ICE}   (:369-370)
  season_offset / derived_temp / current_temp                     (:435-437)
if (fog_hidden) { COLOR = 迷雾色; }                                 (:454-456)
else if (!is_water) { col = render_land_pipeline(...); }            (:458-466)
else                { col = render_water_pipeline(...); }           (:467-487)
// 分支之后：fog 去饱和 + debug view + apply_global_adjustments（0 fetch，~30-40 ALU）
```

**"一个像素只跑一条管线"只在"真分支 + wave 内分类一致"时成立；移动端很可能接近"算两次"（v2 修正）：**

- **SIMT 发散**：一个 wave 里同时含陆地和水面像素时（海岸、湖岸、河口水边），两条路径都会执行。移动端 fragment wave 小（Mali 4×4 quad、Adreno 更大 wave），海岸线在屏幕上又长，发散命中率不低；放大到海岸附近时整屏都可能发散。
- **if-conversion**：Adreno/Mali 编译器常为规避发散把分支摊平成谓词执行——两条管线都发指令。每条分支有几十次 texture fetch 的大分支是否会被摊平因驱动而异，但**不能假定不会**；这也是 `无分支 mix 18 060 ms` 与 `if/else 17 264 ms` 编译代价几乎一样（见 §1.3）的同一类现象：编译器眼里"两个着色来源"的寄存器/调度代价与分支结构关系不大。
- **寄存器 / occupancy**：无论实际走哪条控制流，编译期寄存器都按两支的 worst-case 分配；移动端 tile-based GPU 对 occupancy 敏感，于是**所有像素**都在为另一条管线付 occupancy 成本。
- **导数**：两条分支里都有 `fwidth`（`terrain_surface_detail.gdshaderinc:190` 的 ecotone AA；水面波纹/足迹同样用导数），GLSL 规定非一致控制流里的导数未定义，驱动常把相关计算提到一致流或摊平——又一条"两边都算"的来源。

所以成本模型有两种：**模型 B（真分支，每像素 1 条管线）** 与 **模型 F（摊平/发散，每像素 ≈ land + water 两条管线）**。桌面 NVIDIA/AMD 对这种大 texture 分支通常保留真分支（模型 B 概率高）；移动端 / ANGLE 更可能落在模型 F。**这是本评估里唯一必须靠实测定下来的分歧点。**

两条管线的逐像素量级（桌面质量，按代码计数，非实测）：

| 路径 | 采样数 | 说明 |
|---|---|---|
| SETUP | 6 | 上面 6 个 sampler；ecotone 像素另有 +1~2 |
| 陆地管线 | ≈19–25 | material 1 + surface 2 + micro 1 + shore 8 + horizon 4 + GI 3 + 条件 fbm |
| 水面管线 | ≈50 | water_depth 1 + 3×3 biome 9 + gyre/lake/reef/kelp/ice/currents/plume/wave/shore/foam/caustics/sparkle/horizon/GI… |

移动端 q0 档（`docs/architecture/development-guide.md:1864-1879`）：水面 ≈23、陆地 ≈18 samples；同一文档 `:1799-1812` 的 Adreno 830 实测：地形 shader ON/OFF，非 SUS 帧 24.23 ms → 8.42 ms，即**地形 fragment 占移动端整帧约 65%**。移动端才是 fragment 成本敏感的平台。

### 1.3 Web 已经拆过：拆的是 program，不是 mesh

`hex_renderer.gd:1084-1090` 记录的事故与结论：

| 组合 | ANGLE/FXC 首次编译 |
|---|---|
| 陆地 + 水面同 fragment | **20 291 ms** |
| 只留陆地 | 2 473 ms |
| 只留水面 | 1 089 ms |
| 水面换成 25 行紧凑版 | 17 264 ms |
| 水面换成无分支 mix 版 | 18 060 ms |

悬崖与第二个来源的行数无关，是**寄存器压力型的非线性**。因此 Web 把水面整段移出，改成第二个全屏 quad + `world_water_web.gdshader`（非水像素 `discard`），两个 program 合计 ≈3.6 s（`web_shader_warmup.gd:40-46`、`world_map.gdshader:219-232`）。

**但要说清楚：这组数字是"编译时间"，不是"帧时间"。** 仓库里没有任何"拆分后 frame ms 下降"的实测；拆分的已知收益是 Web 启动/首帧编译。桌面（Vulkan / D3D12）从未观测到 20 s 悬崖，也没有测量过"单 program vs 双 program"的帧时间差。

## 2. 逐像素账：两种分支成本模型

拆分能不能赚，先要定下"现在到底付了几条管线的钱"：

| | 模型 B（真分支：每像素 1 条管线） | 模型 F（摊平/发散：每像素 ≈ land + water 两条） |
|---|---|---|
| 当前每像素 | SETUP 1× + 自己那条管线 | SETUP 1× + 陆地管线 + 水面管线 |
| 拆两个 program（discard-first，不分 mesh） | 2-fetch precheck + SETUP 1× + 自己那条管线 | 2-fetch precheck + SETUP 1× + 自己那条管线（**仅当 wave 级 discard 可靠时**） |
| **拆分的净收益** | ≈ **−2~4%**（多一次 precheck；只能靠寄存器/occupancy 赚回） | ≈ **省掉另一条管线**（水面像素省陆地 ~19–25 fetch，陆地像素省水面 ~50 fetch）—— **但依赖 discard 在 wave 级生效，不可保证** |
| **再加保守覆盖 mesh** | 把这 2~4% precheck 抵掉，回到与今天持平 | **把"不可保证的 discard 收益"变成几何保证**：纯区域只跑一条管线；最坏情况（discard 完全无效）下也避免"整张地图两遍" |

- **同 SETUP 直接拆**（不做 discard-first）在两种模型下都是 +10~15%，直接排除。
- **模型 F 下用户的直觉是对的**：当前单 program 就是每像素两头付费，拆 program 是实打实的计算削减。
- **模型 B 下**：拆分只能靠寄存器压力 / occupancy 赚，必须 GPU-time A/B 才能定；否则可能是负优化。
- **但"拆两个 program"本身不足以兑现模型 F 的收益**：如果只做两个全屏 pass、靠 `discard` 剪掉对方区域，每像素仍有两次 fragment invocation，且对方区域能否提前退场取决于 wave 级 discard（见 §2.1）—— 最坏情况是整张地图两个 pass 都完整执行，比现在还差。**必须同时分 mesh，让纯区域只生成自己那条管线的 fragment。**
- 分 mesh 后：纯区域每像素 = 1 次 invocation + 1×SETUP + 1 条管线（几何保证）；混合带（海岸，O(海岸线长 × block 尺寸)）两个 program 都跑，靠逐像素 `is_water` 互补 discard 保证不重复上色。**不需要 dither。**

### 2.1 discard 是 wave/quad 粒度，不是 pixel 粒度（"两 pass + discard"不能当收益保障）

- GPU fragment 以 **wave** 调度（移动端一个 wave 通常 16–64 像素，桌面 32）。`discard` 只把当前 invocation 标成 killed；**只要同 wave 还有活着的 lane，后续指令照常发射**，killed lane 只是被 mask 掉 —— 不减少这条 wave 的 instruction issue。
- 只有**整条 wave 都 discard**（或分支条件在 wave 内一致）时，wave 才真正提前结束。
- 推论：
  1. "两个全屏 pass、靠 discard 剪掉对方区域"的收益 = **wave 粒度 × 屏幕区域连通性**，不是"每像素省一笔"。适屏 zoom 下大陆/大洋是连片大区域，多数 wave 分类一致 → discard 往往有效；放大到海岸、或海岸线密集的地图，混合 wave 占比高 → 收益趋近 0，最坏就是"整张地图两遍"。
  2. 移动端还有额外风险：部分架构/驱动把 discard 实现成谓词/延迟写（killed lane 继续走到结尾），或因为 discard 放弃某些早退优化；这个行为**不可移植，不能当生产契约**。
  3. 项目自己也是这么理解分支的：迷雾早退注释写明"GPU 分支按 wave 粒度生效：迷雾区是大片连续屏幕区域，发散 wave 只有 O(边界周长)"（`world_map.gdshader:449-453`）。迷雾能这么做是因为它天然是巨大连片区域；陆地/水面的海岸是 1D 边界，高倍 zoom 下边界可以填满屏幕，不能同等对待。
- 因此：**不拆 mesh 的"两 pass + discard"只能当测量原型；最终形态必须分 mesh。** 分 mesh 后纯区域的 fragment 根本不生成，收益由光栅化保证；discard 只在窄的海岸混合带里负责"别画错"，不再承担省算职责。

## 3. 三个方案对比

### 方案 A：两个 program + 同一张 full-map quad（Web 同款）—— 只作测量原型

- 做法：`_water_pass_active()` 去掉 web/Compatibility 门（`hex_renderer.gd:1102-1105`），桌面复用 `world_map.gdshader` + `PK_WATER_ONLY`（Web HIGH 已验证这条路径：`hex_renderer.gd:1055`），陆地 program 不再 include `water_pipeline.gdshaderinc`（72 KB，最大的一个）；水面 material 的 uniform 用 Web HIGH 已有的"从主材质整表拷贝"逻辑（`hex_renderer.gd:1204-1216`）。
- 工作量：**2–4 天**（含变体、fog/debug 对齐、测试、文档；web 作业可直接抄）。
- 收益：**只有在 discard 被验证为 wave 级可靠时**才是模型 F 的管线成本削减；否则每像素两次 invocation，最坏（整图都执行）比现在更差。
- 用途：作为 **P1 测量原型** 是合适的（量出"两条管线到底付了几份钱"）；**不作为最终架构**。
- 风险：中。变体矩阵（tiled/legacy × 质量档 × debug）和字节级 prefix 契约/预热/测试会成倍增加。

### 方案 B（推荐落地）：A + 保守覆盖网格（两个 mesh）

- 做法：从 CPU 已有的逐像素水掩码（`WorldData.biome_buffer` / `pixel_to_cell_lookup` / `cell_pixel_lists` / `MapData.terrain_arr`，见 `world_data.gd:19,47,81-83,266-282`、`map_data.gd:249,545`）按 8/16 world-unit 的 block 生成两张"保守覆盖"网格：凡是 block 内含该类像素就放进该类 mesh（混合 block 两边都放）。**纯陆 block 只有陆地 program 被光栅化，纯海 block 只有水面 program 被光栅化**；shader 仍逐像素判定 `is_water`，混合 block 里互补 discard 保证不重复上色。视觉**逐像素精确、无 dither**。16wu block 在 60×40 地图上约 1.3 万 block / 2.7 万三角形 / ≈0.75 MB；wrap 时按 ±P 复制 3 份（与主 quad 一致）；mesh 只在 bake 期建一次（lands/water 类不会在运行期改变，海冰翻转两侧都是水）。`hex_renderer.gd:4258-4262` 的 `_set_world_quad_mesh` 是现成挂点。
- 工作量：A 的 2–4 天 + 网格 3–5 天（block 分类、wrap、构建 hook、与 tiled cell-id 对齐）+ 测试/文档 ≈ **1–1.5 周**。
- 收益：模型 F 下纯区域每像素从"两条管线"降为"一条管线"（几何保证，不赌 discard）；模型 B 下 ≈ 中性（多两个 draw + 少量重叠块），主要剩寄存器/编译期收益。
- 正确性要点：
  1. 两个 program 仍按逐像素 `is_water` 只写自己 class 的像素（否则会画错），覆盖网格只是"保守超集"：每个 block 至少覆盖自己 class 的所有像素；
  2. 混合 block 外扩一格（两边都多覆盖一圈），吸收 CPU 掩码与 shader 内 tiled cell-id 的任何边界差异，避免漏画（漏画会露出背景）；
  3. wrap 复制 3 份（±P）；
  4. `terrain_surface_debug_view != 0` 时回退到原来的整张 quad + 单 program 诊断路径（部分 debug 视图只在陆地/水面管线里有意义，两个 mesh 覆盖会让诊断画面出现空洞）；
  5. 视觉验证目标：与今天**逐像素一致**（因为分类逻辑、颜色管线都没变，只是几何覆盖变了）。
- 风险：中高。wrap 接缝、tiled 路径的 per-pixel cell id 与 CPU 掩码的 parity（用外扩保险）、mesh 与 bake 的时序、变体数量。

### 方案 C：用户原案（每格 / 海岸线级 mesh + alpha clip dither）

- 海岸线是**逐 texel 分类**（`is_water` 由 cell id + `enum_lut` 决定，`world_map.gdshader:369-370`），不是格子边界。按 hex 建几何会把海岸量化到 ≈38 world units（≈27× 于当前 1.4 wu/texel 的海岸精度），破坏 SDF 岸坡 carve / 沙滩带 / water_depth 的观感；`hex_terrain.gdshader` 在本项目里是死文件，fog 层也明确拒绝过 per-hex 实例化（`fog_of_war_layer.gd:4-9`）。
- 工作量：2–4 周，且画质退化。
- 结论：**不做。**

## 4. Alpha Clip Dither 专项

- **可实现**：项目已有 8×8 Bayer helper，`terrain_surface_detail.gdshaderinc:105-140`；约 12–15 ALU、0 额外采样，而且同一个函数在 fragment 里已经被调用两次（`world_map.gdshader:331-338`、`:383-396`）。
- **但没有 AA 兜底**：`project.godot` 没有 `rendering/anti_aliasing/*`（只有 1600×960 / mode=2 / stretch expand，`:30-35`；渲染后端在 `:106-108`）；2D 没有 MSAA/FXAA/TAA，discard 的 dither 也不会吃到 MSAA resolve。
- **图案只能 texture-space 锚定**：现有 dither 用 `visual_reference_resolution` 量化 uv（`:120-140`），近景 1.20→2.05（桌面）/1.65→2.45（移动）就淡出，因为放大会看到 atlas 大小的方块（`:142-154`）。换成屏幕空间 dither 则会在平移时"游动"。
- **颗粒尺度不可接受**：一张 texel ≈3.1 world units（桌面 1024），dither 单元 = 3.1×zoom 屏幕像素；适屏 zoom≈0.64 时约 2 px（接近 Nyquist，会闪烁/摩尔纹），zoom 6 时约 18.5 px（肉眼棋盘格）。
- **会破坏现有海岸**：桌面海岸现在不是硬切，而是两侧管线各自把颜色混向同一个 `mix(color_coast_water, color_lowland, coast_shore_land_bias)` 的中点色带（`land_pipeline.gdshaderinc:497-504`、`water_pipeline.gdshaderinc:1001-1008`；强度 0.65 / 宽度 1.8，`materials/world_map_material.tres:164-166`）；mobile 档这段被编译裁掉。clip dither 会把这个 fwidth 平滑带替换成噪点。
- **两个 pass 本来就不需要 dither**：每个 pass 逐像素判定、互补 discard，输出与今天的逐像素分类逐位一致；"两个 mesh"只要用保守覆盖就不会有几何缝。
- 如果将来确实要更软的海岸：用 **alpha blend**（第二个 pass 写 alpha = 连续 coverage，`blend_mix` 已经打开）或 **coverage 场**（`water_depth.R` / `abs(elev - sea_level)`，两侧管线都已经在采），不要用 clip dither。

## 5. 推荐路线

### P0（先做，0.5–1 天）：删掉每像素白算的 insolation 积分

> **状态：2026-11-01 已完成（未提交）。** `climate_season.gdshaderinc` 的 `season_offset_unified` 改为无条件 `return 0.0`（on-map 逐位不变），`world_map.gdshader` 加 touch 注释触发重编；headless `terrain_shader_variant_test` 533/533 通过、sampler 预算未变；真机首帧编译 + 固定种子截图仍需人工验收。

`world_map.gdshader:435-437`：

```
float season_offset = season_offset_unified(lat_signed, season_phase);
float derived_temp = compute_current_temp(elev, lat_signed, season_offset);
float current_temp = mix(derived_temp, dyn_temp, dyn_valid);
```

- `dyn_valid` 对 on-map 像素恒为 1（`world_map.gdshader:363`），所以 `current_temp` 在 on-map 像素上**严格等于 `dyn_temp`**，`derived_temp` / `season_offset` 是死值。
- `season_offset_unified` 内部是 16 步 insolation 年积分（每步 tan/acos/sin/cos；`climate_season.gdshaderinc:58-65`、`:77-93`）≈68 个 transcendental / 像素。Web LOW/MID 的共享变体已经用 `PK_WEB_WORLD_MIN` 把它 return 0（`:99-102`），**桌面 / Android / Web HIGH 都还在算**。
- 修法：加一个编译期宏（例如 `PK_SKIP_INSOLATION_FALLBACK`），把 `season_offset_unified` 直接 return 0；padding（`cid<0`）本来就被 FogOfWar 盖住，用 `lat_temp_bell` 的廉价 fallback 即可。on-map 像素输出**逐位不变**（`mix(a,b,1.0)==b`），可以截图 diff 验收。
- 这是目前**最大且最便宜**的每像素收益，优先级高于任何 mesh/program 拆分。

### P1（0.5–1 天）：判定模型 B / F —— 这是拆不拆的决策点

**① 看编译产物（最快）**：用目标移动 GPU 的离线/在线工具看 fragment 的寄存器数、分支指令和每 draw 的 ALU/texture 计数：

- Adreno：Snapdragon Profiler 的 Shaders 视图 / Adreno 离线编译；
- Mali：Arm Performance Studio（`malioc`）看 register count、instruction mix；
- 判读：如果两条管线的 texture 采样计数同时出现、或寄存器数 ≈ 两支之和 → 模型 F（现在就在付两份钱）。

**② 引擎内 A/B（更接近实际帧）**：加三张临时诊断变体：

1. `PK_FORCE_LAND`：把 `is_water` 硬置为 false，整屏只跑陆地管线；
2. `PK_FORCE_WATER`：硬置为 true，整屏只跑水面管线；
3. `PK_PROBE_NO_LAND + PK_PROBE_NO_WATER`：只剩 SETUP（地板价）。

在固定机位、固定种子、vsync 关闭下用 F3 `dump_render_profile()`（non-SUS avg）测：

- **全海洋视角（f_W≈1）**：若 `T_combined > T_force_water`，多出来的就是陆地管线在帮水面像素付费 → 模型 F；若两者≈相等 → 模型 B；
- **全内陆视角（f_L≈1）**：若 `T_combined > T_force_land` → 模型 F；
- 拆分收益估算 ≈ `f_L·T_force_land + f_W·T_force_water`（减去 2-fetch precheck 开销）。若估算收益 ≳15%，方案 A 值得立刻做；若 ≈0，说明分支在你目标设备上是真分支，别为逐像素收益拆。

**③ 最终确认**：P2 原型落地后同机位复测真实帧时间，以帧为准。另外 P0 先做完，否则 insolation 的 68 个 transcendental 会和分支实验互相污染。

### P2（推荐落地，≈1–1.5 周）：两个 program + 保守覆盖 mesh（方案 A+B 合体）

- **Step 1（2–4 天）**：拆 program（discard-first）。复用 Web 架构；新 `PK_LAND_ONLY` / `PK_WATER_ONLY` 定义要把 `water_pipeline.gdshaderinc` 从陆地 program 摘掉，但**保留 `water.gdshaderinc`**（陆地河面法线还要用 `sample_water_normal`，否则会踩 `land_pipeline.gdshaderinc:181-190` 的压平分支）。两个 program 都必须先做 2-fetch classify + discard 再进 SETUP；水面 pass 必须 discard 未探索像素（fog），`terrain_surface_debug_view > 0` 时 discard（`world_map.gdshader:371-374`、`world_water_web.gdshader:296-305`）。
- **Step 2（3–5 天）**：保守覆盖 mesh。从 CPU 逐像素水掩码按 16wu block 生成 land/water 两张网格（混合 block 两边都放、必要时外扩一格做 parity 保险），纯区域只光栅化自己的 program；wrap 三份拷贝与主 quad 一致；在 `bake_world` 结束 / `hex_renderer._rebuild` 阶段构建一次，运行期不重建。
- tiled 陆地 program **必须保留 `VT_USE_WATER_DEPTH`**，否则 `PK_TERRAIN_STATIC_BAKED` 不生效、海岸软权重退回 8-fetch 邻域（`visual_tile_sampling.gdshaderinc:133`、`shore_common.gdshaderinc:46-57`）。
- 同步更新：变体前缀（`hex_renderer.gd:1279-1324`）、web 预热清单（`web_shader_warmup.gd:105-139`）、`terrain_shader_variant_test` 的字节级 prefix / sampler 名单、`web_water_pass_node_test` 同款节点测试、`docs/web-export.md` 与 `SHADER_DEV_GUIDE.md` 的预算表。
- **判据**：P1 判定模型 F → 这条路径把"每像素两条管线"确定性地降到"纯区域一条"；模型 B → 收益小，可降级为只做 P0 + 保留单 program。

### 不做

- 无 mesh 的"两 pass + discard"作为**最终**形态（收益不可保证，最坏整图两遍）。
- 同 SETUP 的两 pass 版本（+10~15%）。
- per-hex / 海岸线级 mesh（海岸是逐 texel 分类，hex 几何会量化到 ≈38 world units，破坏 SDF 岸坡/沙滩/水深）。
- Alpha Clip Dither（见 §4；两个 pass + 保守覆盖 mesh 已经逐像素精确，不需要 dither）。

## 6. 需要一起考虑的边界

- **未提交工作树**：当前工作树有大量 2026-11-01 的 baked-surface / packed-surface 改动（`world_map.gdshader`、`world_water_web.gdshader`、`hex_renderer.gd`、`web_shader_warmup.gd`、测试、`docs/web-export.md` 均未提交）。动 shader 前先和这轮改动对齐，避免把 prefix 契约/预热指纹弄断。
- **变体数量**：Web 已经有 8/7/5 三套 sampler 预算和字节级 prefix 契约；再加桌面 tiled/legacy × 质量档，program 数量和维护成本会明显上升。这是拆分的**主要非性能成本**。
- **收益定位**：如果目标是 Web 编译/首帧，已经解决；如果是 Android 帧时间且 P1 判定模型 F，**方案 A+B（program + 保守覆盖 mesh）** 优先级很高（≈1–1.5 周换"纯区域每像素只跑一条管线"，是确定性收益）；桌面大概率是模型 B，收益有限，可只做 P0；如果只是代码可维护性（72 KB 水面管线不想和陆地绑在一起），方案 A 也是合理投资，但要接受变体矩阵。
- **不要**：无 mesh 的两 pass 最终形态（discard 收益不可保证）、两个全屏 pass 的 same-SETUP 版本（+10~15%）、per-hex/海岸线 mesh、alpha clip dither。

## 7. 关键引用

- 分支与 SETUP：`Project/project-keynes/shaders/world_map.gdshader:246-437, 369-370, 454-487`
- wave 级分支的先例（迷雾早退的推理）：`Project/project-keynes/shaders/world_map.gdshader:449-456`
- insolation 死代码：`world_map.gdshader:363, 435-437`；`shaders/include/climate_season.gdshaderinc:58-65, 77-93, 98-106, 122-129`
- Web 拆分与实测编译时间：`scripts/rendering/hex_renderer.gd:1084-1090, 1102-1105, 1151-1192, 1204-1248`；`shaders/world_map.gdshader:219-232`；`scripts/rendering/web_shader_warmup.gd:40-46`；`shaders/world_water_web.gdshader:255-305`
- 每像素采样预算与移动端帧占比：`docs/architecture/development-guide.md:1799-1812, 1864-1883`
- 几何/相机/视口：`scripts/rendering/hex_renderer.gd:728-736, 4258-4289`；`scripts/rendering/map_camera.gd:29-30`；`scripts/rendering/map_baker.gd:981-991, 1063-1065`；`project.godot:30-35, 106-108`
- CPU 水掩码/rebuild 数据源：`scripts/geography/world_data.gd:19, 47, 81-83, 266-282`；`scripts/geography/map_data.gd:249, 530-552`
- dither / AA / 海岸带：`shaders/include/terrain_surface_detail.gdshaderinc:105-165`；`shaders/include/land_pipeline.gdshaderinc:497-504`；`shaders/include/water_pipeline.gdshaderinc:1001-1008`；`materials/world_map_material.tres:164-166`
- 拆分实施陷阱：`shaders/include/visual_tile_sampling.gdshaderinc:133`；`shaders/include/land_pipeline.gdshaderinc:181-190`；`shaders/SHADER_DEV_GUIDE.md:199-208`

## 8. 落地状态（2026-11-02，未 commit）

### 8.1 已交付

| 组件 | 文件 | 内容 |
|---|---|---|
| 双 program | `shaders/world_map.gdshader` | 新增 `PK_LAND_ONLY` / `PK_WATER_ONLY`；Web 宏在 shader 内别名归一（Web 前缀字节零改动）；陆地 program 摘掉 `water_pipeline`（保留 `water.gdshaderinc` 供河面法线），水面 program 摘掉 `land_pipeline`；水面 program 对未探索水像素改画 `fog_unexplored_color` |
| 双 program | `shaders/world_water_web.gdshader` | compact 水面不再 discard 未探索像素，画同值 fog 色 |
| 双 program | `scripts/rendering/hex_renderer.gd` | `_split_active()` 全平台默认开、`_water_pass_active()` 统一入口、桌面前缀常量、`_push_world_uniform()` 96 处镜像、`_apply_world_quad_geometry()`、编译失败整条回退、hot reload/质量档/F9/debug 全入口、`land_water_split_diagnostics()` |
| 覆盖 mesh | `scripts/rendering/terrain_coverage_mesh.gd`（新增） | 16wu block 保守覆盖 + 8 邻域外扩 1 block + wrap 3 份 + texel 矩形相交 + 边界裁剪；失败 `ok=false` 不抛异常 |
| 测试 | `tests/world/land_water_split_node_test.gd`（新增）、`tests/rendering/terrain_coverage_mesh_test.gd`（新增）、`tests/world/terrain_shader_variant_test.gd`、`tests/world/web_water_pass_node_test.gd` | 拆分/回退/覆盖 mesh/uniform/字节契约 |
| 文档 | `shaders/SHADER_DEV_GUIDE.md`、`docs/web-export.md` §9.26、本文件、`terrain-split-implementation-plan.md` | 预算表、陷阱、验收清单 |

### 8.2 Lead 独立复跑结果（Godot 4.6.2 headless）

| 测试 | 结果 |
|---|---|
| `tests/world/terrain_shader_variant_test.gd` | **616 checks / 0 failures**；Web sampler dump 不变（8/8/8/7/5），新增 `split legacy land/water/full = 15/15/15`、`tiled = 17/17/17` |
| `tests/world/land_water_split_node_test.gd` | **58 checks / 0 failures**（含真实 TerrainCoverageMesh 集成、两种回退） |
| `tests/world/web_water_pass_node_test.gd` | **25 checks / 0 failures** |
| `tests/rendering/terrain_coverage_mesh_test.gd` | **108 checks / 0 failures**；生产规模 build_ms ≈100–119ms（60×40 / derived 1024×606 / block16 / wrap3） |

### 8.3 开关 / 回退（远程 inspector 可 A/B）

- `HexRenderer.split_land_water_passes`（默认 `true`）：关掉 = 完全回到今天的单 program + 单 quad。
- `HexRenderer.terrain_coverage_mesh_enabled`（默认 `true`）：关掉 / 模块缺失 / 构建失败 = 拆分时两块 quad 共享整张 quad。
- 自动回退单 program：`terrain_surface_debug_view != 0`、Compatibility 后端 + tiled、任一 program 变体编译失败（整条回退，不允许半拆）、覆盖 mesh 模块不可用。
- 诊断：`HexRenderer.land_water_split_diagnostics()` 返回 `split_active / water_pass_active / split_program_failed / coverage_ok / coverage_reason / coverage_stats / land_program_land_only / water_program_kind`。

### 8.4 真机验收清单（headless 覆盖不到）

1. **PC Vulkan（tiled + legacy 两套 world）**：同机位/同种子截图对比海岸带、湖泊、河流、迷雾边界，应逐像素一致；`land_water_split_diagnostics()` 显示 `split_active=true`、`coverage_ok=true`。
2. **Debug 视图**：13/14/16/17 切换自动回退单 program 且画面正常；切回 0 恢复拆分；画质档切换后水面正确重编。
3. **移动 Vulkan**（q0/q1/q2）各跑一段：无空洞/接缝/编译失败；Compatibility（GLES3）会走单 program 回退，属预期。
4. **Web LOW/MID/HIGH**：LOW/HIGH 现在用覆盖 mesh + 水面自画迷雾，确认真机迷雾/水面观感与 2026-11-01 一致；Web MID 必须是单 program（本次集成特意保证）；warmup 指纹对账仍通过。注意 Web/WASM 上覆盖 mesh 构建可能 2–3× 慢于 native（≈100ms → 200–300ms 一次性加载成本）。
5. **性能 A/B（按约定本次不做 profile，真机再测）**：`split_land_water_passes=false` 对照 + F9 ΔFPS，重点海岸密集视角 / 全海洋视角；模型 B 下预期中性，模型 F 下应有下降。

### 8.5 残余风险

- 拆分后帧时间收益未真机测量；桌面可能中性/略负（多一个 draw、覆盖 mesh 重叠块、覆盖 mesh 构建 ~100ms 在加载边界）。
- 覆盖 mesh 分类依赖 CPU `pixel_to_cell_lookup` 与 tiled bake 的 per-pixel cell id 一致；已用 1 block 外扩吸收边界差异，若 tiled 海岸接缝出现漏画需加大 margin/block。
- 分类运行期不变假设（海冰翻转两侧都是水）；未来若出现跨水陆边界的 runtime terrain flip，需要加覆盖 mesh 重建钩子。
- Compatibility + tiled 桌面诊断路径仍是单 program（8 槽预算所限）；Android GLES3 也走该回退。
