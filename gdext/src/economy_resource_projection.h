#pragma once

#include "economy_tracked_column.h"

#include <algorithm>

namespace pk {

// The committed destination belongs to this source for its lifetime. A new
// binding or restore replaces the source through tracked column assignments.
// This is its only consumer of the source's Publish pages.
template<class T>
size_t project_resource_wire_column(EconomyTrackedColumn<T> &destination,
                                    const EconomyTrackedColumn<T> &source,
                                    bool full) {
    if (&destination == &source) return 0;
    size_t inspected_lanes = 0;
    source.publish_pages([&](const std::vector<uint64_t> &pages) {
        if (full || destination.size() != source.size()) {
            destination = source;
            inspected_lanes = source.size();
            return;
        }
        constexpr size_t lanes_per_page = 4096 / sizeof(T);
        for (uint64_t page : pages) {
            const size_t first = static_cast<size_t>(page) * lanes_per_page;
            if (first >= source.size()) continue;
            const size_t count = std::min(lanes_per_page, source.size() - first);
            destination.write_values(first, source.data() + first, count);
            inspected_lanes += count;
        }
    });
    return inspected_lanes * sizeof(T);
}

} // namespace pk
