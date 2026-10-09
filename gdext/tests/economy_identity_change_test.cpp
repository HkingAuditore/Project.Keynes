#include "runtime_economy_live_tables.h"
#include <cassert>

using namespace pk;

static bool contains(const EconomyChangeBatch &batch, uint32_t domain, uint32_t column) {
    for (const auto &change : batch.columns)
        if (change.field == EconomyFieldId{domain, column}) return true;
    return false;
}

static void complete(ChangeRegistry &registry, uint64_t revision) {
    for (auto consumer : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish})
        registry.acknowledge(consumer, revision);
}

int main() {
    EconomyFamilyStore family;
    assert(family.changes.catalog().fields().size() == 15);
    auto initial = family.changes.seal(); complete(family.changes, initial.revision);
    const int32_t index = family.allocate();
    const auto original = family.handle_for_index(index);
    family.stable_id.write_scalar(index, 901);
    auto allocated = family.changes.seal();
    assert(contains(allocated, 5, 1) && contains(allocated, 5, 3) && contains(allocated, 5, 1001));
    complete(family.changes, allocated.revision);
    family.stable_id.write_scalar(index, 901);
    auto unchanged = family.changes.seal(); assert(unchanged.columns.empty());
    complete(family.changes, unchanged.revision);
    family.release(index);
    int32_t restored = -1;
    assert(!family.valid_handle(original, restored));
    auto removed = family.changes.seal();
    assert(contains(removed, 5, 1) && contains(removed, 5, 2) && contains(removed, 5, 14));
    complete(family.changes, removed.revision);
    assert(family.allocate() == index);
    const auto reused = family.handle_for_index(index);
    assert(reused != original && family.valid_handle(reused, restored));
    EconomyFamilyStore copied = family;
    auto copied_initial = copied.changes.seal(); complete(copied.changes, copied_initial.revision);
    copied.stable_id.write_scalar(index, 902);
    auto copied_change = copied.changes.seal();
    assert(copied_change.columns.size() == 1 && contains(copied_change, 5, 3));
    assert(family.stable_id[index] == 0);
    complete(copied.changes, copied_change.revision);
    EconomyFamilyStore moved = std::move(copied);
    assert(moved.stable_id[index] == 902 && copied.active_count.get() == 0);
    moved.clear(); assert(moved.active_count.get() == 0 && moved.active.empty());

    EconomyTradeOrderStore trade;
    assert(trade.changes.catalog().fields().size() == 29);
    trade.clear();
    auto empty = trade.changes.seal(); complete(trade.changes, empty.revision);
    trade.cash_escrow.push_back(37);
    trade.next_id++;
    auto dispatched = trade.changes.seal();
    assert(contains(dispatched, 9, 11) && contains(dispatched, 9, 1001));
    complete(trade.changes, dispatched.revision);
    trade.cash_escrow.write_scalar(0, 0);
    EconomyTradeOrderStore archived = trade;
    assert(archived.cash_escrow[0] == 0 && archived.next_id.get() == 2);
    trade.cash_escrow.write_scalar(0, 12);
    assert(archived.cash_escrow[0] == 0);
    // Arrival buckets are derived caches and do not affect authority changes.
    auto settled = archived.changes.seal(); complete(archived.changes, settled.revision);
    archived.arrival_bucket_days.push_back(4);
    auto cache_only = archived.changes.seal(); assert(cache_only.columns.empty());
    complete(archived.changes, cache_only.revision);
}
