#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

constexpr uint32_t RUNTIME_IDEOLOGY_POD_ABI_VERSION = 2u;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_COUNTRIES = 1u << 20;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_IDEAS = 65536u;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_COMMANDS = 1u << 20;
constexpr uint32_t RUNTIME_IDEOLOGY_POD_MAX_TRANSITIONS = 1u << 20;

enum class RuntimeIdeologyPodOpcode : uint16_t {
    DISCOVER = 1,
    GRANT_POINTS = 2,
    OPEN_OFFER = 3,
    CHOOSE_OFFER = 4,
    EQUIP = 5,
    UNEQUIP = 6,
    PROMOTE = 7,
    ADD_UNDERSTANDING = 8,
    SET_GATE = 9,
};

enum class RuntimeIdeologyPodLocation : uint8_t {
    INACTIVE = 0,
    IDEOLOGY = 1,
    NATIONAL_SPIRIT = 2,
};

enum class RuntimeIdeologyPodPhase : uint8_t {
    PENDING_TRANSITIONS = 0,
    COMMANDS = 1,
    ACTIVE_PROGRESS = 2,
};

enum class RuntimeIdeologyPodReceiptStatus : uint8_t {
    PENDING = 1,
    SETTLED = 2,
    REJECTED = 3,
};

struct RuntimeIdeologyPodLevel {
    int64_t threshold_q16 = 0;
    int64_t daily_understanding_q16 = 0;
};

struct RuntimeIdeologyPodDefinition {
    uint8_t acquisition = 3;
    uint8_t reserved[3]{};
    int32_t rarity_weight = 1;
    int32_t ideology_cost = 1;
    int32_t spirit_cost = 1;
    int32_t min_spirit_level = 0;
    uint32_t level_begin = 0;
    uint32_t level_count = 0;
    uint32_t technology_begin = 0;
    uint32_t technology_count = 0;
    uint32_t signal_begin = 0;
    uint32_t signal_count = 0;
    uint32_t gate_begin = 0;
    uint32_t gate_count = 0;
    uint32_t stance_begin = 0;
    uint32_t stance_count = 0;
    std::array<int32_t, 3> support_threshold_q16{};
    int32_t exclusion_group_id = -1;
};

struct RuntimeIdeologyPodClassStance {
    int32_t class_index = -1;
    std::array<int32_t, 3> stance_q16{};
    std::array<int32_t, 3> critical_min_q16{{-65537, -65537, -65537}};
};

struct RuntimeIdeologyPodSynergyRequirement {
    int32_t ideology_id = -1;
    int32_t minimum_level = 0;
    uint8_t location_mask = 0;
    uint8_t reserved[3]{};
};

struct RuntimeIdeologyPodSynergy {
    uint32_t requirement_begin = 0;
    uint32_t requirement_count = 0;
};

struct RuntimeIdeologyPodCatalog {
    uint32_t abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t country_catalog_hash = 0;
    uint64_t class_hash = 0;
    uint32_t class_count = 0;
    uint32_t technology_count = 0;
    uint32_t research_signal_count = 0;
    uint32_t gate_count = 0;
    int32_t ideology_capacity = 6;
    int32_t spirit_capacity = 3;
    int64_t offer_cost_q16 = 65536;
    int64_t starting_points_q16 = 0;
    int32_t owner_influence_weight = 2;
    int64_t funds_per_influence = 1000000;
    uint32_t max_commands_per_slice = 4096;
    uint32_t max_transition_commands = 256;
    uint32_t max_transition_polls_per_slice = 4096;
    uint32_t max_active_visits_per_slice = 1024;
    std::vector<RuntimeIdeologyPodDefinition> definitions;
    std::vector<RuntimeIdeologyPodLevel> levels;
    std::vector<int32_t> technology_requirements;
    std::vector<int32_t> signal_requirements;
    std::vector<int32_t> gate_requirements;
    std::vector<RuntimeIdeologyPodClassStance> class_stances;
    std::vector<RuntimeIdeologyPodSynergyRequirement> synergy_requirements;
    std::vector<RuntimeIdeologyPodSynergy> synergies;
    std::vector<uint32_t> ideology_synergy_offsets;
    std::vector<int32_t> ideology_synergy_ids;
};

struct RuntimeIdeologyOpinionSnapshot {
    uint64_t revision = 0;
    uint64_t class_hash = 0;
    int64_t committed_day = -1;
    uint32_t country_count = 0;
    uint32_t class_count = 0;
    std::vector<uint64_t> country_handles;
    std::vector<uint32_t> country_generations;
    std::vector<int64_t> population;
    std::vector<int64_t> funds;
    std::vector<int64_t> owner_employed;
    std::vector<int64_t> satisfaction_weighted;
    std::vector<int32_t> satisfaction_q16;
};

