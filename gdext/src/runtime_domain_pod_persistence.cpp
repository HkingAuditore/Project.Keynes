#include "runtime_domain_pod.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

namespace {
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
} // namespace

void RuntimeDomainPodPipeline::serialize(std::vector<uint8_t> &out) const {
    out.clear();
    out.reserve(256u + _climate.temperature.size() * 16u + _events.journal.size() * 32u);
    out.insert(out.end(), {'P', 'D', 'P', '4'});
    append_u32(out, RUNTIME_DOMAIN_POD_ABI_VERSION);
    append_u64(out, _effect.next_instance_id); append_u64(out, _effect.generation);
    append_u64(out, _ideology.rng_state); append_u64(out, _ideology.generation);
    append_u64(out, _trigger.generation); append_u64(out, _climate.generation);
    append_u64(out, _climate.rng_state);
    append_u64(out, _economy.generation); append_u64(out, _economy.ledger_failures);
    append_u64(out, _events.next_event_id); append_u64(out, _events.generation);
    write_vector(out, _effect.instances, [](auto &bytes, const RuntimeDomainEffectPodInstance &v) {
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
    const bool legacy_pdp3 = data != nullptr && size >= 8u &&
        std::memcmp(data, "PDP3", 4u) == 0;
    const bool current_pdp4 = data != nullptr && size >= 8u &&
        std::memcmp(data, "PDP4", 4u) == 0;
    if (!legacy_pdp3 && !current_pdp4) {
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
    uint64_t legacy_modifier_generation = 0;
    uint64_t legacy_modifier_revision = 0;
    if (legacy_pdp3 &&
        (!read_u64(data, size, cursor, legacy_modifier_generation) ||
         !read_u64(data, size, cursor, legacy_modifier_revision))) {
        rollback(); error = "runtime_domain_pod_header_truncated"; return false;
    }
    uint64_t *scalars[] = {&_effect.next_instance_id, &_effect.generation, &_ideology.rng_state,
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
        uint32_t definition_id = 0;
        uint32_t scope = 0;
        uint32_t stacks = 0;
        uint32_t magnitude_q16 = 0;
        if (!read_u64(bytes, length, at, v.modifier_handle) ||
            !read_u64(bytes, length, at, v.target_handle) ||
            !read_u32(bytes, length, at, v.target_generation) ||
            !read_u32(bytes, length, at, definition_id) ||
            !read_u32(bytes, length, at, scope) ||
            !read_u64(bytes, length, at, v.entity_handle) ||
            !read_u64(bytes, length, at, v.group_handle) ||
            !read_u64(bytes, length, at, v.source_type) ||
            !read_u64(bytes, length, at, v.source_id) ||
            !read_u32(bytes, length, at, stacks) ||
            !read_u32(bytes, length, at, magnitude_q16) ||
            !read_i64(bytes, length, at, v.applied_day) ||
            !read_i64(bytes, length, at, v.expires_day)) {
            return false;
        }
        v.definition_id = static_cast<int32_t>(definition_id);
        v.scope = static_cast<int32_t>(scope);
        v.stacks = static_cast<int32_t>(stacks);
        v.magnitude_q16 = static_cast<int32_t>(magnitude_q16);
        return true;
    };
    // Reset vectors before filling them so a failed restore cannot retain an
    // entry from a previous world.
    _modifier.entries.clear(); _effect.instances.clear(); _ideology.countries.clear();
    _trigger.accumulators.clear(); _trigger.cooldown_until.clear(); _trigger.fire_sequences.clear();
    _climate.temperature.clear(); _climate.moisture.clear(); _climate.snow_cover.clear(); _climate.temperature_ema.clear();
    _climate.water_balance.clear(); _climate.weather_precip.clear();
    _climate.weather_intensity.clear(); _climate.vegetation_vitality.clear();
    _economy.population.clear(); _economy.treasury.clear(); _economy.inventory.clear(); _events.journal.clear();
    if (legacy_pdp3) {
        _modifier.generation = legacy_modifier_generation;
        _modifier.revision = legacy_modifier_revision;
        if (!read_vector(data,size,cursor,_modifier.entries,read_modifier,1u<<20)) {
            rollback(); error = "runtime_domain_pod_payload_invalid"; return false;
        }
    } else {
        _modifier.entries.clear();
        _modifier.generation = 0;
        _modifier.revision = 0;
    }
    if (!read_vector(data,size,cursor,_effect.instances,[](const uint8_t *b,size_t s,size_t &a,RuntimeDomainEffectPodInstance &v){
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
    _restored_legacy_modifier = legacy_pdp3;
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
    RuntimeDayCommit commit;
    std::vector<RuntimeCommandReceipt> receipts;
    if (!pipeline.execute_day(context, &environment, &country, commit, receipts)) {
        error = "runtime_domain_pipeline_execute_failed"; return false;
    }
    if (commit.completed_stage_count != RUNTIME_DOMAIN_STAGE_COUNT ||
        pipeline.completed_domain_mask() != ((1u << RUNTIME_DOMAIN_STAGE_COUNT) - 1u) ||
        commit.work_units == 0 || pipeline.report().domains[1].timing.intent_count != 2) {
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
    if (!pipeline.execute_day(context, &environment, &country, next, receipts) ||
        next.state_hash == commit.state_hash) {
        error = "runtime_domain_pipeline_hash_not_advancing"; return false;
    }
    error.clear(); return true;
}

} // namespace pk
