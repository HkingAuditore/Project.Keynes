#include "economy_tracked_records.h"
#include "economy_paged_column.h"
#include "runtime_economy_family_side_tables.h"
#include <cassert>

namespace pk {
struct TestRecord {
    uint8_t flags = 0;
    uint64_t identity = 0;
    int64_t cash = 0;
    std::array<uint16_t, 2> needs{};
    int32_t transient_slot = -1;
};
template<class Visitor> void economy_visit_record(const TestRecord &row, Visitor &visit) {
    visit(row.flags); visit(row.identity); visit(row.cash); visit(row.needs);
}
}

using namespace pk;

int main() {
    {
        EconomyFamilyExpeditionPayload original, transient;
        transient.reserved_slot = 123;
        const auto first = EconomyRecordCodec<EconomyFamilyExpeditionPayload>::encode(original);
        const auto second = EconomyRecordCodec<EconomyFamilyExpeditionPayload>::encode(transient);
        assert(first.size == second.size && first.data == second.data);
        transient.funds = 123;
        const auto changed = EconomyRecordCodec<EconomyFamilyExpeditionPayload>::encode(transient);
        assert(first.data != changed.data);
        EconomyTrackedRecords<EconomyFamilyMembershipEdge> membership(
            {{12, 1}, "family.membership", EconomyFieldEncoding::CanonicalRecord, 1});
        membership.push_back({1, 2, 3, 4, 5, 6, 7, 8});
        assert(membership.record_width() == 64);
        const auto &bytes = membership.canonical_column().values();
        assert(bytes.size() == 64);
        for (size_t field = 0; field < 8; ++field) {
            assert(bytes[field * 8] == field + 1);
            for (size_t byte = 1; byte < 8; ++byte) assert(bytes[field * 8 + byte] == 0);
        }
    }
    EconomyTrackedRecords<TestRecord> rows({{12, 1}, "test.records", EconomyFieldEncoding::CanonicalRecord, 1});
    rows.resize(400);
    assert(rows.record_width() == 21);
    auto &registry = rows.registry();
    auto initial = registry.seal();
    assert(initial.columns.size() == 1);
    EconomyPagedColumn pages;
    auto snapshot = pages.update(rows.canonical_column().values(), initial.columns[0], EconomyFieldEncoding::CanonicalRecord);
    const auto preserved = snapshot.page_at(0)->bytes;
    auto finish = [&](uint64_t revision) {
        for (auto c : {EconomyChangeConsumer::Hash, EconomyChangeConsumer::Audit, EconomyChangeConsumer::Publish})
            registry.acknowledge(c, revision);
    };
    finish(initial.revision);
    {
        auto guard = rows.edit_row(0);
        guard[0].transient_slot = 17;
        bool rejected = false;
        try { rows.resize(401); } catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
        rejected = false;
        try { rows.canonical_column(); } catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
    }
    auto cache_only = registry.seal(); assert(cache_only.columns.empty()); finish(cache_only.revision);
    {
        auto guard = rows.edit_row(195); // A 21-byte record spans the 4 KiB boundary.
        guard[0].identity = 0x8877665544332211ULL;
        guard[0].cash = -37;
        guard[0].flags = 3;
        guard[0].needs = {9, 10};
    }
    auto changed = registry.seal();
    assert(changed.columns[0].pages == std::vector<uint64_t>({0, 1}));
    auto current = pages.update(rows.canonical_column().values(), changed.columns[0], EconomyFieldEncoding::CanonicalRecord);
    assert(current.root_hash == EconomyPagedColumn::rebuild(rows.canonical_column().values(), {12, 1}, EconomyFieldEncoding::CanonicalRecord).root_hash);
    assert(snapshot.page_at(0)->bytes == preserved);
    finish(changed.revision);
    rows.write_record(195, rows[195]);
    auto same = registry.seal(); assert(same.columns.empty()); finish(same.revision);
    EconomyWorkerChanges worker;
    {
        auto guard = rows.edit_row(196, &worker);
        guard[0].cash = 123;
    }
    registry.merge(worker);
    changed = registry.seal(); assert(changed.columns.size() == 1); finish(changed.revision);
    EconomyTrackedRecords<TestRecord> copy = rows;
    {
        auto guard = copy.edit_row(196); guard[0].cash = 321;
    }
    assert(rows[196].cash == 123 && copy[196].cash == 321);
    copy.erase(copy.begin(), copy.begin() + 195);
    assert(copy[0].identity == 0x8877665544332211ULL);
    EconomyTrackedRecords<TestRecord> moved = std::move(copy);
    assert(copy.empty() && moved.size() == 205 && moved[1].cash == 321);
}
