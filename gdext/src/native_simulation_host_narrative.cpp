#include "native_simulation_day_context.h"

#include "economy_api.h"
#include "runtime_narrative.h"
#include "runtime_world_environment.h"

#include <algorithm>
#include <cmath>
#include <string_view>

namespace pk {
using namespace godot;

namespace {

constexpr uint64_t NARRATIVE_CONSUMER = [] {
    uint64_t result = 1469598103934665603ull;
    for (char c : std::string_view("narrative_event_service"))
        result = (result ^ uint8_t(c)) * 1099511628211ull;
    return result;
}();

int32_t slot_for(const RuntimeCountryPodSnapshot &country, uint64_t handle) {
    const auto slot = static_cast<uint32_t>(handle);
    return slot < country.country_count && country.country_active[slot] &&
        country.country_generation[slot] == static_cast<uint32_t>(handle >> 32) ?
        static_cast<int32_t>(slot) : -1;
}

uint64_t owner_for(const RuntimeCountryPodSnapshot &country, int32_t cell) {
    if (cell < 0 || size_t(cell) >= country.cell_country_slot.size()) return 0;
    const int32_t slot = country.cell_country_slot[cell];
    if (slot < 0 || size_t(slot) >= country.country_count || !country.country_active[slot]) return 0;
    return (uint64_t(country.country_generation[slot]) << 32) | uint32_t(slot);
}

template <class T>
T sample_at(const std::vector<T> &column, int32_t cell, T fallback) {
    return cell >= 0 && size_t(cell) < column.size() ? column[cell] : fallback;
}

NarrativeCellView sample_geography(const RuntimeEnvironmentSnapshot &geo, int32_t cell,
        uint64_t handle, const RuntimeCountryPodSnapshot &country) {
    NarrativeCellView sampled;
    sampled.cell = cell;
    if (cell < 0 || uint32_t(cell) >= geo.cell_count) return sampled;
    sampled.terrain = sample_at(geo.terrain, cell, uint8_t(2));
    sampled.landform = sample_at(geo.landform, cell, uint8_t(4));
    sampled.vegetation = sample_at(geo.vegetation, cell, uint8_t(0));
    sampled.cover = sample_at(geo.cover, cell, uint8_t(0));
    sampled.temperature = sample_at(geo.cell_temp, cell, 18.0f);
    sampled.moisture = sample_at(geo.cell_moisture, cell, 0.5f);
    sampled.elevation = sample_at(geo.cell_elevation, cell, 0.5f);
    sampled.snow = sample_at(geo.cell_snow_cover, cell, 0.0f);
    sampled.precipitation = sample_at(geo.cell_weather_precip, cell, 0.0f);
    sampled.river = sample_at(geo.has_river, cell, uint8_t(0)) != 0;
    sampled.coastal = sampled.landform == 2 || sampled.landform == 9;
    const auto current = [&](int32_t at) {
        const float x = sample_at(geo.cell_ocean_current_x, at, 0.0f);
        const float y = sample_at(geo.cell_ocean_current_y, at, 0.0f);
        return double(std::sqrt(x * x + y * y));
    };
    sampled.current = current(cell);
    const auto collect = [&](int32_t center, std::vector<int32_t> &cells) {
        for (int32_t dir = 0; dir < 6; ++dir) {
            const int32_t neighbor = sample_at(geo.neighbor_indices, center * 6 + dir, -1);
            if (neighbor < 0 || neighbor == cell || owner_for(country, neighbor) != handle ||
                sample_at(geo.is_water, neighbor, uint8_t(0))) continue;
            cells.push_back(neighbor);
        }
    };
    for (int32_t dir = 0; dir < 6; ++dir) {
        const int32_t neighbor = sample_at(geo.neighbor_indices, cell * 6 + dir, -1);
        if (neighbor >= 0 && sample_at(geo.is_water, neighbor, uint8_t(0))) {
            sampled.coastal = true;
            sampled.current = std::max(sampled.current, current(neighbor));
        }
    }
    collect(cell, sampled.nearby[0]);
    for (int32_t dir = 0; dir < 6; ++dir) {
        const int32_t neighbor = sample_at(geo.neighbor_indices, cell * 6 + dir, -1);
        if (neighbor >= 0) collect(neighbor, sampled.nearby[1]);
    }
    for (auto &ring : sampled.nearby) {
        std::sort(ring.begin(), ring.end());
        ring.erase(std::unique(ring.begin(), ring.end()), ring.end());
    }
    auto &second = sampled.nearby[1];
    second.erase(std::remove_if(second.begin(), second.end(), [&](int32_t value) {
        return std::binary_search(sampled.nearby[0].begin(), sampled.nearby[0].end(), value);
    }), second.end());
    return sampled;
}

} // namespace

bool NativeSimulationHost::initialize_narrative(const Dictionary &packet, const Dictionary &saved) {
    if (!execution_has_stopped()) return false;
    auto narrative = std::make_shared<RuntimeNarrative>();
    if (!narrative->configure(packet, saved)) return false;
    std::atomic_store(&_published_narrative, narrative->view());
    _executor_narrative = std::move(narrative);
    return true;
}

std::shared_ptr<const RuntimeNarrativeView> NativeSimulationHost::latest_narrative() const {
    return std::atomic_load(&_published_narrative);
}

Dictionary NativeSimulationHost::capture_narrative() const {
    std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
    return _executor_narrative ? _executor_narrative->capture() : Dictionary();
}

bool NativeSimulationHost::narrative_needs_choice() const {
    const auto view = latest_narrative();
    return _world_environment && view && !view->active_offer.is_empty();
}

void RuntimeNarrative::sample_country(const RuntimeCountryPodSnapshot &country,
        NarrativeCountryView &out) const {
    const int32_t slot = slot_for(country, out.handle);
    if (slot < 0) return;
    out.slot = slot;
    out.capital = country.capital_cell[slot];
    out.name = country.country_display_names[slot];
    out.treasury_cash = country.country_cash[slot];
    out.territory.assign(country.territory_cells.begin() + country.territory_offsets[slot],
        country.territory_cells.begin() + country.territory_offsets[slot + 1]);
    const auto completed = [&](int32_t technology) {
        return technology >= 0 && uint32_t(technology) < country.technology_count &&
            (country.country_technologies[size_t(slot) * country.technology_words +
                technology / 64] & (1ull << (technology % 64)));
    };
    for (size_t technology = 0; technology < _catalog.technology_ids.size(); ++technology)
        if (completed(technology)) out.technologies.insert(_catalog.technology_ids[technology]);
    for (size_t era = 0; era < _catalog.era_milestones.size(); ++era)
        if (completed(_catalog.era_milestones[era])) out.era = era;
    for (size_t index = 0; index < _catalog.good_ids.size() && index < country.good_count; ++index) {
        const int64_t quantity = country.country_goods[size_t(slot) * country.good_count + index];
        if (quantity > 0) out.treasury_goods.emplace(_catalog.good_ids[index], quantity);
    }
}

NarrativeDay NativeSimulationHost::sample_narrative_day(int64_t day) const {
    const auto *country = _country_pod_authority.borrow_state();
    const auto &geo = _world_environment->narrative_geography();
    const auto *economy = _economy_production_runtime;
    const uint64_t handle = _executor_narrative->player();
    NarrativeCountryView player;
    player.handle = handle;
    if (country) {
        _executor_narrative->sample_country(*country, player);
        sample_narrative_military(player);
    }
    static const std::vector<std::string> empty;
    return {day, std::move(player),
        [country, &geo, economy, handle](int32_t cell, bool detailed) {
            auto sample = country ? sample_geography(geo, cell, handle, *country) : NarrativeCellView{};
            if (economy) economy_api::sample_narrative_cell(*economy, sample, detailed);
            return sample;
        },
        [country](int32_t cell) { return country ? owner_for(*country, cell) : uint64_t(0); },
        [country](uint64_t handle) {
            const int32_t slot = country ? slot_for(*country, handle) : -1;
            return slot >= 0 ? country->territory_count[slot] : 0;
        },
        [economy](int32_t cell, std::vector<NarrativeUnrestRow> &rows) {
            return economy && economy_api::narrative_unrest_rows(*economy, cell, rows);
        },
        [economy](int32_t cell, int32_t profession, int32_t action) {
            return economy ? economy_api::narrative_unrest_odds(*economy, cell, profession, action)
                : NarrativeUnrestOdds{};
        },
        economy ? economy_api::narrative_professions(*economy) : empty};
}

const char *NativeSimulationHost::stage_narrative(DayExecution &day) {
    if (!_executor_narrative || !_world_environment || !events_worker_authoritative()) return nullptr;
    const auto &events = _events_authority.snapshot();
    const auto ack = std::lower_bound(events.consumer_acks.begin(), events.consumer_acks.end(),
        NARRATIVE_CONSUMER, [](const auto &row, uint64_t key) { return row.consumer_key < key; });
    const int64_t day_index = day.plan.context.day;
    const int64_t next = _executor_narrative->step(sample_narrative_day(day_index), events.events,
        ack == events.consumer_acks.end() || ack->consumer_key != NARRATIVE_CONSUMER ? 0 : ack->event_id);
    if (next >= 0 && !enqueue_event_consumer_ack(NARRATIVE_CONSUMER, next, day_index + 1,
            _generation.load(std::memory_order_relaxed) + 1, false))
        return "narrative_events_ack_dispatch_failed";
    if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
    _executor_day_tail->narrative = _executor_narrative->view();
    return nullptr;
}

bool NativeSimulationHost::submit_narrative_choice_request(
        std::shared_ptr<RuntimeNarrativeRequest> request) {
    std::unique_lock<std::mutex> control(_control_mutex);
    const auto available = [&] {
        const auto current = state();
        return _executor_narrative && _world_environment && current != RuntimeWorkerState::STOPPED &&
            current != RuntimeWorkerState::FAULTED && current != RuntimeWorkerState::STOPPING &&
            !_stop_requested.load(std::memory_order_acquire);
    };
    if (!available()) return false;
    _narrative_requests.push_back(request);
    if (inline_daily_mode()) {
        control.unlock();
        service_narrative_requests();
        return request->done;
    }
    _control_cv.notify_all();
    _control_cv.wait(control, [&] { return request->done || !available(); });
    return request->done;
}

bool NativeSimulationHost::service_narrative_requests() {
    std::deque<std::shared_ptr<RuntimeNarrativeRequest>> requests;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        requests.swap(_narrative_requests);
    }
    if (requests.empty()) return false;
    {
        std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
        auto &narrative = *_executor_narrative;
        const int64_t day = _committed_day.load(std::memory_order_acquire);
        for (const auto &request : requests) {
            using Kind = RuntimeNarrativeRequest::Kind;
            if (request->kind == Kind::CHOOSE) {
                request->result = narrative.begin_choice(sample_narrative_day(day), request->args);
            } else if (request->kind == Kind::SOURCE_ID) {
                if (narrative.placing_choice()) request->result["id"] = narrative.allocate_modifier_source();
            } else if (request->kind == Kind::COMPLETE) {
                const auto &record = narrative.choice_record();
                const Dictionary meta = record.get("meta", Dictionary());
                if (_economy_production_runtime && String(meta.get("kind", "")) == "rebellion" &&
                    int64_t(record.get("offer_id", -1)) == int64_t(request->args.get("offer_id", -2))) {
                    const Array actions = meta.get("actions", Array());
                    const int32_t option = record.get("chosen_option_index", -1);
                    if (option >= 0 && option < actions.size()) {
                        const int32_t action = actions[option];
                        const int32_t cell = meta.get("cell", -1);
                        const int32_t profession = meta.get("profession", -1);
                        const bool success = int32_t(record.get("rolled_outcome_index", 1)) == 0;
                        const bool applied = economy_api::settle_narrative_unrest(
                            *_economy_production_runtime, cell, profession, action, success);
                        narrative.finish_unrest_choice(applied);
                    }
                }
                request->result = narrative.complete_choice(request->args);
            } else if (request->kind == Kind::AI_RESULT) {
                request->result = narrative.accept_ai(sample_narrative_day(
                    request->args.get("arrival_day", day)), request->args);
            } else if (request->kind == Kind::SET_AI) {
                narrative.set_ai_enabled(request->args.get("enabled", false));
                request->result["ok"] = true;
            }
        }
        std::atomic_store(&_published_narrative, narrative.view());
    }
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        for (const auto &request : requests) request->done = true;
        _control_cv.notify_all();
    }
    return true;
}

} // namespace pk
