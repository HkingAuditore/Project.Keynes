#include "country_runtime.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
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

    std::string mode = dict_string(profile, "country_runtime_mode", "ACTIVE");
    RuntimeMode parsed_mode = MODE_ACTIVE;
    if (mode == "OFF") parsed_mode = MODE_OFF;
    else if (mode == "PROBE") parsed_mode = MODE_PROBE;
    else if (mode != "ACTIVE") return fail("country_runtime_mode_invalid");

    _good_ids = goods;
    _profession_ids = professions;
    _building_type_ids = building_types;
    _technology_ids = technologies;
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
    _technology_flags = packed_i32(catalog, "technology_flags");
    _technology_modifier_definition_keys =
        packed_strings(catalog, "technology_modifier_definition_keys");
    const size_t tech_count = _technology_ids.size();
    if (_technology_domains.size() != tech_count || _technology_costs.size() != tech_count ||
        _technology_prerequisite_offsets.size() != tech_count + 1 ||
        _technology_milestone_offsets.size() != tech_count + 1 ||
        _technology_milestone_required_counts.size() != tech_count ||
        _technology_flags.size() != tech_count ||
        _technology_modifier_definition_keys.size() != tech_count ||
        _technology_prerequisite_offsets.front() != 0 ||
        _technology_prerequisite_offsets.back() != static_cast<int32_t>(_technology_prerequisites.size()) ||
        _technology_milestone_offsets.front() != 0 ||
        _technology_milestone_offsets.back() != static_cast<int32_t>(_technology_milestone_candidates.size()))
        return fail("country_technology_metadata_invalid");
    for (size_t tech = 0; tech < tech_count; ++tech) {
        if (_technology_domains[tech] < 0 || _technology_domains[tech] >= 4 ||
            _technology_costs[tech] < 0 ||
            _technology_milestone_required_counts[tech] < 0)
            return fail("country_technology_metadata_invalid");
    }
    for (int32_t prerequisite : _technology_prerequisites)
        if (prerequisite < 0 || prerequisite >= static_cast<int32_t>(tech_count))
            return fail("country_technology_prerequisite_invalid");
    for (int32_t candidate : _technology_milestone_candidates)
        if (candidate < 0 || candidate >= static_cast<int32_t>(tech_count))
            return fail("country_technology_milestone_candidate_invalid");
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
    _country_tax_defaults.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _tax_policy_version = 0;
    _last_research_day = -1;
    _pending_commands.clear();
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

std::vector<uint8_t> packed_u8(const Dictionary &d, const char *key) {
    std::vector<uint8_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_BYTE_ARRAY) return out;
    const PackedByteArray src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size());
    return out;
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
    _last_research_day = -1;
    _pending_commands.clear();
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
            opcodes[i] > COMMAND_CLEAR_TAX_OVERRIDE)
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
        if (command.opcode >= COMMAND_SET_TAX_DEFAULT) {
            if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
                command.tax_rate_percent < -100 ||
                command.tax_rate_percent > 100 ||
                (command.opcode != COMMAND_SET_TAX_DEFAULT &&
                 (command.tax_item < 0 ||
                  command.tax_item >= tax_item_count(command.tax_kind)))) {
                return fail("country_tax_command_invalid");
            }
        }
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

