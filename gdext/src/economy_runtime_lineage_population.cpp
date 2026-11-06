#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::sync_owned_family_store(
        RuntimeEconomyFamilyStore &out) const {
    out.clear();
    const size_t family_n = families_store().active.size();
    out.family_slot.reserve(family_n);
    for (int32_t i = 0; i < static_cast<int32_t>(family_n); ++i) {
        out.family_slot.push_back(i);
        out.family_active.push_back(families_store().active[i]);
        out.family_generation.push_back(families_store().generation[i]);
        out.family_stable_id.push_back(families_store().stable_id[i]);
        out.family_surname_id.push_back(families_store().surname_id[i]);
        out.family_surname_disambiguator.push_back(
            families_store().surname_disambiguator[i]);
        out.family_founded_day.push_back(families_store().founded_day[i]);
        out.family_home_cell.push_back(families_store().home_cell[i]);
        out.family_origin_cell.push_back(families_store().origin_cell[i]);
        out.family_origin_ethnicity.push_back(families_store().origin_ethnicity[i]);
        out.family_culture_group_id.push_back(families_store().culture_group_id[i]);
        out.family_split_sequence.push_back(families_store().split_sequence[i]);
        out.family_decline_reviews.push_back(families_store().decline_reviews[i]);
        out.family_flags.push_back(families_store().flags[i]);
    }
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        out.membership_family_handle.push_back(edge.family_handle);
        out.membership_cohort_handle.push_back(edge.cohort_handle);
        out.membership_people.push_back(edge.people);
        out.membership_cash_claim.push_back(edge.cash_claim);
        out.membership_population_basis.push_back(edge.population_basis);
        out.membership_funds_basis.push_back(edge.funds_basis);
        out.membership_owner_employed.push_back(edge.owner_employed);
        out.membership_employee_employed.push_back(edge.employee_employed);
    }
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        out.ownership_family_handle.push_back(edge.family_handle);
        out.ownership_building_handle.push_back(edge.building_handle);
        out.ownership_owned_count.push_back(edge.owned_count);
        out.ownership_filled_owner.push_back(edge.filled_owner);
    }
    const size_t person_n = persons_store().active.size();
    out.person_slot.reserve(person_n);
    for (int32_t i = 0; i < static_cast<int32_t>(person_n); ++i) {
        out.person_slot.push_back(i);
        out.person_active.push_back(persons_store().active[i]);
        out.person_generation.push_back(persons_store().generation[i]);
        out.person_stable_id.push_back(persons_store().stable_id[i]);
        out.person_family_handle.push_back(persons_store().family_handle[i]);
        out.person_cohort_handle.push_back(persons_store().cohort_handle[i]);
        out.person_given_name_id.push_back(persons_store().given_name_id[i]);
        out.person_name_disambiguator.push_back(persons_store().name_disambiguator[i]);
        out.person_notable_since_day.push_back(persons_store().notable_since_day[i]);
        out.person_flags.push_back(persons_store().flags[i]);
        out.person_cash_claim.push_back(persons_store().cash_claim[i]);
        out.person_family_equity_share_q32.push_back(
            persons_store().family_equity_share_q32[i]);
        out.person_epoch_job_income.push_back(persons_store().epoch_job_income[i]);
        out.person_epoch_business_result.push_back(
            persons_store().epoch_business_result[i]);
        out.person_epoch_consumption_expense.push_back(
            persons_store().epoch_consumption_expense[i]);
        out.person_epoch_tax.push_back(persons_store().epoch_tax[i]);
        out.person_income_ema.push_back(persons_store().income_ema[i]);
        out.person_needs_satisfaction.push_back(persons_store().needs_satisfaction[i]);
        out.person_worst_need_id.push_back(persons_store().worst_need_id[i]);
        out.person_building_handle.push_back(persons_store().building_handle[i]);
        out.person_job_kind.push_back(persons_store().job_kind[i]);
        out.person_employee_role_index.push_back(
            persons_store().employee_role_index[i]);
        out.person_job_since_day.push_back(persons_store().job_since_day[i]);
    }
    for (const PersonNeedState &state : person_needs()) {
        out.need_person_handle.push_back(state.person_handle);
        out.need_stable_need_id.push_back(state.stable_need_id);
        out.need_desired_period_units.push_back(state.desired_period_units);
        out.need_satisfaction_q16.push_back(state.satisfaction_q16);
        out.need_attributed_spend.push_back(state.attributed_spend);
    }
    for (const FamilyTraitRoll &roll : family_trait_rolls()) {
        out.trait_family_handle.push_back(roll.family_handle);
        out.trait_trait_id.push_back(roll.trait_id);
        out.trait_strength_q16.push_back(roll.strength_q16);
        out.trait_core.push_back(roll.core);
    }
    const size_t influence_n = family_influences().active.size();
    out.influence_slot.reserve(influence_n);
    for (int32_t i = 0; i < static_cast<int32_t>(influence_n); ++i) {
        out.influence_slot.push_back(i);
        out.influence_active.push_back(family_influences().active[i]);
        out.influence_generation.push_back(family_influences().generation[i]);
        out.influence_family_handle.push_back(
            family_influences().family_handle[i]);
        out.influence_cell.push_back(family_influences().cell[i]);
        out.influence_stable_id.push_back(family_influences().stable_id[i]);
        out.influence_population.push_back(family_influences().population[i]);
        out.influence_cash.push_back(family_influences().cash[i]);
        out.influence_building_asset.push_back(
            family_influences().building_asset[i]);
        out.influence_population_share_q16.push_back(
            family_influences().population_share_q16[i]);
        out.influence_cash_share_q16.push_back(
            family_influences().cash_share_q16[i]);
        out.influence_building_share_q16.push_back(
            family_influences().building_share_q16[i]);
        out.influence_score_q16.push_back(family_influences().score_q16[i]);
        out.influence_satisfaction_q16.push_back(
            family_influences().satisfaction_q16[i]);
        out.influence_prestige_level.push_back(
            family_influences().prestige_level[i]);
        out.influence_pending_target_level.push_back(
            family_influences().pending_target_level[i]);
        out.influence_review_streak.push_back(
            family_influences().review_streak[i]);
        out.influence_last_review_day.push_back(
            family_influences().last_review_day[i]);
    }
    for (const FamilyTraitCommand &command : _family_trait_commands) {
        out.command_operation.push_back(command.operation);
        out.command_family_handle.push_back(command.family_handle);
        out.command_trait_id.push_back(command.trait_id);
        out.command_strength_q16.push_back(command.strength_q16);
        out.command_effective_day.push_back(command.effective_day);
        out.command_priority.push_back(command.priority);
        out.command_sequence.push_back(command.sequence);
        out.command_submit_order.push_back(command.submit_order);
    }
    const size_t expedition_n = family_expeditions_store().active.size();
    out.expedition_slot.reserve(expedition_n);
    for (int32_t i = 0; i < static_cast<int32_t>(expedition_n); ++i) {
        out.expedition_slot.push_back(i);
        out.expedition_active.push_back(family_expeditions_store().active[i]);
        out.expedition_generation.push_back(family_expeditions_store().generation[i]);
        out.expedition_stable_id.push_back(family_expeditions_store().stable_id[i]);
        out.expedition_country_handle.push_back(
            family_expeditions_store().country_handle[i]);
        out.expedition_family_handle.push_back(
            family_expeditions_store().family_handle[i]);
        out.expedition_source_cell.push_back(
            family_expeditions_store().source_cell[i]);
        out.expedition_target_cell.push_back(
            family_expeditions_store().target_cell[i]);
        out.expedition_departure_day.push_back(
            family_expeditions_store().departure_day[i]);
        out.expedition_due_day.push_back(family_expeditions_store().due_day[i]);
        out.expedition_route_cost.push_back(family_expeditions_store().route_cost[i]);
        out.expedition_speed.push_back(family_expeditions_store().speed[i]);
        out.expedition_state.push_back(family_expeditions_store().state[i]);
        out.expedition_population.push_back(family_expeditions_store().population[i]);
        out.expedition_effect_transaction_id.push_back(
            family_expeditions_store().effect_transaction_id[i]);
        out.expedition_idempotency_key.push_back(
            family_expeditions_store().idempotency_key[i]);
        const bool expedition_active = family_expeditions_store().active[i] != 0;
        const uint32_t route_count = expedition_active
            ? family_expeditions_store().route_count[i] : 0;
        const uint32_t payload_count = expedition_active
            ? family_expeditions_store().payload_count[i] : 0;
        out.expedition_route_count.push_back(route_count);
        out.expedition_route_begin.push_back(
            static_cast<uint32_t>(out.route_cell.size()));
        out.expedition_payload_count.push_back(payload_count);
        out.expedition_payload_begin.push_back(
            static_cast<uint32_t>(out.payload_source_cohort_handle.size()));
        const uint32_t route_begin = family_expeditions_store().route_begin[i];
        for (uint32_t r = 0; r < route_count; ++r) {
            out.route_cell.push_back(
                family_expedition_route_cells()[route_begin + r]);
            out.route_cost.push_back(
                family_expedition_route_costs()[route_begin + r]);
        }
        const uint32_t payload_begin = family_expeditions_store().payload_begin[i];
        for (uint32_t p = 0; p < payload_count; ++p) {
            const FamilyExpeditionPayload &lane =
                family_expedition_payloads()[payload_begin + p];
            out.payload_source_cohort_handle.push_back(
                lane.source_cohort_handle);
            out.payload_signature.push_back(lane.signature);
            out.payload_people.push_back(lane.people);
            out.payload_funds.push_back(lane.funds);
            out.payload_epoch_income.push_back(lane.epoch_income);
            out.payload_epoch_expense.push_back(lane.epoch_expense);
            out.payload_epoch_in_kind_income.push_back(
                lane.epoch_in_kind_income);
            out.payload_income_ema.push_back(lane.income_ema);
            out.payload_epoch_tax_paid.push_back(lane.epoch_tax_paid);
            out.payload_epoch_subsidy_received.push_back(
                lane.epoch_subsidy_received);
            out.payload_income_baseline_ema.push_back(
                lane.income_baseline_ema);
            out.payload_demography_residual.push_back(lane.demography_residual);
            out.payload_cash_claim.push_back(lane.cash_claim);
            out.payload_owner_employed.push_back(lane.owner_employed);
            out.payload_employee_employed.push_back(lane.employee_employed);
            out.payload_needs_satisfaction.push_back(lane.needs_satisfaction);
            out.payload_worst_need_id.push_back(lane.worst_need_id);
            out.payload_composite_satisfaction.push_back(
                lane.composite_satisfaction);
            out.payload_worst_dimension_id.push_back(lane.worst_dimension_id);
            const size_t dim_base = out.payload_satisfaction_dims.size();
            out.payload_satisfaction_dims.resize(
                dim_base + static_cast<size_t>(SAT_DIM_COUNT));
            for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                out.payload_satisfaction_dims[dim_base + dim] =
                    lane.satisfaction_dims[dim];
            out.payload_person_count.push_back(lane.person_count);
            out.payload_person_begin.push_back(
                static_cast<uint32_t>(out.payload_person_handle.size()));
            for (uint32_t person = 0; person < lane.person_count; ++person) {
                out.payload_person_handle.push_back(
                    family_expedition_person_handles()[lane.person_begin +
                                                      person]);
            }
        }
        const uint32_t cargo_count = expedition_active
            ? family_expeditions_store().cargo_count[i] : 0;
        const uint32_t kit_lane_count = expedition_active
            ? family_expeditions_store().kit_building_count[i] : 0;
        out.expedition_cargo_count.push_back(cargo_count);
        out.expedition_cargo_begin.push_back(
            static_cast<uint32_t>(out.cargo_good_id.size()));
        const uint32_t cargo_begin = family_expeditions_store().cargo_begin[i];
        for (uint32_t c = 0; c < cargo_count; ++c) {
            const FamilyExpeditionCargoLine &line =
                family_expedition_cargo()[cargo_begin + c];
            out.cargo_good_id.push_back(line.good_id);
            out.cargo_quantity.push_back(line.quantity);
            out.cargo_flags.push_back(line.flags);
        }
        out.expedition_kit_count.push_back(kit_lane_count);
        out.expedition_kit_begin.push_back(
            static_cast<uint32_t>(out.kit_type_id.size()));
        const uint32_t kit_begin = family_expeditions_store().kit_building_begin[i];
        for (uint32_t k = 0; k < kit_lane_count; ++k) {
            const FamilyExpeditionKitBuilding &row =
                family_expedition_kit_buildings()[kit_begin + k];
            out.kit_type_id.push_back(row.type_id);
            out.kit_count.push_back(row.count);
        }
        if (expedition_active) {
            out.expedition_missing_identity.push_back(
                family_expeditions_store().kit_missing_stock_identity[i]);
            out.expedition_missing_count.push_back(
                family_expeditions_store().missing_good_count[i]);
            out.expedition_missing_begin.push_back(
                static_cast<uint32_t>(out.missing_good_id.size()));
            const uint32_t missing_begin =
                family_expeditions_store().missing_good_begin[i];
            for (uint32_t m = 0; m < family_expeditions_store().missing_good_count[i];
                 ++m) {
                out.missing_good_id.push_back(
                    family_expedition_missing_good_ids()[missing_begin + m]);
                out.missing_quantity.push_back(
                    family_expedition_missing_good_quantities()[missing_begin +
                                                               m]);
            }
        } else {
            out.expedition_missing_identity.push_back(0);
            out.expedition_missing_count.push_back(0);
            out.expedition_missing_begin.push_back(
                static_cast<uint32_t>(out.missing_good_id.size()));
        }
    }
}

