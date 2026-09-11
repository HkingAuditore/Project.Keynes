#pragma once

#include "runtime_country_pod.h"

#include <cstdint>
#include <string>

namespace pk {

bool country_core_validate_target(
    const RuntimeCountryPodSnapshot &state,
    const RuntimeCountryCommand &command, int32_t &slot,
    std::string &error);

bool country_core_research_condition_met(
    const RuntimeCountryPodSnapshot &state,
    const RuntimeCountryPodCatalog &catalog, int32_t slot,
    int32_t technology);

bool country_core_technology_prerequisites_met(
    const RuntimeCountryPodSnapshot &state,
    const RuntimeCountryPodCatalog &catalog, int32_t slot,
    int32_t technology);

void country_core_refresh_discovery(
    RuntimeCountryPodSnapshot &state,
    const RuntimeCountryPodCatalog &catalog, int32_t slot);

// Shared worker command formula. NativeCountryRuntime keeps a staged SoA
// apply for large territory batches; Host/POD plan_day must call this.
bool country_core_apply_command(
    RuntimeCountryPodSnapshot &state,
    const RuntimeCountryPodCatalog &catalog,
    const RuntimeCountryCommand &command,
    RuntimeCountryPodPlan &plan, std::string &error);

void country_core_rebuild_territory_csr(RuntimeCountryPodSnapshot &state);

// Economy-origin / Country-origin treasury mutation against the worker
// snapshot. Reservations live on the Host request record, not the snapshot.
bool country_core_apply_economy_asset_prepare(
    RuntimeCountryPodSnapshot &state,
    const RuntimeCountryPodCatalog &catalog,
    RuntimeEconomyAssetRequest &request,
    std::string &error);

bool country_core_apply_economy_asset_commit(
    RuntimeCountryPodSnapshot &state,
    const RuntimeCountryPodCatalog &catalog,
    const RuntimeEconomyAssetRequest &request,
    const RuntimeEconomyAssetResult &result,
    std::string &error);

// Shared Country business projection hash. SHADOW parity and POD commit must
// use this; PKCN/reference-trace may keep a separate canonical hash.
uint64_t country_core_hash_business_state(const RuntimeCountryPodSnapshot &state);

// First field that disagrees between a production export and a worker snapshot.
// Unknown/uncompared days must not be reported as a match.
bool country_core_first_business_difference(
    const RuntimeCountryPodSnapshot &reference,
    const RuntimeCountryPodSnapshot &worker,
    char *field, size_t field_capacity, int32_t &index);

} // namespace pk
