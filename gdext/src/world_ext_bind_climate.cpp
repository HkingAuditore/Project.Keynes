#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_climate_methods() {
    ClassDB::bind_method(D_METHOD("run_bio_province_pass", "knobs"),
                         &DCWorldExt::run_bio_province_pass);
    ClassDB::bind_method(D_METHOD("run_bio_seed_pass", "knobs"),
                         &DCWorldExt::run_bio_seed_pass);
    ClassDB::bind_method(D_METHOD("run_bio_bootstrap_pass", "knobs"),
                         &DCWorldExt::run_bio_bootstrap_pass);
    ClassDB::bind_method(D_METHOD("configure_bio_occupancy", "config"),
                         &DCWorldExt::configure_bio_occupancy);
    ClassDB::bind_method(D_METHOD("run_bio_occupancy_pass", "knobs"),
                         &DCWorldExt::run_bio_occupancy_pass);
    ClassDB::bind_method(D_METHOD("run_bio_occupancy_slice", "knobs"),
                         &DCWorldExt::run_bio_occupancy_slice);
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
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 2）─────────────────
    ClassDB::bind_method(
        D_METHOD("run_albedo_pass", "knobs"),
        &DCWorldExt::run_albedo_pass);
    // [Phase C.3c] albedo WorkerThreadPool 并行变体
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 3）─────────────────
    ClassDB::bind_method(
        D_METHOD("run_vegetation_dynamics_pass", "knobs"),
        &DCWorldExt::run_vegetation_dynamics_pass);
    // [Phase C.3d] vegetation_dynamics WorkerThreadPool 并行变体（emit reduce）
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 4）─────────────────
    ClassDB::bind_method(
        D_METHOD("run_climate_feedback_pass", "knobs"),
        &DCWorldExt::run_climate_feedback_pass);
    // [Phase C.3c] climate_feedback WorkerThreadPool 并行变体
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
    ClassDB::bind_method(D_METHOD("get_active_cyclone_snapshot"),
                         &DCWorldExt::get_active_cyclone_snapshot);
    ClassDB::bind_method(D_METHOD("get_climate_modes_report"),
                         &DCWorldExt::get_climate_modes_report);
    ClassDB::bind_method(D_METHOD("capture_climate_modes_state"),
                         &DCWorldExt::capture_climate_modes_state);
    ClassDB::bind_method(D_METHOD("restore_climate_modes_state", "state"),
                         &DCWorldExt::restore_climate_modes_state);
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
    ClassDB::bind_method(D_METHOD("get_native_climate_round_hot_state"),
                         &DCWorldExt::get_native_climate_round_hot_state);
    ClassDB::bind_method(D_METHOD("reset_native_climate_round_state", "reason"),
                         &DCWorldExt::reset_native_climate_round_state, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("async_climate_round_shutdown"),
                         &DCWorldExt::async_climate_round_shutdown);
}

} // namespace pk
