#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_modifier_methods() {
    ClassDB::bind_method(D_METHOD("configure_modifiers", "catalog", "cell_count"),
                         &DCWorldExt::configure_modifiers);
    ClassDB::bind_method(D_METHOD("submit_modifier_commands", "packed_batch"),
                         &DCWorldExt::submit_modifier_commands);
    ClassDB::bind_method(D_METHOD("run_modifier_daily", "day_index"),
                         &DCWorldExt::run_modifier_daily);
    ClassDB::bind_method(D_METHOD("modifier_should_run", "day_index"),
                         &DCWorldExt::modifier_should_run);
    ClassDB::bind_method(D_METHOD("get_modifier_command_result", "request_id"),
                         &DCWorldExt::get_modifier_command_result);
    ClassDB::bind_method(D_METHOD("list_modifiers", "domain", "entity_handle", "stat_key"),
                         &DCWorldExt::list_modifiers, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("explain_modifier_stat", "domain", "entity_handle",
                                  "group_handle", "stat_key", "base_value"),
                         &DCWorldExt::explain_modifier_stat);
    ClassDB::bind_method(D_METHOD("resolve_modifier_definition_terms", "definition_key"),
                         &DCWorldExt::resolve_modifier_definition_terms);
    ClassDB::bind_method(D_METHOD("evaluate_effect_program_magnitude",
                        "program_key", "metric_values"),
                         &DCWorldExt::evaluate_effect_program_magnitude);
    ClassDB::bind_method(D_METHOD("build_derived_cell_front_for_test", "terms"),
                         &DCWorldExt::build_derived_cell_front_for_test);
    ClassDB::bind_method(D_METHOD("get_modifier_report"),
                         &DCWorldExt::get_modifier_report);
    ClassDB::bind_method(D_METHOD("poll_modifier_events", "after_event_id", "limit"),
                         &DCWorldExt::poll_modifier_events, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("evaluate_modifier_stat", "domain", "entity_handle",
                                  "group_handle", "stat_key", "base_value"),
                         &DCWorldExt::evaluate_modifier_stat);
    ClassDB::bind_method(D_METHOD("register_gameplay_modifier_object", "archetype"),
                         &DCWorldExt::register_gameplay_modifier_object);
    ClassDB::bind_method(D_METHOD("unregister_gameplay_modifier_object", "handle", "day_index"),
                         &DCWorldExt::unregister_gameplay_modifier_object);
    ClassDB::bind_method(D_METHOD("set_gameplay_modifier_base", "handle", "stat_key", "value"),
                         &DCWorldExt::set_gameplay_modifier_base);
    ClassDB::bind_method(D_METHOD("get_gameplay_modifier_effective", "handle", "group_handle", "stat_key"),
                         &DCWorldExt::get_gameplay_modifier_effective);
    ClassDB::bind_method(D_METHOD("capture_modifier_domain", "domain"),
                         &DCWorldExt::capture_modifier_domain);
    ClassDB::bind_method(D_METHOD("restore_modifier_domain", "domain", "bytes"),
                         &DCWorldExt::restore_modifier_domain);
    ClassDB::bind_method(D_METHOD("clear_modifier_domain", "domain"),
                         &DCWorldExt::clear_modifier_domain);
    ClassDB::bind_method(D_METHOD("get_runtime_modifier_snapshot", "after_generation"),
                         &DCWorldExt::get_runtime_modifier_snapshot,
                         DEFVAL(0));
    ClassDB::bind_method(D_METHOD("install_derived_cell_layer_for_test", "front"),
        &DCWorldExt::install_derived_cell_layer_for_test);
    ClassDB::bind_method(D_METHOD("modifier_stat_bucket_version",
        "domain", "stat_ids"),
        &DCWorldExt::modifier_stat_bucket_version);
    ClassDB::bind_method(D_METHOD("collect_modifier_scope_ids",
        "domain", "scope", "stat_ids"),
        &DCWorldExt::collect_modifier_scope_ids);
    ClassDB::bind_method(D_METHOD("collect_modifier_scope_stat_entries",
        "domain", "scope", "stat_ids"),
        &DCWorldExt::collect_modifier_scope_stat_entries);
    ClassDB::bind_method(D_METHOD("resolve_modifier_stat", "stat_key"),
        &DCWorldExt::resolve_modifier_stat);
    ClassDB::bind_method(D_METHOD("get_effective_stat_value", "stat_key", "cell",
                                  "entity_handle", "base_value"),
        &DCWorldExt::get_effective_stat_value);
    ClassDB::bind_method(D_METHOD("get_derived_cell_layer_report"),
        &DCWorldExt::get_derived_cell_layer_report);
    ClassDB::bind_method(D_METHOD("get_derived_materialize_report"),
        &DCWorldExt::get_derived_materialize_report);
    ClassDB::bind_method(D_METHOD("get_derived_multi_country_report"),
        &DCWorldExt::get_derived_multi_country_report);
    ClassDB::bind_method(D_METHOD("probe_fan_out_ownership", "country_handle",
                                  "source_cell", "selector_kind", "param0", "param1",
                                  "dilate_depth"),
        &DCWorldExt::probe_fan_out_ownership, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("drain_derived_cell_layer", "day_index"),
        &DCWorldExt::drain_derived_cell_layer);
    ClassDB::bind_method(D_METHOD("probe_cell_program_backend", "facts"),
        &DCWorldExt::probe_cell_program_backend);
    ClassDB::bind_method(D_METHOD("get_cell_program_rollout"),
        &DCWorldExt::get_cell_program_rollout);
    ClassDB::bind_method(D_METHOD("apply_runtime_modifier_snapshot", "after_generation"),
                         &DCWorldExt::apply_runtime_modifier_snapshot,
                         DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("runtime_modifier_pod_self_test"),
                         &DCWorldExt::runtime_modifier_pod_self_test);
    ClassDB::bind_method(D_METHOD("ensure_modifier_building_handle", "cell", "type_id", "owner_signature_id"),
                         &DCWorldExt::ensure_modifier_building_handle);
}

} // namespace pk
