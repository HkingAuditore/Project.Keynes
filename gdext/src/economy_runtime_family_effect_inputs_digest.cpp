#include "economy_runtime_family_effect_inputs_includes.inc"

namespace pk {

namespace {
inline uint64_t effect_input_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}
} // namespace

void NativeEconomyRuntime::set_effect_input_consumers(
        const MetricMask &cell_metrics, bool tags_needed, bool families_needed,
        const std::array<std::vector<int64_t>, FAMILY_METRIC_COUNT>
            &metric_thresholds,
        const std::vector<int32_t> &tag_ids) {
    const std::shared_ptr<const EffectInputConsumers> previous =
        std::atomic_load_explicit(&_effect_input_consumers,
            std::memory_order_acquire);
    // Republishing the same consumer set must NOT create a new generation: the
    // caller re-publishes on every configure, and a fresh generation resets the
    // per-metric published digests, which would bump every metric on every pass.
    if (previous != nullptr &&
            previous->metric_mask == cell_metrics &&
            previous->tags_needed == tags_needed &&
            previous->tag_ids == tag_ids &&
            previous->families_needed == families_needed &&
            previous->thresholds == metric_thresholds) {
        return;
    }
    auto consumers = std::make_shared<EffectInputConsumers>();
    consumers->metric_mask = cell_metrics;
    consumers->tags_needed = tags_needed;
    consumers->tag_ids = tag_ids;
    consumers->families_needed = families_needed;
    consumers->thresholds = metric_thresholds;
    consumers->generation = previous == nullptr ? 1 : previous->generation + 1;
    std::atomic_store_explicit(&_effect_input_consumers,
        std::shared_ptr<const EffectInputConsumers>(std::move(consumers)),
        std::memory_order_release);
    // No `_published_effect_input_digest = 0` here any more: that was a main-thread
    // write into the digest thread's state. The generation bump above makes the
    // digest republish on its own side.
}

void NativeEconomyRuntime::set_effect_metric_override(int32_t metric,
        int64_t value, bool has_value) {
    if (metric < 0 ||
            metric >= static_cast<int32_t>(FAMILY_METRIC_COUNT))
        return;
    const size_t slot = static_cast<size_t>(metric);
    auto next = std::make_shared<EffectMetricOverrideSet>();
    const std::shared_ptr<const EffectMetricOverrideSet> previous =
        std::atomic_load_explicit(&_effect_metric_override_snapshot,
            std::memory_order_acquire);
    if (previous != nullptr) {
        next->values = previous->values;
        next->set = previous->set;
        next->generation = previous->generation;
    }
    next->values[slot] = value;
    next->set[slot] = has_value ? 1 : 0;
    ++next->generation;
    std::atomic_store_explicit(&_effect_metric_override_snapshot,
        std::shared_ptr<const EffectMetricOverrideSet>(std::move(next)),
        std::memory_order_release);
}

bool NativeEconomyRuntime::set_cell_tag_override_for_test(
        const std::string &tag_key, int32_t cell, bool on) {
    if (cell < 0 || cell >= _cell_count.get()) return false;
    int32_t tag = -1;
    for (int32_t index = 0; index < _target_tags.count(); ++index) {
        if (_target_tags.names[static_cast<size_t>(index)] != tag_key) continue;
        tag = index;
        break;
    }
    if (tag < 0) return false;
    auto next = std::make_shared<CellTagOverrideSet>();
    const std::shared_ptr<const CellTagOverrideSet> previous =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    if (previous != nullptr) {
        next->cells = previous->cells;
        next->generation = previous->generation;
    }
    std::vector<CellTagOverride> &cell_overrides = next->cells[cell];
    if (cell_overrides.size() <= static_cast<size_t>(tag))
        cell_overrides.resize(static_cast<size_t>(tag) + 1u);
    CellTagOverride &override = cell_overrides[static_cast<size_t>(tag)];
    override.force_true = on ? 1 : 0;
    override.force_false = on ? 0 : 1;
    ++next->generation;
    std::atomic_store_explicit(&_cell_tag_override_snapshot,
        std::shared_ptr<const CellTagOverrideSet>(std::move(next)),
        std::memory_order_release);
    return true;
}

void NativeEconomyRuntime::clear_cell_tag_overrides_for_test() {
    auto next = std::make_shared<CellTagOverrideSet>();
    const std::shared_ptr<const CellTagOverrideSet> previous =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    if (previous != nullptr) next->generation = previous->generation;
    ++next->generation;
    std::atomic_store_explicit(&_cell_tag_override_snapshot,
        std::shared_ptr<const CellTagOverrideSet>(std::move(next)),
        std::memory_order_release);
}

