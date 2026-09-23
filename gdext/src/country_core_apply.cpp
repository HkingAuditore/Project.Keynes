#include "country_core_apply.h"

#include "country_core.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace {
constexpr uint32_t COUNTRY_QUEUE_SLOTS = 8u;
}

namespace pk {

bool country_core_validate_target(
        const RuntimeCountryPodSnapshot &state,
        const RuntimeCountryCommand &command, int32_t &slot,
        std::string &error) {
    slot = -1;
    const uint32_t raw_slot = static_cast<uint32_t>(command.target_handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(command.target_handle >> 32u);
    if (command.target_handle == 0 || raw_slot >= state.country_count ||
        state.country_active[raw_slot] == 0 ||
        state.country_generation[raw_slot] != generation) {
        error = "country_handle_invalid";
        return false;
    }
    slot = static_cast<int32_t>(raw_slot);
    return true;
}

bool country_core_research_condition_met(
        const RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog, int32_t slot,
        int32_t technology) {
    if (!catalog.research_conditions_complete || slot < 0 ||
        slot >= static_cast<int32_t>(state.country_count) || technology < 0 ||
        technology >= static_cast<int32_t>(catalog.technology_count)) return false;
    if (catalog.research_condition_offsets.size() !=
        static_cast<size_t>(catalog.technology_count) + 1u) return false;
    const int32_t begin = catalog.research_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end = catalog.research_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin < 0 || end < begin || end > static_cast<int32_t>(catalog.research_condition_ops.size()))
        return false;
    if (begin == end) return true;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t word_base = static_cast<size_t>(slot) * catalog.technology_words;
    const auto has_technology = [&](int32_t ref) {
        return ref >= 0 && ref < static_cast<int32_t>(catalog.technology_count) &&
               (state.country_technologies[word_base + static_cast<size_t>(ref / 64)] &
                (uint64_t{1} << (ref % 64))) != 0;
    };
    const auto has_signal = [&](int32_t ref) {
        if (ref < 0 || ref >= static_cast<int32_t>(state.research_signal_count) ||
            state.research_signal_words == 0 ||
            state.country_research_signals.size() !=
                static_cast<size_t>(state.country_count) * state.research_signal_words)
            return false;
        const size_t index = static_cast<size_t>(slot) * state.research_signal_words +
                             static_cast<size_t>(ref / 64);
        return index < state.country_research_signals.size() &&
               (state.country_research_signals[index] & (uint64_t{1} << (ref % 64))) != 0;
    };
    const auto signal_count = [&](int32_t ref) {
        if (ref < 0 || ref >= static_cast<int32_t>(state.research_signal_count) ||
            state.research_signal_evidence_offsets.size() !=
                static_cast<size_t>(state.country_count) + 1u)
            return int32_t{0};
        const int32_t first = state.research_signal_evidence_offsets[static_cast<size_t>(slot)];
        const int32_t last = state.research_signal_evidence_offsets[static_cast<size_t>(slot + 1)];
        for (int32_t i = first; i < last; ++i)
            if (state.research_signal_evidence[static_cast<size_t>(i)].signal == ref)
                return state.research_signal_evidence[static_cast<size_t>(i)].count;
        return int32_t{0};
    };
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op = catalog.research_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref = catalog.research_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value = catalog.research_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size()) || ref < 0 ||
                ref >= static_cast<int32_t>(catalog.technology_count)) return false;
            stack[static_cast<size_t>(depth++)] = has_technology(ref) ? 1u : 0u;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] = has_signal(ref) ? 1u : 0u;
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] = signal_count(ref) >= value ? 1u : 0u;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1u : 0u;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i)
                truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            stack[static_cast<size_t>(depth++)] = op == 10
                ? (truth_count == ref ? 1u : 0u)
                : (op == 11 ? (truth_count > 0 ? 1u : 0u)
                            : (truth_count >= value ? 1u : 0u));
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

bool country_core_technology_prerequisites_met(
        const RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog, int32_t slot,
        int32_t technology) {
    if (technology < 0 || technology >= static_cast<int32_t>(catalog.technology_count) ||
        slot < 0 || slot >= static_cast<int32_t>(state.country_count)) return false;
    const size_t base = static_cast<size_t>(slot) * catalog.technology_words;
    const auto has = [&](int32_t ref) {
        return ref >= 0 && ref < static_cast<int32_t>(catalog.technology_count) &&
               (state.country_technologies[base + static_cast<size_t>(ref / 64)] &
                (uint64_t{1} << (ref % 64))) != 0;
    };
    if (technology < static_cast<int32_t>(catalog.entry_milestone_indices.size())) {
        const int32_t entry = catalog.entry_milestone_indices[static_cast<size_t>(technology)];
        if (entry >= 0 && !has(entry)) return false;
    }
    const int32_t milestone_begin = catalog.milestone_offsets.empty()
        ? 0 : catalog.milestone_offsets[static_cast<size_t>(technology)];
    const int32_t milestone_end = catalog.milestone_offsets.empty()
        ? 0 : catalog.milestone_offsets[static_cast<size_t>(technology + 1)];
    if (milestone_end > milestone_begin) {
        int32_t count = 0;
        for (int32_t edge = milestone_begin; edge < milestone_end; ++edge)
            if (has(catalog.milestone_candidates[static_cast<size_t>(edge)])) ++count;
        return count >= catalog.milestone_required_counts[static_cast<size_t>(technology)];
    }
    const int32_t begin = catalog.prerequisite_offsets[static_cast<size_t>(technology)];
    const int32_t end = catalog.prerequisite_offsets[static_cast<size_t>(technology + 1)];
    for (int32_t edge = begin; edge < end; ++edge)
        if (!has(catalog.prerequisites[static_cast<size_t>(edge)])) return false;
    return true;
}

