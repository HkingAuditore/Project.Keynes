#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_economy_methods() {
    ClassDB::bind_method(D_METHOD("get_economy_checkpoint_format"),
                         &DCWorldExt::get_economy_checkpoint_format);
    ClassDB::bind_method(D_METHOD("diagnose_colonization_target",
                        "country_handle", "target_cell"),
                         &DCWorldExt::diagnose_colonization_target);
    ClassDB::bind_method(D_METHOD("flush_runtime_economy_resource_writeback"),
                         &DCWorldExt::flush_runtime_economy_resource_writeback);
    ClassDB::bind_method(D_METHOD("get_country_fiscal_snapshot", "handle"),
                         &DCWorldExt::get_country_fiscal_snapshot);
    // R-4 X16 / metric probes.
    ClassDB::bind_method(D_METHOD("get_epoch_profession_report", "country_slot"),
                         &DCWorldExt::get_epoch_profession_report);
    ClassDB::bind_method(D_METHOD("sample_effect_metric_probe", "metric", "cell",
                                  "country_handle"),
                         &DCWorldExt::sample_effect_metric_probe);
    // Independent native PopulationCohort + local-market authority.
    ClassDB::bind_method(D_METHOD("configure_economy", "catalog", "profile", "cell_count", "seed"),
                         &DCWorldExt::configure_economy);
    ClassDB::bind_method(D_METHOD("configure_economy_natural_resources", "knobs"),
                         &DCWorldExt::configure_economy_natural_resources);
    ClassDB::bind_method(D_METHOD("bootstrap_economy", "population_packet", "market_packet"),
                         &DCWorldExt::bootstrap_economy);
    ClassDB::bind_method(D_METHOD("submit_economy_commands", "packed_batch"),
                         &DCWorldExt::submit_economy_commands);
    ClassDB::bind_method(D_METHOD("submit_economy_pod_commands", "packed_batch"),
                         &DCWorldExt::submit_economy_pod_commands);
    ClassDB::bind_method(D_METHOD("poll_economy_pod_receipts", "max_items"),
                         &DCWorldExt::poll_economy_pod_receipts, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("run_economy_slice", "ctx"),
                         &DCWorldExt::run_economy_slice);
    ClassDB::bind_method(D_METHOD("run_economy_slice_compact", "ctx"),
                         &DCWorldExt::run_economy_slice_compact);
    ClassDB::bind_method(D_METHOD("run_economy_stage_ops_day", "day_index"),
                         &DCWorldExt::run_economy_stage_ops_day);
    ClassDB::bind_method(D_METHOD("set_economy_stage_ops_soak_parity_ok", "ok"),
                         &DCWorldExt::set_economy_stage_ops_soak_parity_ok);
    ClassDB::bind_method(D_METHOD("get_economy_stage_ops_soak_parity_ok"),
                         &DCWorldExt::get_economy_stage_ops_soak_parity_ok);
    ClassDB::bind_method(D_METHOD("capture_economy_day_inputs", "day_index"),
                         &DCWorldExt::capture_economy_day_inputs);
    ClassDB::bind_method(D_METHOD("begin_or_reuse_economy_input_epoch",
                                  "day_index", "generation"),
                         &DCWorldExt::begin_or_reuse_economy_input_epoch);
    ClassDB::bind_method(D_METHOD("economy_should_run", "day_index"),
                         &DCWorldExt::economy_should_run);
    ClassDB::bind_method(D_METHOD("economy_deadline_critical", "day_index"),
                         &DCWorldExt::economy_deadline_critical);
    ClassDB::bind_method(D_METHOD("get_economy_live_cells"),
                         &DCWorldExt::get_economy_live_cells);
    // ---- end Economy military hooks ----
    ClassDB::bind_method(D_METHOD("set_effect_metric_override_for_test",
            "metric", "value", "has_value"),
                         &DCWorldExt::set_effect_metric_override_for_test);
    ClassDB::bind_method(D_METHOD(
                             "set_family_target_min_branches_override_for_test",
                             "min_branches"),
                         &DCWorldExt::set_family_target_min_branches_override_for_test);
    ClassDB::bind_method(D_METHOD("set_cell_tag_override_for_test",
            "tag_key", "cell", "on"),
                         &DCWorldExt::set_cell_tag_override_for_test);
    ClassDB::bind_method(D_METHOD("clear_cell_tag_overrides_for_test"),
                         &DCWorldExt::clear_cell_tag_overrides_for_test);
    ClassDB::bind_method(D_METHOD("refresh_effect_input_digest_for_test"),
                         &DCWorldExt::refresh_effect_input_digest_for_test);
    ClassDB::bind_method(D_METHOD("get_class_metric_source_for_test"),
                         &DCWorldExt::get_class_metric_source_for_test);
    ClassDB::bind_method(D_METHOD("capture_class_metric_source_for_test"),
                         &DCWorldExt::capture_class_metric_source_for_test);
    ClassDB::bind_method(D_METHOD("set_class_opinion_source_override_for_test",
            "population", "satisfaction_q16", "satisfaction_weighted"),
                         &DCWorldExt::set_class_opinion_source_override_for_test);
    ClassDB::bind_method(D_METHOD("clear_class_opinion_source_override_for_test"),
                         &DCWorldExt::clear_class_opinion_source_override_for_test);
    ClassDB::bind_method(D_METHOD(
                             "set_country_technology_metric_input_for_test",
                             "country_slot", "words"),
                         &DCWorldExt::set_country_technology_metric_input_for_test);
    ClassDB::bind_method(D_METHOD(
                             "clear_country_technology_metric_input_for_test"),
                         &DCWorldExt::clear_country_technology_metric_input_for_test);
    ClassDB::bind_method(D_METHOD("get_effect_input_revisions"),
                         &DCWorldExt::get_effect_input_revisions);
    ClassDB::bind_method(D_METHOD("get_economy_report"),
                         &DCWorldExt::get_economy_report);
    ClassDB::bind_method(D_METHOD("get_economy_committed_audit_report"),
                         &DCWorldExt::get_economy_committed_audit_report);
    ClassDB::bind_method(D_METHOD("get_country_class_opinion_snapshot"),
                         &DCWorldExt::get_country_class_opinion_snapshot);
    ClassDB::bind_method(D_METHOD("get_population_cell_summary", "cell_idx"),
                         &DCWorldExt::get_population_cell_summary);
    ClassDB::bind_method(D_METHOD("get_named_settlement_snapshot"),
                         &DCWorldExt::get_named_settlement_snapshot);
    ClassDB::bind_method(D_METHOD("get_settlement_delta", "since_revision"),
                         &DCWorldExt::get_settlement_delta);
    ClassDB::bind_method(D_METHOD("get_population_cell_snapshot", "cell_idx",
                                  "include_details"),
                         &DCWorldExt::get_population_cell_snapshot,
                         DEFVAL(true));
    ClassDB::bind_method(D_METHOD("get_market_cell_snapshot", "cell_idx"),
                         &DCWorldExt::get_market_cell_snapshot);
    ClassDB::bind_method(
        D_METHOD("get_cell_situation_snapshot", "requested_cells"),
        &DCWorldExt::get_cell_situation_snapshot);
    ClassDB::bind_method(D_METHOD("explain_cohort_satisfaction", "cohort_handle"),
                         &DCWorldExt::explain_cohort_satisfaction);
    ClassDB::bind_method(
        D_METHOD("get_cell_satisfaction_attractiveness", "cell_idx"),
        &DCWorldExt::get_cell_satisfaction_attractiveness);
    ClassDB::bind_method(D_METHOD("get_country_trade_snapshot",
                                  "country_handle", "view", "offset", "limit"),
                         &DCWorldExt::get_country_trade_snapshot,
                         DEFVAL("summary"), DEFVAL(0), DEFVAL(32));
    ClassDB::bind_method(D_METHOD("get_country_economy_overview",
                                  "country_handle", "view", "scope_cell",
                                  "filter_id", "offset", "limit"),
                         &DCWorldExt::get_country_economy_overview,
                         DEFVAL("summary"), DEFVAL(-1), DEFVAL(-1), DEFVAL(0),
                         DEFVAL(0));
    ClassDB::bind_method(D_METHOD("get_trade_orders_for_cell", "cell_idx", "offset",
                                  "limit", "good_index"),
                         &DCWorldExt::get_trade_orders_for_cell,
                         DEFVAL(0), DEFVAL(64), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("get_trade_visual_snapshot", "cells", "visible",
        "vision_revision", "selected_cell", "enabled"),
        &DCWorldExt::get_trade_visual_snapshot, DEFVAL(-1), DEFVAL(true));
    ClassDB::bind_method(D_METHOD("capture_economy_trade_topology", "neighbor_indices",
                                  "terrain", "trade_passable_lut",
                                  "trade_move_cost_lut", "generation",
                                  "landform", "has_river"),
                         &DCWorldExt::capture_economy_trade_topology, DEFVAL(0),
                         DEFVAL(PackedByteArray()), DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("capture_economy_trade_visibility",
                                  "visible", "fog_solved"),
                         &DCWorldExt::capture_economy_trade_visibility);
    ClassDB::bind_method(D_METHOD("get_building_cell_snapshot", "cell_idx"),
                         &DCWorldExt::get_building_cell_snapshot);
    ClassDB::bind_method(D_METHOD("get_building_visual_snapshot", "requested_cells"),
                         &DCWorldExt::get_building_visual_snapshot);
    ClassDB::bind_method(D_METHOD("consume_building_visual_dirty_cells"),
                          &DCWorldExt::consume_building_visual_dirty_cells);
    ClassDB::bind_method(D_METHOD("get_treasury_construction_quotes",
                                  "country_handle", "cell_idx", "type_ids"),
                         &DCWorldExt::get_treasury_construction_quotes);
    ClassDB::bind_method(D_METHOD("get_construction_command_receipts",
                                  "after_receipt_id", "limit"),
                         &DCWorldExt::get_construction_command_receipts,
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("queue_treasury_sponsored_build",
                                  "country_handle", "cell_idx", "type_id",
                                  "effective_day", "sequence"),
                         &DCWorldExt::queue_treasury_sponsored_build);
    ClassDB::bind_method(D_METHOD("queue_treasury_sponsored_demolish",
                                  "country_handle", "cell_idx", "type_id",
                                  "count", "effective_day", "sequence"),
                         &DCWorldExt::queue_treasury_sponsored_demolish);
    ClassDB::bind_method(D_METHOD("get_family_cell_snapshot", "cell_idx",
                                  "offset", "limit"),
                         &DCWorldExt::get_family_cell_snapshot, DEFVAL(0),
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_family_snapshot", "family_handle"),
                         &DCWorldExt::get_family_snapshot);
    ClassDB::bind_method(D_METHOD("get_family_traits", "family_handle"),
                         &DCWorldExt::get_family_traits);
    ClassDB::bind_method(D_METHOD("get_family_branches", "family_handle",
                                  "offset", "limit"),
                         &DCWorldExt::get_family_branches, DEFVAL(0), DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_family_colonization_quotes",
                                  "country_handle", "target_cell",
                                  "family_filter", "source_filter", "offset",
                                  "limit"),
                         &DCWorldExt::get_family_colonization_quotes,
                         DEFVAL(0), DEFVAL(-1), DEFVAL(0), DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_family_colonization_quote_detail",
                                  "quote_token", "population"),
                         &DCWorldExt::get_family_colonization_quote_detail,
                         DEFVAL(int64_t(-1)));
    ClassDB::bind_method(D_METHOD("start_family_colonization",
                                  "country_handle", "family_handle",
                                  "source_cell", "target_cell", "population",
                                  "quote_token", "effective_day", "sequence"),
                         &DCWorldExt::start_family_colonization);
    ClassDB::bind_method(D_METHOD("cancel_family_colonization",
                                  "country_handle", "expedition_handle",
                                  "effective_day", "sequence"),
                         &DCWorldExt::cancel_family_colonization);
    ClassDB::bind_method(D_METHOD("set_country_procurement_policy",
                                  "country_handle", "enabled",
                                  "treasury_share_bp", "research_share_bp",
                                  "effective_day", "sequence",
                                  "era_share_bp", "colonization_share_bp"),
                         &DCWorldExt::set_country_procurement_policy,
                         DEFVAL(-1), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("set_era_procurement_target",
                                  "country_handle", "active", "good_indices",
                                  "required_quantities", "effective_day",
                                  "sequence"),
                         &DCWorldExt::set_era_procurement_target);
    ClassDB::bind_method(D_METHOD("country_procurement_snapshot",
                                  "country_handle"),
                         &DCWorldExt::country_procurement_snapshot);
    ClassDB::bind_method(D_METHOD("get_family_expeditions", "country_handle",
                                  "offset", "limit"),
                         &DCWorldExt::get_family_expeditions,
                         DEFVAL(0), DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_family_expedition_snapshot",
                                  "country_handle", "expedition_handle"),
                         &DCWorldExt::get_family_expedition_snapshot);
    ClassDB::bind_method(D_METHOD("get_family_colonization_receipts",
                                  "country_handle", "after_receipt_id", "limit"),
                         &DCWorldExt::get_family_colonization_receipts,
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_canal_route_quote", "country_handle",
                                  "start_cell", "end_cell", "waypoints"),
                         &DCWorldExt::get_canal_route_quote,
                         DEFVAL(PackedInt32Array()));
    ClassDB::bind_method(D_METHOD("get_canal_route_quote_detail",
                                  "country_handle", "quote_token"),
                         &DCWorldExt::get_canal_route_quote_detail);
    ClassDB::bind_method(D_METHOD("queue_canal_construction",
                                  "country_handle", "quote_token",
                                  "effective_day", "sequence"),
                         &DCWorldExt::queue_canal_construction);
    ClassDB::bind_method(D_METHOD("get_canal_construction_receipts",
                                  "country_handle", "after_receipt_id", "limit"),
                         &DCWorldExt::get_canal_construction_receipts,
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_family_branch_effects", "family_handle",
                                  "cell_idx"),
                         &DCWorldExt::get_family_branch_effects);
    ClassDB::bind_method(D_METHOD("submit_family_trait_commands", "packed_batch"),
                         &DCWorldExt::submit_family_trait_commands);
    ClassDB::bind_method(D_METHOD("get_family_founding_offers", "offset", "limit"),
                         &DCWorldExt::get_family_founding_offers, DEFVAL(0),
                         DEFVAL(16));
    ClassDB::bind_method(D_METHOD("submit_family_founding_choice", "offer_id",
                                 "generation", "choice_index", "effective_day",
                                 "sequence"),
                         &DCWorldExt::submit_family_founding_choice);
    ClassDB::bind_method(D_METHOD("get_family_industries", "family_handle",
                                 "offset", "limit"),
                         &DCWorldExt::get_family_industries, DEFVAL(0),
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_family_notable_people", "family_handle",
                                 "offset", "limit"),
                         &DCWorldExt::get_family_notable_people, DEFVAL(0),
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_notable_person_snapshot", "person_handle"),
                         &DCWorldExt::get_notable_person_snapshot);
    ClassDB::bind_method(D_METHOD("get_notable_person_needs", "person_handle",
                                 "offset", "limit"),
                         &DCWorldExt::get_notable_person_needs, DEFVAL(0),
                         DEFVAL(32));
    ClassDB::bind_method(D_METHOD("get_building_notable_people", "building_handle",
                                 "offset", "limit"),
                         &DCWorldExt::get_building_notable_people, DEFVAL(0),
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_economy_read_view_status"),
                         &DCWorldExt::get_economy_read_view_status);
    ClassDB::bind_method(D_METHOD(
        "run_economy_production_climate_math_probe", "vectors"),
        &DCWorldExt::run_economy_production_climate_math_probe);
    ClassDB::bind_method(D_METHOD("get_economy_state_hash"),
                         &DCWorldExt::get_economy_state_hash);
    ClassDB::bind_method(D_METHOD("inject_economy_cadence_timing",
                                 "market_cycle_ms", "slow_cycle_ms",
                                 "investment_cycle_ms"),
                         &DCWorldExt::inject_economy_cadence_timing,
                         DEFVAL(-1.0));
    ClassDB::bind_method(D_METHOD("reset_economy", "reason"),
                         &DCWorldExt::reset_economy);
    ClassDB::bind_method(D_METHOD("start_economy_csv_recording", "config"),
                         &DCWorldExt::start_economy_csv_recording);
    ClassDB::bind_method(D_METHOD("request_stop_economy_csv_recording"),
                         &DCWorldExt::request_stop_economy_csv_recording);
    ClassDB::bind_method(D_METHOD("get_economy_csv_recording_status"),
                         &DCWorldExt::get_economy_csv_recording_status);
    ClassDB::bind_method(D_METHOD("begin_economy_save", "chunk_bytes"),
                         &DCWorldExt::begin_economy_save, DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("begin_economy_forensics_save", "chunk_bytes"),
                         &DCWorldExt::begin_economy_forensics_save, DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("read_economy_save_chunk", "max_bytes"),
                         &DCWorldExt::read_economy_save_chunk, DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("end_economy_save"),
                         &DCWorldExt::end_economy_save);
    ClassDB::bind_method(D_METHOD("capture_economy_ecp2", "flags"),
                         &DCWorldExt::capture_economy_ecp2, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("restore_economy_ecp2", "bytes"),
                         &DCWorldExt::restore_economy_ecp2);
    ClassDB::bind_method(D_METHOD("begin_economy_restore"),
                         &DCWorldExt::begin_economy_restore);
    ClassDB::bind_method(D_METHOD("get_economy_restore_rejected_reason"),
                         &DCWorldExt::get_economy_restore_rejected_reason);
    ClassDB::bind_method(D_METHOD("feed_economy_restore_chunk", "chunk"),
                         &DCWorldExt::feed_economy_restore_chunk);
    ClassDB::bind_method(D_METHOD("end_economy_restore"),
                         &DCWorldExt::end_economy_restore);
    ClassDB::bind_method(D_METHOD("get_economy_event_schema"),
                         &DCWorldExt::get_economy_event_schema);
    ClassDB::bind_method(D_METHOD("set_economy_trace_filter", "filter"),
                         &DCWorldExt::set_economy_trace_filter);
    ClassDB::bind_method(D_METHOD("set_economy_inspector_trace_cell", "cell_idx"),
                         &DCWorldExt::set_economy_inspector_trace_cell);
    ClassDB::bind_method(D_METHOD("poll_economy_events", "opts"),
                         &DCWorldExt::poll_economy_events);
    ClassDB::bind_method(D_METHOD("ack_economy_events", "consumer_id", "up_to_event_id"),
                         &DCWorldExt::ack_economy_events);
    ClassDB::bind_method(D_METHOD("get_economy_trace_report"),
                         &DCWorldExt::get_economy_trace_report);
    ClassDB::bind_method(D_METHOD("begin_economy_event_archive", "chunk_bytes"),
                         &DCWorldExt::begin_economy_event_archive,
                         DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("read_economy_event_archive_chunk", "max_bytes"),
                         &DCWorldExt::read_economy_event_archive_chunk,
                         DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("end_economy_event_archive"),
                         &DCWorldExt::end_economy_event_archive);
}

} // namespace pk
