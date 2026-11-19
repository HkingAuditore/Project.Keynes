#include "runtime_narrative.h"

#include "runtime_events_authority.h"

#include <algorithm>
#include <cstdlib>
#include <numeric>

namespace pk {
using namespace godot;

namespace {
constexpr int64_t ONE = 65536;
constexpr int64_t POPUP_GAP = 60;
constexpr int64_t PROBE_INTERVAL = 7;
constexpr int64_t PULSE_INTERVAL = 20;
constexpr int32_t SAMPLE_CELLS = 8;

std::string scoped_key(const std::string &key, int32_t cell) {
    return cell < 0 ? "country:" + key : "cell:" + std::to_string(cell) + ":" + key;
}

std::string annual_cell_key(int64_t year, int32_t cell) {
    return std::to_string(year) + ":" + std::to_string(cell);
}

bool contains(const std::vector<int32_t> &cells, int32_t cell) {
    return std::find(cells.begin(), cells.end(), cell) != cells.end();
}
} // namespace

bool RuntimeNarrative::configure(const Dictionary &packet, const Dictionary &archive) {
    if (!_catalog.configure(packet)) return false;
    _country = int64_t(packet.get("country", 0));
    _seed = std::max<int64_t>(1, packet.get("seed", 1));
    _days_per_year = std::max<int64_t>(1, packet.get("days_per_year", 365));
    _ai_enabled = packet.get("ai_enabled", false);
    restore(archive);
    return _country != 0;
}

bool RuntimeNarrative::paced(int64_t day) const {
    return _last_popup > NEVER && day - _last_popup < POPUP_GAP;
}

bool RuntimeNarrative::cell_capped(int32_t cell, int64_t day) const {
    if (cell < 0) return false;
    const auto it = _year_counts.find(annual_cell_key(day / _days_per_year, cell));
    return it != _year_counts.end() && it->second >= 2;
}

int64_t RuntimeNarrative::roll(int64_t day, int32_t cell, int64_t salt) const {
    return narrative_roll(_seed, day, _country, cell, salt);
}

int64_t RuntimeNarrative::pick(const std::vector<int64_t> &weights,
        int64_t day, int32_t cell, int64_t salt) const {
    const int64_t total = std::accumulate(weights.begin(), weights.end(), int64_t(0));
    if (total <= 0) return -1;
    int64_t target = narrative_hash(_seed, day, _country, cell, salt) % total;
    for (size_t i = 0; i < weights.size(); ++i) {
        if (target < weights[i]) return static_cast<int64_t>(i);
        target -= weights[i];
    }
    return -1;
}

std::vector<int32_t> RuntimeNarrative::sampled_cells(const NarrativeDay &input) const {
    const auto &territory = input.country.territory;
    if (territory.size() <= SAMPLE_CELLS) return territory;
    std::vector<int32_t> cells{territory.front()};
    for (int32_t attempt = 1; cells.size() < SAMPLE_CELLS && attempt <= SAMPLE_CELLS * 3; ++attempt) {
        const int32_t cell = territory[narrative_hash(_seed, input.day, _country, attempt,
            0x43454C4C) % territory.size()];
        if (!contains(cells, cell)) cells.push_back(cell);
    }
    return cells;
}

const NarrativeDefinition *RuntimeNarrative::definition(const std::string &id) const {
    const auto found = _dynamic.find(id);
    return found == _dynamic.end() ? _catalog.find(id) : &found->second;
}

bool RuntimeNarrative::flag_present(const std::string &key, int32_t cell) const {
    return !key.empty() && (_flags.count(key) || _flags.count(scoped_key(key, -1)) ||
        (cell >= 0 && _flags.count(scoped_key(key, cell))));
}

int32_t RuntimeNarrative::weight(const NarrativeDefinition &def, const NarrativeDay &input,
        const NarrativeCellView &cell) const {
    if (def.id.empty() || (def.one_shot && _completed.count(def.id))) return 0;
    const auto cd = _cooldowns.find(scoped_key(def.id, def.scope == 0 ? cell.cell : -1));
    if (cd != _cooldowns.end() && input.day < cd->second) return 0;
    const auto &country = input.country;
    if (country.era < def.min_era || country.era > def.max_era) return 0;
    for (const auto &key : def.required_tech)
        if (!key.empty() && !country.technologies.count(key)) return 0;
    for (const auto &key : def.blocked_tech)
        if (!key.empty() && country.technologies.count(key)) return 0;
    for (const auto &key : def.prerequisites)
        if (!key.empty() && !_completed.count(key)) return 0;
    const auto flag = [&](const std::string &key) { return flag_present(key, cell.cell); };
    for (const auto &key : def.required_flags)
        if (!key.empty() && !flag(key)) return 0;
    for (const auto &key : def.blocked_flags)
        if (flag(key)) return 0;
    if (!def.conditions.matches(country, cell, flag)) return 0;
    int64_t add = def.base_weight, factor = ONE;
    for (const auto &rule : def.weights) {
        if (rule.conditions.matches(country, cell, flag)) {
            add += rule.add;
            factor = factor * std::max(0, rule.factor) / ONE;
        }
    }
    for (const auto &bias : _biases) {
        if (bias.cell >= 0 && bias.cell != cell.cell) continue;
        if ((!bias.event.empty() && bias.event == def.id) ||
            (!bias.tag.empty() && std::find(def.tags.begin(), def.tags.end(), bias.tag) != def.tags.end())) {
            add += bias.add;
            if (bias.factor > 0) factor = factor * bias.factor / ONE;
        }
    }
    return static_cast<int32_t>(std::clamp<int64_t>(
        std::max<int64_t>(0, add) * std::max<int64_t>(0, factor) / ONE, 0, 1000000));
}

void RuntimeNarrative::local_effect(const NarrativeEffect &effect, int32_t cell, int64_t effective) {
    const int32_t scope = effect.cell_scope ? cell : -1;
    const auto &key = effect.key;
    const int64_t expires = effect.duration < 0 ? -1 : effective + effect.duration;
    switch (effect.kind) {
        case NarrativeEffect::SET_FLAG:
            if (!key.empty()) _flags[scoped_key(key, scope)] = {
                effective, expires, std::max<int64_t>(1, effect.value)};
            break;
        case NarrativeEffect::CLEAR_FLAG:
            _flags.erase(key);
            _flags.erase(scoped_key(key, -1));
            if (scope >= 0) _flags.erase(scoped_key(key, scope));
            break;
        case NarrativeEffect::WEIGHT_BIAS:
            _biases.push_back({_next_bias++, effect.value, std::max<int64_t>(0, effect.magnitude),
                effect.duration == 0 ? effective + 1 : expires, scope, key, effect.tag, {}});
            break;
        case NarrativeEffect::SCHEDULE:
            _followups.push_back({effective + std::max<int64_t>(1, effect.duration),
                0, cell, key, effect.tag, effect.ai_prompt});
            break;
    }
}

void RuntimeNarrative::promote(int64_t day) {
    if (!_active.is_empty()) return;
    for (auto it = _queue.begin(); it != _queue.end();) {
        const bool bypass = it->get("bypass_pacing", false);
        const int32_t cell = it->get("cell_idx", -1);
        if (!bypass && cell_capped(cell, day)) {
            it = _queue.erase(it);
            continue;
        }
        if (!bypass && paced(day)) {
            ++it;
            continue;
        }
        _active = *it;
        _queue.erase(it);
        _last_popup = day;
        if (cell >= 0 && !bypass) {
            const int64_t year = day / _days_per_year;
            ++_year_counts[annual_cell_key(year, cell)];
            for (auto entry = _year_counts.begin(); entry != _year_counts.end();) {
                if (std::strtoll(entry->first.c_str(), nullptr, 10) < year - 1)
                    entry = _year_counts.erase(entry);
                else ++entry;
            }
        }
        return;
    }
}

void RuntimeNarrative::prune(int64_t day) {
    const auto erase_map = [](auto &map, const auto &test) {
        for (auto entry = map.begin(); entry != map.end();) {
            if (test(entry->second)) entry = map.erase(entry);
            else ++entry;
        }
    };
    erase_map(_flags, [&](const auto &flag) { return flag.expires >= 0 && day > flag.expires; });
    erase_map(_cooldowns, [&](int64_t expiry) { return day >= expiry; });
    erase_map(_last_seed, [&](int64_t seeded) { return day - seeded > 730; });
    _biases.erase(std::remove_if(_biases.begin(), _biases.end(), [&](const auto &bias) {
        return bias.expires >= 0 && day > bias.expires;
    }), _biases.end());
    _tracking.erase(std::remove_if(_tracking.begin(), _tracking.end(), [&](const auto &row) {
        return day - row.seen > 60;
    }), _tracking.end());
    if (!_pending_ai.is_empty() && day - int64_t(_pending_ai.get("day", day)) > 60) {
        _pending_ai.clear();
        _ai_request = Dictionary();
    }
}

void RuntimeNarrative::followups(const NarrativeDay &input) {
    auto scheduled = std::move(_followups);
    _followups.clear();
    for (auto &item : scheduled) {
        const auto &territory = input.country.territory;
        const int32_t cell = !territory.empty() && !contains(territory, item.cell) ?
            territory.front() : item.cell;
        if (item.event.empty() && !_ai_request.has("ai_request_seq") && _ai_enabled &&
            !item.hint.strip_edges().is_empty() && !item.requested && input.day >= item.due - 3) {
            item.requested = request_ai(input, input.sample(cell, false), item, {}, {}, {}, true);
        }
        if (input.day >= item.due) {
            if (const auto *def = definition(item.event)) enqueue(*def, input, cell, item.chain, true);
        } else {
            _followups.push_back(std::move(item));
        }
    }
}

void RuntimeNarrative::fact(const NarrativeDay &input, const RuntimeEventsRecord &event,
        size_t index, bool &hit) {
    const auto &territory = input.country.territory;
    if (event.cell_idx >= 0 && !territory.empty() && !contains(territory, event.cell_idx)) return;
    const int32_t cell = event.cell_idx < 0 && !territory.empty() ? territory.front() : event.cell_idx;
    const auto sampled = input.sample(cell, true);
    if (cell >= 0 && _ai_enabled && ai_allowed(input.day) && _catalog.ai_fact_hints.has(event.type)) {
        const int32_t chance = 13107 + (26214 - 13107) * ai_pressure(input.country, sampled) / 100;
        if (roll(input.day, cell, 0x464149 + event.type) < chance) {
            const String hint = String(_catalog.ai_fact_hints[event.type]) + String::utf8("（") +
                String::utf8(sampled.settlement.c_str()) + String::utf8("，第 ") +
                String::num_int64(input.day) + String::utf8(" 日）");
            request_ai(input, sampled, {input.day + 1, 0, cell, {}, {}, {}}, hint);
        }
    }
    for (const auto &def : _catalog.events) {
        if (def.channel != 1 || (def.fact != 0 && def.fact != event.type) ||
            weight(def, input, sampled) <= 0) continue;
        if (roll(input.day, cell, int64_t(def.salt) + index) < def.chance) {
            enqueue(def, input, cell);
            hit = true;
            break;
        }
    }
}

void RuntimeNarrative::pulse(const NarrativeDay &input) {
    if (paced(input.day)) return;
    auto cells = sampled_cells(input);
    if (cells.empty()) cells.push_back(-1);
    const int32_t first = cells.front();
    if (_ai_enabled && first >= 0 && ai_allowed(input.day)) {
        const int32_t chance = 2621 + (26214 - 2621) *
            ai_pressure(input.country, input.sample(first, false)) / 100;
        if (roll(input.day, first, 0x4149) < chance)
            request_ai(input, input.sample(first, true), {input.day + 1, 0, first, {}, {}, {}});
    }
    if (roll(input.day, first, 0x50554C53) >= 16384) return;
    std::vector<std::pair<const NarrativeDefinition *, int32_t>> candidates;
    std::vector<int64_t> weights;
    for (int32_t cell : cells) {
        const auto sample = input.sample(cell, true);
        for (const auto &def : _catalog.events) {
            if (def.channel != 0) continue;
            const int32_t score = weight(def, input, sample);
            if (score <= 0) continue;
            candidates.emplace_back(&def, cell);
            weights.push_back(score);
        }
    }
    const auto index = pick(weights, input.day, first, 0x57474854);
    if (index < 0) return;
    const auto &[def, cell] = candidates[index];
    if (roll(input.day, cell, def->salt) < def->chance) enqueue(*def, input, cell);
}

int64_t RuntimeNarrative::step(const NarrativeDay &input,
        const std::vector<RuntimeEventsRecord> &facts, int64_t acknowledged) {
    if (input.day <= _day) return -1;
    _day = input.day;
    _independence_requests = Array();
    unrest(input, facts);
    prune(input.day);
    followups(input);
    std::array<const RuntimeEventsRecord *, 64> batch{};
    size_t count = 0;
    const int64_t after = _last_fact < 0 ? acknowledged : _last_fact;
    for (const auto &record : facts) {
        if (record.event_id <= after) continue;
        batch[count++] = &record;
        _last_fact = std::max(_last_fact, record.event_id);
        if (count == batch.size()) break;
    }
    if (!paced(input.day)) {
        bool hit = false;
        for (size_t index = 0; index < count && !hit; ++index)
            fact(input, *batch[index], index, hit);
    }
    if (input.day - _last_probe >= PROBE_INTERVAL && !_catalog.probes.empty()) {
        _last_probe = input.day;
        poll_probes(input);
    }
    flush_pool(input);
    if (input.day - _last_pulse >= PULSE_INTERVAL) {
        _last_pulse = input.day;
        pulse(input);
    }
    promote(input.day);
    return count != 0 ? batch[count - 1]->event_id : -1;
}

std::shared_ptr<const RuntimeNarrativeView> RuntimeNarrative::view() const {
    auto out = std::make_shared<RuntimeNarrativeView>();
    out->day = _day;
    out->popup_day = _last_popup;
    out->active_offer = _active;
    out->unrest_fact = _last_unrest_fact;
    for (const auto &row : _queue) out->queue.push_back(row);
    for (const auto &row : _chronicle) out->chronicle.push_back(row);
    out->ai_request = _ai_request;
    out->independence = _independence_requests;
    return out;
}
} // namespace pk
