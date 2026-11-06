#pragma once
#include "runtime_committed_view_version.h"
#include <memory>
#include <vector>

namespace pk {
// Only sealed, immutable owner publications may be passed to copy(). The
// consumer owns a deep copy, including when the owner publishes another day.
template <typename T> struct RuntimePublishedView {
    uint64_t generation = 0;
    int64_t day = -1;
    bool committed = false;
    std::shared_ptr<const T> data;
    static RuntimePublishedView copy(const std::shared_ptr<const T> &source,
            uint64_t generation, int64_t day) {
        if (!source) return {};
        return {generation, day, true, std::make_shared<const T>(*source)};
    }
    bool observe(RuntimeCommittedViewVersion &cursor) const {
        return data && cursor.observe(generation, day, committed);
    }
};
inline bool runtime_published_view_self_test() {
    using Rows = std::vector<int>;
    auto owner = std::make_shared<Rows>(Rows{4, 7});
    auto view = RuntimePublishedView<Rows>::copy(owner, 3, 2);
    (*owner)[0] = 9;
    RuntimeCommittedViewVersion cursor;
    if ((*view.data)[0] != 4 || !view.observe(cursor) || !view.observe(cursor)) return false;
    view.generation = 2;
    if (view.observe(cursor)) return false;
    view.generation = 3; view.day = 1;
    if (view.observe(cursor)) return false;
    view.day = 2; view.committed = false;
    if (view.observe(cursor)) return false;
    return !RuntimePublishedView<Rows>{}.observe(cursor);
}
} // namespace pk
