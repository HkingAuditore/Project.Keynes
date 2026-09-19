#include "runtime_economy_family_store.h"

#include <cstring>

namespace pk {
namespace {

constexpr uint64_t kFnvOffset = 1469598103934665603ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

template <typename T>
void append_pod(std::vector<uint8_t> &out, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), bytes, bytes + sizeof(T));
}

template <typename T>
bool read_pod(const uint8_t *&p, const uint8_t *end, T &value) {
    if (static_cast<size_t>(end - p) < sizeof(T)) return false;
    std::memcpy(&value, p, sizeof(T));
    p += sizeof(T);
    return true;
}

template <typename T>
bool column_size(const std::vector<T> &column, size_t expected) {
    return column.size() == expected;
}

} // namespace

void RuntimeEconomyFamilyStore::clear() noexcept {
    family_slot.clear();
    family_active.clear();
    family_generation.clear();
    family_stable_id.clear();
    family_surname_id.clear();
    family_surname_disambiguator.clear();
    family_founded_day.clear();
    family_home_cell.clear();
    family_origin_cell.clear();
    family_origin_ethnicity.clear();
    family_culture_group_id.clear();
    family_split_sequence.clear();
    family_decline_reviews.clear();
    family_flags.clear();
    purchase_factor_q16.clear();
    membership_family_handle.clear();
    membership_cohort_handle.clear();
    membership_people.clear();
    membership_cash_claim.clear();
    membership_population_basis.clear();
    membership_funds_basis.clear();
    membership_owner_employed.clear();
    membership_employee_employed.clear();
    ownership_family_handle.clear();
    ownership_building_handle.clear();
    ownership_owned_count.clear();
    ownership_filled_owner.clear();
    person_slot.clear();
    person_active.clear();
    person_generation.clear();
    person_stable_id.clear();
    person_family_handle.clear();
    person_cohort_handle.clear();
    person_given_name_id.clear();
    person_name_disambiguator.clear();
    person_notable_since_day.clear();
    person_flags.clear();
    person_cash_claim.clear();
    person_family_equity_share_q32.clear();
    person_epoch_job_income.clear();
    person_epoch_business_result.clear();
    person_epoch_consumption_expense.clear();
    person_epoch_tax.clear();
    person_income_ema.clear();
    person_needs_satisfaction.clear();
    person_worst_need_id.clear();
    person_building_handle.clear();
    person_job_kind.clear();
    person_employee_role_index.clear();
    person_job_since_day.clear();
    need_person_handle.clear();
    need_stable_need_id.clear();
    need_desired_period_units.clear();
    need_satisfaction_q16.clear();
    need_attributed_spend.clear();
    trait_family_handle.clear();
    trait_trait_id.clear();
    trait_strength_q16.clear();
    trait_core.clear();
    influence_slot.clear();
    influence_active.clear();
    influence_generation.clear();
    influence_family_handle.clear();
    influence_cell.clear();
    influence_stable_id.clear();
    influence_population.clear();
    influence_cash.clear();
    influence_building_asset.clear();
    influence_population_share_q16.clear();
    influence_cash_share_q16.clear();
    influence_building_share_q16.clear();
    influence_score_q16.clear();
    influence_satisfaction_q16.clear();
    influence_prestige_level.clear();
    influence_pending_target_level.clear();
    influence_review_streak.clear();
    influence_last_review_day.clear();
    command_operation.clear();
    command_family_handle.clear();
    command_trait_id.clear();
    command_strength_q16.clear();
    command_effective_day.clear();
    command_priority.clear();
    command_sequence.clear();
    command_submit_order.clear();
    expedition_slot.clear();
    expedition_active.clear();
    expedition_generation.clear();
    expedition_stable_id.clear();
    expedition_country_handle.clear();
    expedition_family_handle.clear();
    expedition_source_cell.clear();
    expedition_target_cell.clear();
    expedition_departure_day.clear();
    expedition_due_day.clear();
    expedition_route_cost.clear();
    expedition_speed.clear();
    expedition_state.clear();
    expedition_population.clear();
    expedition_effect_transaction_id.clear();
    expedition_idempotency_key.clear();
    expedition_route_count.clear();
    expedition_route_begin.clear();
    expedition_payload_count.clear();
    expedition_payload_begin.clear();
    expedition_cargo_count.clear();
    expedition_cargo_begin.clear();
    expedition_kit_count.clear();
    expedition_kit_begin.clear();
    expedition_missing_identity.clear();
    expedition_missing_count.clear();
    expedition_missing_begin.clear();
    route_cell.clear();
    route_cost.clear();
    payload_source_cohort_handle.clear();
    payload_signature.clear();
    payload_people.clear();
    payload_funds.clear();
    payload_epoch_income.clear();
    payload_epoch_expense.clear();
    payload_epoch_in_kind_income.clear();
    payload_income_ema.clear();
    payload_epoch_tax_paid.clear();
    payload_epoch_subsidy_received.clear();
    payload_income_baseline_ema.clear();
    payload_demography_residual.clear();
    payload_cash_claim.clear();
    payload_owner_employed.clear();
    payload_employee_employed.clear();
    payload_needs_satisfaction.clear();
    payload_worst_need_id.clear();
    payload_composite_satisfaction.clear();
    payload_worst_dimension_id.clear();
    payload_satisfaction_dims.clear();
    payload_person_count.clear();
    payload_person_begin.clear();
    payload_person_handle.clear();
    cargo_good_id.clear();
    cargo_quantity.clear();
    cargo_flags.clear();
    kit_type_id.clear();
    kit_count.clear();
    missing_good_id.clear();
    missing_quantity.clear();
}

