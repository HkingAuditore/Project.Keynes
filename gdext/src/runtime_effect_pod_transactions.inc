bool RuntimeEffectPodAuthority::append_transaction(
        State &state, const RuntimeEffectPodInstance &instance, int64_t day,
        const std::vector<RuntimeEffectPodCommand> &commands,
        bool retirement,
        RuntimeEffectPodTransaction &transaction, std::string &error) {
    if (commands.empty()) return false;
    if (state.transactions.size() >= _transaction_capacity ||
        state.command_arena.size() + commands.size() > _command_capacity) {
        error = state.transactions.size() >= _transaction_capacity
            ? "effect_transaction_capacity_exhausted"
            : "effect_command_arena_exhausted";
        return false;
    }
    transaction = RuntimeEffectPodTransaction{};
    transaction.transaction_id = _next_transaction_id;
    transaction.source_instance_id = instance.instance_id;
    transaction.source_generation = instance.generation;
    transaction.effective_day = day;
    transaction.command_begin = static_cast<uint32_t>(state.command_arena.size());
    transaction.command_count = static_cast<uint32_t>(commands.size());
    transaction.status = RuntimeEffectPodTransactionStatus::PREFLIGHTED;
    transaction.fire_sequence = instance.fire_sequence + 1u;
    transaction.input_revision = instance.input_revision;
    transaction.transition_stack_count =
        retirement ? 0 : std::max(1, instance.stack_count);
    for (const auto &command : commands) {
        transaction.required_ack_mask |= adapter_ack_bit(command.action);
        state.command_arena.push_back(command);
    }
    transaction.plan_hash = calculate_plan_hash(transaction.source_instance_id,
        transaction.source_generation, transaction.effective_day,
        transaction.fire_sequence, commands);
    state.transactions.push_back(transaction);
    return true;
}

bool RuntimeEffectPodAuthority::append_retirement_transaction(
        State &state, const RuntimeEffectPodDefinition &definition,
        RuntimeEffectPodInstance &instance, int64_t day,
        std::vector<RuntimeEffectPodCommand> &commands,
        RuntimeEffectPodTransaction &transaction, std::string &error,
        bool retire_instance) {
    commands.clear();
    if (!build_retirement_commands(definition, instance, day, commands, error))
        return false;
    std::stable_sort(commands.begin(), commands.end(), command_less);
    if (!append_transaction(state, instance, day, commands, true, transaction,
                            error))
        return false;
    ++_next_transaction_id;
    instance.fire_sequence += 1u;
    instance.pending_transaction_id = transaction.transaction_id;
    instance.pending_idempotency_key = commands.front().idempotency_key;
    instance.last_evaluated_input_revision = instance.input_revision;
    instance.next_due_day = day + 1;
    if (retire_instance) instance.retire_requested = 1;
    return true;
}

void RuntimeEffectPodAuthority::append_transaction_intents(
        const State &state, const RuntimeEffectPodDefinition &definition,
        const RuntimeEffectPodInstance &instance,
        const RuntimeEffectPodTransaction &transaction,
        std::vector<RuntimeDomainIntent> &out_intents,
        uint64_t *plan_hash) const {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const size_t command_index =
            static_cast<size_t>(transaction.command_begin) + ordinal;
        if (command_index >= state.command_arena.size()) return;
        const auto &command = state.command_arena[command_index];
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.target_domain = adapter_domain(command.action);
        intent.opcode = static_cast<uint16_t>(command.opcode);
        intent.effect_action = static_cast<uint16_t>(command.action);
        intent.source_id = static_cast<uint64_t>(command.source_instance_id);
        intent.target_handle = command.target_handle;
        intent.target_generation = command.target_generation;
        intent.value = command.value;
        intent.reserved_effect_flags |= RUNTIME_DOMAIN_INTENT_HAS_EFFECT_VALUE;
        intent.effective_day = command.effective_day;
        intent.payload = command.payload;
        intent.request_id = static_cast<uint64_t>(transaction.transaction_id);
        intent.producer_id = static_cast<uint32_t>(RuntimeDomainId::EFFECT);
        intent.sequence = transaction.fire_sequence * 16u + ordinal;
        intent.idempotency_key = command.idempotency_key;
        intent.duration_days = command.duration_days;
        intent.stacks = command.stacks;
        intent.magnitude_q16 = effect_scaled_magnitude_q16(
            command.value, instance.magnitude_scale_q16);
        if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND &&
            intent.payload[1] == 0 && command.domain >= 0 &&
            command.domain < 4) {
            intent.payload[1] = command.domain;
        }
        if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND) {
            int32_t adapter = 0;
            if (command.command_definition_id <
                _catalog.command_native_adapters.size()) {
                adapter =
                    _catalog.command_native_adapters[
                        command.command_definition_id];
            }
            intent.reserved =
                adapter | ((definition.target_domain & 0xFF) << 8);
        }
        out_intents.push_back(intent);
        if (plan_hash != nullptr)
            *plan_hash = command_hash(*plan_hash, command);
    }
}

