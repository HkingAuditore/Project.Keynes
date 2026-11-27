#include "economy_runtime_colonization_kit_includes.inc"

namespace pk {

bool NativeEconomyRuntime::cell_has_submitted_or_pending_buildings(
        int32_t cell) const {
    if (cell < 0 || cell >= _cell_count.get()) return false;
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            if (buildings_store().group_units[group] > 0) return true;
        }
        if (_pending_building_topology_rebuild) {
            const int32_t sorted_end = _building_cell_offsets[_cell_count.get()];
            for (int32_t group = sorted_end;
                 group < static_cast<int32_t>(building_count()); ++group) {
                if (buildings_store().cell[group] == cell &&
                    buildings_store().group_units[group] > 0)
                    return true;
            }
        }
    } else {
        for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
            const auto group = building_at(pk_row);
            if (group.cell == cell && group.count > 0) return true;
        }
    }
    if (_pending_construction_cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t cursor = _pending_construction_cell_offsets[cell];
             cursor < _pending_construction_cell_offsets[cell + 1]; ++cursor) {
            const int32_t pending_index =
                _pending_construction_cell_indices[cursor];
            if (pending_index >= 0 && pending_index < static_cast<int32_t>(
                    pending_construction_count()) &&
                buildings_store().pending_count[
                    static_cast<size_t>(pending_index)] > 0)
                return true;
        }
    } else {
        for (const auto pending : pending_construction()) {
            if (pending.cell == cell && pending.count > 0) return true;
        }
    }
    return false;
}

bool NativeEconomyRuntime::colonization_kit_type_eligible(
        int32_t source_cell, int32_t target_cell, int32_t type_id,
        bool frozen) const {
    if (type_id < 0 || type_id >= static_cast<int32_t>(_building_types.size()))
        return false;
    const BuildingType &type = _building_types[type_id];
    if (type.employee_count > 0 || type.economic_sector == 4) return false;
    for (int32_t output = type.output_begin;
         output < type.output_begin + type.output_count; ++output) {
        const int32_t good = _building_outputs[output].good_id;
        if (good >= 0 && good < static_cast<int32_t>(_good_ids.size()) &&
            (_good_ids[static_cast<size_t>(good)] == "gold" ||
             _good_ids[static_cast<size_t>(good)] == "silver"))
            return false;
    }
    return building_available(source_cell, type_id, frozen) &&
        evaluate_building_conditions(type_id, target_cell);
}

int64_t NativeEconomyRuntime::colonization_kit_output_per_building(
        int32_t target_cell, int32_t type_id, int32_t good_id) const {
    if (type_id < 0 || type_id >= static_cast<int32_t>(_building_types.size()))
        return 0;
    const BuildingType &type = _building_types[type_id];
    int64_t sat = 0;
    const int64_t climate = production_climate_capacity_q16(
        type, target_cell, nullptr, nullptr, sat);
    int64_t quantity = 0;
    for (int32_t output = type.output_begin;
         output < type.output_begin + type.output_count; ++output) {
        const GoodAmount &item = _building_outputs[output];
        if (good_id >= 0 && item.good_id != good_id) continue;
        quantity = saturating_add(quantity, item.quantity, sat);
    }
    return mul_div_sat(quantity, climate, Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::colonization_kit_input_per_building(
        int32_t type_id, int32_t good_id) const {
    if (type_id < 0 || type_id >= static_cast<int32_t>(_building_types.size()))
        return 0;
    const BuildingType &type = _building_types[type_id];
    int64_t sat = 0;
    int64_t quantity = 0;
    for (int32_t input = type.input_begin;
         input < type.input_begin + type.input_count; ++input) {
        const ProductionInput &item = _building_inputs[input];
        if (good_id >= 0 && item.preferred_good_id != good_id) continue;
        quantity = saturating_add(quantity, item.quantity, sat);
    }
    return quantity;
}

int64_t NativeEconomyRuntime::colonization_kit_daily_food_required(
        int32_t target_cell, int64_t population) const {
    if (population <= 0) return 0;
    const EnvironmentSample sample = environment_sample_for_cell(target_cell);
    int64_t sat = 0;
    int64_t required = 0;
    for (const int32_t stable_id : _survival_food_need_stable_ids) {
        if (stable_id < 0 || stable_id >= static_cast<int32_t>(
                _survival_required_need_indices.size())) continue;
        const int32_t need_index = _survival_required_need_indices[stable_id];
        if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size()))
            continue;
        const Need &need = _needs[need_index];
        int64_t units = saturating_mul(population, need.base_qty_per_person, sat);
        units = mul_div_sat(units,
            sample_environment_curve(need.quantity_env_curve, sample),
            Q16_ONE, sat);
        required = saturating_add(required, std::max<int64_t>(0, units), sat);
    }
    return required;
}

