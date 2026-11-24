#include "native_simulation_host.h"
#include "runtime_day_tail.h"
#include "runtime_golden_diagnostics.h"
#include "country_core_apply.h"
#include "economy_api.h"
#include <algorithm>
#include <cstring>
#include <type_traits>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include "runtime_switch_registry.h"
namespace pk {
namespace {
struct LogicalHash {
    uint64_t value = 1469598103934665603ull;
    template<class T> void add(T item) {
        static_assert(std::is_arithmetic<T>::value || std::is_enum<T>::value,
                      "hash only explicit logical scalar fields");
        uint64_t bits = 0;
        if constexpr (std::is_floating_point<T>::value)
            std::memcpy(&bits, &item, sizeof(item));
        else bits = static_cast<uint64_t>(item);
        for (unsigned i = 0; i < 8; ++i) {
            value = (value ^ uint8_t(bits >> (i * 8))) * 1099511628211ull;
        }
    }
    template<class Range> void column(const Range &items) {
        add(items.size());
        for (size_t i = 0; i < size_t(items.size()); ++i) add(items[i]);
    }
};

template<class Range> void trace_continuation_column(const char *domain, int64_t day,
        const char *name, const Range &values) {
    const char *path = runtime_switch_value(RuntimeSwitch::PK_SIM_DAY_TRACE);
    if (path == nullptr || !*path) return;
    std::ofstream out(std::string(path) + ".continuation", std::ios::app);
    out << std::setprecision(17) << "CONT|" << domain << "|" << day << "|" << name << "|";
    for (size_t i = 0; i < size_t(values.size()); ++i) out << +values[i] << ",";
    out << "\n";
}

void add_row(LogicalHash &hash, const RuntimeTriggerEvent &row) {
    hash.add(row.source_id);
    hash.add(row.event_id);
    hash.add(row.day);
    hash.add(row.event_type);
    hash.add(row.payload_schema);
    hash.add(row.entity_handle);
    hash.add(row.group_handle);
    hash.add(row.value);
    hash.column(row.payload);
    hash.add(row.snapshot);
}

void add_row(LogicalHash &hash, const RuntimeTriggerBranchBinding &row) {
    hash.add(row.trigger_id);
    hash.add(row.branch_handle);
    hash.add(row.cell);
    hash.add(row.reward_target);
    hash.add(row.enabled);
}

void add_row(LogicalHash &hash, const RuntimeTriggerPodSnapshotState &row) {
    hash.add(row.trigger_id);
    hash.add(row.target_handle);
    hash.add(row.target_generation);
    hash.add(row.accumulator);
    hash.add(row.remainder);
    hash.add(row.last_event_id);
    hash.add(row.fire_sequence);
    hash.add(row.cooldown_until);
    hash.add(row.window_start_day);
    hash.add(row.last_observed);
    hash.add(row.last_sample_day);
    hash.add(row.completed);
    hash.add(row.initialized);
    hash.add(row.needs_resync);
    hash.column(row.distinct_keys);
}

void add_row(LogicalHash &hash, const RuntimeTriggerEffectIntent &row) {
    hash.add(row.id);
    hash.add(row.effective_day);
    hash.add(row.source_priority);
    hash.add(row.trigger_id);
    hash.add(row.effect_definition_id);
    hash.add(row.target_handle);
    hash.add(row.target_generation);
    hash.add(row.fire_sequence);
    hash.add(row.action);
    hash.add(row.domain);
    hash.add(row.opcode);
    hash.add(row.resolved_value);
    hash.add(row.duration_days);
    hash.add(row.stacks);
    hash.column(row.payload);
}

void add_row(LogicalHash &hash, const RuntimeEventsRecord &row) {
    hash.add(row.event_id);
    hash.add(row.tick);
    hash.add(row.phase);
    hash.add(row.type);
    hash.add(row.source);
    hash.add(row.flags);
    hash.add(row.entity_handle);
    hash.add(row.entity_id);
    hash.add(row.cell_idx);
    hash.add(row.payload_schema);
    hash.add(row.value_i64);
    hash.add(row.payload_i0);
    hash.add(row.payload_i1);
    hash.add(row.payload_i2);
    hash.add(row.payload_i3);
}

void add_row(LogicalHash &hash, const RuntimeEventsConsumerAck &row) {
    hash.add(row.consumer_key);
    hash.add(row.event_id);
}

void add_row(LogicalHash &hash, const RuntimeEventsIdempotencyEvidence &row) {
    hash.add(row.key);
    hash.add(row.request_id);
    hash.add(row.event_id);
}

void add_row(LogicalHash &hash, const RuntimeModifierPodEntry &row) {
    hash.add(row.domain);
    hash.add(row.target_handle);
    hash.add(row.target_generation);
    hash.add(row.definition_id);
    hash.add(row.scope);
    hash.add(row.entity_handle);
    hash.add(row.group_handle);
    hash.add(row.source_type);
    hash.add(row.source_id);
    hash.add(row.stacks);
    hash.add(row.magnitude_q16);
    hash.add(row.value_q16);
    hash.add(row.applied_day);
    hash.add(row.expires_day);
}

void add_row(LogicalHash &hash, const RuntimeModifierPodBucket &row) {
    hash.add(row.domain);
    hash.add(row.scope);
    hash.add(row.stat_id);
    hash.add(row.scope_id);
    hash.add(row.sum_add);
    hash.add(row.product_factor);
    hash.add(row.active_count);
}

void add_row(LogicalHash &hash, const RuntimeEffectPodInstance &row) {
    hash.add(row.program_id);
    hash.add(row.source_type);
    hash.add(row.source_id);
    hash.add(row.source_handle);
    hash.add(row.target_handle);
    hash.add(row.target_generation);
    hash.add(row.level);
    hash.add(row.magnitude_scale_q16);
    hash.add(row.metric_base);
    hash.add(row.input_revision);
    hash.add(row.last_evaluated_input_revision);
    hash.add(row.next_due_day);
    hash.add(row.cadence_days);
    hash.add(row.lifecycle);
    hash.add(row.stack_policy);
    hash.add(row.stack_count);
    hash.add(row.applied_stack_count);
    hash.add(row.max_stacks);
    hash.add(row.expires_day);
    hash.add(row.stack_key_hash);
    hash.add(row.fire_sequence);
    hash.add(row.effect_applied);
    hash.add(row.applied_input_revision);
    hash.add(row.last_acked_fire_sequence);
    hash.add(row.active);
    hash.add(row.retire_requested);
    hash.add(row.needs_resync);
    hash.add(row.latched);
}

void add_row(LogicalHash &hash, const RuntimeEffectPodCommand &row) {
    hash.add(row.action);
    hash.add(row.domain);
    hash.add(row.opcode);
    hash.add(row.source_handle);
    hash.add(row.target_handle);
    hash.add(row.target_generation);
    hash.add(row.value);
    hash.add(row.duration_days);
    hash.add(row.stacks);
    hash.add(row.command_definition_id);
    hash.add(row.command_key_hash);
    hash.add(row.definition_key_hash);
    hash.add(row.effective_day);
    hash.column(row.payload);
}

void add_row(LogicalHash &hash, const RuntimeEffectPodTransaction &row) {
    hash.add(row.effective_day);
    hash.add(row.command_begin);
    hash.add(row.command_count);
    hash.add(row.required_ack_mask);
    hash.add(row.received_ack_mask);
    hash.add(row.status);
    hash.add(row.last_ack_code);
    hash.add(row.fire_sequence);
    hash.add(row.input_revision);
    hash.add(row.transition_stack_count);
}

template<class Range> void rows(LogicalHash &hash, const Range &items) {
    hash.add(items.size());
    for (const auto &row : items) add_row(hash, row);
}
uint64_t climate_hash(const RuntimeClimateStore &state, std::string &error) {
    LogicalHash hash;
    hash.add(state.cell_count);
    hash.add(state.committed_day);
    hash.column(state.temperature);
    hash.column(state.temperature_30d_ema);
    hash.column(state.temperature_365d_ema);
    hash.column(state.temperature_baseline);
    hash.column(state.thermal_energy);
    hash.column(state.moisture);
    hash.column(state.plant_available_water);
    hash.column(state.water_balance_30d);
    hash.column(state.weather_precipitation);
    hash.column(state.weather_intensity);
    hash.column(state.vapor);
    hash.column(state.cloud_water);
    hash.column(state.cloud_cover);
    hash.column(state.convergence);
    hash.column(state.instability);
    hash.column(state.weather_type);
    hash.column(state.weather_prev_type);
    hash.column(state.weather_target_type);
    hash.column(state.weather_transition_alpha);
    hash.column(state.snow_cover);
    hash.column(state.snowpack);
    hash.column(state.sea_ice);
    hash.column(state.runoff);
    hash.column(state.groundwater);
    hash.column(state.river_storage);
    hash.column(state.river_discharge);
    hash.column(state.riparian_moisture);
    hash.column(state.vegetation_vitality);
    hash.column(state.vegetation_growth_pressure);
    hash.column(state.vegetation_heat_stress);
    hash.column(state.vegetation_drought_stress);
    hash.column(state.vegetation_cold_stress);
    hash.column(state.vegetation_growth_streak);
    hash.column(state.vegetation_drought_streak);
    hash.column(state.vegetation_succession_candidate);
    hash.column(state.synoptic_psi);
    hash.column(state.synoptic_psi_prev);
    hash.column(state.vegetation);
    hash.column(state.base_vegetation);
    hash.column(state.terrain);
    hash.column(state.cover);
    hash.column(state.cyclone_state);
    // Decode into diagnostic-local storage. The save blob also contains view
    // generations, diagnostic cyclone totals and its integrity hash: none is
    // part of this logical projection. Never change the live store or encoder.
    hash.add(state.physics_state.empty());
    if (!state.physics_state.empty()) {
        pk_async_physics::RuntimeClimatePhysicsState physics;
        if (!pk_async_physics::restore_physics_state(state.physics_state.data(),
                state.physics_state.size(), physics, error)) return 0;
        hash.add(physics.cell_count); hash.add(physics.ready); hash.add(physics.initialized);
        hash.add(physics.committed_day); hash.add(physics.last_daily_day);
        hash.add(physics.last_slp_day); hash.add(physics.last_wind_day); hash.add(physics.last_ocean_day);
        hash.add(physics.daily_due_seq); hash.add(physics.synoptic_tick);
        hash.add(physics.synoptic_seeded); hash.add(physics.tta_seeded);
        hash.column(physics.slp);
        hash.column(physics.slp_prev);
        hash.column(physics.wind_x);
        hash.column(physics.wind_y);
        hash.column(physics.wind_speed);
        hash.column(physics.ocean_current_x);
        hash.column(physics.ocean_current_y);
        hash.column(physics.ocean_psi);
        hash.column(physics.ocean_psi_prev);
        hash.column(physics.upwelling);
        hash.column(physics.wind_stress_curl);
        hash.column(physics.ocean_thermal_anomaly);
        hash.column(physics.synoptic_psi);
        hash.column(physics.synoptic_psi_prev);
        hash.column(physics.monsoon_thermal);
        hash.column(physics.temp_transport_anomaly);
    }
    hash.add(state.climate_anomaly);
    hash.add(state.annual_temperature_drift);
    hash.add(state.rng_state);
    hash.add(state.annual_rng_state);
    hash.add(state.history_cursor);
    hash.column(state.temperature_history);
    return hash.value;
}
void trace_country(const RuntimeCountryPodSnapshot &state) {
    const char *path = pk::runtime_switch_value(pk::RuntimeSwitch::PK_GOLDEN_COUNTRY_TRACE);
    if (path == nullptr || !*path) return;
    std::ofstream out(path, std::ios::app);
    out << std::setprecision(17);
    const auto column = [&](const char *name, const auto &values) {
        out << state.committed_day << "|" << name << "|";
        for (const auto &value : values) out << +value << ",";
        out << "\n";
    };
    out << state.committed_day << "|last_research_day|" << state.last_research_day << "\n";
    column("country_active", state.country_active);
    column("country_generation", state.country_generation);
    column("research_active_country_slots", state.research_active_country_slots);
    column("territory_count", state.territory_count);
    column("country_state_version", state.country_state_version);
    column("country_cash", state.country_cash);
    column("country_goods", state.country_goods);
    column("cell_country_slot", state.cell_country_slot);
    column("territory_offsets", state.territory_offsets);
    column("territory_cells", state.territory_cells);
    column("country_technologies", state.country_technologies);
    column("country_discovered", state.country_discovered);
    column("country_pending_technologies", state.country_pending_technologies);
    column("country_research_signals", state.country_research_signals);
    column("research_signal_cell_offsets", state.research_signal_cell_offsets);
    column("research_signal_cells", state.research_signal_cells);
    column("research_signal_evidence_offsets", state.research_signal_evidence_offsets);
    column("research_queues", state.research_queues);
    column("research_queue_lengths", state.research_queue_lengths);
    column("research_weights_bp", state.research_weights_bp);
    column("research_deferred_points", state.research_deferred_points);
    column("research_progress_total", state.research_progress_total);
    column("research_completed_total", state.research_completed_total);
    column("research_progress", state.research_progress);
    column("research_cost_factor", state.research_cost_factor);
    column("research_efficiency", state.research_efficiency);
    column("research_peer_flags", state.research_peer_flags);
    column("research_auto_purchase", state.research_auto_purchase);
    column("research_purchased_total", state.research_purchased_total);
    column("research_consumed_total", state.research_consumed_total);
    column("treasury_goods_consumed_total", state.treasury_goods_consumed_total);
    column("country_tax_defaults", state.country_tax_defaults);
    column("country_tax_default_modes", state.country_tax_default_modes);
    column("country_income_tax_overrides", state.country_income_tax_overrides);
    column("country_consumption_tax_overrides", state.country_consumption_tax_overrides);
    column("country_business_tax_overrides", state.country_business_tax_overrides);
    column("country_import_tax_overrides", state.country_import_tax_overrides);
    column("country_export_tax_overrides", state.country_export_tax_overrides);
    column("country_income_tax_mode_overrides", state.country_income_tax_mode_overrides);
    column("country_consumption_tax_mode_overrides", state.country_consumption_tax_mode_overrides);
    column("country_business_tax_mode_overrides", state.country_business_tax_mode_overrides);
    column("country_import_tax_mode_overrides", state.country_import_tax_mode_overrides);
    column("country_export_tax_mode_overrides", state.country_export_tax_mode_overrides);
    column("cell_tax_policy_ids", state.cell_tax_policy_ids);
    column("is_water", state.is_water);
    for (const auto &row : state.research_signal_evidence)
        out << state.committed_day << "|evidence|" << row.signal << "," << row.count << "," << row.first_day << "," << row.last_day << "," << row.first_cell << "\n";
    for (const auto &row : state.cell_tax_policies) {
        column("tax_defaults", row.defaults); column("tax_modes", row.modes);
        for (const auto &entry : row.overrides)
            out << state.committed_day << "|tax_override|" << entry.kind << "," << entry.item << "," << entry.rate << "," << entry.mode << "\n";
    }
}
uint64_t modifier_hash(const RuntimeModifierPodSnapshot &state) {
    LogicalHash hash;
    hash.add(state.catalog_hash); hash.add(state.committed_day);
    rows(hash, state.entries); rows(hash, state.buckets);
    return hash.value;
}
uint64_t effect_hash(const RuntimeEffectPodSnapshot &state) {
    LogicalHash hash;
    hash.add(state.catalog_hash); hash.add(state.committed_day);
    hash.column(state.metric_values); hash.column(state.metric_revisions);
    rows(hash, state.instances); rows(hash, state.command_arena); rows(hash, state.transactions);
    return hash.value;
}
uint64_t trigger_hash(const RuntimeTriggerSnapshot &state) {
    LogicalHash hash;
    trace_continuation_column("TRIGGER", state.committed_day, "header", std::array<int64_t, 4>{
        state.committed_day, state.current_day, int64_t(state.next_effect_id), int64_t(state.acked_effect_id)});
    trace_continuation_column("TRIGGER", state.committed_day, "source_cursor", state.source_cursor);
    trace_continuation_column("TRIGGER", state.committed_day, "source_needs_resync", state.source_needs_resync);
    hash.add(state.catalog_hash); hash.add(state.committed_day); hash.add(state.current_day);
    hash.add(state.next_effect_id); hash.add(state.acked_effect_id);
    hash.column(state.source_cursor); hash.column(state.source_needs_resync);
    hash.column(state.source_gap_begin); hash.column(state.source_gap_end); hash.column(state.enabled);
    rows(hash, state.states); rows(hash, state.branch_bindings);
    rows(hash, state.pending_events); rows(hash, state.pending_effects);
    return hash.value;
}
uint64_t events_hash(const RuntimeEventsSnapshot &state) {
    LogicalHash hash;
    trace_continuation_column("EVENTS", state.committed_day, "header", std::array<uint64_t, 5>{
        uint64_t(state.next_event_id), uint64_t(state.capacity), uint64_t(state.dropped_event_count), uint64_t(state.first_dropped_event_id), uint64_t(state.events.size())});
    for (const auto &ack : state.consumer_acks)
        trace_continuation_column("EVENTS", state.committed_day, "ack", std::array<uint64_t, 2>{uint64_t(ack.consumer_key), uint64_t(ack.event_id)});
    for (const auto &row : state.idempotency)
        trace_continuation_column("EVENTS", state.committed_day, "idempotency", std::array<uint64_t, 3>{uint64_t(row.key), uint64_t(row.request_id), uint64_t(row.event_id)});
    hash.add(state.committed_day); hash.add(state.next_event_id); hash.add(state.capacity);
    hash.add(state.dropped_event_count); hash.add(state.first_dropped_event_id);
    rows(hash, state.events);
    // The score reads this cursor at display cadence. Trigger and narrative
    // acknowledgements still participate in the simulation digest.
    static constexpr uint64_t music_consumer = 4407092808345815469ull; // pk_music_situation
    const auto simulation_consumer = [](const RuntimeEventsConsumerAck &ack) {
        return ack.consumer_key != music_consumer;
    };
    hash.add(std::count_if(state.consumer_acks.begin(), state.consumer_acks.end(),
                           simulation_consumer));
    for (const auto &ack : state.consumer_acks)
        if (simulation_consumer(ack)) add_row(hash, ack);
    rows(hash, state.idempotency);
    const char *path = runtime_switch_value(RuntimeSwitch::PK_SIM_DAY_TRACE);
    if (path != nullptr && *path) {
        std::ofstream trace(std::string(path) + ".continuation", std::ios::app);
        for (const auto &row : state.events)
            trace << "CONT|EVENTS|" << state.committed_day << "|event|"
                << row.event_id << ',' << row.tick << ',' << row.phase << ',' << row.type
                << ',' << row.source << ',' << row.entity_handle << ',' << row.cell_idx
                << ',' << row.value_i64 << ',' << row.payload_i0 << ',' << row.payload_i1 << "\n";
    }
    return hash.value;
}

} // namespace

bool RuntimeDomainAuthorityRunner::copy_trigger_snapshot(
        RuntimeTriggerSnapshot &out, std::string &error) const {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    return _trigger_configured && _trigger_authority.snapshot(out, error);
}

RuntimeGoldenSnapshot NativeSimulationHost::golden_snapshot() const {
    const auto commit = std::atomic_load(&_latest_commit);
    if (commit && commit->day_tail && commit->day_tail->golden)
        return *commit->day_tail->golden;
    // Standalone diagnostic fixtures may query outside an executor commit.
    auto boundary = try_lock_economy_read_boundary();
    if (!boundary.owns_lock() || _worker_day_inflight.load(std::memory_order_acquire) != 0)
        return {};
    return capture_golden_snapshot(_committed_day.load(std::memory_order_acquire));
}

RuntimeGoldenSnapshot NativeSimulationHost::capture_golden_snapshot(int64_t day) const {
    RuntimeGoldenSnapshot out;
    out.day = day;
    if (out.day < 0 || _country_pod_plan_active.load(std::memory_order_acquire)) return out;
    const auto add = [&](const char *id, const char *scope, int64_t day, uint64_t hash) {
        out.domains.push_back({id, scope, day, hash});
    };
    const auto &climate = _climate_authority.store();
    std::string error;
    if (climate.committed_day >= 0) {
        const uint64_t digest = climate_hash(climate, error);
        if (!error.empty()) return out;
        add("CLIMATE", "committed_store_lanes_and_physics_v1", climate.committed_day, digest);
    }
    if (const auto *country = _country_pod_authority.borrow_state()) {
        trace_country(*country);
        add("COUNTRY", "committed_business_state_v1", country->committed_day,
            country_core_hash_business_state(*country));
    }
    RuntimeTriggerSnapshot trigger;
    if (_domain_authority_runner.copy_trigger_snapshot(trigger, error))
        add("TRIGGER_INPUT", "committed_trigger_snapshot_v1", trigger.committed_day, trigger_hash(trigger));
    if (_ideology_pod_configured) {
        const auto &ideology = _ideology_pod_authority.snapshot();
        add("IDEOLOGY", "committed_business_projection_v1", ideology.committed_day,
            ideology_business_hash(ideology));
    }
    if (_effect_pod_authority.configured()) {
        const auto &effect = _effect_pod_authority.snapshot();
        add("EFFECT", "committed_effect_content_without_instance_ids_v1", effect.committed_day, effect_hash(effect));
    }
    if (_modifier_pod_authority.configured()) {
        const auto &modifier = _modifier_pod_authority.snapshot();
        add("MODIFIER", "committed_entries_and_buckets_v1", modifier.committed_day, modifier_hash(modifier));
    }
    // Before the formula-store handoff, the POD ledger mirror intentionally
    // carries only a subset of population columns. Sampling that mirror made
    // the first two days depend on whether the worker had already acquired the
    // handoff lock. Read the actual formula owner under this same boundary.
    const auto &economy = _economy_pod_authority.state();
    if (economy.committed_day >= 0)
        add("ECONOMY", "committed_population_market_columns_v1", economy.committed_day,
            _economy_production_runtime != nullptr
                ? economy_api::golden_population_market_hash(
                    *_economy_production_runtime, economy.sample_day,
                    economy.committed_day)
                : _economy_pod_authority.golden_population_market_hash());
    const auto &events = _events_authority.snapshot();
    if (events.committed_day >= 0)
        add("EVENTS", "committed_event_log_and_ack_state_v1", events.committed_day, events_hash(events));
    if (_economy_production_runtime != nullptr) {
        out.whole_economy_hash = static_cast<uint64_t>(economy_api::state_hash(*_economy_production_runtime));
        out.whole_economy_ready = true;
    }
    out.ready = true;
    return out;
}
} // namespace pk
