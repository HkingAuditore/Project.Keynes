#include "world_ext.h"
#include "runtime_economy_display.h"
#include "native_simulation_host.h"
#include "native_parallel_executor.h"
#include "runtime_domain_pod.h"
#include "runtime_day_tail.h"
#include "world_ext_golden.h"
#include "runtime_country_pod.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "modifier_api.h"
#include "runtime_protocol_guard.h"
#include "runtime_ideology_pod.h"
#include "runtime_economy_pod.h"
#include "economy_graph_kernels.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "metric_mask_tests.h"
#include "runtime_switch_registry.h"
#include "world_ext_simulation_host_internal.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace pk {

using namespace godot;


static String runtime_mode_name(RuntimeSimulationMode mode) {
    switch (mode) {
        case RuntimeSimulationMode::OFF: return "OFF";
        case RuntimeSimulationMode::SHADOW: return "SHADOW";
        case RuntimeSimulationMode::ACTIVE: return "ACTIVE";
    }
    return "OFF";
}

static bool parse_runtime_mode(const Dictionary &config,
                               RuntimeSimulationMode &mode,
                               String &error) {
    const StringName mode_key("simulation_thread_mode");
    const StringName alias_key("mode");
    Variant raw = config.has(mode_key) ? config[mode_key]
        : (config.has(alias_key) ? config[alias_key] : Variant("ACTIVE"));
    if (raw.get_type() == Variant::INT) {
        const int64_t value = static_cast<int64_t>(raw);
        if (value < static_cast<int64_t>(RuntimeSimulationMode::OFF) ||
            value > static_cast<int64_t>(RuntimeSimulationMode::ACTIVE)) {
            error = "runtime_thread_mode_invalid";
            return false;
        }
        mode = static_cast<RuntimeSimulationMode>(value);
        return true;
    }
    if (raw.get_type() != Variant::STRING) {
        error = "runtime_thread_mode_invalid";
        return false;
    }
    const String value = static_cast<String>(raw).to_upper();
    if (value == "OFF") mode = RuntimeSimulationMode::OFF;
    else if (value == "SHADOW") mode = RuntimeSimulationMode::SHADOW;
    else if (value == "ACTIVE") mode = RuntimeSimulationMode::ACTIVE;
    else {
        error = "runtime_thread_mode_invalid";
        return false;
    }
    return true;
}

// `host` is optional and only used for the two main-thread suppression masks: they
// are answered by `domain_main_thread_suppressed()` on the live host, not derivable
// from the report POD, and `thread_report` is the dictionary a caller reads when it
// wants to know whether the main thread may still run a domain.
#include "world_ext_simulation_host_section_load_catalogs.inc"

#include "world_ext_simulation_host_section_launch.inc"

// ===== native_daily_inline：单线程内联日 =====
//
// 调用线程执行同一份十二域计划，并在重试之间服务 Country peer。
// 不等待后台线程；主线程的同步写入口必须随已提交的归属一并更新。
#include "world_ext_simulation_host_section_inline_day.inc"

