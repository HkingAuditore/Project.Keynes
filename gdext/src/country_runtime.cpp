#include "country_runtime.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "economy_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

namespace {
using Clock = std::chrono::steady_clock;
constexpr uint32_t SAVE_MAGIC = 0x4e434b50U; // PKCN
constexpr uint32_t SAVE_END = 0x21444e45U;   // END!
constexpr uint64_t FNV_OFFSET = 1469598103934665603ULL;
constexpr uint64_t FNV_PRIME = 1099511628211ULL;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

std::string to_utf8(const String &value) {
    const CharString bytes = value.utf8();
    return std::string(bytes.get_data(), static_cast<size_t>(bytes.length()));
}

template <typename T>
T dict_num(const Dictionary &d, const char *key, T fallback) {
    const StringName k(key);
    if (!d.has(k)) return fallback;
    const Variant value = d[k];
    if constexpr (std::is_same_v<T, int64_t>) return static_cast<int64_t>(value);
    if constexpr (std::is_same_v<T, int32_t>) return static_cast<int32_t>(static_cast<int64_t>(value));
    if constexpr (std::is_same_v<T, bool>) return static_cast<bool>(value);
    return fallback;
}

std::string dict_string(const Dictionary &d, const char *key,
                        const std::string &fallback = {}) {
    const StringName k(key);
    return d.has(k) ? to_utf8(static_cast<String>(d[k])) : fallback;
}

std::vector<std::string> packed_strings(const Dictionary &d, const char *key) {
    std::vector<std::string> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_STRING_ARRAY) return out;
    const PackedStringArray src = d[k];
    out.reserve(src.size());
    for (int i = 0; i < src.size(); ++i) out.push_back(to_utf8(src[i]));
    return out;
}

std::vector<int32_t> packed_i32(const Dictionary &d, const char *key) {
    std::vector<int32_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_INT32_ARRAY) return out;
    const PackedInt32Array src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int32_t));
    return out;
}

std::vector<int64_t> packed_i64(const Dictionary &d, const char *key) {
    std::vector<int64_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_INT64_ARRAY) return out;
    const PackedInt64Array src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int64_t));
    return out;
}

void hash_bytes(uint64_t &hash, const void *data, size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= FNV_PRIME;
    }
}

void hash_string(uint64_t &hash, const std::string &value) {
    hash_bytes(hash, value.data(), value.size());
    const uint8_t zero = 0;
    hash_bytes(hash, &zero, 1);
}

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    const U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i)
        out.push_back(static_cast<uint8_t>((bits >> (i * 8)) & static_cast<U>(0xff)));
}

template <typename T>
bool read_le(const std::vector<uint8_t> &in, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > in.size()) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(in[cursor++]) << (i * 8);
    value = static_cast<T>(bits);
    return true;
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_string(const std::vector<uint8_t> &in, size_t &cursor, std::string &value) {
    uint32_t length = 0;
    if (!read_le(in, cursor, length) || cursor + length > in.size()) return false;
    value.assign(reinterpret_cast<const char *>(in.data() + cursor), length);
    cursor += length;
    return true;
}

template <typename T>
void append_vector(std::vector<uint8_t> &out, const std::vector<T> &values) {
    append_le<uint64_t>(out, static_cast<uint64_t>(values.size()));
    for (const T &value : values) append_le<T>(out, value);
}

template <typename T>
bool read_vector(const std::vector<uint8_t> &in, size_t &cursor,
                 std::vector<T> &values, uint64_t max_count) {
    uint64_t count = 0;
    if (!read_le(in, cursor, count) || count > max_count) return false;
    values.resize(static_cast<size_t>(count));
    for (T &value : values) if (!read_le(in, cursor, value)) return false;
    return true;
}

Dictionary fail(const std::string &reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = String::utf8(reason.c_str());
    return out;
}

std::vector<uint8_t> packed_u8(const Dictionary &d, const char *key) {
    std::vector<uint8_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_BYTE_ARRAY) return out;
    const PackedByteArray src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size());
    return out;
}
} // namespace

Dictionary NativeCountryRuntime::configure(const Dictionary &catalog,
                                            const Dictionary &profile,
                                            int32_t cell_count, int64_t seed) {
    if (cell_count <= 0) return fail("country_cell_count_invalid");
    const std::vector<std::string> goods = packed_strings(catalog, "good_ids");
    const std::vector<std::string> professions =
        packed_strings(catalog, "profession_ids");
    const std::vector<std::string> building_types =
        packed_strings(catalog, "building_type_ids");
    const std::vector<std::string> technologies = packed_strings(catalog, "technology_ids");
    const std::vector<std::string> research_signals =
        packed_strings(catalog, "research_signal_ids");
    if (goods.empty() || professions.empty() || building_types.empty())
        return fail("country_tax_catalog_empty");

    std::unordered_set<std::string> unique;
    for (const std::string &id : goods)
        if (id.empty() || !unique.insert(id).second) return fail("country_good_catalog_invalid");
    unique.clear();
    for (const std::string &id : professions)
        if (id.empty() || !unique.insert(id).second)
            return fail("country_profession_catalog_invalid");
    unique.clear();
    for (const std::string &id : building_types)
        if (id.empty() || !unique.insert(id).second)
            return fail("country_building_catalog_invalid");
    unique.clear();
    for (const std::string &id : technologies)
        if (id.empty() || !unique.insert(id).second) return fail("country_technology_catalog_invalid");
    unique.clear();
    for (const std::string &id : research_signals)
        if (id.empty() || !unique.insert(id).second)
            return fail("country_research_signal_catalog_invalid");

    std::string mode = dict_string(profile, "country_runtime_mode", "ACTIVE");
    RuntimeMode parsed_mode = MODE_ACTIVE;
    if (mode == "OFF") parsed_mode = MODE_OFF;
    else if (mode == "PROBE") parsed_mode = MODE_PROBE;
    else if (mode != "ACTIVE") return fail("country_runtime_mode_invalid");
    const bool light_report_explicit = profile.has("country_light_report_enabled");
    _light_report_enabled = dict_num<bool>(
        profile, "country_light_report_enabled", true);
    // Direct Native callers and historical tests may only provide the runtime
    // mode. Keep that legacy contract FULL; the formal CountryProfile always
    // supplies the transient LIGHT switch explicitly for production ACTIVE.
    _full_diagnostics = parsed_mode == MODE_PROBE ||
        dict_num<bool>(profile, "country_full_diagnostics", false) ||
        !_light_report_enabled || !light_report_explicit;
    _pending_queue_enabled = dict_num<bool>(
        profile, "country_pending_queue_enabled", true);
    _state_hash_cache_valid = false;
    _pending_activation_index_dirty = true;
    _pending_activation_indices.clear();
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _research_full_scan_fallbacks = 0;
    _research_queue_fallback_reason.clear();

    _good_ids = goods;
    _profession_ids = professions;
    _building_type_ids = building_types;
    _technology_ids = technologies;
    _technology_catalog_identity_hash = static_cast<uint64_t>(
        dict_num<int64_t>(catalog, "technology_catalog_identity_hash", 0));
    _technology_content_binding_hash = static_cast<uint64_t>(
        dict_num<int64_t>(catalog, "technology_content_binding_hash", 0));
    _technology_trigger_definition_hash = static_cast<uint64_t>(
        dict_num<int64_t>(catalog, "technology_trigger_definition_hash", 0));
    if (_technology_catalog_identity_hash == 0 ||
        _technology_content_binding_hash == 0 ||
        _technology_trigger_definition_hash == 0)
        return fail("country_technology_catalog_identity_missing");
    _technology_era_reward_pool_ids = packed_strings(
        catalog, "technology_era_reward_pool_ids");
    _research_signal_ids = research_signals;
    _good_index.clear();
    _technology_index.clear();
    for (int32_t i = 0; i < static_cast<int32_t>(_good_ids.size()); ++i) _good_index[_good_ids[i]] = i;
    for (int32_t i = 0; i < static_cast<int32_t>(_technology_ids.size()); ++i) _technology_index[_technology_ids[i]] = i;
    _technology_domains = packed_i32(catalog, "technology_domain_indices");
    _technology_costs = packed_i64(catalog, "technology_costs");
    _technology_prerequisite_offsets = packed_i32(catalog, "technology_prerequisite_offsets");
    _technology_prerequisites = packed_i32(catalog, "technology_prerequisites");
    _technology_milestone_offsets = packed_i32(catalog, "technology_milestone_offsets");
    _technology_milestone_candidates = packed_i32(catalog, "technology_milestone_candidates");
    _technology_milestone_required_counts = packed_i32(catalog, "technology_milestone_required_counts");
    _technology_entry_milestone_indices =
        packed_i32(catalog, "technology_entry_milestone_indices");
    _technology_flags = packed_i32(catalog, "technology_flags");
    _technology_modifier_definition_keys =
        packed_strings(catalog, "technology_modifier_definition_keys");
    _research_signal_requires_provenance =
        packed_u8(catalog, "research_signal_requires_provenance");
    _technology_research_condition_offsets =
        packed_i32(catalog, "technology_research_condition_offsets");
    _technology_research_condition_ops =
        packed_i32(catalog, "technology_research_condition_ops");
    _technology_research_condition_refs =
        packed_i32(catalog, "technology_research_condition_refs");
    _technology_research_condition_values =
        packed_i64(catalog, "technology_research_condition_values");
    _technology_reveal_condition_offsets =
        packed_i32(catalog, "technology_reveal_condition_offsets");
    _technology_reveal_condition_ops =
        packed_i32(catalog, "technology_reveal_condition_ops");
    _technology_reveal_condition_refs =
        packed_i32(catalog, "technology_reveal_condition_refs");
    _technology_reveal_condition_values =
        packed_i64(catalog, "technology_reveal_condition_values");
    _technology_reveal_signal_offsets =
        packed_i32(catalog, "technology_reveal_signal_offsets");
    _technology_reveal_signal_technologies =
        packed_i32(catalog, "technology_reveal_signal_technologies");
    const size_t tech_count = _technology_ids.size();
    if (catalog.has("technology_era_reward_pool_ids")) {
        std::unordered_set<std::string> reward_pool_ids;
        if (_technology_era_reward_pool_ids.size() != 11)
            return fail("country_era_reward_pool_mapping_invalid");
        for (const std::string &pool_id : _technology_era_reward_pool_ids)
            if (pool_id.empty() || !reward_pool_ids.insert(pool_id).second)
                return fail("country_era_reward_pool_mapping_invalid");
    }
    if (_technology_domains.size() != tech_count || _technology_costs.size() != tech_count ||
        _technology_prerequisite_offsets.size() != tech_count + 1 ||
        _technology_milestone_offsets.size() != tech_count + 1 ||
        _technology_milestone_required_counts.size() != tech_count ||
        _technology_entry_milestone_indices.size() != tech_count ||
        _technology_flags.size() != tech_count ||
        _technology_modifier_definition_keys.size() != tech_count ||
        _technology_prerequisite_offsets.front() != 0 ||
        _technology_prerequisite_offsets.back() != static_cast<int32_t>(_technology_prerequisites.size()) ||
        _technology_milestone_offsets.front() != 0 ||
        _technology_milestone_offsets.back() != static_cast<int32_t>(_technology_milestone_candidates.size()))
        return fail("country_technology_metadata_invalid");

    if (_research_signal_requires_provenance.size() != _research_signal_ids.size() ||
        _technology_research_condition_offsets.size() != tech_count + 1 ||
        _technology_research_condition_offsets.empty() ||
        _technology_research_condition_offsets.front() != 0 ||
        _technology_research_condition_offsets.back() !=
            static_cast<int32_t>(_technology_research_condition_ops.size()) ||
        _technology_research_condition_ops.size() != _technology_research_condition_refs.size() ||
        _technology_research_condition_ops.size() != _technology_research_condition_values.size())
        return fail("country_research_condition_metadata_invalid");
    if (_technology_reveal_condition_offsets.size() != tech_count + 1 ||
        _technology_reveal_condition_offsets.empty() ||
        _technology_reveal_condition_offsets.front() != 0 ||
        _technology_reveal_condition_offsets.back() !=
            static_cast<int32_t>(_technology_reveal_condition_ops.size()) ||
        _technology_reveal_condition_ops.size() != _technology_reveal_condition_refs.size() ||
        _technology_reveal_condition_ops.size() != _technology_reveal_condition_values.size() ||
        _technology_reveal_signal_offsets.size() != _research_signal_ids.size() + 1 ||
        _technology_reveal_signal_offsets.empty() ||
        _technology_reveal_signal_offsets.front() != 0 ||
        _technology_reveal_signal_offsets.back() !=
            static_cast<int32_t>(_technology_reveal_signal_technologies.size()))
        return fail("country_reveal_condition_metadata_invalid");
    for (size_t tech = 0; tech < tech_count; ++tech) {
        if (_technology_domains[tech] < 0 || _technology_domains[tech] >= 4 ||
            _technology_costs[tech] < 0 ||
            _technology_milestone_required_counts[tech] < 0)
            return fail("country_technology_metadata_invalid");
    }
    for (int32_t prerequisite : _technology_prerequisites)
        if (prerequisite < 0 || prerequisite >= static_cast<int32_t>(tech_count))
            return fail("country_technology_prerequisite_invalid");
    for (int32_t entry_milestone : _technology_entry_milestone_indices)
        if (entry_milestone < -1 || entry_milestone >= static_cast<int32_t>(tech_count))
            return fail("country_technology_era_entry_invalid");
    for (int32_t candidate : _technology_milestone_candidates)
        if (candidate < 0 || candidate >= static_cast<int32_t>(tech_count))
            return fail("country_technology_milestone_candidate_invalid");
    for (size_t op = 0; op < _technology_research_condition_ops.size(); ++op) {
        const int32_t kind = _technology_research_condition_ops[op];
        const int32_t ref = _technology_research_condition_refs[op];
        const int64_t value = _technology_research_condition_values[op];
        if ((kind == 1 && (ref < 0 || ref >= static_cast<int32_t>(tech_count))) ||
            ((kind == 2 || kind == 3) &&
             (ref < 0 || ref >= static_cast<int32_t>(_research_signal_ids.size()))) ||
            ((kind == 10 || kind == 11 || kind == 12) && ref <= 0) ||
            (kind == 12 && value <= 0) ||
            (kind == 13 && ref != 1) ||
            (kind < 1 || kind > 13))
            return fail("country_research_condition_opcode_invalid");
    }
    for (size_t op = 0; op < _technology_reveal_condition_ops.size(); ++op) {
        const int32_t kind = _technology_reveal_condition_ops[op];
        const int32_t ref = _technology_reveal_condition_refs[op];
        const int64_t value = _technology_reveal_condition_values[op];
        if ((kind == 1 && (ref < 0 || ref >= static_cast<int32_t>(tech_count))) ||
            ((kind == 2 || kind == 3) &&
             (ref < 0 || ref >= static_cast<int32_t>(_research_signal_ids.size()))) ||
            ((kind == 10 || kind == 11 || kind == 12) && ref <= 0) ||
            (kind == 12 && value <= 0) ||
            (kind == 13 && ref != 1) ||
            (kind < 1 || kind > 13))
            return fail("country_reveal_condition_opcode_invalid");
    }
    for (int32_t technology : _technology_reveal_signal_technologies)
        if (technology < 0 || technology >= static_cast<int32_t>(tech_count))
            return fail("country_reveal_signal_index_invalid");
    const auto points_it = _good_index.find("technology_points");
    if (points_it == _good_index.end()) return fail("country_technology_points_good_missing");
    _technology_points_good_id = points_it->second;
    _starting_technologies.clear();
    for (const std::string &id : packed_strings(profile, "starting_technology_ids")) {
        const auto it = _technology_index.find(id);
        if (it == _technology_index.end()) return fail("country_starting_technology_unknown");
        _starting_technologies.push_back(it->second);
    }
    std::sort(_starting_technologies.begin(), _starting_technologies.end());
    _starting_technologies.erase(std::unique(_starting_technologies.begin(), _starting_technologies.end()),
                                 _starting_technologies.end());

    _cell_count = cell_count;
    _seed = seed;
    _mode = parsed_mode;
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63U) / 64U);
    _research_signal_words = static_cast<int32_t>((_research_signal_ids.size() + 63U) / 64U);
    _max_commands_per_slice = std::max<int32_t>(1, dict_num<int32_t>(profile, "country_max_commands_per_slice", 65536));
    _configured = true;
    _bootstrapped = false;
    _generation = 0;
    _submit_order = 0;
    _next_event_id = 1;
    _last_committed_day = -1;
    _countries = {};
    _cell_country_slot.assign(static_cast<size_t>(_cell_count), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
    _country_research_signals.clear();
    _country_research_signal_cells.clear();
    _country_research_signal_evidence.clear();
    _country_research_progress.clear();
    _country_research_queues.clear();
    _country_research_queue_lengths.clear();
    _country_research_weights_bp.clear();
    _country_research_auto_purchase.clear();
    _country_research_daily_budgets.clear();
    _country_research_deferred_points.clear();
    _country_research_purchased_total.clear();
    _country_research_consumed_total.clear();
    _country_research_progress_total.clear();
    _country_research_completed_total.clear();
    _country_tax_defaults.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _tax_policy_version = 0;
    _cell_tax_policy_ids.assign(static_cast<size_t>(_cell_count), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _last_research_day = -1;
    _pending_commands.clear();
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _next_effect_request_id = 1;
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};
    _is_water.clear();
    _report.clear();
    _report["configured"] = true;
    _report["bootstrapped"] = false;
    _report["runtime_mode"] = mode.c_str();
    _report["schema_version"] = SCHEMA_VERSION;

    Dictionary out;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["runtime_mode"] = mode.c_str();
    out["cell_count"] = _cell_count;
    out["good_count"] = static_cast<int64_t>(_good_ids.size());
    out["profession_count"] = static_cast<int64_t>(_profession_ids.size());
    out["building_type_count"] =
        static_cast<int64_t>(_building_type_ids.size());
    out["technology_count"] = static_cast<int64_t>(_technology_ids.size());
    out["catalog_hash"] = static_cast<int64_t>(catalog_hash());
    return out;
}

int32_t NativeCountryRuntime::append_country(const std::string &stable_id,
                                              const std::string &display_name,
                                              int64_t cash) {
    const int32_t slot = static_cast<int32_t>(_countries.active.size());
    _countries.active.push_back(1);
    _countries.generation.push_back(1);
    _countries.stable_id.push_back(stable_id);
    _countries.display_name.push_back(display_name);
    _countries.territory_count.push_back(0);
    _countries.cash.push_back(cash);
    _countries.state_version.push_back(1);
    _country_technologies.resize(static_cast<size_t>(slot + 1) * _technology_words, 0);
    _country_goods.resize(static_cast<size_t>(slot + 1) * _good_ids.size(), 0);
    _country_tax_defaults.resize(static_cast<size_t>(slot + 1) * TAX_KIND_COUNT,
                                 0);
    _country_income_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _profession_ids.size(),
        TAX_RATE_INHERIT);
    _country_consumption_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_RATE_INHERIT);
    _country_business_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _building_type_ids.size(),
        TAX_RATE_INHERIT);
    _country_import_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_RATE_INHERIT);
    _country_export_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_RATE_INHERIT);
    initialize_country_research(slot);
    return slot;
}

int32_t NativeCountryRuntime::tax_item_count(int32_t kind) const {
    switch (kind) {
        case TAX_INCOME:
            return static_cast<int32_t>(_profession_ids.size());
        case TAX_CONSUMPTION:
        case TAX_IMPORT:
        case TAX_EXPORT:
            return static_cast<int32_t>(_good_ids.size());
        case TAX_BUSINESS:
            return static_cast<int32_t>(_building_type_ids.size());
        default:
            return 0;
    }
}

const std::vector<int8_t> *NativeCountryRuntime::tax_override_vector(
        int32_t kind) const {
    switch (kind) {
        case TAX_INCOME: return &_country_income_tax_overrides;
        case TAX_CONSUMPTION: return &_country_consumption_tax_overrides;
        case TAX_BUSINESS: return &_country_business_tax_overrides;
        case TAX_IMPORT: return &_country_import_tax_overrides;
        case TAX_EXPORT: return &_country_export_tax_overrides;
        default: return nullptr;
    }
}

std::vector<int8_t> *NativeCountryRuntime::tax_override_vector(int32_t kind) {
    return const_cast<std::vector<int8_t> *>(
        static_cast<const NativeCountryRuntime *>(this)->tax_override_vector(kind));
}

int8_t NativeCountryRuntime::resolved_tax_rate(
        const std::vector<int8_t> &defaults,
        const std::vector<int8_t> &overrides, int32_t country_slot,
        int32_t kind, int32_t item, int32_t item_count) {
    if (country_slot < 0 || kind < 0 || kind >= TAX_KIND_COUNT ||
        item < 0 || item >= item_count)
        return 0;
    const int8_t value = overrides[
        static_cast<size_t>(country_slot) * item_count + item];
    return value == TAX_RATE_INHERIT
        ? defaults[static_cast<size_t>(country_slot) * TAX_KIND_COUNT + kind]
        : value;
}

uint64_t NativeCountryRuntime::cell_tax_policy_hash(
        const CellTaxPolicy &policy) {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, policy.defaults.data(), policy.defaults.size());
    for (const CellTaxOverride &entry : policy.overrides) {
        hash_bytes(hash, &entry.kind, sizeof(entry.kind));
        hash_bytes(hash, &entry.item, sizeof(entry.item));
        hash_bytes(hash, &entry.rate, sizeof(entry.rate));
    }
    return hash;
}

const NativeCountryRuntime::CellTaxPolicy &
NativeCountryRuntime::cell_tax_policy(uint32_t policy_id) const {
    static const CellTaxPolicy empty_policy;
    if (policy_id == 0 || policy_id >= _cell_tax_policies.size())
        return empty_policy;
    return _cell_tax_policies[policy_id];
}

uint32_t NativeCountryRuntime::intern_cell_tax_policy(
        const CellTaxPolicy &policy) {
    if (policy.empty()) return 0;
    const uint64_t hash = cell_tax_policy_hash(policy);
    auto &candidates = _cell_tax_policy_intern[hash];
    for (uint32_t id : candidates) {
        if (id < _cell_tax_policies.size() &&
            _cell_tax_policy_refcounts[id] > 0 &&
            _cell_tax_policies[id] == policy) {
            ++_cell_tax_policy_refcounts[id];
            return id;
        }
    }
    uint32_t id = 0;
    if (!_cell_tax_policy_free_ids.empty()) {
        id = _cell_tax_policy_free_ids.back();
        _cell_tax_policy_free_ids.pop_back();
        _cell_tax_policies[id] = policy;
        _cell_tax_policy_refcounts[id] = 1;
    } else {
        id = static_cast<uint32_t>(_cell_tax_policies.size());
        _cell_tax_policies.push_back(policy);
        _cell_tax_policy_refcounts.push_back(1);
    }
    candidates.push_back(id);
    return id;
}

void NativeCountryRuntime::release_cell_tax_policy(uint32_t policy_id) {
    if (policy_id == 0 || policy_id >= _cell_tax_policy_refcounts.size() ||
        _cell_tax_policy_refcounts[policy_id] == 0)
        return;
    if (--_cell_tax_policy_refcounts[policy_id] != 0) return;
    const uint64_t hash = cell_tax_policy_hash(_cell_tax_policies[policy_id]);
    const auto found = _cell_tax_policy_intern.find(hash);
    if (found != _cell_tax_policy_intern.end()) {
        auto &ids = found->second;
        ids.erase(std::remove(ids.begin(), ids.end(), policy_id), ids.end());
        if (ids.empty()) _cell_tax_policy_intern.erase(found);
    }
    _cell_tax_policies[policy_id] = CellTaxPolicy{};
    _cell_tax_policy_free_ids.push_back(policy_id);
}

void NativeCountryRuntime::rebuild_cell_tax_policy_intern() {
    _cell_tax_policy_intern.clear();
    _cell_tax_policy_free_ids.clear();
    if (_cell_tax_policies.empty()) _cell_tax_policies.emplace_back();
    _cell_tax_policy_refcounts.assign(_cell_tax_policies.size(), 0);
    for (uint32_t id : _cell_tax_policy_ids) {
        if (id > 0 && id < _cell_tax_policy_refcounts.size())
            ++_cell_tax_policy_refcounts[id];
    }
    for (uint32_t id = 1; id < _cell_tax_policies.size(); ++id) {
        if (_cell_tax_policy_refcounts[id] == 0) {
            _cell_tax_policies[id] = CellTaxPolicy{};
            _cell_tax_policy_free_ids.push_back(id);
            continue;
        }
        _cell_tax_policy_intern[cell_tax_policy_hash(_cell_tax_policies[id])]
            .push_back(id);
    }
}

const std::vector<std::string> &NativeCountryRuntime::tax_item_ids(
        int32_t kind) const {
    switch (kind) {
        case TAX_INCOME: return _profession_ids;
        case TAX_BUSINESS: return _building_type_ids;
        case TAX_CONSUMPTION:
        case TAX_IMPORT:
        case TAX_EXPORT: return _good_ids;
        default: {
            static const std::vector<std::string> empty;
            return empty;
        }
    }
}

int32_t NativeCountryRuntime::tax_item_index(
        int32_t kind, const std::string &stable_id) const {
    const auto &ids = tax_item_ids(kind);
    const auto found = std::find(ids.begin(), ids.end(), stable_id);
    return found == ids.end() ? -1 : static_cast<int32_t>(found - ids.begin());
}

void NativeCountryRuntime::initialize_country_research(int32_t slot) {
    const size_t countries = static_cast<size_t>(slot + 1);
    _country_discovered.resize(countries * _technology_words, 0);
    _country_pending_technologies.resize(countries * _technology_words, 0);
    _country_research_progress.resize(countries);
    _country_research_queues.resize(countries * 4U * 8U, -1);
    _country_research_queue_lengths.resize(countries * 4U, 0);
    _country_research_weights_bp.resize(countries * 4U, 2500);
    _country_research_auto_purchase.resize(countries, 1);
    _country_research_daily_budgets.resize(countries, 1000 * MONEY_SCALE);
    _country_research_deferred_points.resize(countries, 0);
    _country_research_purchased_total.resize(countries, 0);
    _country_research_consumed_total.resize(countries, 0);
    _country_research_progress_total.resize(countries, 0);
    _country_research_completed_total.resize(countries, 0);
    _country_research_signals.resize(countries * _research_signal_words, 0);
    _country_research_signal_cells.resize(countries);
    _country_research_signal_evidence.resize(countries);
}