int32_t NativeEconomyRuntime::neighbor_count_with_tag(
        int32_t cell, int32_t tag) const {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    std::vector<int32_t> neighbors;
    collect_effect_target_cells(cell, EffectRuntime::SELECTOR_NEIGHBORS_R1,
                                EffectRuntime::SELECTOR_MAX_CELLS, 0, neighbors);
    // R-3b: ONE load, outside the loop. The neighbour walk visits at most 18 cells,
    // but this is called per cell from other loops, so a per-neighbour load would
    // multiply the shared_ptr spin lock by the caller's own iteration count.
    const std::shared_ptr<const TagSnapshot> tags_here =
        tag >= 0 ? tag_snapshot() : std::shared_ptr<const TagSnapshot>();
    const TagSnapshot *const tags_ptr = tags_here.get();
    int32_t count = 0;
    for (const int32_t neighbor : neighbors) {
        if (neighbor == cell) continue;
        if (tag >= 0 && !snapshot_has_tag(tags_ptr, neighbor, tag)) continue;
        ++count;
    }
    return count;
}

int32_t NativeEconomyRuntime::find_entrepreneur_source(
        int32_t cell, int32_t target_signature, int64_t required_capital,
        int64_t target_income_per_day, int64_t target_living_cost_per_day,
        int64_t owner_slots_per_building, int32_t building_type_id,
        bool &had_eligible_sponsor, int64_t &willing_population,
        int64_t &transferable_capital,
        int64_t &income_improvement_q16,
        uint64_t &sponsor_family_handle, const std::vector<int64_t> *living_cost_cache) const {
    had_eligible_sponsor = false;
    willing_population = 0;
    transferable_capital = 0;
    income_improvement_q16 = 0;
    sponsor_family_handle = 0;
    if (cell < 0 || cell >= _cell_count.get() || target_signature < 0 ||
        target_signature >= static_cast<int32_t>(_signatures.size()) ||
        building_type_id < 0 ||
        building_type_id >= static_cast<int32_t>(_building_types.size()) ||
        target_income_per_day <= 0 || owner_slots_per_building <= 0) return -1;
    const Signature &target = _signatures[target_signature];
    int32_t best_slot = -1;
    int64_t best_improvement_q16 = std::numeric_limits<int64_t>::min();
    int64_t best_transferable = -1;
    int64_t best_willing = 0;
    uint64_t best_family = 0;
    int64_t sat = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t source_signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        if (source_signature < 0 || source_signature >=
                static_cast<int32_t>(_signatures.size())) return;
        const Signature &source = _signatures[source_signature];
        if (source.ethnicity_id != target.ethnicity_id) return;
        const int64_t population = std::max<int64_t>(0,
            population_store().population[slot]);
        if (population <= 0) return;
        const bool profession_transition = source_signature != target_signature;
        // Keep one lane occupant when changing profession so a portfolio can
        // apply exact capital corrections without a released source handle.
        const int64_t available_population = profession_transition
            ? std::max<int64_t>(0, population - 1)
            : population;
        if (available_population <= 0 ||
            (is_merchant_slot(slot) && population <= 1)) return;
        const size_t living_key = static_cast<size_t>(source.plan_id) * _ethnicity_ids.size() +
            static_cast<size_t>(source.ethnicity_id);
        const int64_t cached_living_cost = living_cost_cache != nullptr &&
                living_key < living_cost_cache->size()
            ? (*living_cost_cache)[living_key] : -1;
        const int64_t source_living_cost = cached_living_cost >= 0 ? cached_living_cost :
            living_cost_for_signature(cell, source_signature, -1, sat);
        const int64_t reserve = saturating_mul(saturating_mul(
            source_living_cost, population, sat), 30, sat);
        const int64_t transferable = std::max<int64_t>(
            0, population_store().funds[slot] - reserve);
        if (transferable < required_capital) return;
        const int64_t income_per_capita = std::max<int64_t>(0,
            population_store().income_ema[slot]) / population;
        const int64_t recent_expense_per_day = std::max<int64_t>(0,
            population_store().epoch_expense[slot]) /
            std::max<int64_t>(1, saturating_mul(
                population, std::max<int64_t>(1, _epoch_days.get()), sat));
        const int64_t current_disposable = saturating_sub(
            income_per_capita,
            std::max(source_living_cost, recent_expense_per_day), sat);
        const int64_t target_disposable = saturating_sub(
            target_income_per_day, target_living_cost_per_day, sat);
        const int64_t income_gain = saturating_sub(
            target_disposable, current_disposable, sat);
        if (income_gain <= 0) return;
        had_eligible_sponsor = true;
        const int64_t chance_q16 = std::clamp<int64_t>(mul_div_sat(
            income_gain, Q16_ONE, std::max<int64_t>({
                1, target_income_per_day, target_living_cost_per_day}), sat),
            1, Q16_ONE);
        if (target.profession_id == _merchant_profession_id &&
            source.profession_id != _merchant_profession_id &&
            chance_q16 <
                _investment_merchant_transition_min_improvement_q16.get()) {
            // Merchant is both an occupation and the cell's market balance-sheet
            // owner. Require a material improvement before creating another
            // merchant cohort instead of using the generic positive-gain floor.
            return;
        }
        const int64_t willing_floor = mul_div_sat(
            available_population, chance_q16, Q16_ONE, sat);
        const int64_t willingness_numerator = saturating_mul(
            available_population, chance_q16, sat);
        const int64_t willingness_remainder =
            willingness_numerator - saturating_mul(
                willing_floor, Q16_ONE, sat);
        uint64_t roll_hash = 1469598103934665603ULL;
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_seed.get()));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_current_day.get()));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(cell));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(building_type_id));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(source_signature));
        const int64_t roll_q16 = static_cast<int64_t>((roll_hash >> 32) & 0xffffULL);
        const int64_t generic_willing = std::min<int64_t>(
            available_population, saturating_add(
                willing_floor, roll_q16 < willingness_remainder ? 1 : 0, sat));
        if (generic_willing < owner_slots_per_building) return;
        const auto consider = [&](uint64_t family_handle,
                                  int64_t family_people,
                                  int64_t family_capital) {
            const int64_t willing = std::min(generic_willing,
                std::max<int64_t>(0, family_people));
            const int64_t capital = std::min(transferable,
                std::max<int64_t>(0, family_capital));
            if (willing < owner_slots_per_building ||
                capital < required_capital) return;
            if (chance_q16 > best_improvement_q16 ||
                (chance_q16 == best_improvement_q16 &&
                 capital > best_transferable) ||
                (chance_q16 == best_improvement_q16 &&
                 capital == best_transferable &&
                 (best_slot < 0 || slot < best_slot ||
                  (slot == best_slot && family_handle < best_family)))) {
                best_slot = slot;
                best_improvement_q16 = chance_q16;
                best_transferable = capital;
                best_willing = willing;
                best_family = family_handle;
            }
        };
        // Families and the anonymous remainder compete as separate sponsors,
        // each paying from its own claim net of a month of living cost.
        int64_t family_people = 0, family_claim = 0;
        if (_family_runtime_mode.get() == 2 && _family_cohort_offsets.size() ==
                population_store().active.size() + 1) {
            for (int32_t p = _family_cohort_offsets[slot];
                 p < _family_cohort_offsets[slot + 1]; ++p) {
                const FamilyMembershipEdge &edge = family_memberships()[
                    _family_cohort_edge_indices[p]];
                int32_t family = -1;
                if (!families_store().valid_handle(edge.family_handle, family)) continue;
                const int64_t people = std::max<int64_t>(0, edge.people);
                const int64_t claim = std::max<int64_t>(0, edge.cash_claim);
                family_people = saturating_add(family_people, people, sat);
                family_claim = saturating_add(family_claim, claim, sat);
                consider(edge.family_handle, people, saturating_sub(claim,
                    saturating_mul(saturating_mul(source_living_cost, people, sat),
                                   30, sat), sat));
            }
        }
        const int64_t anonymous_people = std::max<int64_t>(0,
            std::min(available_population, population - family_people));
        consider(0, anonymous_people, saturating_sub(saturating_sub(
            population_store().funds[slot], family_claim, sat),
            saturating_mul(saturating_mul(source_living_cost, anonymous_people, sat),
                           30, sat), sat));
    });
    if (best_slot >= 0) {
        willing_population = best_willing;
        transferable_capital = best_transferable;
        income_improvement_q16 = best_improvement_q16;
        sponsor_family_handle = best_family;
    }
    return best_slot;
}

