Dictionary ModifierRuntime::command_result(int64_t request_id) const {
    const auto it = _results.find(request_id);
    if (it == _results.end()) return fail_dict("modifier_request_unknown");
    Dictionary out;
    out["ok"] = it->second.ok;
    out["reason"] = String(it->second.reason.c_str());
    out["modifier_handle"] = static_cast<int64_t>(it->second.handle);
    out["day"] = it->second.day;
    out["pending"] = it->second.reason == "pending";
    return out;
}

bool ModifierRuntime::command_result_pod(int64_t request_id, bool &complete,
                                         bool &ok, std::string &reason) const {
    const auto it = _results.find(request_id);
    if (it == _results.end()) {
        complete = true;
        ok = false;
        reason = "modifier_request_unknown";
        return false;
    }
    complete = it->second.reason != "pending";
    ok = it->second.ok;
    reason = it->second.reason;
    return true;
}

Dictionary ModifierRuntime::list_modifiers(int32_t domain, uint64_t entity_handle,
                                           const String &stat_key_value) const {
    if (domain < 0 || domain >= DOMAIN_COUNT) return fail_dict("modifier_domain_invalid");
    const int32_t filter_stat = stat_key_value.is_empty() ? -1 :
        stat_id(stat_key_value.utf8().get_data());
    if (!stat_key_value.is_empty() && filter_stat < 0)
        return fail_dict("modifier_stat_unknown");
    PackedInt64Array handles, entities, groups, source_types, source_ids, applied, expiry;
    PackedInt32Array scopes, stacks, versions, magnitudes;
    PackedStringArray definitions;
    const Store &store = _stores[domain];
    for (uint32_t index = 0; index < store.active.size(); ++index) {
        if (store.active[index] == 0 ||
            (entity_handle != 0 && store.entity_handle[index] != entity_handle)) continue;
        const Definition &definition = _definitions[store.definition_id[index]];
        if (filter_stat >= 0) {
            bool found = false;
            for (uint32_t t = 0; t < definition.term_count; ++t)
                found = found || _terms[definition.term_begin + t].stat_id == filter_stat;
            if (!found) continue;
        }
        handles.push_back(static_cast<int64_t>(make_handle(store, index)));
        definitions.push_back(definition.key.c_str());
        versions.push_back(definition.version);
        entities.push_back(static_cast<int64_t>(store.entity_handle[index]));
        groups.push_back(static_cast<int64_t>(store.group_handle[index]));
        source_types.push_back(static_cast<int64_t>(store.source_type[index]));
        source_ids.push_back(static_cast<int64_t>(store.source_id[index]));
        scopes.push_back(store.scope[index]);
        stacks.push_back(store.stacks[index]);
        magnitudes.push_back(store.magnitude_q16[index]);
        applied.push_back(store.applied_day[index]);
        expiry.push_back(store.expiry_day[index]);
    }
    Dictionary out;
    out["ok"] = true;
    out["handles"] = handles;
    out["definition_keys"] = definitions;
    out["definition_versions"] = versions;
    out["entity_handles"] = entities;
    out["group_handles"] = groups;
    out["source_types"] = source_types;
    out["source_ids"] = source_ids;
    out["scopes"] = scopes;
    out["stacks"] = stacks;
    out["magnitude_q16"] = magnitudes;
    out["applied_days"] = applied;
    out["expiry_days"] = expiry;
    return out;
}

