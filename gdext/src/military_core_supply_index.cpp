#include "military_core_internal.h"

namespace pk {

bool military_supply_rings_ready(const MilitaryCore &core) {
    const size_t cells = (size_t)std::max(0, core._terrain.cell_count);
    return cells > 0 && core._ring_off.size() == cells && core._ring_len.size() == cells;
}

void military_clear_supply_rings(MilitaryCore &core) {
    core._ring_off.clear();
    core._ring_len.clear();
    core._ring_cells.clear();
    core._ring_dist.clear();
    core._ring_visit_stamp.clear();
    core._ring_visit_generation = 0;
    core._ring_build_queue.clear();
    core._ring_build_distance.clear();
}

void military_prepare_supply_rings(MilitaryCore &core) {
    if (military_supply_rings_ready(core)) return;
    military_clear_supply_rings(core);
    const size_t cells = (size_t)std::max(0, core._terrain.cell_count);
    core._ring_off.assign(cells, -1);
    core._ring_len.assign(cells, 0);
    core._ring_visit_stamp.assign(cells, 0);
}

bool military_supply_ring(MilitaryCore &core, int32_t cell, int32_t &begin, int32_t &end) {
    begin = end = 0;
    if (cell < 0 || cell >= core._terrain.cell_count || !military_supply_rings_ready(core)) return false;
    ++core._report.supply_ring_requests;
    const size_t center = (size_t)cell;
    if (core._ring_off[center] >= 0) {
        ++core._report.supply_ring_cache_hits;
        begin = core._ring_off[center];
        end = begin + core._ring_len[center];
        return true;
    }

    // Same dequeue and neighbor order as the former whole-map build. Scratch
    // belongs to this core: switching worlds or threads cannot reuse a stamp.
    uint32_t &generation = core._ring_visit_generation;
    if (++generation == 0) {
        std::fill(core._ring_visit_stamp.begin(), core._ring_visit_stamp.end(), 0u);
        generation = 1;
    }
    auto &queue = core._ring_build_queue;
    auto &distance = core._ring_build_distance;
    queue.clear();
    distance.clear();
    queue.push_back(cell);
    distance.push_back(0);
    core._ring_visit_stamp[center] = generation;
    const int32_t cells = core._terrain.cell_count;
    const int32_t neighbor_total = (int32_t)core._terrain.neighbors.size();
    const int32_t *neighbors = core._terrain.neighbors.data();
    begin = (int32_t)core._ring_cells.size();
    for (size_t head = 0; head < queue.size(); ++head) {
        const int32_t at = queue[head];
        const uint8_t d = distance[head];
        core._ring_cells.push_back(at);
        core._ring_dist.push_back(d);
        ++core._report.supply_ring_cells_visited;
        if (d >= MILITARY_SUPPLY_RADIUS || at * 6 + 5 >= neighbor_total) continue;
        for (int32_t k = 0; k < 6; ++k) {
            const int32_t next = neighbors[(size_t)(at * 6 + k)];
            if (next < 0 || next >= cells) continue;
            if (core._ring_visit_stamp[(size_t)next] == generation) continue;
            core._ring_visit_stamp[(size_t)next] = generation;
            queue.push_back(next);
            distance.push_back((uint8_t)(d + 1));
        }
    }
    end = (int32_t)core._ring_cells.size();
    core._ring_off[center] = begin;
    core._ring_len[center] = end - begin;
    ++core._report.supply_ring_centers_built;
    return true;
}

} // namespace pk
