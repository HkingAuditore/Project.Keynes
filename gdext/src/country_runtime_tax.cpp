#include "country_runtime.h"
#include "country_runtime_internal.h"

#include <algorithm>
#include <limits>

namespace pk {

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


} // namespace pk
