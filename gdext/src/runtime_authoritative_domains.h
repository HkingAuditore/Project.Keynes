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
    std::vector<uint8_t> weather_transition;
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
    float climate_anomaly = 0.0f;
    float annual_temperature_drift = 0.0f;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
    uint64_t annual_rng_state = 0x243f6a8885a308d3ull;
    uint32_t history_cursor = 0;
    std::vector<float> temperature_history;

    void reset(uint32_t cells);
    bool validate(std::string &error) const;
    uint64_t state_hash() const;
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
