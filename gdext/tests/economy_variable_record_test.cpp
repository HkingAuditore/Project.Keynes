#include "economy_variable_record_codec.h"
#include "economy_paged_column.h"
#include <cassert>

struct VariableRecord {
    int64_t id = 0;
    std::string name;
    std::vector<int32_t> traits;
    template<class Visitor> void visit_persisted(Visitor &visit) const {
        visit(id); visit(name); visit(traits);
    }
};

using namespace pk;

static std::vector<uint8_t> reference(const std::vector<VariableRecord> &rows) {
    std::vector<uint8_t> result;
    auto number = [&](uint64_t value, size_t width) {
        for (size_t byte = 0; byte < width; ++byte) { result.push_back(static_cast<uint8_t>(value)); value >>= 8; }
    };
    for (const auto &row : rows) {
        number(24 + row.name.size() + row.traits.size() * 4, 8);
        number(static_cast<uint64_t>(row.id), 8); number(row.name.size(), 8);
        result.insert(result.end(), row.name.begin(), row.name.end());
        number(row.traits.size(), 8);
        for (auto value : row.traits) number(static_cast<uint32_t>(value), 4);
    }
    return result;
}

int main() {
    EconomyTrackedVariableRecords<VariableRecord> rows(
        {{24, 1}, "family.offers", EconomyFieldEncoding::CanonicalRecord, 1});
    rows.push_back({1, "alpha", {1, -2}}); rows.push_back({2, "beta", {3}});
    assert(rows.record_width() == 0);
    assert(rows.canonical_column().values() == reference(rows.values()));
    auto &registry = rows.registry();
    auto finish = [&](uint64_t revision) {
        for (auto c : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish})
            registry.acknowledge(c, revision);
    };
    EconomyPagedColumn pages;
    auto initial = registry.seal();
    auto old = pages.update(rows.canonical_column().values(), initial.columns[0], EconomyFieldEncoding::CanonicalRecord);
    const auto old_bytes = old.page_at(0)->bytes; finish(initial.revision);
    {
        auto guard = rows.edit_row(0); guard[0].name.append(5000, 'x'); guard[0].traits.push_back(4);
    }
    assert(rows.canonical_column().values() == reference(rows.values()));
    auto changed = registry.seal();
    auto current = pages.update(rows.canonical_column().values(), changed.columns[0], EconomyFieldEncoding::CanonicalRecord);
    assert(current.root_hash == EconomyPagedColumn::rebuild(reference(rows.values()), {24, 1}, EconomyFieldEncoding::CanonicalRecord).root_hash);
    assert(old.page_at(0)->bytes == old_bytes); finish(changed.revision);
    {
        auto guard = rows.edit_row(0); guard[0].name = "z";
    }
    assert(rows.canonical_column().values() == reference(rows.values()));
    rows.stable_sort([](const auto &a, const auto &b) { return a.id > b.id; });
    assert(rows[0].id == 2 && rows.canonical_column().values() == reference(rows.values()));
    auto split = rows.stable_partition([](const auto &row) { return row.id == 1; });
    assert(split - rows.begin() == 1 && rows[0].id == 1);
    assert(rows.canonical_column().values() == reference(rows.values()));
    rows.erase_if([](const auto &row) { return row.id == 2; });
    assert(rows.size() == 1 && rows.canonical_column().values() == reference(rows.values()));
    auto copy = rows; auto moved = std::move(copy);
    assert(copy.empty() && moved.canonical_column().values() == reference(moved.values()));
    moved.clear(); assert(moved.canonical_column().empty());
}