Dictionary DCWorldExt::record_runtime_visual_timings(
        double ui_input_to_feedback_ms,
        double visual_apply_ms,
        double gpu_upload_ms) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->record_visual_timings(ui_input_to_feedback_ms,
                                         visual_apply_ms,
                                         gpu_upload_ms);
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::set_runtime_clock(bool paused, double speed_days_per_second) {
    Dictionary out;
    if (!std::isfinite(speed_days_per_second) || speed_days_per_second < 0.0) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_clock_invalid";
        return out;
    }
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED ||
        _runtime_host->state() == RuntimeWorkerState::STOPPING ||
        _runtime_host->state() == RuntimeWorkerState::FAULTED) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_clock(paused, speed_days_per_second);
    out["ok"] = true;
    out["pending"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::set_runtime_qos_threaded(bool interactive) {
    Dictionary out;
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED ||
        _runtime_host->state() == RuntimeWorkerState::STOPPING ||
        _runtime_host->state() == RuntimeWorkerState::FAULTED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    // QoS is a release/acquire hint only. The facade never waits for the
    // coordinator or executor, so input handling remains independent of the
    // simulation worker even while a large day is being computed.
    _runtime_host->set_interactive(interactive);
    NativeParallelExecutor::instance().set_interactive(interactive);
    out["ok"] = true;
    out["pending"] = true;
    out["interactive"] = interactive;
    out["code"] = "ok";
    return out;
}

std::FILE *pk_sim_trace_file();

void DCWorldExt::sim_trace_main_write(const char *tag) {
    std::FILE *trace = pk_sim_trace_file();
    if (trace == nullptr || !_bound) return;
    auto hash_slot = [&](const char *name) -> unsigned long long {
        const int sid = component_id(StringName(name));
        if (sid < 0 || sid >= _slots.size()) return 0ull;
        const Slot &slot = _slots[sid];
        uint64_t hash = 1469598103934665603ull;
        const uint8_t *bytes = nullptr;
        size_t size = 0;
        if (slot.dtype == SlotDType::F32) {
            bytes = reinterpret_cast<const uint8_t *>(slot.arr_f32.ptr());
            size = static_cast<size_t>(slot.arr_f32.size()) * sizeof(float);
        } else if (slot.dtype == SlotDType::U8) {
            bytes = slot.arr_u8.ptr();
            size = static_cast<size_t>(slot.arr_u8.size());
        }
        for (size_t i = 0; i < size; ++i) hash = (hash ^ bytes[i]) * 1099511628211ull;
        return static_cast<unsigned long long>(hash ^ size);
    };
    const long long committed = _runtime_host != nullptr
        ? static_cast<long long>(_runtime_host->report().committed_day) : -1;
    std::fprintf(trace,
        "[main-write] fn=%s committed=%lld base=%llu soil=%llu moist=%llu temp=%llu "
        "wtype=%llu wint=%llu veg=%llu tta=%llu\n",
        tag, committed, hash_slot("cell_base_moisture"), hash_slot("cell_soil_moisture"),
        hash_slot("cell_moisture"), hash_slot("cell_temp"), hash_slot("cell_weather_type"),
        hash_slot("cell_weather_intensity"), hash_slot("cell_vegetation"),
        hash_slot("cell_temperature_transport_anomaly"));
    std::fflush(trace);
}



Dictionary DCWorldExt::submit_runtime_command(const Dictionary &command) {
    Dictionary out;
    out["admitted"] = false;
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (_runtime_host->state() == RuntimeWorkerState::FAULTED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "worker_faulted";
        return out;
    }
    if (_runtime_host->state() == RuntimeWorkerState::STOPPING) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_stopping";
        return out;
    }
    RuntimeCommandPacket packet;
    const auto read_i64 = [&command](const char *key, int64_t fallback,
                                     int64_t &value) -> bool {
        if (!command.has(key)) { value = fallback; return true; }
        const Variant raw = command[key];
        if (raw.get_type() != Variant::INT) return false;
        value = static_cast<int64_t>(raw);
        return true;
    };
    int64_t request_id = 0;
    int64_t producer_id = 0;
    int64_t sequence = 0;
    int64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t domain = 0;
    int64_t opcode = 0;
    if (!read_i64("request_id", 0, request_id) ||
        !read_i64("producer_id", 0, producer_id) ||
        !read_i64("sequence", 0, sequence) ||
        !read_i64("observed_generation", 0, observed_generation) ||
        !read_i64("requested_day", 0, requested_day) ||
        !read_i64("domain", 0, domain) ||
        !read_i64("opcode", 0, opcode) ||
        request_id <= 0 || producer_id < 0 || sequence < 0 ||
        observed_generation < 0 || requested_day < 0 ||
        domain < 0 || domain > 65535 || opcode < 0 || opcode > 65535) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "invalid_command_value";
        return out;
    }
    packet.envelope.request_id = static_cast<uint64_t>(request_id);
    packet.envelope.producer_id = static_cast<uint32_t>(producer_id);
    packet.envelope.sequence = static_cast<uint64_t>(sequence);
    if (packet.envelope.sequence == 0) {
        packet.envelope.sequence = _runtime_host->allocate_producer_sequence(
            packet.envelope.producer_id);
    }
    packet.envelope.observed_generation = static_cast<uint64_t>(observed_generation);
    packet.envelope.requested_day = requested_day;
    packet.envelope.domain = static_cast<uint16_t>(domain);
    packet.envelope.opcode = static_cast<uint16_t>(opcode);
    packet.envelope.effective_day = packet.envelope.requested_day;
    PackedByteArray payload;
    if (command.has("payload")) {
        const Variant payload_value = command["payload"];
        if (payload_value.get_type() != Variant::PACKED_BYTE_ARRAY) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "invalid_command_payload";
            return out;
        }
        payload = payload_value;
    }
    if (payload.size() > RUNTIME_MAX_COMMAND_PAYLOAD) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "invalid_command_payload";
        return out;
    }
    packet.envelope.payload_offset = 0;
    packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    if (!payload.is_empty()) std::memcpy(packet.payload.data(), payload.ptr(), payload.size());
    std::vector<int64_t> admitted_days;
    if (!_runtime_host->enqueue_batch({packet}, &admitted_days)) {
        out["ok"] = false;
        out["pending"] = false;
        const RuntimeWorkerState state = _runtime_host->state();
        out["code"] = state == RuntimeWorkerState::FAULTED
            ? "worker_faulted" : "command_queue_capacity_exceeded";
        out["request_id"] = static_cast<int64_t>(packet.envelope.request_id);
        return out;
    }
    out["ok"] = true;
    out["admitted"] = true;
    out["pending"] = true;
    out["request_id"] = static_cast<int64_t>(packet.envelope.request_id);
    out["producer_id"] = static_cast<int>(packet.envelope.producer_id);
    out["sequence"] = static_cast<int64_t>(packet.envelope.sequence);
    out["effective_day"] = admitted_days.front();
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::poll_runtime_receipts(int max_items) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    Array receipts;
    const int limit = std::clamp(max_items, 0, 8192);
    for (int i = 0; i < limit; ++i) {
        RuntimeCommandReceipt receipt;
        if (!_runtime_host->poll_receipt(receipt)) break;
        Dictionary item;
        item["request_id"] = static_cast<int64_t>(receipt.request_id);
        item["producer_id"] = static_cast<int>(receipt.producer_id);
        item["sequence"] = static_cast<int64_t>(receipt.sequence);
        item["effective_day"] = receipt.effective_day;
        item["generation"] = static_cast<int64_t>(receipt.generation);
        item["code"] = static_cast<int>(receipt.code);
        receipts.push_back(item);
    }
    out["ok"] = true;
    out["receipts"] = receipts;
    out["count"] = receipts.size();
    return out;
}