bool NativeEconomyRuntime::apply_family_population_reward(
        const Command &cmd, std::string &error) {
    int32_t branch = -1;
    if (!family_influences().valid_handle(cmd.target_handle, branch)) {
        ++_rejected_commands;
        return true;
    }
    const uint64_t family_handle = family_influences().family_handle[branch];
    int32_t family = -1;
    const int32_t cell = family_influences().cell[branch];
    const int64_t amount = cmd.i64_0;
    if (!families_store().valid_handle(family_handle, family)) {
        ++_rejected_commands;
        return true;
    }
    if (cmd.i32_0 == -1) {
        ensure_family_policy_factors();
        if (family >= 0 && family < static_cast<int32_t>(
                _family_colonization_population_reward.size()))
            _family_colonization_population_reward[static_cast<size_t>(family)] =
                static_cast<int32_t>(std::clamp<int64_t>(amount, 0,
                    std::numeric_limits<int32_t>::max()));
        return true;
    }
    if (cell < 0 || cell >= _cell_count.get() || amount <= 0) {
        ++_rejected_commands;
        return true;
    }

    int32_t target_slot = -1;
    int64_t best_people = -1;
    if (cmd.i32_0 == 0) {
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            int32_t slot = -1;
            if (edge.family_handle != family_handle || edge.people <= 0 ||
                !population_store().valid_handle(edge.cohort_handle, slot) ||
                population_store().page_cell[slot / COHORT_PAGE_SIZE] != cell) continue;
            if (edge.people > best_people || (edge.people == best_people &&
                    (target_slot < 0 || edge.cohort_handle <
                        population_store().handle_for_slot(target_slot)))) {
                best_people = edge.people;
                target_slot = slot;
            }
        }
    } else {
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            int64_t attributed = 0;
            const uint64_t cohort = population_store().handle_for_slot(slot);
            for (const FamilyMembershipEdge &edge : family_memberships())
                if (edge.cohort_handle == cohort)
                    attributed = saturating_add(attributed,
                        std::max<int64_t>(0, edge.people), _saturation_count);
            const int64_t anonymous = std::max<int64_t>(0,
                population_store().population[slot] - attributed);
            if (anonymous > best_people || (anonymous == best_people &&
                    (target_slot < 0 || cohort <
                        population_store().handle_for_slot(target_slot)))) {
                best_people = anonymous;
                target_slot = slot;
            }
        });
    }

    if (target_slot < 0) {
        const int32_t signature = unemployed_signature_for_ethnicity(
            families_store().origin_ethnicity[family]);
        if (signature < 0) {
            ++_rejected_commands;
            return true;
        }
        target_slot = population_store().allocate_slot(cell,
            static_cast<uint32_t>(signature));
        if (target_slot < 0) {
            error = "family_population_reward_allocation_failed";
            return false;
        }
    }

    touch_accounting_slot(target_slot);
    audit_touch_population_lane(target_slot);
    const uint64_t cohort_handle = population_store().handle_for_slot(target_slot);
    const int64_t before = population_store().population[target_slot];
    population_store().population.write_scalar(target_slot, saturating_add(
        before, amount, _saturation_count), market_mutation_sink());
    const int64_t actual = population_store().population[target_slot] - before;
    if (actual <= 0) return true;
    _external_population_delta = saturating_add(
        _external_population_delta, actual, _saturation_count);
    _structural_touched_cells.push_back(cell);

    if (cmd.i32_0 == 0) {
        auto membership = std::find_if(family_memberships().begin(),
            family_memberships().end(), [&](const FamilyMembershipEdge &edge) {
                return edge.family_handle == family_handle &&
                    edge.cohort_handle == cohort_handle;
            });
        if (membership == family_memberships().end()) {
            family_memberships().push_back({family_handle, cohort_handle,
                actual, 0, population_store().population[target_slot],
                family_ledger_basis_for_slot(target_slot), 0, 0});
        } else {
            auto membership_write = family_memberships().edit_row(membership - family_memberships().begin(), market_mutation_sink());
            auto *membership_row = &membership_write[0];
            membership_row->people = saturating_add(
                membership->people, actual, _saturation_count);
            membership_row->population_basis = population_store().population[target_slot];
        }
        _family_indices_dirty = true;
    }

    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(cell)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
            static_cast<int64_t>(cohort_handle), -1, before,
            population_store().population[target_slot]});
    }
    trace_append(EVENT_POPULATION_SOURCE,
        static_cast<int32_t>(Stage::LEDGER_APPLY), cell,
        SUBJECT_FAMILY_BRANCH, static_cast<int64_t>(cmd.target_handle),
        cmd.i32_0, COMMAND_FAMILY_POPULATION_REWARD, actual, before,
        population_store().population[target_slot], cmd.i64_1,
        legs.empty() ? nullptr : &legs);
    return true;
}

