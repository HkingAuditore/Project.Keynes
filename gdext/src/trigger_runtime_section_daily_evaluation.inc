bool TriggerRuntime::update_aggregate(int32_t state_index,
                                      const Definition &definition,
                                      const Event &event, int64_t &old_value,
                                      int64_t &new_value, int64_t &event_value) {
    old_value = _state.accumulator[state_index];
    event_value = event_field(event, definition.value_field);
    if (event.snapshot) {
        const int64_t previous = _state.last_observed[state_index];
        _state.last_observed[state_index] = event_value;
        if (definition.aggregator == SNAPSHOT_DIFF) {
            _state.accumulator[state_index] = _state.initialized[state_index] == 0
                ? 0 : saturating_sub(event_value, previous);
        } else {
            _state.accumulator[state_index] = event_value;
        }
        _state.initialized[state_index] = 1;
        new_value = _state.accumulator[state_index];
        return true;
    }
    if (definition.aggregator == CONSECUTIVE_DURATION) {
        const int64_t metric_value = event_value;
        const int64_t coverage = std::max<int64_t>(
            1, event_field(event, definition.duration_field));
        int64_t &last_sample_day = _state.last_sample_day[state_index];
        _state.last_observed[state_index] = metric_value;
        if (last_sample_day >= 0 && event.day <= last_sample_day) {
            new_value = _state.accumulator[state_index];
            return true;
        }
        const bool gap = last_sample_day >= 0 &&
            event.day > saturating_add(last_sample_day, coverage);
        last_sample_day = event.day;
        if (metric_value < definition.qualifier_threshold) {
            _state.accumulator[state_index] = 0;
        } else if (gap || _state.initialized[state_index] == 0) {
            _state.accumulator[state_index] = coverage;
        } else {
            _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], coverage);
        }
        _state.initialized[state_index] = 1;
        new_value = _state.accumulator[state_index];
        return true;
    }
    if ((definition.aggregator == WINDOW_COUNT ||
         definition.aggregator == WINDOW_SUM) && definition.window_days > 0) {
        int64_t &window_start = _state.window_start_day[state_index];
        if (window_start < 0 || event.day >= window_start + definition.window_days) {
            window_start = event.day;
            _state.accumulator[state_index] = 0;
            _state.remainder[state_index] = 0;
            old_value = 0;
        }
    }
    switch (definition.aggregator) {
        case COUNT:
        case WINDOW_COUNT:
            _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], event_value > 0 ? event_value : 1);
            break;
        case SUM:
        case WINDOW_SUM:
        case SNAPSHOT_DIFF:
            _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], event_value);
            break;
        case MINIMUM:
            _state.accumulator[state_index] = _state.initialized[state_index] == 0
                ? event_value : std::min(_state.accumulator[state_index], event_value);
            break;
        case MAXIMUM:
            _state.accumulator[state_index] = _state.initialized[state_index] == 0
                ? event_value : std::max(_state.accumulator[state_index], event_value);
            break;
        case STATE_LEVEL:
            _state.last_observed[state_index] = _state.accumulator[state_index];
            _state.accumulator[state_index] = event_value;
            break;
        case DISTINCT_COUNT: {
            const int64_t distinct = event_field(event, definition.distinct_field);
            const size_t begin = static_cast<size_t>(state_index) * _distinct_capacity;
            size_t slot = static_cast<size_t>(state_hash(state_index,
                static_cast<uint64_t>(distinct))) % _distinct_capacity;
            bool inserted = false;
            for (int32_t probe = 0; probe < _distinct_capacity; ++probe) {
                int64_t &key = _distinct_keys[begin + slot];
                if (key == distinct) break;
                if (key == EMPTY_DISTINCT_KEY) {
                    key = distinct;
                    inserted = true;
                    break;
                }
                slot = (slot + 1U) % _distinct_capacity;
            }
            if (inserted) _state.accumulator[state_index] = saturating_add(
                _state.accumulator[state_index], 1);
            else if (_state.accumulator[state_index] >= _distinct_capacity) {
                _state.needs_resync[state_index] = 1;
                _last_error = "trigger_distinct_capacity_exhausted";
                return false;
            }
            break;
        }
        default: return false;
    }
    _state.initialized[state_index] = 1;
    new_value = _state.accumulator[state_index];
    return true;
}

