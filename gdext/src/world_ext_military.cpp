// Military bridge (owner: B). Godot <-> pk::MilitaryCore.
//
// Authority: Military is a main-thread synchronous runtime (contract §0.1). It
// reads the COMMITTED day-D view of Country and Economy, mutates ONLY its own
// store, and emits intent rows that are submitted to Country/Economy through
// their existing command batches with effective day D+1. Receipts come back the
// next military day. Military never writes another domain's state directly.
//
// ---------------------------------------------------------------------------
// `configure_military(catalog, seed)` — catalog keys (contract §3)
// ---------------------------------------------------------------------------
// The GDScript `MilitaryCatalogCompiler` has already resolved every stable
// string id to a dense id and sorted `units` by stable id, so this file only
// converts scales:
//
//   schema                : int, must be 1
//   militia_unit_index    : int, optional; fallback for the militia lookup
//   units[]               : Array[Dictionary]
//       id                : String  (stable id, ascending; PKMI identity)
//       class             : int     0 line, 1 mobile, 2 artillery
//       militia           : bool    exactly one unit must be true
//       era               : int     0..10
//       unlock_bit        : int     index into unlock_tech_ids, -1 = always
//       attack, defense, speed, fortification_ignore : float
//                         -> q16 (65536 == 1.0; fortification_ignore 0..1)
//       training_days     : int
//       equipment[]       : Array[Dictionary] (max 4)
//           category      : int      dense equipment category index
//           min_quality   : int      1..5
//           per_100       : float    goods units per 100 heads -> GOODS_SCALE
//           weight        : float    -> q16 power weight
//       supply_idle       : PackedFloat32Array(6), goods per 100 heads / day
//       supply_combat     : PackedFloat32Array(6), extra goods per 100 / day
//         index order (ABI): 0 ration, 1 fodder, 2 ammunition, 3 fuel,
//                            4 upkeep, 5 equipment
//         -> MILITARY_GOODS_SCALE per 100 heads per day
//   categories[]          : Array[Dictionary]
//       id                : String
//       goods             : PackedInt32Array   dense good ids, quality asc
//       qualities         : PackedInt32Array   matching 1..5 quality levels
//   state_buildings[]     : Array[Dictionary]
//       id, economy_building_id (dense type, -1 unknown), role (0 barracks,
//       1 fortification, 2 war_college), tier, unlock_bit, capacity,
//       fort_bonus (float -> q16), training_speed (float -> q16),
//       upkeep (money/day -> MONEY_SCALE), build_days,
//       material_goods (PackedInt32Array), material_qty (PackedInt64Array,
//       GOODS_SCALE, parallel)
//   supply_goods          : Array(6) of PackedInt32Array (dense good ids)
//   supply_yield_q16      : Array(6) of PackedInt32Array (q16 per unit good)
//   unlock_tech_ids       : PackedInt32Array (dense technology id per bit)
//   economy_good_count    : int
//   soldier_profession_id : int
//   unemployed_profession_id : int
//   ration_need_per_head  : float need units per head/day -> q16
//
// `set_military_terrain` keys: cell_count, width, height, neighbors
// (PackedInt32Array, cell_count * 6), landform, vegetation, cover, is_water,
// has_river, settlement_tier (PackedByteArray per cell).
//
// Command `op` strings: kMilitaryOps below. Each row may also carry
// `int_pairs` (PackedInt32Array of (unit, count) pairs) as the facade's
// pre-normalized form of `units`.
// ---------------------------------------------------------------------------

#include "world_ext.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "military_core.h"
#include "modifier_runtime.h"
#include "native_simulation_host.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace pk {

using namespace godot;

namespace {

// --------------------------------------------------------------- scales

constexpr int32_t MILITARY_Q = MILITARY_Q16;
constexpr int64_t MILITARY_MONEY = MILITARY_MONEY_SCALE;
constexpr int64_t MILITARY_GOODS = MILITARY_GOODS_SCALE;
constexpr int32_t MILITARY_SUPPLY_CLASSES = MILITARY_MAX_SUPPLY_CLASSES;

int32_t q16_from_float(double value) {
    if (!std::isfinite(value)) return 0;
    const double scaled = value * static_cast<double>(MILITARY_Q);
    if (scaled >= static_cast<double>(std::numeric_limits<int32_t>::max()))
        return std::numeric_limits<int32_t>::max();
    if (scaled <= static_cast<double>(std::numeric_limits<int32_t>::min()))
        return std::numeric_limits<int32_t>::min();
    return static_cast<int32_t>(std::llround(scaled));
}

int64_t goods_from_units(double value) {
    if (!std::isfinite(value) || value <= 0.0) return 0;
    const double scaled = value * static_cast<double>(MILITARY_GOODS);
    if (scaled >= static_cast<double>(std::numeric_limits<int64_t>::max()))
        return std::numeric_limits<int64_t>::max();
    return static_cast<int64_t>(std::llround(scaled));
}

int64_t money_from_units(double value) {
    if (!std::isfinite(value) || value <= 0.0) return 0;
    const double scaled = value * static_cast<double>(MILITARY_MONEY);
    if (scaled >= static_cast<double>(std::numeric_limits<int64_t>::max()))
        return std::numeric_limits<int64_t>::max();
    return static_cast<int64_t>(std::llround(scaled));
}

// --------------------------------------------------------------- dictionary helpers

int64_t dict_i64(const Dictionary &d, const char *key, int64_t fallback) {
    if (!d.has(key)) return fallback;
    const Variant v = d[key];
    switch (v.get_type()) {
    case Variant::INT: return static_cast<int64_t>(v);
    case Variant::FLOAT: return static_cast<int64_t>(static_cast<double>(v));
    case Variant::BOOL: return static_cast<bool>(v) ? 1 : 0;
    default: return fallback;
    }
}

int32_t dict_i32(const Dictionary &d, const char *key, int32_t fallback) {
    return static_cast<int32_t>(dict_i64(d, key, fallback));
}

bool dict_bool(const Dictionary &d, const char *key, bool fallback) {
    return dict_i64(d, key, fallback ? 1 : 0) != 0;
}

double dict_f64(const Dictionary &d, const char *key, double fallback) {
    if (!d.has(key)) return fallback;
    const Variant v = d[key];
    switch (v.get_type()) {
    case Variant::FLOAT: return static_cast<double>(v);
    case Variant::INT: return static_cast<double>(static_cast<int64_t>(v));
    case Variant::BOOL: return static_cast<bool>(v) ? 1.0 : 0.0;
    default: return fallback;
    }
}

std::string dict_string(const Dictionary &d, const char *key) {
    if (!d.has(key)) return std::string();
    const CharString utf8 = String(d[key]).utf8();
    return std::string(utf8.get_data());
}

std::vector<int32_t> dict_i32_array(const Dictionary &d, const char *key) {
    std::vector<int32_t> out;
    if (!d.has(key)) return out;
    const Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
        const PackedInt32Array packed = v;
        out.resize(static_cast<size_t>(packed.size()));
        if (!out.empty())
            std::memcpy(out.data(), packed.ptr(), out.size() * sizeof(int32_t));
    } else if (v.get_type() == Variant::ARRAY) {
        const Array array = v;
        out.reserve(static_cast<size_t>(array.size()));
        for (int64_t i = 0; i < array.size(); ++i)
            out.push_back(static_cast<int32_t>(static_cast<int64_t>(array[i])));
    }
    return out;
}

std::vector<int64_t> dict_i64_array(const Dictionary &d, const char *key) {
    std::vector<int64_t> out;
    if (!d.has(key)) return out;
    const Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT64_ARRAY) {
        const PackedInt64Array packed = v;
        out.resize(static_cast<size_t>(packed.size()));
        if (!out.empty())
            std::memcpy(out.data(), packed.ptr(), out.size() * sizeof(int64_t));
    } else if (v.get_type() == Variant::ARRAY) {
        const Array array = v;
        out.reserve(static_cast<size_t>(array.size()));
        for (int64_t i = 0; i < array.size(); ++i)
            out.push_back(static_cast<int64_t>(array[i]));
    }
    return out;
}

std::vector<uint8_t> dict_u8_array(const Dictionary &d, const char *key) {
    std::vector<uint8_t> out;
    if (!d.has(key)) return out;
    const Variant v = d[key];
    if (v.get_type() == Variant::PACKED_BYTE_ARRAY) {
        const PackedByteArray packed = v;
        out.resize(static_cast<size_t>(packed.size()));
        if (!out.empty()) std::memcpy(out.data(), packed.ptr(), out.size());
    } else if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
        const PackedInt32Array packed = v;
        out.resize(static_cast<size_t>(packed.size()));
        for (int64_t i = 0; i < packed.size(); ++i)
            out[static_cast<size_t>(i)] = static_cast<uint8_t>(packed[i] & 0xFF);
    }
    return out;
}

Dictionary military_fail(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = String(reason);
    return out;
}

Dictionary military_unavailable() { return military_fail("military_unavailable"); }

MilitaryCore *core_from(void *opaque) { return static_cast<MilitaryCore *>(opaque); }
const MilitaryCore *core_from(const void *opaque) {
    return static_cast<const MilitaryCore *>(opaque);
}

// --------------------------------------------------------------- op table

struct MilitaryOpName {
    const char *name;
    uint16_t op;
};

const MilitaryOpName kMilitaryOps[] = {
    {"force.set_target", MCMD_FORCE_SET_TARGET},
    {"force.set_levy", MCMD_FORCE_SET_LEVY},
    {"force.set_auto_discharge", MCMD_FORCE_SET_AUTO_DISCHARGE},
    {"config.set", MCMD_CONFIG_SET},
    {"config.set_quality_policy", MCMD_CONFIG_SET_QUALITY_POLICY},
    {"config.auto_retrain", MCMD_CONFIG_AUTO_RETRAIN},
    {"barracks.pause", MCMD_BARRACKS_PAUSE},
    {"train", MCMD_TRAIN},
    {"state.build", MCMD_STATE_BUILD},
    {"state.demolish", MCMD_STATE_DEMOLISH},
    {"policy.set_wage", MCMD_POLICY_SET_WAGE},
    {"policy.set_procurement", MCMD_POLICY_SET_PROCUREMENT},
    {"policy.set_budget", MCMD_POLICY_SET_BUDGET},
    {"army.create", MCMD_ARMY_CREATE},
    {"army.station", MCMD_ARMY_STATION},
    {"army.transfer", MCMD_ARMY_TRANSFER},
    {"army.merge", MCMD_ARMY_MERGE},
    {"army.split", MCMD_ARMY_SPLIT},
    {"army.set_template", MCMD_ARMY_SET_TEMPLATE},
    {"army.reinforce", MCMD_ARMY_REINFORCE},
    {"army.move", MCMD_ARMY_MOVE},
    {"army.area_control", MCMD_ARMY_AREA_CONTROL},
    {"army.stop", MCMD_ARMY_STOP},
    {"army.stance", MCMD_ARMY_STANCE},
    {"army.rename", MCMD_ARMY_RENAME},
    {"army.disband", MCMD_ARMY_DISBAND},
    {"war.declare", MCMD_WAR_DECLARE},
    {"peace.propose", MCMD_PEACE_PROPOSE},
    {"peace.respond", MCMD_PEACE_RESPOND},
};

uint16_t op_from_name(const String &name) {
    const CharString utf8 = name.utf8();
    const char *text = utf8.get_data();
    for (const MilitaryOpName &entry : kMilitaryOps) {
        if (std::strcmp(entry.name, text) == 0) return entry.op;
    }
    return MCMD_NONE;
}

// Peace term encoding shared by peace.propose / peace.respond /
// evaluate_military_peace. `ints` receives (kind, a, b) triples and `longs` one
// amount per term, matching MilitaryCommand's layout.
struct MilitaryTermName {
    const char *name;
    int32_t kind;
};

const MilitaryTermName kMilitaryTerms[] = {
    {"white", MPEACE_WHITE},
    {"cede", MPEACE_CEDE_CELL},
    {"annex", MPEACE_ANNEX},
    {"lump_sum", MPEACE_LUMP_SUM},
    {"installments", MPEACE_INSTALLMENTS},
    {"goods", MPEACE_GOODS},
    {"return", MPEACE_RETURN_OCCUPATION},
};

bool encode_peace_terms(const Array &terms, std::vector<int32_t> &ints,
                        std::vector<int64_t> &longs, std::string &error) {
    ints.clear();
    longs.clear();
    ints.reserve(static_cast<size_t>(terms.size()) * 3);
    longs.reserve(static_cast<size_t>(terms.size()));
    for (int64_t i = 0; i < terms.size(); ++i) {
        if (terms[i].get_type() != Variant::DICTIONARY) {
            error = "military_peace_term_invalid";
            return false;
        }
        const Dictionary term = terms[i];
        const std::string kind_name = dict_string(term, "kind");
        int32_t kind = -1;
        for (const MilitaryTermName &entry : kMilitaryTerms) {
            if (kind_name == entry.name) {
                kind = entry.kind;
                break;
            }
        }
        if (kind < 0) {
            error = "military_peace_term_kind_invalid";
            return false;
        }
        const int32_t cell = dict_i32(term, "cell", -1);
        const int32_t n = dict_i32(term, "n", 0);
        const int32_t good = dict_i32(term, "good", -1);
        // `amount` is authored in game money / goods units, not scaled ints.
        const double amount_units = dict_f64(term, "amount", 0.0);
        int64_t amount = 0;
        switch (kind) {
        case MPEACE_LUMP_SUM:
            amount = money_from_units(amount_units);
            ints.push_back(kind); ints.push_back(0); ints.push_back(0);
            break;
        case MPEACE_INSTALLMENTS:
            amount = money_from_units(amount_units);
            ints.push_back(kind); ints.push_back(std::max(0, n)); ints.push_back(0);
            break;
        case MPEACE_GOODS:
            amount = goods_from_units(amount_units);
            ints.push_back(kind); ints.push_back(good); ints.push_back(0);
            break;
        case MPEACE_CEDE_CELL:
        case MPEACE_RETURN_OCCUPATION:
            ints.push_back(kind); ints.push_back(cell); ints.push_back(0);
            break;
        default:
            ints.push_back(kind); ints.push_back(0); ints.push_back(0);
            break;
        }
        longs.push_back(amount);
    }
    return true;
}

// --------------------------------------------------------------- catalog

bool parse_unit(const Dictionary &row, MilitaryUnitType &unit, std::string &error) {
    unit.id = dict_string(row, "id");
    if (unit.id.empty()) {
        error = "military_unit_id_missing";
        return false;
    }
    unit.unit_class = static_cast<uint8_t>(
        std::clamp<int32_t>(dict_i32(row, "class", 0), 0, 2));
    unit.is_default_militia = dict_bool(row, "militia", false) ? 1 : 0;
    unit.era_index = static_cast<int8_t>(
        std::clamp<int32_t>(dict_i32(row, "era", 0), 0, 10));
    unit.unlock_bit = dict_i32(row, "unlock_bit", -1);
    unit.attack_q16 = q16_from_float(dict_f64(row, "attack", 1.0));
    unit.defense_q16 = q16_from_float(dict_f64(row, "defense", 1.0));
    unit.speed_q16 = q16_from_float(dict_f64(row, "speed", 1.0));
    unit.fortification_ignore_q16 =
        q16_from_float(std::clamp(dict_f64(row, "fortification_ignore", 0.0), 0.0, 1.0));
    unit.training_days = std::max(1, dict_i32(row, "training_days", 30));
    if (row.has("equipment") && row["equipment"].get_type() == Variant::ARRAY) {
        const Array equipment = row["equipment"];
        const int64_t slots =
            std::min<int64_t>(equipment.size(), MILITARY_MAX_EQUIP_SLOTS);
        unit.slot_count = static_cast<int32_t>(slots);
        for (int64_t s = 0; s < slots; ++s) {
            if (equipment[s].get_type() != Variant::DICTIONARY) continue;
            const Dictionary slot = equipment[s];
            const size_t lane = static_cast<size_t>(s);
            unit.slot_category[lane] = std::max(0, dict_i32(slot, "category", -1));
            unit.slot_min_quality[lane] = static_cast<int8_t>(
                std::clamp<int32_t>(dict_i32(slot, "min_quality", 1), 1, 5));
            unit.slot_qty_per_100[lane] =
                goods_from_units(dict_f64(slot, "per_100", 0.0));
            unit.slot_power_weight_q16[lane] =
                q16_from_float(dict_f64(slot, "weight", 1.0));
        }
    }
    for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
        const size_t lane = static_cast<size_t>(cls);
        unit.idle_per_100_day[lane] = 0;
        unit.combat_per_100_day[lane] = 0;
    }
    const auto read_supply = [&row](const char *key,
            std::array<int64_t, MILITARY_MAX_SUPPLY_CLASSES> &out) {
        if (!row.has(key)) return;
        const Variant v = row[key];
        if (v.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
            const PackedFloat32Array packed = v;
            const int64_t n = std::min<int64_t>(packed.size(), MILITARY_SUPPLY_CLASSES);
            for (int64_t i = 0; i < n; ++i)
                out[static_cast<size_t>(i)] =
                    goods_from_units(static_cast<double>(packed[i]));
        } else if (v.get_type() == Variant::PACKED_FLOAT64_ARRAY) {
            const PackedFloat64Array packed = v;
            const int64_t n = std::min<int64_t>(packed.size(), MILITARY_SUPPLY_CLASSES);
            for (int64_t i = 0; i < n; ++i)
                out[static_cast<size_t>(i)] = goods_from_units(packed[i]);
        } else if (v.get_type() == Variant::ARRAY) {
            const Array array = v;
            const int64_t n = std::min<int64_t>(array.size(), MILITARY_SUPPLY_CLASSES);
            for (int64_t i = 0; i < n; ++i)
                out[static_cast<size_t>(i)] =
                    goods_from_units(static_cast<double>(array[i]));
        }
    };
    read_supply("supply_idle", unit.idle_per_100_day);
    read_supply("supply_combat", unit.combat_per_100_day);
    return true;
}

bool parse_catalog(const Dictionary &catalog, MilitaryCatalog &out, std::string &error) {
    const Variant units_value = catalog.get("units", Array());
    if (units_value.get_type() != Variant::ARRAY) {
        error = "military_units_invalid";
        return false;
    }
    const Array units = units_value;
    if (units.is_empty()) {
        error = "military_units_empty";
        return false;
    }
    if (units.size() > MILITARY_MAX_UNIT_TYPES) {
        error = "military_unit_count_exceeds_cap";
        return false;
    }
    out.units.clear();
    out.units.reserve(static_cast<size_t>(units.size()));
    for (int64_t i = 0; i < units.size(); ++i) {
        if (units[i].get_type() != Variant::DICTIONARY) {
            error = "military_unit_not_object";
            return false;
        }
        MilitaryUnitType unit;
        if (!parse_unit(units[i], unit, error)) return false;
        out.units.push_back(std::move(unit));
    }
    // The compiler emits units in stable-id order; sorting again is cheap and
    // makes a hand-built catalog (tests) behave identically.
    std::sort(out.units.begin(), out.units.end(),
        [](const MilitaryUnitType &a, const MilitaryUnitType &b) { return a.id < b.id; });
    out.militia_unit = -1;
    for (size_t i = 0; i < out.units.size(); ++i) {
        if (!out.units[i].is_default_militia) continue;
        if (out.militia_unit >= 0) {
            error = "military_militia_unit_count_invalid";
            return false;
        }
        out.militia_unit = static_cast<int32_t>(i);
    }
    if (out.militia_unit < 0) {
        error = "military_militia_unit_missing";
        return false;
    }
    // Equipment categories.
    out.categories.clear();
    if (catalog.has("categories") && catalog["categories"].get_type() == Variant::ARRAY) {
        const Array categories = catalog["categories"];
        out.categories.reserve(static_cast<size_t>(categories.size()));
        for (int64_t i = 0; i < categories.size(); ++i) {
            if (categories[i].get_type() != Variant::DICTIONARY) {
                error = "military_equipment_category_not_object";
                return false;
            }
            const Dictionary row = categories[i];
            MilitaryEquipCategory category;
            category.id = dict_string(row, "id");
            category.good_ids = dict_i32_array(row, "goods");
            const std::vector<int32_t> qualities = dict_i32_array(row, "qualities");
            category.good_quality.assign(category.good_ids.size(), 1);
            for (size_t k = 0; k < category.good_quality.size() && k < qualities.size(); ++k)
                category.good_quality[k] = static_cast<int8_t>(
                    std::clamp<int32_t>(qualities[k], 1, 5));
            out.categories.push_back(std::move(category));
        }
    }
    // State buildings.
    out.state_buildings.clear();
    if (catalog.has("state_buildings") &&
        catalog["state_buildings"].get_type() == Variant::ARRAY) {
        const Array buildings = catalog["state_buildings"];
        out.state_buildings.reserve(static_cast<size_t>(buildings.size()));
        for (int64_t i = 0; i < buildings.size(); ++i) {
            if (buildings[i].get_type() != Variant::DICTIONARY) {
                error = "military_state_building_not_object";
                return false;
            }
            const Dictionary row = buildings[i];
            MilitaryStateBuilding building;
            building.id = dict_string(row, "id");
            building.economy_building_id = dict_i32(row, "economy_building_id", -1);
            building.role = static_cast<uint8_t>(
                std::clamp<int32_t>(dict_i32(row, "role", 0), 0, 2));
            building.tier = static_cast<int8_t>(
                std::clamp<int32_t>(dict_i32(row, "tier", 0), 0, 7));
            building.unlock_bit = dict_i32(row, "unlock_bit", -1);
            building.capacity = std::max(0, dict_i32(row, "capacity", 0));
            building.fort_bonus_q16 = q16_from_float(dict_f64(row, "fort_bonus", 0.0));
            building.training_speed_q16 =
                q16_from_float(dict_f64(row, "training_speed", 1.0));
            building.upkeep_per_day = money_from_units(dict_f64(row, "upkeep", 0.0));
            building.build_days = std::max(0, dict_i32(row, "build_days", 0));
            building.material_goods = dict_i32_array(row, "material_goods");
            building.material_qty = dict_i64_array(row, "material_qty");
            if (building.material_qty.size() < building.material_goods.size())
                building.material_qty.resize(building.material_goods.size(), 0);
            out.state_buildings.push_back(std::move(building));
        }
    }
    // Supply candidate tables: Array(6) of PackedInt32Array, parallel yields.
    for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
        out.supply_goods[static_cast<size_t>(cls)].clear();
        out.supply_yield_q16[static_cast<size_t>(cls)].clear();
    }
    if (catalog.has("supply_goods") && catalog["supply_goods"].get_type() == Variant::ARRAY) {
        const Array rows = catalog["supply_goods"];
        Array yield_rows;
        if (catalog.has("supply_yield_q16") &&
            catalog["supply_yield_q16"].get_type() == Variant::ARRAY)
            yield_rows = catalog["supply_yield_q16"];
        for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES && cls < rows.size(); ++cls) {
            if (rows[cls].get_type() != Variant::PACKED_INT32_ARRAY) continue;
            const PackedInt32Array packed = rows[cls];
            const size_t lane = static_cast<size_t>(cls);
            out.supply_goods[lane].resize(static_cast<size_t>(packed.size()));
            if (!packed.is_empty())
                std::memcpy(out.supply_goods[lane].data(), packed.ptr(),
                            static_cast<size_t>(packed.size()) * sizeof(int32_t));
            // Yields default to 1.0 when the compiler omitted the row.
            out.supply_yield_q16[lane].assign(static_cast<size_t>(packed.size()), MILITARY_Q);
            if (cls < yield_rows.size() &&
                yield_rows[cls].get_type() == Variant::PACKED_INT32_ARRAY) {
                const PackedInt32Array yields = yield_rows[cls];
                const int64_t n = std::min<int64_t>(yields.size(), packed.size());
                for (int64_t i = 0; i < n; ++i)
                    out.supply_yield_q16[lane][static_cast<size_t>(i)] =
                        std::max<int32_t>(1, yields[i]);
            }
        }
    }
    out.unlock_count = static_cast<int32_t>(dict_i32_array(catalog, "unlock_tech_ids").size());
    out.economy_good_count = std::max(0, dict_i32(catalog, "economy_good_count", 0));
    out.ration_need_per_head_q16 = std::max<int32_t>(
        1, q16_from_float(dict_f64(catalog, "ration_need_per_head", 1.0)));
    // Naval transport gates (contract-2 §2.2): resolved by MilitaryCatalogCompiler
    // from the two transport technologies. -1 means the catalog has no such bit.
    out.coastal_transport_bit = dict_i32(catalog, "coastal_transport_bit", -1);
    out.ocean_transport_bit = dict_i32(catalog, "ocean_transport_bit", -1);
    return true;
}

