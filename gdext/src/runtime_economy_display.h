#pragma once

#include <cstdint>
#include <deque>
#include <map>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

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

struct RuntimeFiscalHistory {
    void record(int64_t day, const RuntimeFiscalDisplay &sample);
    godot::Dictionary pack() const;

    int64_t country = 0;
    godot::PackedInt32Array days, cash_days, settlement_days;
    godot::PackedFloat32Array income, expense;
    godot::PackedInt64Array cash_values;
    godot::Array settlements;
    godot::Dictionary last_settlement;
};

} // namespace pk
