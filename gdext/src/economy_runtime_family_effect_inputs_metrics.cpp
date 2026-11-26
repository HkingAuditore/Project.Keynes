#include "economy_runtime_family_effect_inputs_includes.inc"

namespace pk {

void NativeEconomyRuntime::rebuild_epoch_geo_columns() {
    const int32_t cells = _cell_count.get();
    if (cells <= 0 || _epoch_cell_country.size() != static_cast<size_t>(cells) ||
        _building_neighbors.size() != static_cast<size_t>(cells) * 6 ||
        _building_is_water.size() != static_cast<size_t>(cells) ||
        _building_has_river.size() != static_cast<size_t>(cells)) {
        _epoch_cell_geo_flags.clear();
        _epoch_cell_waterway_component_size.clear();
        return;
    }
    const uint64_t canal_hash = canal_topology_hash();
    if (!_epoch_cell_geo_flags.empty() &&
        _geo_flags_territory_hash == _epoch_country_topology_hash &&
        _geo_flags_canal_hash == canal_hash) {
        return;
    }

    _epoch_cell_geo_flags.assign(static_cast<size_t>(cells), 0);
    _epoch_cell_waterway_component_size.assign(static_cast<size_t>(cells), 0);
    const bool have_canal_mask =
        _trade_topology.canal_edge_mask.size() == static_cast<size_t>(cells);
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t flags = _building_has_river[static_cast<size_t>(cell)] != 0 ? 1 : 0;
        const bool own_water = _building_is_water[static_cast<size_t>(cell)] != 0;
        if (have_canal_mask &&
            _trade_topology.canal_edge_mask[static_cast<size_t>(cell)] != 0) {
            flags |= 4;
        }
        const int32_t owner = _epoch_cell_country[static_cast<size_t>(cell)];
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _building_neighbors[
                static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
            if (neighbor < 0 || neighbor >= cells) continue;
            if (_building_is_water[static_cast<size_t>(neighbor)] != 0)
                flags |= 2;
            const int32_t neighbor_owner =
                _epoch_cell_country[static_cast<size_t>(neighbor)];
            if (!own_water &&
                _building_is_water[static_cast<size_t>(neighbor)] == 0 &&
                owner >= 0 && neighbor_owner >= 0 && owner != neighbor_owner) {
                flags |= 8;
            }
        }
        _epoch_cell_geo_flags[static_cast<size_t>(cell)] = flags;
    }

    // Connected component over river/canal land cells of the same territory.
    // Owner -1 is one bucket; component size is per cell rather than a global id
    // because no X12 card consumes basin ids. Water cells are excluded on both
    // sides of the traversal: the contract says metric 76 is zero on water.
    std::vector<uint8_t> visited(static_cast<size_t>(cells), 0);
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(cells));
    for (int32_t start = 0; start < cells; ++start) {
        if (_building_is_water[static_cast<size_t>(start)] != 0) continue;
        const bool waterway =
            (_epoch_cell_geo_flags[static_cast<size_t>(start)] & 5) != 0;
        if (!waterway || visited[static_cast<size_t>(start)] != 0) continue;
        const int32_t owner = _epoch_cell_country[static_cast<size_t>(start)];
        queue.clear();
        queue.push_back(start);
        visited[static_cast<size_t>(start)] = 1;
        for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
            const int32_t cell = queue[cursor];
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
                if (neighbor < 0 || neighbor >= cells ||
                    visited[static_cast<size_t>(neighbor)] != 0) continue;
                if (_building_is_water[static_cast<size_t>(neighbor)] != 0) continue;
                if ((_epoch_cell_geo_flags[static_cast<size_t>(neighbor)] & 5) == 0 ||
                    _epoch_cell_country[static_cast<size_t>(neighbor)] != owner)
                    continue;
                visited[static_cast<size_t>(neighbor)] = 1;
                queue.push_back(neighbor);
            }
        }
        const int32_t component_size = static_cast<int32_t>(queue.size());
        for (const int32_t cell : queue)
            _epoch_cell_waterway_component_size[static_cast<size_t>(cell)] =
                component_size;
    }
    _geo_flags_territory_hash = _epoch_country_topology_hash;
    _geo_flags_canal_hash = canal_hash;
    _geo_flags_rebuilds.fetch_add(1, std::memory_order_relaxed);
}

