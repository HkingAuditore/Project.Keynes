#pragma once

#include "native_simulation_host.h"
#include "native_simulation_day_support.h"

namespace pk {
struct NativeSimulationHost::DayExecution {
    RuntimeDayPlan &plan;
    const RuntimeEnvironmentSnapshot *&environment;
    const std::vector<RuntimeCommandPacket> &day_commands;
    std::vector<RuntimeCommandReceipt> &day_receipts;
    uint64_t admitted_submit_order;
    RuntimeDayCommit &commit;
    const RuntimeEnvironmentSnapshot *climate_hashed_input = nullptr;
    uint64_t climate_hashed_input_hash = 0;
    bool climate_authority_requested = false;
    bool active_climate_ok = false;
    std::vector<RuntimeCommandPacket> gameplay_event_commands;
};
} // namespace pk
