#include "economy_runtime_family_effect_inputs_includes.inc"

namespace pk {

int32_t NativeEconomyRuntime::cell_country_slot(int32_t cell) const {
    if (cell < 0) return -1;
    if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count.get()))
        return -1;
    if (cell >= static_cast<int32_t>(_epoch_cell_country.size())) return -1;
    return _epoch_cell_country[static_cast<size_t>(cell)];
}

void NativeEconomyRuntime::rebuild_country_territory_index() {
    _epoch_country_cell_offsets.clear();
    _epoch_country_cells.clear();
    const int32_t cells = _cell_count.get();
    const int32_t countries = std::max(0, _epoch_country_count);
    // Unowned cells are represented as negative slots and simply never enter the
    // CSR, so the index answers "owned by a real country", not "slot value".
    if (cells <= 0 || countries <= 0 ||
        _epoch_cell_country.size() != static_cast<size_t>(cells))
        return;
    _epoch_country_cell_offsets.assign(static_cast<size_t>(countries) + 1u, 0);
    int32_t owned = 0;
    for (const int32_t owner : _epoch_cell_country) {
        if (owner < 0 || owner >= countries) continue;
        ++_epoch_country_cell_offsets[static_cast<size_t>(owner) + 1u];
        ++owned;
    }
    for (size_t i = 1; i < _epoch_country_cell_offsets.size(); ++i)
        _epoch_country_cell_offsets[i] += _epoch_country_cell_offsets[i - 1u];
    _epoch_country_cells.assign(static_cast<size_t>(owned), -1);
    std::vector<int32_t> cursor = _epoch_country_cell_offsets;
    // Ascending scatter order is load bearing: it makes every slice ascending, so
    // a cell cap keeps the lowest cell ids and the selector stays replayable.
    for (int32_t cell = 0; cell < cells; ++cell) {
        const int32_t owner = _epoch_cell_country[static_cast<size_t>(cell)];
        if (owner < 0 || owner >= countries) continue;
        _epoch_country_cells[static_cast<size_t>(
            cursor[static_cast<size_t>(owner)]++)] = cell;
    }
}

bool NativeEconomyRuntime::country_territory_index_ready() const {
    if (_epoch_country_cell_offsets.empty()) return false;
    if (_epoch_country_cell_offsets.size() !=
        static_cast<size_t>(std::max(0, _epoch_country_count)) + 1u)
        return false;
    return _epoch_country_cell_offsets.back() ==
        static_cast<int32_t>(_epoch_country_cells.size());
}

int32_t NativeEconomyRuntime::country_cell_count(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    if (country_territory_index_ready()) {
        if (country_slot + 1 >=
            static_cast<int32_t>(_epoch_country_cell_offsets.size()))
            return 0;
        return _epoch_country_cell_offsets[static_cast<size_t>(country_slot) + 1u] -
            _epoch_country_cell_offsets[static_cast<size_t>(country_slot)];
    }
    const int32_t cells = _cell_count.get();
    if (cells <= 0 || _epoch_cell_country.size() != static_cast<size_t>(cells))
        return 0;
    int32_t count = 0;
    for (const int32_t owner : _epoch_cell_country)
        if (owner == country_slot) ++count;
    return count;
}

int32_t NativeEconomyRuntime::country_cell_at(
        int32_t country_slot, int32_t index) const {
    if (country_slot < 0 || index < 0) return -1;
    if (country_territory_index_ready()) {
        if (country_slot + 1 >=
            static_cast<int32_t>(_epoch_country_cell_offsets.size()))
            return -1;
        const int32_t begin = _epoch_country_cell_offsets[static_cast<size_t>(country_slot)];
        const int32_t end = _epoch_country_cell_offsets[static_cast<size_t>(country_slot) + 1u];
        if (index >= end - begin) return -1;
        return _epoch_country_cells[static_cast<size_t>(begin) + static_cast<size_t>(index)];
    }
    // Fallback: walk the ownership column in cell order, which is exactly the
    // order the index would have produced.
    const int32_t cells = _cell_count.get();
    if (cells <= 0 || _epoch_cell_country.size() != static_cast<size_t>(cells))
        return -1;
    int32_t seen = 0;
    for (int32_t cell = 0; cell < cells; ++cell) {
        if (_epoch_cell_country[static_cast<size_t>(cell)] != country_slot) continue;
        if (seen == index) return cell;
        ++seen;
    }
    return -1;
}

