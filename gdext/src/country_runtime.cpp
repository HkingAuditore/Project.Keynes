#include "country_runtime.h"
#include "country_core_apply.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/array.hpp>
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
    _research_discovery_frontier_mismatches = 0;
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
    _technology_era_milestone_indices =
        packed_i32(catalog, "technology_era_milestone_indices");
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
        _technology_era_milestone_indices.size() != 11 ||
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
    rebuild_discovery_dependents();
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
    _territory_generation = 0;
    _research_generation = 0;
    _submit_order = 0;
    _typed_receipts.clear();
    _typed_request_state.clear();
    clear_peer_protocol_state();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
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
    _current_visual_era.clear();
    _visual_era_dirty_slots.clear();
    _visual_era_generation = 0;
    _research_active_country_slots.clear();
    _research_active_country_membership.clear();
    _research_activated_pending_scratch.clear();
    _research_activated_pending_scratch.reserve(32);
    _research_activated_technologies_scratch.clear();
    _research_activated_technologies_scratch.reserve(32);
    _research_modifier_cache.clear();
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
    _country_tax_default_modes.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _country_income_tax_mode_overrides.clear();
    _country_consumption_tax_mode_overrides.clear();
    _country_business_tax_mode_overrides.clear();
    _country_import_tax_mode_overrides.clear();
    _country_export_tax_mode_overrides.clear();
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
    clear_peer_protocol_state();
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};
    _economy_asset_transaction_history.clear();
    _economy_asset_request_index.clear();
    _economy_asset_transactions_in_flight.clear();
    _economy_asset_reserved_cash.clear();
    _economy_asset_reserved_goods.clear();
    _economy_asset_reserved_research_points.clear();
    _next_economy_asset_transaction_id = 1;
    _economy_asset_operation_sequence = 0;
    _economy_asset_transactions_created = 0;
    _economy_asset_transactions_completed = 0;
    _economy_asset_transactions_rejected = 0;
    _economy_asset_prepare_count = 0;
    _economy_asset_commit_count = 0;
    _economy_asset_complete_count = 0;
    _economy_asset_ledger_failures = 0;
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
    _economy_asset_reserved_cash.resize(_countries.active.size(), 0);
    _economy_asset_reserved_goods.resize(
        _countries.active.size() * _good_ids.size(), 0);
    _economy_asset_reserved_research_points.resize(
        _countries.active.size(), 0);
    _country_technologies.resize(static_cast<size_t>(slot + 1) * _technology_words, 0);
    _current_visual_era.resize(static_cast<size_t>(slot + 1), -1);
    _country_goods.resize(static_cast<size_t>(slot + 1) * _good_ids.size(), 0);
    _country_tax_defaults.resize(static_cast<size_t>(slot + 1) * TAX_KIND_COUNT,
                                 0);
    _country_tax_default_modes.resize(
        static_cast<size_t>(slot + 1) * TAX_KIND_COUNT, TAX_MODE_PERCENT_BP);
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
    _country_income_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _profession_ids.size(),
        TAX_MODE_INHERIT);
    _country_consumption_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_MODE_INHERIT);
    _country_business_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _building_type_ids.size(),
        TAX_MODE_INHERIT);
    _country_import_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_MODE_INHERIT);
    _country_export_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_MODE_INHERIT);
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

const std::vector<int32_t> *NativeCountryRuntime::tax_override_vector(
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

std::vector<int32_t> *NativeCountryRuntime::tax_override_vector(int32_t kind) {
    return const_cast<std::vector<int32_t> *>(
        static_cast<const NativeCountryRuntime *>(this)->tax_override_vector(kind));
}

const std::vector<int32_t> *NativeCountryRuntime::tax_mode_override_vector(
        int32_t kind) const {
    switch (kind) {
        case TAX_INCOME: return &_country_income_tax_mode_overrides;
        case TAX_CONSUMPTION: return &_country_consumption_tax_mode_overrides;
        case TAX_BUSINESS: return &_country_business_tax_mode_overrides;
        case TAX_IMPORT: return &_country_import_tax_mode_overrides;
        case TAX_EXPORT: return &_country_export_tax_mode_overrides;
        default: return nullptr;
    }
}

std::vector<int32_t> *NativeCountryRuntime::tax_mode_override_vector(
        int32_t kind) {
    return const_cast<std::vector<int32_t> *>(
        static_cast<const NativeCountryRuntime *>(this)
            ->tax_mode_override_vector(kind));
}

bool NativeCountryRuntime::tax_assessment_mode_valid(int32_t mode) {
    return mode == TAX_MODE_PERCENT_BP || mode == TAX_MODE_ABSOLUTE;
}

bool NativeCountryRuntime::tax_value_valid(int32_t mode, int32_t value) {
    if (mode == TAX_MODE_ABSOLUTE)
        return value >= TAX_ABSOLUTE_MIN && value <= TAX_ABSOLUTE_MAX;
    if (mode == TAX_MODE_PERCENT_BP)
        return value >= TAX_RATE_MIN_BP && value <= TAX_RATE_MAX_BP;
    return false;
}

int32_t NativeCountryRuntime::resolved_tax_rate(
        const std::vector<int32_t> &defaults,
        const std::vector<int32_t> &overrides, int32_t country_slot,
        int32_t kind, int32_t item, int32_t item_count) {
    if (country_slot < 0 || kind < 0 || kind >= TAX_KIND_COUNT ||
        item < 0 || item >= item_count)
        return 0;
    const int32_t value = overrides[
        static_cast<size_t>(country_slot) * item_count + item];
    return value == TAX_RATE_INHERIT
        ? defaults[static_cast<size_t>(country_slot) * TAX_KIND_COUNT + kind]
        : value;
}

int32_t NativeCountryRuntime::resolved_tax_mode(
        const std::vector<int32_t> &default_modes,
        const std::vector<int32_t> &mode_overrides, int32_t country_slot,
        int32_t kind, int32_t item, int32_t item_count) {
    if (country_slot < 0 || kind < 0 || kind >= TAX_KIND_COUNT ||
        item < 0 || item >= item_count)
        return TAX_MODE_PERCENT_BP;
    const int32_t mode = mode_overrides[
        static_cast<size_t>(country_slot) * item_count + item];
    return mode == TAX_MODE_INHERIT
        ? default_modes[
              static_cast<size_t>(country_slot) * TAX_KIND_COUNT + kind]
        : mode;
}

NativeCountryRuntime::ResolvedTaxPolicy
NativeCountryRuntime::resolved_tax_policy(
        const std::vector<int32_t> &defaults,
        const std::vector<int32_t> &default_modes,
        const std::vector<int32_t> &overrides,
        const std::vector<int32_t> &mode_overrides, int32_t country_slot,
        int32_t kind, int32_t item, int32_t item_count) {
    ResolvedTaxPolicy out;
    out.mode = resolved_tax_mode(default_modes, mode_overrides, country_slot,
                                 kind, item, item_count);
    out.value = resolved_tax_rate(defaults, overrides, country_slot, kind,
                                  item, item_count);
    return out;
}

uint64_t NativeCountryRuntime::cell_tax_policy_hash(
        const CellTaxPolicy &policy) {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, policy.defaults.data(),
               policy.defaults.size() * sizeof(int32_t));
    hash_bytes(hash, policy.default_modes.data(),
               policy.default_modes.size() * sizeof(int32_t));
    for (const CellTaxOverride &entry : policy.overrides) {
        hash_bytes(hash, &entry.kind, sizeof(entry.kind));
        hash_bytes(hash, &entry.item, sizeof(entry.item));
        hash_bytes(hash, &entry.rate, sizeof(entry.rate));
        hash_bytes(hash, &entry.mode, sizeof(entry.mode));
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
    _research_active_country_membership.resize(countries, 0);
    _research_modifier_cache.resize(countries);
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

bool NativeCountryRuntime::country_has_research_work(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(slot)] == 0) {
        return false;
    }
    const size_t word_base = static_cast<size_t>(slot) *
        static_cast<size_t>(_technology_words);
    for (int32_t word = 0; word < _technology_words; ++word) {
        if (_country_pending_technologies[word_base + static_cast<size_t>(word)] != 0)
            return true;
    }
    const size_t queue_base = static_cast<size_t>(slot) * 4U;
    for (int32_t domain = 0; domain < 4; ++domain) {
        if (_country_research_queue_lengths[queue_base +
                static_cast<size_t>(domain)] != 0) {
            return true;
        }
    }
    return false;
}

void NativeCountryRuntime::rebuild_research_active_index() {
    _research_active_country_slots.clear();
    _research_active_country_membership.assign(_countries.active.size(), 0);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        if (!country_has_research_work(slot)) continue;
        _research_active_country_slots.push_back(slot);
        _research_active_country_membership[static_cast<size_t>(slot)] = 1;
    }
}

void NativeCountryRuntime::rebuild_discovery_dependents() {
    const int32_t technology_count =
        static_cast<int32_t>(_technology_ids.size());
    std::vector<std::vector<int32_t>> reverse(
        static_cast<size_t>(technology_count));
    auto add_edge = [&](int32_t source, int32_t target) {
        if (source < 0 || source >= technology_count || target < 0 ||
            target >= technology_count || source == target) return;
        reverse[static_cast<size_t>(source)].push_back(target);
    };
    for (int32_t target = 0; target < technology_count; ++target) {
        for (int32_t edge = _technology_prerequisite_offsets[
                 static_cast<size_t>(target)];
             edge < _technology_prerequisite_offsets[
                 static_cast<size_t>(target + 1)]; ++edge) {
            add_edge(_technology_prerequisites[static_cast<size_t>(edge)], target);
        }
        for (int32_t edge = _technology_milestone_offsets[
                 static_cast<size_t>(target)];
             edge < _technology_milestone_offsets[
                 static_cast<size_t>(target + 1)]; ++edge) {
            add_edge(_technology_milestone_candidates[static_cast<size_t>(edge)],
                     target);
        }
        for (int32_t op = _technology_reveal_condition_offsets[
                 static_cast<size_t>(target)];
             op < _technology_reveal_condition_offsets[
                 static_cast<size_t>(target + 1)]; ++op) {
            if (_technology_reveal_condition_ops[static_cast<size_t>(op)] == 1)
                add_edge(_technology_reveal_condition_refs[
                    static_cast<size_t>(op)], target);
        }
        if (target < static_cast<int32_t>(
                _technology_entry_milestone_indices.size())) {
            add_edge(_technology_entry_milestone_indices[
                static_cast<size_t>(target)], target);
        }
        if (target < static_cast<int32_t>(
                _technology_era_milestone_indices.size())) {
            add_edge(_technology_era_milestone_indices[
                static_cast<size_t>(target)], target);
        }
    }
    _technology_discovery_dependent_offsets.assign(
        static_cast<size_t>(technology_count + 1), 0);
    _technology_discovery_dependents.clear();
    for (int32_t source = 0; source < technology_count; ++source) {
        std::vector<int32_t> &bucket = reverse[static_cast<size_t>(source)];
        std::sort(bucket.begin(), bucket.end());
        bucket.erase(std::unique(bucket.begin(), bucket.end()), bucket.end());
        _technology_discovery_dependents.insert(
            _technology_discovery_dependents.end(), bucket.begin(), bucket.end());
        _technology_discovery_dependent_offsets[
            static_cast<size_t>(source + 1)] =
            static_cast<int32_t>(_technology_discovery_dependents.size());
    }
}

void NativeCountryRuntime::refresh_discovery_for_completed(
        int32_t slot, const std::vector<int32_t> &completed) {
    if (completed.empty()) return;
    std::vector<int32_t> frontier;
    for (const int32_t technology : completed) {
        if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()))
            continue;
        frontier.push_back(technology);
        if (technology + 1 >= static_cast<int32_t>(
                _technology_discovery_dependent_offsets.size())) continue;
        const int32_t begin = _technology_discovery_dependent_offsets[
            static_cast<size_t>(technology)];
        const int32_t end = _technology_discovery_dependent_offsets[
            static_cast<size_t>(technology + 1)];
        frontier.insert(frontier.end(),
            _technology_discovery_dependents.begin() + begin,
            _technology_discovery_dependents.begin() + end);
    }
    std::sort(frontier.begin(), frontier.end());
    frontier.erase(std::unique(frontier.begin(), frontier.end()), frontier.end());
    for (const int32_t technology : frontier)
        refresh_discovery_for_technology(slot, technology);

    if (_full_diagnostics) {
        const size_t word_base = static_cast<size_t>(slot) *
            static_cast<size_t>(_technology_words);
        std::vector<uint64_t> incremental(
            _country_discovered.begin() + static_cast<ptrdiff_t>(word_base),
            _country_discovered.begin() + static_cast<ptrdiff_t>(
                word_base + static_cast<size_t>(_technology_words)));
        refresh_discovery(slot);
        if (!std::equal(incremental.begin(), incremental.end(),
                _country_discovered.begin() + static_cast<ptrdiff_t>(word_base))) {
            ++_research_discovery_frontier_mismatches;
        }
    }
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
    _country_tax_default_modes.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _country_income_tax_mode_overrides.clear();
    _country_consumption_tax_mode_overrides.clear();
    _country_business_tax_mode_overrides.clear();
    _country_import_tax_mode_overrides.clear();
    _country_export_tax_mode_overrides.clear();
    _tax_policy_version = 0;
    _cell_tax_policy_ids.assign(static_cast<size_t>(_cell_count), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _last_research_day = -1;
    _pending_commands.clear();
    _typed_receipts.clear();
    _typed_request_state.clear();
    clear_peer_protocol_state();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _next_effect_request_id = 1;
    _economy_asset_transactions_in_flight.clear();
    _economy_asset_reserved_cash.assign(_countries.active.size(), 0);
    _economy_asset_reserved_goods.assign(
        _countries.active.size() * _good_ids.size(), 0);
    _economy_asset_reserved_research_points.assign(
        _countries.active.size(), 0);
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
    _territory_generation = 1;
    _research_generation = 1;
    _pending_activation_index_dirty = true;
    rebuild_research_active_index();
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
    _current_visual_era.resize(_countries.active.size(), -1);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot)
        _current_visual_era[static_cast<size_t>(slot)] =
            visual_era_index_for_slot(slot);
    _last_committed_day = -1;
    _last_research_day = -1;
    publish_report("aggregate_publish", -1, 0, 0, 0, _cell_count,
                   static_cast<int32_t>(_countries.active.size()), _mode == MODE_ACTIVE);
    begin_reference_boundary(-1);
    record_reference_frame("bootstrap", -1, true, false);
    Dictionary out = report();
    out["ok"] = true;
    out["default_bootstrap"] = ids.empty();
    return out;
}

bool NativeCountryRuntime::validate_admission_command(
        const Command &command, std::string &error) const {
    if (command.opcode < COMMAND_CREATE_COUNTRY ||
        command.opcode > COMMAND_CLAIM_UNOWNED_TERRITORY) {
        error = "country_command_opcode_invalid";
        return false;
    }
    if (command.effective_day < 0 || command.sequence < 0) {
        error = "country_command_order_invalid";
        return false;
    }
    if (command.observed_generation != 0 &&
        command.observed_generation != _generation) {
        error = "stale_command_generation";
        return false;
    }
    if (command.opcode == COMMAND_SET_RESEARCH_WEIGHTS) {
        const std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> weights{{
            command.weights_bp[0], command.weights_bp[1],
            command.weights_bp[2], command.weights_bp[3]}};
        if (!runtime_country_research_weights_valid(weights)) {
            error = "country_research_weight_policy_invalid";
            return false;
        }
    }
    if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
        command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
        const bool needs_value =
            command.opcode != COMMAND_CLEAR_TAX_OVERRIDE;
        if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
            (needs_value &&
             (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
              !tax_value_valid(command.tax_assessment_mode,
                               command.tax_rate_basis_points))) ||
            (command.opcode != COMMAND_SET_TAX_DEFAULT &&
             (command.tax_item < 0 ||
              command.tax_item >= tax_item_count(command.tax_kind)))) {
            error = "country_tax_command_invalid";
            return false;
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
            (has_rate &&
             (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
              !tax_value_valid(command.tax_assessment_mode,
                               command.tax_rate_basis_points)))) {
            error = "country_cell_tax_command_invalid";
            return false;
        }
    }
    if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY &&
        (command.cell < 0 || command.cell >= _cell_count ||
         _is_water[static_cast<size_t>(command.cell)] != 0)) {
        error = "country_claim_target_invalid";
        return false;
    }
    return true;
}

const char *economy_asset_status_name(
        NativeCountryRuntime::EconomyAssetTransactionStatus status) {
    switch (status) {
    case NativeCountryRuntime::ECONOMY_ASSET_CREATED: return "created";
    case NativeCountryRuntime::ECONOMY_ASSET_COUNTRY_PREPARED:
        return "country_prepared";
    case NativeCountryRuntime::ECONOMY_ASSET_PEER_PREPARED:
        return "peer_prepared";
    case NativeCountryRuntime::ECONOMY_ASSET_COMMIT_DECIDED:
        return "commit_decided";
    case NativeCountryRuntime::ECONOMY_ASSET_COUNTRY_APPLIED:
        return "country_applied";
    case NativeCountryRuntime::ECONOMY_ASSET_PEER_APPLIED:
        return "peer_applied";
    case NativeCountryRuntime::ECONOMY_ASSET_COMPLETED: return "completed";
    case NativeCountryRuntime::ECONOMY_ASSET_REJECTED: return "rejected";
    case NativeCountryRuntime::ECONOMY_ASSET_AWAITING_PEER_PREPARED:
        return "awaiting_peer_prepared";
    case NativeCountryRuntime::ECONOMY_ASSET_AWAITING_PEER_APPLIED:
        return "awaiting_peer_applied";
    case NativeCountryRuntime::ECONOMY_ASSET_FAULTED: return "faulted";
    }
    return "unknown";
}

bool NativeCountryRuntime::submit_typed_commands(
        const CountryTypedCommand *commands, size_t count,
        std::vector<CountryCommandReceipt> &receipts, std::string &error) {
    receipts.clear();
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_runtime_unavailable";
        return false;
    }
    if (commands == nullptr || count == 0) {
        error = "country_command_batch_empty";
        return false;
    }
    std::vector<Command> staged;
    staged.reserve(count);
    std::unordered_set<uint64_t> new_request_ids;
    uint64_t next_submit_order = _submit_order;
    for (size_t i = 0; i < count; ++i) {
        const CountryTypedCommand &source = commands[i];
        if (source.request_id == 0) {
            error = "country_request_id_invalid";
            break;
        }
        const auto existing = _typed_request_state.find(source.request_id);
        if (existing != _typed_request_state.end()) continue;
        if (!new_request_ids.insert(source.request_id).second) {
            error = "country_request_id_duplicate";
            break;
        }
        if (source.sequence >
            static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
            error = "country_command_order_invalid";
            break;
        }
        Command command;
        command.request_id = source.request_id;
        command.producer_id = source.producer_id;
        command.observed_generation = source.observed_generation;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = static_cast<int64_t>(source.sequence);
        command.target_handle = source.target_handle;
        command.cell = source.cell;
        command.aux = source.aux;
        command.domain = source.domain;
        command.position = source.position;
        std::copy(std::begin(source.weights_bp), std::end(source.weights_bp),
                  std::begin(command.weights_bp));
        command.tax_kind = source.tax_kind;
        command.tax_item = source.tax_item;
        command.tax_rate_basis_points = source.tax_rate_basis_points;
        command.tax_assessment_mode = source.tax_assessment_mode;
        command.value = source.value;
        command.stable_id = source.stable_id;
        command.display_name = source.display_name;
        command.submit_order = ++next_submit_order;
        if (!validate_admission_command(command, error)) break;
        staged.push_back(std::move(command));
    }
    if (!error.empty()) {
        receipts.reserve(count);
        for (size_t i = 0; i < count; ++i) {
            const auto existing = _typed_request_state.find(commands[i].request_id);
            if (existing != _typed_request_state.end()) {
                receipts.push_back(existing->second);
                continue;
            }
            CountryCommandReceipt receipt;
            receipt.request_id = commands[i].request_id;
            receipt.producer_id = commands[i].producer_id;
            receipt.sequence = commands[i].sequence;
            receipt.effective_day = commands[i].effective_day;
            receipt.generation = _generation;
            receipt.code = CountryCommandReceiptCode::ADMISSION_REJECTED;
            receipt.reason = error;
            receipts.push_back(std::move(receipt));
        }
        return false;
    }

    _pending_commands.reserve(_pending_commands.size() + staged.size());
    _pending_commands.insert(_pending_commands.end(),
        std::make_move_iterator(staged.begin()),
        std::make_move_iterator(staged.end()));
    _submit_order = next_submit_order;
    receipts.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const auto existing = _typed_request_state.find(commands[i].request_id);
        if (existing != _typed_request_state.end()) {
            receipts.push_back(existing->second);
            continue;
        }
        CountryCommandReceipt receipt;
        receipt.request_id = commands[i].request_id;
        receipt.producer_id = commands[i].producer_id;
        receipt.sequence = commands[i].sequence;
        receipt.effective_day = commands[i].effective_day;
        receipt.generation = _generation;
        receipt.code = CountryCommandReceiptCode::ACCEPTED;
        _typed_request_state.emplace(receipt.request_id, receipt);
        receipts.push_back(std::move(receipt));
    }
    return true;
}

bool NativeCountryRuntime::poll_typed_receipt(CountryCommandReceipt &out) {
    if (_typed_receipts.empty()) return false;
    out = std::move(_typed_receipts.front());
    _typed_receipts.pop_front();
    return true;
}

CountryBoundarySeal NativeCountryRuntime::open_implicit_boundary(int64_t day) {
    CountryBoundarySeal seal;
    seal.session_epoch = _session_epoch;
    seal.boundary_id = _next_boundary_id++;
    seal.day = day;
    seal.last_admitted_submit_order = _submit_order;
    seal.expected_base_generation = _generation;
    seal.catalog_hash = catalog_hash();
    _boundary_seal = seal;
    _boundary_seal_active = true;
    return seal;
}

bool NativeCountryRuntime::seal_boundary(
        uint64_t session_epoch, uint64_t boundary_id, int64_t day,
        CountryBoundarySeal &out, std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_runtime_unavailable";
        return false;
    }
    if (session_epoch == 0 || session_epoch != _session_epoch) {
        error = "country_boundary_session_mismatch";
        return false;
    }
    if (boundary_id == 0 || day < 0) {
        error = "country_boundary_invalid";
        return false;
    }
    if (_command_batch.active) {
        error = "country_boundary_in_progress";
        return false;
    }
    if (_boundary_seal_active) {
        if (_boundary_seal.session_epoch == session_epoch &&
            _boundary_seal.boundary_id == boundary_id &&
            _boundary_seal.day == day) {
            out = _boundary_seal;
            return true;
        }
        error = "country_boundary_already_sealed";
        return false;
    }
    _boundary_seal.session_epoch = session_epoch;
    _boundary_seal.boundary_id = boundary_id;
    _boundary_seal.day = day;
    _boundary_seal.last_admitted_submit_order = _submit_order;
    _boundary_seal.expected_base_generation = _generation;
    _boundary_seal.catalog_hash = catalog_hash();
    _boundary_seal_active = true;
    _next_boundary_id = std::max(_next_boundary_id, boundary_id + 1);
    out = _boundary_seal;
    return true;
}

void NativeCountryRuntime::close_boundary_seal() {
    _boundary_seal = {};
    _boundary_seal_active = false;
}

bool NativeCountryRuntime::protocol_contract_self_test(std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF ||
        _command_batch.active || _boundary_seal_active ||
        !_pending_commands.empty() || _peer_async_mode ||
        !_peer_pending_intents.empty() || !_peer_intent_queue.empty() ||
        !_peer_result_cache.empty()) {
        error = "country_protocol_test_requires_idle_runtime";
        return false;
    }
    int32_t slot = -1;
    for (int32_t candidate = 0;
         candidate < static_cast<int32_t>(_countries.active.size());
         ++candidate) {
        if (_countries.active[static_cast<size_t>(candidate)] != 0) {
            slot = candidate;
            break;
        }
    }
    if (slot < 0) {
        error = "country_protocol_test_country_missing";
        return false;
    }
    int32_t owned_cell = -1;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_cell_country_slot[static_cast<size_t>(cell)] == slot) {
            owned_cell = cell;
            break;
        }
    }
    if (owned_cell < 0) {
        error = "country_protocol_test_territory_missing";
        return false;
    }

    CountryCommandReceipt discarded;
    while (poll_typed_receipt(discarded)) {}
    const int64_t day = std::max<int64_t>(0, _last_committed_day + 1);
    const uint64_t handle = make_handle(slot);
    const uint64_t request_base =
        (0x4354525900000000ULL ^ (_session_epoch << 16U) ^
         (_generation << 8U)) & ~0xffULL;
    CountryTypedCommand first;
    first.request_id = request_base | 1ULL;
    first.producer_id = 7;
    first.sequence = 100;
    first.observed_generation = _generation;
    first.effective_day = day;
    first.opcode = COMMAND_RENAME_COUNTRY;
    first.target_handle = handle;
    first.display_name = "protocol.first";
    std::vector<CountryCommandReceipt> receipts;
    if (!submit_typed_commands(&first, 1, receipts, error) ||
        receipts.size() != 1 ||
        receipts[0].code != CountryCommandReceiptCode::ACCEPTED) {
        if (error.empty()) error = "country_protocol_test_first_admission";
        return false;
    }

    CountryBoundarySeal seal;
    const uint64_t explicit_boundary = _next_boundary_id + 100;
    if (!seal_boundary(_session_epoch, explicit_boundary, day, seal, error))
        return false;

    CountryTypedCommand second = first;
    second.request_id = request_base | 2ULL;
    second.sequence = 101;
    second.display_name = "protocol.second";
    if (!submit_typed_commands(&second, 1, receipts, error) ||
        receipts.size() != 1 ||
        receipts[0].code != CountryCommandReceiptCode::ACCEPTED) {
        if (error.empty()) error = "country_protocol_test_second_admission";
        return false;
    }
    const CountryCoreStepResult first_step = run_slice_core(day);
    if (first_step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED ||
        first_step.seal.boundary_id != explicit_boundary ||
        first_step.seal.last_admitted_submit_order != seal.last_admitted_submit_order ||
        _countries.display_name[static_cast<size_t>(slot)] != "protocol.first") {
        error = "country_protocol_test_seal_watermark";
        return false;
    }
    CountryCommandReceipt terminal;
    if (!poll_typed_receipt(terminal) ||
        terminal.request_id != first.request_id ||
        terminal.code != CountryCommandReceiptCode::COMMITTED ||
        poll_typed_receipt(discarded)) {
        error = "country_protocol_test_first_terminal";
        return false;
    }

    const CountryCoreStepResult second_step = run_slice_core(day);
    if (second_step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED ||
        second_step.seal.boundary_id == explicit_boundary ||
        _countries.display_name[static_cast<size_t>(slot)] != "protocol.second" ||
        !poll_typed_receipt(terminal) ||
        terminal.request_id != second.request_id ||
        terminal.code != CountryCommandReceiptCode::COMMITTED) {
        error = "country_protocol_test_second_terminal";
        return false;
    }

    CountryTypedCommand rejected = first;
    rejected.request_id = request_base | 3ULL;
    rejected.sequence = 102;
    rejected.observed_generation = _generation;
    rejected.effective_day = day + 1;
    rejected.opcode = COMMAND_CLAIM_UNOWNED_TERRITORY;
    rejected.cell = owned_cell;
    rejected.display_name.clear();
    if (!submit_typed_commands(&rejected, 1, receipts, error)) return false;
    const uint64_t generation_before_rejection = _generation;
    const CountryCoreStepResult rejected_step = run_slice_core(day + 1);
    if (rejected_step.status != CountryCoreStepStatus::REJECTED ||
        _generation != generation_before_rejection ||
        !poll_typed_receipt(terminal) ||
        terminal.request_id != rejected.request_id ||
        terminal.code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION) {
        error = "country_protocol_test_execution_rejection";
        return false;
    }

    if (!submit_typed_commands(&first, 1, receipts, error) ||
        receipts.size() != 1 ||
        receipts[0].code != CountryCommandReceiptCode::COMMITTED ||
        !_pending_commands.empty()) {
        error = "country_protocol_test_idempotent_replay";
        return false;
    }

    const uint64_t expected_hash = compute_state_hash();
    const uint64_t previous_session = _session_epoch;
    CountryCoreCheckpoint captured;
    if (!capture_core_checkpoint(captured, error)) return false;
    std::vector<uint8_t> encoded;
    if (!encode_country_core_checkpoint(captured, encoded, error)) return false;
    CountryCoreCheckpoint decoded;
    if (!decode_country_core_checkpoint(encoded.data(), encoded.size(),
                                        decoded, error) ||
        decoded.canonical_pkcn != captured.canonical_pkcn ||
        decoded.business_state_hash != expected_hash) {
        if (error.empty()) error = "country_protocol_test_checkpoint_roundtrip";
        return false;
    }
    std::vector<uint8_t> corrupted = encoded;
    corrupted[corrupted.size() / 2u] ^= 0x1u;
    CountryCoreCheckpoint rejected_checkpoint;
    std::string corruption_error;
    if (decode_country_core_checkpoint(corrupted.data(), corrupted.size(),
                                       rejected_checkpoint,
                                       corruption_error)) {
        error = "country_protocol_test_checkpoint_corruption";
        return false;
    }
    CountryCoreCheckpoint mismatched = decoded;
    mismatched.business_state_hash ^= FNV_PRIME;
    const uint64_t rejected_generation = _generation;
    const uint64_t rejected_session = _session_epoch;
    std::string mismatch_error;
    if (restore_core_checkpoint(mismatched, mismatch_error) ||
        mismatch_error != "country_checkpoint_business_state_mismatch" ||
        _generation != rejected_generation ||
        _session_epoch != rejected_session ||
        compute_state_hash() != expected_hash) {
        error = "country_protocol_test_checkpoint_rejection_not_atomic";
        return false;
    }
    std::vector<uint8_t> after_rejection;
    if (!encode_save(after_rejection, error) ||
        after_rejection != captured.canonical_pkcn) {
        if (error.empty())
            error = "country_protocol_test_checkpoint_rejection_mutated_state";
        return false;
    }
    if (!restore_core_checkpoint(decoded, error) ||
        _session_epoch == previous_session ||
        compute_state_hash() != expected_hash ||
        _typed_request_state.size() != decoded.request_states.size() ||
        _next_boundary_id != decoded.next_boundary_id) {
        if (error.empty()) error = "country_protocol_test_checkpoint_restore";
        return false;
    }
    return true;
}