Dictionary ModifierRuntime::explain(int32_t domain, uint64_t entity_handle,
                                    uint64_t group_handle, const String &stat_key_value,
                                    double base_value) const {
    const int32_t sid = stat_id(stat_key_value.utf8().get_data());
    if (sid < 0 || domain < 0 || domain >= DOMAIN_COUNT || _stats[sid].domain != domain)
        return fail_dict("modifier_stat_unknown_or_domain_mismatch");
    PackedInt64Array handles;
    PackedInt32Array scopes, stacks, magnitudes;
    PackedFloat64Array adds, factors;
    PackedStringArray definitions;
    double sum_add = 0.0, product_factor = 1.0;
    const Store &store = _stores[domain];
    for (uint32_t index = 0; index < store.active.size(); ++index) {
        if (store.active[index] == 0) continue;
        const bool in_scope = store.scope[index] == GLOBAL ||
            (store.scope[index] == GROUP && store.group_handle[index] == group_handle) ||
            (store.scope[index] == ENTITY && store.entity_handle[index] == entity_handle);
        if (!in_scope) continue;
        const Definition &definition = _definitions[store.definition_id[index]];
        for (uint32_t term_offset = 0; term_offset < definition.term_count; ++term_offset) {
            const TermDefinition &term = _terms[definition.term_begin + term_offset];
            if (term.stat_id != sid) continue;
            const double add = scaled_add(term, store.stacks[index],
                                          store.magnitude_q16[index]);
            const double factor = scaled_factor(term, store.stacks[index],
                                                store.magnitude_q16[index]);
            handles.push_back(static_cast<int64_t>(make_handle(store, index)));
            definitions.push_back(definition.key.c_str());
            scopes.push_back(store.scope[index]);
            stacks.push_back(store.stacks[index]);
            magnitudes.push_back(store.magnitude_q16[index]);
            adds.push_back(add);
            factors.push_back(factor);
            sum_add += add;
            product_factor *= factor;
        }
    }
    // ── Derived cell layer in the DECOMPOSITION, not just the total ─────────
    //
    // The walk above iterates `store.active` only, so `sum_add` / `product_factor`
    // describe the LEGACY contributions. `effective_value` below also merges the derived
    // cell layer (`:1462-1479`). Before this fix the same Dictionary therefore reported
    // `effective_value = 1.05` beside `sum_add = 0`, `product_factor = 1` and
    // `unclamped_value = 1.0` -- a decomposition that explained the total as "nothing".
    // Measured by the reader-consistency fixture: the gap equalled the derived add to
    // 1e-12.
    //
    // The term is merged with the SAME arithmetic and the SAME §5.5 zero-factor rule as
    // `effective_value`, and it is reported separately as well, so a consumer can say
    // "the cell layer added 0.05" instead of folding it into the legacy numbers.
    double derived_add = 0.0;
    double derived_factor = 1.0;
    bool derived_present = false;
    if (domain == ECONOMY && !_derived_cell_front.rows.empty()) {
        const DerivedCellStatRow *derived_row = _derived_cell_front.row_for_stat(sid);
        if (derived_row != nullptr) {
            const DerivedCellContribution *slot =
                derived_row->find(static_cast<int32_t>(group_handle));
            if (slot != nullptr) {
                derived_present = true;
                derived_add = slot->sum_add;
                derived_factor = slot->zero_factor_count > 0 ? 0.0 : slot->product_nonzero;
            }
        }
    }
    const double total_add = sum_add + derived_add;
    const double total_factor = product_factor * derived_factor;

    Dictionary out;
    out["ok"] = true;
    out["stat_key"] = stat_key_value;
    out["base_value"] = base_value;
    out["sum_add"] = total_add;
    out["product_factor"] = total_factor;
    out["unclamped_value"] = (base_value + total_add) * total_factor;
    out["effective_value"] = effective_value(domain, sid, entity_handle, group_handle, base_value);
    // The derived slice, on its own. `derived_present` distinguishes "the layer has no
    // row for this cell" from "the layer contributed zero", which a bare 0.0 cannot.
    out["derived_present"] = derived_present ? 1 : 0;
    out["derived_add"] = derived_add;
    out["derived_factor"] = derived_factor;
    out["clamp_min"] = _stats[sid].min_value;
    out["clamp_max"] = _stats[sid].max_value;
    out["handles"] = handles;
    out["definition_keys"] = definitions;
    out["scopes"] = scopes;
    out["stacks"] = stacks;
    out["magnitude_q16"] = magnitudes;
    out["adds"] = adds;
    out["factors"] = factors;
    return out;
}