void NativeCountryRuntime::rebuild_pending_activation_index() const {
    _pending_activation_indices.assign(_countries.active.size(), {});
    _pending_activation_count = 0;
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        if (_countries.active[static_cast<size_t>(slot)] == 0) continue;
        std::vector<int32_t> &pending =
            _pending_activation_indices[static_cast<size_t>(slot)];
        for (int32_t technology = 0;
             technology < static_cast<int32_t>(_technology_ids.size());
             ++technology) {
            const size_t word_index = static_cast<size_t>(slot) *
                _technology_words + technology / 64;
            const uint64_t bit = 1ULL << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) != 0)
                pending.push_back(technology);
        }
        _pending_activation_count += static_cast<int64_t>(pending.size());
    }
    _pending_activation_index_dirty = false;
    ++_research_queue_rebuilds;
}

bool NativeCountryRuntime::validate_pending_activation_index() const {
    if (_pending_activation_index_dirty ||
        _pending_activation_indices.size() != _countries.active.size() ||
        _technology_words <= 0 ||
        _country_pending_technologies.size() !=
            _countries.active.size() * static_cast<size_t>(_technology_words)) {
        return false;
    }
    int64_t counted = 0;
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        const auto &pending = _pending_activation_indices[static_cast<size_t>(slot)];
        if (_countries.active[static_cast<size_t>(slot)] == 0) {
            if (!pending.empty()) return false;
            continue;
        }
        int32_t previous = -1;
        for (const int32_t technology : pending) {
            if (technology <= previous || technology < 0 ||
                technology >= static_cast<int32_t>(_technology_ids.size())) {
                return false;
            }
            const size_t word_index = static_cast<size_t>(slot) *
                static_cast<size_t>(_technology_words) +
                static_cast<size_t>(technology / 64);
            const uint64_t bit = uint64_t{1} << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) == 0) return false;
            previous = technology;
        }
        int64_t bit_count = 0;
        const size_t word_base = static_cast<size_t>(slot) *
            static_cast<size_t>(_technology_words);
        for (int32_t word = 0; word < _technology_words; ++word) {
            uint64_t bits = _country_pending_technologies[word_base +
                static_cast<size_t>(word)];
            while (bits != 0) {
                bits &= bits - 1;
                ++bit_count;
            }
        }
        if (bit_count != static_cast<int64_t>(pending.size())) return false;
        counted += bit_count;
    }
    return counted == _pending_activation_count;
}

void NativeCountryRuntime::insert_pending_activation(
        int32_t slot, int32_t technology) {
    if (_pending_activation_index_dirty || slot < 0 || technology < 0 ||
        slot >= static_cast<int32_t>(_pending_activation_indices.size()))
        return;
    std::vector<int32_t> &pending =
        _pending_activation_indices[static_cast<size_t>(slot)];
    const auto position = std::lower_bound(
        pending.begin(), pending.end(), technology);
    if (position != pending.end() && *position == technology) return;
    pending.insert(position, technology);
    ++_pending_activation_count;
}

void NativeCountryRuntime::erase_pending_activation(
        int32_t slot, int32_t technology) {
    if (_pending_activation_index_dirty || slot < 0 || technology < 0 ||
        slot >= static_cast<int32_t>(_pending_activation_indices.size()))
        return;
    std::vector<int32_t> &pending =
        _pending_activation_indices[static_cast<size_t>(slot)];
    const auto position = std::lower_bound(
        pending.begin(), pending.end(), technology);
    if (position == pending.end() || *position != technology) return;
    pending.erase(position);
    --_pending_activation_count;
}

Dictionary NativeCountryRuntime::bootstrap(const Dictionary &packet,
                                            const PackedByteArray &is_water) {
    if (!_configured) return fail("country_not_configured");
    if (is_water.size() != _cell_count) return fail("country_water_mask_size_mismatch");
    _is_water.resize(static_cast<size_t>(_cell_count));
    if (_cell_count > 0) std::memcpy(_is_water.data(), is_water.ptr(), static_cast<size_t>(_cell_count));

    const std::vector<std::string> ids = packed_strings(packet, "country_ids");
    const std::vector<std::string> names = packed_strings(packet, "country_names");
    const std::vector<int64_t> cash = packed_i64(packet, "country_cash");
    const std::vector<int32_t> territory_offsets = packed_i32(packet, "territory_offsets");
    const std::vector<int32_t> territory_cells = packed_i32(packet, "territory_cells");
    const std::vector<int32_t> tech_offsets = packed_i32(packet, "technology_offsets");
    const std::vector<int32_t> tech_indices = packed_i32(packet, "technology_indices");
    const std::vector<int32_t> discovered_offsets =
        packed_i32(packet, "discovered_technology_offsets");
    const std::vector<int32_t> discovered_indices =
        packed_i32(packet, "discovered_technology_indices");
    const std::vector<int32_t> research_signal_offsets =
        packed_i32(packet, "research_signal_offsets");
    const std::vector<int32_t> research_signal_indices =
        packed_i32(packet, "research_signal_indices");
    const std::vector<int32_t> research_signal_cells =
        packed_i32(packet, "research_signal_cells");
    const std::vector<int64_t> research_signal_days =
        packed_i64(packet, "research_signal_days");
    const std::vector<int32_t> treasury_offsets = packed_i32(packet, "treasury_offsets");
    const std::vector<int32_t> treasury_good_indices = packed_i32(packet, "treasury_good_indices");
    const std::vector<int64_t> treasury_quantities = packed_i64(packet, "treasury_quantities");
    const std::vector<int32_t> research_weights =
        packed_i32(packet, "research_weights_bp");
    const std::vector<int64_t> research_budgets =
        packed_i64(packet, "research_daily_budgets");
    const std::vector<uint8_t> research_auto_purchase =
        packed_u8(packet, "research_auto_purchase");

    _countries = {};
    std::fill(_cell_country_slot.begin(), _cell_country_slot.end(), NEUTRAL_SLOT);
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
    _pending_activation_indices.clear();
    _pending_activation_index_dirty = true;
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _country_research_signals.clear();
    _country_research_signal_cells.clear();
    _country_research_signal_evidence.clear();
    _country_research_progress.clear();
    _country_research_queues.clear();
    _country_research_queue_lengths.clear();
    _country_research_weights_bp.clear();
    _country_research_auto_purchase.clear();
    _country_research_daily_budgets.clear();
    _country_research_deferred_points.clear();
    _country_research_purchased_total.clear();
    _country_research_consumed_total.clear();
    _country_research_progress_total.clear();
    _country_research_completed_total.clear();
    _country_tax_defaults.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _tax_policy_version = 0;
    _cell_tax_policy_ids.assign(static_cast<size_t>(_cell_count), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _last_research_day = -1;
    _pending_commands.clear();
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _next_effect_request_id = 1;
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};

    if (ids.empty()) {
        int32_t land_count = 0;
        for (uint8_t water : _is_water) if (water == 0) ++land_count;
        if (land_count == 0) return fail("country_bootstrap_no_land");
        const int32_t slot = append_country("country.default", "默认国家", 0);
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            if (_is_water[static_cast<size_t>(cell)] != 0) continue;
            _cell_country_slot[static_cast<size_t>(cell)] = slot;
            ++_countries.territory_count[static_cast<size_t>(slot)];
        }
        for (int32_t tech : _starting_technologies)
            _country_technologies[static_cast<size_t>(slot) * _technology_words + tech / 64] |= 1ULL << (tech % 64);
        _starting_country_slot = slot;
    } else {
        if (names.size() != ids.size() || (!cash.empty() && cash.size() != ids.size()) ||
            territory_offsets.size() != ids.size() + 1 || territory_offsets.front() != 0 ||
            territory_offsets.back() != static_cast<int32_t>(territory_cells.size()))
            return fail("country_bootstrap_shape_invalid");
        if ((!tech_offsets.empty() && (tech_offsets.size() != ids.size() + 1 || tech_offsets.front() != 0 ||
             tech_offsets.back() != static_cast<int32_t>(tech_indices.size()))) ||
            (!discovered_offsets.empty() && (discovered_offsets.size() != ids.size() + 1 ||
             discovered_offsets.front() != 0 ||
             discovered_offsets.back() != static_cast<int32_t>(discovered_indices.size()))) ||
            (!research_signal_offsets.empty() &&
             (research_signal_offsets.size() != ids.size() + 1 || research_signal_offsets.front() != 0 ||
              research_signal_offsets.back() != static_cast<int32_t>(research_signal_indices.size()) ||
              research_signal_indices.size() != research_signal_cells.size() ||
              research_signal_indices.size() != research_signal_days.size())) ||
            (!treasury_offsets.empty() && (treasury_offsets.size() != ids.size() + 1 || treasury_offsets.front() != 0 ||
             treasury_offsets.back() != static_cast<int32_t>(treasury_good_indices.size()) ||
             treasury_good_indices.size() != treasury_quantities.size())))
            return fail("country_bootstrap_csr_invalid");
        if ((!research_weights.empty() && research_weights.size() != ids.size() * 4U) ||
            (!research_budgets.empty() && research_budgets.size() != ids.size()) ||
            (!research_auto_purchase.empty() &&
             research_auto_purchase.size() != ids.size()))
            return fail("country_bootstrap_research_shape_invalid");

        std::unordered_set<std::string> stable_ids;
        for (size_t i = 0; i < ids.size(); ++i) {
            if (ids[i].empty() || names[i].empty() || !stable_ids.insert(ids[i]).second)
                return fail("country_bootstrap_identity_invalid");
            if (territory_offsets[i] == territory_offsets[i + 1]) return fail("country_bootstrap_zero_territory");
            append_country(ids[i], names[i], cash.empty() ? 0 : cash[i]);
        }
        for (size_t slot = 0; slot < ids.size(); ++slot) {
            for (int32_t edge = territory_offsets[slot]; edge < territory_offsets[slot + 1]; ++edge) {
                const int32_t cell = territory_cells[static_cast<size_t>(edge)];
                if (cell < 0 || cell >= _cell_count) return fail("country_bootstrap_cell_invalid");
                if (_is_water[static_cast<size_t>(cell)] != 0) return fail("country_bootstrap_water_owned");
                if (_cell_country_slot[static_cast<size_t>(cell)] != NEUTRAL_SLOT)
                    return fail("country_bootstrap_duplicate_territory");
                _cell_country_slot[static_cast<size_t>(cell)] = static_cast<int32_t>(slot);
                ++_countries.territory_count[slot];
            }
            if (tech_offsets.empty()) {
                for (int32_t tech : _starting_technologies)
                    _country_technologies[slot * _technology_words + tech / 64] |= 1ULL << (tech % 64);
            } else {
                for (int32_t edge = tech_offsets[slot]; edge < tech_offsets[slot + 1]; ++edge) {
                    const int32_t tech = tech_indices[static_cast<size_t>(edge)];
                    if (tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size()))
                        return fail("country_bootstrap_technology_invalid");
                    _country_technologies[slot * _technology_words + tech / 64] |= 1ULL << (tech % 64);
                }
            }
            if (!discovered_offsets.empty()) {
                for (int32_t edge = discovered_offsets[slot];
                     edge < discovered_offsets[slot + 1]; ++edge) {
                    const int32_t tech = discovered_indices[static_cast<size_t>(edge)];
                    if (tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size()))
                        return fail("country_bootstrap_discovered_technology_invalid");
                    _country_discovered[slot * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
                }
            }
            if (!treasury_offsets.empty()) {
                for (int32_t edge = treasury_offsets[slot]; edge < treasury_offsets[slot + 1]; ++edge) {
                    const int32_t good = treasury_good_indices[static_cast<size_t>(edge)];
                    const int64_t quantity = treasury_quantities[static_cast<size_t>(edge)];
                    if (good < 0 || good >= static_cast<int32_t>(_good_ids.size()) || quantity < 0)
                        return fail("country_bootstrap_treasury_invalid");
                    _country_goods[slot * _good_ids.size() + good] = quantity;
                }
            }
            if (!research_weights.empty()) {
                int32_t total = 0;
                for (int32_t domain = 0; domain < 4; ++domain) {
                    const int32_t weight = research_weights[slot * 4U + domain];
                    if (weight < 0 || weight > 10000)
                        return fail("country_bootstrap_research_policy_invalid");
                    _country_research_weights_bp[slot * 4U + domain] = weight;
                    total += weight;
                }
                if (total != 10000)
                    return fail("country_bootstrap_research_policy_invalid");
            }
            if (!research_budgets.empty()) {
                if (research_budgets[slot] < 0)
                    return fail("country_bootstrap_research_policy_invalid");
                _country_research_daily_budgets[slot] = research_budgets[slot];
            }
            if (!research_auto_purchase.empty()) {
                if (research_auto_purchase[slot] > 1)
                    return fail("country_bootstrap_research_policy_invalid");
                _country_research_auto_purchase[slot] =
                    research_auto_purchase[slot];
            }
            if (!research_signal_offsets.empty()) {
                std::vector<uint64_t> &observed_cells =
                    _country_research_signal_cells[slot];
                std::vector<SignalEvidence> &evidence =
                    _country_research_signal_evidence[slot];
                for (int32_t edge = research_signal_offsets[slot];
                     edge < research_signal_offsets[slot + 1]; ++edge) {
                    const int32_t signal = research_signal_indices[static_cast<size_t>(edge)];
                    const int32_t cell = research_signal_cells[static_cast<size_t>(edge)];
                    const int64_t day = research_signal_days[static_cast<size_t>(edge)];
                    if (signal < 0 || signal >= static_cast<int32_t>(_research_signal_ids.size()) ||
                        cell < 0 || cell >= _cell_count || day < 0)
                        return fail("country_bootstrap_research_signal_invalid");
                    const uint64_t observation_key =
                        (static_cast<uint64_t>(static_cast<uint32_t>(signal)) << 32U) |
                        static_cast<uint32_t>(cell);
                    auto observed_it = std::lower_bound(
                        observed_cells.begin(), observed_cells.end(), observation_key);
                    if (observed_it != observed_cells.end() && *observed_it == observation_key)
                        continue;
                    observed_cells.insert(observed_it, observation_key);
                    if (_research_signal_words > 0) {
                        _country_research_signals[slot * static_cast<size_t>(_research_signal_words) +
                                                   static_cast<size_t>(signal / 64)] |=
                            uint64_t{1} << (signal % 64);
                    }
                    auto evidence_it = std::lower_bound(
                        evidence.begin(), evidence.end(), signal,
                        [](const SignalEvidence &entry, int32_t needle) {
                            return entry.signal < needle;
                        });
                    if (evidence_it == evidence.end() || evidence_it->signal != signal) {
                        SignalEvidence entry;
                        entry.signal = signal;
                        entry.count = 0;
                        entry.first_day = day;
                        entry.last_day = day;
                        entry.first_cell = cell;
                        evidence_it = evidence.insert(evidence_it, entry);
                    }
                    ++evidence_it->count;
                    evidence_it->first_day = std::min(evidence_it->first_day, day);
                    evidence_it->last_day = std::max(evidence_it->last_day, day);
                    if (evidence_it->first_cell < 0 || cell < evidence_it->first_cell)
                        evidence_it->first_cell = cell;
                }
            }
        }
        _starting_country_slot = 0;
    }

    for (int32_t slot = 0; slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
            if (has_technology(slot, tech))
                _country_discovered[static_cast<size_t>(slot) * _technology_words + tech / 64] |=
                    1ULL << (tech % 64);
        }
        refresh_discovery(slot);
    }

    rebuild_cell_csr();
    _generation = 1;
    _pending_activation_index_dirty = true;
    if (_effect_runtime_enabled && _effect_runtime != nullptr) {
        for (int32_t slot = 0; slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
            const uint64_t handle = make_handle(slot);
            for (int32_t technology = 0;
                 technology < static_cast<int32_t>(_technology_ids.size()); ++technology) {
                if (!has_technology(slot, technology) ||
                    _technology_modifier_definition_keys[static_cast<size_t>(technology)].empty())
                    continue;
                std::string effect_error;
                _effect_runtime->upsert_instance_pod(
                    static_cast<int64_t>(((handle & 0x00007fffffffffffULL) << 16U) |
                        static_cast<uint64_t>(technology + 1)),
                    std::string("technology.") + _technology_ids[static_cast<size_t>(technology)],
                    static_cast<uint32_t>(handle >> 32U), 0x54454348, technology + 1,
                    handle, handle, static_cast<uint32_t>(handle >> 32U), 0,
                    0, true, effect_error);
            }
        }
    }
    _bootstrapped = true;
    _last_committed_day = -1;
    _last_research_day = -1;
    publish_report("aggregate_publish", -1, 0, 0, 0, _cell_count,
                   static_cast<int32_t>(_countries.active.size()), _mode == MODE_ACTIVE);
    Dictionary out = report();
    out["ok"] = true;
    out["default_bootstrap"] = ids.empty();
    return out;
}

Dictionary NativeCountryRuntime::submit_commands(const Dictionary &batch) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    if (_mode == MODE_OFF) return fail("country_runtime_off");
    const std::vector<int32_t> opcodes = packed_i32(batch, "opcodes");
    const std::vector<int64_t> days = packed_i64(batch, "effective_days");
    const std::vector<int64_t> sequences = packed_i64(batch, "sequences");
    const std::vector<int64_t> handles = packed_i64(batch, "target_handles");
    const std::vector<int32_t> cells = packed_i32(batch, "cell_indices");
    const std::vector<int32_t> aux = packed_i32(batch, "aux_i32");
    const std::vector<int32_t> domains = packed_i32(batch, "domain_i32");
    const std::vector<int32_t> positions = packed_i32(batch, "position_i32");
    const std::vector<int32_t> weights0 = packed_i32(batch, "weight0_bp");
    const std::vector<int32_t> weights1 = packed_i32(batch, "weight1_bp");
    const std::vector<int32_t> weights2 = packed_i32(batch, "weight2_bp");
    const std::vector<int32_t> weights3 = packed_i32(batch, "weight3_bp");
    const std::vector<int64_t> values = packed_i64(batch, "value_i64");
    std::vector<int32_t> tax_kinds = packed_i32(batch, "tax_kinds");
    std::vector<int32_t> tax_items = packed_i32(batch, "tax_item_indices");
    std::vector<int32_t> tax_rates = packed_i32(batch, "tax_rate_percent");
    const std::vector<std::string> stable_ids = packed_strings(batch, "stable_ids");
    const std::vector<std::string> display_names = packed_strings(batch, "display_names");
    const size_t count = opcodes.size();
    if (count == 0) return fail("country_command_batch_empty");
    if (tax_kinds.empty()) tax_kinds.assign(count, -1);
    if (tax_items.empty()) tax_items.assign(count, -1);
    if (tax_rates.empty()) tax_rates.assign(count, 0);
    if (days.size() != count || sequences.size() != count || handles.size() != count ||
        cells.size() != count || aux.size() != count || domains.size() != count ||
        positions.size() != count || weights0.size() != count || weights1.size() != count ||
        weights2.size() != count || weights3.size() != count || values.size() != count ||
        tax_kinds.size() != count || tax_items.size() != count ||
        tax_rates.size() != count || stable_ids.size() != count ||
        display_names.size() != count)
        return fail("country_command_batch_shape_invalid");
    _pending_commands.reserve(_pending_commands.size() + count);
    for (size_t i = 0; i < count; ++i) {
        if (opcodes[i] < COMMAND_CREATE_COUNTRY ||
            opcodes[i] > COMMAND_CLAIM_UNOWNED_TERRITORY)
            return fail("country_command_opcode_invalid");
        if (days[i] < 0 || sequences[i] < 0) return fail("country_command_order_invalid");
        Command command;
        command.opcode = opcodes[i];
        command.effective_day = days[i];
        command.sequence = sequences[i];
        command.target_handle = static_cast<uint64_t>(handles[i]);
        command.cell = cells[i];
        command.aux = aux[i];
        command.domain = domains[i];
        command.position = positions[i];
        command.weights_bp[0] = weights0[i];
        command.weights_bp[1] = weights1[i];
        command.weights_bp[2] = weights2[i];
        command.weights_bp[3] = weights3[i];
        command.tax_kind = tax_kinds[i];
        command.tax_item = tax_items[i];
        command.tax_rate_percent = tax_rates[i];
        if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
            command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
            if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
                command.tax_rate_percent < -100 ||
                command.tax_rate_percent > 100 ||
                (command.opcode != COMMAND_SET_TAX_DEFAULT &&
                 (command.tax_item < 0 ||
                  command.tax_item >= tax_item_count(command.tax_kind)))) {
                return fail("country_tax_command_invalid");
            }
        }
        if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
            command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
            const bool has_kind =
                command.opcode != COMMAND_CLEAR_CELL_TAX_POLICY;
            const bool has_item =
                command.opcode == COMMAND_SET_CELL_TAX_OVERRIDE ||
                command.opcode == COMMAND_CLEAR_CELL_TAX_OVERRIDE;
            const bool has_rate =
                command.opcode == COMMAND_SET_CELL_TAX_DEFAULT ||
                command.opcode == COMMAND_SET_CELL_TAX_OVERRIDE;
            if (command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                (has_kind && (command.tax_kind < 0 ||
                              command.tax_kind >= TAX_KIND_COUNT)) ||
                (has_item && (command.tax_item < 0 ||
                              command.tax_item >=
                                  tax_item_count(command.tax_kind))) ||
                (has_rate && (command.tax_rate_percent < -100 ||
                              command.tax_rate_percent > 100))) {
                return fail("country_cell_tax_command_invalid");
            }
        }
        if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY &&
            (command.cell < 0 || command.cell >= _cell_count ||
             _is_water[static_cast<size_t>(command.cell)] != 0))
            return fail("country_claim_target_invalid");
        command.value = values[i];
        command.stable_id = stable_ids[i];
        command.display_name = display_names[i];
        command.submit_order = ++_submit_order;
        _pending_commands.push_back(std::move(command));
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted"] = static_cast<int64_t>(count);
    out["pending"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeCountryRuntime::submit_effect_commands_pod(
        const EffectCommand *commands, size_t count, std::vector<int64_t> &request_ids,
        std::string &error) {
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_runtime_unavailable";
        return false;
    }
    if (commands == nullptr || count == 0) { error = "country_effect_command_empty"; return false; }
    request_ids.clear();
    request_ids.reserve(count);
    std::vector<Command> staged;
    staged.reserve(count);
    auto lo_i32 = [](int64_t value) { return static_cast<int32_t>(static_cast<uint32_t>(value)); };
    auto hi_i32 = [](int64_t value) { return static_cast<int32_t>(static_cast<uint64_t>(value) >> 32U); };
    auto u16 = [](int64_t value, int32_t shift) {
        return static_cast<int32_t>((static_cast<uint64_t>(value) >> shift) & 0xffffULL);
    };
    for (size_t i = 0; i < count; ++i) {
        const EffectCommand &source = commands[i];
        if (source.opcode < COMMAND_CREATE_COUNTRY || source.opcode > COMMAND_CLAIM_UNOWNED_TERRITORY ||
            source.effective_day < 0 || source.sequence < 0 || source.idempotency_key == 0) {
            error = "country_effect_command_invalid";
            return false;
        }
        const auto duplicate = _effect_command_idempotency.find(source.idempotency_key);
        if (duplicate != _effect_command_idempotency.end()) {
            request_ids.push_back(duplicate->second);
            continue;
        }
        if (source.opcode != COMMAND_CREATE_COUNTRY && source.target_handle != 0 &&
            static_cast<uint32_t>(source.target_handle >> 32U) != source.target_generation) {
            error = "country_effect_target_generation_invalid";
            return false;
        }
        Command command;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = source.sequence;
        command.target_handle = source.target_handle;
        command.cell = lo_i32(source.payload[0]);
        command.aux = hi_i32(source.payload[0]);
        command.domain = lo_i32(source.payload[1]);
        command.position = hi_i32(source.payload[1]);
        command.weights_bp[0] = u16(source.payload[2], 0);
        command.weights_bp[1] = u16(source.payload[2], 16);
        command.weights_bp[2] = u16(source.payload[2], 32);
        command.weights_bp[3] = u16(source.payload[2], 48);
        command.tax_kind = lo_i32(source.payload[3]);
        command.tax_item = static_cast<int32_t>(static_cast<int16_t>(u16(source.payload[3], 32)));
        command.tax_rate_percent = static_cast<int32_t>(static_cast<int16_t>(u16(source.payload[3], 48)));
        command.value = source.value;
        command.stable_id = source.stable_id == nullptr ? "" : source.stable_id;
        command.display_name = source.display_name == nullptr ? "" : source.display_name;
        command.submit_order = ++_submit_order;
        command.effect_request_id = _next_effect_request_id++;
        command.effect_idempotency_key = source.idempotency_key;
        _effect_command_results.emplace(command.effect_request_id, EffectCommandResult{});
        _effect_command_idempotency[source.idempotency_key] = command.effect_request_id;
        request_ids.push_back(command.effect_request_id);
        staged.push_back(std::move(command));
    }
    _pending_commands.insert(_pending_commands.end(),
        std::make_move_iterator(staged.begin()), std::make_move_iterator(staged.end()));
    return true;
}

bool NativeCountryRuntime::effect_command_result_pod(int64_t request_id, bool &complete,
        bool &ok, std::string &reason) const {
    const auto found = _effect_command_results.find(request_id);
    if (found == _effect_command_results.end()) {
        complete = true; ok = false; reason = "country_effect_request_unknown"; return false;
    }
    complete = found->second.complete != 0;
    ok = found->second.ok != 0;
    reason = found->second.reason;
    return true;
}

bool NativeCountryRuntime::has_pending_effect_commands() const {
    for (const auto &entry : _effect_command_results)
        if (entry.second.complete == 0) return true;
    return false;
}

