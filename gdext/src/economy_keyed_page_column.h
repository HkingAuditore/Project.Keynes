#pragma once
#include "economy_hash_directory.h"
#include "economy_paged_column.h"
#include "economy_keyed_variable_records.h"
#include <map>

namespace pk {
class EconomyKeyedPageColumn {
public:
    struct RowView { uint64_t key = 0; EconomyPagedColumn::View pages; };
    using Directory = EconomyHashDirectory<RowView>;
    struct View {
        EconomyFieldDescriptor field;
        uint64_t rows = 0, root_hash = 0;
        Directory::Root root;
        std::shared_ptr<const RowView> row_at(uint64_t key) const { return Directory::at(root, key); }
    };
    struct Metrics { uint64_t rebuilt_rows = 0, encoded_bytes = 0, rebuilt_pages = 0, directory_nodes = 0; };
private:
    struct CachedRow { EconomyPagedColumn pages; std::shared_ptr<const std::vector<uint8_t>> payload; };
    std::map<uint64_t, CachedRow> _cache;
    Directory _directory{0x4b45594544524f57ULL};
    View _view;
    Metrics _metrics;
    static uint64_t mix(uint64_t hash, uint64_t value) { return economy_hash_u64(hash, value); }
public:
    View view() const { return _view; }
    Metrics metrics() const noexcept { return _metrics; }
    template<class Rows> View update(const Rows &rows, const std::vector<uint64_t> &keys) {
        const auto field = rows.descriptor();
        if (_view.field.id.domain && (!(_view.field.id == field.id) || _view.field.encoding != field.encoding ||
            _view.field.width != field.width || _view.field.layout != field.layout))
            throw std::logic_error("economy_keyed_page_field_changed");
        if (field.layout != EconomyFieldLayout::KeyedRows) throw std::logic_error("economy_keyed_page_layout_invalid");
        _view.field = field; _metrics = {};
        const uint64_t previous_rows = _view.rows;
        const auto nodes = _directory.copied_nodes();
        for (auto key : keys) {
            if (!rows.contains_key(key)) {
                _cache.erase(key); _view.root = _directory.replace(_view.root, key, {}, 0); continue;
            }
            const auto payload = rows.row_page(key);
            if (!payload) throw std::logic_error("economy_keyed_page_payload_missing");
            auto &cached = _cache[key];
            if (cached.payload == payload) continue;
            const auto previous = cached.pages.view();
            EconomyColumnChange change; change.field = field.id; change.lanes = payload->size();
            const uint64_t max_bytes = std::max<uint64_t>(previous.lanes, payload->size());
            const uint64_t page_count = max_bytes / 4096 + (max_bytes % 4096 != 0);
            for (uint64_t page = 0; page < page_count; ++page) change.pages.push_back(page);
            auto current = cached.pages.update(*payload, change, EconomyFieldEncoding::CanonicalRecord);
            cached.payload = payload;
            const auto metrics = cached.pages.metrics();
            _metrics.encoded_bytes += metrics.encoded_bytes; _metrics.rebuilt_pages += metrics.rebuilt_pages;
            _metrics.directory_nodes += metrics.directory_nodes;
            auto old = _view.row_at(key);
            if (old && old->pages.root_hash == current.root_hash && old->pages.root == current.root) continue;
            auto row = std::make_shared<RowView>(); row->key = key; row->pages = std::move(current);
            _view.root = _directory.replace(_view.root, key, row, row->pages.root_hash); ++_metrics.rebuilt_rows;
        }
        if constexpr (Rows::INDEXED_KEYS) {
            for (uint64_t key = previous_rows; key < rows.size(); ++key)
                if (!_view.row_at(key)) throw std::logic_error("economy_keyed_page_new_row_unregistered");
            for (uint64_t key = rows.size(); key < previous_rows; ++key)
                if (_view.row_at(key)) throw std::logic_error("economy_keyed_page_removed_row_unregistered");
        }
        if (_cache.size() != rows.size()) throw std::logic_error("economy_keyed_page_registration_count_mismatch");
        _view.rows = rows.size();
        _metrics.directory_nodes += _directory.copied_nodes() - nodes;
        uint64_t hash = mix(mix(mix(1469598103934665603ULL, 3), field.id.domain), field.id.column);
        hash = mix(mix(hash, static_cast<uint8_t>(field.layout)), _view.rows);
        _view.root_hash = mix(hash, _directory.root_hash(_view.root));
        return _view;
    }
    template<class Rows> static View rebuild(const Rows &rows) {
        auto keys = rows.all_keys();
        EconomyKeyedPageColumn column; return column.update(rows, keys);
    }
};
} // namespace pk