struct RuntimeIdeologyPodCommand {
    uint64_t request_id = 0;
    int32_t source_priority = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t submit_order = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    RuntimeIdeologyPodOpcode opcode = RuntimeIdeologyPodOpcode::DISCOVER;
    uint16_t reserved = 0;
    uint64_t country_handle = 0;
    int32_t ideology_id = -1;
    int64_t value_q16 = 0;
    uint32_t offer_generation = 0;
    int32_t choice_index = -1;
    int32_t gate_id = -1;
};

struct RuntimeIdeologyPodIdeaState {
    int64_t understanding_q16 = 0;
    int32_t level = -1;
    uint64_t entered_levels = 0;
    uint32_t generation = 1;
    RuntimeIdeologyPodLocation location = RuntimeIdeologyPodLocation::INACTIVE;
    uint8_t reserved[3]{};
};

struct RuntimeIdeologyPodOffer {
    uint32_t generation = 0;
    std::array<int32_t, 3> ideology_ids{{-1, -1, -1}};
    uint8_t active = 0;
    uint8_t reserved[3]{};
};

struct RuntimeIdeologyPodCountryState {
    uint64_t handle = 0;
    uint32_t generation = 0;
    int64_t ideology_points_q16 = 0;
    uint64_t rng_state = 0;
    uint64_t draw_sequence = 0;
    int32_t ideology_slots_used = 0;
    int32_t spirit_slots_used = 0;
    uint64_t opinion_revision = 0;
    RuntimeIdeologyPodOffer offer;
    std::vector<uint64_t> known_bits;
    std::vector<uint64_t> gate_bits;
    std::vector<uint64_t> synergy_bits;
    std::vector<RuntimeIdeologyPodIdeaState> ideas;
    std::vector<uint32_t> active_idea_ids;
};

struct RuntimeIdeologyPodTransition {
    uint64_t intent_id = 0;
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    int64_t effective_day = 0;
    uint32_t country_slot = 0;
    uint32_t country_generation = 0;
    int32_t ideology_id = -1;
    int32_t desired_level = -1;
    uint64_t desired_entered_levels = 0;
    RuntimeIdeologyPodLocation desired_location = RuntimeIdeologyPodLocation::INACTIVE;
    uint8_t intent_emitted = 0;
    uint8_t reserved[2]{};
    std::vector<uint64_t> desired_synergy_bits;
};

struct RuntimeIdeologyPodReceipt {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    RuntimeIdeologyPodReceiptStatus status = RuntimeIdeologyPodReceiptStatus::PENDING;
    RuntimeIdeologyPodOpcode opcode = RuntimeIdeologyPodOpcode::DISCOVER;
    uint64_t country_handle = 0;
    int32_t ideology_id = -1;
    int64_t settled_day = -1;
    uint32_t reason_code = 0;
};

struct RuntimeIdeologyPodProducerWatermark {
    uint32_t producer_id = 0;
    uint32_t reserved = 0;
    uint64_t sequence = 0;
};

struct RuntimeIdeologyPodSnapshot {
    uint32_t abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t input_generation = 0;
    uint64_t opinion_revision = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    int64_t round_day = -1;
    RuntimeIdeologyPodPhase phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
    uint32_t pending_cursor = 0;
    uint32_t command_cursor = 0;
    uint32_t active_country_cursor = 0;
    uint32_t active_idea_cursor = 0;
    uint64_t next_submit_order = 1;
    std::vector<RuntimeIdeologyPodCountryState> countries;
    std::vector<RuntimeIdeologyPodProducerWatermark> producer_high_watermarks;
    std::vector<RuntimeIdeologyPodCommand> commands;
    std::vector<RuntimeIdeologyPodTransition> pending_transitions;
    std::vector<RuntimeIdeologyPodReceipt> receipts;
};

struct RuntimeIdeologyPodPlan {
    RuntimeIdeologyPodSnapshot next_snapshot;
    std::vector<RuntimeDomainIntent> intents;
    uint64_t base_generation = 0;
    uint64_t input_generation = 0;
    uint64_t plan_hash = 0;
    uint32_t transition_visits = 0;
    uint32_t commands_consumed = 0;
    uint32_t active_visits = 0;
    uint8_t completed_day = 0;
    uint8_t preflight_ok = 0;
    uint8_t committed = 0;
    char error[64]{};
};