bool RuntimeEffectPodAuthority::schedule_application(
        State &state, const RuntimeEffectPodDefinition &definition,
        RuntimeEffectPodInstance &instance, int64_t day,
        std::vector<RuntimeEffectPodCommand> &commands,
        RuntimeEffectPodTransaction &transaction, std::string &error) {
    if (commands.empty()) return false;
    std::stable_sort(commands.begin(), commands.end(), command_less);
    if (!append_transaction(state, instance, day, commands, false, transaction,
                            error))
        return false;
    ++_next_transaction_id;
    instance.fire_sequence += 1u;
    instance.pending_transaction_id = transaction.transaction_id;
    instance.pending_idempotency_key = commands.front().idempotency_key;
    instance.last_evaluated_input_revision = instance.input_revision;
    instance.next_due_day = day + definition.cadence_days;
    int32_t applied_duration = definition.duration_days;
    if (!commands.empty() && commands.front().duration_days > 0)
        applied_duration = commands.front().duration_days;
    instance.expires_day =
        definition.lifecycle == RuntimeEffectPodLifecycle::DURATION
            ? day + applied_duration
            : -1;
    return true;
}

void RuntimeEffectPodAuthority::compact_acked_transactions(State &state) const {
    if (state.transactions.empty()) return;
    std::vector<RuntimeEffectPodTransaction> retained;
    retained.reserve(state.transactions.size());
    std::vector<RuntimeEffectPodCommand> compacted_commands;
    compacted_commands.reserve(state.command_arena.size());
    for (RuntimeEffectPodTransaction transaction : state.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            continue;
        const uint32_t begin =
            static_cast<uint32_t>(compacted_commands.size());
        for (uint32_t ordinal = 0; ordinal < transaction.command_count;
             ++ordinal) {
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= state.command_arena.size()) break;
            compacted_commands.push_back(state.command_arena[command_index]);
        }
        transaction.command_begin = begin;
        transaction.command_count = static_cast<uint32_t>(
            compacted_commands.size()) - begin;
        retained.push_back(std::move(transaction));
    }
    if (retained.size() == state.transactions.size()) return;
    state.transactions.swap(retained);
    state.command_arena.swap(compacted_commands);
}

uint64_t RuntimeEffectPodAuthority::command_hash(
        uint64_t hash, const RuntimeEffectPodCommand &command) noexcept {
    hash = mix_value(hash, command.action);
    hash = mix_value(hash, command.domain);
    hash = mix_value(hash, command.opcode);
    hash = mix_value(hash, command.source_instance_id);
    hash = mix_value(hash, command.source_generation);
    hash = mix_value(hash, command.source_handle);
    hash = mix_value(hash, command.target_handle);
    hash = mix_value(hash, command.target_generation);
    hash = mix_value(hash, command.value);
    hash = mix_value(hash, command.duration_days);
    hash = mix_value(hash, command.stacks);
    hash = mix_value(hash, command.command_definition_id);
    hash = mix_value(hash, command.command_key_hash);
    hash = mix_value(hash, command.definition_key_hash);
    hash = mix_value(hash, command.idempotency_key);
    hash = mix_value(hash, command.effective_day);
    for (const int64_t value : command.payload) hash = mix_value(hash, value);
    return hash;
}