void NativeCountryRuntime::push_typed_receipt(
        const Command &command, CountryCommandReceiptCode code,
        const std::string &reason) {
    if (command.request_id == 0) return;
    CountryCommandReceipt receipt;
    receipt.request_id = command.request_id;
    receipt.producer_id = command.producer_id;
    receipt.sequence = static_cast<uint64_t>(command.sequence);
    receipt.effective_day = command.effective_day;
    receipt.generation = _generation;
    receipt.code = code;
    receipt.reason = reason;
    _typed_request_state[receipt.request_id] = receipt;
    _typed_receipts.push_back(std::move(receipt));
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
    std::vector<int32_t> tax_rates = packed_i32(
        batch, "tax_rate_basis_points");
    std::vector<int32_t> tax_modes = packed_i32(
        batch, "tax_assessment_modes");
    if (tax_rates.empty()) {
        tax_rates = packed_i32(batch, "tax_rate_percent");
        for (int32_t &rate : tax_rates) {
            rate = static_cast<int32_t>(std::clamp<int64_t>(
                static_cast<int64_t>(rate) * 100,
                TAX_RATE_MIN_BP, TAX_RATE_MAX_BP));
        }
    }
    const std::vector<std::string> stable_ids = packed_strings(batch, "stable_ids");
    const std::vector<std::string> display_names = packed_strings(batch, "display_names");
    const size_t count = opcodes.size();
    if (count == 0) return fail("country_command_batch_empty");
    if (tax_kinds.empty()) tax_kinds.assign(count, -1);
    if (tax_items.empty()) tax_items.assign(count, -1);
    if (tax_rates.empty()) tax_rates.assign(count, 0);
    if (tax_modes.empty()) tax_modes.assign(count, TAX_MODE_PERCENT_BP);
    if (days.size() != count || sequences.size() != count || handles.size() != count ||
        cells.size() != count || aux.size() != count || domains.size() != count ||
        positions.size() != count || weights0.size() != count || weights1.size() != count ||
        weights2.size() != count || weights3.size() != count || values.size() != count ||
        tax_kinds.size() != count || tax_items.size() != count ||
        tax_rates.size() != count || tax_modes.size() != count ||
        stable_ids.size() != count ||
        display_names.size() != count)
        return fail("country_command_batch_shape_invalid");

    std::vector<Command> staged_commands;
    staged_commands.reserve(count);
    uint64_t next_submit_order = _submit_order;
    for (size_t i = 0; i < count; ++i) {
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
        command.tax_rate_basis_points = tax_rates[i];
        command.tax_assessment_mode = tax_modes[i];
        command.value = values[i];
        command.stable_id = stable_ids[i];
        command.display_name = display_names[i];
        command.submit_order = ++next_submit_order;
        std::string admission_error;
        if (!validate_admission_command(command, admission_error))
            return fail(admission_error);
        staged_commands.push_back(std::move(command));
    }
    _pending_commands.reserve(_pending_commands.size() + count);
    _pending_commands.insert(_pending_commands.end(),
        std::make_move_iterator(staged_commands.begin()),
        std::make_move_iterator(staged_commands.end()));
    _submit_order = next_submit_order;
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
        // The effect ABI uses `value` for full-width basis points. Catalogs
        // compiled before PKCN v12 keep their signed whole-percent payload.
        // Effect tax packing has no assessment-mode lane yet; default percent.
        command.tax_rate_basis_points =
            source.opcode >= COMMAND_SET_TAX_DEFAULT &&
                    source.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY &&
                    source.value >= TAX_RATE_MIN_BP &&
                    source.value <= TAX_RATE_MAX_BP
                ? static_cast<int32_t>(source.value)
                : static_cast<int32_t>(
                    static_cast<int16_t>(u16(source.payload[3], 48))) * 100;
        command.tax_assessment_mode = TAX_MODE_PERCENT_BP;
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
    if (_simulation_host != nullptr && !_sync_store_writes_forbidden &&
        _simulation_host->country_pod_configured()) {
        const RuntimeWorkerState host_state = _simulation_host->state();
        const bool host_live = host_state != RuntimeWorkerState::STOPPED &&
            host_state != RuntimeWorkerState::FAULTED;
        if (host_live) {
            std::vector<RuntimeCommandPacket> packets;
            packets.reserve(staged.size());
            const auto copy_fixed = [](auto &destination,
                                       const std::string &source) {
                size_t i = 0;
                for (; i + 1u < destination.size() && i < source.size(); ++i)
                    destination[i] = source[i];
                destination[i] = '\0';
            };
            for (const Command &command : staged) {
                RuntimeCountryCommand mirrored;
                mirrored.request_id =
                    _simulation_host->allocate_command_request_id();
                mirrored.producer_id = 0;
                mirrored.sequence = command.sequence > 0
                    ? static_cast<uint64_t>(command.sequence)
                    : _simulation_host->allocate_producer_sequence(0);
                mirrored.requested_day = command.effective_day;
                mirrored.effective_day = command.effective_day;
                mirrored.opcode = static_cast<uint16_t>(command.opcode);
                mirrored.target_handle = command.target_handle;
                mirrored.cell = command.cell;
                mirrored.aux = command.aux;
                mirrored.domain = command.domain;
                mirrored.position = command.position;
                for (size_t domain = 0; domain < mirrored.weights_bp.size();
                     ++domain) {
                    mirrored.weights_bp[domain] = command.weights_bp[domain];
                }
                mirrored.tax_kind = command.tax_kind;
                mirrored.tax_item = command.tax_item;
                mirrored.tax_rate_basis_points =
                    command.tax_rate_basis_points;
                mirrored.tax_assessment_mode =
                    command.tax_assessment_mode;
                mirrored.value = command.value;
                copy_fixed(mirrored.stable_id, command.stable_id);
                copy_fixed(mirrored.display_name, command.display_name);
                RuntimeCommandPacket packet;
                packet.envelope.request_id = mirrored.request_id;
                packet.envelope.producer_id = mirrored.producer_id;
                packet.envelope.sequence = mirrored.sequence;
                packet.envelope.requested_day = mirrored.requested_day;
                packet.envelope.effective_day = mirrored.effective_day;
                packet.envelope.domain = static_cast<uint16_t>(
                    RuntimeDomainId::COUNTRY);
                packet.envelope.opcode = mirrored.opcode;
                packet.envelope.payload_size = sizeof(RuntimeCountryCommand);
                std::memcpy(packet.payload.data(), &mirrored,
                            sizeof(RuntimeCountryCommand));
                packets.push_back(packet);
            }
            if (!packets.empty() &&
                !_simulation_host->enqueue_batch(std::move(packets))) {
                error = "country_effect_shadow_mirror_capacity_exceeded";
                return false;
            }
        }
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
    // Worker owns the Country day. The sync facade must not keep the
    // economy/runtime-graph gate hot on leftover local queues / tech state —
    // main-thread peer work goes through service_peer_intents_main_thread.
    if (_sync_store_writes_forbidden) return false;
    if (_command_batch.active) return true;
    if (!_peer_pending_intents.empty()) return true;
    if (peer_rejection_needs_service(day_index)) return true;
    // Trigger/Effect often enqueue DISCOVER with effective_day = event.day + 1.
    // Incomplete effect results for those future commands must not pin today;
    // the due-command scan below already covers same-day Effect work, and an
    // in-flight batch is handled by _command_batch.active.
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    if (_technology_points_good_id >= 0) {
        if (_pending_queue_enabled) {
            if (_pending_activation_index_dirty) rebuild_pending_activation_index();
            for (int32_t slot = 0;
                 slot < static_cast<int32_t>(_pending_activation_indices.size());
                 ++slot) {
                for (const int32_t technology :
                         _pending_activation_indices[static_cast<size_t>(slot)]) {
                    if (!peer_rejection_blocks_activation(slot, technology,
                                                           day_index))
                        return true;
                }
            }
        } else {
            for (int32_t slot = 0;
                 slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
                if (_countries.active[static_cast<size_t>(slot)] == 0) continue;
                const size_t word_base = static_cast<size_t>(slot) *
                    static_cast<size_t>(_technology_words);
                for (int32_t word = 0; word < _technology_words; ++word) {
                    uint64_t pending = _country_pending_technologies[
                        word_base + static_cast<size_t>(word)];
                    while (pending != 0) {
                        uint64_t low_bit = pending;
                        int32_t bit = 0;
                        while ((low_bit & 1u) == 0u) {
                            low_bit >>= 1u;
                            ++bit;
                        }
                        const int32_t technology = word * 64 + bit;
                        if (technology < static_cast<int32_t>(_technology_ids.size()) &&
                            !peer_rejection_blocks_activation(
                                slot, technology, day_index))
                            return true;
                        pending &= pending - 1;
                    }
                }
            }
        }
        for (const int32_t active_slot : _research_active_country_slots) {
            if (active_slot < 0 ||
                active_slot >= static_cast<int32_t>(_countries.active.size())) continue;
            const size_t slot = static_cast<size_t>(active_slot);
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
                    !peer_rejection_blocks_activation(
                        static_cast<int32_t>(slot), technology, day_index) &&
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
                        queue_base + static_cast<size_t>(domain)] != 0) {
                    const size_t queue_index = (slot * 4U +
                        static_cast<size_t>(domain)) * 8U;
                    const int32_t technology = _country_research_queues[queue_index];
                    if (technology >= 0 &&
                        !peer_rejection_blocks_activation(
                            static_cast<int32_t>(slot), technology, day_index))
                        return true;
                }
            }
        }
    }
    return false;
}

bool NativeCountryRuntime::run_day_pod(
        const RuntimeCountryDayContext &context,
        RuntimeCountryDayCommit &out) {
    out = RuntimeCountryDayCommit{};
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        out.error_code = RuntimeCountryPodError::NOT_BOOTSTRAPPED;
        return false;
    }
    if (context.day < 0 || !std::isfinite(context.speed_scale)) {
        out.error_code = RuntimeCountryPodError::INVALID_CONTEXT;
        return false;
    }
    // Research completion may call these peer runtimes for Effect/Modifier
    // ACK and economy milestones. They need their own POD barrier adapters
    // before Country can safely become a worker-owned domain.
    if (_effect_runtime != nullptr || _modifier_runtime != nullptr ||
        _economy_runtime != nullptr) {
        out.error_code = RuntimeCountryPodError::CROSS_DOMAIN_BARRIER_REQUIRED;
        return false;
    }

    _state_hash_cache_valid = false;
    const uint64_t visual_generation_before = _visual_era_generation;
    _pod_execution = true;
    struct PodExecutionReset {
        bool &value;
        ~PodExecutionReset() { value = false; }
    } reset{_pod_execution};
    const CountryCoreStepResult step = run_slice_core(context.day);
    if (!step.ok) {
        out.error_code = RuntimeCountryPodError::COMMAND_REJECTED;
        out.preflight_ok = 0;
        out.completed = step.done ? 1 : 0;
        return false;
    }

    out.completed = step.done ? 1 : 0;
    out.preflight_ok = 1;
    out.ack_required = step.day_barrier ? 1 : 0;
    out.changed_countries = static_cast<uint32_t>(
        std::max(0, step.changed_countries));
    out.changed_territory_cells = static_cast<uint32_t>(
        std::max(0, step.changed_cells));
    out.research_work_units = static_cast<uint64_t>(
        std::max<int64_t>(0, _research_countries_scanned)) +
        static_cast<uint64_t>(std::max<int64_t>(0, _research_pending_checks)) +
        static_cast<uint64_t>(std::max<int64_t>(0, _research_discovery_checks));
    out.country_generation = _generation;
    out.state_hash = static_cast<uint64_t>(state_hash());
    if (step.changed_countries > 0)
        out.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
    if (step.changed_cells > 0)
        out.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY;
    if (_visual_era_generation != visual_generation_before)
        out.dirty_families |= RUNTIME_DIRTY_COUNTRY_VISUAL_ERA;
    return true;
}

bool NativeCountryRuntime::export_pod_snapshot(
        RuntimeCountryPodSnapshot &out, std::string &error) const {
    out = RuntimeCountryPodSnapshot{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_not_bootstrapped";
        return false;
    }
    out.generation = _generation;
    out.committed_day = _last_committed_day;
    out.last_research_day = _last_research_day;
    out.session_epoch = _session_epoch;
    out.cell_count = static_cast<uint32_t>(std::max(0, _cell_count));
    out.country_count = static_cast<uint32_t>(_countries.active.size());
    out.technology_words = static_cast<uint32_t>(std::max(0, _technology_words));
    out.technology_count = static_cast<uint32_t>(_technology_ids.size());
    out.good_count = static_cast<uint32_t>(_good_ids.size());
    out.profession_count = static_cast<uint32_t>(_profession_ids.size());
    out.building_type_count = static_cast<uint32_t>(_building_type_ids.size());
    out.research_signal_words = static_cast<uint32_t>(std::max(0, _research_signal_words));
    out.research_signal_count = static_cast<uint32_t>(_research_signal_ids.size());
    out.catalog_hash = _technology_catalog_identity_hash;
    out.bootstrapped = true;
    out.research_active_index_valid = true;
    out.country_active = _countries.active;
    out.country_generation = _countries.generation;
    out.country_stable_ids = _countries.stable_id;
    out.country_display_names = _countries.display_name;
    out.research_active_country_slots = _research_active_country_slots;
    out.territory_count = _countries.territory_count;
    out.country_state_version = _countries.state_version;
    out.country_cash = _countries.cash;
    out.country_goods = _country_goods;
    out.cell_country_slot = _cell_country_slot;
    out.territory_offsets = _country_cell_offsets;
    out.territory_cells = _country_cells;
    out.country_technologies = _country_technologies;
    out.country_discovered = _country_discovered;
    out.country_pending_technologies = _country_pending_technologies;
    out.country_research_signals = _country_research_signals;
    out.research_signal_cell_offsets.assign(
        _country_research_signal_cells.size() + 1u, 0);
    for (size_t slot = 0; slot < _country_research_signal_cells.size(); ++slot) {
        out.research_signal_cell_offsets[slot + 1u] =
            out.research_signal_cell_offsets[slot] +
            static_cast<int32_t>(_country_research_signal_cells[slot].size());
        out.research_signal_cells.insert(out.research_signal_cells.end(),
            _country_research_signal_cells[slot].begin(),
            _country_research_signal_cells[slot].end());
    }
    out.research_signal_evidence_offsets.assign(
        _country_research_signal_evidence.size() + 1u, 0);
    for (size_t slot = 0; slot < _country_research_signal_evidence.size(); ++slot) {
        const auto &entries = _country_research_signal_evidence[slot];
        out.research_signal_evidence_offsets[slot + 1u] =
            out.research_signal_evidence_offsets[slot] +
            static_cast<int32_t>(entries.size());
        for (const SignalEvidence &entry : entries) {
            RuntimeCountryPodSnapshot::SignalEvidence copy;
            copy.signal = entry.signal;
            copy.count = entry.count;
            copy.first_day = entry.first_day;
            copy.last_day = entry.last_day;
            copy.first_cell = entry.first_cell;
            out.research_signal_evidence.push_back(copy);
        }
    }
    out.research_queues = _country_research_queues;
    out.research_queue_lengths = _country_research_queue_lengths;
    out.research_weights_bp = _country_research_weights_bp;
    out.research_daily_budgets = _country_research_daily_budgets;
    out.research_deferred_points = _country_research_deferred_points;
    out.research_progress_total = _country_research_progress_total;
    out.research_completed_total = _country_research_completed_total;
    out.research_auto_purchase = _country_research_auto_purchase;
    out.research_purchased_total = _country_research_purchased_total;
    out.research_consumed_total = _country_research_consumed_total;
    out.country_tax_defaults = _country_tax_defaults;
    out.country_tax_default_modes = _country_tax_default_modes;
    out.country_income_tax_overrides = _country_income_tax_overrides;
    out.country_consumption_tax_overrides = _country_consumption_tax_overrides;
    out.country_business_tax_overrides = _country_business_tax_overrides;
    out.country_import_tax_overrides = _country_import_tax_overrides;
    out.country_export_tax_overrides = _country_export_tax_overrides;
    out.country_income_tax_mode_overrides = _country_income_tax_mode_overrides;
    out.country_consumption_tax_mode_overrides = _country_consumption_tax_mode_overrides;
    out.country_business_tax_mode_overrides = _country_business_tax_mode_overrides;
    out.country_import_tax_mode_overrides = _country_import_tax_mode_overrides;
    out.country_export_tax_mode_overrides = _country_export_tax_mode_overrides;
    out.cell_tax_policy_ids = _cell_tax_policy_ids;
    out.cell_tax_policies.resize(_cell_tax_policies.size());
    for (size_t index = 0; index < _cell_tax_policies.size(); ++index) {
        for (uint32_t kind = 0; kind < RuntimeCountryPodSnapshot::TAX_KIND_COUNT; ++kind) {
            out.cell_tax_policies[index].defaults[kind] =
                _cell_tax_policies[index].defaults[kind];
            out.cell_tax_policies[index].modes[kind] =
                _cell_tax_policies[index].default_modes[kind];
        }
        for (const CellTaxOverride &entry : _cell_tax_policies[index].overrides) {
            out.cell_tax_policies[index].overrides.push_back({
                entry.kind, entry.item, entry.rate, entry.mode});
        }
    }
    out.research_progress.resize(_country_research_progress.size() *
                                 static_cast<size_t>(out.technology_count), 0);
    for (size_t slot = 0; slot < _country_research_progress.size(); ++slot) {
        for (const auto &entry : _country_research_progress[slot]) {
            if (entry.first < 0 || entry.first >= static_cast<int32_t>(out.technology_count))
                continue;
            out.research_progress[slot * out.technology_count +
                                   static_cast<size_t>(entry.first)] = entry.second;
        }
    }
    out.research_cost_factor.assign(out.country_count, 1.0);
    out.research_efficiency.assign(
        static_cast<size_t>(out.country_count) * 4u, 1.0);
    if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
        static constexpr const char *EFFICIENCY_STATS[4] = {
            "country.research.agriculture_efficiency",
            "country.research.engineering_efficiency",
            "country.research.science_efficiency",
            "country.research.society_efficiency",
        };
        for (uint32_t slot = 0; slot < out.country_count; ++slot) {
            if (_countries.active[slot] == 0) continue;
            const uint64_t handle = make_handle(static_cast<int32_t>(slot));
            double cost_factor = _modifier_runtime->effective_value(
                ModifierRuntime::COUNTRY, "country.research.cost_factor",
                handle, 0, 1.0);
            if (!(cost_factor > 0.0) || !std::isfinite(cost_factor))
                cost_factor = 1.0;
            out.research_cost_factor[slot] = cost_factor;
            for (uint32_t domain = 0; domain < 4u; ++domain) {
                double efficiency = _modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, EFFICIENCY_STATS[domain],
                    handle, 0, 1.0);
                if (!(efficiency > 0.0) || !std::isfinite(efficiency))
                    efficiency = 1.0;
                out.research_efficiency[static_cast<size_t>(slot) * 4u + domain] =
                    efficiency;
            }
        }
    }
    out.research_peer_flags.assign(
        static_cast<size_t>(out.country_count) * out.technology_count, 0);
    for (uint32_t slot = 0; slot < out.country_count; ++slot) {
        for (uint32_t technology = 0; technology < out.technology_count; ++technology) {
            const size_t word = static_cast<size_t>(slot) * out.technology_words +
                technology / 64u;
            const uint64_t bit = uint64_t{1} << (technology % 64u);
            if ((out.country_pending_technologies[word] & bit) == 0) continue;
            uint8_t flags = 0;
            if (_effect_runtime_enabled && _effect_runtime != nullptr) {
                const uint64_t target = make_handle(static_cast<int32_t>(slot));
                const uint64_t effect_id = ((target & 0x00007fffffffffffULL) << 16U) +
                    static_cast<uint64_t>(technology + 1u);
                const uint32_t effect_generation = static_cast<uint32_t>(target >> 32U);
                if (_effect_runtime->has_instance_pod(
                        static_cast<int64_t>(effect_id), effect_generation))
                    flags |= COUNTRY_PEER_EFFECT_EXISTS;
                if (_effect_runtime->instance_fire_acked_pod(
                        static_cast<int64_t>(effect_id), effect_generation))
                    flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            }
            if (_modifier_runtime != nullptr && _modifier_runtime->configured() &&
                technology < _technology_modifier_definition_keys.size() &&
                !_technology_modifier_definition_keys[technology].empty() &&
                _modifier_runtime->has_technology_effect(
                    make_handle(static_cast<int32_t>(slot)),
                    _technology_modifier_definition_keys[technology],
                    static_cast<int32_t>(technology)))
                flags |= COUNTRY_PEER_MODIFIER_APPLIED;
            out.research_peer_flags[static_cast<size_t>(slot) * out.technology_count +
                                    technology] = flags;
        }
    }
    out.is_water = _is_water;
    if (out.cell_count != out.cell_country_slot.size() ||
        out.country_count != out.country_generation.size() ||
        out.country_count != out.country_active.size() ||
        out.country_count != out.country_state_version.size() ||
        out.country_count * out.good_count != out.country_goods.size() ||
        out.research_cost_factor.size() != out.country_count ||
        out.research_efficiency.size() != out.country_count * 4u ||
        out.research_peer_flags.size() !=
            static_cast<size_t>(out.country_count) * out.technology_count ||
        (out.research_signal_words > 0 &&
         out.country_count * out.research_signal_words !=
             out.country_research_signals.size()) ||
        out.research_signal_evidence_offsets.size() !=
            static_cast<size_t>(out.country_count) + 1u ||
        out.research_signal_cell_offsets.size() !=
            static_cast<size_t>(out.country_count) + 1u ||
        out.territory_offsets.size() != static_cast<size_t>(out.country_count) + 1u ||
        out.territory_offsets.back() != static_cast<int32_t>(out.territory_cells.size())) {
        error = "country_pod_snapshot_shape_mismatch";
        out = RuntimeCountryPodSnapshot{};
        return false;
    }
    out.state_hash = country_core_hash_business_state(out);
    return true;
}

bool NativeCountryRuntime::export_pod_catalog(
        RuntimeCountryPodCatalog &out, std::string &error) const {
    out = RuntimeCountryPodCatalog{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_not_bootstrapped";
        return false;
    }
    out.catalog_hash = _technology_catalog_identity_hash;
    out.technology_count = static_cast<uint32_t>(_technology_ids.size());
    out.technology_words = static_cast<uint32_t>(std::max(0, _technology_words));
    out.technology_points_good_id = _technology_points_good_id;
    out.technology_costs = _technology_costs;
    out.technology_domains = _technology_domains;
    out.technology_flags = _technology_flags;
    out.technology_effect_required.resize(out.technology_count, 0);
    for (size_t technology = 0; technology < out.technology_count; ++technology)
        out.technology_effect_required[technology] =
            technology < _technology_modifier_definition_keys.size() &&
            !_technology_modifier_definition_keys[technology].empty() ? 1u : 0u;
    out.prerequisite_offsets = _technology_prerequisite_offsets;
    out.prerequisites = _technology_prerequisites;
    out.milestone_offsets = _technology_milestone_offsets;
    out.milestone_candidates = _technology_milestone_candidates;
    out.milestone_required_counts = _technology_milestone_required_counts;
    out.entry_milestone_indices = _technology_entry_milestone_indices;
    out.research_condition_offsets = _technology_research_condition_offsets;
    out.research_condition_ops = _technology_research_condition_ops;
    out.research_condition_refs = _technology_research_condition_refs;
    out.research_condition_values = _technology_research_condition_values;
    out.reveal_condition_offsets = _technology_reveal_condition_offsets;
    out.reveal_condition_ops = _technology_reveal_condition_ops;
    out.reveal_condition_refs = _technology_reveal_condition_refs;
    out.reveal_condition_values = _technology_reveal_condition_values;
    out.starting_technologies = _starting_technologies;
    out.research_conditions_complete =
        out.research_condition_offsets.size() ==
            static_cast<size_t>(out.technology_count) + 1u &&
        out.research_condition_ops.size() == out.research_condition_refs.size() &&
        out.research_condition_ops.size() == out.research_condition_values.size() &&
        !out.research_condition_offsets.empty() &&
        out.research_condition_offsets.back() ==
            static_cast<int32_t>(out.research_condition_ops.size());
    return true;
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
    CountryCoreStepResult result = run_slice_core(requested_day);
    if (result.status == CountryCoreStepStatus::OFF) {
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["stage"] = "idle";
        out["path"] = "off";
        out["core_status"] = country_core_step_status_name(result.status);
        return out;
    }

    publish_report(result.stage.c_str(), requested_day, result.preflight_ms,
                   result.apply_ms, result.publish_ms,
                   result.changed_cells, result.changed_countries,
                   result.published_to_slot, result.reason);
    Dictionary out = report();
    out["ok"] = result.ok;
    out["done"] = result.done;
    out["stage"] = String(result.stage.c_str());
    out["path"] = String(result.path.c_str());
    out["core_status"] = country_core_step_status_name(result.status);
    out["elapsed_ms"] = result.elapsed_ms;
    out["cursor_start"] = result.cursor_start;
    out["cursor_end"] = result.cursor_end;
    out["cursor_total"] = result.cursor_total;
    out["progress_ratio"] = result.progress_ratio;
    out["country_day_barrier"] = result.day_barrier;
    out["observation_batch_input"] = result.observation_batch_input;
    out["observation_batch_added"] = result.observation_batch_added;
    if (!result.reason.empty()) out["fatal_reason"] = result.reason.c_str();
    if (!result.changed_cell_indices.empty()) {
        PackedInt32Array changed_cells;
        PackedInt32Array changed_owners;
        changed_cells.resize(static_cast<int64_t>(result.changed_cell_indices.size()));
        changed_owners.resize(static_cast<int64_t>(result.changed_cell_owners.size()));
        std::memcpy(changed_cells.ptrw(), result.changed_cell_indices.data(),
                    result.changed_cell_indices.size() * sizeof(int32_t));
        std::memcpy(changed_owners.ptrw(), result.changed_cell_owners.data(),
                    result.changed_cell_owners.size() * sizeof(int32_t));
        out["_changed_cell_indices"] = changed_cells;
        out["_changed_cell_owners"] = changed_owners;
    }
    return out;
}

