#pragma once

#include "military_core_catalog.h"

namespace pk {

// ---------------------------------------------------------------- stores

// Soldier registration lots: (location, unit type, quality) -> heads.
struct MilitaryLotStore {
    std::vector<uint8_t> active;
    std::vector<uint8_t> location_kind;     // GARRISON / ARMY
    std::vector<int32_t> location;          // cell or army slot
    std::vector<int32_t> country_slot;
    std::vector<int16_t> unit_type;
    std::vector<int16_t> equip_quality_q8;  // average actual quality * 256
    std::vector<int32_t> kit_q16;           // weighted per-slot delivery factor
    std::vector<uint16_t> partial_equipment; // packed grades of incompletely equipped lots
    std::vector<int32_t> condition_q16;     // equipment condition 0.5..1.0
    std::vector<int64_t> count;
    std::vector<int32_t> free_list;
};

struct MilitaryTrainingOrder {
    uint64_t id = 0;
    int32_t country_slot = -1;
    int32_t cell = -1;
    int16_t from_unit = -1;
    int16_t to_unit = -1;
    int64_t count = 0;
    int32_t days_total = 0;
    int32_t days_done = 0;
    uint8_t equipment_ready = 0;
    uint8_t manual = 0;
    int16_t quality_q8 = 256;          // requested/policy quality (q8)
    int16_t delivered_quality_q8 = 0;  // weakest actually delivered slot (q8), 0 = none yet
    uint64_t equipped_slot_mask = 0;   // one bit per delivered equipment category
    std::array<int8_t, MILITARY_MAX_EQUIP_SLOTS> slot_delivered_quality{};
    uint16_t source_partial_equipment = 0; // same-unit re-equipment only
};

struct MilitaryArmyStore {
    std::vector<uint32_t> generation;
    std::vector<uint8_t> active;
    std::vector<int32_t> owner_slot;
    std::vector<int32_t> cell;
    std::vector<int32_t> next_cell;
    std::vector<int32_t> move_points_q16;
    std::vector<uint8_t> stance;
    std::vector<uint8_t> mission;
    std::vector<int32_t> target_cell;
    std::vector<int32_t> area_id;
    std::vector<int32_t> organization_q16;
    std::vector<int32_t> morale_q16;
    std::vector<int32_t> supply_ratio_q16;   // 3-day mean
    std::vector<int32_t> ration_ratio_q16;   // 3-day mean
    std::vector<int32_t> pay_ratio_q16;      // 30-day mean
    std::vector<int32_t> path_offset;        // into path_cells
    std::vector<int32_t> path_len;
    std::vector<int32_t> path_cursor;
    std::vector<uint8_t> reinforce_enabled;
    std::vector<int32_t> template_offset;    // into template_rows (unit,count)
    std::vector<int32_t> template_len;
    std::vector<uint64_t> commander_slot;    // v1 always 0
    std::vector<int64_t> cached_headcount;
    std::vector<int64_t> cached_attack_q16;  // sum(count*atk*factors) >> 16
    std::vector<int64_t> cached_defense_q16;
    std::vector<int32_t> cached_speed_q16;
    std::vector<int32_t> engagement;         // engagement slot or -1
    std::vector<int64_t> moved_day;          // last cell change day (render)
    std::vector<int32_t> prev_cell;          // for render interpolation
    std::vector<uint32_t> name_seed;
    std::vector<int64_t> funds;              // army personnel lane cash
    std::vector<int32_t> free_list;
    // Intrusive cell index (derived, not saved).
    std::vector<int32_t> next_in_cell;
    std::vector<int32_t> prev_in_cell;
};

// One player auto-exploration task. Rows are addressed by `row_index`; the
// derived `_exploration_by_army` index enforces one task per formation. The
// three masks are indexed by the task's selected-cell ordinal (not cell id),
// so target resolution survives a save without a 256-entry map.
struct MilitaryExplorationTask {
    bool active = false;
    int32_t row_index = -1;
    uint64_t army_handle = 0;
    int32_t owner_slot = -1;
    uint64_t owner_handle = 0;
    int32_t origin_cell = -1;
    int32_t return_cell = -1;
    int32_t anchor_cell = -1;
    int32_t radius = 0;
    int32_t selected_count = 0;
    std::array<int32_t, MILITARY_MAX_EXPLORATION_CELLS> selected_cells{};
    std::array<uint64_t, 4> seen_mask{};
    std::array<uint64_t, 4> visited_mask{};
    std::array<uint64_t, 4> blocked_mask{};
    uint8_t phase = MILITARY_EXPLORATION_ACTIVE;
    uint8_t pause_reason = MILITARY_EXPLORATION_PAUSE_NONE;
    uint8_t result = MILITARY_EXPLORATION_RESULT_NONE;
    uint8_t resume_phase = MILITARY_EXPLORATION_ACTIVE;
    int32_t focus_index = -1;
    int32_t current_observation_cell = -1;
    int32_t observer_tries = 0;
    std::array<int32_t, MILITARY_EXPLORATION_OBSERVERS> reached_observer_cells{{-1, -1, -1}};
    uint32_t tried_observer_mask = 0;
    int64_t started_day = -1;
    int64_t last_progress_day = -1;
    int64_t last_plan_day = -1;
    int64_t complete_day = -1;
    uint8_t return_fallback = 0;
};

// Military-held supply inventory, per holder (army slot or garrison cell)
// and supply good. Sparse rows; holder_kind 0 = garrison cell, 1 = army.
// One physical-maintenance object (design §2 D2/D3): a state building group
// addressed by (country, cell, catalog type) or an equipment group addressed by
// (country, holder, unit type). Rows are REBUILT every day from the committed
// economy ledger and the live lots; only the parts that must survive the rebuild
// live here (fixed-point remainder, the 5-day window, the verdict).
//
// `acc_q32` is the carry the plan requires: a demand of "0.075 goods/day" for a
// single building must not truncate to zero, and it must not be rounded up to
// one item either. `demand = acc >> 32` milli-goods, `acc &= 0xFFFFFFFF`.
struct MilitaryMaintenanceRow {
    int32_t country_slot = -1;
    int32_t cell = -1;
    uint8_t kind = 0;            // 0 state building group, 1 equipment group
    int32_t object_id = -1;      // catalog state building index / unit type index
    uint8_t holder_kind = 0;     // stock holder kind of this row's inventory
    int32_t holder = -1;
    int32_t units = 0;           // building count / soldier heads
    int64_t acc_q32[MILITARY_MAX_REPAIR_MATERIALS] = {};
    int64_t window_need = 0;     // 5-day window (buildings)
    int64_t window_met = 0;
    int32_t window_days = 0;
    int32_t ratio_bp = 10000;    // last settled satisfaction (10000 = 100%)
    uint8_t disrepair = 0;
};

struct MilitaryStockRow {
    uint8_t holder_kind = 0;
    int32_t holder = -1;
    int32_t country_slot = -1;
    int32_t good = -1;
    int64_t qty = 0;   // GOODS_SCALE
};

struct MilitaryShipment {
    uint64_t id = 0;
    int32_t country_slot = -1;
    uint8_t dest_kind = 0;      // 0 garrison cell, 1 army, 2 training order
    int32_t dest = -1;
    uint64_t dest_handle = 0;   // army handle / training order id
    int32_t origin_cell = -1;
    int32_t current_cell = -1;
    int32_t good = -1;                 // -1-category pseudo id for equipment rows
    int32_t real_good = -1;            // economy good id actually bought (equipment)
    int8_t quality = 0;                // delivered quality tier (1..5) for equipment
    int64_t qty = 0;
    int64_t value = 0;          // MONEY_SCALE paid
    int64_t departure_day = 0;
    int64_t eta_day = 0;
    int32_t route_cost_q16 = 0;
    int32_t progress_q16 = 0;
    int32_t blocked_days = 0;
};

struct MilitaryEngagement {
    int32_t cell_a = -1;          // min(cell) of edge
    int32_t cell_b = -1;          // max(cell)
    int32_t attacker_side_cell = -1;
    int32_t attacker_slot = -1;
    int32_t defender_slot = -1;
    int32_t war_id = -1;
    int32_t progress_q16 = 32768; // 0.5
    int64_t start_day = 0;
    int32_t idle_days = 0;
    int32_t days_since_battle = 0;
    int64_t casualties_attacker = 0;
    int64_t casualties_defender = 0;
    uint8_t active = 0;
};

struct MilitaryWar {
    int32_t id = -1;
    int32_t attacker_slot = -1;
    int32_t defender_slot = -1;
    uint64_t attacker_handle = 0;
    uint64_t defender_handle = 0;
    int64_t start_day = 0;
    int32_t score_battle_q16 = 0;      // attacker perspective, points*65536
    int32_t score_annihilation_q16 = 0;
    int32_t score_attrition_q16 = 0;
    int64_t attacker_losses = 0;
    int64_t defender_losses = 0;
    int64_t last_rejected_offer_day_a = -100000;
    int64_t last_rejected_offer_day_b = -100000;
    int64_t fully_occupied_since_a = -1;
    int64_t fully_occupied_since_b = -1;
    uint8_t active = 0;
};

struct MilitaryTruce {
    int32_t slot_a = -1, slot_b = -1;
    int64_t until_day = 0;
};

struct MilitaryReparation {
    uint64_t payer = 0, receiver = 0;
    int64_t installment = 0;    // MONEY_SCALE
    int32_t remaining = 0;
    int64_t next_day = 0;
    int64_t arrears = 0;
    int32_t war_id = -1;
};

struct MilitaryBattleLogRow {
    int64_t day = 0;
    int32_t cell = -1;
    int32_t war_id = -1;
    int32_t winner_slot = -1;
    int32_t loser_slot = -1;
    int64_t winner_losses = 0;
    int64_t loser_losses = 0;
    int32_t score_gain_q16 = 0;
};

struct MilitaryArea {
    int32_t id = -1;
    int32_t owner_slot = -1;
    std::vector<int32_t> cells;   // sorted
    int64_t last_eval_day = -100000;
    uint8_t active = 0;
};

// Per-country policy and force planning.
struct MilitaryCountryPolicy {
    uint8_t target_mode = 0;            // 0 headcount, 1 budget
    int64_t target_value = 0;           // heads or MONEY_SCALE/day
    int64_t effective_target = 0;       // heads
    uint8_t levy_enabled = 1;
    uint8_t auto_retrain = 1;
    uint8_t auto_discharge = 0;
    uint8_t quality_policy = 0;         // 0 BEST, 1 CHEAPEST
    uint8_t wage_mode = 0;              // 0 AUTO, 1 ABSOLUTE
    int64_t wage_absolute = 0;          // MONEY_SCALE per head/day
    int32_t procurement_share_bp = 2000;
    // ---- budget envelope (任务 6). `budget_share_bp <= 0` means "no envelope":
    // wages / upkeep / procurement settle against cash and demand exactly as
    // before. The three channel
    // shares are percentages of the envelope and must sum to <= 10000; the
    // procurement channel reuses `procurement_share_bp` above rather than
    // duplicating it, so there is one number for that channel everywhere.
    int32_t budget_share_bp = 0;
    int32_t budget_wage_bp = 6000;
    int32_t budget_upkeep_bp = 2000;
    std::vector<int32_t> config_share_bp;   // per unit type, sum <= 10000
    // ---- budget settlement outcome (任务 7 / 需求 5.2, 5.3, 7.1) ----------
    // Rewritten from scratch by every wage/upkeep settlement, so these describe
    // the LAST settled day rather than a running total.
    //
    // The three numbers per channel answer three different questions, and
    // conflating them is the easiest way to make the panel lie:
    //   - `*_demand`    what the lots / buildings asked for.
    //   - `*_overspend` how far the payment went PAST this channel's ceiling.
    //                   军饷 and 建筑维护 are high-priority (需求 7.1), so going
    //                   past the share is allowed - cash is still the hard limit -
    //                   and this is what paints the panel rust red.
    //   - `*_arrears`   what nobody could fund (需求 5.2's 缺额).
    // With no envelope all six stay 0 and the legacy path is untouched.
    int64_t wage_demand = 0;
    int64_t wage_arrears = 0;
    int64_t wage_overspend = 0;
    int64_t upkeep_demand = 0;
    int64_t upkeep_arrears = 0;
    int64_t upkeep_overspend = 0;
    // ---- procurement quota outcome (任务 8 / 需求 5.4, 6.2, 7.1) ---------
    // Same per-step, non-cumulative contract as the six numbers above: they
    // describe the LAST procurement pass. `used` is how much of the channel
    // ceiling that pass actually spent, `deferred_units` is the need units it
    // had to leave unpurchased because the quota ran out. Procurement is LOW
    // priority (需求 7.2), so it never overspends and there is deliberately no
    // overspend field to paint rust red - the panel shows 待购 instead.
    //
    // The deferred shortfall is not stored as a queue: a demander's demand is
    // `want - held`, so an unfunded gap simply reappears tomorrow and is bought
    // in the same cheapest-first order. Keeping a second copy of the queue
    // would be a second truth that can drift. With no envelope both stay 0.
    int64_t procurement_budget_used = 0;
    int64_t procurement_deferred_units = 0;
    // Rolling digests (saved).
    int32_t pay_ratio_30_q16 = MILITARY_Q16;
    int64_t spend_payroll_30 = 0, spend_procurement_30 = 0, spend_upkeep_30 = 0;
    int64_t per_soldier_cost = 0;       // MONEY_SCALE/day
    // Cash already promised to today's payroll (design S4-1: 军饷 is reserved
    // FIRST, then maintenance, then general procurement, all out of one pool).
    // Transient by construction: rewritten every step, never saved, never hashed,
    // and the channels below subtract it from the frozen treasury snapshot so no
    // two of them can promise the same money.
    int64_t wage_planned_today = 0;
    // Same idea for the maintenance channel: what the maintenance pass already
    // promised today, so general procurement cannot promise it again.
    int64_t maintenance_planned_today = 0;
};

// Per-cell military state, sparse keyed by cell (only cells with state
// buildings, garrison or pending quotas). Dense mirror arrays are derived.
struct MilitaryCellState {
    int32_t cell = -1;
    // ---- derived cache, rebuilt every day from the economy ledger
    // (requirement 6.1-6.3). The economy's kind-3 building groups are the count
    // of record; `MilitaryCore::refresh_state_building_cache` overwrites these
    // three fields from the digest's `state_*` lanes at the top of every step,
    // so nothing may increment or decrement them. They stay in the save and the
    // state hash because a restored save has to reproduce the same day-0 view,
    // and because a divergence is exactly what the repair counter reports.
    int32_t barracks_count[MILITARY_STATE_BARRACKS_TIERS] = {};     // per tier
    int32_t fort_tier = -1;
    int32_t college_tier = -1;
    uint8_t paused = 0;
    uint8_t disrepair = 0;
    int64_t pending_enlist = 0;
    int64_t quota = 0;
    int64_t requisition_until_day = -1;
    int64_t construction_done_day[MILITARY_STATE_BUILD_SLOTS] = {-1, -1, -1};
    int32_t construction_building[MILITARY_STATE_BUILD_SLOTS] = {-1, -1, -1};

