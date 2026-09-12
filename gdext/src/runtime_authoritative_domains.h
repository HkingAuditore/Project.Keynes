#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

// Pure worker-side records for the real domain migration.  These types are
// intentionally independent from the legacy Godot-facing runtime classes.
// Catalogs are compiled into numeric IDs before a host is started; stores
// below own only mutable state and fixed-capacity transient lanes.
struct RuntimeDomainExecutionReport {
    RuntimeDomainHeader header{};
    double plan_ms = 0.0;
    double replay_ms = 0.0;
    double ack_ms = 0.0;
    uint32_t rejected_count = 0;
};

// Common immutable day barrier envelope used by every domain adapter. The
// concrete stores remain private to the worker; only this report crosses the
// domain orchestration boundary.
struct RuntimeDomainDayResult {
    RuntimeDomainHeader header{};
    uint8_t planned = 0;
    uint8_t committed = 0;
    uint8_t ack_barrier_complete = 0;
    char error[64]{};
};

struct RuntimeClimateStore {
    uint32_t cell_count = 0;
    uint64_t generation = 0;
    uint64_t climate_generation = 0;
    int64_t committed_day = -1;
    std::vector<float> temperature;
    std::vector<float> temperature_30d_ema;
    std::vector<float> temperature_365d_ema;
    std::vector<float> temperature_baseline;
    std::vector<float> thermal_energy;
    std::vector<float> moisture;
    std::vector<float> plant_available_water;
    std::vector<float> water_balance_30d;
    std::vector<float> weather_precipitation;
    std::vector<float> weather_intensity;
    std::vector<float> vapor;
    std::vector<float> cloud_water;
    std::vector<float> cloud_cover;
    std::vector<float> convergence;
    std::vector<float> instability;
    std::vector<uint8_t> weather_type;
    // 过渡动画的三条 lane，与生产的 cell_weather_prev_type /
    // cell_weather_target_type / cell_weather_transition_alpha 一一对应。
    //
    // 之前这里只有一个 uint8 weather_transition，语义是"今天的类型变了没有"，与
    // 生产的三条 slot 不是同一个量，于是它在 parity 表里只能挂 TYPE_MISMATCH、
    // 永久排除在对拍之外。ACTIVE 下这三条要靠 writeback 回灌 MapData，缺一条
    // 天气过渡动画就会卡住，所以按真实形状展开。
    std::vector<uint8_t> weather_prev_type;
    std::vector<uint8_t> weather_target_type;
    std::vector<float> weather_transition_alpha;
    std::vector<float> snow_cover;
    std::vector<float> snowpack;
    std::vector<float> sea_ice;
    std::vector<float> runoff;
    std::vector<float> groundwater;
    std::vector<float> river_storage;
    std::vector<float> river_discharge;
    std::vector<float> riparian_moisture;
    std::vector<float> vegetation_vitality;
    std::vector<float> vegetation_growth_pressure;
    std::vector<float> vegetation_heat_stress;
    std::vector<float> vegetation_drought_stress;
    std::vector<float> vegetation_cold_stress;
    std::vector<int32_t> vegetation_growth_streak;
    std::vector<int32_t> vegetation_drought_streak;
    std::vector<uint8_t> vegetation_succession_candidate;
    // B8-2：worker 自持的 synoptic ψ / ψ_prev。CLM2 ABI 4 起持久化；ABI 3 的旧档
    // 读进来时这两条保持全零，由第一天的生产 capture 重新播种（见
    // RuntimeClimateAuthority::restore 的版本分支）。
    std::vector<float> synoptic_psi;
    std::vector<float> synoptic_psi_prev;
    // B8-P1：worker 自持的植被演替状态（CLM2 ABI 5 起持久化）。生产侧演替后处理会
    // 写 vegetation / base_vegetation 并把 vitality 拉向目标值；ACTIVE 下那条主线程
    // 写入被抑制，这两条 lane 就是 worker 的唯一副本。
    std::vector<uint8_t> vegetation;
    std::vector<uint8_t> base_vegetation;
    // CLM2 ABI 8：worker 自持的 terrain / cover u8 lane。ACTIVE 下主线程海冰翻转与
    // weather distribute 对这两条的写入被抑制，必须由 worker 推进并 writeback。
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> cover;
    // B8-2：worker 自持的 tropical cyclone 状态（可变长条目表），以不透明 blob 形式
    // 随 CLM2 ABI 6 持久化。语义由 runtime_climate_passes.h 的
    // cyclone_state_encode/decode 拥有，store 只负责搬运字节。
    std::vector<uint8_t> cyclone_state;
    // CLM2 ABI 7 的提交态物理胶囊；空表示旧档/新图，下一次计划明确冷播种。
    // 不加入旧 RuntimeClimatePodSnapshot / PDP3/PDP4，也不改变 PKEC 的独立格式。
    static constexpr size_t MAX_PHYSICS_STATE_BYTES = 64u * 1024u * 1024u;
    std::vector<uint8_t> physics_state;
    float climate_anomaly = 0.0f;
    float annual_temperature_drift = 0.0f;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
    uint64_t annual_rng_state = 0x243f6a8885a308d3ull;
    uint32_t history_cursor = 0;
    std::vector<float> temperature_history;

