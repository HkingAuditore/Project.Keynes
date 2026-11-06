// MilitaryCore main TU: catalog, lifecycle, commands, recruitment/training,
// armies, morale/organisation, wages/upkeep, day orchestration, hash, report.
//
// ---------------------------------------------------------------------------
// PERSONNEL MODEL (v1, deliberate simplification - documented, not a TODO)
// ---------------------------------------------------------------------------
// Soldiers stay Economy-owned `(cell, soldier|*)` cohorts at their HOME cell
// for their whole service: Economy keeps consuming the soldier household
// there, and Military only books MILITARY_INTENT_ENLIST / LEVY / DISCHARGE /
// CASUALTY / PAY_WAGES against that cell. A Military lot living in an army is
// the ACCOUNTING view of those people (who is trained, with what equipment,
// where the formation stands); marching an army moves lots and never moves the
// Economy cohort. Accepted consequences:
//   * soldiers of an army still count as `present` at their home garrison, so
//     that barracks keeps its quota suppressed while the field army is away;
//   * wages/consumption settle at the home cell, so a field army has no
//     per-army guest consumption of its own;
//   * casualties are reported to the home cell (one CASUALTY intent per
//     origin cell) instead of an ArmyPersonnelStore lane.
// Other systems book Military lots for armies because they are the same heads;
// v1 never emits an Economy command that moves a soldier cohort between cells.
//
// Stage commands have no bridge opcode in the contract (military_core.h has no
// ARMY_EMBARK / ARMY_DISEMBARK), so army.create/station are pure lot transfers
// here and the bridge needs no cohort command for them.
// ---------------------------------------------------------------------------

#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>

namespace pk {

namespace {

using namespace mil;

constexpr int64_t kRecruitCheckPeriod = 5;    // quota re-freeze cadence ("sample day")
constexpr int64_t kUpkeepPeriod = 5;          // state-building upkeep/disrepair cadence
constexpr int32_t kMinCellPopulationAfterLevy = 5;
constexpr int64_t kPayRatioDesertThreshold = 32768;   // 50% in q16
constexpr int32_t kMaxOrdersPerCellPerDay = 4;

template <typename T>
void grow_zero(T &v, size_t n) {
    if (v.size() < n) v.resize(n, 0);
}

uint64_t mix_bytes(uint64_t h, const void *data, size_t size) {
    const unsigned char *p = static_cast<const unsigned char *>(data);
    for (size_t i = 0; i < size; ++i) {
        h ^= (uint64_t)p[i];
        h *= 0x100000001b3ull;
        h ^= h >> 29;
    }
    return h;
}

template <typename T>
uint64_t mix_scalar(uint64_t h, T value) {
    return mix_bytes(h, &value, sizeof(T));
}

uint64_t mix_string(uint64_t h, const std::string &s) {
    h = mix_scalar<uint64_t>(h, (uint64_t)s.size());
    return mix_bytes(h, s.data(), s.size());
}

// -------------------------------------------------------------- army cache
// Recomputes every active formation's cached headcount / attack / defence /
// speed. The cache reads only lot state and the era mirror, never the digest,
// so a full pass at a fixed point in the day is cheap (O(lots)) and makes the
// cached values independent of the order in which field armies fought.
void military_refresh_army_caches(MilitaryCore &core) {
    for (int32_t a = 0; a < (int32_t)core._armies.active.size(); ++a) {
        if (!core._armies.active[(size_t)a]) continue;
        core.refresh_army_cache(a);
    }
}

// Replays the purchase-order (cell, good, price) stream the army cache saw, so
// a restored army rebuilds the identical cache even though the purchase-order
// table is derived and never saved.
void military_cache_replay(const MilitaryCore &src, MilitaryCore &dst) {
    dst._md_row_cell.clear();
    dst._md_row_good.clear();
    dst._md_row_price.clear();
    dst._md_row_sellable.clear();
    dst._md_cell_has_merchant.assign((size_t)std::max(0, dst._terrain.cell_count), 1);
    dst._md_cell_off.clear();
    dst._md_cell_rows.clear();
    for (const MilitaryCacheRow &row : src._cache_rows) {
        dst._md_row_cell.push_back(row.cell);
        dst._md_row_good.push_back(row.good);
        dst._md_row_price.push_back(row.price);
        dst._md_row_sellable.push_back(row.qty);
    }
    dst._md_day = src._md_day;
    military_refresh_army_caches(dst);
    dst._md_row_cell.clear();
    dst._md_row_good.clear();
    dst._md_row_price.clear();
    dst._md_row_sellable.clear();
    dst._md_cell_off.clear();
    dst._md_cell_rows.clear();
    dst._md_cell_has_merchant.clear();
    dst._md_day = -1;
}

// -------------------------------------------------------------- catalog prep

void military_fill_terrain_defaults(MilitaryCatalog &c, size_t lf_n, size_t veg_n, size_t cv_n) {
    struct LFDef {
        int16_t flat, rough, def_q8, width_q8, supply_q8, attrition_bp100;
        uint8_t passable;
    };
    // id order = LandformType.LF (scripts/geography/landform_type.gd).
    // def/width/supply are q8 (256 == 1.0); attrition is bp100 (100 == 0.01%).
    static const LFDef kLand[16] = {
        /*0 DEEP_OCEAN */ {0, 0, 256, 256, 256, 0, 0},
        /*1 OCEAN      */ {0, 0, 256, 256, 256, 0, 0},
        /*2 COAST      */ {0, 0, 256, 256, 256, 0, 0},
        /*3 LAKE       */ {0, 0, 256, 256, 256, 0, 0},
        /*4 PLAIN      */ {1, 0, 256, 256, 256, 0, 1},
        /*5 LOWLAND    */ {1, 0, 256, 256, 256, 0, 1},
        /*6 HILL       */ {1, 1, 333, 230, 281, 0, 1},
        /*7 MOUNTAIN   */ {2, 2, 461, 154, 358, 5, 1},
        /*8 PEAK       */ {0, 0, 256, 256, 256, 0, 0},
        /*9 DELTA      */ {1, 1, 282, 205, 281, 0, 1},
        /*10 BADLANDS  */ {2, 1, 333, 205, 333, 5, 1},
        /*11 SALT_FLAT */ {2, 0, 230, 256, 333, 5, 1},
        /*12 VOLCANO   */ {0, 0, 256, 256, 256, 0, 0},
        /*13 PLATEAU   */ {2, 0, 307, 256, 307, 0, 1},
        /*14 RIFT      */ {1, 1, 307, 179, 281, 0, 1},
        /*15 CANYON    */ {2, 1, 410, 128, 307, 0, 1},
    };
    if (c.landform_flat.empty()) {
        c.landform_flat.assign(lf_n, 0);
        c.landform_rough.assign(lf_n, 0);
        c.landform_def_q8.assign(lf_n, 256);
        c.landform_width_q8.assign(lf_n, 256);
        c.landform_supply_q8.assign(lf_n, 256);
        c.landform_attrition_bp100.assign(lf_n, 0);
        c.landform_passable.assign(lf_n, 0);
        for (size_t i = 0; i < lf_n; ++i) {
            const LFDef &d = kLand[i < 16 ? i : 0];
            c.landform_flat[i] = d.flat;
            c.landform_rough[i] = d.rough;
            c.landform_def_q8[i] = d.def_q8;
            c.landform_width_q8[i] = d.width_q8;
            c.landform_supply_q8[i] = d.supply_q8;
            c.landform_attrition_bp100[i] = d.attrition_bp100;
            c.landform_passable[i] = d.passable;
        }
    } else {
        const size_t n = c.landform_flat.size();
        if (c.landform_rough.size() < n) c.landform_rough.resize(n, 0);
        if (c.landform_def_q8.size() < n) c.landform_def_q8.resize(n, 256);
        if (c.landform_width_q8.size() < n) c.landform_width_q8.resize(n, 256);
        if (c.landform_supply_q8.size() < n) c.landform_supply_q8.resize(n, 256);
        if (c.landform_attrition_bp100.size() < n) c.landform_attrition_bp100.resize(n, 0);
        if (c.landform_passable.size() < n) c.landform_passable.resize(n, 1);
    }

    // VegetationType.VEG ids (scripts/geography/vegetation_type.gd).
    if (c.vegetation_rough.empty()) {
        c.vegetation_rough.assign(veg_n, 0);
        c.vegetation_def_q8.assign(veg_n, 256);
        c.vegetation_supply_q8.assign(veg_n, 256);
        c.vegetation_attrition_bp100.assign(veg_n, 0);
        for (size_t i = 0; i < veg_n; ++i) {
            int16_t rough = 0, def = 256, supply = 256, attr = 0;
            switch (i) {
                case 5: case 7: case 8: case 12: case 15: case 24: case 25:
                    rough = 1; def = 307; break;                    // forests
                case 14: case 19: case 20: case 21: case 27:
                    rough = 2; def = 307; supply = 282; break;      // rainforest / wetlands
                case 1: case 17:
                    supply = 358; attr = 10; break;                 // polar / xeric desert
                default: break;                                     // grass / shrub / tundra stack +0
            }
            c.vegetation_rough[i] = rough;
            c.vegetation_def_q8[i] = def;
            c.vegetation_supply_q8[i] = supply;
            c.vegetation_attrition_bp100[i] = attr;
        }
    } else {
        const size_t n = c.vegetation_rough.size();
        if (c.vegetation_def_q8.size() < n) c.vegetation_def_q8.resize(n, 256);
        if (c.vegetation_supply_q8.size() < n) c.vegetation_supply_q8.resize(n, 256);
        if (c.vegetation_attrition_bp100.size() < n) c.vegetation_attrition_bp100.resize(n, 0);
    }

    // CoverType.CV ids (scripts/geography/cover_type.gd).
    if (c.cover_flat.empty()) {
        c.cover_flat.assign(cv_n, 0);
        c.cover_supply_q8.assign(cv_n, 256);
        c.cover_attrition_bp100.assign(cv_n, 0);
        for (size_t i = 0; i < cv_n; ++i) {
            int16_t flat = 0, supply = 256, attr = 0;
            switch (i) {
                case 1: flat = 1; supply = 333; attr = 10; break;   // SNOW
                case 2: flat = 3; supply = 410; attr = 30; break;   // GLACIER
                case 5: flat = 2; supply = 282; break;              // FLOODING
                default: break;                                     // SEA_ICE / PERMAFROST / BLOOM
            }
            c.cover_flat[i] = flat;
            c.cover_supply_q8[i] = supply;
            c.cover_attrition_bp100[i] = attr;
        }
    } else {
        const size_t n = c.cover_flat.size();
        if (c.cover_supply_q8.size() < n) c.cover_supply_q8.resize(n, 256);
        if (c.cover_attrition_bp100.size() < n) c.cover_attrition_bp100.resize(n, 0);
    }
}

void normalize_unit(MilitaryUnitType &u) {
    if (u.slot_count < 0) u.slot_count = 0;
    if (u.slot_count > MILITARY_MAX_EQUIP_SLOTS) u.slot_count = MILITARY_MAX_EQUIP_SLOTS;
    for (int32_t s = u.slot_count; s < MILITARY_MAX_EQUIP_SLOTS; ++s) {
        u.slot_category[(size_t)s] = -1;
        u.slot_min_quality[(size_t)s] = 1;
        u.slot_qty_per_100[(size_t)s] = 0;
        u.slot_power_weight_q16[(size_t)s] = 0;
    }
    for (int32_t s = 0; s < u.slot_count; ++s) {
        if (u.slot_min_quality[(size_t)s] < 1) u.slot_min_quality[(size_t)s] = 1;
        if (u.slot_min_quality[(size_t)s] > 5) u.slot_min_quality[(size_t)s] = 5;
        if (u.slot_power_weight_q16[(size_t)s] <= 0) u.slot_power_weight_q16[(size_t)s] = MILITARY_Q16;
        if (u.slot_qty_per_100[(size_t)s] < 0) u.slot_qty_per_100[(size_t)s] = 0;
    }
    if (u.training_days < 1) u.training_days = 1;
    if (u.attack_q16 < 0) u.attack_q16 = 0;
    if (u.defense_q16 < 0) u.defense_q16 = 0;
    if (u.speed_q16 <= 0) u.speed_q16 = MILITARY_Q16;
    for (size_t k = 0; k < MILITARY_MAX_SUPPLY_CLASSES; ++k) {
        if (u.idle_per_100_day[k] < 0) u.idle_per_100_day[k] = 0;
        if (u.combat_per_100_day[k] < 0) u.combat_per_100_day[k] = 0;
    }
}

uint64_t catalog_hash(const MilitaryCatalog &c) {
    uint64_t h = 0xcbf29ce484222325ull;
    h = mix_scalar<uint64_t>(h, (uint64_t)c.units.size());
    for (const MilitaryUnitType &u : c.units) {
        h = mix_string(h, u.id);
        h = mix_scalar<uint8_t>(h, u.unit_class);
        h = mix_scalar<uint8_t>(h, u.is_default_militia);
        h = mix_scalar<int8_t>(h, u.era_index);
        h = mix_scalar<int32_t>(h, u.unlock_bit);
        h = mix_scalar<int32_t>(h, u.attack_q16);
        h = mix_scalar<int32_t>(h, u.defense_q16);
        h = mix_scalar<int32_t>(h, u.speed_q16);
        h = mix_scalar<int32_t>(h, u.fortification_ignore_q16);
        h = mix_scalar<int32_t>(h, u.training_days);
        h = mix_scalar<int32_t>(h, u.slot_count);
        for (int32_t s = 0; s < MILITARY_MAX_EQUIP_SLOTS; ++s) {
            h = mix_scalar<int32_t>(h, u.slot_category[(size_t)s]);
            h = mix_scalar<int8_t>(h, u.slot_min_quality[(size_t)s]);
            h = mix_scalar<int64_t>(h, u.slot_qty_per_100[(size_t)s]);
            h = mix_scalar<int32_t>(h, u.slot_power_weight_q16[(size_t)s]);
        }
        for (size_t k = 0; k < MILITARY_MAX_SUPPLY_CLASSES; ++k) {
            h = mix_scalar<int64_t>(h, u.idle_per_100_day[k]);
            h = mix_scalar<int64_t>(h, u.combat_per_100_day[k]);
        }
    }
    // Naval transport gates participate in the catalog identity: a catalog that`r`n    // grants (or stops granting) sea passage is a different catalog.`r`n    h = mix_scalar<int32_t>(h, c.coastal_transport_bit);`r`n    h = mix_scalar<int32_t>(h, c.ocean_transport_bit);`r`n    h = mix_scalar<uint64_t>(h, (uint64_t)c.categories.size());
    for (const MilitaryEquipCategory &cat : c.categories) {
        h = mix_string(h, cat.id);
        h = mix_scalar<uint64_t>(h, (uint64_t)cat.good_ids.size());
        for (int32_t g : cat.good_ids) h = mix_scalar<int32_t>(h, g);
        for (int8_t q : cat.good_quality) h = mix_scalar<int8_t>(h, q);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)c.state_buildings.size());
    for (const MilitaryStateBuilding &b : c.state_buildings) {
        h = mix_string(h, b.id);
        h = mix_scalar<int32_t>(h, b.economy_building_id);
        h = mix_scalar<uint8_t>(h, b.role);
        h = mix_scalar<int8_t>(h, b.tier);
        h = mix_scalar<int32_t>(h, b.unlock_bit);
        h = mix_scalar<int32_t>(h, b.capacity);
        h = mix_scalar<int32_t>(h, b.fort_bonus_q16);
        h = mix_scalar<int32_t>(h, b.training_speed_q16);
        h = mix_scalar<int64_t>(h, b.upkeep_per_day);
        h = mix_scalar<int32_t>(h, b.build_days);
        h = mix_scalar<uint64_t>(h, (uint64_t)b.material_goods.size());
        for (int32_t g : b.material_goods) h = mix_scalar<int32_t>(h, g);
        for (int64_t q : b.material_qty) h = mix_scalar<int64_t>(h, q);
    }
    for (size_t k = 0; k < MILITARY_MAX_SUPPLY_CLASSES; ++k) {
        h = mix_scalar<uint64_t>(h, (uint64_t)c.supply_goods[k].size());
        for (int32_t g : c.supply_goods[k]) h = mix_scalar<int32_t>(h, g);
        for (int32_t y : c.supply_yield_q16[k]) h = mix_scalar<int32_t>(h, y);
    }
    h = mix_scalar<int32_t>(h, c.ration_need_per_head_q16);
    h = mix_scalar<int32_t>(h, c.economy_good_count);
    h = mix_scalar<int32_t>(h, c.unlock_count);
    for (int16_t v : c.landform_flat) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.landform_rough) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.landform_def_q8) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.landform_width_q8) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.landform_supply_q8) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.landform_attrition_bp100) h = mix_scalar<int16_t>(h, v);
    for (uint8_t v : c.landform_passable) h = mix_scalar<uint8_t>(h, v);
    for (int16_t v : c.vegetation_rough) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.vegetation_def_q8) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.vegetation_supply_q8) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.vegetation_attrition_bp100) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.cover_flat) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.cover_supply_q8) h = mix_scalar<int16_t>(h, v);
    for (int16_t v : c.cover_attrition_bp100) h = mix_scalar<int16_t>(h, v);
    return h;
}

int32_t barracks_capacity_for_tier(const MilitaryCatalog &c, int32_t tier) {
    for (const MilitaryStateBuilding &b : c.state_buildings) {
        if (b.role == (uint8_t)MILITARY_STATE_BARRACKS && (int32_t)b.tier == tier) return b.capacity;
    }
    return 0;
}

int32_t barracks_speed_index_matches(const MilitaryCatalog &c, int32_t tier, int32_t *out) {
    int32_t best = MILITARY_Q16;
    bool found = false;
    for (const MilitaryStateBuilding &b : c.state_buildings) {
        if (b.role != (uint8_t)MILITARY_STATE_WAR_COLLEGE) continue;
        if ((int32_t)b.tier != tier) continue;
        found = true;
        if (b.training_speed_q16 > best) best = b.training_speed_q16;
    }
    if (out) *out = best;
    return found ? 1 : 0;
}

int32_t kind_factor_q16(uint8_t from_class, uint8_t to_class, bool same_unit) {
    if (same_unit) return MILITARY_Q16 / 4;   // re-equip 0.25
    if (from_class == to_class) return 26214; // same category retrain 0.4
    return 52429;                             // cross category retrain 0.8
}

} // namespace

void ensure_catalog_tables(MilitaryCatalog &catalog) {
    const size_t lf_n = std::max<size_t>(16, catalog.landform_flat.size());
    const size_t veg_n = std::max<size_t>(28, catalog.vegetation_rough.size());
    const size_t cv_n = std::max<size_t>(7, catalog.cover_flat.size());
    military_fill_terrain_defaults(catalog, lf_n, veg_n, cv_n);
    for (MilitaryUnitType &u : catalog.units) normalize_unit(u);
    catalog.militia_unit = -1;
    for (size_t i = 0; i < catalog.units.size(); ++i) {
        if (catalog.units[i].is_default_militia) {
            catalog.militia_unit = (int32_t)i;
            break;
        }
    }
}

namespace {

void normalize_digest(const MilitaryTerrainInput &t, MilitaryWorldDigest &d) {
    const size_t n = (size_t)std::max(0, t.cell_count);
    auto fix_cell = [n](std::vector<int32_t> &v, int32_t fill) {
        if (v.size() < n) v.resize(n, fill);
        if (v.size() > n) v.resize(n);
    };
    auto fix_cell64 = [n](std::vector<int64_t> &v) {
        if (v.size() < n) v.resize(n, 0);
        if (v.size() > n) v.resize(n);
    };
    fix_cell(d.cell_owner_slot, -1);
    fix_cell64(d.cell_population);
    fix_cell64(d.cell_unemployed);
    fix_cell64(d.cell_soldiers);
    if (d.cell_has_merchant.size() < n) d.cell_has_merchant.resize(n, 0);
    if (d.cell_has_merchant.size() > n) d.cell_has_merchant.resize(n);
    if (d.market_cell.size() > d.market_good.size()) d.market_good.resize(d.market_cell.size(), -1);
    if (d.market_cell.size() > d.market_sellable.size()) d.market_sellable.resize(d.market_cell.size(), 0);
    if (d.market_cell.size() > d.market_price.size()) d.market_price.resize(d.market_cell.size(), 0);
    if (d.country_capacity < 0) d.country_capacity = 0;
    const size_t cap = (size_t)d.country_capacity;
    grow_zero(d.country_handle, cap);
    grow_zero(d.country_cash, cap);
    grow_zero(d.country_era, cap);
    grow_zero(d.country_annual_revenue, cap);
    grow_zero(d.country_capital_cell, cap);
    grow_zero(d.country_soldier_living_cost, cap);
    if (d.unlock_words < 0) d.unlock_words = 0;
    if (d.stat_count < 0) d.stat_count = 0;
    grow_zero(d.country_unlock_bits, cap * (size_t)d.unlock_words);
    grow_zero(d.country_stat_q16, cap * (size_t)d.stat_count);
    // State building lanes are sparse, so they are only truncated to the
    // shortest of the four (a producer that died mid-write must not leave a cell
    // row without its unit count) instead of being resized to the cell count.
    if (d.state_lane_rows < 0) d.state_lane_rows = 0;
    size_t state_rows = (size_t)d.state_lane_rows;
    state_rows = std::min(state_rows, d.state_cell.size());
    state_rows = std::min(state_rows, d.state_type_id.size());
    state_rows = std::min(state_rows, d.state_state_role.size());
    state_rows = std::min(state_rows, d.state_units.size());
    d.state_lane_rows = (int32_t)state_rows;
    d.state_cell.resize(state_rows);
    d.state_type_id.resize(state_rows);
    d.state_state_role.resize(state_rows);
    d.state_units.resize(state_rows);
    // A payload with rows but no "the ledger answered" flag is a producer bug;
    // trusting it would zero the cache. Treat rows as proof of presence so the
    // lanes are never silently ignored, which is the safer of the two failures.
    if (state_rows > 0) d.state_lanes_present = true;
}

} // namespace

