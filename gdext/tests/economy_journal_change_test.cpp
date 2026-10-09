#include "economy_tracked_journal.h"
#include "economy_keyed_page_column.h"
#include <cassert>

struct JournalRecord {
    uint64_t request = 0;
    int64_t amount = 0;
    std::array<char, 4> reason{};
    uint32_t transient = 0;
    template<class Visitor> void visit_persisted(Visitor &visit) const {
        visit(request); visit(amount); visit(reason);
    }
};

using namespace pk;

int main() {
    EconomyTrackedJournal<uint64_t, JournalRecord> journal(
        {{13, 1}, "fiscal.journal", EconomyFieldEncoding::CanonicalRecord, 1});
    JournalRecord first{100, 17, {'o', 'k', 0, 0}, 3};
    assert(journal.emplace(100, first).second);
    assert(!journal.emplace(100, {}).second && journal.at(100).amount == 17);
    auto &registry = journal.registry();
    auto finish = [&](uint64_t revision) {
        for (auto c : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish})
            registry.acknowledge(c, revision);
    };
    auto initial = registry.seal(); finish(initial.revision);
    assert(journal.record_width() == 20 && journal.key_at(0) == 100);
    EconomyKeyedPageColumn pages;
    auto snapshot = pages.update(journal, journal.all_keys());
    assert(snapshot.row_at(100) && !snapshot.row_at(0));
    journal.write_record(100, first);
    auto same = registry.seal(); assert(same.columns.empty()); finish(same.revision);
    {
        auto guard = journal.edit(100);
        guard.get().transient = 8;
        bool rejected = false;
        try { journal.clear(); } catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
        rejected = false;
        try { journal.row_page(100); } catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
    }
    same = registry.seal(); assert(same.columns.empty()); finish(same.revision);
    {
        auto guard = journal.edit(100);
        // Inserting a different key may rehash; it cannot invalidate the guarded record.
        for (uint64_t key = 1; key < 100; ++key) journal.emplace(key, {key, static_cast<int64_t>(key), {}, 0});
        guard.get().amount = 18;
    }
    assert(journal.at(100).amount == 18 && journal.size() == 100);
    auto changed = registry.seal(); assert(!changed.columns.empty()); finish(changed.revision);
    auto current = pages.update(journal, changed.columns[0].keys);
    assert(current.root_hash == EconomyKeyedPageColumn::rebuild(journal).root_hash);
    auto copied = journal;
    copied.write_record(100, {100, 19, {}, 0});
    assert(journal.find(100)->second.amount == 18 && copied.find(100)->second.amount == 19);
    auto moved = std::move(copied);
    assert(copied.empty() && moved.at(100).amount == 19);
    EconomyTrackedJournal<uint64_t, JournalRecord> reversed(
        {{13, 1}, "fiscal.journal", EconomyFieldEncoding::CanonicalRecord, 1});
    for (uint64_t key = 100; key > 0; --key) reversed.emplace(key, journal.at(key));
    assert(EconomyKeyedPageColumn::rebuild(reversed).root_hash == current.root_hash);
    moved.clear(); assert(moved.empty());
    EconomyTrackedJournal<uint64_t, int32_t> indices(
        {{27, 3}, "canal.active_quote_index", EconomyFieldEncoding::CanonicalRecord, 1});
    constexpr uint64_t large_key = uint64_t{1} << 50;
    indices.emplace(large_key, 7); indices.emplace(3, 8); indices.emplace(4, 9);
    EconomyKeyedPageColumn index_pages;
    const auto old_indices = index_pages.update(indices, indices.all_keys());
    indices.registry().take_keys(indices.descriptor().id, EconomyChangeConsumer::Hash);
    assert(indices.erase(large_key) == 1 && indices.erase(large_key) == 0);
    auto keys = indices.registry().take_keys(indices.descriptor().id, EconomyChangeConsumer::Hash);
    assert(keys.size() == 1 && keys[0] == large_key);
    auto erased = index_pages.update(indices, keys);
    assert(!erased.row_at(large_key) && old_indices.row_at(large_key));
    assert(erased.root_hash == EconomyKeyedPageColumn::rebuild(indices).root_hash);
    indices.emplace(large_key, -1); indices.erase(3);
    keys = indices.registry().take_keys(indices.descriptor().id, EconomyChangeConsumer::Hash);
    auto reused = index_pages.update(indices, keys);
    assert(reused.row_at(large_key) && !reused.row_at(3));
    assert(reused.root_hash == EconomyKeyedPageColumn::rebuild(indices).root_hash);
    assert(indices.at(4) == 9 && indices.key_at(0) == 4);
    ChangeRegistry churn;
    const EconomyFieldId churn_id{99, 1};
    churn.register_field({churn_id, "churn", EconomyFieldEncoding::CanonicalRecord, 1,
        EconomyAuditRole::None, EconomyFieldLayout::KeyedRows});
    for (uint64_t key = 1; key <= 10000; ++key) {
        churn.touch_key(churn_id, key);
        auto batch = churn.seal();
        for (auto consumer : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish}) {
            const auto consumed = churn.take_keys(churn_id, consumer);
            assert(consumed.size() == 1 && consumed[0] == key);
            churn.acknowledge(consumer, batch.revision);
        }
        assert(churn.retained_key_stamps(churn_id) == 0 && churn.pending().empty());
    }
    churn.touch_key(churn_id, 11);
    for (auto consumer : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish})
        churn.take_keys(churn_id, consumer);
    // Consuming pages before sealing retains current-epoch dedup, and a
    // subsequent write is still delivered to all consumers exactly once.
    assert(churn.retained_key_stamps(churn_id) == 1);
    churn.touch_key(churn_id, 11);
    auto final_batch = churn.seal();
    assert(final_batch.columns.size() == 1 && final_batch.columns[0].keys.size() == 1);
    for (auto consumer : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish}) {
        assert(churn.take_keys(churn_id, consumer).size() == 1);
        churn.acknowledge(consumer, final_batch.revision);
    }
    assert(churn.retained_key_stamps(churn_id) == 0);
}
