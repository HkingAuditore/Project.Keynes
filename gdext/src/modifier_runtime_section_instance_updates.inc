uint64_t ModifierRuntime::apply_command(const Command &command, int64_t day,
                                        Result &result) {
    if (command.definition_id < 0 ||
        command.definition_id >= static_cast<int32_t>(_definitions.size())) {
        result = {false, "modifier_definition_unknown", 0, day};
        return 0;
    }
    const Definition &definition = _definitions[command.definition_id];
    if (definition.domain != command.domain) {
        result = {false, "modifier_definition_domain_mismatch", 0, day};
        return 0;
    }
    if (command.magnitude_q16 < 0 || command.magnitude_q16 > MAX_MAGNITUDE_Q16) {
        result = {false, "modifier_magnitude_invalid", 0, day};
        return 0;
    }
    std::string target_error;
    if (!validate_target(command, target_error)) {
        result = {false, target_error, 0, day};
        return 0;
    }
    const int32_t duration = command.duration_days == -2
        ? definition.default_duration : command.duration_days;
    if (duration != -1 && duration <= 0) {
        result = {false, "modifier_duration_invalid", 0, day};
        return 0;
    }
    const int32_t requested_stacks = std::clamp(command.stacks, 1, definition.max_stacks);
    Store &store = _stores[command.domain];
    const UniqueKey unique{command.definition_id, command.scope,
        scope_id_for(command), command.source_type, command.source_id};
    if (definition.policy != INDEPENDENT) {
        const auto existing = store.unique_instances.find(unique);
        if (existing != store.unique_instances.end() &&
            existing->second < store.active.size() && store.active[existing->second] != 0) {
            const uint32_t index = existing->second;
            remove_instance_from_buckets(command.domain, index);
            const int32_t old_stacks = store.stacks[index];
            const int32_t old_magnitude = store.magnitude_q16[index];
            store.stacks[index] = definition.policy == STACK_REFRESH
                ? std::min(definition.max_stacks, old_stacks + requested_stacks)
                : requested_stacks;
            store.magnitude_q16[index] = command.magnitude_q16;
            store.applied_day[index] = day;
            store.expiry_day[index] = duration < 0 ? PERMANENT_EXPIRY : day + duration;
            ++store.expiry_revision[index];
            if (store.expiry_day[index] >= 0) store.expiry_heap.push({
                store.expiry_day[index], index, store.generation[index],
                store.expiry_revision[index]});
            add_instance_to_buckets(command.domain, index);
            ++store.snapshot_version;
            const uint64_t handle = make_handle(store, index);
            result = {true, "", handle, day};
            Event event{0, day,
                definition.policy == STACK_REFRESH ? EVENT_STACK : EVENT_REPLACE,
                command.domain, handle, command.definition_id, command.entity_handle,
                command.group_handle, command.scope, command.source_type,
                command.source_id, old_stacks,
                store.stacks[index], command.request_id, ""};
            event.old_magnitude_q16 = old_magnitude;
            event.new_magnitude_q16 = command.magnitude_q16;
            push_event(std::move(event));
            return handle;
        }
    }

    uint32_t index = 0;
    if (!store.free_list.empty()) {
        index = store.free_list.back();
        store.free_list.pop_back();
        if (++store.generation[index] == 0) store.generation[index] = 1;
    } else {
        index = static_cast<uint32_t>(store.active.size());
        store.active.push_back(0);
        store.generation.push_back(1);
        store.definition_id.push_back(-1);
        store.entity_handle.push_back(0);
        store.group_handle.push_back(0);
        store.source_type.push_back(0);
        store.source_id.push_back(0);
        store.scope.push_back(GLOBAL);
        store.stacks.push_back(1);
        store.magnitude_q16.push_back(Q16_ONE);
        store.applied_day.push_back(-1);
        store.expiry_day.push_back(PERMANENT_EXPIRY);
        store.expiry_revision.push_back(0);
    }
    store.active[index] = 1;
    store.definition_id[index] = command.definition_id;
    store.entity_handle[index] = command.entity_handle;
    store.group_handle[index] = command.group_handle;
    store.source_type[index] = command.source_type;
    store.source_id[index] = command.source_id;
    store.scope[index] = command.scope;
    store.stacks[index] = requested_stacks;
    store.magnitude_q16[index] = command.magnitude_q16;
    store.applied_day[index] = day;
    store.expiry_day[index] = duration < 0 ? PERMANENT_EXPIRY : day + duration;
    ++store.expiry_revision[index];
    if (store.expiry_day[index] >= 0) store.expiry_heap.push({store.expiry_day[index],
        index, store.generation[index], store.expiry_revision[index]});
    if (definition.policy != INDEPENDENT) store.unique_instances[unique] = index;
    add_instance_to_buckets(command.domain, index);
    ++store.active_instances;
    store.peak_instances = std::max(store.peak_instances, store.active_instances);
    ++store.snapshot_version;
    const uint64_t handle = make_handle(store, index);
    result = {true, "", handle, day};
    Event event{0, day, EVENT_APPLY, command.domain, handle,
        command.definition_id, command.entity_handle, command.group_handle,
        command.scope, command.source_type, command.source_id, 0,
        requested_stacks, command.request_id, ""};
    event.old_magnitude_q16 = 0;
    event.new_magnitude_q16 = command.magnitude_q16;
    push_event(std::move(event));
    return handle;
}