bool NativeCountryRuntime::should_run(int64_t day_index) const {
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) return false;
    if (_command_batch.active) return true;
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    if (day_index > _last_research_day && _technology_points_good_id >= 0) {
        for (uint64_t word : _country_pending_technologies) if (word != 0) return true;
        for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
            const int64_t stock = _country_goods[
                slot * _good_ids.size() + static_cast<size_t>(_technology_points_good_id)];
            if (stock > _country_research_deferred_points[slot]) return true;
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
                _command_batch.stage_tax = true;
            } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
                _command_batch.stage_technologies = true;
                _command_batch.stage_research = true;
            } else if (command.opcode >= COMMAND_SET_RESEARCH_WEIGHTS &&
                       command.opcode <= COMMAND_REVEAL_ALL_TECHNOLOGIES) {
                _command_batch.stage_research = true;
                _command_batch.stage_technologies = true;
            } else if (command.opcode >= COMMAND_SET_TAX_DEFAULT) {
                _command_batch.stage_tax = true;
            }
            if (command.opcode != COMMAND_TRANSFER_TERRITORY || command.cell <= previous_cell) {
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
    const size_t cursor_limit = std::min(batch.commands.size(),
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
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY) {
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
            event.stable_id = command.stable_id;
            event.display_name = command.display_name;
            batch.events.push_back(std::move(event));
        }
    }
    batch.preflight_ms += elapsed_ms(start);

    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
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
    const bool stage_technologies = batch.stage_technologies;
    const bool stage_goods = batch.stage_goods;
    const bool stage_research = batch.stage_research;
    const bool stage_tax = batch.stage_tax;
    _command_batch = {};

    const Clock::time_point apply_start = Clock::now();
    _countries = std::move(staged_countries);
    if (stage_technologies) _country_technologies = std::move(staged_technologies);
    if (stage_goods) _country_goods = std::move(staged_goods);
    if (stage_research) {
        _country_discovered = std::move(staged_discovered);
        _country_pending_technologies = std::move(staged_pending);
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
    out["country_day_barrier"] = should_run(day);
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
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = _bootstrapped;
    _report["schema_version"] = SCHEMA_VERSION;
    _report["runtime_mode"] = _mode == MODE_ACTIVE ? "ACTIVE" : (_mode == MODE_PROBE ? "PROBE" : "OFF");
    _report["path"] = _mode == MODE_ACTIVE ? "native_active" : (_mode == MODE_PROBE ? "native_probe" : "off");
    _report["stage"] = stage;
    _report["day_index"] = day;
    _report["country_count"] = static_cast<int64_t>(_countries.active.size());
    _report["cell_count"] = _cell_count;
    _report["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    _report["cursor_start"] = 0;
    _report["cursor_end"] = changed_cells + changed_countries;
    _report["changed_cells"] = changed_cells;
    _report["changed_countries"] = changed_countries;
    _report["command_preflight_ms"] = preflight_ms;
    _report["command_apply_ms"] = apply_ms;
    _report["aggregate_publish_ms"] = publish_ms;
    _report["native_ms"] = preflight_ms + apply_ms + publish_ms;
    _report["generation"] = static_cast<int64_t>(_generation);
    _report["state_hash"] = state_hash();
    _report["published_to_slot"] = published;
    _report["done"] = true;
    _report["country_day_barrier"] = false;
    _report["last_committed_day"] = _last_committed_day;
    int64_t oldest_due = day;
    for (const Command &command : _pending_commands)
        oldest_due = std::min(oldest_due, command.effective_day);
    _report["pending_latency_days"] = _pending_commands.empty()
        ? 0 : std::max<int64_t>(0, day - oldest_due);
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
        _country_goods.size() * sizeof(int64_t));
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
    if (!reason.empty()) {
        _report["fallback_reason"] = reason.c_str();
        _report["fail_stage"] = stage;
    }
}

Dictionary NativeCountryRuntime::report() const { return _report.duplicate(); }

Dictionary NativeCountryRuntime::reset(const String &reason) {
    _bootstrapped = false;
    _countries = {};
    _cell_country_slot.assign(static_cast<size_t>(std::max(0, _cell_count)), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
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
    _last_research_day = -1;
    _pending_commands.clear();
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
    int32_t nonzero_goods = 0;
    for (size_t good = 0; good < _good_ids.size(); ++good)
        if (_country_goods[static_cast<size_t>(slot) * _good_ids.size() + good] != 0) ++nonzero_goods;
    int32_t technologies = 0;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech)) ++technologies;
    out["owned"] = true;
    out["country_handle"] = static_cast<int64_t>(make_handle(slot));
    out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
    out["country_name"] = String::utf8(_countries.display_name[static_cast<size_t>(slot)].c_str());
    out["territory_count"] = _countries.territory_count[static_cast<size_t>(slot)];
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["nonzero_good_count"] = nonzero_goods;
    out["technology_count"] = technologies;
    out["state_version"] = static_cast<int64_t>(_countries.state_version[static_cast<size_t>(slot)]);
    return out;
}