bool NativeCountryRuntime::should_run(int64_t day_index) const {
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) return false;
    if (_command_batch.active) return true;
    // Trigger/Effect often enqueue DISCOVER with effective_day = event.day + 1.
    // Incomplete effect results for those future commands must not pin today;
    // the due-command scan below already covers same-day Effect work, and an
    // in-flight batch is handled by _command_batch.active.
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    if (_technology_points_good_id >= 0) {
        if (_pending_queue_enabled) {
            if (_pending_activation_index_dirty) rebuild_pending_activation_index();
            if (_pending_activation_count > 0) return true;
        } else {
            for (uint64_t word : _country_pending_technologies)
                if (word != 0) return true;
        }
        for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
            if (_countries.active[slot] == 0) continue;
            // A completion can be left at the queue head when the final
            // research point was consumed before the completion sweep. Keep
            // the same-day country continuation alive so it can finalize the
            // head without waiting for another enqueue command or calendar day.
            for (int32_t domain = 0; domain < 4; ++domain) {
                const size_t length_index = slot * 4U +
                    static_cast<size_t>(domain);
                if (_country_research_queue_lengths[length_index] == 0) continue;
                const size_t queue_base = length_index * 8U;
                const int32_t technology = _country_research_queues[queue_base];
                if (technology >= 0 && !has_technology(static_cast<int32_t>(slot), technology) &&
                    progress_for(static_cast<int32_t>(slot), technology) >=
                        effective_research_cost(static_cast<int32_t>(slot), technology))
                    return true;
            }
            if (day_index <= _last_research_day) continue;
            const int64_t stock = _country_goods[
                slot * _good_ids.size() + static_cast<size_t>(_technology_points_good_id)];
            if (stock <= _country_research_deferred_points[slot]) continue;
            const size_t queue_base = slot * 4U;
            for (int32_t domain = 0; domain < 4; ++domain) {
                if (_country_research_queue_lengths[
                        queue_base + static_cast<size_t>(domain)] != 0)
                    return true;
            }
        }
    }
    return false;
}

bool NativeCountryRuntime::validate_handle(uint64_t handle, int32_t &slot) const {
    slot = static_cast<int32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return slot >= 0 && slot < static_cast<int32_t>(_countries.active.size()) &&
           _countries.active[static_cast<size_t>(slot)] != 0 &&
           _countries.generation[static_cast<size_t>(slot)] == generation;
}

uint64_t NativeCountryRuntime::make_handle(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return 0;
    return (static_cast<uint64_t>(_countries.generation[static_cast<size_t>(slot)]) << 32U) |
           static_cast<uint32_t>(slot);
}

Dictionary NativeCountryRuntime::run_slice(const Dictionary &ctx) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    const int64_t requested_day = dict_num<int64_t>(ctx, "day_index", 0);
    if (_mode == MODE_OFF) {
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["stage"] = "idle";
        out["path"] = "off";
        return out;
    }

    // A slice may commit commands, research progress, goods, territory, or
    // signal evidence. Invalidate the transient hash cache at the slice
    // boundary; the generation/research/tax keys still avoid repeated scans
    // between reports and bridge queries in the same committed state.
    _state_hash_cache_valid = false;

    const Clock::time_point start = Clock::now();
    if (!_command_batch.active) {
        const bool all_due = std::all_of(_pending_commands.begin(), _pending_commands.end(),
            [&](const Command &command) { return command.effective_day <= requested_day; });
        if (all_due) {
            _command_batch.commands.swap(_pending_commands);
        } else {
            std::vector<Command> future_commands;
            _command_batch.commands.reserve(_pending_commands.size());
            future_commands.reserve(_pending_commands.size());
            for (Command &command : _pending_commands) {
                if (command.effective_day <= requested_day)
                    _command_batch.commands.push_back(std::move(command));
                else
                    future_commands.push_back(std::move(command));
            }
            _pending_commands.swap(future_commands);
        }
        if (_command_batch.commands.empty()) {
            const int32_t research_changed = run_research_day(requested_day);
            _last_committed_day = std::max(_last_committed_day, requested_day);
            publish_report(research_changed > 0 ? "research_publish" : "idle",
                           requested_day, 0, 0, elapsed_ms(start), 0,
                           research_changed, _mode == MODE_ACTIVE);
            Dictionary out = report();
            out["ok"] = true;
            out["done"] = true;
            out["stage"] = research_changed > 0 ? "research_publish" : "idle";
            out["elapsed_ms"] = elapsed_ms(start);
            // Research completion registers Effect instances after the morning
            // Effect slot. Raise the barrier so the continuation drain can ACK
            // before the next country day; country should_run is already false
            // because _last_research_day == requested_day.
            if (ack_chain_due(requested_day))
                out["country_day_barrier"] = true;
            return out;
        }
        const auto command_less = [](const Command &lhs, const Command &rhs) {
            if (lhs.effective_day != rhs.effective_day)
                return lhs.effective_day < rhs.effective_day;
            if (lhs.sequence != rhs.sequence) return lhs.sequence < rhs.sequence;
            return lhs.submit_order < rhs.submit_order;
        };
        if (!std::is_sorted(_command_batch.commands.begin(), _command_batch.commands.end(),
                            command_less))
            std::sort(_command_batch.commands.begin(), _command_batch.commands.end(), command_less);
        _command_batch.active = true;
        _command_batch.day = requested_day;
        _command_batch.cursor = 0;
        _command_batch.preflight_ms = 0.0;
        _command_batch.countries = _countries;
        _command_batch.direct_unique_territory = !_command_batch.commands.empty();
        int32_t previous_cell = -1;
        for (const Command &command : _command_batch.commands) {
            if (command.opcode == COMMAND_CREATE_COUNTRY) {
                _command_batch.stage_technologies = true;
                _command_batch.stage_goods = true;
                _command_batch.stage_research = true;
                _command_batch.stage_signals = true;
                _command_batch.stage_tax = true;
            } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
                _command_batch.stage_technologies = true;
                _command_batch.stage_research = true;
            } else if (command.opcode >= COMMAND_SET_RESEARCH_WEIGHTS &&
                       command.opcode <= COMMAND_REVEAL_ALL_TECHNOLOGIES) {
                _command_batch.stage_research = true;
                _command_batch.stage_technologies = true;
            } else if (command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL) {
                _command_batch.stage_signals = true;
                _command_batch.stage_research = true;
            } else if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
                       command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
                _command_batch.stage_tax = true;
                _command_batch.stage_cell_tax = true;
            } else if (command.opcode == COMMAND_TRANSFER_TERRITORY ||
                       command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) {
                _command_batch.stage_cell_tax = true;
            } else if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
                       command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
                _command_batch.stage_cell_tax = true;
            }
            if ((command.opcode != COMMAND_TRANSFER_TERRITORY &&
                 command.opcode != COMMAND_CLAIM_UNOWNED_TERRITORY) ||
                command.cell <= previous_cell) {
                _command_batch.direct_unique_territory = false;
            } else {
                previous_cell = command.cell;
            }
        }
        if (_command_batch.stage_technologies)
            _command_batch.technologies = _country_technologies;
        if (_command_batch.stage_goods)
            _command_batch.goods = _country_goods;
        if (_command_batch.stage_research) {
            _command_batch.discovered = _country_discovered;
            _command_batch.pending = _country_pending_technologies;
            _command_batch.progress = _country_research_progress;
            _command_batch.research_queues = _country_research_queues;
            _command_batch.research_queue_lengths = _country_research_queue_lengths;
            _command_batch.research_weights_bp = _country_research_weights_bp;
            _command_batch.research_auto_purchase = _country_research_auto_purchase;
            _command_batch.research_daily_budgets = _country_research_daily_budgets;
            _command_batch.research_deferred_points = _country_research_deferred_points;
        }
        if (_command_batch.stage_research || _command_batch.stage_signals) {
            _command_batch.signals = _country_research_signals;
            _command_batch.signal_evidence = _country_research_signal_evidence;
        }
        if (_command_batch.stage_signals)
            _command_batch.signal_cells = _country_research_signal_cells;
        if (_command_batch.stage_tax) {
            _command_batch.tax_defaults = _country_tax_defaults;
            _command_batch.income_tax_overrides =
                _country_income_tax_overrides;
            _command_batch.consumption_tax_overrides =
                _country_consumption_tax_overrides;
            _command_batch.business_tax_overrides =
                _country_business_tax_overrides;
            _command_batch.import_tax_overrides =
                _country_import_tax_overrides;
            _command_batch.export_tax_overrides =
                _country_export_tax_overrides;
        }
        if (_command_batch.stage_cell_tax)
            _command_batch.cell_tax_updates.reserve(
                std::min(_command_batch.commands.size(),
                         static_cast<size_t>(_cell_count)));
        if (!_command_batch.direct_unique_territory)
            _command_batch.cell_delta.reserve(_command_batch.commands.size());
        _command_batch.cell_delta_order.reserve(_command_batch.commands.size());
        if (_command_batch.direct_unique_territory)
            _command_batch.direct_cell_owners.reserve(_command_batch.commands.size());
        // The public ring is capped at 2048 entries. Reserving one Event per
        // territory command made a 100k-cell transfer allocate several MiB of
        // unused string-bearing records on the hot path.
        _command_batch.events.reserve(std::min<size_t>(_command_batch.commands.size(), 2048));
        _command_batch.changed_countries.assign(_countries.active.size(), 0);
    }

    CommandBatchState &batch = _command_batch;
    const int64_t day = batch.day;
    const size_t cursor_start = batch.cursor;
    size_t cursor_limit = std::min(batch.commands.size(),
        batch.cursor + static_cast<size_t>(_max_commands_per_slice));
    std::string error;

    auto staged_handle = [&](uint64_t handle, int32_t &slot) -> bool {
        slot = static_cast<int32_t>(handle & 0xffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
        return slot >= 0 && slot < static_cast<int32_t>(batch.countries.active.size()) &&
               batch.countries.active[static_cast<size_t>(slot)] != 0 &&
               batch.countries.generation[static_cast<size_t>(slot)] == generation;
    };
    auto owner_of = [&](int32_t cell) -> int32_t {
        int32_t owner = NEUTRAL_SLOT;
        return batch.cell_delta.get(cell, owner)
            ? owner : _cell_country_slot[static_cast<size_t>(cell)];
    };
    auto mark_country = [&](int32_t slot) {
        if (slot < 0) return;
        if (slot >= static_cast<int32_t>(batch.changed_countries.size()))
            batch.changed_countries.resize(static_cast<size_t>(slot + 1), 0);
        batch.changed_countries[static_cast<size_t>(slot)] = 1;
    };
    auto staged_cell_policy = [&](int32_t cell) -> CellTaxPolicy & {
        auto [it, inserted] = batch.cell_tax_updates.try_emplace(cell);
        if (inserted) {
            const uint32_t policy_id =
                _cell_tax_policy_ids[static_cast<size_t>(cell)];
            it->second = cell_tax_policy(policy_id);
        }
        return it->second;
    };

    // Observation-only ingress is commutative. Validate the complete batch,
    // sort/unique once, then linearly merge with the authoritative ordered
    // evidence vector. This avoids O(n^2) shifts during large visibility
    // backfills while preserving the same atomic command boundary.
    const bool observation_only = batch.cursor == 0 && !batch.commands.empty() &&
        std::all_of(batch.commands.begin(), batch.commands.end(), [](const Command &command) {
            return command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL;
        });
    if (observation_only) {
        struct Observation { int32_t slot; uint64_t key; uint64_t handle; int32_t source; };
        std::vector<Observation> incoming;
        incoming.reserve(batch.commands.size());
        for (const Command &command : batch.commands) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_research_signal_ids.size()) ||
                command.cell < 0 || command.cell >= _cell_count) {
                error = "country_research_signal_command_invalid";
                break;
            }
            incoming.push_back(Observation{
                slot,
                (uint64_t(uint32_t(command.aux)) << 32U) | uint32_t(command.cell),
                command.target_handle,
                int32_t(command.value)});
        }
        if (error.empty()) {
            std::sort(incoming.begin(), incoming.end(), [](const Observation &a,
                                                           const Observation &b) {
                if (a.slot != b.slot) return a.slot < b.slot;
                return a.key < b.key;
            });
            incoming.erase(std::unique(incoming.begin(), incoming.end(),
                [](const Observation &a, const Observation &b) {
                    return a.slot == b.slot && a.key == b.key;
                }), incoming.end());
            batch.observation_batch_input = static_cast<int64_t>(batch.commands.size());
            size_t begin = 0;
            while (begin < incoming.size()) {
                size_t end = begin + 1;
                while (end < incoming.size() && incoming[end].slot == incoming[begin].slot) ++end;
                const int32_t slot = incoming[begin].slot;
                std::vector<uint64_t> unique_keys;
                unique_keys.reserve(end - begin);
                for (size_t i = begin; i < end; ++i) unique_keys.push_back(incoming[i].key);
                std::vector<uint64_t> &existing = batch.signal_cells[size_t(slot)];
                std::vector<uint64_t> added;
                added.reserve(unique_keys.size());
                std::set_difference(unique_keys.begin(), unique_keys.end(),
                    existing.begin(), existing.end(), std::back_inserter(added));
                if (!added.empty()) {
                    std::vector<uint64_t> merged;
                    merged.reserve(existing.size() + added.size());
                    std::set_union(existing.begin(), existing.end(),
                        unique_keys.begin(), unique_keys.end(), std::back_inserter(merged));
                    existing.swap(merged);
                    batch.observation_batch_added += static_cast<int64_t>(added.size());
                    batch.countries.state_version[size_t(slot)] += added.size();
                    mark_country(slot);
                    size_t added_begin = 0;
                    while (added_begin < added.size()) {
                        const int32_t signal = int32_t(added[added_begin] >> 32U);
                        size_t added_end = added_begin + 1;
                        while (added_end < added.size() &&
                               int32_t(added[added_end] >> 32U) == signal) ++added_end;
                        const int32_t delta = int32_t(added_end - added_begin);
                        const int32_t first_cell = int32_t(added[added_begin] & 0xffffffffU);
                        if (_research_signal_words > 0)
                            batch.signals[size_t(slot) * _research_signal_words + signal / 64] |=
                                uint64_t{1} << (signal % 64);
                        std::vector<SignalEvidence> &evidence = batch.signal_evidence[size_t(slot)];
                        auto evidence_it = std::lower_bound(evidence.begin(), evidence.end(), signal,
                            [](const SignalEvidence &entry, int32_t value) {
                                return entry.signal < value;
                            });
                        if (evidence_it == evidence.end() || evidence_it->signal != signal) {
                            SignalEvidence entry;
                            entry.signal = signal;
                            entry.first_day = day;
                            entry.first_cell = first_cell;
                            evidence_it = evidence.insert(evidence_it, entry);
                        }
                        evidence_it->count += delta;
                        evidence_it->last_day = day;
                        Event event;
                        event.day = day;
                        event.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL;
                        event.country_handle = incoming[begin].handle;
                        event.cell = first_cell;
                        event.new_country_slot = slot;
                        event.signal_id = signal;
                        event.signal_source_kind = incoming[begin].source;
                        event.evidence_delta = delta;
                        batch.events.push_back(std::move(event));
                        added_begin = added_end;
                    }
                }
                begin = end;
            }
            batch.cursor = batch.commands.size();
            cursor_limit = batch.commands.size();
        }
    }
    if (!error.empty()) batch.cursor = cursor_limit;

    for (; batch.cursor < cursor_limit; ++batch.cursor) {
        const Command &command = batch.commands[batch.cursor];
        uint64_t event_country_handle = 0;
        int32_t event_old_country_slot = NEUTRAL_SLOT;
        int32_t event_new_country_slot = NEUTRAL_SLOT;

        if (command.opcode == COMMAND_CREATE_COUNTRY) {
            if (command.stable_id.empty() || command.display_name.empty() ||
                std::find(batch.countries.stable_id.begin(), batch.countries.stable_id.end(),
                          command.stable_id) != batch.countries.stable_id.end()) {
                error = "country_create_identity_invalid"; break;
            }
            if (command.cell < 0 || command.cell >= _cell_count || _is_water[static_cast<size_t>(command.cell)] != 0) {
                error = "country_create_territory_invalid"; break;
            }
            const int32_t old_owner = batch.direct_unique_territory
                ? _cell_country_slot[static_cast<size_t>(command.cell)]
                : owner_of(command.cell);
            const int32_t new_slot = static_cast<int32_t>(batch.countries.active.size());
            batch.countries.active.push_back(1);
            batch.countries.generation.push_back(1);
            batch.countries.stable_id.push_back(command.stable_id);
            batch.countries.display_name.push_back(command.display_name);
            batch.countries.territory_count.push_back(1);
            batch.countries.cash.push_back(0);
            batch.countries.state_version.push_back(1);
            batch.technologies.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.goods.resize(static_cast<size_t>(new_slot + 1) * _good_ids.size(), 0);
            batch.discovered.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.pending.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.progress.resize(static_cast<size_t>(new_slot + 1));
            batch.research_queues.resize(static_cast<size_t>(new_slot + 1) * 32U, -1);
            batch.research_queue_lengths.resize(static_cast<size_t>(new_slot + 1) * 4U, 0);
            batch.research_weights_bp.resize(static_cast<size_t>(new_slot + 1) * 4U, 2500);
            batch.research_auto_purchase.resize(static_cast<size_t>(new_slot + 1), 1);
            batch.research_daily_budgets.resize(static_cast<size_t>(new_slot + 1),
                                                1000 * MONEY_SCALE);
            batch.research_deferred_points.resize(static_cast<size_t>(new_slot + 1), 0);
            batch.signals.resize(static_cast<size_t>(new_slot + 1) * _research_signal_words, 0);
            batch.signal_cells.resize(static_cast<size_t>(new_slot + 1));
            batch.signal_evidence.resize(static_cast<size_t>(new_slot + 1));
            batch.tax_defaults.resize(
                static_cast<size_t>(new_slot + 1) * TAX_KIND_COUNT, 0);
            batch.income_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _profession_ids.size(),
                TAX_RATE_INHERIT);
            batch.consumption_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_RATE_INHERIT);
            batch.business_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) *
                    _building_type_ids.size(),
                TAX_RATE_INHERIT);
            batch.import_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_RATE_INHERIT);
            batch.export_tax_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_RATE_INHERIT);
            if (old_owner >= 0) {
                --batch.countries.territory_count[static_cast<size_t>(old_owner)];
                for (int32_t word = 0; word < _technology_words; ++word)
                    batch.technologies[static_cast<size_t>(new_slot) * _technology_words + word] =
                        batch.technologies[static_cast<size_t>(old_owner) * _technology_words + word];
                for (int32_t word = 0; word < _technology_words; ++word)
                    batch.discovered[static_cast<size_t>(new_slot) * _technology_words + word] =
                        batch.discovered[static_cast<size_t>(old_owner) * _technology_words + word];
                mark_country(old_owner);
            } else {
                for (int32_t tech : _starting_technologies)
                    batch.technologies[static_cast<size_t>(new_slot) * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
                for (int32_t tech : _starting_technologies)
                    batch.discovered[static_cast<size_t>(new_slot) * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
            }
            if (batch.cell_delta.set(command.cell, new_slot))
                batch.cell_delta_order.push_back(command.cell);
            staged_cell_policy(command.cell) = CellTaxPolicy{};
            mark_country(new_slot);
            event_country_handle = (1ULL << 32U) | static_cast<uint32_t>(new_slot);
            event_old_country_slot = old_owner;
            event_new_country_slot = new_slot;
        } else if (command.opcode == COMMAND_RENAME_COUNTRY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.display_name.empty()) { error = "country_name_empty"; break; }
            batch.countries.display_name[static_cast<size_t>(slot)] = command.display_name;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY ||
                   command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) {
            if (command.cell < 0 || command.cell >= _cell_count || _is_water[static_cast<size_t>(command.cell)] != 0) {
                error = "country_transfer_cell_invalid"; break;
            }
            int32_t target = NEUTRAL_SLOT;
            if (command.target_handle != 0 && !staged_handle(command.target_handle, target)) {
                error = "country_handle_invalid"; break;
            }
            const int32_t old_owner = batch.direct_unique_territory
                ? _cell_country_slot[static_cast<size_t>(command.cell)]
                : owner_of(command.cell);
            if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY &&
                old_owner != NEUTRAL_SLOT) {
                error = "country_claim_target_not_unowned";
                break;
            }
            if (old_owner == target) continue;
            if (old_owner >= 0) {
                --batch.countries.territory_count[static_cast<size_t>(old_owner)];
                ++batch.countries.state_version[static_cast<size_t>(old_owner)];
                mark_country(old_owner);
            }
            if (target >= 0) {
                ++batch.countries.territory_count[static_cast<size_t>(target)];
                ++batch.countries.state_version[static_cast<size_t>(target)];
                mark_country(target);
            }
            if (batch.direct_unique_territory) {
                batch.cell_delta_order.push_back(command.cell);
                batch.direct_cell_owners.push_back(target);
            } else if (batch.cell_delta.set(command.cell, target)) {
                batch.cell_delta_order.push_back(command.cell);
            }
            staged_cell_policy(command.cell) = CellTaxPolicy{};
            event_country_handle = target >= 0 ? ((static_cast<uint64_t>(batch.countries.generation[target]) << 32U) |
                                                   static_cast<uint32_t>(target)) : 0;
            event_old_country_slot = old_owner;
            event_new_country_slot = target;
        } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_technology_ids.size())) {
                error = "country_technology_invalid"; break;
            }
            uint64_t &word = batch.pending[
                static_cast<size_t>(slot) * _technology_words + command.aux / 64];
            const uint64_t bit = 1ULL << (command.aux % 64);
            const uint64_t completed_word = batch.technologies[
                static_cast<size_t>(slot) * _technology_words + command.aux / 64];
            if ((completed_word & bit) == 0 && (word & bit) == 0) {
                word |= bit;
                ++batch.countries.state_version[static_cast<size_t>(slot)];
                mark_country(slot);
            }
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_SET_RESEARCH_WEIGHTS) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            int32_t total = 0;
            for (int32_t domain = 0; domain < 4; ++domain) {
                if (command.weights_bp[domain] < 0 || command.weights_bp[domain] > 10000) {
                    error = "country_research_weight_invalid"; break;
                }
                total += command.weights_bp[domain];
            }
            if (!error.empty()) break;
            if (total != 10000) { error = "country_research_weight_total_invalid"; break; }
            for (int32_t domain = 0; domain < 4; ++domain)
                batch.research_weights_bp[static_cast<size_t>(slot) * 4U + domain] =
                    command.weights_bp[domain];
            batch.research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_ENQUEUE_RESEARCH ||
                   command.opcode == COMMAND_MOVE_RESEARCH) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_technology_ids.size()) ||
                command.domain < 0 || command.domain >= 4 ||
                command.position < -1 || command.position >= 8) {
                error = "country_research_queue_argument_invalid"; break;
            }
            const size_t word_index = static_cast<size_t>(slot) * _technology_words + command.aux / 64;
            const uint64_t bit = 1ULL << (command.aux % 64);
            if ((batch.discovered[word_index] & bit) == 0 ||
                (batch.technologies[word_index] & bit) != 0 ||
                (batch.pending[word_index] & bit) != 0) {
                error = "country_research_technology_unavailable"; break;
            }
            if (!research_condition_met(batch.technologies, batch.signals,
                                        batch.signal_evidence,
                                        slot, command.aux)) {
                error = "country_research_requirements_incomplete"; break;
            }
            const bool milestone = (_technology_flags[static_cast<size_t>(command.aux)] & 2) != 0;
            if (!milestone && _technology_domains[static_cast<size_t>(command.aux)] != command.domain) {
                error = "country_research_domain_mismatch"; break;
            }
            int32_t found_domain = -1, found_position = -1;
            for (int32_t domain = 0; domain < 4; ++domain) {
                const size_t length_index = static_cast<size_t>(slot) * 4U + domain;
                const size_t queue_base = length_index * 8U;
                for (int32_t position = 0; position < batch.research_queue_lengths[length_index]; ++position) {
                    if (batch.research_queues[queue_base + position] == command.aux) {
                        found_domain = domain;
                        found_position = position;
                    }
                }
            }
            if (command.opcode == COMMAND_ENQUEUE_RESEARCH && found_domain >= 0) {
                error = "country_research_already_queued"; break;
            }
            if (command.opcode == COMMAND_MOVE_RESEARCH && found_domain < 0) {
                error = "country_research_not_queued"; break;
            }
            if (found_domain >= 0) {
                const size_t old_length_index = static_cast<size_t>(slot) * 4U + found_domain;
                const size_t old_base = old_length_index * 8U;
                uint8_t &old_length = batch.research_queue_lengths[old_length_index];
                for (int32_t i = found_position + 1; i < old_length; ++i)
                    batch.research_queues[old_base + i - 1] = batch.research_queues[old_base + i];
                batch.research_queues[old_base + --old_length] = -1;
            }
            const size_t length_index = static_cast<size_t>(slot) * 4U + command.domain;
            const size_t queue_base = length_index * 8U;
            uint8_t &length = batch.research_queue_lengths[length_index];
            if (length >= 8) { error = "country_research_queue_full"; break; }
            const int32_t insert_at = command.position < 0 ? length :
                std::min<int32_t>(command.position, length);
            for (int32_t i = length; i > insert_at; --i)
                batch.research_queues[queue_base + i] = batch.research_queues[queue_base + i - 1];
            batch.research_queues[queue_base + insert_at] = command.aux;
            ++length;
            batch.research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_REMOVE_RESEARCH) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            bool removed = false;
            for (int32_t domain = 0; domain < 4 && !removed; ++domain) {
                const size_t length_index = static_cast<size_t>(slot) * 4U + domain;
                const size_t queue_base = length_index * 8U;
                uint8_t &length = batch.research_queue_lengths[length_index];
                for (int32_t position = 0; position < length; ++position) {
                    if (batch.research_queues[queue_base + position] != command.aux) continue;
                    for (int32_t i = position + 1; i < length; ++i)
                        batch.research_queues[queue_base + i - 1] = batch.research_queues[queue_base + i];
                    batch.research_queues[queue_base + --length] = -1;
                    removed = true;
                    break;
                }
            }
            if (!removed) { error = "country_research_not_queued"; break; }
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_SET_RESEARCH_BUDGET) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.value < 0 || (command.aux != 0 && command.aux != 1)) {
                error = "country_research_budget_invalid"; break;
            }
            batch.research_daily_budgets[static_cast<size_t>(slot)] = command.value;
            batch.research_auto_purchase[static_cast<size_t>(slot)] = static_cast<uint8_t>(command.aux);
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_REVEAL_ALL_TECHNOLOGIES) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
                batch.discovered[static_cast<size_t>(slot) * _technology_words + tech / 64] |=
                    1ULL << (tech % 64);
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_research_signal_ids.size()) ||
                command.cell < 0 || command.cell >= _cell_count) {
                error = "country_research_signal_command_invalid";
                break;
            }
            const uint64_t observation_key =
                (static_cast<uint64_t>(static_cast<uint32_t>(command.aux)) << 32U) |
                static_cast<uint32_t>(command.cell);
            std::vector<uint64_t> &observed_cells = batch.signal_cells[static_cast<size_t>(slot)];
            const auto observed_it = std::lower_bound(
                observed_cells.begin(), observed_cells.end(), observation_key);
            if (observed_it == observed_cells.end() || *observed_it != observation_key) {
                observed_cells.insert(observed_it, observation_key);
                if (_research_signal_words > 0) {
                    batch.signals[static_cast<size_t>(slot) * _research_signal_words +
                                  command.aux / 64] |= uint64_t{1} << (command.aux % 64);
                }
                std::vector<SignalEvidence> &evidence =
                    batch.signal_evidence[static_cast<size_t>(slot)];
                auto evidence_it = std::lower_bound(
                    evidence.begin(), evidence.end(), command.aux,
                    [](const SignalEvidence &entry, int32_t signal) {
                        return entry.signal < signal;
                    });
                if (evidence_it == evidence.end() || evidence_it->signal != command.aux) {
                    SignalEvidence entry;
                    entry.signal = command.aux;
                    entry.count = 0;
                    entry.first_day = day;
                    entry.last_day = day;
                    entry.first_cell = command.cell;
                    evidence_it = evidence.insert(evidence_it, entry);
                }
                ++evidence_it->count;
                evidence_it->last_day = day;
                ++batch.countries.state_version[static_cast<size_t>(slot)];
                mark_country(slot);
                event_country_handle = command.target_handle;
                event_new_country_slot = slot;
            }
        } else if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
                   command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
                command.tax_rate_percent < -100 ||
                command.tax_rate_percent > 100) {
                error = "country_tax_command_invalid";
                break;
            }
            if (command.opcode == COMMAND_SET_TAX_DEFAULT) {
                batch.tax_defaults[
                    static_cast<size_t>(slot) * TAX_KIND_COUNT +
                    command.tax_kind] =
                    static_cast<int8_t>(command.tax_rate_percent);
            } else {
                const int32_t item_count = tax_item_count(command.tax_kind);
                if (command.tax_item < 0 || command.tax_item >= item_count) {
                    error = "country_tax_item_invalid";
                    break;
                }
                std::vector<int8_t> *overrides = nullptr;
                switch (command.tax_kind) {
                    case TAX_INCOME:
                        overrides = &batch.income_tax_overrides; break;
                    case TAX_CONSUMPTION:
                        overrides = &batch.consumption_tax_overrides; break;
                    case TAX_BUSINESS:
                        overrides = &batch.business_tax_overrides; break;
                    case TAX_IMPORT:
                        overrides = &batch.import_tax_overrides; break;
                    case TAX_EXPORT:
                        overrides = &batch.export_tax_overrides; break;
                    default: break;
                }
                if (overrides == nullptr) {
                    error = "country_tax_kind_invalid";
                    break;
                }
                (*overrides)[static_cast<size_t>(slot) * item_count +
                             command.tax_item] =
                    command.opcode == COMMAND_CLEAR_TAX_OVERRIDE
                        ? TAX_RATE_INHERIT
                        : static_cast<int8_t>(command.tax_rate_percent);
            }
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
                   command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) {
                error = "country_handle_invalid";
                break;
            }
            if (command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                owner_of(command.cell) != slot) {
                error = "country_cell_tax_territory_invalid";
                break;
            }
            CellTaxPolicy &policy = staged_cell_policy(command.cell);
            if (command.opcode == COMMAND_CLEAR_CELL_TAX_POLICY) {
                policy = CellTaxPolicy{};
            } else if (command.tax_kind < 0 ||
                       command.tax_kind >= TAX_KIND_COUNT) {
                error = "country_cell_tax_kind_invalid";
                break;
            } else if (command.opcode == COMMAND_SET_CELL_TAX_DEFAULT) {
                if (command.tax_rate_percent < -100 ||
                    command.tax_rate_percent > 100) {
                    error = "country_cell_tax_rate_invalid";
                    break;
                }
                policy.defaults[static_cast<size_t>(command.tax_kind)] =
                    static_cast<int8_t>(command.tax_rate_percent);
            } else if (command.opcode == COMMAND_CLEAR_CELL_TAX_DEFAULT) {
                policy.defaults[static_cast<size_t>(command.tax_kind)] =
                    TAX_RATE_INHERIT;
            } else {
                if (command.tax_item < 0 ||
                    command.tax_item >= tax_item_count(command.tax_kind)) {
                    error = "country_cell_tax_item_invalid";
                    break;
                }
                const auto key_less = [](const CellTaxOverride &entry,
                                         const std::pair<int32_t, int32_t> &key) {
                    return entry.kind < key.first ||
                        (entry.kind == key.first && entry.item < key.second);
                };
                const std::pair<int32_t, int32_t> key{
                    command.tax_kind, command.tax_item};
                auto entry = std::lower_bound(policy.overrides.begin(),
                                              policy.overrides.end(), key,
                                              key_less);
                const bool exists = entry != policy.overrides.end() &&
                    entry->kind == command.tax_kind &&
                    entry->item == command.tax_item;
                if (command.opcode == COMMAND_CLEAR_CELL_TAX_OVERRIDE) {
                    if (exists) policy.overrides.erase(entry);
                } else {
                    if (command.tax_rate_percent < -100 ||
                        command.tax_rate_percent > 100) {
                        error = "country_cell_tax_rate_invalid";
                        break;
                    }
                    const CellTaxOverride replacement{
                        command.tax_kind, command.tax_item,
                        static_cast<int8_t>(command.tax_rate_percent)};
                    if (exists) *entry = replacement;
                    else policy.overrides.insert(entry, replacement);
                }
            }
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        }
        // The public event ring retains at most 2048 records. Avoid staging
        // tens of thousands of events that would be discarded immediately by
        // keeping the deterministic tail of very large atomic batches.
        if (command.opcode != COMMAND_TRANSFER_TERRITORY ||
            batch.commands.size() <= 2048 || batch.cursor + 2048 >= batch.commands.size()) {
            Event event;
            event.day = day;
            event.opcode = command.opcode;
            event.country_handle = event_country_handle;
            event.cell = command.cell;
            event.old_country_slot = event_old_country_slot;
            event.new_country_slot = event_new_country_slot;
            event.technology_id = command.aux;
            event.signal_id = command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL
                ? command.aux : -1;
            event.signal_source_kind = command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL
                ? static_cast<int32_t>(command.value) : 0;
            event.evidence_delta = command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL &&
                event_country_handle != 0 ? 1 : 0;
            event.stable_id = command.stable_id;
            event.display_name = command.display_name;
            batch.events.push_back(std::move(event));
        }
    }
    batch.preflight_ms += elapsed_ms(start);

    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        for (const Command &command : batch.commands) {
            if (command.effect_request_id == 0) continue;
            EffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        publish_report("command_preflight", day, preflight_ms, 0, 0, 0, 0, false, error);
        Dictionary out = report();
        out["ok"] = false;
        out["done"] = true;
        out["fatal_reason"] = error.c_str();
        return out;
    }

    if (batch.cursor < batch.commands.size()) {
        publish_report("command_preflight", day, batch.preflight_ms, 0, 0, 0, 0, false);
        Dictionary out = report();
        out["ok"] = true;
        out["done"] = false;
        out["country_day_barrier"] = true;
        out["cursor_start"] = static_cast<int64_t>(cursor_start);
        out["cursor_end"] = static_cast<int64_t>(batch.cursor);
        out["cursor_total"] = static_cast<int64_t>(batch.commands.size());
        out["progress_ratio"] = static_cast<double>(batch.cursor) /
            static_cast<double>(batch.commands.size());
        out["elapsed_ms"] = batch.preflight_ms;
        return out;
    }

    for (size_t slot = 0; slot < batch.countries.active.size(); ++slot) {
        if (batch.countries.active[slot] != 0 && batch.countries.territory_count[slot] <= 0) {
                error = "country_last_territory_protected";
            break;
        }
    }
    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        for (const Command &command : batch.commands) {
            if (command.effect_request_id == 0) continue;
            EffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        publish_report("command_preflight", day, preflight_ms, 0, 0, 0, 0, false, error);
        Dictionary out = report();
        out["ok"] = false;
        out["done"] = true;
        out["fatal_reason"] = error.c_str();
        return out;
    }

    const double preflight_ms = batch.preflight_ms;
    const int32_t changed_country_count = static_cast<int32_t>(std::count(
        batch.changed_countries.begin(), batch.changed_countries.end(), uint8_t{1}));
    SparseCellDelta cell_delta = std::move(batch.cell_delta);
    std::vector<int32_t> cell_delta_order = std::move(batch.cell_delta_order);
    std::vector<int32_t> direct_cell_owners = std::move(batch.direct_cell_owners);
    const bool direct_unique_territory = batch.direct_unique_territory;
    std::vector<Event> staged_events = std::move(batch.events);
    CountryStore staged_countries = std::move(batch.countries);
    std::vector<uint64_t> staged_technologies = std::move(batch.technologies);
    std::vector<int64_t> staged_goods = std::move(batch.goods);
    std::vector<uint64_t> staged_discovered = std::move(batch.discovered);
    std::vector<uint64_t> staged_pending = std::move(batch.pending);
    auto staged_progress = std::move(batch.progress);
    std::vector<int32_t> staged_research_queues = std::move(batch.research_queues);
    std::vector<uint8_t> staged_research_queue_lengths = std::move(batch.research_queue_lengths);
    std::vector<int32_t> staged_research_weights = std::move(batch.research_weights_bp);
    std::vector<uint8_t> staged_auto_purchase = std::move(batch.research_auto_purchase);
    std::vector<int64_t> staged_daily_budgets = std::move(batch.research_daily_budgets);
    std::vector<int64_t> staged_deferred_points = std::move(batch.research_deferred_points);
    std::vector<uint64_t> staged_signals = std::move(batch.signals);
    auto staged_signal_cells = std::move(batch.signal_cells);
    auto staged_signal_evidence = std::move(batch.signal_evidence);
    std::vector<int8_t> staged_tax_defaults =
        std::move(batch.tax_defaults);
    std::vector<int8_t> staged_income_tax =
        std::move(batch.income_tax_overrides);
    std::vector<int8_t> staged_consumption_tax =
        std::move(batch.consumption_tax_overrides);
    std::vector<int8_t> staged_business_tax =
        std::move(batch.business_tax_overrides);
    std::vector<int8_t> staged_import_tax =
        std::move(batch.import_tax_overrides);
    std::vector<int8_t> staged_export_tax =
        std::move(batch.export_tax_overrides);
    auto staged_cell_tax_updates = std::move(batch.cell_tax_updates);
    const bool stage_technologies = batch.stage_technologies;
    const bool stage_goods = batch.stage_goods;
    const bool stage_research = batch.stage_research;
    const bool stage_signals = batch.stage_signals;
    const bool stage_tax = batch.stage_tax;
    const bool stage_cell_tax = batch.stage_cell_tax;
    const int64_t observation_batch_input = batch.observation_batch_input;
    const int64_t observation_batch_added = batch.observation_batch_added;
    std::vector<std::pair<int32_t, int32_t>> signal_refreshes;
    if (stage_signals) {
        signal_refreshes.reserve(batch.commands.size());
        for (const Command &command : batch.commands) {
            if (command.opcode != COMMAND_DISCOVER_COUNTRY_SIGNAL) continue;
            int32_t signal_slot = -1;
            if (!validate_handle(command.target_handle, signal_slot)) continue;
            signal_refreshes.emplace_back(signal_slot, command.aux);
        }
        std::sort(signal_refreshes.begin(), signal_refreshes.end());
        signal_refreshes.erase(std::unique(signal_refreshes.begin(), signal_refreshes.end()),
                               signal_refreshes.end());
    }
    for (const Command &command : batch.commands) {
        if (command.effect_request_id == 0) continue;
        EffectCommandResult &result = _effect_command_results[command.effect_request_id];
        result.complete = 1; result.ok = 1; result.reason.clear();
    }
    _command_batch = {};

    const Clock::time_point apply_start = Clock::now();
    _countries = std::move(staged_countries);
    if (stage_technologies) _country_technologies = std::move(staged_technologies);
    if (stage_goods) _country_goods = std::move(staged_goods);
    if (stage_research) {
        _country_discovered = std::move(staged_discovered);
        _country_pending_technologies = std::move(staged_pending);
        _pending_activation_index_dirty = true;
        _country_research_progress = std::move(staged_progress);
        _country_research_queues = std::move(staged_research_queues);
        _country_research_queue_lengths = std::move(staged_research_queue_lengths);
        _country_research_weights_bp = std::move(staged_research_weights);
        _country_research_auto_purchase = std::move(staged_auto_purchase);
        _country_research_daily_budgets = std::move(staged_daily_budgets);
        _country_research_deferred_points = std::move(staged_deferred_points);
        const size_t country_count = _countries.active.size();
        _country_research_purchased_total.resize(country_count, 0);
        _country_research_consumed_total.resize(country_count, 0);
        _country_research_progress_total.resize(country_count, 0);
        _country_research_completed_total.resize(country_count, 0);
    }
    if (stage_signals) {
        _country_research_signals = std::move(staged_signals);
        _country_research_signal_cells = std::move(staged_signal_cells);
        _country_research_signal_evidence = std::move(staged_signal_evidence);
        for (const auto &entry : signal_refreshes)
            refresh_discovery_for_signal(entry.first, entry.second);
    }
    if (stage_tax) {
        _country_tax_defaults = std::move(staged_tax_defaults);
        _country_income_tax_overrides = std::move(staged_income_tax);
        _country_consumption_tax_overrides =
            std::move(staged_consumption_tax);
        _country_business_tax_overrides = std::move(staged_business_tax);
        _country_import_tax_overrides = std::move(staged_import_tax);
        _country_export_tax_overrides = std::move(staged_export_tax);
        ++_tax_policy_version;
    }
    if (stage_cell_tax && !staged_cell_tax_updates.empty()) {
        for (auto &entry : staged_cell_tax_updates) {
            const int32_t cell = entry.first;
            const uint32_t old_id =
                _cell_tax_policy_ids[static_cast<size_t>(cell)];
            if (cell_tax_policy(old_id) == entry.second) continue;
            const uint32_t new_id = intern_cell_tax_policy(entry.second);
            _cell_tax_policy_ids[static_cast<size_t>(cell)] = new_id;
            release_cell_tax_policy(old_id);
        }
        ++_tax_policy_version;
    }
    for (size_t i = 0; i < cell_delta_order.size(); ++i) {
        int32_t owner = NEUTRAL_SLOT;
        if (direct_unique_territory || cell_delta.get(cell_delta_order[i], owner)) {
            if (direct_unique_territory) owner = direct_cell_owners[i];
            _cell_country_slot[static_cast<size_t>(cell_delta_order[i])] = owner;
        }
    }
    const double apply_ms = elapsed_ms(apply_start);
    const Clock::time_point publish_start = Clock::now();
    if (!cell_delta_order.empty()) rebuild_cell_csr();
    ++_generation;
    _last_committed_day = day;
    for (Event &event : staged_events) push_event(std::move(event));
    const int32_t research_changed = run_research_day(day);
    const double aggregate_ms = elapsed_ms(publish_start);
    publish_report("aggregate_publish", day, preflight_ms, apply_ms, aggregate_ms,
                   static_cast<int32_t>(cell_delta_order.size()),
                   changed_country_count + research_changed, _mode == MODE_ACTIVE);
    Dictionary out = report();
    out["ok"] = true;
    out["done"] = true;
    out["elapsed_ms"] = preflight_ms + apply_ms + aggregate_ms;
    out["cursor_start"] = 0;
    out["cursor_end"] = static_cast<int64_t>(cursor_limit);
    out["cursor_total"] = static_cast<int64_t>(cursor_limit);
    out["progress_ratio"] = 1.0;
    out["country_day_barrier"] = should_run(day) || ack_chain_due(day);
    out["observation_batch_input"] = observation_batch_input;
    out["observation_batch_added"] = observation_batch_added;
    if (!cell_delta_order.empty()) {
        if (!std::is_sorted(cell_delta_order.begin(), cell_delta_order.end()))
            std::sort(cell_delta_order.begin(), cell_delta_order.end());
        PackedInt32Array changed_cells;
        PackedInt32Array changed_owners;
        changed_cells.resize(static_cast<int64_t>(cell_delta_order.size()));
        changed_owners.resize(static_cast<int64_t>(cell_delta_order.size()));
        int32_t *cell_ptr = changed_cells.ptrw();
        int32_t *owner_ptr = changed_owners.ptrw();
        for (size_t i = 0; i < cell_delta_order.size(); ++i) {
            cell_ptr[i] = cell_delta_order[i];
            int32_t owner = direct_unique_territory ? direct_cell_owners[i] : NEUTRAL_SLOT;
            if (!direct_unique_territory) cell_delta.get(cell_delta_order[i], owner);
            owner_ptr[i] = owner;
        }
        out["_changed_cell_indices"] = changed_cells;
        out["_changed_cell_owners"] = changed_owners;
    }
    return out;
}

