bool RuntimeTriggerPodAuthority::validate_catalog(
        const RuntimeTriggerPodCatalog &catalog, std::string &error) const {
    error.clear();
    if (catalog.definitions.size() > RUNTIME_TRIGGER_MAX_DEFINITIONS ||
        catalog.effects.size() > RUNTIME_TRIGGER_MAX_EFFECT_DEFINITIONS ||
        catalog.condition_ops.size() > RUNTIME_TRIGGER_MAX_CONDITION_OPS *
            catalog.definitions.size() || catalog.max_states <= 0 ||
        catalog.max_states > static_cast<int32_t>(RUNTIME_TRIGGER_MAX_DEFINITIONS) ||
        catalog.max_pending_events <= 0 ||
        catalog.max_pending_events > static_cast<int32_t>(RUNTIME_TRIGGER_MAX_PENDING_EVENTS) ||
        catalog.distinct_capacity <= 0 || catalog.distinct_capacity > 4096 ||
        catalog.source_count <= 0 || catalog.event_type_span <= 0) {
        error = "trigger_catalog_shape_invalid";
        return false;
    }
    if (catalog.catalog_hash == 0) {
        error = "trigger_catalog_hash_missing";
        return false;
    }
    for (const RuntimeTriggerDefinition &definition : catalog.definitions) {
        const bool invalid =
            definition.source_id < 0 || definition.source_id >= catalog.source_count ||
            definition.event_type < 0 || definition.event_type >= catalog.event_type_span ||
            definition.threshold <= 0 ||
            definition.condition_begin > catalog.condition_ops.size() ||
            definition.condition_count > catalog.condition_ops.size() - definition.condition_begin ||
            definition.effect_begin > catalog.effects.size() ||
            definition.effect_count > catalog.effects.size() - definition.effect_begin ||
            definition.aggregator < static_cast<int32_t>(RuntimeTriggerAggregator::COUNT) ||
            definition.aggregator > static_cast<int32_t>(RuntimeTriggerAggregator::CONSECUTIVE_DURATION) ||
            definition.value_field < 0 || definition.value_field > 7 ||
            definition.distinct_field < 0 || definition.distinct_field > 7 ||
            definition.scope < 0 || definition.scope > 2 ||
            definition.target_resolver < static_cast<int32_t>(RuntimeTriggerTargetResolver::STATIC) ||
            definition.target_resolver > static_cast<int32_t>(RuntimeTriggerTargetResolver::SNAPSHOT) ||
            (definition.mode != static_cast<int32_t>(RuntimeTriggerMode::REPEAT) &&
             definition.mode != static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT) ) ||
            definition.cooldown_days < 0 || definition.window_days < 0 ||
            ((definition.aggregator == static_cast<int32_t>(RuntimeTriggerAggregator::WINDOW_COUNT) ||
              definition.aggregator == static_cast<int32_t>(RuntimeTriggerAggregator::WINDOW_SUM)) &&
             definition.window_days <= 0) ||
            (definition.aggregator == static_cast<int32_t>(RuntimeTriggerAggregator::CONSECUTIVE_DURATION) &&
             (definition.duration_field < 0 || definition.duration_field > 7));
        if (invalid) {
            error = "trigger_definition_invalid";
            return false;
        }
    }
    for (const int32_t opcode : catalog.condition_ops) {
        if (opcode < static_cast<int32_t>(RuntimeTriggerConditionOp::PUSH_TRUE) ||
            opcode > static_cast<int32_t>(RuntimeTriggerConditionOp::BOOL_NOT)) {
            error = "trigger_condition_opcode_invalid";
            return false;
        }
    }
    for (const RuntimeTriggerEffectDefinition &effect : catalog.effects) {
        const int32_t action = effect.action;
        const bool action_valid = action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_APPLY) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_REMOVE) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_REFRESH) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::MODIFIER_SET_STACKS) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::ECONOMY_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::GAMEPLAY_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::PUBLISH_EVENT) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::CUSTOM_DOMAIN_COMMAND) ||
            action == static_cast<int32_t>(RuntimeTriggerAction::IDEOLOGY_COMMAND);
        if (!action_valid ||
            effect.target_resolver < static_cast<int32_t>(RuntimeTriggerTargetResolver::STATIC) ||
            effect.target_resolver > static_cast<int32_t>(RuntimeTriggerTargetResolver::SNAPSHOT) ||
            effect.value_mode < static_cast<int32_t>(RuntimeTriggerValueMode::CONSTANT) ||
            effect.value_mode > static_cast<int32_t>(RuntimeTriggerValueMode::EVENT_VALUE) ||
            effect.domain < 0 || effect.opcode < 0) {
            error = "trigger_effect_definition_invalid";
            return false;
        }
    }
    return true;
}

