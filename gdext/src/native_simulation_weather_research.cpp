#include "native_simulation_day_context.h"
#include "country_api.h"
#include "native_simulation_weather_research_test.h"
#include "runtime_event_append_packet.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace pk {
namespace {

constexpr int32_t WEATHER_OBSERVED = 11;
constexpr int32_t WEATHER_OBSERVED_V1 = 9;
// Match the established weather research Trigger source and PKTR catalog.
constexpr int32_t WEATHER_RESEARCH_SOURCE = 2;
constexpr int32_t TYPHOON_RULE = 0;
constexpr int32_t MAJOR_FLOOD_RULE = 1;
constexpr int32_t DROUGHT_RULE = 2;
constexpr int32_t MONSOON_RULE = 3;
constexpr int32_t FROST_RULE = 4;
constexpr int32_t STORM_SURGE_RULE = 5;
// Rule 6 is published by Economy as repeated crop failure.
constexpr int32_t HEATWAVE_RULE = 7;
constexpr int32_t FREEZE_THAW_RULE = 8;
constexpr int32_t WET_SEASON_RULE = 9;
constexpr std::array<int32_t, 9> WEATHER_RULES{
    TYPHOON_RULE, MAJOR_FLOOD_RULE, DROUGHT_RULE, MONSOON_RULE, FROST_RULE,
    STORM_SURGE_RULE, HEATWAVE_RULE, FREEZE_THAW_RULE, WET_SEASON_RULE};
constexpr size_t WEATHER_RULE_SPAN = WET_SEASON_RULE + 1;
constexpr uint8_t DROUGHT_TYPE = 4;
constexpr uint8_t HEATWAVE_TYPE = 6;
constexpr uint8_t MONSOON_TYPE = 7;
constexpr uint8_t FLOODING_COVER = 5;
constexpr double WEATHER_INTENSITY = 0.50;
constexpr double HEATWAVE_INTENSITY = 0.30;
constexpr double WET_SEASON_INTENSITY = 0.62;
constexpr double WET_SEASON_SOIL_MOISTURE = 0.55;
constexpr double FROST_TEMPERATURE = 0.18;
constexpr double STRONG_WIND = 0.62;
constexpr uint32_t WEATHER_RESEARCH_PRODUCER = 79u;

struct WeatherObservation {
    int32_t cell_count = 0;
    int32_t first_cell = -1;
    double strongest = 0.0;

    void observe(int32_t cell, double intensity) {
        if (first_cell < 0 || cell < first_cell) first_cell = cell;
        ++cell_count;
        strongest = std::max(strongest, intensity);
    }
};

int32_t weather_discovery_signal(
        const RuntimeTriggerPodCatalog &triggers, const RuntimeTriggerDefinition &definition) {
    if (definition.source_id != WEATHER_RESEARCH_SOURCE ||
        definition.event_type != WEATHER_OBSERVED ||
        definition.payload_schema != WEATHER_OBSERVED_V1 ||
        definition.selector_field != 2 || definition.selector_negated ||
        definition.effect_count != 1 || definition.effect_begin >= triggers.effects.size() ||
        definition.mode != static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT)) return -1;
    const auto &effect = triggers.effects[definition.effect_begin];
    if (effect.action != static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND) ||
        effect.opcode != CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL) return -1;
    return static_cast<int32_t>(effect.payload[0]);
}

