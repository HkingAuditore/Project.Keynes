#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

constexpr uint32_t RUNTIME_TRIGGER_POD_ABI_VERSION = 1u;
constexpr uint32_t RUNTIME_TRIGGER_MAX_DEFINITIONS = 65536u;
constexpr uint32_t RUNTIME_TRIGGER_MAX_EFFECT_DEFINITIONS = 262144u;
constexpr uint32_t RUNTIME_TRIGGER_MAX_CONDITION_OPS = 64u;
constexpr uint32_t RUNTIME_TRIGGER_MAX_PENDING_EVENTS = 8192u;
constexpr uint32_t RUNTIME_TRIGGER_MAX_PENDING_EFFECTS = 8192u;
constexpr uint32_t RUNTIME_TRIGGER_RESYNC_CAPACITY = 256u;

enum class RuntimeTriggerAggregator : int32_t {
    COUNT = 1,
    SUM = 2,
    MINIMUM = 3,
    MAXIMUM = 4,
    STATE_LEVEL = 5,
    WINDOW_COUNT = 6,
    WINDOW_SUM = 7,
    DISTINCT_COUNT = 8,
    SNAPSHOT_DIFF = 9,
    CONSECUTIVE_DURATION = 10,
};

enum class RuntimeTriggerTargetResolver : int32_t {
    STATIC = 0,
    SOURCE_ENTITY = 1,
    EVENT_ENTITY = 2,
    EVENT_GROUP = 3,
    SNAPSHOT = 4,
};

enum class RuntimeTriggerMode : int32_t {
    REPEAT = 1,
    ONE_SHOT = 2,
};

