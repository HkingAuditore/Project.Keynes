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
        _front_edge_pos.clear();
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
    if ((size_t)_exploration_daily_path_requests.size() < _policies.size()) {
        _exploration_daily_path_requests.resize(_policies.size(), 0);
    }
    for (int32_t &n : _exploration_daily_path_requests) n = 0;

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
    // Reconcile against the committed Economy view before applying today's
    // commands.  In particular, an army.create must board the post-reconcile
    // garrison lots after natural Economy-side deaths have been observed.
    reconcile_receipts(receipts);
    reconcile_soldier_roster(view);
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
    // Exploration plans after today's commands land and before movement, using
    // the frozen explored snapshot the host pushed on the day boundary.
    prepare_exploration_day(view);
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
    run_wars_prepared(view, intents);
    // Battles can open or close; resume only tasks whose army is no longer
    // engaged. The next day's prepare revalidates every route.
    settle_exploration_day();
    lap(10);
    // Order matters (design S4-1): payroll claims cash first, then the
    // maintenance channel, then general procurement. All three clip against the
    // same frozen treasury snapshot, so emitting payroll first is what makes the
    // D+1 batch fund the soldiers before it funds goods.
    {
        MilitaryMarketDayReuse market_reuse(*this, view);
        run_wages_and_upkeep(view, intents);
        run_maintenance(view, intents);
        run_procurement(view, intents);
        lap(11);
        run_convoys(view, intents);
        lap(12);
        run_consumption(view, intents);
        lap(13);
        run_requisition(view, intents);
    } // Return parked capacities and end the borrowed view before later passes.
    lap(14);
    update_morale_org(view);
    lap(15);
    // Payroll already ran at the top of the day (design S4-1); the lap stays so
    // the stage index/name table keeps its shape for the perf log.
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
    // Physical maintenance (design S3/S4): a country whose only work is keeping
    // its buildings repaired, or waiting on a paid purchase, must still step -
    // otherwise the maintenance pass never runs and the orders never settle.
    if (!_maint_rows.empty() || !_purchase_orders.empty()) return true;
    if (has_exploration_work()) return true;
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
    // Empty tables add nothing, so a world that never used auto-exploration
    // keeps exactly the pre-v4 hash. Non-empty rows are hashed in table order
    // (the same order PKMI writes), including terminal rows.
    if (!_explorations.empty()) {
        h = mix_scalar<uint64_t>(h, (uint64_t)_explorations.size());
        for (const MilitaryExplorationTask &task : _explorations) {
            h = mix_scalar<uint8_t>(h, task.active ? 1 : 0);
            h = mix_scalar<int32_t>(h, task.row_index);
            h = mix_scalar<uint64_t>(h, task.army_handle);
            h = mix_scalar<int32_t>(h, task.owner_slot);
            h = mix_scalar<uint64_t>(h, task.owner_handle);
            h = mix_scalar<int32_t>(h, task.origin_cell);
            h = mix_scalar<int32_t>(h, task.return_cell);
            h = mix_scalar<int32_t>(h, task.anchor_cell);
            h = mix_scalar<int32_t>(h, task.radius);
            h = mix_scalar<int32_t>(h, task.selected_count);
            for (int32_t i = 0; i < task.selected_count; ++i)
                h = mix_scalar<int32_t>(h, task.selected_cells[(size_t)i]);
            for (int32_t w = 0; w < 4; ++w) {
                h = mix_scalar<uint64_t>(h, task.seen_mask[(size_t)w]);
                h = mix_scalar<uint64_t>(h, task.visited_mask[(size_t)w]);
                h = mix_scalar<uint64_t>(h, task.blocked_mask[(size_t)w]);
            }
            h = mix_scalar<uint8_t>(h, task.phase);
            h = mix_scalar<uint8_t>(h, task.pause_reason);
            h = mix_scalar<uint8_t>(h, task.result);
            h = mix_scalar<uint8_t>(h, task.resume_phase);
            h = mix_scalar<int32_t>(h, task.focus_index);
            h = mix_scalar<int32_t>(h, task.current_observation_cell);
            h = mix_scalar<int32_t>(h, task.observer_tries);
            for (int32_t v : task.reached_observer_cells)
                h = mix_scalar<int32_t>(h, v);
            h = mix_scalar<uint32_t>(h, task.tried_observer_mask);
            h = mix_scalar<int64_t>(h, task.started_day);
            h = mix_scalar<int64_t>(h, task.last_progress_day);
            h = mix_scalar<int64_t>(h, task.last_plan_day);
            h = mix_scalar<int64_t>(h, task.complete_day);
            h = mix_scalar<uint8_t>(h, task.return_fallback);
        }
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
        h = mix_scalar<int32_t>(h, _lots.kit_q16[i]);
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
        for (int8_t quality : o.slot_delivered_quality)
            h = mix_scalar<int8_t>(h, quality);
        h = mix_scalar<int16_t>(h, o.delivered_quality_q8);
        h = mix_scalar<uint64_t>(h, o.equipped_slot_mask);
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
    // Paid-but-unsettled purchases are state: the request identity and the
    // destination decide who receives the goods when the fill receipt lands, so
    // two runs that differ here are not the same world. An empty table adds
    // nothing beyond the sentinels, so a world that never buys keeps the shape
    // of its previous hash.
    h = mix_scalar<int32_t>(h, _next_purchase_id);
    h = mix_scalar<uint64_t>(h, (uint64_t)_purchase_orders.size());
    for (const MilitaryPurchaseOrder &o : _purchase_orders) {
        h = mix_scalar<uint16_t>(h, o.intent.kind);
        h = mix_scalar<int32_t>(h, o.intent.cell);
        h = mix_scalar<int32_t>(h, o.intent.good);
        h = mix_scalar<uint64_t>(h, o.intent.country_a);
        h = mix_scalar<int64_t>(h, o.intent.count);
        h = mix_scalar<int64_t>(h, o.intent.amount);
        h = mix_scalar<uint64_t>(h, o.intent.source_id);
        h = mix_scalar<uint8_t>(h, o.channel);
        h = mix_scalar<int32_t>(h, o.destination_cell);
        h = mix_scalar<uint8_t>(h, o.dest_kind);
        h = mix_scalar<int32_t>(h, o.dest);
        h = mix_scalar<uint64_t>(h, o.dest_handle);
        h = mix_scalar<int32_t>(h, o.stock_good);
        h = mix_scalar<int32_t>(h, o.real_good);
        h = mix_scalar<int32_t>(h, o.category);
        h = mix_scalar<int8_t>(h, o.quality);
        h = mix_scalar<int32_t>(h, o.route_cost_q16);
        h = mix_scalar<int32_t>(h, o.days);
    }
    // Maintenance objects: the carry, the window and the verdict are state, so
    // two runs that differ here are different worlds. A world with no state
    // buildings or soldiers adds only the sentinel.
    h = mix_scalar<uint64_t>(h, (uint64_t)_maint_rows.size());
    for (const MilitaryMaintenanceRow &r : _maint_rows) {
        h = mix_scalar<uint8_t>(h, r.kind);
        h = mix_scalar<int32_t>(h, r.country_slot);
        h = mix_scalar<int32_t>(h, r.cell);
        h = mix_scalar<int32_t>(h, r.object_id);
        h = mix_scalar<uint8_t>(h, r.holder_kind);
        h = mix_scalar<int32_t>(h, r.holder);
        h = mix_scalar<int32_t>(h, r.units);
        for (int32_t m = 0; m < MILITARY_MAX_REPAIR_MATERIALS; ++m)
            h = mix_scalar<int64_t>(h, r.acc_q32[m]);
        h = mix_scalar<int64_t>(h, r.window_need);
        h = mix_scalar<int64_t>(h, r.window_met);
        h = mix_scalar<int32_t>(h, r.window_days);
        h = mix_scalar<int32_t>(h, r.ratio_bp);
        h = mix_scalar<uint8_t>(h, r.disrepair);
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