// ============================================================== lifecycle

bool MilitaryCore::configure(MilitaryCatalog catalog, uint64_t world_seed, std::string &error) {
    error.clear();
    if (catalog.units.size() > (size_t)MILITARY_MAX_UNIT_TYPES) {
        error = "catalog_too_many_units";
        return false;
    }
    int32_t militia_count = 0;
    for (const MilitaryUnitType &u : catalog.units) {
        if (u.id.empty()) {
            error = "catalog_unit_missing_id";
            return false;
        }
        if (u.is_default_militia) ++militia_count;
    }
    if (militia_count != 1) {
        error = militia_count == 0 ? "catalog_no_militia_unit" : "catalog_multiple_militia_units";
        return false;
    }
    for (size_t i = 1; i < catalog.units.size(); ++i) {
        if (!(catalog.units[i - 1].id < catalog.units[i].id)) {
            error = "catalog_units_not_sorted";
            return false;
        }
    }
    ensure_catalog_tables(catalog);
    catalog.hash = catalog_hash(catalog);
    _catalog = std::move(catalog);
    _catalog.hash = catalog_hash(_catalog);
    _seed = world_seed;
    _configured = true;
    reset_state();
    if (_terrain.cell_count > 0) {
        MilitaryTerrainInput keep = _terrain;
        std::string terrain_error;
        if (!set_terrain(std::move(keep), terrain_error)) {
            error = terrain_error;
            return false;
        }
    }
    return true;
}

bool MilitaryCore::set_terrain(MilitaryTerrainInput terrain, std::string &error) {
    error.clear();
    if (terrain.cell_count < 0 || terrain.width < 0 || terrain.height < 0) {
        error = "terrain_negative_dimensions";
        return false;
    }
    const size_t n = (size_t)terrain.cell_count;
    if (n > 0 && terrain.width > 0 && terrain.height > 0 &&
        (int64_t)terrain.width * (int64_t)terrain.height != (int64_t)n) {
        error = "terrain_size_mismatch";
        return false;
    }
    if (terrain.neighbors.size() != n * 6) {
        error = "terrain_neighbors_size";
        return false;
    }
    auto fix = [n](std::vector<uint8_t> &v, uint8_t fill) {
        if (v.size() < n) v.resize(n, fill);
        if (v.size() > n) v.resize(n);
    };
    fix(terrain.landform, 4);
    fix(terrain.vegetation, 0);
    fix(terrain.cover, 0);
    fix(terrain.is_water, 0);
    fix(terrain.has_river, 0);
    fix(terrain.settlement_tier, 0);
    for (size_t i = 0; i < terrain.neighbors.size(); ++i) {
        int32_t v = terrain.neighbors[i];
        if (v < -1 || v >= terrain.cell_count || (v >= 0 && (size_t)v == i / 6)) {
            terrain.neighbors[i] = -1;
        }
    }
    // The seasonal refresh pushes new cover/vegetation for the SAME topology.
    // Only a shape or neighbour-table change invalidates state; anything else
    // swaps the terrain arrays in place and marks derived data dirty, so a
    // mid-war world keeps its wars, armies, lots and policies (design §21).
    const bool same_topology = _configured && !_terrain_configured_never &&
                               terrain.cell_count == _terrain.cell_count &&
                               terrain.width == _terrain.width && terrain.height == _terrain.height &&
                               terrain.neighbors == _terrain.neighbors;
    _terrain = std::move(terrain);
    _terrain_configured_never = false;
    if (!same_topology) {
        reset_state();
        return true;
    }
    // Same answer as a fresh set_terrain for terrain-derived data: the rings,
    // market rows, connectivity and the cached attack/defence are rebuilt from
    // the new arrays before they are used again.
    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    _front_edges.clear();
    _front_edge_set.assign(cells * 6, 0);
    _front_edge_pos.clear();
    _front_unsorted = false;
    _front_recompute = 1;        // canonical front rebuild, bumps the revision on change
    _connected_valid = false;
    _md_day = -1;
    _ring_off.clear();
    _ring_len.clear();
    _ring_cells.clear();
    _ring_dist.clear();
    military_refresh_army_caches(*this);
    return true;
}

void MilitaryCore::reset_state() {
    _last_day = -1;
    _next_sequence = 0;
    _next_id = 1;
    _next_event_id = 1;
    _control_revision = 0;
    _front_revision = 0;
    _ut_dirty = true;

    _pending.clear();
    _path_cells.clear();
    _template_rows.clear();
    _training.clear();
    _stocks.clear();
    _shipments.clear();
    _engagements.clear();
    _wars.clear();
    _truces.clear();
    _reparations.clear();
    _battle_log.clear();
    _areas.clear();
    _events.clear();
    _cell_states.clear();
    _cell_state_index.clear();

    _lots = MilitaryLotStore();
    _lots.free_list.clear();

    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    _cell_controller.assign(cells, -1);

    const size_t cap = (size_t)MILITARY_MAX_ARMIES;
    MilitaryArmyStore &a = _armies;
    a.generation.assign(cap, 0);
    a.active.assign(cap, 0);
    a.owner_slot.assign(cap, -1);
    a.cell.assign(cap, -1);
    a.next_cell.assign(cap, -1);
    a.move_points_q16.assign(cap, 0);
    a.stance.assign(cap, (uint8_t)MILITARY_STANCE_HOLD);
    a.mission.assign(cap, (uint8_t)MILITARY_MISSION_NONE);
    a.target_cell.assign(cap, -1);
    a.area_id.assign(cap, -1);
    a.organization_q16.assign(cap, MILITARY_Q16);
    a.morale_q16.assign(cap, MILITARY_Q16 / 2);
    a.supply_ratio_q16.assign(cap, MILITARY_Q16);
    a.ration_ratio_q16.assign(cap, MILITARY_Q16);
    a.pay_ratio_q16.assign(cap, MILITARY_Q16);
    a.path_offset.assign(cap, 0);
    a.path_len.assign(cap, 0);
    a.path_cursor.assign(cap, 0);
    a.reinforce_enabled.assign(cap, 0);
    a.template_offset.assign(cap, 0);
    a.template_len.assign(cap, 0);
    a.commander_slot.assign(cap, 0);
    a.cached_headcount.assign(cap, 0);
    a.cached_attack_q16.assign(cap, 0);
    a.cached_defense_q16.assign(cap, 0);
    a.cached_speed_q16.assign(cap, MILITARY_Q16);
    a.engagement.assign(cap, -1);
    a.moved_day.assign(cap, -1);
    a.prev_cell.assign(cap, -1);
    a.name_seed.assign(cap, 0);
    a.funds.assign(cap, 0);
    a.next_in_cell.assign(cap, -1);
    a.prev_in_cell.assign(cap, -1);
    a.free_list.clear();
    a.free_list.reserve(cap);
    for (int32_t i = (int32_t)cap - 1; i >= 0; --i) a.free_list.push_back(i);

    _policies.clear();
    _policy_handle.clear();
    _ai_country.clear();
    _ai_next_decision_day.clear();

    _ledger_received = _ledger_consumed = 0;
    _ledger_intercepted_out = _ledger_intercepted_in = _ledger_returned = 0;

    _report = MilitaryReport();
    _cell_head.assign(cells, -1);
    _cell_engagement_mask.assign(cells, 0);
    _front_edges.clear();
    _front_edge_set.assign(cells * 6, 0);
    _front_edge_pos.clear();
    _front_unsorted = false;
    _front_recompute = 0;
    _threat.assign(cells, 0);
    _guard.assign(cells, 0);
    _threat_stamp.assign(cells, 0);
    _stamp = 1;
    _dij_dist.assign(cells, 0);
    _dij_parent.assign(cells, -1);
    _dij_stamp.assign(cells, 0);
    _dij_gen = 1;
    _heap.clear();
    _heap.reserve(4096);
    // Derived logistics indexes.
    _connected_valid = false;
    _bfs_queue.clear();
    _ring_off.clear();
    _ring_len.clear();
    _ring_cells.clear();
    _ring_dist.clear();
    _md_cell_off.clear();
    _md_cell_rows.clear();
    _md_row_cell.clear();
    _md_row_good.clear();
    _md_row_sellable.clear();
    _md_row_price.clear();
    _md_cell_has_merchant.clear();
    _md_day = -1;
    _cache_rows.clear();
    _ct_conflict.assign(cells, 0);
    _ct_ctrl_cells.clear();
    _ct_ctrl_pos.clear();
    _ct_ctrl_ok = false;
    _ct_owned_by_slot.clear();
    _ct_ctrl_by_slot.clear();
    _ct_pairs.clear();
    _ct_sums_day = -1;
    _ct_sums_ok = false;
    _ct_value.clear();
    _ct_annex_value.clear();
    _ct_owned_count.clear();
    // Lot / stock / front indexes.
    _lot_index_ok = false;
    _lot_next.clear();
    _lot_link_kind.clear();
    _lot_link_loc.clear();
    _lot_army_head.clear();
    _lot_cell_head.clear();
    _stock_rows.clear();
    _stock_index_ok = false;
    _unmet_procure_units.clear();
    _unmet_procure_holders = 0;
    _unmet_units_total = 0;
    _unmet_goods_total = 0;
    _ut_dirty = true;
    _cache_era.clear();
    _view_scratch = MilitaryWorldDigest();
    _last_digest = MilitaryWorldDigest();
}

// ============================================================== handles

int32_t MilitaryCore::country_slot_for_handle(uint64_t handle) const {
    if (handle == 0) return -1;
    const size_t n = std::min(_policy_handle.size(), _policies.size());
    for (size_t i = 0; i < n; ++i) {
        if (_policy_handle[i] == handle) return (int32_t)i;
    }
    return -1;
}

uint64_t MilitaryCore::country_handle_for_slot(int32_t slot) const {
    if (slot < 0 || (size_t)slot >= _policy_handle.size()) return 0;
    return _policy_handle[(size_t)slot];
}

int32_t MilitaryCore::ensure_country_slot(uint64_t handle) {
    if (handle == 0) return -1;
    const int32_t existing = country_slot_for_handle(handle);
    if (existing >= 0) return existing;
    for (size_t i = 0; i < _policy_handle.size(); ++i) {
        if (_policy_handle[i] == 0) {
            _policy_handle[i] = handle;
            _policies[i].config_share_bp.assign(_catalog.units.size(), 0);
            if (_ai_country.size() < i + 1) _ai_country.resize(i + 1, 0);
            if (_ai_next_decision_day.size() < i + 1) _ai_next_decision_day.resize(i + 1, 0);
            return (int32_t)i;
        }
    }
    const size_t slot = _policy_handle.size();
    _policy_handle.push_back(handle);
    _policies.emplace_back();
    _policies.back().config_share_bp.assign(_catalog.units.size(), 0);
    _ai_country.push_back(0);
    _ai_next_decision_day.push_back(0);
    _path_daily_requests.push_back(0);
    return (int32_t)slot;
}

uint64_t MilitaryCore::army_handle(int32_t slot) const {
    if (!army_alive(_armies, slot)) return 0;
    return ((uint64_t)_armies.generation[(size_t)slot] << 32) | (uint64_t)(uint32_t)slot;
}

bool MilitaryCore::resolve_army(uint64_t handle, int32_t &slot) const {
    slot = -1;
    if (handle == 0) return false;
    const uint32_t raw = (uint32_t)(handle & 0xFFFFFFFFull);
    const uint32_t gen = (uint32_t)(handle >> 32);
    if ((size_t)raw >= _armies.generation.size()) return false;
    const int32_t s = (int32_t)raw;
    if (!army_alive(_armies, s)) return false;
    if (_armies.generation[(size_t)s] != gen) return false;
    slot = s;
    return true;
}

int32_t MilitaryCore::controller_of(int32_t cell) const {
    if (cell < 0 || (size_t)cell >= _cell_controller.size()) return -1;
    return _cell_controller[(size_t)cell];
}

// ============================================================== events

// Design 19.1 payload schemas (military-runtime.md §10).
uint16_t military_event_payload_schema(uint16_t type) {
    switch (type) {
        case MILITARY_EVENT_WAR_DECLARED: return 20;
        case MILITARY_EVENT_WAR_ENDED: return 20;
        case MILITARY_EVENT_BATTLE_RESOLVED: return 21;
        case MILITARY_EVENT_CELL_CONTROL_CHANGED: return 22;
        case MILITARY_EVENT_ARMY_DESTROYED: return 21;
        case MILITARY_EVENT_COUNTRY_ANNEXED: return 23;
        case MILITARY_EVENT_CONVOY_INTERCEPTED: return 24;
        case MILITARY_EVENT_LEVY_APPLIED: return 25;
        default: return 20;
    }
}

namespace {

// Per-day coalescing table for push_event: open addressing over
// (type, cell, i0, i1) -> index into the day's suffix of the event ring.
struct EventDayIndex {
    std::vector<uint64_t> keys;     // 0 = empty
    std::vector<int32_t> rows;
    int64_t day = -1;

    // Power-of-two capacity with a hard load factor below 1: `insert` below
    // assumes a free slot always exists (a full table would spin forever).
    void clear(int64_t new_day, size_t live) {
        day = new_day;
        size_t capacity = 64;
        while (capacity < live * 4 + 64) capacity <<= 1;
        keys.assign(capacity, 0ull);
        rows.assign(capacity, -1);
    }

    bool compatible(size_t live) const {
        return !keys.empty() && keys.size() >= live * 2 + 64;
    }

    // Returns the row a coalescable earlier event lives in, or -1.
    int32_t find(uint64_t key) const {
        if (keys.empty()) return -1;
        size_t h = (size_t)(key & (keys.size() - 1));
        for (size_t probe = 0; probe < keys.size(); ++probe) {
            if (keys[h] == 0ull) return -1;
            if (keys[h] == key) return rows[h];
            h = (h + 1) & (keys.size() - 1);
        }
        return -1;
    }

    void insert(uint64_t key, int32_t row) {
        if (keys.empty()) return;
        size_t h = (size_t)(key & (keys.size() - 1));
        size_t probes = 0;
        while (keys[h] != 0ull) {
            if (keys[h] == key) {   // replace (row indices only grow)
                rows[h] = row;
                return;
            }
            h = (h + 1) & (keys.size() - 1);
            if (++probes > keys.size()) return;   // defensive: never spin
        }
        keys[h] = key;
        rows[h] = row;
    }
};

// Coalescing identity of one event (design 19.1 rate caps).
inline uint64_t event_day_key(const MilitaryEvent &e) {
    uint64_t key = mix_key((uint64_t)e.type | 0x10000ull, (uint64_t)(uint32_t)(e.cell + 1));
    key = mix_key(key, mix_key((uint64_t)e.i0, (uint64_t)e.i1 | 0x10000ull));
    return key == 0ull ? 1ull : key;
}

EventDayIndex &event_day_index() {
    static thread_local EventDayIndex index;
    return index;
}

} // namespace

void MilitaryCore::push_event(const MilitaryEvent &event) {
    MilitaryEvent e = event;
    // Design 19.1: every Military event carries its payload schema (20..25).
    if (e.payload_schema == 0) e.payload_schema = military_event_payload_schema(e.type);
    e.id = _next_event_id++;
    const size_t cap = (size_t)MILITARY_EVENT_RING_CAPACITY;
    // Coalescing: the same (type, cell, i0, i1) within one day folds into the
    // first row with that identity instead of consuming ring space (design
    // 19.1 rate caps). The per-day table keeps this O(1).
    EventDayIndex &index = event_day_index();
    if (index.day != e.day || !index.compatible(_events.size())) index.clear(e.day, _events.size());
    const uint64_t key = event_day_key(e);
    const int32_t hit = index.find(key);
    if (hit >= 0 && (size_t)hit < _events.size() && _events[(size_t)hit].day == e.day) {
        MilitaryEvent &prev = _events[(size_t)hit];
        prev.value += e.value;
        prev.id = e.id;
        ++_report.event_coalesced;
        return;
    }
    if (_events.size() >= cap) {
        // Ring full: drop the oldest row and rebuild the day table from the
        // survivors (row indices shift, so a stale table is unusable).
        _events.erase(_events.begin(), _events.begin() + (ptrdiff_t)(_events.size() - cap + 1));
        ++_report.event_coalesced;
        index.clear(e.day, _events.size());
        for (size_t i = 0; i < _events.size(); ++i) {
            const MilitaryEvent &row = _events[i];
            if (row.day != e.day) continue;
            const uint64_t k = event_day_key(row);
            if (index.find(k) < 0) index.insert(k, (int32_t)i);
        }
    }
    index.insert(key, (int32_t)_events.size());
    _events.push_back(e);
}

std::vector<MilitaryEvent> MilitaryCore::events_after(uint64_t after_id, size_t limit) const {
    std::vector<MilitaryEvent> out;
    if (limit == 0) return out;
    out.reserve(std::min(limit, _events.size()));
    for (const MilitaryEvent &e : _events) {
        if (e.id <= after_id) continue;
        out.push_back(e);
        if (out.size() >= limit) break;
    }
    return out;
}

// ============================================================== armies

int32_t MilitaryCore::create_army(int32_t country_slot, int32_t cell) {
    if (_armies.free_list.empty()) return -1;
    const int32_t slot = _armies.free_list.back();
    _armies.free_list.pop_back();
    if (slot < 0 || (size_t)slot >= _armies.active.size()) return -1;
    const size_t s = (size_t)slot;
    _armies.active[s] = 1;
    _armies.owner_slot[s] = country_slot;
    _armies.cell[s] = cell;
    _armies.next_cell[s] = -1;
    _armies.move_points_q16[s] = 0;
    _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
    _armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
    _armies.target_cell[s] = -1;
    _armies.area_id[s] = -1;
    _armies.organization_q16[s] = MILITARY_Q16;
    _armies.morale_q16[s] = MILITARY_Q16 / 2;
    _armies.supply_ratio_q16[s] = MILITARY_Q16;
    _armies.ration_ratio_q16[s] = MILITARY_Q16;
    _armies.pay_ratio_q16[s] = MILITARY_Q16;
    _armies.path_offset[s] = 0;
    _armies.path_len[s] = 0;
    _armies.path_cursor[s] = 0;
    _armies.reinforce_enabled[s] = 0;
    _armies.template_offset[s] = 0;
    _armies.template_len[s] = 0;
    _armies.commander_slot[s] = 0;   // v1: commander slot always open (6.4)
    _armies.cached_headcount[s] = 0;
    _armies.cached_attack_q16[s] = 0;
    _armies.cached_defense_q16[s] = 0;
    _armies.cached_speed_q16[s] = MILITARY_Q16;
    _armies.engagement[s] = -1;
    _armies.moved_day[s] = _last_day;
    _armies.prev_cell[s] = cell;
    _armies.name_seed[s] =
        (uint32_t)(rng(_seed, mix_key(0x41524d59ull, (uint64_t)slot), _last_day) & 0xFFFFFFFFull);
    _armies.funds[s] = 0;
    _armies.next_in_cell[s] = -1;
    _armies.prev_in_cell[s] = -1;
    // Personnel lane bookkeeping (transient): a recycled slot never inherits the
    // previous formation's in-flight embarkation.
    if (_army_lane_pending.size() < _armies.active.size())
        _army_lane_pending.resize(_armies.active.size(), 0);
    _army_lane_pending[s] = 0;
    if (_armies.generation[s] == 0) _armies.generation[s] = 1;
    index_insert(slot, cell);
    return slot;
}

void MilitaryCore::destroy_army(int32_t army_slot) {
    if (!army_alive(_armies, army_slot)) return;
    const size_t s = (size_t)army_slot;
    // Any lot still pointing at this formation would be a dangling army
    // reference in PKMI (pkmi_lot_army_missing on the next restore).
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (!_lots.active[i]) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (_lots.location[i] != army_slot) continue;
        _lots.active[i] = 0;
        _lots.free_list.push_back((int32_t)i);
    }
    if (s < _army_lane_pending.size()) _army_lane_pending[s] = 0;
    index_remove(army_slot);
    _armies.active[s] = 0;
    _armies.engagement[s] = -1;
    _armies.cell[s] = -1;
    _armies.next_cell[s] = -1;
    _armies.prev_cell[s] = -1;
    _armies.path_len[s] = 0;
    _armies.path_cursor[s] = 0;
    _armies.template_len[s] = 0;
    _armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
    uint32_t gen = _armies.generation[s] + 1u;
    if (gen == 0) gen = 1;
    _armies.generation[s] = gen;
    _armies.free_list.push_back(army_slot);
}

// ============================================================== lots

namespace {

int32_t *lot_head_ptr(MilitaryCore &c, uint8_t kind, int32_t loc) {
    if (loc < 0) return nullptr;
    if (kind == (uint8_t)MILITARY_LOT_ARMY) {
        return (size_t)loc < c._lot_army_head.size() ? &c._lot_army_head[(size_t)loc] : nullptr;
    }
    return (size_t)loc < c._lot_cell_head.size() ? &c._lot_cell_head[(size_t)loc] : nullptr;
}

void lot_link_head(MilitaryCore &c, int32_t lot) {
    const size_t s = (size_t)lot;
    const uint8_t kind = c._lots.location_kind[s];
    const int32_t loc = c._lots.location[s];
    int32_t *head = lot_head_ptr(c, kind, loc);
    if (!head) return;
    c._lot_next[s] = *head;
    *head = lot;
    c._lot_link_kind[s] = kind;
    c._lot_link_loc[s] = loc;
}

} // namespace

void military_lot_index_rebuild(const MilitaryCore &cc) {
    MilitaryCore &c = const_cast<MilitaryCore &>(cc);
    const size_t n = c._lots.active.size();
    c._lot_next.assign(n, -1);
    c._lot_link_kind.assign(n, 255);
    c._lot_link_loc.assign(n, -1);
    c._lot_army_head.assign(c._armies.active.size(), -1);
    c._lot_cell_head.assign((size_t)std::max(0, c._terrain.cell_count), -1);
    // Ascending iteration order is produced by walking the list BACKWARDS in
    // military_for_each_lot; the list itself only has to be a set.
    for (size_t k = 0; k < n; ++k) {
        if (!c._lots.active[k]) continue;
        lot_link_head(c, (int32_t)k);
    }
    c._lot_index_ok = true;
}

