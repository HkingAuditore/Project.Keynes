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

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value));
    out.push_back(static_cast<uint8_t>(value >> 8u));
    out.push_back(static_cast<uint8_t>(value >> 16u));
    out.push_back(static_cast<uint8_t>(value >> 24u));
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8u; ++i) out.push_back(static_cast<uint8_t>(value >> (i * 8u)));
}

void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}

bool read_u32(const uint8_t *data, size_t size, size_t &cursor, uint32_t &out) {
    if (data == nullptr || cursor > size || size - cursor < 4u) return false;
    out = static_cast<uint32_t>(data[cursor]) |
        (static_cast<uint32_t>(data[cursor + 1u]) << 8u) |
        (static_cast<uint32_t>(data[cursor + 2u]) << 16u) |
        (static_cast<uint32_t>(data[cursor + 3u]) << 24u);
    cursor += 4u; return true;
}

bool read_u64(const uint8_t *data, size_t size, size_t &cursor, uint64_t &out) {
    if (data == nullptr || cursor > size || size - cursor < 8u) return false;
    out = 0;
    for (uint32_t i = 0; i < 8u; ++i) out |= static_cast<uint64_t>(data[cursor + i]) << (i * 8u);
    cursor += 8u; return true;
}

bool read_i64(const uint8_t *data, size_t size, size_t &cursor, int64_t &out) {
    uint64_t value = 0; if (!read_u64(data, size, cursor, value)) return false;
    std::memcpy(&out, &value, sizeof(out)); return true;
}

template <typename T, typename Writer>
void write_vector(std::vector<uint8_t> &out, const std::vector<T> &values, Writer writer) {
    // A malformed/oversized worker store must never produce a count that is
    // smaller than the number of serialized records.  Clamp both the count
    // and the write range to the same value so restore remains self-framing.
    const size_t count = std::min<size_t>(values.size(), 0xffffffffu);
    append_u32(out, static_cast<uint32_t>(count));
    for (size_t i = 0; i < count; ++i) writer(out, values[i]);
}

