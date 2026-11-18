#include "economy_resource_projection.h"

#include <cassert>

int main() {
    using namespace pk;
    constexpr size_t lanes_per_page = 4096 / sizeof(int64_t);
    const EconomyFieldDescriptor field{{3, 1}, "resource.stock", EconomyFieldEncoding::I64, 8};
    ChangeRegistry source_changes;
    ChangeRegistry destination_changes;
    EconomyTrackedColumn<int64_t> source(source_changes, field);
    EconomyTrackedColumn<int64_t> destination(destination_changes, field);

    source.assign(lanes_per_page * 5 + 1, 1234);
    assert(project_resource_wire_column(destination, source, false) ==
           source.size() * sizeof(int64_t));
    assert(destination == source);
    assert(project_resource_wire_column(destination, source, false) == 0);
    source.take_hash_pages();
    source.take_change_pages(EconomyChangeConsumer::Audit);

    source.write_scalar(lanes_per_page * 4, 42);
    source.write_scalar(lanes_per_page * 4 + 5, 23);
    source.write_scalar(source.size() - 1, 65);
    assert(project_resource_wire_column(destination, source, false) ==
           (lanes_per_page + 1) * sizeof(int64_t));
    assert(destination == source);
    const std::vector<uint64_t> changed{4, 5};
    assert(source.take_hash_pages() == changed);
    assert(source.take_change_pages(EconomyChangeConsumer::Audit) == changed);
    assert(project_resource_wire_column(destination, source, false) == 0);

    // Reconfiguring or restoring a world can replace a same-sized source.
    source.assign(source.size(), 7);
    assert(project_resource_wire_column(destination, source, false) ==
           source.size() * sizeof(int64_t));
    assert(destination == source);
    assert(project_resource_wire_column(destination, source, false) == 0);

    // A discarded suffix can leave pending page IDs beyond the current shape.
    source.write_scalar(source.size() - 1, 91);
    source.resize(17);
    assert(project_resource_wire_column(destination, source, false) ==
           source.size() * sizeof(int64_t));
    assert(destination == source);
    assert(project_resource_wire_column(destination, source, false) == 0);

    source.resize(4096, 9);
    assert(project_resource_wire_column(destination, source, true) ==
           source.size() * sizeof(int64_t));
    assert(destination == source);
    assert(project_resource_wire_column(destination, source, false) == 0);

    source.write_scalar(lanes_per_page * 6 + 1, 32);
    bool threw = false;
    try {
        source.publish_pages([](const std::vector<uint64_t> &pages) {
            assert(pages == std::vector<uint64_t>{6});
            throw std::runtime_error("interrupted publication");
        });
    } catch (const std::runtime_error &) {
        threw = true;
    }
    assert(threw);
    assert(project_resource_wire_column(source, source, false) == 0);
    assert(project_resource_wire_column(destination, source, false) == 4096);
    assert(destination == source);
}