CountryCoreStepResult NativeCountryRuntime::run_slice_core(
        int64_t requested_day) {
    CountryCoreStepResult result;
    if (_mode == MODE_OFF) {
        result.status = CountryCoreStepStatus::OFF;
        result.path = "off";
        return result;
    }

    if (!_command_batch.active) {
        if (!_boundary_seal_active) open_implicit_boundary(requested_day);
        result.seal = _boundary_seal;
        if (_boundary_seal.session_epoch != _session_epoch) {
            result.status = CountryCoreStepStatus::REJECTED;
            result.ok = false;
            result.stage = "boundary_seal";
            result.reason = "country_boundary_session_mismatch";
            close_boundary_seal();
            return result;
        }
        if (_boundary_seal.day != requested_day) {
            result.status = CountryCoreStepStatus::REJECTED;
            result.ok = false;
            result.stage = "boundary_seal";
            result.reason = "country_boundary_day_mismatch";
            close_boundary_seal();
            return result;
        }
        if (_boundary_seal.expected_base_generation != _generation ||
            _boundary_seal.catalog_hash != catalog_hash()) {
            result.status = CountryCoreStepStatus::REJECTED;
            result.ok = false;
            result.stage = "boundary_seal";
            result.reason = "country_boundary_base_mismatch";
            close_boundary_seal();
            return result;
        }
        begin_reference_boundary(requested_day);
    } else {
        result.seal = _boundary_seal;
    }

    // A slice may commit commands, research progress, goods, territory, or
    // signal evidence. Invalidate the transient hash cache at the slice
    // boundary; the generation/research/tax keys still avoid repeated scans
    // between reports and bridge queries in the same committed state.
    _state_hash_cache_valid = false;

    // A peer rejection is a durable protocol outcome, not an idle result.
    // Report it once at the next semantic boundary before admitting another
    // command batch. The committed Country state remains intact; only the
    // rejected peer operation is blocked until its retry day.
    const auto peer_rejection_result = [&]() {
        const CountryPeerProtocolStatus status = peer_protocol_status();
        if (_command_batch.active || status.has_unreported_rejection == 0 ||
            !peer_rejection_needs_service(requested_day))
            return false;
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.done = true;
        result.semantic_commit = false;
        result.day_barrier = false;
        result.stage = "peer_rejection";
        result.reason = status.rejection_reason[0] != '\0'
            ? std::string(status.rejection_reason.data())
            : "country_peer_result_rejected";
        mark_peer_rejections_reported(requested_day);
        record_reference_frame("peer_rejected", requested_day, false, false);
        close_boundary_seal();
        return true;
    };
    if (peer_rejection_result()) return result;

    const Clock::time_point start = Clock::now();
    if (!_command_batch.active) {
        const uint64_t admitted_watermark =
            _boundary_seal.last_admitted_submit_order;
        const auto admitted_and_due = [&](const Command &command) {
            return command.submit_order <= admitted_watermark &&
                command.effective_day <= requested_day;
        };
        const bool all_selected = std::all_of(
            _pending_commands.begin(), _pending_commands.end(), admitted_and_due);
        if (all_selected) {
            _command_batch.commands.swap(_pending_commands);
        } else {
            std::vector<Command> future_commands;
            _command_batch.commands.reserve(_pending_commands.size());
            future_commands.reserve(_pending_commands.size());
            for (Command &command : _pending_commands) {
                if (admitted_and_due(command))
                    _command_batch.commands.push_back(std::move(command));
                else
                    future_commands.push_back(std::move(command));
            }
            _pending_commands.swap(future_commands);
        }
        if (_command_batch.commands.empty()) {
            CountryPeerContext peer_context;
            std::string peer_error;
            if (!capture_peer_context(requested_day,
                                      _reference_continuation_index,
                                      peer_context, peer_error)) {
                result.status = CountryCoreStepStatus::FAULTED;
                result.ok = false;
                result.done = true;
                result.stage = "peer_context_capture";
                result.reason = peer_error.empty()
                    ? "country_peer_context_capture_failed" : peer_error;
                close_boundary_seal();
                return result;
            }
            const int32_t research_changed = run_research_day(
                requested_day, &peer_context, &peer_context);
            if (!_peer_protocol_fault_reason.empty()) {
                result.status = CountryCoreStepStatus::FAULTED;
                result.ok = false;
                result.done = true;
                result.stage = "peer_retry";
                result.reason = _peer_protocol_fault_reason;
                close_boundary_seal();
                return result;
            }
            if (peer_rejection_result()) return result;
            _last_committed_day = std::max(_last_committed_day, requested_day);
            const bool day_barrier = ack_chain_due(requested_day,
                                                   &peer_context);
            const double total_ms = elapsed_ms(start);
            result.status = day_barrier
                ? CountryCoreStepStatus::NEED_PEER_RESULTS
                : CountryCoreStepStatus::DAY_QUIESCENT;
            result.semantic_commit = true;
            result.day_barrier = day_barrier;
            result.stage = research_changed > 0 ? "research_publish" : "idle";
            result.publish_ms = total_ms;
            result.elapsed_ms = total_ms;
            result.changed_countries = research_changed;
            record_reference_frame(research_changed > 0
                    ? "research_publish" : "idle",
                requested_day, true, day_barrier);
            close_boundary_seal();
            // Research completion registers Effect instances after the morning
            // Effect slot. Raise the barrier so the continuation drain can ACK
            // before the next country day; country should_run is already false
            // because _last_research_day == requested_day.
            return result;
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
            _command_batch.tax_default_modes = _country_tax_default_modes;
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
            _command_batch.income_tax_mode_overrides =
                _country_income_tax_mode_overrides;
            _command_batch.consumption_tax_mode_overrides =
                _country_consumption_tax_mode_overrides;
            _command_batch.business_tax_mode_overrides =
                _country_business_tax_mode_overrides;
            _command_batch.import_tax_mode_overrides =
                _country_import_tax_mode_overrides;
            _command_batch.export_tax_mode_overrides =
                _country_export_tax_mode_overrides;
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
        struct Observation {
            int32_t slot;
            uint64_t key;
            uint64_t handle;
            int32_t source;
            int64_t effective_day;
        };
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
                int32_t(command.value),
                command.effective_day});
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
                        int64_t first_effective_day =
                            std::numeric_limits<int64_t>::max();
                        int64_t last_effective_day = 0;
                        for (size_t added_index = added_begin;
                             added_index < added_end; ++added_index) {
                            const auto observation = std::lower_bound(
                                incoming.begin() + static_cast<ptrdiff_t>(begin),
                                incoming.begin() + static_cast<ptrdiff_t>(end),
                                added[added_index],
                                [](const Observation &candidate, uint64_t key) {
                                    return candidate.key < key;
                                });
                            if (observation ==
                                incoming.begin() + static_cast<ptrdiff_t>(end))
                                continue;
                            first_effective_day = std::min(
                                first_effective_day, observation->effective_day);
                            last_effective_day = std::max(
                                last_effective_day, observation->effective_day);
                        }
                        if (first_effective_day ==
                            std::numeric_limits<int64_t>::max()) {
                            first_effective_day = day;
                            last_effective_day = day;
                        }
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
                            entry.first_day = first_effective_day;
                            entry.first_cell = first_cell;
                            evidence_it = evidence.insert(evidence_it, entry);
                        }
                        evidence_it->count += delta;
                        evidence_it->last_day = std::max(
                            evidence_it->last_day, last_effective_day);
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
            batch.tax_default_modes.resize(
                static_cast<size_t>(new_slot + 1) * TAX_KIND_COUNT,
                TAX_MODE_PERCENT_BP);
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
            batch.income_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _profession_ids.size(),
                TAX_MODE_INHERIT);
            batch.consumption_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_MODE_INHERIT);
            batch.business_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) *
                    _building_type_ids.size(),
                TAX_MODE_INHERIT);
            batch.import_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_MODE_INHERIT);
            batch.export_tax_mode_overrides.resize(
                static_cast<size_t>(new_slot + 1) * _good_ids.size(),
                TAX_MODE_INHERIT);
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
                    entry.first_day = command.effective_day;
                    entry.last_day = command.effective_day;
                    entry.first_cell = command.cell;
                    evidence_it = evidence.insert(evidence_it, entry);
                }
                ++evidence_it->count;
                evidence_it->last_day = command.effective_day;
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
            const bool needs_value =
                command.opcode != COMMAND_CLEAR_TAX_OVERRIDE;
            if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
                (needs_value &&
                 (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
                  !tax_value_valid(command.tax_assessment_mode,
                                  command.tax_rate_basis_points)))) {
                error = "country_tax_command_invalid";
                break;
            }
            if (command.opcode == COMMAND_SET_TAX_DEFAULT) {
                const size_t index =
                    static_cast<size_t>(slot) * TAX_KIND_COUNT +
                    command.tax_kind;
                batch.tax_defaults[index] = command.tax_rate_basis_points;
                batch.tax_default_modes[index] = command.tax_assessment_mode;
            } else {
                const int32_t item_count = tax_item_count(command.tax_kind);
                if (command.tax_item < 0 || command.tax_item >= item_count) {
                    error = "country_tax_item_invalid";
                    break;
                }
                std::vector<int32_t> *overrides = nullptr;
                std::vector<int32_t> *mode_overrides = nullptr;
                switch (command.tax_kind) {
                    case TAX_INCOME:
                        overrides = &batch.income_tax_overrides;
                        mode_overrides = &batch.income_tax_mode_overrides;
                        break;
                    case TAX_CONSUMPTION:
                        overrides = &batch.consumption_tax_overrides;
                        mode_overrides =
                            &batch.consumption_tax_mode_overrides;
                        break;
                    case TAX_BUSINESS:
                        overrides = &batch.business_tax_overrides;
                        mode_overrides = &batch.business_tax_mode_overrides;
                        break;
                    case TAX_IMPORT:
                        overrides = &batch.import_tax_overrides;
                        mode_overrides = &batch.import_tax_mode_overrides;
                        break;
                    case TAX_EXPORT:
                        overrides = &batch.export_tax_overrides;
                        mode_overrides = &batch.export_tax_mode_overrides;
                        break;
                    default: break;
                }
                if (overrides == nullptr || mode_overrides == nullptr) {
                    error = "country_tax_kind_invalid";
                    break;
                }
                const size_t index =
                    static_cast<size_t>(slot) * item_count + command.tax_item;
                if (command.opcode == COMMAND_CLEAR_TAX_OVERRIDE) {
                    (*overrides)[index] = TAX_RATE_INHERIT;
                    (*mode_overrides)[index] = TAX_MODE_INHERIT;
                } else {
                    (*overrides)[index] = command.tax_rate_basis_points;
                    (*mode_overrides)[index] = command.tax_assessment_mode;
                }
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
                if (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
                    !tax_value_valid(command.tax_assessment_mode,
                                    command.tax_rate_basis_points)) {
                    error = "country_cell_tax_rate_invalid";
                    break;
                }
                policy.defaults[static_cast<size_t>(command.tax_kind)] =
                    command.tax_rate_basis_points;
                policy.default_modes[static_cast<size_t>(command.tax_kind)] =
                    command.tax_assessment_mode;
            } else if (command.opcode == COMMAND_CLEAR_CELL_TAX_DEFAULT) {
                policy.defaults[static_cast<size_t>(command.tax_kind)] =
                    TAX_RATE_INHERIT;
                policy.default_modes[static_cast<size_t>(command.tax_kind)] =
                    TAX_MODE_INHERIT;
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
                    if (!tax_assessment_mode_valid(
                            command.tax_assessment_mode) ||
                        !tax_value_valid(command.tax_assessment_mode,
                                        command.tax_rate_basis_points)) {
                        error = "country_cell_tax_rate_invalid";
                        break;
                    }
                    const CellTaxOverride replacement{
                        command.tax_kind, command.tax_item,
                        command.tax_rate_basis_points,
                        command.tax_assessment_mode};
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
        const uint64_t command_hash = reference_command_hash(batch.commands);
        const uint64_t command_count =
            static_cast<uint64_t>(batch.commands.size());
        for (const Command &command : batch.commands) {
            push_typed_receipt(command,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION, error);
            if (command.effect_request_id == 0) continue;
            EffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        record_reference_frame("command_rejected", day, false, false,
                               command_hash, command_count);
        close_boundary_seal();
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.stage = "command_preflight";
        result.reason = error;
        result.preflight_ms = preflight_ms;
        result.elapsed_ms = preflight_ms;
        return result;
    }

    if (batch.cursor < batch.commands.size()) {
        record_reference_frame("command_preflight", day, false, true,
            reference_command_hash(batch.commands),
            static_cast<uint64_t>(batch.commands.size()));
        result.status = CountryCoreStepStatus::PROGRESS;
        result.done = false;
        result.day_barrier = true;
        result.stage = "command_preflight";
        result.preflight_ms = batch.preflight_ms;
        result.elapsed_ms = batch.preflight_ms;
        result.cursor_start = static_cast<int64_t>(cursor_start);
        result.cursor_end = static_cast<int64_t>(batch.cursor);
        result.cursor_total = static_cast<int64_t>(batch.commands.size());
        result.progress_ratio = static_cast<double>(batch.cursor) /
            static_cast<double>(batch.commands.size());
        return result;
    }

    for (size_t slot = 0; slot < batch.countries.active.size(); ++slot) {
        if (batch.countries.active[slot] != 0 && batch.countries.territory_count[slot] <= 0) {
                error = "country_last_territory_protected";
            break;
        }
    }
    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        const uint64_t command_hash = reference_command_hash(batch.commands);
        const uint64_t command_count =
            static_cast<uint64_t>(batch.commands.size());
        for (const Command &command : batch.commands) {
            push_typed_receipt(command,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION, error);
            if (command.effect_request_id == 0) continue;
            EffectCommandResult &result = _effect_command_results[command.effect_request_id];
            result.complete = 1; result.ok = 0; result.reason = error;
        }
        _command_batch = {};
        record_reference_frame("command_rejected", day, false, false,
                               command_hash, command_count);
        close_boundary_seal();
        result.status = CountryCoreStepStatus::REJECTED;
        result.ok = false;
        result.stage = "command_preflight";
        result.reason = error;
        result.preflight_ms = preflight_ms;
        result.elapsed_ms = preflight_ms;
        return result;
    }

    const double preflight_ms = batch.preflight_ms;
    const uint64_t reference_batch_hash = reference_command_hash(batch.commands);
    const uint64_t reference_batch_count =
        static_cast<uint64_t>(batch.commands.size());
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
    std::vector<int32_t> staged_tax_defaults =
        std::move(batch.tax_defaults);
    std::vector<int32_t> staged_tax_default_modes =
        std::move(batch.tax_default_modes);
    std::vector<int32_t> staged_income_tax =
        std::move(batch.income_tax_overrides);
    std::vector<int32_t> staged_consumption_tax =
        std::move(batch.consumption_tax_overrides);
    std::vector<int32_t> staged_business_tax =
        std::move(batch.business_tax_overrides);
    std::vector<int32_t> staged_import_tax =
        std::move(batch.import_tax_overrides);
    std::vector<int32_t> staged_export_tax =
        std::move(batch.export_tax_overrides);
    std::vector<int32_t> staged_income_tax_modes =
        std::move(batch.income_tax_mode_overrides);
    std::vector<int32_t> staged_consumption_tax_modes =
        std::move(batch.consumption_tax_mode_overrides);
    std::vector<int32_t> staged_business_tax_modes =
        std::move(batch.business_tax_mode_overrides);
    std::vector<int32_t> staged_import_tax_modes =
        std::move(batch.import_tax_mode_overrides);
    std::vector<int32_t> staged_export_tax_modes =
        std::move(batch.export_tax_mode_overrides);
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
    std::vector<Command> committed_typed_commands;
    for (const Command &command : batch.commands) {
        if (command.request_id != 0) {
            Command receipt_command;
            receipt_command.request_id = command.request_id;
            receipt_command.producer_id = command.producer_id;
            receipt_command.sequence = command.sequence;
            receipt_command.effective_day = command.effective_day;
            committed_typed_commands.push_back(std::move(receipt_command));
        }
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
        _research_modifier_cache.resize(country_count);
        rebuild_research_active_index();
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
        _country_tax_default_modes = std::move(staged_tax_default_modes);
        _country_income_tax_overrides = std::move(staged_income_tax);
        _country_consumption_tax_overrides =
            std::move(staged_consumption_tax);
        _country_business_tax_overrides = std::move(staged_business_tax);
        _country_import_tax_overrides = std::move(staged_import_tax);
        _country_export_tax_overrides = std::move(staged_export_tax);
        _country_income_tax_mode_overrides =
            std::move(staged_income_tax_modes);
        _country_consumption_tax_mode_overrides =
            std::move(staged_consumption_tax_modes);
        _country_business_tax_mode_overrides =
            std::move(staged_business_tax_modes);
        _country_import_tax_mode_overrides =
            std::move(staged_import_tax_modes);
        _country_export_tax_mode_overrides =
            std::move(staged_export_tax_modes);
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
    for (const Command &command : committed_typed_commands)
        push_typed_receipt(command, CountryCommandReceiptCode::COMMITTED);
    if (!cell_delta_order.empty()) ++_territory_generation;
    _last_committed_day = day;
    for (Event &event : staged_events) push_event(std::move(event));
    CountryPeerContext peer_context;
    std::string peer_error;
    if (!capture_peer_context(day, _reference_continuation_index,
                              peer_context, peer_error)) {
        result.status = CountryCoreStepStatus::FAULTED;
        result.ok = false;
        result.done = true;
        result.stage = "peer_context_capture";
        result.reason = peer_error.empty()
            ? "country_peer_context_capture_failed" : peer_error;
        close_boundary_seal();
        return result;
    }
    const int32_t research_changed = run_research_day(
        day, &peer_context, &peer_context);
    if (!_peer_protocol_fault_reason.empty()) {
        result.status = CountryCoreStepStatus::FAULTED;
        result.ok = false;
        result.done = true;
        result.stage = "peer_retry";
        result.reason = _peer_protocol_fault_reason;
        close_boundary_seal();
        return result;
    }
    if (peer_rejection_result()) return result;
    const double aggregate_ms = elapsed_ms(publish_start);
    const bool day_barrier = should_run(day) ||
        ack_chain_due(day, &peer_context);
    result.status = CountryCoreStepStatus::BOUNDARY_COMMITTED;
    result.semantic_commit = true;
    result.day_barrier = day_barrier;
    result.stage = "aggregate_publish";
    result.preflight_ms = preflight_ms;
    result.apply_ms = apply_ms;
    result.publish_ms = aggregate_ms;
    result.elapsed_ms = preflight_ms + apply_ms + aggregate_ms;
    result.cursor_start = 0;
    result.cursor_end = static_cast<int64_t>(cursor_limit);
    result.cursor_total = static_cast<int64_t>(cursor_limit);
    result.progress_ratio = 1.0;
    result.changed_cells = static_cast<int32_t>(cell_delta_order.size());
    result.changed_countries = changed_country_count + research_changed;
    result.published_to_slot =
        _mode == MODE_ACTIVE && !cell_delta_order.empty();
    result.observation_batch_input = observation_batch_input;
    result.observation_batch_added = observation_batch_added;
    if (!cell_delta_order.empty()) {
        if (!std::is_sorted(cell_delta_order.begin(), cell_delta_order.end()))
            std::sort(cell_delta_order.begin(), cell_delta_order.end());
        result.changed_cell_indices.resize(cell_delta_order.size());
        result.changed_cell_owners.resize(cell_delta_order.size());
        for (size_t i = 0; i < cell_delta_order.size(); ++i) {
            result.changed_cell_indices[i] = cell_delta_order[i];
            int32_t owner = direct_unique_territory ? direct_cell_owners[i] : NEUTRAL_SLOT;
            if (!direct_unique_territory) cell_delta.get(cell_delta_order[i], owner);
            result.changed_cell_owners[i] = owner;
        }
    }
    record_reference_frame("aggregate_publish", day, true, day_barrier,
                           reference_batch_hash, reference_batch_count);
    close_boundary_seal();
    return result;
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
    _report["peer_async_mode"] = _peer_async_mode;
    _report["peer_pending_intents"] = static_cast<int64_t>(
        _peer_pending_intents.size());
    _report["peer_queued_intents"] = static_cast<int64_t>(
        _peer_intent_queue.size());
    _report["peer_cached_results"] = static_cast<int64_t>(
        _peer_result_cache.size());
    _report["peer_intents_emitted"] = static_cast<int64_t>(_peer_intents_emitted);
    _report["peer_results_consumed"] = static_cast<int64_t>(_peer_results_consumed);
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
    _report["state_generation"] = static_cast<int64_t>(_generation);
    _report["territory_generation"] =
        static_cast<int64_t>(_territory_generation);
    _report["research_generation"] =
        static_cast<int64_t>(_research_generation);
    _report["visual_generation"] =
        static_cast<int64_t>(_visual_era_generation);
    _report["research_activation_ms"] = _research_activation_ms;
    _report["research_allocation_ms"] = _research_allocation_ms;
    _report["research_effect_ack_ms"] = _research_effect_ack_ms;
    _report["research_discovery_ms"] = _research_discovery_ms;
    _report["research_modifier_ms"] = _research_modifier_ms;
    _report["research_countries_scanned"] = _research_countries_scanned;
    _report["research_active_countries"] = _research_active_countries;
    _report["research_pending_checks"] = _research_pending_checks;
    _report["research_discovery_checks"] = _research_discovery_checks;
    _report["research_discovery_frontier_mismatches"] =
        _research_discovery_frontier_mismatches;
    _report["research_modifier_queries"] = _research_modifier_queries;
    _report["research_modifier_cache_hits"] = _research_modifier_cache_hits;
    _report["research_remainder_iterations"] = _research_remainder_iterations;
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
    _report["research_report_ms"] = report_build_ms;
}

Dictionary NativeCountryRuntime::report() const {
    Dictionary out = _report.duplicate();
    const Dictionary transactions = economy_asset_transaction_report();
    out["economy_asset_transactions"] = transactions;
    out["economy_asset_ledger_failures"] = transactions.get(
        "ledger_failures", 0);
    return out;
}

NativeCountryRuntime::ReferenceHashes
NativeCountryRuntime::compute_reference_hashes() const {
    ReferenceHashes out;
    auto hash_count = [](uint64_t &hash, size_t count) {
        const uint64_t value = static_cast<uint64_t>(count);
        hash_bytes(hash, &value, sizeof(value));
    };
    auto hash_vector = [&](uint64_t &hash, const auto &values) {
        hash_count(hash, values.size());
        if (!values.empty())
            hash_bytes(hash, values.data(), values.size() * sizeof(values[0]));
    };
    auto hash_strings = [&](uint64_t &hash,
                            const std::vector<std::string> &values) {
        hash_count(hash, values.size());
        for (const std::string &value : values) hash_string(hash, value);
    };

    out.identity = FNV_OFFSET;
    hash_vector(out.identity, _countries.active);
    hash_vector(out.identity, _countries.generation);
    hash_strings(out.identity, _countries.stable_id);
    hash_strings(out.identity, _countries.display_name);
    hash_vector(out.identity, _countries.state_version);
    hash_bytes(out.identity, &_starting_country_slot,
               sizeof(_starting_country_slot));

    out.territory = FNV_OFFSET;
    hash_vector(out.territory, _countries.territory_count);
    hash_vector(out.territory, _cell_country_slot);
    hash_vector(out.territory, _country_cell_offsets);
    hash_vector(out.territory, _country_cells);

    out.treasury = FNV_OFFSET;
    hash_vector(out.treasury, _countries.cash);
    hash_vector(out.treasury, _country_goods);

    out.technology = FNV_OFFSET;
    hash_vector(out.technology, _country_technologies);
    hash_vector(out.technology, _country_discovered);
    hash_vector(out.technology, _country_pending_technologies);
    hash_vector(out.technology, _current_visual_era);
    hash_bytes(out.technology, &_era_reward_reference.plan_id,
               sizeof(_era_reward_reference.plan_id));
    hash_bytes(out.technology, &_era_reward_reference.offer_generation,
               sizeof(_era_reward_reference.offer_generation));
    hash_bytes(out.technology, &_era_reward_reference.milestone_technology,
               sizeof(_era_reward_reference.milestone_technology));
    hash_bytes(out.technology, &_era_reward_reference.status,
               sizeof(_era_reward_reference.status));

    out.research = FNV_OFFSET;
    hash_count(out.research, _country_research_progress.size());
    for (const auto &entries : _country_research_progress) {
        hash_count(out.research, entries.size());
        for (const auto &entry : entries) {
            hash_bytes(out.research, &entry.first, sizeof(entry.first));
            hash_bytes(out.research, &entry.second, sizeof(entry.second));
        }
    }
    hash_vector(out.research, _country_research_queues);
    hash_vector(out.research, _country_research_queue_lengths);
    hash_vector(out.research, _country_research_weights_bp);
    hash_vector(out.research, _country_research_auto_purchase);
    hash_vector(out.research, _country_research_daily_budgets);
    hash_vector(out.research, _country_research_deferred_points);
    hash_vector(out.research, _country_research_purchased_total);
    hash_vector(out.research, _country_research_consumed_total);
    hash_vector(out.research, _country_research_progress_total);
    hash_vector(out.research, _country_research_completed_total);
    hash_bytes(out.research, &_last_research_day,
               sizeof(_last_research_day));

    out.signals = FNV_OFFSET;
    hash_vector(out.signals, _country_research_signals);
    hash_count(out.signals, _country_research_signal_cells.size());
    for (const auto &cells : _country_research_signal_cells)
        hash_vector(out.signals, cells);
    hash_count(out.signals, _country_research_signal_evidence.size());
    for (const auto &entries : _country_research_signal_evidence) {
        hash_count(out.signals, entries.size());
        for (const SignalEvidence &entry : entries) {
            hash_bytes(out.signals, &entry.signal, sizeof(entry.signal));
            hash_bytes(out.signals, &entry.count, sizeof(entry.count));
            hash_bytes(out.signals, &entry.first_day, sizeof(entry.first_day));
            hash_bytes(out.signals, &entry.last_day, sizeof(entry.last_day));
            hash_bytes(out.signals, &entry.first_cell, sizeof(entry.first_cell));
        }
    }

    out.tax = FNV_OFFSET;
    hash_vector(out.tax, _country_tax_defaults);
    hash_vector(out.tax, _country_tax_default_modes);
    hash_vector(out.tax, _country_income_tax_overrides);
    hash_vector(out.tax, _country_consumption_tax_overrides);
    hash_vector(out.tax, _country_business_tax_overrides);
    hash_vector(out.tax, _country_import_tax_overrides);
    hash_vector(out.tax, _country_export_tax_overrides);
    hash_vector(out.tax, _country_income_tax_mode_overrides);
    hash_vector(out.tax, _country_consumption_tax_mode_overrides);
    hash_vector(out.tax, _country_business_tax_mode_overrides);
    hash_vector(out.tax, _country_import_tax_mode_overrides);
    hash_vector(out.tax, _country_export_tax_mode_overrides);
    hash_count(out.tax, _cell_tax_policy_ids.size());
    for (uint32_t policy_id : _cell_tax_policy_ids) {
        const CellTaxPolicy &policy = cell_tax_policy(policy_id);
        hash_vector(out.tax, policy.defaults);
        hash_vector(out.tax, policy.default_modes);
        hash_count(out.tax, policy.overrides.size());
        for (const CellTaxOverride &entry : policy.overrides) {
            hash_bytes(out.tax, &entry.kind, sizeof(entry.kind));
            hash_bytes(out.tax, &entry.item, sizeof(entry.item));
            hash_bytes(out.tax, &entry.rate, sizeof(entry.rate));
            hash_bytes(out.tax, &entry.mode, sizeof(entry.mode));
        }
    }

    out.effect = FNV_OFFSET;
    std::vector<std::pair<uint64_t, int64_t>> idempotency(
        _effect_command_idempotency.begin(), _effect_command_idempotency.end());
    std::sort(idempotency.begin(), idempotency.end());
    hash_count(out.effect, idempotency.size());
    for (const auto &entry : idempotency) {
        hash_bytes(out.effect, &entry.first, sizeof(entry.first));
        hash_bytes(out.effect, &entry.second, sizeof(entry.second));
    }
    std::vector<int64_t> result_ids;
    result_ids.reserve(_effect_command_results.size());
    for (const auto &entry : _effect_command_results)
        result_ids.push_back(entry.first);
    std::sort(result_ids.begin(), result_ids.end());
    hash_count(out.effect, result_ids.size());
    for (int64_t id : result_ids) {
        const EffectCommandResult &result = _effect_command_results.at(id);
        hash_bytes(out.effect, &id, sizeof(id));
        hash_bytes(out.effect, &result.complete, sizeof(result.complete));
        hash_bytes(out.effect, &result.ok, sizeof(result.ok));
        hash_string(out.effect, result.reason);
    }
    hash_bytes(out.effect, &_next_effect_request_id,
               sizeof(_next_effect_request_id));
    return out;
}

uint64_t NativeCountryRuntime::reference_command_hash(
        const std::vector<Command> &commands) const {
    uint64_t hash = FNV_OFFSET;
    const uint64_t count = static_cast<uint64_t>(commands.size());
    hash_bytes(hash, &count, sizeof(count));
    for (const Command &command : commands) {
        hash_bytes(hash, &command.request_id, sizeof(command.request_id));
        hash_bytes(hash, &command.producer_id, sizeof(command.producer_id));
        hash_bytes(hash, &command.observed_generation,
                   sizeof(command.observed_generation));
        hash_bytes(hash, &command.opcode, sizeof(command.opcode));
        hash_bytes(hash, &command.effective_day, sizeof(command.effective_day));
        hash_bytes(hash, &command.sequence, sizeof(command.sequence));
        hash_bytes(hash, &command.target_handle, sizeof(command.target_handle));
        hash_bytes(hash, &command.cell, sizeof(command.cell));
        hash_bytes(hash, &command.aux, sizeof(command.aux));
        hash_bytes(hash, &command.domain, sizeof(command.domain));
        hash_bytes(hash, &command.position, sizeof(command.position));
        hash_bytes(hash, command.weights_bp, sizeof(command.weights_bp));
        hash_bytes(hash, &command.tax_kind, sizeof(command.tax_kind));
        hash_bytes(hash, &command.tax_item, sizeof(command.tax_item));
        hash_bytes(hash, &command.tax_rate_basis_points,
                   sizeof(command.tax_rate_basis_points));
        hash_bytes(hash, &command.tax_assessment_mode,
                   sizeof(command.tax_assessment_mode));
        hash_bytes(hash, &command.value, sizeof(command.value));
        hash_string(hash, command.stable_id);
        hash_string(hash, command.display_name);
        hash_bytes(hash, &command.submit_order, sizeof(command.submit_order));
        hash_bytes(hash, &command.effect_request_id,
                   sizeof(command.effect_request_id));
        hash_bytes(hash, &command.effect_idempotency_key,
                   sizeof(command.effect_idempotency_key));
    }
    return hash;
}

