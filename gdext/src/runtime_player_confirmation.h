#pragma once

#include <atomic>
#include <cstdint>
#include <deque>
#include <godot_cpp/variant/dictionary.hpp>
#include <map>
#include <memory>

namespace pk {

struct RuntimePlayerConfirmationRequest {
    enum class Kind { DISMISS_IDEOLOGY, POPUP_POLICY };
    Kind kind;
    int64_t value;
    int64_t day;
};

struct RuntimePlayerConfirmationView {
    int64_t day = -1;
    const char *reason = nullptr;
    int32_t family_offer_offset = -1;
    godot::Dictionary family_offer;
    uint32_t ideology_generation = 0;
    bool hide_popups = false;
};

struct RuntimeEraRewardRequest;

struct RuntimePlayerConfirmation {
    // A dismissal acknowledges one offer generation without changing the offer.
    bool hide_popups = false;
    uint32_t dismissed_ideology = 0;
    std::map<int64_t, bool> popup_updates;
    std::deque<std::shared_ptr<RuntimeEraRewardRequest>> era_selections;
    std::deque<std::shared_ptr<RuntimeEraRewardRequest>> era_advancement;
    std::deque<RuntimePlayerConfirmationRequest> requests; // control mutex
    bool ideology_input_changed = false; // control mutex
    std::atomic<int64_t> advance_through{-1};
    std::shared_ptr<const RuntimePlayerConfirmationView> published;
};

} // namespace pk
