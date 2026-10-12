#pragma once

// Country AI planning core. Pure, integer-only and deterministic: no Godot
// types, no floating point, no wall clock. The same inputs (committed Country
// POD state, committed Economy digest, memory rows, catalog) always produce the
// same commands on every platform, so the worker path, the synchronous path and
// a save/load round trip stay byte-identical.

#include "runtime_pod_protocol.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

constexpr uint32_t COUNTRY_AI_PRODUCER_ID = 0x41494331u; // "AIC1"
constexpr int32_t COUNTRY_AI_Q16 = 65536;
constexpr uint32_t COUNTRY_AI_SCHEMA = 1u;
constexpr uint32_t COUNTRY_AI_DOMAIN_COUNT = RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
constexpr uint32_t COUNTRY_AI_TAX_KIND_COUNT = RuntimeCountryPodSnapshot::TAX_KIND_COUNT;
constexpr uint32_t COUNTRY_AI_QUEUE_SLOTS = 8u;
constexpr uint32_t COUNTRY_AI_MAX_CONSIDERATIONS = 4u;
constexpr uint32_t COUNTRY_AI_MAX_PERSONALITIES = 16u;
constexpr uint32_t COUNTRY_AI_FAMILY_PREF_DIM = 4u;

enum class CountryAiMode : uint8_t { OFF = 0, PROBE = 1, ACTIVE = 2 };

enum CountryAiAgenda : uint8_t {
    COUNTRY_AI_AGENDA_DEVELOP = 0,
    COUNTRY_AI_AGENDA_EXPAND = 1,
    COUNTRY_AI_AGENDA_ACCUMULATE = 2,
    COUNTRY_AI_AGENDA_ERA_PUSH = 3,
    COUNTRY_AI_AGENDA_STABILIZE = 4,
    COUNTRY_AI_AGENDA_COUNT = 5,
};

// Normalised observation inputs that agenda considerations can reference.
enum CountryAiInput : uint8_t {
    COUNTRY_AI_INPUT_RESERVE_DAYS = 0,
    COUNTRY_AI_INPUT_SATISFACTION_Q16 = 1,
    COUNTRY_AI_INPUT_FRONTIER_CELLS = 2,
    COUNTRY_AI_INPUT_MILESTONE_GAP = 3,
    COUNTRY_AI_INPUT_TERRITORY_CELLS = 4,
    COUNTRY_AI_INPUT_ESSENTIALS_Q16 = 5,
    COUNTRY_AI_INPUT_EXPEDITIONS = 6,
    COUNTRY_AI_INPUT_CASH_TREND_BP = 7,
    COUNTRY_AI_INPUT_COUNT = 8,
};

enum CountryAiCurveKind : uint8_t {
    COUNTRY_AI_CURVE_LINEAR = 0,
    COUNTRY_AI_CURVE_QUADRATIC = 1,
    COUNTRY_AI_CURVE_INV_QUADRATIC = 2,
    COUNTRY_AI_CURVE_SMOOTHSTEP = 3,
    COUNTRY_AI_CURVE_STEP = 4,
    COUNTRY_AI_CURVE_COUNT = 5,
};

enum CountryAiModule : uint8_t {
    COUNTRY_AI_MODULE_STRATEGY = 0,
    COUNTRY_AI_MODULE_RESEARCH = 1,
    COUNTRY_AI_MODULE_TAX = 2,
    COUNTRY_AI_MODULE_COLONIZE = 3,
    COUNTRY_AI_MODULE_FAMILY = 4,
    COUNTRY_AI_MODULE_COUNT = 5,
};

enum CountryAiOutcome : uint8_t {
    COUNTRY_AI_OUTCOME_EMITTED = 0,
    COUNTRY_AI_OUTCOME_REJECTED = 1,
    COUNTRY_AI_OUTCOME_SKIPPED = 2,
    COUNTRY_AI_OUTCOME_PROBE = 3,
};

struct CountryAiCurve {
    uint8_t input = 0;
    uint8_t kind = COUNTRY_AI_CURVE_LINEAR;
    int64_t x0 = 0;
    int64_t x1 = 1;
    int32_t y0_q16 = 0;
    int32_t y1_q16 = COUNTRY_AI_Q16;
};

