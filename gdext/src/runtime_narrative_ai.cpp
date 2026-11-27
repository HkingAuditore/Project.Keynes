#include "runtime_narrative.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <utility>

namespace pk {
using namespace godot;

namespace {
// 用户 11-23 口径（narrative_event_service.gd: MAX_STATE_PROBE_CELLS_PER_DAY = 2）：
// 每模拟日最多 2 个格子做完整上下文采样，把 8~16 格分摊到多日，消掉每周单帧尖刺。
// 与 runtime_narrative.cpp 的同名常量保持同值。
constexpr int64_t MAX_STATE_PROBE_CELLS_PER_DAY = 2;

bool owns(const NarrativeCountryView &country, int32_t cell) {
    return std::find(country.territory.begin(), country.territory.end(), cell) != country.territory.end();
}
String text(const std::string &value) { return String::utf8(value.c_str()); }

bool normalize_ai_effect_amounts(Dictionary &row) {
    const int32_t kind = row.get("kind", 0);
    const int64_t requested_value = row.get("int_value", 0);
    const int64_t requested_ratio = row.get("ratio_bp", 0);
    int64_t value = requested_value;
    int64_t ratio = requested_ratio <= 0 ? 0 :
        std::clamp<int64_t>(requested_ratio, 50, 2000);
    const bool city = kind == NarrativeEffect::CITY_MODIFIER;
    const int64_t radius = city ? std::clamp<int64_t>(row.get("radius_cells", 0), 0, 2) : 0;
    const int64_t falloff = city ? std::clamp<int64_t>(row.get("falloff", 0), 0, 1) : 0;
    if (city || kind == NarrativeEffect::ADD_POPULATION)
        row["scope_to_cell"] = true;
    else if (kind == NarrativeEffect::COUNTRY_MODIFIER)
        row["scope_to_cell"] = false;

    switch (kind) {
    case NarrativeEffect::TREASURY_CASH_TO_COHORT:
    case NarrativeEffect::COHORT_CASH_TO_TREASURY:
        if (kind == NarrativeEffect::COHORT_CASH_TO_TREASURY)
            value = std::min<int64_t>(value, 1000000);
        if (value <= 0) {
            value = 0;
            if (ratio == 0) ratio = 500;
        }
        break;
    case NarrativeEffect::COUNTRY_GOOD_TO_MARKET:
    case NarrativeEffect::MARKET_GOOD_TO_COUNTRY:
    case NarrativeEffect::MARKET_ADD_STOCK:
    case NarrativeEffect::MARKET_REMOVE_STOCK:
        if (value > 0) {
            value = std::min<int64_t>(value, 50000);
        } else {
            value = kind == NarrativeEffect::MARKET_ADD_STOCK ? 100 : 0;
            if (ratio == 0 && value == 0) ratio = 500;
        }
        break;
    case NarrativeEffect::ADD_POPULATION:
        value = std::clamp<int64_t>(value, -3000, 3000);
        ratio = value != 0 ? 0 : std::clamp<int64_t>(requested_ratio, -3000, 3000);
        if (value == 0 && ratio == 0) ratio = 800;
        break;
    case NarrativeEffect::SET_FLAG:
    case NarrativeEffect::CLEAR_FLAG:
        value = std::clamp<int64_t>(value, 1, 100);
        break;
    case NarrativeEffect::WEIGHT_BIAS:
        value = std::clamp<int64_t>(value != 0 ? value : 50, -300, 500);
        break;
    }
    const int64_t duration = row.get("duration_days", 90);
    const int64_t magnitude = row.get("magnitude_q16", 9830);
    const bool changed = value != requested_value || ratio != requested_ratio ||
        duration < 15 || duration > 365 || magnitude < 3277 || magnitude > 32768 ||
        radius != int64_t(row.get("radius_cells", 0)) || falloff != int64_t(row.get("falloff", 0));
    row["int_value"] = value;
    row["ratio_bp"] = ratio;
    row["duration_days"] = std::clamp<int64_t>(duration, 15, 365);
    row["magnitude_q16"] = std::clamp<int64_t>(magnitude, 3277, 32768);
    row["radius_cells"] = radius;
    row["falloff"] = falloff;
    return changed;
}

String ai_effect_amount_label(const NarrativeEffect &effect, const String &good_name) {
    const auto days = String::num_int64(effect.duration);
    const auto ratio = String::num(effect.ratio / 100.0, 1) + "%";
    switch (effect.kind) {
    case NarrativeEffect::CITY_MODIFIER:
    case NarrativeEffect::COUNTRY_MODIFIER: {
        const bool city = effect.kind == NarrativeEffect::CITY_MODIFIER;
        const auto percent = String::num_int64((effect.magnitude * 100 + 32768) / 65536);
        String line = String::utf8(city ? "本地修正 " : "全国修正 ") +
            (String(effect.key.c_str()).ends_with(".cut") ? "-" : "+") +
            percent + String::utf8("%，") + days + String::utf8(" 日");
        if (city && effect.radius > 0)
            line += String::utf8("（周边 ") + String::num_int64(effect.radius) + String::utf8(" 环）");
        return line;
    }
    case NarrativeEffect::ADD_POPULATION:
        return String::utf8("本地人口 ") + (effect.value < 0 || effect.ratio < 0 ? "-" : "+") +
            (effect.value != 0 ? String::num_int64(std::abs(effect.value)) + String::utf8(" 人") :
                String::num(std::abs(effect.ratio) / 100.0, 1) + "%");
    case NarrativeEffect::COHORT_CASH_TO_TREASURY:
        return String::utf8("本地人数最多的居民群体上缴国库 ") +
            (effect.value > 0 ? String::num_int64(effect.value >= 10000 && effect.value % 100 == 0
                ? (effect.value + 5000) / 10000 : effect.value) : ratio);
    case NarrativeEffect::COUNTRY_GOOD_TO_MARKET:
    case NarrativeEffect::MARKET_GOOD_TO_COUNTRY:
    case NarrativeEffect::MARKET_ADD_STOCK:
    case NarrativeEffect::MARKET_REMOVE_STOCK: {
        const char *const prefix[] = {"国家储备投放 ", "本地市场征调 ", "本地市场新增 ", "本地市场减少 "};
        const auto amount = effect.value > 0 ? String::num_int64(
            effect.value >= 1000 && effect.value % 100 == 0
            ? (effect.value + 500) / 1000 : effect.value) + String::utf8(" 单位") : ratio;
        return String::utf8(prefix[effect.kind - NarrativeEffect::COUNTRY_GOOD_TO_MARKET]) +
            good_name + " " + amount;
    }
    case NarrativeEffect::SET_FLAG:
        return String::utf8("留下地方记事，") + days + String::utf8(" 日");
    case NarrativeEffect::WEIGHT_BIAS:
        return String::utf8(effect.value >= 0 ? "相关变故更易发生，" : "相关变故明显减少，") +
            days + String::utf8(" 日");
    case NarrativeEffect::SCHEDULE:
        return days + String::utf8(" 日后引发后续变故");
    default:
        return {};
    }
}

Dictionary settle_ai_definition(const Dictionary &reply, const NarrativeCountryView &country,
        const std::vector<std::string> &goods) {
    Dictionary def = reply.duplicate(true);
    const Array options = def.get("options", Array());
    const auto known_good = [&](const std::string &id) {
        return std::find(goods.begin(), goods.end(), id) != goods.end();
    };
    for (int64_t i = 0; i < options.size(); ++i) {
        const Dictionary option = options[i];
        const Array outcomes = option.get("outcomes", Array());
        for (int64_t j = 0; j < outcomes.size(); ++j) {
            Dictionary outcome = outcomes[j];
            const Array input = outcome.get("effects", Array());
            const Array descriptions = outcome.get("effect_descriptions", Array());
            Array effects, lines;
            int64_t cash = std::max<int64_t>(0, country.treasury_cash);
            for (int64_t k = 0; k < input.size(); ++k) {
                Dictionary row = input[k];
                const bool adjusted = normalize_ai_effect_amounts(row);
                const auto effect = compile_narrative_effect(row);
                if ((effect.kind == NarrativeEffect::COUNTRY_GOOD_TO_MARKET ||
                     effect.kind == NarrativeEffect::MARKET_GOOD_TO_COUNTRY ||
                     effect.kind == NarrativeEffect::MARKET_ADD_STOCK ||
                     effect.kind == NarrativeEffect::MARKET_REMOVE_STOCK) &&
                        !known_good(effect.key)) continue;
                if (effect.kind == NarrativeEffect::CITY_MODIFIER) {
                    const std::string prefix = "economy.city.good.";
                    const auto suffix = effect.key.find(".output_factor", prefix.size());
                    if (effect.key.compare(0, prefix.size(), prefix) == 0 &&
                        (suffix == std::string::npos ||
                         !known_good(effect.key.substr(prefix.size(), suffix - prefix.size()))))
                        continue;
                }
                String line = k < descriptions.size()
                    ? String(descriptions[k]) : String(row.get("custom_label", ""));
                const String good_name = row.get("target_display_name", text(effect.key));
                row.erase("target_display_name");
                const String custom = row.get("custom_label", "");
                if (custom.is_empty() && (adjusted || effect.kind == NarrativeEffect::CITY_MODIFIER ||
                    effect.kind == NarrativeEffect::COUNTRY_MODIFIER || effect.kind == NarrativeEffect::ADD_POPULATION)) {
                    const String bounded = ai_effect_amount_label(effect, good_name);
                    if (!bounded.is_empty()) line = bounded;
                }
                if (effect.kind == NarrativeEffect::TREASURY_CASH_TO_COHORT) {
                    const int32_t ratio = std::clamp<int64_t>(effect.ratio, 0, 10000);
                    const int64_t wanted = effect.value > 0 ? effect.value
                        : (cash / 10000) * ratio + (cash % 10000) * ratio / 10000;
                    const int64_t amount = std::min(wanted, cash);
                    if (amount == 0) continue;
                    cash -= amount;
                    row["int_value"] = amount;
                    row["ratio_bp"] = 0;
                    const int64_t shown = amount >= 10000 && amount % 100 == 0
                        ? amount / 10000 + (amount % 10000 >= 5000 ? 1 : 0) : amount;
                    line = String::utf8("国库转出 ") + String::num_int64(shown) +
                        String::utf8(" 给本地人数最多的居民群体");
                }
                effects.push_back(row);
                lines.push_back(line);
            }
            outcome["effects"] = effects;
            outcome["effect_descriptions"] = lines;
        }
    }
    return def;
}
} // namespace

int RuntimeNarrative::ai_pressure(const NarrativeCountryView &country, const NarrativeCellView &cell) {
    const auto shortages = std::count_if(cell.market_prices.begin(), cell.market_prices.end(),
        [](const auto &price) { return price.second >= 1.30; });
    int score = std::min(2, static_cast<int>(shortages)) * 15;
    score += std::clamp<int>(std::lround((cell.max_price_ratio - 1.30) * 50.0), 0, 25);
    score += std::clamp<int>(std::lround((0.6 - cell.satisfaction) * 100.0), 0, 25);
    const double stress = cell.temperature >= 30.0 ? (cell.temperature - 30.0) / 10.0 :
        std::max(0.0, -cell.temperature) / 15.0;
    score += std::clamp<int>(std::lround(stress * 20.0), 0, 20);
    score += std::clamp<int>(std::lround((cell.snow - 0.35) * 40.0), 0, 10);
    if (country.at_war) score += country.war_score <= -32768 ? 25 : 15;
    if (cell.family != 0 && cell.prestige >= 3) score += 8;
    return std::min(100, score);
}

bool RuntimeNarrative::ai_allowed(int64_t day) const {
    return _last_ai <= NEVER || day - _last_ai >= 60;
}

bool RuntimeNarrative::request_ai(const NarrativeDay &input, const NarrativeCellView &cell,
        const Followup &item, const String &fact, const std::string &state,
        const String &state_hint, bool scheduled) {
    if (!scheduled && !ai_allowed(input.day)) return false;
    Dictionary request;
    request["ai_request_seq"] = _next_ai++;
    request["day"] = input.day;
    request["effective_day"] = scheduled ? item.due :
        input.day + RuntimeNarrativeCatalog::AI_REPLY_DELAY_DAYS;
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
    if (!scheduled) _last_ai = input.day;
    _pending_ai.push_back({std::move(request), {}});
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
    // 每模拟日最多 MAX_STATE_PROBE_CELLS_PER_DAY 格。按 day 轮转起点，
    // 多日下来每格都会被采到，不会因为固定取前两格而饿死后面的陆块。
    if (static_cast<int64_t>(cells.size()) > MAX_STATE_PROBE_CELLS_PER_DAY) {
        const size_t cap = static_cast<size_t>(MAX_STATE_PROBE_CELLS_PER_DAY);
        const size_t offset = static_cast<size_t>(
            input.day % static_cast<int64_t>(cells.size()));
        std::rotate(cells.begin(),
            cells.begin() + static_cast<std::ptrdiff_t>(offset), cells.end());
        cells.resize(cap);
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
                _tracking.push_back({key, cell, input.day, input.day, sample.max_price_ratio, sample.satisfaction});
                row = std::prev(_tracking.end());
            } else {
                row->seen = input.day;
                row->peak_price = std::max(row->peak_price, sample.max_price_ratio);
                row->min_satisfaction = std::min(row->min_satisfaction, sample.satisfaction);
            }
            const auto seeded = _last_seed.find(key);
            const int64_t held = input.day - row->since;
            if (held < probe.dwell || std::any_of(_pending_ai.begin(), _pending_ai.end(),
                    [&](const auto &pending) {
                        return narrative_key(pending.request.get("state_id", "")) == probe.id;
                    }) ||
                (seeded != _last_seed.end() && input.day - seeded->second < probe.cooldown)) continue;
            const bool has_pooled = std::any_of(_pool.begin(), _pool.end(),
                [&](const auto &entry) { return entry.state == probe.id; });
            if (has_pooled) {
                for (auto entry = _pool.begin(); entry != _pool.end(); ++entry) {
                    if (entry->state != probe.id || (entry->cell >= 0 && entry->cell != cell)) continue;
                    if (ai_event_eligible(entry->definition, input, sample) &&
                            enqueue(entry->definition, input, cell)) {
                        _last_seed[key] = input.day;
                        _pool.erase(entry);
                    }
                    break;
                }
                continue;
            }
            if (!_ai_enabled || !ai_allowed(input.day)) continue;
            auto hint = String::utf8("状态：") + probe.description;
            const auto prompt = probe.prompt.strip_edges();
            if (!prompt.is_empty()) hint += String::utf8("；") + prompt;
            hint += String::utf8("；已持续 ") + String::num_int64(held) +
                String::utf8(" 日；本地人口 ") + String::num_int64(sample.population) +
                String::utf8("，当前满意度 ") + narrative_percent(sample.satisfaction) +
                String::utf8("%；期间最高价格比 ") + String::num(row->peak_price, 2) +
                String::utf8("；期间最低满意度 ") +
                narrative_percent(row->min_satisfaction) + "%";
            if (request_ai(input, sample, {input.day + 1, 0, cell, {}, {}, {}}, {}, probe.id, hint))
                _last_seed[key] = input.day;
        }
    }
}

