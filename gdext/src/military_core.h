#pragma once

// NativeMilitaryRuntime core (v1, PKMI v1).
//
// Pure C++: no Godot types, no Variant/Dictionary/String in hot loops, no
// floating point in state that is hashed or saved. All state is SoA with
// dense ids; armies use generational handles (gen << 32 | slot).
//
// Day model: `step_day(D, digest)` reads the COMMITTED D view of Country and
// Economy (MilitaryWorldDigest) plus Military's own state, mutates ONLY
// Military state, and emits MilitaryIntent rows that the bridge submits to
// Country/Economy with effective day D+1. Receipts come back the next day.
//
// File ownership (one owner per .cpp; header changes go through the
// coordinator):
//   military_core.cpp           catalog, commands, recruitment/training,
//                               armies, morale/org, wages, step_day, hash,
//                               report                                 (A1)
//   military_core_path.cpp      terrain cost, A*, bounded Dijkstra,
//                               movement, ZOC, cell->army index        (A1)
//   military_core_save.cpp      PKMI encode/decode                     (A1)
//   military_core_logistics.cpp supply, nearest-market fields,
//                               procurement, convoys, threat/guard,
//                               interception, requisition, rations     (A2)
//   military_core_war.cpp       wars, engagements, battles, capture,
//                               war score, area control, peace terms,
//                               treaties, reparations, annex, front     (A2)
//   military_core_ai.cpp        country AI military agenda             (A3)
//   military_core_selftest.cpp  self tests + synthetic bench           (A3)

#include "military_bridge.h"

#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace pk {

constexpr uint32_t PKMI_MAGIC = 0x494d4b50u;      // "PKMI"
constexpr uint32_t PKMI_VERSION = 1u;
constexpr int32_t MILITARY_MAX_UNIT_TYPES = 64;
constexpr int32_t MILITARY_MAX_EQUIP_SLOTS = 4;
constexpr int32_t MILITARY_MAX_SUPPLY_CLASSES = 6;
constexpr int32_t MILITARY_MAX_ARMIES = 2048;
constexpr int32_t MILITARY_MAX_AREA_CELLS = 256;
constexpr int32_t MILITARY_MAX_AREA_RADIUS = 6;
constexpr int32_t MILITARY_PATH_REQUESTS_PER_COUNTRY_DAY = 32;
constexpr int32_t MILITARY_AREA_EVALS_PER_COUNTRY_DAY = 32;
constexpr int32_t MILITARY_BATTLE_LOG_CAPACITY = 64;
constexpr int32_t MILITARY_EVENT_RING_CAPACITY = 4096;
constexpr uint32_t MILITARY_PRODUCER_ID = 0x4d494c31u;   // "MIL1"

// Quality multipliers Q1..Q5 in q16: 1.00 1.20 1.45 1.75 2.10
constexpr std::array<int32_t, 5> MILITARY_QUALITY_MULT_Q16 = {
    65536, 78643, 95027, 114688, 137626};

enum MilitaryUnitClass : uint8_t {
    MILITARY_CLASS_LINE = 0,
    MILITARY_CLASS_MOBILE = 1,
    MILITARY_CLASS_ARTILLERY = 2,
};

enum MilitarySupplyClass : uint8_t {
    MILITARY_SUPPLY_RATION = 0,
    MILITARY_SUPPLY_FODDER = 1,
    MILITARY_SUPPLY_AMMUNITION = 2,
    MILITARY_SUPPLY_FUEL = 3,
    MILITARY_SUPPLY_UPKEEP = 4,
    MILITARY_SUPPLY_EQUIPMENT = 5,
};

enum MilitaryStance : uint8_t {
    MILITARY_STANCE_HOLD = 0,
    MILITARY_STANCE_ADVANCE = 1,
    MILITARY_STANCE_ASSAULT = 2,
    MILITARY_STANCE_RETREAT = 3,
    MILITARY_STANCE_EMBARKED = 4,
};

enum MilitaryMission : uint8_t {
    MILITARY_MISSION_NONE = 0,
    MILITARY_MISSION_MOVE = 1,
    MILITARY_MISSION_AREA_CONTROL = 2,
};

enum MilitaryLocationKind : uint8_t {
    MILITARY_LOT_GARRISON = 0,
    MILITARY_LOT_ARMY = 1,
};

enum MilitaryStateRole : uint8_t {
    MILITARY_STATE_BARRACKS = 0,
    MILITARY_STATE_FORTIFICATION = 1,
    MILITARY_STATE_WAR_COLLEGE = 2,
};

