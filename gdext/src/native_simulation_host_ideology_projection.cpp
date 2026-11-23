#include "native_simulation_day_context.h"

#include "country_api.h"
#include "economy_api.h"
#include "derived_cell_layer.h"
#include "ideology_runtime.h"
#include "modifier_api.h"
#include "runtime_ideology_read_view.h"
#include "pk_log.h"

namespace pk {
using namespace godot;

std::shared_ptr<const RuntimeIdeologyReadView> NativeSimulationHost::latest_ideology_read_view() const {
    const auto commit = std::atomic_load(&_latest_commit);
    return commit && commit->day_tail && commit->day_tail->ideology
        ? commit->day_tail->ideology : _trigger_delivery.initial_ideology_view;
}

std::shared_ptr<const RuntimeIdeologyReadView> NativeSimulationHost::capture_ideology_read_view() const {
    if (_trigger_delivery.ideology == nullptr || _effect_adapter_country == nullptr) return {};
    NativeIdeologyRuntime &runtime = *_trigger_delivery.ideology;
    auto view = std::make_shared<RuntimeIdeologyReadView>();
    view->report = runtime.report();
    view->report["worker_import_pending"] = runtime.worker_import_pending();
    view->report["worker_import_attempts"] = static_cast<int64_t>(runtime.worker_import_attempts());
    view->report["worker_import_last_code"] = String(runtime.worker_import_last_code().c_str());
    view->save = runtime.capture();
    view->receipts = runtime.poll_receipts(0, 4096);
    auto business = std::make_shared<RuntimeIdeologyPodSnapshot>();
    if (runtime.export_pod_business_snapshot(*business)) view->business = std::move(business);
    if (_economy_modifier_view != nullptr) {
        const DerivedCellFront *derived = modifier_api::derived_cell_front(*_economy_modifier_view);
        if (derived != nullptr) view->derived = std::make_shared<DerivedCellFront>(*derived);
    }
    CountryEconomySnapshot country;
    if (!country_api::copy_economy_snapshot(*_effect_adapter_country, country)) return view;
    const int32_t count = view->report.get("ideology_count", 0);
    PackedInt32Array ids;
    ids.resize(count);
    for (int32_t id = 0; id < count; ++id) ids.set(id, id);
    for (const uint64_t handle : country.country_handles) {
        if (handle == 0) continue;
        auto &row = view->countries[handle];
        row.state = runtime.snapshot(static_cast<int64_t>(handle));
        row.instances = runtime.effect_instance_report(static_cast<int64_t>(handle));
        row.targets = runtime.effect_target_report(static_cast<int64_t>(handle));
        row.eligibility = runtime.preview_offer_eligibility(static_cast<int64_t>(handle));
        row.batch = runtime.explain_batch(static_cast<int64_t>(handle), ids);
        row.explanations.reserve(count);
        for (int32_t id = 0; id < count; ++id)
            row.explanations.push_back(runtime.explain(static_cast<int64_t>(handle), id));
    }
    return view;
}

void NativeSimulationHost::publish_restored_ideology_view() {
    const auto previous = std::atomic_load(&_latest_commit);
    if (!previous) return;
    auto commit = std::make_shared<RuntimeCommit>(*previous);
    auto tail = previous->day_tail ? std::make_shared<RuntimeDayTail>(*previous->day_tail)
                                   : std::make_shared<RuntimeDayTail>();
    tail->ideology = capture_ideology_read_view();
    commit->day_tail = std::move(tail);
    std::atomic_store(&_latest_commit, std::shared_ptr<const RuntimeCommit>(std::move(commit)));
}

const char *NativeSimulationHost::stage_ideology_projection(DayExecution &day) {
    if (_trigger_delivery.ideology == nullptr) return nullptr;
    NativeIdeologyRuntime &runtime = *_trigger_delivery.ideology;
    const auto &snapshot = _ideology_pod_authority.snapshot();
    std::string error;
    if (snapshot.generation > runtime.pod_snapshot_generation()) {
        if (const auto opinion = worker_opinion_snapshot_for_ideology_generation(snapshot.generation))
            runtime.set_worker_opinion_inputs(*opinion);
        if (!runtime.apply_pod_snapshot(snapshot, error)) {
            pk::log_error("[ideology] executor snapshot: %s", error.c_str());
            return "ideology_executor_snapshot_failed";
        }
    }
    const int64_t next_day = day.plan.context.day + 1;
    while (runtime.step_effect_instance_refresh(next_day)) {}
    while (!runtime.step_derived_rebuild(next_day, error, true)) {
        if (!error.empty()) break;
    }
    if (!error.empty()) {
        pk::log_error("[ideology] executor projection: %s", error.c_str());
        return "ideology_executor_projection_failed";
    }
    if (!publish_committed_ideology_inputs(error)) {
        pk::log_error("[ideology] executor opinion input: %s", error.c_str());
        return "ideology_executor_opinion_invalid";
    }
    _executor_day_tail->ideology = capture_ideology_read_view();
    return nullptr;
}

} // namespace pk
