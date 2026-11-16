#include "ideology_support_incidence.h"

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "runtime_ideology_pod.h"

namespace pk {
namespace ideology_incidence {
using namespace godot;

namespace {
// A card cannot move more than 100% of a channel, and the channel space is the
// Economy prefix plus one slot per need. Both bounds exist so a malformed catalog
// is a named rejection instead of a runaway multiply.
constexpr int32_t kMaxChannelCount = 128;
constexpr int32_t kMaxGainQ16 = 40 * kQ16One;

// Same typed read the main runtime uses: Dictionary::get returns a Variant and a
// packed array has no implicit conversion from it.
PackedInt32Array i32s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt32Array());
    return value.get_type() == Variant::PACKED_INT32_ARRAY
        ? static_cast<PackedInt32Array>(value) : PackedInt32Array();
}
PackedByteArray u8s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedByteArray());
    return value.get_type() == Variant::PACKED_BYTE_ARRAY
        ? static_cast<PackedByteArray>(value) : PackedByteArray();
}

// Local copies of the runtime's saturating helpers: this file must not depend on
// ideology_runtime.cpp's statics, and the worker build does not have them.
int64_t add_sat(int64_t a, int64_t b) {
    if (b > 0 && a > INT64_MAX - b) return INT64_MAX;
    if (b < 0 && a < INT64_MIN - b) return INT64_MIN;
    return a + b;
}
int64_t mul_sat(int64_t a, int64_t b) {
    if (a == 0 || b == 0) return 0;
    if (a > 0) {
        if (b > 0 && a > INT64_MAX / b) return INT64_MAX;
        if (b < 0 && b < INT64_MIN / a) return INT64_MIN;
    } else {
        if (b > 0 && a < INT64_MIN / b) return INT64_MIN;
        if (b < 0 && a < INT64_MAX / b) return INT64_MAX;
    }
    return a * b;
}
}  // namespace

bool support_allows_material(
        const IdeologyIncidenceTable &table,
        const RuntimeIdeologyOpinionSnapshot &opinion, uint32_t country_slot,
        uint32_t class_count, uint32_t level, int32_t threshold_q16,
        int32_t owner_influence_weight, int64_t funds_per_influence) {
    const int32_t channels = table.channel_count;
    const int32_t *delta = table.level_delta(static_cast<int32_t>(level));
    const size_t row_begin = static_cast<size_t>(country_slot) *
        static_cast<size_t>(class_count);
    // The snapshot carries no incidence table: "not measured", so the gate is off.
    // Same rule as the main runtime; a mismatched NON-ZERO count still fails.
    if (opinion.incidence_channel_count <= 0) return true;
    // Same rule for a country with no measurable income yet.
    if (country_slot < opinion.incidence_measured.size() &&
        opinion.incidence_measured[country_slot] == 0) return true;
    if (delta == nullptr || channels <= 0 || class_count == 0 ||
        opinion.incidence_channel_count != channels ||
        country_slot >= opinion.incidence_measured.size() ||
        opinion.incidence_measured[country_slot] == 0 ||
        opinion.class_incidence_q16.size() <
            (row_begin + static_cast<size_t>(class_count)) *
                static_cast<size_t>(channels))
        return false;
    // Same two passes as the main runtime: influence first (the veto needs the
    // total), then the weighted stance.
    int64_t total = 0;
    for (uint32_t class_index = 0; class_index < class_count; ++class_index) {
        const size_t lane = row_begin + static_cast<size_t>(class_index);
        int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
        influence = add_sat(influence, mul_sat(std::max<int64_t>(0,
            opinion.owner_employed[lane]), owner_influence_weight));
        influence = add_sat(influence, std::max<int64_t>(0,
            opinion.funds[lane]) / funds_per_influence);
        total = add_sat(total, std::max<int64_t>(0, influence));
    }
    if (total <= 0) return false;
    int64_t weighted = 0;
    for (uint32_t class_index = 0; class_index < class_count; ++class_index) {
        const size_t lane = row_begin + static_cast<size_t>(class_index);
        int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
        influence = add_sat(influence, mul_sat(std::max<int64_t>(0,
            opinion.owner_employed[lane]), owner_influence_weight));
        influence = add_sat(influence, std::max<int64_t>(0,
            opinion.funds[lane]) / funds_per_influence);
        influence = std::max<int64_t>(0, influence);
        const int32_t *shares = &opinion.class_incidence_q16[
            (row_begin + static_cast<size_t>(class_index)) *
                static_cast<size_t>(channels)];
        const int32_t delta_u = material_delta_q16(shares, delta, channels);
        const int32_t stance_q16 = stance_from_delta_q16(delta_u, table.gain_q16);
        weighted = add_sat(weighted, mul_sat(influence, stance_q16));
        if (class_vetoes(delta_u, influence, total, table.veto_q16,
                         table.veto_min_influence_q16))
            return false;
    }
    const int64_t support = std::clamp<int64_t>(weighted / total,
        -kQ16One, kQ16One);
    return support >= table.scaled_threshold(threshold_q16);
}

