#include "runtime_domain_authorities.h"

#include "runtime_climate_kernel.h"
#include "runtime_country_pod.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

bool RuntimeDomainAuthorityRunner::configure_trigger_pod(
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    RuntimeTriggerSnapshot initial;
    if (_trigger_configured && !_trigger_authority.snapshot(initial, error)) return false;
    if (!_trigger_authority.bootstrap(initial, catalog, error)) return false;
    _trigger_catalog = catalog;
    _trigger_configured = true;
    return true;
}

bool RuntimeDomainAuthorityRunner::queue_trigger_command(
        const RuntimeTriggerCommand &command, std::string &error) {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    return _trigger_authority.queue_command(command, error);
}

bool RuntimeDomainAuthorityRunner::trigger_pod_configured() const {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    return _trigger_configured;
}

bool RuntimeDomainAuthorityRunner::read_trigger_snapshot(
        RuntimeTriggerSnapshot &snapshot, std::string &error) const {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    return _trigger_authority.snapshot(snapshot, error);
}

bool RuntimeDomainAuthorityRunner::run_trigger_active_day(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeDomainAck> &acks,
        std::vector<RuntimeTriggerEffectIntent> &intents,
        RuntimeTriggerSnapshot &snapshot, uint32_t &required_ack_count,
        uint64_t &state_hash, double &replay_ms, std::string &error) {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    intents.clear();
    required_ack_count = 0;
    state_hash = 0;
    replay_ms = 0.0;
    error.clear();
    if (!_trigger_configured) { error = "trigger_pod_not_configured"; return false; }
    if (!_trigger_authority.plan_day(day, input_generation, _trigger_plan, error)) {
        _trigger_authority.discard_plan();
        return false;
    }
    intents = _trigger_plan.intents;
    required_ack_count = _trigger_plan.required_ack_count;
    const auto replay_started = std::chrono::steady_clock::now();
    if (!_trigger_authority.commit_day(_trigger_plan, acks, error)) {
        _trigger_authority.discard_plan();
        return false;
    }
    replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();
    state_hash = _trigger_authority.state_hash();
    return _trigger_authority.snapshot(snapshot, error);
}

RuntimeTriggerPodDiagnostics RuntimeDomainAuthorityRunner::trigger_pod_diagnostics() const {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    return _trigger_authority.diagnostics();
}

bool RuntimeDomainAuthorityRunner::set_trigger_reference_frame(
        int64_t day, uint64_t input_hash, uint64_t state_hash,
        uint64_t effect_hash, std::string &error) {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    if (!_trigger_configured) { error = "trigger_pod_not_configured"; return false; }
    return _trigger_authority.set_reference_frame(
        day, input_hash, state_hash, effect_hash, error);
}

bool RuntimeDomainAuthorityRunner::encode_trigger_save(
        RuntimeTriggerPodSaveSection &section, std::string &error) const {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    if (!_trigger_configured) { error = "trigger_pod_not_configured"; return false; }
    return _trigger_authority.encode_save(section, error);
}

bool RuntimeDomainAuthorityRunner::restore_trigger_save(
        const RuntimeTriggerPodSaveSection &section,
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    std::lock_guard<std::mutex> lock(_trigger_mutex);
    if (!_trigger_authority.restore_save(section, catalog, error)) return false;
    _trigger_catalog = catalog;
    _trigger_configured = true;
    return true;
}
namespace {

constexpr uint64_t FNV_PRIME = 1099511628211ull;

#include "runtime_domain_authorities_stage_helpers.inc"

template <typename T>
uint64_t hash_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    hash ^= static_cast<uint64_t>(values.size());
    hash *= FNV_PRIME;
    for (const T &value : values) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        for (size_t i = 0; i < sizeof(T); ++i) {
            hash ^= static_cast<uint64_t>(bytes[i]);
            hash *= FNV_PRIME;
        }
    }
    return hash;
}

bool finite_vector(const std::vector<float> &values) noexcept {
    for (const float value : values) {
        if (!std::isfinite(value)) return false;
    }
    return true;
}

bool has_cell_lane(const std::vector<float> &lane, uint32_t cells) noexcept {
    return lane.empty() || lane.size() == static_cast<size_t>(cells);
}

} // namespace

RuntimeDomainAuthorityRunner::RuntimeDomainAuthorityRunner() {
    reset(0, 0);
}

