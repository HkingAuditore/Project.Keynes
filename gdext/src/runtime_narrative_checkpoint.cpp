#include "runtime_narrative.h"

#include <initializer_list>

namespace pk {
using namespace godot;

namespace {
bool has_type(const Variant &value, Variant::Type type) {
    return value.get_type() == type ||
        (type == Variant::FLOAT && value.get_type() == Variant::INT) ||
        (type == Variant::STRING && value.get_type() == Variant::STRING_NAME);
}

String fields(const Dictionary &record, const String &path, Variant::Type type,
        std::initializer_list<const char *> keys) {
    for (const char *key : keys) {
        if (record.has(key) && !has_type(record[key], type)) return path + String(key);
    }
    return {};
}

template <class Validate>
String records(const Dictionary &archive, const char *key, Validate validate) {
    const Array rows = archive.get(key, Array());
    for (int64_t index = 0; index < rows.size(); ++index) {
        const String path = String(key) + String("[") + String::num_int64(index) + String("]");
        if (rows[index].get_type() != Variant::DICTIONARY) return path;
        const auto error = validate(Dictionary(rows[index]), path + String("."));
        if (!error.is_empty()) return error;
    }
    return {};
}

String id_record(const Dictionary &record, const String &path, const char *key) {
    if (record.get(key, Variant()).get_type() != Variant::INT || int64_t(record[key]) <= 0)
        return path + String(key);
    return {};
}

String setting_updates(const Dictionary &archive, const char *key, Variant::Type value_type) {
    const Array updates = archive.get(key, Array());
    int64_t previous_day = -1;
    for (int64_t index = 0; index < updates.size(); ++index) {
        const String path = String(key) + String("[") + String::num_int64(index) + String("]");
        if (updates[index].get_type() != Variant::ARRAY) return path;
        const Array row = updates[index];
        if (row.size() != 2 || row[0].get_type() != Variant::INT ||
            row[1].get_type() != value_type || int64_t(row[0]) <= previous_day)
            return path;
        previous_day = row[0];
    }
    return {};
}

String definition_error(const Variant &value, const String &path) {
    if (value.get_type() != Variant::DICTIONARY) return path;
    const Dictionary definition(value);
    const auto id = definition.get("event_id", Variant());
    return has_type(id, Variant::STRING) && !narrative_key(id).empty() ? String() : path + String(".event_id");
}

String ai_request_error(const Dictionary &request, const Dictionary &reply, const String &path) {
    // Older requests without a settlement date cannot be replayed.
    if (request.is_empty() || !request.has("effective_day")) {
        return reply.is_empty() ? String() : path + String(".reply");
    }
    auto error = id_record(request, path + String("."), "ai_request_seq");
    if (!error.is_empty()) return error;
    error = fields(request, path + String("."), Variant::INT, {"day", "effective_day", "due_day", "cell_idx"});
    if (!error.is_empty()) return error;
    if (!request.has("day") || int64_t(request["day"]) < 0 ||
        int64_t(request["effective_day"]) < int64_t(request["day"])) return path + String(".effective_day");
    if (request.get("cell_ctx", Variant()).get_type() != Variant::DICTIONARY) return path + String(".cell_ctx");
    if (reply.is_empty()) return {};
    if (reply.get("ok", Variant()).get_type() != Variant::BOOL) return path + String(".reply.ok");
    if (bool(reply["ok"])) return definition_error(reply.get("definition", Variant()), path + String(".reply.definition"));
    return fields(reply, path + String(".reply."), Variant::STRING, {"code"});
}
} // namespace

String RuntimeNarrative::checkpoint_error(const Dictionary &archive) {
    auto error = fields(archive, "", Variant::INT, {
        "version", "world_seed", "player_country_handle", "next_offer_id", "next_offer_generation",
        "next_record_id", "next_bias_id", "next_mod_source_id", "last_pulse_day", "last_popup_day",
        "last_fact_event_id", "last_ai_request_day", "next_ai_request_seq", "last_state_probe_day",
        "event_pause_mask", "last_notification_fact", "notification_sequence", "last_notice_era", "next_pool_id"});
    if (!error.is_empty()) return error;
    error = fields(archive, "", Variant::BOOL, {"ai_enabled"});
    if (!error.is_empty()) return error;
    error = fields(archive, "", Variant::ARRAY, {"ready_queue", "chronicle", "ai_event_pool",
        "weight_biases", "scheduled_events", "pending_event_pause_masks", "pending_ai_settings",
        "pending_ai_requests"});
    if (!error.is_empty()) return error;
    error = fields(archive, "", Variant::DICTIONARY, {"active_offer", "pending_choice",
        "pending_ai_request", "pending_ai_reply", "state_tracking", "state_last_seed",
        "cell_year_event_counts", "cooldowns", "completed_one_shots", "story_flags",
        "dynamic_events_by_id", "stratum_unrest"});
    if (!error.is_empty()) return error;

    for (const char *key : {"state_last_seed", "cell_year_event_counts", "cooldowns", "completed_one_shots"}) {
        const Dictionary map = archive.get(key, Dictionary());
        const Array keys = map.keys();
        for (int64_t index = 0; index < keys.size(); ++index) {
            if (!has_type(keys[index], Variant::STRING) || map[keys[index]].get_type() != Variant::INT)
                return String(key) + String(".") + String(keys[index]);
        }
    }
    for (const char *key : {"state_tracking", "story_flags", "dynamic_events_by_id"}) {
        const Dictionary map = archive.get(key, Dictionary());
        const Array keys = map.keys();
        for (int64_t index = 0; index < keys.size(); ++index) {
            const auto &value = map[keys[index]];
            const String path = String(key) + String(".") + String(keys[index]);
            if (!has_type(keys[index], Variant::STRING) || value.get_type() != Variant::DICTIONARY)
                return path;
            if (String(key) == "dynamic_events_by_id") {
                error = definition_error(value, path);
            } else if (String(key) == "story_flags") {
                error = fields(Dictionary(value), path + String("."), Variant::INT, {"set_day", "expires_day", "value"});
            } else {
                error = fields(Dictionary(value), path + String("."), Variant::INT, {"cell", "since_day", "last_seen_day"});
                if (error.is_empty()) error = fields(Dictionary(value), path + String("."), Variant::FLOAT,
                    {"peak_price_ratio", "min_satisfaction"});
            }
            if (!error.is_empty()) return error;
        }
    }
    const Dictionary active = archive.get("active_offer", Dictionary());
    if (!active.is_empty()) {
        error = id_record(active, "active_offer.", "offer_id");
        if (!error.is_empty()) return error;
    }
    const Dictionary choice = archive.get("pending_choice", Dictionary());
    if (!choice.is_empty()) {
        for (const char *key : {"effective_day", "offer_id", "offer_generation", "option_index"}) {
            if (choice.get(key, Variant()).get_type() != Variant::INT || int64_t(choice[key]) < 0)
                return String("pending_choice.") + String(key);
        }
        error = fields(choice, "pending_choice.", Variant::BOOL, {"automatic"});
        if (!error.is_empty()) return error;
    }
    error = records(archive, "ready_queue", [](const Dictionary &row, const String &path) {
        return id_record(row, path, "offer_id");
    });
    if (!error.is_empty()) return error;
    error = records(archive, "chronicle", [](const Dictionary &row, const String &path) {
        return id_record(row, path, "record_id");
    });
    if (!error.is_empty()) return error;
    error = records(archive, "weight_biases", [](const Dictionary &row, const String &path) {
        return fields(row, path, Variant::INT, {"id", "add_weight", "mul_q16", "expires_day", "scope_cell"});
    });
    if (!error.is_empty()) return error;
    error = records(archive, "scheduled_events", [](const Dictionary &row, const String &path) {
        if (row.get("due_day", Variant()).get_type() != Variant::INT) return path + String("due_day");
        const auto typed = fields(row, path, Variant::INT, {"cell_idx", "parent_record_id"});
        return typed.is_empty() ? fields(row, path, Variant::BOOL, {"ai_requested"}) : typed;
    });
    if (!error.is_empty()) return error;
    error = records(archive, "ai_event_pool", [](const Dictionary &row, const String &path) {
        return definition_error(row.get("def_dict", Variant()), path + String("def_dict"));
    });
    if (!error.is_empty()) return error;
    error = setting_updates(archive, "pending_event_pause_masks", Variant::INT);
    if (!error.is_empty()) return error;
    error = setting_updates(archive, "pending_ai_settings", Variant::BOOL);
    if (!error.is_empty()) return error;
    const Dictionary single = archive.get("pending_ai_request", Dictionary());
    error = ai_request_error(single, archive.get("pending_ai_reply", Dictionary()), "pending_ai_request");
    if (!error.is_empty()) return error;
    int64_t prior_request = single.get("ai_request_seq", 0);
    const Array requests = archive.get("pending_ai_requests", Array());
    if (!requests.is_empty() && !single.is_empty()) return "pending_ai_requests";
    error = records(archive, "pending_ai_requests", [&](const Dictionary &row, const String &path) {
        const auto types = fields(row, path, Variant::DICTIONARY, {"request", "reply"});
        if (!types.is_empty()) return types;
        const Dictionary request = row.get("request", Dictionary());
        if (!request.has("effective_day")) return path + String("request.effective_day");
        const auto invalid = ai_request_error(request, row.get("reply", Dictionary()), path + String("request"));
        if (!invalid.is_empty()) return invalid;
        const int64_t sequence = request["ai_request_seq"];
        if (sequence <= prior_request) return path + String("request.ai_request_seq");
        prior_request = sequence;
        return String();
    });
    if (!error.is_empty()) return error;
    if (archive.has("next_ai_request_seq") && int64_t(archive["next_ai_request_seq"]) <= prior_request)
        return "next_ai_request_seq";

    const Dictionary unrest = archive.get("stratum_unrest", Dictionary());
    error = fields(unrest, "stratum_unrest.", Variant::INT, {"last_fact_id", "last_day", "sequence"});
    if (!error.is_empty()) return error;
    error = fields(unrest, "stratum_unrest.", Variant::BOOL, {"needs_player_recovery"});
    if (!error.is_empty()) return error;
    error = fields(unrest, "stratum_unrest.", Variant::ARRAY, {"pending_independence", "pending_stage_checks"});
    if (!error.is_empty()) return error;
    error = records(unrest, "pending_independence", [](const Dictionary &row, const String &path) {
        return fields(row, String("stratum_unrest.") + path, Variant::INT, {"cell", "owner_handle", "queued_day"});
    });
    if (!error.is_empty()) return error;
    return records(unrest, "pending_stage_checks", [](const Dictionary &row, const String &path) {
        return fields(row, String("stratum_unrest.") + path, Variant::INT, {"cell", "owner_handle", "profession", "stage"});
    });
}

} // namespace pk