struct CountryAiAgendaDef {
    uint8_t consideration_count = 0;
    std::array<CountryAiCurve, COUNTRY_AI_MAX_CONSIDERATIONS> considerations{};
    int32_t research_share_bp = 3000;   // share of discretionary cash for research
    int32_t expansion_slots = 0;        // extra concurrent expeditions
    int32_t tax_bias_bp = 0;            // signed shift of the fiscal target
    int32_t satisfaction_floor_shift_q16 = 0;
    uint8_t era_focus = 0;              // prefer milestone candidates strongly
};

struct CountryAiPersonality {
    uint64_t id_hash = 0;
    int32_t weight = 1;
    std::array<int32_t, COUNTRY_AI_AGENDA_COUNT> agenda_bias_bp{
        {10000, 10000, 10000, 10000, 10000}};
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> domain_affinity_bp{
        {10000, 10000, 10000, 10000}};
    std::array<int32_t, COUNTRY_AI_TAX_KIND_COUNT> tax_min_bp{};
    std::array<int32_t, COUNTRY_AI_TAX_KIND_COUNT> tax_max_bp{};
    std::array<int32_t, COUNTRY_AI_TAX_KIND_COUNT> tax_initial_bp{};
    std::array<int32_t, COUNTRY_AI_FAMILY_PREF_DIM> family_pref{
        {10000, 3000, 2000, 1000}};
    int32_t risk_bp = 5000;
};

struct CountryAiCatalog {
    uint32_t schema = COUNTRY_AI_SCHEMA;
    uint64_t seed = 0;
    // Cadence (days).
    int32_t think_days = 5;
    int32_t strategy_days = 30;
    int32_t research_days = 10;
    int32_t tax_days = 30;
    int32_t colonize_days = 45;
    int32_t agenda_min_days = 90;
    int32_t agenda_inertia_bp = 1500;
    int32_t decision_noise_bp = 500;
    // Research.
    int32_t research_budget_horizon_days = 360;
    int64_t research_min_daily_budget = 0;
    int64_t research_max_daily_budget = 0;  // 0 = unbounded
    int32_t research_weight_threshold_bp = 1500;
    int32_t research_max_enqueue_per_eval = 3;
    int32_t research_budget_change_bp = 2500;
    int32_t research_frontier_visit_limit = 256;
    // Fiscal / tax.
    uint32_t tax_kind_mask = 0x7u;          // income, consumption, business
    int32_t tax_step_bp = 100;
    int32_t tax_max_step_bp = 300;
    int32_t tax_deadband_q16 = 3277;        // ~0.05
    int32_t satisfaction_floor_q16 = 32768; // 0.5
    int32_t reserve_target_days = 360;
    int64_t reserve_floor_cash = 0;
    // Colonization.
    int32_t colonize_max_in_flight = 1;
    int32_t colonize_population_share_bp = 2500;
    int64_t colonize_min_population = 3;    // COLONIZATION_KIT_MIN_OWNER_SLOTS
    int32_t colonize_vision_radius = 3;
    int32_t colonize_target_ring = 2;
    int32_t colonize_failure_cooldown_days = 120;
    int32_t colonize_min_reserve_days = 180;
    std::array<CountryAiAgendaDef, COUNTRY_AI_AGENDA_COUNT> agendas{};
    std::vector<CountryAiPersonality> personalities;
    uint64_t catalog_hash = 0;
};

// Committed Economy facts, published once per Economy commit.
struct CountryAiEconomyRow {
    uint64_t country_handle = 0;
    int64_t population = 0;
    int32_t satisfaction_q16 = 0;
    int32_t essentials_q16 = 0;
    int64_t tax_paid = 0;
    int64_t subsidy_received = 0;
    int64_t income = 0;
    int64_t expense = 0;
    int32_t family_count = 0;
    int32_t expeditions_active = 0;
    uint32_t ai_colonization_failures = 0;
    uint32_t ai_colonization_started = 0;
};

