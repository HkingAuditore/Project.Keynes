#include "world_ext.h"
#include "country_ai_runtime.h"
#include "country_core_apply.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr uint32_t PKAW_MAGIC = 0x57414b50u; // "PKAW"
constexpr uint32_t PKAW_VERSION = 1u;

CountryAiRuntime *ai_from(void *opaque) { return static_cast<CountryAiRuntime *>(opaque); }
const CountryAiRuntime *ai_from(const void *opaque) {
    return static_cast<const CountryAiRuntime *>(opaque);
}

Dictionary ai_unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["code"] = "country_ai_unavailable";
    return out;
}

int64_t dict_i64(const Dictionary &d, const char *key, int64_t fallback) {
    if (!d.has(key)) return fallback;
    const Variant v = d[key];
    if (v.get_type() == Variant::INT) return static_cast<int64_t>(v);
    if (v.get_type() == Variant::FLOAT) return static_cast<int64_t>(static_cast<double>(v));
    if (v.get_type() == Variant::BOOL) return static_cast<bool>(v) ? 1 : 0;
    return fallback;
}

int32_t dict_i32(const Dictionary &d, const char *key, int32_t fallback) {
    return static_cast<int32_t>(dict_i64(d, key, fallback));
}

template <size_t N>
bool dict_array(const Dictionary &d, const char *key, std::array<int32_t, N> &out) {
    if (!d.has(key)) return true;
    const Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
        const PackedInt32Array a = v;
        if (a.size() != static_cast<int64_t>(N)) return false;
        for (size_t i = 0; i < N; ++i) out[i] = a[static_cast<int64_t>(i)];
        return true;
    }
    if (v.get_type() == Variant::ARRAY) {
        const Array a = v;
        if (a.size() != static_cast<int64_t>(N)) return false;
        for (size_t i = 0; i < N; ++i) out[i] = static_cast<int32_t>(static_cast<int64_t>(a[static_cast<int64_t>(i)]));
        return true;
    }
    return false;
}

uint64_t fnv_string(const String &s) {
    const CharString utf8 = s.utf8();
    uint64_t h = 1469598103934665603ull;
    for (int64_t i = 0; i < utf8.length(); ++i) {
        h ^= static_cast<uint8_t>(utf8.get_data()[i]);
        h *= 1099511628211ull;
    }
    return h;
}

bool parse_mode(const String &text, CountryAiMode &mode) {
    const String upper = text.to_upper();
    if (upper == "OFF") { mode = CountryAiMode::OFF; return true; }
    if (upper == "PROBE") { mode = CountryAiMode::PROBE; return true; }
    if (upper == "ACTIVE") { mode = CountryAiMode::ACTIVE; return true; }
    return false;
}

const char *mode_name(CountryAiMode mode) {
    switch (mode) {
    case CountryAiMode::PROBE: return "PROBE";
    case CountryAiMode::ACTIVE: return "ACTIVE";
    default: return "OFF";
    }
}

int32_t agenda_index(const String &id) {
    for (uint8_t a = 0; a < COUNTRY_AI_AGENDA_COUNT; ++a)
        if (id == String(country_ai_agenda_name(a))) return a;
    return -1;
}

