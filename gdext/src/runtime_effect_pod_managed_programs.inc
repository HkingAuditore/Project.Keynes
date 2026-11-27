int64_t RuntimeEffectPodAuthority::state_value(
        const RuntimeEffectPodInstance &instance, int32_t state_id,
        int64_t day) noexcept {
    // Ids and scaling mirror EffectRuntime::state_value (effect_runtime.cpp:3840).
    // The Q16 factor is not cosmetic: authored content writes thresholds in Q16
    // ("level >= 2" is 131072), so returning a raw count here makes every such
    // condition permanently false on the worker while passing on the main thread.
    switch (state_id) {
        case 0:  // STATE_LEVEL
            return static_cast<int64_t>(instance.level) * Q16_ONE;
        case 1:  // STATE_FIRE_SEQUENCE
            return static_cast<int64_t>(instance.fire_sequence) * Q16_ONE;
        case 2:  // STATE_INPUT_REVISION - deliberately raw, it is a token.
            return instance.input_revision;
        case 3: {  // STATE_REMAINING_DAYS
            if (instance.expires_day < 0) return 0;
            const int64_t remaining =
                std::max<int64_t>(0, instance.expires_day - day);
            if (remaining > std::numeric_limits<int64_t>::max() / Q16_ONE)
                return std::numeric_limits<int64_t>::max();
            return remaining * Q16_ONE;
        }
        case 4:  // STATE_STACK_COUNT
            return static_cast<int64_t>(std::max(0, instance.stack_count)) * Q16_ONE;
        case 5:  // STATE_LATCHED - 0 or Q16_ONE, same as the main thread.
            return instance.latched != 0 ? Q16_ONE : 0;
        default:
            return 0;
    }
}

int32_t RuntimeEffectPodAuthority::scaled_command_stacks(
        int32_t base_stacks, int32_t stack_count, int32_t max_stacks) noexcept {
    // Shared with EffectRuntime so a stacked instance emits the same weight on
    // both threads. Shape mirrors the original main-thread formula:
    // base * max(1, depth), clamped to the program's max_stacks.
    return static_cast<int32_t>(std::min<int64_t>(
        std::max(1, max_stacks),
        static_cast<int64_t>(base_stacks) *
            static_cast<int64_t>(std::max(1, stack_count))));
}

bool RuntimeEffectPodAuthority::evaluate_conditions(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state,
        int64_t day) const {
    if (definition.condition_count == 0) return true;
    std::array<uint8_t, 256> stack{};
    uint32_t depth = 0;
    const auto metric = [&](int32_t id) -> int64_t {
        const size_t offset = static_cast<size_t>(instance.metric_base) +
            static_cast<size_t>(id);
        return offset < state.metric_values.size() ? state.metric_values[offset] : 0;
    };
    const auto read_state = [&](int32_t id) -> int64_t {
        return RuntimeEffectPodAuthority::state_value(instance, id, day);
    };
    for (uint32_t i = 0; i < definition.condition_count; ++i) {
        const auto &condition = _catalog.conditions[definition.condition_begin + i];
        switch (condition.op) {
            case RuntimeEffectPodConditionOp::CONDITION_TRUE:
                if (depth >= stack.size()) return false;
                stack[depth++] = 1;
                break;
            case RuntimeEffectPodConditionOp::METRIC_GTE:
            case RuntimeEffectPodConditionOp::METRIC_LTE:
            case RuntimeEffectPodConditionOp::METRIC_EQ: {
                if (depth >= stack.size()) return false;
                const int64_t actual = metric(condition.arg0);
                stack[depth++] = condition.op == RuntimeEffectPodConditionOp::METRIC_GTE
                    ? actual >= condition.value
                    : condition.op == RuntimeEffectPodConditionOp::METRIC_LTE
                        ? actual <= condition.value : actual == condition.value;
                break;
            }
            case RuntimeEffectPodConditionOp::STATE_GTE:
                if (depth >= stack.size()) return false;
                stack[depth++] = read_state(condition.arg0) >= condition.value;
                break;
            case RuntimeEffectPodConditionOp::BOOL_AND:
            case RuntimeEffectPodConditionOp::BOOL_OR:
                if (depth < 2) return false;
                --depth;
                stack[depth - 1u] = condition.op == RuntimeEffectPodConditionOp::BOOL_AND
                    ? (stack[depth - 1u] && stack[depth])
                    : (stack[depth - 1u] || stack[depth]);
                break;
            case RuntimeEffectPodConditionOp::BOOL_NOT:
                if (depth < 1) return false;
                stack[depth - 1u] = stack[depth - 1u] == 0;
                break;
        }
    }
    return depth == 1 && stack[0] != 0;
}

