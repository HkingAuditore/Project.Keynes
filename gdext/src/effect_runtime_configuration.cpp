#include "effect_runtime.h"
#include "country_api.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

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

bool EffectRuntime::compile_era_reward_catalog(const Dictionary &catalog,
                                               std::string &error) {
    _era_reward_pools.clear();
    _era_reward_options.clear();
    _era_reward_rules.clear();
    _era_reward_route_technology_indices.clear();
    _era_reward_pool_by_technology.clear();
    const PackedStringArray pool_ids = get_strings(catalog, "era_reward_pool_ids");
    // Focused Effect catalogs may intentionally omit the optional gameplay
    // extension. The production EffectDomainCatalog always supplies it and
    // the strict 11x9 validation below then applies.
    if (!catalog.has("era_reward_pool_ids")) return true;
    const auto reward_command_whitelisted = [](const CommandDefinition &command) {
        if (command.action == MODIFIER_COMMAND)
            return command.domain >= 0 && command.domain <= 3 &&
                (command.opcode == ModifierApi::COMMAND_APPLY ||
                 command.opcode == ModifierApi::COMMAND_REMOVE);
        if (command.action == COUNTRY_COMMAND)
            return command.domain == 1 &&
                command.opcode == CountryApi::COMMAND_GRANT_TECHNOLOGY;
        if (command.action == ECONOMY_COMMAND)
            return command.domain == 2 && command.opcode >= 1 && command.opcode <= 8;
        if (command.action == GAMEPLAY_COMMAND || command.action == PUBLISH_EVENT)
            return command.opcode > 0;
        return false;
    };
    const PackedStringArray pool_titles = get_strings(catalog, "era_reward_pool_titles");
    const PackedInt32Array trigger_tech = get_i32(
        catalog, "era_reward_trigger_technology_indices");
    const PackedByteArray pool_final = get_u8(catalog, "era_reward_pool_final");
    const PackedInt32Array option_offsets = get_i32(
        catalog, "era_reward_option_offsets");
    const PackedStringArray option_ids = get_strings(catalog, "era_reward_option_ids");
    const PackedStringArray option_titles = get_strings(
        catalog, "era_reward_option_titles");
    const PackedStringArray option_descriptions = get_strings(
        catalog, "era_reward_option_descriptions");
    const PackedStringArray option_icons = get_strings(
        catalog, "era_reward_option_icons");
    const PackedInt32Array option_weights = get_i32(
        catalog, "era_reward_option_weights");
    const PackedByteArray option_fallback = get_u8(
        catalog, "era_reward_option_fallback");
    const PackedInt32Array eligibility_codes = get_i32(
        catalog, "era_reward_option_eligibility_codes");
    const PackedInt64Array eligibility_thresholds = get_i64(
        catalog, "era_reward_option_eligibility_thresholds");
    const PackedInt32Array rule_offsets = get_i32(catalog, "era_reward_rule_offsets");
    const PackedInt32Array rule_codes = get_i32(catalog, "era_reward_rule_codes");
    const PackedInt64Array rule_thresholds = get_i64(
        catalog, "era_reward_rule_thresholds");
    const PackedInt32Array rule_multipliers = get_i32(
        catalog, "era_reward_rule_multipliers_q16");
    const PackedStringArray rule_reasons = get_strings(
        catalog, "era_reward_rule_reasons");
    const PackedInt32Array rule_signal_indices = get_i32(
        catalog, "era_reward_rule_signal_indices");
    const PackedInt32Array rule_route_offsets = get_i32(
        catalog, "era_reward_rule_route_technology_offsets");
    const PackedInt32Array rule_route_technologies = get_i32(
        catalog, "era_reward_rule_route_technology_indices");
    const PackedInt32Array command_offsets = get_i32(
        catalog, "era_reward_command_offsets");
    const PackedStringArray command_definition_keys = get_strings(
        catalog, "era_reward_command_definition_keys");
    const PackedStringArray command_effect_keys = get_strings(
        catalog, "era_reward_command_effect_keys");
    const PackedInt32Array selector_entity_types = get_i32(
        catalog, "era_reward_selector_entity_types");
    const PackedInt32Array selector_filter_codes = get_i32(
        catalog, "era_reward_selector_filter_codes");
    const PackedInt32Array selector_rankings = get_i32(
        catalog, "era_reward_selector_rankings");
    const PackedInt32Array selector_top_n = get_i32(
        catalog, "era_reward_selector_top_n");
    const PackedInt32Array selector_minimum = get_i32(
        catalog, "era_reward_selector_minimum");
    if (pool_ids.size() != 11 || pool_titles.size() != 11 ||
        trigger_tech.size() != 11 || pool_final.size() != 11 ||
        option_offsets.size() != 12 || option_offsets[0] != 0 ||
        option_offsets[11] != 99 || option_ids.size() != 99 ||
        option_titles.size() != 99 || option_descriptions.size() != 99 ||
        option_icons.size() != 99 || option_weights.size() != 99 ||
        option_fallback.size() != 99 || eligibility_codes.size() != 99 ||
        eligibility_thresholds.size() != 99 || rule_offsets.size() != 100 ||
        command_offsets.size() != 100 || rule_offsets[0] != 0 ||
        command_offsets[0] != 0 ||
        rule_codes.size() != rule_thresholds.size() ||
        rule_codes.size() != rule_multipliers.size() ||
        rule_codes.size() != rule_reasons.size() ||
        rule_codes.size() != rule_signal_indices.size() ||
        rule_route_offsets.size() != rule_codes.size() + 1 ||
        rule_route_offsets[0] != 0 ||
        rule_route_offsets[rule_route_offsets.size() - 1] !=
            rule_route_technologies.size() ||
        command_definition_keys.size() != command_effect_keys.size() ||
        command_effect_keys.size() != selector_entity_types.size() ||
        command_effect_keys.size() != selector_filter_codes.size() ||
        command_effect_keys.size() != selector_rankings.size() ||
        command_effect_keys.size() != selector_top_n.size() ||
        command_effect_keys.size() != selector_minimum.size()) {
        error = "era_reward_catalog_shape_invalid";
        return false;
    }
    std::unordered_set<std::string> seen;
    for (int32_t pool_index = 0; pool_index < 11; ++pool_index) {
        const int32_t begin = option_offsets[pool_index];
        const int32_t end = option_offsets[pool_index + 1];
        if (end - begin != 9 || trigger_tech[pool_index] < 0 ||
            !_era_reward_pool_by_technology.emplace(
                trigger_tech[pool_index], pool_index).second) {
            error = "era_reward_pool_shape_invalid";
            return false;
        }
        EraRewardPool pool;
        pool.id = string_at(pool_ids, pool_index);
        pool.title = string_at(pool_titles, pool_index);
        pool.trigger_technology = trigger_tech[pool_index];
        pool.final_pool = pool_final[pool_index];
        pool.option_begin = begin;
        pool.option_count = end - begin;
        if (pool.id.empty() || pool.title.empty() || !seen.emplace(pool.id).second) {
            error = "era_reward_pool_identity_invalid";
            return false;
        }
        _era_reward_pools.push_back(std::move(pool));
    }
    seen.clear();
    for (int32_t option_index = 0; option_index < 99; ++option_index) {
        if (rule_offsets[option_index] > rule_offsets[option_index + 1] ||
            command_offsets[option_index] > command_offsets[option_index + 1] ||
            command_offsets[option_index + 1] - command_offsets[option_index] < 1 ||
            command_offsets[option_index + 1] - command_offsets[option_index] > 128) {
            error = "era_reward_option_offsets_invalid";
            return false;
        }
        const int32_t command_begin = command_offsets[option_index];
        int32_t expanded_bound = 0;
        int32_t program_id = -1;
        for (int32_t row = command_begin; row < command_offsets[option_index + 1]; ++row) {
            if (row < 0 || row >= command_effect_keys.size() ||
                string_at(command_definition_keys, row).empty() ||
                selector_entity_types[row] < 0 || selector_entity_types[row] > 6 ||
                selector_filter_codes[row] < 0 ||
                selector_rankings[row] < 0 || selector_rankings[row] > 4 ||
                selector_top_n[row] < 1 || selector_top_n[row] > 32 ||
                selector_minimum[row] < 1 ||
                selector_minimum[row] > selector_top_n[row]) {
                error = "era_reward_selector_invalid";
                return false;
            }
            if (option_fallback[option_index] != 0 &&
                (selector_entity_types[row] != 0 || selector_top_n[row] != 1)) {
                error = "era_reward_fallback_target_invalid";
                return false;
            }
            expanded_bound += selector_top_n[row];
            const auto found = _definition_ids.find(string_at(command_effect_keys, row));
            if (found == _definition_ids.end() ||
                (program_id >= 0 && program_id != found->second)) {
                error = "era_reward_effect_program_missing";
                return false;
            }
            program_id = found->second;
            const Definition &reward_definition = _definitions[
                static_cast<size_t>(program_id)];
            for (int32_t command_index = reward_definition.command_begin;
                 command_index < reward_definition.command_begin +
                     reward_definition.command_count; ++command_index) {
                if (command_index < 0 ||
                    command_index >= static_cast<int32_t>(_command_definitions.size()) ||
                    !reward_command_whitelisted(_command_definitions[
                        static_cast<size_t>(command_index)])) {
                    error = "era_reward_command_not_whitelisted";
                    return false;
                }
            }
        }
        if (expanded_bound > 128 || program_id < 0) {
            error = "era_reward_expanded_command_limit_invalid";
            return false;
        }
        EraRewardOption option;
        option.id = string_at(option_ids, option_index);
        option.title = string_at(option_titles, option_index);
        option.description = string_at(option_descriptions, option_index);
        option.icon = string_at(option_icons, option_index);
        option.base_weight = option_weights[option_index];
        option.fallback = option_fallback[option_index];
        option.eligibility_code = eligibility_codes[option_index];
        option.eligibility_threshold = eligibility_thresholds[option_index];
        option.rule_begin = rule_offsets[option_index];
        option.rule_count = rule_offsets[option_index + 1] - option.rule_begin;
        option.program_id = program_id;
        if (option.id.empty() || option.title.empty() || option.base_weight <= 0 ||
            !seen.emplace(option.id).second ||
            (option.fallback != 0 && option.eligibility_code != 0)) {
            error = "era_reward_option_identity_invalid";
            return false;
        }
        _era_reward_options.push_back(std::move(option));
    }
    if (rule_offsets[99] != rule_codes.size() ||
        command_offsets[99] != command_effect_keys.size()) {
        error = "era_reward_catalog_terminal_offset_invalid";
        return false;
    }
    for (int32_t row = 0; row < rule_codes.size(); ++row) {
        if (rule_codes[row] < 0 || rule_codes[row] > 6 ||
            rule_route_offsets[row] > rule_route_offsets[row + 1] ||
            rule_multipliers[row] <= 0 || rule_multipliers[row] > 262144) {
            error = "era_reward_weight_rule_invalid";
            return false;
        }
        if ((rule_codes[row] == 5 && rule_signal_indices[row] < 0) ||
            (rule_codes[row] == 6 &&
             rule_route_offsets[row] == rule_route_offsets[row + 1])) {
            error = "era_reward_context_rule_invalid";
            return false;
        }
        _era_reward_rules.push_back({rule_codes[row], rule_thresholds[row],
            rule_multipliers[row], rule_signal_indices[row],
            rule_route_offsets[row],
            rule_route_offsets[row + 1] - rule_route_offsets[row],
            string_at(rule_reasons, row)});
    }
    _era_reward_route_technology_indices.reserve(
        static_cast<size_t>(rule_route_technologies.size()));
    for (int32_t technology : rule_route_technologies) {
        if (technology < 0) {
            error = "era_reward_route_technology_invalid";
            return false;
        }
        _era_reward_route_technology_indices.push_back(technology);
    }
    for (const EraRewardPool &pool : _era_reward_pools) {
        int32_t fallbacks = 0;
        for (int32_t i = pool.option_begin;
             i < pool.option_begin + pool.option_count; ++i)
            fallbacks += _era_reward_options[i].fallback != 0 ? 1 : 0;
        if (fallbacks != 3) {
            error = "era_reward_fallback_count_invalid";
            return false;
        }
    }
    return true;
}

