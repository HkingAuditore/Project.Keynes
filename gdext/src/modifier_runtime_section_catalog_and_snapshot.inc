int32_t ModifierRuntime::stat_id(const std::string &key) const {
    const auto it = _stat_ids.find(key);
    return it == _stat_ids.end() ? -1 : it->second;
}

double ModifierRuntime::stat_clamp_max(const char *key, double fallback) const {
    if (key == nullptr || !_configured) return fallback;
    const int32_t sid = stat_id(key);
    if (sid < 0 || sid >= static_cast<int32_t>(_stats.size())) return fallback;
    const double hi = _stats[static_cast<size_t>(sid)].max_value;
    return std::isfinite(hi) ? hi : fallback;
}

int32_t ModifierRuntime::definition_id(const std::string &key) const {
    const auto it = _definition_ids.find(key);
    return it == _definition_ids.end() ? -1 : it->second;
}

bool ModifierRuntime::compile_catalog(const Dictionary &catalog,
                                      std::string &error) {
    const PackedStringArray stat_keys = catalog.get("stat_keys", PackedStringArray());
    const PackedInt32Array stat_domains = catalog.get("stat_domains", PackedInt32Array());
    const PackedFloat64Array stat_min = catalog.get("stat_min_values", PackedFloat64Array());
    const PackedFloat64Array stat_max = catalog.get("stat_max_values", PackedFloat64Array());
    const PackedByteArray stat_persistable = catalog.get("stat_persistable", PackedByteArray());
    // Optional columns: a catalog that predates L1-6 has neither, and every stat
    // then behaves exactly as before (SUM, no cap). Required-shape checks below
    // deliberately do not mention them for that reason.
    const PackedInt32Array stat_policies = catalog.get(
        "stat_aggregate_policies", PackedInt32Array());
    const PackedInt32Array stat_caps = catalog.get("stat_source_caps", PackedInt32Array());
    const int32_t stat_count = stat_keys.size();
    if (stat_count <= 0 || stat_domains.size() != stat_count ||
        stat_min.size() != stat_count || stat_max.size() != stat_count ||
        stat_persistable.size() != stat_count ||
        (!stat_policies.is_empty() && stat_policies.size() != stat_count) ||
        (!stat_caps.is_empty() && stat_caps.size() != stat_count)) {
        error = "modifier_stat_catalog_shape_invalid";
        return false;
    }

    std::vector<StatDefinition> stats;
    std::unordered_map<std::string, int32_t> stat_ids;
    stats.reserve(stat_count);
    for (int32_t i = 0; i < stat_count; ++i) {
        const std::string key = stat_keys[i].utf8().get_data();
        const int32_t domain = stat_domains[i];
        const double lo = stat_min[i], hi = stat_max[i];
        if (key.empty() || domain < 0 || domain >= DOMAIN_COUNT ||
            !std::isfinite(lo) || !std::isfinite(hi) || lo > hi ||
            !stat_ids.emplace(key, i).second) {
            error = "modifier_stat_catalog_entry_invalid";
            return false;
        }
        const int32_t policy = stat_policies.is_empty() ? AGGREGATE_SUM : stat_policies[i];
        const int32_t cap = stat_caps.is_empty() ? 0 : stat_caps[i];
        if (policy < AGGREGATE_SUM || policy > AGGREGATE_TOP_N_SOURCES || cap < 0) {
            error = "modifier_stat_aggregate_invalid";
            return false;
        }
        stats.push_back({key, domain, lo, hi, stat_persistable[i] != 0, policy, cap});
    }

    const PackedStringArray definition_keys = catalog.get(
        "definition_keys", PackedStringArray());
    const PackedInt32Array definition_versions = catalog.get(
        "definition_versions", PackedInt32Array());
    const PackedInt32Array definition_domains = catalog.get(
        "definition_domains", PackedInt32Array());
    const PackedInt32Array definition_policies = catalog.get(
        "definition_policies", PackedInt32Array());
    const PackedInt32Array definition_max_stacks = catalog.get(
        "definition_max_stacks", PackedInt32Array());
    const PackedInt32Array definition_default_duration = catalog.get(
        "definition_default_duration", PackedInt32Array());
    const PackedInt32Array term_offsets = catalog.get(
        "definition_term_offsets", PackedInt32Array());
    const PackedInt32Array term_stat_ids = catalog.get("term_stat_ids", PackedInt32Array());
    const PackedInt32Array term_operations = catalog.get("term_operations", PackedInt32Array());
    const PackedFloat64Array term_values = catalog.get("term_values", PackedFloat64Array());
    const int32_t definition_count = definition_keys.size();
    if (definition_count <= 0 || definition_versions.size() != definition_count ||
        definition_domains.size() != definition_count ||
        definition_policies.size() != definition_count ||
        definition_max_stacks.size() != definition_count ||
        definition_default_duration.size() != definition_count ||
        term_offsets.size() != definition_count + 1 ||
        term_stat_ids.size() != term_operations.size() ||
        term_stat_ids.size() != term_values.size() || term_offsets[0] != 0 ||
        term_offsets[definition_count] != term_values.size()) {
        error = "modifier_definition_catalog_shape_invalid";
        return false;
    }

    std::vector<Definition> definitions;
    std::vector<TermDefinition> terms;
    std::unordered_map<std::string, int32_t> definition_ids;
    definitions.reserve(definition_count);
    terms.reserve(term_values.size());
    for (int32_t i = 0; i < definition_count; ++i) {
        const std::string key = definition_keys[i].utf8().get_data();
        const int32_t domain = definition_domains[i];
        const int32_t policy = definition_policies[i];
        const int32_t begin = term_offsets[i], end = term_offsets[i + 1];
        if (key.empty() || definition_versions[i] <= 0 ||
            domain < 0 || domain >= DOMAIN_COUNT || policy < INDEPENDENT ||
            policy > STACK_REFRESH || definition_max_stacks[i] <= 0 ||
            (definition_default_duration[i] != -1 &&
             definition_default_duration[i] <= 0) || begin >= end ||
            !definition_ids.emplace(key, i).second) {
            error = "modifier_definition_catalog_entry_invalid";
            return false;
        }
        Definition definition;
        definition.key = key;
        definition.version = definition_versions[i];
        definition.domain = domain;
        definition.policy = policy;
        definition.max_stacks = definition_max_stacks[i];
        definition.default_duration = definition_default_duration[i];
        definition.term_begin = static_cast<uint32_t>(terms.size());
        for (int32_t term_index = begin; term_index < end; ++term_index) {
            const int32_t sid = term_stat_ids[term_index];
            const int32_t operation = term_operations[term_index];
            const double value = term_values[term_index];
            if (sid < 0 || sid >= stat_count || stats[sid].domain != domain ||
                operation < ADD || operation > DIVIDE || !std::isfinite(value) ||
                (operation == DIVIDE && value == 0.0)) {
                error = "modifier_term_catalog_entry_invalid";
                return false;
            }
            TermDefinition term;
            term.stat_id = sid;
            if (operation == ADD) term.add = value;
            else if (operation == SUBTRACT) term.add = -value;
            else if (operation == MULTIPLY) term.factor = value;
            else term.factor = 1.0 / value;
            if (!std::isfinite(term.add) || !std::isfinite(term.factor)) {
                error = "modifier_term_normalization_invalid";
                return false;
            }
            terms.push_back(term);
        }
        definition.term_count = static_cast<uint32_t>(terms.size()) - definition.term_begin;
        definitions.push_back(std::move(definition));
    }

    uint64_t hash = 1469598103934665603ULL;
    for (const StatDefinition &stat : stats) {
        hash = fnv_string(hash, stat.key);
        hash = fnv_mix(hash, &stat.domain, sizeof(stat.domain));
        hash = fnv_mix(hash, &stat.min_value, sizeof(stat.min_value));
        hash = fnv_mix(hash, &stat.max_value, sizeof(stat.max_value));
    }
    for (const Definition &definition : definitions) {
        hash = fnv_string(hash, definition.key);
        hash = fnv_mix(hash, &definition.version, sizeof(definition.version));
    }
    for (const TermDefinition &term : terms)
        hash = fnv_catalog_term(hash, term.stat_id, term.add, term.factor);
    uint64_t legacy_hash = 1469598103934665603ULL;
    for (const StatDefinition &stat : stats) {
        if (stat.key.rfind("country.tax.", 0) == 0) continue;
        legacy_hash = fnv_string(legacy_hash, stat.key);
        legacy_hash = fnv_mix(legacy_hash, &stat.domain, sizeof(stat.domain));
        legacy_hash = fnv_mix(legacy_hash, &stat.min_value, sizeof(stat.min_value));
        legacy_hash = fnv_mix(legacy_hash, &stat.max_value, sizeof(stat.max_value));
    }
    for (const Definition &definition : definitions) {
        legacy_hash = fnv_string(legacy_hash, definition.key);
        legacy_hash = fnv_mix(
            legacy_hash, &definition.version, sizeof(definition.version));
    }
    for (const TermDefinition &term : terms)
        legacy_hash = fnv_catalog_term(legacy_hash, term.stat_id, term.add, term.factor);

    _stats = std::move(stats);
    _definitions = std::move(definitions);
    _terms = std::move(terms);
    _stat_ids = std::move(stat_ids);
    _definition_ids = std::move(definition_ids);
    _catalog_hash = hash;
    _legacy_catalog_hash_without_tax = legacy_hash;
    _building_output_stat_ids[0] = stat_id("economy.building.output_factor");
    _building_output_stat_ids[1] = stat_id("economy.city.output_factor");
    _building_output_stat_ids[2] =
        stat_id("economy.city.building.agriculture_output_factor");
    _building_output_stat_ids[3] =
        stat_id("economy.city.building.extractive_output_factor");
    _building_output_stat_ids[4] =
        stat_id("economy.city.building.manufacturing_output_factor");
    _building_output_stat_ids[5] =
        stat_id("economy.city.building.energy_output_factor");
    _building_output_stat_ids[6] =
        stat_id("economy.city.building.knowledge_output_factor");
    return true;
}