bool NativeEconomyRuntime::rebuild_epoch_family_cell_metrics() {
    const auto &influences = family_influences();
    uint64_t signature = 1469598103934665603ULL;
    const auto mix = [&](uint64_t value) {
        signature ^= value;
        signature *= 1099511628211ULL;
    };
    mix(static_cast<uint64_t>(influences.active.size()));
    mix(influences.active.mutation_revision());
    mix(influences.family_handle.mutation_revision());
    mix(influences.cell.mutation_revision());
    mix(influences.building_share_q16.mutation_revision());
    mix(influences.score_q16.mutation_revision());
    if (signature == _family_cell_metric_signature &&
        _epoch_cell_family_branch_count.size() ==
            static_cast<size_t>(_cell_count.get()))
        return false;

    const int32_t cells = _cell_count.get();
    std::vector<int32_t> branch_count(static_cast<size_t>(std::max(0, cells)), 0);
    std::vector<int64_t> max_prestige(static_cast<size_t>(std::max(0, cells)), 0);
    std::vector<int32_t> max_asset_share(
        static_cast<size_t>(std::max(0, cells)), 0);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            influences.active.size()); ++branch) {
        if (influences.active[branch] == 0) continue;
        const int32_t cell = influences.cell[branch];
        if (cell < 0 || cell >= cells) continue;
        ++branch_count[static_cast<size_t>(cell)];
        max_prestige[static_cast<size_t>(cell)] = std::max<int64_t>(
            max_prestige[static_cast<size_t>(cell)],
            influences.score_q16[branch]);
        max_asset_share[static_cast<size_t>(cell)] = std::max<int32_t>(
            max_asset_share[static_cast<size_t>(cell)],
            influences.building_share_q16[branch]);
    }
    _family_cell_metric_changed_cells.assign(
        static_cast<size_t>(std::max(0, cells)), 0);
    for (int32_t cell = 0; cell < cells; ++cell) {
        const size_t slot = static_cast<size_t>(cell);
        if ((cell < static_cast<int32_t>(_epoch_cell_family_branch_count.size()) &&
                _epoch_cell_family_branch_count[slot] != branch_count[slot]) ||
            (cell < static_cast<int32_t>(
                _epoch_cell_max_branch_prestige_q16.size()) &&
                _epoch_cell_max_branch_prestige_q16[slot] != max_prestige[slot]) ||
            (cell < static_cast<int32_t>(
                _epoch_cell_family_asset_share_q16.size()) &&
                _epoch_cell_family_asset_share_q16[slot] != max_asset_share[slot]))
            _family_cell_metric_changed_cells[slot] = 1;
    }
    _epoch_cell_family_branch_count = std::move(branch_count);
    _epoch_cell_max_branch_prestige_q16 = std::move(max_prestige);
    _epoch_cell_family_asset_share_q16 = std::move(max_asset_share);
    _family_cell_metric_signature = signature;
    _family_cell_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
    return true;
}

