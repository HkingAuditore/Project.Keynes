# template_overlay.gd — Migration Harness Template (B3)
#
# 复制这个清单（**纯文档，不是要运行的代码**）作为新模块接入 Data Overlay
# 调试通道的 9 步检查清单。原文是 performance-charter §12.6.4 的
# "用模板 #2 做下一个带邻居访问的真实 pass — 7 步清单"，本文件把它扩成
# 9 步并把 file path / hook function 都列出来，让"接 overlay"机械化。
#
# 该文件本身没有可执行的 GDScript 代码，刻意 `extends Resource` 占位让
# Godot import 不报错；engineer 阅读后请按下面的清单去改对应的 9 个文件。

@tool
extends Resource


# ════════════════════════════════════════════════════════════════════
# 接入新 demo overlay 的 9 步清单
# ════════════════════════════════════════════════════════════════════
#
# 假设你新增一个 pass `<name>` 写到 `cell.<name>` slot，要让它出现在
# 调试 overlay 里（按数值染色）。
#
# 每一步只改 1 个文件，按清单顺序做完即可。
#
# ─── Step 1：在 OverlayMode 加新模式 ─────────────────────────────
# 文件：scripts/rendering/overlay_mode.gd
# 改：在 enum MODE 末尾加 `<NAME>,`；在 mode_label / mode_hint 字典加
#     一行映射（中文显示名 + tooltip 说明）。
#
# ─── Step 2：在 climate_profile.gd 加开关 ────────────────────────
# 文件：scripts/data/climate_profile.gd
# 改：`@export var <name>_enabled: bool = false` + 必要的 tunable 参数。
#     同步在 DCFeatureFlags.FLAGS 里登记一行（注释 owner / default）。
#
# ─── Step 3：写 C++ pass（如需 dots_cpp 路径）────────────────────
# 文件：gdext/src/world_ext.cpp + .h
# 改：复制 performance-charter §12.6.2 的 run_thermal_gradient_pass 框架，
#     替换 slot 名 / 公式 / 边界条件；_bind_methods 加 ClassDB::bind_method。
#
# ─── Step 4：在 ComponentSchema 加 cell.<name> ──────────────────
# 文件：scripts/data_core/component_schema.gd
# 改：在 CELL_SCHEMA 末尾加一行：
#       { name = &"cell.<name>", cpp_name = "cell_<name>",
#         dtype = F32, track_prev = false,
#         map_field = "<name>_arr", prev_field = "",
#         owner = "<your_module>" }
# 跑 codegen：`python3 Project.Keynes/tools/codegen/gen_cpp_bind_table.py`
#
# ─── Step 5：在 MapData 加同名 PackedArray 字段 ─────────────────
# 文件：scripts/geography/map_data.gd
# 改：在文件头部 `var <name>_arr: PackedFloat32Array = PackedFloat32Array()`；
#     在 `_alloc_soa(n)` 里 `<name>_arr.resize(n)`；
#     在 `rebuild_soa_from_cells()` 里 `<name>_arr[i] = c.<field>`（如果 HexCell
#     上有对应字段）；
#     在 `flush_soa_to_cells()` 里 `c.<field> = <name>_arr[i]`（如果需要写回）。
#
# ─── Step 6：写 GDScript 对照实现 + bench ───────────────────────
# 文件：tmp/bench_<name>.gd（拷自 tools/migration_harness/template_bench.gd）
# 改：按 charter §12.6.3 公式同语义写 GDScript 版；bench 脚本里跑
#     bit-equal + µs 对照（容差按 charter §12.5 政策选定）。
#
# ─── Step 7：在 DataOverlayBaker 加染色逻辑 ────────────────────
# 文件：scripts/rendering/data_overlay_baker.gd
# 改：match overlay_mode 加新分支，对应 MODE.<NAME>；用 cell.index 索引
#     SoA（map.<name>_arr[cell.index]），按 [0,1] → color ramp 染色。
#
# ─── Step 8：（可选）shader 端 atlas 通道 ──────────────────────
# 文件：shaders/data_overlay.gdshader
# 改：如该 overlay 需要走 atlas 而非 polygon vertex color，加 uniform +
#     fragment 采样分支。
#
# ─── Step 9：接主流程 + debug menu 守门 ────────────────────────
# 文件：scripts/main.gd
# 改：在 `_on_day_changed`（或对应 SUS tick 钩子）末尾按开关调
#     `ext.run_<name>_pass(...)` + snapshot 回 map（如果 GDScript 端有
#     消费者，如 baker）；如果是 demo-only，把整段包在
#     `if cp.<name>_enabled` 里。
# 文件：scripts/ui/debug_console.gd
# 改：`ordered_modes()` 循环里按开关 skip 该 mode，避免开关关闭时
#     用户能切到一个空通道。
#
# ════════════════════════════════════════════════════════════════════
# 完成验收：
#   - bench bit-equal PASS（容差按 charter §12.5）
#   - 启动游戏，把 mode 切到 <NAME>，地图有可见花纹
#   - 关掉开关，mode 在 debug menu 里消失，不被误选
# ════════════════════════════════════════════════════════════════════
