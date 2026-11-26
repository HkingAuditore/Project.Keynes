bool RuntimeModifierPodAuthority::apply_command(
        State &state, const RuntimeModifierPodCommand &command, int64_t day,
        RuntimeDomainAck &ack, bool &changed, std::string &error) {
    const auto &definition = _catalog.definitions[static_cast<size_t>(command.definition_id)];
    DomainState &domain = state.domains[command.domain];
    const int32_t duration = command.duration_days == -2
        ? definition.default_duration : command.duration_days;
    if (duration != -1 && duration <= 0) { error = "modifier_pod_duration_invalid"; return false; }
    const uint64_t wanted_scope = scope_id(command);
    size_t existing = domain.entries.size();
    if (definition.policy != POLICY_INDEPENDENT) {
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            const auto &entry = domain.entries[i];
            if (entry.modifier_handle != 0 && entry.definition_id == command.definition_id &&
                entry.scope == command.scope && scope_id(entry) == wanted_scope &&
                entry.source_type == command.source_type && entry.source_id == command.source_id) {
                existing = i;
                break;
            }
        }
    }
    if (existing < domain.entries.size()) {
        auto &entry = domain.entries[existing];
        if (command.target_generation != 0 &&
            command.target_generation != entry.target_generation) {
            error = "modifier_pod_stale_generation";
            return false;
        }
        if (definition.policy == POLICY_STACK_REFRESH)
            entry.stacks = std::min(definition.max_stacks, entry.stacks + command.stacks);
        else
            entry.stacks = command.stacks;
        entry.magnitude_q16 = command.magnitude_q16;
        entry.value_q16 = command.magnitude_q16;
        entry.applied_day = day;
        entry.expires_day = duration < 0 ? -1 : day + duration;
        ++domain.version;
        changed = true;
        return true;
    }
    uint32_t slot = 0;
    if (!domain.free_indices.empty()) {
        slot = domain.free_indices.back();
        domain.free_indices.pop_back();
        if (++domain.handle_generations[slot] == 0) domain.handle_generations[slot] = 1;
    } else {
        slot = static_cast<uint32_t>(domain.entries.size());
        domain.handle_generations.push_back(1);
        domain.entries.emplace_back();
    }
    auto &entry = domain.entries[slot];
    entry = RuntimeModifierPodEntry{};
    entry.domain = command.domain;
    entry.modifier_handle = (static_cast<uint64_t>(domain.handle_generations[slot]) << 32u) | slot;
    entry.target_handle = command.entity_handle;
    entry.target_generation = command.target_generation;
    entry.definition_id = command.definition_id;
    entry.scope = command.scope;
    entry.entity_handle = command.entity_handle;
    entry.group_handle = command.group_handle;
    entry.source_type = command.source_type;
    entry.source_id = command.source_id;
    entry.stacks = command.stacks;
    entry.magnitude_q16 = command.magnitude_q16;
    entry.value_q16 = command.magnitude_q16;
    entry.applied_day = day;
    entry.expires_day = duration < 0 ? -1 : day + duration;
    ++domain.version;
    changed = true;
    return true;
}

bool RuntimeModifierPodAuthority::remove_entry(
        State &state, const RuntimeModifierPodCommand &command, int64_t day,
        RuntimeDomainAck &ack, bool &changed, std::string &error) {
    DomainState &domain = state.domains[command.domain];
    size_t index = 0;
    if (command.modifier_handle != 0) {
        if (!resolve_entry(domain, command.modifier_handle, index)) {
            error = "modifier_pod_stale_generation";
            return false;
        }
    } else {
        if (command.definition_id < 0 ||
            command.definition_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "modifier_pod_definition_unknown";
            return false;
        }
        const uint64_t wanted_scope = scope_id(command);
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            const auto &entry = domain.entries[i];
            if (entry.modifier_handle != 0 && entry.definition_id == command.definition_id &&
                entry.scope == command.scope && scope_id(entry) == wanted_scope &&
                entry.source_type == command.source_type && entry.source_id == command.source_id) {
                index = i;
                break;
            }
        }
        if (index >= domain.entries.size() || domain.entries[index].modifier_handle == 0) {
            changed = false;
            return true;
        }
    }
    auto &entry = domain.entries[index];
    if (command.target_generation != 0 &&
        command.target_generation != entry.target_generation) {
        error = "modifier_pod_stale_generation";
        return false;
    }
    entry.modifier_handle = 0;
    entry.target_handle = 0;
    domain.free_indices.push_back(static_cast<uint32_t>(index));
    ++domain.version;
    changed = true;
    (void)day;
    return true;
}