template <typename T, typename Reader>
bool read_vector(const uint8_t *data, size_t size, size_t &cursor,
                std::vector<T> &values, Reader reader, size_t max_count) {
    uint32_t count = 0; if (!read_u32(data, size, cursor, count) || count > max_count) return false;
    values.clear(); values.reserve(count);
    for (uint32_t i = 0; i < count; ++i) { T value{}; if (!reader(data, size, cursor, value)) return false; values.push_back(value); }
    return true;
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
    _events.next_event_id = 1; _events.generation = 0;
    _report = RuntimeDomainPipelineReport{};
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
        const RuntimeEnvironmentSnapshot *environment,
        std::vector<RuntimeVisualIntent> &visuals) {
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
        if (std::abs(old - temp) > 1e-5f && visuals.size() < RUNTIME_DOMAIN_INTENT_CAPACITY) {
            RuntimeVisualIntent intent;
            intent.family = RUNTIME_DIRTY_CLIMATE_FIELDS;
            intent.cell_index = static_cast<uint32_t>(i);
            intent.field_id = 1;
            intent.value_f32 = temp;
            visuals.push_back(intent);
        }
    }
    _climate.anomaly = environment->climate_anomaly;
    _climate.rng_state = hash_mix(_climate.rng_state,
        static_cast<uint64_t>(context.day));
    ++_climate.generation;
    out.dirty_families = RUNTIME_DIRTY_CLIMATE_FIELDS;
    out.completed = 1;
    out.timing.work_units = count * 8u;
    out.timing.intent_count = static_cast<uint32_t>(visuals.size());
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
    out.base_generation = _trigger.generation;
    const auto begin = std::chrono::steady_clock::now();
    if (_trigger.accumulators.empty()) {
        _trigger.accumulators.assign(1, 0); _trigger.cooldown_until.assign(1, 0);
        _trigger.fire_sequences.assign(1, 0);
    }
    ++_trigger.accumulators[0]; ++_trigger.generation;
    out.completed = 1; out.dirty_families = RUNTIME_DIRTY_EVENTS;
    out.timing.work_units = _trigger.accumulators.size();
    out.timing.state_hash = hash_mix(FNV_OFFSET, static_cast<uint64_t>(_trigger.accumulators[0]));
    if (_trigger.accumulators[0] == 1 && intents.size() < RUNTIME_DOMAIN_INTENT_CAPACITY) {
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
        intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.opcode = 1; intent.source_id = 1; intent.effective_day = context.day;
        intents.push_back(intent); out.timing.intent_count = 1;
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
    const size_t count = country != nullptr ? country->country_count : 0;
    if (_economy.treasury.size() != count) _economy.treasury.assign(count, 0);
    uint64_t work = 0;
    for (size_t i = 0; i < count; ++i) {
        const int64_t before = _economy.treasury[i];
        const int64_t source = i < country->country_cash.size() ? country->country_cash[i] : 0;
        _economy.treasury[i] = source;
        if (before != source) ++work;
    }
    ++_economy.generation;
    out.completed = 1; out.dirty_families = work > 0 ? RUNTIME_DIRTY_ECONOMY_UI : 0;
    out.timing.work_units = count; out.timing.ack_count = static_cast<uint32_t>(acks.size());
    out.timing.state_hash = hash_mix(FNV_OFFSET, _economy.generation);
    out.timing.state_hash = hash_mix(out.timing.state_hash, static_cast<uint64_t>(context.day));
    out.timing.elapsed_ms = elapsed_ms(begin); return out;
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
        std::vector<RuntimeVisualIntent> &visual_intents,
        std::vector<RuntimeCommandReceipt> &receipts) {
    day_commit = RuntimeDayCommit{}; visual_intents.clear(); receipts.clear();
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
    add(run_climate(context, environment, visual_intents));
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
    visual.dirty_families = visual_intents.empty() ? 0 : RUNTIME_DIRTY_CLIMATE_FIELDS;
    visual.timing.work_units = visual_intents.size();
    visual.timing.intent_count = static_cast<uint32_t>(visual_intents.size());
    visual.timing.state_hash = hash_mix(FNV_OFFSET, visual_intents.size()); add(visual);
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

void RuntimeDomainPodPipeline::serialize(std::vector<uint8_t> &out) const {
    out.clear();
    out.reserve(256u + _climate.temperature.size() * 16u + _events.journal.size() * 32u);
    out.insert(out.end(), {'P', 'D', 'P', '3'});
    append_u32(out, RUNTIME_DOMAIN_POD_ABI_VERSION);
    append_u64(out, _modifier.generation); append_u64(out, _modifier.revision);
    append_u64(out, _effect.next_instance_id); append_u64(out, _effect.generation);
    append_u64(out, _ideology.rng_state); append_u64(out, _ideology.generation);
    append_u64(out, _trigger.generation); append_u64(out, _climate.generation);
    append_u64(out, _climate.rng_state);
    append_u64(out, _economy.generation); append_u64(out, _economy.ledger_failures);
    append_u64(out, _events.next_event_id); append_u64(out, _events.generation);
    write_vector(out, _modifier.entries, [](auto &bytes, const RuntimeModifierPodEntry &v) {
        append_u64(bytes, v.target_handle); append_u32(bytes, v.target_generation);
        append_u32(bytes, v.definition_id); append_i64(bytes, v.stacks);
        append_i64(bytes, v.expires_day); append_i64(bytes, v.value_q16);
    });
    write_vector(out, _effect.instances, [](auto &bytes, const RuntimeEffectPodInstance &v) {
        append_u64(bytes, v.instance_id); append_u32(bytes, v.generation);
        append_u32(bytes, v.target_domain | (static_cast<uint32_t>(v.opcode) << 16u));
        append_u64(bytes, v.target_handle); append_i64(bytes, v.next_due_day);
        append_u32(bytes, v.required_ack_mask); append_u32(bytes, v.received_ack_mask);
        append_u64(bytes, v.fire_sequence); append_u32(bytes, v.active);
    });
    write_vector(out, _ideology.countries, [](auto &bytes, const RuntimeIdeologyPodCountry &v) {
        append_u64(bytes, v.country_handle); append_i64(bytes, v.points);
        append_i64(bytes, v.dominant_id); append_i64(bytes, v.pending_transition);
        append_u32(bytes, v.revision);
    });
    write_vector(out, _trigger.accumulators, [](auto &bytes, int64_t v) { append_i64(bytes, v); });
    write_vector(out, _trigger.cooldown_until, [](auto &bytes, int64_t v) { append_i64(bytes, v); });
    write_vector(out, _trigger.fire_sequences, [](auto &bytes, uint64_t v) { append_u64(bytes, v); });
    write_vector(out, _climate.temperature, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.moisture, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.snow_cover, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.temperature_ema, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.water_balance, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.weather_precip, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.weather_intensity, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    write_vector(out, _climate.vegetation_vitality, [](auto &bytes, float v) { uint32_t bits = 0; std::memcpy(&bits, &v, 4); append_u32(bytes, bits); });
    const double anomaly_scaled = _climate.anomaly * 1000000.0;
    const double anomaly_limit = static_cast<double>(std::numeric_limits<int64_t>::max());
    int64_t anomaly_micro = 0;
    if (anomaly_scaled >= anomaly_limit) anomaly_micro = std::numeric_limits<int64_t>::max();
    else if (anomaly_scaled <= -anomaly_limit) anomaly_micro = std::numeric_limits<int64_t>::min();
    else anomaly_micro = static_cast<int64_t>(std::llround(anomaly_scaled));
    append_i64(out, anomaly_micro);
    write_vector(out, _economy.population, [](auto &bytes, int64_t v) { append_i64(bytes, v); });
    write_vector(out, _economy.treasury, [](auto &bytes, int64_t v) { append_i64(bytes, v); });
    write_vector(out, _economy.inventory, [](auto &bytes, int64_t v) { append_i64(bytes, v); });
    write_vector(out, _events.journal, [](auto &bytes, const RuntimeEventPodEntry &v) {
        append_i64(bytes, v.day); append_u64(bytes, v.event_id);
        append_u32(bytes, v.type | (static_cast<uint32_t>(v.flags) << 16u));
        append_u64(bytes, v.source_handle); append_i64(bytes, v.value);
    });
}

bool RuntimeDomainPodPipeline::restore(const uint8_t *data, size_t size, std::string &error) {
    error.clear();
    if (data == nullptr || size < 4u + 4u || std::memcmp(data, "PDP3", 4u) != 0) {
        error = "runtime_domain_pod_magic_invalid"; return false;
    }
    size_t cursor = 4u; uint32_t version = 0;
    if (!read_u32(data, size, cursor, version) || version != RUNTIME_DOMAIN_POD_ABI_VERSION) {
        error = "runtime_domain_pod_version_incompatible"; return false;
    }
    // Decode transactionally: a corrupt bundle must not leave a partially
    // restored worker store behind.
    const RuntimeModifierPodState modifier_backup = _modifier;
    const RuntimeEffectPodState effect_backup = _effect;
    const RuntimeIdeologyPodState ideology_backup = _ideology;
    const RuntimeTriggerPodState trigger_backup = _trigger;
    const RuntimeClimatePodState climate_backup = _climate;
    const RuntimeEconomyPodState economy_backup = _economy;
    const RuntimeEventsPodState events_backup = _events;
    const auto rollback = [&]() {
        _modifier = modifier_backup;
        _effect = effect_backup;
        _ideology = ideology_backup;
        _trigger = trigger_backup;
        _climate = climate_backup;
        _economy = economy_backup;
        _events = events_backup;
    };
    uint64_t *scalars[] = {&_modifier.generation, &_modifier.revision,
        &_effect.next_instance_id, &_effect.generation, &_ideology.rng_state,
        &_ideology.generation, &_trigger.generation, &_climate.generation,
        &_climate.rng_state,
        &_economy.generation, &_economy.ledger_failures, &_events.next_event_id,
        &_events.generation};
    for (uint64_t *value : scalars) if (!read_u64(data, size, cursor, *value)) {
        rollback(); error = "runtime_domain_pod_header_truncated"; return false;
    }
    const auto read_f32 = [](const uint8_t *bytes, size_t length, size_t &at, float &value) {
        uint32_t bits = 0; if (!read_u32(bytes, length, at, bits)) return false;
        std::memcpy(&value, &bits, sizeof(value)); return std::isfinite(value);
    };
    const auto read_modifier = [](const uint8_t *bytes, size_t length, size_t &at, RuntimeModifierPodEntry &v) {
        int64_t stacks = 0; return read_u64(bytes,length,at,v.target_handle) && read_u32(bytes,length,at,v.target_generation) &&
            read_u32(bytes,length,at,v.definition_id) && read_i64(bytes,length,at,stacks) &&
            read_i64(bytes,length,at,v.expires_day) && read_i64(bytes,length,at,v.value_q16) &&
            (stacks >= std::numeric_limits<int32_t>::min() &&
             stacks <= std::numeric_limits<int32_t>::max()) &&
            (v.stacks = static_cast<int32_t>(stacks), true);
    };
    // Reset vectors before filling them so a failed restore cannot retain an
    // entry from a previous world.
    _modifier.entries.clear(); _effect.instances.clear(); _ideology.countries.clear();
    _trigger.accumulators.clear(); _trigger.cooldown_until.clear(); _trigger.fire_sequences.clear();
    _climate.temperature.clear(); _climate.moisture.clear(); _climate.snow_cover.clear(); _climate.temperature_ema.clear();
    _climate.water_balance.clear(); _climate.weather_precip.clear();
    _climate.weather_intensity.clear(); _climate.vegetation_vitality.clear();
    _economy.population.clear(); _economy.treasury.clear(); _economy.inventory.clear(); _events.journal.clear();
    if (!read_vector(data,size,cursor,_modifier.entries,read_modifier,1u<<20) ||
        !read_vector(data,size,cursor,_effect.instances,[](const uint8_t *b,size_t s,size_t &a,RuntimeEffectPodInstance &v){
            uint32_t packed=0, active=0; return read_u64(b,s,a,v.instance_id)&&read_u32(b,s,a,v.generation)&&read_u32(b,s,a,packed)&&read_u64(b,s,a,v.target_handle)&&read_i64(b,s,a,v.next_due_day)&&read_u32(b,s,a,v.required_ack_mask)&&read_u32(b,s,a,v.received_ack_mask)&&read_u64(b,s,a,v.fire_sequence)&&read_u32(b,s,a,active)&&active <= 1u&&(v.target_domain=static_cast<uint16_t>(packed),v.opcode=static_cast<uint16_t>(packed>>16u),v.active=static_cast<uint8_t>(active),true);
        },1u<<20) ||
        !read_vector(data,size,cursor,_ideology.countries,[](const uint8_t *b,size_t s,size_t &a,RuntimeIdeologyPodCountry &v){int64_t dominant=0,pending=0;return read_u64(b,s,a,v.country_handle)&&read_i64(b,s,a,v.points)&&read_i64(b,s,a,dominant)&&read_i64(b,s,a,pending)&&read_u32(b,s,a,v.revision)&&dominant >= std::numeric_limits<int32_t>::min()&&dominant <= std::numeric_limits<int32_t>::max()&&pending >= std::numeric_limits<int32_t>::min()&&pending <= std::numeric_limits<int32_t>::max()&&(v.dominant_id=static_cast<int32_t>(dominant),v.pending_transition=static_cast<int32_t>(pending),true);},1u<<20) ||
        !read_vector(data,size,cursor,_trigger.accumulators,[](const uint8_t *b,size_t s,size_t &a,int64_t &v){return read_i64(b,s,a,v);},1u<<20) ||
        !read_vector(data,size,cursor,_trigger.cooldown_until,[](const uint8_t *b,size_t s,size_t &a,int64_t &v){return read_i64(b,s,a,v);},1u<<20) ||
        !read_vector(data,size,cursor,_trigger.fire_sequences,[](const uint8_t *b,size_t s,size_t &a,uint64_t &v){return read_u64(b,s,a,v);},1u<<20) ||
        !read_vector(data,size,cursor,_climate.temperature,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.moisture,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.snow_cover,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.temperature_ema,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.water_balance,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.weather_precip,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.weather_intensity,read_f32,1u<<20) ||
        !read_vector(data,size,cursor,_climate.vegetation_vitality,read_f32,1u<<20)) {
        rollback(); error = "runtime_domain_pod_payload_invalid"; return false;
    }
    int64_t anomaly_micro = 0; if (!read_i64(data,size,cursor,anomaly_micro)) { rollback(); error = "runtime_domain_pod_payload_truncated"; return false; }
    _climate.anomaly = static_cast<double>(anomaly_micro) / 1000000.0;
    if (!read_vector(data,size,cursor,_economy.population,[](const uint8_t *b,size_t s,size_t &a,int64_t &v){return read_i64(b,s,a,v);},1u<<20) ||
        !read_vector(data,size,cursor,_economy.treasury,[](const uint8_t *b,size_t s,size_t &a,int64_t &v){return read_i64(b,s,a,v);},1u<<20) ||
        !read_vector(data,size,cursor,_economy.inventory,[](const uint8_t *b,size_t s,size_t &a,int64_t &v){return read_i64(b,s,a,v);},1u<<20) ||
        !read_vector(data,size,cursor,_events.journal,[](const uint8_t *b,size_t s,size_t &a,RuntimeEventPodEntry &v){uint32_t packed=0;return read_i64(b,s,a,v.day)&&read_u64(b,s,a,v.event_id)&&read_u32(b,s,a,packed)&&read_u64(b,s,a,v.source_handle)&&read_i64(b,s,a,v.value)&&(v.type=static_cast<uint16_t>(packed),v.flags=static_cast<uint16_t>(packed>>16u),true);},RUNTIME_DOMAIN_EVENT_CAPACITY) || cursor != size) {
        rollback(); error = "runtime_domain_pod_payload_invalid"; return false;
    }
    return true;
}

bool RuntimeDomainPodPipeline::self_test(std::string &error) {
    constexpr auto stage_order = runtime_domain_stage_order();
    if (stage_order.size() != RUNTIME_DOMAIN_STAGE_COUNT ||
        stage_order[0] != RuntimeDomainId::INPUT_CAPTURE ||
        stage_order[1] != RuntimeDomainId::CLIMATE ||
        stage_order[2] != RuntimeDomainId::COUNTRY ||
        stage_order[3] != RuntimeDomainId::TRIGGER_INPUT ||
        runtime_domain_mask(RuntimeDomainId::CLIMATE) ==
            runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) {
        error = "runtime_domain_stage_layout_invalid";
        return false;
    }
    RuntimeDomainPodPipeline pipeline;
    RuntimeEnvironmentSnapshot environment;
    environment.generation = 1; environment.day = 0; environment.cell_count = 2;
    environment.cell_temp = {10.0f, 12.0f}; environment.cell_moisture = {0.5f, 0.6f};
    environment.cell_snow_cover = {0.0f, 0.0f}; environment.season_phase = 0.25;
    RuntimeCountryPodSnapshot country;
    country.bootstrapped = true; country.country_count = 1; country.cell_count = 2;
    country.country_active = {1}; country.country_generation = {1}; country.territory_count = {2};
    country.country_cash = {100}; country.cell_country_slot = {0, 0}; country.research_weights_bp = {2500,2500,2500,2500};
    country.research_queue_lengths = {0,0,0,0}; country.research_active_index_valid = true;
    country.research_active_country_slots = {0}; country.state_hash = 42;
    RuntimeDayContext context; context.day = 0; context.speed_scale = 1.0;
    RuntimeDayCommit commit; std::vector<RuntimeVisualIntent> visuals;
    std::vector<RuntimeCommandReceipt> receipts;
    if (!pipeline.execute_day(context, &environment, &country, commit, visuals, receipts)) {
        error = "runtime_domain_pipeline_execute_failed"; return false;
    }
    if (commit.completed_stage_count != RUNTIME_DOMAIN_STAGE_COUNT ||
        pipeline.completed_domain_mask() != ((1u << RUNTIME_DOMAIN_STAGE_COUNT) - 1u) ||
        commit.work_units == 0 || visuals.size() != 2) {
        error = "runtime_domain_pipeline_contract_failed"; return false;
    }
    std::vector<uint8_t> encoded;
    pipeline.serialize(encoded);
    if (encoded.size() < 16u) {
        error = "runtime_domain_pipeline_encode_empty"; return false;
    }
    const uint64_t hash_before_corrupt_restore = pipeline.report().state_hash;
    std::vector<uint8_t> corrupt = encoded;
    corrupt.resize(corrupt.size() - 1u);
    std::string restore_error;
    if (pipeline.restore(corrupt.data(), corrupt.size(), restore_error) ||
        pipeline.report().state_hash != hash_before_corrupt_restore) {
        error = "runtime_domain_pipeline_restore_not_transactional"; return false;
    }
    RuntimeClimatePodSnapshot climate_snapshot;
    pipeline.snapshot_climate(climate_snapshot);
    if (climate_snapshot.temperature.size() != 2u ||
        climate_snapshot.water_balance.size() != 2u ||
        climate_snapshot.vegetation_vitality.size() != 2u) {
        error = "runtime_climate_snapshot_shape_invalid"; return false;
    }
    RuntimeClimatePodSnapshot invalid_climate = climate_snapshot;
    invalid_climate.moisture.pop_back();
    if (pipeline.restore_climate(invalid_climate, restore_error)) {
        error = "runtime_climate_snapshot_validation_missing"; return false;
    }
    if (!pipeline.restore_climate(climate_snapshot, restore_error)) {
        error = "runtime_climate_snapshot_restore_failed"; return false;
    }
    RuntimeDayCommit next; context.day = 1;
    if (!pipeline.execute_day(context, &environment, &country, next, visuals, receipts) ||
        next.state_hash == commit.state_hash) {
        error = "runtime_domain_pipeline_hash_not_advancing"; return false;
    }
    error.clear(); return true;
}

} // namespace pk