void NativeEconomyRuntime::collect_own_tagged_cells(
        int32_t country_slot, int32_t tag,
        std::vector<int32_t> &out_cells) const {
    out_cells.clear();
    if (country_slot < 0 || tag < 0 || tag >= _target_tags.count()) return;
    const std::shared_ptr<const TagSnapshot> tags_here = tag_snapshot();
    const TagSnapshot *const tags_ptr = tags_here.get();
    if (tags_ptr == nullptr) return;
    const int32_t owned = country_cell_count(country_slot);
    out_cells.reserve(static_cast<size_t>(std::max(0, owned)));
    for (int32_t index = 0; index < owned; ++index) {
        const int32_t cell = country_cell_at(country_slot, index);
        if (cell < 0) continue;
        if (snapshot_has_tag(tags_ptr, cell, tag)) out_cells.push_back(cell);
    }
}

int32_t NativeEconomyRuntime::country_anchor_cell(int32_t country_slot) const {
    if (country_slot < 0) return -1;
    const int32_t cells = _cell_count.get();
    if (_epoch_cell_country.size() != static_cast<size_t>(cells)) return -1;
    // Fast path: the index was scattered in ascending cell order, so its first
    // slice entry is by construction the lowest owned cell -- the exact value the
    // linear scan below returns. Once the index is consistent it is the
    // authoritative answer, including "this slot owns nothing".
    if (country_territory_index_ready()) {
        if (country_slot + 1 >=
            static_cast<int32_t>(_epoch_country_cell_offsets.size()))
            return -1;
        return country_cell_at(country_slot, 0);
    }
    for (int32_t cell = 0; cell < cells; ++cell) {
        if (_epoch_cell_country[static_cast<size_t>(cell)] == country_slot)
            return cell;
    }
    return -1;
}

void NativeEconomyRuntime::set_target_tags(const TargetTagTable &tags) {
    // R-3b: CONFIG-PHASE OR BOUNDARY-LOCK ONLY. This rebuilds the epoch snapshot,
    // which is the one thing `_published_tag_snapshot_generation` has a single
    // writer for, so two concurrent calls would race the counter and could publish
    // two snapshots carrying the same generation (a reader then reads "unchanged").
    //
    // Legitimate callers:
    //   * `configure_economy` / `configure_effects` at session configuration, before
    //     any epoch or worker thread exists;
    //   * a caller holding `NativeSimulationHost::try_lock_economy_input_capture`,
    //     the same lock `capture_country_epoch` is serialized by.
    // A caller that neither is at configuration nor holds that lock must not call
    // this. The check below cannot test the lock itself (this runtime does not own
    // it), so it makes the offending STATE visible instead: a rebuild already in
    // flight means "this call is concurrent with one", and refusing it here would
    // silently leave the OLD table's bits published -- hence the loud line, not a
    // silent early-out.
    if (_tag_snapshot_building.load(std::memory_order_acquire)) {
        pk::log_error("[economy/tag] set_target_tags while a snapshot rebuild is in "
                      "flight (calls=%llu): the caller must be at configuration or "
                      "hold the economy input capture lock",
                      static_cast<unsigned long long>(tag_snapshot_builds()));
        _tag_snapshot_concurrent_writes.fetch_add(1, std::memory_order_relaxed);
    }
    _target_tags = tags;
    // Any published snapshot was derived from the previous table, so it is stale
    // even if the cell columns have not moved.
    std::atomic_store_explicit(&_tag_snapshot,
        std::shared_ptr<const TagSnapshot>(), std::memory_order_release);
    // Rebuild immediately when the epoch data this table needs is already present.
    //
    // Dropping the pointer and waiting for the next `capture_country_epoch` leaves a
    // window in which every tag query answers "no tags" -- and if the caller attached
    // tags mid-epoch, that window lasts until the NEXT capture, so cards silently stop
    // matching in between. Rebuilding here closes it: the table just changed, the
    // columns it reads are available, so the snapshot can be produced right now.
    //
    // Guarded on the same inputs `rebuild_epoch_tag_snapshot` uses. When the epoch has
    // not captured yet (`_epoch_cell_country` short) there is nothing to build from
    // and the pointer correctly stays null until commit.
    const int32_t cells = _cell_count.get();
    if (cells > 0 && _epoch_cell_country.size() >= static_cast<size_t>(cells))
        rebuild_epoch_tag_snapshot();
}