static bool country_core_reveal_condition_met(
        const RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog, int32_t slot,
        int32_t technology) {
    if (slot < 0 || slot >= static_cast<int32_t>(state.country_count) ||
        technology < 0 ||
        technology >= static_cast<int32_t>(catalog.technology_count) ||
        catalog.reveal_condition_offsets.size() !=
            static_cast<size_t>(catalog.technology_count) + 1u)
        return false;
    const int32_t begin =
        catalog.reveal_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end =
        catalog.reveal_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin < 0 || end <= begin ||
        end > static_cast<int32_t>(catalog.reveal_condition_ops.size()))
        return false;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t technology_base =
        static_cast<size_t>(slot) * catalog.technology_words;
    const auto has_technology = [&](int32_t ref) {
        return ref >= 0 &&
               ref < static_cast<int32_t>(catalog.technology_count) &&
               (state.country_technologies[
                    technology_base + static_cast<size_t>(ref / 64)] &
                (uint64_t{1} << (ref % 64))) != 0;
    };
    const auto has_signal = [&](int32_t ref) {
        if (ref < 0 || ref >= static_cast<int32_t>(state.research_signal_count) ||
            state.research_signal_words == 0) return false;
        const size_t index =
            static_cast<size_t>(slot) * state.research_signal_words +
            static_cast<size_t>(ref / 64);
        return index < state.country_research_signals.size() &&
               (state.country_research_signals[index] &
                (uint64_t{1} << (ref % 64))) != 0;
    };
    const auto signal_count = [&](int32_t ref) {
        if (ref < 0 || ref >= static_cast<int32_t>(state.research_signal_count) ||
            state.research_signal_evidence_offsets.size() !=
                static_cast<size_t>(state.country_count) + 1u)
            return int32_t{0};
        const int32_t first =
            state.research_signal_evidence_offsets[static_cast<size_t>(slot)];
        const int32_t last =
            state.research_signal_evidence_offsets[static_cast<size_t>(slot + 1)];
        for (int32_t i = first; i < last; ++i)
            if (state.research_signal_evidence[static_cast<size_t>(i)].signal == ref)
                return state.research_signal_evidence[static_cast<size_t>(i)].count;
        return int32_t{0};
    };
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op =
            catalog.reveal_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref =
            catalog.reveal_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value =
            catalog.reveal_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] =
                has_technology(ref) ? 1u : 0u;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] = has_signal(ref) ? 1u : 0u;
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] =
                signal_count(ref) >= value ? 1u : 0u;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1u : 0u;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i)
                truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            stack[static_cast<size_t>(depth++)] = op == 10
                ? (truth_count == ref ? 1u : 0u)
                : (op == 11 ? (truth_count > 0 ? 1u : 0u)
                            : (truth_count >= value ? 1u : 0u));
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

void country_core_refresh_discovery(
        RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog, int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(state.country_count)) return;
    const size_t base = static_cast<size_t>(slot) * catalog.technology_words;
    for (int32_t technology = 0;
         technology < static_cast<int32_t>(catalog.technology_count);
         ++technology) {
        const uint64_t bit = uint64_t{1} << (technology % 64);
        const size_t word = base + static_cast<size_t>(technology / 64);
        if ((state.country_technologies[word] & bit) != 0) {
            state.country_discovered[word] |= bit;
            continue;
        }
        const int32_t reveal_begin =
            catalog.reveal_condition_offsets[static_cast<size_t>(technology)];
        const int32_t reveal_end =
            catalog.reveal_condition_offsets[static_cast<size_t>(technology + 1)];
        const bool has_reveal_condition = reveal_end > reveal_begin;
        if (has_reveal_condition &&
            !country_core_reveal_condition_met(
                state, catalog, slot, technology))
            continue;
        bool reveal = false;
        const int32_t milestone_begin = catalog.milestone_offsets.empty()
            ? 0 : catalog.milestone_offsets[static_cast<size_t>(technology)];
        const int32_t milestone_end = catalog.milestone_offsets.empty()
            ? 0 : catalog.milestone_offsets[static_cast<size_t>(technology + 1)];
        if (milestone_end > milestone_begin) {
            for (int32_t edge = milestone_begin;
                 edge < milestone_end && !reveal; ++edge) {
                const int32_t candidate =
                    catalog.milestone_candidates[static_cast<size_t>(edge)];
                reveal = (state.country_technologies[
                    base + static_cast<size_t>(candidate / 64)] &
                    (uint64_t{1} << (candidate % 64))) != 0;
            }
        } else {
            const int32_t begin =
                catalog.prerequisite_offsets[static_cast<size_t>(technology)];
            const int32_t end =
                catalog.prerequisite_offsets[static_cast<size_t>(technology + 1)];
            for (int32_t edge = begin; edge < end && !reveal; ++edge) {
                const int32_t prerequisite =
                    catalog.prerequisites[static_cast<size_t>(edge)];
                reveal = (state.country_technologies[
                    base + static_cast<size_t>(prerequisite / 64)] &
                    (uint64_t{1} << (prerequisite % 64))) != 0;
            }
        }
        if (reveal || has_reveal_condition)
            state.country_discovered[word] |= bit;
    }
}

