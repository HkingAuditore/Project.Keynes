#pragma once
#include "economy_hash_directory.h"
#include "economy_keyed_page_column.h"
#include "economy_tracked_column.h"
#include <map>

namespace pk {
// The field directory and all page directories are persistent. It is an
// internal v3 builder; production activation requires the complete source
// coverage gate, not merely successful construction of registered fields.
class EconomyVersionedFieldTree {
public:
    struct FieldView {
        EconomyFieldDescriptor field;
        uint64_t digest = 0;
        EconomyPagedColumn::View dense;
        EconomyKeyedPageColumn::View keyed;
    };
    using Directory = EconomyHashDirectory<FieldView>;
    struct View {
        int64_t day = -1;
        uint64_t generation = 0, root_hash = 0, field_count = 0;
        uint32_t hash_version = 3, schema = 0;
        Directory::Root root;
        std::shared_ptr<const FieldView> field_at(EconomyFieldId id) const { return Directory::at(root, id.key()); }
    };
    struct Metrics { uint64_t encoded_bytes = 0, rebuilt_pages = 0, rebuilt_fields = 0, directory_nodes = 0; };
private:
    struct CachedField {
        const void *owner = nullptr;
        uint64_t revision = 0;
        bool initialized = false;
        bool committed = false;
        bool descriptor_bound = false;
        EconomyFieldDescriptor descriptor;
        uint64_t visit_epoch = 0;
        EconomyPagedColumn dense;
        EconomyKeyedPageColumn keyed;
    };
    std::map<uint64_t, CachedField> _cache;
    Directory _directory{0x45434f4e4649454cULL};
    View _view;
    View _working;
    bool _building = false;
    Metrics _metrics;
    EconomyChangeConsumer _consumer;
    uint64_t _nodes_before = 0;
    uint64_t _visit_epoch = 0;
    static uint64_t mix(uint64_t h, uint64_t v) { return economy_hash_u64(h, v); }
    void visit(CachedField &field, const EconomyFieldDescriptor &descriptor) {
        if (!_building || field.visit_epoch == _visit_epoch)
            throw std::logic_error("economy_field_tree_duplicate_or_unstarted_source");
        if (field.descriptor_bound && (!(field.descriptor.id == descriptor.id) ||
            field.descriptor.width != descriptor.width || field.descriptor.encoding != descriptor.encoding ||
            field.descriptor.layout != descriptor.layout))
            throw std::logic_error("economy_field_tree_descriptor_changed");
        field.descriptor = descriptor; field.descriptor_bound = true;
        field.visit_epoch = _visit_epoch;
    }
    void install(std::shared_ptr<const FieldView> value) {
        const auto old = _working.field_at(value->field.id);
        if (old && old->digest == value->digest && old->dense.root == value->dense.root && old->keyed.root == value->keyed.root) return;
        _working.root = _directory.replace(_working.root, value->field.id.key(), value, value->digest);
        ++_metrics.rebuilt_fields;
    }
public:
    explicit EconomyVersionedFieldTree(EconomyChangeConsumer consumer = EconomyChangeConsumer::Publish) : _consumer(consumer) {}
    void begin() {
        if (_building) {
            // A failed/abandoned attempt may already have consumed dirty keys.
            // Discard its mutable caches so retry reconstructs from authority.
            for (auto entry = _cache.begin(); entry != _cache.end();) {
                if (!entry->second.committed) { entry = _cache.erase(entry); continue; }
                entry->second.initialized = false; entry->second.owner = nullptr;
                entry->second.dense = EconomyPagedColumn{};
                entry->second.keyed = EconomyKeyedPageColumn{};
                ++entry;
            }
        }
        _building = true; _working = _view;
        _metrics = {}; _nodes_before = _directory.copied_nodes();
        if (++_visit_epoch == 0) {
            for (auto &entry : _cache) entry.second.visit_epoch = 0;
            _visit_epoch = 1;
        }
    }
    template<class Column> void update_dense(const Column &column, bool full_reference = false) {
        if (!_building) throw std::logic_error("economy_field_tree_unstarted_update");
        const auto descriptor = column.descriptor();
        if (descriptor.layout != EconomyFieldLayout::Dense) throw std::logic_error("economy_field_tree_dense_layout_invalid");
        auto &cached = _cache[descriptor.id.key()];
        visit(cached, descriptor);
        const auto revision = column.mutation_revision();
        if (!full_reference && cached.initialized && cached.owner == &column && cached.revision == revision) return;
        EconomyColumnChange change; change.field = descriptor.id; change.lanes = column.size();
        if (!full_reference) change.pages = column.take_change_pages(_consumer);
        if (full_reference || !cached.initialized || cached.owner != &column) {
            const uint64_t per_page = 4096 / descriptor.width;
            const uint64_t maximum = std::max<uint64_t>(cached.dense.view().lanes, column.size());
            change.pages.clear();
            for (uint64_t page = 0; page < maximum / per_page + (maximum % per_page != 0); ++page) change.pages.push_back(page);
        }
        auto current = cached.dense.update(column.values(), change, descriptor.encoding);
        cached.owner = &column; cached.revision = revision; cached.initialized = true;
        const auto work = cached.dense.metrics();
        _metrics.encoded_bytes += work.encoded_bytes; _metrics.rebuilt_pages += work.rebuilt_pages; _metrics.directory_nodes += work.directory_nodes;
        auto value = std::make_shared<FieldView>(); value->field = descriptor; value->digest = current.root_hash; value->dense = std::move(current);
        install(std::move(value));
    }
    template<class Rows> void update_keyed(Rows &rows, bool full_reference = false) {
        if (!_building) throw std::logic_error("economy_field_tree_unstarted_update");
        const auto descriptor = rows.descriptor();
        auto &cached = _cache[descriptor.id.key()];
        visit(cached, descriptor);
        const auto revision = rows.registry().mutation_revision(descriptor.id);
        if (!full_reference && cached.initialized && cached.owner == &rows && cached.revision == revision) return;
        auto keys = full_reference ? std::vector<uint64_t>{} : rows.registry().take_keys(descriptor.id, _consumer);
        if (full_reference || !cached.initialized || cached.owner != &rows) {
            keys = rows.all_keys();
            if (full_reference || !cached.initialized) cached.keyed = EconomyKeyedPageColumn{};
            if constexpr (Rows::INDEXED_KEYS) {
                for (uint64_t key = rows.size(); key < cached.keyed.view().rows; ++key) keys.push_back(key);
            } else if (cached.owner && cached.owner != &rows) {
                cached.keyed = EconomyKeyedPageColumn{};
            }
        }
        auto current = cached.keyed.update(rows, keys);
        cached.owner = &rows; cached.revision = revision; cached.initialized = true;
        const auto work = cached.keyed.metrics();
        _metrics.encoded_bytes += work.encoded_bytes; _metrics.rebuilt_pages += work.rebuilt_pages; _metrics.directory_nodes += work.directory_nodes;
        auto value = std::make_shared<FieldView>(); value->field = descriptor; value->digest = current.root_hash; value->keyed = std::move(current);
        install(std::move(value));
    }
    View finish(int64_t day, uint64_t generation, uint32_t schema) {
        if (!_building) throw std::logic_error("economy_field_tree_unstarted_finish");
        for (const auto &field : _cache)
            if (field.second.visit_epoch != _visit_epoch) throw std::logic_error("economy_field_tree_source_missing");
        _working.day = day; _working.generation = generation; _working.schema = schema; _working.field_count = _cache.size();
        uint64_t hash = mix(mix(mix(mix(1469598103934665603ULL, 3), schema), static_cast<uint64_t>(day)), generation);
        _working.root_hash = mix(mix(hash, _working.field_count), _directory.root_hash(_working.root));
        _metrics.directory_nodes += _directory.copied_nodes() - _nodes_before;
        _view = _working;
        for (auto &field : _cache) field.second.committed = true;
        _building = false; return _view;
    }
    View committed_view() const { return _view; }
    Metrics metrics() const noexcept { return _metrics; }
};
} // namespace pk
