#pragma once

#include "runtime_climate_kernel.h"

#include <cstdint>
#include <string>
#include <vector>

namespace pk {

struct RuntimeClimateVerticalReport {
    uint64_t work_units = 0;
    uint32_t changed_cells = 0;
    uint64_t state_hash = 0;
    uint64_t input_hash = 0;
    uint64_t catalog_hash = 0;
    uint64_t input_generation = 0;
    uint64_t reference_state_hash = 0;
    uint8_t parity_compared = 0;
    uint8_t parity_matched = 0;
    char parity_reason[64]{};
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    double plan_ms = 0.0;
    double replay_ms = 0.0;
    std::array<double, RUNTIME_CLIMATE_STAGE_COUNT> stage_ms{};
    std::array<uint64_t, RUNTIME_CLIMATE_STAGE_COUNT> stage_work{};
    char error[64]{};
};

struct RuntimeClimateSnapshot {
    uint64_t generation = 0;
    int64_t committed_day = -1;
    uint64_t input_generation = 0;
    uint64_t catalog_hash = 0;
    uint64_t state_hash = 0;
    uint32_t dirty_families = 0;
    RuntimeClimateStore payload;
};

class RuntimeClimateAuthority {
public:
    void reset(uint32_t cell_count);
    bool plan_day(int64_t day, const RuntimeEnvironmentSnapshot &environment,
                  RuntimeClimateVerticalReport &report);
    bool commit_day(int64_t day, RuntimeClimateVerticalReport &report);
    // Drop a pending next-lane after a preflight/parity rejection without
    // mutating the last committed store. The same logical day can then be
    // retried from a clean base state.
    void discard_plan();

    const RuntimeClimateStore &store() const { return _store; }
    const RuntimeClimateVerticalReport &last_report() const { return _last_report; }
    const RuntimeClimateCatalog &catalog() const { return _catalog; }
    uint64_t last_input_generation() const { return _last_input_generation; }
    RuntimeClimateSnapshot snapshot() const {
        RuntimeClimateSnapshot result;
        result.generation = _store.generation;
        result.committed_day = _store.committed_day;
        result.input_generation = _last_input_generation;
        result.catalog_hash = _catalog.hash;
        result.state_hash = _store.state_hash();
        result.payload = _store;
        return result;
    }

    bool serialize(std::vector<uint8_t> &bytes, std::string &error) const;
    bool restore(const uint8_t *bytes, size_t size, std::string &error);
    static bool self_test(std::string &error);

private:
    bool seed_from_input(const RuntimeEnvironmentSnapshot &environment,
                         std::string &error);

    RuntimeClimateKernel _kernel;
    RuntimeClimateCatalog _catalog;
    RuntimeClimateStore _store;
    RuntimeClimateStore _next;
    bool _catalog_ready = false;
    bool _plan_ready = false;
    int64_t _planned_day = -1;
    uint64_t _last_input_generation = 0;
    RuntimeClimateVerticalReport _last_report{};
};

} // namespace pk