namespace {
// X7 counted tags. Slot order MUST match FAMILY_METRIC_COUNTRY_*_CELL_COUNT
// ids 56..61 one-for-one: slot i is published as metric (56 + i). Appending a
// tag means appending a metric id in the same commit -- there is no runtime
// mapping between the two lists.
//
// Declared ABOVE `rebuild_epoch_tag_snapshot` (R-3): the snapshot builder fills the
// per-country counts, so it needs this table; the old placement worked only while
// the counts were built by a later function.
struct CountryTagCountSlot {
    const char *tag_name;
};
constexpr CountryTagCountSlot kCountryTagCountSlots[] = {
    {"cell.sector.agriculture"},
    {"cell.sector.extractive"},
    {"cell.sector.manufacturing"},
    {"cell.chained"},
    {"cell.specialized_high"},
    {"cell.market"},
    {"cell.settlement"},
    // Per-good slots. `cell.produces.<good>` is defined as "dominant output good
    // == that good", so these are exactly "how many cells mainly make silver".
    {"cell.produces.silver"},
    {"cell.produces.salt"},
    {"cell.produces.iron_ore"},
    {"cell.produces.coal"},
};
constexpr int32_t kCountryTagCountSlotCount =
    static_cast<int32_t>(sizeof(kCountryTagCountSlots) /
                         sizeof(kCountryTagCountSlots[0]));
} // namespace

