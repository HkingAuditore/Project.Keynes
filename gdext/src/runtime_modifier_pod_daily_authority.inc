bool RuntimeModifierPodAuthority::plan_day(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeModifierPodCommand> &commands,
        const std::vector<RuntimeModifierPodCommand> &intents,
        RuntimeModifierPodSnapshot &planned_snapshot,
        std::vector<RuntimeDomainAck> &acks,
        RuntimeModifierPodReport &report,
        std::string &error,
        const std::vector<std::vector<RuntimeModifierPodCommand>> *atomic_batches,
        std::vector<uint8_t> *atomic_batch_ok) {
    clear_error(error);
    report = RuntimeModifierPodReport{};
    report.generation = _current.generation;
    if (!_configured) { error = "modifier_pod_not_configured"; set_error(report, error.c_str()); return false; }
    if (day < _current.committed_day) { error = "modifier_pod_day_regression"; set_error(report, error.c_str()); return false; }
    _next = _current;
    acks.clear();
    // Expiry is part of the plan lane. It is intentionally applied before
    // commands, matching the legacy daily boundary semantics.
    for (DomainState &domain : _next.domains) {
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            auto &entry = domain.entries[i];
            if (entry.modifier_handle != 0 && entry.expires_day >= 0 &&
                entry.expires_day <= day) {
                entry.modifier_handle = 0;
                domain.free_indices.push_back(static_cast<uint32_t>(i));
                ++domain.version;
                ++report.expired_entries;
            }
        }
        rebuild_expiry_queue(domain);
    }
    struct OrderedCommand {
        RuntimeModifierPodCommand command;
        bool is_intent = false;
    };
    std::vector<OrderedCommand> ordered;
    ordered.reserve(commands.size() + intents.size());
    for (const auto &command : commands)
        if (command.effective_day <= day) ordered.push_back({command, false});
    for (const auto &intent : intents) {
        RuntimeModifierPodCommand command = intent;
        command.request_id = intent.request_id != 0 ? intent.request_id : intent.source_id;
        command.producer_id = intent.producer_id;
        command.sequence = intent.sequence;
        command.input_generation = input_generation;
        ordered.push_back({command, true});
    }
    if (intents.size() > RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "modifier_pod_ack_capacity_exceeded";
        set_error(report, error.c_str());
        _plan_ready = false;
        return false;
    }
    std::stable_sort(ordered.begin(), ordered.end(),
        [](const OrderedCommand &a, const OrderedCommand &b) {
            return RuntimeModifierPodAuthority::command_less(a.command, b.command);
        });
    for (size_t ordered_index = 0; ordered_index < ordered.size(); ++ordered_index) {
        const auto &command = ordered[ordered_index].command;
        std::string command_error;
        bool valid = validate_command(command, command_error);
        if (valid && command.input_generation != 0 &&
            command.input_generation != input_generation) {
            valid = false;
            command_error = "modifier_pod_input_generation_stale";
        }
        RuntimeDomainAck ack;
        ack.request_id = command.request_id;
        ack.transaction_id = command.request_id;
        ack.target_handle = command.entity_handle;
        ack.target_generation = command.target_generation;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        ack.effective_day = command.effective_day;
        ack.producer_id = command.producer_id;
        ack.sequence = command.sequence;
        bool changed = false;
        bool ok = false;
        if (valid) {
            if (command.opcode == COMMAND_APPLY) {
                ok = apply_command(_next, command, day, ack, changed, command_error);
            } else if (command.opcode == COMMAND_REMOVE) {
                ok = remove_entry(_next, command, day, ack, changed, command_error);
            } else {
                DomainState &domain = _next.domains[command.domain];
                size_t index = 0;
                if (!resolve_entry(domain, command.modifier_handle, index)) {
                    command_error = "modifier_pod_stale_generation";
                    ack.code = RuntimeDomainAckCode::STALE_GENERATION;
                } else {
                    auto &entry = domain.entries[index];
                    if (command.target_generation != 0 &&
                        command.target_generation != entry.target_generation) {
                        command_error = "modifier_pod_stale_generation";
                        ack.code = RuntimeDomainAckCode::STALE_GENERATION;
                    } else if (command.opcode == COMMAND_REFRESH) {
                        if (command.duration_days != -1 && command.duration_days <= 0) {
                            command_error = "modifier_pod_duration_invalid";
                        } else {
                            entry.applied_day = day;
                            entry.expires_day = command.duration_days < 0 ? -1 : day + command.duration_days;
                            ++domain.version;
                            changed = true;
                            ok = true;
                        }
                    } else if (command.opcode == COMMAND_SET_STACKS) {
                        const auto &definition = _catalog.definitions[static_cast<size_t>(entry.definition_id)];
                        if (command.stacks <= 0 || command.stacks > definition.max_stacks) {
                            command_error = "modifier_pod_stack_invalid";
                        } else {
                            entry.stacks = command.stacks;
                            ++domain.version;
                            changed = true;
                            ok = true;
                        }
                    } else {
                        entry.magnitude_q16 = command.magnitude_q16;
                        entry.value_q16 = command.magnitude_q16;
                        ++domain.version;
                        changed = true;
                        ok = true;
                    }
                }
            }
        }
        if (ok) {
            ++report.applied_commands;
            ack.code = RuntimeDomainAckCode::OK;
        } else {
            ++report.rejected_commands;
            if (ack.code == RuntimeDomainAckCode::OK)
                ack.code = command_error == "modifier_pod_stale_generation"
                    ? RuntimeDomainAckCode::STALE_GENERATION : RuntimeDomainAckCode::REJECTED;
        }
        const bool is_intent = ordered[ordered_index].is_intent;
        // Only Effect/cross-domain intents require domain ACKs. Host command
        // receipts remain on the existing RuntimeCommandReceipt path.
        if (is_intent) {
            if (acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                error = "modifier_pod_ack_capacity_exceeded";
                set_error(report, error.c_str());
                _plan_ready = false;
                return false;
            }
            acks.push_back(ack);
        }
        if (changed) ++report.work_units;
        if (is_intent && !ok) {
            error = command_error.empty() ? "modifier_pod_intent_rejected" : command_error;
            set_error(report, error.c_str());
            _plan_ready = false;
            return false;
        }
        if (!ok && error.empty()) error = command_error;
    }
    // Atomic producer batches (worker ideology transitions): every command in
    // a batch applies, or the batch is rolled back and reported as rejected.
    // They never produce Effect ACKs and never fail the shared Modifier day.
    if (atomic_batch_ok != nullptr) atomic_batch_ok->clear();
    if (atomic_batches != nullptr) {
        for (const auto &batch : *atomic_batches) {
            State backup = _next;
            uint32_t applied = 0;
            uint32_t changed_units = 0;
            bool batch_ok = true;
            for (const auto &source : batch) {
                RuntimeModifierPodCommand command = source;
                command.input_generation = input_generation;
                std::string command_error;
                RuntimeDomainAck ack;
                bool changed = false;
                bool ok = validate_command(command, command_error);
                if (ok && command.opcode == COMMAND_APPLY)
                    ok = apply_command(_next, command, day, ack, changed, command_error);
                else if (ok && command.opcode == COMMAND_REMOVE)
                    ok = remove_entry(_next, command, day, ack, changed, command_error);
                else if (ok)
                    ok = false;
                if (!ok) { batch_ok = false; break; }
                ++applied;
                if (changed) ++changed_units;
            }
            if (!batch_ok) {
                _next = std::move(backup);
                report.rejected_commands += static_cast<uint32_t>(batch.size());
            } else {
                report.applied_commands += applied;
                report.work_units += changed_units;
            }
            if (atomic_batch_ok != nullptr)
                atomic_batch_ok->push_back(batch_ok ? 1u : 0u);
        }
    }
    for (DomainState &domain : _next.domains) rebuild_expiry_queue(domain);
    _next.generation = _current.generation + 1;
    _next.committed_day = day;
    _next.state_hash = state_hash(_next);
    build_snapshot(_next, planned_snapshot);
    planned_snapshot.acks = acks;
    report.generation = _next.generation;
    report.state_hash = planned_snapshot.state_hash;
    report.ack_count = static_cast<uint32_t>(acks.size());
    report.work_units += report.expired_entries;
    report.completed = 1;
    report.preflight_ok = 1;
    _planned_snapshot = planned_snapshot;
    _report = report;
    _plan_ready = true;
    return true;
}

bool RuntimeModifierPodAuthority::commit_day(RuntimeModifierPodSnapshot &planned_snapshot,
                                             std::string &error) {
    clear_error(error);
    if (!_plan_ready) { error = "modifier_pod_plan_missing"; return false; }
    if (planned_snapshot.catalog_hash != _catalog.catalog_hash ||
        planned_snapshot.generation != _next.generation ||
        planned_snapshot.state_hash != state_hash(_next)) {
        error = "modifier_pod_snapshot_invalid";
        _plan_ready = false;
        return false;
    }
    _current = std::move(_next);
    _snapshot = std::move(planned_snapshot);
    _planned_snapshot = RuntimeModifierPodSnapshot{};
    _plan_ready = false;
    return true;
}

void RuntimeModifierPodAuthority::discard_plan() {
    _next = _current;
    _planned_snapshot = RuntimeModifierPodSnapshot{};
    _plan_ready = false;
}
