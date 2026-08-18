#include "ideology_runtime.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "effect_runtime.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_set>

namespace pk {
using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x44494b50U; // PKID
constexpr uint32_t SAVE_END = 0x21444e45U;
constexpr int32_t MAX_IDEOLOGIES = 65536;
constexpr int32_t MAX_LEVELS = 1000000;
constexpr int32_t MAX_GATES = 65536;
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
uint64_t splitmix64(uint64_t &state) { uint64_t z = (state += 0x9e3779b97f4a7c15ULL); z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL; z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL; return z ^ (z >> 31U); }
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
    for (int32_t i=0;i<enter_count;++i) if(!validate_template(i,false)) { error="ideology_on_enter_template_invalid"; return false; }
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
    _definitions.clear(); _levels.clear(); _persistent_templates.clear(); _on_enter_templates.clear(); _synergy_templates.clear(); _class_stances.clear(); _synergy_requirements.clear(); _synergies.clear(); _technology_requirements.clear(); _signal_requirements.clear(); _gate_requirements.clear();
    _definitions.reserve(count); _levels.reserve(thresholds.size());
    for (int32_t i=0;i<count;++i) {
        Definition d; d.stable_id=String(ids[i]).utf8().get_data(); d.acquisition=acquisition[i]; d.rarity_weight=weights[i]; d.ideology_cost=ideology_costs[i]; d.spirit_cost=spirit_costs[i]; d.min_spirit_level=spirit_levels[i]; d.level_begin=level_offsets[i]; d.level_count=level_offsets[i+1]-level_offsets[i]; d.technology_requirement_begin=tech_offsets[i]; d.technology_requirement_count=tech_offsets[i+1]-tech_offsets[i]; d.signal_requirement_begin=signal_offsets[i]; d.signal_requirement_count=signal_offsets[i+1]-signal_offsets[i]; d.gate_requirement_begin=gate_offsets[i]; d.gate_requirement_count=gate_offsets[i+1]-gate_offsets[i]; d.stance_begin=stance_offsets[i]; d.stance_count=stance_offsets[i+1]-stance_offsets[i]; d.support_threshold_q16={adopt_thresholds[i],repeal_thresholds[i],promote_thresholds[i]}; d.exclusion_group_id=exclusion_groups[i]; _definitions.push_back(std::move(d)); }
    for (int32_t i=0;i<thresholds.size();++i) _levels.push_back({thresholds[i],daily[i],persistent_offsets[i],persistent_offsets[i+1]-persistent_offsets[i],enter_offsets[i],enter_offsets[i+1]-enter_offsets[i]});
    for (int32_t i=0;i<persistent_count;++i) _persistent_templates.push_back({persistent_actions[i],persistent_domains[i],persistent_opcodes[i],persistent_values[i],persistent_durations[i],persistent_stacks[i],String(persistent_keys[i]).utf8().get_data(),String(persistent_definitions[i]).utf8().get_data(),{persistent_i0[i],persistent_i1[i],persistent_i2[i],persistent_i3[i]}});
    for (int32_t i=0;i<enter_count;++i) _on_enter_templates.push_back({enter_actions[i],enter_domains[i],enter_opcodes[i],enter_values[i],enter_durations[i],enter_stacks[i],String(enter_keys[i]).utf8().get_data(),String(enter_definitions[i]).utf8().get_data(),{enter_i0[i],enter_i1[i],enter_i2[i],enter_i3[i]}});
    for (int32_t i=0;i<stance_count;++i) _class_stances.push_back({stance_classes[i],{stance_adopt[i],stance_repeal[i],stance_promote[i]},{stance_adopt_min[i],stance_repeal_min[i],stance_promote_min[i]}});
    for (int32_t i=0;i<synergy_requirement_ideologies.size();++i) _synergy_requirements.push_back({synergy_requirement_ideologies[i],synergy_requirement_levels[i],synergy_requirement_locations[i]});
    for (int32_t i=0;i<synergy_effect_count;++i) _synergy_templates.push_back({synergy_actions[i],synergy_domains[i],synergy_opcodes[i],synergy_values[i],synergy_durations[i],synergy_stacks[i],String(synergy_keys[i]).utf8().get_data(),String(synergy_definitions[i]).utf8().get_data(),{synergy_i0[i],synergy_i1[i],synergy_i2[i],synergy_i3[i]}});
    for (int32_t i=0;i<synergy_count;++i) _synergies.push_back({synergy_requirement_offsets[i],synergy_requirement_offsets[i+1]-synergy_requirement_offsets[i],synergy_effect_offsets[i],synergy_effect_offsets[i+1]-synergy_effect_offsets[i]});
    _ideology_synergy_offsets.assign(ideology_synergy_offsets.ptr(), ideology_synergy_offsets.ptr()+ideology_synergy_offsets.size());
    _ideology_synergy_ids.assign(ideology_synergy_ids.ptr(), ideology_synergy_ids.ptr()+ideology_synergy_ids.size());
    _synergy_candidate_stamps.assign(static_cast<size_t>(synergy_count), 0);
    _political_class_count = political_class_ids.size();
    _political_class_hash = 1469598103934665603ULL;
    for (int32_t i=0;i<political_class_ids.size();++i) {
        const std::string id=String(political_class_ids[i]).utf8().get_data();
        for (const unsigned char value:id) { _political_class_hash^=value; _political_class_hash*=1099511628211ULL; }
        _political_class_hash^=0xffU; _political_class_hash*=1099511628211ULL;
    }
    _technology_requirements.assign(tech.ptr(), tech.ptr()+tech.size()); _signal_requirements.assign(signals.ptr(), signals.ptr()+signals.size()); _gate_requirements.assign(gates.ptr(),gates.ptr()+gates.size());
    _ideology_capacity=std::max(0,int32_t(catalog.get("ideology_capacity",6))); _spirit_capacity=std::max(0,int32_t(catalog.get("national_spirit_capacity",3))); _draw_count=int32_t(catalog.get("offer_choice_count",3)); _offer_cost_q16=int64_t(catalog.get("offer_cost_q16",Q16_ONE)); _max_commands_per_slice=std::max(1,int32_t(catalog.get("max_commands_per_slice",4096))); _max_transition_commands=std::max(1,std::min(4096,int32_t(catalog.get("max_transition_commands",256)))); _max_transition_polls_per_slice=std::max(1,int32_t(catalog.get("max_transition_polls_per_slice",4096))); _max_active_visits_per_slice=std::max(1,int32_t(catalog.get("max_active_visits_per_slice",1024))); _opinion_owner_influence_weight=std::max(0,int32_t(catalog.get("opinion_owner_influence_weight",2))); _opinion_funds_per_influence=std::max<int64_t>(1,int64_t(catalog.get("opinion_funds_per_influence",1000000)));
    if (_draw_count!=3 || _offer_cost_q16<0) { error="ideology_profile_invalid"; return false; }
    _gate_count=std::max(0,max_gate+1); _idea_words=(count+63)/64; _gate_words=(_gate_count+63)/64;
    return true;
}