bool EffectRuntime::bind_era_reward_player_country_pod(uint64_t country_handle,
                                                       std::string &error) {
    if (!_configured || _country_runtime == nullptr) {
        error = "era_reward_runtime_unavailable";
        return false;
    }
    if (country_handle == 0 ||
        !country_api::valid_handle(*_country_runtime, static_cast<int64_t>(country_handle))) {
        error = "era_reward_player_country_invalid";
        return false;
    }
    if (_era_reward_player_country != 0 &&
        _era_reward_player_country != country_handle &&
        _era_reward_offer.status != 0 && _era_reward_offer.status != 3) {
        error = "era_reward_player_rebind_while_offer_open";
        return false;
    }
    _era_reward_player_country = country_handle;
    return true;
}

bool EffectRuntime::notify_era_reward_technology_activated_pod(
        uint64_t country_handle, int32_t technology_id, int64_t day_index,
        std::string &error) {
    if (!_configured || _country_runtime == nullptr) {
        error = "era_reward_runtime_unavailable";
        return false;
    }
    if (_era_reward_player_country == 0 ||
        country_handle != _era_reward_player_country)
        return true;
    const auto found = _era_reward_pool_by_technology.find(technology_id);
    if (found == _era_reward_pool_by_technology.end()) return true;
    refresh_era_reward_offer_status();
    if (_era_reward_offer.status == 1 || _era_reward_offer.status == 2 ||
        _era_reward_offer.status == 4) {
        error = "era_reward_previous_offer_unresolved";
        return false;
    }
    return plan_era_reward_offer(found->second, country_handle, day_index, error);
}