Dictionary DCWorldExt::poll_runtime_commit(int64_t after_generation, bool take_days) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeCommit commit;
    const uint64_t after = static_cast<uint64_t>(std::max<int64_t>(0, after_generation));
    const auto publication = take_days ? _runtime_host->take_day_publications(after) : nullptr;
    if (publication) {
        _runtime_display_commit.header = publication->commit->header;
        _runtime_display_commit.day_tail = publication->commit->day_tail;
        // Keep one immutable publication for the map. An executor restart
        // can lower the generation or republish the current day in this world.
        if (!_runtime_map_display_commit || publication->commit->header.committed_day >
                _runtime_map_display_commit->header.committed_day)
            _runtime_map_display_commit = publication->commit;
        if (!publication->resources.cells.empty())
            _runtime_display_resources = std::shared_ptr<const RuntimeResourceDisplayPatch>(
                publication, &publication->resources);
        commit.header = publication->commit->header;
        commit.day_tail = publication->commit->day_tail;
    }
    if (take_days) {
        bool quotes_ready;
        const Array results = _runtime_host->take_boundary_command_results(quotes_ready);
        if (!results.is_empty()) out["boundary_results"] = results;
        if (quotes_ready) out["colonization_quotes_ready"] = true;
    }
    if (!publication && (take_days || !_runtime_host->poll_commit(after, commit))) {
        out["ok"] = true;
        out["pending"] = true;
        out["available"] = false;
        return out;
    }
    const RuntimeCommitHeader &h = commit.header;
    out["ok"] = true;
    out["pending"] = false;
    out["available"] = true;
    out["generation"] = static_cast<int64_t>(h.generation);
    out["from_day"] = h.from_day;
    out["committed_day"] = h.committed_day;
    out["produced_at_us"] = static_cast<int64_t>(h.produced_at_us);
    out["dirty_families"] = static_cast<int64_t>(h.dirty_families);
    out["state_hash"] = static_cast<int64_t>(h.state_hash);
    out["command_receipt_count"] = static_cast<int>(h.command_receipt_count);
    if (commit.day_tail) {
        out["resource_recovery_cells"] = commit.day_tail->resource_recovery_cells;
        out["species_writeback"] = !commit.day_tail->occupancy.empty();
        out["species_diffused_cells"] = commit.day_tail->species_diffused_cells;
        out["species_introductions_consumed"] = commit.day_tail->species_introductions_consumed;
        out["military_trail_cells"] = commit.day_tail->military_trail_cells;
        out["vision_writeback"] = bool(commit.day_tail->vision);
        out["vision_solved"] = commit.day_tail->vision_solved;
        out["vision_observations"] = commit.day_tail->vision_observations;
        out["species_observations"] = commit.day_tail->species_observations;
    }
    PackedInt64Array dirty_family_generations;
    dirty_family_generations.resize(RUNTIME_DIRTY_FAMILY_COUNT);
    for (size_t i = 0; i < RUNTIME_DIRTY_FAMILY_COUNT; ++i) {
        dirty_family_generations[static_cast<int>(i)] =
            static_cast<int64_t>(h.dirty_family_generations[i]);
    }
    out["dirty_family_generations"] = dirty_family_generations;
    out["receipts"] = publication ? publication->receipts : pack_runtime_receipts(commit.receipts);
    if (publication) {
        out["display_dirty_cells"] = publication->changed_cells;
        out["display_class_cells"] = publication->changed_classes;
        if (commit.day_tail && !commit.day_tail->cell_luts.transition_age.empty())
            out["map_lut_pending"] = true;
        out["days"] = publication->records;
        out["notice_history"] = publication->notices;
        if (!publication->construction_receipts.is_empty())
            out["construction_receipts"] = publication->construction_receipts;
        if (!publication->colonization_receipts.is_empty())
            out["colonization_receipts"] = publication->colonization_receipts;
        if (!publication->gdp.is_empty()) out["gdp"] = publication->gdp;
        if (!publication->fiscal_history.is_empty()) out["fiscal_history"] = publication->fiscal_history;
    }
    return out;
}

