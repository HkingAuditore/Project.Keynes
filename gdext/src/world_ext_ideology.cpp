#include "world_ext.h"

#include "country_runtime.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"

namespace pk {
using namespace godot;

namespace {
NativeIdeologyRuntime *ideology_runtime_from(void *opaque) {
    return static_cast<NativeIdeologyRuntime *>(opaque);
}
const NativeIdeologyRuntime *ideology_runtime_from(const void *opaque) {
    return static_cast<const NativeIdeologyRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "ideology_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_ideologies(const Dictionary &catalog) {
    if (_ideology_runtime == nullptr) _ideology_runtime = new NativeIdeologyRuntime();
    ideology_runtime_from(_ideology_runtime)->attach_country_runtime(
        static_cast<NativeCountryRuntime *>(_country_runtime));
    ideology_runtime_from(_ideology_runtime)->attach_effect_runtime(
        static_cast<EffectRuntime *>(_effect_runtime));
    return ideology_runtime_from(_ideology_runtime)->configure(catalog);
}

Dictionary DCWorldExt::submit_ideology_commands(const Dictionary &batch) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->submit_commands(batch);
}

Dictionary DCWorldExt::run_ideology_daily(int64_t day_index) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->run_daily(day_index);
}

bool DCWorldExt::ideology_should_run(int64_t day_index) const {
    return _ideology_runtime != nullptr &&
        ideology_runtime_from(_ideology_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_ideology_snapshot(int64_t country_handle) const {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->snapshot(country_handle);
}

Dictionary DCWorldExt::explain_ideology(int64_t country_handle, int32_t ideology_id) const {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->explain(country_handle, ideology_id);
}

Dictionary DCWorldExt::get_ideology_report() const {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->report();
}

PackedByteArray DCWorldExt::capture_ideology_state() const {
    return _ideology_runtime == nullptr ? PackedByteArray()
        : ideology_runtime_from(_ideology_runtime)->capture();
}

Dictionary DCWorldExt::restore_ideology_state(const PackedByteArray &bytes) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_ideology_state() {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->clear_state();
}

} // namespace pk
