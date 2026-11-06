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
};
} // namespace pk
