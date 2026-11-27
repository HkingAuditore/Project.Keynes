Array DCWorldExt::poll_military_events(int64_t after_id, int64_t limit) const {
    Array out;
    if (!_military) return out;
    const std::vector<MilitaryEvent> events = read_military_core()->events_after(
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
    if (!_military) return military_unavailable();
    if (cell < 0) return military_fail("military_cell_out_of_range");
    std::vector<int32_t> cells;
    int32_t days = 0;
    if (!read_military_core()->preview_path(static_cast<uint64_t>(army),
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
    if (!_military) return military_unavailable();
    std::vector<int32_t> ints;
    std::vector<int64_t> longs;
    std::string error;
    if (!encode_peace_terms(terms, ints, longs, error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    const MilitaryPeaceEvaluation evaluation = read_military_core()->evaluate_peace(
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
    if (!_military) return military_unavailable();
    const auto frame = read_military_core();
    const MilitaryCatalog &catalog = frame->catalog();
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
            slot["core"] = unit.slot_core[static_cast<size_t>(s)] != 0;
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