bool NativeEconomyRuntime::apply_family_absorb_anonymous(
        const Command &cmd, std::string &error) {
    (void)error;
    int32_t branch = -1;
    if (!family_influences().valid_handle(cmd.target_handle, branch)) {
        ++_rejected_commands;
        return true;
    }
    const uint64_t family_handle = family_influences().family_handle[branch];
    int32_t family = -1;
    const int32_t cell = family_influences().cell[branch];
    if (!families_store().valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count.get()) {
        ++_rejected_commands;
        return true;
    }
    ensure_family_policy_factors();
    if (cmd.i32_0 == 1) {
        if (family >= 0 && family < static_cast<int32_t>(
                _family_absorb_bonus_q16.size()))
            _family_absorb_bonus_q16[static_cast<size_t>(family)] =
                static_cast<int32_t>(std::clamp<int64_t>(cmd.i64_0, 0,
                    4 * Q16_ONE));
        return true;
    }
    int64_t remaining = std::max<int64_t>(0, cmd.i64_0);
    if (remaining <= 0) return true;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        if (remaining <= 0) return;
        int64_t claimed = 0;
        const uint64_t cohort = population_store().handle_for_slot(slot);
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            if (edge.cohort_handle == cohort)
                claimed += std::max<int64_t>(0, edge.people);
        }
        const int64_t available = std::max<int64_t>(0,
            population_store().population[slot] - claimed);
        const int64_t take = std::min(remaining, available);
        if (take <= 0) return;
        add_family_household_people(family_handle, slot, take);
        remaining -= take;
    });
    return true;
}