void NativeCountryRuntime::begin_reference_boundary(int64_t day) {
    if (!_reference_trace_enabled) return;
    if (_boundary_seal_active &&
        _boundary_seal.session_epoch == _session_epoch) {
        _reference_boundary_id = _boundary_seal.boundary_id;
    } else {
        ++_reference_boundary_id;
    }
    _reference_boundary_day = day;
    _reference_continuation_index = 0;
    _reference_boundary_first_event_id =
        static_cast<int64_t>(_next_event_id);
}

void NativeCountryRuntime::record_reference_frame(
        const char *stage, int64_t day, bool semantic_commit,
        bool day_barrier, uint64_t command_hash, uint64_t command_count,
        int64_t first_event_id) {
    if (!_reference_trace_enabled) return;
    ReferenceFrame frame;
    frame.frame_id = _next_reference_frame_id++;
    frame.boundary_id = _reference_boundary_id;
    frame.continuation_index = _reference_continuation_index++;
    frame.day = day;
    frame.stage = stage != nullptr ? stage : "";
    frame.semantic_commit = semantic_commit;
    frame.day_barrier = day_barrier;
    frame.catalog_hash = catalog_hash();
    frame.technology_catalog_hash = _technology_catalog_identity_hash;
    frame.command_watermark = _boundary_seal_active
        ? _boundary_seal.last_admitted_submit_order : _submit_order;
    frame.command_hash = command_hash;
    frame.command_count = command_count;
    frame.business_state_hash = compute_state_hash();
    frame.hashes = compute_reference_hashes();
    frame.generation = _generation;
    frame.territory_generation = _territory_generation;
    frame.research_generation = _research_generation;
    frame.tax_generation = _tax_policy_version;
    frame.visual_generation = _visual_era_generation;
    frame.first_event_id = first_event_id != 0
        ? first_event_id : _reference_boundary_first_event_id;
    frame.last_event_id = _next_event_id > 0
        ? static_cast<int64_t>(_next_event_id - 1) : 0;
    for (const auto &entry : _effect_command_results) {
        ++frame.effect_intent_count;
        if (entry.second.complete != 0) ++frame.effect_ack_count;
    }
    _reference_frames.push_back(std::move(frame));
    while (_reference_frames.size() > _reference_trace_capacity)
        _reference_frames.pop_front();
}

void NativeCountryRuntime::record_direct_reference_frame(const char *stage) {
    if (!_reference_trace_enabled) return;
    begin_reference_boundary(_last_committed_day);
    record_reference_frame(stage, _last_committed_day, true, false);
}

Dictionary NativeCountryRuntime::configure_reference_trace(bool enabled,
                                                             int32_t max_frames) {
    Dictionary out;
    if (max_frames < 1 || max_frames > 65536) {
        out["ok"] = false;
        out["reason"] = "country_reference_capacity_invalid";
        return out;
    }
    _reference_trace_enabled = enabled;
    _reference_trace_capacity = static_cast<size_t>(max_frames);
    _reference_frames.clear();
    _next_reference_frame_id = 1;
    _reference_boundary_id = 0;
    _reference_continuation_index = 0;
    _reference_boundary_day = -1;
    _reference_boundary_first_event_id = 0;
    out["ok"] = true;
    out["enabled"] = enabled;
    out["capacity"] = max_frames;
    return out;
}

Dictionary NativeCountryRuntime::poll_reference_trace(int64_t after_frame_id,
                                                        int32_t limit) const {
    Dictionary out;
    Array frames;
    const int32_t bounded_limit = std::clamp(limit, 1, 4096);
    for (const ReferenceFrame &frame : _reference_frames) {
        if (static_cast<int64_t>(frame.frame_id) <= after_frame_id) continue;
        Dictionary item;
        item["frame_id"] = static_cast<int64_t>(frame.frame_id);
        item["boundary_id"] = static_cast<int64_t>(frame.boundary_id);
        item["continuation_index"] = static_cast<int64_t>(frame.continuation_index);
        item["day"] = frame.day;
        item["stage"] = String(frame.stage.c_str());
        item["semantic_commit"] = frame.semantic_commit;
        item["day_barrier"] = frame.day_barrier;
        item["catalog_hash"] = static_cast<int64_t>(frame.catalog_hash);
        item["technology_catalog_hash"] =
            static_cast<int64_t>(frame.technology_catalog_hash);
        item["command_watermark"] =
            static_cast<int64_t>(frame.command_watermark);
        item["command_hash"] = static_cast<int64_t>(frame.command_hash);
        item["command_count"] = static_cast<int64_t>(frame.command_count);
        item["business_state_hash"] =
            static_cast<int64_t>(frame.business_state_hash);
        item["identity_hash"] = static_cast<int64_t>(frame.hashes.identity);
        item["territory_hash"] = static_cast<int64_t>(frame.hashes.territory);
        item["treasury_hash"] = static_cast<int64_t>(frame.hashes.treasury);
        item["technology_hash"] = static_cast<int64_t>(frame.hashes.technology);
        item["research_hash"] = static_cast<int64_t>(frame.hashes.research);
        item["signal_hash"] = static_cast<int64_t>(frame.hashes.signals);
        item["tax_hash"] = static_cast<int64_t>(frame.hashes.tax);
        item["effect_hash"] = static_cast<int64_t>(frame.hashes.effect);
        item["generation"] = static_cast<int64_t>(frame.generation);
        item["territory_generation"] =
            static_cast<int64_t>(frame.territory_generation);
        item["research_generation"] =
            static_cast<int64_t>(frame.research_generation);
        item["tax_generation"] = static_cast<int64_t>(frame.tax_generation);
        item["visual_generation"] =
            static_cast<int64_t>(frame.visual_generation);
        item["first_event_id"] = frame.first_event_id;
        item["last_event_id"] = frame.last_event_id;
        item["effect_intent_count"] =
            static_cast<int64_t>(frame.effect_intent_count);
        item["effect_ack_count"] =
            static_cast<int64_t>(frame.effect_ack_count);
        frames.push_back(item);
        if (frames.size() >= bounded_limit) break;
    }
    out["ok"] = true;
    out["enabled"] = _reference_trace_enabled;
    out["frames"] = frames;
    out["retained"] = static_cast<int64_t>(_reference_frames.size());
    out["next_frame_id"] = static_cast<int64_t>(_next_reference_frame_id);
    return out;
}

Dictionary NativeCountryRuntime::capture_reference_checkpoint() const {
    Dictionary out;
    std::vector<uint8_t> bytes;
    std::string error;
    if (!encode_save(bytes, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    PackedByteArray packed;
    packed.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty())
        std::memcpy(packed.ptrw(), bytes.data(), bytes.size());
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["generation"] = static_cast<int64_t>(_generation);
    out["day"] = _last_committed_day;
    out["business_state_hash"] = static_cast<int64_t>(compute_state_hash());
    out["bytes"] = packed;
    return out;
}

bool NativeCountryRuntime::capture_core_checkpoint(
        CountryCoreCheckpoint &out, std::string &error) const {
    CountryCoreCheckpoint checkpoint;
    const CountryPeerProtocolStatus peer_status = peer_protocol_status();
    if (peer_status.pending_intents != 0 || peer_status.queued_intents != 0) {
        error = "country_checkpoint_peer_pending";
        return false;
    }
    if (peer_status.rejected_intents != 0) {
        error = "country_checkpoint_peer_rejected_retry_pending";
        return false;
    }
    if (!encode_save(checkpoint.canonical_pkcn, error)) return false;
    checkpoint.session_epoch = _session_epoch;
    checkpoint.catalog_hash = catalog_hash();
    checkpoint.generation = _generation;
    checkpoint.committed_day = _last_committed_day;
    checkpoint.business_state_hash = compute_state_hash();
    checkpoint.command_watermark = _submit_order;
    checkpoint.next_event_id = _next_event_id;
    checkpoint.next_boundary_id = _next_boundary_id;
    checkpoint.pending_protocol.reserve(_pending_commands.size());
    for (const Command &command : _pending_commands) {
        if (command.request_id == 0) continue;
        checkpoint.pending_protocol.push_back(CountryPendingCommandProtocol{
            command.submit_order, command.request_id, command.producer_id,
            command.observed_generation});
    }
    checkpoint.request_states.reserve(_typed_request_state.size());
    for (const auto &entry : _typed_request_state)
        checkpoint.request_states.push_back(entry.second);
    std::sort(checkpoint.request_states.begin(), checkpoint.request_states.end(),
        [](const CountryCommandReceipt &lhs, const CountryCommandReceipt &rhs) {
            return lhs.request_id < rhs.request_id;
        });
    checkpoint.terminal_receipts.assign(_typed_receipts.begin(),
                                        _typed_receipts.end());
    std::vector<uint8_t> encoded;
    if (!encode_country_core_checkpoint(checkpoint, encoded, error)) return false;
    size_t cursor = encoded.size() - sizeof(uint64_t);
    checkpoint.checkpoint_hash = 0;
    for (uint32_t i = 0; i < sizeof(uint64_t); ++i)
        checkpoint.checkpoint_hash |=
            static_cast<uint64_t>(encoded[cursor + i]) << (i * 8u);
    out = std::move(checkpoint);
    return true;
}

bool NativeCountryRuntime::restore_core_checkpoint(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!validate_country_core_checkpoint(checkpoint, error)) return false;
    if (!_configured) {
        error = "country_checkpoint_runtime_unconfigured";
        return false;
    }
    if (checkpoint.catalog_hash != catalog_hash()) {
        error = "country_checkpoint_catalog_mismatch";
        return false;
    }

    NativeCountryRuntime staged(*this);
    std::unique_ptr<ModifierRuntime> staged_modifier;
    if (_modifier_runtime != nullptr) {
        staged_modifier = std::make_unique<ModifierRuntime>(*_modifier_runtime);
        staged_modifier->attach_country_runtime(&staged);
        staged_modifier->attach_economy_runtime(_economy_runtime);
        staged._modifier_runtime = staged_modifier.get();
    }
    if (!staged.restore_core_checkpoint_in_place(checkpoint, error))
        return false;

    ModifierRuntime *live_modifier = _modifier_runtime;
    NativeEconomyRuntime *live_economy = _economy_runtime;
    EffectRuntime *live_effect = _effect_runtime;
    *this = std::move(staged);
    _modifier_runtime = live_modifier;
    _economy_runtime = live_economy;
    _effect_runtime = live_effect;
    if (live_modifier != nullptr) {
        *live_modifier = std::move(*staged_modifier);
        live_modifier->attach_country_runtime(this);
        live_modifier->attach_economy_runtime(live_economy);
    }
    return true;
}

bool NativeCountryRuntime::restore_core_checkpoint_in_place(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!decode_save_in_place(checkpoint.canonical_pkcn, error)) return false;

    std::unordered_map<uint64_t, Command *> pending_by_order;
    pending_by_order.reserve(_pending_commands.size());
    for (Command &command : _pending_commands)
        pending_by_order.emplace(command.submit_order, &command);
    for (const CountryPendingCommandProtocol &metadata :
         checkpoint.pending_protocol) {
        const auto found = pending_by_order.find(metadata.submit_order);
        if (found == pending_by_order.end() || found->second->request_id != 0) {
            error = "country_checkpoint_pending_protocol_mismatch";
            return false;
        }
        found->second->request_id = metadata.request_id;
        found->second->producer_id = metadata.producer_id;
        found->second->observed_generation = metadata.observed_generation;
    }
    _typed_request_state.clear();
    for (const CountryCommandReceipt &receipt : checkpoint.request_states)
        _typed_request_state.emplace(receipt.request_id, receipt);
    _typed_receipts.assign(checkpoint.terminal_receipts.begin(),
                           checkpoint.terminal_receipts.end());
    _next_event_id = checkpoint.next_event_id;
    _next_boundary_id = checkpoint.next_boundary_id;
    close_boundary_seal();
    if (checkpoint.session_epoch == std::numeric_limits<uint64_t>::max()) {
        error = "country_checkpoint_session_epoch_exhausted";
        return false;
    }
    _session_epoch = std::max(_session_epoch, checkpoint.session_epoch + 1u);
    if (_generation != checkpoint.generation ||
        _last_committed_day != checkpoint.committed_day ||
        _submit_order != checkpoint.command_watermark ||
        compute_state_hash() != checkpoint.business_state_hash) {
        error = "country_checkpoint_business_state_mismatch";
        return false;
    }
    return true;
}

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
    _current_visual_era.clear();
    _visual_era_dirty_slots.clear();
    _visual_era_generation = 0;
    _territory_generation = 0;
    _research_generation = 0;
    _research_active_country_slots.clear();
    _research_active_country_scratch.clear();
    _research_active_country_membership.clear();
    _research_activated_pending_scratch.clear();
    _research_activated_technologies_scratch.clear();
    _research_modifier_cache.clear();
    _pending_activation_indices.clear();
    _pending_activation_index_dirty = true;
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _research_full_scan_fallbacks = 0;
    _research_discovery_frontier_mismatches = 0;
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
    _country_tax_default_modes.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _country_income_tax_mode_overrides.clear();
    _country_consumption_tax_mode_overrides.clear();
    _country_business_tax_mode_overrides.clear();
    _country_import_tax_mode_overrides.clear();
    _country_export_tax_mode_overrides.clear();
    _cell_tax_policy_ids.assign(static_cast<size_t>(std::max(0, _cell_count)), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _tax_policy_version = 0;
    _last_research_day = -1;
    _pending_commands.clear();
    _typed_receipts.clear();
    _typed_request_state.clear();
    clear_peer_protocol_state();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
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

int32_t NativeCountryRuntime::visual_era_index_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(slot)] == 0 ||
        _technology_words <= 0)
        return -1;
    int32_t era = -1;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t i = 0;
         i < static_cast<int32_t>(_technology_era_milestone_indices.size()); ++i) {
        const int32_t technology =
            _technology_era_milestone_indices[static_cast<size_t>(i)];
        if (technology < 0 ||
            technology >= static_cast<int32_t>(_technology_ids.size()))
            continue;
        const size_t word = base + static_cast<size_t>(technology / 64);
        if (word < _country_technologies.size() &&
            (_country_technologies[word] &
             (uint64_t{1} << (technology % 64))) != 0)
            era = i;
    }
    return era;
}

Dictionary NativeCountryRuntime::consume_visual_era_dirty_slots() {
    Dictionary out;
    std::sort(_visual_era_dirty_slots.begin(), _visual_era_dirty_slots.end());
    _visual_era_dirty_slots.erase(std::unique(_visual_era_dirty_slots.begin(),
                                              _visual_era_dirty_slots.end()),
                                  _visual_era_dirty_slots.end());
    PackedInt32Array slots;
    slots.resize(static_cast<int64_t>(_visual_era_dirty_slots.size()));
    for (int64_t i = 0; i < slots.size(); ++i)
        slots.set(i, _visual_era_dirty_slots[static_cast<size_t>(i)]);
    _visual_era_dirty_slots.clear();
    out["ok"] = _bootstrapped;
    out["country_era_generation"] =
        static_cast<int64_t>(_visual_era_generation);
    out["country_slots"] = slots;
    if (!_bootstrapped) out["reason"] = "country_not_bootstrapped";
    return out;
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
    PackedInt32Array default_modes;
    defaults.resize(TAX_KIND_COUNT);
    default_modes.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        const size_t index =
            static_cast<size_t>(slot) * TAX_KIND_COUNT + kind;
        defaults.set(kind, _country_tax_defaults[index]);
        default_modes.set(kind, _country_tax_default_modes[index]);
    }

    auto make_rates = [&](int32_t kind, const char *kind_key,
                          const std::vector<std::string> &item_ids,
                          const std::vector<int32_t> &values,
                          const std::vector<int32_t> &modes) {
        PackedInt32Array rates, effective_rates;
        PackedInt32Array rates_percent, effective_rates_percent;
        PackedInt32Array assessment_modes;
        PackedInt32Array absolute_amounts;
        PackedByteArray overrides;
        const int32_t count = tax_item_count(kind);
        rates.resize(count);
        effective_rates.resize(count);
        rates_percent.resize(count);
        effective_rates_percent.resize(count);
        assessment_modes.resize(count);
        absolute_amounts.resize(count);
        overrides.resize(count);
        for (int32_t item = 0; item < count; ++item) {
            const size_t index =
                static_cast<size_t>(slot) * count + item;
            const int32_t raw = values[index];
            const int32_t raw_mode = modes[index];
            const int32_t mode = raw_mode == TAX_MODE_INHERIT
                ? default_modes[kind] : raw_mode;
            const int32_t base_value = raw == TAX_RATE_INHERIT
                ? defaults[kind] : raw;
            rates.set(item, base_value);
            assessment_modes.set(item, mode);
            absolute_amounts.set(
                item, mode == TAX_MODE_ABSOLUTE ? base_value : 0);
            int32_t effective_value = base_value;
            if (mode == TAX_MODE_PERCENT_BP &&
                _modifier_runtime != nullptr &&
                item < static_cast<int32_t>(item_ids.size())) {
                const std::string stat_key = std::string("country.tax.") +
                    kind_key + "." + item_ids[item] + ".rate_bp";
                const int32_t stat_id =
                    _modifier_runtime->stat_id_for_key(stat_key);
                if (stat_id >= 0) {
                    effective_value = static_cast<int32_t>(std::clamp<int64_t>(
                        std::lround(_modifier_runtime->effective_value(
                            ModifierRuntime::COUNTRY, stat_id,
                            static_cast<uint64_t>(handle), 0, base_value)),
                        TAX_RATE_MIN_BP, TAX_RATE_MAX_BP));
                }
            }
            effective_rates.set(item, effective_value);
            rates_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP ? base_value / 100 : 0);
            effective_rates_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP ? effective_value / 100 : 0);
            overrides.set(item, raw == TAX_RATE_INHERIT &&
                                        raw_mode == TAX_MODE_INHERIT
                                    ? 0
                                    : 1);
        }
        Dictionary result;
        result["rates_basis_points"] = rates;
        result["effective_rates_basis_points"] = effective_rates;
        result["rates"] = rates_percent;
        result["effective_rates"] = effective_rates_percent;
        result["assessment_modes"] = assessment_modes;
        result["absolute_amounts"] = absolute_amounts;
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
    PackedInt32Array defaults_percent;
    defaults_percent.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        defaults_percent.set(
            kind,
            default_modes[kind] == TAX_MODE_PERCENT_BP
                ? defaults[kind] / 100
                : 0);
    }
    out["default_rates_basis_points"] = defaults;
    out["default_rates"] = defaults_percent;
    out["default_assessment_modes"] = default_modes;
    out["profession_ids"] = make_ids(_profession_ids);
    out["good_ids"] = make_ids(_good_ids);
    out["building_type_ids"] = make_ids(_building_type_ids);
    out["income"] = make_rates(TAX_INCOME, "income", _profession_ids,
                               _country_income_tax_overrides,
                               _country_income_tax_mode_overrides);
    out["consumption"] = make_rates(
        TAX_CONSUMPTION, "consumption", _good_ids,
        _country_consumption_tax_overrides,
        _country_consumption_tax_mode_overrides);
    out["transaction"] = out["consumption"];
    out["business"] = make_rates(
        TAX_BUSINESS, "business", _building_type_ids,
        _country_business_tax_overrides,
        _country_business_tax_mode_overrides);
    out["import"] = make_rates(TAX_IMPORT, "import", _good_ids,
                               _country_import_tax_overrides,
                               _country_import_tax_mode_overrides);
    out["export"] = make_rates(TAX_EXPORT, "export", _good_ids,
                               _country_export_tax_overrides,
                               _country_export_tax_mode_overrides);
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
    PackedInt32Array country_default_modes;
    PackedInt32Array local_defaults;
    PackedInt32Array local_default_modes;
    PackedByteArray has_local_default;
    country_defaults.resize(TAX_KIND_COUNT);
    country_default_modes.resize(TAX_KIND_COUNT);
    local_defaults.resize(TAX_KIND_COUNT);
    local_default_modes.resize(TAX_KIND_COUNT);
    has_local_default.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        const size_t index =
            static_cast<size_t>(slot) * TAX_KIND_COUNT + kind;
        country_defaults.set(kind, _country_tax_defaults[index]);
        country_default_modes.set(kind, _country_tax_default_modes[index]);
        const int32_t local = policy.defaults[static_cast<size_t>(kind)];
        const int32_t local_mode =
            policy.default_modes[static_cast<size_t>(kind)];
        local_defaults.set(kind, local == TAX_RATE_INHERIT ? 0 : local);
        local_default_modes.set(
            kind, local_mode == TAX_MODE_INHERIT ? 0 : local_mode);
        has_local_default.set(
            kind,
            local == TAX_RATE_INHERIT && local_mode == TAX_MODE_INHERIT
                ? 0
                : 1);
    }

    auto make_kind = [&](int32_t kind, const char *kind_key) {
        const auto &ids = tax_item_ids(kind);
        const std::vector<int32_t> *country_overrides =
            tax_override_vector(kind);
        const std::vector<int32_t> *country_mode_overrides =
            tax_mode_override_vector(kind);
        const int32_t count = static_cast<int32_t>(ids.size());
        PackedStringArray item_ids;
        PackedInt32Array country_base_rates;
        PackedInt32Array local_item_rates;
        PackedInt32Array final_base_rates;
        PackedInt32Array effective_rates;
        PackedInt32Array assessment_modes;
        PackedInt32Array absolute_amounts;
        PackedByteArray has_local_item;
        PackedStringArray source_scopes;
        item_ids.resize(count);
        country_base_rates.resize(count);
        local_item_rates.resize(count);
        final_base_rates.resize(count);
        effective_rates.resize(count);
        assessment_modes.resize(count);
        absolute_amounts.resize(count);
        has_local_item.resize(count);
        source_scopes.resize(count);
        size_t local_cursor = 0;
        while (local_cursor < policy.overrides.size() &&
               policy.overrides[local_cursor].kind < kind)
            ++local_cursor;
        for (int32_t item = 0; item < count; ++item) {
            item_ids.set(item, ids[static_cast<size_t>(item)].c_str());
            const size_t country_index =
                static_cast<size_t>(slot) * count + item;
            const int32_t country_raw = (*country_overrides)[country_index];
            const int32_t country_mode_raw =
                (*country_mode_overrides)[country_index];
            const int32_t country_base = country_raw == TAX_RATE_INHERIT
                ? country_defaults[kind] : country_raw;
            const int32_t country_mode =
                country_mode_raw == TAX_MODE_INHERIT
                    ? country_default_modes[kind]
                    : country_mode_raw;
            country_base_rates.set(item, country_base);
            while (local_cursor < policy.overrides.size() &&
                   policy.overrides[local_cursor].kind == kind &&
                   policy.overrides[local_cursor].item < item)
                ++local_cursor;
            const bool local_item =
                local_cursor < policy.overrides.size() &&
                policy.overrides[local_cursor].kind == kind &&
                policy.overrides[local_cursor].item == item;
            const int32_t local_default =
                policy.defaults[static_cast<size_t>(kind)];
            const int32_t local_default_mode =
                policy.default_modes[static_cast<size_t>(kind)];
            int32_t base_value = country_base;
            int32_t mode = country_mode;
            if (local_item) {
                base_value = policy.overrides[local_cursor].rate;
                mode = policy.overrides[local_cursor].mode == TAX_MODE_INHERIT
                    ? (local_default_mode != TAX_MODE_INHERIT
                           ? local_default_mode
                           : country_mode)
                    : policy.overrides[local_cursor].mode;
            } else if (local_default != TAX_RATE_INHERIT ||
                       local_default_mode != TAX_MODE_INHERIT) {
                if (local_default != TAX_RATE_INHERIT)
                    base_value = local_default;
                if (local_default_mode != TAX_MODE_INHERIT)
                    mode = local_default_mode;
            }
            local_item_rates.set(item, local_item
                ? policy.overrides[local_cursor].rate : 0);
            has_local_item.set(item, local_item ? 1 : 0);
            final_base_rates.set(item, base_value);
            assessment_modes.set(item, mode);
            absolute_amounts.set(
                item, mode == TAX_MODE_ABSOLUTE ? base_value : 0);
            const char *source = local_item ? "cell_item"
                : ((local_default != TAX_RATE_INHERIT ||
                    local_default_mode != TAX_MODE_INHERIT)
                    ? "cell_default"
                   : (country_raw != TAX_RATE_INHERIT ||
                      country_mode_raw != TAX_MODE_INHERIT
                      ? "country_item" : "country_default"));
            source_scopes.set(item, source);

            int32_t effective_value = base_value;
            if (mode == TAX_MODE_PERCENT_BP &&
                _modifier_runtime != nullptr) {
                const std::string stat_key = std::string("country.tax.") +
                    kind_key + "." + ids[static_cast<size_t>(item)] +
                    ".rate_bp";
                const int32_t stat_id =
                    _modifier_runtime->stat_id_for_key(stat_key);
                if (stat_id >= 0) {
                    effective_value = static_cast<int32_t>(
                        std::clamp<int64_t>(std::lround(
                            _modifier_runtime->effective_value(
                                ModifierRuntime::COUNTRY, stat_id, handle,
                                0, base_value)), TAX_RATE_MIN_BP,
                            TAX_RATE_MAX_BP));
                }
            }
            effective_rates.set(item, effective_value);
        }
        Dictionary result;
        PackedInt32Array country_base_percent, local_item_percent;
        PackedInt32Array final_base_percent, effective_percent;
        country_base_percent.resize(count);
        local_item_percent.resize(count);
        final_base_percent.resize(count);
        effective_percent.resize(count);
        for (int32_t item = 0; item < count; ++item) {
            const int32_t mode = assessment_modes[item];
            country_base_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? country_base_rates[item] / 100
                    : 0);
            local_item_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? local_item_rates[item] / 100
                    : 0);
            final_base_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? final_base_rates[item] / 100
                    : 0);
            effective_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? effective_rates[item] / 100
                    : 0);
        }
        result["item_ids"] = item_ids;
        result["country_base_rates_basis_points"] = country_base_rates;
        result["local_item_rates_basis_points"] = local_item_rates;
        result["final_base_rates_basis_points"] = final_base_rates;
        result["effective_rates_basis_points"] = effective_rates;
        result["assessment_modes"] = assessment_modes;
        result["absolute_amounts"] = absolute_amounts;
        result["country_base_rates"] = country_base_percent;
        result["local_item_rates"] = local_item_percent;
        result["has_local_item"] = has_local_item;
        result["final_base_rates"] = final_base_percent;
        result["effective_rates"] = effective_percent;
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
    PackedInt32Array country_defaults_percent, local_defaults_percent;
    country_defaults_percent.resize(TAX_KIND_COUNT);
    local_defaults_percent.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        country_defaults_percent.set(
            kind,
            country_default_modes[kind] == TAX_MODE_PERCENT_BP
                ? country_defaults[kind] / 100
                : 0);
        local_defaults_percent.set(
            kind,
            local_default_modes[kind] == TAX_MODE_PERCENT_BP
                ? local_defaults[kind] / 100
                : 0);
    }
    out["country_default_rates_basis_points"] = country_defaults;
    out["local_default_rates_basis_points"] = local_defaults;
    out["country_default_assessment_modes"] = country_default_modes;
    out["local_default_assessment_modes"] = local_default_modes;
    out["country_default_rates"] = country_defaults_percent;
    out["local_default_rates"] = local_defaults_percent;
    out["has_local_default"] = has_local_default;
    out["income"] = make_kind(TAX_INCOME, "income");
    out["consumption"] = make_kind(TAX_CONSUMPTION, "consumption");
    out["transaction"] = out["consumption"];
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