Dictionary ModifierRuntime::configure(const Dictionary &catalog, int32_t cell_count) {
    if (cell_count <= 0) return fail_dict("modifier_cell_count_invalid");
    std::string error;
    if (!compile_catalog(catalog, error)) return fail_dict(error.c_str());
    _configured = true;
    reset_runtime_state(cell_count);
    Dictionary out;
    out["ok"] = true;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["stat_count"] = static_cast<int32_t>(_stats.size());
    out["definition_count"] = static_cast<int32_t>(_definitions.size());
    return out;
}

bool ModifierRuntime::export_pod_catalog(RuntimeModifierPodCatalog &out,
                                         std::string &error) const {
    error.clear();
    if (!_configured) {
        error = "modifier_runtime_not_configured";
        return false;
    }
    out = RuntimeModifierPodCatalog{};
    out.stats.reserve(_stats.size());
    out.definitions.reserve(_definitions.size());
    out.terms.reserve(_terms.size());
    for (const StatDefinition &stat : _stats) {
        RuntimeModifierPodStat pod;
        pod.domain = stat.domain;
        pod.min_value = stat.min_value;
        pod.max_value = stat.max_value;
        pod.persistable = stat.persistable ? 1u : 0u;
        pod.aggregate_policy = stat.aggregate_policy;
        pod.source_cap = stat.source_cap;
        out.stats.push_back(pod);
    }
    for (const Definition &definition : _definitions) {
        RuntimeModifierPodDefinition pod;
        pod.version = definition.version;
        pod.domain = definition.domain;
        pod.policy = definition.policy;
        pod.max_stacks = definition.max_stacks;
        pod.default_duration = definition.default_duration;
        pod.term_begin = definition.term_begin;
        pod.term_count = definition.term_count;
        out.definitions.push_back(pod);
    }
    for (const TermDefinition &term : _terms) {
        out.terms.push_back({term.stat_id, term.add, term.factor});
    }
    // The POD catalog intentionally hashes only numeric normalized data. Its
    // identity is independent from the legacy string-bearing catalog hash.
    out.catalog_hash = 0;
    return true;
}

