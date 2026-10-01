#include "economy_runtime.h"
#include "country_runtime.h"
#include "modifier_runtime.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <limits>
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
            if (buildings_store().group_units[group] > 0) return true;
        }
        if (_pending_building_topology_rebuild) {
            const int32_t sorted_end = _building_cell_offsets[_cell_count];
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
            static_cast<size_t>(_cell_count + 1)) {
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

void NativeEconomyRuntime::fill_colonization_kit_buffer(
        int32_t source_cell, int32_t target_cell, int64_t population,
        int32_t travel_days, ColonizationKitPlan &kit,
        const ColonizationReserveContext *reserve,
        int32_t bridge_days_override) const {
    if (population <= 0 || source_cell < 0 || source_cell >= _cell_count)
        return;
    const int32_t market = market_store().cell_to_market[source_cell];
    if (market < 0 || market >= market_store().market_count) return;
    auto extra_stock = [&](const std::vector<int64_t> *lane,
                           int32_t good) -> int64_t {
        if (lane == nullptr || good < 0 ||
            good >= static_cast<int32_t>(lane->size())) return 0;
        return std::max<int64_t>(0, (*lane)[static_cast<size_t>(good)]);
    };
    // A preparing party may escrow any source-market stock that is not already
    // committed to another line of this kit. Household survival remains part
    // of ordinary market settlement rather than a colonization-only floor.
    auto spare_stock = [&](int32_t good) -> int64_t {
        if (good < 0 || good >= market_store().good_count) return 0;
        const int64_t stock = std::max<int64_t>(0,
            market_store().stock[market_store().index(market, good)]);
        const int64_t held = reserve == nullptr ? 0
            : extra_stock(reserve->reserved, good);
        return stock + held;
    };
    kit.source_stock_identity = 1469598103934665603ULL;
    for (int32_t good = 0; good < market_store().good_count; ++good) {
        kit.source_stock_identity = trace_hash_mix(
            kit.source_stock_identity,
            static_cast<uint64_t>(spare_stock(good)));
    }
    if (kit.source_stock_identity == 0) kit.source_stock_identity = 1;
    const EnvironmentSample sample = environment_sample_for_cell(target_cell);
    const int32_t days = bridge_days_override > 0 ? bridge_days_override
        : std::max(1, travel_days) + COLONIZATION_KIT_BRIDGE_EXTRA_DAYS;
    int64_t sat = 0;
    auto source_stock = [&](int32_t good) -> int64_t {
        if (good < 0 || good >= market_store().good_count) return 0;
        // Construction materials and previously selected bridge goods already
        // reserve the source market stock.  Every subsequent line must draw
        // from the remaining balance, otherwise a good shared by the build
        // plan and the survival bridge can be billed twice and fail at start.
        int64_t planned = 0;
        for (const FamilyExpeditionCargoLine &line : kit.cargo) {
            if (line.good_id != good || line.quantity <= 0) continue;
            planned = saturating_add(planned, line.quantity, sat);
        }
        return std::max<int64_t>(0, spare_stock(good) - planned);
    };
    struct BufferCandidate {
        int32_t good_id = -1;
        int64_t contribution_numerator = 0;
        int64_t contribution_denominator = 1;
    };
    auto add_candidate = [&](std::vector<BufferCandidate> &candidates,
                            int32_t good, int64_t numerator,
                            int64_t denominator) {
        // A stocked local market is already a valid procurement source.  Do
        // not discard it merely because the source cell cannot currently
        // produce that good: market inventory may have arrived through an
        // earlier production epoch or domestic trade.  Goods with no stock
        // still need a source production capability, so future-era variants
        // from the consumption catalog do not become phantom requirements.
        const bool has_stock = good >= 0 && good < market_store().good_count &&
            spare_stock(good) > 0;
        if (good < 0 || numerator <= 0 || denominator <= 0 ||
            (!has_stock && !good_production_available(source_cell, good, false)))
            return;
        for (const BufferCandidate &candidate : candidates)
            if (candidate.good_id == good) return;
        candidates.push_back({good, numerator, denominator});
    };
    auto fill_group = [&](int64_t required,
                          std::vector<BufferCandidate> candidates) {
        int64_t remaining = std::max<int64_t>(0, required);
        kit.bridge_required_units = saturating_add(kit.bridge_required_units,
            remaining, sat);
        // A party that escrowed a substitute over previous days must keep
        // spending that one first, otherwise a newly stocked preferred
        // candidate would strand the goods already paid for.
        if (reserve != nullptr && reserve->prefer_reserved_candidates) {
            std::stable_partition(candidates.begin(), candidates.end(),
                [&](const BufferCandidate &candidate) {
                    return extra_stock(reserve->reserved,
                        candidate.good_id) > 0;
                });
        }
        for (const BufferCandidate &candidate : candidates) {
            if (remaining <= 0) break;
            int64_t physical_needed = mul_div_sat(remaining,
                candidate.contribution_denominator,
                candidate.contribution_numerator, sat);
            if (mul_div_sat(physical_needed,
                    candidate.contribution_numerator,
                    candidate.contribution_denominator, sat) < remaining) {
                physical_needed = saturating_add(physical_needed, 1, sat);
            }
            const int64_t physical = std::min(
                source_stock(candidate.good_id), physical_needed);
            if (physical <= 0) continue;
            add_colonization_kit_cargo(kit, candidate.good_id, physical,
                EXPEDITION_CARGO_BUFFER, sat);
            const int64_t credited = mul_div_sat(physical,
                candidate.contribution_numerator,
                candidate.contribution_denominator, sat);
            remaining = std::max<int64_t>(0,
                remaining - std::min(remaining, credited));
        }
        if (remaining <= 0) return;
        kit.bridge_missing_units = saturating_add(kit.bridge_missing_units,
            remaining, sat);
        kit.kit_partial = 1;
        for (const BufferCandidate &candidate : candidates)
            kit.missing_good_ids.push_back(candidate.good_id);
    };
    // The expedition carries one aggregate food bridge. The household
    // runtime still keeps staple, protein, and produce as separate needs, but
    // a stocked food candidate from any of those needs can keep a travelling
    // party alive until the destination starts producing.
    int64_t food_units = 0;
    std::vector<BufferCandidate> food_candidates;
    food_candidates.reserve(static_cast<size_t>(
        _survival_food_need_stable_ids.size()) * 4);
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
        food_units = saturating_add(food_units, units, sat);
        for (int32_t variant = 0; variant < need.variant_count; ++variant) {
            const VariantChoice &choice = _variants[need.variant_begin + variant];
            if (choice.component_count != 1) continue;
            const NeedComponent &component =
                _components[choice.component_begin];
            add_candidate(food_candidates, component.good_id, GOODS_SCALE,
                std::max<int64_t>(1, component.qty_per_need));
        }
    }
    fill_group(food_units, food_candidates);
    int32_t clothing_need_index = -1;
    if (_survival_clothing_need_stable_id >= 0 &&
        _survival_clothing_need_stable_id < static_cast<int32_t>(
            _survival_required_need_indices.size())) {
        clothing_need_index =
            _survival_required_need_indices[_survival_clothing_need_stable_id];
    }
    if (clothing_need_index >= 0 &&
        clothing_need_index < static_cast<int32_t>(_needs.size())) {
        const Need &clothing_need = _needs[clothing_need_index];
        int64_t units = saturating_mul(population,
            clothing_need.base_qty_per_person, sat);
        units = saturating_mul(units, days, sat);
        units = mul_div_sat(units,
            sample_environment_curve(clothing_need.quantity_env_curve, sample),
            Q16_ONE, sat);
        std::vector<BufferCandidate> candidates;
        candidates.reserve(static_cast<size_t>(clothing_need.variant_count));
        for (int32_t variant = 0; variant < clothing_need.variant_count;
             ++variant) {
            const VariantChoice &choice =
                _variants[clothing_need.variant_begin + variant];
            if (choice.component_count != 1) continue;
            const NeedComponent &component =
                _components[choice.component_begin];
            add_candidate(candidates, component.good_id, GOODS_SCALE,
                std::max<int64_t>(1, component.qty_per_need));
        }
        fill_group(units, candidates);
    }
    int64_t kit_building_total = 0;
    for (const FamilyExpeditionKitBuilding &row : kit.buildings)
        kit_building_total = saturating_add(kit_building_total, row.count, sat);
    const int32_t tool_days = std::max(days, std::max<int32_t>(1,
        static_cast<int32_t>(std::min<int64_t>(kit_building_total,
            static_cast<int64_t>(std::numeric_limits<int32_t>::max())))));
    for (const FamilyExpeditionKitBuilding &row : kit.buildings) {
        if (row.type_id < 0 ||
            row.type_id >= static_cast<int32_t>(_building_type_ids.size()) ||
            _building_type_ids[static_cast<size_t>(row.type_id)] !=
                "gathering_ground")
            continue;
        const BuildingType &type = _building_types[row.type_id];
        for (int32_t input = 0; input < type.input_count; ++input) {
            const ProductionInput &item =
                _building_inputs[type.input_begin + input];
            if (!colonization_good_is_tools(item.preferred_good_id)) continue;
            int64_t wanted = saturating_mul(item.quantity, row.count, sat);
            wanted = saturating_mul(wanted, tool_days, sat);
            if (wanted <= 0) continue;
            std::vector<BufferCandidate> candidates;
            candidates.reserve(static_cast<size_t>(item.candidate_count));
            for (int32_t pass = 0; pass < 2; ++pass) {
                for (int32_t candidate_index = item.candidate_begin;
                     candidate_index < item.candidate_begin + item.candidate_count;
                     ++candidate_index) {
                    if (candidate_index < 0 || candidate_index >=
                            static_cast<int32_t>(_building_input_candidates.size()))
                        continue;
                    const InputCandidate &candidate =
                        _building_input_candidates[candidate_index];
                    const bool preferred = candidate.good_id ==
                        item.preferred_good_id;
                    if ((pass == 0) != preferred) continue;
                    add_candidate(candidates, candidate.good_id,
                        std::max<int32_t>(1, candidate.efficiency_q16), Q16_ONE);
                }
            }
            // 尚未解锁的软工具投入只降低产量，不能变成永远凑不齐的出发条件。
            if (candidates.empty() && item.required_q16 < Q16_ONE) continue;
            fill_group(wanted, candidates);
        }
    }
    std::sort(kit.missing_good_ids.begin(), kit.missing_good_ids.end());
    kit.missing_good_ids.erase(std::unique(kit.missing_good_ids.begin(),
        kit.missing_good_ids.end()), kit.missing_good_ids.end());
}

