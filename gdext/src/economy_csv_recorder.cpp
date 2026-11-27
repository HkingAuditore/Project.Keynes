#include "economy_csv_recorder.h"

#include "economy_record_source.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <system_error>

#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {
using namespace godot;

using Clock = std::chrono::steady_clock;
void EconomyCsvRecorder::Batch::clear_rows() {
    epoch_id = -1;
    row_count = 0;
    summary.clear(); cohorts.clear(); buildings.clear(); resources.clear(); market.clear();
}

EconomyCsvRecorder::EconomyCsvRecorder() : _source(std::make_unique<EconomyRecordSource>()) {}
EconomyCsvRecorder::~EconomyCsvRecorder() { shutdown(); }

const char *EconomyCsvRecorder::state_name(int32_t state) {
    switch (state) {
        case 1: return "opening";
        case 2: return "recording";
        case 3: return "draining";
        case 4: return "completed";
        case 5: return "error";
        default: return "idle";
    }
}

bool EconomyCsvRecorder::start(const Config &config, NativeEconomyRuntime &runtime,
                               std::string &error) {
    shutdown();
    if (!_source->configure(config, runtime, _buffers, error)) return false;
    _config = _source->config();
    _good_ids = _source->good_ids();
    _good_category_ids = _source->good_category_ids();
    _good_storage_modes = _source->good_storage_modes();
    _buffer_states = {{FREE, FREE}};
    _ready.clear();
    _error_code.clear(); _error_message.clear();
    _last_captured_epoch = -1; _first_unrecorded_epoch = -1;
    _captured_epochs = 0; _written_epochs = 0;
    _captured_rows = 0; _written_rows = 0; _bytes_written = 0;
    _capture_us_last = 0; _capture_us_max = 0;
    _capture_samples_us.clear();
    _backpressure_wait_count = 0; _backpressure_wait_us = 0;
    _encode_us_last = 0; _write_us_last = 0;
    _open_done = false; _open_ok = false;
    _accepting = false; _stop_requested = false;
    _worker_busy = false; _worker_finished = false;
    _state = 1;
    _worker = std::thread(&EconomyCsvRecorder::worker_main, this);

    std::unique_lock<std::mutex> lock(_mutex);
    _open_cv.wait(lock, [&] { return _open_done; });
    if (!_open_ok) {
        error = _error_message.empty() ? "csv_open_failed" : _error_message;
        lock.unlock();
        if (_worker.joinable()) _worker.join();
        return false;
    }
    _accepting = true;
    _state = 2;
    return true;
}

bool EconomyCsvRecorder::wants_capture() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _accepting && _state == 2;
}


void EconomyCsvRecorder::set_terminal_locked(const std::string &code,
                                               const std::string &message,
                                               int64_t first_unrecorded_epoch) {
    _accepting = false;
    _stop_requested = true;
    _state = 3;
    _error_code = code;
    _error_message = message;
    _first_unrecorded_epoch = first_unrecorded_epoch;
}

bool EconomyCsvRecorder::capture_worker_committed(
        NativeEconomyRuntime &runtime, std::string &reason) {
    std::vector<std::vector<float>> lanes;
    _source->worker_resources(runtime, lanes);
    std::vector<const float *> arrays;
    arrays.reserve(lanes.size());
    for (const auto &lane : lanes) arrays.push_back(lane.empty() ? nullptr : lane.data());
    return capture_committed(runtime, arrays, reason);
}

