#include "ideology_runtime.h"

#include "country_runtime.h"
#include "effect_runtime.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cstring>
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
    const auto persistent_count = persistent_actions.size();
    const auto enter_count = enter_actions.size();
    if (acquisition.size()!=count || weights.size()!=count || ideology_costs.size()!=count || spirit_costs.size()!=count || spirit_levels.size()!=count || level_offsets.size()!=count+1 || tech_offsets.size()!=count+1 || signal_offsets.size()!=count+1 || gate_offsets.size()!=count+1 || thresholds.size()!=daily.size() || thresholds.size()>MAX_LEVELS || persistent_offsets.size()!=thresholds.size()+1 || enter_offsets.size()!=thresholds.size()+1 || persistent_domains.size()!=persistent_count || persistent_opcodes.size()!=persistent_count || persistent_values.size()!=persistent_count || persistent_durations.size()!=persistent_count || persistent_stacks.size()!=persistent_count || persistent_keys.size()!=persistent_count || persistent_definitions.size()!=persistent_count || persistent_i0.size()!=persistent_count || persistent_i1.size()!=persistent_count || persistent_i2.size()!=persistent_count || persistent_i3.size()!=persistent_count || enter_domains.size()!=enter_count || enter_opcodes.size()!=enter_count || enter_values.size()!=enter_count || enter_durations.size()!=enter_count || enter_stacks.size()!=enter_count || enter_keys.size()!=enter_count || enter_definitions.size()!=enter_count || enter_i0.size()!=enter_count || enter_i1.size()!=enter_count || enter_i2.size()!=enter_count || enter_i3.size()!=enter_count) { error="ideology_catalog_columns_invalid"; return false; }
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
    _definitions.clear(); _levels.clear(); _persistent_templates.clear(); _on_enter_templates.clear(); _technology_requirements.clear(); _signal_requirements.clear(); _gate_requirements.clear();
    _definitions.reserve(count); _levels.reserve(thresholds.size());
    for (int32_t i=0;i<count;++i) {
        Definition d; d.stable_id=String(ids[i]).utf8().get_data(); d.acquisition=acquisition[i]; d.rarity_weight=weights[i]; d.ideology_cost=ideology_costs[i]; d.spirit_cost=spirit_costs[i]; d.min_spirit_level=spirit_levels[i]; d.level_begin=level_offsets[i]; d.level_count=level_offsets[i+1]-level_offsets[i]; d.technology_requirement_begin=tech_offsets[i]; d.technology_requirement_count=tech_offsets[i+1]-tech_offsets[i]; d.signal_requirement_begin=signal_offsets[i]; d.signal_requirement_count=signal_offsets[i+1]-signal_offsets[i]; d.gate_requirement_begin=gate_offsets[i]; d.gate_requirement_count=gate_offsets[i+1]-gate_offsets[i]; _definitions.push_back(std::move(d)); }
    for (int32_t i=0;i<thresholds.size();++i) _levels.push_back({thresholds[i],daily[i],persistent_offsets[i],persistent_offsets[i+1]-persistent_offsets[i],enter_offsets[i],enter_offsets[i+1]-enter_offsets[i]});
    for (int32_t i=0;i<persistent_count;++i) _persistent_templates.push_back({persistent_actions[i],persistent_domains[i],persistent_opcodes[i],persistent_values[i],persistent_durations[i],persistent_stacks[i],String(persistent_keys[i]).utf8().get_data(),String(persistent_definitions[i]).utf8().get_data(),{persistent_i0[i],persistent_i1[i],persistent_i2[i],persistent_i3[i]}});
    for (int32_t i=0;i<enter_count;++i) _on_enter_templates.push_back({enter_actions[i],enter_domains[i],enter_opcodes[i],enter_values[i],enter_durations[i],enter_stacks[i],String(enter_keys[i]).utf8().get_data(),String(enter_definitions[i]).utf8().get_data(),{enter_i0[i],enter_i1[i],enter_i2[i],enter_i3[i]}});
    _technology_requirements.assign(tech.ptr(), tech.ptr()+tech.size()); _signal_requirements.assign(signals.ptr(), signals.ptr()+signals.size()); _gate_requirements.assign(gates.ptr(),gates.ptr()+gates.size());
    _ideology_capacity=std::max(0,int32_t(catalog.get("ideology_capacity",6))); _spirit_capacity=std::max(0,int32_t(catalog.get("national_spirit_capacity",3))); _draw_count=int32_t(catalog.get("offer_choice_count",3)); _offer_cost_q16=int64_t(catalog.get("offer_cost_q16",Q16_ONE)); _max_commands_per_slice=std::max(1,int32_t(catalog.get("max_commands_per_slice",4096)));
    if (_draw_count!=3 || _offer_cost_q16<0) { error="ideology_profile_invalid"; return false; }
    _gate_count=std::max(0,max_gate+1); _idea_words=(count+63)/64; _gate_words=(_gate_count+63)/64;
    return true;
}