bool NativeEconomyRuntime::rebuild_epoch_family_country_metrics() {
    const auto &families = families_store();
    const auto &influences = family_influences();
    uint64_t signature = 1469598103934665603ULL;
    const auto mix = [&](uint64_t value) {
        signature ^= value;
        signature *= 1099511628211ULL;
    };
    mix(families.active.size());
    mix(families.active.mutation_revision());
    mix(families.founded_day.mutation_revision());
    mix(families.home_cell.mutation_revision());
    mix(families.origin_cell.mutation_revision());
    mix(influences.active.size());
    mix(influences.active.mutation_revision());
    mix(influences.family_handle.mutation_revision());
    mix(influences.cell.mutation_revision());
    mix(_epoch_country_topology_hash);
    if (signature == _family_country_metric_signature &&
        _epoch_country_family_remote_branch_count.size() ==
            static_cast<size_t>(std::max(0, _epoch_country_count)))
        return false;

    const int32_t countries = std::max(0, _epoch_country_count);
    std::vector<int32_t> branches_by_family(
        static_cast<size_t>(std::max(0, static_cast<int32_t>(
            families.active.size()))), 0);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            influences.active.size()); ++branch) {
        if (influences.active[branch] == 0) continue;
        int32_t family = -1;
        if (!families.valid_handle(influences.family_handle[branch], family) ||
            family < 0 || family >= static_cast<int32_t>(branches_by_family.size()))
            continue;
        ++branches_by_family[static_cast<size_t>(family)];
    }

    std::vector<int32_t> family_country(
        families.active.size(), -1);
    std::vector<int32_t> remote(
        static_cast<size_t>(countries), 0);
    std::vector<int32_t> large_families(
        static_cast<size_t>(countries), 0);
    std::vector<int64_t> oldest_founded(
        static_cast<size_t>(countries), std::numeric_limits<int64_t>::max());
    std::vector<int64_t> founded_sum(
        static_cast<size_t>(countries), 0);
    std::vector<int32_t> family_count(
        static_cast<size_t>(countries), 0);
    for (int32_t family = 0; family < static_cast<int32_t>(
            families.active.size()); ++family) {
        if (families.active[family] == 0) continue;
        const int32_t country = cell_country_slot(families.home_cell[family]);
        if (country < 0 || country >= countries) continue;
        family_country[static_cast<size_t>(family)] = country;
        if (branches_by_family[static_cast<size_t>(family)] >= 3)
            ++large_families[static_cast<size_t>(country)];
        oldest_founded[static_cast<size_t>(country)] = std::min<int64_t>(
            oldest_founded[static_cast<size_t>(country)],
            families.founded_day[family]);
        founded_sum[static_cast<size_t>(country)] +=
            families.founded_day[family];
        ++family_count[static_cast<size_t>(country)];
    }

    // "Remote" means at least five hex steps from the family's ancestral
    // origin, not merely away from its current home cell. BFS only four rings
    // and counts a branch as remote when its cell was not reached. A family
    // whose origin is invalid contributes no remote evidence.
    const int32_t cells = std::max(0, _cell_count.get());
    std::vector<int32_t> distance(
        static_cast<size_t>(cells), std::numeric_limits<int32_t>::max());
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(cells));
    for (int32_t family = 0; family < static_cast<int32_t>(
            families.active.size()); ++family) {
        if (families.active[family] == 0) continue;
        const int32_t country = family_country[static_cast<size_t>(family)];
        if (country < 0) continue;
        const int32_t origin = families.origin_cell[family];
        if (origin < 0 || origin >= cells ||
                _building_neighbors.size() !=
                    static_cast<size_t>(cells) * 6)
            continue;
        std::fill(distance.begin(), distance.end(),
            std::numeric_limits<int32_t>::max());
        queue.clear();
        distance[static_cast<size_t>(origin)] = 0;
        queue.push_back(origin);
        for (size_t head = 0; head < queue.size(); ++head) {
            const int32_t cell = queue[head];
            const int32_t next_distance = distance[
                static_cast<size_t>(cell)] + 1;
            if (next_distance > 4) continue;
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 +
                    static_cast<size_t>(direction)];
                if (neighbor < 0 || neighbor >= cells ||
                        distance[static_cast<size_t>(neighbor)] !=
                            std::numeric_limits<int32_t>::max())
                    continue;
                distance[static_cast<size_t>(neighbor)] = next_distance;
                queue.push_back(neighbor);
            }
        }
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                influences.active.size()); ++branch) {
            if (influences.active[branch] == 0) continue;
            int32_t branch_family = -1;
            if (!families.valid_handle(
                    influences.family_handle[branch], branch_family) ||
                    branch_family != family)
                continue;
            const int32_t branch_cell = influences.cell[branch];
            if (branch_cell < 0 || branch_cell >= cells)
                continue;
            if (distance[static_cast<size_t>(branch_cell)] ==
                    std::numeric_limits<int32_t>::max())
                ++remote[static_cast<size_t>(country)];
        }
    }

    std::vector<uint8_t> changed(
        static_cast<size_t>(countries), 0);
    const auto column_changed = [&](const auto &old_values,
                                    const auto &new_values) {
        for (int32_t country = 0; country < countries; ++country) {
            const size_t slot = static_cast<size_t>(country);
            if (slot >= old_values.size() || old_values[slot] != new_values[slot])
                changed[slot] = 1;
        }
    };
    column_changed(_epoch_country_family_remote_branch_count, remote);
    column_changed(_epoch_country_families_with_at_least_3_branches,
        large_families);
    column_changed(_epoch_country_oldest_family_founded_day, oldest_founded);
    column_changed(_epoch_country_family_founded_day_sum, founded_sum);
    column_changed(_epoch_country_family_count, family_count);
    _epoch_country_family_remote_branch_count = std::move(remote);
    _epoch_country_families_with_at_least_3_branches =
        std::move(large_families);
    _epoch_country_oldest_family_founded_day = std::move(oldest_founded);
    _epoch_country_family_founded_day_sum = std::move(founded_sum);
    _epoch_country_family_count = std::move(family_count);
    _family_country_metric_changed_countries = std::move(changed);
    _family_country_metric_signature = signature;
    _family_country_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
    return true;
}

