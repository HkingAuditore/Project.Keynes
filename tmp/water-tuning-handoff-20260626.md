# 水体/水陆形态调参 — 交接笔记（2026-06-26）

> 状态：**代码全部就绪、lint 0 错、已 python ground-truth 验证落地。等用户 rebuild DLL + 重启 Godot + 重新生成地图验证。本机无法编译/跑 Godot，验证必须由用户完成。**

## 背景：用户对生成结果的 4 条反馈
1. 总体还行（无需改）
2. 陆地稍微有点多（实测陆地 68~70%）
3. 浅海太多，严重缺近海/深海（实测海洋渲染分档：浅海 99%、近海 1%、深海 0%）
4. 极地出现温带草原（实测 STEPPE 中 32.8% temp<0.30）

## 关键诊断（CSV 实测，sea_level 真实默认=0.42）
- 海洋"浅/近/深"渲染色由 `biome_color.gdshaderinc::water_depth_gradient` 按像素高程 `depth_t=1-elev/sea_level` 分档，与 terrain 枚举无关。
- 洋底 elev 普遍 0.28~0.42 → depth_t 仅 0.05~0.33，全落浅海/浅近海档；要 basin/abyss 需 elev<0.19/<0.12，海床根本没那么深。
- 根因：双峰地台模型用"大陆性噪声 C"驱动洋底深度（`wt=(0.5-C)*2`），在陆地铺满、缺开阔洋面的图里 wt 到不了 1 → 洋底卡在大陆架深度。**陆地多 + 深海缺是同一病根。**
- STEPPE：`pk_decide_terrain_ex` 凉温带(temp 0.20-0.38)分支 `moist>0.22→STEPPE`，无温度下限 → 亚极地也判温带草原。

## 本轮改动（4 项，均生成期，改 C++ 须重编）
所有改动文件：
- `gdext/src/world_ext.cpp`
- `Project/project-keynes/scripts/geography/map_generator.gd`（STEPPE 镜像）
- `docs/cpp-dots-runtime/computation-pipelines.md`（专节同步）

### A. 距岸距离驱动洋底深度（主力根治，#3）
位置：`run_native_world_generate_base_pass` 内，`dist_ocean` 多源 BFS 之后（紧邻 `auto ocean_influence` 之前）。
做法：新增**源=陆地(E≥sea_level)的多源 BFS** → `shore_dist`（水格到最近陆地步数，复用 `index_for_qr(Q[cur]+DQ[d], R[cur]+DR[d])` 邻居）；按 smoothstep 单调加深洋底：
- 贴岸 shore_dist=1 → 大陆架浅（depth=`PK_SHELF_DEPTH`=0.03）
- 离岸 ≥`PK_SHORE_DEEP_DIST`(=7) 格 → 深海平原满深度（depth=`sea_level*PK_OCEAN_DEPTH_FRAC`=0.378，elev≈0.042，depth_t≈0.90）
- 只重写水格 E（`E[i]=sea_level-depth`，恒<sea）；陆地不碰；海岸线形状不变。
- 全海无陆参照（shore_dist=-1）→ 保留双峰占位。

### B. PK_CONT_THRESH 0.16 → 0.22（#2 + #3）
海陆阈值抬高 → 大陆更小、海洋更宽（为 A 提供足够离岸距离）。

### C. 双峰水侧 wt 注释更正
wt 凹幂律(p=0.62)现仅作"占位深度"（被 A 覆盖），注释已说明；A 关闭时是合理回退。

### D. STEPPE 温度门限（#4，C++ 与 GDScript 双同步）
凉温带分支：仅 `temp>0.30` 保留 STEPPE；更冷按湿度回落 TAIGA(13)/TUNDRA(8)/COLD_DESERT(26)。
- C++：`pk_decide_terrain_ex`
- GDScript：`map_generator.gd::_decide_terrain`（季节重判一致，铁律）

## 新增可调旋钮（C++ constexpr，base pass 内）
| 常量 | 值 | 调大效果 |
|---|---|---|
| `PK_SHORE_DEEP_DIST` | 7 | 调小→深海更普遍（更窄的海也变深） |
| `PK_SHELF_DEPTH` | 0.03 | 大陆架最浅下潜 |
| `PK_CONT_THRESH` | 0.22 | 调大→大陆更小、海洋更宽 |
（深海绝对深度沿用既有 `PK_OCEAN_DEPTH_FRAC`=0.90）

## 一致性核实（已做，无冲突）
- 洋底 E 重写在 base pass；post_base @~15356 用同一 E 重判 OCEAN/COAST（elev<sea-0.06→OCEAN）→ 深海格正确判 OCEAN、浅格 COAST，与 shader 深度色一致。
- `dist_ocean` 在重写前算，重写只让 E 更小仍<sea，mask 不变 → 一致。
- erosion/hypso 重映射跳过水下格（不改水下 E）。

## ⚠️ 上一轮"没生效"的教训（务必避免重演）
用户上次重新生成但 **DLL 没真正重编译**（scons 判定 up-to-date 跳过；两个 target DLL 只差 16 秒不可能编完上万行）。GDExtension **不热重载**，必须完全重启 Godot 进程。

## 验证步骤（用户执行）
```powershell
cd d:\Godot\ProjectKeynes\Project.Keynes\gdext
scons -c                 # 清 .obj 强制全量重编
.\build_and_run.ps1      # 编译 + 复制 DLL + 启动 Godot
```
确认：
1. scons 输出有 `Compiling ... world_ext.cpp`（明显变慢，几十秒+），非 "up to date"。
2. Godot 是脚本拉起的全新进程。
3. 重新生成地图 → 导出新 CSV。

**单一硬指标**：洋底 `min elev` 应从 0.286 骤降到 ~0.04。掉下去=距岸深度生效、深海回来。
辅助：terrain 分布里 OCEAN(0) 占比应明显上升（从 ~0.4% 升到合理值），COAST(1) 下降；STEPPE 的 temp<0.30 占比应≈0。

## 微调预案（拿到新 CSV 后）
- 深海仍少 → `PK_SHORE_DEEP_DIST` 7→5（更窄的海也变深）。
- 陆地仍偏多 / 海洋不够宽 → `PK_CONT_THRESH` 0.22→0.26。
- 深海太多/太突兀 → `PK_SHORE_DEEP_DIST` 调大，或 `PK_OCEAN_DEPTH_FRAC` 略降。
- 若 STEPPE 改动导致亚极地 TUNDRA/COLD_DESERT 过多 → 微调 D 分支的湿度阈值（0.28/0.16）。

## 临时文件（可删）
`tmp/verify.txt`、`tmp/chk.txt`、本笔记 `tmp/water-tuning-handoff-20260626.md`。
