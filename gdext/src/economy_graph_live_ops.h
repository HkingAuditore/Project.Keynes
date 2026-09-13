#pragma once

#include "economy_graph_kernels.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pk {

class NativeEconomyRuntime;

// Live (or probe) StageOps bound to NativeEconomyRuntime SoA. mutate_=false is
// the hash/work-unit probe path used by production ACTIVE attach; mutate_=true
// routes through named economy_kernel_* TUs → economy_dispatch_mutate_stage.
class NativeEconomyGraphStageOps final : public EconomyGraphStageOps {
public:
    NativeEconomyGraphStageOps(NativeEconomyRuntime *runtime, bool mutate);

    bool bind_view(EconomySoAView &view, std::string &error) override;
    bool run_stage(RuntimeEconomyGraphStage stage, EconomyStageCursor &cursor,
                   const RuntimeEconomyEpochInput &input,
                   EconomyStageResult &result, std::string &error) override;
    uint64_t state_hash() const override;
    bool capture_probe(std::vector<uint8_t> &bytes,
                       std::string &error) const override;
    bool restore_probe(const uint8_t *bytes, size_t size,
                       std::string &error) override;

    NativeEconomyRuntime *runtime() const noexcept { return _runtime; }
    bool mutate() const noexcept { return _mutate; }

private:
    NativeEconomyRuntime *_runtime = nullptr;
    bool _mutate = false;
    uint64_t _probe_generation = 0;
    int64_t _probe_committed_day = -1;
    uint64_t _probe_state_hash = 0;
};

} // namespace pk
