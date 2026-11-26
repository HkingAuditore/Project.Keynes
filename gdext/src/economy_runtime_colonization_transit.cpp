#include "economy_runtime_colonization_includes.inc"

namespace pk {
#include "economy_runtime_colonization_internal.h"

bool NativeEconomyRuntime::apply_cancel_family_expedition(
        const Command &cmd, std::string &error) {
    int32_t expedition = -1;
    if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition) ||
            family_expeditions_store().country_handle[expedition] != static_cast<uint64_t>(cmd.i64_1)) {
        error = "colonization_expedition_invalid"; return false;
    }
    if (family_expeditions_store().state[expedition] == EXPEDITION_RETURNING) return true;
    if (family_expeditions_store().state[expedition] == EXPEDITION_PREPARING) {
        abort_preparing_family_expedition(expedition, cmd.effective_day, 2,
            "CANCELLED", cmd.sequence);
        return true;
    }
    if (family_expeditions_store().state[expedition] == EXPEDITION_SETTLING &&
        family_expeditions_store().effect_transaction_id[expedition] != 0) {
        error = "colonization_settlement_already_committed"; return false;
    }
    const int64_t elapsed = std::max<int64_t>(0,
        cmd.effective_day - family_expeditions_store().departure_day[expedition]);
    const int64_t progressed = std::min<int64_t>(
        family_expeditions_store().route_cost[expedition], elapsed *
        std::max(1, family_expeditions_store().speed[expedition]));
    const int64_t return_days = (progressed +
        std::max(1, family_expeditions_store().speed[expedition]) - 1) /
        std::max(1, family_expeditions_store().speed[expedition]);
    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
    release_family_expedition_reservations(expedition);
    note_family_expedition_audit_invalidation();
    family_expeditions_store().due_day.write_scalar(expedition, cmd.effective_day + return_days, market_mutation_sink());
    push_family_expedition_due(expedition);
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        cmd.effective_day, 2, "CANCELLED_RETURNING");
    return true;
}

bool NativeEconomyRuntime::apply_settle_family_expedition(
        const Command &cmd, std::string &error) {
    int32_t expedition = -1;
    if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition))
        return true; // idempotent replay after a successful release.
    if (family_expeditions_store().state[expedition] != EXPEDITION_SETTLING)
        return true;
    const int64_t owner = _country_runtime == nullptr ? 0 :
        country_reads().country_handle_for_cell(
            family_expeditions_store().target_cell[expedition]);
    bool claimed = cmd.i64_0 != 0;
    if (!claimed && _effect_runtime != nullptr)
        claimed = _effect_runtime->family_colonization_includes_claim(
            family_expeditions_store().effect_transaction_id[expedition]);
    if (owner != static_cast<int64_t>(
            family_expeditions_store().country_handle[expedition])) {
        // Under Country worker authority the paired CLAIM commits on the
        // worker's own boundary, so an unowned target here means the claim is
        // not visible yet — not that someone else took the cell. Yield the
        // slice with backpressure instead of condemning the expedition; the
        // command replays intact once the committed snapshot carries the claim.
        // Treating this window as TARGET_LOST left the cell claimed by the
        // player while the settlers were sent home, so the cell kept 0 people.
        if (owner == 0) {
            error = "country_economy_asset_territory_claim_pending";
            return false;
        }
        family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
        release_family_expedition_reservations(expedition);
        note_family_expedition_audit_invalidation();
        family_expeditions_store().due_day.write_scalar(expedition, _current_day.get() +
            std::max<int64_t>(1, (family_expeditions_store().route_cost[expedition] +
                family_expeditions_store().speed[expedition] - 1) /
                family_expeditions_store().speed[expedition]), market_mutation_sink());
        push_family_expedition_due(expedition);
        append_colonization_receipt(expedition, cmd.sequence,
            cmd.effective_day, _current_day.get(), 3, "TARGET_LOST_RETURNING");
        return true;
    }
    const int32_t destination = family_expeditions_store().target_cell[expedition];
    const uint64_t country_handle = family_expeditions_store().country_handle[expedition];
    if (!restore_family_expedition_payload(expedition, destination, error))
        return false;
    if (!settle_family_expedition_kit(expedition, destination, error))
        return false;
    if (cmd.i32_1 > 0)
        apply_family_colonization_population_reward(destination,
            family_expeditions_store().family_handle[expedition], cmd.i32_1);
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        _current_day.get(), claimed ? 4 : 6, claimed ? "CLAIMED" : "RELOCATED");
    _family_expedition_target_index.erase(family_expedition_target_key(
        country_handle, destination));
    family_expeditions_store().release(expedition);
    return finalize_immediate_family_expedition_settlement(destination, error);
}