// Country-level military Modifier stats (country.military.*), q16, 1.0 base
// unless noted. Order is ABI for MilitaryWorldDigest.country_stat_q16.
enum MilitaryStatId : uint16_t {
    MSTAT_ATTACK = 0, MSTAT_DEFENSE, MSTAT_SPEED, MSTAT_LOGISTICS_MOVE,
    MSTAT_SUPPLY_TRANSPORT, MSTAT_SUPPLY_CONSUMPTION, MSTAT_BARRACKS_CAPACITY,
    MSTAT_LEVY_RATE /* bp base 300 */, MSTAT_WAGE /* base 1.3 */,
    MSTAT_TRAINING_TIME, MSTAT_DESERTION, MSTAT_CASUALTY, MSTAT_ATTRITION,
    MSTAT_ORG_RECOVERY, MSTAT_MORALE_ADD /* additive, base 0 */,
    MSTAT_FORTIFICATION, MSTAT_FRONTAGE, MSTAT_MILITIA,
    MSTAT_OCCUPATION_TAX /* base 0.5 */, MSTAT_NAVAL_TRANSPORT,
    MSTAT_VISION_ADD /* additive */, MSTAT_CONVOY_ESCORT,
    MSTAT_RULE_MUTUAL_SUPPORT /* rule params additive, base 0 */,
    MSTAT_RULE_LAST_STAND, MSTAT_RULE_BLITZ, MSTAT_RULE_HOLD_THE_LINE,
    MSTAT_RULE_ENCIRCLEMENT, MSTAT_RULE_HOME_GROUND,
    MSTAT_COUNT
};

// ---------------------------------------------------------------- catalog

struct MilitaryUnitType {
    std::string id;                  // stable id, catalog sorted by id
    uint8_t unit_class = MILITARY_CLASS_LINE;
    uint8_t is_default_militia = 0;
    int8_t era_index = 0;
    int32_t unlock_bit = -1;         // index into digest.country_unlock_bits, -1 = always
    int32_t attack_q16 = MILITARY_Q16;
    int32_t defense_q16 = MILITARY_Q16;
    int32_t speed_q16 = MILITARY_Q16;
    int32_t fortification_ignore_q16 = 0;
    int32_t training_days = 30;
    int32_t slot_count = 0;
    std::array<int32_t, MILITARY_MAX_EQUIP_SLOTS> slot_category{};      // equip category index
    std::array<int8_t, MILITARY_MAX_EQUIP_SLOTS> slot_min_quality{};    // 1..5
    std::array<int64_t, MILITARY_MAX_EQUIP_SLOTS> slot_qty_per_100{};   // GOODS_SCALE
    std::array<int32_t, MILITARY_MAX_EQUIP_SLOTS> slot_power_weight_q16{};
    std::array<int64_t, MILITARY_MAX_SUPPLY_CLASSES> idle_per_100_day{};   // GOODS_SCALE
    std::array<int64_t, MILITARY_MAX_SUPPLY_CLASSES> combat_per_100_day{}; // GOODS_SCALE
};

struct MilitaryEquipCategory {
    std::string id;                       // melee_arms, missile_arms, ...
    std::vector<int32_t> good_ids;        // economy dense good ids, quality asc
    std::vector<int8_t> good_quality;     // 1..5 per candidate
};

struct MilitaryStateBuilding {
    std::string id;
    int32_t economy_building_id = -1;
    uint8_t role = MILITARY_STATE_BARRACKS;
    int8_t tier = 0;
    int32_t unlock_bit = -1;
    int32_t capacity = 0;                 // barracks posts per building
    int32_t fort_bonus_q16 = 0;           // fortification
    int32_t training_speed_q16 = MILITARY_Q16; // war college local
    int64_t upkeep_per_day = 0;           // MONEY_SCALE
    int32_t build_days = 0;
    std::vector<int32_t> material_goods;
    std::vector<int64_t> material_qty;    // GOODS_SCALE
};

struct MilitaryCatalog {
    uint64_t hash = 0;
    std::vector<MilitaryUnitType> units;
    int32_t militia_unit = -1;
    std::vector<MilitaryEquipCategory> categories;
    std::vector<MilitaryStateBuilding> state_buildings;
    // Supply candidates per supply class: economy good ids + per-unit
    // conversion (q16, how much need one good unit satisfies).
    std::array<std::vector<int32_t>, MILITARY_MAX_SUPPLY_CLASSES> supply_goods;
    std::array<std::vector<int32_t>, MILITARY_MAX_SUPPLY_CLASSES> supply_yield_q16;
    // Ration need units per soldier/day (staple + protein), q16.
    int32_t ration_need_per_head_q16 = MILITARY_Q16;
    int32_t economy_good_count = 0;
    int32_t unlock_count = 0;
    // Terrain tables indexed by enum value (filled by bridge from profiles;
    // defaults per design §7.1 when empty).
    std::vector<int16_t> landform_flat, landform_rough, landform_def_q8, landform_width_q8,
        landform_supply_q8, landform_attrition_bp100;
    std::vector<uint8_t> landform_passable;
    std::vector<int16_t> vegetation_rough, vegetation_def_q8, vegetation_supply_q8,
        vegetation_attrition_bp100;
    std::vector<int16_t> cover_flat, cover_supply_q8, cover_attrition_bp100;
};

// ---------------------------------------------------------------- stores

