#include "effect_runtime.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

bool EffectRuntime::pod_snapshot_persistence_self_test(std::string &error) const {
    auto fail = [&](const char *reason) { error = reason; return false; };
    int32_t program = -1;
    for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i) {
        const Definition &d = _definitions[i];
        if (!uses_managed_lifecycle(d) && d.behavior_id.empty() && d.command_count > 0) {
            program = i;
            break;
        }
    }
    if (program < 0) return fail("effect_persistence_fixture_program_missing");
    const Definition &d = _definitions[program];
    const CommandDefinition &c = _command_definitions[d.command_begin];
    RuntimeEffectPodSnapshot snapshot;
    snapshot.generation = 1;
    snapshot.committed_day = 12;
    snapshot.metric_values.resize(_metric_count, 0);
    RuntimeEffectPodInstance instance;
    instance.instance_id = 42;
    instance.program_id = program;
    instance.source_handle = 7;
    instance.target_handle = 9;
    instance.target_generation = 1;
    instance.next_due_day = 20;
    instance.input_revision = 7;
    instance.last_evaluated_input_revision = 7;
    instance.fire_sequence = 3;
    instance.last_acked_fire_sequence = 3;
    instance.effect_applied = 1;
    instance.applied_input_revision = 7;
    instance.applied_stack_count = 1;
    snapshot.instances.push_back(instance);
    RuntimeEffectPodCommand command;
    command.action = static_cast<RuntimeEffectPodAction>(c.action);
    command.domain = c.domain;
    command.opcode = c.opcode;
    command.source_instance_id = 42;
    command.source_generation = 1;
    command.source_handle = 7;
    command.target_handle = 9;
    command.target_generation = 1;
    command.value = c.value;
    command.duration_days = c.duration_days;
    command.stacks = c.stacks;
    command.command_definition_id = d.command_begin;
    command.command_key_hash = RuntimeEffectPodAuthority::hash_text(c.command_key.c_str());
    command.definition_key_hash = c.definition_key.empty() ? 0
        : RuntimeEffectPodAuthority::hash_text(c.definition_key.c_str());
    command.effective_day = 12;
    command.idempotency_key = 123;
    command.payload = c.payload;
    snapshot.command_arena.push_back(command);
    RuntimeEffectPodTransaction tx;
    tx.transaction_id = 5;
    tx.source_instance_id = 42;
    tx.source_generation = 1;
    tx.effective_day = 12;
    tx.command_count = 1;
    tx.fire_sequence = 3;
    tx.input_revision = 7;
    tx.required_ack_mask = RuntimeEffectPodAuthority::adapter_ack_bit(command.action);
    tx.received_ack_mask = tx.required_ack_mask;
    tx.status = RuntimeEffectPodTransactionStatus::ACKED;
    tx.plan_hash = RuntimeEffectPodAuthority::calculate_plan_hash(42, 1, 12, 3, snapshot.command_arena);
    snapshot.transactions.push_back(tx);
    EffectRuntime candidate = *this;
    candidate.reset_runtime_state();
    candidate._country_runtime = nullptr;
    if (!candidate.apply_pod_snapshot(snapshot, error)) return false;
    const PackedByteArray canonical = candidate.capture();
    if (!bool(candidate.restore(canonical).get("ok", false)) ||
        candidate.capture() != canonical)
        return fail("effect_pod_snapshot_roundtrip_failed");
    const uint64_t activation = candidate._instances[0].activation_sequence;
    snapshot.generation = 2;
    if (!candidate.apply_pod_snapshot(snapshot, error) ||
        candidate._instances[0].activation_sequence != activation)
        return fail("effect_pod_activation_changed_on_refresh");
    // Reproduce the old bridge's exact omissions, including its original POD hash.
    // Reproduce the old bridge's exact omissions, then prove the SAVE format
    // rejects them: since the v12 bump the version gate refuses anything but
    // the current schema, so the `schema == 11` migration branch is unreachable
    // by construction. Pinning fail-closed is the only assertion that still
    // means something here; the branch itself is dead code and goes away with
    // PKEF 13.
    const PackedByteArray current = candidate.capture();
    PackedByteArray legacy = current;
    const int32_t legacy_schema = 11;
    std::memcpy(legacy.ptrw() + sizeof(uint32_t), &legacy_schema,
        sizeof(int32_t));
    const Dictionary rejected_legacy = candidate.restore(legacy);
    if (bool(rejected_legacy.get("ok", true)))
        return fail("effect_legacy_pod_save_not_rejected");
    if (candidate.capture() != current)
        return fail("effect_legacy_pod_reject_not_atomic");
    return true;
}

