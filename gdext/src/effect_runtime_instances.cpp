#include "effect_runtime_instances_includes.inc"

namespace pk {

using namespace godot;

int64_t *EffectRuntime::metric_ptr(Instance &instance, int32_t metric_id) {
    if (metric_id < 0 || metric_id >= _metric_count) return nullptr;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    return offset < _metric_values.size() ? &_metric_values[offset] : nullptr;
}

const int64_t *EffectRuntime::metric_ptr(const Instance &instance,
                                         int32_t metric_id) const {
    if (metric_id < 0 || metric_id >= _metric_count) return nullptr;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    return offset < _metric_values.size() ? &_metric_values[offset] : nullptr;
}

void EffectRuntime::schedule_instance(int32_t index, int64_t day) {
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (!instance.active || instance.generation == 0) return;
    const uint64_t token = _schedule_token++;
    instance.schedule_token = token;
    _due_heap.push({day, index, instance.generation, token});
    compact_due_heap_if_needed();
}

void EffectRuntime::mark_dirty(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    if (_dirty_epoch_counter == 0) {
        for (Instance &instance : _instances) instance.dirty_epoch = 0;
        _dirty_epoch_counter = 1;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.dirty_epoch == _dirty_epoch_counter) return;
    instance.dirty_epoch = _dirty_epoch_counter;
    _dirty_queue.push_back(index);
}

int32_t EffectRuntime::instance_index_for_id(int64_t id) const {
    auto it = _instance_ids.find(id);
    return it == _instance_ids.end() ? -1 : it->second;
}


bool EffectRuntime::set_metric_pod(int64_t instance_id, int32_t metric_id,
                                   int64_t revision, int64_t value_q16,
                                   std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) { error = "effect_instance_unknown"; return false; }
    if (metric_id < 0 || metric_id >= _metric_count) {
        error = "effect_snapshot_metric_invalid"; return false;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    // Two different questions, two different fields:
    //   staleness -- is this snapshot older than one already consumed?
    //   change    -- does this publish alter a value any consumer reads?
    // A frozen snapshot is published column by column, so equal revisions are
    // part of the same atomic logical row and must still be written; only
    // genuinely older snapshots are stale.
    if (revision < instance.metric_observed_revision) return true;
    if (revision > instance.metric_observed_revision)
        instance.metric_observed_revision = revision;
    int64_t *metric = metric_ptr(instance, metric_id);
    if (metric == nullptr) { error = "effect_snapshot_metric_invalid"; return false; }
    const size_t present_offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    const bool present = present_offset < _metric_present.size() &&
        _metric_present[present_offset] != 0;
    // An unchanged value is not an input change. Returning before the
    // watermark moves is what stops a daily re-publish from creating one
    // transaction per instance per day (P1-C).
    if (present && *metric == value_q16) return true;
    *metric = value_q16;
    if (present_offset < _metric_present.size()) _metric_present[present_offset] = 1;
    if (revision > instance.input_revision) {
        instance.input_revision = revision;
        mark_family_effect_group_dirty(index);
    }
    advance_committed_generation();
    return true;
}

bool EffectRuntime::instance_metric_pod(int64_t instance_id, int32_t metric_id,
                                       int64_t &out_value, bool &out_present) const {
    out_value = 0;
    out_present = false;
    if (!_configured) return false;
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) return false;
    if (metric_id < 0 || metric_id >= _metric_count) return false;
    const Instance &instance = _instances[static_cast<size_t>(index)];
    const int64_t *value = metric_ptr(instance, metric_id);
    if (value == nullptr) return false;
    out_value = *value;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    out_present = offset < _metric_present.size() && _metric_present[offset] != 0;
    return true;
}

bool EffectRuntime::set_instance_expiry_pod(int64_t instance_id,
                                            uint32_t generation,
                                            int64_t expires_day) {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return false;
    Instance &instance = _instances[static_cast<size_t>(index)];
    // A stale generation must not retarget the live instance's expiry: the
    // caller resolved this row against a different incarnation.
    if (instance.generation != generation) return false;
    instance.expires_day = expires_day;
    advance_committed_generation();
    return true;
}

bool EffectRuntime::uses_managed_lifecycle(const Definition &definition) {
    return definition.lifecycle != 0 || definition.managed_declared;
}

