# 气候性能、诊断与验证

## 目录

- 诊断原则
- 日志读法
- 热点分类
- 已落地优化
- 优化决策
- 测试矩阵
- 命令
- CSV 真实性验证
- 验收门槛

## 诊断原则

按以下顺序定位：

1. 读完整 `[fast tick WARN]`，定位 `largest=job/stage/substage path=...`。
2. 对照当前 tick 的 job breakdown，避免把窗口旧 spike 当当前路径。
3. 读 `[SUS-cpp] last N ticks` 的 avg/p95/max、ran、slices、skipped。
4. 确认 stage/cursor/done 与 cadence/contract。
5. 拆 `native/compute/apply/flush/refresh/sync/write/mark/upload`。
6. 确认 `published_to_slot`、visible publish、dirty 与 fallback reason。
7. 排除旧 DLL、方法未绑定、slot 缺失、size mismatch、recorder report 取错。
8. 最后才改算法、并行或预算。

## 日志读法

Native daily：

- `native_ms`/`total_ms` 是当前 slice wall。
- `round_native_ms` 是本轮累计。
- `done=false` 表示 continuation，不是失败。
- `stage_name` 对应 graph node或split-weather子节点。
- `published_slots` 和 visual intents 只在完成 slice 出现。
- `commit_over_budget=true` 是降频契约违约，不能当正常 stale tolerance。
- per-group `climate_ms` 可能来自 pass 返回值，不能替代 slice wall；某些历史 pass 内部计时为 0。

常见 slow dump：

```text
[native_daily/slow-dump] ... wall bundle jit native_call cpp compute refresh flush apply round ...
[native_daily/slow-dump/weather] field commit dist summary cyclone stage_b ...
[native_daily/slow-dump/finalizer] total cell temp tta thermal sea_ice precip write_mode ...
```

Hydrology：

- `compute_ms` 高：产流/路由本体。
- `flush_ms` 高：MapData发布/CoW。
- `refresh_ms` 高：天气到水文的同步。
- `published_to_slot=false`：先查 knobs、schema/bind和weather publish。

Weather：

- `field_commit_publish_verified=true` 才证明visible commit。
- `field_commit_publish_repaired=true` 说明走了GDScript repair，native可见权威仍不完整。
- 全 CLEAR + continuous arrays全0 + init count 0 是发布失败，不是自然晴天。
- `weather_commit_tick_delta` 是天气生命周期的日轴，不要用partial solver tick算持续天数。

Ocean：

- `psi_path=gdscript` 在 PSI 未执行前可能只是默认值；看真实 PSI stage、published与fallback。
- current强度看 `sqrt(x²+y²)` 与 preclamp p95/max、clamp ratio。
- raster/upload耗时不属于物理 kernel。

Transpiration/finalizer：

- native compute低但wall高，查refresh、sync、dirty、write。
- finalizer高时拆cell/temp/TTA/thermal/sort/dense/sparse dirty collect。
- `mixed_sparse_dense` 是按component独立选择；高dirty时dense可能合理。

## 热点分类

| 现象 | 首查 |
| --- | --- |
| C++ compute低，wall高 | Dictionary/PackedArray打包、refresh、flush、snapshot、report、GDScript apply |
| 单节点超过frame budget | pass内部range/stage切片；scheduler无法抢占 |
| 多节点累计高 | yield粒度、round-trip、coarse spread、重复bundle patch |
| `frame_budget_exhausted` 多 | 更早 job、must_run、单节点尖峰、bucket碰撞 |
| 视觉滞后但模拟正常 | dirty queue、stride、ImageTexture upload；不要提升为simulation must_run |
| fallback偶发 | stale DLL、`has_method`、binding、slot size、knob缺失、readiness |
| 数值台阶/过慢 | stride与真实dt补偿、commit lag、同tick重复consume |
| CSV物理异常 | recorder取值来源、commit cadence、visible publish、分类snapshot |

## 已落地优化

以当前源码复核后再引用：

- Pass-A年均日照按纬度/行星参数指纹缓存，消除每日16样本积分。
- Pass-A/Pass-B在native graph使用deterministic thread variant；大图约4.7–5.6x。
- Pass-A/Pass-B已判定compute-bound，手写AVX2、融合和SFC收益不足。
- Wind-air可直接读`cell_temp` slot，减少全图PackedArray knob。
- Native daily支持spread、coarse yield、split weather、ocean water/land node-range、finalizer slicing/native publish。
- SLP使用latitude LUT；daily wind可拆SLP/wind两天交替。
- PSI使用warm start和residual early exit。
- Physical ocean把物理与视觉状态机分离；leaf pass支持可选range slicing。
- cell-index atlas + per-cell LUT消除多数逐像素动态上传。
- climate moisture可defer visible publish到round finalizer，减少半轮MapData震荡。

## 优化决策

先测量：

- 小图（约2400–6400 cells）常见最优是scalar或少量thread；dispatch可能大于compute。
- 大图才启用`parallel_for_range`；证明每个task写独占range、只读稳定快照。
- 不并行Gauss-Seidel/SOR的有序迭代，除非更换算法并重新验证收敛。
- 不把全局归约拆成独立range后提前发布。
- 不让async worker调用Godot API、Object、Dictionary或共享可变vector。
- 不用降采样掩盖精度/稳定性，除非明确建立sample/commit lag与dt补偿契约。