void NativeCountryRuntime::rebuild_cell_csr() {
    const int32_t count = static_cast<int32_t>(_countries.active.size());
    _country_cell_offsets.assign(static_cast<size_t>(count + 1), 0);
    for (int32_t owner : _cell_country_slot)
        if (owner >= 0 && owner < count) ++_country_cell_offsets[static_cast<size_t>(owner + 1)];
    for (int32_t slot = 0; slot < count; ++slot)
        _country_cell_offsets[static_cast<size_t>(slot + 1)] += _country_cell_offsets[static_cast<size_t>(slot)];
    _country_cells.assign(static_cast<size_t>(_country_cell_offsets.back()), -1);
    std::vector<int32_t> cursor = _country_cell_offsets;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t owner = _cell_country_slot[static_cast<size_t>(cell)];
        if (owner >= 0 && owner < count) _country_cells[static_cast<size_t>(cursor[static_cast<size_t>(owner)]++)] = cell;
    }
}

void NativeCountryRuntime::publish_report(const char *stage, int64_t day,
                                          double preflight_ms, double apply_ms,
                                          double publish_ms, int32_t changed_cells,
                                          int32_t changed_countries, bool published,
                                          const std::string &reason) {
    const Clock::time_point report_start = Clock::now();
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = _bootstrapped;
    _report["schema_version"] = SCHEMA_VERSION;
    _report["runtime_mode"] = _mode == MODE_ACTIVE ? "ACTIVE" : (_mode == MODE_PROBE ? "PROBE" : "OFF");
    const char *report_mode = _full_diagnostics ? "FULL" : "LIGHT";
    _report["report_mode"] = report_mode;
    // Keep the explicit perf-record column names alongside the short legacy
    // names. These are transient diagnostics and are intentionally not part of
    // save/state or event hash contracts.
    _report["country_report_mode"] = report_mode;
    _report["path"] = _mode == MODE_ACTIVE ? "native_active" : (_mode == MODE_PROBE ? "native_probe" : "off");
    _report["stage"] = stage;
    _report["day_index"] = day;
    _report["country_count"] = static_cast<int64_t>(_countries.active.size());
    _report["cell_count"] = _cell_count;
    _report["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    _report["research_queue_size"] = _pending_activation_index_dirty
        ? static_cast<int64_t>(-1) : _pending_activation_count;
    _report["research_pending_queue_enabled"] = _pending_queue_enabled;
    _report["country_light_report_enabled"] = _light_report_enabled;
    _report["research_queue_rebuilds"] = _research_queue_rebuilds;
    _report["research_full_scan_fallbacks"] = _research_full_scan_fallbacks;
    _report["fallback_reason"] = String(_research_queue_fallback_reason.c_str());
    _report["fail_stage"] = _research_queue_fallback_reason.empty()
        ? String() : String("research_pending_queue");
    _report["fallback"] = !_research_queue_fallback_reason.empty();
    _report["cursor_start"] = 0;
    _report["cursor_end"] = changed_cells + changed_countries;
    _report["changed_cells"] = changed_cells;
    _report["changed_countries"] = changed_countries;
    _report["command_preflight_ms"] = preflight_ms;
    _report["command_apply_ms"] = apply_ms;
    _report["aggregate_publish_ms"] = publish_ms;
    _report["native_ms"] = preflight_ms + apply_ms + publish_ms;
    _report["generation"] = static_cast<int64_t>(_generation);
    const Clock::time_point hash_start = Clock::now();
    if (_full_diagnostics) {
        _report["state_hash"] = state_hash();
        _report["state_hash_stale"] = false;
    } else {
        // Keep the compatibility field for startup/save consumers, but never
        // trigger a full-map scan from the production report path.
        _report["state_hash"] = static_cast<int64_t>(
            _state_hash_cache_valid ? _state_hash_cache : 0);
        _report["state_hash_stale"] = !_state_hash_cache_valid;
    }
    const double state_hash_ms = elapsed_ms(hash_start);
    _report["state_hash_ms"] = state_hash_ms;
    _report["country_state_hash_ms"] = state_hash_ms;
    _report["published_to_slot"] = published;
    _report["done"] = true;
    _report["country_day_barrier"] = false;
    _report["last_committed_day"] = _last_committed_day;
    // Cell tax policy statistics require walking the intern table (and can
    // approach map-sized work). Keep them out of the ACTIVE/LIGHT report;
    // FULL remains the explicit diagnostic path for these counters.
    if (_full_diagnostics) {
        int64_t authoritative_policies = 0;
        int64_t shared_policies = 0;
        int64_t cell_tax_overrides = 0;
        for (size_t id = 1; id < _cell_tax_policy_refcounts.size(); ++id) {
            if (_cell_tax_policy_refcounts[id] == 0) continue;
            ++authoritative_policies;
            if (_cell_tax_policy_refcounts[id] > 1) ++shared_policies;
            cell_tax_overrides += static_cast<int64_t>(
                _cell_tax_policies[id].overrides.size());
        }
        _report["cell_tax_authoritative_policy_count"] = authoritative_policies;
        _report["cell_tax_shared_policy_count"] = shared_policies;
        _report["cell_tax_override_count"] = cell_tax_overrides;
    } else {
        _report["cell_tax_authoritative_policy_count"] = 0;
        _report["cell_tax_shared_policy_count"] = 0;
        _report["cell_tax_override_count"] = 0;
    }
    int64_t oldest_due = day;
    for (const Command &command : _pending_commands)
        oldest_due = std::min(oldest_due, command.effective_day);
    _report["pending_latency_days"] = _pending_commands.empty()
        ? 0 : std::max<int64_t>(0, day - oldest_due);
    if (_full_diagnostics) {
        int64_t memory_bytes =
            static_cast<int64_t>(_countries.active.size() * sizeof(uint8_t) +
            _countries.generation.size() * sizeof(uint32_t) +
            _countries.territory_count.size() * sizeof(int32_t) +
            _countries.cash.size() * sizeof(int64_t) +
            _countries.state_version.size() * sizeof(uint64_t) +
            _cell_country_slot.size() * sizeof(int32_t) +
            _country_cell_offsets.size() * sizeof(int32_t) +
            _country_cells.size() * sizeof(int32_t) +
            _country_technologies.size() * sizeof(uint64_t) +
            _country_goods.size() * sizeof(int64_t) +
            _cell_tax_policy_ids.size() * sizeof(uint32_t) +
            _cell_tax_policies.size() * sizeof(CellTaxPolicy) +
            _cell_tax_policy_refcounts.size() * sizeof(uint32_t));
        for (const CellTaxPolicy &policy : _cell_tax_policies)
            memory_bytes += static_cast<int64_t>(
                policy.overrides.capacity() * sizeof(CellTaxOverride));
        for (const std::string &value : _countries.stable_id) memory_bytes += value.capacity() + 1;
        for (const std::string &value : _countries.display_name) memory_bytes += value.capacity() + 1;
        for (const std::string &value : _good_ids) memory_bytes += value.capacity() + 1;
        for (const std::string &value : _technology_ids) memory_bytes += value.capacity() + 1;
        memory_bytes += static_cast<int64_t>(_is_water.capacity() * sizeof(uint8_t) +
            _starting_technologies.capacity() * sizeof(int32_t) +
            _pending_commands.size() * sizeof(Command) + _events.size() * sizeof(Event));
        for (const Command &command : _pending_commands)
            memory_bytes += command.stable_id.capacity() + command.display_name.capacity() + 2;
        // Account conservatively for unordered-map nodes/buckets. Exact allocator
        // overhead is implementation-specific; this estimate intentionally rounds up.
        memory_bytes += static_cast<int64_t>((_good_index.size() + _technology_index.size()) * 64 +
            (_good_index.bucket_count() + _technology_index.bucket_count()) * sizeof(void *));
        _report["memory_bytes"] = memory_bytes;
    } else {
        _report["memory_bytes"] = 0;
    }
    if (!reason.empty()) {
        _report["fallback_reason"] = reason.c_str();
        _report["fail_stage"] = stage;
    }
    const double report_build_ms = elapsed_ms(report_start);
    _report["report_build_ms"] = report_build_ms;
    _report["country_report_build_ms"] = report_build_ms;
}

Dictionary NativeCountryRuntime::report() const { return _report.duplicate(); }

Dictionary NativeCountryRuntime::reset(const String &reason) {
    _bootstrapped = false;
    _state_hash_cache_valid = false;
    _countries = {};
    _cell_country_slot.assign(static_cast<size_t>(std::max(0, _cell_count)), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
    _pending_activation_indices.clear();
    _pending_activation_index_dirty = true;
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _research_full_scan_fallbacks = 0;
    _research_queue_fallback_reason.clear();
    _country_research_progress.clear();
    _country_research_queues.clear();
    _country_research_queue_lengths.clear();
    _country_research_weights_bp.clear();
    _country_research_auto_purchase.clear();
    _country_research_daily_budgets.clear();
    _country_research_deferred_points.clear();
    _country_research_purchased_total.clear();
    _country_research_consumed_total.clear();
    _country_research_progress_total.clear();
    _country_research_completed_total.clear();
    _country_tax_defaults.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _cell_tax_policy_ids.assign(static_cast<size_t>(std::max(0, _cell_count)), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _tax_policy_version = 0;
    _last_research_day = -1;
    _pending_commands.clear();
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _next_effect_request_id = 1;
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};
    ++_generation;
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = false;
    _report["reason"] = reason;
    Dictionary out;
    out["ok"] = true;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

Dictionary NativeCountryRuntime::cell_summary(int32_t cell) const {
    if (!_bootstrapped || cell < 0 || cell >= _cell_count) return {};
    Dictionary out;
    out["ok"] = true;
    out["cell"] = cell;
    const int32_t slot = _cell_country_slot[static_cast<size_t>(cell)];
    out["country_slot"] = slot;
    if (slot < 0) {
        out["owned"] = false;
        // Must use utf8(): Godot String(const char*) is not UTF-8 and mojibakes CJK.
        out["country_name"] = String::utf8("无主之地");
        out["country_handle"] = static_cast<int64_t>(0);
        return out;
    }
    Dictionary country = country_summary(static_cast<int64_t>(make_handle(slot)));
    const Array keys = country.keys();
    for (int64_t index = 0; index < keys.size(); ++index)
        out[keys[index]] = country[keys[index]];
    out["cell"] = cell;
    out["country_slot"] = slot;
    return out;
}

Dictionary NativeCountryRuntime::country_summary(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");
    int32_t nonzero_goods = 0;
    for (size_t good = 0; good < _good_ids.size(); ++good)
        if (_country_goods[static_cast<size_t>(slot) * _good_ids.size() + good] != 0)
            ++nonzero_goods;
    int32_t technologies = 0;
    for (int32_t tech = 0;
         tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech)) ++technologies;
    Dictionary out;
    out["ok"] = true;
    out["owned"] = true;
    out["country_handle"] = handle;
    out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
    out["country_name"] = String::utf8(
        _countries.display_name[static_cast<size_t>(slot)].c_str());
    out["territory_count"] =
        _countries.territory_count[static_cast<size_t>(slot)];
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["nonzero_good_count"] = nonzero_goods;
    out["technology_count"] = technologies;
    out["state_version"] = static_cast<int64_t>(
        _countries.state_version[static_cast<size_t>(slot)]);
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

PackedStringArray NativeCountryRuntime::completed_technology_ids(
        int64_t handle) const {
    int32_t slot = -1;
    PackedStringArray technology_ids;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return technology_ids;
    for (int32_t tech = 0;
         tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech))
            technology_ids.push_back(
                _technology_ids[static_cast<size_t>(tech)].c_str());
    return technology_ids;
}

Dictionary NativeCountryRuntime::submit_observation_batch(
        int64_t handle, const PackedInt32Array &cells,
        const PackedInt32Array &signals, int64_t effective_day) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    if (_mode == MODE_OFF) return fail("country_runtime_off");
    if (effective_day < 0 || cells.size() != signals.size())
        return fail("country_observation_batch_invalid");
    int32_t country_slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), country_slot))
        return fail("country_handle_invalid");
    const int32_t count = cells.size();
    if (count == 0) {
        Dictionary out;
        out["ok"] = true;
        out["submitted"] = 0;
        out["pending"] = static_cast<int64_t>(_pending_commands.size());
        return out;
    }
    const int32_t signal_count = static_cast<int32_t>(_research_signal_ids.size());
    for (int32_t i = 0; i < count; ++i) {
        if (cells[i] < 0 || cells[i] >= _cell_count ||
            signals[i] < 0 || signals[i] >= signal_count)
            return fail("country_observation_batch_invalid");
    }
    _pending_commands.reserve(_pending_commands.size() + size_t(count));
    for (int32_t i = 0; i < count; ++i) {
        Command command;
        command.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL;
        command.effective_day = effective_day;
        command.sequence = i;
        command.target_handle = static_cast<uint64_t>(handle);
        command.cell = cells[i];
        command.aux = signals[i];
        command.value = 1;
        command.submit_order = ++_submit_order;
        _pending_commands.push_back(std::move(command));
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted"] = count;
    out["pending"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeCountryRuntime::has_completed_technology(
        int64_t handle, int32_t technology_id) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(handle), slot) &&
           has_technology(slot, technology_id);
}