struct CountryAiEconomyDigest {
    uint64_t revision = 0;
    int64_t commit_day = -1;
    std::vector<CountryAiEconomyRow> rows; // sorted by country_handle
    const CountryAiEconomyRow *find(uint64_t handle) const;
};

// Persisted per-slot memory. Fixed-size POD so encode/hash are trivial.
struct CountryAiMemory {
    uint64_t handle = 0;
    uint8_t controlled = 0;
    uint8_t personality = 0;
    uint8_t agenda = COUNTRY_AI_AGENDA_DEVELOP;
    uint8_t initialized = 0;
    int64_t agenda_since_day = -1;
    int64_t last_think_day = -1;
    int64_t last_strategy_day = -1;
    int64_t last_research_day = -1;
    int64_t last_tax_day = -1;
    int64_t last_colonize_day = -1;
    int64_t colonize_cooldown_until = -1;
    int64_t last_cash = 0;
    int64_t last_cash_day = -1;
    int64_t cash_delta_ema = 0;        // currency per day
    int32_t satisfaction_ema_q16 = 0;
    int32_t goal_milestone = -1;
    int32_t milestone_gap = 0;
    int32_t completed_milestones = 0;
    int32_t tax_pressure = 0;          // signed integral (-8..8)
    uint32_t colonize_failures_seen = 0;
    uint32_t colonize_started_seen = 0;
    uint32_t commands_emitted = 0;
    uint32_t commands_rejected = 0;
    uint32_t colonize_intents = 0;
    uint32_t reserved = 0;
};

struct CountryAiCommand {
    uint16_t opcode = 0;
    uint8_t module = 0;
    uint8_t reserved = 0;
    int32_t slot = -1;
    uint64_t target_handle = 0;
    int32_t aux = -1;
    int32_t domain = -1;
    int32_t position = -1;
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> weights_bp{{2500, 2500, 2500, 2500}};
    int32_t tax_kind = -1;
    int32_t tax_rate_bp = 0;
    int32_t tax_mode = 0;
    int64_t value = 0;
};

struct CountryAiColonizationIntent {
    int64_t day = -1;
    uint64_t country_handle = 0;
    int32_t target_cell = -1;
    int32_t population_share_bp = 0;
    int64_t min_population = 0;
    uint64_t sequence = 0;
    std::vector<int32_t> visible_cells;
};

// Frozen per-country founding preference consumed by Economy FAMILY_COMMIT for
// AI-owned cells. Weights: realized margin, revenue, founders, hash jitter.
struct CountryAiFamilyPreferenceRow {
    uint64_t country_handle = 0;
    std::array<int32_t, COUNTRY_AI_FAMILY_PREF_DIM> weights{};
};

struct CountryAiDecision {
    uint64_t id = 0;
    int64_t day = -1;
    int32_t slot = -1;
    uint64_t handle = 0;
    uint8_t module = 0;
    uint8_t outcome = 0;
    uint8_t agenda = 0;
    uint8_t reserved = 0;
    int32_t subject = -1;
    int32_t value = 0;
    int64_t amount = 0;
    int32_t score_q16 = 0;
    std::array<int32_t, 3> alt_subject{{-1, -1, -1}};
    std::array<int32_t, 3> alt_score_q16{{0, 0, 0}};
    std::array<char, 40> reason{};
};

// One diagnostic row per controlled country per think tick.
struct CountryAiRecordRow {
    int64_t day = -1;
    int32_t slot = -1;
    uint64_t handle = 0;
    uint8_t agenda = 0;
    uint8_t personality = 0;
    int64_t cash = 0;
    int64_t cash_delta_ema = 0;
    int32_t reserve_days = 0;
    int32_t satisfaction_q16 = 0;
    int32_t essentials_q16 = 0;
    int64_t population = 0;
    int32_t territory = 0;
    int32_t frontier = 0;
    int32_t completed_milestones = 0;
    int32_t goal_milestone = -1;
    int32_t milestone_gap = 0;
    int32_t queued_techs = 0;
    int64_t research_budget = 0;
    std::array<int32_t, 3> tax_bp{{0, 0, 0}};
    int32_t expeditions = 0;
    int32_t families = 0;
    uint32_t colonize_started = 0;
    uint32_t colonize_failures = 0;
    uint32_t commands_emitted = 0;
    uint32_t commands_rejected = 0;
};

