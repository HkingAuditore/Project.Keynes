#include "runtime_domain_pod.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

template <typename T>
void reserve_store(std::vector<T> &items, size_t capacity) {
    items.clear();
    items.reserve(capacity);
}

double elapsed_ms(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
}

void set_fallback_reason(RuntimeDomainReport &report, const char *reason) {
    if (reason == nullptr) return;
    size_t i = 0;
    for (; i + 1u < sizeof(report.fallback_reason) && reason[i] != '\0'; ++i)
        report.fallback_reason[i] = reason[i];
    report.fallback_reason[i] = '\0';
}

}

RuntimeDomainPodPipeline::RuntimeDomainPodPipeline() {
    reset();
}

void RuntimeDomainPodPipeline::snapshot_climate(RuntimeClimatePodSnapshot &out) const {
    out.generation = _climate.generation;
    out.rng_state = _climate.rng_state;
    out.anomaly = _climate.anomaly;
    out.temperature = _climate.temperature;
    out.moisture = _climate.moisture;
    out.snow_cover = _climate.snow_cover;
    out.temperature_ema = _climate.temperature_ema;
    out.water_balance = _climate.water_balance;
    out.weather_precip = _climate.weather_precip;
    out.weather_intensity = _climate.weather_intensity;
    out.vegetation_vitality = _climate.vegetation_vitality;
}

bool RuntimeDomainPodPipeline::restore_climate(
        const RuntimeClimatePodSnapshot &snapshot, std::string &error) {
    error.clear();
    const size_t count = snapshot.temperature.size();
    const auto valid = [count](const std::vector<float> &values) {
        if (values.size() != count) return false;
        for (const float value : values) if (!std::isfinite(value)) return false;
        return true;
    };
    if (!std::isfinite(snapshot.anomaly) ||
        !valid(snapshot.moisture) || !valid(snapshot.snow_cover) ||
        !valid(snapshot.temperature_ema) || !valid(snapshot.water_balance) ||
        !valid(snapshot.weather_precip) || !valid(snapshot.weather_intensity) ||
        !valid(snapshot.vegetation_vitality) || !valid(snapshot.temperature)) {
        error = "runtime_climate_snapshot_invalid";
        return false;
    }
    _climate.generation = snapshot.generation;
    _climate.rng_state = snapshot.rng_state;
    _climate.anomaly = snapshot.anomaly;
    _climate.temperature = snapshot.temperature;
    _climate.moisture = snapshot.moisture;
    _climate.snow_cover = snapshot.snow_cover;
    _climate.temperature_ema = snapshot.temperature_ema;
    _climate.water_balance = snapshot.water_balance;
    _climate.weather_precip = snapshot.weather_precip;
    _climate.weather_intensity = snapshot.weather_intensity;
    _climate.vegetation_vitality = snapshot.vegetation_vitality;
    return true;
}

void RuntimeDomainPodPipeline::snapshot_economy(RuntimeEconomyPodSnapshot &out) const {
    out = RuntimeEconomyPodSnapshot{};
    out.session_epoch = _economy.session_epoch;
    out.generation = _economy.generation;
    out.committed_day = _economy.committed_day;
    out.from_day = _economy.committed_day > 0 ? _economy.committed_day - 1 : -1;
    out.epoch_sample_day = _economy.epoch_sample_day;
    out.input_generation = _economy.input_generation;
    out.country_generation = _economy.country_generation;
    out.completed_stage_mask = _economy.completed_stage_mask;
    out.pending_outbox = _economy.pending_outbox;
    out.pending_inbox = _economy.pending_inbox;
    out.operation_gate_mask = _economy.operation_gate_mask;
    out.authority_ready = _economy.authority_ready;
    out.committed = !_economy.epoch_active && !_economy.waiting_for_peer &&
        _economy.committed_day >= 0;
    out.state_hash = hash_mix(FNV_OFFSET, _economy.generation);
    out.state_hash = hash_mix(out.state_hash,
        static_cast<uint64_t>(_economy.committed_day));
    out.state_hash = hash_mix(out.state_hash,
        static_cast<uint64_t>(_economy.completed_stage_mask));
}