bool NativeEconomyRuntime::family_expedition_settle_inflight(
        uint64_t expedition_handle) const {
    auto is_settle = [&](const Command &cmd) {
        return cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION &&
               cmd.target_handle == expedition_handle;
    };
    for (const Command &cmd : _pending_commands)
        if (is_settle(cmd)) return true;
    for (const Command &cmd : _epoch_commands)
        if (is_settle(cmd)) return true;
    return false;
}

void NativeEconomyRuntime::recover_lost_family_settlement_commands() {
    if (_effect_runtime == nullptr) return;
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().state[expedition] != EXPEDITION_SETTLING)
            continue;
        const uint64_t handle = family_expeditions_store().handle_for_index(expedition);
        if (handle == 0 || family_expedition_settle_inflight(handle)) continue;
        const uint64_t settle_key =
            _effect_runtime->family_colonization_settle_idempotency_key(
                family_expeditions_store().stable_id[expedition],
                family_expeditions_store().generation[expedition],
                family_expeditions_store().idempotency_key[expedition]);
        const auto found = _effect_idempotency_requests.find(settle_key);
        if (found == _effect_idempotency_requests.end()) continue;
        const auto result = _effect_command_results.find(found->second);
        if (result == _effect_command_results.end() ||
            result->second.complete != 0) continue;
        Command command;
        command.opcode = COMMAND_SETTLE_FAMILY_EXPEDITION;
        command.effective_day = _current_day.get();
        command.sequence = static_cast<int64_t>(settle_key & 0x7fffffffffffffffULL);
        command.target_handle = handle;
        command.i32_0 = family_expeditions_store().target_cell[expedition];
        command.i32_1 = _effect_runtime->family_colonization_population_reward(
            family_expeditions_store().effect_transaction_id[expedition]);
        command.i64_0 = _effect_runtime->family_colonization_includes_claim(
            family_expeditions_store().effect_transaction_id[expedition]) ? 1 : 0;
        command.i64_1 = static_cast<int64_t>(
            family_expeditions_store().country_handle[expedition]);
        command.submit_order = _next_submit_order++;
        command.effect_request_id = found->second;
        command.effect_idempotency_key = settle_key;
        queue_family_settlement_command(command);
    }
}

bool NativeEconomyRuntime::stage_allows_in_epoch_family_settlement() const {
    if (!_epoch_active || _fatal) return false;
    switch (_stage) {
        case Stage::EPOCH_BEGIN:
        case Stage::TRADE_PLANNING:
        case Stage::BUILDING_PLAN:
        case Stage::TRADE_SETTLE:
        case Stage::LEDGER_APPLY:
            return true;
        default:
            return false;
    }
}

void NativeEconomyRuntime::queue_family_settlement_command(
        const Command &command) {
    if (_epoch_active && stage_allows_in_epoch_family_settlement())
        _epoch_commands.push_back(command);
    else
        _pending_commands.push_back(command);
}

