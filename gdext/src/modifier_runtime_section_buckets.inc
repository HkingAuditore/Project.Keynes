uint64_t ModifierRuntime::make_handle(const Store &store, uint32_t index) const {
    return (static_cast<uint64_t>(store.generation[index]) << 32U) | index;
}

bool ModifierRuntime::resolve_handle(const Store &store, uint64_t handle,
                                     uint32_t &index) const {
    index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return index < store.active.size() && store.active[index] != 0 && generation != 0 &&
        store.generation[index] == generation;
}

uint64_t ModifierRuntime::scope_id_for(const Command &command) const {
    if (command.scope == GLOBAL) return 0;
    return command.scope == GROUP ? command.group_handle : command.entity_handle;
}

double ModifierRuntime::scaled_add(const TermDefinition &term, int32_t stacks,
                                   int32_t magnitude_q16) const {
    const double magnitude = static_cast<double>(magnitude_q16) /
        static_cast<double>(Q16_ONE);
    return term.add * static_cast<double>(stacks) * magnitude;
}

double ModifierRuntime::scaled_factor(const TermDefinition &term, int32_t stacks,
                                      int32_t magnitude_q16) const {
    const double magnitude = static_cast<double>(magnitude_q16) /
        static_cast<double>(Q16_ONE);
    const double interpolated = 1.0 + (term.factor - 1.0) * magnitude;
    return simulation_math::pow(interpolated, static_cast<double>(stacks));
}

double ModifierRuntime::bucket_factor(const Bucket &bucket) const {
    return bucket.zero_factor_count > 0 ? 0.0 : bucket.product_nonzero;
}

void ModifierRuntime::rebuild_bucket(int32_t domain, const BucketKey &key,
                                     Bucket &bucket) {
    const auto start = std::chrono::steady_clock::now();
    Store &store = _stores[domain];
    bucket.sum_add = 0.0;
    bucket.product_nonzero = 1.0;
    bucket.zero_factor_count = 0;
    const StatDefinition &stat = _stats[static_cast<size_t>(key.stat_id)];
    // Per-source accumulation, only for the two non-SUM policies. Kept local
    // rather than in the bucket: the map is rebuilt from `members` anyway, and a
    // stored copy would have to be kept coherent with three separate mutation
    // paths for no read-side benefit.
    std::vector<std::pair<uint64_t, double>> by_source;
    if (stat.aggregate_policy != AGGREGATE_SUM)
        by_source.reserve(bucket.members.size());
    std::vector<Contribution> live;
    live.reserve(bucket.members.size());
    for (const Contribution contribution : bucket.members) {
        if (contribution.instance >= store.active.size() ||
            store.active[contribution.instance] == 0) continue;
        const Definition &definition = _definitions[store.definition_id[contribution.instance]];
        if (contribution.term >= definition.term_count) continue;
        const TermDefinition &term = _terms[definition.term_begin + contribution.term];
        if (term.stat_id != key.stat_id) continue;
        const int32_t stacks = store.stacks[contribution.instance];
        const int32_t magnitude = store.magnitude_q16[contribution.instance];
        const double add = scaled_add(term, stacks, magnitude);
        if (stat.aggregate_policy == AGGREGATE_SUM) {
            bucket.sum_add += add;
        } else {
            // Source identity is (source_type, source_id), which is what the
            // caller supplied when it applied the row. Two rows from the same
            // cell collapse into one source, which is exactly the "同格 ×N" the
            // design asks for: a cell that qualifies through three of its own
            // cards is one source, not three.
            const uint64_t source_type = store.source_type[contribution.instance];
            const uint64_t source_id = store.source_id[contribution.instance];
            const uint64_t identity = source_type * 0x9e3779b97f4a7c15ULL ^ source_id;
            // Collected flat and merged after the sweep. A linear scan here would
            // be O(members x sources) -- on a wide cell-scope bucket that is the
            // difference between 40k and 400 comparisons per rebuild.
            by_source.emplace_back(identity, add);
        }
        const double factor = scaled_factor(term, stacks, magnitude);
        if (factor == 0.0) ++bucket.zero_factor_count;
        else bucket.product_nonzero *= factor;
        live.push_back(contribution);
    }
    if (stat.aggregate_policy != AGGREGATE_SUM) {
        // Merge equal sources: sort by identity, then fold adjacent runs. O(m log
        // m) instead of the O(m x sources) the per-member linear scan would cost.
        std::sort(by_source.begin(), by_source.end(),
            [](const std::pair<uint64_t, double> &lhs,
               const std::pair<uint64_t, double> &rhs) {
                return lhs.first < rhs.first;
            });
        size_t merged = 0;
        for (size_t index = 0; index < by_source.size(); ++index) {
            if (merged > 0 && by_source[merged - 1].first == by_source[index].first) {
                by_source[merged - 1].second += by_source[index].second;
                continue;
            }
            by_source[merged++] = by_source[index];
        }
        by_source.resize(merged);
        if (stat.aggregate_policy == AGGREGATE_MAX_SOURCE) {
            double best = 0.0;
            bool has_best = false;
            for (const auto &entry : by_source) {
                if (!has_best || entry.second > best) { best = entry.second; has_best = true; }
            }
            bucket.sum_add = has_best ? best : 0.0;
        } else {
            // TOP_N: keep the N largest source contributions and drop the rest.
            // Sorting descending is the definition, not an optimisation -- "the
            // largest three" must not depend on insertion order.
            std::sort(by_source.begin(), by_source.end(),
                [](const std::pair<uint64_t, double> &lhs,
                   const std::pair<uint64_t, double> &rhs) {
                    return lhs.second > rhs.second;
                });
            const size_t keep = stat.source_cap <= 0
                ? by_source.size()
                : std::min(by_source.size(), static_cast<size_t>(stat.source_cap));
            for (size_t index = 0; index < keep; ++index)
                bucket.sum_add += by_source[index].second;
        }
    }
    bucket.members.swap(live);
    bucket.mutations_since_rebuild = 0;
    ++store.bucket_rebuilds;
    const double duration_ms = elapsed_ms(start);
    _last_bucket_rebuild_ms += duration_ms;
    _bucket_rebuild_ms_total += duration_ms;
}

