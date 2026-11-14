#include "effect_runtime.h"
#include "country_api.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

Dictionary EffectRuntime::run_daily(int64_t day_index) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (day_index < _last_completed_day) return failure("effect_day_rewind");
    const int64_t previous_current_day = _current_day;
    const int64_t previous_last_completed_day = _last_completed_day;
    if (_run_day >= 0 && _run_day != day_index &&
        _candidate_cursor < static_cast<int32_t>(_run_candidates.size()) &&
        _run_day != _last_completed_day) {
        // An unfinished same-day slice must not freeze Effect across calendar
        // days. Re-queue remaining candidates for today and rebuild.
        for (int32_t cursor = _candidate_cursor;
             cursor < static_cast<int32_t>(_run_candidates.size()); ++cursor) {
            const int32_t index = _run_candidates[static_cast<size_t>(cursor)];
            if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
            Instance &instance = _instances[static_cast<size_t>(index)];
            if (!instance.active) continue;
            instance.next_due_day = std::min(instance.next_due_day, day_index);
            schedule_instance(index, day_index);
        }
        _candidate_cursor = static_cast<int32_t>(_run_candidates.size());
        _last_completed_day = _run_day;
        _run_cursor = _candidate_cursor;
    }
    const auto started = std::chrono::steady_clock::now();
    if (_run_day != day_index) {
        _run_day = day_index;
        rebuild_run_candidates(day_index);
        _candidate_cursor = 0;
        _run_cursor = 0;
    } else if (_candidate_cursor >= static_cast<int32_t>(_run_candidates.size()) &&
               (!_dirty_queue.empty() ||
                (!_due_heap.empty() && _due_heap.top().day <= day_index))) {
        // New snapshots/submissions can make a completed same-day run dirty.
        // Rebuild only when there is actual work; never scan dormant instances.
        rebuild_run_candidates(day_index);
        _run_cursor = 0;
    }
    _current_day = day_index;
    int32_t work = 0;
    const int32_t budget = std::max(1, _max_work_per_slice);
    const bool has_evaluation_work =
        _candidate_cursor < static_cast<int32_t>(_run_candidates.size());
    if (!has_evaluation_work) {
        _last_completed_day = day_index;
        if (_current_day != previous_current_day ||
            _last_completed_day != previous_last_completed_day)
            advance_committed_generation();
        _last_evaluate_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["stage"] = "effect_dispatch";
        out["path"] = "EFFECT_GRAPH";
        out["work_done"] = 0;
        out["progress_ratio"] = 1.0;
        out["transactions_planned"] = static_cast<int64_t>(_transactions.size());
        out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
        out["evaluated_count"] = 0;
        out["elapsed_ms"] = _last_evaluate_ms;
        out["last_error"] = String(_last_error.c_str());
        return out;
    }
    auto evaluation_failure = [&](const std::string &reason) {
        _last_error = reason;
        _last_evaluate_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        Dictionary out;
        out["ok"] = false;
        out["done"] = false;
        out["reason"] = String(reason.c_str());
        out["stage"] = "effect_evaluate";
        out["path"] = "EFFECT_GRAPH";
        out["work_done"] = work;
        out["run_cursor"] = _candidate_cursor;
        out["progress_ratio"] = _run_candidates.empty() ? 1.0 :
            static_cast<double>(_candidate_cursor) /
            static_cast<double>(_run_candidates.size());
        out["elapsed_ms"] = _last_evaluate_ms;
        out["last_error"] = String(_last_error.c_str());
        return out;
    };

    // Declarative IR evaluation is read-only over the frozen instance/metric
    // slabs. Plan a contiguous slice in workers, then replay it in candidate
    // order so fire sequences, transaction ids, capacity backpressure and
    // idempotency remain bit-identical to the serial path. Behavior callbacks
    // deliberately stay on the existing serial path until a callback is
    // explicitly certified thread-safe by its owner.
    int32_t batch_end = _candidate_cursor;
    int32_t batch_work = 0;
    bool batch_declarative = true;
    while (batch_end < static_cast<int32_t>(_run_candidates.size())) {
        const int32_t index = _run_candidates[static_cast<size_t>(batch_end)];
        const Definition *definition = nullptr;
        if (index >= 0 && index < static_cast<int32_t>(_instances.size())) {
            const Instance &instance = _instances[static_cast<size_t>(index)];
            if (instance.program_id >= 0 &&
                instance.program_id < static_cast<int32_t>(_definitions.size()))
                definition = &_definitions[instance.program_id];
        }
        const int32_t cost = std::max(1, definition != nullptr ? definition->max_work : 1);
        if (batch_end > _candidate_cursor && batch_work + cost > budget) break;
        if (definition != nullptr && (uses_managed_lifecycle(*definition) ||
            !definition->behavior_id.empty())) {
            batch_declarative = false;
            break;
        }
        batch_work += cost;
        ++batch_end;
        if (batch_work >= budget) break;
    }
    const int32_t batch_count = batch_end - _candidate_cursor;
    const bool has_workers = parallel_has_real_worker_threads();
    const bool use_parallel_plan = batch_declarative && batch_count >= 64;
    if (batch_count > 1 && batch_declarative && !has_workers) {
        _last_parallel_path = "serial_fallback";
        _last_parallel_fallback_reason = "no_worker_threads";
        ++_serial_fallback_dispatches;
    } else if (batch_count < 64 || !batch_declarative) {
        _last_parallel_path = "serial";
        _last_parallel_fallback_reason = !batch_declarative
            ? "behavior_callback_requires_serial" : "batch_below_parallel_threshold";
        ++_serial_fallback_dispatches;
    }
    if (use_parallel_plan) {
        const auto planning_started = std::chrono::steady_clock::now();
        _last_parallel_path = has_workers ? "parallel_plan_serial_merge"
                                          : "serial_fallback_plan_merge";
        _last_parallel_fallback_reason = has_workers ? "" : "no_worker_threads";
        _last_parallel_worker_count = has_workers ? parallel_default_n_tasks(batch_count) : 1;
        std::vector<PlannedCandidate> plans(static_cast<size_t>(batch_count));
        auto plan_range = [&](int begin, int end) {
            for (int offset = begin; offset < end; ++offset) {
                const int32_t cursor = _candidate_cursor + offset;
                const int32_t instance_index = _run_candidates[static_cast<size_t>(cursor)];
                build_planned_candidate(cursor, instance_index, day_index,
                                        plans[static_cast<size_t>(offset)]);
            }
        };
        parallel_for_range("pk_effect_plan", batch_count, 0, 64, plan_range);
        _last_parallel_planning_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - planning_started).count();
        if (has_workers) ++_parallel_dispatches;

        const auto merge_started = std::chrono::steady_clock::now();
        for (int32_t offset = 0; offset < batch_count; ++offset) {
            PlannedCandidate &plan = plans[static_cast<size_t>(offset)];
            const int32_t instance_cursor = _candidate_cursor;
            if (plan.candidate_cursor != instance_cursor) {
                _last_error = "effect_parallel_candidate_order_invalid";
                return evaluation_failure(_last_error);
            }
            if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                compact_terminal_transactions();
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    ++_overflow_count;
                    return evaluation_failure("effect_transaction_capacity_exceeded");
                }
            }
            if (plan.instance_index < 0 ||
                plan.instance_index >= static_cast<int32_t>(_instances.size())) {
                ++_candidate_cursor;
                _run_cursor = _candidate_cursor;
                continue;
            }
            Instance &instance = _instances[static_cast<size_t>(plan.instance_index)];
            if (!plan.eligible) {
                ++_candidate_cursor;
                _run_cursor = _candidate_cursor;
                continue;
            }
            ++_programs_evaluated;
            if (!plan.enabled || !plan.passes) {
                const Definition &definition = _definitions[instance.program_id];
                instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
                instance.last_evaluated_input_revision = instance.input_revision;
                schedule_instance(plan.instance_index, instance.next_due_day);
                instance.dirty_epoch = 0;
                ++_candidate_cursor;
                _run_cursor = _candidate_cursor;
                continue;
            }
            if (!plan.error.empty()) {
                if (plan.behavior_failure) ++_behavior_failures;
                if (plan.overflowed) ++_overflow_count;
                return evaluation_failure(plan.error);
            }
            if (!plan.commands.empty()) {
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    ++_overflow_count;
                    return evaluation_failure("effect_transaction_capacity_exceeded");
                }
            }
            instance.fire_sequence = plan.planned_fire_sequence;
            Transaction transaction;
            transaction.source_instance_id = instance.id;
            transaction.source_generation = instance.generation;
            transaction.program_id = instance.program_id;
            transaction.effective_day = day_index;
            for (const Command &command : plan.commands)
                append_command(transaction, command);
            if (transaction.command_count != 0) {
                transaction.plan_hash = 1469598103934665603ULL;
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.source_instance_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.source_generation);
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.program_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash,
                    transaction.effective_day);
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    const Command *command = command_at(transaction, ordinal);
                    if (command == nullptr) continue;
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->action);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->domain);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->opcode);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_handle);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_generation);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->value_q16);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->duration_days);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->stacks);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->command_key_id);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        command->command_definition_id);
                    for (int64_t payload_value : command->payload)
                        transaction.plan_hash = fnv_value(transaction.plan_hash, payload_value);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->idempotency_key);
                }
                transaction.id = _next_transaction_id++;
                if (transaction.required_ack_mask == 0) transaction.status = COMMITTED;
                _transactions.push_back(std::move(transaction));
                _transaction_ids[_transactions.back().id] =
                    static_cast<int32_t>(_transactions.size() - 1);
                track_pending_transaction(_transactions.back());
                index_transaction_commands(_transactions.back());
            }
            const Definition &definition = _definitions[instance.program_id];
            instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
            instance.last_evaluated_input_revision = instance.input_revision;
            schedule_instance(plan.instance_index, instance.next_due_day);
            instance.dirty_epoch = 0;
            ++_candidate_cursor;
            _run_cursor = _candidate_cursor;
        }
        _last_parallel_merge_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - merge_started).count();
        work = batch_work;
    }
    while (_candidate_cursor < static_cast<int32_t>(_run_candidates.size()) && work < budget) {
        // Terminal transactions no longer participate in replay. Reclaim them
        // before evaluating a new instance so a bounded queue applies
        // backpressure instead of dropping the current effect.
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            compact_terminal_transactions();
            if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                ++_overflow_count;
                return evaluation_failure("effect_transaction_capacity_exceeded");
            }
        }
        const int32_t instance_cursor = _candidate_cursor;
        const int32_t instance_index = _run_candidates[static_cast<size_t>(_candidate_cursor)];
        if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size())) {
            ++_candidate_cursor;
            _run_cursor = _candidate_cursor;
            continue;
        }
        Instance &instance = _instances[static_cast<size_t>(instance_index)];
        const uint64_t prior_fire_sequence = instance.fire_sequence;
        const int64_t prior_next_due_day = instance.next_due_day;
        const uint64_t prior_commands_emitted = _commands_emitted;
        const Definition *work_definition =
            (instance.program_id >= 0 &&
             instance.program_id < static_cast<int32_t>(_definitions.size()))
            ? &_definitions[instance.program_id] : nullptr;
        // max_work is the scheduler charge for one definition evaluation. A
        // single definition is always allowed to run once even when its
        // charge exceeds the slice budget; otherwise it could starve forever.
        const int32_t definition_work = std::max(1,
            work_definition != nullptr ? work_definition->max_work : 1);
        if (work > 0 && work + definition_work > budget) break;
        ++_candidate_cursor;
        _run_cursor = _candidate_cursor;
        work += definition_work;
        if (!instance.active || instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
            (instance.next_due_day > day_index &&
             instance.input_revision <= instance.last_evaluated_input_revision))
            continue;
        const Definition &definition = _definitions[instance.program_id];
        ++_programs_evaluated;
        const bool managed_lifecycle = uses_managed_lifecycle(definition);
        if (managed_lifecycle) {
            const auto pending = _pending_transactions_by_instance.find(instance.id);
            if (pending != _pending_transactions_by_instance.end() &&
                pending->second > 0) {
                instance.next_due_day = day_index + 1;
                schedule_instance(instance_index, instance.next_due_day);
                continue;
            }
        }
        if (instance.retire_requested != 0) {
            std::string retirement_error;
            if (!create_retirement_transaction(instance_index, day_index,
                                                retirement_error, true))
                return evaluation_failure(retirement_error);
            instance.dirty_epoch = 0;
            continue;
        }
        if (definition.lifecycle == 1 && instance.expires_day >= 0 &&
            day_index >= instance.expires_day) {
            std::string expiry_error;
            if (!create_retirement_transaction(instance_index, day_index,
                                               expiry_error))
                return evaluation_failure(expiry_error);
            instance.dirty_epoch = 0;
            continue;
        }
        if (!definition.enabled) {
            instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
            instance.last_evaluated_input_revision = instance.input_revision;
            schedule_instance(instance_index, instance.next_due_day);
            instance.dirty_epoch = 0;
            continue;
        }
        bool passes = evaluate_condition(definition, instance);
        // Latch the RAW condition result, before group arbitration. A hysteresis
        // band is a statement about the metric, not about whether the effect won
        // a stack fight this tick -- folding the arbitration in would make the
        // band release and re-enter every time another source took the slot.
        instance.latched = passes ? 1 : 0;
        if (passes && is_family_effect_instance(instance)) {
            std::string arbitration_error;
            if (!resolve_family_effect_group(instance_index, day_index,
                                             arbitration_error))
                return evaluation_failure(arbitration_error);
            passes = instance.desired_stack_count > 0;
        }
        if (managed_lifecycle && !passes && instance.effect_applied) {
            std::string deactivate_error;
            if (!create_retirement_transaction(instance_index, day_index,
                                                deactivate_error, false))
                return evaluation_failure(deactivate_error);
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.dirty_epoch = 0;
            continue;
        }
        const bool managed_update_due = managed_lifecycle && passes &&
            (!instance.effect_applied ||
             instance.input_revision > instance.applied_input_revision ||
             instance.applied_stack_count != (is_family_effect_instance(instance)
                 ? instance.desired_stack_count
                 : std::max(1, instance.stack_count)));
        if (passes) {
            if (definition.lifecycle == 1 && definition.stack_policy == 1 &&
                !instance.effect_applied) {
                instance.expires_day = day_index +
                    static_cast<int64_t>(definition.duration_days);
            }
            if (managed_lifecycle && !managed_update_due) {
                instance.next_due_day = day_index + std::max<int32_t>(
                    1, definition.cadence_days);
                instance.last_evaluated_input_revision = instance.input_revision;
                schedule_instance(instance_index, instance.next_due_day);
                instance.dirty_epoch = 0;
                continue;
            }
            ++instance.fire_sequence;
            Transaction transaction;
            transaction.source_instance_id = instance.id;
            transaction.source_generation = instance.generation;
            transaction.program_id = instance.program_id;
            transaction.effective_day = day_index;
            std::string error;
            if (!definition.behavior_id.empty()) {
                BehaviorFn behavior = nullptr;
                {
                    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
                    auto it = behavior_registry().find(definition.behavior_id);
                    if (it != behavior_registry().end()) behavior = it->second;
                }
                if (behavior == nullptr) {
                    ++_behavior_failures;
                    error = "effect_behavior_not_registered:" + definition.behavior_id;
                    _last_error = error;
                } else {
                    BehaviorInput input;
                    input.instance_id = instance.id;
                    input.instance_generation = instance.generation;
                    input.program_id = instance.program_id;
                    input.level = instance.level;
                    input.day = day_index;
                    input.target_handle = instance.target_handle;
                    input.source_handle = instance.source_handle;
                    input.metrics = metric_ptr(instance, 0);
                    input.metric_count = _metric_count;
                    BehaviorOutput output;
                    output.commands = _behavior_command_buffer.data();
                    output.capacity = std::min<int32_t>(definition.max_work,
                        static_cast<int32_t>(_behavior_command_buffer.size()));
                    if (!behavior(input, output, error)) {
                        ++_behavior_failures;
                        _last_error = error.empty() ? "effect_behavior_failed" : error;
                    } else {
                        if (output.overflowed || output.count < 0 || output.count > output.capacity) {
                            ++_behavior_failures;
                            ++_overflow_count;
                            _last_error = "effect_behavior_output_capacity_exceeded";
                            error = _last_error;
                        }
                        for (int32_t command_index = 0;
                             error.empty() && command_index < output.count; ++command_index) {
                            const BehaviorCommand &source = output.commands[command_index];
                            Command command;
                            command.action = source.action;
                            command.domain = source.domain;
                            command.opcode = source.opcode;
                            command.target_handle = source.target_handle;
                            command.target_generation = source.target_generation;
                            command.value_q16 = source.value_q16;
                            command.duration_days = source.duration_days;
                            command.stacks = source.stacks;
                            if (source.command_key_id < -1 ||
                                source.command_key_id >= static_cast<int32_t>(
                                    _behavior_command_keys.size())) {
                                error = "effect_behavior_command_key_invalid";
                                break;
                            }
                            command.command_key_id = source.command_key_id;
                            command.command_definition_id = -1;
                            command.payload = source.payload;
                            command.idempotency_key = command_idempotency_key(instance,
                                static_cast<uint32_t>(command_index));
                            append_command(transaction, command);
                        }
                    }
                }
            }
            if (error.empty() && definition.instruction_count > 0 &&
                !execute_program(definition, instance, day_index, transaction, error)) {
                _last_error = error;
            }
            if (!error.empty()) {
                // Do not advance a failing effect. The same frozen input can
                // be retried after the missing behavior/adapter/configuration
                // is repaired, without producing a duplicate fire sequence.
                _commands_emitted = prior_commands_emitted;
                instance.fire_sequence = prior_fire_sequence;
                instance.next_due_day = prior_next_due_day;
                    _candidate_cursor = instance_cursor;
                    _run_cursor = _candidate_cursor;
                    return evaluation_failure(error);
            }
            if (transaction.command_count != 0) {
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    // Completed transactions are no longer needed for replay:
                    // `_acked_transaction_id` and command idempotency keys
                    // already make retries safe. Reclaim them before treating
                    // the bounded pending queue as overflowed.
                    compact_terminal_transactions();
                }
                if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
                    ++_overflow_count;
                    _last_error = "effect_transaction_capacity_exceeded";
                    _commands_emitted = prior_commands_emitted;
                    instance.fire_sequence = prior_fire_sequence;
                    instance.next_due_day = prior_next_due_day;
                    _candidate_cursor = instance_cursor;
                    _run_cursor = _candidate_cursor;
                    return evaluation_failure(_last_error);
                }
                if (managed_lifecycle) {
                    transaction.instance_transition = definition.lifecycle == 2
                        ? TRANSITION_RETIRE
                        : (instance.effect_applied ? TRANSITION_UPDATE
                                                   : TRANSITION_APPLY);
                    transaction.transition_input_revision = instance.input_revision;
                    transaction.transition_fire_sequence = instance.fire_sequence;
                    transaction.transition_stack_count = definition.lifecycle == 2
                        ? 0 : (is_family_effect_instance(instance)
                            ? instance.desired_stack_count
                            : std::max(1, instance.stack_count));
                }
                transaction.plan_hash = 1469598103934665603ULL;
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.source_instance_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.source_generation);
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.program_id);
                transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
                if (transaction.instance_transition != TRANSITION_NONE) {
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        transaction.instance_transition);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        transaction.transition_input_revision);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        transaction.transition_fire_sequence);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        transaction.transition_stack_count);
                }
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    const Command *command = command_at(transaction, ordinal);
                    if (command == nullptr) continue;
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->action);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->domain);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->opcode);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_handle);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_generation);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->value_q16);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->duration_days);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->stacks);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        command->command_key_id);
                    transaction.plan_hash = fnv_value(transaction.plan_hash,
                        command->command_definition_id);
                    for (int64_t payload_value : command->payload)
                        transaction.plan_hash = fnv_value(transaction.plan_hash, payload_value);
                    transaction.plan_hash = fnv_value(transaction.plan_hash, command->idempotency_key);
                }
                transaction.id = _next_transaction_id++;
                if (transaction.required_ack_mask == 0) {
                    transaction.status = COMMITTED;
                    transaction.status = ACKED;
                    apply_acked_instance_transition(transaction);
                    _acked_transaction_id = std::max(
                        _acked_transaction_id, transaction.id);
                    ++_transactions_acked;
                }
                _transactions.push_back(std::move(transaction));
                _transaction_ids[_transactions.back().id] =
                    static_cast<int32_t>(_transactions.size() - 1);
                if (_transactions.back().status != ACKED) {
                    track_pending_transaction(_transactions.back());
                    index_transaction_commands(_transactions.back());
                }
            }
            // Keep EVENT_ONCE active while its transaction is pending. The
            // ACK gate above retires it; rejection leaves it retryable.
        }
        instance.next_due_day = day_index + std::max<int32_t>(1, definition.cadence_days);
        instance.last_evaluated_input_revision = instance.input_revision;
        schedule_instance(instance_index, instance.next_due_day);
        // The candidate has consumed its current frozen snapshot. A later
        // same-day publish must be able to enqueue one new dirty candidate.
        instance.dirty_epoch = 0;
    }
    const bool done = _candidate_cursor >= static_cast<int32_t>(_run_candidates.size());
    if (done) _last_completed_day = day_index;
    if (work > 0 || _current_day != previous_current_day ||
        _last_completed_day != previous_last_completed_day)
        advance_committed_generation();
    _last_evaluate_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    Dictionary out;
    out["ok"] = true;
    out["done"] = done;
    out["stage"] = "effect_evaluate";
    out["path"] = "EFFECT_GRAPH";
    out["work_done"] = work;
    out["progress_ratio"] = _run_candidates.empty() ? 1.0 :
        static_cast<double>(_candidate_cursor) /
        static_cast<double>(_run_candidates.size());
    out["transactions_planned"] = static_cast<int64_t>(_transactions.size());
    out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
    out["evaluated_count"] = work;
    out["elapsed_ms"] = _last_evaluate_ms;
    out["last_error"] = String(_last_error.c_str());
    return out;
}