// --------------------------------------------------------------- command parse

bool parse_military_command(const Dictionary &row, MilitaryCommand &command,
                            std::string &error) {
    if (!row.has("op")) {
        error = "military_command_op_missing";
        return false;
    }
    const uint16_t op = op_from_name(String(row["op"]));
    if (op == MCMD_NONE) {
        error = "military_command_op_unknown";
        return false;
    }
    command.op = op;
    command.country = static_cast<uint64_t>(dict_i64(row, "country", 0));
    command.army = static_cast<uint64_t>(dict_i64(row, "army", 0));
    command.other = static_cast<uint64_t>(dict_i64(row, "other", 0));
    command.cell = dict_i32(row, "cell", -1);
    command.radius =
        std::clamp(dict_i32(row, "radius", 0), 0, MILITARY_MAX_AREA_RADIUS);
    command.unit_from = dict_i32(row, "unit_from", -1);
    command.unit_to = dict_i32(row, "unit_to", -1);
    command.count = dict_i64(row, "count", 0);
    command.value = dict_i64(row, "value", 0);
    command.cells = dict_i32_array(row, "cells");
    // `units` arrives as Dictionary{dense unit id -> count}; the facade also
    // pre-normalizes it to `int_pairs` (unit, count) for cold callers.
    if (row.has("int_pairs")) {
        command.ints = dict_i32_array(row, "int_pairs");
    } else if (row.has("units") && row["units"].get_type() == Variant::DICTIONARY) {
        const Dictionary units = row["units"];
        const Array keys = units.keys();
        std::vector<int32_t> ids;
        ids.reserve(static_cast<size_t>(keys.size()));
        for (int64_t i = 0; i < keys.size(); ++i)
            ids.push_back(static_cast<int32_t>(static_cast<int64_t>(keys[i])));
        std::sort(ids.begin(), ids.end());
        command.ints.reserve(ids.size() * 2);
        for (const int32_t id : ids) {
            const String key = String::num_int64(id);
            const int64_t count = units.has(key) ? dict_i64(units, key.utf8().get_data(), 0)
                                                 : 0;
            command.ints.push_back(id);
            command.ints.push_back(static_cast<int32_t>(std::max<int64_t>(0, count)));
        }
    }
    const bool peace_op = op == MCMD_PEACE_PROPOSE || op == MCMD_PEACE_RESPOND;
    if (peace_op && row.has("terms") && row["terms"].get_type() == Variant::ARRAY) {
        if (!encode_peace_terms(row["terms"], command.ints, command.longs, error))
            return false;
    } else if (row.has("ints")) {
        // Explicit (kind, a, b) triples, used by tests and the AI.
        command.ints = dict_i32_array(row, "ints");
        command.longs = dict_i64_array(row, "longs");
    }
    if (op == MCMD_PEACE_PROPOSE && command.ints.empty()) {
        error = "military_peace_terms_missing";
        return false;
    }
    return true;
}

// --------------------------------------------------------------- digest

// Military statistics the core consumes (MilitaryStatId order, q16). The
// bridge reads real Modifier values when a Modifier runtime is attached and
// falls back to the design defaults otherwise, so a world without military
// content still simulates.
const char *const kMilitaryStatKeys[MSTAT_COUNT] = {
    "country.military.attack_factor",
    "country.military.defense_factor",
    "country.military.speed_factor",
    "country.military.logistics_move_factor",
    "country.military.supply_transport_factor",
    "country.military.supply_consumption_factor",
    "country.military.barracks_capacity_factor",
    "country.military.levy_rate",
    "country.military.wage_factor",
    "country.military.training_time_factor",
    "country.military.desertion_factor",
    "country.military.casualty_factor",
    "country.military.attrition_factor",
    "country.military.organization_recovery_factor",
    "country.military.morale_add",
    "country.military.fortification_factor",
    "country.military.frontage_factor",
    "country.military.militia_factor",
    "country.military.occupation_tax_efficiency",
    "country.military.naval_transport_factor",
    "country.military.vision_add",
    // Keys must match ModifierCatalog.TECHNOLOGY_STATS (modifier_catalog.gd).
    "country.military.convoy_escort_factor",
    "country.military.rule.mutual_support",
    "country.military.rule.last_stand",
    "country.military.rule.blitz",
    "country.military.rule.hold_the_line",
    "country.military.rule.encirclement",
    "country.military.rule.home_ground",
};

// Design §13 / §12.1 defaults in q16 for the stats whose base is not 1.0.
int32_t military_stat_default_q16(int32_t stat) {
    switch (stat) {
    case MSTAT_LEVY_RATE: return (MILITARY_Q * 3) / 100;  // 3% of cell population
    case MSTAT_WAGE: return (MILITARY_Q * 13) / 10;       // 1.3
    case MSTAT_OCCUPATION_TAX: return MILITARY_Q / 2;      // 0.5
    case MSTAT_MORALE_ADD:
    case MSTAT_VISION_ADD:
    case MSTAT_RULE_MUTUAL_SUPPORT:
    case MSTAT_RULE_LAST_STAND:
    case MSTAT_RULE_BLITZ:
    case MSTAT_RULE_HOLD_THE_LINE:
    case MSTAT_RULE_ENCIRCLEMENT:
    case MSTAT_RULE_HOME_GROUND: return 0;
    default: return MILITARY_Q;
    }
}

} // namespace

// ===========================================================================
// lifecycle
// ===========================================================================