RuntimeEffectPodAuthority::ManagedLifecycleDecision
RuntimeEffectPodAuthority::evaluate_managed_lifecycle(
        const RuntimeEffectPodDefinition &definition,
        RuntimeEffectPodInstance &instance, const State &state,
        int64_t day) const {
    const bool condition_passed =
        evaluate_conditions(definition, instance, state, day);
    // Latch the raw result before any stack arbitration, exactly like the main
    // thread. A hysteresis band describes the metric, not the outcome of this
    // tick's stack fight.
    instance.latched = condition_passed ? 1 : 0;
    if (definition.managed == 0)
        return condition_passed ? ManagedLifecycleDecision::FIRE
                                : ManagedLifecycleDecision::IDLE;
    if (!condition_passed)
        return instance.effect_applied != 0
            ? ManagedLifecycleDecision::RETIRE
            : ManagedLifecycleDecision::IDLE;
    if (instance.needs_resync == 0 && instance.effect_applied != 0 &&
        instance.input_revision <= instance.applied_input_revision &&
        instance.applied_stack_count == std::max(1, instance.stack_count)) {
        return ManagedLifecycleDecision::IDLE;
    }
    return ManagedLifecycleDecision::FIRE;
}

bool RuntimeEffectPodAuthority::compile_command(
        const RuntimeEffectPodCommandDefinition &definition,
        const RuntimeEffectPodInstance &instance, int64_t value, int64_t day,
        uint64_t fire_sequence, uint32_t command_index,
        RuntimeEffectPodCommand &out) const {
    out = RuntimeEffectPodCommand{};
    out.action = definition.action;
    out.domain = definition.domain;
    out.opcode = definition.opcode;
    out.source_instance_id = static_cast<uint64_t>(instance.instance_id);
    out.source_generation = instance.generation;
    out.source_handle = instance.source_handle;
    out.target_handle = definition.target_resolver == RuntimeEffectPodTargetResolver::STATIC
        ? definition.static_target
        : definition.target_resolver == RuntimeEffectPodTargetResolver::SOURCE
            ? instance.source_handle : instance.target_handle;
    out.target_generation = instance.target_generation;
    out.value = definition.value_mode == RuntimeEffectPodValueMode::CONSTANT
        ? definition.value : value;
    out.duration_days = definition.duration_days;
    if (instance.program_id >= 0 &&
        instance.program_id < static_cast<int32_t>(_catalog.definitions.size())) {
        const uint64_t program_hash =
            _catalog.definitions[static_cast<size_t>(instance.program_id)].key_hash;
        if (program_hash == hash_text("family.effect.ancestral_precept")) {
            static constexpr int32_t kAncestralDurations[6] = {
                180, 180, 240, 300, 365, 540
            };
            out.duration_days = kAncestralDurations[std::clamp(instance.level, 0, 5)];
        } else if (program_hash == hash_text("family.effect.shared_water")) {
            static constexpr int32_t kSharedWaterDurations[6] = {
                1, 1, 1, 2, 2, 3
            };
            out.duration_days = kSharedWaterDurations[std::clamp(instance.level, 0, 5)];
        }
    }
    // Depth multiplies the command exactly like the main thread. instance
    // .max_stacks is seeded from the program definition at :555, so it is the
    // same ceiling the main thread uses.
    out.stacks = scaled_command_stacks(
        definition.stacks, instance.stack_count, instance.max_stacks);
    out.command_definition_id = static_cast<uint32_t>(
        &definition - _catalog.commands.data());
    out.command_key_hash = definition.command_key_hash;
    out.definition_key_hash = definition.definition_key_hash;
    out.effective_day = day;
    out.payload = definition.payload;
    uint64_t key = FNV_OFFSET;
    key = mix_value(key, instance.instance_id);
    key = mix_value(key, instance.generation);
    key = mix_value(key, fire_sequence);
    key = mix_value(key, command_index);
    key = mix_value(key, out.action);
    key = mix_value(key, out.domain);
    key = mix_value(key, out.opcode);
    out.idempotency_key = key;
    const int32_t program = instance.program_id;
    const InstanceZeroPolicy policy =
        program >= 0 &&
        program < static_cast<int32_t>(_catalog.definitions.size())
        ? instance_zero_policy(
              _catalog.definitions[static_cast<size_t>(program)].target_domain)
        : InstanceZeroPolicy{};
    // target_generation is copied from the instance whatever the resolver is, so
    // a policy-exempt zero survives; an unexempt zero still means "unset".
    if (out.target_generation == 0 && !policy.generation_allowed) return false;
    if (out.target_handle != 0) return true;
    // A zero handle is real only when the command resolves to the instance's own
    // target. A STATIC 0 or a SOURCE 0 carries no cell index. Returning false
    // here is not a dropped command: execute_program turns it into
    // effect_command_target_invalid and fails the whole transaction, so a cell-0
    // family effect used to make the Effect stage fail every single day.
    return policy.handle_allowed &&
        definition.target_resolver == RuntimeEffectPodTargetResolver::INSTANCE;
}

