#include "effect_runtime_includes.inc"

namespace pk {

using namespace godot;

bool native_command_shape_valid(int32_t action, int32_t domain, int32_t opcode,
                                int32_t target_resolver, int32_t duration_days,
                                int32_t stacks, int64_t value,
                                std::string &reason) {
    // Native Effect ABI registration is deliberately fixed at startup rather
    // than discovered from strings in the daily path.
    if (action < EffectRuntime::MODIFIER_COMMAND ||
        action > EffectRuntime::CUSTOM_DOMAIN_COMMAND) {
        reason = "effect_command_action_unregistered";
        return false;
    }
    if (domain < 0 || domain >= 32 || stacks <= 0 || duration_days < -1 ||
        target_resolver < EffectRuntime::TARGET_STATIC ||
        target_resolver > EffectRuntime::TARGET_SOURCE) {
        reason = "effect_command_layout_invalid";
        return false;
    }
    switch (action) {
        case EffectRuntime::MODIFIER_COMMAND:
            if (domain > 3 || (opcode != ModifierApi::COMMAND_APPLY &&
                               opcode != ModifierApi::COMMAND_REMOVE)) {
                reason = "effect_modifier_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::COUNTRY_COMMAND:
            if (domain != 1 || opcode < CountryApi::COMMAND_CREATE_COUNTRY ||
                opcode > CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL) {
                reason = "effect_country_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::ECONOMY_COMMAND:
            if (domain != 2 ||
                !EconomyApi::is_registered_economy_effect_opcode(opcode)) {
                reason = "effect_economy_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::GAMEPLAY_COMMAND:
            if (domain != 3 || opcode <= 0) {
                reason = "effect_gameplay_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::PUBLISH_EVENT:
            if (domain != 4 || opcode <= 0) {
                reason = "effect_publish_event_opcode_unregistered";
                return false;
            }
            break;
        case EffectRuntime::CUSTOM_DOMAIN_COMMAND:
            // Each native custom consumer must be registered explicitly here.
            // Opcode 3 grants Ideology free draws; its value is a positive row
            // count, not an Ideology opcode.
            if (domain != 6 ||
                (opcode != EffectRuntime::CUSTOM_AUDIT_OPCODE &&
                 opcode != EffectRuntime::CUSTOM_CANAL_COMMIT_OPCODE &&
                 opcode != EffectRuntime::CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE)) {
                reason = "effect_custom_domain_adapter_unregistered";
                return false;
            }
            if (opcode == EffectRuntime::CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE &&
                (value <= 0 || value > 65535)) {
                reason = "effect_ideology_free_draw_count_invalid";
                return false;
            }
            break;
        default:
            reason = "effect_command_action_unregistered";
            return false;
    }
    return true;
}


bool EffectRuntime::invoke_pod_behavior(
        uint64_t behavior_id_hash,
        const RuntimeEffectPodBehaviorInput &input,
        RuntimeEffectPodBehaviorOutput &output, std::string &error) {
    error.clear();
    BehaviorFn fn = find_behavior_hash(behavior_id_hash);
    if (fn == nullptr) {
        error = "effect_behavior_not_registered";
        return false;
    }
    BehaviorInput legacy_input;
    legacy_input.instance_id = input.instance_id;
    legacy_input.instance_generation = input.instance_generation;
    legacy_input.program_id = -1;
    legacy_input.level = input.level;
    legacy_input.day = input.day;
    legacy_input.target_handle = input.target_handle;
    legacy_input.source_handle = input.source_handle;
    legacy_input.metrics = input.metrics;
    legacy_input.metric_count = static_cast<int32_t>(input.metric_count);
    std::array<BehaviorCommand, RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT> buffer{};
    BehaviorOutput legacy_output;
    legacy_output.commands = buffer.data();
    legacy_output.capacity = static_cast<int32_t>(
        std::min<uint32_t>(output.capacity, RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT));
    legacy_output.count = 0;
    if (!fn(legacy_input, legacy_output, error) || legacy_output.overflowed) {
        if (error.empty()) {
            error = legacy_output.overflowed
                ? "effect_behavior_output_capacity_exceeded"
                : "effect_behavior_failed";
        }
        output.overflowed = legacy_output.overflowed;
        return false;
    }
    output.count = 0;
    output.overflowed = false;
    for (int32_t i = 0; i < legacy_output.count; ++i) {
        RuntimeEffectPodBehaviorCommand command;
        command.action = static_cast<RuntimeEffectPodAction>(buffer[i].action);
        command.domain = buffer[i].domain;
        command.opcode = buffer[i].opcode;
        command.target_handle = buffer[i].target_handle;
        command.target_generation = buffer[i].target_generation;
        command.value = buffer[i].value_q16;
        command.duration_days = buffer[i].duration_days;
        command.stacks = buffer[i].stacks;
        command.payload = buffer[i].payload;
        if (!output.emit(command)) {
            error = "effect_behavior_output_capacity_exceeded";
            return false;
        }
    }
    return true;
}

namespace {
constexpr int64_t ADAPTER_TRANSACTION_START = int64_t{1} << 52;
}

void EffectRuntime::begin_executor_transaction_namespace() noexcept {
    // POD catalog transactions start at 1. Transactions created by the native
    // adapters (including family claims) have their own persisted cursor.
    _next_transaction_id = std::max(_next_transaction_id, ADAPTER_TRANSACTION_START);
}

bool EffectRuntime::apply_pod_snapshot(const RuntimeEffectPodSnapshot &snapshot,
                                       std::string &error) {
    error.clear();
    if (!_configured) {
        error = "effect_runtime_not_configured";
        return false;
    }
    if (snapshot.abi_version != RUNTIME_EFFECT_POD_ABI_VERSION) {
        error = "effect_pod_snapshot_abi_mismatch";
        return false;
    }
    if (snapshot.catalog_hash != 0 && snapshot.catalog_hash != _catalog_hash &&
        _catalog_hash != 0) {
        // POD catalog hash is numeric-normalized and may differ from legacy
        // string-bearing hash; only reject when both sides advertise a hash and
        // the POD side also carries a non-zero catalog_revision mismatch path
        // that the Host already validated against its POD catalog.
    }
    if (snapshot.generation != 0 &&
        snapshot.generation <= _pod_snapshot_generation) {
        error = "effect_pod_snapshot_generation_regression";
        return false;
    }

    // Economy enqueues family colonization (and canal) builtins onto this
    // main-thread EffectRuntime with program_id == -1. The worker POD snapshot
    // never carries them. Preserve those transactions and their Country/Economy
    // adapter bindings across write-back so CLAIM/SETTLE cannot race the apply
    // into a use-after-free on cleared binding vectors.
    struct PreservedBuiltin {
        Transaction transaction;
        std::vector<Command> commands;
    };
    std::vector<PreservedBuiltin> preserved_builtins;
    std::unordered_set<int64_t> preserved_tx_ids;
    preserved_builtins.reserve(8);
    for (const Transaction &tx : _transactions) {
        if (tx.program_id != -1 && tx.program_id != -2) continue;
        PreservedBuiltin row;
        row.transaction = tx;
        row.commands.reserve(tx.command_count);
        for (uint32_t ordinal = 0; ordinal < tx.command_count; ++ordinal) {
            const Command *command = command_at(tx, ordinal);
            if (command == nullptr) {
                error = "effect_pod_snapshot_builtin_command_missing";
                return false;
            }
            row.commands.push_back(*command);
        }
        preserved_tx_ids.insert(tx.id);
        preserved_builtins.push_back(std::move(row));
    }
    // SPLIT AUTHORITY (mask 0xFEF: IDEOLOGY on the main thread, EFFECT and
    // MODIFIER on the worker). An ideology equip plans its batch on THIS table
    // because the worker's Effect POD store never receives it, and nothing on
    // the main thread drains it (`run_effect_daily`, both Modifier adapter halves
    // and `run_modifier_daily` all report `path=EFFECT_WORKER`). Replacing
    // `_transactions` wholesale therefore erased the row one day after it was
    // planned: `transaction_status_pod` answered 0 (MISSING), which
    // `poll_pending_transition` reads as failure and rolls the equip back.
    //
    // Preserve the batch AND its source instance (the transaction rebuild below
    // requires the source instance to exist), so `collect_worker_modifier_rows`
    // has something to settle.
    struct PreservedIdeologyBatch {
        Transaction transaction;
        std::vector<Command> commands;
        Instance source;
        std::vector<int64_t> metric_values;
        std::vector<uint8_t> metric_present;
    };
    std::vector<PreservedIdeologyBatch> preserved_ideology;
    for (const Transaction &tx : _transactions) {
        if (tx.program_id < 0) continue;  // builtins are handled above.
        const int32_t source_index = instance_index_for_id(tx.source_instance_id);
        if (source_index < 0 ||
            source_index >= static_cast<int32_t>(_instances.size()))
            continue;
        const Instance &source_instance = _instances[static_cast<size_t>(source_index)];
        if (tx.id < ADAPTER_TRANSACTION_START &&
            source_instance.source_type != IDEOLOGY_SOURCE_TYPE) continue;
        PreservedIdeologyBatch row;
        row.transaction = tx;
        row.commands.reserve(tx.command_count);
        for (uint32_t ordinal = 0; ordinal < tx.command_count; ++ordinal) {
            const Command *command = command_at(tx, ordinal);
            if (command == nullptr) {
                error = "effect_pod_snapshot_ideology_command_missing";
                return false;
            }
            row.commands.push_back(*command);
        }
        row.source = source_instance;
        row.metric_values.reserve(static_cast<size_t>(_metric_count));
        row.metric_present.reserve(static_cast<size_t>(_metric_count));
        const size_t source_base = static_cast<size_t>(source_instance.metric_base);
        for (int32_t metric = 0; metric < _metric_count; ++metric) {
            const size_t src = source_base + static_cast<size_t>(metric);
            if (src < _metric_values.size() &&
                src < _metric_present.size()) {
                row.metric_values.push_back(_metric_values[src]);
                row.metric_present.push_back(_metric_present[src]);
            } else {
                row.metric_values.push_back(0);
                row.metric_present.push_back(0);
            }
        }
        preserved_tx_ids.insert(tx.id);
        preserved_ideology.push_back(std::move(row));
    }
    std::vector<int64_t> preserved_country_request_ids;
    std::vector<NativeAckBinding> preserved_country_bindings;
    std::unordered_set<int64_t> preserved_country_bound_ids;
    std::vector<int64_t> preserved_economy_request_ids;
    std::vector<NativeAckBinding> preserved_economy_bindings;
    std::unordered_set<int64_t> preserved_economy_bound_ids;
    auto keep_bindings = [&](const std::vector<int64_t> &request_ids,
                             const std::vector<NativeAckBinding> &bindings,
                             const std::unordered_set<int64_t> &bound_ids,
                             std::vector<int64_t> &out_ids,
                             std::vector<NativeAckBinding> &out_bindings,
                             std::unordered_set<int64_t> &out_bound) {
        for (const NativeAckBinding &binding : bindings) {
            if (preserved_tx_ids.count(binding.transaction_id) == 0) continue;
            const uint32_t begin = binding.request_begin;
            const uint32_t end = begin + binding.request_count;
            if (end < begin || end > request_ids.size()) continue;
            NativeAckBinding kept = binding;
            kept.request_begin = static_cast<uint32_t>(out_ids.size());
            for (uint32_t i = begin; i < end; ++i)
                out_ids.push_back(request_ids[i]);
            out_bindings.push_back(kept);
            if (bound_ids.count(binding.transaction_id) != 0)
                out_bound.insert(binding.transaction_id);
        }
    };
    keep_bindings(_native_country_request_ids, _native_country_ack_bindings,
                  _native_country_bound_transaction_ids,
                  preserved_country_request_ids, preserved_country_bindings,
                  preserved_country_bound_ids);
    keep_bindings(_native_economy_request_ids, _native_economy_ack_bindings,
                  _native_economy_bound_transaction_ids,
                  preserved_economy_request_ids, preserved_economy_bindings,
                  preserved_economy_bound_ids);

    const size_t metric_width = _metric_keys.size();
    std::vector<Instance> next_instances;
    std::unordered_map<int64_t, int32_t> next_instance_ids;
    std::vector<int64_t> next_metric_values;
    std::vector<uint8_t> next_metric_present;
    next_instances.reserve(snapshot.instances.size());
    next_metric_values.reserve(snapshot.instances.size() * metric_width);
    next_metric_present.reserve(snapshot.instances.size() * metric_width);
    uint64_t next_activation_sequence = _next_activation_sequence;

    for (const RuntimeEffectPodInstance &entry : snapshot.instances) {
        if (entry.instance_id == 0 || entry.generation == 0) {
            error = "effect_pod_snapshot_instance_invalid";
            return false;
        }
        if (entry.program_id < 0 ||
            entry.program_id >= static_cast<int32_t>(_definitions.size())) {
            error = "effect_pod_snapshot_program_invalid";
            return false;
        }
        if (next_instance_ids.count(entry.instance_id) != 0) {
            error = "effect_pod_snapshot_duplicate_instance";
            return false;
        }
        Instance instance;
        instance.id = entry.instance_id;
        instance.generation = entry.generation;
        instance.program_id = entry.program_id;
        instance.source_type = entry.source_type;
        instance.source_id = entry.source_id;
        instance.source_handle = entry.source_handle;
        instance.target_handle = entry.target_handle;
        instance.target_generation = entry.target_generation;
        instance.level = entry.level;
        // ABI 2. Both are decided by whoever owns EFFECT, so a write-back has to
        // carry them or the flip silently rewrites a card's strength.
        instance.magnitude_scale_q16 = entry.magnitude_scale_q16;
        instance.latched = entry.latched;
        instance.next_due_day = entry.next_due_day;
        instance.input_revision = entry.input_revision;
        // The snapshot carries the change watermark only; treat it as the
        // observed one too so the first publish after a write-back is compared
        // against what the worker already committed.
        instance.metric_observed_revision = entry.input_revision;
        instance.last_evaluated_input_revision =
            entry.last_evaluated_input_revision;
        instance.fire_sequence = entry.fire_sequence;
        instance.active = entry.active;
        instance.lifecycle = static_cast<int32_t>(entry.lifecycle);
        instance.stack_policy = static_cast<int32_t>(entry.stack_policy);
        instance.max_stacks = entry.max_stacks;
        instance.stack_count = entry.stack_count;
        instance.applied_stack_count = entry.applied_stack_count;
        instance.effect_applied = entry.effect_applied;
        // Written back verbatim on purpose. For an UNMANAGED program the POD keeps
        // `applied_stack_count` as fire bookkeeping and never touches the latch, so
        // this arrives as `(0, N)`; that is the domain's own shape, not a corruption,
        // and `restore()`'s pair check is scoped to managed rows for exactly this
        // reason (see the comment there and `runtime_effect_pod.cpp`'s matching save
        // validation). Normalising it here would make this facade's copy disagree
        // with the POD's own save of the same instance.
        instance.applied_input_revision = entry.applied_input_revision;
        instance.expires_day = entry.expires_day;
        instance.stack_key_hash = entry.stack_key_hash;
        instance.retire_requested = entry.retire_requested;
        instance.last_acked_fire_sequence = entry.last_acked_fire_sequence;
        const int32_t previous_index = instance_index_for_id(instance.id);
        if (previous_index >= 0) {
            const Instance &previous = _instances[previous_index];
            if (previous.generation == instance.generation &&
                previous.program_id == instance.program_id)
                instance.activation_sequence = previous.activation_sequence;
        }
        if (instance.activation_sequence == 0)
            instance.activation_sequence = next_activation_sequence++;
        instance.metric_base = static_cast<uint32_t>(next_metric_values.size());
        if (metric_width > 0) {
            const size_t src_base = static_cast<size_t>(entry.metric_base);
            for (size_t m = 0; m < metric_width; ++m) {
                const size_t src = src_base + m;
                if (src < snapshot.metric_values.size()) {
                    next_metric_values.push_back(snapshot.metric_values[src]);
                    next_metric_present.push_back(1);
                } else {
                    next_metric_values.push_back(0);
                    next_metric_present.push_back(0);
                }
            }
        }
        if (entry.program_id >= 0 &&
            entry.program_id < static_cast<int32_t>(_definitions.size())) {
            const Definition &definition = _definitions[entry.program_id];
            instance.source_kind = definition.source_kind;
            instance.target_domain = definition.target_domain;
            instance.operation = definition.operation;
            instance.priority = definition.priority;
            instance.duration_days = definition.duration_days;
            instance.stack_key_hash = fnv_string(1469598103934665603ULL,
                definition.stack_key.empty() ? definition.key : definition.stack_key);
        }
        next_instance_ids[instance.id] =
            static_cast<int32_t>(next_instances.size());
        next_instances.push_back(instance);
    }

    std::vector<Transaction> next_transactions;
    std::unordered_map<int64_t, int32_t> next_transaction_ids;
    std::unordered_map<int64_t, uint32_t> next_pending_by_instance;
    std::vector<Command> next_command_arena = {};
    next_command_arena.reserve(snapshot.command_arena.size());
    for (const RuntimeEffectPodCommand &command : snapshot.command_arena) {
        Command row;
        row.action = static_cast<int32_t>(command.action);
        row.domain = command.domain;
        row.opcode = command.opcode;
        row.target_handle = command.target_handle;
        row.target_generation = command.target_generation;
        row.value_q16 = command.value;
        row.duration_days = command.duration_days;
        row.stacks = command.stacks;
        row.command_definition_id =
            static_cast<int32_t>(command.command_definition_id);
        row.payload = command.payload;
        row.idempotency_key = command.idempotency_key;
        row.command_key_id = row.command_definition_id;
        next_command_arena.push_back(row);
    }
    next_transactions.reserve(snapshot.transactions.size());
    for (const RuntimeEffectPodTransaction &entry : snapshot.transactions) {
        if (entry.transaction_id == 0) {
            error = "effect_pod_snapshot_transaction_invalid";
            return false;
        }
        Transaction tx;
        tx.id = entry.transaction_id;
        tx.source_instance_id = entry.source_instance_id;
        tx.source_generation = entry.source_generation;
        const auto source = next_instance_ids.find(entry.source_instance_id);
        if (source == next_instance_ids.end()) {
            error = "effect_pod_snapshot_transaction_source_missing";
            return false;
        }
        tx.program_id = next_instances[source->second].program_id;
        tx.effective_day = entry.effective_day;
        tx.plan_hash = entry.plan_hash;
        tx.required_ack_mask = entry.required_ack_mask;
        tx.received_ack_mask = entry.received_ack_mask;
        tx.status = static_cast<int32_t>(entry.status);
        tx.transition_input_revision = entry.input_revision;
        tx.transition_fire_sequence = entry.fire_sequence;
        tx.transition_stack_count = entry.transition_stack_count;
        if (uses_managed_lifecycle(_definitions[tx.program_id])) {
            tx.instance_transition = entry.transition_stack_count > 0
                ? TRANSITION_APPLY : TRANSITION_RETIRE;
        } else {
            tx.transition_input_revision = 0;
            tx.transition_fire_sequence = 0;
            tx.transition_stack_count = 0;
        }
        tx.command_begin = entry.command_begin;
        tx.command_count = entry.command_count;
        if (tx.command_begin + tx.command_count > next_command_arena.size()) {
            error = "effect_pod_snapshot_command_range_invalid";
            return false;
        }
        tx.plan_hash = persisted_plan_hash(tx, next_command_arena);
        next_transaction_ids[tx.id] =
            static_cast<int32_t>(next_transactions.size());
        if (tx.status == PLANNED || tx.status == PREFLIGHTED ||
            tx.status == COMMITTED) {
            ++next_pending_by_instance[tx.source_instance_id];
        }
        next_transactions.push_back(tx);
    }

    // A transaction number cannot establish that the underlying requests
    // match. In particular, a catalog row never represents a family claim.
    for (const PreservedBuiltin &row : preserved_builtins) {
        if (next_transaction_ids.count(row.transaction.id) != 0) {
            error = "effect_pod_snapshot_builtin_transaction_id_collision";
            return false;
        }
    }
    for (const PreservedIdeologyBatch &row : preserved_ideology) {
        const auto other = next_transaction_ids.find(row.transaction.id);
        if (other == next_transaction_ids.end()) continue;
        const Transaction &incoming = next_transactions[other->second];
        if (incoming.source_instance_id != row.transaction.source_instance_id ||
            incoming.source_generation != row.transaction.source_generation ||
            incoming.plan_hash != row.transaction.plan_hash) {
            error = "effect_pod_snapshot_ideology_transaction_id_collision";
            return false;
        }
    }

    _instances = std::move(next_instances);
    _instance_ids = std::move(next_instance_ids);
    _free_instance_indices.clear();
    _metric_values = std::move(next_metric_values);
    _metric_present = std::move(next_metric_present);
    // Re-attach the preserved ideology source instances. Skipped when the worker
    // already carries the same id (that state is newer than ours).
    for (PreservedIdeologyBatch &row : preserved_ideology) {
        if (_instance_ids.count(row.source.id) != 0) continue;
        Instance instance = row.source;
        // Re-attached INACTIVE: it exists only so the settle can map the
        // preserved transaction back into Modifier rows. It must never be
        // evaluated on this thread, because the worker owns EFFECT here.
        instance.active = 0;
        instance.metric_base = static_cast<uint32_t>(_metric_values.size());
        _metric_values.insert(_metric_values.end(), row.metric_values.begin(),
                              row.metric_values.end());
        _metric_present.insert(_metric_present.end(), row.metric_present.begin(),
                               row.metric_present.end());
        _instance_ids[instance.id] = static_cast<int32_t>(_instances.size());
        _instances.push_back(instance);
    }
    _transactions = std::move(next_transactions);
    _transaction_ids = std::move(next_transaction_ids);
    _pending_transactions_by_instance = std::move(next_pending_by_instance);
    _command_arena = std::move(next_command_arena);
    _pending_command_idempotency.clear();
    _native_request_ids.clear();
    _native_ack_bindings.clear();
    _native_bound_transaction_ids.clear();
    _native_country_request_ids = std::move(preserved_country_request_ids);
    _native_country_ack_bindings = std::move(preserved_country_bindings);
    _native_country_bound_transaction_ids =
        std::move(preserved_country_bound_ids);
    _native_economy_request_ids = std::move(preserved_economy_request_ids);
    _native_economy_ack_bindings = std::move(preserved_economy_bindings);
    _native_economy_bound_transaction_ids =
        std::move(preserved_economy_bound_ids);
    _native_gameplay_request_ids.clear();
    _native_gameplay_ack_bindings.clear();
    _native_gameplay_bound_transaction_ids.clear();
    auto remap_preserved_bindings = [](int64_t old_id, int64_t new_id,
                                       std::vector<NativeAckBinding> &bindings,
                                       std::unordered_set<int64_t> &bound_ids) {
        for (NativeAckBinding &binding : bindings) {
            if (binding.transaction_id == old_id) binding.transaction_id = new_id;
        }
        if (bound_ids.erase(old_id) > 0) bound_ids.insert(new_id);
    };
    for (PreservedBuiltin &row : preserved_builtins) {
        if (_transaction_ids.count(row.transaction.id) != 0) {
            // Builtin transactions (colonization/canal) never originate on the
            // worker POD. A matching ID here is an ID collision with a worker
            // catalog transaction (for example from an older save); remap it
            // into the disjoint builtin ID range instead of silently dropping
            // the expedition's CLAIM/SETTLE transaction.
            const int64_t old_id = row.transaction.id;
            const int64_t new_id = allocate_builtin_transaction_id();
            row.transaction.id = new_id;
            remap_preserved_bindings(old_id, new_id,
                _native_country_ack_bindings,
                _native_country_bound_transaction_ids);
            remap_preserved_bindings(old_id, new_id,
                _native_economy_ack_bindings,
                _native_economy_bound_transaction_ids);
        }
        row.transaction.command_begin =
            static_cast<uint32_t>(_command_arena.size());
        row.transaction.command_count =
            static_cast<uint32_t>(row.commands.size());
        for (Command &command : row.commands)
            _command_arena.push_back(std::move(command));
        _transaction_ids[row.transaction.id] =
            static_cast<int32_t>(_transactions.size());
        if (row.transaction.status == PLANNED ||
            row.transaction.status == PREFLIGHTED ||
            row.transaction.status == COMMITTED) {
            ++_pending_transactions_by_instance[row.transaction.source_instance_id];
        }
        _transactions.push_back(std::move(row.transaction));
    }
    for (PreservedIdeologyBatch &row : preserved_ideology) {
        if (_transaction_ids.count(row.transaction.id) != 0) continue;
        if (_instance_ids.count(row.transaction.source_instance_id) == 0) continue;
        row.transaction.command_begin = static_cast<uint32_t>(_command_arena.size());
        row.transaction.command_count = static_cast<uint32_t>(row.commands.size());
        for (Command &command : row.commands)
            _command_arena.push_back(std::move(command));
        _transaction_ids[row.transaction.id] =
            static_cast<int32_t>(_transactions.size());
        if (row.transaction.status == PLANNED ||
            row.transaction.status == PREFLIGHTED ||
            row.transaction.status == COMMITTED) {
            ++_pending_transactions_by_instance[row.transaction.source_instance_id];
        }
        _transactions.push_back(std::move(row.transaction));
    }
    _dirty_queue.clear();
    _next_activation_sequence = next_activation_sequence;
    for (const Transaction &tx : _transactions)
        _next_transaction_id = std::max(_next_transaction_id, tx.id + 1);
    _current_day = snapshot.committed_day;
    _last_completed_day = snapshot.committed_day;
    _run_day = -1;
    _run_cursor = 0;
    rebuild_family_effect_groups();
    rebuild_command_idempotency_index();
    _run_candidates.clear();
    _candidate_cursor = 0;
    _due_heap = {};
    _schedule_token += 1;
    for (size_t i = 0; i < _instances.size(); ++i) {
        Instance &instance = _instances[i];
        instance.schedule_token = _schedule_token;
        if (instance.active != 0) {
            DueNode node;
            node.day = instance.next_due_day;
            node.instance_index = static_cast<int32_t>(i);
            node.generation = instance.generation;
            node.schedule_token = instance.schedule_token;
            _due_heap.push(node);
        }
    }
    // A snapshot only ever advances the watermark. Assigning directly would
    // let a worker snapshot that is behind the local value-driven publishes
    // pull `_committed_generation` backwards, and country_runtime rejects any
    // peer intent whose adapter generation looks older than its own.
    _committed_generation = std::max<uint64_t>(_committed_generation,
        snapshot.generation);
    _pod_snapshot_generation = snapshot.generation;
    return true;
}














bool EffectRuntime::has_pending_family_colonization_transactions() const {
    for (const Transaction &transaction : _transactions) {
        if (transaction.program_id != -1 || transaction.command_count == 0)
            continue;
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        return true;
    }
    return false;
}

bool EffectRuntime::should_run(int64_t day_index) const {
    if (!_configured) return false;
    if (_run_day == day_index &&
        _candidate_cursor < static_cast<int32_t>(_run_candidates.size())) return true;
    auto transaction_due = [&](int64_t transaction_id) -> bool {
        const int32_t index = transaction_index_for_id(transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
            return false;
        const Transaction &transaction = _transactions[static_cast<size_t>(index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            return false;
        return transaction.effective_day <= day_index;
    };
    auto bindings_due = [&](const std::vector<NativeAckBinding> &bindings) -> bool {
        for (const NativeAckBinding &binding : bindings)
            if (transaction_due(binding.transaction_id)) return true;
        return false;
    };
    if (bindings_due(_native_ack_bindings) ||
        bindings_due(_native_country_ack_bindings) ||
        bindings_due(_native_economy_ack_bindings) ||
        bindings_due(_native_gameplay_ack_bindings))
        return true;
    for (const Transaction &transaction : _transactions) {
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (transaction.effective_day <= day_index) return true;
    }
    for (const int32_t index : _dirty_queue) {
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
        const Instance &instance = _instances[static_cast<size_t>(index)];
        if (instance.active != 0 && instance.next_due_day <= day_index) return true;
    }
    if (!_due_heap.empty() && _due_heap.top().day <= day_index) return true;
    return false;
}

bool EffectRuntime::program_modifier_commands(
        const std::string &program_key,
        std::vector<ProgramModifierCommand> &out) const {
    out.clear();
    for (const Definition &definition : _definitions) {
        if (definition.key != program_key) continue;
        for (int32_t offset = 0; offset < definition.command_count; ++offset) {
            const CommandDefinition &command = _command_definitions[
                static_cast<size_t>(definition.command_begin + offset)];
            if (command.action != MODIFIER_COMMAND) continue;
            out.push_back(ProgramModifierCommand{command.definition_key,
                command.value, command.stacks, command.duration_days,
                command.value_mode});
        }
        return true;
    }
    return false;
}



Dictionary EffectRuntime::clear_state() {
    if (!_configured) return failure("effect_runtime_unconfigured");
    reset_runtime_state();
    Dictionary out;
    out["ok"] = true;
    return out;
}

} // namespace pk
