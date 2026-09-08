#pragma once

#include "runtime_climate_kernel.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>

namespace pk {

enum class RuntimeClimateTraceState : uint8_t {
    CAPTURED = 0,
    REFERENCE_READY = 1,
    CONSUMABLE = 2,
    CONSUMED = 3,
};

// Immutable data returned to the worker after a successful pop. The ring's
// internal state is atomic; this value intentionally remains a cheap POD-like
// view for existing host code and parity diagnostics.
struct RuntimeClimateReferenceFrame {
    std::shared_ptr<const RuntimeEnvironmentSnapshot> environment;
    // Full production state for this day, when the caller supplied one. A hash
    // alone can only answer "do they differ"; locating *which* field and cell
    // first diverges requires the reference values themselves. Optional
    // because carrying it costs roughly cell_count * 30 * 4 bytes per day, so
    // only diagnostic runs pay for it.
    std::shared_ptr<const RuntimeClimateStore> reference_store;
    uint64_t input_hash = 0;
    uint64_t reference_state_hash = 0;
    uint64_t catalog_hash = 0;
    uint64_t trace_hash = 0;
    RuntimeClimateTraceState state = RuntimeClimateTraceState::CAPTURED;
};

// 生产在一个仿真日里到底跑了哪些 Climate 段、每段用的什么输入。
//
// capture 发生在 tick 开头（round 之前），所以这些事实只有到 reference publish 时才
// 知道，由 mark_reference_ready 回填进 environment 的克隆。
//
// 为什么是一个结构而不是继续加位置参数：stage 8..13 每段都要带自己的 knobs + 输入，
// 排到第十几个实参之后调用点已经看不出哪个对应哪段，漏传一个就静默变成"生产没跑"。
struct RuntimeClimateReferencePublish {
    // 生产这一天的完整状态。只有哈希只能回答"是否不同"，定位到首个分叉字段/格子需要
    // 参考值本身。可选：一天约 cell_count * 30 * 4 字节，只有诊断跑才付这个代价。
    std::shared_ptr<const RuntimeClimateStore> reference_store;
    // ── climate round（stage 0..7 + finalizer）────────────────────────
    std::shared_ptr<const pk_async_climate::ClimateInputBuf> round_input;
    bool round_ran = false;
    const pk_async_climate::ClimateRoundScalars *round_scalars = nullptr;
    int round_scalar_mask = 0;
    // ── stage 1 PASS_B 的非 slot 输入（海冰浓度）──────────────────────
    std::shared_ptr<const pk_async_climate::ClimatePassBInput> pass_b;
    std::shared_ptr<const pk_async_climate::SeaIceInput>       sea_ice;
    std::shared_ptr<const pk_async_climate::WindSurfaceInput>  wind_surface;
    std::shared_ptr<const pk_async_climate::OceanWaterInput>   ocean_water;
    // ── stage 4 WIND_AIR 的两条非 slot 输入（baseline / 轨迹表）───────────
    std::shared_ptr<const pk_async_climate::WindAirInput> wind_air;
    // ── stage 8 ALBEDO（stage_b 段，自己的 stride）────────────────────
    pk_async_climate::ClimateAlbedoKnobs albedo;
    // ── stage 9 VEGETATION_DYNAMICS（stage_b 段，自己的 stride）───────
    std::shared_ptr<const pk_async_climate::VegetationDynamicsInput> vegetation;
    // ── stage 10 CLIMATE_FEEDBACK（stage_b 段，自己的 stride）─────────
    std::shared_ptr<const pk_async_climate::ClimateFeedbackInput> feedback;
    // ── stage 11 WEATHER（weather bucket 自己的 cadence）─────────
    std::shared_ptr<const pk_async_climate::WeatherFieldInput> weather;
    // ── stage 12 RUNTIME_HYDROLOGY（runtime_hydrology_stride）─────────
    std::shared_ptr<const pk_async_climate::HydrologyInput> hydrology;
    // ── weather distribute（stage 11 后段，跟 weather bucket 同节拍）─────
    std::shared_ptr<const pk_async_climate::WeatherDistributeInput> weather_distribute;
    // 生产这一天跑过哪些 stage（1 << RuntimeClimateStage）。它与上面各段的输入记录
    // 是两件事：输入记录只有已经提取成共享内核的 stage 才有，而这个掩码对尚未提取的
    // stage 也照实置位 —— 于是"worker 缺实现"和"生产这天本来也没跑"能分开。
    int production_stage_mask = 0;
    // 季末一次的反馈消费（map_generator.gd::_consume_feedback_buffers）。它是纯
    // GDScript pass，不经过任何 record_production_* 路径，所以在 stage mask 里完全
    // 隐身。soil_moisture 与 base_moisture 的衰减会随每日输入记录自动传过来，但
    // vegetation_growth_pressure 是 worker 自己持久化的 store 成员 —— 少了这一步，
    // worker 的 growth_pressure 在季末停在生产的两倍，再经 plant_available_water 的
    // 水支出（paw + inflow - growth_pressure * 0.015）和 water_balance_30d 扩散成
    // moisture / PAW / runoff / groundwater / river_* 一整组分叉。
    bool  seasonal_feedback_ran = false;
    float seasonal_feedback_decay = 1.0f;
    // 季末地理级重算跑了没。season refresh 的 stage 0/1 直接重设 moisture（从
    // base_moisture + 季节 pattern + rain shadow 重算），worker 复刻不了——那条
    // 路径要 WorldData / 风带 / 地形重判定，全在主线程。worker 只能在这一天采纳
    // 生产值作为当天 round 的起点。
    bool  season_refresh_ran = false;
};

enum class RuntimeClimateTracePopResult : uint8_t {
    EMPTY = 0,
    REFERENCE_PENDING = 1,
    FUTURE_FRAME = 2,
    CONSUMED = 3,
};

// Single-producer (main thread), single-consumer (simulation worker) bounded
// trace. A captured frame remains in the ring until the synchronous reference
// has supplied a matching hash and explicitly released it for consumption.
// No worker path reads the latest live environment as a fallback.
class RuntimeClimateTrace {
public:
    static constexpr uint32_t CAPACITY = 2048u;

