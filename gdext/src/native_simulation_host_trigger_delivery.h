#pragma once

#include <cstdint>
#include <functional>
#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

class TriggerRuntime;
class NativeCountryRuntime;
class EffectRuntime;

godot::Dictionary reconcile_trigger_research(TriggerRuntime &trigger,
    const NativeCountryRuntime &country, const EffectRuntime *effect_runtime,
    int limit, const std::function<godot::Dictionary(int32_t, int64_t, int32_t, int64_t)> &submit);

} // namespace pk