bool TriggerRuntime::evaluate_conditions(const Definition &definition,
                                         int32_t state_index,
                                         int64_t old_value, int64_t new_value,
                                         int64_t old_level,
                                         int64_t new_level) const {
    if (definition.condition_count == 0)
        return new_level > old_level;
    const auto operation = [&](size_t index) {
        return static_cast<RuntimeTriggerConditionOp>(_condition_ops[definition.condition_begin + index]);
    };
    return evaluate_trigger_conditions<MAX_CONDITION_OPS>(definition.condition_count, operation,
        [&](size_t index, bool &value) {
            switch (static_cast<int32_t>(operation(index))) {
                case PUSH_TRUE: value = true; break;
                case PUSH_ACC_GTE: value = new_value >= definition.threshold; break;
                case PUSH_CROSSING: value = new_level > old_level; break;
                case PUSH_LEVEL_CHANGE: value = new_level != old_level; break;
                case PUSH_COOLDOWN_READY:
                    value = _current_day >= _state.cooldown_until[state_index]; break;
                case PUSH_NOT_COMPLETED: value = _state.completed[state_index] == 0; break;
                default: return false;
            }
            return true;
        });
}

int64_t TriggerRuntime::fire_count_for(const Definition &definition,
                                       int32_t state_index,
                                       int64_t old_value, int64_t new_value,
                                       int64_t old_level,
                                       int64_t new_level) const {
    if (definition.mode == ONE_SHOT)
        return _state.completed[state_index] == 0 && new_value >= definition.threshold ? 1 : 0;
    if (new_level > old_level) return new_level - old_level;
    return new_level != old_level ? 1 : 0;
}

void TriggerRuntime::emit_effects(int32_t trigger_id, int32_t state_index,
                                  const Event &event, int64_t fire_count,
                                  int64_t level, int64_t event_value) {
    const Definition &definition = _definitions[trigger_id];
    const uint64_t sequence = ++_state.fire_sequence[state_index];
    const uint64_t state_target = _state.target_handle[state_index];
    for (int32_t i = 0; i < definition.effect_count; ++i) {
        const EffectDefinition &source =
            _effect_definitions[definition.effect_begin + i];
        Effect effect;
        effect.id = _next_effect_id++;
        effect.effective_day = event.day + 1;
        effect.source_priority = source.source_priority;
        effect.trigger_id = trigger_id;
        effect.effect_definition_id = definition.effect_begin + i;
        effect.target_handle = resolve_effect_target(source, state_target, event);
        effect.target_generation = generation_from_handle(effect.target_handle);
        effect.fire_sequence = sequence;
        effect.action = source.action;
        effect.domain = source.domain;
        effect.opcode = source.opcode;
        effect.duration_days = source.duration_days;
        effect.stacks = source.stacks;
        effect.command_key = source.command_key;
        effect.definition_key = source.definition_key;
        effect.payload = source.payload;
        if (effect.action == ECONOMY_COMMAND &&
            (effect.opcode == EconomyApi::COMMAND_FAMILY_FREE_BUILDING ||
             effect.command_key == "family.free_building") &&
            event.payload[1] >= 0 && effect.payload[1] == 0)
            effect.payload[1] = event.payload[1];
        if (effect.action == COUNTRY_COMMAND &&
            effect.opcode == 14) { // NativeCountryRuntime::COMMAND_DISCOVER_COUNTRY_SIGNAL
            const uint64_t signal = static_cast<uint64_t>(effect.payload[0]) & 0xffffffffULL;
            const uint64_t cell = event.group_handle & 0xffffffffULL;
            effect.payload[0] = static_cast<int64_t>((signal << 32U) | cell);
        }
        for (const BranchBinding &binding : _branch_bindings) {
            if (binding.trigger_id == trigger_id &&
                binding.branch_handle == state_target) {
                effect.payload[0] = binding.reward_target;
                break;
            }
        }
        switch (source.value_mode) {
            case EFFECT_FIRE_COUNT: effect.resolved_value = fire_count; break;
            case EFFECT_LEVEL: effect.resolved_value = level; break;
            case EFFECT_ACCUMULATOR:
                effect.resolved_value = _state.accumulator[state_index]; break;
            case EFFECT_EVENT_VALUE: effect.resolved_value = event_value; break;
            default: effect.resolved_value = source.value; break;
        }
        if (source.value_mode == EFFECT_LEVEL && effect.stacks <= 0)
            effect.stacks = static_cast<int32_t>(std::max<int64_t>(0, level));
        _effects.push_back(std::move(effect));
        ++_effects_emitted;
    }
}

