#pragma once
#include <algorithm>
#include <cstdint>

namespace pk {

// The one place that decides "how strong is this Modifier row".
//
// Why a shared header: the main thread applies the per-instance multiplier when
// it turns a program command into a modifier row (dispatch_native_modifier),
// and the EFFECT worker applies the same multiplier when it plans its own rows.
// Under worker authority the main-thread path is suppressed entirely, so the
// worker copy is the only one that runs -- two copies of the clamp would drift
// the moment either ceiling moved, and the drift would show up as a magnitude
// that depends on which side owns the domain.
//
// This header deliberately carries no Godot type and no dependency on
// ModifierRuntime, because the worker translation units may not include the
// main-thread modifier header.

constexpr int32_t EFFECT_MAGNITUDE_Q16_ONE = 65536;
// 4x. Mirrors ModifierRuntime::MAX_MAGNITUDE_Q16, which now aliases this.
constexpr int32_t EFFECT_MAX_MAGNITUDE_Q16 = EFFECT_MAGNITUDE_Q16_ONE * 4;

// `value` is clamped to [0, MAX] exactly as the pre-scale path was, and a scale
// of 1.0 takes the same branch it always did, so every pre-L3-9 caller keeps
// bit-identical behaviour.
inline int32_t effect_scaled_magnitude_q16(int64_t value, int32_t scale_q16) {
    if (scale_q16 == EFFECT_MAGNITUDE_Q16_ONE) {
        return static_cast<int32_t>(std::clamp<int64_t>(
            value, 0, EFFECT_MAX_MAGNITUDE_Q16));
    }
    return static_cast<int32_t>(std::clamp<int64_t>(
        value * static_cast<int64_t>(scale_q16) / EFFECT_MAGNITUDE_Q16_ONE, 0,
        EFFECT_MAX_MAGNITUDE_Q16));
}

} // namespace pk