bool country_core_apply_command(
        RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog,
        const RuntimeCountryCommand &command,
        RuntimeCountryPodPlan &plan, std::string &error) {
    error.clear();
    int32_t slot = -1;
    constexpr int32_t TAX_INHERIT = std::numeric_limits<int32_t>::min();
    constexpr int32_t TAX_MODE_INHERIT = std::numeric_limits<int32_t>::min();
    constexpr int32_t TAX_MODE_PERCENT = 0;
    constexpr int32_t TAX_MODE_ABSOLUTE = 1;
    const auto tax_item_count = [&](int32_t kind) -> int32_t {
        if (kind == 0) return static_cast<int32_t>(state.profession_count);
        if (kind == 2) return static_cast<int32_t>(state.building_type_count);
        if (kind == 1 || kind == 3 || kind == 4)
            return static_cast<int32_t>(state.good_count);
        return 0;
    };
    const auto tax_value_valid = [&](int32_t mode, int32_t value) {
        if (mode == TAX_MODE_PERCENT)
            return value >= -100000 && value <= 10000;
        if (mode == TAX_MODE_ABSOLUTE)
            return value >= -1000000000 && value <= 1000000000;
        return false;
    };
    const auto copy_fixed = [](const std::array<char, RUNTIME_COUNTRY_STABLE_ID_CAPACITY> &value) {
        return std::string(value.data());
    };
    const auto copy_display = [](const std::array<char, RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY> &value) {
        return std::string(value.data());
    };
    const auto ensure_cell_policy = [&](int32_t cell) -> RuntimeCountryPodSnapshot::CellTaxPolicy * {
        if (cell < 0 || cell >= static_cast<int32_t>(state.cell_tax_policy_ids.size()) ||
            state.cell_tax_policies.empty()) return nullptr;
        uint32_t policy_id = state.cell_tax_policy_ids[static_cast<size_t>(cell)];
        if (policy_id >= state.cell_tax_policies.size()) return nullptr;
        state.cell_tax_policies.push_back(state.cell_tax_policies[policy_id]);
        state.cell_tax_policy_ids[static_cast<size_t>(cell)] =
            static_cast<uint32_t>(state.cell_tax_policies.size() - 1u);
        return &state.cell_tax_policies.back();
    };
    const auto country_tax_vectors = [&](int32_t kind,
            std::vector<int32_t> *&rates, std::vector<int32_t> *&modes) {
        rates = nullptr; modes = nullptr;
        switch (kind) {
        case 0: rates = &state.country_income_tax_overrides;
                modes = &state.country_income_tax_mode_overrides; break;
        case 1: rates = &state.country_consumption_tax_overrides;
                modes = &state.country_consumption_tax_mode_overrides; break;
        case 2: rates = &state.country_business_tax_overrides;
                modes = &state.country_business_tax_mode_overrides; break;
        case 3: rates = &state.country_import_tax_overrides;
                modes = &state.country_import_tax_mode_overrides; break;
        case 4: rates = &state.country_export_tax_overrides;
                modes = &state.country_export_tax_mode_overrides; break;
        default: break;
        }
    };
    switch (command.opcode) {
    case 1: { // create country
        const std::string stable_id = copy_fixed(command.stable_id);
        const std::string display_name = copy_display(command.display_name);
        if (stable_id.empty() || display_name.empty() ||
            std::find(state.country_stable_ids.begin(), state.country_stable_ids.end(),
                      stable_id) != state.country_stable_ids.end()) {
            error = "country_create_identity_invalid";
            return false;
        }
        if (command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count) ||
            (!state.is_water.empty() && state.is_water[static_cast<size_t>(command.cell)] != 0)) {
            error = "country_create_territory_invalid";
            return false;
        }
        const int32_t old_owner = state.cell_country_slot[static_cast<size_t>(command.cell)];
        const int32_t new_slot = static_cast<int32_t>(state.country_count);
        ++state.country_count;
        state.country_active.push_back(1);
        state.country_generation.push_back(1);
        state.country_stable_ids.push_back(stable_id);
        state.country_display_names.push_back(display_name);
        state.territory_count.push_back(1);
        state.country_state_version.push_back(1);
        state.country_cash.push_back(0);
        state.country_technologies.insert(state.country_technologies.end(), state.technology_words, 0);
        state.country_discovered.insert(state.country_discovered.end(), state.technology_words, 0);
        state.country_pending_technologies.insert(state.country_pending_technologies.end(), state.technology_words, 0);
        state.country_goods.insert(state.country_goods.end(), state.good_count, 0);
        state.research_progress.insert(state.research_progress.end(), state.technology_count, 0);
        state.research_queues.insert(state.research_queues.end(),
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT * COUNTRY_QUEUE_SLOTS, -1);
        state.research_queue_lengths.insert(state.research_queue_lengths.end(),
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT, 0);
        state.research_weights_bp.insert(state.research_weights_bp.end(),
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT, 2500);
        state.research_daily_budgets.push_back(1000 * 10000);
        state.research_deferred_points.push_back(0);
        state.research_progress_total.push_back(0);
        state.research_completed_total.push_back(0);
        state.research_auto_purchase.push_back(1);
        state.research_purchased_total.push_back(0);
        state.research_consumed_total.push_back(0);
        state.research_peer_flags.insert(state.research_peer_flags.end(), state.technology_count, 0);
        state.research_signal_cell_offsets.push_back(
            state.research_signal_cell_offsets.back());
        state.research_signal_evidence_offsets.push_back(
            state.research_signal_evidence_offsets.back());
        state.country_tax_defaults.insert(state.country_tax_defaults.end(),
            RuntimeCountryPodSnapshot::TAX_KIND_COUNT, 0);
        state.country_tax_default_modes.insert(state.country_tax_default_modes.end(),
            RuntimeCountryPodSnapshot::TAX_KIND_COUNT, TAX_MODE_PERCENT);
        const auto add_tax_arrays = [&](std::vector<int32_t> &rates,
                                        std::vector<int32_t> &modes,
                                        int32_t count) {
            rates.insert(rates.end(), count, TAX_INHERIT);
            modes.insert(modes.end(), count, TAX_MODE_INHERIT);
        };
        add_tax_arrays(state.country_income_tax_overrides, state.country_income_tax_mode_overrides,
                       static_cast<int32_t>(state.profession_count));
        add_tax_arrays(state.country_consumption_tax_overrides, state.country_consumption_tax_mode_overrides,
                       static_cast<int32_t>(state.good_count));
        add_tax_arrays(state.country_business_tax_overrides, state.country_business_tax_mode_overrides,
                       static_cast<int32_t>(state.building_type_count));
        add_tax_arrays(state.country_import_tax_overrides, state.country_import_tax_mode_overrides,
                       static_cast<int32_t>(state.good_count));
        add_tax_arrays(state.country_export_tax_overrides, state.country_export_tax_mode_overrides,
                       static_cast<int32_t>(state.good_count));
        if (old_owner >= 0) {
            if (state.territory_count[static_cast<size_t>(old_owner)] <= 0) {
                error = "country_territory_count_underflow";
                return false;
            }
            --state.territory_count[static_cast<size_t>(old_owner)];
            for (uint32_t word = 0; word < state.technology_words; ++word) {
                state.country_technologies[static_cast<size_t>(new_slot) * state.technology_words + word] =
                    state.country_technologies[static_cast<size_t>(old_owner) * state.technology_words + word];
                state.country_discovered[static_cast<size_t>(new_slot) * state.technology_words + word] =
                    state.country_discovered[static_cast<size_t>(old_owner) * state.technology_words + word];
            }
        } else {
            for (const int32_t technology : catalog.starting_technologies) {
                if (technology < 0 || technology >= static_cast<int32_t>(state.technology_count)) continue;
                const size_t word = static_cast<size_t>(new_slot) * state.technology_words + technology / 64u;
                const uint64_t bit = uint64_t{1} << (technology % 64u);
                state.country_technologies[word] |= bit;
                state.country_discovered[word] |= bit;
            }
        }
        state.cell_country_slot[static_cast<size_t>(command.cell)] = new_slot;
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY |
                                      RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 2: { // rename country
        if (!country_core_validate_target(state, command, slot, error)) return false;
        const std::string display_name = copy_display(command.display_name);
        if (display_name.empty()) { error = "country_name_empty"; return false; }
        state.country_display_names[static_cast<size_t>(slot)] = display_name;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 3: // transfer territory / claim unowned when target_handle is zero
    case 20: {
        if (command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count) ||
            (!state.is_water.empty() && state.is_water[static_cast<size_t>(command.cell)] != 0)) {
            error = "country_transfer_cell_invalid";
            return false;
        }
        if (command.opcode == 20 && command.target_handle == 0) {
            error = "country_claim_target_missing";
            return false;
        }
        if (command.target_handle != 0 && !country_core_validate_target(state, command, slot, error))
            return false;
        const int32_t old_owner = state.cell_country_slot[static_cast<size_t>(command.cell)];
        if (command.opcode == 20 && old_owner != -1) {
            error = "country_claim_target_not_unowned";
            return false;
        }
        const int32_t target = slot;
        if (old_owner == target) return true;
        if (old_owner >= 0) {
            if (state.territory_count[static_cast<size_t>(old_owner)] <= 0) {
                error = "country_territory_count_underflow";
                return false;
            }
            --state.territory_count[static_cast<size_t>(old_owner)];
            ++state.country_state_version[static_cast<size_t>(old_owner)];
        }
        ++state.territory_count[static_cast<size_t>(target)];
        ++state.country_state_version[static_cast<size_t>(target)];
        state.cell_country_slot[static_cast<size_t>(command.cell)] = target;
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY |
                                      RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 4: // grant technology: completion is an Effect ACK boundary
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(catalog.technology_count)) {
            error = "country_technology_invalid";
            return false;
        }
        {
            const size_t word = static_cast<size_t>(slot) * catalog.technology_words +
                                static_cast<size_t>(command.aux / 64);
            const uint64_t bit = uint64_t{1} << (command.aux % 64);
            if ((state.country_technologies[word] & bit) == 0) {
                state.country_pending_technologies[word] |= bit;
                ++state.country_state_version[static_cast<size_t>(slot)];
                RuntimeDomainIntent intent;
                intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
                intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
                // `RuntimeDomainIntent::opcode` is the peer operation at this
                // boundary, not the originating Country command opcode.  The
                // two enums intentionally do not share a wire namespace:
                // GRANT_TECHNOLOGY is Country command 4, while ENSURE is peer
                // operation 1.  Keeping the typed peer opcode here prevents
                // the Host adapter from having to guess which semantic was
                // intended from an overlapping integer value.
                intent.opcode = static_cast<uint16_t>(
                    CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT);
                intent.source_id = command.request_id;
                intent.target_handle = command.target_handle;
                intent.target_generation = state.country_generation[static_cast<size_t>(slot)];
                intent.effective_day = command.effective_day;
                intent.payload[0] = command.aux;
                plan.intents.push_back(intent);
                ++plan.required_ack_count;
                plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            }
        }
        return true;
    case 5: // set research weights
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (!runtime_country_research_weights_valid(command.weights_bp)) {
            error = "country_research_weight_total_invalid";
            return false;
        }
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            state.research_weights_bp[static_cast<size_t>(slot) *
                                      RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT + domain] =
                command.weights_bp[domain];
        state.research_deferred_points[static_cast<size_t>(slot)] = 0;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    case 6: // enqueue research; full condition CSR is mandatory
    case 8: { // move research
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (!catalog.research_conditions_complete) {
            error = "countrycatalog_research_conditions_missing";
            return false;
        }
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(catalog.technology_count) ||
            command.domain < 0 || command.domain >= static_cast<int32_t>(RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) ||
            command.position < -1 || command.position >= static_cast<int32_t>(COUNTRY_QUEUE_SLOTS)) {
            error = "country_research_queue_argument_invalid";
            return false;
        }
        const size_t word = static_cast<size_t>(slot) * catalog.technology_words +
                            static_cast<size_t>(command.aux / 64);
        const uint64_t bit = uint64_t{1} << (command.aux % 64);
        if ((state.country_discovered[word] & bit) == 0 ||
            (state.country_technologies[word] & bit) != 0 ||
            (state.country_pending_technologies[word] & bit) != 0) {
            error = "country_research_technology_unavailable";
            return false;
        }
        if (!country_core_technology_prerequisites_met(state, catalog, slot, command.aux) ||
            !country_core_research_condition_met(state, catalog, slot, command.aux)) {
            error = "country_research_requirements_incomplete";
            return false;
        }
        if (catalog.technology_domains[static_cast<size_t>(command.aux)] != command.domain) {
            error = "country_research_domain_mismatch";
            return false;
        }
        const size_t country_base = static_cast<size_t>(slot) *
                                    RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        int32_t found_domain = -1, found_position = -1;
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const size_t length_index = country_base + domain;
            const size_t queue_base = length_index * COUNTRY_QUEUE_SLOTS;
            for (uint32_t position = 0; position < state.research_queue_lengths[length_index]; ++position)
                if (state.research_queues[queue_base + position] == command.aux) {
                    found_domain = static_cast<int32_t>(domain);
                    found_position = static_cast<int32_t>(position);
                }
        }
        if (command.opcode == 6 && found_domain >= 0) {
            error = "country_research_already_queued";
            return false;
        }
        if (command.opcode == 8 && found_domain < 0) {
            error = "country_research_not_queued";
            return false;
        }
        if (found_domain >= 0) {
            const size_t old_index = country_base + static_cast<size_t>(found_domain);
            const size_t old_base = old_index * COUNTRY_QUEUE_SLOTS;
            uint8_t &old_length = state.research_queue_lengths[old_index];
            for (int32_t i = found_position + 1; i < old_length; ++i)
                state.research_queues[old_base + static_cast<size_t>(i - 1)] =
                    state.research_queues[old_base + static_cast<size_t>(i)];
            state.research_queues[old_base + static_cast<size_t>(--old_length)] = -1;
        }
        const size_t index = country_base + static_cast<size_t>(command.domain);
        const size_t base = index * COUNTRY_QUEUE_SLOTS;
        uint8_t &length = state.research_queue_lengths[index];
        if (length >= COUNTRY_QUEUE_SLOTS) {
            error = "country_research_queue_full";
            return false;
        }
        const int32_t insert_at = command.position < 0
            ? static_cast<int32_t>(length)
            : std::min<int32_t>(command.position, length);
        for (int32_t i = length; i > insert_at; --i)
            state.research_queues[base + static_cast<size_t>(i)] =
                state.research_queues[base + static_cast<size_t>(i - 1)];
        state.research_queues[base + static_cast<size_t>(insert_at)] = command.aux;
        ++length;
        state.research_deferred_points[static_cast<size_t>(slot)] = 0;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 7: { // remove research
        if (!country_core_validate_target(state, command, slot, error)) return false;
        bool removed = false;
        const size_t country_base = static_cast<size_t>(slot) *
                                    RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT && !removed; ++domain) {
            const size_t index = country_base + domain;
            const size_t base = index * COUNTRY_QUEUE_SLOTS;
            uint8_t &length = state.research_queue_lengths[index];
            for (uint32_t position = 0; position < length; ++position) {
                if (state.research_queues[base + position] != command.aux) continue;
                for (uint32_t i = position + 1; i < length; ++i)
                    state.research_queues[base + i - 1u] = state.research_queues[base + i];
                state.research_queues[base + --length] = -1;
                removed = true;
                break;
            }
        }
        if (!removed) {
            error = "country_research_not_queued";
            return false;
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 9: // budget and auto purchase
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.value < 0 || (command.aux != 0 && command.aux != 1)) {
            error = "country_research_budget_invalid";
            return false;
        }
        state.research_daily_budgets[static_cast<size_t>(slot)] = command.value;
        state.research_auto_purchase[static_cast<size_t>(slot)] =
            static_cast<uint8_t>(command.aux);
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    case 10: // reveal all technologies
        if (!country_core_validate_target(state, command, slot, error)) return false;
        for (uint32_t tech = 0; tech < catalog.technology_count; ++tech)
            state.country_discovered[static_cast<size_t>(slot) * catalog.technology_words +
                                      tech / 64u] |= uint64_t{1} << (tech % 64u);
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    case 11: // country tax default
    case 12: // country tax override
    case 13: { // clear country tax override
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.tax_kind < 0 || command.tax_kind >= static_cast<int32_t>(RuntimeCountryPodSnapshot::TAX_KIND_COUNT)) {
            error = "country_tax_kind_invalid"; return false;
        }
        const bool needs_value = command.opcode != 13;
        if (needs_value && !tax_value_valid(command.tax_assessment_mode,
                                            command.tax_rate_basis_points)) {
            error = "country_tax_command_invalid"; return false;
        }
        if (command.opcode == 11) {
            const size_t index = static_cast<size_t>(slot) * RuntimeCountryPodSnapshot::TAX_KIND_COUNT + command.tax_kind;
            state.country_tax_defaults[index] = command.tax_rate_basis_points;
            state.country_tax_default_modes[index] = command.tax_assessment_mode;
        } else {
            const int32_t count = tax_item_count(command.tax_kind);
            if (command.tax_item < 0 || command.tax_item >= count) {
                error = "country_tax_item_invalid"; return false;
            }
            std::vector<int32_t> *rates = nullptr, *modes = nullptr;
            country_tax_vectors(command.tax_kind, rates, modes);
            const size_t index = static_cast<size_t>(slot) * count + command.tax_item;
            (*rates)[index] = command.opcode == 13 ? TAX_INHERIT : command.tax_rate_basis_points;
            (*modes)[index] = command.opcode == 13 ? TAX_MODE_INHERIT : command.tax_assessment_mode;
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 14: { // discover country signal
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(state.research_signal_count) ||
            command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count)) {
            error = "country_research_signal_command_invalid"; return false;
        }
        const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(command.aux)) << 32u) |
                             static_cast<uint32_t>(command.cell);
        const size_t begin = static_cast<size_t>(state.research_signal_cell_offsets[static_cast<size_t>(slot)]);
        const size_t end = static_cast<size_t>(state.research_signal_cell_offsets[static_cast<size_t>(slot) + 1u]);
        auto cells = state.research_signal_cells.begin() + static_cast<ptrdiff_t>(begin);
        auto cells_end = state.research_signal_cells.begin() + static_cast<ptrdiff_t>(end);
        auto found = std::lower_bound(cells, cells_end, key);
        if (found != cells_end && *found == key) {
            // Production refreshes the reveal frontier for every admitted
            // signal command, including duplicate observations. A prerequisite
            // may have completed since the first observation, so an early
            // no-op return here would leave worker discovery stale.
            country_core_refresh_discovery(state, catalog, slot);
            plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            return true;
        }
        const size_t insertion = static_cast<size_t>(found - state.research_signal_cells.begin());
        state.research_signal_cells.insert(state.research_signal_cells.begin() + static_cast<ptrdiff_t>(insertion), key);
        for (size_t index = static_cast<size_t>(slot) + 1u; index < state.research_signal_cell_offsets.size(); ++index)
            ++state.research_signal_cell_offsets[index];
        const size_t evidence_begin = static_cast<size_t>(state.research_signal_evidence_offsets[static_cast<size_t>(slot)]);
        const size_t evidence_end = static_cast<size_t>(state.research_signal_evidence_offsets[static_cast<size_t>(slot) + 1u]);
        auto evidence = state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_begin);
        auto evidence_end_it = state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_end);
        auto evidence_it = std::lower_bound(evidence, evidence_end_it, command.aux,
            [](const RuntimeCountryPodSnapshot::SignalEvidence &entry, int32_t signal) {
                return entry.signal < signal;
            });
        if (evidence_it == evidence_end_it || evidence_it->signal != command.aux) {
            RuntimeCountryPodSnapshot::SignalEvidence entry;
            entry.signal = command.aux; entry.count = 0;
            entry.first_day = command.effective_day;
            entry.last_day = command.effective_day;
            entry.first_cell = command.cell;
            const size_t evidence_index = static_cast<size_t>(evidence_it - state.research_signal_evidence.begin());
            state.research_signal_evidence.insert(state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_index), entry);
            for (size_t index = static_cast<size_t>(slot) + 1u; index < state.research_signal_evidence_offsets.size(); ++index)
                ++state.research_signal_evidence_offsets[index];
            evidence_it = state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_index);
        }
        ++evidence_it->count;
        evidence_it->last_day = command.effective_day;
        if (state.research_signal_words > 0)
            state.country_research_signals[static_cast<size_t>(slot) * state.research_signal_words + command.aux / 64] |=
                uint64_t{1} << (command.aux % 64);
        country_core_refresh_discovery(state, catalog, slot);
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 15: // cell tax default
    case 16: // clear cell tax default
    case 17: // cell tax override
    case 18: // clear cell tax override
    case 19: { // clear cell tax policy
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count) ||
            (!state.is_water.empty() && state.is_water[static_cast<size_t>(command.cell)] != 0) ||
            state.cell_country_slot[static_cast<size_t>(command.cell)] != slot) {
            error = "country_cell_tax_territory_invalid"; return false;
        }
        if (command.opcode == 19) {
            state.cell_tax_policy_ids[static_cast<size_t>(command.cell)] = 0;
        } else {
            auto *policy = ensure_cell_policy(command.cell);
            if (policy == nullptr) { error = "country_cell_tax_policy_invalid"; return false; }
            if (command.tax_kind < 0 || command.tax_kind >= static_cast<int32_t>(RuntimeCountryPodSnapshot::TAX_KIND_COUNT)) {
                error = "country_cell_tax_kind_invalid"; return false;
            }
            if (command.opcode == 15 || command.opcode == 16) {
                if (command.opcode == 15 && !tax_value_valid(command.tax_assessment_mode, command.tax_rate_basis_points)) {
                    error = "country_cell_tax_rate_invalid"; return false;
                }
                policy->defaults[static_cast<size_t>(command.tax_kind)] = command.opcode == 16 ? TAX_INHERIT : command.tax_rate_basis_points;
                policy->modes[static_cast<size_t>(command.tax_kind)] = command.opcode == 16 ? TAX_MODE_INHERIT : command.tax_assessment_mode;
            } else {
                const int32_t count = tax_item_count(command.tax_kind);
                if (command.tax_item < 0 || command.tax_item >= count) { error = "country_cell_tax_item_invalid"; return false; }
                auto entry = std::lower_bound(policy->overrides.begin(), policy->overrides.end(),
                    std::pair<int32_t, int32_t>{command.tax_kind, command.tax_item},
                    [](const RuntimeCountryPodSnapshot::CellTaxOverride &value,
                       const std::pair<int32_t, int32_t> &key) {
                        return value.kind < key.first || (value.kind == key.first && value.item < key.second);
                    });
                if (command.opcode == 18) {
                    if (entry != policy->overrides.end() && entry->kind == command.tax_kind && entry->item == command.tax_item)
                        policy->overrides.erase(entry);
                } else {
                    if (!tax_value_valid(command.tax_assessment_mode, command.tax_rate_basis_points)) { error = "country_cell_tax_rate_invalid"; return false; }
                    RuntimeCountryPodSnapshot::CellTaxOverride replacement{command.tax_kind, command.tax_item, command.tax_rate_basis_points, command.tax_assessment_mode};
                    if (entry != policy->overrides.end() && entry->kind == command.tax_kind && entry->item == command.tax_item) *entry = replacement;
                    else policy->overrides.insert(entry, replacement);
                }
            }
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    default:
        error = "country_command_capture_contract_missing";
        return false;
    }
}