bool EffectRuntime::is_family_effect_instance(const Instance &instance) const {
    return instance.program_id >= 0 &&
        instance.program_id < static_cast<int32_t>(_definitions.size()) &&
        instance.operation != 4 &&
        _definitions[static_cast<size_t>(instance.program_id)]
            .managed_declared;
}

EffectRuntime::FamilyEffectGroupKey EffectRuntime::family_effect_group_key(
        const Instance &instance) const {
    return {instance.target_domain, instance.target_handle,
            instance.target_generation, instance.stack_key_hash};
}

void EffectRuntime::add_family_effect_group_member(int32_t instance_index) {
    if (instance_index < 0 ||
        instance_index >= static_cast<int32_t>(_instances.size()) ||
        !is_family_effect_instance(_instances[static_cast<size_t>(instance_index)]))
        return;
    auto &members = _family_effect_groups[family_effect_group_key(
        _instances[static_cast<size_t>(instance_index)])];
    if (std::find(members.begin(), members.end(), instance_index) == members.end())
        members.push_back(instance_index);
}

void EffectRuntime::remove_family_effect_group_member(
        int32_t instance_index, const FamilyEffectGroupKey &key) {
    auto found = _family_effect_groups.find(key);
    if (found == _family_effect_groups.end()) return;
    auto &members = found->second;
    members.erase(std::remove(members.begin(), members.end(), instance_index),
                  members.end());
    if (members.empty()) _family_effect_groups.erase(found);
}

void EffectRuntime::rebuild_family_effect_groups() {
    _family_effect_groups.clear();
    for (int32_t index = 0; index < static_cast<int32_t>(_instances.size()); ++index)
        if (_instances[static_cast<size_t>(index)].id > 0)
            add_family_effect_group_member(index);
}

void EffectRuntime::mark_family_effect_group_dirty(int32_t instance_index) {
    if (instance_index < 0 ||
        instance_index >= static_cast<int32_t>(_instances.size())) return;
    const Instance &instance = _instances[static_cast<size_t>(instance_index)];
    if (!is_family_effect_instance(instance)) {
        mark_dirty(instance_index);
        return;
    }
    const auto found = _family_effect_groups.find(
        family_effect_group_key(instance));
    if (found == _family_effect_groups.end()) {
        mark_dirty(instance_index);
        return;
    }
    for (const int32_t member : found->second) mark_dirty(member);
}

bool EffectRuntime::preview_family_effect_value(
        const Definition &definition, const Instance &instance,
        int64_t &value, std::string &error) const {
    // Bind both accessors to this instance and delegate. `state_value` reads the
    // instance's latched STATE words, which a caller without an instance has no
    // equivalent for -- the derived layer passes a constant 0 accessor, which is
    // correct because a program reading STATE is not eligible for DerivedCell in
    // the first place (`state_dependent` in cell_program_eligibility.h).
    return run_program_machine(
        definition,
        [this, &instance](int32_t metric_id) {
            return metric_value(instance, metric_id);
        },
        [this, &instance](int32_t state_id) {
            return state_value(instance, state_id);
        },
        value, error);
}

bool EffectRuntime::retire_instance_pod(int64_t instance_id,
                                        uint32_t generation,
                                        int64_t effective_day,
                                        std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) {
        // No Effect instance means no Effect-owned Modifier was committed.
        return true;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation) {
        error = "effect_instance_generation_stale";
        return false;
    }
    if (instance.active == 0) return true;
    if (instance.retire_requested != 0) return true;
    const auto pending = _pending_transactions_by_instance.find(instance.id);
    if (pending != _pending_transactions_by_instance.end() &&
        pending->second > 0) {
        instance.retire_requested = 1;
        instance.next_due_day = std::max<int64_t>(
            instance.next_due_day, effective_day + 1);
        mark_family_effect_group_dirty(index);
        schedule_instance(index, instance.next_due_day);
        return true;
    }
    return create_retirement_transaction(index, effective_day, error);
}

