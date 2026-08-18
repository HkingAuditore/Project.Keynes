# 气候运行时现状与风险

## 目录

- 快照日期与事实优先级
- 当前生产状态
- 系统状态表
- Retained boundaries
- Fallback与兼容
- 已知风险
- 禁止重复的失败方向
- 维护清单

## 快照日期与事实优先级

本文件基于 2026-07-29 仓库状态。每次使用时按以下顺序重新确认：

1. `gdext/src/system_schedule.cpp` 与相关 C++/GDScript调用点。
2. `Project/project-keynes/data/world/*.tres` 生产profile override。
3. `component_schema.gd` 与生成bind table。
4. 当前runtime文档。
5. 历史计划、日志和旧skill描述。

已发现的历史漂移：

- 旧摘要曾写 Pass-A→ocean→Pass-B；当前源码是 Pass-A→Pass-B→ocean。
- 旧摘要曾把 runtime hydrology列为graph blocker/图外；当前源码已含条件式hydrology节点。
- `ClimateProfile`脚本默认`native_daily_sim_mode=OFF`，但`earth_like`生产资源明确override为ACTIVE；不得只看脚本默认判断生产状态。

## 当前生产状态

`earth_like.tres`：

- ACTIVE native daily，stride/lag 10。
- spread across ticks、coarse yield、split weather。
- ocean water/land node-range、ocean thread variant。
- finalizer slicing + native publish。
- climate/weather/ocean/season active owner gates。
- legacy daily climate/weather/sea-ice production retired。
- runtime hydrology与physical cell slicing开启。
- daily wind period 6、slow ocean period 60。

`earth_like_mobile_complex.tres`：

- ACTIVE native daily，stride/lag 20，单slice/tick。
- spread、split weather、owner gates、legacy retirement。
- runtime hydrology开启。
- daily wind period 6、slow ocean period 60。
- weather advect降到4；重型feedback cadence降低。
- 未显式继承桌面profile所有可选node-range/thread/native-finalizer开关；以资源实际字段和脚本默认合成。

## 系统状态表

| 子系统 | 现状 | 主要风险/剩余边界 |
| --- | --- | --- |
| Pass-A | C++ scalar/thread，native graph使用thread；annual-insolation cache | 内部timing历史可能低报；knob镜像与dt |
| Pass-B | C++ scalar/SIMD/thread，native graph使用thread | 海冰尾循环/knob漏镜像历史风险；顺序不可回退 |
| Ocean heat | C++ water/land，支持node-range/thread配置 | PackedArray JIT patch、半发布、fallback旧语义 |
| Wind heat | C++ air/surface；surface唯一写最终temp | 单位方向/速度混用、旧DLL temp packing |
| Sea ice | C++ graph与独立fallback；dt-aware、迟滞、edge mix | terrain flip/visual sync、cadence台阶 |
| Transpiration | C++与async pure kernel | compute通常低，边界sync/dirty可能主导 |
| Albedo/vegetation/feedback | C++ stage-b子pass | succession object/visual apply仍在GDScript |
| Weather | native field/commit/distribute/summary/split交易可ACTIVE | Front object、LUT/upload、repair/readiness |
| Hydrology | native graph节点，生产profile开启 | weather有效降水顺序、parent拓扑、flush成本 |
| Physical ocean | C++ SLP/wind/PSI/current/upwelling | visual raster/commit仍Godot；PSI不可随意range |
| Native daily | slice continuation、owner/report/finalizer | bundle/JIT/round-trip、commit lag、finalizer |
| Climate visuals | per-cell LUT/atlas C++编码辅助 | Image/ImageTexture/RID生命周期仍Godot |
| Climate→economy | plant water/temp30d slot冻结输入 | 经济结算不是climate authority |

## Retained boundaries

这些边界保留不代表native daily不完整：

