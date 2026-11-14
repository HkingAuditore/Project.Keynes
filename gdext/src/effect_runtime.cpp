#include "effect_runtime.h"
#include "country_api.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

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
        if (source_instance.source_type != IDEOLOGY_SOURCE_TYPE) continue;
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
    for (PreservedBuiltin &row : preserved_builtins) {
        if (_transaction_ids.count(row.transaction.id) != 0) continue;
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

Dictionary EffectRuntime::explain(int64_t instance_id) const {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) return failure("effect_instance_not_found");
    const Instance &instance = _instances[index];
    const Definition &definition = _definitions[instance.program_id];
    Dictionary out;
    out["ok"] = true;
    out["instance_id"] = instance.id;
    out["generation"] = static_cast<int64_t>(instance.generation);
    out["program_key"] = String(definition.key.c_str());
    out["program_version"] = definition.version;
    out["level"] = instance.level;
    out["source_kind"] = instance.source_kind;
    out["target_domain"] = instance.target_domain;
    out["operation"] = instance.operation;
    out["lifecycle"] = instance.lifecycle;
    out["duration_days"] = instance.duration_days;
    out["stack_policy"] = instance.stack_policy;
    out["stack_count"] = instance.stack_count;
    out["applied_stack_count"] = instance.applied_stack_count;
    out["max_stacks"] = instance.max_stacks;
    out["priority"] = instance.priority;
    out["activation_sequence"] = static_cast<int64_t>(
        instance.activation_sequence);
    out["expires_day"] = instance.expires_day;
    out["effect_applied"] = instance.effect_applied != 0;
    out["retire_requested"] = instance.retire_requested != 0;
    out["applied_input_revision"] = instance.applied_input_revision;
    out["last_acked_fire_sequence"] = static_cast<int64_t>(
        instance.last_acked_fire_sequence);
    // Persisted since PKEF 13. Exposed so a test can tell a genuinely latched
    // instance from one that merely round-tripped a zero.
    out["latched"] = instance.latched != 0;
    out["next_due_day"] = instance.next_due_day;
    out["input_revision"] = instance.input_revision;
    out["last_evaluated_input_revision"] = instance.last_evaluated_input_revision;
    out["fire_sequence"] = static_cast<int64_t>(instance.fire_sequence);
    out["condition_passes"] = evaluate_condition(definition, instance);
    return out;
}

Dictionary EffectRuntime::report() const {
    Dictionary out;
    std::array<int32_t, RESYNC_REQUIRED + 1> status_counts{};
    for (const Transaction &transaction : _transactions) {
        if (transaction.status >= PLANNED && transaction.status <= RESYNC_REQUIRED)
            ++status_counts[transaction.status];
    }
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["committed_generation"] = static_cast<int64_t>(_committed_generation);
    out["current_day"] = _current_day;
    out["last_completed_day"] = _last_completed_day;
    out["definitions"] = static_cast<int32_t>(_definitions.size());
    out["metrics"] = _metric_count;
    out["instances"] = static_cast<int32_t>(_instance_ids.size());
    out["instance_storage_slots"] = static_cast<int32_t>(_instances.size());
    out["free_instance_slots"] = static_cast<int32_t>(_free_instance_indices.size());
    out["family_effect_stack_groups"] = static_cast<int64_t>(
        _family_effect_groups.size());
    int64_t family_effect_group_members = 0;
    int64_t family_effect_group_bytes = 0;
    for (const auto &entry : _family_effect_groups) {
        family_effect_group_members += static_cast<int64_t>(entry.second.size());
        family_effect_group_bytes += static_cast<int64_t>(
            sizeof(entry.first) + entry.second.capacity() * sizeof(int32_t));
    }
    out["family_effect_group_members"] = family_effect_group_members;
    out["family_effect_group_bytes"] = family_effect_group_bytes;
    out["transactions"] = static_cast<int32_t>(_transactions.size());
    out["external_bindings"] = static_cast<int32_t>(_external_binding_ids.size());
    out["pending_command_idempotency_count"] = static_cast<int64_t>(
        _pending_command_idempotency.size());
    out["pending_transactions"] = static_cast<int32_t>(std::count_if(
        _transactions.begin(), _transactions.end(), [](const Transaction &transaction) {
            return transaction.status == PLANNED || transaction.status == PREFLIGHTED ||
                transaction.status == COMMITTED;
        }));
    out["planned_transactions"] = status_counts[PLANNED];
    out["preflighted_transactions"] = status_counts[PREFLIGHTED];
    out["committed_transactions"] = status_counts[COMMITTED];
    out["acked_transactions"] = status_counts[ACKED];
    out["rejected_transactions"] = status_counts[REJECTED];
    out["resync_required_transactions"] = status_counts[RESYNC_REQUIRED];
    out["max_work_per_slice"] = _max_work_per_slice;
    out["instances_submitted"] = static_cast<int64_t>(_instances_submitted);
    out["programs_evaluated"] = static_cast<int64_t>(_programs_evaluated);
    out["commands_emitted"] = static_cast<int64_t>(_commands_emitted);
    out["transactions_acked"] = static_cast<int64_t>(_transactions_acked);
    out["preflight_rejects"] = static_cast<int64_t>(_preflight_rejects);
    out["behavior_failures"] = static_cast<int64_t>(_behavior_failures);
    out["overflow_count"] = static_cast<int64_t>(_overflow_count);
    out["last_evaluate_ms"] = _last_evaluate_ms;
    out["last_native_modifier_dispatch_ms"] = _last_native_dispatch_ms;
    out["last_native_modifier_ack_ms"] = _last_native_ack_ms;
    out["last_parallel_planning_ms"] = _last_parallel_planning_ms;
    out["last_parallel_merge_ms"] = _last_parallel_merge_ms;
    out["last_parallel_worker_count"] = _last_parallel_worker_count;
    out["parallel_dispatches"] = static_cast<int64_t>(_parallel_dispatches);
    out["serial_fallback_dispatches"] = static_cast<int64_t>(_serial_fallback_dispatches);
    out["last_parallel_path"] = String(_last_parallel_path.c_str());
    out["last_parallel_fallback_reason"] = String(_last_parallel_fallback_reason.c_str());
    out["native_modifier_transactions"] = static_cast<int64_t>(_native_modifier_transactions);
    out["native_modifier_commands"] = static_cast<int64_t>(_native_modifier_commands);
    out["native_modifier_acks"] = static_cast<int64_t>(_native_modifier_acks);
    out["native_country_transactions"] = static_cast<int64_t>(_native_country_transactions);
    out["native_country_commands"] = static_cast<int64_t>(_native_country_commands);
    out["native_country_acks"] = static_cast<int64_t>(_native_country_acks);
    out["native_economy_transactions"] = static_cast<int64_t>(_native_economy_transactions);
    out["native_economy_commands"] = static_cast<int64_t>(_native_economy_commands);
    out["native_economy_acks"] = static_cast<int64_t>(_native_economy_acks);
    out["native_gameplay_transactions"] = static_cast<int64_t>(_native_gameplay_transactions);
    out["native_gameplay_commands"] = static_cast<int64_t>(_native_gameplay_commands);
    out["native_gameplay_acks"] = static_cast<int64_t>(_native_gameplay_acks);
    out["due_queue_count"] = static_cast<int64_t>(_due_heap.size());
    out["dirty_queue_count"] = static_cast<int64_t>(_dirty_queue.size());
    out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
    out["candidate_cursor"] = _candidate_cursor;
    out["native_modifier_ack_pending"] = static_cast<int64_t>(
        _native_ack_bindings.size());
    out["native_country_ack_pending"] = static_cast<int64_t>(
        _native_country_ack_bindings.size());
    out["native_economy_ack_pending"] = static_cast<int64_t>(
        _native_economy_ack_bindings.size());
    out["native_gameplay_ack_pending"] = static_cast<int64_t>(
        _native_gameplay_ack_bindings.size());
    out["dormant_instances_scanned"] = 0;
    out["metric_slab_bytes"] = static_cast<int64_t>(
        _metric_values.capacity() * sizeof(int64_t) +
        _metric_present.capacity() * sizeof(uint8_t));
    out["instance_storage_bytes"] = static_cast<int64_t>(
        _instances.capacity() * sizeof(Instance));
    out["era_reward_last_plan_ms"] = _last_era_reward_plan_ms;
    out["era_reward_offers_planned"] = static_cast<int64_t>(
        _era_reward_offers_planned);
    out["era_reward_last_expanded_commands"] =
        _last_era_reward_expanded_commands;
    int64_t era_reward_storage_bytes = static_cast<int64_t>(
        _era_reward_pools.capacity() * sizeof(EraRewardPool) +
        _era_reward_options.capacity() * sizeof(EraRewardOption) +
        _era_reward_rules.capacity() * sizeof(EraRewardRule) +
        sizeof(EraRewardOffer));
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        era_reward_storage_bytes += static_cast<int64_t>(
            alternative.target_summary.capacity());
        for (const std::string &reason : alternative.reasons)
            era_reward_storage_bytes += static_cast<int64_t>(reason.capacity());
    }
    out["era_reward_storage_bytes"] = era_reward_storage_bytes;
    out["last_error"] = String(_last_error.c_str());
    out["run_cursor"] = _run_cursor;
    return out;
}

