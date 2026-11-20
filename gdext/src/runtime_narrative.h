#pragma once

#include "runtime_narrative_catalog.h"
#include "runtime_pod_protocol.h"

#include <deque>
#include <memory>

namespace pk {

struct RuntimeEventsRecord;
struct RuntimeCountryPodSnapshot;

struct NarrativeDay {
    int64_t day;
    NarrativeCountryView country;
    std::function<NarrativeCellView(int32_t, bool)> sample;
    std::function<uint64_t(int32_t)> owner;
    std::function<int32_t(uint64_t)> territory_count;
    std::function<bool(int32_t, std::vector<NarrativeUnrestRow> &)> unrest_rows;
    std::function<NarrativeUnrestOdds(int32_t, int32_t, int32_t)> unrest_odds;
    const std::vector<std::string> &professions;
};

struct NarrativeIndependenceAction {
    int32_t cell = -1;
    uint64_t old_owner = 0, new_owner = 0;
    int64_t sequence = 0;
    std::string stable_id, display_name;
};

struct RuntimeNarrativeView {
    int64_t day = -1;
    int64_t popup_day = -999;
    godot::Dictionary active_offer;
    godot::Array queue, chronicle;
    uint16_t pause_mask = 0x00ff;
    int64_t unrest_fact = -1;
    godot::Dictionary ai_request;
    int64_t waiting_for_external_input_day = -1;
    bool ai_enabled = false;
    bool ai_enabled_requested = false;
};

// Control requests run between committed days. The response is written before
// signaling the requesting thread under the host control mutex.
struct RuntimeNarrativeRequest {
    enum class Kind { CHOOSE, AI_RESULT, SET_AI, PAUSE_POLICY };
    Kind kind = Kind::CHOOSE;
    godot::Dictionary args, result;
    bool done = false;
};

class RuntimeNarrative {
public:
    void sample_country(const RuntimeCountryPodSnapshot &, NarrativeCountryView &) const;
    bool configure(const godot::Dictionary &packet, const godot::Dictionary &archive);
    int64_t step(const NarrativeDay &input, const std::vector<RuntimeEventsRecord> &facts,
                 int64_t acknowledged);
    godot::Dictionary capture() const;
    std::shared_ptr<const RuntimeNarrativeView> view(int64_t committed_day) const;
    godot::Dictionary queue_choice(int64_t day, const godot::Dictionary &args, bool automatic = false);
    godot::Dictionary take_due_choice(int64_t day);
    void queue_automatic_choice(int64_t day);
    void set_pause_policy(int64_t day, uint16_t mask);
    void apply_pause_policy(int64_t day);
    std::vector<RuntimeNotice> take_notices();
    void economy_notices(const NarrativeDay &, const std::vector<NarrativeEconomyNotice> &);
    godot::Dictionary begin_choice(const NarrativeDay &input, const godot::Dictionary &args);
    godot::Dictionary complete_choice(godot::Dictionary result, bool apply_local = true);
    void settle_economy_effects(const std::function<bool(int64_t, std::string &)> &receipt);
    std::vector<NarrativeIndependenceAction> take_independence_actions();
    int64_t allocate_modifier_source() { return _next_modifier_source++; }
    godot::Dictionary queue_ai_reply(const godot::Dictionary &result);
    void set_ai_enabled(int64_t day, bool enabled);
    void apply_ai_policy(int64_t day);
    uint64_t player() const { return _country; }
    const RuntimeNarrativeCatalog &catalog() const { return _catalog; }
    bool placing_choice() const { return !_choice_record.is_empty(); }
    void finish_unrest_choice(bool applied, int64_t day);
    const godot::Dictionary &choice_record() const { return _choice_record; }
    int64_t allocate_unrest_sequence() { return ++_unrest_sequence; }

private:
    struct Flag { int64_t set, expires, value; };
    struct Bias {
        int64_t id, add, factor, expires;
        int32_t cell;
        std::string event, tag, source;
    };
    struct Followup {
        int64_t due, parent;
        int32_t cell;
        std::string event, chain;
        godot::String hint;
        bool requested = false;
    };
    struct ProbeTracking {
        std::string key;
        int32_t cell;
        int64_t since, seen;
        double peak_price, min_satisfaction;
    };
    struct PoolEntry {
        int64_t id, created;
        int32_t cell;
        std::string state;
        NarrativeDefinition definition;
    };
    struct UnrestPending {
        int32_t cell, profession, stage;
        uint64_t owner;
    };
    struct Independence {
        int32_t cell;
        uint64_t owner;
        int64_t queued;
        std::string stable_id;
        bool submitted = false;
    };

