#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_military_methods() {
    // ---- Military (contract §2) -------------------------------------------
    ClassDB::bind_method(D_METHOD("configure_military", "catalog", "seed"),
                         &DCWorldExt::configure_military);
    ClassDB::bind_method(D_METHOD("set_military_terrain", "terrain"),
                         &DCWorldExt::set_military_terrain);
    ClassDB::bind_method(D_METHOD("submit_military_commands", "batch"),
                         &DCWorldExt::submit_military_commands);
    ClassDB::bind_method(D_METHOD("military_should_run", "day"),
                         &DCWorldExt::military_should_run);
    ClassDB::bind_method(D_METHOD("run_military_daily", "ctx"),
                         &DCWorldExt::run_military_daily);
    ClassDB::bind_method(D_METHOD("run_military_catch_up", "ctx"),
                         &DCWorldExt::run_military_catch_up);
    ClassDB::bind_method(D_METHOD("get_military_report"),
                         &DCWorldExt::get_military_report);
    ClassDB::bind_method(D_METHOD("get_military_country_snapshot", "country"),
                         &DCWorldExt::get_military_country_snapshot);
    ClassDB::bind_method(D_METHOD("get_military_maintenance_snapshot", "country"),
                         &DCWorldExt::get_military_maintenance_snapshot);
    ClassDB::bind_method(D_METHOD("get_military_armies", "country"),
                         &DCWorldExt::get_military_armies);
    ClassDB::bind_method(D_METHOD("get_military_army", "army"),
                         &DCWorldExt::get_military_army);
    ClassDB::bind_method(D_METHOD("get_military_cell_snapshot", "cell", "observer"),
                         &DCWorldExt::get_military_cell_snapshot);
    ClassDB::bind_method(D_METHOD("get_military_render_snapshot", "after_revision"),
                         &DCWorldExt::get_military_render_snapshot);
    ClassDB::bind_method(D_METHOD("set_military_render_selection", "army"),
                         &DCWorldExt::set_military_render_selection);
    ClassDB::bind_method(D_METHOD("get_military_control_snapshot"),
                         &DCWorldExt::get_military_control_snapshot);
    ClassDB::bind_method(D_METHOD("poll_military_events", "after_id", "limit"),
                         &DCWorldExt::poll_military_events, DEFVAL(256));
    ClassDB::bind_method(D_METHOD("preview_military_path", "army", "cell"),
                         &DCWorldExt::preview_military_path);
    ClassDB::bind_method(D_METHOD("evaluate_military_peace", "war_id", "proposer", "terms"),
                         &DCWorldExt::evaluate_military_peace);
    ClassDB::bind_method(D_METHOD("get_military_catalog_view"),
                         &DCWorldExt::get_military_catalog_view);
    ClassDB::bind_method(D_METHOD("set_military_exploration_observer", "observer_slot"),
                         &DCWorldExt::set_military_exploration_observer);
    ClassDB::bind_method(D_METHOD("set_military_exploration_view", "observer_slot",
                                  "explored", "day", "revision"),
                         &DCWorldExt::set_military_exploration_view);
    ClassDB::bind_method(D_METHOD("get_military_vision_trail", "observer_slot"),
                         &DCWorldExt::get_military_vision_trail);
    ClassDB::bind_method(D_METHOD("clear_military_vision_trail", "observer_slot"),
                         &DCWorldExt::clear_military_vision_trail);
    ClassDB::bind_method(D_METHOD("has_military_exploration_work"),
                         &DCWorldExt::has_military_exploration_work);
    ClassDB::bind_method(D_METHOD("encode_military_state"),
                         &DCWorldExt::encode_military_state);
    ClassDB::bind_method(D_METHOD("restore_military_state", "bytes"),
                         &DCWorldExt::restore_military_state);
    ClassDB::bind_method(D_METHOD("runtime_military_self_test"),
                         &DCWorldExt::runtime_military_self_test);
    ClassDB::bind_method(D_METHOD("run_military_bench", "cfg"),
                         &DCWorldExt::run_military_bench);
    ClassDB::bind_method(D_METHOD("set_military_ai_player_handles", "handles"),
                         &DCWorldExt::set_military_ai_player_handles);
    ClassDB::bind_method(D_METHOD("set_military_ai_country", "slot", "ai"),
                         &DCWorldExt::set_military_ai_country);
    // ---- Military cell stats
    ClassDB::bind_method(D_METHOD("set_military_country_metrics", "rows"),
                         &DCWorldExt::set_military_country_metrics);
    ClassDB::bind_method(D_METHOD("set_military_cell_tags", "tags"),
                         &DCWorldExt::set_military_cell_tags);
    ClassDB::bind_method(D_METHOD("get_military_cell_tag_cells", "tag"),
                         &DCWorldExt::get_military_cell_tag_cells);
    ClassDB::bind_method(D_METHOD("get_military_country_metrics", "handle"),
                         &DCWorldExt::get_military_country_metrics);
    ClassDB::bind_method(D_METHOD("get_military_cell_stats_report"),
                         &DCWorldExt::get_military_cell_stats_report);
    ClassDB::bind_method(D_METHOD("clear_military_cell_stats"),
                         &DCWorldExt::clear_military_cell_stats);
    ClassDB::bind_method(D_METHOD("get_military_cell_stat_q16", "cell_key", "cell",
                                  "entity_handle", "base_value_q16"),
                         &DCWorldExt::get_military_cell_stat_q16);
    // ---- Economy military hooks ----
    ClassDB::bind_method(D_METHOD("set_military_ration_satisfaction",
                                  "cells", "q16"),
                         &DCWorldExt::set_military_ration_satisfaction);
}

} // namespace pk
