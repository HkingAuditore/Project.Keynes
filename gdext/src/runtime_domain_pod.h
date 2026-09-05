#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <type_traits>
#include <vector>

namespace pk {

struct RuntimeDomainPipelineReport {
    uint32_t completed_domain_mask = 0;
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint64_t state_hash = 0;
    uint32_t fallback_count = 0;
    std::array<RuntimeDomainReport, RUNTIME_DOMAIN_STAGE_COUNT> domains{};
};

// The following stores are the worker-owned mutable state for the domains.
// They are deliberately compact SoA-like vectors.  Main-thread catalogs are
// not retained here and can therefore be destroyed after bootstrap.
struct RuntimeModifierPodEntry {
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    uint32_t definition_id = 0;
    int32_t stacks = 0;
    int64_t expires_day = -1;
    int64_t value_q16 = 0;
};

struct RuntimeModifierPodState {
    std::vector<RuntimeModifierPodEntry> entries;
    uint64_t generation = 0;
    uint64_t revision = 0;
};

struct RuntimeEffectPodInstance {
    uint64_t instance_id = 0;
    uint32_t generation = 1;
    uint16_t target_domain = 0;
    uint16_t opcode = 0;
    uint64_t target_handle = 0;
    int64_t next_due_day = -1;
    uint32_t required_ack_mask = 0;
    uint32_t received_ack_mask = 0;
    uint64_t fire_sequence = 0;
    uint8_t active = 1;
};

struct RuntimeEffectPodState {
    std::vector<RuntimeEffectPodInstance> instances;
    uint64_t next_instance_id = 1;
    uint64_t generation = 0;
};

struct RuntimeIdeologyPodCountry {
    uint64_t country_handle = 0;
    int64_t points = 0;
    int32_t dominant_id = -1;
    int32_t pending_transition = -1;
    uint32_t revision = 0;
};

struct RuntimeIdeologyPodState {
    std::vector<RuntimeIdeologyPodCountry> countries;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
    uint64_t generation = 0;
};

struct RuntimeTriggerPodState {
    std::vector<int64_t> accumulators;
    std::vector<int64_t> cooldown_until;
    std::vector<uint64_t> fire_sequences;
    uint64_t generation = 0;
};

struct RuntimeClimatePodState {
    std::vector<float> temperature;
    std::vector<float> moisture;
    std::vector<float> snow_cover;
    std::vector<float> temperature_ema;
    // These fields are kept in the worker-owned state even while the legacy
    // weather front/atlas objects remain on the main thread.  They make the
    // Climate boundary explicit and give SHADOW parity a stable payload to
    // compare before the full weather solver is moved behind the host.
    std::vector<float> water_balance;
    std::vector<float> weather_precip;
    std::vector<float> weather_intensity;
    std::vector<float> vegetation_vitality;
    double anomaly = 0.0;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
    uint64_t generation = 0;
};

struct RuntimeClimatePodSnapshot {
    uint64_t generation = 0;
    uint64_t rng_state = 0x9e3779b97f4a7c15ull;
    double anomaly = 0.0;
    std::vector<float> temperature;
    std::vector<float> moisture;
    std::vector<float> snow_cover;
    std::vector<float> temperature_ema;
    std::vector<float> water_balance;
    std::vector<float> weather_precip;
    std::vector<float> weather_intensity;
    std::vector<float> vegetation_vitality;
};

struct RuntimeEconomyPodState {
    std::vector<int64_t> population;
    std::vector<int64_t> treasury;
    std::vector<int64_t> inventory;
    uint64_t generation = 0;
    uint64_t ledger_failures = 0;
};

struct RuntimeEventPodEntry {
    int64_t day = 0;
    uint64_t event_id = 0;
    uint16_t type = 0;
    uint16_t flags = 0;
    uint64_t source_handle = 0;
    int64_t value = 0;
};

static_assert(std::is_trivially_copyable_v<RuntimeDomainAck>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainIntent>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainTiming>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainReport>);
static_assert(std::is_trivially_copyable_v<RuntimeEventPodEntry>);

struct RuntimeEventsPodState {
    std::vector<RuntimeEventPodEntry> journal;
    uint64_t next_event_id = 1;
    uint64_t generation = 0;
};

class RuntimeDomainPodPipeline {
public:
    RuntimeDomainPodPipeline();

