#include "country_read_view.h"
#include "country_runtime.h"

namespace pk {
static_assert(CountryReadView::TAX_KIND_COUNT == NativeCountryRuntime::TAX_KIND_COUNT);
static_assert(CountryReadView::TAX_RATE_INHERIT == NativeCountryRuntime::TAX_RATE_INHERIT);
static_assert(CountryReadView::TAX_MODE_INHERIT == NativeCountryRuntime::TAX_MODE_INHERIT);
CountryReadView NativeCountryRuntime::read_view() const {
    static const CountryReadView::Queries queries{
        [](const void *owner, CountryReadView::Snapshot &out) {
            return static_cast<const NativeCountryRuntime *>(owner)->copy_economy_snapshot(out);
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->total_cash();
        },
        [](const void *owner, int32_t slot) {
            return static_cast<const NativeCountryRuntime *>(owner)->cash_for_slot(slot);
        },
        [](const void *owner, int32_t good) {
            return static_cast<const NativeCountryRuntime *>(owner)->total_good(good);
        },
        [](const void *owner, int64_t handle) {
            return static_cast<const NativeCountryRuntime *>(owner)->valid_handle(handle);
        },
        [](const void *owner, int32_t cell) {
            return static_cast<const NativeCountryRuntime *>(owner)->country_handle_for_cell(cell);
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->research_consumed_total();
        },
        [](const void *owner, int64_t &goods, int64_t &research, int64_t &cash) {
            return static_cast<const NativeCountryRuntime *>(owner)->sample_economy_goods_audit(goods, research, cash);
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->economy_available();
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->sync_store_writes_forbidden();
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->technology_points_good_id();
        },
        [](const void *owner, int32_t cell) {
            return static_cast<const NativeCountryRuntime *>(owner)->country_slot_for_cell(cell);
        },
        [](const void *owner, int32_t slot, int32_t technology) {
            return static_cast<const NativeCountryRuntime *>(owner)->has_technology(slot, technology);
        },
        [](const void *owner, int32_t slot) {
            return static_cast<const NativeCountryRuntime *>(owner)->political_regime_id_for_slot(slot);
        },
        [](const void *owner, int32_t slot) {
            return static_cast<const NativeCountryRuntime *>(owner)->political_regime_capabilities_for_slot(slot);
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->good_count();
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->technology_count();
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->starting_country_slot();
        },
        [](const void *owner, int64_t day) {
            return static_cast<const NativeCountryRuntime *>(owner)->should_run(day);
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->state_hash();
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->generation();
        },
        [](const void *owner) {
            return static_cast<const NativeCountryRuntime *>(owner)->state_hash_v3_compat();
        },
        [](const void *owner, int64_t handle) {
            return static_cast<const NativeCountryRuntime *>(owner)->cash_for_handle(handle);
        },
        [](const void *owner, int64_t handle, int32_t good) {
            return static_cast<const NativeCountryRuntime *>(owner)->good_for_handle(handle, good);
        },
        [](const void *owner, int32_t slot, int32_t good) {
            return static_cast<const NativeCountryRuntime *>(owner)->good_for_slot(slot, good);
        },
        [](const void *owner, std::vector<int32_t> &out) {
            return static_cast<const NativeCountryRuntime *>(owner)->copy_technology_domains(out);
        },
        [](const void *owner, int32_t slot, int32_t signal) {
            return static_cast<const NativeCountryRuntime *>(owner)->has_research_signal(slot, signal);
        },
        [](const void *owner, int32_t slot, int32_t signal) {
            return static_cast<const NativeCountryRuntime *>(owner)->research_signal_evidence_count(slot, signal);
        },
        [](const void *owner, int32_t slot, bool &enabled, int64_t &cash_budget, int64_t &remaining_points) {
            return static_cast<const NativeCountryRuntime *>(owner)->research_procurement_policy(slot, enabled, cash_budget, remaining_points);
        },
    };
    return CountryReadView(this, queries);
}
} // namespace pk
