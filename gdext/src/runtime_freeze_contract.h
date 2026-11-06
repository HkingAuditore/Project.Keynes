#pragma once

#include <cstdint>

namespace pk {

// Common immutable version for same-day Freeze reads.
struct RuntimeFrozenInputVersion {
    uint64_t session_epoch = 0;
    int64_t day = -1;
    uint64_t generation = 0;
    uint64_t command_watermark = 0;
    uint8_t committed = 0;
    uint8_t in_flight = 0;

    bool valid_for(int64_t expected_day, uint64_t expected_generation) const noexcept {
        return committed != 0 && in_flight == 0 && day == expected_day &&
            generation == expected_generation && session_epoch != 0;
    }
};

struct RuntimeFreezeReadSet {
    uint32_t registered_mask = 0;

    bool register_read(uint32_t domain_mask,
                       const RuntimeFrozenInputVersion &version,
                       int64_t expected_day,
                       uint64_t expected_generation) noexcept {
        if (!version.valid_for(expected_day, expected_generation)) return false;
        registered_mask |= domain_mask;
        return true;
    }
};

} // namespace pk
