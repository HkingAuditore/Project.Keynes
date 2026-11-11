#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_runtime_methods() {
    ClassDB::bind_method(D_METHOD("begin_loading_task", "operation", "input"), &DCWorldExt::begin_loading_task);
    ClassDB::bind_method(D_METHOD("poll_loading_task", "handle"), &DCWorldExt::poll_loading_task);
    ClassDB::bind_method(D_METHOD("take_loading_task", "handle"), &DCWorldExt::take_loading_task);
    ClassDB::bind_method(D_METHOD("cancel_loading_task", "handle"), &DCWorldExt::cancel_loading_task);
    ClassDB::bind_method(D_METHOD("cancel_all_loading_tasks"), &DCWorldExt::cancel_all_loading_tasks);
    ClassDB::bind_method(D_METHOD("encode_bake_height_flow_tex_data", "input"), &DCWorldExt::encode_bake_height_flow_tex_data);
    ClassDB::bind_method(D_METHOD("run_native_daily_tick", "tick_knobs"),
                         &DCWorldExt::run_native_daily_tick);
    ClassDB::bind_method(D_METHOD("run_native_daily_slice", "tick_knobs"),
                         &DCWorldExt::run_native_daily_slice);
    // native_daily_inline：调用线程上同步跑完一天的 12 域日屏障（Web 用）。
    ClassDB::bind_method(D_METHOD("run_native_daily_inline_day"),
                         &DCWorldExt::run_native_daily_inline_day);
    ClassDB::bind_method(D_METHOD("configure_runtime_graph", "boot_config"),
                         &DCWorldExt::configure_runtime_graph);
    ClassDB::bind_method(D_METHOD("advance_runtime_pulse", "day", "season_phase",
                                  "speed_scale", "budget_us", "flags"),
                         &DCWorldExt::advance_runtime_pulse, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("flush_runtime_visuals", "dirty_mask"),
                         &DCWorldExt::flush_runtime_visuals, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("set_runtime_qos", "interactive"),
                         &DCWorldExt::set_runtime_qos);
    ClassDB::bind_method(D_METHOD("get_runtime_thread_report"),
                         &DCWorldExt::get_runtime_thread_report);
    ClassDB::bind_method(D_METHOD("get_runtime_control_state"),
                         &DCWorldExt::get_runtime_control_state);
    ClassDB::bind_method(D_METHOD("record_runtime_visual_timings",
                                  "ui_input_to_feedback_ms", "visual_apply_ms",
                                  "gpu_upload_ms"),
                         &DCWorldExt::record_runtime_visual_timings);
    ClassDB::bind_method(D_METHOD("get_runtime_perf_snapshot", "detail_level"),
                         &DCWorldExt::get_runtime_perf_snapshot, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("get_runtime_graph_last_economy_report"),
                         &DCWorldExt::get_runtime_graph_last_economy_report);
    ClassDB::bind_method(D_METHOD("start_runtime_worker", "config"),
                         &DCWorldExt::start_runtime_worker);
    ClassDB::bind_method(D_METHOD("set_runtime_clock", "paused", "speed_days_per_second"),
                         &DCWorldExt::set_runtime_clock);
    ClassDB::bind_method(D_METHOD("set_runtime_qos_threaded", "interactive"),
                         &DCWorldExt::set_runtime_qos_threaded);
     ClassDB::bind_method(D_METHOD("capture_runtime_inputs", "inputs"),
                          &DCWorldExt::capture_runtime_inputs);
     ClassDB::bind_method(D_METHOD("compute_runtime_climate_parity_hash", "fields"),
                          &DCWorldExt::compute_runtime_climate_parity_hash);
     ClassDB::bind_method(D_METHOD("publish_runtime_climate_reference_state", "day", "fields"),
                          &DCWorldExt::publish_runtime_climate_reference_state);
     ClassDB::bind_method(D_METHOD("get_runtime_climate_parity_fields"),
                          &DCWorldExt::get_runtime_climate_parity_fields);
     ClassDB::bind_method(D_METHOD("get_runtime_climate_parity_divergence"),
                          &DCWorldExt::get_runtime_climate_parity_divergence);
     ClassDB::bind_method(D_METHOD("set_runtime_climate_parity_forcing", "enabled"),
                          &DCWorldExt::set_runtime_climate_parity_forcing);
    ClassDB::bind_method(D_METHOD("set_runtime_ideology_parity_enabled", "enabled"),
                         &DCWorldExt::set_runtime_ideology_parity_enabled);
    ClassDB::bind_method(D_METHOD("submit_runtime_command", "command"),
                         &DCWorldExt::submit_runtime_command);
    ClassDB::bind_method(D_METHOD("poll_runtime_receipts", "max_items"),
                         &DCWorldExt::poll_runtime_receipts, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("poll_runtime_commit", "after_generation"),
                         &DCWorldExt::poll_runtime_commit, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("consume_runtime_visual_patch", "generation", "family", "cursor", "max_items"),
                         &DCWorldExt::consume_runtime_visual_patch, DEFVAL(0), DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("profile_runtime_save_window", "active"), &DCWorldExt::profile_runtime_save_window);
    ClassDB::bind_method(D_METHOD("request_runtime_save", "request_id"),
                         &DCWorldExt::request_runtime_save);
    ClassDB::bind_method(D_METHOD("poll_runtime_save", "request_id"),
                         &DCWorldExt::poll_runtime_save);
    ClassDB::bind_method(D_METHOD("restore_runtime_bundle", "bytes", "external_ecp2"),
                         &DCWorldExt::restore_runtime_bundle, DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("request_runtime_stop"),
                         &DCWorldExt::request_runtime_stop);
    ClassDB::bind_method(D_METHOD("climate_worker_authoritative"),
                         &DCWorldExt::climate_worker_authoritative);
    ClassDB::bind_method(D_METHOD("climate_main_thread_suppressed"),
                         &DCWorldExt::climate_main_thread_suppressed);
    ClassDB::bind_method(D_METHOD("climate_physics_authoritative"),
                         &DCWorldExt::climate_physics_authoritative);
    ClassDB::bind_method(D_METHOD("get_climate_physics_read_view"),
                         &DCWorldExt::get_climate_physics_read_view);
    ClassDB::bind_method(
        D_METHOD("apply_runtime_climate_writeback", "after_generation"),
        &DCWorldExt::apply_runtime_climate_writeback);
    ClassDB::bind_method(
        D_METHOD("wait_climate_consumed", "after_environment_generation",
                 "timeout_ms"),
        &DCWorldExt::wait_climate_consumed, DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("runtime_climate_writeback_self_test"),
                         &DCWorldExt::runtime_climate_writeback_self_test);
    // P1：环境帧预发布器（主线程 _process 里发 N+1..N+K）需要的两个只读探测。
    ClassDB::bind_method(D_METHOD("environment_ring_has_capacity"),
                         &DCWorldExt::environment_ring_has_capacity);
    ClassDB::bind_method(D_METHOD("runtime_committed_day"),
                         &DCWorldExt::runtime_committed_day);
    ClassDB::bind_method(D_METHOD("runtime_snapshot_ring_self_test"),
                         &DCWorldExt::runtime_snapshot_ring_self_test);
    ClassDB::bind_method(D_METHOD("runtime_domain_pod_self_test"),
                         &DCWorldExt::runtime_domain_pod_self_test);
    ClassDB::bind_method(D_METHOD("runtime_authoritative_domains_self_test"),
                         &DCWorldExt::runtime_authoritative_domains_self_test);
    ClassDB::bind_method(D_METHOD("runtime_climate_authority_self_test"),
                         &DCWorldExt::runtime_climate_authority_self_test);
    ClassDB::bind_method(D_METHOD("runtime_climate_trace_self_test"),
                         &DCWorldExt::runtime_climate_trace_self_test);
    ClassDB::bind_method(D_METHOD("runtime_climate_parity_contract_test"),
                         &DCWorldExt::runtime_climate_parity_contract_test);
    ClassDB::bind_method(D_METHOD("runtime_climate_stage_order_contract_test"),
                         &DCWorldExt::runtime_climate_stage_order_contract_test);
    ClassDB::bind_method(D_METHOD("runtime_country_pod_authority_self_test"),
                         &DCWorldExt::runtime_country_pod_authority_self_test);
    ClassDB::bind_method(D_METHOD("runtime_protocol_guard_self_test"),
                         &DCWorldExt::runtime_protocol_guard_self_test);
    ClassDB::bind_method(D_METHOD("runtime_trigger_pod_self_test"),
                         &DCWorldExt::runtime_trigger_pod_self_test);
    ClassDB::bind_method(D_METHOD("runtime_effect_pod_self_test"),
                         &DCWorldExt::runtime_effect_pod_self_test);
    ClassDB::bind_method(D_METHOD("runtime_effect_host_stage_self_test"),
                         &DCWorldExt::runtime_effect_host_stage_self_test);
    ClassDB::bind_method(D_METHOD("runtime_effect_adapter_parity_self_test"),
                         &DCWorldExt::runtime_effect_adapter_parity_self_test);
    ClassDB::bind_method(D_METHOD("runtime_ideology_pod_self_test"),
                         &DCWorldExt::runtime_ideology_pod_self_test);
    ClassDB::bind_method(D_METHOD("runtime_events_authority_self_test"),
                         &DCWorldExt::runtime_events_authority_self_test);
    ClassDB::bind_method(D_METHOD("runtime_economy_pod_self_test"),
                         &DCWorldExt::runtime_economy_pod_self_test);
    ClassDB::bind_method(D_METHOD("switch_economy_authority", "mode"),
                         &DCWorldExt::switch_economy_authority);
    ClassDB::bind_method(D_METHOD("runtime_economy_authority_fault_gate_self_test"),
                         &DCWorldExt::runtime_economy_authority_fault_gate_self_test);
    ClassDB::bind_method(D_METHOD("runtime_economy_target_selector_self_test"),
                         &DCWorldExt::runtime_economy_target_selector_self_test);
    ClassDB::bind_method(D_METHOD("runtime_metric_mask_self_test"),
                         &DCWorldExt::runtime_metric_mask_self_test);
    ClassDB::bind_method(D_METHOD("arm_runtime_fault_injection", "point"),
                         &DCWorldExt::arm_runtime_fault_injection);
    ClassDB::bind_method(D_METHOD("clear_runtime_fault_injection"),
                         &DCWorldExt::clear_runtime_fault_injection);
    ClassDB::bind_method(D_METHOD("runtime_economy_stage_order_contract_test"),
                         &DCWorldExt::runtime_economy_stage_order_contract_test);
    ClassDB::bind_method(D_METHOD("run_native_daily_finalizer", "knobs"),
                         &DCWorldExt::run_native_daily_finalizer);
    ClassDB::bind_method(D_METHOD("run_native_sim_tick", "ctx"),
                         &DCWorldExt::run_native_sim_tick);
    ClassDB::bind_method(D_METHOD("get_native_daily_report"),
                         &DCWorldExt::get_native_daily_report);
    ClassDB::bind_method(D_METHOD("get_native_shadow_diff_report"),
                         &DCWorldExt::get_native_shadow_diff_report);
    ClassDB::bind_method(D_METHOD("native_ocean_physical_begin", "ctx"),
                         &DCWorldExt::native_ocean_physical_begin);
    ClassDB::bind_method(D_METHOD("native_ocean_physical_step", "ctx"),
                         &DCWorldExt::native_ocean_physical_step);
    ClassDB::bind_method(D_METHOD("native_ocean_physical_finish", "ctx"),
                         &DCWorldExt::native_ocean_physical_finish);
    ClassDB::bind_method(D_METHOD("reset_native_ocean_physical_state", "reason"),
                         &DCWorldExt::reset_native_ocean_physical_state);
    ClassDB::bind_method(D_METHOD("get_native_ocean_physical_state_report"),
                         &DCWorldExt::get_native_ocean_physical_state_report);
    ClassDB::bind_method(D_METHOD("get_native_ocean_physical_hot_state"),
                         &DCWorldExt::get_native_ocean_physical_hot_state);
    ClassDB::bind_method(D_METHOD("run_boot_facade_pass", "knobs"),
                         &DCWorldExt::run_boot_facade_pass);
    ClassDB::bind_method(D_METHOD("get_native_dirty_report"),
                         &DCWorldExt::get_native_dirty_report);
}

} // namespace pk