uint64_t NativeCountryRuntime::begin_economy_asset_transaction(
        EconomyAssetTransaction &transaction, uint64_t request_id,
        uint32_t origin_domain, int64_t origin_epoch, int32_t origin_stage) {
    if (_sync_store_writes_forbidden) {
        transaction.transaction_id = 0;
        transaction.status = ECONOMY_ASSET_REJECTED;
        transaction.rejection_reason = "country_worker_unique_writer";
        return 0;
    }
    transaction.transaction_id = _next_economy_asset_transaction_id++;
    if (transaction.transaction_id == 0)
        transaction.transaction_id = _next_economy_asset_transaction_id++;
    transaction.session_epoch = _session_epoch;
    transaction.origin_domain = origin_domain;
    transaction.origin_epoch = origin_epoch;
    transaction.origin_stage = origin_stage;
    transaction.operation_sequence = ++_economy_asset_operation_sequence;
    transaction.request_id = request_id != 0 ? request_id : transaction.transaction_id;
    transaction.status = ECONOMY_ASSET_CREATED;
    _economy_asset_request_index[transaction.request_id] =
        transaction.transaction_id;
    ++_economy_asset_transactions_created;
    return transaction.transaction_id;
}

void NativeCountryRuntime::finish_economy_asset_transaction(
        EconomyAssetTransaction &transaction, bool completed,
        const char *rejection_reason, bool conservation_failure) {
    if (completed) {
        transaction.status = ECONOMY_ASSET_COMPLETED;
        ++_economy_asset_transactions_completed;
        ++_economy_asset_complete_count;
    } else {
        transaction.status = ECONOMY_ASSET_REJECTED;
        transaction.conservation_ok = !conservation_failure;
        transaction.rejection_reason = rejection_reason == nullptr
            ? "country_economy_asset_transaction_rejected" : rejection_reason;
        ++_economy_asset_transactions_rejected;
        if (conservation_failure)
            ++_economy_asset_ledger_failures;
    }
    _economy_asset_request_index[transaction.request_id] =
        transaction.transaction_id;
    _economy_asset_transactions_in_flight.erase(transaction.transaction_id);
    _economy_asset_transaction_history.push_back(transaction);
    while (_economy_asset_transaction_history.size() > 4096)
        _economy_asset_transaction_history.pop_front();
    if (_simulation_host != nullptr && !_sync_store_writes_forbidden &&
        _simulation_host->country_pod_configured()) {
        RuntimeEconomyAssetRequest request;
        RuntimeEconomyAssetResult result;
        request.operation = static_cast<RuntimeEconomyAssetOperation>(
            transaction.operation);
        request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
        request.all_or_nothing = transaction.all_or_nothing ? 1 : 0;
        request.session_epoch = transaction.session_epoch;
        request.transaction_id = transaction.transaction_id;
        request.request_id = transaction.request_id;
        request.origin_domain = transaction.origin_domain;
        request.origin_epoch = transaction.origin_epoch;
        request.origin_stage = transaction.origin_stage;
        request.operation_sequence = transaction.operation_sequence;
        request.country_generation = transaction.country_generation_before;
        request.peer_generation = transaction.peer_generation;
        request.country_handle = transaction.country_handle;
        request.country_slot = transaction.country_slot;
        request.good_id = transaction.good_id;
        request.good_count = static_cast<uint32_t>(std::min<size_t>(
            transaction.good_ids.size(), RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY));
        for (uint32_t i = 0; i < request.good_count; ++i) {
            request.good_ids[i] = transaction.good_ids[i];
            request.good_quantities[i] = i < transaction.good_quantities.size()
                ? transaction.good_quantities[i] : 0;
        }
        request.requested_quantity = transaction.requested_quantity;
        request.prepared_quantity = transaction.prepared_quantity;
        request.requested_cash = transaction.requested_cash;
        request.reserved_cash = transaction.reserved_cash;
        request.requested_goods_total = transaction.requested_goods_total;
        request.reserved_goods_total = transaction.reserved_goods_total;
        const bool ok = transaction.status == ECONOMY_ASSET_COMPLETED;
        result.code = ok ? RuntimeEconomyAssetResultCode::COMPLETED
                         : RuntimeEconomyAssetResultCode::REJECTED;
        result.state = ok ? RuntimeEconomyAssetState::COMPLETED
                          : RuntimeEconomyAssetState::REJECTED;
        result.accepted = ok ? 1 : 0;
        result.session_epoch = transaction.session_epoch;
        result.transaction_id = transaction.transaction_id;
        result.request_id = transaction.request_id;
        result.operation = request.operation;
        result.country_generation = transaction.country_generation_before;
        result.peer_generation = transaction.peer_generation;
        result.committed_peer_generation = transaction.peer_generation;
        result.country_slot = transaction.country_slot;
        result.committed_quantity = transaction.committed_quantity;
        result.committed_cash = transaction.committed_cash;
        result.committed_goods_total = transaction.committed_goods_total;
        const char *reason_src = transaction.rejection_reason.c_str();
        size_t reason_i = 0;
        if (reason_src != nullptr) {
            for (; reason_i + 1u < result.reason.size() && reason_src[reason_i] != '\0';
                 ++reason_i)
                result.reason[reason_i] = reason_src[reason_i];
        }
        result.reason[reason_i] = '\0';
        std::string mirror_error;
        _simulation_host->mirror_sync_country_economy_asset(
            request, result, mirror_error);
    }
}

bool NativeCountryRuntime::find_economy_asset_transaction(
        uint64_t request_id, EconomyAssetTransaction &out) const {
    if (request_id == 0) return false;
    const auto indexed = _economy_asset_request_index.find(request_id);
    if (indexed == _economy_asset_request_index.end()) return false;
    const auto pending = _economy_asset_transactions_in_flight.find(
        indexed->second);
    if (pending != _economy_asset_transactions_in_flight.end()) {
        out = pending->second;
        return true;
    }
    for (auto it = _economy_asset_transaction_history.rbegin();
         it != _economy_asset_transaction_history.rend(); ++it) {
        if (it->transaction_id == indexed->second) {
            out = *it;
            return true;
        }
    }
    return false;
}

namespace {

Dictionary economy_asset_transaction_dictionary(
        const NativeCountryRuntime::EconomyAssetTransaction &transaction) {
    Dictionary out;
    out["ok"] = true;
    out["transaction_id"] = static_cast<int64_t>(transaction.transaction_id);
    out["request_id"] = static_cast<int64_t>(transaction.request_id);
    out["session_epoch"] = static_cast<int64_t>(transaction.session_epoch);
    out["origin_domain"] = static_cast<int64_t>(transaction.origin_domain);
    out["origin_epoch"] = transaction.origin_epoch;
    out["origin_stage"] = transaction.origin_stage;
    out["operation_sequence"] = static_cast<int64_t>(
        transaction.operation_sequence);
    out["operation"] = static_cast<int64_t>(transaction.operation);
    out["status"] = static_cast<int64_t>(transaction.status);
    out["status_name"] = economy_asset_status_name(transaction.status);
    out["country_handle"] = static_cast<int64_t>(transaction.country_handle);
    out["country_slot"] = transaction.country_slot;
    out["country_generation"] = static_cast<int64_t>(
        transaction.country_generation_before);
    out["peer_generation"] = static_cast<int64_t>(transaction.peer_generation);
    out["requested_cash"] = transaction.requested_cash;
    out["reserved_cash"] = transaction.reserved_cash;
    out["committed_cash"] = transaction.committed_cash;
    out["requested_quantity"] = transaction.requested_quantity;
    out["prepared_quantity"] = transaction.prepared_quantity;
    out["committed_quantity"] = transaction.committed_quantity;
    out["requested_goods_total"] = transaction.requested_goods_total;
    out["reserved_goods_total"] = transaction.reserved_goods_total;
    out["committed_goods_total"] = transaction.committed_goods_total;
    out["country_cash_before"] = transaction.country_cash_before;
    out["country_cash_after"] = transaction.country_cash_after;
    out["country_good_before"] = transaction.country_good_before;
    out["country_good_after"] = transaction.country_good_after;
    out["all_or_nothing"] = transaction.all_or_nothing;
    out["conservation_ok"] = transaction.conservation_ok;
    out["rejection_reason"] = String::utf8(
        transaction.rejection_reason.c_str());
    PackedInt32Array ids;
    PackedInt64Array quantities;
    PackedInt64Array before_goods;
    PackedInt64Array after_goods;
    ids.resize(static_cast<int64_t>(transaction.good_ids.size()));
    quantities.resize(static_cast<int64_t>(transaction.good_quantities.size()));
    before_goods.resize(ids.size());
    after_goods.resize(ids.size());
    for (int64_t i = 0; i < ids.size(); ++i) {
        ids.set(i, transaction.good_ids[static_cast<size_t>(i)]);
        quantities.set(i, transaction.good_quantities[static_cast<size_t>(i)]);
        before_goods.set(i, i < static_cast<int64_t>(
            transaction.country_goods_before.size())
            ? transaction.country_goods_before[static_cast<size_t>(i)] : 0);
        after_goods.set(i, i < static_cast<int64_t>(
            transaction.country_goods_after.size())
            ? transaction.country_goods_after[static_cast<size_t>(i)] : 0);
    }
    out["good_ids"] = ids;
    out["good_quantities"] = quantities;
    out["country_goods_before"] = before_goods;
    out["country_goods_after"] = after_goods;
    return out;
}

Dictionary economy_asset_failure(const char *code) {
    Dictionary out;
    out["ok"] = false;
    out["code"] = code;
    return out;
}

} // namespace

Dictionary NativeCountryRuntime::begin_economy_treasury_spend(
        int64_t country_handle, const PackedInt32Array &good_ids,
        const PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_TREASURY_SPEND;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_cash = cash;
    transaction.requested_goods_total = 0;
    transaction.all_or_nothing = true;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }

    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (cash < 0 || good_ids.size() != quantities.size() ||
        good_ids.size() > 4096 ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_treasury_async_target_invalid");

    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    transaction.good_ids.reserve(static_cast<size_t>(good_ids.size()));
    transaction.good_quantities.reserve(static_cast<size_t>(quantities.size()));
    const size_t base = static_cast<size_t>(slot) * _good_ids.size();
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available_cash < cash)
        return reject("country_treasury_async_cash_insufficient");
    for (int64_t i = 0; i < good_ids.size(); ++i) {
        const int32_t good_id = good_ids[i];
        const int64_t quantity = quantities[i];
        if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
            quantity < 0)
            return reject("country_treasury_async_good_invalid");
        for (const int32_t prior : transaction.good_ids)
            if (prior == good_id)
                return reject("country_treasury_async_duplicate_good");
        if (transaction.requested_goods_total >
                std::numeric_limits<int64_t>::max() - quantity)
            return reject("country_treasury_async_quantity_overflow");
        const size_t index = base + static_cast<size_t>(good_id);
        const int64_t available = _country_goods[index] -
            _economy_asset_reserved_goods[index];
        if (available < quantity)
            return reject("country_treasury_async_goods_insufficient");
        transaction.good_ids.push_back(good_id);
        transaction.good_quantities.push_back(quantity);
        transaction.requested_goods_total += quantity;
        transaction.reserved_goods_total += quantity;
        if (i == 0) transaction.good_id = good_id;
    }
    transaction.reserved_cash = cash;
    transaction.prepared_quantity = transaction.requested_goods_total;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] += cash;
    for (size_t i = 0; i < transaction.good_ids.size(); ++i)
        _economy_asset_reserved_goods[base + static_cast<size_t>(
            transaction.good_ids[i])] += transaction.good_quantities[i];
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::acknowledge_economy_asset_peer_prepared(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const String &reason) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end()) {
        EconomyAssetTransaction terminal;
        for (auto history = _economy_asset_transaction_history.rbegin();
             history != _economy_asset_transaction_history.rend(); ++history) {
            if (history->transaction_id == transaction_id) {
                terminal = *history;
                Dictionary out = economy_asset_transaction_dictionary(terminal);
                out["replayed"] = true;
                return out;
            }
        }
        return economy_asset_failure("country_treasury_async_transaction_unknown");
    }
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status == ECONOMY_ASSET_PEER_PREPARED && accepted) {
        if (session_epoch != transaction.session_epoch ||
            country_generation != transaction.country_generation_before ||
            peer_generation != transaction.peer_generation)
            return economy_asset_failure(
                "country_treasury_async_prepare_duplicate_mismatch");
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["replayed"] = true;
        return out;
    }
    if (transaction.status != ECONOMY_ASSET_AWAITING_PEER_PREPARED)
        return economy_asset_failure("country_treasury_async_prepare_state_invalid");
    if (session_epoch != transaction.session_epoch ||
        country_generation != transaction.country_generation_before ||
        peer_generation == 0)
        return economy_asset_failure("country_treasury_async_prepare_identity_mismatch");
    auto release_reservation = [&]() {
        if (transaction.country_slot < 0) return;
        const size_t slot = static_cast<size_t>(transaction.country_slot);
        _economy_asset_reserved_cash[slot] -= transaction.reserved_cash;
        const size_t base = slot * _good_ids.size();
        for (size_t i = 0; i < transaction.good_ids.size(); ++i)
            _economy_asset_reserved_goods[base + static_cast<size_t>(
                transaction.good_ids[i])] -= transaction.good_quantities[i];
        if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE &&
            slot < _economy_asset_reserved_research_points.size())
            _economy_asset_reserved_research_points[slot] -=
                transaction.prepared_quantity;
        transaction.reserved_cash = 0;
        transaction.reserved_goods_total = 0;
    };
    if (!accepted) {
        release_reservation();
        transaction.rejection_reason = reason.is_empty()
            ? "country_treasury_async_peer_prepare_rejected"
            : reason.utf8().get_data();
        finish_economy_asset_transaction(transaction, false,
            transaction.rejection_reason.c_str());
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.peer_generation = peer_generation;
    transaction.status = ECONOMY_ASSET_PEER_PREPARED;
    Dictionary out = economy_asset_transaction_dictionary(transaction);
    out["ok"] = true;
    return out;
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_FISCAL_RESERVE;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = requested;
    transaction.requested_cash = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_fiscal_async_reserve_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available <= 0)
        return reject("country_fiscal_async_reserve_cash_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.reserved_cash = transaction.prepared_quantity;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] +=
        transaction.reserved_cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_cash_credit(
        EconomyAssetOperation operation, int64_t country_handle, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        const char *invalid_reason) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = operation;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = offered;
    transaction.requested_cash = offered;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject(invalid_reason);
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    transaction.prepared_quantity = std::min(
        offered, std::numeric_limits<int64_t>::max() -
            transaction.country_cash_before);
    if (transaction.prepared_quantity <= 0)
        return reject("country_fiscal_async_credit_capacity_exhausted");
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_FISCAL_RETURN, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_fiscal_async_return_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_FISCAL_COLLECT, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_fiscal_async_collect_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_CASH_TO_COHORT;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = requested;
    transaction.requested_cash = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_cash_to_cohort_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available <= 0)
        return reject("country_cash_to_cohort_async_cash_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.reserved_cash = transaction.prepared_quantity;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] +=
        transaction.reserved_cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_CASH_FROM_COHORT, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_cash_from_cohort_async_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_GOOD_TO_MARKET;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.good_id = good_id;
    transaction.requested_quantity = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_good_to_market_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const size_t index = static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(good_id);
    transaction.country_good_before = _country_goods[index];
    const int64_t available = transaction.country_good_before -
        _economy_asset_reserved_goods[index];
    if (available <= 0)
        return reject("country_good_to_market_async_goods_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.good_ids.push_back(good_id);
    transaction.good_quantities.push_back(transaction.prepared_quantity);
    transaction.requested_goods_total = requested;
    transaction.reserved_goods_total = transaction.prepared_quantity;
    _economy_asset_reserved_goods[index] += transaction.prepared_quantity;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_GOOD_FROM_MARKET;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.good_id = good_id;
    transaction.requested_quantity = offered;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (offered <= 0 || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_good_from_market_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const size_t index = static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(good_id);
    transaction.country_good_before = _country_goods[index];
    transaction.prepared_quantity = std::min(
        offered, std::numeric_limits<int64_t>::max() -
            transaction.country_good_before);
    if (transaction.prepared_quantity <= 0)
        return reject("country_good_from_market_async_capacity_exhausted");
    transaction.good_ids.push_back(good_id);
    transaction.good_quantities.push_back(transaction.prepared_quantity);
    transaction.requested_goods_total = offered;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_RESEARCH_PURCHASE;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = quantity;
    transaction.requested_cash = total_cost;
    transaction.requested_goods_total = quantity;
    transaction.all_or_nothing = true;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }

    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    int32_t slot = -1;
    if (quantity <= 0 || total_cost < 0 ||
        _technology_points_good_id < 0 ||
        _technology_points_good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_research_purchase_async_target_invalid");

    transaction.country_slot = slot;
    transaction.good_id = _technology_points_good_id;
    transaction.country_generation_before = _generation;
    const size_t country_slot = static_cast<size_t>(slot);
    const size_t good_index = country_slot * _good_ids.size() +
        static_cast<size_t>(_technology_points_good_id);
    transaction.country_cash_before = _countries.cash[country_slot];
    transaction.country_good_before = _country_goods[good_index];
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[country_slot];
    const int64_t reserved_points =
        _economy_asset_reserved_research_points[country_slot];
    const int64_t points_capacity = std::numeric_limits<int64_t>::max() -
        transaction.country_good_before;
    const int64_t purchased_capacity = std::numeric_limits<int64_t>::max() -
        _country_research_purchased_total[country_slot];
    if (available_cash < total_cost || reserved_points > points_capacity ||
        quantity > points_capacity - reserved_points ||
        quantity > purchased_capacity)
        return reject("country_research_purchase_async_resources_insufficient");

    transaction.good_ids.push_back(_technology_points_good_id);
    transaction.good_quantities.push_back(quantity);
    transaction.prepared_quantity = quantity;
    transaction.reserved_cash = total_cost;
    _economy_asset_reserved_cash[country_slot] += total_cost;
    _economy_asset_reserved_research_points[country_slot] += quantity;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::commit_economy_asset_transaction(
        uint64_t transaction_id) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end())
        return economy_asset_transaction_snapshot(transaction_id);
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status == ECONOMY_ASSET_AWAITING_PEER_APPLIED ||
        transaction.status == ECONOMY_ASSET_COUNTRY_APPLIED ||
        transaction.status == ECONOMY_ASSET_PEER_APPLIED) {
        return economy_asset_transaction_dictionary(transaction);
    }
    if (transaction.status != ECONOMY_ASSET_PEER_PREPARED)
        return economy_asset_failure("country_treasury_async_commit_state_invalid");
    if (transaction.operation != ECONOMY_ASSET_TREASURY_SPEND &&
        transaction.operation != ECONOMY_ASSET_FISCAL_RESERVE &&
        transaction.operation != ECONOMY_ASSET_FISCAL_RETURN &&
        transaction.operation != ECONOMY_ASSET_FISCAL_COLLECT &&
        transaction.operation != ECONOMY_ASSET_CASH_TO_COHORT &&
        transaction.operation != ECONOMY_ASSET_CASH_FROM_COHORT &&
        transaction.operation != ECONOMY_ASSET_GOOD_TO_MARKET &&
        transaction.operation != ECONOMY_ASSET_GOOD_FROM_MARKET &&
        transaction.operation != ECONOMY_ASSET_RESEARCH_PURCHASE)
        return economy_asset_failure("country_economy_async_commit_operation_invalid");
    const size_t slot = static_cast<size_t>(transaction.country_slot);
    const size_t base = slot * _good_ids.size();
    const bool credits_country = transaction.operation == ECONOMY_ASSET_FISCAL_RETURN ||
        transaction.operation == ECONOMY_ASSET_FISCAL_COLLECT ||
        transaction.operation == ECONOMY_ASSET_CASH_FROM_COHORT;
    const bool credits_goods = transaction.operation == ECONOMY_ASSET_GOOD_FROM_MARKET ||
        transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE;
    const bool moves_goods = transaction.operation == ECONOMY_ASSET_GOOD_TO_MARKET ||
        transaction.operation == ECONOMY_ASSET_GOOD_FROM_MARKET;
    const int64_t commit_cash = transaction.operation == ECONOMY_ASSET_FISCAL_RESERVE ||
        credits_country ? transaction.prepared_quantity : transaction.requested_cash;
    if ((!credits_country && _countries.cash[slot] < commit_cash) ||
        (credits_country && _countries.cash[slot] >
            std::numeric_limits<int64_t>::max() - commit_cash))
        return economy_asset_failure("country_treasury_async_commit_cash_invalid");
    for (size_t i = 0; i < transaction.good_ids.size(); ++i) {
        const size_t index = base + static_cast<size_t>(transaction.good_ids[i]);
        if ((!credits_goods && _country_goods[index] < transaction.good_quantities[i]) ||
            (credits_goods && _country_goods[index] >
                std::numeric_limits<int64_t>::max() - transaction.good_quantities[i]))
            return economy_asset_failure("country_treasury_async_commit_goods_invalid");
    }
    transaction.status = ECONOMY_ASSET_COMMIT_DECIDED;
    ++_economy_asset_commit_count;
    if (credits_country)
        _countries.cash[slot] += commit_cash;
    else
        _countries.cash[slot] -= commit_cash;
    for (size_t i = 0; i < transaction.good_ids.size(); ++i) {
        int64_t &stock = _country_goods[base + static_cast<size_t>(transaction.good_ids[i])];
        if (credits_goods) stock += transaction.good_quantities[i];
        else stock -= transaction.good_quantities[i];
    }
    if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE)
        _country_research_purchased_total[slot] += transaction.prepared_quantity;
    _economy_asset_reserved_cash[slot] -= transaction.reserved_cash;
    if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE &&
        slot < _economy_asset_reserved_research_points.size())
        _economy_asset_reserved_research_points[slot] -=
            transaction.prepared_quantity;
    if (!credits_goods) {
        for (size_t i = 0; i < transaction.good_ids.size(); ++i)
            _economy_asset_reserved_goods[base + static_cast<size_t>(
                transaction.good_ids[i])] -= transaction.good_quantities[i];
    }
    transaction.reserved_cash = 0;
    transaction.reserved_goods_total = 0;
    transaction.committed_cash = commit_cash;
    transaction.committed_quantity = moves_goods
        ? transaction.prepared_quantity
        : (transaction.operation == ECONOMY_ASSET_FISCAL_RESERVE ||
            transaction.operation == ECONOMY_ASSET_CASH_TO_COHORT ||
            credits_country
            ? commit_cash : transaction.requested_goods_total);
    transaction.committed_goods_total = moves_goods
        ? transaction.prepared_quantity : transaction.requested_goods_total;
    transaction.country_cash_after = _countries.cash[slot];
    transaction.country_goods_before.clear();
    transaction.country_goods_after.clear();
    transaction.country_goods_before.reserve(transaction.good_ids.size());
    transaction.country_goods_after.reserve(transaction.good_ids.size());
    for (size_t i = 0; i < transaction.good_ids.size(); ++i) {
        const int64_t after = _country_goods[base + static_cast<size_t>(
            transaction.good_ids[i])];
        transaction.country_goods_after.push_back(after);
        transaction.country_goods_before.push_back(credits_goods
            ? after - transaction.good_quantities[i]
            : after + transaction.good_quantities[i]);
    }
    transaction.country_good_before = transaction.country_goods_before.empty() ? 0
        : transaction.country_goods_before[0];
    transaction.country_good_after = transaction.country_goods_after.empty() ? 0
        : transaction.country_goods_after[0];
    ++_countries.state_version[slot];
    ++_generation;
    _state_hash_cache_valid = false;
    record_direct_reference_frame(
        transaction.operation == ECONOMY_ASSET_TREASURY_SPEND
            ? "treasury_spend_async"
            : (transaction.operation == ECONOMY_ASSET_FISCAL_RESERVE
                ? "fiscal_reserve_async"
                : (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE
                    ? "research_procurement_async"
                    : (moves_goods ? "market_goods_async" : "fiscal_credit_async"))));
    transaction.status = ECONOMY_ASSET_COUNTRY_APPLIED;
    bool goods_conserved = transaction.country_goods_before.size() ==
        transaction.good_quantities.size() &&
        transaction.country_goods_after.size() == transaction.good_quantities.size();
    for (size_t i = 0; goods_conserved && i < transaction.good_quantities.size(); ++i)
        goods_conserved = credits_goods
            ? transaction.country_goods_after[i] - transaction.country_goods_before[i] ==
                transaction.good_quantities[i]
            : transaction.country_goods_before[i] - transaction.country_goods_after[i] ==
                transaction.good_quantities[i];
    const bool cash_conserved = credits_country
        ? transaction.country_cash_after - transaction.country_cash_before ==
            transaction.committed_cash
        : transaction.country_cash_before - transaction.country_cash_after ==
            transaction.committed_cash;
    if (!cash_conserved || !goods_conserved) {
        transaction.conservation_ok = false;
        transaction.status = ECONOMY_ASSET_FAULTED;
        transaction.rejection_reason = transaction.operation ==
                ECONOMY_ASSET_RESEARCH_PURCHASE
            ? "research_purchase_async_conservation_failure"
            : "country_treasury_async_conservation_failure";
        ++_economy_asset_ledger_failures;
        _economy_asset_request_index[transaction.request_id] = transaction_id;
        _economy_asset_transaction_history.push_back(transaction);
        _economy_asset_transactions_in_flight.erase(transaction_id);
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_APPLIED;
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::commit_economy_treasury_spend(
        uint64_t transaction_id) {
    return commit_economy_asset_transaction(transaction_id);
}

Dictionary NativeCountryRuntime::acknowledge_economy_asset_peer_applied(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const String &reason) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end()) {
        Dictionary out = economy_asset_transaction_snapshot(transaction_id);
        if (static_cast<bool>(out.get("ok", false))) out["replayed"] = true;
        return out;
    }
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status != ECONOMY_ASSET_AWAITING_PEER_APPLIED)
        return economy_asset_failure("country_treasury_async_apply_state_invalid");
    if (session_epoch != transaction.session_epoch ||
        country_generation != transaction.country_generation_before ||
        peer_generation != transaction.peer_generation)
        return economy_asset_failure("country_treasury_async_apply_identity_mismatch");
    if (!accepted) {
        transaction.status = ECONOMY_ASSET_FAULTED;
        transaction.conservation_ok = false;
        transaction.rejection_reason = reason.is_empty()
            ? "country_treasury_async_peer_apply_rejected"
            : reason.utf8().get_data();
        ++_economy_asset_ledger_failures;
        _economy_asset_request_index[transaction.request_id] = transaction_id;
        _economy_asset_transaction_history.push_back(transaction);
        _economy_asset_transactions_in_flight.erase(transaction_id);
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.status = ECONOMY_ASSET_PEER_APPLIED;
    finish_economy_asset_transaction(transaction, true);
    return economy_asset_transaction_snapshot(transaction_id);
}

Dictionary NativeCountryRuntime::economy_asset_transaction_snapshot(
        uint64_t transaction_id) const {
    const auto pending = _economy_asset_transactions_in_flight.find(transaction_id);
    if (pending != _economy_asset_transactions_in_flight.end())
        return economy_asset_transaction_dictionary(pending->second);
    for (auto it = _economy_asset_transaction_history.rbegin();
         it != _economy_asset_transaction_history.rend(); ++it)
        if (it->transaction_id == transaction_id)
            return economy_asset_transaction_dictionary(*it);
    return economy_asset_failure("country_treasury_async_transaction_unknown");
}