void NativeEconomyRuntime::refresh_class_opinion_metrics() {
    const auto view = copy_lineage_opinion_view();
    assert(view.observe(_lineage_opinion_view_version));
    const auto &snapshot = *view.data;
    const std::vector<int64_t> &source_population =
        _class_opinion_source_override_enabled
        ? _class_opinion_override_population : snapshot.population;
    const std::vector<int32_t> &source_satisfaction_q16 =
        _class_opinion_source_override_enabled
        ? _class_opinion_override_satisfaction_q16 : snapshot.satisfaction_q16;
    const std::vector<int64_t> &source_satisfaction_weighted =
        _class_opinion_source_override_enabled
        ? _class_opinion_override_weighted : snapshot.satisfaction_weighted;
    const int32_t country_count = std::max(0, _epoch_country_count);
    auto source_hash = [&]() {
        uint64_t hash = 1469598103934665603ULL;
        auto mix = [](uint64_t value_hash, uint64_t value) {
            value_hash ^= value;
            value_hash *= 1099511628211ULL;
            return value_hash;
        };
        hash = mix(hash, static_cast<uint64_t>(snapshot.country_count));
        hash = mix(hash, static_cast<uint64_t>(snapshot.class_count));
        for (const int64_t value : source_population)
            hash = mix(hash, static_cast<uint64_t>(value));
        for (const int32_t value : source_satisfaction_q16)
            hash = mix(hash, static_cast<uint32_t>(value));
        for (const int64_t value : source_satisfaction_weighted)
            hash = mix(hash, static_cast<uint64_t>(value));
        return hash;
    }();
    if (source_hash == _class_metric_source_content_hash &&
        static_cast<int32_t>(_epoch_country_weighted_satisfaction_q16.size()) ==
            country_count &&
        static_cast<int32_t>(_epoch_country_farmer_satisfaction_q16.size()) ==
            country_count &&
        static_cast<int32_t>(_epoch_country_worker_satisfaction_q16.size()) ==
            country_count)
        return;
    std::vector<int64_t> class_values(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> weighted_values(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> farmer_values(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> worker_values(
        static_cast<size_t>(country_count), 0);
    // Sorted classes are checked per row; smaller fixtures keep their valid rows.
    const int32_t general_class = [&]() {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("general"));
        return found != _political_class_ids.end() && *found == "general"
            ? static_cast<int32_t>(found - _political_class_ids.begin()) : -1;
    }();
    const int32_t farmer_class = [&]() {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("farmer"));
        return found != _political_class_ids.end() && *found == "farmer"
            ? static_cast<int32_t>(found - _political_class_ids.begin()) : -1;
    }();
    const int32_t worker_class = [&]() {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("worker"));
        return found != _political_class_ids.end() && *found == "worker"
            ? static_cast<int32_t>(found - _political_class_ids.begin()) : -1;
    }();
    const int64_t snapshot_row_count =
        static_cast<int64_t>(snapshot.country_count) * snapshot.class_count;
    const bool class_rows_valid =
        static_cast<int64_t>(source_satisfaction_q16.size()) == snapshot_row_count &&
        static_cast<int64_t>(source_population.size()) == snapshot_row_count &&
        static_cast<int64_t>(source_satisfaction_weighted.size()) ==
            snapshot_row_count;
    if (class_rows_valid) {
        for (int32_t country = 0; country < country_count; ++country) {
            if (country >= snapshot.country_count) break;
            const size_t row_base = static_cast<size_t>(country) *
                static_cast<size_t>(snapshot.class_count);
            if (general_class >= 0)
                class_values[static_cast<size_t>(country)] =
                    source_satisfaction_q16[row_base +
                        static_cast<size_t>(general_class)];
            if (farmer_class >= 0)
                farmer_values[static_cast<size_t>(country)] =
                    source_satisfaction_q16[row_base +
                        static_cast<size_t>(farmer_class)];
            if (worker_class >= 0)
                worker_values[static_cast<size_t>(country)] =
                    source_satisfaction_q16[row_base +
                        static_cast<size_t>(worker_class)];
        }
    }
    // The committed snapshot has no influence column. Population is the honest
    // v1 weight available in Economy; ideology's influence weight is not read
    // across the authority boundary. Both values are Q16 ratios.
    for (int32_t country = 0; country < country_count; ++country) {
        if (country >= snapshot.country_count) break;
        int64_t country_population = 0;
        int64_t country_weighted = 0;
        for (int32_t political_class = 0;
             political_class < snapshot.class_count; ++political_class) {
            const size_t row = static_cast<size_t>(country) *
                static_cast<size_t>(snapshot.class_count) +
                static_cast<size_t>(political_class);
            if (row >= source_population.size() ||
                row >= source_satisfaction_weighted.size())
                break;
            country_population = saturating_add(country_population,
                std::max<int64_t>(0, source_population[row]),
                _saturation_count);
            country_weighted = saturating_add(country_weighted,
                std::max<int64_t>(0, source_satisfaction_weighted[row]),
                _saturation_count);
        }
        if (country_population > 0)
            weighted_values[static_cast<size_t>(country)] =
                std::clamp<int64_t>(
                    country_weighted / country_population, 0, Q16_ONE);
    }
    const bool changed =
        class_values != _epoch_country_class_satisfaction_q16 ||
        weighted_values != _epoch_country_weighted_satisfaction_q16 ||
        farmer_values != _epoch_country_farmer_satisfaction_q16 ||
        worker_values != _epoch_country_worker_satisfaction_q16;
    _epoch_country_class_satisfaction_q16 = std::move(class_values);
    _epoch_country_weighted_satisfaction_q16 = std::move(weighted_values);
    _epoch_country_farmer_satisfaction_q16 = std::move(farmer_values);
    _epoch_country_worker_satisfaction_q16 = std::move(worker_values);
    _class_metric_source_revision = snapshot.revision;
    _class_metric_source_content_hash = source_hash;
    _class_metric_source_epoch_day = snapshot.epoch_day;
    if (changed) _class_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
}