void country_core_rebuild_territory_csr(RuntimeCountryPodSnapshot &state) {
    state.territory_offsets.assign(static_cast<size_t>(state.country_count) + 1u, 0);
    for (int32_t owner : state.cell_country_slot)
        if (owner >= 0 && owner < static_cast<int32_t>(state.country_count))
            ++state.territory_offsets[static_cast<size_t>(owner) + 1u];
    for (size_t i = 1; i < state.territory_offsets.size(); ++i)
        state.territory_offsets[i] += state.territory_offsets[i - 1u];
    state.territory_cells.assign(state.territory_offsets.back(), -1);
    std::vector<int32_t> cursor = state.territory_offsets;
    for (int32_t cell = 0; cell < static_cast<int32_t>(state.cell_country_slot.size()); ++cell) {
        const int32_t owner = state.cell_country_slot[static_cast<size_t>(cell)];
        if (owner < 0 || owner >= static_cast<int32_t>(state.country_count)) continue;
        state.territory_cells[static_cast<size_t>(cursor[static_cast<size_t>(owner)]++)] = cell;
    }
    state.territory_count.assign(state.country_count, 0);
    for (uint32_t slot = 0; slot < state.country_count; ++slot)
        state.territory_count[slot] = state.territory_offsets[slot + 1u] -
                                      state.territory_offsets[slot];
}

