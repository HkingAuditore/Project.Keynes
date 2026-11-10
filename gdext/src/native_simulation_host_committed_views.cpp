#include "native_simulation_host.h"
#include "economy_runtime.h"
#include "ideology_opinion_bridge.h"
#include "country_ai_core.h"
#include <cassert>

namespace pk {
RuntimePublishedView<RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::copy_economy_opinion_view(int64_t day) {
    auto source = std::atomic_load_explicit(&_ideology_opinion_snapshot,
                                           std::memory_order_acquire);
    if (_economy_production_runtime != nullptr &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        RuntimeExecutionContext::active_for(this) &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
            runtime_domain_mask(RuntimeDomainId::ECONOMY)) != 0u) {
        // The executor owns both stages and holds their day boundary. Observe
        // Economy's last commit directly; a delayed main-thread publication
        // must not choose which earlier opinion this day settles against.
        const auto committed = _economy_production_runtime->copy_lineage_opinion_view();
        auto opinion = ideology_opinion_from_economy(*committed.data);
        if (_economy_production_runtime->class_opinion_source_override_enabled_for_test())
            opinion = ideology_opinion_from_economy(
                _economy_production_runtime->country_class_opinion_source_snapshot());
        source = pin_ideology_reference_opinion(day, opinion);
        if (source->revision == 0) source.reset();
    }
    if (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW &&
        ideology_parity_enabled()) {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        const auto found = _ideology_reference_opinions.find(day);
        source = found != _ideology_reference_opinions.end() ? found->second : nullptr;
    }
    // Both publishers copy Economy's completed opinion, never its working buffer.
    return RuntimePublishedView<RuntimeIdeologyOpinionSnapshot>::copy(source,
        source ? source->revision : 0, source ? source->committed_day : -1);
}

RuntimePublishedView<RuntimeIdeologyPodSnapshot>
NativeSimulationHost::copy_annual_ideology_view() const {
    const auto source = std::atomic_load_explicit(&_ideology_snapshot,
                                                std::memory_order_acquire);
    // This pointer is installed only after commit (or completed restore).
    return RuntimePublishedView<RuntimeIdeologyPodSnapshot>::copy(source,
        source ? source->generation : 0, source ? source->committed_day : -1);
}
RuntimePublishedView<CountryAiEconomyDigest>
NativeSimulationHost::copy_country_ai_economy_view() const {
    const auto source = _economy_production_runtime != nullptr
        ? _economy_production_runtime->country_ai_digest() : nullptr;
    return RuntimePublishedView<CountryAiEconomyDigest>::copy(source,
        source ? source->revision : 0, source ? source->commit_day : -1);
}
RuntimePublishedView<RuntimeCountryPodSnapshot>
NativeSimulationHost::copy_annual_country_view() const {
    // publish_day calls this only after the Country plan has closed.
    assert(!_country_pod_plan_active);
    const auto source = country_asset_snapshot();
    auto view = RuntimePublishedView<RuntimeCountryPodSnapshot>::copy(source,
        source ? source->generation : 0, source ? source->committed_day : -1);
    view.committed = !_country_pod_plan_active;
    return view;
}
} // namespace pk