Dictionary NativeIdeologyRuntime::configure(const Dictionary &catalog) {
    _configured=false; reset_runtime_state(); std::string error; if (!validate_catalog(catalog,error)) return fail(error); _catalog_hash=compute_catalog_hash(); _configured=true; Dictionary out; out["ok"]=true; out["catalog_hash"]=static_cast<int64_t>(_catalog_hash); out["ideology_count"]=static_cast<int32_t>(_definitions.size()); return out;
}

void NativeIdeologyRuntime::reset_runtime_state() {
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
    _synergy_candidate_generation = 0;
    _synergy_candidate_scratch.clear();
    _transition_poll_ms = 0.0;
    _command_apply_ms = 0.0;
    _active_progress_ms = 0.0;
    _last_slice_ms = 0.0;
    _max_slice_ms = 0.0;
    _last_error.clear();
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
        state = CountryState{};
        state.handle = handle;
        state.rng_state = handle ^ (_catalog_hash + 0x9e3779b97f4a7c15ULL);
        state.known_bits.assign(static_cast<size_t>(_idea_words), 0);
        state.gate_bits.assign(static_cast<size_t>(_gate_words), 0);
        state.active_bits.assign(static_cast<size_t>(_idea_words), 0);
        state.active_synergy_bits.assign(
            (_synergies.size() + 63U) / 64U, 0);
    }
    return &state;
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
    if (active) word |= mask;
    else word &= ~mask;
}