namespace {

int32_t country_core_slot_from_handle(const RuntimeCountryPodSnapshot &state,
                                      uint64_t handle) {
    if (handle == 0) return -1;
    const uint32_t raw_slot = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32u);
    if (raw_slot >= state.country_count ||
        state.country_active[raw_slot] == 0 ||
        state.country_generation[raw_slot] != generation)
        return -1;
    return static_cast<int32_t>(raw_slot);
}

bool country_core_country_pays(RuntimeEconomyAssetOperation operation) {
    using Op = RuntimeEconomyAssetOperation;
    return operation == Op::RESEARCH_PURCHASE ||
        operation == Op::FISCAL_RESERVE ||
        operation == Op::CASH_TO_COHORT ||
        operation == Op::GOOD_TO_MARKET ||
        operation == Op::TREASURY_SPEND;
}

} // namespace

bool country_core_apply_economy_asset_prepare(
        RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog,
        RuntimeEconomyAssetRequest &request,
        std::string &error) {
    error.clear();
    (void)catalog;
    int32_t slot = request.country_slot;
    if (slot < 0) slot = country_core_slot_from_handle(state, request.country_handle);
    if (slot < 0 || slot >= static_cast<int32_t>(state.country_count)) {
        error = "country_economy_asset_slot_invalid";
        return false;
    }
    request.country_slot = slot;
    request.country_generation = state.generation;
    const size_t country = static_cast<size_t>(slot);
    if (country_core_country_pays(request.operation)) {
        if (request.requested_cash > 0 &&
            state.country_cash[country] < request.requested_cash) {
            error = "country_economy_asset_cash_insufficient";
            return false;
        }
        // RESEARCH_PURCHASE credits technology_points into the treasury; the
        // good payload is the purchase quantity, not a debit from stock.
        if (request.operation != RuntimeEconomyAssetOperation::RESEARCH_PURCHASE) {
            for (uint32_t i = 0; i < request.good_count &&
                 i < RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY; ++i) {
                const int32_t good = request.good_ids[i];
                const int64_t qty = request.good_quantities[i];
                if (good < 0 || good >= static_cast<int32_t>(state.good_count) ||
                    qty < 0) {
                    error = "country_economy_asset_good_invalid";
                    return false;
                }
                const int64_t stock = state.country_goods[
                    country * state.good_count + static_cast<size_t>(good)];
                if (stock < qty) {
                    error = "country_economy_asset_goods_insufficient";
                    return false;
                }
            }
        } else if (catalog.technology_points_good_id >= 0 &&
                   catalog.technology_points_good_id <
                       static_cast<int32_t>(state.good_count)) {
            const int64_t qty = request.requested_quantity > 0
                ? request.requested_quantity : request.requested_cash;
            const int64_t stock = state.country_goods[
                country * state.good_count +
                static_cast<size_t>(catalog.technology_points_good_id)];
            if (qty < 0 || stock > std::numeric_limits<int64_t>::max() - qty) {
                error = "country_economy_asset_research_points_overflow";
                return false;
            }
        }
        request.reserved_cash = request.requested_cash;
        request.reserved_goods_total = request.requested_goods_total;
        request.prepared_quantity = request.requested_quantity > 0
            ? request.requested_quantity : request.requested_cash;
    } else {
        request.prepared_quantity = request.requested_quantity > 0
            ? request.requested_quantity : request.requested_cash;
    }
    request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    return true;
}

