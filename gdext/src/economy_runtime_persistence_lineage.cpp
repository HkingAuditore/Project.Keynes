#include "economy_runtime.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_persistence_codec.h"
#include <algorithm>
#include <cstdlib>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace persistence_codec;

bool NativeEconomyRuntime::decode_restore_family_tables(
        const std::vector<uint8_t> &bytes, size_t &cursor, uint16_t schema,
        uint16_t section, uint32_t records, std::string &error) {
    if (schema >= 26 && section == SAVE_SECTION_FAMILY_RECORDS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1, surname = -1, home_cell = -1, origin_cell = -1,
                    ethnicity = -1, culture_group = -1;
            uint8_t active = 0;
            uint32_t generation = 0, disambiguator = 0, split_sequence = 0;
            int64_t stable_id = 0, founded_day = -1;
            uint16_t decline = 0, flags = 0;
            int32_t pending_population_reward = 0;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, surname) ||
                !read_le(bytes, cursor, disambiguator) ||
                !read_le(bytes, cursor, founded_day) ||
                !read_le(bytes, cursor, home_cell) ||
                (schema >= 40 && !read_le(bytes, cursor, origin_cell)) ||
                !read_le(bytes, cursor, ethnicity) ||
                (schema >= 40 && !read_le(bytes, cursor, culture_group)) ||
                (schema >= 40 && !read_le(bytes, cursor, split_sequence)) ||
                !read_le(bytes, cursor, decline) ||
                !read_le(bytes, cursor, flags) ||
                !read_le(bytes, cursor, pending_population_reward) ||
                index != static_cast<int32_t>(families_store().active.size()) ||
                active > 1 || generation == 0 ||
                pending_population_reward < 0 ||
                (active != 0 && (stable_id <= 0 || surname < 0 ||
                    surname >= static_cast<int32_t>(_family_surname_ids.size()) ||
                    home_cell < 0 || home_cell >= _cell_count.get() ||
                    (schema >= 40 && (origin_cell < 0 || origin_cell >= _cell_count.get() ||
                        culture_group < 0 || ethnicity < 0 ||
                        ethnicity >= static_cast<int32_t>(_ethnicity_culture_group_ids.size()) ||
                        culture_group != _ethnicity_culture_group_ids[ethnicity])) ||
                    ethnicity < 0 || ethnicity >= static_cast<int32_t>(_ethnicity_ids.size())))) {
                error = "save_family_record_invalid";
                return false;
            }
            families_store().active.push_back(active);
            families_store().generation.push_back(generation);
            families_store().stable_id.push_back(stable_id);
            families_store().surname_id.push_back(surname);
            families_store().surname_disambiguator.push_back(disambiguator);
            families_store().founded_day.push_back(founded_day);
            families_store().home_cell.push_back(home_cell);
            families_store().origin_cell.push_back(schema >= 40 ? origin_cell : home_cell);
            families_store().origin_ethnicity.push_back(ethnicity);
            families_store().culture_group_id.push_back(schema >= 40 ? culture_group :
                (ethnicity >= 0 && ethnicity < static_cast<int32_t>(
                    _ethnicity_culture_group_ids.size())
                    ? _ethnicity_culture_group_ids[ethnicity] : 0));
            families_store().split_sequence.push_back(schema >= 40 ? split_sequence : 0);
            families_store().decline_reviews.push_back(decline);
            families_store().flags.push_back(flags);
            _restore.family_colonization_population_reward_pending.push_back(
                pending_population_reward);
            if (active != 0) {
                ++families_store().active_count;
                _family_stable_ids.insert(stable_id);
                if (static_cast<size_t>(surname) >=
                    _family_surname_members.size())
                    _family_surname_members.resize(
                        static_cast<size_t>(surname) + 1);
                _family_surname_members[static_cast<size_t>(surname)]
                    .push_back(index);
            } else {
                families_store().free_indices.push_back(index);
            }
            ++_restore.restored_families;
        }
        _restore.family_records_seen = true;
    } else if (schema >= 26 &&
               section == SAVE_SECTION_FAMILY_MEMBERSHIP) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyMembershipEdge edge;
            int32_t family = -1, slot = -1;
            if (!read_le(bytes, cursor, edge.family_handle) ||
                !read_le(bytes, cursor, edge.cohort_handle) ||
                !read_le(bytes, cursor, edge.people) ||
                !read_le(bytes, cursor, edge.cash_claim) ||
                !read_le(bytes, cursor, edge.population_basis) ||
                !read_le(bytes, cursor, edge.funds_basis) ||
                !read_le(bytes, cursor, edge.owner_employed) ||
                !read_le(bytes, cursor, edge.employee_employed) ||
                !families_store().valid_handle(edge.family_handle, family) ||
                !population_store().valid_handle(edge.cohort_handle, slot) ||
                edge.people <= 0 || edge.cash_claim < 0) {
                error = "save_family_membership_invalid";
                return false;
            }
            // Older saves could persist overshot employment attribution or
            // stale population/funds bases after membership merges. Repair the
            // derived fields instead of rejecting an otherwise loadable world.
            sanitize_family_membership_edge(edge);
            family_memberships().push_back(edge);
            ++_restore.restored_family_memberships;
        }
        _restore.family_membership_seen = true;
    } else if (schema >= 26 &&
               section == SAVE_SECTION_FAMILY_OWNERSHIP) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyBuildingOwnership edge;
            int32_t family = -1;
            if (!read_le(bytes, cursor, edge.family_handle) ||
                !read_le(bytes, cursor, edge.building_handle) ||
                !read_le(bytes, cursor, edge.owned_count) ||
                !read_le(bytes, cursor, edge.filled_owner) ||
                !families_store().valid_handle(edge.family_handle, family) ||
                edge.building_handle == 0 || edge.owned_count <= 0 ||
                edge.filled_owner < 0) {
                error = "save_family_ownership_invalid";
                return false;
            }
            family_ownerships().push_back(edge);
            ++_restore.restored_family_ownerships;
        }
        _restore.family_ownership_seen = true;
    } else if (schema >= 27 && section == SAVE_SECTION_PERSON_RECORDS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1;
            uint8_t active = 0, job_kind = 0;
            uint32_t generation = 0, disambiguator = 0;
            int64_t stable_id = 0, notable_since_day = -1, cash_claim = 0,
                    equity_share = 0, epoch_job_income = 0,
                    epoch_business_result = 0, epoch_consumption_expense = 0,
                    epoch_tax = 0, income_ema = 0, job_since_day = -1;
            uint64_t family_handle = 0, cohort_handle = 0,
                     building_handle = 0;
            int32_t given_name = -1, employee_role = -1;
            uint16_t flags = 0, satisfaction = 0,
                     worst_need = std::numeric_limits<uint16_t>::max();
            int32_t family = -1, cohort = -1;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, family_handle) ||
                !read_le(bytes, cursor, cohort_handle) ||
                !read_le(bytes, cursor, given_name) ||
                !read_le(bytes, cursor, disambiguator) ||
                !read_le(bytes, cursor, notable_since_day) ||
                !read_le(bytes, cursor, flags) ||
                !read_le(bytes, cursor, cash_claim) ||
                !read_le(bytes, cursor, equity_share) ||
                !read_le(bytes, cursor, epoch_job_income) ||
                !read_le(bytes, cursor, epoch_business_result) ||
                !read_le(bytes, cursor, epoch_consumption_expense) ||
                !read_le(bytes, cursor, epoch_tax) ||
                !read_le(bytes, cursor, income_ema) ||
                !read_le(bytes, cursor, satisfaction) ||
                !read_le(bytes, cursor, worst_need) ||
                !read_le(bytes, cursor, building_handle) ||
                !read_le(bytes, cursor, job_kind) ||
                !read_le(bytes, cursor, employee_role) ||
                !read_le(bytes, cursor, job_since_day) ||
                index != static_cast<int32_t>(persons_store().active.size()) ||
                active > 1 || generation == 0 || job_kind > 2 ||
                (active != 0 &&
                    (stable_id <= 0 ||
                     !families_store().valid_handle(family_handle, family) ||
                     (cohort_handle != 0 &&
                      !population_store().valid_handle(cohort_handle, cohort)) ||
                     given_name < 0 || given_name >= static_cast<int32_t>(
                        _person_given_name_ids.size()) ||
                     notable_since_day < 0 || cash_claim < 0 ||
                     equity_share < 0 || equity_share > Q32_ONE ||
                     epoch_job_income < 0 || epoch_consumption_expense < 0 ||
                     epoch_tax < 0 || income_ema < 0 ||
                     // satisfaction 是 uint16_t，见 satisfaction_dims 处的注释——
                     // 「>= Q16_ONE」对该类型恒假。
                     (job_kind == 0 &&
                        (building_handle != 0 || employee_role != -1)) ||
                     (job_kind != 0 && building_handle == 0) ||
                     (job_kind == 1 && employee_role != -1) ||
                     (job_kind == 2 && employee_role < 0)))) {
                error = "save_person_record_invalid";
                return false;
            }
            persons_store().active.push_back(active);
            persons_store().generation.push_back(generation);
            persons_store().stable_id.push_back(stable_id);
            if (active != 0) _person_stable_ids.insert(stable_id);
            persons_store().family_handle.push_back(family_handle);
            persons_store().cohort_handle.push_back(cohort_handle);
            persons_store().given_name_id.push_back(given_name);
            persons_store().name_disambiguator.push_back(disambiguator);
            persons_store().notable_since_day.push_back(notable_since_day);
            persons_store().flags.push_back(flags);
            persons_store().cash_claim.push_back(cash_claim);
            persons_store().family_equity_share_q32.push_back(equity_share);
            persons_store().epoch_job_income.push_back(epoch_job_income);
            persons_store().epoch_business_result.push_back(epoch_business_result);
            persons_store().epoch_consumption_expense.push_back(
                epoch_consumption_expense);
            persons_store().epoch_tax.push_back(epoch_tax);
            persons_store().income_ema.push_back(income_ema);
            persons_store().needs_satisfaction.push_back(satisfaction);
            persons_store().worst_need_id.push_back(worst_need);
            persons_store().building_handle.push_back(building_handle);
            persons_store().job_kind.push_back(job_kind);
            persons_store().employee_role_index.push_back(employee_role);
            persons_store().job_since_day.push_back(job_since_day);
            if (active != 0) ++persons_store().active_count;
            else persons_store().free_indices.push_back(index);
            ++_restore.restored_persons;
        }
        _restore.person_records_seen = true;
    } else if (schema >= 27 && section == SAVE_SECTION_PERSON_NEEDS) {
        for (uint32_t record = 0; record < records; ++record) {
            PersonNeedState state;
            int32_t person = -1;
            if (!read_le(bytes, cursor, state.person_handle) ||
                !read_le(bytes, cursor, state.stable_need_id) ||
                !read_le(bytes, cursor, state.desired_period_units) ||
                !read_le(bytes, cursor, state.satisfaction_q16) ||
                !read_le(bytes, cursor, state.attributed_spend) ||
                !persons_store().valid_handle(state.person_handle, person) ||
                state.stable_need_id < 0 || state.stable_need_id >=
                    static_cast<int32_t>(_needs.size()) ||
                state.desired_period_units < 0 ||
                // satisfaction_q16 是 uint16_t，见 satisfaction_dims 处的注释——
                // 「>= Q16_ONE」对该类型恒假。
                state.attributed_spend < 0) {
                error = "save_person_need_invalid";
                return false;
            }
            person_needs().push_back(state);
            _person_needs_normalized = false;
            ++_restore.restored_person_needs;
        }
        _restore.person_needs_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_TRAITS) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyTraitRoll roll;
            int32_t family = -1;
            if (!read_le(bytes, cursor, roll.family_handle) ||
                !read_le(bytes, cursor, roll.trait_id) ||
                !read_le(bytes, cursor, roll.strength_q16) ||
                !read_le(bytes, cursor, roll.core) || roll.core > 1 ||
                !families_store().valid_handle(roll.family_handle, family) ||
                roll.trait_id < 0 || roll.trait_id >= static_cast<int32_t>(
                    _family_trait_ids.size()) ||
                roll.strength_q16 < _family_trait_strength_min_q16[roll.trait_id] ||
                roll.strength_q16 > _family_trait_strength_max_q16[roll.trait_id] ||
                (roll.strength_q16 -
                    _family_trait_strength_min_q16[roll.trait_id]) %
                    _family_trait_strength_step_q16[roll.trait_id] != 0) {
                error = "save_family_trait_roll_invalid";
                return false;
            }
            family_trait_rolls().push_back(roll);
            ++_restore.restored_family_traits;
        }
        _restore.family_traits_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_INFLUENCES) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1, cell = -1;
            uint8_t active = 0, level = 0, pending = 0, streak = 0;
            uint32_t generation = 0;
            uint64_t family_handle = 0;
            int64_t stable_id = 0, population = 0, cash = 0, asset = 0,
                last_review = -1;
            int32_t population_share = 0, cash_share = 0,
                building_share = 0, score = 0, satisfaction = 0;
            int32_t family = -1;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, family_handle) ||
                !read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, population) ||
                !read_le(bytes, cursor, cash) ||
                !read_le(bytes, cursor, asset) ||
                !read_le(bytes, cursor, population_share) ||
                !read_le(bytes, cursor, cash_share) ||
                !read_le(bytes, cursor, building_share) ||
                !read_le(bytes, cursor, score) ||
                !read_le(bytes, cursor, satisfaction) ||
                !read_le(bytes, cursor, level) ||
                !read_le(bytes, cursor, pending) ||
                !read_le(bytes, cursor, streak) ||
                !read_le(bytes, cursor, last_review) ||
                index != static_cast<int32_t>(
                    family_influences().active.size()) || active > 1 ||
                generation == 0 || (active != 0 &&
                    (!families_store().valid_handle(family_handle, family) ||
                     cell < 0 || cell >= _cell_count.get() || stable_id <= 0 ||
                     population < 0 || cash < 0 || asset < 0 || level > 5 ||
                     pending > 5 || population_share < 0 ||
                     population_share > Q16_ONE || cash_share < 0 ||
                     cash_share > Q16_ONE || building_share < 0 ||
                     building_share > Q16_ONE || score < 0 ||
                     score > Q16_ONE || satisfaction < 0 ||
                     satisfaction >= Q16_ONE))) {
                error = "save_family_influence_invalid";
                return false;
            }
            family_influences().active.push_back(active);
            family_influences().generation.push_back(generation);
            family_influences().family_handle.push_back(family_handle);
            family_influences().cell.push_back(cell);
            family_influences().stable_id.push_back(stable_id);
            family_influences().population.push_back(population);
            family_influences().cash.push_back(cash);
            family_influences().building_asset.push_back(asset);
            family_influences().population_share_q16.push_back(population_share);
            family_influences().cash_share_q16.push_back(cash_share);
            family_influences().building_share_q16.push_back(building_share);
            family_influences().score_q16.push_back(score);
            family_influences().satisfaction_q16.push_back(satisfaction);
            family_influences().prestige_level.push_back(level);
            family_influences().pending_target_level.push_back(pending);
            family_influences().review_streak.push_back(streak);
            family_influences().last_review_day.push_back(last_review);
            if (active == 0) family_influences().free_indices.push_back(index);
            ++_restore.restored_family_influences;
        }
        _restore.family_influences_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_TRAIT_COMMANDS) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyTraitCommand command;
            int32_t family = -1;
            if (!read_le(bytes, cursor, command.operation) ||
                !read_le(bytes, cursor, command.family_handle) ||
                !read_le(bytes, cursor, command.trait_id) ||
                !read_le(bytes, cursor, command.strength_q16) ||
                !read_le(bytes, cursor, command.effective_day) ||
                !read_le(bytes, cursor, command.priority) ||
                !read_le(bytes, cursor, command.sequence) ||
                !read_le(bytes, cursor, command.submit_order) ||
                command.operation < 1 || command.operation > 3 ||
                !families_store().valid_handle(command.family_handle, family) ||
                command.trait_id < 0 || command.trait_id >= static_cast<int32_t>(
                    _family_trait_ids.size()) || command.effective_day < 0 ||
                command.submit_order == 0) {
                error = "save_family_trait_command_invalid";
                return false;
            }
            _family_trait_commands.push_back(command);
            ++_restore.restored_family_trait_commands;
        }
        _restore.family_trait_commands_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_EXPEDITIONS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1, source_cell = -1, target_cell = -1;
            uint8_t active = 0, state = 0;
            uint32_t generation = 0, route_count = 0, payload_count = 0;
            int64_t stable_id = 0, departure_day = -1, due_day = -1,
                population = 0, kit_bridge_required = 0,
                kit_material_required = 0, transaction_id = 0;
            uint64_t country_handle = 0, family_handle = 0,
                idempotency_key = 0;
            int32_t route_cost = 0, speed = 0;
            int64_t anonymous_population = 0;
            // schema 65 carries the unaffiliated headcount right after the
            // dispatched family headcount; older records never had any.
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, country_handle) ||
                !read_le(bytes, cursor, family_handle) ||
                !read_le(bytes, cursor, source_cell) ||
                !read_le(bytes, cursor, target_cell) ||
                !read_le(bytes, cursor, departure_day) ||
                !read_le(bytes, cursor, due_day) ||
                !read_le(bytes, cursor, route_cost) ||
                !read_le(bytes, cursor, speed) ||
                !read_le(bytes, cursor, state) ||
                !read_le(bytes, cursor, population) ||
                (schema >= 65 && !read_le(bytes, cursor, anonymous_population)) ||
                !read_le(bytes, cursor, kit_bridge_required) ||
                !read_le(bytes, cursor, kit_material_required) ||
                !read_le(bytes, cursor, transaction_id) ||
                !read_le(bytes, cursor, idempotency_key) ||
                !read_le(bytes, cursor, route_count) ||
                !read_le(bytes, cursor, payload_count) ||
                index != static_cast<int32_t>(
                    family_expeditions_store().active.size()) ||
                active > 1 || generation == 0 || route_count > 8193 ||
                payload_count > 100000) {
                error = "save_family_expedition_record_invalid";
                return false;
            }
            int32_t family = -1;
            if (active != 0) {
                if (stable_id <= 0 || country_handle == 0 ||
                    !country_reads().valid_handle(
                        static_cast<int64_t>(country_handle))) {
                    error = "save_family_expedition_country_identity_invalid";
                    return false;
                }
                // family_handle 0 是无家族移民队：队伍人数全记在 anonymous 上。
                if (family_handle != 0 &&
                    !families_store().valid_handle(family_handle, family)) {
                    error = "save_family_expedition_family_handle_invalid";
                    return false;
                }
                if (source_cell < 0 || source_cell >= _cell_count.get() ||
                    target_cell < 0 || target_cell >= _cell_count.get()) {
                    error = "save_family_expedition_cell_invalid"; return false;
                }
                if (departure_day < 0 || due_day < departure_day) {
                    error = "save_family_expedition_dates_invalid"; return false;
                }
                if (route_cost < 1 || speed < 1 || route_count < 2) {
                    error = "save_family_expedition_route_invalid"; return false;
                }
                const uint8_t max_state = schema >= 42
                    ? EXPEDITION_PREPARING : EXPEDITION_RETURNING;
                if (state < EXPEDITION_OUTBOUND || state > max_state ||
                    (schema < 42 && state == EXPEDITION_PREPARING)) {
                    error = "save_family_expedition_state_invalid"; return false;
                }
                const bool preparing = state == EXPEDITION_PREPARING;
                if (population < 0 || anonymous_population < 0 ||
                    population + anonymous_population < 1 ||
                    kit_bridge_required < 0 ||
                    kit_material_required < 0 ||
                    (preparing ? payload_count != 0 : payload_count < 1)) {
                    error = "save_family_expedition_payload_header_invalid"; return false;
                }
                if (idempotency_key == 0 ||
                    (state == EXPEDITION_SETTLING && transaction_id <= 0)) {
                    error = "save_family_expedition_transaction_invalid"; return false;
                }
            }
            family_expeditions_store().active.push_back(active);
            family_expeditions_store().generation.push_back(generation);
            family_expeditions_store().stable_id.push_back(stable_id);
            family_expeditions_store().country_handle.push_back(country_handle);
            family_expeditions_store().family_handle.push_back(family_handle);
            family_expeditions_store().source_cell.push_back(source_cell);
            family_expeditions_store().target_cell.push_back(target_cell);
            family_expeditions_store().departure_day.push_back(departure_day);
            family_expeditions_store().due_day.push_back(due_day);
            family_expeditions_store().route_cost.push_back(route_cost);
            family_expeditions_store().speed.push_back(speed);
            family_expeditions_store().state.push_back(state);
            family_expeditions_store().population.push_back(population);
            family_expeditions_store().anonymous.push_back(anonymous_population);
            family_expeditions_store().kit_bridge_required_units.push_back(
                kit_bridge_required);
            family_expeditions_store().kit_material_required_units.push_back(
                kit_material_required);
            family_expeditions_store().effect_transaction_id.push_back(transaction_id);
            family_expeditions_store().idempotency_key.push_back(idempotency_key);
            family_expeditions_store().route_begin.push_back(static_cast<uint32_t>(
                family_expedition_route_cells().size()));
            family_expeditions_store().route_count.push_back(route_count);
            int32_t last_cost = -1;
            for (uint32_t route = 0; route < route_count; ++route) {
                int32_t cell = -1, cumulative = -1;
                if (!read_le(bytes, cursor, cell) ||
                    !read_le(bytes, cursor, cumulative) || active == 0 ||
                    cell < 0 || cell >= _cell_count.get() || cumulative < last_cost ||
                    (route == 0 && (cell != source_cell || cumulative != 0)) ||
                    (route + 1 == route_count &&
                     (cell != target_cell || cumulative != route_cost))) {
                    error = "save_family_expedition_route_invalid";
                    return false;
                }
                family_expedition_route_cells().push_back(cell);
                family_expedition_route_costs().push_back(cumulative);
                last_cost = cumulative;
            }
            family_expeditions_store().payload_begin.push_back(static_cast<uint32_t>(
                family_expedition_payloads().size()));
            family_expeditions_store().payload_count.push_back(payload_count);
            int64_t payload_population = 0;
            int64_t payload_anonymous = 0;
            for (uint32_t payload_index = 0; payload_index < payload_count;
                 ++payload_index) {
                FamilyExpeditionPayload lane;
                if (!read_le(bytes, cursor, lane.source_cohort_handle) ||
                    !read_le(bytes, cursor, lane.signature) ||
                    !read_le(bytes, cursor, lane.people) ||
                    !read_le(bytes, cursor, lane.funds) ||
                    !read_le(bytes, cursor, lane.epoch_income) ||
                    !read_le(bytes, cursor, lane.epoch_expense) ||
                    !read_le(bytes, cursor, lane.epoch_in_kind_income) ||
                    !read_le(bytes, cursor, lane.income_ema) ||
                    !read_le(bytes, cursor, lane.epoch_tax_paid) ||
                    !read_le(bytes, cursor, lane.epoch_subsidy_received) ||
                    !read_le(bytes, cursor, lane.income_baseline_ema) ||
                    !read_le(bytes, cursor, lane.demography_residual) ||
                    !read_le(bytes, cursor, lane.cash_claim) ||
                    !read_le(bytes, cursor, lane.owner_employed) ||
                    !read_le(bytes, cursor, lane.employee_employed) ||
                    !read_le(bytes, cursor, lane.needs_satisfaction) ||
                    !read_le(bytes, cursor, lane.worst_need_id) ||
                    !read_le(bytes, cursor, lane.composite_satisfaction) ||
                    !read_le(bytes, cursor, lane.worst_dimension_id)) {
                    error = "save_family_expedition_payload_truncated";
                    return false;
                }
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                    if (!read_le(bytes, cursor, lane.satisfaction_dims[dim])) {
                        error = "save_family_expedition_payload_truncated";
                        return false;
                    }
                if (schema >= 65 &&
                    !read_le(bytes, cursor, lane.anonymous)) {
                    error = "save_family_expedition_payload_truncated";
                    return false;
                }
                if (lane.anonymous > 1) {
                    error = "save_family_expedition_payload_invalid";
                    return false;
                }
                if (!read_le(bytes, cursor, lane.person_count) || active == 0 ||
                    lane.signature < 0 || lane.signature >= static_cast<int32_t>(
                        _signatures.size()) || lane.people <= 0 || lane.funds < 0 ||
                    lane.cash_claim < 0 || lane.owner_employed < 0 ||
                    lane.employee_employed < 0 || lane.person_count > 100000) {
                    error = "save_family_expedition_payload_invalid";
                    return false;
                }
                lane.person_begin = static_cast<uint32_t>(
                    family_expedition_person_handles().size());
                const uint32_t serialized_person_count = lane.person_count;
                uint32_t kept_person_count = 0;
                for (uint32_t person = 0; person < serialized_person_count; ++person) {
                    uint64_t person_handle = 0;
                    int32_t person_slot = -1;
                    if (!read_le(bytes, cursor, person_handle) ||
                        person_handle == 0) {
                        error = "save_family_expedition_person_invalid";
                        return false;
                    }
                    // Builds before the in-transit retirement fix retired every
                    // notable person that was travelling, so their payloads
                    // still carry a dead handle while population, funds and the
                    // attribution lanes are intact. Keep the save: drop the
                    // orphaned person lane instead of rejecting the whole world.
                    if (!persons_store().valid_handle(person_handle, person_slot)) {
                        ++_restore.dropped_transit_persons;
                        continue;
                    }
                    if (persons_store().cohort_handle[person_slot] != 0 ||
                        persons_store().family_handle[person_slot] !=
                            family_handle) {
                        error = "save_family_expedition_person_invalid";
                        return false;
                    }
                    family_expedition_person_handles().push_back(person_handle);
                    ++kept_person_count;
                }
                lane.person_count = kept_person_count;
                payload_population += lane.people;
                if (lane.anonymous != 0) payload_anonymous += lane.people;
                family_expedition_payloads().push_back(lane);
            }
            if (active != 0 && state != EXPEDITION_PREPARING &&
                (payload_population != population + anonymous_population ||
                 payload_anonymous != anonymous_population)) {
                error = "save_family_expedition_population_mismatch";
                return false;
            }
            uint32_t cargo_count = 0;
            uint32_t kit_count = 0;
            family_expeditions_store().cargo_begin.push_back(static_cast<uint32_t>(
                family_expedition_cargo().size()));
            family_expeditions_store().kit_building_begin.push_back(
                static_cast<uint32_t>(family_expedition_kit_buildings().size()));
            if (schema >= 37) {
                if (!read_le(bytes, cursor, cargo_count) ||
                    cargo_count > 100000) {
                    error = "save_family_expedition_cargo_invalid";
                    return false;
                }
                for (uint32_t c = 0; c < cargo_count; ++c) {
                    FamilyExpeditionCargoLine line;
                    if (!read_le(bytes, cursor, line.good_id) ||
                        !read_le(bytes, cursor, line.quantity) ||
                        !read_le(bytes, cursor, line.flags) ||
                        line.good_id < 0 || line.good_id >= market_store().good_count.get() ||
                        line.quantity <= 0 ||
                        (line.flags != EXPEDITION_CARGO_CONSTRUCTION &&
                         line.flags != EXPEDITION_CARGO_BUFFER) ||
                        active == 0) {
                        error = "save_family_expedition_cargo_invalid";
                        return false;
                    }
                    family_expedition_cargo().push_back(line);
                }
                if (!read_le(bytes, cursor, kit_count) || kit_count > 100000) {
                    error = "save_family_expedition_kit_invalid";
                    return false;
                }
                for (uint32_t k = 0; k < kit_count; ++k) {
                    FamilyExpeditionKitBuilding row;
                    if (!read_le(bytes, cursor, row.type_id) ||
                        !read_le(bytes, cursor, row.count) ||
                        row.type_id < 0 ||
                        row.type_id >= static_cast<int32_t>(
                            _building_types.size()) ||
                        row.count <= 0 || active == 0) {
                        error = "save_family_expedition_kit_invalid";
                        return false;
                    }
                    family_expedition_kit_buildings().push_back(row);
                }
            }
            family_expeditions_store().cargo_count.push_back(cargo_count);
            family_expeditions_store().kit_building_count.push_back(kit_count);
            uint64_t missing_identity = 0;
            uint32_t missing_count = 0;
            family_expeditions_store().missing_good_begin.push_back(
                static_cast<uint32_t>(family_expedition_missing_good_ids().size()));
            if (schema >= 42) {
                if (!read_le(bytes, cursor, missing_identity) ||
                    !read_le(bytes, cursor, missing_count) ||
                    missing_count > 100000) {
                    error = "save_family_expedition_missing_invalid";
                    return false;
                }
                for (uint32_t m = 0; m < missing_count; ++m) {
                    int32_t good_id = -1;
                    int64_t quantity = 0;
                    if (!read_le(bytes, cursor, good_id) ||
                        !read_le(bytes, cursor, quantity) ||
                        good_id < 0 || quantity < 0 || active == 0) {
                        error = "save_family_expedition_missing_invalid";
                        return false;
                    }
                    family_expedition_missing_good_ids().push_back(good_id);
                    family_expedition_missing_good_quantities().push_back(quantity);
                }
            }
            // A preparing party holds no people and has not committed to a
            // building plan yet, but it may already escrow the goods it has
            // stocked from the source market day by day.
            if (active != 0 && state == EXPEDITION_PREPARING &&
                (payload_count != 0 || kit_count != 0)) {
                error = "save_family_expedition_preparing_payload_invalid";
                return false;
            }
            family_expeditions_store().kit_missing_stock_identity.push_back(
                missing_identity);
            family_expeditions_store().missing_good_count.push_back(missing_count);
            if (active != 0) {
                ++family_expeditions_store().active_count;
                ++_restore.restored_family_expeditions;
            } else {
                family_expeditions_store().free_indices.push_back(index);
            }
            ++_restore.restored_family_expedition_slots;
        }
        _restore.family_expeditions_seen = true;
    }
    return true;
}

} // namespace pk