uint64_t RuntimeEffectPodAuthority::calculate_plan_hash(int64_t source_id,
        uint32_t generation, int64_t day, uint64_t fire_sequence,
        const std::vector<RuntimeEffectPodCommand> &commands) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, source_id);
    hash = mix_value(hash, generation);
    hash = mix_value(hash, day);
    hash = mix_value(hash, fire_sequence);
    for (const auto &command : commands) hash = command_hash(hash, command);
    return hash;
}

uint64_t RuntimeEffectPodAuthority::transaction_hash(
        uint64_t hash, const RuntimeEffectPodTransaction &transaction) noexcept {
    hash = mix_value(hash, transaction.transaction_id);
    hash = mix_value(hash, transaction.source_instance_id);
    hash = mix_value(hash, transaction.source_generation);
    hash = mix_value(hash, transaction.effective_day);
    hash = mix_value(hash, transaction.plan_hash);
    hash = mix_value(hash, transaction.command_begin);
    hash = mix_value(hash, transaction.command_count);
    hash = mix_value(hash, transaction.required_ack_mask);
    hash = mix_value(hash, transaction.received_ack_mask);
    hash = mix_value(hash, transaction.status);
    hash = mix_value(hash, transaction.retry_count);
    hash = mix_value(hash, transaction.duplicate_ack_count);
    hash = mix_value(hash, transaction.last_ack_code);
    hash = mix_value(hash, transaction.fire_sequence);
    hash = mix_value(hash, transaction.input_revision);
    hash = mix_value(hash, transaction.transition_stack_count);
    return hash;
}

uint64_t RuntimeEffectPodAuthority::state_hash(const State &state) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, state.generation);
    hash = mix_value(hash, state.committed_day);
    for (const int64_t value : state.metric_values) hash = mix_value(hash, value);
    for (const int64_t value : state.metric_revisions) hash = mix_value(hash, value);
    for (const auto &instance : state.instances) {
        hash = mix_value(hash, instance.instance_id);
        hash = mix_value(hash, instance.generation);
        hash = mix_value(hash, instance.program_id);
        hash = mix_value(hash, instance.source_type);
        hash = mix_value(hash, instance.source_id);
        hash = mix_value(hash, instance.source_handle);
        hash = mix_value(hash, instance.target_handle);
        hash = mix_value(hash, instance.target_generation);
        hash = mix_value(hash, instance.level);
        hash = mix_value(hash, instance.magnitude_scale_q16);
        hash = mix_value(hash, instance.latched);
        hash = mix_value(hash, instance.metric_base);
        hash = mix_value(hash, instance.input_revision);
        hash = mix_value(hash, instance.last_evaluated_input_revision);
        hash = mix_value(hash, instance.next_due_day);
        hash = mix_value(hash, instance.cadence_days);
        hash = mix_value(hash, instance.lifecycle);
        hash = mix_value(hash, instance.stack_policy);
        hash = mix_value(hash, instance.stack_count);
        hash = mix_value(hash, instance.applied_stack_count);
        hash = mix_value(hash, instance.effect_applied);
        hash = mix_value(hash, instance.applied_input_revision);
        hash = mix_value(hash, instance.max_stacks);
        hash = mix_value(hash, instance.expires_day);
        hash = mix_value(hash, instance.stack_key_hash);
        hash = mix_value(hash, instance.fire_sequence);
        hash = mix_value(hash, instance.pending_transaction_id);
        hash = mix_value(hash, instance.pending_idempotency_key);
        hash = mix_value(hash, instance.last_acked_fire_sequence);
        hash = mix_value(hash, instance.active);
        hash = mix_value(hash, instance.retire_requested);
        hash = mix_value(hash, instance.needs_resync);
    }
    for (const auto &command : state.command_arena) hash = command_hash(hash, command);
    for (const auto &transaction : state.transactions)
        hash = transaction_hash(hash, transaction);
    return hash;
}