bool EffectRuntime::plan_era_reward_offer(int32_t pool_index,
                                          uint64_t country_handle,
                                          int64_t day_index,
                                          std::string &error) {
    const auto plan_start = std::chrono::steady_clock::now();
    const NativeCountryRuntime *source = _era_reward_country_view != nullptr
        ? _era_reward_country_view : _country_runtime;
    if (pool_index < 0 || pool_index >= static_cast<int32_t>(_era_reward_pools.size()) ||
        _country_runtime == nullptr ||
        !country_api::valid_handle(*source, static_cast<int64_t>(country_handle))) {
        error = "era_reward_plan_input_invalid";
        return false;
    }
    const Dictionary country = country_api::country_snapshot(*source,
        static_cast<int64_t>(country_handle));
    const Dictionary treasury = country_api::treasury_snapshot(*source,
        static_cast<int64_t>(country_handle));
    const Dictionary research = country_api::research_snapshot(*source,
        static_cast<int64_t>(country_handle));
    const Dictionary signals_snapshot = country_api::research_signal_snapshot(*source,
        static_cast<int64_t>(country_handle));
    if (!static_cast<bool>(country.get("ok", false)) ||
        !static_cast<bool>(treasury.get("ok", false)) ||
        !static_cast<bool>(research.get("ok", false)) ||
        !static_cast<bool>(signals_snapshot.get("ok", false))) {
        error = "era_reward_frozen_snapshot_unavailable";
        return false;
    }
    const PackedInt32Array territory_cells = country.get(
        "territory_cells", PackedInt32Array());
    const int32_t territory = territory_cells.size();
    const int64_t cash = treasury.get("cash", 0);
    const int64_t completed = research.get("completed_total", 0);
    const PackedInt32Array evidence_signal_ids = signals_snapshot.get(
        "signal_ids", PackedInt32Array());
    const PackedInt32Array evidence_signal_counts = signals_snapshot.get(
        "counts", PackedInt32Array());
    PackedInt32Array signal_counts;
    int32_t maximum_signal = -1;
    for (int32_t i = 0; i < evidence_signal_ids.size(); ++i)
        maximum_signal = std::max(maximum_signal, evidence_signal_ids[i]);
    if (maximum_signal >= 0) signal_counts.resize(maximum_signal + 1);
    const PackedInt32Array technology_states = research.get(
        "technology_states", PackedInt32Array());
    int64_t signals = 0;
    for (int32_t i = 0; i < evidence_signal_ids.size(); ++i) {
        const int32_t signal = evidence_signal_ids[i];
        const int32_t count = i < evidence_signal_counts.size()
            ? evidence_signal_counts[i] : 0;
        if (signal >= 0 && signal < signal_counts.size())
            signal_counts.set(signal, count);
        signals += count;
    }
    const EraRewardPool &pool = _era_reward_pools[static_cast<size_t>(pool_index)];
    struct WeightedCandidate {
        int32_t option = -1;
        int64_t weight = 0;
        std::array<std::string, 2> reasons{};
        int32_t reason_count = 0;
    };
    std::vector<WeightedCandidate> normal;
    std::vector<WeightedCandidate> fallbacks;
    for (int32_t option_index = pool.option_begin;
         option_index < pool.option_begin + pool.option_count; ++option_index) {
        const EraRewardOption &option = _era_reward_options[
            static_cast<size_t>(option_index)];
        if (!era_reward_option_eligible(option, cash, territory, completed, signals))
            continue;
        WeightedCandidate candidate;
        candidate.option = option_index;
        candidate.weight = era_reward_option_weight(option, cash, territory,
            completed, signals, signal_counts, technology_states,
            candidate.reasons, candidate.reason_count);
        (option.fallback != 0 ? fallbacks : normal).push_back(std::move(candidate));
    }
    uint64_t seed = static_cast<uint64_t>(country_api::world_seed(*source));
    seed = fnv_string(seed, String(country.get("country_id", "")).utf8().get_data());
    seed = fnv_string(seed, pool.id);
    seed = fnv_value(seed, _era_reward_next_generation);
    std::array<WeightedCandidate, 3> selected{};
    int32_t selected_count = 0;
    while (selected_count < 3 && !normal.empty()) {
        uint64_t total = 0;
        for (const WeightedCandidate &candidate : normal)
            total += static_cast<uint64_t>(std::max<int64_t>(1, candidate.weight));
        const uint64_t pick = total > 0 ? splitmix64_next(seed) % total : 0;
        uint64_t cursor = 0;
        size_t chosen = 0;
        for (; chosen < normal.size(); ++chosen) {
            cursor += static_cast<uint64_t>(std::max<int64_t>(1, normal[chosen].weight));
            if (pick < cursor) break;
        }
        if (chosen >= normal.size()) chosen = normal.size() - 1;
        selected[selected_count++] = normal[chosen];
        normal.erase(normal.begin() + static_cast<ptrdiff_t>(chosen));
    }
    while (selected_count < 3 && !fallbacks.empty()) {
        const size_t chosen = static_cast<size_t>(
            splitmix64_next(seed) % fallbacks.size());
        selected[selected_count++] = fallbacks[chosen];
        fallbacks.erase(fallbacks.begin() + static_cast<ptrdiff_t>(chosen));
    }
    if (selected_count != 3) {
        error = "era_reward_offer_cannot_fill_three";
        return false;
    }
    EraRewardOffer offer;
    offer.plan_id = _era_reward_next_plan_id++;
    offer.generation = _era_reward_next_generation++;
    offer.pool_index = pool_index;
    offer.milestone_technology = pool.trigger_technology;
    offer.country_handle = country_handle;
    offer.country_generation = static_cast<uint32_t>(country_handle >> 32U);
    offer.status = 1;
    offer.plan_hash = 1469598103934665603ULL;
    offer.plan_hash = fnv_value(offer.plan_hash, offer.plan_id);
    offer.plan_hash = fnv_value(offer.plan_hash, offer.generation);
    offer.plan_hash = fnv_value(offer.plan_hash, day_index);
    offer.plan_hash = fnv_string(offer.plan_hash, pool.id);
    for (int32_t i = 0; i < 3; ++i) {
        EraRewardAlternative &alternative = offer.alternatives[i];
        alternative.option_index = selected[i].option;
        alternative.weight = selected[i].weight;
        alternative.target_handle = country_handle;
        alternative.target_generation = offer.country_generation;
        alternative.reasons = selected[i].reasons;
        alternative.reason_count = selected[i].reason_count;
        alternative.target_summary = String(country.get("country_name", "")).utf8().get_data();
        const EraRewardOption &option = _era_reward_options[
            static_cast<size_t>(alternative.option_index)];
        offer.plan_hash = fnv_string(offer.plan_hash, option.id);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.weight);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.target_handle);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.target_generation);
        for (int32_t reason = 0; reason < alternative.reason_count; ++reason)
            offer.plan_hash = fnv_string(offer.plan_hash, alternative.reasons[reason]);
    }
    _era_reward_offer = std::move(offer);
    _last_era_reward_expanded_commands = 0;
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        const int32_t option_index = alternative.option_index;
        if (option_index < 0 ||
            option_index >= static_cast<int32_t>(_era_reward_options.size()))
            continue;
        const int32_t program_id = _era_reward_options[
            static_cast<size_t>(option_index)].program_id;
        if (program_id >= 0 && program_id < static_cast<int32_t>(_definitions.size()))
            _last_era_reward_expanded_commands += _definitions[
                static_cast<size_t>(program_id)].command_count;
    }
    _last_era_reward_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_start).count();
    ++_era_reward_offers_planned;
    country_api::set_era_reward_reference_pod(*_country_runtime,
        _era_reward_offer.plan_id, _era_reward_offer.generation,
        _era_reward_offer.milestone_technology, _era_reward_offer.status);
    return true;
}