bool NativeIdeologyRuntime::synergy_requirements_met(
        const CountryState &country, int32_t synergy_id) const {
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
        const IdeaState *state =
            idea_state_for(country, requirement.ideology_id);
        if (state == nullptr ||
                state->level < requirement.minimum_level ||
                (requirement.location_mask &
                 (1U << state->location)) == 0)
            return false;
    }
    return true;
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
        uint64_t hash = 1469598103934665603ULL;
        hash = mixv(hash, country_handle); hash = mixv(hash, ideology_id); hash = mixv(hash, level);
        hash = mixv(hash, begin + offset); hash = mixv(hash, salt); hash = mixv(hash, remove);
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

bool NativeIdeologyRuntime::emit_level_effects(CountryState &country, IdeaState &state,
        int32_t level, bool remove_persistent, bool include_on_enter, int64_t day,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (level < 0 || state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size())) return true;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    if (level >= definition.level_count) return true;
    const Level &row = _levels[static_cast<size_t>(definition.level_begin + level)];
    if (!emit_templates(country.handle, state.ideology_id, level, row.persistent_begin,
            row.persistent_count, remove_persistent, day, 0, commands, error)) return false;
    if (include_on_enter)
        return emit_templates(country.handle, state.ideology_id, level, row.on_enter_begin,
            row.on_enter_count, false, day, static_cast<uint64_t>(level + 1), commands, error);
    return true;
}