bool EffectRuntime::enqueue_trigger_effect_pod(
        int64_t effect_id, int64_t effective_day, int32_t trigger_id,
        uint64_t target_handle, uint32_t target_generation,
        uint64_t fire_sequence, int32_t action, int32_t domain, int32_t opcode,
        int64_t resolved_value, int32_t duration_days, int32_t stacks,
        const std::string &command_key, const std::string &definition_key,
        const std::array<int64_t, 4> &payload, std::string &error) {
    const std::string program_key = action == COUNTRY_COMMAND
        ? std::string("trigger.country.") + definition_key
        : action == ECONOMY_COMMAND
            ? std::string("trigger.economy.") + command_key
            : std::string("trigger.modifier.") + definition_key;
    return enqueue_external_effect_pod(effect_id, effective_day, 0x54524947,
        trigger_id, program_key, target_handle,
        target_handle, target_generation, fire_sequence, action, domain, opcode,
        resolved_value, duration_days, stacks, command_key, definition_key, payload, error);
}

uint64_t EffectRuntime::family_colonization_settle_idempotency_key(
        int64_t effect_id, uint32_t expedition_generation,
        uint64_t fire_sequence) const {
    return make_hash(static_cast<uint64_t>(effect_id), expedition_generation,
                     fire_sequence, 1);
}

int64_t EffectRuntime::allocate_builtin_transaction_id() {
    if (_next_transaction_id < BUILTIN_TRANSACTION_ID_BASE)
        _next_transaction_id = BUILTIN_TRANSACTION_ID_BASE;
    while (_transaction_ids.find(_next_transaction_id) != _transaction_ids.end())
        ++_next_transaction_id;
    return _next_transaction_id++;
}

bool EffectRuntime::enqueue_canal_commit_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t project_handle, uint32_t project_generation,
        uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || effective_day < 0 || source_id <= 0 ||
        project_handle == 0 || project_generation == 0) {
        error = "canal_effect_shape_invalid";
        return false;
    }
    const uint64_t idempotency = make_hash(static_cast<uint64_t>(effect_id),
        project_generation, fire_sequence, 0x43414e4cU);
    for (const Transaction &existing : _transactions) {
        const Command *first = command_at(existing, 0);
        if (first != nullptr && first->idempotency_key == idempotency) {
            if (out_transaction_id != nullptr) *out_transaction_id = existing.id;
            return true;
        }
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    Transaction transaction;
    transaction.id = allocate_builtin_transaction_id();
    transaction.source_instance_id = source_id;
    transaction.source_generation = project_generation;
    transaction.program_id = -2;
    transaction.effective_day = effective_day;

    Command commit;
    commit.action = CUSTOM_DOMAIN_COMMAND;
    commit.domain = 6;
    commit.opcode = 2; // geography.canal.commit
    commit.target_handle = project_handle;
    commit.target_generation = project_generation;
    commit.command_key_id = -1;
    commit.command_definition_id = -1;
    commit.idempotency_key = idempotency;
    append_command(transaction, commit);
    if (transaction.command_count != 1) {
        error = "canal_effect_transaction_capacity_exceeded";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.action);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.domain);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.opcode);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.target_handle);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.target_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.idempotency_key);
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

int32_t EffectRuntime::transaction_status_pod(int64_t transaction_id) const {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index >= 0 && index < static_cast<int32_t>(_transactions.size()))
        return _transactions[static_cast<size_t>(index)].status;
    return transaction_id > 0 && transaction_id <= _acked_transaction_id ? ACKED : 0;
}

bool EffectRuntime::consume_rejected_transaction_pod(
        int64_t transaction_id, int64_t source_id) {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
        return false;
    Transaction &transaction = _transactions[static_cast<size_t>(index)];
    if (transaction.source_instance_id != source_id ||
        (transaction.status != REJECTED &&
         transaction.status != RESYNC_REQUIRED)) return false;
    // The producer has converted the failure into its own durable state. Mark
    // the row terminal so the generic arena compactor can retire it without
    // retaining rejected expedition transactions for the rest of the session.
    transaction.status = ACKED;
    compact_terminal_transactions();
    return true;
}

