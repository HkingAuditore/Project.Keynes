#pragma once
#include <cstdint>

namespace pk {

// A fixed 256-bit selection set over catalog-declared metric ids.
//
// Why this type exists
// --------------------
// Metrics are addressed by dense id (`FamilyEffectMetricId` in
// `economy_runtime.h`) and the catalogue is 50 rows today. A program says which
// ids it reads, the economy samples only those ids, and the value lands in the
// Effect instance's metric column. The selection used to be a bare `uint64_t`,
// so `effect_runtime.cpp` had to reject any `arg0 >= 64` at *catalog compile*
// time with `effect_metric_mask_overflow` -- a card above the ceiling could not
// even be loaded, let alone fire. The build redesign pushes the table past 64,
// so the ceiling has to move before any of that content can exist.
//
// Four words is a deliberate choice: one word (64) is already too small, and
// the next round of content is not going to need more than a couple hundred
// ids. 32 bytes per definition is cheaper than a heap allocation and keeps the
// struct trivially copyable, which matters because it travels inside
// `FamilyEffectMetadataPod` by value on every reconcile.
//
// Two states that must never be confused
// --------------------------------------
//   * `empty()` -- nothing requested. The sampler skips the cell entirely.
//   * `all()`   -- "no selection information", i.e. compute every *declared*
//                  metric. This is what `FamilyEffectMetadataPod` falls back to
//                  when nothing narrowed it, and what the
//                  `PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE` escape hatch forces.
// Treating empty as "all" would make every metric-less card pay for a full
// scan; treating all as "empty" would silence the escape hatch. Neither has a
// sentinel bit, so `all()` is simply "every word saturated" -- for a mask that
// genuinely selects all 256 ids the two readings agree anyway.
//
// `all_declared(count)` exists because most call sites only ever mean "every
// id the catalogue has", not "every id this type can hold".
class MetricMask {
public:
    static constexpr int32_t WORD_BITS = 64;
    static constexpr int32_t WORD_COUNT = 4;
    static constexpr int32_t CAPACITY = WORD_BITS * WORD_COUNT;

    static bool valid(int32_t id) { return id >= 0 && id < CAPACITY; }

    // Every id this type can hold. Prefer `all_declared()` when the caller
    // knows the catalogue size; this one is for caches keyed on cells.
    static MetricMask all() {
        MetricMask mask;
        mask.set_all();
        return mask;
    }
    // Ids 0..count-1. `count` is clamped to CAPACITY: a catalogue bigger than
    // the mask would otherwise silently drop the ids past the end.
    static MetricMask all_declared(int32_t count) {
        MetricMask mask;
        if (count > CAPACITY) count = CAPACITY;
        for (int32_t id = 0; id < count; ++id) mask.set(id);
        return mask;
    }

    void clear() {
        for (int32_t word = 0; word < WORD_COUNT; ++word) _words[word] = 0;
    }
    void set_all() {
        for (int32_t word = 0; word < WORD_COUNT; ++word) _words[word] = ~uint64_t{0};
    }
    void set(int32_t id) {
        if (!valid(id)) return;
        _words[id / WORD_BITS] |= uint64_t{1} << static_cast<uint32_t>(id % WORD_BITS);
    }
    void unset(int32_t id) {
        if (!valid(id)) return;
        _words[id / WORD_BITS] &= ~(uint64_t{1} << static_cast<uint32_t>(id % WORD_BITS));
    }
    bool test(int32_t id) const {
        if (!valid(id)) return false;
        return (_words[id / WORD_BITS] &
                (uint64_t{1} << static_cast<uint32_t>(id % WORD_BITS))) != 0;
    }
    bool is_none() const {
        for (int32_t word = 0; word < WORD_COUNT; ++word)
            if (_words[word] != 0) return false;
        return true;
    }
    bool is_any() const { return !is_none(); }
    bool is_all() const {
        for (int32_t word = 0; word < WORD_COUNT; ++word)
            if (_words[word] != ~uint64_t{0}) return false;
        return true;
    }
    // True when any selected id is >= `first`. Used to prove that a program
    // never asks for a metric the sampler cannot compute, without walking all
    // 256 ids: whole words below the boundary are skipped.
    bool has_id_at_or_above(int32_t first) const {
        if (first < 0) first = 0;
        if (first >= CAPACITY) return false;
        const int32_t word = first / WORD_BITS;
        const uint32_t bit = static_cast<uint32_t>(first % WORD_BITS);
        if ((_words[word] & (~uint64_t{0} << bit)) != 0) return true;
        for (int32_t next = word + 1; next < WORD_COUNT; ++next)
            if (_words[next] != 0) return true;
        return false;
    }

    // Set-bit count, clamped to `limit` so callers that only need "how many
    // metrics did this card ask for" never walk a saturated mask 256 times.
    int32_t count(int32_t limit = CAPACITY) const {
        if (limit > CAPACITY) limit = CAPACITY;
        int32_t total = 0;
        for (int32_t id = 0; id < limit; ++id) total += test(id) ? 1 : 0;
        return total;
    }

    // Raw word access for the sampler's "walk only the requested ids" loop and
    // for debug dumps. Callers must go through test()/set() when they have an
    // id rather than a word index.
    uint64_t word(int32_t index) const {
        return index >= 0 && index < WORD_COUNT ? _words[index] : 0;
    }
    void set_word(int32_t index, uint64_t bits) {
        if (index >= 0 && index < WORD_COUNT) _words[index] = bits;
    }

    MetricMask &operator|=(const MetricMask &other) {
        for (int32_t word = 0; word < WORD_COUNT; ++word)
            _words[word] |= other._words[word];
        return *this;
    }
    MetricMask operator&(const MetricMask &other) const {
        MetricMask result;
        for (int32_t word = 0; word < WORD_COUNT; ++word)
            result._words[word] = _words[word] & other._words[word];
        return result;
    }
    MetricMask &operator&=(const MetricMask &other) { return *this = *this & other; }
    bool operator==(const MetricMask &other) const {
        for (int32_t word = 0; word < WORD_COUNT; ++word)
            if (_words[word] != other._words[word]) return false;
        return true;
    }
    bool operator!=(const MetricMask &other) const { return !(*this == other); }

    // The worker change journal encodes every economy record through a
    // field-order visitor. Visiting the words individually keeps the encoding
    // self-describing enough for that journal (it is produced and consumed in
    // one process, so it never has to match an older layout).
    template<class Visitor> void visit_persisted(Visitor &visit) const {
        for (int32_t word = 0; word < WORD_COUNT; ++word) visit(_words[word]);
    }

private:
    uint64_t _words[WORD_COUNT] = {0, 0, 0, 0};
};

} // namespace pk