void DCWorldExt::finish_runtime_display_frame() {
    _runtime_display_commit = {};
}

Dictionary DCWorldExt::read_runtime_map_lut_frame(Object *map, int64_t day, int64_t generation,
                                                  int cell_count, bool measure_copy) const {
    const auto fail = [](const char *reason) {
        Dictionary failure;
        failure["reason"] = reason;
        return failure;
    };
    const auto &commit = _runtime_map_display_commit;
    if (!commit || !commit->day_tail) return fail("map_lut_publication_unavailable");
    if (!map || map != _map_data) return fail("map_lut_map_mismatch");
    if (day != commit->header.committed_day) return fail("map_lut_day_mismatch");
    if (generation <= 0 || static_cast<uint64_t>(generation) != commit->header.generation)
        return fail("map_lut_generation_mismatch");
    if (cell_count <= 0 || cell_count != _native_world_cell_count)
        return fail("map_lut_cell_count_mismatch");

    const auto &model = commit->day_tail->cell_luts;
    const auto count = static_cast<size_t>(cell_count);
    if (model.transition_age.size() != count || model.previous_vitality.size() != count)
        return fail("map_lut_column_size_mismatch");

    Dictionary frame;
    using Clock = std::chrono::steady_clock;
    const auto started = measure_copy ? Clock::now() : Clock::time_point{};
    PackedByteArray ages, vitalities;
    if (ages.resize(cell_count) != OK || vitalities.resize(cell_count) != OK)
        return fail("map_lut_allocation_failed");
    std::memcpy(ages.ptrw(), model.transition_age.data(), count);
    std::memcpy(vitalities.ptrw(), model.previous_vitality.data(), count);
    if (measure_copy)
        frame["copy_ns"] = static_cast<int64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started).count());
    frame["transition_age"] = ages;
    frame["previous_vitality"] = vitalities;
    return frame;
}

void DCWorldExt::clear_runtime_map_lut_frame() {
    _runtime_map_display_commit.reset();
}