Dictionary DCWorldExt::configure_military(const Dictionary &catalog, int64_t seed) {
    MilitaryCatalog parsed;
    std::string error;
    if (!parse_catalog(catalog, parsed, error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    if (_military_runtime == nullptr) _military_runtime = new MilitaryCore();
    MilitaryCore *core = core_from(_military_runtime);
    // A catalog reconfiguration must not lose the map: configure() resets the
    // state but keeps the previous terrain, so the same input is reinstalled.
    const MilitaryTerrainInput keep = core->terrain();
    if (!core->configure(std::move(parsed), static_cast<uint64_t>(seed), error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    // Dense technology id per unlock bit, captured once so the daily digest only
    // needs one has_technology() probe per referenced technology.
    _military_unlock_tech_ids = dict_i32_array(catalog, "unlock_tech_ids");
    if (keep.cell_count > 0) {
        std::string terrain_error;
        core->set_terrain(keep, terrain_error);
    }
    _military_last_step_day = -1;
    _military_sequence = 0;
    _military_pending_intents.clear();
    _military_forced_run_day = -1;
    _military_economy_event_cursor = -1;
    _military_economy_seen_day = -1;
    _military_render_selected_army = 0;
    if (_military_receipts) _military_receipts->after_request_id = 0;
    // Open a slot for every active country now, so commands submitted before
    // the first stepped military day resolve their issuing country.
    const int32_t countries_opened = ensure_military_country_slots();
    ++_military_render_revision;
    const MilitaryCatalog &configured = core->catalog();
    Dictionary out;
    out["ok"] = true;
    out["reason"] = String();
    out["countries_opened"] = static_cast<int64_t>(countries_opened);
    out["catalog_hash"] = static_cast<int64_t>(configured.hash);
    out["unit_count"] = static_cast<int64_t>(configured.units.size());
    out["category_count"] = static_cast<int64_t>(configured.categories.size());
    out["state_building_count"] = static_cast<int64_t>(configured.state_buildings.size());
    out["unlock_count"] = static_cast<int64_t>(configured.unlock_count);
    out["militia_unit"] = static_cast<int64_t>(configured.militia_unit);
    out["seed"] = seed;
    return out;
}

Dictionary DCWorldExt::set_military_terrain(const Dictionary &terrain) {
    if (_military_runtime == nullptr) return military_unavailable();
    MilitaryTerrainInput input;
    input.cell_count = dict_i32(terrain, "cell_count", -1);
    input.width = dict_i32(terrain, "width", 0);
    input.height = dict_i32(terrain, "height", 0);
    input.neighbors = dict_i32_array(terrain, "neighbors");
    input.landform = dict_u8_array(terrain, "landform");
    input.vegetation = dict_u8_array(terrain, "vegetation");
    input.cover = dict_u8_array(terrain, "cover");
    input.is_water = dict_u8_array(terrain, "is_water");
    input.has_river = dict_u8_array(terrain, "has_river");
    input.settlement_tier = dict_u8_array(terrain, "settlement_tier");
    std::string error;
    if (!core_from(_military_runtime)->set_terrain(std::move(input), error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    // Size the reusable digest lanes once per terrain, so the daily capture only
    // fills them and never allocates.
    const int32_t cells = std::max(0, core_from(_military_runtime)->terrain().cell_count);
    MilitaryDigestScratch &scratch = _military_digest_scratch;
    scratch.cell_population.assign(static_cast<size_t>(cells), 0);
    scratch.cell_unemployed.assign(static_cast<size_t>(cells), 0);
    scratch.cell_soldiers.assign(static_cast<size_t>(cells), 0);
    scratch.cell_has_merchant.assign(static_cast<size_t>(cells), 0);
    scratch.country_cash.clear();
    scratch.country_annual_revenue.clear();
    scratch.country_unlock_bits.clear();
    scratch.country_stat_q16.clear();
    ++_military_render_revision;
    Dictionary out;
    out["ok"] = true;
    out["reason"] = String();
    out["cell_count"] = static_cast<int64_t>(cells);
    out["width"] = static_cast<int64_t>(core_from(_military_runtime)->terrain().width);
    out["height"] = static_cast<int64_t>(core_from(_military_runtime)->terrain().height);
    return out;
}

bool DCWorldExt::military_should_run(int64_t day) const {
    if (_military_runtime == nullptr) return false;
    const MilitaryCore *core = core_from(_military_runtime);
    if (!core->configured()) return false;
    // One step per day and never backwards: re-running a day would submit its
    // D+1 intents twice.
    if (day <= _military_last_step_day) return false;
    // A submitted command must always get its day stepped, even when the core
    // would otherwise idle (no policy yet -> should_run false -> deadlock).
    if (_military_forced_run_day >= 0 && day >= _military_forced_run_day) return true;
    // Outstanding bridge rows (a POD population move, a treasury spend awaiting
    // its receipt) can only be settled inside a military day. If the core looks
    // idle while a row is still open, refusing to step deadlocks the row forever
    // (observed: last_step_day frozen at 70 while pending_intents stayed 3).
    for (const MilitaryPendingIntent &row : _military_pending_intents) {
        if (row.receipt_pending == 1) return true;
    }
    return core->should_run(day);
}

int32_t DCWorldExt::ensure_military_country_slots() {
    if (_military_runtime == nullptr || _country_runtime == nullptr) return 0;
    NativeCountryRuntime *country = static_cast<NativeCountryRuntime *>(_country_runtime);
    NativeCountryRuntime::EconomySnapshot snapshot;
    if (!country->copy_economy_snapshot(snapshot)) return 0;
    MilitaryCore *core = core_from(_military_runtime);
    int32_t active = 0;
    for (size_t slot = 0; slot < snapshot.country_handles.size(); ++slot) {
        const uint64_t handle = snapshot.country_handles[slot];
        if (handle == 0) continue;
        core->ensure_country_slot(handle);
        ++active;
    }
    return active;
}

// ===========================================================================
// digest capture (day D committed Country + Economy)
// ===========================================================================

void DCWorldExt::capture_military_digest(MilitaryWorldDigest &digest,
                                         MilitaryDigestScratch &scratch,
                                         const MilitaryCatalog &catalog,
                                         bool *economy_ready) {
    if (economy_ready != nullptr) *economy_ready = false;
    const int32_t cells = std::max(0, core_from(_military_runtime)->terrain().cell_count);
    digest.day = -1;
    // The digest object is reused across days, so the state building lanes must
    // be reset up front: an economy read that fails below must not leave
    // yesterday's rows in place, because the core would rebuild its cache from
    // stale ledger data instead of keeping what the save restored.
    digest.state_lanes_present = false;
    digest.state_lane_rows = 0;
    // ---- Country: one pinned committed projection ----
    int32_t country_count = 0;
    std::vector<int64_t> cash(std::max<size_t>(scratch.country_cash.size(), 1), 0);
    std::vector<int32_t> owner;
    std::vector<uint64_t> handles;
    if (_country_runtime != nullptr) {
        NativeCountryRuntime *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        NativeCountryRuntime::EconomySnapshot snapshot;
        if (country->copy_economy_snapshot(snapshot)) {
            country_count = snapshot.country_count;
            owner = std::move(snapshot.cell_country_slot);
            handles = std::move(snapshot.country_handles);
            cash.assign(static_cast<size_t>(country_count), 0);
            for (int32_t slot = 0; slot < country_count; ++slot)
                cash[static_cast<size_t>(slot)] = country->cash_for_slot(slot);
        }
    }
    if (owner.size() < static_cast<size_t>(cells)) owner.resize(static_cast<size_t>(cells), -1);
    if (owner.size() > static_cast<size_t>(cells)) owner.resize(static_cast<size_t>(cells));
    // Military stores policy rows by slot, and a slot only exists once the core
    // has seen the handle. Open one per active country here, in slot order, so
    // `submit()` (which rejects unknown countries) and the policy queries below
    // agree with the digest rows. Idempotent: existing slots keep their state.
    MilitaryCore *core = core_from(_military_runtime);
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const uint64_t handle = static_cast<size_t>(slot) < handles.size()
            ? handles[static_cast<size_t>(slot)] : 0;
        if (handle == 0) continue;
        core->ensure_country_slot(handle);
    }
    digest.cell_owner_slot = std::move(owner);
    digest.country_capacity = country_count;
    digest.country_handle = std::move(handles);
    digest.country_cash = std::move(cash);
    digest.country_era.assign(static_cast<size_t>(country_count), 0);
    digest.country_annual_revenue.assign(static_cast<size_t>(country_count), 0);
    digest.country_capital_cell.assign(static_cast<size_t>(country_count), -1);
    digest.country_soldier_living_cost.assign(static_cast<size_t>(country_count), 0);
    // ---- Economy: dense per-cell lanes + sparse military-supply markets ----
    scratch.cell_population.assign(static_cast<size_t>(cells), 0);
    scratch.cell_unemployed.assign(static_cast<size_t>(cells), 0);
    scratch.cell_soldiers.assign(static_cast<size_t>(cells), 0);
    scratch.cell_has_merchant.assign(static_cast<size_t>(cells), 0);
    scratch.market_cell.clear();
    scratch.market_good.clear();
    scratch.market_sellable.clear();
    scratch.market_price.clear();
    if (_economy_runtime != nullptr) {
        NativeEconomyRuntime *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
        if (economy_ready != nullptr)
            *economy_ready = economy->military_command_window_open();
        NativeEconomyRuntime::MilitaryCellView view;
        economy->military_read_cell_view(view, catalog.economy_good_count);
        const size_t n = std::min(view.population.size(), static_cast<size_t>(cells));
        for (size_t cell = 0; cell < n; ++cell) {
            scratch.cell_population[cell] = view.population[cell];
            scratch.cell_unemployed[cell] = view.unemployed[cell];
            scratch.cell_soldiers[cell] = view.soldiers[cell];
            scratch.cell_has_merchant[cell] = view.has_merchant[cell];
        }
        // Only the military supply goods are quoted; a good shared by several
        // classes is captured once.
        std::vector<int32_t> goods;
        for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
            for (const int32_t good : catalog.supply_goods[static_cast<size_t>(cls)]) {
                if (good < 0) continue;
                if (std::find(goods.begin(), goods.end(), good) == goods.end())
                    goods.push_back(good);
            }
        }
        std::sort(goods.begin(), goods.end());
        for (const int32_t good : goods) {
            std::vector<int32_t> market_cells;
            std::vector<int64_t> sellable;
            std::vector<int64_t> price;
            economy->military_read_market(good, market_cells, sellable, price);
            for (size_t i = 0; i < market_cells.size(); ++i) {
                scratch.market_cell.push_back(market_cells[i]);
                scratch.market_good.push_back(good);
                scratch.market_sellable.push_back(sellable[i]);
                scratch.market_price.push_back(price[i]);
            }
        }
        for (int32_t slot = 0; slot < country_count; ++slot)
            digest.country_soldier_living_cost[static_cast<size_t>(slot)] =
                economy->military_soldier_living_cost(slot);
        // The economy's kind-3 building groups are the ledger of record for
        // every state lot; the core rebuilds its cache from these rows and never
        // counts anything itself (requirement 6.1-6.3). A non-authoritative
        // read leaves `state_lanes_present` false, which tells the core to keep
        // the cache it has instead of zeroing it.
        std::vector<int32_t> state_cells;
        std::vector<int32_t> state_types;
        std::vector<int32_t> state_roles;
        std::vector<int64_t> state_units;
        if (economy->military_read_state_buildings(state_cells, state_types,
                                                   state_roles, state_units)) {
            scratch.state_cell.swap(state_cells);
            scratch.state_type_id.swap(state_types);
            scratch.state_state_role.swap(state_roles);
            scratch.state_units.swap(state_units);
            digest.state_lanes_present = true;
            digest.state_lane_rows = static_cast<int32_t>(scratch.state_cell.size());
        }
    }
    digest.cell_population = scratch.cell_population;
    digest.cell_unemployed = scratch.cell_unemployed;
    digest.cell_soldiers = scratch.cell_soldiers;
    digest.cell_has_merchant = scratch.cell_has_merchant;
    digest.market_cell = scratch.market_cell;
    digest.market_good = scratch.market_good;
    digest.market_sellable = scratch.market_sellable;
    digest.market_price = scratch.market_price;
    // Copied (not moved) because the scratch is reused next day; the copy only
    // costs the sparse state rows, which are a few hundred at most.
    digest.state_cell = scratch.state_cell;
    digest.state_type_id = scratch.state_type_id;
    digest.state_state_role = scratch.state_state_role;
    digest.state_units = scratch.state_units;
    // ---- Technology unlock bits: one row per country, bit = unlock_bit ----
    // `_military_unlock_tech_ids` records the dense technology id each bit
    // stands for at configure time, so a country's row is one
    // has_technology() probe per referenced technology.
    const int32_t unlock_bits = static_cast<int32_t>(_military_unlock_tech_ids.size());
    digest.unlock_words = (unlock_bits + 63) / 64;
    digest.country_unlock_bits.assign(
        static_cast<size_t>(country_count) * static_cast<size_t>(digest.unlock_words), 0);
    if (_country_runtime != nullptr && unlock_bits > 0) {
        NativeCountryRuntime *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        for (int32_t slot = 0; slot < country_count; ++slot) {
            uint64_t *row = digest.country_unlock_bits.data() +
                static_cast<size_t>(slot) * static_cast<size_t>(digest.unlock_words);
            for (int32_t bit = 0; bit < unlock_bits; ++bit) {
                const int32_t tech = _military_unlock_tech_ids[static_cast<size_t>(bit)];
                if (tech < 0 || !country->has_technology(slot, tech)) continue;
                row[bit >> 6] |= (uint64_t{1} << static_cast<uint32_t>(bit & 63));
            }
        }
    }
    // ---- Military Modifier stats (q16, design defaults when absent) ----
    digest.stat_count = MSTAT_COUNT;
    digest.country_stat_q16.assign(
        static_cast<size_t>(country_count) * static_cast<size_t>(MSTAT_COUNT), 0);
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const uint64_t handle = slot < static_cast<int32_t>(digest.country_handle.size())
            ? digest.country_handle[static_cast<size_t>(slot)] : 0;
        for (int32_t stat = 0; stat < MSTAT_COUNT; ++stat) {
            int32_t value = military_stat_default_q16(stat);
            if (_modifier_runtime != nullptr && handle != 0) {
                const double base = static_cast<double>(value) / static_cast<double>(MILITARY_Q);
                const double effective = static_cast<ModifierRuntime *>(_modifier_runtime)
                    ->effective_value(ModifierRuntime::COUNTRY,
                                      kMilitaryStatKeys[static_cast<size_t>(stat)],
                                      handle, 0, base);
                if (std::isfinite(effective))
                    value = q16_from_float(effective);
            }
            digest.country_stat_q16[static_cast<size_t>(slot) *
                static_cast<size_t>(MSTAT_COUNT) + static_cast<size_t>(stat)] = value;
        }
    }
}

// ===========================================================================
// intent submission (military D -> Country/Economy D+1 commands)
// ===========================================================================

namespace {

// Country opcodes the military bridge is allowed to submit. 23/24/27 are the
// treaty opcodes the Country owner adds; 22/25/26 stay reserved for Country.
constexpr int32_t MCOUNTRY_TRANSFER_TERRITORY = 3;
constexpr int32_t MCOUNTRY_CONSUME_TREASURY_GOODS = 21;
constexpr int32_t MCOUNTRY_TRANSFER_CASH = 23;
constexpr int32_t MCOUNTRY_TRANSFER_GOODS = 24;
constexpr int32_t MCOUNTRY_ANNEX = 27;

// Economy opcodes (economy_runtime.h Opcode).
constexpr int32_t MECONOMY_TRANSFER_TO_COHORT = 1;
constexpr int32_t MECONOMY_REMOVE_STOCK = 5;
constexpr int32_t MECONOMY_ADD_POPULATION = 6;
constexpr int32_t MECONOMY_CHANGE_SIGNATURE = 8;
constexpr int32_t MECONOMY_CONVERT_COHORT = 24;   // B: (cell, src sig, dst sig, heads)
constexpr int32_t MECONOMY_MARKET_GOOD_TO_COUNTRY = 13;
// Army personnel lane (army-personnel contract §1.2). Same POD lane as 24:
// payload0 = heads, payload1 = destination lane for MERGE_LANES, target_cohort
// = army handle, target_cell = the cell, target_country = soldier signature.
constexpr int32_t MECONOMY_ARMY_EMBARK = 30;
constexpr int32_t MECONOMY_ARMY_DISEMBARK = 31;
constexpr int32_t MECONOMY_ARMY_MERGE_LANES = 32;
// Split / partial transfer (army-personnel contract-2 §1.1). Lane -> lane like
// 32, so no cohort is named and no structural command is needed: payload0 =
// heads actually moved, payload1 = destination army handle, target_cohort =
// source army handle. payload0 <= 0 means "the whole lane" on the Economy side;
// Military emits 32 for that case instead (contract §1.2).
constexpr int32_t MECONOMY_ARMY_SPLIT_LANES = 33;
// Army pay (army-pay contract §3, Economy opcode 34): payload0 = MONEY_SCALE
// amount, payload1 = country handle, target_cohort = army handle. Treasury cash
// only — no cohort and no structural command — so it rides the same POD lane as
// 24/30-33 and is deduplicated by `sequence` there.
constexpr int32_t MECONOMY_ARMY_LANE_PAY = 34;

bool is_army_lane_opcode(int32_t opcode) {
    return opcode == MECONOMY_ARMY_EMBARK || opcode == MECONOMY_ARMY_DISEMBARK ||
           opcode == MECONOMY_ARMY_MERGE_LANES || opcode == MECONOMY_ARMY_SPLIT_LANES ||
           opcode == MECONOMY_ARMY_LANE_PAY;
}

// Feature detection for the split lanes (army-personnel contract-2 §1.1): the
// Economy runtime reports whether this build implements opcode 33. Probed at
// compile time the same way world_ext_economy_military.cpp probes
// military_army_population(), so an Economy build that predates the split lanes
// still links and runs: the bridge then degrades to a no-op plus a failed
// pending row instead of submitting an opcode nobody knows.
template <typename T, typename = void>
struct HasArmyLaneSplitProbe : std::false_type {};
template <typename T>
struct HasArmyLaneSplitProbe<T, std::void_t<decltype(
        std::declval<const T &>().military_army_lane_split_supported())>>
    : std::true_type {};

template <typename T>
bool army_lane_split_supported(const T *runtime) {
    if (runtime == nullptr) return false;
    if constexpr (HasArmyLaneSplitProbe<T>::value)
        return runtime->military_army_lane_split_supported();
    return false;
}

// Feature detection for army pay (army-pay contract §3.3). Same compile-time
// probe contract as the split lanes: an Economy build that predates opcode 34
// must not be handed the command at all, because admission would reject the row
// and (on the legacy ingress) could take the whole batch down with it. When the
// probe is absent or false, MILITARY_INTENT_ARMY_PAY degrades to a no-op plus a
// failed receipt and Military stays on the pre-army-pay accounting.
template <typename T, typename = void>
struct HasArmyLanePayProbe : std::false_type {};
template <typename T>
struct HasArmyLanePayProbe<T, std::void_t<decltype(
        std::declval<const T &>().military_army_lane_pay_supported())>>
    : std::true_type {};

template <typename T>
bool army_lane_pay_supported(const T *runtime) {
    if (runtime == nullptr) return false;
    if constexpr (HasArmyLanePayProbe<T>::value)
        return runtime->military_army_lane_pay_supported();
    return false;
}

} // namespace

// Army personnel lane probes, defined in world_ext_economy_military.cpp (the
// only TU that looks at the Economy lane bindings). An economy build without
// them answers false / -1 instead of trapping, so the bridge keeps working.
bool economy_army_lane_supported(const void *economy);
int64_t economy_army_lane_population(void *economy, uint64_t army_handle);
int64_t economy_army_lane_funds(void *economy, uint64_t army_handle);
bool economy_set_army_ration(void *economy, uint64_t army_handle, int32_t q16);

namespace {

// Army personnel lane reconcile (army-personnel contract §2.1). Economy owns
// natural deaths and the lane row, so Military only ever READS the lane and
// trims its own lots down to it — it never grows a formation and never writes
// Economy. Two hard rules from the recruitment pipeline apply verbatim:
//   * a lane read of 0 is not evidence of death (a busy worker read view reports
//     zero), so only a positive reading may trim;
//   * heads already booked but still in flight (embarkation emitted, receipt
//     pending) are part of the ceiling, or the army is trimmed the day it forms.
int64_t reconcile_army_lane_personnel(NativeEconomyRuntime *economy, MilitaryCore &core) {
    if (economy == nullptr) return 0;
    if (!economy_army_lane_supported(economy)) return 0;
    int64_t trimmed = 0;
    const MilitaryArmyStore &armies = core.armies();
    for (size_t slot = 0; slot < armies.active.size(); ++slot) {
        if (armies.active[slot] == 0) continue;
        const int64_t booked = armies.cached_headcount[slot];
        if (booked <= 0) continue;
        const uint64_t handle = core.army_handle(static_cast<int32_t>(slot));
        if (handle == 0) continue;
        const int64_t lane = economy_army_lane_population(economy, handle);
        if (lane <= 0) continue;
        const int64_t allowed = lane + core.army_lane_pending(static_cast<int32_t>(slot));
        if (booked <= allowed) continue;
        core.trim_army_lots(static_cast<int32_t>(slot), allowed);
        core.refresh_army_cache(static_cast<int32_t>(slot));
        trimmed += booked - allowed;
    }
    return trimmed;
}

} // namespace

Dictionary DCWorldExt::run_military_daily(const Dictionary &ctx) {
    if (_military_runtime == nullptr) return military_unavailable();
    MilitaryCore *core = core_from(_military_runtime);
    if (!core->configured()) return military_fail("military_not_configured");
    const int64_t day = dict_i64(ctx, "day_index", -1);
    if (day < 0) return military_fail("military_day_invalid");
    if (core->terrain().cell_count <= 0) return military_fail("military_terrain_missing");
    Dictionary out;
    out["ok"] = true;
    out["day_index"] = day;
    out["path"] = "native_military";
    if (day <= _military_last_step_day) {
        // The day was already stepped by the other entry point (daily system vs
        // whole-graph catch-up). Re-running it would double-submit D+1 intents.
        out["skipped"] = true;
        out["reason"] = "military_day_already_stepped";
        out["intents_submitted"] = static_cast<int64_t>(0);
        out["country_ops"] = static_cast<int64_t>(0);
        out["economy_ops"] = static_cast<int64_t>(0);
        return out;
    }
    // ---- 1. Committed D digest ----
    const auto capture_started = std::chrono::steady_clock::now();
    MilitaryWorldDigest digest;
    bool economy_ready = false;
    capture_military_digest(digest, _military_digest_scratch, core->catalog(), &economy_ready);
    digest.day = day;
    const double capture_ms = static_cast<double>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - capture_started).count()) / 1000.0;
    // ---- 2. Receipts for every pending intent that reached a terminal state ----
    // Rows survive across days until their authority reports a terminal
    // outcome (or they time out), so a late Economy epoch never loses a receipt.
    apply_military_deferred_cash(day);
    std::vector<MilitaryIntentReceipt> receipts;
    collect_military_receipts(day, receipts);
    // ---- 3. The military day ----
    std::vector<MilitaryIntent> intents;
    intents.reserve(256);
    std::string error;
    if (!core->step_day(day, digest, receipts, intents, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        out["capture_ms"] = capture_ms;
        return out;
    }
    _military_last_step_day = day;
    // Commands due on or before this day were applied by step_day.
    if (_military_forced_run_day >= 0 && _military_forced_run_day <= day)
        _military_forced_run_day = -1;
    // ---- 3b. Publish the ration satisfaction Economy consumes ----
    // Design §9.2: the soldier's staple/protein needs are supplied in kind from
    // the military ration stock, so Economy reads their satisfaction from here
    // instead of buying them on the market. The core keeps the per-holder ration
    // ratio; the garrison lane is per cell, which is what Economy needs.
    if (_economy_runtime != nullptr) {
        publish_military_ration_satisfaction(*core_from(_military_runtime), digest, intents);
    }
    // ---- 3c. Reconcile the army personnel lanes against Economy -----------
    // Read-and-trim only (contract §2.1): a formation never books more people
    // than its lane holds, and Economy is never written from here.
    int64_t army_lane_trimmed = 0;
    if (_economy_runtime != nullptr) {
        army_lane_trimmed = reconcile_army_lane_personnel(
            static_cast<NativeEconomyRuntime *>(_economy_runtime), *core);
    }
    // ---- 4. Translate intents into D+1 command batches ----
    const int64_t effective_day = day + 1;
    std::vector<MilitaryCountryCommand> country_commands;
    std::vector<MilitaryEconomyCommand> economy_commands;
    std::vector<MilitaryPendingIntent> pending;
    pending.reserve(intents.size());
    int32_t unsequenced = 0;
    for (const MilitaryIntent &intent : intents) {
        translate_military_intent(intent, effective_day, digest, country_commands,
                                  economy_commands, pending, unsequenced);
    }
    int64_t country_ops = static_cast<int64_t>(country_commands.size());
    int64_t economy_ops = static_cast<int64_t>(economy_commands.size());    std::string submit_error;
    const bool country_ok = country_commands.empty() ||
        submit_military_country_commands(country_commands, pending, submit_error);
    const bool economy_ok = economy_commands.empty() ||
        submit_military_economy_commands(economy_commands, pending, submit_error);    // Rows whose authority rejected the whole batch are reported back as failed
    // receipts so the core can reconcile them on the next day.
    if (!country_ok || !economy_ok) {
        out["submit_error"] = String(submit_error.c_str());
        for (MilitaryPendingIntent &row : pending) {
            const bool refused = (row.authority == 1 && !country_ok) ||
                                 (row.authority == 2 && !economy_ok);
            if (!refused) continue;
            // No receipt will arrive for a batch the authority refused.
            row.receipt_pending = 0;
        }
    }
    // Append today's rows to the cross-day pending set. Rows that already failed
    // here (no source cohort, refused batch) are kept as "resolved failed" so the
    // next fold reports them to the core instead of silently dropping them.
    // Rows of earlier days stay until their own terminal receipt / timeout.
    for (MilitaryPendingIntent &row : pending) {
        if (row.receipt_pending == 0) row.receipt_pending = 3;
        _military_pending_intents.push_back(row);
    }
    // ---- 5. Report ----
    const MilitaryReport &report = core->report();
    // Any successful day may change authoritative army rows even when the
    // battle loop reports idle: command application, merges/splits, supply,
    // morale, training and composition can all settle without an intent.
    // The feed must observe that day boundary instead of waiting for movement.
    ++_military_render_revision;
    out["ok"] = country_ok && economy_ok;
    out["reason"] = (country_ok && economy_ok) ? String() : String("military_intent_submit_failed");
    out["path"] = "native_military";
    out["skipped"] = false;
    out["day_ms"] = report.day_ms;
    out["capture_ms"] = capture_ms;
    out["armies_active"] = static_cast<int64_t>(report.armies_active);
    out["armies_moving"] = static_cast<int64_t>(report.armies_moving);
    out["engagements_active"] = static_cast<int64_t>(report.engagements_active);
    out["wars_active"] = static_cast<int64_t>(report.wars_active);
    out["soldiers_total"] = report.soldiers_total;
    out["astar_expansions"] = report.astar_expansions;
    out["area_evals"] = static_cast<int64_t>(report.area_evals);
    out["threat_field_cells"] = static_cast<int64_t>(report.threat_field_cells);
    out["convoys_due"] = static_cast<int64_t>(report.convoys_due);
    out["convoy_hops"] = report.convoy_hops;
    out["front_edges_touched"] = static_cast<int64_t>(report.front_edges_touched);
    out["vision_patch_cells"] = static_cast<int64_t>(report.vision_patch_cells);
    out["event_coalesced"] = static_cast<int64_t>(report.event_coalesced);
    out["reconcile_delta"] = report.reconcile_delta;
    // The day's payroll split by holder (army-pay contract §2.3). A test (or a
    // panel) can tell "who got paid today" apart from the 30-day EWMA.
    out["payroll_garrison"] = report.payroll_garrison;
    out["payroll_army"] = report.payroll_army;
    out["intents_emitted"] = static_cast<int64_t>(report.intents_emitted);
    out["intents_submitted"] = static_cast<int64_t>(pending.size());
    out["receipts_folded"] = static_cast<int64_t>(receipts.size());
    out["country_ops"] = country_ops;
    out["economy_ops"] = economy_ops;
    // Army personnel lane telemetry (contract §2): how many rows went to the
    // economy this day, whether the loaded economy can carry them at all, and
    // how many heads the lane reconcile trimmed.
    int64_t army_lane_ops = 0;
    for (const MilitaryEconomyCommand &command : economy_commands) {
        if (is_army_lane_opcode(command.opcode)) ++army_lane_ops;
    }
    out["army_lane_ops"] = army_lane_ops;
    out["army_lane_supported"] = _economy_runtime != nullptr &&
        economy_army_lane_supported(_economy_runtime);
    // Split / partial-transfer lane support (contract-2 §1.1, opcode 33): the
    // smoke test gates its split/transfer conservation assertions on this, so an
    // economy DLL that predates 33 skips them instead of failing them.
    out["army_split_lane_supported"] = army_lane_split_supported(
        static_cast<const NativeEconomyRuntime *>(_economy_runtime));
    // Army pay support (army-pay contract §3.3, opcode 34): same gate contract as
    // the split lanes above, so a DLL without 34 skips the pay assertions instead
    // of failing them.
    out["army_pay_supported"] = army_lane_pay_supported(
        static_cast<const NativeEconomyRuntime *>(_economy_runtime));
    int64_t army_pay_ops = 0;
    for (const MilitaryEconomyCommand &command : economy_commands) {
        if (command.opcode == MECONOMY_ARMY_LANE_PAY) ++army_pay_ops;
    }
    out["army_pay_ops"] = army_pay_ops;
    // Diagnostic for the army-pay gate: paying needs a synchronous treasury debit,
    // which is only available while Country accepts sync store writes.
    out["army_pay_sync_cash_available"] = _country_runtime != nullptr &&
        !static_cast<NativeCountryRuntime *>(_country_runtime)
             ->sync_store_writes_forbidden();
    out["army_lane_trimmed"] = army_lane_trimmed;
    out["economy_ready"] = economy_ready;
    out["effective_day"] = effective_day;
    out["sequence_cursor"] = _military_sequence;
    out["command_cursor"] = static_cast<int64_t>(core->_pending.size());
    out["state_hash"] = static_cast<int64_t>(core->state_hash() & 0x7fffffffffffffffll);
    return out;
}

Dictionary DCWorldExt::run_military_catch_up(const Dictionary &ctx) {
    if (_military_runtime == nullptr) return military_unavailable();
    const int64_t day = dict_i64(ctx, "day_index", -1);
    Dictionary out;
    if (day < 0) return military_fail("military_day_invalid");
    // The worker never steps Military. In whole-graph ACTIVE, WorldRuntimeHost
    // replays every committed day on the main thread (facade.run_daily ->
    // run_military_daily); this entry point is the same main-thread step with
    // the one-step-per-day guard, kept for callers that use `catch_up`.
    if (day <= _military_last_step_day) {
        out["ok"] = true;
        out["path"] = "native_military_catch_up";
        out["skipped"] = true;
        out["reason"] = "military_day_already_stepped";
        out["day_index"] = day;
        return out;
    }
    return run_military_daily(ctx);
}

// ===========================================================================
// command batches
// ===========================================================================

Dictionary DCWorldExt::submit_military_commands(const Array &batch) {
    if (_military_runtime == nullptr) return military_unavailable();
    if (!core_from(_military_runtime)->configured()) return military_fail("military_not_configured");
    Array rejected;
    int64_t accepted = 0;
    for (int64_t i = 0; i < batch.size(); ++i) {
        Dictionary row_out;
        if (batch[i].get_type() != Variant::DICTIONARY) {
            row_out["index"] = i;
            row_out["reason"] = String("military_command_not_object");
            rejected.push_back(row_out);
            continue;
        }
        const Dictionary row = batch[i];
        MilitaryCommand command;
        std::string error;
        if (!parse_military_command(row, command, error)) {
            row_out["index"] = i;
            row_out["reason"] = String(error.c_str());
            rejected.push_back(row_out);
            continue;
        }
        // Every command applies on the next military day (design §6.2); `stop`
        // is the documented same-day exception and still lands on D+1 because
        // D has already been stepped when the player clicks.
        command.effective_day = _military_last_step_day + 1;
        command.sequence = static_cast<uint64_t>(++_military_sequence);
        // Lazily open the issuing country's slot (resolved against the Country
        // authority) so a command before the first military day is not
        // rejected as command_unknown_country.
        if (command.country != 0 && _country_runtime != nullptr &&
            core_from(_military_runtime)->country_slot_for_handle(command.country) < 0 &&
            static_cast<NativeCountryRuntime *>(_country_runtime)
                ->valid_handle(static_cast<int64_t>(command.country))) {
            ensure_military_country_slots();
        }
        const int64_t effective_day = command.effective_day;
        if (!core_from(_military_runtime)->submit(std::move(command), error)) {
            row_out["index"] = i;
            row_out["reason"] = String(error.c_str());
            rejected.push_back(row_out);
            continue;
        }
        if (_military_forced_run_day < 0 || effective_day < _military_forced_run_day)
            _military_forced_run_day = effective_day;
        ++accepted;
    }
    Dictionary out;
    out["ok"] = rejected.is_empty();
    out["accepted"] = accepted;
    out["rejected"] = rejected;
    out["code"] = rejected.is_empty() ? String("ok") : String("military_command_rejected");
    out["next_sequence"] = _military_sequence;
    return out;
}

bool DCWorldExt::submit_military_country_commands(
        const std::vector<MilitaryCountryCommand> &commands,
        std::vector<MilitaryPendingIntent> &pending, std::string &error) {
    if (commands.empty()) return true;
    if (_country_runtime == nullptr) {
        error = "military_country_unavailable";
        return false;
    }
    const int64_t count = static_cast<int64_t>(commands.size());
    PackedInt32Array opcodes, cells, aux, domains, positions, w0, w1, w2, w3,
        tax_kinds, tax_items, tax_rates, tax_modes;
    PackedInt64Array days, sequences, targets, values;
    PackedStringArray stable_ids, names;
    opcodes.resize(count);
    cells.resize(count);
    aux.resize(count);
    domains.resize(count);
    positions.resize(count);
    w0.resize(count); w1.resize(count); w2.resize(count); w3.resize(count);
    tax_kinds.resize(count);
    tax_items.resize(count);
    tax_rates.resize(count);
    tax_modes.resize(count);
    days.resize(count);
    sequences.resize(count);
    targets.resize(count);
    values.resize(count);
    stable_ids.resize(count);
    names.resize(count);
    for (int64_t i = 0; i < count; ++i) {
        const MilitaryCountryCommand &c = commands[static_cast<size_t>(i)];
        opcodes[i] = c.opcode;
        cells[i] = c.cell;
        aux[i] = c.aux;
        domains[i] = c.domain;
        positions[i] = -1;
        w0[i] = 0; w1[i] = 0; w2[i] = 0; w3[i] = 0;
        tax_kinds[i] = -1;
        tax_items[i] = -1;
        tax_rates[i] = 0;
        tax_modes[i] = 0;
        days[i] = c.effective_day;
        sequences[i] = c.sequence;
        targets[i] = c.target_handle;
        values[i] = c.value;
        stable_ids[i] = String();
        names[i] = String();
    }
    Dictionary batch;
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
    if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
    const Dictionary submitted = submit_country_commands(batch);
    if (!static_cast<bool>(submitted.get("ok", false))) {
        error = String(submitted.get("code", submitted.get("reason",
            "military_country_submit_rejected"))).utf8().get_data();
        return false;
    }
    // Stamp request ids so the next day's receipt poll can match rows.
    if (submitted.has("request_ids") &&
        submitted["request_ids"].get_type() == Variant::PACKED_INT64_ARRAY) {
        const PackedInt64Array request_ids = submitted["request_ids"];
        for (int64_t i = 0; i < count && i < request_ids.size(); ++i) {
            for (MilitaryPendingIntent &row : pending) {
                if (row.authority != 1 || row.sequence != commands[static_cast<size_t>(i)].sequence)
                    continue;
                row.request_id = request_ids[i];
            }
            if (request_ids[i] > _military_receipts->after_request_id)
                _military_receipts->after_request_id = request_ids[i];
        }
    }
    return true;
}

bool DCWorldExt::submit_military_economy_commands(
        const std::vector<MilitaryEconomyCommand> &commands,
        std::vector<MilitaryPendingIntent> &pending, std::string &error) {
    if (commands.empty()) return true;
    if (_economy_runtime == nullptr) {
        error = "military_economy_unavailable";
        return false;
    }
    const int64_t count = static_cast<int64_t>(commands.size());
    // Row groups. Army personnel lane rows (opcodes 30/31/32) travel apart from
    // the pre-lane economy rows everywhere: an economy that does not know them
    // rejects a whole batch at the first bad row, so letting them share a batch
    // would take enlistment / casualties down with the lane. Three groups:
    //   * lane_rows      -> army personnel lane rows
    //   * pod_rows       -> the opcodes the POD lane carries (24 cohort convert,
    //                       6 population delta)
    //   * pre_lane_rows  -> every non-lane row, used for the legacy retry
    std::vector<int32_t> lane_rows;
    std::vector<int32_t> pod_rows;
    std::vector<int32_t> pre_lane_rows;
    std::vector<int32_t> all_rows;
    all_rows.reserve(static_cast<size_t>(count));
    for (int64_t i = 0; i < count; ++i) {
        const int32_t opcode = commands[static_cast<size_t>(i)].opcode;
        all_rows.push_back(static_cast<int32_t>(i));
        if (is_army_lane_opcode(opcode)) {
            lane_rows.push_back(static_cast<int32_t>(i));
        } else {
            pre_lane_rows.push_back(static_cast<int32_t>(i));
            if (opcode == MECONOMY_CONVERT_COHORT || opcode == MECONOMY_ADD_POPULATION)
                pod_rows.push_back(static_cast<int32_t>(i));
        }
    }
    const auto build_legacy = [&](const std::vector<int32_t> &rows) {
        const int64_t n = static_cast<int64_t>(rows.size());
        PackedInt32Array opcodes, i32_0, i32_1;
        PackedInt64Array days, sequences, targets, i64_0, i64_1;
        opcodes.resize(n);
        i32_0.resize(n);
        i32_1.resize(n);
        days.resize(n);
        sequences.resize(n);
        targets.resize(n);
        i64_0.resize(n);
        i64_1.resize(n);
        for (int64_t k = 0; k < n; ++k) {
            const MilitaryEconomyCommand &c = commands[static_cast<size_t>(rows[static_cast<size_t>(k)])];
            opcodes[k] = c.opcode;
            days[k] = c.effective_day;
            sequences[k] = c.sequence;
            targets[k] = c.target_handle;
            i32_0[k] = c.i32_0;
            i32_1[k] = c.i32_1;
            i64_0[k] = c.i64_0;
            i64_1[k] = c.i64_1;
        }
        Dictionary batch;
        batch["opcodes"] = opcodes;
        batch["effective_days"] = days;
        batch["sequences"] = sequences;
        batch["target_handles"] = targets;
        batch["i32_0"] = i32_0;
        batch["i32_1"] = i32_1;
        batch["i64_0"] = i64_0;
        batch["i64_1"] = i64_1;
        return batch;
    };
    // Marks the pending rows of one row group failed (no receipt will arrive).
    const auto fail_rows = [&](const std::vector<int32_t> &rows) {
        for (MilitaryPendingIntent &row : pending) {
            if (row.authority != 2) continue;
            for (const int32_t i : rows) {
                if (commands[static_cast<size_t>(i)].sequence != row.sequence) continue;
                row.receipt_pending = 0;
                break;
            }
        }
    };
    const Dictionary submitted = submit_economy_commands(build_legacy(all_rows));
    if (!static_cast<bool>(submitted.get("ok", false)) &&
        String(submitted.get("reason", "")) != String("economy_legacy_ingress_disabled") &&
        !lane_rows.empty() && !pre_lane_rows.empty()) {
        // Older economy on the legacy ingress: the lane opcodes are unknown there
        // (`unsupported_command_opcode`), which may fail the whole batch. Retry
        // without them so enlistment still lands, and fail only the lane rows.
        const Dictionary retry = submit_economy_commands(build_legacy(pre_lane_rows));
        if (static_cast<bool>(retry.get("ok", false))) {
            fail_rows(lane_rows);
            return true;
        }
    }
    if (!static_cast<bool>(submitted.get("ok", false)) &&
        String(submitted.get("reason", "")) == String("economy_legacy_ingress_disabled") &&
        _runtime_host != nullptr) {
        // B (design 5.4): state-directed cohort conversion, named by signature.
        // Economy resolves both cohorts inside whichever store owns the day, so
        // this works under whole-graph ACTIVE without the legacy ingress. Cash
        // lanes stay out: they would mint inside the POD store.
        const std::vector<int32_t> &cohort_rows = pod_rows;
        const auto build_pod = [&](const std::vector<int32_t> &rows) {
            PackedInt64Array ids, p0, p1, p2, cohorts;
            PackedInt32Array ops, cells;
            for (const int32_t i : rows) {
                const MilitaryEconomyCommand &c = commands[static_cast<size_t>(i)];
                ids.push_back(static_cast<int64_t>(_military_pod_request++));
                ops.push_back(c.opcode);
                cohorts.push_back(c.target_handle);
                switch (c.opcode) {
                case MECONOMY_CONVERT_COHORT:
                    p0.push_back(c.i64_0);        // heads
                    p1.push_back(c.i32_1);        // source signature
                    p2.push_back(c.i64_1);        // destination signature
                    cells.push_back(c.i32_0);     // cell
                    break;
                case MECONOMY_ARMY_EMBARK:
                case MECONOMY_ARMY_DISEMBARK:
                    p0.push_back(c.i64_0);        // heads
                    p1.push_back(c.i64_1);        // payload1 (unused for 30/31)
                    p2.push_back(c.i32_1);        // soldier signature for the cell
                    cells.push_back(c.i32_0);     // source / destination cell
                    break;
                case MECONOMY_ARMY_MERGE_LANES:
                    p0.push_back(c.i64_0);        // heads folded (informational)
                    p1.push_back(c.i64_1);        // destination army handle
                    p2.push_back(-1);
                    cells.push_back(c.i32_0);
                    break;
                case MECONOMY_ARMY_SPLIT_LANES:
                    p0.push_back(c.i64_0);        // heads actually moved
                    p1.push_back(c.i64_1);        // destination army handle
                    p2.push_back(-1);
                    cells.push_back(c.i32_0);
                    break;
                case MECONOMY_ARMY_LANE_PAY:
                    // Army pay (contract §3): payload0 = amount, payload1 =
                    // country handle (the payer), target_cohort = army handle,
                    // target_country unused. Treasury cash only, no cohort.
                    p0.push_back(c.i64_0);        // MONEY_SCALE amount
                    p1.push_back(c.i64_1);        // country handle
                    p2.push_back(-1);
                    cells.push_back(c.i32_0);
                    break;
                default:
                    // ADD_POPULATION: signed population delta.
                    p0.push_back(c.i64_0);
                    p1.push_back(-1);
                    p2.push_back(-1);
                    cells.push_back(c.i32_0);
                    break;
                }
            }
            Dictionary pod;
            pod["request_ids"] = ids;
            pod["opcodes"] = ops;
            pod["payload0s"] = p0;
            pod["payload1s"] = p1;
            pod["target_cells"] = cells;
            pod["target_countries"] = p2;
            pod["target_cohorts"] = cohorts;
            return pod;
        };
        if (cohort_rows.empty() && lane_rows.empty()) {
            error = "military_economy_ingress_closed";
            for (MilitaryPendingIntent &row : pending)
                if (row.authority == 2) row.receipt_pending = 0;
            return false;
        }
        if (!cohort_rows.empty()) {
            const Dictionary pod_result = submit_economy_pod_commands(build_pod(cohort_rows));
            if (!static_cast<bool>(pod_result.get("ok", false))) {
                error = String(pod_result.get("code", "military_economy_pod_rejected"))
                    .utf8().get_data();
                for (MilitaryPendingIntent &row : pending)
                    if (row.authority == 2) row.receipt_pending = 0;
                return false;
            }
        }
        if (!lane_rows.empty()) {
            const Dictionary lane_result = submit_economy_pod_commands(build_pod(lane_rows));
            if (!static_cast<bool>(lane_result.get("ok", false))) {
                // Degrade, do not poison the day: only the lane rows are lost and
                // they report back as failed receipts, so Military books the army
                // lots without a lane and the pre-lane model still runs.
                for (MilitaryPendingIntent &row : pending) {
                    if (row.authority != 2) continue;
                    for (const int32_t i : lane_rows) {
                        if (commands[static_cast<size_t>(i)].sequence != row.sequence) continue;
                        row.receipt_pending = 0;
                        break;
                    }
                }
            }
        }
        for (MilitaryPendingIntent &row : pending) {
            if (row.authority != 2) continue;
            bool carried = false;
            const std::vector<int32_t> *groups[2] = {&cohort_rows, &lane_rows};
            for (const std::vector<int32_t> *rows : groups) {
                for (const int32_t i : *rows) {
                    if (commands[static_cast<size_t>(i)].sequence == row.sequence) {
                        carried = true;
                        break;
                    }
                }
                if (carried) break;
            }
            if (!carried) row.receipt_pending = 0;
        }
        return true;
    }    return true;
}

// ===========================================================================
// receipts (Country command terminals + Economy settlements ->
// MilitaryIntentReceipt). `_military_pending_intents` is a cross-day set:
// a row leaves it only when a receipt is emitted for it (terminal ok/fail or
// timeout), so ENLIST/LEVY always reach MilitaryCore::reconcile_receipts.
// ===========================================================================

namespace {
// A row whose authority never reported back is failed after this many days
// past its effective day (Economy epochs are daily; Country commits are D+1).
constexpr int64_t kMilitaryReceiptTimeoutDays = 8;
} // namespace

void DCWorldExt::collect_military_receipts(int64_t day,
                                           std::vector<MilitaryIntentReceipt> &out) {
    out.clear();
    if (_military_pending_intents.empty()) return;
    // Economy rows (authority 2) settle through Economy trace events.
    collect_military_economy_receipts(day, out);
    if (_runtime_host == nullptr) {
        // Without a worker the sync country facade commits on its own day; there
        // is no per-command receipt, so an intent is assumed committed once its
        // effective day has been reached by the country runtime.
        int64_t committed_day = -1;
        if (_country_runtime != nullptr)
            committed_day = static_cast<NativeCountryRuntime *>(_country_runtime)
                ->last_committed_day();
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 1 || row.receipt_pending != 1 ||
                row.effective_day > committed_day) continue;
            row.receipt_pending = 2;
        }
    } else {
        // Worker authority: fold every terminal receipt after the cursor.
        if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
        MilitaryReceiptCursor &cursor = *_military_receipts;
        std::vector<CountryCommandReceipt> receipts;
        _runtime_host->poll_country_command_receipts(
            static_cast<uint64_t>(std::max<int64_t>(0, cursor.after_request_id)), 512, receipts);
        for (const CountryCommandReceipt &receipt : receipts) {
            cursor.after_request_id = std::max<int64_t>(cursor.after_request_id,
                static_cast<int64_t>(receipt.request_id));
            const bool terminal =
                receipt.code == CountryCommandReceiptCode::COMMITTED ||
                receipt.code == CountryCommandReceiptCode::REJECTED_AT_EXECUTION;
            if (!terminal) continue;
            const bool ok = receipt.code == CountryCommandReceiptCode::COMMITTED;
            for (MilitaryPendingIntent &row : _military_pending_intents) {
                if (row.authority != 1 || row.receipt_pending != 1 ||
                    row.request_id != static_cast<int64_t>(receipt.request_id))
                    continue;
                row.receipt_pending = ok ? 2 : 3;
                break;
            }
        }
        // The cursor can skip a terminal that landed before the stamp; look the
        // still-open rows up directly.
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 1 || row.receipt_pending != 1 || row.request_id <= 0) continue;
            CountryCommandReceipt receipt;
            if (!_runtime_host->try_country_command_terminal(
                    static_cast<uint64_t>(row.request_id), receipt))
                continue;
            if (receipt.code == CountryCommandReceiptCode::COMMITTED)
                row.receipt_pending = 2;
            else if (receipt.code == CountryCommandReceiptCode::REJECTED_AT_EXECUTION)
                row.receipt_pending = 3;
        }
    }
    // Emit resolved rows (in pending/sequence order), time out stale ones, and
    // compact the set.
    size_t write = 0;
    for (size_t i = 0; i < _military_pending_intents.size(); ++i) {
        MilitaryPendingIntent row = _military_pending_intents[i];
        if (row.receipt_pending == 1 &&
            day > row.effective_day + kMilitaryReceiptTimeoutDays)
            row.receipt_pending = 3;
        if (row.receipt_pending == 2) {
            out.push_back(military_receipt_from(row, true, row.count, row.amount));
            continue;
        }
        if (row.receipt_pending == 3 || row.receipt_pending == 0) {
            out.push_back(military_receipt_from(row, false, 0, 0));
            continue;
        }
        _military_pending_intents[write++] = row;
    }
    _military_pending_intents.resize(write);
}