Dictionary EffectRuntime::choose_era_reward(int64_t offer_generation,
                                             int32_t choice_index,
                                             int64_t effective_day,
                                             bool host_commit) {
    refresh_era_reward_offer_status();
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (_era_reward_offer.status != 1 ||
        _era_reward_offer.generation != offer_generation)
        return failure("era_reward_offer_generation_stale");
    if (choice_index < 0 || choice_index >= 3 || effective_day < 0)
        return failure("era_reward_choice_invalid");
    const EraRewardAlternative &alternative =
        _era_reward_offer.alternatives[static_cast<size_t>(choice_index)];
    if (alternative.option_index < 0 ||
        alternative.option_index >= static_cast<int32_t>(_era_reward_options.size()))
        return failure("era_reward_frozen_alternative_invalid");
    const EraRewardOption &option = _era_reward_options[
        static_cast<size_t>(alternative.option_index)];
    if (option.program_id < 0 ||
        option.program_id >= static_cast<int32_t>(_definitions.size()))
        return failure("era_reward_program_invalid");
    const Definition &definition = _definitions[static_cast<size_t>(option.program_id)];
    if (host_commit) {
        _era_reward_offer.selected_choice = choice_index;
        std::vector<EraRewardModifierCommand> commands;
        std::string error;
        if (!era_reward_selected_modifier_commands(commands, error)) {
            _era_reward_offer.selected_choice = -1;
            return failure(error.c_str());
        }
        _era_reward_offer.status = 2;
        _era_reward_offer.transaction_id = 0;
        if (_country_runtime != nullptr)
            country_api::set_era_reward_reference_pod(*_country_runtime,
                _era_reward_offer.plan_id, _era_reward_offer.generation,
                _era_reward_offer.milestone_technology, _era_reward_offer.status);
        Dictionary out;
        out["ok"] = true;
        out["offer_generation"] = offer_generation;
        out["choice_index"] = choice_index;
        out["transaction_id"] = 0;
        return out;
    }
    const int64_t instance_id = static_cast<int64_t>(
        0x4552410000000000ULL | (static_cast<uint64_t>(_era_reward_offer.plan_id) &
                                0x000000ffffffffffULL));
    std::string error;
    if (!upsert_instance_pod(instance_id, definition.key, 1, ERA_REWARD_SOURCE_TYPE,
            _era_reward_offer.generation, _era_reward_offer.country_handle,
            alternative.target_handle, alternative.target_generation, 0,
            effective_day, false, error))
        return failure(error.c_str());
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions)
            return failure("effect_transaction_capacity_exceeded");
    }
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = instance_id;
    transaction.source_generation = 1;
    transaction.program_id = option.program_id;
    transaction.effective_day = effective_day;
    for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
        const int32_t command_definition_id = definition.command_begin + ordinal;
        const CommandDefinition &source = _command_definitions[
            static_cast<size_t>(command_definition_id)];
        Command command;
        command.action = source.action;
        command.domain = source.domain;
        command.opcode = source.opcode;
        command.target_handle = alternative.target_handle;
        command.target_generation = alternative.target_generation;
        command.value_q16 = source.value;
        command.duration_days = source.duration_days;
        command.stacks = source.stacks;
        command.command_key_id = command_definition_id;
        command.command_definition_id = command_definition_id;
        command.payload = source.payload;
        command.idempotency_key = make_hash(
            static_cast<uint64_t>(instance_id), 1,
            static_cast<uint64_t>(_era_reward_offer.generation), ordinal);
        append_command(transaction, command);
    }
    if (transaction.command_count == 0 || transaction.command_count > 128)
        return failure("era_reward_transaction_command_count_invalid");
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_definition_id);
        for (int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->idempotency_key);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    _era_reward_offer.status = 2;
    _era_reward_offer.selected_choice = choice_index;
    _era_reward_offer.transaction_id = _transactions.back().id;
    if (_country_runtime != nullptr)
        country_api::set_era_reward_reference_pod(*_country_runtime,
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
    Dictionary out;
    out["ok"] = true;
    out["offer_generation"] = offer_generation;
    out["choice_index"] = choice_index;
    out["transaction_id"] = _era_reward_offer.transaction_id;
    return out;
}

void EffectRuntime::settle_era_reward_selection_pod(bool ok, const char *error) {
    if (!era_reward_host_selection_pending()) return;
    _era_reward_offer.status = ok ? 3 : 4;
    if (!ok) _era_reward_offer.error = error != nullptr && error[0] != '\0'
        ? error : "era_reward_transaction_rejected";
    if (_country_runtime != nullptr)
        country_api::set_era_reward_reference_pod(*_country_runtime,
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
}

void EffectRuntime::refresh_era_reward_offer_status() {
    if (_era_reward_offer.status != 2 || _era_reward_offer.transaction_id <= 0)
        return;
    const int32_t status = transaction_status_pod(
        _era_reward_offer.transaction_id);
    if (status == ACKED) {
        _era_reward_offer.status = 3;
    } else if (status == REJECTED || status == RESYNC_REQUIRED || status == 0) {
        _era_reward_offer.status = 4;
        _era_reward_offer.error = status == RESYNC_REQUIRED
            ? "era_reward_resync_required" : "era_reward_transaction_rejected";
    }
    if (_country_runtime != nullptr &&
        (_era_reward_offer.status == 3 || _era_reward_offer.status == 4))
        country_api::set_era_reward_reference_pod(*_country_runtime,
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
}

} // namespace pk