void append_weather_research_events(
        int64_t day, const RuntimeClimateStore &climate, const RuntimeClimateResearchWeather &weather,
        const RuntimeCountryPodSnapshot &country, const RuntimeTriggerPodCatalog &triggers,
        std::vector<RuntimeCommandPacket> &out) {
    if (!country.bootstrapped || country.research_signal_words == 0 ||
        country.committed_day != day ||
        climate.committed_day != day || climate.cell_count != country.cell_count) return;

    std::array<int32_t, WEATHER_RULE_SPAN> signals;
    signals.fill(-1);
    for (const auto &definition : triggers.definitions) {
        const int32_t signal = weather_discovery_signal(triggers, definition);
        if (signal < 0 || static_cast<uint32_t>(signal) >= country.research_signal_count) continue;
        if (std::find(WEATHER_RULES.begin(), WEATHER_RULES.end(),
                      definition.selector_value) != WEATHER_RULES.end())
            signals[definition.selector_value] = signal;
    }

    for (uint32_t slot = 0; slot < country.country_count; ++slot) {
        if (country.country_active[slot] == 0) continue;
        std::array<bool, WEATHER_RULE_SPAN> needs{};
        for (const int32_t rule : WEATHER_RULES) {
            const int32_t signal = signals[rule];
            if (signal < 0) continue;
            const size_t word = size_t(slot) * country.research_signal_words + signal / 64;
            // The family drought trigger still needs daily observations
            // after the country has acquired the one-shot research signal.
            needs[rule] = rule == DROUGHT_RULE || (country.country_research_signals[word] &
                (uint64_t{1} << (signal % 64))) == 0;
        }
        if (std::none_of(needs.begin(), needs.end(), [](bool need) { return need; })) continue;

        std::array<WeatherObservation, WEATHER_RULE_SPAN> observations;
        for (int32_t i = country.territory_offsets[slot];
             i < country.territory_offsets[slot + 1u]; ++i) {
            const int32_t cell = country.territory_cells[i];
            const uint8_t type = climate.weather_type[cell];
            const double intensity = climate.weather_intensity[cell];
            const double temperature = climate.temperature[cell];
            const bool flooded = climate.cover[cell] == FLOODING_COVER;
            if (needs[DROUGHT_RULE] && type == DROUGHT_TYPE && intensity >= WEATHER_INTENSITY)
                observations[DROUGHT_RULE].observe(cell, intensity);
            if (type == MONSOON_TYPE) {
                if (needs[MONSOON_RULE] && intensity >= WEATHER_INTENSITY)
                    observations[MONSOON_RULE].observe(cell, intensity);
                if (needs[WET_SEASON_RULE] && intensity >= WET_SEASON_INTENSITY &&
                    weather.soil_moisture != nullptr) {
                    const double wetness = 0.5 + weather.soil_moisture[cell];
                    if (wetness >= WET_SEASON_SOIL_MOISTURE)
                        observations[WET_SEASON_RULE].observe(cell, std::max(intensity, wetness));
                }
            }
            if (needs[HEATWAVE_RULE] && type == HEATWAVE_TYPE && intensity >= HEATWAVE_INTENSITY)
                observations[HEATWAVE_RULE].observe(cell, intensity);
            if (needs[FROST_RULE] && temperature <= FROST_TEMPERATURE)
                observations[FROST_RULE].observe(cell, FROST_TEMPERATURE - temperature);
            if (needs[FREEZE_THAW_RULE] && weather.previous_temperature != nullptr &&
                weather.previous_temperature[cell] <= FROST_TEMPERATURE && temperature > FROST_TEMPERATURE)
                observations[FREEZE_THAW_RULE].observe(cell, temperature - FROST_TEMPERATURE);
            if (needs[MAJOR_FLOOD_RULE] && flooded)
                observations[MAJOR_FLOOD_RULE].observe(cell, intensity);
            if ((needs[TYPHOON_RULE] || needs[STORM_SURGE_RULE]) && weather.cyclone_tags != nullptr &&
                weather.cyclone_tags[cell] == weather.cyclone_generation) {
                if (needs[TYPHOON_RULE]) observations[TYPHOON_RULE].observe(cell, intensity);
                const double wind = weather.wind_speed != nullptr ? weather.wind_speed[cell] : 0.0;
                if (needs[STORM_SURGE_RULE] && (flooded || wind >= STRONG_WIND))
                    observations[STORM_SURGE_RULE].observe(cell, std::max(intensity, wind));
            }
        }
        for (const int32_t rule : WEATHER_RULES) {
            const WeatherObservation &observation = observations[rule];
            if (observation.cell_count == 0) continue;
            RuntimeEventsRecord record;
            record.tick = day;
            record.type = WEATHER_OBSERVED;
            record.source = WEATHER_RESEARCH_SOURCE;
            record.entity_handle = (uint64_t(country.country_generation[slot]) << 32u) | slot;
            record.entity_id = observation.first_cell;
            record.cell_idx = observation.first_cell;
            record.payload_schema = WEATHER_OBSERVED_V1;
            record.value_i64 = std::max<int64_t>(1, std::llround(observation.strongest * 65536.0));
            record.payload_i0 = rule;
            record.payload_i1 = observation.cell_count;
            record.payload_i2 = observation.first_cell;
            record.payload_i3 = 1;
            const uint64_t sequence = (uint64_t(day) << 32u) + uint64_t(slot) * WEATHER_RULE_SPAN + rule;
            out.push_back(make_event_append_packet(
                0, WEATHER_RESEARCH_PRODUCER, sequence, day + 1, record));
        }
    }
}

} // namespace

