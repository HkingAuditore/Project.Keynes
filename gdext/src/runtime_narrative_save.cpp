#include "runtime_narrative.h"

#include <algorithm>

namespace pk {
using namespace godot;

namespace {
String text(const std::string &value) { return String::utf8(value.c_str()); }

template <class Map, class Put>
Dictionary encode_map(const Map &map, Put put) {
    std::vector<std::string> keys;
    keys.reserve(map.size());
    for (const auto &row : map) keys.push_back(row.first);
    std::sort(keys.begin(), keys.end());
    Dictionary archive;
    for (const auto &key : keys) archive[text(key)] = put(map.at(key));
    return archive;
}

template <class Map, class Read>
void decode_map(const Dictionary &archive, Map &map, Read read) {
    const auto keys = archive.keys();
    for (int64_t i = 0; i < keys.size(); ++i)
        map[narrative_key(keys[i])] = read(archive[keys[i]]);
}

Dictionary record_or_empty(const Variant &value) {
    return value.get_type() == Variant::DICTIONARY ? Dictionary(value) : Dictionary();
}

Array rows_or_empty(const Variant &value) {
    return value.get_type() == Variant::ARRAY ? Array(value) : Array();
}

template <class Rows>
Array encode_records(const Rows &rows) {
    Array out;
    for (const auto &row : rows) out.push_back(row);
    return out;
}

template <class Read>
void decode_records(const Variant &value, Read read) {
    const auto array = rows_or_empty(value);
    for (int64_t i = 0; i < array.size(); ++i)
        if (array[i].get_type() == Variant::DICTIONARY) read(Dictionary(array[i]));
}
} // namespace

Dictionary RuntimeNarrative::capture() const {
    Dictionary out;
    out["schema"] = "PKNarrativeRuntime";
    out["version"] = 1;
    out["world_seed"] = static_cast<int64_t>(_seed);
    out["player_country_handle"] = static_cast<int64_t>(_country);
    out["next_offer_id"] = _next_offer;
    out["next_offer_generation"] = _next_generation;
    out["next_record_id"] = _next_record;
    out["next_bias_id"] = _next_bias;
    out["next_mod_source_id"] = _next_modifier_source;
    out["last_pulse_day"] = _last_pulse;
    out["last_popup_day"] = _last_popup;
    out["last_fact_event_id"] = _last_fact;
    out["last_ai_request_day"] = _last_ai;
    out["next_ai_request_seq"] = _next_ai;
    out["pending_ai_request"] = _pending_ai;
    out["last_state_probe_day"] = _last_probe;
    out["event_pause_mask"] = static_cast<int32_t>(_pause_mask);
    out["last_notification_fact"] = _last_notification_fact;
    out["notification_sequence"] = _notification_sequence;
    out["last_notice_era"] = _last_notice_era;
    out["pending_choice"] = _pending_choice;
    Array pause_updates;
    for (const auto &[day, mask] : _pause_updates) {
        Array row;
        row.push_back(day);
        row.push_back(static_cast<int32_t>(mask));
        pause_updates.push_back(row);
    }
    out["pending_event_pause_masks"] = pause_updates;
    out["next_pool_id"] = _next_pool;
    Array pool;
    for (const auto &item : _pool) {
        Dictionary row;
        row["pool_id"] = item.id;
        row["state_id"] = text(item.state);
        row["cell_idx"] = item.cell;
        row["created_day"] = item.created;
        row["def_dict"] = item.definition.presentation;
        pool.push_back(row);
    }
    out["ai_event_pool"] = pool;
    Dictionary tracking;
    for (const auto &item : _tracking) {
        Dictionary row;
        row["cell"] = item.cell;
        row["since_day"] = item.since;
        row["last_seen_day"] = item.seen;
        row["peak_price_ratio"] = item.peak_price;
        row["min_satisfaction"] = item.min_satisfaction;
        tracking[text(item.key)] = row;
    }
    out["state_tracking"] = tracking;
    const auto identity = [](int64_t value) { return value; };
    out["state_last_seed"] = encode_map(_last_seed, identity);
    out["cell_year_event_counts"] = encode_map(_year_counts, identity);
    out["active_offer"] = _active;
    out["ready_queue"] = encode_records(_queue);
    out["cooldowns"] = encode_map(_cooldowns, identity);
    out["completed_one_shots"] = encode_map(_completed, identity);
    out["story_flags"] = encode_map(_flags, [](const Flag &flag) {
        Dictionary row;
        row["set_day"] = flag.set;
        row["expires_day"] = flag.expires;
        row["value"] = flag.value;
        return row;
    });
    Array biases;
    for (const auto &item : _biases) {
        Dictionary row;
        row["id"] = item.id;
        row["target_event_id"] = text(item.event);
        row["target_tag"] = text(item.tag);
        row["scope_cell"] = item.cell;
        row["add_weight"] = item.add;
        row["mul_q16"] = item.factor;
        row["expires_day"] = item.expires;
        row["source_event_id"] = text(item.source);
        biases.push_back(row);
    }
    out["weight_biases"] = biases;
    Array scheduled;
    for (const auto &item : _followups) {
        Dictionary row;
        row["due_day"] = item.due;
        row["event_id"] = text(item.event);
        row["cell_idx"] = item.cell;
        row["chain_id"] = text(item.chain);
        row["parent_record_id"] = item.parent;
        row["ai_prompt_hint"] = item.hint;
        row["ai_requested"] = item.requested;
        scheduled.push_back(row);
    }
    out["scheduled_events"] = scheduled;
    out["chronicle"] = encode_records(_chronicle);
    out["dynamic_events_by_id"] = encode_map(_dynamic,
        [](const NarrativeDefinition &def) { return def.presentation; });

    Dictionary unrest;
    unrest["schema"] = "PKStratumUnrest";
    unrest["version"] = 1;
    unrest["last_fact_id"] = _last_unrest_fact;
    unrest["last_day"] = _last_unrest_day;
    unrest["sequence"] = _unrest_sequence;
    unrest["needs_player_recovery"] = _recover_unrest;
    Array independence;
    for (const auto &item : _independence) {
        Dictionary row;
        row["cell"] = item.cell;
        row["owner_handle"] = static_cast<int64_t>(item.owner);
        row["queued_day"] = item.queued;
        row["stable_id"] = text(item.stable_id);
        row["submitted"] = item.submitted;
        independence.push_back(row);
    }
    unrest["pending_independence"] = independence;
    Array checks;
    for (const auto &item : _unrest_checks) {
        Dictionary row;
        row["cell"] = item.cell;
        row["profession"] = item.profession;
        row["stage"] = item.stage;
        row["owner_handle"] = static_cast<int64_t>(item.owner);
        checks.push_back(row);
    }
    unrest["pending_stage_checks"] = checks;
    out["stratum_unrest"] = unrest;
    return out.duplicate(true);
}

void RuntimeNarrative::restore(const Dictionary &state) {
    if (state.is_empty()) return;
    _country = int64_t(state.get("player_country_handle", static_cast<int64_t>(_country)));
    _seed = std::max<int64_t>(1, state.get("world_seed", static_cast<int64_t>(_seed)));
    const auto next = [&](const char *key) { return std::max<int64_t>(1, state.get(key, 1)); };
    _next_offer = next("next_offer_id");
    _next_generation = next("next_offer_generation");
    _next_record = next("next_record_id");
    _next_bias = next("next_bias_id");
    _next_modifier_source = next("next_mod_source_id");
    _next_ai = next("next_ai_request_seq");
    _next_pool = next("next_pool_id");
    _last_pulse = state.get("last_pulse_day", 0);
    _last_popup = state.get("last_popup_day", NEVER);
    _last_fact = state.get("last_fact_event_id", -1);
    _last_probe = state.get("last_state_probe_day", NEVER);
    _pause_mask = static_cast<uint16_t>(int32_t(state.get("event_pause_mask", _pause_mask)));
    _last_notification_fact = state.get("last_notification_fact", std::max<int64_t>(0, _last_fact));
    _notification_sequence = state.get("notification_sequence", 0);
    _last_notice_era = state.get("last_notice_era", -1);
    _pending_choice = record_or_empty(state.get("pending_choice", Variant())).duplicate(true);
    const auto pending_masks = rows_or_empty(state.get("pending_event_pause_masks", Variant()));
    for (int64_t index = 0; index < pending_masks.size(); ++index) {
        if (pending_masks[index].get_type() != Variant::ARRAY) continue;
        const Array row = pending_masks[index];
        if (row.size() == 2)
            _pause_updates.emplace_back(int64_t(row[0]), static_cast<uint16_t>(int32_t(row[1])));
    }
    _last_ai = state.get("last_ai_request_day", NEVER);
    _pending_ai = record_or_empty(state.get("pending_ai_request", Variant())).duplicate(true);

    _active = record_or_empty(state.get("active_offer", Variant())).duplicate(true);
    decode_records(state.get("ready_queue", Array()),
        [&](const Dictionary &row) { _queue.push_back(row.duplicate(true)); });
    decode_records(state.get("chronicle", Array()),
        [&](const Dictionary &row) { _chronicle.push_back(row.duplicate(true)); });
    decode_records(state.get("ai_event_pool", Array()), [&](const Dictionary &row) {
        auto def = _catalog.compile_event(record_or_empty(row.get("def_dict", Variant())));
        if (!def.id.empty()) _pool.push_back({row.get("pool_id", 0),
            row.get("created_day", 0), row.get("cell_idx", -1),
            narrative_key(row.get("state_id", "")), std::move(def)});
    });
    if (_pool.size() > 24) _pool.erase(_pool.begin(), _pool.end() - 24);
    const auto tracking = record_or_empty(state.get("state_tracking", Variant()));
    const auto keys = tracking.keys();
    for (int64_t i = 0; i < keys.size(); ++i) {
        const auto row = record_or_empty(tracking[keys[i]]);
        if (row.is_empty()) continue;
        _tracking.push_back({narrative_key(keys[i]), row.get("cell", -1), row.get("since_day", 0),
            row.get("last_seen_day", 0), row.get("peak_price_ratio", 1.0),
            row.get("min_satisfaction", 0.65)});
    }
    const auto integer = [](const Variant &value) { return int64_t(value); };
    decode_map(record_or_empty(state.get("state_last_seed", Variant())), _last_seed, integer);
    decode_map(record_or_empty(state.get("cell_year_event_counts", Variant())), _year_counts, integer);
    decode_map(record_or_empty(state.get("cooldowns", Variant())), _cooldowns, integer);
    decode_map(record_or_empty(state.get("completed_one_shots", Variant())), _completed, integer);
    decode_map(record_or_empty(state.get("story_flags", Variant())), _flags, [](const Variant &value) {
        const auto row = record_or_empty(value);
        return Flag{row.get("set_day", 0), row.get("expires_day", -1), row.get("value", 1)};
    });
    decode_records(state.get("weight_biases", Array()), [&](const Dictionary &row) {
        _biases.push_back({row.get("id", 0), row.get("add_weight", 0),
            row.get("mul_q16", 65536), row.get("expires_day", -1),
            row.get("scope_cell", -1), narrative_key(row.get("target_event_id", "")),
            narrative_key(row.get("target_tag", "")), narrative_key(row.get("source_event_id", ""))});
    });
    decode_records(state.get("scheduled_events", Array()), [&](const Dictionary &row) {
        _followups.push_back({row.get("due_day", 0), row.get("parent_record_id", 0),
            row.get("cell_idx", -1), narrative_key(row.get("event_id", "")),
            narrative_key(row.get("chain_id", "")), row.get("ai_prompt_hint", ""),
            row.get("ai_requested", false)});
    });
    decode_map(record_or_empty(state.get("dynamic_events_by_id", Variant())), _dynamic,
        [&](const Variant &value) { return _catalog.compile_event(record_or_empty(value)); });

    const auto unrest = record_or_empty(state.get("stratum_unrest", Variant()));
    _last_unrest_fact = unrest.get("last_fact_id", -1);
    _last_unrest_day = unrest.get("last_day", -1);
    _day = _last_unrest_day;
    _unrest_sequence = std::max<int64_t>(1, unrest.get("sequence", 1));
    _recover_unrest = unrest.get("needs_player_recovery", true);
    decode_records(unrest.get("pending_independence", Array()), [&](const Dictionary &row) {
        _independence.push_back({row.get("cell", -1), uint64_t(int64_t(row.get("owner_handle", 0))),
            row.get("queued_day", 0), narrative_key(row.get("stable_id", "")),
            row.get("submitted", false)});
    });
    decode_records(unrest.get("pending_stage_checks", Array()), [&](const Dictionary &row) {
        _unrest_checks.push_back({row.get("cell", -1), row.get("profession", -1),
            row.get("stage", 0), uint64_t(int64_t(row.get("owner_handle", 0)))});
    });
}

} // namespace pk