void DCWorldExt::apply_military_deferred_cash(int64_t day) {
    // SPEND_CASH rows emitted on day D are debited here, at the start of
    // military day D+1, through the conserved fiscal escrow (reserve+collect
    // into Country's non-tax expenditure slots). Country has no "debit
    // treasury cash" command opcode, so this stays a bridge-side call, but it
    // now follows the D+1 rule and always produces a receipt with the
    // actually collected amount.
    if (_military_pending_intents.empty()) return;
    NativeEconomyRuntime *economy = _economy_runtime == nullptr ? nullptr
        : static_cast<NativeEconomyRuntime *>(_economy_runtime);
    for (MilitaryPendingIntent &row : _military_pending_intents) {
        if (row.authority != 3 || row.receipt_pending != 1) continue;
        if (row.effective_day > day) continue;
        if (economy == nullptr || !economy->military_command_window_open()) {
            // Retry next day; the timeout fails the row eventually.
            continue;
        }
        const int64_t collected = economy->military_collect_cash(
            static_cast<int64_t>(row.country_handle), row.amount);
        row.amount = collected;
        row.count = collected > 0 ? 1 : 0;
        row.receipt_pending = collected > 0 ? 2 : 3;
    }
}

// ===========================================================================
// intent translation
// ===========================================================================