void NativeEconomyRuntime::refresh_effect_input_digest() {
    // One load for the whole pass: the consumer set is immutable once published.
    const std::shared_ptr<const EffectInputConsumers> consumers =
        std::atomic_load_explicit(&_effect_input_consumers,
            std::memory_order_acquire);
    if (consumers == nullptr) return;
    if (!consumers->tags_needed && !consumers->families_needed &&
            consumers->metric_mask.is_none())
        return;
    const std::shared_ptr<const CellTagOverrideSet> tag_overrides =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    const uint64_t tag_override_generation =
        tag_overrides == nullptr ? 0 : tag_overrides->generation;
    if (tag_override_generation != _tag_snapshot_override_generation) {
        rebuild_epoch_tag_snapshot();
        refresh_effect_input_digest();
        return;
    }
    const auto started = std::chrono::steady_clock::now();
    // Copy-on-write: bump the revisions on a private copy and publish the whole
    // snapshot in one atomic store at the end, so no reader can observe a half
    // updated set (P3-B).
    const std::shared_ptr<const EffectInputSnapshot> previous =
        std::atomic_load_explicit(&_effect_input_snapshot,
            std::memory_order_acquire);
    auto next = previous != nullptr
        ? std::make_shared<EffectInputSnapshot>(*previous)
        : std::make_shared<EffectInputSnapshot>();
    const std::shared_ptr<const EffectMetricOverrideSet> overrides =
        std::atomic_load_explicit(&_effect_metric_override_snapshot,
            std::memory_order_acquire);
    bool changed = false;
    uint64_t digest = 1469598103934665603ULL;
    // ── territory revision ────────────────────────────────────────────────
    // Ownership, not the country state hash: state_hash folds cash and goods in,
    // both of which move on every settlement, so keying on it would advance the
    // revision daily and defeat the gate entirely (04 §3.1).
    uint64_t territory_digest = 1469598103934665603ULL;
    territory_digest = effect_input_mix(territory_digest,
        static_cast<uint64_t>(_epoch_cell_country.size()));
    for (const int32_t country : _epoch_cell_country) {
        territory_digest = effect_input_mix(territory_digest,
            static_cast<uint64_t>(static_cast<uint32_t>(country)));
    }
    digest = effect_input_mix(digest, territory_digest);
    if (territory_digest != _effect_territory_published) {
        _effect_territory_published = territory_digest;
        ++next->territory_revision;
        changed = true;
    }
    // ── family revision ───────────────────────────────────────────────────
    // X9-b resolves family-owned targets from the Economy-side family tables.
    // Hash every input that can change target eligibility: identity/home cell,
    // branch generation/family/cell, and the ownership rows that make a family
    // own at least one building. Hash only when a family-target consumer exists
    // so unrelated cards keep their zero-refresh idle window.
    if (consumers->families_needed) {
        uint64_t family_digest = 1469598103934665603ULL;
        const auto &families = families_store();
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(families.active.size()));
        for (int32_t family = 0; family < static_cast<int32_t>(
                families.active.size()); ++family) {
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(families.active[family]));
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(families.generation[family]));
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(static_cast<uint32_t>(
                    families.home_cell[family])));
        }
        const auto &branches = family_influences();
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(branches.active.size()));
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                branches.active.size()); ++branch) {
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(branches.active[branch]));
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(branches.generation[branch]));
            family_digest = effect_input_mix(family_digest,
                branches.family_handle[branch]);
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(static_cast<uint32_t>(
                    branches.cell[branch])));
        }
        const auto &ownerships = family_ownerships();
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(ownerships.size()));
        for (const FamilyBuildingOwnership &ownership : ownerships) {
            family_digest = effect_input_mix(family_digest,
                ownership.family_handle);
            family_digest = effect_input_mix(family_digest,
                ownership.building_handle);
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(static_cast<uint32_t>(
                    std::max<int64_t>(0, ownership.owned_count))));
        }
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(static_cast<uint32_t>(
                _family_target_min_branches_override_for_test)));
        digest = effect_input_mix(digest, family_digest);
        if (family_digest != _effect_family_published) {
            _effect_family_published = family_digest;
            ++next->family_revision;
            changed = true;
        }
    }
    // ── tag revision ──────────────────────────────────────────────────────
    if (consumers->tags_needed) {
        // R-3: ONE atomic load for the whole digest, so the bits hashed here all
        // belong to the same epoch. The local pointer also keeps that snapshot alive
        // if a commit publishes a new one mid-loop.
        const std::shared_ptr<const TagSnapshot> tags_snapshot = tag_snapshot();
        const uint64_t words = tags_snapshot == nullptr
            ? 0 : static_cast<uint64_t>(tags_snapshot->tag_words);
        uint64_t tag_digest = effect_input_mix(1469598103934665603ULL, words);
        if (tags_snapshot != nullptr) {
            for (const uint64_t word : tags_snapshot->tag_bits)
                tag_digest = effect_input_mix(tag_digest, word);
        }
        digest = effect_input_mix(digest, tag_digest);
        if (tag_digest != _effect_tag_published) {
            _effect_tag_published = tag_digest;
            ++next->tag_revision;
            changed = true;
        }
    }
    if (consumers->metric_mask.is_any()) {
        const int32_t cells = _cell_count.get();
        const int32_t metric_count = static_cast<int32_t>(FAMILY_METRIC_COUNT);
        // One digest per metric, so a card can depend on the metrics it reads
        // rather than on "some metric somewhere moved".
        std::array<uint64_t, FAMILY_METRIC_COUNT> per_metric;
        per_metric.fill(1469598103934665603ULL);
        std::vector<int32_t> requested_metrics;
        consumers->metric_mask.collect_ids(0, metric_count, requested_metrics);
        digest = effect_input_mix(digest, static_cast<uint64_t>(cells));
        // Sampling reads the frozen epoch. Each partition writes separate cells;
        // fold every metric in ascending cell order, including across batches.
        // A strip keeps scratch proportional to active metrics on large maps.
        constexpr int32_t strip_cells = 4096;
        const int32_t stride = std::min(cells, strip_cells);
        std::vector<uint64_t> samples(requested_metrics.size() * static_cast<size_t>(stride));
        for (int32_t start = 0; start < cells; ) {
            const int32_t count = std::min(stride, cells - start);
            parallel_for_range("pk_effect_metric_cells", count, 0, 1024, [&](int begin, int end) {
                std::array<int64_t, FAMILY_METRIC_COUNT> values{};
                for (int i = begin; i < end; ++i) {
                    fill_family_behavior_metrics(-1, -1, start + i, values.data(),
                                                 metric_count, consumers->metric_mask);
                    for (size_t index = 0; index < requested_metrics.size(); ++index) {
                        const int32_t metric = requested_metrics[index];
                        int64_t value = overrides != nullptr && overrides->set[metric] != 0
                            ? overrides->values[metric] : values[metric];
                        const auto &thresholds = consumers->thresholds[metric];
                        if (!thresholds.empty())
                            value = std::upper_bound(thresholds.begin(), thresholds.end(), value)
                                    - thresholds.begin();
                        samples[index * stride + i] = static_cast<uint64_t>(value);
                    }
                }
            });
            for (size_t index = 0; index < requested_metrics.size(); ++index) {
                uint64_t &hash = per_metric[requested_metrics[index]];
                const auto *column = samples.data() + index * stride;
                for (int i = 0; i < count; ++i) hash = effect_input_mix(hash, column[i]);
            }
            start += count;
        }
        // Fold the per-metric digests into the global one (so its meaning is
        // unchanged) and bump the revision of each metric that actually moved.
        for (const int32_t metric : requested_metrics) {
            const size_t slot = static_cast<size_t>(metric);
            digest = effect_input_mix(digest, per_metric[slot]);
            if (per_metric[slot] != _effect_metric_published[slot]) {
                _effect_metric_published[slot] = per_metric[slot];
                ++next->metric_revision[slot];
                changed = true;
            }
        }
    }
    ++_effect_input_digest_computations;
    _effect_input_digest_ms += std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    // A changed consumer set makes the old digest incomparable, so it republishes
    // even when the value happens to match.
    const bool consumers_changed =
        consumers->generation != _published_consumers_generation;
    const uint64_t override_generation =
        overrides == nullptr ? 0 : overrides->generation;
    const bool override_changed = override_generation != _published_override_generation;
    const bool tag_override_changed =
        tag_override_generation != _tag_override_published_generation;
    // KNOWN GAP (review round 3, P2): a metric that leaves the mask and later
    // re-enters with a digest equal to the stale stored one will not bump. The
    // fix is to force a bump for slots newly present in the mask; resetting all
    // published digests on every consumer change (the first attempt) made every
    // metric bump on every pass, which is worse. Global revision still moves, so
    // nothing is silently lost -- only the per-card narrowing misses one refresh.
    if (digest != _published_effect_input_digest || consumers_changed ||
            override_changed || tag_override_changed) {
        _published_effect_input_digest = digest;
        _published_consumers_generation = consumers->generation;
        _published_override_generation = override_generation;
        _tag_override_published_generation = tag_override_generation;
        _effect_input_revision.fetch_add(1, std::memory_order_release);
    }
    if (changed || previous == nullptr) {
        ++next->generation;
        std::atomic_store_explicit(&_effect_input_snapshot,
            std::shared_ptr<const EffectInputSnapshot>(std::move(next)),
            std::memory_order_release);
    }
}


// REMOVED (R-3): `ensure_country_tag_counts` and `build_country_tag_counts` are
// gone. The per-country counts live in the same immutable TagSnapshot as the tag
// bits they are derived from, so there is nothing to build or invalidate here;
// readers call `tag_snapshot()`.

// REMOVED (R-3): `ensure_country_specialized_goods` (X7b, metric 67) used to build
// lazily from a const getter here. It is now computed inside
// `rebuild_epoch_tag_snapshot()` and published in the same `TagSnapshot` as the tag
// bits, so one epoch's answer is always one object. Readers use `tag_snapshot()`.

} // namespace pk
