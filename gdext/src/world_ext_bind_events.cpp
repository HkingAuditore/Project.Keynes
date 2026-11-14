#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_events_methods() {
    ClassDB::bind_method(D_METHOD("gameplay_effect_should_run", "day_index"),
                         &DCWorldExt::gameplay_effect_should_run);
    ClassDB::bind_method(D_METHOD("run_gameplay_effects", "day_index"),
                         &DCWorldExt::run_gameplay_effects);
    ClassDB::bind_method(D_METHOD("get_gameplay_event_schema"),
                         &DCWorldExt::get_gameplay_event_schema);
    ClassDB::bind_method(D_METHOD("publish_gameplay_events", "batch"),
                         &DCWorldExt::publish_gameplay_events);
    ClassDB::bind_method(D_METHOD("poll_gameplay_events", "opts"),
                         &DCWorldExt::poll_gameplay_events);
    ClassDB::bind_method(D_METHOD("ack_gameplay_events", "consumer_id", "up_to_event_id"),
                         &DCWorldExt::ack_gameplay_events);
    ClassDB::bind_method(D_METHOD("poll_runtime_events_snapshot", "after_generation"),
                         &DCWorldExt::poll_runtime_events_snapshot,
                         DEFVAL(0));
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
    ClassDB::bind_method(
        D_METHOD("consume_canal_visual_dirty_cells"),
        &DCWorldExt::consume_canal_visual_dirty_cells);
}

} // namespace pk
