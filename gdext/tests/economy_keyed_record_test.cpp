#include "economy_keyed_variable_records.h"
#include "economy_keyed_page_column.h"
#include <cassert>

struct Row {
    uint64_t id = 0;
    std::string text;
    template<class Visitor> void visit_persisted(Visitor &visit) const { visit(id); visit(text); }
};
using namespace pk;

int main() {
    EconomyKeyedVariableRecords<Row> rows({{24, 1}, "rows", EconomyFieldEncoding::CanonicalRecord, 1});
    for (size_t index = 0; index < 10000; ++index) rows.push_back({index, "unchanged"});
    auto &registry = rows.registry();
    auto finish = [&](uint64_t revision) {
        for (auto c : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish})
            registry.acknowledge(c, revision);
    };
    auto batch = registry.seal(); assert(batch.columns[0].keys.size() == 10000);
    EconomyKeyedPageColumn pages;
    auto snapshot = pages.update(rows, batch.columns[0].keys);
    assert(snapshot.root_hash == EconomyKeyedPageColumn::rebuild(rows).root_hash);
    const auto snapshot_row = snapshot.row_at(0);
    finish(batch.revision);
    registry.take_keys({24, 1}, EconomyChangeConsumer::Hash);
    registry.take_keys({24, 1}, EconomyChangeConsumer::Audit);
    registry.take_keys({24, 1}, EconomyChangeConsumer::Publish);
    auto old = rows.row_page(0), untouched = rows.row_page(9999);
    const auto encoded = rows.encoded_rows();
    {
        auto guard = rows.edit_row(0); guard[0].text.assign(10000, 'z');
    }
    assert(rows.encoded_rows() - encoded == 1 && rows.row_page(9999) == untouched);
    assert(rows.row_page(0) != old && old->size() == 25);
    batch = registry.seal(); assert(batch.columns[0].keys == std::vector<uint64_t>{0});
    auto current = pages.update(rows, batch.columns[0].keys);
    assert(current.root_hash == EconomyKeyedPageColumn::rebuild(rows).root_hash);
    assert(pages.metrics().rebuilt_rows == 1 && snapshot.row_at(0) == snapshot_row);
    finish(batch.revision);
    assert(registry.take_keys({24, 1}, EconomyChangeConsumer::Hash) == std::vector<uint64_t>{0});
    {
        auto guard = rows.edit_row(0); guard[0].text.assign(10000, 'z');
    }
    batch = registry.seal(); assert(batch.columns.empty()); finish(batch.revision);
    const auto same_root = current.root;
    current = pages.update(rows, {});
    assert(current.root == same_root && pages.metrics().encoded_bytes == 0 && pages.metrics().directory_nodes == 0);
    assert(registry.take_keys({24, 1}, EconomyChangeConsumer::Audit) == std::vector<uint64_t>{0});
    const auto before_pop = rows.encoded_rows();
    rows.write_record(2, rows.back()); rows.pop_back();
    assert(rows.encoded_rows() - before_pop == 1);
    batch = registry.seal(); assert(batch.columns[0].keys == std::vector<uint64_t>({2, 9999}));
    current = pages.update(rows, batch.columns[0].keys);
    assert(!current.row_at(9999) && snapshot.row_at(9999));
    assert(current.root_hash == EconomyKeyedPageColumn::rebuild(rows).root_hash);
    finish(batch.revision);
    auto copy = rows; auto moved = std::move(copy);
    assert(copy.empty() && moved.size() == 9999 && moved[2].id == 9999);
    moved.clear(); assert(moved.empty());
}
