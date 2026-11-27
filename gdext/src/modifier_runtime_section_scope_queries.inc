void ModifierRuntime::effective_values(int32_t domain, const int32_t *stat_ids,
                                       uint64_t entity_handle,
                                       const int32_t *base_values,
                                       int32_t *out_values, size_t count) const {
    if (stat_ids == nullptr || base_values == nullptr || out_values == nullptr) return;
    for (size_t i = 0; i < count; ++i) {
        const double value = effective_value(domain, stat_ids[i], entity_handle, 0,
                                             base_values[i]);
        const int32_t rounded = static_cast<int32_t>(std::round(value));
        out_values[i] = rounded;
    }
}

void ModifierRuntime::collect_scope_ids(int32_t domain, int32_t scope,
                                        const int32_t *stat_ids,
                                        size_t stat_count,
                                        std::vector<uint64_t> &out_scope_ids) const {
    out_scope_ids.clear();
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT ||
        stat_ids == nullptr || stat_count == 0) return;
    // The bucket map is keyed by stat id, so the wanted set stays tiny relative
    // to a full probe of every candidate scope id.
    std::vector<int32_t> wanted(stat_ids, stat_ids + stat_count);
    std::sort(wanted.begin(), wanted.end());
    wanted.erase(std::unique(wanted.begin(), wanted.end()), wanted.end());
    const Store &store = _stores[domain];
    for (const auto &entry : store.buckets) {
        if (entry.first.scope != scope) continue;
        if (!std::binary_search(wanted.begin(), wanted.end(), entry.first.stat_id))
            continue;
        out_scope_ids.push_back(entry.first.scope_id);
    }
    // Union with the derived layer (plan §8.5 "scope enumeration returns the
    // union of instances and derived GROUP(cell) rows").
    //
    // Without this, a cell that ONLY has a derived contribution is invisible to
    // the caller: `refresh_city_modifier_factors` builds its work set from this
    // function, so the merge in `effective_value` would compute the right value
    // for a cell the reader never visits. The layer would look installed and
    // change nothing.
    //
    // Only GROUP scope can carry a derived cell row; GLOBAL/ENTITY have no cell
    // identity to look up.
    if (domain == ECONOMY && scope == GROUP) {
        for (const DerivedCellStatRow &row : _derived_cell_front.rows) {
            if (!std::binary_search(wanted.begin(), wanted.end(), row.stat_id))
                continue;
            for (const int32_t cell : row.cells) {
                if (cell < 0) continue;
                out_scope_ids.push_back(static_cast<uint64_t>(cell));
            }
        }
    }
    std::sort(out_scope_ids.begin(), out_scope_ids.end());
    out_scope_ids.erase(std::unique(out_scope_ids.begin(), out_scope_ids.end()),
                        out_scope_ids.end());
}

void ModifierRuntime::collect_scope_stat_entries(
        int32_t domain, int32_t scope, const int32_t *stat_ids,
        size_t stat_count, std::vector<uint64_t> &out_scope_ids,
        std::vector<int32_t> &out_stat_ids) const {
    out_scope_ids.clear();
    out_stat_ids.clear();
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT ||
        stat_ids == nullptr || stat_count == 0)
        return;
    std::vector<int32_t> wanted(stat_ids, stat_ids + stat_count);
    std::sort(wanted.begin(), wanted.end());
    wanted.erase(std::unique(wanted.begin(), wanted.end()), wanted.end());
    std::vector<std::pair<uint64_t, int32_t>> entries;
    const Store &store = _stores[domain];
    entries.reserve(store.buckets.size());
    for (const auto &entry : store.buckets) {
        if (entry.first.scope != scope || !std::binary_search(
                wanted.begin(), wanted.end(), entry.first.stat_id))
            continue;
        entries.emplace_back(entry.first.scope_id, entry.first.stat_id);
    }
    // Union with the derived layer (plan §8.5). `refresh_city_output_modifier_
    // factors` builds its `(cell, good)` work list from THIS function, so a
    // derived-only `(stat, cell)` pair must appear here or the reader silently
    // skips it.
    if (domain == ECONOMY && scope == GROUP) {
        for (const DerivedCellStatRow &row : _derived_cell_front.rows) {
            if (!std::binary_search(wanted.begin(), wanted.end(), row.stat_id))
                continue;
            for (const int32_t cell : row.cells) {
                if (cell < 0) continue;
                entries.emplace_back(static_cast<uint64_t>(cell), row.stat_id);
            }
        }
    }
    std::sort(entries.begin(), entries.end());
    entries.erase(std::unique(entries.begin(), entries.end()), entries.end());
    out_scope_ids.reserve(entries.size());
    out_stat_ids.reserve(entries.size());
    for (const auto &entry : entries) {
        out_scope_ids.push_back(entry.first);
        out_stat_ids.push_back(entry.second);
    }
}

uint64_t ModifierRuntime::stat_bucket_version(int32_t domain, const int32_t *stat_ids,
                                              size_t stat_count) const {
    if (domain < 0 || domain >= DOMAIN_COUNT || stat_ids == nullptr) return 0;
    const Store &store = _stores[domain];
    uint64_t hash = (1469598103934665603ULL ^ store.structure_epoch) *
        1099511628211ULL;
    for (size_t i = 0; i < stat_count; ++i) {
        const int32_t sid = stat_ids[i];
        const uint64_t version = sid >= 0 &&
                static_cast<size_t>(sid) < store.stat_versions.size()
            ? store.stat_versions[static_cast<size_t>(sid)] : 0;
        hash = (hash ^ version) * 1099511628211ULL;
        hash = (hash ^ static_cast<uint64_t>(static_cast<uint32_t>(sid))) *
            1099511628211ULL;
    }
    // ── Derived layer participation (plan §8.6) ────────────────────────────
    //
    // The derived layer keeps its OWN per-stat versions, deliberately separate
    // from `Store::stat_versions` (which `apply_pod_snapshot` bumps
    // unconditionally, `modifier_runtime.cpp:463-464`). But callers must not have
    // to remember to combine two version namespaces -- forgetting that is
    // exactly bug #1 this round: `refresh_city_modifier_factors` compares ONE
    // version, saw no change, returned early, and never reached the union.
    //
    // So the combination happens HERE, in the function every existing cache
    // already keys on. A derived change now invalidates those caches, and an
    // idle day still does not (the layer generation only moves on a real
    // content change, `install_derived_cell_layer`).
    //
    // Only the ECONOMY domain can carry a derived cell layer, and only for
    // GROUP-scoped stats, so other domains keep their historical hash exactly.
    if (domain == ECONOMY && !_derived_cell_front.rows.empty()) {
        hash = (hash ^ _derived_cell_front.generation) * 1099511628211ULL;
        for (size_t i = 0; i < stat_count; ++i) {
            const int32_t sid = stat_ids[i];
            const uint64_t layer_version = sid >= 0 &&
                    static_cast<size_t>(sid) <
                        _derived_cell_front.stat_versions.size()
                ? _derived_cell_front.stat_versions[static_cast<size_t>(sid)] : 0;
            hash = (hash ^ layer_version) * 1099511628211ULL;
        }
    }
    return hash;
}
