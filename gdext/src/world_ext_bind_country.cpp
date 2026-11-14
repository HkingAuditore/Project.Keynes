#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_country_methods() {
    ClassDB::bind_method(D_METHOD("configure_annual_reports", "country_handle", "days_per_year", "initial_day", "profile"), &DCWorldExt::configure_annual_reports);
    ClassDB::bind_method(D_METHOD("commit_annual_reports", "day"), &DCWorldExt::commit_annual_reports);
    ClassDB::bind_method(D_METHOD("get_annual_report_status"), &DCWorldExt::get_annual_report_status);
    ClassDB::bind_method(D_METHOD("get_annual_report_snapshot", "report_id"), &DCWorldExt::get_annual_report_snapshot);
    ClassDB::bind_method(D_METHOD("get_annual_report_history", "offset", "limit"), &DCWorldExt::get_annual_report_history, DEFVAL(0), DEFVAL(32));
    ClassDB::bind_method(D_METHOD("mark_annual_report_presented", "report_id"), &DCWorldExt::mark_annual_report_presented);
    ClassDB::bind_method(D_METHOD("capture_annual_report_state"), &DCWorldExt::capture_annual_report_state);
    ClassDB::bind_method(D_METHOD("restore_annual_report_state", "bytes"), &DCWorldExt::restore_annual_report_state);
    ClassDB::bind_method(D_METHOD("annual_report_self_test"), &DCWorldExt::annual_report_self_test);
    ClassDB::bind_method(D_METHOD("capture_country_runtime_snapshot"),
                         &DCWorldExt::capture_country_runtime_snapshot);
    ClassDB::bind_method(D_METHOD("get_country_territory_counts"),
                         &DCWorldExt::get_country_territory_counts);
    ClassDB::bind_method(D_METHOD("get_economy_territory_plane"),
                         &DCWorldExt::get_economy_territory_plane);
    ClassDB::bind_method(D_METHOD("capture_country_pod_catalog"),
                         &DCWorldExt::capture_country_pod_catalog);
    ClassDB::bind_method(D_METHOD("get_country_worker_protocol_status"),
                         &DCWorldExt::get_country_worker_protocol_status);
    ClassDB::bind_method(D_METHOD("get_country_worker_read_view",
                                  "after_generation"),
                         &DCWorldExt::get_country_worker_read_view);
    ClassDB::bind_method(D_METHOD("poll_country_worker_intent"),
                         &DCWorldExt::poll_country_worker_intent);
    ClassDB::bind_method(D_METHOD("get_country_economy_asset_protocol_status"),
                         &DCWorldExt::get_country_economy_asset_protocol_status);
    ClassDB::bind_method(D_METHOD("poll_country_economy_asset_request"),
                         &DCWorldExt::poll_country_economy_asset_request);
    ClassDB::bind_method(D_METHOD("submit_country_economy_asset_result", "result"),
                         &DCWorldExt::submit_country_economy_asset_result);
    ClassDB::bind_method(D_METHOD("runtime_country_host_economy_protocol_self_test"),
                         &DCWorldExt::runtime_country_host_economy_protocol_self_test);
    ClassDB::bind_method(D_METHOD("runtime_country_host_handoff_self_test"),
                         &DCWorldExt::runtime_country_host_handoff_self_test);
    ClassDB::bind_method(D_METHOD("prepare_country_authority_handoff", "target_owner"),
                         &DCWorldExt::prepare_country_authority_handoff);
    ClassDB::bind_method(D_METHOD("install_country_authority_handoff"),
                         &DCWorldExt::install_country_authority_handoff);
    ClassDB::bind_method(D_METHOD("abort_country_authority_handoff"),
                         &DCWorldExt::abort_country_authority_handoff);
    ClassDB::bind_method(D_METHOD("get_country_authority_handoff_status"),
                         &DCWorldExt::get_country_authority_handoff_status);
    ClassDB::bind_method(D_METHOD("runtime_country_host_rejection_self_test"),
                         &DCWorldExt::runtime_country_host_rejection_self_test);
    ClassDB::bind_method(D_METHOD("runtime_country_shadow_parity_self_test"),
                         &DCWorldExt::runtime_country_shadow_parity_self_test);
    ClassDB::bind_method(D_METHOD("service_country_worker_peer_adapter",
                                  "max_intents", "shadow_replay"),
                         &DCWorldExt::service_country_worker_peer_adapter,
                         DEFVAL(64), DEFVAL(true));
    ClassDB::bind_method(D_METHOD("configure_country_reference_trace", "enabled", "max_frames"),
                         &DCWorldExt::configure_country_reference_trace,
                         DEFVAL(4096));
    ClassDB::bind_method(D_METHOD("poll_country_reference_trace", "after_frame_id", "limit"),
                         &DCWorldExt::poll_country_reference_trace,
                         DEFVAL(0), DEFVAL(128));
    ClassDB::bind_method(D_METHOD("capture_country_reference_checkpoint"),
                         &DCWorldExt::capture_country_reference_checkpoint);
    ClassDB::bind_method(D_METHOD("restore_country_runtime_checkpoint", "canonical_pkcn"),
                         &DCWorldExt::restore_country_runtime_checkpoint);
    ClassDB::bind_method(D_METHOD("set_country_peer_async_mode", "enabled"),
                         &DCWorldExt::set_country_peer_async_mode);
    ClassDB::bind_method(D_METHOD("get_country_peer_protocol_status"),
                         &DCWorldExt::get_country_peer_protocol_status);
    ClassDB::bind_method(D_METHOD("poll_country_peer_intent"),
                         &DCWorldExt::poll_country_peer_intent);
    ClassDB::bind_method(D_METHOD("submit_country_peer_result", "result"),
                         &DCWorldExt::submit_country_peer_result);
    ClassDB::bind_method(D_METHOD("service_country_peer_adapter", "max_intents"),
                         &DCWorldExt::service_country_peer_adapter,
                         DEFVAL(64));
    ClassDB::bind_method(D_METHOD("begin_country_economy_treasury_spend",
                                  "country_handle", "good_ids", "quantities",
                                  "cash", "origin_epoch", "origin_stage",
                                  "request_id"),
                         &DCWorldExt::begin_country_economy_treasury_spend,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_fiscal_reserve",
                                  "country_handle", "requested", "origin_epoch",
                                  "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_fiscal_reserve,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_fiscal_return",
                                  "country_handle", "offered", "origin_epoch",
                                  "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_fiscal_return,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_fiscal_collect",
                                  "country_handle", "offered", "origin_epoch",
                                  "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_fiscal_collect,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_cash_to_cohort",
                                  "country_handle", "requested", "origin_epoch",
                                  "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_cash_to_cohort,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_cash_from_cohort",
                                  "country_handle", "offered", "origin_epoch",
                                  "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_cash_from_cohort,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_good_to_market",
                                  "country_handle", "good_id", "requested",
                                  "origin_epoch", "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_good_to_market,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_good_from_market",
                                  "country_handle", "good_id", "offered",
                                  "origin_epoch", "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_good_from_market,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_country_economy_research_purchase",
                                  "country_handle", "quantity", "total_cost",
                                  "origin_epoch", "origin_stage", "request_id"),
                         &DCWorldExt::begin_country_economy_research_purchase,
                         DEFVAL(-1), DEFVAL(-1), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("ack_country_economy_asset_peer_prepared",
                                  "transaction_id", "session_epoch",
                                  "country_generation", "peer_generation",
                                  "accepted", "reason"),
                         &DCWorldExt::ack_country_economy_asset_peer_prepared,
                         DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("commit_country_economy_treasury_spend",
                                  "transaction_id"),
                         &DCWorldExt::commit_country_economy_treasury_spend);
    ClassDB::bind_method(D_METHOD("commit_country_economy_fiscal_reserve",
                                  "transaction_id"),
                         &DCWorldExt::commit_country_economy_fiscal_reserve);
    ClassDB::bind_method(D_METHOD("commit_country_economy_asset_transaction",
                                  "transaction_id"),
                         &DCWorldExt::commit_country_economy_asset_transaction);
    ClassDB::bind_method(D_METHOD("ack_country_economy_asset_peer_applied",
                                  "transaction_id", "session_epoch",
                                  "country_generation", "peer_generation",
                                  "accepted", "reason"),
                         &DCWorldExt::ack_country_economy_asset_peer_applied,
                         DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("get_country_economy_asset_transaction",
                                  "transaction_id"),
                         &DCWorldExt::get_country_economy_asset_transaction);
    ClassDB::bind_method(D_METHOD("runtime_country_core_protocol_self_test"),
                         &DCWorldExt::runtime_country_core_protocol_self_test);
    ClassDB::bind_method(D_METHOD("runtime_country_peer_protocol_self_test"),
                         &DCWorldExt::runtime_country_peer_protocol_self_test);
    ClassDB::bind_method(D_METHOD("bootstrap_country", "packet", "is_water"),
                         &DCWorldExt::bootstrap_country);
    ClassDB::bind_method(D_METHOD("submit_country_commands", "packed_batch"),
                         &DCWorldExt::submit_country_commands);
    ClassDB::bind_method(D_METHOD("poll_country_command_receipts",
                                  "after_request_id", "limit"),
                         &DCWorldExt::poll_country_command_receipts,
                         DEFVAL(0), DEFVAL(128));
    ClassDB::bind_method(D_METHOD("runtime_country_host_receipt_self_test"),
                         &DCWorldExt::runtime_country_host_receipt_self_test);
    ClassDB::bind_method(D_METHOD("set_country_sync_store_writes_forbidden", "forbidden"),
                         &DCWorldExt::set_country_sync_store_writes_forbidden);
    ClassDB::bind_method(D_METHOD("run_country_slice", "ctx"),
                         &DCWorldExt::run_country_slice);
    ClassDB::bind_method(D_METHOD("configure_country_ai", "catalog"),
                         &DCWorldExt::configure_country_ai);
    ClassDB::bind_method(D_METHOD("set_country_ai_mode", "mode"),
                         &DCWorldExt::set_country_ai_mode);
    ClassDB::bind_method(D_METHOD("set_country_ai_excluded_handles", "handles"),
                         &DCWorldExt::set_country_ai_excluded_handles);
    ClassDB::bind_method(D_METHOD("set_country_ai_topology", "neighbors", "cell_value_q16"),
                         &DCWorldExt::set_country_ai_topology);
    ClassDB::bind_method(D_METHOD("get_country_ai_report"),
                         &DCWorldExt::get_country_ai_report);
    ClassDB::bind_method(D_METHOD("get_country_ai_country_snapshot", "handle"),
                         &DCWorldExt::get_country_ai_country_snapshot);
    ClassDB::bind_method(D_METHOD("poll_country_ai_decisions", "after_id", "limit"),
                         &DCWorldExt::poll_country_ai_decisions, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("drain_country_ai_record_rows", "limit"),
                         &DCWorldExt::drain_country_ai_record_rows, DEFVAL(4096));
    ClassDB::bind_method(D_METHOD("encode_country_ai_state"),
                         &DCWorldExt::encode_country_ai_state);
    ClassDB::bind_method(D_METHOD("restore_country_ai_state", "bytes"),
                         &DCWorldExt::restore_country_ai_state);
    ClassDB::bind_method(D_METHOD("runtime_country_ai_self_test"),
                         &DCWorldExt::runtime_country_ai_self_test);
    // ---- end Military cell stats
    // ---- end Military -----------------------------------------------------
    ClassDB::bind_method(D_METHOD("sync_country_territory_to_map"),
                         &DCWorldExt::sync_country_territory_to_map);
    ClassDB::bind_method(D_METHOD("country_should_run", "day_index"),
                         &DCWorldExt::country_should_run);
    ClassDB::bind_method(D_METHOD("get_country_report"),
                         &DCWorldExt::get_country_report);
    ClassDB::bind_method(D_METHOD("get_country_state_hash"),
                         &DCWorldExt::get_country_state_hash);
    ClassDB::bind_method(D_METHOD("get_country_cell_summary", "cell_idx"),
                         &DCWorldExt::get_country_cell_summary);
    ClassDB::bind_method(D_METHOD("get_country_snapshot", "handle"),
                         &DCWorldExt::get_country_snapshot);
    ClassDB::bind_method(D_METHOD("get_country_political_regime_snapshot", "handle"),
                         &DCWorldExt::get_country_political_regime_snapshot);
    ClassDB::bind_method(D_METHOD("get_country_treasury_snapshot", "handle"),
                         &DCWorldExt::get_country_treasury_snapshot);
    ClassDB::bind_method(D_METHOD("get_country_research_snapshot", "handle"),
                         &DCWorldExt::get_country_research_snapshot);
    ClassDB::bind_method(D_METHOD("consume_country_visual_era_dirty_slots"),
                         &DCWorldExt::consume_country_visual_era_dirty_slots);
    ClassDB::bind_method(D_METHOD("get_country_research_signal_snapshot", "handle"),
                         &DCWorldExt::get_country_research_signal_snapshot);
    ClassDB::bind_method(D_METHOD("has_completed_country_technology", "handle",
                                 "technology_id"),
                         &DCWorldExt::has_completed_country_technology);
    ClassDB::bind_method(D_METHOD("get_country_tax_policy_snapshot", "handle"),
                         &DCWorldExt::get_country_tax_policy_snapshot);
    ClassDB::bind_method(D_METHOD("get_country_cell_tax_policy_snapshot", "cell_idx"),
                         &DCWorldExt::get_country_cell_tax_policy_snapshot);
    ClassDB::bind_method(D_METHOD("get_country_ui_snapshot", "handle", "section_mask"),
                         &DCWorldExt::get_country_ui_snapshot);
    ClassDB::bind_method(D_METHOD("poll_country_events", "after_event_id", "limit"),
                         &DCWorldExt::poll_country_events, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("reset_country", "reason"),
                         &DCWorldExt::reset_country);
    ClassDB::bind_method(D_METHOD("begin_country_save", "chunk_bytes"),
                         &DCWorldExt::begin_country_save, DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("begin_country_forensics_save", "chunk_bytes"),
                         &DCWorldExt::begin_country_forensics_save, DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("read_country_save_chunk", "max_bytes"),
                         &DCWorldExt::read_country_save_chunk, DEFVAL(4 * 1024 * 1024));
    ClassDB::bind_method(D_METHOD("end_country_save"),
                         &DCWorldExt::end_country_save);
    ClassDB::bind_method(D_METHOD("begin_country_restore"),
                         &DCWorldExt::begin_country_restore);
    ClassDB::bind_method(D_METHOD("feed_country_restore_chunk", "chunk"),
                         &DCWorldExt::feed_country_restore_chunk);
    ClassDB::bind_method(D_METHOD("end_country_restore"),
                         &DCWorldExt::end_country_restore);
}

} // namespace pk