Dictionary EffectRuntime::dispatch_native_modifier(ModifierRuntime *modifier_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (modifier_runtime == nullptr || !modifier_api::configured(*modifier_runtime))
        return failure("modifier_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();

    auto binding_exists = [&](int64_t transaction_id) {
        return _native_bound_transaction_ids.find(transaction_id) !=
            _native_bound_transaction_ids.end();
    };
    auto definition_key_ptr = [&](const Command &command) -> const std::string * {
        if (command.command_definition_id >= 0 &&
            command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
            return &_command_definitions[command.command_definition_id].definition_key;
        return nullptr;
    };

    struct PendingTransaction {
        int32_t transaction_index = -1;
        uint32_t request_offset = 0;
        uint32_t request_count = 0;
        uint32_t domain_mask = 0;
    };
    std::vector<ModifierApi::NativeCommand> native_commands;
    std::vector<PendingTransaction> pending_transactions;
    native_commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    pending_transactions.reserve(std::min<int32_t>(_max_transactions, 4096));

    // A transaction may contain commands for several native domains. Each
    // adapter claims only its own command subset; the shared ACK mask keeps the
    // transaction hidden from fallback polling until every domain is done.
    for (int32_t tx_index = 0;
         tx_index < static_cast<int32_t>(_transactions.size());
         ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (binding_exists(transaction.id) || transaction.command_count == 0 ||
            transaction.required_ack_mask == 0)
            continue;

        const int32_t instance_index = instance_index_for_id(transaction.source_instance_id);
        const Instance *source_instance = instance_index >= 0 &&
            instance_index < static_cast<int32_t>(_instances.size())
            ? &_instances[static_cast<size_t>(instance_index)] : nullptr;
        if (source_instance == nullptr ||
            source_instance->generation != transaction.source_generation)
            continue;

        const uint32_t request_offset = static_cast<uint32_t>(native_commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) { supported = false; break; }
            if (command->action != MODIFIER_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            // THE mapping (magnitude, source identity, scope, handles) lives in
            // map_modifier_row; the translation below is storage only.
            ModifierRow row;
            if (!map_modifier_row(transaction, *source_instance, *command, row)) {
                supported = false;
                break;
            }
            ModifierApi::NativeCommand native;
            native.opcode = row.opcode;
            native.producer = row.producer;
            native.sequence = row.sequence;
            native.effective_day = row.effective_day;
            // `map_modifier_row` already rejected a missing key; keep the
            // catalog-owned pointer instead of the loop copy so the `const char*`
            // stays valid after `row` goes out of scope.
            const std::string *definition_key = definition_key_ptr(*command);
            native.definition_key = definition_key != nullptr
                ? definition_key->c_str() : "";
            native.domain = row.domain;
            native.scope = row.scope;
            native.entity_handle = row.entity_handle;
            native.group_handle = row.group_handle;
            native.source_type = row.source_type;
            native.source_id = row.source_id;
            native.duration_days = row.duration_days;
            native.stacks = row.stacks;
            native.magnitude_q16 = row.magnitude_q16;
            native.modifier_handle = 0;
            if (command->domain >= 0 && command->domain < 32)
                domain_mask |= row.domain_bit;
            native_commands.push_back(native);
        }
        if (!supported) {
            native_commands.resize(request_offset);
            break;
        }
        const uint32_t request_count = static_cast<uint32_t>(native_commands.size()) -
            request_offset;
        if (request_count == 0 || domain_mask == 0) continue;
        if (native_commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            native_commands.resize(request_offset);
            continue;
        }
        pending_transactions.push_back({tx_index, request_offset, request_count, domain_mask});
    }

    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (native_commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }

    std::vector<int64_t> request_ids;
    std::string error;
    if (!modifier_api::submit_commands_pod(*modifier_runtime, native_commands.data(), native_commands.size(),
                                               request_ids, error) ||
        request_ids.size() != native_commands.size()) {
        _last_error = error.empty() ? "effect_native_modifier_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    for (const PendingTransaction &pending : pending_transactions) {
        Transaction &transaction = _transactions[static_cast<size_t>(pending.transaction_index)];
        const uint32_t request_begin = static_cast<uint32_t>(_native_request_ids.size());
        _native_request_ids.insert(_native_request_ids.end(),
            request_ids.begin() + pending.request_offset,
            request_ids.begin() + pending.request_offset + pending.request_count);
        _native_ack_bindings.push_back({transaction.id, request_begin,
            pending.request_count, pending.domain_mask});
        _native_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending_transactions.size());
    out["submitted_commands"] = static_cast<int32_t>(native_commands.size());
    _native_modifier_transactions += pending_transactions.size();
    _native_modifier_commands += native_commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_modifier(ModifierRuntime *modifier_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (modifier_runtime == nullptr || !modifier_api::configured(*modifier_runtime))
        return failure("modifier_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();

    int32_t acknowledged = 0;
    int32_t rejected = 0;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_request_ids;
    retained.reserve(_native_ack_bindings.size());
    retained_request_ids.reserve(_native_request_ids.size());
    for (const NativeAckBinding &binding : _native_ack_bindings) {
        const int32_t tx_index = transaction_index_for_id(binding.transaction_id);
        Transaction *transaction = tx_index >= 0 &&
            tx_index < static_cast<int32_t>(_transactions.size())
            ? &_transactions[static_cast<size_t>(tx_index)] : nullptr;
        if (transaction == nullptr || transaction->status == ACKED ||
            transaction->status == REJECTED || transaction->status == RESYNC_REQUIRED)
            continue;
        bool pending = false;
        bool failed = false;
        std::string failure_reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_request_ids.size()) {
                failed = true;
                failure_reason = "effect_native_modifier_binding_invalid";
                break;
            }
            bool complete = false, ok = false;
            std::string reason;
            modifier_api::command_result_pod(*modifier_runtime, _native_request_ids[request_index],
                                                 complete, ok, reason);
            if (!complete) {
                pending = true;
                break;
            }
            if (!ok) {
                failed = true;
                failure_reason = reason.empty() ? "effect_native_modifier_rejected" : reason;
                // Roll back the rows THIS batch already committed.
                //
                // `run_modifier_daily` applies each row in submission order and only then
                // does the ACK reach the failing row, so rows that committed before it are
                // otherwise orphaned: `apply_rejected_instance_transition` only reschedules
                // and never touches the Modifier store (it has no pointer to it). Measured
                // before this fix: a rejected equip left the card's own cost row live while
                // the card was INACTIVE with zero cell contributions.
                //
                // The row identity depends on which adapter branch produced it -- the
                // ideology branch keys on the instance id, the generic MODIFIER_COMMAND
                // branch on the batch's source id -- so BOTH are swept. A row matching
                // neither is not from this batch.
                const int32_t source_index = instance_index_for_id(
                    transaction->source_instance_id);
                if (source_index >= 0 &&
                    source_index < static_cast<int32_t>(_instances.size())) {
                    const Instance &source =
                        _instances[static_cast<size_t>(source_index)];
                    modifier_api::remove_rows_for_source(*modifier_runtime,
                        static_cast<uint64_t>(source.source_type),
                        static_cast<uint64_t>(source.id), _current_day);
                    modifier_api::remove_rows_for_source(*modifier_runtime,
                        static_cast<uint64_t>(source.source_type),
                        static_cast<uint64_t>(source.source_id), _current_day);
                }
                break;
            }
        }
        if (pending) {
            NativeAckBinding kept = binding;
            kept.request_begin = static_cast<uint32_t>(retained_request_ids.size());
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_request_ids.push_back(_native_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(*transaction);
            unindex_transaction_commands(*transaction);
            transaction->status = REJECTED;
            apply_rejected_instance_transition(*transaction);
            ++_preflight_rejects;
            ++rejected;
            _last_error = failure_reason;
            continue;
        }
        acknowledge_native_domain(*transaction, binding.domain_bit);
        ++acknowledged;
    }
    for (const NativeAckBinding &binding : _native_ack_bindings) {
        if (std::find_if(retained.begin(), retained.end(),
                [&](const NativeAckBinding &candidate) {
                    return candidate.transaction_id == binding.transaction_id;
                }) == retained.end())
            _native_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_ack_bindings.swap(retained);
    _native_request_ids.swap(retained_request_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_modifier_acks += static_cast<uint64_t>(acknowledged);
    _last_native_ack_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::dispatch_native_country(NativeCountryRuntime *country_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (country_runtime == nullptr) return failure("country_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<CountryEffectCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (_native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end())
            continue;
        if (transaction.command_count == 0) continue;
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            if (command->action != COUNTRY_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            if (command->domain < 0 || command->domain >= 32 ||
                command->opcode < CountryApi::COMMAND_CREATE_COUNTRY ||
                command->opcode > CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY ||
                (command->command_definition_id < 0 &&
                 command->opcode != CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY) ||
                command->command_definition_id >= static_cast<int32_t>(_command_definitions.size())) {
                supported = false;
                break;
            }
            CountryEffectCommand native;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            native.value = command->value_q16;
            native.payload = command->payload;
            native.idempotency_key = command->idempotency_key;
            // For structural country commands the catalog carries immutable
            // names in the existing cold string columns.  No Godot Variant is
            // built in this bridge.
            if (command->command_definition_id >= 0) {
                const CommandDefinition &definition = _command_definitions[
                    static_cast<size_t>(command->command_definition_id)];
                native.stable_id = definition.definition_key.c_str();
                native.display_name = definition.command_key.c_str();
            }
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) { commands.resize(begin); continue; }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true; out["submitted_transactions"] = 0; out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!country_api::submit_effect_commands_pod(*country_runtime, commands.data(), commands.size(), request_ids, error) ||
        request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_country_enqueue_failed" : error;
        out["ok"] = false; out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(_native_country_request_ids.size());
        _native_country_request_ids.insert(_native_country_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_country_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_country_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_country_transactions += pending.size();
    _native_country_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_country(NativeCountryRuntime *country_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (country_runtime == nullptr) return failure("country_runtime_unavailable");
    country_api::drain_effect_host_command_receipts(*country_runtime);
    int32_t acknowledged = 0, rejected = 0;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_country_ack_bindings.size());
    retained_ids.reserve(_native_country_request_ids.size());
    for (const NativeAckBinding &binding : _native_country_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false, failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_country_request_ids.size()) { failed = true; reason = "effect_native_country_binding_invalid"; break; }
            bool complete = false, ok = false;
            if (!country_api::effect_command_result_pod(*country_runtime, _native_country_request_ids[request_index],
                    complete, ok, reason)) { failed = true; break; }
            if (!complete) { pending = true; break; }
            if (!ok) { failed = true; break; }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count,
                binding.domain_bit};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_country_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects; ++rejected; _last_error = reason.empty() ? "effect_native_country_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_country_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_country_ack_bindings.swap(retained);
    _native_country_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0; out["acknowledged"] = acknowledged;
    out["rejected"] = rejected; out["pending"] = static_cast<int32_t>(_native_country_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_country_acks += static_cast<uint64_t>(acknowledged);
    return out;
}

Dictionary EffectRuntime::settle_orphaned_native_country_acks() {
    if (!_configured) return failure("effect_runtime_unconfigured");
    int32_t settled = 0;
    std::vector<NativeAckBinding> bindings = _native_country_ack_bindings;
    std::vector<int64_t> request_ids = _native_country_request_ids;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(bindings.size());
    retained_ids.reserve(request_ids.size());
    _native_country_ack_bindings.clear();
    _native_country_request_ids.clear();
    auto keep = [&](const NativeAckBinding &binding) {
        NativeAckBinding kept{binding.transaction_id,
            static_cast<uint32_t>(retained_ids.size()), binding.request_count,
            binding.domain_bit};
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t index =
                static_cast<size_t>(binding.request_begin) + i;
            if (index < request_ids.size())
                retained_ids.push_back(request_ids[index]);
        }
        retained.push_back(kept);
    };
    for (const NativeAckBinding &binding : bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) {
            _native_country_bound_transaction_ids.erase(binding.transaction_id);
            continue;
        }
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        if (transaction.status != PREFLIGHTED && transaction.status != COMMITTED &&
            transaction.status != PLANNED) {
            _native_country_bound_transaction_ids.erase(binding.transaction_id);
            continue;
        }
        // Soft-settling exists to stop a stalled Country domain from pinning the
        // clock, but it must not forge an ACK that another domain is ordered
        // behind. dispatch_native_economy holds an Economy command until the
        // Country commands in the same transaction are ACKed, so releasing this
        // binding early let colonization SETTLE run against a claim that had not
        // committed: Economy read the target as unowned and sent the settlers
        // home while the claim still landed. Only transactions that actually
        // pair Country and Economy work are held back; everything else still
        // soft-settles, which is what keeps a stalled Country off the clock.
        bool has_country_command = false;
        bool has_economy_command = false;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count;
                ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            if (command->action == COUNTRY_COMMAND) has_country_command = true;
            else if (command->action == ECONOMY_COMMAND) has_economy_command = true;
        }
        if (has_country_command && has_economy_command) {
            keep(binding);
            continue;
        }
        acknowledge_native_domain(transaction, binding.domain_bit);
        _native_country_bound_transaction_ids.erase(binding.transaction_id);
        ++settled;
    }
    _native_country_ack_bindings.swap(retained);
    _native_country_request_ids.swap(retained_ids);
    if (settled != 0) compact_terminal_transactions();
    _native_country_acks += static_cast<uint64_t>(settled);
    Dictionary out;
    out["ok"] = true;
    out["acknowledged"] = settled;
    out["pending"] = static_cast<int32_t>(_native_country_ack_bindings.size());
    return out;
}

Dictionary EffectRuntime::dispatch_native_economy(NativeEconomyRuntime *economy_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (economy_runtime == nullptr) return failure("economy_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<EconomyApi::EffectCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    int32_t rejected_transactions = 0;
    int32_t retryable_transactions = 0;
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED ||
            _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
            transaction.command_count == 0)
            continue;
        if (transaction.program_id == -1) {
            // Colonization is intentionally ordered: Economy may consume the
            // transit payload only after the Country claim has committed and
            // ACKed. A rejected claim therefore never reaches Economy.
            uint32_t prerequisite_mask = 0;
            for (uint32_t ordinal = 0; ordinal < transaction.command_count;
                    ++ordinal) {
                const Command *command = command_at(transaction, ordinal);
                if (command != nullptr && command->action == COUNTRY_COMMAND)
                    prerequisite_mask |= adapter_ack_bit_for(*command);
            }
            if (prerequisite_mask != 0 &&
                (transaction.received_ack_mask & prerequisite_mask) !=
                    prerequisite_mask) continue;
        }
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            if (command->action != ECONOMY_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            if (command->domain < 0 || command->domain >= 32 ||
                command->opcode < EconomyApi::COMMAND_TRANSFER_TO_COHORT ||
                (command->opcode > EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION &&
                 command->opcode != EconomyApi::COMMAND_FAMILY_ABSORB_ANONYMOUS &&
                 command->opcode != EconomyApi::COMMAND_FAMILY_PURCHASE_DISCOUNT &&
                 command->opcode != EconomyApi::COMMAND_FAMILY_SET_SPLIT_POLICY)) {
                supported = false;
                break;
            }
            EconomyApi::EffectCommand native;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            const uint64_t packed_i32 = static_cast<uint64_t>(command->payload[0]);
            native.i32_0 = static_cast<int32_t>(packed_i32 & 0xffffffffULL);
            native.i32_1 = command->opcode ==
                EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION
                ? static_cast<int32_t>(command->payload[3])
                : static_cast<int32_t>((packed_i32 >> 32U) & 0xffffffffULL);
            native.i64_0 = command->opcode ==
                EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION
                ? command->payload[2] : command->value_q16;
            native.i64_1 = command->payload[1];
            native.idempotency_key = command->idempotency_key;
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) {
            commands.resize(begin);
            continue;
        }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        std::string preflight_error;
        const int32_t preflight = economy_api::preflight_effect_commands_pod(
            *economy_runtime, commands.data() + begin, count, preflight_error);
        if (preflight == EconomyApi::EFFECT_PREFLIGHT_RETRY) {
            commands.resize(begin);
            ++retryable_transactions;
            if (!preflight_error.empty()) _last_error = preflight_error;
            continue;
        }
        if (preflight != EconomyApi::EFFECT_PREFLIGHT_ACCEPT) {
            commands.resize(begin);
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects;
            ++rejected_transactions;
            _last_error = preflight_error.empty()
                ? "effect_native_economy_preflight_rejected"
                : preflight_error;
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    out["rejected_transactions"] = rejected_transactions;
    out["retryable_transactions"] = retryable_transactions;
    if (rejected_transactions != 0 || retryable_transactions != 0)
        out["reason"] = String(_last_error.c_str());
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!economy_api::submit_effect_commands_pod(*economy_runtime, commands.data(),
            commands.size(), request_ids, error) || request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_economy_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(
            _native_economy_request_ids.size());
        _native_economy_request_ids.insert(_native_economy_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_economy_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_economy_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_economy_transactions += pending.size();
    _native_economy_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_economy(NativeEconomyRuntime *economy_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (economy_runtime == nullptr) return failure("economy_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_economy_ack_bindings.size());
    retained_ids.reserve(_native_economy_request_ids.size());
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (const NativeAckBinding &binding : _native_economy_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false;
        bool failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_economy_request_ids.size()) {
                failed = true;
                reason = "effect_native_economy_binding_invalid";
                break;
            }
            bool complete = false;
            bool ok = false;
            if (!economy_api::effect_command_result_pod(*economy_runtime,
                    _native_economy_request_ids[request_index], complete, ok, reason)) {
                failed = true;
                break;
            }
            if (!complete) {
                pending = true;
                break;
            }
            if (!ok) {
                failed = true;
                break;
            }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count,
                binding.domain_bit};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_economy_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects;
            ++rejected;
            _last_error = reason.empty() ? "effect_native_economy_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_economy_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_economy_ack_bindings.swap(retained);
    _native_economy_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_economy_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_economy_acks += static_cast<uint64_t>(acknowledged);
    _last_native_ack_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::dispatch_native_gameplay(DCWorldExt *world_ext) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (world_ext == nullptr) return failure("gameplay_effect_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<DCWorldExt::EffectGameplayCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if ((transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
             transaction.status != COMMITTED) || transaction.command_count == 0 ||
            _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end())
            continue;
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            const bool native_gameplay = command != nullptr &&
                command->action == GAMEPLAY_COMMAND && command->domain == 3 &&
                command->opcode > 0;
            const bool native_publish = command != nullptr &&
                command->action == PUBLISH_EVENT && command->domain == 4 &&
                command->opcode > 0;
            const bool native_custom = command != nullptr &&
                command->action == CUSTOM_DOMAIN_COMMAND && command->domain == 6 &&
                (command->opcode == CUSTOM_AUDIT_OPCODE ||
                 command->opcode == CUSTOM_CANAL_COMMIT_OPCODE ||
                 command->opcode == CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE);
            if (!native_gameplay && !native_publish && !native_custom) {
                continue;
            }
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            DCWorldExt::EffectGameplayCommand native;
            native.action = command->action;
            native.domain = command->domain;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            native.value_i64 = command->value_q16;
            native.payload = command->payload;
            native.idempotency_key = command->idempotency_key;
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) {
            commands.resize(begin);
            continue;
        }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!world_ext->submit_effect_gameplay_commands_pod(commands.data(),
            commands.size(), request_ids, error) || request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_gameplay_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(
            _native_gameplay_request_ids.size());
        _native_gameplay_request_ids.insert(_native_gameplay_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_gameplay_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_gameplay_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_gameplay_transactions += pending.size();
    _native_gameplay_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_gameplay(DCWorldExt *world_ext) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (world_ext == nullptr) return failure("gameplay_effect_runtime_unavailable");
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_gameplay_ack_bindings.size());
    retained_ids.reserve(_native_gameplay_request_ids.size());
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (const NativeAckBinding &binding : _native_gameplay_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false;
        bool failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            bool complete = false;
            bool ok = false;
            if (request_index >= _native_gameplay_request_ids.size() ||
                !world_ext->effect_gameplay_command_result_pod(
                    _native_gameplay_request_ids[request_index], complete, ok, reason)) {
                failed = true;
                if (reason.empty()) reason = "effect_native_gameplay_binding_invalid";
                break;
            }
            if (!complete) { pending = true; failed = false; break; }
            if (!ok) { failed = true; break; }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_gameplay_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects;
            ++rejected;
            _last_error = reason.empty() ? "effect_native_gameplay_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_gameplay_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_gameplay_ack_bindings.swap(retained);
    _native_gameplay_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_gameplay_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_gameplay_acks += static_cast<uint64_t>(acknowledged);
    return out;
}

} // namespace pk