Dictionary NativeCountryRuntime::country_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray technology_ids;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech)) technology_ids.push_back(_technology_ids[static_cast<size_t>(tech)].c_str());
    PackedInt32Array cells;
    if (slot + 1 < static_cast<int32_t>(_country_cell_offsets.size())) {
        const int32_t begin = _country_cell_offsets[static_cast<size_t>(slot)];
        const int32_t end = _country_cell_offsets[static_cast<size_t>(slot + 1)];
        cells.resize(end - begin);
        if (end > begin) std::memcpy(cells.ptrw(), _country_cells.data() + begin, static_cast<size_t>(end - begin) * sizeof(int32_t));
    }
    Dictionary out = cell_summary(cells.is_empty() ? -1 : cells[0]);
    if (out.is_empty()) {
        out["ok"] = true;
        out["country_handle"] = handle;
        out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
        out["country_name"] = String::utf8(_countries.display_name[static_cast<size_t>(slot)].c_str());
    }
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
                0, _technology_costs[static_cast<size_t>(tech)] -
                progress_for(country_slot, tech));
        }
    }
    const int64_t stock = _country_goods[
        slot * _good_ids.size() + static_cast<size_t>(_technology_points_good_id)];
    remaining_points = std::max<int64_t>(0, remaining_points - stock);
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

bool NativeCountryRuntime::prerequisites_met(const std::vector<uint64_t> &completed,
                                              int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_ids.size())) return false;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const auto has = [&](int32_t tech) {
        return (completed[base + tech / 64] & (1ULL << (tech % 64))) != 0;
    };
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

bool NativeCountryRuntime::prerequisites_met(int32_t slot, int32_t technology) const {
    return prerequisites_met(_country_technologies, slot, technology);
}

