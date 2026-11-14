#include "effect_runtime.h"
#include "country_api.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

namespace {

// Effect content has two domain concepts. `Command::domain` names the target
// domain (and, for Modifier, its subdomain). ACKs instead belong to the native
// adapter crossing a distinct safe boundary.
inline uint32_t native_adapter_ack_bit(int32_t action) {
    if (action < EffectRuntime::MODIFIER_COMMAND ||
        action > EffectRuntime::CUSTOM_DOMAIN_COMMAND)
        return 0;
    return 1u << static_cast<uint32_t>(action - EffectRuntime::MODIFIER_COMMAND);
}

} // namespace

bool EffectRuntime::family_effect_metadata_pod(
        const std::string &program_key, FamilyEffectMetadataPod &out) const {
    const int32_t definition_id = definition_id_for_key(program_key);
    if (definition_id < 0 ||
        definition_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    const Definition &definition = _definitions[
        static_cast<size_t>(definition_id)];
    if (!definition.managed_declared) return false;
    out = FamilyEffectMetadataPod{};
    out.source_kind = definition.source_kind;
    out.target_domain = definition.target_domain;
    out.operation = definition.operation;
    out.lifecycle = definition.lifecycle;
    out.duration_days = definition.duration_days;
    out.stack_policy = definition.stack_policy;
    out.max_stacks = definition.max_stacks;
    out.priority = definition.priority;
    out.target_selector_kind = definition.target_selector_kind;
    out.target_selector_id = definition.target_selector_id;
    out.target_selector_param[0] = definition.target_selector_param[0];
    out.target_selector_param[1] = definition.target_selector_param[1];
    out.stack_key_hash = fnv_string(1469598103934665603ULL,
        definition.stack_key.empty() ? definition.key : definition.stack_key);
    for (int32_t tier = 0; tier < 6; ++tier)
        out.magnitude_by_prestige_q16[tier] =
            definition.magnitude_by_prestige_q16[tier];
    auto include_metric = [&](int32_t metric_id) {
        // MetricMask::set() ignores out-of-range ids, which the compile-time
        // guard above already rejected; keeping the check here too means a
        // program that somehow bypassed it publishes nothing rather than
        // publishing the wrong column.
        if (metric_id < EconomyApi::FAMILY_METRIC_COUNT)
            out.metric_mask.set(metric_id);
        else
            out.scalar_mask.set(metric_id);
    };
    out.condition_count = definition.condition_count;
    for (int32_t row = definition.condition_begin;
         row < definition.condition_begin + definition.condition_count; ++row) {
        const Condition &condition = _conditions[static_cast<size_t>(row)];
        if (condition.op == STATE_GTE) out.condition_reads_state = true;
        if (condition.op == METRIC_GTE || condition.op == METRIC_LTE ||
            condition.op == METRIC_EQ) {
            include_metric(condition.arg0);
            auto push_boundary = [&](int64_t boundary) {
                if (out.metric_threshold_count >=
                        FamilyEffectMetadataPod::METRIC_THRESHOLD_CAP) {
                    // Truncating silently would leave a boundary unobserved while
                    // still bucketing the metric -- worse than not bucketing at
                    // all, because the miss is invisible.
                    if (condition.arg0 < EconomyApi::FAMILY_METRIC_COUNT)
                        out.exact_metric_mask.set(condition.arg0);
                    return;
                }
                // Economy consumes thresholds for revision bucketing. Ideology
                // scalars live above that boundary and have no Economy consumer,
                // but this skip must not abandon later conditions/instructions.
                if (condition.arg0 < EconomyApi::FAMILY_METRIC_COUNT) {
                    const int32_t slot = out.metric_threshold_count++;
                    out.metric_threshold_ids[slot] = condition.arg0;
                    out.metric_threshold_values[slot] = boundary;
                }
            };
            if (condition.op == METRIC_GTE) {
                push_boundary(condition.value);
            } else if (condition.op == METRIC_LTE) {
                push_boundary(condition.value + 1);
            } else {  // METRIC_EQ flips on both sides
                push_boundary(condition.value);
                push_boundary(condition.value + 1);
            }
        }
    }
    for (int32_t row = definition.instruction_begin;
         row < definition.instruction_begin + definition.instruction_count; ++row) {
        const InstructionRow &instruction = _instructions[static_cast<size_t>(row)];
        if (instruction.op == READ_METRIC) {
            include_metric(instruction.arg0);
            // A Ramp consumes the continuous value: bucketing it would quantise
            // the card's own strength, which is a silent numeric change.
            if (instruction.arg0 < EconomyApi::FAMILY_METRIC_COUNT)
                out.exact_metric_mask.set(instruction.arg0);
        }
    }
    return true;
}

// The stack machine itself, parameterised on where metric reads come from.
//
// Extracted so a caller with its own per-cell samples can run the SAME bytecode
// without an `Instance` (plan §15.5: a Ramp must stay a live function of its
// metric, and reimplementing the instruction set for the derived layer would be a
// second evaluator to keep in step).
bool EffectRuntime::run_program_machine(
        const Definition &definition,
        const std::function<int64_t(int32_t)> &metric_accessor,
        const std::function<int64_t(int32_t)> &state_accessor,
        int64_t &value, std::string &error) const {
    std::array<int64_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t end = definition.instruction_begin +
        definition.instruction_count;
    for (int32_t row_index = definition.instruction_begin;
         row_index < end; ++row_index) {
        const InstructionRow &row = _instructions[static_cast<size_t>(row_index)];
        switch (row.op) {
            case CONST:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = row.value;
                break;
            case READ_METRIC:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = metric_accessor(row.arg0);
                break;
            case READ_STATE:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = state_accessor(row.arg0);
                break;
            case ADD:
            case SUB:
            case MUL_Q16:
            case DIV_FLOOR:
            case MIN:
            case MAX:
                if (sp < 2) { error = "effect_value_stack_underflow"; return false; }
                if (row.op == ADD) stack[sp - 2] = saturating_add(stack[sp - 2], stack[sp - 1]);
                else if (row.op == SUB) stack[sp - 2] = saturating_sub(stack[sp - 2], stack[sp - 1]);
                else if (row.op == MUL_Q16) stack[sp - 2] = mul_q16(stack[sp - 2], stack[sp - 1]);
                else if (row.op == DIV_FLOOR) {
                    if (stack[sp - 1] == 0) { error = "effect_division_by_zero"; return false; }
                    const int64_t quotient = floor_div(stack[sp - 2], stack[sp - 1]);
                    if (quotient > std::numeric_limits<int64_t>::max() / Q16_ONE ||
                        quotient < std::numeric_limits<int64_t>::min() / Q16_ONE) {
                        error = "effect_division_overflow";
                        return false;
                    }
                    stack[sp - 2] = quotient * Q16_ONE;
                } else if (row.op == MIN) {
                    stack[sp - 2] = std::min(stack[sp - 2], stack[sp - 1]);
                } else {
                    stack[sp - 2] = std::max(stack[sp - 2], stack[sp - 1]);
                }
                --sp;
                break;
            case CLAMP:
                if (sp < 1) { error = "effect_value_stack_underflow"; return false; }
                stack[sp - 1] = std::max(row.value, std::min(
                    stack[sp - 1], static_cast<int64_t>(row.arg0)));
                break;
            case EMIT_COMMAND: {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count) {
                    error = "effect_command_index_invalid";
                    return false;
                }
                const CommandDefinition &command = _command_definitions[
                    static_cast<size_t>(definition.command_begin + row.arg0)];
                value = command.value_mode == VALUE_STACK_TOP
                    ? (sp > 0 ? stack[sp - 1] : 0) : command.value;
                return true;
            }
            case END:
                break;
            default:
                error = "effect_instruction_opcode_invalid";
                return false;
        }
    }
    error = "effect_stack_policy_value_missing";
    return false;
}