enum class RuntimeTriggerConditionOp : int32_t {
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

// These sparse numeric values are part of the Trigger/Effect contract.
enum class RuntimeTriggerAction : int32_t {
    MODIFIER_APPLY = 1,
    MODIFIER_REMOVE = 2,
    MODIFIER_REFRESH = 3,
    MODIFIER_SET_STACKS = 4,
    COUNTRY_COMMAND = 10,
    ECONOMY_COMMAND = 11,
    GAMEPLAY_COMMAND = 12,
    PUBLISH_EVENT = 13,
    CUSTOM_DOMAIN_COMMAND = 14,
    IDEOLOGY_COMMAND = 15,
};

enum class RuntimeTriggerValueMode : int32_t {
    CONSTANT = 0,
    FIRE_COUNT = 1,
    LEVEL = 2,
    ACCUMULATOR = 3,
    EVENT_VALUE = 4,
};

enum class RuntimeTriggerCommandOpcode : uint16_t {
    INGEST_EVENT = 1,
    INGEST_SNAPSHOT = 2,
    SET_ENABLED = 3,
    RECONCILE_BRANCH_BINDING = 4,
    RESYNC_SOURCE = 5,
    ACK_EFFECTS = 6,
};

struct RuntimeTriggerEvent {
    int32_t source_id = 0;
    int64_t event_id = 0;
    int64_t day = 0;
    int32_t event_type = 0;
    int32_t payload_schema = 0;
    uint64_t entity_handle = 0;
    uint64_t group_handle = 0;
    int64_t value = 1;
    std::array<int64_t, 4> payload{};
    uint8_t snapshot = 0;
};

struct RuntimeTriggerDefinition {
    uint64_t key_hash = 0;
    int32_t version = 1;
    int32_t source_id = 0;
    int32_t event_type = 0;
    int32_t payload_schema = 0;
    int32_t aggregator = static_cast<int32_t>(RuntimeTriggerAggregator::COUNT);
    int32_t value_field = 0;
    int32_t distinct_field = 1;
    int32_t scope = 0;
    int32_t target_resolver = static_cast<int32_t>(RuntimeTriggerTargetResolver::STATIC);
    uint64_t static_target = 0;
    int64_t threshold = 1;
    int32_t mode = static_cast<int32_t>(RuntimeTriggerMode::REPEAT);
    int32_t cooldown_days = 0;
    int32_t window_days = 0;
    int64_t qualifier_threshold = 0;
    int32_t duration_field = 0;
    int32_t development_metric_id = -1;
    int32_t development_era_index = -1;
    uint32_t condition_begin = 0;
    uint32_t condition_count = 0;
    uint32_t effect_begin = 0;
    uint32_t effect_count = 0;
    int32_t selector_field = -1;
    int64_t selector_value = 0;
    uint8_t enabled = 1;
    uint8_t dynamic_binding = 0;
    uint8_t selector_negated = 0;
};

struct RuntimeTriggerEffectDefinition {
    int32_t action = static_cast<int32_t>(RuntimeTriggerAction::CUSTOM_DOMAIN_COMMAND);
    int32_t source_priority = 0;
    int32_t domain = 0;
    int32_t opcode = 0;
    int32_t target_resolver = static_cast<int32_t>(RuntimeTriggerTargetResolver::STATIC);
    uint64_t static_target = 0;
    int32_t value_mode = static_cast<int32_t>(RuntimeTriggerValueMode::CONSTANT);
    int64_t value = 0;
    int32_t duration_days = -1;
    int32_t stacks = 1;
    std::array<int64_t, 4> payload{};
};

struct RuntimeTriggerBranchBinding {
    int32_t trigger_id = -1;
    uint64_t branch_handle = 0;
    int32_t cell = -1;
    int32_t reward_target = 0;
    uint8_t enabled = 1;
};

struct RuntimeTriggerPodCatalog {
    uint64_t catalog_hash = 0;
    int32_t max_states = 4096;
    int32_t max_pending_events = 8192;
    int32_t distinct_capacity = 64;
    int32_t source_count = 64;
    int32_t event_type_span = 256;
    uint8_t strict_source_cursors = 0;
    std::vector<RuntimeTriggerDefinition> definitions;
    std::vector<RuntimeTriggerEffectDefinition> effects;
    std::vector<int32_t> condition_ops;
};

struct RuntimeTriggerPodSnapshotState {
    int32_t trigger_id = -1;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t accumulator = 0;
    int64_t remainder = 0;
    int64_t last_event_id = 0;
    uint64_t fire_sequence = 0;
    int64_t cooldown_until = 0;
    int64_t window_start_day = -1;
    int64_t last_observed = 0;
    int64_t last_sample_day = -1;
    uint8_t completed = 0;
    uint8_t initialized = 0;
    uint8_t needs_resync = 0;
    std::vector<int64_t> distinct_keys;
};

struct RuntimeTriggerEffectIntent {
    int64_t id = 0;
    int64_t effective_day = 0;
    int32_t source_priority = 0;
    int32_t trigger_id = -1;
    int32_t effect_definition_id = -1;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    uint64_t fire_sequence = 0;
    int32_t action = 0;
    int32_t domain = 0;
    int32_t opcode = 0;
    int64_t resolved_value = 0;
    int32_t duration_days = -1;
    int32_t stacks = 1;
    std::array<int64_t, 4> payload{};
};

struct RuntimeTriggerSnapshot {
    uint64_t generation = 0;
    uint64_t catalog_hash = 0;
    int64_t committed_day = -1;
    int64_t current_day = -1;
    int64_t next_effect_id = 1;
    int64_t acked_effect_id = 0;
    std::vector<int64_t> source_cursor;
    std::vector<uint8_t> source_needs_resync;
    std::vector<int64_t> source_gap_begin;
    std::vector<int64_t> source_gap_end;
    std::vector<RuntimeTriggerPodSnapshotState> states;
    // Runtime enable controls are state, not catalog identity. Keeping this
    // vector in the snapshot makes SET_ENABLED transactional.
    std::vector<uint8_t> enabled;
    std::vector<RuntimeTriggerBranchBinding> branch_bindings;
    std::vector<RuntimeTriggerEvent> pending_events;
    std::vector<RuntimeTriggerEffectIntent> pending_effects;
};

struct RuntimeTriggerCommand {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    RuntimeTriggerCommandOpcode opcode = RuntimeTriggerCommandOpcode::INGEST_EVENT;
    RuntimeTriggerEvent event{};
    int32_t trigger_id = -1;
    uint8_t enabled = 1;
    RuntimeTriggerBranchBinding binding{};
    int32_t source_id = -1;
    int64_t cursor = 0;
    int64_t ack_up_to_effect_id = 0;
    uint32_t resync_count = 0;
    std::array<int32_t, RUNTIME_TRIGGER_RESYNC_CAPACITY> resync_trigger_ids{};
    std::array<uint64_t, RUNTIME_TRIGGER_RESYNC_CAPACITY> resync_target_handles{};
    std::array<int64_t, RUNTIME_TRIGGER_RESYNC_CAPACITY> resync_values{};
};

struct RuntimeTriggerPodPlan {
    RuntimeDomainHeader header{};
    RuntimeTriggerSnapshot next_state{};
    std::vector<RuntimeTriggerCommand> consumed_commands;
    std::vector<RuntimeTriggerEffectIntent> intents;
    std::vector<RuntimeDomainAck> acks;
    uint32_t required_ack_count = 0;
    uint8_t preflight_ok = 0;
    uint8_t committed = 0;
};

struct RuntimeTriggerPodSaveSection {
    RuntimeDomainSaveSection descriptor{};
    uint64_t catalog_hash = 0;
    int64_t committed_day = -1;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    std::vector<uint8_t> payload;
};

struct RuntimeTriggerPodDiagnostics {
    int64_t day = -1;
    int64_t reference_day = -1;
    uint64_t input_hash = 0;
    uint64_t reference_input_hash = 0;
    uint64_t reference_state_hash = 0;
    uint64_t worker_state_hash = 0;
    uint64_t reference_effect_hash = 0;
    uint64_t worker_effect_hash = 0;
    uint32_t required_ack_count = 0;
    uint32_t received_ack_count = 0;
    uint32_t pending_ack_count = 0;
    uint64_t generation = 0;
    int64_t committed_day = -1;
    int64_t acked_effect_id = 0;
    uint32_t pending_command_count = 0;
    uint8_t parity_compared = 0;
    uint8_t parity_matched = 0;
    int32_t first_divergence_index = -1;
    char first_divergence_kind[32]{};
    char blocker[64]{};
};

class RuntimeTriggerPodAuthority {
public:
    RuntimeTriggerPodAuthority();