void military_lot_index_unlink(MilitaryCore &c, int32_t lot) {
    if (!c._lot_index_ok) return;
    const size_t s = (size_t)lot;
    if (lot < 0 || s >= c._lot_link_kind.size() || c._lot_link_kind[s] == 255) return;
    int32_t *head = lot_head_ptr(c, c._lot_link_kind[s], c._lot_link_loc[s]);
    if (head) {
        if (*head == lot) {
            *head = c._lot_next[s];
        } else {
            int32_t p = *head;
            while (p >= 0 && c._lot_next[(size_t)p] != lot) p = c._lot_next[(size_t)p];
            if (p >= 0) c._lot_next[(size_t)p] = c._lot_next[s];
        }
    }
    c._lot_next[s] = -1;
    c._lot_link_kind[s] = 255;
    c._lot_link_loc[s] = -1;
}

void military_lot_index_link(MilitaryCore &c, int32_t lot) {
    if (!c._lot_index_ok) {
        military_lot_index_rebuild(c);
        return;
    }
    const size_t n = c._lots.active.size();
    if (c._lot_next.size() < n) {
        c._lot_next.resize(n, -1);
        c._lot_link_kind.resize(n, 255);
        c._lot_link_loc.resize(n, -1);
    }
    if (lot < 0 || (size_t)lot >= n) return;
    if (c._lot_link_kind[(size_t)lot] != 255) military_lot_index_unlink(c, lot);
    if (!c._lots.active[(size_t)lot]) return;
    lot_link_head(c, lot);
}

int32_t MilitaryCore::lot_find_or_create(uint8_t kind, int32_t location, int32_t country_slot,
                                         int16_t unit, int16_t quality_q8) {
    const size_t n = _lots.active.size();
    int32_t found = -1;
    military_for_each_lot(*this, kind, location, [&](int32_t i) {
        if (found >= 0) return;
        const size_t s = (size_t)i;
        if (_lots.country_slot[s] != country_slot) return;
        if (_lots.unit_type[s] != unit) return;
        if (std::abs((int32_t)_lots.equip_quality_q8[s] - (int32_t)quality_q8) > 16) return;
        found = i;
    });
    if (found >= 0) return found;
    int32_t slot = -1;
    if (!_lots.free_list.empty()) {
        slot = _lots.free_list.back();
        _lots.free_list.pop_back();
    } else {
        slot = (int32_t)n;
        _lots.active.push_back(0);
        _lots.location_kind.push_back(0);
        _lots.location.push_back(-1);
        _lots.country_slot.push_back(-1);
        _lots.unit_type.push_back(-1);
        _lots.equip_quality_q8.push_back(256);
        _lots.condition_q16.push_back(MILITARY_Q16);
        _lots.count.push_back(0);
    }
    if (slot < 0) return -1;
    const size_t s = (size_t)slot;
    _lots.active[s] = 1;
    _lots.location_kind[s] = kind;
    _lots.location[s] = location;
    _lots.country_slot[s] = country_slot;
    _lots.unit_type[s] = unit;
    _lots.equip_quality_q8[s] = quality_q8;
    _lots.condition_q16[s] = MILITARY_Q16;
    _lots.count[s] = 0;
    military_lot_index_link(*this, slot);
    return slot;
}

int64_t MilitaryCore::lot_remove_casualties(uint8_t kind, int32_t location, int64_t count) {
    if (count <= 0) return 0;
    // Proportional removal with largest-remainder rounding, ties by lot index.
    static thread_local std::vector<int32_t> rows;
    rows.clear();
    int64_t total = 0;
    military_for_each_lot(*this, kind, location, [&](int32_t i) {
        rows.push_back(i);
        total += _lots.count[(size_t)i];
    });
    if (total <= 0) return 0;
    const int64_t want = std::min(count, total);
    int64_t assigned = 0;
    for (int32_t i : rows) {
        const size_t s = (size_t)i;
        int64_t share = mul_div(_lots.count[s], want, total);
        if (share > _lots.count[s]) share = _lots.count[s];
        _lots.count[s] -= share;
        assigned += share;
    }
    int64_t rest = want - assigned;
    for (size_t k = 0; k < rows.size() && rest > 0; ++k) {
        const size_t idx = (size_t)rows[k];
        if (_lots.count[idx] > 0) {
            _lots.count[idx] -= 1;
            --rest;
        }
    }
    for (size_t k = 0; k < rows.size() && rest > 0; ++k) {
        const size_t idx = (size_t)rows[k];
        const int64_t take = std::min(rest, _lots.count[idx]);
        _lots.count[idx] -= take;
        rest -= take;
    }
    for (int32_t i : rows) {
        const size_t s = (size_t)i;
        if (_lots.active[s] && _lots.count[s] <= 0) {
            military_lot_index_unlink(*this, i);
            _lots.active[s] = 0;
            _lots.count[s] = 0;
            _lots.location[s] = -1;
            _lots.free_list.push_back(i);
        }
    }
    return want;
}

MilitaryCellState *MilitaryCore::cell_state(int32_t cell, bool create) {
    if (cell < 0 || cell >= _terrain.cell_count) return nullptr;
    // Flat occupancy mirror (stamp-free: rebuilt on restore, kept in sync here)
    // avoids a memmove of the whole sparse vector for every new cell.
    if (_cell_state_index.size() != (size_t)_terrain.cell_count) {
        _cell_state_index.assign((size_t)_terrain.cell_count, -1);
        for (size_t i = 0; i < _cell_states.size(); ++i) {
            const int32_t c = _cell_states[i].cell;
            if (c >= 0 && (size_t)c < _cell_state_index.size()) _cell_state_index[(size_t)c] = (int32_t)i;
        }
    }
    int32_t idx = _cell_state_index[(size_t)cell];
    if (idx >= 0 && (size_t)idx < _cell_states.size() && _cell_states[(size_t)idx].cell == cell) {
        return &_cell_states[(size_t)idx];
    }
    if (!create) return nullptr;
    MilitaryCellState st;
    st.cell = cell;
    // Keep rows sorted by cell (posts_for_cell binary-searches; PKMI restore sorts).
    auto it = std::lower_bound(_cell_states.begin(), _cell_states.end(), cell,
                               [](const MilitaryCellState &row, int32_t c) { return row.cell < c; });
    idx = (int32_t)(it - _cell_states.begin());
    _cell_states.insert(it, st);
    for (size_t i = (size_t)idx; i < _cell_states.size(); ++i) _cell_state_index[(size_t)_cell_states[i].cell] = (int32_t)i;
    return &_cell_states[(size_t)idx];
}

// Kept next to `cell_state` because it is the only other writer of the cache
// fields: everything else in this TU only reads them.
void MilitaryCore::refresh_state_building_cache(const MilitaryWorldDigest &digest) {
    // No lane at all means the producer predates this contract; the cache the
    // save restored is the only truth available, so leave it untouched.
    if (!digest.state_lanes_present) return;
    const size_t rows = std::min((size_t)std::max(0, digest.state_lane_rows),
        std::min(digest.state_cell.size(),
            std::min(digest.state_type_id.size(),
                std::min(digest.state_state_role.size(), digest.state_units.size()))));
    // Resolve each ledger row through the military catalog: `state_role` in the
    // digest is the economy's copy and is only used to detect drift, while the
    // military catalog stays the authority on what tier a lot represents.
    struct LedgerRow {
        int32_t cell;
        int32_t role;
        int32_t tier;
        int64_t units;
    };
    static thread_local std::vector<LedgerRow> parsed;
    parsed.clear();
    parsed.reserve(rows);
    for (size_t i = 0; i < rows; ++i) {
        const int32_t cell = digest.state_cell[i];
        const int32_t type_id = digest.state_type_id[i];
        const int64_t units = digest.state_units[i];
        if (cell < 0 || cell >= _terrain.cell_count || units <= 0) continue;
        int32_t role = -1;
        int32_t tier = -1;
        for (const MilitaryStateBuilding &b : _catalog.state_buildings) {
            if (b.economy_building_id != type_id) continue;
            role = (int32_t)b.role;
            tier = (int32_t)b.tier;
            break;
        }
        if (role < 0) {
            // A kind-3 lot with no military profile cannot contribute posts,
            // fort bonus or training speed. Report it instead of guessing a tier.
            ++_report.state_ledger_unmapped;
            continue;
        }
        if (digest.state_state_role[i] != role + 1) ++_report.state_role_mismatch;
        parsed.push_back({cell, role, tier, units});
    }
    // The producer reports rows sorted by (cell, type) and this function relies
    // on cell order twice, so the sort is enforced here rather than assumed:
    // a producer that ever changes its ordering would otherwise silently make
    // the divergence probe compare the wrong cells.
    std::stable_sort(parsed.begin(), parsed.end(),
        [](const LedgerRow &a, const LedgerRow &b) {
            if (a.cell != b.cell) return a.cell < b.cell;
            if (a.role != b.role) return a.role < b.role;
            return a.tier < b.tier;
        });
    // Divergence probe (requirement 6.4). The cache on entry is exactly what
    // yesterday's rebuild wrote, unless something else in this TU touched it -
    // which is the bug this counter exists to surface. "Yesterday's rebuild" is
    // reconstructible from `_state_ledger_prev`, so a legitimate arrival or
    // demolition (the ledger itself changed) is not mistaken for a stale cache.
    if (_state_ledger_prev_valid) {
        struct CachedCell {
            int32_t cell;
            int32_t barracks[MILITARY_STATE_BARRACKS_TIERS];
            int32_t fort;
            int32_t college;
        };
        static thread_local std::vector<CachedCell> expected;
        expected.clear();
        for (size_t i = 0; i < _state_ledger_prev.size();) {
            const int32_t cell = _state_ledger_prev[i].cell;
            CachedCell row;
            row.cell = cell;
            std::fill(row.barracks, row.barracks + MILITARY_STATE_BARRACKS_TIERS, 0);
            row.fort = -1;
            row.college = -1;
            while (i < _state_ledger_prev.size() && _state_ledger_prev[i].cell == cell) {
                const StateLedgerRow &prev = _state_ledger_prev[i];
                if (prev.role == (int32_t)MILITARY_STATE_BARRACKS) {
                    const int32_t tier = clamp32(prev.tier, 0, MILITARY_STATE_BARRACKS_TIERS - 1);
                    row.barracks[tier] += prev.units;
                } else if (prev.role == (int32_t)MILITARY_STATE_FORTIFICATION) {
                    row.fort = std::max<int32_t>(row.fort, prev.tier);
                } else {
                    row.college = std::max<int32_t>(row.college, prev.tier);
                }
                ++i;
            }
            expected.push_back(row);
        }
        // Both sides are sorted by cell, so one merge walk answers every cell.
        size_t cursor = 0;
        for (const MilitaryCellState &st : _cell_states) {
            while (cursor < expected.size() && expected[cursor].cell < st.cell) {
                // A cell the ledger believed in that no longer has a row: its
                // cache watched a building disappear without the ledger saying
                // so. The rebuild below creates the row again, so only the
                // mismatch is counted.
                for (int32_t t = 0; t < MILITARY_STATE_BARRACKS_TIERS; ++t) {
                    if (expected[cursor].barracks[t] != 0) { ++_report.state_cache_repairs; break; }
                }
                ++cursor;
            }
            bool same = true;
            if (cursor < expected.size() && expected[cursor].cell == st.cell) {
                const CachedCell &want = expected[cursor];
                same = want.fort == st.fort_tier && want.college == st.college_tier;
                for (int32_t t = 0; t < MILITARY_STATE_BARRACKS_TIERS && same; ++t) {
                    if (want.barracks[t] != st.barracks_count[t]) same = false;
                }
                ++cursor;
            } else {
                // No ledger row yesterday: the cache must be empty too.
                same = st.fort_tier < 0 && st.college_tier < 0;
                for (int32_t t = 0; t < MILITARY_STATE_BARRACKS_TIERS && same; ++t) {
                    if (st.barracks_count[t] != 0) same = false;
                }
            }
            if (!same) ++_report.state_cache_repairs;
        }
    }
    // Clear: a cell whose lots were all demolished must read as "no building",
    // and the ledger rows below are the only thing that may put one back.
    for (MilitaryCellState &st : _cell_states) {
        std::fill(st.barracks_count, st.barracks_count + MILITARY_STATE_BARRACKS_TIERS, 0);
        st.fort_tier = -1;
        st.college_tier = -1;
    }
    for (const LedgerRow &row : parsed) {
        MilitaryCellState *st = cell_state(row.cell, true);
        if (st == nullptr) continue;
        if (row.role == (int32_t)MILITARY_STATE_BARRACKS) {
            const int32_t tier = clamp32(row.tier, 0, MILITARY_STATE_BARRACKS_TIERS - 1);
            st->barracks_count[tier] += (int32_t)row.units;
        } else if (row.role == (int32_t)MILITARY_STATE_FORTIFICATION) {
            st->fort_tier = std::max<int32_t>(st->fort_tier, row.tier);
        } else {
            st->college_tier = std::max<int32_t>(st->college_tier, row.tier);
        }
    }
    // Remember what this rebuild produced, sorted by cell, so tomorrow can tell
    // a stale cache apart from a changed ledger.
    _state_ledger_prev.clear();
    _state_ledger_prev.reserve(parsed.size());
    for (const LedgerRow &row : parsed) {
        StateLedgerRow out;
        out.cell = row.cell;
        out.role = row.role;
        out.tier = row.tier;
        out.units = (int32_t)row.units;
        _state_ledger_prev.push_back(out);
    }
    _state_ledger_prev_valid = true;
}

// ============================================================== army cache

int32_t MilitaryCore::militia_era(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    if ((size_t)country_slot < _country_era.size()) return _country_era[(size_t)country_slot];
    if ((size_t)country_slot < _last_digest.country_era.size()) return _last_digest.country_era[(size_t)country_slot];
    return 0;
}

void MilitaryCore::refresh_army_cache(int32_t army_slot) {
    if (!army_alive(_armies, army_slot)) return;
    const size_t a = (size_t)army_slot;
    const int32_t owner = _armies.owner_slot[a];
    int64_t head = 0;
    int64_t attack = 0;
    int64_t defense = 0;
    int32_t speed_q16 = INT32_MAX;
    for (int32_t li = military_lot_head(*this, (uint8_t)MILITARY_LOT_ARMY, army_slot); li >= 0;
         li = _lot_next[(size_t)li]) {
        const size_t i = (size_t)li;
        if (!_lots.active[i]) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (_lots.location[i] != army_slot) continue;
        const int32_t unit = _lots.unit_type[i];
        if (unit < 0 || (size_t)unit >= _catalog.units.size()) continue;
        const MilitaryUnitType &u = _catalog.units[(size_t)unit];
        const int64_t cnt = _lots.count[i];
        if (cnt <= 0) continue;
        head += cnt;
        const int64_t eq = equip_factor_q16(u, _lots.equip_quality_q8[i]);
        const int64_t cond = clamp64(_lots.condition_q16[i], MILITARY_Q16 / 2, MILITARY_Q16);
        const int64_t cond_factor = MILITARY_Q16 / 2 + cond / 2;   // 0.5 + 0.5 * condition
        const int64_t power = mul_div(cnt * eq, cond_factor, MILITARY_Q16);   // heads * factors
        int64_t atk = u.attack_q16;
        int64_t def = u.defense_q16;
        if (unit == _catalog.militia_unit) {
            const int64_t era = era_factor_militia_q16(militia_era(owner));
            atk = mul_div(atk, era, MILITARY_Q16);
            def = mul_div(def, era, MILITARY_Q16);
        }
        attack += mul_div(power, atk, MILITARY_Q16);
        defense += mul_div(power, def, MILITARY_Q16);
        const int32_t spd = u.speed_q16;   // militia speed stays 1.0 across eras
        if (spd < speed_q16) speed_q16 = spd;
    }
    _armies.cached_headcount[a] = head;
    _armies.cached_attack_q16[a] = attack;
    _armies.cached_defense_q16[a] = defense;
    _armies.cached_speed_q16[a] = head > 0 ? speed_q16 : 0;
}

// ============================================================== queries

int64_t MilitaryCore::country_soldiers(int32_t slot) const {
    const size_t n = _lots.active.size();
    int64_t total = 0;
    for (size_t i = 0; i < n; ++i) {
        if (_lots.active[i] && _lots.country_slot[i] == slot) total += _lots.count[i];
    }
    return total;
}

int32_t MilitaryCore::posts_for_cell(int32_t cell, int32_t country_slot) const {
    (void)country_slot;
    if (cell < 0 || cell >= _terrain.cell_count) return 0;
    size_t lo = 0, hi = _cell_states.size();
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (_cell_states[mid].cell < cell) lo = mid + 1; else hi = mid;
    }
    if (lo >= _cell_states.size() || _cell_states[lo].cell != cell) return 0;
    const MilitaryCellState &st = _cell_states[lo];
    int64_t posts = 0;
    for (int32_t tier = 0; tier < 8; ++tier) {
        const int32_t count = st.barracks_count[tier];
        if (count <= 0) continue;
        posts += (int64_t)count * (int64_t)barracks_capacity_for_tier(_catalog, tier);
    }
    if (posts > (int64_t)MILITARY_MAX_ARMIES * 256) posts = (int64_t)MILITARY_MAX_ARMIES * 256;
    return (int32_t)posts;
}

int64_t MilitaryCore::present_for_cell(int32_t cell) const {
    if (cell < 0 || cell >= _terrain.cell_count) return 0;
    int64_t present = 0;
    int32_t slot = _cell_head.empty() ? -1 : _cell_head[(size_t)cell];
    while (slot >= 0) {
        present += _armies.cached_headcount[(size_t)slot];
        slot = _armies.next_in_cell[(size_t)slot];
    }
    military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell,
                          [&](int32_t i) { present += _lots.count[(size_t)i]; });
    return present;
}

bool MilitaryCore::at_war(int32_t slot_a, int32_t slot_b) const {
    return war_between(slot_a, slot_b) >= 0;
}

int32_t MilitaryCore::war_between(int32_t slot_a, int32_t slot_b) const {
    if (slot_a < 0 || slot_b < 0 || slot_a == slot_b) return -1;
    for (const MilitaryWar &w : _wars) {
        if (!w.active) continue;
        if ((w.attacker_slot == slot_a && w.defender_slot == slot_b) ||
            (w.attacker_slot == slot_b && w.defender_slot == slot_a)) {
            return w.id;
        }
    }
    return -1;
}

// ============================================================== force targets

void MilitaryCore::update_force_targets(const MilitaryWorldDigest &digest) {
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        const int64_t heads = country_soldiers(s);
        const int64_t living = slot < digest.country_soldier_living_cost.size()
                                   ? digest.country_soldier_living_cost[slot]
                                   : 0;
        const int64_t wage = p.wage_mode == 1
                                 ? p.wage_absolute
                                 : mul_div(living, stat_q16(digest, s, MSTAT_WAGE), MILITARY_Q16);
        int64_t upkeep_total = 0;
        for (const MilitaryCellState &st : _cell_states) {
            for (int32_t tier = 0; tier < 8; ++tier) {
                if (st.barracks_count[tier] <= 0) continue;
                for (const MilitaryStateBuilding &b : _catalog.state_buildings) {
                    if (b.role == (uint8_t)MILITARY_STATE_BARRACKS && (int32_t)b.tier == tier) {
                        upkeep_total += (int64_t)st.barracks_count[tier] * b.upkeep_per_day;
                        break;
                    }
                }
            }
        }
        const int64_t upkeep_per_head = heads > 0 ? upkeep_total / heads : 0;
        const int64_t procurement_per_head = p.spend_procurement_30 > 0
                                                 ? (p.spend_procurement_30 / 30) / std::max<int64_t>(heads, 1)
                                                 : 0;
        p.per_soldier_cost = std::max<int64_t>(1, wage + procurement_per_head + upkeep_per_head);

        int64_t target = p.target_mode == 1 ? p.target_value / p.per_soldier_cost : p.target_value;
        if (target < 0) target = 0;
        // +/-2% hysteresis for BUDGET mode; HEADCOUNT mode is a direct setting.
        if (p.target_mode == 1) {
            const int64_t old = p.effective_target;
            if (old <= 0 || target * 100 < old * 98 || target * 100 > old * 102) {
                p.effective_target = target;
            }
        } else {
            p.effective_target = target;
        }
    }
}

// ======================================================== roster reconcile