// Derived, catalog-bound technology indices. Rebuilt only when the Country
// catalog hash changes; never persisted.
struct CountryAiTechIndex {
    uint64_t catalog_hash = 0;
    uint32_t technology_count = 0;
    uint32_t words = 0;
    std::vector<int32_t> milestones;          // tech ids with milestone CSR
    std::vector<uint8_t> is_milestone;
    // Transitive prerequisite closure (including the tech itself) as bitsets.
    std::vector<uint64_t> closure;
    bool build(const RuntimeCountryPodCatalog &catalog);
};

struct CountryAiObservation {
    int32_t slot = -1;
    uint64_t handle = 0;
    int64_t cash = 0;
    int32_t territory = 0;
    int32_t frontier = 0;
    int32_t reserve_days = 0;
    int32_t cash_trend_bp = 0;
    const CountryAiEconomyRow *economy = nullptr;
    int32_t satisfaction_q16 = 0;
    int32_t essentials_q16 = 0;
    int32_t queued_techs = 0;
};

struct CountryAiPlanInput {
    int64_t day = -1;
    const RuntimeCountryPodSnapshot *state = nullptr;
    const RuntimeCountryPodCatalog *catalog = nullptr;
    const CountryAiTechIndex *tech = nullptr;
    const CountryAiEconomyDigest *economy = nullptr;
    const std::vector<int32_t> *neighbors = nullptr; // stride 6, -1 = none
    const std::vector<int32_t> *cell_value_q16 = nullptr;
};

struct CountryAiPlanOutput {
    std::vector<CountryAiCommand> commands;
    std::vector<CountryAiColonizationIntent> colonization;
    std::vector<CountryAiDecision> decisions;
    std::vector<CountryAiRecordRow> records;
    uint32_t countries_thought = 0;
};

// ---- primitives -----------------------------------------------------------
uint64_t country_ai_splitmix64(uint64_t &state);
uint64_t country_ai_mix(uint64_t seed, uint64_t a, uint64_t b, uint64_t c);
int32_t country_ai_eval_curve(const CountryAiCurve &curve, int64_t x);
int32_t country_ai_combine_scores(const int32_t *scores, uint32_t count);
bool country_ai_normalize_weights(
    const std::array<int64_t, COUNTRY_AI_DOMAIN_COUNT> &demand,
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> &out);
uint64_t country_ai_catalog_hash(const CountryAiCatalog &catalog);
bool country_ai_validate_catalog(const CountryAiCatalog &catalog, std::string &error);
uint8_t country_ai_pick_personality(const CountryAiCatalog &catalog, uint64_t seed,
                                    int32_t slot, uint64_t handle);

// Aligns memory rows with live country slots. A slot whose handle changed is
// reset; control is re-derived from the sorted excluded-handle list.
void country_ai_sync_memory(const CountryAiCatalog &catalog,
                            const RuntimeCountryPodSnapshot &state,
                            const std::vector<uint64_t> &excluded_sorted,
                            std::vector<CountryAiMemory> &memory);

// Whether any controlled slot thinks on `day`. O(slots), branch-light.
bool country_ai_due(const CountryAiCatalog &catalog,
                    const std::vector<CountryAiMemory> &memory, int64_t day);

// Plans `input.day` from state committed through `input.day - 1`. Mutates only
// the passed memory copy (the caller stages and commits it).
void country_ai_plan(const CountryAiCatalog &catalog, const CountryAiPlanInput &input,
                     std::vector<CountryAiMemory> &memory, uint64_t &decision_id,
                     CountryAiPlanOutput &out);

uint64_t country_ai_hash_memory(const std::vector<CountryAiMemory> &memory);

const char *country_ai_agenda_name(uint8_t agenda);
const char *country_ai_module_name(uint8_t module);
const char *country_ai_outcome_name(uint8_t outcome);

} // namespace pk
