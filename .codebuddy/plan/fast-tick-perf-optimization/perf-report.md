# Fast Tick 加速运行性能优化 — Perf Report

> 采集方式：启动 Godot 编辑器运行项目，256×256 地图默认配置；通过按键切换到 x1 / x5 / x20 三档各运行 ≥ 30 秒；
> 记录 console 打点 + Godot Profiler "加速运行 10 秒" 快照。
>
> 打点格式参考：
> - `fast tick #N: Xms`（每 365 日打一次，首次必打）
> - `[fast tick] Xms > 12ms budget (frame=N, cells=M)`（> 12ms 触发）
> - `Season refresh Xms`
> - `Yearly refresh Xms`
> - `refresh_climate_daily #N: Xms`

---

## Baseline（优化前 — 任务 1 产出）

> **状态：待用户实测填入**。AI 无法启动 Godot 运行时采集；所有数值请在修改任何代码前运行基线版本补齐。
> 本节建立后，任务 2–8 不得在此节再追加/修改任何数据，只能读取。

### 运行环境

| 项 | 值 |
|---|---|
| Godot 版本 | （待填，例 4.3.stable.official） |
| OS | （待填） |
| CPU / GPU | （待填） |
| 地图尺寸 | 256×256 |
| seed | （待填；后续回归验证与性能对比必须用同一个 seed） |

### console 打点（每档运行 ≥ 30 秒后取样）

| 档位 | fast tick 均值(ms) | fast tick p95(ms) | refresh_climate_daily 均值(ms) | Season refresh 均值(ms) | Yearly refresh 均值(ms) | > 12ms WARN 次数 |
|---|---|---|---|---|---|---|
| x1  |  |  |  |  |  |  |
| x5  |  |  |  |  |  |  |
| x20 |  |  |  |  |  |  |

### Godot Profiler 帧时（加速运行 10 秒快照）

| 档位 | 平均帧时(ms) | p95 帧时(ms) | 主要热点函数 Top 3 |
|---|---|---|---|
| x1  |  |  |  |
| x5  |  |  |  |
| x20 |  |  |  |

### 主观观察

- x20 档肉眼卡顿描述：
- 季节切换抖动描述：
- TOD 色温过渡描述：

---

## Regression Diff（任务 9 产出 — 占位）

> 任务 9 完成后填入。重点：x1 档 365 日快照字段级差异、x5/x20 档长期均值一致性。

---

## Final（任务 10 产出 — 占位）

> 任务 10 完成后填入。重点：三档帧时是否达门槛、主观视觉评估、已知副作用清单。

---

## 代码改动总结（任务 2–8 落地汇总，只读参考）