void RuntimeModifierPodAuthority::rebuild_buckets(
        const State &state, std::vector<RuntimeModifierPodBucket> &out) const {
    out.clear();
    struct Key {
        uint16_t domain = 0;
        uint16_t scope = 0;
        uint32_t stat = 0;
        uint64_t id = 0;
        bool operator==(const Key &other) const {
            return domain == other.domain && scope == other.scope && stat == other.stat && id == other.id;
        }
    };
    struct KeyHash {
        size_t operator()(const Key &key) const noexcept {
            uint64_t value = key.domain;
            value = value * 1315423911ull + key.scope;
            value = value * 1315423911ull + key.stat;
            value = value * 1315423911ull + key.id;
            return static_cast<size_t>(value);
        }
    };
    std::unordered_map<Key, RuntimeModifierPodBucket, KeyHash> map;
    // Per-(bucket, source) add, only for the non-SUM policies. Keyed off the same
    // identity the main runtime uses, so the two aggregate identically.
    std::unordered_map<Key, std::vector<std::pair<uint64_t, double>>, KeyHash> by_source;
    for (size_t d = 0; d < state.domains.size(); ++d) {
        const DomainState &domain = state.domains[d];
        for (const auto &entry : domain.entries) {
            if (entry.modifier_handle == 0 || entry.definition_id < 0 ||
                entry.definition_id >= static_cast<int32_t>(_catalog.definitions.size())) continue;
            const auto &definition = _catalog.definitions[static_cast<size_t>(entry.definition_id)];
            const double magnitude = static_cast<double>(entry.magnitude_q16) / Q16_ONE;
            const uint64_t id = scope_id(entry);
            for (uint32_t i = 0; i < definition.term_count; ++i) {
                const auto &term = _catalog.terms[definition.term_begin + i];
                const Key key{static_cast<uint16_t>(d), static_cast<uint16_t>(entry.scope),
                              static_cast<uint32_t>(term.stat_id), id};
                auto &bucket = map[key];
                bucket.domain = key.domain;
                bucket.scope = key.scope;
                bucket.stat_id = key.stat;
                bucket.scope_id = key.id;
                const double add = term.add * entry.stacks * magnitude;
                const int32_t policy = term.stat_id >= 0 &&
                        term.stat_id < static_cast<int32_t>(_catalog.stats.size())
                    ? _catalog.stats[static_cast<size_t>(term.stat_id)].aggregate_policy : 0;
                if (policy == 0) {
                    bucket.sum_add += add;
                } else {
                    const uint64_t identity =
                        entry.source_type * 0x9e3779b97f4a7c15ULL ^ entry.source_id;
                    auto &rows = by_source[key];
                    bool merged = false;
                    for (auto &row : rows) {
                        if (row.first == identity) { row.second += add; merged = true; break; }
                    }
                    if (!merged) rows.emplace_back(identity, add);
                }
                const double factor = simulation_math::pow(1.0 + (term.factor - 1.0) * magnitude,
                                               static_cast<double>(entry.stacks));
                bucket.product_factor *= factor;
                ++bucket.active_count;
            }
        }
    }
    // Fold the per-source rows into sum_add. Done after the sweep so the map is
    // not mutated while it is being iterated for insertion.
    for (const auto &pair : by_source) {
        auto bucket_it = map.find(pair.first);
        if (bucket_it == map.end()) continue;
        const int32_t stat_id = static_cast<int32_t>(pair.first.stat);
        const auto &stat = _catalog.stats[static_cast<size_t>(stat_id)];
        std::vector<std::pair<uint64_t, double>> rows = pair.second;
        double total = 0.0;
        if (stat.aggregate_policy == 1) {
            bool has_best = false;
            for (const auto &row : rows) {
                if (!has_best || row.second > total) { total = row.second; has_best = true; }
            }
        } else {
            std::sort(rows.begin(), rows.end(),
                [](const std::pair<uint64_t, double> &lhs,
                   const std::pair<uint64_t, double> &rhs) {
                    return lhs.second > rhs.second;
                });
            const size_t keep = stat.source_cap <= 0
                ? rows.size() : std::min(rows.size(), static_cast<size_t>(stat.source_cap));
            for (size_t index = 0; index < keep; ++index) total += rows[index].second;
        }
        bucket_it->second.sum_add = total;
    }
    out.reserve(map.size());
    for (const auto &pair : map) out.push_back(pair.second);
    std::sort(out.begin(), out.end(), [](const auto &a, const auto &b) {
        if (a.domain != b.domain) return a.domain < b.domain;
        if (a.scope != b.scope) return a.scope < b.scope;
        if (a.stat_id != b.stat_id) return a.stat_id < b.stat_id;
        return a.scope_id < b.scope_id;
    });
}

