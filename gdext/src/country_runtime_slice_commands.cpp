#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_core_apply.h"
#include "economy_effect_forward.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

namespace pk {


bool NativeCountryRuntime::preflight_country_slice(
        CoreSliceContext &context) {
    auto &result = context.result;
    const Clock::time_point &start = context.start;
    CommandBatchState &batch = _command_batch;
    const int64_t day = context.day;
    const size_t cursor_start = context.cursor_start;
    size_t &cursor_limit = context.cursor_limit;
    std::string error;

    auto staged_handle = [&](uint64_t handle, int32_t &slot) -> bool {
        slot = static_cast<int32_t>(handle & 0xffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
        return slot >= 0 && slot < static_cast<int32_t>(batch.countries.active.size()) &&
               batch.countries.active[static_cast<size_t>(slot)] != 0 &&
               batch.countries.generation[static_cast<size_t>(slot)] == generation;
    };
    auto owner_of = [&](int32_t cell) -> int32_t {
        int32_t owner = NEUTRAL_SLOT;
        return batch.cell_delta.get(cell, owner)
            ? owner : _cell_country_slot[static_cast<size_t>(cell)];
    };
    auto mark_country = [&](int32_t slot) {
        if (slot < 0) return;
        if (slot >= static_cast<int32_t>(batch.changed_countries.size()))
            batch.changed_countries.resize(static_cast<size_t>(slot + 1), 0);
        batch.changed_countries[static_cast<size_t>(slot)] = 1;
    };
    auto staged_cell_policy = [&](int32_t cell) -> CellTaxPolicy & {
        auto [it, inserted] = batch.cell_tax_updates.try_emplace(cell);
        if (inserted) {
            const uint32_t policy_id =
                _cell_tax_policy_ids[static_cast<size_t>(cell)];
            it->second = cell_tax_policy(policy_id);
        }
        return it->second;
    };

    // Observation-only ingress is commutative. Validate the complete batch,
    // sort/unique once, then linearly merge with the authoritative ordered
    // evidence vector. This avoids O(n^2) shifts during large visibility
    // backfills while preserving the same atomic command boundary.
    const bool observation_only = batch.cursor == 0 && !batch.commands.empty() &&
        std::all_of(batch.commands.begin(), batch.commands.end(), [](const Command &command) {
            return command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL;
        });
    if (observation_only) {
        struct Observation {
            int32_t slot;
            uint64_t key;
            uint64_t handle;
            int32_t source;
            int64_t effective_day;
        };
        std::vector<Observation> incoming;
        incoming.reserve(batch.commands.size());
        for (const Command &command : batch.commands) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_research_signal_ids.size()) ||
                command.cell < 0 || command.cell >= _cell_count) {
                error = "country_research_signal_command_invalid";
                break;
            }
            incoming.push_back(Observation{
                slot,
                (uint64_t(uint32_t(command.aux)) << 32U) | uint32_t(command.cell),
                command.target_handle,
                int32_t(command.value),
                command.effective_day});
        }
        if (error.empty()) {
            std::sort(incoming.begin(), incoming.end(), [](const Observation &a,
                                                           const Observation &b) {
                if (a.slot != b.slot) return a.slot < b.slot;
                return a.key < b.key;
            });
            incoming.erase(std::unique(incoming.begin(), incoming.end(),
                [](const Observation &a, const Observation &b) {
                    return a.slot == b.slot && a.key == b.key;
                }), incoming.end());
            batch.observation_batch_input = static_cast<int64_t>(batch.commands.size());
            size_t begin = 0;
            while (begin < incoming.size()) {
                size_t end = begin + 1;
                while (end < incoming.size() && incoming[end].slot == incoming[begin].slot) ++end;
                const int32_t slot = incoming[begin].slot;
                std::vector<uint64_t> unique_keys;
                unique_keys.reserve(end - begin);
                for (size_t i = begin; i < end; ++i) unique_keys.push_back(incoming[i].key);
                std::vector<uint64_t> &existing = batch.signal_cells[size_t(slot)];
                std::vector<uint64_t> added;
                added.reserve(unique_keys.size());
                std::set_difference(unique_keys.begin(), unique_keys.end(),
                    existing.begin(), existing.end(), std::back_inserter(added));
                if (!added.empty()) {
                    std::vector<uint64_t> merged;
                    merged.reserve(existing.size() + added.size());
                    std::set_union(existing.begin(), existing.end(),
                        unique_keys.begin(), unique_keys.end(), std::back_inserter(merged));
                    existing.swap(merged);
                    batch.observation_batch_added += static_cast<int64_t>(added.size());
                    batch.countries.state_version[size_t(slot)] += added.size();
                    mark_country(slot);
                    size_t added_begin = 0;
                    while (added_begin < added.size()) {
                        const int32_t signal = int32_t(added[added_begin] >> 32U);
                        size_t added_end = added_begin + 1;
                        while (added_end < added.size() &&
                               int32_t(added[added_end] >> 32U) == signal) ++added_end;
                        const int32_t delta = int32_t(added_end - added_begin);
                        const int32_t first_cell = int32_t(added[added_begin] & 0xffffffffU);
                        int64_t first_effective_day =
                            std::numeric_limits<int64_t>::max();
                        int64_t last_effective_day = 0;
                        for (size_t added_index = added_begin;
                             added_index < added_end; ++added_index) {
                            const auto observation = std::lower_bound(
                                incoming.begin() + static_cast<ptrdiff_t>(begin),
                                incoming.begin() + static_cast<ptrdiff_t>(end),
                                added[added_index],
                                [](const Observation &candidate, uint64_t key) {
                                    return candidate.key < key;
                                });
                            if (observation ==
                                incoming.begin() + static_cast<ptrdiff_t>(end))
                                continue;
                            first_effective_day = std::min(
                                first_effective_day, observation->effective_day);
                            last_effective_day = std::max(
                                last_effective_day, observation->effective_day);
                        }
                        if (first_effective_day ==
                            std::numeric_limits<int64_t>::max()) {
                            first_effective_day = day;
                            last_effective_day = day;
                        }
                        if (_research_signal_words > 0)
                            batch.signals[size_t(slot) * _research_signal_words + signal / 64] |=
                                uint64_t{1} << (signal % 64);
                        std::vector<SignalEvidence> &evidence = batch.signal_evidence[size_t(slot)];
                        auto evidence_it = std::lower_bound(evidence.begin(), evidence.end(), signal,
                            [](const SignalEvidence &entry, int32_t value) {
                                return entry.signal < value;
                            });
                        if (evidence_it == evidence.end() || evidence_it->signal != signal) {
                            SignalEvidence entry;
                            entry.signal = signal;
                            entry.first_day = first_effective_day;
                            entry.first_cell = first_cell;
                            evidence_it = evidence.insert(evidence_it, entry);
                        }
                        evidence_it->count += delta;
                        evidence_it->last_day = std::max(
                            evidence_it->last_day, last_effective_day);
                        Event event;
                        event.day = day;
                        event.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL;
                        event.country_handle = incoming[begin].handle;
                        event.cell = first_cell;
                        event.new_country_slot = slot;
                        event.signal_id = signal;
                        event.signal_source_kind = incoming[begin].source;
                        event.evidence_delta = delta;
                        batch.events.push_back(std::move(event));
                        added_begin = added_end;
                    }
                }
                begin = end;
            }
            batch.cursor = batch.commands.size();
            cursor_limit = batch.commands.size();
        }
    }
    if (!error.empty()) batch.cursor = cursor_limit;

    for (; batch.cursor < cursor_limit; ++batch.cursor) {
        const Command &command = batch.commands[batch.cursor];
        uint64_t event_country_handle = 0;
        int32_t event_old_country_slot = NEUTRAL_SLOT;
        int32_t event_new_country_slot = NEUTRAL_SLOT;

        if (command.opcode == COMMAND_CREATE_COUNTRY) {
            if (command.stable_id.empty() || command.display_name.empty() ||
                std::find(batch.countries.stable_id.begin(), batch.countries.stable_id.end(),
                          command.stable_id) != batch.countries.stable_id.end()) {
                error = "country_create_identity_invalid"; break;
            }
            if (command.cell < 0 || command.cell >= _cell_count || _is_water[static_cast<size_t>(command.cell)] != 0) {
                error = "country_create_territory_invalid"; break;
            }
            const int32_t old_owner = batch.direct_unique_territory
                ? _cell_country_slot[static_cast<size_t>(command.cell)]
                : owner_of(command.cell);
            const int32_t new_slot = static_cast<int32_t>(batch.countries.active.size());
            batch.countries.active.push_back(1);
            batch.countries.generation.push_back(1);
            batch.countries.stable_id.push_back(command.stable_id);
            batch.countries.display_name.push_back(command.display_name);
            batch.countries.territory_count.push_back(1);
            batch.countries.cash.push_back(0);
            batch.countries.state_version.push_back(1);
            const auto early_regime = _political_regime_index.find("early_clan");
            const int32_t default_regime = early_regime == _political_regime_index.end()
                ? 0 : early_regime->second;
            batch.countries.political_regime_id.push_back(default_regime);
            batch.countries.political_regime_capability_bits.push_back(
                default_regime >= 0 && static_cast<size_t>(default_regime) <
                    _political_regime_capability_bits.size()
                    ? _political_regime_capability_bits[static_cast<size_t>(default_regime)]
                    : 0u);
            batch.technologies.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.goods.resize(static_cast<size_t>(new_slot + 1) * _good_ids.size(), 0);
            batch.discovered.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.pending.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.progress.resize(static_cast<size_t>(new_slot + 1));
            batch.research_queues.resize(static_cast<size_t>(new_slot + 1) * 32U, -1);
            batch.research_queue_lengths.resize(static_cast<size_t>(new_slot + 1) * 4U, 0);
            batch.research_weights_bp.resize(static_cast<size_t>(new_slot + 1) * 4U, 2500);
            batch.research_auto_purchase.resize(static_cast<size_t>(new_slot + 1), 1);
            batch.research_daily_budgets.resize(static_cast<size_t>(new_slot + 1),
                                                1000 * MONEY_SCALE);
            batch.research_deferred_points.resize(static_cast<size_t>(new_slot + 1), 0);
            batch.signals.resize(static_cast<size_t>(new_slot + 1) * _research_signal_words, 0);
            batch.signal_cells.resize(static_cast<size_t>(new_slot + 1));
            batch.signal_evidence.resize(static_cast<size_t>(new_slot + 1));
            batch.tax_defaults.resize(
                static_cast<size_t>(new_slot + 1) * TAX_KIND_COUNT, 0);
            batch.tax_default_modes.resize(
                static_cast<size_t>(new_slot + 1) * TAX_KIND_COUNT,
                TAX_MODE_PERCENT_BP);
            batch.income_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _profession_ids.size(),
                TAX_RATE_INHERIT);
            batch.consumption_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_RATE_INHERIT);
            batch.business_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) *
                    _building_type_ids.size(),
                TAX_RATE_INHERIT);
            batch.import_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_RATE_INHERIT);
            batch.export_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_RATE_INHERIT);
            batch.income_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _profession_ids.size(),
                TAX_MODE_INHERIT);
            batch.consumption_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_MODE_INHERIT);
            batch.business_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) *
                    _building_type_ids.size(),
                TAX_MODE_INHERIT);
            batch.import_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_MODE_INHERIT);
            batch.export_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_MODE_INHERIT);
            if (old_owner >= 0) {
                --batch.countries.territory_count[static_cast<size_t>(old_owner)];
                for (int32_t word = 0; word < _technology_words; ++word)
                    batch.technologies[static_cast<size_t>(new_slot) * _technology_words + word] =
                        batch.technologies[static_cast<size_t>(old_owner) * _technology_words + word];
                for (int32_t word = 0; word < _technology_words; ++word)
                    batch.discovered[static_cast<size_t>(new_slot) * _technology_words + word] =
                        batch.discovered[static_cast<size_t>(old_owner) * _technology_words + word];
                mark_country(old_owner);
            } else {
                for (int32_t tech : _starting_technologies)
                    batch.technologies[static_cast<size_t>(new_slot) * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
                for (int32_t tech : _starting_technologies)
                    batch.discovered[static_cast<size_t>(new_slot) * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
            }
            if (batch.cell_delta.set(command.cell, new_slot))
                batch.cell_delta_order.push_back(command.cell);
            staged_cell_policy(command.cell) = CellTaxPolicy{};
            mark_country(new_slot);
            event_country_handle = (1ULL << 32U) | static_cast<uint32_t>(new_slot);
            event_old_country_slot = old_owner;
            event_new_country_slot = new_slot;
        } else if (command.opcode == COMMAND_RENAME_COUNTRY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.display_name.empty()) { error = "country_name_empty"; break; }
            batch.countries.display_name[static_cast<size_t>(slot)] = command.display_name;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY ||
                   command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) {
            if (command.cell < 0 || command.cell >= _cell_count || _is_water[static_cast<size_t>(command.cell)] != 0) {
                error = "country_transfer_cell_invalid"; break;
            }
            int32_t target = NEUTRAL_SLOT;
            if (command.target_handle != 0 && !staged_handle(command.target_handle, target)) {
                error = "country_handle_invalid"; break;
            }
            const int32_t old_owner = batch.direct_unique_territory
                ? _cell_country_slot[static_cast<size_t>(command.cell)]
                : owner_of(command.cell);
            if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY &&
                old_owner != NEUTRAL_SLOT) {
                error = "country_claim_target_not_unowned";
                break;
            }
            if (old_owner == target) continue;
            if (old_owner >= 0) {
                --batch.countries.territory_count[static_cast<size_t>(old_owner)];
                ++batch.countries.state_version[static_cast<size_t>(old_owner)];
                mark_country(old_owner);
            }
            if (target >= 0) {
                ++batch.countries.territory_count[static_cast<size_t>(target)];
                ++batch.countries.state_version[static_cast<size_t>(target)];
                mark_country(target);
            }
            if (batch.direct_unique_territory) {
                batch.cell_delta_order.push_back(command.cell);
                batch.direct_cell_owners.push_back(target);
            } else if (batch.cell_delta.set(command.cell, target)) {
                batch.cell_delta_order.push_back(command.cell);
            }
            staged_cell_policy(command.cell) = CellTaxPolicy{};
            event_country_handle = target >= 0 ? ((static_cast<uint64_t>(batch.countries.generation[target]) << 32U) |
                                                   static_cast<uint32_t>(target)) : 0;
            event_old_country_slot = old_owner;
            event_new_country_slot = target;
        } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_technology_ids.size())) {
                error = "country_technology_invalid"; break;
            }
            uint64_t &word = batch.pending[
                static_cast<size_t>(slot) * _technology_words + command.aux / 64];
            const uint64_t bit = 1ULL << (command.aux % 64);
            const uint64_t completed_word = batch.technologies[
                static_cast<size_t>(slot) * _technology_words + command.aux / 64];
            if ((completed_word & bit) == 0 && (word & bit) == 0) {
                word |= bit;
                ++batch.countries.state_version[static_cast<size_t>(slot)];
                mark_country(slot);
            }
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_SET_POLITICAL_REGIME) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid"; break;
            }
            const auto found = _political_regime_index.find(command.stable_id);
            if (found == _political_regime_index.end()) {
                error = "political_regime_invalid"; break;
            }
            const int32_t regime = found->second;
            batch.countries.political_regime_id[static_cast<size_t>(slot)] = regime;
            batch.countries.political_regime_capability_bits[static_cast<size_t>(slot)] =
                regime >= 0 && static_cast<size_t>(regime) <
                    _political_regime_capability_bits.size()
                    ? _political_regime_capability_bits[static_cast<size_t>(regime)] : 0u;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_CONSUME_TREASURY_GOODS) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_good_ids.size()) ||
                command.value <= 0) {
                error = "country_treasury_goods_command_invalid"; break;
            }
            const size_t goods_index = static_cast<size_t>(slot) * _good_ids.size() +
                static_cast<size_t>(command.aux);
            if (goods_index >= batch.goods.size()) {
                error = "country_treasury_goods_insufficient"; break;
            }
            // Goods currently reserved by an in-flight Economy asset
            // transaction are not spendable by the era sink.
            int64_t reserved = 0;
            if (goods_index < _economy_asset_reserved_goods.size())
                reserved = std::max<int64_t>(0, _economy_asset_reserved_goods[goods_index]);
            if (batch.goods[goods_index] - reserved < command.value) {
                error = "country_treasury_goods_insufficient"; break;
            }
            batch.goods[goods_index] -= command.value;
            batch.treasury_consumed.emplace_back(slot, command.value);
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES ||
                   command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES) {
            int32_t payer = -1;
            int32_t receiver = -1;
            if (!staged_handle(command.target_handle, payer) ||
                !staged_handle(receiver_handle_from_payload(command.cell, command.aux),
                               receiver)) {
                error = "country_handle_invalid"; break;
            }
            if (payer == receiver || command.value <= 0) {
                error = "country_transfer_between_command_invalid"; break;
            }
            int64_t moved = 0;
            if (command.opcode == COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES) {
                int64_t reserved = 0;
                if (static_cast<size_t>(payer) < _economy_asset_reserved_cash.size())
                    reserved = std::max<int64_t>(
                        0, _economy_asset_reserved_cash[static_cast<size_t>(payer)]);
                int64_t &from = batch.countries.cash[static_cast<size_t>(payer)];
                int64_t &to = batch.countries.cash[static_cast<size_t>(receiver)];
                moved = std::min(command.value, std::max<int64_t>(0, from - reserved));
                if (moved > std::numeric_limits<int64_t>::max() - to) {
                    error = "country_treasury_overflow"; break;
                }
                from -= moved;
                to += moved;
            } else {
                if (command.domain < 0 ||
                    command.domain >= static_cast<int32_t>(_good_ids.size())) {
                    error = "country_transfer_between_command_invalid"; break;
                }
                const size_t good_count = _good_ids.size();
                const size_t from_index = static_cast<size_t>(payer) * good_count +
                    static_cast<size_t>(command.domain);
                const size_t to_index = static_cast<size_t>(receiver) * good_count +
                    static_cast<size_t>(command.domain);
                if (from_index >= batch.goods.size() || to_index >= batch.goods.size()) {
                    error = "country_transfer_between_command_invalid"; break;
                }
                int64_t reserved = 0;
                if (from_index < _economy_asset_reserved_goods.size())
                    reserved = std::max<int64_t>(0, _economy_asset_reserved_goods[from_index]);
                moved = std::min(command.value,
                                 std::max<int64_t>(0, batch.goods[from_index] - reserved));
                if (moved > std::numeric_limits<int64_t>::max() - batch.goods[to_index]) {
                    error = "country_treasury_overflow"; break;
                }
                batch.goods[from_index] -= moved;
                batch.goods[to_index] += moved;
            }
            ++batch.countries.state_version[static_cast<size_t>(payer)];
            ++batch.countries.state_version[static_cast<size_t>(receiver)];
            mark_country(payer);
            mark_country(receiver);
            if (batch.events.size() < 2048) {
                Event event;
                event.day = day;
                event.opcode = command.opcode;
                event.country_handle = command.target_handle;
                event.cell = -1;
                event.old_country_slot = payer;
                event.new_country_slot = receiver;
                event.technology_id =
                    command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES
                        ? command.domain : -1;
                event.value = moved;
                batch.events.push_back(std::move(event));
            }
            continue;
        } else if (command.opcode == COMMAND_ANNEX_COUNTRY) {
            int32_t victim = -1;
            int32_t annexer = -1;
            const uint64_t annexer_handle =
                receiver_handle_from_payload(command.cell, command.aux);
            if (!staged_handle(command.target_handle, victim) ||
                !staged_handle(annexer_handle, annexer)) {
                error = "country_handle_invalid"; break;
            }
            if (victim == annexer) { error = "country_annex_command_invalid"; break; }
            if ((static_cast<size_t>(victim) < _economy_asset_reserved_cash.size() &&
                 _economy_asset_reserved_cash[static_cast<size_t>(victim)] > 0)) {
                error = "country_annex_assets_reserved"; break;
            }
            const size_t good_count = _good_ids.size();
            const size_t victim_goods = static_cast<size_t>(victim) * good_count;
            const size_t annexer_goods = static_cast<size_t>(annexer) * good_count;
            bool goods_ok = victim_goods + good_count <= batch.goods.size() &&
                annexer_goods + good_count <= batch.goods.size();
            for (size_t good = 0; goods_ok && good < good_count; ++good) {
                const size_t index = victim_goods + good;
                if (index < _economy_asset_reserved_goods.size() &&
                    _economy_asset_reserved_goods[index] > 0) goods_ok = false;
                else if (batch.goods[index] >
                         std::numeric_limits<int64_t>::max() -
                             batch.goods[annexer_goods + good]) goods_ok = false;
            }
            int64_t &victim_cash = batch.countries.cash[static_cast<size_t>(victim)];
            int64_t &annexer_cash = batch.countries.cash[static_cast<size_t>(annexer)];
            if (!goods_ok ||
                victim_cash > std::numeric_limits<int64_t>::max() - annexer_cash) {
                error = "country_annex_assets_invalid"; break;
            }
            // Collect the victim's staged territory: committed CSR cells still
            // owned by it plus cells staged to it earlier in this batch.
            std::vector<int32_t> victim_cells;
            if (static_cast<size_t>(victim) + 1u < _country_cell_offsets.size()) {
                for (int32_t cursor = _country_cell_offsets[static_cast<size_t>(victim)];
                     cursor < _country_cell_offsets[static_cast<size_t>(victim) + 1u];
                     ++cursor) {
                    const int32_t cell = _country_cells[static_cast<size_t>(cursor)];
                    if (owner_of(cell) == victim) victim_cells.push_back(cell);
                }
            }
            for (const int32_t cell : batch.cell_delta_order) {
                if (_cell_country_slot[static_cast<size_t>(cell)] != victim &&
                    owner_of(cell) == victim)
                    victim_cells.push_back(cell);
            }
            std::sort(victim_cells.begin(), victim_cells.end());
            for (const int32_t cell : victim_cells) {
                if (batch.cell_delta.set(cell, annexer))
                    batch.cell_delta_order.push_back(cell);
                staged_cell_policy(cell) = CellTaxPolicy{};
            }
            const int32_t moved_cells = static_cast<int32_t>(victim_cells.size());
            batch.countries.territory_count[static_cast<size_t>(annexer)] += moved_cells;
            batch.countries.territory_count[static_cast<size_t>(victim)] = 0;
            annexer_cash += victim_cash;
            victim_cash = 0;
            for (size_t good = 0; good < good_count; ++good) {
                batch.goods[annexer_goods + good] += batch.goods[victim_goods + good];
                batch.goods[victim_goods + good] = 0;
            }
            // Research queues and pending activations retire with the state.
            for (int32_t word = 0; word < _technology_words; ++word)
                batch.pending[static_cast<size_t>(victim) * _technology_words +
                              static_cast<size_t>(word)] = 0;
            for (size_t i = 0; i < 32U; ++i)
                batch.research_queues[static_cast<size_t>(victim) * 32U + i] = -1;
            for (size_t i = 0; i < 4U; ++i)
                batch.research_queue_lengths[static_cast<size_t>(victim) * 4U + i] = 0;
            batch.research_deferred_points[static_cast<size_t>(victim)] = 0;
            batch.countries.active[static_cast<size_t>(victim)] = 0;
            ++batch.countries.generation[static_cast<size_t>(victim)];
            ++batch.countries.state_version[static_cast<size_t>(victim)];
            ++batch.countries.state_version[static_cast<size_t>(annexer)];
            mark_country(victim);
            mark_country(annexer);
            // Territory evidence: one event per moved cell (deterministic
            // tail kept within the public ring), then a summary record.
            const size_t first_cell_event =
                victim_cells.size() > 2047 ? victim_cells.size() - 2047 : 0;
            for (size_t i = first_cell_event; i < victim_cells.size(); ++i) {
                Event event;
                event.day = day;
                event.opcode = COMMAND_ANNEX_COUNTRY;
                event.country_handle = annexer_handle;
                event.cell = victim_cells[i];
                event.old_country_slot = victim;
                event.new_country_slot = annexer;
                batch.events.push_back(std::move(event));
            }
            Event summary;
            summary.day = day;
            summary.opcode = COMMAND_ANNEX_COUNTRY;
            summary.country_handle = annexer_handle;
            summary.cell = -1;
            summary.old_country_slot = victim;
            summary.new_country_slot = annexer;
            summary.value = moved_cells;
            summary.stable_id = batch.countries.stable_id[static_cast<size_t>(victim)];
            summary.display_name =
                batch.countries.display_name[static_cast<size_t>(victim)];
            batch.events.push_back(std::move(summary));
            continue;
        } else if (command.opcode == COMMAND_SET_RESEARCH_WEIGHTS) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            int32_t total = 0;
            for (int32_t domain = 0; domain < 4; ++domain) {
                if (command.weights_bp[domain] < 0 || command.weights_bp[domain] > 10000) {
                    error = "country_research_weight_invalid"; break;
                }
                total += command.weights_bp[domain];
            }
            if (!error.empty()) break;
            if (total != 10000) { error = "country_research_weight_total_invalid"; break; }
            for (int32_t domain = 0; domain < 4; ++domain)
                batch.research_weights_bp[static_cast<size_t>(slot) * 4U + domain] =
                    command.weights_bp[domain];
            batch.research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_ENQUEUE_RESEARCH ||
                   command.opcode == COMMAND_MOVE_RESEARCH) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_technology_ids.size()) ||
                command.domain < 0 || command.domain >= 4 ||
                command.position < -1 || command.position >= 8) {
                error = "country_research_queue_argument_invalid"; break;
            }
            const size_t word_index = static_cast<size_t>(slot) * _technology_words + command.aux / 64;
            const uint64_t bit = 1ULL << (command.aux % 64);
            if ((batch.discovered[word_index] & bit) == 0 ||
                (batch.technologies[word_index] & bit) != 0 ||
                (batch.pending[word_index] & bit) != 0) {
                error = "country_research_technology_unavailable"; break;
            }
            if (!research_condition_met(batch.technologies, batch.signals,
                                        batch.signal_evidence,
                                        slot, command.aux)) {
                error = "country_research_requirements_incomplete"; break;
            }
            const bool milestone = (_technology_flags[static_cast<size_t>(command.aux)] & 2) != 0;
            if (!milestone && _technology_domains[static_cast<size_t>(command.aux)] != command.domain) {
                error = "country_research_domain_mismatch"; break;
            }
            int32_t found_domain = -1, found_position = -1;
            for (int32_t domain = 0; domain < 4; ++domain) {
                const size_t length_index = static_cast<size_t>(slot) * 4U + domain;
                const size_t queue_base = length_index * 8U;
                for (int32_t position = 0; position < batch.research_queue_lengths[length_index]; ++position) {
                    if (batch.research_queues[queue_base + position] == command.aux) {
                        found_domain = domain;
                        found_position = position;
                    }
                }
            }
            if (command.opcode == COMMAND_ENQUEUE_RESEARCH && found_domain >= 0) {
                error = "country_research_already_queued"; break;
            }
            if (command.opcode == COMMAND_MOVE_RESEARCH && found_domain < 0) {
                error = "country_research_not_queued"; break;
            }
            if (found_domain >= 0) {
                const size_t old_length_index = static_cast<size_t>(slot) * 4U + found_domain;
                const size_t old_base = old_length_index * 8U;
                uint8_t &old_length = batch.research_queue_lengths[old_length_index];
                for (int32_t i = found_position + 1; i < old_length; ++i)
                    batch.research_queues[old_base + i - 1] = batch.research_queues[old_base + i];
                batch.research_queues[old_base + --old_length] = -1;
            }
            const size_t length_index = static_cast<size_t>(slot) * 4U + command.domain;
            const size_t queue_base = length_index * 8U;
            uint8_t &length = batch.research_queue_lengths[length_index];
            if (length >= 8) { error = "country_research_queue_full"; break; }
            const int32_t insert_at = command.position < 0 ? length :
                std::min<int32_t>(command.position, length);
            for (int32_t i = length; i > insert_at; --i)
                batch.research_queues[queue_base + i] = batch.research_queues[queue_base + i - 1];
            batch.research_queues[queue_base + insert_at] = command.aux;
            ++length;
            batch.research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_REMOVE_RESEARCH) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            bool removed = false;
            for (int32_t domain = 0; domain < 4 && !removed; ++domain) {
                const size_t length_index = static_cast<size_t>(slot) * 4U + domain;
                const size_t queue_base = length_index * 8U;
                uint8_t &length = batch.research_queue_lengths[length_index];
                for (int32_t position = 0; position < length; ++position) {
                    if (batch.research_queues[queue_base + position] != command.aux) continue;
                    for (int32_t i = position + 1; i < length; ++i)
                        batch.research_queues[queue_base + i - 1] = batch.research_queues[queue_base + i];
                    batch.research_queues[queue_base + --length] = -1;
                    removed = true;
                    break;
                }
            }
            if (!removed) { error = "country_research_not_queued"; break; }
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_SET_RESEARCH_BUDGET) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.value < 0 || (command.aux != 0 && command.aux != 1)) {
                error = "country_research_budget_invalid"; break;
            }
            batch.research_daily_budgets[static_cast<size_t>(slot)] = command.value;
            batch.research_auto_purchase[static_cast<size_t>(slot)] = static_cast<uint8_t>(command.aux);
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_REVEAL_ALL_TECHNOLOGIES) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
                batch.discovered[static_cast<size_t>(slot) * _technology_words + tech / 64] |=
                    1ULL << (tech % 64);
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_research_signal_ids.size()) ||
                command.cell < 0 || command.cell >= _cell_count) {
                error = "country_research_signal_command_invalid";
                break;
            }
            const uint64_t observation_key =
                (static_cast<uint64_t>(static_cast<uint32_t>(command.aux)) << 32U) |
                static_cast<uint32_t>(command.cell);
            std::vector<uint64_t> &observed_cells = batch.signal_cells[static_cast<size_t>(slot)];
            const auto observed_it = std::lower_bound(
                observed_cells.begin(), observed_cells.end(), observation_key);
            if (observed_it == observed_cells.end() || *observed_it != observation_key) {
                observed_cells.insert(observed_it, observation_key);
                if (_research_signal_words > 0) {
                    batch.signals[static_cast<size_t>(slot) * _research_signal_words +
                                  command.aux / 64] |= uint64_t{1} << (command.aux % 64);
                }
                std::vector<SignalEvidence> &evidence =
                    batch.signal_evidence[static_cast<size_t>(slot)];
                auto evidence_it = std::lower_bound(
                    evidence.begin(), evidence.end(), command.aux,
                    [](const SignalEvidence &entry, int32_t signal) {
                        return entry.signal < signal;
                    });
                if (evidence_it == evidence.end() || evidence_it->signal != command.aux) {
                    SignalEvidence entry;
                    entry.signal = command.aux;
                    entry.count = 0;
                    entry.first_day = command.effective_day;
                    entry.last_day = command.effective_day;
                    entry.first_cell = command.cell;
                    evidence_it = evidence.insert(evidence_it, entry);
                }
                ++evidence_it->count;
                evidence_it->last_day = command.effective_day;
                ++batch.countries.state_version[static_cast<size_t>(slot)];
                mark_country(slot);
                event_country_handle = command.target_handle;
                event_new_country_slot = slot;
            }
        } else if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
                   command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            const bool needs_value =
                command.opcode != COMMAND_CLEAR_TAX_OVERRIDE;
            if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
                (needs_value &&
                 (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
                  !tax_value_valid(command.tax_assessment_mode,
                                  command.tax_rate_basis_points)))) {
                error = "country_tax_command_invalid";
                break;
            }
            if (command.opcode == COMMAND_SET_TAX_DEFAULT) {
                const size_t index =
                    static_cast<size_t>(slot) * TAX_KIND_COUNT +
                    command.tax_kind;
                batch.tax_defaults[index] = command.tax_rate_basis_points;
                batch.tax_default_modes[index] = command.tax_assessment_mode;
            } else {
                const int32_t item_count = tax_item_count(command.tax_kind);
                if (command.tax_item < 0 || command.tax_item >= item_count) {
                    error = "country_tax_item_invalid";
                    break;
                }
                std::vector<int32_t> *overrides = nullptr;
                std::vector<int32_t> *mode_overrides = nullptr;
                switch (command.tax_kind) {
                    case TAX_INCOME:
                        overrides = &batch.income_tax_overrides;
                        mode_overrides = &batch.income_tax_mode_overrides;
                        break;
                    case TAX_CONSUMPTION:
                        overrides = &batch.consumption_tax_overrides;
                        mode_overrides =
                            &batch.consumption_tax_mode_overrides;
                        break;
                    case TAX_BUSINESS:
                        overrides = &batch.business_tax_overrides;
                        mode_overrides = &batch.business_tax_mode_overrides;
                        break;
                    case TAX_IMPORT:
                        overrides = &batch.import_tax_overrides;
                        mode_overrides = &batch.import_tax_mode_overrides;
                        break;
                    case TAX_EXPORT:
                        overrides = &batch.export_tax_overrides;
                        mode_overrides = &batch.export_tax_mode_overrides;
                        break;
                    default: break;
                }
                if (overrides == nullptr || mode_overrides == nullptr) {
                    error = "country_tax_kind_invalid";
                    break;
                }
                const size_t index =
                    static_cast<size_t>(slot) * item_count + command.tax_item;
                if (command.opcode == COMMAND_CLEAR_TAX_OVERRIDE) {
                    (*overrides)[index] = TAX_RATE_INHERIT;
                    (*mode_overrides)[index] = TAX_MODE_INHERIT;
                } else {
                    (*overrides)[index] = command.tax_rate_basis_points;
                    (*mode_overrides)[index] = command.tax_assessment_mode;
                }
            }
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
                   command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                owner_of(command.cell) != slot) {
                error = "country_cell_tax_territory_invalid";
                break;
            }
            CellTaxPolicy &policy = staged_cell_policy(command.cell);
            if (command.opcode == COMMAND_CLEAR_CELL_TAX_POLICY) {
                policy = CellTaxPolicy{};
            } else if (command.tax_kind < 0 ||
                       command.tax_kind >= TAX_KIND_COUNT) {
                error = "country_cell_tax_kind_invalid";
                break;
            } else if (command.opcode == COMMAND_SET_CELL_TAX_DEFAULT) {
                if (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
                    !tax_value_valid(command.tax_assessment_mode,
                                    command.tax_rate_basis_points)) {
                    error = "country_cell_tax_rate_invalid";
                    break;
                }
                policy.defaults[static_cast<size_t>(command.tax_kind)] =
                    command.tax_rate_basis_points;
                policy.default_modes[static_cast<size_t>(command.tax_kind)] =
                    command.tax_assessment_mode;
            } else if (command.opcode == COMMAND_CLEAR_CELL_TAX_DEFAULT) {
                policy.defaults[static_cast<size_t>(command.tax_kind)] =
                    TAX_RATE_INHERIT;
                policy.default_modes[static_cast<size_t>(command.tax_kind)] =
                    TAX_MODE_INHERIT;
            } else {
                if (command.tax_item < 0 ||
                    command.tax_item >= tax_item_count(command.tax_kind)) {
                    error = "country_cell_tax_item_invalid";
                    break;
                }
                const auto key_less = [](const CellTaxOverride &entry,
                                         const std::pair<int32_t, int32_t> &key) {
                    return entry.kind < key.first ||
                        (entry.kind == key.first && entry.item < key.second);
                };
                const std::pair<int32_t, int32_t> key{
                    command.tax_kind, command.tax_item};
                auto entry = std::lower_bound(policy.overrides.begin(),
                                              policy.overrides.end(), key,
                                              key_less);
                const bool exists = entry != policy.overrides.end() &&
                    entry->kind == command.tax_kind &&
                    entry->item == command.tax_item;
                if (command.opcode == COMMAND_CLEAR_CELL_TAX_OVERRIDE) {
                    if (exists) policy.overrides.erase(entry);
                } else {
                    if (!tax_assessment_mode_valid(
                            command.tax_assessment_mode) ||
                        !tax_value_valid(command.tax_assessment_mode,
                                        command.tax_rate_basis_points)) {
                        error = "country_cell_tax_rate_invalid";
                        break;
                    }
                    const CellTaxOverride replacement{
                        command.tax_kind, command.tax_item,
                        command.tax_rate_basis_points,
                        command.tax_assessment_mode};
                    if (exists) *entry = replacement;
                    else policy.overrides.insert(entry, replacement);
                }
            }
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        }
        // The public event ring retains at most 2048 records. Avoid staging
        // tens of thousands of events that would be discarded immediately by
        // keeping the deterministic tail of very large atomic batches.
        if (command.opcode != COMMAND_TRANSFER_TERRITORY ||
            batch.commands.size() <= 2048 || batch.cursor + 2048 >= batch.commands.size()) {
            Event event;
            event.day = day;
            event.opcode = command.opcode;
            event.country_handle = event_country_handle;
            event.cell = command.cell;
            event.old_country_slot = event_old_country_slot;
            event.new_country_slot = event_new_country_slot;
            event.technology_id = command.aux;
            event.signal_id = command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL
                ? command.aux : -1;
            event.signal_source_kind = command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL
                ? static_cast<int32_t>(command.value) : 0;
            event.evidence_delta = command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL &&
                event_country_handle != 0 ? 1 : 0;
            event.stable_id = command.stable_id;
            event.display_name = command.display_name;
            batch.events.push_back(std::move(event));
        }
    }
    batch.preflight_ms += elapsed_ms(start);

    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        const uint64_t command_hash = reference_command_hash(batch.commands);
        const uint64_t command_count =
            static_cast<uint64_t>(batch.commands.size());
        for (const Command &command : batch.commands) {
            push_typed_receipt(command,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION, error);
            if (command.effect_request_id == 0) continue;
            EffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        record_reference_frame("command_rejected", day, false, false,
                               command_hash, command_count);
        close_boundary_seal();
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.stage = "command_preflight";
        result.reason = error;
        result.preflight_ms = preflight_ms;
        result.elapsed_ms = preflight_ms;
        return false;
    }

    if (batch.cursor < batch.commands.size()) {
        record_reference_frame("command_preflight", day, false, true,
            reference_command_hash(batch.commands),
            static_cast<uint64_t>(batch.commands.size()));
        result.status = CountryCoreStepStatus::PROGRESS;
        result.done = false;
        result.day_barrier = true;
        result.stage = "command_preflight";
        result.preflight_ms = batch.preflight_ms;
        result.elapsed_ms = batch.preflight_ms;
        result.cursor_start = static_cast<int64_t>(cursor_start);
        result.cursor_end = static_cast<int64_t>(batch.cursor);
        result.cursor_total = static_cast<int64_t>(batch.commands.size());
        result.progress_ratio = static_cast<double>(batch.cursor) /
            static_cast<double>(batch.commands.size());
        return false;
    }

    for (size_t slot = 0; slot < batch.countries.active.size(); ++slot) {
        if (batch.countries.active[slot] != 0 && batch.countries.territory_count[slot] <= 0) {
                error = "country_last_territory_protected";
            break;
        }
    }
    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        const uint64_t command_hash = reference_command_hash(batch.commands);
        const uint64_t command_count =
            static_cast<uint64_t>(batch.commands.size());
        for (const Command &command : batch.commands) {
            push_typed_receipt(command,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION, error);
            if (command.effect_request_id == 0) continue;
            EffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        record_reference_frame("command_rejected", day, false, false,
                               command_hash, command_count);
        close_boundary_seal();
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.stage = "command_preflight";
        result.reason = error;
        result.preflight_ms = preflight_ms;
        result.elapsed_ms = preflight_ms;
        return false;
    }
    return true;

}