int64_t NativeCountryRuntime::complete_economy_asset_compatibility(
        const Dictionary &begin) {
    if (!static_cast<bool>(begin.get("ok", false))) return 0;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed"
            ? static_cast<int64_t>(begin.get("committed_quantity", 0)) : 0;
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    if (transaction_id == 0 || session_epoch == 0 || country_generation == 0)
        return 0;
    // Legacy Economy callers remain synchronous until the real peer
    // coordinator is connected. They still traverse the typed protocol.
    const uint64_t peer_generation = transaction_id;
    const Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return 0;
    const Dictionary committed = commit_economy_asset_transaction(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return 0;
    const Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
            String(applied.get("status_name", "")) == "completed"
        ? static_cast<int64_t>(applied.get("committed_quantity", 0)) : 0;
}

int64_t NativeCountryRuntime::economy_reserve_fiscal_cash(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_reserve(
        country_handle, requested, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_return_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_return(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_collect_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_collect(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

bool NativeCountryRuntime::economy_purchase_research_points(
        int32_t country_slot, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (country_slot < 0 ||
        country_slot >= static_cast<int32_t>(_countries.active.size()))
        return false;
    const uint64_t handle = make_handle(country_slot);
    // The legacy production caller is still synchronous, but it now traverses
    // the same typed transaction state machine.  The synthetic peer ACKs are a
    // compatibility adapter until NativeEconomyRuntime owns the real market
    // prepare/apply coordinator; they must not be used as ACTIVE authority.
    Dictionary begin = begin_economy_research_purchase(
        static_cast<int64_t>(handle), quantity, total_cost, origin_epoch,
        origin_stage, request_id);
    if (!static_cast<bool>(begin.get("ok", false))) return false;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed";
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    const uint64_t peer_generation = transaction_id;
    Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return false;
    Dictionary committed = commit_economy_asset_transaction(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return false;
    Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
}

Dictionary NativeCountryRuntime::economy_asset_transaction_report() const {
    Dictionary out;
    out["created"] = static_cast<int64_t>(_economy_asset_transactions_created);
    out["completed"] = static_cast<int64_t>(_economy_asset_transactions_completed);
    out["rejected"] = static_cast<int64_t>(_economy_asset_transactions_rejected);
    out["prepared"] = static_cast<int64_t>(_economy_asset_prepare_count);
    out["commit_decisions"] = static_cast<int64_t>(_economy_asset_commit_count);
    out["complete"] = static_cast<int64_t>(_economy_asset_complete_count);
    out["ledger_failures"] = _economy_asset_ledger_failures;
    out["next_transaction_id"] = static_cast<int64_t>(_next_economy_asset_transaction_id);
    out["operation_sequence"] = static_cast<int64_t>(_economy_asset_operation_sequence);
    out["history_size"] = static_cast<int64_t>(_economy_asset_transaction_history.size());
    out["in_flight"] = static_cast<int64_t>(
        _economy_asset_transactions_in_flight.size());
    int64_t reserved_cash = 0;
    int64_t reserved_goods = 0;
    int64_t reserved_research_points = 0;
    for (const int64_t value : _economy_asset_reserved_cash)
        if (value > 0 && reserved_cash <=
                std::numeric_limits<int64_t>::max() - value)
            reserved_cash += value;
    for (const int64_t value : _economy_asset_reserved_goods)
        if (value > 0 && reserved_goods <=
                std::numeric_limits<int64_t>::max() - value)
            reserved_goods += value;
    for (const int64_t value : _economy_asset_reserved_research_points)
        if (value > 0 && reserved_research_points <=
                std::numeric_limits<int64_t>::max() - value)
            reserved_research_points += value;
    out["reserved_cash"] = reserved_cash;
    out["reserved_goods"] = reserved_goods;
    out["reserved_research_points"] = reserved_research_points;
    out["faulted"] = static_cast<int64_t>(std::count_if(
        _economy_asset_transaction_history.begin(),
        _economy_asset_transaction_history.end(), [](const auto &transaction) {
            return transaction.status == ECONOMY_ASSET_FAULTED;
        }));
    return out;
}

bool NativeCountryRuntime::purchase_research_points(int32_t country_slot,
                                                     int64_t quantity,
                                                     int64_t total_cost) {
    return economy_purchase_research_points(country_slot, quantity, total_cost,
        -1, -1);
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
    ++_research_discovery_checks;
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
        int32_t slot, int32_t technology,
        const CountryPeerContext *peer_context) const {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_costs.size()))
        return 1;
    ensure_research_modifier_cache(slot, peer_context);
    const double cost_factor = slot >= 0 &&
        slot < static_cast<int32_t>(_research_modifier_cache.size())
        ? _research_modifier_cache[static_cast<size_t>(slot)].cost_factor : 1.0;
    return country_effective_research_cost(
        _technology_costs[static_cast<size_t>(technology)], cost_factor);
}

void NativeCountryRuntime::ensure_research_modifier_cache(
        int32_t slot, const CountryPeerContext *peer_context) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return;
    if (_research_modifier_cache.size() < _countries.active.size())
        _research_modifier_cache.resize(_countries.active.size());
    ResearchModifierCache &cache =
        _research_modifier_cache[static_cast<size_t>(slot)];
    const uint64_t handle = make_handle(slot);
    const uint64_t version = peer_context != nullptr
        ? peer_context->modifier_generation
        : (_modifier_runtime != nullptr && _modifier_runtime->configured()
            ? _modifier_runtime->domain_snapshot_version(ModifierRuntime::COUNTRY)
            : 0);
    if (cache.country_handle == handle && cache.modifier_version == version) {
        ++_research_modifier_cache_hits;
        return;
    }

    const Clock::time_point started = Clock::now();
    cache.country_handle = handle;
    cache.modifier_version = version;
    cache.cost_factor = 1.0;
    cache.efficiency = {{1.0, 1.0, 1.0, 1.0}};
    if (peer_context != nullptr) {
        const size_t slot_index = static_cast<size_t>(slot);
        if (slot_index < peer_context->research_cost_factor.size())
            cache.cost_factor = peer_context->research_cost_factor[slot_index];
        const size_t efficiency_base = slot_index * 4u;
        if (efficiency_base + 4u <= peer_context->research_efficiency.size()) {
            for (int32_t domain = 0; domain < 4; ++domain)
                cache.efficiency[static_cast<size_t>(domain)] =
                    peer_context->research_efficiency[efficiency_base +
                        static_cast<size_t>(domain)];
        }
        _research_modifier_ms += elapsed_ms(started);
        return;
    }
    if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
        static const char *EFFICIENCY_STATS[4] = {
            "country.research.agriculture_efficiency",
            "country.research.engineering_efficiency",
            "country.research.science_efficiency",
            "country.research.society_efficiency",
        };
        cache.cost_factor = _modifier_runtime->effective_value(
            ModifierRuntime::COUNTRY, "country.research.cost_factor",
            handle, 0, 1.0);
        ++_research_modifier_queries;
        for (int32_t domain = 0; domain < 4; ++domain) {
            cache.efficiency[static_cast<size_t>(domain)] =
                _modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, EFFICIENCY_STATS[domain],
                    handle, 0, 1.0);
            ++_research_modifier_queries;
        }
    }
    _research_modifier_ms += elapsed_ms(started);
}

int64_t NativeCountryRuntime::max_storable_research_progress(
        int32_t technology) const {
    if (technology < 0 ||
        technology >= static_cast<int32_t>(_technology_costs.size())) {
        return 1;
    }
    const int64_t base_cost = std::max<int64_t>(
        1, _technology_costs[static_cast<size_t>(technology)]);
    // Keep in sync with ModifierCatalog TECHNOLOGY_STATS for
    // country.research.cost_factor when the ModifierRuntime is not configured.
    constexpr double kResearchCostFactorFallbackMax = 4.0;
    double max_factor = kResearchCostFactorFallbackMax;
    if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
        max_factor = _modifier_runtime->stat_clamp_max(
            "country.research.cost_factor", kResearchCostFactorFallbackMax);
    }
    if (!(max_factor > 0.0) || !std::isfinite(max_factor)) {
        max_factor = kResearchCostFactorFallbackMax;
    }
    return std::max<int64_t>(
        base_cost,
        static_cast<int64_t>(std::llround(
            static_cast<double>(base_cost) * max_factor)));
}

bool NativeCountryRuntime::finalize_research_head_if_complete(
        int32_t slot, int32_t domain, int64_t day_index,
        bool use_pending_queue, CountryPeerContext *peer_context) {
    if (slot < 0 || domain < 0 || domain >= 4) return false;
    const size_t length_index = static_cast<size_t>(slot) * 4U +
        static_cast<size_t>(domain);
    uint8_t &length = _country_research_queue_lengths[length_index];
    if (length == 0) return false;
    const size_t queue_base = length_index * 8U;
    const int32_t technology = _country_research_queues[queue_base];
    if (technology < 0 || has_technology(slot, technology) ||
        !prerequisites_met(slot, technology) ||
        progress_for(slot, technology) < effective_research_cost(
            slot, technology, peer_context))
        return false;

    const size_t word_index = static_cast<size_t>(slot) * _technology_words +
        static_cast<size_t>(technology / 64);
    const uint64_t bit = uint64_t{1} << (technology % 64);
    _country_pending_technologies[word_index] |= bit;
    if (use_pending_queue) insert_pending_activation(slot, technology);
    const std::string &modifier_key =
        _technology_modifier_definition_keys[static_cast<size_t>(technology)];
    if (!modifier_key.empty() && peer_context != nullptr)
        ensure_technology_effect_instance(
            slot, technology, day_index, *peer_context);
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

bool NativeCountryRuntime::capture_peer_context(
        int64_t day, uint32_t continuation_index,
        CountryPeerContext &out, std::string &error) const {
    out = CountryPeerContext{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_context_runtime_unavailable";
        return false;
    }
    if (day < 0) {
        error = "country_peer_context_day_invalid";
        return false;
    }

    out.session_epoch = _session_epoch;
    out.country_generation = _generation;
    out.modifier_generation = _modifier_runtime != nullptr &&
            _modifier_runtime->configured()
        ? _modifier_runtime->domain_snapshot_version(ModifierRuntime::COUNTRY)
        : 0;
    out.effect_generation = _effect_runtime_enabled && _effect_runtime != nullptr
        ? _effect_runtime->committed_generation() : 0;
    out.economy_generation = _economy_runtime != nullptr
        ? _economy_runtime->committed_generation() : 0;
    out.day = day;
    out.continuation_index = continuation_index;
    out.effect_enabled = _effect_runtime_enabled && _effect_runtime != nullptr ? 1 : 0;
    out.modifier_enabled = _modifier_runtime != nullptr &&
        _modifier_runtime->configured() ? 1 : 0;
    out.economy_enabled = _economy_runtime != nullptr ? 1 : 0;
    out.effect_should_run = out.effect_enabled != 0 &&
        _effect_runtime->should_run(day) ? 1 : 0;
    out.modifier_should_run = out.modifier_enabled != 0 &&
        _modifier_runtime->should_run(day) ? 1 : 0;

    constexpr double kFallbackMaxCostFactor = 4.0;
    out.max_research_cost_factor = kFallbackMaxCostFactor;
    if (out.modifier_enabled != 0) {
        out.max_research_cost_factor = _modifier_runtime->stat_clamp_max(
            "country.research.cost_factor", kFallbackMaxCostFactor);
        if (!(out.max_research_cost_factor > 0.0) ||
            !std::isfinite(out.max_research_cost_factor))
            out.max_research_cost_factor = kFallbackMaxCostFactor;
    }

    const size_t country_count = _countries.active.size();
    out.research_cost_factor.assign(country_count, 1.0);
    out.research_efficiency.assign(country_count * 4u, 1.0);
    static constexpr const char *EFFICIENCY_STATS[4] = {
        "country.research.agriculture_efficiency",
        "country.research.engineering_efficiency",
        "country.research.science_efficiency",
        "country.research.society_efficiency",
    };
    if (out.modifier_enabled != 0) {
        for (size_t slot = 0; slot < country_count; ++slot) {
            if (_countries.active[slot] == 0) continue;
            const uint64_t handle = make_handle(static_cast<int32_t>(slot));
            double cost_factor = _modifier_runtime->effective_value(
                ModifierRuntime::COUNTRY, "country.research.cost_factor",
                handle, 0, 1.0);
            if (!(cost_factor > 0.0) || !std::isfinite(cost_factor))
                cost_factor = 1.0;
            out.research_cost_factor[slot] = cost_factor;
            for (int32_t domain = 0; domain < 4; ++domain) {
                double efficiency = _modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, EFFICIENCY_STATS[domain],
                    handle, 0, 1.0);
                if (!(efficiency > 0.0) || !std::isfinite(efficiency))
                    efficiency = 1.0;
                out.research_efficiency[slot * 4u +
                    static_cast<size_t>(domain)] = efficiency;
            }
        }
    }

    const size_t technology_count = _technology_ids.size();
    out.technology_states.reserve(country_count);
    for (size_t slot = 0; slot < country_count; ++slot) {
        if (_countries.active[slot] == 0) continue;
        const size_t word_base = slot * static_cast<size_t>(_technology_words);
        for (size_t technology = 0; technology < technology_count; ++technology) {
            const size_t word = word_base + technology / 64u;
            if (word >= _country_pending_technologies.size() ||
                (_country_pending_technologies[word] &
                    (uint64_t{1} << (technology % 64u))) == 0)
                continue;
            CountryPeerTechnologyState state;
            state.country_slot = static_cast<int32_t>(slot);
            state.technology = static_cast<int32_t>(technology);
            state.target_handle = make_handle(state.country_slot);
            state.effect_instance_id = static_cast<uint64_t>(
                ((state.target_handle & 0x00007fffffffffffULL) << 16U) |
                static_cast<uint64_t>(technology + 1u));
            state.effect_generation = static_cast<uint32_t>(
                state.target_handle >> 32U);
            if (out.effect_enabled != 0 &&
                state.effect_instance_id > 0 && state.effect_generation != 0) {
                if (_effect_runtime->has_instance_pod(
                        static_cast<int64_t>(state.effect_instance_id),
                        state.effect_generation))
                    state.flags |= COUNTRY_PEER_EFFECT_EXISTS;
                if (_effect_runtime->instance_fire_acked_pod(
                        static_cast<int64_t>(state.effect_instance_id),
                        state.effect_generation))
                    state.flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            }
            if (out.modifier_enabled != 0 &&
                technology < _technology_modifier_definition_keys.size() &&
                !_technology_modifier_definition_keys[technology].empty() &&
                _modifier_runtime->has_technology_effect(
                    state.target_handle,
                    _technology_modifier_definition_keys[technology],
                    state.technology))
                state.flags |= COUNTRY_PEER_MODIFIER_APPLIED;
            out.technology_states.push_back(state);
        }
    }
    return true;
}

CountryPeerTechnologyState *NativeCountryRuntime::find_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology) {
    const auto it = std::lower_bound(context.technology_states.begin(),
        context.technology_states.end(), std::pair<int32_t, int32_t>{slot, technology},
        [](const CountryPeerTechnologyState &entry,
           const std::pair<int32_t, int32_t> &value) {
            return entry.country_slot < value.first ||
                (entry.country_slot == value.first &&
                 entry.technology < value.second);
        });
    return it != context.technology_states.end() &&
            it->country_slot == slot && it->technology == technology
        ? &(*it) : nullptr;
}

const CountryPeerTechnologyState *NativeCountryRuntime::find_peer_technology_state(
        const CountryPeerContext &context, int32_t slot,
        int32_t technology) const {
    const auto it = std::lower_bound(context.technology_states.begin(),
        context.technology_states.end(), std::pair<int32_t, int32_t>{slot, technology},
        [](const CountryPeerTechnologyState &entry,
           const std::pair<int32_t, int32_t> &value) {
            return entry.country_slot < value.first ||
                (entry.country_slot == value.first &&
                 entry.technology < value.second);
        });
    return it != context.technology_states.end() &&
            it->country_slot == slot && it->technology == technology
        ? &(*it) : nullptr;
}

CountryPeerTechnologyState &NativeCountryRuntime::ensure_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology) {
    auto it = std::lower_bound(context.technology_states.begin(),
        context.technology_states.end(), std::pair<int32_t, int32_t>{slot, technology},
        [](const CountryPeerTechnologyState &entry,
           const std::pair<int32_t, int32_t> &value) {
            return entry.country_slot < value.first ||
                (entry.country_slot == value.first &&
                 entry.technology < value.second);
        });
    if (it == context.technology_states.end() || it->country_slot != slot ||
        it->technology != technology) {
        CountryPeerTechnologyState state;
        state.country_slot = slot;
        state.technology = technology;
        const uint64_t handle = make_handle(slot);
        state.target_handle = handle;
        state.effect_instance_id = static_cast<uint64_t>(
            ((handle & 0x00007fffffffffffULL) << 16U) |
            static_cast<uint64_t>(technology + 1));
        state.effect_generation = static_cast<uint32_t>(handle >> 32U);
        it = context.technology_states.insert(it, state);
    }
    return *it;
}

CountryPeerIntent NativeCountryRuntime::make_peer_intent(
        const CountryPeerContext &context, CountryPeerIntentCode opcode,
        int32_t slot, int32_t technology, int64_t day_index) const {
    CountryPeerIntent intent;
    intent.opcode = opcode;
    intent.session_epoch = context.session_epoch;
    intent.country_generation = context.country_generation;
    switch (opcode) {
    case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
    case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
    case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
        intent.peer_generation = context.effect_generation;
        break;
    case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
        intent.peer_generation = context.modifier_generation;
        break;
    case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
        intent.peer_generation = context.economy_generation;
        break;
    }
    intent.day = day_index;
    intent.continuation_index = context.continuation_index;
    intent.country_slot = slot;
    intent.technology = technology;
    intent.target_handle = slot >= 0 ? make_handle(slot) : 0;
    if (slot >= 0 && technology >= 0) {
        intent.effect_instance_id = static_cast<uint64_t>(
            ((intent.target_handle & 0x00007fffffffffffULL) << 16U) |
            static_cast<uint64_t>(technology + 1));
        intent.effect_generation = static_cast<uint32_t>(
            intent.target_handle >> 32U);
    }
    intent.request_id = country_peer_request_id(
        intent.session_epoch, intent.country_generation, intent.day,
        intent.continuation_index, slot, technology, opcode);
    intent.idempotency_key = intent.request_id ^ 0x504545525f4944ull;

    // A research completion can advance Country's generation before the peer
    // responds. Reuse the original same-day intent identity in that case;
    // otherwise a continuation would enqueue a second Effect request for the
    // exact same pending technology.
    const auto same_logical_intent = [&](const CountryPeerIntent &existing) {
        return existing.session_epoch == intent.session_epoch &&
            existing.day == intent.day && existing.opcode == intent.opcode &&
            existing.country_slot == intent.country_slot &&
            existing.technology == intent.technology &&
            existing.target_handle == intent.target_handle;
    };
    const CountryPeerIntent *selected_pending = nullptr;
    for (const auto &entry : _peer_pending_intents) {
        if (!same_logical_intent(entry.second)) continue;
        if (selected_pending == nullptr ||
            entry.second.request_id < selected_pending->request_id)
            selected_pending = &entry.second;
    }
    if (selected_pending != nullptr) return *selected_pending;

    const CountryPeerResult *selected_cached = nullptr;
    for (const auto &entry : _peer_result_cache) {
        const CountryPeerResult &existing = entry.second;
        if (existing.code == CountryPeerResultCode::REJECTED)
            continue;
        if (existing.session_epoch != intent.session_epoch ||
            existing.day != intent.day || existing.opcode != intent.opcode ||
            existing.country_slot != intent.country_slot ||
            existing.technology != intent.technology ||
            existing.target_handle != intent.target_handle)
            continue;
        if (selected_cached == nullptr ||
            existing.request_id < selected_cached->request_id)
            selected_cached = &existing;
    }
    if (selected_cached != nullptr) {
        intent.request_id = selected_cached->request_id;
        intent.country_generation = selected_cached->country_generation;
        intent.peer_generation = selected_cached->peer_generation;
        intent.continuation_index = selected_cached->continuation_index;
        intent.idempotency_key = intent.request_id ^ 0x504545525f4944ull;
    }
    return intent;
}

void NativeCountryRuntime::set_peer_async_mode(bool enabled) {
    _peer_async_mode = enabled;
}

CountryPeerProtocolStatus NativeCountryRuntime::peer_protocol_status() const {
    CountryPeerProtocolStatus status;
    status.async_mode = _peer_async_mode ? 1 : 0;
    status.pending_intents = static_cast<uint32_t>(std::min<size_t>(
        _peer_pending_intents.size(), std::numeric_limits<uint32_t>::max()));
    status.queued_intents = static_cast<uint32_t>(std::min<size_t>(
        _peer_intent_queue.size(), std::numeric_limits<uint32_t>::max()));
    status.rejected_intents = static_cast<uint32_t>(std::min<size_t>(
        _peer_rejected_results.size(), std::numeric_limits<uint32_t>::max()));

    const CountryPeerResult *selected = nullptr;
    bool selected_unreported = false;
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &candidate = entry.second;
        const bool unreported = _peer_rejection_reported.find(
            candidate.request_id) == _peer_rejection_reported.end();
        if (selected == nullptr ||
            (unreported && !selected_unreported) ||
            (unreported == selected_unreported &&
             candidate.request_id < selected->request_id)) {
            selected = &candidate;
            selected_unreported = unreported;
        }
        const int64_t candidate_retry_day = candidate.day <
                std::numeric_limits<int64_t>::max()
            ? candidate.day + 1 : candidate.day;
        if (status.retry_day < 0 || candidate_retry_day < status.retry_day)
            status.retry_day = candidate_retry_day;
        if (unreported)
            status.has_unreported_rejection = 1;
    }
    if (selected != nullptr) {
        status.rejected_request_id = selected->request_id;
        status.rejected_opcode = selected->opcode;
        status.rejection_reason = selected->reason;
    }
    return status;
}

void NativeCountryRuntime::remember_peer_rejection(
        const CountryPeerResult &result) {
    if (result.code != CountryPeerResultCode::REJECTED ||
        result.request_id == 0)
        return;
    _peer_rejected_results[result.request_id] = result;
    _peer_rejection_reported.erase(result.request_id);
}

void NativeCountryRuntime::clear_peer_rejections_for_retry(
        const CountryPeerIntent &intent) {
    const auto is_technology_intent = [](CountryPeerIntentCode opcode) {
        return opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
            opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
            opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    };
    std::vector<uint64_t> obsolete;
    obsolete.reserve(_peer_rejected_results.size());
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        if (rejection.request_id == intent.request_id ||
            rejection.session_epoch != intent.session_epoch ||
            rejection.day >= intent.day ||
            rejection.country_slot != intent.country_slot ||
            rejection.technology != intent.technology ||
            rejection.target_handle != intent.target_handle)
            continue;
        const bool same_technology_retry =
            is_technology_intent(rejection.opcode) &&
            is_technology_intent(intent.opcode);
        if (!same_technology_retry && rejection.opcode != intent.opcode)
            continue;
        obsolete.push_back(entry.first);
    }
    for (const uint64_t request_id : obsolete) {
        _peer_rejected_results.erase(request_id);
        _peer_rejection_reported.erase(request_id);
        const auto cached = _peer_result_cache.find(request_id);
        if (cached != _peer_result_cache.end() &&
            cached->second.code == CountryPeerResultCode::REJECTED)
            _peer_result_cache.erase(cached);
    }
}

bool NativeCountryRuntime::peer_rejection_blocks_activation(
        int32_t slot, int32_t technology, int64_t day) const {
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        if (rejection.country_slot != slot ||
            rejection.technology != technology ||
            (rejection.opcode != CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT &&
             rejection.opcode != CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT &&
             rejection.opcode != CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER))
            continue;
        const int64_t retry_day = rejection.day <
                std::numeric_limits<int64_t>::max()
            ? rejection.day + 1 : rejection.day;
        // The first pass after an ACK must consume and report the rejection.
        // Once reported, the same logical activation is held until the next
        // calendar day, where a new request identity is created.
        if (_peer_rejection_reported.find(rejection.request_id) ==
                _peer_rejection_reported.end() && day >= rejection.day)
            return false;
        if (day < retry_day) return true;
    }
    return false;
}

bool NativeCountryRuntime::peer_rejection_needs_service(int64_t day) const {
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        if (_peer_rejection_reported.find(rejection.request_id) ==
                _peer_rejection_reported.end() && day >= rejection.day)
            return true;
        const int64_t retry_day = rejection.day <
                std::numeric_limits<int64_t>::max()
            ? rejection.day + 1 : rejection.day;
        if (day >= retry_day) return true;
    }
    return false;
}

void NativeCountryRuntime::mark_peer_rejections_reported(int64_t day) {
    for (const auto &entry : _peer_rejected_results) {
        if (entry.second.day <= day)
            _peer_rejection_reported.insert(entry.first);
    }
}

bool NativeCountryRuntime::retry_peer_rejections(
        int64_t day, CountryPeerContext &context) {
    std::vector<uint64_t> retry_ids;
    retry_ids.reserve(_peer_rejected_results.size());
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        const int64_t retry_day = rejection.day <
                std::numeric_limits<int64_t>::max()
            ? rejection.day + 1 : rejection.day;
        if (day < retry_day) continue;
        // Technology activation retries are driven by the pending bitset in
        // run_research_day. Only post-activation peer work is retried here;
        // otherwise the same intent would be emitted twice in one boundary.
        if (rejection.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
            rejection.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
            rejection.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER)
            continue;
        retry_ids.push_back(entry.first);
    }
    std::sort(retry_ids.begin(), retry_ids.end());
    bool protocol_fault = false;
    for (const uint64_t request_id : retry_ids) {
        const auto found = _peer_rejected_results.find(request_id);
        if (found == _peer_rejected_results.end()) continue;
        const CountryPeerResult previous = found->second;
        const CountryPeerIntent retry = make_peer_intent(
            context, previous.opcode, previous.country_slot,
            previous.technology, day);
        if (retry.request_id == previous.request_id) {
            protocol_fault = true;
            continue;
        }
        // Applying a retry may insert a new rejection and rehash the map, so
        // remove the old entry before calling apply_peer_intent().
        _peer_rejected_results.erase(request_id);
        _peer_rejection_reported.erase(request_id);
        const CountryPeerResult result = apply_peer_intent(context, retry);
        if (result.code == CountryPeerResultCode::STALE)
            protocol_fault = true;
    }
    return !protocol_fault;
}

void NativeCountryRuntime::clear_peer_protocol_state() {
    _peer_pending_intents.clear();
    _peer_intent_queue.clear();
    _peer_result_cache.clear();
    _peer_rejected_results.clear();
    _peer_rejection_reported.clear();
    _peer_async_mode = false;
}

bool NativeCountryRuntime::poll_peer_intent(CountryPeerIntent &out) {
    while (!_peer_intent_queue.empty()) {
        const uint64_t request_id = _peer_intent_queue.front();
        _peer_intent_queue.pop_front();
        const auto found = _peer_pending_intents.find(request_id);
        if (found == _peer_pending_intents.end()) continue;
        out = found->second;
        return true;
    }
    return false;
}

bool NativeCountryRuntime::peer_result_identity_matches(
        const CountryPeerIntent &intent, const CountryPeerResult &result,
        std::string &error) const {
    error.clear();
    if (result.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION) {
        error = "country_peer_result_protocol_invalid";
        return false;
    }
    if (result.request_id != intent.request_id ||
        result.session_epoch != intent.session_epoch ||
        result.country_generation != intent.country_generation ||
        result.peer_generation != intent.peer_generation ||
        result.day != intent.day ||
        result.continuation_index != intent.continuation_index ||
        result.opcode != intent.opcode ||
        result.country_slot != intent.country_slot ||
        result.technology != intent.technology ||
        result.target_handle != intent.target_handle) {
        error = "country_peer_result_identity_mismatch";
        return false;
    }
    return true;
}

void NativeCountryRuntime::apply_peer_result_to_context(
        CountryPeerContext &context, const CountryPeerResult &result) {
    if (result.committed_peer_generation != 0) {
        switch (result.opcode) {
        case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
            context.effect_generation = result.committed_peer_generation;
            break;
        case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
            context.modifier_generation = result.committed_peer_generation;
            break;
        case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
            context.economy_generation = result.committed_peer_generation;
            break;
        }
    }
    if (!result.ok() || result.technology_flags == 0 ||
        result.country_slot < 0 || result.technology < 0 ||
        result.technology >= static_cast<int32_t>(_technology_ids.size()))
        return;
    CountryPeerTechnologyState &state = ensure_peer_technology_state(
        context, result.country_slot, result.technology);
    state.flags = result.technology_flags;
}

bool NativeCountryRuntime::submit_peer_result(
        const CountryPeerResult &result, std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_result_runtime_unavailable";
        return false;
    }
    if (result.request_id == 0 ||
        static_cast<uint8_t>(result.code) >
            static_cast<uint8_t>(CountryPeerResultCode::STALE)) {
        error = "country_peer_result_invalid";
        return false;
    }
    if (result.code == CountryPeerResultCode::STALE) {
        // STALE describes a protocol identity failure. It is not a durable
        // business rejection and must never enter the retry queue.
        error = "country_peer_result_stale_terminal_invalid";
        return false;
    }
    const auto pending = _peer_pending_intents.find(result.request_id);
    const auto cached = _peer_result_cache.find(result.request_id);
    if (pending == _peer_pending_intents.end()) {
        if (cached == _peer_result_cache.end()) {
            error = "country_peer_result_request_unknown";
            return false;
        }
        const CountryPeerResult &previous = cached->second;
        if (previous.protocol_version != result.protocol_version ||
            previous.request_id != result.request_id ||
            previous.session_epoch != result.session_epoch ||
            previous.country_generation != result.country_generation ||
            previous.peer_generation != result.peer_generation ||
            previous.day != result.day ||
            previous.continuation_index != result.continuation_index ||
            previous.opcode != result.opcode ||
            previous.country_slot != result.country_slot ||
            previous.technology != result.technology ||
            previous.target_handle != result.target_handle ||
            previous.code != result.code ||
            previous.committed_peer_generation !=
                result.committed_peer_generation ||
            previous.technology_flags != result.technology_flags) {
            error = "country_peer_result_duplicate_mismatch";
            return false;
        }
        return true;
    }
    if (!peer_result_identity_matches(pending->second, result, error))
        return false;
    if (result.ok() && pending->second.peer_generation != 0 &&
        (result.committed_peer_generation == 0 ||
         result.committed_peer_generation < pending->second.peer_generation)) {
        error = "country_peer_result_generation_invalid";
        return false;
    }
    _peer_result_cache[result.request_id] = result;
    if (result.code != CountryPeerResultCode::PENDING)
        _peer_pending_intents.erase(pending);
    if (result.code == CountryPeerResultCode::REJECTED)
        remember_peer_rejection(result);
    return true;
}

