#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

// Native trigger authority. Catalog parsing is a cold boundary; event ingest,
// aggregation, condition evaluation, and effect generation use dense POD data.
class TriggerRuntime {
public:
    static constexpr int32_t PROTOCOL_VERSION = 1;
    static constexpr int32_t SAVE_SCHEMA_VERSION = 1;

    enum Scope : int32_t { GLOBAL = 0, GROUP = 1, ENTITY = 2 };
    enum Aggregator : int32_t {
        COUNT = 1,
        SUM = 2,
        MINIMUM = 3,
        MAXIMUM = 4,
        STATE_LEVEL = 5,
        WINDOW_COUNT = 6,
        WINDOW_SUM = 7,
        DISTINCT_COUNT = 8,
        SNAPSHOT_DIFF = 9,
    };
    enum ValueField : int32_t {
        VALUE_ONE = 0,
        VALUE_I64 = 1,
        PAYLOAD_I0 = 2,
        PAYLOAD_I1 = 3,
        PAYLOAD_I2 = 4,
        PAYLOAD_I3 = 5,
        ENTITY_HANDLE = 6,
        GROUP_HANDLE = 7,
    };
    enum TargetResolver : int32_t {
        TARGET_STATIC = 0,
        TARGET_SOURCE_ENTITY = 1,
        TARGET_EVENT_ENTITY = 2,
        TARGET_EVENT_GROUP = 3,
        TARGET_SNAPSHOT = 4,
    };
    enum TriggerMode : int32_t { REPEAT = 1, ONE_SHOT = 2 };
    enum ConditionOp : int32_t {
        PUSH_TRUE = 1,
        PUSH_ACC_GTE = 2,
        PUSH_CROSSING = 3,
        PUSH_LEVEL_CHANGE = 4,
        PUSH_COOLDOWN_READY = 5,
        PUSH_NOT_COMPLETED = 6,
        BOOL_AND = 7,
        BOOL_OR = 8,
        BOOL_NOT = 9,
    };
    enum Action : int32_t {
        MODIFIER_APPLY = 1,
        MODIFIER_REMOVE = 2,
        MODIFIER_REFRESH = 3,
        MODIFIER_SET_STACKS = 4,
        COUNTRY_COMMAND = 10,
        ECONOMY_COMMAND = 11,
        GAMEPLAY_COMMAND = 12,
        PUBLISH_EVENT = 13,
        CUSTOM_DOMAIN_COMMAND = 14,
    };
    enum EffectValueMode : int32_t {
        EFFECT_CONSTANT = 0,
        EFFECT_FIRE_COUNT = 1,
        EFFECT_LEVEL = 2,
        EFFECT_ACCUMULATOR = 3,
        EFFECT_EVENT_VALUE = 4,
    };

    godot::Dictionary configure(const godot::Dictionary &catalog);
    godot::Dictionary submit_events(const godot::Dictionary &batch);
    godot::Dictionary submit_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_daily(int64_t day_index);
    godot::Dictionary poll_effects(int64_t after_effect_id, int32_t limit) const;
    godot::Dictionary ack_effects(int64_t up_to_effect_id);
    godot::Dictionary set_enabled(const godot::Dictionary &batch);
    godot::Dictionary resync_source(const godot::Dictionary &snapshot);
    godot::Dictionary report() const;
    bool should_run(int64_t day_index) const;

    godot::PackedByteArray capture() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_state();

private:
    struct Definition {
        std::string key;
        int32_t version = 1;
        int32_t source_id = 0;
        int32_t event_type = 0;
        int32_t payload_schema = 0;
        int32_t aggregator = COUNT;
        int32_t value_field = VALUE_ONE;
        int32_t distinct_field = VALUE_I64;
        int32_t scope = GLOBAL;
        int32_t target_resolver = TARGET_STATIC;
        uint64_t static_target = 0;
        int64_t threshold = 1;
        int32_t mode = REPEAT;
        int32_t cooldown_days = 0;
        int32_t window_days = 0;
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t effect_begin = 0;
        int32_t effect_count = 0;
        uint8_t enabled = 1;
    };
    struct EffectDefinition {
        int32_t action = CUSTOM_DOMAIN_COMMAND;
        int32_t source_priority = 0;
        int32_t domain = 0;
        int32_t opcode = 0;
        int32_t target_resolver = TARGET_STATIC;
        uint64_t static_target = 0;
        int32_t value_mode = EFFECT_CONSTANT;
        int64_t value = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct Event {
        int32_t source_id = 0;
        int64_t event_id = 0;
        int64_t day = 0;
        int32_t event_type = 0;
        int32_t payload_schema = 0;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        int64_t value = 0;
        std::array<int64_t, 4> payload{};
        bool snapshot = false;
    };
    struct Effect {
        int64_t id = 0;
        int64_t effective_day = 0;
        int32_t source_priority = 0;
        int32_t trigger_id = -1;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        uint64_t fire_sequence = 0;
        int32_t action = 0;
        int32_t domain = 0;
        int32_t opcode = 0;
        int64_t resolved_value = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };

