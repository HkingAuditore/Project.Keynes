#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_demo_methods() {
    ClassDB::bind_method(D_METHOD("encode_tile_csv_rows", "knobs"), &DCWorldExt::encode_tile_csv_rows);
    // Mode-B reference implementation entry point (see docs/architecture/current-state.md)
    ClassDB::bind_method(D_METHOD("run_temp_drift_pass", "drift_amount"), &DCWorldExt::run_temp_drift_pass);
    // Pass #2 reference implementation entry point (see docs/architecture/current-state.md)
    ClassDB::bind_method(
        D_METHOD("run_thermal_gradient_pass", "grid_w", "grid_h", "elevation_gain", "normalize_k"),
        &DCWorldExt::run_thermal_gradient_pass);
    // Pass #3 reference implementation entry point (see docs/architecture/current-state.md)
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
}

} // namespace pk
