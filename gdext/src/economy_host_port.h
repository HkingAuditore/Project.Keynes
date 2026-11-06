#pragma once

#include "runtime_pod_protocol.h"
#include "runtime_economy_pod.h"
#include "annual_development_ledger.h"

#include <cstdint>
#include <string>

namespace pk {

// Narrow host boundary used by Economy.  Keep this list limited to the
// operations that Economy actually performs on its owning simulation host.
class EconomyHostPort {
public:
    virtual ~EconomyHostPort() = default;

    // Country asset protocol.
    virtual bool poll_country_economy_asset_request(
            RuntimeEconomyAssetRequest &out) = 0;
    virtual bool country_economy_asset_terminal_result(
            uint64_t request_id, RuntimeEconomyAssetResult &out) const = 0;
    virtual bool submit_country_economy_asset_result(
            const RuntimeEconomyAssetResult &result, std::string &error) = 0;
    virtual bool requeue_country_economy_asset_request(
            uint64_t request_id, std::string &error) = 0;
    virtual bool enqueue_economy_origin_country_asset(
            RuntimeEconomyAssetRequest request, std::string &error) = 0;
    virtual void acknowledge_country_economy_asset_consumed(
            uint64_t request_id) noexcept = 0;
    virtual void defer_country_economy_asset_settlement(
            uint64_t request_id) = 0;
    virtual void release_country_economy_asset_settlement(
            uint64_t request_id) noexcept = 0;
    virtual bool country_economy_asset_settlement_deferred(
            uint64_t request_id) const = 0;
    virtual bool prepare_worker_cohort_cash(
            RuntimeEconomyAssetRequest &request, std::string &error) = 0;
    virtual bool finish_worker_country_asset(
            uint64_t request_id, RuntimeEconomyAssetResult &result,
            std::string &error) = 0;
    virtual bool flush_country_economy_asset_commits(
            std::string &error, uint64_t settle_request_id = 0,
            bool skip_audit_snapshot = false,
            int64_t shadow_through_day = -1) = 0;

    // Published country state (publication and command identity group).
    virtual bool publish_country_worker_snapshot(
            uint32_t dirty_families, std::string &error) = 0;

    // Execution authority and thread gates.
    virtual bool domain_is_worker_authoritative(
            RuntimeDomainId domain) const = 0;
    virtual bool economy_worker_owns_execution() const noexcept = 0;
    virtual bool on_worker_thread() const noexcept = 0;
    virtual bool country_authority_owner_is_worker() const = 0;
    virtual EconomyProductionWriter economy_production_writer_effective()
            const noexcept = 0;
    virtual bool economy_parity_shadow_enabled() const noexcept = 0;

    // Annual development report.
    virtual bool annual_development_enabled() const = 0;
    virtual uint64_t annual_country_handle() const = 0;
    virtual void publish_annual_economy(const AnnualEconomyFacts &facts) = 0;

    // Published references and command identity.
    virtual void publish_economy_stage_reference(
            uint32_t stage, int64_t day, uint64_t generation,
            uint64_t state_hash, uint64_t work_units) noexcept = 0;
    virtual uint64_t allocate_command_request_id() = 0;
};

} // namespace pk