uint64_t ModifierRuntime::estimated_store_bytes(int32_t domain) const {
    if (domain < 0 || domain >= DOMAIN_COUNT) return 0;
    const Store &store = _stores[domain];
    uint64_t bytes = 0;
#define PK_CAPACITY_BYTES(field) bytes += static_cast<uint64_t>(store.field.capacity()) * sizeof(typename decltype(store.field)::value_type)
    PK_CAPACITY_BYTES(active);
    PK_CAPACITY_BYTES(generation);
    PK_CAPACITY_BYTES(definition_id);
    PK_CAPACITY_BYTES(entity_handle);
    PK_CAPACITY_BYTES(group_handle);
    PK_CAPACITY_BYTES(source_type);
    PK_CAPACITY_BYTES(source_id);
    PK_CAPACITY_BYTES(scope);
    PK_CAPACITY_BYTES(stacks);
    PK_CAPACITY_BYTES(magnitude_q16);
    PK_CAPACITY_BYTES(applied_day);
    PK_CAPACITY_BYTES(expiry_day);
    PK_CAPACITY_BYTES(expiry_revision);
    PK_CAPACITY_BYTES(free_list);
#undef PK_CAPACITY_BYTES
    bytes += static_cast<uint64_t>(store.expiry_heap.size()) * sizeof(ExpiryNode);
    bytes += static_cast<uint64_t>(store.unique_instances.size()) *
        (sizeof(UniqueKey) + sizeof(uint32_t) + sizeof(void *) * 2);
    bytes += static_cast<uint64_t>(store.buckets.size()) *
        (sizeof(BucketKey) + sizeof(Bucket) + sizeof(void *) * 2);
    for (const auto &entry : store.buckets)
        bytes += static_cast<uint64_t>(entry.second.members.capacity()) * sizeof(Contribution);
    const IdentityStore *identities = domain == ECONOMY ? &_building_identities :
        (domain == GAMEPLAY ? &_gameplay_identities : nullptr);
    if (identities != nullptr) {
        bytes += identities->active.capacity() * sizeof(uint8_t);
        bytes += identities->generation.capacity() * sizeof(uint32_t);
        bytes += identities->labels.capacity() * sizeof(std::string);
        bytes += identities->free_list.capacity() * sizeof(uint32_t);
        for (const std::string &label : identities->labels) bytes += label.capacity();
    }
    if (domain == GAMEPLAY) {
        bytes += _gameplay_base_by_stat.capacity() * sizeof(std::vector<double>);
        for (const std::vector<double> &values : _gameplay_base_by_stat)
            bytes += values.capacity() * sizeof(double);
    }
    return bytes;
}

void ModifierRuntime::record_error(const std::string &reason) const {
    if (!reason.empty()) ++_error_counts[reason];
}

Dictionary ModifierRuntime::report() const {
    Dictionary out;
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["current_day"] = _current_day;
    out["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    out["commands_applied_total"] = static_cast<int64_t>(_commands_applied);
    out["commands_rejected_total"] = static_cast<int64_t>(_commands_rejected);
    out["expired_total"] = static_cast<int64_t>(_expired);
    // ── Derived cell layer identity (plan 7.4) ──────────────────────────────
    //
    // These were missing entirely: `get_modifier_report()` could not witness the derived
    // front at all, so a diagnostic reader had no way to tell "the layer is installed at
    // generation N" from "there is no layer". The reader-consistency fixture measured that
    // absence (M5-71, finding N3); the only proxy was
    // `modifier_stat_bucket_version()`, which mixes the generation into a hash.
    //
    // `layer_installed` is reported as 0/1 rather than a bool because every other field in
    // this Dictionary is an integer.
    //
    // `layer_stat_versions_bytes` reports the SIZE of the per-stat version vector, not the
    // vector: it is sized by the stat-id space, which is not what a reader wants to see.
    {
        int64_t layer_contributions = 0;
        for (const DerivedCellStatRow &row : _derived_cell_front.rows)
            layer_contributions += static_cast<int64_t>(row.contributions.size());
        out["layer_installed"] = _derived_cell_front.rows.empty() ? 0 : 1;
        out["layer_generation"] = static_cast<int64_t>(_derived_layer_generation);
        out["layer_stat_count"] = static_cast<int64_t>(_derived_cell_front.rows.size());
        out["layer_contribution_count"] = layer_contributions;
        out["layer_stat_versions_bytes"] = static_cast<int64_t>(
            _derived_cell_front.stat_versions.size() *
            static_cast<size_t>(sizeof(uint64_t)));
    }
    out["journal_overflow"] = static_cast<int64_t>(_journal_overflow);
    out["journal_version"] = 2;
    out["command_merge_ms"] = _last_command_ms;
    out["expiry_ms"] = _last_expiry_ms;
    out["snapshot_publish_ms"] = _last_publish_ms;
    out["bucket_update_ms"] = _last_bucket_update_ms;
    out["bucket_rebuild_ms"] = _last_bucket_rebuild_ms;
    out["bucket_update_ms_total"] = _bucket_update_ms_total;
    out["bucket_rebuild_ms_total"] = _bucket_rebuild_ms_total;
    PackedInt64Array active, peak, buckets, queries, bucket_reads, rebuilds, versions,
        apply_events, remove_events, expire_events, reject_events, cleanup_events,
        estimated_memory;
    for (const Store &store : _stores) {
        active.push_back(static_cast<int64_t>(store.active_instances));
        peak.push_back(static_cast<int64_t>(store.peak_instances));
        buckets.push_back(static_cast<int64_t>(store.buckets.size()));
        queries.push_back(static_cast<int64_t>(store.query_count));
        bucket_reads.push_back(static_cast<int64_t>(store.bucket_reads));
        rebuilds.push_back(static_cast<int64_t>(store.bucket_rebuilds));
        versions.push_back(static_cast<int64_t>(store.snapshot_version));
        apply_events.push_back(static_cast<int64_t>(store.apply_events));
        remove_events.push_back(static_cast<int64_t>(store.remove_events));
        expire_events.push_back(static_cast<int64_t>(store.expire_events));
        reject_events.push_back(static_cast<int64_t>(store.reject_events));
        cleanup_events.push_back(static_cast<int64_t>(store.target_cleanup_events));
    }
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain)
        estimated_memory.push_back(static_cast<int64_t>(estimated_store_bytes(domain)));
    out["active_instances_by_domain"] = active;
    out["peak_instances_by_domain"] = peak;
    out["bucket_count_by_domain"] = buckets;
    out["query_count_by_domain"] = queries;
    out["bucket_reads_by_domain"] = bucket_reads;
    out["bucket_rebuilds_by_domain"] = rebuilds;
    out["snapshot_versions"] = versions;
    out["apply_events_by_domain"] = apply_events;
    out["remove_events_by_domain"] = remove_events;
    out["expire_events_by_domain"] = expire_events;
    out["reject_events_by_domain"] = reject_events;
    out["target_cleanup_events_by_domain"] = cleanup_events;
    out["estimated_memory_bytes_by_domain"] = estimated_memory;
    std::vector<std::pair<std::string, uint64_t>> errors(_error_counts.begin(),
                                                         _error_counts.end());
    std::sort(errors.begin(), errors.end(), [](const auto &a, const auto &b) {
        return a.first < b.first;
    });
    PackedStringArray error_reasons;
    PackedInt64Array error_counts;
    for (const auto &entry : errors) {
        error_reasons.push_back(entry.first.c_str());
        error_counts.push_back(static_cast<int64_t>(entry.second));
    }
    out["error_reasons"] = error_reasons;
    out["error_counts"] = error_counts;
    return out;
}

