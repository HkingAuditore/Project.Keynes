#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

class NativeCountryRuntime;
class EffectRuntime;

// Country-scoped ideology authority.  It deliberately owns only ideology
// collection/progression state; Country, Effect and Modifier retain their
// existing domain ownership.
class NativeIdeologyRuntime {
public:
    static constexpr int32_t PROTOCOL_VERSION = 1;
    static constexpr int32_t SAVE_SCHEMA_VERSION = 2;
    static constexpr int64_t Q16_ONE = 65536;

    enum Acquisition : uint8_t { DISCOVER = 1, DRAW = 2 };
    enum CommandOpcode : int32_t {
        DISCOVER_IDEOLOGY = 1,
        GRANT_IDEOLOGY_POINTS = 2,
        OPEN_IDEOLOGY_OFFER = 3,
        CHOOSE_IDEOLOGY_OFFER = 4,
        EQUIP_IDEOLOGY = 5,
        UNEQUIP_IDEOLOGY = 6,
        PROMOTE_NATIONAL_SPIRIT = 7,
        ADD_UNDERSTANDING = 8,
        SET_IDEOLOGY_GATE = 9,
    };
    enum Location : uint8_t { INACTIVE = 0, IDEOLOGY = 1, NATIONAL_SPIRIT = 2 };

    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) { _effect_runtime = runtime; }

    godot::Dictionary configure(const godot::Dictionary &catalog);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
    // TriggerRuntime calls this typed ingress after its own event/idempotency
    // checks. The command still joins the ideology-owned deterministic queue.
    bool submit_trigger_command_pod(int32_t opcode, int64_t effective_day,
                                    int32_t source_priority, int64_t sequence,
                                    uint64_t country_handle, int32_t ideology_id,
                                    int64_t value_q16, uint32_t offer_generation,
                                    int32_t choice_index, int32_t gate_id,
                                    std::string &error);
    godot::Dictionary run_daily(int64_t day_index);
    bool should_run(int64_t day_index) const;
    godot::Dictionary snapshot(int64_t country_handle) const;
    godot::Dictionary explain(int64_t country_handle, int32_t ideology_id) const;
    godot::Dictionary report() const;
    godot::PackedByteArray capture() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_state();