int32_t ModifierRuntime::remove_rows_for_source(uint64_t source_type,
                                                 uint64_t source_id,
                                                 int64_t day) {
    if (!_configured) return 0;
    int32_t removed = 0;
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) {
        Store &store = _stores[domain];
        // Collect handles FIRST: `remove_handle` recycles the slot index, so removing
        // while scanning would skip the row that lands in the freed slot.
        std::vector<uint64_t> handles;
        for (size_t index = 0; index < store.active.size(); ++index) {
            if (store.active[index] == 0) continue;
            if (store.source_type[index] != source_type) continue;
            if (store.source_id[index] != source_id) continue;
            handles.push_back(make_handle(store, static_cast<uint32_t>(index)));
        }
        for (const uint64_t handle : handles) {
            // EVENT_REJECT, not EVENT_REMOVE: these rows are being reversed because the
            // originating batch was rejected, and the journal should say so.
            if (remove_handle(domain, handle, day, EVENT_REJECT, 0,
                              "batch_rejected", nullptr))
                ++removed;
        }
    }
    return removed;
}

bool ModifierRuntime::remove_handle(int32_t domain, uint64_t handle, int64_t day,
                                    int32_t event_kind, int64_t request_id,
                                    const std::string &reason, Result *result) {
    if (domain < 0 || domain >= DOMAIN_COUNT) {
        if (result) *result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    Store &store = _stores[domain];
    uint32_t index = 0;
    if (!resolve_handle(store, handle, index)) {
        if (result) *result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    const int32_t definition_id_value = store.definition_id[index];
    const Definition &definition = _definitions[definition_id_value];
    const int32_t old_stacks = store.stacks[index];
    const int32_t old_magnitude = store.magnitude_q16[index];
    if (definition.policy != INDEPENDENT) {
        const uint64_t sid = store.scope[index] == GLOBAL ? 0 :
            (store.scope[index] == GROUP ? store.group_handle[index] : store.entity_handle[index]);
        store.unique_instances.erase({definition_id_value, store.scope[index], sid,
            store.source_type[index], store.source_id[index]});
    }
    remove_instance_from_buckets(domain, index);
    const uint64_t entity = store.entity_handle[index];
    const uint64_t group = store.group_handle[index];
    const int32_t scope = store.scope[index];
    const uint64_t source_type = store.source_type[index];
    const uint64_t source_id = store.source_id[index];
    store.active[index] = 0;
    store.free_list.push_back(index);
    --store.active_instances;
    ++store.snapshot_version;
    if (result) *result = {true, "", handle, day};
    Event event{0, day, event_kind, domain, handle, definition_id_value, entity,
        group, scope, source_type, source_id, old_stacks, 0, request_id, reason};
    event.old_magnitude_q16 = old_magnitude;
    event.new_magnitude_q16 = 0;
    push_event(std::move(event));
    return true;
}

bool ModifierRuntime::remove_unique_command(const Command &command, int64_t day,
                                            Result &result) {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT ||
        command.definition_id < 0 ||
        command.definition_id >= static_cast<int32_t>(_definitions.size())) {
        result = {false, "modifier_remove_definition_invalid", 0, day};
        return false;
    }
    const Definition &definition = _definitions[command.definition_id];
    if (definition.policy == INDEPENDENT) {
        // Effect-owned independent stacks have no `unique_instances` entry,
        // but retirement still must remove every row created by this exact
        // (definition, scope, source) identity. This is a lifecycle-only
        // boundary operation, never a simulation hot-loop query.
        const uint64_t requested_scope_id = scope_id_for(command);
        const Store &store = _stores[command.domain];
        std::vector<uint64_t> matching_handles;
        for (uint32_t index = 0; index < store.active.size(); ++index) {
            if (store.active[index] == 0 ||
                store.definition_id[index] != command.definition_id ||
                store.scope[index] != command.scope ||
                store.source_type[index] != command.source_type ||
                store.source_id[index] != command.source_id)
                continue;
            const uint64_t stored_scope_id = store.scope[index] == GLOBAL ? 0 :
                (store.scope[index] == GROUP ? store.group_handle[index] :
                 store.entity_handle[index]);
            if (stored_scope_id == requested_scope_id)
                matching_handles.push_back(make_handle(store, index));
        }
        if (matching_handles.empty()) {
            result = {true, "already_removed", 0, day};
            return true;
        }
        Result removed;
        for (const uint64_t handle : matching_handles) {
            if (!remove_handle(command.domain, handle, day, EVENT_REMOVE,
                               command.request_id, "removed", &removed)) {
                result = removed;
                return false;
            }
        }
        result = removed;
        return true;
    }
    const uint64_t scope_id = scope_id_for(command);
    const UniqueKey key{command.definition_id, command.scope, scope_id,
                        command.source_type, command.source_id};
    const Store &store = _stores[command.domain];
    const auto found = store.unique_instances.find(key);
    // Retrying after a completed remove must not turn a normal replay into a
    // stale-handle failure.
    if (found == store.unique_instances.end()) {
        result = {true, "already_removed", 0, day};
        return true;
    }
    return remove_handle(command.domain, make_handle(store, found->second), day,
                         EVENT_REMOVE, command.request_id, "removed", &result);
}

bool ModifierRuntime::refresh_handle(const Command &command, int64_t day,
                                     Result &result) {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT) {
        result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    Store &store = _stores[command.domain];
    uint32_t index = 0;
    if (!resolve_handle(store, command.modifier_handle, index)) {
        result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    if (command.duration_days != -1 && command.duration_days <= 0) {
        result = {false, "modifier_duration_invalid", 0, day};
        return false;
    }
    store.applied_day[index] = day;
    store.expiry_day[index] = command.duration_days < 0 ? PERMANENT_EXPIRY :
        day + command.duration_days;
    ++store.expiry_revision[index];
    if (store.expiry_day[index] >= 0) store.expiry_heap.push({store.expiry_day[index],
        index, store.generation[index], store.expiry_revision[index]});
    ++store.snapshot_version;
    result = {true, "", command.modifier_handle, day};
    Event event{0, day, EVENT_REFRESH, command.domain, command.modifier_handle,
        store.definition_id[index], store.entity_handle[index], store.group_handle[index],
        store.scope[index], store.source_type[index], store.source_id[index],
        store.stacks[index], store.stacks[index], command.request_id, ""};
    event.old_magnitude_q16 = store.magnitude_q16[index];
    event.new_magnitude_q16 = store.magnitude_q16[index];
    push_event(std::move(event));
    return true;
}

bool ModifierRuntime::set_stacks(const Command &command, int64_t day,
                                 Result &result) {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT) {
        result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    Store &store = _stores[command.domain];
    uint32_t index = 0;
    if (!resolve_handle(store, command.modifier_handle, index)) {
        result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    const Definition &definition = _definitions[store.definition_id[index]];
    if (command.stacks <= 0 || command.stacks > definition.max_stacks) {
        result = {false, "modifier_stack_count_invalid", 0, day};
        return false;
    }
    const int32_t old_stacks = store.stacks[index];
    remove_instance_from_buckets(command.domain, index);
    store.stacks[index] = command.stacks;
    add_instance_to_buckets(command.domain, index);
    ++store.snapshot_version;
    result = {true, "", command.modifier_handle, day};
    Event event{0, day, EVENT_STACK, command.domain, command.modifier_handle,
        store.definition_id[index], store.entity_handle[index], store.group_handle[index],
        store.scope[index], store.source_type[index], store.source_id[index],
        old_stacks, command.stacks, command.request_id, ""};
    event.old_magnitude_q16 = store.magnitude_q16[index];
    event.new_magnitude_q16 = store.magnitude_q16[index];
    push_event(std::move(event));
    return true;
}

bool ModifierRuntime::set_magnitude(const Command &command, int64_t day,
                                    Result &result) {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT) {
        result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    if (command.magnitude_q16 < 0 || command.magnitude_q16 > MAX_MAGNITUDE_Q16) {
        result = {false, "modifier_magnitude_invalid", 0, day};
        return false;
    }
    Store &store = _stores[command.domain];
    uint32_t index = 0;
    if (!resolve_handle(store, command.modifier_handle, index)) {
        result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    const int32_t old_magnitude = store.magnitude_q16[index];
    if (old_magnitude != command.magnitude_q16) {
        remove_instance_from_buckets(command.domain, index);
        store.magnitude_q16[index] = command.magnitude_q16;
        add_instance_to_buckets(command.domain, index);
        ++store.snapshot_version;
    }
    result = {true, "", command.modifier_handle, day};
    Event event{0, day, EVENT_MAGNITUDE, command.domain, command.modifier_handle,
        store.definition_id[index], store.entity_handle[index], store.group_handle[index],
        store.scope[index], store.source_type[index], store.source_id[index],
        store.stacks[index], store.stacks[index], command.request_id, ""};
    event.old_magnitude_q16 = old_magnitude;
    event.new_magnitude_q16 = command.magnitude_q16;
    push_event(std::move(event));
    return true;
}

Dictionary ModifierRuntime::run_daily(int64_t day_index) {
    if (!_configured) return fail_dict("modifier_runtime_not_configured");
    if (day_index < _current_day) return fail_dict("modifier_day_regression");
    _last_bucket_update_ms = 0.0;
    _last_bucket_rebuild_ms = 0.0;
    const auto expiry_start = std::chrono::steady_clock::now();
    int64_t expired_count = 0;
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) {
        Store &store = _stores[domain];
        while (!store.expiry_heap.empty() && store.expiry_heap.top().day <= day_index) {
            const ExpiryNode node = store.expiry_heap.top();
            store.expiry_heap.pop();
            if (node.index >= store.active.size() || store.active[node.index] == 0 ||
                store.generation[node.index] != node.generation ||
                store.expiry_revision[node.index] != node.revision ||
                store.expiry_day[node.index] != node.day) continue;
            const uint64_t handle = make_handle(store, node.index);
            if (remove_handle(domain, handle, day_index, EVENT_EXPIRE, 0, "expired")) {
                ++expired_count;
                ++_expired;
            }
        }
    }
    _last_expiry_ms = elapsed_ms(expiry_start);

    const auto command_start = std::chrono::steady_clock::now();
    std::stable_sort(_pending_commands.begin(), _pending_commands.end(),
        [](const Command &a, const Command &b) {
            if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
            if (a.producer != b.producer) return a.producer < b.producer;
            if (a.sequence != b.sequence) return a.sequence < b.sequence;
            return a.submit_order < b.submit_order;
        });
    std::vector<Command> retained;
    retained.reserve(_pending_commands.size());
    int64_t applied_count = 0;
    for (const Command &command : _pending_commands) {
        if (command.effective_day > day_index) {
            retained.push_back(command);
            continue;
        }
        Result result;
        bool ok = false;
        if (command.opcode == COMMAND_APPLY) {
            ok = apply_command(command, day_index, result) != 0;
        } else if (command.opcode == COMMAND_REMOVE) {
            ok = command.modifier_handle != 0
                ? remove_handle(command.domain, command.modifier_handle, day_index,
                    EVENT_REMOVE, command.request_id, "removed", &result)
                : remove_unique_command(command, day_index, result);
        } else if (command.opcode == COMMAND_REFRESH) {
            ok = refresh_handle(command, day_index, result);
        } else if (command.opcode == COMMAND_SET_STACKS) {
            ok = set_stacks(command, day_index, result);
        } else if (command.opcode == COMMAND_SET_MAGNITUDE) {
            ok = set_magnitude(command, day_index, result);
        } else {
            result = {false, "modifier_command_opcode_invalid", 0, day_index};
        }
        _results[command.request_id] = result;
        if (ok) {
            ++applied_count;
            ++_commands_applied;
        } else {
            ++_commands_rejected;
            push_event({0, day_index, EVENT_REJECT, command.domain,
                command.modifier_handle, command.definition_id, command.entity_handle,
                command.group_handle, command.scope, command.source_type,
                command.source_id, 0, 0,
                command.request_id, result.reason});
        }
    }
    _pending_commands.swap(retained);
    _last_command_ms = elapsed_ms(command_start);
    const auto publish_start = std::chrono::steady_clock::now();
    _current_day = day_index;
    _last_publish_ms = elapsed_ms(publish_start);
    Dictionary out = report();
    out["ok"] = true;
    out["done"] = true;
    out["path"] = "MODIFIER_GRAPH";
    out["stage"] = "modifier_publish";
    out["day_index"] = day_index;
    out["commands_applied"] = applied_count;
    out["expired"] = expired_count;
    out["work_done"] = applied_count + expired_count;
    return out;
}
