#pragma once

#include <cstdint>
#include <vector>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

struct RuntimeEraAdvancement {
    enum class Phase { IDLE, PURCHASING, PAUSED, COMPLETING };

    struct Policy {
        int32_t treasury = 200;
        int32_t research = 5000;
        int32_t era = -1;
        int32_t colonization = -1;
    };

    uint64_t country = 0;
    godot::Array catalog;
    std::vector<std::vector<int32_t>> regime_definitions;
    int32_t observed_regime = -1;
    int32_t conditions_required = 3;
    double technology_ratio = 0.6;
    Policy policy;
    Phase phase = Phase::IDLE;
    int32_t target = -1;
    int32_t frozen_territory = 0;
    godot::PackedStringArray goods;
    godot::PackedInt64Array required;
    int32_t known_era = -1;
    int32_t trade_era = -1;
    int64_t trade = 0;
    int64_t last_trade_total = -1;
    int64_t completion_day = -1;
    int64_t next_sequence = 1;
    int64_t last_target_day = -1;
    int64_t last_policy_day = -1;
    bool prelude_granted = false;

    const char *phase_name() const;
    void clear_purchase();
    godot::Dictionary business_state() const;
    godot::Dictionary save() const;
    void restore(const godot::Dictionary &saved);
};

struct RuntimeEraAdvancementView {
    godot::Dictionary model;
    godot::Dictionary state;
    godot::Dictionary save;
};

} // namespace pk