    bool construction_slot_available(int32_t slot, int64_t day) const {
        return construction_building[slot] < 0 || construction_done_day[slot] <= day;
    }
};

struct MilitaryReport {
    double day_ms = 0.0;
    int64_t day = -1;
    int32_t armies_active = 0;
    int32_t armies_moving = 0;
    int32_t engagements_active = 0;
    int64_t astar_expansions = 0;
    int32_t area_evals = 0;
    int32_t threat_field_cells = 0;
    int32_t convoys_due = 0;
    int64_t convoy_hops = 0;
    int32_t front_edges_touched = 0;
    int32_t vision_patch_cells = 0;
    int32_t event_coalesced = 0;
    int64_t reconcile_delta = 0;
    int32_t intents_emitted = 0;
    int32_t wars_active = 0;
    int64_t soldiers_total = 0;
    uint8_t idle = 1;
    // War diagnostics (military_core_war.cpp).
    int32_t cells_captured = 0;
    int32_t armies_retreated = 0;
    int64_t casualties_annihilation = 0;
    int32_t battles_fought = 0;
    // Procurement demand (design 9.3): need units no market within the supply
    // radius could meet today, how many holders went unmet, and how many
    // market deliveries procurement emitted.
    int32_t unmet_procurement_holders = 0;
    int64_t unmet_procurement_units = 0;
    int32_t procure_markets_used = 0;
    // Supply connectivity: disconnection probes answered (0 = no probe).
    int32_t supply_probes = 0;
    // Actual work performed this day, never saved or hashed.
    int64_t supply_ring_requests = 0;
    int64_t supply_ring_cache_hits = 0;
    int64_t supply_ring_centers_built = 0;
    int64_t supply_ring_cells_visited = 0;
    int64_t payroll_lots_visited = 0;
    int64_t payroll_holders_visited = 0;
    int64_t war_cells_visited = 0;
    int64_t engagement_index_slots_visited = 0;
    int64_t engagement_members_cleared = 0;
    int64_t front_position_lookups = 0;
    int64_t front_position_rows = 0;
    int64_t front_removal_fallback_rows = 0;
    mutable int64_t garrison_queries = 0;
    mutable int64_t garrison_lots_visited = 0;
    mutable int64_t garrison_scan_fallbacks = 0;
    int64_t event_evictions = 0;
    int64_t event_index_rows_visited = 0;
    int64_t procurement_inflight_rows = 0;
    int64_t procurement_inflight_keys = 0;
    int64_t procurement_inflight_sort_fallbacks = 0;
    int64_t battle_plan_value_queries = 0;
    int64_t battle_plan_value_builds = 0;
    int64_t battle_plan_fort_queries = 0;
    int64_t battle_plan_fort_builds = 0;
    int64_t market_index_builds = 0;
    int64_t market_index_reuses = 0;
    int64_t market_index_cells = 0;
    int64_t procurement_garrison_links_visited = 0;
    int64_t procurement_garrison_heads_visited = 0;
    // The day's payroll as actually planned, split by holder (army-pay contract
    // §2.3). `payroll_garrison` is what the cell rows sent to the garrison
    // cohorts and `payroll_army` what the MILITARY_INTENT_ARMY_PAY rows sent to
    // the formations' lanes; together they are the day's `planned` and the
    // denominator both feeds the same pay_ratio_30 statistic. Transient (reset
    // every step, never saved or hashed) — the reporting surface a test or a
    // panel needs to tell "who got paid today" apart from the 30-day EWMA.
    int64_t payroll_garrison = 0;
    int64_t payroll_army = 0;
    // State building cache diagnostics (requirement 6.4). Transient: reset with
    // the rest of the report every step, never saved and never hashed.
    // - `state_cache_repairs`: cells whose rebuilt barracks/fort/college tuple
    //   differed from the value the previous day left behind, i.e. the cache was
    //   stale and the economy ledger corrected it.
    // - `state_ledger_unmapped`: ledger rows whose economy building type has no
    //   military catalog entry, so no posts / fort bonus / training speed could
    //   be attributed to them.
    // - `state_role_mismatch`: rows where the economy's `state_role` disagreed
    //   with the military catalog's role for the same type. The military catalog
    //   wins (it is the one that knows what a tier means), but a non-zero count
    //   means the two catalogs drifted and needs fixing at the source.
    int32_t state_cache_repairs = 0;
    int32_t state_ledger_unmapped = 0;
    int32_t state_role_mismatch = 0;
    // ---- physical maintenance (design §5, transient: reset every step) ----
    // `maintenance_spend` is SETTLED money (only real fills count), while
    // `maintenance_need_goods` / `maintenance_met_goods` are the day's recipe
    // demand and the part actually consumed out of military inventory.
    // `maintenance_backlog` is the paid-but-undelivered purchase quantity, and
    // `maintenance_rows` the live maintenance objects the pass walked (a
    // cheap way to prove the pass is sparse).
    int64_t maintenance_spend = 0;
    int64_t maintenance_need_goods = 0;
    int64_t maintenance_met_goods = 0;
    int64_t maintenance_backlog = 0;
    int32_t maintenance_rows = 0;
    int32_t maintenance_disrepair_rows = 0;
    double maintenance_ms = 0.0;
};


// One market row the army cache read (derived, not saved or hashed). Shared by
// the logistics TU (staging) and the core TU (restore replay).
struct MilitaryCacheRow {
    int32_t cell = -1;
    int32_t good = -1;
    int64_t price = 0;
    int64_t qty = 0;
};

} // namespace pk
