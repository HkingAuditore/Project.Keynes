#include "economy_runtime.h"
#include "country_runtime.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <tuple>

namespace pk {

void NativeEconomyRuntime::add_colonization_kit_cargo(
        ColonizationKitPlan &kit, int32_t good_id, int64_t quantity,
        uint8_t flags, int64_t &sat) const {
    if (good_id < 0 || quantity <= 0) return;
    for (FamilyExpeditionCargoLine &line : kit.cargo) {
        if (line.good_id == good_id && line.flags == flags) {
            line.quantity = saturating_add(line.quantity, quantity, sat);
            return;
        }
    }
    kit.cargo.push_back({good_id, quantity, flags});
}

void NativeEconomyRuntime::sort_colonization_kit_cargo(
        ColonizationKitPlan &kit) const {
    std::sort(kit.cargo.begin(), kit.cargo.end(),
        [](const FamilyExpeditionCargoLine &a,
           const FamilyExpeditionCargoLine &b) {
            return std::tie(a.flags, a.good_id) < std::tie(b.flags, b.good_id);
        });
}

bool NativeEconomyRuntime::cell_has_submitted_or_pending_buildings(
        int32_t cell) const {
    if (cell < 0 || cell >= _cell_count) return false;
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            if (_buildings[group].count > 0) return true;
        }
        if (_pending_building_topology_rebuild) {
            const int32_t sorted_end = _building_cell_offsets[_cell_count];
            for (int32_t group = sorted_end;
                 group < static_cast<int32_t>(_buildings.size()); ++group) {
                if (_buildings[group].cell == cell &&
                    _buildings[group].count > 0)
                    return true;
            }
        }
    } else {
        for (const BuildingGroup &group : _buildings) {
            if (group.cell == cell && group.count > 0) return true;
        }
    }
    if (_pending_construction_cell_offsets.size() ==
            static_cast<size_t>(_cell_count + 1)) {
        for (int32_t cursor = _pending_construction_cell_offsets[cell];
             cursor < _pending_construction_cell_offsets[cell + 1]; ++cursor) {
            const int32_t pending_index =
                _pending_construction_cell_indices[cursor];
            if (pending_index >= 0 && pending_index < static_cast<int32_t>(
                    _pending_construction.size()) &&
                _pending_construction[pending_index].count > 0)
                return true;
        }
    } else {
        for (const PendingConstruction &pending : _pending_construction) {
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

void NativeEconomyRuntime::fill_colonization_kit_buffer(
        int32_t source_cell, int32_t target_cell, int64_t population,
        int32_t travel_days, ColonizationKitPlan &kit) const {
    if (population <= 0 || source_cell < 0 || source_cell >= _cell_count)
        return;
    const int32_t market = _market.cell_to_market[source_cell];
    if (market < 0 || market >= _market.market_count) return;
    const EnvironmentSample sample = environment_sample_for_cell(target_cell);
    const int32_t days = std::max(1, travel_days) +
        COLONIZATION_KIT_BRIDGE_EXTRA_DAYS;
    int64_t sat = 0;
    auto source_stock = [&](int32_t good) -> int64_t {
        if (good < 0 || good >= _market.good_count) return 0;
        return std::max<int64_t>(0, _market.stock[_market.index(market, good)]);
    };
    auto pick_stocked_good = [&](const std::vector<uint8_t> &mask,
                                 int32_t preferred) -> int32_t {
        if (preferred >= 0 && preferred < static_cast<int32_t>(mask.size()) &&
            mask[static_cast<size_t>(preferred)] != 0 &&
            source_stock(preferred) > 0)
            return preferred;
        for (int32_t good = 0; good < static_cast<int32_t>(mask.size()); ++good) {
            if (mask[static_cast<size_t>(good)] != 0 && source_stock(good) > 0)
                return good;
        }
        return preferred;
    };
    for (const int32_t stable_id : _survival_food_need_stable_ids) {
        if (stable_id < 0 || stable_id >= static_cast<int32_t>(
                _survival_required_need_indices.size())) continue;
        const int32_t need_index = _survival_required_need_indices[stable_id];
        if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size()))
            continue;
        const Need &need = _needs[need_index];
        int64_t units = saturating_mul(population, need.base_qty_per_person, sat);
        units = saturating_mul(units, days, sat);
        units = mul_div_sat(units,
            sample_environment_curve(need.quantity_env_curve, sample),
            Q16_ONE, sat);
        if (units <= 0) continue;
        int32_t preferred_good = -1;
        int64_t qty_per_need = GOODS_SCALE;
        for (int32_t variant = 0; variant < need.variant_count; ++variant) {
            const VariantChoice &choice = _variants[need.variant_begin + variant];
            if (choice.component_count != 1) continue;
            const NeedComponent &component =
                _components[choice.component_begin];
            if (component.good_id < 0 ||
                component.good_id >= static_cast<int32_t>(
                    _survival_food_good_mask.size()) ||
                _survival_food_good_mask[static_cast<size_t>(
                    component.good_id)] == 0)
                continue;
            preferred_good = component.good_id;
            qty_per_need = std::max<int64_t>(1, component.qty_per_need);
            break;
        }
        const int32_t good = pick_stocked_good(_survival_food_good_mask,
            preferred_good);
        if (good < 0) {
            kit.missing_good_ids.push_back(preferred_good);
            kit.kit_partial = 1;
            continue;
        }
        const int64_t quantity = mul_div_sat(units, qty_per_need, GOODS_SCALE, sat);
        const int64_t available = source_stock(good);
        if (available <= 0) {
            kit.missing_good_ids.push_back(good);
            kit.kit_partial = 1;
            continue;
        }
        if (available < quantity) {
            kit.missing_good_ids.push_back(good);
            kit.kit_partial = 1;
        }
        add_colonization_kit_cargo(kit, good, std::min(quantity, available),
            EXPEDITION_CARGO_BUFFER, sat);
    }
    int32_t clothing_good = -1;
    if (_survival_clothing_need_stable_id >= 0 &&
        _survival_clothing_need_stable_id < static_cast<int32_t>(
            _survival_required_need_indices.size())) {
        const int32_t need_index =
            _survival_required_need_indices[_survival_clothing_need_stable_id];
        if (need_index >= 0 && need_index < static_cast<int32_t>(_needs.size())) {
            const Need &need = _needs[need_index];
            for (int32_t variant = 0; variant < need.variant_count; ++variant) {
                const VariantChoice &choice =
                    _variants[need.variant_begin + variant];
                if (choice.component_count != 1) continue;
                const NeedComponent &component =
                    _components[choice.component_begin];
                if (component.good_id >= 0 &&
                    component.good_id < static_cast<int32_t>(
                        _survival_clothing_good_mask.size()) &&
                    _survival_clothing_good_mask[static_cast<size_t>(
                        component.good_id)] != 0) {
                    clothing_good = component.good_id;
                    break;
                }
            }
        }
    }
    clothing_good = pick_stocked_good(_survival_clothing_good_mask, clothing_good);
    if (clothing_good >= 0) {
        const int64_t wanted = saturating_mul(population,
            saturating_mul(COLONIZATION_KIT_CLOTHING_BUFFER_DAYS, GOODS_SCALE,
                sat), sat);
        const int64_t available = source_stock(clothing_good);
        if (available < wanted) {
            kit.missing_good_ids.push_back(clothing_good);
            kit.kit_partial = 1;
        }
        if (available > 0)
            add_colonization_kit_cargo(kit, clothing_good, std::min(wanted, available),
                EXPEDITION_CARGO_BUFFER, sat);
    }
    std::sort(kit.missing_good_ids.begin(), kit.missing_good_ids.end());
    kit.missing_good_ids.erase(std::unique(kit.missing_good_ids.begin(),
        kit.missing_good_ids.end()), kit.missing_good_ids.end());
}