// ── M1 acceptance gate ─────────────────────────────────────────────────────
// The worker Effect POD used to derive state through its own hand-written
// switch ordered 0=level(raw) 1=fire(raw) 2=stack 3=input_revision, while this
// runtime answers 0=level*Q16 1=fire*Q16 2=input_revision(raw) 3=remaining*Q16
// 4=stack*Q16. Authored content writes thresholds in Q16 ("level >= 2" is
// 131072), so the mismatch made every state-gated card permanently false on
// the worker and true here - a silent split brain, not a crash. Nothing caught
// it because nothing compared the two.
//
// This test walks the full input matrix through both implementations and
// requires bit-identical answers, then pins the POD's capability ceilings to be
// no narrower than this runtime's. That second check is what the catalog-wide
// POD validator needed: one card above the ceiling rejects the entire catalog,
// which costs the whole twelve-domain authority graph, not just that card.
bool EffectRuntime::pod_state_parity_self_test(std::string &error) const {
    auto fail = [&](const std::string &reason) { error = reason; return false; };

    if (RuntimeEffectPodAuthority::MAX_STATE_ID < STATE_LATCHED)
        return fail("effect_pod_state_ceiling_below_main_thread");
    // OWN_TERRITORY is the widest selector kind the main thread resolves. The
    // POD forwards whatever the main thread resolved, so it must not be
    // narrower. Derived from SELECTOR_MAX_KIND instead of a hand-copied 11:
    // adding a kind used to require remembering this line, and forgetting it
    // rejects the *entire* POD catalog (one card above the ceiling poisons
    // all of them), which is how the 7/3 regression shipped.
    if (RuntimeEffectPodAuthority::MAX_SELECTOR_KIND < SELECTOR_MAX_KIND)
        return fail("effect_pod_selector_ceiling_below_main_thread");

    // state_value() reads _current_day through a const method, so evaluate the
    // main-thread answers on a copy that is pinned to the day under test.
    const int64_t day = 1000;
    EffectRuntime main_thread = *this;
    main_thread._current_day = day;

    const int32_t levels[] = {0, 1, 2, 7};
    const uint64_t fires[] = {0, 1, 5};
    const int32_t stacks[] = {0, 1, 3, 9};
    const int64_t expires[] = {-1, 0, 2, 30};
    for (const int32_t level : levels) {
        for (const uint64_t fire : fires) {
            for (const int32_t stack : stacks) {
                for (const int64_t expiry : expires) {
                    const int64_t revision = 7 + stack;
                    Instance instance;
                    instance.level = level;
                    instance.fire_sequence = fire;
                    instance.stack_count = stack;
                    instance.input_revision = revision;
                    instance.expires_day = expiry;
                    // Set the latch on both sides: if the worker's switch is
                    // missing the STATE_LATCHED case it answers 0 here while the
                    // main thread answers Q16_ONE, and the mismatch surfaces as
                    // a named failure instead of a card that behaves differently
                    // on the two authorities.
                    instance.latched = 1;
                    RuntimeEffectPodInstance pod_instance;
                    pod_instance.level = level;
                    pod_instance.fire_sequence = fire;
                    pod_instance.stack_count = stack;
                    pod_instance.input_revision = revision;
                    pod_instance.expires_day = expiry;
                    pod_instance.latched = 1;
                    for (int32_t id = 0;
                         id <= RuntimeEffectPodAuthority::MAX_STATE_ID; ++id) {
                        const int64_t main_value =
                            main_thread.state_value(instance, id);
                        const int64_t pod_value =
                            RuntimeEffectPodAuthority::state_value(
                                pod_instance, id, day);
                        if (main_value == pod_value) continue;
                        return fail("effect_pod_state_parity_mismatch id=" +
                            std::to_string(id) + " level=" +
                            std::to_string(level) + " fire=" +
                            std::to_string(fire) + " stack=" +
                            std::to_string(stack) + " expires=" +
                            std::to_string(expiry) + " main=" +
                            std::to_string(main_value) + " pod=" +
                            std::to_string(pod_value));
                    }
                }
            }
        }
    }

    // Ids 0/1/3/4 are Q16-scaled, id 2 is a raw token, id 5 is Q16 but strictly
    // 0 or Q16_ONE. Pinning that split explicitly means a future "unify the
    // scaling" cleanup fails loudly here instead of silently re-breaking every
    // authored threshold.
    Instance probe;
    probe.level = 3;
    probe.fire_sequence = 2;
    probe.stack_count = 5;
    probe.input_revision = 9;
    probe.expires_day = day + 4;
    probe.latched = 1;
    const int64_t expected[] = {3 * Q16_ONE, 2 * Q16_ONE, 9, 4 * Q16_ONE,
                                5 * Q16_ONE, Q16_ONE};
    for (int32_t id = 0; id <= STATE_LATCHED; ++id) {
        if (main_thread.state_value(probe, id) != expected[id])
            return fail("effect_state_id_scaling_changed id=" +
                std::to_string(id));
    }
    // And the cleared side: an unlatched instance must read 0, not "absent".
    probe.latched = 0;
    if (main_thread.state_value(probe, STATE_LATCHED) != 0)
        return fail("effect_state_latched_clear_is_not_zero");

    // Depth scaling of an emitted command must be identical on both threads.
    // main_thread's path calls the same helper, so a divergence can only come
    // from the constant "one depth unit multiplies the command by one" rule
    // changing on one side; assert the shape contract directly.
    if (RuntimeEffectPodAuthority::scaled_command_stacks(1, 4, 3) != 3 ||
        RuntimeEffectPodAuthority::scaled_command_stacks(2, 0, 8) != 2 ||
        RuntimeEffectPodAuthority::scaled_command_stacks(2, 3, 8) != 6 ||
        RuntimeEffectPodAuthority::scaled_command_stacks(5, 2, 0) != 1)
        return fail("effect_command_stack_scaling_changed");

    // A5: ABI 3 pinned the latch byte's meaning; ABI 4 adds the ACKed managed
    // lifecycle state. Both are version-gated so an older payload cannot be
    // mistaken for "not applied" and silently resurrect a card row.
    //
    // ABI 2 declared and serialized the byte but nothing ever populated it
    // (no producer wrote a `latched` column, the forwarder read none), so an
    // ABI-2 snapshot says "unlatched" for a latched instance. A payload from the
    // old ABI must therefore be refused by version, not read as "latch cleared".
    if (RUNTIME_EFFECT_POD_ABI_VERSION != 4u)
        return fail("effect_pod_abi_must_be_4_for_managed_lifecycle_wire");
    if (RuntimeEffectPodSnapshot{}.abi_version != 4u)
        return fail("effect_pod_snapshot_default_abi_is_stale");
    return true;
}

