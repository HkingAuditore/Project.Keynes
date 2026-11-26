// MilitaryCore main TU: catalog, lifecycle, day orchestration and state hash.
// Store, commands, personnel and payroll implementations live in sibling TUs.
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
            h = mix_scalar<uint8_t>(h, u.slot_core[(size_t)s]);
            h = mix_scalar<int8_t>(h, u.slot_min_quality[(size_t)s]);
            h = mix_scalar<int64_t>(h, u.slot_qty_per_100[(size_t)s]);
            h = mix_scalar<int32_t>(h, u.slot_power_weight_q16[(size_t)s]);
        }
        for (size_t k = 0; k < MILITARY_MAX_SUPPLY_CLASSES; ++k) {
            h = mix_scalar<int64_t>(h, u.idle_per_100_day[k]);
            h = mix_scalar<int64_t>(h, u.combat_per_100_day[k]);
        }
        // Physical repair recipe: a different recipe is a different catalog, so
        // an old PKMI is rejected instead of replaying demand it cannot satisfy.
        h = mix_scalar<uint64_t>(h, (uint64_t)u.repair_materials.size());
        for (const MilitaryRepairMaterial &mat : u.repair_materials) {
            h = mix_scalar<int32_t>(h, mat.good);
            h = mix_scalar<int64_t>(h, mat.rate_q32);
        }
    }
    // Water-crossing gates participate in the catalog identity: a catalog that
    // grants (or stops granting) a water tier is a different catalog.
    h = mix_scalar<int32_t>(h, c.water_lake_bit);
    h = mix_scalar<int32_t>(h, c.water_shallow_bit);
    h = mix_scalar<int32_t>(h, c.water_far_bit);
    h = mix_scalar<int32_t>(h, c.water_deep_bit);
    h = mix_scalar<uint64_t>(h, (uint64_t)c.categories.size());
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
        // Same rule as units: the repair recipe is part of the catalog identity.
        h = mix_scalar<uint64_t>(h, (uint64_t)b.repair_materials.size());
        for (const MilitaryRepairMaterial &mat : b.repair_materials) {
            h = mix_scalar<int32_t>(h, mat.good);
            h = mix_scalar<int64_t>(h, mat.rate_q32);
        }
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
    military_market_reuse_cancel(*this);
    _connected_valid = false;
    _md_day = -1;
    military_clear_supply_rings(*this);
    military_refresh_army_caches(*this);
    return true;
}

void MilitaryCore::reset_state() {
    military_market_reuse_cancel(*this);
    invalidate_engagement_members();
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
    _explorations.clear();
    _exploration_by_army.assign((size_t)MILITARY_MAX_ARMIES, -1);
    _exploration_daily_path_requests.clear();
    _exploration_observer_slot = -1;
    _exploration_explored_view.clear();
    _exploration_view_day = -1;
    _exploration_view_revision = 0;
    _exploration_trail.clear();
    _exploration_trail_stamp.clear();
    _exploration_trail_gen = 1;
    _training.clear();
    _stocks.clear();
    _shipments.clear();
    _purchase_orders.clear();
    _next_purchase_id = 1;
    _maint_rows.clear();
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
    military_clear_supply_rings(*this);
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
    _lot_garrison_lookup_complete = false;
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

// ============================================================== step_day
#include "military_core_section_day.inc"

// ============================================================== hash

#include "military_core_section_state_hash.inc"

} // namespace pk