    bool bootstrap(const RuntimeTriggerSnapshot &snapshot,
                   const RuntimeTriggerPodCatalog &catalog,
                   std::string &error);
    bool queue_command(const RuntimeTriggerCommand &command, std::string &error);
    bool plan_day(int64_t day, uint64_t input_generation,
                  RuntimeTriggerPodPlan &plan, std::string &error);
    bool commit_day(RuntimeTriggerPodPlan &plan,
                    const std::vector<RuntimeDomainAck> &acks,
                    std::string &error);
    void discard_plan();
    bool snapshot(RuntimeTriggerSnapshot &out, std::string &error) const;
    bool set_reference_frame(int64_t day, uint64_t input_hash,
                             uint64_t state_hash, uint64_t effect_hash,
                             std::string &error);
    bool encode_save(RuntimeTriggerPodSaveSection &out, std::string &error) const;
    bool restore_save(const RuntimeTriggerPodSaveSection &section,
                      const RuntimeTriggerPodCatalog &catalog,
                      std::string &error);
    bool validate_catalog(const RuntimeTriggerPodCatalog &catalog,
                          std::string &error) const;
    uint64_t generation() const noexcept { return _state.generation; }
    int64_t committed_day() const noexcept { return _state.committed_day; }
    uint64_t state_hash() const noexcept { return _state_hash; }
    uint32_t pending_command_count() const noexcept {
        return static_cast<uint32_t>(_pending_commands.size());
    }
    const RuntimeTriggerPodDiagnostics &diagnostics() const noexcept { return _diagnostics; }
    static uint64_t canonical_state_hash(const RuntimeTriggerSnapshot &snapshot);
    static uint64_t canonical_effect_hash(
            const std::vector<RuntimeTriggerEffectIntent> &effects);
    static bool self_test(std::string &error);

private:
    RuntimeTriggerSnapshot _state;
    RuntimeTriggerPodCatalog _catalog;
    std::vector<RuntimeTriggerCommand> _pending_commands;
    RuntimeTriggerPodPlan *_active_plan = nullptr;
    RuntimeTriggerPodDiagnostics _diagnostics{};
    uint64_t _state_hash = 0;
    uint64_t _next_generation = 1;
    bool _bootstrapped = false;
    bool _plan_active = false;
    bool _reference_pending = false;
    int64_t _reference_day = -1;
    uint64_t _reference_input_hash = 0;
    uint64_t _reference_state_hash = 0;
    uint64_t _reference_effect_hash = 0;

    bool validate_state(const RuntimeTriggerSnapshot &snapshot,
                        std::string &error) const;
    bool apply_command(RuntimeTriggerSnapshot &state,
                       const RuntimeTriggerCommand &command,
                       std::string &error) const;
    static uint64_t hash_snapshot(const RuntimeTriggerSnapshot &snapshot);
    static uint64_t hash_effects(const std::vector<RuntimeTriggerEffectIntent> &effects);
    bool compare_reference_frame();
};

} // namespace pk