bool RuntimeEffectPodAuthority::invoke_behavior(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state,
        int64_t day, std::vector<RuntimeEffectPodCommand> &commands,
        std::string &error) const {
    if (definition.behavior_id_hash == 0) return true;
    const RuntimeEffectPodBehaviorMetadata *metadata = nullptr;
    for (const auto &candidate : _catalog.behaviors) {
        if (candidate.behavior_id_hash == definition.behavior_id_hash) {
            metadata = &candidate;
            break;
        }
    }
    if (metadata == nullptr || metadata->implemented == 0 ||
        metadata->thread_safe == 0) {
        error = "effect_behavior_not_registered";
        return false;
    }
    std::array<RuntimeEffectPodBehaviorCommand, RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT> buffer{};
    RuntimeEffectPodBehaviorOutput output;
    output.commands = buffer.data();
    output.capacity = std::min<uint32_t>(metadata->max_output,
                                         RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT);
    const size_t metric_count = _catalog.metric_key_hashes.size();
    const int64_t *metrics = instance.metric_base < state.metric_values.size()
        ? state.metric_values.data() + instance.metric_base : nullptr;
    RuntimeEffectPodBehaviorInput input;
    input.instance_id = instance.instance_id;
    input.instance_generation = instance.generation;
    input.level = instance.level;
    input.day = day;
    input.source_handle = instance.source_handle;
    input.target_handle = instance.target_handle;
    input.metrics = metrics;
    input.metric_count = static_cast<uint32_t>(metric_count);
    bool invoked = false;
    if (metadata->function != nullptr) {
        invoked = metadata->function(input, output, error);
    } else if (RuntimeEffectPodBehaviorResolver resolver =
                   runtime_effect_pod_behavior_resolver()) {
        invoked = resolver(definition.behavior_id_hash, input, output, error);
    } else {
        error = "effect_behavior_not_registered";
        return false;
    }
    if (!invoked || output.overflowed) {
        if (error.empty()) error = output.overflowed
            ? "effect_behavior_output_capacity_exceeded" : "effect_behavior_failed";
        return false;
    }
    for (uint32_t i = 0; i < output.count; ++i) {
        const auto &behavior_command = output.commands[i];
        RuntimeEffectPodCommand command;
        command.action = behavior_command.action;
        command.domain = behavior_command.domain;
        command.opcode = behavior_command.opcode;
        command.source_instance_id = static_cast<uint64_t>(instance.instance_id);
        command.source_generation = instance.generation;
        command.source_handle = instance.source_handle;
        command.target_handle = behavior_command.target_handle == 0
            ? instance.target_handle : behavior_command.target_handle;
        command.target_generation = behavior_command.target_generation == 0
            ? instance.target_generation : behavior_command.target_generation;
        command.value = behavior_command.value;
        command.duration_days = behavior_command.duration_days;
        command.stacks = behavior_command.stacks;
        command.effective_day = day;
        command.payload = behavior_command.payload;
        command.idempotency_key = FNV_OFFSET;
        command.idempotency_key = mix_value(command.idempotency_key,
                                            instance.instance_id);
        command.idempotency_key = mix_value(command.idempotency_key,
                                            instance.generation);
        command.idempotency_key = mix_value(command.idempotency_key,
                                            instance.fire_sequence + 1u);
        command.idempotency_key = mix_value(command.idempotency_key, i);
        commands.push_back(command);
    }
    return true;
}