private:
    struct Level {
        int64_t threshold_q16 = 0;
        int64_t daily_understanding_q16 = 0;
        int32_t persistent_begin = 0;
        int32_t persistent_count = 0;
        int32_t on_enter_begin = 0;
        int32_t on_enter_count = 0;
    };
    struct EffectTemplate {
        int32_t action = 0;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct Definition {
        std::string stable_id;
        uint8_t acquisition = DISCOVER | DRAW;
        int32_t rarity_weight = 1;
        int32_t ideology_cost = 1;
        int32_t spirit_cost = 1;
        int32_t min_spirit_level = 0;
        int32_t level_begin = 0;
        int32_t level_count = 0;
        int32_t technology_requirement_begin = 0;
        int32_t technology_requirement_count = 0;
        int32_t signal_requirement_begin = 0;
        int32_t signal_requirement_count = 0;
        int32_t gate_requirement_begin = 0;
        int32_t gate_requirement_count = 0;
    };
    struct IdeaState {
        int32_t ideology_id = -1;
        int64_t understanding_q16 = 0;
        int32_t level = -1;
        uint64_t entered_levels = 0;
        uint32_t generation = 1;
        uint8_t location = INACTIVE;
        int64_t binding_id = 0;
        uint32_t binding_generation = 0;
        uint64_t binding_signature = 0;
        uint64_t binding_program_hash = 0;
        // The displayed state is an intent while an Effect transaction is in
        // flight. The previous state is retained so a rejected transaction can
        // be rolled back without leaking a Modifier or a slot reservation.
        struct Transition {
            uint8_t active = 0;
            int32_t previous_level = -1;
            uint64_t previous_entered_levels = 0;
            uint32_t previous_generation = 1;
            uint8_t previous_location = INACTIVE;
            uint64_t entered_on_success = 0;
            std::vector<int64_t> transaction_ids;
        } transition;
    };
    struct Offer {
        uint32_t generation = 0;
        std::array<int32_t, 3> ideology_ids{{-1, -1, -1}};
        uint8_t active = 0;
    };
    struct CountryState {
        uint64_t handle = 0;
        int64_t ideology_points_q16 = 0;
        uint64_t rng_state = 0;
        uint64_t draw_sequence = 0;
        std::vector<uint64_t> known_bits;
        std::vector<uint64_t> gate_bits;
        std::vector<IdeaState> ideas;
        std::unordered_map<int32_t, int32_t> idea_indices;
        std::vector<int32_t> active_ideologies;
        Offer offer;
    };
    struct Command {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int32_t source_priority = 0;
        int64_t sequence = 0;
        uint64_t country_handle = 0;
        int32_t ideology_id = -1;
        int64_t value_q16 = 0;
        uint32_t offer_generation = 0;
        int32_t choice_index = -1;
        int32_t gate_id = -1;
        uint64_t submit_order = 0;
    };

    bool validate_catalog(const godot::Dictionary &catalog, std::string &error);
    bool validate_command_shape(const Command &command, std::string &error) const;
    bool validate_country(uint64_t handle, int32_t &slot) const;
    CountryState *country_state_for(uint64_t handle, bool create);
    const CountryState *country_state_for(uint64_t handle) const;
    IdeaState *idea_state_for(CountryState &country, int32_t ideology_id, bool create);
    const IdeaState *idea_state_for(const CountryState &country, int32_t ideology_id) const;
    bool known(const CountryState &country, int32_t ideology_id) const;
    void set_known(CountryState &country, int32_t ideology_id);
    bool gate(const CountryState &country, int32_t gate_id) const;
    void set_gate(CountryState &country, int32_t gate_id, bool value);
    bool requirements_met(const CountryState &country, int32_t country_slot,
                          const Definition &definition) const;
    bool apply_command(const Command &command, int64_t day, std::string &error);
    bool open_offer(CountryState &country, int32_t country_slot, std::string &error);
    bool choose_offer(CountryState &country, const Command &command, std::string &error);
    bool equip(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    bool unequip(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    bool promote(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    void reconcile_level(IdeaState &state);
    int32_t unlocked_level(const IdeaState &state) const;
    bool start_transition(CountryState &country, IdeaState &state,
                          uint8_t location, int32_t level,
                          bool remove_previous_persistent,
                          bool apply_current_persistent,
                          uint64_t entered_on_success, int64_t day,
                          std::string &error);
    bool emit_level_effects(CountryState &country, IdeaState &state,
                            int32_t level, bool remove_persistent,
                            bool include_on_enter, int64_t day,
                            std::vector<int64_t> &transaction_ids,
                            std::string &error);
    bool emit_templates(uint64_t country_handle, int32_t ideology_id,
                        int32_t level, int32_t begin, int32_t count,
                        bool remove, int64_t day, uint64_t salt,
                        std::vector<int64_t> &transaction_ids,
                        std::string &error);
    void poll_transitions(CountryState &country);
    bool start_next_level_transition(CountryState &country, IdeaState &state,
                                     int64_t day, std::string &error);
    uint64_t unentered_level_mask(const IdeaState &state, int32_t through_level) const;
    void rebuild_active(CountryState &country);
    int32_t ideology_slot_cost(const CountryState &country) const;
    int32_t spirit_slot_cost(const CountryState &country) const;
    uint64_t next_random(CountryState &country);
    int32_t sample_weighted(CountryState &country, const std::vector<int32_t> &pool,
                            const std::vector<int64_t> &weights) const;
    void reset_runtime_state();
    uint64_t compute_catalog_hash() const;
    uint64_t compute_state_hash() const;
    uint64_t binding_id_for(uint64_t country_handle, int32_t ideology_id,
                            uint8_t location) const;
    uint64_t binding_signature_for(int32_t ideology_id, int32_t level) const;
    bool sync_external_binding(uint64_t country_handle, IdeaState &state,
                               std::string &error);

    bool _configured = false;
    uint64_t _catalog_hash = 0;
    int32_t _ideology_capacity = 6;
    int32_t _spirit_capacity = 3;
    int32_t _draw_count = 3;
    int64_t _offer_cost_q16 = Q16_ONE;
    int32_t _max_commands_per_slice = 4096;
    int32_t _gate_count = 0;
    int32_t _idea_words = 0;
    int32_t _gate_words = 0;
    std::vector<Definition> _definitions;
    std::vector<Level> _levels;
    std::vector<EffectTemplate> _persistent_templates;
    std::vector<EffectTemplate> _on_enter_templates;
    std::vector<int32_t> _technology_requirements;
    std::vector<int32_t> _signal_requirements;
    std::vector<int32_t> _gate_requirements;
    std::vector<CountryState> _countries;
    std::vector<Command> _commands;
    uint64_t _submit_order = 0;
    int64_t _last_day = -1;
    uint64_t _active_visits = 0;
    uint64_t _dormant_scan_count = 0;
    uint64_t _commands_applied = 0;
    uint64_t _commands_rejected = 0;
    uint64_t _offers_opened = 0;
    uint64_t _levels_advanced = 0;
    std::string _last_error;
    NativeCountryRuntime *_country_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
};

} // namespace pk