bool NativeEconomyRuntime::plan_colonization_kit(
        int32_t source_cell, int32_t target_cell, int64_t population,
        int32_t travel_days, bool frozen, ColonizationKitPlan &kit,
        bool ignore_existing, const ColonizationReserveContext *reserve) const {
    kit = ColonizationKitPlan{};
    kit.supported_population = std::max<int64_t>(0, population);
    if (source_cell < 0 || source_cell >= _cell_count ||
        target_cell < 0 || target_cell >= _cell_count || population <= 0)
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
            static_cast<size_t>(_cell_count)) {
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            const size_t lane = resource * static_cast<size_t>(_cell_count) +
                static_cast<size_t>(target_cell);
            kit.dest_identity = trace_hash_mix(kit.dest_identity,
                static_cast<uint64_t>(resource_stock_lanes()[lane]));
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
        if (market < 0 || market >= market_store().market_count) return false;
        for (int32_t good = 0; good < market_store().good_count; ++good)
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
                    row.count, Q16_ONE, plan, nullptr, &stock, true) ||
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
    kit.kit_unbuildable = structurally_unbuildable ? 1 : 0;
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
    if (market >= 0 && market < market_store().market_count) {
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
            const int64_t stock = good < market_store().good_count
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

bool NativeEconomyRuntime::adjust_market_stock(
        int32_t cell, int32_t good_id, int64_t delta, std::string &error) {
    if (cell < 0 || cell >= _cell_count || good_id < 0 ||
        good_id >= market_store().good_count) {
        error = "colonization_kit_market_invalid";
        return false;
    }
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count) {
        error = "colonization_kit_market_invalid";
        return false;
    }
    const int64_t index = market_store().index(market, good_id);
    const int64_t next = market_store().stock[index] + delta;
    if (next < 0) {
        error = "colonization_kit_materials_short";
        return false;
    }
    audit_touch_market_lane(static_cast<size_t>(index));
    market_store().stock[index] = next;
    return true;
}

