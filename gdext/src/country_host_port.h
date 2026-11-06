#pragma once

#include "runtime_pod_protocol.h"
#include "country_core.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pk {

// Narrow host boundary used by Country. Keep this list limited to the
// operations that Country actually performs on its owning simulation host.
class CountryHostPort {
public:
    virtual ~CountryHostPort() = default;

    // Command transport and terminal receipts.
    virtual uint64_t allocate_command_request_id() = 0;
    virtual uint64_t allocate_producer_sequence(uint32_t producer_id) = 0;
    virtual bool enqueue_batch(std::vector<RuntimeCommandPacket> packets) = 0;
    virtual bool try_country_command_terminal(
            uint64_t request_id, CountryCommandReceipt &out) = 0;

    // Authority, lifecycle, and worker gates.
    virtual RuntimeWorkerState state() const = 0;
    virtual bool country_pod_configured() const = 0;
    virtual bool domain_is_worker_authoritative(
            RuntimeDomainId domain) const = 0;
    virtual bool domain_grant_pending(RuntimeDomainId domain) const = 0;
    virtual bool country_authority_handoff_prepare_pending() const = 0;

    // Published Country snapshots used by Country/Economy boundaries.
    virtual std::shared_ptr<const RuntimeCountryPodSnapshot>
    country_asset_snapshot() const = 0;
    virtual std::shared_ptr<const RuntimeCountryPodSnapshot>
    country_economy_audit_snapshot() const = 0;
    virtual bool mirror_sync_country_economy_asset(
            const CountryEconomyAssetRequest &request,
            const CountryEconomyAssetResult &result, std::string &error) = 0;
    virtual bool mirror_country_peer_result(
            const CountryPeerResult &result, std::string &error) = 0;

    // Effect POD technology bridge.
    virtual bool effect_pod_transport_ready() const = 0;
    virtual int32_t effect_pod_program_id_for_key(const char *key) const = 0;
    virtual bool ensure_effect_pod_technology_instance(
            int64_t instance_id, uint32_t generation, int32_t program_id,
            uint64_t target_handle, uint32_t target_generation, int64_t day,
            std::string &error) = 0;
    virtual bool effect_pod_instance_fire_acked(
            int64_t instance_id, uint32_t generation) const = 0;
    virtual std::string describe_effect_pod_technology_state(
            int64_t instance_id, uint32_t generation, int32_t program_id,
            int32_t technology) const = 0;
};

} // namespace pk
