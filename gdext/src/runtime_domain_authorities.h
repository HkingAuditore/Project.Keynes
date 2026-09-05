#pragma once

#include "runtime_authoritative_domains.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

// A worker-only transaction plan for the domains that are still being moved
// behind NativeSimulationHost.  The plan owns no Godot values and is never
// exposed to the main thread.  All vectors are resident arenas allocated by
// reset(); a day only rewinds their logical sizes.
struct RuntimeDomainAuthorityPlan {
    RuntimeDayContext context{};
    std::array<RuntimeDomainReport, RUNTIME_DOMAIN_STAGE_COUNT> reports{};
    std::vector<RuntimeDomainIntent> intents;
    std::vector<RuntimeDomainAck> acks;
    uint32_t planned_mask = 0;
    uint32_t ack_required_mask = 0;
    uint32_t ack_received_mask = 0;
    uint64_t input_hash = 0;
    uint64_t base_hash = 0;
    uint64_t next_hash = 0;
    uint8_t preflight_ok = 0;
    char error[64]{};
};

struct RuntimeDomainAuthorityReport {
    std::array<RuntimeDomainReport, RUNTIME_DOMAIN_STAGE_COUNT> domains{};
    uint32_t diagnostic_planned_mask = 0;
    uint32_t diagnostic_committed_mask = 0;
    uint32_t ack_required_mask = 0;
    uint32_t ack_received_mask = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint64_t state_hash = 0;
    uint64_t input_hash = 0;
    uint64_t work_units = 0;
    uint32_t changed_cells = 0;
    uint8_t preflight_ok = 0;
    uint8_t commit_ok = 0;
    char fallback_reason[64]{};
};

// Explicit aliases keep the per-domain API names stable while the concrete
// plan/commit storage is still consolidated in one bounded worker runner.
using RuntimeModifierPlan = RuntimeDomainAuthorityPlan;
using RuntimeEffectPlan = RuntimeDomainAuthorityPlan;
using RuntimeIdeologyPlan = RuntimeDomainAuthorityPlan;
using RuntimeTriggerPlan = RuntimeDomainAuthorityPlan;
using RuntimeEconomyPlan = RuntimeDomainAuthorityPlan;
using RuntimeEventsPlan = RuntimeDomainAuthorityPlan;

// Godot-free deterministic adapters for the remaining gameplay domains.  This
// is a SHADOW/validation authority: it executes a complete plan/replay/ACK
// transaction, but its capability mask is intentionally not used to unlock
// ACTIVE until each domain has passed the long A/B gate against the legacy
// reference implementation.
class RuntimeDomainAuthorityRunner {
public:
    RuntimeDomainAuthorityRunner();

    void reset(uint32_t cell_count, uint32_t country_count,
               size_t modifier_capacity = 256u,
               size_t effect_capacity = 256u,
               size_t trigger_capacity = 1024u,
               size_t event_capacity = RUNTIME_DOMAIN_EVENT_CAPACITY);

    bool plan_day(const RuntimeDayContext &context,
                  const RuntimeEnvironmentSnapshot *environment,
                  const RuntimeCountryPodSnapshot *country_snapshot,
                  RuntimeDomainAuthorityPlan &plan,
                  std::string &error);
    bool commit_day(RuntimeDomainAuthorityPlan &plan, std::string &error);
    void discard_plan();

    const RuntimeDomainAuthorityReport &report() const { return _report; }
    const RuntimeAuthoritativeDomainStores &stores() const { return _current; }
    RuntimeAuthoritativeDomainStores &stores_for_test() { return _current; }

    // This mask is deliberately diagnostic-only.  Returning zero prevents a
    // caller from accidentally treating the probe as an ACTIVE capability.
    static constexpr uint32_t capability_mask() { return 0u; }
    static bool self_test(std::string &error);

private:
    RuntimeDomainReport run_input_capture(const RuntimeDayContext &context,
                                          const RuntimeEnvironmentSnapshot *environment,
                                          uint64_t &input_hash) const;
    RuntimeDomainReport run_climate(const RuntimeDayContext &context,
                                    const RuntimeEnvironmentSnapshot *environment,
                                    uint64_t &work_units,
                                    uint32_t &changed_cells);
    RuntimeDomainReport run_country(const RuntimeDayContext &context,
                                    const RuntimeCountryPodSnapshot *snapshot,
                                    uint64_t &work_units);
    RuntimeDomainReport run_trigger_input(const RuntimeDayContext &context,
                                          uint64_t &work_units);
    RuntimeDomainReport run_ideology(const RuntimeDayContext &context,
                                     uint64_t &work_units);
    RuntimeDomainReport run_effect(const RuntimeDayContext &context,
                                   uint64_t &work_units);
    RuntimeDomainReport run_modifier(const RuntimeDayContext &context,
                                     uint64_t &work_units);
    RuntimeDomainReport run_gameplay_effect(const RuntimeDayContext &context,
                                            uint64_t &work_units);
    RuntimeDomainReport run_economy(const RuntimeDayContext &context,
                                    const RuntimeEnvironmentSnapshot *environment,
                                    uint64_t &work_units,
                                    uint32_t &changed_cells);
    RuntimeDomainReport run_events(const RuntimeDayContext &context,
                                   uint64_t &work_units);
    RuntimeDomainReport run_visual(const RuntimeDayContext &context) const;
    RuntimeDomainReport run_commit(const RuntimeDayContext &context) const;

    void set_report_error(RuntimeDomainReport &report, const char *reason) const;
    // Returns false when the bounded ACK arena is exhausted.  Capacity
    // exhaustion is a transaction failure and must never be interpreted as an
    // empty ACK set (which would accidentally satisfy the barrier).
    bool add_ack(RuntimeDomainAuthorityPlan &plan, uint16_t domain,
                 uint64_t transaction_id, uint64_t target_handle,
                 int64_t day, RuntimeDomainAckCode code);
    static uint64_t hash_mix(uint64_t value, uint64_t input) noexcept;

    RuntimeAuthoritativeDomainStores _current;
    RuntimeAuthoritativeDomainStores _next;
    RuntimeDomainAuthorityPlan *_active_plan = nullptr;
    RuntimeDomainAuthorityReport _report{};
    std::vector<RuntimeDomainIntent> _intents;
    std::vector<RuntimeDomainAck> _acks;
    std::vector<RuntimeEventRecord> _event_scratch;
    std::vector<uint64_t> _distinct_scratch;
    bool _plan_ready = false;
};

} // namespace pk