Dictionary EffectRuntime::submit_instances(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "instance_ids");
    const PackedStringArray program_keys = get_strings(batch, "program_keys");
    const int32_t count = ids.size();
    const PackedInt32Array generations = get_i32(batch, "generations");
    const PackedInt32Array source_types = get_i32(batch, "source_types");
    const PackedInt32Array declared_source_kinds = get_i32(
        batch, "source_kinds");
    const PackedInt64Array source_ids = get_i64(batch, "source_ids");
    const PackedInt64Array source_handles = get_i64(batch, "source_handles");
    const PackedInt64Array target_handles = get_i64(batch, "target_handles");
    const PackedInt32Array target_generations = get_i32(batch, "target_generations");
    const PackedInt32Array levels = get_i32(batch, "levels");
    // Optional per-instance magnitude multiplier (L3-9). Absent means 1.0 for
    // every row, which is exactly the pre-L3-9 behaviour, so no existing caller
    // has to change.
    const PackedInt32Array magnitude_scales = get_i32(batch, "magnitude_scales");
    const PackedInt32Array submitted_stack_counts = get_i32(batch, "stack_counts");
    const PackedInt64Array activation_sequences = get_i64(
        batch, "activation_sequences");
    const PackedInt64Array next_due_days = get_i64(batch, "next_due_days");
    const PackedByteArray active = get_u8(batch, "active");
    // A5: optional latch column. Absent means 0 ("no latch"), which is the
    // pre-existing behaviour for every caller that does not carry one, so no
    // existing batch has to change. A supplied column must match the row count,
    // like the other optional columns, so a truncated column cannot latch the
    // wrong instances.
    const PackedByteArray latched_column = get_u8(batch, "latched");
    if (count <= 0 || count > _max_instances || program_keys.size() != count ||
        (!submitted_stack_counts.is_empty() && submitted_stack_counts.size() != count) ||
        (!activation_sequences.is_empty() && activation_sequences.size() != count) ||
        (!declared_source_kinds.is_empty() && declared_source_kinds.size() != count) ||
        (!magnitude_scales.is_empty() && magnitude_scales.size() != count) ||
        (!latched_column.is_empty() && latched_column.size() != count))
        return failure("effect_instance_columns_invalid");
    int32_t accepted = 0;
    int32_t rejected = 0;
    std::unordered_set<int64_t> batch_ids;
    PackedInt64Array accepted_ids;
    for (int32_t i = 0; i < count; ++i) {
        const int64_t id = ids[i];
        const int32_t program_id = definition_id_for_key(program_keys[i].utf8().get_data());
        if (id <= 0 || program_id < 0 || !batch_ids.emplace(id).second) {
            ++rejected;
            continue;
        }
        const uint32_t generation = static_cast<uint32_t>(std::max(1, i32_at(generations, i, 1)));
        const Definition &definition = _definitions[static_cast<size_t>(program_id)];
        // Shared with the worker transport path via effect_declarative_validation.h.
        // The batch columns are sparse, so read them only when the row exists.
        EffectDeclarativeFacts facts;
        facts.source_kind = definition.source_kind;
        facts.managed_declared = definition.managed_declared;
        const EffectDeclarativeReject declarative = validate_effect_declarative_row(
            facts, id, generation, !declared_source_kinds.is_empty(),
            i < declared_source_kinds.size() ? declared_source_kinds[i] : 0,
            u8_at(active, i, 1) != 0);
        if (declarative != EffectDeclarativeReject::NONE) {
            ++rejected;
            _last_error = effect_declarative_reject_token(declarative);
            continue;
        }
        const bool requested_active = u8_at(active, i, 1) != 0;
        const int32_t previous_index = instance_index_for_id(id);
        const bool was_active = previous_index >= 0 &&
            _instances[static_cast<size_t>(previous_index)].active != 0;
        const uint64_t previous_activation = previous_index >= 0
            ? _instances[static_cast<size_t>(previous_index)].activation_sequence
            : 0;
        const int64_t due_day = i64_at(next_due_days, i,
            _current_day >= 0 ? _current_day : 0);
        std::string error;
        if (!upsert_instance_pod(id, string_at(program_keys, i), generation,
                i32_at(source_types, i, 0), i64_at(source_ids, i, 0),
                static_cast<uint64_t>(i64_at(source_handles, i, 0)),
                static_cast<uint64_t>(i64_at(target_handles, i, 0)),
                static_cast<uint32_t>(std::max(0,
                    i32_at(target_generations, i, 0))),
                i32_at(levels, i, 0), due_day, requested_active, error)) {
            ++rejected;
            _last_error = error;
            continue;
        }
        const int32_t index = instance_index_for_id(id);
        if (index < 0) {
            ++rejected;
            _last_error = "effect_instance_missing_after_upsert";
            continue;
        }
        Instance &instance = _instances[static_cast<size_t>(index)];
        bool arbitration_changed = false;
        if (!submitted_stack_counts.is_empty()) {
            const int32_t requested_stacks = std::clamp(
                submitted_stack_counts[i], 1,
                definition.max_stacks);
            arbitration_changed = arbitration_changed ||
                requested_stacks != instance.stack_count;
            instance.stack_count = requested_stacks;
        }
        if (!magnitude_scales.is_empty()) {
            // Clamped to the same [0.25x, 4x] band the authoring layer enforces.
            // A scale change has to force a re-emit: the instance is already
            // `effect_applied`, and without clearing that flag the new
            // multiplier would sit unused until something else touched the row.
            const int32_t max_scale = static_cast<int32_t>(4 * Q16_ONE);
            const int32_t raw_scale = magnitude_scales[i];
            int32_t requested_scale = std::clamp(
                raw_scale, static_cast<int32_t>(Q16_ONE / 4), max_scale);
            if (definition.target_selector_kind ==
                    SELECTOR_TAG_SOURCE_COUNT) {
                const SourceCountSelector selector =
                    decode_source_count_selector(
                        definition.target_selector_param);
                const int32_t count_min_scale = static_cast<int32_t>(
                    Q16_ONE / std::clamp(selector.cap, 1, 15));
                requested_scale = std::clamp(
                    raw_scale, count_min_scale, max_scale);
            }
            if (requested_scale != instance.magnitude_scale_q16) {
                instance.magnitude_scale_q16 = requested_scale;
                instance.effect_applied = 0;
            }
        }
        if (!latched_column.is_empty()) {
            // A5: carry the evaluating side's latch across an authority flip.
            //
            // Only an explicit column writes it. Absent means "the caller does not
            // own this state", so the instance keeps whatever it had -- which is
            // what keeps a legacy caller from clearing a live latch on every
            // submit. A change does NOT force a re-emit: the latch is an input to
            // the next evaluation, not a command to replay.
            instance.latched = latched_column[i] != 0 ? 1 : 0;
        }
        const uint64_t submitted_activation = activation_sequences.is_empty()
            ? 0 : static_cast<uint64_t>(std::max<int64_t>(
                0, activation_sequences[i]));
        const bool explicit_activation = submitted_activation >
            instance.activation_sequence;
        const bool reactivated = !was_active && requested_active &&
            previous_activation != 0;
        if (explicit_activation) {
            instance.activation_sequence = submitted_activation;
            _next_activation_sequence = std::max(
                _next_activation_sequence, submitted_activation + 1);
            arbitration_changed = true;
        } else if (reactivated) {
            instance.activation_sequence = _next_activation_sequence++;
            arbitration_changed = true;
        }
        if ((explicit_activation || reactivated) &&
            definition.stack_policy == 1 && definition.lifecycle == 1) {
            instance.expires_day = due_day +
                static_cast<int64_t>(definition.duration_days);
        }
        if (arbitration_changed) mark_family_effect_group_dirty(index);
        schedule_instance(index, instance.next_due_day);
        ++accepted;
        accepted_ids.append(id);
    }
    _run_cursor = 0;
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["rejected"] = rejected;
    out["instance_ids"] = accepted_ids;
    return out;
}

