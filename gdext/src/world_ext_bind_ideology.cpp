#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_ideology_methods() {
    ClassDB::bind_method(D_METHOD("configure_ideologies", "catalog"),
                         &DCWorldExt::configure_ideologies);
    ClassDB::bind_method(D_METHOD("submit_ideology_commands", "batch"),
                         &DCWorldExt::submit_ideology_commands);
    ClassDB::bind_method(D_METHOD("poll_ideology_receipts",
                         "after_receipt_id", "limit"),
                         &DCWorldExt::poll_ideology_receipts);
    ClassDB::bind_method(D_METHOD("run_ideology_daily", "day_index"),
                         &DCWorldExt::run_ideology_daily);
    ClassDB::bind_method(D_METHOD("ideology_should_run", "day_index"),
                         &DCWorldExt::ideology_should_run);
    ClassDB::bind_method(D_METHOD("ideology_needs_daily_continuation", "day_index"),
                         &DCWorldExt::ideology_needs_daily_continuation);
    ClassDB::bind_method(D_METHOD("step_ideology_instance_refresh", "day_index"),
                         &DCWorldExt::step_ideology_instance_refresh);
    ClassDB::bind_method(D_METHOD("step_ideology_derived_rebuild", "day_index"),
                         &DCWorldExt::step_ideology_derived_rebuild);
    ClassDB::bind_method(D_METHOD("apply_runtime_ideology_snapshot",
                         "after_generation"),
                         &DCWorldExt::apply_runtime_ideology_snapshot,
                         DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("get_ideology_snapshot", "country_handle"),
                         &DCWorldExt::get_ideology_snapshot);
    ClassDB::bind_method(D_METHOD("get_ideology_effect_instance_report", "country_handle"),
                         &DCWorldExt::get_ideology_effect_instance_report);
    ClassDB::bind_method(D_METHOD("get_ideology_effect_target_report", "country_handle"),
                         &DCWorldExt::get_ideology_effect_target_report);
    ClassDB::bind_method(D_METHOD("get_city_output_factor_q16", "cell", "good_id"),
                         &DCWorldExt::get_city_output_factor_q16);
    ClassDB::bind_method(D_METHOD("resolve_effect_program_modifier_commands", "program_key"),
                         &DCWorldExt::resolve_effect_program_modifier_commands);
    ClassDB::bind_method(D_METHOD("reconcile_ideology_effects_for_test", "country_handle"),
                         &DCWorldExt::reconcile_ideology_effects_for_test);
    ClassDB::bind_method(D_METHOD("apply_ideology_self_snapshot_for_test", "generation"),
                         &DCWorldExt::apply_ideology_self_snapshot_for_test);
    ClassDB::bind_method(D_METHOD("effect_program_is_managed", "program_key"),
                         &DCWorldExt::effect_program_is_managed);
    ClassDB::bind_method(D_METHOD("query_effect_target_cells",
                         "source_cell", "selector_kind", "param0", "param1"),
                         &DCWorldExt::query_effect_target_cells);
    ClassDB::bind_method(D_METHOD("query_country_anchor_cell", "country_slot"),
                         &DCWorldExt::query_country_anchor_cell);
    ClassDB::bind_method(D_METHOD("preview_ideology_offer_eligibility", "country_handle"),
                         &DCWorldExt::preview_ideology_offer_eligibility);
    ClassDB::bind_method(D_METHOD("explain_ideology", "country_handle", "ideology_id"),
                         &DCWorldExt::explain_ideology);
    ClassDB::bind_method(D_METHOD("explain_ideologies",
                         "country_handle", "ideology_ids"),
                         &DCWorldExt::explain_ideologies);
    ClassDB::bind_method(D_METHOD("compute_idea_activation_signature_for_test",
            "handle", "ideology_id"),
                         &DCWorldExt::compute_idea_activation_signature_for_test);
    ClassDB::bind_method(D_METHOD("get_ideology_report"),
                         &DCWorldExt::get_ideology_report);
    ClassDB::bind_method(D_METHOD("get_ideology_business_state"),
                         &DCWorldExt::get_ideology_business_state);
    ClassDB::bind_method(D_METHOD("capture_ideology_state"),
                         &DCWorldExt::capture_ideology_state);
    ClassDB::bind_method(D_METHOD("restore_ideology_state", "bytes"),
                         &DCWorldExt::restore_ideology_state);
    ClassDB::bind_method(D_METHOD("clear_ideology_state"),
                         &DCWorldExt::clear_ideology_state);
    ClassDB::bind_method(D_METHOD("publish_ideology_worker_inputs"),
                         &DCWorldExt::publish_ideology_worker_inputs);
    ClassDB::bind_method(D_METHOD("poll_ideology_worker_intent"),
                         &DCWorldExt::poll_ideology_worker_intent);
    ClassDB::bind_method(D_METHOD("submit_ideology_worker_ack", "ack"),
                         &DCWorldExt::submit_ideology_worker_ack);
}

} // namespace pk