bool country_core_apply_economy_asset_commit(
        RuntimeCountryPodSnapshot &state,
        const RuntimeCountryPodCatalog &catalog,
        const RuntimeEconomyAssetRequest &request,
        const RuntimeEconomyAssetResult &result,
        std::string &error) {
    error.clear();
    if (result.code == RuntimeEconomyAssetResultCode::REJECTED ||
        result.code == RuntimeEconomyAssetResultCode::FAULTED) {
        return true;
    }
    if (result.code != RuntimeEconomyAssetResultCode::COMPLETED &&
        result.code != RuntimeEconomyAssetResultCode::PEER_APPLIED &&
        result.state != RuntimeEconomyAssetState::COMPLETED) {
        error = "country_economy_asset_commit_state_invalid";
        return false;
    }
    const int32_t slot = request.country_slot;
    if (slot < 0 || slot >= static_cast<int32_t>(state.country_count)) {
        error = "country_economy_asset_slot_invalid";
        return false;
    }
    const size_t country = static_cast<size_t>(slot);
    const int64_t cash = result.committed_cash != 0
        ? result.committed_cash : request.reserved_cash;
    const bool pays = country_core_country_pays(request.operation);
    if (pays) {
        if (state.country_cash[country] < cash) {
            error = "country_economy_asset_cash_insufficient";
            return false;
        }
        state.country_cash[country] -= cash;
        if (request.operation == RuntimeEconomyAssetOperation::RESEARCH_PURCHASE &&
            catalog.technology_points_good_id >= 0 &&
            catalog.technology_points_good_id <
                static_cast<int32_t>(state.good_count)) {
            const int64_t qty = result.committed_quantity > 0
                ? result.committed_quantity : request.prepared_quantity;
            state.country_goods[country * state.good_count +
                static_cast<size_t>(catalog.technology_points_good_id)] += qty;
            if (country < state.research_purchased_total.size())
                state.research_purchased_total[country] += qty;
        }
        for (uint32_t i = 0; i < request.good_count &&
             i < RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY; ++i) {
            if (request.operation == RuntimeEconomyAssetOperation::RESEARCH_PURCHASE)
                continue;
            const int32_t good = request.good_ids[i];
            const int64_t qty = request.good_quantities[i];
            if (good < 0 || good >= static_cast<int32_t>(state.good_count)) continue;
            int64_t &stock = state.country_goods[
                country * state.good_count + static_cast<size_t>(good)];
            if (stock < qty) {
                error = "country_economy_asset_goods_insufficient";
                return false;
            }
            stock -= qty;
        }
    } else {
        state.country_cash[country] += cash;
        for (uint32_t i = 0; i < request.good_count &&
             i < RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY; ++i) {
            const int32_t good = request.good_ids[i];
            const int64_t qty = request.good_quantities[i];
            if (good < 0 || good >= static_cast<int32_t>(state.good_count)) continue;
            state.country_goods[country * state.good_count +
                static_cast<size_t>(good)] += qty;
        }
    }
    ++state.country_state_version[country];
    return true;
}

