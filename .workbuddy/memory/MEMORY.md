# Project.Keynes 长期项目记忆

## 关键架构
- 地图生成三阶段：① GDScript 发请求 → ② C++ 算完全部 → ③ C++ 返回、GDScript 解包。权威文档：`Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md`
- 详见 skill：`.codebuddy/skills/map-generation-pipeline/SKILL.md`

## 关键运行参数（实际值，非 map_config 默认）
- sea_level = 0.42（main.gd:116 实际值；map_config.gd:13 的 0.64 是死默认，被 main.gd 覆盖）
- num_continents = 2（main.gd:114）
- 地图尺寸预设：小40×28 / 当前60×40 / 大100×64 / 自定义上限500×400
- river_map_reference_cells = 15000（缩放基准，N>15000 才触发 river_map_scale）

## 已诊断的大地图生成问题（2026-06-30）
- 河流密集根因：channel_init=16 为 150×100 调参，预设尺寸(<15000)下缩放失效；N>15000 时指数 0.65 亚线性不足
- 高原密集根因：PLATEAU 无密度上限(PEAK/RIFT 有)；高原阈值不随地图缩放；噪声归一化采样使造山带特征数固定
- 诊断报告：`D:/Godot/ProjectKeynes/大地图河流与高原过度密集诊断报告.md`

## 已修复（density-fix 2026-06-30，需 rebuild DLL 验证）
- 河流：缩放指数 0.65→1.0；min_length 指数 0.75→1.0；river_headwater_init 6→10
- 高原：新增 plateau_max_land_ratio=0.25 面积占比上限（按连通分量面积降序保留，余下降级HILL）；plateau_max_relief 按 pow(15000/N,0.25) 收紧；plateau_min_land_h 0.25→0.35；PK_PLATFORM_UNDULATE 0.03→0.04
- up_count 未单独归一化（指数1.0已隐含等价归一化，SPL式inv对up_count无效）
- 改动文件：world_ext_generate.cpp、world_ext_internal.h、climate_profile.gd、computation-pipelines.md

## 自然资源系统（2026-06-30 规划阶段，未实现）
- 状态：已完成 plan，代码实现被回退（git stash@{0} "resource-system-implementation"），用户要求先看 plan 不应用
- 设计：仅 C++ native 节点（SCHEDULE_GRAPH 末尾 `resource` 节点）；字符串公式 + C++ 递归下降解析器；有序覆写表（priority desc 首匹配）；每资源一个 F32 slot；首次 tick 用 init_formula 初始化
- 首批资源：WOOD（可再生）/ IRON（不可再生）/ HORSE（可再生，依赖草原 vegetation==9）
- 变量集：temp/moist/elev/lat/river_flow/soil_moist/reserve/season/tick + terrain/landform/vegetation/cover/has_river/is_water
- plan 文件：`C:\Users\hkinghuang\.workbuddy\plans\blazing-forging-darwin.md`
- 待用户确认 plan 后再实现