bool configure_table(const Dictionary &catalog, IdeologyIncidenceTable &out,
                     std::string &error) {
    out = IdeologyIncidenceTable{};
    out.model = static_cast<int32_t>(int(catalog.get("support_model", 1)));
    // The authored-stance model is retired: it measured "what the author thinks
    // this class wants" rather than "what this card does to this class". A stale
    // profile that still asks for it must fail loudly instead of silently
    // shipping material numbers under the old name.
    if (out.model != SUPPORT_MODEL_MATERIAL) {
        error = "ideology_support_model_retired";
        return false;
    }
    out.gain_q16 = static_cast<int32_t>(
        int(catalog.get("incidence_gain_q16", kDefaultGainQ16)));
    if (out.gain_q16 < 0 || out.gain_q16 > kMaxGainQ16) {
        error = "ideology_support_gain_invalid";
        return false;
    }
    out.veto_q16 = static_cast<int32_t>(
        int(catalog.get("incidence_veto_q16", kDefaultVetoQ16)));
    if (out.veto_q16 > 0 || out.veto_q16 < -kQ16One) {
        error = "ideology_support_veto_invalid";
        return false;
    }
    out.veto_min_influence_q16 = static_cast<int32_t>(
        int(catalog.get("incidence_veto_min_influence_q16",
            kDefaultVetoMinInfluenceQ16)));
    if (out.veto_min_influence_q16 < 0 ||
        out.veto_min_influence_q16 > kQ16One) {
        error = "ideology_support_veto_share_invalid";
        return false;
    }
    out.threshold_scale_q16 = static_cast<int32_t>(
        int(catalog.get("incidence_threshold_scale_q16", kQ16One)));
    if (out.threshold_scale_q16 <= 0 || out.threshold_scale_q16 > 4 * kQ16One) {
        error = "ideology_support_threshold_scale_invalid";
        return false;
    }
    // TEST HOOK: a fixture that is not about the gate configures the catalog with
    // the gate disabled, which is exactly the "no model" state below.
    if (!bool(catalog.get("support_gate_enabled", true))) {
        out.channel_count = 0;
        out.level_count = 0;
        out.level_channels_q16.clear();
        out.level_measured.clear();
        return true;
    }
    out.channel_count = static_cast<int32_t>(
        int(catalog.get("incidence_channel_count", 0)));
    if (out.channel_count < 0 || out.channel_count > kMaxChannelCount) {
        error = "ideology_incidence_channel_count_invalid";
        return false;
    }
    // level_offsets is the CARD -> level CSR, so its last entry is the total level
    // count, not size() - 1 (which would be the card count).
    const PackedInt32Array level_offsets = i32s(catalog, "level_offsets");
    out.level_count = level_offsets.size() > 0
        ? level_offsets[level_offsets.size() - 1] : 0;
    const PackedInt32Array channels = i32s(catalog, "incidence_level_channels_q16");
    if (out.channel_count == 0) {
        if (!channels.is_empty()) {
            error = "ideology_incidence_rows_without_channels";
            return false;
        }
        out.level_channels_q16.clear();
        return true;
    }
    if (out.level_count <= 0) {
        error = "ideology_incidence_levels_missing";
        return false;
    }
    const int64_t expected = static_cast<int64_t>(out.level_count) *
        static_cast<int64_t>(out.channel_count);
    if (static_cast<int64_t>(channels.size()) != expected) {
        error = "ideology_incidence_row_shape_invalid";
        return false;
    }
    out.level_channels_q16.resize(static_cast<size_t>(expected));
    for (int64_t index = 0; index < expected; ++index) {
        const int32_t delta = channels[static_cast<int32_t>(index)];
        if (delta < -kQ16One || delta > kQ16One) {
            error = "ideology_incidence_delta_out_of_range";
            return false;
        }
        out.level_channels_q16[static_cast<size_t>(index)] = delta;
    }
    // Optional per-level "has any effect" flags. Absent means "assume measured",
    // which is what a catalog compiled before the flags existed means.
    const PackedByteArray measured = u8s(catalog, "incidence_level_measured");
    out.level_measured.clear();
    if (!measured.is_empty()) {
        if (measured.size() != out.level_count) {
            error = "ideology_incidence_measured_shape_invalid";
            return false;
        }
        out.level_measured.resize(static_cast<size_t>(measured.size()));
        for (int32_t i = 0; i < measured.size(); ++i) {
            const int32_t value = static_cast<int32_t>(measured[i]);
            if (value < 0 || value > 1) {
                error = "ideology_incidence_measured_value_invalid";
                return false;
            }
            out.level_measured[static_cast<size_t>(i)] =
                static_cast<uint8_t>(value);
        }
    }
    return true;
}

}  // namespace ideology_incidence
}  // namespace pk
