#pragma once
#include "economy_csv_recorder.h"

namespace pk {
// Runs on the simulation owner. Freezes committed values for a file writer
// which has no access to NativeEconomyRuntime internals.
class EconomyRecordSource final {
public:
    using Config = EconomyCsvRecorder::Config;
    using Batch = EconomyCsvRecorder::Batch;
    bool configure(const Config &, const NativeEconomyRuntime &,
                   std::array<Batch, 2> &, std::string &error);
    static int64_t committed_epoch(const NativeEconomyRuntime &runtime);
    int64_t projected_rows(const NativeEconomyRuntime &runtime) const;
    bool fill_batch(Batch &, NativeEconomyRuntime &,
                    const std::vector<const float *> &resources,
                    int64_t row_id, int64_t expected_rows, std::string &error);
    void worker_resources(const NativeEconomyRuntime &,
                          std::vector<std::vector<float>> &) const;
    const Config &config() const { return _config; }
    const std::vector<int32_t> &sample_cells() const { return _sample_cells; }
    const std::vector<std::string> &good_ids() const { return _good_ids; }
    const std::vector<std::string> &good_category_ids() const { return _good_category_ids; }
    const std::vector<int32_t> &good_storage_modes() const { return _good_storage_modes; }
private:
    Config _config;
    std::vector<std::string> _good_ids;
    std::vector<std::string> _good_category_ids;
    std::vector<int32_t> _good_storage_modes;
    std::vector<int32_t> _sample_cells;
    std::vector<int32_t> _sample_cell_positions;
    // Recorder resource rows follow the caller's slot order, while native
    // building deltas follow the economy catalog's stable-id order.
    std::vector<int32_t> _resource_runtime_indices;
    std::vector<float> _previous_resource_reserve;
    std::vector<int64_t> _pending_resource_artificial;
    std::vector<uint8_t> _resource_history_valid;
};
}
