#include "effect_runtime_dispatch_includes.inc"

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
        // EVENT_ONCE (lifecycle 2) delivers one payout per instance generation.
        // The ACK gate retires it, but a fire transaction that is rejected or
        // reclaimed by compaction never reaches that gate and used to leave the
        // row armed: the cadence then replayed the same command every day with a
        // new fire_sequence (and therefore a new idempotency key), so nothing
        // downstream could reject the duplicate. A row that already fired and has
        // no live transaction left is retired here instead of being re-armed.
        // See fire_family_event_once_effect: city_founder's "+220 people" paid
        // out once per day for 75 days in the reported save.
        if (definition.lifecycle == 2 && instance.fire_sequence > 0 &&
            _pending_transactions_by_instance.find(instance.id) ==
                _pending_transactions_by_instance.end()) {
            instance.active = 0;
            instance.schedule_token = 0;
            instance.dirty_epoch = 0;
            release_retired_instance_if_terminal(instance_index);
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




} // namespace pk