// Design 5.5: Economy owns natural deaths. Every day the Military roster must
// equal the cell's committed soldier cohort; when Economy has fewer people than
// the lots claim (deaths, or people leaving the soldier lane), the excess is
// trimmed proportionally and booked as non-combat attrition. Economy is never
// written here, so the reconcile is a pure read-and-trim.
void MilitaryCore::reconcile_soldier_roster(const MilitaryWorldDigest &digest) {
    if (digest.cell_soldiers.size() != (size_t)_terrain.cell_count) return;
    static thread_local std::vector<int32_t> rows;
    rows.clear();
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] == 0) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        rows.push_back((int32_t)i);
    }
    if (rows.empty()) return;
    std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
        if (_lots.location[a] != _lots.location[b]) return _lots.location[a] < _lots.location[b];
        return a < b;
    });
    size_t begin = 0;
    while (begin < rows.size()) {
        const int32_t cell = _lots.location[(size_t)rows[begin]];
        size_t end = begin;
        int64_t total = 0;
        while (end < rows.size() && _lots.location[(size_t)rows[end]] == cell) {
            total += std::max<int64_t>(0, _lots.count[(size_t)rows[end]]);
            ++end;
        }
        // A transiently unavailable digest (worker read view busy) reports zero
        // population for every cell. Treating that as "everyone died" wipes the
        // roster, so a cell only participates when the digest actually carries
        // population for it.
        const bool digest_has_cell =
            (size_t)cell < digest.cell_population.size() &&
            digest.cell_population[(size_t)cell] > 0;
        const int64_t economy_heads = digest_has_cell && (size_t)cell < digest.cell_soldiers.size()
            ? std::max<int64_t>(0, digest.cell_soldiers[(size_t)cell]) : 0;
        // Heads already enlisted but not yet converted are pre-applied to the
        // roster and still missing from the committed cohort: trimming them here
        // re-opens the quota the next sample and converts the same people twice
        // (economy 19 soldiers against 6 in the roster).
        const MilitaryCellState *cell_row = cell_state(cell, false);
        const int64_t in_flight = cell_row != nullptr
            ? std::max<int64_t>(0, cell_row->pending_enlist) : 0;
        const int64_t allowed = economy_heads + in_flight;
        if (total > allowed) {
            const int64_t removed_total = total - allowed;
            int64_t excess = removed_total;
            // Proportional largest-remainder trim in ascending lot order.
            for (size_t k = begin; k < end && excess > 0; ++k) {
                const int32_t lot = rows[k];
                const int64_t share =
                    std::max<int64_t>(0, mul_div(_lots.count[(size_t)lot], removed_total, total));
                const int64_t take = std::min(share, std::min<int64_t>(_lots.count[(size_t)lot], excess));
                if (take <= 0) continue;
                _lots.count[(size_t)lot] -= take;
                excess -= take;
            }
            // Any remainder falls on the last lots, one head each.
            for (size_t k = begin; k < end && excess > 0; ++k) {
                const int32_t lot = rows[k];
                if (_lots.count[(size_t)lot] <= 0) continue;
                _lots.count[(size_t)lot] -= 1;
                --excess;
            }
            for (size_t k = begin; k < end; ++k) {
                const int32_t lot = rows[k];
                if (_lots.count[(size_t)lot] > 0) continue;
                _lots.active[(size_t)lot] = 0;
                _lots.free_list.push_back(lot);
            }
        }
        begin = end;
    }
}

// ================================================== army personnel lane
//
// Army-personnel contract §2.1. Military books the heads the moment the intent
// is emitted (same pre-apply rule as ENLIST/DISCHARGE) and never writes Economy;
// the lane row itself is Economy's, keyed by army handle. The bridge translates
// these rows into opcodes 30/31/32/33 and reads `military_army_population(handle)`
// back the next day to trim lots Economy no longer holds people for.

void MilitaryCore::emit_army_lane_intent(uint16_t kind, int32_t army_slot, int32_t cell,
                                         int64_t count, uint64_t peer_handle) {
    if (count <= 0) return;
    if (!army_alive(_armies, army_slot)) return;
    if (_army_lane_pending.size() < _armies.active.size())
        _army_lane_pending.resize(_armies.active.size(), 0);
    MilitaryIntent in;
    in.kind = kind;
    in.cell = cell;
    in.count = count;
    // `source_id` is the receipt's key and always names the formation whose book
    // is short: the formation being (re)filled here. For a lane -> lane move that
    // is the DESTINATION — its lots already carry the heads, its lane only catches
    // up when the command lands, so its in-flight ceiling stays raised until the
    // receipt. The bridge translates 32/33 from country_a/country_b, never from
    // source_id, so the receipt key is free to be the destination.
    in.source_id = army_handle(army_slot);
    if (peer_handle != 0) {
        // MERGE_LANES / SPLIT_LANES: country_a = source lane, country_b = the
        // formation whose lane grows.
        in.country_a = peer_handle;
        in.country_b = army_handle(army_slot);
    } else {
        in.country_a = country_handle_for_slot(_armies.owner_slot[(size_t)army_slot]);
    }
    _lane_intents.push_back(in);
    // Only an inbound move leaves heads in Economy's future: a DISEMBARK removes
    // them from the lane, so it must not widen the trim ceiling.
    if (kind != MILITARY_INTENT_ARMY_DISEMBARK)
        _army_lane_pending[(size_t)army_slot] += count;
}

int64_t MilitaryCore::army_lane_pending(int32_t army_slot) const {
    if (army_slot < 0 || (size_t)army_slot >= _army_lane_pending.size()) return 0;
    return std::max<int64_t>(0, _army_lane_pending[(size_t)army_slot]);
}

void MilitaryCore::emit_army_personnel_loss(int32_t army_slot, int32_t cell,
                                            int64_t lane_count, int64_t dead_count,
                                            std::vector<MilitaryIntent> &out) {
    if (!army_alive(_armies, army_slot)) return;
    if (cell < 0 || cell >= _terrain.cell_count) return;
    const uint64_t handle = army_handle(army_slot);
    const uint64_t owner_handle =
        country_handle_for_slot(_armies.owner_slot[(size_t)army_slot]);
    if (lane_count > 0) {
        // The dead are in the formation's lane, not in the home cell's soldier
        // cohort: hand the heads back to the cell first (opcode 31), then let the
        // casualty row below kill them there. Economy clamps both to what it
        // actually holds, so the pair cannot invent or destroy a head.
        MilitaryIntent release;
        release.kind = MILITARY_INTENT_ARMY_DISEMBARK;
        release.cell = cell;
        release.country_a = owner_handle;
        release.count = lane_count;
        release.source_id = handle;
        out.push_back(release);
        ++_report.intents_emitted;
    }
    if (dead_count > 0) {
        MilitaryIntent dead;
        dead.kind = MILITARY_INTENT_CASUALTY;
        dead.cell = cell;
        dead.country_a = owner_handle;
        dead.count = dead_count;
        dead.source_id = handle;
        out.push_back(dead);
        ++_report.intents_emitted;
    }
}

void MilitaryCore::trim_army_lots(int32_t army_slot, int64_t allowed) {
    if (army_slot < 0) return;
    if (allowed < 0) allowed = 0;
    static thread_local std::vector<int32_t> rows;
    rows.clear();
    int64_t total = 0;
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] == 0 || _lots.count[i] <= 0) continue;
        if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (_lots.location[i] != army_slot) continue;
        rows.push_back((int32_t)i);
        total += _lots.count[i];
    }
    if (total <= allowed) return;
    const int64_t removed_total = total - allowed;
    int64_t excess = removed_total;
    // Proportional largest-remainder trim in ascending lot order (same rule as
    // reconcile_soldier_roster, but scoped to one formation).
    for (size_t k = 0; k < rows.size() && excess > 0; ++k) {
        const int32_t lot = rows[k];
        const int64_t share =
            std::max<int64_t>(0, mul_div(_lots.count[(size_t)lot], removed_total, total));
        const int64_t take = std::min(share, std::min<int64_t>(_lots.count[(size_t)lot], excess));
        if (take <= 0) continue;
        _lots.count[(size_t)lot] -= take;
        excess -= take;
    }
    for (size_t k = 0; k < rows.size() && excess > 0; ++k) {
        const int32_t lot = rows[k];
        if (_lots.count[(size_t)lot] <= 0) continue;
        _lots.count[(size_t)lot] -= 1;
        --excess;
    }
    for (size_t k = 0; k < rows.size(); ++k) {
        const int32_t lot = rows[k];
        if (_lots.count[(size_t)lot] > 0) continue;
        _lots.active[(size_t)lot] = 0;
        _lots.free_list.push_back(lot);
    }
}

void MilitaryCore::reconcile_receipts(const std::vector<MilitaryIntentReceipt> &receipts) {
    for (const MilitaryIntentReceipt &r : receipts) {
        // Army personnel lane rows (contract §2.1). A row is bookkeeping only:
        // the heads were booked by Military when the intent was emitted and
        // Economy owns the lane. Whatever the outcome, the formation no longer has
        // a lane move in flight, so a lane reconcile may trim it again from the
        // next day on. `source_id` names the formation whose in-flight ceiling has
        // to be released — the one whose lane grew (the destination for
        // MERGE_LANES / SPLIT_LANES), which is who `emit_army_lane_intent` stamps
        // on the row; a merged-away formation never resolves and needs nothing
        // (destroy_army already cleared its bookkeeping).
        if (r.kind == MILITARY_INTENT_ARMY_EMBARK ||
            r.kind == MILITARY_INTENT_ARMY_DISEMBARK ||
            r.kind == MILITARY_INTENT_ARMY_MERGE_LANES ||
            r.kind == MILITARY_INTENT_ARMY_SPLIT_LANES) {
            int32_t lane_army = -1;
            if (resolve_army(r.source_id, lane_army) &&
                (size_t)lane_army < _army_lane_pending.size())
                _army_lane_pending[(size_t)lane_army] = 0;
            continue;
        }
        // Army pay (army-pay contract §2, opcode 34). The heads and the lane cash
        // are Economy's, and the lot book already holds them, so there is nothing
        // to reconcile a second time: the receipt only tells Military how much of
        // the payroll the treasury could actually fund. A failed row means the
        // lane was not credited at all, which is the pay-ratio statistic's
        // business (already booked from `planned` when the intent was emitted),
        // not a head-count correction.
        if (r.kind == MILITARY_INTENT_ARMY_PAY) continue;

        // DISCHARGE pre-applies to the garrison lots when the intent is emitted
        // (run_recruitment / attrition); the receipt never removes heads a second
        // time. Only the shortfall the old owner could not move is put back, so
        // the Military roster stays equal to the Economy soldier cohort.
        if (r.kind == MILITARY_INTENT_DISCHARGE) {
            const int64_t requested = (int64_t)((r.source_id >> 48) & 0xFFFFull);
            const int32_t slot = (int32_t)((r.source_id >> 32) & 0xFFFFull) - 1;
            const int64_t committed = r.ok
                ? std::clamp<int64_t>(r.committed_count, 0, requested) : 0;
            const int64_t shortfall = requested - committed;
            if (slot >= 0 && shortfall > 0 && r.cell >= 0 && r.cell < _terrain.cell_count) {
                const int16_t militia = (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0);
                const int32_t lot = lot_find_or_create((uint8_t)MILITARY_LOT_GARRISON, r.cell, slot, militia, 256);
                if (lot >= 0) _lots.count[(size_t)lot] += shortfall;
            }
            continue;
        }
        if (!r.ok || r.committed_count == 0) continue;
        switch (r.kind) {
            case MILITARY_INTENT_ENLIST:
            case MILITARY_INTENT_LEVY: {
                if (r.cell < 0 || r.cell >= _terrain.cell_count) break;
                // The roster was pre-applied when the intent was emitted (same
                // contract as DISCHARGE). The receipt only settles what Economy
                // actually moved: heads it could not move come back off the lot,
                // so the roster never runs ahead of the real cohort.
                const int64_t requested = (int64_t)((r.source_id >> 48) & 0xFFFFull);
                const int64_t committed = r.ok
                    ? std::clamp<int64_t>(r.committed_count, 0, requested) : 0;
                const int64_t shortfall = requested > 0 ? requested - committed : 0;
                int32_t slot = (int32_t)((r.source_id >> 32) & 0xFFFFull) - 1;
                if (slot < 0 && (size_t)r.cell < _last_digest.cell_owner_slot.size())
                    slot = _last_digest.cell_owner_slot[(size_t)r.cell];
                if (slot < 0) slot = 0;
                if (shortfall > 0) {
                    const int16_t militia =
                        (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0);
                    const int32_t lot = lot_find_or_create(
                        (uint8_t)MILITARY_LOT_GARRISON, r.cell, slot, militia, 256);
                    if (lot >= 0)
                        _lots.count[(size_t)lot] = std::max<int64_t>(
                            0, _lots.count[(size_t)lot] - shortfall);
                }
                if (MilitaryCellState *st = cell_state(r.cell, false)) {
                    st->pending_enlist = std::max<int64_t>(0, st->pending_enlist - requested);
                }
                _report.reconcile_delta += committed;
                break;
            }
            case MILITARY_INTENT_CASUALTY: {
                if (r.cell < 0 || r.cell >= _terrain.cell_count) break;
                // Casualties are booked on military lots when the intent is
                // emitted, and an army lot and a garrison lot are different
                // places: only the heads Economy could not remove (a shortfall,
                // or a fully failed row) belong back on the home garrison. The
                // emitter never packs the request into `source_id`, so the
                // requested count is the one the bridge translated. A full
                // refund therefore needs the bridge to report the shortfall;
                // with committed heads it adds back exactly what Economy kept.
                //
                // The roster total is what the report counts, so the refund is
                // applied to the garrison lot the receipt names.
                const int64_t committed = r.ok ? std::max<int64_t>(0, r.committed_count) : 0;
                if (committed <= 0) break;
                _report.reconcile_delta -= committed;
                break;
            }
            default:
                break;
        }
    }
}

// ============================================================== recruitment

namespace {

struct QuotaCell {
    int32_t cell = -1;
    int64_t open = 0;
    int64_t share = 0;
};

} // namespace

void MilitaryCore::run_recruitment(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out) {
    const bool sampling = (_last_day >= 0) && (_last_day % kRecruitCheckPeriod) == 0;
    if (!sampling) return;
    const int32_t cells = _terrain.cell_count;
    // `pending_enlist` is counted from the moment an ENLIST/LEVY intent is emitted
    // until its receipt arrives. A row can leave the bridge without a successful
    // receipt (timeout, refused submit), and the receipt for a partially applied
    // row never carries the shortfall, so a counter that is only decremented by
    // `committed_count` would keep a cell's posts occupied forever. The pending
    // total therefore lives only inside one receipt window: the outbound count of
    // the previous sample is replaced by the difference the receipts actually
    // applied (reconcile_receipts tracked it in `_report.reconcile_delta`).
    int64_t pending_applied = _report.reconcile_delta;
    for (MilitaryCellState &st : _cell_states) {
        if (st.pending_enlist <= 0) continue;
        if (pending_applied <= 0) {
            st.pending_enlist = 0;
            continue;
        }
        const int64_t keep = std::min(st.pending_enlist, pending_applied);
        st.pending_enlist -= keep;
        pending_applied -= keep;
    }
    static thread_local std::vector<QuotaCell> quota_rows;
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        const uint64_t handle = _policy_handle[slot];
        if (handle == 0) continue;
        quota_rows.clear();
        int64_t open_sum = 0;
        // Only cells with a state row can hold posts; _cell_states is sorted by
        // cell, so this visits the same cells in the same order as a full scan.
        for (size_t sti = 0; sti < _cell_states.size(); ++sti) {
            MilitaryCellState *st = &_cell_states[sti];
            const int32_t cell = st->cell;
            if (cell < 0 || cell >= cells) continue;
            if ((size_t)cell >= digest.cell_owner_slot.size()) break;
            if (digest.cell_owner_slot[(size_t)cell] != s) continue;
            const int32_t ctrl = controller_of(cell);
            if (ctrl >= 0 && ctrl != s) continue;
            if (st->paused) continue;
            const int64_t posts = posts_for_cell(cell, s);
            if (posts <= 0) continue;
            const int64_t open = std::max<int64_t>(0, posts - present_for_cell(cell) - st->pending_enlist);
            if (open <= 0) continue;
            QuotaCell q;
            q.cell = cell;
            q.open = open;
            quota_rows.push_back(q);
            open_sum += open;
        }
        // `plan` ignores the cell-level `pending_enlist` (already replaced by what
        // the receipts applied); `open` above keeps it so a cell never overshoots
        // its posts while a row is still in flight.
        const int64_t deficit = p.effective_target - country_soldiers(s);
        int64_t plan = 0;
        if (deficit > 0) {
            plan = std::min(deficit, open_sum);
            int64_t assigned = 0;
            for (QuotaCell &q : quota_rows) {
                q.share = mul_div(plan, q.open, open_sum);
                assigned += q.share;
            }
            int64_t rest = plan - assigned;
            for (size_t i = 0; i < quota_rows.size() && rest > 0; ++i) {
                if (quota_rows[i].share < quota_rows[i].open) {
                    quota_rows[i].share += 1;
                    --rest;
                }
            }
        }
        // Re-freeze the per-cell quota for this sample period.
        for (QuotaCell &q : quota_rows) {
            MilitaryCellState *st = cell_state(q.cell, true);
            if (st) st->quota = std::min(q.open, q.share);
        }
        // No early `continue` here: an over-target country still has to reach
        // the auto-discharge / desertion block below (it used to be skipped
        // whenever there was no open post or nothing to recruit).
        const int64_t levy_cap_bp = clamp32(stat_bp(digest, s, MSTAT_LEVY_RATE), 0, 10000);
        for (const QuotaCell &q : quota_rows) {
            if (plan <= 0) break;
            const int64_t quota = plan <= 0 ? 0 : q.share;
            if (quota <= 0) continue;
            MilitaryCellState *st = cell_state(q.cell, true);
            if (!st) continue;
            const int64_t pop = digest.cell_population[(size_t)q.cell];
            const int64_t unemployed = digest.cell_unemployed[(size_t)q.cell];
            const int64_t room = std::max<int64_t>(0, pop - kMinCellPopulationAfterLevy);
            const int64_t volunteers = std::min({quota, std::max<int64_t>(0, unemployed), room});
            if (volunteers > 0) {
                MilitaryIntent in;
                in.kind = MILITARY_INTENT_ENLIST;
                in.cell = q.cell;
                in.country_a = handle;
                in.count = volunteers;
                // Pre-apply the roster exactly like DISCHARGE does and pack the
                // request into source_id: booking only on the receipt left the
                // roster a day behind, so the quota kept recruiting past the
                // posts (economy 16 soldiers against 12 posts).
                in.source_id = military_discharge_source(q.cell, s, volunteers);
                out.push_back(in);
                st->pending_enlist += volunteers;
                const int32_t lot = lot_find_or_create(
                    (uint8_t)MILITARY_LOT_GARRISON, q.cell, s,
                    (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0), 256);
                if (lot >= 0) _lots.count[(size_t)lot] += volunteers;
            }
            // Design 5.4: when the unemployed pool cannot fill the quota the levy
            // draws from the cell's non-merchant, non-owner employee cohorts. The
            // bridge translates that as a CHANGE_SIGNATURE from any non-merchant
            // profession cohort of the cell, so the levy is bounded only by the
            // people that may leave, never by `unemployed`.
            const int64_t missing = quota - volunteers;
            if (missing > 0 && p.levy_enabled) {
                const int64_t levy_cap = std::max<int64_t>(1, mul_div(pop, levy_cap_bp, 10000));
                const int64_t levy = std::min({missing, levy_cap, std::max<int64_t>(0, room - volunteers)});
                if (levy > 0) {
                    MilitaryIntent in;
                    in.kind = MILITARY_INTENT_LEVY;
                    in.cell = q.cell;
                    in.country_a = handle;
                    in.count = levy;
                    in.source_id = military_discharge_source(q.cell, s, levy);
                    out.push_back(in);
                    st->pending_enlist += levy;
                    const int32_t lot = lot_find_or_create(
                        (uint8_t)MILITARY_LOT_GARRISON, q.cell, s,
                        (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0), 256);
                    if (lot >= 0) _lots.count[(size_t)lot] += levy;
                    MilitaryEvent ev;
                    ev.day = _last_day;
                    ev.type = MILITARY_EVENT_LEVY_APPLIED;
                    ev.cell = q.cell;
                    ev.i0 = (uint64_t)s;
                    ev.i1 = handle;
                    ev.value = levy;
                    push_event(ev);
                }
            }
        }

        // ---- auto discharge (5.5) and desertion, same sample day.
        const int64_t target = p.effective_target;
        const int64_t pay = p.pay_ratio_30_q16;
        int64_t over = country_soldiers(s) - target;
        const bool discharge = over > 0 && p.auto_discharge;
        const bool desert = pay < kPayRatioDesertThreshold;
        if (!discharge && !desert) continue;
        static thread_local std::vector<int32_t> cells_with_soldiers;
        cells_with_soldiers.clear();
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i]) continue;
            if (_lots.country_slot[i] != s) continue;
            if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
            cells_with_soldiers.push_back(_lots.location[i]);
        }
        std::sort(cells_with_soldiers.begin(), cells_with_soldiers.end());
        cells_with_soldiers.erase(std::unique(cells_with_soldiers.begin(), cells_with_soldiers.end()),
                                  cells_with_soldiers.end());
        // DISCHARGE pre-applies to the lots; the receipt reconciles a shortfall
        // (reconcile_receipts), so source_id carries cell, slot and request.
        auto emit_discharge = [&](int32_t cell, int64_t done) {
            MilitaryIntent in;
            in.kind = MILITARY_INTENT_DISCHARGE;
            in.cell = cell;
            in.country_a = handle;
            in.count = done;
            in.source_id = military_discharge_source(cell, s, done);
            out.push_back(in);
        };
        for (int32_t cell : cells_with_soldiers) {
            if (!discharge) break;
            if (cell < 0 || cell >= cells) continue;
            if (over <= 0) break;
            // Order: militia -> rear garrison -> obsolete; approximated by
            // "lowest unit id first", which puts the militia (id 0) first.
            // source_id packs the request in 16 bits, so a cell never asks for
            // more than MILITARY_DISCHARGE_CHUNK (a truncated request would make
            // the receipt refund the wrong number of heads).
            const int64_t take = std::min<int64_t>(over, MILITARY_DISCHARGE_CHUNK);
            const int64_t done = lot_remove_casualties((uint8_t)MILITARY_LOT_GARRISON, cell, take);
            if (done > 0) {
                over -= done;
                emit_discharge(cell, done);
            }
        }
        if (desert) {
            const uint64_t key = mix_key(mix_key(0x4445534552ull, (uint64_t)s), (uint64_t)_last_day);
            for (int32_t cell : cells_with_soldiers) {
                if (cell < 0 || cell >= cells) continue;
                int64_t garrison = 0;
                military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell, [&](int32_t i) {
                    if (_lots.country_slot[(size_t)i] == s) garrison += _lots.count[(size_t)i];
                });
                if (garrison <= 0) continue;
                // Daily 0.5% * (1 - pay_ratio), deterministic in (seed, cell, day).
                const int64_t gap_q16 = MILITARY_Q16 - pay;
                int64_t want = mul_div(garrison * 50, gap_q16, MILITARY_Q16 * 10000);
                if (want <= 0) {
                    const int64_t roll = rng_q16(_seed, mix_key(key, (uint64_t)cell), _last_day);
                    if (roll * 10000 < mul_div(50 * 10000, gap_q16, MILITARY_Q16)) want = 1;
                }
                want = std::min<int64_t>(want, MILITARY_DISCHARGE_CHUNK);
                if (want > 0) {
                    const int64_t done = lot_remove_casualties((uint8_t)MILITARY_LOT_GARRISON, cell, want);
                    if (done > 0) emit_discharge(cell, done);
                }
            }
        }
    }
}
// ============================================================== training

