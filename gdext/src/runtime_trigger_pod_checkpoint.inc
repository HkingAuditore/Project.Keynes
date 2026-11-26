bool RuntimeTriggerPodAuthority::encode_save(RuntimeTriggerPodSaveSection &out,
                                             std::string &error) const {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    out = RuntimeTriggerPodSaveSection{};
    out.descriptor.domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    out.descriptor.version = RUNTIME_TRIGGER_POD_ABI_VERSION;
    out.catalog_hash = _catalog.catalog_hash;
    out.committed_day = _state.committed_day;
    out.generation = _state.generation;
    out.state_hash = _state_hash;
    std::vector<uint8_t> payload;
    append_le<uint32_t>(payload, SAVE_MAGIC);
    append_le<uint32_t>(payload, RUNTIME_TRIGGER_POD_ABI_VERSION);
    append_le<uint16_t>(payload, static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT));
    append_le<uint16_t>(payload, 0);
    append_le<uint64_t>(payload, _catalog.catalog_hash);
    append_le<uint64_t>(payload, _state.generation);
    append_le<int64_t>(payload, _state.committed_day);
    append_le<uint64_t>(payload, _state_hash);
    append_le<int32_t>(payload, _catalog.source_count);
    append_le<int32_t>(payload, _catalog.max_states);
    append_le<int32_t>(payload, _catalog.distinct_capacity);
    append_le<int32_t>(payload, _catalog.max_pending_events);
    append_le<int64_t>(payload, _state.next_effect_id);
    append_le<int64_t>(payload, _state.acked_effect_id);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.source_cursor.size()));
    for (size_t i = 0; i < _state.source_cursor.size(); ++i) {
        append_le<int64_t>(payload, _state.source_cursor[i]);
        append_le<uint8_t>(payload, _state.source_needs_resync[i]);
        append_le<int64_t>(payload, _state.source_gap_begin[i]);
        append_le<int64_t>(payload, _state.source_gap_end[i]);
    }
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.enabled.size()));
    for (const uint8_t enabled : _state.enabled) append_le<uint8_t>(payload, enabled);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.states.size()));
    for (const RuntimeTriggerPodSnapshotState &state : _state.states)
        append_state(payload, state, _catalog.distinct_capacity);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.branch_bindings.size()));
    for (const RuntimeTriggerBranchBinding &binding : _state.branch_bindings)
        append_binding(payload, binding);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.pending_events.size()));
    for (const RuntimeTriggerEvent &event : _state.pending_events) append_event(payload, event);
    append_le<uint32_t>(payload, static_cast<uint32_t>(_state.pending_effects.size()));
    for (const RuntimeTriggerEffectIntent &effect : _state.pending_effects) append_effect(payload, effect);
    std::vector<RuntimeTriggerCommand> ordered_commands = _pending_commands;
    std::stable_sort(ordered_commands.begin(), ordered_commands.end(), command_less);
    append_le<uint32_t>(payload, static_cast<uint32_t>(ordered_commands.size()));
    for (const RuntimeTriggerCommand &command : ordered_commands)
        append_command(payload, command);
    append_le<uint32_t>(payload, SAVE_END);
    if (payload.size() > MAX_SAVE_BYTES) { error = "trigger_save_size_exceeded"; return false; }
    out.payload = std::move(payload);
    out.descriptor.payload_size = static_cast<uint32_t>(out.payload.size());
    out.descriptor.checksum = FNV_OFFSET;
    for (const uint8_t byte : out.payload) out.descriptor.checksum = mix_value(out.descriptor.checksum, byte);
    return true;
}