void RuntimeDomainAuthorityRunner::reset(uint32_t cell_count,
                                          uint32_t country_count,
                                          size_t modifier_capacity,
                                          size_t effect_capacity,
                                          size_t trigger_capacity,
                                          size_t event_capacity) {
    _current.reset(cell_count, country_count);
    _next.reset(cell_count, country_count);
    // Reserve the arenas once.  The runner never calls reserve/resize from a
    // daily stage; logical contents are cleared and reused at the boundary.
    _current.modifier.entries.reserve(modifier_capacity);
    _current.modifier.expiry_heap.reserve(modifier_capacity);
    _next.modifier.entries.reserve(modifier_capacity);
    _next.modifier.expiry_heap.reserve(modifier_capacity);
    _current.effect.instances.reserve(effect_capacity);
    _next.effect.instances.reserve(effect_capacity);
    _current.ideology.countries.reserve(country_count);
    _next.ideology.countries.reserve(country_count);
    _current.trigger.states.reserve(trigger_capacity);
    _next.trigger.states.reserve(trigger_capacity);
    _current.trigger.distinct_keys.reserve(trigger_capacity * 4u);
    _next.trigger.distinct_keys.reserve(trigger_capacity * 4u);
    _current.events.journal.reserve(event_capacity);
    _next.events.journal.reserve(event_capacity);
    _intents.clear();
    _intents.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
    _acks.clear();
    _acks.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
    _event_scratch.clear();
    _event_scratch.reserve(event_capacity);
    _distinct_scratch.clear();
    _distinct_scratch.reserve(trigger_capacity * 4u);
    _active_plan = nullptr;
    _report = RuntimeDomainAuthorityReport{};
    _economy_replay_report = RuntimeEconomyReplayReport{};
    _economy_pod_authority.reset();
    _plan_ready = false;
}

uint64_t RuntimeDomainAuthorityRunner::hash_mix(uint64_t value,
                                                 uint64_t input) noexcept {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6u) + (value >> 2u);
    value *= FNV_PRIME;
    return value;
}

void RuntimeDomainAuthorityRunner::set_report_error(
        RuntimeDomainReport &report, const char *reason) const {
    report.preflight_ok = 0;
    report.completed = 0;
    report.fallback = 1;
    copy_text(report.fallback_reason, reason);
}

