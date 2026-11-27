#include "runtime_narrative.h"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <locale>
#include <sstream>
#include <utility>
#include <numeric>

namespace pk {
using namespace godot;

namespace {
String text(const char *value) { return String::utf8(value); }
String text(const std::string &value) { return text(value.c_str()); }

String decimal(double value) {
    std::ostringstream formatted;
    formatted.imbue(std::locale::classic());
    formatted << std::fixed << std::setprecision(1) << value;
    return String(formatted.str().c_str());
}

String label(const String &raw, const Dictionary &ctx) {
    auto family = String(ctx.get("primary_family_name", "")).strip_edges();
    if (family.is_empty()) family = text("本地大族");
    return raw.replace("{settlement_name}", ctx.get("settlement_name", text("本地")))
        .replace("{primary_profession}", ctx.get("primary_cohort_profession_name", text("居民")))
        .replace("{dominant_profession}", ctx.get("dominant_profession_name", text("居民")))
        .replace("{family_name}", family);
}

String name_at(const PackedStringArray &column, int32_t index, const char *fallback) {
    return index >= 0 && index < column.size() ? column[index] : text(fallback);
}

String requirement(const NarrativeOptionRule &option, const NarrativeCountryView &country,
        bool unrest, const Dictionary &tech_names) {
    if (option.cash > 0 && option.cash > (unrest ? 0 : country.treasury_cash)) {
        return text("国库资金不足（需 ") + decimal(option.cash / 10000.0) + text(" 资金）");
    }
    if (!option.good.empty() && option.quantity > 0) {
        const auto goods = country.treasury_goods.find(option.good);
        if (unrest || goods == country.treasury_goods.end() || goods->second < option.quantity)
            return text("缺少 ") + option.good_name + text("（需 ") +
                decimal(option.quantity / 1000.0) + text(" 单位）");
    }
    if (!option.technology.empty() && (unrest || !country.technologies.count(option.technology))) {
        const String tech_key = text(option.technology);
        const String display = String(tech_names.get(tech_key, tech_key)).strip_edges();
        return text("缺少科技「") + (display.is_empty() ? tech_key : display) + text("」");
    }
    return {};
}

PackedInt32Array normalized(const Array &outcomes) {
    PackedInt32Array probabilities;
    int64_t total = 0;
    for (int64_t i = 0; i < outcomes.size(); ++i) {
        const auto weight = std::max(1, int32_t(Dictionary(outcomes[i]).get("probability_q16", 65536)));
        probabilities.push_back(weight);
        total += weight;
    }
    if (!total) return probabilities;
    int64_t remaining = 65536;
    for (int64_t i = 0; i < probabilities.size(); ++i) {
        const int32_t p = i + 1 == probabilities.size() ? int32_t(remaining) :
            int32_t(std::clamp<int64_t>(std::lround(double(probabilities[i]) * 65536.0 / total),
                1, std::max<int64_t>(1, remaining - (probabilities.size() - 1 - i))));
        probabilities.set(i, p);
        remaining -= p;
    }
    return probabilities;
}
} // namespace

Dictionary narrative_response(bool ok, const char *code, const char *message) {
    Dictionary result;
    result["ok"] = ok;
    if (!ok) result["admitted"] = false;
    result["code"] = code;
    result["message"] = text(message);
    return result;
}

String narrative_percent(double fraction) {
    return String::num_int64(std::lround(fraction * 100.0));
}

String narrative_format(const String &raw, const Dictionary &ctx) {
    const double temp = ctx.get("temperature", 15.0);
    auto family = String(ctx.get("primary_family_name", "")).strip_edges();
    if (family.is_empty()) family = text("本地大族");
    return raw.replace("{settlement_name}", ctx.get("settlement_name", text("当地聚落")))
        .replace("{country_name}", ctx.get("country_name", text("我国")))
        .replace("{terrain_name}", ctx.get("terrain_name", text("原野")))
        .replace("{landform_name}", ctx.get("landform_name", text("平地")))
        .replace("{temperature}", decimal(temp) + text("°C"))
        .replace("{era_name}", ctx.get("era_name", text("当前时代")))
        .replace("{good_name}", ctx.get("highlight_good_name", text("民生商品")))
        .replace("{family_name}", family)
        .replace("{unrest_profession}", ctx.get("unrest_profession", text("本地阶层")));
}

String RuntimeNarrative::date_text(int64_t day) const {
    const int64_t display_days = std::accumulate(_catalog.month_lengths.begin(),
        _catalog.month_lengths.end(), int64_t(0));
    int64_t date = static_cast<int64_t>(std::floor(
        (double(day % _days_per_year) / double(_days_per_year)) * double(display_days)));
    size_t month = 0;
    for (; month + 1 < _catalog.month_lengths.size() && date >= _catalog.month_lengths[month]; ++month)
        date -= _catalog.month_lengths[month];
    return text("第") + String::num_int64(day / _days_per_year + 1) + text("年 · ") +
        String::num_int64(month + 1) + text("月") + String::num_int64(date + 1) + text("日");
}

Dictionary RuntimeNarrative::context(const NarrativeDay &input, const NarrativeCellView &cell) const {
    const auto &country = input.country;
    Dictionary out;
    out["day"] = input.day;
    out["country_handle"] = static_cast<int64_t>(country.handle);
    out["country_name"] = country.name.empty() ? text("我国") : text(country.name);
    out["era_index"] = country.era;
    out["era_name"] = name_at(_catalog.era_names, country.era, "石器时代");
    auto technologies = PackedStringArray();
    for (const auto &id : _catalog.technology_ids)
        if (country.technologies.count(id)) technologies.push_back(text(id));
    out["technology_ids"] = technologies;
    out["technologies"] = technologies;
    PackedInt32Array territory;
    for (const int32_t value : country.territory) territory.push_back(value);
    out["territory_cells"] = territory;
    out["treasury_cash"] = country.treasury_cash;
    Dictionary goods;
    for (const auto &id : _catalog.good_ids) {
        const auto entry = country.treasury_goods.find(id);
        if (entry != country.treasury_goods.end()) goods[text(id)] = entry->second;
    }
    out["treasury_goods_by_id"] = goods;
    out["military_available"] = country.military_available;
    out["at_war"] = country.at_war;
    out["war_count"] = country.war_count;
    out["soldiers_total"] = country.soldiers;
    out["soldiers_in_armies"] = country.soldiers_in_armies;
    out["war_score_min_q16"] = country.war_score;
    out["war_losses_total"] = country.war_losses;

    out["cell_idx"] = cell.cell;
    out["settlement_name"] = cell.settlement.empty() ? text("边陲聚落") : text(cell.settlement);
    out["terrain"] = cell.terrain;
    out["terrain_name"] = name_at(_catalog.terrain_names, cell.terrain, "平原");
    out["landform"] = cell.landform;
    out["landform_name"] = name_at(_catalog.landform_names, cell.landform, "平原");
    out["vegetation"] = cell.vegetation;
    out["vegetation_name"] = name_at(_catalog.vegetation_names, cell.vegetation, "");
    out["cover"] = cell.cover;
    out["temperature"] = cell.temperature;
    out["temperature_c"] = cell.temperature;
    out["moisture"] = cell.moisture;
    out["elevation"] = cell.elevation;
    out["snow_cover"] = cell.snow;
    out["precipitation"] = cell.precipitation;
    out["weather_precip"] = cell.precipitation;
    out["has_river"] = cell.river;
    out["is_coastal"] = cell.coastal;
    out["ocean_current_speed"] = cell.current;
    out["ocean_upwelling"] = cell.upwelling;
    out["weather_vapor"] = cell.vapor;
    out["weather_cloud"] = cell.clouds;
    out["satisfaction"] = cell.satisfaction;
    out["satisfaction_norm"] = cell.satisfaction;
    out["population"] = cell.population;
    out["primary_cohort_handle"] = static_cast<int64_t>(cell.primary_cohort);
    out["primary_cohort_cash"] = cell.primary_cash;
    out["primary_cohort_profession_id"] = text(cell.primary_profession);
    out["primary_cohort_profession_name"] = _catalog.profession_names.get(
        text(cell.primary_profession), text(cell.primary_profession));
    out["dominant_profession_id"] = text(cell.dominant_profession);
    out["dominant_profession_name"] = _catalog.profession_names.get(
        text(cell.dominant_profession), text(cell.dominant_profession));
    out["human_context_available"] = cell.detailed && cell.population > 0;
    const auto dominant = cell.profession_population.find(cell.dominant_profession);
    out["dominant_profession_share"] = dominant != cell.profession_population.end() ?
        double(dominant->second) / double(cell.denominator()) : 0.0;
    out["unemployment_ratio"] = double(cell.unemployment) / double(cell.denominator());
    out["subsistence_shortfall_ratio"] = double(cell.subsistence_shortfall) / double(cell.denominator());
    out["neediest_cohort_satisfaction"] = cell.neediest_satisfaction;
    out["family_available"] = cell.family != 0;
    out["family_count"] = cell.family_count;
    out["primary_family_handle"] = static_cast<int64_t>(cell.family);
    out["primary_family_name"] = text(cell.family_name);
    out["primary_family_prestige"] = cell.prestige;
    out["primary_family_prestige_score_q16"] = cell.prestige_q16;
    out["primary_family_population"] = cell.family_population;
    out["primary_family_population_share"] = std::clamp(
        double(cell.family_population) / double(cell.denominator()), 0.0, 1.0);
    out["primary_family_owned_buildings"] = cell.family_buildings;
    out["primary_family_notable_people"] = cell.notables;
    PackedStringArray trait_names;
    for (const auto &name : cell.family_trait_names) trait_names.push_back(text(name));
    out["primary_family_trait_names"] = trait_names;
    Dictionary stocks, prices, buildings, resources;
    PackedStringArray shortages;
    for (const auto &id : _catalog.good_ids) {
        if (cell.market_stocks.count(id)) stocks[text(id)] = cell.stock(id);
        const auto price = cell.market_prices.find(id);
        if (price == cell.market_prices.end()) continue;
        prices[text(id)] = price->second;
        if (price->second >= 1.30) shortages.push_back(text(id));
    }
    const auto encode_sorted = [](const auto &values, Dictionary &out) {
        std::vector<std::string> keys;
        for (const auto &item : values) keys.push_back(item.first);
        std::sort(keys.begin(), keys.end());
        for (const auto &key : keys) out[text(key)] = values.at(key);
    };
    encode_sorted(cell.building_counts, buildings);
    encode_sorted(cell.resources, resources);
    out["market_stocks_by_id"] = stocks;
    out["market_price_ratios_by_id"] = prices;
    out["shortage_good_ids"] = shortages;
    out["building_counts_by_id"] = buildings;
    out["natural_resources_by_id"] = resources;
    out["max_price_ratio"] = cell.max_price_ratio;
    const auto good_display = [&](const std::string &good_id) -> String {
        if (good_id.empty()) return text("粮食");
        const String key = text(good_id);
        const String mapped = String(_catalog.good_names.get(key, key)).strip_edges();
        return mapped.is_empty() ? key : mapped;
    };
    out["highlight_good_name"] = good_display(cell.expensive_good);
    for (int32_t ring = 0; ring < 2; ++ring) {
        PackedInt32Array cells;
        for (const int32_t value : cell.nearby[ring]) cells.push_back(value);
        out[ring == 0 ? "nearby_owned_cells_r1" : "nearby_owned_cells_r2"] = cells;
    }
    if (cell.detailed) {
        Array neighbors;
        for (const auto &ring : cell.nearby) {
            for (const int32_t index : ring) {
                if (neighbors.size() == 3) break;
                const auto neighbor = input.sample(index, false);
                Dictionary row;
                row["cell_idx"] = index;
                row["name"] = text(neighbor.settlement);
                row["population"] = neighbor.population;
                row["shortage_good"] = neighbor.max_price_ratio >= 1.30 ?
                    good_display(neighbor.expensive_good) : String();
                neighbors.push_back(row);
            }
        }
        out["neighbor_settlements"] = neighbors;
    }
    Dictionary active_flags;
    std::vector<std::string> keys;
    for (const auto &item : _flags) keys.push_back(item.first);
    std::sort(keys.begin(), keys.end());
    const std::string prefix = "cell:" + std::to_string(cell.cell) + ":";
    for (const auto &key : keys) {
        if (key.rfind("cell:", 0) == 0 && key.rfind(prefix, 0) != 0) continue;
        const auto &flag = _flags.at(key);
        Dictionary value;
        value["set_day"] = flag.set;
        value["expires_day"] = flag.expires;
        value["value"] = flag.value;
        const std::string bare = key.rfind(prefix, 0) == 0 ? key.substr(prefix.size()) :
            key.rfind("country:", 0) == 0 ? key.substr(8) : key;
        active_flags[text(bare)] = value;
    }
    out["story_flags"] = active_flags;
    return out;
}

bool RuntimeNarrative::ai_event_eligible(const NarrativeDefinition &def, const NarrativeDay &input,
        const NarrativeCellView &cell) const {
    return weight(def, input, cell) > 0 &&
        std::any_of(def.options.begin(), def.options.end(), [&](const auto &option) {
            return requirement(option, input.country, false, _catalog.technology_names).is_empty();
        });
}

bool RuntimeNarrative::enqueue(const NarrativeDefinition &def, const NarrativeDay &input,
        int32_t cell, const std::string &chain, bool bypass, const Dictionary &meta,
        int64_t chain_salt, const Array &odds) {
    if (!bypass && (paced(input.day) || cell_capped(cell, input.day))) return false;
    const bool rebellion = !meta.is_empty() && String(meta.get("kind", "")) == "rebellion";
    const auto sampled = input.sample(cell, !rebellion);
    Dictionary ctx;
    if (rebellion) {
        ctx["settlement_name"] = sampled.settlement.empty() ? text("本地") : text(sampled.settlement);
        ctx["unrest_profession"] = meta.get("profession_name", text("本地阶层"));
    } else {
        ctx = context(input, sampled);
    }
    if (def.cooldown > 0) {
        const auto key = def.scope == 0 && cell >= 0 ? "cell:" + std::to_string(cell) + ":" + def.id :
            "country:" + def.id;
        _cooldowns[key] = input.day + def.cooldown;
    }
    Array summaries;
    for (const auto &effect : def.on_trigger) {
        local_effect(effect, cell, input.day + 1);
        const String line = label(effect.label, ctx);
        if (!line.is_empty()) summaries.push_back(line);
    }

    const auto &raw = def.presentation;
    const Array authored_options = raw.get("options", Array());
    Array options;
    for (int64_t i = 0; i < authored_options.size(); ++i) {
        const Dictionary source = authored_options[i];
        const Array outcomes = source.get("outcomes", Array());
        PackedInt32Array probabilities = def.options[i].probabilities;
        if (i < odds.size()) probabilities = odds[i];
        else if (probabilities.size() != outcomes.size()) probabilities = normalized(outcomes);
        const String reason = requirement(def.options[i], input.country, rebellion, _catalog.technology_names);
        Dictionary option;
        option["index"] = i;
        option["option_id"] = source.get("option_id", "");
        option["text"] = narrative_format(source.get("text", ""), ctx);
        if (rebellion) {
            if (i == 3 || (int32_t(meta.get("stage", 0)) == 4 && i == 2))
                option["tooltip_hint"] = source.get("tooltip_hint", "");
            else {
                // The prose is authored in StratumRebellionContent; only the
                // published tariff and chance are substituted here.
                const auto probability = narrative_percent(probabilities[0] / 65536.0);
                option["tooltip_hint"] = String(source.get("tooltip_hint", ""))
                    .replace("{unrest_chance}", probability);
            }
        } else {
            option["tooltip_hint"] = narrative_format(source.get("tooltip_hint", ""), ctx);
        }
        option["eligible"] = reason.is_empty();
        option["ineligible_reason"] = reason;
        Array paths;
        for (int64_t j = 0; j < outcomes.size(); ++j) {
            const Dictionary authored = outcomes[j];
            const int32_t probability = j < probabilities.size() ? probabilities[j] : 65536;
            const Array effects = authored.get("effects", Array());
            const Array descriptions = authored.get("effect_descriptions", Array());
            Array lines;
            for (int64_t k = 0; k < effects.size(); ++k)
                lines.push_back(label(k < descriptions.size() ? String(descriptions[k]) :
                    String(Dictionary(effects[k]).get("custom_label", "")), ctx));
            PackedStringArray packed_lines;
            for (int64_t k = 0; k < lines.size(); ++k) packed_lines.push_back(lines[k]);
            Dictionary path;
            path["probability_q16"] = probability;
            path["probability_percent"] = int32_t(std::lround(probability * 100.0 / 65536.0));
            path["outcome_title"] = narrative_format(authored.get("outcome_title", ""), ctx);
            path["outcome_narrative"] = narrative_format(authored.get("outcome_narrative", ""), ctx);
            path["effect_summaries"] = packed_lines;
            path["effects"] = effects;
            path["effect_descriptions"] = descriptions;
            paths.push_back(path);
        }
        option["outcomes"] = paths;
        options.push_back(option);
    }

    Dictionary offer;
    offer["offer_id"] = _next_offer++;
    offer["offer_generation"] = _next_generation++;
    offer["event_id"] = text(def.id);
    offer["day"] = input.day;
    offer["date_text"] = date_text(input.day);
    offer["cell_idx"] = cell;
    offer["settlement_name"] = ctx.get("settlement_name", text("本地"));
    offer["terrain_name"] = ctx.get("terrain_name", "");
    offer["landform_name"] = ctx.get("landform_name", "");
    offer["temperature"] = ctx.get("temperature", 18.0);
    for (const char *key : {"title", "body_text", "speaker", "quote_text"})
        offer[key] = narrative_format(raw.get(key, ""), ctx);
    for (const char *key : {"image_key", "image_path", "ai_visual_prompt"})
        offer[key] = raw.get(key, "");
    offer["tags"] = raw.get("tags", Array());
    offer["chain_id"] = text(chain);
    offer["chain_salt"] = chain_salt;
    offer["meta"] = meta.duplicate(true);
    offer["event_category"] = rebellion ? 0 : def.category;
    offer["event_notification"] = def.notification;
    if (rebellion) {
        Dictionary clean = offer["meta"];
        clean.erase("profession_name");
    }
    offer["bypass_pacing"] = bypass;
    offer["is_ai_generated"] = raw.get("is_ai_generated", false);
    offer["one_shot"] = def.one_shot;
    offer["on_trigger_summaries"] = summaries;
    offer["options"] = options;
    _queue.push_back(offer);
    promote(input.day);
    return true;
}


bool RuntimeNarrative::stops_for(const Dictionary &offer, uint16_t mask) const {
    const int32_t category = std::clamp<int32_t>(offer.get("event_category", 7), 0, 7);
    const int32_t bit = category + (bool(offer.get("event_notification", false)) ? 8 : 0);
    return (mask & (uint16_t(1) << bit)) != 0;
}

Dictionary RuntimeNarrative::queue_choice(int64_t day, const Dictionary &args, bool automatic) {
    if (!_pending_choice.is_empty())
        return narrative_response(false, "narrative_choice_already_pending");
    const auto check = validate_choice(args);
    if (!bool(check.get("ok", false))) return check;
    _pending_choice = args.duplicate(true);
    _pending_choice["effective_day"] = day;
    _pending_choice["automatic"] = automatic;
    auto receipt = narrative_response(true, "ok");
    receipt["effective_day"] = day;
    receipt["offer_id"] = args.get("offer_id", 0);
    receipt["pending"] = true;
    return receipt;
}

Dictionary RuntimeNarrative::take_due_choice(int64_t day) {
    if (_pending_choice.is_empty() || int64_t(_pending_choice.get("effective_day", -1)) > day)
        return {};
    return std::exchange(_pending_choice, {});
}

int64_t RuntimeNarrative::automatic_option_index(const Dictionary &offer) {
    const Array options = offer.get("options", Array());
    const auto eligible = [&](int64_t index) {
        return index >= 0 && index < options.size() &&
            bool(Dictionary(options[index]).get("eligible", true));
    };
    int64_t selected = offer.get("default_option_index", 0);
    if (eligible(selected)) return selected;
    for (int64_t i = 0; i < options.size(); ++i)
        if (eligible(i)) return i;
    return -1;
}

void RuntimeNarrative::queue_automatic_choice(int64_t day, bool suppress_popups) {
    if (_active.is_empty() || !_pending_choice.is_empty() ||
            (!suppress_popups && stops_for(_active, _pause_mask))) return;
    const int64_t selected = automatic_option_index(_active);
    if (selected < 0) return;
    Dictionary choice;
    choice["country"] = static_cast<int64_t>(_country);
    choice["offer_id"] = _active["offer_id"];
    choice["offer_generation"] = _active["offer_generation"];
    choice["option_index"] = selected;
    queue_choice(day, choice, true);
}

void RuntimeNarrative::set_pause_policy(int64_t day, uint16_t mask) {
    while (!_pause_updates.empty() && _pause_updates.back().first >= day)
        _pause_updates.pop_back();
    _pause_updates.emplace_back(day, mask);
}

uint16_t RuntimeNarrative::pause_policy_for(int64_t day) const {
    uint16_t mask = _pause_mask;
    for (const auto &[effective_day, value] : _pause_updates) {
        if (effective_day > day) break;
        mask = value;
    }
    return mask;
}

void RuntimeNarrative::apply_pause_policy(int64_t day) {
    while (!_pause_updates.empty() && _pause_updates.front().first <= day) {
        _pause_mask = _pause_updates.front().second;
        _pause_updates.pop_front();
    }
}

Dictionary RuntimeNarrative::validate_choice(const Dictionary &args) const {
    return validate_offer(placing_choice() ? Dictionary() : _active, _country, args);
}

Dictionary RuntimeNarrative::validate_offer(const Dictionary &offer, uint64_t country,
        const Dictionary &args) {
    if (offer.is_empty() || int64_t(args.get("country", 0)) != int64_t(country) ||
        int64_t(args.get("offer_id", -1)) != int64_t(offer.get("offer_id", -2)) ||
        int64_t(args.get("offer_generation", -1)) != int64_t(offer.get("offer_generation", -2)))
        return narrative_response(false, "narrative_offer_mismatch", "事件已过期。");
    const Array options = offer.get("options", Array());
    const int64_t option = args.get("option_index", -1);
    if (option < 0 || option >= options.size())
        return narrative_response(false, "narrative_option_invalid", "选项无效。");
    const Dictionary selected = options[option];
    if (!bool(selected.get("eligible", true))) {
        auto result = narrative_response(false, "narrative_option_ineligible");
        result["message"] = selected.get("ineligible_reason", text("条件不满足。"));
        return result;
    }
    return narrative_response(true, "ok");
}

Dictionary RuntimeNarrative::begin_choice(const NarrativeDay &input, const Dictionary &args) {
    const auto check = validate_choice(args);
    if (!bool(check.get("ok", false))) return check;
    const Array options = _active.get("options", Array());
    const int64_t option = args["option_index"];
    const Dictionary selected = options[option];
    _choice_day = args.get("effective_day", input.day + 1);
    const int32_t cell = _active.get("cell_idx", -1);
    const int64_t offer_id = _active.get("offer_id", 0);
    const int64_t chain_salt = _active.get("chain_salt", 0);
    _choice_context = context(input, input.sample(cell, true));
    _choice_context["day"] = _choice_day;

    const Array outcomes = selected.get("outcomes", Array());
    std::vector<int64_t> weights;
    for (int64_t i = 0; i < outcomes.size(); ++i)
        weights.push_back(std::max<int64_t>(1, Dictionary(outcomes[i]).get("probability_q16", 65536)));
    const int64_t salt = (chain_salt != 0 ? chain_salt : offer_id) * 131 + option * 17 + 7;
    const int64_t rolled = std::max<int64_t>(0, pick(weights, _choice_day, cell, salt));
    Dictionary chosen;
    if (outcomes.is_empty()) {
        chosen["probability_q16"] = 65536;
        chosen["probability_percent"] = 100;
        chosen["outcome_title"] = text("尘埃落定");
        chosen["outcome_narrative"] = "";
        chosen["effects"] = Array();
    } else {
        chosen = outcomes[rolled];
    }
    _choice_effects = chosen.get("effects", Array());
    Dictionary record;
    for (const char *key : {"offer_id", "day", "date_text", "cell_idx", "settlement_name",
            "event_id", "title", "body_text", "speaker", "quote_text", "image_key",
            "image_path", "tags", "chain_id", "meta", "is_ai_generated"})
        record[key] = _active[key];
    if (bool(_active.get("notice_only", false))) record["notice_only"] = true;
    record["record_id"] = _next_record;
    record["resolved_day"] = _choice_day;
    record["automatically_chosen"] = args.get("automatic", false);
    record["year"] = _choice_day / _days_per_year;
    record["chosen_option_index"] = option;
    record["chosen_option_text"] = selected.get("text", "");
    record["rolled_outcome_index"] = rolled;
    record["outcome_probability_percent"] = chosen.get("probability_percent", 100);
    record["outcome_title"] = chosen.get("outcome_title", "");
    record["outcome_narrative"] = chosen.get("outcome_narrative", "");
    _choice_record = record;
    auto result = narrative_response(true, "ok");
    result["effective_day"] = _choice_day;
    result["outcome_index"] = rolled;
    result["outcome"] = chosen.duplicate(true);
    result["context"] = _choice_context.duplicate(true);
    result["offer_id"] = offer_id;
    const Dictionary meta = _choice_record.get("meta", Dictionary());
    if (String(meta.get("kind", "")) == "rebellion") {
        const Array actions = meta.get("actions", Array());
        const Array costs = meta.get("cost_bps", Array());
        const int32_t action = option < actions.size() ? int32_t(actions[option]) : -1;
        const int32_t bp = option < costs.size() ? int32_t(costs[option]) : 0;
        const int64_t amount = input.country.treasury_cash * bp / 10000;
        const int64_t cohort = _choice_context.get("primary_cohort_handle", 0);
        if ((action == 0 || action == 1) && amount > 0 && cohort != 0) {
            Dictionary concession;
            concession["cohort"] = cohort;
            concession["amount"] = amount;
            concession["day"] = _choice_day;
            concession["sequence"] = allocate_unrest_sequence();
            result["concession"] = concession;
        }
    }
    return result;
}

Dictionary RuntimeNarrative::complete_choice(Dictionary result, bool apply_local) {
    const int64_t date = _choice_record["resolved_day"];
    const int32_t cell = _choice_record["cell_idx"];
    if (apply_local) {
        for (int64_t i = 0; i < _choice_effects.size(); ++i)
            local_effect(compile_narrative_effect(_choice_effects[i]), cell, date);
    }
    if (!bool(_active.get("notice_only", false)))
        _completed[narrative_key(_choice_record["event_id"])] = date;
    ++_next_record;
    const Dictionary outcome = result.get("outcome", Dictionary());
    const Array descriptions = outcome.get("effect_descriptions", Array());
    Array summaries;
    if (!descriptions.is_empty()) {
        for (int64_t index = 0; index < descriptions.size(); ++index) {
            const auto line = label(descriptions[index], _choice_context);
            if (!line.is_empty()) summaries.push_back(line);
        }
    } else {
        const PackedStringArray shown = outcome.get("effect_summaries", PackedStringArray());
        for (int64_t index = 0; index < shown.size(); ++index)
            if (!shown[index].is_empty()) summaries.push_back(shown[index]);
    }
    if (result.has("effect_failures")) {
        _choice_record["effect_failures"] = result["effect_failures"];
        summaries.clear();
        summaries.push_back(String::utf8("部分效果未能生效。"));
    }
    if (result.has("pending_economy_effects"))
        _choice_record["pending_economy_effects"] = result["pending_economy_effects"];
    _choice_record["applied_effects_summary"] = summaries;
    PackedStringArray displayed;
    for (int64_t index = 0; index < summaries.size(); ++index) displayed.push_back(summaries[index]);
    result["applied_summaries"] = displayed;
    _chronicle.push_front(_choice_record);
    if (_chronicle.size() > 256) _chronicle.pop_back();
    result["record"] = _choice_record.duplicate(true);
    result["effective_day"] = _choice_day;
    _active = Dictionary();
    _choice_record = Dictionary();
    _choice_context = Dictionary();
    _choice_effects = Array();
    promote(_choice_day);
    return result;
}
void RuntimeNarrative::settle_economy_effects(
        const std::function<bool(int64_t, std::string &)> &receipt) {
    for (auto &row : _chronicle) {
        const PackedInt64Array pending = row.get("pending_economy_effects", PackedInt64Array());
        if (pending.is_empty()) continue;
        PackedInt64Array remaining;
        PackedStringArray failures = row.get("effect_failures", PackedStringArray());
        for (int64_t i = 0; i < pending.size(); ++i) {
            std::string reason;
            if (!receipt(pending[i], reason)) remaining.push_back(pending[i]);
            else if (!reason.empty()) failures.push_back(String(reason.c_str()));
        }
        if (!failures.is_empty()) {
            row["effect_failures"] = failures;
            Array summary;
            summary.push_back(String::utf8("部分效果未能生效。"));
            row["applied_effects_summary"] = summary;
        }
        if (remaining.is_empty()) row.erase("pending_economy_effects");
        else row["pending_economy_effects"] = remaining;
    }
}

} // namespace pk