void NativeCountryRuntime::refresh_discovery(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
        const uint64_t bit = 1ULL << (tech % 64);
        if ((_country_technologies[base + tech / 64] & bit) != 0) {
            _country_discovered[base + tech / 64] |= bit;
            continue;
        }
        const int32_t begin = _technology_prerequisite_offsets[static_cast<size_t>(tech)];
        const int32_t end = _technology_prerequisite_offsets[static_cast<size_t>(tech + 1)];
        const int32_t milestone_begin = _technology_milestone_offsets[static_cast<size_t>(tech)];
        const int32_t milestone_end = _technology_milestone_offsets[static_cast<size_t>(tech + 1)];
        bool reveal = false;
        if (milestone_end > milestone_begin) {
            for (int32_t edge = milestone_begin; edge < milestone_end && !reveal; ++edge) {
                const int32_t candidate = _technology_milestone_candidates[static_cast<size_t>(edge)];
                reveal = (_country_technologies[base + candidate / 64] &
                          (1ULL << (candidate % 64))) != 0;
            }
        } else {
            for (int32_t edge = begin; edge < end && !reveal; ++edge) {
                const int32_t prerequisite = _technology_prerequisites[static_cast<size_t>(edge)];
                reveal = (_country_technologies[base + prerequisite / 64] &
                          (1ULL << (prerequisite % 64))) != 0;
            }
        }
        if (reveal) _country_discovered[base + tech / 64] |= bit;
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

int32_t NativeCountryRuntime::run_research_day(int64_t day_index) {
    if (day_index <= _last_research_day || _technology_points_good_id < 0) return 0;
    int32_t changed = 0;
    for (int32_t slot = 0; slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        if (_countries.active[static_cast<size_t>(slot)] == 0) continue;
        const size_t word_base = static_cast<size_t>(slot) * _technology_words;
        bool activated = false;
        for (int32_t technology = 0;
             technology < static_cast<int32_t>(_technology_ids.size());
             ++technology) {
            const size_t word_index = word_base + technology / 64;
            const uint64_t bit = 1ULL << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) == 0) continue;
            bool modifier_ready = true;
            if (_modifier_runtime != nullptr && _modifier_runtime->configured() &&
                !_technology_modifier_definition_keys[static_cast<size_t>(technology)].empty()) {
                std::string modifier_error;
                modifier_ready = _modifier_runtime->apply_technology_effect(
                    make_handle(slot),
                    _technology_modifier_definition_keys[static_cast<size_t>(technology)],
                    technology, day_index, modifier_error);
            }
            if (!modifier_ready) continue;
            _country_technologies[word_index] |= bit;
            _country_pending_technologies[word_index] &= ~bit;
            activated = true;
        }
        if (activated) {
            refresh_discovery(slot);
            _country_research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++_countries.state_version[static_cast<size_t>(slot)];
            ++changed;
        }

        int64_t &stock = _country_goods[
            static_cast<size_t>(slot) * _good_ids.size() +
            static_cast<size_t>(_technology_points_good_id)];
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
            while (domain_points > 0) {
                const size_t length_index = static_cast<size_t>(slot) * 4U +
                    static_cast<size_t>(domain);
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
                double cost_factor = 1.0;
                double efficiency = 1.0;
                if (_modifier_runtime != nullptr && _modifier_runtime->configured()) {
                    cost_factor = _modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY, "country.research.cost_factor",
                        make_handle(slot), 0, 1.0);
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
                const int64_t effective_cost = std::max<int64_t>(
                    1, static_cast<int64_t>(std::llround(
                        static_cast<double>(_technology_costs[
                            static_cast<size_t>(technology)]) * cost_factor)));
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
                    ++_country_research_completed_total[static_cast<size_t>(slot)];
                    for (int32_t i = 1; i < length; ++i)
                        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
                            _country_research_queues[queue_base + static_cast<size_t>(i)];
                    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                } else {
                    break;
                }
            }
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
    _last_research_day = day_index;
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
    out.tax_policy_version = _tax_policy_version;
    out.generation = _generation;
    out.state_hash = compute_state_hash();
    return true;
}

