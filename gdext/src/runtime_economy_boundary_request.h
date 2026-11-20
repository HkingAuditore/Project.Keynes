#pragma once

#include <cstdint>
#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

struct RuntimeEconomyBoundaryRequest {
    enum class Kind { QUOTES, QUOTE_DETAIL, START, CANCEL, FOUNDING_CHOICE, BUILD_CANAL };
    Kind kind = Kind::QUOTES;
    int64_t country_handle = 0;
    int64_t family_handle = 0;
    int32_t source_cell = -1;
    int32_t target_cell = -1;
    int32_t offset = 0;
    int32_t limit = 0;
    int64_t population = 0;
    int64_t quote_token = 0;
    int64_t subject_id = 0;
    int64_t offer_generation = 0;
    int32_t choice = -1;
    int64_t effective_day = -1;
    int64_t sequence = 0;
    godot::Dictionary result;
    bool done = false; // _control_mutex

    const char *command() const {
        switch (kind) {
            case Kind::START: return "family.colonization.start";
            case Kind::CANCEL: return "family.colonization.cancel";
            case Kind::FOUNDING_CHOICE: return "family.founding.choose";
            case Kind::BUILD_CANAL: return "infrastructure.canal.build";
            default: return nullptr;
        }
    }
};

} // namespace pk