bool NativeCountryRuntime::commit_country_slice(
        CoreSliceContext &context) {
    auto &result = context.result;
    CommandBatchState &batch = _command_batch;
    const int64_t day = context.day;
    const size_t cursor_limit = context.cursor_limit;
    const double preflight_ms = batch.preflight_ms;
    const uint64_t reference_batch_hash = reference_command_hash(batch.commands);
    const uint64_t reference_batch_count =
        static_cast<uint64_t>(batch.commands.size());
    const int32_t changed_country_count = static_cast<int32_t>(std::count(
        batch.changed_countries.begin(), batch.changed_countries.end(), uint8_t{1}));
    SparseCellDelta cell_delta = std::move(batch.cell_delta);
    std::vector<int32_t> cell_delta_order = std::move(batch.cell_delta_order);
    std::vector<int32_t> direct_cell_owners = std::move(batch.direct_cell_owners);
    const bool direct_unique_territory = batch.direct_unique_territory;
    std::vector<Event> staged_events = std::move(batch.events);
    CountryStore staged_countries = std::move(batch.countries);
    std::vector<uint64_t> staged_technologies = std::move(batch.technologies);
    std::vector<int64_t> staged_goods = std::move(batch.goods);
    std::vector<uint64_t> staged_discovered = std::move(batch.discovered);
    std::vector<uint64_t> staged_pending = std::move(batch.pending);
    auto staged_progress = std::move(batch.progress);
    std::vector<int32_t> staged_research_queues = std::move(batch.research_queues);
    std::vector<uint8_t> staged_research_queue_lengths = std::move(batch.research_queue_lengths);
    std::vector<int32_t> staged_research_weights = std::move(batch.research_weights_bp);
    std::vector<uint8_t> staged_auto_purchase = std::move(batch.research_auto_purchase);
    std::vector<int64_t> staged_daily_budgets = std::move(batch.research_daily_budgets);
    std::vector<int64_t> staged_deferred_points = std::move(batch.research_deferred_points);
    std::vector<uint64_t> staged_signals = std::move(batch.signals);
    auto staged_signal_cells = std::move(batch.signal_cells);
    auto staged_signal_evidence = std::move(batch.signal_evidence);
    std::vector<int32_t> staged_tax_defaults =
        std::move(batch.tax_defaults);
    std::vector<int32_t> staged_tax_default_modes =
        std::move(batch.tax_default_modes);
    std::vector<int32_t> staged_income_tax =
        std::move(batch.income_tax_overrides);
    std::vector<int32_t> staged_consumption_tax =
        std::move(batch.consumption_tax_overrides);
    std::vector<int32_t> staged_business_tax =
        std::move(batch.business_tax_overrides);
    std::vector<int32_t> staged_import_tax =
        std::move(batch.import_tax_overrides);
    std::vector<int32_t> staged_export_tax =
        std::move(batch.export_tax_overrides);
    std::vector<int32_t> staged_income_tax_modes =
        std::move(batch.income_tax_mode_overrides);
    std::vector<int32_t> staged_consumption_tax_modes =
        std::move(batch.consumption_tax_mode_overrides);
    std::vector<int32_t> staged_business_tax_modes =
        std::move(batch.business_tax_mode_overrides);
    std::vector<int32_t> staged_import_tax_modes =
        std::move(batch.import_tax_mode_overrides);
    std::vector<int32_t> staged_export_tax_modes =
        std::move(batch.export_tax_mode_overrides);
    auto staged_cell_tax_updates = std::move(batch.cell_tax_updates);
    auto staged_treasury_consumed = std::move(batch.treasury_consumed);
    const bool stage_technologies = batch.stage_technologies;
    const bool stage_goods = batch.stage_goods;
    const bool stage_research = batch.stage_research;
    const bool stage_signals = batch.stage_signals;
    const bool stage_tax = batch.stage_tax;
    const bool stage_cell_tax = batch.stage_cell_tax;
    const int64_t observation_batch_input = batch.observation_batch_input;
    const int64_t observation_batch_added = batch.observation_batch_added;
    std::vector<std::pair<int32_t, int32_t>> signal_refreshes;
    if (stage_signals) {
        signal_refreshes.reserve(batch.commands.size());
        for (const Command &command : batch.commands) {
            if (command.opcode != COMMAND_DISCOVER_COUNTRY_SIGNAL) continue;
            int32_t signal_slot = -1;
            if (!validate_handle(command.target_handle, signal_slot)) continue;
            signal_refreshes.emplace_back(signal_slot, command.aux);
        }
        std::sort(signal_refreshes.begin(), signal_refreshes.end());
        signal_refreshes.erase(std::unique(signal_refreshes.begin(), signal_refreshes.end()),
                               signal_refreshes.end());
    }
    std::vector<Command> committed_typed_commands;
    for (const Command &command : batch.commands) {
        if (command.request_id != 0) {
            Command receipt_command;
            receipt_command.request_id = command.request_id;
            receipt_command.producer_id = command.producer_id;
            receipt_command.sequence = command.sequence;
            receipt_command.effective_day = command.effective_day;
            committed_typed_commands.push_back(std::move(receipt_command));
        }
        if (command.effect_request_id == 0) continue;
        EffectCommandResult &result = _effect_command_results[command.effect_request_id];
        result.complete = 1; result.ok = 1; result.reason.clear();
    }
    _command_batch = {};

    const Clock::time_point apply_start = Clock::now();
    _countries = std::move(staged_countries);
    if (stage_technologies) _country_technologies = std::move(staged_technologies);
    if (stage_goods) _country_goods = std::move(staged_goods);
    if (!staged_treasury_consumed.empty()) {
        _country_treasury_goods_consumed_total.resize(_countries.active.size(), 0);
        for (const auto &entry : staged_treasury_consumed) {
            if (entry.first < 0 || static_cast<size_t>(entry.first) >=
                    _country_treasury_goods_consumed_total.size()) continue;
            int64_t &total = _country_treasury_goods_consumed_total[
                static_cast<size_t>(entry.first)];
            total = entry.second > std::numeric_limits<int64_t>::max() - total
                ? std::numeric_limits<int64_t>::max() : total + entry.second;
        }
        _state_hash_cache_valid = false;
    }
    if (stage_research) {
        _country_discovered = std::move(staged_discovered);
        _country_pending_technologies = std::move(staged_pending);
        _pending_activation_index_dirty = true;
        _country_research_progress = std::move(staged_progress);
        _country_research_queues = std::move(staged_research_queues);
        _country_research_queue_lengths = std::move(staged_research_queue_lengths);
        _country_research_weights_bp = std::move(staged_research_weights);
        _country_research_auto_purchase = std::move(staged_auto_purchase);
        _country_research_daily_budgets = std::move(staged_daily_budgets);
        _country_research_deferred_points = std::move(staged_deferred_points);
        const size_t country_count = _countries.active.size();
        _country_research_purchased_total.resize(country_count, 0);
        _country_research_consumed_total.resize(country_count, 0);
        _country_treasury_goods_consumed_total.resize(country_count, 0);
        _country_research_progress_total.resize(country_count, 0);
        _country_research_completed_total.resize(country_count, 0);
        _research_modifier_cache.resize(country_count);
        rebuild_research_active_index();
    }
    if (stage_signals) {
        _country_research_signals = std::move(staged_signals);
        _country_research_signal_cells = std::move(staged_signal_cells);
        _country_research_signal_evidence = std::move(staged_signal_evidence);
        for (const auto &entry : signal_refreshes)
            refresh_discovery_for_signal(entry.first, entry.second);
    }
    if (stage_tax) {
        _country_tax_defaults = std::move(staged_tax_defaults);
        _country_tax_default_modes = std::move(staged_tax_default_modes);
        _country_income_tax_overrides = std::move(staged_income_tax);
        _country_consumption_tax_overrides =
            std::move(staged_consumption_tax);
        _country_business_tax_overrides = std::move(staged_business_tax);
        _country_import_tax_overrides = std::move(staged_import_tax);
        _country_export_tax_overrides = std::move(staged_export_tax);
        _country_income_tax_mode_overrides =
            std::move(staged_income_tax_modes);
        _country_consumption_tax_mode_overrides =
            std::move(staged_consumption_tax_modes);
        _country_business_tax_mode_overrides =
            std::move(staged_business_tax_modes);
        _country_import_tax_mode_overrides =
            std::move(staged_import_tax_modes);
        _country_export_tax_mode_overrides =
            std::move(staged_export_tax_modes);
        ++_tax_policy_version;
    }
    if (stage_cell_tax && !staged_cell_tax_updates.empty()) {
        for (auto &entry : staged_cell_tax_updates) {
            const int32_t cell = entry.first;
            const uint32_t old_id =
                _cell_tax_policy_ids[static_cast<size_t>(cell)];
            if (cell_tax_policy(old_id) == entry.second) continue;
            const uint32_t new_id = intern_cell_tax_policy(entry.second);
            _cell_tax_policy_ids[static_cast<size_t>(cell)] = new_id;
            release_cell_tax_policy(old_id);
        }
        ++_tax_policy_version;
    }
    for (size_t i = 0; i < cell_delta_order.size(); ++i) {
        int32_t owner = NEUTRAL_SLOT;
        if (direct_unique_territory || cell_delta.get(cell_delta_order[i], owner)) {
            if (direct_unique_territory) owner = direct_cell_owners[i];
            _cell_country_slot[static_cast<size_t>(cell_delta_order[i])] = owner;
        }
    }
    const double apply_ms = elapsed_ms(apply_start);
    const Clock::time_point publish_start = Clock::now();
    if (!cell_delta_order.empty()) rebuild_cell_csr();
    ++_generation;
    for (const Command &command : committed_typed_commands)
        push_typed_receipt(command, CountryCommandReceiptCode::COMMITTED);
    if (!cell_delta_order.empty()) ++_territory_generation;
    _last_committed_day = day;
    for (Event &event : staged_events) push_event(std::move(event));
    CountryPeerContext peer_context;
    std::string peer_error;
    if (!capture_peer_context(day, _reference_continuation_index,
                              peer_context, peer_error)) {
        result.status = CountryCoreStepStatus::FAULTED;
        result.ok = false;
        result.done = true;
        result.stage = "peer_context_capture";
        result.reason = peer_error.empty()
            ? "country_peer_context_capture_failed" : peer_error;
        close_boundary_seal();
        return false;
    }
    const int32_t research_changed = run_research_day(
        day, &peer_context, &peer_context);
    if (!_peer_protocol_fault_reason.empty()) {
        result.status = CountryCoreStepStatus::FAULTED;
        result.ok = false;
        result.done = true;
        result.stage = "peer_retry";
        result.reason = _peer_protocol_fault_reason;
        close_boundary_seal();
        return false;
    }
    if (report_peer_rejection(day, result)) return false;
    const double aggregate_ms = elapsed_ms(publish_start);
    const bool day_barrier = should_run(day) ||
        ack_chain_due(day, &peer_context);
    result.status = CountryCoreStepStatus::BOUNDARY_COMMITTED;
    result.semantic_commit = true;
    result.day_barrier = day_barrier;
    result.stage = "aggregate_publish";
    result.preflight_ms = preflight_ms;
    result.apply_ms = apply_ms;
    result.publish_ms = aggregate_ms;
    result.elapsed_ms = preflight_ms + apply_ms + aggregate_ms;
    result.cursor_start = 0;
    result.cursor_end = static_cast<int64_t>(cursor_limit);
    result.cursor_total = static_cast<int64_t>(cursor_limit);
    result.progress_ratio = 1.0;
    result.changed_cells = static_cast<int32_t>(cell_delta_order.size());
    result.changed_countries = changed_country_count + research_changed;
    result.published_to_slot =
        _mode == MODE_ACTIVE && !cell_delta_order.empty();
    result.observation_batch_input = observation_batch_input;
    result.observation_batch_added = observation_batch_added;
    if (!cell_delta_order.empty()) {
        if (!std::is_sorted(cell_delta_order.begin(), cell_delta_order.end()))
            std::sort(cell_delta_order.begin(), cell_delta_order.end());
        result.changed_cell_indices.resize(cell_delta_order.size());
        result.changed_cell_owners.resize(cell_delta_order.size());
        for (size_t i = 0; i < cell_delta_order.size(); ++i) {
            result.changed_cell_indices[i] = cell_delta_order[i];
            int32_t owner = direct_unique_territory ? direct_cell_owners[i] : NEUTRAL_SLOT;
            if (!direct_unique_territory) cell_delta.get(cell_delta_order[i], owner);
            result.changed_cell_owners[i] = owner;
        }
    }
    record_reference_frame("aggregate_publish", day, true, day_barrier,
                           reference_batch_hash, reference_batch_count);
    close_boundary_seal();
    return true;

}

} // namespace pk