void ModifierRuntime::export_definition_key_hashes(
        std::vector<std::pair<uint64_t, int32_t>> &out) const {
    out.clear();
    out.reserve(_definitions.size());
    for (size_t i = 0; i < _definitions.size(); ++i) {
        const std::string &key = _definitions[i].key;
        if (key.empty()) continue;
        out.emplace_back(
            RuntimeEffectPodAuthority::hash_text(key.c_str()),
            static_cast<int32_t>(i));
    }
}

bool ModifierRuntime::apply_pod_snapshot(const RuntimeModifierPodSnapshot &snapshot,
                                         std::string &error) {
    error.clear();
    if (!_configured) {
        error = "modifier_runtime_not_configured";
        return false;
    }
    if (snapshot.abi_version != RUNTIME_MODIFIER_POD_ABI_VERSION) {
        error = "modifier_pod_snapshot_abi_mismatch";
        return false;
    }
    if (snapshot.generation != 0 &&
        snapshot.generation <= _pod_snapshot_generation) {
        error = "modifier_pod_snapshot_generation_regression";
        return false;
    }
    for (const RuntimeModifierPodEntry &entry : snapshot.entries) {
        if (entry.domain >= DOMAIN_COUNT) {
            error = "modifier_pod_snapshot_domain_invalid";
            return false;
        }
        if (entry.scope < GLOBAL || entry.scope > ENTITY) {
            error = "modifier_pod_snapshot_scope_invalid";
            return false;
        }
        if (entry.definition_id < 0 ||
            entry.definition_id >= static_cast<int32_t>(_definitions.size())) {
            error = "modifier_pod_snapshot_definition_invalid";
            return false;
        }
    }
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets) {
        if (bucket.domain >= DOMAIN_COUNT || bucket.scope > ENTITY) {
            error = "modifier_pod_snapshot_bucket_shape_invalid";
            return false;
        }
    }

    // Build into temporaries so a mid-apply failure cannot leave a half state.
    std::array<Store, DOMAIN_COUNT> next_stores{};
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) {
        next_stores[domain].snapshot_version =
            _stores[domain].snapshot_version + 1;
        next_stores[domain].structure_epoch =
            _stores[domain].structure_epoch + 1;
        if (domain < static_cast<int32_t>(snapshot.domain_versions.size()) &&
            snapshot.domain_versions[domain] != 0) {
            next_stores[domain].snapshot_version = std::max(
                next_stores[domain].snapshot_version,
                snapshot.domain_versions[domain]);
        }
    }

    for (const RuntimeModifierPodEntry &entry : snapshot.entries) {
        if (entry.modifier_handle == 0) continue;
        Store &store = next_stores[entry.domain];
        const uint32_t index =
            static_cast<uint32_t>(entry.modifier_handle & 0xffffffffULL);
        const uint32_t generation =
            static_cast<uint32_t>(entry.modifier_handle >> 32U);
        if (generation == 0) {
            error = "modifier_pod_snapshot_handle_invalid";
            return false;
        }
        if (index >= store.active.size()) {
            const size_t grow = static_cast<size_t>(index) + 1u;
            store.active.resize(grow, 0);
            store.generation.resize(grow, 0);
            store.definition_id.resize(grow, -1);
            store.entity_handle.resize(grow, 0);
            store.group_handle.resize(grow, 0);
            store.source_type.resize(grow, 0);
            store.source_id.resize(grow, 0);
            store.scope.resize(grow, GLOBAL);
            store.stacks.resize(grow, 1);
            store.magnitude_q16.resize(grow, Q16_ONE);
            store.applied_day.resize(grow, -1);
            store.expiry_day.resize(grow, PERMANENT_EXPIRY);
            store.expiry_revision.resize(grow, 0);
        }
        if (store.active[index] != 0) {
            error = "modifier_pod_snapshot_duplicate_slot";
            return false;
        }
        store.active[index] = 1;
        store.generation[index] = generation;
        store.definition_id[index] = entry.definition_id;
        store.entity_handle[index] = entry.entity_handle;
        store.group_handle[index] = entry.group_handle;
        store.source_type[index] = entry.source_type;
        store.source_id[index] = entry.source_id;
        store.scope[index] = entry.scope;
        store.stacks[index] = entry.stacks;
        store.magnitude_q16[index] = entry.magnitude_q16;
        store.applied_day[index] = entry.applied_day;
        store.expiry_day[index] = entry.expires_day;
        store.expiry_revision[index] = 1;
        if (store.expiry_day[index] >= 0) {
            store.expiry_heap.push({store.expiry_day[index], index,
                                   store.generation[index],
                                   store.expiry_revision[index]});
        }
        const Definition &definition = _definitions[entry.definition_id];
        if (definition.policy != INDEPENDENT) {
            UniqueKey unique{entry.definition_id, entry.scope,
                             entry.scope == GROUP ? entry.group_handle
                                 : (entry.scope == ENTITY ? entry.entity_handle
                                                         : 0),
                             entry.source_type, entry.source_id};
            store.unique_instances[unique] = index;
        }
        ++store.active_instances;
        store.peak_instances =
            std::max(store.peak_instances, store.active_instances);
    }

    // Install aggregated buckets from the snapshot so evaluate_* matches the
    // worker commit even when contribution rebuild would diverge on ordering.
    for (const RuntimeModifierPodBucket &pod_bucket : snapshot.buckets) {
        Store &store = next_stores[pod_bucket.domain];
        BucketKey key{static_cast<int32_t>(pod_bucket.stat_id),
                      static_cast<int32_t>(pod_bucket.scope),
                      pod_bucket.scope_id};
        Bucket bucket;
        bucket.sum_add = pod_bucket.sum_add;
        if (pod_bucket.product_factor == 0.0) {
            bucket.zero_factor_count = 1;
            bucket.product_nonzero = 1.0;
        } else {
            bucket.zero_factor_count = 0;
            bucket.product_nonzero = pod_bucket.product_factor;
        }
        store.buckets[key] = bucket;
        bump_stat_version(store, key.stat_id);
    }

    // Swap in only after the full rebuild succeeded.
    _stores = std::move(next_stores);
    _pending_commands.clear();
    if (snapshot.committed_day >= 0)
        _current_day = snapshot.committed_day;
    _pod_snapshot_generation = snapshot.generation;
    _pod_domain_versions = snapshot.domain_versions;
    return true;
}
