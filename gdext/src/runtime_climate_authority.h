#pragma once

#include "runtime_climate_kernel.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

struct RuntimeClimateVerticalReport {
    uint64_t work_units = 0;
    uint32_t changed_cells = 0;
    uint64_t state_hash = 0;
    // Canonical parity reduction of the same state. Unlike state_hash it
    // excludes worker-only bookkeeping, so it is the only value that may be
    // compared against a production reference hash.
    uint64_t parity_hash = 0;
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
    // 1 << RuntimeClimateStage。生产跑过哪些 stage / worker 跑过哪些 stage；差集就是
    // "生产算了、worker 没算"。stage_work 只说 worker 干了多少活，说不出生产那一侧的
    // 节拍，而 stage 9..13 的分叉恰恰要靠两侧对比才能归因。
    int32_t production_stage_mask = 0;
    int32_t worker_stage_mask = 0;
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
    // 没有 store 成员、但仍须回灌 MapData 的场。它们不在 payload 里，因为 payload
    // 就是 store 本身，而 store 的字段集同时决定 PKEC 存档格式 —— 为了一条不需要
    // 跨天自持的场去改存档格式并 bump schema 不值得。
    //
    // soil_moisture 是 distribute 的产物，ACTIVE 下主线程那份 distribute 被抑制，
    // 所以 worker 这份是它唯一的日频写者。空 vector = 这一天 distribute 没跑。
    std::vector<float> soil_moisture;
    // pass_a 的日照/热量输出。同样没有 store 成员，同样在 ACTIVE 下失去主线程写者
    // （生产 pass_a 整段被抑制门关掉），于是 MapData 里这几条停在世界生成时的值。
    //
    // 它们不影响 worker 内部的模拟正确性 —— round 内部 pass_a→pass_b 的接力走的是
    // out 缓冲，不经 MapData（runtime_climate_passes.cpp:2844）。坏的是外部读者：
    // 渲染、tile 录制、UI 面板读的都是 MapData，看到的是一张永远停在春分的日照图。
    // 实测 insolation_dev 上界恒 0.134 而主线程那侧 0.302 且逐日推进。
    std::vector<float> insolation_now;
    std::vector<float> insolation_dev;
    std::vector<float> day_length;
    std::vector<float> heat_input;
    std::vector<float> temp_season_offset;
};

// Worker -> main-thread handoff for ACTIVE Climate write-back.
//
// Same three-slot protocol as RuntimeSnapshotRing, with a Climate store as the
// payload instead of a RuntimeCommit. It is a separate ring rather than a new
// field on that one because the visual ring is published on a throttle and may
// legitimately drop frames: dropping a visual patch loses a repaint, dropping
// an authoritative day loses the day itself. This one is only written at a
// committed day boundary, so it never drops while a reader keeps up.
//
// Neither side ever blocks. The worker skips publishing when all non-reading
// slots are busy (counted, not silently swallowed) and the main thread simply
// finds nothing new.
class RuntimeClimateWritebackRing {
public:
    RuntimeClimateWritebackRing();

    // Worker-only.
    bool try_begin_write(uint32_t &index);
    RuntimeClimateSnapshot &write_buffer(uint32_t index) { return _buffers[index]; }
    void publish(uint32_t index);

    // Main-thread-only, non-blocking. The newest READY slot past
    // `after_generation` wins; older ones are left to be recycled.
    bool try_acquire_latest(uint64_t after_generation, uint32_t &index);
    const RuntimeClimateSnapshot &read_buffer(uint32_t index) const {
        return _buffers[index];
    }
    void release(uint32_t index);

    void reset();
    uint64_t publish_drop_count() const {
        return _publish_drop_count.load(std::memory_order_relaxed);
    }
    static bool self_test(std::string &error);

private:
    enum BufferState : uint8_t { FREE = 0, WRITING = 1, READY = 2, READING = 3 };
    static constexpr size_t SLOT_COUNT = 3;

    std::array<RuntimeClimateSnapshot, SLOT_COUNT> _buffers{};
    std::array<std::atomic<uint8_t>, SLOT_COUNT> _states{};
    std::atomic<uint64_t> _published_generation{0};
    std::atomic<uint64_t> _publish_drop_count{0};
};

class RuntimeClimateAuthority {
public:
    void reset(uint32_t cell_count);
    bool plan_day(int64_t day, const RuntimeEnvironmentSnapshot &environment,
                  RuntimeClimateVerticalReport &report);
    bool commit_day(int64_t day, RuntimeClimateVerticalReport &report);
    // Commits the planned day and then overwrites the comparable fields with
    // the production reference for that day.
    //
    // This is a measurement mode, never an authority path. Without it a single
    // divergent day leaves the worker unable to advance, because the same day
    // is retried forever against an ever-newer trace front: exactly one day
    // could ever be measured. Adopting the reference turns each day into an
    // independent one-step comparison, which is what a per-stage divergence
    // matrix needs. The worker's own bookkeeping is left untouched.
    bool commit_day_forced(int64_t day, const RuntimeClimateStore &reference,
                           RuntimeClimateVerticalReport &report);
    // Takes the production reference for `day` as the worker's starting state,
    // without planning that day.
    //
    // A worker joins a world that has already been generated: its store is all
    // zeros while the very first reference it sees carries the whole generation
    // pass. Comparing that day measures nothing but the missing history, and it
    // would mark every field divergent. This adopts the reference once instead,
    // so the first *measured* day starts from the same baseline production did.
    bool adopt_reference_baseline(int64_t day,
                                 const RuntimeClimateStore &reference,
                                 const RuntimeEnvironmentSnapshot &environment,
                                 RuntimeClimateVerticalReport &report);
    // Drop a pending next-lane after a preflight/parity rejection without
    // mutating the last committed store. The same logical day can then be
    // retried from a clean base state.
    void discard_plan();

    const RuntimeClimateStore &store() const { return _store; }
    // The next-lane state produced by plan_day. Meaningful only between
    // plan_day and the following commit_day/discard_plan, which is exactly the
    // window in which a parity comparison happens.
    const RuntimeClimateStore &planned_store() const { return _next; }
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
        result.soil_moisture = _kernel.distribute_soil_moisture();
        const auto &ro = _kernel.round_output();
        result.insolation_now = ro.insolation_now;
        result.insolation_dev = ro.insolation_dev;
        result.day_length = ro.day_length;
        result.heat_input = ro.heat_input;
        result.temp_season_offset = ro.temp_season_offset;
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