uint64_t RuntimeModifierPodAuthority::state_hash(const State &state) const {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, state.generation);
    hash = hash_value(hash, state.committed_day);
    for (size_t d = 0; d < state.domains.size(); ++d) {
        const DomainState &domain = state.domains[d];
        hash = hash_value(hash, static_cast<uint16_t>(d));
        hash = hash_value(hash, domain.version);
        hash = hash_value(hash, static_cast<uint64_t>(domain.entries.size()));
        hash = hash_value(hash, static_cast<uint64_t>(domain.handle_generations.size()));
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            hash = hash_value(hash, static_cast<uint32_t>(i));
            const uint32_t generation = i < domain.handle_generations.size()
                ? domain.handle_generations[i] : 0;
            hash = hash_value(hash, generation);
            const auto &entry = domain.entries[i];
            hash = hash_value(hash, entry.modifier_handle);
            if (entry.modifier_handle == 0) continue;
            hash = hash_value(hash, entry.target_handle);
            hash = hash_value(hash, entry.target_generation);
            hash = hash_value(hash, entry.definition_id);
            hash = hash_value(hash, entry.scope);
            hash = hash_value(hash, entry.entity_handle);
            hash = hash_value(hash, entry.group_handle);
            hash = hash_value(hash, entry.source_type);
            hash = hash_value(hash, entry.source_id);
            hash = hash_value(hash, entry.stacks);
            hash = hash_value(hash, entry.magnitude_q16);
            hash = hash_value(hash, entry.applied_day);
            hash = hash_value(hash, entry.expires_day);
        }
        hash = hash_value(hash, static_cast<uint64_t>(domain.free_indices.size()));
        for (const uint32_t index : domain.free_indices) hash = hash_value(hash, index);
        hash = hash_value(hash, static_cast<uint64_t>(domain.expiry_queue.size()));
        for (const uint32_t index : domain.expiry_queue) hash = hash_value(hash, index);
    }
    return hash;
}

void RuntimeModifierPodAuthority::build_snapshot(
        const State &state, RuntimeModifierPodSnapshot &out) const {
    out = RuntimeModifierPodSnapshot{};
    out.abi_version = RUNTIME_MODIFIER_POD_ABI_VERSION;
    out.catalog_hash = _catalog.catalog_hash;
    out.generation = state.generation;
    out.committed_day = state.committed_day;
    out.state_hash = state_hash(state);
    for (size_t i = 0; i < state.domains.size(); ++i) {
        out.domain_versions[i] = state.domains[i].version;
        for (const auto &entry : state.domains[i].entries) {
            if (entry.modifier_handle == 0) continue;
            RuntimeModifierPodEntry copy = entry;
            copy.domain = static_cast<uint16_t>(i);
            out.entries.push_back(copy);
        }
    }
    std::sort(out.entries.begin(), out.entries.end(), [](const auto &a, const auto &b) {
        if (a.domain != b.domain) return a.domain < b.domain;
        if (a.modifier_handle != b.modifier_handle) return a.modifier_handle < b.modifier_handle;
        if (a.definition_id != b.definition_id) return a.definition_id < b.definition_id;
        return a.scope < b.scope;
    });
    rebuild_buckets(state, out.buckets);
}

void RuntimeModifierPodAuthority::set_error(RuntimeModifierPodReport &report,
                                             const char *reason) const {
    runtime_copy_text(report.fallback_reason, reason != nullptr ? reason : "modifier_pod_failed");
    report.completed = 0;
    report.preflight_ok = 0;
}