- WeatherFront Godot对象构造、池与front publish。
- Image、ImageTexture、RID、GPU upload。
- enum/dynamic/ecology/weather LUT和atlas的Godot资源生命周期。
- ocean/wind pixel raster commit与overlay buffer。
- terrain/sea-ice facade、HexCell兼容读取。
- vegetation succession candidate的HexCell/MapData/visual apply。
- detail scatter与MultiMesh更新。
- CSV采样、debug overlay和UI。
- reset/abort/stale-DLL/probe编排。

只有当这些边界重新推进模拟状态或阻止slot提交时，才升级为authority blocker。

## Fallback与兼容

- Legacy `ClimateDailySystem`保留sync/async/failure/diagnostic路径；生产profile已退休独立daily production registration。
- `run_native_daily_tick_from_job()`只用于debug/full-run；`run_native_sim_tick_from_job()`用于SHADOW/A-B。
- Weather staged path和publish repair保留为readiness/probe/failure保护。
- OceanCurrents wrapper内部legacy job保留physical/visual状态与fallback。
- Sea-ice独立system在async climate启用时必须避免与worker重复执行。
- 旧DLL通过`has_method()`和能力探针回退；源码有方法不证明当前加载DLL已更新。
- GDScript weather/ocean fallback部分仍可能使用旧合成语义；不要在无A/B时随意“顺手修齐”，也不要让其静默命中生产。

## 已知风险

1. **文档/注释漂移**：图顺序和owner状态变化快，必须查源码。
2. **双/多份公式漂移**：weather C++/GDScript、climate scalar/thread/async、split/monolithic最容易漏项。
3. **Knob命名漂移**：async/native bundle若凭直觉命名，会静默使用错误默认值。
4. **CoW可见性**：C++计算正确但MapData/CSV全0，常是commit/flush问题。
5. **Finalizer遗漏**：温度/TTA/thermal cap未执行会造成长期偏移或极端值。
6. **dt错误**：stride>1却按1天推进会造成EMA、海冰、transition、水文明显慢跑；重复consume会双推进。
7. **半轮发布**：range/slice中途让下游读到部分新值会破坏确定性。
8. **Budget错因**：调度无法抢占单次native pass；加budget不能修节点峰值。
9. **视觉与模拟混淆**：GPU upload慢不等于climate compute慢；visual skip不一定是authority failure。
10. **天气录制错源**：weather diagnostics必须读weather report，分类snapshot与current state不是同一时刻。
11. **Profile层级**：脚本默认、earth-like和mobile override不同；调参必须指出修改层。
12. **长期反馈过拟合**：短录制无法证明海冰季节相位、Köppen分布、植被演替和水文稳定。

## 禁止重复的失败方向

- 不把全屏云做昂贵raymarch来解决top-down天气表现；收益与采样成本不匹配。
- 不用prescribed行波硬调降水来制造“移动天气”；历史尝试破坏blob分布且不涌现。
- 不在Pass-A/Pass-B compute-bound路径上优先做SFC或融合。
- 不为Pass-A超越函数热点手写低精度AVX2，除非有严格ULP与端到端收益证据。
- 不把PSI Gauss-Seidel简单按cell range并行。
- 不靠`must_run=true`堆叠native daily与season刷新。
- 不在每个native stage前全量refresh。
- 不在C++已发布后让GDScript全量unpack/write。
- 不用`temp > 0`判断有效值。
- 不把wind direction模长当wind speed。
- 不让非降水天气的残余precip进入水文。

## 维护清单

修改以下事实时同步更新本skill：

- native daily节点集合、顺序、yield/split/range行为。
- production profile ACTIVE/stride/budget/owner/fallback默认。
- field writer、schema、bind table、MapData字段。
- SAME_SOURCE镜像集合。
- `dt_days`来源与上限。
- publish/finalizer/repair/dirty contract。
- retained boundary或fallback退休状态。
-主要性能结论和no-go决策。
-测试文件名、运行命令、CSV字段和验收指标。
