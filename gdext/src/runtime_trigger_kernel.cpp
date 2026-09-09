#include "runtime_trigger_kernel.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <tuple>

namespace pk {
namespace {

constexpr int64_t EMPTY_DISTINCT_KEY = std::numeric_limits<int64_t>::min();

int64_t saturating_add(int64_t a, int64_t b) {
    if (b > 0 && a > std::numeric_limits<int64_t>::max() - b)
        return std::numeric_limits<int64_t>::max();
    if (b < 0 && a < std::numeric_limits<int64_t>::min() - b)
        return std::numeric_limits<int64_t>::min();
    return a + b;
}

int64_t saturating_sub(int64_t a, int64_t b) {
    if (b > 0 && a < std::numeric_limits<int64_t>::min() + b)
        return std::numeric_limits<int64_t>::min();
    if (b < 0 && a > std::numeric_limits<int64_t>::max() - b)
        return std::numeric_limits<int64_t>::max();
    return a - b;
}

uint32_t generation_from_handle(uint64_t handle) {
    return static_cast<uint32_t>(handle >> 32u);
}

uint64_t distinct_hash(uint64_t value) {
    value ^= value >> 33u;
    value *= 0xff51afd7ed558ccdULL;
    value ^= value >> 33u;
    return value;
}

int64_t event_field(const RuntimeTriggerEvent &event, int32_t field) {
    switch (field) {
        case 0: return 1;
        case 1: return event.value;
        case 2: return event.payload[0];
        case 3: return event.payload[1];
        case 4: return event.payload[2];
        case 5: return event.payload[3];
        case 6: return static_cast<int64_t>(event.entity_handle);
        case 7: return static_cast<int64_t>(event.group_handle);
        default: return 0;
    }
}

bool event_matches(const RuntimeTriggerDefinition &definition,
                   const RuntimeTriggerEvent &event) {
    if (definition.selector_field < 0) return true;
    const bool equal = event_field(event, definition.selector_field) ==
        definition.selector_value;
    return definition.selector_negated != 0 ? !equal : equal;
}

uint64_t resolve_target(const RuntimeTriggerDefinition &definition,
                        const RuntimeTriggerEvent &event) {
    switch (static_cast<RuntimeTriggerTargetResolver>(definition.target_resolver)) {
        case RuntimeTriggerTargetResolver::SOURCE_ENTITY:
        case RuntimeTriggerTargetResolver::EVENT_ENTITY: return event.entity_handle;
        case RuntimeTriggerTargetResolver::EVENT_GROUP: return event.group_handle;
        case RuntimeTriggerTargetResolver::SNAPSHOT:
            return event.entity_handle != 0 ? event.entity_handle : event.group_handle;
        default: return definition.static_target;
    }
}

uint64_t resolve_effect_target(const RuntimeTriggerEffectDefinition &effect,
                               uint64_t state_target,
                               const RuntimeTriggerEvent &event) {
    switch (static_cast<RuntimeTriggerTargetResolver>(effect.target_resolver)) {
        case RuntimeTriggerTargetResolver::SOURCE_ENTITY:
        case RuntimeTriggerTargetResolver::EVENT_ENTITY: return event.entity_handle;
        case RuntimeTriggerTargetResolver::EVENT_GROUP: return event.group_handle;
        case RuntimeTriggerTargetResolver::SNAPSHOT: return state_target;
        default: return effect.static_target != 0 ? effect.static_target : state_target;
    }
}

int32_t find_state(const RuntimeTriggerSnapshot &state, int32_t trigger_id,
                   uint64_t target) {
    for (int32_t index = 0; index < static_cast<int32_t>(state.states.size()); ++index) {
        const RuntimeTriggerPodSnapshotState &candidate = state.states[index];
        if (candidate.trigger_id == trigger_id && candidate.target_handle == target)
            return index;
    }
    return -1;
}

int32_t find_or_create_state(RuntimeTriggerSnapshot &state,
                             const RuntimeTriggerPodCatalog &catalog,
                             int32_t trigger_id, uint64_t target,
                             std::string &error) {
    const int32_t existing = find_state(state, trigger_id, target);
    if (existing >= 0) return existing;
    if (state.states.size() >= static_cast<size_t>(catalog.max_states)) {
        error = "trigger_state_capacity_exhausted";
        return -1;
    }
    RuntimeTriggerPodSnapshotState created;
    created.trigger_id = trigger_id;
    created.target_handle = target;
    created.target_generation = generation_from_handle(target);
    created.distinct_keys.assign(catalog.distinct_capacity, EMPTY_DISTINCT_KEY);
    state.states.push_back(std::move(created));
    return static_cast<int32_t>(state.states.size() - 1u);
}

bool update_aggregate(RuntimeTriggerPodSnapshotState &state,
                      const RuntimeTriggerDefinition &definition,
                      const RuntimeTriggerPodCatalog &catalog,
                      const RuntimeTriggerEvent &event,
                      int64_t &old_value, int64_t &new_value,
                      int64_t &event_value, std::string &error) {
    old_value = state.accumulator;
    event_value = event_field(event, definition.value_field);
    const auto aggregator = static_cast<RuntimeTriggerAggregator>(definition.aggregator);
    if (event.snapshot != 0) {
        const int64_t previous = state.last_observed;
        state.last_observed = event_value;
        state.accumulator = aggregator == RuntimeTriggerAggregator::SNAPSHOT_DIFF
            ? (state.initialized == 0 ? 0 : saturating_sub(event_value, previous))
            : event_value;
        state.initialized = 1;
        new_value = state.accumulator;
        return true;
    }
    if (aggregator == RuntimeTriggerAggregator::CONSECUTIVE_DURATION) {
        const int64_t coverage = std::max<int64_t>(1,
            event_field(event, definition.duration_field));
        state.last_observed = event_value;
        if (state.last_sample_day >= 0 && event.day <= state.last_sample_day) {
            new_value = state.accumulator;
            return true;
        }
        const bool gap = state.last_sample_day >= 0 &&
            event.day > saturating_add(state.last_sample_day, coverage);
        state.last_sample_day = event.day;
        if (event_value < definition.qualifier_threshold) {
            state.accumulator = 0;
        } else if (gap || state.initialized == 0) {
            state.accumulator = coverage;
        } else {
            state.accumulator = saturating_add(state.accumulator, coverage);
        }
        state.initialized = 1;
        new_value = state.accumulator;
        return true;
    }
    if ((aggregator == RuntimeTriggerAggregator::WINDOW_COUNT ||
         aggregator == RuntimeTriggerAggregator::WINDOW_SUM) &&
        definition.window_days > 0 &&
        (state.window_start_day < 0 ||
         event.day >= state.window_start_day + definition.window_days)) {
        state.window_start_day = event.day;
        state.accumulator = 0;
        state.remainder = 0;
        old_value = 0;
    }
    switch (aggregator) {
        case RuntimeTriggerAggregator::COUNT:
        case RuntimeTriggerAggregator::WINDOW_COUNT:
            state.accumulator = saturating_add(state.accumulator,
                event_value > 0 ? event_value : 1);
            break;
        case RuntimeTriggerAggregator::SUM:
        case RuntimeTriggerAggregator::WINDOW_SUM:
        case RuntimeTriggerAggregator::SNAPSHOT_DIFF:
            state.accumulator = saturating_add(state.accumulator, event_value);
            break;
        case RuntimeTriggerAggregator::MINIMUM:
            state.accumulator = state.initialized == 0 ? event_value
                : std::min(state.accumulator, event_value);
            break;
        case RuntimeTriggerAggregator::MAXIMUM:
            state.accumulator = state.initialized == 0 ? event_value
                : std::max(state.accumulator, event_value);
            break;
        case RuntimeTriggerAggregator::STATE_LEVEL:
            state.last_observed = state.accumulator;
            state.accumulator = event_value;
            break;
        case RuntimeTriggerAggregator::DISTINCT_COUNT: {
            if (catalog.distinct_capacity <= 0) {
                error = "trigger_distinct_capacity_invalid";
                return false;
            }
            if (state.distinct_keys.size() != static_cast<size_t>(catalog.distinct_capacity))
                state.distinct_keys.assign(catalog.distinct_capacity, EMPTY_DISTINCT_KEY);
            const int64_t distinct = event_field(event, definition.distinct_field);
            size_t slot = static_cast<size_t>(distinct_hash(static_cast<uint64_t>(distinct))) %
                state.distinct_keys.size();
            bool inserted = false;
            for (int32_t probe = 0; probe < catalog.distinct_capacity; ++probe) {
                int64_t &key = state.distinct_keys[slot];
                if (key == distinct) break;
                if (key == EMPTY_DISTINCT_KEY) {
                    key = distinct;
                    inserted = true;
                    break;
                }
                slot = (slot + 1u) % state.distinct_keys.size();
            }
            if (inserted) state.accumulator = saturating_add(state.accumulator, 1);
            else if (state.accumulator >= catalog.distinct_capacity) {
                state.needs_resync = 1;
                error = "trigger_distinct_capacity_exhausted";
                return false;
            }
            break;
        }
        default:
            error = "trigger_aggregator_invalid";
            return false;
    }
    state.initialized = 1;
    new_value = state.accumulator;
    return true;
}

bool conditions_pass(const RuntimeTriggerPodCatalog &catalog,
                     const RuntimeTriggerDefinition &definition,
                     const RuntimeTriggerPodSnapshotState &state, int64_t day,
                     int64_t old_value, int64_t new_value,
                     int64_t old_level, int64_t new_level) {
    if (definition.condition_count == 0) return new_level > old_level;
    if (definition.condition_count > RUNTIME_TRIGGER_MAX_CONDITION_OPS ||
        definition.condition_begin > catalog.condition_ops.size() ||
        definition.condition_count > catalog.condition_ops.size() - definition.condition_begin)
        return false;
    bool stack[RUNTIME_TRIGGER_MAX_CONDITION_OPS]{};
    int32_t depth = 0;
    for (uint32_t index = 0; index < definition.condition_count; ++index) {
        const int32_t op = catalog.condition_ops[definition.condition_begin + index];
        if (op >= static_cast<int32_t>(RuntimeTriggerConditionOp::PUSH_TRUE) &&
            op <= static_cast<int32_t>(RuntimeTriggerConditionOp::PUSH_NOT_COMPLETED)) {
            if (depth >= static_cast<int32_t>(RUNTIME_TRIGGER_MAX_CONDITION_OPS)) return false;
            bool value = false;
            switch (static_cast<RuntimeTriggerConditionOp>(op)) {
                case RuntimeTriggerConditionOp::PUSH_TRUE: value = true; break;
                case RuntimeTriggerConditionOp::PUSH_ACC_GTE:
                    value = new_value >= definition.threshold; break;
                case RuntimeTriggerConditionOp::PUSH_CROSSING:
                    value = new_level > old_level; break;
                case RuntimeTriggerConditionOp::PUSH_LEVEL_CHANGE:
                    value = new_level != old_level; break;
                case RuntimeTriggerConditionOp::PUSH_COOLDOWN_READY:
                    value = day >= state.cooldown_until; break;
                case RuntimeTriggerConditionOp::PUSH_NOT_COMPLETED:
                    value = state.completed == 0; break;
                default: return false;
            }
            stack[depth++] = value;
        } else if (op == static_cast<int32_t>(RuntimeTriggerConditionOp::BOOL_NOT)) {
            if (depth < 1) return false;
            stack[depth - 1] = !stack[depth - 1];
        } else if (op == static_cast<int32_t>(RuntimeTriggerConditionOp::BOOL_AND) ||
                   op == static_cast<int32_t>(RuntimeTriggerConditionOp::BOOL_OR)) {
            if (depth < 2) return false;
            const bool right = stack[--depth];
            const bool left = stack[depth - 1];
            stack[depth - 1] = op == static_cast<int32_t>(RuntimeTriggerConditionOp::BOOL_AND)
                ? left && right : left || right;
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0];
}

int64_t fire_count(const RuntimeTriggerDefinition &definition,
                   const RuntimeTriggerPodSnapshotState &state, int64_t old_value,
                   int64_t new_value, int64_t old_level, int64_t new_level) {
    if (definition.mode == static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT))
        return state.completed == 0 && new_value >= definition.threshold ? 1 : 0;
    if (new_level > old_level) return new_level - old_level;
    return new_level != old_level ? 1 : 0;
}

void emit_effects(const RuntimeTriggerPodCatalog &catalog,
                  RuntimeTriggerSnapshot &state, int32_t trigger_id,
                  RuntimeTriggerPodSnapshotState &trigger_state,
                  const RuntimeTriggerEvent &event, int64_t fire_count_value,
                  int64_t level, int64_t event_value,
                  std::vector<RuntimeTriggerEffectIntent> &emitted,
                  std::string &error) {
    const RuntimeTriggerDefinition &definition = catalog.definitions[trigger_id];
    if (definition.effect_begin > catalog.effects.size() ||
        definition.effect_count > catalog.effects.size() - definition.effect_begin) {
        error = "trigger_effect_range_invalid";
        return;
    }
    const uint64_t fire_sequence = ++trigger_state.fire_sequence;
    for (uint32_t offset = 0; offset < definition.effect_count; ++offset) {
        if (state.pending_effects.size() + emitted.size() >= RUNTIME_TRIGGER_MAX_PENDING_EFFECTS) {
            error = "trigger_effect_capacity_exhausted";
            return;
        }
        const RuntimeTriggerEffectDefinition &source =
            catalog.effects[definition.effect_begin + offset];
        RuntimeTriggerEffectIntent effect;
        effect.id = state.next_effect_id++;
        effect.effective_day = event.day + 1;
        effect.source_priority = source.source_priority;
        effect.trigger_id = trigger_id;
        effect.effect_definition_id = static_cast<int32_t>(definition.effect_begin + offset);
        effect.target_handle = resolve_effect_target(source, trigger_state.target_handle, event);
        effect.target_generation = generation_from_handle(effect.target_handle);
        effect.fire_sequence = fire_sequence;
        effect.action = source.action;
        effect.domain = source.domain;
        effect.opcode = source.opcode;
        effect.duration_days = source.duration_days;
        effect.stacks = source.stacks;
        effect.payload = source.payload;
        if (effect.action == static_cast<int32_t>(RuntimeTriggerAction::ECONOMY_COMMAND) &&
            effect.opcode == 14 && event.payload[1] >= 0 && effect.payload[1] == 0)
            effect.payload[1] = event.payload[1];
        if (effect.action == static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND) &&
            effect.opcode == 14) {
            const uint64_t signal = static_cast<uint64_t>(effect.payload[0]) & 0xffffffffULL;
            const uint64_t cell = event.group_handle & 0xffffffffULL;
            effect.payload[0] = static_cast<int64_t>((signal << 32u) | cell);
        }
        for (const RuntimeTriggerBranchBinding &binding : state.branch_bindings) {
            if (binding.enabled != 0 && binding.trigger_id == trigger_id &&
                binding.branch_handle == trigger_state.target_handle) {
                effect.payload[0] = binding.reward_target;
                break;
            }
        }
        switch (static_cast<RuntimeTriggerValueMode>(source.value_mode)) {
            case RuntimeTriggerValueMode::FIRE_COUNT: effect.resolved_value = fire_count_value; break;
            case RuntimeTriggerValueMode::LEVEL: effect.resolved_value = level; break;
            case RuntimeTriggerValueMode::ACCUMULATOR:
                effect.resolved_value = trigger_state.accumulator; break;
            case RuntimeTriggerValueMode::EVENT_VALUE: effect.resolved_value = event_value; break;
            default: effect.resolved_value = source.value; break;
        }
        if (source.value_mode == static_cast<int32_t>(RuntimeTriggerValueMode::LEVEL) &&
            effect.stacks <= 0)
            effect.stacks = static_cast<int32_t>(std::max<int64_t>(0, level));
        emitted.push_back(effect);
    }
}

} // namespace

