#include "native_simulation_host.h"
#include "economy_runtime.h"
#include "country_ai_core.h"
#include <cassert>

namespace pk {
RuntimePublishedView<RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::copy_economy_opinion_view(int64_t day) {
    auto source = std::atomic_load_explicit(&_ideology_opinion_snapshot,
                                           std::memory_order_acquire);
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
