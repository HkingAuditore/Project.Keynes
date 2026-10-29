#include "ideology_runtime.h"
#include <cstdio>
#include <cstdlib>
#include "derived_cell_materializer.h"
#include "effect_selector_cap.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "effect_runtime.h"
#include "effect_instance_forwarder.h"
#include "ideology_opinion_bridge.h"
// Authority-aware instance queries: the ideology report and the ideology restore
// both ask whether an instance still exists / has fired.
#include "economy_effect_forward.h"
#include "modifier_runtime.h"
#include "runtime_effect_pod.h"
#include "runtime_ideology_draw_kernel.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace pk {
using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x44494b50U; // PKID
constexpr uint32_t SAVE_END = 0x21444e45U;

// ── plan §11.5: the execution-contract version vector ───────────────────────
//
// One constant per rule the plan names. The hash over these is what makes an old save
// REFUSED when execution semantics move (`cell_program_execution_contract_mismatch`)
// instead of being silently reinterpreted under different rules.
//
// BUMP THE MATCHING CONSTANT WHEN THE RULE CHANGES. That is the entire contract: a rule
// change without a bump lets an old archive load under rules it was not written for.
constexpr int32_t kExecutionSemanticsVersion = 1;  // the vector itself changed shape
constexpr int32_t kProgramBackendVersion = 1;      // which programs are derived vs instance
constexpr int32_t kSelectorUnboundedVersion = 1;   // the 32-cap removal semantics
constexpr int32_t kSourceCountDecodeVersion = 1;   // kind-16 low-five-bit source count
constexpr int32_t kEvaluatorVersion = 1;           // magnitude / merge / rounding rules
// A copier card (copy_left_programs) at level >= 2 scales the programs it copies by
// 1.2x. ONE definition, used by BOTH backends, because I01 says a program's behaviour
// must not depend on which backend took it -- an earlier version spelled 78643 inline in
// the instance branch only, so a derived copier silently dropped its level-2 bonus.
constexpr int32_t kCopierLevelTwoScaleQ16 = 78643;  // 1.2 * 65536
constexpr int32_t kEligibilityVersion = 1;         // §9.3: eligible_from_day = D + 1
constexpr int32_t MAX_IDEOLOGIES = 65536;
constexpr int32_t MAX_LEVELS = 1000000;
constexpr int32_t MAX_GATES = 65536;
constexpr int64_t TRADE_MONEY_SCALE = 10000;
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &started) {
    return std::chrono::duration<double, std::milli>(Clock::now() - started).count();
}

constexpr auto command_less = [](const auto &a, const auto &b) {
    return std::tie(a.effective_day, a.source_priority, a.producer_id,
                    a.sequence, a.submit_order) <
        std::tie(b.effective_day, b.source_priority, b.producer_id,
                 b.sequence, b.submit_order);
};

template <typename T> void append_le(std::vector<uint8_t> &out, T value) {
    const auto *ptr = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), ptr, ptr + sizeof(T));
}
template <typename T> bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > size) return false;
    std::memcpy(&value, data + cursor, sizeof(T)); cursor += sizeof(T); return true;
}
template <typename T> void append_vec(std::vector<uint8_t> &out, const std::vector<T> &items) {
    append_le<uint64_t>(out, static_cast<uint64_t>(items.size()));
    if (!items.empty()) {
        const auto *ptr = reinterpret_cast<const uint8_t *>(items.data());
        out.insert(out.end(), ptr, ptr + sizeof(T) * items.size());
    }
}
template <typename T> bool read_vec(const uint8_t *data, size_t size, size_t &cursor,
                                    std::vector<T> &items, uint64_t limit) {
    uint64_t count = 0;
    if (!read_le(data, size, cursor, count) || count > limit ||
        count > (size - cursor) / sizeof(T)) return false;
    items.resize(static_cast<size_t>(count));
    if (count != 0) std::memcpy(items.data(), data + cursor, sizeof(T) * count);
    cursor += sizeof(T) * static_cast<size_t>(count); return true;
}
// Length-prefixed string. Used by the applied-basis rows (plan §18.2), whose two
// string fields are the only variable-length members of a row.
void append_string(std::vector<uint8_t> &out, const std::string &text) {
    append_le<uint32_t>(out, static_cast<uint32_t>(text.size()));
    if (!text.empty())
        out.insert(out.end(), text.begin(), text.end());
}
bool read_string(const uint8_t *data, size_t size, size_t &cursor,
                 std::string &text, uint32_t limit) {
    text.clear();
    uint32_t length = 0;
    if (!read_le(data, size, cursor, length) || length > limit ||
            length > size - cursor) return false;
    text.assign(reinterpret_cast<const char *>(data + cursor),
                static_cast<size_t>(length));
    cursor += static_cast<size_t>(length);
    return true;
}
// 1e-6 quantisation for the applied-basis terms digest. Mirrors
// `DerivedCellFront::content_digest` (derived_cell_layer.h): a digest over raw
// double bits would refuse a save for a last-bit difference no fold can observe.
int64_t basis_quantise(double value) {
    if (!std::isfinite(value)) return 0;
    return static_cast<int64_t>(std::llround(value * 1000000.0));
}
PackedInt32Array i32s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt32Array());
    return value.get_type() == Variant::PACKED_INT32_ARRAY ? static_cast<PackedInt32Array>(value) : PackedInt32Array();
}
PackedInt64Array i64s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt64Array());
    return value.get_type() == Variant::PACKED_INT64_ARRAY ? static_cast<PackedInt64Array>(value) : PackedInt64Array();
}
PackedByteArray u8s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedByteArray());
    return value.get_type() == Variant::PACKED_BYTE_ARRAY ? static_cast<PackedByteArray>(value) : PackedByteArray();
}
PackedStringArray strings(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedStringArray());
    return value.get_type() == Variant::PACKED_STRING_ARRAY ? static_cast<PackedStringArray>(value) : PackedStringArray();
}
Dictionary fail(const std::string &reason) { Dictionary out; out["ok"] = false; out["reason"] = String(reason.c_str()); return out; }
uint64_t mix(uint64_t h, const void *data, size_t n) { const auto *p = static_cast<const uint8_t *>(data); for (size_t i=0;i<n;++i) { h ^= p[i]; h *= 1099511628211ULL; } return h; }
template <typename T> uint64_t mixv(uint64_t h, T value) { return mix(h, &value, sizeof(T)); }
int32_t popcount64(uint64_t value) {
    int32_t count = 0;
    while (value != 0) {
        value &= value - 1;
        ++count;
    }
    return count;
}
uint64_t splitmix64(uint64_t &state) { uint64_t z = (state += 0x9e3779b97f4a7c15ULL); z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL; z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL; return z ^ (z >> 31U); }
// The identity of an Effect program as carried by EffectInstanceRef. One
// definition because two call sites hash it: the reconciler that stamps the ref
// and the report that labels it with a domain. A second copy would be a silent
// divergence the moment either side is touched.
uint64_t effect_program_hash(const std::string &program) {
    return mix(1469598103934665603ULL, program.data(), program.size());
}
// Digest of "which columns this instance conditions on, and what they read".
// Deliberately excludes the day and the revision: two reconciles that see the
// same world have to produce the same digest, otherwise the publish gate in
// reconcile_effect_activations() would never close.
uint64_t metric_publish_digest(const MetricMask &mask,
                               const std::vector<int64_t> &values) {
    uint64_t digest = 1469598103934665603ULL;
    for (int32_t word = 0; word < MetricMask::WORD_COUNT; ++word)
        digest = mixv(digest, mask.word(word));
    const int32_t count = static_cast<int32_t>(values.size()) < MetricMask::CAPACITY
        ? static_cast<int32_t>(values.size()) : MetricMask::CAPACITY;
    for (int32_t id = 0; id < count; ++id) {
        if (!mask.test(id)) continue;
        digest = mixv(digest, values[static_cast<size_t>(id)]);
    }
    return digest;
}
int64_t add_sat(int64_t a, int64_t b) { if (b > 0 && a > std::numeric_limits<int64_t>::max() - b) return std::numeric_limits<int64_t>::max(); if (b < 0 && a < std::numeric_limits<int64_t>::min() - b) return std::numeric_limits<int64_t>::min(); return a+b; }
int64_t mul_sat(int64_t a, int64_t b) {
    if (a == 0 || b == 0) return 0;
    if (a == -1 && b == std::numeric_limits<int64_t>::min())
        return std::numeric_limits<int64_t>::max();
    if (b == -1 && a == std::numeric_limits<int64_t>::min())
        return std::numeric_limits<int64_t>::max();
    if (a > 0) {
        if (b > 0 && a > std::numeric_limits<int64_t>::max() / b)
            return std::numeric_limits<int64_t>::max();
        if (b < 0 && b < std::numeric_limits<int64_t>::min() / a)
            return std::numeric_limits<int64_t>::min();
    } else {
        if (b > 0 && a < std::numeric_limits<int64_t>::min() / b)
            return std::numeric_limits<int64_t>::min();
        if (b < 0 && a < std::numeric_limits<int64_t>::max() / b)
            return std::numeric_limits<int64_t>::max();
    }
    return a * b;
}
}

bool NativeIdeologyRuntime::validate_catalog(const Dictionary &catalog, std::string &error) {
    if (int32_t(catalog.get("protocol_version", PROTOCOL_VERSION)) != PROTOCOL_VERSION) { error = "ideology_protocol_version_invalid"; return false; }
    const PackedStringArray ids = strings(catalog, "ideology_ids");
    const int32_t count = ids.size();
    if (count > MAX_IDEOLOGIES) { error = "ideology_definition_count_invalid"; return false; }
    const PackedByteArray acquisition = u8s(catalog, "acquisition_flags");
    const PackedInt32Array weights = i32s(catalog, "rarity_weights");
    const PackedInt32Array ideology_costs = i32s(catalog, "ideology_slot_costs");
    const PackedInt32Array spirit_costs = i32s(catalog, "spirit_slot_costs");
    const PackedInt32Array spirit_levels = i32s(catalog, "national_spirit_min_levels");
    const PackedInt32Array level_offsets = i32s(catalog, "level_offsets");
    const PackedInt64Array thresholds = i64s(catalog, "level_thresholds_q16");
    const PackedInt64Array daily = i64s(catalog, "level_daily_understanding_q16");
    const PackedInt32Array persistent_offsets = i32s(catalog, "level_persistent_offsets");
    const PackedInt32Array persistent_actions = i32s(catalog, "persistent_actions");
    const PackedInt32Array persistent_domains = i32s(catalog, "persistent_domains");
    const PackedInt32Array persistent_opcodes = i32s(catalog, "persistent_opcodes");
    const PackedInt64Array persistent_values = i64s(catalog, "persistent_values_q16");
    const PackedInt32Array persistent_durations = i32s(catalog, "persistent_duration_days");
    const PackedInt32Array persistent_stacks = i32s(catalog, "persistent_stacks");
    const PackedStringArray persistent_keys = strings(catalog, "persistent_command_keys");
    const PackedStringArray persistent_definitions = strings(catalog, "persistent_definition_keys");
    const PackedInt64Array persistent_i0 = i64s(catalog, "persistent_payload_i0");
    const PackedInt64Array persistent_i1 = i64s(catalog, "persistent_payload_i1");
    const PackedInt64Array persistent_i2 = i64s(catalog, "persistent_payload_i2");
    const PackedInt64Array persistent_i3 = i64s(catalog, "persistent_payload_i3");
    const PackedInt32Array enter_offsets = i32s(catalog, "level_on_enter_offsets");
    const PackedInt32Array enter_actions = i32s(catalog, "on_enter_actions");
    const PackedInt32Array enter_domains = i32s(catalog, "on_enter_domains");
    const PackedInt32Array enter_opcodes = i32s(catalog, "on_enter_opcodes");
    const PackedInt64Array enter_values = i64s(catalog, "on_enter_values_q16");
    const PackedInt32Array enter_durations = i32s(catalog, "on_enter_duration_days");
    const PackedInt32Array enter_stacks = i32s(catalog, "on_enter_stacks");
    const PackedStringArray enter_keys = strings(catalog, "on_enter_command_keys");
    const PackedStringArray enter_definitions = strings(catalog, "on_enter_definition_keys");
    const PackedInt64Array enter_i0 = i64s(catalog, "on_enter_payload_i0");
    const PackedInt64Array enter_i1 = i64s(catalog, "on_enter_payload_i1");
    const PackedInt64Array enter_i2 = i64s(catalog, "on_enter_payload_i2");
    const PackedInt64Array enter_i3 = i64s(catalog, "on_enter_payload_i3");
    const PackedInt32Array tech_offsets = i32s(catalog, "technology_requirement_offsets");
    const PackedInt32Array tech = i32s(catalog, "technology_requirements");
    const PackedInt32Array signal_offsets = i32s(catalog, "signal_requirement_offsets");
    const PackedInt32Array signals = i32s(catalog, "signal_requirements");
    const PackedInt32Array gate_offsets = i32s(catalog, "gate_requirement_offsets");
    const PackedInt32Array gates = i32s(catalog, "gate_requirements");
    const PackedInt32Array era_indices = i32s(catalog, "ideology_era_indices");
    const PackedInt32Array era_decay_bp = i32s(catalog, "era_decay_bp");
    const PackedInt32Array era_milestones =
        i32s(catalog, "ideology_era_milestone_technologies");
    const PackedByteArray copy_left_programs =
        u8s(catalog, "ideology_copy_left_programs");
    const PackedByteArray copyable = u8s(catalog, "ideology_copyable");
    const PackedInt32Array school_indices =
        i32s(catalog, "ideology_school_indices");
    const PackedStringArray school_keys =
        strings(catalog, "ideology_school_keys");
    const PackedStringArray school_strength_keys =
        strings(catalog, "school_strength_factor_stat_keys");
    const PackedStringArray gate_keys = strings(catalog, "gate_keys");
    const PackedStringArray political_class_ids =
        strings(catalog, "political_class_ids");
    const PackedInt32Array stance_offsets = i32s(catalog, "stance_offsets");
    const PackedInt32Array stance_classes =
        i32s(catalog, "stance_class_indices");
    const PackedInt32Array stance_adopt = i32s(catalog, "stance_adopt_q16");
    const PackedInt32Array stance_repeal = i32s(catalog, "stance_repeal_q16");
    const PackedInt32Array stance_promote = i32s(catalog, "stance_promote_q16");
    const PackedInt32Array stance_adopt_min =
        i32s(catalog, "stance_adopt_min_q16");
    const PackedInt32Array stance_repeal_min =
        i32s(catalog, "stance_repeal_min_q16");
    const PackedInt32Array stance_promote_min =
        i32s(catalog, "stance_promote_min_q16");
    const PackedInt32Array adopt_thresholds =
        i32s(catalog, "adopt_thresholds_q16");
    const PackedInt32Array repeal_thresholds =
        i32s(catalog, "repeal_thresholds_q16");
    const PackedInt32Array promote_thresholds =
        i32s(catalog, "promote_thresholds_q16");
    const PackedInt32Array exclusion_groups =
        i32s(catalog, "exclusion_group_ids");
    const PackedStringArray route_keys = strings(catalog, "route_keys");
    const PackedInt32Array route_masks =
        i32s(catalog, "ideology_route_masks");
    const PackedInt32Array synergy_requirement_offsets =
        i32s(catalog, "synergy_requirement_offsets");
    const PackedInt32Array synergy_requirement_ideologies =
        i32s(catalog, "synergy_requirement_ideology_ids");
    const PackedInt32Array synergy_requirement_levels =
        i32s(catalog, "synergy_requirement_min_levels");
    const PackedByteArray synergy_requirement_locations =
        u8s(catalog, "synergy_requirement_location_masks");
    const PackedInt32Array synergy_effect_offsets =
        i32s(catalog, "synergy_effect_offsets");
    const PackedInt32Array synergy_actions =
        i32s(catalog, "synergy_effect_actions");
    const PackedInt32Array synergy_domains =
        i32s(catalog, "synergy_effect_domains");
    const PackedInt32Array synergy_opcodes =
        i32s(catalog, "synergy_effect_opcodes");
    const PackedInt64Array synergy_values =
        i64s(catalog, "synergy_effect_values_q16");
    const PackedInt32Array synergy_durations =
        i32s(catalog, "synergy_effect_duration_days");
    const PackedInt32Array synergy_stacks =
        i32s(catalog, "synergy_effect_stacks");
    const PackedStringArray synergy_keys =
        strings(catalog, "synergy_effect_command_keys");
    const PackedStringArray synergy_definitions =
        strings(catalog, "synergy_effect_definition_keys");
    const PackedInt64Array synergy_i0 =
        i64s(catalog, "synergy_effect_payload_i0");
    const PackedInt64Array synergy_i1 =
        i64s(catalog, "synergy_effect_payload_i1");
    const PackedInt64Array synergy_i2 =
        i64s(catalog, "synergy_effect_payload_i2");
    const PackedInt64Array synergy_i3 =
        i64s(catalog, "synergy_effect_payload_i3");
    const PackedStringArray synergy_ids = strings(catalog, "synergy_ids");
    const PackedInt32Array ideology_synergy_offsets =
        i32s(catalog, "ideology_synergy_offsets");
    const PackedInt32Array ideology_synergy_ids =
        i32s(catalog, "ideology_synergy_ids");
    const PackedInt32Array synergy_min_counts =
        i32s(catalog, "synergy_min_counts");
    // L3-9 synergy magnitude overrides. All three columns are optional as a set;
    // a catalog that predates them has none and behaves exactly as before.
    const PackedInt32Array synergy_override_offsets =
        i32s(catalog, "synergy_override_offsets");
    const PackedStringArray synergy_override_programs =
        strings(catalog, "synergy_override_programs");
    const PackedInt32Array synergy_override_scales =
        i32s(catalog, "synergy_override_scales");
    const PackedInt32Array synergy_override_match_kinds =
        i32s(catalog, "synergy_override_match_kinds");
    const PackedStringArray synergy_override_match_values =
        strings(catalog, "synergy_override_match_values");
    const PackedInt32Array synergy_override_fields =
        i32s(catalog, "synergy_override_fields");
    const PackedInt32Array synergy_override_values =
        i32s(catalog, "synergy_override_values");
    const PackedStringArray synergy_override_tag_names =
        strings(catalog, "synergy_override_tag_names");
    const PackedInt32Array unlock_technologies =
        i32s(catalog, "capacity_unlock_technology_ids");
    const PackedInt32Array unlock_ideology =
        i32s(catalog, "capacity_unlock_ideology_deltas");
    const PackedInt32Array unlock_spirit =
        i32s(catalog, "capacity_unlock_spirit_deltas");
    const auto persistent_count = persistent_actions.size();
    const auto enter_count = enter_actions.size();
    const int32_t stance_count = stance_classes.size();
    const int32_t synergy_count = synergy_ids.size();
    const int32_t synergy_effect_count = synergy_actions.size();
    if (acquisition.size()!=count || weights.size()!=count || ideology_costs.size()!=count || spirit_costs.size()!=count || spirit_levels.size()!=count || level_offsets.size()!=count+1 || tech_offsets.size()!=count+1 || signal_offsets.size()!=count+1 || gate_offsets.size()!=count+1 || thresholds.size()!=daily.size() || thresholds.size()>MAX_LEVELS || persistent_offsets.size()!=thresholds.size()+1 || enter_offsets.size()!=thresholds.size()+1 || persistent_domains.size()!=persistent_count || persistent_opcodes.size()!=persistent_count || persistent_values.size()!=persistent_count || persistent_durations.size()!=persistent_count || persistent_stacks.size()!=persistent_count || persistent_keys.size()!=persistent_count || persistent_definitions.size()!=persistent_count || persistent_i0.size()!=persistent_count || persistent_i1.size()!=persistent_count || persistent_i2.size()!=persistent_count || persistent_i3.size()!=persistent_count || enter_domains.size()!=enter_count || enter_opcodes.size()!=enter_count || enter_values.size()!=enter_count || enter_durations.size()!=enter_count || enter_stacks.size()!=enter_count || enter_keys.size()!=enter_count || enter_definitions.size()!=enter_count || enter_i0.size()!=enter_count || enter_i1.size()!=enter_count || enter_i2.size()!=enter_count || enter_i3.size()!=enter_count || political_class_ids.is_empty() || stance_offsets.size()!=count+1 || stance_adopt.size()!=stance_count || stance_repeal.size()!=stance_count || stance_promote.size()!=stance_count || stance_adopt_min.size()!=stance_count || stance_repeal_min.size()!=stance_count || stance_promote_min.size()!=stance_count || adopt_thresholds.size()!=count || repeal_thresholds.size()!=count || promote_thresholds.size()!=count || exclusion_groups.size()!=count || synergy_requirement_offsets.size()!=synergy_count+1 || synergy_requirement_ideologies.size()!=synergy_requirement_levels.size() || synergy_requirement_ideologies.size()!=synergy_requirement_locations.size() || synergy_effect_offsets.size()!=synergy_count+1 || synergy_domains.size()!=synergy_effect_count || synergy_opcodes.size()!=synergy_effect_count || synergy_values.size()!=synergy_effect_count || synergy_durations.size()!=synergy_effect_count || synergy_stacks.size()!=synergy_effect_count || synergy_keys.size()!=synergy_effect_count || synergy_definitions.size()!=synergy_effect_count || synergy_i0.size()!=synergy_effect_count || synergy_i1.size()!=synergy_effect_count || synergy_i2.size()!=synergy_effect_count || synergy_i3.size()!=synergy_effect_count || ideology_synergy_offsets.size()!=count+1) { error="ideology_catalog_columns_invalid"; return false; }
    std::unordered_set<std::string> seen;
    int32_t max_gate=-1;
    for (int32_t i=0;i<count;++i) {
        const std::string id = String(ids[i]).utf8().get_data();
        if (id.empty() || !seen.insert(id).second || (acquisition[i] & ~(DISCOVER|DRAW)) != 0 || acquisition[i]==0 || weights[i]<=0 || ideology_costs[i]<=0 || spirit_costs[i]<=0 || spirit_levels[i]<0 || level_offsets[i]<0 || level_offsets[i+1] <= level_offsets[i] || level_offsets[i+1]-level_offsets[i] > 64 || level_offsets[i+1]>thresholds.size() || spirit_levels[i] >= level_offsets[i+1]-level_offsets[i] || tech_offsets[i]<0 || tech_offsets[i+1]<tech_offsets[i] || tech_offsets[i+1]>tech.size() || signal_offsets[i]<0 || signal_offsets[i+1]<signal_offsets[i] || signal_offsets[i+1]>signals.size() || gate_offsets[i]<0 || gate_offsets[i+1]<gate_offsets[i] || gate_offsets[i+1]>gates.size()) { error="ideology_definition_invalid"; return false; }
        int64_t previous=-1;
        for (int32_t row=level_offsets[i];row<level_offsets[i+1];++row) { if (thresholds[row]<0 || thresholds[row]<previous || daily[row]<0) { error="ideology_level_invalid"; return false; } previous=thresholds[row]; }
        for (int32_t row=tech_offsets[i];row<tech_offsets[i+1];++row) if (tech[row]<0) { error="ideology_technology_requirement_invalid"; return false; }
        for (int32_t row=signal_offsets[i];row<signal_offsets[i+1];++row) if (signals[row]<0) { error="ideology_signal_requirement_invalid"; return false; }
        for (int32_t row=gate_offsets[i];row<gate_offsets[i+1];++row) { if (gates[row]<0 || gates[row]>=MAX_GATES) { error="ideology_gate_requirement_invalid"; return false; } max_gate=std::max(max_gate,gates[row]); }
    }
    // Era metadata. A catalog authored before eras existed omits both arrays;
    // that degrades to "no decay" instead of failing, so the same runtime keeps
    // working with old content. Anything present must be well formed.
    if (!era_indices.is_empty() && era_indices.size() != count) {
        error = "ideology_era_indices_invalid";
        return false;
    }
    // X6-c catalog flags. Arrays are optional for older catalogs; when present
    // they must describe every definition, and a byte outside {0,1} is a typo
    // that would otherwise make a legendary card copyable or a copier silent.
    if ((!copy_left_programs.is_empty() &&
            copy_left_programs.size() != count) ||
            (!copyable.is_empty() && copyable.size() != count)) {
        error = "ideology_copy_flags_invalid";
        return false;
    }
    for (int32_t i = 0; i < copy_left_programs.size(); ++i) {
        if (copy_left_programs[i] > 1) {
            error = "ideology_copy_flags_invalid";
            return false;
        }
    }
    for (int32_t i = 0; i < copyable.size(); ++i) {
        if (copyable[i] > 1) {
            error = "ideology_copy_flags_invalid";
            return false;
        }
    }
    if (route_keys.size() > 31 ||
            (!route_masks.is_empty() && route_masks.size() != count)) {
        error = "ideology_route_table_invalid";
        return false;
    }
    if (route_keys.is_empty()) {
        for (int32_t i = 0; i < route_masks.size(); ++i) {
            if (route_masks[i] != 0) {
                error = "ideology_route_table_invalid";
                return false;
            }
        }
    }
    if (!school_keys.is_empty()) {
        if (school_keys.size() > 64 || school_indices.size() != count ||
                school_strength_keys.size() != school_keys.size()) {
            error = "ideology_school_strength_contract_invalid";
            return false;
        }
        std::unordered_set<std::string> seen_schools;
        std::unordered_set<std::string> seen_strength_stats;
        for (int32_t i = 0; i < school_keys.size(); ++i) {
            const std::string school =
                String(school_keys[i]).utf8().get_data();
            const std::string stat =
                String(school_strength_keys[i]).utf8().get_data();
            if (school.empty() || stat.empty() ||
                    !seen_schools.insert(school).second ||
                    !seen_strength_stats.insert(stat).second) {
                error = "ideology_school_strength_contract_invalid";
                return false;
            }
        }
        for (int32_t i = 0; i < school_indices.size(); ++i) {
            if (school_indices[i] < 0 ||
                    school_indices[i] >= school_keys.size()) {
                error = "ideology_school_index_invalid";
                return false;
            }
        }
    } else if (!school_indices.is_empty() ||
            !school_strength_keys.is_empty()) {
        error = "ideology_school_strength_contract_invalid";
        return false;
    }
    for (int32_t i = 0; i < era_indices.size(); ++i) {
        if (era_indices[i] < 0 || era_indices[i] > MAX_ERA_INDEX) {
            error = "ideology_era_index_invalid";
            return false;
        }
    }
    for (int32_t i = 0; i < era_decay_bp.size(); ++i) {
        if (era_decay_bp[i] < 0 || era_decay_bp[i] > 10000) {
            error = "ideology_era_decay_invalid";
            return false;
        }
    }
    // -1 marks an era without a milestone; anything else must be a real technology.
    // The dense index range is not known until the country catalog is attached, so
    // only the negative bound is checked here.
    for (int32_t i = 0; i < era_milestones.size(); ++i) {
        if (era_milestones[i] < -1) {
            error = "ideology_era_milestone_invalid";
            return false;
        }
    }
    for (int32_t level = 0; level < thresholds.size(); ++level) {
        if (persistent_offsets[level] < 0 || persistent_offsets[level + 1] < persistent_offsets[level] || persistent_offsets[level + 1] > persistent_count || enter_offsets[level] < 0 || enter_offsets[level + 1] < enter_offsets[level] || enter_offsets[level + 1] > enter_count) { error="ideology_effect_offsets_invalid"; return false; }
    }
    auto validate_template = [&](int32_t i, bool persistent) {
        const int32_t action = persistent ? persistent_actions[i] : enter_actions[i];
        const int32_t domain = persistent ? persistent_domains[i] : enter_domains[i];
        const int32_t opcode = persistent ? persistent_opcodes[i] : enter_opcodes[i];
        const int32_t stacks = persistent ? persistent_stacks[i] : enter_stacks[i];
        const std::string key = String(persistent ? persistent_keys[i] : enter_keys[i]).utf8().get_data();
        const std::string definition = String(persistent ? persistent_definitions[i] : enter_definitions[i]).utf8().get_data();
        return action >= EffectRuntime::MODIFIER_COMMAND && action <= EffectRuntime::CUSTOM_DOMAIN_COMMAND && domain >= 0 && domain < 32 && stacks > 0 && !key.empty() && !definition.empty() && (!persistent || (action == EffectRuntime::MODIFIER_COMMAND && domain < 4 && opcode == 1));
    };
    for (int32_t i=0;i<persistent_count;++i) if(!validate_template(i,true)) { error="ideology_persistent_template_invalid"; return false; }
    for (int32_t i=0;i<enter_count;++i) {
        // X6-b registers exactly one new Effect custom-domain opcode (3). The
        // row value is a positive count, not an Ideology opcode.
        if (enter_actions[i] == EffectRuntime::CUSTOM_DOMAIN_COMMAND &&
                enter_domains[i] == 6 &&
                enter_opcodes[i] == 3) {
            if (enter_values[i] <= 0 || enter_values[i] > 65535 ||
                    enter_stacks[i] <= 0 || enter_durations[i] < -1 ||
                    String(enter_keys[i]).is_empty() ||
                    String(enter_definitions[i]).is_empty()) {
                error = "ideology_on_enter_free_draw_invalid";
                return false;
            }
            continue;
        }
        if(!validate_template(i,false)) { error="ideology_on_enter_template_invalid"; return false; }
    }
    std::string previous_class;
    for (int32_t class_index = 0;
            class_index < political_class_ids.size(); ++class_index) {
        const std::string id =
            String(political_class_ids[class_index]).utf8().get_data();
        if (id.empty() || (class_index > 0 && id <= previous_class)) {
            error = "ideology_political_class_order_invalid";
            return false;
        }
        previous_class = id;
    }
    for (int32_t ideology = 0; ideology < count; ++ideology) {
        if (stance_offsets[ideology] < 0 ||
                stance_offsets[ideology + 1] < stance_offsets[ideology] ||
                stance_offsets[ideology + 1] > stance_count ||
                adopt_thresholds[ideology] < -65536 ||
                adopt_thresholds[ideology] > 65536 ||
                repeal_thresholds[ideology] < -65536 ||
                repeal_thresholds[ideology] > 65536 ||
                promote_thresholds[ideology] < -65536 ||
                promote_thresholds[ideology] > 65536 ||
                exclusion_groups[ideology] < -1) {
            error = "ideology_stance_definition_invalid";
            return false;
        }
        int32_t previous_stance_class = -1;
        for (int32_t row = stance_offsets[ideology];
                row < stance_offsets[ideology + 1]; ++row) {
            if (stance_classes[row] <= previous_stance_class ||
                    stance_classes[row] < 0 ||
                    stance_classes[row] >= political_class_ids.size() ||
                    stance_adopt[row] < -65536 ||
                    stance_adopt[row] > 65536 ||
                    stance_repeal[row] < -65536 ||
                    stance_repeal[row] > 65536 ||
                    stance_promote[row] < -65536 ||
                    stance_promote[row] > 65536 ||
                    stance_adopt_min[row] < -65537 ||
                    stance_adopt_min[row] > 65536 ||
                    stance_repeal_min[row] < -65537 ||
                    stance_repeal_min[row] > 65536 ||
                    stance_promote_min[row] < -65537 ||
                    stance_promote_min[row] > 65536) {
                error = "ideology_stance_row_invalid";
                return false;
            }
            previous_stance_class = stance_classes[row];
        }
    }
    for (int32_t synergy = 0; synergy < synergy_count; ++synergy) {
        if (synergy_requirement_offsets[synergy] < 0 ||
                synergy_requirement_offsets[synergy + 1] <=
                    synergy_requirement_offsets[synergy] ||
                synergy_requirement_offsets[synergy + 1] >
                    synergy_requirement_ideologies.size() ||
                synergy_effect_offsets[synergy] < 0 ||
                synergy_effect_offsets[synergy + 1] <
                    synergy_effect_offsets[synergy] ||
                synergy_effect_offsets[synergy + 1] >
                    synergy_effect_count) {
            error = "ideology_synergy_offsets_invalid";
            return false;
        }
        for (int32_t row = synergy_requirement_offsets[synergy];
                row < synergy_requirement_offsets[synergy + 1]; ++row) {
            if (synergy_requirement_ideologies[row] < 0 ||
                    synergy_requirement_ideologies[row] >= count ||
                    synergy_requirement_levels[row] < 0 ||
                    synergy_requirement_locations[row] == 0 ||
                    (synergy_requirement_locations[row] & ~6) != 0) {
                error = "ideology_synergy_requirement_invalid";
                return false;
            }
        }
    }
    if (!synergy_override_offsets.is_empty()) {
        if (synergy_override_offsets.size() != synergy_count + 1 ||
                synergy_override_programs.size() != synergy_override_scales.size() ||
                (!synergy_override_match_kinds.is_empty() &&
                    (synergy_override_match_kinds.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_match_values.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_fields.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_values.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_tag_names.size() !=
                        synergy_override_programs.size())) ||
                synergy_override_offsets[synergy_count] < 0 ||
                synergy_override_offsets[synergy_count] !=
                    static_cast<int32_t>(synergy_override_programs.size())) {
            error = "ideology_synergy_override_columns_invalid";
            return false;
        }
        for (int32_t i = 0; i < synergy_count; ++i) {
            if (synergy_override_offsets[i] < 0 ||
                    synergy_override_offsets[i + 1] < synergy_override_offsets[i]) {
                error = "ideology_synergy_override_columns_invalid";
                return false;
            }
        }
        for (int32_t row = 0; row < static_cast<int32_t>(synergy_override_programs.size()); ++row) {
            const std::string program =
                String(synergy_override_programs[row]).utf8().get_data();
            const bool legacy_columns = synergy_override_match_kinds.is_empty();
            const int32_t field = legacy_columns ? 4
                : synergy_override_fields[row];
            const int32_t match_kind = legacy_columns ? 0
                : synergy_override_match_kinds[row];
            const int32_t value = legacy_columns ? synergy_override_scales[row]
                : synergy_override_values[row];
            const std::string match_value = legacy_columns ? program
                : String(synergy_override_match_values[row]).utf8().get_data();
            const std::string tag_name = legacy_columns ? std::string()
                : String(synergy_override_tag_names[row]).utf8().get_data();
            bool valid = !program.empty() && !match_value.empty() &&
                match_kind >= 0 && match_kind <= 1;
            if (valid && field == 4) { // MAGNITUDE_SCALE
                valid = value >= Q16_ONE / 4 && value <= 4 * Q16_ONE &&
                    match_kind == 0;
            } else if (valid && field == 5) { // TAG
                valid = !tag_name.empty() && match_kind == 1;
            } else if (valid && field == 6) { // SELECTOR_KIND
                valid = match_kind == 0 &&
                    (value == EffectRuntime::SELECTOR_NEIGHBORS_R1 ||
                     value == EffectRuntime::SELECTOR_NEIGHBORS_R2 ||
                     value == EffectRuntime::SELECTOR_TAG_SOURCE_R1 ||
                     value == EffectRuntime::SELECTOR_TAG_SOURCE_R2);
            } else if (valid && field == 7) { // SELECTOR_CAP
                valid = match_kind == 0 && value >= 1 &&
                    value <= EffectRuntime::SELECTOR_MAX_CELLS;
            } else {
                valid = false;
            }
            if (!valid) {
                error = "ideology_synergy_override_row_invalid";
                return false;
            }
        }
    }
    for (int32_t effect = 0; effect < synergy_effect_count; ++effect) {
        if (synergy_actions[effect] != EffectRuntime::MODIFIER_COMMAND ||
                synergy_domains[effect] < 0 || synergy_domains[effect] > 3 ||
                synergy_opcodes[effect] != 1 ||
                synergy_stacks[effect] <= 0 ||
                String(synergy_keys[effect]).is_empty() ||
                String(synergy_definitions[effect]).is_empty()) {
            error = "ideology_synergy_effect_invalid";
            return false;
        }
    }
    int32_t previous_reverse = 0;
    if (ideology_synergy_offsets[0] != 0) {
        error = "ideology_synergy_reverse_invalid";
        return false;
    }
    for (int32_t ideology = 0; ideology < count; ++ideology) {
        const int32_t end = ideology_synergy_offsets[ideology + 1];
        if (end < previous_reverse || end > ideology_synergy_ids.size()) {
            error = "ideology_synergy_reverse_invalid";
            return false;
        }
        int32_t previous_synergy = -1;
        for (int32_t row = previous_reverse; row < end; ++row) {
            if (ideology_synergy_ids[row] <= previous_synergy ||
                    ideology_synergy_ids[row] < 0 ||
                    ideology_synergy_ids[row] >= synergy_count) {
                error = "ideology_synergy_reverse_invalid";
                return false;
            }
            previous_synergy = ideology_synergy_ids[row];
        }
        previous_reverse = end;
    }
    if (previous_reverse != ideology_synergy_ids.size()) {
        error = "ideology_synergy_reverse_invalid";
        return false;
    }
    if (!synergy_min_counts.is_empty() &&
            synergy_min_counts.size() != synergy_count) {
        error = "ideology_synergy_min_counts_invalid";
        return false;
    }
    for (int32_t synergy = 0; synergy < synergy_min_counts.size(); ++synergy) {
        const int32_t requirements = synergy_requirement_offsets[synergy + 1] -
            synergy_requirement_offsets[synergy];
        if (synergy_min_counts[synergy] < 0 ||
                synergy_min_counts[synergy] > requirements) {
            error = "ideology_synergy_min_counts_invalid";
            return false;
        }
    }
    if (unlock_ideology.size() != unlock_technologies.size() ||
            unlock_spirit.size() != unlock_technologies.size()) {
        error = "ideology_capacity_unlocks_invalid";
        return false;
    }
    for (int32_t row = 0; row < unlock_technologies.size(); ++row) {
        if (unlock_technologies[row] < 0 || unlock_ideology[row] < 0 ||
                unlock_spirit[row] < 0 || unlock_ideology[row] > 16 ||
                unlock_spirit[row] > 16) {
            error = "ideology_capacity_unlocks_invalid";
            return false;
        }
    }
    _synergy_override_programs.clear();
    _synergy_override_scales.clear();
    _synergy_overrides.clear();
    _synergy_program_overrides.clear();
    _synergy_tag_overrides.clear();
    _synergy_override_tags_resolved = false;
    if (!synergy_override_offsets.is_empty()) {
        _synergy_override_programs.reserve(synergy_override_programs.size());
        for (int32_t row = 0; row < static_cast<int32_t>(synergy_override_programs.size()); ++row)
            _synergy_override_programs.emplace_back(
                String(synergy_override_programs[row]).utf8().get_data());
        _synergy_override_scales.assign(synergy_override_scales.ptr(),
            synergy_override_scales.ptr() + synergy_override_scales.size());
        const bool legacy_columns = synergy_override_match_kinds.is_empty();
        _synergy_overrides.reserve(
            static_cast<size_t>(synergy_override_programs.size()));
        for (int32_t row = 0;
                row < static_cast<int32_t>(synergy_override_programs.size());
                ++row) {
            SynergyOverride override;
            override.field = legacy_columns ? 4 : synergy_override_fields[row];
            override.value = legacy_columns ? synergy_override_scales[row]
                : synergy_override_values[row];
            override.match_kind = legacy_columns ? 0
                : synergy_override_match_kinds[row];
            override.match_value = legacy_columns ? _synergy_override_programs[
                static_cast<size_t>(row)]
                : String(synergy_override_match_values[row]).utf8().get_data();
            override.tag_name = legacy_columns ? std::string()
                : String(synergy_override_tag_names[row]).utf8().get_data();
            override.synergy_id = -1;
            _synergy_overrides.push_back(std::move(override));
        }
    }
    _definitions.clear(); _route_keys.clear(); _route_indices.clear(); _school_keys.clear(); _levels.clear(); _persistent_templates.clear(); _on_enter_templates.clear(); _synergy_templates.clear(); _class_stances.clear(); _synergy_requirements.clear(); _synergies.clear(); _technology_requirements.clear(); _signal_requirements.clear(); _gate_requirements.clear(); _era_decay_bp.clear(); _era_milestone_technologies.clear();
    _route_keys.reserve(static_cast<size_t>(route_keys.size()));
    for (int32_t i = 0; i < route_keys.size(); ++i) {
        const std::string key = String(route_keys[i]).utf8().get_data();
        if (key.empty() || !_route_indices.emplace(key, i).second) {
            error = "ideology_route_table_invalid";
            return false;
        }
        _route_keys.push_back(key);
    }
    for (int32_t i = 0; i < school_keys.size(); ++i)
        _school_keys.emplace_back(String(school_keys[i]).utf8().get_data());
    _definitions.reserve(count); _levels.reserve(thresholds.size());
    for (int32_t i=0;i<count;++i) {
        Definition d; d.stable_id=String(ids[i]).utf8().get_data(); d.acquisition=acquisition[i]; d.copy_left_programs=copy_left_programs.is_empty()?0:copy_left_programs[i]; d.copyable=copyable.is_empty()?1:copyable[i]; d.school_index=school_indices.is_empty()?-1:school_indices[i]; d.rarity_weight=weights[i]; d.ideology_cost=ideology_costs[i]; d.spirit_cost=spirit_costs[i]; d.min_spirit_level=spirit_levels[i]; d.level_begin=level_offsets[i]; d.level_count=level_offsets[i+1]-level_offsets[i]; d.technology_requirement_begin=tech_offsets[i]; d.technology_requirement_count=tech_offsets[i+1]-tech_offsets[i]; d.signal_requirement_begin=signal_offsets[i]; d.signal_requirement_count=signal_offsets[i+1]-signal_offsets[i]; d.gate_requirement_begin=gate_offsets[i]; d.gate_requirement_count=gate_offsets[i+1]-gate_offsets[i]; d.stance_begin=stance_offsets[i]; d.stance_count=stance_offsets[i+1]-stance_offsets[i]; d.support_threshold_q16={adopt_thresholds[i],repeal_thresholds[i],promote_thresholds[i]}; d.exclusion_group_id=exclusion_groups[i]; d.era_index=era_indices.is_empty()?0:era_indices[i]; d.route_mask=route_masks.is_empty()?0:static_cast<uint32_t>(route_masks[i]); _definitions.push_back(std::move(d)); }
    for (int32_t i=0;i<thresholds.size();++i) _levels.push_back({thresholds[i],daily[i],persistent_offsets[i],persistent_offsets[i+1]-persistent_offsets[i],enter_offsets[i],enter_offsets[i+1]-enter_offsets[i]});
    for (int32_t i=0;i<persistent_count;++i) _persistent_templates.push_back({persistent_actions[i],persistent_domains[i],persistent_opcodes[i],persistent_values[i],persistent_durations[i],persistent_stacks[i],String(persistent_keys[i]).utf8().get_data(),String(persistent_definitions[i]).utf8().get_data(),{persistent_i0[i],persistent_i1[i],persistent_i2[i],persistent_i3[i]}});
    for (int32_t i=0;i<enter_count;++i) _on_enter_templates.push_back({enter_actions[i],enter_domains[i],enter_opcodes[i],enter_values[i],enter_durations[i],enter_stacks[i],String(enter_keys[i]).utf8().get_data(),String(enter_definitions[i]).utf8().get_data(),{enter_i0[i],enter_i1[i],enter_i2[i],enter_i3[i]}});
    for (int32_t i=0;i<stance_count;++i) _class_stances.push_back({stance_classes[i],{stance_adopt[i],stance_repeal[i],stance_promote[i]},{stance_adopt_min[i],stance_repeal_min[i],stance_promote_min[i]}});
    for (int32_t i=0;i<synergy_requirement_ideologies.size();++i) _synergy_requirements.push_back({synergy_requirement_ideologies[i],synergy_requirement_levels[i],synergy_requirement_locations[i]});
    for (int32_t i=0;i<synergy_effect_count;++i) _synergy_templates.push_back({synergy_actions[i],synergy_domains[i],synergy_opcodes[i],synergy_values[i],synergy_durations[i],synergy_stacks[i],String(synergy_keys[i]).utf8().get_data(),String(synergy_definitions[i]).utf8().get_data(),{synergy_i0[i],synergy_i1[i],synergy_i2[i],synergy_i3[i]}});
    for (int32_t i=0;i<synergy_count;++i) {
        const int32_t requirements=synergy_requirement_offsets[i+1]-synergy_requirement_offsets[i];
        const int32_t min_count=synergy_min_counts.is_empty()||synergy_min_counts[i]==0?requirements:synergy_min_counts[i];
        const int32_t override_begin = synergy_override_offsets.is_empty()
            ? 0 : synergy_override_offsets[i];
        const int32_t override_count = synergy_override_offsets.is_empty()
            ? 0 : synergy_override_offsets[i + 1] - synergy_override_offsets[i];
        _synergies.push_back({synergy_requirement_offsets[i],requirements,synergy_effect_offsets[i],synergy_effect_offsets[i+1]-synergy_effect_offsets[i],min_count,override_begin,override_count});
    }
    // Reverse index, built once per catalog: the scale lookup is on the hot path
    // (per program, per country, per reconcile) and used to walk every synergy.
    _synergy_override_index.clear();
    _synergy_program_overrides.clear();
    for (size_t synergy_id = 0; synergy_id < _synergies.size(); ++synergy_id) {
        const Synergy &synergy = _synergies[synergy_id];
        const int32_t end = synergy.override_begin + synergy.override_count;
        for (int32_t row = synergy.override_begin; row < end; ++row) {
            if (row < 0 || row >= static_cast<int32_t>(_synergy_overrides.size()))
                continue;
            _synergy_overrides[static_cast<size_t>(row)].synergy_id =
                static_cast<int32_t>(synergy_id);
            const SynergyOverride &override =
                _synergy_overrides[static_cast<size_t>(row)];
            if (override.field != 4) {
                if (override.match_kind == 0)
                    _synergy_program_overrides[override.match_value].push_back(
                        static_cast<int32_t>(row));
                continue;
            }
            _synergy_override_index[override.match_value].push_back(
                {static_cast<int32_t>(synergy_id), override.value});
        }
    }
    _capacity_unlocks.clear();
    for (int32_t i=0;i<unlock_technologies.size();++i) _capacity_unlocks.push_back({unlock_technologies[i],unlock_ideology[i],unlock_spirit[i]});
    _ideology_synergy_offsets.assign(ideology_synergy_offsets.ptr(), ideology_synergy_offsets.ptr()+ideology_synergy_offsets.size());
    _ideology_synergy_ids.assign(ideology_synergy_ids.ptr(), ideology_synergy_ids.ptr()+ideology_synergy_ids.size());
    _synergy_candidate_stamps.assign(static_cast<size_t>(synergy_count), 0);
    // Optional. Only the offer RNG depends on it, and the worker receives the
    // same value through `export_pod_catalog`, so parity holds whether or not a
    // content layer supplies one.
    _world_seed = static_cast<uint64_t>(int64_t(catalog.get("world_seed", 0)));
    _political_class_count = political_class_ids.size();
    _political_class_hash = 1469598103934665603ULL;
    for (int32_t i=0;i<political_class_ids.size();++i) {
        const std::string id=String(political_class_ids[i]).utf8().get_data();
        for (const unsigned char value:id) { _political_class_hash^=value; _political_class_hash*=1099511628211ULL; }
        _political_class_hash^=0xffU; _political_class_hash*=1099511628211ULL;
    }
    _technology_requirements.assign(tech.ptr(), tech.ptr()+tech.size()); _signal_requirements.assign(signals.ptr(), signals.ptr()+signals.size()); _gate_requirements.assign(gates.ptr(),gates.ptr()+gates.size());
    _era_decay_bp.assign(era_decay_bp.ptr(), era_decay_bp.ptr()+era_decay_bp.size());
    _era_milestone_technologies.assign(era_milestones.ptr(), era_milestones.ptr()+era_milestones.size());
    _ideology_capacity=std::max(0,int32_t(catalog.get("ideology_capacity",6))); _spirit_capacity=std::max(0,int32_t(catalog.get("national_spirit_capacity",3))); _draw_count=int32_t(catalog.get("offer_choice_count",3)); _offer_cost_q16=int64_t(catalog.get("offer_cost_q16",Q16_ONE)); _starting_points_q16=std::max<int64_t>(0,int64_t(catalog.get("starting_points_q16",0))); _max_commands_per_slice=std::max(1,int32_t(catalog.get("max_commands_per_slice",4096))); _max_transition_commands=std::max(1,std::min(4096,int32_t(catalog.get("max_transition_commands",256)))); _max_transition_polls_per_slice=std::max(1,int32_t(catalog.get("max_transition_polls_per_slice",4096))); _max_active_visits_per_slice=std::max(1,int32_t(catalog.get("max_active_visits_per_slice",1024))); _opinion_owner_influence_weight=std::max(0,int32_t(catalog.get("opinion_owner_influence_weight",2))); _opinion_funds_per_influence=std::max<int64_t>(1,int64_t(catalog.get("opinion_funds_per_influence",1000000)));
    _draw_count=std::clamp(_draw_count,1,OFFER_CHOICE_CAPACITY);
    if (_offer_cost_q16<0) { error="ideology_profile_invalid"; return false; }
    _ideology_capacity_max=std::max(_ideology_capacity,int32_t(catalog.get("ideology_capacity_max",_ideology_capacity)));
    _spirit_capacity_max=std::max(_spirit_capacity,int32_t(catalog.get("national_spirit_capacity_max",_spirit_capacity)));
    _offer_cost_growth_percent=int64_t(catalog.get("offer_cost_growth_percent",100));
    if (_offer_cost_growth_percent<100 || _offer_cost_growth_percent>400) { error="ideology_profile_invalid"; return false; }
    _offer_cost_max_q16=std::max<int64_t>(_offer_cost_q16,int64_t(catalog.get("offer_cost_max_q16",_offer_cost_q16)));
    _reroll_cost_percent=std::clamp(int32_t(catalog.get("reroll_cost_percent",50)),0,1000);
    _point_population_weight_q16=std::max<int64_t>(0,int64_t(catalog.get("point_population_weight_q16",0)));
    _point_building_weight_q16=std::max<int64_t>(0,int64_t(catalog.get("point_building_weight_q16",0)));
    _point_trade_weight_q16=std::max<int64_t>(0,int64_t(catalog.get("point_trade_weight_q16",0)));
    _point_gain_cap_q16=std::max<int64_t>(0,int64_t(catalog.get("point_gain_cap_q16",0)));
    _point_gain_stat_key=String(catalog.get("point_gain_stat_key",String())).utf8().get_data();
    _point_population_factor_stat_key=String(catalog.get(
        "point_population_factor_stat_key",String())).utf8().get_data();
    _point_building_factor_stat_key=String(catalog.get(
        "point_building_factor_stat_key",String())).utf8().get_data();
    _point_trade_factor_stat_key=String(catalog.get(
        "point_trade_factor_stat_key",String())).utf8().get_data();
    _opinion_factor_floor_stat_key=String(catalog.get(
        "opinion_factor_floor_stat_key",String())).utf8().get_data();
    _school_strength_factor_stat_keys.clear();
    for (int32_t i = 0; i < school_strength_keys.size(); ++i)
        _school_strength_factor_stat_keys.emplace_back(
            String(school_strength_keys[i]).utf8().get_data());
    _understanding_gain_stat_key=
        String(catalog.get("understanding_gain_stat_key",String())).utf8().get_data();
    _reroll_cost_stat_key=
        String(catalog.get("reroll_cost_stat_key",String())).utf8().get_data();
    _era_decay_floor_stat_key=
        String(catalog.get("era_decay_floor_stat_key",String())).utf8().get_data();
    _offer_choice_bonus_stat_key=
        String(catalog.get("offer_choice_bonus_stat_key",String())).utf8().get_data();
    _refine_weight_bp=std::clamp(int32_t(catalog.get("refine_weight_bp",0)),0,10000);
    _refine_understanding_q16=std::max<int64_t>(0,
        int64_t(catalog.get("refine_understanding_q16",4*Q16_ONE)));
    // A reconfigure can renumber stat ids (dense ids are assigned in catalog
    // order), so any id cached against the previous catalog is stale.
    _understanding_gain_stat_id = -1;
    _reroll_cost_stat_id = -1;
    _era_decay_floor_stat_id = -1;
    _offer_choice_bonus_stat_id = -1;
    _point_population_factor_stat_id = -1;
    _point_building_factor_stat_id = -1;
    _point_trade_factor_stat_id = -1;
    _opinion_factor_floor_stat_id = -1;
    _school_strength_factor_stat_ids.assign(
        _school_strength_factor_stat_keys.size(), -1);
    // gate_bits must cover every registered gate key, not just the highest one a
    // requirement happens to reference: IdeologyFacade resolves a key to its index
    // in gate_keys and set_gate() drops anything past _gate_count, so a context
    // gate that no card requires yet (ctx.*) would be silently ignored.
    _gate_count=std::max(std::max(0,max_gate+1),static_cast<int32_t>(gate_keys.size())); _idea_words=(count+63)/64; _gate_words=(_gate_count+63)/64;
    return true;
}

Dictionary NativeIdeologyRuntime::configure(const Dictionary &catalog) {
    _configured=false; reset_runtime_state(); std::string error; if (!validate_catalog(catalog,error)) return fail(error); _catalog_hash=compute_catalog_hash(); _configured=true;
    // A configured runtime has no restore behind it, so there is nothing for the worker
    // to adopt and no imported catalog identity to remember yet.
    _worker_import_pending = false;
    _worker_import_last_code.clear();
    _worker_import_attempts = 0;
    _pod_catalog_hash = 0;
    if (_effect_runtime != nullptr && !resolve_synergy_override_tags(error)) {
        _configured = false;
        return fail(error);
    }
    // Hand the economy the declared consumer set: without it the digest covers
    // nothing and every managed card would sit frozen on a content change.
    publish_effect_input_consumers();
    // Plan §11.5: nothing is stamped here on purpose. The contract is computed wherever it
    // is needed (capture / restore / report), so it always describes the configuration in
    // force and cannot go stale behind a later `configure_effects`.
    Dictionary out; out["ok"]=true; out["catalog_hash"]=static_cast<int64_t>(_catalog_hash);
    out["execution_contract_hash"]=static_cast<int64_t>(compute_execution_contract_hash()); out["ideology_count"]=static_cast<int32_t>(_definitions.size()); return out;
}

void NativeIdeologyRuntime::reset_runtime_state() {
    _worker_opinion_inputs = RuntimeIdeologyOpinionSnapshot{};
    _worker_opinion_inputs_valid = false;
    _countries.clear();
    _commands.clear();
    _command_cursor = 0;
    _producer_high_watermarks.clear();
    _receipts.clear();
    _next_receipt_id = 1;
    _applying_producer_id = 0;
    _applying_sequence = 0;
    _applying_opcode = 0;
    _pending_transitions.clear();
    _pending_transition_cursor = 0;
    _active_progress_day = -1;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _submit_order = 0;
    _last_day = -1;
    _active_visits = 0;
    _dormant_scan_count = 0;
    _sparse_idea_scan_count = 0;
    _pending_transition_visits = 0;
    _command_queue_resorts = 0;
    _command_queue_shift_steps = 0;
    _command_queue_merge_steps = 0;
    _derived_rebuild_visits = 0;
    _commands_applied = 0;
    _commands_rejected = 0;
    _offers_opened = 0;
    _levels_advanced = 0;
    _class_snapshot_reads = 0;
    _support_evaluations = 0;
    _synergy_candidates_visited = 0;
    _metric_publishes = 0;
    _metric_publishes_skipped = 0;
    _selector_stats = EffectSelectorStats{};
    _selector_truncations = 0;
    _source_count_evaluations = 0;
    _managed_active_total = 0;
    _effect_input_revision_seen = 0;
    _effect_input_revision_target = 0;
    _instance_refresh_pending = false;
    _instance_refresh_dirty = false;
    _instance_refresh_country_cursor = 0;
    _instance_refresh_visits = 0;
    _instance_refresh_skips = 0;
    _instance_refresh_passes = 0;
    _instance_refresh_lag_revisions = 0;
    _instance_refresh_ms = 0.0;
    _level_managed_built = false;
    _synergy_candidate_generation = 0;
    _synergy_candidate_scratch.clear();
    _transition_poll_ms = 0.0;
    _command_apply_ms = 0.0;
    _active_progress_ms = 0.0;
    _last_slice_ms = 0.0;
    _max_slice_ms = 0.0;
    _pod_snapshot_generation = 0;
    _points_revision_seen = 0;
    _worker_origin = false;
    // The applied basis describes the country rows and the catalogs it was derived
    // from; a reset clears the rows, so the basis goes with them. (The two basis DATES
    // are deliberately left alone here: §9.3 eligibility is a clock property, not a row
    // property, and resetting it would let a reconfigure re-adopt a projection early.)
    _applied_program_basis.clear();
    // §18.5: same argument for the scalar record -- it describes the rows that were
    // just cleared. `_derived_basis_sample_day` is a clock/identity property of the
    // projection like the two dates above, so it is deliberately left alone.
    _local_scalar_basis.clear();
    _last_error.clear();
}

bool NativeIdeologyRuntime::apply_pod_snapshot(
        const RuntimeIdeologyPodSnapshot &snapshot, std::string &error) {
    error.clear();
    if (!_configured) {
        error = "ideology_runtime_not_configured";
        return false;
    }
    // ── plan §9.3 in WORKER mode ────────────────────────────────────────────
    //
    // The two basis dates were stamped only in `settle_transition`'s success path, which
    // never runs on the main thread when the worker owns IDEOLOGY. Without this the
    // eligibility gate is permanently open there, and publishing projections with §9.3
    // silently unenforced is worse than publishing none.
    //
    // The mirror's `committed_day` is the worker's own confirmation day: everything in
    // this snapshot was ACKed on it, so the projection it carries is confirmed that day
    // and eligible the next -- the same rule the local path applies.
    if (snapshot.committed_day != _derived_basis_confirmed_day) {
        _derived_basis_confirmed_day = snapshot.committed_day;
        _derived_basis_eligible_day = snapshot.committed_day + 1;
    }


    if (_worker_opinion_inputs_valid) {
        const size_t school_count = _school_keys.size();
        if (school_count > 0) {
            const bool shaped =
                _worker_opinion_inputs.school_strength_factor_q16.empty() ||
                _worker_opinion_inputs.school_strength_factor_q16.size() ==
                    snapshot.countries.size() * school_count;
            if (!shaped) {
                error = "ideology_school_strength_snapshot_shape_invalid";
                return false;
            }
        }
    }
    if (snapshot.abi_version != RUNTIME_IDEOLOGY_POD_ABI_VERSION) {
        error = "ideology_pod_snapshot_abi_mismatch";
        return false;
    }
    if (snapshot.generation != 0 &&
            snapshot.generation <= _pod_snapshot_generation) {
        error = "ideology_pod_snapshot_generation_regression";
        return false;
    }
    const size_t definition_count = _definitions.size();
    const size_t idea_words = static_cast<size_t>(std::max(0, _idea_words));
    const size_t gate_words = static_cast<size_t>(std::max(0, _gate_words));
    const size_t synergy_words = (_synergies.size() + 63u) / 64u;

    std::vector<CountryState> next_countries(snapshot.countries.size());
    for (size_t slot = 0; slot < snapshot.countries.size(); ++slot) {
        const RuntimeIdeologyPodCountryState &source = snapshot.countries[slot];
        if (source.handle == 0) continue;
        CountryState &target = next_countries[slot];
        // P1-B: the instance set is NOT part of the POD snapshot -- the worker
        // never sees an Effect instance, the facade owns them. Carry the previous
        // rows across by (country, ideology) so a write-back cannot resubmit the
        // whole world, and so the retire pass still has something to compare
        // against. Moved, not copied: the old table is discarded right below.
        CountryState *previous_country = nullptr;
        const uint32_t previous_slot =
            static_cast<uint32_t>(source.handle & 0xffffffffULL);
        if (previous_slot < _countries.size() &&
                _countries[previous_slot].handle == source.handle)
            previous_country = &_countries[previous_slot];
        target.handle = source.handle;
        target.unlocked_era = source.unlocked_era;
        target.ideology_points_q16 = source.ideology_points_q16;
        target.rng_state = source.rng_state;
        target.draw_sequence = source.draw_sequence;
        target.free_draws = source.free_draws;
        target.points_revision = source.points_revision;
        target.baseline_ready = source.baseline_ready;
        target.history_count = source.history_count;
        target.history_head = source.history_head;
        target.baseline_population = source.baseline_population;
        target.baseline_buildings = source.baseline_buildings;
        target.lifetime_points_q16 = source.lifetime_points_q16;
        target.trade_paid_day = source.trade_paid_day;
        target.ledger = source.ledger;
        for (size_t i = 0; i < target.history_q16.size() &&
                i < source.history_q16.size(); ++i)
            target.history_q16[i] = source.history_q16[i];
        target.opinion_revision = source.opinion_revision;
        target.ideology_slots_used = source.ideology_slots_used;
        target.spirit_slots_used = source.spirit_slots_used;
        target.known_bits.assign(idea_words, 0);
        target.gate_bits.assign(gate_words, 0);
        target.active_bits.assign(idea_words, 0);
        target.active_synergy_bits.assign(synergy_words, 0);
        // 封存 lives in its own bitmap, and the POD has always carried it. Not
        // copying it let a banned card reappear in the offer the moment a worker
        // snapshot landed.
        target.banned_bits.assign(idea_words, 0);
        for (size_t word = 0;
                word < idea_words && word < source.banned_bits.size(); ++word)
            target.banned_bits[word] = source.banned_bits[word];
        if (source.offer.choice_count > OFFER_CHOICE_CAPACITY ||
                source.unlocked_era < 0) {
            error = "ideology_pod_snapshot_country_invalid";
            return false;
        }
        for (size_t word = 0;
                word < idea_words && word < source.known_bits.size(); ++word)
            target.known_bits[word] = source.known_bits[word];
        for (size_t word = 0;
                word < gate_words && word < source.gate_bits.size(); ++word)
            target.gate_bits[word] = source.gate_bits[word];
        for (size_t word = 0;
                word < synergy_words && word < source.synergy_bits.size(); ++word)
            target.active_synergy_bits[word] = source.synergy_bits[word];
        target.offer.generation = source.offer.generation;
        target.offer.ideology_ids = source.offer.ideology_ids;
        target.offer.active = source.offer.active;
        target.offer.choice_count = source.offer.choice_count;
        // POD ideas are dense by ideology_id. The facade keeps sparse rows plus
        // an id->row index, so only rows that carry state are materialised;
        // everything else stays absent exactly as the synchronous path leaves
        // an undiscovered idea.
        for (size_t id = 0; id < source.ideas.size() && id < definition_count;
                ++id) {
            const RuntimeIdeologyPodIdeaState &idea = source.ideas[id];
            const bool discovered = (id / 64u) < target.known_bits.size() &&
                (target.known_bits[id / 64u] & (1ull << (id % 64u))) != 0;
            if (!discovered &&
                    idea.location == RuntimeIdeologyPodLocation::INACTIVE &&
                    idea.understanding_q16 == 0 && idea.level < 0 &&
                    idea.entered_levels == 0 && idea.generation <= 1) {
                continue;
            }
            const int32_t row = static_cast<int32_t>(target.ideas.size());
            IdeaState state;
            state.ideology_id = static_cast<int32_t>(id);
            state.understanding_q16 = idea.understanding_q16;
            state.level = idea.level;
            state.entered_levels = idea.entered_levels;
            state.generation = idea.generation;
            state.location = static_cast<uint8_t>(idea.location);
            state.slot_index = idea.slot_index;
            // Carry the facade-owned instance rows and the signature that
            // produced them. Without this every write-back looked like "no
            // instances held", so reconcile resubmitted every card and the
            // retire pass had nothing to retire against.
            if (previous_country != nullptr) {
                auto previous_row =
                    previous_country->idea_indices.find(state.ideology_id);
                if (previous_row != previous_country->idea_indices.end()) {
                    IdeaState &previous = previous_country->ideas[
                        static_cast<size_t>(previous_row->second)];
                    state.effect_instances = std::move(previous.effect_instances);
                    state.activation_signature = previous.activation_signature;
                    // The worker snapshot is authoritative for whether the idea
                    // is still equipped. If it just went inactive, retires can
                    // no longer ride the active-only refresh pass, so release
                    // the carried facade instances here.
                    if (state.location == INACTIVE &&
                            !state.effect_instances.empty()) {
                        retire_effect_activations(state, snapshot.committed_day);
                        state.activation_signature = 0;
                    }
                }
            }
            // The durable binding identity is a pure function of (handle, idea,
            // location, generation, level), so it is derived rather than carried.
            // Leaving it zero made compute_state_hash disagree between the
            // synchronous and worker paths for the same world.
            if (state.location != INACTIVE) {
                state.binding_id = static_cast<int64_t>(binding_id_for(
                    target.handle, state.ideology_id, state.location));
                state.binding_generation = state.generation;
                state.binding_signature =
                    binding_signature_for(state.ideology_id, state.level);
                state.binding_program_hash =
                    _effect_runtime != nullptr ? _effect_runtime->catalog_hash() : 0;
            }
            target.idea_indices[state.ideology_id] = row;
            if (state.location != INACTIVE) {
                // Rows are appended in ascending ideology_id, so the active
                // index is already in the sorted order insert_active_state
                // maintains.
                target.active_state_indices.push_back(row);
                target.active_bits[id / 64u] |= 1ull << (id % 64u);
            }
            target.ideas.push_back(state);
        }
    }

    std::vector<PendingTransitionRef> next_pending;
    next_pending.reserve(snapshot.pending_transitions.size());
    for (const RuntimeIdeologyPodTransition &pending :
            snapshot.pending_transitions) {
        if (pending.country_slot >= next_countries.size() ||
                pending.ideology_id < 0 ||
                pending.ideology_id >= static_cast<int32_t>(definition_count)) {
            error = "ideology_pod_snapshot_transition_invalid";
            return false;
        }
        CountryState &country =
            next_countries[static_cast<size_t>(pending.country_slot)];
        if (country.handle == 0) {
            error = "ideology_pod_snapshot_transition_country_inactive";
            return false;
        }
        auto found = country.idea_indices.find(pending.ideology_id);
        if (found == country.idea_indices.end()) {
            // A first transition can be the only state an idea carries, and
            // the dense POD row above then looked empty.
            IdeaState state;
            state.ideology_id = pending.ideology_id;
            const int32_t row = static_cast<int32_t>(country.ideas.size());
            country.idea_indices[pending.ideology_id] = row;
            country.ideas.push_back(state);
            found = country.idea_indices.find(pending.ideology_id);
        }
        IdeaState &state = country.ideas[static_cast<size_t>(found->second)];
        // The worker applies a transition only on the Effect ACK, so the row
        // above is still the pre-transition state. previous_* mirrors it: a
        // rollback on rejection is then a no-op instead of inventing state the
        // POD snapshot never carried. desired_level / desired_location have no
        // facade field; the next snapshot carries them as the applied row.
        state.transition.active = 1;
        state.transition.producer_id = static_cast<int32_t>(pending.producer_id);
        state.transition.command_sequence =
            static_cast<int64_t>(pending.sequence);
        state.transition.previous_level = state.level;
        state.transition.previous_entered_levels = state.entered_levels;
        state.transition.previous_generation = state.generation;
        state.transition.previous_location = state.location;
        state.transition.previous_slot_index = state.slot_index;
        state.transition.entered_on_success = pending.desired_entered_levels;
        state.transition.transaction_ids.assign(
            1, static_cast<int64_t>(pending.intent_id));
        ++country.pending_transition_count;
        next_pending.push_back({country.handle,
            static_cast<int32_t>(pending.country_slot), found->second,
            state.generation});
    }

    std::vector<Receipt> next_receipts;
    next_receipts.reserve(snapshot.receipts.size());
    int64_t next_receipt_id = 1;
    for (const RuntimeIdeologyPodReceipt &source : snapshot.receipts) {
        Receipt receipt;
        receipt.receipt_id = next_receipt_id++;
        receipt.producer_id = static_cast<int32_t>(source.producer_id);
        receipt.sequence = static_cast<int64_t>(source.sequence);
        receipt.status = static_cast<int32_t>(source.status);
        receipt.opcode = static_cast<int32_t>(source.opcode);
        receipt.country_handle = source.country_handle;
        receipt.ideology_id = source.ideology_id;
        receipt.settled_day = source.settled_day;
        if (source.status == RuntimeIdeologyPodReceiptStatus::REJECTED)
            receipt.reason = source.reason_text.empty()
                ? "ideology_worker_rejected" : source.reason_text;
        next_receipts.push_back(receipt);
    }

    _countries = std::move(next_countries);
    _pending_transitions = std::move(next_pending);
    _pending_transition_cursor = 0;
    _receipts = std::move(next_receipts);
    _next_receipt_id = next_receipt_id;
    _producer_high_watermarks.clear();
    for (const RuntimeIdeologyPodProducerWatermark &watermark :
            snapshot.producer_high_watermarks) {
        _producer_high_watermarks[static_cast<int32_t>(watermark.producer_id)] =
            static_cast<int64_t>(watermark.sequence);
    }
    // The worker owns the command queue under ACTIVE. Whatever is staged here
    // was already mirrored across the transport by submit_ideology_commands,
    // so replaying it on the main thread would double-apply it.
    _commands.clear();
    _command_cursor = 0;
    _active_progress_day = snapshot.round_day;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _submit_order = std::max(_submit_order, snapshot.next_submit_order);
    _pod_snapshot_generation = snapshot.generation;
    _last_day = snapshot.committed_day;
    _worker_origin = true;
    // The pod owns level/location under worker authority, so this snapshot is
    // the only place where the main thread learns that a card changed tier.
    //
    // Do NOT converge here. Reconciling every card of every country on every
    // write-back is the P1-B defect: one snapshot per generation, and a
    // generation per day, meant the whole world was re-submitted daily. Mark
    // the refresh dirty instead; the sliced pass recomputes only the cards whose
    // signature actually moved.
    mark_instance_refresh_dirty();
    recount_managed_active();
    return true;
}

bool NativeIdeologyRuntime::validate_country(uint64_t handle, int32_t &slot) const { slot=static_cast<int32_t>(handle & 0xffffffffULL); return _country_runtime!=nullptr && handle!=0 && _country_runtime->valid_handle(static_cast<int64_t>(handle)); }
NativeIdeologyRuntime::CountryState *NativeIdeologyRuntime::country_state_for(
        uint64_t handle, bool create) {
    int32_t slot = -1;
    if (!validate_country(handle, slot)) return nullptr;
    if (slot >= static_cast<int32_t>(_countries.size())) {
        if (!create) return nullptr;
        _countries.resize(static_cast<size_t>(slot + 1));
    }
    CountryState &state = _countries[static_cast<size_t>(slot)];
    if (state.handle != handle) {
        if (!create && state.handle == 0) return nullptr;
        init_country_state(state, handle);
    }
    return &state;
}
void NativeIdeologyRuntime::init_country_state(CountryState &state,
        uint64_t handle) const {
    state = CountryState{};
    state.handle = handle;
    state.ideology_points_q16 = _starting_points_q16;
    // Seed from the handle and the SHARED world seed only. The worker uses
    // `runtime_ideology_country_rng_seed()` with the same pair; seeding from
    // `_catalog_hash` here made `rng_state` differ by construction, and seeding
    // from the handle alone made every session of a map draw the same sequence.
    state.rng_state = runtime_ideology_country_rng_seed(handle, _world_seed);
    state.known_bits.assign(static_cast<size_t>(_idea_words), 0);
    state.banned_bits.assign(static_cast<size_t>(_idea_words), 0);
    state.gate_bits.assign(static_cast<size_t>(_gate_words), 0);
    state.active_bits.assign(static_cast<size_t>(_idea_words), 0);
    state.active_synergy_bits.assign((_synergies.size() + 63U) / 64U, 0);
}
const NativeIdeologyRuntime::CountryState *NativeIdeologyRuntime::country_state_for(uint64_t handle) const { const int32_t slot=static_cast<int32_t>(handle & 0xffffffffULL); if(slot<0 || slot>=static_cast<int32_t>(_countries.size())) return nullptr; const CountryState &state=_countries[slot]; return state.handle==handle?&state:nullptr; }
NativeIdeologyRuntime::IdeaState *NativeIdeologyRuntime::idea_state_for(CountryState &country,int32_t id,bool create) { auto found=country.idea_indices.find(id); if(found!=country.idea_indices.end()) return &country.ideas[found->second]; if(!create || id<0 || id>=static_cast<int32_t>(_definitions.size())) return nullptr; const int32_t index=static_cast<int32_t>(country.ideas.size()); country.ideas.push_back({id,0,-1,0,1,INACTIVE}); country.idea_indices[id]=index; return &country.ideas.back(); }
const NativeIdeologyRuntime::IdeaState *NativeIdeologyRuntime::idea_state_for(const CountryState &country,int32_t id) const { auto found=country.idea_indices.find(id); return found==country.idea_indices.end()?nullptr:&country.ideas[found->second]; }
bool NativeIdeologyRuntime::known(const CountryState &c,int32_t id) const { return id>=0 && id<static_cast<int32_t>(_definitions.size()) && (c.known_bits[id/64]&(1ULL<<(id%64)))!=0; }
void NativeIdeologyRuntime::set_known(CountryState &c,int32_t id) { c.known_bits[id/64]|=(1ULL<<(id%64)); }
bool NativeIdeologyRuntime::gate(const CountryState &c,int32_t id) const { return id>=0 && id<_gate_count && (c.gate_bits[id/64]&(1ULL<<(id%64)))!=0; }
void NativeIdeologyRuntime::set_gate(CountryState &c,int32_t id,bool value) { if(id<0||id>=_gate_count)return; const uint64_t mask=1ULL<<(id%64); if(value)c.gate_bits[id/64]|=mask; else c.gate_bits[id/64]&=~mask; }
bool NativeIdeologyRuntime::requirements_met(const CountryState &country,int32_t slot,const Definition &d) const { if(_country_runtime==nullptr)return false; for(int32_t i=0;i<d.technology_requirement_count;++i) if(!_country_runtime->has_technology(slot,_technology_requirements[d.technology_requirement_begin+i])) return false; for(int32_t i=0;i<d.signal_requirement_count;++i) if(!_country_runtime->has_research_signal(slot,_signal_requirements[d.signal_requirement_begin+i])) return false; for(int32_t i=0;i<d.gate_requirement_count;++i) if(!gate(country,_gate_requirements[d.gate_requirement_begin+i])) return false; return true; }

NativeIdeologyRuntime::SupportResult NativeIdeologyRuntime::evaluate_support(
        CountryState &country, int32_t ideology_id,
        SupportDirection direction) {
    SupportResult result;
    if (ideology_id < 0 ||
            ideology_id >= static_cast<int32_t>(_definitions.size()) ||
            direction < SUPPORT_ADOPT || direction > SUPPORT_PROMOTE)
        return result;
    const Definition &definition =
        _definitions[static_cast<size_t>(ideology_id)];
    result.threshold_q16 =
        definition.support_threshold_q16[static_cast<size_t>(direction)];
    ++_support_evaluations;
    if (definition.stance_count == 0) {
        result.available = true;
        result.allowed = true;
        return result;
    }
    if (_economy_runtime == nullptr) return result;
    const NativeEconomyRuntime::CountryClassOpinionSnapshot &snapshot =
        _economy_runtime->country_class_opinion_snapshot();
    ++_class_snapshot_reads;
    const int32_t country_slot =
        static_cast<int32_t>(country.handle & 0xffffffffULL);
    if (snapshot.revision == 0 ||
            snapshot.class_hash != _political_class_hash ||
            snapshot.class_count != _political_class_count ||
            country_slot < 0 || country_slot >= snapshot.country_count ||
            country_slot >=
                static_cast<int32_t>(snapshot.country_handles.size()) ||
            snapshot.country_handles[static_cast<size_t>(country_slot)] !=
                country.handle)
        return result;
    result.revision = snapshot.revision;
    if (country.opinion_revision != snapshot.revision ||
            country.class_influence.size() !=
                static_cast<size_t>(_political_class_count)) {
        country.class_influence.assign(
            static_cast<size_t>(_political_class_count), 0);
        const size_t row_begin = static_cast<size_t>(country_slot) *
            static_cast<size_t>(_political_class_count);
        for (int32_t class_index = 0;
                class_index < _political_class_count; ++class_index) {
            const size_t row = row_begin +
                static_cast<size_t>(class_index);
            if (row >= snapshot.population.size() ||
                    row >= snapshot.funds.size() ||
                    row >= snapshot.owner_employed.size())
                continue;
            int64_t influence =
                std::max<int64_t>(0, snapshot.population[row]);
            influence = add_sat(influence, mul_sat(
                std::max<int64_t>(0, snapshot.owner_employed[row]),
                _opinion_owner_influence_weight));
            influence = add_sat(influence,
                std::max<int64_t>(0, snapshot.funds[row]) /
                    _opinion_funds_per_influence);
            country.class_influence[static_cast<size_t>(class_index)] =
                std::max<int64_t>(0, influence);
        }
        country.opinion_revision = snapshot.revision;
    }
    int64_t total_influence = 0;
    for (const int64_t influence : country.class_influence)
        total_influence = add_sat(total_influence,
            std::max<int64_t>(0, influence));
    if (total_influence <= 0) return result;
    int64_t weighted_support = 0;
    for (int32_t row = definition.stance_begin;
            row < definition.stance_begin + definition.stance_count; ++row) {
        const ClassStance &stance =
            _class_stances[static_cast<size_t>(row)];
        const int64_t influence =
            country.class_influence[static_cast<size_t>(
                stance.class_index)];
        const int32_t stance_value =
            stance.stance_q16[static_cast<size_t>(direction)];
        weighted_support = add_sat(weighted_support,
            mul_sat(influence, stance_value));
        const int32_t critical_min =
            stance.critical_min_q16[static_cast<size_t>(direction)];
        if (critical_min >= -65536 &&
                (influence <= 0 || stance_value < critical_min) &&
                result.blocking_class < 0)
            result.blocking_class = stance.class_index;
    }
    result.support_q16 = static_cast<int32_t>(std::clamp<int64_t>(
        weighted_support / total_influence, -Q16_ONE, Q16_ONE));
    result.available = true;
    result.allowed = result.support_q16 >= result.threshold_q16 &&
        result.blocking_class < 0;
    return result;
}

bool NativeIdeologyRuntime::support_gate(CountryState &country,
        int32_t ideology_id, SupportDirection direction,
        std::string &error) {
    const SupportResult result =
        evaluate_support(country, ideology_id, direction);
    if (!result.available) {
        error = "ideology_class_opinion_unavailable";
        return false;
    }
    if (result.blocking_class >= 0) {
        error = "ideology_critical_class_blocked";
        return false;
    }
    if (!result.allowed) {
        error = "ideology_support_threshold_not_met";
        return false;
    }
    return true;
}

bool NativeIdeologyRuntime::exclusion_allows(
        const CountryState &country, int32_t ideology_id,
        std::string &error) const {
    const int32_t group =
        _definitions[static_cast<size_t>(ideology_id)].exclusion_group_id;
    if (group < 0) return true;
    for (const int32_t idea_slot : country.active_state_indices) {
        if (idea_slot < 0 ||
                idea_slot >= static_cast<int32_t>(country.ideas.size()))
            continue;
        const IdeaState &other =
            country.ideas[static_cast<size_t>(idea_slot)];
        if (other.ideology_id != ideology_id &&
                other.location != INACTIVE &&
                _definitions[static_cast<size_t>(other.ideology_id)]
                    .exclusion_group_id == group) {
            error = "ideology_exclusion_group_conflict";
            return false;
        }
    }
    return true;
}

bool NativeIdeologyRuntime::synergy_active(
        const CountryState &country, int32_t synergy_id) const {
    return synergy_id >= 0 &&
        synergy_id < static_cast<int32_t>(_synergies.size()) &&
        static_cast<size_t>(synergy_id / 64) <
            country.active_synergy_bits.size() &&
        (country.active_synergy_bits[static_cast<size_t>(synergy_id / 64)] &
         (1ULL << (synergy_id % 64))) != 0;
}

void NativeIdeologyRuntime::set_synergy_active(CountryState &country,
        int32_t synergy_id, bool active) {
    if (synergy_id < 0 ||
            synergy_id >= static_cast<int32_t>(_synergies.size()))
        return;
    if (country.active_synergy_bits.size() <
            (_synergies.size() + 63U) / 64U)
        country.active_synergy_bits.resize(
            (_synergies.size() + 63U) / 64U, 0);
    uint64_t &word = country.active_synergy_bits[
        static_cast<size_t>(synergy_id / 64)];
    const uint64_t mask = 1ULL << (synergy_id % 64);
    const bool previous = (word & mask) != 0;
    if (active) word |= mask;
    else word &= ~mask;
    if (previous != active)
        mark_instance_refresh_dirty();
}

bool NativeIdeologyRuntime::synergy_requirements_met(
        const CountryState &country, int32_t synergy_id) const {
    if (synergy_id < 0 ||
            synergy_id >= static_cast<int32_t>(_synergies.size()))
        return false;
    const Synergy &synergy =
        _synergies[static_cast<size_t>(synergy_id)];
    const int32_t needed = synergy.min_count > 0
        ? synergy.min_count : synergy.requirement_count;
    int32_t held = 0;
    for (int32_t row = synergy.requirement_begin;
            row < synergy.requirement_begin + synergy.requirement_count;
            ++row) {
        const SynergyRequirement &requirement =
            _synergy_requirements[static_cast<size_t>(row)];
        const IdeaState *state =
            idea_state_for(country, requirement.ideology_id);
        if (state != nullptr &&
                state->level >= requirement.minimum_level &&
                (requirement.location_mask &
                 (1U << state->location)) != 0) {
            if (++held >= needed) return true;
        }
    }
    return held >= needed;
}

bool NativeIdeologyRuntime::collect_affected_synergies(
        CountryState &country, int32_t ideology_id, int64_t day,
        IdeaState::Transition &transition,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (ideology_id < 0 ||
            ideology_id + 1 >=
                static_cast<int32_t>(_ideology_synergy_offsets.size()))
        return true;
    if (++_synergy_candidate_generation == 0) {
        std::fill(_synergy_candidate_stamps.begin(),
            _synergy_candidate_stamps.end(), 0);
        _synergy_candidate_generation = 1;
    }
    _synergy_candidate_scratch.clear();
    for (int32_t cursor =
            _ideology_synergy_offsets[static_cast<size_t>(ideology_id)];
            cursor < _ideology_synergy_offsets[
                static_cast<size_t>(ideology_id + 1)]; ++cursor) {
        const int32_t synergy_id =
            _ideology_synergy_ids[static_cast<size_t>(cursor)];
        if (_synergy_candidate_stamps[static_cast<size_t>(synergy_id)] ==
                _synergy_candidate_generation)
            continue;
        _synergy_candidate_stamps[static_cast<size_t>(synergy_id)] =
            _synergy_candidate_generation;
        _synergy_candidate_scratch.push_back(synergy_id);
    }
    std::sort(_synergy_candidate_scratch.begin(),
        _synergy_candidate_scratch.end());
    for (const int32_t synergy_id : _synergy_candidate_scratch) {
        ++_synergy_candidates_visited;
        const bool previous = synergy_active(country, synergy_id);
        const bool next = synergy_requirements_met(country, synergy_id);
        if (previous == next) continue;
        const Synergy &synergy =
            _synergies[static_cast<size_t>(synergy_id)];
        if (commands.size() + static_cast<size_t>(synergy.effect_count) >
                static_cast<size_t>(_max_transition_commands)) {
            error = "ideology_transition_command_limit_exceeded";
            return false;
        }
        transition.changed_synergy_ids.push_back(synergy_id);
        transition.previous_synergy_active.push_back(previous ? 1 : 0);
        set_synergy_active(country, synergy_id, next);
        for (int32_t effect = 0; effect < synergy.effect_count; ++effect) {
            const int32_t effect_index = synergy.effect_begin + effect;
            const EffectTemplate &templ =
                _synergy_templates[static_cast<size_t>(effect_index)];
            uint64_t hash = 1469598103934665603ULL;
            hash = mixv(hash, country.handle);
            hash = mixv(hash, synergy_id);
            hash = mixv(hash, effect_index);
            EffectRuntime::ExternalEffectCommandPod command;
            command.effect_id = static_cast<int64_t>(
                hash & 0x7fffffffffffffffULL);
            command.source_id = static_cast<int64_t>(
                (0x7fffULL << 48U) |
                (static_cast<uint64_t>(synergy_id + 1) << 16U) |
                static_cast<uint32_t>(effect + 1));
            command.program_key = "ideology.command";
            // The row this command produces must be keyed by `source_id` above, NOT by
            // the per-fire Effect instance. `source_id` is stable per (synergy, effect),
            // so the later deactivation's REMOVE resolves to the same row. With an
            // instance-derived key the removal could never match and the row leaked
            // permanently (measured: factors stayed at 0.95/1.03 after the bond died).
            command.stable_source_identity = true;
            command.fire_sequence = static_cast<uint64_t>(day) ^
                (next ? 0ULL : (1ULL << 63U));
            command.action = templ.action;
            command.domain = templ.domain;
            command.opcode = next ? templ.opcode : 2;
            command.resolved_value = templ.value_q16;
            command.duration_days = templ.duration_days;
            command.stacks = templ.stacks;
            command.command_key = templ.command_key;
            command.definition_key = templ.definition_key;
            command.payload = templ.payload;
            commands.push_back(std::move(command));
        }
    }
    return true;
}

void NativeIdeologyRuntime::rollback_synergies(
        CountryState &country,
        const IdeaState::Transition &transition) {
    const size_t count = std::min(transition.changed_synergy_ids.size(),
        transition.previous_synergy_active.size());
    for (size_t index = 0; index < count; ++index)
        set_synergy_active(country,
            transition.changed_synergy_ids[index],
            transition.previous_synergy_active[index] != 0);
}

void NativeIdeologyRuntime::rebuild_synergies(CountryState &country) {
    country.active_synergy_bits.assign(
        (_synergies.size() + 63U) / 64U, 0);
    for (int32_t synergy_id = 0;
            synergy_id < static_cast<int32_t>(_synergies.size());
            ++synergy_id)
        if (synergy_requirements_met(country, synergy_id))
            set_synergy_active(country, synergy_id, true);
}

int32_t NativeIdeologyRuntime::ideology_slot_cost(const CountryState &country) const {
    return country.ideology_slots_used;
}

int32_t NativeIdeologyRuntime::spirit_slot_cost(const CountryState &country) const {
    return country.spirit_slots_used;
}

void NativeIdeologyRuntime::insert_active_state(CountryState &country, int32_t idea_slot) {
    if (idea_slot < 0 || idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    const int32_t ideology_id = country.ideas[static_cast<size_t>(idea_slot)].ideology_id;
    auto found = std::lower_bound(country.active_state_indices.begin(),
        country.active_state_indices.end(), ideology_id,
        [&](int32_t current_slot, int32_t needle_id) {
            return country.ideas[static_cast<size_t>(current_slot)].ideology_id < needle_id;
        });
    if (found == country.active_state_indices.end() || *found != idea_slot)
        country.active_state_indices.insert(found, idea_slot);
    country.active_bits[static_cast<size_t>(ideology_id / 64)] |=
        1ULL << (ideology_id % 64);
}

void NativeIdeologyRuntime::remove_active_state(CountryState &country, int32_t idea_slot) {
    if (idea_slot < 0 || idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    const int32_t ideology_id = country.ideas[static_cast<size_t>(idea_slot)].ideology_id;
    auto found = std::lower_bound(country.active_state_indices.begin(),
        country.active_state_indices.end(), ideology_id,
        [&](int32_t current_slot, int32_t needle_id) {
            return country.ideas[static_cast<size_t>(current_slot)].ideology_id < needle_id;
        });
    if (found != country.active_state_indices.end() && *found == idea_slot)
        country.active_state_indices.erase(found);
    country.active_bits[static_cast<size_t>(ideology_id / 64)] &=
        ~(1ULL << (ideology_id % 64));
}

void NativeIdeologyRuntime::set_state_location(CountryState &country,
        int32_t idea_slot, uint8_t location) {
    if (idea_slot < 0 || idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
    if (state.location == location) return;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    if (state.location == IDEOLOGY)
        country.ideology_slots_used -= definition.ideology_cost;
    else if (state.location == NATIONAL_SPIRIT)
        country.spirit_slots_used -= definition.spirit_cost;
    const bool was_active = state.location != INACTIVE;
    const bool will_be_active = location != INACTIVE;
    state.location = location;
    if (location == IDEOLOGY)
        country.ideology_slots_used += definition.ideology_cost;
    else if (location == NATIONAL_SPIRIT)
        country.spirit_slots_used += definition.spirit_cost;
    if (!was_active && will_be_active) insert_active_state(country, idea_slot);
    else if (was_active && !will_be_active) remove_active_state(country, idea_slot);
    mark_instance_refresh_dirty();
}

uint8_t NativeIdeologyRuntime::next_free_slot(const CountryState &country,
        uint8_t location, int32_t exclude_ideology_id) const {
    if (location == INACTIVE) return 0;
    std::array<bool, 64> occupied{};
    for (const IdeaState &idea : country.ideas) {
        if (idea.ideology_id == exclude_ideology_id ||
                idea.location != location || idea.slot_index >= occupied.size())
            continue;
        occupied[static_cast<size_t>(idea.slot_index)] = true;
    }
    for (uint8_t slot = 0; slot < static_cast<uint8_t>(occupied.size());
            ++slot)
        if (!occupied[static_cast<size_t>(slot)]) return slot;
    return 63;
}

void NativeIdeologyRuntime::rebuild_country_derived(CountryState &country) {
    country.active_bits.assign(static_cast<size_t>(_idea_words), 0);
    country.active_state_indices.clear();
    country.ideology_slots_used = 0;
    country.spirit_slots_used = 0;
    country.pending_transition_count = 0;
    country.opinion_revision = 0;
    country.class_influence.clear();
    for (int32_t idea_slot = 0; idea_slot < static_cast<int32_t>(country.ideas.size());
            ++idea_slot) {
        ++_derived_rebuild_visits;
        const IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
        if (state.transition.active != 0)
            ++country.pending_transition_count;
        if (state.location == IDEOLOGY)
            country.ideology_slots_used +=
                _definitions[static_cast<size_t>(state.ideology_id)].ideology_cost;
        else if (state.location == NATIONAL_SPIRIT)
            country.spirit_slots_used +=
                _definitions[static_cast<size_t>(state.ideology_id)].spirit_cost;
        if (state.location != INACTIVE) {
            country.active_state_indices.push_back(idea_slot);
            country.active_bits[static_cast<size_t>(state.ideology_id / 64)] |=
                1ULL << (state.ideology_id % 64);
        }
    }
    std::sort(country.active_state_indices.begin(), country.active_state_indices.end(),
        [&](int32_t a, int32_t b) {
            return country.ideas[static_cast<size_t>(a)].ideology_id <
                country.ideas[static_cast<size_t>(b)].ideology_id;
        });
    rebuild_synergies(country);
}

void NativeIdeologyRuntime::append_pending_transition(CountryState &country,
        int32_t idea_slot) {
    int32_t country_slot = -1;
    if (!validate_country(country.handle, country_slot) || idea_slot < 0 ||
            idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    const IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
    _pending_transitions.push_back({
        country.handle, country_slot, idea_slot, state.generation});
}

void NativeIdeologyRuntime::rebuild_pending_transition_index() {
    _pending_transitions.clear();
    _pending_transition_cursor = 0;
    for (int32_t country_slot = 0; country_slot < static_cast<int32_t>(_countries.size()); ++country_slot) {
        CountryState &country = _countries[static_cast<size_t>(country_slot)];
        if (country.handle == 0) continue;
        for (int32_t idea_slot = 0; idea_slot < static_cast<int32_t>(country.ideas.size()); ++idea_slot) {
            ++_derived_rebuild_visits;
            const IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
            if (state.transition.active != 0)
                _pending_transitions.push_back({country.handle, country_slot, idea_slot, state.generation});
        }
    }
}
int32_t NativeIdeologyRuntime::unlocked_level(const IdeaState &state) const {
    if (state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size())) return -1;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    int32_t unlocked = -1;
    for (int32_t level = 0; level < definition.level_count; ++level) {
        if (state.understanding_q16 < _levels[definition.level_begin + level].threshold_q16) break;
        unlocked = level;
    }
    return unlocked;
}

void NativeIdeologyRuntime::reconcile_level(IdeaState &state) {
    const int32_t unlocked = unlocked_level(state);
    if (unlocked > state.level) {
        state.level = unlocked;
        ++state.generation;
        ++_levels_advanced;
    }
}

uint64_t NativeIdeologyRuntime::unentered_level_mask(const IdeaState &state,
                                                      int32_t through_level) const {
    if (through_level < 0) return 0;
    const int32_t capped = std::min(through_level, 63);
    const uint64_t available = capped == 63 ? ~0ULL : ((1ULL << (capped + 1)) - 1ULL);
    return available & ~state.entered_levels;
}

bool NativeIdeologyRuntime::emit_templates(uint64_t country_handle, int32_t ideology_id,
        int32_t level, int32_t begin, int32_t count, bool remove, int64_t day,
        uint64_t salt,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (count <= 0) return true;
    if (_effect_runtime == nullptr) { error = "ideology_effect_runtime_unavailable"; return false; }
    if (static_cast<int64_t>(commands.size()) + count >
            _max_transition_commands) {
        error = "ideology_transition_command_limit_exceeded";
        return false;
    }
    const std::vector<EffectTemplate> &templates = remove
        ? _persistent_templates : (salt == 0 ? _persistent_templates : _on_enter_templates);
    const int64_t tier_source_id = static_cast<int64_t>(
        (static_cast<uint64_t>(ideology_id + 1) << 32U) | static_cast<uint32_t>(level + 1));
    for (int32_t offset = 0; offset < count; ++offset) {
        const EffectTemplate &templ = templates[static_cast<size_t>(begin + offset)];
        // Persisted tier rows (salt 0) that resolve to a declarative managed
        // program are owned by reconcile_effect_activations(). Emitting them
        // here as well would apply the same effect twice. On-enter one-shots
        // keep using this batch: they are events, not state.
        if (salt == 0 && _effect_runtime != nullptr) {
            const std::string program = effect_program_key(templ.definition_key);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!program.empty() &&
                    _effect_runtime->family_effect_metadata_pod(program, metadata))
                continue;
        }
        // The APPLY and its matching REMOVE must mint the SAME effect identity.
        //
        // `enqueue_external_effect_batch_pod` derives the instance id from
        // (source_type, transition_source_id, first.effect_id, first.fire_sequence)
        // and that instance id becomes the Modifier row's `source_id`
        // (`effect_runtime.cpp`: NATIVE_MODIFIER_IDEOLOGY sets
        // `source_id = source_instance->id`). A REMOVE is matched by
        // `remove_unique_command`, which keys `unique_instances` on
        // (definition, scope, scope_id, source_type, source_id) and answers
        // `already_removed` on a miss -- so any difference here leaves the applied
        // row alive while reporting success.
        //
        // `remove` used to be mixed into this hash, which guaranteed that
        // difference: every unequip retired the slot and the binding but left the
        // national Modifier row in place, and the stat kept its buffed value.
        uint64_t hash = 1469598103934665603ULL;
        hash = mixv(hash, country_handle); hash = mixv(hash, ideology_id); hash = mixv(hash, level);
        hash = mixv(hash, begin + offset); hash = mixv(hash, salt);
        const int64_t effect_id = static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
        const int32_t opcode = remove ? 2 : templ.opcode; // Modifier COMMAND_REMOVE
        EffectRuntime::ExternalEffectCommandPod command;
        command.effect_id = effect_id;
        command.source_id = tier_source_id;
        command.program_key = "ideology.command";
        command.fire_sequence = static_cast<uint64_t>(offset + 1);
        command.action = templ.action;
        command.domain = templ.domain;
        command.opcode = opcode;
        command.resolved_value = templ.value_q16;
        command.duration_days = templ.duration_days;
        command.stacks = templ.stacks;
        command.command_key = templ.command_key;
        command.definition_key = templ.definition_key;
        command.payload = templ.payload;
        commands.push_back(std::move(command));
    }
    return true;
}

std::string NativeIdeologyRuntime::effect_program_key(
        const std::string &definition_key) {
    if (definition_key.empty()) return {};
    return "ideology.effect." + definition_key;
}

int64_t NativeIdeologyRuntime::effect_instance_id(uint64_t country_handle,
        int32_t ideology_id, uint8_t location, int32_t level,
        const std::string &program, uint64_t target_handle, int32_t layer) {
    // Pure function of the owning identity and the target. Anything that makes
    // the id depend on time, iteration order or counters leaks orphan
    // instances across a save/load round trip.
    uint64_t h = 1469598103934665603ULL;
    h = mixv(h, country_handle);
    h = mixv(h, ideology_id);
    h = mixv(h, location);
    h = mixv(h, level);
    h = mix(h, program.data(), program.size());
    h = mixv(h, target_handle);
    // Only for stacked programs. Mixing 0 unconditionally would renumber every
    // instance in every save, for an argument that is 0 for all of them.
    if (layer != 0) h = mixv(h, layer);
    const int64_t id = static_cast<int64_t>(h & 0x7fffffffffffffffULL);
    return id == 0 ? 1 : id;
}

bool NativeIdeologyRuntime::copy_source_state(const CountryState &country,
        const IdeaState &state, const IdeaState *&source) const {
    source = nullptr;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    if (_definitions[static_cast<size_t>(
            state.ideology_id)].copy_left_programs == 0)
        return false;
    if (state.location == INACTIVE || state.slot_index == 0)
        return false;
    const uint8_t wanted_slot = static_cast<uint8_t>(state.slot_index - 1);
    for (const IdeaState &candidate : country.ideas) {
        if (candidate.location != state.location ||
                candidate.slot_index != wanted_slot ||
                candidate.ideology_id == state.ideology_id)
            continue;
        source = &candidate;
        return true;
    }
    return false;
}

bool NativeIdeologyRuntime::copy_source_programs(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    const IdeaState *source = nullptr;
    if (!copy_source_state(country, state, source) || source == nullptr)
        return false;
    if (source->ideology_id < 0 ||
            source->ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    if (source->level < 0) return true;
    const Definition &definition = _definitions[
        static_cast<size_t>(source->ideology_id)];
    if (source->level >= definition.level_count) return true;
    // Legendary/rule cards are never copy sources, at any copier level. The
    // source program list is still the source's level list, never its live
    // Effect instance table.
    if (definition.copyable == 0) return true;
    const Level &row = _levels[
        static_cast<size_t>(definition.level_begin + source->level)];
    out.reserve(static_cast<size_t>(row.persistent_count));
    for (int32_t offset = 0; offset < row.persistent_count; ++offset)
        out.push_back(&_persistent_templates[
            static_cast<size_t>(row.persistent_begin + offset)]);
    return true;
}

void NativeIdeologyRuntime::collect_copied_legacy_templates(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()) ||
            state.level < 0)
        return;
    const Definition &definition = _definitions[
        static_cast<size_t>(state.ideology_id)];
    if (state.level >= definition.level_count) return;
    const Level &own_level = _levels[
        static_cast<size_t>(definition.level_begin + state.level)];
    if (definition.copy_left_programs == 0) {
        out.reserve(static_cast<size_t>(own_level.persistent_count));
        for (int32_t offset = 0; offset < own_level.persistent_count; ++offset)
            out.push_back(&_persistent_templates[
                static_cast<size_t>(own_level.persistent_begin + offset)]);
        return;
    }
    // `emit_level_effects` is the legacy Modifier batch. Managed rows are owned by
    // the Effect reconciler, not this path, but the copier's own national/price
    // rows must remain active even when its managed list comes from a neighbour.
    for (int32_t offset = 0; offset < own_level.persistent_count; ++offset) {
        const EffectTemplate *templ = &_persistent_templates[
            static_cast<size_t>(own_level.persistent_begin + offset)];
        const std::string program = effect_program_key(templ->definition_key);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (_effect_runtime != nullptr && !program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        out.push_back(templ);
    }
    std::vector<const EffectTemplate *> copied;
    if (!copy_source_programs(country, state, copied)) return;
    for (const EffectTemplate *templ : copied) {
        const std::string program = effect_program_key(templ->definition_key);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (_effect_runtime != nullptr && !program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        out.push_back(templ);
    }
}

void NativeIdeologyRuntime::apply_fan_out_ownership_filter(
        int32_t source_cell, int32_t ownership_scope,
        std::vector<int32_t> &cells) const {
    if (_economy_runtime == nullptr) return;
    if (ownership_scope == EffectRuntime::OWNERSHIP_ANY) return;
    // The source came out of OWN_TERRITORY, so its owner IS the card's country.
    // Read per source rather than once: a multi-country world can have sources in
    // different slots once the collector is widened, and a cached slot would silently
    // mis-filter.
    const int32_t source_country = _economy_runtime->cell_country_slot(source_cell);
    if (source_country < 0) return;
    cells.erase(
        std::remove_if(cells.begin(), cells.end(),
            [&](int32_t target) {
                // Three cases, not two: an unowned target is neither own nor "another
                // country", and FOREIGN must not swallow neutral land.
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    source_country, _economy_runtime->cell_country_slot(target));
                return !pk::ownership_accepts(ownership_scope, relation);
            }),
        cells.end());
}

void NativeIdeologyRuntime::apply_union_ownership_filter(
        int32_t country_slot, int32_t ownership_scope,
        std::vector<int32_t> &cells) const {
    if (_economy_runtime == nullptr) return;
    if (ownership_scope == EffectRuntime::OWNERSHIP_ANY) return;
    if (country_slot < 0) return;
    cells.erase(
        std::remove_if(cells.begin(), cells.end(),
            [&](int32_t target) {
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    country_slot, _economy_runtime->cell_country_slot(target));
                return !pk::ownership_accepts(ownership_scope, relation);
            }),
        cells.end());
}

bool NativeIdeologyRuntime::resolve_effect_targets(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        uint64_t selection_salt,
        std::vector<EffectTarget> &out) const {
    out.clear();
    if (country.handle == 0) { ++_targets_country_zero; return false; }
    // X5: the selector is the only part of the program metadata a country
    // rewrite replaces. Program conditions, cadence and command values remain
    // the shared catalog template.
    const EffectRuntime::FamilyEffectMetadataPod effective =
        effective_selector_metadata(country, program, metadata);
    if (effective.target_domain == 3) { // COUNTRY
        const uint32_t generation = static_cast<uint32_t>(country.handle >> 32U);
        if (generation == 0) return false;
        out.push_back({country.handle, generation,
            static_cast<int32_t>(Q16_ONE)});
        return true;
    }
    if (effective.target_domain == 0) { // FAMILY (X9-b)
        if (_economy_runtime == nullptr ||
            effective.target_selector_kind !=
                EffectRuntime::SELECTOR_FAMILY_OWNED)
            return false;
        const int32_t country_slot =
            static_cast<int32_t>(country.handle & 0xffffffffULL);
        // Belt and braces: the compile-time validator
        // (`effect_runtime.cpp`, the FAMILY_OWNED clause) already rejects an authored
        // family count outside [1, 32], so this clamp cannot silently shrink anything.
        // It stays because `effective` here can come from a stored/serialized
        // definition that predates that check.
        const int32_t cap = std::clamp(
            effective.target_selector_param[0], 1,
            static_cast<int32_t>(EffectRuntime::SELECTOR_MAX_CELLS));
        const int32_t authored_min = effective.target_selector_param[1];
        const int32_t min_branches =
            _economy_runtime->family_target_min_branches_for_test(authored_min);
        std::vector<uint64_t> handles;
        _economy_runtime->collect_family_effect_target_handles(
            country_slot, min_branches, cap, handles);
        for (const uint64_t handle : handles) {
            const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
            if (generation == 0) continue;
            out.push_back({handle, generation,
                static_cast<int32_t>(Q16_ONE)});
        }
        return !out.empty();
    }
    // Settlement cell (2) and building/resource within a cell (5) both target
    // cells; the adapter maps them to ModifierRuntime's GROUP scope.
    if (effective.target_domain != 2 && effective.target_domain != 5) {
        ++_targets_domain_gate; return false;
    }
    if (_economy_runtime == nullptr) { ++_targets_economy_null; return false; }
    const int32_t country_slot = static_cast<int32_t>(country.handle & 0xffffffffULL);
    // TODO: replace with a real capital / city-cell anchor once the game models
    // one. Until then a country's cell-scoped effect is anchored on its first
    // owned cell, which keeps the selector deterministic and replayable.
    const int32_t anchor = _economy_runtime->country_anchor_cell(country_slot);
    if (anchor < 0) { ++_targets_anchor_neg; return false; }
    std::vector<int32_t> cells;
    std::vector<int32_t> source_counts;
    // X1: per-source evaluation. Kinds 14/15 mean "for every owned cell that
    // matches the source tag, expand one radial fan-out and union the results".
    // Doing it here (rather than inside the economy selector) keeps the
    // territory walk and the neighbour walk as two existing, separately tested
    // primitives, and keeps the union/dedup/cap rule in one place.
    if (effective.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_COUNT) {
        const EffectRuntime::SourceCountSelector selector =
            EffectRuntime::decode_source_count_selector(
                effective.target_selector_param);
        if (selector.tag <= 0 || selector.radius < 1 || selector.radius > 4 ||
                selector.cap < 1) {
            return false;
        }
        // X1-b sources are the country's OWN tagged cells. Walking the territory
        // directly is important: OWN_TERRITORY caps at 32, which would silently
        // undercount a country with more matching sources.
        const int32_t tag = selector.tag - 1;
        if (tag >= _economy_runtime->target_tag_count()) return false;
        std::vector<int32_t> sources;
        _economy_runtime->collect_own_tagged_cells(country_slot, tag, sources);
        if (sources.empty()) { ++_targets_fanout_no_source; return false; }
        std::sort(sources.begin(), sources.end());
        sources.erase(std::unique(sources.begin(), sources.end()), sources.end());

        // Source counts are reconstructed during reconcile, never persisted. Keep
        // one accumulator per grid cell (bounded and allocation-free inside the
        // source loop) instead of a hash map: `effect_stable_cap` may retain cells
        // whose count is low, and the report is hot enough that Dictionary /
        // Variant work would be the wrong tool anyway.
        const int32_t grid_cells = _economy_runtime->cell_count();
        if (grid_cells <= 0) return false;
        source_counts.assign(static_cast<size_t>(grid_cells), 0);
        // Radius 1/2 use the precomputed six-neighbour table directly. BFS is
        // reserved for 3/4, where it is the only bounded way to reach 37/61 cells.
        std::vector<int32_t> ring_1;
        std::vector<int32_t> ring_2;
        std::vector<int32_t> frontier;
        std::vector<int32_t> next;
        std::vector<uint8_t> seen;
        const int32_t sources_count = static_cast<int32_t>(sources.size());
        for (int32_t source_index = 0; source_index < sources_count;
                ++source_index) {
            const int32_t source = sources[static_cast<size_t>(source_index)];
            if (selector.radius <= 2) {
                ring_1.clear();
                for (int32_t direction = 0; direction < 6; ++direction) {
                    const int32_t neighbor =
                        _economy_runtime->building_neighbor(source, direction);
                    if (neighbor < 0 || neighbor >= grid_cells) continue;
                    if (neighbor == source) continue;
                    ring_1.push_back(neighbor);
                }
                std::sort(ring_1.begin(), ring_1.end());
                ring_1.erase(std::unique(ring_1.begin(), ring_1.end()),
                    ring_1.end());
                for (const int32_t cell : ring_1)
                    ++source_counts[static_cast<size_t>(cell)];
                if (selector.radius == 2) {
                    seen.assign(static_cast<size_t>(grid_cells), 0);
                    seen[static_cast<size_t>(source)] = 1;
                    for (const int32_t cell : ring_1)
                        seen[static_cast<size_t>(cell)] = 1;
                    // Visit the six neighbours of every first-ring cell. The
                    // source cannot come back through a cycle because it is
                    // marked before the walk.
                    ring_2.clear();
                    for (const int32_t cell : ring_1) {
                        for (int32_t direction = 0; direction < 6; ++direction) {
                            const int32_t neighbor =
                                _economy_runtime->building_neighbor(cell, direction);
                            if (neighbor < 0 || neighbor >= grid_cells) continue;
                            if (seen[static_cast<size_t>(neighbor)] != 0) continue;
                            seen[static_cast<size_t>(neighbor)] = 1;
                            ring_2.push_back(neighbor);
                        }
                    }
                    for (const int32_t cell : ring_2)
                        ++source_counts[static_cast<size_t>(cell)];
                }
                continue;
            }
            // R=3..4: a bounded BFS. The origin is seen before expansion and is
            // never emitted, so a source does not count itself even on a cycle.
            frontier.clear();
            seen.assign(static_cast<size_t>(grid_cells), 0);
            seen[static_cast<size_t>(source)] = 1;
            frontier.push_back(source);
            for (int32_t depth = 1;
                    depth <= selector.radius && !frontier.empty(); ++depth) {
                next.clear();
                for (const int32_t cell : frontier) {
                    for (int32_t direction = 0; direction < 6; ++direction) {
                        const int32_t neighbor =
                            _economy_runtime->building_neighbor(cell, direction);
                        if (neighbor < 0 || neighbor >= grid_cells) continue;
                        if (seen[static_cast<size_t>(neighbor)] != 0) continue;
                        seen[static_cast<size_t>(neighbor)] = 1;
                        next.push_back(neighbor);
                        ++source_counts[static_cast<size_t>(neighbor)];
                    }
                }
                frontier.swap(next);
            }
        }
        cells.reserve(static_cast<size_t>(grid_cells));
        // OWNERSHIP SCOPE (same meaning as kinds 14/15).
        //
        // A target's `source_counts` entry counts how many of THIS country's sources
        // reach it, so the count itself is already country-relative; what was missing is
        // the bound on WHOSE cells may be hit. Dropping foreign cells here is correct
        // and does not change any surviving cell's scale.
        for (int32_t cell = 0; cell < grid_cells; ++cell) {
            if (source_counts[static_cast<size_t>(cell)] <= 0) continue;
            if (selector.ownership_scope != EffectRuntime::OWNERSHIP_ANY) {
                // `cell_country_slot` directly, NOT `collect_own_tagged_cells(-1)`:
                // that helper returns an EMPTY list for `tag < 0`
                // (`economy_runtime_family_buff.cpp:1010`), which would have made
                // "is this cell mine" false for every cell and dropped the entire
                // target set under the new OWN default.
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    country_slot, _economy_runtime->cell_country_slot(cell));
                if (!pk::ownership_accepts(selector.ownership_scope, relation))
                    continue;
            }
            cells.push_back(cell);
        }
        ++_ownership_filtered_resolves;
        if (selector.ownership_scope == EffectRuntime::OWNERSHIP_OWN)
            ++_ownership_own_resolves;
        else if (selector.ownership_scope == EffectRuntime::OWNERSHIP_FOREIGN)
            ++_ownership_foreign_resolves;
        std::sort(cells.begin(), cells.end());
        effect_stable_cap(cells, selector.target_cap,
            static_cast<uint64_t>(anchor), selection_salt, &_selector_stats);
    } else if (effective.target_selector_kind ==
            EffectRuntime::SELECTOR_TAG_SOURCE_R1 ||
            effective.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R2) {
        const int32_t tag = effective.target_selector_param[1];
        // 0 would mean "every owned cell", which for a radial fan-out is a
        // country-sized sweep disguised as a card. Requiring the tag makes the
        // cost of the card visible in the data.
        if (tag <= 0) { ++_targets_fanout_no_tag; return false; }
        // `param[0]` carries the ownership scope in bits 12..13, so the cap must be
        // masked out of it. Without this the cap silently became "32" for every card
        // because `4096 > 0` made the ternary true and `min(4096, 32) == 32`.
        const int32_t authored_cap =
            effective.target_selector_param[0] &
            ((int32_t{1} << EffectRuntime::OWNERSHIP_SCOPE_SHIFT) - 1);
        // NO 32 CAP ON THE SOURCE COUNT (decision, 2026-10-28).
        //
        // This used to clamp to `SELECTOR_MAX_CELLS` (32), which meant a country with
        // 300 tagged cells only ever fanned out from 32 of them. Kinds 14/15 are
        // classified UNBOUNDED by `selector_cell_cap.h` (`selector_cell_ceiling`
        // returns `kSelectorNoCellCap` for them), so a 32 here contradicted that
        // classification -- and all five shipped kind 14/15 cards authored
        // `param[0] = 32`, i.e. the clamp was doing real work and hiding it.
        //
        // Now: an authored cap is honoured at face value, and 0 means "the kind's own
        // default", which for an unbounded kind is no cap. The five cards were moved to
        // `param[0] = 0` in content for the same change.
        //
        // COST: coverage now scales with the country's tagged cell count. That is the
        // point of the migration, but it is also more work per resolve -- see the
        // release note; the measurement is blocked by native tags, and that is stated
        // rather than glossed.
        const int32_t cap = authored_cap > 0
            ? authored_cap
            : pk::kSelectorNoCellCap;
        std::vector<int32_t> sources;
        _economy_runtime->collect_effect_target_cells(anchor,
            EffectRuntime::SELECTOR_OWN_TERRITORY, cap, tag, sources,
            selection_salt, &_selector_stats);
        if (sources.empty()) { ++_targets_fanout_ring_empty; return false; }
        const bool first_ring =
            effective.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R1;
        const int32_t ring_kind = first_ring
            ? EffectRuntime::SELECTOR_NEIGHBORS_R1
            : EffectRuntime::SELECTOR_NEIGHBORS_R2;
        // One cell's own fan-out is capped by the same ceiling as the union, so
        // a dense cluster of sources cannot make a single source unbounded.
        // The RING size is bounded geometrically (R1 = 6, R2 = 18), which
        // `collect_effect_target_cells` applies itself. Clamping to 32 here was a
        // second, redundant ceiling that never bound -- drop it with the source cap so
        // the intent is "no policy cap on this path" rather than "32 is big enough".
        const int32_t ring_cap = static_cast<int32_t>(pk::selector_cell_ceiling(ring_kind));
        // OWNERSHIP SCOPE for the fan-out (plan: "周围地块" must mean the player's own
        // land by default).
        //
        // The radial walk itself is ownership-blind: `collect_effect_target_cells`
        // follows `_building_neighbors` and `accepts()` only checks terrain/resource/
        // predicate (`economy_runtime_family_buff.cpp:2646-2664`). So a border card
        // reached FOREIGN cells. Filtering HERE rather than inside the selector keeps
        // the economy's selector API unchanged and costs one lookup per ring cell,
        // which is bounded by `ring_cap` (<= 32).
        const int32_t ownership_scope =
            EffectRuntime::decode_ownership_scope(
                effective.target_selector_param);
        // ONE batch dilation over the whole source set.
        //
        // The per-source loop here allocated and zeroed a `cells`-sized `seen` buffer
        // on every call (`economy_runtime_family_buff.cpp:2663`): a 6400-cell country
        // with 6400 sources paid ~41 MB of allocate-and-zero per resolve, which is what
        // pushed a single resolve past the 1 ms slice gate once the source cap was
        // removed. `dilate_cell_set` does the same union in one pass with a stamp-based
        // visited buffer, so it allocates nothing per source and clears nothing.
        //
        // Semantics are unchanged: union of the rings, deduplicated, anchor excluded
        // (kinds 6/7 contract). The per-source ring cap never bound (geometric reach is
        // 6/18) so dropping it changes nothing.
        (void)ring_cap;
        _economy_runtime->dilate_cell_set(sources, first_ring ? 1 : 2, cells);
        // Every source came from the same OWN_TERRITORY scan, so one country slot covers
        // the union and the filter runs once instead of N times.
        apply_union_ownership_filter(
            static_cast<int32_t>(country.handle & 0xffffffffULL), ownership_scope, cells);
        // Stable cap over the UNION, keyed on the anchor cell: resizing the
        // ascending list kept the lowest ids, which is the same corner of the
        // map for every card.
        effect_stable_cap(cells, cap, static_cast<uint64_t>(anchor),
            selection_salt, &_selector_stats);
        ++_ownership_filtered_resolves;
        if (ownership_scope == EffectRuntime::OWNERSHIP_OWN)
            ++_ownership_own_resolves;
        else if (ownership_scope == EffectRuntime::OWNERSHIP_FOREIGN)
            ++_ownership_foreign_resolves;
    } else {
        _economy_runtime->collect_effect_target_cells(anchor,
            effective.target_selector_kind, effective.target_selector_param[0],
            effective.target_selector_param[1], cells, selection_salt,
            &_selector_stats);
    }
    if (cells.empty()) ++_targets_collected_empty;
    const uint32_t generation = static_cast<uint32_t>(country.handle >> 32U);
    for (const int32_t cell : cells) {
        if (cell < 0) continue;
        int32_t scale_q16 = static_cast<int32_t>(Q16_ONE);
        if (effective.target_selector_kind ==
                EffectRuntime::SELECTOR_TAG_SOURCE_COUNT) {
            const EffectRuntime::SourceCountSelector selector =
                EffectRuntime::decode_source_count_selector(
                    effective.target_selector_param);
            const int32_t count = cell >= 0 &&
                static_cast<size_t>(cell) < source_counts.size()
                ? std::max(0, source_counts[static_cast<size_t>(cell)]) : 0;
            scale_q16 = static_cast<int32_t>(
                static_cast<int64_t>(std::min(count, selector.cap)) *
                Q16_ONE / selector.cap);
            ++_source_count_evaluations;
        }
        out.push_back({static_cast<uint64_t>(cell), generation, scale_q16});
    }
    // One truncation per resolve that cut something. The flag is cleared so a
    // later untruncated resolve cannot inherit the previous one's verdict;
    // `matched_total` stays as the last reading for the report.
    if (_selector_stats.truncated != 0) {
        ++_selector_truncations;
        _selector_stats.truncated = 0;
    }
    return !out.empty();
}

CellProgramFacts NativeIdeologyRuntime::cell_program_facts_for(
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const IdeaState &state) const {
    CellProgramFacts facts;
    facts.target_domain = metadata.target_domain;
    facts.lifecycle = metadata.lifecycle;
    facts.duration_days = metadata.duration_days;
    facts.stack_policy = metadata.stack_policy;
    facts.max_stacks = metadata.max_stacks;
    facts.selector_kind = metadata.target_selector_kind;
    // READ_STATE dependence is not on the metadata pod; it is the program's
    // instruction stream. `exact_metric_mask` marks every metric a Ramp reads,
    // and a Ramp that also reads STATE would be history-dependent, so
    // `metric_mask` being non-empty is NOT the test. What matters is whether the
    // program is a Ramp at all: a Ramp's magnitude tracks a live metric, which the
    // constant-only M1 layer cannot reproduce, so it must be reported as
    // `ramp_not_yet_supported` rather than smuggled in as a constant.
    const bool has_metric_input = metadata.metric_mask.is_any();
    (void)state;
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (_effect_runtime != nullptr &&
            _effect_runtime->program_modifier_commands(program, commands)) {
        for (const EffectRuntime::ProgramModifierCommand &command : commands) {
            CellProgramCommandFacts row;
            // `value_mode` comes from the COMMAND DEFINITION, not from an
            // assumption about today's content. Plan 22 §4.4 condition 4 turns on
            // whether the magnitude is a CONSTANT or read from the stack top / a
            // metric, so hard-coding it here would silently mis-classify the first
            // card that authors a constant.
            row.value_mode = command.value_mode;
            row.stacks = command.stacks;
            row.duration_days = command.duration_days;
            // A DEFINITION resolves when the modifier runtime knows it. The
            // synthesised city families are produced by `compile_native_catalog`,
            // so they resolve here exactly like the .tres ones -- that is the
            // 101-of-325 trap §4.4 condition 3 names.
            std::vector<ModifierRuntime::ResolvedTerm> terms;
            row.definition_resolved =
                _modifier_runtime != nullptr &&
                _modifier_runtime->resolve_definition_terms(
                    command.definition_key, terms);
            // City stats are forced SUM by the catalog validator
            // (`modifier_catalog.gd:448-457`), so a resolved city term is SUM by
            // construction; a non-SUM term would be a catalog defect.
            row.all_terms_sum = row.definition_resolved;
            // M1 only handles CONSTANT magnitudes. `has_metric_input` turns the
            // decision into `ramp_not_yet_supported` (a delay to M3), not
            // `non_constant_value_mode` (a permanent exclusion).
            row.stack_top_is_constant = !has_metric_input;
            row.has_metric_ramp = has_metric_input;
            facts.commands.push_back(row);
        }
    }
    return facts;
}

void NativeIdeologyRuntime::resolve_program_fold_terms(
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const std::string &program,
        std::vector<DerivedProgramContribution::Term> &out,
        bool count_diagnostics) const {
    out.clear();
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (_effect_runtime == nullptr ||
            !_effect_runtime->program_modifier_commands(program, commands) ||
            _modifier_runtime == nullptr)
        return;
    for (const EffectRuntime::ProgramModifierCommand &command : commands) {
        std::vector<ModifierRuntime::ResolvedTerm> terms;
        if (!_modifier_runtime->resolve_definition_terms(
                command.definition_key, terms))
            continue;  // counted by the materializer's missing_stat
        const int64_t magnitude = std::clamp<int64_t>(
            command.value_q16, 0, ModifierRuntime::MAX_MAGNITUDE_Q16);
        // ── M3: a metric-fed ramp must stay a LIVE function ──────
        //
        // `command.value_q16` is only meaningful when the magnitude is
        // a compile-time constant. For a Ramp it holds whatever the top
        // of the value stack was, NOT the program's output, so folding it
        // here would freeze the effect at the metric value seen during
        // materialise -- precisely the stale "threshold bucket" that
        // plan §15.5 forbids.
        //
        // So the term records WHICH metric it follows and at what scale,
        // and the materializer evaluates it per cell (the shipping stack
        // machine is already reachable through
        // `evaluate_program_magnitude_for_metrics`).
        //
        // A program reading several metrics would need a per-term
        // distinction no authored content currently requires; the FIRST
        // readable id is recorded so the choice is explicit rather than
        // silently made during evaluation.
        // A Ramp is exactly "not a compile-time constant AND reads a
        // metric": `value_mode != VALUE_CONSTANT` alone would also catch
        // a stack-top command that reads no metric, and
        // `metric_mask.is_any()` alone would catch a program whose
        // CONDITIONS read a metric while its magnitude stays constant.
        const bool ramp = command.value_mode !=
                EffectRuntime::VALUE_CONSTANT &&
            metadata.metric_mask.is_any();
        // Diagnostic: a ramp card that reports `taken=0 deferred=0` is
        // indistinguishable from one whose metrics never reached this
        // branch. These counters say which half of the condition failed.
        //
        // NOT counted when the caller only wants the digest: the applied-basis
        // rebuild runs on every capture, and a save must not move a number that
        // fixtures read as an exact measurement of the fold.
        if (count_diagnostics &&
                command.value_mode != EffectRuntime::VALUE_CONSTANT) {
            ++_ramp_candidates;
            if (metadata.metric_mask.is_any()) ++_ramp_metric_ok;
        }
        int32_t ramp_metric_id = -1;
        if (ramp) {
            for (int32_t id = 0; id < MetricMask::CAPACITY; ++id) {
                if (metadata.metric_mask.test(id)) {
                    ramp_metric_id = id;
                    break;
                }
            }
        }
        for (const ModifierRuntime::ResolvedTerm &term : terms) {
            DerivedProgramContribution::Term row;
            row.stat_id = term.stat_id;
            row.operation = term.operation;
            // Plan §5.4: `term.add * stacks * magnitude`. The sign
            // lives in the DEFINITION (a `.cut` twin is a SUBTRACT
            // term whose value is negative), never in the magnitude,
            // because magnitudes are clamped to [0, 4].
            const double scaled_magnitude =
                static_cast<double>(magnitude) /
                static_cast<double>(Q16_ONE);
            const double stacks =
                static_cast<double>(std::max(1, command.stacks));
            if (ramp && ramp_metric_id >= 0) {
                // The resolved term value becomes the SCALE; the
                // magnitude arrives per cell from the sample. `add` and
                // `factor` stay neutral here because the materializer
                // substitutes the sampled value for them -- leaving a
                // constant in `add` would double-count.
                row.magnitude_source =
                    DerivedProgramContribution::MagnitudeSource::RampMetric;
                row.metric_id = ramp_metric_id;
                // THE PROGRAM OWNS THE MAGNITUDE, not `term.value`.
                //
                // An earlier version scaled by `term.value * stacks / Q16`
                // and claimed in a comment that "the authored MIN/MAX inside
                // the instruction stream already bound the sample". That is
                // false: the derived path never executes the instruction
                // stream, so it sampled the RAW metric.
                //
                // Measured on `salt_monopoly_l1`
                // (`CONST 655 -> READ_METRIC -> CONST 983040 -> MIN -> MUL
                // -> EMIT`): the interpreter gives a constant 9825 while the
                // derived path gave 40 and 120 for the same two inputs, and
                // the contribution saturated the stat at its clamp_max
                // (M5-13). The key travels with the term so the materializer
                // can ask the stack machine instead.
                row.program_key = intern_program_key(program);
                row.ramp_scale = term.value * stacks /
                    static_cast<double>(Q16_ONE);
                row.ramp_has_ceil = false;
                row.add = 0.0;
                row.factor = 1.0;
            } else {
                row.add = term.operation == ModifierRuntime::ADD
                    ? term.value * stacks * scaled_magnitude : 0.0;
                row.factor = term.operation == ModifierRuntime::ADD
                    ? 1.0 : std::pow(term.value, stacks);
            }
            out.push_back(row);
        }
    }
}

bool NativeIdeologyRuntime::resolve_contribution_templates(
        const CountryState &country, const IdeaState &state,
        int32_t &contribution_level,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    contribution_level = -1;
    if (state.location == INACTIVE) return false;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    // ── WHICH LEVEL DOES A PENDING CARD CONTRIBUTE? (plan §10.1) ─────────────
    //
    // "pending 期间使用旧基础": a pending TRANSITION serves the previous level, and a
    // pending EQUIP has `previous_location == INACTIVE`, i.e. the card was not
    // equipped before, so it contributes NOTHING until its ACK lands.
    int32_t level = state.level;
    if (state.transition.active != 0) {
        if (state.transition.previous_location == INACTIVE) return false;
        if (state.transition.previous_level < 0) return false;
        level = state.transition.previous_level;
    }
    if (level < 0 || level >= definition.level_count) return false;
    contribution_level = level;
    if (definition.copy_left_programs != 0) {
        // A copier never falls back to its own managed list. No left slot (or
        // a noncopyable source) means it has no managed activations.
        (void)copy_source_programs(country, state, out);
    } else {
        const Level &row = _levels[
            static_cast<size_t>(definition.level_begin + level)];
        out.reserve(static_cast<size_t>(row.persistent_count));
        for (int32_t offset = 0; offset < row.persistent_count; ++offset)
            out.push_back(&_persistent_templates[
                static_cast<size_t>(row.persistent_begin + offset)]);
    }
    return true;
}

bool NativeIdeologyRuntime::collect_effect_activations(
        const CountryState &country, const IdeaState &state,
        std::vector<EffectActivation> &out,
        std::vector<DerivedProgramContribution> *out_derived) const {
    out.clear();
    if (_effect_runtime == nullptr) return true;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return true;
    ++_collect_entries;
    // ── WHICH LEVEL DOES A PENDING CARD CONTRIBUTE? (plan §10.1) ─────────────
    //
    // The plan says: "pending 期间使用旧基础：升级保留旧等级，卸卡保留旧贡献，尚未确认的装卡
    // 不产生贡献". This implements it.
    //
    // `start_transition` writes `state.level = target` at REQUEST time (`:3598`), so
    // reading `state.level` here served the NEW level's magnitudes while the transition's
    // Effect transactions had not been ACKed at all. Measured on a level-up with
    // `transition_transaction_statuses == [1, 1]` (both PLANNED, zero ACKs): the covered
    // cell already read the L2 add 0.08000183 instead of the L1 0.05000305. Settling then
    // changed nothing, which is exactly why a content check could not see it -- only
    // comparing the pending window against the settled state could (M5-69).
    //
    // `:5006-5007` -- the daily understanding accrual for this SAME card -- already does
    // it right:
    //
    //     growth_level = state->transition.active != 0 ? previous_level : state->level
    //
    // The two halves of one card disagreed. This makes the contribution half agree, and
    // adds the other half of the same rule: a pending EQUIP has
    // `previous_location == INACTIVE`, i.e. the card was not equipped before, so it must
    // contribute NOTHING until its ACK lands.
    if (state.location == INACTIVE) return true;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    int32_t contribution_level = -1;
    std::vector<const EffectTemplate *> active_templates;
    // The level-selection rule lives in ONE place now
    // (`resolve_contribution_templates`), because the applied-program basis has to
    // read the same level: a second copy is exactly the M5-69 defect, where the
    // contribution half and the accrual half disagreed about a pending transition.
    if (!resolve_contribution_templates(country, state, contribution_level,
            active_templates))
        return true;
    for (const EffectTemplate *templ_ptr : active_templates) {
        ++_collect_templates;
        const EffectTemplate &templ = *templ_ptr;
        const std::string program = effect_program_key(templ.definition_key);
        if (program.empty()) { ++_collect_program_empty; continue; }
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program, metadata)) {
            // No declarative program: the row stays on the legacy batch.
            ++_collect_pod_fail;
            // Record WHICH program: a bare count cannot tell "the card never became
            // active" apart from "the card is active but its program is missing".
            if (_collect_pod_fail_keys.size() < 8)
                _collect_pod_fail_keys.push_back(program);
            continue;
        }
        // Record the SUCCESSES too: a cost entry legitimately fails POD, so the failure
        // list alone cannot say whether the card's real effect resolved.
        if (_collect_pod_ok_keys.size() < 8)
            _collect_pod_ok_keys.push_back(program);
        (void)state;
        std::vector<EffectTarget> targets;
        const bool targets_ok = resolve_effect_targets(country, state, program,
            metadata, effect_program_hash(program), targets);
        if (!targets_ok) { ++_collect_targets_fail; continue; }

        // ── Backend split (plan 22 §4.4 / §4.5 / I01) ──────────────────────
        //
        // The eligibility column is consulted ONCE, here. A DerivedCell program
        // contributes rows to the Modifier derived layer and creates NO
        // instances -- which is what removes the 32-cell cap for it, because the
        // cap below exists only to bound the instance table.
        //
        // Everything else keeps the instance path unchanged. I01 forbids one
        // program having two backends in the same configuration, so this is an
        // exclusive branch, not an addition.
        const CellProgramDecision backend =
            decide_cell_program_backend(cell_program_facts_for(
                program, metadata, state));
        // ── I01 is decided by CAPABILITY + ROLLOUT, not by the caller ─────
        //
        // This used to require `out_derived != nullptr` as well, which meant the
        // INSTANCE call site (`reconcile_effect_activations`, :2483, passes nullptr)
        // ignored the rollout entirely while the DERIVED call site
        // (`step_derived_rebuild`) honoured it. With a batch enabled both ran,
        // so the same program created instances AND contributed rows -- a direct
        // violation of I01 ("one program, one backend") and the reason the M4
        // per-source scale fix appeared to do nothing: the value the fixture read
        // came from the surviving INSTANCE, not from the derived row
        // (measured `present=[1,1,1,1]`, see M4-3).
        //
        // The condition is now "should this program be derived", and the caller only
        // decides whether it CAN receive rows. A derived program is skipped by the
        // instance path either way.
        const bool derive_this_program =
            cell_program_rollout_enabled(metadata.target_selector_kind) &&
            backend.backend == CellProgramBackend::DerivedCell;
        if (derive_this_program && out_derived == nullptr) {
            // Derived backend, but this call site collects no rows: emit NOTHING so
            // the instance path cannot double-apply it. `step_derived_rebuild`
            // is the only producer of the derived rows.
            continue;
        }
        if (derive_this_program) {
            // ── One contribution PER TARGET, not one per program ──────────
            //
            // `EffectTarget` carries `magnitude_scale_q16`
            // (ideology_runtime.h:456), and for SELECTOR_TAG_SOURCE_COUNT the
            // instance path normalises it to `min(count, cap) / cap`
            // (ideology_runtime.cpp:2079-2081). Collecting every cell into ONE
            // contribution threw that scale away, so a cell bracketed by two
            // sources read 1.23999 where the instance path reads 1.12 -- a
            // difference of exactly one source contribution (measured, see
            // artifacts/ideology-cell-layer/m4/M4-2-per-source-scale-rootcause.md).
            //
            // Emitting one contribution per target keeps the fold in the
            // materializer unchanged (it already walks contribution -> cells) and
            // lets each cell carry its own scale.
            // ── school strength must reach the DERIVED backend too ────────
            //
            // It used to be applied only on the instance path, which multiplies
            // `activation_scale_q16` by `school_strength_scale_q16` (the LEGACY branch
            // below does exactly that). So a school's strength affected its
            // country-domain cards and silently did nothing for its kind-12 cell cards
            // -- the majority of the catalog. A mechanism that works on one of two
            // backends is worse than one that works on neither, because it lies: a
            // designer writes "agrarian school strength +25%", verifies it on a
            // country-domain card, and most agrarian cards never move.
            //
            // This mirrors the instance path exactly, INCLUDING its self-reference
            // guard: a card that itself writes its own school's strength stat must not
            // then be scaled by it.
            //
            // Zero-risk when written: no shipped content writes any of the six
            // `country.ideology.school_strength_factor.*` stats (measured: zero
            // modifier-definition terms target them), so the factor is 1.0 in every
            // shipped configuration and this multiplies by 1.0. It only starts to
            // matter the day content drives the stat -- which is the point: doing it
            // now is free, doing it then is a re-balance of every derived card.
            double derived_school_scale = 1.0;
            {
                const int32_t school_index = definition.school_index;
                if (!program_writes_school_strength(program, school_index)) {
                    derived_school_scale = static_cast<double>(
                        school_strength_scale_q16(country, school_index)) /
                        static_cast<double>(Q16_ONE);
                }
            }
            // I01: the backend must not change what a program does. The instance branch
            // scales a copier's copied programs by 1.2x at level >= 2; without the same
            // term here a derived copier would silently drop that bonus.
            //
            // Measured: shipped content has exactly one copier
            // (idea.algorithmic_governance) and its effects target the Modifier domain,
            // not cells, so this is a no-op today. It stops being one the moment a copier
            // targets cells -- which is precisely what I01 is for.
            double derived_copy_scale = 1.0;
            if (definition.copy_left_programs != 0 && state.level >= 2)
                derived_copy_scale = static_cast<double>(kCopierLevelTwoScaleQ16) /
                    static_cast<double>(Q16_ONE);
            std::vector<DerivedProgramContribution> per_target;
            per_target.reserve(targets.size());
            for (const EffectTarget &t : targets) {
                DerivedProgramContribution single;
                single.source_country = country.handle;
                single.backend = CellProgramBackend::DerivedCell;
                single.cells.push_back(static_cast<int32_t>(t.handle));
                single.magnitude_scale =
                    static_cast<double>(t.magnitude_scale_q16) /
                    static_cast<double>(Q16_ONE) * derived_school_scale *
                    derived_copy_scale;
                per_target.push_back(std::move(single));
            }
            std::vector<DerivedProgramContribution::Term> fold_terms;
            resolve_program_fold_terms(metadata, program, fold_terms, true);
            for (const DerivedProgramContribution::Term &row : fold_terms) {
                // A SUBTRACT term arrives as ADD with a negative value
                // from the resolver, so a `.cut` card must fold its
                // magnitude negatively rather than being dropped.
                for (DerivedProgramContribution &single : per_target) {
                    DerivedProgramContribution::Term scaled = row;
                    // `magnitude_scale` is 1.0 for every selector except
                    // TAG_SOURCE_COUNT, so this is a no-op for kinds 12/14/15.
                    scaled.add *= single.magnitude_scale;
                    if (scaled.operation != 0)
                        scaled.factor = std::pow(scaled.factor,
                            single.magnitude_scale);
                    single.terms.push_back(scaled);
                }
            }
            // Hand to the caller's accumulator; `collect_effect_activations`
            // stays a pure collector so `reconcile_effect_activations` (and the
            // pod mirror) can decide when to materialise.
            for (DerivedProgramContribution &single : per_target) {
                out_derived->push_back(std::move(single));
                ++_collect_derived_emitted;
            }
            continue;  // no instance, no cap, no ACK
        }
        // LEGACY INSTANCE PROTECTION: one instance per resolved target, capped so a
        // wide selector cannot flood the instance table.
        //
        // This branch is reached ONLY by programs the derived layer did not take
        // (`continue` above handles those). So the 32 here bounds INSTANCES, not cell
        // coverage -- a derived card covers the whole territory with zero instances.
        if (static_cast<int32_t>(targets.size()) >
                EffectRuntime::LEGACY_INSTANCE_MAX_CELLS)
            targets.resize(static_cast<size_t>(
                EffectRuntime::LEGACY_INSTANCE_MAX_CELLS));
        // ADD_STACK rows own one instance PER LAYER, not one instance carrying a
        // stack count: the whole point of L2-8 is that layers can expire
        // independently, and a single instance has a single `duration_days`. Any
        // other policy keeps exactly one instance, so their ids are unchanged.
        const bool layered = metadata.stack_policy == 2; // ADD_STACK
        const int32_t layers = layered
            ? std::clamp(templ.stacks, 1, std::max(1, metadata.max_stacks)) : 1;
        // Hoisted out of the target x layer loops: the value depends only on the
        // country, the program, and the copier level, so a 32-cell x 3-layer row
        // would otherwise rescan every synergy 96 times for the same answer.
        const int32_t copy_scale_q16 =
            definition.copy_left_programs != 0 && state.level >= 2
                ? kCopierLevelTwoScaleQ16 : static_cast<int32_t>(Q16_ONE);
        int64_t activation_scale_q16 =
            static_cast<int64_t>(magnitude_scale_for(country, program)) *
            copy_scale_q16 / Q16_ONE;
        const int32_t school_index = definition.school_index;
        if (!program_writes_school_strength(program, school_index)) {
            activation_scale_q16 =
                activation_scale_q16 *
                school_strength_scale_q16(country, school_index) / Q16_ONE;
        }
        activation_scale_q16 = std::clamp<int64_t>(
            activation_scale_q16, Q16_ONE / 4, 4 * Q16_ONE);
        for (const auto &target : targets) {
            for (int32_t layer = 0; layer < layers; ++layer) {
                EffectActivation activation;
                activation.program = program;
                activation.source_kind = metadata.source_kind;
                activation.target_domain = metadata.target_domain;
                activation.metric_mask = metadata.metric_mask;
                activation.scalar_mask = metadata.scalar_mask;
                // L3-9: resolved per country from ACTIVE synergies, so the same
                // program can be rewritten for one country and untouched for
                // another. 1.0 when no active synergy targets it.
                const int32_t target_scale_q16 = static_cast<int32_t>(
                    static_cast<int64_t>(activation_scale_q16) *
                    target.magnitude_scale_q16 / Q16_ONE);
                activation.magnitude_scale_q16 = target_scale_q16;
                activation.ref.magnitude_scale_q16 = target_scale_q16;
                activation.ref.program_hash = effect_program_hash(program);
                activation.ref.target_handle = target.handle;
                activation.ref.target_generation = target.generation;
                activation.ref.instance_id = effect_instance_id(country.handle,
                    state.ideology_id, state.location, state.level, program,
                    target.handle, layer);
                activation.ref.generation = std::max(1U, state.generation);
                out.push_back(std::move(activation));
            }
        }
    }
    std::sort(out.begin(), out.end(),
        [](const EffectActivation &lhs, const EffectActivation &rhs) {
            if (lhs.ref.instance_id != rhs.ref.instance_id)
                return lhs.ref.instance_id < rhs.ref.instance_id;
            return lhs.program < rhs.program;
        });
    return true;
}

void NativeIdeologyRuntime::collect_idea_program_domains(
        const CountryState &country, const IdeaState &state,
        std::unordered_map<uint64_t, int32_t> &out) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return;
    // Same preconditions as collect_effect_activations: an inactive or
    // out-of-range idea owns no instances, so it owns no labels either.
    if (state.location == INACTIVE || state.level < 0) return;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    if (state.level >= definition.level_count) return;
    std::vector<const EffectTemplate *> active_templates;
    if (definition.copy_left_programs != 0) {
        (void)copy_source_programs(country, state, active_templates);
    } else {
        const Level &row = _levels[
            static_cast<size_t>(definition.level_begin + state.level)];
        active_templates.reserve(static_cast<size_t>(row.persistent_count));
        for (int32_t offset = 0; offset < row.persistent_count; ++offset)
            active_templates.push_back(&_persistent_templates[
                static_cast<size_t>(row.persistent_begin + offset)]);
    }
    for (const EffectTemplate *templ_ptr : active_templates) {
        const EffectTemplate &templ = *templ_ptr;
        const std::string program = effect_program_key(templ.definition_key);
        if (program.empty()) continue;
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        const EffectRuntime::FamilyEffectMetadataPod effective =
            effective_selector_metadata(country, program, metadata);
        out[effect_program_hash(program)] = effective.target_domain;
    }
}

void NativeIdeologyRuntime::retire_effect_activations(IdeaState &state,
        int64_t day) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) {
        state.effect_instances.clear();
        return;
    }
    for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
        // `attached()`, not just non-null: DCWorldExt creates the forwarder with
        // the world and only attach()es it once the Effect catalog exists, and an
        // unattached forwarder answers retire() with unavailable() -- dropping the
        // retire instead of falling back to the legacy authority.
        if (_effect_forwarder != nullptr && _effect_forwarder->attached()) {
            _effect_forwarder->retire(ref.instance_id, ref.generation, day);
            continue;
        }
        std::string ignored;
        _effect_runtime->retire_instance_pod(
            ref.instance_id, ref.generation, day, ignored);
    }
    state.effect_instances.clear();
}

bool NativeIdeologyRuntime::reconcile_effect_activations(
        const CountryState &country, IdeaState &state, int64_t day,
        std::string &error) {
    error.clear();
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return true;
    std::vector<EffectActivation> desired;
    // Derived contributions are NOT materialised here.
    //
    // `reconcile_effect_activations` runs once per (country, idea) from four
    // call sites. Building a WHOLE front from one country's data and
    // installing it means the last reconcile erases every other country's
    // rows. The materialiser therefore lives in
    // `step_derived_rebuild()`, which walks every country and builds one
    // front -- a global operation for a global output.
    if (!collect_effect_activations(country, state, desired)) return true;

    // Retire before submitting so a superseded instance can never coexist with
    // its replacement for a single tick.
    for (const IdeaState::EffectInstanceRef &held : state.effect_instances) {
        bool keep = false;
        for (const EffectActivation &want : desired) {
            if (want.ref.instance_id == held.instance_id) {
                keep = true;
                break;
            }
        }
        if (keep) continue;
        // Same attached() rule as retire_effect_activations above.
        if (_effect_forwarder != nullptr && _effect_forwarder->attached()) {
            _effect_forwarder->retire(held.instance_id, held.generation, day);
            continue;
        }
        std::string ignored;
        _effect_runtime->retire_instance_pod(
            held.instance_id, held.generation, day, ignored);
    }

    std::vector<const EffectActivation *> added;
    for (const EffectActivation &want : desired) {
        bool present = false;
        for (const IdeaState::EffectInstanceRef &held : state.effect_instances) {
            // The scale is part of "present": a synergy flip can change a
            // card's strength without touching its identity, and skipping the
            // submit here is exactly the X5 bug (the instance keeps the old
            // multiplier until something else makes it re-submit).
            if (held.instance_id == want.ref.instance_id &&
                    held.generation == want.ref.generation &&
                    held.magnitude_scale_q16 == want.ref.magnitude_scale_q16) {
                present = true;
                break;
            }
        }
        if (!present) added.push_back(&want);
    }

    if (!added.empty()) {
        const int32_t count = static_cast<int32_t>(added.size());
        PackedInt64Array ids;
        PackedStringArray program_keys;
        PackedInt32Array generations;
        PackedInt32Array source_types;
        PackedInt32Array source_kinds;
        PackedInt64Array source_ids;
        PackedInt64Array source_handles;
        PackedInt64Array target_handles;
        PackedInt32Array target_generations;
        PackedInt32Array levels;
        PackedByteArray active;
        PackedInt64Array next_due_days;
        PackedInt32Array magnitude_scales;
        ids.resize(count);
        program_keys.resize(count);
        generations.resize(count);
        source_types.resize(count);
        source_kinds.resize(count);
        source_ids.resize(count);
        source_handles.resize(count);
        target_handles.resize(count);
        target_generations.resize(count);
        levels.resize(count);
        active.resize(count);
        next_due_days.resize(count);
        magnitude_scales.resize(count);
        const int32_t source_id = state.ideology_id + 1;
        for (int32_t i = 0; i < count; ++i) {
            const EffectActivation &activation = *added[static_cast<size_t>(i)];
            ids[i] = activation.ref.instance_id;
            program_keys[i] = String(activation.program.c_str());
            generations[i] = static_cast<int32_t>(activation.ref.generation);
            source_types[i] = static_cast<int32_t>(0x4944454f); // IDEO
            source_kinds[i] = activation.source_kind;
            source_ids[i] = source_id;
            source_handles[i] = static_cast<int64_t>(country.handle);
            target_handles[i] = static_cast<int64_t>(activation.ref.target_handle);
            target_generations[i] = static_cast<int32_t>(activation.ref.target_generation);
            levels[i] = std::max(0, state.level);
            active[i] = 1;
            next_due_days[i] = day;
            magnitude_scales[i] = activation.magnitude_scale_q16;
        }
        Dictionary batch;
        batch["instance_ids"] = ids;
        batch["program_keys"] = program_keys;
        batch["generations"] = generations;
        batch["source_types"] = source_types;
        batch["source_kinds"] = source_kinds;
        batch["source_ids"] = source_ids;
        batch["source_handles"] = source_handles;
        batch["target_handles"] = target_handles;
        batch["target_generations"] = target_generations;
        batch["levels"] = levels;
        batch["next_due_days"] = next_due_days;
        batch["magnitude_scales"] = magnitude_scales;
        // A5 NOTE: no `latched` column is sent here, deliberately.
        //
        // Everything in `added` is by definition an instance the Effect side does
        // NOT already hold (a held one with matching id/generation/scale is
        // filtered out above), so this side has no knowledge of its latch --
        // sending a column of zeros would be a claim, and `submit_instances`
        // treats an explicit column as authoritative. Omitting the column means
        // "not owned here", which is the truth: the evaluating authority keeps its
        // own latch, and the write-back path (`apply_pod_snapshot`) carries it
        // back. The forwarder's builder also reads no latch from these rows.
        batch["active"] = active;
        // Same attached() rule as the retires: submit_batch on an unattached
        // forwarder can only answer effect_runtime_unavailable, which would read
        // as a rejected card instead of "use the legacy authority".
        const bool forward =
            _effect_forwarder != nullptr && _effect_forwarder->attached();
        const Dictionary result = forward
            ? _effect_forwarder->submit_batch(batch)
            : _effect_runtime->submit_instances(batch);
        if (!static_cast<bool>(result.get("ok", false))) {
            Variant reason = result.get("reason", Variant());
            error = reason.get_type() == Variant::STRING
                ? std::string(String(reason).utf8().get_data())
                : std::string("ideology_effect_instance_submit_failed");
            return false;
        }
        if (int32_t(result.get("rejected", 0)) > 0) {
            error = "ideology_effect_instance_submit_rejected";
            return false;
        }
    }

    // ── Metric snapshots ────────────────────────────────────────────────────
    // A managed ideology program that conditions on a metric reads whatever was
    // last written for its instance. Nothing used to write, so every METRIC_GTE
    // compared `0 >= threshold` and was permanently false while METRIC_LTE was
    // permanently true -- which is why the V1..V6 mechanism cards could only be
    // asserted as declarations, never observed firing.
    //
    // Published on every reconcile that changes something, not only on
    // creation: a condition has to see the world move, and the world moves
    // every day. The digest below is what keeps "the world moves" from being
    // read as "the input changed" -- an identical publish is skipped whole.
    //
    // Cell programs sample their own target cell, so "this cell's extractive
    // share >= 60%" means the cell the effect lands on. Country programs sample
    // the country anchor: country metrics are identical on every owned cell, and
    // the cache key has to be a cell because that is what the sampler takes.
    // One sample per distinct cell per reconcile: nine cards pointing at the
    // same cell cost one building scan, not nine.
    if (!desired.empty()) {
        constexpr int32_t metric_count = NativeEconomyRuntime::FAMILY_METRIC_COUNT;
        const int32_t effect_metric_count = _effect_runtime == nullptr
            ? metric_count : _effect_runtime->metric_count();
        const int64_t revision = day > (std::numeric_limits<int64_t>::max() - 1) / 4
            ? std::numeric_limits<int64_t>::max() : day * 4 + 1;
        // O3: sample each cell ONCE with the union of the masks that target it.
        // The old `all_declared` mask forced every reconcile to compute all 68
        // columns, and the X7 country counts among them rebuild the whole-map
        // tag bitset -- the most expensive thing in this function.
        std::unordered_map<int32_t, MetricMask> mask_by_cell;
        std::vector<std::pair<int32_t, EffectActivation *>> pending_publishes;
        std::vector<EffectActivation *> pending_scalar_publishes;
        for (EffectActivation &activation : desired) {
            if (activation.metric_mask.is_none() && activation.scalar_mask.is_none())
                continue;
            int32_t cell = -1;
            if (activation.target_domain == 3) {
                // A country program reads country-wide Economy metrics from its
                // anchor cell, but ideology scalars are identical for every
                // cell of the country. Keep a scalar-only country program
                // publishable even when Economy is not attached.
                if (activation.metric_mask.is_none()) {
                    pending_scalar_publishes.push_back(&activation);
                    continue;
                }
                if (_economy_runtime == nullptr) continue;
                const int32_t country_slot =
                    static_cast<int32_t>(country.handle & 0xffffffffULL);
                cell = _economy_runtime->country_anchor_cell(country_slot);
            } else if (activation.target_domain == 2 ||
                       activation.target_domain == 5) {
                const int64_t raw = static_cast<int64_t>(
                    activation.ref.target_handle);
                if (raw < 0 || raw > std::numeric_limits<int32_t>::max())
                    continue;
                cell = static_cast<int32_t>(raw);
            } else {
                continue;
            }
            if (cell < 0) continue;
            mask_by_cell[cell] |= activation.metric_mask;
            pending_publishes.emplace_back(cell, &activation);
        }
        // Ideology scalars are country-wide, so one vector serves every
        // cell. Economy never receives these ids; only the Effect instance
        // slab sees them.
        std::vector<int64_t> scalar_values;
        const bool wants_ideology_scalars =
            !pending_scalar_publishes.empty() ||
            std::any_of(pending_publishes.begin(), pending_publishes.end(),
                [](const std::pair<int32_t, EffectActivation *> &publish) {
                    return publish.second->scalar_mask.is_any();
                });
        if (wants_ideology_scalars) {
            scalar_values.assign(static_cast<size_t>(effect_metric_count), 0);
            fill_ideology_scalars(country, state, scalar_values);
        }
        std::unordered_map<int32_t, std::vector<int64_t>> sampled_by_cell;
        sampled_by_cell.reserve(mask_by_cell.size());
        for (const auto &entry : mask_by_cell) {
            std::vector<int64_t> values(static_cast<size_t>(effect_metric_count), 0);
            std::vector<int32_t> economy_ids;
            entry.second.collect_ids(0, metric_count, economy_ids);
            if (_economy_runtime != nullptr && !economy_ids.empty()) {
                MetricMask economy_mask;
                for (int32_t metric_id : economy_ids) economy_mask.set(metric_id);
                _economy_runtime->sample_effect_metrics(entry.first, metric_count,
                    values.data(), economy_mask);
            }
            if (wants_ideology_scalars)
                fill_ideology_scalars(country, state, values);
            sampled_by_cell.emplace(entry.first, std::move(values));
        }
        // Previous publish per instance. Built before `effect_instances` is
        // rebuilt below; a level change advances the generation, which
        // invalidates the digest by construction.
        std::unordered_map<int64_t, size_t> held_by_instance;
        held_by_instance.reserve(state.effect_instances.size());
        for (size_t held = 0; held < state.effect_instances.size(); ++held)
            held_by_instance.emplace(state.effect_instances[held].instance_id, held);
        for (const auto &publish : pending_publishes) {
            EffectActivation &activation = *publish.second;
            auto found = sampled_by_cell.find(publish.first);
            if (found == sampled_by_cell.end()) continue;
            MetricMask publish_mask = activation.metric_mask;
            publish_mask |= activation.scalar_mask;
            const uint64_t digest = metric_publish_digest(
                publish_mask, found->second);
            const auto held = held_by_instance.find(activation.ref.instance_id);
            if (held != held_by_instance.end()) {
                const IdeaState::EffectInstanceRef &previous =
                    state.effect_instances[held->second];
                if (previous.generation == activation.ref.generation &&
                        previous.metric_digest == digest) {
                    // Same columns, same values, same instance. Publishing
                    // again would advance the Effect input revision and mint a
                    // Modifier transaction for a world that did not move.
                    activation.ref.metric_digest = digest;
                    ++_metric_publishes_skipped;
                    continue;
                }
            }
            std::string metric_error;
            bool published = true;
            for (int32_t metric_id = 0; metric_id < effect_metric_count;
                    ++metric_id) {
                // MetricMask covers 256 ids (infra item L0-1), so this is a
                // plain membership test rather than a shift that would be
                // undefined past 63.
                if (!publish_mask.test(metric_id)) continue;
                // A rejected metric (stale instance raced by a retire) must not
                // fail the reconcile: the instance set is already correct.
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        activation.ref.instance_id, activation.ref.generation,
                        metric_id, revision,
                        found->second[static_cast<size_t>(metric_id)],
                        metric_error)) {
                    published = false;
                    break;
                }
            }
            // Only stamp the digest when every column landed, so a partial
            // publish is retried instead of being remembered as done.
            if (published) {
                activation.ref.metric_digest = digest;
                ++_metric_publishes;
            }
        }
        // Scalar-only activations skip Economy coordinate resolution but still
        // publish the derived inputs into the Effect instance's metric slab.
        for (EffectActivation *activation : pending_scalar_publishes) {
            MetricMask publish_mask = activation->scalar_mask;
            const uint64_t digest = metric_publish_digest(
                publish_mask, scalar_values);
            const auto held = held_by_instance.find(activation->ref.instance_id);
            if (held != held_by_instance.end()) {
                const IdeaState::EffectInstanceRef &previous =
                    state.effect_instances[held->second];
                if (previous.generation == activation->ref.generation &&
                        previous.metric_digest == digest) {
                    activation->ref.metric_digest = digest;
                    ++_metric_publishes_skipped;
                    continue;
                }
            }
            std::string metric_error;
            bool published = true;
            for (int32_t metric_id = 0; metric_id < effect_metric_count;
                    ++metric_id) {
                if (!publish_mask.test(metric_id)) continue;
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        activation->ref.instance_id, activation->ref.generation,
                        metric_id, revision,
                        scalar_values[static_cast<size_t>(metric_id)],
                        metric_error)) {
                    published = false;
                    break;
                }
            }
            if (published) {
                activation->ref.metric_digest = digest;
                ++_metric_publishes;
            }
        }
    }

    state.effect_instances.clear();
    state.effect_instances.reserve(desired.size());
    for (const EffectActivation &activation : desired)
        state.effect_instances.push_back(activation.ref);
    // Stamp the input signature AFTER the set is rebuilt. Every path that
    // reconciles -- transition, restore, worker write-back, refresh -- leaves
    // this current, which is what lets a later refresh skip the card without
    // re-deriving anything.
    state.activation_signature = compute_activation_signature(country, state);
    return true;
}

void NativeIdeologyRuntime::publish_effect_input_consumers() {
    if (_economy_runtime == nullptr) return;
    rebuild_level_managed_if_needed();
    constexpr int32_t kEconomyMetricCount =
        NativeEconomyRuntime::FAMILY_METRIC_COUNT;
    MetricMask mask;
    bool tags = false;
    bool tag_ids_incomplete = false;
    std::vector<int32_t> tag_ids;
    bool families = false;
    MetricMask exact;
    std::array<std::vector<int64_t>, NativeEconomyRuntime::FAMILY_METRIC_COUNT>
        thresholds;
    for (const LevelManagedInfo &info : _level_managed) {
        if (info.has_managed == 0) continue;
        MetricMask economy_consumer_mask = info.consumer_mask;
        economy_consumer_mask &= MetricMask::all_declared(
            kEconomyMetricCount);
        mask |= economy_consumer_mask;
        if (info.uses_tags != 0) tags = true;
        if (info.tag_ids_incomplete != 0) tag_ids_incomplete = true;
        for (const int32_t tag_id : info.tag_ids) tag_ids.push_back(tag_id);
        if (info.uses_families != 0) families = true;
        exact |= info.exact_mask;
        for (int32_t t = 0; t < info.threshold_count; ++t) {
            const int32_t metric = info.threshold_ids[t];
            if (metric < 0 || metric >= static_cast<int32_t>(thresholds.size()))
                continue;
            thresholds[static_cast<size_t>(metric)].push_back(
                info.threshold_values[t]);
        }
    }
    // One sorted, deduplicated threshold set per metric: the digest asks "how
    // many are <= value", so order is the whole point and duplicates would
    // shift the count without meaning anything.
    for (auto &per_metric : thresholds) {
        if (per_metric.empty()) continue;
        std::sort(per_metric.begin(), per_metric.end());
        per_metric.erase(std::unique(per_metric.begin(), per_metric.end()),
                         per_metric.end());
    }
    // Exact metrics drop every boundary: an empty set means "compare raw values",
    // which is the only safe answer for a Ramp input or a truncated set.
    for (int32_t metric = 0;
            metric < static_cast<int32_t>(thresholds.size()); ++metric) {
        if (exact.test(metric)) thresholds[static_cast<size_t>(metric)].clear();
    }
    std::sort(tag_ids.begin(), tag_ids.end());
    tag_ids.erase(std::unique(tag_ids.begin(), tag_ids.end()), tag_ids.end());
    // Diagnostic: `consumed=0` at the economy means either "no publisher ran" or
    // "the publisher found no named tags". These three counters separate them.
    ++_consumer_publish_calls;
    _consumer_tag_ids_last = static_cast<int64_t>(tag_ids.size());
    _consumer_levels_with_tags = 0;
    for (const LevelManagedInfo &info : _level_managed) {
        if (info.uses_tags != 0) ++_consumer_levels_with_tags;
    }
    // An incomplete set must NOT be published as a narrow one: the economy would then
    // skip tags a synergy rewrite can still read. An empty set with `tags == true` is
    // the protocol's "all tags" signal.
    if (tag_ids_incomplete) tag_ids.clear();
    _economy_runtime->set_effect_input_consumers(
        mask, tags, families, thresholds, tag_ids);
}

void NativeIdeologyRuntime::set_worker_opinion_inputs(
        const RuntimeIdeologyOpinionSnapshot &opinion) {
    _worker_opinion_inputs = opinion;
    _worker_opinion_inputs_valid = true;
    mark_instance_refresh_dirty();
}

void NativeIdeologyRuntime::collect_local_scalars(
        const CountryState &country,
        std::vector<std::pair<std::string, int64_t>> &out) const {
    out.clear();
    static constexpr const char *kEquippedKey =
        "ideology.scalar.equipped_count";
    static constexpr const char *kSynergyKey =
        "ideology.scalar.active_synergy_count";
    static constexpr const char *kEraKey =
        "ideology.scalar.unlocked_era";
    static constexpr const char *kRoutePrefix =
        "ideology.scalar.route_count.";
    // Equipped means ideology-location only; national spirits retain their
    // separate slot capacity and must not inflate this count.
    int32_t equipped = 0;
    std::array<int32_t, 32> routes{};
    for (const IdeaState &idea : country.ideas) {
        if (idea.location != IDEOLOGY || idea.ideology_id < 0 ||
                idea.ideology_id >= static_cast<int32_t>(_definitions.size()))
            continue;
        ++equipped;
        const uint32_t route_mask =
            _definitions[static_cast<size_t>(idea.ideology_id)].route_mask;
        for (int32_t route = 0; route < static_cast<int32_t>(_route_keys.size());
                ++route) {
            if ((route_mask & (uint32_t{1} << route)) != 0)
                ++routes[static_cast<size_t>(route)];
        }
    }
    out.emplace_back(kEquippedKey, static_cast<int64_t>(equipped) * Q16_ONE);
    for (int32_t route = 0; route < static_cast<int32_t>(_route_keys.size());
            ++route) {
        out.emplace_back(
            std::string(kRoutePrefix) + _route_keys[static_cast<size_t>(route)],
            static_cast<int64_t>(routes[static_cast<size_t>(route)]) * Q16_ONE);
    }
    int32_t active_synergies = 0;
    for (const uint64_t word : country.active_synergy_bits)
        active_synergies += popcount64(word);
    out.emplace_back(kSynergyKey,
        static_cast<int64_t>(active_synergies) * Q16_ONE);
    int32_t country_slot = -1;
    if (validate_country(country.handle, country_slot))
        out.emplace_back(kEraKey,
            static_cast<int64_t>(unlocked_era_for(country_slot)) * Q16_ONE);
}

void NativeIdeologyRuntime::fill_ideology_scalars(
        const CountryState &country, const IdeaState &state,
        std::vector<int64_t> &values) const {
    if (_effect_runtime == nullptr || values.empty()) return;
    // ONE computation, two consumers: this slab and the §18.5 save record. Keeping a
    // second copy of "how many cards are equipped" is how a basis drifts from the
    // thing it claims to describe.
    std::vector<std::pair<std::string, int64_t>> scalars;
    collect_local_scalars(country, scalars);
    for (const std::pair<std::string, int64_t> &entry : scalars) {
        const int32_t metric_id = _effect_runtime->metric_id_for_key(entry.first);
        if (metric_id >= 0 && metric_id < static_cast<int32_t>(values.size()))
            values[static_cast<size_t>(metric_id)] = entry.second;
    }
    // Silence the unused parameter without letting the compiler optimize the
    // call-site contract away: the instance is intentionally not part of the
    // country-wide scalar value.
    (void)state;
}

bool NativeIdeologyRuntime::build_local_scalar_basis(
        const CountryState &country, std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows) const {
    out.clear();
    if (_effect_runtime == nullptr || country.handle == 0) return false;
    const int32_t metric_count = _effect_runtime->metric_count();
    if (metric_count <= 0) return false;
    std::vector<std::pair<std::string, int64_t>> scalars;
    collect_local_scalars(country, scalars);
    // EVERY value in this block is a function of (this payload's country row, the
    // catalogs) EXCEPT the era term, whose input is the Country domain's technology set
    // (`unlocked_era_for` -> `has_technology`). PKCN owns and restores that domain, not
    // PKID, so the era row cannot be used as evidence that THIS payload is corrupt:
    //   * a world that has not restored PKCN yet cannot answer at all, and
    //   * a world whose Country section legitimately reached a different era answers a
    //     DIFFERENT number (measured: capture 3, restore 0 in
    //     `ideology_save_worker_authority_test`, which restores PKEF+PKID only).
    // Either way a content comparison over that row would refuse a good save. The row is
    // still persisted, still shape-checked and still covered by the state hash, so a
    // corrupted era value is caught -- by the hash, which is the layer that can see it.
    if (cross_domain_rows != nullptr) {
        const int32_t era_metric = _effect_runtime->metric_id_for_key(
            "ideology.scalar.unlocked_era");
        if (era_metric >= 0 && era_metric < metric_count) {
            LocalScalarValue row;
            row.country_handle = country.handle;
            row.metric_id = era_metric;
            cross_domain_rows->push_back(row);
        }
    }
    for (const std::pair<std::string, int64_t> &entry : scalars) {
        const int32_t metric_id = _effect_runtime->metric_id_for_key(entry.first);
        // A key this catalog does not declare has no slot in the slab, so there is
        // nothing to record: a program's `READ_METRIC` cannot name it either. This is
        // also what makes the content check real -- a payload row for an id the
        // current catalog no longer produces survives into `restored` but never into
        // `rebuilt`, and the two vectors then differ.
        if (metric_id < 0 || metric_id >= metric_count) continue;
        bool replaced = false;
        for (LocalScalarValue &row : out) {
            if (row.metric_id != metric_id) continue;
            // Two keys on one id is a corrupt catalog. The slab's own rule is last
            // write wins, so the record follows the slab instead of inventing a third
            // answer -- and the reader's strictly-ascending rule still holds.
            row.value_q16 = entry.second;
            replaced = true;
            break;
        }
        if (replaced) continue;
        LocalScalarValue row;
        row.country_handle = country.handle;
        row.metric_id = metric_id;
        row.value_q16 = entry.second;
        out.push_back(row);
    }
    std::sort(out.begin(), out.end(),
        [](const LocalScalarValue &lhs, const LocalScalarValue &rhs) {
            return lhs.metric_id < rhs.metric_id;
        });
    return true;
}

void NativeIdeologyRuntime::rebuild_local_scalar_basis(
        const std::vector<CountryState> &countries,
        std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    std::vector<LocalScalarValue> rows;
    for (const CountryState &country : countries) {
        if (country.handle == 0) continue;
        if (!build_local_scalar_basis(country, rows, cross_domain_rows)) continue;
        out.insert(out.end(), rows.begin(), rows.end());
    }
    // Same ordering contract as the applied basis: strictly ascending (country,
    // metric), which rejects duplicates and an unsorted block on read and makes the
    // byte layout a function of the state rather than of iteration order.
    std::stable_sort(out.begin(), out.end(),
        [](const LocalScalarValue &lhs, const LocalScalarValue &rhs) {
            if (lhs.country_handle != rhs.country_handle)
                return lhs.country_handle < rhs.country_handle;
            return lhs.metric_id < rhs.metric_id;
        });
    out.erase(std::unique(out.begin(), out.end(),
        [](const LocalScalarValue &lhs, const LocalScalarValue &rhs) {
            return lhs.country_handle == rhs.country_handle &&
                lhs.metric_id == rhs.metric_id;
        }), out.end());
}

uint64_t NativeIdeologyRuntime::mix_local_scalar_basis(
        uint64_t hash, const std::vector<LocalScalarValue> &rows) {
    hash = mixv(hash, static_cast<uint64_t>(rows.size()));
    for (const LocalScalarValue &row : rows) {
        hash = mixv(hash, row.country_handle);
        hash = mixv(hash, row.metric_id);
        hash = mixv(hash, row.value_q16);
    }
    return hash;
}

// One line explaining WHY a scalar comparison failed, so the named refusal says what
// disagreed. `cross_domain` rows are reported too: a refusal that was mostly about
// excluded rows is a different finding from a value that moved.
static std::string describe_local_scalar_mismatch(
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &restored,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &rebuilt,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &cross_domain) {
    std::string out = "payload_rows=" + std::to_string(restored.size()) +
        " rebuilt_rows=" + std::to_string(rebuilt.size()) +
        " cross_domain_rows=" + std::to_string(cross_domain.size());
    const auto skip = [&cross_domain](
            const NativeIdeologyRuntime::LocalScalarValue &row) {
        for (const NativeIdeologyRuntime::LocalScalarValue &candidate : cross_domain)
            if (candidate.country_handle == row.country_handle &&
                    candidate.metric_id == row.metric_id)
                return true;
        return false;
    };
    size_t restored_index = 0;
    size_t rebuilt_index = 0;
    int32_t reported = 0;
    while (reported < 3) {
        while (restored_index < restored.size() && skip(restored[restored_index]))
            ++restored_index;
        while (rebuilt_index < rebuilt.size() && skip(rebuilt[rebuilt_index]))
            ++rebuilt_index;
        if (restored_index == restored.size() || rebuilt_index == rebuilt.size())
            break;
        const NativeIdeologyRuntime::LocalScalarValue &left =
            restored[restored_index];
        const NativeIdeologyRuntime::LocalScalarValue &right = rebuilt[rebuilt_index];
        if (left != right) {
            out += " | diff#";
            out += std::to_string(reported);
            out += " payload(handle=" + std::to_string(left.country_handle) +
                " metric=" + std::to_string(left.metric_id) +
                " value=" + std::to_string(left.value_q16) + ")";
            out += " rebuilt(handle=" + std::to_string(right.country_handle) +
                " metric=" + std::to_string(right.metric_id) +
                " value=" + std::to_string(right.value_q16) + ")";
            ++reported;
        }
        ++restored_index;
        ++rebuilt_index;
    }
    if (reported == 0 && restored.size() != rebuilt.size())
        out += " | row counts differ (presence, not value)";
    return out;
}

// Do the payload's rows agree with a fresh derivation, ignoring the rows whose value is
// NOT a function of this payload plus the catalogs? `cross_domain` is at most one row per
// country (the era term), so the linear skip test costs nothing; both inputs are
// (country, metric)-sorted by the rebuild.
//
// Anything NOT named in `cross_domain` must match exactly, including PRESENCE: a row the
// rebuild did not produce (a metric the catalogs no longer declare, or one whose key is
// gone) is a difference, which is the whole point of the content check.
static bool local_scalar_basis_agrees(
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &restored,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &rebuilt,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &cross_domain) {
    const auto skip = [&cross_domain](
            const NativeIdeologyRuntime::LocalScalarValue &row) {
        for (const NativeIdeologyRuntime::LocalScalarValue &candidate : cross_domain)
            if (candidate.country_handle == row.country_handle &&
                    candidate.metric_id == row.metric_id)
                return true;
        return false;
    };
    size_t restored_index = 0;
    size_t rebuilt_index = 0;
    while (true) {
        while (restored_index < restored.size() && skip(restored[restored_index]))
            ++restored_index;
        while (rebuilt_index < rebuilt.size() && skip(rebuilt[rebuilt_index]))
            ++rebuilt_index;
        if (restored_index == restored.size() && rebuilt_index == rebuilt.size())
            return true;
        if (restored_index == restored.size() || rebuilt_index == rebuilt.size())
            return false;
        if (restored[restored_index] != rebuilt[rebuilt_index]) return false;
        ++restored_index;
        ++rebuilt_index;
    }
}

void NativeIdeologyRuntime::rebuild_level_managed_if_needed() const {
    if (_level_managed_built) return;
    _level_managed_built = true;
    _level_managed.assign(_levels.size(), LevelManagedInfo{});
    if (_effect_runtime == nullptr) return;
    for (int32_t id = 0; id < static_cast<int32_t>(_definitions.size()); ++id) {
        const Definition &definition = _definitions[static_cast<size_t>(id)];
        for (int32_t level = 0; level < definition.level_count; ++level) {
            const int32_t index = definition.level_begin + level;
            if (index < 0 || index >= static_cast<int32_t>(_levels.size())) continue;
            const Level &row = _levels[static_cast<size_t>(index)];
            LevelManagedInfo info;
            std::vector<const EffectTemplate *> managed_rows;
            if (definition.copy_left_programs != 0) {
                // Conservative union: every possible left source the copier may
                // read. Legendary sources are excluded at every level. The
                // copier's own managed rows stay excluded.
                for (int32_t source_id = 0;
                        source_id < static_cast<int32_t>(_definitions.size());
                        ++source_id) {
                    if (source_id == id) continue;
                    const Definition &source_definition =
                        _definitions[static_cast<size_t>(source_id)];
                    if (source_definition.copyable == 0) continue;
                    for (int32_t source_level = 0;
                            source_level < source_definition.level_count;
                            ++source_level) {
                        const int32_t source_index =
                            source_definition.level_begin + source_level;
                        if (source_index < 0 ||
                                source_index >= static_cast<int32_t>(
                                    _levels.size()))
                            continue;
                        const Level &source_row =
                            _levels[static_cast<size_t>(source_index)];
                        for (int32_t offset = 0;
                                offset < source_row.persistent_count; ++offset)
                            managed_rows.push_back(&_persistent_templates[
                                static_cast<size_t>(
                                    source_row.persistent_begin + offset)]);
                    }
                }
            } else {
                managed_rows.reserve(
                    static_cast<size_t>(row.persistent_count));
                for (int32_t offset = 0;
                        offset < row.persistent_count; ++offset)
                    managed_rows.push_back(&_persistent_templates[
                        static_cast<size_t>(row.persistent_begin + offset)]);
            }
            for (const EffectTemplate *templ_ptr : managed_rows) {
                const EffectTemplate &templ = *templ_ptr;
                const std::string program = effect_program_key(templ.definition_key);
                if (program.empty()) continue;
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
                    continue; // Legacy Modifier row: nothing to reconcile.
                const EffectRuntime::FamilyEffectMetadataPod effective =
                    effective_selector_metadata(CountryState{}, program, metadata);
                info.has_managed = 1;
                info.program_mix = mixv(info.program_mix,
                    effect_program_hash(program));
                if (effective.target_domain == 2 || effective.target_domain == 5)
                    info.uses_economy_inputs = 1;
                if (effective.target_domain == 0) {
                    info.uses_economy_inputs = 1;
                    info.uses_families = 1;
                }
                if (metadata.metric_mask.is_any()) {
                    info.uses_economy_inputs = 1;
                    info.consumer_mask |= metadata.metric_mask;
                    info.exact_mask |= metadata.exact_metric_mask;
                    for (int32_t t = 0; t < metadata.metric_threshold_count; ++t) {
                        if (info.threshold_count >= 8) {
                            // Same reasoning as the pod cap: a dropped boundary
                            // must demote the metric to exact, not vanish.
                            info.exact_mask.set(metadata.metric_threshold_ids[t]);
                            break;
                        }
                        const int32_t slot = info.threshold_count++;
                        info.threshold_ids[slot] = metadata.metric_threshold_ids[t];
                        info.threshold_values[slot] =
                            metadata.metric_threshold_values[t];
                    }
                }
                info.scalar_mask |= metadata.scalar_mask;
                // Selector kinds 12..15 all read the epoch tag bitset: 12/13
                // filter targets by tag, 14/15 select source cells by tag.
                if (effective.target_selector_kind >= 12 &&
                        effective.target_selector_kind <= 16) {
                    info.uses_tags = 1;
                    // `target_selector_param[1]` is the 1-based tag id; 0 means "no
                    // tag filter" (already handled by the selector), so only a positive
                    // value names a tag.
                    const int32_t tag_param = effective.target_selector_param[1];
                    if (tag_param > 0)
                        info.tag_ids.push_back(tag_param - 1);
                }
                // A TAG/KIND rewrite can turn a non-tag program into a tag user,
                // and a TAG rewrite can add a tag to an existing tag program.
                // Declare the consumer conservatively once any override exists;
                // the economy's bitset is small and this avoids a stale digest.
                if (!_synergy_overrides.empty()) {
                    info.uses_tags = 1;
                    // A TAG/KIND rewrite can introduce a tag this level never named,
                    // but the overrides are ENUMERABLE -- `_synergy_tag_overrides` is
                    // keyed by tag index. Collecting them keeps the set exhaustive, so
                    // the economy can still narrow. Marking it "incomplete" instead
                    // discarded all 48 collected ids and fell back to all 296 tags
                    // (measured on B7: `tag_ids=48` at the publisher, `consumed=0` at
                    // the economy).
                    for (const auto &entry : _synergy_tag_overrides) {
                        if (entry.first >= 0)
                            info.tag_ids.push_back(entry.first);
                    }
                    for (const auto &entry : _synergy_program_overrides) {
                        for (const int32_t synergy_id : entry.second) {
                            // `_synergy_overrides` is a VECTOR indexed by synergy id,
                            // not a map.
                            if (synergy_id < 0 ||
                                    synergy_id >= static_cast<int32_t>(
                                        _synergy_overrides.size()))
                                continue;
                            const SynergyOverride &override_row =
                                _synergy_overrides[static_cast<size_t>(synergy_id)];
                            // BOTH ids matter: `match_tag_id` is the tag the selector
                            // reads, `tag_id` is the one the rewrite applies. Naming
                            // only the replacement would make the selector see a tag
                            // whose bits were never computed.
                            if (override_row.match_tag_id >= 0)
                                info.tag_ids.push_back(override_row.match_tag_id);
                            if (override_row.tag_id >= 0)
                                info.tag_ids.push_back(override_row.tag_id);
                        }
                    }
                }
            }
            _level_managed[static_cast<size_t>(index)] = info;
        }
    }
}

const NativeIdeologyRuntime::LevelManagedInfo *
NativeIdeologyRuntime::level_managed_info(
        int32_t ideology_id, int32_t level) const {
    if (ideology_id < 0 ||
            ideology_id >= static_cast<int32_t>(_definitions.size()))
        return nullptr;
    const Definition &definition = _definitions[static_cast<size_t>(ideology_id)];
    if (level < 0 || level >= definition.level_count) return nullptr;
    const int32_t index = definition.level_begin + level;
    if (index < 0 || index >= static_cast<int32_t>(_level_managed.size()))
        return nullptr;
    return &_level_managed[static_cast<size_t>(index)];
}

bool NativeIdeologyRuntime::level_is_managed(
        int32_t ideology_id, int32_t level) const {
    rebuild_level_managed_if_needed();
    const LevelManagedInfo *info = level_managed_info(ideology_id, level);
    return info != nullptr && info->has_managed != 0;
}

uint64_t NativeIdeologyRuntime::activation_signature_for_test(uint64_t handle,
        int32_t ideology_id) const {
    for (const CountryState &country : _countries) {
        if (country.handle != handle) continue;
        const auto found = country.idea_indices.find(ideology_id);
        if (found == country.idea_indices.end()) return 0;
        const size_t index = found->second;
        if (index >= country.ideas.size()) return 0;
        return compute_activation_signature(country, country.ideas[index]);
    }
    return 0;
}

uint64_t NativeIdeologyRuntime::compute_activation_signature(
        const CountryState &country, const IdeaState &state) const {
    rebuild_level_managed_if_needed();
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, state.ideology_id);
    hash = mixv(hash, state.level);
    hash = mixv(hash, state.location);
    hash = mixv(hash, state.slot_index);
    hash = mixv(hash, state.generation);
    if (state.ideology_id >= 0 &&
            state.ideology_id < static_cast<int32_t>(_definitions.size())) {
        const Definition &definition =
            _definitions[static_cast<size_t>(state.ideology_id)];
        hash = mixv(hash, school_strength_scale_q16(
            country, definition.school_index));
    }
    if (state.ideology_id >= 0 &&
            state.ideology_id < static_cast<int32_t>(_definitions.size()) &&
            _definitions[static_cast<size_t>(
                state.ideology_id)].copy_left_programs != 0) {
        const IdeaState *source = nullptr;
        if (copy_source_state(country, state, source) && source != nullptr) {
            hash = mixv(hash, source->ideology_id);
            hash = mixv(hash, source->level);
            hash = mixv(hash, source->generation);
        } else {
            // Stable "no source" sentinel. 0 is not a valid ideology id.
            hash = mixv(hash, 0);
            hash = mixv(hash, -1);
            hash = mixv(hash, 0);
        }
        hash = mixv(hash,
            static_cast<int32_t>(state.level >= 2 ? 78643 : Q16_ONE));
    }
    const LevelManagedInfo *info =
        level_managed_info(state.ideology_id, state.level);
    if (info == nullptr) return hash;
    hash = mixv(hash, info->program_mix);
    // Ideology scalars are local state, not Economy revisions. Mix only the
    // values this card actually reads so equipping an unrelated card cannot
    // make every active card refresh.
    if (info->scalar_mask.is_any()) {
        std::vector<int64_t> scalars;
        const int32_t metric_count = _effect_runtime == nullptr
            ? 0 : _effect_runtime->metric_count();
        scalars.assign(static_cast<size_t>(metric_count), 0);
        fill_ideology_scalars(country, state, scalars);
        for (int32_t metric = 0; metric < metric_count; ++metric) {
            if (!info->scalar_mask.test(metric)) continue;
            hash = mixv(hash, scalars[static_cast<size_t>(metric)]);
        }
    }
    // X5: a synergy flip changes this card's magnitude without touching the
    // card. Hashing the active set is coarser than a per-program scale lookup
    // but costs a couple of words instead of a catalog scan, and over-triggering
    // here only costs one reconcile.
    if (!_synergy_overrides.empty()) {
        for (const uint64_t word : country.active_synergy_bits)
            hash = mixv(hash, word);
    }
    // Review §3: a card's signature mixes only the metrics it reads. Cards with
    // no metric mask keep the global revision, so nothing that used to refresh
    // stops refreshing -- the change can only narrow.
    if (_economy_runtime != nullptr) {
        // Three independent inputs, mixed only where this card actually reads
        // them (review §3). Anything the old global revision caught is still
        // caught: a cell card that reads neither metrics nor tags depends on
        // ownership, which is the territory revision.
        // ONE snapshot load for the whole signature. Reading it per metric meant a
        // card could mix metric A's new revision with metric B's old one -- the
        // exact torn read the snapshot exists to prevent -- and cost up to 68
        // atomic shared_ptr loads per card, which is lock-prefixed on MSVC.
        const std::shared_ptr<const EffectInputSnapshot> snapshot =
            _economy_runtime->effect_input_snapshot();
        if (snapshot != nullptr) {
            if (info->consumer_mask.is_any()) {
                // SUM, not max: the revisions are independent counters, so a max
                // hides every metric that is not the leading one. With A=5 and B
                // going 3->4, max stays 5 and a card reading both would never
                // refresh. Revisions only increase, so the sum always moves.
                uint64_t metric_revision = 0;
                constexpr int32_t kMetricCount =
                    static_cast<int32_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT);
                for (int32_t metric = 0; metric < kMetricCount; ++metric) {
                    if (!info->consumer_mask.test(metric)) continue;
                    metric_revision +=
                        snapshot->metric_revision[static_cast<size_t>(metric)];
                }
                hash = mixv(hash, metric_revision);
            }
            if (info->uses_tags != 0)
                hash = mixv(hash, snapshot->tag_revision);
            if (info->uses_families != 0)
                hash = mixv(hash, snapshot->family_revision);
            if (info->uses_economy_inputs != 0)
                hash = mixv(hash, snapshot->territory_revision);
        }
    }
    return hash;
}

void NativeIdeologyRuntime::recount_managed_active() {
    rebuild_level_managed_if_needed();
    int32_t total = 0;
    for (const CountryState &country : _countries) {
        if (country.handle == 0) continue;
        for (const int32_t row : country.active_state_indices) {
            if (row < 0 || row >= static_cast<int32_t>(country.ideas.size()))
                continue;
            const IdeaState &state = country.ideas[static_cast<size_t>(row)];
            if (level_is_managed(state.ideology_id, state.level)) ++total;
        }
    }
    _managed_active_total = total;
}

bool NativeIdeologyRuntime::step_effect_instance_refresh(
        int64_t day, int32_t country_budget) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return false;
    rebuild_level_managed_if_needed();
    if (_level_managed.empty()) return false;
    if (!_instance_refresh_pending) {
        const uint64_t revision = _economy_runtime == nullptr
            ? _effect_input_revision_seen
            : _economy_runtime->effect_input_revision();
        if ((_economy_runtime == nullptr || revision == _effect_input_revision_seen) &&
                !_instance_refresh_dirty)
            return false;
        _instance_refresh_pending = true;
        // Adopt the target only at the START of a pass. Restarting on every new
        // revision would reset the cursor before it ever reaches the tail.
        _effect_input_revision_target = revision;
        _instance_refresh_country_cursor = 0;
        _instance_refresh_dirty = false;
    }
    const Clock::time_point started = Clock::now();
    int32_t budget = country_budget > 0
        ? country_budget : INSTANCE_REFRESH_COUNTRY_BUDGET;
    if (budget <= 0) budget = static_cast<int32_t>(_countries.size());
    int32_t visit_budget = INSTANCE_REFRESH_VISIT_BUDGET;
    while (_instance_refresh_country_cursor <
               static_cast<int32_t>(_countries.size()) && budget > 0) {
        if (visit_budget <= 0) break;
        CountryState &country = _countries[
            static_cast<size_t>(_instance_refresh_country_cursor)];
        --budget;
        ++_instance_refresh_country_cursor;
        if (country.handle == 0) continue;
        for (const int32_t row : country.active_state_indices) {
            if (row < 0 || row >= static_cast<int32_t>(country.ideas.size()))
                continue;
            IdeaState &state = country.ideas[static_cast<size_t>(row)];
            if (state.location == INACTIVE || state.level < 0) continue;
            // A card with an Effect transaction in flight is owned by the ACK
            // branch; touching it here would race the rollback.
            if (state.transition.active != 0) continue;
            if (!level_is_managed(state.ideology_id, state.level)) continue;
            const uint64_t signature = compute_activation_signature(country, state);
            if (signature == state.activation_signature) {
                ++_instance_refresh_skips;
                continue;
            }
            std::string ignored;
            reconcile_effect_activations(country, state, day, ignored);
            --visit_budget;
            ++_instance_refresh_visits;
        }
    }
    _instance_refresh_ms += elapsed_ms(started);
    if (_instance_refresh_country_cursor <
            static_cast<int32_t>(_countries.size()))
        return true;
    _effect_input_revision_seen = _effect_input_revision_target;
    _instance_refresh_pending = false;
    ++_instance_refresh_passes;
    if (_economy_runtime != nullptr) {
        const uint64_t now = _economy_runtime->effect_input_revision();
        if (now > _effect_input_revision_seen) {
            const uint64_t lag = now - _effect_input_revision_seen;
            if (lag > _instance_refresh_lag_revisions)
                _instance_refresh_lag_revisions = lag;
        }
    }
    return false;
}

void NativeIdeologyRuntime::reconcile_country_effect_activations(
        CountryState &country, int64_t day) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return;
    // Every IdeaState in this country shares one Effect authority, so a flip is
    // detected once here and applied to all of them.
    //
    // Why the refs must be dropped on a flip: `state.effect_instances` records
    // what this runtime believes it wrote, and it wrote to whichever side held
    // EFFECT at the time. When the other side takes over, that memory is a lie
    // in two directions -- retires would target instances the new authority
    // never accepted, and "already present" would skip instances it never got.
    // Forgetting the set makes the next reconcile resubmit everything, which is
    // idempotent per (instance_id, generation).
    if (_effect_forwarder != nullptr) {
        const uint64_t epoch = _effect_forwarder->authority_epoch();
        if (_effect_authority_epoch == AUTHORITY_EPOCH_UNSET) {
            _effect_authority_epoch = epoch;
        } else if (epoch != _effect_authority_epoch) {
            _effect_authority_epoch = epoch;
            for (IdeaState &state : country.ideas)
                state.effect_instances.clear();
        }
    }
    for (IdeaState &state : country.ideas) {
        std::string ignored;
        reconcile_effect_activations(country, state, day, ignored);
    }
}

bool NativeIdeologyRuntime::emit_level_effects(CountryState &country, IdeaState &state,
        int32_t level, bool remove_persistent, bool include_on_enter, int64_t day,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (level < 0 || state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size())) return true;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    if (level >= definition.level_count) return true;
    const Level &row = _levels[static_cast<size_t>(definition.level_begin + level)];
    if (definition.copy_left_programs != 0) {
        std::vector<const EffectTemplate *> legacy_rows;
        collect_copied_legacy_templates(country, state, legacy_rows);
        for (const EffectTemplate *templ : legacy_rows) {
            if (!emit_templates(country.handle, state.ideology_id, level,
                    static_cast<int32_t>(templ - _persistent_templates.data()),
                    1, remove_persistent, day, 0, commands, error))
                return false;
        }
    } else if (!emit_templates(country.handle, state.ideology_id, level,
            row.persistent_begin, row.persistent_count, remove_persistent, day,
            0, commands, error)) {
        return false;
    }
    if (include_on_enter)
        return emit_templates(country.handle, state.ideology_id, level, row.on_enter_begin,
            row.on_enter_count, false, day, static_cast<uint64_t>(level + 1), commands, error);
    return true;
}

bool NativeIdeologyRuntime::start_transition(CountryState &country, IdeaState &state,
        uint8_t location, int32_t level, uint8_t slot_index,
        bool remove_previous_persistent, bool apply_current_persistent,
        uint64_t entered_on_success, int64_t day, std::string &error) {
    if (state.transition.active != 0) { error = "ideology_transition_pending"; return false; }
    const auto index_it = country.idea_indices.find(state.ideology_id);
    if (index_it == country.idea_indices.end()) {
        error = "ideology_state_index_missing";
        return false;
    }
    const int32_t idea_slot = index_it->second;
    IdeaState::Transition transition;
    transition.active = 1;
    transition.producer_id = _applying_producer_id;
    transition.command_sequence = _applying_sequence;
    transition.command_opcode = _applying_opcode;
    transition.previous_level = state.level;
    transition.previous_entered_levels = state.entered_levels;
    transition.previous_generation = state.generation;
    transition.previous_location = state.location;
    transition.previous_slot_index = state.slot_index;
    transition.entered_on_success = entered_on_success;
    const int64_t previous_binding_id = state.binding_id;
    const uint32_t previous_binding_generation = state.binding_generation;
    const uint64_t previous_binding_signature = state.binding_signature;
    const uint64_t previous_binding_program_hash = state.binding_program_hash;
    bool new_binding_created = false;
    auto rollback_before_transition = [&]() {
        rollback_synergies(country, transition);
        if (new_binding_created && state.binding_id > 0 &&
                state.binding_generation != 0 && _effect_runtime != nullptr) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        set_state_location(country, idea_slot, transition.previous_location);
        state.slot_index = transition.previous_slot_index;
        state.level = transition.previous_level;
        state.generation = transition.previous_generation;
        state.binding_id = previous_binding_id;
        state.binding_generation = previous_binding_generation;
        state.binding_signature = previous_binding_signature;
        state.binding_program_hash = previous_binding_program_hash;
        // A level replacement keeps the same external identity.  Restore its
        // previous durable binding after the failed new generation has been
        // retired; without this, a failed transition would leave PKID active
        // while PKEF held an inactive binding for that same identity.
        if (state.location != INACTIVE && _effect_runtime != nullptr) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error) &&
                    error.empty())
                error = restore_error.empty()
                    ? "ideology_effect_binding_rollback_failed" : restore_error;
        }
    };
    _transition_command_scratch.clear();
    if (_transition_command_scratch.capacity() <
            static_cast<size_t>(_max_transition_commands))
        _transition_command_scratch.reserve(
            static_cast<size_t>(_max_transition_commands));
    set_state_location(country, idea_slot, location);
    state.slot_index = slot_index;
    state.level = level;
    ++state.generation;
    // Effect transactions are compacted after ACK.  Record a separate
    // durable binding before issuing any command so PKID can prove, on load,
    // which active ideology generation owns the persistent source.
    if (location != INACTIVE && !sync_external_binding(country.handle, state, error)) {
        rollback_before_transition();
        return false;
    }
    new_binding_created = location != INACTIVE;
    // REMOVE and APPLY go into SEPARATE batches, because they must name DIFFERENT
    // generations.
    //
    // Both are `enqueue_external_effect_batch_pod` calls, and that function derives
    // the Effect instance id from (source_type, transition_source_id, first.effect_id,
    // fire_sequence) (`effect_runtime.cpp:3465`). `transition_source_id` embeds the
    // idea's generation, and `NATIVE_MODIFIER_IDEOLOGY` then sets the Modifier row's
    // `source_id` from that instance (`effect_runtime.cpp:5509`).
    //
    // The row being removed was applied at `previous_generation`; the row being added
    // belongs to `state.generation`. Sharing one batch id therefore always mismatches
    // one side:
    //   * unequip (remove only): nothing is found, `already_removed`, row survives;
    //   * level-up / relocation (remove + apply in one transaction): the OLD level's
    //     row keeps its old `source_id`, so the REMOVE cannot find it and BOTH levels
    //     stay live.
    // Splitting the enqueue by generation fixes both cases with one rule instead of a
    // special case per command kind.
    if (remove_previous_persistent && transition.previous_location != INACTIVE &&
            transition.previous_level >= 0) {
        _removed_command_scratch.clear();
        if (!emit_level_effects(country, state, transition.previous_level, true,
                false, day, _removed_command_scratch, error)) {
            rollback_before_transition();
            return false;
        }
        if (!_removed_command_scratch.empty()) {
            const int64_t remove_source_id = static_cast<int64_t>(
                (static_cast<uint64_t>(state.ideology_id + 1) << 32U) |
                static_cast<uint32_t>(transition.previous_generation));
            int64_t remove_transaction_id = 0;
            if (!_effect_runtime->enqueue_external_effect_batch_pod(
                    day, 0x4944454F, remove_source_id, country.handle,
                    country.handle, static_cast<uint32_t>(country.handle >> 32U),
                    _removed_command_scratch.data(),
                    _removed_command_scratch.size(), error,
                    &remove_transaction_id) ||
                    remove_transaction_id <= 0) {
                if (error.empty()) error = "ideology_effect_batch_enqueue_failed";
                rollback_before_transition();
                return false;
            }
            transition.transaction_ids.push_back(remove_transaction_id);
        }
    }
    if (apply_current_persistent && location != INACTIVE && level >= 0 &&
            !emit_level_effects(country, state, level, false, false, day,
                _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
    }
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    for (int32_t entered_level = 0; entered_level < definition.level_count && entered_level < 64; ++entered_level) {
        if ((entered_on_success & (1ULL << entered_level)) == 0) continue;
        const Level &row = _levels[definition.level_begin + entered_level];
        if (!emit_templates(country.handle, state.ideology_id, entered_level, row.on_enter_begin,
                row.on_enter_count, false, day, static_cast<uint64_t>(entered_level + 1),
                _transition_command_scratch, error)) {
            rollback_before_transition();
            return false;
        }
    }
    if (!collect_affected_synergies(country, state.ideology_id, day,
            transition, _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
    }
    if (!_transition_command_scratch.empty()) {
        int64_t transaction_id = 0;
        // Remaining scratch holds everything that BELONGS to the new generation: the
        // APPLY rows, on-enter one-shots and synergy rows. The REMOVE rows were
        // already enqueued above under `previous_generation` (see that block for why
        // the two cannot share a batch id).
        const int64_t transition_source_id = static_cast<int64_t>(
            (static_cast<uint64_t>(state.ideology_id + 1) << 32U) |
            static_cast<uint32_t>(state.generation));
        if (!_effect_runtime->enqueue_external_effect_batch_pod(
                day, 0x4944454F, transition_source_id, country.handle,
                country.handle, static_cast<uint32_t>(country.handle >> 32U),
                _transition_command_scratch.data(),
                _transition_command_scratch.size(), error, &transaction_id) ||
                transaction_id <= 0) {
            if (error.empty()) error = "ideology_effect_batch_enqueue_failed";
            rollback_before_transition();
            return false;
        }
        transition.transaction_ids.push_back(transaction_id);
    }
    if (transition.transaction_ids.empty()) {
        state.entered_levels |= entered_on_success;
        if (transition.previous_location != INACTIVE && _effect_runtime != nullptr) {
            std::string ignored;
            const int64_t retired_id = previous_binding_id > 0 ? previous_binding_id
                : static_cast<int64_t>(binding_id_for(country.handle, state.ideology_id,
                    transition.previous_location));
            const uint32_t retired_generation = previous_binding_generation != 0
                ? previous_binding_generation : transition.previous_generation;
            _effect_runtime->retire_external_binding_pod(retired_id,
                retired_generation, ignored);
        }
        if (state.location == INACTIVE) {
            state.binding_id = 0;
            state.binding_generation = 0;
            state.binding_signature = 0;
            state.binding_program_hash = 0;
        }
        // Allocated at the top for the deferred path; see the note there.
        {
            std::string reconcile_error;
            if (!reconcile_effect_activations(country, state, day,
                    reconcile_error))
                _last_error = reconcile_error;
        }
        return true;
    }
    state.transition = std::move(transition);
    ++country.pending_transition_count;
    append_pending_transition(country, idea_slot);
    return true;
}

bool NativeIdeologyRuntime::poll_pending_transition(PendingTransitionRef &ref,
        int64_t day) {
    if (_effect_runtime == nullptr || ref.country_slot < 0 ||
            ref.country_slot >= static_cast<int32_t>(_countries.size())) return false;
    CountryState &country = _countries[static_cast<size_t>(ref.country_slot)];
    if (country.handle != ref.country_handle || ref.idea_slot < 0 ||
            ref.idea_slot >= static_cast<int32_t>(country.ideas.size())) return false;
    IdeaState &state = country.ideas[static_cast<size_t>(ref.idea_slot)];
    if (state.transition.active == 0 || state.generation != ref.state_generation)
        return false;
    bool pending = false;
    bool failed = false;
    for (const int64_t transaction_id : state.transition.transaction_ids) {
        const int32_t status = _effect_runtime->transaction_status_pod(transaction_id);
        if (status == EffectRuntime::ACKED) continue;
        if (status == EffectRuntime::REJECTED ||
                status == EffectRuntime::RESYNC_REQUIRED || status == 0) {
            failed = true;
            break;
        }
        pending = true;
    }
    if (pending && !failed) return true;
    if (failed) {
        _last_error = "ideology_effect_transition_rejected";
        append_transition_receipt(state.transition, state, country.handle,
            RECEIPT_REJECTED, day, _last_error);
        rollback_synergies(country, state.transition);
        if (state.location != INACTIVE) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        const uint8_t previous_location = state.transition.previous_location;
        const uint8_t previous_slot_index =
            state.transition.previous_slot_index;
        state.level = state.transition.previous_level;
        state.entered_levels = state.transition.previous_entered_levels;
        state.generation = state.transition.previous_generation;
        set_state_location(country, ref.idea_slot, previous_location);
        state.slot_index = previous_slot_index;
        state.binding_id = 0;
        state.binding_generation = 0;
        state.binding_signature = 0;
        state.binding_program_hash = 0;
        if (state.location != INACTIVE) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error))
                _last_error = restore_error;
        }
        mark_instance_refresh_dirty();
    } else {
        append_transition_receipt(state.transition, state, country.handle,
            RECEIPT_SETTLED, day);
        state.entered_levels |= state.transition.entered_on_success;
        if (state.transition.previous_location != INACTIVE) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(
                binding_id_for(country.handle, state.ideology_id,
                    state.transition.previous_location),
                state.transition.previous_generation, ignored);
        }
        if (state.location == INACTIVE) {
            state.binding_id = 0;
            state.binding_generation = 0;
            state.binding_signature = 0;
            state.binding_program_hash = 0;
        }
        mark_instance_refresh_dirty();
    }
    country.pending_transition_count =
        std::max(0, country.pending_transition_count - 1);
    state.transition = IdeaState::Transition{};
    if (!failed) {
        // ── plan §9.3: the projection is confirmed TODAY, eligible TOMORROW ──
        //
        // "该确认投影的 eligible_from_day = D+1. 在 sample_day = S 的新经济冻结边界，只能
        // 选择满足 eligible_from_day <= S 的最新已确认投影."
        //
        // Recorded only on the success path: a rejected transition produces no
        // projection, so it must not move the dates.
        _derived_basis_confirmed_day = day;
        _derived_basis_eligible_day = day + 1;
        // Deferred success is the only point where level/location are durably
        // committed, so the instance set converges here rather than at request
        // time. A failure leaves the previous set untouched by construction.
        std::string reconcile_error;
        if (!reconcile_effect_activations(country, state, day,
                reconcile_error))
            _last_error = reconcile_error;
    }
    return false;
}

bool NativeIdeologyRuntime::start_next_level_transition(CountryState &country,
        IdeaState &state, int64_t day, std::string &error) {
    if (state.location == INACTIVE || state.transition.active != 0) return true;
    if (country.pending_transition_count > 0 && !_synergies.empty())
        return true;
    const int32_t unlocked = unlocked_level(state);
    const int32_t next = state.level + 1;
    if (unlocked < next) return true;
    const uint64_t entered = next < 64 && (state.entered_levels & (1ULL << next)) == 0
        ? (1ULL << next) : 0;
    const bool started = start_transition(country, state, state.location, next,
        state.slot_index, state.level >= 0, true, entered, day, error);
    if (started) ++_levels_advanced;
    return started;
}
uint64_t NativeIdeologyRuntime::next_random(CountryState&c){return splitmix64(c.rng_state);}
int32_t NativeIdeologyRuntime::sample_weighted(CountryState&c,const std::vector<int32_t>&pool,const std::vector<int64_t>&weights) const { int64_t sum=0;for(int64_t v:weights)sum=add_sat(sum,std::max<int64_t>(0,v));if(sum<=0)return -1;const uint64_t roll=splitmix64(c.rng_state)%static_cast<uint64_t>(sum);int64_t cursor=0;for(size_t i=0;i<pool.size();++i){cursor=add_sat(cursor,weights[i]);if(static_cast<uint64_t>(std::max<int64_t>(0,cursor))>roll)return pool[i];}return pool.back(); }
int32_t NativeIdeologyRuntime::ideology_capacity_for(int32_t slot) const {
    int64_t capacity = _ideology_capacity;
    if (_country_runtime != nullptr)
        for (const CapacityUnlock &unlock : _capacity_unlocks)
            if (unlock.ideology_delta != 0 &&
                    _country_runtime->has_technology(slot, unlock.technology_id))
                capacity += unlock.ideology_delta;
    return static_cast<int32_t>(std::min<int64_t>(capacity, _ideology_capacity_max));
}
int32_t NativeIdeologyRuntime::spirit_capacity_for(int32_t slot) const {
    int64_t capacity = _spirit_capacity;
    if (_country_runtime != nullptr)
        for (const CapacityUnlock &unlock : _capacity_unlocks)
            if (unlock.spirit_delta != 0 &&
                    _country_runtime->has_technology(slot, unlock.technology_id))
                capacity += unlock.spirit_delta;
    return static_cast<int32_t>(std::min<int64_t>(capacity, _spirit_capacity_max));
}
int64_t NativeIdeologyRuntime::offer_cost_for(uint64_t draw_sequence) const {
    return runtime_ideology_offer_cost_q16(
        _offer_cost_q16, _offer_cost_growth_percent, _offer_cost_max_q16, draw_sequence);
}
int64_t NativeIdeologyRuntime::reroll_cost_for(uint64_t draw_sequence,
                                               uint64_t handle) const {
    // The open offer was paid at draw_sequence - 1; rerolls cost a share of it.
    const int64_t paid = offer_cost_for(draw_sequence == 0 ? 0 : draw_sequence - 1u);
    const int32_t factor = ideology_stat_factor_q16(
        _reroll_cost_stat_key, _reroll_cost_stat_id, handle);
    // Scale the *share*, never the base draw: a discount card must not turn into
    // a blanket discount on the whole draw economy. The cap lives in the shared
    // kernel so the worker cannot round or clamp it differently.
    return mul_sat(paid,
        ideology_reroll_percent(_reroll_cost_percent, factor)) / 100;
}
int32_t NativeIdeologyRuntime::resolve_ideology_stat_id(
        const std::string &key, int32_t &cache) const {
    if (cache >= 0 || key.empty() || _modifier_runtime == nullptr ||
            !_modifier_runtime->configured()) return cache;
    cache = _modifier_runtime->stat_id_for_key(key);
    return cache;
}
int32_t NativeIdeologyRuntime::ideology_stat_factor_q16(
        const std::string &key, int32_t &cache, uint64_t handle) const {
    if (resolve_ideology_stat_id(key, cache) < 0)
        return static_cast<int32_t>(Q16_ONE);
    double factor = _modifier_runtime->effective_value(ModifierRuntime::COUNTRY,
        cache, handle, 0, 1.0);
    if (!std::isfinite(factor)) factor = 1.0;
    return static_cast<int32_t>(std::lround(std::clamp(factor, 0.0, 4.0) * 65536.0));
}
int32_t NativeIdeologyRuntime::ideology_stat_bp(
        const std::string &key, int32_t &cache, uint64_t handle) const {
    if (resolve_ideology_stat_id(key, cache) < 0) return 0;
    double value = _modifier_runtime->effective_value(ModifierRuntime::COUNTRY,
        cache, handle, 0, 0.0);
    if (!std::isfinite(value)) return 0;
    return static_cast<int32_t>(std::lround(std::clamp(value, 0.0, 10000.0)));
}

int32_t NativeIdeologyRuntime::ideology_stat_count(
        const std::string &key, int32_t &cache, uint64_t handle,
        int32_t cap) const {
    if (resolve_ideology_stat_id(key, cache) < 0) return 0;
    double value = _modifier_runtime->effective_value(ModifierRuntime::COUNTRY,
        cache, handle, 0, 0.0);
    if (!std::isfinite(value)) return 0;
    return static_cast<int32_t>(std::lround(std::clamp(
        value, 0.0, static_cast<double>(std::max(0, cap)))));
}

int32_t NativeIdeologyRuntime::magnitude_scale_for(
        const CountryState &country, const std::string &program) const {
    if (_synergy_override_scales.empty() || program.empty()) return static_cast<int32_t>(Q16_ONE);
    // Product, not max: two cards that each rewrite the same program stack, and
    // taking the larger one would make the second card silently do nothing.
    // Clamped once at the end -- clamping per step would turn 1.5^3 into 1.5^2.
    const auto found = _synergy_override_index.find(program);
    if (found == _synergy_override_index.end()) return static_cast<int32_t>(Q16_ONE);
    ++_synergy_scale_lookups;
    int64_t scale = Q16_ONE;
    for (const auto &entry : found->second) {
        ++_synergy_scale_scans;
        if (!synergy_active(country, entry.first)) continue;
        scale = scale * entry.second / Q16_ONE;
        if (scale > 4 * Q16_ONE) { scale = 4 * Q16_ONE; break; }
    }
    if (scale < Q16_ONE / 4) scale = Q16_ONE / 4;
    if (scale > 4 * Q16_ONE) scale = 4 * Q16_ONE;
    return static_cast<int32_t>(scale);
}

bool NativeIdeologyRuntime::program_writes_school_strength(
        const std::string &program, int32_t school_index) const {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr ||
            school_index < 0 ||
            school_index >= static_cast<int32_t>(
                _school_strength_factor_stat_keys.size())) {
        return false;
    }
    const int32_t stat_id = _modifier_runtime->stat_id_for_key(
        _school_strength_factor_stat_keys[static_cast<size_t>(school_index)]);
    if (stat_id < 0) return false;
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (!_effect_runtime->program_modifier_commands(program, commands))
        return false;
    for (const EffectRuntime::ProgramModifierCommand &command : commands) {
        std::vector<ModifierRuntime::ResolvedTerm> terms;
        if (!_modifier_runtime->resolve_definition_terms(
                command.definition_key, terms)) {
            continue;
        }
        for (const ModifierRuntime::ResolvedTerm &term : terms)
            if (term.stat_id == stat_id) return true;
    }
    return false;
}

int32_t NativeIdeologyRuntime::school_strength_scale_q16(
        const CountryState &country, int32_t school_index) const {
    if (school_index < 0 ||
            school_index >= static_cast<int32_t>(_school_keys.size()))
        return static_cast<int32_t>(Q16_ONE);
    int32_t scale = static_cast<int32_t>(Q16_ONE);
    const size_t school_count = _school_keys.size();
    const size_t slot = static_cast<size_t>(
        static_cast<uint32_t>(country.handle & 0xffffffffULL));
    const RuntimeIdeologyOpinionSnapshot &opinion = _worker_opinion_inputs;
    if (_worker_opinion_inputs_valid && school_count > 0 &&
            opinion.school_strength_factor_q16.size() ==
                opinion.country_count * school_count) {
        for (size_t country_row = 0; country_row < opinion.country_count;
                ++country_row) {
            if (opinion.country_handles[country_row] != country.handle)
                continue;
            scale = opinion.school_strength_factor_q16[
                country_row * school_count +
                static_cast<size_t>(school_index)];
            break;
        }
    } else {
        // Synchronous/main-thread fallback. Prefer the cached country slot so a
        // worker snapshot with no country row cannot silently read the global
        // modifier bucket. If the catalog has no ModifierRuntime, the authored
        // base stays 1.0.
        (void)slot;
        if (_modifier_runtime != nullptr &&
                school_index < static_cast<int32_t>(
                    _school_strength_factor_stat_keys.size())) {
            scale = ideology_stat_factor_q16(
                _school_strength_factor_stat_keys[
                    static_cast<size_t>(school_index)],
                _school_strength_factor_stat_ids[
                    static_cast<size_t>(school_index)],
                country.handle);
        }
    }
    return std::clamp(scale, static_cast<int32_t>(Q16_ONE / 2),
        static_cast<int32_t>(2 * Q16_ONE));
}

bool NativeIdeologyRuntime::resolve_synergy_override_tags(
        std::string &error) const {
    error.clear();
    if (_synergy_override_tags_resolved) return true;
    // configure() is allowed to run before configure_effects(). Attaching the
    // EffectRuntime only clears this flag; resolve here, on the first actual
    // selector call, so both startup orders and direct test fixtures converge.
    if (_effect_runtime == nullptr) return false;
    _synergy_tag_overrides.clear();
    const TargetTagTable &tags = _effect_runtime->target_tags();
    std::unordered_map<std::string, int32_t> tag_ids;
    tag_ids.reserve(tags.names.size());
    for (size_t i = 0; i < tags.names.size(); ++i)
        tag_ids[tags.names[i]] = static_cast<int32_t>(i);
    for (size_t row = 0; row < _synergy_overrides.size(); ++row) {
        SynergyOverride &override = _synergy_overrides[row];
        if (override.field != 5) continue;
        override.match_tag_id = -1;
        override.tag_id = -1;
        const auto match = tag_ids.find(override.match_value);
        if (match == tag_ids.end()) {
            error = "ideology_synergy_override_tag_unknown";
            return false;
        }
        override.match_tag_id = match->second;
        const auto found = tag_ids.find(override.tag_name);
        if (found == tag_ids.end()) {
            error = "ideology_synergy_override_tag_unknown";
            return false;
        }
        override.tag_id = found->second;
        _synergy_tag_overrides[override.match_tag_id].push_back(
            static_cast<int32_t>(row));
    }
    _synergy_override_tags_resolved = true;
    return true;
}

EffectRuntime::FamilyEffectMetadataPod
NativeIdeologyRuntime::effective_selector_metadata(
        const CountryState &country, const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata) const {
    EffectRuntime::FamilyEffectMetadataPod out = metadata;
    if (_synergy_overrides.empty() || program.empty()) return out;
    std::string tag_error;
    if (!resolve_synergy_override_tags(tag_error)) return out;
    std::vector<int32_t> candidates;
    const auto by_program = _synergy_program_overrides.find(program);
    if (by_program != _synergy_program_overrides.end())
        candidates.insert(candidates.end(), by_program->second.begin(),
            by_program->second.end());
    if (out.target_selector_param[1] > 0) {
        const auto by_tag =
            _synergy_tag_overrides.find(out.target_selector_param[1] - 1);
        if (by_tag != _synergy_tag_overrides.end())
            candidates.insert(candidates.end(), by_tag->second.begin(),
                by_tag->second.end());
    }
    if (candidates.empty()) return out;
    std::sort(candidates.begin(), candidates.end());
    candidates.erase(std::unique(candidates.begin(), candidates.end()),
        candidates.end());
    struct Winner {
        int32_t minimum_level = -1;
        int32_t synergy_id = -1;
        int32_t value = 0;
        bool found = false;
    };
    Winner tag;
    Winner kind;
    Winner cap;
    for (const int32_t row : candidates) {
        if (row < 0 ||
                row >= static_cast<int32_t>(_synergy_overrides.size()))
            continue;
        const SynergyOverride &override =
            _synergy_overrides[static_cast<size_t>(row)];
        int32_t synergy_id = -1;
        for (size_t candidate = 0; candidate < _synergies.size(); ++candidate) {
            const Synergy &synergy = _synergies[candidate];
            if (row >= synergy.override_begin &&
                    row < synergy.override_begin + synergy.override_count) {
                synergy_id = static_cast<int32_t>(candidate);
                break;
            }
        }
        if (synergy_id < 0 || !synergy_active(country, synergy_id)) continue;
        const Synergy &synergy =
            _synergies[static_cast<size_t>(synergy_id)];
        int32_t minimum_level = 0;
        for (int32_t requirement = synergy.requirement_begin;
                requirement < synergy.requirement_begin +
                    synergy.requirement_count; ++requirement) {
            minimum_level = std::max(minimum_level,
                _synergy_requirements[static_cast<size_t>(requirement)]
                    .minimum_level);
        }
        Winner *target = nullptr;
        int32_t value = override.value;
        if (override.field == 5) {
            target = &tag;
            value = override.tag_id;
        } else if (override.field == 6) {
            target = &kind;
        } else if (override.field == 7) {
            target = &cap;
        }
        if (target == nullptr) continue;
        const bool wins = !target->found ||
            minimum_level > target->minimum_level ||
            (minimum_level == target->minimum_level &&
             synergy_id > target->synergy_id);
        if (wins) {
            target->minimum_level = minimum_level;
            target->synergy_id = synergy_id;
            target->value = value;
            target->found = true;
        }
    }
    // TAG only applies to a tag selector. A MATCH_TAG rewrite that reaches a
    // non-tag program is an authoring error caught by the generator lint; at
    // runtime it is ignored rather than changing an unrelated slot.
    if (tag.found && tag.value >= 0 &&
            (out.target_selector_kind == EffectRuntime::SELECTOR_OWN_TERRITORY ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_ANY_CELL ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R1 ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R2 ||
             out.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_COUNT))
        out.target_selector_param[1] = tag.value + 1;
    if (kind.found)
        out.target_selector_kind = kind.value;
    if (cap.found)
        out.target_selector_param[0] = cap.value;
    return out;
}

int32_t NativeIdeologyRuntime::offer_choice_count_for(
        const CountryState &country) const {
    // The catalog's `offer_choice_count` IS the base: the field used to be read,
    // validated to equal 3 and then ignored, with 3 written into the draw. The
    // stat adds rows on top of whatever the catalog authored.
    const int32_t bonus = ideology_stat_count(_offer_choice_bonus_stat_key,
        _offer_choice_bonus_stat_id, country.handle,
        OFFER_CHOICE_CAPACITY - OFFER_CHOICE_BASE);
    const int32_t count = _draw_count + bonus;
    return std::clamp(count, 1, OFFER_CHOICE_CAPACITY);
}

bool NativeIdeologyRuntime::banned(const CountryState &c, int32_t id) const {
    return id >= 0 && id / 64 < static_cast<int32_t>(c.banned_bits.size()) &&
        (c.banned_bits[static_cast<size_t>(id) / 64] & (1ULL << (id % 64))) != 0;
}

void NativeIdeologyRuntime::set_banned(CountryState &c, int32_t id) {
    if (id < 0 || id / 64 >= static_cast<int32_t>(c.banned_bits.size())) return;
    c.banned_bits[static_cast<size_t>(id) / 64] |= (1ULL << (id % 64));
}

int32_t NativeIdeologyRuntime::draw_pool_size(const CountryState &c, int32_t slot) const {
    int32_t count = 0;
    for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i) {
        const Definition &d = _definitions[static_cast<size_t>(i)];
        if (banned(c, i)) continue;
        if (!known(c, i) && (d.acquisition & DRAW) != 0 && requirements_met(c, slot, d)) ++count;
    }
    return count;
}
int32_t NativeIdeologyRuntime::unlocked_era_for(int32_t country_slot) const {
    if (_country_runtime == nullptr) return 0;
    int32_t reached = 0;
    for (int32_t era = 0;
            era < static_cast<int32_t>(_era_milestone_technologies.size()); ++era) {
        const int32_t technology =
            _era_milestone_technologies[static_cast<size_t>(era)];
        if (technology < 0 || era <= reached) continue;
        if (_country_runtime->has_technology(country_slot, technology)) reached = era;
    }
    return reached;
}
bool NativeIdeologyRuntime::draw_offer(CountryState &c, int32_t slot, std::string &error) {
    // Mirrors RuntimeIdeologyPodAuthority::draw_offer: same eligibility filter,
    // same shared weight kernel, same RNG advance, so the two authorities stay
    // byte-identical stream consumers.
    c.unlocked_era = unlocked_era_for(slot);
    const int32_t decay_floor_bp = ideology_stat_bp(_era_decay_floor_stat_key,
        _era_decay_floor_stat_id, c.handle);
    std::vector<IdeologyDrawCandidate> pool;
    // Parallel to `pool`: 1 when the row may satisfy the current-era guarantee.
    // Kept beside the pool rather than inside the candidate struct so the shared
    // draw kernel keeps its two-field row.
    std::vector<uint8_t> pool_recent;
    std::vector<IdeologyDrawCandidate> fallback_rows;
    for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i) {
        const Definition &d = _definitions[static_cast<size_t>(i)];
        // 封存 retires a card from this run's pool for good. Checked before
        // anything else so a banned card can never take part in a draw, a
        // guarantee slot or the rarity fallback.
        if (banned(c, i) || (d.acquisition & DRAW) == 0) continue;
        if (!requirements_met(c, slot, d)) continue;
        const uint8_t recent = d.era_index >= c.unlocked_era - 1 ? 1u : 0u;
        const int32_t weight = ideology_draw_weight(d.rarity_weight,
            _era_decay_bp.data(), _era_decay_bp.size(), c.unlocked_era,
            d.era_index, decay_floor_bp);
        IdeologyDrawCandidate candidate;
        candidate.id = i;
        if (!known(c, i)) {
            candidate.weight = weight;
            pool.push_back(candidate);
            pool_recent.push_back(recent);
            // The rarity fallback is computed from the NEW-card slice only.
            // Including 精进 rows would make the fallback fire (and therefore
            // advance the RNG differently) purely because refine is enabled.
            fallback_rows.push_back(candidate);
        } else if (_refine_weight_bp > 0) {
            // 精进: an owned card that is not maxed comes back as a pick that
            // raises understanding instead of unlocking one. Maxed cards stay
            // out -- a row that cannot do anything is worse than a missing row,
            // and excluding them means there is no refund to price.
            const IdeaState *state = idea_state_for(c, i);
            if (state == nullptr) continue;
            if (state->level >= d.level_count - 1) continue;
            candidate.weight = static_cast<int64_t>(d.rarity_weight) *
                static_cast<int64_t>(_refine_weight_bp);
            pool.push_back(candidate);
            pool_recent.push_back(recent);
        }
    }
    if (pool.empty()) { error = "ideology_offer_pool_insufficient"; return false; }
    std::vector<IdeologyDrawCandidate> weighted;
    std::vector<uint8_t> weighted_recent;
    weighted.reserve(pool.size());
    weighted_recent.reserve(pool.size());
    for (size_t index = 0; index < pool.size(); ++index) {
        if (pool[index].weight > 0) {
            weighted.push_back(pool[index]);
            weighted_recent.push_back(pool_recent[index]);
        }
    }
    // Late eras only carry a handful of ideas, so once they are all known the
    // decayed pool empties out permanently. Falling back to raw rarity weight
    // keeps the offer functional; it is a pure function of the eligible list so
    // both authorities take the same branch on the same day.
    if (weighted.empty()) {
        for (const IdeologyDrawCandidate &candidate : fallback_rows) {
            IdeologyDrawCandidate fallback = candidate;
            fallback.weight = static_cast<int64_t>(
                _definitions[static_cast<size_t>(candidate.id)].rarity_weight) * 10000;
            weighted.push_back(fallback);
            weighted_recent.push_back(
                _definitions[static_cast<size_t>(candidate.id)].era_index
                    >= c.unlocked_era - 1 ? 1u : 0u);
        }
    }
    if (weighted.empty()) { error = "ideology_offer_weight_invalid"; return false; }
    std::array<int32_t, OFFER_CHOICE_CAPACITY> draw;
    draw.fill(-1);
    const int32_t want = std::min(offer_choice_count_for(c),
        static_cast<int32_t>(weighted.size()));
    const int32_t drawn = ideology_weighted_draw_recent_first(weighted,
        weighted_recent, want, [&c]() { return splitmix64(c.rng_state); },
        draw.data());
    if (drawn <= 0) { error = "ideology_offer_weight_invalid"; return false; }
    const uint32_t generation = std::max<uint32_t>(1, c.offer.generation + 1);
    c.offer.clear();
    c.offer.active = 1;
    c.offer.generation = generation;
    for (int32_t i = 0; i < drawn; ++i) c.offer.ideology_ids[static_cast<size_t>(i)] = draw[static_cast<size_t>(i)];
    c.offer.choice_count = static_cast<uint8_t>(drawn);
    return true;
}
bool NativeIdeologyRuntime::open_offer(CountryState &c, int32_t slot, std::string &error) {
    if (c.offer.active != 0) { error = "ideology_offer_pending"; return false; }
    const int64_t cost = offer_cost_for(c.draw_sequence);
    if (c.free_draws == 0 && c.ideology_points_q16 < cost) {
        error = "ideology_points_insufficient"; return false;
    }
    if (!draw_offer(c, slot, error)) return false;
    if (c.free_draws > 0) --c.free_draws;
    else c.ideology_points_q16 -= cost;
    ++c.draw_sequence;
    ++_offers_opened;
    return true;
}
bool NativeIdeologyRuntime::reroll_offer(CountryState &c, int32_t slot,
        const Command &cmd, std::string &error) {
    if (c.offer.active == 0) { error = "ideology_offer_not_active"; return false; }
    if (cmd.offer_generation != 0 && cmd.offer_generation != c.offer.generation) {
        error = "ideology_offer_generation_stale"; return false;
    }
    const int64_t cost = reroll_cost_for(c.draw_sequence, c.handle);
    if (c.ideology_points_q16 < cost) { error = "ideology_points_insufficient"; return false; }
    if (!draw_offer(c, slot, error)) return false;
    c.ideology_points_q16 -= cost;
    return true;
}
void NativeIdeologyRuntime::accrue_points(int64_t day) {
    // Production entry point: settle from Economy's committed snapshot.
    //
    // Read it by REFERENCE -- `ideology_opinion_from_economy` copies every lane
    // (population/funds/satisfaction arrays) and this runs once per day per world.
    if (_economy_runtime == nullptr) {
        _points_accrue_result = 1;
        return;
    }
    accrue_points_from(
        ideology_opinion_from_economy(
            _economy_runtime->country_class_opinion_snapshot()),
        day);
}

void NativeIdeologyRuntime::accrue_points_from(
        const RuntimeIdeologyOpinionSnapshot &opinion, int64_t day) {
    // THE ONLY settlement body (R9-1). `accrue_points(day)` is the sole caller
    // today: it feeds Economy's committed snapshot. The parity binding that would
    // feed this from the worker's snapshot is not landed (05 §2.7) -- but keeping
    // ONE body means that wiring only has to supply an opinion, never re-implement
    // the accounting.
    // Mirrors RuntimeIdeologyPodAuthority::accrue_points field for field -- the
    // two must stay line-comparable or parity regresses into a business diff.
    _points_accrue_result = -1;
    const uint64_t revision = opinion.revision;
    _points_accrue_revision = revision;
    if (revision == 0) { _points_accrue_result = 2; return; }
    // R9-2: settle once per COMMITTED DAY, never per publish.
    //
    // The key used to be `period_index = commit_day / period_days`, and that
    // divisor is not constant: `period_days` comes from `_epoch_days`
    // (`economy_runtime_epoch.cpp`), recomputed whenever the workset changes. With
    // period 5, day 10 is period 2; once the epoch widens to 6, day 12 is period 2
    // as well, so a genuinely new commit was skipped as "already settled" (and the
    // reverse split one period into two). `commit_day` is monotone and independent
    // of the publish count, so it is the only safe key. `period_index` survives as
    // a diagnostic field only.
    const int64_t commit_day = opinion.committed_day;
    const uint64_t settle_key = commit_day >= 0
        ? static_cast<uint64_t>(commit_day) + 1u
        : revision;
    if (settle_key == _points_revision_seen) { _points_accrue_result = 3; return; }
    const size_t countries = static_cast<size_t>(opinion.country_count);
    if (opinion.country_handles.size() < countries ||
            opinion.country_population.size() != countries ||
            opinion.country_buildings_installed.size() != countries ||
            opinion.country_trade_base_value.size() != countries) {
        _points_accrue_result = 4;
        return;
    }
    if (opinion.class_hash != _political_class_hash ||
            opinion.class_count != _political_class_count) {
        _points_accrue_result = 5;
        return;
    }
    // Mark the key consumed only AFTER every gate passed. The original order
    // consumed it first, so a single snapshot with a mismatched class catalog
    // permanently retired that revision: the next day's identical snapshot fell
    // into the "already seen" branch and the runtime never allocated a single
    // country row. A retryable gate has to stay retryable.
    _points_revision_seen = settle_key;
    _points_accrue_result = 0;
    const int64_t period = std::max<int64_t>(1, opinion.period_days);
    const size_t classes = static_cast<size_t>(std::max(0, _political_class_count));
    for (size_t slot = 0; slot < countries; ++slot) {
        const uint64_t handle = opinion.country_handles[slot];
        if (handle == 0) continue;
        CountryState *row = country_state_for(handle, true);
        if (row == nullptr || row->points_revision == settle_key) continue;
        row->points_revision = settle_key;
        const int64_t population = std::max<int64_t>(0, opinion.country_population[slot]);
        const int64_t buildings = std::max<int64_t>(0, opinion.country_buildings_installed[slot]);
        if (row->baseline_ready == 0) {
            row->baseline_population = population;
            row->baseline_buildings = buildings;
            row->baseline_ready = 1;
            // R9-5: seed the trade marker on the SAME settlement that establishes
            // the baseline. Leaving it at INT64_MIN meant the kernel's first call
            // did the seeding instead, one settlement later, so the whole first
            // period's trade flow was never paid. Seeding here costs nothing (it
            // pays 0 either way) and removes the silent lost period.
            if (row->trade_paid_day == INT64_MIN) row->trade_paid_day = day;
            continue;
        }
        const int64_t population_gain = std::max<int64_t>(0, population - row->baseline_population);
        const int64_t building_gain = std::max<int64_t>(0, buildings - row->baseline_buildings);
        row->baseline_population = std::max(row->baseline_population, population);
        row->baseline_buildings = std::max(row->baseline_buildings, buildings);
        const int64_t trade_per_day = std::max<int64_t>(0, opinion.country_trade_base_value[slot]) / period;
        RuntimeIdeologyPodPointLedger ledger;
        ledger.day = day;
        const int32_t population_factor_q16 = ideology_stat_factor_q16(
            _point_population_factor_stat_key, _point_population_factor_stat_id,
            handle);
        const int32_t building_factor_q16 = ideology_stat_factor_q16(
            _point_building_factor_stat_key, _point_building_factor_stat_id,
            handle);
        const int32_t trade_factor_q16 = ideology_stat_factor_q16(
            _point_trade_factor_stat_key, _point_trade_factor_stat_id, handle);
        const std::vector<int32_t> population_factor = {
            std::clamp<int32_t>(population_factor_q16, Q16_ONE / 2, 3 * Q16_ONE)};
        const std::vector<int32_t> building_factor = {
            std::clamp<int32_t>(building_factor_q16, Q16_ONE / 2, 3 * Q16_ONE)};
        const std::vector<int32_t> trade_factor = {
            std::clamp<int32_t>(trade_factor_q16, Q16_ONE / 2, 3 * Q16_ONE)};
        ledger.population_q16 = ideology_point_term_q16(
            mul_sat(population_gain, _point_population_weight_q16),
            population_factor, 0);
        ledger.building_q16 = ideology_point_term_q16(
            mul_sat(building_gain, _point_building_weight_q16),
            building_factor, 0);
        // Trade is a FLOW, so one settlement pays for the days that actually
        // elapsed. Population and buildings are high-water deltas and already
        // pay at most once whatever the cadence, but trade used to pay its full
        // daily amount per settlement and then suppress a second settlement on
        // the SAME day. That made the total a function of the settlement count:
        // the worker, settling on its own clock, collected 11 days where the
        // main thread collected one (measured 46859 vs 67969, R8-2).
        //
        // `ideology_trade_flow_q16` is the shared kernel: `trade_per_day x
        // clamp(day - trade_paid_day, 0, period_days)`, seeded (not paid) on the
        // first observation. Settling once, thirty times, or a random number of
        // times over the same 30 days now pays the same total, and the marker
        // saves/restores with the row.
        // The span this settlement covers, needed by the cap (R9-3). Trade is the
        // only flow that knows elapsed time, so the kernel reports how many days
        // it paid for; a day already paid counts as 1 so the cap never collapses.
        const int64_t trade_paid_before = row->trade_paid_day;
        const int64_t trade_days_q16 = ideology_trade_flow_q16(
            trade_per_day, day, period, row->trade_paid_day);
        const int64_t ledger_span_days = trade_paid_before == INT64_MIN
            ? 1 : std::max<int64_t>(1, day - trade_paid_before);
        ledger.trade_q16 = ideology_point_term_q16(
            mul_sat(trade_days_q16, _point_trade_weight_q16) / TRADE_MONEY_SCALE,
            trade_factor, 0);
        int64_t total_influence = 0;
        int64_t weighted = 0;
        for (size_t class_index = 0; class_index < classes; ++class_index) {
            const size_t lane = slot * classes + class_index;
            if (lane >= opinion.population.size() || lane >= opinion.owner_employed.size() ||
                    lane >= opinion.funds.size() || lane >= opinion.satisfaction_q16.size())
                continue;
            int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
            influence = add_sat(influence, mul_sat(std::max<int64_t>(0, opinion.owner_employed[lane]),
                _opinion_owner_influence_weight));
            influence = add_sat(influence, std::max<int64_t>(0, opinion.funds[lane]) /
                _opinion_funds_per_influence);
            total_influence = add_sat(total_influence, influence);
            weighted = add_sat(weighted, mul_sat(influence,
                std::clamp<int64_t>(opinion.satisfaction_q16[lane], 0, Q16_ONE)));
        }
        const int64_t satisfaction = total_influence > 0
            ? std::clamp<int64_t>(weighted / total_influence, 0, Q16_ONE) : Q16_ONE / 2;
        int32_t opinion_floor_q16 = static_cast<int32_t>(Q16_ONE / 2);
        if (resolve_ideology_stat_id(
                _opinion_factor_floor_stat_key,
                _opinion_factor_floor_stat_id) >= 0) {
            double floor_value = _modifier_runtime->effective_value(
                ModifierRuntime::COUNTRY, _opinion_factor_floor_stat_id,
                handle, 0, 0.5);
            if (!std::isfinite(floor_value)) floor_value = 0.5;
            opinion_floor_q16 = static_cast<int32_t>(std::lround(
                std::clamp(floor_value, 0.3, 0.5) * 65536.0));
        }
        const std::vector<int32_t> opinion_floor = {opinion_floor_q16};
        ledger.opinion_factor_q16 = ideology_opinion_factor_q16(
            satisfaction, opinion_floor, 0);
        double factor = 1.0;
        if (_modifier_runtime != nullptr && _modifier_runtime->configured() &&
                !_point_gain_stat_key.empty())
            factor = _modifier_runtime->effective_value(ModifierRuntime::COUNTRY,
                _point_gain_stat_key.c_str(), handle, 0, 1.0);
        if (!std::isfinite(factor)) factor = 1.0;
        factor = std::clamp(factor, 0.0, 4.0);
        ledger.gain_factor_q16 = static_cast<int32_t>(std::lround(factor * 65536.0));
        const int64_t raw = add_sat(add_sat(ledger.population_q16, ledger.building_q16), ledger.trade_q16);
        int64_t gain = mul_sat(raw, ledger.opinion_factor_q16) / Q16_ONE;
        gain = mul_sat(gain, ledger.gain_factor_q16) / Q16_ONE;
        // R9-3: the single-settlement cap scales with the days this settlement
        // covers.
        //
        // `_point_gain_cap_q16` is authored as a PER-DAY ceiling, but it was
        // applied to the whole settlement. Trade now pays its full elapsed span at
        // once, so a side that settles rarely hits the cap with a large span while
        // a side that settles daily never does -- "1 settlement == 30 settlements"
        // held in the kernel and broke here, paying the rare settler LESS.
        //
        // The span is the number of days this settlement is responsible for. It is
        // 1 when trade was already paid for this day, and `day - previous_day`
        // otherwise. Population and building gains are high-water deltas that
        // describe the whole span, so they are covered by the same multiplier.
        const int64_t covered_days = std::max<int64_t>(1, ledger_span_days);
        if (_point_gain_cap_q16 > 0) {
            gain = std::min(gain, mul_sat(_point_gain_cap_q16, covered_days * Q16_ONE) / Q16_ONE);
        }
        ledger.gain_q16 = std::max<int64_t>(0, gain);
        row->ideology_points_q16 = add_sat(row->ideology_points_q16, ledger.gain_q16);
        row->lifetime_points_q16 = add_sat(row->lifetime_points_q16, ledger.gain_q16);
        row->ledger = ledger;
        row->history_q16[row->history_head] = ledger.gain_q16;
        row->history_head = static_cast<uint8_t>((row->history_head + 1u) % POINT_HISTORY);
        if (row->history_count < POINT_HISTORY) ++row->history_count;
    }
}
bool NativeIdeologyRuntime::choose_offer(CountryState &c, const Command &cmd,
        std::string &error) {
    if (c.offer.active == 0 || cmd.offer_generation != c.offer.generation) {
        error = "ideology_offer_generation_stale";
        return false;
    }
    // Bound by the row count the draw actually produced, not by the array
    // capacity: the tail of `ideology_ids` is -1 and picking there would be an
    // index that looks valid.
    if (cmd.choice_index < 0 ||
            cmd.choice_index >= static_cast<int32_t>(c.offer.choice_count)) {
        error = "ideology_offer_choice_invalid";
        return false;
    }
    const int32_t idea = c.offer.ideology_ids[static_cast<size_t>(cmd.choice_index)];
    if (idea < 0 || banned(c, idea)) {
        error = "ideology_offer_choice_unavailable";
        return false;
    }
    if (known(c, idea)) {
        // 精进: an owned row only ever reaches the offer because the card is not
        // maxed, so the pick pays understanding. `reconcile_level` is what turns
        // that into a level, which is the whole point -- a duplicate is progress
        // instead of a dead pick or a permanently shrinking pool.
        IdeaState *state = idea_state_for(c, idea, false);
        if (state == nullptr) { error = "ideology_offer_choice_unavailable"; return false; }
        state->understanding_q16 += _refine_understanding_q16;
        reconcile_level(*state);
    } else {
        set_known(c, idea);
        idea_state_for(c, idea, true);
    }
    c.offer.clear();
    return true;
}

bool NativeIdeologyRuntime::ban_card(CountryState &c, const Command &cmd,
        std::string &error) {
    const int32_t idea = cmd.ideology_id;
    if (idea < 0 || idea >= static_cast<int32_t>(_definitions.size())) {
        error = "ideology_ideology_invalid";
        return false;
    }
    // Banning an owned card would delete progress, and banning twice would charge
    // twice for the same effect. Both are refused by name.
    if (known(c, idea)) { error = "ideology_ban_known"; return false; }
    if (banned(c, idea)) { error = "ideology_ban_already_banned"; return false; }
    const int64_t cost = offer_cost_for(c.draw_sequence);
    if (c.ideology_points_q16 < cost) {
        error = "ideology_points_insufficient";
        return false;
    }
    c.ideology_points_q16 -= cost;
    set_banned(c, idea);
    return true;
}
bool NativeIdeologyRuntime::equip(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (!known(country, ideology_id)) { error = "ideology_unknown"; return false; }
    if (country.pending_transition_count > 0 && !_synergies.empty()) {
        error = "ideology_country_transition_pending"; return false;
    }
    IdeaState *state = idea_state_for(country, ideology_id, true);
    if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (state->location == NATIONAL_SPIRIT) { error = "ideology_is_national_spirit"; return false; }
    if (state->location == IDEOLOGY) return true;
    if (!exclusion_allows(country, ideology_id, error) ||
            !support_gate(country, ideology_id, SUPPORT_ADOPT, error))
        return false;
    if (ideology_slot_cost(country) + _definitions[ideology_id].ideology_cost >
            ideology_capacity_for(static_cast<int32_t>(country.handle & 0xffffffffULL))) {
        error = "ideology_slot_capacity_exceeded"; return false;
    }
    reconcile_level(*state); // inactive, therefore no Effect needs replacement yet.
    const uint64_t entered = unentered_level_mask(*state, state->level);
    if (!start_transition(country, *state, IDEOLOGY, state->level,
            next_free_slot(country, IDEOLOGY, ideology_id), false, true,
            entered, day, error))
        return false;
    return true;
}

bool NativeIdeologyRuntime::unequip(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (country.pending_transition_count > 0 && !_synergies.empty()) {
        error = "ideology_country_transition_pending"; return false;
    }
    IdeaState *state = idea_state_for(country, ideology_id, false);
    if (state == nullptr || state->location != IDEOLOGY) { error = "ideology_not_equipped"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (!support_gate(country, ideology_id, SUPPORT_REPEAL, error))
        return false;
    if (!start_transition(country, *state, INACTIVE, state->level,
            state->slot_index, state->level >= 0, false, 0, day, error))
        return false;
    return true;
}

bool NativeIdeologyRuntime::promote(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (!known(country, ideology_id)) { error = "ideology_unknown"; return false; }
    if (country.pending_transition_count > 0 && !_synergies.empty()) {
        error = "ideology_country_transition_pending"; return false;
    }
    IdeaState *state = idea_state_for(country, ideology_id, true);
    if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (state->location == NATIONAL_SPIRIT) return true;
    if (state->location != IDEOLOGY) {
        error = "ideology_promotion_requires_equipped"; return false;
    }
    reconcile_level(*state);
    const Definition &definition = _definitions[ideology_id];
    if (state->level < definition.min_spirit_level) { error = "ideology_national_spirit_level_insufficient"; return false; }
    if (spirit_slot_cost(country) + definition.spirit_cost >
            spirit_capacity_for(static_cast<int32_t>(country.handle & 0xffffffffULL))) {
        error = "national_spirit_slot_capacity_exceeded"; return false;
    }
    if (!support_gate(country, ideology_id, SUPPORT_PROMOTE, error))
        return false;
    if (!start_transition(country, *state, NATIONAL_SPIRIT, state->level,
            next_free_slot(country, NATIONAL_SPIRIT, ideology_id), false,
            false, 0, day, error)) return false;
    return true;
}
bool NativeIdeologyRuntime::validate_command_shape(const Command&cmd,std::string&error) const {
    if (cmd.opcode < DISCOVER_IDEOLOGY || cmd.opcode > GRANT_IDEOLOGY_FREE_DRAW ||
            cmd.country_handle == 0 || cmd.producer_id <= 0 ||
            cmd.sequence < 0) {
        error = "ideology_command_invalid";
        return false;
    }
    if ((cmd.opcode == DISCOVER_IDEOLOGY || cmd.opcode == EQUIP_IDEOLOGY ||
            cmd.opcode == UNEQUIP_IDEOLOGY ||
            cmd.opcode == PROMOTE_NATIONAL_SPIRIT ||
            cmd.opcode == ADD_UNDERSTANDING ||
            cmd.opcode == BAN_IDEOLOGY_CARD) &&
            (cmd.ideology_id < 0 ||
             cmd.ideology_id >= static_cast<int32_t>(_definitions.size()))) {
        error = "ideology_id_invalid";
        return false;
    }
    if (cmd.opcode == SET_IDEOLOGY_GATE &&
            (cmd.gate_id < 0 || cmd.gate_id >= _gate_count)) {
        error = "ideology_gate_invalid";
        return false;
    }
    if ((cmd.opcode == GRANT_IDEOLOGY_POINTS ||
            cmd.opcode == ADD_UNDERSTANDING) && cmd.value_q16 < 0) {
        error = "ideology_value_negative";
        return false;
    }
    if (cmd.opcode == GRANT_IDEOLOGY_FREE_DRAW &&
            (cmd.value_q16 <= 0 || cmd.value_q16 > 65535)) {
        error = "ideology_free_draw_invalid";
        return false;
    }
    return true;
}

size_t NativeIdeologyRuntime::pending_command_count() const {
    return _command_cursor <= _commands.size() ? _commands.size() - _command_cursor : 0;
}

const NativeIdeologyRuntime::Command *NativeIdeologyRuntime::next_command() const {
    return _command_cursor < _commands.size() ? &_commands[_command_cursor] : nullptr;
}

void NativeIdeologyRuntime::merge_staged_commands(std::vector<Command> &&staged) {
    std::stable_sort(staged.begin(), staged.end(), command_less);
    std::vector<Command> merged;
    merged.reserve(pending_command_count() + staged.size());
    auto existing = _commands.begin() + static_cast<std::ptrdiff_t>(
        std::min(_command_cursor, _commands.size()));
    std::merge(existing, _commands.end(), staged.begin(), staged.end(),
        std::back_inserter(merged), command_less);
    _command_queue_merge_steps += pending_command_count() + staged.size();
    _commands.swap(merged);
    _command_cursor = 0;
}

void NativeIdeologyRuntime::append_receipt(const Command &command, int32_t status,
        int64_t day, const std::string &reason) {
    Receipt receipt;
    receipt.receipt_id = _next_receipt_id++;
    receipt.producer_id = command.producer_id;
    receipt.sequence = command.sequence;
    receipt.status = status;
    receipt.opcode = command.opcode;
    receipt.country_handle = command.country_handle;
    receipt.ideology_id = command.ideology_id;
    receipt.settled_day = day;
    receipt.reason = reason;
    _receipts.push_back(std::move(receipt));
    if (static_cast<int32_t>(_receipts.size()) > _max_receipts) {
        const size_t remove_count = _receipts.size() -
            static_cast<size_t>(_max_receipts);
        _receipts.erase(_receipts.begin(),
            _receipts.begin() + static_cast<std::ptrdiff_t>(remove_count));
    }
}

void NativeIdeologyRuntime::append_transition_receipt(
        const IdeaState::Transition &transition, const IdeaState &state,
        uint64_t country_handle, int32_t status, int64_t day,
        const std::string &reason) {
    if (transition.producer_id <= 0) return;
    Command command;
    command.producer_id = transition.producer_id;
    command.sequence = transition.command_sequence;
    command.country_handle = country_handle;
    command.ideology_id = state.ideology_id;
    command.opcode = transition.command_opcode;
    append_receipt(command, status, day, reason);
}

Dictionary NativeIdeologyRuntime::poll_receipts(int64_t after_receipt_id,
        int32_t limit) const {
    const int32_t bounded_limit = std::max(1, std::min(limit, 4096));
    PackedInt64Array receipt_ids;
    PackedInt32Array producer_ids;
    PackedInt64Array sequences;
    PackedInt32Array statuses;
    PackedInt32Array opcodes;
    PackedInt64Array country_handles;
    PackedInt32Array ideology_ids;
    PackedInt64Array settled_days;
    PackedStringArray reasons;
    for (const Receipt &receipt : _receipts) {
        if (receipt.receipt_id <= after_receipt_id ||
                receipt_ids.size() >= bounded_limit) continue;
        receipt_ids.append(receipt.receipt_id);
        producer_ids.append(receipt.producer_id);
        sequences.append(receipt.sequence);
        statuses.append(receipt.status);
        opcodes.append(receipt.opcode);
        country_handles.append(static_cast<int64_t>(receipt.country_handle));
        ideology_ids.append(receipt.ideology_id);
        settled_days.append(receipt.settled_day);
        reasons.append(String(receipt.reason.c_str()));
    }
    Dictionary out;
    out["ok"] = true;
    out["receipt_ids"] = receipt_ids;
    out["producer_ids"] = producer_ids;
    out["sequences"] = sequences;
    out["statuses"] = statuses;
    out["opcodes"] = opcodes;
    out["country_handles"] = country_handles;
    out["ideology_ids"] = ideology_ids;
    out["settled_days"] = settled_days;
    out["reasons"] = reasons;
    out["count"] = receipt_ids.size();
    out["latest_receipt_id"] = _next_receipt_id - 1;
    return out;
}

Dictionary NativeIdeologyRuntime::submit_commands(const Dictionary &batch) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const PackedInt32Array ops=i32s(batch,"opcodes"),producers=i32s(batch,"producer_ids"),prio=i32s(batch,"source_priorities"),ids=i32s(batch,"ideology_ids"),choices=i32s(batch,"choice_indices"),gates=i32s(batch,"gate_ids");
    const PackedInt64Array days=i64s(batch,"effective_days"),seq=i64s(batch,"sequences"),handles=i64s(batch,"country_handles"),values=i64s(batch,"values_q16"),offer=i64s(batch,"offer_generations");
    const int32_t count=ops.size();
    if(count<=0||(!producers.is_empty()&&producers.size()!=count)||days.size()!=count||prio.size()!=count||seq.size()!=count||handles.size()!=count||ids.size()!=count||values.size()!=count||offer.size()!=count||choices.size()!=count||gates.size()!=count)
        return fail("ideology_command_columns_invalid");
    std::vector<Command> staged;
    staged.reserve(static_cast<size_t>(count));
    auto staged_high_watermarks = _producer_high_watermarks;
    int32_t duplicates = 0;
    for(int32_t i=0;i<count;++i) {
        Command c;
        c.opcode=ops[i];c.effective_day=days[i];
        c.producer_id=producers.is_empty()?1:producers[i];c.source_priority=prio[i];
        c.sequence=seq[i];c.country_handle=static_cast<uint64_t>(handles[i]);
        c.ideology_id=ids[i];c.value_q16=values[i];
        c.offer_generation=static_cast<uint32_t>(std::max<int64_t>(0,offer[i]));
        c.choice_index=choices[i];c.gate_id=gates[i];
        c.submit_order=_submit_order+static_cast<uint64_t>(i)+1;
        std::string error;
        if(!validate_command_shape(c,error)) return fail(error);
        const auto found = staged_high_watermarks.find(c.producer_id);
        if (found != staged_high_watermarks.end() && c.sequence <= found->second) {
            ++duplicates;
            continue;
        }
        staged_high_watermarks[c.producer_id] = c.sequence;
        staged.push_back(c);
    }
    _submit_order+=static_cast<uint64_t>(count);
    _producer_high_watermarks.swap(staged_high_watermarks);
    merge_staged_commands(std::move(staged));
    Dictionary out;
    out["ok"]=true;
    out["accepted"]=count-duplicates;
    out["duplicates"]=duplicates;
    out["pending"]=static_cast<int32_t>(pending_command_count());
    return out;
}

bool NativeIdeologyRuntime::submit_trigger_command_pod(int32_t opcode, int64_t effective_day,
        int32_t source_priority, int64_t sequence, uint64_t country_handle,
        int32_t ideology_id, int64_t value_q16, uint32_t offer_generation,
        int32_t choice_index, int32_t gate_id, std::string &error) {
    if (!_configured) { error = "ideology_runtime_unconfigured"; return false; }
    Command command;
    command.opcode = opcode; command.effective_day = effective_day;
    command.producer_id = 2;
    command.source_priority = source_priority; command.sequence = sequence;
    command.country_handle = country_handle; command.ideology_id = ideology_id;
    command.value_q16 = value_q16; command.offer_generation = offer_generation;
    command.choice_index = choice_index; command.gate_id = gate_id;
    command.submit_order = _submit_order + 1;
    if (!validate_command_shape(command, error)) return false;
    const auto found = _producer_high_watermarks.find(command.producer_id);
    if (found != _producer_high_watermarks.end() &&
            command.sequence <= found->second) return true;
    _producer_high_watermarks[command.producer_id] = command.sequence;
    ++_submit_order;
    std::vector<Command> staged;
    staged.push_back(command);
    merge_staged_commands(std::move(staged));
    return true;
}
bool NativeIdeologyRuntime::apply_command(const Command &command, int64_t day,
        std::string &error) {
    int32_t country_slot = -1;
    if (!validate_country(command.country_handle, country_slot)) {
        error = "ideology_country_handle_stale"; return false;
    }
    CountryState *country = country_state_for(command.country_handle, true);
    if (country == nullptr) { error = "ideology_country_state_unavailable"; return false; }
    switch (command.opcode) {
        case DISCOVER_IDEOLOGY: {
            if ((_definitions[command.ideology_id].acquisition & DISCOVER) == 0) {
                error = "ideology_discovery_not_allowed"; return false;
            }
            set_known(*country, command.ideology_id);
            IdeaState *state = idea_state_for(*country, command.ideology_id, true);
            if (state != nullptr && state->location == INACTIVE) reconcile_level(*state);
            return true;
        }
        case GRANT_IDEOLOGY_POINTS:
            country->ideology_points_q16 = add_sat(country->ideology_points_q16, command.value_q16);
            return true;
        case GRANT_IDEOLOGY_FREE_DRAW:
            country->free_draws = static_cast<uint16_t>(std::min<int64_t>(
                65535, static_cast<int64_t>(country->free_draws) +
                    command.value_q16));
            return true;
        case OPEN_IDEOLOGY_OFFER: return open_offer(*country, country_slot, error);
        case REROLL_IDEOLOGY_OFFER: return reroll_offer(*country, country_slot, command, error);
        case CHOOSE_IDEOLOGY_OFFER: return choose_offer(*country, command, error);
        case BAN_IDEOLOGY_CARD: return ban_card(*country, command, error);
        case EQUIP_IDEOLOGY: return equip(*country, command.ideology_id, day, error);
        case UNEQUIP_IDEOLOGY: return unequip(*country, command.ideology_id, day, error);
        case PROMOTE_NATIONAL_SPIRIT: return promote(*country, command.ideology_id, day, error);
        case ADD_UNDERSTANDING: {
            if (!known(*country, command.ideology_id)) { error = "ideology_unknown"; return false; }
            IdeaState *state = idea_state_for(*country, command.ideology_id, true);
            if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
            state->understanding_q16 = add_sat(state->understanding_q16, command.value_q16);
            if (state->location == INACTIVE) {
                reconcile_level(*state);
                return true;
            }
            return start_next_level_transition(*country, *state, day, error);
        }
        case SET_IDEOLOGY_GATE:
            set_gate(*country, command.gate_id, command.value_q16 != 0); return true;
        default: error = "ideology_command_unknown"; return false;
    }
}
Dictionary NativeIdeologyRuntime::run_daily(int64_t day) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    accrue_points(day);
    Dictionary result = run_daily_slices(day);
    // Rebuild the derived cell layer ONCE for the whole world (plan 22 §4.2).
    //
    // Placed on the daily entry rather than inside the per-country reconcile
    // because the front is a single shared object: building it from one
    // country and installing it would erase every other country's rows.
    //
    // A failed install is reported but does not fail the day: the layer is an
    // optimisation, and aborting a day because a cache could not be published
    // would turn a recoverable condition into a fatal one. The error is kept so
    // the report can surface it (§12.4).
    // Rebuild ONCE for the whole world (plan 22 §4.2).
    //
    // This was briefly moved into `run_daily_slices` as a sharded stage so a 6400-cell
    // materialise could be split under the §14.3 1 ms budget. It was REVERTED: the
    // sharded version measured `contribs=1600` at build time against 3200 collected,
    // because a day's accumulator is reset by the next `run_ideology_daily` call, and
    // B10 drives ten such days. The result silently covered only one country
    // (M4-18). A correct shard needs `DerivedCellFrontBuilder` to be resumable across
    // steps, which it is not -- that is a design change, not a wiring change.
    //
    // A failed install is reported but does not fail the day: the layer is an
    // optimisation, and aborting a day because a cache could not be published would
    // turn a recoverable condition into a fatal one.
    // The derived rebuild runs as a slice stage now (see `run_daily_slices`).
    return result;
    return run_daily_slices(day);
}

Dictionary NativeIdeologyRuntime::run_daily_slices(int64_t day) {
    const Clock::time_point slice_started = Clock::now();
    int32_t handled = 0;    int32_t visits = 0;
    int32_t transition_visits = 0;
    auto finish = [&](bool done, const char *stage) {
        _last_slice_ms = elapsed_ms(slice_started);
        _max_slice_ms = std::max(_max_slice_ms, _last_slice_ms);
        Dictionary out;
        out["ok"] = true; out["done"] = done; out["stage"] = stage;
        out["path"] = "IDEOLOGY_GRAPH";
        out["commands_applied"] = handled; out["active_visits"] = visits;
        out["pending_transition_visits"] = transition_visits;
        out["dormant_scan_count"] = static_cast<int64_t>(_dormant_scan_count);
        out["sparse_idea_scan_count"] = static_cast<int64_t>(_sparse_idea_scan_count);
        out["pending_transitions"] = static_cast<int32_t>(_pending_transitions.size());
        out["pending_commands"] = static_cast<int32_t>(pending_command_count());
        out["cursor_start"] = _active_country_cursor;
        out["cursor_end"] = _active_country_cursor;
        out["progress_ratio"] = done ? 1.0 : (_countries.empty() ? 0.0 :
            static_cast<double>(_active_country_cursor) / static_cast<double>(_countries.size()));
        out["elapsed_ms"] = _last_slice_ms;
        return out;
    };
    const Clock::time_point transition_started = Clock::now();
    while (_pending_transition_cursor < _pending_transitions.size() &&
            transition_visits < _max_transition_polls_per_slice) {
        PendingTransitionRef &ref = _pending_transitions[_pending_transition_cursor++];
        ++transition_visits; ++_pending_transition_visits;
        if (!poll_pending_transition(ref, day)) ref.country_slot = -1;
    }
    _transition_poll_ms += elapsed_ms(transition_started);
    if (_pending_transition_cursor < _pending_transitions.size())
        return finish(false, "ideology_transition_poll");
    _pending_transition_cursor = 0;
    _pending_transitions.erase(std::remove_if(_pending_transitions.begin(),
        _pending_transitions.end(), [](const PendingTransitionRef &ref) {
            return ref.country_slot < 0;
        }), _pending_transitions.end());

    const Clock::time_point command_started = Clock::now();
    const Command *command = next_command();
    while (command != nullptr && command->effective_day <= day &&
            handled < _max_commands_per_slice) {
        std::string error;
        _applying_producer_id = command->producer_id;
        _applying_sequence = command->sequence;
        _applying_opcode = command->opcode;
        const bool applied = apply_command(*command, day, error);
        _applying_producer_id = 0;
        _applying_sequence = 0;
        _applying_opcode = 0;
        if (!applied) {
            ++_commands_rejected;
            _last_error = error;
            append_receipt(*command, RECEIPT_REJECTED, day, error);
        } else {
            ++_commands_applied;
            bool pending_receipt = false;
            const CountryState *country = country_state_for(command->country_handle);
            const IdeaState *state = country == nullptr ? nullptr :
                idea_state_for(*country, command->ideology_id);
            if (state != nullptr && state->transition.active != 0 &&
                    state->transition.producer_id == command->producer_id &&
                    state->transition.command_sequence == command->sequence)
                pending_receipt = true;
            append_receipt(*command, pending_receipt ? RECEIPT_PENDING :
                RECEIPT_SETTLED, day);
        }
        ++_command_cursor; ++handled;
        command = next_command();
    }
    if (_command_cursor == _commands.size()) {
        _commands.clear();
        _command_cursor = 0;
    }
    _command_apply_ms += elapsed_ms(command_started);
    command = next_command();
    if (command != nullptr && command->effective_day <= day)
        return finish(false, "ideology_commands");

    if (_active_progress_day != day && _last_day < day) {
        _active_progress_day = day;
        _active_country_cursor = 0;
        _active_item_cursor = 0;
        // Once per day is enough: the refresh gate only needs to know whether
        // any managed card is in play, and that set changes at most on equip.
        recount_managed_active();
    }
    const Clock::time_point active_started = Clock::now();
    while (_active_progress_day == day &&
            _active_country_cursor < static_cast<int32_t>(_countries.size())) {
        CountryState &country = _countries[static_cast<size_t>(_active_country_cursor)];
        int32_t country_slot = -1;
        if (country.handle == 0 || !validate_country(country.handle, country_slot) ||
                _active_item_cursor >= static_cast<int32_t>(country.active_state_indices.size())) {
            ++_active_country_cursor;
            _active_item_cursor = 0;
            continue;
        }
        if (visits >= _max_active_visits_per_slice) {
            _active_progress_ms += elapsed_ms(active_started);
            return finish(false, "ideology_active_progress");
        }
        const int32_t idea_slot = country.active_state_indices[
            static_cast<size_t>(_active_item_cursor++)];
        if (idea_slot >= 0 && idea_slot < static_cast<int32_t>(country.ideas.size())) {
            IdeaState *state = &country.ideas[static_cast<size_t>(idea_slot)];
            const int32_t ideology_id = state->ideology_id;
            if (state->location != INACTIVE) {
                ++visits; ++_active_visits;
                const Definition &definition = _definitions[static_cast<size_t>(ideology_id)];
                const int32_t growth_level = state->transition.active != 0
                    ? state->transition.previous_level : state->level;
                if (growth_level >= 0 && growth_level < definition.level_count) {
                    const int64_t daily =
                        _levels[definition.level_begin + growth_level].daily_understanding_q16;
                    // Levels that intentionally accrue nothing skip the modifier
                    // lookup entirely: 0 * anything is 0, and the accrual loop
                    // runs once per active idea per day.
                    if (daily != 0)
                        state->understanding_q16 = add_sat(
                            state->understanding_q16,
                            ideology_scaled_daily(daily, ideology_stat_factor_q16(
                                _understanding_gain_stat_key,
                                _understanding_gain_stat_id, country.handle)));
                }
                std::string error;
                if (!start_next_level_transition(country, *state, day, error)) {
                    ++_commands_rejected;
                    _last_error = error;
                }
            }
        }
    }
    _active_progress_ms += elapsed_ms(active_started);
    if (_active_progress_day == day) {
        _active_progress_day = -1;
        _active_country_cursor = 0;
        _active_item_cursor = 0;
        _last_day = day;
    }
    // P1-A: the instance refresh runs after the day's own work, and finishing
    // the day is NOT the same as being idle. While the pass still has countries
    // left, report done=false so the graph keeps scheduling this system.
    if (step_effect_instance_refresh(day))
        return finish(false, "ideology_instance_refresh");
    // §14.3: the derived rebuild is a SLICE STAGE. Reporting done=false keeps the
    // graph scheduling this system until the fold completes; nothing is installed
    // until then, so a reader never observes a half-built front.
    //
    // Unlike the first attempt (M4-18), the fold state lives in `_derived_rebuild_job`
    // across steps, so each step really does only its own share of the work.
    if (_modifier_runtime != nullptr && _effect_runtime != nullptr) {
        std::string rebuild_error;
        if (!step_derived_rebuild(day, rebuild_error)) {
            if (!rebuild_error.empty()) _last_error = rebuild_error;
            return finish(false, "ideology_derived_rebuild");
        }
        if (!rebuild_error.empty()) _last_error = rebuild_error;
    }
    return finish(true, "ideology_active_progress");
}
bool NativeIdeologyRuntime::should_run(int64_t day) const {
    const Command *command = next_command();
    return _configured && ((command != nullptr && command->effective_day <= day) ||
        !_pending_transitions.empty() || _active_progress_day == day || _last_day < day ||
        // P1-A: a stale input revision has to wake the graph, otherwise the
        // refresh would only ever run on a day that had other work to do.
        // Ideology scalars are local derived inputs: their dirty flag must wake
        // the graph even when no Economy authority is attached.
        (_managed_active_total > 0 &&
         (_instance_refresh_pending || _instance_refresh_dirty ||
          (_economy_runtime != nullptr &&
           _economy_runtime->effect_input_revision() != _effect_input_revision_seen))));
}

bool NativeIdeologyRuntime::export_pod_catalog(
        const RuntimeCountryPodSnapshot &country,
        RuntimeIdeologyPodCatalog &out, std::string &error) const {
    error.clear();
    if (!_configured || !country.bootstrapped || country.catalog_hash == 0) {
        error = "ideology_pod_export_unavailable";
        return false;
    }
    RuntimeIdeologyPodCatalog catalog;
    catalog.country_catalog_hash = country.catalog_hash;
    // Same world seed on both sides: the worker seeds its offer RNG from this and
    // the country handle, exactly like `init_country_state` does on the main
    // thread.
    catalog.world_seed = _world_seed;
    catalog.class_hash = _political_class_hash;
    catalog.class_count = static_cast<uint32_t>(std::max(0, _political_class_count));
    catalog.technology_count = country.technology_count;
    catalog.research_signal_count = country.research_signal_count;
    catalog.gate_count = static_cast<uint32_t>(std::max(0, _gate_count));
    catalog.ideology_capacity = _ideology_capacity;
    catalog.spirit_capacity = _spirit_capacity;
    catalog.draw_count = _draw_count;
    catalog.offer_cost_q16 = _offer_cost_q16;
    catalog.starting_points_q16 = _starting_points_q16;
    catalog.ideology_capacity_max = _ideology_capacity_max;
    catalog.spirit_capacity_max = _spirit_capacity_max;
    catalog.offer_cost_growth_percent = _offer_cost_growth_percent;
    catalog.offer_cost_max_q16 = _offer_cost_max_q16;
    catalog.reroll_cost_percent = _reroll_cost_percent;
    catalog.point_population_weight_q16 = _point_population_weight_q16;
    catalog.point_building_weight_q16 = _point_building_weight_q16;
    catalog.point_trade_weight_q16 = _point_trade_weight_q16;
    catalog.point_gain_cap_q16 = _point_gain_cap_q16;
    catalog.point_gain_stat_id = -1;
    catalog.route_keys.clear();
    catalog.route_keys.reserve(_route_keys.size());
    for (const std::string &route : _route_keys)
        catalog.route_keys.push_back(route);
    catalog.point_population_factor_stat_id = -1;
    catalog.point_building_factor_stat_id = -1;
    catalog.point_trade_factor_stat_id = -1;
    catalog.opinion_factor_floor_stat_id = -1;
    catalog.understanding_gain_stat_id = -1;
    catalog.reroll_cost_stat_id = -1;
    catalog.school_strength_factor_stat_ids.assign(
        _school_strength_factor_stat_keys.size(), -1);
    if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
        if (!_point_gain_stat_key.empty())
            catalog.point_gain_stat_id =
                _modifier_runtime->stat_id_for_key(_point_gain_stat_key);
        catalog.point_population_factor_stat_id = resolve_ideology_stat_id(
            _point_population_factor_stat_key,
            _point_population_factor_stat_id);
        catalog.point_building_factor_stat_id = resolve_ideology_stat_id(
            _point_building_factor_stat_key,
            _point_building_factor_stat_id);
        catalog.point_trade_factor_stat_id = resolve_ideology_stat_id(
            _point_trade_factor_stat_key, _point_trade_factor_stat_id);
        catalog.opinion_factor_floor_stat_id = resolve_ideology_stat_id(
            _opinion_factor_floor_stat_key, _opinion_factor_floor_stat_id);
        // Exporting the catalog is also the one place the main-thread hot path's
        // cached ids get refreshed, so both authorities resolve from the same
        // call and cannot drift apart.
        _understanding_gain_stat_id = -1;
        _reroll_cost_stat_id = -1;
        catalog.understanding_gain_stat_id = resolve_ideology_stat_id(
            _understanding_gain_stat_key, _understanding_gain_stat_id);
        catalog.reroll_cost_stat_id = resolve_ideology_stat_id(
            _reroll_cost_stat_key, _reroll_cost_stat_id);
        // The worker cannot read ModifierRuntime, so the host only needs the ID
        // here to know WHICH bucket to freeze into the opinion snapshot.
        catalog.era_decay_floor_stat_id = resolve_ideology_stat_id(
            _era_decay_floor_stat_key, _era_decay_floor_stat_id);
        catalog.offer_choice_bonus_stat_id = resolve_ideology_stat_id(
            _offer_choice_bonus_stat_key, _offer_choice_bonus_stat_id);
        for (size_t index = 0;
                index < _school_strength_factor_stat_keys.size(); ++index) {
            catalog.school_strength_factor_stat_ids[index] =
                resolve_ideology_stat_id(
                    _school_strength_factor_stat_keys[index],
                    _school_strength_factor_stat_ids[index]);
        }
    }
    catalog.school_keys = _school_keys;
    for (const CapacityUnlock &unlock : _capacity_unlocks)
        catalog.capacity_unlocks.push_back(
            {unlock.technology_id, unlock.ideology_delta, unlock.spirit_delta});
    auto modifier_template = [](const EffectTemplate &templ) {
        RuntimeIdeologyPodModifierTemplate row;
        row.definition_key_hash =
            RuntimeEffectPodAuthority::hash_text(templ.definition_key.c_str());
        row.domain = templ.domain;
        row.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            templ.value_q16 > 0 ? templ.value_q16 : Q16_ONE, 1,
            std::numeric_limits<int32_t>::max()));
        return row;
    };
    auto is_managed_program = [this](const EffectTemplate &templ) {
        if (_effect_runtime != nullptr) {
            const std::string program = effect_program_key(templ.definition_key);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
                return true;
        }
        return false;
    };
    catalog.owner_influence_weight = _opinion_owner_influence_weight;
    catalog.funds_per_influence = _opinion_funds_per_influence;
    catalog.era_decay_bp = _era_decay_bp;
    catalog.refine_weight_bp = _refine_weight_bp;
    catalog.refine_understanding_q16 = _refine_understanding_q16;
    catalog.era_milestone_technologies = _era_milestone_technologies;
    catalog.max_commands_per_slice = static_cast<uint32_t>(
        std::max(1, _max_commands_per_slice));
    catalog.max_transition_commands = static_cast<uint32_t>(
        std::max(1, _max_transition_commands));
    catalog.max_transition_polls_per_slice = static_cast<uint32_t>(
        std::max(1, _max_transition_polls_per_slice));
    catalog.max_active_visits_per_slice = static_cast<uint32_t>(
        std::max(1, _max_active_visits_per_slice));
    catalog.levels.reserve(_levels.size());
    for (const Level &level : _levels) {
        RuntimeIdeologyPodLevel row;
        row.threshold_q16 = level.threshold_q16;
        row.daily_understanding_q16 = level.daily_understanding_q16;
        row.modifier_begin = static_cast<uint32_t>(catalog.level_modifiers.size());
        for (int32_t i = 0; i < level.persistent_count; ++i) {
            const EffectTemplate &templ = _persistent_templates[
                static_cast<size_t>(level.persistent_begin + i)];
            if (!is_managed_program(templ))
                catalog.level_modifiers.push_back(modifier_template(templ));
        }
        row.modifier_count = static_cast<uint32_t>(
            catalog.level_modifiers.size() - row.modifier_begin);
        for (int32_t i = 0; i < level.on_enter_count; ++i) {
            const EffectTemplate &templ = _on_enter_templates[
                static_cast<size_t>(level.on_enter_begin + i)];
            if (templ.action != EffectRuntime::CUSTOM_DOMAIN_COMMAND ||
                    templ.domain != 6 ||
                    templ.opcode !=
                        EffectRuntime::CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE)
                continue;
            const uint32_t count = static_cast<uint32_t>(std::max<int64_t>(
                1, std::min<int64_t>(65535, templ.value_q16)));
            row.on_enter_free_draws = static_cast<uint16_t>(
                std::min<uint32_t>(65535u,
                    static_cast<uint32_t>(row.on_enter_free_draws) + count));
        }
        catalog.levels.push_back(row);
    }
    catalog.definitions.reserve(_definitions.size());
    for (const Definition &definition : _definitions) {
        RuntimeIdeologyPodDefinition row;
        row.acquisition = definition.acquisition;
        row.copy_left_programs = definition.copy_left_programs;
        row.copyable = definition.copyable;
        row.school_index = definition.school_index < 0
            ? 0 : static_cast<uint8_t>(definition.school_index);
        row.rarity_weight = definition.rarity_weight;
        row.era_index = definition.era_index;
        row.ideology_cost = definition.ideology_cost;
        row.spirit_cost = definition.spirit_cost;
        row.min_spirit_level = definition.min_spirit_level;
        row.level_begin = static_cast<uint32_t>(definition.level_begin);
        row.level_count = static_cast<uint32_t>(definition.level_count);
        row.technology_begin = static_cast<uint32_t>(definition.technology_requirement_begin);
        row.technology_count = static_cast<uint32_t>(definition.technology_requirement_count);
        row.signal_begin = static_cast<uint32_t>(definition.signal_requirement_begin);
        row.signal_count = static_cast<uint32_t>(definition.signal_requirement_count);
        row.gate_begin = static_cast<uint32_t>(definition.gate_requirement_begin);
        row.gate_count = static_cast<uint32_t>(definition.gate_requirement_count);
        row.stance_begin = static_cast<uint32_t>(definition.stance_begin);
        row.stance_count = static_cast<uint32_t>(definition.stance_count);
        row.support_threshold_q16 = definition.support_threshold_q16;
        row.exclusion_group_id = definition.exclusion_group_id;
        row.route_mask = definition.route_mask;
        catalog.definitions.push_back(row);
    }
    catalog.technology_requirements = _technology_requirements;
    catalog.signal_requirements = _signal_requirements;
    catalog.gate_requirements = _gate_requirements;
    catalog.class_stances.reserve(_class_stances.size());
    for (const ClassStance &stance : _class_stances) {
        RuntimeIdeologyPodClassStance row;
        row.class_index = stance.class_index;
        row.stance_q16 = stance.stance_q16;
        row.critical_min_q16 = stance.critical_min_q16;
        catalog.class_stances.push_back(row);
    }
    catalog.synergy_requirements.reserve(_synergy_requirements.size());
    for (const SynergyRequirement &requirement : _synergy_requirements) {
        RuntimeIdeologyPodSynergyRequirement row;
        row.ideology_id = requirement.ideology_id;
        row.minimum_level = requirement.minimum_level;
        row.location_mask = requirement.location_mask;
        catalog.synergy_requirements.push_back(row);
    }
    catalog.synergies.reserve(_synergies.size());
    for (const Synergy &synergy : _synergies) {
        RuntimeIdeologyPodSynergy row;
        row.requirement_begin = static_cast<uint32_t>(synergy.requirement_begin);
        row.requirement_count = static_cast<uint32_t>(synergy.requirement_count);
        row.min_count = static_cast<uint32_t>(synergy.min_count);
        row.modifier_begin = static_cast<uint32_t>(catalog.synergy_modifiers.size());
        for (int32_t i = 0; i < synergy.effect_count; ++i) {
            const EffectTemplate &templ = _synergy_templates[
                static_cast<size_t>(synergy.effect_begin + i)];
            if (!is_managed_program(templ))
                catalog.synergy_modifiers.push_back(modifier_template(templ));
        }
        row.modifier_count = static_cast<uint32_t>(
            catalog.synergy_modifiers.size() - row.modifier_begin);
        catalog.synergies.push_back(row);
    }
    catalog.ideology_synergy_offsets.reserve(_ideology_synergy_offsets.size());
    for (const int32_t offset : _ideology_synergy_offsets)
        catalog.ideology_synergy_offsets.push_back(static_cast<uint32_t>(offset));
    catalog.ideology_synergy_ids = _ideology_synergy_ids;
    RuntimeIdeologyPodAuthority validator;
    if (!validator.configure(catalog, error)) return false;
    catalog.catalog_hash = validator.catalog_hash();
    // The POD recomputes its catalog hash in `configure` from the SAME struct, so this is
    // the identity a POD save/import payload must carry -- `_catalog_hash` is NOT (the two
    // sides hash their catalogs with different functions; see `rng_state`'s seeding note).
    _pod_catalog_hash = catalog.catalog_hash;
    out = std::move(catalog);
    return true;
}
Dictionary NativeIdeologyRuntime::reconcile_effects_for_test(int64_t handle) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr)
        return fail("ideology_effect_runtime_unavailable");
    CountryState *country = country_state_for(static_cast<uint64_t>(handle), false);
    if (country == nullptr) return fail("ideology_country_unknown");
    const uint64_t publishes_before = _metric_publishes;
    const uint64_t skipped_before = _metric_publishes_skipped;
    reconcile_country_effect_activations(*country,
        std::max<int64_t>(0, _last_day));
    int64_t instances = 0;
    for (const IdeaState &state : country->ideas)
        instances += static_cast<int64_t>(state.effect_instances.size());
    Dictionary out;
    out["ok"] = true;
    // Deltas, not totals: a caller that reconciles twice compares these.
    out["metric_publishes"] = static_cast<int64_t>(_metric_publishes - publishes_before);
    out["metric_publishes_skipped"] =
        static_cast<int64_t>(_metric_publishes_skipped - skipped_before);
    out["instances"] = instances;
    out["last_error"] = String(_last_error.c_str());
    return out;
}

// Main-thread -> POD export. This is the neutral structure both sides can hash:
// `apply_self_pod_snapshot_for_test` used to build it inline, and parity needs the
// same snapshot without applying it.
bool NativeIdeologyRuntime::export_pod_business_snapshot(
        RuntimeIdeologyPodSnapshot &out) const {
    if (!_configured) return false;
    out = RuntimeIdeologyPodSnapshot{};
    out.abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    out.catalog_hash = _catalog_hash;
    out.generation = std::max<uint64_t>(1, _pod_snapshot_generation);
    out.committed_day = _last_day;
    out.round_day = _last_day;
    out.countries.resize(_countries.size());
    for (size_t slot = 0; slot < _countries.size(); ++slot) {
        const CountryState &source = _countries[slot];
        if (source.handle == 0) continue;
        RuntimeIdeologyPodCountryState &target = out.countries[slot];
        target.handle = source.handle;
        target.unlocked_era = source.unlocked_era;
        target.ideology_points_q16 = source.ideology_points_q16;
        target.points_revision = source.points_revision;
        target.rng_state = source.rng_state;
        target.draw_sequence = source.draw_sequence;
        target.free_draws = source.free_draws;
        target.known_bits = source.known_bits;
        target.banned_bits = source.banned_bits;
        target.gate_bits = source.gate_bits;
        target.synergy_bits = source.active_synergy_bits;
        target.offer.generation = source.offer.generation;
        target.offer.ideology_ids = source.offer.ideology_ids;
        target.offer.choice_count = source.offer.choice_count;
        target.offer.active = source.offer.active;
        // Everything `apply_pod_snapshot` reads has to be exported, or applying a
        // snapshot silently zeroes it -- and the business hash would report the
        // main-thread side as "0" for these forever.
        target.lifetime_points_q16 = source.lifetime_points_q16;
        target.trade_paid_day = source.trade_paid_day;
        target.baseline_ready = source.baseline_ready;
        target.baseline_population = source.baseline_population;
        target.baseline_buildings = source.baseline_buildings;
        target.history_count = source.history_count;
        target.history_head = source.history_head;
        target.history_q16 = source.history_q16;
        target.ledger = source.ledger;
        target.ideology_slots_used = source.ideology_slots_used;
        target.spirit_slots_used = source.spirit_slots_used;
        target.opinion_revision = source.opinion_revision;
        target.ideas.resize(_definitions.size());
        for (const IdeaState &idea : source.ideas) {
            if (idea.ideology_id < 0 ||
                    idea.ideology_id >= static_cast<int32_t>(_definitions.size()))
                continue;
            RuntimeIdeologyPodIdeaState &row =
                target.ideas[static_cast<size_t>(idea.ideology_id)];
            row.understanding_q16 = idea.understanding_q16;
            row.level = idea.level;
            row.entered_levels = idea.entered_levels;
            row.generation = idea.generation;
            row.location = static_cast<RuntimeIdeologyPodLocation>(idea.location);
            row.slot_index = idea.slot_index;
        }
    }
    // Business hash, not `compute_state_hash`: the latter folds in generation,
    // cursors and opinion_revision, which differ between main and worker by
    // construction and made every parity comparison a guaranteed mismatch.
    out.state_hash = ideology_business_hash(out);
    return true;
}


// ── worker IMPORT: the state a restored save must make the POD adopt ───────────
//
// WHY THIS EXISTS. `restore()` rebuilds this runtime's rows, and under IDEOLOGY worker
// authority this runtime is a MIRROR: `apply_pod_snapshot` replaces its rows wholesale
// from the next worker publish. So a restore changes only the main thread, and the
// worker's next publish puts its own state back (measured: `idea_rows [82,1,0,0] -> []`,
// §9.3 dates `7/8 -> 2/3`, then a pump with nothing to fold). The import closes that by
// producing exactly what the POD needs to ADOPT the same state -- not a merge: the POD's
// committed day, rows, points, RNG and offer all become the payload's.
//
// WHY THE BUSINESS SNAPSHOT IS NOT ENOUGH. Three things it deliberately omits are
// required for the POD to accept and reproduce the state:
//   1. the POD's CATALOG identity (`_pod_catalog_hash`, not `_catalog_hash`: the two
//      sides hash their catalogs with different functions);
//   2. the live per-slot COUNTRY generation, which `validate_inputs` compares on every
//      plan and which also encodes into the handle (`generation << 32 | slot`);
//   3. the CALENDAR: `apply_pod_snapshot` stamps the two §9.3 dates from
//      `committed_day`, so that field decides whether the mirror keeps the payload's
//      dates or adopts the worker's (`7/8` vs `2/3`).
bool NativeIdeologyRuntime::export_pod_import_state(
        RuntimeIdeologyPodSnapshot &out,
        const RuntimeCountryPodSnapshot &country, std::string &error) const {
    error.clear();
    if (!_configured) { error = "ideology_runtime_not_configured"; return false; }
    if (_pod_catalog_hash == 0) {
        error = "ideology_pod_catalog_identity_unavailable";
        return false;
    }
    if (!country.bootstrapped || country.country_count == 0 ||
        country.country_active.size() != country.country_count ||
        country.country_generation.size() != country.country_count) {
        error = "ideology_pod_import_country_snapshot_invalid";
        return false;
    }
    if (!export_pod_business_snapshot(out)) {
        error = "ideology_runtime_not_configured";
        return false;
    }
    // The POD indexes a country row by `handle & 0xffffffff` and refuses a state whose
    // row count differs from the Country snapshot it plans against (`validate_inputs`),
    // so the mirror's trailing empty rows are trimmed -- but a row that still carries a
    // handle is a country the Country domain does not know about, and dropping it would
    // silently lose a card.
    for (size_t slot = country.country_count; slot < out.countries.size(); ++slot) {
        if (out.countries[slot].handle != 0) {
            error = "ideology_pod_import_country_shape_mismatch";
            return false;
        }
    }
    if (out.countries.size() < country.country_count) {
        error = "ideology_pod_import_country_shape_mismatch";
        return false;
    }
    out.countries.resize(country.country_count);
    for (uint32_t slot = 0; slot < country.country_count; ++slot) {
        RuntimeIdeologyPodCountryState &row = out.countries[slot];
        if (country.country_active[slot] == 0) {
            row = RuntimeIdeologyPodCountryState{};
            continue;
        }
        const uint64_t handle =
            (static_cast<uint64_t>(country.country_generation[slot]) << 32u) | slot;
        if (row.handle != handle) {
            error = "ideology_pod_import_country_handle_mismatch";
            return false;
        }
        row.generation = country.country_generation[slot];
    }
    out.catalog_hash = _pod_catalog_hash;
    // ── the calendar ────────────────────────────────────────────────────────
    // The CONFIRMED day is the day this state was confirmed on, and it is the value
    // `apply_pod_snapshot` maps back onto `_derived_basis_confirmed_day`. Anything else
    // (the worker's own day, or the payload's `_last_day`) moves the mirrored dates.
    const int64_t floor_day = _derived_basis_confirmed_day >= 0
        ? _derived_basis_confirmed_day : _last_day;
    if (floor_day < 0) {
        error = "ideology_pod_import_day_unavailable";
        return false;
    }
    out.committed_day = floor_day;
    out.round_day = -1;
    out.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
    out.pending_cursor = 0;
    out.command_cursor = 0;
    out.active_country_cursor = 0;
    out.active_idea_cursor = 0;
    out.next_submit_order = std::max<uint64_t>(1, _submit_order);
    out.producer_high_watermarks.clear();
    // `_producer_high_watermarks` is an unordered_map and the POD's restore requires
    // STRICTLY ASCENDING producer ids, so the rows are sorted here (the same way
    // `capture()` sorts its own copy) instead of relying on iteration order.
    std::vector<std::pair<int32_t, int64_t>> watermarks(
        _producer_high_watermarks.begin(), _producer_high_watermarks.end());
    std::sort(watermarks.begin(), watermarks.end());
    out.producer_high_watermarks.reserve(watermarks.size());
    for (const auto &entry : watermarks) {
        if (entry.first <= 0) continue;
        RuntimeIdeologyPodProducerWatermark watermark;
        watermark.producer_id = static_cast<uint32_t>(entry.first);
        watermark.sequence = static_cast<uint64_t>(std::max<int64_t>(0, entry.second));
        out.producer_high_watermarks.push_back(watermark);
    }
    // PKID's rows are SETTLED state: a pending transition is persisted on the row, and
    // the row already carries the level and location the transition settles to. So the
    // import carries no transition and no command -- re-emitting one would drive an
    // Effect instance this worker never ordered, on a card whose bindings live on the
    // main thread.
    out.pending_transitions.clear();
    out.commands.clear();
    out.receipts.clear();
    // One generation AHEAD of everything the mirror has applied. A snapshot the ring
    // still holds from before the import then loses the generation race instead of
    // overwriting the restore (`apply_pod_snapshot` refuses a regression).
    out.generation = std::max<uint64_t>(1, _pod_snapshot_generation + 1);
    RuntimeIdeologyPodAuthority::canonicalize_import(out);
    return true;
}


void NativeIdeologyRuntime::record_worker_import(
        const std::string &code, bool applied, bool retryable) {
    ++_worker_import_attempts;
    _worker_import_last_code = code;
    // A refused payload must not become an infinite retry: retrying would ALSO keep the
    // write-back from applying (the pending flag guards the restore), which would freeze
    // the mirror instead of reporting the refusal. Only "the worker held the day
    // boundary" is worth another attempt.
    if (applied || !retryable) _worker_import_pending = false;
}


Dictionary NativeIdeologyRuntime::apply_self_pod_snapshot_for_test(int64_t generation) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    // Business-only schema tests must not inherit a frozen worker factor table
    // from an earlier fixture in the same runtime.
    _worker_opinion_inputs = RuntimeIdeologyOpinionSnapshot{};
    _worker_opinion_inputs_valid = false;
    // Mirrors what the worker would publish for the CURRENT state, so applying
    // it must be a no-op for the instance set. That is the P1-B contract and the
    // only way to exercise it without a real worker (a headless fixture never
    // earns the IDEOLOGY grant -- see ideology_effect_worker_forward_test.gd).
    RuntimeIdeologyPodSnapshot snapshot;
    if (!export_pod_business_snapshot(snapshot))
        return fail("ideology_runtime_unconfigured");
    // The hook's whole point is to control the generation it applies, so it
    // overrides whatever the export used (the internal cursor).
    snapshot.generation =
        static_cast<uint64_t>(std::max<int64_t>(1, generation));
    int64_t instances_before = 0;
    for (const CountryState &country : _countries)
        for (const IdeaState &state : country.ideas)
            instances_before += static_cast<int64_t>(state.effect_instances.size());
    const uint64_t publishes_before = _metric_publishes;
    std::string error;
    const bool ok = apply_pod_snapshot(snapshot, error);
    int64_t instances_after = 0;
    for (const CountryState &country : _countries)
        for (const IdeaState &state : country.ideas)
            instances_after += static_cast<int64_t>(state.effect_instances.size());
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    out["instances_before"] = instances_before;
    out["instances_after"] = instances_after;
    out["refresh_pending"] = _instance_refresh_pending;
    out["refresh_dirty"] = _instance_refresh_dirty;
    // apply_pod_snapshot must not reconcile: any publish here means the inline
    // full pass came back.
    out["metric_publishes"] =
        static_cast<int64_t>(_metric_publishes - publishes_before);
    return out;
}


Dictionary NativeIdeologyRuntime::effect_instance_report(int64_t handle) const {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    if (country == nullptr) return fail("ideology_country_unknown");
    PackedInt64Array idea_ids, idea_levels, instance_ids, generations,
        program_hashes, target_handles;
    PackedInt32Array target_generations, target_domains;
    PackedInt32Array magnitude_scales;
    PackedByteArray present;
    std::unordered_map<uint64_t, int32_t> domain_by_program;
    for (const IdeaState &state : country->ideas) {
        collect_idea_program_domains(*country, state, domain_by_program);
        for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
            idea_ids.append(state.ideology_id);
            idea_levels.append(state.level);
            instance_ids.append(ref.instance_id);
            generations.append(static_cast<int64_t>(ref.generation));
            program_hashes.append(static_cast<int64_t>(ref.program_hash));
            target_handles.append(static_cast<int64_t>(ref.target_handle));
            target_generations.append(static_cast<int32_t>(ref.target_generation));
            // -1 = "this ref could not be labelled", which a reader MUST treat
            // as "do not draw", not as "domain zero". The distinction matters:
            // target_handle is a cell index for domains 2/5 and a country handle
            // otherwise, so guessing wrong paints an unrelated hex.
            const auto found = domain_by_program.find(ref.program_hash);
            target_domains.append(found == domain_by_program.end()
                ? -1 : found->second);
            magnitude_scales.append(ref.magnitude_scale_q16);
            // Deliberately NOT authority-aware: this column is the *ownership*
            // bit ("did the main thread own this instance, or was it handed to
            // the worker"), the same signal family_branch_effects.effect_present
            // carries. Routing it through the worker snapshot would make both
            // authorities report 1 and destroy the only way a reroute can be
            // told apart from a drop.
            present.append(_effect_runtime != nullptr &&
                _effect_runtime->has_instance_pod(
                    ref.instance_id, ref.generation) ? 1 : 0);
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["count"] = static_cast<int64_t>(instance_ids.size());
    out["idea_ids"] = idea_ids;
    out["idea_levels"] = idea_levels;
    out["instance_ids"] = instance_ids;
    out["generations"] = generations;
    out["program_hashes"] = program_hashes;
    out["target_handles"] = target_handles;
    out["target_generations"] = target_generations;
    out["target_domains"] = target_domains;
    out["magnitude_scales"] = magnitude_scales;
    out["present"] = present;
    return out;
}

Dictionary NativeIdeologyRuntime::snapshot(int64_t handle) const {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    Dictionary out; out["ok"] = true; out["country_handle"] = handle;
    out["offer_cost_q16"] = _offer_cost_q16;
    out["starting_points_q16"] = _starting_points_q16;
    const int32_t country_slot_id = static_cast<int32_t>(
        static_cast<uint64_t>(handle) & 0xffffffffULL);
    const bool handle_valid = _country_runtime != nullptr && handle != 0 &&
        _country_runtime->valid_handle(handle);
    out["ideology_slots_capacity_max"] = _ideology_capacity_max;
    out["national_spirit_slots_capacity_max"] = _spirit_capacity_max;
    out["reroll_cost_percent"] = _reroll_cost_percent;
    {
        // Slot unlock milestones for the UI: technology id plus deltas.
        PackedInt32Array unlock_tech, unlock_ideology, unlock_spirit;
        PackedByteArray unlock_owned;
        for (const CapacityUnlock &unlock : _capacity_unlocks) {
            unlock_tech.append(unlock.technology_id);
            unlock_ideology.append(unlock.ideology_delta);
            unlock_spirit.append(unlock.spirit_delta);
            unlock_owned.append(handle_valid &&
                _country_runtime->has_technology(country_slot_id, unlock.technology_id) ? 1 : 0);
        }
        out["capacity_unlock_technology_ids"] = unlock_tech;
        out["capacity_unlock_ideology_deltas"] = unlock_ideology;
        out["capacity_unlock_spirit_deltas"] = unlock_spirit;
        out["capacity_unlock_owned"] = unlock_owned;
    }
    auto put_points = [&](const CountryState *row) {
        const uint64_t draws = row == nullptr ? 0 : row->draw_sequence;
        out["draw_sequence"] = static_cast<int64_t>(draws);
        out["free_draws"] = row == nullptr ? 0 : static_cast<int64_t>(
            row->free_draws);
        out["next_offer_cost_q16"] = offer_cost_for(draws);
        out["reroll_cost_q16"] = reroll_cost_for(draws, handle);
        const RuntimeIdeologyPodPointLedger ledger =
            row == nullptr ? RuntimeIdeologyPodPointLedger{} : row->ledger;
        out["point_ledger_population_q16"] = ledger.population_q16;
        out["point_ledger_building_q16"] = ledger.building_q16;
        out["point_ledger_trade_q16"] = ledger.trade_q16;
        out["point_ledger_opinion_factor_q16"] = ledger.opinion_factor_q16;
        out["point_ledger_gain_factor_q16"] = ledger.gain_factor_q16;
        out["point_ledger_gain_q16"] = ledger.gain_q16;
        out["point_ledger_day"] = ledger.day;
        out["point_baseline_ready"] = row != nullptr && row->baseline_ready != 0;
        out["lifetime_points_q16"] = row == nullptr ? 0 : row->lifetime_points_q16;
        // Oldest-first gains of the last POINT_HISTORY settlements.
        PackedInt64Array history;
        if (row != nullptr) {
            const int32_t count = row->history_count;
            const int32_t start = (row->history_head + POINT_HISTORY - count) % POINT_HISTORY;
            for (int32_t i = 0; i < count; ++i)
                history.append(row->history_q16[static_cast<size_t>((start + i) % POINT_HISTORY)]);
        }
        out["point_history_q16"] = history;
        PackedInt32Array synergy_ids;
        if (row != nullptr)
            for (int32_t id = 0; id < static_cast<int32_t>(_synergies.size()); ++id)
                if (synergy_active(*row, id)) synergy_ids.append(id);
        out["active_synergy_ids"] = synergy_ids;
    };
    auto put_scalars = [&](const CountryState *row) {
        // Derived, read-only mirrors of the values published into the Effect
        // metric slab. National spirits deliberately do not count as equipped.
        int32_t equipped = 0;
        std::array<int32_t, 32> routes{};
        if (row != nullptr) {
            for (const IdeaState &idea : row->ideas) {
                if (idea.location != IDEOLOGY || idea.ideology_id < 0 ||
                        idea.ideology_id >=
                            static_cast<int32_t>(_definitions.size()))
                    continue;
                ++equipped;
                const uint32_t route_mask =
                    _definitions[static_cast<size_t>(idea.ideology_id)]
                        .route_mask;
                for (int32_t route = 0;
                        route < static_cast<int32_t>(_route_keys.size());
                        ++route) {
                    if ((route_mask & (uint32_t{1} << route)) != 0)
                        ++routes[static_cast<size_t>(route)];
                }
            }
        }
        Dictionary route_counts;
        for (int32_t route = 0;
                route < static_cast<int32_t>(_route_keys.size()); ++route) {
            route_counts[String(_route_keys[static_cast<size_t>(route)].c_str())] =
                static_cast<int64_t>(routes[static_cast<size_t>(route)]);
        }
        int32_t active_synergies = 0;
        if (row != nullptr)
            for (const uint64_t word : row->active_synergy_bits)
                active_synergies += popcount64(word);
        int32_t unlocked_era = 0;
        int32_t country_slot = -1;
        if (handle_valid && validate_country(
                static_cast<uint64_t>(handle), country_slot))
            unlocked_era = unlocked_era_for(country_slot);
        out["ideology_scalar_equipped_count"] =
            static_cast<int64_t>(equipped);
        out["ideology_scalar_route_counts"] = route_counts;
        out["ideology_scalar_active_synergy_count"] =
            static_cast<int64_t>(active_synergies);
        out["ideology_scalar_unlocked_era"] =
            static_cast<int64_t>(unlocked_era);
    };
    put_points(country);
    put_scalars(country);
    if (country == nullptr) {
        // UI reads this before the first command materializes a country row.
        // Keep the same keys as a live empty country so slot gauges and draw
        // cost never collapse to 0/0.
        out["materialized"] = false;
        out["ideology_points_q16"] = _starting_points_q16;
        out["known_ids"] = PackedInt32Array();
        out["idea_ids"] = PackedInt32Array();
        out["understanding_q16"] = PackedInt64Array();
        out["levels"] = PackedInt32Array();
        out["locations"] = PackedInt32Array();
        out["slot_indices"] = PackedInt32Array();
        out["transition_pending"] = PackedByteArray();
        out["binding_ids"] = PackedInt64Array();
        out["binding_generations"] = PackedInt32Array();
        out["binding_signatures"] = PackedInt64Array();
        out["binding_program_hashes"] = PackedInt64Array();
        out["binding_verified"] = PackedByteArray();
        PackedInt32Array empty_transition_offsets;
        empty_transition_offsets.append(0);
        out["transition_transaction_offsets"] = empty_transition_offsets;
        out["transition_transaction_ids"] = PackedInt64Array();
        out["transition_transaction_statuses"] = PackedInt32Array();
        out["ideology_slots_used"] = 0;
        out["ideology_slots_capacity"] = handle_valid
            ? ideology_capacity_for(country_slot_id) : _ideology_capacity;
        out["national_spirit_slots_used"] = 0;
        out["national_spirit_slots_capacity"] = handle_valid
            ? spirit_capacity_for(country_slot_id) : _spirit_capacity;
        out["offer_active"] = false;
        out["offer_generation"] = static_cast<int64_t>(0);
        out["offer_ids"] = PackedInt32Array();
        out["support_revision"] = static_cast<int64_t>(0);
        out["last_error"] = String(_last_error.c_str());
        return out;
    }
    out["materialized"] = true;
    PackedInt32Array known_ids, idea_ids, levels, locations, slot_indices;
    PackedInt64Array understanding, binding_ids, binding_signatures,
        binding_program_hashes, transition_transaction_ids;
    PackedInt32Array binding_generations, transition_transaction_offsets,
        transition_transaction_statuses;
    PackedByteArray transition_pending, binding_verified;
    transition_transaction_offsets.append(0);
    for (int32_t ideology_id = 0; ideology_id < static_cast<int32_t>(_definitions.size()); ++ideology_id)
        if (known(*country, ideology_id)) known_ids.append(ideology_id);
    for (const IdeaState &state : country->ideas) {
        idea_ids.append(state.ideology_id); understanding.append(state.understanding_q16);
        levels.append(state.level); locations.append(state.location);
        slot_indices.append(state.slot_index);
        transition_pending.append(state.transition.active);
        binding_ids.append(state.binding_id);
        binding_generations.append(static_cast<int32_t>(state.binding_generation));
        binding_signatures.append(static_cast<int64_t>(state.binding_signature));
        binding_program_hashes.append(static_cast<int64_t>(state.binding_program_hash));
        const bool verified = state.location == INACTIVE
            ? state.binding_id == 0
            : _effect_runtime != nullptr &&
                _effect_runtime->has_external_binding_pod(state.binding_id,
                    state.binding_generation, 0x4944454f, state.ideology_id,
                    country->handle,
                    static_cast<uint32_t>(country->handle >> 32U), state.level,
                    state.location, state.binding_signature,
                    state.binding_program_hash);
        binding_verified.append(verified ? 1 : 0);
        for (const int64_t transaction_id : state.transition.transaction_ids) {
            transition_transaction_ids.append(transaction_id);
            transition_transaction_statuses.append(_effect_runtime == nullptr ? 0
                : _effect_runtime->transaction_status_pod(transaction_id));
        }
        transition_transaction_offsets.append(
            static_cast<int32_t>(transition_transaction_ids.size()));
    }
    PackedInt32Array offer_ids;
    // Only the rows the draw actually filled. The tail is -1 by construction, and
    // a UI that zips `offer_ids` against localised card names would render three
    // "unknown" chips for a two-row offer otherwise.
    for (int32_t index = 0;
            index < static_cast<int32_t>(country->offer.choice_count); ++index)
        offer_ids.append(country->offer.ideology_ids[static_cast<size_t>(index)]);
    out["ideology_points_q16"] = country->ideology_points_q16;
    out["known_ids"] = known_ids; out["idea_ids"] = idea_ids;
    out["understanding_q16"] = understanding; out["levels"] = levels;
    out["locations"] = locations;
    out["slot_indices"] = slot_indices;
    out["transition_pending"] = transition_pending;
    out["binding_ids"] = binding_ids;
    out["binding_generations"] = binding_generations;
    out["binding_signatures"] = binding_signatures;
    out["binding_program_hashes"] = binding_program_hashes;
    out["binding_verified"] = binding_verified;
    out["transition_transaction_offsets"] = transition_transaction_offsets;
    out["transition_transaction_ids"] = transition_transaction_ids;
    out["transition_transaction_statuses"] = transition_transaction_statuses;
    out["ideology_slots_used"] = ideology_slot_cost(*country);
    out["ideology_slots_capacity"] = handle_valid
        ? ideology_capacity_for(country_slot_id) : _ideology_capacity;
    out["national_spirit_slots_used"] = spirit_slot_cost(*country);
    out["national_spirit_slots_capacity"] = handle_valid
        ? spirit_capacity_for(country_slot_id) : _spirit_capacity;
    out["offer_active"] = country->offer.active != 0;
    out["offer_generation"] = static_cast<int64_t>(country->offer.generation);
    out["offer_choice_count"] = static_cast<int32_t>(country->offer.choice_count);
    out["offer_ids"] = offer_ids;
    uint64_t support_revision = 0;
    if (_economy_runtime != nullptr) {
        const NativeEconomyRuntime::CountryClassOpinionSnapshot &opinion =
            _economy_runtime->country_class_opinion_snapshot();
        const int32_t country_slot =
            static_cast<int32_t>(country->handle & 0xffffffffULL);
        if (opinion.class_hash == _political_class_hash &&
                opinion.class_count == _political_class_count &&
                country_slot >= 0 && country_slot < opinion.country_count &&
                country_slot < static_cast<int32_t>(
                    opinion.country_handles.size()) &&
                opinion.country_handles[static_cast<size_t>(country_slot)] ==
                    country->handle)
            support_revision = opinion.revision;
    }
    out["support_revision"] = static_cast<int64_t>(support_revision);
    out["last_error"] = String(_last_error.c_str());
    return out;
}
Dictionary NativeIdeologyRuntime::preview_offer_eligibility(int64_t handle) const {
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["can_draw"] = false;
    out["can_reroll"] = false;
    if (!_configured) { out["ok"] = false; out["reason"] = "ideology_runtime_unconfigured"; return out; }
    int32_t slot = -1;
    if (!validate_country(static_cast<uint64_t>(handle), slot)) {
        out["reason"] = "ideology_country_handle_stale";
        return out;
    }
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    CountryState scratch;
    if (country == nullptr) {
        init_country_state(scratch, static_cast<uint64_t>(handle));
        country = &scratch;
    }
    const int64_t cost = offer_cost_for(country->draw_sequence);
    const int64_t reroll = reroll_cost_for(country->draw_sequence, country->handle);
    const int32_t pool = draw_pool_size(*country, slot);
    out["points_q16"] = country->ideology_points_q16;
    out["free_draws"] = static_cast<int64_t>(country->free_draws);
    out["cost_q16"] = cost;
    out["reroll_cost_q16"] = reroll;
    out["pool_size"] = pool;
    out["offer_active"] = country->offer.active != 0;
    out["offer_generation"] = static_cast<int64_t>(country->offer.generation);
    out["offer_choice_count"] = static_cast<int32_t>(country->offer.choice_count);
    String reason = "";
    if (country->offer.active != 0) reason = "ideology_offer_pending";
    else if (pool <= 0) reason = "ideology_offer_pool_insufficient";
    else if (country->free_draws == 0 &&
            country->ideology_points_q16 < cost)
        reason = "ideology_points_insufficient";
    out["can_draw"] = reason.is_empty();
    out["reason"] = reason;
    out["can_reroll"] = country->offer.active != 0 && pool > 0 &&
        country->ideology_points_q16 >= reroll;
    return out;
}
Dictionary NativeIdeologyRuntime::explain(int64_t handle, int32_t id) {
    if (id < 0 || id >= static_cast<int32_t>(_definitions.size()))
        return fail("ideology_id_invalid");
    Dictionary out;
    out["ok"] = true;
    out["ideology_id"] = id;
    CountryState *country =
        country_state_for(static_cast<uint64_t>(handle), false);
    const IdeaState *state =
        country == nullptr ? nullptr : idea_state_for(*country, id);
    const Definition &definition =
        _definitions[static_cast<size_t>(id)];
    out["known"] = country != nullptr && known(*country, id);
    out["level"] = state == nullptr ? -1 : state->level;
    out["understanding_q16"] =
        state == nullptr ? 0 : state->understanding_q16;
    out["location"] = state == nullptr ? INACTIVE : state->location;
    PackedInt64Array thresholds;
    PackedInt64Array daily;
    for (int32_t level = 0; level < definition.level_count; ++level) {
        thresholds.append(_levels[static_cast<size_t>(
            definition.level_begin + level)].threshold_q16);
        daily.append(_levels[static_cast<size_t>(
            definition.level_begin + level)].daily_understanding_q16);
    }
    out["thresholds_q16"] = thresholds;
    out["daily_understanding_q16"] = daily;
    out["min_spirit_level"] = definition.min_spirit_level;
    PackedInt32Array support_q16;
    PackedInt32Array support_thresholds;
    PackedInt32Array blocking_classes;
    PackedByteArray support_available;
    PackedByteArray support_allowed;
    uint64_t revision = 0;
    for (int32_t direction = SUPPORT_ADOPT;
            direction <= SUPPORT_PROMOTE; ++direction) {
        const SupportResult support = country == nullptr
            ? SupportResult{}
            : evaluate_support(*country, id,
                static_cast<SupportDirection>(direction));
        support_q16.append(support.support_q16);
        support_thresholds.append(support.threshold_q16);
        blocking_classes.append(support.blocking_class);
        support_available.append(support.available ? 1 : 0);
        support_allowed.append(support.allowed ? 1 : 0);
        revision = std::max(revision, support.revision);
    }
    out["support_q16"] = support_q16;
    out["support_thresholds_q16"] = support_thresholds;
    out["support_blocking_classes"] = blocking_classes;
    out["support_available"] = support_available;
    out["support_allowed"] = support_allowed;
    out["support_revision"] = static_cast<int64_t>(revision);
    PackedInt32Array stance_classes;
    PackedInt64Array class_influence;
    PackedInt32Array adopt_stances;
    PackedInt32Array repeal_stances;
    PackedInt32Array promote_stances;
    PackedInt64Array adopt_contributions;
    PackedInt64Array repeal_contributions;
    PackedInt64Array promote_contributions;
    for (int32_t row = definition.stance_begin;
            row < definition.stance_begin + definition.stance_count; ++row) {
        const ClassStance &stance =
            _class_stances[static_cast<size_t>(row)];
        const int64_t influence =
            country != nullptr &&
                    static_cast<size_t>(stance.class_index) <
                        country->class_influence.size()
                ? country->class_influence[
                    static_cast<size_t>(stance.class_index)] : 0;
        stance_classes.append(stance.class_index);
        class_influence.append(influence);
        adopt_stances.append(stance.stance_q16[SUPPORT_ADOPT]);
        repeal_stances.append(stance.stance_q16[SUPPORT_REPEAL]);
        promote_stances.append(stance.stance_q16[SUPPORT_PROMOTE]);
        adopt_contributions.append(mul_sat(influence,
            stance.stance_q16[SUPPORT_ADOPT]));
        repeal_contributions.append(mul_sat(influence,
            stance.stance_q16[SUPPORT_REPEAL]));
        promote_contributions.append(mul_sat(influence,
            stance.stance_q16[SUPPORT_PROMOTE]));
    }
    out["stance_class_indices"] = stance_classes;
    out["class_influence"] = class_influence;
    out["adopt_stances_q16"] = adopt_stances;
    out["repeal_stances_q16"] = repeal_stances;
    out["promote_stances_q16"] = promote_stances;
    out["adopt_contributions"] = adopt_contributions;
    out["repeal_contributions"] = repeal_contributions;
    out["promote_contributions"] = promote_contributions;
    PackedInt32Array affected_synergy_ids;
    PackedByteArray current_synergy_active;
    PackedByteArray expected_synergy_active;
    if (country != nullptr && id + 1 <
            static_cast<int32_t>(_ideology_synergy_offsets.size())) {
        for (int32_t cursor =
                _ideology_synergy_offsets[static_cast<size_t>(id)];
                cursor < _ideology_synergy_offsets[
                    static_cast<size_t>(id + 1)]; ++cursor) {
            const int32_t synergy_id =
                _ideology_synergy_ids[static_cast<size_t>(cursor)];
            affected_synergy_ids.append(synergy_id);
            current_synergy_active.append(
                synergy_active(*country, synergy_id) ? 1 : 0);
            expected_synergy_active.append(
                synergy_requirements_met(*country, synergy_id) ? 1 : 0);
        }
    }
    out["affected_synergy_ids"] = affected_synergy_ids;
    out["current_synergy_active"] = current_synergy_active;
    out["expected_synergy_active"] = expected_synergy_active;
    return out;
}

Dictionary NativeIdeologyRuntime::explain_batch(int64_t handle,
        const PackedInt32Array &requested_ids) {
    CountryState *country =
        country_state_for(static_cast<uint64_t>(handle), false);
    if (country == nullptr) return fail("ideology_country_unknown");

    PackedInt32Array ids;
    if (requested_ids.is_empty()) {
        for (int32_t id = 0;
                id < static_cast<int32_t>(_definitions.size()); ++id)
            if (known(*country, id)) ids.append(id);
    } else {
        std::vector<uint8_t> seen(_definitions.size(), 0);
        for (const int32_t id : requested_ids) {
            if (id < 0 || id >= static_cast<int32_t>(_definitions.size()))
                return fail("ideology_id_invalid");
            if (seen[static_cast<size_t>(id)] != 0) continue;
            seen[static_cast<size_t>(id)] = 1;
            ids.append(id);
        }
    }

    PackedInt32Array support_q16;
    PackedInt32Array support_thresholds;
    PackedInt32Array blocking_classes;
    PackedByteArray support_available;
    PackedByteArray support_allowed;
    PackedByteArray equip_allowed;
    PackedByteArray unequip_allowed;
    PackedByteArray promote_allowed;
    PackedByteArray exclusion_allowed;
    PackedInt32Array stance_offsets;
    PackedInt32Array stance_class_indices;
    PackedInt64Array class_influence;
    PackedInt64Array adopt_contributions;
    PackedInt64Array repeal_contributions;
    PackedInt64Array promote_contributions;
    PackedInt32Array synergy_offsets;
    PackedInt32Array affected_synergy_ids;
    PackedByteArray current_synergy_active;
    PackedByteArray equip_synergy_active;
    PackedByteArray unequip_synergy_active;
    PackedByteArray promote_synergy_active;
    stance_offsets.append(0);
    synergy_offsets.append(0);
    uint64_t revision = 0;

    auto requirements_met_with_override =
        [&](int32_t synergy_id, int32_t override_ideology_id,
                uint8_t override_location,
                int32_t override_level) -> bool {
        if (synergy_id < 0 ||
                synergy_id >= static_cast<int32_t>(_synergies.size()))
            return false;
        const Synergy &synergy =
            _synergies[static_cast<size_t>(synergy_id)];
        for (int32_t row = synergy.requirement_begin;
                row < synergy.requirement_begin + synergy.requirement_count;
                ++row) {
            const SynergyRequirement &requirement =
                _synergy_requirements[static_cast<size_t>(row)];
            const IdeaState *required_state =
                idea_state_for(*country, requirement.ideology_id);
            const uint8_t location =
                requirement.ideology_id == override_ideology_id
                ? override_location
                : (required_state == nullptr
                    ? INACTIVE : required_state->location);
            const int32_t level =
                requirement.ideology_id == override_ideology_id
                ? override_level
                : (required_state == nullptr ? -1 : required_state->level);
            if (level < requirement.minimum_level ||
                    (requirement.location_mask & (1U << location)) == 0)
                return false;
        }
        return true;
    };

    for (const int32_t id : ids) {
        const Definition &definition =
            _definitions[static_cast<size_t>(id)];
        IdeaState *state = idea_state_for(*country, id, false);
        std::array<SupportResult, 3> supports;
        for (int32_t direction = SUPPORT_ADOPT;
                direction <= SUPPORT_PROMOTE; ++direction) {
            supports[static_cast<size_t>(direction)] =
                evaluate_support(*country, id,
                    static_cast<SupportDirection>(direction));
            const SupportResult &support =
                supports[static_cast<size_t>(direction)];
            support_q16.append(support.support_q16);
            support_thresholds.append(support.threshold_q16);
            blocking_classes.append(support.blocking_class);
            support_available.append(support.available ? 1 : 0);
            support_allowed.append(support.allowed ? 1 : 0);
            revision = std::max(revision, support.revision);
        }

        std::string ignored;
        const bool exclusion_ok = exclusion_allows(*country, id, ignored);
        exclusion_allowed.append(exclusion_ok ? 1 : 0);
        const bool state_pending =
            state != nullptr && state->transition.active != 0;
        const bool country_pending =
            country->pending_transition_count > 0 && !_synergies.empty();
        const uint8_t location =
            state == nullptr ? INACTIVE : state->location;
        const int32_t reconciled_level =
            state == nullptr ? -1
            : std::max(state->level, unlocked_level(*state));
        equip_allowed.append(
            known(*country, id) && state != nullptr &&
            location == INACTIVE && !state_pending && !country_pending &&
            exclusion_ok && supports[SUPPORT_ADOPT].allowed &&
            country->ideology_slots_used + definition.ideology_cost <=
                _ideology_capacity ? 1 : 0);
        unequip_allowed.append(
            state != nullptr && location == IDEOLOGY &&
            !state_pending && !country_pending &&
            supports[SUPPORT_REPEAL].allowed ? 1 : 0);
        promote_allowed.append(
            state != nullptr && location == IDEOLOGY &&
            !state_pending && !country_pending &&
            reconciled_level >= definition.min_spirit_level &&
            country->spirit_slots_used + definition.spirit_cost <=
                _spirit_capacity &&
            supports[SUPPORT_PROMOTE].allowed ? 1 : 0);

        for (int32_t row = definition.stance_begin;
                row < definition.stance_begin + definition.stance_count;
                ++row) {
            const ClassStance &stance =
                _class_stances[static_cast<size_t>(row)];
            const int64_t influence =
                static_cast<size_t>(stance.class_index) <
                    country->class_influence.size()
                ? country->class_influence[
                    static_cast<size_t>(stance.class_index)] : 0;
            stance_class_indices.append(stance.class_index);
            class_influence.append(influence);
            adopt_contributions.append(mul_sat(influence,
                stance.stance_q16[SUPPORT_ADOPT]));
            repeal_contributions.append(mul_sat(influence,
                stance.stance_q16[SUPPORT_REPEAL]));
            promote_contributions.append(mul_sat(influence,
                stance.stance_q16[SUPPORT_PROMOTE]));
        }
        stance_offsets.append(stance_class_indices.size());

        if (id + 1 < static_cast<int32_t>(
                _ideology_synergy_offsets.size())) {
            for (int32_t cursor =
                    _ideology_synergy_offsets[static_cast<size_t>(id)];
                    cursor < _ideology_synergy_offsets[
                        static_cast<size_t>(id + 1)]; ++cursor) {
                const int32_t synergy_id =
                    _ideology_synergy_ids[static_cast<size_t>(cursor)];
                affected_synergy_ids.append(synergy_id);
                current_synergy_active.append(
                    synergy_active(*country, synergy_id) ? 1 : 0);
                equip_synergy_active.append(
                    requirements_met_with_override(synergy_id, id,
                        IDEOLOGY, reconciled_level) ? 1 : 0);
                unequip_synergy_active.append(
                    requirements_met_with_override(synergy_id, id,
                        INACTIVE, reconciled_level) ? 1 : 0);
                promote_synergy_active.append(
                    requirements_met_with_override(synergy_id, id,
                        NATIONAL_SPIRIT, reconciled_level) ? 1 : 0);
            }
        }
        synergy_offsets.append(affected_synergy_ids.size());
    }

    Dictionary out;
    out["ok"] = true;
    out["ideology_ids"] = ids;
    out["support_revision"] = static_cast<int64_t>(revision);
    out["support_q16"] = support_q16;
    out["support_thresholds_q16"] = support_thresholds;
    out["support_blocking_classes"] = blocking_classes;
    out["support_available"] = support_available;
    out["support_allowed"] = support_allowed;
    out["equip_allowed"] = equip_allowed;
    out["unequip_allowed"] = unequip_allowed;
    out["promote_allowed"] = promote_allowed;
    out["exclusion_allowed"] = exclusion_allowed;
    out["stance_offsets"] = stance_offsets;
    out["stance_class_indices"] = stance_class_indices;
    out["class_influence"] = class_influence;
    out["adopt_contributions"] = adopt_contributions;
    out["repeal_contributions"] = repeal_contributions;
    out["promote_contributions"] = promote_contributions;
    out["affected_synergy_offsets"] = synergy_offsets;
    out["affected_synergy_ids"] = affected_synergy_ids;
    out["current_synergy_active"] = current_synergy_active;
    out["equip_synergy_active"] = equip_synergy_active;
    out["unequip_synergy_active"] = unequip_synergy_active;
    out["promote_synergy_active"] = promote_synergy_active;
    return out;
}

Dictionary NativeIdeologyRuntime::report() const {
    Dictionary out;
    out["configured"] = _configured;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    // Plan §11.5: the execution-contract identity this runtime is executing under. A
    // reader compares it with what an archive claims, which is how an archive produced
    // under different execution rules gets refused instead of reinterpreted.
    out["execution_contract_hash"] = static_cast<int64_t>(compute_execution_contract_hash());
    out["ideology_count"] = static_cast<int32_t>(_definitions.size());
    out["countries_allocated"] = static_cast<int32_t>(_countries.size());
    out["pending_commands"] = static_cast<int32_t>(pending_command_count());
    out["pending_transitions"] = static_cast<int32_t>(_pending_transitions.size());
    out["active_visits"] = static_cast<int64_t>(_active_visits);
    out["dormant_scan_count"] = static_cast<int64_t>(_dormant_scan_count);
    out["sparse_idea_scan_count"] = static_cast<int64_t>(_sparse_idea_scan_count);
    out["pending_transition_visits"] = static_cast<int64_t>(_pending_transition_visits);
    out["command_queue_resorts"] = static_cast<int64_t>(_command_queue_resorts);
    out["command_queue_shift_steps"] = static_cast<int64_t>(_command_queue_shift_steps);
    out["command_queue_merge_steps"] = static_cast<int64_t>(_command_queue_merge_steps);
    out["derived_rebuild_visits"] = static_cast<int64_t>(_derived_rebuild_visits);
    // Cell-layer rebuild diagnostics (plan 22 §12.4). `cell_layer_rebuild_visits`
    // counts calls to the sharded rebuild, which is a different question
    // from `derived_rebuild_visits` above (an idea-iteration counter).
    out["cell_layer_rebuild_visits"] = static_cast<int64_t>(_cell_layer_rebuild_visits);
    out["cell_layer_rebuild_skips"] = static_cast<int64_t>(_cell_layer_rebuild_skips);
    out["cell_layer_rebuild_ms"] = _cell_layer_rebuild_ms;
    // §14.3: split so a slice boundary can be placed where the time actually goes.
    out["cell_layer_collect_ms"] = _derived_collect_ms;
    out["cell_layer_materialise_ms"] = _derived_materialise_ms;
    // How many slices the sharded rebuild needed; 1 means it fit in a single step.
    out["cell_layer_rebuild_steps"] = static_cast<int64_t>(_derived_rebuild_steps);
    // A sharded rebuild finishes across several `run_ideology_daily` calls. A caller
    // that reads the layer immediately after one call sees an EMPTY front, which is
    // exactly what broke B7/B8/B10/stress when the stage was introduced -- the tests
    // drive a fixed number of days and never learned that the layer now needs
    // draining. Exposing the flag lets them (and production) wait honestly instead of
    // guessing a call count.
    out["derived_rebuild_pending"] = derived_rebuild_pending();
    // Plan §9.3 asks for the ability to tell which projections are not eligible yet.
    out["derived_basis_confirmed_day"] = _derived_basis_confirmed_day;
    out["derived_basis_eligible_day"] = _derived_basis_eligible_day;
    // Plan §18.2: how many (country, program) rows the LAST projection was built from,
    // and a digest of them. Zero means no derived program has been applied yet -- which
    // is also why a capture of such a world persists an empty basis block, not a
    // fabricated one.
    out["applied_program_basis_rows"] =
        static_cast<int64_t>(_applied_program_basis.size());
    out["applied_program_basis_digest"] = static_cast<int64_t>(
        mix_applied_program_basis(1469598103934665603ULL,
            _applied_program_basis));
    // WHICH program the surviving basis names. A count and a digest cannot tell a no-op
    // from a HALF-WRITE when both sides hold one row, so the atomicity assertion (a
    // refusal that happens AFTER the basis was parsed must leave the previous basis
    // intact) needs the identity itself.
    out["applied_program_basis_first_program"] = String(
        _applied_program_basis.empty()
            ? "" : _applied_program_basis.front().program_key.c_str());
    // §18.5: the local scalar basis the LAST RESTORE installed, and the sample day the
    // last projection was built from. `rows == 0` on a runtime that has never
    // restored is the state the atomicity assertion needs: a refused restore that had
    // already parsed (and committed) a non-empty record must leave BOTH numbers where
    // they were. Same reason as `applied_program_basis_first_program` above, the
    // identity of the first row is reported -- a count and a digest cannot tell a
    // no-op from a half-write when both sides hold one row.
    out["local_scalar_basis_rows"] =
        static_cast<int64_t>(_local_scalar_basis.size());
    out["local_scalar_basis_digest"] = static_cast<int64_t>(
        mix_local_scalar_basis(1469598103934665603ULL, _local_scalar_basis));
    out["local_scalar_basis_first_metric"] = _local_scalar_basis.empty()
        ? -1 : _local_scalar_basis.front().metric_id;
    out["local_scalar_basis_first_value"] = _local_scalar_basis.empty()
        ? 0 : _local_scalar_basis.front().value_q16;
    // §18.5: WHY the last `ideology_save_scalar_basis_mismatch` fired, in one line:
    // row counts on both sides plus the first differing (country, metric, value) pairs.
    // Empty when the last restore did not refuse. A named refusal without this costs a
    // debugging round per firing, which is exactly what happened the first time.
    out["local_scalar_basis_mismatch_detail"] =
        String(_last_scalar_basis_mismatch_detail.c_str());
    out["derived_basis_sample_day"] = _derived_basis_sample_day;
    // §18.5: the epoch id the projection was built against. STRUCTURALLY 0 -- declared
    // once, never assigned, and read only as the DerivedCellMaterializeJob argument --
    // which is exactly why the payload does NOT carry it (see `capture`). Reported so
    // that claim is measurable from outside instead of being a comment.
    out["derived_basis_epoch_id"] = static_cast<int64_t>(_derived_epoch_id);
    out["derived_rebuild_gated_by_eligibility"] =
        _derived_rebuild_gated_by_eligibility;
    // Non-zero proves the sharded path EVALUATED ramp terms instead of deferring them.
    out["ramp_samples_taken"] = static_cast<int64_t>(_derived_ramp_samples_taken);
    // Proof that the PROGRAM ran, not the metric fallback.
    out["derived_program_evaluations"] =
        static_cast<int64_t>(_derived_program_evaluations);
    out["derived_program_failures"] = static_cast<int64_t>(_derived_program_failures);
    out["ramp_candidates"] = static_cast<int64_t>(_ramp_candidates);
    // I01 evidence: how many programs the old plane SKIPPED because the derived layer
    // owns them. Without this number "the plane no longer double-counts" is not
    // observable from outside.
    out["cell_plane_derived_elsewhere"] =
        static_cast<int64_t>(_cell_plane_derived_elsewhere);
    out["cell_plane_builds"] = static_cast<int64_t>(_cell_plane_builds);
    // Ownership-scope evidence: how many fan-out resolves ran under each scope.
    out["ownership_filtered_resolves"] =
        static_cast<int64_t>(_ownership_filtered_resolves);
    out["ownership_own_resolves"] = static_cast<int64_t>(_ownership_own_resolves);
    out["ownership_foreign_resolves"] =
        static_cast<int64_t>(_ownership_foreign_resolves);
    out["consumer_publish_calls"] = static_cast<int64_t>(_consumer_publish_calls);
    out["consumer_tag_ids"] = _consumer_tag_ids_last;
    out["consumer_levels_with_tags"] = static_cast<int64_t>(_consumer_levels_with_tags);
    out["ramp_metric_ok"] = static_cast<int64_t>(_ramp_metric_ok);
    out["ramp_samples_memoised"] =
        static_cast<int64_t>(_derived_ramp_samples_memoised);
    out["cell_layer_collect_count"] = _derived_collect_count;
    out["cell_layer_collect_rows"] = _derived_collect_rows;
    out["cell_layer_collect_ideas"] = _derived_collect_ideas;
    out["cell_layer_delta_a"] = _derived_first_country_delta;
    out["cell_layer_delta_b"] = _derived_second_country_delta;
    out["cell_layer_contribs_passed"] = _derived_contribs_passed;
    out["cell_layer_rows_emitted"] = _last_derived_materialize.rows_emitted;
    out["cell_layer_allocations"] = _last_derived_materialize.allocations;
    out["cell_layer_cells_visited"] = _last_derived_materialize.cells_visited;
    out["cell_layer_collect_ok"] = _derived_last_collect_ok;
    // M4 diagnosis: which exit `collect_effect_activations` took.
    out["collect_entries"] = static_cast<int64_t>(_collect_entries);
    out["collect_templates"] = static_cast<int64_t>(_collect_templates);
    out["collect_program_empty"] = static_cast<int64_t>(_collect_program_empty);
    out["collect_pod_fail"] = static_cast<int64_t>(_collect_pod_fail);
    {
        PackedStringArray keys;
        for (const std::string &key : _collect_pod_fail_keys) keys.append(key.c_str());
        out["collect_pod_fail_keys"] = keys;
        PackedStringArray ok_keys;
        for (const std::string &key : _collect_pod_ok_keys) ok_keys.append(key.c_str());
        out["collect_pod_ok_keys"] = ok_keys;
    }
    out["collect_targets_fail"] = static_cast<int64_t>(_collect_targets_fail);
    out["collect_derived_emitted"] = static_cast<int64_t>(_collect_derived_emitted);
    out["targets_country_zero"] = static_cast<int64_t>(_targets_country_zero);
    out["targets_domain_gate"] = static_cast<int64_t>(_targets_domain_gate);
    out["targets_economy_null"] = static_cast<int64_t>(_targets_economy_null);
    out["targets_anchor_neg"] = static_cast<int64_t>(_targets_anchor_neg);
    out["targets_collected_empty"] = static_cast<int64_t>(_targets_collected_empty);
    out["targets_fanout_no_tag"] = static_cast<int64_t>(_targets_fanout_no_tag);
    out["targets_fanout_no_source"] = static_cast<int64_t>(_targets_fanout_no_source);
    out["targets_fanout_ring_empty"] = static_cast<int64_t>(_targets_fanout_ring_empty);
    // §18.3 peak memory. Bytes of the derived structure, not process RSS.
    // `scratch` is NOT reported: the materialiser's working buffers are not reachable
    // from here, and a made-up number would be worse than a documented gap.
    out["peak_retained_bytes"] = static_cast<int64_t>(_derived_peak_retained_bytes);
    out["peak_candidate_bytes"] = static_cast<int64_t>(_derived_peak_candidate_bytes);
    out["peak_total_bytes"] = static_cast<int64_t>(_derived_peak_total_bytes);
    // M3 ramp sampling: `taken` counts real metric samples, `memoised` counts
    // country-scope cache hits. For a wide territory a country metric should
    // show memoised >> 0; if taken grows while memoised stays 0, the cache key
    // or the scoped id range is wrong.
    out["ramp_samples_taken"] = static_cast<int64_t>(_ramp_samples_taken);
    out["ramp_samples_memoised"] = static_cast<int64_t>(_ramp_samples_memoised);
    out["ramp_terms_evaluated"] = static_cast<int64_t>(_ramp_terms_evaluated);
    out["ramp_terms_deferred"] = static_cast<int64_t>(_ramp_terms_deferred);
    out["commands_applied"] = static_cast<int64_t>(_commands_applied);
    out["commands_rejected"] = static_cast<int64_t>(_commands_rejected);
    out["offers_opened"] = static_cast<int64_t>(_offers_opened);
    out["levels_advanced"] = static_cast<int64_t>(_levels_advanced);
    out["class_snapshot_reads"] =
        static_cast<int64_t>(_class_snapshot_reads);
    out["political_class_hash"] = static_cast<int64_t>(_political_class_hash);
    out["political_class_count"] = static_cast<int32_t>(_political_class_count);
    out["points_accrue_result"] = static_cast<int32_t>(_points_accrue_result);
    out["points_accrue_revision"] = static_cast<int64_t>(_points_accrue_revision);
    out["points_revision_seen"] = static_cast<int64_t>(_points_revision_seen);
    out["support_evaluations"] =
        static_cast<int64_t>(_support_evaluations);
    out["synergy_candidates_visited"] =
        static_cast<int64_t>(_synergy_candidates_visited);
    out["selector_truncations"] = static_cast<int64_t>(_selector_truncations);
    out["selector_matched_total"] =
        static_cast<int64_t>(_selector_stats.matched_total);
    out["source_count_evaluations"] =
        static_cast<int64_t>(_source_count_evaluations);
    out["metric_publishes"] = static_cast<int64_t>(_metric_publishes);
    out["metric_publishes_skipped"] =
        static_cast<int64_t>(_metric_publishes_skipped);
    out["managed_idea_count"] = static_cast<int64_t>(_managed_active_total);
    out["instance_refresh_visits"] =
        static_cast<int64_t>(_instance_refresh_visits);
    out["cell_plane_rebuilds"] = static_cast<int64_t>(_cell_plane_builds);
    out["synergy_scale_lookups"] = static_cast<int64_t>(_synergy_scale_lookups);
    out["synergy_scale_scans"] = static_cast<int64_t>(_synergy_scale_scans);
    out["instance_refresh_skips"] =
        static_cast<int64_t>(_instance_refresh_skips);
    out["instance_refresh_passes"] =
        static_cast<int64_t>(_instance_refresh_passes);
    out["instance_refresh_lag_revisions"] =
        static_cast<int64_t>(_instance_refresh_lag_revisions);
    out["instance_refresh_pending"] = _instance_refresh_pending;
    out["instance_refresh_ms"] = _instance_refresh_ms;
    out["effect_input_revision_seen"] =
        static_cast<int64_t>(_effect_input_revision_seen);
    out["effect_input_revision_target"] =
        static_cast<int64_t>(_effect_input_revision_target);
    out["effect_input_revision"] = _economy_runtime == nullptr
        ? static_cast<int64_t>(0)
        : static_cast<int64_t>(_economy_runtime->effect_input_revision());
    out["transition_poll_ms"] = _transition_poll_ms;
    out["command_apply_ms"] = _command_apply_ms;
    out["active_progress_ms"] = _active_progress_ms;
    out["last_slice_ms"] = _last_slice_ms;
    out["max_slice_ms"] = _max_slice_ms;
    out["active_progress_day"] = _active_progress_day;
    out["active_country_cursor"] = _active_country_cursor;
    out["active_item_cursor"] = _active_item_cursor;
    out["last_error"] = String(_last_error.c_str());
    return out;
}
uint64_t NativeIdeologyRuntime::compute_execution_contract_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    // 1-4: the rule versions (plan §11.5 bullets 1-4).
    hash = mixv(hash, kExecutionSemanticsVersion);
    hash = mixv(hash, kProgramBackendVersion);
    hash = mixv(hash, kSelectorUnboundedVersion);
    hash = mixv(hash, kSourceCountDecodeVersion);
    hash = mixv(hash, kEvaluatorVersion);
    hash = mixv(hash, kEligibilityVersion);
    // 5: the participating compile identities. The ideology catalog hash already covers
    // routes / schools / stat keys / capacities / weights; the Effect and Modifier hashes
    // cover the program and modifier catalogs this layer folds against. A 0 here means
    // that side is absent, and is hashed as such rather than skipped -- "no Effect
    // runtime" is a different contract from "an Effect runtime with hash 0".
    hash = mixv(hash, _catalog_hash);
    hash = mixv(hash, _effect_runtime != nullptr
        ? _effect_runtime->catalog_hash() : uint64_t{0});
    hash = mixv(hash, _modifier_runtime != nullptr
        ? _modifier_runtime->catalog_hash() : uint64_t{0});
    return hash;
}

uint64_t NativeIdeologyRuntime::compute_catalog_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    // Route ids feed ideology-local scalars and are therefore part of the
    // catalog contract, not presentation metadata.
    for (const std::string &route : _route_keys)
        hash = mix(hash, route.data(), route.size());
    for (const std::string &school : _school_keys)
        hash = mix(hash, school.data(), school.size());
    for (const std::string &stat : _school_strength_factor_stat_keys)
        hash = mix(hash, stat.data(), stat.size());
    for (const Definition &definition : _definitions)
        hash = mixv(hash, definition.route_mask);
    hash = mixv(hash, _ideology_capacity);
    hash = mixv(hash, _spirit_capacity);
    hash = mixv(hash, _offer_cost_q16);
    hash = mixv(hash, _starting_points_q16);
    hash = mixv(hash, _political_class_hash);
    hash = mixv(hash, _opinion_owner_influence_weight);
    hash = mixv(hash, _opinion_funds_per_influence);
    hash = mixv(hash, _ideology_capacity_max);
    hash = mixv(hash, _spirit_capacity_max);
    hash = mixv(hash, _offer_cost_growth_percent);
    hash = mixv(hash, _offer_cost_max_q16);
    hash = mixv(hash, _reroll_cost_percent);
    hash = mixv(hash, _point_population_weight_q16);
    hash = mixv(hash, _point_building_weight_q16);
    hash = mixv(hash, _point_trade_weight_q16);
    hash = mixv(hash, _point_gain_cap_q16);
    hash = mix(hash, _point_gain_stat_key.data(), _point_gain_stat_key.size());
    hash = mix(hash, _point_population_factor_stat_key.data(),
               _point_population_factor_stat_key.size());
    hash = mix(hash, _point_building_factor_stat_key.data(),
               _point_building_factor_stat_key.size());
    hash = mix(hash, _point_trade_factor_stat_key.data(),
               _point_trade_factor_stat_key.size());
    hash = mix(hash, _opinion_factor_floor_stat_key.data(),
               _opinion_factor_floor_stat_key.size());
    hash = mix(hash, _understanding_gain_stat_key.data(),
               _understanding_gain_stat_key.size());
    hash = mix(hash, _reroll_cost_stat_key.data(), _reroll_cost_stat_key.size());
    // The draw-side knobs belong in the hash for the same reason the decay curve
    // does: a peer that resolves a different floor or row count draws a different
    // card from the same seed, and a mismatched hash is the only place that is
    // ever reported by name instead of as a replay divergence days later.
    hash = mix(hash, _era_decay_floor_stat_key.data(),
               _era_decay_floor_stat_key.size());
    hash = mix(hash, _offer_choice_bonus_stat_key.data(),
               _offer_choice_bonus_stat_key.size());
    hash = mixv(hash, _refine_weight_bp);
    hash = mixv(hash, _refine_understanding_q16);
    // Draw weighting is part of the catalog contract: two peers that disagree on
    // the decay curve would silently draw different cards from the same seed.
    for (const int32_t decay : _era_decay_bp) hash = mixv(hash, decay);
    for (const int32_t milestone : _era_milestone_technologies)
        hash = mixv(hash, milestone);
    for (const CapacityUnlock &unlock : _capacity_unlocks) {
        hash = mixv(hash, unlock.technology_id);
        hash = mixv(hash, unlock.ideology_delta);
        hash = mixv(hash, unlock.spirit_delta);
    }
    for (const Definition &definition : _definitions) {
        hash = mix(hash, definition.stable_id.data(),
            definition.stable_id.size());
        hash = mixv(hash, definition.acquisition);
        hash = mixv(hash, definition.copy_left_programs);
        hash = mixv(hash, definition.copyable);
        hash = mixv(hash, definition.school_index);
        hash = mixv(hash, definition.rarity_weight);
        hash = mixv(hash, definition.ideology_cost);
        hash = mixv(hash, definition.spirit_cost);
        hash = mixv(hash, definition.min_spirit_level);
        hash = mixv(hash, definition.stance_begin);
        hash = mixv(hash, definition.stance_count);
        for (const int32_t threshold :
                definition.support_threshold_q16)
            hash = mixv(hash, threshold);
        hash = mixv(hash, definition.exclusion_group_id);
        hash = mixv(hash, definition.era_index);
    }
    for (const Level &level : _levels) {
        hash = mixv(hash, level.threshold_q16);
        hash = mixv(hash, level.daily_understanding_q16);
    }
    for (const ClassStance &stance : _class_stances) {
        hash = mixv(hash, stance.class_index);
        for (const int32_t value : stance.stance_q16)
            hash = mixv(hash, value);
        for (const int32_t value : stance.critical_min_q16)
            hash = mixv(hash, value);
    }
    for (const SynergyRequirement &requirement :
            _synergy_requirements) {
        hash = mixv(hash, requirement.ideology_id);
        hash = mixv(hash, requirement.minimum_level);
        hash = mixv(hash, requirement.location_mask);
    }
    for (const Synergy &synergy : _synergies) {
        hash = mixv(hash, synergy.requirement_begin);
        hash = mixv(hash, synergy.requirement_count);
        hash = mixv(hash, synergy.effect_begin);
        hash = mixv(hash, synergy.effect_count);
        hash = mixv(hash, synergy.min_count);
        hash = mixv(hash, synergy.override_begin);
        hash = mixv(hash, synergy.override_count);
    }
    // The override rows themselves are part of the contract: two peers that
    // disagree on how hard a synergy rewrites a program would produce different
    // modifier values from the same state and never report why.
    for (const SynergyOverride &override : _synergy_overrides) {
        hash = mixv(hash, override.match_kind);
        hash = mixv(hash, override.field);
        hash = mixv(hash, override.value);
        hash = mix(hash, override.match_value.data(),
            override.match_value.size());
        hash = mix(hash, override.tag_name.data(), override.tag_name.size());
    }
    return hash;
}
// Hash of the state this runtime currently holds, basis included.
//
// Capture and restore deliberately call `compute_state_hash_with` instead: both of them
// need the rows for the payload anyway, and re-deriving them here would resolve every
// program twice on a save. This entry point is the honest "what does my state hash to"
// for anything that has no rows in hand -- and it is what makes "the hash covers the
// basis" true by construction rather than by the caller remembering to pass them.
uint64_t NativeIdeologyRuntime::compute_state_hash() const {
    std::vector<AppliedProgramBasis> basis;
    rebuild_applied_program_basis(_countries, basis);
    std::vector<LocalScalarValue> scalars;
    rebuild_local_scalar_basis(_countries, scalars);
    return compute_state_hash_with(basis, scalars, _derived_basis_sample_day);
}

uint64_t NativeIdeologyRuntime::compute_state_hash_with(
        const std::vector<AppliedProgramBasis> &basis,
        const std::vector<LocalScalarValue> &scalars,
        int64_t sample_day) const {
    uint64_t hash = _catalog_hash;
    // NOTE: `_execution_contract_hash` is deliberately NOT mixed in here.
    //
    // It is validated explicitly on restore with its own named reason
    // (`cell_program_execution_contract_mismatch`), which is what plan §11.5 requires:
    // "该身份进入整包兼容检查 … 旧档默认明确拒读". Folding it into the state hash as
    // well was belt-and-braces, and it made the hash sensitive to any difference between
    // the capture and restore runtimes -- which refused a fixture that captures and
    // restores on the same runtime for reasons unrelated to the contract. Two checks for
    // one property, one of which can misfire, is worse than one precise check.
    // Plan §9.3 basis dates. Hashed because they are now persisted: an unhashed
    // persisted scalar is one a corrupted payload can rewrite undetected.
    hash = mixv(hash, _derived_basis_confirmed_day);
    hash = mixv(hash, _derived_basis_eligible_day);
    for (const CountryState &country : _countries) {
        hash = mixv(hash, country.handle); hash = mixv(hash, country.ideology_points_q16);
        hash = mixv(hash, country.rng_state); hash = mixv(hash, country.draw_sequence);
        hash = mixv(hash, country.free_draws);
        hash = mixv(hash, country.points_revision); hash = mixv(hash, country.baseline_ready);
        hash = mixv(hash, country.baseline_population); hash = mixv(hash, country.baseline_buildings);
        hash = mixv(hash, country.lifetime_points_q16); hash = mixv(hash, country.ledger.gain_q16);
        hash = mixv(hash, country.history_count); hash = mixv(hash, country.history_head);
        hash = mixv(hash, country.unlocked_era);
        for (int64_t value : country.history_q16) hash = mixv(hash, value);
        for (uint64_t word : country.known_bits) hash = mixv(hash, word);
        for (uint64_t word : country.gate_bits) hash = mixv(hash, word);
        for (const IdeaState &state : country.ideas) {
            hash = mixv(hash, state.ideology_id); hash = mixv(hash, state.understanding_q16);
            hash = mixv(hash, state.level); hash = mixv(hash, state.entered_levels);
            hash = mixv(hash, state.generation); hash = mixv(hash, state.location);
            hash = mixv(hash, state.slot_index);
            hash = mixv(hash, state.binding_id); hash = mixv(hash, state.binding_generation);
            hash = mixv(hash, state.binding_signature); hash = mixv(hash, state.binding_program_hash);
            hash = mixv(hash, state.transition.active);
            hash = mixv(hash, state.transition.previous_level);
            hash = mixv(hash, state.transition.previous_entered_levels);
            hash = mixv(hash, state.transition.previous_generation);
            hash = mixv(hash, state.transition.previous_location);
            hash = mixv(hash, state.transition.previous_slot_index);
            hash = mixv(hash, state.transition.entered_on_success);
            for (int64_t transaction_id : state.transition.transaction_ids)
                hash = mixv(hash, transaction_id);
        }
    }
    // Plan §18.2: the applied-program basis is persisted, so it is hashed too. An
    // unhashed persisted block is one a corrupted payload can rewrite undetected --
    // which is exactly the argument the two basis dates above already make.
    hash = mix_applied_program_basis(hash, basis);
    // Plan §18.5: the local scalar basis and the sample day the projection was built
    // from. Same argument. The sample day is hashed here rather than beside the two
    // dates above because it belongs to the same record as these rows: the rows are
    // WHAT the projection read, the day is WHEN.
    hash = mix_local_scalar_basis(hash, scalars);
    hash = mixv(hash, sample_day);
    return hash;
}

uint64_t NativeIdeologyRuntime::mix_applied_program_basis(
        uint64_t hash, const std::vector<AppliedProgramBasis> &basis) {
    hash = mixv(hash, static_cast<uint64_t>(basis.size()));
    for (const AppliedProgramBasis &row : basis) {
        hash = mixv(hash, row.country_handle);
        hash = mixv(hash, static_cast<uint64_t>(row.program_key.size()));
        hash = mix(hash, row.program_key.data(), row.program_key.size());
        hash = mixv(hash, static_cast<int32_t>(row.selector_kind));
        hash = mixv(hash, static_cast<uint64_t>(row.selector_id.size()));
        hash = mix(hash, row.selector_id.data(), row.selector_id.size());
        hash = mixv(hash, row.selector_param[0]);
        hash = mixv(hash, row.selector_param[1]);
        hash = mixv(hash, row.terms_digest);
    }
    return hash;
}

bool NativeIdeologyRuntime::build_applied_program_basis_row(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        AppliedProgramBasis &out) const {
    out = AppliedProgramBasis{};
    if (_effect_runtime == nullptr || program.empty()) return false;
    // The SAME eligibility decision the collector consults (I01), so a program the
    // instance path owns can never appear in the basis and vice versa.
    const CellProgramFacts facts = cell_program_facts_for(program, metadata, state);
    const CellProgramDecision backend = decide_cell_program_backend(facts);
    if (backend.backend != CellProgramBackend::DerivedCell) return false;
    if (!cell_program_rollout_enabled(metadata.target_selector_kind)) return false;
    // The EFFECTIVE selector: a country's active synergy can rewrite the selector
    // kind, its tag and its parameters, so recording the authored one would let two
    // worlds with different synergy rows look identical here.
    const EffectRuntime::FamilyEffectMetadataPod effective =
        effective_selector_metadata(country, program, metadata);
    std::vector<DerivedProgramContribution::Term> terms;
    resolve_program_fold_terms(metadata, program, terms, false);
    out.country_handle = country.handle;
    out.program_key = program;
    out.selector_kind = effective.target_selector_kind;
    out.selector_id = effective.target_selector_id;
    out.selector_param[0] = effective.target_selector_param[0];
    out.selector_param[1] = effective.target_selector_param[1];
    out.terms_digest = 1469598103934665603ULL;
    out.terms_digest = mixv(out.terms_digest,
        static_cast<uint64_t>(terms.size()));
    for (const DerivedProgramContribution::Term &term : terms) {
        out.terms_digest = mixv(out.terms_digest,
            static_cast<int32_t>(term.stat_id));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<int32_t>(term.operation));
        out.terms_digest = mixv(out.terms_digest, basis_quantise(term.add));
        out.terms_digest = mixv(out.terms_digest, basis_quantise(term.factor));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<uint32_t>(term.magnitude_source));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<int32_t>(term.metric_id));
        out.terms_digest = mixv(out.terms_digest,
            basis_quantise(term.ramp_scale));
        out.terms_digest = mixv(out.terms_digest,
            basis_quantise(term.ramp_floor));
        out.terms_digest = mixv(out.terms_digest,
            basis_quantise(term.ramp_ceil));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<uint8_t>(term.ramp_has_ceil ? 1 : 0));
        // The ramp's program key decides WHICH instruction stream produces the
        // magnitude, so a change there is a semantic change even when every number
        // above happens to match.
        const std::string empty;
        const std::string &key = term.program_key != nullptr
            ? *term.program_key : empty;
        out.terms_digest = mixv(out.terms_digest,
            static_cast<uint64_t>(key.size()));
        out.terms_digest = mix(out.terms_digest, key.data(), key.size());
    }
    return true;
}

void NativeIdeologyRuntime::rebuild_applied_program_basis(
        const std::vector<CountryState> &countries,
        std::vector<AppliedProgramBasis> &out) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    std::vector<const EffectTemplate *> templates;
    for (const CountryState &country : countries) {
        if (country.handle == 0) continue;
        for (const IdeaState &state : country.ideas) {
            int32_t contribution_level = -1;
            if (!resolve_contribution_templates(country, state,
                    contribution_level, templates))
                continue;
            for (const EffectTemplate *templ_ptr : templates) {
                if (templ_ptr == nullptr) continue;
                const std::string program =
                    effect_program_key(templ_ptr->definition_key);
                if (program.empty()) continue;
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
                    continue;
                AppliedProgramBasis row;
                if (!build_applied_program_basis_row(country, state, program,
                        metadata, row))
                    continue;
                out.push_back(std::move(row));
            }
        }
    }
    // Deterministic order and one row per (country, program). `stable_sort` keeps
    // the iteration order for a collision, so two cards carrying the same program
    // resolve the same way on both sides of a save -- a plain `sort` would let the
    // winner depend on the sort's internals.
    std::stable_sort(out.begin(), out.end(),
        [](const AppliedProgramBasis &lhs, const AppliedProgramBasis &rhs) {
            if (lhs.country_handle != rhs.country_handle)
                return lhs.country_handle < rhs.country_handle;
            return lhs.program_key < rhs.program_key;
        });
    out.erase(std::unique(out.begin(), out.end(),
        [](const AppliedProgramBasis &lhs, const AppliedProgramBasis &rhs) {
            return lhs.country_handle == rhs.country_handle &&
                lhs.program_key == rhs.program_key;
        }), out.end());
}
PackedByteArray NativeIdeologyRuntime::capture() const {
    PackedByteArray out;
    if (!_configured) return out;
    // One derivation, used twice: the payload's basis block AND the state hash that
    // covers it. Resolving every program twice on a save is the only alternative.
    std::vector<AppliedProgramBasis> basis;
    rebuild_applied_program_basis(_countries, basis);
    // §18.5: the same treatment for the local scalar basis -- re-derived from the
    // payload's own country rows through the CURRENT catalogs, never read from
    // `_local_scalar_basis`. That member records what the last RESTORE installed and
    // goes stale the moment a card is equipped or levelled, which would make a
    // payload refuse its own world.
    std::vector<LocalScalarValue> scalars;
    rebuild_local_scalar_basis(_countries, scalars);
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC); append_le<int32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash); append_le<int64_t>(bytes, _last_day);
    append_le<uint64_t>(bytes, _submit_order);
    append_le<uint64_t>(bytes,
        compute_state_hash_with(basis, scalars, _derived_basis_sample_day));
    std::vector<std::pair<int32_t, int64_t>> high_watermarks(
        _producer_high_watermarks.begin(), _producer_high_watermarks.end());
    std::sort(high_watermarks.begin(), high_watermarks.end());
    append_le<uint64_t>(bytes, static_cast<uint64_t>(high_watermarks.size()));
    for (const auto &entry : high_watermarks) {
        append_le<int32_t>(bytes, entry.first);
        append_le<int64_t>(bytes, entry.second);
    }
    append_le<uint64_t>(bytes, _points_revision_seen);
    append_le<uint8_t>(bytes, _worker_origin ? 1u : 0u);
    append_le<uint64_t>(bytes, static_cast<uint64_t>(_countries.size()));
    for (const CountryState &country : _countries) {
        append_le<uint64_t>(bytes, country.handle); append_le<int64_t>(bytes, country.ideology_points_q16);
        append_le<int32_t>(bytes, country.unlocked_era);
        append_le<uint64_t>(bytes, country.rng_state); append_le<uint64_t>(bytes, country.draw_sequence);
        append_le<uint16_t>(bytes, country.free_draws);
        append_le<uint64_t>(bytes, country.points_revision);
        append_le<uint8_t>(bytes, country.baseline_ready);
        append_le<uint8_t>(bytes, country.history_count);
        append_le<uint8_t>(bytes, country.history_head);
        append_le<int64_t>(bytes, country.baseline_population);
        append_le<int64_t>(bytes, country.baseline_buildings);
        append_le<int64_t>(bytes, country.lifetime_points_q16);
    append_le<int64_t>(bytes, country.trade_paid_day);
        append_le<int64_t>(bytes, country.ledger.population_q16);
        append_le<int64_t>(bytes, country.ledger.building_q16);
        append_le<int64_t>(bytes, country.ledger.trade_q16);
        append_le<int32_t>(bytes, country.ledger.opinion_factor_q16);
        append_le<int32_t>(bytes, country.ledger.gain_factor_q16);
        append_le<int64_t>(bytes, country.ledger.gain_q16);
        append_le<int64_t>(bytes, country.ledger.day);
        for (int64_t value : country.history_q16) append_le<int64_t>(bytes, value);
        append_vec(bytes, country.known_bits); append_vec(bytes, country.gate_bits);
        append_le<uint32_t>(bytes, country.offer.generation);
        append_le<uint8_t>(bytes, country.offer.active);
        append_le<uint8_t>(bytes, country.offer.choice_count);
        // Always the full capacity, never `choice_count` ints: a save written by
        // one build has to be readable by a build whose OFFER_CHOICE_CAPACITY
        // differs, and a variable-length row would silently shift every field
        // after it. The schema version covers changes to the capacity itself.
        for (int32_t ideology_id : country.offer.ideology_ids) append_le<int32_t>(bytes, ideology_id);
        append_vec(bytes, country.banned_bits);
        append_le<uint64_t>(bytes, static_cast<uint64_t>(country.ideas.size()));
        for (const IdeaState &state : country.ideas) {
            append_le<int32_t>(bytes, state.ideology_id); append_le<int64_t>(bytes, state.understanding_q16);
            append_le<int32_t>(bytes, state.level); append_le<uint64_t>(bytes, state.entered_levels);
            append_le<uint32_t>(bytes, state.generation);
            append_le<uint8_t>(bytes, state.location);
            append_le<uint8_t>(bytes, state.slot_index);
            append_le<int64_t>(bytes, state.binding_id);
            append_le<uint32_t>(bytes, state.binding_generation);
            append_le<uint64_t>(bytes, state.binding_signature);
            append_le<uint64_t>(bytes, state.binding_program_hash);
            append_le<uint8_t>(bytes, state.transition.active);
            append_le<int32_t>(bytes, state.transition.producer_id);
            append_le<int64_t>(bytes, state.transition.command_sequence);
            append_le<int32_t>(bytes, state.transition.command_opcode);
            append_le<int32_t>(bytes, state.transition.previous_level);
            append_le<uint64_t>(bytes, state.transition.previous_entered_levels);
            append_le<uint32_t>(bytes, state.transition.previous_generation);
            append_le<uint8_t>(bytes, state.transition.previous_location);
            append_le<uint8_t>(bytes, state.transition.previous_slot_index);
            append_le<uint64_t>(bytes, state.transition.entered_on_success);
            append_le<uint64_t>(bytes, static_cast<uint64_t>(state.transition.transaction_ids.size()));
            for (int64_t transaction_id : state.transition.transaction_ids) append_le<int64_t>(bytes, transaction_id);
            append_le<uint64_t>(bytes, static_cast<uint64_t>(
                state.transition.changed_synergy_ids.size()));
            for (size_t index = 0;
                    index < state.transition.changed_synergy_ids.size();
                    ++index) {
                append_le<int32_t>(bytes,
                    state.transition.changed_synergy_ids[index]);
                append_le<uint8_t>(bytes,
                    index < state.transition.previous_synergy_active.size()
                    ? state.transition.previous_synergy_active[index] : 0);
            }
            // Reconciled Effect instances owned by this idea. Persisted so a load
            // can prove the EffectRuntime still holds them; the ids are a pure
            // function of the owning identity, so a mismatch is real data loss
            // and must fail loudly instead of silently dropping the card's effect.
            append_le<uint64_t>(bytes,
                static_cast<uint64_t>(state.effect_instances.size()));
            for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
                append_le<uint64_t>(bytes, ref.program_hash);
                append_le<uint64_t>(bytes, ref.target_handle);
                append_le<uint32_t>(bytes, ref.target_generation);
                append_le<int64_t>(bytes, ref.instance_id);
                append_le<uint32_t>(bytes, ref.generation);
            }
        }
    }
    append_le<uint64_t>(bytes, static_cast<uint64_t>(pending_command_count()));
    for (size_t command_index = _command_cursor;
            command_index < _commands.size(); ++command_index) {
        const Command &command = _commands[command_index];
        append_le<int32_t>(bytes, command.opcode); append_le<int64_t>(bytes, command.effective_day);
        append_le<int32_t>(bytes, command.producer_id);
        append_le<int32_t>(bytes, command.source_priority); append_le<int64_t>(bytes, command.sequence);
        append_le<uint64_t>(bytes, command.country_handle); append_le<int32_t>(bytes, command.ideology_id);
        append_le<int64_t>(bytes, command.value_q16); append_le<uint32_t>(bytes, command.offer_generation);
        append_le<int32_t>(bytes, command.choice_index); append_le<int32_t>(bytes, command.gate_id);
        append_le<uint64_t>(bytes, command.submit_order);
    }
    // Plan §18.2: the FULL applied-program basis. One row per (country, program)
    // the derived projection folds: the program key, the effective target-selector
    // identity and a digest of the fold inputs.
    //
    // Re-derived HERE rather than read from `_applied_program_basis`: that member
    // records the last projection BUILT, which goes stale the moment a card is
    // equipped, unequipped or levelled before the next rebuild. A payload must
    // describe the state it was captured from, because that is the only thing a
    // reload can re-derive and check.
    //
    // The block is variable-length, so it carries its own total byte length as its
    // last field. That is what keeps the rest of the tail (the §18.5 scalar block
    // that follows, then the sample day / dates / contract / trailer) addressable
    // from the END of the payload with constants -- the layout fixture derives every
    // offset from the tail, and a block whose size could only be learnt by parsing it
    // from the front would be unaddressable.
    const size_t basis_block_begin = bytes.size();
    append_le<uint32_t>(bytes, static_cast<uint32_t>(basis.size()));
    for (const AppliedProgramBasis &row : basis) {
        append_le<uint64_t>(bytes, row.country_handle);
        append_string(bytes, row.program_key);
        append_le<int32_t>(bytes, row.selector_kind);
        append_string(bytes, row.selector_id);
        append_le<int32_t>(bytes, row.selector_param[0]);
        append_le<int32_t>(bytes, row.selector_param[1]);
        append_le<uint64_t>(bytes, row.terms_digest);
    }
    append_le<uint32_t>(bytes,
        static_cast<uint32_t>(bytes.size() - basis_block_begin));
    // ── plan §18.2 / §18.5: the LOCAL SCALAR BASIS ──────────────────────────
    //
    // One row per (country, slab metric id): the Q16 value the card programs read
    // through `READ_METRIC`. Written immediately after the applied-program basis and
    // closed by its own trailing u32 byte length, for the same reason that block is:
    // the tail (sample day / §9.3 dates / contract / trailer) has to stay addressable
    // from the END of the payload, and a block whose size could only be learnt by
    // parsing it from the front would make the tail unaddressable.
    const size_t scalar_block_begin = bytes.size();
    append_le<uint32_t>(bytes, static_cast<uint32_t>(scalars.size()));
    for (const LocalScalarValue &row : scalars) {
        append_le<uint64_t>(bytes, row.country_handle);
        append_le<int32_t>(bytes, row.metric_id);
        append_le<int64_t>(bytes, row.value_q16);
    }
    append_le<uint32_t>(bytes,
        static_cast<uint32_t>(bytes.size() - scalar_block_begin));
    // §18.5: the sample day the projection was built from.
    //
    // THE EPOCH ID IS DELIBERATELY NOT PERSISTED. `_derived_epoch_id` is structurally
    // 0: it is declared once (ideology_runtime.h), never assigned anywhere in the
    // codebase, and its only read is the `DerivedCellMaterializeJob` argument below --
    // so the `epoch_id` on every `DerivedCellFront` is 0 by construction. A field
    // persisting it would be 0 in every payload this build can ever write, i.e. a
    // value that cannot disagree with anything and therefore validates nothing.
    // `_derived_world_identity` and `_derived_map_generation` are in exactly the same
    // state. What actually identifies the projection's basis and CAN disagree is this
    // day plus the execution contract stamped below (which pins the rule versions and
    // the other catalogs). Extending the payload is the right move the day the epoch
    // becomes real -- and that day needs a schema bump anyway.
    append_le<int64_t>(bytes, _derived_basis_sample_day);
    // Plan §9.3 / p.719: the save must carry the basis dates so a load can tell
    // which projections are not eligible yet. Written after every variable-length
    // section (the two basis blocks above) and immediately before the contract, so
    // the layout is deterministic and the dates stay at a constant distance from the
    // END of the payload.
    append_le<int64_t>(bytes, _derived_basis_confirmed_day);
    append_le<int64_t>(bytes, _derived_basis_eligible_day);
    // Plan §11.5: the execution-contract identity, so an archive produced under other
    // execution rules is refused rather than reinterpreted.
    // Plan §11.5: computed AT CAPTURE TIME, not read from a configure-time stamp.
    //
    // A stamp fixed at configure depends on configure ORDER: `configure_ideologies` before
    // `configure_effects` records a contract whose Effect hash is still 0, so the world
    // could then never reload its own save. Computing here makes the contract describe the
    // configuration actually in force, which is what a save must record.
    append_le<uint64_t>(bytes, compute_execution_contract_hash());
    append_le<uint32_t>(bytes, SAVE_END);
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

Dictionary NativeIdeologyRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const uint8_t *data = packed.ptr(); const size_t size = packed.size(); size_t cursor = 0;
    uint32_t magic = 0, end = 0; int32_t schema = 0; uint64_t catalog_hash = 0, state_hash = 0;
    uint64_t submit_order = 0, country_count = 0, command_count = 0; int64_t last_day = -1;
    if (!read_le(data, size, cursor, magic) || !read_le(data, size, cursor, schema) ||
            !read_le(data, size, cursor, catalog_hash) || !read_le(data, size, cursor, last_day) ||
            !read_le(data, size, cursor, submit_order) || !read_le(data, size, cursor, state_hash) ||
            magic != SAVE_MAGIC) return fail("ideology_save_header_invalid");
    // PKID v4 (increment-only points, ledger, per-country slot capacity) is
    // fail-closed: earlier schemas are rejected instead of migrated.
    if (schema != SAVE_SCHEMA_VERSION) return fail("ideology_save_schema_unsupported");
    if (catalog_hash != _catalog_hash) return fail("ideology_save_catalog_mismatch");
    std::unordered_map<int32_t, int64_t> producer_high_watermarks;
    if (schema >= 3) {
        uint64_t high_watermark_count = 0;
        if (!read_le(data, size, cursor, high_watermark_count) ||
                high_watermark_count > 65536)
            return fail("ideology_save_producer_count_invalid");
        for (uint64_t i = 0; i < high_watermark_count; ++i) {
            int32_t producer_id = 0;
            int64_t sequence = -1;
            if (!read_le(data, size, cursor, producer_id) ||
                    !read_le(data, size, cursor, sequence) ||
                    producer_id <= 0 || sequence < 0 ||
                    !producer_high_watermarks.emplace(
                        producer_id, sequence).second)
                return fail("ideology_save_producer_invalid");
        }
    }
    uint64_t points_revision_seen = 0;
    uint8_t worker_origin = 0;
    if (!read_le(data, size, cursor, points_revision_seen) ||
            !read_le(data, size, cursor, worker_origin) || worker_origin > 1)
        return fail("ideology_save_points_header_invalid");
    if (!read_le(data, size, cursor, country_count) || country_count > 1000000) return fail("ideology_save_country_count_invalid");
    std::vector<CountryState> countries(static_cast<size_t>(country_count));
    for (CountryState &country : countries) {
        if (!read_le(data, size, cursor, country.handle) || !read_le(data, size, cursor, country.ideology_points_q16) ||
                !read_le(data, size, cursor, country.unlocked_era) ||
                !read_le(data, size, cursor, country.rng_state) || !read_le(data, size, cursor, country.draw_sequence) ||
                !read_le(data, size, cursor, country.free_draws) ||
                !read_le(data, size, cursor, country.points_revision) ||
                !read_le(data, size, cursor, country.baseline_ready) ||
                !read_le(data, size, cursor, country.history_count) ||
                !read_le(data, size, cursor, country.history_head) ||
                !read_le(data, size, cursor, country.baseline_population) ||
                !read_le(data, size, cursor, country.baseline_buildings) ||
                !read_le(data, size, cursor, country.lifetime_points_q16) ||
                !read_le(data, size, cursor, country.trade_paid_day) ||
                !read_le(data, size, cursor, country.ledger.population_q16) ||
                !read_le(data, size, cursor, country.ledger.building_q16) ||
                !read_le(data, size, cursor, country.ledger.trade_q16) ||
                !read_le(data, size, cursor, country.ledger.opinion_factor_q16) ||
                !read_le(data, size, cursor, country.ledger.gain_factor_q16) ||
                !read_le(data, size, cursor, country.ledger.gain_q16) ||
                !read_le(data, size, cursor, country.ledger.day))
            return fail("ideology_save_country_invalid");
        for (int64_t &value : country.history_q16)
            if (!read_le(data, size, cursor, value)) return fail("ideology_save_point_history_invalid");
        if (country.baseline_ready > 1 || country.history_count > POINT_HISTORY ||
                country.history_head >= POINT_HISTORY)
            return fail("ideology_save_point_history_invalid");
        if (!read_vec(data, size, cursor, country.known_bits, _idea_words) ||
                !read_vec(data, size, cursor, country.gate_bits, _gate_words) ||
                !read_le(data, size, cursor, country.offer.generation) || !read_le(data, size, cursor, country.offer.active) ||
                !read_le(data, size, cursor, country.offer.choice_count))
            return fail("ideology_save_country_invalid");
        // read_vec only enforces an upper bound. A short gate_bits vector would
        // make gate() read past the end, so the length has to match exactly.
        // banned_bits is validated where it is read, not here: it appears later
        // in the stream, so a size check at this point would compare against an
        // empty vector and reject every save.
        if (country.known_bits.size() != static_cast<size_t>(_idea_words) ||
                country.gate_bits.size() != static_cast<size_t>(_gate_words) ||
                country.unlocked_era < 0 || country.unlocked_era > MAX_ERA_INDEX ||
                country.offer.active > 1 ||
                country.offer.choice_count > OFFER_CHOICE_CAPACITY)
            return fail("ideology_save_country_invalid");
        for (int32_t &ideology_id : country.offer.ideology_ids)
            if (!read_le(data, size, cursor, ideology_id)) return fail("ideology_save_offer_invalid");
        // banned_bits follows the offer row, matching append order exactly. It is
        // NOT next to known_bits in the stream even though the two are siblings
        // conceptually -- the write site sits inside the offer block, and a
        // reader that assumes otherwise silently shifts every later field.
        if (!read_vec(data, size, cursor, country.banned_bits, _idea_words) ||
                country.banned_bits.size() != static_cast<size_t>(_idea_words))
            return fail("ideology_save_ban_invalid");
        uint64_t idea_count = 0;
        if (!read_le(data, size, cursor, idea_count) || idea_count > _definitions.size()) return fail("ideology_save_idea_count_invalid");
        for (uint64_t n = 0; n < idea_count; ++n) {
            IdeaState state; uint64_t transition_count = 0;
            if (!read_le(data, size, cursor, state.ideology_id) || !read_le(data, size, cursor, state.understanding_q16) ||
                    !read_le(data, size, cursor, state.level) || !read_le(data, size, cursor, state.entered_levels) ||
                    !read_le(data, size, cursor, state.generation) || !read_le(data, size, cursor, state.location) ||
                    (schema >= 9 && !read_le(data, size, cursor, state.slot_index)) ||
                    (schema >= 2 && (!read_le(data, size, cursor, state.binding_id) ||
                        !read_le(data, size, cursor, state.binding_generation) ||
                        !read_le(data, size, cursor, state.binding_signature) ||
                        !read_le(data, size, cursor, state.binding_program_hash))) ||
                    !read_le(data, size, cursor, state.transition.active) ||
                    (schema >= 3 && (!read_le(data, size, cursor,
                        state.transition.producer_id) ||
                        !read_le(data, size, cursor,
                            state.transition.command_sequence) ||
                        !read_le(data, size, cursor,
                            state.transition.command_opcode))) ||
                    !read_le(data, size, cursor, state.transition.previous_level) ||
                    !read_le(data, size, cursor, state.transition.previous_entered_levels) ||
                    !read_le(data, size, cursor, state.transition.previous_generation) ||
                    !read_le(data, size, cursor, state.transition.previous_location) ||
                    (schema >= 9 && !read_le(data, size, cursor,
                        state.transition.previous_slot_index)) ||
                    !read_le(data, size, cursor, state.transition.entered_on_success) ||
                    !read_le(data, size, cursor, transition_count) || transition_count > 4096 ||
                    state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size()) ||
                    state.location > NATIONAL_SPIRIT || state.transition.previous_location > NATIONAL_SPIRIT)
                return fail("ideology_save_idea_invalid");
            state.transition.transaction_ids.resize(static_cast<size_t>(transition_count));
            for (int64_t &transaction_id : state.transition.transaction_ids)
                if (!read_le(data, size, cursor, transaction_id) || transaction_id <= 0) return fail("ideology_save_transition_invalid");
            if (schema >= 3) {
                uint64_t changed_synergy_count = 0;
                if (!read_le(data, size, cursor, changed_synergy_count) ||
                        changed_synergy_count > _synergies.size())
                    return fail("ideology_save_synergy_transition_invalid");
                state.transition.changed_synergy_ids.resize(
                    static_cast<size_t>(changed_synergy_count));
                state.transition.previous_synergy_active.resize(
                    static_cast<size_t>(changed_synergy_count));
                for (size_t index = 0;
                        index < static_cast<size_t>(changed_synergy_count);
                        ++index) {
                    if (!read_le(data, size, cursor,
                            state.transition.changed_synergy_ids[index]) ||
                            !read_le(data, size, cursor,
                                state.transition.previous_synergy_active[index]) ||
                            state.transition.changed_synergy_ids[index] < 0 ||
                            state.transition.changed_synergy_ids[index] >=
                                static_cast<int32_t>(_synergies.size()) ||
                            state.transition.previous_synergy_active[index] > 1)
                        return fail(
                            "ideology_save_synergy_transition_invalid");
                }
            }
            if (state.transition.active == 0 && !state.transition.transaction_ids.empty()) return fail("ideology_save_transition_invalid");
            if (schema >= 6) {
                uint64_t effect_instance_count = 0;
                if (!read_le(data, size, cursor, effect_instance_count) ||
                        effect_instance_count > 4096)
                    return fail("ideology_save_effect_instance_count_invalid");
                state.effect_instances.resize(
                    static_cast<size_t>(effect_instance_count));
                for (size_t index = 0;
                        index < static_cast<size_t>(effect_instance_count);
                        ++index) {
                    IdeaState::EffectInstanceRef &ref =
                        state.effect_instances[index];
                    if (!read_le(data, size, cursor, ref.program_hash) ||
                            !read_le(data, size, cursor, ref.target_handle) ||
                            !read_le(data, size, cursor, ref.target_generation) ||
                            !read_le(data, size, cursor, ref.instance_id) ||
                            !read_le(data, size, cursor, ref.generation) ||
                            ref.instance_id <= 0 || ref.generation == 0 ||
                            ref.program_hash == 0)
                        return fail("ideology_save_effect_instance_invalid");
                }
            }
            country.idea_indices[state.ideology_id] = static_cast<int32_t>(country.ideas.size());
            country.ideas.push_back(std::move(state));
        }
        rebuild_country_derived(country);
    }
    if (!read_le(data, size, cursor, command_count) || command_count > 10000000) return fail("ideology_save_command_count_invalid");
    std::vector<Command> commands; commands.reserve(static_cast<size_t>(command_count));
    for (uint64_t n = 0; n < command_count; ++n) {
        Command command;
        if (!read_le(data, size, cursor, command.opcode) || !read_le(data, size, cursor, command.effective_day) ||
                (schema >= 3 && !read_le(data, size, cursor, command.producer_id)) ||
                !read_le(data, size, cursor, command.source_priority) || !read_le(data, size, cursor, command.sequence) ||
                !read_le(data, size, cursor, command.country_handle) || !read_le(data, size, cursor, command.ideology_id) ||
                !read_le(data, size, cursor, command.value_q16) || !read_le(data, size, cursor, command.offer_generation) ||
                !read_le(data, size, cursor, command.choice_index) || !read_le(data, size, cursor, command.gate_id) ||
                !read_le(data, size, cursor, command.submit_order)) return fail("ideology_save_command_invalid");
        std::string error; if (!validate_command_shape(command, error)) return fail(error);
        commands.push_back(command);
    }
    if (!std::is_sorted(commands.begin(), commands.end(), command_less))
        return fail("ideology_save_command_order_invalid");
    // ── plan §18.2: the applied-program basis ─────────────────────────────────
    //
    // Read BEFORE the dates, because that is where it is written: after the command
    // table, self-delimited by its own total byte length.
    std::vector<AppliedProgramBasis> restored_basis;
    {
        const size_t basis_block_begin = cursor;
        uint32_t basis_row_count = 0;
        if (!read_le(data, size, cursor, basis_row_count))
            return fail("ideology_save_truncated");
        // Two bounds: the global cap, and what the remaining bytes could possibly
        // hold (an empty row is 8+4+4+4+4+8 fixed bytes plus two empty strings, so
        // 32 bytes). The second one is what turns a lying count into a SHAPE error
        // instead of a slow truncation deep inside a row read.
        if (basis_row_count > APPLIED_BASIS_ROW_LIMIT ||
                static_cast<uint64_t>(basis_row_count) >
                    (size - cursor) / 32U)
            return fail("ideology_save_applied_basis_invalid");
        restored_basis.reserve(static_cast<size_t>(basis_row_count));
        for (uint32_t index = 0; index < basis_row_count; ++index) {
            AppliedProgramBasis row;
            if (!read_le(data, size, cursor, row.country_handle) ||
                    !read_string(data, size, cursor, row.program_key,
                        APPLIED_BASIS_KEY_LIMIT) ||
                    !read_le(data, size, cursor, row.selector_kind) ||
                    !read_string(data, size, cursor, row.selector_id,
                        APPLIED_BASIS_KEY_LIMIT) ||
                    !read_le(data, size, cursor, row.selector_param[0]) ||
                    !read_le(data, size, cursor, row.selector_param[1]) ||
                    !read_le(data, size, cursor, row.terms_digest))
                return fail("ideology_save_truncated");
            // Shape/pair validation, the same idea as the dates' pair rule above: a
            // row that cannot describe a real program is refused by name instead of
            // being carried into the state hash and a later comparison.
            if (row.country_handle == 0 || row.program_key.empty() ||
                    row.selector_kind < 0 || row.terms_digest == 0)
                return fail("ideology_save_applied_basis_invalid");
            // Strictly ascending (country, program): rejects duplicates and an
            // unsorted block, which is what makes the byte layout a function of the
            // state rather than of iteration order.
            if (!restored_basis.empty()) {
                const AppliedProgramBasis &previous = restored_basis.back();
                const bool ordered = previous.country_handle < row.country_handle ||
                    (previous.country_handle == row.country_handle &&
                     previous.program_key < row.program_key);
                if (!ordered)
                    return fail("ideology_save_applied_basis_invalid");
            }
            restored_basis.push_back(std::move(row));
        }
        // The block's declared length must agree with the bytes actually consumed.
        // Without this a length field could point anywhere and the "addressable from
        // the tail" property would rest on data that is never checked.
        //
        // `basis_rows_end` is taken BEFORE the length field itself is read: the field
        // is not part of the length it declares. Using `cursor` directly after the read
        // counted the field, and the writer/reader disagreed by exactly four bytes --
        // measured: every restore refused a payload this same code had just written.
        const size_t basis_rows_end = cursor;
        uint32_t basis_block_bytes = 0;
        if (!read_le(data, size, cursor, basis_block_bytes))
            return fail("ideology_save_truncated");
        if (basis_block_bytes !=
                static_cast<uint32_t>(basis_rows_end - basis_block_begin))
            return fail("ideology_save_applied_basis_invalid");
    }
    // ── plan §18.2 / §18.5: the LOCAL SCALAR BASIS ────────────────────────────────
    //
    // Read immediately after the applied basis and before the sample day, because
    // that is where it is written: after the command table, self-delimited by its own
    // trailing u32.
    std::vector<LocalScalarValue> restored_scalars;
    {
        const size_t scalar_block_begin = cursor;
        uint32_t scalar_row_count = 0;
        if (!read_le(data, size, cursor, scalar_row_count))
            return fail("ideology_save_truncated");
        // Two bounds again: the global cap, and what the remaining bytes could hold.
        // `LocalScalarValue` is 8 + 4 + 8 = 20 fixed bytes with no variable part, so a
        // count above `(size - cursor) / 20` is a SHAPE error rather than a slow
        // truncation deep inside a row read.
        if (scalar_row_count > LOCAL_SCALAR_ROW_LIMIT ||
                static_cast<uint64_t>(scalar_row_count) >
                    (size - cursor) / 20U)
            return fail("ideology_save_scalar_basis_invalid");
        restored_scalars.reserve(static_cast<size_t>(scalar_row_count));
        for (uint32_t index = 0; index < scalar_row_count; ++index) {
            LocalScalarValue row;
            if (!read_le(data, size, cursor, row.country_handle) ||
                    !read_le(data, size, cursor, row.metric_id) ||
                    !read_le(data, size, cursor, row.value_q16))
                return fail("ideology_save_truncated");
            // Shape: a row must name a country and a real slab slot. `-1` is the
            // builder's own "unresolved key" sentinel, so a payload carrying it cannot
            // have come from a catalog that resolves the scalar keys.
            if (row.country_handle == 0 || row.metric_id < 0)
                return fail("ideology_save_scalar_basis_invalid");
            // Strictly ascending (country, metric): rejects duplicates and an unsorted
            // block, exactly as the applied basis does.
            if (!restored_scalars.empty()) {
                const LocalScalarValue &previous = restored_scalars.back();
                const bool ordered = previous.country_handle < row.country_handle ||
                    (previous.country_handle == row.country_handle &&
                     previous.metric_id < row.metric_id);
                if (!ordered)
                    return fail("ideology_save_scalar_basis_invalid");
            }
            restored_scalars.push_back(row);
        }
        // Same honesty requirement as the block above: the declared length must agree
        // with the bytes actually consumed, and the end is taken BEFORE the length
        // field itself is read (the field is not part of the length it declares).
        const size_t scalar_rows_end = cursor;
        uint32_t scalar_block_bytes = 0;
        if (!read_le(data, size, cursor, scalar_block_bytes))
            return fail("ideology_save_truncated");
        if (scalar_block_bytes !=
                static_cast<uint32_t>(scalar_rows_end - scalar_block_begin))
            return fail("ideology_save_scalar_basis_invalid");
    }
    // §18.5: the sample day the projection was built from. `-1` = nothing projected.
    //
    // The EPOCH ID is deliberately absent from the payload (see the writer's comment):
    // `_derived_epoch_id` is structurally 0, so a field for it would validate nothing.
    // The sample day is the half of the identity that carries information; the
    // execution contract read below pins the rules it was built under.
    int64_t restored_sample_day = -1;
    if (!read_le(data, size, cursor, restored_sample_day))
        return fail("ideology_save_truncated");
    // Shape only. There is deliberately NO pair rule tying the sample day to
    // `_last_day` or to the two §9.3 dates below:
    //   * `drain_derived_cell_layer` drives `step_derived_rebuild(day)` directly, so a
    //     projection can be built for a day the day-completion marker has not reached;
    //   * a transition may CONFIRM on a later day than the build it confirmed, so
    //     `confirmed_day > sample_day` is legal.
    // Both rules would therefore refuse payloads this same code writes, and a check
    // that fires on legal data is worse than none. What is left is the domain: below
    // -1 is neither a real day nor the "no projection" sentinel.
    if (restored_sample_day < -1)
        return fail("ideology_save_scalar_basis_invalid");
    int64_t restored_basis_confirmed_day = -1;
    int64_t restored_basis_eligible_day = -1;
    if (!read_le(data, size, cursor, restored_basis_confirmed_day) ||
        !read_le(data, size, cursor, restored_basis_eligible_day))
        return fail("ideology_save_truncated");
    // Plan §11.5: the execution-contract identity. Explicit refusal, per the plan:
    // "旧档默认明确拒读 cell_program_execution_contract_mismatch, 而不是删掉旧实例继续读."
    uint64_t restored_contract = 0;
    if (!read_le(data, size, cursor, restored_contract))
        return fail("ideology_save_truncated");
    // Compare against THIS runtime's own stamp, not a live recomputation.
    //
    // That asymmetry was a real defect (found while fixing a fixture): `configure`
    // stamps `_execution_contract_hash` on its last line from the catalogs attached AT
    // THAT MOMENT, so a world configured Effect-AFTER-Ideology carries a stamp computed
    // with an effect hash of 0. Comparing the payload against a LIVE recomputation then
    // meant such a world could restore a foreign, correctly-stamped payload yet could
    // never reload its OWN save -- the worst of both directions.
    //
    // Comparing stamp against stamp makes the rule symmetric and states it plainly:
    // a payload is accepted iff the runtime that produced it agreed on the contract. A
    // runtime that reconfigured gets a new stamp, so it refuses payloads from the old
    // one, which is what §11.5 wants ("跨不同覆盖配置加载时必须拒读").
    if (restored_contract != compute_execution_contract_hash())
        return fail("cell_program_execution_contract_mismatch");
    // Reject a nonsensical pair rather than trusting it: the gate treats
    // `eligible < 0` as "no basis yet", so a payload claiming confirmed=9999 /
    // eligible=0 would silently disable it.
    if ((restored_basis_confirmed_day < 0) != (restored_basis_eligible_day < 0) ||
        (restored_basis_eligible_day >= 0 &&
         restored_basis_eligible_day != restored_basis_confirmed_day + 1))
        return fail("ideology_save_basis_dates_invalid");
    if (!read_le(data, size, cursor, end) || end != SAVE_END || cursor != size) return fail("ideology_save_truncated");
    // ── plan §18.2: can the payload's basis be rebuilt from the CURRENT catalogs? ──
    //
    // This is the check the two basis dates cannot make: they say WHEN a projection may
    // be adopted, not WHAT it was built from. The concrete hole it closes -- measured,
    // see `ideology_save_payload_robustness_test` -- is the card-level -> program
    // mapping: `compute_catalog_hash` does not cover `Definition::level_begin`,
    // `Level::persistent_*` or `EffectTemplate::definition_key`, and the execution
    // contract covers only the version vector plus the OTHER two catalogs' hashes. So
    // two builds that disagree about which program a card level carries agree on every
    // other persisted identity, and without this check the reload would silently project
    // a DIFFERENT card from the same rows.
    //
    // Runs against the payload's own country rows, before anything is installed, using
    // the pure rebuild helper: a refusal here leaves the runtime untouched, so it needs
    // no rollback of its own.
    {
        std::vector<AppliedProgramBasis> rebuilt_basis;
        rebuild_applied_program_basis(countries, rebuilt_basis);
        if (rebuilt_basis != restored_basis)
            return fail("ideology_save_applied_basis_mismatch");
    }
    // ── plan §18.5: can the payload's SCALAR values be rebuilt from the CURRENT
    // catalogs and state? ─────────────────────────────────────────────────────────
    //
    // The applied basis above pins which PROGRAMS the projection folds; this pins the
    // NUMBERS their programs read. Two identities that agree on every program can
    // still disagree on `equipped_count` or `unlocked_era`, and a reload that silently
    // re-derives a different value reports "restored" while projecting something else.
    //
    // The comparison is a pure function of (payload country rows, current Effect
    // catalog, this runtime's Country domain), run before anything is installed, so a
    // refusal here needs no rollback: `_local_scalar_basis` still holds the previous
    // record and the country table was never moved.
    //
    // The ONE exception is a row whose input this runtime cannot answer -- the
    // `unlocked_era` term needs the Country domain, which a test or a partially-loaded
    // world may not have ready. Those rows are excluded from the comparison (named, not
    // silently zeroed); every other row is still compared strictly, presence included.
    {
        std::vector<LocalScalarValue> rebuilt_scalars;
        std::vector<LocalScalarValue> cross_domain_rows;
        rebuild_local_scalar_basis(countries, rebuilt_scalars, &cross_domain_rows);
        if (!local_scalar_basis_agrees(restored_scalars, rebuilt_scalars,
                cross_domain_rows)) {
            _last_scalar_basis_mismatch_detail = describe_local_scalar_mismatch(
                restored_scalars, rebuilt_scalars, cross_domain_rows);
            return fail("ideology_save_scalar_basis_mismatch");
        }
        _last_scalar_basis_mismatch_detail.clear();
    }
    auto previous_countries = std::move(_countries);
    auto previous_commands = std::move(_commands);
    auto previous_producer_high_watermarks =
        std::move(_producer_high_watermarks);
    const size_t previous_command_cursor = _command_cursor;
    auto previous_pending_transitions = std::move(_pending_transitions);
    const size_t previous_pending_transition_cursor = _pending_transition_cursor;
    const int64_t previous_active_progress_day = _active_progress_day;
    const int32_t previous_active_country_cursor = _active_country_cursor;
    const int32_t previous_active_item_cursor = _active_item_cursor;
    const int64_t previous_last_day = _last_day;
    const uint64_t previous_submit_order = _submit_order;
    const uint64_t previous_points_revision_seen = _points_revision_seen;
    const bool previous_worker_origin = _worker_origin;
    _countries = std::move(countries); _commands = std::move(commands);
    _producer_high_watermarks = std::move(producer_high_watermarks);
    _points_revision_seen = points_revision_seen;
    _worker_origin = worker_origin != 0;
    if (schema < 3) {
        for (const Command &command : _commands) {
            auto &high_watermark =
                _producer_high_watermarks[command.producer_id];
            high_watermark = std::max(high_watermark, command.sequence);
        }
    }
    _command_cursor = 0;
    _active_progress_day = -1;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _last_day = last_day;
    _submit_order = submit_order;
    const int64_t previous_basis_confirmed_day = _derived_basis_confirmed_day;
    const int64_t previous_basis_eligible_day = _derived_basis_eligible_day;
    _derived_basis_confirmed_day = restored_basis_confirmed_day;
    _derived_basis_eligible_day = restored_basis_eligible_day;
    // Plan §18.2 commit point: the basis the payload described is now the basis this
    // runtime reports. Same treatment as the two dates above -- assigned at the commit
    // point and put back by `rollback`, so a later failure in this restore cannot leave
    // a basis that describes state which was itself rolled back.
    const std::vector<AppliedProgramBasis> previous_applied_basis =
        _applied_program_basis;
    _applied_program_basis = restored_basis;
    // §18.5 commit point: the scalar record and the projection's sample day. Both are
    // MEMBERS, so a failure AFTER this line (the state hash below, a missing Effect
    // instance, a missing binding) has to put them back; otherwise a refused restore
    // would leave this runtime reporting another world's scalar values -- exactly the
    // class of bug the applied-basis member was introduced to make impossible.
    const std::vector<LocalScalarValue> previous_local_scalar_basis =
        _local_scalar_basis;
    _local_scalar_basis = restored_scalars;
    const int64_t previous_basis_sample_day = _derived_basis_sample_day;
    _derived_basis_sample_day = restored_sample_day;
    rebuild_pending_transition_index();
    auto rollback = [&]() {
        _countries = std::move(previous_countries);
        _commands = std::move(previous_commands);
        _producer_high_watermarks =
            std::move(previous_producer_high_watermarks);
        _command_cursor = previous_command_cursor;
        _pending_transitions = std::move(previous_pending_transitions);
        _pending_transition_cursor = previous_pending_transition_cursor;
        _active_progress_day = previous_active_progress_day;
        _active_country_cursor = previous_active_country_cursor;
        _active_item_cursor = previous_active_item_cursor;
        _last_day = previous_last_day;
        _submit_order = previous_submit_order;
        _points_revision_seen = previous_points_revision_seen;
        _worker_origin = previous_worker_origin;
        _derived_basis_confirmed_day = previous_basis_confirmed_day;
        _derived_basis_eligible_day = previous_basis_eligible_day;
        _applied_program_basis = previous_applied_basis;
        _local_scalar_basis = previous_local_scalar_basis;
        _derived_basis_sample_day = previous_basis_sample_day;
    };
    // The hash is taken over the rows that were just verified, not over a fresh
    // derivation: `rebuilt_basis == restored_basis` was proved above, so this is the same
    // number and it resolves every program only once. Same for the scalar rows, whose
    // equality was proved by the §18.5 check above.
    if (compute_state_hash_with(restored_basis, restored_scalars,
            restored_sample_day) != state_hash) {
        rollback();
        return fail("ideology_save_state_hash_mismatch");
    }
    // A card whose effect lives on a reconciled instance is only half-restored by
    // PKID. If the Effect domain lost that instance the card would silently stop
    // producing anything, so prove ownership here instead. PKEF restores first
    // (game_save_coordinator), which makes this an ordering assertion as well.
    //
    // The check has to ask whichever side owns EFFECT: under worker authority
    // EffectRuntime is writeback-only, so the old unconditional query failed every
    // worker-owned instance and rejected a perfectly good save with
    // ideology_effect_instance_missing. "Cannot answer" is deliberately NOT a
    // failure -- a transport that is not ready yet must not fail a restore.
    if (_effect_runtime != nullptr || _effect_forwarder != nullptr) {
        for (const CountryState &country : _countries) {
            for (const IdeaState &state : country.ideas) {
                for (const IdeaState::EffectInstanceRef &ref :
                        state.effect_instances) {
                    bool ref_exists = false;
                    if (!effect_pod_instance_exists(_effect_runtime,
                            _effect_forwarder, ref.instance_id, ref.generation,
                            ref_exists))
                        continue;
                    if (!ref_exists) {
                        rollback();
                        return fail("ideology_effect_instance_missing");
                    }
                }
            }
        }
    }
    if (_worker_origin) {
        // Worker-authored state binds through Modifier UniqueSource rows that
        // PKCM restores and IDP2 audits; it never owned PKEF bindings.
        Dictionary out; out["ok"] = true; out["state_hash"] = static_cast<int64_t>(state_hash);
        out["worker_origin"] = true;
        return out;
    }
    if (_effect_runtime == nullptr) { rollback(); return fail("ideology_effect_runtime_unavailable"); }
    for (const CountryState &country : _countries) {
        std::vector<int64_t> expected_transaction_ids;
        std::vector<uint64_t> expected_source_ids;
        for (const IdeaState &state : country.ideas) {
            if (schema < 2 && (state.location != INACTIVE ||
                    state.transition.active != 0)) {
                rollback();
                return fail("ideology_legacy_active_state_unsupported");
            }
            if (state.location != INACTIVE) {
                const int64_t expected_binding_id = static_cast<int64_t>(
                    binding_id_for(country.handle, state.ideology_id,
                        state.location));
                const uint64_t expected_signature = binding_signature_for(
                    state.ideology_id, state.level);
                const uint64_t expected_program_hash =
                    _effect_runtime->catalog_hash();
                if (state.binding_id != expected_binding_id ||
                    state.binding_generation == 0 ||
                    state.binding_signature != expected_signature ||
                    state.binding_program_hash != expected_program_hash ||
                    !_effect_runtime->has_external_binding_pod(state.binding_id,
                        state.binding_generation, 0x4944454f, state.ideology_id,
                        country.handle, static_cast<uint32_t>(country.handle >> 32U),
                        state.level, state.location, state.binding_signature,
                        state.binding_program_hash)) {
                    rollback();
                    return fail("ideology_effect_binding_missing_or_mismatched");
                }
            }
            if (state.transition.active == 0) continue;
            const uint64_t source_prefix =
                static_cast<uint64_t>(state.ideology_id + 1) << 32U;
            for (const int64_t transaction_id : state.transition.transaction_ids) {
                expected_transaction_ids.push_back(transaction_id);
                expected_source_ids.push_back(source_prefix);
            }
        }
        std::string transaction_error;
        if (!_effect_runtime->verify_external_pending_transactions_pod(
                0x4944454f, country.handle, 0xffffffff00000000ULL,
                expected_transaction_ids, expected_source_ids,
                transaction_error)) {
            rollback();
            return fail(transaction_error.empty()
                ? "ideology_effect_transition_unknown" : transaction_error);
        }
    }
    // Converge the instance set after a load. The verification above proves the
    // saved set still exists; this makes a save that predates a program (or one
    // written by a path that never reconciled) self-heal instead of leaving the
    // card silently inert. Idempotent: a matching set produces no submits.
    for (CountryState &country : _countries)
        reconcile_country_effect_activations(country, std::max<int64_t>(0, _last_day));
    // The restore pass above already revisited every card and stamped its
    // signature, so the first refresh must not repeat it.
    _effect_input_revision_seen = _economy_runtime == nullptr
        ? 0 : _economy_runtime->effect_input_revision();
    _effect_input_revision_target = _effect_input_revision_seen;
    _instance_refresh_pending = false;
    _instance_refresh_dirty = false;
    _instance_refresh_country_cursor = 0;
    recount_managed_active();
    Dictionary out; out["ok"] = true; out["state_hash"] = static_cast<int64_t>(state_hash); return out;
}

uint64_t NativeIdeologyRuntime::binding_id_for(uint64_t country_handle,
        int32_t ideology_id, uint8_t location) const {
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, country_handle);
    hash = mixv(hash, ideology_id);
    hash = mixv(hash, location);
    hash = mixv(hash, uint64_t{0x4944454f42494e44ULL}); // IDEOBIND
    return hash & 0x7fffffffffffffffULL;
}

uint64_t NativeIdeologyRuntime::binding_signature_for(int32_t ideology_id,
        int32_t level) const {
    if (ideology_id < 0 || ideology_id >= static_cast<int32_t>(_definitions.size())) return 0;
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, ideology_id);
    hash = mixv(hash, level);
    const Definition &definition = _definitions[static_cast<size_t>(ideology_id)];
    if (level < 0 || level >= definition.level_count) return hash;
    const Level &row = _levels[static_cast<size_t>(definition.level_begin + level)];
    for (int32_t i = 0; i < row.persistent_count; ++i) {
        const EffectTemplate &templ = _persistent_templates[
            static_cast<size_t>(row.persistent_begin + i)];
        hash = mixv(hash, templ.action); hash = mixv(hash, templ.domain);
        hash = mixv(hash, templ.opcode); hash = mixv(hash, templ.value_q16);
        hash = mixv(hash, templ.duration_days); hash = mixv(hash, templ.stacks);
        hash = mix(hash, templ.command_key.data(), templ.command_key.size());
        hash = mix(hash, templ.definition_key.data(), templ.definition_key.size());
        for (int64_t value : templ.payload) hash = mixv(hash, value);
    }
    return hash;
}

bool NativeIdeologyRuntime::sync_external_binding(uint64_t country_handle,
        IdeaState &state, std::string &error) {
    if (_effect_runtime == nullptr) { error = "ideology_effect_runtime_unavailable"; return false; }
    if (state.location == INACTIVE) return true;
    const uint64_t signature = binding_signature_for(state.ideology_id, state.level);
    const int64_t binding_id = static_cast<int64_t>(binding_id_for(country_handle,
        state.ideology_id, state.location));
    if (!_effect_runtime->upsert_external_binding_pod(binding_id, state.generation,
            0x4944454f, state.ideology_id, country_handle,
            static_cast<uint32_t>(country_handle >> 32U), state.level,
            state.location, signature, _effect_runtime->catalog_hash(), error))
        return false;
    state.binding_id = binding_id;
    state.binding_generation = state.generation;
    state.binding_signature = signature;
    state.binding_program_hash = _effect_runtime->catalog_hash();
    return true;
}
const std::string *NativeIdeologyRuntime::intern_program_key(
        const std::string &key) const {
    const auto found = _program_key_pool.find(key);
    if (found != _program_key_pool.end()) return &*found;
    return &*_program_key_pool.insert(key).first;
}

void NativeIdeologyRuntime::ensure_derived_program_sampler() {
    if (_derived_program_sampler) return;
    _derived_program_metric_scratch.assign(
        static_cast<size_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT), 0);
    _derived_program_sampler = [this](const std::string &program_key, int32_t cell,
                                      uint64_t source_country) -> double {
        (void)source_country;   // the program reads cell metrics; scope is the cell
        if (_economy_runtime == nullptr || _effect_runtime == nullptr) return 0.0;
        // Every declared metric, not a narrowed mask: the program's own READ_METRIC
        // decides what it needs, and a mask here would be a second, drifting copy of
        // that knowledge.
        const int32_t count =
            static_cast<int32_t>(_derived_program_metric_scratch.size());
        const pk::MetricMask all = pk::MetricMask::all_declared(count);
        _economy_runtime->sample_effect_metrics(cell, count,
            _derived_program_metric_scratch.data(), all);
        int64_t magnitude = 0;
        std::string error;
        if (!_effect_runtime->evaluate_program_magnitude_for_metrics(
                program_key, _derived_program_metric_scratch.data(), count,
                magnitude, error)) {
            // Counted, never silently zeroed: a muted effect and an effect evaluated to
            // zero look identical in the output, and only the counter separates them.
            ++_derived_program_failures;
            return 0.0;
        }
        ++_derived_program_evaluations;
        return static_cast<double>(magnitude) / static_cast<double>(Q16_ONE);
    };
}

void NativeIdeologyRuntime::ensure_derived_ramp_sampler() {
    if (!_derived_ramp_sampler) {
        _derived_ramp_metric_scratch.resize(
            static_cast<size_t>(NativeEconomyRuntime::FAMILY_METRIC_COUNT), 0);
        // Captures MEMBERS, not locals: the job outlives this call.
        _derived_ramp_sampler = [this](int32_t metric_id, int32_t cell,
                                       uint64_t source_country) -> double {
            const bool country_scope =
                (metric_id >= 56 && metric_id <= 61) ||
                (metric_id >= 63 && metric_id <= 69) || metric_id == 91;
            if (country_scope) {
                static_assert(NativeEconomyRuntime::FAMILY_METRIC_COUNT <= 256,
                    "ramp country-metric cache key packs metric_id into 8 bits");
                const uint64_t key = (source_country << 8U) ^
                    static_cast<uint64_t>(metric_id);
                const auto found = _derived_ramp_country_cache.find(key);
                if (found != _derived_ramp_country_cache.end()) {
                    ++_derived_ramp_samples_memoised;
                    return found->second;
                }
            }
            _economy_runtime->sample_effect_metrics(
                cell, static_cast<int32_t>(_derived_ramp_metric_scratch.size()),
                _derived_ramp_metric_scratch.data());
            ++_derived_ramp_samples_taken;
            const double sample = metric_id >= 0 &&
                    metric_id < static_cast<int32_t>(_derived_ramp_metric_scratch.size())
                ? static_cast<double>(
                      _derived_ramp_metric_scratch[static_cast<size_t>(metric_id)])
                : 0.0;
            if (country_scope) {
                const uint64_t key = (source_country << 8U) ^
                    static_cast<uint64_t>(metric_id);
                _derived_ramp_country_cache[key] = sample;
            }
            return sample;
        };
    }
}

bool NativeIdeologyRuntime::step_derived_rebuild(int64_t day,
                                               std::string &error) {
    error.clear();
    if (!_configured || _modifier_runtime == nullptr || _effect_runtime == nullptr)
        return true;
    // Counted HERE, not in the deleted `rebuild_derived_cell_layer`.
    //
    // When the old one-shot rebuild was removed its `++_cell_layer_rebuild_visits`
    // went with it while the export stayed, so the counter was permanently 0 and
    // `ideology_cell_layer_e2e_test` failed on a truthful-looking message
    // ("0 means run_daily never reached the hook") that was actually my oversight.
    ++_cell_layer_rebuild_visits;

    if (day != _derived_rebuild_day) {
        // A new day invalidates any half-built job: the epoch's inputs differ, so
        // splicing two days together would be wrong.
        _derived_rebuild_day = day;
        _derived_rebuild_slices = 0;
        _derived_rebuild_total_ms = 0.0;
        _cell_layer_rebuild_ms = 0.0;
        _derived_materialise_ms = 0.0;
        // Reset with the two above, not left to accumulate. `_derived_collect_ms` is a
        // MAX, so an un-reset member reports the worst collect of the WHOLE RUN while
        // `cell_layer_rebuild_ms` / `cell_layer_materialise_ms` describe the LAST day --
        // three numbers that cannot be compared with each other (measured: an un-reset
        // collect read 1.377 ms at 6400 against a per-day 0.69 ms, and the difference
        // looked like a regression that was not there).
        _derived_collect_ms = 0.0;
        _derived_rebuild_contributions.clear();
    _collect_pod_fail_keys.clear();
    _collect_pod_ok_keys.clear();
        _derived_rebuild_collected = false;
        _derived_rebuild_job.reset();
    }

    // ── plan §9.3: do not adopt a projection before its eligibility day ────
    //
    // Placed AFTER the day-reset above, deliberately. An earlier version sat before it,
    // so a refused rebuild left `_derived_rebuild_day` pointing at the confirmation day;
    // `derived_rebuild_pending()` then stayed true and `drain_derived_cell_layer` burned
    // its whole 4096-step budget and reported `complete=false` (measured). Clearing the
    // job first makes "refused" indistinguishable from "nothing to do", which is what a
    // caller should see.
    if (_derived_basis_eligible_day >= 0 && day < _derived_basis_eligible_day) {
        ++_derived_rebuild_gated_by_eligibility;
        // Clear the day marker as well. `derived_rebuild_pending()` is
        // `_derived_rebuild_day >= 0`, and the reset block above has just set it to
        // `day`, so leaving it set made a REFUSED rebuild look like an in-flight one:
        // `drain_derived_cell_layer` then looped its entire 4096-step budget and
        // reported `complete=false` (measured in B12's continuous branch). Clearing it
        // is what makes "refused" indistinguishable from "nothing to do", which is what
        // a caller should see.
        _derived_rebuild_day = -1;
        return true;
    }

    const Clock::time_point started = Clock::now();

    if (!_derived_rebuild_collected) {
        // Collect only after the day's own active progress finished. Collecting
        // earlier reads a half-advanced world: `run_daily_slices` walks
        // `_active_country_cursor` across slices, so a second country's card may not
        // be ACTIVE yet. That is exactly what produced `collect_count = 3200`
        // against 6400 in M4-18.
        if (_active_progress_day == day) return false;
        _derived_rebuild_contributions.clear();
        for (const CountryState &country : _countries) {
            if (country.handle == 0) continue;
            for (const IdeaState &state : country.ideas) {
                if (state.location == INACTIVE || state.level < 0) continue;
                std::vector<EffectActivation> throwaway;
                collect_effect_activations(country, state, throwaway,
                    &_derived_rebuild_contributions);
            }
        }
        _derived_rebuild_collected = true;
        // Plan §18.2: record the basis this projection is being built from. Done HERE,
        // at the collect step, because the collect loop above already resolved exactly
        // these programs -- and because collection honours a pending transition's OLD
        // level (§10.1), so the rows describe the basis in force, not the one that is
        // still waiting for its ACK. Diagnostics only: a capture re-derives its own rows.
        rebuild_applied_program_basis(_countries, _applied_program_basis);
        // Collection is a STEP of its own. At 6400 cells it costs 0.68 ms, and folding
        // in the same call pushed the first step to 1.03 ms -- over the 1 ms gate even
        // though the fold itself was budgeted. Returning here keeps each step's work
        // bounded by ONE kind of cost.
        // The collect's own cost, and ONLY its own. This assignment is what makes
        // `cell_layer_collect_ms` a measurement instead of a constant: the field was
        // declared and exported but never written, so the report said 0.0 on every run
        // and the perf table quoted that zero as if it were data (found 2026-10-29).
        _derived_collect_ms = std::max(_derived_collect_ms, elapsed_ms(started));
        _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms,
                                          elapsed_ms(started));
        // `_derived_materialise_ms` is deliberately NOT set here. It used to be assigned
        // the same collect duration, which made a "materialise" number that contained no
        // materialisation; it is the fold's cost and is set in the fold branch only.
        _derived_rebuild_steps = ++_derived_rebuild_slices;
        // Ramp terms must be EVALUATED, not deferred. Passing an empty options struct
        // here silently turned every ramp program into "no contribution" on the
        // sharded path while the single-shot path still evaluated them.
        DerivedMaterializeOptions job_options;
        _derived_ramp_country_cache.clear();
        _derived_ramp_samples_taken = 0;
        _derived_ramp_samples_memoised = 0;
        if (_economy_runtime != nullptr) {
            ensure_derived_ramp_sampler();
            job_options.ramp_sampler = &_derived_ramp_sampler;
            // Preferred over the metric sampler for every ramp term that names a
            // program (which is all of them, since the collector fills `program_key`).
            if (_effect_runtime != nullptr) {
                ensure_derived_program_sampler();
                job_options.program_magnitude_sampler = &_derived_program_sampler;
            }
        }
        _derived_rebuild_job.reset(new DerivedCellMaterializeJob(
            _derived_world_identity, _derived_map_generation, day,
            _derived_epoch_id, compute_execution_contract_hash(), job_options));
        return false;   // fold happens in later steps
    }

    ++_derived_rebuild_slices;
    if (_derived_rebuild_job == nullptr) return true;
    const bool folded = _derived_rebuild_job->fold_step(
        _derived_rebuild_contributions, DERIVED_REBUILD_STEP_BUDGET_MS);
    const double step_ms = elapsed_ms(started);
    _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, step_ms);
    _derived_materialise_ms = std::max(_derived_materialise_ms, step_ms);
    _derived_rebuild_steps = _derived_rebuild_slices;
    _derived_rebuild_total_ms += step_ms;

    if (!folded) return false;   // more steps needed; nothing installed yet

    DerivedCellFront front;
    DerivedMaterializeReport report;
    bool skipped = false;
    const DerivedCellFront *previous = _modifier_runtime->derived_cell_front();
    if (!_derived_rebuild_job->finish(previous, front, report, skipped)) {
        error = "derived_cell_layer_finish_failed";
        return true;
    }
    _last_derived_materialize = report;
    // PEAK MEMORY (§18.3): the only point where the RETAINED front (still serving
    // readers) and the CANDIDATE front (just built, not yet installed) both exist.
    // `previous` is null on the very first build -- a real case, reported as retained 0.
    {
        const int64_t retained_bytes =
            previous != nullptr ? pk::derived_cell_front_bytes(*previous) : 0;
        const int64_t candidate_bytes = pk::derived_cell_front_bytes(front);
        _derived_peak_retained_bytes =
            std::max(_derived_peak_retained_bytes, retained_bytes);
        _derived_peak_candidate_bytes =
            std::max(_derived_peak_candidate_bytes, candidate_bytes);
        _derived_peak_total_bytes = std::max(
            _derived_peak_total_bytes, retained_bytes + candidate_bytes);
    }
    // Export the JOB's ramp counters.
    //
    // These were only ever assigned on the (now dead) single-shot path, so a fixture
    // reading `ramp_terms_evaluated` saw a stale 0 no matter what the job did -- which
    // made "the ramp path works" unprovable and "the ramp path is broken" equally
    // unfalsifiable.
    _ramp_terms_evaluated = report.ramp_terms_evaluated;
    _ramp_terms_deferred = report.ramp_terms_deferred;
    if (!skipped) {
        bool install_skipped = false;
        _modifier_runtime->install_derived_cell_layer(
            std::move(front), 0, install_skipped, error);
        // §18.5: the sample day of the projection that is now serving readers. Read
        // back from the INSTALLED front rather than from the job argument, because
        // those are not the same thing: an idempotent install is skipped (§I13), an
        // install can be refused (`derived_cell_layer_identity_mismatch`), and a build
        // in flight is not a projection yet. Reading it back makes this member equal to
        // `derived_cell_front()->sample_day` by construction instead of by assumption.
        const DerivedCellFront *serving = _modifier_runtime->derived_cell_front();
        _derived_basis_sample_day = serving != nullptr ? serving->sample_day : -1;
    }
    // ── the step does not END until the front is built and installed ────────────
    //
    // `step_ms` above is taken BEFORE `finish()` and `install_derived_cell_layer()`, so
    // `cell_layer_rebuild_ms` used to publish a number that excluded the most expensive
    // part of the tail: measured at 12800 rows, the front build alone was 0.93 ms, so a
    // slice that really took 1.32 ms reported itself as 0.69 ms. That is a green number
    // quoting a subset of the work (found 2026-10-29 against the 5-run per-call trace).
    //
    // The max now covers the WHOLE step. `_derived_materialise_ms` stays fold-only, so
    // the two reported numbers still answer different questions: "what did the fold
    // cost" versus "what did one slice of this stage cost".
    {
        const double whole_step_ms = elapsed_ms(started);
        _cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, whole_step_ms);
        // The tail (build + install + release) is part of the same day's total. The
        // fold's part was already added above, so only the delta is added here.
        _derived_rebuild_total_ms += whole_step_ms - step_ms;
    }
    _derived_rebuild_day = -1;
    _derived_rebuild_collected = false;
    _derived_rebuild_job.reset();
    return true;
}


Dictionary NativeIdeologyRuntime::clear_state(){if(!_configured)return fail("ideology_runtime_unconfigured");reset_runtime_state();_worker_import_pending=false;Dictionary o;o["ok"]=true;return o;}
} // namespace pk
