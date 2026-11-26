#include "country_core_apply.h"

#include "country_core.h"
#include "fnv1a_bytes.h"

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
        // Legacy diagnostic fixtures may omit capital_cell; normalize to the
        // already-existing slots before appending the new one.
        if (state.capital_cell.size() != static_cast<size_t>(new_slot))
            state.capital_cell.resize(static_cast<size_t>(new_slot), -1);
        state.capital_cell.push_back(command.cell);
        state.country_state_version.push_back(1);
        int32_t default_regime = 0;
        for (size_t regime = 0; regime < catalog.political_regime_ids.size(); ++regime) {
            if (catalog.political_regime_ids[regime] == "early_clan") {
                default_regime = static_cast<int32_t>(regime);
                break;
            }
        }
        state.country_political_regime_ids.push_back(default_regime);
        state.country_political_regime_capabilities.push_back(
            default_regime >= 0 && static_cast<size_t>(default_regime) <
                catalog.political_regime_capability_bits.size()
                ? catalog.political_regime_capability_bits[
                    static_cast<size_t>(default_regime)] : 0u);
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
        state.research_deferred_points.push_back(0);
        state.research_progress_total.push_back(0);
        state.research_completed_total.push_back(0);
        state.research_auto_purchase.push_back(1);
        state.research_purchased_total.push_back(0);
        state.research_consumed_total.push_back(0);
        if (!state.treasury_goods_consumed_total.empty())
            state.treasury_goods_consumed_total.push_back(0);
        state.research_peer_flags.insert(state.research_peer_flags.end(), state.technology_count, 0);
        state.country_research_signals.insert(
            state.country_research_signals.end(), state.research_signal_words, 0);
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
                country_core_mark_research_active(state, slot);
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
        if (!country_core_research_condition_met(state, catalog, slot, command.aux)) {
            error = "country_research_requirements_incomplete";
            return false;
        }
        const bool milestone =
            (catalog.technology_flags[static_cast<size_t>(command.aux)] & 2) != 0;
        if (!milestone &&
            catalog.technology_domains[static_cast<size_t>(command.aux)] != command.domain) {
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
        country_core_mark_research_active(state, slot);
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
    case 9: // research auto purchase
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.aux != 0 && command.aux != 1) {
            error = "country_research_auto_purchase_invalid";
            return false;
        }
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
    case 21: { // consume treasury goods (era advancement sink)
        if (!country_core_validate_target(state, command, slot, error)) return false;
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(state.good_count) ||
            command.value <= 0) {
            error = "country_treasury_goods_command_invalid";
            return false;
        }
        const size_t index = static_cast<size_t>(slot) * state.good_count +
            static_cast<size_t>(command.aux);
        if (index >= state.country_goods.size() ||
            state.country_goods[index] < command.value) {
            error = "country_treasury_goods_insufficient";
            return false;
        }
        state.country_goods[index] -= command.value;
        if (state.treasury_goods_consumed_total.size() < state.country_count)
            state.treasury_goods_consumed_total.resize(state.country_count, 0);
        int64_t &total = state.treasury_goods_consumed_total[static_cast<size_t>(slot)];
        total = command.value > std::numeric_limits<int64_t>::max() - total
            ? std::numeric_limits<int64_t>::max() : total + command.value;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 23: // transfer cash between countries
    case 24: { // transfer goods between countries
        if (!country_core_validate_target(state, command, slot, error)) return false;
        RuntimeCountryCommand receiver_command = command;
        receiver_command.target_handle =
            (static_cast<uint64_t>(static_cast<uint32_t>(command.aux)) << 32u) |
            static_cast<uint64_t>(static_cast<uint32_t>(command.cell));
        int32_t receiver = -1;
        if (!country_core_validate_target(state, receiver_command, receiver, error))
            return false;
        if (receiver == slot || command.value <= 0) {
            error = "country_transfer_between_command_invalid";
            return false;
        }
        if (command.opcode == 23) {
            int64_t &from = state.country_cash[static_cast<size_t>(slot)];
            int64_t &to = state.country_cash[static_cast<size_t>(receiver)];
            const int64_t moved = std::min(command.value, std::max<int64_t>(0, from));
            if (moved > std::numeric_limits<int64_t>::max() - to) {
                error = "country_treasury_overflow";
                return false;
            }
            from -= moved;
            to += moved;
        } else {
            if (command.domain < 0 || command.domain >= static_cast<int32_t>(state.good_count)) {
                error = "country_transfer_between_command_invalid";
                return false;
            }
            const size_t from_index = static_cast<size_t>(slot) * state.good_count +
                static_cast<size_t>(command.domain);
            const size_t to_index = static_cast<size_t>(receiver) * state.good_count +
                static_cast<size_t>(command.domain);
            if (from_index >= state.country_goods.size() ||
                to_index >= state.country_goods.size()) {
                error = "country_transfer_between_command_invalid";
                return false;
            }
            const int64_t moved = std::min(
                command.value, std::max<int64_t>(0, state.country_goods[from_index]));
            if (moved > std::numeric_limits<int64_t>::max() - state.country_goods[to_index]) {
                error = "country_treasury_overflow";
                return false;
            }
            state.country_goods[from_index] -= moved;
            state.country_goods[to_index] += moved;
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        ++state.country_state_version[static_cast<size_t>(receiver)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 27: { // annex country: victim = target_handle, annexer = cell/aux
        int32_t victim = -1;
        if (!country_core_validate_target(state, command, victim, error)) return false;
        RuntimeCountryCommand annexer_command = command;
        annexer_command.target_handle =
            (static_cast<uint64_t>(static_cast<uint32_t>(command.aux)) << 32u) |
            static_cast<uint64_t>(static_cast<uint32_t>(command.cell));
        int32_t annexer = -1;
        if (!country_core_validate_target(state, annexer_command, annexer, error))
            return false;
        if (annexer == victim) {
            error = "country_annex_command_invalid";
            return false;
        }
        const size_t v = static_cast<size_t>(victim);
        const size_t a = static_cast<size_t>(annexer);
        const size_t goods = state.good_count;
        if ((v + 1u) * goods > state.country_goods.size() ||
            (a + 1u) * goods > state.country_goods.size() ||
            state.country_cash[v] > std::numeric_limits<int64_t>::max() - state.country_cash[a]) {
            error = "country_annex_assets_invalid";
            return false;
        }
        for (size_t good = 0; good < goods; ++good) {
            if (state.country_goods[v * goods + good] >
                std::numeric_limits<int64_t>::max() - state.country_goods[a * goods + good]) {
                error = "country_annex_assets_invalid";
                return false;
            }
        }
        int32_t moved_cells = 0;
        for (size_t cell = 0; cell < state.cell_country_slot.size(); ++cell) {
            if (state.cell_country_slot[cell] != victim) continue;
            state.cell_country_slot[cell] = annexer;
            if (cell < state.cell_tax_policy_ids.size())
                state.cell_tax_policy_ids[cell] = 0;
            ++moved_cells;
        }
        state.territory_count[a] += moved_cells;
        state.territory_count[v] = 0;
        state.country_cash[a] += state.country_cash[v];
        state.country_cash[v] = 0;
        for (size_t good = 0; good < goods; ++good) {
            state.country_goods[a * goods + good] += state.country_goods[v * goods + good];
            state.country_goods[v * goods + good] = 0;
        }
        for (uint32_t word = 0; word < state.technology_words; ++word) {
            const size_t index = v * state.technology_words + word;
            if (index < state.country_pending_technologies.size())
                state.country_pending_technologies[index] = 0;
        }
        for (size_t i = 0; i < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT * COUNTRY_QUEUE_SLOTS; ++i) {
            const size_t index = v * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT * COUNTRY_QUEUE_SLOTS + i;
            if (index < state.research_queues.size()) state.research_queues[index] = -1;
        }
        for (size_t i = 0; i < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++i) {
            const size_t index = v * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT + i;
            if (index < state.research_queue_lengths.size())
                state.research_queue_lengths[index] = 0;
        }
        if (v < state.research_deferred_points.size())
            state.research_deferred_points[v] = 0;
        if (v < state.research_peer_flags.size() / std::max<uint32_t>(state.technology_count, 1u)) {
            for (uint32_t technology = 0; technology < state.technology_count; ++technology)
                state.research_peer_flags[v * state.technology_count + technology] = 0;
        }
        auto &active_slots = state.research_active_country_slots;
        active_slots.erase(std::remove(active_slots.begin(), active_slots.end(), victim),
                           active_slots.end());
        state.country_active[v] = 0;
        ++state.country_generation[v];
        ++state.country_state_version[v];
        ++state.country_state_version[a];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY |
                                      RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 28: { // set political regime; stable_id carries the catalog key
        if (!country_core_validate_target(state, command, slot, error)) return false;
        const std::string key = copy_fixed(command.stable_id);
        const auto found = std::find(catalog.political_regime_ids.begin(),
                                     catalog.political_regime_ids.end(), key);
        if (key.empty() || found == catalog.political_regime_ids.end()) {
            error = "political_regime_invalid";
            return false;
        }
        const int32_t regime = static_cast<int32_t>(
            found - catalog.political_regime_ids.begin());
        state.country_political_regime_ids[static_cast<size_t>(slot)] = regime;
        state.country_political_regime_capabilities[static_cast<size_t>(slot)] =
            regime >= 0 && static_cast<size_t>(regime) <
                catalog.political_regime_capability_bits.size()
                ? catalog.political_regime_capability_bits[static_cast<size_t>(regime)]
                : 0u;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    default:
        error = "country_command_capture_contract_missing";
        return false;
    }
}

} // namespace pk
