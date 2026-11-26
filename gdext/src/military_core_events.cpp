#include "military_core.h"
#include "military_core_internal.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <utility>

namespace pk {
using namespace mil;

// ============================================================== events

// Design 19.1 payload schemas (military-runtime.md §10).
uint16_t military_event_payload_schema(uint16_t type) {
    switch (type) {
        case MILITARY_EVENT_WAR_DECLARED: return 20;
        case MILITARY_EVENT_WAR_ENDED: return 20;
        case MILITARY_EVENT_BATTLE_RESOLVED: return 21;
        case MILITARY_EVENT_CELL_CONTROL_CHANGED: return 22;
        case MILITARY_EVENT_ARMY_DESTROYED: return 21;
        case MILITARY_EVENT_COUNTRY_ANNEXED: return 23;
        case MILITARY_EVENT_CONVOY_INTERCEPTED: return 24;
        case MILITARY_EVENT_LEVY_APPLIED: return 25;
        default: return 20;
    }
}

namespace {

// Per-day coalescing table for push_event: open addressing over
// (type, cell, i0, i1) -> index into the day's suffix of the event ring.
struct EventDayIndex {
    std::vector<uint64_t> keys;     // 0 = empty
    std::vector<int32_t> rows;
    int64_t day = -1;

    // Power-of-two capacity with a hard load factor below 1: `insert` below
    // assumes a free slot always exists (a full table would spin forever).
    void clear(int64_t new_day, size_t live) {
        day = new_day;
        size_t capacity = 64;
        while (capacity < live * 4 + 64) capacity <<= 1;
        keys.assign(capacity, 0ull);
        rows.assign(capacity, -1);
    }

    bool compatible(size_t live) const {
        return !keys.empty() && keys.size() >= live * 2 + 64;
    }

    // Returns the row a coalescable earlier event lives in, or -1.
    int32_t find(uint64_t key) const {
        if (keys.empty()) return -1;
        size_t h = (size_t)(key & (keys.size() - 1));
        for (size_t probe = 0; probe < keys.size(); ++probe) {
            if (keys[h] == 0ull) return -1;
            if (keys[h] == key) return rows[h];
            h = (h + 1) & (keys.size() - 1);
        }
        return -1;
    }

    void insert(uint64_t key, int32_t row) {
        if (keys.empty()) return;
        size_t h = (size_t)(key & (keys.size() - 1));
        size_t probes = 0;
        while (keys[h] != 0ull) {
            if (keys[h] == key) {   // replace (row indices only grow)
                rows[h] = row;
                return;
            }
            h = (h + 1) & (keys.size() - 1);
            if (++probes > keys.size()) return;   // defensive: never spin
        }
        keys[h] = key;
        rows[h] = row;
    }
};

// Coalescing identity of one event (design 19.1 rate caps).
inline uint64_t event_day_key(const MilitaryEvent &e) {
    uint64_t key = mix_key((uint64_t)e.type | 0x10000ull, (uint64_t)(uint32_t)(e.cell + 1));
    key = mix_key(key, mix_key((uint64_t)e.i0, (uint64_t)e.i1 | 0x10000ull));
    return key == 0ull ? 1ull : key;
}

EventDayIndex &event_day_index() {
    static thread_local EventDayIndex index;
    return index;
}

} // namespace

void MilitaryCore::push_event(const MilitaryEvent &event) {
    MilitaryEvent e = event;
    // Design 19.1: every Military event carries its payload schema (20..25).
    if (e.payload_schema == 0) e.payload_schema = military_event_payload_schema(e.type);
    e.id = _next_event_id++;
    const size_t cap = (size_t)MILITARY_EVENT_RING_CAPACITY;
    // Coalescing: the same (type, cell, i0, i1) within one day folds into the
    // first row with that identity instead of consuming ring space (design
    // 19.1 rate caps). The per-day table keeps this O(1).
    EventDayIndex &index = event_day_index();
    if (index.day != e.day || !index.compatible(_events.size())) index.clear(e.day, _events.size());
    const uint64_t key = event_day_key(e);
    const int32_t hit = index.find(key);
    if (hit >= 0 && (size_t)hit < _events.size() && _events[(size_t)hit].day == e.day) {
        MilitaryEvent &prev = _events[(size_t)hit];
        prev.value += e.value;
        prev.id = e.id;
        ++_report.event_coalesced;
        return;
    }
    if (_events.size() >= cap) {
        // Ring full: drop the oldest row and rebuild the day table from the
        // survivors (row indices shift, so a stale table is unusable).
        _events.erase(_events.begin(), _events.begin() + static_cast<std::ptrdiff_t>(_events.size() - cap + 1));
        ++_report.event_evictions;
        ++_report.event_coalesced;
        index.clear(e.day, _events.size());
        for (size_t i = 0; i < _events.size(); ++i) {
            ++_report.event_index_rows_visited;
            const MilitaryEvent &row = _events[i];
            if (row.day != e.day) continue;
            const uint64_t k = event_day_key(row);
            if (index.find(k) < 0) index.insert(k, (int32_t)i);
        }
    }
    index.insert(key, (int32_t)_events.size());
    _events.push_back(e);
}

std::vector<MilitaryEvent> MilitaryCore::events_after(uint64_t after_id, size_t limit) const {
    std::vector<MilitaryEvent> out;
    if (limit == 0) return out;
    out.reserve(std::min(limit, _events.size()));
    for (const MilitaryEvent &e : _events) {
        if (e.id <= after_id) continue;
        out.push_back(e);
        if (out.size() >= limit) break;
    }
    return out;
}

} // namespace pk