bool country_core_first_business_difference(
        const RuntimeCountryPodSnapshot &reference,
        const RuntimeCountryPodSnapshot &worker,
        char *field, size_t field_capacity, int32_t &index) {
    index = -1;
    const auto set_field = [&](const char *name, int32_t at) {
        index = at;
        if (field == nullptr || field_capacity == 0) return;
        size_t i = 0;
        if (name != nullptr) {
            for (; i + 1u < field_capacity && name[i] != '\0'; ++i)
                field[i] = name[i];
        }
        field[i] = '\0';
    };
    if (reference.country_count != worker.country_count) {
        set_field("country_count", 0);
        return true;
    }
    if (reference.cell_count != worker.cell_count) {
        set_field("cell_count", 0);
        return true;
    }
    if (reference.last_research_day != worker.last_research_day) {
        set_field("last_research_day", 0);
        return true;
    }
    if (reference.country_active != worker.country_active) {
        set_field("country_active", 0);
        return true;
    }
    if (reference.country_generation != worker.country_generation) {
        set_field("country_generation", 0);
        return true;
    }
    if (reference.country_stable_ids != worker.country_stable_ids) {
        set_field("country_stable_ids", 0);
        return true;
    }
    if (reference.country_display_names != worker.country_display_names) {
        set_field("country_display_names", 0);
        return true;
    }
    if (reference.territory_count != worker.territory_count) {
        set_field("territory_count", 0);
        return true;
    }
    if (reference.country_cash != worker.country_cash) {
        int32_t at = 0;
        const size_t n = std::min(reference.country_cash.size(),
                                  worker.country_cash.size());
        for (size_t i = 0; i < n; ++i) {
            if (reference.country_cash[i] != worker.country_cash[i]) {
                at = static_cast<int32_t>(i);
                break;
            }
        }
        set_field("country_cash", at);
        return true;
    }
    if (reference.country_goods != worker.country_goods) {
        set_field("country_goods", 0);
        return true;
    }
    if (reference.cell_country_slot != worker.cell_country_slot) {
        int32_t at = 0;
        const size_t n = std::min(reference.cell_country_slot.size(),
                                  worker.cell_country_slot.size());
        for (size_t i = 0; i < n; ++i) {
            if (reference.cell_country_slot[i] != worker.cell_country_slot[i]) {
                at = static_cast<int32_t>(i);
                break;
            }
        }
        set_field("cell_country_slot", at);
        return true;
    }
    if (reference.territory_offsets != worker.territory_offsets) {
        set_field("territory_csr", 0);
        return true;
    }
    if (reference.territory_cells != worker.territory_cells) {
        set_field("territory_cells", 0);
        return true;
    }
    if (reference.country_technologies != worker.country_technologies) {
        set_field("country_technologies", 0);
        return true;
    }
    if (reference.country_discovered != worker.country_discovered) {
        set_field("country_discovered", 0);
        return true;
    }
    if (reference.country_pending_technologies !=
            worker.country_pending_technologies) {
        set_field("country_pending_technologies", 0);
        return true;
    }
    if (reference.country_research_signals != worker.country_research_signals) {
        int32_t at = 0;
        const size_t n = std::min(reference.country_research_signals.size(),
                                  worker.country_research_signals.size());
        for (size_t i = 0; i < n; ++i) {
            if (reference.country_research_signals[i] !=
                    worker.country_research_signals[i]) {
                at = static_cast<int32_t>(i);
                break;
            }
        }
        set_field("country_research_signals", at);
        return true;
    }
    if (reference.research_signal_cell_offsets !=
            worker.research_signal_cell_offsets ||
        reference.research_signal_cells != worker.research_signal_cells) {
        set_field("research_signal_cells", 0);
        return true;
    }
    if (reference.research_signal_evidence_offsets !=
            worker.research_signal_evidence_offsets ||
        reference.research_signal_evidence.size() !=
            worker.research_signal_evidence.size()) {
        set_field("research_signal_evidence", 0);
        return true;
    }
    for (size_t i = 0; i < reference.research_signal_evidence.size(); ++i) {
        const auto &a = reference.research_signal_evidence[i];
        const auto &b = worker.research_signal_evidence[i];
        if (a.signal != b.signal || a.count != b.count ||
            a.first_day != b.first_day || a.last_day != b.last_day ||
            a.first_cell != b.first_cell) {
            set_field("research_signal_evidence", static_cast<int32_t>(i));
            return true;
        }
    }
    if (reference.research_queues != worker.research_queues) {
        set_field("research_queues", 0);
        return true;
    }
    if (reference.research_queue_lengths != worker.research_queue_lengths) {
        set_field("research_queue_lengths", 0);
        return true;
    }
    if (reference.research_weights_bp != worker.research_weights_bp) {
        set_field("research_weights_bp", 0);
        return true;
    }
    if (reference.research_auto_purchase != worker.research_auto_purchase) {
        set_field("research_auto_purchase", 0);
        return true;
    }
    if (reference.research_daily_budgets != worker.research_daily_budgets) {
        set_field("research_daily_budgets", 0);
        return true;
    }
    if (reference.research_deferred_points != worker.research_deferred_points) {
        set_field("research_deferred_points", 0);
        return true;
    }
    if (reference.research_progress != worker.research_progress) {
        set_field("research_progress", 0);
        return true;
    }
    if (reference.research_purchased_total != worker.research_purchased_total ||
        reference.research_consumed_total != worker.research_consumed_total ||
        reference.research_progress_total != worker.research_progress_total ||
        reference.research_completed_total != worker.research_completed_total) {
        set_field("research_totals", 0);
        return true;
    }
    if (reference.country_tax_defaults != worker.country_tax_defaults) {
        set_field("country_tax_defaults", 0);
        return true;
    }
    if (reference.cell_tax_policy_ids != worker.cell_tax_policy_ids) {
        set_field("cell_tax_policy_ids", 0);
        return true;
    }
    if (country_core_hash_business_state(reference) !=
        country_core_hash_business_state(worker)) {
        set_field("state_hash", 0);
        return true;
    }
    return false;
}

