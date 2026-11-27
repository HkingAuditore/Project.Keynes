#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <numeric>
#include <unordered_set>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

bool NativeEconomyRuntime::compile_development_catalog(
        const Dictionary &catalog, std::string &error) {
    _development_metric_signal_indices = packed_i32(
        catalog, "development_metric_signal_indices");
    _development_metric_era_indices = packed_i32(
        catalog, "development_metric_era_indices");
    _development_metric_types = packed_i32(catalog, "development_metric_types");
    _development_metric_subject_kinds = packed_i32(
        catalog, "development_metric_subject_kinds");
    const std::vector<int32_t> authored_offsets = packed_i32(
        catalog, "development_metric_subject_offsets");
    const std::vector<std::string> authored_subject_ids = packed_strings(
        catalog, "development_metric_subject_ids");
    _development_metric_qualifier_thresholds = packed_i64(
        catalog, "development_metric_qualifier_thresholds");
    _development_metric_duration_days = packed_i32(
        catalog, "development_metric_duration_days");
    const size_t count = _development_metric_types.size();
    if (_development_metric_signal_indices.size() != count ||
        _development_metric_era_indices.size() != count ||
        _development_metric_subject_kinds.size() != count ||
        _development_metric_qualifier_thresholds.size() != count ||
        _development_metric_duration_days.size() != count ||
        authored_offsets.size() != count + 1 || authored_offsets.empty() ||
        authored_offsets.front() != 0 ||
        authored_offsets.back() != static_cast<int32_t>(authored_subject_ids.size())) {
        error = "development_metric_catalog_columns_invalid";
        return false;
    }
    _development_metric_subject_offsets.assign(1, 0);
    _development_metric_subject_indices.clear();
    for (size_t metric = 0; metric < count; ++metric) {
        const int32_t type = _development_metric_types[metric];
        const int32_t kind = _development_metric_subject_kinds[metric];
        if (type <= 0 || type > 14 || kind < 0 || kind > 4 ||
            _development_metric_era_indices[metric] < 0 ||
            _development_metric_era_indices[metric] >= 11 ||
            _development_metric_qualifier_thresholds[metric] < 0 ||
            _development_metric_duration_days[metric] <= 0) {
            error = "development_metric_definition_invalid";
            return false;
        }
        for (int32_t cursor = authored_offsets[metric];
             cursor < authored_offsets[metric + 1]; ++cursor) {
            const std::string &subject = authored_subject_ids[static_cast<size_t>(cursor)];
            int32_t resolved = -1;
            if (kind == 1) { // economic sector
                static const char *SECTORS[] = {
                    "agriculture", "extractive", "manufacturing", "energy", "knowledge"};
                for (int32_t i = 0; i < 5; ++i)
                    if (subject == SECTORS[i]) resolved = i;
            } else if (kind == 2) {
                const auto it = std::find(_building_type_ids.begin(),
                                          _building_type_ids.end(), subject);
                if (it != _building_type_ids.end())
                    resolved = static_cast<int32_t>(it - _building_type_ids.begin());
            } else if (kind == 3) {
                const auto it = std::find(_building_upgrade_family_ids.begin(),
                                          _building_upgrade_family_ids.end(), subject);
                if (it != _building_upgrade_family_ids.end())
                    resolved = static_cast<int32_t>(it - _building_upgrade_family_ids.begin());
            } else if (kind == 4) {
                const auto it = std::find(_good_ids.begin(), _good_ids.end(), subject);
                if (it != _good_ids.end())
                    resolved = static_cast<int32_t>(it - _good_ids.begin());
            } else {
                // Settlement count uses a numeric tier as its subject.
                try { resolved = std::stoi(subject); } catch (...) { resolved = -1; }
            }
            if (resolved < 0) {
                error = "development_metric_subject_unknown:" + subject;
                return false;
            }
            _development_metric_subject_indices.push_back(resolved);
        }
        _development_metric_subject_offsets.push_back(
            static_cast<int32_t>(_development_metric_subject_indices.size()));
    }
    return true;
}
bool NativeEconomyRuntime::compile_family_catalog(
        const Dictionary &catalog, std::string &error) {
    _family_surname_pack_id = dict_string(
        catalog, "family_surname_pack_id", "default_zh");
    _family_surname_ids = packed_strings(catalog, "family_surname_ids");
    _family_surname_text = packed_strings(catalog, "family_surname_text");
    _family_surname_weights = packed_i32(catalog, "family_surname_weights");
    _family_culture_group_ids = packed_strings(catalog, "family_culture_group_ids");
    _family_culture_group_display_names = packed_strings(catalog, "family_culture_group_display_names");
    _family_culture_group_naming_formats = packed_strings(catalog, "family_culture_group_naming_formats");
    _family_culture_group_separators = packed_strings(catalog, "family_culture_group_separators");
    _family_culture_group_suffixes = packed_strings(catalog, "family_culture_group_suffixes");
    _family_surname_culture_group_ids = packed_i32(catalog, "family_surname_culture_group_ids");
    const std::vector<std::string> ethnicity_culture_group_keys =
        packed_strings(catalog, "ethnicity_culture_group_ids");
    _ethnicity_culture_group_ids.assign(_ethnicity_ids.size(), -1);
    if (ethnicity_culture_group_keys.size() != _ethnicity_ids.size()) {
        error = "ethnicity_culture_group_columns_mismatch";
        return false;
    }
    for (size_t i = 0; i < ethnicity_culture_group_keys.size(); ++i) {
        const auto it = std::lower_bound(_family_culture_group_ids.begin(),
            _family_culture_group_ids.end(), ethnicity_culture_group_keys[i]);
        if (it == _family_culture_group_ids.end() || *it != ethnicity_culture_group_keys[i]) {
            error = "ethnicity_culture_group_unknown";
            return false;
        }
        _ethnicity_culture_group_ids[i] = static_cast<int32_t>(
            it - _family_culture_group_ids.begin());
    }
    _family_catalog_hash = dict_num<int64_t>(catalog, "family_catalog_hash", 0);
    _family_catalog_compat_hash_v39 = dict_num<int64_t>(
        catalog, "family_catalog_compat_hash_v39", 0);
    if (_family_surname_ids.empty() || _family_culture_group_ids.empty() ||
        _family_surname_ids.size() != _family_surname_text.size() ||
        _family_surname_ids.size() != _family_surname_weights.size() ||
        _family_surname_ids.size() != _family_surname_culture_group_ids.size() ||
        _family_culture_group_ids.size() != _family_culture_group_display_names.size() ||
        _family_culture_group_ids.size() != _family_culture_group_naming_formats.size() ||
        _family_culture_group_ids.size() != _family_culture_group_separators.size() ||
        _family_culture_group_ids.size() != _family_culture_group_suffixes.size() ||
        _family_catalog_hash.get() == 0) {
        error = "family_surname_catalog_invalid";
        return false;
    }
    for (size_t i = 0; i < _family_culture_group_ids.size(); ++i) {
        if (_family_culture_group_ids[i].empty() ||
            (i > 0 && _family_culture_group_ids[i - 1] >= _family_culture_group_ids[i]) ||
            _family_culture_group_naming_formats[i] != "CITY_SURNAME_SUFFIX" &&
            _family_culture_group_naming_formats[i] != "CITY_SEPARATOR_SURNAME" &&
            _family_culture_group_naming_formats[i] != "CITY_SURNAME") {
            error = "family_culture_group_catalog_invalid";
            return false;
        }
    }
    int64_t weight_sum = 0;
    for (size_t i = 0; i < _family_surname_ids.size(); ++i) {
        if (_family_surname_ids[i].empty() || _family_surname_text[i].empty() ||
            _family_surname_weights[i] <= 0 ||
            (i > 0 && std::tie(_family_surname_culture_group_ids[i - 1],
                _family_surname_ids[i - 1]) >= std::tie(
                _family_surname_culture_group_ids[i], _family_surname_ids[i]))) {
            error = "family_surname_catalog_not_sorted_unique";
            return false;
        }
        weight_sum += _family_surname_weights[i];
        if (_family_surname_culture_group_ids[i] < 0 ||
            _family_surname_culture_group_ids[i] >=
                static_cast<int32_t>(_family_culture_group_ids.size())) {
            error = "family_surname_culture_group_invalid";
            return false;
        }
    }
    if (weight_sum <= 0) {
        error = "family_surname_weight_sum_invalid";
        return false;
    }
    return compile_family_trait_catalog(catalog, error);
}
bool NativeEconomyRuntime::compile_person_catalog(
        const Dictionary &catalog, std::string &error) {
    _person_given_name_pack_id = dict_string(
        catalog, "person_given_name_pack_id", "default_zh");
    _person_given_name_ids = packed_strings(catalog, "person_given_name_ids");
    _person_given_name_text = packed_strings(catalog, "person_given_name_text");
    _person_given_name_weights = packed_i32(catalog, "person_given_name_weights");
    _person_catalog_hash = dict_num<int64_t>(catalog, "person_catalog_hash", 0);
    if (_person_given_name_ids.empty() ||
        _person_given_name_ids.size() != _person_given_name_text.size() ||
        _person_given_name_ids.size() != _person_given_name_weights.size() ||
        _person_catalog_hash.get() == 0) {
        error = "person_given_name_catalog_invalid";
        return false;
    }
    int64_t weight_sum = 0;
    for (size_t i = 0; i < _person_given_name_ids.size(); ++i) {
        if (_person_given_name_ids[i].empty() ||
            _person_given_name_text[i].empty() ||
            _person_given_name_weights[i] <= 0 ||
            (i > 0 && _person_given_name_ids[i - 1] >=
                _person_given_name_ids[i])) {
            error = "person_given_name_catalog_not_sorted_unique";
            return false;
        }
        weight_sum += _person_given_name_weights[i];
    }
    if (weight_sum <= 0) {
        error = "person_given_name_weight_sum_invalid";
        return false;
    }
    return true;
}
bool NativeEconomyRuntime::compile_settlement_catalog(
        const Dictionary &catalog, std::string &error) {
    _prosperity_thresholds = packed_i64(catalog, "prosperity_thresholds");
    _prosperity_ids = packed_strings(catalog, "prosperity_ids");
    _prosperity_names = packed_strings(catalog, "prosperity_names");
    _settlement_full_name_ids = packed_strings(
        catalog, "settlement_full_name_ids");
    _settlement_full_name_text = packed_strings(
        catalog, "settlement_full_name_text");
    _settlement_full_name_weights = packed_i32(
        catalog, "settlement_full_name_weights");
    _settlement_full_name_alias_ids = packed_strings(
        catalog, "settlement_full_name_alias_ids");
    _settlement_full_name_alias_targets = packed_strings(
        catalog, "settlement_full_name_alias_targets");
    _settlement_full_name_share_q16 = dict_num<int32_t>(
        catalog, "settlement_full_name_share_q16", 32768);
    _settlement_prefix_ids = packed_strings(catalog, "settlement_prefix_ids");
    _settlement_prefix_text = packed_strings(catalog, "settlement_prefix_text");
    _settlement_prefix_weights = packed_i32(catalog, "settlement_prefix_weights");
    _settlement_prefix_alias_ids = packed_strings(
        catalog, "settlement_prefix_alias_ids");
    _settlement_prefix_alias_targets = packed_strings(
        catalog, "settlement_prefix_alias_targets");
    _settlement_root_ids = packed_strings(catalog, "settlement_root_ids");
    _settlement_root_text = packed_strings(catalog, "settlement_root_text");
    _settlement_root_weights = packed_i32(catalog, "settlement_root_weights");
    _settlement_root_alias_ids = packed_strings(
        catalog, "settlement_root_alias_ids");
    _settlement_root_alias_targets = packed_strings(
        catalog, "settlement_root_alias_targets");
    _settlement_suffix_ids = packed_strings(catalog, "settlement_suffix_ids");
    _settlement_suffix_text = packed_strings(catalog, "settlement_suffix_text");
    _settlement_suffix_weights = packed_i32(catalog, "settlement_suffix_weights");
    _settlement_suffix_alias_ids = packed_strings(
        catalog, "settlement_suffix_alias_ids");
    _settlement_suffix_alias_targets = packed_strings(
        catalog, "settlement_suffix_alias_targets");
    _settlement_name_pack_id = dict_string(
        catalog, "settlement_name_pack_id", "default_zh");
    _settlement_named_tier = dict_num<int32_t>(
        catalog, "settlement_named_tier", 2);
    _settlement_downgrade_bp = dict_num<int32_t>(
        catalog, "settlement_downgrade_bp", 9000);
    _prosperity_profile_hash = dict_num<int64_t>(
        catalog, "prosperity_profile_hash", 0);
    _settlement_catalog_hash = dict_num<int64_t>(
        catalog, "settlement_catalog_hash", 0);
    const size_t tiers = _prosperity_thresholds.size();
    if (tiers < 2 || tiers > 32 || _prosperity_ids.size() != tiers ||
        _prosperity_names.size() != tiers || _prosperity_thresholds[0] != 0 ||
        !std::is_sorted(_prosperity_thresholds.begin(),
                        _prosperity_thresholds.end()) ||
        std::adjacent_find(_prosperity_thresholds.begin(),
                           _prosperity_thresholds.end()) !=
            _prosperity_thresholds.end() ||
        _settlement_named_tier < 1 ||
        _settlement_named_tier >= static_cast<int32_t>(tiers) ||
        _settlement_downgrade_bp < 1 || _settlement_downgrade_bp > 10000 ||
        _settlement_full_name_share_q16 < 0 ||
        _settlement_full_name_share_q16 > 65536 ||
        _prosperity_profile_hash.get() == 0 || _settlement_catalog_hash == 0) {
        error = "settlement_profile_invalid";
        return false;
    }
    const auto valid_part = [](const std::vector<std::string> &ids,
                               const std::vector<std::string> &text,
                               const std::vector<int32_t> &weights) {
        return !ids.empty() && ids.size() == text.size() &&
            ids.size() == weights.size() &&
            std::all_of(weights.begin(), weights.end(),
                        [](int32_t value) { return value > 0; });
    };
    const bool has_full_names = !_settlement_full_name_ids.empty();
    const bool has_components = !_settlement_prefix_ids.empty();
    if ((!has_full_names && !has_components) ||
        (has_full_names && !valid_part(
            _settlement_full_name_ids, _settlement_full_name_text,
            _settlement_full_name_weights)) ||
        (has_components && (!valid_part(_settlement_prefix_ids, _settlement_prefix_text,
                    _settlement_prefix_weights) ||
        !valid_part(_settlement_root_ids, _settlement_root_text,
                    _settlement_root_weights) ||
        !valid_part(_settlement_suffix_ids, _settlement_suffix_text,
                    _settlement_suffix_weights)))) {
        error = "settlement_name_catalog_invalid";
        return false;
    }
    const auto valid_aliases = [](const std::vector<std::string> &aliases,
                                  const std::vector<std::string> &targets,
                                  const std::vector<std::string> &ids) {
        if (aliases.size() != targets.size()) return false;
        for (size_t i = 0; i < aliases.size(); ++i) {
            if (aliases[i].empty() ||
                std::find(ids.begin(), ids.end(), targets[i]) == ids.end())
                return false;
        }
        return true;
    };
    if ((has_full_names && !valid_aliases(
            _settlement_full_name_alias_ids,
            _settlement_full_name_alias_targets,
            _settlement_full_name_ids)) ||
        (has_components && (!valid_aliases(_settlement_prefix_alias_ids,
                       _settlement_prefix_alias_targets,
                       _settlement_prefix_ids) ||
        !valid_aliases(_settlement_root_alias_ids,
                       _settlement_root_alias_targets,
                       _settlement_root_ids) ||
        !valid_aliases(_settlement_suffix_alias_ids,
                       _settlement_suffix_alias_targets,
                       _settlement_suffix_ids)))) {
        error = "settlement_name_alias_invalid";
        return false;
    }
    const uint64_t component_combinations = has_components
        ? static_cast<uint64_t>(_settlement_prefix_ids.size()) *
        static_cast<uint64_t>(_settlement_root_ids.size()) *
        static_cast<uint64_t>(_settlement_suffix_ids.size()) : 0;
    const uint64_t combinations =
        static_cast<uint64_t>(_settlement_full_name_ids.size()) +
        component_combinations;
    if (combinations == 0 ||
        (has_components && component_combinations < 4096) ||
        combinations > 0x7fffffffULL) {
        error = "settlement_name_combination_count_invalid";
        return false;
    }
    return true;
}

} // namespace pk