// Soldier registration lots: (location, unit type, quality) -> heads.
struct MilitaryLotStore {
    std::vector<uint8_t> active;
    std::vector<uint8_t> location_kind;     // GARRISON / ARMY
    std::vector<int32_t> location;          // cell or army slot
    std::vector<int32_t> country_slot;
    std::vector<int16_t> unit_type;
    std::vector<int16_t> equip_quality_q8;  // average actual quality * 256
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
    int16_t quality_q8 = 256;
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

// Military-held supply inventory, per holder (army slot or garrison cell)
// and supply good. Sparse rows; holder_kind 0 = garrison cell, 1 = army.
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
    int32_t good = -1;
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
    std::vector<int32_t> config_share_bp;   // per unit type, sum <= 10000
    // Rolling digests (saved).
    int32_t pay_ratio_30_q16 = MILITARY_Q16;
    int64_t spend_payroll_30 = 0, spend_procurement_30 = 0, spend_upkeep_30 = 0;
    int64_t per_soldier_cost = 0;       // MONEY_SCALE/day
};

// Per-cell military state, sparse keyed by cell (only cells with state
// buildings, garrison or pending quotas). Dense mirror arrays are derived.
struct MilitaryCellState {
    int32_t cell = -1;
    int32_t barracks_count[8] = {};     // per tier
    int32_t fort_tier = -1;
    int32_t college_tier = -1;
    uint8_t paused = 0;
    uint8_t disrepair = 0;
    int64_t pending_enlist = 0;
    int64_t quota = 0;
    int64_t requisition_until_day = -1;
    int64_t construction_done_day[3] = {-1, -1, -1};
    int32_t construction_building[3] = {-1, -1, -1};
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
};


// One market row the army cache read (derived, not saved or hashed). Shared by
// the logistics TU (staging) and the core TU (restore replay).
struct MilitaryCacheRow {
    int32_t cell = -1;
    int32_t good = -1;
    int64_t price = 0;
    int64_t qty = 0;
};

// ---------------------------------------------------------------- runtime

struct MilitaryCommand {
    uint16_t op = 0;          // MilitaryCommandOp
    int64_t effective_day = 0;
    uint64_t sequence = 0;
    uint64_t country = 0;     // issuing country handle
    uint64_t army = 0;
    uint64_t other = 0;       // second army / target country / war id
    int32_t cell = -1;
    int32_t radius = 0;
    int32_t unit_from = -1;
    int32_t unit_to = -1;
    int64_t count = 0;
    int64_t value = 0;
    std::vector<int32_t> cells;     // area cells / ceded cells
    std::vector<int32_t> ints;      // config shares (unit, bp pairs), template rows, treaty terms
    std::vector<int64_t> longs;
};

enum MilitaryCommandOp : uint16_t {
    MCMD_NONE = 0,
    MCMD_FORCE_SET_TARGET = 1,        // count=mode, value
    MCMD_FORCE_SET_LEVY = 2,          // count=enabled
    MCMD_FORCE_SET_AUTO_DISCHARGE = 3,
    MCMD_CONFIG_SET = 4,              // ints=(unit,bp)*
    MCMD_CONFIG_SET_QUALITY_POLICY = 5,
    MCMD_CONFIG_AUTO_RETRAIN = 6,
    MCMD_BARRACKS_PAUSE = 7,          // cell, count=paused
    MCMD_TRAIN = 8,                   // cell, unit_from, unit_to, count
    MCMD_STATE_BUILD = 9,             // cell, unit_to=state building index
    MCMD_STATE_DEMOLISH = 10,
    MCMD_POLICY_SET_WAGE = 11,        // count=mode, value
    MCMD_POLICY_SET_PROCUREMENT = 12, // value=bp
    MCMD_ARMY_CREATE = 20,            // cell, ints=(unit,count)*
    MCMD_ARMY_STATION = 21,           // army, ints optional
    MCMD_ARMY_TRANSFER = 22,          // army -> other, ints
    MCMD_ARMY_MERGE = 23,             // army <- other
    MCMD_ARMY_SPLIT = 24,             // army, ints
    MCMD_ARMY_SET_TEMPLATE = 25,      // army, ints
    MCMD_ARMY_REINFORCE = 26,         // army, count=enabled
    MCMD_ARMY_MOVE = 27,              // army, cell
    MCMD_ARMY_AREA_CONTROL = 28,      // army, cells | cell+radius
    MCMD_ARMY_STOP = 29,
    MCMD_ARMY_STANCE = 30,            // army, count=stance
    MCMD_ARMY_RENAME = 31,            // army, value=name seed
    MCMD_ARMY_DISBAND = 32,
    MCMD_WAR_DECLARE = 40,            // country -> other(country handle)
    MCMD_PEACE_PROPOSE = 41,          // other(war id), ints/longs terms
    MCMD_PEACE_RESPOND = 42,          // other(war id), count=accept
};