bool RuntimeTriggerPodAuthority::validate_state(
        const RuntimeTriggerSnapshot &snapshot, std::string &error) const {
    error.clear();
    if (!_catalog.definitions.empty() && snapshot.enabled.size() != _catalog.definitions.size()) {
        error = "trigger_enabled_shape_invalid";
        return false;
    }
    if (snapshot.source_cursor.size() != static_cast<size_t>(_catalog.source_count) ||
        snapshot.source_needs_resync.size() != snapshot.source_cursor.size() ||
        snapshot.source_gap_begin.size() != snapshot.source_cursor.size() ||
        snapshot.source_gap_end.size() != snapshot.source_cursor.size() ||
        snapshot.states.size() > static_cast<size_t>(_catalog.max_states) ||
        snapshot.pending_events.size() > static_cast<size_t>(_catalog.max_pending_events) ||
        snapshot.pending_effects.size() > RUNTIME_TRIGGER_MAX_PENDING_EFFECTS ||
        snapshot.next_effect_id <= 0 || snapshot.acked_effect_id < 0 ||
        snapshot.current_day < snapshot.committed_day) {
        error = "trigger_snapshot_shape_invalid";
        return false;
    }
    for (size_t source = 0; source < snapshot.source_needs_resync.size(); ++source) {
        const uint8_t value = snapshot.source_needs_resync[source];
        if (value > 1) { error = "trigger_source_resync_flag_invalid"; return false; }
        if (value == 0 && (snapshot.source_gap_begin[source] != 0 ||
                           snapshot.source_gap_end[source] != 0)) {
            error = "trigger_source_gap_without_resync";
            return false;
        }
        if (value != 0 && (snapshot.source_gap_begin[source] <= 0 ||
                           snapshot.source_gap_end[source] <
                               snapshot.source_gap_begin[source])) {
            error = "trigger_source_gap_invalid";
            return false;
        }
    }
    for (const uint8_t value : snapshot.enabled) {
        if (value > 1) { error = "trigger_enabled_value_invalid"; return false; }
    }
    for (size_t i = 0; i < snapshot.states.size(); ++i) {
        const RuntimeTriggerPodSnapshotState &state = snapshot.states[i];
        if (state.trigger_id < 0 || state.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            state.distinct_keys.size() != static_cast<size_t>(_catalog.distinct_capacity) ||
            state.target_generation != static_cast<uint32_t>(state.target_handle >> 32u) ||
            state.completed > 1 || state.initialized > 1 || state.needs_resync > 1) {
            error = "trigger_state_shape_invalid";
            return false;
        }
        if (i > 0 && !state_less(snapshot.states[i - 1], state)) {
            error = "trigger_state_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.states[i - 1].trigger_id == state.trigger_id &&
            snapshot.states[i - 1].target_handle == state.target_handle) {
            error = "trigger_state_duplicate";
            return false;
        }
    }
    for (size_t i = 0; i < snapshot.pending_events.size(); ++i) {
        const RuntimeTriggerEvent &event = snapshot.pending_events[i];
        if (!valid_event(event, _catalog) || event.snapshot > 1) {
            error = "trigger_pending_event_invalid";
            return false;
        }
        if (i > 0 && !event_less(snapshot.pending_events[i - 1], event)) {
            error = "trigger_pending_event_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.pending_events[i - 1].source_id == event.source_id &&
            snapshot.pending_events[i - 1].event_id == event.event_id) {
            error = "trigger_pending_event_duplicate";
            return false;
        }
    }
    int64_t maximum_effect_id = 0;
    for (size_t i = 0; i < snapshot.pending_effects.size(); ++i) {
        const RuntimeTriggerEffectIntent &effect = snapshot.pending_effects[i];
        if (effect.id <= 0 || effect.effective_day < 0 ||
            effect.trigger_id < 0 ||
            effect.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            effect.effect_definition_id < 0 ||
            effect.effect_definition_id >= static_cast<int32_t>(_catalog.effects.size()) ||
            effect.target_generation != static_cast<uint32_t>(effect.target_handle >> 32u)) {
            error = "trigger_pending_effect_invalid";
            return false;
        }
        maximum_effect_id = std::max(maximum_effect_id, effect.id);
        if (i > 0 && !effect_less(snapshot.pending_effects[i - 1], effect)) {
            error = "trigger_pending_effect_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.pending_effects[i - 1].id == effect.id) {
            error = "trigger_pending_effect_duplicate";
            return false;
        }
    }
    if (snapshot.acked_effect_id >= snapshot.next_effect_id ||
        maximum_effect_id >= snapshot.next_effect_id) {
        error = "trigger_effect_cursor_invalid";
        return false;
    }
    for (size_t i = 0; i < snapshot.branch_bindings.size(); ++i) {
        const RuntimeTriggerBranchBinding &binding = snapshot.branch_bindings[i];
        if (binding.trigger_id < 0 ||
            binding.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            _catalog.definitions[binding.trigger_id].dynamic_binding == 0 ||
            binding.branch_handle == 0 || binding.cell < 0 ||
            binding.reward_target < 0 || binding.reward_target > 1 ||
            binding.enabled > 1) {
            error = "trigger_branch_binding_invalid";
            return false;
        }
        if (i > 0 && !binding_less(snapshot.branch_bindings[i - 1], binding)) {
            error = "trigger_branch_binding_order_invalid";
            return false;
        }
        if (i > 0 && snapshot.branch_bindings[i - 1].trigger_id == binding.trigger_id &&
            snapshot.branch_bindings[i - 1].branch_handle == binding.branch_handle &&
            snapshot.branch_bindings[i - 1].cell == binding.cell) {
            error = "trigger_branch_binding_duplicate";
            return false;
        }
    }
    return true;
}