bool RuntimeTriggerPodAuthority::restore_save(
        const RuntimeTriggerPodSaveSection &section,
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    error.clear();
    if (section.descriptor.domain != static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT) ||
        section.descriptor.version != RUNTIME_TRIGGER_POD_ABI_VERSION) {
        error = "trigger_save_domain_version_invalid"; return false;
    }
    if (section.payload.empty() || section.payload.size() != section.descriptor.payload_size ||
        section.payload.size() > MAX_SAVE_BYTES || section.catalog_hash != catalog.catalog_hash) {
        error = "trigger_save_catalog_or_size_invalid"; return false;
    }
    uint64_t checksum = FNV_OFFSET;
    for (const uint8_t byte : section.payload) checksum = mix_value(checksum, byte);
    if (checksum != section.descriptor.checksum) { error = "trigger_save_checksum_failed"; return false; }
    RuntimeTriggerPodAuthority candidate;
    RuntimeTriggerSnapshot restored;
    if (!candidate.bootstrap(RuntimeTriggerSnapshot{}, catalog, error)) return false;
    const uint8_t *data = section.payload.data(); const size_t size = section.payload.size(); size_t cursor = 0;
    uint32_t magic = 0, version = 0; uint16_t domain = 0, reserved = 0;
    uint64_t catalog_hash = 0, generation = 0, state_hash = 0; int64_t committed_day = -1;
    int32_t source_count = 0, max_states = 0, distinct_capacity = 0, max_pending_events = 0;
    if (!read_le(data,size,cursor,magic) || !read_le(data,size,cursor,version) ||
        !read_le(data,size,cursor,domain) || !read_le(data,size,cursor,reserved) ||
        !read_le(data,size,cursor,catalog_hash) || !read_le(data,size,cursor,generation) ||
        !read_le(data,size,cursor,committed_day) || !read_le(data,size,cursor,state_hash) ||
        !read_le(data,size,cursor,source_count) || !read_le(data,size,cursor,max_states) ||
        !read_le(data,size,cursor,distinct_capacity) || !read_le(data,size,cursor,max_pending_events)) {
        error = "trigger_save_header_truncated"; return false;
    }
    if (magic != SAVE_MAGIC || version != RUNTIME_TRIGGER_POD_ABI_VERSION ||
        domain != static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT) ||
        reserved != 0 ||
        catalog_hash != catalog.catalog_hash || generation != section.generation ||
        committed_day != section.committed_day || source_count != catalog.source_count ||
        max_states != catalog.max_states || distinct_capacity != catalog.distinct_capacity ||
        max_pending_events != catalog.max_pending_events || state_hash != section.state_hash) {
        error = "trigger_save_header_invalid"; return false;
    }
    restored.catalog_hash = catalog_hash; restored.generation = generation;
    restored.committed_day = committed_day; restored.current_day = committed_day;
    if (!read_le(data,size,cursor,restored.next_effect_id) ||
        !read_le(data,size,cursor,restored.acked_effect_id)) { error = "trigger_save_cursor_truncated"; return false; }
    uint32_t count = 0;
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.source_count))) { error = "trigger_save_source_shape_invalid"; return false; }
    restored.source_cursor.resize(count); restored.source_needs_resync.resize(count);
    restored.source_gap_begin.resize(count); restored.source_gap_end.resize(count);
    for (uint32_t i=0;i<count;++i) if (!read_le(data,size,cursor,restored.source_cursor[i]) || !read_le(data,size,cursor,restored.source_needs_resync[i]) || !read_le(data,size,cursor,restored.source_gap_begin[i]) || !read_le(data,size,cursor,restored.source_gap_end[i])) { error="trigger_save_source_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.definitions.size()))) { error="trigger_save_enabled_shape_invalid"; return false; }
    restored.enabled.resize(count); for (uint32_t i=0;i<count;++i) if(!read_le(data,size,cursor,restored.enabled[i])) { error="trigger_save_enabled_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.max_states))) { error="trigger_save_state_count_invalid"; return false; }
    restored.states.resize(count); for (RuntimeTriggerPodSnapshotState &state : restored.states) if(!read_state(data,size,cursor,state,catalog.distinct_capacity)) { error="trigger_save_state_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.max_states))) { error="trigger_save_binding_count_invalid"; return false; }
    restored.branch_bindings.resize(count); for (RuntimeTriggerBranchBinding &binding : restored.branch_bindings) if(!read_binding(data,size,cursor,binding)) { error="trigger_save_binding_truncated"; return false; }
    if (!read_count(data,size,cursor,count,static_cast<uint32_t>(catalog.max_pending_events))) { error="trigger_save_event_count_invalid"; return false; }
    restored.pending_events.resize(count); for (RuntimeTriggerEvent &event : restored.pending_events) if(!read_event(data,size,cursor,event)) { error="trigger_save_event_truncated"; return false; }
    if (!read_count(data,size,cursor,count,RUNTIME_TRIGGER_MAX_PENDING_EFFECTS)) { error="trigger_save_effect_count_invalid"; return false; }
    restored.pending_effects.resize(count); for (RuntimeTriggerEffectIntent &effect : restored.pending_effects) if(!read_effect(data,size,cursor,effect)) { error="trigger_save_effect_truncated"; return false; }
    if (!read_count(data,size,cursor,count,RUNTIME_COMMAND_QUEUE_CAPACITY)) { error="trigger_save_command_count_invalid"; return false; }
    candidate._pending_commands.resize(count);
    for (size_t i = 0; i < candidate._pending_commands.size(); ++i) {
        RuntimeTriggerCommand &command = candidate._pending_commands[i];
        if (!read_command(data, size, cursor, command)) {
            error = "trigger_save_command_truncated";
            return false;
        }
        if (!validate_command_shape(command, catalog, error) ||
            (command.observed_generation != 0 &&
             command.observed_generation > generation)) {
            if (error.empty()) error = "trigger_save_command_invalid";
            return false;
        }
        if (i > 0 && !command_less(candidate._pending_commands[i - 1], command)) {
            error = "trigger_save_command_order_invalid";
            return false;
        }
    }
    uint32_t end = 0; if(!read_le(data,size,cursor,end) || end != SAVE_END || cursor != size) { error="trigger_save_trailing_bytes"; return false; }
    if (!candidate.validate_state(restored,error) || hash_snapshot(restored) != state_hash) { if(error.empty()) error="trigger_save_state_hash_failed"; return false; }
    candidate._state = std::move(restored); candidate._state_hash = state_hash; candidate._bootstrapped = true; candidate._next_generation = candidate._state.generation + 1u;
    *this = std::move(candidate);
    return true;
}
