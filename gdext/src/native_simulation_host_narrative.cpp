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
        uint64_t handle, const RuntimeCountryPodSnapshot &country,
        const RuntimeClimateStore &climate, const RuntimeSeasonView *season,
        const pk_async_physics::RuntimeClimatePhysicsState *physics) {
    NarrativeCellView sampled;
    sampled.cell = cell;
    if (cell < 0 || uint32_t(cell) >= geo.cell_count) return sampled;
    const bool committed = climate.committed_day >= 0;
    sampled.terrain = sample_at(committed ? climate.terrain : geo.terrain, cell, uint8_t(2));
    sampled.landform = sample_at(season ? season->landform : geo.landform, cell, uint8_t(4));
    sampled.vegetation = sample_at(committed ? climate.vegetation : geo.vegetation, cell, uint8_t(0));
    sampled.cover = sample_at(committed ? climate.cover : geo.cover, cell, uint8_t(0));
    sampled.temperature = sample_at(committed ? climate.temperature : geo.cell_temp, cell, 18.0f);
    sampled.moisture = sample_at(committed ? climate.moisture : geo.cell_moisture, cell, 0.5f);
    sampled.elevation = sample_at(geo.cell_elevation, cell, 0.5f);
    sampled.snow = sample_at(committed ? climate.snow_cover : geo.cell_snow_cover, cell, 0.0f);
    sampled.precipitation = sample_at(committed ? climate.weather_precipitation : geo.cell_weather_precip, cell, 0.0f);
    sampled.vapor = sample_at(committed ? climate.vapor : geo.cell_weather_vapor, cell, 0.0f);
    sampled.clouds = sample_at(committed ? climate.cloud_cover : geo.cell_weather_cloud, cell, 0.0f);
    const auto &upwelling = physics ? physics->upwelling : geo.climate_physics_seed_upwelling;
    sampled.upwelling = sample_at(upwelling, cell, 0.0f);
    sampled.river = sample_at(geo.has_river, cell, uint8_t(0)) != 0;
    sampled.coastal = sampled.landform == 2 || sampled.landform == 9;
    const auto current = [&](int32_t at) {
        const float x = sample_at(physics ? physics->ocean_current_x : geo.cell_ocean_current_x, at, 0.0f);
        const float y = sample_at(physics ? physics->ocean_current_y : geo.cell_ocean_current_y, at, 0.0f);
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
            sampled.upwelling = std::max(sampled.upwelling, double(sample_at(upwelling, neighbor, 0.0f)));
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
    if (!narrative->configure(packet, saved.is_empty() ? _restored_narrative : saved)) return false;
    _restored_narrative = Dictionary();
    _executor_narrative = std::move(narrative);
    publish_narrative_boundary(_committed_day.load(std::memory_order_acquire));
    return true;
}

bool NativeSimulationHost::restore_narrative_checkpoint(const Dictionary &saved) {
    if (!execution_has_stopped()) return false;
    _restored_narrative = saved.duplicate(true);
    return true;
}

void NativeSimulationHost::publish_narrative_boundary(int64_t day) {
    if (_executor_narrative)
        std::atomic_store(&_published_narrative, _executor_narrative->view(day));
}

std::shared_ptr<const RuntimeNarrativeView> NativeSimulationHost::latest_narrative() const {
    return std::atomic_load(&_published_narrative);
}

Dictionary NativeSimulationHost::capture_narrative() const {
    std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
    return _executor_narrative ? _executor_narrative->capture() : _restored_narrative.duplicate(true);
}

const char *NativeSimulationHost::narrative_input_block() const {
    const auto view = latest_narrative();
    if (!_world_environment || !view) return nullptr;
    if (!view->active_offer.is_empty()) return "narrative_choice_required";
    if (view->waiting_for_external_input_day >= 0) return "narrative_external_input_required";
    return nullptr;
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
    const auto &climate = _climate_authority.store();
    const auto season = _world_environment->season_view(day);
    const auto physics = _climate_authority.copy_committed_physics();
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
        [country, &geo, &climate, season, economy, handle, physics](int32_t cell, bool detailed) {
            auto sample = country ? sample_geography(geo, cell, handle, *country, climate,
                season.get(), physics && physics->ready ? physics.get() : nullptr)
                                  : NarrativeCellView{};
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
    if (_economy_production_runtime) {
        _executor_narrative->settle_economy_effects([&](int64_t request, std::string &error) {
            bool complete = false, ok = false;
            if (!economy_api::effect_command_result_pod(*_economy_production_runtime,
                    request, complete, ok, error)) return true;
            if (complete && !ok && error.empty()) error = "narrative_effect_economy_failed";
            return complete;
        });
    }
    const auto input = sample_narrative_day(day_index);
    const int64_t next = _executor_narrative->step(input, events.events,
        ack == events.consumer_acks.end() || ack->consumer_key != NARRATIVE_CONSUMER ? 0 : ack->event_id);
    if (_economy_production_runtime)
        _executor_narrative->economy_notices(input, economy_api::narrative_economy_notices(
            *_economy_production_runtime, day_index, input.country.handle));
    if (!dispatch_narrative_independence(day_index + 1))
        return "narrative_independence_dispatch_failed";
    if (next >= 0 && !enqueue_event_consumer_ack(NARRATIVE_CONSUMER, next, day_index + 1,
            _generation.load(std::memory_order_relaxed) + 1, false))
        return "narrative_events_ack_dispatch_failed";
    if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
    _executor_narrative->queue_automatic_choice(day_index + 1);
    _executor_day_tail->narrative = _executor_narrative->view(day_index);
    _executor_day_tail->notices = _executor_narrative->take_notices();
    return nullptr;
}

bool NativeSimulationHost::prepare_narrative_day(int64_t day) {
    if (!_executor_narrative || !_world_environment) return false;
    auto &narrative = *_executor_narrative;
    narrative.apply_pause_policy(day);
    narrative.apply_ai_policy(day);
    narrative.queue_automatic_choice(day);
    const auto choice = narrative.take_due_choice(day);
    if (choice.is_empty()) return false;
    if (!bool(resolve_narrative_choice(day - 1, choice).get("ok", false)))
        set_fault("narrative_choice_apply_failed");
    return true;
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
                request->result = narrative.queue_choice(day + 1, request->args);
            } else if (request->kind == Kind::PAUSE_POLICY) {
                // A stopped day has no simulation work ahead of the pending reply.
                // A policy can replace that reply with an automatic choice on D+1.
                const auto view = narrative.view(day);
                const int64_t effective_day = view->active_offer.is_empty() ?
                    std::max(day + 1, command_seal_day()) : day + 1;
                narrative.set_pause_policy(effective_day,
                    static_cast<uint16_t>(int32_t(request->args.get("mask", 255))));
                request->result["ok"] = true;
                request->result["effective_day"] = effective_day;
            } else if (request->kind == Kind::AI_RESULT) {
                request->result = narrative.queue_ai_reply(request->args);
            } else if (request->kind == Kind::SET_AI) {
                const int64_t effective_day = std::max(day + 1,
                    int64_t(request->args.get("effective_day", day + 1)));
                narrative.set_ai_enabled(effective_day, request->args.get("enabled", false));
                request->result["ok"] = true;
                request->result["effective_day"] = effective_day;
            }
        }
        publish_narrative_boundary(day);
    }
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        for (const auto &request : requests) request->done = true;
        _control_cv.notify_all();
    }
    return true;
}

} // namespace pk