Dictionary NativeCountryRuntime::country_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray technology_ids = completed_technology_ids(handle);
    PackedInt32Array cells;
    if (slot + 1 < static_cast<int32_t>(_country_cell_offsets.size())) {
        const int32_t begin = _country_cell_offsets[static_cast<size_t>(slot)];
        const int32_t end = _country_cell_offsets[static_cast<size_t>(slot + 1)];
        cells.resize(end - begin);
        if (end > begin) std::memcpy(cells.ptrw(), _country_cells.data() + begin, static_cast<size_t>(end - begin) * sizeof(int32_t));
    }
    Dictionary out = country_summary(handle);
    out["cell"] = cells.is_empty() ? -1 : cells[0];
    out["country_slot"] = slot;
    out["technology_ids"] = technology_ids;
    out["territory_cells"] = cells;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

Dictionary NativeCountryRuntime::treasury_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray good_ids;
    PackedInt64Array quantities;
    for (size_t good = 0; good < _good_ids.size(); ++good) {
        const int64_t quantity = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + good];
        if (quantity == 0) continue;
        good_ids.push_back(_good_ids[good].c_str());
        quantities.push_back(quantity);
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["good_ids"] = good_ids;
    out["quantities"] = quantities;
    return out;
}

Dictionary NativeCountryRuntime::tax_policy_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");

    PackedInt32Array defaults;
    defaults.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        defaults.set(kind, _country_tax_defaults[
            static_cast<size_t>(slot) * TAX_KIND_COUNT + kind]);
    }

    auto make_rates = [&](int32_t kind, const char *kind_key,
                          const std::vector<std::string> &item_ids,
                          const std::vector<int8_t> &values) {
        PackedInt32Array rates;
        PackedInt32Array effective_rates;
        PackedByteArray overrides;
        const int32_t count = tax_item_count(kind);
        rates.resize(count);
        effective_rates.resize(count);
        overrides.resize(count);
        for (int32_t item = 0; item < count; ++item) {
            const int8_t raw = values[
                static_cast<size_t>(slot) * count + item];
            const int32_t base_rate = raw == TAX_RATE_INHERIT
                ? defaults[kind] : raw;
            rates.set(item, base_rate);
            int32_t effective_rate = base_rate;
            if (_modifier_runtime != nullptr &&
                item < static_cast<int32_t>(item_ids.size())) {
                const std::string stat_key = std::string("country.tax.") +
                    kind_key + "." + item_ids[item] + ".rate_pct";
                const int32_t stat_id =
                    _modifier_runtime->stat_id_for_key(stat_key);
                if (stat_id >= 0) {
                    effective_rate = static_cast<int32_t>(std::clamp<int64_t>(
                        std::lround(_modifier_runtime->effective_value(
                            ModifierRuntime::COUNTRY, stat_id,
                            static_cast<uint64_t>(handle), 0, base_rate)),
                        -100, 100));
                }
            }
            effective_rates.set(item, effective_rate);
            overrides.set(item, raw == TAX_RATE_INHERIT ? 0 : 1);
        }
        Dictionary result;
        result["rates"] = rates;
        result["effective_rates"] = effective_rates;
        result["has_override"] = overrides;
        return result;
    };
    auto make_ids = [](const std::vector<std::string> &ids) {
        PackedStringArray out;
        for (const std::string &id : ids) out.push_back(id.c_str());
        return out;
    };

    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["policy_version"] = static_cast<int64_t>(_tax_policy_version);
    out["catalog_hash"] = static_cast<int64_t>(catalog_hash());
    out["default_rates"] = defaults;
    out["profession_ids"] = make_ids(_profession_ids);
    out["good_ids"] = make_ids(_good_ids);
    out["building_type_ids"] = make_ids(_building_type_ids);
    out["income"] = make_rates(TAX_INCOME, "income", _profession_ids,
                               _country_income_tax_overrides);
    out["consumption"] = make_rates(
        TAX_CONSUMPTION, "consumption", _good_ids,
        _country_consumption_tax_overrides);
    out["business"] = make_rates(
        TAX_BUSINESS, "business", _building_type_ids,
        _country_business_tax_overrides);
    out["import"] = make_rates(TAX_IMPORT, "import", _good_ids,
                               _country_import_tax_overrides);
    out["export"] = make_rates(TAX_EXPORT, "export", _good_ids,
                               _country_export_tax_overrides);
    out["tariffs_active"] = false;
    return out;
}

Dictionary NativeCountryRuntime::cell_tax_policy_snapshot(int32_t cell) const {
    if (!_bootstrapped || cell < 0 || cell >= _cell_count)
        return fail("country_cell_tax_cell_invalid");
    const int32_t slot = _cell_country_slot[static_cast<size_t>(cell)];
    if (slot < 0) return fail("country_cell_tax_unowned");
    const uint64_t handle = make_handle(slot);
    const CellTaxPolicy &policy = cell_tax_policy(
        _cell_tax_policy_ids[static_cast<size_t>(cell)]);

    PackedInt32Array country_defaults;
    PackedInt32Array local_defaults;
    PackedByteArray has_local_default;
    country_defaults.resize(TAX_KIND_COUNT);
    local_defaults.resize(TAX_KIND_COUNT);
    has_local_default.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        country_defaults.set(kind, _country_tax_defaults[
            static_cast<size_t>(slot) * TAX_KIND_COUNT + kind]);
        const int8_t local = policy.defaults[static_cast<size_t>(kind)];
        local_defaults.set(kind, local == TAX_RATE_INHERIT ? 0 : local);
        has_local_default.set(kind, local == TAX_RATE_INHERIT ? 0 : 1);
    }

    auto make_kind = [&](int32_t kind, const char *kind_key) {
        const auto &ids = tax_item_ids(kind);
        const std::vector<int8_t> *country_overrides =
            tax_override_vector(kind);
        const int32_t count = static_cast<int32_t>(ids.size());
        PackedStringArray item_ids;
        PackedInt32Array country_base_rates;
        PackedInt32Array local_item_rates;
        PackedInt32Array final_base_rates;
        PackedInt32Array effective_rates;
        PackedByteArray has_local_item;
        PackedStringArray source_scopes;
        item_ids.resize(count);
        country_base_rates.resize(count);
        local_item_rates.resize(count);
        final_base_rates.resize(count);
        effective_rates.resize(count);
        has_local_item.resize(count);
        source_scopes.resize(count);
        size_t local_cursor = 0;
        while (local_cursor < policy.overrides.size() &&
               policy.overrides[local_cursor].kind < kind)
            ++local_cursor;
        for (int32_t item = 0; item < count; ++item) {
            item_ids.set(item, ids[static_cast<size_t>(item)].c_str());
            const int8_t country_raw = (*country_overrides)[
                static_cast<size_t>(slot) * count + item];
            const int32_t country_base = country_raw == TAX_RATE_INHERIT
                ? country_defaults[kind] : country_raw;
            country_base_rates.set(item, country_base);
            while (local_cursor < policy.overrides.size() &&
                   policy.overrides[local_cursor].kind == kind &&
                   policy.overrides[local_cursor].item < item)
                ++local_cursor;
            const bool local_item =
                local_cursor < policy.overrides.size() &&
                policy.overrides[local_cursor].kind == kind &&
                policy.overrides[local_cursor].item == item;
            const int8_t local_default =
                policy.defaults[static_cast<size_t>(kind)];
            const int32_t base_rate = local_item
                ? policy.overrides[local_cursor].rate
                : (local_default != TAX_RATE_INHERIT
                    ? local_default : country_base);
            local_item_rates.set(item, local_item
                ? policy.overrides[local_cursor].rate : 0);
            has_local_item.set(item, local_item ? 1 : 0);
            final_base_rates.set(item, base_rate);
            const char *source = local_item ? "cell_item"
                : (local_default != TAX_RATE_INHERIT ? "cell_default"
                   : (country_raw != TAX_RATE_INHERIT
                      ? "country_item" : "country_default"));
            source_scopes.set(item, source);

            int32_t effective_rate = base_rate;
            if (_modifier_runtime != nullptr) {
                const std::string stat_key = std::string("country.tax.") +
                    kind_key + "." + ids[static_cast<size_t>(item)] +
                    ".rate_pct";
                const int32_t stat_id =
                    _modifier_runtime->stat_id_for_key(stat_key);
                if (stat_id >= 0) {
                    effective_rate = static_cast<int32_t>(
                        std::clamp<int64_t>(std::lround(
                            _modifier_runtime->effective_value(
                                ModifierRuntime::COUNTRY, stat_id, handle,
                                0, base_rate)), -100, 100));
                }
            }
            effective_rates.set(item, effective_rate);
        }
        Dictionary result;
        result["item_ids"] = item_ids;
        result["country_base_rates"] = country_base_rates;
        result["local_item_rates"] = local_item_rates;
        result["has_local_item"] = has_local_item;
        result["final_base_rates"] = final_base_rates;
        result["effective_rates"] = effective_rates;
        result["source_scopes"] = source_scopes;
        return result;
    };

    Dictionary out;
    out["ok"] = true;
    out["cell"] = cell;
    out["country_handle"] = static_cast<int64_t>(handle);
    out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
    out["country_name"] = String::utf8(
        _countries.display_name[static_cast<size_t>(slot)].c_str());
    out["policy_version"] = static_cast<int64_t>(_tax_policy_version);
    out["country_default_rates"] = country_defaults;
    out["local_default_rates"] = local_defaults;
    out["has_local_default"] = has_local_default;
    out["income"] = make_kind(TAX_INCOME, "income");
    out["consumption"] = make_kind(TAX_CONSUMPTION, "consumption");
    out["business"] = make_kind(TAX_BUSINESS, "business");
    out["import"] = make_kind(TAX_IMPORT, "import");
    out["export"] = make_kind(TAX_EXPORT, "export");
    out["tariffs_active"] = false;
    return out;
}

Dictionary NativeCountryRuntime::research_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedInt32Array states;
    PackedInt64Array progress;
    states.resize(static_cast<int64_t>(_technology_ids.size()));
    progress.resize(static_cast<int64_t>(_technology_ids.size()));
    const size_t word_base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
        const uint64_t bit = 1ULL << (tech % 64);
        int32_t state = 0;
        if ((_country_technologies[word_base + tech / 64] & bit) != 0) state = 5;
        else if ((_country_pending_technologies[word_base + tech / 64] & bit) != 0) state = 4;
        else if ((_country_discovered[word_base + tech / 64] & bit) != 0)
            state = prerequisites_met(slot, tech) ? 2 : 1;
        states.set(tech, state);
        progress.set(tech, progress_for(slot, tech));
    }
    PackedInt32Array queue_offsets;
    PackedInt32Array queue_technologies;
    queue_offsets.push_back(0);
    for (int32_t domain = 0; domain < 4; ++domain) {
        const size_t length_index = static_cast<size_t>(slot) * 4U + domain;
        const size_t queue_base = length_index * 8U;
        const int32_t length = _country_research_queue_lengths[length_index];
        for (int32_t position = 0; position < length; ++position) {
            const int32_t tech = _country_research_queues[queue_base + position];
            queue_technologies.push_back(tech);
            if (states[tech] < 4) states.set(tech, 3);
        }
        queue_offsets.push_back(queue_technologies.size());
    }
    PackedInt32Array weights;
    for (int32_t domain = 0; domain < 4; ++domain)
        weights.push_back(_country_research_weights_bp[static_cast<size_t>(slot) * 4U + domain]);
    const int64_t stock = _country_goods[
        static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(_technology_points_good_id)];
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["technology_states"] = states;
    out["technology_progress"] = progress;
    out["queue_offsets"] = queue_offsets;
    out["queue_technology_indices"] = queue_technologies;
    out["domain_weights_bp"] = weights;
    out["auto_purchase_enabled"] =
        _country_research_auto_purchase[static_cast<size_t>(slot)] != 0;
    out["daily_procurement_budget"] =
        _country_research_daily_budgets[static_cast<size_t>(slot)];
    out["technology_points_stock"] = stock;
    out["deferred_unallocated_points"] =
        _country_research_deferred_points[static_cast<size_t>(slot)];
    out["purchased_total"] = _country_research_purchased_total[static_cast<size_t>(slot)];
    out["consumed_total"] = _country_research_consumed_total[static_cast<size_t>(slot)];
    out["progress_total"] = _country_research_progress_total[static_cast<size_t>(slot)];
    out["completed_total"] = _country_research_completed_total[static_cast<size_t>(slot)];
    out["last_research_day"] = _last_research_day;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

Dictionary NativeCountryRuntime::research_signal_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");
    PackedInt32Array signal_ids;
    PackedInt32Array counts;
    PackedInt64Array first_days;
    PackedInt64Array last_days;
    PackedInt32Array first_cells;
    if (slot >= 0 && slot < static_cast<int32_t>(_country_research_signal_evidence.size())) {
        const std::vector<SignalEvidence> &entries =
            _country_research_signal_evidence[static_cast<size_t>(slot)];
        signal_ids.resize(static_cast<int64_t>(entries.size()));
        counts.resize(static_cast<int64_t>(entries.size()));
        first_days.resize(static_cast<int64_t>(entries.size()));
        last_days.resize(static_cast<int64_t>(entries.size()));
        first_cells.resize(static_cast<int64_t>(entries.size()));
        for (size_t i = 0; i < entries.size(); ++i) {
            signal_ids.set(static_cast<int64_t>(i), entries[i].signal);
            counts.set(static_cast<int64_t>(i), entries[i].count);
            first_days.set(static_cast<int64_t>(i), entries[i].first_day);
            last_days.set(static_cast<int64_t>(i), entries[i].last_day);
            first_cells.set(static_cast<int64_t>(i), entries[i].first_cell);
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["signal_ids"] = signal_ids;
    out["counts"] = counts;
    out["first_days"] = first_days;
    out["last_days"] = last_days;
    out["first_cells"] = first_cells;
    return out;
}

bool NativeCountryRuntime::research_procurement_policy(int32_t country_slot, bool &enabled,
                                                       int64_t &cash_budget,
                                                       int64_t &remaining_points) const {
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(country_slot)] == 0) return false;
    const size_t slot = static_cast<size_t>(country_slot);
    enabled = _country_research_auto_purchase[slot] != 0;
    cash_budget = _country_research_daily_budgets[slot];
    remaining_points = 0;
    for (int32_t domain = 0; domain < 4; ++domain) {
        const size_t length_index = slot * 4U + domain;
        const size_t queue_base = length_index * 8U;
        for (int32_t position = 0; position < _country_research_queue_lengths[length_index]; ++position) {
            const int32_t tech = _country_research_queues[queue_base + position];
            remaining_points += std::max<int64_t>(
                0, effective_research_cost(country_slot, tech) -
                progress_for(country_slot, tech));
        }
    }
    const int64_t stock = _country_goods[
        slot * _good_ids.size() + static_cast<size_t>(_technology_points_good_id)];
    const int64_t unreserved = std::max<int64_t>(
        0, stock - _country_research_deferred_points[slot]);
    // Unreserved treasury stock is a real buyer gap of zero: government will
    // not purchase points it already holds. Starter grants must therefore not
    // cover later queued techs, or automatic investment never sees demand.
    remaining_points = std::max<int64_t>(0, remaining_points - unreserved);
    return true;
}

bool NativeCountryRuntime::purchase_research_points(int32_t country_slot,
                                                     int64_t quantity,
                                                     int64_t total_cost) {
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(_countries.active.size()) ||
        quantity <= 0 || total_cost < 0 ||
        _countries.cash[static_cast<size_t>(country_slot)] < total_cost) return false;
    const size_t slot = static_cast<size_t>(country_slot);
    int64_t &stock = _country_goods[
        slot * _good_ids.size() + static_cast<size_t>(_technology_points_good_id)];
    if (quantity > std::numeric_limits<int64_t>::max() - stock) return false;
    _countries.cash[slot] -= total_cost;
    stock += quantity;
    _country_research_purchased_total[slot] += quantity;
    ++_countries.state_version[slot];
    ++_generation;
    return true;
}

PackedInt32Array NativeCountryRuntime::cell_country_snapshot() const {
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(_cell_country_slot.size()));
    if (!_cell_country_slot.empty()) std::memcpy(out.ptrw(), _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    return out;
}

bool NativeCountryRuntime::has_technology(int32_t country_slot, int32_t technology_id) const {
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(_countries.active.size()) ||
        technology_id < 0 || technology_id >= static_cast<int32_t>(_technology_ids.size())) return false;
    return (_country_technologies[static_cast<size_t>(country_slot) * _technology_words + technology_id / 64] &
            (1ULL << (technology_id % 64))) != 0;
}

bool NativeCountryRuntime::has_research_signal(int32_t country_slot,
                                                int32_t signal_id) const {
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(_countries.active.size()) ||
        signal_id < 0 || signal_id >= static_cast<int32_t>(_research_signal_ids.size()) ||
        _countries.active[static_cast<size_t>(country_slot)] == 0) return false;
    const size_t base = static_cast<size_t>(country_slot) * _research_signal_words;
    return (_country_research_signals[base + static_cast<size_t>(signal_id / 64)] &
            (1ULL << (signal_id % 64))) != 0;
}

bool NativeCountryRuntime::prerequisites_met(const std::vector<uint64_t> &completed,
                                              int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_ids.size())) return false;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const auto has = [&](int32_t tech) {
        return (completed[base + tech / 64] & (1ULL << (tech % 64))) != 0;
    };
    if (!era_entry_met(completed, slot, technology)) return false;
    const int32_t milestone_begin = _technology_milestone_offsets[static_cast<size_t>(technology)];
    const int32_t milestone_end = _technology_milestone_offsets[static_cast<size_t>(technology + 1)];
    if (milestone_end > milestone_begin) {
        int32_t count = 0;
        for (int32_t edge = milestone_begin; edge < milestone_end; ++edge)
            if (has(_technology_milestone_candidates[static_cast<size_t>(edge)])) ++count;
        return count >= _technology_milestone_required_counts[static_cast<size_t>(technology)];
    }
    const int32_t begin = _technology_prerequisite_offsets[static_cast<size_t>(technology)];
    const int32_t end = _technology_prerequisite_offsets[static_cast<size_t>(technology + 1)];
    for (int32_t edge = begin; edge < end; ++edge)
        if (!has(_technology_prerequisites[static_cast<size_t>(edge)])) return false;
    return true;
}

bool NativeCountryRuntime::era_entry_met(const std::vector<uint64_t> &completed,
                                          int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_entry_milestone_indices.size())) return false;
    const int32_t entry = _technology_entry_milestone_indices[static_cast<size_t>(technology)];
    // -1: ordinary node, or the first-era milestone. Previous-era completion is
    // a research gate only for later-era milestone technologies.
    if (entry < 0) return true;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const size_t word = base + static_cast<size_t>(entry / 64);
    return word < completed.size() &&
           (completed[word] & (uint64_t{1} << (entry % 64))) != 0;
}

bool NativeCountryRuntime::prerequisites_met(int32_t slot, int32_t technology) const {
    return research_condition_met(slot, technology);
}

bool NativeCountryRuntime::signal_present(const std::vector<uint64_t> &signals,
                                          int32_t slot, int32_t signal) const {
    if (slot < 0 || signal < 0 || signal >= static_cast<int32_t>(_research_signal_ids.size()) ||
        _research_signal_words <= 0) return false;
    const size_t index = static_cast<size_t>(slot) * _research_signal_words + signal / 64;
    return index < signals.size() && (signals[index] & (uint64_t{1} << (signal % 64))) != 0;
}

NativeCountryRuntime::SignalEvidence *NativeCountryRuntime::find_signal_evidence(
        std::vector<SignalEvidence> &entries, int32_t signal) {
    const auto it = std::lower_bound(entries.begin(), entries.end(), signal,
        [](const SignalEvidence &entry, int32_t needle) { return entry.signal < needle; });
    return it != entries.end() && it->signal == signal ? &*it : nullptr;
}

const NativeCountryRuntime::SignalEvidence *NativeCountryRuntime::find_signal_evidence(
        const std::vector<SignalEvidence> &entries, int32_t signal) {
    const auto it = std::lower_bound(entries.begin(), entries.end(), signal,
        [](const SignalEvidence &entry, int32_t needle) { return entry.signal < needle; });
    return it != entries.end() && it->signal == signal ? &*it : nullptr;
}

int32_t NativeCountryRuntime::signal_count(int32_t slot, int32_t signal) const {
    return signal_count(_country_research_signal_evidence, slot, signal);
}

int32_t NativeCountryRuntime::signal_count(
        const std::vector<std::vector<SignalEvidence>> &evidence,
        int32_t slot, int32_t signal) const {
    if (slot < 0 || slot >= static_cast<int32_t>(evidence.size())) return 0;
    const SignalEvidence *entry = find_signal_evidence(
        evidence[static_cast<size_t>(slot)], signal);
    return entry == nullptr ? 0 : entry->count;
}

bool NativeCountryRuntime::research_condition_met(const std::vector<uint64_t> &completed,
                                                   const std::vector<uint64_t> &signals,
                                                   const std::vector<std::vector<SignalEvidence>> &evidence,
                                                   int32_t slot, int32_t technology) const {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_research_condition_offsets.empty()) return false;
    const int32_t begin = _technology_research_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end = _technology_research_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin == end) return true;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t tech_base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op = _technology_research_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref = _technology_research_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value = _technology_research_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size()) || ref < 0 ||
                ref >= static_cast<int32_t>(_technology_ids.size())) return false;
            stack[depth++] = (completed[tech_base + ref / 64] & (uint64_t{1} << (ref % 64))) != 0;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_present(signals, slot, ref);
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_count(evidence, slot, ref) >= value;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1 : 0;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i) truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = op == 10 ? truth_count == ref :
                (op == 11 ? truth_count > 0 : truth_count >= value);
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

bool NativeCountryRuntime::research_condition_met(int32_t slot, int32_t technology) const {
    return research_condition_met(_country_technologies, _country_research_signals,
                                  _country_research_signal_evidence,
                                  slot, technology);
}

bool NativeCountryRuntime::reveal_condition_met(int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_reveal_condition_offsets.empty()) return false;
    const int32_t begin = _technology_reveal_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end = _technology_reveal_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin == end) return true;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t tech_base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op = _technology_reveal_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref = _technology_reveal_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value = _technology_reveal_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size()) || ref < 0 ||
                ref >= static_cast<int32_t>(_technology_ids.size())) return false;
            stack[depth++] = (_country_technologies[tech_base + ref / 64] &
                              (uint64_t{1} << (ref % 64))) != 0;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_present(_country_research_signals, slot, ref);
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_count(slot, ref) >= value;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1 : 0;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i)
                truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = op == 10 ? truth_count == ref :
                (op == 11 ? truth_count > 0 : truth_count >= value);
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

