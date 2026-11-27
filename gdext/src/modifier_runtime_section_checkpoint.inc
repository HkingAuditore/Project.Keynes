void ModifierRuntime::clear_domain(int32_t domain) {
    if (domain < 0 || domain >= DOMAIN_COUNT) return;
    // Caches keyed on the snapshot version treat equality as "nothing changed",
    // so a cleared store continues the previous sequence instead of restarting.
    const uint64_t previous_version = _stores[domain].snapshot_version;
    const uint64_t previous_epoch = _stores[domain].structure_epoch;
    _stores[domain] = Store{};
    _stores[domain].snapshot_version = previous_version + 1;
    _stores[domain].structure_epoch = previous_epoch + 1;
    if (domain == ECONOMY) {
        _building_identities = IdentityStore{};
        _building_handles.clear();
    } else if (domain == GAMEPLAY) {
        _gameplay_identities = IdentityStore{};
        _person_targets.clear();
        for (std::vector<double> &values : _gameplay_base_by_stat) values.clear();
    }
}

bool ModifierRuntime::serialize_domain(int32_t domain, std::vector<uint8_t> &out,
                                       std::string &error) const {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT) {
        error = "modifier_save_domain_invalid";
        return false;
    }
    out.clear();
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, SAVE_SCHEMA_VERSION);
    append_le<int32_t>(out, domain);
    append_le<uint64_t>(out, _catalog_hash);
    append_le<int64_t>(out, _current_day);
    const Store &store = _stores[domain];
    append_le<uint64_t>(out, _pod_snapshot_generation != 0 ? _pod_domain_versions[domain] : store.snapshot_version);
    append_le<uint64_t>(out, store.active_instances);
    for (uint32_t index = 0; index < store.active.size(); ++index) {
        if (store.active[index] == 0) continue;
        const Definition &definition = _definitions[store.definition_id[index]];
        append_le<uint64_t>(out, make_handle(store, index));
        append_string(out, definition.key);
        append_le<int32_t>(out, definition.version);
        append_le<uint64_t>(out, store.entity_handle[index]);
        append_le<uint64_t>(out, store.group_handle[index]);
        append_le<uint64_t>(out, store.source_type[index]);
        append_le<uint64_t>(out, store.source_id[index]);
        append_le<int32_t>(out, store.scope[index]);
        append_le<int32_t>(out, store.stacks[index]);
        append_le<int32_t>(out, store.magnitude_q16[index]);
        append_le<int64_t>(out, store.applied_day[index]);
        append_le<int64_t>(out, store.expiry_day[index]);
        append_le<uint32_t>(out, definition.term_count);
        for (uint32_t t = 0; t < definition.term_count; ++t) {
            const TermDefinition &term = _terms[definition.term_begin + t];
            append_string(out, _stats[term.stat_id].key);
            append_le<double>(out, term.add);
            append_le<double>(out, term.factor);
        }
    }
    const IdentityStore *identities = domain == ECONOMY ? &_building_identities :
        (domain == GAMEPLAY ? &_gameplay_identities : nullptr);
    append_le<uint64_t>(out, identities == nullptr ? 0 : identities->active.size());
    if (identities != nullptr) {
        for (size_t i = 0; i < identities->active.size(); ++i) {
            append_le<uint8_t>(out, identities->active[i]);
            append_le<uint32_t>(out, identities->generation[i]);
            append_string(out, identities->labels[i]);
        }
    }
    if (domain == GAMEPLAY) {
        append_le<uint64_t>(out, _stats.size());
        for (size_t sid = 0; sid < _stats.size(); ++sid) {
            append_string(out, _stats[sid].key);
            append_le<uint64_t>(out, _gameplay_base_by_stat[sid].size());
            for (double value : _gameplay_base_by_stat[sid]) append_le<double>(out, value);
        }
    }
    append_le<uint32_t>(out, SAVE_END);
    return true;
}