bool EconomyCsvRecorder::capture_committed(
        NativeEconomyRuntime &runtime, const std::vector<const float *> &resource_arrays,
        std::string &reason) {
    const int64_t epoch_id = EconomyRecordSource::committed_epoch(runtime);
    if (epoch_id < 0) {
        reason = "not_committed";
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_accepting || _state != 2) {
            reason = "not_recording";
            return false;
        }
        if (epoch_id == _last_captured_epoch) {
            reason = "same_epoch";
            return false;
        }
    }
    const int64_t rows = _source->projected_rows(runtime);
    int32_t buffer_index = -1;
    int64_t epoch_row_id = 0;
    {
        std::unique_lock<std::mutex> lock(_mutex);
        if (!_accepting || _state != 2) {
            reason = "not_recording";
            return false;
        }
        if (epoch_id == _last_captured_epoch) {
            reason = "same_epoch";
            return false;
        }
        if (_captured_rows + rows > _config.max_rows) {
            set_terminal_locked("row_limit", "next committed epoch exceeds max_rows", epoch_id);
            reason = "row_limit";
            _cv.notify_all();
            return false;
        }
        auto find_free_buffer = [&]() {
            for (int32_t i = 0; i < 2; ++i)
                if (_buffer_states[i] == FREE) return i;
            return int32_t{-1};
        };
        buffer_index = find_free_buffer();
        if (buffer_index < 0) {
            const auto wait_start = Clock::now();
            ++_backpressure_wait_count;
            _cv.wait(lock, [&] {
                return find_free_buffer() >= 0 || !_accepting || _state != 2;
            });
            _backpressure_wait_us += std::chrono::duration_cast<std::chrono::microseconds>(
                Clock::now() - wait_start).count();
            if (!_accepting || _state != 2) {
                reason = _error_code.empty() ? "not_recording" : _error_code;
                return false;
            }
            buffer_index = find_free_buffer();
        }
        _buffer_states[buffer_index] = FILLING;
        epoch_row_id = _captured_epochs + 1;
    }

    const auto start_time = Clock::now();
    Batch &batch = _buffers[buffer_index];
    batch.clear_rows();
    std::string fill_error;
    const bool filled = _source->fill_batch(batch, runtime, resource_arrays, epoch_row_id, rows, fill_error);
    const int64_t elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - start_time).count();
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _capture_us_last = elapsed_us;
        _capture_us_max = std::max(_capture_us_max, elapsed_us);
        _capture_samples_us.push_back(elapsed_us);
        if (_capture_samples_us.size() > 256) _capture_samples_us.pop_front();
        if (!filled) {
            _buffer_states[buffer_index] = FREE;
            set_terminal_locked("capture_failed", fill_error, epoch_id);
            reason = fill_error;
            _cv.notify_all();
            return false;
        }
        _buffer_states[buffer_index] = READY;
        _ready.push_back(buffer_index);
        _last_captured_epoch = epoch_id;
        ++_captured_epochs;
        _captured_rows += batch.row_count;
    }
    _cv.notify_one();
    reason.clear();
    return true;
}


void EconomyCsvRecorder::worker_main() {
    std::string open_error;
    const bool opened = open_files(open_error);
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _open_ok = opened; _open_done = true;
        if (!opened) {
            _state = 5; _error_code = "open_failed"; _error_message = open_error;
            _worker_finished = true;
        }
    }
    _open_cv.notify_one();
    if (!opened) return;

    for (;;) {
        int32_t index = -1;
        {
            std::unique_lock<std::mutex> lock(_mutex);
            _cv.wait(lock, [&] { return !_ready.empty() || _stop_requested; });
            if (_ready.empty()) {
                if (_stop_requested) break;
                continue;
            }
            index = _ready.front(); _ready.pop_front();
            _buffer_states[index] = WRITING; _worker_busy = true;
        }
        int64_t bytes = 0;
        std::string write_error;
        if (_config.test_write_delay_ms > 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(_config.test_write_delay_ms));
        const bool ok = write_batch(_buffers[index], bytes, write_error);
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _worker_busy = false;
            if (ok) {
                ++_written_epochs; _written_rows += _buffers[index].row_count;
                _bytes_written += bytes;
                _buffers[index].clear_rows(); _buffer_states[index] = FREE;
            } else {
                _buffer_states[index] = FREE;
                _accepting = false; _stop_requested = true; _state = 5;
                _error_code = "write_failed"; _error_message = write_error;
                while (!_ready.empty()) {
                    const int32_t pending = _ready.front(); _ready.pop_front();
                    _buffers[pending].clear_rows(); _buffer_states[pending] = FREE;
                }
                _cv.notify_all();
                break;
            }
        }
        _cv.notify_all();
    }
    close_files();
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _worker_finished = true; _worker_busy = false;
        if (_state != 5) _state = _error_code.empty() ? 4 : 5;
    }
    _cv.notify_all();
}