namespace {

int32_t cell_training_speed_q16(const MilitaryCatalog &c, const MilitaryCellState *st) {
    if (!st || st->college_tier < 0) return MILITARY_Q16;
    int32_t speed = 0;
    if (!barracks_speed_index_matches(c, st->college_tier, &speed)) return MILITARY_Q16;
    if (st->disrepair) speed = MILITARY_Q16 + (speed - MILITARY_Q16) / 2;
    return speed > 0 ? speed : MILITARY_Q16;
}

int64_t garrison_heads_for_unit(const MilitaryLotStore &lots, int32_t cell, int32_t country_slot,
                                int16_t unit) {
    int64_t total = 0;
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i]) continue;
        if (lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (lots.location[i] != cell) continue;
        if (country_slot >= 0 && lots.country_slot[i] != country_slot) continue;
        if (unit >= 0 && lots.unit_type[i] != unit) continue;
        total += lots.count[i];
    }
    return total;
}

// Moves heads between garrison lots in one cell, preserving total heads.
int64_t transfer_garrison(MilitaryCore &core, int32_t cell, int32_t from_country, int32_t to_country,
                          int16_t from_unit, int16_t to_unit, int16_t quality_q8, int64_t count) {
    if (count <= 0) return 0;
    int64_t left = count;
    for (size_t i = 0; i < core._lots.active.size() && left > 0; ++i) {
        if (!core._lots.active[i]) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (core._lots.location[i] != cell) continue;
        if (core._lots.country_slot[i] != from_country) continue;
        if (core._lots.unit_type[i] != from_unit) continue;
        const int64_t take = std::min(left, core._lots.count[i]);
        if (take <= 0) continue;
        core._lots.count[i] -= take;
        const int32_t lot = core.lot_find_or_create((uint8_t)MILITARY_LOT_GARRISON, cell, to_country,
                                                    to_unit, quality_q8);
        if (lot < 0) {
            core._lots.count[i] += take;
            break;
        }
        core._lots.count[(size_t)lot] += take;
        left -= take;
    }
    return count - left;
}

} // namespace

void MilitaryCore::run_training(const MilitaryWorldDigest &digest) {
    // 1. Advance in-progress orders. A2's procurement sets equipment_ready once
    // the equipment is in place; until then the order waits (and is the demand
    // signal A2 reads from _training).
    for (size_t i = 0; i < _training.size(); ++i) {
        MilitaryTrainingOrder &o = _training[i];
        if (o.count <= 0 || o.days_done >= o.days_total) continue;
        if (!o.equipment_ready) continue;
        ++o.days_done;
        if (o.days_done < o.days_total) continue;
        // v3: the garrison lot kept its *source* unit type while training, so
        // an unequipped order can never fight as the target unit. Only now -
        // every equipment slot delivered and all training days elapsed - do the
        // heads become the target unit, at the quality actually bought.
        const int16_t delivered_q8 = o.delivered_quality_q8 > 0
            ? o.delivered_quality_q8 : o.quality_q8;
        if (o.from_unit >= 0) {
            transfer_garrison(*this, o.cell, o.country_slot, o.country_slot,
                              o.from_unit, o.to_unit, delivered_q8, o.count);
        }
        o.count = 0;
    }
    // 2. Compact finished orders.
    {
        size_t w = 0;
        for (size_t r = 0; r < _training.size(); ++r) {
            if (_training[r].count <= 0) continue;
            if (w != r) _training[w] = _training[r];
            ++w;
        }
        _training.resize(w);
    }
    const int32_t units = (int32_t)_catalog.units.size();
    if (units <= 0 || _catalog.militia_unit < 0) return;
    static thread_local std::vector<int64_t> gap;
    static thread_local std::vector<int64_t> existing;

    // 3. Automatic training / retraining / re-equip (5.6).
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        if (!p.auto_retrain) continue;
        if (p.config_share_bp.size() < (size_t)units) p.config_share_bp.resize((size_t)units, 0);
        int64_t share_sum = 0;
        for (int32_t u = 0; u < units; ++u) {
            int32_t bp = p.config_share_bp[(size_t)u];
            if (bp < 0) bp = 0;
            if (bp > 10000) bp = 10000;
            p.config_share_bp[(size_t)u] = bp;
            if (u == _catalog.militia_unit) continue;
            share_sum += bp;
        }
        if (share_sum <= 0) continue;
        const int64_t target = p.effective_target;
        if (target <= 0) continue;
        gap.assign((size_t)units, 0);
        existing.assign((size_t)units, 0);
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i]) continue;
            if (_lots.country_slot[i] != s) continue;
            const int32_t u = _lots.unit_type[i];
            if (u >= 0 && u < units) existing[(size_t)u] += _lots.count[i];
        }
        for (const MilitaryTrainingOrder &o : _training) {
            if (o.country_slot != s) continue;
            if (o.to_unit >= 0 && o.to_unit < units) existing[(size_t)o.to_unit] += o.count;
        }
        for (int32_t u = 0; u < units; ++u) {
            if (u == _catalog.militia_unit) continue;
            const int64_t want = mul_div(p.config_share_bp[(size_t)u], target, 10000);
            gap[(size_t)u] = want - existing[(size_t)u];
        }
        const int16_t militia = (int16_t)_catalog.militia_unit;
        for (MilitaryCellState &st : _cell_states) {
            const int32_t cell = st.cell;
            if (cell < 0 || cell >= _terrain.cell_count) continue;
            if ((size_t)cell >= digest.cell_owner_slot.size()) continue;
            if (digest.cell_owner_slot[(size_t)cell] != s) continue;
            const int32_t ctrl = controller_of(cell);
            if (ctrl >= 0 && ctrl != s) continue;
            if (st.paused) continue;
            const int64_t posts = posts_for_cell(cell, s);
            if (posts <= 0) continue;
            int64_t in_training = 0;
            for (const MilitaryTrainingOrder &o : _training) {
                if (o.cell == cell) in_training += o.count;
            }
            int64_t capacity = posts - in_training;
            if (capacity <= 0) continue;
            // v3: heads stay in the militia lot until the order completes, so
            // reserve those already committed to in-flight orders in this cell.
            const int64_t militia_heads = std::max<int64_t>(0,
                garrison_heads_for_unit(_lots, cell, s, militia) - in_training);
            if (militia_heads <= 0) continue;
            const int32_t speed = cell_training_speed_q16(_catalog, &st);
            const int64_t train_stat = stat_q16(digest, s, MSTAT_TRAINING_TIME);
            int32_t orders = 0;
            // Upgrade path A: militia -> configured unit, biggest gap first.
            while (capacity > 0 && orders < kMaxOrdersPerCellPerDay) {
                int32_t best = -1;
                int64_t best_gap = 0;
                for (int32_t u = 0; u < units; ++u) {
                    if (u == _catalog.militia_unit) continue;
                    if (!unlocked(digest, s, _catalog.units[(size_t)u].unlock_bit)) continue;
                    if (gap[(size_t)u] > best_gap) {
                        best_gap = gap[(size_t)u];
                        best = u;
                    }
                }
                if (best < 0) break;
                const MilitaryUnitType &ut = _catalog.units[(size_t)best];
                const int64_t count = std::min({capacity, militia_heads, best_gap});
                if (count <= 0) break;
                const int64_t kind = kind_factor_q16((uint8_t)MILITARY_CLASS_LINE, ut.unit_class, false);
                int64_t days = ceil_div_pos((int64_t)ut.training_days * kind, MILITARY_Q16);
                days = std::max<int64_t>(1, mul_div(days, train_stat, speed));
                MilitaryTrainingOrder o;
                o.id = _next_id++;
                o.country_slot = s;
                o.cell = cell;
                o.from_unit = militia;
                o.to_unit = (int16_t)best;
                o.count = count;
                o.days_total = (int32_t)std::min<int64_t>(days, 100000);
                o.days_done = 0;
                o.equipment_ready = 0;   // A2 fills this from procurement
                o.manual = 0;
                o.quality_q8 = (int16_t)(p.quality_policy == 0 ? 5 * 256 : 1 * 256);
                _training.push_back(o);
                gap[(size_t)best] -= count;
                capacity -= count;
                ++orders;
            }
            // Upgrade path B (retrain): a trained unit whose share is now the
            // largest gap retrains from an over-represented unit of the same
            // category where that is cheaper than training militia.
            for (int32_t u = 0; u < units && orders < kMaxOrdersPerCellPerDay; ++u) {
                if (u == _catalog.militia_unit) continue;
                if (gap[(size_t)u] <= 0) continue;
                if (!unlocked(digest, s, _catalog.units[(size_t)u].unlock_bit)) continue;
                int32_t source = -1;
                int64_t source_heads = 0;
                for (int32_t v = 0; v < units; ++v) {
                    if (v == _catalog.militia_unit || v == u) continue;
                    if (gap[(size_t)v] >= 0) continue;
                    const int64_t heads = garrison_heads_for_unit(_lots, cell, s, (int16_t)v);
                    if (heads > source_heads) {
                        source_heads = heads;
                        source = v;
                    }
                }
                if (source < 0) break;
                source_heads = std::max<int64_t>(0, source_heads - in_training);
                if (source_heads <= 0) break;
                const MilitaryUnitType &ut = _catalog.units[(size_t)u];
                const int64_t count = std::min({capacity, source_heads, gap[(size_t)u]});
                if (count <= 0) break;
                const int64_t kind = kind_factor_q16(_catalog.units[(size_t)source].unit_class,
                                                     ut.unit_class, false);
                int64_t days = ceil_div_pos((int64_t)ut.training_days * kind, MILITARY_Q16);
                days = std::max<int64_t>(1, mul_div(days, train_stat, speed));
                MilitaryTrainingOrder o;
                o.id = _next_id++;
                o.country_slot = s;
                o.cell = cell;
                o.from_unit = (int16_t)source;
                o.to_unit = (int16_t)u;
                o.count = count;
                o.days_total = (int32_t)std::min<int64_t>(days, 100000);
                o.equipment_ready = 0;
                o.manual = 0;
                o.quality_q8 = (int16_t)(p.quality_policy == 0 ? 5 * 256 : 1 * 256);
                _training.push_back(o);
                gap[(size_t)u] -= count;
                gap[(size_t)source] += count;
                capacity -= count;
                ++orders;
                break;
            }
        }
        // Re-equip (5.6, same-unit re-equip): garrison lots of a configured unit whose
        // quality is below the achievable maximum queue a 0.25? order.
        if (p.quality_policy != 0) continue;
        const int32_t max_q8 = 5 * 256;
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i]) continue;
            if (_lots.country_slot[i] != s) continue;
            if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
            if (_lots.equip_quality_q8[i] + 128 >= max_q8) continue;
            const int32_t u = _lots.unit_type[i];
            if (u < 0 || u >= units) continue;
            if (u == _catalog.militia_unit) continue;
            if (_catalog.units[(size_t)u].slot_count <= 0) continue;
            const int32_t cell = _lots.location[i];
            const MilitaryCellState *st = cell_state(cell, false);
            if (!st || st->paused) continue;
            if (cell < 0 || (size_t)cell >= digest.cell_owner_slot.size()) continue;
            if (digest.cell_owner_slot[(size_t)cell] != s) continue;
            if ((_last_day + cell) % 7 != 0) continue;   // spread re-equip work over the week
            const int64_t count = std::min<int64_t>(_lots.count[i], 256);
            if (count <= 0) continue;
            const int32_t speed = cell_training_speed_q16(_catalog, st);
            const int64_t train_stat = stat_q16(digest, s, MSTAT_TRAINING_TIME);
            int64_t days = ceil_div_pos((int64_t)_catalog.units[(size_t)u].training_days * (MILITARY_Q16 / 4),
                                        MILITARY_Q16);
            days = std::max<int64_t>(1, mul_div(days, train_stat, speed));
            MilitaryTrainingOrder o;
            o.id = _next_id++;
            o.country_slot = s;
            o.cell = cell;
            o.from_unit = (int16_t)u;
            o.to_unit = (int16_t)u;
            o.count = count;
            o.days_total = (int32_t)std::min<int64_t>(days, 100000);
            o.equipment_ready = 0;
            o.manual = 0;
            o.quality_q8 = (int16_t)max_q8;
            _training.push_back(o);
            break;
        }
    }
}

// ============================================================== reinforcement

void MilitaryCore::run_reinforcement(const MilitaryWorldDigest &digest) {
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        if (!_armies.reinforce_enabled[(size_t)slot]) continue;
        const int32_t owner = _armies.owner_slot[(size_t)slot];
        if (owner < 0) continue;
        const int32_t cell = _armies.cell[(size_t)slot];
        if (cell < 0 || cell >= _terrain.cell_count) continue;
        if ((size_t)cell >= digest.cell_owner_slot.size()) continue;
        if (digest.cell_owner_slot[(size_t)cell] != owner) continue;
        const int32_t ctrl = controller_of(cell);
        if (ctrl >= 0 && ctrl != owner) continue;
        const int32_t tpl_off = _armies.template_offset[(size_t)slot];
        const int32_t tpl_len = _armies.template_len[(size_t)slot];
        if (tpl_off < 0 || tpl_len <= 0) continue;
        bool changed = false;
        for (int32_t row = 0; row < tpl_len; row += 2) {
            const size_t ri = (size_t)(tpl_off + row);
            if (ri + 1 >= _template_rows.size()) break;
            const int32_t unit = _template_rows[ri];
            const int64_t want = _template_rows[ri + 1];
            if (unit < 0 || (size_t)unit >= _catalog.units.size()) continue;
            int64_t have = 0;
            for (size_t i = 0; i < _lots.active.size(); ++i) {
                if (!_lots.active[i]) continue;
                if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                if (_lots.location[i] != slot) continue;
                if (_lots.unit_type[i] != unit) continue;
                have += _lots.count[i];
            }
            int64_t deficit = want - have;
            if (deficit <= 0) continue;
            // Pull trained heads from garrisons in the same cell; never take
            // the last 10%, never touch trainees (6.5).
            for (size_t i = 0; i < _lots.active.size() && deficit > 0; ++i) {
                if (!_lots.active[i]) continue;
                if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
                if (_lots.location[i] != cell) continue;
                if (_lots.country_slot[i] != owner) continue;
                if (_lots.unit_type[i] != unit) continue;
                const int64_t take = std::min(deficit, _lots.count[i] - _lots.count[i] / 10);
                if (take <= 0) continue;
                _lots.count[i] -= take;
                const int32_t dest = lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, slot, owner,
                                                        (int16_t)unit, _lots.equip_quality_q8[i]);
                if (dest < 0) {
                    _lots.count[i] += take;
                    break;
                }
                _lots.count[(size_t)dest] += take;
                deficit -= take;
                changed = true;
            }
        }
        if (changed) refresh_army_cache(slot);
    }
}

// ============================================================== morale / org

void MilitaryCore::update_morale_org(const MilitaryWorldDigest &digest) {
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        const size_t a = (size_t)slot;
        const int32_t owner = _armies.owner_slot[a];
        const int32_t cell = _armies.cell[a];
        // Morale (10): weights 30/25/10/10/15/10 scaled by their ratios.
        int64_t morale = 0;
        morale += 30 * _armies.pay_ratio_q16[a] / MILITARY_Q16;
        morale += 25 * _armies.ration_ratio_q16[a] / MILITARY_Q16;
        morale += 10 * 3 / 4;   // daily consumption satisfaction proxy (0.75)
        morale += 10 * std::min<int64_t>(MILITARY_Q16, _armies.supply_ratio_q16[a] * 2) / MILITARY_Q16;
        int64_t civic_q16 = MILITARY_Q16 * 3 / 10;
        if (owner >= 0 && cell >= 0 && cell < _terrain.cell_count &&
            (size_t)cell < digest.cell_owner_slot.size() &&
            digest.cell_owner_slot[(size_t)cell] == owner) {
            const int32_t ctrl = controller_of(cell);
            civic_q16 = (ctrl >= 0 && ctrl != owner) ? MILITARY_Q16 * 3 / 10 : MILITARY_Q16 * 3 / 4;
        }
        morale += 15 * civic_q16 / MILITARY_Q16;
        morale += 10;
        if (owner >= 0) morale += stat_add(digest, owner, MSTAT_MORALE_ADD) / 655;   // additive, 1/100 steps
        _armies.morale_q16[a] = (int32_t)clamp64(morale * MILITARY_Q16 / 100, 0, MILITARY_Q16);

        // Organisation: +3% * supply * recovery while not engaged (13). The
        // engagement stage subtracts for engaged units.
        if (_armies.engagement[a] < 0) {
            int32_t org = _armies.organization_q16[a];
            if (org < MILITARY_Q16) {
                const int64_t rec = owner >= 0 ? stat_q16(digest, owner, MSTAT_ORG_RECOVERY) : MILITARY_Q16;
                int64_t gain = mul_div(mul_div(3 * MILITARY_Q16 / 100, _armies.supply_ratio_q16[a], MILITARY_Q16),
                                       rec, MILITARY_Q16);
                org = (int32_t)std::min<int64_t>(MILITARY_Q16, org + gain);
                _armies.organization_q16[a] = org;
            }
        }
        if (_armies.cached_headcount[a] <= 0) {
            // Empty formations are removed here (A2 may already have done it).
            destroy_army(slot);
        }
    }
}

// ============================================================== wages / upkeep

int64_t MilitaryCore::soldier_living_cost(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    if ((size_t)country_slot >= _last_digest.country_soldier_living_cost.size()) return 0;
    return _last_digest.country_soldier_living_cost[(size_t)country_slot];
}

int64_t MilitaryCore::soldier_daily_wage(int32_t country_slot) const {
    if (country_slot < 0 || (size_t)country_slot >= _policies.size()) return 0;
    const MilitaryCountryPolicy &p = _policies[(size_t)country_slot];
    // ABSOLUTE pays the policy value outright; AUTO scales the soldier living
    // cost by the country's MSTAT_WAGE stat (army-pay contract §2.2). Both pay
    // paths call this, so the garrison and the lane can never disagree.
    if (p.wage_mode == 1) return std::max<int64_t>(0, p.wage_absolute);
    return std::max<int64_t>(0, mul_div(soldier_living_cost(country_slot),
                                       stat_q16(_last_digest, country_slot, MSTAT_WAGE),
                                       MILITARY_Q16));
}