void NativeCountryRuntime::refresh_discovery_for_technology(int32_t slot, int32_t tech) {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size())) return;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const uint64_t bit = uint64_t{1} << (tech % 64);
    if ((_country_technologies[base + tech / 64] & bit) != 0) {
        _country_discovered[base + tech / 64] |= bit;
        return;
    }
    const int32_t reveal_begin = _technology_reveal_condition_offsets[static_cast<size_t>(tech)];
    const int32_t reveal_end = _technology_reveal_condition_offsets[static_cast<size_t>(tech + 1)];
    if (reveal_end > reveal_begin && !reveal_condition_met(slot, tech)) return;
    const int32_t begin = _technology_prerequisite_offsets[static_cast<size_t>(tech)];
    const int32_t end = _technology_prerequisite_offsets[static_cast<size_t>(tech + 1)];
    const int32_t milestone_begin = _technology_milestone_offsets[static_cast<size_t>(tech)];
    const int32_t milestone_end = _technology_milestone_offsets[static_cast<size_t>(tech + 1)];
    bool reveal = false;
    if (milestone_end > milestone_begin) {
        for (int32_t edge = milestone_begin; edge < milestone_end && !reveal; ++edge) {
            const int32_t candidate = _technology_milestone_candidates[static_cast<size_t>(edge)];
            reveal = (_country_technologies[base + candidate / 64] &
                      (uint64_t{1} << (candidate % 64))) != 0;
        }
    } else {
        for (int32_t edge = begin; edge < end && !reveal; ++edge) {
            const int32_t prerequisite = _technology_prerequisites[static_cast<size_t>(edge)];
            reveal = (_country_technologies[base + prerequisite / 64] &
                      (uint64_t{1} << (prerequisite % 64))) != 0;
        }
    }
    if (reveal || (reveal_end > reveal_begin && reveal_condition_met(slot, tech)))
        _country_discovered[base + tech / 64] |= bit;
}

void NativeCountryRuntime::refresh_discovery_for_signal(int32_t slot, int32_t signal) {
    if (signal < 0 || signal + 1 >= static_cast<int32_t>(_technology_reveal_signal_offsets.size()))
        return;
    const int32_t begin = _technology_reveal_signal_offsets[static_cast<size_t>(signal)];
    const int32_t end = _technology_reveal_signal_offsets[static_cast<size_t>(signal + 1)];
    for (int32_t cursor = begin; cursor < end; ++cursor)
        refresh_discovery_for_technology(slot,
            _technology_reveal_signal_technologies[static_cast<size_t>(cursor)]);
}

void NativeCountryRuntime::refresh_discovery(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
        refresh_discovery_for_technology(slot, tech);
    }
}

int64_t NativeCountryRuntime::progress_for(int32_t slot, int32_t technology) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_country_research_progress.size())) return 0;
    const auto &entries = _country_research_progress[static_cast<size_t>(slot)];
    const auto it = std::lower_bound(entries.begin(), entries.end(), technology,
        [](const std::pair<int32_t, int64_t> &entry, int32_t value) {
            return entry.first < value;
        });
    return it != entries.end() && it->first == technology ? it->second : 0;
}

void NativeCountryRuntime::set_progress(int32_t slot, int32_t technology, int64_t value) {
    auto &entries = _country_research_progress[static_cast<size_t>(slot)];
    const auto it = std::lower_bound(entries.begin(), entries.end(), technology,
        [](const std::pair<int32_t, int64_t> &entry, int32_t needle) {
            return entry.first < needle;
        });
    if (it != entries.end() && it->first == technology) {
        if (value <= 0) entries.erase(it);
        else it->second = value;
    } else if (value > 0) {
        entries.insert(it, {technology, value});
    }
}

int64_t NativeCountryRuntime::effective_research_cost(
        int32_t slot, int32_t technology) const {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_costs.size()))
        return 1;
    double cost_factor = 1.0;
    if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
        cost_factor = _modifier_runtime->effective_value(
            ModifierRuntime::COUNTRY, "country.research.cost_factor",
            make_handle(slot), 0, 1.0);
    }
    return std::max<int64_t>(1, static_cast<int64_t>(std::llround(
        static_cast<double>(_technology_costs[static_cast<size_t>(technology)]) *
        cost_factor)));
}

bool NativeCountryRuntime::finalize_research_head_if_complete(
        int32_t slot, int32_t domain, int64_t day_index,
        bool use_pending_queue) {
    if (slot < 0 || domain < 0 || domain >= 4) return false;
    const size_t length_index = static_cast<size_t>(slot) * 4U +
        static_cast<size_t>(domain);
    uint8_t &length = _country_research_queue_lengths[length_index];
    if (length == 0) return false;
    const size_t queue_base = length_index * 8U;
    const int32_t technology = _country_research_queues[queue_base];
    if (technology < 0 || has_technology(slot, technology) ||
        !prerequisites_met(slot, technology) ||
        progress_for(slot, technology) < effective_research_cost(slot, technology))
        return false;

    const size_t word_index = static_cast<size_t>(slot) * _technology_words +
        static_cast<size_t>(technology / 64);
    const uint64_t bit = uint64_t{1} << (technology % 64);
    _country_pending_technologies[word_index] |= bit;
    if (use_pending_queue) insert_pending_activation(slot, technology);
    const std::string &modifier_key =
        _technology_modifier_definition_keys[static_cast<size_t>(technology)];
    if (!modifier_key.empty())
        ensure_technology_effect_instance(slot, technology, day_index);
    ++_country_research_completed_total[static_cast<size_t>(slot)];
    for (int32_t i = 1; i < length; ++i)
        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
            _country_research_queues[queue_base + static_cast<size_t>(i)];
    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
    return true;
}

int32_t NativeCountryRuntime::country_slot_for_cell(int32_t cell) const {
    return cell >= 0 && cell < _cell_count ? _cell_country_slot[static_cast<size_t>(cell)] : NEUTRAL_SLOT;
}

int64_t NativeCountryRuntime::country_handle_for_cell(int32_t cell) const {
    const int32_t slot = country_slot_for_cell(cell);
    return slot < 0 ? 0 : static_cast<int64_t>(make_handle(slot));
}

bool NativeCountryRuntime::valid_handle(int64_t handle) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(handle), slot);
}

int64_t NativeCountryRuntime::total_cash() const {
    int64_t total = 0;
    for (size_t i = 0; i < _countries.cash.size(); ++i) {
        if (_countries.active[i] == 0) continue;
        if (_countries.cash[i] > 0 && total > std::numeric_limits<int64_t>::max() - _countries.cash[i])
            return std::numeric_limits<int64_t>::max();
        total += _countries.cash[i];
    }
    return total;
}

int64_t NativeCountryRuntime::cash_for_slot(int32_t country_slot) const {
    return country_slot >= 0 &&
           country_slot < static_cast<int32_t>(_countries.active.size()) &&
           _countries.active[static_cast<size_t>(country_slot)] != 0
        ? _countries.cash[static_cast<size_t>(country_slot)] : 0;
}

int64_t NativeCountryRuntime::total_good(int32_t good_id) const {
    if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size())) return 0;
    int64_t total = 0;
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        if (_countries.active[slot] == 0) continue;
        const int64_t value = _country_goods[slot * _good_ids.size() + static_cast<size_t>(good_id)];
        if (value > 0 && total > std::numeric_limits<int64_t>::max() - value) return std::numeric_limits<int64_t>::max();
        total += value;
    }
    return total;
}

int64_t NativeCountryRuntime::research_consumed_total() const {
    int64_t total = 0;
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        if (_countries.active[slot] == 0 ||
            slot >= _country_research_consumed_total.size()) continue;
        const int64_t value = _country_research_consumed_total[slot];
        if (value > 0 && total > std::numeric_limits<int64_t>::max() - value)
            return std::numeric_limits<int64_t>::max();
        total += value;
    }
    return total;
}

bool NativeCountryRuntime::ack_chain_due(int64_t day_index) const {
    if (_effect_runtime_enabled && _effect_runtime != nullptr &&
        _effect_runtime->should_run(day_index))
        return true;
    return _modifier_runtime != nullptr && _modifier_runtime->configured() &&
        _modifier_runtime->should_run(day_index);
}

bool NativeCountryRuntime::ensure_technology_effect_instance(
        int32_t slot, int32_t technology, int64_t day_index) {
    if (!_effect_runtime_enabled || _effect_runtime == nullptr) return false;
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()))
        return false;
    const uint64_t handle = make_handle(slot);
    const int64_t effect_instance_id = static_cast<int64_t>(
        ((handle & 0x00007fffffffffffULL) << 16U) |
        static_cast<uint64_t>(technology + 1));
    const uint32_t effect_generation = static_cast<uint32_t>(handle >> 32U);
    if (effect_instance_id <= 0 || effect_generation == 0) return false;
    if (_effect_runtime->has_instance_pod(effect_instance_id, effect_generation)) {
        // Existing pending nodes must be re-queued. Skip-if-exists alone left
        // unacked instances (cadence 3650 / consumed due heap / REJECTED ACK)
        // pending forever after a missed Effect morning.
        _effect_runtime->nudge_unacked_instance_pod(
            effect_instance_id, effect_generation, day_index);
        return true;
    }
    std::string effect_error;
    return _effect_runtime->upsert_instance_pod(
        effect_instance_id,
        std::string("technology.") + _technology_ids[static_cast<size_t>(technology)],
        effect_generation, 0x54454348, technology + 1,
        handle, handle, effect_generation, 0,
        day_index, true, effect_error);
}

int32_t NativeCountryRuntime::run_research_day(int64_t day_index) {
    if (_technology_points_good_id < 0) return 0;
    // Research allocation is once per day, but pending technologies may be
    // ACKed by Effect/Modifier later in the same day. Keep the activation
    // pass live for same-day continuations instead of making the completed
    // node wait for a new research command or the next calendar day.
    const bool research_due = day_index > _last_research_day;
    bool use_pending_queue = _pending_queue_enabled;
    bool pending_queue_fallback = false;
    if (use_pending_queue && _pending_activation_index_dirty)
        rebuild_pending_activation_index();
    // The parity check is transient diagnostics only.  It walks the compact
    // pending bitset, never the research conditions or full technology graph,
    // and therefore does not affect the LIGHT production hot path.
    if (use_pending_queue && _full_diagnostics &&
        !validate_pending_activation_index()) {
        use_pending_queue = false;
        // The configured feature flag remains enabled.  A parity failure is
        // a one-day safety fallback: the authoritative pending bitset is still
        // consumed by the deterministic full scan, then the compact index is
        // rebuilt so the next research day can automatically recover.
        pending_queue_fallback = true;
        _research_queue_fallback_reason = "pending_queue_mismatch";
        _pending_activation_index_dirty = true;
    }
    if (pending_queue_fallback) ++_research_full_scan_fallbacks;
    int32_t changed = 0;
    for (int32_t slot = 0; slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        if (_countries.active[static_cast<size_t>(slot)] == 0) continue;
        const size_t word_base = static_cast<size_t>(slot) * _technology_words;
        bool activated = false;
        std::vector<int32_t> activated_pending;
        const int32_t candidate_count = use_pending_queue
            ? static_cast<int32_t>(
                _pending_activation_indices[static_cast<size_t>(slot)].size())
            : static_cast<int32_t>(_technology_ids.size());
        for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
            const int32_t technology = use_pending_queue
                ? _pending_activation_indices[static_cast<size_t>(slot)][
                    static_cast<size_t>(candidate)]
                : candidate;
            const size_t word_index = word_base + technology / 64;
            const uint64_t bit = 1ULL << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) == 0) continue;
            const std::string &technology_modifier_key =
                _technology_modifier_definition_keys[static_cast<size_t>(technology)];
            bool modifier_ready = technology_modifier_key.empty();
            const uint64_t handle = make_handle(slot);
            if (_effect_runtime_enabled && _effect_runtime != nullptr &&
                !technology_modifier_key.empty()) {
                const int64_t effect_instance_id = static_cast<int64_t>(
                    ((handle & 0x00007fffffffffffULL) << 16U) |
                    static_cast<uint64_t>(technology + 1));
                const uint32_t effect_generation = static_cast<uint32_t>(handle >> 32U);
                const bool effect_registered =
                    ensure_technology_effect_instance(slot, technology, day_index);
                const bool fire_acked = effect_registered &&
                    _effect_runtime->instance_fire_acked_pod(
                        effect_instance_id, effect_generation);
                const bool modifier_applied =
                    _modifier_runtime != nullptr && _modifier_runtime->configured() &&
                    _modifier_runtime->has_technology_effect(
                        handle, technology_modifier_key, technology);
                modifier_ready = fire_acked || modifier_applied;
            }
            if (!modifier_ready &&
                (!_effect_runtime_enabled || _effect_runtime == nullptr) &&
                _modifier_runtime != nullptr && _modifier_runtime->configured() &&
                !technology_modifier_key.empty()) {
                // Legacy configurations without EffectRuntime retain their
                // direct idempotent path. Once EffectRuntime is authoritative,
                // activation must wait for its cross-domain ACK chain.
                std::string modifier_error;
                modifier_ready = _modifier_runtime->apply_technology_effect(
                    handle, technology_modifier_key, technology, day_index, modifier_error);
            }
            if (!modifier_ready) continue;
            _country_technologies[word_index] |= bit;
            _country_pending_technologies[word_index] &= ~bit;
            if (use_pending_queue)
                activated_pending.push_back(technology);
            // Era rewards are emitted only after the technology's permanent
            // Effect has ACKed and the completed bit becomes authoritative.
            // Research progress reaching its cost never enters this hook.
            if (_effect_runtime_enabled && _effect_runtime != nullptr) {
                std::string reward_error;
                _effect_runtime->notify_era_reward_technology_activated_pod(
                    handle, technology, day_index, reward_error);
                if (!reward_error.empty())
                    _report["era_reward_error"] = String(reward_error.c_str());
                if (_economy_runtime != nullptr)
                    _economy_runtime->notify_era_milestone_activated(
                        static_cast<uint64_t>(handle));
            }
            activated = true;
        }
        for (const int32_t technology : activated_pending)
            erase_pending_activation(slot, technology);
        if (activated) {
            refresh_discovery(slot);
            _country_research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++_countries.state_version[static_cast<size_t>(slot)];
            ++changed;
        }

        // Completion is a state transition, not a technology-points
        // purchase. If the final fractional unit was consumed on the
        // previous day, the treasury may now be empty even though the queue
        // head is complete. Finalize such heads before the stock early exit.
        for (int32_t domain = 0; domain < 4; ++domain) {
            while (finalize_research_head_if_complete(
                    slot, domain, day_index, use_pending_queue)) {
                ++_countries.state_version[static_cast<size_t>(slot)];
                ++changed;
            }
        }

        int64_t &stock = _country_goods[
            static_cast<size_t>(slot) * _good_ids.size() +
            static_cast<size_t>(_technology_points_good_id)];
        if (!research_due) continue;
        const int64_t prior_deferred = std::min(
            _country_research_deferred_points[static_cast<size_t>(slot)], stock);
        const int64_t available = stock - prior_deferred;
        if (available <= 0) continue;

        int64_t shares[4] = {0, 0, 0, 0};
        int64_t remainders[4] = {0, 0, 0, 0};
        int64_t assigned = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            const int32_t weight = _country_research_weights_bp[
                static_cast<size_t>(slot) * 4U + static_cast<size_t>(domain)];
            const int64_t quotient = available / 10000;
            const int64_t remainder = available % 10000;
            shares[domain] = quotient * weight + (remainder * weight) / 10000;
            remainders[domain] = (remainder * weight) % 10000;
            assigned += shares[domain];
        }
        for (int64_t remainder_units = available - assigned; remainder_units > 0; --remainder_units) {
            int32_t winner = 0;
            for (int32_t domain = 1; domain < 4; ++domain)
                if (remainders[domain] > remainders[winner]) winner = domain;
            ++shares[winner];
            remainders[winner] = -1;
        }

        int64_t consumed = 0;
        int64_t newly_deferred = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            int64_t domain_points = shares[domain];
            const size_t length_index = static_cast<size_t>(slot) * 4U +
                static_cast<size_t>(domain);
            const uint8_t initial_length =
                _country_research_queue_lengths[length_index];
            while (domain_points > 0) {
                uint8_t &length = _country_research_queue_lengths[length_index];
                if (length == 0) break;
                const size_t queue_base = (static_cast<size_t>(slot) * 4U +
                    static_cast<size_t>(domain)) * 8U;
                const int32_t technology = _country_research_queues[queue_base];
                if (technology < 0 || has_technology(slot, technology)) {
                    for (int32_t i = 1; i < length; ++i)
                        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
                            _country_research_queues[queue_base + static_cast<size_t>(i)];
                    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                    continue;
                }
                if (!prerequisites_met(slot, technology)) break;
                const int64_t progress = progress_for(slot, technology);
                double efficiency = 1.0;
                if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
                    static const char *EFFICIENCY_STATS[4] = {
                        "country.research.agriculture_efficiency",
                        "country.research.engineering_efficiency",
                        "country.research.science_efficiency",
                        "country.research.society_efficiency",
                    };
                    efficiency = _modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY, EFFICIENCY_STATS[domain],
                        make_handle(slot), 0, 1.0);
                }
                const int64_t effective_cost = effective_research_cost(slot, technology);
                const int64_t remaining = std::max<int64_t>(
                    0, effective_cost - progress);
                const int64_t spend_needed = std::max<int64_t>(
                    1, static_cast<int64_t>(std::ceil(
                        static_cast<double>(remaining) /
                        std::max(0.000001, efficiency))));
                const int64_t spend = std::min(domain_points, spend_needed);
                const int64_t progress_gain = std::min<int64_t>(
                    remaining, std::max<int64_t>(1, static_cast<int64_t>(
                        std::floor(static_cast<double>(spend) * efficiency))));
                set_progress(slot, technology, progress + progress_gain);
                domain_points -= spend;
                consumed += spend;
                _country_research_progress_total[static_cast<size_t>(slot)] += progress_gain;
                if (progress + progress_gain >= effective_cost) {
                    _country_pending_technologies[word_base + technology / 64] |=
                        1ULL << (technology % 64);
                    if (use_pending_queue)
                        insert_pending_activation(slot, technology);
                    // Register the Effect instance on the completion day so the
                    // next morning's Effect job (priority 85) can fire before
                    // Country (255) checks ACK. Waiting until the activation
                    // loop would miss that slot and leave the node pending.
                    // Content-only leftover nodes have empty modifier keys; their
                    // unlocks are catalog tags, not Effect ACK. Instantiating the
                    // adopted-only recipe left native_country_ack_pending forever.
                    const std::string &completed_modifier_key =
                        _technology_modifier_definition_keys[static_cast<size_t>(technology)];
                    if (!completed_modifier_key.empty())
                        ensure_technology_effect_instance(slot, technology, day_index);
                    ++_country_research_completed_total[static_cast<size_t>(slot)];
                    for (int32_t i = 1; i < length; ++i)
                        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
                            _country_research_queues[queue_base + static_cast<size_t>(i)];
                    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                } else {
                    break;
                }
            }
            // Empty domains leave unused shares in the treasury so later days
            // can still fund queued domains at the current weights. Parking
            // those shares as deferred stock made available=0 after one day,
            // which froze progress unless the player maxed a domain weight.
            // A domain that actually had queue work (blocked head or leftover
            // after completion) still parks its remainder.
            if (initial_length > 0)
                newly_deferred += domain_points;
        }
        if (consumed > 0) {
            stock -= consumed;
            _country_research_consumed_total[static_cast<size_t>(slot)] += consumed;
            ++_countries.state_version[static_cast<size_t>(slot)];
            if (!activated) ++changed;
        }
        _country_research_deferred_points[static_cast<size_t>(slot)] =
            std::min(stock, prior_deferred + newly_deferred);
    }
    if (pending_queue_fallback) {
        // Full-scan mutations intentionally bypass incremental queue updates.
        // Rebuild from the authoritative pending bits before publishing this
        // day so the queue is valid and deterministic on the following day.
        _pending_activation_index_dirty = true;
        rebuild_pending_activation_index();
    } else if (use_pending_queue &&
               _research_queue_fallback_reason == "pending_queue_mismatch") {
        // A clean parity check after a previous one-day fallback clears the
        // transient diagnostic marker without changing authority or hashes.
        _research_queue_fallback_reason.clear();
    }
    if (research_due) _last_research_day = day_index;
    if (changed > 0) ++_generation;
    return changed;
}

int64_t NativeCountryRuntime::transfer_cash_to_cohort(int64_t country_handle, int64_t requested) {
    int32_t slot = -1;
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t moved = std::min(requested, _countries.cash[static_cast<size_t>(slot)]);
    _countries.cash[static_cast<size_t>(slot)] -= moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

int64_t NativeCountryRuntime::cash_for_handle(int64_t country_handle) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(country_handle), slot)
        ? _countries.cash[static_cast<size_t>(slot)] : 0;
}

int64_t NativeCountryRuntime::good_for_handle(int64_t country_handle,
                                               int32_t good_id) const {
    int32_t slot = -1;
    if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    return _country_goods[static_cast<size_t>(slot) * _good_ids.size() +
                          static_cast<size_t>(good_id)];
}

bool NativeCountryRuntime::spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash) {
    int32_t slot = -1;
    if (cash < 0 || (good_count > 0 && (good_ids == nullptr || quantities == nullptr)) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return false;
    if (_countries.cash[static_cast<size_t>(slot)] < cash) return false;
    const size_t base = static_cast<size_t>(slot) * _good_ids.size();
    for (size_t i = 0; i < good_count; ++i) {
        if (good_ids[i] < 0 || good_ids[i] >= static_cast<int32_t>(_good_ids.size()) ||
            quantities[i] < 0 ||
            _country_goods[base + static_cast<size_t>(good_ids[i])] < quantities[i]) {
            return false;
        }
        for (size_t prior = 0; prior < i; ++prior) {
            if (good_ids[prior] == good_ids[i]) return false;
        }
    }
    bool any_goods = false;
    for (size_t i = 0; i < good_count; ++i) any_goods = any_goods || quantities[i] != 0;
    if (cash == 0 && !any_goods) return true;
    _countries.cash[static_cast<size_t>(slot)] -= cash;
    for (size_t i = 0; i < good_count; ++i) {
        _country_goods[base + static_cast<size_t>(good_ids[i])] -= quantities[i];
    }
    ++_countries.state_version[static_cast<size_t>(slot)];
    ++_generation;
    return true;
}

int64_t NativeCountryRuntime::transfer_cash_from_cohort(int64_t country_handle, int64_t offered) {
    int32_t slot = -1;
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t room = std::numeric_limits<int64_t>::max() - _countries.cash[static_cast<size_t>(slot)];
    const int64_t moved = std::min(offered, room);
    _countries.cash[static_cast<size_t>(slot)] += moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

int64_t NativeCountryRuntime::reserve_fiscal_cash(int64_t country_handle,
                                                   int64_t requested) {
    return transfer_cash_to_cohort(country_handle, requested);
}

int64_t NativeCountryRuntime::return_fiscal_cash(int64_t country_handle,
                                                  int64_t offered) {
    return transfer_cash_from_cohort(country_handle, offered);
}

int64_t NativeCountryRuntime::collect_fiscal_cash(int64_t country_handle,
                                                   int64_t offered) {
    return transfer_cash_from_cohort(country_handle, offered);
}

int64_t NativeCountryRuntime::transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                                       int64_t requested) {
    int32_t slot = -1;
    if (requested <= 0 || good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    int64_t &stock = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + static_cast<size_t>(good_id)];
    const int64_t moved = std::min(requested, stock);
    stock -= moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

int64_t NativeCountryRuntime::transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                                         int64_t offered) {
    int32_t slot = -1;
    if (offered <= 0 || good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    int64_t &stock = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + static_cast<size_t>(good_id)];
    const int64_t moved = std::min(offered, std::numeric_limits<int64_t>::max() - stock);
    stock += moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

bool NativeCountryRuntime::copy_economy_snapshot(EconomySnapshot &out) const {
    if (!economy_available()) return false;
    out.cell_country_slot = _cell_country_slot;
    out.country_handles.resize(_countries.active.size());
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        out.country_handles[slot] = _countries.active[slot] != 0
            ? make_handle(static_cast<int32_t>(slot)) : 0;
    }
    out.country_technologies = _country_technologies;
    out.country_count = static_cast<int32_t>(_countries.active.size());
    out.technology_words = _technology_words;
    out.profession_count = static_cast<int32_t>(_profession_ids.size());
    out.good_count = static_cast<int32_t>(_good_ids.size());
    out.building_type_count =
        static_cast<int32_t>(_building_type_ids.size());
    auto resolve_all = [&](int32_t kind,
                           const std::vector<int8_t> &overrides,
                           std::vector<int8_t> &rates) {
        const int32_t item_count = tax_item_count(kind);
        rates.resize(static_cast<size_t>(out.country_count) * item_count);
        for (int32_t slot = 0; slot < out.country_count; ++slot) {
            for (int32_t item = 0; item < item_count; ++item) {
                rates[static_cast<size_t>(slot) * item_count + item] =
                    resolved_tax_rate(_country_tax_defaults, overrides, slot,
                                      kind, item, item_count);
            }
        }
    };
    resolve_all(TAX_INCOME, _country_income_tax_overrides,
                out.income_tax_rates);
    resolve_all(TAX_CONSUMPTION, _country_consumption_tax_overrides,
                out.consumption_tax_rates);
    resolve_all(TAX_BUSINESS, _country_business_tax_overrides,
                out.business_tax_rates);
    resolve_all(TAX_IMPORT, _country_import_tax_overrides,
                out.import_tax_rates);
    resolve_all(TAX_EXPORT, _country_export_tax_overrides,
                out.export_tax_rates);
    out.cell_tax_policy_ids = _cell_tax_policy_ids;
    out.cell_tax_policies = _cell_tax_policies;
    out.tax_policy_version = _tax_policy_version;
    out.generation = _generation;
    out.state_hash = compute_state_hash();
    return true;
}

uint64_t NativeCountryRuntime::catalog_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_technology_catalog_identity_hash,
               sizeof(_technology_catalog_identity_hash));
    hash_bytes(hash, &_technology_content_binding_hash,
               sizeof(_technology_content_binding_hash));
    hash_bytes(hash, &_technology_trigger_definition_hash,
               sizeof(_technology_trigger_definition_hash));
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _profession_ids) hash_string(hash, id);
    for (const std::string &id : _building_type_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
    for (const std::string &id : _technology_era_reward_pool_ids)
        hash_string(hash, id);
    for (const std::string &id : _research_signal_ids) hash_string(hash, id);
    if (!_technology_domains.empty())
        hash_bytes(hash, _technology_domains.data(), _technology_domains.size() * sizeof(int32_t));
    if (!_technology_costs.empty())
        hash_bytes(hash, _technology_costs.data(), _technology_costs.size() * sizeof(int64_t));
    if (!_technology_prerequisite_offsets.empty())
        hash_bytes(hash, _technology_prerequisite_offsets.data(),
                   _technology_prerequisite_offsets.size() * sizeof(int32_t));
    if (!_technology_prerequisites.empty())
        hash_bytes(hash, _technology_prerequisites.data(),
                   _technology_prerequisites.size() * sizeof(int32_t));
    if (!_technology_entry_milestone_indices.empty())
        hash_bytes(hash, _technology_entry_milestone_indices.data(),
                   _technology_entry_milestone_indices.size() * sizeof(int32_t));
    if (!_research_signal_requires_provenance.empty())
        hash_bytes(hash, _research_signal_requires_provenance.data(),
                   _research_signal_requires_provenance.size() * sizeof(uint8_t));
    if (!_technology_research_condition_offsets.empty())
        hash_bytes(hash, _technology_research_condition_offsets.data(),
                   _technology_research_condition_offsets.size() * sizeof(int32_t));
    if (!_technology_research_condition_ops.empty())
        hash_bytes(hash, _technology_research_condition_ops.data(),
                   _technology_research_condition_ops.size() * sizeof(int32_t));
    if (!_technology_research_condition_refs.empty())
        hash_bytes(hash, _technology_research_condition_refs.data(),
                   _technology_research_condition_refs.size() * sizeof(int32_t));
    if (!_technology_research_condition_values.empty())
        hash_bytes(hash, _technology_research_condition_values.data(),
                   _technology_research_condition_values.size() * sizeof(int64_t));
    if (!_technology_reveal_condition_offsets.empty())
        hash_bytes(hash, _technology_reveal_condition_offsets.data(),
                   _technology_reveal_condition_offsets.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_ops.empty())
        hash_bytes(hash, _technology_reveal_condition_ops.data(),
                   _technology_reveal_condition_ops.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_refs.empty())
        hash_bytes(hash, _technology_reveal_condition_refs.data(),
                   _technology_reveal_condition_refs.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_values.empty())
        hash_bytes(hash, _technology_reveal_condition_values.data(),
                   _technology_reveal_condition_values.size() * sizeof(int64_t));
    if (!_technology_reveal_signal_offsets.empty())
        hash_bytes(hash, _technology_reveal_signal_offsets.data(),
                   _technology_reveal_signal_offsets.size() * sizeof(int32_t));
    if (!_technology_reveal_signal_technologies.empty())
        hash_bytes(hash, _technology_reveal_signal_technologies.data(),
                   _technology_reveal_signal_technologies.size() * sizeof(int32_t));
    return hash;
}

