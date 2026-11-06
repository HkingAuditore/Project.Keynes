#include "runtime_modifier_pod.h"
#include <cassert>

namespace pk {
RuntimeModifierCommittedView RuntimeModifierPodAuthority::copy_committed_view() const {
    assert(!_plan_ready);
    RuntimeModifierCommittedView view;
    view.generation = _snapshot.generation;
    view.day = _snapshot.committed_day;
    view.committed = !_plan_ready;
    view.buckets = _snapshot.buckets;
    return view;
}

bool RuntimeModifierPodAuthority::committed_view_self_test(std::string &error) {
    RuntimeModifierPodAuthority owner;
    owner._snapshot.generation = 4;
    owner._snapshot.committed_day = 2;
    RuntimeModifierPodBucket bucket;
    bucket.sum_add = 0.25;
    bucket.product_factor = 1.5;
    owner._snapshot.buckets.push_back(bucket);
    const auto view = owner.copy_committed_view();
    owner._snapshot.buckets[0].sum_add = 0.5;
    if (view.buckets[0].sum_add != 0.25 || view.buckets[0].product_factor != 1.5) {
        error = "modifier_view_not_owned"; return false;
    }
    if (!owner.observe_committed_view(view) || !owner.observe_committed_view(view)) {
        error = "modifier_view_retry_failed"; return false;
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
    if (!owner.observe_committed_view(owner.copy_committed_view())) {
        error = "view_reset_failed"; return false;
    }
    return true;
}
} // namespace pk