void MilitaryCore::run_wages_and_upkeep(const MilitaryWorldDigest &digest,
                                        std::vector<MilitaryIntent> &out) {
    const bool upkeep_day = (_last_day % kUpkeepPeriod) == 0;
    static thread_local std::vector<int64_t> per_cell;
    // Army holders collect into their own lane (army-pay contract §2.1), so they
    // are accumulated per formation slot instead of per cell. Sized once per call
    // like `per_cell`; slot order keeps the emitted batch deterministic.
    static thread_local std::vector<int64_t> per_army;
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        const uint64_t handle = _policy_handle[slot];
        if (handle == 0) continue;
        const int64_t cash = slot < digest.country_cash.size() ? digest.country_cash[slot] : 0;
        // One wage for both paths (contract §2.2): garrison and army pay use the
        // same per-head daily value, so this is the only place it is computed.
        const int64_t wage = soldier_daily_wage(s);
        per_cell.assign((size_t)_terrain.cell_count, 0);
        per_army.assign(_armies.active.size(), 0);
        int64_t demanded = 0;
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i] || _lots.count[i] <= 0) continue;
            if (_lots.country_slot[i] != s) continue;
            const int64_t amount = (int64_t)wage * _lots.count[i];
            if (amount <= 0) continue;
            if (_lots.location_kind[i] == (uint8_t)MILITARY_LOT_ARMY) {
                // The heads are in the formation's lane, so the wages follow them
                // there (army-pay contract §2.1). The lane is named by ARMY
                // HANDLE, never by cell: a formation that has marched away must
                // not keep paying the home cohort it left behind.
                const int32_t army = _lots.location[i];
                if (!army_alive(_armies, army)) continue;
                const size_t a = (size_t)army;
                if (a >= per_army.size()) continue;
                per_army[a] += amount;
                demanded += amount;
                continue;
            }
            // Garrison path unchanged: wages go to the cell the lots stand on.
            const int32_t pay_cell = _lots.location[i];
            if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
            if (pay_cell < 0 || pay_cell >= _terrain.cell_count) continue;
            per_cell[(size_t)pay_cell] += amount;
            demanded += amount;
        }
        // One treasury, two kinds of holder: both draws share the same cash
        // ceiling. The garrison rows are planned first (cell order) exactly as
        // before, the army rows then take what is left; the combined `planned`
        // feeds the same pay-ratio statistics (contract §2.3: army and garrison
        // each count into the same ratio).
        //
        // Budget envelope (任务 7 / 需求 5.2, 7.1): 军饷 is a high-priority
        // channel, so its share is a PLANNING TARGET, not a hard cap - a country
        // whose soldiers must be paid is allowed to overspend here, and the
        // excess is reported so the panel can paint it rust red. Cash therefore
        // stays the only hard limit; what the envelope changes is that the
        // settlement now knows, and says, how far past its share it went.
        const MilitaryBudgetSplit split = budget_split(s, cash);
        // Procurement settled earlier in this same `step_day` (lap 11 before lap
        // 16) and already charged the treasury, so its spend is no longer
        // available to the wage and upkeep channels. Without this the two would
        // both treat the full balance as theirs: with a 400,000 envelope the
        // army could be paid 400,000 AND buy 400,000 of goods out of the same
        // 2,000,000 - the emitted rows claim more cash than exists.
        //
        // Only metered countries are affected. Without an envelope
        // `procurement_budget_used` stays 0 by contract (需求 5.5: the legacy
        // cash-driven path is untouched), so AI countries settle exactly as
        // before.
        const int64_t committed = split.enabled
                                      ? std::max<int64_t>(0, p.procurement_budget_used)
                                      : 0;
        int64_t budget = std::max<int64_t>(0, cash - committed);
        int64_t planned = 0;
        for (int32_t cell = 0; cell < _terrain.cell_count; ++cell) {
            const int64_t amount = per_cell[(size_t)cell];
            if (amount <= 0) continue;
            const int64_t pay = std::min(amount, budget);
            if (pay <= 0) continue;
            budget -= pay;
            planned += pay;
            _report.payroll_garrison += pay;
            MilitaryIntent in;
            in.kind = MILITARY_INTENT_PAY_WAGES;
            in.cell = cell;
            in.country_a = handle;
            in.amount = pay;
            in.source_id = (uint64_t)cell;
            out.push_back(in);
        }
        for (size_t a = 0; a < per_army.size(); ++a) {
            const int64_t amount = per_army[a];
            if (amount <= 0) continue;
            const int64_t pay = std::min(amount, budget);
            if (pay <= 0) continue;
            budget -= pay;
            planned += pay;
            _report.payroll_army += pay;
            MilitaryIntent in;
            in.kind = MILITARY_INTENT_ARMY_PAY;
            in.cell = _armies.cell[a];
            in.country_a = handle;
            in.amount = pay;
            in.count = _armies.cached_headcount[a];
            in.source_id = army_handle((int32_t)a);
            out.push_back(in);
        }
        p.pay_ratio_30_q16 = demanded > 0
                                 ? (int32_t)clamp64(mul_div(planned, MILITARY_Q16, demanded), 0, MILITARY_Q16)
                                 : MILITARY_Q16;
        // 需求 5.2 + 7.1, resolved the only way both can hold at once: the wage
        // ceiling is a PLANNING TARGET, cash is the HARD limit. So
        //   planned   = min(demand, cash)      -> what actually went out
        //   overspend = paid past the ceiling  -> allowed (军饷 is high priority)
        //   arrears   = demand  - planned      -> nobody could fund it
        // The three are stored per country on the policy row, not in the report:
        // the report is one global struct, so a shared counter would add every
        // country's bill together and the panel would show a foreign AI's numbers.
        // With no envelope they all stay 0 and the legacy path is untouched.
        p.wage_demand = 0;
        p.wage_arrears = 0;
        p.wage_overspend = 0;
        if (split.enabled) {
            p.wage_demand = demanded;
            if (planned > split.wage_ceiling)
                p.wage_overspend = planned - split.wage_ceiling;
            if (demanded > planned) p.wage_arrears = demanded - planned;
        }
        // 30-day rolling spend (integer EWMA, deterministic).
        p.spend_payroll_30 = p.spend_payroll_30 - p.spend_payroll_30 / 30 + planned;

        // The upkeep bill settles every `kUpkeepPeriod` days, so on the days in
        // between there is nothing to report. Clearing here (before the early
        // `continue`) is what keeps the panel from showing a stale shortfall for
        // up to four days after the bill was already paid.
        p.upkeep_demand = 0;
        p.upkeep_arrears = 0;
        p.upkeep_overspend = 0;
        if (!upkeep_day) continue;
        int64_t upkeep = 0;
        for (const MilitaryCellState &st : _cell_states) {
            if (st.cell < 0 || st.cell >= _terrain.cell_count) continue;
            if ((size_t)st.cell >= digest.cell_owner_slot.size()) continue;
            if (digest.cell_owner_slot[(size_t)st.cell] != s) continue;
            for (int32_t tier = 0; tier < 8; ++tier) {
                const int32_t count = st.barracks_count[tier];
                if (count <= 0) continue;
                for (const MilitaryStateBuilding &b : _catalog.state_buildings) {
                    if (b.role == (uint8_t)MILITARY_STATE_BARRACKS && (int32_t)b.tier == tier) {
                        upkeep += (int64_t)count * b.upkeep_per_day * kUpkeepPeriod;
                        break;
                    }
                }
            }
            for (const MilitaryStateBuilding &b : _catalog.state_buildings) {
                if (b.role == (uint8_t)MILITARY_STATE_FORTIFICATION && (int32_t)b.tier == st.fort_tier) {
                    upkeep += b.upkeep_per_day * kUpkeepPeriod;
                } else if (b.role == (uint8_t)MILITARY_STATE_WAR_COLLEGE &&
                           (int32_t)b.tier == st.college_tier) {
                    upkeep += b.upkeep_per_day * kUpkeepPeriod;
                }
            }
        }
        if (upkeep > 0) {
            const int64_t afford = std::min(upkeep,
                                            std::max<int64_t>(0, cash - committed - planned));
            MilitaryIntent in;
            in.kind = MILITARY_INTENT_SPEND_CASH;
            in.country_a = handle;
            in.amount = afford;
            out.push_back(in);
            p.spend_upkeep_30 = p.spend_upkeep_30 - p.spend_upkeep_30 / 6 + afford;
            // Same three numbers as the wage channel (需求 5.3, 7.1), same reason
            // for storing them per country. `upkeep` is the bill for
            // kUpkeepPeriod days and `upkeep_ceiling` is valued PER DAY, so the
            // ceiling has to be scaled by the period before comparing - otherwise
            // a 5-day bill looks 5x over its one-day share.
            if (split.enabled) {
                const int64_t ceiling = split.upkeep_ceiling * kUpkeepPeriod;
                p.upkeep_demand = upkeep;
                if (afford > ceiling) p.upkeep_overspend = afford - ceiling;
                if (upkeep > afford) p.upkeep_arrears = upkeep - afford;
            }
            const uint8_t poor = (afford * 2 < upkeep) ? 1 : 0;
            // The bill above is per country, so the flag that records it must be
            // per country too. Writing every cell state here stamped one
            // country's arrears onto every other country's cells (and onto cells
            // with no state building at all, which then reported `disrepair` in
            // the inspector and moved `state_hash`); the `else` arm was worse, as
            // the last poor-free country wiped everybody else's flag. Only cells
            // this country owns may carry its verdict.
            for (MilitaryCellState &st : _cell_states) {
                if (st.cell < 0 || st.cell >= _terrain.cell_count) continue;
                if ((size_t)st.cell >= digest.cell_owner_slot.size()) continue;
                if (digest.cell_owner_slot[(size_t)st.cell] != s) continue;
                st.disrepair = poor;
            }
        } else {
            // No upkeep bill means this country has no state building that could
            // fall into disrepair, so its own cells are cleared. `else` fires for
            // every country in turn; clearing the whole map here would erase the
            // flag of whichever neighbour was processed before it.
            for (MilitaryCellState &st : _cell_states) {
                if (st.cell < 0 || st.cell >= _terrain.cell_count) continue;
                if ((size_t)st.cell >= digest.cell_owner_slot.size()) continue;
                if (digest.cell_owner_slot[(size_t)st.cell] != s) continue;
                st.disrepair = 0;
            }
        }
    }
}

// ============================================================== cross-TU helpers

int32_t military_cell_garrison_slot(const MilitaryCore &core, int32_t cell) {
    int32_t owner = -1;
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (core._lots.location[i] != cell) continue;
        if (owner < 0 || core._lots.country_slot[i] < owner) owner = core._lots.country_slot[i];
    }
    return owner;
}

namespace {

// Moves heads army -> army (same cell), preserving equipment quality.
int64_t transfer_army_to_army(MilitaryCore &core, int32_t from, int32_t to, int32_t unit,
                              int64_t count) {
    int64_t left = count;
    for (size_t i = 0; i < core._lots.active.size() && left > 0; ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (core._lots.location[i] != from) continue;
        if (unit >= 0 && core._lots.unit_type[i] != unit) continue;
        const int64_t take = std::min(left, core._lots.count[i]);
        if (take <= 0) continue;
        core._lots.count[i] -= take;
        const int32_t dest = core.lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, to,
                                                     core._lots.country_slot[i], core._lots.unit_type[i],
                                                     core._lots.equip_quality_q8[i]);
        if (dest < 0) {
            core._lots.count[i] += take;
            break;
        }
        core._lots.count[(size_t)dest] += take;
        // A source lot that gave everything away must stop pointing at the army:
        // a zero-count row with a live location encodes an army reference that
        // PKMI validates and rejects (pkmi_lot_army_missing after merges).
        if (core._lots.count[i] <= 0) {
            core._lots.active[i] = 0;
            core._lots.free_list.push_back((int32_t)i);
        }
        left -= take;
    }
    return count - left;
}

// Sets an army template from (unit, count) pairs in `ints`.
void set_template(MilitaryCore &core, int32_t army, const std::vector<int32_t> &ints) {
    if (!army_alive(core._armies, army)) return;
    const size_t s = (size_t)army;
    // Compact the arena: append the new rows and mark the old span dead by
    // pointing the army at the fresh tail (save compacts further).
    const int32_t off = (int32_t)core._template_rows.size();
    int32_t rows = 0;
    for (size_t i = 0; i + 1 < ints.size(); i += 2) {
        if (ints[i] < 0 || ints[i] >= (int32_t)core._catalog.units.size()) continue;
        if (ints[i + 1] <= 0) continue;
        core._template_rows.push_back(ints[i]);
        core._template_rows.push_back(ints[i + 1]);
        rows += 2;
    }
    core._armies.template_offset[s] = rows > 0 ? off : 0;
    core._armies.template_len[s] = rows;
    if (core._template_rows.size() > 200000) {
        // Defensive compaction so a long session cannot grow without bound.
        core._template_rows.resize((size_t)off);
        core._armies.template_len[s] = 0;
    }
}

int32_t garrison_owner_at(const MilitaryCore &core, int32_t cell) {
    return military_cell_garrison_slot(core, cell);
}

} // namespace

int32_t military_embark_army(MilitaryCore &core, int32_t owner, int32_t cell, int64_t count) {
    if (owner < 0 || cell < 0 || cell >= core._terrain.cell_count) return -1;
    if (count <= 0) return -1;
    const int32_t army = core.create_army(owner, cell);
    if (army < 0) return -1;
    int64_t left = count;
    for (size_t i = 0; i < core._lots.active.size() && left > 0; ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (core._lots.location[i] != cell) continue;
        if (core._lots.country_slot[i] != owner) continue;
        const int64_t take = std::min(left, core._lots.count[i]);
        core._lots.count[i] -= take;
        const int32_t dest = core.lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, army, owner,
                                                     core._lots.unit_type[i], core._lots.equip_quality_q8[i]);
        if (dest < 0) {
            core._lots.count[i] += take;
            break;
        }
        core._lots.count[(size_t)dest] += take;
        // A source lot that gave everything away must stop pointing at the army:
        // a zero-count row with a live location encodes an army reference that
        // PKMI validates and rejects (pkmi_lot_army_missing after merges).
        if (core._lots.count[i] <= 0) {
            core._lots.active[i] = 0;
            core._lots.free_list.push_back((int32_t)i);
        }
        left -= take;
    }
    core.refresh_army_cache(army);
    if (left == count) {   // nothing boarded: no empty formations
        core.destroy_army(army);
        return -1;
    }
    // Personnel lane (contract §2.1): the boarded heads leave the cell's soldier
    // cohort on the Economy side and live in this formation's lane. One intent
    // per formation, so the lane row is created once and named by army handle.
    core.emit_army_lane_intent(MILITARY_INTENT_ARMY_EMBARK, army, cell, count - left);
    return army;
}

bool military_disembark_army(MilitaryCore &core, int32_t army) {
    if (!army_alive(core._armies, army)) return false;
    const int32_t cell = core._armies.cell[(size_t)army];
    const int32_t owner = core._armies.owner_slot[(size_t)army];
    if (cell < 0) return false;
    // Heads the formation actually carries: its army lots, which mirror the
    // Economy lane row 1:1. Captured before the lots move to the garrison.
    int64_t lane_heads = 0;
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (core._lots.location[i] != army) continue;
        lane_heads += core._lots.count[i];
    }
    // Queued (not emitted directly) because the army must still be alive when
    // the intent carries its handle; destroy_army runs below.
    core.emit_army_lane_intent(MILITARY_INTENT_ARMY_DISEMBARK, army, cell, lane_heads);
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (!core._lots.active[i] || core._lots.count[i] <= 0) continue;
        if (core._lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
        if (core._lots.location[i] != army) continue;
        const int32_t dest = core.lot_find_or_create((uint8_t)MILITARY_LOT_GARRISON, cell, owner,
                                                     core._lots.unit_type[i], core._lots.equip_quality_q8[i]);
        if (dest < 0) break;
        core._lots.count[(size_t)dest] += core._lots.count[i];
        core._lots.count[i] = 0;
    }
    for (size_t i = 0; i < core._lots.active.size(); ++i) {
        if (core._lots.active[i] && core._lots.count[i] <= 0) {
            core._lots.active[i] = 0;
            core._lots.free_list.push_back((int32_t)i);
        }
    }
    core.destroy_army(army);
    return true;
}

// ============================================================== submit

bool MilitaryCore::submit(MilitaryCommand command, std::string &error) {
    error.clear();
    if (!_configured) {
        error = "military_not_configured";
        return false;
    }
    const int64_t cmd_day = command.effective_day;
    if (cmd_day < _last_day) {
        error = "command_day_in_past";
        return false;
    }
    command.sequence = (command.sequence != 0) ? command.sequence : _next_sequence++;
    // Army-scoped commands (move / stance / stop / area_control) may omit the
    // country: the formation knows its owner, and requiring the caller to
    // repeat it only surfaces command_missing_country from the map layer.
    if (command.country == 0 && command.army != 0) {
        int32_t owner_army = -1;
        if (resolve_army(command.army, owner_army) && owner_army >= 0) {
            const int32_t owner = _armies.owner_slot[(size_t)owner_army];
            if (owner >= 0 && (size_t)owner < _policy_handle.size())
                command.country = _policy_handle[(size_t)owner];
        }
    }
    if (command.country == 0) {
        error = "command_missing_country";
        return false;
    }
    const bool has_country = country_slot_for_handle(command.country) >= 0;
    int32_t army_slot = -1;
    const bool has_army = resolve_army(command.army, army_slot);
    auto need_country = [&]() -> bool {
        if (has_country) return true;
        error = "command_unknown_country";
        return false;
    };
    auto need_army = [&]() -> bool {
        if (has_army) return true;
        error = "command_unknown_army";
        return false;
    };

    auto need_cell = [&](int32_t cell) -> bool {
        if (cell >= 0 && cell < _terrain.cell_count) return true;
        error = "command_bad_cell";
        return false;
    };
    auto unit_ok = [&](int32_t unit) -> bool {
        return unit >= 0 && unit < (int32_t)_catalog.units.size();
    };
    switch (command.op) {
        case MCMD_FORCE_SET_TARGET:
            if (!need_country()) return false;
            if (command.count < 0 || command.count > 1) {
                error = "command_bad_target_mode";
                return false;
            }
            if (command.value < 0) {
                error = "command_bad_target_value";
                return false;
            }
            break;
        case MCMD_FORCE_SET_LEVY:
        case MCMD_FORCE_SET_AUTO_DISCHARGE:
        case MCMD_CONFIG_AUTO_RETRAIN:
            if (!need_country()) return false;
            break;
        case MCMD_CONFIG_SET_QUALITY_POLICY:
            if (!need_country()) return false;
            if (command.value < 0 || command.value > 1) {
                error = "command_bad_quality_policy";
                return false;
            }
            break;
        case MCMD_CONFIG_SET: {
            if (!need_country()) return false;
            if (command.ints.size() % 2 != 0) {
                error = "command_bad_shares";
                return false;
            }
            int64_t sum = 0;
            for (size_t i = 0; i + 1 < command.ints.size(); i += 2) {
                if (!unit_ok(command.ints[i])) {
                    error = "command_bad_unit";
                    return false;
                }
                const int32_t bp = command.ints[i + 1];
                if (bp < 0 || bp > 10000) {
                    error = "command_bad_share_bp";
                    return false;
                }
                sum += bp;
            }
            if (sum > 10000) {
                error = "command_shares_exceed_10000";
                return false;
            }
            break;
        }
        case MCMD_BARRACKS_PAUSE: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            const int32_t owner = garrison_owner_at(*this, command.cell);
            if (owner >= 0 && owner != country_slot_for_handle(command.country)) {
                error = "command_not_owner";
                return false;
            }
            break;
        }
        case MCMD_TRAIN: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            if (!unit_ok(command.unit_to)) {
                error = "command_bad_unit";
                return false;
            }
            if (command.unit_from >= (int32_t)_catalog.units.size()) {
                error = "command_bad_unit";
                return false;
            }
            if (command.count <= 0) {
                error = "command_bad_count";
                return false;
            }
            break;
        }
        case MCMD_STATE_BUILD:
        case MCMD_STATE_DEMOLISH: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            if (!unit_ok(command.unit_to) && command.unit_to != -1) {
                // state building index lives in unit_to for these two ops
                error = "command_bad_state_building";
                return false;
            }
            if (command.unit_to < 0 || command.unit_to >= (int32_t)_catalog.state_buildings.size()) {
                error = "command_bad_state_building";
                return false;
            }
            break;
        }
        case MCMD_POLICY_SET_WAGE:
            if (!need_country()) return false;
            if (command.count < 0 || command.count > 1) {
                error = "command_bad_wage_mode";
                return false;
            }
            if (command.value < 0) {
                error = "command_bad_wage";
                return false;
            }
            break;
        case MCMD_POLICY_SET_PROCUREMENT:
            if (!need_country()) return false;
            if (command.value < 0 || command.value > 10000) {
                error = "command_bad_procurement_share";
                return false;
            }
            break;
        case MCMD_POLICY_SET_BUDGET: {
            if (!need_country()) return false;
            if (command.value < -1 || command.value > 10000) {
                error = "command_bad_budget_share";
                return false;
            }
            if (command.ints.size() > 3) {
                error = "command_bad_budget_channels";
                return false;
            }
            for (const int32_t bp : command.ints) {
                if (bp < -1 || bp > 10000) {
                    error = "command_bad_budget_channel_share";
                    return false;
                }
            }
            // 三项之和必须 <= 100%：未传的通道沿用当前值，这样 UI 只推一项时
            // 校验的仍然是玩家最终会看到的那个组合，而不是一份残缺的配置。
            const int32_t slot_now = country_slot_for_handle(command.country);
            const MilitaryCountryPolicy &now = _policies[(size_t)slot_now];
            const int32_t wage = command.ints.size() >= 1 && command.ints[0] >= 0
                                     ? command.ints[0] : now.budget_wage_bp;
            const int32_t upkeep = command.ints.size() >= 2 && command.ints[1] >= 0
                                       ? command.ints[1] : now.budget_upkeep_bp;
            const int32_t procurement =
                command.ints.size() >= 3 && command.ints[2] >= 0
                    ? command.ints[2] : now.procurement_share_bp;
            if (static_cast<int64_t>(wage) + upkeep + procurement > 10000) {
                error = "command_budget_channels_exceed_10000";
                return false;
            }
            break;
        }
        case MCMD_ARMY_CREATE: {
            if (!need_country()) return false;
            if (!need_cell(command.cell)) return false;
            if (command.ints.size() % 2 != 0) {
                error = "command_bad_units";
                return false;
            }
            const int32_t owner = country_slot_for_handle(command.country);
            if (garrison_owner_at(*this, command.cell) != owner) {
                error = "command_no_local_garrison";
                return false;
            }
            break;
        }
        case MCMD_ARMY_STATION:
            if (!need_country()) return false;
            if (!need_country_owns_army(has_country, command)) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_TRANSFER: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            int32_t other = -1;
            if (!resolve_army(command.other, other)) {
                error = "command_unknown_army";
                return false;
            }
            if (_armies.cell[(size_t)army_slot] != _armies.cell[(size_t)other]) {
                error = "command_armies_not_colocated";
                return false;
            }
            break;
        }
        case MCMD_ARMY_MERGE: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            int32_t other = -1;
            if (!resolve_army(command.other, other)) {
                error = "command_unknown_army";
                return false;
            }
            if (_armies.cell[(size_t)army_slot] != _armies.cell[(size_t)other]) {
                error = "command_armies_not_colocated";
                return false;
            }
            break;
        }
        case MCMD_ARMY_SPLIT:
        case MCMD_ARMY_SET_TEMPLATE: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (command.ints.size() % 2 != 0) {
                error = "command_bad_units";
                return false;
            }
            break;
        }
        case MCMD_ARMY_REINFORCE:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_MOVE:
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (!need_cell(command.cell)) return false;
            break;
        case MCMD_ARMY_AREA_CONTROL: {
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (command.cells.empty()) {
                if (!need_cell(command.cell)) return false;
                if (command.radius < 1 || command.radius > MILITARY_MAX_AREA_RADIUS) {
                    error = "command_bad_area_radius";
                    return false;
                }
            } else if (command.cells.size() > (size_t)MILITARY_MAX_AREA_CELLS) {
                error = "command_area_too_large";
                return false;
            }
            for (int32_t cell : command.cells) {
                if (cell < 0 || cell >= _terrain.cell_count) {
                    error = "command_bad_cell";
                    return false;
                }
            }
            break;
        }
        case MCMD_ARMY_STOP:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_STANCE:
            if (!need_country()) return false;
            if (!need_army()) return false;
            if (command.count < 0 || command.count > MILITARY_STANCE_EMBARKED) {
                error = "command_bad_stance";
                return false;
            }
            break;
        case MCMD_ARMY_RENAME:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_ARMY_DISBAND:
            if (!need_country()) return false;
            if (!need_army()) return false;
            break;
        case MCMD_WAR_DECLARE:
        case MCMD_PEACE_PROPOSE:
        case MCMD_PEACE_RESPOND:
            if (!need_country()) return false;
            break;
        default:
            error = "command_unknown_op";
            return false;
    }
    _pending.push_back(std::move(command));
    return true;
}

