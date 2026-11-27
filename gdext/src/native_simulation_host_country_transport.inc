// Country transactions, command acknowledgements, and checkpoint transport.

    // Ideology parity, mirroring the country pair above: the main thread publishes
    // its hash for a day, the worker's own state hash is compared against it.
    bool publish_ideology_reference(int64_t day,
                                    const RuntimeIdeologyPodSnapshot &state);
#include "native_simulation_host_ideology_parity.h"

    bool publish_country_reference(int64_t day, uint64_t reference_state_hash,
                                   std::string &error,
                                   const RuntimeCountryPodSnapshot *snapshot = nullptr);
    bool mirror_country_peer_result(const CountryPeerResult &result,
                                    std::string &error) override;
    bool mirror_sync_country_economy_asset(
            const RuntimeEconomyAssetRequest &request,
            const RuntimeEconomyAssetResult &result, std::string &error) override;
    bool country_shadow_parity_self_test(std::string &error) const;
    bool poll_country_worker_intent(CountryPeerIntent &out);
    bool submit_country_worker_result(const CountryPeerResult &result,
                                      std::string &error);
    // Post-commit Country notifications (era milestones). Unlike plan intents
    // they carry no ACK barrier; `snapshot` is the committed Country state that
    // activated the milestone, so the main-thread planner reads that boundary.
    struct CountryWorkerNotification {
        CountryPeerIntent intent;
        std::shared_ptr<const RuntimeCountryPodSnapshot> snapshot;
    };
    bool poll_country_worker_notification(CountryWorkerNotification &out);
    bool poll_country_economy_asset_request(
            RuntimeEconomyAssetRequest &out) override;
    // Economy owns peer-side mutation. Its continuation needs a read-only
    // terminal lookup so it can resume the same request identity without
    // creating a second Country transaction.
    bool country_economy_asset_terminal_result(
            uint64_t request_id, RuntimeEconomyAssetResult &out) const override;
    bool submit_country_economy_asset_result(
            const RuntimeEconomyAssetResult &result, std::string &error) override;
    bool requeue_country_economy_asset_request(uint64_t request_id,
                                               std::string &error) override;
    RuntimeEconomyAssetProtocolStatus
    country_economy_asset_protocol_status() const;
    bool country_economy_asset_protocol_self_test(std::string &error) const;
    bool enqueue_economy_origin_country_asset(
            RuntimeEconomyAssetRequest request, std::string &error) override;
    // True only on the thread that is currently executing a simulation day:
    // the worker thread in worker mode, or the calling thread inside
    // `run_inline_day()` under native_daily_inline. Callers that can run on
    // either thread must check this before taking a worker-only in-thread
    // path; a main-thread caller that is NOT inside an inline day still has to
    // use the Host peer queue.
    bool on_worker_thread() const noexcept override {
        return RuntimeExecutionContext::active_for(this);
    }
    const char *preflight_military_construction(
        uint64_t country, int32_t cell, int32_t type, bool demolishing,
        int64_t day, int32_t &building, int32_t &slot) const override;
    void commit_military_construction(
        int32_t cell, int32_t building, int32_t slot, int64_t day, int64_t ready_day) override;
    bool prepare_worker_cohort_cash(RuntimeEconomyAssetRequest &request,
                                   std::string &error) override;
    bool finish_worker_country_asset(uint64_t request_id,
                                  RuntimeEconomyAssetResult &result,
                                  std::string &error) override;
    // Commit Country treasury for Economy-origin terminals when Economy is
    // still sync (Country unique-writer). Worker-thread finish_worker_* is
    // preferred when Economy is also authoritative.
    // COMPLETED RESEARCH_PURCHASE is deferred until Economy settles market /
    // merchant credits in the same advance: pass settle_request_id to include
    // that one wire id. Ids registered via defer_country_economy_asset_settlement
    // follow the same rule. Rejected/faulted terminals still retire immediately.
    bool flush_country_economy_asset_commits(std::string &error,
                                            uint64_t settle_request_id = 0,
                                            bool skip_audit_snapshot = false,
                                            int64_t shadow_through_day = -1) override;
    bool publish_country_worker_snapshot(uint32_t dirty_families,
                                         std::string &error) override;
    // Publish plan.next_state for UI while the open plan is still peer-waiting.
    // Does not close the plan or mutate authority committed_day; commit_day /
    // commit_rejected_day remain the only authority closes.
    // Does NOT update country_economy_audit_snapshot — Economy conservation must
    // not observe uncommitted research spend / purchase credits from preview.
    bool publish_country_plan_preview_snapshot(std::string &error);
    std::shared_ptr<const RuntimeCountryPodSnapshot> country_asset_snapshot() const override {
        return std::atomic_load_explicit(&_country_snapshot, std::memory_order_acquire);
    }
    // Last sealed / authority-published Country assets for Economy audits.
    // Falls back to country_asset_snapshot when no sealed view exists yet.
    std::shared_ptr<const RuntimeCountryPodSnapshot>
    country_economy_audit_snapshot() const override {
        auto audit = std::atomic_load_explicit(&_country_economy_audit_snapshot,
                                               std::memory_order_acquire);
        if (audit != nullptr) return audit;
        return country_asset_snapshot();
    }
    enum class CountryAuthorityOwner : uint8_t { SYNC = 0, WORKER = 1 };
    struct CountryAuthorityHandoffStatus {
        CountryAuthorityOwner owner = CountryAuthorityOwner::SYNC;
        CountryAuthorityOwner prepared_target = CountryAuthorityOwner::SYNC;
        bool prepare_pending = false;
        uint64_t session_epoch = 0;
        char last_reason[64]{};
    };
    bool prepare_country_authority_handoff(CountryAuthorityOwner target,
                                           std::string &error);
    bool abort_country_authority_handoff(std::string &error);
    bool install_country_authority_handoff(std::string &error);
    CountryAuthorityHandoffStatus country_authority_handoff_status() const;
    // D10 unique-writer / sync-slice gate. Independent of
    // authoritative_domain_mask for protocol tests, but production ACTIVE
    // Country also sets this via domain_is_worker_authoritative after D12.
    bool country_authority_owner_is_worker() const override {
        return country_authority_handoff_status().owner ==
            CountryAuthorityOwner::WORKER;
    }
    bool country_authority_handoff_prepare_pending() const override {
        return country_authority_handoff_status().prepare_pending;
    }
    bool country_authority_handoff_self_test(std::string &error) const;
    RuntimeCountryReadView country_worker_read_view(
            uint64_t after_generation = 0) const;
    using CountryWorkerProtocolStatus = RuntimeCountryWorkerProtocolStatus;
    CountryWorkerProtocolStatus country_worker_protocol_status() const;
    bool publish_country_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                    std::string &error);
    // Identity of the Country checkpoint a save is being built from. Economy
    // save headers must carry this under worker Country authority.
    bool country_checkpoint_identity(uint64_t &generation,
                                     uint64_t &business_state_hash) const;
    bool pending_country_checkpoint(CountryCoreCheckpoint &out,
                                    std::string &error) const;
    RuntimeCountryPodDiagnostics country_pod_diagnostics() const;