uint64_t EffectRuntime::persisted_plan_hash(const Transaction &tx,
        const std::vector<Command> &arena) const {
    uint64_t hash = 1469598103934665603ULL;
    const bool builtin = tx.program_id < 0;
    if (builtin) {
        hash = fnv_value(hash, tx.id);
        hash = fnv_value(hash, tx.effective_day);
    } else {
        hash = fnv_value(hash, tx.source_instance_id);
        hash = fnv_value(hash, tx.source_generation);
        hash = fnv_value(hash, tx.program_id);
        hash = fnv_value(hash, tx.effective_day);
        if (tx.instance_transition != TRANSITION_NONE) {
            hash = fnv_value(hash, tx.instance_transition);
            hash = fnv_value(hash, tx.transition_input_revision);
            hash = fnv_value(hash, tx.transition_fire_sequence);
            hash = fnv_value(hash, tx.transition_stack_count);
        }
    }
    for (uint32_t i = 0; i < tx.command_count; ++i) {
        const Command &c = arena[static_cast<size_t>(tx.command_begin) + i];
        hash = fnv_value(hash, c.action);
        hash = fnv_value(hash, c.domain);
        hash = fnv_value(hash, c.opcode);
        hash = fnv_value(hash, c.target_handle);
        hash = fnv_value(hash, c.target_generation);
        if (!builtin) {
            hash = fnv_value(hash, c.value_q16);
            hash = fnv_value(hash, c.duration_days);
            hash = fnv_value(hash, c.stacks);
            hash = fnv_value(hash, c.command_key_id);
            hash = fnv_value(hash, c.command_definition_id);
        }
        if (tx.program_id != -2)
            for (const int64_t value : c.payload) hash = fnv_value(hash, value);
        hash = fnv_value(hash, c.idempotency_key);
        if (c.external_effect_id != 0) {
            hash = fnv_value(hash, c.external_effect_id);
            hash = fnv_value(hash, c.external_source_id);
        }
    }
    return hash;
}