void NativeEconomyRuntime::apply_family_colonization_population_reward(
        int32_t destination, uint64_t family_handle, int64_t amount) {
    if (destination < 0 || destination >= _cell_count.get() || amount <= 0) return;
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family)) return;
    Command reward;
    reward.opcode = COMMAND_FAMILY_POPULATION_REWARD;
    reward.i32_0 = 0;
    reward.i64_0 = amount;
    reward.sequence = 0;
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0 ||
            family_influences().family_handle[branch] != family_handle ||
            family_influences().cell[branch] != destination) continue;
        reward.target_handle = family_influences().handle_for_index(branch);
        std::string ignored;
        apply_family_population_reward(reward, ignored);
        return;
    }
    int32_t target_slot = -1;
    int64_t best_people = -1;
    population_store().for_each_in_cell(destination, [&](int32_t slot) {
        int64_t attributed = 0;
        const uint64_t cohort = population_store().handle_for_slot(slot);
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            if (edge.cohort_handle == cohort)
                attributed += std::max<int64_t>(0, edge.people);
        }
        const int64_t anonymous = std::max<int64_t>(0,
            population_store().population[slot] - attributed);
        if (anonymous > best_people || (anonymous == best_people &&
                (target_slot < 0 || cohort <
                    population_store().handle_for_slot(target_slot)))) {
            best_people = anonymous;
            target_slot = slot;
        }
    });
    if (target_slot < 0) {
        const int32_t signature = unemployed_signature_for_ethnicity(
            families_store().origin_ethnicity[family]);
        if (signature < 0) return;
        target_slot = population_store().allocate_slot(destination,
            static_cast<uint32_t>(signature));
        if (target_slot < 0) return;
    }
    touch_accounting_slot(target_slot);
    audit_touch_population_lane(target_slot);
    const uint64_t cohort_handle = population_store().handle_for_slot(target_slot);
    const int64_t before = population_store().population[target_slot];
    population_store().population.write_scalar(target_slot, saturating_add(
        before, amount, _saturation_count), market_mutation_sink());
    const int64_t actual = population_store().population[target_slot] - before;
    if (actual <= 0) return;
    _external_population_delta = saturating_add(
        _external_population_delta, actual, _saturation_count);
    _structural_touched_cells.push_back(destination);
    auto membership = std::find_if(family_memberships().begin(),
        family_memberships().end(), [&](const FamilyMembershipEdge &edge) {
            return edge.family_handle == family_handle &&
                edge.cohort_handle == cohort_handle;
        });
    if (membership == family_memberships().end()) {
        family_memberships().push_back({family_handle, cohort_handle,
            actual, 0, population_store().population[target_slot],
            family_ledger_basis_for_slot(target_slot), 0, 0});
    } else {
        auto membership_write = family_memberships().edit_row(membership - family_memberships().begin(), market_mutation_sink());
        auto *membership_row = &membership_write[0];
        membership_row->people = saturating_add(
            membership->people, actual, _saturation_count);
        membership_row->population_basis = population_store().population[target_slot];
    }
    _family_indices_dirty = true;
    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(destination)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
            static_cast<int64_t>(cohort_handle), -1, before,
            population_store().population[target_slot]});
    }
    trace_append(EVENT_POPULATION_SOURCE,
        static_cast<int32_t>(Stage::LEDGER_APPLY), destination,
        SUBJECT_FAMILY_BRANCH, static_cast<int64_t>(family_handle),
        0, COMMAND_FAMILY_POPULATION_REWARD, actual, before,
        population_store().population[target_slot], 0,
        legs.empty() ? nullptr : &legs);
}

} // namespace pk