Dictionary TriggerRuntime::run_daily(int64_t day_index) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    if (day_index < _current_day) return failure("trigger_day_regression");
    const auto started = std::chrono::steady_clock::now();
    RuntimeTriggerPodCatalog catalog;
    RuntimeTriggerSnapshot snapshot;
    std::string kernel_error;
    if (!export_pod_catalog(catalog, kernel_error) ||
        !export_pod_snapshot(snapshot, kernel_error))
        return failure(kernel_error.empty() ? "trigger_pod_export_failed" : kernel_error.c_str());

    const RuntimeTriggerSnapshot previous_snapshot = snapshot;
    const size_t pending_before = snapshot.pending_events.size();
    std::vector<RuntimeTriggerEffectIntent> emitted;
    if (!RuntimeTriggerKernel::evaluate_day(catalog, snapshot, day_index,
                                            emitted, kernel_error))
        return failure(kernel_error.empty() ? "trigger_kernel_failed" : kernel_error.c_str());

    // The kernel retains only future events, so the difference is the exact
    // number consumed without maintaining a second event loop in the facade.
    const int64_t processed = static_cast<int64_t>(pending_before) -
        static_cast<int64_t>(snapshot.pending_events.size());
    // State snapshots are already keyed by (trigger,target).  Index the
    // previous snapshot once instead of scanning it twice for every state;
    // large catalogs otherwise turn trigger_evaluate into an O(n²) main-thread
    // slice even when only a few events are pending.
    struct StateKey {
        int32_t trigger_id;
        uint64_t target_handle;
        bool operator==(const StateKey &other) const {
            return trigger_id == other.trigger_id &&
                target_handle == other.target_handle;
        }
    };
    struct StateKeyHash {
        size_t operator()(const StateKey &key) const {
            const size_t h1 = std::hash<int32_t>{}(key.trigger_id);
            const size_t h2 = std::hash<uint64_t>{}(key.target_handle);
            return h1 ^ (h2 + static_cast<size_t>(0x9e3779b9U) +
                (h1 << 6U) + (h1 >> 2U));
        }
    };
    std::unordered_map<StateKey, uint64_t, StateKeyHash> previous_fire_sequence;
    previous_fire_sequence.reserve(previous_snapshot.states.size() * 2 + 1);
    for (const RuntimeTriggerPodSnapshotState &before : previous_snapshot.states)
        previous_fire_sequence[{before.trigger_id, before.target_handle}] =
            before.fire_sequence;
    int64_t fired = 0;
    for (const RuntimeTriggerPodSnapshotState &after : snapshot.states) {
        const auto it = previous_fire_sequence.find(
            StateKey{after.trigger_id, after.target_handle});
        if (it == previous_fire_sequence.end()) {
            fired += static_cast<int64_t>(after.fire_sequence);
        } else if (after.fire_sequence > it->second) {
            fired += static_cast<int64_t>(after.fire_sequence - it->second);
        }
    }

    // Replace only after the Godot-free kernel succeeds. This keeps the
    // facade transactional while preserving all PKTR v6 fields and strings.
    _effects_emitted += emitted.size();
    std::string adopt_error;
    if (!adopt_pod_state(snapshot, day_index, adopt_error))
        return failure(adopt_error.c_str());
    _last_evaluate_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    Dictionary out = report();
    out["ok"] = true;
    out["done"] = true;
    out["path"] = "TRIGGER_GRAPH";
    out["stage"] = "trigger_evaluate";
    out["day_index"] = day_index;
    out["events_processed"] = processed;
    out["firings"] = fired;
    out["effects_pending"] = static_cast<int64_t>(_effects.size());
    out["work_done"] = processed + fired;
    return out;
}