bool RuntimeTriggerPodAuthority::bootstrap(
        const RuntimeTriggerSnapshot &snapshot,
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    error.clear();
    if (!validate_catalog(catalog, error)) return false;
    _catalog = catalog;
    RuntimeTriggerSnapshot initial = snapshot;
    initial.catalog_hash = catalog.catalog_hash;
    if (initial.source_cursor.empty()) initial.source_cursor.assign(catalog.source_count, 0);
    if (initial.source_needs_resync.empty()) initial.source_needs_resync.assign(catalog.source_count, 0);
    if (initial.source_gap_begin.empty()) initial.source_gap_begin.assign(catalog.source_count, 0);
    if (initial.source_gap_end.empty()) initial.source_gap_end.assign(catalog.source_count, 0);
    if (initial.enabled.empty()) {
        initial.enabled.resize(catalog.definitions.size());
        for (size_t i = 0; i < catalog.definitions.size(); ++i)
            initial.enabled[i] = catalog.definitions[i].enabled;
    }
    if (initial.next_effect_id <= 0) initial.next_effect_id = 1;
    // Facade exports are dense snapshots, but their state insertion order is
    // an implementation detail of the legacy lookup table. Normalize it at
    // the worker boundary so validation and every later hash use one order.
    initial = canonicalize_snapshot(initial, true);
    if (!validate_state(initial, error)) return false;
    _state = std::move(initial);
    _pending_commands.clear();
    _diagnostics = RuntimeTriggerPodDiagnostics{};
    _state_hash = hash_snapshot(_state);
    _next_generation = _state.generation + 1u;
    _bootstrapped = true;
    _plan_active = false;
    _reference_pending = false;
    _reference_day = -1;
    _reference_input_hash = 0;
    _reference_state_hash = 0;
    _reference_effect_hash = 0;
    return true;
}