CountryPeerResult NativeCountryRuntime::apply_peer_intent(
        CountryPeerContext &context, const CountryPeerIntent &intent) {
    CountryPeerResult result;
    result.opcode = intent.opcode;
    result.request_id = intent.request_id;
    result.session_epoch = intent.session_epoch;
    result.country_generation = intent.country_generation;
    result.peer_generation = intent.peer_generation;
    result.day = intent.day;
    result.continuation_index = intent.continuation_index;
    result.country_slot = intent.country_slot;
    result.technology = intent.technology;
    result.target_handle = intent.target_handle;

    auto reject = [&](CountryPeerResultCode code, const char *reason) {
        result.code = code;
        country_peer_copy_reason(result.reason, reason);
        if (code == CountryPeerResultCode::REJECTED)
            remember_peer_rejection(result);
        ++_peer_results_consumed;
        return result;
    };
    const auto intent_identity_matches = [](const CountryPeerIntent &lhs,
                                            const CountryPeerIntent &rhs) {
        return lhs.protocol_version == rhs.protocol_version &&
            lhs.opcode == rhs.opcode && lhs.request_id == rhs.request_id &&
            lhs.session_epoch == rhs.session_epoch &&
            lhs.country_generation == rhs.country_generation &&
            lhs.peer_generation == rhs.peer_generation && lhs.day == rhs.day &&
            lhs.continuation_index == rhs.continuation_index &&
            lhs.country_slot == rhs.country_slot && lhs.technology == rhs.technology &&
            lhs.target_handle == rhs.target_handle &&
            lhs.effect_instance_id == rhs.effect_instance_id &&
            lhs.effect_generation == rhs.effect_generation &&
            lhs.idempotency_key == rhs.idempotency_key;
    };
    const auto existing_context_valid = [&]() {
        if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
            intent.session_epoch == 0 || intent.session_epoch != _session_epoch ||
            intent.session_epoch != context.session_epoch ||
            intent.day != context.day)
            return false;
        if (intent.target_handle == 0) return true;
        int32_t slot = -1;
        return validate_handle(intent.target_handle, slot) &&
            (intent.country_slot < 0 || slot == intent.country_slot);
    };

    // Existing requests deliberately outlive a Country generation change made
    // by the same research completion. They remain safe because their session,
    // day and target handle are checked here, and no cached result can be
    // substituted for a different request identity.
    const auto pending_intent = _peer_pending_intents.find(intent.request_id);
    if (pending_intent != _peer_pending_intents.end()) {
        if (!existing_context_valid() ||
            !intent_identity_matches(intent, pending_intent->second)) {
            return reject(CountryPeerResultCode::STALE,
                          "country_peer_intent_identity_stale");
        }
        result.code = CountryPeerResultCode::PENDING;
        country_peer_copy_reason(result.reason,
                                 "country_peer_intent_waiting_for_result");
        const CountryPeerTechnologyState *state =
            find_peer_technology_state(context, intent.country_slot,
                                      intent.technology);
        if (state != nullptr) result.technology_flags = state->flags;
        return result;
    }
    const auto cached_result = _peer_result_cache.find(intent.request_id);
    if (cached_result != _peer_result_cache.end()) {
        std::string cache_error;
        if (!existing_context_valid() ||
            !peer_result_identity_matches(intent, cached_result->second,
                                          cache_error)) {
            return reject(CountryPeerResultCode::STALE,
                          "country_peer_intent_identity_stale");
        }
        result = cached_result->second;
        apply_peer_result_to_context(context, result);
        ++_peer_results_consumed;
        return result;
    }
    if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        intent.session_epoch == 0 || intent.session_epoch != _session_epoch ||
        intent.session_epoch != context.session_epoch ||
        intent.country_generation == 0 ||
        intent.country_generation != context.country_generation ||
        intent.country_generation != _generation ||
        intent.day != context.day ||
        intent.continuation_index != context.continuation_index) {
        return reject(CountryPeerResultCode::STALE,
                      "country_peer_intent_identity_stale");
    }
    const bool effect_intent =
        intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD;
    const bool modifier_intent =
        intent.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    const bool economy_intent =
        intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE;
    if (!effect_intent && !modifier_intent && !economy_intent)
        return reject(CountryPeerResultCode::REJECTED,
                      "country_peer_intent_opcode_invalid");
    const uint64_t expected_peer_generation = effect_intent
        ? context.effect_generation
        : (modifier_intent ? context.modifier_generation :
            (economy_intent ? context.economy_generation : 0));
    if (intent.peer_generation != expected_peer_generation) {
        return reject(CountryPeerResultCode::STALE,
                      "country_peer_intent_peer_generation_stale");
    }

    // A new, identity-valid request for the same logical operation supersedes
    // an earlier-day rejection. The current request rejection, if any, is
    // inserted by reject() below and remains visible.
    clear_peer_rejections_for_retry(intent);

    if (_peer_async_mode) {
        const bool technology_intent = effect_intent || modifier_intent;
        if (technology_intent) {
            int32_t validated_slot = -1;
            if (intent.country_slot < 0 || intent.technology < 0 ||
                intent.technology >= static_cast<int32_t>(_technology_ids.size()) ||
                !validate_handle(intent.target_handle, validated_slot) ||
                validated_slot != intent.country_slot)
                return reject(CountryPeerResultCode::REJECTED,
                              "country_peer_intent_target_invalid");
            const CountryPeerTechnologyState *state =
                find_peer_technology_state(context, intent.country_slot,
                                           intent.technology);
            if (state != nullptr &&
                ((effect_intent && intent.opcode !=
                      CountryPeerIntentCode::NOTIFY_ERA_REWARD &&
                    state->has(COUNTRY_PEER_EFFECT_FIRE_ACKED)) ||
                 (modifier_intent &&
                    state->has(COUNTRY_PEER_MODIFIER_APPLIED)))) {
                result.code = effect_intent
                    ? CountryPeerResultCode::READY
                    : CountryPeerResultCode::APPLIED;
                result.committed_peer_generation = expected_peer_generation;
                result.technology_flags = state->flags;
                ++_peer_results_consumed;
                return result;
            }
        }
        _peer_pending_intents.emplace(intent.request_id, intent);
        _peer_intent_queue.push_back(intent.request_id);
        ++_peer_intents_emitted;
        result.code = CountryPeerResultCode::PENDING;
        country_peer_copy_reason(result.reason, "country_peer_intent_queued");
        return result;
    }
    ++_peer_intents_emitted;
    result = execute_peer_intent_main_thread(intent);
    apply_peer_result_to_context(context, result);
    if (result.code == CountryPeerResultCode::REJECTED)
        remember_peer_rejection(result);
    return result;
}

CountryPeerResult NativeCountryRuntime::execute_peer_intent_main_thread(
        const CountryPeerIntent &intent, bool validate_local_identity) {
    CountryPeerResult result;
    result.protocol_version = intent.protocol_version;
    result.opcode = intent.opcode;
    result.request_id = intent.request_id;
    result.session_epoch = intent.session_epoch;
    result.country_generation = intent.country_generation;
    result.peer_generation = intent.peer_generation;
    result.day = intent.day;
    result.continuation_index = intent.continuation_index;
    result.country_slot = intent.country_slot;
    result.technology = intent.technology;
    result.target_handle = intent.target_handle;

    auto reject = [&](const char *reason) {
        result.code = CountryPeerResultCode::REJECTED;
        country_peer_copy_reason(result.reason, reason);
        ++_peer_results_consumed;
        return result;
    };
    if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        intent.request_id == 0 || intent.day < 0 ||
        (validate_local_identity &&
         (intent.session_epoch != _session_epoch ||
          intent.country_generation == 0 ||
          intent.country_generation > _generation)))
        return reject("country_peer_adapter_identity_invalid");

    const bool effect_intent =
        intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD;
    const bool modifier_intent =
        intent.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    const bool economy_intent =
        intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE;
    if (!effect_intent && !modifier_intent && !economy_intent)
        return reject("country_peer_intent_opcode_invalid");

    if (intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD) {
        if (!_effect_runtime_enabled || _effect_runtime == nullptr)
            return reject("country_peer_effect_runtime_unavailable");
        if (_effect_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_effect_generation_regressed");
        std::string peer_error;
        if (!_effect_runtime->notify_era_reward_technology_activated_pod(
                intent.target_handle, intent.technology, intent.day,
                peer_error))
            return reject(peer_error.empty() ? "country_peer_era_reward_rejected"
                                             : peer_error.c_str());
        result.code = CountryPeerResultCode::APPLIED;
        result.committed_peer_generation = _effect_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }
    if (intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE) {
        if (_economy_runtime == nullptr)
            return reject("country_peer_economy_runtime_unavailable");
        if (_economy_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_economy_generation_regressed");
        _economy_runtime->notify_era_milestone_activated(intent.target_handle);
        result.code = CountryPeerResultCode::APPLIED;
        result.committed_peer_generation = _economy_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }

    int32_t validated_slot = -1;
    if (intent.country_slot < 0 || intent.technology < 0 ||
        intent.technology >= static_cast<int32_t>(_technology_ids.size()) ||
        !validate_handle(intent.target_handle, validated_slot) ||
        validated_slot != intent.country_slot)
        return reject("country_peer_intent_target_invalid");

    const std::string &modifier_key =
        intent.technology < static_cast<int32_t>(
            _technology_modifier_definition_keys.size())
        ? _technology_modifier_definition_keys[
              static_cast<size_t>(intent.technology)]
        : std::string{};
    uint8_t technology_flags = 0;
    if (_modifier_runtime != nullptr && _modifier_runtime->configured() &&
        !modifier_key.empty() && _modifier_runtime->has_technology_effect(
            intent.target_handle, modifier_key, intent.technology))
        technology_flags |= COUNTRY_PEER_MODIFIER_APPLIED;

    if (intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT) {
        if (!_effect_runtime_enabled || _effect_runtime == nullptr)
            return reject("country_peer_effect_runtime_unavailable");
        if (_effect_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_effect_generation_regressed");
        if (intent.effect_generation == 0 ||
            intent.effect_generation != static_cast<uint32_t>(
                intent.target_handle >> 32U) ||
            intent.effect_instance_id == 0)
            return reject("country_peer_effect_generation_invalid");
        const bool exists = _effect_runtime->has_instance_pod(
            static_cast<int64_t>(intent.effect_instance_id),
            intent.effect_generation);
        if (!exists) {
            if (intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT)
                return reject("country_peer_effect_instance_missing");
            std::string peer_error;
            if (!_effect_runtime->upsert_instance_pod(
                    static_cast<int64_t>(intent.effect_instance_id),
                    std::string("technology.") +
                        _technology_ids[static_cast<size_t>(intent.technology)],
                    intent.effect_generation, 0x54454348,
                    intent.technology + 1, intent.target_handle,
                    intent.target_handle, intent.effect_generation, 0,
                    intent.day, true, peer_error))
                return reject(peer_error.empty()
                    ? "country_peer_effect_upsert_rejected"
                    : peer_error.c_str());
        }
        if (!_effect_runtime->instance_fire_acked_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation) &&
            !_effect_runtime->nudge_unacked_instance_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation, intent.day))
            return reject("country_peer_effect_nudge_rejected");

        technology_flags |= COUNTRY_PEER_EFFECT_EXISTS;
        if (_effect_runtime->instance_fire_acked_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation)) {
            technology_flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            result.code = CountryPeerResultCode::READY;
        } else {
            result.code = CountryPeerResultCode::PENDING;
        }
        result.technology_flags = technology_flags;
        result.committed_peer_generation = _effect_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }

    if (_modifier_runtime == nullptr || !_modifier_runtime->configured() ||
        modifier_key.empty())
        return reject("country_peer_modifier_runtime_unavailable");
    if (_modifier_runtime->domain_snapshot_version(ModifierRuntime::COUNTRY) <
        intent.peer_generation)
        return reject("country_peer_adapter_modifier_generation_regressed");
    if ((technology_flags & COUNTRY_PEER_MODIFIER_APPLIED) == 0) {
        std::string peer_error;
        if (!_modifier_runtime->apply_technology_effect(
                intent.target_handle, modifier_key, intent.technology,
                intent.day, peer_error))
            return reject(peer_error.empty()
                ? "country_peer_modifier_apply_rejected"
                : peer_error.c_str());
        technology_flags |= COUNTRY_PEER_MODIFIER_APPLIED;
    }
    result.code = CountryPeerResultCode::APPLIED;
    result.technology_flags = technology_flags;
    result.committed_peer_generation =
        _modifier_runtime->domain_snapshot_version(ModifierRuntime::COUNTRY);
    ++_peer_results_consumed;
    return result;
}

CountryPeerResult NativeCountryRuntime::execute_peer_intent_from_worker(
        const CountryPeerIntent &intent) {
    return execute_peer_intent_main_thread(intent, false);
}

bool NativeCountryRuntime::service_peer_intents_main_thread(
        int32_t max_intents, PeerAdapterServiceReport &out,
        std::string &error) {
    out = PeerAdapterServiceReport{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_adapter_runtime_unavailable";
        return false;
    }
    if (!_peer_async_mode) {
        error = "country_peer_adapter_async_mode_required";
        return false;
    }
    if (max_intents <= 0 || max_intents > 4096) {
        error = "country_peer_adapter_limit_invalid";
        return false;
    }

    std::vector<uint64_t> request_ids;
    request_ids.reserve(_peer_pending_intents.size());
    for (const auto &entry : _peer_pending_intents)
        request_ids.push_back(entry.first);
    std::sort(request_ids.begin(), request_ids.end());
    if (request_ids.size() > static_cast<size_t>(max_intents))
        request_ids.resize(static_cast<size_t>(max_intents));

    for (const uint64_t request_id : request_ids) {
        const auto found = _peer_pending_intents.find(request_id);
        if (found == _peer_pending_intents.end()) continue;
        const CountryPeerIntent intent = found->second;
        _peer_intent_queue.erase(std::remove(_peer_intent_queue.begin(),
                                            _peer_intent_queue.end(), request_id),
                                 _peer_intent_queue.end());
        ++out.inspected;
        out.last_request_id = request_id;
        switch (intent.opcode) {
        case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
            ++out.effect_intents;
            break;
        case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
            ++out.modifier_intents;
            break;
        case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
            ++out.economy_intents;
            break;
        }

        const CountryPeerResult result = execute_peer_intent_main_thread(intent);
        out.last_reason = result.reason.data();
        switch (result.code) {
        case CountryPeerResultCode::READY:
        case CountryPeerResultCode::APPLIED:
            ++out.completed;
            break;
        case CountryPeerResultCode::PENDING:
            ++out.pending;
            break;
        case CountryPeerResultCode::REJECTED:
        case CountryPeerResultCode::STALE:
            ++out.rejected;
            break;
        }
        std::string submit_error;
        if (!submit_peer_result(result, submit_error)) {
            error = submit_error.empty()
                ? "country_peer_adapter_result_submit_failed"
                : submit_error;
            return false;
        }
        if (_simulation_host != nullptr && !_sync_store_writes_forbidden &&
            _simulation_host->country_pod_configured() &&
            result.code != CountryPeerResultCode::PENDING) {
            std::string mirror_error;
            _simulation_host->mirror_country_peer_result(result, mirror_error);
        }
    }
    return true;
}

bool NativeCountryRuntime::ensure_technology_effect_instance(
        int32_t slot, int32_t technology, int64_t day_index,
        CountryPeerContext &peer_context) {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()))
        return false;
    const CountryPeerTechnologyState *state = find_peer_technology_state(
        peer_context, slot, technology);
    const CountryPeerIntentCode opcode = state != nullptr &&
        state->has(COUNTRY_PEER_EFFECT_EXISTS)
        ? CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT
        : CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
    const CountryPeerIntent intent = make_peer_intent(
        peer_context, opcode, slot, technology, day_index);
    const CountryPeerResult result = apply_peer_intent(peer_context, intent);
    return result.ok();
}

bool NativeCountryRuntime::ack_chain_due(
        int64_t day_index, const CountryPeerContext *peer_context) const {
    if (!_peer_pending_intents.empty()) return true;
    if (peer_context != nullptr && peer_context->day == day_index)
        return peer_context->effect_should_run != 0 ||
            peer_context->modifier_should_run != 0;
    if (_effect_runtime_enabled && _effect_runtime != nullptr &&
        _effect_runtime->should_run(day_index))
        return true;
    return _modifier_runtime != nullptr && _modifier_runtime->configured() &&
        _modifier_runtime->should_run(day_index);
}

int32_t NativeCountryRuntime::run_research_day(
        int64_t day_index, const CountryPeerContext *peer_context,
        CountryPeerContext *out_peer_context) {
    if (_technology_points_good_id < 0) return 0;
    CountryPeerContext owned_peer_context;
    if (peer_context == nullptr) {
        std::string peer_error;
        if (!capture_peer_context(day_index, _reference_continuation_index,
                                  owned_peer_context, peer_error)) {
            if (!_pod_execution && !peer_error.empty())
                _report["country_peer_context_error"] = String(peer_error.c_str());
            if (out_peer_context != nullptr) *out_peer_context = owned_peer_context;
            return 0;
        }
        peer_context = &owned_peer_context;
    }
    if (peer_context->day != day_index ||
        peer_context->session_epoch != _session_epoch ||
        peer_context->country_generation != _generation) {
        if (!_pod_execution)
            _report["country_peer_context_error"] =
                "country_peer_context_identity_stale";
        if (out_peer_context != nullptr) *out_peer_context = *peer_context;
        return 0;
    }
    // The input capture remains immutable. Immediate synchronous adapter
    // results are applied to this local copy so a same-day continuation sees
    // exactly the facts produced by the intent it just submitted.
    CountryPeerContext working_peer_context = *peer_context;
    CountryPeerContext *working_context = &working_peer_context;
    _peer_protocol_fault_reason.clear();
    _research_activation_ms = 0.0;
    _research_allocation_ms = 0.0;
    _research_effect_ack_ms = 0.0;
    _research_discovery_ms = 0.0;
    _research_modifier_ms = 0.0;
    _research_countries_scanned = 0;
    _research_active_countries = 0;
    _research_pending_checks = 0;
    _research_discovery_checks = 0;
    _research_modifier_queries = 0;
    _research_modifier_cache_hits = 0;
    _research_remainder_iterations = 0;
    if (!retry_peer_rejections(day_index, *working_context)) {
        _peer_protocol_fault_reason = "country_peer_retry_protocol_fault";
        if (out_peer_context != nullptr)
            *out_peer_context = working_peer_context;
        return 0;
    }
    // Research allocation is once per day, but pending technologies may be
    // ACKed by Effect/Modifier later in the same day. Keep the activation
    // pass live for same-day continuations instead of making the completed
    // node wait for a new research command or the next calendar day.
    const bool research_due = day_index > _last_research_day;
    bool use_pending_queue = _pending_queue_enabled;
    bool pending_queue_fallback = false;
    if (use_pending_queue && _pending_activation_index_dirty)
        rebuild_pending_activation_index();
    if (_research_active_country_membership.size() != _countries.active.size())
        rebuild_research_active_index();
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
    _research_active_country_scratch.clear();
    _research_active_country_scratch.swap(_research_active_country_slots);
    for (const int32_t slot : _research_active_country_scratch) {
        if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
            _countries.active[static_cast<size_t>(slot)] == 0) continue;
        ++_research_countries_scanned;
        ++_research_active_countries;
        _research_active_country_membership[static_cast<size_t>(slot)] = 0;
        auto retain_if_active = [&]() {
            if (!country_has_research_work(slot)) return;
            _research_active_country_slots.push_back(slot);
            _research_active_country_membership[static_cast<size_t>(slot)] = 1;
        };
        const Clock::time_point activation_started = Clock::now();
        const size_t word_base = static_cast<size_t>(slot) * _technology_words;
        bool activated = false;
        std::vector<int32_t> &activated_pending =
            _research_activated_pending_scratch;
        std::vector<int32_t> &activated_technologies =
            _research_activated_technologies_scratch;
        activated_pending.clear();
        activated_technologies.clear();
        const int32_t candidate_count = use_pending_queue
            ? static_cast<int32_t>(
                _pending_activation_indices[static_cast<size_t>(slot)].size())
            : static_cast<int32_t>(_technology_ids.size());
        for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
            ++_research_pending_checks;
            const int32_t technology = use_pending_queue
                ? _pending_activation_indices[static_cast<size_t>(slot)][
                    static_cast<size_t>(candidate)]
                : candidate;
            const size_t word_index = word_base + technology / 64;
            const uint64_t bit = 1ULL << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) == 0) continue;
            if (peer_rejection_blocks_activation(slot, technology, day_index))
                continue;
            const std::string &technology_modifier_key =
                _technology_modifier_definition_keys[static_cast<size_t>(technology)];
            bool modifier_ready = technology_modifier_key.empty();
            const uint64_t handle = make_handle(slot);
            if (working_context->effect_enabled != 0 &&
                !technology_modifier_key.empty()) {
                const Clock::time_point effect_started = Clock::now();
                ensure_technology_effect_instance(
                    slot, technology, day_index, *working_context);
                const CountryPeerTechnologyState *peer_state =
                    find_peer_technology_state(*working_context, slot, technology);
                modifier_ready = peer_state != nullptr &&
                    (peer_state->has(COUNTRY_PEER_EFFECT_FIRE_ACKED) ||
                     peer_state->has(COUNTRY_PEER_MODIFIER_APPLIED));
                _research_effect_ack_ms += elapsed_ms(effect_started);
            }
            if (!modifier_ready &&
                working_context->effect_enabled == 0 &&
                working_context->modifier_enabled != 0 &&
                !technology_modifier_key.empty()) {
                const Clock::time_point effect_started = Clock::now();
                // Legacy configurations without EffectRuntime retain their
                // direct idempotent path. Once EffectRuntime is authoritative,
                // activation must wait for its cross-domain ACK chain.
                const CountryPeerIntent intent = make_peer_intent(
                    *working_context,
                    CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER,
                    slot, technology, day_index);
                const CountryPeerResult result = apply_peer_intent(
                    *working_context, intent);
                modifier_ready = result.ok() &&
                    result.has(COUNTRY_PEER_MODIFIER_APPLIED);
                _research_effect_ack_ms += elapsed_ms(effect_started);
            }
            if (!modifier_ready) continue;
            const int32_t visual_era_before = visual_era_index_for_slot(slot);
            _country_technologies[word_index] |= bit;
            _country_pending_technologies[word_index] &= ~bit;
            const int32_t visual_era_after = visual_era_index_for_slot(slot);
            if (visual_era_after != visual_era_before) {
                if (_current_visual_era.size() < _countries.active.size())
                    _current_visual_era.resize(_countries.active.size(), -1);
                _current_visual_era[static_cast<size_t>(slot)] = visual_era_after;
                _visual_era_dirty_slots.push_back(slot);
                ++_visual_era_generation;
            }
            if (use_pending_queue)
                activated_pending.push_back(technology);
            activated_technologies.push_back(technology);
            // Era rewards are emitted only after the technology's permanent
            // Effect has ACKed and the completed bit becomes authoritative.
            // Research progress reaching its cost never enters this hook.
            if (working_context->effect_enabled != 0) {
                const CountryPeerIntent reward_intent = make_peer_intent(
                    *working_context, CountryPeerIntentCode::NOTIFY_ERA_REWARD,
                    slot, technology, day_index);
                const CountryPeerResult reward_result = apply_peer_intent(
                    *working_context, reward_intent);
                if (!_pod_execution && !reward_result.ok())
                    _report["era_reward_error"] = String(
                        reward_result.reason.data());
                if (working_context->economy_enabled != 0) {
                    const CountryPeerIntent economy_intent = make_peer_intent(
                        *working_context,
                        CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE,
                        slot, technology, day_index);
                    apply_peer_intent(*working_context, economy_intent);
                }
            }
            activated = true;
        }
        for (const int32_t technology : activated_pending)
            erase_pending_activation(slot, technology);
        if (activated) {
            const Clock::time_point discovery_started = Clock::now();
            refresh_discovery_for_completed(slot, activated_technologies);
            _research_discovery_ms += elapsed_ms(discovery_started);
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
                    slot, domain, day_index, use_pending_queue,
                    working_context)) {
                ++_countries.state_version[static_cast<size_t>(slot)];
                ++changed;
            }
        }
        _research_activation_ms += elapsed_ms(activation_started);

        int64_t &stock = _country_goods[
            static_cast<size_t>(slot) * _good_ids.size() +
            static_cast<size_t>(_technology_points_good_id)];
        if (!research_due) {
            retain_if_active();
            continue;
        }
        const int64_t prior_deferred = std::min(
            _country_research_deferred_points[static_cast<size_t>(slot)], stock);
        const int64_t available = stock - prior_deferred;
        if (available <= 0) {
            retain_if_active();
            continue;
        }

        const Clock::time_point allocation_started = Clock::now();

        std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> weights{{0, 0, 0, 0}};
        for (int32_t domain = 0; domain < 4; ++domain)
            weights[static_cast<size_t>(domain)] = _country_research_weights_bp[
                static_cast<size_t>(slot) * 4U + static_cast<size_t>(domain)];
        uint64_t remainder_iterations = 0;
        const CountryResearchAllocation allocation =
            country_allocate_research_points(available, weights,
                                              &remainder_iterations);
        _research_remainder_iterations += remainder_iterations;

        int64_t consumed = 0;
        int64_t newly_deferred = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            int64_t domain_points = allocation.shares[static_cast<size_t>(domain)];
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
                ensure_research_modifier_cache(slot, working_context);
                const double efficiency =
                    _research_modifier_cache[static_cast<size_t>(slot)]
                        .efficiency[static_cast<size_t>(domain)];
                const double cost_factor = _research_modifier_cache[
                    static_cast<size_t>(slot)].cost_factor;
                const CountryResearchProgress step =
                    country_advance_research_progress(
                        progress,
                        _technology_costs[static_cast<size_t>(technology)],
                        cost_factor, efficiency, domain_points);
                if (!step.valid || step.spend <= 0) break;
                set_progress(slot, technology, progress + step.progress_gain);
                domain_points -= step.spend;
                consumed += step.spend;
                _country_research_progress_total[static_cast<size_t>(slot)] +=
                    step.progress_gain;
                if (step.completed) {
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
                        ensure_technology_effect_instance(
                            slot, technology, day_index, *working_context);
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
        _research_allocation_ms += elapsed_ms(allocation_started);
        retain_if_active();
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
    if (changed > 0) {
        ++_research_generation;
        ++_generation;
    }
    if (out_peer_context != nullptr)
        *out_peer_context = std::move(working_peer_context);
    return changed;
}