bool MilitaryCore::need_country_owns_army(bool has_country, const MilitaryCommand &command) const {
    if (!has_country) return false;
    int32_t slot = -1;
    if (!resolve_army(command.army, slot)) return false;
    const int32_t owner = _armies.owner_slot[(size_t)slot];
    return owner >= 0 && _policy_handle.size() > (size_t)owner && _policy_handle[(size_t)owner] == command.country;
}

// ============================================================== commands (apply)

void MilitaryCore::apply_due_commands(int64_t day) {
    if (_pending.empty()) return;
    // Stable sort by (effective_day, sequence): the contract's apply order.
    std::stable_sort(_pending.begin(), _pending.end(), [](const MilitaryCommand &a, const MilitaryCommand &b) {
        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
        return a.sequence < b.sequence;
    });
    // Commands are applied on their effective day or on the first day after it
    // (e.g. a request queued while the world was paused). Commands dated in the
    // future wait for their day.
    size_t applied = 0;
    while (applied < _pending.size() && _pending[applied].effective_day <= day) {
        // Country handles map to slots for the whole lifetime of the world, so
        // a handle accepted by submit() still resolves here.
        apply_command(_pending[applied], day);
        ++applied;
    }
    if (applied > 0) _pending.erase(_pending.begin(), _pending.begin() + (ptrdiff_t)applied);
}

void MilitaryCore::apply_command(const MilitaryCommand &cmd, int64_t day) {
    const int32_t country = country_slot_for_handle(cmd.country);
    if (country < 0) return;   // country vanished before the order took effect
    MilitaryCountryPolicy &policy = _policies[(size_t)country];
    int32_t army_slot = -1;
    switch (cmd.op) {
        case MCMD_FORCE_SET_TARGET:
            policy.target_mode = (uint8_t)cmd.count;
            policy.target_value = cmd.value;
            if (cmd.count == 0) policy.effective_target = cmd.value;
            return;
        case MCMD_FORCE_SET_LEVY:
            policy.levy_enabled = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_FORCE_SET_AUTO_DISCHARGE:
            policy.auto_discharge = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_CONFIG_AUTO_RETRAIN:
            policy.auto_retrain = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_CONFIG_SET_QUALITY_POLICY:
            policy.quality_policy = (uint8_t)cmd.value;
            return;
        case MCMD_CONFIG_SET: {
            if (policy.config_share_bp.size() < _catalog.units.size()) {
                policy.config_share_bp.resize(_catalog.units.size(), 0);
            }
            for (int32_t &bp : policy.config_share_bp) bp = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) {
                policy.config_share_bp[(size_t)cmd.ints[i]] = cmd.ints[i + 1];
            }
            return;
        }
        case MCMD_POLICY_SET_WAGE:
            policy.wage_mode = (uint8_t)cmd.count;
            policy.wage_absolute = cmd.value;
            return;
        case MCMD_POLICY_SET_PROCUREMENT:
            policy.procurement_share_bp = (int32_t)cmd.value;
            return;
        case MCMD_POLICY_SET_BUDGET: {
            // -1 表示「本次不改」，让 UI 只推变化的那一项；其余按传入值落库。
            // 采购占比走 ints[2] 而不是复用 value，因为 value 已经是总份额。
            if (cmd.value >= 0)
                policy.budget_share_bp = (int32_t)std::min<int64_t>(cmd.value, 10000);
            if (cmd.ints.size() >= 1 && cmd.ints[0] >= 0)
                policy.budget_wage_bp = std::min(cmd.ints[0], 10000);
            if (cmd.ints.size() >= 2 && cmd.ints[1] >= 0)
                policy.budget_upkeep_bp = std::min(cmd.ints[1], 10000);
            if (cmd.ints.size() >= 3 && cmd.ints[2] >= 0)
                policy.procurement_share_bp = std::min(cmd.ints[2], 10000);
            return;
        }
        case MCMD_BARRACKS_PAUSE:
            if (MilitaryCellState *st = cell_state(cmd.cell, cmd.count != 0)) st->paused = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_TRAIN: {
            // Manual order: only from heads that exist in the local garrison.
            const int32_t from_unit = cmd.unit_from >= 0 ? cmd.unit_from : _catalog.militia_unit;
            if (from_unit < 0) return;
            int64_t reserved = 0;
            for (const MilitaryTrainingOrder &o : _training) {
                if (o.cell == cmd.cell && o.country_slot == country) reserved += o.count;
            }
            const int64_t have = std::max<int64_t>(0,
                garrison_heads_for_unit(_lots, cmd.cell, country, (int16_t)from_unit) - reserved);
            const int64_t count = std::min(have, cmd.count);
            if (count <= 0) return;
            const MilitaryUnitType &to = _catalog.units[(size_t)cmd.unit_to];
            MilitaryCellState *st = cell_state(cmd.cell, false);
            int32_t speed = MILITARY_Q16;
            MilitaryWorldDigest empty;
            if (st) {
                int32_t found = 0;
                if (barracks_speed_index_matches(_catalog, st->college_tier, &found)) speed = found;
                if (st->disrepair) speed = MILITARY_Q16 + (speed - MILITARY_Q16) / 2;
            }
            const uint8_t from_class = (from_unit == cmd.unit_to)
                                           ? to.unit_class
                                           : _catalog.units[(size_t)from_unit].unit_class;
            const int64_t kind = kind_factor_q16(from_class, to.unit_class, from_unit == cmd.unit_to);
            int64_t days = ceil_div_pos((int64_t)to.training_days * kind, MILITARY_Q16);
            days = std::max<int64_t>(1, mul_div(days, MILITARY_Q16, speed));
            MilitaryTrainingOrder o;
            o.id = _next_id++;
            o.country_slot = country;
            o.cell = cmd.cell;
            o.from_unit = (int16_t)from_unit;
            o.to_unit = (int16_t)cmd.unit_to;
            o.count = count;
            o.days_total = (int32_t)std::min<int64_t>(days, 100000);
            o.equipment_ready = 0;
            o.manual = 1;
            o.quality_q8 = (int16_t)(policy.quality_policy == 0 ? 5 * 256 : 256);
            _training.push_back(o);
            return;
        }
        case MCMD_STATE_BUILD: {
            if (cmd.unit_to < 0 || (size_t)cmd.unit_to >= _catalog.state_buildings.size()) return;
            const MilitaryStateBuilding &b = _catalog.state_buildings[(size_t)cmd.unit_to];
            MilitaryCellState *st = cell_state(cmd.cell, true);
            if (!st) return;
            // Bookkeeping only. `state.build` is no longer a settlement: the
            // caller issues `COMMAND_TREASURY_SPONSORED_BUILD` first and only
            // forwards this command once the economy accepted it, so the real
            // bill (treasury goods, then market gap in cash, booked as
            // NON_TAX_CONSTRUCTION) exists exactly once. The old cash-only
            // material estimate charged a second, invented amount on top.
            //
            // `construction_done_day` is a cache of the economy's schedule:
            // the authoritative completion is the economy building group's
            // pending-construction row, which also applies the country
            // construction time factor this local sum cannot see.
            const int64_t done_day = day + std::max(1, b.build_days);
            int32_t slot = -1;
            for (int32_t k = 0; k < 3; ++k) {
                if (st->construction_building[k] < 0) {
                    slot = k;
                    break;
                }
            }
            if (slot < 0) slot = 0;
            st->construction_building[slot] = cmd.unit_to;
            st->construction_done_day[slot] = done_day;
            return;
        }
        case MCMD_STATE_DEMOLISH: {
            // Deliberately a no-op on the cache. The removal already happened in
            // the economy ledger - the bridge only forwards this command after
            // `queue_treasury_sponsored_demolish` accepted it (requirement 6.5) -
            // and the next `refresh_state_building_cache` reads the smaller
            // group back. Decrementing here as well would take the building down
            // twice: once in the ledger, once in the cache, and every demolition
            // would then look like a stale cache to the repair probe.
            //
            // The opcode is kept because the bridge still echoes an accepted
            // removal through the ordinary command lane, and removing it would
            // renumber the wire format.
            (void)cmd;
            return;
        }
        case MCMD_ARMY_CREATE: {
            const int64_t total = [&]() {
                int64_t sum = 0;
                for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) sum += std::max(0, cmd.ints[i + 1]);
                return sum > 0 ? sum : 0x7FFFFFFFFFFFFFFFll;
            }();
            const int32_t army = military_embark_army(*this, country, cmd.cell, total);
            if (army < 0) return;
            if (!cmd.ints.empty()) set_template(*this, army, cmd.ints);
            refresh_army_cache(army);
            return;
        }
        case MCMD_ARMY_STATION:
            if (resolve_army(cmd.army, army_slot)) military_disembark_army(*this, army_slot);
            return;
        case MCMD_ARMY_TRANSFER:
        case MCMD_ARMY_MERGE: {
            int32_t other = -1;
            // army absorbs `other`.
            if (!resolve_army(cmd.army, army_slot) || !resolve_army(cmd.other, other)) return;
            if (cmd.op == MCMD_ARMY_MERGE) {
                // Personnel lane (contract §1.2 opcode 32): the absorbed
                // formation's whole lane folds into the survivor. Counted before
                // the lots move, because those heads are the lane's population.
                int64_t absorbed_heads = 0;
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (!_lots.active[i] || _lots.count[i] <= 0) continue;
                    if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                    if (_lots.location[i] != other) continue;
                    absorbed_heads += _lots.count[i];
                }
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (!_lots.active[i] || _lots.count[i] <= 0) continue;
                    if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                    if (_lots.location[i] != other) continue;
                    const int32_t dest = lot_find_or_create((uint8_t)MILITARY_LOT_ARMY, army_slot,
                                                            _lots.country_slot[i], _lots.unit_type[i],
                                                            _lots.equip_quality_q8[i]);
                    if (dest < 0) continue;
                    _lots.count[(size_t)dest] += _lots.count[i];
                    _lots.count[i] = 0;
                }
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (_lots.active[i] && _lots.count[i] <= 0) {
                        _lots.active[i] = 0;
                        _lots.free_list.push_back((int32_t)i);
                    }
                }
                _armies.reinforce_enabled[(size_t)army_slot] =
                    _armies.reinforce_enabled[(size_t)army_slot] | _armies.reinforce_enabled[(size_t)other];
                // Fold the absorbed lane into the survivor (opcode 32) before the
                // source formation disappears, so `other` still resolves.
                emit_army_lane_intent(MILITARY_INTENT_ARMY_MERGE_LANES, army_slot,
                                      _armies.cell[(size_t)army_slot], absorbed_heads,
                                      army_handle(other));
                destroy_army(other);
                refresh_army_cache(army_slot);
                return;
            }
            // transfer: (unit, count) pairs, -1 unit means "any".
            // Personnel lane (contract §1.2): the people move with the lots. The
            // head count is what `transfer_army_to_army` actually moved (it clamps
            // to the source's lots), never the template the player asked for.
            int64_t moved = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) {
                const int32_t unit = cmd.ints[i];
                const int64_t count = cmd.ints[i + 1];
                if (count <= 0) continue;
                moved += transfer_army_to_army(*this, other, army_slot,
                                               unit < 0 ? -1 : unit, count);
            }
            if (moved > 0) {
                // Whole formation transferred -> fold the source lane into the
                // receiver (opcode 32, the army.merge semantics). A partial
                // transfer only moves the heads that left (opcode 33), so the
                // rest of the source formation keeps its own people.
                int64_t remaining = 0;
                for (size_t i = 0; i < _lots.active.size(); ++i) {
                    if (!_lots.active[i] || _lots.count[i] <= 0) continue;
                    if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_ARMY) continue;
                    if (_lots.location[i] != other) continue;
                    remaining += _lots.count[i];
                }
                emit_army_lane_intent(
                    remaining <= 0 ? MILITARY_INTENT_ARMY_MERGE_LANES
                                   : MILITARY_INTENT_ARMY_SPLIT_LANES,
                    army_slot, _armies.cell[(size_t)army_slot], moved,
                    army_handle(other));
                // `moved` raises this formation's in-flight ceiling on purpose:
                // its lane is still short of those heads until the command lands,
                // and the lane reconcile at the end of this same day would
                // otherwise trim them straight off the lots. The receipt releases
                // the ceiling once the lane has caught up.
            }
            refresh_army_cache(army_slot);
            refresh_army_cache(other);
            return;
        }
        case MCMD_ARMY_SPLIT: {
            if (!resolve_army(cmd.army, army_slot)) return;
            const int32_t cell = _armies.cell[(size_t)army_slot];
            const int32_t owner = _armies.owner_slot[(size_t)army_slot];
            // Split out (unit, count) pairs into a new formation at the same cell.
            int64_t total = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) total += std::max(0, cmd.ints[i + 1]);
            if (total <= 0) return;
            const int32_t created = create_army(owner, cell);
            if (created < 0) return;
            int64_t moved = 0;
            for (size_t i = 0; i + 1 < cmd.ints.size(); i += 2) {
                const int32_t unit = cmd.ints[i];
                const int64_t count = cmd.ints[i + 1];
                if (count <= 0) continue;
                moved += transfer_army_to_army(*this, army_slot, created, unit, count);
            }
            // Personnel lane (contract §1.2 opcode 33): the detached formation gets
            // its own people, not a copy of the template. `moved` is the sum of the
            // lot counts that actually left the source formation; the source lane
            // loses exactly those heads and the new formation's lane gains them.
            if (moved > 0) {
                emit_army_lane_intent(MILITARY_INTENT_ARMY_SPLIT_LANES, created, cell, moved,
                                      army_handle(army_slot));
                // Same rule as the transfer above: the new formation's lots run
                // ahead of its lane until the split command lands, so the heads
                // stay in flight (the reconcile at the end of this day must not
                // trim them). `emit_army_lane_intent` puts the receipt on this
                // formation, so the ceiling is released when the lane catches up.
            }
            refresh_army_cache(army_slot);
            refresh_army_cache(created);
            if (moved <= 0) destroy_army(created);
            return;
        }
        case MCMD_ARMY_SET_TEMPLATE:
            if (resolve_army(cmd.army, army_slot)) set_template(*this, army_slot, cmd.ints);
            return;
        case MCMD_ARMY_REINFORCE:
            if (resolve_army(cmd.army, army_slot)) _armies.reinforce_enabled[(size_t)army_slot] = cmd.count != 0 ? 1 : 0;
            return;
        case MCMD_ARMY_MOVE: {
            if (!resolve_army(cmd.army, army_slot)) return;
            const int32_t owner = _armies.owner_slot[(size_t)army_slot];
            MilitaryWorldDigest empty;
            std::vector<int32_t> path;
            if (!find_path(army_slot, cmd.cell, empty, path)) {
                // Deferred: the daily path budget is spent (design 21.3).
                return;
            }
            const size_t s = (size_t)army_slot;
            const int32_t off = (int32_t)_path_cells.size();
            _path_cells.insert(_path_cells.end(), path.begin(), path.end());
            _armies.path_offset[s] = path.empty() ? 0 : off;
            _armies.path_len[s] = (int32_t)path.size();
            _armies.path_cursor[s] = 0;
            _armies.target_cell[s] = cmd.cell;
            _armies.mission[s] = (uint8_t)MILITARY_MISSION_MOVE;
            if (_armies.stance[s] == (uint8_t)MILITARY_STANCE_RETREAT) {
                _armies.stance[s] = (uint8_t)MILITARY_STANCE_HOLD;
            }
            (void)owner;
            return;
        }
        case MCMD_ARMY_AREA_CONTROL: {
            if (!resolve_army(cmd.army, army_slot)) return;
            std::vector<int32_t> cells = cmd.cells;
            if (cells.empty() && cmd.cell >= 0) {
                // Centre + radius: ring walk via BFS on the neighbour table.
                cells = ring_cells(cmd.cell, cmd.radius);
            }
            if (cells.empty()) return;
            std::sort(cells.begin(), cells.end());
            cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
            if (cells.size() > (size_t)MILITARY_MAX_AREA_CELLS) cells.resize((size_t)MILITARY_MAX_AREA_CELLS);
            const int32_t owner = _armies.owner_slot[(size_t)army_slot];
            int32_t area_id = _armies.area_id[(size_t)army_slot];
            if (area_id < 0 || (size_t)area_id >= _areas.size() || !_areas[(size_t)area_id].active) {
                MilitaryArea area;
                area.id = (int32_t)_areas.size();
                area.owner_slot = owner;
                area.last_eval_day = -100000;
                area.active = 1;
                area.cells = cells;
                _areas.push_back(area);
                area_id = area.id;
            } else {
                _areas[(size_t)area_id].cells = cells;
                _areas[(size_t)area_id].owner_slot = owner;
                _areas[(size_t)area_id].last_eval_day = -100000;
                _areas[(size_t)area_id].active = 1;
            }
            _armies.area_id[(size_t)army_slot] = area_id;
            _armies.mission[(size_t)army_slot] = (uint8_t)MILITARY_MISSION_AREA_CONTROL;
            return;
        }
        case MCMD_ARMY_STOP: {
            if (!resolve_army(cmd.army, army_slot)) return;
            const size_t s = (size_t)army_slot;
            _armies.path_len[s] = 0;
            _armies.path_cursor[s] = 0;
            _armies.target_cell[s] = -1;
            _armies.mission[s] = (uint8_t)MILITARY_MISSION_NONE;
            _armies.area_id[s] = -1;
            return;
        }
        case MCMD_ARMY_STANCE: {
            if (!resolve_army(cmd.army, army_slot)) return;
            _armies.stance[(size_t)army_slot] = (uint8_t)cmd.count;
            if (cmd.count != MILITARY_STANCE_RETREAT) {
                // leaving RETREAT resumes normal movement
            }
            return;
        }
        case MCMD_ARMY_RENAME: {
            if (!resolve_army(cmd.army, army_slot)) return;
            _armies.name_seed[(size_t)army_slot] = (uint32_t)(cmd.value & 0xFFFFFFFFll);
            return;
        }
        case MCMD_ARMY_DISBAND:
            if (resolve_army(cmd.army, army_slot)) military_disembark_army(*this, army_slot);
            return;
        default:
            apply_war_command(cmd, day);
            return;
    }
}

std::vector<int32_t> MilitaryCore::ring_cells(int32_t center, int32_t radius) const {
    std::vector<int32_t> out;
    if (center < 0 || center >= _terrain.cell_count) return out;
    if (radius <= 0) {
        out.push_back(center);
        return out;
    }
    static thread_local std::vector<int32_t> frontier;
    static thread_local std::vector<int32_t> next;
    static thread_local std::vector<int32_t> dist;
    dist.assign((size_t)_terrain.cell_count, -1);
    frontier.clear();
    frontier.push_back(center);
    dist[(size_t)center] = 0;
    out.push_back(center);
    for (int32_t r = 0; r < radius; ++r) {
        next.clear();
        for (int32_t cell : frontier) {
            const int32_t base = cell * 6;
            for (int32_t d = 0; d < 6; ++d) {
                const int32_t nb = _terrain.neighbors[(size_t)(base + d)];
                if (nb < 0 || nb >= _terrain.cell_count) continue;
                if (dist[(size_t)nb] >= 0) continue;
                dist[(size_t)nb] = r + 1;
                next.push_back(nb);
                out.push_back(nb);
            }
        }
        frontier.swap(next);
        if (frontier.empty()) break;
    }
    std::sort(out.begin(), out.end());
    return out;
}

// ============================================================== step_day
namespace {

double g_stage_ms[MILITARY_STAGE_COUNT] = {};

double now_ms(const std::chrono::steady_clock::time_point &start) {
    const auto end = std::chrono::steady_clock::now();
    return (double)std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count() / 1000000.0;
}

} // namespace

const double *military_stage_ms() { return g_stage_ms; }

const char *military_stage_name(int32_t stage) {
    static const char *kNames[MILITARY_STAGE_COUNT] = {
        "commands", "force_targets", "supply_fields", "threat_fields", "recruitment", "training", "reinforcement",
        "movement", "area_missions", "engagements", "wars", "procurement", "convoys", "consumption", "requisition",
        "morale_org", "wages", "reparations", "ai", "ledger_report"};
    return (stage >= 0 && stage < MILITARY_STAGE_COUNT) ? kNames[stage] : "?";
}