void NativeEconomyRuntime::collect_family_expedition_reserved_stock(
        int32_t expedition, std::vector<int64_t> &reserved) const {
    reserved.assign(_good_ids.size(), 0);
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0) return;
    const uint32_t begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t end = std::min<uint32_t>(
        static_cast<uint32_t>(family_expedition_cargo().size()),
        begin + family_expeditions_store().cargo_count[expedition]);
    int64_t sat = 0;
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionCargoLine &line = family_expedition_cargo()[i];
        if (line.good_id < 0 ||
            line.good_id >= static_cast<int32_t>(reserved.size())) continue;
        reserved[static_cast<size_t>(line.good_id)] = saturating_add(
            reserved[static_cast<size_t>(line.good_id)], line.quantity, sat);
    }
}

void NativeEconomyRuntime::note_family_expedition_procurement_rejection(
        int32_t expedition, int32_t good, uint8_t cargo_flags, int64_t day,
        const std::string &reason) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size())) return;
    FamilyExpeditionProcurementRejection &note =
        _family_expedition_procurement_rejections[expedition];
    note.generation = family_expeditions_store().generation[expedition];
    note.good = good;
    note.cargo_flags = cargo_flags;
    note.day = day;
    note.reason = reason.empty() ? "colonization_treasury_purchase_failed"
                                 : reason;
}