bool RuntimeEffectPodAuthority::build_retirement_commands(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, int64_t day,
        std::vector<RuntimeEffectPodCommand> &commands,
        std::string &error) const {
    commands.clear();
    error.clear();
    uint32_t command_position = 0;
    for (uint32_t i = 0; i < definition.command_count; ++i) {
        const uint32_t command_index = definition.command_begin + i;
        if (command_index >= _catalog.commands.size()) {
            error = "effect_pod_retirement_command_missing";
            return false;
        }
        const auto &apply = _catalog.commands[command_index];
        if (apply.action != RuntimeEffectPodAction::MODIFIER_COMMAND ||
            apply.opcode != 1) {
            ++command_position;
            continue;
        }
        RuntimeEffectPodCommand command;
        if (!compile_command(apply, instance, 0, day,
                             instance.fire_sequence + 1u, command_position++,
                             command)) {
            error = "effect_command_target_invalid";
            return false;
        }
        command.opcode = 2;
        command.value = 0;
        command.duration_days = -1;
        command.stacks = 1;
        if (apply.target_resolver == RuntimeEffectPodTargetResolver::SOURCE) {
            command.target_generation = instance.generation;
        }
        // Mirror EffectRuntime::create_retirement_transaction(): the REMOVE
        // names the same reversible command definition but is not the APPLY
        // key, so it cannot collide with the row it removes.
        uint64_t key = FNV_OFFSET;
        key = mix_value(key, instance.instance_id);
        key = mix_value(key, instance.generation);
        key = mix_value(key, instance.fire_sequence + 1u);
        key = mix_value(key, command_index);
        key = mix_value(key, static_cast<uint8_t>(
            RuntimeEffectPodAction::MODIFIER_COMMAND));
        key = mix_value(key, command.domain);
        key = mix_value(key, command.opcode);
        key = mix_value(key, 1u);
        command.idempotency_key = key;
        commands.push_back(command);
    }
    if (commands.empty()) {
        error = "effect_retire_reversible_command_missing";
        return false;
    }
    return true;
}

