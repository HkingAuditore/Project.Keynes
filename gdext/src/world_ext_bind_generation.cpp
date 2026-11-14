#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_generation_methods() {
    ClassDB::bind_method(D_METHOD("run_native_world_generate_base_pass", "seed", "cfg", "profile"),
                         &DCWorldExt::run_native_world_generate_base_pass);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_post_base_pass", "seed", "cfg", "profile", "input"),
                         &DCWorldExt::run_native_world_generate_post_base_pass);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_full_pass", "seed", "cfg", "profile"),
                         &DCWorldExt::run_native_world_generate_full_pass);
    ClassDB::bind_method(D_METHOD("restuff_generation_river_cache", "input"),
                         &DCWorldExt::restuff_generation_river_cache);
    ClassDB::bind_method(D_METHOD("run_research_signal_generation_pass", "knobs"),
                         &DCWorldExt::run_research_signal_generation_pass);
    ClassDB::bind_method(D_METHOD("run_resource_deposit_pass", "knobs"),
                         &DCWorldExt::run_resource_deposit_pass);
    ClassDB::bind_method(D_METHOD("run_native_world_generate_pass", "seed", "cfg", "profile"),
                         &DCWorldExt::run_native_world_generate_pass);
    ClassDB::bind_method(D_METHOD("start_native_generation", "seed", "cfg", "profile"),
                         &DCWorldExt::start_native_generation);
    ClassDB::bind_method(D_METHOD("run_native_generation_slice", "budget"),
                         &DCWorldExt::run_native_generation_slice);
    ClassDB::bind_method(D_METHOD("finish_native_generation"),
                         &DCWorldExt::finish_native_generation);
    // ─── Natural resources（economy.resources）─────────────────────────
    ClassDB::bind_method(
        D_METHOD("run_natural_resource_pass", "knobs"),
        &DCWorldExt::run_natural_resource_pass);
    ClassDB::bind_method(
        D_METHOD("get_natural_resource_regen_factors", "resource_ids", "n_cells"),
        &DCWorldExt::get_natural_resource_regen_factors);
    ClassDB::bind_method(
        D_METHOD("run_temp_baseline_year_bake", "knobs"),
        &DCWorldExt::run_temp_baseline_year_bake);
    ClassDB::bind_method(
        D_METHOD("run_bake_terrain_index_pass", "knobs"),
        &DCWorldExt::run_bake_terrain_index_pass);
    // 生成期 per-pixel 几何场 buffer-encoder（dots-total-cpp 续，2026-06-25）
    ClassDB::bind_method(
        D_METHOD("run_bake_latitude_field_pass", "knobs"),
        &DCWorldExt::run_bake_latitude_field_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_river_sdf_pass", "knobs"),
        &DCWorldExt::run_bake_river_sdf_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_erosion_pass", "knobs"),
        &DCWorldExt::run_bake_erosion_pass);
    ClassDB::bind_method(
        D_METHOD("run_bake_geometry_fields_pass", "knobs"),
        &DCWorldExt::run_bake_geometry_fields_pass);
}

} // namespace pk