bool MilitaryCore::step_day(int64_t day, const MilitaryWorldDigest &digest,
                            const std::vector<MilitaryIntentReceipt> &receipts,
                            std::vector<MilitaryIntent> &intents, std::string &error) {
    error.clear();
    if (!_configured) {
        error = "military_not_configured";
        return false;
    }
    const auto start = std::chrono::steady_clock::now();
    _last_day = day;
    _report = MilitaryReport();
    _report.day = day;
    MilitaryWorldDigest view = digest;
    normalize_digest(_terrain, view);

    const size_t cells = (size_t)std::max(0, _terrain.cell_count);
    if (_cell_head.size() < cells) {
        _cell_head.resize(cells, -1);
        _cell_engagement_mask.resize(cells, 0);
        _front_edge_set.assign(cells * 6, 0);
        _threat.assign(cells, 0);
        _guard.assign(cells, 0);
        _threat_stamp.assign(cells, 0);
        _dij_dist.resize(cells, 0);
        _dij_parent.resize(cells, -1);
        _dij_stamp.assign(cells, 0);
        _cell_controller.resize(cells, -1);
        rebuild_cell_index();
    }
    if ((size_t)_path_daily_requests.size() < _policies.size()) {
        _path_daily_requests.resize(_policies.size(), 0);
    }
    for (int32_t &n : _path_daily_requests) n = 0;

    const size_t intents_before = intents.size();
    _attrition_intents.clear();
    // Mirror the committed view for cold queries and the AI agenda.
    _last_digest = view;
    // The state building cache is a derived read of the economy ledger, so it
    // is rebuilt before anything downstream (posts, upkeep, training speed,
    // fortification strength, the AI's barracks planner) consults it
    // (requirement 6.1-6.4).
    refresh_state_building_cache(view);
    _country_annual_revenue.assign(view.country_annual_revenue.begin(), view.country_annual_revenue.end());
    _country_era.assign(view.country_era.begin(), view.country_era.end());
    _cell_owner_dirty.assign((size_t)view.cell_owner_slot.size(), 0);
    double *stage = g_stage_ms;
    for (int32_t i = 0; i < MILITARY_STAGE_COUNT; ++i) stage[i] = 0.0;
    auto mark = std::chrono::steady_clock::now();
    auto lap = [&](int32_t idx) {
        const auto t = std::chrono::steady_clock::now();
        stage[idx] += (double)std::chrono::duration_cast<std::chrono::nanoseconds>(t - mark).count() / 1e6;
        mark = t;
    };
    apply_due_commands(day);    for (MilitaryCellState &st : _cell_states) for (int32_t k = 0; k < 3; ++k) {   // A3: finish state builds
        const int32_t b = st.construction_building[k];
        if (b < 0 || st.construction_done_day[k] > day || (size_t)b >= _catalog.state_buildings.size()) continue;
        // No cache increment: the economy ledger owns the count (requirement
        // 6.1/6.5) and the next `refresh_state_building_cache` reads the
        // finished lot back. This pass only expires the local schedule slot,
        // which is a cache of the economy's completion day - the economy also
        // applies the country construction time factor this local sum cannot
        // see, so booking anything here would double count.
        st.construction_building[k] = -1; st.construction_done_day[k] = -1;
    }
    reconcile_receipts(receipts);
    reconcile_soldier_roster(view);
    // Army personnel lane rows queued by today's command application (create /
    // station / disband / merge) join the same D+1 batch as every other intent.
    for (const MilitaryIntent &row : _lane_intents) intents.push_back(row);
    _lane_intents.clear();
    lap(0);
    update_force_targets(view);
    lap(1);
    // Supply fields: daily logistics indexes are built by the logistics pass
    // (design 9.3) inside build_threat_fields' shared prep step; the old
    // nationwide nearest-market field no longer exists.
    lap(2);
    build_threat_fields(view);
    lap(3);
    run_recruitment(view, intents);
    lap(4);
    run_training(view);
    lap(5);
    run_reinforcement(view);
    lap(6);
    run_movement(view);
    lap(7);
    // Soldier losses from harsh-environment attrition drain into the batch.
    for (const MilitaryIntent &row : _attrition_intents) intents.push_back(row);
    _attrition_intents.clear();
    // State building requests become economy construction orders in the bridge.
    // `MCMD_STATE_BUILD` no longer settles anything itself, so a request that
    // the treasury cannot pay for simply never turns into a lot.
    for (const StateBuildRequest &request : _build_requests) {
        if (request.country == 0 || request.cell < 0 || request.building < 0) continue;
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_STATE_BUILD;
        intent.cell = request.cell;
        intent.country_a = request.country;
        intent.count = request.building;
        intent.source_id = 0x5354415445ull;   // "STATE"
        intents.push_back(intent);
    }
    _build_requests.clear();
    run_area_missions(view);
    lap(8);
    run_engagements(view, intents);
    lap(9);
    run_wars(view, intents);
    lap(10);
    run_procurement(view, intents);
    lap(11);
    run_convoys(view, intents);
    lap(12);
    run_consumption(view, intents);
    lap(13);
    run_requisition(view, intents);
    lap(14);
    update_morale_org(view);
    lap(15);
    run_wages_and_upkeep(view, intents);
    lap(16);
    run_reparations(view, intents);
    lap(17);
    if (ai_decision_due(day)) run_country_ai(view);
    lap(18);

    if (cells > 0) _control_revision += 0;   // bumped by whoever mutates control
    _report.intents_emitted = (int32_t)(intents.size() - intents_before);
    _report.armies_active = 0;
    _report.armies_moving = 0;
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        ++_report.armies_active;
        if (_armies.mission[(size_t)slot] == (uint8_t)MILITARY_MISSION_MOVE ||
            _armies.path_cursor[(size_t)slot] < _armies.path_len[(size_t)slot]) {
            ++_report.armies_moving;
        }
    }
    _report.engagements_active = 0;
    for (const MilitaryEngagement &e : _engagements) {
        if (e.active) ++_report.engagements_active;
    }
    _report.wars_active = 0;
    for (const MilitaryWar &w : _wars) {
        if (w.active) ++_report.wars_active;
    }
    int64_t soldiers = 0;
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i]) soldiers += _lots.count[i];
    }
    _report.soldiers_total = soldiers;
    reconcile_ledger();   // A3: report.reconcile_delta is the sec 9.7 goods residual
    lap(19);
    _report.day_ms = now_ms(start);
    _report.idle = (_report.armies_moving == 0 && _report.engagements_active == 0 &&
                    _report.wars_active == 0 && _report.intents_emitted == 0)
                       ? 1
                       : 0;
    return true;
}

bool MilitaryCore::ai_decision_due(int64_t day) const {
    const size_t n = _ai_country.size();
    for (size_t i = 0; i < n; ++i) {
        if (!_ai_country[i]) continue;
        const int64_t next = i < _ai_next_decision_day.size() ? _ai_next_decision_day[i] : 0;
        if (day >= next) return true;
    }
    return false;
}

bool MilitaryCore::should_run(int64_t day) const {
    if (!_configured) return false;
    if (!_pending.empty()) return true;
    const bool upkeep_day = (day % kUpkeepPeriod) == 0;
    const bool recruit_day = (day % kRecruitCheckPeriod) == 0;
    for (int32_t slot = 0; slot < (int32_t)_armies.active.size(); ++slot) {
        if (!_armies.active[(size_t)slot]) continue;
        if (_armies.cached_headcount[(size_t)slot] > 0) return true;
        if (_armies.mission[(size_t)slot] != (uint8_t)MILITARY_MISSION_NONE) return true;
        if (_armies.path_cursor[(size_t)slot] < _armies.path_len[(size_t)slot]) return true;
    }
    for (const MilitaryEngagement &e : _engagements) {
        if (e.active) return true;
    }
    for (const MilitaryWar &w : _wars) {
        if (w.active) return true;
    }
    for (const MilitaryShipment &sh : _shipments) {
        if (sh.qty > 0) return true;
    }
    for (const MilitaryTrainingOrder &o : _training) {
        if (o.count > 0) return true;
    }
    for (const MilitaryReparation &r : _reparations) {
        if (r.remaining > 0) return true;
    }
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] && _lots.count[i] > 0) return true;
    }
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        if (_policy_handle[slot] == 0) continue;
        const MilitaryCountryPolicy &p = _policies[slot];
        if (p.effective_target > 0 || p.target_value > 0) return true;
        if (recruit_day) return true;
        if (upkeep_day && !_cell_states.empty()) return true;
    }
    if (ai_decision_due(day)) return true;
    return false;
}

// ============================================================== hash

uint64_t MilitaryCore::state_hash() const {
    uint64_t h = 0x243f6a8885a308d3ull;
    h = mix_scalar<uint64_t>(h, _seed);
    h = mix_scalar<uint64_t>(h, _catalog.hash);
    h = mix_scalar<int64_t>(h, _last_day);
    h = mix_scalar<uint64_t>(h, _next_sequence);
    h = mix_scalar<uint64_t>(h, _next_id);
    h = mix_scalar<uint64_t>(h, _next_event_id);
    h = mix_scalar<uint64_t>(h, _control_revision);
    h = mix_scalar<uint64_t>(h, _front_revision);
    h = mix_scalar<uint64_t>(h, (uint64_t)_path_daily_requests.size());
    for (int32_t n : _path_daily_requests) h = mix_scalar<int32_t>(h, n);
    h = mix_scalar<uint64_t>(h, (uint64_t)_pending.size());
    for (const MilitaryCommand &c : _pending) {
        h = mix_scalar<uint16_t>(h, c.op);
        h = mix_scalar<int64_t>(h, c.effective_day);
        h = mix_scalar<uint64_t>(h, c.sequence);
        h = mix_scalar<uint64_t>(h, c.country);
        h = mix_scalar<uint64_t>(h, c.army);
        h = mix_scalar<uint64_t>(h, c.other);
        h = mix_scalar<int32_t>(h, c.cell);
        h = mix_scalar<int32_t>(h, c.radius);
        h = mix_scalar<int32_t>(h, c.unit_from);
        h = mix_scalar<int32_t>(h, c.unit_to);
        h = mix_scalar<int64_t>(h, c.count);
        h = mix_scalar<int64_t>(h, c.value);
        for (int32_t v : c.cells) h = mix_scalar<int32_t>(h, v);
        for (int32_t v : c.ints) h = mix_scalar<int32_t>(h, v);
        for (int64_t v : c.longs) h = mix_scalar<int64_t>(h, v);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_lots.active.size());
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        h = mix_scalar<uint8_t>(h, _lots.active[i]);
        if (!_lots.active[i]) continue;
        h = mix_scalar<uint8_t>(h, _lots.location_kind[i]);
        h = mix_scalar<int32_t>(h, _lots.location[i]);
        h = mix_scalar<int32_t>(h, _lots.country_slot[i]);
        h = mix_scalar<int16_t>(h, _lots.unit_type[i]);
        h = mix_scalar<int16_t>(h, _lots.equip_quality_q8[i]);
        h = mix_scalar<int32_t>(h, _lots.condition_q16[i]);
        h = mix_scalar<int64_t>(h, _lots.count[i]);
    }
    const MilitaryArmyStore &a = _armies;
    h = mix_scalar<uint64_t>(h, (uint64_t)a.active.size());
    for (size_t i = 0; i < a.active.size(); ++i) {
        h = mix_scalar<uint8_t>(h, a.active[i]);
        if (!a.active[i]) continue;
        h = mix_scalar<uint32_t>(h, a.generation[i]);
        h = mix_scalar<int32_t>(h, a.owner_slot[i]);
        h = mix_scalar<int32_t>(h, a.cell[i]);
        h = mix_scalar<int32_t>(h, a.next_cell[i]);
        h = mix_scalar<int32_t>(h, a.move_points_q16[i]);
        h = mix_scalar<uint8_t>(h, a.stance[i]);
        h = mix_scalar<uint8_t>(h, a.mission[i]);
        h = mix_scalar<int32_t>(h, a.target_cell[i]);
        h = mix_scalar<int32_t>(h, a.area_id[i]);
        h = mix_scalar<int32_t>(h, a.organization_q16[i]);
        h = mix_scalar<int32_t>(h, a.morale_q16[i]);
        h = mix_scalar<int32_t>(h, a.supply_ratio_q16[i]);
        h = mix_scalar<int32_t>(h, a.ration_ratio_q16[i]);
        h = mix_scalar<int32_t>(h, a.pay_ratio_q16[i]);
        h = mix_scalar<int32_t>(h, a.path_cursor[i]);
        h = mix_scalar<int32_t>(h, a.path_len[i]);
        h = mix_scalar<uint8_t>(h, a.reinforce_enabled[i]);
        h = mix_scalar<int32_t>(h, a.template_len[i]);
        h = mix_scalar<int64_t>(h, a.cached_headcount[i]);
        h = mix_scalar<int64_t>(h, a.cached_attack_q16[i]);
        h = mix_scalar<int64_t>(h, a.cached_defense_q16[i]);
        h = mix_scalar<int32_t>(h, a.cached_speed_q16[i]);
        h = mix_scalar<int32_t>(h, a.engagement[i]);
        h = mix_scalar<int64_t>(h, a.moved_day[i]);
        h = mix_scalar<int32_t>(h, a.prev_cell[i]);
        h = mix_scalar<uint32_t>(h, a.name_seed[i]);
        h = mix_scalar<int64_t>(h, a.funds[i]);
    }
    // Live spans only (arenas are compacted by PKMI encode; dead rows are not state).
    for (size_t i = 0; i < a.active.size(); ++i) {
        if (!a.active[i]) continue;
        for (int32_t k = 0; k < a.path_len[i]; ++k) {
            const size_t at = (size_t)(a.path_offset[i] + k);
            h = mix_scalar<int32_t>(h, at < _path_cells.size() ? _path_cells[at] : -1);
        }
        for (int32_t k = 0; k < a.template_len[i]; ++k) {
            const size_t at = (size_t)(a.template_offset[i] + k);
            h = mix_scalar<int32_t>(h, at < _template_rows.size() ? _template_rows[at] : -1);
        }
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_training.size());
    for (const MilitaryTrainingOrder &o : _training) {
        h = mix_scalar<uint64_t>(h, o.id);
        h = mix_scalar<int32_t>(h, o.country_slot);
        h = mix_scalar<int32_t>(h, o.cell);
        h = mix_scalar<int16_t>(h, o.from_unit);
        h = mix_scalar<int16_t>(h, o.to_unit);
        h = mix_scalar<int64_t>(h, o.count);
        h = mix_scalar<int32_t>(h, o.days_total);
        h = mix_scalar<int32_t>(h, o.days_done);
        h = mix_scalar<uint8_t>(h, o.equipment_ready);
        h = mix_scalar<uint8_t>(h, o.manual);
        h = mix_scalar<int16_t>(h, o.quality_q8);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_stocks.size());
    for (const MilitaryStockRow &r : _stocks) {
        h = mix_scalar<uint8_t>(h, r.holder_kind);
        h = mix_scalar<int32_t>(h, r.holder);
        h = mix_scalar<int32_t>(h, r.country_slot);
        h = mix_scalar<int32_t>(h, r.good);
        h = mix_scalar<int64_t>(h, r.qty);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_shipments.size());
    for (const MilitaryShipment &s : _shipments) {
        h = mix_scalar<uint64_t>(h, s.id);
        h = mix_scalar<int32_t>(h, s.country_slot);
        h = mix_scalar<uint8_t>(h, s.dest_kind);
        h = mix_scalar<int32_t>(h, s.dest);
        h = mix_scalar<uint64_t>(h, s.dest_handle);
        h = mix_scalar<int32_t>(h, s.origin_cell);
        h = mix_scalar<int32_t>(h, s.current_cell);
        h = mix_scalar<int32_t>(h, s.good);
        h = mix_scalar<int64_t>(h, s.qty);
        h = mix_scalar<int64_t>(h, s.value);
        h = mix_scalar<int64_t>(h, s.departure_day);
        h = mix_scalar<int64_t>(h, s.eta_day);
        h = mix_scalar<int32_t>(h, s.route_cost_q16);
        h = mix_scalar<int32_t>(h, s.progress_q16);
        h = mix_scalar<int32_t>(h, s.blocked_days);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_engagements.size());
    for (const MilitaryEngagement &e : _engagements) {
        h = mix_scalar<int32_t>(h, e.cell_a);
        h = mix_scalar<int32_t>(h, e.cell_b);
        h = mix_scalar<int32_t>(h, e.attacker_side_cell);
        h = mix_scalar<int32_t>(h, e.attacker_slot);
        h = mix_scalar<int32_t>(h, e.defender_slot);
        h = mix_scalar<int32_t>(h, e.war_id);
        h = mix_scalar<int32_t>(h, e.progress_q16);
        h = mix_scalar<int64_t>(h, e.start_day);
        h = mix_scalar<int32_t>(h, e.idle_days);
        h = mix_scalar<int32_t>(h, e.days_since_battle);
        h = mix_scalar<int64_t>(h, e.casualties_attacker);
        h = mix_scalar<int64_t>(h, e.casualties_defender);
        h = mix_scalar<uint8_t>(h, e.active);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_wars.size());
    for (const MilitaryWar &w : _wars) {
        h = mix_scalar<int32_t>(h, w.id);
        h = mix_scalar<int32_t>(h, w.attacker_slot);
        h = mix_scalar<int32_t>(h, w.defender_slot);
        h = mix_scalar<uint64_t>(h, w.attacker_handle);
        h = mix_scalar<uint64_t>(h, w.defender_handle);
        h = mix_scalar<int64_t>(h, w.start_day);
        h = mix_scalar<int32_t>(h, w.score_battle_q16);
        h = mix_scalar<int32_t>(h, w.score_annihilation_q16);
        h = mix_scalar<int32_t>(h, w.score_attrition_q16);
        h = mix_scalar<int64_t>(h, w.attacker_losses);
        h = mix_scalar<int64_t>(h, w.defender_losses);
        h = mix_scalar<int64_t>(h, w.last_rejected_offer_day_a);
        h = mix_scalar<int64_t>(h, w.last_rejected_offer_day_b);
        h = mix_scalar<int64_t>(h, w.fully_occupied_since_a);
        h = mix_scalar<int64_t>(h, w.fully_occupied_since_b);
        h = mix_scalar<uint8_t>(h, w.active);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_truces.size());
    for (const MilitaryTruce &t : _truces) {
        h = mix_scalar<int32_t>(h, t.slot_a);
        h = mix_scalar<int32_t>(h, t.slot_b);
        h = mix_scalar<int64_t>(h, t.until_day);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_reparations.size());
    for (const MilitaryReparation &r : _reparations) {
        h = mix_scalar<uint64_t>(h, r.payer);
        h = mix_scalar<uint64_t>(h, r.receiver);
        h = mix_scalar<int64_t>(h, r.installment);
        h = mix_scalar<int32_t>(h, r.remaining);
        h = mix_scalar<int64_t>(h, r.next_day);
        h = mix_scalar<int64_t>(h, r.arrears);
        h = mix_scalar<int32_t>(h, r.war_id);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_battle_log.size());
    for (const MilitaryBattleLogRow &b : _battle_log) {
        h = mix_scalar<int64_t>(h, b.day);
        h = mix_scalar<int32_t>(h, b.cell);
        h = mix_scalar<int32_t>(h, b.war_id);
        h = mix_scalar<int32_t>(h, b.winner_slot);
        h = mix_scalar<int32_t>(h, b.loser_slot);
        h = mix_scalar<int64_t>(h, b.winner_losses);
        h = mix_scalar<int64_t>(h, b.loser_losses);
        h = mix_scalar<int32_t>(h, b.score_gain_q16);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_areas.size());
    for (const MilitaryArea &ar : _areas) {
        h = mix_scalar<int32_t>(h, ar.id);
        h = mix_scalar<int32_t>(h, ar.owner_slot);
        h = mix_scalar<int64_t>(h, ar.last_eval_day);
        h = mix_scalar<uint8_t>(h, ar.active);
        h = mix_scalar<uint64_t>(h, (uint64_t)ar.cells.size());
        for (int32_t c : ar.cells) h = mix_scalar<int32_t>(h, c);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_policies.size());
    for (size_t i = 0; i < _policies.size(); ++i) {
        const MilitaryCountryPolicy &p = _policies[i];
        h = mix_scalar<uint64_t>(h, _policy_handle[i]);
        h = mix_scalar<uint8_t>(h, p.target_mode);
        h = mix_scalar<int64_t>(h, p.target_value);
        h = mix_scalar<int64_t>(h, p.effective_target);
        h = mix_scalar<uint8_t>(h, p.levy_enabled);
        h = mix_scalar<uint8_t>(h, p.auto_retrain);
        h = mix_scalar<uint8_t>(h, p.auto_discharge);
        h = mix_scalar<uint8_t>(h, p.quality_policy);
        h = mix_scalar<uint8_t>(h, p.wage_mode);
        h = mix_scalar<int64_t>(h, p.wage_absolute);
        h = mix_scalar<int32_t>(h, p.procurement_share_bp);
        h = mix_scalar<int32_t>(h, p.pay_ratio_30_q16);
        h = mix_scalar<int64_t>(h, p.per_soldier_cost);
        for (int32_t bp : p.config_share_bp) h = mix_scalar<int32_t>(h, bp);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_cell_states.size());
    for (const MilitaryCellState &st : _cell_states) {
        h = mix_scalar<int32_t>(h, st.cell);
        for (int32_t t = 0; t < 8; ++t) h = mix_scalar<int32_t>(h, st.barracks_count[t]);
        h = mix_scalar<int32_t>(h, st.fort_tier);
        h = mix_scalar<int32_t>(h, st.college_tier);
        h = mix_scalar<uint8_t>(h, st.paused);
        h = mix_scalar<uint8_t>(h, st.disrepair);
        h = mix_scalar<int64_t>(h, st.pending_enlist);
        h = mix_scalar<int64_t>(h, st.quota);
        h = mix_scalar<int64_t>(h, st.requisition_until_day);
        for (int32_t k = 0; k < 3; ++k) {
            h = mix_scalar<int64_t>(h, st.construction_done_day[k]);
            h = mix_scalar<int32_t>(h, st.construction_building[k]);
        }
    }
    for (int32_t c : _cell_controller) h = mix_scalar<int32_t>(h, c);
    h = mix_scalar<int64_t>(h, _ledger_received);
    h = mix_scalar<int64_t>(h, _ledger_consumed);
    h = mix_scalar<int64_t>(h, _ledger_intercepted_out);
    h = mix_scalar<int64_t>(h, _ledger_intercepted_in);
    h = mix_scalar<int64_t>(h, _ledger_returned);
    h = mix_scalar<uint64_t>(h, (uint64_t)_events.size());
    for (const MilitaryEvent &e : _events) {
        h = mix_scalar<uint64_t>(h, e.id);
        h = mix_scalar<int64_t>(h, e.day);
        h = mix_scalar<uint16_t>(h, e.type);
        h = mix_scalar<uint16_t>(h, e.payload_schema);
        h = mix_scalar<int32_t>(h, e.cell);
        h = mix_scalar<uint64_t>(h, e.i0);
        h = mix_scalar<uint64_t>(h, e.i1);
        h = mix_scalar<uint64_t>(h, e.i2);
        h = mix_scalar<uint64_t>(h, e.i3);
        h = mix_scalar<int64_t>(h, e.value);
    }
    h = mix_scalar<uint64_t>(h, (uint64_t)_ai_country.size());
    for (size_t i = 0; i < _ai_country.size(); ++i) {
        h = mix_scalar<uint8_t>(h, _ai_country[i]);
        if (i < _ai_next_decision_day.size()) h = mix_scalar<int64_t>(h, _ai_next_decision_day[i]);
    }
    return h;
}

} // namespace pk