bool NativeEconomyRuntime::reserve_preparing_family_expedition_cargo(
        int32_t expedition, ColonizationKitPlan &kit,
        std::string &error, int64_t day) {
    const int32_t source_cell = family_expeditions_store().source_cell[expedition];
    const uint32_t begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t count = family_expeditions_store().cargo_count[expedition];
    if (static_cast<size_t>(begin) + count > family_expedition_cargo().size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    // The planner already counted the escrow as available stock, so every kit
    // line states the total the party must hold. Only the difference moves:
    // surplus goes back to the source market first so the top-up can spend it.
    // Cargo can contain duplicate rows after a kit is re-planned.  Treat the
    // escrow as a multiset; looking only at the first row loses stock when the
    // market delta is calculated and eventually breaks goods conservation.
    auto quantity_for = [](const std::vector<FamilyExpeditionCargoLine> &rows,
            int32_t good, uint8_t flags) -> int64_t {
        int64_t total = 0;
        int64_t saturation = 0;
        for (const FamilyExpeditionCargoLine &line : rows)
            if (line.good_id == good && line.flags == flags)
                total = NativeEconomyRuntime::saturating_add(
                    total, line.quantity, saturation);
        return total;
    };
    std::vector<FamilyExpeditionCargoLine> old_cargo;
    old_cargo.reserve(count);
    for (uint32_t i = 0; i < count; ++i)
        old_cargo.push_back(family_expedition_cargo()[begin + i]);
    auto store_cargo = [&](const std::vector<FamilyExpeditionCargoLine> &rows) {
        uint32_t &stored_begin =
            family_expeditions_store().cargo_begin[expedition];
        uint32_t &stored_count =
            family_expeditions_store().cargo_count[expedition];
        if (rows.size() <= stored_count &&
            static_cast<size_t>(stored_begin) + stored_count <=
                family_expedition_cargo().size()) {
            for (size_t i = 0; i < rows.size(); ++i)
                family_expedition_cargo()[stored_begin + i] = rows[i];
        } else {
            stored_begin = static_cast<uint32_t>(
                family_expedition_cargo().size());
            family_expedition_cargo().insert(family_expedition_cargo().end(),
                rows.begin(), rows.end());
        }
        stored_count = static_cast<uint32_t>(rows.size());
        note_family_expedition_audit_invalidation();
    };
    std::vector<std::pair<int32_t, int64_t>> applied;
    auto move_stock = [&](int32_t good, int64_t delta,
                          uint8_t cargo_flags) -> bool {
        if (delta == 0) return true;
        if (delta < 0) {
            const int64_t quantity = -delta;
            const int32_t market = market_store().cell_to_market[source_cell];
            const int64_t price = market >= 0 && market < market_store().market_count
                ? std::max<int64_t>(0, market_store().price[
                    market_store().index(market, good)]) : 0;
            const int64_t cash = goods_cost(quantity, price, _saturation_count);
            std::vector<int32_t> ids{good};
            std::vector<int64_t> treasury{0};
            std::vector<int64_t> market_goods{quantity};
            int64_t committed_cash = 0;
            FamilyExpeditionProcurementContinuation &continuation =
                _family_expedition_procurement_continuation;
            bool purchased = false;
            if (continuation.active) {
                if (continuation.expedition != expedition ||
                    continuation.good != good ||
                    continuation.cargo_flags != cargo_flags ||
                    continuation.quantity != quantity) {
                    error = "colonization_treasury_peer_busy";
                    return false;
                }
                purchased = advance_family_expedition_procurement(
                    continuation, error);
            } else {
                purchased = start_family_expedition_procurement(
                    continuation, expedition, source_cell, market, good,
                    cargo_flags, quantity, cash, error);
            }
            if (!purchased) {
                if (error.empty()) error = "colonization_treasury_purchase_failed";
                return false;
            }
            auto acquired = std::find_if(old_cargo.begin(), old_cargo.end(),
                [&](const FamilyExpeditionCargoLine &held) {
                    return held.good_id == good && held.flags == cargo_flags;
                });
            if (acquired == old_cargo.end()) {
                old_cargo.push_back({good, quantity, cargo_flags});
            } else {
                acquired->quantity = saturating_add(acquired->quantity,
                    quantity, _saturation_count);
            }
            std::sort(old_cargo.begin(), old_cargo.end(),
                [](const FamilyExpeditionCargoLine &a,
                   const FamilyExpeditionCargoLine &b) {
                    return std::tie(a.flags, a.good_id) <
                        std::tie(b.flags, b.good_id);
                });
            store_cargo(old_cargo);
            // The purchase is also a non-household demand event.  Keep the
            // market pressure path identical to construction procurement.
            const int32_t signal = ensure_market_signal_index(source_cell, good);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())) {
                _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                    _epoch_nonhousehold_withdrawals[signal], quantity,
                    _saturation_count);
                _market_signals.business_demand_ema[signal] = saturating_add(
                    _market_signals.business_demand_ema[signal], quantity,
                    _saturation_count);
                _market_signals.realized_withdrawal_ema[signal] = saturating_add(
                    _market_signals.realized_withdrawal_ema[signal], quantity,
                    _saturation_count);
            }
            return true;
        }
        if (!adjust_market_stock(source_cell, good, delta, error)) {
            for (auto it = applied.rbegin(); it != applied.rend(); ++it) {
                std::string ignored;
                adjust_market_stock(source_cell, it->first, -it->second,
                    ignored);
            }
            return false;
        }
        applied.push_back({good, delta});
        return true;
    };
    for (size_t old_index = 0; old_index < old_cargo.size(); ++old_index) {
        const FamilyExpeditionCargoLine &held = old_cargo[old_index];
        bool seen = false;
        for (size_t j = 0; j < old_index; ++j)
            if (old_cargo[j].good_id == held.good_id &&
                old_cargo[j].flags == held.flags) {
                seen = true;
                break;
            }
        if (seen) continue;
        const int64_t held_total = quantity_for(old_cargo, held.good_id, held.flags);
        const int64_t net_surplus = held_total -
            quantity_for(kit.cargo, held.good_id, held.flags);
        // Returning already purchased cargo would require a matching merchant
        // refund. Keep the escrow monotonic during preparation; the planner's
        // reserve-aware quote prevents unnecessary top-ups.
        if (net_surplus > 0) continue;
    }
    // Only one purchase can be in flight. A line the Country side rejected
    // must not starve every later line, so a terminal rejection is recorded
    // and the next line is tried; a line rejected earlier today waits.
    int32_t skip_good = -1;
    uint8_t skip_flags = 0;
    {
        const auto rejection = _family_expedition_procurement_rejections.find(
            expedition);
        if (day >= 0 &&
            rejection != _family_expedition_procurement_rejections.end() &&
            rejection->second.generation ==
                family_expeditions_store().generation[expedition] &&
            rejection->second.day == day) {
            skip_good = rejection->second.good;
            skip_flags = rejection->second.cargo_flags;
        }
    }
    bool short_lines = false;
    for (size_t kit_index = 0; kit_index < kit.cargo.size(); ++kit_index) {
        const FamilyExpeditionCargoLine &line = kit.cargo[kit_index];
        bool seen = false;
        for (size_t j = 0; j < kit_index; ++j)
            if (kit.cargo[j].good_id == line.good_id &&
                kit.cargo[j].flags == line.flags) {
                seen = true;
                break;
            }
        if (seen) continue;
        const int64_t net_shortfall = quantity_for(kit.cargo, line.good_id,
            line.flags) - quantity_for(old_cargo, line.good_id, line.flags);
        if (net_shortfall <= 0) continue;
        if (skip_good == line.good_id && skip_flags == line.flags) {
            short_lines = true;
            continue;
        }
        if (move_stock(line.good_id, -net_shortfall, line.flags)) continue;
        const FamilyExpeditionProcurementContinuation &continuation =
            _family_expedition_procurement_continuation;
        if (continuation.active) return false;
        note_family_expedition_procurement_rejection(expedition,
            line.good_id, line.flags, day, error);
        error.clear();
        short_lines = true;
    }
    if (short_lines) {
        error = "colonization_procurement_short";
        return false;
    }
    // The planner's quote is a target, not the authoritative escrow. A quote
    // can shrink when market stock or a substitute changes; never overwrite
    // goods already purchased by earlier preparation days. Merge by key and
    // keep the larger quantity, then append any old key omitted by the quote.
    std::vector<FamilyExpeditionCargoLine> merged = kit.cargo;
    for (const FamilyExpeditionCargoLine &old_line : old_cargo) {
        auto found = std::find_if(merged.begin(), merged.end(),
            [&](const FamilyExpeditionCargoLine &line) {
                return line.good_id == old_line.good_id &&
                    line.flags == old_line.flags;
            });
        if (found == merged.end()) {
            merged.push_back(old_line);
        } else if (found->quantity < old_line.quantity) {
            found->quantity = old_line.quantity;
        }
    }
    kit.cargo.swap(merged);
    store_cargo(kit.cargo);
    return true;
}