    void reset(uint32_t cells);
    // Lane 形状 / 长度契约（无逐元素扫描）。commit 热路径用这个，避免把
    // finite + physics decode 再付一遍；完整 validate 留给 save/restore/seed。
    bool validate_shape(std::string &error) const;
    bool validate(std::string &error) const;
    // Covers every field including worker-only bookkeeping. Use for save,
    // restore and snapshot integrity. ABI 8+ includes terrain/cover.
    uint64_t state_hash() const;
    // 冻结 ABI 7 的哈希算法：abi6 + physics_state，不含 terrain/cover。
    uint64_t state_hash_abi7() const;
    // 冻结 ABI 6 的哈希算法，仅供 CLM2 旧档完整性校验；不包含 physics_state。
    uint64_t state_hash_abi6() const;
    // Covers only the fields that also exist on the production side, so the
    // two paths are actually comparable. Defined in runtime_climate_parity.cpp
    // alongside the canonical field table. Use for parity comparison.
    uint64_t parity_hash() const;
};

struct RuntimeCountryStore {
    uint32_t cell_count = 0;
    uint32_t country_count = 0;
    uint64_t generation = 0;
    int64_t committed_day = -1;
    std::vector<uint8_t> active;
    std::vector<uint32_t> entity_generation;
    std::vector<int64_t> treasury;
    std::vector<int32_t> cell_country_slot;
    std::vector<int32_t> territory_offsets;
    std::vector<int32_t> territory_cells;
    std::vector<uint64_t> technologies;
    std::vector<uint64_t> discovered;
    std::vector<uint64_t> pending_technologies;
    std::vector<int32_t> research_queue;
    std::vector<uint8_t> research_queue_lengths;
    std::array<int32_t, 4> default_research_weights{{2500, 2500, 2500, 2500}};
    std::vector<int32_t> research_active_slots;
    uint64_t state_generation = 0;
    uint64_t territory_generation = 0;
    uint64_t visual_generation = 0;
    uint64_t research_generation = 0;

    void reset(uint32_t cells, uint32_t countries);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

struct RuntimeModifierEntry {
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    uint32_t definition_id = 0;
    int32_t stacks = 0;
    int64_t value_q16 = 0;
    int64_t expiry_day = -1;
    uint64_t source_handle = 0;
    uint64_t creation_sequence = 0;
};

struct RuntimeModifierStore {
    uint64_t generation = 0;
    uint64_t bucket_revision = 0;
    int64_t committed_day = -1;
    std::vector<RuntimeModifierEntry> entries;
    std::vector<uint32_t> expiry_heap;

    void reset(size_t capacity);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

struct RuntimeEffectInstance {
    uint64_t instance_id = 0;
    uint32_t generation = 1;
    uint32_t definition_id = 0;
    uint64_t source_handle = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t next_due_day = -1;
    int64_t expiry_day = -1;
    uint64_t fire_sequence = 0;
    uint32_t required_ack_mask = 0;
    uint32_t received_ack_mask = 0;
    uint64_t idempotency_key = 0;
    uint8_t active = 1;
    uint8_t retry_count = 0;
};

struct RuntimeEffectStore {
    uint64_t generation = 0;
    uint64_t next_instance_id = 1;
    int64_t committed_day = -1;
    std::vector<RuntimeEffectInstance> instances;