bool NativeEconomyRuntime::process_due_family_expeditions(
        int64_t day, std::string &error) {
    const auto started = std::chrono::steady_clock::now();
    if (!settle_family_expedition_procurement_orphans(error)) return false;
    while (!_family_expedition_due_heap.empty()) {
        const auto top = _family_expedition_due_heap.front();
        if (top.first > day) break;
        std::pop_heap(_family_expedition_due_heap.begin(),
                      _family_expedition_due_heap.end(), due_heap_less);
        _family_expedition_due_heap.pop_back();
        const int32_t expedition = top.second;
        if (expedition < 0 || expedition >= static_cast<int32_t>(
                family_expeditions_store().active.size()) ||
            family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().due_day[expedition] != top.first) continue;
        if (family_expeditions_store().state[expedition] == EXPEDITION_PREPARING) {
            if (!advance_preparing_family_expedition(expedition, day, error))
                return false;
            continue;
        }
        if (family_expeditions_store().state[expedition] == EXPEDITION_SETTLING) {
            const int64_t transaction_id =
                family_expeditions_store().effect_transaction_id[expedition];
            int64_t resolved_transaction_id = 0;
            const int32_t status = _effect_runtime == nullptr ? 0 :
                _effect_runtime->family_colonization_transaction_status_pod(
                    transaction_id,
                    family_expeditions_store().stable_id[expedition],
                    family_expeditions_store().generation[expedition],
                    family_expeditions_store().idempotency_key[expedition],
                    &resolved_transaction_id);
            if (resolved_transaction_id != 0 &&
                resolved_transaction_id != transaction_id) {
                family_expeditions_store().effect_transaction_id.write_scalar(
                    expedition, resolved_transaction_id, market_mutation_sink());
            }
            if (status == EffectRuntime::REJECTED ||
                status == EffectRuntime::RESYNC_REQUIRED) {
                const int64_t consume_id = resolved_transaction_id != 0
                    ? resolved_transaction_id : transaction_id;
                if (_effect_runtime != nullptr && consume_id != 0)
                    _effect_runtime->consume_rejected_transaction_pod(
                        consume_id,
                        family_expeditions_store().stable_id[expedition]);
                family_expeditions_store().effect_transaction_id.write_scalar(expedition, 0, market_mutation_sink());
                family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
                release_family_expedition_reservations(expedition);
                family_expeditions_store().due_day.write_scalar(expedition, day +
                    std::max<int64_t>(1,
                        (family_expeditions_store().route_cost[expedition] +
                         family_expeditions_store().speed[expedition] - 1) /
                        family_expeditions_store().speed[expedition]), market_mutation_sink());
                push_family_expedition_due(expedition);
                append_colonization_receipt(expedition, 0,
                    family_expeditions_store().departure_day[expedition], day, 3,
                    "TARGET_LOST_RETURNING");
            } else if (status == 0 && _effect_runtime != nullptr) {
                // Builtin transaction is absent from EffectRuntime (for example
                // in an older save whose colonization tx ID collided with a
                // worker POD snapshot). Re-check ownership and re-enqueue
                // idempotently so the expedition cannot park in SETTLING forever.
                const int64_t owner = _country_runtime == nullptr ? 0 :
                    country_reads().country_handle_for_cell(
                        family_expeditions_store().target_cell[expedition]);
                if (_country_runtime == nullptr ||
                    (owner != 0 && owner != static_cast<int64_t>(
                        family_expeditions_store().country_handle[expedition]))) {
                    family_expeditions_store().effect_transaction_id.write_scalar(expedition, 0, market_mutation_sink());
                    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
                    release_family_expedition_reservations(expedition);
                    family_expeditions_store().due_day.write_scalar(expedition, day +
                        std::max<int64_t>(1,
                            (family_expeditions_store().route_cost[expedition] +
                             family_expeditions_store().speed[expedition] - 1) /
                            family_expeditions_store().speed[expedition]), market_mutation_sink());
                    push_family_expedition_due(expedition);
                    append_colonization_receipt(expedition, 0,
                        family_expeditions_store().departure_day[expedition], day, 3,
                        "TARGET_LOST_RETURNING");
                } else {
                    const uint64_t handle =
                        family_expeditions_store().handle_for_index(expedition);
                    int64_t re_transaction_id = 0;
                    const bool claim_unowned = owner == 0;
                    const int32_t population_reward =
                        family_colonization_population_reward_amount(
                            family_expeditions_store().family_handle[expedition]);
                    if (!_effect_runtime->enqueue_family_colonization_pod(
                            family_expeditions_store().stable_id[expedition], day,
                            family_expeditions_store().stable_id[expedition],
                            family_expeditions_store().country_handle[expedition],
                            static_cast<uint32_t>(
                                family_expeditions_store().country_handle[expedition] >> 32U),
                            handle, family_expeditions_store().generation[expedition],
                            family_expeditions_store().target_cell[expedition],
                            family_expeditions_store().idempotency_key[expedition], error,
                            &re_transaction_id, claim_unowned, population_reward))
                        return false;
                    family_expeditions_store().effect_transaction_id.write_scalar(
                        expedition, re_transaction_id, market_mutation_sink());
                    family_expeditions_store().due_day.write_scalar(
                        expedition, day + 1, market_mutation_sink());
                    push_family_expedition_due(expedition);
                }
            } else {
                family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
                push_family_expedition_due(expedition);
            }
            continue;
        }
        if (family_expeditions_store().state[expedition] == EXPEDITION_RETURNING) {
            const int32_t source_cell =
                family_expeditions_store().source_cell[expedition];
            if (!restore_family_expedition_payload(expedition,
                    source_cell, error)) return false;
            if (!restore_family_expedition_cargo(expedition,
                    source_cell, false, error))
                return false;
            if (!repair_cell_merchant_and_rebuild(source_cell, error))
                return false;
            note_family_expedition_audit_invalidation();
            append_colonization_receipt(expedition, 0,
                family_expeditions_store().departure_day[expedition], day, 5, "RETURNED");
            _family_expedition_target_index.erase(family_expedition_target_key(
                family_expeditions_store().country_handle[expedition],
                family_expeditions_store().target_cell[expedition]));
            family_expeditions_store().release(expedition);
            continue;
        }
        if (family_expeditions_store().state[expedition] == EXPEDITION_OUTBOUND) {
            const int64_t owner = _country_runtime == nullptr ? 0 :
                country_reads().country_handle_for_cell(
                    family_expeditions_store().target_cell[expedition]);
            if (_country_runtime == nullptr ||
                (owner != 0 && owner != static_cast<int64_t>(
                    family_expeditions_store().country_handle[expedition]))) {
                family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
                release_family_expedition_reservations(expedition);
                family_expeditions_store().due_day.write_scalar(expedition, day +
                    std::max<int64_t>(1, (family_expeditions_store().route_cost[expedition] +
                        family_expeditions_store().speed[expedition] - 1) /
                        family_expeditions_store().speed[expedition]), market_mutation_sink());
                push_family_expedition_due(expedition);
                append_colonization_receipt(expedition, 0,
                    family_expeditions_store().departure_day[expedition], day, 3,
                    "TARGET_LOST_RETURNING");
                continue;
            }
            if (_effect_runtime == nullptr) {
                error = "colonization_effect_runtime_unavailable"; return false;
            }
            const uint64_t handle =
                family_expeditions_store().handle_for_index(expedition);
            int64_t transaction_id = 0;
            const bool claim_unowned = owner == 0;
            const int32_t population_reward =
                family_colonization_population_reward_amount(
                    family_expeditions_store().family_handle[expedition]);
            if (!_effect_runtime->enqueue_family_colonization_pod(
                    family_expeditions_store().stable_id[expedition], day,
                    family_expeditions_store().stable_id[expedition],
                    family_expeditions_store().country_handle[expedition],
                    static_cast<uint32_t>(
                        family_expeditions_store().country_handle[expedition] >> 32U),
                    handle, family_expeditions_store().generation[expedition],
                    family_expeditions_store().target_cell[expedition],
                    family_expeditions_store().idempotency_key[expedition], error,
                    &transaction_id, claim_unowned, population_reward)) return false;
            family_expeditions_store().effect_transaction_id.write_scalar(expedition, transaction_id, market_mutation_sink());
            family_expeditions_store().state.write_scalar(expedition, EXPEDITION_SETTLING, market_mutation_sink());
            family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
            push_family_expedition_due(expedition);
        }
    }
    _colonization_cross_domain_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return true;
}

void NativeEconomyRuntime::rebuild_family_expedition_indices() {
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _family_expedition_procurement_rejections.clear();
    _family_expedition_procurement_orphans.clear();
    for (int32_t i = 0; i < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++i) {
        if (family_expeditions_store().active[i] == 0) continue;
        _family_expedition_target_index[family_expedition_target_key(
            family_expeditions_store().country_handle[i],
            family_expeditions_store().target_cell[i])] = i;
        if (family_expeditions_store().state[i] != EXPEDITION_RETURNING) {
            const uint32_t begin = family_expeditions_store().payload_begin[i];
            const uint32_t end = std::min<uint32_t>(begin +
                family_expeditions_store().payload_count[i], static_cast<uint32_t>(
                    family_expedition_payloads().size()));
            reserve_family_expedition_payload_slots(i, begin, end, false);
        }
        if (family_expeditions_store().due_day[i] !=
                std::numeric_limits<int64_t>::max())
            push_family_expedition_due(i);
    }
}

} // namespace pk