bool parse_catalog(const Dictionary &d, CountryAiCatalog &c, std::vector<std::string> &ids,
                   std::string &error) {
    c.schema = static_cast<uint32_t>(dict_i64(d, "schema", COUNTRY_AI_SCHEMA));
    c.seed = static_cast<uint64_t>(dict_i64(d, "seed", 0));
    c.think_days = dict_i32(d, "think_days", c.think_days);
    c.strategy_days = dict_i32(d, "strategy_days", c.strategy_days);
    c.research_days = dict_i32(d, "research_days", c.research_days);
    c.tax_days = dict_i32(d, "tax_days", c.tax_days);
    c.colonize_days = dict_i32(d, "colonize_days", c.colonize_days);
    c.agenda_min_days = dict_i32(d, "agenda_min_days", c.agenda_min_days);
    c.agenda_inertia_bp = dict_i32(d, "agenda_inertia_bp", c.agenda_inertia_bp);
    c.decision_noise_bp = dict_i32(d, "decision_noise_bp", c.decision_noise_bp);
    c.research_budget_horizon_days = dict_i32(d, "research_budget_horizon_days", c.research_budget_horizon_days);
    c.research_min_daily_budget = dict_i64(d, "research_min_daily_budget", c.research_min_daily_budget);
    c.research_max_daily_budget = dict_i64(d, "research_max_daily_budget", c.research_max_daily_budget);
    c.research_weight_threshold_bp = dict_i32(d, "research_weight_threshold_bp", c.research_weight_threshold_bp);
    c.research_max_enqueue_per_eval = dict_i32(d, "research_max_enqueue_per_eval", c.research_max_enqueue_per_eval);
    c.research_budget_change_bp = dict_i32(d, "research_budget_change_bp", c.research_budget_change_bp);
    c.research_frontier_visit_limit = dict_i32(d, "research_frontier_visit_limit", c.research_frontier_visit_limit);
    c.research_tax_share_bp = dict_i32(d, "research_tax_share_bp", c.research_tax_share_bp);
    c.research_per_capita_budget = dict_i64(d, "research_per_capita_budget", c.research_per_capita_budget);
    c.research_essentials_floor_q16 = dict_i32(d, "research_essentials_floor_q16", c.research_essentials_floor_q16);
    c.tax_kind_mask = static_cast<uint32_t>(dict_i64(d, "tax_kind_mask", c.tax_kind_mask));
    c.tax_step_bp = dict_i32(d, "tax_step_bp", c.tax_step_bp);
    c.tax_max_step_bp = dict_i32(d, "tax_max_step_bp", c.tax_max_step_bp);
    c.tax_deadband_q16 = dict_i32(d, "tax_deadband_q16", c.tax_deadband_q16);
    c.satisfaction_floor_q16 = dict_i32(d, "satisfaction_floor_q16", c.satisfaction_floor_q16);
    c.reserve_target_days = dict_i32(d, "reserve_target_days", c.reserve_target_days);
    c.reserve_floor_cash = dict_i64(d, "reserve_floor_cash", c.reserve_floor_cash);
    c.colonize_max_in_flight = dict_i32(d, "colonize_max_in_flight", c.colonize_max_in_flight);
    c.colonize_population_share_bp = dict_i32(d, "colonize_population_share_bp", c.colonize_population_share_bp);
    c.colonize_min_population = dict_i64(d, "colonize_min_population", c.colonize_min_population);
    c.colonize_vision_radius = dict_i32(d, "colonize_vision_radius", c.colonize_vision_radius);
    c.colonize_target_ring = dict_i32(d, "colonize_target_ring", c.colonize_target_ring);
    c.colonize_failure_cooldown_days = dict_i32(d, "colonize_failure_cooldown_days", c.colonize_failure_cooldown_days);
    c.colonize_min_reserve_days = dict_i32(d, "colonize_min_reserve_days", c.colonize_min_reserve_days);
    c.colonize_min_country_population = dict_i64(d, "colonize_min_country_population", c.colonize_min_country_population);
    c.colonize_min_population_per_cell = dict_i64(d, "colonize_min_population_per_cell", c.colonize_min_population_per_cell);
    c.colonize_essentials_floor_q16 = dict_i32(d, "colonize_essentials_floor_q16", c.colonize_essentials_floor_q16);
    c.colonize_min_cell_value_q16 = dict_i32(d, "colonize_min_cell_value_q16", c.colonize_min_cell_value_q16);
    c.colonize_cell_value_weight_bp = dict_i32(d, "colonize_cell_value_weight_bp", c.colonize_cell_value_weight_bp);
    c.research_load_full_q16 = dict_i32(d, "research_load_full_q16", c.research_load_full_q16);
    c.research_load_zero_q16 = dict_i32(d, "research_load_zero_q16", c.research_load_zero_q16);
    c.research_hungry_share_max_q16 = dict_i32(d, "research_hungry_share_max_q16", c.research_hungry_share_max_q16);
    c.colonize_hungry_share_max_q16 = dict_i32(d, "colonize_hungry_share_max_q16", c.colonize_hungry_share_max_q16);
    c.subsidy_food_rate_bp = dict_i32(d, "subsidy_food_rate_bp", c.subsidy_food_rate_bp);
    c.subsidy_on_hungry_share_q16 = dict_i32(d, "subsidy_on_hungry_share_q16", c.subsidy_on_hungry_share_q16);
    c.subsidy_off_hungry_share_q16 = dict_i32(d, "subsidy_off_hungry_share_q16", c.subsidy_off_hungry_share_q16);
    const Array agendas = d.get("agendas", Array());
    if (agendas.size() != COUNTRY_AI_AGENDA_COUNT) {
        error = "country_ai_agenda_count_invalid";
        return false;
    }
    std::array<bool, COUNTRY_AI_AGENDA_COUNT> seen{};
    for (int64_t i = 0; i < agendas.size(); ++i) {
        const Dictionary a = agendas[i];
        const int32_t index = agenda_index(String(a.get("id", "")));
        if (index < 0 || seen[static_cast<size_t>(index)]) {
            error = "country_ai_agenda_id_invalid";
            return false;
        }
        seen[static_cast<size_t>(index)] = true;
        CountryAiAgendaDef &def = c.agendas[static_cast<size_t>(index)];
        const Array considerations = a.get("considerations", Array());
        if (considerations.size() > COUNTRY_AI_MAX_CONSIDERATIONS) {
            error = "country_ai_agenda_considerations_invalid";
            return false;
        }
        def.consideration_count = static_cast<uint8_t>(considerations.size());
        for (int64_t k = 0; k < considerations.size(); ++k) {
            const Dictionary cd = considerations[k];
            CountryAiCurve &curve = def.considerations[static_cast<size_t>(k)];
            curve.input = static_cast<uint8_t>(dict_i32(cd, "input", 0));
            curve.kind = static_cast<uint8_t>(dict_i32(cd, "curve", 0));
            curve.x0 = dict_i64(cd, "x0", 0);
            curve.x1 = dict_i64(cd, "x1", 1);
            curve.y0_q16 = dict_i32(cd, "y0_q16", 0);
            curve.y1_q16 = dict_i32(cd, "y1_q16", COUNTRY_AI_Q16);
        }
        def.research_share_bp = dict_i32(a, "research_share_bp", def.research_share_bp);
        def.expansion_slots = dict_i32(a, "expansion_slots", def.expansion_slots);
        def.tax_bias_bp = dict_i32(a, "tax_bias_bp", def.tax_bias_bp);
        def.satisfaction_floor_shift_q16 = dict_i32(a, "satisfaction_floor_shift_q16", def.satisfaction_floor_shift_q16);
        def.era_focus = dict_i64(a, "era_focus", 0) != 0 ? 1 : 0;
    }
    const Array personalities = d.get("personalities", Array());
    ids.clear();
    c.personalities.clear();
    for (int64_t i = 0; i < personalities.size(); ++i) {
        const Dictionary p = personalities[i];
        CountryAiPersonality personality;
        const String id = p.get("id", "");
        personality.id_hash = fnv_string(id);
        personality.weight = dict_i32(p, "weight", 1);
        personality.risk_bp = dict_i32(p, "risk_bp", personality.risk_bp);
        if (!dict_array(p, "agenda_bias_bp", personality.agenda_bias_bp) ||
            !dict_array(p, "domain_affinity_bp", personality.domain_affinity_bp) ||
            !dict_array(p, "tax_min_bp", personality.tax_min_bp) ||
            !dict_array(p, "tax_max_bp", personality.tax_max_bp) ||
            !dict_array(p, "tax_initial_bp", personality.tax_initial_bp) ||
            !dict_array(p, "family_pref", personality.family_pref)) {
            error = "country_ai_personality_array_invalid";
            return false;
        }
        c.personalities.push_back(personality);
        ids.push_back(std::string(id.utf8().get_data()));
    }
    return country_ai_validate_catalog(c, error);
}

