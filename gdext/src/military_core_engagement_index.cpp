#include "military_core_internal.h"

namespace pk {

void MilitaryCore::invalidate_engagement_members() {
    _engagement_members_valid = false;
    _engagement_members_unresolved = false;
    _engagement_army_head.clear();
    _army_engagement_prev.clear();
    _army_engagement_next.clear();
}

void MilitaryCore::ensure_engagement_members() {
    const size_t armies = _armies.engagement.size();
    const bool added_engagements = _engagement_army_head.size() < _engagements.size();
    if (_engagement_members_valid && _army_engagement_next.size() == armies &&
        !(added_engagements && _engagement_members_unresolved)) {
        if (_engagement_army_head.size() < _engagements.size())
            _engagement_army_head.resize(_engagements.size(), -1);
        return;
    }
    _engagement_army_head.assign(_engagements.size(), -1);
    _army_engagement_prev.assign(armies, -1);
    _army_engagement_next.assign(armies, -1);
    _engagement_members_unresolved = false;
    // Include inactive slots too: the historical close pass cleared every
    // matching authoritative field, including saved inactive payload.
    for (size_t army = 0; army < armies; ++army) {
        ++_report.engagement_index_slots_visited;
        const int32_t engagement = _armies.engagement[army];
        if (engagement < 0) continue;
        if ((size_t)engagement >= _engagements.size()) {
            // Accepted inactive save payload can point beyond today's table.
            // If the table later grows to that index, it must join the row.
            _engagement_members_unresolved = true;
            continue;
        }
        const int32_t head = _engagement_army_head[(size_t)engagement];
        _army_engagement_next[army] = head;
        if (head >= 0) _army_engagement_prev[(size_t)head] = (int32_t)army;
        _engagement_army_head[(size_t)engagement] = (int32_t)army;
    }
    _engagement_members_valid = true;
}

void MilitaryCore::set_army_engagement(int32_t army, int32_t engagement) {
    if (army < 0 || (size_t)army >= _armies.engagement.size()) return;
    // Until the first engagement operation, preserve the zero-index-work army
    // creation path. The eventual rebuild reads all authoritative assignments.
    if (!_engagement_members_valid) {
        _armies.engagement[(size_t)army] = engagement;
        return;
    }
    ensure_engagement_members();
    const size_t slot = (size_t)army;
    const int32_t old = _armies.engagement[slot];
    if (old == engagement) return;
    const int32_t previous = _army_engagement_prev[slot];
    const int32_t next = _army_engagement_next[slot];
    if (old >= 0 && (size_t)old < _engagement_army_head.size()) {
        if (previous >= 0) _army_engagement_next[(size_t)previous] = next;
        else _engagement_army_head[(size_t)old] = next;
        if (next >= 0) _army_engagement_prev[(size_t)next] = previous;
    }
    _army_engagement_prev[slot] = -1;
    _army_engagement_next[slot] = -1;
    _armies.engagement[slot] = engagement;
    if (engagement < 0) return;
    if ((size_t)engagement >= _engagements.size()) {
        _engagement_members_unresolved = true;
        return;
    }
    const int32_t head = _engagement_army_head[(size_t)engagement];
    _army_engagement_next[slot] = head;
    if (head >= 0) _army_engagement_prev[(size_t)head] = army;
    _engagement_army_head[(size_t)engagement] = army;
}

} // namespace pk