Dictionary EffectRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (packed.size() < sizeof(uint32_t) * 2) return failure("pkef_truncated");
    const uint8_t *bytes = packed.ptr();
    const size_t size = packed.size();
    size_t cursor = 0;
    uint32_t magic = 0, end_magic = 0;
    int32_t schema = 0, protocol = 0;
    uint64_t hash = 0;
    if (!read_le(bytes, size, cursor, magic) || magic != SAVE_MAGIC ||
        !read_le(bytes, size, cursor, schema))
        return failure("pkef_header_incompatible");
    // Two different failures that used to share `catalog_hash_mismatch`, which
    // sent every compatibility audit after the wrong cause: a save from another
    // build is an unsupported schema, not a content mismatch.
    if (schema != SAVE_SCHEMA_VERSION)
        return failure("pkef_schema_unsupported");
    if (!read_le(bytes, size, cursor, protocol) || protocol != PROTOCOL_VERSION ||
        !read_le(bytes, size, cursor, hash) || hash != _catalog_hash)
        return failure("catalog_hash_mismatch");
    int64_t current_day = -1, last_day = -1, run_day = -1, next_tx = 1, acked_tx = 0;
    uint64_t next_activation_sequence = 1;
    int32_t run_cursor = 0;
    uint32_t instance_count = 0, candidate_count = 0, transaction_count = 0;
    if (!read_le(bytes, size, cursor, current_day) || !read_le(bytes, size, cursor, last_day) ||
        !read_le(bytes, size, cursor, run_day) || !read_le(bytes, size, cursor, run_cursor) ||
        !read_le(bytes, size, cursor, next_tx) || !read_le(bytes, size, cursor, acked_tx) ||
        !read_le(bytes, size, cursor, next_activation_sequence) ||
        !read_le(bytes, size, cursor, instance_count) || instance_count > static_cast<uint32_t>(_max_instances))
        return failure("pkef_instances_invalid");
    if (current_day < -1 || last_day < -1 || run_day < -1 || run_cursor < 0 ||
        next_tx <= 0 || acked_tx < 0 || acked_tx >= next_tx ||
        next_activation_sequence == 0)
        return failure("pkef_runtime_cursor_invalid");
    std::vector<Instance> restored_instances;
    std::vector<int64_t> restored_metric_values;
    std::vector<uint8_t> restored_metric_present;
    restored_metric_values.reserve(static_cast<size_t>(instance_count) *
                                   static_cast<size_t>(_metric_count));
    restored_metric_present.reserve(static_cast<size_t>(instance_count) *
                                    static_cast<size_t>(_metric_count));
    std::unordered_map<int64_t, int32_t> restored_instance_ids;
    // Nothing inserts here since PKEF 13 deleted the v11 migration, so the
    // legacy POD transaction branch that reads it is unreachable. The container
    // and the guard stay because a future schema migration is exactly the way
    // this state comes back, and deleting the guard would make that change look
    // smaller than it is.
    std::unordered_set<int64_t> legacy_pod_instance_ids;
    restored_instances.reserve(instance_count);
    for (uint32_t i = 0; i < instance_count; ++i) {
        Instance instance;
        uint32_t metric_count = 0;
        if (!read_le(bytes, size, cursor, instance.id) || !read_le(bytes, size, cursor, instance.generation) ||
            !read_le(bytes, size, cursor, instance.program_id) || !read_le(bytes, size, cursor, instance.source_type) ||
            !read_le(bytes, size, cursor, instance.source_id) || !read_le(bytes, size, cursor, instance.source_handle) ||
            !read_le(bytes, size, cursor, instance.target_handle) || !read_le(bytes, size, cursor, instance.target_generation) ||
            !read_le(bytes, size, cursor, instance.level) ||
            !read_le(bytes, size, cursor, instance.magnitude_scale_q16) ||
            // BOUNDS CHECK BEFORE THE INDEX, not after -- and `-1` is NOT an index.
            //
            // `instance.program_id` came straight out of the payload two reads above and
            // the range check lived ~70 lines LATER (the `pkef_instance_identity_invalid`
            // test), so a corrupted PKEF could index `_definitions[]` out of bounds here;
            // a negative id becomes a huge `size_t`, i.e. a guaranteed out-of-bounds read.
            //
            // The first attempt at this guard simply added `program_id < 0` to the chain,
            // which rejected every TOMBSTONE -- `program_id == -1` is the legitimate
            // marker for a deleted instance (`pkef_instance_tombstone_invalid` below reads
            // it that way) -- and broke four save fixtures on the next run. So `-1` skips
            // the whole group instead of failing it.
            (instance.program_id != -1 &&
             (instance.program_id < 0 ||
              instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
              !magnitude_scale_allowed_for_selector(
                  _definitions[static_cast<size_t>(instance.program_id)]
                      .target_selector_kind,
                  instance.magnitude_scale_q16,
                  _definitions[static_cast<size_t>(instance.program_id)]
                      .target_selector_param))) ||
            !read_le(bytes, size, cursor, instance.next_due_day) ||
            !read_le(bytes, size, cursor, instance.input_revision) ||
            !read_le(bytes, size, cursor, instance.last_evaluated_input_revision) ||
            !read_le(bytes, size, cursor, instance.fire_sequence) ||
            !read_le(bytes, size, cursor, instance.active) ||
            !read_le(bytes, size, cursor, instance.source_kind) ||
            !read_le(bytes, size, cursor, instance.target_domain) ||
            !read_le(bytes, size, cursor, instance.operation) ||
            !read_le(bytes, size, cursor, instance.lifecycle) ||
            !read_le(bytes, size, cursor, instance.duration_days) ||
            !read_le(bytes, size, cursor, instance.stack_policy) ||
            !read_le(bytes, size, cursor, instance.max_stacks) ||
            !read_le(bytes, size, cursor, instance.stack_count) ||
            !read_le(bytes, size, cursor, instance.applied_stack_count) ||
            !read_le(bytes, size, cursor, instance.priority) ||
            !read_le(bytes, size, cursor, instance.activation_sequence) ||
            !read_le(bytes, size, cursor, instance.expires_day) ||
            !read_le(bytes, size, cursor, instance.stack_key_hash) ||
            !read_le(bytes, size, cursor, instance.effect_applied) ||
            !read_le(bytes, size, cursor, instance.retire_requested) ||
            !read_le(bytes, size, cursor, instance.applied_input_revision) ||
            !read_le(bytes, size, cursor, instance.last_acked_fire_sequence) ||
            !read_le(bytes, size, cursor, instance.latched) ||
            !read_le(bytes, size, cursor, metric_count) ||
            metric_count != static_cast<uint32_t>(_metric_count))
            return failure("pkef_instance_truncated_or_metric_mismatch");
        // The v11 migration block that used to live here is gone: the version
        // gate above rejects anything but the current schema, so `schema == 11`
        // could never be true and the repair never ran. Its only other effect
        // was feeding `legacy_pod_instance_ids`, which is why the legacy POD
        // transaction branch below is now unreachable too -- see the note at the
        // set's declaration.
        if (instance.active > 1 || instance.source_kind < 0 || instance.source_kind > 5 ||
            instance.target_domain < 0 || instance.target_domain > 5 ||
            instance.operation < 0 || instance.operation > 4 ||
            instance.lifecycle < 0 || instance.lifecycle > 2 ||
            instance.stack_policy < 0 || instance.stack_policy > 4 ||
            instance.max_stacks <= 0 ||
            instance.max_stacks > MAX_AUTHORED_STACKS ||
            instance.stack_count <= 0 ||
            instance.stack_count > instance.max_stacks ||
            instance.applied_stack_count < 0 ||
            instance.applied_stack_count > instance.max_stacks ||
            instance.effect_applied > 1 || instance.retire_requested > 1 ||
            instance.latched > 1 ||
            // The (effect_applied, applied_stack_count) pair is a MANAGED-lifecycle
            // invariant, not a row invariant: the two fields are advanced TOGETHER
            // only for a managed program (`apply_acked_instance_transition` here,
            // `RuntimeEffectPodAuthority::apply_ack` on the worker). An UNMANAGED
            // program is fire-and-forget: the worker records its applied stack count
            // as bookkeeping and never sets the latch, because nothing consumes the
            // latch for it (`uses_managed_lifecycle` gates every reader). `(0, N)` is
            // therefore the pair the domain itself produces for a one-shot row that
            // fired, and the POD's OWN save format already scopes this identical
            // test to `managed != 0` (`runtime_effect_pod.cpp`, the
            // `effect_pod_instance_truncated_or_invalid` chain).
            //
            // PKEF used to apply the test to EVERY row. That made this reader refuse
            // the pair its own domain writes: with EFFECT owned by the worker, the
            // write-back of a fired `person.modifier.*` instance carries
            // `(effect_applied=0, applied_stack_count=1)`, `capture()` persisted it,
            // and `restore()` answered `pkef_instance_identity_invalid` -- measured,
            // for the payload returned by the runtime that had just written it. The
            // check is NOT removed: a MANAGED row whose latch and count disagree is
            // a real inconsistency (both writers move them together) and is still
            // refused, in a main-thread payload and a worker payload alike.
            (instance.program_id >= 0 &&
             uses_managed_lifecycle(
                 _definitions[static_cast<size_t>(instance.program_id)]) &&
             (instance.effect_applied == 0) !=
                 (instance.applied_stack_count == 0)) ||
            instance.applied_input_revision < 0 ||
            instance.applied_input_revision > instance.input_revision ||
            instance.last_acked_fire_sequence > instance.fire_sequence ||
            instance.input_revision < 0 ||
            instance.last_evaluated_input_revision < 0 ||
            instance.last_evaluated_input_revision > instance.input_revision)
            return failure("pkef_instance_identity_invalid");
        if (instance.id == 0) {
            // Retired slots are persisted so their metric slab rows and free
            // list can be reconstructed without renumbering live instances.
            if (instance.generation != 0 || instance.program_id != -1 ||
                instance.active != 0 || instance.activation_sequence != 0)
                return failure("pkef_instance_tombstone_invalid");
        } else if (instance.id < 0 || instance.generation == 0 ||
                   instance.program_id < 0 ||
                   instance.program_id >= static_cast<int32_t>(_definitions.size()) ||
                   instance.activation_sequence == 0 ||
                   instance.activation_sequence >= next_activation_sequence ||
                   !restored_instance_ids.emplace(instance.id,
                       static_cast<int32_t>(restored_instances.size())).second) {
            return failure("pkef_instance_identity_invalid");
        }
        // The save carried the change watermark but not the observed one, and
        // a restored instance must not treat the first publish after load as a
        // regression against a value it has already seen.
        instance.metric_observed_revision = instance.input_revision;
        if (instance.id > 0) {
            const Definition &definition = _definitions[
                static_cast<size_t>(instance.program_id)];
            const uint64_t expected_stack_key = fnv_string(
                1469598103934665603ULL,
                definition.stack_key.empty() ? definition.key
                                             : definition.stack_key);
            if (instance.source_kind != definition.source_kind ||
                instance.target_domain != definition.target_domain ||
                instance.operation != definition.operation ||
                instance.lifecycle != definition.lifecycle ||
                instance.duration_days != definition.duration_days ||
                instance.stack_policy != definition.stack_policy ||
                instance.max_stacks != definition.max_stacks ||
                instance.priority != definition.priority ||
                instance.stack_key_hash != expected_stack_key)
                return failure("pkef_instance_catalog_metadata_mismatch");
        }
        for (uint32_t j = 0; j < metric_count; ++j) {
            int64_t value = 0;
            if (!read_le(bytes, size, cursor, value))
                return failure("pkef_instance_metrics_truncated");
            restored_metric_values.push_back(value);
        }
        for (uint32_t j = 0; j < metric_count; ++j) {
            uint8_t present = 0;
            if (!read_le(bytes, size, cursor, present))
                return failure("pkef_instance_presence_truncated");
            if (present > 1) return failure("pkef_instance_presence_invalid");
            restored_metric_present.push_back(present);
        }
        restored_instances.push_back(std::move(instance));
    }
    int32_t candidate_cursor = 0;
    if (!read_le(bytes, size, cursor, candidate_cursor) ||
        !read_le(bytes, size, cursor, candidate_count) ||
        candidate_count > instance_count || candidate_cursor < 0 ||
        candidate_cursor > static_cast<int32_t>(candidate_count))
        return failure("pkef_candidate_cursor_invalid");
    std::vector<int32_t> restored_candidates;
    restored_candidates.reserve(candidate_count);
    std::vector<uint8_t> candidate_seen(instance_count, 0);
    for (uint32_t i = 0; i < candidate_count; ++i) {
        int32_t index = -1;
        if (!read_le(bytes, size, cursor, index) || index < 0 ||
            index >= static_cast<int32_t>(instance_count) ||
            restored_instances[static_cast<size_t>(index)].id == 0 ||
            candidate_seen[static_cast<size_t>(index)] != 0)
            return failure("pkef_candidate_invalid");
        candidate_seen[static_cast<size_t>(index)] = 1;
        restored_candidates.push_back(index);
    }
    if (!read_le(bytes, size, cursor, transaction_count) ||
        transaction_count > static_cast<uint32_t>(_max_transactions))
        return failure("pkef_transactions_invalid");
    std::vector<Transaction> restored_transactions;
    std::vector<Command> restored_command_arena;
    std::unordered_set<int64_t> restored_transaction_ids;
    restored_transactions.reserve(transaction_count);
    restored_command_arena.reserve(std::min<size_t>(
        static_cast<size_t>(_max_native_modifier_commands),
        static_cast<size_t>(transaction_count) * 4));
    int64_t max_transaction_id = 0;
    for (uint32_t i = 0; i < transaction_count; ++i) {
        Transaction transaction;
        uint32_t command_count = 0;
        if (!read_le(bytes, size, cursor, transaction.id) ||
            !read_le(bytes, size, cursor, transaction.source_instance_id) ||
            !read_le(bytes, size, cursor, transaction.source_generation) ||
            !read_le(bytes, size, cursor, transaction.program_id) ||
            !read_le(bytes, size, cursor, transaction.effective_day) ||
            !read_le(bytes, size, cursor, transaction.plan_hash) ||
            !read_le(bytes, size, cursor, transaction.required_ack_mask) ||
            !read_le(bytes, size, cursor, transaction.received_ack_mask) ||
            !read_le(bytes, size, cursor, transaction.status) ||
            !read_le(bytes, size, cursor, transaction.instance_transition) ||
            !read_le(bytes, size, cursor, transaction.transition_input_revision) ||
            !read_le(bytes, size, cursor, transaction.transition_fire_sequence) ||
            !read_le(bytes, size, cursor, transaction.transition_stack_count) ||
            !read_le(bytes, size, cursor, command_count) || command_count > 4096)
            return failure("pkef_transaction_truncated");
        const bool legacy_pod_transaction = transaction.program_id == -1 &&
            legacy_pod_instance_ids.count(transaction.source_instance_id) != 0;
        const uint64_t legacy_pod_fire_sequence = transaction.transition_fire_sequence;
        const uint64_t legacy_pod_plan_hash = transaction.plan_hash;
        std::vector<RuntimeEffectPodCommand> legacy_pod_commands;
        if (legacy_pod_transaction) {
            const Instance &source = restored_instances[
                restored_instance_ids.at(transaction.source_instance_id)];
            if (transaction.source_generation != source.generation ||
                transaction.instance_transition != TRANSITION_NONE ||
                legacy_pod_fire_sequence == 0 ||
                legacy_pod_fire_sequence > source.fire_sequence ||
                transaction.transition_stack_count != 0 ||
                transaction.transition_input_revision > source.input_revision)
                return failure("pkef_legacy_pod_transaction_invalid");
            transaction.program_id = source.program_id;
            transaction.transition_fire_sequence = 0;
            transaction.transition_input_revision = 0;
        }
        const bool builtin_family_colonization = transaction.program_id == -1;
        const bool builtin_canal_commit = transaction.program_id == -2;
        const bool builtin_transaction = builtin_family_colonization ||
            builtin_canal_commit;
        if (transaction.id <= 0 || transaction.source_instance_id <= 0 ||
            transaction.source_generation == 0 ||
            (!builtin_transaction &&
             (transaction.program_id < 0 ||
              transaction.program_id >= static_cast<int32_t>(_definitions.size()) ||
              restored_instance_ids.find(transaction.source_instance_id) == restored_instance_ids.end())) ||
            transaction.status < PLANNED || transaction.status > RESYNC_REQUIRED ||
            transaction.instance_transition < TRANSITION_NONE ||
            transaction.instance_transition > TRANSITION_RETIRE ||
            transaction.transition_input_revision < 0 ||
            transaction.transition_stack_count < 0 ||
            !restored_transaction_ids.emplace(transaction.id).second ||
            (transaction.received_ack_mask & ~transaction.required_ack_mask) != 0)
            return failure("pkef_transaction_identity_invalid");
        if (!builtin_transaction) {
            const Instance &source_instance = restored_instances[
                restored_instance_ids[transaction.source_instance_id]];
            if ((transaction.status == PLANNED || transaction.status == PREFLIGHTED ||
                 transaction.status == COMMITTED) &&
                source_instance.generation != transaction.source_generation)
                return failure("pkef_transaction_source_generation_invalid");
            // A TERMINAL REJECTED row keeps the fire/input references it was rejected AT,
            // while a generation supersession resets those same instance counters to 0
            // (`upsert_instance_pod`, the `generation_changed` block). The pair is
            // legitimate, but it violates the "a transition must not reference a counter
            // the instance no longer has" rule below -- which made any save taken in the
            // window between the supersession rejection and the retry fire UNLOADABLE
            // (`pkef_transaction_transition_invalid`, measured by the §11.7 time-point-2
            // fixture).
            //
            // That rule exists to stop a transition from being APPLIED against a stale
            // instance. A REJECTED row is terminal and is never applied --
            // `apply_rejected_instance_transition` deliberately leaves the program
            // retryable, and the retry is a NEW transaction. So the two "stale counter"
            // checks are skipped for it. The structural checks still apply to every row,
            // so real corruption is still caught.
            const bool terminal_rejected = transaction.status == REJECTED;
            if ((transaction.instance_transition == TRANSITION_NONE) !=
                    (transaction.transition_fire_sequence == 0) ||
                (transaction.instance_transition == TRANSITION_NONE &&
                 transaction.transition_stack_count != 0) ||
                ((transaction.instance_transition == TRANSITION_APPLY ||
                  transaction.instance_transition == TRANSITION_UPDATE) &&
                 (transaction.transition_stack_count <= 0 ||
                  transaction.transition_stack_count >
                      source_instance.max_stacks)) ||
                ((transaction.instance_transition == TRANSITION_DEACTIVATE ||
                  transaction.instance_transition == TRANSITION_RETIRE) &&
                 transaction.transition_stack_count != 0) ||
                (!terminal_rejected &&
                 (transaction.transition_input_revision >
                      source_instance.input_revision ||
                  transaction.transition_fire_sequence >
                      source_instance.fire_sequence)))
                return failure("pkef_transaction_transition_invalid");
        } else if (transaction.instance_transition != TRANSITION_NONE ||
                   transaction.transition_input_revision != 0 ||
                   transaction.transition_fire_sequence != 0 ||
                   transaction.transition_stack_count != 0) {
            return failure("pkef_builtin_transaction_transition_invalid");
        }
        if ((transaction.status == PLANNED || transaction.status == PREFLIGHTED) &&
            transaction.received_ack_mask != 0)
            return failure("pkef_transaction_state_invalid");
        if (transaction.status == ACKED &&
            (transaction.received_ack_mask & transaction.required_ack_mask) !=
                transaction.required_ack_mask)
            return failure("pkef_transaction_ack_incomplete");
        transaction.command_begin = static_cast<uint32_t>(restored_command_arena.size());
        transaction.command_count = 0;
        uint32_t derived_ack_mask = 0;
        std::unordered_set<uint64_t> command_idempotency_keys;
        for (uint32_t j = 0; j < command_count; ++j) {
            Command command;
            if (!read_le(bytes, size, cursor, command.action) || !read_le(bytes, size, cursor, command.domain) ||
                !read_le(bytes, size, cursor, command.opcode) || !read_le(bytes, size, cursor, command.target_handle) ||
                !read_le(bytes, size, cursor, command.target_generation) ||
                !read_le(bytes, size, cursor, command.value_q16) || !read_le(bytes, size, cursor, command.duration_days) ||
                !read_le(bytes, size, cursor, command.stacks) ||
                !read_le(bytes, size, cursor, command.idempotency_key) ||
                !read_le(bytes, size, cursor, command.command_key_id) ||
                !read_le(bytes, size, cursor, command.command_definition_id))
                return failure("pkef_command_truncated");
            if (schema >= 10 &&
                (!read_le(bytes, size, cursor, command.external_effect_id) ||
                 !read_le(bytes, size, cursor, command.external_source_id)))
                return failure("pkef_command_external_identity_truncated");
            if (legacy_pod_transaction) {
                if (command.command_key_id != -1 ||
                    command.command_definition_id < 0 ||
                    command.command_definition_id >= static_cast<int32_t>(_command_definitions.size()) ||
                    _command_definitions[command.command_definition_id].owner_program_id != transaction.program_id ||
                    command.external_effect_id != transaction.source_instance_id ||
                    command.external_source_id != 0)
                    return failure("pkef_legacy_pod_command_invalid");
                command.command_key_id = command.command_definition_id;
                command.external_effect_id = 0;
            }
            if (command.action < MODIFIER_COMMAND || command.action > CUSTOM_DOMAIN_COMMAND ||
                command.domain < -1 || command.domain >= 32 || command.stacks <= 0 ||
                command.duration_days < -1 || command.command_key_id < -1 ||
                command.command_definition_id < -1 ||
                ((command.external_effect_id == 0) !=
                 (command.external_source_id == 0)) ||
                command.external_effect_id < 0 ||
                (command.command_definition_id >= static_cast<int32_t>(_command_definitions.size())) ||
                (command.command_definition_id >= 0 &&
                 command.command_key_id != command.command_definition_id) ||
                (command.command_definition_id < 0 &&
                 command.command_key_id >= static_cast<int32_t>(_behavior_command_keys.size())) ||
                !command_idempotency_keys.emplace(command.idempotency_key).second)
                return failure("pkef_command_invalid");
            if (command.command_definition_id >= 0) {
                const CommandDefinition &definition = _command_definitions[
                    static_cast<size_t>(command.command_definition_id)];
                std::string command_error;
                const bool remove_alias = command.action == MODIFIER_COMMAND &&
                    command.opcode == ModifierApi::COMMAND_REMOVE &&
                    definition.opcode == ModifierApi::COMMAND_APPLY;
                const bool family_stack_alias = !remove_alias &&
                    definition.owner_program_id >= 0 &&
                    definition.owner_program_id < static_cast<int32_t>(
                        _definitions.size()) &&
                    _definitions[static_cast<size_t>(
                        definition.owner_program_id)].managed_declared &&
                    definition.stacks == 1 && command.stacks >= 1 &&
                    command.stacks <= _definitions[static_cast<size_t>(
                        definition.owner_program_id)].max_stacks;
                const bool command_shape_matches = remove_alias
                    ? definition.action == MODIFIER_COMMAND &&
                        definition.domain == command.domain &&
                        command.duration_days == -1 && command.stacks == 1
                    : definition.action == command.action &&
                        definition.domain == command.domain &&
                        definition.opcode == command.opcode &&
                        definition.duration_days == command.duration_days &&
                        (definition.stacks == command.stacks ||
                         family_stack_alias);
                if (!command_shape_matches ||
                    !native_command_shape_valid(command.action, command.domain,
                        command.opcode, definition.target_resolver,
                        command.duration_days, command.stacks, command.value_q16,
                        command_error))
                    return failure(command_error.empty()
                        ? "pkef_command_definition_mismatch" : command_error.c_str());
            }
            derived_ack_mask |= adapter_ack_bit_for(command);
            for (int64_t &value : command.payload)
                if (!read_le(bytes, size, cursor, value)) return failure("pkef_command_payload_truncated");
            if (legacy_pod_transaction) {
                const Instance &source = restored_instances[
                    restored_instance_ids.at(transaction.source_instance_id)];
                const CommandDefinition &definition = _command_definitions[command.command_definition_id];
                RuntimeEffectPodCommand pod;
                pod.action = static_cast<RuntimeEffectPodAction>(command.action);
                pod.domain = command.domain;
                pod.opcode = command.opcode;
                pod.source_instance_id = static_cast<uint64_t>(source.id);
                pod.source_generation = source.generation;
                pod.source_handle = source.source_handle;
                pod.target_handle = command.target_handle;
                pod.target_generation = command.target_generation;
                pod.value = command.value_q16;
                pod.duration_days = command.duration_days;
                pod.stacks = command.stacks;
                pod.command_definition_id = command.command_definition_id;
                pod.command_key_hash = RuntimeEffectPodAuthority::hash_text(definition.command_key.c_str());
                pod.definition_key_hash = definition.definition_key.empty() ? 0
                    : RuntimeEffectPodAuthority::hash_text(definition.definition_key.c_str());
                pod.idempotency_key = command.idempotency_key;
                pod.effective_day = transaction.effective_day;
                pod.payload = command.payload;
                legacy_pod_commands.push_back(pod);
            }
            restored_command_arena.push_back(std::move(command));
            ++transaction.command_count;
        }
        if (builtin_family_colonization) {
            const Command *first = transaction.command_count > 0
                ? &restored_command_arena[transaction.command_begin] : nullptr;
            const bool settle_only = transaction.command_count == 1 &&
                first != nullptr && first->action == ECONOMY_COMMAND &&
                first->domain == 8 &&
                first->opcode == EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION &&
                first->command_key_id == -1 && first->command_definition_id == -1;
            const bool claim_and_settle = transaction.command_count == 2;
            if (settle_only) {
                // Own-country relocation: Economy SETTLE only.
            } else if (claim_and_settle) {
                const Command &claim = restored_command_arena[transaction.command_begin];
                const Command &settle = restored_command_arena[transaction.command_begin + 1];
                if (claim.action != COUNTRY_COMMAND || claim.domain != 7 ||
                    claim.opcode != CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY ||
                    claim.command_key_id != -1 || claim.command_definition_id != -1 ||
                    settle.action != ECONOMY_COMMAND || settle.domain != 8 ||
                    settle.opcode != EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION ||
                    settle.command_key_id != -1 || settle.command_definition_id != -1 ||
                    claim.target_handle != settle.payload[1] ||
                    claim.payload[0] != settle.payload[0])
                    return failure("pkef_colonization_transaction_shape_invalid");
            } else {
                return failure("pkef_colonization_transaction_shape_invalid");
            }
        } else if (builtin_canal_commit) {
            if (transaction.command_count != 1)
                return failure("pkef_canal_transaction_shape_invalid");
            const Command &commit = restored_command_arena[transaction.command_begin];
            if (commit.action != CUSTOM_DOMAIN_COMMAND || commit.domain != 6 ||
                commit.opcode != 2 || commit.target_handle == 0 ||
                commit.target_generation == 0 || commit.command_key_id != -1 ||
                commit.command_definition_id != -1)
                return failure("pkef_canal_transaction_shape_invalid");
        }
        if (derived_ack_mask != transaction.required_ack_mask)
            return failure("pkef_transaction_ack_mask_invalid");
        uint64_t expected_plan_hash = 1469598103934665603ULL;
        if (builtin_transaction) {
            expected_plan_hash = fnv_value(expected_plan_hash, transaction.id);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.effective_day);
        } else {
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.source_instance_id);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.source_generation);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.program_id);
            expected_plan_hash = fnv_value(expected_plan_hash,
                                           transaction.effective_day);
            if (transaction.instance_transition != TRANSITION_NONE) {
                expected_plan_hash = fnv_value(expected_plan_hash,
                    transaction.instance_transition);
                expected_plan_hash = fnv_value(expected_plan_hash,
                    transaction.transition_input_revision);
                expected_plan_hash = fnv_value(expected_plan_hash,
                    transaction.transition_fire_sequence);
                expected_plan_hash = fnv_value(expected_plan_hash,
                    transaction.transition_stack_count);
            }
        }
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command &command = restored_command_arena[
                static_cast<size_t>(transaction.command_begin) + ordinal];
            expected_plan_hash = fnv_value(expected_plan_hash, command.action);
            expected_plan_hash = fnv_value(expected_plan_hash, command.domain);
            expected_plan_hash = fnv_value(expected_plan_hash, command.opcode);
            expected_plan_hash = fnv_value(expected_plan_hash, command.target_handle);
            expected_plan_hash = fnv_value(expected_plan_hash, command.target_generation);
            if (!builtin_transaction) {
                expected_plan_hash = fnv_value(expected_plan_hash, command.value_q16);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.duration_days);
                expected_plan_hash = fnv_value(expected_plan_hash, command.stacks);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.command_key_id);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.command_definition_id);
            }
            if (!builtin_canal_commit) {
                for (int64_t payload_value : command.payload)
                    expected_plan_hash = fnv_value(expected_plan_hash,
                                                   payload_value);
            }
            expected_plan_hash = fnv_value(expected_plan_hash, command.idempotency_key);
            if (schema >= 10 && command.external_effect_id != 0) {
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.external_effect_id);
                expected_plan_hash = fnv_value(expected_plan_hash,
                                               command.external_source_id);
            }
        }
        if (legacy_pod_transaction) {
            if (RuntimeEffectPodAuthority::calculate_plan_hash(
                    transaction.source_instance_id, transaction.source_generation,
                    transaction.effective_day, legacy_pod_fire_sequence,
                    legacy_pod_commands) != legacy_pod_plan_hash)
                return failure("pkef_legacy_pod_plan_hash_invalid");
            transaction.plan_hash = expected_plan_hash;
        }
        if (expected_plan_hash != transaction.plan_hash)
            return failure("pkef_transaction_plan_hash_invalid");
        max_transaction_id = std::max(max_transaction_id, transaction.id);
        restored_transactions.push_back(std::move(transaction));
    }
    std::vector<ExternalSourceBinding> restored_bindings;
    std::unordered_map<int64_t, int32_t> restored_binding_ids;
    if (schema >= 5) {
        uint32_t binding_count = 0;
        if (!read_le(bytes, size, cursor, binding_count) ||
            binding_count > static_cast<uint32_t>(_max_instances))
            return failure("pkef_external_binding_count_invalid");
        restored_bindings.reserve(binding_count);
        for (uint32_t i = 0; i < binding_count; ++i) {
            ExternalSourceBinding binding;
            if (!read_le(bytes, size, cursor, binding.binding_id) ||
                !read_le(bytes, size, cursor, binding.generation) ||
                !read_le(bytes, size, cursor, binding.source_type) ||
                !read_le(bytes, size, cursor, binding.source_id) ||
                !read_le(bytes, size, cursor, binding.target_handle) ||
                !read_le(bytes, size, cursor, binding.target_generation) ||
                !read_le(bytes, size, cursor, binding.level) ||
                !read_le(bytes, size, cursor, binding.location) ||
                !read_le(bytes, size, cursor, binding.active) ||
                !read_le(bytes, size, cursor, binding.template_signature) ||
                !read_le(bytes, size, cursor, binding.program_hash))
                return failure("pkef_external_binding_truncated");
            if (binding.binding_id <= 0 || binding.generation == 0 ||
                binding.target_handle == 0 || binding.target_generation == 0 ||
                binding.level < -1 || binding.location > 2 || binding.active > 1 ||
                !restored_binding_ids.emplace(binding.binding_id,
                    static_cast<int32_t>(restored_bindings.size())).second)
                return failure("pkef_external_binding_invalid");
            restored_bindings.push_back(binding);
        }
    }
    uint64_t restored_player_country = 0;
    int64_t restored_next_plan_id = 1;
    int64_t restored_next_generation = 1;
    EraRewardOffer restored_offer;
    if (!read_le(bytes, size, cursor, restored_player_country) ||
        !read_le(bytes, size, cursor, restored_next_plan_id) ||
        !read_le(bytes, size, cursor, restored_next_generation) ||
        !read_le(bytes, size, cursor, restored_offer.plan_id) ||
        !read_le(bytes, size, cursor, restored_offer.generation) ||
        !read_le(bytes, size, cursor, restored_offer.pool_index) ||
        !read_le(bytes, size, cursor, restored_offer.milestone_technology) ||
        !read_le(bytes, size, cursor, restored_offer.country_handle) ||
        !read_le(bytes, size, cursor, restored_offer.country_generation) ||
        !read_le(bytes, size, cursor, restored_offer.status) ||
        !read_le(bytes, size, cursor, restored_offer.selected_choice) ||
        !read_le(bytes, size, cursor, restored_offer.transaction_id) ||
        !read_le(bytes, size, cursor, restored_offer.plan_hash) ||
        !read_string(bytes, size, cursor, restored_offer.error))
        return failure("pkef_era_reward_truncated");
    for (EraRewardAlternative &alternative : restored_offer.alternatives) {
        if (!read_le(bytes, size, cursor, alternative.option_index) ||
            !read_le(bytes, size, cursor, alternative.weight) ||
            !read_le(bytes, size, cursor, alternative.target_handle) ||
            !read_le(bytes, size, cursor, alternative.target_generation) ||
            !read_le(bytes, size, cursor, alternative.reason_count) ||
            !read_string(bytes, size, cursor, alternative.reasons[0]) ||
            !read_string(bytes, size, cursor, alternative.reasons[1]) ||
            !read_string(bytes, size, cursor, alternative.target_summary))
            return failure("pkef_era_reward_alternative_truncated");
    }
    if (restored_next_plan_id <= 0 || restored_next_generation <= 0 ||
        restored_offer.status < 0 || restored_offer.status > 4 ||
        restored_offer.pool_index < -1 ||
        restored_offer.pool_index >= static_cast<int32_t>(_era_reward_pools.size()) ||
        restored_offer.selected_choice < -1 || restored_offer.selected_choice > 2 ||
        (restored_offer.status == 0 &&
         (restored_offer.plan_id != 0 || restored_offer.transaction_id != 0)) ||
        (restored_offer.status != 0 &&
         (restored_offer.plan_id <= 0 || restored_offer.generation <= 0 ||
          restored_offer.country_handle == 0 || restored_offer.country_generation == 0)) ||
        (restored_offer.status == 1 && restored_offer.transaction_id != 0) ||
        (restored_offer.status == 2 &&
         (restored_offer.transaction_id < 0 ||
          (restored_offer.transaction_id > 0 &&
           restored_transaction_ids.find(restored_offer.transaction_id) ==
               restored_transaction_ids.end()))) ||
        (restored_offer.status == 2 && restored_offer.transaction_id == 0 &&
         (restored_offer.selected_choice < 0 || restored_offer.selected_choice > 2)))
        return failure("pkef_era_reward_identity_invalid");
    if (restored_offer.status != 0) {
        for (const EraRewardAlternative &alternative : restored_offer.alternatives) {
            if (alternative.option_index < 0 ||
                alternative.option_index >= static_cast<int32_t>(_era_reward_options.size()) ||
                alternative.weight <= 0 || alternative.target_handle == 0 ||
                alternative.target_generation == 0 ||
                alternative.reason_count < 0 || alternative.reason_count > 2)
                return failure("pkef_era_reward_alternative_invalid");
        }
    }
    if (_country_runtime != nullptr) {
        const CountryApi::EraRewardReference country_reference =
            country_api::era_reward_reference_pod(*_country_runtime);
        if (country_reference.plan_id != restored_offer.plan_id ||
            country_reference.offer_generation != restored_offer.generation ||
            country_reference.milestone_technology !=
                restored_offer.milestone_technology ||
            country_reference.status != restored_offer.status)
            return failure("era_reward_cross_section_mismatch");
    }
    if (!read_le(bytes, size, cursor, end_magic) || end_magic != SAVE_END)
        return failure("pkef_end_marker_missing");
    if (cursor != size || run_cursor > static_cast<int32_t>(restored_instances.size()) ||
        next_tx <= max_transaction_id)
        return failure("pkef_trailing_or_cursor_invalid");

    // Commit the parsed snapshot only after every bound and marker has passed.
    // A malformed/truncated save therefore cannot destroy the live runtime.
    reset_runtime_state();
    _current_day = current_day;
    _last_completed_day = last_day;
    _run_day = run_day;
    _run_cursor = candidate_cursor;
    _candidate_cursor = candidate_cursor;
    _run_candidates = std::move(restored_candidates);
    _next_transaction_id = next_tx;
    _acked_transaction_id = acked_tx;
    _next_activation_sequence = next_activation_sequence;
    _instances = std::move(restored_instances);
    _metric_values = std::move(restored_metric_values);
    _metric_present = std::move(restored_metric_present);
    _command_arena = std::move(restored_command_arena);
    for (size_t i = 0; i < _instances.size(); ++i) {
        _instances[i].metric_base = static_cast<uint32_t>(i *
            static_cast<size_t>(_metric_count));
        _instances[i].dirty_epoch = 0;
        _instances[i].schedule_token = 0;
        _instances[i].stack_decision_epoch = 0;
        _instances[i].desired_stack_count = 0;
        if (_instances[i].active)
            schedule_instance(static_cast<int32_t>(i), _instances[i].next_due_day);
    }
    _instance_ids = std::move(restored_instance_ids);
    rebuild_family_effect_groups();
    _free_instance_indices.clear();
    for (size_t i = 0; i < _instances.size(); ++i)
        if (_instances[i].id == 0)
            _free_instance_indices.push_back(static_cast<int32_t>(i));
    _transactions = std::move(restored_transactions);
    _transaction_ids.clear();
    _transaction_ids.reserve(_transactions.size());
    for (size_t i = 0; i < _transactions.size(); ++i)
        _transaction_ids[_transactions[i].id] = static_cast<int32_t>(i);
    _external_bindings = std::move(restored_bindings);
    _external_binding_ids = std::move(restored_binding_ids);
    _era_reward_player_country = restored_player_country;
    _era_reward_next_plan_id = restored_next_plan_id;
    _era_reward_next_generation = restored_next_generation;
    _era_reward_offer = std::move(restored_offer);
    rebuild_command_idempotency_index();
    // Installing a restored snapshot publishes a new peer-domain view. Keep
    // the watermark monotonic so pre-restore ACKs cannot be reused.
    advance_committed_generation();
    Dictionary out;
    out["ok"] = true;
    out["instances"] = static_cast<int32_t>(_instances.size());
    out["transactions"] = static_cast<int32_t>(_transactions.size());
    return out;
}

Dictionary EffectRuntime::clear_state() {
    if (!_configured) return failure("effect_runtime_unconfigured");
    reset_runtime_state();
    Dictionary out;
    out["ok"] = true;
    return out;
}

} // namespace pk
