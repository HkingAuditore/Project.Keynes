#pragma once

#include <cstdint>
#include <deque>
#include <map>

#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

struct RuntimeGdpCell {
    int32_t cell = -1;
    int64_t population = 0;
    double per_day = 0.0;
    double accumulated = 0.0;
};

struct RuntimeGdpDisplay {
    uint64_t country = 0;
    int64_t day = -1;
    int64_t year_length = 365;
    double per_day = 0.0;
    double accumulated = 0.0;
    int64_t population = 0;
    bool backfilled = false;
    std::map<int32_t, RuntimeGdpCell> cells;
    std::deque<int32_t> trend_days;
    std::deque<float> trend;

    godot::Dictionary pack() const;
};

struct RuntimeFiscalDisplay {
    int64_t cash = 0;
    godot::Dictionary fiscal;
};

} // namespace pk