Dictionary NativeIdeologyRuntime::configure(const Dictionary &catalog) {
    _configured=false; reset_runtime_state(); std::string error; if (!validate_catalog(catalog,error)) return fail(error); _catalog_hash=compute_catalog_hash(); _configured=true; Dictionary out; out["ok"]=true; out["catalog_hash"]=static_cast<int64_t>(_catalog_hash); out["ideology_count"]=static_cast<int32_t>(_definitions.size()); return out;
}

void NativeIdeologyRuntime::reset_runtime_state() { _countries.clear(); _commands.clear(); _submit_order=0; _last_day=-1; _active_visits=0; _dormant_scan_count=0; _commands_applied=0; _commands_rejected=0; _offers_opened=0; _levels_advanced=0; _last_error.clear(); }

bool NativeIdeologyRuntime::validate_country(uint64_t handle, int32_t &slot) const { slot=static_cast<int32_t>(handle & 0xffffffffULL); return _country_runtime!=nullptr && handle!=0 && _country_runtime->valid_handle(static_cast<int64_t>(handle)); }
NativeIdeologyRuntime::CountryState *NativeIdeologyRuntime::country_state_for(uint64_t handle,bool create) { int32_t slot=-1; if(!validate_country(handle,slot)) return nullptr; if(slot>=static_cast<int32_t>(_countries.size())) { if(!create) return nullptr; _countries.resize(static_cast<size_t>(slot+1)); } CountryState &state=_countries[slot]; if(state.handle!=handle) { if(!create && state.handle==0) return nullptr; state=CountryState{}; state.handle=handle; state.rng_state=(handle ^ (_catalog_hash + 0x9e3779b97f4a7c15ULL)); state.known_bits.assign(_idea_words,0); state.gate_bits.assign(_gate_words,0); } return &state; }
const NativeIdeologyRuntime::CountryState *NativeIdeologyRuntime::country_state_for(uint64_t handle) const { const int32_t slot=static_cast<int32_t>(handle & 0xffffffffULL); if(slot<0 || slot>=static_cast<int32_t>(_countries.size())) return nullptr; const CountryState &state=_countries[slot]; return state.handle==handle?&state:nullptr; }
NativeIdeologyRuntime::IdeaState *NativeIdeologyRuntime::idea_state_for(CountryState &country,int32_t id,bool create) { auto found=country.idea_indices.find(id); if(found!=country.idea_indices.end()) return &country.ideas[found->second]; if(!create || id<0 || id>=static_cast<int32_t>(_definitions.size())) return nullptr; const int32_t index=static_cast<int32_t>(country.ideas.size()); country.ideas.push_back({id,0,-1,0,1,INACTIVE}); country.idea_indices[id]=index; return &country.ideas.back(); }
const NativeIdeologyRuntime::IdeaState *NativeIdeologyRuntime::idea_state_for(const CountryState &country,int32_t id) const { auto found=country.idea_indices.find(id); return found==country.idea_indices.end()?nullptr:&country.ideas[found->second]; }
bool NativeIdeologyRuntime::known(const CountryState &c,int32_t id) const { return id>=0 && id<static_cast<int32_t>(_definitions.size()) && (c.known_bits[id/64]&(1ULL<<(id%64)))!=0; }
void NativeIdeologyRuntime::set_known(CountryState &c,int32_t id) { c.known_bits[id/64]|=(1ULL<<(id%64)); }
bool NativeIdeologyRuntime::gate(const CountryState &c,int32_t id) const { return id>=0 && id<_gate_count && (c.gate_bits[id/64]&(1ULL<<(id%64)))!=0; }
void NativeIdeologyRuntime::set_gate(CountryState &c,int32_t id,bool value) { if(id<0||id>=_gate_count)return; const uint64_t mask=1ULL<<(id%64); if(value)c.gate_bits[id/64]|=mask; else c.gate_bits[id/64]&=~mask; }
bool NativeIdeologyRuntime::requirements_met(const CountryState &country,int32_t slot,const Definition &d) const { if(_country_runtime==nullptr)return false; for(int32_t i=0;i<d.technology_requirement_count;++i) if(!_country_runtime->has_technology(slot,_technology_requirements[d.technology_requirement_begin+i])) return false; for(int32_t i=0;i<d.signal_requirement_count;++i) if(!_country_runtime->has_research_signal(slot,_signal_requirements[d.signal_requirement_begin+i])) return false; for(int32_t i=0;i<d.gate_requirement_count;++i) if(!gate(country,_gate_requirements[d.gate_requirement_begin+i])) return false; return true; }
int32_t NativeIdeologyRuntime::ideology_slot_cost(const CountryState &c) const { int32_t total=0; for(const IdeaState&s:c.ideas) if(s.location==IDEOLOGY) total+=_definitions[s.ideology_id].ideology_cost; return total; }
int32_t NativeIdeologyRuntime::spirit_slot_cost(const CountryState &c) const { int32_t total=0; for(const IdeaState&s:c.ideas) if(s.location==NATIONAL_SPIRIT) total+=_definitions[s.ideology_id].spirit_cost; return total; }
void NativeIdeologyRuntime::rebuild_active(CountryState &c) { c.active_ideologies.clear(); for(const IdeaState&s:c.ideas) if(s.location!=INACTIVE)c.active_ideologies.push_back(s.ideology_id); std::sort(c.active_ideologies.begin(),c.active_ideologies.end()); }
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
        uint64_t salt, std::vector<int64_t> &transaction_ids, std::string &error) {
    if (count <= 0) return true;
    if (_effect_runtime == nullptr) { error = "ideology_effect_runtime_unavailable"; return false; }
    const std::vector<EffectTemplate> &templates = remove
        ? _persistent_templates : (salt == 0 ? _persistent_templates : _on_enter_templates);
    const uint32_t target_generation = static_cast<uint32_t>(country_handle >> 32U);
    const int64_t tier_source_id = static_cast<int64_t>(
        (static_cast<uint64_t>(ideology_id + 1) << 32U) | static_cast<uint32_t>(level + 1));
    for (int32_t offset = 0; offset < count; ++offset) {
        const EffectTemplate &templ = templates[static_cast<size_t>(begin + offset)];
        uint64_t hash = 1469598103934665603ULL;
        hash = mixv(hash, country_handle); hash = mixv(hash, ideology_id); hash = mixv(hash, level);
        hash = mixv(hash, begin + offset); hash = mixv(hash, salt); hash = mixv(hash, remove);
        const int64_t effect_id = static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
        int64_t transaction_id = 0;
        const int32_t opcode = remove ? 2 : templ.opcode; // Modifier COMMAND_REMOVE
        if (!_effect_runtime->enqueue_external_effect_pod(effect_id, day, 0x4944454F,
                tier_source_id, "ideology.command", country_handle, country_handle,
                target_generation, static_cast<uint64_t>(offset + 1), templ.action,
                templ.domain, opcode, templ.value_q16, templ.duration_days, templ.stacks,
                templ.command_key, templ.definition_key, templ.payload, error, &transaction_id)) {
            if (error.empty()) error = "ideology_effect_enqueue_failed";
            return false;
        }
        if (transaction_id > 0 && std::find(transaction_ids.begin(), transaction_ids.end(), transaction_id) == transaction_ids.end())
            transaction_ids.push_back(transaction_id);
    }
    return true;
}

