#include "economy_runtime.h"

#include <algorithm>

namespace pk {

void NativeEconomyRuntime::append_epoch_input_report(godot::Dictionary &out) const {
    out["catalog_hash"] = _catalog_hash.get();
    out["building_upgrade_catalog_builds"] = static_cast<int64_t>(
        _building_upgrade_catalog_builds);
    out["building_upgrade_catalog_rows"] = static_cast<int64_t>(
        _building_upgrade_catalog_rows);
    out["building_upgrade_catalog_bytes"] = static_cast<int64_t>(
        _building_upgrade_required_tiers.capacity() * sizeof(uint32_t));
    out["building_catalog_hash"] = _building_catalog_hash.get();
    out["environment_day"] = _environment_day.get();
    out["environment_hash"] = _environment_hash.get();
    out["country_generation"] = static_cast<int64_t>(_epoch_country_generation);
    out["country_state_hash"] = static_cast<int64_t>(_epoch_country_hash);
    out["country_availability_cache_hits"] = static_cast<int64_t>(
        _country_availability_cache.hits.load(std::memory_order_relaxed));
    out["country_availability_cache_rebuilds"] = static_cast<int64_t>(
        _country_availability_cache.rebuilds.load(std::memory_order_relaxed));
    out["country_territory_cache_hits"] = static_cast<int64_t>(
        _country_territory_cache.hits.load(std::memory_order_relaxed));
    out["country_territory_cache_rebuilds"] = static_cast<int64_t>(
        _country_territory_cache.rebuilds.load(std::memory_order_relaxed));
    out["country_commands_due"] = _country_runtime != nullptr &&
        country_reads().should_run(_current_day.get());
}

void NativeEconomyRuntime::refresh_country_availability_cache() {
    auto &cache = _country_availability_cache;
    const int32_t countries = std::max(0, _epoch_country_count);
    const auto &handles = _epoch_country_handles.values();
    const size_t rows = static_cast<size_t>(countries);
    const bool shape_valid =
        _epoch_country_good_available.size() == rows * _good_ids.size() &&
        _epoch_country_market_available.size() == rows * _good_ids.size() &&
        _epoch_country_profession_available.size() == rows * _profession_ids.size() &&
        _epoch_country_variant_available.size() == rows * _variants.size() &&
        _epoch_country_building_available.size() == rows * _building_types.size() &&
        _epoch_country_building_type_offsets.size() == rows + 1u &&
        _epoch_country_building_type_offsets.front() == 0 &&
        _epoch_country_building_type_offsets.back() ==
            static_cast<int32_t>(_epoch_country_building_type_indices.size());
    // Use a private copy of the actual input. The technology-metric test hook
    // can change the epoch bits before this capture, and its own source hash
    // describes a different derived result. Neither is a safe cache identity.
    if (cache.valid && shape_valid && cache.countries == countries &&
        cache.stride == _epoch_country_technology_words &&
        cache.handles == handles && cache.technologies == _epoch_country_technologies) {
        cache.hits.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    const auto requirements_available = [&](int32_t country, int32_t begin,
                                             int32_t end,
                                             const std::vector<int32_t> &requirements) {
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(requirements.size())) return false;
        if (begin == end) return true;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t technology_id = requirements[i];
            if (technology_id < 0 ||
                technology_id >= static_cast<int32_t>(_technology_ids.size()))
                return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            if (word_index < _epoch_country_technologies.size() &&
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) != 0) return true;
        }
        return false;
    };
    const auto all_requirements_available = [&](int32_t country, int32_t begin,
                                                 int32_t end,
                                                 const std::vector<int32_t> &requirements) {
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(requirements.size())) return false;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t technology_id = requirements[i];
            if (technology_id < 0 ||
                technology_id >= static_cast<int32_t>(_technology_ids.size())) return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            if (word_index >= _epoch_country_technologies.size() ||
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) == 0) return false;
        }
        return true;
    };
    const auto dependency_requirements_available = [&](int32_t country,
                                                        int32_t type_id) {
        if (type_id < 0 || type_id + 1 >= static_cast<int32_t>(
                _building_dependency_branch_offsets.size())) return false;
        const int32_t branch_begin = _building_dependency_branch_offsets[
            static_cast<size_t>(type_id)];
        const int32_t branch_end = _building_dependency_branch_offsets[
            static_cast<size_t>(type_id + 1)];
        auto has_technology = [&](int32_t technology_id) {
            if (technology_id < 0 || technology_id >= static_cast<int32_t>(
                    _technology_ids.size())) return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            return word_index < _epoch_country_technologies.size() &&
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) != 0;
        };
        for (int32_t branch = branch_begin; branch < branch_end; ++branch) {
            const int32_t tech_begin = _building_dependency_branch_technology_offsets[
                static_cast<size_t>(branch)];
            const int32_t tech_end = _building_dependency_branch_technology_offsets[
                static_cast<size_t>(branch + 1)];
            bool branch_ready = true;
            for (int32_t edge = tech_begin; edge < tech_end; ++edge) {
                if (!has_technology(_building_dependency_branch_technologies[
                        static_cast<size_t>(edge)])) {
                    branch_ready = false;
                    break;
                }
            }
            if (!branch_ready) continue;
            const int32_t group_begin = _building_dependency_branch_group_offsets[
                static_cast<size_t>(branch)];
            const int32_t group_end = _building_dependency_branch_group_offsets[
                static_cast<size_t>(branch + 1)];
            for (int32_t group = group_begin; group < group_end; ++group) {
                if (!building_dependency_group_required_for_operation(group))
                    continue;
                bool group_ready = false;
                for (int32_t tag = _building_dependency_tag_offsets[
                        static_cast<size_t>(group)];
                     tag < _building_dependency_tag_offsets[
                        static_cast<size_t>(group + 1)]; ++tag) {
                    if (has_technology(_building_dependency_tags[
                            static_cast<size_t>(tag)])) {
                        group_ready = true;
                        break;
                    }
                }
                if (!group_ready) {
                    branch_ready = false;
                    break;
                }
            }
            if (branch_ready) return true;
        }
        return false;
    };
    _epoch_country_good_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), 0);
    _epoch_country_market_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), 0);
    _epoch_country_profession_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _profession_ids.size(), 0);
    _epoch_country_variant_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _variants.size(), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t good = 0;
             good < static_cast<int32_t>(_good_ids.size()); ++good) {
            const bool available =
                good + 1 < static_cast<int32_t>(
                    _good_technology_offsets.size()) &&
                requirements_available(country,
                    _good_technology_offsets[good],
                    _good_technology_offsets[good + 1],
                    _good_required_technologies);
            _epoch_country_good_available[
                static_cast<size_t>(country) * _good_ids.size() + good] =
                    available ? 1 : 0;
            const bool market_available = available ||
                (good < static_cast<int32_t>(_good_trade_enabled.size()) &&
                 _good_trade_enabled[good] != 0 &&
                 good < static_cast<int32_t>(_good_storage_modes.size()) &&
                 _good_storage_modes[good] == 0);
            _epoch_country_market_available[
                static_cast<size_t>(country) * _good_ids.size() + good] =
                    market_available ? 1 : 0;
        }
        for (int32_t profession = 0;
             profession < static_cast<int32_t>(_profession_ids.size());
             ++profession) {
            const bool available =
                profession + 1 < static_cast<int32_t>(
                    _profession_technology_offsets.size()) &&
                requirements_available(country,
                    _profession_technology_offsets[profession],
                    _profession_technology_offsets[profession + 1],
                    _profession_required_technologies);
            _epoch_country_profession_available[
                static_cast<size_t>(country) * _profession_ids.size() +
                profession] = available ? 1 : 0;
        }
        for (int32_t variant = 0;
             variant < static_cast<int32_t>(_variants.size()); ++variant) {
            const VariantChoice &choice = _variants[variant];
            bool available = true;
            for (int32_t component = 0;
                 component < choice.component_count; ++component) {
                const int32_t good = _components[
                    choice.component_begin + component].good_id;
                const size_t good_index = static_cast<size_t>(country) *
                    _good_ids.size() + static_cast<size_t>(std::max(0, good));
                if (good < 0 ||
                    good >= static_cast<int32_t>(_good_ids.size()) ||
                    good_index >= _epoch_country_good_available.size() ||
                    _epoch_country_good_available[good_index] == 0) {
                    available = false;
                    break;
                }
            }
            _epoch_country_variant_available[
                static_cast<size_t>(country) * _variants.size() + variant] =
                    available ? 1 : 0;
        }
    }
    _epoch_country_building_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_types.size(), 0);
    _epoch_country_building_type_offsets.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) + 1, 0);
    _epoch_country_building_type_indices.clear();
    _epoch_country_building_type_indices.reserve(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_types.size());
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t type_id = 0;
             type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
            const bool available = type_id + 1 < static_cast<int32_t>(
                    _building_technology_offsets.size()) &&
                requirements_available(country,
                    _building_technology_offsets[type_id],
                    _building_technology_offsets[type_id + 1],
                    _building_required_technologies) &&
                type_id + 1 < static_cast<int32_t>(
                    _building_all_technology_offsets.size()) &&
                all_requirements_available(country,
                    _building_all_technology_offsets[type_id],
                    _building_all_technology_offsets[type_id + 1],
                    _building_all_required_technologies) &&
                dependency_requirements_available(country, type_id);
            const size_t cache_index = static_cast<size_t>(country) *
                _building_types.size() + static_cast<size_t>(type_id);
            _epoch_country_building_available[cache_index] = available ? 1 : 0;
            if (available)
                _epoch_country_building_type_indices.push_back(type_id);
        }
        _epoch_country_building_type_offsets[country + 1] =
            static_cast<int32_t>(_epoch_country_building_type_indices.size());
    }
    cache.countries = countries;
    cache.stride = _epoch_country_technology_words;
    cache.handles = handles;
    cache.technologies = _epoch_country_technologies;
    cache.valid = true;
    cache.rebuilds.fetch_add(1, std::memory_order_relaxed);
}