Dictionary decision_to_dict(const CountryAiDecision &d) {
    Dictionary row;
    row["id"] = static_cast<int64_t>(d.id);
    row["day"] = d.day;
    row["slot"] = d.slot;
    row["handle"] = static_cast<int64_t>(d.handle);
    row["module"] = String(country_ai_module_name(d.module));
    row["outcome"] = String(country_ai_outcome_name(d.outcome));
    row["agenda"] = String(country_ai_agenda_name(d.agenda));
    row["subject"] = d.subject;
    row["value"] = d.value;
    row["amount"] = d.amount;
    row["score_q16"] = d.score_q16;
    PackedInt32Array alt_subject, alt_score;
    for (size_t i = 0; i < 3; ++i) {
        alt_subject.push_back(d.alt_subject[i]);
        alt_score.push_back(d.alt_score_q16[i]);
    }
    row["alt_subjects"] = alt_subject;
    row["alt_scores_q16"] = alt_score;
    row["reason"] = String(d.reason.data());
    return row;
}

struct WrapWriter {
    std::vector<uint8_t> bytes;
    void u32(uint32_t v) { for (int i = 0; i < 4; ++i) bytes.push_back(static_cast<uint8_t>(v >> (i * 8))); }
    void u64(uint64_t v) { for (int i = 0; i < 8; ++i) bytes.push_back(static_cast<uint8_t>(v >> (i * 8))); }
};

struct WrapReader {
    const uint8_t *data;
    size_t size;
    size_t at = 0;
    bool ok = true;
    uint32_t u32() {
        if (!ok || size - at < 4) { ok = false; return 0; }
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= static_cast<uint32_t>(data[at++]) << (i * 8);
        return v;
    }
    uint64_t u64() {
        if (!ok || size - at < 8) { ok = false; return 0; }
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= static_cast<uint64_t>(data[at++]) << (i * 8);
        return v;
    }
};

} // namespace

void DCWorldExt::attach_country_ai_to_host() {
    if (_runtime_host != nullptr)
        _runtime_host->attach_country_ai_runtime(ai_from(_country_ai_runtime));
}

void DCWorldExt::push_country_ai_family_preferences() {
    if (_economy_runtime == nullptr) return;
    NativeEconomyRuntime *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    if (_country_ai_runtime == nullptr) {
        economy->set_country_ai_family_preferences({});
        return;
    }
    economy->set_country_ai_family_preferences(ai_from(_country_ai_runtime)->family_preferences());
}

Dictionary DCWorldExt::configure_country_ai(const Dictionary &catalog) {
    Dictionary out;
    CountryAiCatalog parsed;
    std::vector<std::string> ids;
    std::string error;
    if (!parse_catalog(catalog, parsed, ids, error)) {
        out["ok"] = false;
        out["code"] = String(error.c_str());
        return out;
    }
    if (_country_ai_runtime == nullptr) _country_ai_runtime = new CountryAiRuntime();
    CountryAiRuntime *runtime = ai_from(_country_ai_runtime);
    if (!runtime->configure(parsed, error)) {
        out["ok"] = false;
        out["code"] = String(error.c_str());
        return out;
    }
    CountryAiMode mode = CountryAiMode::OFF;
    parse_mode(String(catalog.get("mode", "OFF")), mode);
    runtime->set_mode(mode);
    _country_ai_personality_ids = std::move(ids);
    _country_ai_sync_day = -1;
    _country_ai_catalog_cache.reset();
    if (_economy_runtime != nullptr) {
        NativeEconomyRuntime *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
        std::vector<CountryAiColonizationIntent> intents;
        std::vector<NativeEconomyRuntime::CountryAiColonizationStat> stats;
        int64_t cursor = 0;
        economy->export_country_ai_pending(intents, stats, cursor);
        // Keep the receipt cursor: receipts before reconfiguration belong to
        // the previous AI session and must not count as new failures.
        economy->import_country_ai_pending({}, {}, cursor);
    }
    push_country_ai_family_preferences();
    attach_country_ai_to_host();
    out["ok"] = true;
    out["code"] = "ok";
    out["mode"] = mode_name(mode);
    out["catalog_hash"] = static_cast<int64_t>(runtime->report().catalog_hash);
    out["personality_count"] = static_cast<int64_t>(parsed.personalities.size());
    return out;
}

Dictionary DCWorldExt::set_country_ai_mode(const String &mode_text) {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    Dictionary out;
    CountryAiMode mode = CountryAiMode::OFF;
    if (!parse_mode(mode_text, mode)) {
        out["ok"] = false;
        out["code"] = "country_ai_mode_invalid";
        return out;
    }
    ai_from(_country_ai_runtime)->set_mode(mode);
    push_country_ai_family_preferences();
    out["ok"] = true;
    out["mode"] = mode_name(mode);
    return out;
}