Dictionary EffectRuntime::submit_snapshots(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array instance_ids = get_i64(batch, "instance_ids");
    const PackedInt64Array revisions = get_i64(batch, "revisions");
    const PackedInt32Array offsets = get_i32(batch, "metric_offsets");
    const PackedInt32Array metric_ids = get_i32(batch, "metric_ids");
    const PackedInt64Array metric_values = get_i64(batch, "metric_values_q16");
    const int32_t count = instance_ids.size();
    if (count <= 0 || offsets.size() != count + 1 ||
        metric_ids.size() != metric_values.size() ||
        offsets[0] != 0 || offsets[count] != metric_ids.size())
        return failure("effect_snapshot_columns_invalid");
    for (int32_t i = 1; i < offsets.size(); ++i) {
        if (offsets[i] < offsets[i - 1] || offsets[i] < 0 ||
            offsets[i] > metric_ids.size())
            return failure("effect_snapshot_offsets_invalid");
    }
    int32_t accepted = 0;
    for (int32_t i = 0; i < count; ++i) {
        const int32_t instance_index = instance_index_for_id(instance_ids[i]);
        if (instance_index < 0) continue;
        const int32_t begin = offsets[i];
        const int32_t end = offsets[i + 1];
        if (begin < 0 || end < begin || end > metric_ids.size())
            return failure("effect_snapshot_offsets_invalid");
        Instance &instance = _instances[instance_index];
        const int64_t revision = i64_at(revisions, i, instance.input_revision + 1);
        if (revision <= instance.input_revision) continue;
        std::fill(_metric_present.begin() + instance.metric_base,
                  _metric_present.begin() + instance.metric_base + _metric_count, 0);
        for (int32_t j = begin; j < end; ++j) {
            const int32_t metric_id = metric_ids[j];
            if (metric_id < 0 || metric_id >= _metric_count)
                return failure("effect_snapshot_metric_invalid");
            int64_t *metric = metric_ptr(instance, metric_id);
            if (metric == nullptr) return failure("effect_snapshot_metric_invalid");
            *metric = metric_values[j];
            _metric_present[static_cast<size_t>(instance.metric_base) +
                            static_cast<size_t>(metric_id)] = 1;
        }
        instance.input_revision = revision;
        mark_family_effect_group_dirty(instance_index);
        ++accepted;
    }
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["metrics_written"] = metric_values.size();
    return out;
}




