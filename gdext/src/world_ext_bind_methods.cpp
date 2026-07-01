#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_methods() {
    using namespace godot;

    ClassDB::bind_method(D_METHOD("register_component", "name", "dtype", "stride", "track_prev"),
                         &DCWorldExt::register_component, DEFVAL(1), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("component_id", "name"),     &DCWorldExt::component_id);
    ClassDB::bind_method(D_METHOD("component_count"),          &DCWorldExt::component_count);
    ClassDB::bind_method(D_METHOD("has_component", "name"),    &DCWorldExt::has_component);
    // Fix #11 second pass (2026-06-16) — PKLog.enabled C++ mirror。
    ClassDB::bind_method(D_METHOD("set_diag_logs_enabled", "v"), &DCWorldExt::set_diag_logs_enabled);
    ClassDB::bind_method(D_METHOD("get_diag_logs_enabled"),       &DCWorldExt::get_diag_logs_enabled);

    ClassDB::bind_method(D_METHOD("create_entities", "count"), &DCWorldExt::create_entities);
    ClassDB::bind_method(D_METHOD("entity_count"),             &DCWorldExt::entity_count);

    ClassDB::bind_method(D_METHOD("create_pool", "name", "capacity"), &DCWorldExt::create_pool);
    ClassDB::bind_method(D_METHOD("pool_range", "pool_id"),           &DCWorldExt::pool_range);
    ClassDB::bind_method(D_METHOD("pool_id", "name"),                 &DCWorldExt::pool_id);
    ClassDB::bind_method(D_METHOD("pool_count"),                      &DCWorldExt::pool_count);
    ClassDB::bind_method(D_METHOD("pool_free_count", "pool_id"),      &DCWorldExt::pool_free_count);

    ClassDB::bind_method(D_METHOD("view_f32", "comp_id"), &DCWorldExt::view_f32);
    ClassDB::bind_method(D_METHOD("view_i32", "comp_id"), &DCWorldExt::view_i32);
    ClassDB::bind_method(D_METHOD("view_u8",  "comp_id"), &DCWorldExt::view_u8);

    // Mode-B snapshot API (recommended; see performance-charter.md §12)
    ClassDB::bind_method(D_METHOD("snapshot_f32", "comp_id"), &DCWorldExt::snapshot_f32);
    // B3b：snapshot_i32 / snapshot_u8 给 streak（I32）+ 后续 save/overlay 补齐
    ClassDB::bind_method(D_METHOD("snapshot_i32", "comp_id"), &DCWorldExt::snapshot_i32);
    ClassDB::bind_method(D_METHOD("snapshot_u8",  "comp_id"), &DCWorldExt::snapshot_u8);
    ClassDB::bind_method(D_METHOD("encode_tile_csv_rows", "knobs"), &DCWorldExt::encode_tile_csv_rows);

    // Mode-B per-cell read API（plan/3b-single-read-source；HexCell facade
    // 21 hot getter 的 read 源——结构性消除 C++ flush 与 GDScript-DCWorld
    // SoA 脱钩类 bug，sea_ice_frac 冻结 + weather/climate/wind/ocean 同款 12 处）。
    ClassDB::bind_method(D_METHOD("read_f32", "comp_id", "idx"), &DCWorldExt::read_f32);
    ClassDB::bind_method(D_METHOD("read_i32", "comp_id", "idx"), &DCWorldExt::read_i32);
    ClassDB::bind_method(D_METHOD("read_u8",  "comp_id", "idx"), &DCWorldExt::read_u8);

    ClassDB::bind_method(D_METHOD("write_f32", "comp_id", "idx", "v"), &DCWorldExt::write_f32);
    ClassDB::bind_method(D_METHOD("write_i32", "comp_id", "idx", "v"), &DCWorldExt::write_i32);
    ClassDB::bind_method(D_METHOD("write_u8",  "comp_id", "idx", "v"), &DCWorldExt::write_u8);
    ClassDB::bind_method(D_METHOD("write_f32_range", "comp_id", "start", "src"), &DCWorldExt::write_f32_range);
    ClassDB::bind_method(D_METHOD("write_i32_range", "comp_id", "start", "src"), &DCWorldExt::write_i32_range);
    ClassDB::bind_method(D_METHOD("write_u8_range",  "comp_id", "start", "src"), &DCWorldExt::write_u8_range);

    ClassDB::bind_method(D_METHOD("write_f32_indexed", "comp_id", "indices", "values"), &DCWorldExt::write_f32_indexed);
    ClassDB::bind_method(D_METHOD("write_i32_indexed", "comp_id", "indices", "values"), &DCWorldExt::write_i32_indexed);
    ClassDB::bind_method(D_METHOD("write_u8_indexed",  "comp_id", "indices", "values"), &DCWorldExt::write_u8_indexed);
    ClassDB::bind_method(D_METHOD("write_f32_scalar_indexed", "comp_id", "indices", "v"), &DCWorldExt::write_f32_scalar_indexed);
    ClassDB::bind_method(D_METHOD("write_i32_scalar_indexed", "comp_id", "indices", "v"), &DCWorldExt::write_i32_scalar_indexed);
    ClassDB::bind_method(D_METHOD("write_u8_scalar_indexed",  "comp_id", "indices", "v"), &DCWorldExt::write_u8_scalar_indexed);

    ClassDB::bind_method(D_METHOD("bind_map_data", "map_data"), &DCWorldExt::bind_map_data);
    // sea-ice-snow-visual-fix-2026-06：bind 后注入 DCWorld 句柄，让 C++ 自动 mark dirty。
    ClassDB::bind_method(D_METHOD("bind_dirty_world", "dirty_world"), &DCWorldExt::bind_dirty_world);
    ClassDB::bind_method(D_METHOD("is_bound"),                  &DCWorldExt::is_bound);
    ClassDB::bind_method(D_METHOD("configure_native_world", "knobs"),
                         &DCWorldExt::configure_native_world);
    ClassDB::bind_method(D_METHOD("run_native_daily_tick", "tick_knobs"),
                         &DCWorldExt::run_native_daily_tick);
    ClassDB::bind_method(D_METHOD("run_native_daily_slice", "tick_knobs"),
                         &DCWorldExt::run_native_daily_slice);
    ClassDB::bind_method(D_METHOD("run_native_daily_finalizer", "knobs"),
                         &DCWorldExt::run_native_daily_finalizer);
    ClassDB::bind_method(D_METHOD("run_native_sim_tick", "ctx"),
                         &DCWorldExt::run_native_sim_tick);
    ClassDB::bind_method(D_METHOD("get_native_daily_report"),
                         &DCWorldExt::get_native_daily_report);
    ClassDB::bind_method(D_METHOD("get_native_shadow_diff_report"),
                         &DCWorldExt::get_native_shadow_diff_report);
    ClassDB::bind_method(D_METHOD("native_ocean_physical_begin", "ctx"),
                         &DCWorldExt::native_ocean_physical_begin);
    ClassDB::bind_method(D_METHOD("native_ocean_physical_step", "ctx"),
                         &DCWorldExt::native_ocean_physical_step);
    ClassDB::bind_method(D_METHOD("native_ocean_physical_finish", "ctx"),
                         &DCWorldExt::native_ocean_physical_finish);
    ClassDB::bind_method(D_METHOD("reset_native_ocean_physical_state", "reason"),
                         &DCWorldExt::reset_native_ocean_physical_state);
    ClassDB::bind_method(D_METHOD("get_native_ocean_physical_state_report"),
                         &DCWorldExt::get_native_ocean_physical_state_report);
    ClassDB::bind_method(D_METHOD("get_gameplay_event_schema"),
                         &DCWorldExt::get_gameplay_event_schema);
    ClassDB::bind_method(D_METHOD("publish_gameplay_events", "batch"),
                         &DCWorldExt::publish_gameplay_events);
    ClassDB::bind_method(D_METHOD("poll_gameplay_events", "opts"),
                         &DCWorldExt::poll_gameplay_events);
    ClassDB::bind_method(D_METHOD("ack_gameplay_events", "consumer_id", "up_to_event_id"),
                         &DCWorldExt::ack_gameplay_events);
    ClassDB::bind_method(D_METHOD("replay_gameplay_events", "opts"),
                         &DCWorldExt::replay_gameplay_events);
    ClassDB::bind_method(D_METHOD("snapshot_gameplay_event_journal", "opts"),
                         &DCWorldExt::snapshot_gameplay_event_journal);
    ClassDB::bind_method(D_METHOD("restore_gameplay_event_journal", "snapshot"),
                         &DCWorldExt::restore_gameplay_event_journal);
    ClassDB::bind_method(D_METHOD("clear_gameplay_events", "opts"),
                         &DCWorldExt::clear_gameplay_events);
    ClassDB::bind_method(D_METHOD("get_gameplay_event_bus_report"),
                         &DCWorldExt::get_gameplay_event_bus_report);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_base_pass", "seed", "cfg", "profile"),
                         &DCWorldExt::run_native_world_generate_base_pass);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_post_base_pass", "seed", "cfg", "profile", "input"),
                         &DCWorldExt::run_native_world_generate_post_base_pass);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_full_pass", "seed", "cfg", "profile"),
                         &DCWorldExt::run_native_world_generate_full_pass);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_pass", "seed", "cfg", "profile"),
                         &DCWorldExt::run_native_world_generate_pass);
    ClassDB::bind_method(D_METHOD("get_native_fronts_snapshot"),
                         &DCWorldExt::get_native_fronts_snapshot);
    ClassDB::bind_method(D_METHOD("get_native_fronts_snapshot_packed"),
                         &DCWorldExt::get_native_fronts_snapshot_packed);
    ClassDB::bind_method(D_METHOD("get_native_dirty_report"),
                         &DCWorldExt::get_native_dirty_report);
    ClassDB::bind_method(D_METHOD("start_native_generation", "seed", "cfg", "profile"),
                         &DCWorldExt::start_native_generation);
    ClassDB::bind_method(D_METHOD("run_native_generation_slice", "budget"),
                         &DCWorldExt::run_native_generation_slice);
    ClassDB::bind_method(D_METHOD("finish_native_generation"),
                         &DCWorldExt::finish_native_generation);

    // CoW flush / refresh (performance-charter §11.2)
    ClassDB::bind_method(D_METHOD("flush_slots_to_map"),    &DCWorldExt::flush_slots_to_map);
    ClassDB::bind_method(D_METHOD("refresh_slots_from_map"), &DCWorldExt::refresh_slots_from_map);
    ClassDB::bind_method(D_METHOD("refresh_slots_from_map_keys", "slot_names"),
                         &DCWorldExt::refresh_slots_from_map_keys);
    // dirty-mark-batch-2026-06
    ClassDB::bind_method(D_METHOD("flush_pending_mark_dirty_all"),
                         &DCWorldExt::flush_pending_mark_dirty_all);

    ClassDB::bind_method(D_METHOD("create_archetype", "name", "comp_ids"), &DCWorldExt::create_archetype);
    ClassDB::bind_method(D_METHOD("assign_archetype", "idx", "arch_id"),   &DCWorldExt::assign_archetype);
    ClassDB::bind_method(D_METHOD("archetype_count"),                      &DCWorldExt::archetype_count);
    ClassDB::bind_method(D_METHOD("entity_archetype_array"),               &DCWorldExt::entity_archetype_array);

    ClassDB::bind_method(D_METHOD("run_climate_pass_a", "cp_struct", "phase", "season_phase"),
                         &DCWorldExt::run_climate_pass_a);

    // [Phase C.3c] climate_pass_a WorkerThreadPool 并行变体（与 _thread 命名约定一致）
    ClassDB::bind_method(D_METHOD("run_climate_pass_a_thread", "cp_struct", "phase", "season_phase", "n_tasks"),
                         &DCWorldExt::run_climate_pass_a_thread);

    // ─── Phase F / dots-full-migration §F.1-F.6 hot pass C++ stubs bind ──
    // 6 个 hot pass 的 ClassDB 注册。当前实现都返回 -1.0 → GDScript caller fallback。
    // 后续 PR 填实际算法时本段无需改动（签名稳定）。
    ClassDB::bind_method(
        D_METHOD("run_weather_field_solve_pass", "knobs"),
        &DCWorldExt::run_weather_field_solve_pass);
    ClassDB::bind_method(
        D_METHOD("run_synoptic_advance_pass", "knobs"),
        &DCWorldExt::run_synoptic_advance_pass);
    ClassDB::bind_method(
        D_METHOD("run_weather_field_commit_pass", "knobs"),
        &DCWorldExt::run_weather_field_commit_pass);
    ClassDB::bind_method(
        D_METHOD("run_ocean_water_pass", "knobs"),
        &DCWorldExt::run_ocean_water_pass);
    ClassDB::bind_method(
        D_METHOD("run_ocean_land_pass", "knobs"),
        &DCWorldExt::run_ocean_land_pass);
    ClassDB::bind_method(
        D_METHOD("run_wind_air_mass_pass", "knobs"),
        &DCWorldExt::run_wind_air_mass_pass);
    ClassDB::bind_method(
        D_METHOD("run_wind_surface_pass", "knobs"),
        &DCWorldExt::run_wind_surface_pass);
    // ─── sim-2ms-perf-push（plan/ocean-water-land-simd）────────────────
    //   water/land 各两档：water/land idx 预筛 + 直线 kernel（_simd）/
    //   + WorkerThreadPool 分块（_thread）。flag gate：
    //   use_gdext_ocean_water_simd / use_gdext_ocean_land_simd /
    //   use_gdext_thread_fallback。
    ClassDB::bind_method(
        D_METHOD("run_ocean_water_pass_simd", "knobs"),
        &DCWorldExt::run_ocean_water_pass_simd);
    ClassDB::bind_method(
        D_METHOD("run_ocean_water_pass_thread", "knobs", "n_tasks"),
        &DCWorldExt::run_ocean_water_pass_thread);
    ClassDB::bind_method(
        D_METHOD("run_ocean_land_pass_simd", "knobs"),
        &DCWorldExt::run_ocean_land_pass_simd);
    ClassDB::bind_method(
        D_METHOD("run_ocean_land_pass_thread", "knobs", "n_tasks"),
        &DCWorldExt::run_ocean_land_pass_thread);
    ClassDB::bind_method(
        D_METHOD("run_climate_pass_b", "knobs"),
        &DCWorldExt::run_climate_pass_b);
    // ─── sim-2ms-perf-push（plan/climate-pass-b-simd）─────────────────
    //   land-mask 预筛 + auto-vectorize 路径（ulp ≤ 4 容差，charter §risk=B 已批）
    //   + WorkerThreadPool 兜底变体。flag gate 见 ClimateProfile / FLAGS：
    //   use_gdext_pass_b_simd / use_gdext_thread_fallback。
    ClassDB::bind_method(
        D_METHOD("run_climate_pass_b_simd", "knobs"),
        &DCWorldExt::run_climate_pass_b_simd);
    ClassDB::bind_method(
        D_METHOD("run_climate_pass_b_thread", "knobs", "n_tasks"),
        &DCWorldExt::run_climate_pass_b_thread);
    ClassDB::bind_method(
        D_METHOD("run_sea_ice_daily_pass", "knobs", "season_phase"),
        &DCWorldExt::run_sea_ice_daily_pass);
    // [Phase C.3d] sea_ice WorkerThreadPool 并行变体（Phase A 裸并行 + Phase B emit reduce）
    ClassDB::bind_method(
        D_METHOD("run_sea_ice_daily_pass_thread", "knobs", "season_phase", "n_tasks"),
        &DCWorldExt::run_sea_ice_daily_pass_thread);
    ClassDB::bind_method(
        D_METHOD("run_transpiration_pass", "knobs"),
        &DCWorldExt::run_transpiration_pass);
    ClassDB::bind_method(
        D_METHOD("run_runtime_hydrology_pass", "knobs"),
        &DCWorldExt::run_runtime_hydrology_pass);
    // ─── Natural resources（economy.resources）─────────────────────────
    ClassDB::bind_method(
        D_METHOD("run_natural_resource_pass", "knobs"),
        &DCWorldExt::run_natural_resource_pass);
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 2）─────────────────
    ClassDB::bind_method(
        D_METHOD("run_albedo_pass", "knobs"),
        &DCWorldExt::run_albedo_pass);
    // [Phase C.3c] albedo WorkerThreadPool 并行变体
    ClassDB::bind_method(
        D_METHOD("run_albedo_pass_thread", "knobs", "n_tasks"),
        &DCWorldExt::run_albedo_pass_thread);
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 3）─────────────────
    ClassDB::bind_method(
        D_METHOD("run_vegetation_dynamics_pass", "knobs"),
        &DCWorldExt::run_vegetation_dynamics_pass);
    // [Phase C.3d] vegetation_dynamics WorkerThreadPool 并行变体（emit reduce）
    ClassDB::bind_method(
        D_METHOD("run_vegetation_dynamics_pass_thread", "knobs", "n_tasks"),
        &DCWorldExt::run_vegetation_dynamics_pass_thread);
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 4）─────────────────
    ClassDB::bind_method(
        D_METHOD("run_climate_feedback_pass", "knobs"),
        &DCWorldExt::run_climate_feedback_pass);
    // [Phase C.3c] climate_feedback WorkerThreadPool 并行变体
    ClassDB::bind_method(
        D_METHOD("run_climate_feedback_pass_thread", "knobs", "n_tasks"),
        &DCWorldExt::run_climate_feedback_pass_thread);
    // ─── 方案 B：stage_b 三段合并（plan/stage-b-combine）──────────────────
    //   合并 albedo + veg_dyn + feedback 单 cpp call，消除 GDScript 端
    //   pack/unpack 围栏；目标 stage_b 6–15ms → ≤ 1.5ms
    ClassDB::bind_method(
        D_METHOD("run_stage_b_pass", "knobs"),
        &DCWorldExt::run_stage_b_pass);
    ClassDB::bind_method(
        D_METHOD("run_weather_front_advect_pass", "knobs"),
        &DCWorldExt::run_weather_front_advect_pass);

    // ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）──────────────
    // dist + summary 两个 pass + summary 状态管理三件套。骨架先返回 -1，
    // 让 GDScript caller 永远 fallback。任务 4 / 7 实装算法主体。
    ClassDB::bind_method(
        D_METHOD("run_weather_distribute_pass", "knobs"),
        &DCWorldExt::run_weather_distribute_pass);
    ClassDB::bind_method(
        D_METHOD("run_weather_summary_fronts_pass", "knobs"),
        &DCWorldExt::run_weather_summary_fronts_pass);
    ClassDB::bind_method(
        D_METHOD("reset_weather_summary_state"),
        &DCWorldExt::reset_weather_summary_state);
    ClassDB::bind_method(
        D_METHOD("snapshot_weather_summary_state"),
        &DCWorldExt::snapshot_weather_summary_state);
    ClassDB::bind_method(
        D_METHOD("restore_weather_summary_state"),
        &DCWorldExt::restore_weather_summary_state);

    // ─── plan/weather-refresh-cpp-all: 顶层一体化 weather refresh ────────
    ClassDB::bind_method(
        D_METHOD("run_weather_refresh_daily_pass", "knobs"),
        &DCWorldExt::run_weather_refresh_daily_pass);
    ClassDB::bind_method(
        D_METHOD("get_cyclone_perturbations_dict"),
        &DCWorldExt::get_cyclone_perturbations_dict);

    // Block B: ocean_currents wind solver (dots-wind-validation.md)
    ClassDB::bind_method(
        D_METHOD("run_wind_field_pass", "knobs"),
        &DCWorldExt::run_wind_field_pass);
    ClassDB::bind_method(
        D_METHOD("run_physical_circulation_pass", "knobs"),
        &DCWorldExt::run_physical_circulation_pass);
    // plan/dots-slp-psi-cpp: SLP + PSI fully native physical-circulation finals
    ClassDB::bind_method(
        D_METHOD("run_slp_field_pass", "knobs"),
        &DCWorldExt::run_slp_field_pass);
    ClassDB::bind_method(
        D_METHOD("run_psi_solver_pass", "knobs"),
        &DCWorldExt::run_psi_solver_pass);
    // dots-total-cpp step3: 物理环流编排（生成期一次性路径）
    ClassDB::bind_method(
        D_METHOD("run_physical_solve_pass", "knobs"),
        &DCWorldExt::run_physical_solve_pass);
    ClassDB::bind_method(
        D_METHOD("run_temp_baseline_year_bake", "knobs"),
        &DCWorldExt::run_temp_baseline_year_bake);
    ClassDB::bind_method(
        D_METHOD("run_season_refresh_stage", "knobs"),
        &DCWorldExt::run_season_refresh_stage);
    ClassDB::bind_method(
        D_METHOD("run_season_refresh_micro_pass", "knobs"),
        &DCWorldExt::run_season_refresh_micro_pass);
    // ─── Phase B+（2026-05-21）：season refresh round 一次跨界整 round 切片调度 ─
    ClassDB::bind_method(
        D_METHOD("start_season_round", "round_knobs"),
        &DCWorldExt::start_season_round);
    ClassDB::bind_method(
        D_METHOD("run_season_round_slice", "handle", "max_usec"),
        &DCWorldExt::run_season_round_slice);
    ClassDB::bind_method(
        D_METHOD("finish_season_round", "handle"),
        &DCWorldExt::finish_season_round);
    ClassDB::bind_method(
        D_METHOD("abort_season_round"),
        &DCWorldExt::abort_season_round);
    ClassDB::bind_method(
        D_METHOD("run_sea_ice_atlas_prepare", "knobs"),
        &DCWorldExt::run_sea_ice_atlas_prepare);
    ClassDB::bind_method(
        D_METHOD("patch_enum_atlas_axes", "knobs"),
        &DCWorldExt::patch_enum_atlas_axes);
    // Bake-time static texture encoders: C++ byte payload, GD texture upload.
    ClassDB::bind_method(
        D_METHOD("encode_bake_height_tex_data", "knobs"),
        &DCWorldExt::encode_bake_height_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_terrain_normal_tex_data", "knobs"),
        &DCWorldExt::encode_bake_terrain_normal_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_r8_tex_data", "knobs"),
        &DCWorldExt::encode_bake_r8_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_flow_tex_data", "knobs"),
        &DCWorldExt::encode_bake_flow_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_enum_atlas_payload", "knobs"),
        &DCWorldExt::encode_bake_enum_atlas_payload);
    ClassDB::bind_method(
        D_METHOD("encode_bake_upwelling_tex_data", "knobs"),
        &DCWorldExt::encode_bake_upwelling_tex_data);
    ClassDB::bind_method(
        D_METHOD("run_bake_terrain_index_pass", "knobs"),
        &DCWorldExt::run_bake_terrain_index_pass);
    // 生成期 per-pixel 几何场 buffer-encoder（dots-total-cpp 续，2026-06-25）
    ClassDB::bind_method(
        D_METHOD("run_bake_volcano_field_pass", "knobs"),
        &DCWorldExt::run_bake_volcano_field_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_latitude_field_pass", "knobs"),
        &DCWorldExt::run_bake_latitude_field_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_river_sdf_pass", "knobs"),
        &DCWorldExt::run_bake_river_sdf_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_coast_sdf_pass", "knobs"),
        &DCWorldExt::run_bake_coast_sdf_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_erosion_pass", "knobs"),
        &DCWorldExt::run_bake_erosion_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_geometry_fields_pass", "knobs"),
        &DCWorldExt::run_bake_geometry_fields_pass);
    // Dirty-Push Atlas Encode (plan/dirty-push-atlas-encode 阶段 F)：
    // 4 张运行期 atlas baker 的 byte-fill C++/SIMD pass。CSR 协议详见 world_ext.h。
    ClassDB::bind_method(
        D_METHOD("encode_dynamic_cell_atlas", "knobs"),
        &DCWorldExt::encode_dynamic_cell_atlas);
    ClassDB::bind_method(
        D_METHOD("encode_ecology_visual_atlas", "knobs"),
        &DCWorldExt::encode_ecology_visual_atlas);
    ClassDB::bind_method(
        D_METHOD("encode_dyn_smooth_atlas", "knobs"),
        &DCWorldExt::encode_dyn_smooth_atlas);
    ClassDB::bind_method(
        D_METHOD("encode_ice_state_atlas", "knobs"),
        &DCWorldExt::encode_ice_state_atlas);
    // plan/debug-overlay-perf v2（2026-06-12）：debug data overlay pixel fan-out 下沉 C++。
    ClassDB::bind_method(
        D_METHOD("encode_overlay_atlas", "knobs"),
        &DCWorldExt::encode_overlay_atlas);
    // ────────────────────────────────────────────────────────────────────
    // DOTS-Total-CPP（atlas-pipeline-cpp）：4 atlas 全量 DOTS 化主入口
    //   - run_atlas_pipeline_step：每 tick 单一入口，4-phase 状态机驱动
    //     dirty 消费 + value-diff（prev_sigs snapshot）+ 1 跳膨胀
    //     + 4 atlas encode + ms 切片诊断；返回 atlas_buffers Dict 供 GD
    //     ImageTexture.update 使用。
    //   - invalidate_atlas_csr_cache：地图重生成时清 CSR/snapshot 缓存。
    //   - migrate_eco_persistent_from_gd：一次性 burn-in，把 map_baker.gd
    //     ecology 持久状态（foliage/stress/transition_age/active_decay 等）
    //     迁到 C++ 端 AtlasPipelineState。
    // ────────────────────────────────────────────────────────────────────
    ClassDB::bind_method(
        D_METHOD("run_atlas_pipeline_step", "opts"),
        &DCWorldExt::run_atlas_pipeline_step);
    ClassDB::bind_method(
        D_METHOD("invalidate_atlas_csr_cache"),
        &DCWorldExt::invalidate_atlas_csr_cache);
    ClassDB::bind_method(
        D_METHOD("migrate_eco_persistent_from_gd", "state"),
        &DCWorldExt::migrate_eco_persistent_from_gd);
    // ─── Cell-index 间接寻址（province-ID indirection）──────────────────
    //   encode_cell_luts：per-cell enum/dyn/eco LUT 编码（n_cells texel）
    ClassDB::bind_method(
        D_METHOD("encode_cell_luts", "opts"),
        &DCWorldExt::encode_cell_luts);
    // vegetation-visual-pcg 阶段 A：植被/点缀散布 per-instance 热循环 + MultiMesh buffer 组装
    ClassDB::bind_method(
        D_METHOD("encode_detail_scatter", "knobs"),
        &DCWorldExt::encode_detail_scatter);
    ClassDB::bind_method(
        D_METHOD("encode_detail_scatter_delta", "knobs"),
        &DCWorldExt::encode_detail_scatter_delta);
    // DOTS-Total-CPP（plan/dots-total-cpp 任务 4）：ocean rasterize 一次性 hex→pixel
    ClassDB::bind_method(
        D_METHOD("run_ocean_field_rasterize", "knobs"),
        &DCWorldExt::run_ocean_field_rasterize);
    // DOTS-Total-CPP（A 方案 / wind raster 孪生）：wind rasterize 一次性 hex→pixel
    ClassDB::bind_method(
        D_METHOD("run_wind_field_rasterize", "knobs"),
        &DCWorldExt::run_wind_field_rasterize);
    // DOTS-Total-CPP（A 方案 / phys nan_guard 孪生）：6 字段 SoA NaN/Inf 扫描
    ClassDB::bind_method(
        D_METHOD("phys_field_nan_guard"),
        &DCWorldExt::phys_field_nan_guard);


    // Mode-B reference implementation entry point (see performance-charter.md §12)
    ClassDB::bind_method(D_METHOD("run_temp_drift_pass", "drift_amount"), &DCWorldExt::run_temp_drift_pass);

    // Pass #2 reference implementation entry point (see performance-charter.md §12.6)
    ClassDB::bind_method(
        D_METHOD("run_thermal_gradient_pass", "grid_w", "grid_h", "elevation_gain", "normalize_k"),
        &DCWorldExt::run_thermal_gradient_pass);

    // Pass #3 reference implementation entry point (see performance-charter.md §12.6.6)
    ClassDB::bind_method(
        D_METHOD("run_demo_complex_pass",
                 "grid_w", "grid_h",
                 "iterations", "kernel_radius",
                 "coriolis_strength", "terrain_drag",
                 "elevation_gain", "normalize_k"),
        &DCWorldExt::run_demo_complex_pass);

    // DOTS-A1 EXPERIMENT: archetype-filtered demo_complex (see world_ext.h)
    ClassDB::bind_method(
        D_METHOD("run_demo_complex_pass_archetyped",
                 "grid_w", "grid_h",
                 "iterations", "kernel_radius",
                 "coriolis_strength", "terrain_drag",
                 "elevation_gain", "normalize_k",
                 "target_archetype"),
        &DCWorldExt::run_demo_complex_pass_archetyped);

    // Phase 3a Step 0: alias spike (TEMPORARY)
    ClassDB::bind_method(D_METHOD("_spike_alias_v1_naive",          "obj", "prop", "idx", "sentinel"), &DCWorldExt::_spike_alias_v1_naive);
    ClassDB::bind_method(D_METHOD("_spike_alias_v2_release",        "obj", "prop", "idx", "sentinel"), &DCWorldExt::_spike_alias_v2_release);
    ClassDB::bind_method(D_METHOD("_spike_alias_v3_write_then_set", "obj", "prop", "idx", "sentinel"), &DCWorldExt::_spike_alias_v3_write_then_set);

    // Phase 3a Step 1: alias verification helper (TEMPORARY)
    ClassDB::bind_method(D_METHOD("_debug_poke_f32", "comp_id", "idx", "sentinel"), &DCWorldExt::_debug_poke_f32);
    ClassDB::bind_method(D_METHOD("_debug_poke_f32_with_flush", "comp_id", "idx", "sentinel"), &DCWorldExt::_debug_poke_f32_with_flush);

    // Phase-3 micro-bench API
    ClassDB::bind_method(D_METHOD("bench_pass_a_full_scalar", "comp_id", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_full_scalar);
    ClassDB::bind_method(D_METHOD("bench_pass_a_full_simd", "comp_id", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_full_simd);
    ClassDB::bind_method(D_METHOD("bench_pass_a_full_thread", "comp_id", "lat", "prev", "neighbors", "k1", "k2", "base", "season", "n_tasks"),
                         &DCWorldExt::bench_pass_a_full_thread);
    ClassDB::bind_method(D_METHOD("bench_pass_a_indexed_scalar", "comp_id", "dirty", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_indexed_scalar);
    ClassDB::bind_method(D_METHOD("bench_pass_a_indexed_simd", "comp_id", "dirty", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_indexed_simd);
    ClassDB::bind_method(D_METHOD("bench_pass_a_indexed_thread", "comp_id", "dirty", "lat", "prev", "neighbors", "k1", "k2", "base", "season", "n_tasks"),
                         &DCWorldExt::bench_pass_a_indexed_thread);

    // EXPERIMENTAL: D-async (long-lived worker thread + double buffering)
    ClassDB::bind_method(D_METHOD("async_climate_register_task", "task_id", "n_workers"),
                         &DCWorldExt::async_climate_register_task);
    ClassDB::bind_method(D_METHOD("async_climate_set_inputs", "task_id", "temp", "elev"),
                         &DCWorldExt::async_climate_set_inputs);
    ClassDB::bind_method(
        D_METHOD("async_climate_request",
                 "task_id", "grid_w", "grid_h",
                 "iterations", "kernel_radius",
                 "coriolis_strength", "terrain_drag",
                 "elevation_gain", "normalize_k"),
        &DCWorldExt::async_climate_request);
    ClassDB::bind_method(D_METHOD("async_climate_poll", "task_id"),
                         &DCWorldExt::async_climate_poll);
    ClassDB::bind_method(D_METHOD("async_climate_stats", "task_id"),
                         &DCWorldExt::async_climate_stats);
    ClassDB::bind_method(D_METHOD("async_climate_shutdown_task", "task_id"),
                         &DCWorldExt::async_climate_shutdown_task);
    ClassDB::bind_method(D_METHOD("async_climate_shutdown_all"),
                         &DCWorldExt::async_climate_shutdown_all);

    // Async Climate Round（plan §async-stage-1，2026-06-14）
    ClassDB::bind_method(D_METHOD("async_climate_round_register"),
                         &DCWorldExt::async_climate_round_register);
    ClassDB::bind_method(D_METHOD("async_climate_round_set_static_knobs", "knobs"),
                         &DCWorldExt::async_climate_round_set_static_knobs);
    ClassDB::bind_method(D_METHOD("async_climate_round_kick", "input"),
                         &DCWorldExt::async_climate_round_kick);
    ClassDB::bind_method(D_METHOD("async_climate_round_poll"),
                         &DCWorldExt::async_climate_round_poll);
    ClassDB::bind_method(D_METHOD("async_climate_round_stats"),
                         &DCWorldExt::async_climate_round_stats);
    ClassDB::bind_method(D_METHOD("native_climate_round_begin", "static_knobs"),
                         &DCWorldExt::native_climate_round_begin);
    ClassDB::bind_method(D_METHOD("native_climate_round_begin_round", "ctx"),
                         &DCWorldExt::native_climate_round_begin_round);
    ClassDB::bind_method(D_METHOD("native_climate_round_kick", "input"),
                         &DCWorldExt::native_climate_round_kick);
    ClassDB::bind_method(D_METHOD("native_climate_round_poll"),
                         &DCWorldExt::native_climate_round_poll);
    ClassDB::bind_method(D_METHOD("native_climate_round_finish_round", "ctx"),
                         &DCWorldExt::native_climate_round_finish_round);
    ClassDB::bind_method(D_METHOD("get_native_climate_round_state_report"),
                         &DCWorldExt::get_native_climate_round_state_report);
    ClassDB::bind_method(D_METHOD("reset_native_climate_round_state", "reason"),
                         &DCWorldExt::reset_native_climate_round_state, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("async_climate_round_shutdown"),
                         &DCWorldExt::async_climate_round_shutdown);
}

} // namespace pk
