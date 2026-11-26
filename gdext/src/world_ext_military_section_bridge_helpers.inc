namespace {

// --------------------------------------------------------------- scales

constexpr int32_t MILITARY_Q = MILITARY_Q16;
constexpr int64_t MILITARY_MONEY = MILITARY_MONEY_SCALE;
constexpr int64_t MILITARY_GOODS = MILITARY_GOODS_SCALE;
constexpr int32_t MILITARY_SUPPLY_CLASSES = MILITARY_MAX_SUPPLY_CLASSES;
constexpr uint32_t kMilitaryBridgeMagic = 0x4d494c42u;  // "MILB"
constexpr uint32_t kMilitaryBridgeWrapperVersion = 4u;

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

Dictionary military_unavailable() { return military_fail("military_unavailable"); }

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
    {"army.explore", MCMD_ARMY_EXPLORE},
    {"war.declare", MCMD_WAR_DECLARE},
    {"war.declare_forced", MCMD_WAR_DECLARE_FORCED},
    {"garrison.transfer_cell", MCMD_GARRISON_TRANSFER_CELL},
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
            unit.slot_core[lane] = dict_i32(slot, "core", 0) != 0 ? 1 : 0;
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
    // Physical repair recipe (design §2): rate_q32 is q32 of one milli-good per
    // 100 heads per day. Militia authors an empty recipe, which is the explicit
    // "zero maintenance" rule, not a missing table.
    {
        const std::vector<int32_t> repair_goods = dict_i32_array(row, "repair_goods");
        const std::vector<int64_t> repair_rates = dict_i64_array(row, "repair_rate_q32");
        const size_t repair_count = std::min<size_t>(
            {repair_goods.size(), repair_rates.size(), (size_t)MILITARY_MAX_REPAIR_MATERIALS});
        unit.repair_materials.clear();
        unit.repair_materials.reserve(repair_count);
        for (size_t m = 0; m < repair_count; ++m) {
            MilitaryRepairMaterial mat;
            mat.good = repair_goods[m];
            mat.rate_q32 = std::max<int64_t>(0, repair_rates[m]);
            if (mat.good < 0 || mat.rate_q32 <= 0) continue;
            unit.repair_materials.push_back(mat);
        }
    }
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
            // Physical repair recipe (design §2): parallel (good, rate_q32)
            // columns, at most 4 components. `rate_q32` is q32 of ONE
            // milli-good per day per building, so the runtime only accumulates
            // and shifts - it never re-derives consumption from cash or from the
            // construction bill.
            const std::vector<int32_t> repair_goods = dict_i32_array(row, "repair_goods");
            const std::vector<int64_t> repair_rates = dict_i64_array(row, "repair_rate_q32");
            const size_t repair_count = std::min<size_t>(
                {repair_goods.size(), repair_rates.size(), (size_t)MILITARY_MAX_REPAIR_MATERIALS});
            building.repair_materials.clear();
            building.repair_materials.reserve(repair_count);
            for (size_t m = 0; m < repair_count; ++m) {
                MilitaryRepairMaterial mat;
                mat.good = repair_goods[m];
                mat.rate_q32 = std::max<int64_t>(0, repair_rates[m]);
                if (mat.good < 0 || mat.rate_q32 <= 0) continue;
                building.repair_materials.push_back(mat);
            }
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
    out.water_lake_bit = dict_i32(catalog, "water_lake_bit", -1);
    out.water_shallow_bit = dict_i32(catalog, "water_shallow_bit", -1);
    out.water_far_bit = dict_i32(catalog, "water_far_bit", -1);
    out.water_deep_bit = dict_i32(catalog, "water_deep_bit", -1);
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
    command.effective_day = dict_i64(row, "effective_day", 0);
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

} // namespace
