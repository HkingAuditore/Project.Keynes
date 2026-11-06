#include "runtime_effect_pod.h"
#include <cassert>

namespace pk {
RuntimeEffectCommittedView RuntimeEffectPodAuthority::copy_committed_view(uint64_t instance_id) const {
    assert(!_plan_ready);
    RuntimeEffectCommittedView view;
    view.generation = _snapshot.generation;
    view.day = _snapshot.committed_day;
    view.committed = !_plan_ready;
    for (const auto &instance : _snapshot.instances) {
        if (static_cast<uint64_t>(instance.instance_id) == instance_id) {
            view.instance = instance;
            view.found = true;
            break;
        }
    }
    return view;
}

bool RuntimeEffectPodAuthority::committed_view_self_test(std::string &error) {
    RuntimeEffectPodAuthority owner;
    owner._snapshot.generation = 4;
    owner._snapshot.committed_day = 2;
    RuntimeEffectPodInstance instance;
    instance.instance_id = 7;
    instance.source_id = 123;
    owner._snapshot.instances.push_back(instance);
    const auto view = owner.copy_committed_view(7);
    owner._snapshot.instances[0].source_id = 456;
    if (!view.found || view.instance.source_id != 123 || owner.copy_committed_view(8).found) {
        error = "effect_view_not_owned"; return false;
    }
    if (!owner.observe_committed_view(view) || !owner.observe_committed_view(view)) {
        error = "effect_view_retry_failed"; return false;
    }
    auto invalid = view;
    invalid.generation--;
    if (owner.observe_committed_view(invalid)) { error = "view_generation_regressed"; return false; }
    invalid = view; invalid.day--;
    if (owner.observe_committed_view(invalid)) { error = "view_day_regressed"; return false; }
    invalid = view; invalid.committed = false;
    if (owner.observe_committed_view(invalid)) { error = "view_inflight_accepted"; return false; }
    owner.reset();
    owner._snapshot.generation = 5;
    owner._snapshot.committed_day = 3;
    if (!owner.observe_committed_view(owner.copy_committed_view(7))) {
        error = "view_reset_failed"; return false;
    }
    return true;
}
} // namespace pk