// Peace term encoding inside MilitaryCommand.ints (kind, a, b) triples and
// longs (amount per term).
enum MilitaryPeaceTermKind : int32_t {
    MPEACE_WHITE = 0,
    MPEACE_CEDE_CELL = 1,          // a = cell
    MPEACE_ANNEX = 2,              // cede all remaining
    MPEACE_LUMP_SUM = 3,           // longs = A
    MPEACE_INSTALLMENTS = 4,       // a = n, longs = A
    MPEACE_GOODS = 5,              // a = good, longs = qty
    MPEACE_RETURN_OCCUPATION = 6,  // a = cell
};

struct MilitaryPeaceEvaluation {
    bool valid = false;
    std::string reason;
    int32_t price_q16 = 0;         // total term price in points
    int32_t willing_q16 = 0;
    int32_t gap_q16 = 0;
    uint8_t acceptance_band = 0;   // 0 low, 1 mid, 2 high
};

class MilitaryCore {
public:
    // ---- lifecycle (military_core.cpp)
    bool configure(MilitaryCatalog catalog, uint64_t world_seed, std::string &error);
    bool set_terrain(MilitaryTerrainInput terrain, std::string &error);
    void reset_state();
    bool configured() const { return _configured; }
    const MilitaryCatalog &catalog() const { return _catalog; }
    const MilitaryTerrainInput &terrain() const { return _terrain; }

    // ---- commands (military_core.cpp); validated on submit, applied at
    // the start of step_day(effective_day).
    bool submit(MilitaryCommand command, std::string &error);
    // Applies one validated command (owner: military_core.cpp).
    void apply_command(const MilitaryCommand &cmd, int64_t day);
    // Submit helper: true when command.army is owned by command.country.
    bool need_country_owns_army(bool has_country, const MilitaryCommand &command) const;
    // Centre + radius expansion for army.area_control (ascending, unique).
    std::vector<int32_t> ring_cells(int32_t center, int32_t radius) const;
    bool should_run(int64_t day) const;   // false => zero work today

    // ---- the day (military_core.cpp orchestrates; see order in .cpp)
    bool step_day(int64_t day, const MilitaryWorldDigest &digest,
                  const std::vector<MilitaryIntentReceipt> &receipts,
                  std::vector<MilitaryIntent> &intents, std::string &error);

    // ---- queries (cold)
    const MilitaryReport &report() const { return _report; }
    uint64_t state_hash() const;
    int32_t country_slot_for_handle(uint64_t handle) const;
    // Resolves (or opens) the slot that owns `handle`; -1 when the slot table
    // is full. Handles are the only country identity Military stores.
    int32_t ensure_country_slot(uint64_t handle);
    uint64_t country_handle_for_slot(int32_t slot) const;
    // True when at least one AI country's decision day has arrived.
    bool ai_decision_due(int64_t day) const;
    uint64_t army_handle(int32_t slot) const;
    bool resolve_army(uint64_t handle, int32_t &slot) const;
    int32_t controller_of(int32_t cell) const;        // -1 => owner
    const std::vector<int32_t> &cell_controller() const { return _cell_controller; }
    uint64_t control_revision() const { return _control_revision; }
    uint64_t front_revision() const { return _front_revision; }
    const std::vector<uint32_t> &front_edges() const { return _front_edges; } // key = cell*6+dir
    const MilitaryArmyStore &armies() const { return _armies; }
    const MilitaryLotStore &lots() const { return _lots; }
    const std::vector<MilitaryEngagement> &engagements() const { return _engagements; }
    const std::vector<MilitaryWar> &wars() const { return _wars; }
    const std::vector<MilitaryShipment> &shipments() const { return _shipments; }
    const std::vector<MilitaryTrainingOrder> &training() const { return _training; }
    const std::vector<MilitaryCountryPolicy> &policies() const { return _policies; }
    const std::vector<MilitaryCellState> &cell_states() const { return _cell_states; }
    const std::vector<MilitaryStockRow> &stocks() const { return _stocks; }
    const std::vector<MilitaryBattleLogRow> &battle_log() const { return _battle_log; }
    const std::vector<MilitaryReparation> &reparations() const { return _reparations; }
    const std::vector<MilitaryArea> &areas() const { return _areas; }
    std::vector<MilitaryEvent> events_after(uint64_t after_id, size_t limit) const;
    int64_t country_soldiers(int32_t slot) const;
    int32_t posts_for_cell(int32_t cell, int32_t country_slot) const;
    int64_t present_for_cell(int32_t cell) const;
    bool at_war(int32_t slot_a, int32_t slot_b) const;
    int32_t war_between(int32_t slot_a, int32_t slot_b) const;
    // Peace (military_core_war.cpp)
    MilitaryPeaceEvaluation evaluate_peace(int32_t war_id, uint64_t proposer,
                                           const std::vector<int32_t> &ints,
                                           const std::vector<int64_t> &longs) const;
    // Paths (military_core_path.cpp)
    bool preview_path(uint64_t army, int32_t target_cell, std::vector<int32_t> &out_cells,
                      int32_t &out_days) const;

    // ---- persistence (military_core_save.cpp)
    std::vector<uint8_t> encode() const;
    bool restore(const uint8_t *data, size_t size, std::string &error);

