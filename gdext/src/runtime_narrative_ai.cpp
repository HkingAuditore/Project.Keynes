#include "runtime_narrative.h"

#include <algorithm>
#include <cmath>

namespace pk {
using namespace godot;

namespace {
bool owns(const NarrativeCountryView &country, int32_t cell) {
    return std::find(country.territory.begin(), country.territory.end(), cell) != country.territory.end();
}
String text(const std::string &value) { return String::utf8(value.c_str()); }
} // namespace

int RuntimeNarrative::ai_pressure(const NarrativeCountryView &country, const NarrativeCellView &cell) {
    // The legacy price and shortage lanes are empty. Keep their contribution
    // zero until the sampler corrections are made together with effect parity.
    int score = std::clamp<int>(std::lround((0.6 - cell.satisfaction) * 100.0), 0, 25);
    const double stress = cell.temperature >= 30.0 ? (cell.temperature - 30.0) / 10.0 :
        std::max(0.0, -cell.temperature) / 15.0;
    score += std::clamp<int>(std::lround(stress * 20.0), 0, 20);
    score += std::clamp<int>(std::lround((cell.snow - 0.35) * 40.0), 0, 10);
    if (country.at_war) score += country.war_score <= -32768 ? 25 : 15;
    if (cell.family != 0 && cell.prestige >= 3) score += 8;
    return std::min(100, score);
}

bool RuntimeNarrative::ai_allowed(int64_t day) const {
    return _pending_ai.is_empty() && (_last_ai <= NEVER || day - _last_ai >= 60);
}

bool RuntimeNarrative::request_ai(const NarrativeDay &input, const NarrativeCellView &cell,
        const Followup &item, const String &fact, const std::string &state,
        const String &state_hint, bool scheduled) {
    if (!ai_allowed(input.day)) return false;
    Dictionary request;
    request["ai_request_seq"] = _next_ai++;
    request["day"] = input.day;
    request["due_day"] = item.due;
    request["scheduled_followup"] = scheduled;
    request["cell_idx"] = cell.cell;
    request["chain_id"] = text(item.chain);
    request["ai_prompt_hint"] = item.hint;
    request["fact_hint"] = fact;
    request["state_id"] = text(state);
    request["state_hint"] = state_hint;
    request["cell_ctx"] = context(input, cell);
    Array recent;
    for (size_t i = 0; i < std::min<size_t>(3, _chronicle.size()); ++i)
        recent.push_back(_chronicle[i]);
    request["recent_chronicle"] = recent;
    _last_ai = input.day;
    _pending_ai = request;
    _ai_request = request;
    return true;
}

bool RuntimeNarrative::probe_matches(const NarrativeProbe &probe, const NarrativeDay &input,
        const NarrativeCellView &cell) const {
    return !probe.id.empty() && !probe.conditions.code.empty() &&
        input.country.era >= probe.min_era && input.country.era <= probe.max_era &&
        probe.conditions.matches(input.country, cell,
            [&](const std::string &flag) { return flag_present(flag, cell.cell); });
}

void RuntimeNarrative::poll_probes(const NarrativeDay &input) {
    if (input.country.territory.empty()) return;
    auto cells = sampled_cells(input);
    for (const auto &row : _tracking) {
        if (row.cell >= 0 && cells.size() < 16 &&
            std::find(cells.begin(), cells.end(), row.cell) == cells.end())
            cells.push_back(row.cell);
    }
    for (int32_t cell : cells) {
        const auto sample = input.sample(cell, true);
        for (const auto &probe : _catalog.probes) {
            const auto key = probe.id + ":" + std::to_string(cell);
            auto row = std::find_if(_tracking.begin(), _tracking.end(), [&](const auto &current) {
                return current.key == key;
            });
            if (!probe_matches(probe, input, sample)) {
                if (row != _tracking.end()) _tracking.erase(row);
                continue;
            }
            if (row == _tracking.end()) {
                _tracking.push_back({key, cell, input.day, input.day, 1.0, sample.satisfaction});
                row = std::prev(_tracking.end());
            } else {
                row->seen = input.day;
                row->min_satisfaction = std::min(row->min_satisfaction, sample.satisfaction);
            }
            const auto seeded = _last_seed.find(key);
            const int64_t held = input.day - row->since;
            if (!_ai_enabled || held < probe.dwell ||
                narrative_key(_pending_ai.get("state_id", "")) == probe.id ||
                (seeded != _last_seed.end() && input.day - seeded->second < probe.cooldown)) continue;
            const bool has_pooled = std::any_of(_pool.begin(), _pool.end(),
                [&](const auto &entry) { return entry.state == probe.id; });
            if (has_pooled) {
                for (auto entry = _pool.begin(); entry != _pool.end(); ++entry) {
                    if (entry->state != probe.id || (entry->cell >= 0 && entry->cell != cell)) continue;
                    if (enqueue(entry->definition, input, cell)) {
                        _last_seed[key] = input.day;
                        _pool.erase(entry);
                    }
                    break;
                }
                continue;
            }
            if (!ai_allowed(input.day)) continue;
            auto hint = String::utf8("状态：") + probe.description;
            const auto prompt = probe.prompt.strip_edges();
            if (!prompt.is_empty()) hint += String::utf8("；") + prompt;
            hint += String::utf8("；已持续 ") + String::num_int64(held) +
                String::utf8(" 日；本地人口 ") + String::num_int64(sample.population) +
                String::utf8("，当前满意度 ") + narrative_percent(sample.satisfaction) +
                String::utf8("%；期间最高价格比 1.00；期间最低满意度 ") +
                narrative_percent(row->min_satisfaction) + "%";
            if (request_ai(input, sample, {input.day + 1, 0, cell, {}, {}, {}}, {}, probe.id, hint))
                _last_seed[key] = input.day;
        }
    }
}

void RuntimeNarrative::flush_pool(const NarrativeDay &input) {
    if (_pool.empty() || paced(input.day)) return;
    int32_t attempts = 0;
    for (auto entry = _pool.begin(); entry != _pool.end() && attempts < 4;) {
        const auto probe = std::find_if(_catalog.probes.begin(), _catalog.probes.end(),
            [&](const auto &probe) { return probe.id == entry->state; });
        if (input.day - entry->created > 365 || probe == _catalog.probes.end()) {
            entry = _pool.erase(entry);
            continue;
        }
        ++attempts;
        const int32_t cell = !input.country.territory.empty() && !owns(input.country, entry->cell)
            ? input.country.territory.front() : entry->cell;
        if (cell < 0 || !probe_matches(*probe, input, input.sample(cell, true)) ||
            !enqueue(entry->definition, input, cell)) {
            ++entry;
            continue;
        }
        _last_seed[entry->state + ":" + std::to_string(cell)] = input.day;
        entry = _pool.erase(entry);
    }
}

void RuntimeNarrative::store_ai(const std::string &state, NarrativeDefinition &&def,
        int32_t cell, int64_t day) {
    // Match the persisted pool order: other states first, then this state's
    // retained entry and the newly produced one.
    const auto start = std::stable_partition(_pool.begin(), _pool.end(),
        [&](const auto &row) { return row.state != state; });
    if (std::distance(start, _pool.end()) >= 2)
        _pool.erase(start, std::prev(_pool.end()));
    _pool.push_back({_next_pool++, day, cell, state, std::move(def)});
    if (_pool.size() > 24) _pool.erase(_pool.begin());
}

Dictionary RuntimeNarrative::accept_ai(const NarrativeDay &input, const Dictionary &result) {
    const auto sequence = int64_t(result.get("ai_request_seq", -1));
    if (_pending_ai.is_empty() || sequence != int64_t(_pending_ai.get("ai_request_seq", 0)))
        return narrative_response(false, "ai_request_unknown");
    const Dictionary pending = _pending_ai;
    _pending_ai = Dictionary();
    _ai_request = Dictionary();
    if (!bool(result.get("ok", false))) {
        auto failed = narrative_response(false, "ai_generation_failed");
        failed["code"] = result.get("code", "ai_generation_failed");
        return failed;
    }
    auto def = _catalog.compile_event(result.get("definition", Dictionary()));
    if (def.id.empty()) return narrative_response(false, "ai_definition_missing");
    if (input.day - int64_t(pending.get("day", input.day)) > 60)
        return narrative_response(false, "ai_result_stale");

    const int32_t target = pending.get("cell_idx", -1);
    const int32_t cell = !input.country.territory.empty() && !owns(input.country, target)
        ? input.country.territory.front() : target;
    const auto chain = narrative_key(pending.get("chain_id", ""));
    if (bool(pending.get("scheduled_followup", false))) {
        const auto id = def.id;
        _dynamic.insert_or_assign(id, std::move(def));
        _followups.push_back({std::max<int64_t>(input.day, pending.get("due_day", input.day)),
            0, cell, id, chain, {}});
        auto response = narrative_response(true, "ok");
        response["scheduled"] = true;
        return response;
    }
    const auto state = narrative_key(pending.get("state_id", ""));
    const auto probe = std::find_if(_catalog.probes.begin(), _catalog.probes.end(),
        [&](const auto &entry) { return entry.id == state; });
    if ((state.empty() || (probe != _catalog.probes.end() &&
            probe_matches(*probe, input, input.sample(cell, true)))) &&
        enqueue(def, input, cell, chain)) {
        const auto id = def.id;
        _dynamic.insert_or_assign(id, std::move(def));
        return narrative_response(true, "ok");
    }
    if (state.empty()) return narrative_response(false, "ai_paced_out");
    store_ai(state, std::move(def), cell, input.day);
    return narrative_response(true, "ai_event_pooled");
}

} // namespace pk