void NativeEconomyRuntime::refresh_technology_metrics() {
    const int32_t country_count = std::max(0, _epoch_country_count);
    const int32_t words = std::max(0, _epoch_country_technology_words);
    const auto popcount = [](uint64_t value) {
        int32_t count = 0;
        while (value != 0) {
            value &= value - 1;
            ++count;
        }
        return count;
    };
    uint64_t source_hash = 1469598103934665603ULL;
    auto mix = [](uint64_t hash, uint64_t value) {
        hash ^= value;
        hash *= 1099511628211ULL;
        return hash;
    };
    source_hash = mix(source_hash, static_cast<uint64_t>(country_count));
    source_hash = mix(source_hash, static_cast<uint64_t>(words));
    const size_t expected_words = static_cast<size_t>(country_count) *
        static_cast<size_t>(words);
    for (size_t word = 0;
         word < expected_words && word < _epoch_country_technologies.size();
         ++word) {
        source_hash = mix(source_hash, _epoch_country_technologies[word]);
    }
    if (source_hash == _technology_metric_source_hash &&
        static_cast<int32_t>(_epoch_country_completed_tech_count.size()) ==
            country_count)
        return;
    std::vector<int64_t> total(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_counts(
        static_cast<size_t>(country_count) * 4, 0);
    for (int32_t country = 0; country < country_count; ++country) {
        int64_t country_total = 0;
        for (int32_t word = 0; word < words; ++word) {
            const size_t index =
                static_cast<size_t>(country) * static_cast<size_t>(words) +
                static_cast<size_t>(word);
            if (index >= _epoch_country_technologies.size()) break;
            const uint64_t bits = _epoch_country_technologies[index];
            country_total += popcount(bits);
            for (size_t domain = 0; domain < 4; ++domain) {
                const size_t mask_index =
                    domain * static_cast<size_t>(words) +
                    static_cast<size_t>(word);
                if (mask_index >= _technology_domain_masks.size()) continue;
                const uint64_t domain_bits =
                    bits & _technology_domain_masks[mask_index];
                domain_counts[static_cast<size_t>(country) * 4 + domain] +=
                    popcount(domain_bits);
            }
        }
        total[static_cast<size_t>(country)] = country_total;
    }
    std::vector<int64_t> domain_0(static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_1(static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_2(static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_3(static_cast<size_t>(country_count), 0);
    for (int32_t country = 0; country < country_count; ++country) {
        const size_t row = static_cast<size_t>(country) * 4;
        domain_0[static_cast<size_t>(country)] = domain_counts[row];
        domain_1[static_cast<size_t>(country)] = domain_counts[row + 1];
        domain_2[static_cast<size_t>(country)] = domain_counts[row + 2];
        domain_3[static_cast<size_t>(country)] = domain_counts[row + 3];
    }
    const bool changed =
        total != _epoch_country_completed_tech_count ||
        domain_0 != _epoch_country_completed_tech_count_domain_0 ||
        domain_1 != _epoch_country_completed_tech_count_domain_1 ||
        domain_2 != _epoch_country_completed_tech_count_domain_2 ||
        domain_3 != _epoch_country_completed_tech_count_domain_3;
    _epoch_country_completed_tech_count = std::move(total);
    _epoch_country_completed_tech_count_domain_0 = std::move(domain_0);
    _epoch_country_completed_tech_count_domain_1 = std::move(domain_1);
    _epoch_country_completed_tech_count_domain_2 = std::move(domain_2);
    _epoch_country_completed_tech_count_domain_3 = std::move(domain_3);
    _technology_metric_source_hash = source_hash;
    if (changed)
        _technology_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
}

void NativeEconomyRuntime::refresh_neighbor_distinct_goods_metrics() {
    const int32_t cells = _cell_count.get();
    if (cells <= 0 ||
        _building_cell_offsets.size() != static_cast<size_t>(cells) + 1 ||
        _building_neighbors.size() != static_cast<size_t>(cells) * 6) {
        if (!_epoch_cell_neighbor_distinct_goods.empty()) {
            _epoch_cell_neighbor_distinct_goods.clear();
            _neighbor_distinct_goods_source_hash = 0;
            _neighbor_distinct_goods_rebuilds.fetch_add(
                1, std::memory_order_relaxed);
        }
        return;
    }

    uint64_t source_hash = 1469598103934665603ULL;
    const auto mix = [](uint64_t hash, uint64_t value) {
        hash ^= value;
        hash *= 1099511628211ULL;
        return hash;
    };
    source_hash = mix(source_hash, static_cast<uint64_t>(cells));
    for (size_t index = 0; index < _building_cell_offsets.size(); ++index) {
        source_hash = mix(source_hash,
            static_cast<uint64_t>(_building_cell_offsets[index]));
    }
    for (const int32_t neighbor : _building_neighbors) {
        source_hash = mix(source_hash,
            static_cast<uint64_t>(static_cast<uint32_t>(neighbor)));
    }
    // Hash the metric's actual inputs, not raw production magnitudes. A stable
    // mine can report a different last_output every day while still dominating
    // the same good; rebuilding 87 in that case would make the idle contract
    // depend on price noise. dominant_output_good_at() resolves ties and output
    // shares, so two equal dominant ids guarantee the distinct-neighbour answer
    // is unchanged.
    std::vector<int32_t> dominant_goods(static_cast<size_t>(cells), -1);
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t share_q16 = 0;
        const int32_t good = _building_cell_offsets[cell] == _building_cell_offsets[cell + 1]
            ? -1 : dominant_output_good_at(cell, share_q16);
        dominant_goods[cell] = good;
        source_hash = mix(source_hash,
            static_cast<uint64_t>(static_cast<uint32_t>(good + 1)));
    }
    if (source_hash == _neighbor_distinct_goods_source_hash &&
        _epoch_cell_neighbor_distinct_goods.size() ==
            static_cast<size_t>(cells))
        return;

    std::vector<int32_t> counts(static_cast<size_t>(cells), 0);
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t distinct[6] = {-1, -1, -1, -1, -1, -1};
        int32_t distinct_count = 0;
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _building_neighbors[
                static_cast<size_t>(cell) * 6 +
                static_cast<size_t>(direction)];
            if (neighbor < 0 || neighbor >= cells) continue;
            const int32_t good = dominant_goods[neighbor];
            if (good < 0) continue;
            bool duplicate = false;
            for (int32_t slot = 0; slot < distinct_count; ++slot) {
                if (distinct[slot] == good) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) distinct[distinct_count++] = good;
        }
        counts[static_cast<size_t>(cell)] = distinct_count;
    }
    _neighbor_distinct_goods_rebuilds.fetch_add(
        1, std::memory_order_relaxed);
    _epoch_cell_neighbor_distinct_goods = std::move(counts);
    _neighbor_distinct_goods_source_hash = source_hash;
}

void NativeEconomyRuntime::set_epoch_country_technologies_for_test(
        const std::vector<uint64_t> &bits) {
    _epoch_country_technologies = bits;
    _technology_metric_input_override = bits;
    _technology_metric_input_override_enabled = true;
    refresh_technology_metrics();
}

void NativeEconomyRuntime::clear_epoch_country_technologies_for_test() {
    _technology_metric_input_override.clear();
    _technology_metric_input_override_enabled = false;
    refresh_technology_metrics();
}

void NativeEconomyRuntime::set_class_opinion_source_override_for_test(
        const std::vector<int64_t> &population,
        const std::vector<int32_t> &satisfaction_q16,
        const std::vector<int64_t> &satisfaction_weighted) {
    _class_opinion_override_population = population;
    _class_opinion_override_satisfaction_q16 = satisfaction_q16;
    _class_opinion_override_weighted = satisfaction_weighted;
    const CountryClassOpinionSnapshot &committed =
        country_class_opinion_snapshot();
    _class_opinion_override_revision = std::max(
        _class_opinion_override_revision + 1u, committed.revision + 1u);
    _class_opinion_override_commit_day = std::max(
        _class_opinion_override_commit_day + 1, committed.commit_day + 1);
    _class_opinion_source_override_enabled = true;
}

bool NativeEconomyRuntime::class_opinion_source_override_enabled_for_test() const {
    return _class_opinion_source_override_enabled;
}

NativeEconomyRuntime::CountryClassOpinionSnapshot
NativeEconomyRuntime::country_class_opinion_source_snapshot() const {
    CountryClassOpinionSnapshot out = country_class_opinion_snapshot();
    if (!_class_opinion_source_override_enabled)
        return out;
    const size_t rows = static_cast<size_t>(std::max(0, out.country_count)) *
        static_cast<size_t>(std::max(0, out.class_count));
    if (_class_opinion_override_population.size() != rows ||
        _class_opinion_override_satisfaction_q16.size() != rows ||
        _class_opinion_override_weighted.size() != rows ||
        out.country_population.size() !=
            static_cast<size_t>(std::max(0, out.country_count)))
        return out;
    out.population = _class_opinion_override_population;
    out.satisfaction_q16 = _class_opinion_override_satisfaction_q16;
    out.satisfaction_weighted = _class_opinion_override_weighted;
    out.revision = _class_opinion_override_revision;
    out.commit_day = _class_opinion_override_commit_day;
    out.period_index = out.commit_day / std::max<int64_t>(1, out.period_days);
    // Ideology accrues against the country total, not the published live total.
    // Recompute it from the same overridden rows so the worker and class metrics
    // cannot disagree about the population delta.
    std::fill(out.country_population.begin(), out.country_population.end(), 0);
    int64_t saturation_count = 0;
    for (int32_t country = 0; country < out.country_count; ++country) {
        for (int32_t political_class = 0;
             political_class < out.class_count; ++political_class) {
            const size_t row = static_cast<size_t>(country) *
                static_cast<size_t>(out.class_count) +
                static_cast<size_t>(political_class);
            out.country_population[static_cast<size_t>(country)] =
                saturating_add(
                    out.country_population[static_cast<size_t>(country)],
                    std::max<int64_t>(0, out.population[row]),
                    saturation_count);
        }
    }
    return out;
}

void NativeEconomyRuntime::clear_class_opinion_source_override_for_test() {
    _class_opinion_override_population.clear();
    _class_opinion_override_satisfaction_q16.clear();
    _class_opinion_override_weighted.clear();
    _class_opinion_source_override_enabled = false;
}

} // namespace pk