Dictionary DCWorldExt::request_runtime_stop(bool preserve_day_boundary) {
    Dictionary out;
    const RuntimeWorkerState before = _runtime_host
        ? _runtime_host->state() : RuntimeWorkerState::STOPPED;
    if (_runtime_host && preserve_day_boundary && !_runtime_host->try_stop_at_day_boundary()) {
        out["ok"] = false;
        out["pending"] = true;
        out["code"] = "runtime_stop_waiting_for_day_boundary";
        out["state"] = runtime_state_name(before);
        return out;
    }
    _climate_physics_committed.reset();
    _climate_physics_capture_ready = false;
    _climate_writeback_applied_generation = 0;
    _climate_writeback_applied_day = -1;
    if (!_runtime_host) {
        out["ok"] = true;
        out["pending"] = false;
        out["state"] = "STOPPED";
        return out;
    }
    // Stop is asynchronous: the worker may still be executing an Economy
    // stage or its command executor. Keep both attached until it has exited;
    // DCWorldExt joins the host before destroying the owned runtimes.
    if (!preserve_day_boundary) _runtime_host->request_stop();
    out["ok"] = true;
    const RuntimeWorkerState state = _runtime_host->state();
    // The request itself is asynchronous even if the worker exits during this
    // call.  Callers use pending to schedule a later lifecycle poll, while the
    // state field is allowed to already be STOPPED.
    out["pending"] = before != RuntimeWorkerState::STOPPED ||
        !_runtime_host->execution_has_stopped();
    out["state"] = runtime_state_name(state);
    return out;
}















Dictionary DCWorldExt::switch_economy_authority(const String &mode) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeEconomyAuthorityMode parsed =
        RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    const CharString utf8 = mode.utf8();
    const char *text = utf8.get_data();
    if (text == nullptr || text[0] == '\0' ||
        std::strcmp(text, "LEGACY_SYNC") == 0) {
        parsed = RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    } else if (std::strcmp(text, "POD_ACTIVE_WITH_LEGACY_PARITY") == 0) {
        parsed = RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY;
    } else if (std::strcmp(text, "POD_ACTIVE") == 0) {
        parsed = RuntimeEconomyAuthorityMode::POD_ACTIVE;
    } else {
        out["ok"] = false;
        out["code"] = "economy_authority_mode_invalid";
        return out;
    }
    std::string error;
    const bool ok = _runtime_host->switch_economy_authority(parsed, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    out["economy_worker_is_authoritative"] =
        _runtime_host->economy_worker_is_authoritative();
    out["economy_legacy_fallback_enabled"] =
        _runtime_host->economy_legacy_fallback_enabled();
    out["authority_mode"] = static_cast<int>(
        _runtime_host->economy_authority_mode());
    const RuntimeThreadReport audit = _runtime_host->report();
    out["economy_authority_switch_count"] = static_cast<int64_t>(
        audit.economy_authority_switch_count);
    out["economy_authority_switch_audit_sequence"] = static_cast<int64_t>(
        audit.economy_authority_switch_audit_sequence);
    out["economy_authority_switch_before_hash"] = static_cast<int64_t>(
        audit.economy_authority_switch_before_hash);
    out["economy_authority_switch_after_hash"] = static_cast<int64_t>(
        audit.economy_authority_switch_after_hash);
    out["economy_authority_switch_before_generation"] = static_cast<int64_t>(
        audit.economy_authority_switch_before_generation);
    out["economy_authority_switch_after_generation"] = static_cast<int64_t>(
        audit.economy_authority_switch_after_generation);
    out["economy_authority_switch_latency_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_us);
    out["economy_authority_switch_latency_p95_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_p95_us);
    out["economy_authority_switch_latency_max_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_max_us);
    out["economy_authority_switch_command_latency_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_command_latency_us);
    out["economy_authority_switch_command_latency_p95_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_command_latency_p95_us);
    out["economy_authority_switch_command_latency_max_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_command_latency_max_us);
    out["economy_authority_switch_latency_sample_count"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_sample_count);
    out["economy_authority_switch_rejected"] = static_cast<int64_t>(
        audit.economy_authority_switch_rejected);
    out["economy_authority_switch_reason"] = String(
        audit.economy_authority_switch_reason);
    out["economy_authority_switch_blocker"] = String(
        audit.economy_authority_switch_blocker);
    out["economy_authority_switch_audit_before"] = String(
        audit.economy_authority_switch_audit_before);
    out["economy_authority_switch_audit_after"] = String(
        audit.economy_authority_switch_audit_after);
    out["economy_authority_switch_audit_hash"] = static_cast<int64_t>(
        audit.economy_authority_switch_audit_hash);
    // Compact aliases matching the M6 switch evidence contract.
    out["before_hash"] = out["economy_authority_switch_before_hash"];
    out["after_hash"] = out["economy_authority_switch_after_hash"];
    out["audit_hash"] = out["economy_authority_switch_audit_hash"];
    out["generation"] = out["economy_authority_switch_after_generation"];
    out["latency_us"] = out["economy_authority_switch_latency_us"];
    return out;
}

} // namespace pk