bool EffectRuntime::resolve_family_effect_group(
        int32_t instance_index, int64_t day, std::string &error) {
    if (instance_index < 0 ||
        instance_index >= static_cast<int32_t>(_instances.size())) {
        error = "effect_instance_unknown";
        return false;
    }
    Instance &requested = _instances[static_cast<size_t>(instance_index)];
    if (!is_family_effect_instance(requested)) {
        requested.stack_decision_epoch = _stack_decision_epoch;
        requested.desired_stack_count = std::max(1, requested.stack_count);
        return true;
    }
    if (requested.stack_decision_epoch == _stack_decision_epoch) return true;
    const auto found = _family_effect_groups.find(
        family_effect_group_key(requested));
    if (found == _family_effect_groups.end()) {
        requested.stack_decision_epoch = _stack_decision_epoch;
        requested.desired_stack_count = 0;
        return true;
    }
    _family_effect_candidate_scratch.clear();
    for (const int32_t member_index : found->second) {
        if (member_index < 0 ||
            member_index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &member = _instances[static_cast<size_t>(member_index)];
        member.stack_decision_epoch = _stack_decision_epoch;
        member.desired_stack_count = 0;
        if (!member.active || member.retire_requested != 0 ||
            member.program_id < 0 ||
            member.program_id >= static_cast<int32_t>(_definitions.size()))
            continue;
        const Definition &definition = _definitions[
            static_cast<size_t>(member.program_id)];
        if (!definition.enabled ||
            (definition.lifecycle == 1 && member.expires_day >= 0 &&
             day >= member.expires_day) ||
            !evaluate_condition(definition, member))
            continue;
        _family_effect_candidate_scratch.push_back(member_index);
    }
    if (_family_effect_candidate_scratch.empty()) return true;
    const int32_t policy = requested.stack_policy;
    const int32_t group_cap = std::max(1, requested.max_stacks);
    auto stable_better = [&](int32_t lhs_index, int32_t rhs_index,
                             bool activation_first) {
        const Instance &lhs = _instances[static_cast<size_t>(lhs_index)];
        const Instance &rhs = _instances[static_cast<size_t>(rhs_index)];
        if (activation_first && lhs.activation_sequence != rhs.activation_sequence)
            return lhs.activation_sequence > rhs.activation_sequence;
        if (lhs.priority != rhs.priority) return lhs.priority > rhs.priority;
        if (!activation_first && lhs.activation_sequence != rhs.activation_sequence)
            return lhs.activation_sequence > rhs.activation_sequence;
        return lhs.id < rhs.id;
    };
    if (policy == 2) { // ADD_STACK.
        std::sort(_family_effect_candidate_scratch.begin(),
                  _family_effect_candidate_scratch.end(),
                  [&](int32_t lhs, int32_t rhs) {
                      return stable_better(lhs, rhs, false);
                  });
        int32_t remaining = group_cap;
        for (const int32_t member_index : _family_effect_candidate_scratch) {
            Instance &member = _instances[static_cast<size_t>(member_index)];
            int32_t member_cap = std::max(1, member.stack_count);
            if (member.program_id >= 0 &&
                member.program_id < static_cast<int32_t>(_definitions.size()) &&
                _definitions[static_cast<size_t>(member.program_id)].key ==
                    "family.effect.century_shop") {
                static constexpr int32_t kCenturyShopMaxStacks[6] = {
                    2, 2, 3, 4, 5, 6
                };
                const int32_t tier_cap =
                    kCenturyShopMaxStacks[std::clamp(member.level, 0, 5)];
                const int32_t elapsed_decades = _current_day > 0
                    ? std::max<int32_t>(1,
                        static_cast<int32_t>(_current_day / 3650))
                    : std::max(1, member.stack_count);
                member_cap = std::min(tier_cap,
                    std::max(member.stack_count, elapsed_decades));
            }
            const int32_t allocated = std::min(remaining, member_cap);
            member.desired_stack_count = allocated;
            remaining -= allocated;
            if (remaining <= 0) break;
        }
        return true;
    }
    int32_t winner = _family_effect_candidate_scratch.front();
    int64_t winner_value = 0;
    if (policy == 3 || policy == 4) { // MAX / MIN.
        const Instance &first = _instances[static_cast<size_t>(winner)];
        if (!preview_family_effect_value(
                _definitions[static_cast<size_t>(first.program_id)], first,
                winner_value, error)) return false;
    }
    for (size_t i = 1; i < _family_effect_candidate_scratch.size(); ++i) {
        const int32_t candidate_index = _family_effect_candidate_scratch[i];
        bool choose = false;
        if (policy == 3 || policy == 4) {
            const Instance &candidate = _instances[
                static_cast<size_t>(candidate_index)];
            int64_t candidate_value = 0;
            if (!preview_family_effect_value(
                    _definitions[static_cast<size_t>(candidate.program_id)],
                    candidate, candidate_value, error)) return false;
            choose = policy == 3 ? candidate_value > winner_value
                                 : candidate_value < winner_value;
            if (candidate_value == winner_value)
                choose = stable_better(candidate_index, winner, false);
            if (choose) winner_value = candidate_value;
        } else {
            choose = stable_better(candidate_index, winner, policy == 1);
        }
        if (choose) winner = candidate_index;
    }
    Instance &selected = _instances[static_cast<size_t>(winner)];
    selected.desired_stack_count = std::min(
        group_cap, std::max(1, selected.stack_count));
    return true;
}

bool EffectRuntime::evaluate_program_magnitude_for_metrics(
        const std::string &program_key,
        const int64_t *metric_values, int32_t metric_count,
        int64_t &out_value, std::string &error) const {
    error.clear();
    out_value = 0;
    if (metric_values == nullptr || metric_count <= 0) {
        error = "effect_magnitude_metrics_missing";
        return false;
    }
    const Definition *definition = nullptr;
    for (const Definition &candidate : _definitions) {
        if (candidate.key == program_key) {
            definition = &candidate;
            break;
        }
    }
    if (definition == nullptr) {
        error = "effect_program_not_found";
        return false;
    }
    // No runtime state is mutated: the accessor closes over the caller's samples.
    // An earlier version swapped `_metric_values` with a `const_cast`; that would
    // have been a data race under the worker path (plan §8.1).
    return run_program_machine(
        *definition,
        [metric_values, metric_count](int32_t metric_id) -> int64_t {
            if (metric_id < 0 || metric_id >= metric_count) return 0;
            return metric_values[metric_id];
        },
        // A STATE-reading program is never DerivedCell (`state_dependent`), so this
        // accessor should never be consulted. Returning 0 makes that a visible
        // zero rather than an inherited value if the invariant ever breaks.
        [](int32_t) -> int64_t { return 0; },
        out_value, error);
}

int64_t EffectRuntime::state_value(const Instance &instance, int32_t state_id) const {
    switch (state_id) {
        case STATE_LEVEL: return static_cast<int64_t>(instance.level) * Q16_ONE;
        case STATE_FIRE_SEQUENCE: return static_cast<int64_t>(instance.fire_sequence) * Q16_ONE;
        case STATE_INPUT_REVISION: return instance.input_revision;
        case STATE_REMAINING_DAYS: {
            if (instance.expires_day < 0) return 0;
            const int64_t remaining = std::max<int64_t>(0,
                instance.expires_day - _current_day);
            if (remaining > std::numeric_limits<int64_t>::max() / Q16_ONE)
                return std::numeric_limits<int64_t>::max();
            return remaining * Q16_ONE;
        }
        // The instance's own depth. Reported in Q16 like level/fire_sequence so
        // one condition unit means "one stack" everywhere.
        case STATE_STACK_COUNT:
            return static_cast<int64_t>(std::max(0, instance.stack_count)) * Q16_ONE;
        // Previous day's condition result. 0 before the first evaluation, so a
        // fresh instance always has to cross the upper threshold once.
        case STATE_LATCHED:
            return instance.latched != 0 ? Q16_ONE : 0;
        default: return 0;
    }
}

// One condition machine for both callers: the instance day pass and the derived
// layer's per-cell gate. A template rather than std::function so the day pass
// keeps its direct calls.
template <typename MetricFn, typename StateFn>
bool EffectRuntime::run_condition_machine(const Definition &definition,
                                          MetricFn metric, StateFn state) const {
    if (definition.condition_count <= 0) return true;
    std::array<uint8_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.condition_begin;
    const int32_t end = begin + definition.condition_count;
    for (int32_t i = begin; i < end; ++i) {
        const Condition &condition = _conditions[i];
        bool value = false;
        switch (condition.op) {
            case CONDITION_TRUE: value = true; break;
            case METRIC_GTE: value = metric(condition.arg0) >= condition.value; break;
            case METRIC_LTE: value = metric(condition.arg0) <= condition.value; break;
            case METRIC_EQ: value = metric(condition.arg0) == condition.value; break;
            case STATE_GTE: value = state(condition.arg0) >= condition.value; break;
            case BOOL_AND:
                if (sp < 2) return false;
                value = stack[sp - 2] != 0 && stack[sp - 1] != 0;
                --sp;
                stack[sp - 1] = value ? 1 : 0;
                continue;
            case BOOL_OR:
                if (sp < 2) return false;
                value = stack[sp - 2] != 0 || stack[sp - 1] != 0;
                --sp;
                stack[sp - 1] = value ? 1 : 0;
                continue;
            case BOOL_NOT:
                if (sp < 1) return false;
                stack[sp - 1] = stack[sp - 1] == 0 ? 1 : 0;
                continue;
            default: return false;
        }
        if (sp >= MAX_STACK) return false;
        stack[sp++] = value ? 1 : 0;
    }
    return sp > 0 && stack[sp - 1] != 0;
}

bool EffectRuntime::evaluate_condition(const Definition &definition,
                                       const Instance &instance) const {
    return run_condition_machine(definition,
        [&](int32_t id) { return metric_value(instance, id); },
        [&](int32_t id) { return state_value(instance, id); });
}

bool EffectRuntime::evaluate_program_conditions_for_metrics(
        const std::string &program_key,
        const int64_t *metric_values, int32_t metric_count,
        bool &passes, std::string &error) const {
    error.clear();
    passes = false;
    const int32_t id = definition_id_for_key(program_key);
    if (id < 0 || id >= static_cast<int32_t>(_definitions.size())) {
        error = "effect_program_not_found";
        return false;
    }
    // A STATE condition is never DerivedCell (`state_dependent`), so the state
    // accessor is never consulted; 0 keeps a broken invariant visible.
    passes = run_condition_machine(_definitions[static_cast<size_t>(id)],
        [metric_values, metric_count](int32_t metric_id) -> int64_t {
            if (metric_values == nullptr || metric_id < 0 ||
                    metric_id >= metric_count) return 0;
            return metric_values[metric_id];
        },
        [](int32_t) -> int64_t { return 0; });
    return true;
}

bool EffectRuntime::execute_program(const Definition &definition, Instance &instance,
                                     int64_t day, Transaction &transaction,
                                     std::string &error) {
    std::array<int64_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.instruction_begin;
    const int32_t end = begin + definition.instruction_count;
    for (int32_t i = begin; i < end; ++i) {
        const InstructionRow &row = _instructions[i];
        switch (row.op) {
            case CONST:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = row.value;
                break;
            case READ_METRIC:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = metric_value(instance, row.arg0);
                break;
            case READ_STATE:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = state_value(instance, row.arg0);
                break;
            case ADD:
            case SUB:
            case MUL_Q16:
            case DIV_FLOOR:
            case MIN:
            case MAX:
                if (sp < 2) { error = "effect_value_stack_underflow"; return false; }
                if (row.op == ADD) stack[sp - 2] = saturating_add(stack[sp - 2], stack[sp - 1]);
                else if (row.op == SUB) stack[sp - 2] = saturating_sub(stack[sp - 2], stack[sp - 1]);
                else if (row.op == MUL_Q16) stack[sp - 2] = mul_q16(stack[sp - 2], stack[sp - 1]);
                else if (row.op == DIV_FLOOR) {
                    if (stack[sp - 1] == 0) { error = "effect_division_by_zero"; return false; }
                    const int64_t quotient = floor_div(stack[sp - 2], stack[sp - 1]);
                    if (quotient > std::numeric_limits<int64_t>::max() / Q16_ONE ||
                        quotient < std::numeric_limits<int64_t>::min() / Q16_ONE) {
                        error = "effect_division_overflow";
                        return false;
                    }
                    stack[sp - 2] = quotient * Q16_ONE;
                } else if (row.op == MIN) stack[sp - 2] = std::min(stack[sp - 2], stack[sp - 1]);
                else stack[sp - 2] = std::max(stack[sp - 2], stack[sp - 1]);
                --sp;
                break;
            case CLAMP:
                if (sp < 1) { error = "effect_value_stack_underflow"; return false; }
                stack[sp - 1] = std::max(row.value, std::min(stack[sp - 1],
                    static_cast<int64_t>(row.arg0)));
                break;
            case EMIT_COMMAND: {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count) {
                    error = "effect_command_index_invalid"; return false;
                }
                const CommandDefinition &definition_command =
                    _command_definitions[definition.command_begin + row.arg0];
                Command command;
                command.action = definition_command.action;
                command.domain = definition_command.domain;
                command.opcode = definition_command.opcode;
                command.duration_days = definition_command.duration_days;
                const int32_t source_stacks = is_family_effect_instance(instance)
                    ? std::max(1, instance.desired_stack_count)
                    : std::max(1, instance.stack_count);
                command.stacks = static_cast<int32_t>(std::min<int64_t>(
                    definition.max_stacks,
                    static_cast<int64_t>(definition_command.stacks) *
                        source_stacks));
                command.payload = definition_command.payload;
                command.value_q16 = definition_command.value_mode == VALUE_STACK_TOP
                    ? (sp > 0 ? stack[sp - 1] : 0) : definition_command.value;
                const int32_t command_definition_id =
                    definition.command_begin + row.arg0;
                command.command_definition_id = command_definition_id;
                command.command_key_id = command_definition_id;
                if (definition.key == "family.effect.ancestral_precept") {
                    static constexpr int32_t kAncestralDurations[6] = {
                        180, 180, 240, 300, 365, 540
                    };
                    const int32_t tier = std::clamp(instance.level, 0, 5);
                    command.duration_days = kAncestralDurations[tier];
                    instance.duration_days = command.duration_days;
                    instance.expires_day = day + command.duration_days;
                } else if (definition.key == "family.effect.shared_water") {
                    static constexpr int32_t kSharedWaterDurations[6] = {
                        1, 1, 1, 2, 2, 3
                    };
                    const int32_t tier = std::clamp(instance.level, 0, 5);
                    command.duration_days = kSharedWaterDurations[tier];
                    instance.duration_days = command.duration_days;
                    instance.expires_day = day + command.duration_days;
                }
                if (definition_command.target_resolver == TARGET_STATIC)
                    command.target_handle = definition_command.static_target;
                else if (definition_command.target_resolver == TARGET_SOURCE) {
                    command.target_handle = instance.source_handle;
                    command.target_generation = instance.generation;
                } else {
                    command.target_handle = instance.target_handle;
                    command.target_generation = instance.target_generation;
                }
                command.idempotency_key = command_idempotency_key(
                    instance, static_cast<uint32_t>(row.arg0));
                append_command(transaction, command);
                break;
            }
            case END:
                return true;
            default:
                error = "effect_instruction_opcode_invalid";
                return false;
        }
    }
    (void)day;
    return true;
}