bool RuntimeDomainPodPipeline::restore_economy_snapshot(
        const RuntimeEconomyPodSnapshot &snapshot, std::string &error) {
    error.clear();
    if (snapshot.generation == 0 || snapshot.committed_day < 0 ||
        snapshot.from_day > snapshot.committed_day ||
        snapshot.completed_stage_mask == 0 || snapshot.pending_outbox != 0 ||
        snapshot.pending_inbox != 0 || !snapshot.committed) {
        error = "runtime_economy_snapshot_not_committed";
        return false;
    }
    if (snapshot.money_error != 0 || snapshot.population_error != 0 ||
        snapshot.goods_error != 0) {
        error = "runtime_economy_snapshot_conservation_failed";
        return false;
    }
    _economy.session_epoch = snapshot.session_epoch;
    _economy.generation = snapshot.generation;
    _economy.committed_day = snapshot.committed_day;
    _economy.epoch_sample_day = snapshot.epoch_sample_day;
    _economy.input_generation = snapshot.input_generation;
    _economy.country_generation = snapshot.country_generation;
    _economy.completed_stage_mask = snapshot.completed_stage_mask;
    _economy.pending_outbox = 0;
    _economy.pending_inbox = 0;
    _economy.operation_gate_mask = snapshot.operation_gate_mask;
    _economy.epoch_active = false;
    _economy.waiting_for_peer = false;
    _economy.authority_ready = snapshot.authority_ready;
    return true;
}

void RuntimeDomainPodPipeline::reset(uint32_t cell_count, uint32_t country_count) {
    reserve_store(_modifier.entries, std::max<size_t>(country_count, 64));
    reserve_store(_effect.instances, std::max<size_t>(country_count, 64));
    reserve_store(_ideology.countries, std::max<size_t>(country_count, 64));
    reserve_store(_trigger.accumulators, 256);
    reserve_store(_trigger.cooldown_until, 256);
    reserve_store(_trigger.fire_sequences, 256);
    reserve_store(_climate.temperature, cell_count);
    reserve_store(_climate.moisture, cell_count);
    reserve_store(_climate.snow_cover, cell_count);
    reserve_store(_climate.temperature_ema, cell_count);
    reserve_store(_climate.water_balance, cell_count);
    reserve_store(_climate.weather_precip, cell_count);
    reserve_store(_climate.weather_intensity, cell_count);
    reserve_store(_climate.vegetation_vitality, cell_count);
    reserve_store(_economy.population, std::max<size_t>(cell_count, 64));
    reserve_store(_economy.treasury, std::max<size_t>(country_count, 64));
    reserve_store(_economy.inventory, std::max<size_t>(cell_count, 64));
    reserve_store(_events.journal, RUNTIME_DOMAIN_EVENT_CAPACITY);
    _modifier.generation = _modifier.revision = 0;
    _effect.next_instance_id = 1; _effect.generation = 0;
    _ideology.rng_state = 0x9e3779b97f4a7c15ull; _ideology.generation = 0;
    _trigger.generation = 0;
    _climate.rng_state = 0x9e3779b97f4a7c15ull;
    _climate.anomaly = 0.0;
    _climate.generation = 0;
    _economy.generation = 0; _economy.ledger_failures = 0;
    _economy.committed_day = -1;
    _economy.epoch_sample_day = -1;
    _economy.session_epoch = 0;
    _economy.input_generation = 0;
    _economy.country_generation = 0;
    _economy.stage_index = 0;
    _economy.stage_cursor = 0;
    _economy.operation_gate_mask = 0;
    _economy.pending_outbox = 0;
    _economy.pending_inbox = 0;
    _economy.completed_stage_mask = 0;
    _economy.epoch_active = false;
    _economy.waiting_for_peer = false;
    _economy.authority_ready = false;
    _events.next_event_id = 1; _events.generation = 0;
    _report = RuntimeDomainPipelineReport{};
    _restored_legacy_modifier = false;
    _trigger_catalog = RuntimeTriggerPodCatalog{};
    _trigger_catalog.catalog_hash = 1;
    _trigger_catalog.source_count = 1;
    _trigger_catalog.event_type_span = 1;
    _trigger_catalog.max_states = 1;
    _trigger_catalog.max_pending_events = 1;
    _trigger_catalog.distinct_capacity = 1;
    std::string trigger_bootstrap_error;
    _trigger_authority.bootstrap(RuntimeTriggerSnapshot{}, _trigger_catalog,
                                 trigger_bootstrap_error);
    _intents.clear();
    _acks.clear();
    _last_execute_ok = true;
}

