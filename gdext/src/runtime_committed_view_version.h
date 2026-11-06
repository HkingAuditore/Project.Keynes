#pragma once
#include <cstdint>
namespace pk {
// Diagnostic cursor; reset with the owner, never serialized.
struct RuntimeCommittedViewVersion {
    uint64_t generation = 0;
    int64_t day = -1;
    bool observe(uint64_t next_generation, int64_t next_day, bool committed) {
        if (!committed || next_generation < generation || next_day < day ||
            (next_generation == generation && next_day != day)) return false;
        generation = next_generation;
        day = next_day;
        return true;
    }
};
} // namespace pk