uint64_t country_core_hash_business_state(const RuntimeCountryPodSnapshot &state) {
    constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
    constexpr uint64_t FNV_PRIME = 1099511628211ull;
    uint64_t hash = FNV_OFFSET;
    const auto mix_u64 = [&](uint64_t value) {
        for (uint32_t i = 0; i < 8; ++i) {
            hash ^= static_cast<uint8_t>(value >> (i * 8u));
            hash *= FNV_PRIME;
        }
    };
    const auto hash_vector = [&](const auto &values) {
        const uint32_t count = static_cast<uint32_t>(values.size());
        for (size_t i = 0; i < sizeof(count); ++i) {
            hash ^= static_cast<uint8_t>(count >> (i * 8u));
            hash *= FNV_PRIME;
        }
        if (!values.empty()) {
            const auto *bytes = reinterpret_cast<const uint8_t *>(values.data());
            for (size_t i = 0; i < values.size() * sizeof(values[0]); ++i) {
                hash ^= bytes[i];
                hash *= FNV_PRIME;
            }
        }
    };
    // generation is transport/bookkeeping state, not Country business state.
    // Production and SHADOW can publish the same canonical Country values
    // through different numbers of internal commits, so including it makes
    // deterministic business parity impossible by construction.
    mix_u64(static_cast<uint64_t>(state.last_research_day));
    hash_vector(state.country_active);
    hash_vector(state.country_generation);
    for (const std::string &value : state.country_stable_ids) {
        hash_vector(std::vector<uint8_t>(value.begin(), value.end()));
        mix_u64(0);
    }
    for (const std::string &value : state.country_display_names) {
        hash_vector(std::vector<uint8_t>(value.begin(), value.end()));
        mix_u64(0);
    }
    // Per-country state versions are read-view invalidation cursors. They can
    // differ when production batches internal writes differently from SHADOW,
    // without any difference in the canonical Country business values.
    hash_vector(state.territory_count);
    hash_vector(state.country_cash);
    hash_vector(state.country_goods);
    hash_vector(state.cell_country_slot);
    hash_vector(state.territory_offsets);
    hash_vector(state.territory_cells);
    hash_vector(state.country_technologies);
    hash_vector(state.country_discovered);
    hash_vector(state.country_pending_technologies);
    hash_vector(state.country_research_signals);
    hash_vector(state.research_signal_cell_offsets);
    hash_vector(state.research_signal_cells);
    hash_vector(state.research_signal_evidence_offsets);
    for (const auto &entry : state.research_signal_evidence) {
        mix_u64(static_cast<uint64_t>(entry.signal));
        mix_u64(static_cast<uint64_t>(entry.count));
        mix_u64(static_cast<uint64_t>(entry.first_day));
        mix_u64(static_cast<uint64_t>(entry.last_day));
        mix_u64(static_cast<uint64_t>(entry.first_cell));
    }
    hash_vector(state.research_queues);
    hash_vector(state.research_queue_lengths);
    hash_vector(state.research_weights_bp);
    hash_vector(state.research_auto_purchase);
    hash_vector(state.research_daily_budgets);
    hash_vector(state.research_deferred_points);
    hash_vector(state.research_progress);
    hash_vector(state.research_purchased_total);
    hash_vector(state.research_consumed_total);
    hash_vector(state.research_progress_total);
    hash_vector(state.research_completed_total);
    hash_vector(state.country_tax_defaults);
    hash_vector(state.country_tax_default_modes);
    hash_vector(state.country_income_tax_overrides);
    hash_vector(state.country_consumption_tax_overrides);
    hash_vector(state.country_business_tax_overrides);
    hash_vector(state.country_import_tax_overrides);
    hash_vector(state.country_export_tax_overrides);
    hash_vector(state.country_income_tax_mode_overrides);
    hash_vector(state.country_consumption_tax_mode_overrides);
    hash_vector(state.country_business_tax_mode_overrides);
    hash_vector(state.country_import_tax_mode_overrides);
    hash_vector(state.country_export_tax_mode_overrides);
    hash_vector(state.cell_tax_policy_ids);
    for (const auto &policy : state.cell_tax_policies) {
        for (const int32_t value : policy.defaults)
            mix_u64(static_cast<uint64_t>(value));
        for (const int32_t value : policy.modes)
            mix_u64(static_cast<uint64_t>(value));
        for (const auto &entry : policy.overrides) {
            mix_u64(static_cast<uint64_t>(entry.kind));
            mix_u64(static_cast<uint64_t>(entry.item));
            mix_u64(static_cast<uint64_t>(entry.rate));
            mix_u64(static_cast<uint64_t>(entry.mode));
        }
    }
    return hash;
}

} // namespace pk