    struct StateArrays {
        std::vector<int32_t> trigger_id;
        std::vector<uint64_t> target_handle;
        std::vector<uint32_t> target_generation;
        std::vector<int64_t> accumulator;
        std::vector<int64_t> remainder;
        std::vector<int64_t> last_event_id;
        std::vector<uint64_t> fire_sequence;
        std::vector<int64_t> cooldown_until;
        std::vector<int64_t> window_start_day;
        std::vector<int64_t> last_observed;
        std::vector<uint8_t> completed;
        std::vector<uint8_t> initialized;
        std::vector<uint8_t> needs_resync;
    };

    struct LookupSlot {
        int32_t trigger_id = -1;
        uint64_t target_handle = 0;
        int32_t state_index = -1;
    };

    bool _configured = false;
    uint64_t _catalog_hash = 0;
    int64_t _current_day = -1;
    int32_t _max_states = 4096;
    int32_t _max_pending_events = 8192;
    int32_t _distinct_capacity = 64;
    int32_t _source_count = 64;
    int32_t _event_type_span = 256;
    bool _strict_source_cursors = false;
    int32_t _state_count = 0;
    int64_t _next_effect_id = 1;
    int64_t _acked_effect_id = 0;

    std::vector<Definition> _definitions;
    std::vector<EffectDefinition> _effect_definitions;
    std::vector<int32_t> _condition_ops;
    std::vector<std::vector<int32_t>> _index_by_source_event;
    std::vector<int64_t> _source_cursor;
    std::vector<uint8_t> _source_needs_resync;
    std::vector<int64_t> _source_gap_begin;
    std::vector<int64_t> _source_gap_end;
    std::vector<Event> _pending_events;
    std::vector<Effect> _effects;
    StateArrays _state;
    std::vector<LookupSlot> _lookup;
    std::vector<int64_t> _distinct_keys;

    uint64_t _events_ingested = 0;
    uint64_t _events_deduplicated = 0;
    uint64_t _events_rejected = 0;
    uint64_t _rules_evaluated = 0;
    uint64_t _effects_emitted = 0;
    uint64_t _gap_count = 0;
    uint64_t _resync_count = 0;
    double _last_ingest_ms = 0.0;
    double _last_evaluate_ms = 0.0;
    std::string _last_error;

    int32_t find_or_create_state(int32_t trigger_id, uint64_t target_handle,
                                 uint32_t target_generation);
    uint64_t resolve_target(const Definition &definition, const Event &event) const;
    uint64_t resolve_effect_target(const EffectDefinition &effect,
                                   uint64_t state_target,
                                   const Event &event) const;
    int64_t event_field(const Event &event, int32_t field) const;
    bool update_aggregate(int32_t state_index, const Definition &definition,
                          const Event &event, int64_t &old_value,
                          int64_t &new_value, int64_t &event_value);
    bool evaluate_conditions(const Definition &definition, int32_t state_index,
                             int64_t old_value, int64_t new_value,
                             int64_t old_level, int64_t new_level) const;
    int64_t fire_count_for(const Definition &definition, int32_t state_index,
                           int64_t old_value, int64_t new_value,
                           int64_t old_level, int64_t new_level) const;
    void emit_effects(int32_t trigger_id, int32_t state_index,
                      const Event &event, int64_t fire_count,
                      int64_t level, int64_t event_value);
    void mark_source_gap(int32_t source_id, int64_t expected, int64_t actual);
    void reset_runtime_state();
};

} // namespace pk