bool RuntimeDomainAuthorityRunner::add_ack(
        RuntimeDomainAuthorityPlan &plan, uint16_t domain,
        uint64_t transaction_id, uint64_t target_handle, int64_t day,
        RuntimeDomainAckCode code) {
    if (_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        plan.preflight_ok = 0;
        copy_text(plan.error, "domain_ack_capacity_exceeded");
        return false;
    }
    RuntimeDomainAck ack;
    ack.transaction_id = transaction_id;
    ack.target_handle = target_handle;
    ack.domain = domain;
    ack.effective_day = day;
    ack.code = code;
    _acks.push_back(ack);
    const uint32_t mask = runtime_domain_mask(
        static_cast<RuntimeDomainId>(domain));
    if (mask != 0) {
        plan.ack_required_mask |= mask;
        if (code == RuntimeDomainAckCode::OK) plan.ack_received_mask |= mask;
    }
    return true;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_input_capture(
        const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment,
        uint64_t &input_hash) const {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::INPUT_CAPTURE;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    std::string validation_error;
    if (environment == nullptr || context.input_generation == 0 ||
        (environment != nullptr && environment->generation != context.input_generation) ||
        (environment != nullptr && environment->day > context.day) ||
        (environment != nullptr &&
         !validate_runtime_environment_snapshot(*environment, validation_error))) {
        set_report_error(out, environment == nullptr
            ? "runtime_input_missing"
            : (validation_error.empty() ? "runtime_input_invalid" : validation_error.c_str()));
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }
    input_hash = RuntimeClimateKernel::input_hash(*environment);
    out.completed = 1;
    out.preflight_ok = 1;
    out.timing.work_units = environment->cell_count;
    out.timing.state_hash = hash_mix(input_hash,
                                     static_cast<uint64_t>(context.day));
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_climate(
        const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment,
        uint64_t &work_units, uint32_t &changed_cells) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::CLIMATE;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    if (environment == nullptr || environment->cell_count != _next.climate.cell_count) {
        set_report_error(out, environment == nullptr
            ? "climate_input_missing" : "climate_input_shape_mismatch");
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }
    std::string validation_error;
    if (!validate_runtime_environment_snapshot(*environment, validation_error)) {
        set_report_error(out, validation_error.c_str());
        out.timing.elapsed_ms = elapsed_ms(started);
        return out;
    }
    const uint32_t cells = _next.climate.cell_count;
    for (uint32_t cell = 0; cell < cells; ++cell) {
        const float previous_temperature = _next.climate.temperature[cell];
        const float previous_moisture = _next.climate.moisture[cell];
        const float source_temperature = environment->cell_temp.empty()
            ? previous_temperature : environment->cell_temp[cell];
        const float source_moisture = environment->cell_moisture.empty()
            ? previous_moisture : environment->cell_moisture[cell];
        // This adapter deliberately uses the immutable input as a stable
        // diagnostic projection.  The production formula remains in
        // RuntimeClimateKernel and is compared separately before promotion.
        _next.climate.temperature[cell] = source_temperature;
        _next.climate.temperature_30d_ema[cell] = environment->cell_temp_30d.empty()
            ? source_temperature : environment->cell_temp_30d[cell];
        _next.climate.moisture[cell] = std::clamp(source_moisture, 0.0f, 1.0f);
        _next.climate.plant_available_water[cell] =
            environment->cell_plant_available_water.empty()
                ? _next.climate.plant_available_water[cell]
                : std::clamp(environment->cell_plant_available_water[cell], 0.0f, 1.0f);
        _next.climate.weather_precipitation[cell] = environment->cell_weather_precip.empty()
            ? _next.climate.weather_precipitation[cell]
            : std::max(0.0f, environment->cell_weather_precip[cell]);
        _next.climate.weather_intensity[cell] = environment->cell_weather_intensity.empty()
            ? _next.climate.weather_intensity[cell]
            : std::max(0.0f, environment->cell_weather_intensity[cell]);
        _next.climate.snow_cover[cell] = environment->cell_snow_cover.empty()
            ? _next.climate.snow_cover[cell]
            : std::clamp(environment->cell_snow_cover[cell], 0.0f, 1.0f);
        if (previous_temperature != _next.climate.temperature[cell] ||
            previous_moisture != _next.climate.moisture[cell]) {
            ++changed_cells;
        }
    }
    _next.climate.climate_anomaly = static_cast<float>(environment->climate_anomaly);
    _next.climate.committed_day = context.day;
    _next.climate.generation = _current.climate.generation + 1u;
    _next.climate.climate_generation = _current.climate.climate_generation + 1u;
    work_units += static_cast<uint64_t>(cells) * 8u;
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_CLIMATE_FIELDS;
    out.timing.work_units = static_cast<uint64_t>(cells) * 8u;
    out.timing.state_hash = _next.climate.state_hash();
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}

RuntimeDomainReport RuntimeDomainAuthorityRunner::run_country(
        const RuntimeDayContext &context,
        const RuntimeCountryPodSnapshot *snapshot,
        uint64_t &work_units) {
    RuntimeDomainReport out;
    out.domain = RuntimeDomainId::COUNTRY;
    out.day = context.day;
    out.input_generation = context.input_generation;
    const auto started = std::chrono::steady_clock::now();
    if (snapshot != nullptr) {
        std::string error;
        if (!RuntimeCountryPodAdapter::validate_snapshot(*snapshot, error)) {
            set_report_error(out, error.c_str());
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        if (_next.country.cell_count != snapshot->cell_count ||
            _next.country.country_count != snapshot->country_count) {
            set_report_error(out, "country_snapshot_shape_mismatch");
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        // The consolidated diagnostic store currently carries one 64-bit
        // technology word per country.  Reject a wider catalog explicitly
        // instead of silently dropping higher words and producing a false
        // parity result.
        if (snapshot->technology_words > 1u) {
            set_report_error(out, "country_snapshot_technology_words_unsupported");
            out.timing.elapsed_ms = elapsed_ms(started);
            return out;
        }
        // Capture only numeric authority fields.  Country names and Godot
        // resources never enter this adapter.
        if (snapshot->country_active.size() == _next.country.country_count)
            _next.country.active = snapshot->country_active;
        if (snapshot->country_generation.size() == _next.country.country_count)
            _next.country.entity_generation = snapshot->country_generation;
        if (snapshot->country_cash.size() == _next.country.country_count)
            _next.country.treasury = snapshot->country_cash;
        if (snapshot->cell_country_slot.size() == _next.country.cell_count)
            _next.country.cell_country_slot = snapshot->cell_country_slot;
        if (!snapshot->territory_offsets.empty())
            _next.country.territory_offsets = snapshot->territory_offsets;
        if (!snapshot->territory_cells.empty())
            _next.country.territory_cells = snapshot->territory_cells;
        if (snapshot->country_technologies.size() == _next.country.country_count)
            _next.country.technologies = snapshot->country_technologies;
        if (snapshot->country_pending_technologies.size() ==
                _next.country.country_count)
            _next.country.pending_technologies = snapshot->country_pending_technologies;
        if (snapshot->country_discovered.size() == _next.country.country_count)
            _next.country.discovered = snapshot->country_discovered;
        if (snapshot->research_queues.size() == _next.country.research_queue.size())
            _next.country.research_queue = snapshot->research_queues;
        if (snapshot->research_queue_lengths.size() ==
                _next.country.research_queue_lengths.size())
            _next.country.research_queue_lengths = snapshot->research_queue_lengths;
        if (snapshot->research_active_country_slots.size() <=
                _next.country.country_count)
            _next.country.research_active_slots =
                snapshot->research_active_country_slots;
    }
    _next.country.committed_day = context.day;
    _next.country.generation = _current.country.generation + 1u;
    _next.country.state_generation = _current.country.state_generation + 1u;
    work_units += _next.country.country_count + _next.country.cell_count;
    out.completed = 1;
    out.preflight_ok = 1;
    out.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
    out.timing.work_units = _next.country.country_count + _next.country.cell_count;
    out.timing.state_hash = _next.country.state_hash();
    out.timing.elapsed_ms = elapsed_ms(started);
    return out;
}
bool RuntimeDomainAuthorityRunner::plan_day(
        const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment,
        const RuntimeCountryPodSnapshot *country_snapshot,
        RuntimeDomainAuthorityPlan &plan,
        std::string &error) {
    error.clear();
    plan = RuntimeDomainAuthorityPlan{};
    plan.context = context;
    _report = RuntimeDomainAuthorityReport{};
    if (_plan_ready) {
        error = "domain_plan_already_pending";
        copy_text(plan.error, error.c_str());
        return false;
    }
    if (context.day < 0 || context.input_generation == 0) {
        error = "domain_context_invalid";
        copy_text(plan.error, error.c_str());
        return false;
    }
    // A domain transaction represents exactly one authoritative simulation
    // day.  Once bootstrapped, accepting a skipped or replayed day would make
    // generation/hash diagnostics look valid while silently violating the
    // no-day-skipping contract.  The initial bootstrap may start at any
    // non-negative day (for example after a restore).
    if (_current.climate.committed_day >= 0 &&
        context.day != _current.climate.committed_day + 1) {
        error = "domain_day_not_sequential";
        copy_text(plan.error, error.c_str());
        return false;
    }
    std::string store_error;
    if (!_current.validate_all(store_error)) {
        error = store_error;
        copy_text(plan.error, error.c_str());
        return false;
    }
    _next = _current;
    _intents.clear();
    _acks.clear();
    _event_scratch.clear();
    _active_plan = &plan;
    uint64_t total_work = 0;
    uint32_t changed_cells = 0;
    uint64_t input_hash = 0;
    const auto assign = [&](size_t index, RuntimeDomainReport report) {
        plan.reports[index] = report;
        _report.domains[index] = report;
        if (report.preflight_ok != 0) {
            plan.planned_mask |= runtime_domain_mask(report.domain);
            _report.diagnostic_planned_mask |= runtime_domain_mask(report.domain);
        }
        total_work += report.timing.work_units;
    };
    const auto input_report = run_input_capture(context, environment, input_hash);
    assign(0, input_report);
    if (input_report.preflight_ok == 0) {
        error = input_report.fallback_reason;
        _active_plan = nullptr;
        copy_text(plan.error, error.c_str());
        return false;
    }
    assign(1, run_climate(context, environment, total_work, changed_cells));
    assign(2, run_country(context, country_snapshot, total_work));
    assign(3, run_trigger_input(context, total_work));
    assign(4, run_ideology(context, total_work));
    assign(5, run_effect(context, total_work));
    assign(6, run_modifier(context, total_work));
    assign(7, run_gameplay_effect(context, total_work));
    assign(8, run_economy(context, environment, total_work, changed_cells));
    assign(9, run_events(context, total_work));
    assign(10, run_visual(context));
    assign(11, run_commit(context));
    for (size_t i = 0; i < plan.reports.size(); ++i) {
        if (plan.reports[i].preflight_ok == 0) {
            error = plan.reports[i].fallback_reason;
            _active_plan = nullptr;
            copy_text(plan.error, error.c_str());
            return false;
        }
    }
    plan.intents = _intents;
    plan.acks = _acks;
    for (const RuntimeDomainIntent &intent : plan.intents) {
        if (intent.target_domain == static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
            plan.ack_required_mask |= runtime_domain_mask(RuntimeDomainId::MODIFIER);
        }
    }
    plan.input_hash = input_hash;
    plan.base_hash = _current.state_hash();
    plan.next_hash = _next.state_hash();
    // External domain ACKs are attached by NativeSimulationHost after the
    // dedicated stage has planned successfully. The plan remains uncommitted
    // until accept_modifier_acks() closes this barrier.
    plan.preflight_ok = 1;
    // A successful plan is not a commit.  Keep the committed mask at zero
    // until the explicit commit barrier swaps the stores; conflating these
    // states makes diagnostics look authoritative after a discarded plan.
    _report.diagnostic_committed_mask = 0;
    _report.ack_required_mask = plan.ack_required_mask;
    _report.ack_received_mask = plan.ack_received_mask;
    _report.intent_count = static_cast<uint32_t>(plan.intents.size());
    _report.ack_count = static_cast<uint32_t>(plan.acks.size());
    _report.state_hash = plan.next_hash;
    _report.input_hash = input_hash;
    _report.work_units = total_work;
    _report.changed_cells = changed_cells;
    _report.preflight_ok = 1;
    _plan_ready = true;
    return true;
}

bool RuntimeDomainAuthorityRunner::accept_modifier_acks(
        RuntimeDomainAuthorityPlan &plan,
        const std::vector<RuntimeDomainAck> &acks, std::string &error) {
    error.clear();
    if (!_plan_ready || _active_plan != &plan || plan.preflight_ok == 0) {
        error = "domain_plan_missing";
        return false;
    }
    std::vector<const RuntimeDomainIntent *> expected;
    expected.reserve(plan.intents.size());
    for (const RuntimeDomainIntent &intent : plan.intents) {
        if (intent.target_domain == static_cast<uint16_t>(RuntimeDomainId::MODIFIER))
            expected.push_back(&intent);
    }
    if (expected.size() > RUNTIME_DOMAIN_INTENT_CAPACITY ||
        acks.size() != expected.size() ||
        plan.acks.size() + acks.size() > RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = expected.size() == acks.size()
            ? "domain_ack_capacity_exceeded" : "modifier_ack_missing";
        copy_text(plan.error, error.c_str());
        plan.preflight_ok = 0;
        return false;
    }
    std::vector<uint8_t> matched(acks.size(), 0u);
    for (const RuntimeDomainIntent *intent : expected) {
        size_t found = acks.size();
        for (size_t i = 0; i < acks.size(); ++i) {
            if (matched[i] != 0) continue;
            const RuntimeDomainAck &ack = acks[i];
            if (ack.domain == static_cast<uint16_t>(RuntimeDomainId::MODIFIER) &&
                ack.request_id == intent->request_id &&
                ack.transaction_id == intent->request_id &&
                ack.producer_id == intent->producer_id &&
                ack.sequence == intent->sequence &&
                ack.target_handle == intent->target_handle &&
                ack.target_generation == intent->target_generation &&
                ack.effective_day == intent->effective_day) {
                found = i;
                break;
            }
        }
        if (found == acks.size()) {
            error = "modifier_ack_identity_mismatch";
            copy_text(plan.error, error.c_str());
            plan.preflight_ok = 0;
            return false;
        }
        if (acks[found].code != RuntimeDomainAckCode::OK) {
            error = acks[found].code == RuntimeDomainAckCode::STALE_GENERATION
                ? "modifier_ack_stale_generation"
                : (acks[found].code == RuntimeDomainAckCode::RETRY
                    ? "modifier_ack_retry" : "modifier_ack_rejected");
            copy_text(plan.error, error.c_str());
            plan.preflight_ok = 0;
            return false;
        }
        matched[found] = 1u;
        plan.acks.push_back(acks[found]);
    }
    if (!expected.empty())
        plan.ack_received_mask |= runtime_domain_mask(RuntimeDomainId::MODIFIER);
    _acks = plan.acks;
    _report.ack_received_mask = plan.ack_received_mask;
    _report.ack_count = static_cast<uint32_t>(plan.acks.size());
    return true;
}

bool RuntimeDomainAuthorityRunner::commit_day(
        RuntimeDomainAuthorityPlan &plan, std::string &error) {
    error.clear();
    if (!_plan_ready || _active_plan != &plan || plan.preflight_ok == 0) {
        error = "domain_plan_missing";
        return false;
    }
    if (plan.ack_required_mask != plan.ack_received_mask) {
        error = "domain_ack_barrier_incomplete";
        return false;
    }
    std::swap(_current, _next);
    plan.next_hash = _current.state_hash();
    plan.preflight_ok = 1;
    _report.commit_ok = 1;
    _report.diagnostic_committed_mask = plan.planned_mask;
    _report.state_hash = plan.next_hash;
    _active_plan = nullptr;
    _plan_ready = false;
    return true;
}

void RuntimeDomainAuthorityRunner::discard_plan() {
    _active_plan = nullptr;
    _plan_ready = false;
}

bool RuntimeDomainAuthorityRunner::self_test(std::string &error) {
    error.clear();
    RuntimeDomainAuthorityRunner runner;
    runner.reset(4u, 1u);
    RuntimeEnvironmentSnapshot environment;
    environment.generation = 1;
    environment.day = 0;
    environment.cell_count = 4;
    environment.climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    environment.cell_temp = {0.2f, 0.3f, 0.4f, 0.5f};
    environment.cell_moisture = {0.4f, 0.5f, 0.6f, 0.7f};
    environment.cell_plant_available_water = {0.5f, 0.5f, 0.5f, 0.5f};
    environment.terrain = {0, 0, 1, 1};
    environment.neighbor_offsets = {0, 1, 2, 3, 4};
    environment.neighbor_indices = {1, 2, 3, 0};
    std::string validation_error;
    if (!validate_runtime_environment_snapshot(environment, validation_error)) {
        error = validation_error;
        return false;
    }
    RuntimeDayContext context;
    context.day = 0;
    context.input_generation = 1;
    context.environment = &environment;
    RuntimeDomainAuthorityPlan plan;
    if (!runner.plan_day(context, &environment, nullptr, plan, error) ||
        plan.planned_mask != RUNTIME_ALL_DOMAIN_MASK || plan.next_hash == 0 ||
        plan.reports[0].preflight_ok == 0 || plan.reports[11].completed == 0) {
        if (error.empty()) error = "domain_authority_plan_self_test_failed";
        return false;
    }
    const RuntimeEconomyReplayReport &economy = runner.economy_replay_report();
    if (economy.completed_stage_mask != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK ||
        economy.stage_cursor != environment.cell_count ||
        economy.input_captured == 0 || economy.committed == 0 ||
        economy.parity_ready != 0 || economy.input_hash == 0 ||
        economy.base_hash == 0 || economy.next_hash == 0 ||
        economy.stage_work[0] != environment.cell_count ||
        economy.stage_work[1] != environment.cell_count ||
        economy.stage_work[12] != environment.cell_count) {
        error = "economy_j2b_replay_contract_failed";
        return false;
    }
    const uint64_t first_input_hash = economy.input_hash;
    if (!runner.commit_day(plan, error)) return false;
    const uint64_t first_hash = runner.report().state_hash;
    context.day = 1;
    context.input_generation = 2;
    environment.generation = 2;
    environment.day = 1;
    if (!runner.plan_day(context, &environment, nullptr, plan, error) ||
        runner.economy_replay_report().input_hash == first_input_hash ||
        !runner.commit_day(plan, error) || runner.report().state_hash == first_hash) {
        if (error.empty()) error = "domain_authority_commit_self_test_failed";
        return false;
    }
    if (runner.stores().economy.ledger_failures != 0 ||
        runner.stores().climate.committed_day != 1 ||
        runner.stores().events.committed_day != 1) {
        error = "domain_authority_state_self_test_failed";
        return false;
    }
    return true;
}

} // namespace pk
