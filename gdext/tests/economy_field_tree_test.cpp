#include "economy_versioned_field_tree.h"
#include "economy_tracked_journal.h"
#include <cassert>

struct Record {
    uint64_t id = 0; std::string name;
    template<class Visitor> void visit_persisted(Visitor &visit) const { visit(id); visit(name); }
};
struct JournalRecord {
    uint64_t amount = 0;
    template<class Visitor> void visit_persisted(Visitor &visit) const { visit(amount); }
};
using namespace pk;

int main() {
    ChangeRegistry registry;
    EconomyTrackedColumn<int64_t> cash(registry, {{1, 1}, "cash", EconomyFieldEncoding::I64, 8});
    cash.assign(1000, 5);
    EconomyKeyedVariableRecords<Record> records({{2, 1}, "records", EconomyFieldEncoding::CanonicalRecord, 1});
    records.push_back({11, "one"}); records.push_back({22, "two"});
    EconomyVersionedFieldTree tree;
    auto update = [&](int64_t day, uint64_t generation, bool full) {
        tree.begin(); tree.update_dense(cash, full); tree.update_keyed(records, full);
        return tree.finish(day, generation, 55);
    };
    const auto first = update(1, 1, false);
    assert(first.field_count == 2 && first.hash_version == 3);
    const auto bytes = first.field_at({1, 1})->dense.page_at(0)->bytes;
    const auto fields = first.root;
    const auto unchanged = update(2, 2, false);
    assert(unchanged.root == fields && unchanged.root_hash != first.root_hash);
    assert(tree.metrics().encoded_bytes == 0 && tree.metrics().directory_nodes == 0);
    cash.write_scalar(999, 9);
    { auto write = records.edit_row(1); write[0].name.assign(9000, 'x'); }
    const auto changed = update(3, 3, false);
    assert(first.field_at({1, 1})->dense.page_at(0)->bytes == bytes);
    EconomyVersionedFieldTree oracle;
    oracle.begin(); oracle.update_dense(cash, true); oracle.update_keyed(records, true);
    assert(changed.root_hash == oracle.finish(3, 3, 55).root_hash);
    tree.begin(); tree.update_dense(cash);
    bool rejected = false;
    try { tree.update_dense(cash); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    tree.begin(); tree.update_dense(cash);
    rejected = false;
    try { tree.finish(4, 4, 55); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    assert(tree.committed_view().root == changed.root);
    cash.write_scalar(0, 42);
    tree.begin(); tree.update_dense(cash);
    // Retry after a missing source, even though the failed attempt consumed
    // the cash dirty page. No partial generation can become public.
    rejected = false;
    try { tree.finish(4, 4, 55); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected && tree.committed_view().generation == 3);
    const auto recovered = update(4, 4, false);
    EconomyVersionedFieldTree recovered_oracle;
    recovered_oracle.begin(); recovered_oracle.update_dense(cash, true); recovered_oracle.update_keyed(records, true);
    assert(recovered.root_hash == recovered_oracle.finish(4, 4, 55).root_hash);
    rejected = false;
    try { tree.finish(5, 5, 55); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    rejected = false;
    try { tree.update_dense(cash); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    ChangeRegistry incompatible_registry;
    EconomyTrackedColumn<uint64_t> incompatible(incompatible_registry, {{1, 1}, "cash", EconomyFieldEncoding::U64, 8});
    incompatible.assign(1000, 42);
    tree.begin(); rejected = false;
    try { tree.update_dense(incompatible); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected && tree.committed_view().generation == 4);
    EconomyTrackedJournal<uint64_t, JournalRecord> journal({{13, 1}, "journal", EconomyFieldEncoding::CanonicalRecord, 1});
    journal.emplace(9001, {1}); journal.emplace(9002, {2});
    EconomyVersionedFieldTree journal_tree;
    journal_tree.begin(); journal_tree.update_keyed(journal); journal_tree.finish(1, 1, 55);
    journal.clear(); journal.emplace(9901, {3}); journal.emplace(9902, {4});
    // Full reference must remove absent arbitrary keys, even when row count
    // stays unchanged. It cannot reuse the previous sparse-key cache.
    journal_tree.begin(); journal_tree.update_keyed(journal, true);
    const auto full_journal = journal_tree.finish(2, 2, 55);
    EconomyVersionedFieldTree journal_oracle;
    journal_oracle.begin(); journal_oracle.update_keyed(journal, true);
    assert(full_journal.root_hash == journal_oracle.finish(2, 2, 55).root_hash);
    assert(!full_journal.field_at({13, 1})->keyed.row_at(9001));
    ChangeRegistry extra_registry;
    EconomyTrackedColumn<int32_t> extra(extra_registry, {{99, 1}, "extra", EconomyFieldEncoding::I32, 4});
    rejected = false;
    try { journal_tree.update_dense(extra); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    journal_tree.begin(); journal_tree.update_keyed(journal);
    assert(journal_tree.finish(3, 3, 55).field_count == 1);
    journal_tree.begin(); journal_tree.update_dense(extra);
    rejected = false;
    try { journal_tree.finish(4, 4, 55); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    // A field introduced only by a failed candidate is not part of the
    // committed catalog and must not become mandatory on the next attempt.
    journal_tree.begin(); journal_tree.update_keyed(journal);
    assert(journal_tree.finish(4, 4, 55).field_count == 1);
}