Dictionary DCWorldExt::set_country_ai_excluded_handles(const PackedInt64Array &handles) {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    std::vector<uint64_t> values;
    for (int64_t i = 0; i < handles.size(); ++i)
        if (handles[i] != 0) values.push_back(static_cast<uint64_t>(handles[i]));
    ai_from(_country_ai_runtime)->set_excluded_handles(std::move(values));
    push_country_ai_family_preferences();
    Dictionary out;
    out["ok"] = true;
    out["excluded"] = handles.size();
    return out;
}

Dictionary DCWorldExt::set_country_ai_topology(const PackedInt32Array &neighbors,
                                               const PackedInt32Array &cell_value_q16) {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    std::vector<int32_t> n(static_cast<size_t>(neighbors.size()));
    if (!n.empty()) std::memcpy(n.data(), neighbors.ptr(), n.size() * sizeof(int32_t));
    std::vector<int32_t> v(static_cast<size_t>(cell_value_q16.size()));
    if (!v.empty()) std::memcpy(v.data(), cell_value_q16.ptr(), v.size() * sizeof(int32_t));
    ai_from(_country_ai_runtime)->set_topology(std::move(n), std::move(v));
    Dictionary out;
    out["ok"] = true;
    out["neighbor_count"] = neighbors.size();
    return out;
}

Dictionary DCWorldExt::get_country_ai_report() const {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    const CountryAiReport r = ai_from(_country_ai_runtime)->report();
    Dictionary out;
    out["ok"] = true;
    out["configured"] = r.configured;
    out["armed"] = r.armed;
    out["mode"] = mode_name(r.mode);
    out["catalog_hash"] = static_cast<int64_t>(r.catalog_hash);
    out["country_catalog_hash"] = static_cast<int64_t>(r.country_catalog_hash);
    out["committed_day"] = r.committed_day;
    out["controlled"] = static_cast<int64_t>(r.controlled);
    out["excluded"] = static_cast<int64_t>(r.excluded);
    out["plans"] = static_cast<int64_t>(r.plans);
    out["plan_days_due"] = static_cast<int64_t>(r.plan_days_due);
    out["countries_thought"] = static_cast<int64_t>(r.countries_thought);
    out["commands_emitted"] = static_cast<int64_t>(r.commands_emitted);
    out["commands_rejected"] = static_cast<int64_t>(r.commands_rejected);
    out["retries"] = static_cast<int64_t>(r.retries);
    out["colonization_intents"] = static_cast<int64_t>(r.colonization_intents);
    out["decisions_total"] = static_cast<int64_t>(r.decisions_total);
    out["records_total"] = static_cast<int64_t>(r.records_total);
    out["records_dropped"] = static_cast<int64_t>(r.records_dropped);
    out["restores"] = static_cast<int64_t>(r.restores);
    out["restored_catalog_mismatch"] = r.restored_catalog_mismatch;
    out["plan_ms_last"] = r.plan_ms_last;
    out["plan_ms_max"] = r.plan_ms_max;
    out["plan_ms_total"] = r.plan_ms_total;
    out["state_hash"] = static_cast<int64_t>(r.state_hash);
    out["command_hash"] = static_cast<int64_t>(r.command_hash & 0x7fffffffffffffffull);
    const bool worker = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY);
    out["path"] = worker ? "native_country_worker" : "sync_country_slice";
    return out;
}

Dictionary DCWorldExt::get_country_ai_country_snapshot(int64_t handle) const {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    Dictionary out;
    for (const CountryAiMemory &m : ai_from(_country_ai_runtime)->memory()) {
        if (m.handle != static_cast<uint64_t>(handle)) continue;
        out["ok"] = true;
        out["handle"] = handle;
        out["controlled"] = m.controlled != 0;
        out["personality"] = m.personality < _country_ai_personality_ids.size()
            ? String(_country_ai_personality_ids[m.personality].c_str()) : String();
        out["agenda"] = String(country_ai_agenda_name(m.agenda));
        out["agenda_since_day"] = m.agenda_since_day;
        out["last_think_day"] = m.last_think_day;
        out["cash_delta_ema"] = m.cash_delta_ema;
        out["satisfaction_ema_q16"] = m.satisfaction_ema_q16;
        out["goal_milestone"] = m.goal_milestone;
        out["milestone_gap"] = m.milestone_gap;
        out["completed_milestones"] = m.completed_milestones;
        out["tax_pressure"] = m.tax_pressure;
        out["colonize_cooldown_until"] = m.colonize_cooldown_until;
        out["colonize_intents"] = static_cast<int64_t>(m.colonize_intents);
        out["commands_emitted"] = static_cast<int64_t>(m.commands_emitted);
        out["commands_rejected"] = static_cast<int64_t>(m.commands_rejected);
        return out;
    }
    out["ok"] = false;
    out["code"] = "country_ai_handle_unknown";
    return out;
}

Dictionary DCWorldExt::poll_country_ai_decisions(int64_t after_id, int limit) const {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    const std::vector<CountryAiDecision> decisions = ai_from(_country_ai_runtime)->decisions_after(
        static_cast<uint64_t>(std::max<int64_t>(0, after_id)),
        static_cast<size_t>(std::clamp(limit, 1, 4096)));
    Array rows;
    int64_t last = after_id;
    for (const CountryAiDecision &d : decisions) {
        rows.push_back(decision_to_dict(d));
        last = std::max<int64_t>(last, static_cast<int64_t>(d.id));
    }
    Dictionary out;
    out["ok"] = true;
    out["decisions"] = rows;
    out["last_id"] = last;
    return out;
}

