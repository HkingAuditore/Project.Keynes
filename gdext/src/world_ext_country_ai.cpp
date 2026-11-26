#include "world_ext.h"
#include "country_ai_runtime.h"
#include "country_core_apply.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"
#include "runtime_checkpoint_wire.h"

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
constexpr uint32_t COUNTRY_AI_ECONOMY_DIGEST = 0x31444143u; // CAD1

template<class IO, class Row>
bool country_ai_economy_fields(IO &io, Row &row) {
    return io.field(row.country_handle) && io.field(row.population) &&
        io.field(row.satisfaction_q16) && io.field(row.essentials_q16) &&
        io.field(row.tax_paid) && io.field(row.subsidy_received) &&
        io.field(row.income) && io.field(row.expense) &&
        io.field(row.family_count) && io.field(row.expeditions_active) &&
        io.field(row.ai_colonization_failures) && io.field(row.ai_colonization_started) &&
        io.field(row.carrying_k_eff) && io.field(row.carrying_k_geo) &&
        io.field(row.carrying_load_q16) && io.field(row.hungry_share_q16);
}

template<class IO, class Digest>
bool country_ai_economy_digest_fields(IO &io, Digest &digest) {
    return io.field(digest.revision) && io.field(digest.commit_day) &&
        io.rows(digest.rows, [](auto &codec, auto &row) {
            return country_ai_economy_fields(codec, row);
        }) && io.rows(digest.food_building_types, checkpoint_scalar) &&
        io.rows(digest.cell_population, checkpoint_scalar);
}

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
    c.research_min_share_bp = dict_i32(d, "research_min_share_bp", c.research_min_share_bp);
    c.research_max_share_bp = dict_i32(d, "research_max_share_bp", c.research_max_share_bp);
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
    CountryAiRuntime *runtime = ai_from(_country_ai_runtime);
    economy->set_country_ai_family_preferences(runtime->family_preferences());
    // Procurement policies are transient Economy state: restore and mode
    // switches re-send the AI's current research shares.
    for (const auto &policy : runtime->procurement_policies(0))
        economy->queue_research_procurement_policy(policy.country_handle,
            policy.research_share_bp, policy.day, static_cast<int64_t>(policy.sequence));
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
        row["research_share_bp"] = r.research_share_bp;
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
    if (_economy_runtime != nullptr) {
        const auto &economy = *static_cast<const NativeEconomyRuntime *>(_economy_runtime);
        if (const auto digest = economy.country_ai_digest()) {
            // Country runs before Economy. Keep the sample it would read
            // on the first resumed day, including the previous cycle's rates.
            CheckpointWriter snapshot;
            snapshot.field(COUNTRY_AI_ECONOMY_DIGEST);
            country_ai_economy_digest_fields(snapshot, *digest);
            w.bytes.insert(w.bytes.end(), snapshot.bytes.begin(), snapshot.bytes.end());
        }
    }
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
    if (!r.ok) return fail("pkai_wrapper_truncated");
    std::shared_ptr<CountryAiEconomyDigest> digest;
    if (r.at < r.size) {
        CheckpointReader snapshot{r.data + r.at, r.size - r.at};
        uint32_t marker = 0;
        if (snapshot.field(marker) && marker == COUNTRY_AI_ECONOMY_DIGEST) {
            auto saved = std::make_shared<CountryAiEconomyDigest>();
            if (country_ai_economy_digest_fields(snapshot, *saved) &&
                snapshot.cursor == snapshot.size) digest = std::move(saved);
        }
    }
    std::string error;
    if (!ai_from(_country_ai_runtime)->restore(ai_bytes, ai_size, error))
        return fail(error.c_str());
    if (_economy_runtime != nullptr) {
        auto &economy = *static_cast<NativeEconomyRuntime *>(_economy_runtime);
        economy.import_country_ai_pending(std::move(intents), std::move(stats), receipt_cursor);
        economy.restore_country_ai_digest(std::move(digest));
    }
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
    for (const auto &policy : result.procurement)
        economy->queue_research_procurement_policy(policy.country_handle,
            policy.research_share_bp, policy.day, static_cast<int64_t>(policy.sequence));
}


} // namespace pk