bool RuntimeEffectPodAuthority::command_less(
        const RuntimeEffectPodCommand &a,
        const RuntimeEffectPodCommand &b) noexcept {
    if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
    if (a.source_instance_id != b.source_instance_id)
        return a.source_instance_id < b.source_instance_id;
    if (a.idempotency_key != b.idempotency_key)
        return a.idempotency_key < b.idempotency_key;
    if (a.action != b.action) return static_cast<uint8_t>(a.action) < static_cast<uint8_t>(b.action);
    if (a.domain != b.domain) return a.domain < b.domain;
    return a.opcode < b.opcode;
}

bool RuntimeEffectPodAuthority::ack_matches(
        const RuntimeDomainAck &ack,
        const RuntimeEffectPodCommand &command) noexcept {
    const uint16_t expected_domain = adapter_domain(command.action);
    if (ack.domain != expected_domain && ack.domain != static_cast<uint16_t>(
            std::max(0, command.domain))) return false;
    if (ack.effective_day != command.effective_day) return false;
    if (ack.target_handle != 0 && ack.target_handle != command.target_handle) return false;
    if (ack.target_generation != 0 && ack.target_generation != command.target_generation)
        return false;
    return true;
}

bool RuntimeEffectPodAuthority::finite_or_zero(int64_t) noexcept {
    return true;
}

void RuntimeEffectPodAuthority::build_snapshot(const State &state,
                                               RuntimeEffectPodSnapshot &out) const {
    out = RuntimeEffectPodSnapshot{};
    out.abi_version = RUNTIME_EFFECT_POD_ABI_VERSION;
    out.catalog_version = RUNTIME_EFFECT_POD_CATALOG_VERSION;
    out.catalog_hash = _catalog.catalog_hash;
    out.catalog_revision = _catalog_revision;
    out.generation = state.generation;
    out.deterministic_state_hash = state.deterministic_state_hash;
    out.committed_day = state.committed_day;
    out.metric_values = state.metric_values;
    out.metric_revisions = state.metric_revisions;
    out.instances = state.instances;
    out.command_arena = state.command_arena;
    out.transactions = state.transactions;
}

void RuntimeEffectPodAuthority::rebuild_report(const RuntimeEffectPodPlan *plan) {
    _report = RuntimeEffectPodReport{};
    _report.catalog_hash = _catalog.catalog_hash;
    _report.generation = _current.generation;
    _report.deterministic_state_hash = _current.deterministic_state_hash;
    _report.committed_day = _current.committed_day;
    _report.instance_count = static_cast<uint32_t>(_current.instances.size());
    _report.transaction_count = static_cast<uint32_t>(_current.transactions.size());
    _report.configured = _configured ? 1 : 0;
    _report.plan_ready = _plan_ready ? 1 : 0;
    for (const auto &transaction : _current.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            ++_report.acked_transaction_count;
        else if (transaction.status == RuntimeEffectPodTransactionStatus::REJECTED)
            ++_report.rejected_transaction_count;
        else if (transaction.status == RuntimeEffectPodTransactionStatus::RESYNC_REQUIRED)
            ++_report.resync_required_count;
        else
            ++_report.pending_transaction_count;
        _report.retry_count += transaction.retry_count;
        _report.duplicate_ack_count += transaction.duplicate_ack_count;
        _report.emitted_command_count += transaction.command_count;
    }
    if (plan != nullptr) {
        _report.deterministic_plan_hash = plan->deterministic_plan_hash;
        _report.emitted_command_count = plan->emitted_command_count;
        _report.plan_ready = 1;
    }
}