void EffectRuntime::compact_due_heap_if_needed() {
    const size_t threshold = std::max<size_t>(1024, _instances.size() * 4 + 1024);
    if (_due_heap.size() <= threshold) return;
    std::priority_queue<DueNode, std::vector<DueNode>, std::greater<DueNode>> compacted;
    for (int32_t index = 0; index < static_cast<int32_t>(_instances.size()); ++index) {
        Instance &instance = _instances[static_cast<size_t>(index)];
        if (!instance.active || instance.generation == 0) continue;
        if (instance.schedule_token == 0) instance.schedule_token = _schedule_token++;
        compacted.push({instance.next_due_day, index, instance.generation,
                        instance.schedule_token});
    }
    _due_heap.swap(compacted);
}

void EffectRuntime::rebuild_run_candidates(int64_t day_index) {
    _run_candidates.clear();
    ++_dirty_epoch_counter;
    if (_dirty_epoch_counter == 0) {
        for (Instance &instance : _instances) instance.dirty_epoch = 0;
        _dirty_epoch_counter = 1;
    }
    ++_stack_decision_epoch;
    if (_stack_decision_epoch == 0) {
        for (Instance &instance : _instances)
            instance.stack_decision_epoch = 0;
        _stack_decision_epoch = 1;
    }
    while (!_due_heap.empty() && _due_heap.top().day <= day_index) {
        const DueNode node = _due_heap.top();
        _due_heap.pop();
        if (node.instance_index < 0 ||
            node.instance_index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &instance = _instances[static_cast<size_t>(node.instance_index)];
        if (!instance.active || instance.generation != node.generation ||
            instance.next_due_day > day_index ||
            instance.schedule_token != node.schedule_token) continue;
        if (instance.dirty_epoch != _dirty_epoch_counter) {
            instance.dirty_epoch = _dirty_epoch_counter;
            _run_candidates.push_back(node.instance_index);
        }
    }
    for (const int32_t index : _dirty_queue) {
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &instance = _instances[static_cast<size_t>(index)];
        if (!instance.active) continue;
        if (instance.dirty_epoch != _dirty_epoch_counter) {
            instance.dirty_epoch = _dirty_epoch_counter;
            _run_candidates.push_back(index);
        }
    }
    _dirty_queue.clear();
    std::sort(_run_candidates.begin(), _run_candidates.end(),
        [&](int32_t a, int32_t b) {
            const Instance &lhs = _instances[static_cast<size_t>(a)];
            const Instance &rhs = _instances[static_cast<size_t>(b)];
            if (lhs.program_id != rhs.program_id) return lhs.program_id < rhs.program_id;
            if (lhs.id != rhs.id) return lhs.id < rhs.id;
            return a < b;
        });
    _run_candidates.erase(std::unique(_run_candidates.begin(), _run_candidates.end()),
                          _run_candidates.end());
    _candidate_cursor = 0;
}



} // namespace pk