bool NativeIdeologyRuntime::emit_level_effects(CountryState &country, IdeaState &state,
        int32_t level, bool remove_persistent, bool include_on_enter, int64_t day,
        std::vector<int64_t> &transaction_ids, std::string &error) {
    if (level < 0 || state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size())) return true;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    if (level >= definition.level_count) return true;
    const Level &row = _levels[static_cast<size_t>(definition.level_begin + level)];
    if (!emit_templates(country.handle, state.ideology_id, level, row.persistent_begin,
            row.persistent_count, remove_persistent, day, 0, transaction_ids, error)) return false;
    if (include_on_enter)
        return emit_templates(country.handle, state.ideology_id, level, row.on_enter_begin,
            row.on_enter_count, false, day, static_cast<uint64_t>(level + 1), transaction_ids, error);
    return true;
}

bool NativeIdeologyRuntime::start_transition(CountryState &country, IdeaState &state,
        uint8_t location, int32_t level, bool remove_previous_persistent,
        bool apply_current_persistent, uint64_t entered_on_success, int64_t day,
        std::string &error) {
    if (state.transition.active != 0) { error = "ideology_transition_pending"; return false; }
    IdeaState::Transition transition;
    transition.active = 1;
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
        if (new_binding_created && state.binding_id > 0 &&
                state.binding_generation != 0 && _effect_runtime != nullptr) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        state.location = transition.previous_location;
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
    state.location = location;
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
            !emit_level_effects(country, state, transition.previous_level, true, false, day, transition.transaction_ids, error)) {
        rollback_before_transition();
        return false;
    }
    if (apply_current_persistent && location != INACTIVE && level >= 0 &&
            !emit_level_effects(country, state, level, false, false, day, transition.transaction_ids, error)) {
        rollback_before_transition();
        return false;
    }
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    for (int32_t entered_level = 0; entered_level < definition.level_count && entered_level < 64; ++entered_level) {
        if ((entered_on_success & (1ULL << entered_level)) == 0) continue;
        const Level &row = _levels[definition.level_begin + entered_level];
        if (!emit_templates(country.handle, state.ideology_id, entered_level, row.on_enter_begin,
                row.on_enter_count, false, day, static_cast<uint64_t>(entered_level + 1),
                transition.transaction_ids, error)) {
            rollback_before_transition();
            return false;
        }
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
    return true;
}