void EffectRuntime::append_planned_command(std::vector<Command> &commands,
                                           uint32_t &required_ack_mask,
                                           const Command &command) {
    for (const Command &existing : commands) {
        if (existing.idempotency_key == command.idempotency_key) return;
    }
    commands.push_back(command);
    required_ack_mask |= adapter_ack_bit_for(command);
}

uint32_t EffectRuntime::adapter_ack_bit_for(const Command &command) {
    return native_adapter_ack_bit(command.action);
}

bool EffectRuntime::execute_program_plan(const Definition &definition,
                                         const Instance &instance,
                                         int64_t day,
                                         std::vector<Command> &commands,
                                         uint32_t &required_ack_mask,
                                         std::string &error) const {
    std::array<int64_t, MAX_STACK> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.instruction_begin;
    const int32_t end = begin + definition.instruction_count;
    for (int32_t i = begin; i < end; ++i) {
        const InstructionRow &row = _instructions[i];
        switch (row.op) {
            case CONST:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = row.value;
                break;
            case READ_METRIC:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = metric_value(instance, row.arg0);
                break;
            case READ_STATE:
                if (sp >= MAX_STACK) { error = "effect_value_stack_overflow"; return false; }
                stack[sp++] = state_value(instance, row.arg0);
                break;
            case ADD:
            case SUB:
            case MUL_Q16:
            case DIV_FLOOR:
            case MIN:
            case MAX:
                if (sp < 2) { error = "effect_value_stack_underflow"; return false; }
                if (row.op == ADD) stack[sp - 2] = saturating_add(stack[sp - 2], stack[sp - 1]);
                else if (row.op == SUB) stack[sp - 2] = saturating_sub(stack[sp - 2], stack[sp - 1]);
                else if (row.op == MUL_Q16) stack[sp - 2] = mul_q16(stack[sp - 2], stack[sp - 1]);
                else if (row.op == DIV_FLOOR) {
                    if (stack[sp - 1] == 0) { error = "effect_division_by_zero"; return false; }
                    const int64_t quotient = floor_div(stack[sp - 2], stack[sp - 1]);
                    if (quotient > std::numeric_limits<int64_t>::max() / Q16_ONE ||
                        quotient < std::numeric_limits<int64_t>::min() / Q16_ONE) {
                        error = "effect_division_overflow";
                        return false;
                    }
                    stack[sp - 2] = quotient * Q16_ONE;
                } else if (row.op == MIN) stack[sp - 2] = std::min(stack[sp - 2], stack[sp - 1]);
                else stack[sp - 2] = std::max(stack[sp - 2], stack[sp - 1]);
                --sp;
                break;
            case CLAMP:
                if (sp < 1) { error = "effect_value_stack_underflow"; return false; }
                stack[sp - 1] = std::max(row.value, std::min(stack[sp - 1],
                    static_cast<int64_t>(row.arg0)));
                break;
            case EMIT_COMMAND: {
                if (row.arg0 < 0 || row.arg0 >= definition.command_count) {
                    error = "effect_command_index_invalid"; return false;
                }
                const CommandDefinition &definition_command =
                    _command_definitions[definition.command_begin + row.arg0];
                Command command;
                command.action = definition_command.action;
                command.domain = definition_command.domain;
                command.opcode = definition_command.opcode;
                command.duration_days = definition_command.duration_days;
                // Same helper as the worker POD (RuntimeEffectPodAuthority::
                // scaled_command_stacks), so a stacked instance emits identical
                // weight on both threads instead of two formulas that drift.
                command.stacks = RuntimeEffectPodAuthority::scaled_command_stacks(
                    definition_command.stacks, instance.stack_count,
                    definition.max_stacks);
                command.payload = definition_command.payload;
                command.value_q16 = definition_command.value_mode == VALUE_STACK_TOP
                    ? (sp > 0 ? stack[sp - 1] : 0) : definition_command.value;
                const int32_t command_definition_id = definition.command_begin + row.arg0;
                command.command_definition_id = command_definition_id;
                command.command_key_id = command_definition_id;
                if (definition_command.target_resolver == TARGET_STATIC)
                    command.target_handle = definition_command.static_target;
                else if (definition_command.target_resolver == TARGET_SOURCE) {
                    command.target_handle = instance.source_handle;
                    command.target_generation = instance.generation;
                } else {
                    command.target_handle = instance.target_handle;
                    command.target_generation = instance.target_generation;
                }
                command.idempotency_key = command_idempotency_key(
                    instance, static_cast<uint32_t>(row.arg0));
                append_planned_command(commands, required_ack_mask, command);
                break;
            }
            case END:
                return true;
            default:
                error = "effect_instruction_opcode_invalid";
                return false;
        }
    }
    (void)day;
    return true;
}