PackedByteArray EffectRuntime::capture() const {
    if (!_configured) return PackedByteArray();
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<int32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<int32_t>(bytes, PROTOCOL_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash);
    append_le<int64_t>(bytes, _current_day);
    append_le<int64_t>(bytes, _last_completed_day);
    append_le<int64_t>(bytes, _run_day);
    append_le<int32_t>(bytes, _run_cursor);
    append_le<int64_t>(bytes, _next_transaction_id);
    append_le<int64_t>(bytes, _acked_transaction_id);
    append_le<uint64_t>(bytes, _next_activation_sequence);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_instances.size()));
    for (const Instance &instance : _instances) {
        append_le<int64_t>(bytes, instance.id);
        append_le<uint32_t>(bytes, instance.generation);
        append_le<int32_t>(bytes, instance.program_id);
        append_le<int32_t>(bytes, instance.source_type);
        append_le<int64_t>(bytes, instance.source_id);
        append_le<uint64_t>(bytes, instance.source_handle);
        append_le<uint64_t>(bytes, instance.target_handle);
        append_le<uint32_t>(bytes, instance.target_generation);
        append_le<int32_t>(bytes, instance.level);
        append_le<int32_t>(bytes, instance.magnitude_scale_q16);
        append_le<int64_t>(bytes, instance.next_due_day);
        append_le<int64_t>(bytes, instance.input_revision);
        append_le<int64_t>(bytes, instance.last_evaluated_input_revision);
        append_le<uint64_t>(bytes, instance.fire_sequence);
        append_le<uint8_t>(bytes, instance.active);
        append_le<int32_t>(bytes, instance.source_kind);
        append_le<int32_t>(bytes, instance.target_domain);
        append_le<int32_t>(bytes, instance.operation);
        append_le<int32_t>(bytes, instance.lifecycle);
        append_le<int32_t>(bytes, instance.duration_days);
        append_le<int32_t>(bytes, instance.stack_policy);
        append_le<int32_t>(bytes, instance.max_stacks);
        append_le<int32_t>(bytes, instance.stack_count);
        append_le<int32_t>(bytes, instance.applied_stack_count);
        append_le<int32_t>(bytes, instance.priority);
        append_le<uint64_t>(bytes, instance.activation_sequence);
        append_le<int64_t>(bytes, instance.expires_day);
        append_le<uint64_t>(bytes, instance.stack_key_hash);
        append_le<uint8_t>(bytes, instance.effect_applied);
        append_le<uint8_t>(bytes, instance.retire_requested);
        append_le<int64_t>(bytes, instance.applied_input_revision);
        append_le<uint64_t>(bytes, instance.last_acked_fire_sequence);
        // Before the metric slab, not after: the slab is a variable-length tail
        // whose length is the very next field.
        append_le<uint8_t>(bytes, instance.latched);
        append_le<uint32_t>(bytes, static_cast<uint32_t>(_metric_count));
        for (int32_t metric_id = 0; metric_id < _metric_count; ++metric_id) {
            const int64_t *value = metric_ptr(instance, metric_id);
            append_le<int64_t>(bytes, value != nullptr ? *value : 0);
        }
        for (int32_t metric_id = 0; metric_id < _metric_count; ++metric_id) {
            const size_t offset = static_cast<size_t>(instance.metric_base) +
                static_cast<size_t>(metric_id);
            append_le<uint8_t>(bytes,
                offset < _metric_present.size() ? _metric_present[offset] : 0);
        }
    }
    append_le<int32_t>(bytes, _candidate_cursor);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_run_candidates.size()));
    for (const int32_t index : _run_candidates) append_le<int32_t>(bytes, index);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_transactions.size()));
    for (const Transaction &transaction : _transactions) {
        append_le<int64_t>(bytes, transaction.id);
        append_le<int64_t>(bytes, transaction.source_instance_id);
        append_le<uint32_t>(bytes, transaction.source_generation);
        append_le<int32_t>(bytes, transaction.program_id);
        append_le<int64_t>(bytes, transaction.effective_day);
        append_le<uint64_t>(bytes, transaction.plan_hash);
        append_le<uint32_t>(bytes, transaction.required_ack_mask);
        append_le<uint32_t>(bytes, transaction.received_ack_mask);
        // Native request ids are intentionally not persisted. A save taken
        // before the Modifier safe boundary must replay the transaction from
        // PLANNED so the restored runtime can submit it again idempotently.
        const int32_t persisted_status =
            transaction.status == PREFLIGHTED &&
            (_native_bound_transaction_ids.find(transaction.id) !=
                _native_bound_transaction_ids.end() ||
             _native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end() ||
             _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
             _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end())
            ? PLANNED : transaction.status;
        append_le<int32_t>(bytes, persisted_status);
        append_le<int32_t>(bytes, transaction.instance_transition);
        append_le<int64_t>(bytes, transaction.transition_input_revision);
        append_le<uint64_t>(bytes, transaction.transition_fire_sequence);
        append_le<int32_t>(bytes, transaction.transition_stack_count);
        append_le<uint32_t>(bytes, transaction.command_count);
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            append_le<int32_t>(bytes, command->action);
            append_le<int32_t>(bytes, command->domain);
            append_le<int32_t>(bytes, command->opcode);
            append_le<uint64_t>(bytes, command->target_handle);
            append_le<uint32_t>(bytes, command->target_generation);
            append_le<int64_t>(bytes, command->value_q16);
            append_le<int32_t>(bytes, command->duration_days);
            append_le<int32_t>(bytes, command->stacks);
            append_le<uint64_t>(bytes, command->idempotency_key);
            append_le<int32_t>(bytes, command->command_key_id);
            append_le<int32_t>(bytes, command->command_definition_id);
            append_le<int64_t>(bytes, command->external_effect_id);
            append_le<int64_t>(bytes, command->external_source_id);
            for (int64_t value : command->payload) append_le<int64_t>(bytes, value);
        }
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_external_bindings.size()));
    for (const ExternalSourceBinding &binding : _external_bindings) {
        append_le<int64_t>(bytes, binding.binding_id);
        append_le<uint32_t>(bytes, binding.generation);
        append_le<int32_t>(bytes, binding.source_type);
        append_le<int64_t>(bytes, binding.source_id);
        append_le<uint64_t>(bytes, binding.target_handle);
        append_le<uint32_t>(bytes, binding.target_generation);
        append_le<int32_t>(bytes, binding.level);
        append_le<uint8_t>(bytes, binding.location);
        append_le<uint8_t>(bytes, binding.active);
        append_le<uint64_t>(bytes, binding.template_signature);
        append_le<uint64_t>(bytes, binding.program_hash);
    }
    append_le<uint64_t>(bytes, _era_reward_player_country);
    append_le<int64_t>(bytes, _era_reward_next_plan_id);
    append_le<int64_t>(bytes, _era_reward_next_generation);
    append_le<int64_t>(bytes, _era_reward_offer.plan_id);
    append_le<int64_t>(bytes, _era_reward_offer.generation);
    append_le<int32_t>(bytes, _era_reward_offer.pool_index);
    append_le<int32_t>(bytes, _era_reward_offer.milestone_technology);
    append_le<uint64_t>(bytes, _era_reward_offer.country_handle);
    append_le<uint32_t>(bytes, _era_reward_offer.country_generation);
    append_le<int32_t>(bytes, _era_reward_offer.status);
    append_le<int32_t>(bytes, _era_reward_offer.selected_choice);
    append_le<int64_t>(bytes, _era_reward_offer.transaction_id);
    append_le<uint64_t>(bytes, _era_reward_offer.plan_hash);
    append_string(bytes, _era_reward_offer.error);
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        append_le<int32_t>(bytes, alternative.option_index);
        append_le<int64_t>(bytes, alternative.weight);
        append_le<uint64_t>(bytes, alternative.target_handle);
        append_le<uint32_t>(bytes, alternative.target_generation);
        append_le<int32_t>(bytes, alternative.reason_count);
        append_string(bytes, alternative.reasons[0]);
        append_string(bytes, alternative.reasons[1]);
        append_string(bytes, alternative.target_summary);
    }
    append_le<uint32_t>(bytes, SAVE_END);
    PackedByteArray out;
    out.resize(bytes.size());
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

} // namespace pk