bool RuntimeEconomyFamilyStore::shape_valid(
        uint32_t family_count, uint32_t membership_count,
        uint32_t ownership_count, uint32_t person_count,
        uint32_t person_need_count, uint32_t trait_count,
        uint32_t influence_count, uint32_t trait_command_count,
        uint32_t expedition_count) const noexcept {
    const size_t families = static_cast<size_t>(family_count);
    const size_t memberships = static_cast<size_t>(membership_count);
    const size_t ownerships = static_cast<size_t>(ownership_count);
    const size_t persons = static_cast<size_t>(person_count);
    const size_t person_needs = static_cast<size_t>(person_need_count);
    const size_t traits = static_cast<size_t>(trait_count);
    const size_t influences = static_cast<size_t>(influence_count);
    const size_t trait_commands = static_cast<size_t>(trait_command_count);
    const size_t expeditions = static_cast<size_t>(expedition_count);

    if (!(column_size(family_slot, families) &&
          column_size(family_active, families) &&
          column_size(family_generation, families) &&
          column_size(family_stable_id, families) &&
          column_size(family_surname_id, families) &&
          column_size(family_surname_disambiguator, families) &&
          column_size(family_founded_day, families) &&
          column_size(family_home_cell, families) &&
          column_size(family_origin_cell, families) &&
          column_size(family_origin_ethnicity, families) &&
          column_size(family_culture_group_id, families) &&
          column_size(family_split_sequence, families) &&
          column_size(family_decline_reviews, families) &&
          column_size(family_flags, families))) {
        return false;
    }
    if (!(column_size(membership_family_handle, memberships) &&
          column_size(membership_cohort_handle, memberships) &&
          column_size(membership_people, memberships) &&
          column_size(membership_cash_claim, memberships) &&
          column_size(membership_population_basis, memberships) &&
          column_size(membership_funds_basis, memberships) &&
          column_size(membership_owner_employed, memberships) &&
          column_size(membership_employee_employed, memberships))) {
        return false;
    }
    if (!(column_size(ownership_family_handle, ownerships) &&
          column_size(ownership_building_handle, ownerships) &&
          column_size(ownership_owned_count, ownerships) &&
          column_size(ownership_filled_owner, ownerships))) {
        return false;
    }
    if (!(column_size(person_slot, persons) && column_size(person_active, persons) &&
          column_size(person_generation, persons) &&
          column_size(person_stable_id, persons) &&
          column_size(person_family_handle, persons) &&
          column_size(person_cohort_handle, persons) &&
          column_size(person_given_name_id, persons) &&
          column_size(person_name_disambiguator, persons) &&
          column_size(person_notable_since_day, persons) &&
          column_size(person_flags, persons) &&
          column_size(person_cash_claim, persons) &&
          column_size(person_family_equity_share_q32, persons) &&
          column_size(person_epoch_job_income, persons) &&
          column_size(person_epoch_business_result, persons) &&
          column_size(person_epoch_consumption_expense, persons) &&
          column_size(person_epoch_tax, persons) &&
          column_size(person_income_ema, persons) &&
          column_size(person_needs_satisfaction, persons) &&
          column_size(person_worst_need_id, persons) &&
          column_size(person_building_handle, persons) &&
          column_size(person_job_kind, persons) &&
          column_size(person_employee_role_index, persons) &&
          column_size(person_job_since_day, persons))) {
        return false;
    }
    if (!(column_size(need_person_handle, person_needs) &&
          column_size(need_stable_need_id, person_needs) &&
          column_size(need_desired_period_units, person_needs) &&
          column_size(need_satisfaction_q16, person_needs) &&
          column_size(need_attributed_spend, person_needs))) {
        return false;
    }
    if (!(column_size(trait_family_handle, traits) &&
          column_size(trait_trait_id, traits) &&
          column_size(trait_strength_q16, traits) &&
          column_size(trait_core, traits))) {
        return false;
    }
    if (!(column_size(influence_slot, influences) &&
          column_size(influence_active, influences) &&
          column_size(influence_generation, influences) &&
          column_size(influence_family_handle, influences) &&
          column_size(influence_cell, influences) &&
          column_size(influence_stable_id, influences) &&
          column_size(influence_population, influences) &&
          column_size(influence_cash, influences) &&
          column_size(influence_building_asset, influences) &&
          column_size(influence_population_share_q16, influences) &&
          column_size(influence_cash_share_q16, influences) &&
          column_size(influence_building_share_q16, influences) &&
          column_size(influence_score_q16, influences) &&
          column_size(influence_satisfaction_q16, influences) &&
          column_size(influence_prestige_level, influences) &&
          column_size(influence_pending_target_level, influences) &&
          column_size(influence_review_streak, influences) &&
          column_size(influence_last_review_day, influences))) {
        return false;
    }
    if (!(column_size(command_operation, trait_commands) &&
          column_size(command_family_handle, trait_commands) &&
          column_size(command_trait_id, trait_commands) &&
          column_size(command_strength_q16, trait_commands) &&
          column_size(command_effective_day, trait_commands) &&
          column_size(command_priority, trait_commands) &&
          column_size(command_sequence, trait_commands) &&
          column_size(command_submit_order, trait_commands))) {
        return false;
    }
    if (!(column_size(expedition_slot, expeditions) &&
          column_size(expedition_active, expeditions) &&
          column_size(expedition_generation, expeditions) &&
          column_size(expedition_stable_id, expeditions) &&
          column_size(expedition_country_handle, expeditions) &&
          column_size(expedition_family_handle, expeditions) &&
          column_size(expedition_source_cell, expeditions) &&
          column_size(expedition_target_cell, expeditions) &&
          column_size(expedition_departure_day, expeditions) &&
          column_size(expedition_due_day, expeditions) &&
          column_size(expedition_route_cost, expeditions) &&
          column_size(expedition_speed, expeditions) &&
          column_size(expedition_state, expeditions) &&
          column_size(expedition_population, expeditions) &&
          column_size(expedition_effect_transaction_id, expeditions) &&
          column_size(expedition_idempotency_key, expeditions) &&
          column_size(expedition_route_count, expeditions) &&
          column_size(expedition_route_begin, expeditions) &&
          column_size(expedition_payload_count, expeditions) &&
          column_size(expedition_payload_begin, expeditions) &&
          column_size(expedition_cargo_count, expeditions) &&
          column_size(expedition_cargo_begin, expeditions) &&
          column_size(expedition_kit_count, expeditions) &&
          column_size(expedition_kit_begin, expeditions) &&
          column_size(expedition_missing_identity, expeditions) &&
          column_size(expedition_missing_count, expeditions) &&
          column_size(expedition_missing_begin, expeditions))) {
        return false;
    }

    const size_t routes = route_cell.size();
    if (!column_size(route_cost, routes)) return false;
    const size_t payloads = payload_source_cohort_handle.size();
    if (!(column_size(payload_signature, payloads) &&
          column_size(payload_people, payloads) &&
          column_size(payload_funds, payloads) &&
          column_size(payload_epoch_income, payloads) &&
          column_size(payload_epoch_expense, payloads) &&
          column_size(payload_epoch_in_kind_income, payloads) &&
          column_size(payload_income_ema, payloads) &&
          column_size(payload_epoch_tax_paid, payloads) &&
          column_size(payload_epoch_subsidy_received, payloads) &&
          column_size(payload_income_baseline_ema, payloads) &&
          column_size(payload_demography_residual, payloads) &&
          column_size(payload_cash_claim, payloads) &&
          column_size(payload_owner_employed, payloads) &&
          column_size(payload_employee_employed, payloads) &&
          column_size(payload_needs_satisfaction, payloads) &&
          column_size(payload_worst_need_id, payloads) &&
          column_size(payload_composite_satisfaction, payloads) &&
          column_size(payload_worst_dimension_id, payloads) &&
          column_size(payload_person_count, payloads) &&
          column_size(payload_person_begin, payloads) &&
          column_size(payload_satisfaction_dims,
                       payloads * static_cast<size_t>(kSatDimCount)))) {
        return false;
    }
    const size_t payload_persons = payload_person_handle.size();
    const size_t cargo_lines = cargo_good_id.size();
    if (!(column_size(cargo_quantity, cargo_lines) &&
          column_size(cargo_flags, cargo_lines))) {
        return false;
    }
    const size_t kit_buildings = kit_type_id.size();
    if (!column_size(kit_count, kit_buildings)) return false;
    const size_t missing_goods = missing_good_id.size();
    if (!column_size(missing_quantity, missing_goods)) return false;

    uint32_t route_sum = 0;
    uint32_t payload_sum = 0;
    uint32_t cargo_sum = 0;
    uint32_t kit_sum = 0;
    uint32_t missing_sum = 0;
    uint32_t payload_person_sum = 0;
    for (size_t i = 0; i < expeditions; ++i) {
        if (expedition_route_begin[i] != route_sum) return false;
        if (expedition_payload_begin[i] != payload_sum) return false;
        if (expedition_cargo_begin[i] != cargo_sum) return false;
        if (expedition_kit_begin[i] != kit_sum) return false;
        if (expedition_missing_begin[i] != missing_sum) return false;
        route_sum += expedition_route_count[i];
        payload_sum += expedition_payload_count[i];
        cargo_sum += expedition_cargo_count[i];
        kit_sum += expedition_kit_count[i];
        missing_sum += expedition_missing_count[i];
    }
    if (route_sum != static_cast<uint32_t>(routes) ||
        payload_sum != static_cast<uint32_t>(payloads) ||
        cargo_sum != static_cast<uint32_t>(cargo_lines) ||
        kit_sum != static_cast<uint32_t>(kit_buildings) ||
        missing_sum != static_cast<uint32_t>(missing_goods)) {
        return false;
    }
    for (size_t p = 0; p < payloads; ++p) {
        if (payload_person_begin[p] != payload_person_sum) return false;
        payload_person_sum += payload_person_count[p];
    }
    return payload_person_sum == static_cast<uint32_t>(payload_persons);
}