struct RuntimeIdeologyPodSaveSection {
    uint32_t abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t state_hash = 0;
    std::vector<uint8_t> payload;
};

class RuntimeIdeologyPodAuthority {
public:
    RuntimeIdeologyPodAuthority();
    void reset();
    bool configure(const RuntimeIdeologyPodCatalog &catalog, std::string &error);
    bool bootstrap(const RuntimeCountryPodSnapshot &country,
                   const RuntimeIdeologyOpinionSnapshot &opinion,
                   std::string &error);
    bool queue_command(RuntimeIdeologyPodCommand command, std::string &error);
    bool plan_day(int64_t day, const RuntimeCountryPodSnapshot &country,
                  const RuntimeIdeologyOpinionSnapshot &opinion,
                  const std::vector<RuntimeDomainAck> &acks,
                  RuntimeIdeologyPodPlan &plan, std::string &error);
    bool commit_day(RuntimeIdeologyPodPlan &plan, std::string &error);
    void discard_plan() noexcept { _plan_ready = false; }
    const RuntimeIdeologyPodSnapshot &snapshot() const noexcept { return _current; }
    const RuntimeIdeologyPodCatalog &catalog() const noexcept { return _catalog; }
    bool configured() const noexcept { return _configured; }
    uint64_t catalog_hash() const noexcept { return _catalog.catalog_hash; }
    void serialize(std::vector<uint8_t> &out) const;
    bool restore(const uint8_t *data, size_t size, std::string &error);
    static bool self_test(std::string &error);

private:
    static bool command_less(const RuntimeIdeologyPodCommand &a,
                             const RuntimeIdeologyPodCommand &b) noexcept;
    static uint64_t compute_catalog_hash(const RuntimeIdeologyPodCatalog &catalog);
    static uint64_t compute_state_hash(const RuntimeIdeologyPodSnapshot &state);
    bool validate_catalog(const RuntimeIdeologyPodCatalog &catalog,
                          std::string &error) const;
    bool validate_inputs(const RuntimeCountryPodSnapshot &country,
                         const RuntimeIdeologyOpinionSnapshot &opinion,
                         std::string &error) const;
    bool validate_command(const RuntimeIdeologyPodCommand &command,
                          std::string &error) const;
    bool apply_command(RuntimeIdeologyPodSnapshot &state,
                       const RuntimeCountryPodSnapshot &country,
                       const RuntimeIdeologyOpinionSnapshot &opinion,
                       const RuntimeIdeologyPodCommand &command,
                       RuntimeIdeologyPodPlan &plan, std::string &error) const;
    bool begin_transition(RuntimeIdeologyPodSnapshot &state, uint32_t country_slot,
                          int32_t ideology_id, int32_t desired_level,
                          RuntimeIdeologyPodLocation desired_location,
                          uint64_t entered_levels,
                          const RuntimeIdeologyPodCommand *command,
                          int64_t day, RuntimeIdeologyPodPlan &plan,
                          std::string &error) const;
    void emit_transition(RuntimeIdeologyPodTransition &transition,
                         RuntimeIdeologyPodPlan &plan) const;
    bool apply_ack(RuntimeIdeologyPodSnapshot &state,
                   const RuntimeDomainAck &ack, int64_t day,
                   std::string &error) const;
    bool support_allows(const RuntimeIdeologyPodSnapshot &state,
                        const RuntimeIdeologyOpinionSnapshot &opinion,
                        uint32_t country_slot, int32_t ideology_id,
                        uint32_t direction) const;
    bool requirements_met(const RuntimeIdeologyPodSnapshot &state,
                          const RuntimeCountryPodSnapshot &country,
                          uint32_t country_slot, int32_t ideology_id) const;
    int32_t unlocked_level(const RuntimeIdeologyPodIdeaState &idea,
                           int32_t ideology_id) const;
    void compute_synergies(const RuntimeIdeologyPodCountryState &country,
                           int32_t override_ideology,
                           int32_t override_level,
                           RuntimeIdeologyPodLocation override_location,
                           std::vector<uint64_t> &out) const;
    uint64_t transition_identity(const RuntimeIdeologyPodTransition &transition,
                                 RuntimeIdeologyPodOpcode opcode) const;

    RuntimeIdeologyPodCatalog _catalog;
    RuntimeIdeologyPodSnapshot _current;
    RuntimeIdeologyPodSnapshot _planned;
    bool _configured = false;
    bool _plan_ready = false;
};

} // namespace pk
