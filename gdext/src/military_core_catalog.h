#pragma once

// Military constants, command limits and catalog data.

#include "military_bridge.h"

#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace pk {

struct MilitaryMarketDayReuse;

constexpr uint32_t PKMI_MAGIC = 0x494d4b50u;      // "PKMI"
// v2: state buildings are counted through the economy ledger (kind-3 rows)
// instead of a cumulative barracks/fort/college cache. v1 streams still load
// (backward-compatible) and fold their cache into the ledger on restore.
// v3: a training order no longer relabels its garrison lot on submission, and
// carries the *actually delivered* equipment quality / per-slot coverage. Old
// streams are rejected: their in-flight lots already have the target unit type
// and their orders carry only the policy-requested quality.
// v6: physical maintenance procurement. Adds the paid-but-unsettled purchase
// order table (section 24) with its monotonic request identity. Old streams are
// rejected: a v5 save can be in the middle of a purchase whose row does not
// exist, so interpreting it as settled would hand goods to nobody (or pay
// twice), and the old cash `SPEND_CASH` upkeep must never be replayed as a
// physical purchase.
constexpr uint32_t PKMI_VERSION = 7u;
constexpr int32_t MILITARY_MAX_UNIT_TYPES = 64;
constexpr int32_t MILITARY_MAX_EQUIP_SLOTS = 4;
constexpr int32_t MILITARY_MAX_SUPPLY_CLASSES = 6;
constexpr int32_t MILITARY_MAX_ARMIES = 2048;
constexpr int32_t MILITARY_MAX_AREA_CELLS = 256;
constexpr int32_t MILITARY_MAX_AREA_RADIUS = 6;
// Physical maintenance (design §2 D3). A recipe has at most 4 components, the
// building inventory holder encodes (cell, catalog type) in one int32, and the
// stock policy is "top up to 10 days once the cover drops below 5".
constexpr int32_t MILITARY_MAX_REPAIR_MATERIALS = 4;
constexpr int32_t MILITARY_MAINT_HOLDER_STRIDE = 64;
constexpr int32_t MILITARY_MAINT_TARGET_DAYS = 10;
constexpr int32_t MILITARY_MAINT_REORDER_DAYS = 5;
constexpr int32_t MILITARY_MAX_EXPLORATION_TASKS = 256;
constexpr int32_t MILITARY_MAX_EXPLORATION_CELLS = 256;
constexpr int32_t MILITARY_EXPLORATION_PLANS_PER_DAY = 8;
constexpr int32_t MILITARY_EXPLORATION_PATH_REQUESTS_PER_COUNTRY_DAY = 16;
constexpr int32_t MILITARY_EXPLORATION_OBSERVERS = 3;
constexpr int32_t MILITARY_EXPLORATION_OBSERVER_RADIUS = 2;
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
    MILITARY_MISSION_EXPLORE = 3,
};

enum MilitaryExplorationPhase : uint8_t {
    MILITARY_EXPLORATION_ACTIVE = 0,
    MILITARY_EXPLORATION_RETURNING = 1,
    MILITARY_EXPLORATION_PAUSED_BATTLE = 2,
    MILITARY_EXPLORATION_COMPLETE = 3,
    MILITARY_EXPLORATION_FAILED_NO_RETURN = 4,
};

enum MilitaryExplorationResult : uint8_t {
    MILITARY_EXPLORATION_RESULT_NONE = 0,
    MILITARY_EXPLORATION_RESULT_ALL_SEEN = 1,
    MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE = 2,
    MILITARY_EXPLORATION_RESULT_FAILED_NO_RETURN = 3,
    MILITARY_EXPLORATION_RESULT_CANCELLED = 4,
};

enum MilitaryExplorationPauseReason : uint8_t {
    MILITARY_EXPLORATION_PAUSE_NONE = 0,
    MILITARY_EXPLORATION_PAUSE_ENGAGEMENT = 1,
};

enum MilitaryExplorationPathResult : uint8_t {
    MILITARY_EXPLORATION_PATH_OK = 0,
    MILITARY_EXPLORATION_PATH_UNREACHABLE = 1,
    MILITARY_EXPLORATION_PATH_DAILY_BUDGET_EXHAUSTED = 2,
    MILITARY_EXPLORATION_PATH_INVALID = 3,
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

// Sizes of MilitaryCellState's per-cell arrays. They are part of the cell
// snapshot ABI (`barracks_tiers` / `construction_*`), so the bridge and the
// dossier read the same numbers the core writes.
constexpr int32_t MILITARY_STATE_BARRACKS_TIERS = 8;
constexpr int32_t MILITARY_STATE_BUILD_SLOTS = 3;

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

struct MilitaryRepairMaterial { int32_t good = -1; int64_t rate_q32 = 0; };

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
    std::array<uint8_t, MILITARY_MAX_EQUIP_SLOTS> slot_core{};          // hard quality gate
    std::array<int8_t, MILITARY_MAX_EQUIP_SLOTS> slot_min_quality{};    // 1..5
    std::array<int64_t, MILITARY_MAX_EQUIP_SLOTS> slot_qty_per_100{};   // GOODS_SCALE
    std::array<int32_t, MILITARY_MAX_EQUIP_SLOTS> slot_power_weight_q16{};
    std::vector<MilitaryRepairMaterial> repair_materials;
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
    std::vector<MilitaryRepairMaterial> repair_materials;
    int64_t upkeep_per_day = 0;           // MONEY_SCALE
    int32_t build_days = 0;
    std::vector<int32_t> material_goods;
    std::vector<int64_t> material_qty;    // GOODS_SCALE
};

// One paid purchase that the treasury has NOT settled yet (physical maintenance
// design §3 / D6). Nothing is in military custody while this row exists: the
// goods still belong to the market, the cash still belongs to the country. Only
// the real fill receipt (`settle_purchase`) turns a row into stock or a convoy.
//
// `intent.source_id` is the STABLE request identity (monotonic, persists across
// retries and saves) that Economy dedupes on and the receipt echoes back.
struct MilitaryPurchaseOrder {
    MilitaryIntent intent;           // requested good / quantity / ceiling price
    uint8_t channel = 0;             // 0 general supply quota, 1 maintenance quota
    int32_t destination_cell = -1;   // where the goods must land
    uint8_t dest_kind = 0;           // MILITARY_LOT_* holder kind
    int32_t dest = -1;
    uint64_t dest_handle = 0;        // army handle / training order id
    int32_t stock_good = -1;         // identity in _stocks (pseudo id for equipment)
    int32_t real_good = -1;          // economy good actually bought (equipment)
    int32_t category = -1;           // equipment category, -1 for supply classes
    int8_t quality = 0;              // delivered equipment tier (0 = not equipment)
    int32_t route_cost_q16 = 0;      // convoy route fixed when the order was made
    int32_t days = 0;                // convoy travel days at order time
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
    // Water-crossing gates (army-personnel contract 2 §2.2, design §7.4):
    // one bit per water tier, resolved by MilitaryCatalogCompiler from the four
    // navigation technologies. A formation may enter a water cell whose tier is
    // at or below the best unlocked tier; -1 (or any unconfigured catalog) means
    // "never granted", so that tier stays impassable.
    int32_t water_lake_bit = -1;      // tech.river_transport
    int32_t water_shallow_bit = -1;   // tech.military.coastal_transport
    int32_t water_far_bit = -1;       // tech.celestial_navigation
    int32_t water_deep_bit = -1;      // tech.oceanic_ship_design
};

} // namespace pk