Dictionary DCWorldExt::drain_country_ai_record_rows(int limit) {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    const std::vector<CountryAiRecordRow> records = ai_from(_country_ai_runtime)->drain_records(
        static_cast<size_t>(std::clamp(limit, 1, 65536)));
    Array rows;
    for (const CountryAiRecordRow &r : records) {
        Dictionary row;
        row["day"] = r.day;
        row["slot"] = r.slot;
        row["handle"] = static_cast<int64_t>(r.handle);
        row["agenda"] = String(country_ai_agenda_name(r.agenda));
        row["personality"] = r.personality < _country_ai_personality_ids.size()
            ? String(_country_ai_personality_ids[r.personality].c_str()) : String();
        row["cash"] = r.cash;
        row["cash_delta_ema"] = r.cash_delta_ema;
        row["reserve_days"] = r.reserve_days;
        row["satisfaction_q16"] = r.satisfaction_q16;
        row["essentials_q16"] = r.essentials_q16;
        row["population"] = r.population;
        row["territory"] = r.territory;
        row["frontier"] = r.frontier;
        row["completed_milestones"] = r.completed_milestones;
        row["goal_milestone"] = r.goal_milestone;
        row["milestone_gap"] = r.milestone_gap;
        row["queued_techs"] = r.queued_techs;
        row["research_budget"] = r.research_budget;
        row["tax_paid"] = r.tax_paid;
        row["household_income"] = r.household_income;
        row["carrying_k_eff"] = r.carrying_k_eff;
        row["carrying_k_geo"] = r.carrying_k_geo;
        row["carrying_load_q16"] = r.carrying_load_q16;
        row["tax_income_bp"] = r.tax_bp[0];
        row["tax_consumption_bp"] = r.tax_bp[1];
        row["tax_business_bp"] = r.tax_bp[2];
        row["expeditions"] = r.expeditions;
        row["families"] = r.families;
        row["colonize_started"] = static_cast<int64_t>(r.colonize_started);
        row["colonize_failures"] = static_cast<int64_t>(r.colonize_failures);
        row["commands_emitted"] = static_cast<int64_t>(r.commands_emitted);
        row["commands_rejected"] = static_cast<int64_t>(r.commands_rejected);
        row["hungry_share_q16"] = r.hungry_share_q16;
        row["food_subsidy_bp"] = r.food_subsidy_bp;
        rows.push_back(row);
    }
    Dictionary out;
    out["ok"] = true;
    out["rows"] = rows;
    return out;
}

PackedByteArray DCWorldExt::encode_country_ai_state() const {
    PackedByteArray bytes;
    if (_country_ai_runtime == nullptr) return bytes;
    const std::vector<uint8_t> ai = ai_from(_country_ai_runtime)->encode();
    std::vector<CountryAiColonizationIntent> intents;
    std::vector<NativeEconomyRuntime::CountryAiColonizationStat> stats;
    int64_t receipt_cursor = 0;
    if (_economy_runtime != nullptr)
        static_cast<const NativeEconomyRuntime *>(_economy_runtime)
            ->export_country_ai_pending(intents, stats, receipt_cursor);
    WrapWriter w;
    w.u32(PKAW_MAGIC);
    w.u32(PKAW_VERSION);
    w.u32(static_cast<uint32_t>(ai.size()));
    w.bytes.insert(w.bytes.end(), ai.begin(), ai.end());
    w.u32(static_cast<uint32_t>(intents.size()));
    for (const CountryAiColonizationIntent &i : intents) {
        w.u64(static_cast<uint64_t>(i.day));
        w.u64(i.country_handle);
        w.u32(static_cast<uint32_t>(i.target_cell));
        w.u32(static_cast<uint32_t>(i.population_share_bp));
        w.u64(static_cast<uint64_t>(i.min_population));
        w.u64(i.sequence);
        w.u32(static_cast<uint32_t>(i.visible_cells.size()));
        for (const int32_t cell : i.visible_cells) w.u32(static_cast<uint32_t>(cell));
    }
    w.u32(static_cast<uint32_t>(stats.size()));
    for (const auto &s : stats) {
        w.u64(s.country_handle);
        w.u32(s.failures);
        w.u32(s.started);
    }
    w.u64(static_cast<uint64_t>(receipt_cursor));
    bytes.resize(static_cast<int64_t>(w.bytes.size()));
    if (!w.bytes.empty()) std::memcpy(bytes.ptrw(), w.bytes.data(), w.bytes.size());
    return bytes;
}

