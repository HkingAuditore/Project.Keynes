#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk {

// Use the same six-neighbour topology for province IDs and deposit quotas.
// Water stays 0, and landmass IDs follow the first cell of each component.
inline int32_t label_world_landmasses(const uint8_t *water, const int32_t *neighbors,
                                    int32_t cell_count, int32_t *labels) {
    std::fill_n(labels, cell_count, 0);
    int32_t count = 0;
    std::vector<int32_t> pending;
    pending.reserve(static_cast<std::size_t>(cell_count));
    for (int32_t cell = 0; cell < cell_count; ++cell) {
        if (water[cell] != 0 || labels[cell] != 0) continue;
        labels[cell] = ++count;
        pending.push_back(cell);
        while (!pending.empty()) {
            const int32_t current = pending.back();
            pending.pop_back();
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t next = neighbors[current * 6 + direction];
                if (next < 0 || next >= cell_count || water[next] != 0 ||
                    labels[next] != 0) continue;
                labels[next] = count;
                pending.push_back(next);
            }
        }
    }
    return count;
}

} // namespace pk