uint64_t NativeCountryRuntime::catalog_hash() const {
    uint64_t hash = FNV_OFFSET;
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _profession_ids) hash_string(hash, id);
    for (const std::string &id : _building_type_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
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
    hash_bytes(hash, &_tax_policy_version, sizeof(_tax_policy_version));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    return hash;
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

int64_t NativeCountryRuntime::state_hash() const { return static_cast<int64_t>(compute_state_hash()); }

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
    PackedInt32Array opcodes, cells, old_slots, new_slots, technologies;
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
    out["stable_ids"] = stable_ids;
    out["display_names"] = display_names;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

bool NativeCountryRuntime::encode_save(std::vector<uint8_t> &out, std::string &error) const {
    if (!_bootstrapped) { error = "country_save_not_bootstrapped"; return false; }
    if (_command_batch.active) { error = "country_save_requires_idle_command_graph"; return false; }
    if (should_run(_last_committed_day)) { error = "country_save_requires_idle_command_graph"; return false; }
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
    for (const std::string &id : _good_ids) append_string(out, id);
    for (const std::string &id : _profession_ids) append_string(out, id);
    for (const std::string &id : _building_type_ids) append_string(out, id);
    for (const std::string &id : _technology_ids) append_string(out, id);
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
    }
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
    int32_t tech_count = 0, tech_words = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version)) { error = "country_save_truncated"; return false; }
    if (magic != SAVE_MAGIC) { error = "country_save_magic_invalid"; return false; }
    if (version != 3 && version != SCHEMA_VERSION) {
        error = "legacy_technology_tree_save_unsupported";
        return false;
    }
    if (!read_le(bytes, cursor, saved_catalog) || !read_le(bytes, cursor, generation_value) ||
        !read_le(bytes, cursor, committed_day) || !read_le(bytes, cursor, saved_submit_order) ||
        !read_le(bytes, cursor, cell_count) ||
        !read_le(bytes, cursor, country_count) ||
        !read_le(bytes, cursor, good_count_value)) {
        error = "country_save_header_truncated"; return false;
    }
    if (version >= 4 &&
        (!read_le(bytes, cursor, profession_count) ||
         !read_le(bytes, cursor, building_count))) {
        error = "country_save_header_truncated";
        return false;
    }
    if (!read_le(bytes, cursor, tech_count) ||
        !read_le(bytes, cursor, tech_words)) {
        error = "country_save_header_truncated";
        return false;
    }
    const uint64_t expected_catalog =
        version == 3 ? catalog_hash_v3() : catalog_hash();
    if (saved_catalog != expected_catalog ||
        cell_count != _cell_count ||
        good_count_value != static_cast<int32_t>(_good_ids.size()) ||
        (version >= 4 &&
         (profession_count != static_cast<int32_t>(_profession_ids.size()) ||
          building_count !=
              static_cast<int32_t>(_building_type_ids.size()))) ||
        tech_count != static_cast<int32_t>(_technology_ids.size()) || tech_words != _technology_words ||
        country_count <= 0 || country_count > 1000000) { error = "country_save_catalog_or_shape_mismatch"; return false; }
    std::string id;
    for (const std::string &expected : _good_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "country_save_good_catalog_mismatch"; return false; }
    if (version >= 4) {
        for (const std::string &expected : _profession_ids)
            if (!read_string(bytes, cursor, id) || id != expected) {
                error = "country_save_profession_catalog_mismatch";
                return false;
            }
        for (const std::string &expected : _building_type_ids)
            if (!read_string(bytes, cursor, id) || id != expected) {
                error = "country_save_building_catalog_mismatch";
                return false;
            }
    }
    for (const std::string &expected : _technology_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "country_save_technology_catalog_mismatch"; return false; }

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
    std::vector<uint64_t> discovered, pending;
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
        !read_vector(bytes, cursor, research_queues, countries_u64 * 32U) ||
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
    if (version >= 4) {
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
        if (version >= 4 &&
            (!read_le(bytes, cursor, command.tax_kind) ||
             !read_le(bytes, cursor, command.tax_item) ||
             !read_le(bytes, cursor, command.tax_rate_percent))) {
            error = "country_save_command_truncated";
            return false;
        }
        if (!read_le(bytes, cursor, command.value) ||
            !read_string(bytes, cursor, command.stable_id) || !read_string(bytes, cursor, command.display_name) ||
            !read_le(bytes, cursor, command.submit_order)) { error = "country_save_command_truncated"; return false; }
        if (command.opcode < COMMAND_CREATE_COUNTRY ||
            command.opcode >
                (version >= 4 ? COMMAND_CLEAR_TAX_OVERRIDE
                              : COMMAND_REVEAL_ALL_TECHNOLOGIES) ||
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
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY) {
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
        if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
            (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
             command.tax_rate_percent < -100 ||
             command.tax_rate_percent > 100 ||
             (command.opcode != COMMAND_SET_TAX_DEFAULT &&
              (command.tax_item < 0 ||
               command.tax_item >= tax_item_count(command.tax_kind))))) {
            error = "country_save_tax_command_invalid";
            return false;
        }
        commands.push_back(std::move(command));
        max_submit_order = std::max(max_submit_order, commands.back().submit_order);
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
    _tax_policy_version = tax_policy_version;
    _last_research_day = last_research_day;
    _pending_commands = std::move(commands);
    _generation = generation_value;
    _last_committed_day = committed_day;
    _submit_order = std::max(saved_submit_order, max_submit_order);
    _bootstrapped = true;
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
