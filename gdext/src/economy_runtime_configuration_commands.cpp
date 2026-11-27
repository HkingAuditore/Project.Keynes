#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "economy_host_port.h"
#include "parallel_dispatcher.h"
#include "runtime_economy_pod.h"

#include <algorithm>
#include <limits>
#include <numeric>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/variant/utility_functions.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

Dictionary NativeEconomyRuntime::submit_commands(const Dictionary &batch) {
    Dictionary out;
    if (!_bootstrapped || _fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                                         : (_fatal ? "economy_fatal" : "save_restore_active");
        return out;
    }
    // Phase-2.4.5: fail-closed legacy ingress when worker owns ECONOMY or the
    // StageOps production writer is effective.
    if (_sync_writes_forbidden ||
        (_simulation_host != nullptr &&
         _simulation_host->economy_production_writer_effective() ==
             EconomyProductionWriter::STAGE_OPS)) {
        out["ok"] = false;
        out["reason"] = "economy_legacy_ingress_disabled";
        return out;
    }
    const std::vector<int32_t> opcodes = packed_i32(batch, "opcodes");
    const std::vector<int64_t> days = packed_i64(batch, "effective_days");
    const std::vector<int64_t> sequences = packed_i64(batch, "sequences");
    const std::vector<int64_t> handles = packed_i64(batch, "target_handles");
    const std::vector<int32_t> i32_0 = packed_i32(batch, "i32_0");
    const std::vector<int32_t> i32_1 = packed_i32(batch, "i32_1");
    const std::vector<int64_t> i64_0 = packed_i64(batch, "i64_0");
    const std::vector<int64_t> i64_1 = packed_i64(batch, "i64_1");
    const size_t n = opcodes.size();
    if (days.size() != n || sequences.size() != n || handles.size() != n ||
        i32_0.size() != n || i32_1.size() != n || i64_0.size() != n || i64_1.size() != n) {
        out["ok"] = false;
        out["reason"] = "command_batch_size_mismatch";
        return out;
    }
    if (_pending_commands.size() + n > 1000000ULL) {
        out["ok"] = false;
        out["reason"] = "command_queue_capacity_exceeded";
        return out;
    }
    // Preflight the whole batch before mutating the queue.
    for (size_t i = 0; i < n; ++i) {
        const bool family_reward = is_family_ledger_command(opcodes[i]);
        const bool split_policy = opcodes[i] == COMMAND_FAMILY_SET_SPLIT_POLICY;
        const bool allowed_opcode =
            (opcodes[i] >= COMMAND_TRANSFER_TO_COHORT &&
             opcodes[i] <= COMMAND_TREASURY_SPONSORED_BUILD) ||
            family_reward || split_policy || opcodes[i] == COMMAND_MILITARY_PROCUREMENT_DEMAND ||
            opcodes[i] == COMMAND_MILITARY_PURCHASE || opcodes[i] == COMMAND_MILITARY_PURCHASE_ACK;
        if (!allowed_opcode || days[i] < 0 || sequences[i] < 0 ||
            (i64_0[i] < 0 && opcodes[i] != COMMAND_ADD_POPULATION &&
             opcodes[i] != COMMAND_FAMILY_PURCHASE_DISCOUNT &&
             opcodes[i] != COMMAND_FAMILY_ABSORB_ANONYMOUS)) {
            out["ok"] = false;
            out["reason"] = "command_entry_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (opcodes[i] == COMMAND_MILITARY_PROCUREMENT_DEMAND) {
            Command demand;
            demand.opcode = opcodes[i];
            demand.effective_day = days[i];
            demand.sequence = sequences[i];
            demand.target_handle = static_cast<uint64_t>(handles[i]);
            demand.i32_0 = i32_0[i];
            demand.i32_1 = i32_1[i];
            demand.i64_0 = i64_0[i];
            demand.i64_1 = i64_1[i];
            if (!military_procurement_demand_valid(demand)) {
                out["ok"] = false;
                out["reason"] = "military_procurement_demand_invalid";
                return out;
            }
        }
        const bool treasury_build =
            opcodes[i] == COMMAND_TREASURY_SPONSORED_BUILD;
        // The sponsored demolish lane names a country handle in `target_handle`
        // exactly like the build lane, so it must skip the cohort-handle probe
        // for the same reason.
        const bool treasury_demolish =
            opcodes[i] == COMMAND_TREASURY_SPONSORED_DEMOLISH;
        if (!family_reward && !treasury_build && !treasury_demolish && !split_policy &&
            opcodes[i] != COMMAND_MILITARY_PROCUREMENT_DEMAND &&
            opcodes[i] != COMMAND_MILITARY_PURCHASE && opcodes[i] != COMMAND_MILITARY_PURCHASE_ACK &&
            opcodes[i] != COMMAND_ADD_STOCK &&
            opcodes[i] != COMMAND_REMOVE_STOCK &&
            opcodes[i] != COMMAND_COUNTRY_GOOD_TO_MARKET &&
            opcodes[i] != COMMAND_MARKET_GOOD_TO_COUNTRY) {
            int32_t slot = -1;
            if (!population_store().valid_handle(static_cast<uint64_t>(handles[i]), slot)) {
                out["ok"] = false;
                out["reason"] = "stale_or_invalid_cohort_handle";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_REMOVE_STOCK ||
             opcodes[i] == COMMAND_COUNTRY_GOOD_TO_MARKET ||
             opcodes[i] == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
            (i32_0[i] < 0 || i32_0[i] >= market_store().market_count.get() || i32_1[i] < 0 ||
             i32_1[i] >= market_store().good_count.get())) {
            out["ok"] = false;
            out["reason"] = "command_market_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
            _merchant_primary_slot[i32_0[i]] < 0) {
            out["ok"] = false;
            out["reason"] = "cannot_add_stock_without_local_merchant";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_MOVE_POPULATION &&
             (i32_0[i] < 0 || i32_0[i] >= _cell_count.get())) ||
            (opcodes[i] == COMMAND_CHANGE_SIGNATURE &&
             (i32_0[i] < 0 || i32_0[i] >= static_cast<int32_t>(_signatures.size())))) {
            out["ok"] = false;
            out["reason"] = "command_structural_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_BUILD || opcodes[i] == COMMAND_DEMOLISH ||
             treasury_build || treasury_demolish) &&
            (i32_0[i] < 0 || i32_0[i] >= _cell_count.get() || i32_1[i] < 0 ||
             i32_1[i] >= static_cast<int32_t>(_building_types.size()) || i64_0[i] <= 0)) {
            out["ok"] = false;
            out["reason"] = "command_building_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (treasury_demolish &&
            (i64_1[i] != OWNERSHIP_TREASURY_SPONSORED_PRIVATE ||
             _country_runtime == nullptr ||
             !country_reads().valid_handle(handles[i]))) {
            out["ok"] = false;
            out["reason"] = i64_1[i] != OWNERSHIP_TREASURY_SPONSORED_PRIVATE
                ? "unsupported_ownership_policy"
                : "command_treasury_build_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (treasury_build &&
            (i64_0[i] != 1 ||
             i64_1[i] != OWNERSHIP_TREASURY_SPONSORED_PRIVATE ||
             _country_runtime == nullptr ||
             !country_reads().valid_handle(handles[i]))) {
            out["ok"] = false;
            out["reason"] = i64_1[i] != OWNERSHIP_TREASURY_SPONSORED_PRIVATE
                ? "unsupported_ownership_policy"
                : "command_treasury_build_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (family_reward) {
            Command probe;
            probe.opcode = opcodes[i];
            probe.target_handle = static_cast<uint64_t>(handles[i]);
            probe.i32_0 = i32_0[i];
            probe.i32_1 = i32_1[i];
            probe.i64_0 = i64_0[i];
            probe.i64_1 = i64_1[i];
            if (!family_ledger_command_preflight(probe)) {
                out["ok"] = false;
                out["reason"] = "command_family_reward_target_invalid";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
        if (split_policy) {
            Command probe;
            probe.opcode = opcodes[i];
            probe.target_handle = static_cast<uint64_t>(handles[i]);
            probe.i32_0 = i32_0[i];
            probe.i32_1 = i32_1[i];
            probe.i64_0 = i64_0[i];
            probe.i64_1 = i64_1[i];
            if (!family_split_policy_command_preflight(probe)) {
                out["ok"] = false;
                out["reason"] = "command_family_split_policy_invalid";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
    }
    for (size_t i = 0; i < n; ++i) {
        _pending_commands.push_back({opcodes[i], days[i], sequences[i],
                                     static_cast<uint64_t>(handles[i]), i32_0[i], i32_1[i],
                                     i64_0[i], i64_1[i], _next_submit_order++});
    }
    out["ok"] = true;
    out["accepted"] = static_cast<int64_t>(n);
    out["queued"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeEconomyRuntime::family_ledger_command_preflight(const Command &cmd) const {
    if (!is_family_ledger_command(cmd.opcode)) return false;
    int32_t branch = -1;
    if (!family_influences().valid_handle(cmd.target_handle, branch)) return false;
    if (cmd.opcode == COMMAND_FAMILY_FREE_BUILDING)
        return cmd.i32_0 >= 0 && cmd.i32_0 <= 1 && cmd.i64_0 > 0 &&
            family_free_building_type_id(cmd) >= 0;
    if (cmd.opcode == COMMAND_FAMILY_POPULATION_REWARD)
        return ((cmd.i32_0 >= 0 && cmd.i32_0 <= 1) || cmd.i32_0 == -1) &&
            cmd.i64_0 > 0;
    if (cmd.opcode == COMMAND_FAMILY_ABSORB_ANONYMOUS) {
        if (cmd.i32_0 == 0) return cmd.i64_0 > 0;
        if (cmd.i32_0 == 1) return cmd.i64_0 >= 0;
        return false;
    }
    if (cmd.opcode == COMMAND_FAMILY_PURCHASE_DISCOUNT)
        return cmd.i64_0 >= 0 && cmd.i64_0 <= 4 * Q16_ONE;
    return false;
}

bool NativeEconomyRuntime::family_split_policy_command_preflight(
        const Command &cmd) const {
    if (cmd.opcode != COMMAND_FAMILY_SET_SPLIT_POLICY) return false;
    const int32_t mode = cmd.i32_0 & static_cast<int32_t>(FAMILY_FLAG_SPLIT_MODE_MASK);
    const int32_t gifts = cmd.i32_0 & static_cast<int32_t>(
        FAMILY_FLAG_SPLIT_GIFT_BUILDING | FAMILY_FLAG_SPLIT_GIFT_POPULATION);
    if ((cmd.i32_0 & ~static_cast<int32_t>(FAMILY_FLAG_SPLIT_POLICY_MASK)) != 0)
        return false;
    if (mode != 0 &&
        mode != static_cast<int32_t>(FAMILY_FLAG_SPLIT_RETAIN_ONLY) &&
        mode != static_cast<int32_t>(FAMILY_FLAG_SPLIT_BONUS_WEIGHT) &&
        mode != static_cast<int32_t>(FAMILY_FLAG_SPLIT_REPLACE))
        return false;
    (void)gifts;
    if (cmd.i64_0 < 0 || cmd.i64_0 > 255) return false;
    int32_t family = -1;
    int32_t branch = -1;
    if (families_store().valid_handle(cmd.target_handle, family)) return true;
    return family_influences().valid_handle(cmd.target_handle, branch) &&
        families_store().valid_handle(family_influences().family_handle[branch], family);
}

bool NativeEconomyRuntime::validate_command_pod(const Command &cmd,
                                                std::string &error) const {
    const bool family_reward = is_family_ledger_command(cmd.opcode);
    const bool split_policy = cmd.opcode == COMMAND_FAMILY_SET_SPLIT_POLICY;
    const bool opcode_ok =
        (cmd.opcode >= COMMAND_TRANSFER_TO_COHORT &&
         cmd.opcode <= COMMAND_SETTLE_FAMILY_EXPEDITION) ||
        family_reward || split_policy;
    if (!opcode_ok ||
        cmd.effective_day < 0 || cmd.sequence < 0 ||
        (cmd.i64_0 < 0 && cmd.opcode != COMMAND_ADD_POPULATION &&
         cmd.opcode != COMMAND_FAMILY_PURCHASE_DISCOUNT &&
         cmd.opcode != COMMAND_FAMILY_ABSORB_ANONYMOUS)) {
        error = "command_entry_invalid";
        return false;
    }
    const bool expedition_settle =
        cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION;
    const bool expedition_player =
        cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
        cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION;
    if (!family_reward && !split_policy && !expedition_settle &&
        !expedition_player &&
        cmd.opcode != COMMAND_ADD_STOCK &&
        cmd.opcode != COMMAND_REMOVE_STOCK &&
        cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
        cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY) {
        int32_t slot = -1;
        if (!population_store().valid_handle(cmd.target_handle, slot)) {
            error = "stale_or_invalid_cohort_handle";
            return false;
        }
    }
    if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK ||
         cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
         cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
        (cmd.i32_0 < 0 || cmd.i32_0 >= market_store().market_count.get() ||
         cmd.i32_1 < 0 || cmd.i32_1 >= market_store().good_count.get())) {
        error = "command_market_target_invalid";
        return false;
    }
    if ((cmd.opcode == COMMAND_ADD_STOCK ||
         cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
        (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(
            _merchant_primary_slot.size()) ||
         _merchant_primary_slot[cmd.i32_0] < 0)) {
        error = "cannot_add_stock_without_local_merchant";
        return false;
    }
    if ((cmd.opcode == COMMAND_MOVE_POPULATION &&
         (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count.get())) ||
        (cmd.opcode == COMMAND_CHANGE_SIGNATURE &&
         (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(
             _signatures.size())))) {
        error = "command_structural_target_invalid";
        return false;
    }
    if ((cmd.opcode == COMMAND_BUILD || cmd.opcode == COMMAND_DEMOLISH) &&
        (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count.get() || cmd.i32_1 < 0 ||
         cmd.i32_1 >= static_cast<int32_t>(_building_types.size()) ||
         cmd.i64_0 <= 0)) {
        error = "command_building_target_invalid";
        return false;
    }
    if (family_reward && !family_ledger_command_preflight(cmd)) {
        error = "command_family_reward_target_invalid";
        return false;
    }
    if (split_policy && !family_split_policy_command_preflight(cmd)) {
        error = "command_family_split_policy_invalid";
        return false;
    }
    if (expedition_settle) {
        int32_t expedition = -1;
        if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition) ||
            cmd.i32_0 != family_expeditions_store().target_cell[expedition] ||
            cmd.i64_1 != static_cast<int64_t>(
                family_expeditions_store().country_handle[expedition])) {
            error = "colonization_settlement_target_invalid";
            return false;
        }
    }
    if (expedition_player) {
        if (cmd.opcode == COMMAND_START_FAMILY_EXPEDITION) {
            int32_t family = -1;
            // target_handle 0 是合法输入：无家族移民队。
            if ((cmd.target_handle != 0 &&
                 !families_store().valid_handle(cmd.target_handle, family)) ||
                cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count.get() ||
                cmd.i32_1 < 0 || cmd.i32_1 >= _cell_count.get() ||
                cmd.i64_0 < 1) {
                error = "colonization_command_invalid";
                return false;
            }
        } else {
            int32_t expedition = -1;
            if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition)) {
                error = "colonization_expedition_invalid";
                return false;
            }
        }
    }
    return true;
}

int32_t NativeEconomyRuntime::preflight_effect_commands_pod(
        const EffectCommand *commands, size_t count, std::string &error) const {
    error.clear();
    if (!_bootstrapped || _save.active || _restore.active) {
        error = !_bootstrapped ? "economy_not_bootstrapped" :
            "save_restore_active";
        return EFFECT_PREFLIGHT_RETRY;
    }
    if (_fatal) {
        error = "economy_fatal";
        return EFFECT_PREFLIGHT_REJECT;
    }
    if ((commands == nullptr && count != 0) || count > 1000000ULL) {
        error = "effect_economy_command_batch_invalid";
        return EFFECT_PREFLIGHT_REJECT;
    }
    for (size_t i = 0; i < count; ++i) {
        const EffectCommand &source = commands[i];
        if (source.idempotency_key == 0 || source.sequence < 0) {
            error = "effect_economy_command_identity_invalid";
            return EFFECT_PREFLIGHT_REJECT;
        }
        // An already accepted idempotency key is safe to replay regardless of
        // whether its generation-safe target has since retired.
        if (_effect_idempotency_requests.find(source.idempotency_key) !=
                _effect_idempotency_requests.end())
            continue;
        Command command;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = source.sequence;
        command.target_handle = source.target_handle;
        command.i32_0 = source.i32_0;
        command.i32_1 = source.i32_1;
        command.i64_0 = source.i64_0;
        command.i64_1 = source.i64_1;
        command.effect_idempotency_key = source.idempotency_key;
        if (!validate_command_pod(command, error)) {
            error = "effect_economy_preflight_" + error;
            return EFFECT_PREFLIGHT_REJECT;
        }
    }
    return EFFECT_PREFLIGHT_ACCEPT;
}

bool NativeEconomyRuntime::submit_effect_commands_pod(
        const EffectCommand *commands, size_t count,
        std::vector<int64_t> &request_ids, std::string &error) {
    request_ids.clear();
    if (!_bootstrapped || _fatal || _save.active || _restore.active) {
        error = !_bootstrapped ? "economy_not_bootstrapped" :
            (_fatal ? "economy_fatal" : "save_restore_active");
        return false;
    }
    if ((commands == nullptr && count != 0) || count > 1000000ULL) {
        error = "effect_economy_command_batch_invalid";
        return false;
    }
    std::vector<Command> staged;
    staged.reserve(count);
    request_ids.reserve(count);
    std::unordered_map<uint64_t, int64_t> staged_idempotency;
    for (size_t i = 0; i < count; ++i) {
        const EffectCommand &source = commands[i];
        if (source.idempotency_key == 0 || source.sequence < 0) {
            error = "effect_economy_command_identity_invalid";
            return false;
        }
        const auto existing = _effect_idempotency_requests.find(
            source.idempotency_key);
        if (existing != _effect_idempotency_requests.end()) {
            request_ids.push_back(existing->second);
            continue;
        }
        const auto duplicate = staged_idempotency.find(source.idempotency_key);
        if (duplicate != staged_idempotency.end()) {
            request_ids.push_back(duplicate->second);
            continue;
        }
        Command command;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = source.sequence;
        command.target_handle = source.target_handle;
        command.i32_0 = source.i32_0;
        command.i32_1 = source.i32_1;
        command.i64_0 = source.i64_0;
        command.i64_1 = source.i64_1;
        command.effect_request_id = _next_effect_request_id +
            static_cast<int64_t>(staged.size());
        command.effect_idempotency_key = source.idempotency_key;
        if (!validate_command_pod(command, error)) {
            error = "effect_economy_preflight_" + error;
            return false;
        }
        staged_idempotency.emplace(source.idempotency_key,
            command.effect_request_id);
        request_ids.push_back(command.effect_request_id);
        staged.push_back(command);
    }
    if (_pending_commands.size() + staged.size() > 1000000ULL ||
        _effect_command_results.size() + staged.size() > 1000000ULL ||
        _next_effect_request_id > std::numeric_limits<int64_t>::max() -
            static_cast<int64_t>(staged.size())) {
        error = "effect_economy_queue_capacity_exceeded";
        return false;
    }
    const bool immediate_family_settlement = !_epoch_active &&
        staged.size() == 1 &&
        staged.front().opcode == COMMAND_SETTLE_FAMILY_EXPEDITION &&
        staged.front().effective_day <= _current_day.get();
    // When no epoch is open, due effect commands must apply (or fail) now.
    // Queuing them for a future begin_epoch deadlocks WorldClock: Effect ACK
    // arms the day barrier, and the next epoch never starts.
    const int64_t due_day = std::max(_current_day.get(), _last_committed_day.get());
    for (Command &command : staged) {
        command.submit_order = _next_submit_order++;
        _effect_idempotency_requests.emplace(command.effect_idempotency_key,
            command.effect_request_id);
        EffectCommandResult &result = _effect_command_results[
            command.effect_request_id];
        if (immediate_family_settlement) {
            std::string commit_error;
            const bool applied = apply_settle_family_expedition(
                command, commit_error);
            if (!applied && runtime_country_asset_pending_reason(commit_error)) {
                // Backpressure, not failure: no store was mutated. Re-queue the
                // command intact and leave the Effect request incomplete, so the
                // transaction is not ACKed against a claim that has not landed.
                queue_family_settlement_command(command);
            } else {
                result.complete = 1;
                result.ok = applied ? 1 : 0;
                result.reason = applied ? std::string{} :
                    (commit_error.empty()
                        ? "effect_economy_commit_failed" : commit_error);
            }
        } else if (command.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION) {
            queue_family_settlement_command(command);
        } else if (command.effective_day <= due_day) {
            // Apply due Effect commands even mid-epoch. Queuing them until
            // commit finalize deadlocks play: Effect hard_ack pins the day
            // barrier while Economy stays inflight waiting for that day.
            std::string commit_error;
            const bool applied = apply_command(command, commit_error);
            result.complete = 1;
            result.ok = applied ? 1 : 0;
            result.reason = applied ? std::string{} :
                (commit_error.empty()
                    ? "effect_economy_commit_failed" : commit_error);
        } else {
            _pending_commands.push_back(command);
        }
    }
    _next_effect_request_id += static_cast<int64_t>(staged.size());
    return true;
}

void NativeEconomyRuntime::drain_due_effect_pending_commands() {
    if (_epoch_active || _fatal || !_bootstrapped || _pending_commands.empty())
        return;
    const int64_t due_day = std::max(_current_day.get(), _last_committed_day.get());
    std::vector<Command> kept;
    kept.reserve(_pending_commands.size());
    for (const Command &command : _pending_commands) {
        if (command.effect_request_id == 0 || command.effective_day > due_day) {
            kept.push_back(command);
            continue;
        }
        if (command.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION) {
            std::string commit_error;
            const bool applied = apply_settle_family_expedition(
                command, commit_error);
            if (!applied && runtime_country_asset_pending_reason(commit_error)) {
                kept.push_back(command);
            } else {
                auto &result =
                    _effect_command_results[command.effect_request_id];
                result.complete = 1;
                result.ok = applied ? 1 : 0;
                result.reason = applied ? std::string{} :
                    (commit_error.empty()
                        ? "effect_economy_commit_failed" : commit_error);
            }
            continue;
        }
        EffectCommandResult &result =
            _effect_command_results[command.effect_request_id];
        std::string commit_error;
        const bool applied = apply_command(command, commit_error);
        result.complete = 1;
        result.ok = applied ? 1 : 0;
        result.reason = applied ? std::string{} :
            (commit_error.empty() ? "effect_economy_commit_failed" : commit_error);
    }
    _pending_commands.swap(kept);
}

bool NativeEconomyRuntime::effect_command_result_pod(int64_t request_id,
        bool &complete, bool &ok, std::string &reason) const {
    complete = false;
    ok = false;
    reason.clear();
    const auto found = _effect_command_results.find(request_id);
    if (found == _effect_command_results.end()) {
        reason = "effect_economy_request_unknown";
        return false;
    }
    complete = found->second.complete != 0;
    ok = found->second.ok != 0;
    reason = found->second.reason;
    return true;
}

bool NativeEconomyRuntime::has_pending_effect_commands() const {
    for (const auto &entry : _effect_command_results)
        if (entry.second.complete == 0) return true;
    return false;
}

} // namespace pk
