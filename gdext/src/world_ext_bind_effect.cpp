#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_effect_methods() {
    ClassDB::bind_method(D_METHOD("apply_runtime_effect_snapshot", "after_generation"),
                         &DCWorldExt::apply_runtime_effect_snapshot,
                         DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("configure_effects", "catalog"),
                         &DCWorldExt::configure_effects);
    ClassDB::bind_method(D_METHOD("submit_effect_instances", "batch"),
                         &DCWorldExt::submit_effect_instances);
    ClassDB::bind_method(D_METHOD("retire_effect_instance", "instance_id", "generation", "effective_day"),
                         &DCWorldExt::retire_effect_instance);
    ClassDB::bind_method(D_METHOD("set_effect_forwarder_authority_for_test", "mode"),
                         &DCWorldExt::set_effect_forwarder_authority_for_test);
    ClassDB::bind_method(D_METHOD("queue_effect_pod_instance", "input"),
                         &DCWorldExt::queue_effect_pod_instance);
    ClassDB::bind_method(D_METHOD("queue_effect_pod_metric", "input"),
                         &DCWorldExt::queue_effect_pod_metric);
    ClassDB::bind_method(D_METHOD("queue_effect_pod_remove", "instance_id", "generation"),
                         &DCWorldExt::queue_effect_pod_remove);
    ClassDB::bind_method(D_METHOD("poll_effect_worker_intent"),
                         &DCWorldExt::poll_effect_worker_intent);
    ClassDB::bind_method(D_METHOD("submit_effect_worker_ack", "ack"),
                         &DCWorldExt::submit_effect_worker_ack);
    ClassDB::bind_method(D_METHOD("effect_instance_fire_acked", "instance_id", "generation"),
                         &DCWorldExt::effect_instance_fire_acked);
    ClassDB::bind_method(D_METHOD("query_effect_instance_metric", "instance_id", "metric_id"),
                         &DCWorldExt::query_effect_instance_metric);
    ClassDB::bind_method(D_METHOD("submit_effect_snapshots", "batch"),
                         &DCWorldExt::submit_effect_snapshots);
    ClassDB::bind_method(D_METHOD("run_effect_daily", "day_index"),
                         &DCWorldExt::run_effect_daily);
    ClassDB::bind_method(D_METHOD("dispatch_effect_native_modifier"),
                         &DCWorldExt::dispatch_effect_native_modifier);
    ClassDB::bind_method(D_METHOD("ack_effect_native_modifier"),
                         &DCWorldExt::ack_effect_native_modifier);
    ClassDB::bind_method(D_METHOD("dispatch_effect_native_country"),
                         &DCWorldExt::dispatch_effect_native_country);
    ClassDB::bind_method(D_METHOD("ack_effect_native_country"),
                         &DCWorldExt::ack_effect_native_country);
    ClassDB::bind_method(D_METHOD("settle_orphaned_effect_native_country_acks"),
                         &DCWorldExt::settle_orphaned_effect_native_country_acks);
    ClassDB::bind_method(D_METHOD("dispatch_effect_native_economy"),
                         &DCWorldExt::dispatch_effect_native_economy);
    ClassDB::bind_method(D_METHOD("ack_effect_native_economy"),
                         &DCWorldExt::ack_effect_native_economy);
    ClassDB::bind_method(D_METHOD("dispatch_effect_native_gameplay"),
                         &DCWorldExt::dispatch_effect_native_gameplay);
    ClassDB::bind_method(D_METHOD("ack_effect_native_gameplay"),
                         &DCWorldExt::ack_effect_native_gameplay);
    ClassDB::bind_method(D_METHOD("get_effect_native_adapter_report"),
                         &DCWorldExt::get_effect_native_adapter_report);
    ClassDB::bind_method(D_METHOD("effect_should_run", "day_index"),
                         &DCWorldExt::effect_should_run);
    ClassDB::bind_method(D_METHOD("poll_effect_transactions", "after_transaction_id", "limit"),
                         &DCWorldExt::poll_effect_transactions, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("preflight_effect_transactions", "batch"),
                         &DCWorldExt::preflight_effect_transactions);
    ClassDB::bind_method(D_METHOD("commit_effect_transactions", "batch"),
                         &DCWorldExt::commit_effect_transactions);
    ClassDB::bind_method(D_METHOD("ack_effect_transactions", "batch"),
                         &DCWorldExt::ack_effect_transactions);
    ClassDB::bind_method(D_METHOD("explain_effect", "instance_id"),
                         &DCWorldExt::explain_effect);
    ClassDB::bind_method(D_METHOD("get_effect_report"),
                         &DCWorldExt::get_effect_report);
    ClassDB::bind_method(D_METHOD("capture_effect_state"),
                         &DCWorldExt::capture_effect_state);
    ClassDB::bind_method(D_METHOD("restore_effect_state", "bytes"),
                         &DCWorldExt::restore_effect_state);
    ClassDB::bind_method(D_METHOD("clear_effect_state"),
                         &DCWorldExt::clear_effect_state);
    ClassDB::bind_method(D_METHOD("bind_era_reward_player_country",
                                  "country_handle"),
                         &DCWorldExt::bind_era_reward_player_country);
    ClassDB::bind_method(D_METHOD("get_era_reward_offer"),
                         &DCWorldExt::get_era_reward_offer);
    ClassDB::bind_method(D_METHOD("choose_era_reward", "offer_generation",
                                  "choice_index", "effective_day"),
                         &DCWorldExt::choose_era_reward);
}

} // namespace pk