    // ---- self test / bench (military_core_selftest.cpp)
    static bool self_test(std::string &report);
    static bool bench(int32_t cells, int32_t armies, int32_t engagements, int32_t days,
                      double &avg_ms, double &p95_ms, double &max_ms, std::string &report);

    // ---------------------------------------------------------------
    // Internal stages. Public only so the split .cpp files can call each
    // other; not part of the bridge API.
    // military_core.cpp
    void apply_due_commands(int64_t day);
    void reconcile_receipts(const std::vector<MilitaryIntentReceipt> &receipts);
    void reconcile_soldier_roster(const MilitaryWorldDigest &digest);
    // ---- army personnel lane (army-personnel contract §2.1, military_core.cpp)
    // Queues one EMBARK/DISEMBARK/MERGE_LANES intent and books the heads as in
    // flight. `peer_handle` carries the absorbed formation for MERGE_LANES
    // (source lane); 0 for the single-army kinds. The bridge translates the row
    // to Economy opcode 30/31/32.
    void emit_army_lane_intent(uint16_t kind, int32_t army_slot, int32_t cell, int64_t count,
                               uint64_t peer_handle = 0);
    // In-flight heads booked for an army (0 when nothing is pending).
    int64_t army_lane_pending(int32_t army_slot) const;
    // Trims the army's lots down to `allowed` heads (proportional, then one head
    // per lot). Used by the bridge's lane reconcile: Economy owns natural deaths,
    // so Military only ever reads-and-trims, exactly like the cell roster.
    void trim_army_lots(int32_t army_slot, int64_t allowed);
    // Army deaths (battles, annihilation, terrain attrition): releases
    // `lane_count` heads of the formation's Economy lane back to `cell`
    // (opcode 31) and books `dead_count` dead there (CASUALTY), in that order,
    // into the same D+1 batch. The lane is where these people live, so a death
    // that only touched the lots would leave ghosts behind.
    void emit_army_personnel_loss(int32_t army_slot, int32_t cell, int64_t lane_count,
                                  int64_t dead_count, std::vector<MilitaryIntent> &out);
    void update_force_targets(const MilitaryWorldDigest &digest);
    void run_recruitment(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void run_training(const MilitaryWorldDigest &digest);
    void run_reinforcement(const MilitaryWorldDigest &digest);
    void update_morale_org(const MilitaryWorldDigest &digest);
    void run_wages_and_upkeep(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void refresh_army_cache(int32_t army_slot);
    // Country era index from the last committed digest (militia scaling).
    int32_t militia_era(int32_t country_slot) const;
    void push_event(const MilitaryEvent &event);
    int32_t create_army(int32_t country_slot, int32_t cell);
    void destroy_army(int32_t army_slot);
    int32_t lot_find_or_create(uint8_t kind, int32_t location, int32_t country_slot,
                               int16_t unit, int16_t quality_q8);
    int64_t lot_remove_casualties(uint8_t kind, int32_t location, int64_t count); // proportional
    MilitaryCellState *cell_state(int32_t cell, bool create);
    // Military stock custody helpers (military_core_logistics.cpp).
    int64_t stock_get(uint8_t holder_kind, int32_t holder, int32_t country_slot,
                      int32_t good) const;
    // Need units of <cls> currently held by a holder (supply_yield applied).
    int64_t stock_units(int32_t country_slot, uint8_t holder_kind, int32_t holder,
                        int32_t cls) const;
    // Returns the new quantity held.
    int64_t stock_add(uint8_t holder_kind, int32_t holder, int32_t country_slot,
                      int32_t good, int64_t delta);
    void stock_clear_holder(uint8_t holder_kind, int32_t holder);
    int64_t ledger_stock_total() const;      // sum of held stock
    int64_t ledger_transit_total() const;    // sum of in-transit shipments
    void reconcile_ledger();                 // fills report.reconcile_delta (§9.7)
    // military_core_path.cpp
    int32_t step_cost_q16(int32_t from, int32_t to, int32_t country_slot,
                          const MilitaryWorldDigest &digest) const;   // <0 impassable
    bool passable_for(int32_t cell, int32_t country_slot, const MilitaryWorldDigest &digest) const;
    bool find_path(int32_t army_slot, int32_t target, const MilitaryWorldDigest &digest,
                   std::vector<int32_t> &out);
    void bounded_dijkstra(int32_t source, int32_t country_slot, int32_t max_expansions,
                          const MilitaryWorldDigest &digest);           // fills _dij_* scratch
    void run_movement(const MilitaryWorldDigest &digest);
    void index_insert(int32_t army_slot, int32_t cell);
    void index_remove(int32_t army_slot);
    void rebuild_cell_index();
    // True when a formation at war with `country_slot` sites in a neighbour of
    // `cell` (ZOC and engagement targeting; owner: path TU).
    bool has_hostile_adjacent_army(int32_t cell, int32_t country_slot) const;
    int32_t cell_distance(int32_t a, int32_t b) const;   // wrap-aware hex distance
    // military_core_logistics.cpp
    void build_threat_fields(const MilitaryWorldDigest &digest);
    // Day holder of the per-day market CSR + per-topology rings (design 9.3):
    // `ensure()` is idempotent inside one day and the destructor drops the
    // indexes again, so a day with no demander pays nothing.
    struct MarketDayScope {
        explicit MarketDayScope(MilitaryCore &c);
        ~MarketDayScope();
        void ensure(const MilitaryWorldDigest &digest);
        void drop();
        MilitaryCore &core;
    };
    void run_procurement(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void run_convoys(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void run_consumption(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void run_requisition(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    // military_core_war.cpp
    void run_wars(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void run_engagements(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void run_area_missions(const MilitaryWorldDigest &digest);
    void update_front_cells(const std::vector<int32_t> &touched_cells);
    void mark_cell_conflict(int32_t cell);
    // O(1) control membership of the stage: ctrl list + per-(owner, controller) sums.
    void ct_set_cell(int32_t cell, int32_t owner, int32_t controller);
    void ct_erase_ctrl(int32_t cell);
    void run_reparations(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void apply_war_command(const MilitaryCommand &cmd, int64_t day);
    void open_engagement(int32_t from_cell, int32_t to_cell, int32_t attacker_slot,
                         int32_t defender_slot);
    void on_cells_ceded_or_annexed(const std::vector<int32_t> &cells, int32_t new_owner);
    // Supporting war helpers (military_core_war.cpp).
    bool truce_active(int32_t slot_a, int32_t slot_b, int64_t day) const;
    MilitaryWar *find_war(int32_t war_id);
    const MilitaryWar *find_war_const(int32_t war_id) const;
    int32_t next_war_id();
    MilitaryPeaceEvaluation evaluate_peace_terms(const MilitaryWar &war, const std::vector<int32_t> &ints,
                                                 const std::vector<int64_t> &longs) const;
    void execute_treaty(MilitaryWar &war, const std::vector<int32_t> &ints,
                        const std::vector<int64_t> &longs, int32_t proposer_slot, int64_t day,
                        std::vector<MilitaryIntent> &out);
    void close_engagement(int32_t index);
    void capture_cell(int32_t index, const MilitaryWorldDigest &digest,
                      std::vector<MilitaryIntent> &out);
    void retreat_or_annihilate(int32_t army, int32_t from_cell, int32_t victor,
                               const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out);
    void apply_casualties(int64_t losses, int32_t army_hint, int32_t fallback_cell,
                          std::vector<MilitaryIntent> &out);
    void record_battle(int64_t day, int32_t cell, int32_t war_id, int32_t winner, int32_t loser,
                       int64_t winner_losses, int64_t loser_losses, int32_t score_gain_q16);
    void with_war_score(int32_t war_id, int32_t delta_q16);
    void set_controller(int32_t cell, int32_t controller);           // bumps _control_revision
    void clear_controller(int32_t cell);                             // controller := owner
    void front_rebuild(const MilitaryWorldDigest &digest);
    void evaluate_area(MilitaryArea &area, const MilitaryWorldDigest &digest);
    void assign_path(int32_t army_slot, const std::vector<int32_t> &path);
    int32_t nearest_friendly_cell(int32_t from, int32_t owner,
                                  const MilitaryWorldDigest &digest) const;
    int64_t garrison_heads_at(int32_t cell, int32_t country_slot) const;
    void transfer_garrison_owner(int32_t cell, int32_t from, int32_t to);
    void transfer_stock(uint8_t holder_kind, int32_t from_holder, int32_t to_holder,
                        int32_t to_country);
    int64_t war_score(int32_t war_id, int32_t slot) const;
    int64_t cell_value_q16(int32_t cell) const;
    int64_t annual_revenue_q16(int32_t slot) const;
    int64_t country_power(int32_t slot) const;
    int64_t annex_price_q16(int32_t receiver, const MilitaryWar &war) const;
    void track_full_occupation(MilitaryWar &war, const MilitaryWorldDigest &digest);
    void update_war_score(MilitaryWar &war, const MilitaryWorldDigest &digest);
    // military_core_ai.cpp
    void run_country_ai(const MilitaryWorldDigest &digest);
    void set_ai_country(int32_t slot, bool ai) ;

    // ---- state (all saved unless marked derived)
    bool _configured = false;
    uint64_t _seed = 0;
    MilitaryCatalog _catalog;
    MilitaryTerrainInput _terrain;
    int64_t _last_day = -1;
    uint64_t _next_sequence = 0;
    uint64_t _next_id = 1;           // shipment / training / event ids
    std::vector<MilitaryCommand> _pending;
    MilitaryLotStore _lots;
    std::vector<MilitaryTrainingOrder> _training;
    MilitaryArmyStore _armies;
    std::vector<int32_t> _path_cells;      // arena; compacted on save
    std::vector<int32_t> _path_daily_requests;  // per country slot, reset each day (daily budget)
    // Soldier losses from harsh-environment attrition, queued by run_movement
    // and drained into the step_day intent vector by the orchestrator.
    std::vector<MilitaryIntent> _attrition_intents;
    // Army personnel lane (army-personnel contract §2.1): personnel intents
    // emitted while a command is applied (army.create/station/disband/merge)
    // are queued here and spliced into the day's batch by step_day.
    std::vector<MilitaryIntent> _lane_intents;
    // Heads already booked by Military whose Economy lane row is still in
    // flight (EMBARK/MERGE emitted, receipt not folded yet). A reconcile must
    // never trim an embarkation that the lane has not seen yet. Transient:
    // never saved, never hashed; sized on demand against the army store.
    std::vector<int64_t> _army_lane_pending;
    std::vector<int32_t> _template_rows;   // (unit, count) pairs
    std::vector<MilitaryStockRow> _stocks;
    std::vector<MilitaryShipment> _shipments;
    std::vector<MilitaryEngagement> _engagements;
    std::vector<MilitaryWar> _wars;
    std::vector<MilitaryTruce> _truces;
    std::vector<MilitaryReparation> _reparations;
    std::vector<MilitaryBattleLogRow> _battle_log;
    std::vector<MilitaryArea> _areas;
    std::vector<MilitaryCountryPolicy> _policies;   // by country slot
    std::vector<uint64_t> _policy_handle;           // handle the policy row belongs to
    std::vector<uint8_t> _ai_country;               // by slot
    std::vector<int64_t> _ai_next_decision_day;
    std::vector<MilitaryCellState> _cell_states;    // sorted by cell
    std::vector<int32_t> _cell_controller;          // dense, -1 = owner (saved sparse)
    uint64_t _control_revision = 0;
    // Ledger (goods, GOODS_SCALE): received = stock + transit + consumed + intercepted_out - intercepted_in + returned
    int64_t _ledger_received = 0, _ledger_consumed = 0, _ledger_intercepted_out = 0,
            _ledger_intercepted_in = 0, _ledger_returned = 0;
    // Derived from stock + shipments + ledger terms; equals _ledger_received
    // when the ledger is exact (report.reconcile_delta).
    int64_t _ledger_stock = 0, _ledger_transit = 0;
    std::vector<MilitaryEvent> _events;   // ring, capacity MILITARY_EVENT_RING_CAPACITY
    uint64_t _next_event_id = 1;

    // ---- derived scratch (not saved, not hashed)
    MilitaryReport _report;
    std::vector<int32_t> _cell_head;          // cell -> first army slot
    std::vector<uint8_t> _cell_engagement_mask;
    std::vector<uint32_t> _front_edges;
    std::vector<uint8_t> _front_edge_set;     // cell*6+dir membership
    uint64_t _front_revision = 0;
    std::vector<int64_t> _threat;             // by cell, current war context
    std::vector<int64_t> _guard;
    std::vector<uint32_t> _threat_stamp;
    std::vector<uint16_t> _threat_owner;      // by cell, slot+1 of strongest hostile
    std::vector<uint16_t> _guard_owners;      // by cell, slot+1 (own presence)
    uint32_t _stamp = 1;
    std::vector<int32_t> _dij_dist;
    std::vector<int32_t> _dij_parent;
    std::vector<uint32_t> _dij_stamp;
    uint32_t _dij_gen = 1;
    std::vector<int32_t> _heap;
    std::vector<uint8_t> _cell_owner_dirty;   // per cell, owner/control moved this day
    std::vector<int64_t> _country_annual_revenue;   // by slot, MONEY_SCALE (digest mirror)
    MilitaryWorldDigest _last_digest;         // last day's committed view (cold queries)
    std::vector<int32_t> _country_era;        // by slot, era index mirror (militia scaling)
    std::vector<int32_t> _cell_state_index;   // cell -> row in _cell_states, -1 none (derived)
    std::vector<MilitaryIntent> _war_intents;      // treaty batch queued by war commands
    int32_t _event_counter_control = 0;       // per-day control event budget
    // Cash the owner's command stage owes for state building materials; drained
    // into the step_day intent vector as SPEND_CASH (see MCMD_STATE_BUILD).
    std::vector<std::pair<uint64_t, int64_t>> pending_spend;

    // ---- derived performance indexes (appended by the perf pass; never
    // saved or hashed; rebuilt lazily after reset/restore). Helpers live in
    // military_core_internal.h / military_core_logistics.cpp.
    // Lot location lists, ascending lot index per (kind, location). Inactive
    // lots may linger in a list until their slot is reused; readers filter.
    std::vector<int32_t> _lot_next;
    std::vector<uint8_t> _lot_link_kind;       // 255 = not linked
    std::vector<int32_t> _lot_link_loc;
    std::vector<int32_t> _lot_army_head;       // by army slot
    std::vector<int32_t> _lot_cell_head;       // by cell
    bool _lot_index_ok = false;
    // Stock row index: open addressing over rows of _stocks keyed by
    // (holder_kind, holder, country, good); -1 = empty.
    std::vector<int32_t> _stock_rows;
    bool _stock_index_ok = false;
    // Front edge key -> position in _front_edges (-1 none); sorted on demand.
    std::vector<int32_t> _front_edge_pos;
    bool _front_unsorted = false;
    // Full canonical front recompute pending: 0 none, 1 recompute (bumps the
    // revision on change; war set changed), 2 silent rebuild after restore.
    uint8_t _front_recompute = 0;
    // Control tracker: occupied-cell list (controller >= 0) and per-country
    // owner sums, refreshed only when the committed owner map changes (or
    // every 30 days for the population term).
    std::vector<int32_t> _ct_ctrl_cells;
    std::vector<int32_t> _ct_ctrl_pos;         // cell -> index in _ct_ctrl_cells, -1
    bool _ct_ctrl_ok = false;
    std::vector<int64_t> _ct_owned_count;      // by slot
    std::vector<int64_t> _ct_value;            // by slot: sum(cell_value_q16 + population)
    std::vector<int64_t> _ct_annex_value;      // by slot: sum(max(2, cell_value_q16))
    std::vector<int64_t> _ct_owned_by_slot;    // owner sums, O(1) maintenance
    std::vector<int32_t> _ct_ctrl_by_slot;     // controlled cell counts
    std::vector<int64_t> _ct_pairs;            // owner * slot_count + controller
    int64_t _ct_sums_day = -1;
    bool _ct_sums_ok = false;
    // Procurement demand that no market within the supply radius could meet
    // (need units / goods), by country slot; refreshed every procurement day.
    std::vector<int64_t> _unmet_procure_units;
    int32_t _unmet_procure_holders = 0;
    // Normalised copy of the digest, only used when the bridge hands over a
    // digest with inconsistent array sizes.
    MilitaryWorldDigest _view_scratch;
    // Era mirror the army caches were last computed with (militia scaling).
    std::vector<int32_t> _cache_era;
    // Per-cell conflict flag recomputed when control or war membership moves
    // (design 21.5); the daily war pass uses it to skip clean days.
    std::vector<uint8_t> _ct_conflict;

    // ---- daily logistics indexes (design 9.3 / 21.4; never saved or hashed).
    // Wrap-aware rings of hex distance <= MILITARY_SUPPLY_RADIUS, built once
    // per topology change. Offsets are per cell into _ring_cells / _ring_dist;
    // _ring_dist is the row-major hex distance from the ring's centre.
    std::vector<int32_t> _ring_off;
    std::vector<uint8_t> _ring_len;
    std::vector<int32_t> _ring_cells;
    std::vector<uint8_t> _ring_dist;
    // Market rows of the current day grouped by cell (CSR over _md_row_*).
    std::vector<int32_t> _md_cell_off;      // size cells + 1
    std::vector<int32_t> _md_cell_rows;     // row ids ascending by (cell, row)
    std::vector<int32_t> _md_row_cell;      // per market row
    std::vector<int32_t> _md_row_good;      // per row: market good slot
    std::vector<int64_t> _md_row_sellable;  // per row: day quota left (GOODS_SCALE)
    std::vector<int64_t> _md_row_price;     // per row: retail price (MONEY_SCALE)
    std::vector<uint8_t> _md_cell_has_merchant;
    int64_t _md_day = -1;
    // Per live row of the current procurement day: stock still for sale to the
    // military quota, and a back-reference taken while it is consumed.
    std::vector<int64_t> _md_row_left;
    // Distinct need-unit state of a market row as observed today
    // (0 fresh, 1 sold out by procurement, 2 need met, 3 reachable but unmet).
    // Distinct need-unit state of a market row as observed today
    // (0 fresh, 1 sold out by procurement, 2 need met, 3 reachable but unmet).
    std::vector<uint8_t> _sup_row_own;

    // ---- additional derived state appended by the core perf pass (never
    // saved or hashed; rebuilt lazily or on the next day).
    bool _terrain_configured_never = true;   // no topology has been pushed yet
    // Supply connectivity: one BFS over cells the country owns AND controls
    // gives a per-cell group id and, per group, the count of cells holding a
    // stocked market of that country (design 9.3).
    bool _connected_valid = false;
    int64_t _connected_day = -1;
    int64_t _connected_revision = -1;
    std::vector<int32_t> _conn_group;        // by cell: BFS group of the country
    std::vector<int32_t> _conn_group_slot;   // group -> country slot, -1 empty
    std::vector<int32_t> _conn_mark_cells;   // group -> cells holding a market row
    std::vector<int32_t> _bfs_queue;
    // Unmet procurement demand carried into the report (need units, goods).
    bool _ut_dirty = true;
    int64_t _unmet_units_total = 0;
    int64_t _unmet_goods_total = 0;
    // Army cache version and the version each formation was computed at
    // (a full refresh after control/condition/store changes bumps the version).
    uint64_t _army_cache_gen = 1;
    std::vector<uint64_t> _army_cache_gen_at;
    // Procurements this day, in emission order; replayed after the daily
    // condition pass so a same-day purchase order reproduces byte-identically.
    bool _replay_mode = false;
    std::vector<MilitaryCacheRow> _cache_rows;
};

} // namespace pk
