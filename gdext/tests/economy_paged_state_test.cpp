#include "economy_paged_column.h"
#include "economy_tracked_column.h"
#include "runtime_chunk_hash.h"
#include "economy_tracked_scalar.h"
#include "economy_owned_column.h"
#include <cassert>
#include <random>
#include <thread>

using namespace pk;

static void consume(ChangeRegistry &registry, uint64_t revision) {
    registry.acknowledge(EconomyChangeConsumer::Hash, revision);
    registry.acknowledge(EconomyChangeConsumer::Audit, revision);
    registry.acknowledge(EconomyChangeConsumer::Publish, revision);
}

static void check_page_bytes(const EconomyPagedColumn::View &view, const std::vector<int64_t> &reference) {
    for (size_t first = 0; first < reference.size(); first += 512) {
        const auto page = view.page_at(first / 512);
        assert(page);
        const size_t count = std::min<size_t>(512, reference.size() - first);
        assert(page->bytes.size() == count * 8);
        for (size_t index = 0; index < count; ++index) {
            uint64_t expected = static_cast<uint64_t>(reference[first + index]);
            for (size_t byte = 0; byte < 8; ++byte)
                assert(page->bytes[index * 8 + byte] == uint8_t(expected >> (byte * 8)));
        }
    }
}

int main() {
    {
        EconomyOwnedColumn<int32_t> route({{11, 1}, "expedition.route", EconomyFieldEncoding::I32, 4});
        route.assign(std::vector<int32_t>{3, 5});
        EconomyOwnedColumn<int32_t> copied = route;
        auto batch = copied.registry().seal(); consume(copied.registry(), batch.revision);
        const std::array<int32_t, 2> tail{7, 9};
        copied.insert(copied.end(), tail.begin(), tail.end());
        assert(copied.values() == std::vector<int32_t>({3, 5, 7, 9}) && route.size() == 2);
        EconomyOwnedColumn<int32_t> moved = std::move(copied);
        assert(moved.size() == 4 && copied.empty());
        batch = moved.registry().seal(); consume(moved.registry(), batch.revision);
        moved.write_scalar(3, 9);
        batch = moved.registry().seal(); assert(batch.columns.empty()); consume(moved.registry(), batch.revision);
    }
    {
        ChangeRegistry audit;
        const EconomyFieldDescriptor field{{1, 1}, "audit.cash", EconomyFieldEncoding::I64, 8, EconomyAuditRole::Cash};
        EconomyTrackedColumn<int64_t> cash(audit, field);
        cash.assign(std::vector<int64_t>{11, 22, 33});
        assert(audit.take_audit(field.id).requires_full_reference);
        cash.write_scalar(0, 11);
        cash.write_scalar(0, 12);
        cash.write_scalar(0, 19);
        {
            auto lease = EconomyRowWriteLease::create();
            auto &value = cash.borrow_row(1, *lease);
            cash.write_scalar(1, 27);
            value = 28;
        }
        {
            auto range = cash.write_range(0, 3);
            range.data()[0] = 30; range.data()[2] = 44;
        }
        auto before = audit.take_audit(field.id);
        assert(!before.requires_full_reference && before.preimages.size() == 3);
        assert(before.preimages[0].lane == 0 && before.preimages[0].bits == 11);
        assert(before.preimages[1].lane == 1 && before.preimages[1].bits == 22);
        assert(before.preimages[2].lane == 2 && before.preimages[2].bits == 33);
        EconomyWorkerChanges first, second;
        cash.write_scalar(0, 40, &first);
        cash.write_scalar(0, 50, &first);
        cash.write_scalar(2, 60, &second);
        audit.merge(first); audit.merge(second);
        before = audit.take_audit(field.id);
        assert(before.preimages.size() == 2 && before.preimages[0].bits == 30 && before.preimages[1].bits == 44);
        cash.erase(0, 1);
        assert(audit.take_audit(field.id).requires_full_reference);
        cash.write_scalar(0, 29);
        before = audit.take_audit(field.id);
        assert(before.preimages.size() == 1 && before.preimages[0].bits == 28);
    }
    {
        ChangeRegistry owner, foreign;
        const EconomyFieldDescriptor field{{1, 1}, "writer.owner", EconomyFieldEncoding::I64, 8};
        const auto handle = owner.register_field(field, 1);
        foreign.register_field(field, 1);
        bool rejected = false;
        try { foreign.touch(handle, 0, 1); }
        catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
        rejected = false;
        try { owner.mutation_revision(ChangeRegistry::WriterHandle{}); }
        catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
        assert(owner.mutation_revision(handle) == 0 && foreign.mutation_revision(field.id) == 0);
    }
    {
        ChangeRegistry counts;
        EconomyTrackedScalar<int64_t> count(counts,
            {{1, 1001}, "population.active_count", EconomyFieldEncoding::I64, 8});
        auto initial = counts.seal(); consume(counts, initial.revision);
        count = 0;
        auto unchanged = counts.seal(); assert(unchanged.columns.empty());
        consume(counts, unchanged.revision);
        assert(++count == 1 && count++ == 1 && count.get() == 2);
        assert(--count == 1 && count-- == 1 && count.get() == 0);
        auto changed = counts.seal();
        assert(changed.columns.size() == 1 && changed.columns[0].pages == std::vector<uint64_t>{0});
        consume(counts, changed.revision);
    }
    {
        const EconomyFieldId id{9, 1};
        const auto signed_empty = EconomyPagedColumn::rebuild(std::vector<int64_t>{}, id);
        const auto unsigned_empty = EconomyPagedColumn::rebuild(std::vector<uint64_t>{}, id);
        assert(signed_empty.root_hash != unsigned_empty.root_hash);
        EconomyPagedColumn missing;
        EconomyColumnChange change; change.field = id; change.lanes = 1;
        bool rejected_missing = false;
        try { missing.update(std::vector<int64_t>{3}, change); }
        catch (const std::logic_error &) { rejected_missing = true; }
        assert(rejected_missing);
    }
    const EconomyFieldDescriptor field{{1, 7}, "population.funds", EconomyFieldEncoding::I64, 8};
    EconomyFieldCatalog catalog;
    catalog.add(field);
    bool rejected = false;
    try { catalog.add(field); } catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
    ChangeRegistry registry;
    EconomyTrackedColumn<int64_t> column(registry, field);
    EconomyPagedColumn pages;
    RuntimeChunkHash v2_cache;
    column.resize(2049, -1);
    auto batch = registry.seal();
    assert(batch.columns.size() == 1 && batch.columns[0].pages.size() == 5);
    auto view = pages.update(column.values(), batch.columns[0]);
    assert(v2_cache.update(column, 1, 1) == RuntimeChunkHash::rebuild(column.values(), 1, 1));
    assert(v2_cache.update(column, 1, 1) == RuntimeChunkHash::rebuild(column.values(), 1, 1));
    assert(v2_cache.metrics().compared_bytes == 0 && v2_cache.metrics().rebuilt_pages == 0);
    assert(view.root_hash == EconomyPagedColumn::rebuild(column.values(), field.id).root_hash);
    auto old_view = view;
    auto old_page = old_view.page_at(0);
    const auto old_bytes = old_page->bytes;
    registry.acknowledge(EconomyChangeConsumer::Hash, batch.revision);
    registry.acknowledge(EconomyChangeConsumer::Audit, batch.revision);
    assert(registry.pending().size() == 1);
    registry.acknowledge(EconomyChangeConsumer::Publish, batch.revision);
    assert(registry.pending().empty());

    column.write_scalar(0, -1);
    batch = registry.seal();
    assert(batch.columns.empty());
    consume(registry, batch.revision);

    {
        auto lease = EconomyRowWriteLease::create();
        auto retained_lease = lease;
        auto &funds = column.borrow_row(0, *lease);
        funds += 5;
        lease.reset();
        // Another reference still owns the lease and blocks structural changes.
        rejected = false;
        try { column.resize(0); } catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
        retained_lease.reset();
        column.write_scalar(0, -1);
        batch = registry.seal(); consume(registry, batch.revision);
        assert(v2_cache.update(column, 1, 1) == RuntimeChunkHash::rebuild(column.values(), 1, 1));
    }

    column.write_scalar(2048, INT64_MIN);
    assert(v2_cache.update(column, 1, 1) == RuntimeChunkHash::rebuild(column.values(), 1, 1));
    assert(v2_cache.metrics().compared_bytes == 8);
    // A second observer that missed prior dirty consumption must rebuild.
    RuntimeChunkHash second_observer;
    assert(second_observer.update(column, 1, 1) == RuntimeChunkHash::rebuild(column.values(), 1, 1));
    batch = registry.seal();
    assert(batch.columns.size() == 1 && batch.columns[0].pages == std::vector<uint64_t>{4});
    view = pages.update(column.values(), batch.columns[0]);
    assert(pages.metrics().encoded_bytes == 8 && pages.metrics().rebuilt_pages == 1);
    assert(view.page_at(0) == old_page && old_page->bytes == old_bytes);
    check_page_bytes(view, column.values());
    consume(registry, batch.revision);

    {
        auto guard = column.write_range(508, 12);
        guard.data()[0] = 42; guard.data()[11] = 99;
        rejected = false;
        try { column.resize(1); } catch (const std::logic_error &) { rejected = true; }
        assert(rejected);
    }
    batch = registry.seal();
    assert(batch.columns[0].pages == (std::vector<uint64_t>{0, 1}));
    view = pages.update(column.values(), batch.columns[0]);
    consume(registry, batch.revision);

    // Two real writes whose final value returns to the published value do not
    // create a new immutable page or copy its directory path.
    const auto retained_root = view.root;
    const int64_t previous = column[1];
    column.write_scalar(1, 123); column.write_scalar(1, previous);
    batch = registry.seal();
    view = pages.update(column.values(), batch.columns[0]);
    assert(view.root == retained_root && pages.metrics().encoded_bytes == 0);
    consume(registry, batch.revision);

    std::vector<int64_t> reference = column.values();
    std::mt19937_64 random(20261009);
    for (int step = 0; step < 500; ++step) {
        switch (random() % 4) {
        case 0: {
            const size_t size = random() % 9000;
            column.resize(size, 13); reference.resize(size, 13);
            break;
        }
        case 1:
            if (!reference.empty()) {
                const size_t index = random() % reference.size();
                const int64_t value = static_cast<int64_t>(random());
                column.write_scalar(index, value); reference[index] = value;
            }
            break;
        case 2:
            if (!reference.empty()) {
                const size_t first = random() % reference.size();
                const size_t count = random() % (reference.size() - first + 1);
                column.erase(first, count);
                reference.erase(reference.begin() + first, reference.begin() + first + count);
            }
            break;
        case 3:
            std::reverse(reference.begin(), reference.end()); column.assign(reference);
            break;
        }
        assert(column.values() == reference);
        assert(v2_cache.update(column, 1, 1) == RuntimeChunkHash::rebuild(column.values(), 1, 1));
        batch = registry.seal();
        if (!batch.columns.empty()) view = pages.update(column.values(), batch.columns[0]);
        assert(view.root_hash == EconomyPagedColumn::rebuild(reference, field.id).root_hash);
        check_page_bytes(view, reference);
        assert(old_view.page_at(0)->bytes == old_bytes);
        consume(registry, batch.revision);
    }

    column.resize(2048);
    batch = registry.seal();
    if (!batch.columns.empty()) pages.update(column.values(), batch.columns[0]);
    consume(registry, batch.revision);
    std::array<EconomyWorkerChanges, 4> sinks;
    std::array<std::thread, 4> workers;
    for (size_t task = 0; task < workers.size(); ++task) workers[task] = std::thread([&, task] {
        auto range = column.write_range(task * 512, 512, &sinks[task]);
        for (size_t lane = 0; lane < range.size(); ++lane) range.data()[lane] = static_cast<int64_t>(task * 512 + lane);
    });
    for (auto &worker : workers) worker.join();
    for (const auto &sink : sinks) registry.merge(sink);
    batch = registry.seal();
    assert(batch.columns[0].pages.size() == 4);
    view = pages.update(column.values(), batch.columns[0]);
    assert(view.root_hash == EconomyPagedColumn::rebuild(column.values(), field.id).root_hash);
    consume(registry, batch.revision);
    rejected = false;
    try { registry.acknowledge(EconomyChangeConsumer::Hash, batch.revision - 1); }
    catch (const std::logic_error &) { rejected = true; }
    assert(rejected);
}
