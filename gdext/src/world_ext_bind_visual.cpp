#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_visual_methods() {
    ClassDB::bind_method(D_METHOD("bake_trade_visual_paths", "snapshot", "map_width", "hex_size"),
        &DCWorldExt::bake_trade_visual_paths);
    ClassDB::bind_method(D_METHOD("bake_building_visual_chunk", "knobs"),
                          &DCWorldExt::bake_building_visual_chunk);
    ClassDB::bind_method(D_METHOD("configure_vision_research", "config"),
                         &DCWorldExt::configure_vision_research);
    ClassDB::bind_method(D_METHOD("run_vision_research_pass", "knobs"),
                         &DCWorldExt::run_vision_research_pass);
    ClassDB::bind_method(D_METHOD("filter_bio_research_observations", "cells", "signals"),
                         &DCWorldExt::filter_bio_research_observations);
    ClassDB::bind_method(
        D_METHOD("run_sea_ice_atlas_prepare", "knobs"),
        &DCWorldExt::run_sea_ice_atlas_prepare);
    ClassDB::bind_method(
        D_METHOD("patch_enum_atlas_axes", "knobs"),
        &DCWorldExt::patch_enum_atlas_axes);
    ClassDB::bind_method(
        D_METHOD("run_bake_visual_tile_layer_pass", "knobs"),
        &DCWorldExt::run_bake_visual_tile_layer_pass);
    ClassDB::bind_method(
        D_METHOD("run_resample_visual_horizon_layer_pass", "knobs"),
        &DCWorldExt::run_resample_visual_horizon_layer_pass);
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
    ClassDB::bind_method(
        D_METHOD("encode_detail_scatter_family_cells", "knobs"),
        &DCWorldExt::encode_detail_scatter_family_cells);
}

} // namespace pk