void ModifierRuntime::bump_stat_version(Store &store, int32_t stat_id) {
    if (stat_id < 0) return;
    if (static_cast<size_t>(stat_id) >= store.stat_versions.size())
        store.stat_versions.resize(static_cast<size_t>(stat_id) + 1, 0);
    ++store.stat_versions[static_cast<size_t>(stat_id)];
}

void ModifierRuntime::add_instance_to_buckets(int32_t domain, uint32_t index) {
    const auto start = std::chrono::steady_clock::now();
    Store &store = _stores[domain];
    const Definition &definition = _definitions[store.definition_id[index]];
    const uint64_t scope_id = store.scope[index] == GLOBAL ? 0 :
        (store.scope[index] == GROUP ? store.group_handle[index] : store.entity_handle[index]);
    for (uint32_t term_offset = 0; term_offset < definition.term_count; ++term_offset) {
        const TermDefinition &term = _terms[definition.term_begin + term_offset];
        const BucketKey key{term.stat_id, store.scope[index], scope_id};
        bump_stat_version(store, term.stat_id);
        Bucket &bucket = store.buckets[key];
        bucket.members.push_back({index, static_cast<uint16_t>(term_offset)});
        bucket.sum_add += scaled_add(term, store.stacks[index], store.magnitude_q16[index]);
        const double factor = scaled_factor(term, store.stacks[index],
                                            store.magnitude_q16[index]);
        if (factor == 0.0) ++bucket.zero_factor_count;
        else bucket.product_nonzero *= factor;
        // A MAX / TOP_N bucket cannot be maintained by adding one row: the new
        // row may displace a larger one and change the aggregate in a way no
        // delta can express. Rebuilding here is O(members) on a bucket that is
        // about to be read anyway, and only for the stats that opted in.
        if (_stats[static_cast<size_t>(term.stat_id)].aggregate_policy != AGGREGATE_SUM) {
            rebuild_bucket(domain, key, bucket);
            continue;
        }
        if (++bucket.mutations_since_rebuild >= BUCKET_REBUILD_INTERVAL ||
            !std::isfinite(bucket.sum_add) || !std::isfinite(bucket.product_nonzero)) {
            rebuild_bucket(domain, key, bucket);
        }
    }
    const double duration_ms = elapsed_ms(start);
    _last_bucket_update_ms += duration_ms;
    _bucket_update_ms_total += duration_ms;
}

void ModifierRuntime::remove_instance_from_buckets(int32_t domain, uint32_t index) {
    const auto start = std::chrono::steady_clock::now();
    Store &store = _stores[domain];
    const Definition &definition = _definitions[store.definition_id[index]];
    const uint64_t scope_id = store.scope[index] == GLOBAL ? 0 :
        (store.scope[index] == GROUP ? store.group_handle[index] : store.entity_handle[index]);
    for (uint32_t term_offset = 0; term_offset < definition.term_count; ++term_offset) {
        const TermDefinition &term = _terms[definition.term_begin + term_offset];
        const BucketKey key{term.stat_id, store.scope[index], scope_id};
        auto it = store.buckets.find(key);
        if (it == store.buckets.end()) continue;
        bump_stat_version(store, term.stat_id);
        Bucket &bucket = it->second;
        bucket.sum_add -= scaled_add(term, store.stacks[index], store.magnitude_q16[index]);
        const double factor = scaled_factor(term, store.stacks[index],
                                            store.magnitude_q16[index]);
        if (factor == 0.0) --bucket.zero_factor_count;
        else bucket.product_nonzero /= factor;
        bucket.members.erase(std::remove_if(bucket.members.begin(), bucket.members.end(),
            [&](const Contribution &entry) {
                return entry.instance == index && entry.term == term_offset;
            }), bucket.members.end());
        if (bucket.members.empty()) store.buckets.erase(it);
        else if (_stats[static_cast<size_t>(term.stat_id)].aggregate_policy != AGGREGATE_SUM)
            rebuild_bucket(domain, key, bucket);
        else if (++bucket.mutations_since_rebuild >= BUCKET_REBUILD_INTERVAL ||
                 !std::isfinite(bucket.sum_add) || !std::isfinite(bucket.product_nonzero))
            rebuild_bucket(domain, key, bucket);
    }
    const double duration_ms = elapsed_ms(start);
    _last_bucket_update_ms += duration_ms;
    _bucket_update_ms_total += duration_ms;
}
