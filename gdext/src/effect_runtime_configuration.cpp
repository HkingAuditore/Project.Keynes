#include "effect_runtime_configuration_includes.inc"

namespace pk {

using namespace godot;

namespace {

// Managed ownership is declared by the catalog (`managed_flags`). The only
// surviving meaning of the legacy "family.effect." prefix is *which* managed
// owner a declared program belongs to -- never whether it is managed at all.
// Anything using this helper to gate lifecycle/target/stack behaviour is a
// regression back to the prefix-inference era.
inline bool is_family_owned_key(const std::string &key) {
    return key.rfind("family.effect.", 0) == 0;
}

} // namespace

Dictionary EffectRuntime::configure(const Dictionary &catalog) {
    // A failed reconfigure must never leave a half-compiled catalog exposed
    // through the runtime facade. The next successful configure starts from a
    // clean lifecycle; callers must treat a failed configure as unavailable.
    _configured = false;
    _catalog_hash = 0;
    reset_runtime_state();
    if (int32_t(catalog.get("protocol_version", PROTOCOL_VERSION)) !=
        PROTOCOL_VERSION) return failure("effect_protocol_version_invalid");

    const PackedStringArray keys = get_strings(catalog, "effect_keys");
    const int32_t count = keys.size();
    if (count > MAX_DEFINITIONS) return failure("effect_definition_count_invalid");
    const PackedStringArray metric_keys = get_strings(catalog, "metric_keys");
    if (metric_keys.size() > MAX_METRICS) return failure("effect_metric_count_invalid");
    const PackedStringArray behavior_command_keys =
        get_strings(catalog, "behavior_command_keys");
    if (behavior_command_keys.size() > MAX_COMMANDS)
        return failure("effect_behavior_command_key_count_invalid");

    const PackedInt32Array versions = get_i32(catalog, "versions");
    const PackedInt32Array cadence_days = get_i32(catalog, "cadence_days");
    const PackedInt32Array max_work = get_i32(catalog, "max_work");
    const PackedByteArray enabled = get_u8(catalog, "enabled");
    const PackedStringArray behavior_keys = get_strings(catalog, "behavior_keys");
    const PackedInt32Array source_kinds = get_i32(catalog, "source_kinds");
    const PackedInt32Array target_domains = get_i32(catalog, "target_domains");
    const PackedInt32Array operations = get_i32(catalog, "operations");
    const PackedInt32Array lifecycles = get_i32(catalog, "lifecycles");
    const PackedInt32Array definition_duration_days = get_i32(catalog, "duration_days");
    const PackedInt32Array stack_policies = get_i32(catalog, "stack_policies");
    const PackedStringArray stack_keys = get_strings(catalog, "stack_keys");
    const PackedInt32Array max_stacks = get_i32(catalog, "max_stacks");
    const PackedInt32Array priorities = get_i32(catalog, "priorities");
    const PackedInt32Array target_selector_kinds = get_i32(catalog, "target_selector_kinds");
    const PackedStringArray target_selector_ids = get_strings(catalog, "target_selector_ids");
    // Optional: two ints per definition, [0] cell cap / [1] terrain-resource-
    // predicate id. Absent keeps every pre-existing catalog byte-identical.
    const PackedInt32Array target_selector_params = get_i32(
        catalog, "target_selector_params");
    // Optional: declarations of managed ownership. Absent (or empty) keeps the
    // legacy "family.effect." prefix inference so old catalogs and fixtures
    // compile untouched.
    const PackedByteArray managed_flags = get_u8(catalog, "managed_flags");
    const PackedInt32Array condition_offsets = get_i32(catalog, "condition_offsets");
    const PackedInt32Array condition_ops = get_i32(catalog, "condition_ops");
    const PackedInt32Array condition_arg0 = get_i32(catalog, "condition_arg0");
    const PackedInt64Array condition_values = get_i64(catalog, "condition_values");
    const PackedInt32Array instruction_offsets = get_i32(catalog, "instruction_offsets");
    const PackedInt32Array instruction_ops = get_i32(catalog, "instruction_ops");
    const PackedInt32Array instruction_arg0 = get_i32(catalog, "instruction_arg0");
    const PackedInt32Array instruction_arg1 = get_i32(catalog, "instruction_arg1");
    const PackedInt64Array instruction_values = get_i64(catalog, "instruction_values");
    const PackedInt32Array command_offsets = get_i32(catalog, "command_offsets");
    const PackedInt32Array command_actions = get_i32(catalog, "command_actions");
    const PackedInt32Array command_domains = get_i32(catalog, "command_domains");
    const PackedInt32Array command_opcodes = get_i32(catalog, "command_opcodes");
    const PackedInt32Array command_target_resolvers = get_i32(catalog, "command_target_resolvers");
    const PackedInt64Array command_static_targets = get_i64(catalog, "command_static_targets");
    const PackedInt32Array command_value_modes = get_i32(catalog, "command_value_modes");
    const PackedInt64Array command_values = get_i64(catalog, "command_values");
    const PackedInt32Array command_duration_days = get_i32(catalog, "command_duration_days");
    const PackedInt32Array command_stacks = get_i32(catalog, "command_stacks");
    const PackedStringArray command_keys = get_strings(catalog, "command_keys");
    const PackedStringArray command_definition_keys = get_strings(catalog, "command_definition_keys");
    const PackedInt64Array command_payload_i0 = get_i64(catalog, "command_payload_i0");
    const PackedInt64Array command_payload_i1 = get_i64(catalog, "command_payload_i1");
    const PackedInt64Array command_payload_i2 = get_i64(catalog, "command_payload_i2");
    const PackedInt64Array command_payload_i3 = get_i64(catalog, "command_payload_i3");

    if (condition_offsets.size() != count + 1 ||
        source_kinds.size() != count || target_domains.size() != count ||
        operations.size() != count || lifecycles.size() != count ||
        definition_duration_days.size() != count ||
        stack_policies.size() != count || stack_keys.size() != count ||
        max_stacks.size() != count || priorities.size() != count ||
        target_selector_kinds.size() != count || target_selector_ids.size() != count ||
        (!target_selector_params.is_empty() &&
         target_selector_params.size() != count * 2) ||
        (!managed_flags.is_empty() && managed_flags.size() != count) ||
        instruction_offsets.size() != count + 1 ||
        command_offsets.size() != count + 1 ||
        condition_ops.size() != condition_arg0.size() ||
        condition_ops.size() != condition_values.size() ||
        instruction_ops.size() != instruction_arg0.size() ||
        instruction_ops.size() != instruction_arg1.size() ||
        instruction_ops.size() != instruction_values.size() ||
        command_actions.size() != command_domains.size() ||
        command_actions.size() != command_opcodes.size() ||
        command_actions.size() != command_target_resolvers.size() ||
        command_actions.size() != command_static_targets.size() ||
        command_actions.size() != command_value_modes.size() ||
        command_actions.size() != command_values.size() ||
        command_actions.size() != command_duration_days.size() ||
        command_actions.size() != command_stacks.size() ||
        command_actions.size() != command_keys.size() ||
        command_actions.size() != command_definition_keys.size() ||
        command_actions.size() != command_payload_i0.size() ||
        command_actions.size() != command_payload_i1.size() ||
        command_actions.size() != command_payload_i2.size() ||
        command_actions.size() != command_payload_i3.size())
        return failure("effect_catalog_columns_invalid");
    auto valid_offsets = [](const PackedInt32Array &offsets, int32_t total) {
        if (offsets.is_empty() || offsets[0] != 0 || offsets[offsets.size() - 1] != total)
            return false;
        for (int32_t i = 1; i < offsets.size(); ++i) {
            if (offsets[i] < offsets[i - 1]) return false;
        }
        return true;
    };
    if (!valid_offsets(condition_offsets, condition_ops.size()) ||
        !valid_offsets(instruction_offsets, instruction_ops.size()) ||
        !valid_offsets(command_offsets, command_actions.size()))
        return failure("effect_catalog_offsets_invalid");
    if (condition_ops.size() > MAX_INSTRUCTIONS || instruction_ops.size() > MAX_INSTRUCTIONS ||
        command_actions.size() > MAX_COMMANDS)
        return failure("effect_catalog_capacity_invalid");

    _max_instances = std::max(1, int32_t(catalog.get("max_instances", 4096)));
    _max_transactions = std::max(1, int32_t(catalog.get("max_transactions", 8192)));
    _max_work_per_slice = std::max(1, int32_t(catalog.get("max_work_per_slice", 1024)));
    _max_native_modifier_commands = std::max(1, int32_t(
        catalog.get("max_native_modifier_commands", 4096)));
    if (_max_instances > 16000000 || _max_transactions > 16000000 ||
        _max_work_per_slice > 1000000 || _max_native_modifier_commands > 4000000)
        return failure("effect_runtime_capacity_invalid");

    // Optional tag predicate table (target_tag.h). A catalog without
    // `target_tags` keeps zero tags, which is what makes this additive: every
    // pre-tag catalog -- including the fixtures -- configures untouched, and
    // the territory selector falls back to its built-in predicate ids.
    _target_tags.clear();
    {
        const PackedStringArray tag_names = get_strings(catalog, "target_tags");
        if (!tag_names.is_empty()) {
            const PackedInt32Array tag_offsets = get_i32(catalog, "tag_offsets");
            const PackedInt32Array tag_metric_ids = get_i32(catalog, "tag_metric_ids");
            const PackedInt32Array tag_metric_ops = get_i32(catalog, "tag_metric_ops");
            const PackedInt32Array tag_metric_clauses =
                get_i32(catalog, "tag_metric_clauses");
            const PackedInt64Array tag_thresholds =
                get_i64(catalog, "tag_metric_thresholds_q16");
            if (tag_offsets.size() != tag_names.size() + 1 ||
                tag_metric_ids.size() != tag_metric_ops.size() ||
                tag_metric_ids.size() != tag_metric_clauses.size() ||
                tag_metric_ids.size() != tag_thresholds.size())
                return failure("target_tag_columns_invalid");
            _target_tags.names.reserve(static_cast<size_t>(tag_names.size()));
            for (int32_t i = 0; i < tag_names.size(); ++i)
                _target_tags.names.push_back(string_at(tag_names, i));
            _target_tags.offsets.assign(tag_offsets.size(), 0);
            for (int32_t i = 0; i < tag_offsets.size(); ++i)
                _target_tags.offsets[static_cast<size_t>(i)] = tag_offsets[i];
            _target_tags.rows.resize(static_cast<size_t>(tag_metric_ids.size()));
            for (int32_t i = 0; i < tag_metric_ids.size(); ++i) {
                TargetTagRow &row = _target_tags.rows[static_cast<size_t>(i)];
                row.metric_id = tag_metric_ids[i];
                row.op = tag_metric_ops[i];
                row.clause = tag_metric_clauses[i];
                row.threshold_q16 = tag_thresholds[i];
                // The sampler walks metric_keys only, so a row pointing past
                // the declared table would read 0 forever and silently turn a
                // ">= 60%" card into "never fires". Reject at compile time.
                if (row.metric_id >= metric_keys.size())
                    return failure("target_tag_metric_not_declared");
            }
            std::string tag_error;
            if (!_target_tags.valid(tag_error))
                return failure(tag_error.c_str());
        }
    }

    _metric_keys.clear();
    _metric_ids.clear();
    for (int32_t i = 0; i < metric_keys.size(); ++i) {
        const std::string key = string_at(metric_keys, i);
        if (key.empty() || !_metric_ids.emplace(key, i).second)
            return failure("effect_metric_key_invalid_or_duplicate");
        _metric_keys.push_back(key);
    }
    _metric_count = static_cast<int32_t>(_metric_keys.size());
    _behavior_command_keys.clear();
    std::unordered_set<std::string> behavior_key_seen;
    _behavior_command_keys.reserve(behavior_command_keys.size());
    for (int32_t i = 0; i < behavior_command_keys.size(); ++i) {
        const std::string key = string_at(behavior_command_keys, i);
        if (key.empty() || !behavior_key_seen.emplace(key).second)
            return failure("effect_behavior_command_key_invalid_or_duplicate");
        _behavior_command_keys.push_back(key);
    }

    _definitions.clear();
    _definition_ids.clear();
    _conditions.clear();
    _instructions.clear();
    _command_definitions.clear();
    _behavior_command_buffer.clear();
    _definitions.reserve(count);
    _conditions.reserve(condition_ops.size());
    _instructions.reserve(instruction_ops.size());
    _command_definitions.reserve(command_actions.size());
    _behavior_command_buffer.resize(std::max(1, _max_work_per_slice));
    for (int32_t i = 0; i < count; ++i) {
        Definition definition;
        definition.key = string_at(keys, i);
        definition.version = i32_at(versions, i, 1);
        definition.cadence_days = std::max(1, i32_at(cadence_days, i, 1));
        definition.max_work = std::max(1, i32_at(max_work, i, _max_work_per_slice));
        definition.enabled = u8_at(enabled, i, 1);
        definition.behavior_id = string_at(behavior_keys, i);
        if (definition.key.empty() || definition.version <= 0 ||
            !_definition_ids.emplace(definition.key, i).second)
            return failure("effect_definition_key_invalid_or_duplicate");
        definition.condition_begin = i32_at(condition_offsets, i, 0);
        definition.condition_count = i32_at(condition_offsets, i + 1, 0) - definition.condition_begin;
        definition.instruction_begin = i32_at(instruction_offsets, i, 0);
        definition.instruction_count = i32_at(instruction_offsets, i + 1, 0) - definition.instruction_begin;
        definition.command_begin = i32_at(command_offsets, i, 0);
        definition.command_count = i32_at(command_offsets, i + 1, 0) - definition.command_begin;
        definition.source_kind = i32_at(source_kinds, i, 0);
        definition.target_domain = i32_at(target_domains, i, 0);
        definition.operation = i32_at(operations, i, 0);
        definition.lifecycle = i32_at(lifecycles, i, 0);
        definition.duration_days = i32_at(definition_duration_days, i, -1);
        definition.stack_policy = i32_at(stack_policies, i, 0);
        definition.stack_key = string_at(stack_keys, i);
        definition.max_stacks = std::clamp(
            i32_at(max_stacks, i, 1), 1, MAX_AUTHORED_STACKS);
        definition.priority = i32_at(priorities, i, 0);
        definition.target_selector_kind = i32_at(target_selector_kinds, i, 0);
        definition.target_selector_id = string_at(target_selector_ids, i);
        definition.target_selector_param[0] = target_selector_params.size() == count * 2
            ? i32_at(target_selector_params, i * 2, 0) : 0;
        definition.target_selector_param[1] = target_selector_params.size() == count * 2
            ? i32_at(target_selector_params, i * 2 + 1, 0) : 0;
        definition.managed_declared = managed_flags.is_empty()
            ? is_family_owned_key(definition.key)
            : managed_flags[i] != 0;
        const PackedInt32Array prestige_magnitudes = get_i32(
            catalog, "magnitude_by_prestige_q16");
        for (int32_t tier = 0; tier < 6; ++tier) {
            const int32_t packed_index = i * 6 + tier;
            definition.magnitude_by_prestige_q16[tier] =
                prestige_magnitudes.size() == count * 6
                    ? i32_at(prestige_magnitudes, packed_index, Q16_ONE)
                    : Q16_ONE;
            if (definition.magnitude_by_prestige_q16[tier] < 0 ||
                definition.magnitude_by_prestige_q16[tier] > 4 * Q16_ONE)
                return failure("effect_prestige_magnitude_invalid");
        }
        // Kind 16 stores target_cap/radius/count_cap in one packed int, so the
        // plain "selector cap" range check would reject every valid row. Decode
        // the same fields the runtime resolves and keep the old range rule for
        // every other selector.
        const SourceCountSelector source_count_selector =
            decode_source_count_selector(definition.target_selector_param);
        const bool source_count_selector_valid =
            definition.target_selector_kind == SELECTOR_TAG_SOURCE_COUNT
                ? source_count_selector.radius >= 1 &&
                    source_count_selector.radius <= 4 &&
                    source_count_selector.cap >= 1 &&
                    source_count_selector.tag >= 0
                : true;
        if (definition.source_kind < 0 || definition.source_kind > 5 ||
            definition.target_domain < 0 || definition.target_domain > 5 ||
            definition.operation < 0 || definition.operation > 4 ||
            definition.lifecycle < 0 || definition.lifecycle > 2 ||
            definition.stack_policy < 0 || definition.stack_policy > 4 ||
            (definition.lifecycle == 1 && definition.duration_days < 1) ||
            (definition.lifecycle != 1 && definition.duration_days == 0) ||
            definition.max_stacks <= 0 || definition.target_selector_kind < 0 ||
            definition.target_selector_kind > SELECTOR_MAX_KIND ||
            definition.target_selector_param[0] < 0 ||
            // M2-2: the ceiling is per-KIND now, mirroring
            // `selector_cell_ceiling()`. Territory/source kinds report "no
            // policy cap" because their target set comes from the ownership
            // index rather than a geometric walk, and capping it at 32 is what
            // plan 22 removes.
            //
            // This must stay in step with the GDScript validator in
            // `scripts/ideology/ideology_effect_definition.gd`; the two run at
            // different layers of the same compile, so a divergence means one
            // accepts content the other rejects.
            // NOTE: the AUTHORED ceiling, not the geometric one. `param[0]` is a cap
            // and shipped content authors 8 for R1 whose walk yields 6 --
            // validating against the geometry (6) rejected that content and
            // broke the catalog. The authored ceiling stays at the legacy 32
            // for every bounded kind, which is what these validators checked
            // before the refactor.
            (!selector_authored_cap_is_unbounded(
                 definition.target_selector_kind) &&
                definition.target_selector_param[0] >
                    selector_authored_cell_ceiling(
                        definition.target_selector_kind)) ||
            // FAMILY_OWNED selects family HANDLES, not cells, so
            // `selector_cell_ceiling()` correctly reports "no CELL cap" for it. Its
            // consumer nevertheless clamps the family count to
            // `LEGACY_INSTANCE_MAX_CELLS` (`ideology_runtime.cpp:1905`), and a silent
            // clamp is exactly what a validator exists to prevent: a card authoring 40
            // families would quietly get 32 and never learn. Bound it here instead.
            (definition.target_selector_kind == SELECTOR_FAMILY_OWNED &&
                (definition.target_domain != 0 ||
                    definition.target_selector_param[0] < 1 ||
                    definition.target_selector_param[0] >
                        LEGACY_INSTANCE_MAX_CELLS ||
                    definition.target_selector_param[1] < 1)) ||
            !source_count_selector_valid ||
            (definition.lifecycle == 1 && definition.command_count == 0))
            return failure("effect_family_metadata_invalid");
        if (definition.condition_begin < 0 || definition.condition_count < 0 ||
            definition.condition_begin + definition.condition_count > condition_ops.size() ||
            definition.instruction_begin < 0 || definition.instruction_count < 0 ||
            definition.instruction_begin + definition.instruction_count > instruction_ops.size() ||
            definition.command_begin < 0 || definition.command_count < 0 ||
            definition.command_begin + definition.command_count > command_actions.size())
            return failure("effect_catalog_offsets_invalid");
        if (definition.behavior_id.empty() && definition.instruction_count == 0)
            return failure("effect_definition_has_no_program");
        _definitions.push_back(definition);
    }
    for (int32_t i = 0; i < condition_ops.size(); ++i) {
        Condition condition;
        condition.op = condition_ops[i];
        condition.arg0 = condition_arg0[i];
        condition.value = condition_values[i];
        if (condition.op < CONDITION_TRUE || condition.op > BOOL_NOT)
            return failure("effect_condition_opcode_invalid");
        if ((condition.op == METRIC_GTE || condition.op == METRIC_LTE ||
             condition.op == METRIC_EQ) &&
            (condition.arg0 < 0 || condition.arg0 >= _metric_count))
            return failure("effect_condition_metric_invalid");
        if (condition.op == STATE_GTE &&
            (condition.arg0 < 0 || condition.arg0 > STATE_LATCHED))
            return failure("effect_condition_state_invalid");
        _conditions.push_back(condition);
    }
    std::vector<int32_t> command_owner(
        static_cast<size_t>(command_actions.size()), -1);
    for (int32_t definition_id = 0;
         definition_id < static_cast<int32_t>(_definitions.size());
         ++definition_id) {
        const Definition &definition = _definitions[
            static_cast<size_t>(definition_id)];
        for (int32_t command_index = definition.command_begin;
             command_index < definition.command_begin + definition.command_count;
             ++command_index) {
            if (command_index < 0 || command_index >= command_actions.size() ||
                command_owner[static_cast<size_t>(command_index)] != -1)
                return failure("effect_command_owner_invalid");
            command_owner[static_cast<size_t>(command_index)] = definition_id;
        }
    }
    for (int32_t i = 0; i < instruction_ops.size(); ++i) {
        InstructionRow row;
        row.op = instruction_ops[i];
        row.arg0 = instruction_arg0[i];
        row.arg1 = instruction_arg1[i];
        row.value = instruction_values[i];
        if (row.op < CONST || row.op > END)
            return failure("effect_instruction_opcode_invalid");
        if (row.op == READ_METRIC && (row.arg0 < 0 || row.arg0 >= _metric_count))
            return failure("effect_instruction_metric_invalid");
        if (row.op == READ_STATE && (row.arg0 < 0 || row.arg0 > STATE_LATCHED))
            return failure("effect_instruction_state_invalid");
        if (row.op == CLAMP && row.value > static_cast<int64_t>(row.arg0))
            return failure("effect_instruction_clamp_invalid");
        _instructions.push_back(row);
    }
    for (int32_t i = 0; i < command_actions.size(); ++i) {
        CommandDefinition command;
        command.action = command_actions[i];
        command.domain = command_domains[i];
        command.opcode = command_opcodes[i];
        command.target_resolver = command_target_resolvers[i];
        command.static_target = static_cast<uint64_t>(command_static_targets[i]);
        command.value_mode = command_value_modes[i];
        command.value = command_values[i];
        command.duration_days = command_duration_days[i];
        command.stacks = std::max(1, command_stacks[i]);
        command.command_key = string_at(command_keys, i);
        command.definition_key = string_at(command_definition_keys, i);
        command.owner_program_id = command_owner[static_cast<size_t>(i)];
        if (command.action == MODIFIER_COMMAND) {
            if (command.command_key == "technology.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_TECHNOLOGY;
            else if (command.command_key == "family.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_FAMILY;
            else if (command.command_key == "person.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_PERSON;
            else if (command.command_key == "trigger.modifier")
                command.native_modifier_adapter = NATIVE_MODIFIER_TRIGGER;
            else if (command.owner_program_id >= 0) {
                const Definition &owner = _definitions[
                    static_cast<size_t>(command.owner_program_id)];
                if (owner.managed_declared)
                    command.native_modifier_adapter =
                        is_family_owned_key(owner.key)
                            ? NATIVE_MODIFIER_FAMILY_EFFECT
                            : NATIVE_MODIFIER_IDEOLOGY;
            }
        }
        command.payload = {command_payload_i0[i], command_payload_i1[i],
                           command_payload_i2[i], command_payload_i3[i]};
        std::string command_error;
        if (!native_command_shape_valid(command.action, command.domain, command.opcode,
                command.target_resolver, command.duration_days, command.stacks,
                command.value, command_error) ||
            command.value_mode < VALUE_CONSTANT || command.value_mode > VALUE_STACK_TOP ||
            command.command_key.empty() ||
            (command.action != MODIFIER_COMMAND &&
             command.action != ECONOMY_COMMAND &&
             command.definition_key.empty()) ||
            (command.target_resolver == TARGET_STATIC && command.static_target == 0))
            return failure(command_error.empty() ? "effect_command_definition_invalid"
                                                 : command_error.c_str());
        _command_definitions.push_back(command);
    }

    for (const Definition &definition : _definitions) {
        const int32_t declared_work = definition.condition_count +
            definition.instruction_count;
        if (declared_work > definition.max_work)
            return failure("effect_definition_work_exceeded");

        int32_t condition_depth = 0;
        for (int32_t i = definition.condition_begin;
             i < definition.condition_begin + definition.condition_count; ++i) {
            const int32_t op = _conditions[i].op;
            if (op == BOOL_AND || op == BOOL_OR) {
                if (condition_depth < 2) return failure("effect_condition_stack_invalid");
                --condition_depth;
            } else if (op == BOOL_NOT) {
                if (condition_depth < 1) return failure("effect_condition_stack_invalid");
            } else if (++condition_depth > MAX_STACK) {
                return failure("effect_condition_stack_invalid");
            }
        }
        if (definition.condition_count > 0 && condition_depth != 1)
            return failure("effect_condition_stack_invalid");
        if (definition.lifecycle == 1) {
            bool has_modifier_command = false;
            for (int32_t command_index = definition.command_begin;
                 command_index < definition.command_begin + definition.command_count;
                 ++command_index) {
                if (_command_definitions[static_cast<size_t>(command_index)].action ==
                    MODIFIER_COMMAND) {
                    has_modifier_command = true;
                    break;
                }
            }
            if (!has_modifier_command)
                return failure("effect_duration_requires_modifier_command");
        }
        if (definition.managed_declared) {
            const int32_t expected_modifier_domain =
                definition.target_domain == 3 ? ModifierApi::COUNTRY
                : definition.target_domain == 4 ? ModifierApi::CLIMATE
                                                : ModifierApi::ECONOMY;
            if (definition.operation == 3 && definition.condition_count == 0)
                return failure("effect_conditional_override_requires_condition");
            if ((definition.operation == 4) != (definition.lifecycle == 2))
                return failure("effect_event_operation_lifecycle_mismatch");
            bool has_event_command = false;
            for (int32_t command_index = definition.command_begin;
                 command_index < definition.command_begin + definition.command_count;
                 ++command_index) {
                const CommandDefinition &command = _command_definitions[
                    static_cast<size_t>(command_index)];
                if (definition.operation == 4) {
                    if (command.action == MODIFIER_COMMAND)
                        return failure("effect_event_operation_modifier_invalid");
                    has_event_command = true;
                } else if (command.action != MODIFIER_COMMAND ||
                           command.opcode != ModifierApi::COMMAND_APPLY ||
                           command.domain != expected_modifier_domain) {
                    return failure("effect_family_target_adapter_mismatch");
                }
            }
            if (definition.operation == 4 && !has_event_command)
                return failure("effect_event_command_missing");
            // A program that reads a metric the selection set cannot address
            // would be dropped by family_effect_metadata_pod, so the publisher
            // would never write the value and the condition would stay
            // permanently false. Fail loudly instead of silently. The ceiling
            // is now MetricMask::CAPACITY (256) rather than 64; the tighter and
            // more useful limit -- "the catalogue must actually declare this
            // id" -- is already enforced above via `_metric_count`.
            for (int32_t row = definition.condition_begin;
                 row < definition.condition_begin + definition.condition_count;
                 ++row) {
                const Condition &condition =
                    _conditions[static_cast<size_t>(row)];
                if ((condition.op == METRIC_GTE || condition.op == METRIC_LTE ||
                     condition.op == METRIC_EQ) &&
                    !MetricMask::valid(condition.arg0))
                    return failure("effect_metric_mask_overflow");
            }
            for (int32_t row = definition.instruction_begin;
                 row < definition.instruction_begin + definition.instruction_count;
                 ++row) {
                const InstructionRow &instruction =
                    _instructions[static_cast<size_t>(row)];
                if (instruction.op == READ_METRIC &&
                    !MetricMask::valid(instruction.arg0))
                    return failure("effect_metric_mask_overflow");
            }
        }

        int32_t value_depth = 0;
        for (int32_t i = definition.instruction_begin;
             i < definition.instruction_begin + definition.instruction_count; ++i) {
            const InstructionRow &row = _instructions[i];
            if (row.op == CONST || row.op == READ_METRIC || row.op == READ_STATE) {
                if (++value_depth > MAX_STACK)
                    return failure("effect_value_stack_invalid");
            } else if (row.op == ADD || row.op == SUB || row.op == MUL_Q16 ||
                       row.op == DIV_FLOOR || row.op == MIN || row.op == MAX) {
                if (value_depth < 2) return failure("effect_value_stack_invalid");
                --value_depth;
            } else if (row.op == CLAMP) {
                if (value_depth < 1) return failure("effect_value_stack_invalid");
            } else if (row.op == EMIT_COMMAND) {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count)
                    return failure("effect_command_index_invalid");
                const CommandDefinition &command =
                    _command_definitions[definition.command_begin + row.arg0];
                if (command.value_mode == VALUE_STACK_TOP && value_depth < 1)
                    return failure("effect_value_stack_invalid");
            }
        }
    }

    // An explicit stack key is a catalog-level contract across definitions.
    // Runtime grouping is keyed by the resolved target, so incompatible rows
    // must be rejected before any instance can enter the hot path.
    std::unordered_map<std::string, int32_t> family_stack_contracts;
    std::unordered_map<uint64_t, std::string> family_stack_hashes;
    for (int32_t definition_index = 0;
         definition_index < static_cast<int32_t>(_definitions.size());
         ++definition_index) {
        const Definition &definition = _definitions[
            static_cast<size_t>(definition_index)];
        if (!definition.managed_declared) continue;
        const std::string resolved_stack_key = definition.stack_key.empty()
            ? definition.key : definition.stack_key;
        const uint64_t resolved_stack_hash = fnv_string(
            1469598103934665603ULL, resolved_stack_key);
        const auto hash_inserted = family_stack_hashes.emplace(
            resolved_stack_hash, resolved_stack_key);
        if (!hash_inserted.second &&
            hash_inserted.first->second != resolved_stack_key)
            return failure("effect_family_stack_hash_collision");
        if (definition.operation == 4) {
            if (definition.stack_policy != 0 || definition.max_stacks != 1)
                return failure("effect_event_stack_policy_invalid");
            continue;
        }
        for (int32_t command_index = definition.command_begin;
             command_index < definition.command_begin + definition.command_count;
             ++command_index) {
            if (_command_definitions[static_cast<size_t>(command_index)].stacks != 1)
                return failure("effect_family_command_base_stacks_invalid");
        }
        if ((definition.stack_policy == 3 || definition.stack_policy == 4) &&
            (definition.command_count != 1 || !definition.behavior_id.empty()))
            return failure("effect_extreme_stack_policy_shape_invalid");
        if (definition.stack_key.empty()) continue;
        const auto inserted = family_stack_contracts.emplace(
            definition.stack_key, definition_index);
        if (inserted.second) continue;
        const Definition &reference = _definitions[
            static_cast<size_t>(inserted.first->second)];
        if (reference.target_domain != definition.target_domain ||
            reference.operation != definition.operation ||
            reference.lifecycle != definition.lifecycle ||
            reference.duration_days != definition.duration_days ||
            reference.stack_policy != definition.stack_policy ||
            reference.max_stacks != definition.max_stacks ||
            reference.target_selector_kind != definition.target_selector_kind ||
            reference.target_selector_id != definition.target_selector_id ||
            reference.target_selector_param[0] != definition.target_selector_param[0] ||
            reference.target_selector_param[1] != definition.target_selector_param[1] ||
            reference.command_count != definition.command_count)
            return failure("effect_family_stack_contract_mismatch");
        for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
            const CommandDefinition &lhs = _command_definitions[
                static_cast<size_t>(reference.command_begin + ordinal)];
            const CommandDefinition &rhs = _command_definitions[
                static_cast<size_t>(definition.command_begin + ordinal)];
            if (lhs.action != rhs.action || lhs.domain != rhs.domain ||
                lhs.opcode != rhs.opcode ||
                lhs.target_resolver != rhs.target_resolver ||
                lhs.static_target != rhs.static_target ||
                lhs.duration_days != rhs.duration_days ||
                lhs.stacks != rhs.stacks)
                return failure("effect_family_stack_command_mismatch");
        }
    }

    std::string era_reward_error;
    if (!compile_era_reward_catalog(catalog, era_reward_error))
        return failure(era_reward_error.c_str());

    uint64_t hash = 1469598103934665603ULL;
    hash = fnv_value(hash, PROTOCOL_VERSION);
    hash = fnv_value(hash, _max_instances);
    hash = fnv_value(hash, _max_transactions);
    hash = fnv_value(hash, _max_work_per_slice);
    hash = fnv_value(hash, _max_native_modifier_commands);
    hash = fnv_value(hash, _metric_count);
    hash = fnv_value(hash, static_cast<int32_t>(_definitions.size()));
    for (const std::string &key : _metric_keys) hash = fnv_string(hash, key);
    for (const std::string &key : _behavior_command_keys) hash = fnv_string(hash, key);
    for (const Definition &definition : _definitions) {
        hash = fnv_string(hash, definition.key);
        hash = fnv_value(hash, definition.version);
        hash = fnv_value(hash, definition.cadence_days);
        hash = fnv_value(hash, definition.max_work);
        hash = fnv_value(hash, definition.enabled);
        hash = fnv_value(hash, definition.condition_begin);
        hash = fnv_value(hash, definition.condition_count);
        hash = fnv_value(hash, definition.instruction_begin);
        hash = fnv_value(hash, definition.instruction_count);
        hash = fnv_value(hash, definition.command_begin);
        hash = fnv_value(hash, definition.command_count);
        hash = fnv_string(hash, definition.behavior_id);
        hash = fnv_value(hash, definition.source_kind);
        hash = fnv_value(hash, definition.target_domain);
        hash = fnv_value(hash, definition.operation);
        hash = fnv_value(hash, definition.lifecycle);
        hash = fnv_value(hash, definition.duration_days);
        hash = fnv_value(hash, definition.stack_policy);
        hash = fnv_string(hash, definition.stack_key);
        hash = fnv_value(hash, definition.max_stacks);
        hash = fnv_value(hash, definition.priority);
        hash = fnv_value(hash, definition.target_selector_kind);
        hash = fnv_string(hash, definition.target_selector_id);
        hash = fnv_value(hash, definition.target_selector_param[0]);
        hash = fnv_value(hash, definition.target_selector_param[1]);
        for (int32_t tier = 0; tier < 6; ++tier)
            hash = fnv_value(hash, definition.magnitude_by_prestige_q16[tier]);
    }
    for (const Condition &condition : _conditions) {
        hash = fnv_value(hash, condition.op);
        hash = fnv_value(hash, condition.arg0);
        hash = fnv_value(hash, condition.value);
    }
    for (const InstructionRow &row : _instructions) {
        hash = fnv_value(hash, row.op);
        hash = fnv_value(hash, row.arg0);
        hash = fnv_value(hash, row.arg1);
        hash = fnv_value(hash, row.value);
    }
    for (const CommandDefinition &command : _command_definitions) {
        hash = fnv_value(hash, command.action);
        hash = fnv_value(hash, command.domain);
        hash = fnv_value(hash, command.opcode);
        hash = fnv_value(hash, command.target_resolver);
        hash = fnv_value(hash, command.static_target);
        hash = fnv_value(hash, command.value_mode);
        hash = fnv_value(hash, command.value);
        hash = fnv_value(hash, command.duration_days);
        hash = fnv_value(hash, command.stacks);
        hash = fnv_string(hash, command.command_key);
        hash = fnv_string(hash, command.definition_key);
        for (int64_t payload_value : command.payload)
            hash = fnv_value(hash, payload_value);
    }
    for (const EraRewardPool &pool : _era_reward_pools) {
        hash = fnv_string(hash, pool.id);
        hash = fnv_string(hash, pool.title);
        hash = fnv_value(hash, pool.trigger_technology);
        hash = fnv_value(hash, pool.final_pool);
    }
    for (const EraRewardOption &option : _era_reward_options) {
        hash = fnv_string(hash, option.id);
        hash = fnv_string(hash, option.title);
        hash = fnv_string(hash, option.description);
        hash = fnv_string(hash, option.icon);
        hash = fnv_value(hash, option.base_weight);
        hash = fnv_value(hash, option.fallback);
        hash = fnv_value(hash, option.eligibility_code);
        hash = fnv_value(hash, option.eligibility_threshold);
        hash = fnv_value(hash, option.program_id);
    }
    for (const EraRewardRule &rule : _era_reward_rules) {
        hash = fnv_value(hash, rule.code);
        hash = fnv_value(hash, rule.threshold);
        hash = fnv_value(hash, rule.multiplier_q16);
        hash = fnv_value(hash, rule.signal_index);
        hash = fnv_value(hash, rule.route_technology_begin);
        hash = fnv_value(hash, rule.route_technology_count);
        hash = fnv_string(hash, rule.reason);
    }
    for (int32_t technology : _era_reward_route_technology_indices)
        hash = fnv_value(hash, technology);
    _catalog_hash = hash;
    _configured = true;
    reset_runtime_state();
    Dictionary out;
    out["ok"] = true;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["committed_generation"] = static_cast<int64_t>(_committed_generation);
    out["definitions"] = count;
    out["metrics"] = _metric_count;
    return out;
}


} // namespace pk
