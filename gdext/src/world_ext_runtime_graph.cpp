#include "world_ext.h"

#include "country_runtime.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"
#include "trigger_runtime.h"

#include <algorithm>
#include <chrono>

namespace pk {

using namespace godot;

namespace {
using Clock = std::chrono::steady_clock;

static uint32_t elapsed_us(Clock::time_point start) {
    const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - start).count();
    return static_cast<uint32_t>(std::clamp<int64_t>(us, 0, 0xffffffffll));
}

static int64_t make_token(int64_t day, uint32_t status, uint32_t dirty,
                          uint32_t flags) {
    // [63:48] status/flags, [47:32] dirty mask, [31:0] committed day.
    const uint64_t hi = (static_cast<uint64_t>(status & 0xffu) << 56) |
        (static_cast<uint64_t>(flags & 0xffu) << 48) |
        (static_cast<uint64_t>(dirty & 0xffffu) << 32);
    return static_cast<int64_t>(hi | (static_cast<uint64_t>(day) & 0xffffffffull));
}
} // namespace

int DCWorldExt::configure_runtime_graph(const Dictionary &boot_config) {
    _runtime_graph_configured = false;
    _runtime_graph_enabled = bool(boot_config.get("enabled", false));
    _runtime_graph_day = int64_t(boot_config.get("day", -1));
    _runtime_graph_generation = uint64_t(boot_config.get("generation", 0));
    _runtime_graph_dirty_mask = 0;
    _runtime_graph_next_cursor = 0;
    _runtime_graph_pulse_count = 0;
    _runtime_graph_abi_calls = 0;
    _runtime_graph_callback_count = 0;
    _runtime_graph_work_done = 0;
    _runtime_graph_budget_yields = 0;
    _runtime_graph_economy_slices = 0;
    _runtime_graph_economy_commits = 0;
    _runtime_graph_last_elapsed_us = 0;
    _runtime_graph_last_status = 0;
    _runtime_graph_configured = true;
    return 0;
}

