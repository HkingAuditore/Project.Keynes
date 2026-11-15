#pragma once
#include <cstdint>
#include <vector>
namespace pk {
struct RuntimeGoldenDomain {
    const char *id;
    const char *scope;
    int64_t state_day;
    uint64_t hash;
};
struct RuntimeGoldenSnapshot {
    bool ready = false;
    int64_t day = -1;
    std::vector<RuntimeGoldenDomain> domains;
    // Whole economy runtime hash taken under the day boundary. The worker
    // mutates that runtime, so a main-thread state_hash() outside the boundary
    // races it and consumes the paged hash's dirty marks.
    bool whole_economy_ready = false;
    uint64_t whole_economy_hash = 0;
};
} // namespace pk