bool NativeCountryRuntime::peer_protocol_self_test(std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF ||
        _command_batch.active || _boundary_seal_active ||
        !_pending_commands.empty()) {
        error = "country_peer_protocol_test_requires_idle_runtime";
        return false;
    }
    CountryPeerContext context;
    if (!capture_peer_context(
            std::max<int64_t>(0, _last_committed_day),
            _reference_continuation_index, context, error))
        return false;
    if (context.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        context.session_epoch != _session_epoch ||
        context.country_generation != _generation ||
        context.research_cost_factor.size() != _countries.active.size() ||
        context.research_efficiency.size() != _countries.active.size() * 4u) {
        error = "country_peer_protocol_test_context_shape";
        return false;
    }
    int32_t slot = -1;
    for (int32_t candidate = 0;
         candidate < static_cast<int32_t>(_countries.active.size());
         ++candidate) {
        if (_countries.active[static_cast<size_t>(candidate)] != 0) {
            slot = candidate;
            break;
        }
    }
    if (slot < 0) {
        error = "country_peer_protocol_test_country_missing";
        return false;
    }
    const int32_t technology = _technology_ids.empty() ? -1 : 0;
    if (technology < 0) {
        error = "country_peer_protocol_test_technology_missing";
        return false;
    }
    const CountryPeerIntent first = make_peer_intent(
        context, CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, context.day);
    const CountryPeerIntent second = make_peer_intent(
        context, CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, context.day);
    if (first.request_id == 0 || first.request_id != second.request_id ||
        first.idempotency_key != second.idempotency_key) {
        error = "country_peer_protocol_test_request_identity";
        return false;
    }
    CountryPeerIntent stale_session = first;
    ++stale_session.session_epoch;
    const CountryPeerResult stale_session_result = apply_peer_intent(
        context, stale_session);
    if (stale_session_result.code != CountryPeerResultCode::STALE ||
        std::string(stale_session_result.reason.data()) !=
            "country_peer_intent_identity_stale") {
        error = "country_peer_protocol_test_session_rejection";
        return false;
    }
    CountryPeerIntent stale_generation = first;
    ++stale_generation.peer_generation;
    const CountryPeerResult stale_generation_result = apply_peer_intent(
        context, stale_generation);
    if (stale_generation_result.code != CountryPeerResultCode::STALE ||
        std::string(stale_generation_result.reason.data()) !=
            "country_peer_intent_peer_generation_stale") {
        error = "country_peer_protocol_test_peer_generation_rejection";
        return false;
    }

    auto result_for = [](const CountryPeerIntent &intent,
                         CountryPeerResultCode code) {
        CountryPeerResult result;
        result.code = code;
        result.opcode = intent.opcode;
        result.request_id = intent.request_id;
        result.session_epoch = intent.session_epoch;
        result.country_generation = intent.country_generation;
        result.peer_generation = intent.peer_generation;
        result.day = intent.day;
        result.continuation_index = intent.continuation_index;
        result.country_slot = intent.country_slot;
        result.technology = intent.technology;
        result.target_handle = intent.target_handle;
        return result;
    };
    set_peer_async_mode(true);
    const auto async_failure = [&](const char *reason) {
        clear_peer_protocol_state();
        error = reason;
        return false;
    };
    CountryPeerContext async_context = context;
    const CountryPeerIntent queued_intent = make_peer_intent(
        async_context, CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, async_context.day);
    const CountryPeerResult queued_result = apply_peer_intent(
        async_context, queued_intent);
    if (queued_result.code != CountryPeerResultCode::PENDING ||
        pending_peer_intent_count() != 1)
        return async_failure("country_peer_protocol_test_async_queue");
    CountryPeerIntent polled_intent;
    if (!poll_peer_intent(polled_intent) ||
        polled_intent.request_id != queued_intent.request_id ||
        poll_peer_intent(polled_intent))
        return async_failure("country_peer_protocol_test_async_poll");

    CountryPeerResult unknown_result = result_for(
        queued_intent, CountryPeerResultCode::READY);
    unknown_result.request_id ^= 0x1ULL;
    if (unknown_result.request_id == 0) unknown_result.request_id = 1;
    std::string submit_error;
    if (submit_peer_result(unknown_result, submit_error) ||
        submit_error != "country_peer_result_request_unknown")
        return async_failure("country_peer_protocol_test_unknown_result");

    CountryPeerResult stale_result = result_for(
        queued_intent, CountryPeerResultCode::READY);
    ++stale_result.session_epoch;
    if (submit_peer_result(stale_result, submit_error) ||
        submit_error != "country_peer_result_identity_mismatch")
        return async_failure("country_peer_protocol_test_stale_result");
    stale_result = result_for(queued_intent, CountryPeerResultCode::READY);
    stale_result.peer_generation ^= 0x1ULL;
    if (submit_peer_result(stale_result, submit_error) ||
        submit_error != "country_peer_result_identity_mismatch")
        return async_failure("country_peer_protocol_test_stale_generation_result");

    CountryPeerResult acknowledged = result_for(
        queued_intent, CountryPeerResultCode::READY);
    acknowledged.committed_peer_generation = queued_intent.peer_generation == 0
        ? 0 : queued_intent.peer_generation + 1u;
    acknowledged.technology_flags = COUNTRY_PEER_EFFECT_EXISTS |
        COUNTRY_PEER_EFFECT_FIRE_ACKED;
    if (!submit_peer_result(acknowledged, submit_error) ||
        !submit_peer_result(acknowledged, submit_error) ||
        pending_peer_intent_count() != 0)
        return async_failure("country_peer_protocol_test_duplicate_ack");

    CountryPeerContext continuation_context = context;
    ++continuation_context.country_generation;
    const CountryPeerIntent replayed_intent = make_peer_intent(
        continuation_context,
        CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, continuation_context.day);
    const CountryPeerResult replayed_result = apply_peer_intent(
        continuation_context, replayed_intent);
    if (replayed_intent.request_id != queued_intent.request_id ||
        replayed_result.code != CountryPeerResultCode::READY ||
        !replayed_result.has(COUNTRY_PEER_EFFECT_FIRE_ACKED))
        return async_failure("country_peer_protocol_test_same_day_continuation");

    const CountryPeerIntent rejected_intent = make_peer_intent(
        async_context, CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE,
        slot, technology, async_context.day);
    if (apply_peer_intent(async_context, rejected_intent).code !=
            CountryPeerResultCode::PENDING ||
        !poll_peer_intent(polled_intent) ||
        polled_intent.request_id != rejected_intent.request_id)
        return async_failure("country_peer_protocol_test_rejection_queue");
    CountryPeerResult rejected = result_for(
        rejected_intent, CountryPeerResultCode::REJECTED);
    country_peer_copy_reason(rejected.reason, "peer_rejected_for_test");
    if (!submit_peer_result(rejected, submit_error) ||
        apply_peer_intent(async_context, rejected_intent).ok())
        return async_failure("country_peer_protocol_test_rejected_result");
    clear_peer_protocol_state();
    return true;
}

int64_t NativeCountryRuntime::debit_country_cash(
        int64_t country_handle, int64_t requested, const char *trace_stage) {
    int32_t slot = -1;
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t moved = std::min(requested, _countries.cash[static_cast<size_t>(slot)]);
    _countries.cash[static_cast<size_t>(slot)] -= moved;
    if (moved > 0) {
        ++_countries.state_version[static_cast<size_t>(slot)];
        ++_generation;
        _state_hash_cache_valid = false;
        record_direct_reference_frame(trace_stage);
    }
    return moved;
}

int64_t NativeCountryRuntime::transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested) {
    return economy_transfer_cash_to_cohort(country_handle, requested, -1, -1);
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
    return economy_spend_treasury_assets(country_handle, good_ids, quantities,
        good_count, cash, -1, -1);
}

int64_t NativeCountryRuntime::credit_country_cash(
        int64_t country_handle, int64_t offered, const char *trace_stage) {
    int32_t slot = -1;
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t room = std::numeric_limits<int64_t>::max() - _countries.cash[static_cast<size_t>(slot)];
    const int64_t moved = std::min(offered, room);
    _countries.cash[static_cast<size_t>(slot)] += moved;
    if (moved > 0) {
        ++_countries.state_version[static_cast<size_t>(slot)];
        ++_generation;
        _state_hash_cache_valid = false;
        record_direct_reference_frame(trace_stage);
    }
    return moved;
}

int64_t NativeCountryRuntime::economy_transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_cash_to_cohort(
        country_handle, requested, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_cash_from_cohort(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_transfer_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_good_to_market(
        country_handle, good_id, requested, origin_epoch, origin_stage,
        request_id));
}

int64_t NativeCountryRuntime::economy_transfer_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_good_from_market(
        country_handle, good_id, offered, origin_epoch, origin_stage,
        request_id));
}

bool NativeCountryRuntime::economy_spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    PackedInt32Array ids;
    PackedInt64Array amounts;
    ids.resize(static_cast<int64_t>(good_count));
    amounts.resize(static_cast<int64_t>(good_count));
    for (size_t i = 0; i < good_count; ++i) {
        ids.set(static_cast<int64_t>(i), good_ids == nullptr ? -1 : good_ids[i]);
        amounts.set(static_cast<int64_t>(i),
            quantities == nullptr ? -1 : quantities[i]);
    }
    Dictionary begin = begin_economy_treasury_spend(
        country_handle, ids, amounts, cash, origin_epoch, origin_stage,
        request_id);
    if (!static_cast<bool>(begin.get("ok", false))) return false;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed";
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    const uint64_t peer_generation = transaction_id;
    Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return false;
    Dictionary committed = commit_economy_treasury_spend(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return false;
    Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
}

int64_t NativeCountryRuntime::transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered) {
    return economy_transfer_cash_from_cohort(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::reserve_fiscal_cash(int64_t country_handle,
                                                   int64_t requested) {
    return economy_reserve_fiscal_cash(country_handle, requested, -1, -1);
}

int64_t NativeCountryRuntime::return_fiscal_cash(int64_t country_handle,
                                                  int64_t offered) {
    return economy_return_fiscal_cash(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::collect_fiscal_cash(int64_t country_handle,
                                                   int64_t offered) {
    return economy_collect_fiscal_cash(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                                       int64_t requested) {
    return economy_transfer_good_to_market(country_handle, good_id, requested,
        -1, -1);
}

int64_t NativeCountryRuntime::transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                                         int64_t offered) {
    return economy_transfer_good_from_market(country_handle, good_id, offered,
        -1, -1);
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
                           const std::vector<int32_t> &overrides,
                           const std::vector<int32_t> &mode_overrides,
                           std::vector<int32_t> &rates,
                           std::vector<int32_t> &modes) {
        const int32_t item_count = tax_item_count(kind);
        rates.resize(static_cast<size_t>(out.country_count) * item_count);
        modes.resize(static_cast<size_t>(out.country_count) * item_count);
        for (int32_t slot = 0; slot < out.country_count; ++slot) {
            for (int32_t item = 0; item < item_count; ++item) {
                const size_t index =
                    static_cast<size_t>(slot) * item_count + item;
                rates[index] = resolved_tax_rate(
                    _country_tax_defaults, overrides, slot, kind, item,
                    item_count);
                modes[index] = resolved_tax_mode(
                    _country_tax_default_modes, mode_overrides, slot, kind,
                    item, item_count);
            }
        }
    };
    resolve_all(TAX_INCOME, _country_income_tax_overrides,
                _country_income_tax_mode_overrides, out.income_tax_rates,
                out.income_tax_modes);
    resolve_all(TAX_CONSUMPTION, _country_consumption_tax_overrides,
                _country_consumption_tax_mode_overrides,
                out.consumption_tax_rates, out.consumption_tax_modes);
    resolve_all(TAX_BUSINESS, _country_business_tax_overrides,
                _country_business_tax_mode_overrides, out.business_tax_rates,
                out.business_tax_modes);
    resolve_all(TAX_IMPORT, _country_import_tax_overrides,
                _country_import_tax_mode_overrides, out.import_tax_rates,
                out.import_tax_modes);
    resolve_all(TAX_EXPORT, _country_export_tax_overrides,
                _country_export_tax_mode_overrides, out.export_tax_rates,
                out.export_tax_modes);
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
                   _country_tax_defaults.size() * sizeof(int32_t));
    if (!_country_tax_default_modes.empty())
        hash_bytes(hash, _country_tax_default_modes.data(),
                   _country_tax_default_modes.size() * sizeof(int32_t));
    if (!_country_income_tax_overrides.empty())
        hash_bytes(hash, _country_income_tax_overrides.data(),
                   _country_income_tax_overrides.size() * sizeof(int32_t));
    if (!_country_income_tax_mode_overrides.empty())
        hash_bytes(hash, _country_income_tax_mode_overrides.data(),
                   _country_income_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_consumption_tax_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_overrides.data(),
                   _country_consumption_tax_overrides.size() * sizeof(int32_t));
    if (!_country_consumption_tax_mode_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_mode_overrides.data(),
                   _country_consumption_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_business_tax_overrides.empty())
        hash_bytes(hash, _country_business_tax_overrides.data(),
                   _country_business_tax_overrides.size() * sizeof(int32_t));
    if (!_country_business_tax_mode_overrides.empty())
        hash_bytes(hash, _country_business_tax_mode_overrides.data(),
                   _country_business_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_import_tax_overrides.empty())
        hash_bytes(hash, _country_import_tax_overrides.data(),
                   _country_import_tax_overrides.size() * sizeof(int32_t));
    if (!_country_import_tax_mode_overrides.empty())
        hash_bytes(hash, _country_import_tax_mode_overrides.data(),
                   _country_import_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_export_tax_overrides.empty())
        hash_bytes(hash, _country_export_tax_overrides.data(),
                   _country_export_tax_overrides.size() * sizeof(int32_t));
    if (!_country_export_tax_mode_overrides.empty())
        hash_bytes(hash, _country_export_tax_mode_overrides.data(),
                   _country_export_tax_mode_overrides.size() *
                       sizeof(int32_t));
    uint64_t cell_policy_count = 0;
    for (uint32_t id : _cell_tax_policy_ids)
        if (!cell_tax_policy(id).empty()) ++cell_policy_count;
    hash_bytes(hash, &cell_policy_count, sizeof(cell_policy_count));
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const CellTaxPolicy &policy = cell_tax_policy(
            _cell_tax_policy_ids[static_cast<size_t>(cell)]);
        if (policy.empty()) continue;
        hash_bytes(hash, &cell, sizeof(cell));
        hash_bytes(hash, policy.defaults.data(),
                   policy.defaults.size() * sizeof(int32_t));
        hash_bytes(hash, policy.default_modes.data(),
                   policy.default_modes.size() * sizeof(int32_t));
        const uint64_t entry_count = policy.overrides.size();
        hash_bytes(hash, &entry_count, sizeof(entry_count));
        for (const CellTaxOverride &entry : policy.overrides) {
            hash_bytes(hash, &entry.kind, sizeof(entry.kind));
            hash_string(hash, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            hash_bytes(hash, &entry.rate, sizeof(entry.rate));
            hash_bytes(hash, &entry.mode, sizeof(entry.mode));
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
    const bool changed = _era_reward_reference.plan_id != plan_id ||
        _era_reward_reference.offer_generation != offer_generation ||
        _era_reward_reference.milestone_technology != milestone_technology ||
        _era_reward_reference.status != status;
    _era_reward_reference.plan_id = plan_id;
    _era_reward_reference.offer_generation = offer_generation;
    _era_reward_reference.milestone_technology = milestone_technology;
    _era_reward_reference.status = status;
    _state_hash_cache_valid = false;
    if (changed) record_direct_reference_frame("era_reward_reference");
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
    if (_command_batch.active || _boundary_seal_active) {
        error = "country_save_requires_idle_command_graph";
        return false;
    }
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
    append_vector(out, _country_tax_default_modes);
    append_vector(out, _country_income_tax_mode_overrides);
    append_vector(out, _country_consumption_tax_mode_overrides);
    append_vector(out, _country_business_tax_mode_overrides);
    append_vector(out, _country_import_tax_mode_overrides);
    append_vector(out, _country_export_tax_mode_overrides);
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
        for (int32_t rate : policy.defaults) append_le<int32_t>(out, rate);
        for (int32_t mode : policy.default_modes) append_le<int32_t>(out, mode);
        append_le<uint64_t>(out,
            static_cast<uint64_t>(policy.overrides.size()));
        for (const CellTaxOverride &entry : policy.overrides) {
            append_le<int32_t>(out, entry.kind);
            append_string(out, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            append_le<int32_t>(out, entry.rate);
            append_le<int32_t>(out, entry.mode);
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
        append_le<int32_t>(out, command.tax_rate_basis_points);
        append_le<int32_t>(out, command.tax_assessment_mode);
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
    NativeCountryRuntime staged(*this);
    std::unique_ptr<ModifierRuntime> staged_modifier;
    if (_modifier_runtime != nullptr) {
        staged_modifier = std::make_unique<ModifierRuntime>(*_modifier_runtime);
        staged_modifier->attach_country_runtime(&staged);
        staged_modifier->attach_economy_runtime(_economy_runtime);
        staged._modifier_runtime = staged_modifier.get();
    }
    if (!staged.decode_save_in_place(bytes, error)) return false;

    ModifierRuntime *live_modifier = _modifier_runtime;
    NativeEconomyRuntime *live_economy = _economy_runtime;
    EffectRuntime *live_effect = _effect_runtime;
    *this = std::move(staged);
    _modifier_runtime = live_modifier;
    _economy_runtime = live_economy;
    _effect_runtime = live_effect;
    if (live_modifier != nullptr) {
        *live_modifier = std::move(*staged_modifier);
        live_modifier->attach_country_runtime(this);
        live_modifier->attach_economy_runtime(live_economy);
    }
    return true;
}

bool NativeCountryRuntime::decode_save_in_place(
        const std::vector<uint8_t> &bytes, std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, end = 0;
    uint64_t saved_catalog = 0, generation_value = 0, saved_submit_order = 0;
    int64_t committed_day = -1;
    int32_t cell_count = 0, country_count = 0, good_count_value = 0;
    int32_t profession_count = 0, building_count = 0;
    int32_t tech_count = 0, tech_words = 0, signal_count = 0, signal_words = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version)) { error = "country_save_truncated"; return false; }
    if (magic != SAVE_MAGIC) { error = "country_save_magic_invalid"; return false; }
    if (version != SCHEMA_VERSION && version != 12 && version != 11) {
        error = "catalog_hash_mismatch";
        return false;
    }
    const bool legacy_percent_tax_rates = version == 11;
    const bool has_tax_assessment_modes = version >= 13;
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
                value > max_storable_research_progress(tech)) {
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
    std::vector<int32_t> tax_defaults(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT, 0);
    std::vector<int32_t> income_tax(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> consumption_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> business_tax(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> import_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> export_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> tax_default_modes(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT,
        TAX_MODE_PERCENT_BP);
    std::vector<int32_t> income_tax_modes(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> consumption_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> business_tax_modes(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> import_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> export_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    uint64_t tax_policy_version = 0;
    {
        bool read_ok = false;
        if (legacy_percent_tax_rates) {
            std::vector<int8_t> old_defaults, old_income, old_consumption;
            std::vector<int8_t> old_business, old_import, old_export;
            read_ok = read_vector(bytes, cursor, old_defaults,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) &&
                read_vector(bytes, cursor, old_income,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) &&
                read_vector(bytes, cursor, old_consumption,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, old_business,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) &&
                read_vector(bytes, cursor, old_import,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, old_export,
                    static_cast<uint64_t>(country_count) * _good_ids.size());
            const auto migrate = [](const std::vector<int8_t> &source,
                                    std::vector<int32_t> &target,
                                    bool allow_inherit) {
                target.resize(source.size());
                for (size_t i = 0; i < source.size(); ++i) {
                    target[i] = allow_inherit && source[i] == 127
                        ? TAX_RATE_INHERIT
                        : static_cast<int32_t>(source[i]) * 100;
                }
            };
            if (read_ok) {
                migrate(old_defaults, tax_defaults, false);
                migrate(old_income, income_tax, true);
                migrate(old_consumption, consumption_tax, true);
                migrate(old_business, business_tax, true);
                migrate(old_import, import_tax, true);
                migrate(old_export, export_tax, true);
            }
        } else {
            read_ok = read_vector(bytes, cursor, tax_defaults,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) &&
                read_vector(bytes, cursor, income_tax,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) &&
                read_vector(bytes, cursor, consumption_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, business_tax,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) &&
                read_vector(bytes, cursor, import_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, export_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size());
        }
        if (!read_ok ||
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
        if (has_tax_assessment_modes) {
            if (!read_vector(bytes, cursor, tax_default_modes,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) ||
                !read_vector(bytes, cursor, income_tax_modes,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) ||
                !read_vector(bytes, cursor, consumption_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                !read_vector(bytes, cursor, business_tax_modes,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) ||
                !read_vector(bytes, cursor, import_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                !read_vector(bytes, cursor, export_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                tax_default_modes.size() !=
                    static_cast<size_t>(country_count) * TAX_KIND_COUNT ||
                income_tax_modes.size() !=
                    static_cast<size_t>(country_count) *
                        _profession_ids.size() ||
                consumption_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size() ||
                business_tax_modes.size() !=
                    static_cast<size_t>(country_count) *
                        _building_type_ids.size() ||
                import_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size() ||
                export_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size()) {
                error = "country_save_tax_mode_shape_invalid";
                return false;
            }
        } else {
            tax_default_modes.assign(
                static_cast<size_t>(country_count) * TAX_KIND_COUNT,
                TAX_MODE_PERCENT_BP);
            income_tax_modes.assign(
                static_cast<size_t>(country_count) * _profession_ids.size(),
                TAX_MODE_INHERIT);
            consumption_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
            business_tax_modes.assign(
                static_cast<size_t>(country_count) *
                    _building_type_ids.size(),
                TAX_MODE_INHERIT);
            import_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
            export_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
        }
        if (!read_le(bytes, cursor, tax_policy_version)) {
            error = "country_save_tax_shape_invalid";
            return false;
        }
        for (size_t i = 0; i < tax_defaults.size(); ++i) {
            if (!tax_assessment_mode_valid(tax_default_modes[i]) ||
                !tax_value_valid(tax_default_modes[i], tax_defaults[i])) {
                error = "country_save_tax_rate_invalid";
                return false;
            }
        }
        const auto override_value_valid =
            [](int32_t mode, int32_t rate, int32_t default_mode) {
                if (rate == TAX_RATE_INHERIT) return mode == TAX_MODE_INHERIT;
                if (mode == TAX_MODE_INHERIT)
                    return tax_assessment_mode_valid(default_mode) &&
                           tax_value_valid(default_mode, rate);
                return tax_assessment_mode_valid(mode) &&
                       tax_value_valid(mode, rate);
            };
        const auto validate_overrides =
            [&](const std::vector<int32_t> &rates,
                const std::vector<int32_t> &modes, int32_t kind,
                int32_t item_count) {
                for (int32_t slot = 0; slot < country_count; ++slot) {
                    const int32_t default_mode = tax_default_modes[
                        static_cast<size_t>(slot) * TAX_KIND_COUNT + kind];
                    for (int32_t item = 0; item < item_count; ++item) {
                        const size_t index =
                            static_cast<size_t>(slot) * item_count + item;
                        if (!override_value_valid(modes[index], rates[index],
                                                  default_mode)) {
                            return false;
                        }
                    }
                }
                return true;
            };
        if (!validate_overrides(income_tax, income_tax_modes, TAX_INCOME,
                                static_cast<int32_t>(_profession_ids.size())) ||
            !validate_overrides(consumption_tax, consumption_tax_modes,
                                TAX_CONSUMPTION,
                                static_cast<int32_t>(_good_ids.size())) ||
            !validate_overrides(
                business_tax, business_tax_modes, TAX_BUSINESS,
                static_cast<int32_t>(_building_type_ids.size())) ||
            !validate_overrides(import_tax, import_tax_modes, TAX_IMPORT,
                                static_cast<int32_t>(_good_ids.size())) ||
            !validate_overrides(export_tax, export_tax_modes, TAX_EXPORT,
                                static_cast<int32_t>(_good_ids.size()))) {
            error = "country_save_tax_rate_invalid";
            return false;
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
        for (int32_t &rate : policy.defaults) {
            if (legacy_percent_tax_rates) {
                int8_t old_rate = 0;
                if (!read_le(bytes, cursor, old_rate)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
                rate = old_rate == 127 ? TAX_RATE_INHERIT
                                       : static_cast<int32_t>(old_rate) * 100;
            } else if (!read_le(bytes, cursor, rate)) {
                error = "country_save_cell_tax_default_invalid";
                return false;
            }
        }
        if (has_tax_assessment_modes) {
            for (int32_t &mode : policy.default_modes) {
                if (!read_le(bytes, cursor, mode)) {
                    error = "country_save_cell_tax_default_mode_invalid";
                    return false;
                }
            }
        } else {
            policy.default_modes.fill(TAX_MODE_INHERIT);
        }
        for (size_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
            const int32_t rate = policy.defaults[kind];
            const int32_t mode = policy.default_modes[kind];
            if (rate == TAX_RATE_INHERIT) {
                if (mode != TAX_MODE_INHERIT &&
                    !tax_assessment_mode_valid(mode)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
            } else if (mode == TAX_MODE_INHERIT) {
                // Value inherits country assessment mode at resolve time;
                // accept either absolute or percent bounds.
                if (!tax_value_valid(TAX_MODE_PERCENT_BP, rate) &&
                    !tax_value_valid(TAX_MODE_ABSOLUTE, rate)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
            } else if (!tax_assessment_mode_valid(mode) ||
                       !tax_value_valid(mode, rate)) {
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
                !read_string(bytes, cursor, item_id)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            if (legacy_percent_tax_rates) {
                int8_t old_rate = 0;
                if (!read_le(bytes, cursor, old_rate)) {
                    error = "country_save_cell_tax_entry_truncated";
                    return false;
                }
                entry.rate = static_cast<int32_t>(old_rate) * 100;
            } else if (!read_le(bytes, cursor, entry.rate)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            if (has_tax_assessment_modes) {
                if (!read_le(bytes, cursor, entry.mode)) {
                    error = "country_save_cell_tax_entry_truncated";
                    return false;
                }
            } else {
                entry.mode = TAX_MODE_INHERIT;
            }
            entry.item = tax_item_index(entry.kind, item_id);
            const bool mode_ok =
                entry.mode == TAX_MODE_INHERIT ||
                tax_assessment_mode_valid(entry.mode);
            const bool rate_ok =
                entry.mode == TAX_MODE_INHERIT
                    ? (tax_value_valid(TAX_MODE_PERCENT_BP, entry.rate) ||
                       tax_value_valid(TAX_MODE_ABSOLUTE, entry.rate))
                    : tax_value_valid(entry.mode, entry.rate);
            if (entry.kind < 0 || entry.kind >= TAX_KIND_COUNT ||
                entry.item < 0 || !mode_ok || !rate_ok ||
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
            !read_le(bytes, cursor, command.tax_rate_basis_points)) {
            error = "country_save_command_truncated";
            return false;
        }
        if (legacy_percent_tax_rates)
            command.tax_rate_basis_points *= 100;
        if (has_tax_assessment_modes) {
            if (!read_le(bytes, cursor, command.tax_assessment_mode)) {
                error = "country_save_command_truncated";
                return false;
            }
        } else {
            command.tax_assessment_mode = TAX_MODE_PERCENT_BP;
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
             (command.opcode != COMMAND_CLEAR_TAX_OVERRIDE &&
              (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
               !tax_value_valid(command.tax_assessment_mode,
                               command.tax_rate_basis_points))) ||
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
                (has_rate &&
                 (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
                  !tax_value_valid(command.tax_assessment_mode,
                                  command.tax_rate_basis_points)))) {
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
    _country_tax_default_modes = std::move(tax_default_modes);
    _country_income_tax_overrides = std::move(income_tax);
    _country_consumption_tax_overrides = std::move(consumption_tax);
    _country_business_tax_overrides = std::move(business_tax);
    _country_import_tax_overrides = std::move(import_tax);
    _country_export_tax_overrides = std::move(export_tax);
    _country_income_tax_mode_overrides = std::move(income_tax_modes);
    _country_consumption_tax_mode_overrides = std::move(consumption_tax_modes);
    _country_business_tax_mode_overrides = std::move(business_tax_modes);
    _country_import_tax_mode_overrides = std::move(import_tax_modes);
    _country_export_tax_mode_overrides = std::move(export_tax_modes);
    _cell_tax_policy_ids = std::move(cell_tax_policy_ids);
    _cell_tax_policies = std::move(cell_tax_policies);
    rebuild_cell_tax_policy_intern();
    _tax_policy_version = tax_policy_version;
    _last_research_day = last_research_day;
    _pending_commands = std::move(commands);
    clear_peer_protocol_state();
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
    _territory_generation = generation_value > 0 ? 1 : 0;
    _research_generation = generation_value > 0 ? 1 : 0;
    _last_committed_day = committed_day;
    _submit_order = std::max(saved_submit_order, max_submit_order);
    _bootstrapped = true;
    _events.clear();
    _next_event_id = 1;
    _typed_receipts.clear();
    _typed_request_state.clear();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
    _current_visual_era.resize(_countries.active.size(), -1);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot)
        _current_visual_era[static_cast<size_t>(slot)] =
            visual_era_index_for_slot(slot);
    _visual_era_dirty_slots.clear();
    _research_modifier_cache.clear();
    _research_modifier_cache.resize(_countries.active.size());
    rebuild_research_active_index();
    _state_hash_cache_valid = false;
    rebuild_cell_csr();
    publish_report("aggregate_publish", committed_day, 0, 0, 0, _cell_count, country_count, _mode == MODE_ACTIVE);
    return true;
}

Dictionary NativeCountryRuntime::begin_save(int32_t chunk_bytes) {
    if (_save_active) return fail("country_save_already_active");
    if (_simulation_host != nullptr &&
        _simulation_host->country_authority_handoff_prepare_pending()) {
        return fail("country_authority_handoff_pending");
    }
    if (!_economy_asset_transactions_in_flight.empty()) {
        Dictionary out = fail("country_save_economy_asset_transaction_pending");
        out["in_flight"] = static_cast<int64_t>(
            _economy_asset_transactions_in_flight.size());
        int64_t reserved_cash = 0;
        int64_t reserved_goods = 0;
        for (const int64_t value : _economy_asset_reserved_cash)
            if (value > 0 && reserved_cash <=
                    std::numeric_limits<int64_t>::max() - value)
                reserved_cash += value;
        for (const int64_t value : _economy_asset_reserved_goods)
            if (value > 0 && reserved_goods <=
                    std::numeric_limits<int64_t>::max() - value)
                reserved_goods += value;
        int64_t reserved_research_points = 0;
        for (const int64_t value : _economy_asset_reserved_research_points)
            if (value > 0 && reserved_research_points <=
                    std::numeric_limits<int64_t>::max() - value)
                reserved_research_points += value;
        out["reserved_cash"] = reserved_cash;
        out["reserved_goods"] = reserved_goods;
        out["reserved_research_points"] = reserved_research_points;
        return out;
    }
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
    begin_reference_boundary(_last_committed_day);
    record_reference_frame("restore", _last_committed_day, true, false);
    Dictionary out;
    out["ok"] = true;
    out["state_hash"] = state_hash();
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

} // namespace pk
