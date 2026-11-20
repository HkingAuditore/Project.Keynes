#pragma once

#include <cstdint>
#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

struct RuntimeEraRewardRequest {
    enum class Kind {
        BIND_PLAYER, SELECT, BIND_ADVANCEMENT, RESTORE_ADVANCEMENT,
        START_ADVANCEMENT, PAUSE_ADVANCEMENT, RESUME_ADVANCEMENT, SET_ADVANCEMENT_POLICY,
    };
    Kind kind = Kind::SELECT;
    uint64_t country_handle = 0;
    int64_t offer_generation = 0;
    int64_t effective_day = -1;
    int32_t choice = -1;
    int64_t advancement_sequence = 0;
    godot::Dictionary advancement;
    godot::Dictionary result;
    bool done = false; // Guarded by the executor control mutex.

    const char *command() const {
        switch (kind) {
            case Kind::SELECT: return "era_reward.choose";
            case Kind::START_ADVANCEMENT: return "era.advance.start";
            case Kind::PAUSE_ADVANCEMENT: return "era.advance.pause";
            case Kind::RESUME_ADVANCEMENT: return "era.advance.resume";
            case Kind::SET_ADVANCEMENT_POLICY: return "procurement.set_policy";
            default: return nullptr;
        }
    }
};

struct RuntimeEraRewardView {
    godot::Dictionary offer;
    bool needs_choice = false;
};

} // namespace pk
