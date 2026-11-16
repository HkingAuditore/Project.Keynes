#include "economy_runtime.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

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
        MetricMask mask;
        for (const int32_t tag : active_tags) {
            for (int32_t row = _target_tags.begin(tag);
                 row < _target_tags.end(tag); ++row)
                mask.set(_target_tags.rows[static_cast<size_t>(row)].metric_id);
        }
        MetricMask catalog_mask;
        _target_tags.collect_metric_mask(catalog_mask);
        _tag_catalog_metrics.store(
            catalog_mask.count(metric_count), std::memory_order_relaxed);
        _tag_snapshot_requested_metrics.store(
            mask.count(metric_count), std::memory_order_relaxed);
        _tag_snapshot_sampled_cells.store(
            active > 0 ? cells : 0, std::memory_order_relaxed);
        for (int32_t cell = 0; active > 0 && cell < cells; ++cell) {
            sample_effect_metrics(cell, metric_count, values.data(), mask);
            const size_t word = static_cast<size_t>(cell / 64);
            const uint64_t bit = uint64_t{1} << (cell % 64);
            const std::vector<CellTagOverride> *cell_overrides = nullptr;
            if (tag_overrides != nullptr) {
                const auto override_it = tag_overrides->cells.find(cell);
                if (override_it != tag_overrides->cells.end())
                    cell_overrides = &override_it->second;
            }
            for (int32_t index = 0; index < active; ++index) {
                const int32_t tag = active_tags[static_cast<size_t>(index)];
                bool matches =
                    _target_tags.matches(tag, values.data(), metric_count);
                if (cell_overrides != nullptr &&
                        tag < static_cast<int32_t>(
                            cell_overrides->size())) {
                    const CellTagOverride &override =
                        (*cell_overrides)[static_cast<size_t>(tag)];
                    if (override.force_true != 0)
                        matches = true;
                    else if (override.force_false != 0)
                        matches = false;
                }
                if (!matches) continue;
                snapshot->tag_bits[static_cast<size_t>(tag) *
                                       static_cast<size_t>(words) + word] |= bit;
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
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t share_q16 = 0;
        const int32_t good = dominant_output_good_at(cell, share_q16);
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
            int32_t share_q16 = 0;
            const int32_t good = dominant_output_good_at(
                neighbor, share_q16);
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
        std::vector<int64_t> values(static_cast<size_t>(metric_count), 0);
        // One digest per metric, so a card can depend on the metrics it reads
        // rather than on "some metric somewhere moved".
        std::array<uint64_t, FAMILY_METRIC_COUNT> per_metric;
        per_metric.fill(1469598103934665603ULL);
        digest = effect_input_mix(digest, static_cast<uint64_t>(cells));
        for (int32_t cell = 0; cell < cells; ++cell) {
            sample_effect_metrics(cell, metric_count, values.data(),
                consumers->metric_mask);
            for (int32_t metric = 0; metric < metric_count; ++metric) {
                if (!consumers->metric_mask.test(metric)) continue;
                int64_t sampled = values[static_cast<size_t>(metric)];
                if (overrides != nullptr &&
                        overrides->set[static_cast<size_t>(metric)] != 0)
                    sampled = overrides->values[static_cast<size_t>(metric)];
                // Threshold bucketing (review §3): if any card compares this
                // metric against N, the digest carries "how many N are <= value"
                // instead of the raw number. Crossing a threshold is exactly the
                // event that can flip a condition, and it needs no unit table --
                // population, counts and category ids all work the same way.
                const std::vector<int64_t> &metric_thresholds =
                    consumers->thresholds[static_cast<size_t>(metric)];
                if (!metric_thresholds.empty())
                    sampled = static_cast<int64_t>(
                        std::upper_bound(metric_thresholds.begin(),
                                         metric_thresholds.end(), sampled) -
                        metric_thresholds.begin());
                per_metric[static_cast<size_t>(metric)] = effect_input_mix(
                    per_metric[static_cast<size_t>(metric)],
                    static_cast<uint64_t>(sampled));
            }
        }
        // Fold the per-metric digests into the global one (so its meaning is
        // unchanged) and bump the revision of each metric that actually moved.
        for (int32_t metric = 0; metric < metric_count; ++metric) {
            if (!consumers->metric_mask.test(metric)) continue;
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