    void reset(size_t capacity);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

struct RuntimeIdeologyCountry {
    uint64_t country_handle = 0;
    int64_t points_q16 = 0;
    int32_t dominant_id = -1;
    int32_t pending_transition = -1;
    uint32_t revision = 0;
    uint64_t offer_generation = 0;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
};

struct RuntimeIdeologyStore {
    uint64_t generation = 0;
    int64_t committed_day = -1;
    std::vector<RuntimeIdeologyCountry> countries;

    void reset(size_t capacity);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

struct RuntimeTriggerState {
    uint32_t definition_id = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t accumulator = 0;
    int64_t window_start_day = 0;
    int64_t consecutive_days = 0;
    int64_t cooldown_until = -1;
    uint64_t last_event_id = 0;
    uint64_t fire_sequence = 0;
    uint8_t completed = 0;
};

struct RuntimeTriggerStore {
    uint64_t generation = 0;
    int64_t committed_day = -1;
    std::vector<RuntimeTriggerState> states;
    std::vector<uint64_t> distinct_keys;

    void reset(size_t state_capacity, size_t distinct_capacity);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

struct RuntimeEconomyStore {
    uint32_t cell_count = 0;
    uint64_t generation = 0;
    int64_t committed_day = -1;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
    uint64_t ledger_failures = 0;
    std::vector<int64_t> population;
    std::vector<int64_t> treasury;
    std::vector<int64_t> inventory;
    std::vector<int64_t> production;
    std::vector<int64_t> household_demand;
    std::vector<int64_t> construction;
    std::vector<int64_t> price_q16;

    void reset(uint32_t cells);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

struct RuntimeEventRecord {
    uint64_t source_id = 0;
    uint64_t event_id = 0;
    int64_t day = 0;
    uint32_t type = 0;
    uint64_t entity_handle = 0;
    uint64_t group_handle = 0;
    int64_t value = 0;
    std::array<int64_t, 4> payload{};
    uint8_t gameplay = 1;
    uint8_t visual = 0;
    uint8_t debug = 0;
    uint8_t committed = 0;
};

struct RuntimeEventsStore {
    uint64_t generation = 0;
    uint64_t next_event_id = 1;
    int64_t committed_day = -1;
    std::vector<RuntimeEventRecord> journal;

    void reset(size_t capacity);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
};

// Owns all real domain stores in one worker-only aggregate.  The aggregate is
// intentionally not exposed through GDExtension; snapshots and save sections
// are copied out at explicit barriers only.
class RuntimeAuthoritativeDomainStores {
public:
    static bool self_test(std::string &error);
    void reset(uint32_t cell_count, uint32_t country_count,
               uint32_t technology_words = 1);
    bool validate_all(std::string &error) const;
    uint64_t state_hash() const;
    RuntimeDomainDayResult validate_day_barrier(RuntimeDomainId domain,
                                                int64_t day,
                                                uint64_t input_generation) const;
    // Reports the exact preflight status of a stage without claiming that a
    // gameplay domain is authoritative.  Until a domain has its complete
    // plan/replay/ACK implementation this returns an explicit pending
    // blocker instead of silently treating the container as committed.
    RuntimeDomainReport stage_preflight(RuntimeDomainId domain,
                                        const RuntimeDayContext &context,
                                        const RuntimeEnvironmentSnapshot *environment) const;
    uint32_t completed_mask() const { return _completed_mask; }
    void set_completed(RuntimeDomainId domain, bool completed);

    RuntimeClimateStore climate;
    RuntimeCountryStore country;
    RuntimeModifierStore modifier;
    RuntimeEffectStore effect;
    RuntimeIdeologyStore ideology;
    RuntimeTriggerStore trigger;
    RuntimeEconomyStore economy;
    RuntimeEventsStore events;

private:
    uint64_t generation_for_domain(RuntimeDomainId domain) const;
    uint32_t _completed_mask = runtime_domain_mask(RuntimeDomainId::COMMIT);
};

} // namespace pk