void RuntimeEconomyFamilyStore::append_wire(std::vector<uint8_t> &out) const {
    const size_t families = family_slot.size();
    for (size_t i = 0; i < families; ++i) {
        append_pod(out, family_slot[i]);
        append_pod(out, family_active[i]);
        append_pod(out, family_generation[i]);
        append_pod(out, family_stable_id[i]);
        append_pod(out, family_surname_id[i]);
        append_pod(out, family_surname_disambiguator[i]);
        append_pod(out, family_founded_day[i]);
        append_pod(out, family_home_cell[i]);
        append_pod(out, family_origin_cell[i]);
        append_pod(out, family_origin_ethnicity[i]);
        append_pod(out, family_culture_group_id[i]);
        append_pod(out, family_split_sequence[i]);
        append_pod(out, family_decline_reviews[i]);
        append_pod(out, family_flags[i]);
    }
    const size_t memberships = membership_family_handle.size();
    for (size_t i = 0; i < memberships; ++i) {
        append_pod(out, membership_family_handle[i]);
        append_pod(out, membership_cohort_handle[i]);
        append_pod(out, membership_people[i]);
        append_pod(out, membership_cash_claim[i]);
        append_pod(out, membership_population_basis[i]);
        append_pod(out, membership_funds_basis[i]);
        append_pod(out, membership_owner_employed[i]);
        append_pod(out, membership_employee_employed[i]);
    }
    const size_t ownerships = ownership_family_handle.size();
    for (size_t i = 0; i < ownerships; ++i) {
        append_pod(out, ownership_family_handle[i]);
        append_pod(out, ownership_building_handle[i]);
        append_pod(out, ownership_owned_count[i]);
        append_pod(out, ownership_filled_owner[i]);
    }
    const size_t persons = person_slot.size();
    for (size_t i = 0; i < persons; ++i) {
        append_pod(out, person_slot[i]);
        append_pod(out, person_active[i]);
        append_pod(out, person_generation[i]);
        append_pod(out, person_stable_id[i]);
        append_pod(out, person_family_handle[i]);
        append_pod(out, person_cohort_handle[i]);
        append_pod(out, person_given_name_id[i]);
        append_pod(out, person_name_disambiguator[i]);
        append_pod(out, person_notable_since_day[i]);
        append_pod(out, person_flags[i]);
        append_pod(out, person_cash_claim[i]);
        append_pod(out, person_family_equity_share_q32[i]);
        append_pod(out, person_epoch_job_income[i]);
        append_pod(out, person_epoch_business_result[i]);
        append_pod(out, person_epoch_consumption_expense[i]);
        append_pod(out, person_epoch_tax[i]);
        append_pod(out, person_income_ema[i]);
        append_pod(out, person_needs_satisfaction[i]);
        append_pod(out, person_worst_need_id[i]);
        append_pod(out, person_building_handle[i]);
        append_pod(out, person_job_kind[i]);
        append_pod(out, person_employee_role_index[i]);
        append_pod(out, person_job_since_day[i]);
    }
    const size_t person_needs = need_person_handle.size();
    for (size_t i = 0; i < person_needs; ++i) {
        append_pod(out, need_person_handle[i]);
        append_pod(out, need_stable_need_id[i]);
        append_pod(out, need_desired_period_units[i]);
        append_pod(out, need_satisfaction_q16[i]);
        append_pod(out, need_attributed_spend[i]);
    }
    const size_t traits = trait_family_handle.size();
    for (size_t i = 0; i < traits; ++i) {
        append_pod(out, trait_family_handle[i]);
        append_pod(out, trait_trait_id[i]);
        append_pod(out, trait_strength_q16[i]);
        append_pod(out, trait_core[i]);
    }
    const size_t influences = influence_slot.size();
    for (size_t i = 0; i < influences; ++i) {
        append_pod(out, influence_slot[i]);
        append_pod(out, influence_active[i]);
        append_pod(out, influence_generation[i]);
        append_pod(out, influence_family_handle[i]);
        append_pod(out, influence_cell[i]);
        append_pod(out, influence_stable_id[i]);
        append_pod(out, influence_population[i]);
        append_pod(out, influence_cash[i]);
        append_pod(out, influence_building_asset[i]);
        append_pod(out, influence_population_share_q16[i]);
        append_pod(out, influence_cash_share_q16[i]);
        append_pod(out, influence_building_share_q16[i]);
        append_pod(out, influence_score_q16[i]);
        append_pod(out, influence_satisfaction_q16[i]);
        append_pod(out, influence_prestige_level[i]);
        append_pod(out, influence_pending_target_level[i]);
        append_pod(out, influence_review_streak[i]);
        append_pod(out, influence_last_review_day[i]);
    }
    const size_t trait_commands = command_operation.size();
    for (size_t i = 0; i < trait_commands; ++i) {
        append_pod(out, command_operation[i]);
        append_pod(out, command_family_handle[i]);
        append_pod(out, command_trait_id[i]);
        append_pod(out, command_strength_q16[i]);
        append_pod(out, command_effective_day[i]);
        append_pod(out, command_priority[i]);
        append_pod(out, command_sequence[i]);
        append_pod(out, command_submit_order[i]);
    }
    const size_t expeditions = expedition_slot.size();
    for (size_t i = 0; i < expeditions; ++i) {
        append_pod(out, expedition_slot[i]);
        append_pod(out, expedition_active[i]);
        append_pod(out, expedition_generation[i]);
        append_pod(out, expedition_stable_id[i]);
        append_pod(out, expedition_country_handle[i]);
        append_pod(out, expedition_family_handle[i]);
        append_pod(out, expedition_source_cell[i]);
        append_pod(out, expedition_target_cell[i]);
        append_pod(out, expedition_departure_day[i]);
        append_pod(out, expedition_due_day[i]);
        append_pod(out, expedition_route_cost[i]);
        append_pod(out, expedition_speed[i]);
        append_pod(out, expedition_state[i]);
        append_pod(out, expedition_population[i]);
        append_pod(out, expedition_effect_transaction_id[i]);
        append_pod(out, expedition_idempotency_key[i]);
        const uint32_t route_count =
            expedition_active[i] != 0 ? expedition_route_count[i] : 0;
        const uint32_t payload_count =
            expedition_active[i] != 0 ? expedition_payload_count[i] : 0;
        append_pod(out, route_count);
        append_pod(out, payload_count);
        const uint32_t route_begin = expedition_route_begin[i];
        for (uint32_t r = 0; r < route_count; ++r) {
            const size_t index = static_cast<size_t>(route_begin + r);
            append_pod(out, route_cell[index]);
            append_pod(out, route_cost[index]);
        }
        const uint32_t payload_begin = expedition_payload_begin[i];
        for (uint32_t p = 0; p < payload_count; ++p) {
            const size_t index = static_cast<size_t>(payload_begin + p);
            append_pod(out, payload_source_cohort_handle[index]);
            append_pod(out, payload_signature[index]);
            append_pod(out, payload_people[index]);
            append_pod(out, payload_funds[index]);
            append_pod(out, payload_epoch_income[index]);
            append_pod(out, payload_epoch_expense[index]);
            append_pod(out, payload_epoch_in_kind_income[index]);
            append_pod(out, payload_income_ema[index]);
            append_pod(out, payload_epoch_tax_paid[index]);
            append_pod(out, payload_epoch_subsidy_received[index]);
            append_pod(out, payload_income_baseline_ema[index]);
            append_pod(out, payload_demography_residual[index]);
            append_pod(out, payload_cash_claim[index]);
            append_pod(out, payload_owner_employed[index]);
            append_pod(out, payload_employee_employed[index]);
            append_pod(out, payload_needs_satisfaction[index]);
            append_pod(out, payload_worst_need_id[index]);
            append_pod(out, payload_composite_satisfaction[index]);
            append_pod(out, payload_worst_dimension_id[index]);
            const size_t dim_base =
                index * static_cast<size_t>(kSatDimCount);
            for (int32_t dim = 0; dim < kSatDimCount; ++dim) {
                append_pod(out, payload_satisfaction_dims[dim_base + dim]);
            }
            append_pod(out, payload_person_count[index]);
            const uint32_t person_begin = payload_person_begin[index];
            const uint32_t person_count = payload_person_count[index];
            for (uint32_t person = 0; person < person_count; ++person) {
                append_pod(out,
                           payload_person_handle[person_begin + person]);
            }
        }
        const uint32_t cargo_count =
            expedition_active[i] != 0 ? expedition_cargo_count[i] : 0;
        const uint32_t kit_lane_count =
            expedition_active[i] != 0 ? expedition_kit_count[i] : 0;
        append_pod(out, cargo_count);
        const uint32_t cargo_begin = expedition_cargo_begin[i];
        for (uint32_t c = 0; c < cargo_count; ++c) {
            const size_t index = static_cast<size_t>(cargo_begin + c);
            append_pod(out, cargo_good_id[index]);
            append_pod(out, cargo_quantity[index]);
            append_pod(out, cargo_flags[index]);
        }
        append_pod(out, kit_lane_count);
        const uint32_t kit_begin = expedition_kit_begin[i];
        for (uint32_t k = 0; k < kit_lane_count; ++k) {
            const size_t index = static_cast<size_t>(kit_begin + k);
            append_pod(out, kit_type_id[index]);
            append_pod(out, kit_count[index]);
        }
        uint64_t missing_identity = 0;
        uint32_t missing_count = 0;
        uint32_t missing_begin = 0;
        if (expedition_active[i] != 0) {
            missing_identity = expedition_missing_identity[i];
            missing_count = expedition_missing_count[i];
            missing_begin = expedition_missing_begin[i];
        }
        append_pod(out, missing_identity);
        append_pod(out, missing_count);
        for (uint32_t m = 0; m < missing_count; ++m) {
            append_pod(out, missing_good_id[missing_begin + m]);
            append_pod(out, missing_quantity[missing_begin + m]);
        }
    }
}