bool ModifierRuntime::restore_domain(int32_t domain, const std::vector<uint8_t> &bytes,
                                     std::string &error,
                                     bool allow_tax_catalog_extension) {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT) {
        error = "modifier_restore_domain_invalid";
        return false;
    }
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, end = 0;
    int32_t saved_domain = -1;
    uint64_t saved_catalog = 0, snapshot_version = 0, count = 0;
    int64_t saved_day = -1;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version) ||
        !read_le(bytes, cursor, saved_domain) || !read_le(bytes, cursor, saved_catalog) ||
        !read_le(bytes, cursor, saved_day) || !read_le(bytes, cursor, snapshot_version) ||
        !read_le(bytes, cursor, count)) {
        error = "modifier_restore_header_truncated";
        return false;
    }
    // One reason per condition. The old single `modifier_restore_header_invalid`
    // covered all of them, so "save written by a different modifier catalog"
    // was indistinguishable from "file is garbage" and every audit started in
    // the wrong place.
    if (magic != SAVE_MAGIC) {
        error = "modifier_restore_magic_invalid";
        return false;
    }
    if (version != SAVE_SCHEMA_VERSION) {
        error = "modifier_restore_schema_unsupported";
        return false;
    }
    if (saved_domain != domain) {
        error = "modifier_restore_domain_mismatch";
        return false;
    }
    if (saved_catalog != _catalog_hash &&
        (!allow_tax_catalog_extension ||
         saved_catalog != _legacy_catalog_hash_without_tax)) {
        error = "modifier_restore_catalog_mismatch";
        return false;
    }
    if (count > 10000000ULL) {
        error = "modifier_restore_instance_count_invalid";
        return false;
    }
    struct SavedInstance {
        uint64_t handle = 0, entity = 0, group = 0, source_type = 0, source_id = 0;
        int32_t definition = -1, scope = 0, stacks = 1, magnitude_q16 = Q16_ONE;
        int64_t applied = -1, expiry = -1;
    };
    std::vector<SavedInstance> saved;
    saved.reserve(static_cast<size_t>(count));
    uint32_t max_index = 0;
    for (uint64_t i = 0; i < count; ++i) {
        SavedInstance item;
        std::string definition_key;
        int32_t definition_version = 0;
        uint32_t term_count = 0;
        if (!read_le(bytes, cursor, item.handle) ||
            !read_string(bytes, cursor, definition_key) ||
            !read_le(bytes, cursor, definition_version) ||
            !read_le(bytes, cursor, item.entity) || !read_le(bytes, cursor, item.group) ||
            !read_le(bytes, cursor, item.source_type) || !read_le(bytes, cursor, item.source_id) ||
            !read_le(bytes, cursor, item.scope) || !read_le(bytes, cursor, item.stacks) ||
            !read_le(bytes, cursor, item.magnitude_q16) ||
            !read_le(bytes, cursor, item.applied) || !read_le(bytes, cursor, item.expiry) ||
            !read_le(bytes, cursor, term_count)) {
            error = "modifier_restore_instance_truncated";
            return false;
        }
        item.definition = definition_id(definition_key);
        if (item.definition < 0 || _definitions[item.definition].version != definition_version ||
            _definitions[item.definition].domain != domain ||
            term_count != _definitions[item.definition].term_count || item.stacks <= 0 ||
            item.stacks > _definitions[item.definition].max_stacks ||
            item.magnitude_q16 < 0 || item.magnitude_q16 > MAX_MAGNITUDE_Q16) {
            error = "modifier_restore_definition_incompatible";
            return false;
        }
        for (uint32_t t = 0; t < term_count; ++t) {
            std::string stat_key_value;
            double add = 0.0, factor = 1.0;
            if (!read_string(bytes, cursor, stat_key_value) || !read_le(bytes, cursor, add) ||
                !read_le(bytes, cursor, factor)) {
                error = "modifier_restore_term_truncated";
                return false;
            }
            const TermDefinition &expected = _terms[_definitions[item.definition].term_begin + t];
            if (stat_id(stat_key_value) != expected.stat_id || add != expected.add ||
                factor != expected.factor) {
                error = "modifier_restore_term_incompatible";
                return false;
            }
        }
        const uint32_t index = static_cast<uint32_t>(item.handle & 0xffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(item.handle >> 32U);
        if (generation == 0) { error = "modifier_restore_handle_invalid"; return false; }
        max_index = std::max(max_index, index);
        saved.push_back(item);
    }

    IdentityStore identities;
    uint64_t identity_count = 0;
    if (!read_le(bytes, cursor, identity_count) || identity_count > 10000000ULL) {
        error = "modifier_restore_identity_count_invalid";
        return false;
    }
    identities.active.resize(static_cast<size_t>(identity_count));
    identities.generation.resize(static_cast<size_t>(identity_count));
    identities.labels.resize(static_cast<size_t>(identity_count));
    for (size_t i = 0; i < identity_count; ++i) {
        if (!read_le(bytes, cursor, identities.active[i]) ||
            !read_le(bytes, cursor, identities.generation[i]) ||
            !read_string(bytes, cursor, identities.labels[i]) ||
            identities.generation[i] == 0) {
            error = "modifier_restore_identity_invalid";
            return false;
        }
        if (identities.active[i] == 0) identities.free_list.push_back(static_cast<uint32_t>(i));
    }
    std::vector<std::vector<double>> gameplay_values;
    if (domain == GAMEPLAY) {
        uint64_t stat_count = 0;
        if (!read_le(bytes, cursor, stat_count) || stat_count != _stats.size()) {
            error = "modifier_restore_gameplay_stat_count_invalid";
            return false;
        }
        gameplay_values.resize(_stats.size());
        for (size_t sid = 0; sid < _stats.size(); ++sid) {
            std::string key;
            uint64_t value_count = 0;
            if (!read_string(bytes, cursor, key) || key != _stats[sid].key ||
                !read_le(bytes, cursor, value_count) || value_count > 10000000ULL) {
                error = "modifier_restore_gameplay_stat_invalid";
                return false;
            }
            gameplay_values[sid].resize(static_cast<size_t>(value_count));
            for (double &value : gameplay_values[sid])
                if (!read_le(bytes, cursor, value) || !std::isfinite(value)) {
                    error = "modifier_restore_gameplay_value_invalid";
                    return false;
                }
        }
    }
    if (!read_le(bytes, cursor, end) || end != SAVE_END || cursor != bytes.size()) {
        error = "modifier_restore_end_invalid";
        return false;
    }

    clear_domain(domain);
    Store &store = _stores[domain];
    const size_t slots = saved.empty() ? 0 : static_cast<size_t>(max_index) + 1;
    store.active.assign(slots, 0);
    store.generation.assign(slots, 1);
    store.definition_id.assign(slots, -1);
    store.entity_handle.assign(slots, 0);
    store.group_handle.assign(slots, 0);
    store.source_type.assign(slots, 0);
    store.source_id.assign(slots, 0);
    store.scope.assign(slots, GLOBAL);
    store.stacks.assign(slots, 1);
    store.magnitude_q16.assign(slots, Q16_ONE);
    store.applied_day.assign(slots, -1);
    store.expiry_day.assign(slots, PERMANENT_EXPIRY);
    store.expiry_revision.assign(slots, 0);
    std::set<uint32_t> occupied;
    for (const SavedInstance &item : saved) {
        const uint32_t index = static_cast<uint32_t>(item.handle & 0xffffffffULL);
        if (!occupied.insert(index).second) { error = "modifier_restore_duplicate_slot"; return false; }
        store.active[index] = 1;
        store.generation[index] = static_cast<uint32_t>(item.handle >> 32U);
        store.definition_id[index] = item.definition;
        store.entity_handle[index] = item.entity;
        store.group_handle[index] = item.group;
        store.source_type[index] = item.source_type;
        store.source_id[index] = item.source_id;
        store.scope[index] = item.scope;
        store.stacks[index] = item.stacks;
        store.magnitude_q16[index] = item.magnitude_q16;
        store.applied_day[index] = item.applied;
        store.expiry_day[index] = item.expiry;
        store.expiry_revision[index] = 1;
        const Definition &definition = _definitions[item.definition];
        if (definition.policy != INDEPENDENT) {
            const uint64_t sid = item.scope == GLOBAL ? 0 :
                (item.scope == GROUP ? item.group : item.entity);
            if (!store.unique_instances.emplace(UniqueKey{item.definition, item.scope,
                    sid, item.source_type, item.source_id}, index).second) {
                error = "modifier_restore_unique_collision";
                return false;
            }
        }
        add_instance_to_buckets(domain, index);
        if (item.expiry >= 0) store.expiry_heap.push({item.expiry, index,
            store.generation[index], store.expiry_revision[index]});
    }
    for (uint32_t index = 0; index < slots; ++index)
        if (store.active[index] == 0) store.free_list.push_back(index);
    store.active_instances = saved.size();
    store.peak_instances = saved.size();
    store.snapshot_version = std::max(store.snapshot_version, snapshot_version + 1);
    if (domain == ECONOMY) {
        _building_identities = std::move(identities);
        _building_handles.clear();
        for (size_t i = 0; i < _building_identities.active.size(); ++i) {
            if (_building_identities.active[i] == 0) continue;
            int cell = -1, type = -1, owner = -1;
            if (std::sscanf(_building_identities.labels[i].c_str(), "%d:%d:%d", &cell, &type, &owner) == 3)
                _building_handles[{cell, type, owner}] =
                    (static_cast<uint64_t>(_building_identities.generation[i]) << 32U) | i;
        }
    } else if (domain == GAMEPLAY) {
        _gameplay_identities = std::move(identities);
        _gameplay_base_by_stat = std::move(gameplay_values);
    }
    _current_day = std::max(_current_day, saved_day);
    return true;
}
