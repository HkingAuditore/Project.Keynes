#include "effect_runtime_includes.inc"

namespace pk {
using namespace godot;

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

} // namespace pk