void EconomyCsvRecorder::request_stop() {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_state != 1 && _state != 2 && _state != 3) return;
        _accepting = false; _stop_requested = true;
        if (_state != 5) _state = 3;
    }
    _cv.notify_all();
}

void EconomyCsvRecorder::shutdown() {
    request_stop();
    if (_worker.joinable()) _worker.join();
    close_files();
    std::lock_guard<std::mutex> lock(_mutex);
    if (_state == 1 || _state == 2 || _state == 3) _state = _error_code.empty() ? 4 : 5;
}

godot::Dictionary EconomyCsvRecorder::status() const {
    std::lock_guard<std::mutex> lock(_mutex);
    godot::Dictionary out;
    int64_t buffer_memory_bytes = 0;
    for (const Batch &batch : _buffers) {
        buffer_memory_bytes += static_cast<int64_t>(batch.summary.capacity() * sizeof(SummaryRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.cohorts.capacity() * sizeof(CohortRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.buildings.capacity() * sizeof(BuildingRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.resources.capacity() * sizeof(ResourceRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.market.capacity() * sizeof(MarketRow));
        buffer_memory_bytes += static_cast<int64_t>(batch.scratch_trade_inbound.capacity() * sizeof(int64_t));
        buffer_memory_bytes += static_cast<int64_t>(batch.scratch_trade_outbound.capacity() * sizeof(int64_t));
    }
    std::vector<int64_t> capture_samples(_capture_samples_us.begin(), _capture_samples_us.end());
    std::sort(capture_samples.begin(), capture_samples.end());
    const int64_t capture_p95_us = capture_samples.empty() ? 0 : capture_samples[
        std::min(capture_samples.size() - 1,
                 static_cast<size_t>(std::ceil(capture_samples.size() * 0.95)) - 1)];
    out["state"] = state_name(_state);
    out["schema_version"] = SCHEMA_VERSION;
    out["recording"] = _accepting && _state == 2;
    out["draining"] = _state == 3;
    out["captured_epochs"] = _captured_epochs;
    out["written_epochs"] = _written_epochs;
    out["last_captured_epoch"] = _last_captured_epoch;
    out["captured_rows"] = _captured_rows;
    out["written_rows"] = _written_rows;
    out["bytes_written"] = _bytes_written;
    out["buffer_memory_bytes"] = buffer_memory_bytes;
    out["queued_batches"] = static_cast<int64_t>(_ready.size()) + (_worker_busy ? 1 : 0);
    out["writer_busy"] = _worker_busy;
    out["capture_ms_last"] = static_cast<double>(_capture_us_last) / 1000.0;
    out["capture_ms_p95"] = static_cast<double>(capture_p95_us) / 1000.0;
    out["capture_ms_max"] = static_cast<double>(_capture_us_max) / 1000.0;
    out["backpressure_wait_count"] = _backpressure_wait_count;
    out["backpressure_wait_ms_total"] =
        static_cast<double>(_backpressure_wait_us) / 1000.0;
    out["worker_encode_ms_last"] = static_cast<double>(_encode_us_last) / 1000.0;
    out["worker_write_ms_last"] = static_cast<double>(_write_us_last) / 1000.0;
    out["max_rows"] = _config.max_rows;
    out["sampled_cell_count"] = static_cast<int64_t>(_source->sample_cells().size());
    out["cell_scope"] = _config.cell_indices.empty() ? "all" : "selected";
    out["selected_cell_index"] = _config.cell_indices.size() == 1
        ? _config.cell_indices.front() : -1;
    out["error_code"] = godot::String(_error_code.c_str());
    out["error_message"] = godot::String(_error_message.c_str());
    out["hit_limit"] = _error_code == "row_limit";
    out["first_unrecorded_epoch"] = _first_unrecorded_epoch;
    godot::PackedStringArray paths;
    for (int32_t dim = 0; dim < DIM_COUNT; ++dim)
        if (_config.enabled[dim]) paths.push_back(godot::String::utf8(_config.paths[dim].c_str()));
    out["paths"] = paths;
    return out;
}

} // namespace pk