bool weather_research_self_test(const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    const auto fail = [&](const char *reason) {
        error = reason;
        return false;
    };
    std::array<int32_t, WEATHER_RULE_SPAN> signals;
    signals.fill(-1);
    constexpr uint32_t SIGNAL_COUNT = 4096;
    for (const auto &definition : catalog.definitions) {
        const int32_t signal = weather_discovery_signal(catalog, definition);
        if (signal < 0) continue;
        const int64_t rule = definition.selector_value;
        if (std::find(WEATHER_RULES.begin(), WEATHER_RULES.end(), rule) == WEATHER_RULES.end() ||
            signals[rule] >= 0 || static_cast<uint32_t>(signal) >= SIGNAL_COUNT)
            return fail("weather_research_rule_without_unique_publisher");
        signals[rule] = signal;
    }
    for (const int32_t rule : WEATHER_RULES) {
        if (signals[rule] < 0) return fail("weather_research_rule_missing_from_trigger_catalog");
    }

    constexpr int64_t DAY = 7;
    constexpr uint64_t COUNTRY = uint64_t{1} << 32u;
    RuntimeClimateStore climate;
    climate.cell_count = 8;
    climate.committed_day = DAY;
    climate.weather_type = {4, 7, 0, 6, 7, 4, 6, 0};
    climate.weather_intensity = {0.81f, 0.77f, 0.0f, 0.36f, 0.65f, 0.49f, 0.29f, 0.0f};
    climate.temperature = {0.50f, 0.50f, 0.17f, 0.70f, 0.50f, 0.50f, 0.70f, 0.10f};
    climate.cover = {0, 5, 0, 0, 0, 0, 0, 5};
    const std::array<float, 8> previous{0.10f, 0.5f, 0.16f, 0.7f, 0.5f, 0.5f, 0.7f, 0.15f};
    const std::array<float, 8> soil{0.0f, 0.10f, 0.0f, 0.0f, 0.04f, 0.0f, 0.0f, 0.0f};
    const std::array<float, 8> wind{0.0f, 0.0f, 0.0f, 0.0f, 0.72f, 0.61f, 0.0f, 0.8f};
    const std::array<uint32_t, 8> cyclone{0, 0, 3, 0, 4, 4, 0, 4};
    const RuntimeClimateResearchWeather weather{
        previous.data(), soil.data(), wind.data(), cyclone.data(), 4};
    RuntimeCountryPodSnapshot country;
    country.bootstrapped = true;
    country.committed_day = DAY;
    country.cell_count = climate.cell_count;
    country.country_count = 1;
    country.country_active = {1};
    country.country_generation = {1};
    country.territory_offsets = {0, 7};
    country.territory_cells = {0, 1, 2, 3, 4, 5, 6};
    country.research_signal_count = SIGNAL_COUNT;
    country.research_signal_words = SIGNAL_COUNT / 64;
    country.country_research_signals.assign(country.research_signal_words, 0);

    std::vector<RuntimeCommandPacket> packets;
    append_weather_research_events(DAY, climate, weather, country, catalog, packets);
    if (packets.size() != WEATHER_RULES.size()) return fail("weather_research_event_missing");
    for (size_t i = 0; i < packets.size(); ++i) packets[i].envelope.request_id = i + 1;
    RuntimeEventsAuthority events;
    RuntimeEventsSnapshot saved;
    RuntimeEventsReport report;
    std::vector<RuntimeCommandReceipt> receipts;
    if (!events.plan_day(DAY + 1, packets, saved, receipts, report, error) ||
        !events.commit_day(saved, error)) return false;
    const auto view = events.copy_committed_view();
    if (view.events.size() != WEATHER_RULES.size()) return fail("weather_research_event_packet_rejected");
    constexpr std::array<int32_t, 9> first_cells{4, 1, 0, 1, 2, 4, 3, 0, 1};
    constexpr std::array<int32_t, 9> counts{2, 1, 1, 2, 1, 1, 1, 1, 1};
    RuntimeTriggerPodAuthority trigger;
    if (!trigger.bootstrap({}, catalog, error)) return false;
    for (size_t i = 0; i < view.events.size(); ++i) {
        const auto &event = view.events[i];
        if (event.tick != DAY || event.entity_handle != COUNTRY ||
            event.payload_i0 != WEATHER_RULES[i] || event.cell_idx != first_cells[i] ||
            event.payload_i1 != counts[i] || event.payload_i2 != first_cells[i] ||
            event.payload_i3 != 1 || event.value_i64 <= 0)
            return fail("weather_research_observation_threshold_or_ownership_wrong");
        RuntimeTriggerCommand command;
        command.request_id = command.sequence = i + 1;
        command.opcode = RuntimeTriggerCommandOpcode::INGEST_EVENT;
        command.requested_day = command.effective_day = DAY + 2;
        command.event = {event.source, event.event_id, event.tick, event.type,
            event.payload_schema, event.entity_handle, uint64_t(event.cell_idx),
            event.value_i64, {event.payload_i0, event.payload_i1, event.payload_i2, event.payload_i3}};
        if (!trigger.queue_command(command, error)) return false;
    }
    RuntimeTriggerPodPlan plan;
    if (!trigger.plan_day(DAY + 2, 1, plan, error)) return false;
    if (plan.intents.size() != WEATHER_RULES.size()) return fail("weather_research_discovery_missing");
    for (size_t i = 0; i < WEATHER_RULES.size(); ++i) {
        const uint64_t expected = (uint64_t(signals[WEATHER_RULES[i]]) << 32u) | first_cells[i];
        if (std::none_of(plan.intents.begin(), plan.intents.end(), [&](const auto &intent) {
            return intent.target_handle == COUNTRY &&
                intent.opcode == CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL &&
                uint64_t(intent.payload[0]) == expected;
        })) return fail("weather_research_discovery_targets_wrong_signal_or_cell");
    }
    // No additional one-shot observations once their signals are known. Keep
    // drought samples for the repeating family consumer.
    std::fill(country.country_research_signals.begin(), country.country_research_signals.end(), ~uint64_t{0});
    packets.clear();
    append_weather_research_events(DAY, climate, weather, country, catalog, packets);
    if (packets.size() != 1 ||
        packets.front().envelope.sequence != (uint64_t(DAY) << 32u) + DROUGHT_RULE)
        return fail("weather_research_repeating_drought_consumption_regression");
    return true;
}

const char *NativeSimulationHost::stage_weather_research(DayExecution &day) {
    const uint32_t required_domains = runtime_domain_mask(RuntimeDomainId::COUNTRY) |
        runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT) |
        runtime_domain_mask(RuntimeDomainId::EVENTS);
    if (!day.active_climate_ok ||
        (_requested_authority_mask.load(std::memory_order_acquire) & required_domains) !=
            required_domains || !_domain_authority_runner.trigger_pod_configured()) return nullptr;

    const auto country = country_economy_audit_snapshot();
    if (!country) return nullptr;
    std::vector<RuntimeCommandPacket> packets;
    append_weather_research_events(day.plan.context.day, _climate_authority.store(),
        _climate_authority.research_weather(), *country,
        _domain_authority_runner.trigger_catalog(), packets);
    for (auto &packet : packets)
        packet.envelope.request_id = allocate_command_request_id();
    // This is a consequence of the completed day. Admit it to the executor's
    // next-day inbox, which the existing pending-command checkpoint preserves.
    if (!packets.empty() && !enqueue_batch_at(std::move(packets), nullptr, false))
        return "weather_research_event_admission_failed";
    return nullptr;
}

} // namespace pk