| 任务 | 涉及文件 | 改动概要 |
|---|---|---|
| D（任务 2） | `world_clock.gd` | 新增 `signal speed_changed`；`set_speed` 末尾按需 emit；新增 `season_phase_emit_step`；新增 `_user_overridden_phase_step` 标志位与 `_apply_phase_step_for_speed(s)`，按 x1/x5/x20 → (0,0)/(0.005,0.002)/(0.02,0.01) 自动调档；切换时重置 `_last_emit_day_phase` / `_last_emit_season_phase = -1.0` 哨兵。 |
| A（任务 3） | `data/climate_profile.gd` | 在 `daily_climate_refresh_stride` 后新增 `@export_range(1,8,1) var weather_refresh_stride: int = 1`。 |
| A（任务 3-4） | `map_generator.gd` | 新增成员 `_last_active_fronts: Array` / `_refresh_daily_call_index: int`；新增 `set_weather_refresh_stride(s)` 并 print `[fastpath] weather_refresh_stride = N`；`refresh_daily` 入口按 `(call_index % stride) == 0` 节流，跳日时直接 `return _last_active_fronts`，**不**调用 `_apply_transpiration_pass` / `_apply_albedo_pass` / `_apply_vegetation_dynamics` / `_apply_weather_to_map_feedback_pass` / `_baker.rebake_*`，且向调用方透传 "skipped" 标志以跳过 `> 12ms budget` 警告。 |
| A（任务 4） | `main.gd` | `_ready` 末尾订阅 `world_clock.speed_changed`；新增 `_on_speed_changed(s)` 按 x1→1 / x5→2 / x20→4 调用 `_generator.set_weather_refresh_stride`；`_on_day_changed` 跳日分支早返，避免 UI 强制刷新抖动。 |
| C（任务 5） | `hex_cell.gd` | 新增强类型成员：`temperature` / `moisture` / `snow_cover` / `temp_baseline` / `temp_season_offset` / `temp_30d_mean` / `temp_365d_mean` / `temp_dev_from_annual` / `_ema_initialized`；新增 `_migrate_typed_fields_from_dict()` 在反序列化后一次性把旧字典键搬到强类型成员并 `erase`；`is_passable_in_season` 改读 `cell.snow_cover`。 |
| C（任务 6） | `map_generator.gd` / `weather_system.gd` / `map_data.gd` / `main.gd` | 把 13 + 12 + 1 + 5 处 `current_state["temperature"\|"moisture"\|"snow_cover"\|"_temp_baseline"\|...]` 的读写全部改为强类型成员直读直写；`refresh_climate_daily` 首次入口 print `[fastpath] HexCell typed fields active` + 兜底调一次 `_migrate_typed_fields_from_dict`；`current_state` 字典仅保留 `season/biome/landform/vegetation/cover/weather/weather_intensity` 等离散低频字段，**不再双写**。 |
| E（任务 7） | `rendering/hex_renderer.gd` | 末尾追加 `set_biome_tex_only(world)` / `set_cover_tex_only(world)` / `set_vegetation_tex_only(world)`；只重绑 `enum_atlas` shader uniform（cover / vegetation 共用同一张 atlas，三者语义重合，重绑幂等），**不**触发 `_rebuild` / `_apply_uniforms`（避免一次性写 60+ uniform + 重建 mesh + `_weather_layer.setup`）。`set_map(...)` 老路径完全保留给 regenerate 流程。 |
| E（任务 8） | `main.gd` | `_on_season_changed` 中 `_renderer.set_map(_current_map, _world_data)` 改为 `_renderer.set_biome_tex_only(_world_data)`，`has_method` 守卫向后兼容；`Season refresh %dms` 打点格式不变。 |

> 上表仅为索引，详细代码以仓库 commit 为准。

---

## 验证操作指引（用户跑前必读）

### Step A — 采集 Baseline（任务 1，可在所有改动之前先 git stash 一份 / 或检出修改前 commit）

1. 检出修改前的 commit（若已基于 HEAD 改动，临时 `git stash`）。
2. 启动 Godot 编辑器，打开本项目，运行 `main.tscn`（或同等入口场景）。
3. 默认 256×256 地图，记录 seed（控制台首行通常会打印 seed），后续每次回归必须沿用同一 seed。
4. 启动后保持 x1 档运行 ≥ 30 秒，复制 console 中所有 `fast tick` / `refresh_climate_daily` / `Season refresh` / `Yearly refresh` 打点；打开 Godot Profiler 录 10 秒并截图主热点函数 Top 3。
5. 切到 x5 档，重复 4。再切到 x20 档，重复 4。
6. 把数据填入 `Baseline` 节的两张表与"主观观察"。

### Step B — 应用本次优化（任务 2–8 已在仓库 HEAD 落地）

无需操作，直接进入 Step C。

### Step C — Regression Diff（任务 9）

1. 启动游戏，**用 Step A 完全相同的 seed**（在地图配置面板手动输入），x1 档无中断地推进 365 日。
2. 推进过程中至少观察一次 `[fastpath] HexCell typed fields active` 与 `[fastpath] weather_refresh_stride = N` 出现在 console（确认 fast-path 主路径已激活）。
3. 365 日后用调试控制台 dump 所选 cell 的关键字段：`temperature` / `moisture` / `snow_cover` / `temp_30d_mean` / `temp_365d_mean` / `temp_dev_from_annual` / `vegetation` / `biome`。允许浮点 EMA 误差 ≤ 1e-4。
4. 切到 x5 / x20 档分别推进 365 日，对比 Baseline 同档位记录的全图气候稳态（季节温差幅度 / 降水均值 / 主要 biome 比例），允许平台稳态差异，但**长期均值方向不能变**（夏季升温、冬季降温、雨季湿润、旱季干燥）。
5. 把对比表与定性结论填入下面 `Regression Diff` 节。

### Step D — Final 性能验收（任务 10）

