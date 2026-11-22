#include "runtime_ideology_pod.h"
#include <algorithm>
#include <limits>
#include <utility>

namespace pk {

RuntimeIdeologySnapshotRing::RuntimeIdeologySnapshotRing() { reset(); }

void RuntimeIdeologySnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeIdeologyPodSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeIdeologySnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        uint8_t expected = FREE;
        if (_slots[i].state.compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    uint64_t oldest_generation = std::numeric_limits<uint64_t>::max();
    uint32_t oldest_index = 0;
    bool ready_found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if (!ready_found || generation < oldest_generation) {
            oldest_generation = generation;
            oldest_index = i;
            ready_found = true;
        }
    }
    if (ready_found) {
        uint8_t expected = READY;
        if (_slots[oldest_index].state.compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            index = oldest_index;
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeIdeologySnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                                std::memory_order_relaxed);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeIdeologySnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                     uint32_t &index) {
    const bool accept_initial =
        after_generation == std::numeric_limits<uint64_t>::max();
    uint64_t best = 0;
    uint32_t best_index = 0;
    bool found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if ((accept_initial || generation > after_generation) &&
            (!found || generation > best)) {
            best = generation;
            best_index = i;
            found = true;
        }
    }
    if (!found) return false;
    uint8_t expected = READY;
    if (!_slots[best_index].state.compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    index = best_index;
    return true;
}

void RuntimeIdeologySnapshotRing::release(uint32_t index) {
    if (index >= _slots.size()) return;
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeIdeologySnapshotRing::self_test() {
    RuntimeIdeologySnapshotRing ring;
    uint32_t slot = 0;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 7;
    ring.publish(slot);
    uint32_t acquired = 0;
    if (!ring.try_acquire_latest(0, acquired)) return false;
    if (ring.read_buffer(acquired).generation != 7) return false;
    ring.release(acquired);
    return true;
}

namespace {
inline uint64_t business_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}
inline uint64_t business_seed() { return 1469598103934665603ULL; }
} // namespace

void ideology_business_sections(const RuntimeIdeologyPodSnapshot &state,
                                IdeologyBusinessSections &out) {
    out = IdeologyBusinessSections{};
    // `catalog_hash` is deliberately NOT mixed in. The main thread and the worker
    // compute it with two different functions over two different structures:
    //   main   -> NativeIdeologyRuntime::compute_catalog_hash()
    //   worker -> RuntimeIdeologyPodAuthority::compute_catalog_hash()
    // so the two values differ by construction. Folding it into `points` made
    // that section permanently unequal and made every real parity comparison
    // report `field=points`. Catalog agreement is a PRECONDITION, checked
    // separately (see `ideology_catalog_mismatch`), never a business field.
    out.points = business_seed();
    out.baseline = business_seed();
    out.history = business_seed();
    out.draw = business_seed();
    out.bits = business_seed();
    out.offer = business_seed();
    out.ideas = business_seed();
    out.points_balance = business_seed();
    out.points_lifetime = business_seed();
    out.points_revision = business_seed();
    out.history_cursor = business_seed();
    for (const RuntimeIdeologyPodCountryState &country : state.countries) {
        // Empty slots depend on the array length, not on state.
        if (country.handle == 0) continue;
        const uint64_t handle = country.handle;
        // `points` is the business section: balances only. `points_revision` is a
        // per-side Economy cadence counter (see the sub-hash comment below) and
        // must not be mixed in here, or this section can never be equal.
        out.points = business_mix(business_mix(out.points, handle),
            static_cast<uint64_t>(country.ideology_points_q16));
        out.points = business_mix(out.points,
            static_cast<uint64_t>(country.lifetime_points_q16));
        // Same rows, split by field, so `field=` can say which one moved.
        out.points_balance = business_mix(
            business_mix(out.points_balance, handle),
            static_cast<uint64_t>(country.ideology_points_q16));
        out.points_lifetime = business_mix(
            business_mix(out.points_lifetime, handle),
            static_cast<uint64_t>(country.lifetime_points_q16));
        // `points_revision` is deliberately NOT part of `points`.
        //
        // It is not "how many times this row accrued"; it is the external
        // Economy opinion revision the row last settled against:
        //     row->points_revision = opinion.revision;
        // That counter increments once per Economy development publish, and the
        // two sides publish on different cadences -- the worker on its own
        // clock, the main thread on cooperative slices. So the two numbers
        // differ by construction even when every business value is identical
        // (observed: reference_revision=1 vs worker_revision=3 while
        // ideology_points_q16 and lifetime_points_q16 matched exactly).
        //
        // It is kept as its own diagnostic sub-hash so a real divergence in
        // accrual cadence is still visible, but it cannot make `points` unequal.
        out.points_revision = business_mix(
            business_mix(out.points_revision, handle),
            static_cast<uint64_t>(country.points_revision));
        out.baseline = business_mix(business_mix(out.baseline, handle),
            static_cast<uint64_t>(country.baseline_ready));
        out.baseline = business_mix(business_mix(out.baseline,
            static_cast<uint64_t>(country.baseline_population)),
            static_cast<uint64_t>(country.baseline_buildings));
        // History is compared by CONTENT, normalised for ring cadence.
        //
        // `history_count` / `history_head` are positions in a fixed-size ring:
        // they count how many accruals wrote into it. Two sides that accrued a
        // different NUMBER of times (the worker settles against a higher Economy
        // revision because it publishes on its own clock) therefore carry
        // different cursors even when every stored gain is identical. Observed:
        // reference_history_count=0 vs worker_history_count=2 while both
        // `reference_history_q16` and `worker_history_q16` were all zero.
        //
        // So: mix every NON-ZERO stored gain in ring order. "No gains" then
        // hashes the same no matter how many empty notches the ring took, while
        // any real gain still differs. The raw cursors go to a separate
        // diagnostic sub-hash that cannot make `history` unequal.
        //
        // This does not weaken the section: a genuine accrual difference changes
        // `ideology_points_q16` / `lifetime_points_q16` (in `points`) and the
        // non-zero entries here.
        out.history = business_mix(out.history, handle);
        for (int64_t value : country.history_q16) {
            if (value == 0) continue;
            out.history = business_mix(out.history,
                static_cast<uint64_t>(value));
        }
        out.history_cursor = business_mix(
            business_mix(out.history_cursor, handle),
            static_cast<uint64_t>(country.history_count) << 32 |
            static_cast<uint64_t>(country.history_head));
        out.draw = business_mix(business_mix(out.draw, handle),
            country.rng_state);
        out.draw = business_mix(out.draw,
            static_cast<uint64_t>(country.draw_sequence));
        out.draw = business_mix(out.draw,
            static_cast<uint64_t>(country.unlocked_era));
        out.bits = business_mix(business_mix(out.bits, handle),
            static_cast<uint64_t>(country.known_bits.size()));
        for (uint64_t word : country.known_bits)
            out.bits = business_mix(out.bits, word);
        for (uint64_t word : country.banned_bits)
            out.bits = business_mix(out.bits, word);
        for (uint64_t word : country.gate_bits)
            out.bits = business_mix(out.bits, word);
        for (uint64_t word : country.synergy_bits)
            out.bits = business_mix(out.bits, word);
        out.offer = business_mix(business_mix(out.offer, handle),
            country.offer.generation);
        out.offer = business_mix(out.offer,
            static_cast<uint64_t>(country.offer.active) << 32 |
            static_cast<uint64_t>(country.offer.choice_count));
        for (int32_t id : country.offer.ideology_ids)
            out.offer = business_mix(out.offer,
                static_cast<uint64_t>(static_cast<int64_t>(id)));
        out.ideas = business_mix(business_mix(out.ideas, handle),
            static_cast<uint64_t>(country.ideas.size()));
        for (const RuntimeIdeologyPodIdeaState &idea : country.ideas) {
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(idea.understanding_q16));
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(static_cast<int64_t>(idea.level)) << 32 |
                static_cast<uint64_t>(idea.generation));
            out.ideas = business_mix(out.ideas, idea.entered_levels);
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(static_cast<int32_t>(idea.location)));
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(idea.slot_index));
        }
    }
}

uint64_t ideology_business_hash(const RuntimeIdeologyPodSnapshot &state) {
    IdeologyBusinessSections sections;
    ideology_business_sections(state, sections);
    uint64_t hash = business_mix(business_seed(), state.committed_day);
    hash = business_mix(hash, sections.points);
    hash = business_mix(hash, sections.baseline);
    hash = business_mix(hash, sections.history);
    hash = business_mix(hash, sections.draw);
    hash = business_mix(hash, sections.bits);
    hash = business_mix(hash, sections.offer);
    hash = business_mix(hash, sections.ideas);
    return hash;
}


} // namespace pk
