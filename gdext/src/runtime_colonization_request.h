#pragma once

#include <cstdint>
#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

struct RuntimeColonizationRequest {
    enum class Kind { QUOTES, QUOTE_DETAIL, START };
    Kind kind = Kind::QUOTES;
    int64_t country_handle = 0;
    int64_t family_handle = 0;
    int32_t source_cell = -1;
    int32_t target_cell = -1;
    int32_t offset = 0;
    int32_t limit = 0;
    int64_t population = 0;
    int64_t quote_token = 0;
    int64_t effective_day = -1;
    int64_t sequence = 0;
    godot::Dictionary result;
    bool done = false; // _control_mutex
};

} // namespace pk