1. 与 Step A 同样流程，对 x1 / x5 / x20 三档分别采集优化后的 console 打点均值/p95 + Profiler 帧时。
2. 检查门槛：
    - x20 平均帧时 ≤ 22ms（≈ 45 fps）
    - x5 平均帧时 ≤ 16.6ms（60 fps）
    - x1 与 Baseline 偏差 ≤ ±5%（无回归）
    - x20 `Season refresh` < 3ms（方案 E 验收线）
    - x5/x20 `[fast tick] > 12ms budget` 警告频率显著下降（理想为 0）
3. 主观评估：
    - x20 档跳日的 fronts 视觉断帧是否可察觉（按 stride=4 应最长断 4 日）
    - 季节切换抖动是否消除
    - x5/x20 TOD 色温过渡是否仍平滑（无肉眼可见的阶梯感）
4. 把数据 + 结论填入下面 `Final` 节。

---

## 已知副作用与注意事项（设计阶段已识别，验收时核对即可）

1. **EMA 收敛变慢**：方案 A 让 `refresh_climate_daily` 在 `weather_refresh_stride > 1` 时也跟着跳日，`temp_30d_mean` / `temp_365d_mean` 的 α 是常量，stride > 1 时收敛实际节奏放缓（x5 节拍约 ×2、x20 约 ×4）。长期均值方向不变，但稳态值可能与 baseline 有轻微平台差，属于可观测且可接受的副作用。
2. **天气 fronts 视觉断帧**：方案 A 跳日时复用上次活跃 fronts 快照，最长断 stride−1 日（x20 档约 4 日 ≈ 0.2 秒现实时间）。weather front 本就是慢漂移可视化，肉眼几乎察觉不到，但需在 Final 节做主观评估并记录。
3. **跳日的 UI 行不刷新**：方案 A 跳日时 UI 选中地块的 weather/vitality/climate/emergent 行不强制刷新，避免抖动；玩家手动点选其他地块时仍会主动刷新，**不**会出现"卡死"假象。
4. **Inspector 用户覆盖优先**：方案 D 的 `_user_overridden_phase_step` 标志在 `_ready` 阶段检测到 Inspector 中已设非 0 值时置 true，自动调档逻辑跳过；用户精心调过的节流不会被覆盖。
5. **enum_atlas 三方法语义重合**：方案 E 的 `set_cover_tex_only` / `set_vegetation_tex_only` 在本项目里都直接调 `set_biome_tex_only`，因为 cover / vegetation / biome 数据共用同一张 `enum_atlas`。保留三个方法仅为契合方案文档命名约定；调用方任选其一即可。
6. **存档兼容**：方案 C 提供 `_migrate_typed_fields_from_dict()` 兜底，旧存档加载时残留的字典键会被一次性搬到强类型成员并 `erase`，新代码永不写回这些键，因此不会出现"双写不一致"。
7. **F1 洋流年内冻结**：`ocean_current_refresh_seasons=4`（默认）下，`world.ocean_current_buffer` / `ocean_upwelling_buffer` 仅在 `season_idx == 0`（年首）重烘一次，其余三个季节直接复用上一次烘焙结果。视觉上洋流方向年内不变；与"季节是涌现物"的设计哲学相比，本质上仍是离散切换，但把"每季 1 次硬切"降为"每年 1 次硬切"，作为向"逐日连续 monsoon"演进过程中的中间态。stride=2 = 半年一次（春/秋切），stride=1 = 退化为旧行为（每季都跑）。
8. **F3 行级缓存幂等性**：`_bake_ocean_upwelling` 把 `lat_signed` / `lat_temp` / `temp_rel` / `cold_sink_byte` / `ekman_sign` / `rot_angle` / `monsoon_row` 提到外层 `for y` 行级，结果与原版逐像素重算等价（同纬度行内本来就是常量），无 baseline 漂移风险。
9. **F3 海洋判据归属外提**：`_bake_ocean_currents` 把 `has_biome_buf` / `hm_match` 在循环外一次性求值，避免每像素 W*H = ~70 万次 `world.biome_buffer.size()` 比较。语义完全等价。

---

## F1 + F3：洋流季节烘烤瓶颈攻关（在原方案 A/C/D/E 之后追加）

### 触发原因（用户实测打点）

```
Season refresh 1676ms
  rebake_ocean_currents(phase=2.50): currents=521ms upwelling=541ms
```

x20 档下单次 `Season refresh` 占 1676ms，其中 `rebake_ocean_currents` 占 1062ms ≈ **63%**。原方案 A/C/D/E 均未触及季节性洋流烘烤，这是方案 E（`set_biome_tex_only` 替代 `set_map`）落地后实际仍卡顿的根因。