uint64_t NativeCountryRuntime::compute_state_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_generation, sizeof(_generation));
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        hash_bytes(hash, &_countries.active[slot], sizeof(uint8_t));
        hash_bytes(hash, &_countries.generation[slot], sizeof(uint32_t));
        hash_string(hash, _countries.stable_id[slot]);
        hash_string(hash, _countries.display_name[slot]);
        hash_bytes(hash, &_countries.territory_count[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.cash[slot], sizeof(int64_t));
        hash_bytes(hash, &_countries.state_version[slot], sizeof(uint64_t));
    }
    if (!_cell_country_slot.empty()) hash_bytes(hash, _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty()) hash_bytes(hash, _country_technologies.data(), _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty()) hash_bytes(hash, _country_goods.data(), _country_goods.size() * sizeof(int64_t));
    if (!_country_discovered.empty()) hash_bytes(hash, _country_discovered.data(), _country_discovered.size() * sizeof(uint64_t));
    if (!_country_pending_technologies.empty()) hash_bytes(hash, _country_pending_technologies.data(), _country_pending_technologies.size() * sizeof(uint64_t));
    if (!_country_research_signals.empty())
        hash_bytes(hash, _country_research_signals.data(),
                   _country_research_signals.size() * sizeof(uint64_t));
    for (const auto &cells : _country_research_signal_cells)
        if (!cells.empty()) hash_bytes(hash, cells.data(), cells.size() * sizeof(uint64_t));
    for (const auto &entries : _country_research_signal_evidence)
        for (const SignalEvidence &entry : entries)
            // Hash fields individually: native struct padding is not stable across
            // construction/restore and must never affect a persisted-state hash.
            hash_bytes(hash, &entry.signal, sizeof(entry.signal)),
            hash_bytes(hash, &entry.count, sizeof(entry.count)),
            hash_bytes(hash, &entry.first_day, sizeof(entry.first_day)),
            hash_bytes(hash, &entry.last_day, sizeof(entry.last_day)),
            hash_bytes(hash, &entry.first_cell, sizeof(entry.first_cell));
    if (!_country_research_queues.empty()) hash_bytes(hash, _country_research_queues.data(), _country_research_queues.size() * sizeof(int32_t));
    if (!_country_research_queue_lengths.empty()) hash_bytes(hash, _country_research_queue_lengths.data(), _country_research_queue_lengths.size() * sizeof(uint8_t));
    if (!_country_research_weights_bp.empty()) hash_bytes(hash, _country_research_weights_bp.data(), _country_research_weights_bp.size() * sizeof(int32_t));
    if (!_country_research_daily_budgets.empty()) hash_bytes(hash, _country_research_daily_budgets.data(), _country_research_daily_budgets.size() * sizeof(int64_t));
    if (!_country_research_deferred_points.empty()) hash_bytes(hash, _country_research_deferred_points.data(), _country_research_deferred_points.size() * sizeof(int64_t));
    if (!_country_tax_defaults.empty())
        hash_bytes(hash, _country_tax_defaults.data(),
                   _country_tax_defaults.size() * sizeof(int8_t));
    if (!_country_income_tax_overrides.empty())
        hash_bytes(hash, _country_income_tax_overrides.data(),
                   _country_income_tax_overrides.size() * sizeof(int8_t));
    if (!_country_consumption_tax_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_overrides.data(),
                   _country_consumption_tax_overrides.size() * sizeof(int8_t));
    if (!_country_business_tax_overrides.empty())
        hash_bytes(hash, _country_business_tax_overrides.data(),
                   _country_business_tax_overrides.size() * sizeof(int8_t));
    if (!_country_import_tax_overrides.empty())
        hash_bytes(hash, _country_import_tax_overrides.data(),
                   _country_import_tax_overrides.size() * sizeof(int8_t));
    if (!_country_export_tax_overrides.empty())
        hash_bytes(hash, _country_export_tax_overrides.data(),
                   _country_export_tax_overrides.size() * sizeof(int8_t));
    uint64_t cell_policy_count = 0;
    for (uint32_t id : _cell_tax_policy_ids)
        if (!cell_tax_policy(id).empty()) ++cell_policy_count;
    hash_bytes(hash, &cell_policy_count, sizeof(cell_policy_count));
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const CellTaxPolicy &policy = cell_tax_policy(
            _cell_tax_policy_ids[static_cast<size_t>(cell)]);
        if (policy.empty()) continue;
        hash_bytes(hash, &cell, sizeof(cell));
        hash_bytes(hash, policy.defaults.data(), policy.defaults.size());
        const uint64_t entry_count = policy.overrides.size();
        hash_bytes(hash, &entry_count, sizeof(entry_count));
        for (const CellTaxOverride &entry : policy.overrides) {
            hash_bytes(hash, &entry.kind, sizeof(entry.kind));
            hash_string(hash, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            hash_bytes(hash, &entry.rate, sizeof(entry.rate));
        }
    }
    hash_bytes(hash, &_tax_policy_version, sizeof(_tax_policy_version));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    hash_bytes(hash, &_era_reward_reference.plan_id,
               sizeof(_era_reward_reference.plan_id));
    hash_bytes(hash, &_era_reward_reference.offer_generation,
               sizeof(_era_reward_reference.offer_generation));
    hash_bytes(hash, &_era_reward_reference.milestone_technology,
               sizeof(_era_reward_reference.milestone_technology));
    hash_bytes(hash, &_era_reward_reference.status,
               sizeof(_era_reward_reference.status));
    return hash;
}

int32_t NativeCountryRuntime::research_signal_evidence_count(
        int32_t country_slot, int32_t signal_id) const {
    return signal_count(country_slot, signal_id);
}

void NativeCountryRuntime::set_era_reward_reference_pod(
        int64_t plan_id, int64_t offer_generation,
        int32_t milestone_technology, int32_t status) {
    _era_reward_reference.plan_id = plan_id;
    _era_reward_reference.offer_generation = offer_generation;
    _era_reward_reference.milestone_technology = milestone_technology;
    _era_reward_reference.status = status;
    _state_hash_cache_valid = false;
}

uint64_t NativeCountryRuntime::catalog_hash_v3() const {
    uint64_t hash = FNV_OFFSET;
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
    if (!_technology_domains.empty())
        hash_bytes(hash, _technology_domains.data(),
                   _technology_domains.size() * sizeof(int32_t));
    if (!_technology_costs.empty())
        hash_bytes(hash, _technology_costs.data(),
                   _technology_costs.size() * sizeof(int64_t));
    if (!_technology_prerequisite_offsets.empty())
        hash_bytes(hash, _technology_prerequisite_offsets.data(),
                   _technology_prerequisite_offsets.size() *
                       sizeof(int32_t));
    if (!_technology_prerequisites.empty())
        hash_bytes(hash, _technology_prerequisites.data(),
                   _technology_prerequisites.size() * sizeof(int32_t));
    if (!_technology_entry_milestone_indices.empty())
        hash_bytes(hash, _technology_entry_milestone_indices.data(),
                   _technology_entry_milestone_indices.size() * sizeof(int32_t));
    return hash;
}

int64_t NativeCountryRuntime::state_hash_v3_compat() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_generation, sizeof(_generation));
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        hash_bytes(hash, &_countries.active[slot], sizeof(uint8_t));
        hash_bytes(hash, &_countries.generation[slot], sizeof(uint32_t));
        hash_string(hash, _countries.stable_id[slot]);
        hash_string(hash, _countries.display_name[slot]);
        hash_bytes(hash, &_countries.territory_count[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.cash[slot], sizeof(int64_t));
        hash_bytes(hash, &_countries.state_version[slot], sizeof(uint64_t));
    }
    if (!_cell_country_slot.empty())
        hash_bytes(hash, _cell_country_slot.data(),
                   _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty())
        hash_bytes(hash, _country_technologies.data(),
                   _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty())
        hash_bytes(hash, _country_goods.data(),
                   _country_goods.size() * sizeof(int64_t));
    if (!_country_discovered.empty())
        hash_bytes(hash, _country_discovered.data(),
                   _country_discovered.size() * sizeof(uint64_t));
    if (!_country_pending_technologies.empty())
        hash_bytes(hash, _country_pending_technologies.data(),
                   _country_pending_technologies.size() * sizeof(uint64_t));
    if (!_country_research_queues.empty())
        hash_bytes(hash, _country_research_queues.data(),
                   _country_research_queues.size() * sizeof(int32_t));
    if (!_country_research_queue_lengths.empty())
        hash_bytes(hash, _country_research_queue_lengths.data(),
                   _country_research_queue_lengths.size() * sizeof(uint8_t));
    if (!_country_research_weights_bp.empty())
        hash_bytes(hash, _country_research_weights_bp.data(),
                   _country_research_weights_bp.size() * sizeof(int32_t));
    if (!_country_research_daily_budgets.empty())
        hash_bytes(hash, _country_research_daily_budgets.data(),
                   _country_research_daily_budgets.size() * sizeof(int64_t));
    if (!_country_research_deferred_points.empty())
        hash_bytes(hash, _country_research_deferred_points.data(),
                   _country_research_deferred_points.size() * sizeof(int64_t));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    return static_cast<int64_t>(hash);
}

int64_t NativeCountryRuntime::state_hash() const {
    const bool cache_matches = _state_hash_cache_valid &&
        _state_hash_cache_generation == _generation &&
        _state_hash_cache_research_day == _last_research_day &&
        _state_hash_cache_tax_policy_version == _tax_policy_version &&
        _state_hash_cache_era_reward.plan_id == _era_reward_reference.plan_id &&
        _state_hash_cache_era_reward.offer_generation == _era_reward_reference.offer_generation &&
        _state_hash_cache_era_reward.milestone_technology == _era_reward_reference.milestone_technology &&
        _state_hash_cache_era_reward.status == _era_reward_reference.status;
    if (!cache_matches) {
        _state_hash_cache = compute_state_hash();
        _state_hash_cache_generation = _generation;
        _state_hash_cache_research_day = _last_research_day;
        _state_hash_cache_tax_policy_version = _tax_policy_version;
        _state_hash_cache_era_reward = _era_reward_reference;
        _state_hash_cache_valid = true;
    }
    return static_cast<int64_t>(_state_hash_cache);
}

void NativeCountryRuntime::mark_slot_publication(bool published, double publish_ms,
                                                  const String &reason) {
    _report["published_to_slot"] = published;
    _report["slot_publish_ms"] = publish_ms;
    _report["aggregate_publish_ms"] =
        static_cast<double>(_report.get("aggregate_publish_ms", 0.0)) + publish_ms;
    _report["native_ms"] = static_cast<double>(_report.get("native_ms", 0.0)) + publish_ms;
    if (!reason.is_empty()) _report["publish_reason"] = reason;
    else _report.erase("publish_reason");
}

void NativeCountryRuntime::push_event(Event event) {
    event.event_id = static_cast<int64_t>(_next_event_id++);
    _events.push_back(std::move(event));
    while (_events.size() > 2048) _events.pop_front();
}

Dictionary NativeCountryRuntime::poll_events(int64_t after_event_id, int32_t limit) const {
    limit = std::clamp(limit, 1, 512);
    PackedInt64Array event_ids, days, handles;
    PackedInt32Array opcodes, cells, old_slots, new_slots, technologies, signals,
        signal_sources, evidence_deltas;
    PackedStringArray stable_ids, display_names;
    for (const Event &event : _events) {
        if (event.event_id <= after_event_id || event_ids.size() >= limit) continue;
        event_ids.push_back(event.event_id);
        days.push_back(event.day);
        handles.push_back(static_cast<int64_t>(event.country_handle));
        opcodes.push_back(event.opcode);
        cells.push_back(event.cell);
        old_slots.push_back(event.old_country_slot);
        new_slots.push_back(event.new_country_slot);
        technologies.push_back(event.technology_id);
        signals.push_back(event.signal_id);
        signal_sources.push_back(event.signal_source_kind);
        evidence_deltas.push_back(event.evidence_delta);
        stable_ids.push_back(event.stable_id.c_str());
        display_names.push_back(String::utf8(event.display_name.c_str()));
    }
    Dictionary out;
    out["ok"] = true;
    out["event_ids"] = event_ids;
    out["days"] = days;
    out["opcodes"] = opcodes;
    out["country_handles"] = handles;
    out["cells"] = cells;
    out["old_country_slots"] = old_slots;
    out["new_country_slots"] = new_slots;
    out["technology_ids"] = technologies;
    out["signal_ids"] = signals;
    out["signal_source_kinds"] = signal_sources;
    out["evidence_deltas"] = evidence_deltas;
    out["stable_ids"] = stable_ids;
    out["display_names"] = display_names;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

bool NativeCountryRuntime::encode_save(std::vector<uint8_t> &out, std::string &error) const {
    if (!_bootstrapped) { error = "country_save_not_bootstrapped"; return false; }
    if (_command_batch.active) { error = "country_save_requires_idle_command_graph"; return false; }
    if (std::any_of(_pending_commands.begin(), _pending_commands.end(),
            [&](const Command &command) {
                return command.effective_day <= _last_committed_day;
            }) || ack_chain_due(_last_committed_day)) {
        error = "country_save_requires_idle_command_graph";
        return false;
    }
    out.clear();
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, SCHEMA_VERSION);
    append_le<uint64_t>(out, catalog_hash());
    append_le<uint64_t>(out, _generation);
    append_le<int64_t>(out, _last_committed_day);
    append_le<uint64_t>(out, _submit_order);
    append_le<int32_t>(out, _cell_count);
    append_le<int32_t>(out, static_cast<int32_t>(_countries.active.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_good_ids.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_profession_ids.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_building_type_ids.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_technology_ids.size()));
    append_le<int32_t>(out, _technology_words);
    append_le<int32_t>(out, static_cast<int32_t>(_research_signal_ids.size()));
    append_le<int32_t>(out, _research_signal_words);
    for (const std::string &id : _good_ids) append_string(out, id);
    for (const std::string &id : _profession_ids) append_string(out, id);
    for (const std::string &id : _building_type_ids) append_string(out, id);
    for (const std::string &id : _technology_ids) append_string(out, id);
    for (const std::string &id : _research_signal_ids) append_string(out, id);
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        append_le<uint8_t>(out, _countries.active[slot]);
        append_le<uint32_t>(out, _countries.generation[slot]);
        append_string(out, _countries.stable_id[slot]);
        append_string(out, _countries.display_name[slot]);
        append_le<int32_t>(out, _countries.territory_count[slot]);
        append_le<int64_t>(out, _countries.cash[slot]);
        append_le<uint64_t>(out, _countries.state_version[slot]);
    }
    append_vector(out, _cell_country_slot);
    append_vector(out, _country_technologies);
    append_vector(out, _country_goods);
    append_vector(out, _country_discovered);
    append_vector(out, _country_pending_technologies);
    append_vector(out, _country_research_signals);
    append_le<uint64_t>(out, static_cast<uint64_t>(_country_research_signal_cells.size()));
    for (const auto &cells : _country_research_signal_cells)
        append_vector(out, cells);
    append_le<uint64_t>(out, static_cast<uint64_t>(_country_research_signal_evidence.size()));
    for (const auto &entries : _country_research_signal_evidence) {
        append_le<uint64_t>(out, static_cast<uint64_t>(entries.size()));
        for (const SignalEvidence &entry : entries) {
            append_le<int32_t>(out, entry.signal);
            append_le<int32_t>(out, entry.count);
            append_le<int64_t>(out, entry.first_day);
            append_le<int64_t>(out, entry.last_day);
            append_le<int32_t>(out, entry.first_cell);
        }
    }
    append_vector(out, _country_research_queues);
    append_vector(out, _country_research_queue_lengths);
    append_vector(out, _country_research_weights_bp);
    append_vector(out, _country_research_auto_purchase);
    append_vector(out, _country_research_daily_budgets);
    append_vector(out, _country_research_deferred_points);
    append_vector(out, _country_research_purchased_total);
    append_vector(out, _country_research_consumed_total);
    append_vector(out, _country_research_progress_total);
    append_vector(out, _country_research_completed_total);
    append_le<int64_t>(out, _last_research_day);
    append_le<uint64_t>(out, static_cast<uint64_t>(_country_research_progress.size()));
    for (const auto &entries : _country_research_progress) {
        append_le<uint64_t>(out, static_cast<uint64_t>(entries.size()));
        for (const auto &entry : entries) {
            append_le<int32_t>(out, entry.first);
            append_le<int64_t>(out, entry.second);
        }
    }
    append_vector(out, _country_tax_defaults);
    append_vector(out, _country_income_tax_overrides);
    append_vector(out, _country_consumption_tax_overrides);
    append_vector(out, _country_business_tax_overrides);
    append_vector(out, _country_import_tax_overrides);
    append_vector(out, _country_export_tax_overrides);
    append_le<uint64_t>(out, _tax_policy_version);
    uint64_t saved_cell_policy_count = 0;
    for (uint32_t id : _cell_tax_policy_ids)
        if (!cell_tax_policy(id).empty()) ++saved_cell_policy_count;
    append_le<uint64_t>(out, saved_cell_policy_count);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const CellTaxPolicy &policy = cell_tax_policy(
            _cell_tax_policy_ids[static_cast<size_t>(cell)]);
        if (policy.empty()) continue;
        append_le<int32_t>(out, cell);
        for (int8_t rate : policy.defaults) append_le<int8_t>(out, rate);
        append_le<uint64_t>(out,
            static_cast<uint64_t>(policy.overrides.size()));
        for (const CellTaxOverride &entry : policy.overrides) {
            append_le<int32_t>(out, entry.kind);
            append_string(out, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            append_le<int8_t>(out, entry.rate);
        }
    }
    append_le<uint64_t>(out, static_cast<uint64_t>(_pending_commands.size()));
    for (const Command &command : _pending_commands) {
        append_le<int32_t>(out, command.opcode);
        append_le<int64_t>(out, command.effective_day);
        append_le<int64_t>(out, command.sequence);
        append_le<uint64_t>(out, command.target_handle);
        append_le<int32_t>(out, command.cell);
        append_le<int32_t>(out, command.aux);
        append_le<int32_t>(out, command.domain);
        append_le<int32_t>(out, command.position);
        for (int32_t weight : command.weights_bp) append_le<int32_t>(out, weight);
        append_le<int32_t>(out, command.tax_kind);
        append_le<int32_t>(out, command.tax_item);
        append_le<int32_t>(out, command.tax_rate_percent);
        append_le<int64_t>(out, command.value);
        append_string(out, command.stable_id);
        append_string(out, command.display_name);
        append_le<uint64_t>(out, command.submit_order);
        append_le<int64_t>(out, command.effect_request_id);
        append_le<uint64_t>(out, command.effect_idempotency_key);
    }
    append_le<int64_t>(out, _era_reward_reference.plan_id);
    append_le<int64_t>(out, _era_reward_reference.offer_generation);
    append_le<int32_t>(out, _era_reward_reference.milestone_technology);
    append_le<int32_t>(out, _era_reward_reference.status);
    std::vector<uint8_t> modifier_bytes;
    if (_modifier_runtime != nullptr &&
        !_modifier_runtime->serialize_domain(ModifierRuntime::COUNTRY,
                                              modifier_bytes, error)) {
        return false;
    }
    append_le<uint64_t>(out, static_cast<uint64_t>(modifier_bytes.size()));
    out.insert(out.end(), modifier_bytes.begin(), modifier_bytes.end());
    append_le<uint32_t>(out, SAVE_END);
    return true;
}

