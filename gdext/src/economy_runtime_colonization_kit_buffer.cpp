#include "economy_runtime_colonization_kit_includes.inc"

namespace pk {

void NativeEconomyRuntime::fill_colonization_kit_buffer(
        int32_t source_cell, int32_t target_cell, int64_t population,
        int32_t travel_days, ColonizationKitPlan &kit,
        const ColonizationReserveContext *reserve,
        int32_t bridge_days_override) const {
    if (population <= 0 || source_cell < 0 || source_cell >= _cell_count.get())
        return;
    const int32_t market = market_store().cell_to_market[source_cell];
    if (market < 0 || market >= market_store().market_count.get()) return;
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
        if (good < 0 || good >= market_store().good_count.get()) return 0;
        const int64_t stock = std::max<int64_t>(0,
            market_store().stock[market_store().index(market, good)]);
        const int64_t held = reserve == nullptr ? 0
            : extra_stock(reserve->reserved, good);
        return stock + held;
    };
    kit.source_stock_identity = 1469598103934665603ULL;
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
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
        if (good < 0 || good >= market_store().good_count.get()) return 0;
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
        const bool has_stock = good >= 0 && good < market_store().good_count.get() &&
            spare_stock(good) > 0;
        if (good < 0 || numerator <= 0 || denominator <= 0 ||
            (!has_stock && !good_production_available(source_cell, good, false)))
            return;
        for (const BufferCandidate &candidate : candidates)
            if (candidate.good_id == good) return;
        candidates.push_back({good, numerator, denominator});
    };
    auto fill_group = [&](int64_t required,
                          std::vector<BufferCandidate> candidates,
                          bool required_for_launch = true) {
        int64_t remaining = std::max<int64_t>(0, required);
        if (required_for_launch)
            kit.bridge_required_units = saturating_add(kit.bridge_required_units,
                remaining, sat);
        // A bridge with no reachable candidate can never make progress.  This
        // used to leave PREPARING expeditions retrying forever at (for example)
        // 96% food even though the source had neither stock nor a producer for
        // any survival good.  Keep temporary stock shortages retryable; only
        // an empty candidate set is structurally unbuildable.
        if (required_for_launch && remaining > 0 && candidates.empty())
            kit.kit_unbuildable = 1;
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
        if (remaining > 0 && reserve != nullptr && reserve->forecast_missing &&
            !candidates.empty()) {
            const BufferCandidate &candidate = candidates.front();
            int64_t physical = mul_div_sat(remaining, candidate.contribution_denominator,
                candidate.contribution_numerator, sat);
            if (mul_div_sat(physical, candidate.contribution_numerator,
                    candidate.contribution_denominator, sat) < remaining)
                physical = saturating_add(physical, 1, sat);
            add_colonization_kit_cargo(kit, candidate.good_id, physical,
                EXPEDITION_CARGO_BUFFER, sat);
        }
        if (remaining <= 0 || !required_for_launch) return;
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
                    // A tool the source country has not unlocked is not
                    // part of the kit, even when the market holds stock.
                    if (!good_production_available(source_cell,
                            candidate.good_id, false)) continue;
                    add_candidate(candidates, candidate.good_id,
                        std::max<int32_t>(1, candidate.efficiency_q16), Q16_ONE);
                }
            }
            // Soft production inputs improve yield but are not required to
            // operate the camp. Buy what is available without making the
            // missing remainder a departure gate, even after tools unlock.
            fill_group(wanted, candidates, item.required_q16 >= Q16_ONE);
        }
    }
    std::sort(kit.missing_good_ids.begin(), kit.missing_good_ids.end());
    kit.missing_good_ids.erase(std::unique(kit.missing_good_ids.begin(),
        kit.missing_good_ids.end()), kit.missing_good_ids.end());
}

} // namespace pk