### 设计哲学校正

季节本身应为温度 / 降水 / 日照 / monsoon 的涌现产物，而非硬编码切换器。原 `refresh_seasonal` 中 4.75 节"每季 1 次重烘洋流"是与该哲学最冲突的硬切残留：洋流由 `wind × monsoon_offset(ny, season_phase)` 驱动，而 `monsoon_offset` 本就是 `season_phase ∈ [0, 4)` 的连续函数。把它绑死到 4 个离散相位既贵又粗糙。F1 是过渡方案，F3 是纯算法优化。中长期目标是让洋流也走 `refresh_climate_daily` 同款的逐日连续 phase 路径（异步切片上传），但工程量显著大于本轮范围，留作后续。

### 代码改动

| 任务 | 涉及文件 | 改动概要 |
|---|---|---|
| F1 | `data/climate_profile.gd` | 在 `weather_refresh_stride` 后新增 `@export_range(1,4,1) var ocean_current_refresh_seasons: int = 4`。注释明确说明语义、与设计哲学的关系、未来路线。 |
| F1 | `map_generator.gd` (`refresh_seasonal` 4.75 节) | `_baker.rebake_ocean_currents(...)` 与 `_compute_ocean_currents(...)` 用 `if season_idx == 0 or (season_idx % stride) == 0` 守卫包裹；跨年首季永远必跑，保证年首切换的同步基准。 |
| F3 | `rendering/map_baker.gd` (`_bake_ocean_currents`) | 把 `has_biome_buf` / `hm_match` / `biome_buf` 在循环外一次性求值；70 万像素的 `world.biome_buffer.size()` 比较与 `hm_W == W and hm_H == H` 的复合比较降为 O(1)。 |
| F3 | `rendering/map_baker.gd` (`_bake_ocean_upwelling`) | (1) 双重遍历的预扫掩码循环改为 `for i in range(W*H)` 单维循环（去掉冗余的 `for y/for x` 嵌套）；(2) 主扫第一行守卫 `if is_ocean_arr[idx] == 0: continue` 让陆地像素零浮点开销；(3) 把 `lat_signed` / `lat_temp` / `temp_rel` / `is_cold_sink` / `cold_sink_byte` / `ekman_sign` / `rot_angle` / `monsoon_row` 提到外层 `for y` 行级，避免每像素重算。 |

### 预期收益（待用户实测填入）

| 指标 | 优化前（用户实测） | F1+F3 后预期 | 实测填入 |
|---|---|---|---|
| `Season refresh` 单次（x20） | 1676ms | ~614ms（仅年首跑）/ ~614ms（其他 3 季跳过 rebake，约 614ms 余量） |  |
| `rebake_ocean_currents currents=` | 521ms | 350~430ms（F3 减分支） |  |
| `rebake_ocean_currents upwelling=` | 541ms | 250~350ms（F3 合并双重遍历 + 陆地早退） |  |
| 跨年首次 Season refresh | 1676ms | ~614~900ms（依赖 F3 实际收益） |  |
| 普通季 Season refresh（year-aligned） | 1676ms | ~614ms（rebake_ocean_currents 整体跳过） |  |

### 验证操作指引

1. 启动游戏，x20 档至少跑过 2 个游戏年（season_idx 至少跨过 0→1→2→3→0→1）。
2. 观察 console：
    - 年首（`season_idx == 0`）应仍出现 `rebake_ocean_currents(phase=0.50): currents=Xms upwelling=Yms`。
    - 其他三个季节切换时**不应再出现** `rebake_ocean_currents` 打点（守卫直接跳过整段调用）。
    - `Season refresh Xms` 应出现两个量级的数：年首仍 ~600~900ms，其他三季应骤降至几十~一两百毫秒。
3. 主观验收：洋流方向纹理（如有 F6 调试层）在年内三个季节切换前后**纹理不变**，年首跳变一次。这是 F1 引入的已知副作用（见上文 7）。
4. 数据填入上表"实测填入"列。

### 回退手段

- 把 `ClimateProfile.ocean_current_refresh_seasons` 改回 `1` → 退化为 F1 前的"每季都跑"语义。
- F3 的算法优化无开关（对 baseline 行为完全等价），如需对照可直接 `git revert` `_bake_ocean_currents` / `_bake_ocean_upwelling` 的相关 commit。