每次性能改动保留：

- baseline/after同地图、同seed、同profile、同build。
- avg/p95/max与largest stage。
- fallback count、skipped、published、dirty。
- 数值parity/hash/ULP或明确容差。
- 生产平台（desktop/mobile）分别证据。

## 测试矩阵

Graph/authority：

- `native_daily_graph_order_test.gd`
- `native_daily_hydrology_graph_test.gd`
- `native_daily_weather_split_graph_test.gd`
- `native_daily_active_bootstrap_test.gd`
- `native_daily_shadow_test.gd`
- `native_daily_shadow_runtime_test.gd`
- `native_daily_shadow_soak_test.gd`
- `native_weather_daily_readiness_test.gd`

Formula/state：

- `native_dt_compensation_probe_test.gd`
- `native_wind_surface_zero_baseline_test.gd`
- `native_wind_surface_transport_budget_test.gd`
- `native_ocean_water_sea_ice_suppression_test.gd`
- `native_sea_ice_state_machine_test.gd`
- `sea_ice_solar_gate_formula_test.gd`
- `vegetation_climate_loop_formula_test.gd`
- `weather_field_solver_test.gd`
- `weather_profile_regression_test.gd`
- `weather_front_shape_test.gd`

Performance/integration：

- `climate_pass_bench.gd`
- `climate_pipeline_spike_reduction_test.gd`
- `production_climate_math_test.gd`
- `production_climate_runtime_test.gd`

按修改面选最小集合，再加graph-order和dt测试作为高风险默认。不要因为单元公式绿就跳过visible publish和soak。

## 命令

在 `Project.Keynes` 仓库根目录运行 schema codegen：

```powershell
python tools/codegen/gen_cpp_bind_table.py
```

重建 Windows GDExtension：

```powershell
Set-Location gdext
scons platform=windows target=template_debug dev_build=no -j8
scons platform=windows target=template_release dev_build=no -j8
```

关闭Godot后重建，并完全重启以加载新DLL。`gdext/rebuild.bat` 是交互式辅助脚本；自动化时直接使用非交互SCons命令。

运行SceneTree测试：

```powershell
godot --headless --path Project/project-keynes --script res://tests/native_daily_graph_order_test.gd --quit
godot --headless --path Project/project-keynes --script res://tests/native_daily_hydrology_graph_test.gd --quit
godot --headless --path Project/project-keynes --script res://tests/native_daily_weather_split_graph_test.gd --quit
godot --headless --path Project/project-keynes --script res://tests/native_dt_compensation_probe_test.gd --quit
godot --headless --path Project/project-keynes --script res://tests/weather_field_solver_test.gd --quit
```

使用实际可执行文件路径替换`godot`。部分视觉shader/GPU问题不能由headless证明。

静态检查：

```powershell
rg -n "SCHEDULE_GRAPH|runtime_hydrology|stage_b_after_hydrology" gdext/src Project/project-keynes/scripts
rg -n "published_to_slot|fallback_reason|defer_visible_publish" gdext/src Project/project-keynes/scripts
rg -n "cell_temp|cell_moisture|cell_sea_ice_frac" Project/project-keynes/scripts/data_core/component_schema.gd gdext/src/component_bind_table.gen.h
git diff --check
```

## CSV 真实性验证

使用：

```powershell
python tools/analyze_tile_climate_csv.py <tile_data_record.csv>
```

至少30个committed tick；季节/海冰/气候型使用覆盖完整季节或年度的录制。固定观察：

- wind direction p95与>120° flip ratio。
- ocean current preclamp/clamp ratio。
- runtime moisture与base moisture相关性。
- sea-ice binary ratio、邻域p99、纬度合法性和季节相位。
- weather commit path/init count/publish verified。
- precipitation/cloud water/vapor、rain duration、transition lifecycle。
- soil/WB30/plant water/vegetation vitality/stress。
- hydrology discharge p95/max、storage、runoff与dt。

区分：

- `sample["climate"]`：climate/native daily/finalizer。
- `sample["weather"]`：weather commit/convergence/front。
- classification snapshot：天气决策时输入。
- 当前MapData：提交后状态。

不要把分类snapshot与后续current state差异误判为分类器bug。

## 验收门槛

功能：

- graph order测试通过。
- native/fallback/thread/async需要的镜像在约定容差内。
- `published_to_slot=true`且visible消费者读到同一完成态。
- fallback count为0或原因可接受且明确。
- 无NaN/Inf、越界、低纬海冰、陆地海冰、非法weather type。
- cadence和dt契约不违约。

性能：

- 报告before/after avg/p95/max与largest。
- 单slice满足目标或有明确range/stage计划。
- `frame_budget_exhausted`不长期饿死authority job。
- native compute下降不以flush/sync/upload回归抵消。
- dirty量与真实变化相符，不因dense重复写全图标脏。

真实性：

- 使用多seed/长窗口，不用单seed截图定稿。
- 每个调参说明预期因果链、受影响指标和副作用。
- 避免prescribed视觉波代替状态驱动的涌现机制。