bool NativeEconomyRuntime::extract_family_expedition_cargo(
        int32_t expedition, const ColonizationKitPlan &kit,
        std::string &error) {
    // Procurement has already populated the expedition cargo range. Only the
    // frozen building plan is attached here.
    error.clear();
    const uint32_t cargo_begin =
        family_expeditions_store().cargo_begin[expedition];
    const uint32_t cargo_count =
        family_expeditions_store().cargo_count[expedition];
    if (static_cast<size_t>(cargo_begin) + cargo_count >
            family_expedition_cargo().size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    family_expeditions_store().kit_building_begin[expedition] = static_cast<uint32_t>(
        family_expedition_kit_buildings().size());
    if (kit.place_buildings != 0) {
        family_expedition_kit_buildings().insert(
            family_expedition_kit_buildings().end(),
            kit.buildings.begin(), kit.buildings.end());
        family_expeditions_store().kit_building_count[expedition] =
            static_cast<uint32_t>(kit.buildings.size());
    } else {
        family_expeditions_store().kit_building_count[expedition] = 0;
    }
    return true;
}

bool NativeEconomyRuntime::restore_family_expedition_cargo(
        int32_t expedition, int32_t destination_cell, bool consume_construction,
        std::string &error) {
    const uint32_t begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t count = family_expeditions_store().cargo_count[expedition];
    const uint32_t end = begin + count;
    if (end > family_expedition_cargo().size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    int64_t construction_consumed = 0;
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionCargoLine &line = family_expedition_cargo()[i];
        if (consume_construction &&
            line.flags == EXPEDITION_CARGO_CONSTRUCTION) {
            construction_consumed = saturating_add(construction_consumed,
                line.quantity, _saturation_count);
            continue;
        }
        if (!adjust_market_stock(destination_cell, line.good_id, line.quantity,
                error))
            return false;
    }
    family_expeditions_store().cargo_count[expedition] = 0;
    // Idle/opening-prelude settlements belong to the next opening baseline.
    if (construction_consumed > 0 && _epoch_active)
        _construction_goods_consumed = saturating_add(
            _construction_goods_consumed, construction_consumed,
            _saturation_count);
    return true;
}

bool NativeEconomyRuntime::advance_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &c, std::string &error) {
    error.clear();
    if (!c.active) return true;
    if (_country_runtime == nullptr || !_country_runtime->economy_available()) {
        c.last_error = "colonization_treasury_peer_unavailable";
        c.active = false;
        error = c.last_error;
        return false;
    }
    if (c.phase == 1) {
        if (c.pending_request_id != 0) {
            RuntimeEconomyAssetResult terminal;
            if (!_simulation_host ||
                !_simulation_host->country_economy_asset_terminal_result(
                    c.pending_request_id, terminal)) {
                error = "colonization_treasury_peer_pending";
                return false;
            }
            if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
                terminal.operation != RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
                c.last_error = terminal.reason[0] != '\0'
                    ? terminal.reason.data()
                    : "colonization_treasury_peer_rejected";
                _simulation_host->acknowledge_country_economy_asset_consumed(
                    c.pending_request_id);
                c.active = false;
                c.pending_request_id = 0;
                error = c.last_error;
                return false;
            }
            if (_simulation_host->domain_is_worker_authoritative(
                    RuntimeDomainId::ECONOMY)) {
                if (!_simulation_host->finish_worker_country_asset(
                        c.pending_request_id, terminal, error)) {
                    return false;
                }
            } else if (!_simulation_host->flush_country_economy_asset_commits(
                           error, c.pending_request_id) ||
                       !_simulation_host->publish_country_worker_snapshot(
                           RUNTIME_DIRTY_COUNTRY_STATE, error)) {
                return false;
            } else {
                _simulation_host->acknowledge_country_economy_asset_consumed(
                    c.pending_request_id);
            }
            c.transaction_id = c.pending_request_id;
            c.session_epoch = terminal.session_epoch;
            c.country_generation = terminal.country_generation;
            c.peer_generation = _committed_generation;
            c.pending_request_id = 0;
            c.host_peer = true;
            // The worker-side GOOD_FROM_MARKET service already removed the
            // market stock. Only the sync path applies that mutation below.
            c.market_applied = true;
            c.phase = 4;
        } else {
            error = "colonization_treasury_peer_pending";
            return false;
        }
    }
    if (c.phase == 4) {
        if (!c.market_applied) {
            const size_t lane = market_store().index(c.market, c.good);
            if (lane >= market_store().stock.size() ||
                market_store().stock[lane] < c.quantity) {
                c.active = false;
                error = "colonization_treasury_peer_market_stock_drift";
                return false;
            }
            audit_touch_market_lane(lane);
            market_store().stock[lane] -= c.quantity;
            c.market_applied = true;
        }
        while (c.merchant_cursor < c.living_merchants.size()) {
            const int32_t slot = c.living_merchants[c.merchant_cursor++];
            c.merchant_population_prefix = saturating_add(
                c.merchant_population_prefix,
                population_store().population[slot], _saturation_count);
            const int64_t next = mul_div_sat(
                c.cash, c.merchant_population_prefix,
                c.merchant_population, _saturation_count);
            const int64_t share = std::max<int64_t>(
                0, next - c.merchant_distributed);
            c.merchant_distributed = next;
            audit_touch_population_lane(slot);
            touch_accounting_slot(slot);
            population_store().funds[slot] = saturating_add(
                population_store().funds[slot], share, _saturation_count);
            population_store().epoch_income[slot] = saturating_add(
                population_store().epoch_income[slot], share, _saturation_count);
            trace_record_cashflow(c.source_cell,
                population_store().handle_for_slot(slot),
                CASHFLOW_MERCHANT_BUSINESS, share, 0);
        }
        if (c.merchant_distributed != c.cash) {
            c.active = false;
            error = "colonization_treasury_peer_distribution_drift";
            return false;
        }
        if (!c.host_peer) {
            const godot::Dictionary applied =
                _country_runtime->acknowledge_economy_asset_peer_applied(
                    c.transaction_id, c.session_epoch, c.country_generation,
                    c.peer_generation, true, godot::String());
            if (!static_cast<bool>(applied.get("ok", false)) ||
                godot::String(applied.get("status_name", "")) != "completed") {
                c.phase = 6;
                error = "colonization_treasury_peer_apply_ack_failed";
                return false;
            }
        }
        // The market purchase has put the goods into the Country treasury.
        // Move the same quantity out of that treasury before the caller adds
        // it to the expedition cargo, preserving the goods ledger.
        c.host_peer = false;
        c.pending_request_id = 0;
        const std::vector<int32_t> ids{c.good};
        const std::vector<int64_t> treasury{c.quantity};
        const auto route = block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(NativeCountryRuntime::ECONOMY_ASSET_TREASURY_SPEND),
            static_cast<uint64_t>(family_expeditions_store().country_handle[c.expedition]),
            0, c.quantity, ids, treasury, error, &c.pending_request_id);
        if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
            c.host_peer = true;
            c.phase = 5;
            error = "colonization_treasury_transfer_pending";
            return false;
        }
        if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
            // The market -> Country leg has already committed at this point.
            // Country worker backpressure (including a temporarily closed
            // operation gate) must not discard that completed leg: doing so
            // leaves cash and market goods debited while the expedition cargo
            // is still empty, which later trips the global conservation audit.
            // Keep the continuation at phase 4 and retry the treasury ->
            // expedition transfer on the next pulse.
            c.host_peer = false;
            c.phase = 4;
            error = "colonization_treasury_transfer_pending";
            return false;
        }
        const godot::PackedInt32Array packed_ids = [&]() {
            godot::PackedInt32Array out; out.resize(1); out.set(0, c.good); return out;
        }();
        const godot::PackedInt64Array packed_qty = [&]() {
            godot::PackedInt64Array out; out.resize(1); out.set(0, c.quantity); return out;
        }();
        const godot::Dictionary begun = _country_runtime->begin_economy_treasury_spend(
            static_cast<int64_t>(family_expeditions_store().country_handle[c.expedition]),
            packed_ids, packed_qty, 0, _epoch_id, static_cast<int32_t>(_stage));
        if (!static_cast<bool>(begun.get("ok", false))) {
            c.active = false;
            error = godot::String(begun.get(
                "code", "colonization_treasury_transfer_rejected")).utf8().get_data();
            return false;
        }
        c.transaction_id = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("transaction_id", 0)));
        c.session_epoch = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("session_epoch", 0)));
        c.country_generation = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("country_generation", 0)));
        c.peer_generation = _committed_generation;
        const godot::Dictionary prepared =
            _country_runtime->acknowledge_economy_asset_peer_prepared(
                c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation, true, godot::String());
        if (!static_cast<bool>(prepared.get("ok", false))) {
            c.active = false; error = "colonization_treasury_transfer_prepare_failed";
            return false;
        }
        const godot::Dictionary committed =
            _country_runtime->commit_economy_asset_transaction(c.transaction_id);
        if (!static_cast<bool>(committed.get("ok", false))) {
            c.active = false; error = "colonization_treasury_transfer_commit_failed";
            return false;
        }
        const godot::Dictionary applied =
            _country_runtime->acknowledge_economy_asset_peer_applied(
                c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation, true, godot::String());
        if (!static_cast<bool>(applied.get("ok", false)) ||
            godot::String(applied.get("status_name", "")) != "completed") {
            c.active = false; error = "colonization_treasury_transfer_ack_failed";
            return false;
        }
        c.active = false;
        return true;
    }
    if (c.phase == 6) {
        const godot::Dictionary applied =
            _country_runtime->acknowledge_economy_asset_peer_applied(
                c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation, true, godot::String());
        if (!static_cast<bool>(applied.get("ok", false)) ||
            godot::String(applied.get("status_name", "")) != "completed") {
            error = "colonization_treasury_peer_apply_ack_failed";
            return false;
        }
        c.active = false;
        return true;
    }
    if (c.phase == 5) {
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host || !_simulation_host->country_economy_asset_terminal_result(
                c.pending_request_id, terminal)) {
            error = "colonization_treasury_transfer_pending";
            return false;
        }
        if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
            terminal.operation != RuntimeEconomyAssetOperation::TREASURY_SPEND) {
            _simulation_host->acknowledge_country_economy_asset_consumed(
                c.pending_request_id);
            c.active = false;
            error = terminal.reason[0] != '\0' ? terminal.reason.data()
                : "colonization_treasury_transfer_rejected";
            return false;
        }
        if (_simulation_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY)) {
            if (!_simulation_host->finish_worker_country_asset(
                    c.pending_request_id, terminal, error)) {
                return false;
            }
        } else if (!_simulation_host->flush_country_economy_asset_commits(
                       error, c.pending_request_id) ||
                   !_simulation_host->publish_country_worker_snapshot(
                       RUNTIME_DIRTY_COUNTRY_STATE, error)) {
            return false;
        } else {
            _simulation_host->acknowledge_country_economy_asset_consumed(
                c.pending_request_id);
        }
        c.active = false;
        return true;
    }
    error = "colonization_treasury_peer_phase_invalid";
    c.active = false;
    return false;
}