bool NativeIdeologyRuntime::start_transition(CountryState &country, IdeaState &state,
        uint8_t location, int32_t level, bool remove_previous_persistent,
        bool apply_current_persistent, uint64_t entered_on_success, int64_t day,
        std::string &error) {
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
    if (remove_previous_persistent && transition.previous_location != INACTIVE && transition.previous_level >= 0 &&
            !emit_level_effects(country, state, transition.previous_level, true,
                false, day, _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
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
        state.level = state.transition.previous_level;
        state.entered_levels = state.transition.previous_entered_levels;
        state.generation = state.transition.previous_generation;
        set_state_location(country, ref.idea_slot, previous_location);
        state.binding_id = 0;
        state.binding_generation = 0;
        state.binding_signature = 0;
        state.binding_program_hash = 0;
        if (state.location != INACTIVE) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error))
                _last_error = restore_error;
        }
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
    }
    country.pending_transition_count =
        std::max(0, country.pending_transition_count - 1);
    state.transition = IdeaState::Transition{};
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
        state.level >= 0, true, entered, day, error);
    if (started) ++_levels_advanced;
    return started;
}
uint64_t NativeIdeologyRuntime::next_random(CountryState&c){return splitmix64(c.rng_state);}
int32_t NativeIdeologyRuntime::sample_weighted(CountryState&c,const std::vector<int32_t>&pool,const std::vector<int64_t>&weights) const { int64_t sum=0;for(int64_t v:weights)sum=add_sat(sum,std::max<int64_t>(0,v));if(sum<=0)return -1;const uint64_t roll=splitmix64(c.rng_state)%static_cast<uint64_t>(sum);int64_t cursor=0;for(size_t i=0;i<pool.size();++i){cursor=add_sat(cursor,weights[i]);if(static_cast<uint64_t>(std::max<int64_t>(0,cursor))>roll)return pool[i];}return pool.back(); }
bool NativeIdeologyRuntime::open_offer(CountryState&c,int32_t slot,std::string&error){if(c.offer.active!=0){error="ideology_offer_pending";return false;}if(c.ideology_points_q16<_offer_cost_q16){error="ideology_points_insufficient";return false;}std::vector<int32_t>pool;std::vector<int64_t>weights;for(int32_t i=0;i<static_cast<int32_t>(_definitions.size());++i){const Definition&d=_definitions[i];if(known(c,i)||(d.acquisition&DRAW)==0||!requirements_met(c,slot,d))continue;pool.push_back(i);weights.push_back(d.rarity_weight);}if(pool.size()<3){error="ideology_offer_pool_insufficient";return false;}std::array<int32_t,3>draw{{-1,-1,-1}};for(int32_t n=0;n<3;++n){const int32_t selected=sample_weighted(c,pool,weights);if(selected<0){error="ideology_offer_weight_invalid";return false;}draw[n]=selected;const auto it=std::find(pool.begin(),pool.end(),selected);const size_t pos=static_cast<size_t>(it-pool.begin());pool.erase(it);weights.erase(weights.begin()+static_cast<std::ptrdiff_t>(pos));}c.ideology_points_q16-=_offer_cost_q16;c.offer.active=1;c.offer.generation=std::max<uint32_t>(1,c.offer.generation+1);c.offer.ideology_ids=draw;++c.draw_sequence;++_offers_opened;return true;}
bool NativeIdeologyRuntime::choose_offer(CountryState&c,const Command&cmd,std::string&error){if(c.offer.active==0||cmd.offer_generation!=c.offer.generation){error="ideology_offer_generation_stale";return false;}if(cmd.choice_index<0||cmd.choice_index>=3){error="ideology_offer_choice_invalid";return false;}const int32_t idea=c.offer.ideology_ids[cmd.choice_index];if(idea<0||known(c,idea)){error="ideology_offer_choice_unavailable";return false;}set_known(c,idea);idea_state_for(c,idea,true);c.offer.active=0;c.offer.ideology_ids={{-1,-1,-1}};return true;}
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
    if (ideology_slot_cost(country) + _definitions[ideology_id].ideology_cost > _ideology_capacity) {
        error = "ideology_slot_capacity_exceeded"; return false;
    }
    reconcile_level(*state); // inactive, therefore no Effect needs replacement yet.
    const uint64_t entered = unentered_level_mask(*state, state->level);
    if (!start_transition(country, *state, IDEOLOGY, state->level, false, true, entered, day, error))
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
    if (!start_transition(country, *state, INACTIVE, state->level, state->level >= 0,
            false, 0, day, error)) return false;
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
    if (spirit_slot_cost(country) + definition.spirit_cost > _spirit_capacity) {
        error = "national_spirit_slot_capacity_exceeded"; return false;
    }
    if (!support_gate(country, ideology_id, SUPPORT_PROMOTE, error))
        return false;
    if (!start_transition(country, *state, NATIONAL_SPIRIT, state->level,
            false, false, 0, day, error)) return false;
    return true;
}
bool NativeIdeologyRuntime::validate_command_shape(const Command&cmd,std::string&error) const { if(cmd.opcode<DISCOVER_IDEOLOGY||cmd.opcode>SET_IDEOLOGY_GATE||cmd.country_handle==0||cmd.producer_id<=0||cmd.sequence<0){error="ideology_command_invalid";return false;}if((cmd.opcode==DISCOVER_IDEOLOGY||cmd.opcode==EQUIP_IDEOLOGY||cmd.opcode==UNEQUIP_IDEOLOGY||cmd.opcode==PROMOTE_NATIONAL_SPIRIT||cmd.opcode==ADD_UNDERSTANDING)&& (cmd.ideology_id<0||cmd.ideology_id>=static_cast<int32_t>(_definitions.size()))){error="ideology_id_invalid";return false;}if(cmd.opcode==SET_IDEOLOGY_GATE&&(cmd.gate_id<0||cmd.gate_id>=_gate_count)){error="ideology_gate_invalid";return false;}if((cmd.opcode==GRANT_IDEOLOGY_POINTS||cmd.opcode==ADD_UNDERSTANDING)&&cmd.value_q16<0){error="ideology_value_negative";return false;}return true;}

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
        case OPEN_IDEOLOGY_OFFER: return open_offer(*country, country_slot, error);
        case CHOOSE_IDEOLOGY_OFFER: return choose_offer(*country, command, error);
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
    const Clock::time_point slice_started = Clock::now();
    int32_t handled = 0;
    int32_t visits = 0;
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
                if (growth_level >= 0 && growth_level < definition.level_count)
                    state->understanding_q16 = add_sat(state->understanding_q16,
                        _levels[definition.level_begin + growth_level].daily_understanding_q16);
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
    return finish(true, "ideology_active_progress");
}
bool NativeIdeologyRuntime::should_run(int64_t day) const {
    const Command *command = next_command();
    return _configured && ((command != nullptr && command->effective_day <= day) ||
        !_pending_transitions.empty() || _active_progress_day == day || _last_day < day);
}
Dictionary NativeIdeologyRuntime::snapshot(int64_t handle) const {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    Dictionary out; out["ok"] = true; out["country_handle"] = handle;
    if (country == nullptr) {
        out["ideology_points_q16"] = 0; out["known_ids"] = PackedInt32Array();
        out["idea_ids"] = PackedInt32Array(); out["offer_active"] = false;
        out["transition_pending"] = PackedByteArray();
        out["binding_ids"] = PackedInt64Array();
        out["binding_generations"] = PackedInt32Array();
        out["binding_verified"] = PackedByteArray();
        PackedInt32Array empty_transition_offsets;
        empty_transition_offsets.append(0);
        out["transition_transaction_offsets"] = empty_transition_offsets;
        out["transition_transaction_ids"] = PackedInt64Array();
        out["transition_transaction_statuses"] = PackedInt32Array();
        out["support_revision"] = static_cast<int64_t>(0);
        out["last_error"] = String(_last_error.c_str());
        return out;
    }
    PackedInt32Array known_ids, idea_ids, levels, locations;
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
    for (int32_t ideology_id : country->offer.ideology_ids) offer_ids.append(ideology_id);
    out["ideology_points_q16"] = country->ideology_points_q16;
    out["known_ids"] = known_ids; out["idea_ids"] = idea_ids;
    out["understanding_q16"] = understanding; out["levels"] = levels;
    out["locations"] = locations; out["transition_pending"] = transition_pending;
    out["binding_ids"] = binding_ids;
    out["binding_generations"] = binding_generations;
    out["binding_signatures"] = binding_signatures;
    out["binding_program_hashes"] = binding_program_hashes;
    out["binding_verified"] = binding_verified;
    out["transition_transaction_offsets"] = transition_transaction_offsets;
    out["transition_transaction_ids"] = transition_transaction_ids;
    out["transition_transaction_statuses"] = transition_transaction_statuses;
    out["ideology_slots_used"] = ideology_slot_cost(*country);
    out["ideology_slots_capacity"] = _ideology_capacity;
    out["national_spirit_slots_used"] = spirit_slot_cost(*country);
    out["national_spirit_slots_capacity"] = _spirit_capacity;
    out["offer_active"] = country->offer.active != 0;
    out["offer_generation"] = static_cast<int64_t>(country->offer.generation);
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
    out["commands_applied"] = static_cast<int64_t>(_commands_applied);
    out["commands_rejected"] = static_cast<int64_t>(_commands_rejected);
    out["offers_opened"] = static_cast<int64_t>(_offers_opened);
    out["levels_advanced"] = static_cast<int64_t>(_levels_advanced);
    out["class_snapshot_reads"] =
        static_cast<int64_t>(_class_snapshot_reads);
    out["support_evaluations"] =
        static_cast<int64_t>(_support_evaluations);
    out["synergy_candidates_visited"] =
        static_cast<int64_t>(_synergy_candidates_visited);
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
uint64_t NativeIdeologyRuntime::compute_catalog_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    hash = mixv(hash, _ideology_capacity);
    hash = mixv(hash, _spirit_capacity);
    hash = mixv(hash, _offer_cost_q16);
    hash = mixv(hash, _political_class_hash);
    hash = mixv(hash, _opinion_owner_influence_weight);
    hash = mixv(hash, _opinion_funds_per_influence);
    for (const Definition &definition : _definitions) {
        hash = mix(hash, definition.stable_id.data(),
            definition.stable_id.size());
        hash = mixv(hash, definition.acquisition);
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
    }
    return hash;
}
uint64_t NativeIdeologyRuntime::compute_state_hash() const {
    uint64_t hash = _catalog_hash;
    for (const CountryState &country : _countries) {
        hash = mixv(hash, country.handle); hash = mixv(hash, country.ideology_points_q16);
        hash = mixv(hash, country.rng_state); hash = mixv(hash, country.draw_sequence);
        for (uint64_t word : country.known_bits) hash = mixv(hash, word);
        for (uint64_t word : country.gate_bits) hash = mixv(hash, word);
        for (const IdeaState &state : country.ideas) {
            hash = mixv(hash, state.ideology_id); hash = mixv(hash, state.understanding_q16);
            hash = mixv(hash, state.level); hash = mixv(hash, state.entered_levels);
            hash = mixv(hash, state.generation); hash = mixv(hash, state.location);
            hash = mixv(hash, state.binding_id); hash = mixv(hash, state.binding_generation);
            hash = mixv(hash, state.binding_signature); hash = mixv(hash, state.binding_program_hash);
            hash = mixv(hash, state.transition.active);
            hash = mixv(hash, state.transition.previous_level);
            hash = mixv(hash, state.transition.previous_entered_levels);
            hash = mixv(hash, state.transition.previous_generation);
            hash = mixv(hash, state.transition.previous_location);
            hash = mixv(hash, state.transition.entered_on_success);
            for (int64_t transaction_id : state.transition.transaction_ids)
                hash = mixv(hash, transaction_id);
        }
    }
    return hash;
}
PackedByteArray NativeIdeologyRuntime::capture() const {
    PackedByteArray out;
    if (!_configured) return out;
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC); append_le<int32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash); append_le<int64_t>(bytes, _last_day);
    append_le<uint64_t>(bytes, _submit_order); append_le<uint64_t>(bytes, compute_state_hash());
    std::vector<std::pair<int32_t, int64_t>> high_watermarks(
        _producer_high_watermarks.begin(), _producer_high_watermarks.end());
    std::sort(high_watermarks.begin(), high_watermarks.end());
    append_le<uint64_t>(bytes, static_cast<uint64_t>(high_watermarks.size()));
    for (const auto &entry : high_watermarks) {
        append_le<int32_t>(bytes, entry.first);
        append_le<int64_t>(bytes, entry.second);
    }
    append_le<uint64_t>(bytes, static_cast<uint64_t>(_countries.size()));
    for (const CountryState &country : _countries) {
        append_le<uint64_t>(bytes, country.handle); append_le<int64_t>(bytes, country.ideology_points_q16);
        append_le<uint64_t>(bytes, country.rng_state); append_le<uint64_t>(bytes, country.draw_sequence);
        append_vec(bytes, country.known_bits); append_vec(bytes, country.gate_bits);
        append_le<uint32_t>(bytes, country.offer.generation); append_le<uint8_t>(bytes, country.offer.active);
        for (int32_t ideology_id : country.offer.ideology_ids) append_le<int32_t>(bytes, ideology_id);
        append_le<uint64_t>(bytes, static_cast<uint64_t>(country.ideas.size()));
        for (const IdeaState &state : country.ideas) {
            append_le<int32_t>(bytes, state.ideology_id); append_le<int64_t>(bytes, state.understanding_q16);
            append_le<int32_t>(bytes, state.level); append_le<uint64_t>(bytes, state.entered_levels);
            append_le<uint32_t>(bytes, state.generation); append_le<uint8_t>(bytes, state.location);
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
            magic != SAVE_MAGIC || schema < 1 || schema > SAVE_SCHEMA_VERSION) return fail("ideology_save_header_invalid");
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
    if (!read_le(data, size, cursor, country_count) || country_count > 1000000) return fail("ideology_save_country_count_invalid");
    std::vector<CountryState> countries(static_cast<size_t>(country_count));
    for (CountryState &country : countries) {
        if (!read_le(data, size, cursor, country.handle) || !read_le(data, size, cursor, country.ideology_points_q16) ||
                !read_le(data, size, cursor, country.rng_state) || !read_le(data, size, cursor, country.draw_sequence) ||
                !read_vec(data, size, cursor, country.known_bits, _idea_words) ||
                !read_vec(data, size, cursor, country.gate_bits, _gate_words) ||
                !read_le(data, size, cursor, country.offer.generation) || !read_le(data, size, cursor, country.offer.active))
            return fail("ideology_save_country_invalid");
        for (int32_t &ideology_id : country.offer.ideology_ids)
            if (!read_le(data, size, cursor, ideology_id)) return fail("ideology_save_offer_invalid");
        uint64_t idea_count = 0;
        if (!read_le(data, size, cursor, idea_count) || idea_count > _definitions.size()) return fail("ideology_save_idea_count_invalid");
        for (uint64_t n = 0; n < idea_count; ++n) {
            IdeaState state; uint64_t transition_count = 0;
            if (!read_le(data, size, cursor, state.ideology_id) || !read_le(data, size, cursor, state.understanding_q16) ||
                    !read_le(data, size, cursor, state.level) || !read_le(data, size, cursor, state.entered_levels) ||
                    !read_le(data, size, cursor, state.generation) || !read_le(data, size, cursor, state.location) ||
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
    if (!read_le(data, size, cursor, end) || end != SAVE_END || cursor != size) return fail("ideology_save_truncated");
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
    _countries = std::move(countries); _commands = std::move(commands);
    _producer_high_watermarks = std::move(producer_high_watermarks);
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
    };
    if (compute_state_hash() != state_hash) { rollback(); return fail("ideology_save_state_hash_mismatch"); }
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
Dictionary NativeIdeologyRuntime::clear_state(){if(!_configured)return fail("ideology_runtime_unconfigured");reset_runtime_state();Dictionary o;o["ok"]=true;return o;}
} // namespace pk
