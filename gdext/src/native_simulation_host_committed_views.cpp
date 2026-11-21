#include "native_simulation_host.h"
#include "economy_runtime.h"
#include "ideology_opinion_bridge.h"
#include "country_ai_core.h"
#include <cassert>

namespace pk {
bool NativeSimulationHost::publish_committed_ideology_inputs(std::string &error) {
    if (_economy_production_runtime == nullptr) return true;
    const auto &economy = *_economy_production_runtime;
    const auto opinion = economy.class_opinion_source_override_enabled_for_test()
        ? economy.country_class_opinion_source_snapshot() : economy.country_class_opinion_snapshot();
    const auto previous = std::atomic_load(&_ideology_opinion_snapshot);
    if (opinion.revision == 0 || (previous && opinion.revision == previous->revision)) return true;
    if (const auto tags = economy.published_tag_snapshot())
        set_ideology_cell_tags(tags->tag_words, tags->tag_bits);
    else
        set_ideology_cell_tags(0, {});
    return publish_ideology_opinion_snapshot(ideology_opinion_from_economy(opinion), error);
}

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

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::expand_ideology_opinion(const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion) {
    const size_t old_count = opinion.country_count, new_count = country.country_count;
    const size_t old_lanes = old_count * opinion.class_count;
    const size_t new_lanes = new_count * opinion.class_count;
    if (old_count >= new_count || country.country_generation.size() != new_count ||
        country.country_active.size() != new_count ||
        opinion.country_handles.size() != old_count || opinion.country_generations.size() != old_count ||
        opinion.population.size() != old_lanes || opinion.funds.size() != old_lanes ||
        opinion.owner_employed.size() != old_lanes || opinion.satisfaction_weighted.size() != old_lanes ||
        opinion.satisfaction_q16.size() != old_lanes) return {};
    auto out = std::make_shared<RuntimeIdeologyOpinionSnapshot>(opinion);
    for (size_t slot = old_count; slot < new_count; ++slot) {
        const uint64_t generation = country.country_generation[slot];
        out->country_generations.push_back(generation);
        out->country_handles.push_back(country.country_active[slot] ? (generation << 32) | slot : 0);
    }
    out->country_count = new_count;
    out->population.resize(new_lanes, 0);
    out->funds.resize(new_lanes, 0);
    out->owner_employed.resize(new_lanes, 0);
    out->satisfaction_weighted.resize(new_lanes, 0);
    out->satisfaction_q16.resize(new_lanes, 0);
    if (!out->incidence_measured.empty()) out->incidence_measured.resize(new_count, 0);
    if (!out->class_incidence_q16.empty())
        out->class_incidence_q16.resize(new_lanes * out->incidence_channel_count, 0);
    for (auto *values : {&out->country_population, &out->country_buildings_installed,
                         &out->country_trade_base_value}) {
        if (values->size() == old_count) values->resize(new_count, 0);
    }
    return out;
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