Dictionary ModifierRuntime::poll_events(int64_t after_event_id, int32_t limit) const {
    limit = std::clamp(limit, 1, 512);
    PackedInt64Array ids, days, handles, entities, groups, source_types, source_ids, requests;
    PackedInt32Array kinds, domains, scopes, old_stacks, new_stacks,
        old_magnitudes, new_magnitudes;
    PackedStringArray definitions, reasons;
    for (const Event &event : _events) {
        if (event.id <= after_event_id || ids.size() >= limit) continue;
        ids.push_back(event.id);
        days.push_back(event.day);
        kinds.push_back(event.kind);
        domains.push_back(event.domain);
        handles.push_back(static_cast<int64_t>(event.handle));
        entities.push_back(static_cast<int64_t>(event.entity_handle));
        groups.push_back(static_cast<int64_t>(event.group_handle));
        scopes.push_back(event.scope);
        source_types.push_back(static_cast<int64_t>(event.source_type));
        source_ids.push_back(static_cast<int64_t>(event.source_id));
        requests.push_back(event.request_id);
        old_stacks.push_back(event.old_stacks);
        new_stacks.push_back(event.new_stacks);
        old_magnitudes.push_back(event.old_magnitude_q16);
        new_magnitudes.push_back(event.new_magnitude_q16);
        definitions.push_back(event.definition_id >= 0 &&
            event.definition_id < static_cast<int32_t>(_definitions.size())
                ? _definitions[event.definition_id].key.c_str() : "");
        reasons.push_back(event.reason.c_str());
    }
    Dictionary out;
    out["ok"] = true;
    out["journal_version"] = 2;
    out["event_ids"] = ids;
    out["days"] = days;
    out["kinds"] = kinds;
    out["domains"] = domains;
    out["modifier_handles"] = handles;
    out["entity_handles"] = entities;
    out["group_handles"] = groups;
    out["scopes"] = scopes;
    out["source_types"] = source_types;
    out["source_ids"] = source_ids;
    out["request_ids"] = requests;
    out["old_stacks"] = old_stacks;
    out["new_stacks"] = new_stacks;
    out["old_magnitude_q16"] = old_magnitudes;
    out["new_magnitude_q16"] = new_magnitudes;
    out["definition_keys"] = definitions;
    out["reasons"] = reasons;
    out["journal_overflow"] = static_cast<int64_t>(_journal_overflow);
    return out;
}