bool NativeCountryRuntime::decode_save(const std::vector<uint8_t> &bytes, std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, end = 0;
    uint64_t saved_catalog = 0, generation_value = 0, saved_submit_order = 0;
    int64_t committed_day = -1;
    int32_t cell_count = 0, country_count = 0, good_count_value = 0;
    int32_t profession_count = 0, building_count = 0;
    int32_t tech_count = 0, tech_words = 0, signal_count = 0, signal_words = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version)) { error = "country_save_truncated"; return false; }
    if (magic != SAVE_MAGIC) { error = "country_save_magic_invalid"; return false; }
    if (version != SCHEMA_VERSION) {
        error = "catalog_hash_mismatch";
        return false;
    }
    if (!read_le(bytes, cursor, saved_catalog) || !read_le(bytes, cursor, generation_value) ||
        !read_le(bytes, cursor, committed_day) || !read_le(bytes, cursor, saved_submit_order) ||
        !read_le(bytes, cursor, cell_count) ||
        !read_le(bytes, cursor, country_count) ||
        !read_le(bytes, cursor, good_count_value)) {
        error = "country_save_header_truncated"; return false;
    }
    if (!read_le(bytes, cursor, profession_count) ||
        !read_le(bytes, cursor, building_count)) {
        error = "country_save_header_truncated";
        return false;
    }
    if (!read_le(bytes, cursor, tech_count) ||
        !read_le(bytes, cursor, tech_words) ||
        !read_le(bytes, cursor, signal_count) ||
        !read_le(bytes, cursor, signal_words)) {
        error = "country_save_header_truncated";
        return false;
    }
    const uint64_t expected_catalog = catalog_hash();
    if (saved_catalog != expected_catalog ||
        cell_count != _cell_count ||
        good_count_value != static_cast<int32_t>(_good_ids.size()) ||
        profession_count != static_cast<int32_t>(_profession_ids.size()) ||
        building_count != static_cast<int32_t>(_building_type_ids.size()) ||
        tech_count != static_cast<int32_t>(_technology_ids.size()) || tech_words != _technology_words ||
        signal_count != static_cast<int32_t>(_research_signal_ids.size()) ||
        signal_words != _research_signal_words) {
        error = "catalog_hash_mismatch";
        return false;
    }
    if (country_count <= 0 || country_count > 1000000) {
        error = "country_save_shape_invalid";
        return false;
    }
    std::string id;
    for (const std::string &expected : _good_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }
    for (const std::string &expected : _profession_ids)
        if (!read_string(bytes, cursor, id) || id != expected) {
            error = "catalog_hash_mismatch";
            return false;
        }
    for (const std::string &expected : _building_type_ids)
        if (!read_string(bytes, cursor, id) || id != expected) {
            error = "catalog_hash_mismatch";
            return false;
        }
    for (const std::string &expected : _technology_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }
    for (const std::string &expected : _research_signal_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }

    CountryStore countries;
    countries.active.resize(country_count);
    countries.generation.resize(country_count);
    countries.stable_id.resize(country_count);
    countries.display_name.resize(country_count);
    countries.territory_count.resize(country_count);
    countries.cash.resize(country_count);
    countries.state_version.resize(country_count);
    std::unordered_set<std::string> stable_ids;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_le(bytes, cursor, countries.active[slot]) || !read_le(bytes, cursor, countries.generation[slot]) ||
            !read_string(bytes, cursor, countries.stable_id[slot]) || !read_string(bytes, cursor, countries.display_name[slot]) ||
            !read_le(bytes, cursor, countries.territory_count[slot]) || !read_le(bytes, cursor, countries.cash[slot]) ||
            !read_le(bytes, cursor, countries.state_version[slot])) { error = "country_save_country_record_truncated"; return false; }
        if (countries.active[slot] == 0 || countries.generation[slot] == 0 || countries.stable_id[slot].empty() ||
            countries.display_name[slot].empty() || countries.territory_count[slot] <= 0 || countries.cash[slot] < 0 ||
            !stable_ids.insert(countries.stable_id[slot]).second) { error = "country_save_country_record_invalid"; return false; }
    }
    std::vector<int32_t> owners;
    std::vector<uint64_t> technologies;
    std::vector<int64_t> goods;
    if (!read_vector(bytes, cursor, owners, static_cast<uint64_t>(_cell_count)) || owners.size() != static_cast<size_t>(_cell_count) ||
        !read_vector(bytes, cursor, technologies, static_cast<uint64_t>(country_count) * _technology_words) ||
        technologies.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, goods, static_cast<uint64_t>(country_count) * _good_ids.size()) ||
        goods.size() != static_cast<size_t>(country_count) * _good_ids.size()) { error = "country_save_matrix_shape_invalid"; return false; }
    std::vector<uint64_t> discovered, pending, signals;
    std::vector<int32_t> research_queues, research_weights;
    std::vector<uint8_t> research_queue_lengths, auto_purchase;
    std::vector<int64_t> daily_budgets, deferred_points, purchased_total,
        consumed_total, progress_total, completed_total;
    int64_t last_research_day = -1;
    const uint64_t countries_u64 = static_cast<uint64_t>(country_count);
    if (!read_vector(bytes, cursor, discovered, countries_u64 * _technology_words) ||
        discovered.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, pending, countries_u64 * _technology_words) ||
        pending.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, signals, countries_u64 * _research_signal_words) ||
        signals.size() != static_cast<size_t>(country_count) * _research_signal_words) {
        error = "country_save_research_shape_invalid";
        return false;
    }
    uint64_t signal_cell_country_count = 0;
    if (!read_le(bytes, cursor, signal_cell_country_count) ||
        signal_cell_country_count != countries_u64) {
        error = "country_save_signal_cells_shape_invalid";
        return false;
    }
    std::vector<std::vector<uint64_t>> signal_cells(static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_vector(bytes, cursor, signal_cells[static_cast<size_t>(slot)],
                         static_cast<uint64_t>(_cell_count) *
                             std::max<int32_t>(signal_count, 1))) {
            error = "country_save_signal_cells_shape_invalid";
            return false;
        }
        if (!std::is_sorted(signal_cells[static_cast<size_t>(slot)].begin(),
                            signal_cells[static_cast<size_t>(slot)].end()) ||
            std::adjacent_find(signal_cells[static_cast<size_t>(slot)].begin(),
                               signal_cells[static_cast<size_t>(slot)].end()) !=
                signal_cells[static_cast<size_t>(slot)].end()) {
            error = "country_save_signal_cells_invalid";
            return false;
        }
        for (uint64_t key : signal_cells[static_cast<size_t>(slot)]) {
            const int32_t signal = static_cast<int32_t>(key >> 32U);
            const int32_t cell = static_cast<int32_t>(key & 0xffffffffU);
            if (signal < 0 || signal >= signal_count || cell < 0 || cell >= _cell_count) {
                error = "country_save_signal_cells_invalid";
                return false;
            }
        }
    }
    uint64_t signal_evidence_country_count = 0;
    if (!read_le(bytes, cursor, signal_evidence_country_count) ||
        signal_evidence_country_count != countries_u64) {
        error = "country_save_signal_evidence_shape_invalid";
        return false;
    }
    std::vector<std::vector<SignalEvidence>> signal_evidence(
        static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        uint64_t entry_count = 0;
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > static_cast<uint64_t>(signal_count)) {
            error = "country_save_signal_evidence_shape_invalid";
            return false;
        }
        int32_t previous_signal = -1;
        for (uint64_t entry_index = 0; entry_index < entry_count; ++entry_index) {
            SignalEvidence entry;
            if (!read_le(bytes, cursor, entry.signal) || !read_le(bytes, cursor, entry.count) ||
                !read_le(bytes, cursor, entry.first_day) || !read_le(bytes, cursor, entry.last_day) ||
                !read_le(bytes, cursor, entry.first_cell) || entry.signal <= previous_signal ||
                entry.signal < 0 || entry.signal >= signal_count || entry.count <= 0 ||
                entry.first_day < 0 || entry.last_day < entry.first_day ||
                entry.first_cell < 0 || entry.first_cell >= _cell_count) {
                error = "country_save_signal_evidence_invalid";
                return false;
            }
            signal_evidence[static_cast<size_t>(slot)].push_back(entry);
            previous_signal = entry.signal;
        }
    }
    if (!read_vector(bytes, cursor, research_queues, countries_u64 * 32U) ||
        research_queues.size() != static_cast<size_t>(country_count) * 32U ||
        !read_vector(bytes, cursor, research_queue_lengths, countries_u64 * 4U) ||
        research_queue_lengths.size() != static_cast<size_t>(country_count) * 4U ||
        !read_vector(bytes, cursor, research_weights, countries_u64 * 4U) ||
        research_weights.size() != static_cast<size_t>(country_count) * 4U ||
        !read_vector(bytes, cursor, auto_purchase, countries_u64) ||
        auto_purchase.size() != static_cast<size_t>(country_count) ||
        !read_vector(bytes, cursor, daily_budgets, countries_u64) ||
        !read_vector(bytes, cursor, deferred_points, countries_u64) ||
        !read_vector(bytes, cursor, purchased_total, countries_u64) ||
        !read_vector(bytes, cursor, consumed_total, countries_u64) ||
        !read_vector(bytes, cursor, progress_total, countries_u64) ||
        !read_vector(bytes, cursor, completed_total, countries_u64) ||
        daily_budgets.size() != static_cast<size_t>(country_count) ||
        deferred_points.size() != static_cast<size_t>(country_count) ||
        purchased_total.size() != static_cast<size_t>(country_count) ||
        consumed_total.size() != static_cast<size_t>(country_count) ||
        progress_total.size() != static_cast<size_t>(country_count) ||
        completed_total.size() != static_cast<size_t>(country_count) ||
        !read_le(bytes, cursor, last_research_day)) {
        error = "country_save_research_shape_invalid";
        return false;
    }
    uint64_t progress_country_count = 0;
    if (!read_le(bytes, cursor, progress_country_count) ||
        progress_country_count != countries_u64) {
        error = "country_save_research_progress_shape_invalid";
        return false;
    }
    std::vector<std::vector<std::pair<int32_t, int64_t>>> research_progress(
        static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        uint64_t entry_count = 0;
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > static_cast<uint64_t>(_technology_ids.size())) {
            error = "country_save_research_progress_shape_invalid";
            return false;
        }
        int32_t previous_tech = -1;
        for (uint64_t entry = 0; entry < entry_count; ++entry) {
            int32_t tech = -1;
            int64_t value = 0;
            if (!read_le(bytes, cursor, tech) || !read_le(bytes, cursor, value) ||
                tech <= previous_tech || tech >= tech_count || value <= 0 ||
                value > _technology_costs[static_cast<size_t>(tech)]) {
                error = "country_save_research_progress_invalid";
                return false;
            }
            research_progress[static_cast<size_t>(slot)].push_back({tech, value});
            previous_tech = tech;
        }
    }
    for (int32_t slot = 0; slot < country_count; ++slot) {
        int32_t weight_total = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            const size_t index = static_cast<size_t>(slot) * 4U + domain;
            if (research_queue_lengths[index] > 8 ||
                research_weights[index] < 0 || research_weights[index] > 10000) {
                error = "country_save_research_policy_invalid";
                return false;
            }
            weight_total += research_weights[index];
        }
        if (weight_total != 10000 || auto_purchase[static_cast<size_t>(slot)] > 1 ||
            daily_budgets[static_cast<size_t>(slot)] < 0 ||
            deferred_points[static_cast<size_t>(slot)] < 0) {
            error = "country_save_research_policy_invalid";
            return false;
        }
    }
    std::vector<int32_t> territory_counts(static_cast<size_t>(country_count), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t owner = owners[static_cast<size_t>(cell)];
        if (owner < NEUTRAL_SLOT || owner >= country_count ||
            (owner >= 0 && !_is_water.empty() && _is_water[static_cast<size_t>(cell)] != 0)) {
            error = "country_save_territory_invalid"; return false;
        }
        if (owner >= 0) ++territory_counts[static_cast<size_t>(owner)];
    }
    if (territory_counts != countries.territory_count) { error = "country_save_territory_count_mismatch"; return false; }
    for (int64_t quantity : goods) if (quantity < 0) { error = "country_save_treasury_negative"; return false; }
    std::vector<int8_t> tax_defaults(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT, 0);
    std::vector<int8_t> income_tax(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int8_t> consumption_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int8_t> business_tax(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int8_t> import_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int8_t> export_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    uint64_t tax_policy_version = 0;
    {
        if (!read_vector(bytes, cursor, tax_defaults,
                         static_cast<uint64_t>(country_count) *
                             TAX_KIND_COUNT) ||
            !read_vector(bytes, cursor, income_tax,
                         static_cast<uint64_t>(country_count) *
                             _profession_ids.size()) ||
            !read_vector(bytes, cursor, consumption_tax,
                         static_cast<uint64_t>(country_count) *
                             _good_ids.size()) ||
            !read_vector(bytes, cursor, business_tax,
                         static_cast<uint64_t>(country_count) *
                             _building_type_ids.size()) ||
            !read_vector(bytes, cursor, import_tax,
                         static_cast<uint64_t>(country_count) *
                             _good_ids.size()) ||
            !read_vector(bytes, cursor, export_tax,
                         static_cast<uint64_t>(country_count) *
                             _good_ids.size()) ||
            !read_le(bytes, cursor, tax_policy_version) ||
            tax_defaults.size() !=
                static_cast<size_t>(country_count) * TAX_KIND_COUNT ||
            income_tax.size() != static_cast<size_t>(country_count) *
                _profession_ids.size() ||
            consumption_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size() ||
            business_tax.size() != static_cast<size_t>(country_count) *
                _building_type_ids.size() ||
            import_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size() ||
            export_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size()) {
            error = "country_save_tax_shape_invalid";
            return false;
        }
        const auto rate_valid = [](int8_t rate) {
            return rate == TAX_RATE_INHERIT ||
                   (rate >= -100 && rate <= 100);
        };
        for (int8_t rate : tax_defaults) {
            if (rate < -100 || rate > 100) {
                error = "country_save_tax_rate_invalid";
                return false;
            }
        }
        for (const auto *rates : {&income_tax, &consumption_tax,
                                  &business_tax, &import_tax, &export_tax}) {
            if (!std::all_of(rates->begin(), rates->end(), rate_valid)) {
                error = "country_save_tax_rate_invalid";
                return false;
            }
        }
    }
    std::vector<uint32_t> cell_tax_policy_ids(
        static_cast<size_t>(_cell_count), 0);
    std::vector<CellTaxPolicy> cell_tax_policies(1);
    std::unordered_map<uint64_t, std::vector<uint32_t>> local_policy_intern;
    uint64_t saved_cell_policy_count = 0;
    if (!read_le(bytes, cursor, saved_cell_policy_count) ||
        saved_cell_policy_count > static_cast<uint64_t>(_cell_count)) {
        error = "country_save_cell_tax_count_invalid";
        return false;
    }
    int32_t previous_cell_policy = -1;
    for (uint64_t policy_index = 0;
         policy_index < saved_cell_policy_count; ++policy_index) {
        int32_t cell = -1;
        CellTaxPolicy policy;
        if (!read_le(bytes, cursor, cell) || cell <= previous_cell_policy ||
            cell < 0 || cell >= _cell_count ||
            owners[static_cast<size_t>(cell)] < 0) {
            error = "country_save_cell_tax_cell_invalid";
            return false;
        }
        for (int8_t &rate : policy.defaults) {
            if (!read_le(bytes, cursor, rate) ||
                (rate != TAX_RATE_INHERIT && (rate < -100 || rate > 100))) {
                error = "country_save_cell_tax_default_invalid";
                return false;
            }
        }
        uint64_t entry_count = 0;
        const uint64_t max_entries = static_cast<uint64_t>(
            _profession_ids.size() + _building_type_ids.size() +
            _good_ids.size() * 3U);
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > max_entries) {
            error = "country_save_cell_tax_entries_invalid";
            return false;
        }
        int32_t previous_kind = -1;
        int32_t previous_item = -1;
        for (uint64_t entry_index = 0; entry_index < entry_count;
             ++entry_index) {
            CellTaxOverride entry;
            std::string item_id;
            if (!read_le(bytes, cursor, entry.kind) ||
                !read_string(bytes, cursor, item_id) ||
                !read_le(bytes, cursor, entry.rate)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            entry.item = tax_item_index(entry.kind, item_id);
            if (entry.kind < 0 || entry.kind >= TAX_KIND_COUNT ||
                entry.item < 0 || entry.rate < -100 || entry.rate > 100 ||
                entry.kind < previous_kind ||
                (entry.kind == previous_kind && entry.item <= previous_item)) {
                error = "country_save_cell_tax_entry_invalid";
                return false;
            }
            policy.overrides.push_back(entry);
            previous_kind = entry.kind;
            previous_item = entry.item;
        }
        if (policy.empty()) {
            error = "country_save_cell_tax_empty_policy";
            return false;
        }
        const uint64_t hash = cell_tax_policy_hash(policy);
        uint32_t id_value = 0;
        auto &candidates = local_policy_intern[hash];
        for (uint32_t candidate : candidates) {
            if (cell_tax_policies[candidate] == policy) {
                id_value = candidate;
                break;
            }
        }
        if (id_value == 0) {
            id_value = static_cast<uint32_t>(cell_tax_policies.size());
            cell_tax_policies.push_back(std::move(policy));
            candidates.push_back(id_value);
        }
        cell_tax_policy_ids[static_cast<size_t>(cell)] = id_value;
        previous_cell_policy = cell;
    }
    uint64_t command_count = 0;
    if (!read_le(bytes, cursor, command_count) || command_count > 10000000ULL) { error = "country_save_command_count_invalid"; return false; }
    std::vector<Command> commands;
    commands.reserve(static_cast<size_t>(command_count));
    uint64_t max_submit_order = 0;
    std::unordered_set<uint64_t> command_submit_orders;
    std::unordered_set<std::string> pending_stable_ids = stable_ids;
    auto saved_handle_valid = [&](uint64_t handle) {
        const int32_t slot = static_cast<int32_t>(handle & 0xffffffffULL);
        const uint32_t handle_generation = static_cast<uint32_t>(handle >> 32U);
        return slot >= 0 && slot < country_count && countries.active[slot] != 0 &&
            countries.generation[slot] == handle_generation;
    };
    for (uint64_t i = 0; i < command_count; ++i) {
        Command command;
        if (!read_le(bytes, cursor, command.opcode) || !read_le(bytes, cursor, command.effective_day) ||
            !read_le(bytes, cursor, command.sequence) || !read_le(bytes, cursor, command.target_handle) ||
            !read_le(bytes, cursor, command.cell) || !read_le(bytes, cursor, command.aux) ||
            !read_le(bytes, cursor, command.domain) || !read_le(bytes, cursor, command.position) ||
            !read_le(bytes, cursor, command.weights_bp[0]) ||
            !read_le(bytes, cursor, command.weights_bp[1]) ||
            !read_le(bytes, cursor, command.weights_bp[2]) ||
            !read_le(bytes, cursor, command.weights_bp[3])) {
            error = "country_save_command_truncated";
            return false;
        }
        if (!read_le(bytes, cursor, command.tax_kind) ||
            !read_le(bytes, cursor, command.tax_item) ||
            !read_le(bytes, cursor, command.tax_rate_percent)) {
            error = "country_save_command_truncated";
            return false;
        }
        if (!read_le(bytes, cursor, command.value) ||
            !read_string(bytes, cursor, command.stable_id) || !read_string(bytes, cursor, command.display_name) ||
            !read_le(bytes, cursor, command.submit_order) ||
            !read_le(bytes, cursor, command.effect_request_id) ||
            !read_le(bytes, cursor, command.effect_idempotency_key)) { error = "country_save_command_truncated"; return false; }
        if (command.opcode < COMMAND_CREATE_COUNTRY ||
            command.opcode > COMMAND_CLAIM_UNOWNED_TERRITORY ||
            command.effective_day < 0 ||
            command.sequence < 0 || command.submit_order == 0 ||
            !command_submit_orders.insert(command.submit_order).second) {
            error = "country_save_command_invalid"; return false;
        }
        if (command.opcode == COMMAND_CREATE_COUNTRY) {
            if (command.stable_id.empty() || command.display_name.empty() ||
                command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                !pending_stable_ids.insert(command.stable_id).second) {
                error = "country_save_create_command_invalid"; return false;
            }
        } else if (command.opcode == COMMAND_RENAME_COUNTRY) {
            if (!saved_handle_valid(command.target_handle) || command.display_name.empty()) {
                error = "country_save_rename_command_invalid"; return false;
            }
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY ||
                   command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) {
            if (command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                (command.target_handle != 0 && !saved_handle_valid(command.target_handle))) {
                error = "country_save_transfer_command_invalid"; return false;
            }
        } else if (!saved_handle_valid(command.target_handle) ||
                   ((command.opcode == COMMAND_GRANT_TECHNOLOGY ||
                     command.opcode == COMMAND_ENQUEUE_RESEARCH ||
                     command.opcode == COMMAND_REMOVE_RESEARCH ||
                     command.opcode == COMMAND_MOVE_RESEARCH) &&
                    (command.aux < 0 || command.aux >= tech_count))) {
            error = "country_save_technology_command_invalid"; return false;
        }
        if (command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL &&
            (command.aux < 0 || command.aux >= signal_count || command.cell < 0 ||
             command.cell >= _cell_count)) {
            error = "country_save_signal_command_invalid";
            return false;
        }
        if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
            command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE &&
            (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
             command.tax_rate_percent < -100 ||
             command.tax_rate_percent > 100 ||
             (command.opcode != COMMAND_SET_TAX_DEFAULT &&
              (command.tax_item < 0 ||
               command.tax_item >= tax_item_count(command.tax_kind))))) {
            error = "country_save_tax_command_invalid";
            return false;
        }
        if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
            command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
            const bool has_kind =
                command.opcode != COMMAND_CLEAR_CELL_TAX_POLICY;
            const bool has_item =
                command.opcode == COMMAND_SET_CELL_TAX_OVERRIDE ||
                command.opcode == COMMAND_CLEAR_CELL_TAX_OVERRIDE;
            const bool has_rate =
                command.opcode == COMMAND_SET_CELL_TAX_DEFAULT ||
                command.opcode == COMMAND_SET_CELL_TAX_OVERRIDE;
            if (!saved_handle_valid(command.target_handle) ||
                command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                (has_kind && (command.tax_kind < 0 ||
                              command.tax_kind >= TAX_KIND_COUNT)) ||
                (has_item && (command.tax_item < 0 ||
                              command.tax_item >= tax_item_count(
                                  command.tax_kind))) ||
                (has_item && !command.stable_id.empty() &&
                 tax_item_ids(command.tax_kind)[
                     static_cast<size_t>(command.tax_item)] !=
                     command.stable_id) ||
                (has_rate && (command.tax_rate_percent < -100 ||
                              command.tax_rate_percent > 100))) {
                error = "country_save_cell_tax_command_invalid";
                return false;
            }
        }
        commands.push_back(std::move(command));
        max_submit_order = std::max(max_submit_order, commands.back().submit_order);
    }
    EraRewardReference era_reward_reference;
    if (!read_le(bytes, cursor, era_reward_reference.plan_id) ||
        !read_le(bytes, cursor, era_reward_reference.offer_generation) ||
        !read_le(bytes, cursor, era_reward_reference.milestone_technology) ||
        !read_le(bytes, cursor, era_reward_reference.status) ||
        era_reward_reference.status < 0 || era_reward_reference.status > 4 ||
        (era_reward_reference.status == 0 &&
         (era_reward_reference.plan_id != 0 ||
          era_reward_reference.offer_generation != 0)) ||
        (era_reward_reference.status != 0 &&
         (era_reward_reference.plan_id <= 0 ||
          era_reward_reference.offer_generation <= 0 ||
          era_reward_reference.milestone_technology < 0 ||
          era_reward_reference.milestone_technology >= tech_count))) {
        error = "country_save_era_reward_reference_invalid";
        return false;
    }
    std::vector<uint8_t> modifier_bytes;
    {
        uint64_t modifier_size = 0;
        if (!read_le(bytes, cursor, modifier_size) ||
            modifier_size > static_cast<uint64_t>(bytes.size() - cursor) ||
            modifier_size > 256ULL * 1024ULL * 1024ULL) {
            error = "country_save_modifier_payload_invalid";
            return false;
        }
        modifier_bytes.assign(bytes.begin() + static_cast<ptrdiff_t>(cursor),
                              bytes.begin() + static_cast<ptrdiff_t>(cursor + modifier_size));
        cursor += static_cast<size_t>(modifier_size);
    }
    if (!read_le(bytes, cursor, end) || end != SAVE_END || cursor != bytes.size()) { error = "country_save_end_invalid"; return false; }

    if (!modifier_bytes.empty()) {
        if (_modifier_runtime == nullptr) {
            error = "country_restore_modifier_runtime_unavailable";
            return false;
        }
        if (!_modifier_runtime->restore_domain(ModifierRuntime::COUNTRY,
                                               modifier_bytes, error,
                                               version == 3)) {
            error = "country_restore_modifier_failed:" + error;
            return false;
        }
    } else if (_modifier_runtime != nullptr) {
        _modifier_runtime->clear_domain(ModifierRuntime::COUNTRY);
    }

    _countries = std::move(countries);
    _cell_country_slot = std::move(owners);
    _country_technologies = std::move(technologies);
    _country_goods = std::move(goods);
    _country_discovered = std::move(discovered);
    _country_pending_technologies = std::move(pending);
    _pending_activation_index_dirty = true;
    _country_research_signals = std::move(signals);
    _country_research_signal_cells = std::move(signal_cells);
    _country_research_signal_evidence = std::move(signal_evidence);
    _country_research_progress = std::move(research_progress);
    _country_research_queues = std::move(research_queues);
    _country_research_queue_lengths = std::move(research_queue_lengths);
    _country_research_weights_bp = std::move(research_weights);
    _country_research_auto_purchase = std::move(auto_purchase);
    _country_research_daily_budgets = std::move(daily_budgets);
    _country_research_deferred_points = std::move(deferred_points);
    _country_research_purchased_total = std::move(purchased_total);
    _country_research_consumed_total = std::move(consumed_total);
    _country_research_progress_total = std::move(progress_total);
    _country_research_completed_total = std::move(completed_total);
    _country_tax_defaults = std::move(tax_defaults);
    _country_income_tax_overrides = std::move(income_tax);
    _country_consumption_tax_overrides = std::move(consumption_tax);
    _country_business_tax_overrides = std::move(business_tax);
    _country_import_tax_overrides = std::move(import_tax);
    _country_export_tax_overrides = std::move(export_tax);
    _cell_tax_policy_ids = std::move(cell_tax_policy_ids);
    _cell_tax_policies = std::move(cell_tax_policies);
    rebuild_cell_tax_policy_intern();
    _tax_policy_version = tax_policy_version;
    _last_research_day = last_research_day;
    _pending_commands = std::move(commands);
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _next_effect_request_id = 1;
    _era_reward_reference = era_reward_reference;
    for (const Command &command : _pending_commands) {
        if (command.effect_request_id <= 0) continue;
        if (command.effect_idempotency_key == 0 ||
            !_effect_command_idempotency.emplace(command.effect_idempotency_key,
                command.effect_request_id).second) {
            error = "country_save_effect_command_invalid";
            return false;
        }
        _effect_command_results.emplace(command.effect_request_id, EffectCommandResult{});
        _next_effect_request_id = std::max(_next_effect_request_id,
            command.effect_request_id + 1);
    }
    _generation = generation_value;
    _last_committed_day = committed_day;
    _submit_order = std::max(saved_submit_order, max_submit_order);
    _bootstrapped = true;
    _state_hash_cache_valid = false;
    rebuild_cell_csr();
    publish_report("aggregate_publish", committed_day, 0, 0, 0, _cell_count, country_count, _mode == MODE_ACTIVE);
    return true;
}

Dictionary NativeCountryRuntime::begin_save(int32_t chunk_bytes) {
    if (_save_active) return fail("country_save_already_active");
    std::string error;
    if (!encode_save(_save_bytes, error)) return fail(error);
    _save_chunk_bytes = std::clamp(chunk_bytes, 4096, 16 * 1024 * 1024);
    _save_cursor = 0;
    _save_active = true;
    Dictionary out;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["bytes"] = static_cast<int64_t>(_save_bytes.size());
    out["state_hash"] = state_hash();
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

PackedByteArray NativeCountryRuntime::read_save_chunk(int32_t max_bytes) {
    PackedByteArray out;
    if (!_save_active || _save_cursor >= _save_bytes.size()) return out;
    const size_t take = std::min(_save_bytes.size() - _save_cursor,
                                 static_cast<size_t>(std::clamp(max_bytes, 1, _save_chunk_bytes)));
    out.resize(static_cast<int64_t>(take));
    std::memcpy(out.ptrw(), _save_bytes.data() + _save_cursor, take);
    _save_cursor += take;
    return out;
}

Dictionary NativeCountryRuntime::end_save() {
    if (!_save_active) return fail("country_save_not_active");
    const bool complete = _save_cursor == _save_bytes.size();
    _save_active = false;
    _save_bytes.clear();
    _save_cursor = 0;
    Dictionary out;
    out["ok"] = complete;
    out["reason"] = complete ? "" : "country_save_not_fully_read";
    return out;
}

Dictionary NativeCountryRuntime::begin_restore() {
    if (!_configured) return fail("country_not_configured");
    if (_restore_active) return fail("country_restore_already_active");
    _restore_bytes.clear();
    _restore_active = true;
    Dictionary out;
    out["ok"] = true;
    return out;
}

Dictionary NativeCountryRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    if (!_restore_active) return fail("country_restore_not_active");
    if (chunk.is_empty()) return fail("country_restore_empty_chunk");
    const size_t old_size = _restore_bytes.size();
    _restore_bytes.resize(old_size + static_cast<size_t>(chunk.size()));
    std::memcpy(_restore_bytes.data() + old_size, chunk.ptr(), static_cast<size_t>(chunk.size()));
    Dictionary out;
    out["ok"] = true;
    out["bytes_received"] = static_cast<int64_t>(_restore_bytes.size());
    return out;
}

Dictionary NativeCountryRuntime::end_restore() {
    if (!_restore_active) return fail("country_restore_not_active");
    std::string error;
    const bool ok = decode_save(_restore_bytes, error);
    _restore_active = false;
    _restore_bytes.clear();
    if (!ok) return fail(error);
    Dictionary out;
    out["ok"] = true;
    out["state_hash"] = state_hash();
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

} // namespace pk