Dictionary DCWorldExt::restore_country_ai_state(const PackedByteArray &bytes) {
    if (_country_ai_runtime == nullptr) return ai_unavailable();
    Dictionary out;
    WrapReader r{bytes.ptr(), static_cast<size_t>(bytes.size())};
    const auto fail = [&out](const char *code) {
        out["ok"] = false;
        out["code"] = code;
        return out;
    };
    if (r.u32() != PKAW_MAGIC) return fail("pkai_wrapper_magic_invalid");
    if (r.u32() != PKAW_VERSION) return fail("pkai_wrapper_version_unsupported");
    const uint32_t ai_size = r.u32();
    if (!r.ok || r.size - r.at < ai_size) return fail("pkai_wrapper_truncated");
    const uint8_t *ai_bytes = r.data + r.at;
    r.at += ai_size;
    std::vector<CountryAiColonizationIntent> intents(r.u32());
    if (!r.ok || intents.size() > 4096) return fail("pkai_intents_invalid");
    for (CountryAiColonizationIntent &i : intents) {
        i.day = static_cast<int64_t>(r.u64());
        i.country_handle = r.u64();
        i.target_cell = static_cast<int32_t>(r.u32());
        i.population_share_bp = static_cast<int32_t>(r.u32());
        i.min_population = static_cast<int64_t>(r.u64());
        i.sequence = r.u64();
        const uint32_t count = r.u32();
        if (!r.ok || count > 1u << 22) return fail("pkai_intents_invalid");
        i.visible_cells.resize(count);
        for (int32_t &cell : i.visible_cells) cell = static_cast<int32_t>(r.u32());
    }
    std::vector<NativeEconomyRuntime::CountryAiColonizationStat> stats(r.u32());
    if (!r.ok || stats.size() > 4096) return fail("pkai_stats_invalid");
    for (auto &s : stats) {
        s.country_handle = r.u64();
        s.failures = r.u32();
        s.started = r.u32();
    }
    const int64_t receipt_cursor = static_cast<int64_t>(r.u64());
    if (!r.ok || r.at != r.size) return fail("pkai_wrapper_truncated");
    std::string error;
    if (!ai_from(_country_ai_runtime)->restore(ai_bytes, ai_size, error))
        return fail(error.c_str());
    if (_economy_runtime != nullptr)
        static_cast<NativeEconomyRuntime *>(_economy_runtime)
            ->import_country_ai_pending(std::move(intents), std::move(stats), receipt_cursor);
    _country_ai_sync_day = -1;
    push_country_ai_family_preferences();
    const CountryAiReport report = ai_from(_country_ai_runtime)->report();
    out["ok"] = true;
    out["code"] = "ok";
    out["committed_day"] = report.committed_day;
    out["state_hash"] = static_cast<int64_t>(report.state_hash);
    out["catalog_mismatch"] = report.restored_catalog_mismatch;
    return out;
}

bool DCWorldExt::country_ai_sync_due(int64_t day) const {
    if (_country_ai_runtime == nullptr || _country_runtime == nullptr || day < 0) return false;
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY))
        return false;
    if (_country_ai_sync_day == day) return false;
    return ai_from(_country_ai_runtime)->due(day);
}

void DCWorldExt::country_ai_sync_plan(int64_t day) {
    if (!country_ai_sync_due(day)) return;
    _country_ai_sync_day = day;
    NativeCountryRuntime *country = static_cast<NativeCountryRuntime *>(_country_runtime);
    RuntimeCountryPodSnapshot snapshot;
    std::string error;
    if (!country->export_pod_snapshot(snapshot, error)) return;
    if (!_country_ai_catalog_cache || _country_ai_catalog_cache->catalog_hash != snapshot.catalog_hash) {
        auto catalog = std::make_shared<RuntimeCountryPodCatalog>();
        if (!country->export_pod_catalog(*catalog, error)) return;
        _country_ai_catalog_cache = std::move(catalog);
    }
    std::shared_ptr<const CountryAiEconomyDigest> digest;
    if (_economy_runtime != nullptr)
        digest = static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_ai_digest();
    std::vector<CountryAiCommand> commands;
    CountryAiRuntime *runtime = ai_from(_country_ai_runtime);
    if (!runtime->plan(day, snapshot, *_country_ai_catalog_cache, digest.get(), commands) ||
        commands.empty())
        return;
    Dictionary batch;
    PackedInt32Array opcodes, cells, aux, domains, positions, w0, w1, w2, w3, tax_kinds, tax_items,
        tax_rates, tax_modes;
    PackedInt64Array days, sequences, targets, values;
    PackedStringArray stable_ids, names;
    for (uint32_t i = 0; i < commands.size(); ++i) {
        const RuntimeCountryCommand c = CountryAiRuntime::to_runtime_command(commands[i], day, i);
        opcodes.push_back(c.opcode);
        days.push_back(c.effective_day);
        sequences.push_back(static_cast<int64_t>(c.sequence));
        targets.push_back(static_cast<int64_t>(c.target_handle));
        cells.push_back(c.cell);
        aux.push_back(c.aux);
        domains.push_back(c.domain);
        positions.push_back(c.position);
        w0.push_back(c.weights_bp[0]);
        w1.push_back(c.weights_bp[1]);
        w2.push_back(c.weights_bp[2]);
        w3.push_back(c.weights_bp[3]);
        values.push_back(c.value);
        tax_kinds.push_back(c.tax_kind);
        tax_items.push_back(c.tax_item);
        tax_rates.push_back(c.tax_rate_basis_points);
        tax_modes.push_back(c.tax_assessment_mode);
        stable_ids.push_back(String());
        names.push_back(String());
    }
    batch["opcodes"] = opcodes;
    batch["effective_days"] = days;
    batch["sequences"] = sequences;
    batch["target_handles"] = targets;
    batch["cell_indices"] = cells;
    batch["aux_i32"] = aux;
    batch["domain_i32"] = domains;
    batch["position_i32"] = positions;
    batch["weight0_bp"] = w0;
    batch["weight1_bp"] = w1;
    batch["weight2_bp"] = w2;
    batch["weight3_bp"] = w3;
    batch["value_i64"] = values;
    batch["tax_kinds"] = tax_kinds;
    batch["tax_item_indices"] = tax_items;
    batch["tax_rate_basis_points"] = tax_rates;
    batch["tax_assessment_modes"] = tax_modes;
    batch["stable_ids"] = stable_ids;
    batch["display_names"] = names;
    const Dictionary submitted = submit_country_ai_batch(batch);
    if (!static_cast<bool>(submitted.get("ok", false)))
        runtime->reject_staged(day, String(submitted.get("code",
            submitted.get("reason", "country_ai_sync_submit_rejected"))).utf8().get_data());
}