void NativeEconomyRuntime::refresh_country_territory_cache() {
    auto &cache = _country_territory_cache;
    const int32_t countries = std::max(0, _epoch_country_count);
    const int32_t cells = _cell_count.get();
    const auto &handles = _epoch_country_handles.values();
    const bool has_index = cells > 0 && countries > 0 &&
        _epoch_cell_country.size() == static_cast<size_t>(cells);
    const bool shape_valid = has_index
        ? country_territory_index_ready()
        : _epoch_country_cell_offsets.empty() && _epoch_country_cells.empty();
    if (cache.valid && shape_valid && cache.countries == countries &&
        cache.stride == cells && cache.handles == handles &&
        cache.owners == _epoch_cell_country) {
        _epoch_country_topology_hash = cache.topology_hash;
        cache.hits.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    rebuild_country_territory_index();
    // Preserve the existing byte order and hash value; this is still consumed
    // by geography and trade, but is no longer recomputed for unchanged owners.
    uint64_t topology_hash = 1469598103934665603ULL;
    for (const int32_t country : _epoch_cell_country) {
        const uint32_t value = static_cast<uint32_t>(country);
        for (int32_t byte = 0; byte < 4; ++byte) {
            topology_hash ^= static_cast<uint8_t>((value >> (byte * 8)) & 0xffU);
            topology_hash *= 1099511628211ULL;
        }
    }
    _epoch_country_topology_hash = (topology_hash & 0x7fffffffffffffffULL) | 1ULL;
    cache.countries = countries;
    cache.stride = cells;
    cache.handles = handles;
    cache.owners = _epoch_cell_country;
    cache.topology_hash = _epoch_country_topology_hash;
    cache.valid = true;
    cache.rebuilds.fetch_add(1, std::memory_order_relaxed);
}

} // namespace pk