uint64_t NativeEconomyRuntime::hash_colonization_kit_plan(
        const ColonizationKitPlan &kit) const {
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, kit.place_buildings);
    hash = trace_hash_mix(hash, kit.kit_partial);
    hash = trace_hash_mix(hash, static_cast<uint64_t>(kit.supported_population));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(kit.food_coverage_q16));
    for (const FamilyExpeditionKitBuilding &building : kit.buildings) {
        hash = trace_hash_mix(hash, static_cast<uint32_t>(building.type_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(building.count));
    }
    for (const FamilyExpeditionCargoLine &line : kit.cargo) {
        hash = trace_hash_mix(hash, static_cast<uint32_t>(line.good_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(line.quantity));
        hash = trace_hash_mix(hash, line.flags);
    }
    for (const int32_t good : kit.missing_good_ids)
        hash = trace_hash_mix(hash, static_cast<uint32_t>(good));
    return hash == 0 ? 1 : hash;
}

bool NativeEconomyRuntime::plan_colonization_kit(
        int32_t source_cell, int32_t target_cell, int64_t population,
        int32_t travel_days, bool frozen, ColonizationKitPlan &kit,
        bool ignore_existing, const ColonizationReserveContext *reserve) const {
    kit = ColonizationKitPlan{};
    kit.supported_population = std::max<int64_t>(0, population);
    if (source_cell < 0 || source_cell >= _cell_count.get() ||
        target_cell < 0 || target_cell >= _cell_count.get() || population <= 0)
        return false;
    const bool has_existing = cell_has_submitted_or_pending_buildings(target_cell);
    kit.place_buildings = (has_existing && !ignore_existing) ? 0 : 1;
    kit.dest_identity = 1469598103934665603ULL;
    kit.dest_identity = trace_hash_mix(kit.dest_identity, kit.place_buildings);
    // Mix the target cell's committed resource picture, not the per-epoch
    // lane cache stamp. `_resource_current_generation` increments at every
    // epoch begin and would invalidate every live quote after one cycle.
    if (!_resource_ids.empty() &&
        resource_stock_lanes().size() >= _resource_ids.size() *
            static_cast<size_t>(_cell_count.get())) {
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            const size_t lane = resource * static_cast<size_t>(_cell_count.get()) +
                static_cast<size_t>(target_cell);
            kit.dest_identity = trace_hash_mix(kit.dest_identity,
                static_cast<uint64_t>(resource_stock_lanes()[lane]));
        }
    }
    if (_country_runtime != nullptr) {
        CountryReadView::Snapshot snapshot;
        if (country_reads().copy_economy_snapshot(snapshot))
            kit.dest_identity = trace_hash_mix(kit.dest_identity,
                snapshot.generation);
    }
    auto preferred_id_for_role = [&](uint32_t role) -> const char * {
        if (role == BUILDING_KIT_ROLE_SURVIVAL_FOOD) return "gathering_ground";
        if (role == BUILDING_KIT_ROLE_TRADE) return "early_merchant_post";
        if (role == BUILDING_KIT_ROLE_CONSTRUCTION)
            return "deadwood_gathering_camp";
        if (role == BUILDING_KIT_ROLE_CLOTHING_INPUT) return "bast_fiber_camp";
        if (role == BUILDING_KIT_ROLE_CLOTHING) return "bast_wrap_shelter";
        return "";
    };
    auto pick_role = [&](uint32_t role) -> int32_t {
        const std::string preferred = preferred_id_for_role(role);
        int32_t chosen = -1;
        int32_t fallback = -1;
        for (int32_t type_id = 0;
             type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
            if ((_building_types[type_id].kit_role_mask & role) == 0) continue;
            if (!colonization_kit_type_eligible(source_cell, target_cell,
                    type_id, frozen)) continue;
            if (!preferred.empty() &&
                type_id < static_cast<int32_t>(_building_type_ids.size()) &&
                _building_type_ids[static_cast<size_t>(type_id)] == preferred) {
                chosen = type_id;
                break;
            }
            if (fallback < 0) fallback = type_id;
        }
        if (chosen < 0) chosen = fallback;
        if (chosen >= 0) {
            kit.dest_identity = trace_hash_mix(kit.dest_identity,
                static_cast<uint32_t>(chosen));
            kit.dest_identity = trace_hash_mix(kit.dest_identity, role);
        }
        return chosen;
    };
    const int32_t food_type = pick_role(BUILDING_KIT_ROLE_SURVIVAL_FOOD);
    const int32_t clothing_input_type =
        pick_role(BUILDING_KIT_ROLE_CLOTHING_INPUT);
    const int32_t clothing_type = pick_role(BUILDING_KIT_ROLE_CLOTHING);
    const int32_t construction_type =
        pick_role(BUILDING_KIT_ROLE_CONSTRUCTION);
    const int32_t trade_type = pick_role(BUILDING_KIT_ROLE_TRADE);
    kit.dest_identity = kit.dest_identity == 0 ? 1 : kit.dest_identity;
    if (!kit.place_buildings ||
        population < COLONIZATION_KIT_MIN_OWNER_SLOTS) {
        if (population < COLONIZATION_KIT_MIN_OWNER_SLOTS)
            kit.kit_partial = 1;
        fill_colonization_kit_buffer(source_cell, target_cell, population,
            travel_days, kit, reserve);
        sort_colonization_kit_cargo(kit);
        kit.kit_hash = hash_colonization_kit_plan(kit);
        return true;
    }

    struct Planned {
        int32_t type_id = -1;
        int64_t count = 0;
        int32_t drop_rank = 0;
        int32_t owner_slots = 0;
    };
    std::vector<Planned> planned;
    int64_t used_slots = 0;
    int64_t sat = 0;
    auto owner_slots_of = [&](int32_t type_id) -> int64_t {
        if (type_id < 0) return 0;
        return std::max<int64_t>(1,
            _building_types[type_id].owner_slots_per_building);
    };
    auto try_add = [&](int32_t type_id, int64_t count, int32_t drop_rank)
            -> bool {
        if (type_id < 0 || count <= 0) return false;
        const int64_t slots = saturating_mul(count, owner_slots_of(type_id),
            sat);
        if (used_slots + slots > population) return false;
        if (!family_free_building_resources_legal(target_cell, type_id,
                count)) return false;
        for (Planned &row : planned) {
            if (row.type_id == type_id) {
                row.count += count;
                row.drop_rank = std::max(row.drop_rank, drop_rank);
                used_slots += slots;
                return true;
            }
        }
        planned.push_back({type_id, count, drop_rank,
            static_cast<int32_t>(owner_slots_of(type_id))});
        used_slots += slots;
        return true;
    };

    const int64_t food_required =
        colonization_kit_daily_food_required(target_cell, population);
    const int64_t food_output = food_type >= 0
        ? colonization_kit_output_per_building(target_cell, food_type, -1) : 0;
    int64_t food_count = 0;
    int64_t food_produced = 0;
    if (food_type >= 0 && food_output > 0) {
        while (true) {
            const int64_t coverage = food_required <= 0 ? Q16_ONE
                : mul_div_sat(food_produced, Q16_ONE, food_required, sat);
            if (coverage >= COLONIZATION_KIT_FOOD_COVERAGE_Q16 && food_count > 0)
                break;
            if (!try_add(food_type, 1, food_count == 0 ? 10 : 50)) break;
            ++food_count;
            food_produced = saturating_add(food_produced, food_output, sat);
            if (food_count > population) break;
        }
    } else if (food_type >= 0) {
        try_add(food_type, 1, 10);
    }
    // The merchant post is part of the minimum greenfield opening plan. Add
    // it before optional clothing/construction chains so a three-person party
    // keeps one food producer and one trade building; the later drop ranks
    // still remove optional chains first when the party is smaller.
    if (trade_type >= 0)
        try_add(trade_type, 1, 5);
    if (clothing_input_type >= 0 && clothing_type >= 0) {
        int32_t fiber_good = -1;
        const BuildingType &input_type = _building_types[clothing_input_type];
        if (input_type.output_count > 0)
            fiber_good = _building_outputs[input_type.output_begin].good_id;
        const int64_t fiber_out = colonization_kit_output_per_building(
            target_cell, clothing_input_type, fiber_good);
        const int64_t wrap_in = colonization_kit_input_per_building(
            clothing_type, fiber_good);
        if (fiber_out > 0 && wrap_in > 0 &&
            used_slots + owner_slots_of(clothing_input_type) +
                owner_slots_of(clothing_type) <= population &&
            try_add(clothing_input_type, 1, 20)) {
            const int64_t wraps = std::max<int64_t>(1, fiber_out / wrap_in);
            int64_t added = 0;
            while (added < wraps && try_add(clothing_type, 1, 30))
                ++added;
            if (added <= 0) {
                for (auto it = planned.begin(); it != planned.end(); ++it) {
                    if (it->type_id != clothing_input_type) continue;
                    used_slots -= owner_slots_of(clothing_input_type) * it->count;
                    planned.erase(it);
                    break;
                }
            }
        }
    }
    if (construction_type >= 0)
        try_add(construction_type, 1, 40);

    auto rebuild_buildings = [&]() {
        kit.buildings.clear();
        std::sort(planned.begin(), planned.end(),
            [](const Planned &a, const Planned &b) {
                return a.type_id < b.type_id;
            });
        for (const Planned &row : planned) {
            if (row.count > 0)
                kit.buildings.push_back({row.type_id, row.count});
        }
    };
    auto reserve_lane = [&](const std::vector<int64_t> *lane,
                            int32_t good) -> int64_t {
        if (lane == nullptr || good < 0 ||
            good >= static_cast<int32_t>(lane->size())) return 0;
        return std::max<int64_t>(0, (*lane)[static_cast<size_t>(good)]);
    };
    auto spare_source_stock = [&](int32_t market, int32_t good) -> int64_t {
        const int64_t stock = std::max<int64_t>(0,
            market_store().stock[market_store().index(market, good)]);
        const int64_t held = reserve == nullptr ? 0
            : reserve_lane(reserve->reserved, good);
        return stock + held;
    };
    // Construction demand of a build plan, in raw group quantities. Progress
    // reporting compares the full intent against the subset the source can
    // actually fund today, so both sides must use the same unit.
    auto construction_units_of = [&](const std::vector<Planned> &rows)
            -> int64_t {
        int64_t sat = 0;
        int64_t total = 0;
        for (const Planned &row : rows) {
            if (row.count <= 0 || row.type_id < 0) continue;
            const BuildingType &type = _building_types[row.type_id];
            for (int32_t i = 0; i < type.construction_count; ++i) {
                const int32_t group = type.construction_begin + i;
                if (group < 0 || group >= static_cast<int32_t>(
                        _building_construction_goods.size())) continue;
                total = saturating_add(total, saturating_mul(row.count,
                    _building_construction_goods[group].quantity, sat), sat);
            }
        }
        return total;
    };
    bool structurally_unbuildable = false;
    auto materials_fit = [&](std::vector<int32_t> *missing) -> bool {
        std::vector<int64_t> stock(_good_ids.size(), 0);
        const int32_t market = market_store().cell_to_market[source_cell];
        if (market < 0 || market >= market_store().market_count.get()) return false;
        for (int32_t good = 0; good < market_store().good_count.get(); ++good)
            stock[static_cast<size_t>(good)] = spare_source_stock(market, good);
        kit.cargo.erase(std::remove_if(kit.cargo.begin(), kit.cargo.end(),
            [](const FamilyExpeditionCargoLine &line) {
                return line.flags == EXPEDITION_CARGO_CONSTRUCTION;
            }), kit.cargo.end());
        int64_t sat = 0;
        bool ok = true;
        for (const Planned &row : planned) {
            if (row.count <= 0) continue;
            ConstructionMaterialPlan plan;
            if (_building_types[row.type_id].construction_count <= 0)
                continue;
            if (!plan_construction_materials(source_cell, row.type_id,
                    row.count, Q16_ONE, plan, nullptr, &stock, true,
                    reserve != nullptr && reserve->forecast_missing) ||
                !plan.feasible) {
                ok = false;
                if (plan.failed_group >= 0) {
                    const int32_t group =
                        _building_types[row.type_id].construction_begin +
                        plan.failed_group;
                    if (group >= 0 && group < static_cast<int32_t>(
                            _building_construction_goods.size()) &&
                        group + 1 < static_cast<int32_t>(
                            _building_construction_candidate_offsets.size())) {
                        const int32_t begin =
                            _building_construction_candidate_offsets[group];
                        const int32_t end =
                            _building_construction_candidate_offsets[group + 1];
                        // The reachability gate must match the one
                        // plan_construction_materials itself uses, otherwise a
                        // group can fail with an empty explanation.
                        bool reachable = false;
                        for (int32_t candidate = begin; candidate < end;
                             ++candidate) {
                            if (candidate >= 0 && candidate < static_cast<int32_t>(
                                    _building_construction_candidates.size())) {
                                const int32_t missing_good =
                                    _building_construction_candidates[candidate].good_id;
                                if (good_market_available(
                                        source_cell, missing_good, false)) {
                                    reachable = true;
                                    if (missing != nullptr)
                                        missing->push_back(missing_good);
                                }
                            }
                        }
                        if (!reachable) {
                            structurally_unbuildable = true;
                            if (missing != nullptr)
                                missing->push_back(
                                    _building_construction_goods[group].good_id);
                        }
                    }
                }
                break;
            }
            for (size_t i = 0; i < plan.good_ids.size(); ++i)
                add_colonization_kit_cargo(kit, plan.good_ids[i], plan.quantities[i],
                    EXPEDITION_CARGO_CONSTRUCTION, sat);
        }
        return ok;
    };

    const std::vector<Planned> intent = planned;
    std::vector<int32_t> missing;
    while (!planned.empty() && !materials_fit(&missing)) {
        missing.clear();
        auto worst = std::max_element(planned.begin(), planned.end(),
            [](const Planned &a, const Planned &b) {
                return std::tie(a.drop_rank, a.type_id) <
                    std::tie(b.drop_rank, b.type_id);
            });
        if (worst->count > 1) {
            --worst->count;
            used_slots -= worst->owner_slots;
            if (worst->count == 1 && worst->type_id == food_type)
                worst->drop_rank = 10;
        } else {
            used_slots -= worst->owner_slots * worst->count;
            planned.erase(worst);
        }
    }
    // The kit only ships once the full intent is affordable, so the shortfall
    // to report is the one the intent still has today. Accumulating every
    // intermediate drop instead would keep listing goods that are already in
    // stock and would pin kit_partial on a shortage that no longer exists.
    kit.material_required_units = construction_units_of(intent);
    const int64_t affordable_units = construction_units_of(planned);
    kit.material_missing_units = std::max<int64_t>(0,
        kit.material_required_units - affordable_units);
    const bool intent_reduced = kit.material_missing_units > 0 ||
        planned.size() != intent.size();
    if (intent_reduced) {
        std::vector<Planned> affordable;
        affordable.swap(planned);
        planned = intent;
        std::vector<int32_t> material_missing;
        structurally_unbuildable = false;
        materials_fit(&material_missing);
        planned.swap(affordable);
        // materials_fit rewrites the construction cargo, so the shipped plan
        // has to be re-costed after the intent probe.
        materials_fit(nullptr);
        for (const int32_t good : material_missing) {
            if (std::find(kit.missing_good_ids.begin(),
                    kit.missing_good_ids.end(), good) ==
                kit.missing_good_ids.end())
                kit.missing_good_ids.push_back(good);
        }
        kit.kit_partial = 1;
    }
    kit.kit_unbuildable = (structurally_unbuildable ||
        kit.kit_unbuildable != 0) ? 1 : 0;
    rebuild_buildings();
    if (kit.buildings.empty())
        kit.kit_partial = 1;

    food_produced = 0;
    food_count = 0;
    for (const Planned &row : planned) {
        if (row.type_id == food_type) {
            food_count += row.count;
            food_produced = saturating_add(food_produced,
                saturating_mul(row.count, food_output, sat), sat);
        }
    }
    kit.food_coverage_q16 = food_required <= 0 ? Q16_ONE
        : mul_div_sat(food_produced, Q16_ONE, food_required, sat);

    fill_colonization_kit_buffer(source_cell, target_cell, population,
        travel_days, kit, reserve);

    const int32_t market = market_store().cell_to_market[source_cell];
    if (market >= 0 && market < market_store().market_count.get()) {
        int64_t sat = 0;
        std::vector<int64_t> billed(_good_ids.size(), 0);
        for (const FamilyExpeditionCargoLine &line : kit.cargo) {
            if (line.flags == EXPEDITION_CARGO_CONSTRUCTION &&
                line.good_id >= 0 &&
                line.good_id < static_cast<int32_t>(billed.size()))
                billed[static_cast<size_t>(line.good_id)] = saturating_add(
                    billed[static_cast<size_t>(line.good_id)], line.quantity,
                    sat);
        }
        std::vector<int64_t> reserved(_good_ids.size(), 0);
        for (const FamilyExpeditionCargoLine &line : kit.cargo) {
            if (line.good_id >= 0 &&
                line.good_id < static_cast<int32_t>(reserved.size()))
                reserved[static_cast<size_t>(line.good_id)] = saturating_add(
                    reserved[static_cast<size_t>(line.good_id)], line.quantity,
                    sat);
        }
        for (int32_t good = 0; good < static_cast<int32_t>(billed.size());
             ++good) {
            if (billed[static_cast<size_t>(good)] <= 0) continue;
            const int64_t stock = good < market_store().good_count.get()
                ? spare_source_stock(market, good) : 0;
            const int64_t leftover = std::max<int64_t>(0,
                stock - reserved[static_cast<size_t>(good)]);
            const int64_t extra = std::min(leftover,
                billed[static_cast<size_t>(good)]);
            add_colonization_kit_cargo(kit, good, extra, EXPEDITION_CARGO_BUFFER, sat);
        }
    }
    sort_colonization_kit_cargo(kit);
    std::sort(kit.missing_good_ids.begin(), kit.missing_good_ids.end());
    kit.missing_good_ids.erase(std::unique(kit.missing_good_ids.begin(),
        kit.missing_good_ids.end()), kit.missing_good_ids.end());
    kit.kit_hash = hash_colonization_kit_plan(kit);
    return true;
}

} // namespace pk