bool RuntimeEconomyFamilyStore::load_wire(
        const uint8_t *data, size_t size, uint32_t family_count,
        uint32_t membership_count, uint32_t ownership_count,
        uint32_t person_count, uint32_t person_need_count,
        uint32_t trait_count, uint32_t influence_count,
        uint32_t trait_command_count, uint32_t expedition_count) {
    clear();
    if (data == nullptr && size != 0) return false;
    const uint8_t *p = data;
    const uint8_t *end = data + size;

    family_slot.reserve(family_count);
    for (uint32_t i = 0; i < family_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        int64_t v_i64 = 0;
        uint16_t v_u16 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        family_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        family_generation.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        family_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_surname_id.push_back(v_i32);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        family_surname_disambiguator.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        family_founded_day.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_home_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_origin_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_origin_ethnicity.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        family_culture_group_id.push_back(v_i32);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        family_split_sequence.push_back(v_u32);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        family_decline_reviews.push_back(v_u16);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        family_flags.push_back(v_u16);
    }

    membership_family_handle.reserve(membership_count);
    for (uint32_t i = 0; i < membership_count; ++i) {
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        membership_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        membership_cohort_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_people.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_cash_claim.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_population_basis.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_funds_basis.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_owner_employed.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        membership_employee_employed.push_back(v_i64);
    }

    ownership_family_handle.reserve(ownership_count);
    for (uint32_t i = 0; i < ownership_count; ++i) {
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        ownership_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        ownership_building_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        ownership_owned_count.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        ownership_filled_owner.push_back(v_i64);
    }

    person_slot.reserve(person_count);
    for (uint32_t i = 0; i < person_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        int64_t v_i64 = 0;
        uint64_t v_u64 = 0;
        uint16_t v_u16 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        person_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        person_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        person_generation.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        person_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        person_cohort_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        person_given_name_id.push_back(v_i32);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        person_name_disambiguator.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_notable_since_day.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        person_flags.push_back(v_u16);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_cash_claim.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_family_equity_share_q32.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_job_income.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_business_result.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_consumption_expense.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_epoch_tax.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_income_ema.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        person_needs_satisfaction.push_back(v_u16);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        person_worst_need_id.push_back(v_u16);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        person_building_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        person_job_kind.push_back(v_u8);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        person_employee_role_index.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        person_job_since_day.push_back(v_i64);
    }

    need_person_handle.reserve(person_need_count);
    for (uint32_t i = 0; i < person_need_count; ++i) {
        uint64_t v_u64 = 0;
        int32_t v_i32 = 0;
        int64_t v_i64 = 0;
        uint16_t v_u16 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        need_person_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        need_stable_need_id.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        need_desired_period_units.push_back(v_i64);
        if (!read_pod(p, end, v_u16)) {
            clear();
            return false;
        }
        need_satisfaction_q16.push_back(v_u16);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        need_attributed_spend.push_back(v_i64);
    }

    trait_family_handle.reserve(trait_count);
    for (uint32_t i = 0; i < trait_count; ++i) {
        uint64_t v_u64 = 0;
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        trait_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        trait_trait_id.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        trait_strength_q16.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        trait_core.push_back(v_u8);
    }

    influence_slot.reserve(influence_count);
    for (uint32_t i = 0; i < influence_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        influence_generation.push_back(v_u32);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        influence_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_population.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_cash.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_building_asset.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_population_share_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_cash_share_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_building_share_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_score_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        influence_satisfaction_q16.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_prestige_level.push_back(v_u8);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_pending_target_level.push_back(v_u8);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        influence_review_streak.push_back(v_u8);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        influence_last_review_day.push_back(v_i64);
    }

    command_operation.reserve(trait_command_count);
    for (uint32_t i = 0; i < trait_command_count; ++i) {
        int32_t v_i32 = 0;
        uint64_t v_u64 = 0;
        int64_t v_i64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_operation.push_back(v_i32);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        command_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_trait_id.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_strength_q16.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        command_effective_day.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        command_priority.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        command_sequence.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        command_submit_order.push_back(v_u64);
    }

    expedition_slot.reserve(expedition_count);
    for (uint32_t i = 0; i < expedition_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        int64_t v_i64 = 0;
        uint64_t v_u64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        expedition_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        expedition_generation.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_country_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_source_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_target_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_departure_day.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_due_day.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_route_cost.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_speed.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        expedition_state.push_back(v_u8);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_population.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_effect_transaction_id.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_idempotency_key.push_back(v_u64);
        uint32_t route_count = 0;
        uint32_t payload_count = 0;
        if (!read_pod(p, end, route_count) || !read_pod(p, end, payload_count)) {
            clear();
            return false;
        }
        expedition_route_count.push_back(route_count);
        expedition_route_begin.push_back(static_cast<uint32_t>(route_cell.size()));
        expedition_payload_count.push_back(payload_count);
        expedition_payload_begin.push_back(
            static_cast<uint32_t>(payload_source_cohort_handle.size()));
        for (uint32_t r = 0; r < route_count; ++r) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            route_cell.push_back(v_i32);
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            route_cost.push_back(v_i32);
        }
        for (uint32_t lane = 0; lane < payload_count; ++lane) {
            if (!read_pod(p, end, v_u64)) {
                clear();
                return false;
            }
            payload_source_cohort_handle.push_back(v_u64);
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            payload_signature.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_people.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_funds.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_income.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_expense.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_in_kind_income.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_income_ema.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_tax_paid.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_subsidy_received.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_income_baseline_ema.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_demography_residual.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_cash_claim.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_owner_employed.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_employee_employed.push_back(v_i64);
            uint16_t v_u16 = 0;
            if (!read_pod(p, end, v_u16)) {
                clear();
                return false;
            }
            payload_needs_satisfaction.push_back(v_u16);
            if (!read_pod(p, end, v_u16)) {
                clear();
                return false;
            }
            payload_worst_need_id.push_back(v_u16);
            if (!read_pod(p, end, v_u16)) {
                clear();
                return false;
            }
            payload_composite_satisfaction.push_back(v_u16);
            if (!read_pod(p, end, v_u8)) {
                clear();
                return false;
            }
            payload_worst_dimension_id.push_back(v_u8);
            const size_t dim_base =
                payload_satisfaction_dims.size();
            payload_satisfaction_dims.resize(dim_base +
                                             static_cast<size_t>(kSatDimCount));
            for (int32_t dim = 0; dim < kSatDimCount; ++dim) {
                if (!read_pod(p, end, v_u16)) {
                    clear();
                    return false;
                }
                payload_satisfaction_dims[dim_base + dim] = v_u16;
            }
            if (!read_pod(p, end, v_u32)) {
                clear();
                return false;
            }
            payload_person_count.push_back(v_u32);
            payload_person_begin.push_back(
                static_cast<uint32_t>(payload_person_handle.size()));
            for (uint32_t person = 0; person < v_u32; ++person) {
                if (!read_pod(p, end, v_u64)) {
                    clear();
                    return false;
                }
                payload_person_handle.push_back(v_u64);
            }
        }
        uint32_t cargo_count = 0;
        if (!read_pod(p, end, cargo_count)) {
            clear();
            return false;
        }
        expedition_cargo_count.push_back(cargo_count);
        expedition_cargo_begin.push_back(static_cast<uint32_t>(cargo_good_id.size()));
        for (uint32_t c = 0; c < cargo_count; ++c) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            cargo_good_id.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            cargo_quantity.push_back(v_i64);
            if (!read_pod(p, end, v_u8)) {
                clear();
                return false;
            }
            cargo_flags.push_back(v_u8);
        }
        uint32_t kit_count_wire = 0;
        if (!read_pod(p, end, kit_count_wire)) {
            clear();
            return false;
        }
        expedition_kit_count.push_back(kit_count_wire);
        expedition_kit_begin.push_back(static_cast<uint32_t>(kit_type_id.size()));
        for (uint32_t k = 0; k < kit_count_wire; ++k) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            kit_type_id.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            kit_count.push_back(v_i64);
        }
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_missing_identity.push_back(v_u64);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        expedition_missing_count.push_back(v_u32);
        expedition_missing_begin.push_back(
            static_cast<uint32_t>(missing_good_id.size()));
        for (uint32_t m = 0; m < v_u32; ++m) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            missing_good_id.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            missing_quantity.push_back(v_i64);
        }
    }

    if (p != end) {
        clear();
        return false;
    }
    return shape_valid(family_count, membership_count, ownership_count,
                       person_count, person_need_count, trait_count,
                       influence_count, trait_command_count, expedition_count);
}

uint64_t RuntimeEconomyFamilyStore::wire_content_hash() const noexcept {
    std::vector<uint8_t> wire;
    append_wire(wire);
    uint64_t hash = kFnvOffset;
    for (uint8_t byte : wire) {
        hash ^= byte;
        hash *= kFnvPrime;
    }
    return hash;
}

} // namespace pk