void DCWorldExt::country_ai_sync_finish(int64_t day, bool ok, Dictionary &out) {
    if (_country_ai_runtime == nullptr || _country_ai_sync_day != day) return;
    CountryAiRuntime *runtime = ai_from(_country_ai_runtime);
    if (!ok) {
        runtime->abort(day);
        _country_ai_sync_day = -1;
        return;
    }
    CountryAiCommitResult result = runtime->commit(day);
    if (!result.committed) return;
    out["country_ai_committed"] = true;
    if (_economy_runtime == nullptr) return;
    NativeEconomyRuntime *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    if (result.family_preferences_changed)
        economy->set_country_ai_family_preferences(std::move(result.family_preferences));
    if (!result.colonization.empty())
        economy->queue_country_ai_colonization(std::move(result.colonization));
}

bool DCWorldExt::runtime_country_ai_self_test() const {
    const auto fail = [](const char *what) {
        UtilityFunctions::printerr(String("[country ai self-test] ") + String(what));
        return false;
    };
    // Curves and utility composition.
    CountryAiCurve linear;
    linear.x0 = 0; linear.x1 = 100;
    if (country_ai_eval_curve(linear, 50) != COUNTRY_AI_Q16 / 2) return fail("linear_mid");
    if (country_ai_eval_curve(linear, -5) != 0 || country_ai_eval_curve(linear, 500) != COUNTRY_AI_Q16)
        return fail("linear_clamp");
    CountryAiCurve inverse = linear;
    inverse.y0_q16 = COUNTRY_AI_Q16; inverse.y1_q16 = 0;
    if (country_ai_eval_curve(inverse, 100) != 0) return fail("inverse");
    const int32_t ones[3] = {COUNTRY_AI_Q16, COUNTRY_AI_Q16, COUNTRY_AI_Q16};
    if (country_ai_combine_scores(ones, 3) != COUNTRY_AI_Q16) return fail("combine_one");
    const int32_t zero[2] = {COUNTRY_AI_Q16, 0};
    if (country_ai_combine_scores(zero, 2) != 0) return fail("combine_zero_veto");
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> weights{};
    if (!country_ai_normalize_weights({{1, 1, 1, 0}}, weights) ||
        weights[0] + weights[1] + weights[2] + weights[3] != 10000 || weights[3] != 0)
        return fail("weights_sum");

    // Synthetic world: 2 countries (slot 0 = player, excluded), 4 techs.
    RuntimeCountryPodCatalog pod;
    pod.catalog_hash = 77;
    pod.technology_count = 4;
    pod.technology_words = 1;
    pod.research_conditions_complete = true;
    pod.technology_costs = {10, 20, 30, 50};
    pod.technology_domains = {0, 1, 2, 0};
    pod.technology_flags = {0, 0, 0, 0};
    pod.prerequisite_offsets = {0, 0, 1, 2, 2};
    pod.prerequisites = {0, 1};
    pod.milestone_offsets = {0, 0, 0, 0, 2};
    pod.milestone_candidates = {1, 2};
    pod.milestone_required_counts = {0, 0, 0, 1};
    pod.entry_milestone_indices = {-1, -1, -1, -1};
    pod.research_condition_offsets = {0, 0, 0, 0, 0};
    RuntimeCountryPodSnapshot state;
    state.cell_count = 6;
    state.country_count = 2;
    state.technology_words = 1;
    state.technology_count = 4;
    state.catalog_hash = 77;
    state.country_active = {1, 1};
    state.country_generation = {1, 1};
    state.territory_count = {1, 2};
    state.country_cash = {1000000, 1000000};
    state.cell_country_slot = {0, 1, 1, -1, -1, -1};
    state.territory_offsets = {0, 1, 3};
    state.territory_cells = {0, 1, 2};
    state.country_technologies = {1, 1};
    state.country_discovered = {0xf, 0xf};
    state.country_pending_technologies = {0, 0};
    state.research_queues.assign(2 * 4 * 8, -1);
    state.research_queue_lengths.assign(8, 0);
    state.research_weights_bp = {2500, 2500, 2500, 2500, 2500, 2500, 2500, 2500};
    state.research_daily_budgets = {0, 0};
    state.research_auto_purchase = {0, 0};
    state.country_tax_defaults.assign(10, 0);
    state.country_tax_default_modes.assign(10, 0);
    state.country_state_version = {0, 0};
    state.research_deferred_points = {0, 0};
    state.is_water = {0, 0, 0, 0, 0, 1};
    CountryAiCatalog catalog;
    catalog.seed = 9;
    CountryAiPersonality personality;
    personality.tax_min_bp = {{0, 0, 0, 0, 0}};
    personality.tax_max_bp = {{2000, 2000, 2000, 0, 0}};
    personality.tax_initial_bp = {{500, 300, 400, 0, 0}};
    catalog.personalities.push_back(personality);
    for (CountryAiAgendaDef &agenda : catalog.agendas) agenda.consideration_count = 0;
    CountryAiEconomyDigest digest;
    CountryAiEconomyRow row;
    row.country_handle = (uint64_t{1} << 32) | 1u;
    row.population = 100;
    row.satisfaction_q16 = COUNTRY_AI_Q16 * 3 / 4;
    digest.rows.push_back(row);
    const std::vector<int32_t> neighbors = {
        1, -1, -1, -1, -1, -1,  0, 2, -1, -1, -1, -1,  1, 3, -1, -1, -1, -1,
        2, 4, -1, -1, -1, -1,  3, 5, -1, -1, -1, -1,  4, -1, -1, -1, -1, -1};
    const auto run = [&](CountryAiRuntime &runtime, std::vector<CountryAiCommand> &out_commands) {
        std::string error;
        if (!runtime.configure(catalog, error)) return false;
        runtime.set_mode(CountryAiMode::ACTIVE);
        runtime.set_excluded_handles({(uint64_t{1} << 32) | 0u});
        runtime.set_topology(neighbors, {});
        if (!runtime.plan(1, state, pod, &digest, out_commands)) return false;
        runtime.commit(1);
        return true;
    };
    {
        CountryAiRuntime unarmed;
        std::string error;
        std::vector<CountryAiCommand> none;
        unarmed.configure(catalog, error);
        unarmed.set_mode(CountryAiMode::ACTIVE);
        if (unarmed.due(1) || unarmed.plan(1, state, pod, &digest, none))
            return fail("unarmed_planned");
    }
    CountryAiRuntime a, b;
    std::vector<CountryAiCommand> ca, cb;
    if (!run(a, ca) || !run(b, cb)) return fail("plan_failed");
    if (ca.empty()) return fail("no_commands");
    bool enqueue_tech1 = false;
    for (const CountryAiCommand &c : ca) {
        if (c.target_handle != ((uint64_t{1} << 32) | 1u)) return fail("player_controlled");
        enqueue_tech1 = enqueue_tech1 || (c.opcode == 6 && c.aux == 1 && c.domain == 1);
        RuntimeCountryPodPlan plan;
        RuntimeCountryPodSnapshot scratch = state;
        std::string error;
        const RuntimeCountryCommand rc = CountryAiRuntime::to_runtime_command(c, 1, 0);
        if (!country_core_apply_command(scratch, pod, rc, plan, error))
            return fail((std::string("command_invalid:") + error).c_str());
    }
    if (!enqueue_tech1) return fail("goal_path_missing");
    if (a.report().command_hash != b.report().command_hash || a.state_hash() != b.state_hash())
        return fail("nondeterministic");
    const std::vector<uint8_t> blob = a.encode();
    CountryAiRuntime c;
    std::string error;
    c.configure(catalog, error);
    if (!c.restore(blob.data(), blob.size(), error)) return fail(error.c_str());
    if (c.state_hash() != a.state_hash()) return fail("restore_hash");
    {
        CountryAiCatalog other = catalog;
        other.seed = catalog.seed + 1;
        CountryAiRuntime mismatched;
        mismatched.configure(other, error);
        if (mismatched.restore(blob.data(), blob.size(), error) || error != "catalog_hash_mismatch")
            return fail("catalog_mismatch_accepted");
    }
    std::vector<CountryAiCommand> next_a, next_c;
    c.set_mode(CountryAiMode::ACTIVE);
    c.set_topology(neighbors, {});
    const bool planned_a = a.plan(4, state, pod, &digest, next_a);
    const bool planned_c = c.plan(4, state, pod, &digest, next_c);
    if (!planned_a || planned_a != planned_c || next_a.size() != next_c.size())
        return fail("restore_divergence");
    a.commit(4);
    c.commit(4);
    if (a.state_hash() != c.state_hash()) return fail("restore_state_divergence");

    // Food subsidy: on above the hungry threshold, only on food building
    // types, applied as ordinary overrides, and cleared once hunger recedes.
    {
        constexpr int32_t inherit = std::numeric_limits<int32_t>::min();
        RuntimeCountryPodSnapshot fed = state;
        fed.building_type_count = 3;
        fed.country_business_tax_overrides.assign(6, inherit);
        fed.country_business_tax_mode_overrides.assign(6, inherit);
        CountryAiEconomyDigest hungry = digest;
        hungry.food_building_types = {1, 0, 1};
        hungry.rows[0].hungry_share_q16 = COUNTRY_AI_Q16 / 4;
        CountryAiRuntime s;
        std::vector<CountryAiCommand> cmds;
        s.configure(catalog, error);
        s.set_mode(CountryAiMode::ACTIVE);
        s.set_excluded_handles({(uint64_t{1} << 32) | 0u});
        if (!s.plan(1, fed, pod, &hungry, cmds)) return fail("subsidy_first_plan");
        s.commit(1);
        if (!s.plan(4, fed, pod, &hungry, cmds)) return fail("subsidy_plan");
        s.commit(4);
        int32_t on = 0;
        RuntimeCountryPodPlan plan;
        for (uint32_t i = 0; i < cmds.size(); ++i) {
            if (cmds[i].opcode != 12) continue;
            if (cmds[i].tax_kind != 2 || cmds[i].tax_item == 1 ||
                cmds[i].tax_rate_bp != catalog.subsidy_food_rate_bp)
                return fail("subsidy_command_shape");
            if (!country_core_apply_command(fed, pod, CountryAiRuntime::to_runtime_command(cmds[i], 4, i),
                                            plan, error))
                return fail((std::string("subsidy_apply:") + error).c_str());
            ++on;
        }
        if (on != 2 || fed.country_business_tax_overrides[3] != catalog.subsidy_food_rate_bp ||
            fed.country_business_tax_overrides[4] != inherit)
            return fail("subsidy_not_applied");
        hungry.rows[0].hungry_share_q16 = 0;
        if (!s.plan(9, fed, pod, &hungry, cmds)) return fail("subsidy_off_plan");
        s.commit(9);
        int32_t off = 0;
        for (uint32_t i = 0; i < cmds.size(); ++i) {
            if (cmds[i].opcode != 13) continue;
            if (!country_core_apply_command(fed, pod, CountryAiRuntime::to_runtime_command(cmds[i], 9, i),
                                            plan, error))
                return fail((std::string("subsidy_clear:") + error).c_str());
            ++off;
        }
        if (off != 2 || fed.country_business_tax_overrides[3] != inherit)
            return fail("subsidy_not_cleared");
    }
    return true;
}

} // namespace pk
