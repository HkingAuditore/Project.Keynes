Dictionary DCWorldExt::start_economy_csv_recording(const Dictionary &config) {
    Dictionary out;
    // Do not hold the economy authority boundary across start()/file-open.
    // That lock is also the worker's per-day gate; holding it while the main
    // thread waits on CSV open starves Country peer pumps and nails the sim
    // on climate_input_capacity_day_barrier. Probe busy first, then start
    // unlocked, and only take the lock briefly to attach.
    if (_runtime_host) {
        auto probe = _runtime_host->try_lock_economy_input_capture();
        if (!probe.owns_lock()) {
            out["ok"] = false;
            out["error_code"] = "economy_boundary_busy";
            return out;
        }
        probe.unlock();
    }
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["error_code"] = "economy_unavailable";
        return out;
    }
    EconomyCsvRecorder::Config native;
    native.enabled[EconomyCsvRecorder::SUMMARY] = config.get("record_summary", true);
    native.enabled[EconomyCsvRecorder::COHORTS] = config.get("record_cohorts", true);
    native.enabled[EconomyCsvRecorder::BUILDINGS] = config.get("record_buildings", true);
    native.enabled[EconomyCsvRecorder::RESOURCES] = config.get("record_resources", true);
    native.enabled[EconomyCsvRecorder::MARKET] = config.get("record_market", true);
    native.cell_stride = static_cast<int32_t>(config.get("cell_stride", 1));
    native.max_rows = static_cast<int64_t>(config.get("max_rows", int64_t{5'000'000}));
    native.test_write_delay_ms = std::clamp<int32_t>(
        static_cast<int32_t>(config.get("test_write_delay_ms", 0)), 0, 5000);
    native.test_fail_after_bytes = std::max<int64_t>(
        -1, static_cast<int64_t>(config.get("test_fail_after_bytes", int64_t{-1})));

    auto copy_i32 = [](const PackedInt32Array &src, std::vector<int32_t> &dst) {
        dst.resize(static_cast<size_t>(src.size()));
        if (src.size() > 0) std::copy(src.ptr(), src.ptr() + src.size(), dst.begin());
    };
    copy_i32(config.get("q_arr", PackedInt32Array()), native.q);
    copy_i32(config.get("r_arr", PackedInt32Array()), native.r);
    copy_i32(config.get("s_arr", PackedInt32Array()), native.s);
    copy_i32(config.get("cell_indices", PackedInt32Array()), native.cell_indices);
    copy_i32(config.get("resource_slot_ids", PackedInt32Array()), native.resource_slot_ids);

    const PackedStringArray resource_ids = config.get("resource_ids", PackedStringArray());
    for (int64_t i = 0; i < resource_ids.size(); ++i) {
        const auto bytes = String(resource_ids[i]).utf8();
        native.resource_ids.emplace_back(bytes.get_data(), static_cast<size_t>(bytes.length()));
    }
    const Dictionary paths = config.get("paths", Dictionary());
    static constexpr const char *keys[EconomyCsvRecorder::DIM_COUNT] = {
        "summary", "cohorts", "buildings", "resources", "market"
    };
    for (int32_t dim = 0; dim < EconomyCsvRecorder::DIM_COUNT; ++dim) {
        const String path = paths.get(keys[dim], String());
        const auto bytes = path.utf8();
        native.paths[dim].assign(bytes.get_data(), static_cast<size_t>(bytes.length()));
    }

    if (_economy_csv_recorder == nullptr)
        _economy_csv_recorder = new EconomyCsvRecorder();
    std::string error;
    EconomyCsvRecorder *recorder =
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder);
    const bool ok = recorder->start(native, *runtime_from(_economy_runtime), error);
    if (ok) {
        if (_runtime_host) {
            auto boundary = _runtime_host->try_lock_economy_input_capture();
            if (!boundary.owns_lock()) {
                recorder->request_stop();
                out = recorder->status();
                out["ok"] = false;
                out["error_code"] = "economy_boundary_busy";
                return out;
            }
            runtime_from(_economy_runtime)->attach_csv_recorder(recorder);
        } else {
            runtime_from(_economy_runtime)->attach_csv_recorder(recorder);
        }
    }
    out = recorder->status();
    out["ok"] = ok;
    if (!ok && !error.empty()) out["error_message"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::request_stop_economy_csv_recording() {
    if (_economy_csv_recorder == nullptr) return get_economy_csv_recording_status();
    EconomyCsvRecorder *recorder =
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder);
    recorder->request_stop();
    return recorder->status();
}

Dictionary DCWorldExt::get_economy_csv_recording_status() const {
    if (_economy_csv_recorder != nullptr)
        return static_cast<EconomyCsvRecorder *>(_economy_csv_recorder)->status();
    Dictionary out;
    out["state"] = "idle";
    out["schema_version"] = EconomyCsvRecorder::SCHEMA_VERSION;
    out["recording"] = false;
    out["draining"] = false;
    out["captured_epochs"] = 0;
    out["written_epochs"] = 0;
    out["captured_rows"] = 0;
    out["written_rows"] = 0;
    out["bytes_written"] = 0;
    out["paths"] = PackedStringArray();
    return out;
}