bool RuntimeTriggerKernel::evaluate_day(const RuntimeTriggerPodCatalog &catalog,
                                        RuntimeTriggerSnapshot &state,
                                        int64_t day,
                                        std::vector<RuntimeTriggerEffectIntent> &emitted,
                                        std::string &error) {
    error.clear();
    emitted.clear();
    if (day < state.committed_day) {
        error = "trigger_day_regression";
        return false;
    }
    state.current_day = day;
    if (state.enabled.size() != catalog.definitions.size()) {
        state.enabled.resize(catalog.definitions.size());
        for (size_t i = 0; i < catalog.definitions.size(); ++i)
            state.enabled[i] = catalog.definitions[i].enabled;
    }
    std::stable_sort(state.pending_events.begin(), state.pending_events.end(),
        [](const RuntimeTriggerEvent &a, const RuntimeTriggerEvent &b) {
            return std::tie(a.day, a.source_id, a.event_id) <
                std::tie(b.day, b.source_id, b.event_id);
        });
    size_t retained = 0;
    for (const RuntimeTriggerEvent &event : state.pending_events) {
        if (event.day > day) {
            state.pending_events[retained++] = event;
            continue;
        }
        if (event.source_id < 0 || event.source_id >= catalog.source_count ||
            event.event_type < 0 || event.event_type >= catalog.event_type_span ||
            static_cast<size_t>(event.source_id) >= state.source_needs_resync.size() ||
            state.source_needs_resync[event.source_id] != 0) continue;
        const auto process = [&](int32_t trigger_id, uint64_t target) {
            if (!error.empty() || trigger_id < 0 ||
                trigger_id >= static_cast<int32_t>(catalog.definitions.size())) return;
            const RuntimeTriggerDefinition &definition = catalog.definitions[trigger_id];
            if (state.enabled[trigger_id] == 0 ||
                (definition.payload_schema > 0 &&
                 definition.payload_schema != event.payload_schema) ||
                !event_matches(definition, event)) return;
            const int32_t state_index = find_or_create_state(state, catalog, trigger_id,
                target, error);
            if (state_index < 0) return;
            RuntimeTriggerPodSnapshotState &trigger_state = state.states[state_index];
            if (trigger_state.needs_resync != 0 ||
                trigger_state.last_event_id >= event.event_id) return;
            int64_t old_value = 0, new_value = 0, event_value = 0;
            if (!update_aggregate(trigger_state, definition, catalog, event,
                                  old_value, new_value, event_value, error)) return;
            trigger_state.last_event_id = event.event_id;
            const int64_t threshold = std::max<int64_t>(1, definition.threshold);
            const int64_t old_level = old_value >= 0 ? old_value / threshold : 0;
            const int64_t new_level = new_value >= 0 ? new_value / threshold : 0;
            trigger_state.remainder = new_value >= 0 ? new_value % threshold : 0;
            if (!conditions_pass(catalog, definition, trigger_state, day, old_value,
                                 new_value, old_level, new_level)) return;
            const int64_t fired = fire_count(definition, trigger_state, old_value,
                                             new_value, old_level, new_level);
            if (fired <= 0) return;
            emit_effects(catalog, state, trigger_id, trigger_state, event, fired,
                         new_level, event_value, emitted, error);
            if (definition.mode == static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT))
                trigger_state.completed = 1;
            if (definition.cooldown_days > 0)
                trigger_state.cooldown_until = day + definition.cooldown_days;
        };
        for (int32_t trigger_id = 0;
             trigger_id < static_cast<int32_t>(catalog.definitions.size()); ++trigger_id) {
            const RuntimeTriggerDefinition &definition = catalog.definitions[trigger_id];
            if (definition.dynamic_binding == 0 && definition.source_id == event.source_id &&
                definition.event_type == event.event_type)
                process(trigger_id, resolve_target(definition, event));
        }
        for (const RuntimeTriggerBranchBinding &binding : state.branch_bindings) {
            if (binding.enabled == 0 || binding.cell != static_cast<int32_t>(event.group_handle) ||
                binding.trigger_id < 0 ||
                binding.trigger_id >= static_cast<int32_t>(catalog.definitions.size())) continue;
            const RuntimeTriggerDefinition &definition = catalog.definitions[binding.trigger_id];
            if (definition.dynamic_binding != 0 && definition.source_id == event.source_id &&
                definition.event_type == event.event_type)
                process(binding.trigger_id, binding.branch_handle);
        }
    }
    state.pending_events.resize(retained);
    state.pending_effects.insert(state.pending_effects.end(), emitted.begin(), emitted.end());
    std::stable_sort(state.pending_effects.begin(), state.pending_effects.end(),
        [](const RuntimeTriggerEffectIntent &a, const RuntimeTriggerEffectIntent &b) {
            return std::tie(a.effective_day, a.source_priority, a.trigger_id,
                            a.target_handle, a.fire_sequence, a.id) <
                std::tie(b.effective_day, b.source_priority, b.trigger_id,
                         b.target_handle, b.fire_sequence, b.id);
        });
    return error.empty();
}

} // namespace pk