void DCWorldExt::translate_military_intent(const MilitaryIntent &intent,
                                           int64_t effective_day,
                                           const MilitaryWorldDigest &digest,
                                           std::vector<MilitaryCountryCommand> &country,
                                           std::vector<MilitaryEconomyCommand> &economy,
                                           std::vector<MilitaryPendingIntent> &pending,
                                           int32_t &unsequenced) {
    (void)digest;
    (void)unsequenced;
    MilitaryPendingIntent row;
    row.kind = intent.kind;
    row.cell = intent.cell;
    row.good = intent.good;
    row.source_id = intent.source_id;
    row.country_handle = intent.country_a;
    row.count = intent.count;
    row.amount = intent.amount;
    row.effective_day = effective_day;
    const auto next_sequence = [this]() { return ++_military_sequence; };
    NativeEconomyRuntime *economy_runtime = _economy_runtime == nullptr ? nullptr
        : static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const int32_t soldier_profession = economy_runtime == nullptr ? -1
        : economy_runtime->military_soldier_profession();
    const int32_t unemployed_profession = economy_runtime == nullptr ? -1
        : economy_runtime->military_unemployed_profession();
    // LEVY draws from the cell's non-merchant employee cohorts once the
    // unemployed pool is exhausted (design 5.4), so it must not reuse the
    // ENLIST source. The candidate list is built from the province catalog
    // (dense profession ids), never from a cohort scan.
    std::vector<int32_t> levy_professions;
    if (intent.kind == MILITARY_INTENT_LEVY && economy_runtime != nullptr) {
        const int32_t count = economy_runtime->profession_count();
        levy_professions.reserve(static_cast<size_t>(std::max(0, count)));
        for (int32_t profession = 0; profession < count; ++profession) {
            if (profession == soldier_profession || profession == unemployed_profession ||
                profession == economy_runtime->military_merchant_profession())
                continue;
            levy_professions.push_back(profession);
        }
    }

    switch (intent.kind) {
    case MILITARY_INTENT_ENLIST:
    case MILITARY_INTENT_LEVY:
    case MILITARY_INTENT_DISCHARGE:
    case MILITARY_INTENT_CASUALTY: {
        // All four are cohort transitions on the cell's soldier cohort
        // (contract §0.5).
        if (economy_runtime == nullptr || intent.cell < 0) return;
        const int64_t heads = std::max<int64_t>(0, intent.count);
        if (heads == 0) return;
        uint64_t handle = 0;
        int32_t target_signature = -1;
        switch (intent.kind) {
        case MILITARY_INTENT_ENLIST: {
            // unemployed -> soldier: the source is the cell's unemployed cohort
            // (lowest ethnicity that still has people).
            handle = economy_runtime->military_cohort_handle_any_ethnicity(
                intent.cell, unemployed_profession);
            target_signature = soldier_profession;
            if (handle == 0) {
                // No unemployed pool in the cell: the enlist cannot be
                // conserved, so it is reported back as a failed receipt instead
                // of being silently dropped.
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            break;
        }
        case MILITARY_INTENT_LEVY: {
            // Forced service: unemployed first, then any other cohort the
            // state may draft (employee lanes of the same cell).
            handle = economy_runtime->military_cohort_handle_any_ethnicity(
                intent.cell, unemployed_profession);
            if (handle == 0) {
                handle = economy_runtime->military_cohort_handle_from_professions(
                    intent.cell, levy_professions.data(),
                    static_cast<int32_t>(levy_professions.size()));
            }
            target_signature = soldier_profession;
            if (handle == 0) {
                // Nothing left that may be drafted.
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            break;
        }
        case MILITARY_INTENT_DISCHARGE:
            handle = economy_runtime->military_cohort_handle_any_ethnicity(
                intent.cell, soldier_profession);
            target_signature = unemployed_profession;
            break;
        default:
            // CASUALTY: negative population on the soldier cohort.
            handle = economy_runtime->military_cohort_handle_any_ethnicity(
                intent.cell, soldier_profession);
            target_signature = -1;
            break;
        }
        if (handle == 0) return;
        // CHANGE_SIGNATURE names a SIGNATURE id, not a profession id, and the
        // cohort keeps its ethnicity through the transition: resolve
        // (target_profession, source ethnicity) explicitly instead of relying on
        // the dense profession row and the signature row sharing an index.
        if (target_signature >= 0 && intent.kind != MILITARY_INTENT_CASUALTY) {
            const int32_t ethnicity = economy_runtime->military_cohort_ethnicity(
                static_cast<uint64_t>(handle));
            // Resolve with the ECONOMY runtime's own table for this cell: the
            // bridge's profession id and the executor's signature id are not
            // guaranteed to line up, and a mismatch silently moves people into
            // another profession (unemployed drains, soldier cohort stays 0).
            int32_t resolved = economy_runtime->military_signature_for_cell_ethnicity(
                intent.cell, target_signature);
            if (resolved < 0 && ethnicity >= 0)
                resolved = economy_runtime->military_signature_for(target_signature, ethnicity);
            if (resolved < 0) {
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            target_signature = resolved;
        }
        MilitaryEconomyCommand command;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(handle);
        if (intent.kind == MILITARY_INTENT_CASUALTY) {
            // The dead cannot be more than the cell's live soldier cohort.
            const int64_t alive = economy_runtime->military_soldier_heads(intent.cell);
            const int64_t dead = std::min(heads, alive);
            if (dead <= 0) {
                row.receipt_pending = 0;
                pending.push_back(row);
                return;
            }
            command.opcode = MECONOMY_ADD_POPULATION;
            command.i64_0 = -dead;
            command.i32_0 = intent.cell;
            row.count = dead;
        } else {
            if (target_signature < 0) return;
            // B: name the cohorts by signature, never by slot id. Economy
            // resolves both inside whichever store owns the day and moves the
            // people there, so this works under whole-graph ACTIVE without
            // reopening the legacy ingress.
            const int32_t source_signature =
                economy_runtime->military_cohort_signature(static_cast<uint64_t>(handle));
            command.opcode = MECONOMY_CONVERT_COHORT;
            row.count = heads;
            command.i32_0 = intent.cell;
            command.i32_1 = source_signature;
            command.i64_0 = heads;
            command.i64_1 = target_signature;
        }
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        row.target_signature = command.opcode == MECONOMY_CHANGE_SIGNATURE ? command.i32_0 : -1;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_PAY_WAGES: {
        // Treasury -> soldier cohort (COMMAND_TRANSFER_TO_COHORT, i64_1 = country).
        if (economy_runtime == nullptr || intent.cell < 0 || intent.amount <= 0) return;
        const uint64_t handle = economy_runtime->military_cohort_handle_any_ethnicity(
            intent.cell, soldier_profession);
        if (handle == 0) return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_TRANSFER_TO_COHORT;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(handle);
        command.i64_0 = intent.amount;
        command.i64_1 = static_cast<int64_t>(intent.country_a);
        command.i32_0 = intent.cell;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_PROCURE_GOOD: {
        // Market -> treasury, paid to the merchant (COMMAND_MARKET_GOOD_TO_COUNTRY,
        // i32_0 = market = cell, i32_1 = good).
        if (economy_runtime == nullptr || intent.cell < 0 || intent.good < 0 ||
            intent.count <= 0 || intent.country_a == 0)
            return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_MARKET_GOOD_TO_COUNTRY;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.i32_0 = intent.cell;
        command.i32_1 = intent.good;
        command.i64_0 = intent.count;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_CONSUME_TREASURY_GOOD: {
        // Country opcode 21: aux = dense good, value = GOODS_SCALE consumed.
        if (intent.country_a == 0 || intent.good < 0 || intent.count <= 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_CONSUME_TREASURY_GOODS;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.aux = intent.good;
        command.value = intent.count;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_REQUISITION: {
        // Explicit market stock delta, no payment (COMMAND_REMOVE_STOCK).
        if (economy_runtime == nullptr || intent.cell < 0 || intent.good < 0 ||
            intent.count <= 0)
            return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_REMOVE_STOCK;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = 0;
        command.i32_0 = intent.cell;
        command.i32_1 = intent.good;
        command.i64_0 = std::max<int64_t>(0, intent.count);
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = 0;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_SPEND_CASH: {
        // Military upkeep / building cash. Country has no "debit cash" opcode,
        // so this uses the conserved fiscal escrow (reserve + collect), which
        // books the amount into the country's non-tax expenditure slots. It is
        // deferred to D+1 (apply_military_deferred_cash at the start of the
        // next military day) so it reads the same committed treasury the rest
        // of the D+1 batch does; the receipt carries the collected amount, and
        // a shortfall reports the smaller committed_amount.
        if (economy_runtime == nullptr || intent.country_a == 0 || intent.amount <= 0) return;
        row.authority = 3;
        row.receipt_pending = 1;
        row.sequence = next_sequence();
        pending.push_back(row);
        return;
    }
    case MILITARY_INTENT_STATE_BUILD: {
        // A state building request (see MILITARY_INTENT_STATE_BUILD in
        // military_bridge.h). This is the only settlement path for a state lot:
        // the economy charges the treasury for the real materials and, only
        // when it accepted the order, the core gets the bookkeeping command
        // that schedules the completion day.
        if (economy_runtime == nullptr || intent.country_a == 0 ||
            intent.cell < 0 || intent.count <= 0)
            return;
        MilitaryCore *core = core_from(_military_runtime);
        const int32_t building = static_cast<int32_t>(intent.count);
        if (building >= static_cast<int32_t>(core->_catalog.state_buildings.size()))
            return;
        const int32_t economy_type = core->_catalog.state_buildings[
            static_cast<size_t>(building)].economy_building_id;
        // A catalog compiled before this bridge leaves the column at -1: those
        // lots have no economy profile, therefore no bill, therefore they are
        // not built at all instead of being built for free.
        if (economy_type < 0) return;
        const Dictionary queued = economy_runtime->queue_treasury_sponsored_build(
            static_cast<int64_t>(intent.country_a), intent.cell, economy_type,
            effective_day, next_sequence(), false);
        if (!bool(queued.get("ok", false))) return;
        // The economy owns the schedule; the core only mirrors it. Feeding the
        // accepted lot back through the ordinary command queue keeps the
        // pending construction slots and the completion day on one code path.
        MilitaryCommand command;
        command.op = MCMD_STATE_BUILD;
        command.country = intent.country_a;
        command.cell = intent.cell;
        command.unit_to = building;
        command.effective_day = effective_day;
        command.sequence = static_cast<uint64_t>(next_sequence());
        std::string command_error;
        core->submit(std::move(command), command_error);
        // Deliberately no `pending` row: this branch already holds the economy's
        // synchronous accept/reject, so there is nothing left to await, and the
        // core's receipt fold has no case for this kind. Pushing an authority=2
        // row here would sit unresolved until the receipt timeout and then emit
        // a failure the core ignores anyway.
        return;
    }
    case MILITARY_INTENT_STATE_DEMOLISH: {
        // The mirror of STATE_BUILD on the removal side. The economy drops the
        // unit from the ledger row first and only an accepted removal is echoed
        // back as MCMD_STATE_DEMOLISH, so the ledger is always the first to
        // change and the core can never report a demolition the ledger did not
        // record (requirement 6.5). `count` carries the state building index,
        // exactly like STATE_BUILD; one unit per request.
        if (economy_runtime == nullptr || intent.country_a == 0 ||
            intent.cell < 0 || intent.count <= 0)
            return;
        MilitaryCore *core = core_from(_military_runtime);
        const int32_t building = static_cast<int32_t>(intent.count);
        if (building >= static_cast<int32_t>(core->_catalog.state_buildings.size()))
            return;
        const int32_t economy_type = core->_catalog.state_buildings[
            static_cast<size_t>(building)].economy_building_id;
        // A catalog compiled before this bridge leaves the column at -1: the lot
        // has no economy profile, so it is not in the ledger and there is
        // nothing that could remove it.
        if (economy_type < 0) return;
        const Dictionary queued = economy_runtime->queue_treasury_sponsored_demolish(
            static_cast<int64_t>(intent.country_a), intent.cell, economy_type, 1,
            effective_day, next_sequence(), false);
        if (!bool(queued.get("ok", false))) return;
        MilitaryCommand command;
        command.op = MCMD_STATE_DEMOLISH;
        command.country = intent.country_a;
        command.cell = intent.cell;
        command.unit_to = building;
        command.effective_day = effective_day;
        command.sequence = static_cast<uint64_t>(next_sequence());
        std::string command_error;
        core->submit(std::move(command), command_error);
        // No `pending` row: the economy's accept/reject above is synchronous.
        return;
    }
    case MILITARY_INTENT_ARMY_EMBARK:
    case MILITARY_INTENT_ARMY_DISEMBARK: {
        // Army personnel lane (army-personnel contract §1.2, opcode 30/31).
        // The lane row is named by ARMY HANDLE (target_cohort) and the cohort by
        // (cell, signature) — never by slot id, same rule as opcode 24. Economy
        // resolves the soldier|ethnicity signature itself; the bridge only offers
        // the signature it can see for the cell, and -1 means "you decide".
        if (economy_runtime == nullptr || intent.cell < 0 || intent.source_id == 0) return;
        const int64_t heads = std::max<int64_t>(0, intent.count);
        if (heads == 0) return;
        int32_t signature = -1;
        if (soldier_profession >= 0) {
            signature = economy_runtime->military_signature_for_cell_ethnicity(
                intent.cell, soldier_profession);
        }
        MilitaryEconomyCommand command;
        command.opcode = intent.kind == MILITARY_INTENT_ARMY_EMBARK
            ? MECONOMY_ARMY_EMBARK : MECONOMY_ARMY_DISEMBARK;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.source_id);  // army handle
        command.i32_0 = intent.cell;
        command.i32_1 = signature;
        command.i64_0 = heads;
        command.i64_1 = 0;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_ARMY_MERGE_LANES: {
        // Opcode 32: fold the source lane into the destination lane. payload1
        // carries the destination army handle; the source is target_cohort.
        if (economy_runtime == nullptr || intent.country_a == 0 || intent.country_b == 0) return;
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_ARMY_MERGE_LANES;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);   // source lane
        command.i64_0 = std::max<int64_t>(0, intent.count);
        command.i64_1 = static_cast<int64_t>(intent.country_b);           // destination
        command.i32_0 = intent.cell;
        command.i32_1 = -1;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_ARMY_SPLIT_LANES: {
        // Opcode 33 (contract-2 §1.1/§1.2): move the heads a split / partial
        // transfer actually moved from the source formation's lane into the
        // destination formation's lane. payload0 = heads, payload1 = destination
        // army handle, target_cohort = source army handle — the same key layout
        // as 32, and lane -> lane names no cohort, so no signature is needed.
        if (intent.country_a == 0 || intent.country_b == 0 ||
            intent.country_a == intent.country_b)
            return;
        const int64_t heads = std::max<int64_t>(0, intent.count);
        if (heads == 0) return;
        if (economy_runtime == nullptr) return;
        if (!army_lane_split_supported(economy_runtime)) {
            // Feature detection (contract-2 §1.1): this Economy build does not
            // implement opcode 33. Emitting the row anyway would be rejected as an
            // unknown opcode and could take the whole batch down. Report it as a
            // failed receipt instead — a no-op command plus one pending row
            // failure, never a crash — and Military stays on the pre-split-lane
            // model (the lots have already moved, so only the lane bookkeeping is
            // skipped).
            row.authority = 2;
            row.receipt_pending = 0;
            row.opcode = MECONOMY_ARMY_SPLIT_LANES;
            row.target_handle = static_cast<int64_t>(intent.country_a);
            pending.push_back(row);
            return;
        }
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_ARMY_SPLIT_LANES;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);   // source lane
        command.i64_0 = heads;                                            // heads moved
        command.i64_1 = static_cast<int64_t>(intent.country_b);           // destination
        command.i32_0 = intent.cell;
        // Unused by opcode 33 (lane -> lane), but 0 rather than -1 so the legacy
        // settlement fold (`expected_i1 == 0` for this opcode) can match the row
        // and settle it instead of letting it time out.
        command.i32_1 = 0;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_ARMY_PAY: {
        // Opcode 34 (army-pay contract §3): the wages of the heads that march
        // with the formation, paid into its lane from the treasury.
        //   payload0 = amount (MONEY_SCALE), payload1 = country handle,
        //   target_cohort = army handle (the lane key 30-33 already use).
        // No cohort is named and no structural command is involved, so the row
        // rides the same POD lane as 24/30-33 and is deduplicated there by
        // `sequence`.
        //
        // The receipt needs the PRE-PAYMENT lane balance, because the only
        // truth Economy can report afterwards is the new balance and a lane also
        // spends cash on guest consumption the same day. `row.count` carries
        // that base value: the fold reads military_army_funds(handle) and books
        // max(0, now - prev) clamped to the amount requested.
        if (intent.source_id == 0 || intent.country_a == 0 || intent.amount <= 0)
            return;
        if (economy_runtime == nullptr) return;
        if (!army_lane_pay_supported(economy_runtime)) {
            // Feature detection (contract §3.3): this Economy build has no
            // opcode 34. Emitting the row anyway would be an unknown opcode at
            // admission; report a failed receipt instead — a no-op command plus
            // one failed pending row, never a crash — and Military keeps the
            // pre-army-pay model (the formation's people are simply not paid
            // through the lane this day).
            row.authority = 2;
            row.receipt_pending = 0;
            row.opcode = MECONOMY_ARMY_LANE_PAY;
            row.target_handle = static_cast<int64_t>(intent.source_id);
            pending.push_back(row);
            return;
        }
        MilitaryEconomyCommand command;
        command.opcode = MECONOMY_ARMY_LANE_PAY;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.source_id);  // army handle
        command.i64_0 = intent.amount;                                   // MONEY_SCALE
        command.i64_1 = static_cast<int64_t>(intent.country_a);           // payer
        // Unused by opcode 34 (the lane knows its own cell), but 0 rather than
        // -1 so the settlement fold can match the row and settle it.
        command.i32_0 = intent.cell;
        command.i32_1 = 0;
        row.authority = 2;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        // Base value for the receipt: the lane's cash before this payment.
        // Economy answers 0 for a lane that does not exist yet, which is also
        // the correct base (a new lane starts empty), so the read is unconditional.
        row.count = economy_runtime->military_army_funds(
            static_cast<uint64_t>(intent.source_id));
        row.amount = intent.amount;
        pending.push_back(row);
        economy.push_back(command);
        return;
    }
    case MILITARY_INTENT_TRANSFER_TERRITORY: {
        if (intent.cell < 0 || intent.country_b == 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_TRANSFER_TERRITORY;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_b);
        command.cell = intent.cell;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_TRANSFER_CASH: {
        // Opcode 23: target_handle = payer, cell/aux = receiver slot/generation
        // (contract §0.4), value = MONEY_SCALE.
        if (intent.country_a == 0 || intent.country_b == 0 || intent.amount <= 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_TRANSFER_CASH;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.cell = static_cast<int32_t>(intent.country_b & 0xFFFFFFFFull);
        command.aux = static_cast<int32_t>(intent.country_b >> 32u);
        command.value = intent.amount;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_TRANSFER_GOODS: {
        // Opcode 24: same receiver encoding, domain = dense good.
        if (intent.country_a == 0 || intent.country_b == 0 || intent.good < 0 ||
            intent.count <= 0)
            return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_TRANSFER_GOODS;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.cell = static_cast<int32_t>(intent.country_b & 0xFFFFFFFFull);
        command.aux = static_cast<int32_t>(intent.country_b >> 32u);
        command.domain = intent.good;
        command.value = intent.count;
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    case MILITARY_INTENT_ANNEX_COUNTRY: {
        // Opcode 27: target_handle = victim, cell/aux = annexer slot/generation.
        if (intent.country_a == 0 || intent.country_b == 0) return;
        MilitaryCountryCommand command;
        command.opcode = MCOUNTRY_ANNEX;
        command.effective_day = effective_day;
        command.sequence = next_sequence();
        command.target_handle = static_cast<int64_t>(intent.country_a);
        command.cell = static_cast<int32_t>(intent.country_b & 0xFFFFFFFFull);
        command.aux = static_cast<int32_t>(intent.country_b >> 32u);
        row.authority = 1;
        row.sequence = command.sequence;
        row.receipt_pending = 1;
        pending.push_back(row);
        country.push_back(command);
        return;
    }
    default:
        return;
    }
}

MilitaryIntentReceipt DCWorldExt::military_receipt_from(
        const MilitaryPendingIntent &row, bool ok, int64_t committed_count,
        int64_t committed_amount) {
    MilitaryIntentReceipt receipt;
    receipt.kind = row.kind;
    receipt.ok = ok ? 1 : 0;
    receipt.cell = row.cell;
    receipt.source_id = row.source_id;
    receipt.committed_count = ok ? committed_count : 0;
    receipt.committed_amount = ok ? committed_amount : 0;
    return receipt;
}

// ===========================================================================
// ration satisfaction (design §9.2: staple/protein are supplied in kind)
// ===========================================================================

void DCWorldExt::publish_military_ration_satisfaction(
        const MilitaryCore &core, const MilitaryWorldDigest &digest,
        const std::vector<MilitaryIntent> &intents) {
    if (_economy_runtime == nullptr) return;
    NativeEconomyRuntime *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const int32_t soldier_profession = economy->military_soldier_profession();
    if (soldier_profession < 0) return;
    // Real per-cell garrison ration satisfaction for the day just stepped,
    // reconstructed from public const state (military_core.h is frozen):
    //   need  = garrison heads * ration_need_per_head (need units, q16 scale),
    //   met   = ration goods the holder consumed today (the
    //           CONSUME_TREASURY_GOOD intents run_consumption emitted with
    //           source_id = (holder_kind << 32) | holder) * supply yield,
    //           plus ration units still held after consumption (a stocked
    //           garrison that already ate its fill reads 1.0).
    // Ratio = min(1, met / need) in q16. Garrisons are home-cell soldiers, so
    // the lane is per cell, which is what Economy reads. Terrain/consumption
    // multipliers scale need and consumption alike and are omitted.
    // Cells whose garrison disappeared are reset to 1.0 so a stale shortage
    // never lingers. Army lots are not home-cell cohorts in v1 (the soldier
    // cohort stays on its home cell), so only garrison lots are published.
    const int32_t cells_total = core.terrain().cell_count;
    if (cells_total <= 0) return;
    static thread_local std::vector<int64_t> heads;
    static thread_local std::vector<int64_t> met;
    static thread_local std::vector<int32_t> touched;
    static thread_local std::vector<uint8_t> published_prev;
    if (heads.size() != static_cast<size_t>(cells_total)) {
        heads.assign(static_cast<size_t>(cells_total), 0);
        met.assign(static_cast<size_t>(cells_total), 0);
        published_prev.assign(static_cast<size_t>(cells_total), 0);
    }
    touched.clear();
    const MilitaryLotStore &lots = core.lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.location_kind[i] != MILITARY_LOT_GARRISON) continue;
        const int32_t cell = lots.location[i];
        if (cell < 0 || cell >= cells_total) continue;
        if (heads[static_cast<size_t>(cell)] == 0) touched.push_back(cell);
        heads[static_cast<size_t>(cell)] += lots.count[i];
    }
    const MilitaryCatalog &catalog = core.catalog();
    const std::vector<int32_t> &ration_goods = catalog.supply_goods[MILITARY_SUPPLY_RATION];
    const std::vector<int32_t> &ration_yield = catalog.supply_yield_q16[MILITARY_SUPPLY_RATION];
    const auto yield_of = [&](int32_t good) -> int32_t {
        for (size_t g = 0; g < ration_goods.size(); ++g) {
            if (ration_goods[g] != good) continue;
            const int32_t y = g < ration_yield.size() ? ration_yield[g] : MILITARY_Q;
            return y > 0 ? y : MILITARY_Q;
        }
        return 0;
    };
    const auto mul_q = [](int64_t v, int32_t q) { return (v * static_cast<int64_t>(q)) >> 16; };
    for (const MilitaryIntent &intent : intents) {
        if (intent.kind != MILITARY_INTENT_CONSUME_TREASURY_GOOD) continue;
        if ((intent.source_id >> 32) != MILITARY_LOT_GARRISON) continue;
        const int32_t cell = static_cast<int32_t>(intent.source_id & 0xffffffffu);
        if (cell < 0 || cell >= cells_total || heads[static_cast<size_t>(cell)] <= 0) continue;
        const int32_t y = yield_of(intent.good);
        if (y <= 0) continue;
        met[static_cast<size_t>(cell)] += mul_q(intent.count, y);
    }
    for (const MilitaryStockRow &row : core.stocks()) {
        if (row.holder_kind != MILITARY_LOT_GARRISON || row.qty <= 0) continue;
        const int32_t cell = row.holder;
        if (cell < 0 || cell >= cells_total || heads[static_cast<size_t>(cell)] <= 0) continue;
        const int32_t y = yield_of(row.good);
        if (y <= 0) continue;
        met[static_cast<size_t>(cell)] += mul_q(row.qty, y);
    }
    (void)digest;
    const int32_t per_head = catalog.ration_need_per_head_q16 > 0
        ? catalog.ration_need_per_head_q16 : MILITARY_Q;
    std::sort(touched.begin(), touched.end());
    std::vector<int32_t> cells;
    std::vector<int32_t> ratios;
    cells.reserve(touched.size());
    ratios.reserve(touched.size());
    std::vector<uint8_t> now_published(published_prev.size(), 0);
    for (const int32_t cell : touched) {
        const size_t c = static_cast<size_t>(cell);
        const int64_t need = mul_q(heads[c], per_head);
        int64_t ratio = MILITARY_Q;
        if (need > 0) ratio = std::min<int64_t>(MILITARY_Q, (met[c] * MILITARY_Q) / need);
        cells.push_back(cell);
        ratios.push_back(static_cast<int32_t>(std::max<int64_t>(0, ratio)));
        now_published[c] = 1;
        heads[c] = 0;
        met[c] = 0;
    }
    // Garrisons that vanished since the last publish go back to 1.0.
    for (size_t c = 0; c < published_prev.size(); ++c) {
        if (published_prev[c] == 0 || now_published[c] != 0) continue;
        cells.push_back(static_cast<int32_t>(c));
        ratios.push_back(MILITARY_Q);
    }
    published_prev.swap(now_published);
    if (!cells.empty()) {
        economy->set_military_ration_satisfaction(cells, ratios);
    }
    // ---- army lanes (contract §2.2) --------------------------------------
    // A deployed formation is not a home-cell cohort: its people sit in an
    // Economy lane keyed by army handle, so the staple/protein satisfaction has
    // to be published per formation. The core already keeps the 3-day EMA of
    // exactly that ratio (run_consumption, sec 10 morale input); no
    // reconstruction is needed here. Garrisons keep the per-cell lane above.
    if (economy_army_lane_supported(economy)) {
        const MilitaryArmyStore &armies = core.armies();
        for (size_t slot = 0; slot < armies.active.size(); ++slot) {
            if (armies.active[slot] == 0) continue;
            if (armies.cached_headcount[slot] <= 0) continue;
            const uint64_t handle = core.army_handle(static_cast<int32_t>(slot));
            if (handle == 0) continue;
            const int32_t q16 = std::clamp<int32_t>(
                armies.ration_ratio_q16[slot], 0, MILITARY_Q);
            economy_set_army_ration(economy, handle, q16);
        }
    }
}

// ===========================================================================
// queries (cold: HUD, inspector, render feed)
// ===========================================================================

Dictionary DCWorldExt::get_military_report() {
    if (_military_runtime == nullptr) {
        Dictionary out = military_unavailable();
        out["configured"] = false;
        return out;
    }
    const MilitaryCore *core = core_from(_military_runtime);
    const MilitaryReport &report = core->report();
    Dictionary out;
    out["ok"] = true;
    out["configured"] = core->configured();
    out["day"] = report.day;
    out["military_day_ms"] = report.day_ms;
    out["armies_active"] = static_cast<int64_t>(report.armies_active);
    out["armies_moving"] = static_cast<int64_t>(report.armies_moving);
    out["engagements_active"] = static_cast<int64_t>(report.engagements_active);
    out["astar_expansions"] = report.astar_expansions;
    out["area_evals"] = static_cast<int64_t>(report.area_evals);
    out["threat_field_cells"] = static_cast<int64_t>(report.threat_field_cells);
    out["convoys_due"] = static_cast<int64_t>(report.convoys_due);
    out["convoy_hops"] = report.convoy_hops;
    out["front_edges_touched"] = static_cast<int64_t>(report.front_edges_touched);
    out["vision_patch_cells"] = static_cast<int64_t>(report.vision_patch_cells);
    out["event_coalesced"] = static_cast<int64_t>(report.event_coalesced);
    out["reconcile_delta"] = report.reconcile_delta;
    out["intents_emitted"] = static_cast<int64_t>(report.intents_emitted);
    out["wars_active"] = static_cast<int64_t>(report.wars_active);
    out["soldiers_total"] = report.soldiers_total;
    out["idle"] = report.idle != 0;
    // State building cache diagnostics (requirement 6.4). They are transient:
    // a nonzero `state_cache_repairs` means "the economy ledger disagreed with
    // the cache on this day", not "the save is broken".
    out["state_cache_repairs"] = static_cast<int64_t>(report.state_cache_repairs);
    out["state_ledger_unmapped"] = static_cast<int64_t>(report.state_ledger_unmapped);
    out["state_role_mismatch"] = static_cast<int64_t>(report.state_role_mismatch);
    out["configured_units"] = static_cast<int64_t>(core->catalog().units.size());
    out["catalog_hash"] = static_cast<int64_t>(core->catalog().hash);
    out["last_step_day"] = _military_last_step_day;
    out["sequence_cursor"] = _military_sequence;
    out["pending_intents"] = static_cast<int64_t>(_military_pending_intents.size());
    out["ledger_received"] = core->_ledger_received;
    out["ledger_consumed"] = core->_ledger_consumed;
    out["ledger_stock"] = core->ledger_stock_total();
    out["ledger_transit"] = core->ledger_transit_total();
    out["has_terrain"] = core->terrain().cell_count > 0;
    out["cell_count"] = static_cast<int64_t>(core->terrain().cell_count);
    out["state_hash"] = static_cast<int64_t>(core->state_hash() & 0x7fffffffffffffffll);
    out["render_revision"] = _military_render_revision;
    return out;
}

Dictionary DCWorldExt::get_military_country_snapshot(int64_t country) const {
    if (_military_runtime == nullptr) return military_unavailable();
    const MilitaryCore *core = core_from(_military_runtime);
    const int32_t slot = core->country_slot_for_handle(static_cast<uint64_t>(country));
    if (slot < 0) return military_fail("military_country_slot_unknown");
    Dictionary out;
    out["ok"] = true;
    out["country"] = static_cast<int64_t>(core->country_handle_for_slot(slot));
    out["country_slot"] = static_cast<int64_t>(slot);

    // ---- force overview ----
    int64_t militia = 0, trained = 0, in_armies = 0, garrisoned = 0;
    const MilitaryLotStore &lots = core->lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.country_slot[i] != slot) continue;
        const int32_t unit = lots.unit_type[i];
        const bool is_militia = unit >= 0 &&
            unit < static_cast<int32_t>(core->catalog().units.size()) &&
            core->catalog().units[static_cast<size_t>(unit)].is_default_militia != 0;
        if (is_militia) militia += lots.count[i];
        else trained += lots.count[i];
        if (lots.location_kind[i] == MILITARY_LOT_ARMY) in_armies += lots.count[i];
        else garrisoned += lots.count[i];
    }
    int64_t training = 0;
    for (const MilitaryTrainingOrder &order : core->training()) {
        if (order.country_slot == slot) training += std::max<int64_t>(0, order.count);
    }
    out["soldiers_total"] = core->country_soldiers(slot);
    out["soldiers_militia"] = militia;
    out["soldiers_trained"] = trained;
    out["soldiers_garrisoned"] = garrisoned;
    out["soldiers_in_armies"] = in_armies;
    out["soldiers_training"] = training;

    // ---- policy / target / config ----
    const std::vector<MilitaryCountryPolicy> &policies = core->policies();
    if (static_cast<size_t>(slot) < policies.size()) {
        const MilitaryCountryPolicy &policy = policies[static_cast<size_t>(slot)];
        out["has_policy"] = true;
        out["target_mode"] = static_cast<int64_t>(policy.target_mode);
        out["target_value"] = policy.target_value;
        out["effective_target"] = policy.effective_target;
        out["levy_enabled"] = policy.levy_enabled != 0;
        out["auto_retrain"] = policy.auto_retrain != 0;
        out["auto_discharge"] = policy.auto_discharge != 0;
        out["quality_policy"] = static_cast<int64_t>(policy.quality_policy);
        out["wage_mode"] = static_cast<int64_t>(policy.wage_mode);
        out["wage_absolute"] = policy.wage_absolute;
        out["procurement_share_bp"] = static_cast<int64_t>(policy.procurement_share_bp);
        // ---- budget envelope (任务 6). `budget_enabled == false` is the
        // documented "no envelope" state: the panel keeps the read-only block
        // and the native settlement keeps the legacy cash-driven path, so both
        // sides agree on what an absent policy means.
        out["budget_share_bp"] = static_cast<int64_t>(policy.budget_share_bp);
        out["budget_enabled"] = policy.budget_share_bp > 0;
        out["budget_wage_bp"] = static_cast<int64_t>(policy.budget_wage_bp);
        out["budget_upkeep_bp"] = static_cast<int64_t>(policy.budget_upkeep_bp);
        // The channel ceilings need the envelope base, which is the country's
        // committed treasury cash (需求 5.1). Publish the split so the panel and
        // the settlement cannot drift apart.
        const MilitaryCore::MilitaryBudgetSplit split =
            core->budget_split(slot, core->last_country_cash(slot));
        out["budget_envelope_daily"] = split.envelope_daily;
        out["budget_wage_daily"] = split.enabled ? split.wage_ceiling : -1;
        out["budget_upkeep_daily"] = split.enabled ? split.upkeep_ceiling : -1;
        out["budget_procurement_daily"] = split.enabled ? split.procurement_ceiling : -1;
        out["pay_ratio_30_q16"] = static_cast<int64_t>(policy.pay_ratio_30_q16);
        out["spend_payroll_30"] = policy.spend_payroll_30;
        out["spend_procurement_30"] = policy.spend_procurement_30;
        out["spend_upkeep_30"] = policy.spend_upkeep_30;
        // ---- budget settlement outcome (任务 7 / 需求 5.2, 5.3, 7.1) -------
        // Per-step, non-cumulative: these describe the LAST settled day, so the
        // panel paints today's shortfall/overspend and forgets it tomorrow. All
        // six stay 0 when the country has no envelope.
        out["budget_wage_demand"] = policy.wage_demand;
        out["budget_wage_arrears"] = policy.wage_arrears;
        out["budget_wage_overspend"] = policy.wage_overspend;
        out["budget_upkeep_demand"] = policy.upkeep_demand;
        out["budget_upkeep_arrears"] = policy.upkeep_arrears;
        out["budget_upkeep_overspend"] = policy.upkeep_overspend;
        // ---- procurement quota outcome (任务 8 / 需求 5.4, 6.2, 7.1) ------
        // `procurement_budget_used` is money committed to markets on the last
        // procurement pass, read off the same `cost` the intents carry, so it
        // reconciles with the treasury one-for-one. `procurement_deferred_units`
        // is the need-unit gap the QUOTA refused (not the gap no market could
        // fill), which is what the panel labels 待购. Both stay 0 with no
        // envelope, so a country without budget control looks exactly as before.
        out["budget_procurement_used"] = policy.procurement_budget_used;
        out["budget_procurement_deferred_units"] = policy.procurement_deferred_units;
        out["per_soldier_cost"] = policy.per_soldier_cost;
        // The per-head DAILY WAGE both pay paths use (army-pay contract §2.2):
        // ABSOLUTE takes the policy value, AUTO is living cost x the MSTAT_WAGE
        // stat. `country_soldier_living_cost` is the input the AUTO branch reads,
        // published so a test can recompute the same number instead of guessing.
        out["daily_wage"] = core->soldier_daily_wage(slot);
        out["soldier_living_cost"] = core->soldier_living_cost(slot);
        PackedInt32Array shares;
        shares.resize(static_cast<int64_t>(policy.config_share_bp.size()));
        for (int64_t i = 0; i < shares.size(); ++i)
            shares[i] = policy.config_share_bp[static_cast<size_t>(i)];
        out["config_share_bp"] = shares;
    } else {
        out["has_policy"] = false;
    }

    // ---- barracks (cell states + posts) ----
    Array barracks;
    int64_t posts_total = 0;
    const std::vector<MilitaryCellState> &states = core->cell_states();
    for (const MilitaryCellState &state : states) {
        if (state.cell < 0) continue;
        int32_t building_count = 0;
        for (int32_t tier = 0; tier < 8; ++tier) building_count += state.barracks_count[tier];
        const int32_t posts = core->posts_for_cell(state.cell, slot);
        if (building_count == 0 && posts == 0 && state.quota == 0) continue;
        Dictionary row;
        row["cell"] = static_cast<int64_t>(state.cell);
        row["post_count"] = static_cast<int64_t>(posts);
        row["present"] = core->present_for_cell(state.cell);
        row["open"] = static_cast<int64_t>(std::max<int64_t>(
            0, posts - core->present_for_cell(state.cell) - state.pending_enlist));
        row["quota"] = state.quota;
        row["pending_enlist"] = state.pending_enlist;
        row["paused"] = state.paused != 0;
        row["disrepair"] = state.disrepair != 0;
        row["fort_tier"] = static_cast<int64_t>(state.fort_tier);
        row["college_tier"] = static_cast<int64_t>(state.college_tier);
        barracks.push_back(row);
        posts_total += posts;
    }
    out["barracks"] = barracks;
    out["post_count"] = posts_total;

    // ---- training queue ----
    Array queue;
    for (const MilitaryTrainingOrder &order : core->training()) {
        if (order.country_slot != slot) continue;
        Dictionary row;
        row["id"] = static_cast<int64_t>(order.id);
        row["cell"] = static_cast<int64_t>(order.cell);
        row["from_unit"] = static_cast<int64_t>(order.from_unit);
        row["to_unit"] = static_cast<int64_t>(order.to_unit);
        row["count"] = order.count;
        row["days_total"] = static_cast<int64_t>(order.days_total);
        row["days_done"] = static_cast<int64_t>(order.days_done);
        row["equipment_ready"] = order.equipment_ready != 0;
        row["quality_q8"] = static_cast<int64_t>(order.quality_q8);
        queue.push_back(row);
    }
    out["training"] = queue;

    // ---- wars ----
    Array wars;
    for (const MilitaryWar &war : core->wars()) {
        if (!war.active) continue;
        if (war.attacker_slot != slot && war.defender_slot != slot) continue;
        const bool attacker = war.attacker_slot == slot;
        int32_t score = war.score_battle_q16 + war.score_annihilation_q16 +
            war.score_attrition_q16;
        if (!attacker) score = -score;
        Dictionary row;
        row["war_id"] = static_cast<int64_t>(war.id);
        row["attacker_slot"] = static_cast<int64_t>(war.attacker_slot);
        row["defender_slot"] = static_cast<int64_t>(war.defender_slot);
        row["start_day"] = war.start_day;
        row["score_q16"] = static_cast<int64_t>(score);
        row["attacker_losses"] = war.attacker_losses;
        row["defender_losses"] = war.defender_losses;
        row["fully_occupied"] = (attacker ? war.fully_occupied_since_b
                                         : war.fully_occupied_since_a) >= 0;
        wars.push_back(row);
    }
    out["wars"] = wars;
    out["wars_active"] = static_cast<int64_t>(wars.size());
    return out;
}

Array DCWorldExt::get_military_armies(int64_t country) const {
    Array out;
    if (_military_runtime == nullptr) return out;
    const MilitaryCore *core = core_from(_military_runtime);
    const int32_t slot = core->country_slot_for_handle(static_cast<uint64_t>(country));
    if (slot < 0) {
        // 0 means "every army", which the map UI uses for the overview.
        if (country != 0) return out;
    }
    const MilitaryArmyStore &armies = core->armies();
    for (int32_t i = 0; i < static_cast<int32_t>(armies.active.size()); ++i) {
        if (!armies.active[static_cast<size_t>(i)]) continue;
        if (country != 0 && armies.owner_slot[static_cast<size_t>(i)] != slot) continue;
        Dictionary row;
        row["handle"] = static_cast<int64_t>(core->army_handle(i));
        row["owner_slot"] = static_cast<int64_t>(armies.owner_slot[static_cast<size_t>(i)]);
        row["cell"] = static_cast<int64_t>(armies.cell[static_cast<size_t>(i)]);
        row["headcount"] = armies.cached_headcount[static_cast<size_t>(i)];
        row["attack_q16"] = armies.cached_attack_q16[static_cast<size_t>(i)];
        row["defense_q16"] = armies.cached_defense_q16[static_cast<size_t>(i)];
        row["speed_q16"] = static_cast<int64_t>(armies.cached_speed_q16[static_cast<size_t>(i)]);
        row["morale_q16"] = static_cast<int64_t>(armies.morale_q16[static_cast<size_t>(i)]);
        row["organization_q16"] = static_cast<int64_t>(
            armies.organization_q16[static_cast<size_t>(i)]);
        row["supply_ratio_q16"] = static_cast<int64_t>(
            armies.supply_ratio_q16[static_cast<size_t>(i)]);
        row["ration_ratio_q16"] = static_cast<int64_t>(
            armies.ration_ratio_q16[static_cast<size_t>(i)]);
        row["pay_ratio_q16"] = static_cast<int64_t>(armies.pay_ratio_q16[static_cast<size_t>(i)]);
        row["stance"] = static_cast<int64_t>(armies.stance[static_cast<size_t>(i)]);
        row["mission"] = static_cast<int64_t>(armies.mission[static_cast<size_t>(i)]);
        row["target_cell"] = static_cast<int64_t>(armies.target_cell[static_cast<size_t>(i)]);
        row["engagement"] = static_cast<int64_t>(armies.engagement[static_cast<size_t>(i)]);
        row["moved_day"] = armies.moved_day[static_cast<size_t>(i)];
        row["prev_cell"] = static_cast<int64_t>(armies.prev_cell[static_cast<size_t>(i)]);
        row["reinforce_enabled"] = armies.reinforce_enabled[static_cast<size_t>(i)] != 0;
        row["name_seed"] = static_cast<int64_t>(armies.name_seed[static_cast<size_t>(i)]);
        out.push_back(row);
    }
    return out;
}

Dictionary DCWorldExt::get_military_army(int64_t army) {
    if (_military_runtime == nullptr) return military_unavailable();
    const MilitaryCore *core = core_from(_military_runtime);
    int32_t slot = -1;
    if (!core->resolve_army(static_cast<uint64_t>(army), slot))
        return military_fail("military_army_unknown");
    const MilitaryArmyStore &armies = core->armies();
    const size_t s = static_cast<size_t>(slot);
    Dictionary out;
    out["ok"] = true;
    out["handle"] = static_cast<int64_t>(core->army_handle(slot));
    out["owner_slot"] = static_cast<int64_t>(armies.owner_slot[s]);
    out["cell"] = static_cast<int64_t>(armies.cell[s]);
    out["next_cell"] = static_cast<int64_t>(armies.next_cell[s]);
    out["headcount"] = armies.cached_headcount[s];
    out["attack_q16"] = armies.cached_attack_q16[s];
    out["defense_q16"] = armies.cached_defense_q16[s];
    out["speed_q16"] = static_cast<int64_t>(armies.cached_speed_q16[s]);
    out["organization_q16"] = static_cast<int64_t>(armies.organization_q16[s]);
    out["morale_q16"] = static_cast<int64_t>(armies.morale_q16[s]);
    out["supply_ratio_q16"] = static_cast<int64_t>(armies.supply_ratio_q16[s]);
    out["ration_ratio_q16"] = static_cast<int64_t>(armies.ration_ratio_q16[s]);
    out["pay_ratio_q16"] = static_cast<int64_t>(armies.pay_ratio_q16[s]);
    out["stance"] = static_cast<int64_t>(armies.stance[s]);
    out["mission"] = static_cast<int64_t>(armies.mission[s]);
    out["target_cell"] = static_cast<int64_t>(armies.target_cell[s]);
    out["area_id"] = static_cast<int64_t>(armies.area_id[s]);
    out["engagement"] = static_cast<int64_t>(armies.engagement[s]);
    out["move_points_q16"] = static_cast<int64_t>(armies.move_points_q16[s]);
    out["reinforce_enabled"] = armies.reinforce_enabled[s] != 0;
    out["funds"] = armies.funds[s];
    // ---- personnel lane (army-personnel contract §2.1) --------------------
    // `headcount` is what Military books; `personnel` is what Economy actually
    // holds in the formation's lane row. They are the same people and must stay
    // equal, so both are reported (an older economy without the lane bindings
    // reports the military book and lane_supported = false).
    const bool lane_supported = _economy_runtime != nullptr &&
        economy_army_lane_supported(_economy_runtime);
    int64_t lane_population = -1;
    if (lane_supported) {
        lane_population = economy_army_lane_population(_economy_runtime,
            core->army_handle(slot));
    }
    out["lane_supported"] = lane_supported;
    out["lane_population"] = lane_population;
    // Lane cash: what the formation's people actually hold in Economy. Army pay
    // (contract §3) lands here, so the smoke test asserts on this instead of the
    // Military-side `funds` mirror, which only the pre-lane bookkeeping touched.
    int64_t lane_funds = -1;
    if (lane_supported) {
        lane_funds = economy_army_lane_funds(_economy_runtime,
            core->army_handle(slot));
    }
    out["lane_funds"] = lane_funds;
    out["lane_pay_supported"] = army_lane_pay_supported(
        static_cast<const NativeEconomyRuntime *>(_economy_runtime));
    out["personnel"] = lane_population >= 0 ? lane_population : armies.cached_headcount[s];
    out["personnel_pending"] = core->army_lane_pending(slot);
    // Ration still in the formation's store (need units of the ration class).
    out["ration_stock"] = core->stock_units(armies.owner_slot[s], MILITARY_LOT_ARMY,
        slot, MILITARY_SUPPLY_RATION);
    out["moved_day"] = armies.moved_day[s];
    out["prev_cell"] = static_cast<int64_t>(armies.prev_cell[s]);
    out["name_seed"] = static_cast<int64_t>(armies.name_seed[s]);
    // commander: v1 keeps the seat open (design §6.4).
    Dictionary commander;
    commander["open"] = true;
    commander["slot"] = static_cast<int64_t>(armies.commander_slot[s]);
    commander["handle"] = static_cast<int64_t>(0);
    out["commander"] = commander;
    // ---- composition ----
    Array composition;
    const MilitaryLotStore &lots = core->lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.location_kind[i] != MILITARY_LOT_ARMY || lots.location[i] != slot) continue;
        Dictionary row;
        row["unit"] = static_cast<int64_t>(lots.unit_type[i]);
        row["count"] = lots.count[i];
        row["quality_q8"] = static_cast<int64_t>(lots.equip_quality_q8[i]);
        row["condition_q16"] = static_cast<int64_t>(lots.condition_q16[i]);
        composition.push_back(row);
    }
    out["composition"] = composition;
    // ---- supply days by class ----
    PackedInt64Array supply_days;
    supply_days.resize(MILITARY_SUPPLY_CLASSES);
    for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
        const int64_t units = core->stock_units(armies.owner_slot[s],
            MILITARY_LOT_ARMY, slot, cls);
        supply_days[cls] = armies.cached_headcount[s] > 0
            ? units * 100 / std::max<int64_t>(1, armies.cached_headcount[s]) : 0;
    }
    out["supply_days"] = supply_days;
    // ---- convoys bound for this army ----
    Array convoys;
    for (const MilitaryShipment &shipment : core->shipments()) {
        if (shipment.qty <= 0) continue;
        if (shipment.dest_kind != 1 || shipment.dest != slot) continue;
        Dictionary row;
        row["id"] = static_cast<int64_t>(shipment.id);
        row["good"] = static_cast<int64_t>(shipment.good);
        row["qty"] = shipment.qty;
        row["current_cell"] = static_cast<int64_t>(shipment.current_cell);
        row["eta_day"] = shipment.eta_day;
        row["progress_q16"] = static_cast<int64_t>(shipment.progress_q16);
        convoys.push_back(row);
    }
    out["convoys"] = convoys;
    // ---- path preview ----
    PackedInt32Array path;
    const int32_t path_begin = armies.path_cursor[s];
    for (int32_t k = path_begin; k < armies.path_len[s]; ++k) {
        const int32_t offset = armies.path_offset[s] + k;
        if (offset < 0 || static_cast<size_t>(offset) >= core->_path_cells.size()) break;
        path.push_back(core->_path_cells[static_cast<size_t>(offset)]);
    }
    out["path"] = path;
    return out;
}

Dictionary DCWorldExt::get_military_cell_snapshot(int64_t cell, int64_t observer) const {
    if (_military_runtime == nullptr) return military_unavailable();
    (void)observer;  // v1: the military roster is not fog-filtered
    const MilitaryCore *core = core_from(_military_runtime);
    if (cell < 0 || cell >= core->terrain().cell_count)
        return military_fail("military_cell_out_of_range");
    const int32_t c = static_cast<int32_t>(cell);
    // Owner comes from Country (Military only stores controllers).
    int32_t owner_slot = -1;
    if (_country_runtime != nullptr)
        owner_slot = static_cast<NativeCountryRuntime *>(_country_runtime)
            ->country_slot_for_cell(c);
    const int32_t controller = core->controller_of(c);
    Dictionary out;
    out["ok"] = true;
    out["cell"] = static_cast<int64_t>(c);
    out["owner_slot"] = static_cast<int64_t>(owner_slot);
    out["controller_slot"] = static_cast<int64_t>(
        controller >= 0 ? controller : owner_slot);
    out["post_count"] = static_cast<int64_t>(core->posts_for_cell(c, owner_slot));
    out["present"] = core->present_for_cell(c);
    out["garrison"] = core->present_for_cell(c);
    int64_t quota = 0, pending = 0, fort_tier = -1, college_tier = -1;
    bool paused = false, disrepair = false;
    // Per-tier barracks counts and running state builds, so the tile dossier can
    // show "how many of which tier" and target a demolish at the exact catalog
    // row instead of guessing from `post_count`.
    PackedInt32Array barracks_tiers;
    barracks_tiers.resize(MILITARY_STATE_BARRACKS_TIERS);
    barracks_tiers.fill(0);
    PackedInt32Array construction_buildings;
    construction_buildings.resize(MILITARY_STATE_BUILD_SLOTS);
    construction_buildings.fill(-1);
    PackedInt32Array construction_done_days;
    construction_done_days.resize(MILITARY_STATE_BUILD_SLOTS);
    construction_done_days.fill(-1);
    for (const MilitaryCellState &state : core->cell_states()) {
        if (state.cell != c) continue;
        quota = state.quota;
        pending = state.pending_enlist;
        fort_tier = state.fort_tier;
        college_tier = state.college_tier;
        paused = state.paused != 0;
        disrepair = state.disrepair != 0;
        for (int32_t tier = 0; tier < MILITARY_STATE_BARRACKS_TIERS; ++tier)
            barracks_tiers[tier] = state.barracks_count[tier];
        for (int32_t k = 0; k < MILITARY_STATE_BUILD_SLOTS; ++k) {
            construction_buildings[k] = state.construction_building[k];
            construction_done_days[k] = static_cast<int32_t>(std::clamp<int64_t>(
                state.construction_done_day[k], -1,
                std::numeric_limits<int32_t>::max()));
        }
        break;
    }
    out["quota"] = quota;
    out["pending_enlist"] = pending;
    out["fort_tier"] = fort_tier;
    out["college_tier"] = college_tier;
    out["paused"] = paused;
    out["disrepair"] = disrepair;
    out["barracks_tiers"] = barracks_tiers;
    out["construction_buildings"] = construction_buildings;
    out["construction_done_days"] = construction_done_days;
    // Garrison composition (lots located in this cell).
    Array garrison;
    const MilitaryLotStore &lots = core->lots();
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i] || lots.count[i] <= 0) continue;
        if (lots.location_kind[i] != MILITARY_LOT_GARRISON || lots.location[i] != c) continue;
        Dictionary row;
        row["country_slot"] = static_cast<int64_t>(lots.country_slot[i]);
        row["unit"] = static_cast<int64_t>(lots.unit_type[i]);
        row["count"] = lots.count[i];
        row["quality_q8"] = static_cast<int64_t>(lots.equip_quality_q8[i]);
        garrison.push_back(row);
    }
    out["garrison_lots"] = garrison;
    // Visiting armies (design §5.4 "in-station / foreign").
    Array armies_here;
    const MilitaryArmyStore &armies = core->armies();
    for (size_t i = 0; i < armies.active.size(); ++i) {
        if (!armies.active[i] || armies.cell[i] != c) continue;
        Dictionary row;
        row["handle"] = static_cast<int64_t>(core->army_handle(static_cast<int32_t>(i)));
        row["owner_slot"] = static_cast<int64_t>(armies.owner_slot[i]);
        row["headcount"] = armies.cached_headcount[i];
        row["foreign"] = armies.owner_slot[i] != owner_slot;
        armies_here.push_back(row);
    }
    out["armies"] = armies_here;
    // Local training queue.
    Array training;
    for (const MilitaryTrainingOrder &order : core->training()) {
        if (order.cell != c) continue;
        Dictionary row;
        row["id"] = static_cast<int64_t>(order.id);
        row["country_slot"] = static_cast<int64_t>(order.country_slot);
        row["from_unit"] = static_cast<int64_t>(order.from_unit);
        row["to_unit"] = static_cast<int64_t>(order.to_unit);
        row["count"] = order.count;
        row["days_done"] = static_cast<int64_t>(order.days_done);
        row["days_total"] = static_cast<int64_t>(order.days_total);
        training.push_back(row);
    }
    out["training"] = training;
    return out;
}

Dictionary DCWorldExt::get_military_render_snapshot(int64_t after_revision) {
    if (_military_runtime == nullptr) {
        Dictionary out = military_unavailable();
        out["available"] = false;
        out["revision"] = after_revision;
        return out;
    }
    const MilitaryCore *core = core_from(_military_runtime);
    Dictionary out;
    out["ok"] = true;
    out["available"] = true;
    out["revision"] = _military_render_revision;
    const int64_t control_revision = static_cast<int64_t>(core->control_revision());
    const int64_t front_revision = static_cast<int64_t>(core->front_revision());
    out["control_revision"] = control_revision;
    out["front_revision"] = front_revision;
    if (after_revision == _military_render_revision &&
        control_revision == _military_render_control_revision &&
        front_revision == _military_render_front_revision) {
        // Unchanged: the feed keeps its previous arrays and does no work.
        out["unchanged"] = true;
        return out;
    }
    out["unchanged"] = false;
    _military_render_revision = std::max<int64_t>(_military_render_revision, after_revision);
    _military_render_control_revision = control_revision;
    _military_render_front_revision = front_revision;
    // ---- armies ----
    const MilitaryArmyStore &armies = core->armies();
    int32_t army_count = 0;
    for (size_t i = 0; i < armies.active.size(); ++i)
        if (armies.active[i]) ++army_count;
    PackedInt64Array handle, headcount, composition_weight;
    PackedInt32Array owner, cell, prev_cell, moved_day, flags;
    PackedInt32Array composition_offsets, composition_unit;
    PackedInt32Array heading_q16, attack_seq, hit_seq;
    PackedByteArray unit_class;
    handle.resize(army_count);
    headcount.resize(army_count);
    owner.resize(army_count);
    cell.resize(army_count);
    prev_cell.resize(army_count);
    moved_day.resize(army_count);
    flags.resize(army_count);
    unit_class.resize(army_count);
    composition_offsets.resize(static_cast<int64_t>(army_count) + 1);
    composition_offsets[0] = 0;
    composition_unit.resize(static_cast<int64_t>(army_count) * 3);
    composition_weight.resize(static_cast<int64_t>(army_count) * 3);
    heading_q16.resize(army_count);
    attack_seq.resize(army_count);
    hit_seq.resize(army_count);
    std::vector<int32_t> army_lane(armies.active.size(), -1);
    std::vector<int32_t> dominant_lot_unit(army_count, -1);
    std::vector<int64_t> dominant_lot_count(army_count, 0);
    int32_t lane = 0;
    for (int32_t i = 0; i < static_cast<int32_t>(armies.active.size()); ++i) {
        if (!armies.active[static_cast<size_t>(i)]) continue;
        army_lane[static_cast<size_t>(i)] = lane;
        handle[lane] = static_cast<int64_t>(core->army_handle(i));
        owner[lane] = armies.owner_slot[static_cast<size_t>(i)];
        cell[lane] = armies.cell[static_cast<size_t>(i)];
        prev_cell[lane] = armies.prev_cell[static_cast<size_t>(i)];
        moved_day[lane] = static_cast<int32_t>(std::clamp<int64_t>(
            armies.moved_day[static_cast<size_t>(i)], -1,
            std::numeric_limits<int32_t>::max()));
        headcount[lane] = armies.cached_headcount[static_cast<size_t>(i)];
        int32_t bits = 0;
        if (armies.supply_ratio_q16[static_cast<size_t>(i)] < MILITARY_Q / 2) bits |= 1 << 0;
        if (armies.ration_ratio_q16[static_cast<size_t>(i)] < MILITARY_Q / 4) bits |= 1 << 1;
        if (armies.pay_ratio_q16[static_cast<size_t>(i)] < (MILITARY_Q * 6) / 10) bits |= 1 << 2;
        if (armies.morale_q16[static_cast<size_t>(i)] < (MILITARY_Q * 4) / 10) bits |= 1 << 3;
        if (armies.engagement[static_cast<size_t>(i)] >= 0) bits |= 1 << 4;
        if (armies.stance[static_cast<size_t>(i)] == MILITARY_STANCE_RETREAT) bits |= 1 << 5;
        flags[lane] = bits;
        heading_q16[lane] = 0;  // East; runtime quad rotation supplies other headings.
        attack_seq[lane] = 0;
        hit_seq[lane] = 0;
        ++lane;
    }

    // Aggregate army lots once by (army lane, dense unit id), then derive both
    // the existing dominant class and the new top-three visual composition.
    const MilitaryLotStore &lots = core->lots();
    const size_t unit_count = core->catalog().units.size();
    std::vector<int64_t> unit_weight_by_army(
        static_cast<size_t>(army_count) * unit_count, 0);
    for (size_t lot = 0; lot < lots.active.size(); ++lot) {
        if (!lots.active[lot] || lots.count[lot] <= 0) continue;
        if (lots.location_kind[lot] != MILITARY_LOT_ARMY) continue;
        const int32_t army_slot = lots.location[lot];
        if (army_slot < 0 || static_cast<size_t>(army_slot) >= army_lane.size()) continue;
        const int32_t lot_lane = army_lane[static_cast<size_t>(army_slot)];
        if (lot_lane < 0) continue;
        if (lots.count[lot] > dominant_lot_count[static_cast<size_t>(lot_lane)]) {
            dominant_lot_count[static_cast<size_t>(lot_lane)] = lots.count[lot];
            dominant_lot_unit[static_cast<size_t>(lot_lane)] = lots.unit_type[lot];
        }
        const int32_t unit = lots.unit_type[lot];
        if (unit < 0 || static_cast<size_t>(unit) >= unit_count) continue;
        unit_weight_by_army[static_cast<size_t>(lot_lane) * unit_count +
            static_cast<size_t>(unit)] += lots.count[lot];
    }
    int32_t composition_count = 0;
    for (int32_t row = 0; row < army_count; ++row) {
        const size_t weight_base = static_cast<size_t>(row) * unit_count;
        std::array<int32_t, 3> top_units = {-1, -1, -1};
        for (int32_t term = 0; term < 3; ++term) {
            int32_t best_unit = -1;
            int64_t best_weight = 0;
            for (size_t unit = 0; unit < unit_count; ++unit) {
                const int64_t weight = unit_weight_by_army[weight_base + unit];
                if (weight <= 0) continue;
                bool already_selected = false;
                for (int32_t selected = 0; selected < term; ++selected) {
                    if (top_units[static_cast<size_t>(selected)] ==
                        static_cast<int32_t>(unit)) {
                        already_selected = true;
                        break;
                    }
                }
                if (already_selected) continue;
                if (weight > best_weight ||
                    (weight == best_weight &&
                     (best_unit < 0 || static_cast<int32_t>(unit) < best_unit))) {
                    best_unit = static_cast<int32_t>(unit);
                    best_weight = weight;
                }
            }
            if (best_unit < 0) break;
            top_units[static_cast<size_t>(term)] = best_unit;
            composition_unit[composition_count] = best_unit;
            composition_weight[composition_count] = best_weight;
            ++composition_count;
        }
        composition_offsets[row + 1] = composition_count;
        const int32_t dominant_unit = dominant_lot_unit[static_cast<size_t>(row)];
        unit_class[row] = (dominant_unit >= 0 &&
            static_cast<size_t>(dominant_unit) < unit_count)
            ? core->catalog().units[static_cast<size_t>(dominant_unit)].unit_class : 0;
    }
    composition_unit.resize(composition_count);
    composition_weight.resize(composition_count);
    Dictionary army_rows;
    army_rows["handle"] = handle;
    army_rows["owner_slot"] = owner;
    army_rows["cell"] = cell;
    army_rows["prev_cell"] = prev_cell;
    army_rows["moved_day"] = moved_day;
    army_rows["unit_class"] = unit_class;
    army_rows["headcount"] = headcount;
    army_rows["flags"] = flags;
    army_rows["composition_offsets"] = composition_offsets;
    army_rows["composition_unit"] = composition_unit;
    army_rows["composition_weight"] = composition_weight;
    army_rows["heading_q16"] = heading_q16;
    army_rows["attack_seq"] = attack_seq;
    army_rows["hit_seq"] = hit_seq;
    out["armies"] = army_rows;
    out["army_count"] = static_cast<int64_t>(army_count);
    // ---- engagements ----
    const std::vector<MilitaryEngagement> &engagements = core->engagements();
    int32_t engagement_count = 0;
    for (const MilitaryEngagement &e : engagements)
        if (e.active) ++engagement_count;
    PackedInt32Array e_a, e_b, e_progress, e_attacker;
    PackedByteArray e_battle;
    e_a.resize(engagement_count);
    e_b.resize(engagement_count);
    e_progress.resize(engagement_count);
    e_attacker.resize(engagement_count);
    e_battle.resize(engagement_count);
    int32_t e_lane = 0;
    for (const MilitaryEngagement &e : engagements) {
        if (!e.active) continue;
        e_a[e_lane] = e.cell_a;
        e_b[e_lane] = e.cell_b;
        e_progress[e_lane] = e.progress_q16;
        e_attacker[e_lane] = e.attacker_slot;
        e_battle[e_lane] = e.days_since_battle == 0 ? 1 : 0;
        ++e_lane;
    }
    Dictionary engagement_rows;
    engagement_rows["cell_a"] = e_a;
    engagement_rows["cell_b"] = e_b;
    engagement_rows["progress_q16"] = e_progress;
    engagement_rows["attacker_slot"] = e_attacker;
    engagement_rows["battle"] = e_battle;
    out["engagements"] = engagement_rows;
    out["engagement_count"] = static_cast<int64_t>(engagement_count);
    // ---- convoys ----
    const std::vector<MilitaryShipment> &shipments = core->shipments();
    int32_t convoy_count = 0;
    for (const MilitaryShipment &s : shipments)
        if (s.qty > 0) ++convoy_count;
    PackedInt32Array c_current, c_dest, c_country, c_risk;
    c_current.resize(convoy_count);
    c_dest.resize(convoy_count);
    c_country.resize(convoy_count);
    c_risk.resize(convoy_count);
    int32_t c_lane = 0;
    for (const MilitaryShipment &s : shipments) {
        if (s.qty <= 0) continue;
        c_current[c_lane] = s.current_cell;
        c_dest[c_lane] = s.dest_kind == 0 ? s.dest : -1;
        c_country[c_lane] = s.country_slot;
        // Risk proxy: stretch of contested route already covered.
        c_risk[c_lane] = std::clamp<int32_t>(s.route_cost_q16, 0, MILITARY_Q * 4);
        ++c_lane;
    }
    Dictionary convoy_rows;
    convoy_rows["current_cell"] = c_current;
    convoy_rows["dest_cell"] = c_dest;
    convoy_rows["country_slot"] = c_country;
    convoy_rows["risk_q16"] = c_risk;
    out["convoys"] = convoy_rows;
    out["convoy_count"] = static_cast<int64_t>(convoy_count);
    // ---- controllers (sparse) ----
    const std::vector<int32_t> &controllers = core->cell_controller();
    PackedInt32Array controller_cells, controller_slots;
    for (size_t i = 0; i < controllers.size(); ++i) {
        if (controllers[i] < 0) continue;
        controller_cells.push_back(static_cast<int32_t>(i));
        controller_slots.push_back(controllers[i]);
    }
    out["controller_cells"] = controller_cells;
    out["controller_slots"] = controller_slots;
    // ---- front edges (key = cell*6 + dir) ----
    // Progress byte: 255 for a quiet front; when an active engagement sits on
    // the edge, its progress_q16 (attacker perspective) mapped to 0..254.
    const std::vector<uint32_t> &front = core->front_edges();
    const std::vector<int32_t> &neighbors = core->terrain().neighbors;
    PackedInt32Array front_edges;
    PackedByteArray front_progress;
    front_edges.resize(static_cast<int64_t>(front.size()));
    front_progress.resize(static_cast<int64_t>(front.size()));
    for (int64_t i = 0; i < front_edges.size(); ++i) {
        const uint32_t key = front[static_cast<size_t>(i)];
        front_edges[i] = static_cast<int32_t>(key);
        uint8_t progress = 255;
        const int32_t cell_x = static_cast<int32_t>(key / 6u);
        const size_t neighbor_index = static_cast<size_t>(key);
        const int32_t cell_y = neighbor_index < neighbors.size() ? neighbors[neighbor_index] : -1;
        if (cell_y >= 0 && engagement_count > 0) {
            const int32_t lo = std::min(cell_x, cell_y);
            const int32_t hi = std::max(cell_x, cell_y);
            for (const MilitaryEngagement &e : engagements) {
                if (!e.active || e.cell_a != lo || e.cell_b != hi) continue;
                const int64_t q = std::clamp<int64_t>(e.progress_q16, 0, MILITARY_Q);
                progress = static_cast<uint8_t>((q * 254) / MILITARY_Q);
                break;
            }
        }
        front_progress[i] = progress;
    }
    out["front_edges"] = front_edges;
    out["front_progress"] = front_progress;
    // ---- selection (set_military_render_selection) ----
    PackedInt32Array area_cells, path_cells;
    int64_t selected = 0;
    int32_t army_slot = -1;
    if (_military_render_selected_army != 0 &&
        core->resolve_army(static_cast<uint64_t>(_military_render_selected_army), army_slot)) {
        selected = _military_render_selected_army;
        const size_t s = static_cast<size_t>(army_slot);
        const int32_t area_id = armies.area_id[s];
        const std::vector<MilitaryArea> &areas = core->areas();
        if (area_id >= 0 && static_cast<size_t>(area_id) < areas.size() &&
            areas[static_cast<size_t>(area_id)].active) {
            const std::vector<int32_t> &cells_ref = areas[static_cast<size_t>(area_id)].cells;
            area_cells.resize(static_cast<int64_t>(cells_ref.size()));
            for (int64_t k = 0; k < area_cells.size(); ++k)
                area_cells[k] = cells_ref[static_cast<size_t>(k)];
        }
        for (int32_t k = armies.path_cursor[s]; k < armies.path_len[s]; ++k) {
            const int32_t offset = armies.path_offset[s] + k;
            if (offset < 0 || static_cast<size_t>(offset) >= core->_path_cells.size()) break;
            path_cells.push_back(core->_path_cells[static_cast<size_t>(offset)]);
        }
    }
    out["selected_army"] = selected;
    out["selected_area_cells"] = area_cells;
    out["selected_path_cells"] = path_cells;
    return out;
}

Dictionary DCWorldExt::set_military_render_selection(int64_t army) {
    if (_military_runtime == nullptr) return military_unavailable();
    if (army != 0) {
        int32_t slot = -1;
        if (!core_from(_military_runtime)->resolve_army(static_cast<uint64_t>(army), slot))
            return military_fail("military_army_unknown");
    }
    Dictionary out;
    out["ok"] = true;
    out["selected_army"] = army;
    out["changed"] = army != _military_render_selected_army;
    if (army != _military_render_selected_army) {
        _military_render_selected_army = army;
        ++_military_render_revision;  // the feed rebuilds on revision change
    }
    out["revision"] = _military_render_revision;
    return out;
}

Dictionary DCWorldExt::get_military_control_snapshot() const {
    if (_military_runtime == nullptr) return military_unavailable();
    const MilitaryCore *core = core_from(_military_runtime);
    const std::vector<int32_t> &controllers = core->cell_controller();
    PackedInt32Array cells, slots;
    for (size_t i = 0; i < controllers.size(); ++i) {
        if (controllers[i] < 0) continue;
        cells.push_back(static_cast<int32_t>(i));
        slots.push_back(controllers[i]);
    }
    Dictionary out;
    out["ok"] = true;
    out["revision"] = static_cast<int64_t>(core->control_revision());
    out["cells"] = cells;
    out["controller_slots"] = slots;
    out["count"] = cells.size();
    return out;
}

Array DCWorldExt::poll_military_events(int64_t after_id, int64_t limit) const {
    Array out;
    if (_military_runtime == nullptr) return out;
    const std::vector<MilitaryEvent> events = core_from(_military_runtime)->events_after(
        static_cast<uint64_t>(std::max<int64_t>(0, after_id)),
        static_cast<size_t>(std::clamp<int64_t>(limit, 1, MILITARY_EVENT_RING_CAPACITY)));
    for (const MilitaryEvent &event : events) {
        Dictionary row;
        row["id"] = static_cast<int64_t>(event.id);
        row["day"] = event.day;
        row["type"] = static_cast<int64_t>(event.type);
        row["payload_schema"] = static_cast<int64_t>(event.payload_schema);
        row["cell"] = static_cast<int64_t>(event.cell);
        row["i0"] = static_cast<int64_t>(event.i0);
        row["i1"] = static_cast<int64_t>(event.i1);
        row["i2"] = static_cast<int64_t>(event.i2);
        row["i3"] = static_cast<int64_t>(event.i3);
        row["value"] = event.value;
        out.push_back(row);
    }
    return out;
}

Dictionary DCWorldExt::preview_military_path(int64_t army, int64_t cell) {
    if (_military_runtime == nullptr) return military_unavailable();
    if (cell < 0) return military_fail("military_cell_out_of_range");
    std::vector<int32_t> cells;
    int32_t days = 0;
    if (!core_from(_military_runtime)->preview_path(static_cast<uint64_t>(army),
            static_cast<int32_t>(cell), cells, days))
        return military_fail("military_path_unreachable");
    PackedInt32Array out_cells;
    out_cells.resize(static_cast<int64_t>(cells.size()));
    for (int64_t i = 0; i < out_cells.size(); ++i)
        out_cells[i] = cells[static_cast<size_t>(i)];
    Dictionary out;
    out["ok"] = true;
    out["cells"] = out_cells;
    out["days"] = static_cast<int64_t>(days);
    return out;
}

Dictionary DCWorldExt::evaluate_military_peace(int64_t war_id, int64_t proposer,
                                               const Array &terms) const {
    if (_military_runtime == nullptr) return military_unavailable();
    std::vector<int32_t> ints;
    std::vector<int64_t> longs;
    std::string error;
    if (!encode_peace_terms(terms, ints, longs, error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    const MilitaryPeaceEvaluation evaluation = core_from(_military_runtime)->evaluate_peace(
        static_cast<int32_t>(war_id), static_cast<uint64_t>(proposer), ints, longs);
    Dictionary out;
    out["ok"] = evaluation.valid;
    out["reason"] = String(evaluation.reason.c_str());
    out["price"] = static_cast<double>(evaluation.price_q16) / static_cast<double>(MILITARY_Q);
    out["price_q16"] = static_cast<int64_t>(evaluation.price_q16);
    out["willing"] = static_cast<double>(evaluation.willing_q16) / static_cast<double>(MILITARY_Q);
    out["willing_q16"] = static_cast<int64_t>(evaluation.willing_q16);
    out["gap_q16"] = static_cast<int64_t>(evaluation.gap_q16);
    static const char *const bands[3] = {"low", "mid", "high"};
    const int32_t band = std::clamp<int32_t>(evaluation.acceptance_band, 0, 2);
    out["band"] = String(bands[band]);
    return out;
}

Dictionary DCWorldExt::get_military_catalog_view() const {
    if (_military_runtime == nullptr) return military_unavailable();
    const MilitaryCatalog &catalog = core_from(_military_runtime)->catalog();
    Dictionary out;
    out["ok"] = true;
    out["catalog_hash"] = static_cast<int64_t>(catalog.hash);
    out["militia_unit"] = static_cast<int64_t>(catalog.militia_unit);
    out["economy_good_count"] = static_cast<int64_t>(catalog.economy_good_count);
    out["unlock_count"] = static_cast<int64_t>(catalog.unlock_count);
    out["ration_need_per_head_q16"] = static_cast<int64_t>(catalog.ration_need_per_head_q16);
    Array units;
    for (size_t i = 0; i < catalog.units.size(); ++i) {
        const MilitaryUnitType &unit = catalog.units[i];
        Dictionary row;
        row["index"] = static_cast<int64_t>(i);
        row["id"] = String(unit.id.c_str());
        row["class"] = static_cast<int64_t>(unit.unit_class);
        row["militia"] = unit.is_default_militia != 0;
        row["era"] = static_cast<int64_t>(unit.era_index);
        row["unlock_bit"] = static_cast<int64_t>(unit.unlock_bit);
        row["attack_q16"] = static_cast<int64_t>(unit.attack_q16);
        row["defense_q16"] = static_cast<int64_t>(unit.defense_q16);
        row["speed_q16"] = static_cast<int64_t>(unit.speed_q16);
        row["fortification_ignore_q16"] = static_cast<int64_t>(unit.fortification_ignore_q16);
        row["training_days"] = static_cast<int64_t>(unit.training_days);
        Array equipment;
        for (int32_t s = 0; s < unit.slot_count && s < MILITARY_MAX_EQUIP_SLOTS; ++s) {
            Dictionary slot;
            slot["category"] = static_cast<int64_t>(unit.slot_category[static_cast<size_t>(s)]);
            slot["min_quality"] = static_cast<int64_t>(unit.slot_min_quality[static_cast<size_t>(s)]);
            slot["qty_per_100"] = unit.slot_qty_per_100[static_cast<size_t>(s)];
            slot["weight_q16"] = static_cast<int64_t>(
                unit.slot_power_weight_q16[static_cast<size_t>(s)]);
            equipment.push_back(slot);
        }
        row["equipment"] = equipment;
        PackedInt64Array idle, combat;
        idle.resize(MILITARY_SUPPLY_CLASSES);
        combat.resize(MILITARY_SUPPLY_CLASSES);
        for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
            idle[cls] = unit.idle_per_100_day[static_cast<size_t>(cls)];
            combat[cls] = unit.combat_per_100_day[static_cast<size_t>(cls)];
        }
        row["supply_idle_per_100"] = idle;
        row["supply_combat_per_100"] = combat;
        units.push_back(row);
    }
    out["units"] = units;
    Array categories;
    for (size_t i = 0; i < catalog.categories.size(); ++i) {
        const MilitaryEquipCategory &category = catalog.categories[i];
        Dictionary row;
        row["index"] = static_cast<int64_t>(i);
        row["id"] = String(category.id.c_str());
        PackedInt32Array goods, qualities;
        goods.resize(static_cast<int64_t>(category.good_ids.size()));
        qualities.resize(static_cast<int64_t>(category.good_ids.size()));
        for (int64_t k = 0; k < goods.size(); ++k) {
            goods[k] = category.good_ids[static_cast<size_t>(k)];
            qualities[k] = static_cast<int64_t>(category.good_quality[static_cast<size_t>(k)]);
        }
        row["goods"] = goods;
        row["qualities"] = qualities;
        categories.push_back(row);
    }
    out["categories"] = categories;
    Array buildings;
    for (size_t i = 0; i < catalog.state_buildings.size(); ++i) {
        const MilitaryStateBuilding &building = catalog.state_buildings[i];
        Dictionary row;
        row["index"] = static_cast<int64_t>(i);
        row["id"] = String(building.id.c_str());
        row["economy_building_id"] = static_cast<int64_t>(building.economy_building_id);
        row["role"] = static_cast<int64_t>(building.role);
        row["tier"] = static_cast<int64_t>(building.tier);
        row["unlock_bit"] = static_cast<int64_t>(building.unlock_bit);
        row["capacity"] = static_cast<int64_t>(building.capacity);
        row["fort_bonus_q16"] = static_cast<int64_t>(building.fort_bonus_q16);
        row["training_speed_q16"] = static_cast<int64_t>(building.training_speed_q16);
        row["upkeep_per_day"] = building.upkeep_per_day;
        row["build_days"] = static_cast<int64_t>(building.build_days);
        buildings.push_back(row);
    }
    out["state_buildings"] = buildings;
    Array supply_goods, supply_yields;
    for (int32_t cls = 0; cls < MILITARY_SUPPLY_CLASSES; ++cls) {
        const std::vector<int32_t> &goods = catalog.supply_goods[static_cast<size_t>(cls)];
        const std::vector<int32_t> &yields = catalog.supply_yield_q16[static_cast<size_t>(cls)];
        PackedInt32Array goods_row, yield_row;
        goods_row.resize(static_cast<int64_t>(goods.size()));
        yield_row.resize(static_cast<int64_t>(yields.size()));
        for (int64_t k = 0; k < goods_row.size(); ++k)
            goods_row[k] = goods[static_cast<size_t>(k)];
        for (int64_t k = 0; k < yield_row.size(); ++k)
            yield_row[k] = yields[static_cast<size_t>(k)];
        supply_goods.push_back(goods_row);
        supply_yields.push_back(yield_row);
    }
    out["supply_goods"] = supply_goods;
    out["supply_yield_q16"] = supply_yields;
    return out;
}

// ===========================================================================
// persistence
// ===========================================================================

PackedByteArray DCWorldExt::encode_military_state() const {
    PackedByteArray bytes;
    if (_military_runtime == nullptr) return bytes;
    // PKMI already carries magic/version/catalog hash; the bridge adds only the
    // rows the core cannot reconstruct (pending receipts + sequence cursor).
    const std::vector<uint8_t> core_bytes = core_from(_military_runtime)->encode();
    std::vector<uint8_t> out;
    out.reserve(core_bytes.size() + 8 * (_military_pending_intents.size() * 9 + 4) + 64);
    const auto append_u32 = [](std::vector<uint8_t> &buffer, uint32_t value) {
        for (int i = 0; i < 4; ++i) buffer.push_back(static_cast<uint8_t>(value >> (i * 8)));
    };
    const auto append_u64 = [](std::vector<uint8_t> &buffer, uint64_t value) {
        for (int i = 0; i < 8; ++i) buffer.push_back(static_cast<uint8_t>(value >> (i * 8)));
    };
    append_u32(out, 0x4d494c42u);  // "MILB" bridge wrapper
    append_u32(out, 2u);           // v2: pending rows carry economy match identity
    append_u32(out, static_cast<uint32_t>(core_bytes.size()));
    out.insert(out.end(), core_bytes.begin(), core_bytes.end());
    append_u64(out, static_cast<uint64_t>(std::max<int64_t>(0, _military_sequence)));
    append_u64(out, static_cast<uint64_t>(std::max<int64_t>(-1, _military_last_step_day)));
    if (_military_receipts) {
        append_u64(out, static_cast<uint64_t>(
            std::max<int64_t>(0, _military_receipts->after_request_id)));
    } else {
        append_u64(out, 0);
    }
    append_u32(out, static_cast<uint32_t>(_military_pending_intents.size()));
    for (const MilitaryPendingIntent &row : _military_pending_intents) {
        append_u32(out, row.kind);
        append_u32(out, static_cast<uint32_t>(row.authority));
        append_u32(out, static_cast<uint32_t>(row.cell));
        append_u32(out, static_cast<uint32_t>(row.good));
        append_u64(out, row.source_id);
        append_u64(out, row.country_handle);
        append_u64(out, static_cast<uint64_t>(row.count));
        append_u64(out, static_cast<uint64_t>(row.amount));
        append_u64(out, static_cast<uint64_t>(row.sequence));
        append_u64(out, static_cast<uint64_t>(row.request_id));
        append_u64(out, static_cast<uint64_t>(row.effective_day));
        append_u32(out, row.receipt_pending);
        append_u64(out, static_cast<uint64_t>(row.target_handle));
        append_u32(out, static_cast<uint32_t>(row.target_signature));
        append_u32(out, static_cast<uint32_t>(row.opcode));
    }
    bytes.resize(static_cast<int64_t>(out.size()));
    if (!out.empty()) std::memcpy(bytes.ptrw(), out.data(), out.size());
    return bytes;
}

Dictionary DCWorldExt::restore_military_state(const PackedByteArray &bytes) {
    if (_military_runtime == nullptr) return military_unavailable();
    if (bytes.is_empty()) return military_fail("pkmi_empty");
    const uint8_t *data = bytes.ptr();
    const size_t size = static_cast<size_t>(bytes.size());
    size_t at = 0;
    const auto read_u32 = [&](uint32_t &value) {
        if (size - at < 4) return false;
        value = 0;
        for (int i = 0; i < 4; ++i) value |= static_cast<uint32_t>(data[at++]) << (i * 8);
        return true;
    };
    const auto read_u64 = [&](uint64_t &value) {
        if (size - at < 8) return false;
        value = 0;
        for (int i = 0; i < 8; ++i) value |= static_cast<uint64_t>(data[at++]) << (i * 8);
        return true;
    };
    uint32_t magic = 0, version = 0, core_size = 0;
    if (!read_u32(magic) || magic != 0x4d494c42u) return military_fail("pkmi_wrapper_magic_invalid");
    if (!read_u32(version) || (version != 1u && version != 2u))
        return military_fail("pkmi_wrapper_version_unsupported");
    if (!read_u32(core_size) || size - at < core_size) return military_fail("pkmi_wrapper_truncated");
    std::string error;
    if (!core_from(_military_runtime)->restore(data + at, core_size, error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    at += core_size;
    uint64_t sequence = 0, last_day = 0, receipt_cursor = 0;
    if (!read_u64(sequence) || !read_u64(last_day) || !read_u64(receipt_cursor))
        return military_fail("pkmi_wrapper_truncated");
    _military_sequence = static_cast<int64_t>(std::min<uint64_t>(sequence,
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())));
    _military_last_step_day = static_cast<int64_t>(last_day);
    if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
    _military_receipts->after_request_id = static_cast<int64_t>(receipt_cursor);
    uint32_t pending_count = 0;
    if (!read_u32(pending_count) || pending_count > (1u << 20))
        return military_fail("pkmi_pending_invalid");
    _military_pending_intents.clear();
    _military_pending_intents.reserve(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        uint32_t kind = 0, authority = 0, cell = 0, good = 0, receipt_pending = 0;
        uint64_t source_id = 0, country = 0, count = 0, amount = 0, seq = 0, request = 0, day = 0;
        if (!read_u32(kind) || !read_u32(authority) || !read_u32(cell) || !read_u32(good) ||
            !read_u64(source_id) || !read_u64(country) || !read_u64(count) ||
            !read_u64(amount) || !read_u64(seq) || !read_u64(request) || !read_u64(day) ||
            !read_u32(receipt_pending))
            return military_fail("pkmi_wrapper_truncated");
        uint64_t target_handle = 0;
        uint32_t target_signature = 0xffffffffu, opcode = 0;
        if (version >= 2u &&
            (!read_u64(target_handle) || !read_u32(target_signature) || !read_u32(opcode)))
            return military_fail("pkmi_wrapper_truncated");
        MilitaryPendingIntent row;
        row.target_handle = static_cast<int64_t>(target_handle);
        row.target_signature = static_cast<int32_t>(target_signature);
        row.opcode = static_cast<int32_t>(opcode);
        row.kind = static_cast<uint16_t>(kind);
        row.authority = static_cast<uint8_t>(authority);
        row.cell = static_cast<int32_t>(cell);
        row.good = static_cast<int32_t>(good);
        row.source_id = source_id;
        row.country_handle = country;
        row.count = static_cast<int64_t>(count);
        row.amount = static_cast<int64_t>(amount);
        row.sequence = static_cast<int64_t>(seq);
        row.request_id = static_cast<int64_t>(request);
        row.effective_day = static_cast<int64_t>(day);
        row.receipt_pending = static_cast<uint8_t>(receipt_pending);
        _military_pending_intents.push_back(row);
    }
    // Economy settlement fold restarts over the retained trace window; rows
    // are matched by their (saved, monotone) command sequence. v1 rows carry
    // no opcode and resolve through the receipt timeout.
    _military_economy_event_cursor = -1;
    _military_economy_seen_day = -1;
    _military_forced_run_day = -1;
    _military_render_selected_army = 0;
    ++_military_render_revision;
    const MilitaryReport &report = core_from(_military_runtime)->report();
    Dictionary out;
    out["ok"] = true;
    out["reason"] = String();
    out["day"] = report.day;
    out["last_step_day"] = _military_last_step_day;
    out["pending_intents"] = static_cast<int64_t>(_military_pending_intents.size());
    out["sequence_cursor"] = _military_sequence;
    out["state_hash"] = static_cast<int64_t>(
        core_from(_military_runtime)->state_hash() & 0x7fffffffffffffffll);
    return out;
}

// ===========================================================================
// self test / bench / AI arming
// ===========================================================================

Dictionary DCWorldExt::runtime_military_self_test() {
    Dictionary out;
    std::string report;
    const bool ok = MilitaryCore::self_test(report);
    out["ok"] = ok;
    out["reason"] = String(report.c_str());
    // Bridge-level checks that do not need a world: catalog scaling, op table
    // coverage and term encoding are pure conversions.
    if (ok) {
        MilitaryCatalog probe;
        Dictionary catalog;
        Array units;
        Dictionary unit;
        unit["id"] = String("a_militia");
        unit["class"] = static_cast<int64_t>(0);
        unit["militia"] = true;
        unit["attack"] = 0.5;
        unit["defense"] = 0.6;
        unit["speed"] = 1.0;
        unit["training_days"] = static_cast<int64_t>(0);
        PackedFloat32Array idle;
        idle.resize(MILITARY_SUPPLY_CLASSES);
        idle[0] = 0.25f;
        unit["supply_idle"] = idle;
        units.push_back(unit);
        catalog["units"] = units;
        std::string error;
        if (!parse_catalog(catalog, probe, error)) {
            out["ok"] = false;
            out["reason"] = String(error.c_str());
            return out;
        }
        const MilitaryUnitType &parsed = probe.units.front();
        if (probe.militia_unit != 0 || parsed.attack_q16 != MILITARY_Q / 2 ||
            parsed.training_days != 1 || parsed.idle_per_100_day[0] != MILITARY_GOODS / 4) {
            out["ok"] = false;
            out["reason"] = String("military_catalog_scaling_invalid");
            return out;
        }
        if (op_from_name(String("army.area_control")) != MCMD_ARMY_AREA_CONTROL ||
            op_from_name(String("nope")) != MCMD_NONE) {
            out["ok"] = false;
            out["reason"] = String("military_op_table_invalid");
            return out;
        }
        Array terms;
        Dictionary term;
        term["kind"] = String("lump_sum");
        term["amount"] = 12.5;
        terms.push_back(term);
        std::vector<int32_t> ints;
        std::vector<int64_t> longs;
        if (!encode_peace_terms(terms, ints, longs, error) || ints.size() != 3 ||
            longs.size() != 1 || longs[0] != money_from_units(12.5)) {
            out["ok"] = false;
            out["reason"] = String("military_peace_term_encoding_invalid");
            return out;
        }
    }
    out["bridge"] = out["ok"];
    return out;
}

Dictionary DCWorldExt::run_military_bench(const Dictionary &cfg) {
    int32_t cells = std::max(1, dict_i32(cfg, "cells", 100000));
    int32_t armies = std::clamp(dict_i32(cfg, "armies", 2048), 1, MILITARY_MAX_ARMIES);
    int32_t engagements = std::max(1, dict_i32(cfg, "engagements", 4096));
    int32_t days = std::clamp(dict_i32(cfg, "days", 30), 1, 1000);
    double avg_ms = 0.0, p95_ms = 0.0, max_ms = 0.0;
    std::string report;
    const bool ok = MilitaryCore::bench(cells, armies, engagements, days, avg_ms, p95_ms,
                                        max_ms, report);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(report.c_str());
    out["cells"] = static_cast<int64_t>(cells);
    out["armies"] = static_cast<int64_t>(armies);
    out["engagements"] = static_cast<int64_t>(engagements);
    out["days"] = static_cast<int64_t>(days);
    out["avg_ms"] = avg_ms;
    out["p95_ms"] = p95_ms;
    out["max_ms"] = max_ms;
    return out;
}

Dictionary DCWorldExt::set_military_ai_player_handles(const PackedInt64Array &handles) {
    if (_military_runtime == nullptr) return military_unavailable();
    MilitaryCore *core = core_from(_military_runtime);
    int32_t arming_errors = 0;
    // Make sure every active country owns a slot before slot -> handle lookups.
    ensure_military_country_slots();
    // Every country slot the digest knows becomes AI unless it is a player.
    int32_t country_count = 0;
    if (_country_runtime != nullptr) {
        NativeCountryRuntime::EconomySnapshot snapshot;
        if (static_cast<NativeCountryRuntime *>(_country_runtime)
                ->copy_economy_snapshot(snapshot))
            country_count = static_cast<int32_t>(snapshot.country_handles.size());
    }
    (void)arming_errors;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const uint64_t handle = core->country_handle_for_slot(slot);
        bool player = false;
        for (int64_t i = 0; i < handles.size(); ++i) {
            if (static_cast<uint64_t>(handles[i]) == handle) {
                player = true;
                break;
            }
        }
        // AI slot table is sized by the digest at configure time; use the
        // core's own arming entry point so MilitaryCore stays authoritative.
        core->set_ai_country(slot, !player);
    }
    Dictionary out;
    out["ok"] = true;
    out["path"] = "handle_set";
    out["applied"] = static_cast<int64_t>(country_count);
    return out;
}

Dictionary DCWorldExt::set_military_ai_country(int64_t slot, int64_t ai) {
    if (_military_runtime == nullptr) return military_unavailable();
    if (slot < 0 || slot >= MILITARY_MAX_ARMIES) return military_fail("military_slot_invalid");
    core_from(_military_runtime)->set_ai_country(static_cast<int32_t>(slot), ai != 0);
    Dictionary out;
    out["ok"] = true;
    out["slot"] = slot;
    out["ai"] = ai != 0;
    return out;
}

} // namespace pk