    bool push(const RuntimeEnvironmentSnapshot &snapshot) {
        const uint64_t write = _write.load(std::memory_order_relaxed);
        const uint64_t read = _read.load(std::memory_order_acquire);
        if (write - read >= CAPACITY) {
            _capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        Slot &slot = _slots[write % CAPACITY];
        // A slot is reused only after _read has advanced. Consequently the
        // producer owns this shared_ptr assignment exclusively.
        slot.frame = std::make_shared<TraceFrame>();
        slot.frame->environment =
            std::make_shared<const RuntimeEnvironmentSnapshot>(snapshot);
        slot.frame->input_hash = RuntimeClimateKernel::input_hash(snapshot);
        slot.frame->reference_state_hash = 0;
        slot.frame->catalog_hash = snapshot.climate_catalog_hash;
        // The trace identity must cover every captured lane, not just the
        // day/topology tuple. Reusing the canonical input hash makes a
        // malformed or partially-copied frame visible to the parity report
        // without storing a second dynamic payload in the ring.
        slot.frame->trace_hash = RuntimeClimateKernel::input_hash(snapshot);
        slot.frame->state.store(RuntimeClimateTraceState::CAPTURED,
                                std::memory_order_relaxed);
        slot.day.store(snapshot.day, std::memory_order_relaxed);
        slot.generation.store(snapshot.generation, std::memory_order_relaxed);
        _write.store(write + 1u, std::memory_order_release);
        return true;
    }

    // production_round_input / round_ran 描述"这一天生产到底跑了什么"。它们只有在
    // reference publish 时才知道（capture 发生在 tick 开头、round 之前），所以在这里
    // 回填而不是在 push 时。回填方式是克隆 environment：帧此刻还是 CAPTURED，只有
    // 生产者持有它，下面那次 release CAS 会把克隆一并发布给 worker。
    bool mark_reference_ready(
            int64_t day, uint64_t input_hash, uint64_t reference_state_hash,
            std::string &error,
            RuntimeClimateReferencePublish publish = {}) {
        error.clear();
        if (reference_state_hash == 0) {
            error = "climate_trace_reference_hash_invalid";
            _reference_rejected.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            Slot &slot = _slots[cursor % CAPACITY];
            auto frame = slot.frame;
            if (!frame || !frame->environment ||
                frame->environment->day != day) continue;
            if (frame->input_hash != input_hash) {
                error = "climate_trace_input_hash_mismatch";
                _reference_rejected.fetch_add(1, std::memory_order_relaxed);
                return false;
            }
            const RuntimeClimateTraceState observed =
                frame->state.load(std::memory_order_acquire);
            if (observed != RuntimeClimateTraceState::CAPTURED) {
                error = observed == RuntimeClimateTraceState::REFERENCE_READY
                    ? "climate_trace_reference_already_recorded"
                    : "climate_trace_reference_not_captured";
                _reference_rejected.fetch_add(1, std::memory_order_relaxed);
                return false;
            }
            // Publish the reference bytes before opening REFERENCE_READY. A
            // concurrent consumer can therefore never observe CONSUMABLE with
            // an unwritten reference hash. The state pointer is published in
            // the same window and is released by the same CAS below.
            {
                auto clone = std::make_shared<RuntimeEnvironmentSnapshot>(
                    *frame->environment);
                clone->climate_round_ran = publish.round_ran;
                // 两份缓冲分层：capture 那份提供全 9 pass 的 lane，生产那份覆盖
                // pass_a 的权威输入。只取其一都会分叉，理由见
                // pk_async_climate::overlay_production_pass_a 的注释。
                const bool lane_diag =
                    pk_async_climate::round_input_lane_diag_enabled();
                pk_async_climate::ClimateInputBuf lane_diag_before;
                if (lane_diag) lane_diag_before = clone->climate_round_input;
                if (publish.round_ran && publish.round_input != nullptr) {
                    if (clone->climate_round_input.n_cells ==
                            static_cast<int>(clone->cell_count)) {
                        pk_async_climate::overlay_production_pass_a(
                            clone->climate_round_input, *publish.round_input);
                    } else {
                        clone->climate_round_input = *publish.round_input;
                    }
                }
                // pass_b→sea_ice 的标量：capture 侧在 native_daily 路径下拿不到
                // （ClimateDailySystem 未注册），只能靠生产各 pass 自己记录的那一份。
                if (publish.round_ran && publish.round_scalars != nullptr) {
                    pk_async_climate::overlay_production_round_scalars(
                        clone->climate_round_input, *publish.round_scalars,
                        publish.round_scalar_mask);
                }
                if (publish.round_ran && publish.pass_b != nullptr) {
                    pk_async_climate::overlay_production_pass_b(
                        clone->climate_round_input, *publish.pass_b);
                }
                // sea_ice 的温度 lane 同理：生产传的是 cell.temperature，capture 侧
                // 只能看到 SoA cell_temp。
                if (publish.round_ran && publish.sea_ice != nullptr) {
                    pk_async_climate::overlay_production_sea_ice(
                        clone->climate_round_input, *publish.sea_ice);
                }
                // oanom 的权威在生产的分片 ocean stage 手里，不在 worker。
                if (publish.round_ran && publish.wind_surface != nullptr) {
                    pk_async_climate::overlay_production_wind_surface(
                        clone->climate_round_input, *publish.wind_surface);
                }
                if (publish.round_ran && publish.ocean_water != nullptr) {
                    pk_async_climate::overlay_production_ocean_water(
                        clone->climate_round_input, *publish.ocean_water);
                }
                // wind_air 的 baseline 与轨迹表同理：两者都不是 slot，capture 侧
                // 拿不到，只能用生产跑 wind_air 时记下的那一份。
                if (publish.round_ran && publish.wind_air != nullptr) {
                    pk_async_climate::overlay_production_wind_air(
                        clone->climate_round_input, *publish.wind_air);
                }
                if (lane_diag && publish.round_ran) {
                    pk_async_climate::report_round_input_lane_delta(
                        lane_diag_before, clone->climate_round_input, day);
                }
                clone->climate_albedo = publish.albedo;
                clone->climate_vegetation = std::move(publish.vegetation);
                clone->climate_feedback = std::move(publish.feedback);
    clone->climate_weather = std::move(publish.weather);
    clone->climate_hydrology = std::move(publish.hydrology);
    clone->climate_weather_distribute = std::move(publish.weather_distribute);
                clone->climate_production_stage_mask = publish.production_stage_mask;
        clone->climate_seasonal_feedback_ran = publish.seasonal_feedback_ran;
        clone->climate_seasonal_feedback_decay = publish.seasonal_feedback_decay;
        clone->climate_season_refresh_ran = publish.season_refresh_ran;
                frame->environment = std::move(clone);
            }
            frame->reference_store = std::move(publish.reference_store);
            frame->reference_state_hash.store(reference_state_hash,
                                               std::memory_order_relaxed);
            RuntimeClimateTraceState expected = RuntimeClimateTraceState::CAPTURED;
            if (!frame->state.compare_exchange_strong(
                    expected, RuntimeClimateTraceState::REFERENCE_READY,
                    std::memory_order_acq_rel, std::memory_order_acquire)) {
                error = expected == RuntimeClimateTraceState::REFERENCE_READY
                    ? "climate_trace_reference_already_recorded"
                    : "climate_trace_reference_not_captured";
                _reference_rejected.fetch_add(1, std::memory_order_relaxed);
                return false;
            }
            return true;
        }
        error = "climate_trace_reference_frame_missing";
        _reference_rejected.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    bool input_hash_for_day(int64_t day, uint64_t &out_hash) const {
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            const Slot &slot = _slots[cursor % CAPACITY];
            const auto frame = slot.frame;
            if (frame && frame->environment && frame->environment->day == day) {
                out_hash = frame->input_hash;
                return true;
            }
        }
        out_hash = 0;
        return false;
    }

    bool mark_consumable(int64_t day, std::string &error) {
        error.clear();
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            Slot &slot = _slots[cursor % CAPACITY];
            auto frame = slot.frame;
            if (!frame || !frame->environment ||
                frame->environment->day != day) continue;
            RuntimeClimateTraceState expected = RuntimeClimateTraceState::REFERENCE_READY;
            if (frame->state.compare_exchange_strong(
                    expected, RuntimeClimateTraceState::CONSUMABLE,
                    std::memory_order_acq_rel, std::memory_order_acquire)) {
                return true;
            }
            error = expected == RuntimeClimateTraceState::CAPTURED
                ? "climate_trace_reference_pending"
                : "climate_trace_reference_not_ready";
            _reference_rejected.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        error = "climate_trace_reference_frame_missing";
        _reference_rejected.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    RuntimeClimateTracePopResult pop_for_day(
            int64_t max_day, RuntimeClimateReferenceFrame &out) {
        out = RuntimeClimateReferenceFrame{};
        const uint64_t read = _read.load(std::memory_order_relaxed);
        const uint64_t write = _write.load(std::memory_order_acquire);
        if (read == write) return RuntimeClimateTracePopResult::EMPTY;
        Slot &slot = _slots[read % CAPACITY];
        auto frame = slot.frame;
        if (!frame || !frame->environment)
            return RuntimeClimateTracePopResult::EMPTY;
        if (frame->environment->day > max_day)
            return RuntimeClimateTracePopResult::FUTURE_FRAME;
        if (frame->state.load(std::memory_order_acquire) !=
            RuntimeClimateTraceState::CONSUMABLE) {
            _reference_pending.fetch_add(1, std::memory_order_relaxed);
            return RuntimeClimateTracePopResult::REFERENCE_PENDING;
        }
        out.environment = frame->environment;
        out.reference_store = frame->reference_store;
        out.input_hash = frame->input_hash;
        out.reference_state_hash = frame->reference_state_hash.load(
            std::memory_order_acquire);
        out.catalog_hash = frame->catalog_hash;
        out.trace_hash = frame->trace_hash;
        out.state = RuntimeClimateTraceState::CONSUMED;
        // Keep slot.frame until the producer reuses the slot after observing
        // _read. This avoids a concurrent shared_ptr reset race with the
        // main-thread reference marker.
        frame->state.store(RuntimeClimateTraceState::CONSUMED,
                           std::memory_order_release);
        _read.store(read + 1u, std::memory_order_release);
        return RuntimeClimateTracePopResult::CONSUMED;
    }

    bool pop_consumable(RuntimeClimateReferenceFrame &out) {
        return pop_for_day(std::numeric_limits<int64_t>::max(), out) ==
            RuntimeClimateTracePopResult::CONSUMED;
    }

    // Compatibility accessor used by existing diagnostics. It only returns a
    // reference-backed frame; there is intentionally no latest-input fallback.
    std::shared_ptr<const RuntimeEnvironmentSnapshot> pop() {
        RuntimeClimateReferenceFrame frame;
        return pop_consumable(frame) ? std::move(frame.environment) : nullptr;
    }

    uint32_t depth() const {
        const uint64_t write = _write.load(std::memory_order_acquire);
        const uint64_t read = _read.load(std::memory_order_acquire);
        return static_cast<uint32_t>(write >= read ? write - read : 0u);
    }
    bool front_day(int64_t &out_day) const {
        const uint64_t read = _read.load(std::memory_order_acquire);
        const uint64_t write = _write.load(std::memory_order_acquire);
        if (read == write) return false;
        const auto frame = _slots[read % CAPACITY].frame;
        if (!frame || !frame->environment) return false;
        out_day = frame->environment->day;
        return true;
    }

    uint32_t state_count(RuntimeClimateTraceState state) const {
        const uint64_t write = _write.load(std::memory_order_acquire);
        const uint64_t read = _read.load(std::memory_order_acquire);
        uint32_t count = 0;
        for (uint64_t cursor = read; cursor < write; ++cursor) {
            const auto frame = _slots[cursor % CAPACITY].frame;
            if (frame != nullptr &&
                frame->state.load(std::memory_order_acquire) == state) {
                ++count;
            }
        }
        return count;
    }

    uint32_t captured_depth() const {
        return state_count(RuntimeClimateTraceState::CAPTURED);
    }
    uint32_t reference_ready_depth() const {
        return state_count(RuntimeClimateTraceState::REFERENCE_READY);
    }
    uint32_t consumable_depth() const {
        return state_count(RuntimeClimateTraceState::CONSUMABLE);
    }
    uint32_t reference_pending_depth() const {
        return captured_depth() + reference_ready_depth();
    }
    uint64_t capacity_exceeded() const {
        return _capacity_exceeded.load(std::memory_order_acquire);
    }
    uint64_t reference_rejected() const {
        return _reference_rejected.load(std::memory_order_acquire);
    }
    uint64_t reference_pending() const {
        return _reference_pending.load(std::memory_order_acquire);
    }

    void reset() {
        // Called only before a worker starts or after it has stopped. Do not
        // reset a slot concurrently with pop_for_day/mark_reference_ready.
        for (auto &slot : _slots) {
            slot.frame.reset();
            slot.day.store(-1, std::memory_order_relaxed);
            slot.generation.store(0, std::memory_order_relaxed);
        }
        _read.store(0, std::memory_order_release);
        _write.store(0, std::memory_order_release);
        _capacity_exceeded.store(0, std::memory_order_release);
        _reference_rejected.store(0, std::memory_order_release);
        _reference_pending.store(0, std::memory_order_release);
    }

    static bool self_test(std::string &error) {
        RuntimeClimateTrace trace;
        RuntimeEnvironmentSnapshot frame;
        frame.generation = 1;
        frame.day = 0;
        frame.cell_count = 1;
        frame.climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
        frame.cell_temp = {1.0f};
        if (!trace.push(frame)) {
            error = "climate_trace_initial_push_failed";
            return false;
        }
        const uint64_t input_hash = RuntimeClimateKernel::input_hash(frame);
        if (trace.mark_consumable(0, error) ||
            error != "climate_trace_reference_pending") {
            error = "climate_trace_capture_barrier_invalid";
            return false;
        }
        if (!trace.mark_reference_ready(0, input_hash, 77, error) ||
            !trace.mark_consumable(0, error)) {
            error = "climate_trace_reference_transition_invalid";
            return false;
        }
        RuntimeClimateReferenceFrame consumed;
        if (!trace.pop_consumable(consumed) || !consumed.environment ||
            consumed.reference_state_hash != 77 || trace.depth() != 0) {
            error = "climate_trace_reference_state_invalid";
            return false;
        }

        RuntimeClimateTrace bounded;
        for (uint32_t i = 0; i < CAPACITY; ++i) {
            frame.day = static_cast<int64_t>(i + 1u);
            frame.generation = i + 2u;
            if (!bounded.push(frame)) {
                error = "climate_trace_capacity_order_invalid";
                return false;
            }
        }
        frame.day = CAPACITY + 1u;
        if (bounded.push(frame) || bounded.capacity_exceeded() != 1u) {
            error = "climate_trace_capacity_not_rejected";
            return false;
        }
        error.clear();
        return true;
    }

private:
    struct TraceFrame {
        std::shared_ptr<const RuntimeEnvironmentSnapshot> environment;
        // Written by the producer inside mark_reference_ready, before the CAS
        // that opens REFERENCE_READY, and read only after a consumer has
        // observed CONSUMABLE.
        std::shared_ptr<const RuntimeClimateStore> reference_store;
        uint64_t input_hash = 0;
        std::atomic<uint64_t> reference_state_hash{0};
        uint64_t catalog_hash = 0;
        uint64_t trace_hash = 0;
        std::atomic<RuntimeClimateTraceState> state{
            RuntimeClimateTraceState::CAPTURED};
    };

    struct Slot {
        std::shared_ptr<TraceFrame> frame;
        std::atomic<int64_t> day{-1};
        std::atomic<uint64_t> generation{0};
    };

    std::array<Slot, CAPACITY> _slots{};
    std::atomic<uint64_t> _write{0};
    std::atomic<uint64_t> _read{0};
    std::atomic<uint64_t> _capacity_exceeded{0};
    std::atomic<uint64_t> _reference_rejected{0};
    std::atomic<uint64_t> _reference_pending{0};
};

} // namespace pk
