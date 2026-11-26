#include "country_core_apply.h"

#include "country_core.h"
#include "fnv1a_bytes.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

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
    // The compiler has already combined hard prerequisites, route alternatives,
    // milestone thresholds and era entry into this condition. Rechecking the
    // old prerequisite CSR adds a second, different gate to the worker path.
    return country_core_research_condition_met(state, catalog, slot, technology);
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

void country_core_mark_research_active(
        RuntimeCountryPodSnapshot &state, int32_t slot) {
    if (!state.research_active_index_valid || slot < 0 ||
        slot >= static_cast<int32_t>(state.country_count) ||
        static_cast<size_t>(slot) >= state.country_active.size() ||
        state.country_active[static_cast<size_t>(slot)] == 0)
        return;
    auto &slots = state.research_active_country_slots;
    const auto it = std::lower_bound(slots.begin(), slots.end(), slot);
    if (it == slots.end() || *it != slot) slots.insert(it, slot);
}

void country_core_repair_research_active_index(
        RuntimeCountryPodSnapshot &state) {
    if (!state.research_active_index_valid) return;
    for (uint32_t slot = 0; slot < state.country_count; ++slot) {
        bool has_work = false;
        const size_t queue_base = static_cast<size_t>(slot) *
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        for (uint32_t domain = 0;
             domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT && !has_work; ++domain) {
            const size_t lane = queue_base + domain;
            has_work = lane < state.research_queue_lengths.size() &&
                state.research_queue_lengths[lane] != 0;
        }
        const size_t word_base = static_cast<size_t>(slot) * state.technology_words;
        for (uint32_t word = 0; word < state.technology_words && !has_work; ++word) {
            const size_t index = word_base + word;
            has_work = index < state.country_pending_technologies.size() &&
                state.country_pending_technologies[index] != 0;
        }
        if (has_work)
            country_core_mark_research_active(state, static_cast<int32_t>(slot));
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
        // A market purchase may also carry a cash price.  Treat it as a
        // treasury payer when requested_cash is non-zero; zero-cost transfers
        // retain the existing no-cash behavior.
        operation == Op::GOOD_FROM_MARKET ||
        operation == Op::TREASURY_SPEND;
}

} // namespace

bool country_core_apply_economy_asset_prepare(
        const RuntimeCountryPodSnapshot &state,
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
        if (request.operation != RuntimeEconomyAssetOperation::RESEARCH_PURCHASE &&
            request.operation != RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
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
        // Prepare validated and reserved exactly reserved_cash; a larger
        // peer-committed amount would debit treasury value Economy never
        // credited anywhere.
        if (cash < 0 || cash > request.reserved_cash) {
            error = "country_economy_asset_commit_cash_exceeds_reserved";
            return false;
        }
        if (state.country_cash[country] < cash) {
            error = "country_economy_asset_cash_insufficient";
            return false;
        }
        for (uint32_t i = 0; i < request.good_count &&
             i < RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY; ++i) {
            if (request.operation == RuntimeEconomyAssetOperation::RESEARCH_PURCHASE)
                continue;
            const int32_t good = request.good_ids[i];
            const int64_t qty = request.good_quantities[i];
            if (good < 0 || good >= static_cast<int32_t>(state.good_count)) continue;
            const int64_t stock = state.country_goods[
                country * state.good_count + static_cast<size_t>(good)];
            if (request.operation == RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
                if (stock > std::numeric_limits<int64_t>::max() - qty) {
                    error = "country_economy_asset_goods_overflow";
                    return false;
                }
            } else {
                if (stock < qty) {
                    error = "country_economy_asset_goods_insufficient";
                    return false;
                }
            }
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
            if (request.operation == RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
                stock += qty;
            } else {
                stock -= qty;
            }
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

} // namespace pk