bool NativeEconomyRuntime::start_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &c,
        int32_t expedition, int32_t source_cell, int32_t market,
        int32_t good, uint8_t cargo_flags, int64_t quantity, int64_t cash,
        std::string &error) {
    c = NativeEconomyRuntime::FamilyExpeditionProcurementContinuation{};
    c.active = true;
    c.phase = 1;
    c.expedition = expedition;
    c.source_cell = source_cell;
    c.market = market;
    c.good = good;
    c.cargo_flags = cargo_flags;
    c.quantity = quantity;
    c.cash = cash;
    c.started_day = std::max<int64_t>(0, _current_day);
    if (_merchant_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t edge = _merchant_offsets[source_cell];
             edge < _merchant_offsets[source_cell + 1]; ++edge) {
            const int32_t slot = _merchant_slots[edge];
            if (is_merchant_slot(slot) && slot >= 0 &&
                slot < static_cast<int32_t>(population_store().population.size()) &&
                population_store().population[slot] > 0)
                c.living_merchants.push_back(slot);
        }
    }
    if (cash > 0 && c.living_merchants.empty()) {
        error = "country_treasury_peer_merchant_missing";
        c.active = false;
        return false;
    }
    for (int32_t slot : c.living_merchants)
        c.merchant_population = saturating_add(
            c.merchant_population, population_store().population[slot],
            _saturation_count);
    std::vector<int32_t> ids{good};
    std::vector<int64_t> goods{quantity};
    const auto route = block_or_enqueue_country_worker_asset(
        static_cast<uint16_t>(NativeCountryRuntime::ECONOMY_ASSET_GOOD_FROM_MARKET),
        static_cast<uint64_t>(family_expeditions_store().country_handle[expedition]),
        cash, quantity, ids, goods, error, &c.pending_request_id, market);
    if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
        error = "colonization_treasury_peer_pending";
        c.host_peer = true;
        return false;
    }
    if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
        c.active = false;
        return false;
    }
    const godot::Dictionary begun = _country_runtime->begin_economy_good_from_market(
        static_cast<int64_t>(family_expeditions_store().country_handle[expedition]),
        good, quantity, _epoch_id, static_cast<int32_t>(_stage), 0, cash);
    if (!static_cast<bool>(begun.get("ok", false))) {
        error = godot::String(begun.get(
            "code", "colonization_treasury_peer_country_rejected")).utf8().get_data();
        c.active = false;
        return false;
    }
    c.transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("transaction_id", 0)));
    c.session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("session_epoch", 0)));
    c.country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("country_generation", 0)));
    c.peer_generation = _committed_generation;
    const int64_t prepared_quantity = static_cast<int64_t>(
        begun.get("prepared_quantity", 0));
    if (c.transaction_id == 0 || c.session_epoch == 0 ||
        c.country_generation == 0 || c.peer_generation == 0 ||
        prepared_quantity != quantity) {
        error = "colonization_treasury_peer_identity_invalid";
        c.active = false;
        return false;
    }
    const godot::Dictionary prepared =
        _country_runtime->acknowledge_economy_asset_peer_prepared(
            c.transaction_id, c.session_epoch, c.country_generation,
            c.peer_generation, true, godot::String());
    if (!static_cast<bool>(prepared.get("ok", false))) {
        error = "colonization_treasury_peer_prepare_failed";
        c.active = false;
        return false;
    }
    const godot::Dictionary committed =
        _country_runtime->commit_economy_asset_transaction(c.transaction_id);
    if (!static_cast<bool>(committed.get("ok", false)) ||
        static_cast<int64_t>(committed.get("committed_quantity", 0)) != quantity ||
        static_cast<int64_t>(committed.get("committed_cash", cash)) != cash) {
        error = "colonization_treasury_peer_commit_failed";
        c.active = false;
        return false;
    }
    c.host_peer = false;
    c.phase = 4;
    return advance_family_expedition_procurement(c, error);
}

