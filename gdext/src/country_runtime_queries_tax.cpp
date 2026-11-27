#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_runtime_queries_peer_reads.inc"
#include "country_host_port.h"

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
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

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
                    modifier_api::stat_id_for_key(*_modifier_runtime, stat_key);
                if (stat_id >= 0) {
                    effective_value = static_cast<int32_t>(std::clamp<int64_t>(
                        std::lround(modifier_api::effective_value(*_modifier_runtime,
                            ModifierApi::COUNTRY, stat_id,
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
                    modifier_api::stat_id_for_key(*_modifier_runtime, stat_key);
                if (stat_id >= 0) {
                    effective_value = static_cast<int32_t>(
                        std::clamp<int64_t>(std::lround(
                            modifier_api::effective_value(*_modifier_runtime,
                                ModifierApi::COUNTRY, stat_id, handle,
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

} // namespace pk