int64_t DCWorldExt::advance_runtime_pulse(int64_t day, double season_phase,
                                          double speed_scale, int budget_us,
                                          int flags) {
    const auto started = Clock::now();
    ++_runtime_graph_abi_calls;
    if (!_runtime_graph_configured || !_runtime_graph_enabled) {
        _runtime_graph_last_status = 0;
        _runtime_graph_last_elapsed_us = elapsed_us(started);
        return make_token(day, 0, _runtime_graph_dirty_mask,
                          static_cast<uint32_t>(flags));
    }

    _runtime_graph_day = day;
    const int limit_us = std::max(250, budget_us);
    uint32_t status = 1; // progressed
    uint32_t work = 0;
    uint32_t dirty = 0;
    int iterations = 0;

    auto over_budget = [&]() {
        return static_cast<int>(elapsed_us(started)) >= limit_us;
    };
    auto ctx_for = [&]() {
        Dictionary ctx;
        ctx["day_index"] = day;
        ctx["tick_index"] = static_cast<int64_t>(_runtime_graph_pulse_count);
        ctx["season_phase"] = season_phase;
        ctx["speed_scale"] = speed_scale;
        ctx["slice_budget_ms"] = static_cast<double>(limit_us) / 1000.0;
        ctx["source"] = StringName("native_runtime_graph");
        return ctx;
    };
    auto ran = [&](const Dictionary &result) {
        ++work;
        const int64_t changed = static_cast<int64_t>(result.get("changed_cells", 0));
        if (changed > 0 || bool(result.get("published_to_slot", false))) dirty |= 1u;
        if (bool(result.get("done", false))) status = 2;
    };

    auto ingest_trigger_events = [&]() {
        if (_trigger_runtime == nullptr) return uint32_t{0};
        TriggerRuntime *trigger = static_cast<TriggerRuntime *>(_trigger_runtime);
        const StringName consumer("trigger_runtime");
        const int64_t *stored_cursor = _gameplay_consumer_ack.getptr(consumer);
        int64_t cursor = stored_cursor != nullptr ? *stored_cursor : int64_t{0};
        uint32_t ingested = 0;
        for (const GameplayEventRecord &event : _gameplay_events) {
            if (event.event_id <= cursor) continue;
            TriggerRuntime::EventInput input;
            input.source_id = event.source;
            input.event_id = event.event_id;
            input.day = day;
            input.event_type = event.type;
            input.payload_schema = event.payload_schema;
            input.entity_handle = event.entity_handle != 0
                ? event.entity_handle : static_cast<uint64_t>(std::max(0, event.entity_id));
            input.group_handle = static_cast<uint64_t>(std::max(0, event.cell_idx));
            input.value = event.value_i64;
            input.payload = {event.payload_i0, event.payload_i1,
                             event.payload_i2, event.payload_i3};
            size_t accepted = 0;
            int64_t last_accepted = 0;
            std::string error;
            if (!trigger->submit_events_pod(&input, 1, accepted,
                                            last_accepted, error) || accepted != 1) {
                break;
            }
            cursor = last_accepted;
            ++ingested;
            if (ingested >= 512) break;
        }
        if (ingested > 0) _gameplay_consumer_ack[consumer] = cursor;
        return ingested;
    };

    // Stable order mirrors the existing GDScript ACK chain and scheduler
    // priorities. Each runtime owns its own persistent range cursor.
    while (iterations++ < 64 && !over_budget()) {
        bool progressed = false;
        Dictionary ctx = ctx_for();
        if (_country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_country();
            ran(run_country_slice(ctx));
            if (_effect_runtime != nullptr) ack_effect_native_country();
            progressed = true;
        }
        if (over_budget()) break;
        const uint32_t ingested_events = ingest_trigger_events();
        if (ingested_events > 0) {
            work += ingested_events;
            progressed = true;
        }
        if (_trigger_runtime != nullptr &&
            static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day)) {
            ran(run_trigger_daily(day));
            if (_effect_runtime != nullptr) handoff_trigger_effects(512);
            progressed = true;
        }
        if (over_budget()) break;
        if (_ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day)) {
            ran(run_ideology_daily(day));
            progressed = true;
        }
        if (over_budget()) break;
        if (_effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) {
            ran(run_effect_daily(day));
            // A native effect transaction can be waiting for an ACK even when
            // the peer runtime has no independent daily work.  ACK every
            // adapter after effect evaluation so the transaction can reach a
            // terminal state instead of keeping effect_should_run() hot.
            if (_effect_runtime != nullptr) {
                dispatch_effect_native_country();
                dispatch_effect_native_economy();
                dispatch_effect_native_modifier();
                dispatch_effect_native_gameplay();
                ack_effect_native_country();
                ack_effect_native_economy();
                ack_effect_native_modifier();
                ack_effect_native_gameplay();
            }
            progressed = true;
        }
        if (over_budget()) break;
        if (_modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_modifier();
            ran(run_modifier_daily(day));
            if (_effect_runtime != nullptr) ack_effect_native_modifier();
            progressed = true;
        }
        if (over_budget()) break;
        if (_effect_runtime != nullptr && gameplay_effect_should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_gameplay();
            ran(run_gameplay_effects(day));
            if (_effect_runtime != nullptr) ack_effect_native_gameplay();
            progressed = true;
        }
        // Economy is the terminal hard-domain in this deterministic chain. A
        // busy Effect/ACK queue may consume the pulse budget, but it must not
        // starve an overdue economy range forever. Let one native economy
        // slice start after the ordered ACK dispatch; the slice itself owns
        // its cursor and the next loop/pulse will resume from that boundary.
        if (_economy_runtime != nullptr && economy_should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_economy();
            Dictionary economy_result = run_economy_slice_compact(ctx);
            ++_runtime_graph_economy_slices;
            if (bool(economy_result.get("done", false)))
                ++_runtime_graph_economy_commits;
            ran(economy_result);
            if (_effect_runtime != nullptr) ack_effect_native_economy();
            _runtime_graph_last_economy_report = economy_result;
            progressed = true;
        }
        if (!progressed) {
            status = 2;
            break;
        }
    }
    if (over_budget()) {
        ++_runtime_graph_budget_yields;
        status = 3;
    }
    // A runtime may still own a persistent cursor even when this pulse did not
    // hit the wall-clock budget (for example a range cap stopped the loop).
    // Keep the committed-day barrier armed until every hard domain reports idle.
    const bool pending =
        (_country_runtime != nullptr &&
         static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) ||
        (_effect_runtime != nullptr &&
         static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) ||
        (_modifier_runtime != nullptr &&
         static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) ||
        (_effect_runtime != nullptr && gameplay_effect_should_run(day)) ||
        (_economy_runtime != nullptr && economy_should_run(day));
    if (pending) status = 3;
    _runtime_graph_dirty_mask |= dirty;
    _runtime_graph_next_cursor += work;
    _runtime_graph_work_done += work;
    ++_runtime_graph_pulse_count;
    _runtime_graph_last_status = status;
    _runtime_graph_last_elapsed_us = elapsed_us(started);
    return make_token(day, status, _runtime_graph_dirty_mask,
                      static_cast<uint32_t>(flags));
}

