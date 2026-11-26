Dictionary ModifierRuntime::submit_commands(const Dictionary &batch) {
    if (!_configured) return fail_dict("modifier_runtime_not_configured");
    const int32_t protocol = batch.get("protocol_version", 0);
    if (protocol != PROTOCOL_VERSION) return fail_dict("modifier_protocol_unsupported");
    const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
    const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
    const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
    const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
    const PackedStringArray definition_keys = batch.get("definition_keys", PackedStringArray());
    const PackedInt32Array domains = batch.get("domains", PackedInt32Array());
    const PackedInt32Array scopes = batch.get("scopes", PackedInt32Array());
    const PackedInt64Array entities = batch.get("entity_handles", PackedInt64Array());
    const PackedInt64Array groups = batch.get("group_handles", PackedInt64Array());
    const PackedInt64Array source_types = batch.get("source_types", PackedInt64Array());
    const PackedInt64Array source_ids = batch.get("source_ids", PackedInt64Array());
    const PackedInt32Array durations = batch.get("duration_days", PackedInt32Array());
    const PackedInt32Array stacks = batch.get("stacks", PackedInt32Array());
    const PackedInt32Array magnitudes = batch.get("magnitude_q16", PackedInt32Array());
    const PackedInt64Array handles = batch.get("modifier_handles", PackedInt64Array());
    const int32_t count = opcodes.size();
    if (count <= 0 || producers.size() != count || sequences.size() != count ||
        days.size() != count || definition_keys.size() != count || domains.size() != count ||
        scopes.size() != count || entities.size() != count || groups.size() != count ||
        source_types.size() != count || source_ids.size() != count ||
        durations.size() != count || stacks.size() != count || magnitudes.size() != count ||
        handles.size() != count) {
        return fail_dict("modifier_command_shape_invalid");
    }
    PackedInt64Array request_ids;
    request_ids.resize(count);
    for (int32_t i = 0; i < count; ++i) {
        Command command;
        command.opcode = opcodes[i];
        command.producer = producers[i];
        command.sequence = sequences[i];
        command.effective_day = days[i];
        command.request_id = _next_request_id++;
        command.definition_id = definition_id(definition_keys[i].utf8().get_data());
        command.domain = domains[i];
        command.scope = scopes[i];
        command.entity_handle = static_cast<uint64_t>(entities[i]);
        command.group_handle = static_cast<uint64_t>(groups[i]);
        command.source_type = static_cast<uint64_t>(source_types[i]);
        command.source_id = static_cast<uint64_t>(source_ids[i]);
        command.duration_days = durations[i];
        command.stacks = stacks[i];
        command.magnitude_q16 = magnitudes[i];
        command.modifier_handle = static_cast<uint64_t>(handles[i]);
        command.submit_order = ++_submit_order;
        request_ids.set(i, command.request_id);
        _pending_commands.push_back(command);
        _results[command.request_id] = {false, "pending", 0, -1};
    }
    Dictionary out;
    out["ok"] = true;
    out["request_ids"] = request_ids;
    out["pending_count"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool ModifierRuntime::submit_commands_pod(const NativeCommand *commands, size_t count,
                                          std::vector<int64_t> &request_ids,
                                          std::string &error) {
    if (!_configured) {
        error = "modifier_runtime_not_configured";
        return false;
    }
    if (commands == nullptr || count == 0) {
        error = "modifier_command_shape_invalid";
        return false;
    }
    request_ids.clear();
    request_ids.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const NativeCommand &source = commands[i];
        Command command;
        command.opcode = source.opcode;
        command.producer = source.producer;
        command.sequence = source.sequence;
        command.effective_day = source.effective_day;
        command.request_id = _next_request_id++;
        command.definition_id = definition_id(source.definition_key != nullptr
            ? source.definition_key : "");
        command.domain = source.domain;
        command.scope = source.scope;
        command.entity_handle = source.entity_handle;
        command.group_handle = source.group_handle;
        command.source_type = source.source_type;
        command.source_id = source.source_id;
        command.duration_days = source.duration_days;
        command.stacks = source.stacks;
        command.magnitude_q16 = source.magnitude_q16;
        command.modifier_handle = source.modifier_handle;
        command.submit_order = ++_submit_order;
        _pending_commands.push_back(command);
        _results[command.request_id] = {false, "pending", 0, -1};
        request_ids.push_back(command.request_id);
    }
    return true;
}

bool ModifierRuntime::should_run(int64_t day_index) const {
    if (!_configured) return false;
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    for (const Store &store : _stores)
        if (!store.expiry_heap.empty() && store.expiry_heap.top().day <= day_index) return true;
    return _current_day < day_index;
}
