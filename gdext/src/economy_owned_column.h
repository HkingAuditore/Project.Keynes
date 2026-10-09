#pragma once
#include "economy_tracked_column.h"

namespace pk {
namespace economy_detail {
struct RegistryOwner { ChangeRegistry changes; };
}

// Self-owned sparse side columns can retain normal container copy/move
// semantics without copying writer handles or the source consumer cursors.
template<class T> class EconomyOwnedColumn : private economy_detail::RegistryOwner,
    public EconomyTrackedColumn<T> {
    using Column = EconomyTrackedColumn<T>;
public:
    explicit EconomyOwnedColumn(EconomyFieldDescriptor field)
        : Column(economy_detail::RegistryOwner::changes, field) {}
    EconomyOwnedColumn(EconomyFieldDescriptor field, std::initializer_list<T> initial)
        : EconomyOwnedColumn(field) { Column::assign(initial.begin(), initial.end()); }
    EconomyOwnedColumn(const EconomyOwnedColumn &other) : EconomyOwnedColumn(other.descriptor()) {
        Column::assign(other.values());
    }
    EconomyOwnedColumn(EconomyOwnedColumn &&other) : EconomyOwnedColumn(other.descriptor()) {
        Column::move_from(other);
    }
    EconomyOwnedColumn &operator=(const EconomyOwnedColumn &other) {
        if (this != &other) Column::assign(other.values());
        return *this;
    }
    EconomyOwnedColumn &operator=(EconomyOwnedColumn &&other) {
        if (this != &other) Column::move_from(other);
        return *this;
    }
    using Column::operator=;
    ChangeRegistry &registry() noexcept { return economy_detail::RegistryOwner::changes; }
    const ChangeRegistry &registry() const noexcept { return economy_detail::RegistryOwner::changes; }
    void merge(const EconomyWorkerChanges &sink) {
        const auto id = Column::field_id();
        EconomyWorkerChanges selected;
        for (const auto &before : sink.preimages)
            if (before.field == id) selected.preimages.push_back(before);
        for (const auto &range : sink.ranges)
            if (range.field == id) selected.ranges.push_back(range);
        registry().merge(selected);
    }
};
} // namespace pk