bool RuntimeEffectPodAuthority::execute_program(
        const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance, const State &state,
        int64_t day, std::vector<RuntimeEffectPodCommand> &commands,
        std::string &error) const {
    error.clear();
    if (!invoke_behavior(definition, instance, state, day, commands, error)) return false;
    if (definition.instruction_count == 0) return true;
    std::array<int64_t, 256> stack{};
    uint32_t depth = 0;
    const auto metric = [&](int32_t id) -> int64_t {
        const size_t offset = static_cast<size_t>(instance.metric_base) +
            static_cast<size_t>(id);
        return offset < state.metric_values.size() ? state.metric_values[offset] : 0;
    };
    const auto read_state = [&](int32_t id) -> int64_t {
        return RuntimeEffectPodAuthority::state_value(instance, id, day);
    };
    for (uint32_t i = 0; i < definition.instruction_count; ++i) {
        const auto &instruction = _catalog.instructions[definition.instruction_begin + i];
        switch (instruction.op) {
            case RuntimeEffectPodInstructionOp::CONST:
                if (depth >= stack.size()) { error = "effect_value_stack_overflow"; return false; }
                stack[depth++] = instruction.value;
                break;
            case RuntimeEffectPodInstructionOp::READ_METRIC:
                if (depth >= stack.size()) { error = "effect_value_stack_overflow"; return false; }
                stack[depth++] = metric(instruction.arg0);
                break;
            case RuntimeEffectPodInstructionOp::READ_STATE:
                if (depth >= stack.size()) { error = "effect_value_stack_overflow"; return false; }
                stack[depth++] = read_state(instruction.arg0);
                break;
            case RuntimeEffectPodInstructionOp::ADD:
            case RuntimeEffectPodInstructionOp::SUB:
            case RuntimeEffectPodInstructionOp::MUL_Q16:
            case RuntimeEffectPodInstructionOp::DIV_FLOOR:
            case RuntimeEffectPodInstructionOp::MIN:
            case RuntimeEffectPodInstructionOp::MAX: {
                if (depth < 2) { error = "effect_value_stack_underflow"; return false; }
                const int64_t rhs = stack[--depth];
                int64_t &lhs = stack[depth - 1u];
                if (instruction.op == RuntimeEffectPodInstructionOp::ADD) lhs += rhs;
                else if (instruction.op == RuntimeEffectPodInstructionOp::SUB) lhs -= rhs;
                else if (instruction.op == RuntimeEffectPodInstructionOp::MUL_Q16)
                    lhs = static_cast<int64_t>((static_cast<long double>(lhs) * rhs) / Q16_ONE);
                else if (instruction.op == RuntimeEffectPodInstructionOp::DIV_FLOOR)
                    lhs = rhs == 0 ? 0 : lhs / rhs;
                else if (instruction.op == RuntimeEffectPodInstructionOp::MIN) lhs = std::min(lhs, rhs);
                else lhs = std::max(lhs, rhs);
                break;
            }
            case RuntimeEffectPodInstructionOp::CLAMP:
                if (depth == 0) { error = "effect_value_stack_underflow"; return false; }
                stack[depth - 1u] = std::clamp(stack[depth - 1u],
                                               static_cast<int64_t>(instruction.arg0),
                                               instruction.value);
                break;
            case RuntimeEffectPodInstructionOp::EMIT_COMMAND: {
                if (instruction.arg0 < 0 ||
                    static_cast<uint32_t>(instruction.arg0) >= definition.command_count) {
                    error = "effect_command_index_invalid";
                    return false;
                }
                const auto &command_definition = _catalog.commands[
                    definition.command_begin + static_cast<uint32_t>(instruction.arg0)];
                int64_t value = 0;
                if (command_definition.value_mode == RuntimeEffectPodValueMode::STACK_TOP) {
                    if (depth == 0) { error = "effect_value_stack_underflow"; return false; }
                    value = stack[--depth];
                }
                RuntimeEffectPodCommand command;
                if (!compile_command(command_definition, instance, value, day,
                                     instance.fire_sequence + 1u,
                                     static_cast<uint32_t>(instruction.arg0), command)) {
                    error = "effect_command_target_invalid";
                    return false;
                }
                commands.push_back(command);
                break;
            }
            case RuntimeEffectPodInstructionOp::END:
                return true;
        }
        if (i >= static_cast<uint32_t>(definition.max_work)) {
            error = "effect_definition_work_exceeded";
            return false;
        }
    }
    return true;
}