    void reset(uint32_t cell_count = 0, uint32_t country_count = 0);
    bool execute_day(const RuntimeDayContext &context,
                     const RuntimeEnvironmentSnapshot *environment,
                     const RuntimeCountryPodSnapshot *country,
                     RuntimeDayCommit &day_commit,
                     std::vector<RuntimeVisualIntent> &visual_intents,
                     std::vector<RuntimeCommandReceipt> &receipts);

    // PKSR section codec. The codec is little-endian, bounded and entirely
    // independent of Godot so the worker can build/restore it at a safe day
    // boundary.
    void serialize(std::vector<uint8_t> &out) const;
    bool restore(const uint8_t *data, size_t size, std::string &error);

    const RuntimeDomainPipelineReport &report() const { return _report; }
    uint32_t completed_domain_mask() const { return _report.completed_domain_mask; }

    // Explicit Climate ownership boundary.  The returned snapshot is a deep
    // copy and can therefore be published through the host without exposing
    // the worker's mutable vectors to the main thread.
    void snapshot_climate(RuntimeClimatePodSnapshot &out) const;
    bool restore_climate(const RuntimeClimatePodSnapshot &snapshot,
                         std::string &error);

    // Cheap deterministic checks used by CI and by the GDExtension smoke
    // test.  They exercise all state stores without constructing Godot values.
    static bool self_test(std::string &error);

private:
    static uint64_t hash_mix(uint64_t value, uint64_t input);
    static bool finite_environment(const RuntimeEnvironmentSnapshot *environment);
    RuntimeDomainReport run_input_capture(const RuntimeDayContext &context,
                                          const RuntimeEnvironmentSnapshot *environment);
    RuntimeDomainReport run_climate(const RuntimeDayContext &context,
                                    const RuntimeEnvironmentSnapshot *environment,
                                    std::vector<RuntimeVisualIntent> &visuals);
    RuntimeDomainReport run_country(const RuntimeDayContext &context,
                                    const RuntimeCountryPodSnapshot *country,
                                    std::vector<RuntimeDomainIntent> &intents);
    RuntimeDomainReport run_trigger(const RuntimeDayContext &context,
                                    std::vector<RuntimeDomainIntent> &intents);
    RuntimeDomainReport run_ideology(const RuntimeDayContext &context,
                                     std::vector<RuntimeDomainIntent> &intents);
    RuntimeDomainReport run_effect(const RuntimeDayContext &context,
                                   std::vector<RuntimeDomainIntent> &intents);
    RuntimeDomainReport run_modifier(const RuntimeDayContext &context,
                                     std::vector<RuntimeDomainAck> &acks);
    RuntimeDomainReport run_gameplay_effect(const RuntimeDayContext &context,
                                            std::vector<RuntimeDomainIntent> &intents);
    RuntimeDomainReport run_economy(const RuntimeDayContext &context,
                                    const RuntimeCountryPodSnapshot *country,
                                    std::vector<RuntimeDomainAck> &acks);
    RuntimeDomainReport run_events(const RuntimeDayContext &context,
                                   std::vector<RuntimeDomainIntent> &intents);

    RuntimeModifierPodState _modifier;
    RuntimeEffectPodState _effect;
    RuntimeIdeologyPodState _ideology;
    RuntimeTriggerPodState _trigger;
    RuntimeClimatePodState _climate;
    RuntimeEconomyPodState _economy;
    RuntimeEventsPodState _events;
    RuntimeDomainPipelineReport _report{};
    std::vector<RuntimeDomainIntent> _intents;
    std::vector<RuntimeDomainAck> _acks;
    bool _last_execute_ok = true;
};

} // namespace pk
