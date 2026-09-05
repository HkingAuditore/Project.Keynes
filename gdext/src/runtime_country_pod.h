#pragma once

#include "runtime_pod_protocol.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pk {

struct RuntimeCountryPodPlan {
    RuntimeDomainHeader header{};
    RuntimeCountryPodSnapshot next_state{};
    std::vector<RuntimeCountryCommand> commands;
    std::vector<RuntimeCommandReceipt> receipts;
    std::vector<RuntimeDomainIntent> intents;
    std::vector<RuntimeDomainAck> acks;
    uint32_t required_ack_count = 0;
    uint8_t preflight_ok = 0;
    uint8_t committed = 0;
};

struct RuntimeCountryPodSaveSection {
    RuntimeDomainSaveSection descriptor{};
    uint64_t catalog_hash = 0;
    int64_t committed_day = -1;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    std::vector<uint8_t> payload;
};

struct RuntimeCountryPodParityReport {
    int64_t day = -1;
    uint32_t field = 0;
    uint32_t country_slot = 0;
    uint32_t cell = 0;
    uint64_t reference_bits = 0;
    uint64_t worker_bits = 0;
    uint64_t reference_hash = 0;
    uint64_t worker_hash = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    char reason[64]{};
};

// Worker-only authoritative Country runtime. It is intentionally separate
// from NativeCountryRuntime: the latter remains the synchronous reference and
// Godot facade until every Country/economy/ACK gate is migrated.
class RuntimeCountryPodAuthority {
public:
    RuntimeCountryPodAuthority();

    bool bootstrap(const RuntimeCountryPodSnapshot &snapshot,
                   const RuntimeCountryPodCatalog &catalog,
                   std::string &error);
    bool queue_command(const RuntimeCountryCommand &command,
                       std::string &error);
    bool plan_day(int64_t day, uint64_t input_generation,
                  RuntimeCountryPodPlan &plan, std::string &error);
    bool commit_day(RuntimeCountryPodPlan &plan,
                    const std::vector<RuntimeDomainAck> &acks,
                    std::string &error);
    // Abandon a prepared plan after a rejected ACK or a scheduler fault. The
    // committed state and pending command queue remain untouched, allowing a
    // deterministic retry or an explicit fault transition.
    void discard_plan() noexcept { _plan_active = false; }
    bool snapshot(RuntimeCountryPodSnapshot &out, std::string &error) const;
    bool encode_save(RuntimeCountryPodSaveSection &out, std::string &error) const;
    bool restore_save(const RuntimeCountryPodSaveSection &section,
                      const RuntimeCountryPodCatalog &catalog,
                      std::string &error);
    bool validate_catalog(const RuntimeCountryPodCatalog &catalog,
                          std::string &error) const;
    uint64_t generation() const noexcept { return _state.generation; }
    int64_t committed_day() const noexcept { return _state.committed_day; }
    uint64_t state_hash() const noexcept { return _state.state_hash; }
    uint32_t pending_command_count() const noexcept {
        return static_cast<uint32_t>(_pending.size());
    }
    static bool self_test(std::string &error);

private:
    RuntimeCountryPodSnapshot _state;
    RuntimeCountryPodCatalog _catalog;
    std::vector<RuntimeCountryCommand> _pending;
    std::vector<RuntimeCommandReceipt> _receipt_scratch;
    std::vector<RuntimeDomainIntent> _intent_scratch;
    bool _bootstrapped = false;
    bool _plan_active = false;
    uint64_t _next_generation = 1;

    bool validate_state(const RuntimeCountryPodSnapshot &snapshot,
                        std::string &error) const;
    bool apply_command(RuntimeCountryPodSnapshot &state,
                       const RuntimeCountryCommand &command,
                       RuntimeCountryPodPlan &plan,
                       std::string &error) const;
    bool validate_target(const RuntimeCountryPodSnapshot &state,
                         const RuntimeCountryCommand &command,
                         int32_t &slot, std::string &error) const;
    bool research_condition_met(const RuntimeCountryPodSnapshot &state,
                                int32_t slot, int32_t technology) const;
    bool technology_prerequisites_met(const RuntimeCountryPodSnapshot &state,
                                      int32_t slot, int32_t technology) const;
    void rebuild_territory_csr(RuntimeCountryPodSnapshot &state) const;
    static uint64_t hash_state(const RuntimeCountryPodSnapshot &state);
};

// Research/territory probe that can run on a worker without touching the
// Godot-facing NativeCountryRuntime.  It is deliberately conservative: the
// adapter reports a complete numeric calculation only for the immutable
// snapshot projection, while cross-domain ACK ownership remains explicit.
class RuntimeCountryPodAdapter {
public:
    static bool execute_day(const RuntimeCountryPodSnapshot &snapshot,
                     const RuntimeCountryDayContext &context,
                     RuntimeCountryDayCommit &commit,
                     RuntimeCountryPodDiagnostics &diagnostics);

    static bool validate_snapshot(const RuntimeCountryPodSnapshot &snapshot,
                                  std::string &error);
    static bool decode_command(const RuntimeCommandPacket &packet,
                               RuntimeCountryCommand &command,
                               std::string &error);
    static bool validate_command(const RuntimeCountryCommand &command,
                                 std::string &error);

};

} // namespace pk