    static constexpr int64_t NEVER = -999;
    RuntimeNarrativeCatalog _catalog;
    uint64_t _country = 0, _seed = 1;
    int64_t _days_per_year = 365, _day = -1;
    bool _ai_enabled = false;
    std::deque<std::pair<int64_t, bool>> _ai_updates;
    uint16_t _pause_mask = 0x00ff;
    std::deque<std::pair<int64_t, uint16_t>> _pause_updates;
    godot::Dictionary _pending_choice;
    int64_t _next_offer = 1, _next_generation = 1, _next_record = 1;
    int64_t _next_bias = 1, _next_modifier_source = 1, _next_pool = 1;
    int64_t _last_pulse = 0, _last_popup = NEVER, _last_fact = -1, _last_probe = NEVER;
    int64_t _last_ai = NEVER, _next_ai = 1;
    int64_t _last_unrest_fact = -1, _last_unrest_day = -1, _unrest_sequence = 1;
    bool _recover_unrest = true;
    std::unordered_map<std::string, int64_t> _cooldowns, _completed, _last_seed, _year_counts;
    std::unordered_map<std::string, Flag> _flags;
    std::vector<Bias> _biases;
    std::vector<Followup> _followups;
    std::vector<ProbeTracking> _tracking;
    std::vector<PoolEntry> _pool;
    std::unordered_map<std::string, NarrativeDefinition> _dynamic;
    std::vector<UnrestPending> _unrest_checks;
    std::vector<Independence> _independence;
    std::vector<NarrativeIndependenceAction> _independence_actions;
    godot::Dictionary _pending_ai, _pending_ai_reply;
    // Offers and records keep the established pknr/presentation shape. No
    // condition reads the presentation payload to sample the simulation.
    std::vector<RuntimeNotice> _notices;
    godot::Dictionary _active, _choice_record, _choice_context;
    godot::Array _choice_effects;
    std::deque<godot::Dictionary> _queue, _chronicle;
    int64_t _choice_day = -1;

    int32_t weight(const NarrativeDefinition &, const NarrativeDay &, const NarrativeCellView &) const;
    bool enqueue(const NarrativeDefinition &, const NarrativeDay &, int32_t cell,
        const std::string &chain = {}, bool bypass = false, const godot::Dictionary &meta = {},
        int64_t chain_salt = 0, const godot::Array &odds = {});
    int64_t _last_notification_fact = 0, _notification_sequence = 0;
    int32_t _last_notice_era = -1;
    void enqueue_notice(const NarrativeDay &, int32_t cell, int32_t category,
                        const char *id, const char *title);
    void fact_notices(const NarrativeDay &, const std::vector<RuntimeEventsRecord> &);
    void promote(int64_t day);
    godot::Dictionary validate_choice(const godot::Dictionary &args) const;
    bool stops_for(const godot::Dictionary &offer, uint16_t mask) const;
    uint16_t pause_policy_for(int64_t day) const;
    bool flag_present(const std::string &key, int32_t cell) const;
    void local_effect(const NarrativeEffect &, int32_t cell, int64_t effective);
    void prune(int64_t day);
    void followups(const NarrativeDay &);
    void poll_probes(const NarrativeDay &);
    void flush_pool(const NarrativeDay &);
    void pulse(const NarrativeDay &);
    void fact(const NarrativeDay &, const RuntimeEventsRecord &, size_t index, bool &hit);
    void unrest(const NarrativeDay &, const std::vector<RuntimeEventsRecord> &);
    void queue_independence(int32_t cell, uint64_t owner);
    void advance_independence(const NarrativeDay &);
    bool probe_matches(const NarrativeProbe &, const NarrativeDay &, const NarrativeCellView &) const;
    bool ai_allowed(int64_t day) const;
    bool request_ai(const NarrativeDay &, const NarrativeCellView &, const Followup &request,
        const godot::String &fact = {}, const std::string &state = {},
        const godot::String &state_hint = {}, bool scheduled = false);
    void apply_ai_reply(const NarrativeDay &);
    bool ai_event_eligible(const NarrativeDefinition &, const NarrativeDay &,
                           const NarrativeCellView &) const;
    void store_ai(const std::string &state, NarrativeDefinition &&, int32_t cell, int64_t day);
    static int ai_pressure(const NarrativeCountryView &, const NarrativeCellView &);
    std::vector<int32_t> sampled_cells(const NarrativeDay &) const;
    bool paced(int64_t day) const;
    bool cell_capped(int32_t cell, int64_t day) const;
    int64_t roll(int64_t day, int32_t cell, int64_t salt) const;
    int64_t pick(const std::vector<int64_t> &weights, int64_t day, int32_t cell, int64_t salt) const;
    const NarrativeDefinition *definition(const std::string &) const;
    godot::Dictionary context(const NarrativeDay &, const NarrativeCellView &) const;
    godot::String date_text(int64_t day) const;
    void restore(const godot::Dictionary &);
};

godot::String narrative_format(const godot::String &, const godot::Dictionary &);
godot::String narrative_percent(double fraction);
godot::Dictionary narrative_response(bool ok, const char *code, const char *message = "");

} // namespace pk