void NativeIdeologyRuntime::poll_transitions(CountryState &country) {
    if (_effect_runtime == nullptr) return;
    bool rebuild = false;
    for (IdeaState &state : country.ideas) {
        if (state.transition.active == 0) continue;
        bool pending = false;
        bool failed = false;
        for (const int64_t transaction_id : state.transition.transaction_ids) {
            const int32_t status = _effect_runtime->transaction_status_pod(transaction_id);
            if (status == EffectRuntime::ACKED) continue;
            if (status == EffectRuntime::REJECTED || status == EffectRuntime::RESYNC_REQUIRED || status == 0) {
                failed = true; break;
            }
            pending = true;
        }
        if (pending && !failed) continue;
        if (failed) {
            _last_error = "ideology_effect_transition_rejected";
            if (state.location != INACTIVE) {
                std::string ignored;
                _effect_runtime->retire_external_binding_pod(state.binding_id,
                    state.binding_generation, ignored);
            }
            state.level = state.transition.previous_level;
            state.entered_levels = state.transition.previous_entered_levels;
            state.generation = state.transition.previous_generation;
            state.location = state.transition.previous_location;
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
        state.transition = IdeaState::Transition{};
        rebuild = true;
    }
    if (rebuild) rebuild_active(country);
}

bool NativeIdeologyRuntime::start_next_level_transition(CountryState &country,
        IdeaState &state, int64_t day, std::string &error) {
    if (state.location == INACTIVE || state.transition.active != 0) return true;
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
    IdeaState *state = idea_state_for(country, ideology_id, true);
    if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (state->location == NATIONAL_SPIRIT) { error = "ideology_is_national_spirit"; return false; }
    if (state->location == IDEOLOGY) return true;
    if (ideology_slot_cost(country) + _definitions[ideology_id].ideology_cost > _ideology_capacity) {
        error = "ideology_slot_capacity_exceeded"; return false;
    }
    reconcile_level(*state); // inactive, therefore no Effect needs replacement yet.
    const uint64_t entered = unentered_level_mask(*state, state->level);
    if (!start_transition(country, *state, IDEOLOGY, state->level, false, true, entered, day, error))
        return false;
    rebuild_active(country);
    return true;
}

bool NativeIdeologyRuntime::unequip(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    IdeaState *state = idea_state_for(country, ideology_id, false);
    if (state == nullptr || state->location != IDEOLOGY) { error = "ideology_not_equipped"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (!start_transition(country, *state, INACTIVE, state->level, state->level >= 0,
            false, 0, day, error)) return false;
    rebuild_active(country);
    return true;
}

bool NativeIdeologyRuntime::promote(CountryState &country, int32_t ideology_id,
        int64_t day, std::string &error) {
    if (!known(country, ideology_id)) { error = "ideology_unknown"; return false; }
    IdeaState *state = idea_state_for(country, ideology_id, true);
    if (state == nullptr) { error = "ideology_state_unavailable"; return false; }
    if (state->transition.active != 0) { error = "ideology_transition_pending"; return false; }
    if (state->location == NATIONAL_SPIRIT) return true;
    reconcile_level(*state);
    const Definition &definition = _definitions[ideology_id];
    if (state->level < definition.min_spirit_level) { error = "ideology_national_spirit_level_insufficient"; return false; }
    if (spirit_slot_cost(country) + definition.spirit_cost > _spirit_capacity) {
        error = "national_spirit_slot_capacity_exceeded"; return false;
    }
    if (state->location == IDEOLOGY) {
        // The source identity is country + ideology + active form, not slot
        // position. Moving an active ideology to national spirit preserves its
        // exact current Modifier while changing only the durable binding form.
        state->location = NATIONAL_SPIRIT;
        ++state->generation;
        std::string binding_error;
        if (!sync_external_binding(country.handle, *state, binding_error)) {
            state->location = IDEOLOGY;
            --state->generation;
            error = binding_error;
            return false;
        }
        std::string ignored;
        _effect_runtime->retire_external_binding_pod(
            binding_id_for(country.handle, ideology_id, IDEOLOGY),
            state->generation - 1, ignored);
        rebuild_active(country);
        return true;
    }
    const uint64_t entered = unentered_level_mask(*state, state->level);
    if (!start_transition(country, *state, NATIONAL_SPIRIT, state->level,
            false, true, entered, day, error)) return false;
    rebuild_active(country);
    return true;
}
bool NativeIdeologyRuntime::validate_command_shape(const Command&cmd,std::string&error) const { if(cmd.opcode<DISCOVER_IDEOLOGY||cmd.opcode>SET_IDEOLOGY_GATE||cmd.country_handle==0){error="ideology_command_invalid";return false;}if((cmd.opcode==DISCOVER_IDEOLOGY||cmd.opcode==EQUIP_IDEOLOGY||cmd.opcode==UNEQUIP_IDEOLOGY||cmd.opcode==PROMOTE_NATIONAL_SPIRIT||cmd.opcode==ADD_UNDERSTANDING)&& (cmd.ideology_id<0||cmd.ideology_id>=static_cast<int32_t>(_definitions.size()))){error="ideology_id_invalid";return false;}if(cmd.opcode==SET_IDEOLOGY_GATE&&(cmd.gate_id<0||cmd.gate_id>=_gate_count)){error="ideology_gate_invalid";return false;}if((cmd.opcode==GRANT_IDEOLOGY_POINTS||cmd.opcode==ADD_UNDERSTANDING)&&cmd.value_q16<0){error="ideology_value_negative";return false;}return true;}
Dictionary NativeIdeologyRuntime::submit_commands(const Dictionary&batch){if(!_configured)return fail("ideology_runtime_unconfigured");const PackedInt32Array ops=i32s(batch,"opcodes"),prio=i32s(batch,"source_priorities"),ids=i32s(batch,"ideology_ids"),choices=i32s(batch,"choice_indices"),gates=i32s(batch,"gate_ids");const PackedInt64Array days=i64s(batch,"effective_days"),seq=i64s(batch,"sequences"),handles=i64s(batch,"country_handles"),values=i64s(batch,"values_q16"),offer=i64s(batch,"offer_generations");const int32_t count=ops.size();if(count<=0||days.size()!=count||prio.size()!=count||seq.size()!=count||handles.size()!=count||ids.size()!=count||values.size()!=count||offer.size()!=count||choices.size()!=count||gates.size()!=count)return fail("ideology_command_columns_invalid");std::vector<Command>staged;staged.reserve(count);for(int32_t i=0;i<count;++i){Command c;c.opcode=ops[i];c.effective_day=days[i];c.source_priority=prio[i];c.sequence=seq[i];c.country_handle=static_cast<uint64_t>(handles[i]);c.ideology_id=ids[i];c.value_q16=values[i];c.offer_generation=static_cast<uint32_t>(std::max<int64_t>(0,offer[i]));c.choice_index=choices[i];c.gate_id=gates[i];c.submit_order=_submit_order+static_cast<uint64_t>(i)+1;std::string e;if(!validate_command_shape(c,e))return fail(e);staged.push_back(c);} _submit_order+=static_cast<uint64_t>(count);_commands.insert(_commands.end(),staged.begin(),staged.end());std::stable_sort(_commands.begin(),_commands.end(),[](const Command&a,const Command&b){return std::tie(a.effective_day,a.source_priority,a.sequence,a.submit_order)<std::tie(b.effective_day,b.source_priority,b.sequence,b.submit_order);});Dictionary out;out["ok"]=true;out["accepted"]=count;out["pending"]=static_cast<int32_t>(_commands.size());return out;}

bool NativeIdeologyRuntime::submit_trigger_command_pod(int32_t opcode, int64_t effective_day,
        int32_t source_priority, int64_t sequence, uint64_t country_handle,
        int32_t ideology_id, int64_t value_q16, uint32_t offer_generation,
        int32_t choice_index, int32_t gate_id, std::string &error) {
    if (!_configured) { error = "ideology_runtime_unconfigured"; return false; }
    Command command;
    command.opcode = opcode; command.effective_day = effective_day;
    command.source_priority = source_priority; command.sequence = sequence;
    command.country_handle = country_handle; command.ideology_id = ideology_id;
    command.value_q16 = value_q16; command.offer_generation = offer_generation;
    command.choice_index = choice_index; command.gate_id = gate_id;
    command.submit_order = ++_submit_order;
    if (!validate_command_shape(command, error)) return false;
    _commands.push_back(command);
    std::stable_sort(_commands.begin(), _commands.end(), [](const Command &a, const Command &b) {
        return std::tie(a.effective_day, a.source_priority, a.sequence, a.submit_order) <
            std::tie(b.effective_day, b.source_priority, b.sequence, b.submit_order);
    });
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
    for (CountryState &country : _countries) poll_transitions(country);
    int32_t handled = 0;
    size_t erase = 0;
    for (; erase < _commands.size() && _commands[erase].effective_day <= day &&
            handled < _max_commands_per_slice; ++erase, ++handled) {
        std::string error;
        if (!apply_command(_commands[erase], day, error)) {
            ++_commands_rejected;
            _last_error = error;
        } else {
            ++_commands_applied;
        }
    }
    if (erase > 0) _commands.erase(_commands.begin(), _commands.begin() + static_cast<std::ptrdiff_t>(erase));
    if (handled >= _max_commands_per_slice && !_commands.empty() && _commands.front().effective_day <= day) {
        Dictionary out; out["ok"] = true; out["done"] = false;
        out["stage"] = "ideology_commands"; out["commands_applied"] = handled;
        return out;
    }
    int32_t visits = 0;
    for (CountryState &country : _countries) {
        int32_t country_slot = -1;
        if (country.handle == 0 || !validate_country(country.handle, country_slot)) continue;
        for (const int32_t ideology_id : country.active_ideologies) {
            IdeaState *state = idea_state_for(country, ideology_id, false);
            if (state == nullptr || state->location == INACTIVE) continue;
            ++visits; ++_active_visits;
            const Definition &definition = _definitions[ideology_id];
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
    _last_day = day;
    Dictionary out; out["ok"] = true; out["done"] = true;
    out["stage"] = "ideology_active_progress"; out["commands_applied"] = handled;
    out["active_visits"] = visits; out["dormant_scan_count"] = 0;
    return out;
}
bool NativeIdeologyRuntime::should_run(int64_t day) const { return _configured && ((!_commands.empty()&&_commands.front().effective_day<=day)||_last_day<day); }
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
    out["last_error"] = String(_last_error.c_str());
    return out;
}
Dictionary NativeIdeologyRuntime::explain(int64_t handle,int32_t id) const { if(id<0||id>=static_cast<int32_t>(_definitions.size()))return fail("ideology_id_invalid");Dictionary out;out["ok"]=true;out["ideology_id"]=id;const CountryState*c=country_state_for(static_cast<uint64_t>(handle));const IdeaState*s=c==nullptr?nullptr:idea_state_for(*c,id);const Definition&d=_definitions[id];out["known"]=c!=nullptr&&known(*c,id);out["level"]=s==nullptr?-1:s->level;out["understanding_q16"]=s==nullptr?0:s->understanding_q16;out["location"]=s==nullptr?INACTIVE:s->location;PackedInt64Array thresholds,daily;for(int32_t i=0;i<d.level_count;++i){thresholds.append(_levels[d.level_begin+i].threshold_q16);daily.append(_levels[d.level_begin+i].daily_understanding_q16);}out["thresholds_q16"]=thresholds;out["daily_understanding_q16"]=daily;out["min_spirit_level"]=d.min_spirit_level;return out;}
Dictionary NativeIdeologyRuntime::report() const { Dictionary o;o["configured"]=_configured;o["catalog_hash"]=static_cast<int64_t>(_catalog_hash);o["state_hash"]=static_cast<int64_t>(compute_state_hash());o["ideology_count"]=static_cast<int32_t>(_definitions.size());o["countries_allocated"]=static_cast<int32_t>(_countries.size());o["pending_commands"]=static_cast<int32_t>(_commands.size());o["active_visits"]=static_cast<int64_t>(_active_visits);o["dormant_scan_count"]=0;o["commands_applied"]=static_cast<int64_t>(_commands_applied);o["commands_rejected"]=static_cast<int64_t>(_commands_rejected);o["offers_opened"]=static_cast<int64_t>(_offers_opened);o["levels_advanced"]=static_cast<int64_t>(_levels_advanced);o["last_error"]=String(_last_error.c_str());return o;}
uint64_t NativeIdeologyRuntime::compute_catalog_hash() const { uint64_t h=1469598103934665603ULL;h=mixv(h,_ideology_capacity);h=mixv(h,_spirit_capacity);h=mixv(h,_offer_cost_q16);for(const Definition&d:_definitions){h=mix(h,d.stable_id.data(),d.stable_id.size());h=mixv(h,d.acquisition);h=mixv(h,d.rarity_weight);h=mixv(h,d.ideology_cost);h=mixv(h,d.spirit_cost);h=mixv(h,d.min_spirit_level);}for(const Level&l:_levels){h=mixv(h,l.threshold_q16);h=mixv(h,l.daily_understanding_q16);}return h;}
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
            append_le<int32_t>(bytes, state.transition.previous_level);
            append_le<uint64_t>(bytes, state.transition.previous_entered_levels);
            append_le<uint32_t>(bytes, state.transition.previous_generation);
            append_le<uint8_t>(bytes, state.transition.previous_location);
            append_le<uint64_t>(bytes, state.transition.entered_on_success);
            append_le<uint64_t>(bytes, static_cast<uint64_t>(state.transition.transaction_ids.size()));
            for (int64_t transaction_id : state.transition.transaction_ids) append_le<int64_t>(bytes, transaction_id);
        }
    }
    append_le<uint64_t>(bytes, static_cast<uint64_t>(_commands.size()));
    for (const Command &command : _commands) {
        append_le<int32_t>(bytes, command.opcode); append_le<int64_t>(bytes, command.effective_day);
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
            magic != SAVE_MAGIC || (schema != 1 && schema != SAVE_SCHEMA_VERSION)) return fail("ideology_save_header_invalid");
    if (catalog_hash != _catalog_hash) return fail("ideology_save_catalog_mismatch");
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
            if (state.transition.active == 0 && !state.transition.transaction_ids.empty()) return fail("ideology_save_transition_invalid");
            country.idea_indices[state.ideology_id] = static_cast<int32_t>(country.ideas.size());
            country.ideas.push_back(std::move(state));
        }
        rebuild_active(country);
    }
    if (!read_le(data, size, cursor, command_count) || command_count > 10000000) return fail("ideology_save_command_count_invalid");
    std::vector<Command> commands; commands.reserve(static_cast<size_t>(command_count));
    for (uint64_t n = 0; n < command_count; ++n) {
        Command command;
        if (!read_le(data, size, cursor, command.opcode) || !read_le(data, size, cursor, command.effective_day) ||
                !read_le(data, size, cursor, command.source_priority) || !read_le(data, size, cursor, command.sequence) ||
                !read_le(data, size, cursor, command.country_handle) || !read_le(data, size, cursor, command.ideology_id) ||
                !read_le(data, size, cursor, command.value_q16) || !read_le(data, size, cursor, command.offer_generation) ||
                !read_le(data, size, cursor, command.choice_index) || !read_le(data, size, cursor, command.gate_id) ||
                !read_le(data, size, cursor, command.submit_order)) return fail("ideology_save_command_invalid");
        std::string error; if (!validate_command_shape(command, error)) return fail(error);
        commands.push_back(command);
    }
    if (!read_le(data, size, cursor, end) || end != SAVE_END || cursor != size) return fail("ideology_save_truncated");
    auto previous_countries = std::move(_countries);
    auto previous_commands = std::move(_commands);
    const int64_t previous_last_day = _last_day;
    const uint64_t previous_submit_order = _submit_order;
    _countries = std::move(countries); _commands = std::move(commands); _last_day = last_day; _submit_order = submit_order;
    auto rollback = [&]() {
        _countries = std::move(previous_countries);
        _commands = std::move(previous_commands);
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
