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
    // Country-owned Economy transactions are published as a separate typed
    // outbox.  The vector is intentionally independent from `intents`: an
    // asset transaction has its own prepare/commit/complete lifecycle and
    // must not be coerced into a generic peer ACK.
    std::vector<RuntimeEconomyAssetRequest> economy_requests;
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
    // Remove only commands belonging to a rejected semantic batch. This is
    // used when transport admission succeeded but worker decode/preflight
    // rejects the batch before a committed plan exists.
    void remove_pending_commands(const std::vector<uint64_t> &request_ids) noexcept;
    bool plan_day(int64_t day, uint64_t input_generation,
                  RuntimeCountryPodPlan &plan, std::string &error);
    bool commit_day(RuntimeCountryPodPlan &plan,
                    const std::vector<RuntimeDomainAck> &acks,
                    std::string &error);
    // Commit the Country-side semantic work of a boundary whose peer intent
    // did not produce an OK ACK. Research consumption, pending activation and
    // already ordered Country commands remain durable; the pending technology
    // stays blocked until a later-day retry.
    //
    // A rejection keeps the generation frozen so the retry keeps its identity.
    // A still-PENDING peer must instead pass advance_generation=true: the day's
    // commands and research progress are real state, and read-view consumers
    // (country_committed, the UI section cache) only observe a new generation.
    bool commit_rejected_day(RuntimeCountryPodPlan &plan,
                             std::string &error,
                             bool advance_generation = false);
    // Abandon a prepared plan after a rejected ACK or a scheduler fault. The
    // committed state and pending command queue remain untouched, allowing a
    // deterministic retry or an explicit fault transition.
    void discard_plan() noexcept { _plan_active = false; }
    bool apply_economy_asset_result(const RuntimeEconomyAssetRequest &request,
                                    const RuntimeEconomyAssetResult &result,
                                    std::string &error);
    // Apply a treasury mutation onto the committed authority state even while a
    // plan is open. Does not bump generation (commit_day still keys on
    // base_generation). Callers that also mutate plan.next_state must apply the
    // same delta there so the eventual commit stays consistent.
    bool apply_economy_asset_commit_to_authority_state(
            const RuntimeEconomyAssetRequest &request,
            const RuntimeEconomyAssetResult &result, std::string &error);
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
    bool has_pending_request(uint64_t request_id) const noexcept {
        if (request_id == 0) return false;
        for (const RuntimeCountryCommand &command : _pending) {
            if (command.request_id == request_id) return true;
        }
        return false;
    }
    // Re-open the research allocation window on an already-planned next_state
    // after a late-fold enqueue / move. Used by the ACTIVE Host while peers
    // are still pending so the new queue head can spend the same calendar day.
    bool catch_up_research_day(RuntimeCountryPodSnapshot &state, int64_t day,
                               RuntimeCountryPodPlan &plan,
                               std::string &error) const {
        if (state.last_research_day >= day)
            state.last_research_day = day - 1;
        return run_research_day(state, day, plan, error);
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
    bool run_research_day(RuntimeCountryPodSnapshot &state,
                          int64_t day, RuntimeCountryPodPlan &plan,
                          std::string &error) const;
    bool activate_pending_technology(RuntimeCountryPodSnapshot &state,
                                     int32_t slot, int32_t technology,
                                     const RuntimeCountryPodPlan &plan,
                                     uint8_t peer_flags,
                                     std::string &error) const;
    void rebuild_territory_csr(RuntimeCountryPodSnapshot &state) const;
    static uint64_t hash_business_state(const RuntimeCountryPodSnapshot &state);
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