Dictionary DCWorldExt::get_runtime_graph_last_economy_report() const {
    return _runtime_graph_last_economy_report;
}

void DCWorldExt::flush_runtime_visuals(uint32_t dirty_mask) {
    const uint32_t pending = _runtime_graph_dirty_mask & (dirty_mask | 0xffffffffu);
    if (pending != 0) flush_slots_to_map();
    _runtime_graph_dirty_mask = 0;
    ++_runtime_graph_generation;
}

Dictionary DCWorldExt::get_runtime_perf_snapshot(int detail_level) const {
    Dictionary out;
    out["configured"] = _runtime_graph_configured;
    out["enabled"] = _runtime_graph_enabled;
    out["day"] = _runtime_graph_day;
    out["generation"] = static_cast<int64_t>(_runtime_graph_generation);
    out["pulse_count"] = static_cast<int64_t>(_runtime_graph_pulse_count);
    out["abi_calls"] = static_cast<int64_t>(_runtime_graph_abi_calls);
    out["gdscript_callbacks"] = static_cast<int64_t>(_runtime_graph_callback_count);
    out["work_done"] = static_cast<int64_t>(_runtime_graph_work_done);
    out["budget_yields"] = static_cast<int64_t>(_runtime_graph_budget_yields);
    out["economy_slices"] = static_cast<int64_t>(_runtime_graph_economy_slices);
    out["economy_commits"] = static_cast<int64_t>(_runtime_graph_economy_commits);
    out["last_elapsed_us"] = static_cast<int64_t>(_runtime_graph_last_elapsed_us);
    out["last_status"] = static_cast<int64_t>(_runtime_graph_last_status);
    out["dirty_mask"] = static_cast<int64_t>(_runtime_graph_dirty_mask);
    if (detail_level > 0) {
        out["next_cursor"] = static_cast<int64_t>(_runtime_graph_next_cursor);
        out["authority"] = String("existing_native_runtimes");
        out["callbacks_in_graph"] = static_cast<int64_t>(_runtime_graph_callback_count);
        const int64_t day = _runtime_graph_day;
        out["country_pending"] = _country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day);
        out["trigger_pending"] = _trigger_runtime != nullptr &&
            static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day);
        out["ideology_pending"] = _ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day);
        out["effect_pending"] = _effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day);
        out["modifier_pending"] = _modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day);
        out["gameplay_effect_pending"] = _effect_runtime != nullptr &&
            gameplay_effect_should_run(day);
        out["economy_pending"] = _economy_runtime != nullptr &&
            economy_should_run(day);
        out["gameplay_event_count"] = static_cast<int64_t>(_gameplay_events.size());
        const int64_t *trigger_ack = _gameplay_consumer_ack.getptr(
            StringName("trigger_runtime"));
        out["trigger_event_ack"] = trigger_ack != nullptr ? *trigger_ack : int64_t{0};
    }
    return out;
}

} // namespace pk