void RuntimeNarrative::flush_pool(const NarrativeDay &input) {
    if (_pool.empty() || paced(input.day) || input.country.territory.empty()) return;
    int32_t attempts = 0;
    for (auto entry = _pool.begin(); entry != _pool.end() && attempts < 4;) {
        const auto probe = std::find_if(_catalog.probes.begin(), _catalog.probes.end(),
            [&](const auto &probe) { return probe.id == entry->state; });
        if (input.day - entry->created > 365 || probe == _catalog.probes.end()) {
            entry = _pool.erase(entry);
            continue;
        }
        ++attempts;
        const int32_t cell = owns(input.country, entry->cell) ? entry->cell : input.country.territory.front();
        const auto sample = input.sample(cell, true);
        if (!probe_matches(*probe, input, sample) || !ai_event_eligible(entry->definition, input, sample) ||
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

Dictionary RuntimeNarrative::queue_ai_reply(const Dictionary &result) {
    const auto sequence = int64_t(result.get("ai_request_seq", -1));
    const auto pending = std::find_if(_pending_ai.begin(), _pending_ai.end(), [&](const auto &entry) {
        return sequence == int64_t(entry.request["ai_request_seq"]);
    });
    if (pending == _pending_ai.end())
        return narrative_response(false, "ai_request_unknown");
    const int64_t day = pending->request["effective_day"];
    if (int64_t(result.get("effective_day", -1)) != day)
        return narrative_response(false, "ai_reply_day_mismatch");
    if (!pending->reply.is_empty())
        return narrative_response(false, "ai_reply_already_received");
    pending->reply["ok"] = result.get("ok", false);
    if (bool(pending->reply["ok"]))
        pending->reply["definition"] = result.get("definition", Dictionary());
    else
        pending->reply["code"] = result.get("code", "ai_generation_failed");
    auto response = narrative_response(true, "ok");
    response["effective_day"] = day;
    return response;
}

void RuntimeNarrative::set_ai_enabled(int64_t day, bool enabled) {
    if (enabled == (_ai_updates.empty() ? _ai_enabled : _ai_updates.back().second)) return;
    while (!_ai_updates.empty() && _ai_updates.back().first >= day)
        _ai_updates.pop_back();
    _ai_updates.emplace_back(day, enabled);
}

void RuntimeNarrative::apply_ai_policy(int64_t day) {
    while (!_ai_updates.empty() && _ai_updates.front().first <= day) {
        _ai_enabled = _ai_updates.front().second;
        _ai_updates.pop_front();
    }
}

void RuntimeNarrative::apply_ai_replies(const NarrativeDay &input) {
    for (auto it = _pending_ai.begin(); it != _pending_ai.end();) {
        if (int64_t(it->request["effective_day"]) != input.day) {
            ++it;
            continue;
        }
        apply_ai_reply(input, *it);
        it = _pending_ai.erase(it);
    }
}

void RuntimeNarrative::apply_ai_reply(const NarrativeDay &input, const PendingAi &entry) {
    const auto &pending = entry.request;
    const auto &result = entry.reply;
    if (!bool(result.get("ok", false)) || input.country.territory.empty()) return;
    auto def = _catalog.compile_event(settle_ai_definition(
        result.get("definition", Dictionary()), input.country, _catalog.good_ids));
    if (def.id.empty()) return;
    const int32_t target = pending.get("cell_idx", -1);
    const int32_t cell = owns(input.country, target) ? target : input.country.territory.front();
    const auto sample = input.sample(cell, true);
    const auto chain = narrative_key(pending.get("chain_id", ""));
    if (bool(pending.get("scheduled_followup", false))) {
        if (!ai_event_eligible(def, input, sample)) return;
        const auto id = def.id;
        _dynamic.insert_or_assign(id, std::move(def));
        _followups.push_back({std::max<int64_t>(input.day, pending.get("due_day", input.day)),
            0, cell, id, chain, {}});
        return;
    }
    const auto state = narrative_key(pending.get("state_id", ""));
    const auto probe = std::find_if(_catalog.probes.begin(), _catalog.probes.end(),
        [&](const auto &entry) { return entry.id == state; });
    if ((state.empty() || (probe != _catalog.probes.end() && probe_matches(*probe, input, sample))) &&
        ai_event_eligible(def, input, sample) && enqueue(def, input, cell, chain)) {
        const auto id = def.id;
        _dynamic.insert_or_assign(id, std::move(def));
    } else if (probe != _catalog.probes.end()) {
        store_ai(state, std::move(def), cell, input.day);
    }
}

} // namespace pk