bool NativeEconomyRuntime::plan_colonization_kit(
        int32_t source_cell, int32_t target_cell, int64_t population,
        int32_t travel_days, bool frozen, ColonizationKitPlan &kit) const {
    kit = ColonizationKitPlan{};
    kit.supported_population = std::max<int64_t>(0, population);
    if (source_cell < 0 || source_cell >= _cell_count ||
        target_cell < 0 || target_cell >= _cell_count || population <= 0)
        return false;
    const bool has_existing = cell_has_submitted_or_pending_buildings(target_cell);
    kit.place_buildings = has_existing ? 0 : 1;
    kit.dest_identity = 1469598103934665603ULL;
    kit.dest_identity = trace_hash_mix(kit.dest_identity, kit.place_buildings);
    // Mix the target cell's committed resource picture, not the per-epoch
    // lane cache stamp. `_resource_current_generation` increments at every
    // epoch begin and would invalidate every live quote after one cycle.
    if (!_resource_ids.empty() &&
        _resource_snapshot.size() >= _resource_ids.size() *
            static_cast<size_t>(_cell_count)) {
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            const size_t lane = resource * static_cast<size_t>(_cell_count) +
                static_cast<size_t>(target_cell);
            kit.dest_identity = trace_hash_mix(kit.dest_identity,
                static_cast<uint64_t>(_resource_snapshot[lane]));
        }
    }
    if (_country_runtime != nullptr) {
        NativeCountryRuntime::EconomySnapshot snapshot;
        if (_country_runtime->copy_economy_snapshot(snapshot))
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
            travel_days, kit);
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
    if (trade_type >= 0)
        try_add(trade_type, 1, 5);
    if (food_type >= 0) {
        while (used_slots + owner_slots_of(food_type) <= population &&
               try_add(food_type, 1, 50)) {}
    }

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
    auto materials_fit = [&](std::vector<int32_t> *missing) -> bool {
        std::vector<int64_t> stock(_good_ids.size(), 0);
        const int32_t market = _market.cell_to_market[source_cell];
        if (market < 0 || market >= _market.market_count) return false;
        for (int32_t good = 0; good < _market.good_count; ++good)
            stock[static_cast<size_t>(good)] = std::max<int64_t>(0,
                _market.stock[_market.index(market, good)]);
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
                    row.count, Q16_ONE, plan, nullptr, &stock) ||
                !plan.feasible) {
                ok = false;
                if (missing != nullptr && plan.failed_group >= 0) {
                    const int32_t group =
                        _building_types[row.type_id].construction_begin +
                        plan.failed_group;
                    if (group >= 0 && group < static_cast<int32_t>(
                            _building_construction_goods.size()))
                        missing->push_back(
                            _building_construction_goods[group].good_id);
                }
                break;
            }
            for (size_t i = 0; i < plan.good_ids.size(); ++i)
                add_colonization_kit_cargo(kit, plan.good_ids[i], plan.quantities[i],
                    EXPEDITION_CARGO_CONSTRUCTION, sat);
        }
        return ok;
    };

    std::vector<int32_t> missing;
    while (!planned.empty() && !materials_fit(&missing)) {
        kit.kit_partial = 1;
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
        missing.clear();
    }
    if (!missing.empty()) {
        kit.missing_good_ids.insert(kit.missing_good_ids.end(),
            missing.begin(), missing.end());
        kit.kit_partial = 1;
    }
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
        travel_days, kit);

    const int32_t market = _market.cell_to_market[source_cell];
    if (market >= 0 && market < _market.market_count) {
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
            const int64_t stock = std::max<int64_t>(0,
                _market.stock[_market.index(market, good)]);
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

bool NativeEconomyRuntime::adjust_market_stock(
        int32_t cell, int32_t good_id, int64_t delta, std::string &error) {
    if (cell < 0 || cell >= _cell_count || good_id < 0 ||
        good_id >= _market.good_count) {
        error = "colonization_kit_market_invalid";
        return false;
    }
    const int32_t market = _market.cell_to_market[cell];
    if (market < 0 || market >= _market.market_count) {
        error = "colonization_kit_market_invalid";
        return false;
    }
    const int64_t index = _market.index(market, good_id);
    const int64_t next = _market.stock[index] + delta;
    if (next < 0) {
        error = "colonization_kit_materials_short";
        return false;
    }
    audit_touch_market_lane(static_cast<size_t>(index));
    _market.stock[index] = next;
    return true;
}

bool NativeEconomyRuntime::extract_family_expedition_cargo(
        int32_t expedition, const ColonizationKitPlan &kit,
        std::string &error) {
    const int32_t source_cell = _family_expeditions.source_cell[expedition];
    for (const FamilyExpeditionCargoLine &line : kit.cargo) {
        if (!adjust_market_stock(source_cell, line.good_id, -line.quantity,
                error)) {
            for (const FamilyExpeditionCargoLine &undo : kit.cargo) {
                if (&undo == &line) break;
                std::string ignored;
                adjust_market_stock(source_cell, undo.good_id, undo.quantity,
                    ignored);
            }
            return false;
        }
    }
    _family_expeditions.cargo_begin[expedition] = static_cast<uint32_t>(
        _family_expedition_cargo.size());
    _family_expedition_cargo.insert(_family_expedition_cargo.end(),
        kit.cargo.begin(), kit.cargo.end());
    _family_expeditions.cargo_count[expedition] = static_cast<uint32_t>(
        kit.cargo.size());
    _family_expeditions.kit_building_begin[expedition] = static_cast<uint32_t>(
        _family_expedition_kit_buildings.size());
    if (kit.place_buildings != 0) {
        _family_expedition_kit_buildings.insert(
            _family_expedition_kit_buildings.end(),
            kit.buildings.begin(), kit.buildings.end());
        _family_expeditions.kit_building_count[expedition] =
            static_cast<uint32_t>(kit.buildings.size());
    } else {
        _family_expeditions.kit_building_count[expedition] = 0;
    }
    return true;
}

bool NativeEconomyRuntime::restore_family_expedition_cargo(
        int32_t expedition, int32_t destination_cell, bool consume_construction,
        std::string &error) {
    const uint32_t begin = _family_expeditions.cargo_begin[expedition];
    const uint32_t count = _family_expeditions.cargo_count[expedition];
    const uint32_t end = begin + count;
    if (end > _family_expedition_cargo.size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionCargoLine &line = _family_expedition_cargo[i];
        if (consume_construction &&
            line.flags == EXPEDITION_CARGO_CONSTRUCTION) {
            _construction_goods_consumed = saturating_add(
                _construction_goods_consumed, line.quantity,
                _saturation_count);
            continue;
        }
        if (!adjust_market_stock(destination_cell, line.good_id, line.quantity,
                error))
            return false;
    }
    _family_expeditions.cargo_count[expedition] = 0;
    return true;
}

bool NativeEconomyRuntime::settle_family_expedition_kit(
        int32_t expedition, int32_t destination_cell, std::string &error) {
    if (!restore_family_expedition_cargo(expedition, destination_cell, true,
            error))
        return false;
    const uint32_t begin = _family_expeditions.kit_building_begin[expedition];
    const uint32_t count = _family_expeditions.kit_building_count[expedition];
    const uint32_t end = begin + count;
    if (end > _family_expedition_kit_buildings.size()) {
        error = "colonization_kit_building_range_invalid";
        return false;
    }
    if (count == 0) return true;
    const uint64_t family_handle =
        _family_expeditions.family_handle[expedition];
    int32_t family = -1;
    if (!_families.valid_handle(family_handle, family)) {
        error = "colonization_family_invalid";
        return false;
    }
    int32_t ethnicity = _families.origin_ethnicity[family];
    if (ethnicity < 0) {
        _population.for_each_in_cell(destination_cell, [&](int32_t slot) {
            if (ethnicity >= 0) return;
            const int32_t signature =
                static_cast<int32_t>(_population.signature_id[slot]);
            if (signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size()))
                ethnicity = _signatures[signature].ethnicity_id;
        });
    }
    bool inserted = false;
    bool inserted_new_group = false;
    std::vector<std::pair<int32_t, int64_t>> placed;
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionKitBuilding &row =
            _family_expedition_kit_buildings[i];
        if (row.type_id < 0 ||
            row.type_id >= static_cast<int32_t>(_building_types.size()) ||
            row.count <= 0)
            continue;
        const BuildingType &type = _building_types[row.type_id];
        const int32_t owner_signature = signature_for_profession_ethnicity(
            type.owner_profession_id, std::max(0, ethnicity));
        if (owner_signature < 0) continue;
        const int32_t existing = find_building_group(
            destination_cell, row.type_id, owner_signature);
        if (existing >= 0) {
            _buildings[existing].count = saturating_add(
                _buildings[existing].count, row.count, _saturation_count);
            _building_handle_index_clean = false;
            if (_modifier_runtime != nullptr &&
                _buildings[existing].modifier_handle == 0) {
                _buildings[existing].modifier_handle =
                    _modifier_runtime->ensure_building_identity(
                        destination_cell, row.type_id, owner_signature);
            }
        } else {
            BuildingGroup group;
            group.cell = destination_cell;
            group.type_id = row.type_id;
            group.owner_signature_id = owner_signature;
            group.count = row.count;
            if (_modifier_runtime != nullptr) {
                group.modifier_handle =
                    _modifier_runtime->ensure_building_identity(
                        destination_cell, row.type_id, owner_signature);
            }
            _buildings.push_back(group);
            ++_building_structure_new_groups;
            inserted_new_group = true;
        }
        placed.push_back({row.type_id, row.count});
        inserted = true;
    }
    if (!inserted) return true;
    // Do not rebuild market/labor CSRs during LEDGER_APPLY. Frozen epoch
    // production reserves and group-parallel arrays are keyed by the
    // epoch-begin permutation; inserting a mid-index cell would shift every
    // later signal and fail goods conservation on a live map. Append like
    // commit_ready_construction and wait for BUILDING_COMMIT. Idle landings
    // have no frozen workset, so they rebuild immediately for Inspector.
    if (inserted_new_group) {
        if (_epoch_active)
            _pending_building_topology_rebuild = true;
        else {
            rebuild_building_role_storage();
            refresh_building_modifier_factors();
        }
    }

    for (const auto &row : placed) {
        const BuildingType &type = _building_types[row.first];
        const int32_t owner_signature = signature_for_profession_ethnicity(
            type.owner_profession_id, std::max(0, ethnicity));
        if (owner_signature < 0) continue;
        const int64_t needed = saturating_mul(row.second,
            std::max<int64_t>(1, type.owner_slots_per_building),
            _saturation_count);
        int32_t owner_slot = find_cohort_slot(destination_cell, owner_signature);
        int64_t have = owner_slot >= 0 ? _population.population[owner_slot] : 0;
        int64_t missing = std::max<int64_t>(0, needed - have);
        struct Candidate {
            int32_t slot = -1;
            bool unemployed = false;
            int32_t profession = 0;
            int32_t ethnicity_id = 0;
            uint64_t handle = 0;
        };
        std::vector<Candidate> candidates;
        _population.for_each_in_cell(destination_cell, [&](int32_t slot) {
            if (_population.population[slot] <= 0) return;
            const int32_t signature =
                static_cast<int32_t>(_population.signature_id[slot]);
            if (signature == owner_signature) return;
            if (signature < 0 ||
                signature >= static_cast<int32_t>(_signatures.size()))
                return;
            candidates.push_back({slot,
                _signatures[signature].profession_id ==
                    _unemployed_profession_id,
                _signatures[signature].profession_id,
                _signatures[signature].ethnicity_id,
                _population.handle_for_slot(slot)});
        });
        std::sort(candidates.begin(), candidates.end(),
            [](const Candidate &a, const Candidate &b) {
                return std::tuple(!a.unemployed, a.profession, a.ethnicity_id,
                    a.handle) <
                    std::tuple(!b.unemployed, b.profession, b.ethnicity_id,
                        b.handle);
            });
        for (const Candidate &candidate : candidates) {
            if (missing <= 0) break;
            if (candidate.slot < 0 ||
                candidate.slot >= static_cast<int32_t>(_population.active.size()) ||
                _population.active[candidate.slot] == 0)
                continue;
            const int64_t take = std::min(missing,
                _population.population[candidate.slot]);
            if (take <= 0) continue;
            if (!move_cohort_population(candidate.slot, destination_cell,
                    owner_signature, take, error, nullptr, family_handle))
                return false;
            missing -= take;
        }
        owner_slot = find_cohort_slot(destination_cell, owner_signature);
        const int32_t group_index = find_building_group(
            destination_cell, row.first, owner_signature);
        if (group_index >= 0) {
            const int64_t filled = owner_slot >= 0
                ? std::min(needed, _population.population[owner_slot]) : 0;
            _buildings[group_index].filled_owner = filled;
            if (owner_slot >= 0)
                _population.owner_employed[owner_slot] = std::max(
                    _population.owner_employed[owner_slot], filled);
            if (_buildings[group_index].modifier_handle != 0) {
                bool found = false;
                for (FamilyBuildingOwnership &edge : _family_ownerships) {
                    if (edge.family_handle == family_handle &&
                        edge.building_handle ==
                            _buildings[group_index].modifier_handle) {
                        edge.owned_count = saturating_add(
                            edge.owned_count, row.second, _saturation_count);
                        edge.filled_owner = std::max(edge.filled_owner,
                            filled);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    _family_ownerships.push_back({family_handle,
                        _buildings[group_index].modifier_handle, row.second,
                        filled});
                }
                _family_indices_dirty = true;
            }
        }
    }
    _structural_touched_cells.push_back(destination_cell);
    return true;
}

} // namespace pk