uint64_t RuntimeDomainPodPipeline::hash_mix(uint64_t value, uint64_t input) {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6) + (value >> 2);
    value *= FNV_PRIME;
    return value;
}

bool RuntimeDomainPodPipeline::finite_environment(
        const RuntimeEnvironmentSnapshot *environment) {
    if (environment == nullptr) return true;
    const auto finite = [](const std::vector<float> &values) {
        for (const float value : values) if (!std::isfinite(value)) return false;
        return true;
    };
    const size_t cells = environment->cell_count != 0
        ? static_cast<size_t>(environment->cell_count)
        : environment->cell_temp.size();
    const auto sized = [cells](size_t count) {
        return count == 0 || (cells != 0 && count == cells);
    };
    if (!sized(environment->cell_temp.size()) ||
        !sized(environment->cell_temp_30d.size()) ||
        !sized(environment->cell_moisture.size()) ||
        !sized(environment->cell_plant_available_water.size()) ||
        !sized(environment->cell_weather_precip.size()) ||
        !sized(environment->cell_snow_cover.size()) ||
        !sized(environment->cell_weather_intensity.size()) ||
        !sized(environment->cell_elevation.size()) ||
        !sized(environment->cell_lat_norm.size()) ||
        !sized(environment->canal_water.size()) ||
        !sized(environment->building_resource_reserve.size()) ||
        !sized(environment->building_resource_extra.size())) return false;
    if (!environment->neighbor_indices.empty() &&
        (cells == 0 || environment->neighbor_indices.size() != cells * 6u)) return false;
    return std::isfinite(environment->season_phase) &&
        std::isfinite(environment->climate_anomaly) &&
        finite(environment->cell_temp) && finite(environment->cell_temp_30d) &&
        finite(environment->cell_moisture) &&
        finite(environment->cell_plant_available_water) &&
        finite(environment->cell_weather_precip) &&
        finite(environment->cell_snow_cover) &&
        finite(environment->cell_weather_intensity) &&
        finite(environment->cell_elevation) && finite(environment->cell_lat_norm) &&
        finite(environment->canal_water) &&
        finite(environment->building_resource_reserve) &&
        finite(environment->building_resource_extra);
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_input_capture(
        const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::INPUT_CAPTURE;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto begin = std::chrono::steady_clock::now();
    if (environment == nullptr || !finite_environment(environment) ||
        environment->day > context.day ||
        (context.input_generation != 0 &&
         environment->generation != 0 &&
         environment->generation > context.input_generation)) {
        out.completed = 0;
        out.preflight_ok = 0;
        out.fallback = 1;
        ++_report.fallback_count;
        set_fallback_reason(out, environment == nullptr
            ? "missing_environment"
            : "invalid_environment_generation");
        out.timing.elapsed_ms = elapsed_ms(begin);
        return out;
    }
    // The capture itself occurs on the main thread.  This barrier only proves
    // that the immutable copy presented to the worker is structurally valid.
    out.completed = 1;
    out.preflight_ok = 1;
    out.timing.work_units = environment->cell_count;
    out.timing.state_hash = hash_mix(FNV_OFFSET, environment->generation);
    out.timing.state_hash = hash_mix(out.timing.state_hash,
                                     static_cast<uint64_t>(environment->day));
    out.timing.elapsed_ms = elapsed_ms(begin);
    return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_climate(
        const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::CLIMATE;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _climate.generation;
    const auto begin = std::chrono::steady_clock::now();
    if (environment == nullptr || !finite_environment(environment)) {
        out.preflight_ok = 0; out.fallback = 1; ++_report.fallback_count;
        set_fallback_reason(out, environment == nullptr ? "missing_environment" : "invalid_environment");
        out.timing.elapsed_ms = elapsed_ms(begin); return out;
    }
    const size_t count = environment->cell_count != 0
        ? static_cast<size_t>(environment->cell_count)
        : environment->cell_temp.size();
    auto ensure_cells = [count](std::vector<float> &values) {
        if (values.size() != count) values.assign(count, 0.0f);
    };
    ensure_cells(_climate.temperature);
    ensure_cells(_climate.moisture);
    ensure_cells(_climate.snow_cover);
    ensure_cells(_climate.temperature_ema);
    ensure_cells(_climate.water_balance);
    ensure_cells(_climate.weather_precip);
    ensure_cells(_climate.weather_intensity);
    ensure_cells(_climate.vegetation_vitality);
    uint32_t changed_cells = 0;
    for (size_t i = 0; i < count; ++i) {
        const float temp = i < environment->cell_temp.size()
            ? environment->cell_temp[i] : 0.0f;
        const float moisture = i < environment->cell_moisture.size()
            ? environment->cell_moisture[i] : 0.0f;
        const float snow = i < environment->cell_snow_cover.size()
            ? environment->cell_snow_cover[i] : 0.0f;
        const float precip = i < environment->cell_weather_precip.size()
            ? environment->cell_weather_precip[i] : 0.0f;
        const float intensity = i < environment->cell_weather_intensity.size()
            ? environment->cell_weather_intensity[i] : 0.0f;
        const float water = i < environment->cell_plant_available_water.size()
            ? environment->cell_plant_available_water[i] : 0.0f;
        const float old = _climate.temperature[i];
        _climate.temperature[i] = temp;
        _climate.moisture[i] = moisture;
        _climate.snow_cover[i] = snow;
        _climate.temperature_ema[i] = _climate.temperature_ema[i] * 0.95f + temp * 0.05f;
        _climate.water_balance[i] = water;
        _climate.weather_precip[i] = precip;
        _climate.weather_intensity[i] = intensity;
        // Vitality is a deterministic bounded integration of water and
        // temperature stress.  It is intentionally POD-only; vegetation
        // visuals consume the resulting field later on the main thread.
        const float stress = std::min(1.0f, std::abs(temp - 15.0f) / 45.0f);
        const float target_vitality = std::clamp((1.0f - stress) *
            std::clamp(0.5f + water * 0.5f, 0.0f, 1.0f), 0.0f, 1.0f);
        _climate.vegetation_vitality[i] = _climate.vegetation_vitality[i] * 0.9f +
            target_vitality * 0.1f;
        if (std::abs(old - temp) > 1e-5f && changed_cells < RUNTIME_DOMAIN_INTENT_CAPACITY)
            ++changed_cells;
    }
    _climate.anomaly = environment->climate_anomaly;
    _climate.rng_state = hash_mix(_climate.rng_state,
        static_cast<uint64_t>(context.day));
    ++_climate.generation;
    out.dirty_families = RUNTIME_DIRTY_CLIMATE_FIELDS;
    out.completed = 1;
    out.timing.work_units = count * 8u;
    out.timing.intent_count = changed_cells;
    out.timing.state_hash = hash_mix(FNV_OFFSET, _climate.generation);
    out.timing.state_hash = hash_mix(out.timing.state_hash,
                                     static_cast<uint64_t>(std::llround(_climate.anomaly * 1000000.0)));
    out.timing.state_hash = hash_mix(out.timing.state_hash, _climate.rng_state);
    out.timing.elapsed_ms = elapsed_ms(begin);
    return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_country(
        const RuntimeDayContext &context, const RuntimeCountryPodSnapshot *country,
        std::vector<RuntimeDomainIntent> &intents) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::COUNTRY;
    out.day = context.day;
    out.base_generation = country != nullptr ? country->generation : 0;
    const auto begin = std::chrono::steady_clock::now();
    if (country == nullptr || !country->bootstrapped) {
        out.preflight_ok = 0; out.fallback = 1; ++_report.fallback_count;
        set_fallback_reason(out, country == nullptr ? "missing_country_snapshot" : "country_not_bootstrapped");
        out.timing.elapsed_ms = elapsed_ms(begin); return out;
    }
    const uint32_t count = country->research_active_index_valid
        ? static_cast<uint32_t>(country->research_active_country_slots.size())
        : country->country_count;
    out.dirty_families = count > 0 ? RUNTIME_DIRTY_COUNTRY_STATE : 0;
    out.completed = 1;
    out.timing.work_units = count;
    out.timing.state_hash = hash_mix(FNV_OFFSET, country->state_hash);
    out.timing.state_hash = hash_mix(out.timing.state_hash, static_cast<uint64_t>(context.day));
    for (uint32_t i = 0; i < count && intents.size() < RUNTIME_DOMAIN_INTENT_CAPACITY; ++i) {
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
        intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
        intent.opcode = 1;
        intent.source_id = i;
        intent.effective_day = context.day;
        intents.push_back(intent);
    }
    out.timing.intent_count = static_cast<uint32_t>(intents.size());
    out.timing.elapsed_ms = elapsed_ms(begin);
    return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_trigger(
        const RuntimeDayContext &context, std::vector<RuntimeDomainIntent> &intents) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::TRIGGER_INPUT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = static_cast<uint32_t>(_trigger_authority.generation());
    const auto begin = std::chrono::steady_clock::now();
    RuntimeTriggerPodPlan plan;
    std::string error;
    if (!_trigger_authority.plan_day(context.day, context.input_generation, plan, error)) {
        out.preflight_ok = 0;
        runtime_copy_text(out.fallback_reason, error.empty()
            ? "trigger_pod_transaction_failed" : error.c_str());
        out.timing.elapsed_ms = elapsed_ms(begin);
        return out;
    }
    // Required ACK identities are not received ACKs. This compatibility
    // pipeline has no Trigger peer adapter, so an emitted intent must leave
    // the transaction uncommitted until a real receipt is supplied.
    static const std::vector<RuntimeDomainAck> no_trigger_acks;
    if (!_trigger_authority.commit_day(plan, no_trigger_acks, error)) {
        _trigger_authority.discard_plan();
        out.preflight_ok = 0;
        runtime_copy_text(out.fallback_reason, error.empty()
            ? "trigger_pod_transaction_failed" : error.c_str());
        out.timing.elapsed_ms = elapsed_ms(begin);
        return out;
    }
    out.completed = 1; out.preflight_ok = 1; out.dirty_families = RUNTIME_DIRTY_EVENTS;
    out.timing.work_units = plan.next_state.states.size() + plan.intents.size();
    out.timing.intent_count = static_cast<uint32_t>(plan.intents.size());
    out.timing.ack_count = plan.required_ack_count;
    out.timing.state_hash = _trigger_authority.state_hash();
    for (const RuntimeTriggerEffectIntent &effect : plan.intents) {
        if (intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) break;
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
        intent.target_domain = static_cast<uint16_t>(effect.domain);
        intent.opcode = static_cast<uint16_t>(effect.opcode);
        intent.source_id = static_cast<uint64_t>(effect.id);
        intent.target_handle = effect.target_handle;
        intent.target_generation = effect.target_generation;
        intent.value = effect.resolved_value;
        intent.effective_day = effect.effective_day;
        intent.payload = effect.payload;
        intents.push_back(intent);
    }
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_ideology(
        const RuntimeDayContext &context, std::vector<RuntimeDomainIntent> &intents) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::IDEOLOGY;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _ideology.generation;
    const auto begin = std::chrono::steady_clock::now();
    ++_ideology.generation;
    _ideology.rng_state = hash_mix(_ideology.rng_state, static_cast<uint64_t>(context.day));
    out.completed = 1; out.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
    out.timing.work_units = _ideology.countries.size();
    out.timing.state_hash = hash_mix(_ideology.rng_state, _ideology.generation);
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_effect(
        const RuntimeDayContext &context, std::vector<RuntimeDomainIntent> &intents) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::EFFECT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _effect.generation;
    const auto begin = std::chrono::steady_clock::now();
    uint64_t work = 0;
    for (auto &instance : _effect.instances) {
        if (instance.active == 0 || instance.next_due_day > context.day) continue;
        ++work; instance.fire_sequence++; instance.next_due_day = context.day + 1;
        if (intents.size() < RUNTIME_DOMAIN_INTENT_CAPACITY) {
            RuntimeDomainIntent intent;
            intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
            intent.target_domain = instance.target_domain; intent.opcode = instance.opcode;
            intent.target_handle = instance.target_handle; intent.effective_day = context.day;
            intents.push_back(intent);
        }
    }
    ++_effect.generation;
    out.completed = 1; out.dirty_families = work > 0 ? RUNTIME_DIRTY_EVENTS : 0;
    out.timing.work_units = work; out.timing.intent_count = static_cast<uint32_t>(intents.size());
    out.timing.state_hash = hash_mix(FNV_OFFSET, _effect.generation);
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_modifier(
        const RuntimeDayContext &context, std::vector<RuntimeDomainAck> &acks) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::MODIFIER;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _modifier.generation;
    const auto begin = std::chrono::steady_clock::now();
    uint64_t work = 0;
    for (auto it = _modifier.entries.begin(); it != _modifier.entries.end();) {
        ++work;
        if (it->expires_day >= 0 && it->expires_day <= context.day) it = _modifier.entries.erase(it);
        else ++it;
    }
    ++_modifier.generation; ++_modifier.revision;
    out.completed = 1; out.dirty_families = work > 0 ? RUNTIME_DIRTY_COUNTRY_STATE : 0;
    out.timing.work_units = work; out.timing.ack_count = static_cast<uint32_t>(acks.size());
    out.timing.state_hash = hash_mix(FNV_OFFSET, _modifier.revision);
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_gameplay_effect(
        const RuntimeDayContext &context, std::vector<RuntimeDomainIntent> &intents) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::GAMEPLAY_EFFECT;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _effect.generation;
    const auto begin = std::chrono::steady_clock::now();
    ++_effect.generation;
    out.completed = 1; out.timing.work_units = 1;
    out.timing.state_hash = hash_mix(FNV_OFFSET, _effect.generation ^ static_cast<uint64_t>(context.day));
    out.timing.intent_count = static_cast<uint32_t>(intents.size());
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_economy(
        const RuntimeDayContext &context, const RuntimeCountryPodSnapshot *country,
        std::vector<RuntimeDomainAck> &acks) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::ECONOMY;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _economy.generation;
    const auto begin = std::chrono::steady_clock::now();
    if (country == nullptr || !country->bootstrapped) {
        out.completed = 0;
        out.preflight_ok = 0;
        out.fallback = 1;
        set_fallback_reason(out, country == nullptr
            ? "missing_country_snapshot" : "country_not_bootstrapped");
        out.timing.elapsed_ms = elapsed_ms(begin);
        return out;
    }
    // J2-B: publish orchestration header only. Do not claim full-stage authority
    // or invent treasury mutations from the country cash snapshot.
    _economy.epoch_active = true;
    _economy.epoch_sample_day = context.day;
    _economy.input_generation = context.input_generation;
    _economy.country_generation = country->generation;
    _economy.stage_index = 0;
    _economy.stage_cursor = 0;
    _economy.completed_stage_mask = 0;
    _economy.pending_outbox = 0;
    _economy.pending_inbox = 0;
    ++_economy.generation;
    _economy.committed_day = context.day;
    // Diagnostic pipeline still marks the stage complete for Host SHADOW
    // telemetry, but authority_ready stays false until ACTIVE migration.
    _economy.completed_stage_mask = RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    _economy.epoch_active = false;
    _economy.authority_ready = false;
    (void)acks;
    out.completed = 1;
    out.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
    out.timing.work_units = country->country_count;
    out.timing.ack_count = 0;
    out.timing.state_hash = hash_mix(FNV_OFFSET, _economy.generation);
    out.timing.state_hash = hash_mix(out.timing.state_hash,
        static_cast<uint64_t>(context.day));
    out.timing.state_hash = hash_mix(out.timing.state_hash,
        _economy.completed_stage_mask);
    out.timing.elapsed_ms = elapsed_ms(begin);
    return out;
}

RuntimeDomainReport RuntimeDomainPodPipeline::run_events(
        const RuntimeDayContext &context, std::vector<RuntimeDomainIntent> &intents) {
    RuntimeDomainReport out; out.domain = RuntimeDomainId::EVENTS;
    out.day = context.day;
    out.input_generation = context.input_generation;
    out.base_generation = _events.generation;
    const auto begin = std::chrono::steady_clock::now();
    if (_events.journal.size() < RUNTIME_DOMAIN_EVENT_CAPACITY) {
        RuntimeEventPodEntry entry;
        entry.day = context.day; entry.event_id = _events.next_event_id++;
        entry.type = 1; entry.source_handle = 0; entry.value = 0;
        _events.journal.push_back(entry);
    }
    ++_events.generation;
    out.completed = 1; out.dirty_families = RUNTIME_DIRTY_EVENTS;
    out.timing.work_units = 1; out.timing.state_hash = hash_mix(FNV_OFFSET, _events.generation);
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
}

bool RuntimeDomainPodPipeline::execute_day(
        const RuntimeDayContext &context, const RuntimeEnvironmentSnapshot *environment,
        const RuntimeCountryPodSnapshot *country, RuntimeDayCommit &day_commit,
        std::vector<RuntimeCommandReceipt> &receipts) {
    day_commit = RuntimeDayCommit{}; receipts.clear();
    _report = RuntimeDomainPipelineReport{}; _intents.clear(); _acks.clear();
    if (context.day < 0 || !std::isfinite(context.speed_scale)) return false;
    bool all_ok = true;
    const auto add = [&](const RuntimeDomainReport &domain) {
        const size_t index = static_cast<size_t>(domain.domain) - 1u;
        if (index < _report.domains.size()) _report.domains[index] = domain;
        if (domain.completed != 0) {
            _report.completed_domain_mask |= runtime_domain_mask(domain.domain);
            ++day_commit.completed_stage_count;
        }
        _report.dirty_families |= domain.dirty_families;
        _report.work_units += domain.timing.work_units;
        _report.intent_count += domain.timing.intent_count;
        _report.ack_count += domain.timing.ack_count;
        _report.state_hash = hash_mix(_report.state_hash, domain.timing.state_hash);
        all_ok = all_ok && domain.preflight_ok != 0 && domain.completed != 0;
        day_commit.dirty_families |= domain.dirty_families;
        day_commit.work_units += domain.timing.work_units;
        day_commit.completed_domain_mask |= runtime_domain_mask(domain.domain);
    };
    add(run_input_capture(context, environment));
    const auto climate = run_climate(context, environment);
    add(climate);
    add(run_country(context, country, _intents));
    add(run_trigger(context, _intents));
    add(run_ideology(context, _intents));
    add(run_effect(context, _intents));
    add(run_modifier(context, _acks));
    add(run_gameplay_effect(context, _intents));
    add(run_economy(context, country, _acks));
    add(run_events(context, _intents));
    RuntimeDomainReport visual; visual.domain = RuntimeDomainId::VISUAL;
    visual.day = context.day; visual.input_generation = context.input_generation;
    visual.completed = 1;
    visual.dirty_families = climate.timing.intent_count == 0 ? 0 : RUNTIME_DIRTY_CLIMATE_FIELDS;
    visual.timing.work_units = climate.timing.intent_count;
    visual.timing.intent_count = climate.timing.intent_count;
    visual.timing.state_hash = hash_mix(FNV_OFFSET, climate.timing.intent_count); add(visual);
    RuntimeDomainReport commit; commit.domain = RuntimeDomainId::COMMIT;
    commit.day = context.day; commit.input_generation = context.input_generation;
    commit.base_generation = _report.state_hash; commit.completed = 1;
    commit.timing.work_units = 1; commit.timing.state_hash = _report.state_hash; add(commit);
    _report.state_hash = hash_mix(_report.state_hash, static_cast<uint64_t>(context.day));
    day_commit.state_hash = _report.state_hash;
    day_commit.completed_stage_count = RUNTIME_DOMAIN_STAGE_COUNT;
    day_commit.completed_domain_mask = _report.completed_domain_mask;
    _last_execute_ok = all_ok;
    return all_ok;
}
} // namespace pk
