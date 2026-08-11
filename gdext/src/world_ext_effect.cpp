#include "world_ext.h"

#include "effect_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"

namespace pk {

using namespace godot;

namespace {
EffectRuntime *runtime_from(void *opaque) {
    return static_cast<EffectRuntime *>(opaque);
}
const EffectRuntime *runtime_from(const void *opaque) {
    return static_cast<const EffectRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "effect_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_effects(const Dictionary &catalog) {
    if (_effect_runtime == nullptr) _effect_runtime = new EffectRuntime();
    Dictionary result = runtime_from(_effect_runtime)->configure(catalog);
    if (bool(result.get("ok", false))) {
        if (_country_runtime != nullptr) {
            runtime_from(_effect_runtime)->attach_country_runtime(
                static_cast<NativeCountryRuntime *>(_country_runtime));
            static_cast<NativeCountryRuntime *>(_country_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
        }
        if (_economy_runtime != nullptr)
            static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
        // Country runtime is configured before EffectRuntime during normal
        // startup, and ideology is intentionally configured with the country
        // catalog at that same early boundary.  Keep the peer link symmetric:
        // otherwise NativeIdeologyRuntime retains a null EffectRuntime when
        // EffectRuntime is configured later, so its first equip/upgrade is
        // rejected despite both runtimes being healthy.
        if (_ideology_runtime != nullptr)
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
    }
    return result;
}

Dictionary DCWorldExt::bind_era_reward_player_country(int64_t country_handle) {
    if (_effect_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = runtime_from(_effect_runtime)
        ->bind_era_reward_player_country_pod(
            static_cast<uint64_t>(country_handle), error);
    Dictionary out;
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::get_era_reward_offer() {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->era_reward_offer_snapshot();
}

Dictionary DCWorldExt::choose_era_reward(int64_t offer_generation,
                                         int choice_index,
                                         int64_t effective_day) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->choose_era_reward(
            offer_generation, choice_index, effective_day);
}

Dictionary DCWorldExt::submit_effect_instances(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->submit_instances(batch);
}

Dictionary DCWorldExt::retire_effect_instance(int64_t instance_id,
                                              int64_t generation,
                                              int64_t effective_day) {
    if (_effect_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = generation > 0 && runtime_from(_effect_runtime)->retire_instance_pod(
        instance_id, static_cast<uint32_t>(generation), effective_day, error);
    Dictionary out;
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

bool DCWorldExt::effect_instance_fire_acked(int64_t instance_id,
                                            int64_t generation) const {
    return _effect_runtime != nullptr && generation > 0 &&
        runtime_from(_effect_runtime)->instance_fire_acked_pod(
            instance_id, static_cast<uint32_t>(generation));
}

Dictionary DCWorldExt::submit_effect_snapshots(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->submit_snapshots(batch);
}

Dictionary DCWorldExt::run_effect_daily(int64_t day_index) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->run_daily(day_index);
}

Dictionary DCWorldExt::dispatch_effect_native_modifier() {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_modifier(
        static_cast<ModifierRuntime *>(_modifier_runtime));
}

Dictionary DCWorldExt::ack_effect_native_modifier() {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_modifier(
        static_cast<ModifierRuntime *>(_modifier_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_country() {
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_country(
        static_cast<NativeCountryRuntime *>(_country_runtime));
}

Dictionary DCWorldExt::ack_effect_native_country() {
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_country(
        static_cast<NativeCountryRuntime *>(_country_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_economy() {
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_economy(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

Dictionary DCWorldExt::ack_effect_native_economy() {
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_economy(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_gameplay() {
    if (_effect_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_gameplay(this);
}

Dictionary DCWorldExt::ack_effect_native_gameplay() {
    if (_effect_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_gameplay(this);
}

Dictionary DCWorldExt::get_effect_native_adapter_report() const {
    Dictionary out;
    const bool country_pending = _country_runtime != nullptr &&
        static_cast<const NativeCountryRuntime *>(_country_runtime)
            ->has_pending_effect_commands();
    const bool economy_pending = _economy_runtime != nullptr &&
        static_cast<const NativeEconomyRuntime *>(_economy_runtime)
            ->has_pending_effect_commands();
    const bool gameplay_pending = !_effect_gameplay_commands.empty();
    out["country_pending"] = country_pending;
    out["economy_pending"] = economy_pending;
    out["gameplay_pending"] = gameplay_pending;
    out["country_pending_count"] = country_pending ? 1 : 0;
    out["economy_pending_count"] = economy_pending ? 1 : 0;
    out["gameplay_pending_count"] = static_cast<int64_t>(
        _effect_gameplay_commands.size());
    out["idle"] = !country_pending && !economy_pending && !gameplay_pending;
    return out;
}

bool DCWorldExt::effect_should_run(int64_t day_index) const {
    return _effect_runtime != nullptr &&
        runtime_from(_effect_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::poll_effect_transactions(int64_t after_transaction_id,
                                                int limit) const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->poll_transactions(after_transaction_id, limit);
}

Dictionary DCWorldExt::preflight_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->preflight_transactions(batch);
}

Dictionary DCWorldExt::commit_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->commit_transactions(batch);
}

Dictionary DCWorldExt::ack_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->ack_transactions(batch);
}

Dictionary DCWorldExt::explain_effect(int64_t instance_id) const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->explain(instance_id);
}

Dictionary DCWorldExt::get_effect_report() const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->report();
}

PackedByteArray DCWorldExt::capture_effect_state() const {
    return _effect_runtime == nullptr ? PackedByteArray()
        : runtime_from(_effect_runtime)->capture();
}

Dictionary DCWorldExt::restore_effect_state(const PackedByteArray &bytes) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_effect_state() {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->clear_state();
}

} // namespace pk
