#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_core_methods() {
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
    // Mode-B snapshot API (recommended; see docs/architecture/current-state.md)
    ClassDB::bind_method(D_METHOD("snapshot_f32", "comp_id"), &DCWorldExt::snapshot_f32);
    // B3b：snapshot_i32 / snapshot_u8 给 streak（I32）+ 后续 save/overlay 补齐
    ClassDB::bind_method(D_METHOD("snapshot_i32", "comp_id"), &DCWorldExt::snapshot_i32);
    ClassDB::bind_method(D_METHOD("snapshot_u8",  "comp_id"), &DCWorldExt::snapshot_u8);
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
    ClassDB::bind_method(D_METHOD("bind_map_data", "map_data"), &DCWorldExt::bind_map_data);
    // sea-ice-snow-visual-fix-2026-06：bind 后注入 DCWorld 句柄，让 C++ 自动 mark dirty。
    ClassDB::bind_method(D_METHOD("bind_dirty_world", "dirty_world"), &DCWorldExt::bind_dirty_world);
    ClassDB::bind_method(D_METHOD("is_bound"),                  &DCWorldExt::is_bound);
    ClassDB::bind_method(D_METHOD("configure_native_world", "knobs"),
                         &DCWorldExt::configure_native_world);
    ClassDB::bind_method(D_METHOD("is_native_daily_visual_commit_pending"),
                         &DCWorldExt::is_native_daily_visual_commit_pending);
    ClassDB::bind_method(D_METHOD("complete_native_daily_visual_commit"),
                         &DCWorldExt::complete_native_daily_visual_commit);
    ClassDB::bind_method(D_METHOD("complete_native_daily_moisture_commit"),
                         &DCWorldExt::complete_native_daily_moisture_commit);
    ClassDB::bind_method(D_METHOD("configure_country", "catalog", "profile", "cell_count", "seed"),
                         &DCWorldExt::configure_country);
    // CoW flush / refresh (performance-charter §11.2)
    ClassDB::bind_method(D_METHOD("flush_slots_to_map"),    &DCWorldExt::flush_slots_to_map);
    ClassDB::bind_method(D_METHOD("flush_slots_to_map_keys", "slot_names"),
                         &DCWorldExt::flush_slots_to_map_keys);
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
    ClassDB::bind_method(
        D_METHOD("supports_wind_air_slot_temp"),
        &DCWorldExt::supports_wind_air_slot_temp);
}

} // namespace pk