bool EffectRuntime::build_planned_candidate(int32_t candidate_cursor,
                                            int32_t instance_index,
                                            int64_t day,
                                            PlannedCandidate &plan) const {
    plan = PlannedCandidate();
    plan.candidate_cursor = candidate_cursor;
    plan.instance_index = instance_index;
    if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size())) return true;
    const Instance &instance = _instances[static_cast<size_t>(instance_index)];
    const Definition *definition =
        (instance.program_id >= 0 && instance.program_id < static_cast<int32_t>(_definitions.size()))
        ? &_definitions[instance.program_id] : nullptr;
    plan.work = std::max(1, definition != nullptr ? definition->max_work : 1);
    if (!instance.active || definition == nullptr ||
        (instance.next_due_day > day &&
         instance.input_revision <= instance.last_evaluated_input_revision))
        return true;
    plan.eligible = 1;
    if (!definition->enabled) return true;
    plan.enabled = 1;
    if (!evaluate_condition(*definition, instance)) return true;
    plan.passes = 1;
    if (!definition->behavior_id.empty()) {
        plan.error = "effect_behavior_requires_serial";
        plan.behavior_failure = 1;
        return false;
    }
    Instance planning_instance = instance;
    planning_instance.fire_sequence = instance.fire_sequence + 1;
    plan.planned_fire_sequence = planning_instance.fire_sequence;
    if (definition->instruction_count > 0 &&
        !execute_program_plan(*definition, planning_instance, day, plan.commands,
                              plan.required_ack_mask, plan.error))
        return false;
    return true;
}

} // namespace pk