bool NativeEconomyRuntime::settle_family_expedition_kit(
        int32_t expedition, int32_t destination_cell, std::string &error) {
    if (!restore_family_expedition_cargo(expedition, destination_cell, true,
            error))
        return false;
    const uint32_t count = family_expeditions_store().kit_building_count[expedition];
    const uint32_t begin = family_expeditions_store().kit_building_begin[expedition];
    const uint32_t end = begin + count;
    if (end > family_expedition_kit_buildings().size()) {
        error = "colonization_kit_building_range_invalid";
        return false;
    }
    if (count == 0) return true;
    const uint64_t family_handle =
        family_expeditions_store().family_handle[expedition];
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family)) {
        error = "colonization_family_invalid";
        return false;
    }
    int32_t ethnicity = families_store().origin_ethnicity[family];
    if (ethnicity < 0) {
        population_store().for_each_in_cell(destination_cell, [&](int32_t slot) {
            if (ethnicity >= 0) return;
            const int32_t signature =
                static_cast<int32_t>(population_store().signature_id[slot]);
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
            family_expedition_kit_buildings()[i];
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
            buildings_store().group_units[existing] = saturating_add(
                buildings_store().group_units[existing], row.count, _saturation_count);
            _building_handle_index_clean = false;
            if (_modifier_runtime != nullptr &&
                buildings_store().modifier_handle[existing] == 0) {
                buildings_store().modifier_handle[existing] =
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
            append_building_group(group);
            ++_building_structure_new_groups;
            inserted_new_group = true;
        }
        placed.push_back({row.type_id, row.count});
        inserted = true;
    }
    ColonizationKitPlan extra;
    int64_t used_slots = 0;
    for (int32_t group = 0; group < static_cast<int32_t>(building_count());
         ++group) {
        if (buildings_store().cell[group] != destination_cell ||
            buildings_store().group_units[group] <= 0)
            continue;
        const int32_t type_id = buildings_store().type_id[group];
        if (type_id < 0 ||
            type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        used_slots = saturating_add(used_slots, saturating_mul(
            buildings_store().group_units[group],
            std::max<int64_t>(1,
                _building_types[type_id].owner_slots_per_building),
            _saturation_count), _saturation_count);
    }
    const int64_t remaining_slots = std::max<int64_t>(0,
        family_expeditions_store().population[expedition] - used_slots);
    if (remaining_slots > 0 &&
        plan_colonization_kit(destination_cell, destination_cell,
            remaining_slots, 1, true, extra, true) &&
        extra.place_buildings != 0 && !extra.buildings.empty()) {
        bool extra_affordable = true;
        for (const FamilyExpeditionCargoLine &line : extra.cargo) {
            if (line.flags != EXPEDITION_CARGO_CONSTRUCTION ||
                line.quantity <= 0)
                continue;
            if (market_stock(destination_cell, line.good_id) < line.quantity) {
                extra_affordable = false;
                break;
            }
        }
        if (extra_affordable) {
            int64_t extra_construction_consumed = 0;
            for (const FamilyExpeditionCargoLine &line : extra.cargo) {
                if (line.flags != EXPEDITION_CARGO_CONSTRUCTION ||
                    line.quantity <= 0)
                    continue;
                std::string ignored;
                if (adjust_market_stock(destination_cell, line.good_id,
                        -line.quantity, ignored)) {
                    extra_construction_consumed = saturating_add(
                        extra_construction_consumed, line.quantity,
                        _saturation_count);
                }
            }
            if (_epoch_active)
                _construction_goods_consumed = saturating_add(
                    _construction_goods_consumed, extra_construction_consumed,
                    _saturation_count);
            for (const FamilyExpeditionKitBuilding &row : extra.buildings) {
                if (row.type_id < 0 ||
                    row.type_id >= static_cast<int32_t>(_building_types.size()) ||
                    row.count <= 0)
                    continue;
                const BuildingType &type = _building_types[row.type_id];
                const int32_t owner_signature =
                    signature_for_profession_ethnicity(
                        type.owner_profession_id, std::max(0, ethnicity));
                if (owner_signature < 0) continue;
                const int32_t existing = find_building_group(
                    destination_cell, row.type_id, owner_signature);
                if (existing >= 0) {
                    buildings_store().group_units[existing] = saturating_add(
                        buildings_store().group_units[existing], row.count,
                        _saturation_count);
                    _building_handle_index_clean = false;
                    if (_modifier_runtime != nullptr &&
                        buildings_store().modifier_handle[existing] == 0) {
                        buildings_store().modifier_handle[existing] =
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
                    append_building_group(group);
                    ++_building_structure_new_groups;
                    inserted_new_group = true;
                }
                placed.push_back({row.type_id, row.count});
                inserted = true;
            }
        }
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
        int64_t have = owner_slot >= 0 ? population_store().population[owner_slot] : 0;
        int64_t missing = std::max<int64_t>(0, needed - have);
        struct Candidate {
            int32_t slot = -1;
            bool unemployed = false;
            int32_t profession = 0;
            int32_t ethnicity_id = 0;
            uint64_t handle = 0;
        };
        std::vector<Candidate> candidates;
        population_store().for_each_in_cell(destination_cell, [&](int32_t slot) {
            if (population_store().population[slot] <= 0) return;
            const int32_t signature =
                static_cast<int32_t>(population_store().signature_id[slot]);
            if (signature == owner_signature) return;
            if (signature < 0 ||
                signature >= static_cast<int32_t>(_signatures.size()))
                return;
            candidates.push_back({slot,
                _signatures[signature].profession_id ==
                    _unemployed_profession_id,
                _signatures[signature].profession_id,
                _signatures[signature].ethnicity_id,
                population_store().handle_for_slot(slot)});
        });
        std::sort(candidates.begin(), candidates.end(),
            [](const Candidate &a, const Candidate &b) {
                return std::tuple(!a.unemployed, a.profession, a.ethnicity_id,
                    a.handle) <
                    std::tuple(!b.unemployed, b.profession, b.ethnicity_id,
                        b.handle);
            });
        int64_t remaining_merchants = living_merchant_population(destination_cell);
        for (const Candidate &candidate : candidates) {
            if (missing <= 0) break;
            if (candidate.slot < 0 ||
                candidate.slot >= static_cast<int32_t>(population_store().active.size()) ||
                population_store().active[candidate.slot] == 0)
                continue;
            const bool from_merchant = is_merchant_slot(candidate.slot);
            int64_t take = std::min(missing,
                population_store().population[candidate.slot]);
            if (from_merchant)
                take = std::min(take, std::max<int64_t>(0, remaining_merchants - 1));
            if (take <= 0) continue;
            if (!move_cohort_population(candidate.slot, destination_cell,
                    owner_signature, take, error, nullptr, family_handle))
                return false;
            missing -= take;
            if (from_merchant)
                remaining_merchants = std::max<int64_t>(
                    0, remaining_merchants - take);
        }
        owner_slot = find_cohort_slot(destination_cell, owner_signature);
        const int32_t group_index = find_building_group(
            destination_cell, row.first, owner_signature);
        if (group_index >= 0) {
            const int64_t filled = owner_slot >= 0
                ? std::min(needed, population_store().population[owner_slot]) : 0;
            buildings_store().filled_owner[group_index] = filled;
            if (owner_slot >= 0)
                population_store().owner_employed[owner_slot] = std::max(
                    population_store().owner_employed[owner_slot], filled);
            if (buildings_store().modifier_handle[group_index] != 0) {
                bool found = false;
                for (FamilyBuildingOwnership &edge : family_ownerships()) {
                    if (edge.family_handle == family_handle &&
                        edge.building_handle ==
                            buildings_store().modifier_handle[group_index]) {
                        edge.owned_count = saturating_add(
                            edge.owned_count, row.second, _saturation_count);
                        edge.filled_owner = std::max(edge.filled_owner,
                            filled);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    family_ownerships().push_back({family_handle,
                        buildings_store().modifier_handle[group_index], row.second,
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