void NativeEconomyRuntime::rebuild_epoch_tag_snapshot() {
    // M4: measure before deciding whether a per-tag incremental update is worth
    // building (the "stamp / touched scratch" task). A ScopedTimer so every early
    // return below is still counted.
    struct BuildTimer {
        std::atomic<double> &out_ms;
        std::atomic<int64_t> &out_count;
        std::chrono::steady_clock::time_point start =
            std::chrono::steady_clock::now();
        ~BuildTimer() {
            const double ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            out_ms.store(ms, std::memory_order_relaxed);
            out_count.fetch_add(1, std::memory_order_relaxed);
        }
    } build_timer{_last_tag_snapshot_build_ms, _tag_snapshot_build_count};
    // R-3: build ONE immutable snapshot and publish it with a single atomic store.
    //
    // History of this function, because the first "fix" was not one:
    //   1. Originally the tables were built lazily INSIDE const query methods, so the
    //      first reader after an epoch boundary mutated them from whatever thread
    //      queried first.
    //   2. Making the build eager at commit did not remove the race -- it moved the
    //      `clear()` + `assign()` onto the commit thread while the main thread's
    //      `step_ideology_instance_refresh -> reconcile` still iterated the same
    //      vectors. A reader could walk a buffer the writer had just freed.
    //   3. This version never mutates published storage. A fresh TagSnapshot is
    //      allocated, filled, and swapped in atomically; readers keep the old one
    //      alive through their shared_ptr for the duration of their read.
    //   4. R-3b: it also does nothing when nothing reads it. See `tag_snapshot_needed`.
    //
    // SINGLE WRITER (R-3b): this is the only function that assigns
    // `_published_tag_snapshot_generation`, and its two callers are serialized by
    // construction -- `capture_country_epoch` (the epoch owner) and `set_target_tags`
    // (config time, or a caller holding the boundary lock).
    const bool want_bits = tag_bits_needed();
    const bool want_specialized = specialized_good_count_needed();    // "Only one thread builds" (R-3b). A concurrent second caller returns and keeps
    // the previously published snapshot: stale at worst, never torn, and the next
    // epoch rebuilds it. Without this the two callers would race on
    // `_published_tag_snapshot_generation` and could publish two snapshots carrying
    // the same generation, which a reader would read as "nothing changed".
    struct BuildGuard {
        std::atomic<bool> &flag;
        bool owned = false;
        ~BuildGuard() { if (owned) flag.store(false, std::memory_order_release); }
    } build_guard{_tag_snapshot_building};
    {
        bool expected = false;
        if (!_tag_snapshot_building.compare_exchange_strong(expected, true,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            _tag_snapshot_skips.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        build_guard.owned = true;
    }
    _tag_snapshot_sampled_cells.store(0, std::memory_order_relaxed);
    _tag_snapshot_requested_metrics.store(0, std::memory_order_relaxed);
    _tag_catalog_metrics.store(0, std::memory_order_relaxed);
    if (!want_bits && !want_specialized) {
        // Nobody consumes either table this epoch, so the per-cell metric sample and
        // the per-country sweep would buy exactly nothing. Drop the stale snapshot
        // rather than leave a previous epoch's bits readable: a consumer set that
        // later asks for tags must not be answered from a generation it never
        // declared, and `tag_snapshot()` reporting a miss is the honest signal.
        std::atomic_store_explicit(&_tag_snapshot,
            std::shared_ptr<const TagSnapshot>(), std::memory_order_release);
        _tag_snapshot_skips.fetch_add(1, std::memory_order_relaxed);
        const std::shared_ptr<const CellTagOverrideSet> overrides =
            std::atomic_load_explicit(&_cell_tag_override_snapshot,
                std::memory_order_acquire);
        _tag_snapshot_override_generation =
            overrides == nullptr ? 0 : overrides->generation;
        return;
    }
    auto snapshot = std::make_shared<TagSnapshot>();
    snapshot->tag_count = want_bits ? _target_tags.count() : 0;
    const int32_t cells = _cell_count.get();
    const int32_t tags = snapshot->tag_count;
    const std::shared_ptr<const CellTagOverrideSet> tag_overrides =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    const uint64_t tag_override_generation =
        tag_overrides == nullptr ? 0 : tag_overrides->generation;

    if (tags > 0 && cells > 0) {
        const int32_t words = (cells + 63) / 64;
        snapshot->tag_words = words;
        snapshot->tag_bits.assign(
            static_cast<size_t>(tags) * static_cast<size_t>(words), uint64_t{0});
        const int32_t metric_count = static_cast<int32_t>(FAMILY_METRIC_COUNT);
        std::array<int64_t, FAMILY_METRIC_COUNT> values{};
        // Tags with NO rows can never match: `matches()` returns false immediately
        // (`target_tag.h:203`). Precomputing the active set turns a `cells x tags`
        // sweep into `cells x active_tags`, and the shipped catalogue declares far
        // more tags than any one world's table actually uses.
        // Narrow to the CONSUMED tags (M4-22).
        //
        // `tags_needed` was a bare bool, so a world whose cards read ONE tag still paid
        // `cells x 296` matches -- 35.66 ms at 6400 cells. The consumer set now carries
        // the ids; an EMPTY set with `tags_needed` true means "the publisher could not
        // name them" and is treated as all tags, so a conservative publisher can never
        // silently narrow the target set.
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        // Test switch: force the "all tags" fallback so the narrowing can be A/B'd
        static const bool env_force_all = []() {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_TAG_FORCE_ALL);
            return value != nullptr && value[0] == '1';
        }();
        const bool force_all_tags = env_force_all || _tag_force_all_for_test;
        const std::vector<int32_t> *consumed =
            (consumers == nullptr || force_all_tags)
                ? nullptr : &consumers->tag_ids;
        std::vector<int32_t> active_tags;
        if (consumed != nullptr && !consumed->empty()) {
            active_tags.reserve(consumed->size());
            for (const int32_t tag : *consumed) {
                if (tag < 0 || tag >= tags) continue;          // stale id
                if (_target_tags.end(tag) <= _target_tags.begin(tag)) continue;
                active_tags.push_back(tag);
            }
        } else {
            active_tags.reserve(static_cast<size_t>(tags));
            for (int32_t tag = 0; tag < tags; ++tag) {
                if (_target_tags.end(tag) > _target_tags.begin(tag))
                    active_tags.push_back(tag);
            }
        }
        _tag_active_tag_count = static_cast<int64_t>(active_tags.size());
        _tag_consumed_tag_count = consumed == nullptr
            ? 0 : static_cast<int64_t>(consumed->size());
        _tag_declared_tag_count = tags;
        const int32_t active = static_cast<int32_t>(active_tags.size());
        // The selected tags also define the metric work. Collecting the whole
        // catalog here sampled unrelated employment, resource and production
        // metrics on every cell even when only a terrain tag was consumed.
        // Unknown/empty consumer sets already select all tags above. Direct
        // metric queries keep their own mask and are not narrowed by this pass.
        // Index category rules by the actual map byte. A cell only visits tags it matches.
        using CategoryTags = std::array<std::vector<int32_t>, 256>;
        CategoryTags terrain_tags, landform_tags;
        struct SingleRowTag { int32_t tag; TargetTagRow row; };
        std::vector<SingleRowTag> single_row_tags;
        std::vector<int32_t> compound_tags;
        MetricMask requested_mask;
        MetricMask sample_mask;
        const auto metric_overrides = std::atomic_load_explicit(
            &_effect_metric_override_snapshot, std::memory_order_acquire);
        for (const int32_t tag : active_tags) {
            const auto first = _target_tags.rows.begin() + _target_tags.begin(tag);
            const auto last = _target_tags.rows.begin() + _target_tags.end(tag);
            for (auto row = first; row != last; ++row)
                requested_mask.set(row->metric_id);
            const int32_t id = first->metric_id;
            const bool categorical = id == FAMILY_METRIC_CELL_TERRAIN ||
                                     id == FAMILY_METRIC_CELL_LANDFORM;
            if (categorical && (metric_overrides == nullptr || !metric_overrides->set[id]) &&
                    std::all_of(first, last, [id](const auto &row) { return row.metric_id == id; })) {
                // A pure terrain/landform rule has the same answer for every
                // cell of that category, including the missing-column value 0.
                auto &by_value = id == FAMILY_METRIC_CELL_TERRAIN ? terrain_tags : landform_tags;
                for (size_t value = 0; value < by_value.size(); ++value) {
                    values[id] = static_cast<int64_t>(value) * Q16_ONE;
                    if (_target_tags.matches(tag, values.data(), metric_count))
                        by_value[value].push_back(tag);
                }
            } else {
                if (last - first == 1 && id >= 0 && id < metric_count)
                    single_row_tags.push_back({tag, *first});
                else
                    compound_tags.push_back(tag);
                for (auto row = first; row != last; ++row)
                    sample_mask.set(row->metric_id);
            }
        }
        MetricMask catalog_mask;
        _target_tags.collect_metric_mask(catalog_mask);
        _tag_catalog_metrics.store(
            catalog_mask.count(metric_count), std::memory_order_relaxed);
        _tag_snapshot_requested_metrics.store(
            requested_mask.count(metric_count), std::memory_order_relaxed);
        _tag_snapshot_sampled_cells.store(
            active > 0 ? cells : 0, std::memory_order_relaxed);
        std::vector<int32_t> overridden_metrics;
        if (metric_overrides != nullptr) {
            for (int32_t id = 0; id < metric_count; ++id)
                if (metric_overrides->set[id]) overridden_metrics.push_back(id);
        }
        if (active > 0) {
            // Give each task whole words of every tag. Metric sampling reads
            // frozen inputs, and each task owns its value scratch and bit writes.
            pk::parallel_for_range("pk_economy_tag_words", words,
                parallel_default_n_tasks(cells), 32, [&](int begin, int end) {
                std::array<int64_t, FAMILY_METRIC_COUNT> sampled_values{};
                const auto end_cell = std::min(static_cast<size_t>(cells),
                                               static_cast<size_t>(end) * 64u);
                for (size_t index = static_cast<size_t>(begin) * 64u; index < end_cell; ++index) {
                    const auto cell = static_cast<int32_t>(index);
                    const size_t word = index / 64u;
                    const uint64_t bit = uint64_t{1} << (index % 64u);
                    const auto set_bit = [&](int32_t tag) {
                        snapshot->tag_bits[static_cast<size_t>(tag) * words + word] |= bit;
                    };
                    for (const int32_t tag : terrain_tags[index < _building_terrain.size()
                            ? _building_terrain[index] : 0]) set_bit(tag);
                    for (const int32_t tag : landform_tags[index < _building_landform.size()
                            ? _building_landform[index] : 0]) set_bit(tag);
                    if (!single_row_tags.empty() || !compound_tags.empty()) {
                        fill_family_behavior_metrics(-1, -1, cell, sampled_values.data(),
                                                     metric_count, sample_mask);
                        for (const int32_t id : overridden_metrics)
                            sampled_values[id] = metric_overrides->values[id];
                        for (const auto &entry : single_row_tags) {
                            if (TargetTagTable::row_matches(entry.row, sampled_values[entry.row.metric_id]))
                                set_bit(entry.tag);
                        }
                        for (const int32_t tag : compound_tags) {
                            if (_target_tags.matches(tag, sampled_values.data(), metric_count))
                                set_bit(tag);
                        }
                    }
                }
            });
            // Overrides affect selected tags even when their rule did not match.
            if (tag_overrides != nullptr) {
                for (const auto &[cell, overrides] : tag_overrides->cells) {
                    if (cell < 0 || cell >= cells) continue;
                    const uint64_t bit = uint64_t{1} << (cell % 64);
                    for (const int32_t tag : active_tags) {
                        if (static_cast<size_t>(tag) >= overrides.size()) continue;
                        auto &word = snapshot->tag_bits[static_cast<size_t>(tag) * words + cell / 64];
                        if (overrides[tag].force_true) word |= bit;
                        else if (overrides[tag].force_false) word &= ~bit;
                    }
                }
            }
        }
    }

    // X7 counts are derived from the SAME bits, into the same snapshot, so a reader
    // can never see bits from one epoch beside counts from another.
    if (snapshot->tag_words > 0 && cells > 0 &&
        _epoch_cell_country.size() >= static_cast<size_t>(cells)) {
        int32_t countries = _epoch_country_count;
        for (int32_t cell = 0; cell < cells; ++cell) {
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country >= countries) countries = country + 1;
        }
        if (countries > 0) {
            int32_t tag_index[kCountryTagCountSlotCount];
            for (int32_t slot = 0; slot < kCountryTagCountSlotCount; ++slot) {
                tag_index[slot] = -1;
                const std::string wanted = kCountryTagCountSlots[slot].tag_name;
                for (int32_t tag = 0; tag < tags; ++tag) {
                    if (_target_tags.names[static_cast<size_t>(tag)] == wanted) {
                        tag_index[slot] = tag;
                        break;
                    }
                }
            }
            snapshot->country_count = countries;
            snapshot->country_tag_counts.assign(
                static_cast<size_t>(countries) *
                    static_cast<size_t>(kCountryTagCountSlotCount), 0);
            for (int32_t cell = 0; cell < cells; ++cell) {
                const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
                if (country < 0 || country >= countries) continue;
                const size_t word = static_cast<size_t>(cell / 64);
                const uint64_t bit = uint64_t{1} << (cell % 64);
                const size_t row = static_cast<size_t>(country) *
                    static_cast<size_t>(kCountryTagCountSlotCount);
                for (int32_t slot = 0; slot < kCountryTagCountSlotCount; ++slot) {
                    const int32_t tag = tag_index[slot];
                    if (tag < 0) continue;
                    const size_t index = static_cast<size_t>(tag) *
                        static_cast<size_t>(snapshot->tag_words) + word;
                    if (index >= snapshot->tag_bits.size()) continue;
                    if ((snapshot->tag_bits[index] & bit) == 0) continue;
                    ++snapshot->country_tag_counts[row + static_cast<size_t>(slot)];
                }
            }
        }
    }

    // X7b (metric 67): distinct specialized goods per country, in the SAME snapshot.
    //
    // Moved here from `ensure_country_specialized_goods()` (R-3). That was the worst
    // of the lazy builds: a const getter that sampled per-cell metrics and grew a
    // vector-of-vectors while the epoch columns could be moving underneath it.
    // Computing it with the tag bits keeps one epoch's answer in one object.
    //
    // R-3b: gated on its OWN consumer flag. Metric 67 reads no tag table, so a
    // catalog that declares the metric but no tags still gets its counts, and a
    // catalog that declares tags but not the metric no longer pays for this pass.
    if (want_specialized && cells > 0 &&
        _epoch_cell_country.size() >= static_cast<size_t>(cells)) {
        int32_t countries = _epoch_country_count;
        for (int32_t cell = 0; cell < cells; ++cell) {
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country >= countries) countries = country + 1;
        }
        if (countries > 0) {
            std::vector<std::vector<uint32_t>> specialized_bits(
                static_cast<size_t>(countries));
            MetricMask mask;
            mask.set(FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID);
            mask.set(FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16);
            std::vector<int64_t> values(static_cast<size_t>(FAMILY_METRIC_COUNT), 0);
            const int64_t specialized_share = Q16_ONE * 60 / 100;
            for (int32_t cell = 0; cell < cells; ++cell) {
                const int32_t country =
                    _epoch_cell_country[static_cast<size_t>(cell)];
                if (country < 0 || country >= countries) continue;
                sample_effect_metrics(cell, FAMILY_METRIC_COUNT, values.data(),
                                      mask);
                const int64_t good_q16 =
                    values[FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID];
                if (good_q16 < 0) continue;
                if (values[FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16] <
                        specialized_share)
                    continue;
                const int32_t good = static_cast<int32_t>(good_q16 / Q16_ONE);
                if (good < 0) continue;
                std::vector<uint32_t> &bits =
                    specialized_bits[static_cast<size_t>(country)];
                const size_t word = static_cast<size_t>(good / 32);
                if (bits.size() <= word) bits.resize(word + 1u, 0u);
                bits[word] |= uint32_t{1} << (good % 32);
            }
            snapshot->country_specialized_good_count.assign(
                static_cast<size_t>(countries), 0);
            for (int32_t country = 0; country < countries; ++country) {
                int32_t distinct = 0;
                for (const uint32_t word :
                        specialized_bits[static_cast<size_t>(country)]) {
                    uint32_t remaining = word;
                    while (remaining != 0) {
                        remaining &= remaining - 1u;
                        ++distinct;
                    }
                }
                snapshot->country_specialized_good_count[
                    static_cast<size_t>(country)] = distinct;
            }
        }
    }

    snapshot->generation = _published_tag_snapshot_generation + 1u;
    _published_tag_snapshot_generation = snapshot->generation;
    // The single mutation of published state: swap the pointer.
    std::atomic_store_explicit(&_tag_snapshot,
        std::shared_ptr<const TagSnapshot>(std::move(snapshot)),
        std::memory_order_release);
    _tag_snapshot_builds.fetch_add(1, std::memory_order_relaxed);
    _tag_snapshot_override_generation = tag_override_generation;
}

} // namespace pk
