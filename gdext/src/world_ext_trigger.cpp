#include "world_ext.h"

#include "trigger_runtime.h"
#include "effect_runtime.h"
#include "economy_runtime.h"
#include "ideology_runtime.h"

#include <cstring>
#include <vector>

namespace pk {

using namespace godot;

namespace {
TriggerRuntime *runtime_from(void *opaque) {
    return static_cast<TriggerRuntime *>(opaque);
}
const TriggerRuntime *runtime_from(const void *opaque) {
    return static_cast<const TriggerRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "trigger_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_triggers(const Dictionary &catalog) {
    if (_trigger_runtime == nullptr) _trigger_runtime = new TriggerRuntime();
    Dictionary out = runtime_from(_trigger_runtime)->configure(catalog);
    if (static_cast<bool>(out.get("ok", false)) && _economy_runtime != nullptr) {
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_trigger_runtime(
            runtime_from(_trigger_runtime));
    }
    return out;
}

Dictionary DCWorldExt::submit_trigger_events(const Dictionary &batch) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->submit_events(batch);
}

Dictionary DCWorldExt::submit_trigger_snapshots(const Dictionary &batch) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->submit_snapshots(batch);
}

Dictionary DCWorldExt::run_trigger_daily(int64_t day_index) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->run_daily(day_index);
}

bool DCWorldExt::trigger_should_run(int64_t day_index) const {
    return _trigger_runtime != nullptr &&
        runtime_from(_trigger_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::poll_trigger_effects(int64_t after_effect_id,
                                             int limit) const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->poll_effects(after_effect_id, limit);
}

Dictionary DCWorldExt::ack_trigger_effects(int64_t up_to_effect_id) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->ack_effects(up_to_effect_id);
}

Dictionary DCWorldExt::handoff_trigger_effects(int limit) {
    if (_trigger_runtime == nullptr || _effect_runtime == nullptr)
        return unavailable();
    return runtime_from(_trigger_runtime)->handoff_effects(
        static_cast<EffectRuntime *>(_effect_runtime),
        static_cast<NativeIdeologyRuntime *>(_ideology_runtime), limit);
}

Dictionary DCWorldExt::set_trigger_enabled(const Dictionary &batch) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->set_enabled(batch);
}

Dictionary DCWorldExt::reconcile_trigger_branch_bindings(const Dictionary &batch) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->reconcile_branch_bindings(batch);
}

Dictionary DCWorldExt::get_trigger_branch_progress(int64_t branch_handle) const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->branch_progress(
            static_cast<uint64_t>(branch_handle));
}

Dictionary DCWorldExt::get_development_progress(int64_t country_handle,
                                                int32_t era_index) const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->development_progress(
            static_cast<uint64_t>(country_handle), era_index);
}

Dictionary DCWorldExt::resync_trigger_source(const Dictionary &snapshot) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->resync_source(snapshot);
}

Dictionary DCWorldExt::get_trigger_report() const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->report();
}

PackedByteArray DCWorldExt::capture_trigger_state() const {
    return _trigger_runtime == nullptr ? PackedByteArray()
        : runtime_from(_trigger_runtime)->capture();
}

Dictionary DCWorldExt::restore_trigger_state(const PackedByteArray &bytes) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_trigger_state() {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->clear_state();
}

} // namespace pk
