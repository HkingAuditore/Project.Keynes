#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_trigger_methods() {
    ClassDB::bind_method(D_METHOD("configure_triggers", "catalog"),
                         &DCWorldExt::configure_triggers);
    ClassDB::bind_method(D_METHOD("submit_trigger_events", "batch"),
                         &DCWorldExt::submit_trigger_events);
    ClassDB::bind_method(D_METHOD("submit_trigger_snapshots", "batch"),
                         &DCWorldExt::submit_trigger_snapshots);
    ClassDB::bind_method(D_METHOD("run_trigger_daily", "day_index"),
                         &DCWorldExt::run_trigger_daily);
    ClassDB::bind_method(D_METHOD("trigger_should_run", "day_index"),
                         &DCWorldExt::trigger_should_run);
    ClassDB::bind_method(D_METHOD("trigger_worker_authoritative"),
                         &DCWorldExt::trigger_worker_authoritative);
    ClassDB::bind_method(D_METHOD("apply_runtime_trigger_snapshot", "after_generation"),
                         &DCWorldExt::apply_runtime_trigger_snapshot,
                         DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("poll_trigger_worker_intent"),
                         &DCWorldExt::poll_trigger_worker_intent);
    ClassDB::bind_method(D_METHOD("submit_trigger_worker_ack", "ack"),
                         &DCWorldExt::submit_trigger_worker_ack);
    ClassDB::bind_method(D_METHOD("poll_trigger_effects", "after_effect_id", "limit"),
                         &DCWorldExt::poll_trigger_effects, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("ack_trigger_effects", "up_to_effect_id"),
                         &DCWorldExt::ack_trigger_effects);
    ClassDB::bind_method(D_METHOD("ack_trigger_effect_ids", "effect_ids"),
                         &DCWorldExt::ack_trigger_effect_ids);
    ClassDB::bind_method(D_METHOD("reconcile_completed_research_signals", "limit"),
                         &DCWorldExt::reconcile_completed_research_signals, DEFVAL(64));
    ClassDB::bind_method(D_METHOD("handoff_trigger_effects", "limit"),
                         &DCWorldExt::handoff_trigger_effects, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("set_trigger_enabled", "batch"),
                         &DCWorldExt::set_trigger_enabled);
    ClassDB::bind_method(D_METHOD("reconcile_trigger_branch_bindings", "batch"),
                         &DCWorldExt::reconcile_trigger_branch_bindings);
    ClassDB::bind_method(D_METHOD("get_trigger_branch_progress", "branch_handle"),
                         &DCWorldExt::get_trigger_branch_progress);
    ClassDB::bind_method(D_METHOD("get_development_progress", "country_handle", "era_index"),
                         &DCWorldExt::get_development_progress);
    ClassDB::bind_method(D_METHOD("resync_trigger_source", "snapshot"),
                         &DCWorldExt::resync_trigger_source);
    ClassDB::bind_method(D_METHOD("get_trigger_report"),
                         &DCWorldExt::get_trigger_report);
    ClassDB::bind_method(D_METHOD("capture_trigger_state"),
                         &DCWorldExt::capture_trigger_state);
    ClassDB::bind_method(D_METHOD("restore_trigger_state", "bytes"),
                         &DCWorldExt::restore_trigger_state);
    ClassDB::bind_method(D_METHOD("clear_trigger_state"),
                         &DCWorldExt::clear_trigger_state);
    ClassDB::bind_method(D_METHOD("replay_completed_research_signal",
                         "trigger_id", "target", "cell", "day"),
                         &DCWorldExt::replay_completed_research_signal);
}

} // namespace pk
