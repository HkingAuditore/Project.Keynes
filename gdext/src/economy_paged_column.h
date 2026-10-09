#pragma once

#include "economy_change_registry.h"
#include "economy_hash.h"
#include <memory>
#include <type_traits>

namespace pk {

// Immutable directory nodes are copied only along dirty paths. Retaining a
// root pins the exact old revision without copying a flat page-pointer table.
class EconomyPagedColumn {
public:
    static constexpr uint32_t HASH_VERSION = 3, PAGE_BYTES = 4096;
    struct Page { std::vector<uint8_t> bytes; uint64_t digest = 0; };
    struct Node {
        std::shared_ptr<const Node> left, right;
        std::shared_ptr<const Page> page;
        uint64_t digest = 0;
    };
    struct View {
        EconomyFieldId field;
        uint32_t width = 0;
        EconomyFieldEncoding encoding = EconomyFieldEncoding::U8;
        uint64_t lanes = 0, capacity = 1, root_hash = 0;
        std::shared_ptr<const Node> root;
        std::shared_ptr<const Page> page_at(uint64_t index) const {
            if (index >= capacity) return {};
            auto node = root;
            for (uint64_t span = capacity; node && span > 1; span /= 2) {
                if (index < span / 2) node = node->left;
                else { index -= span / 2; node = node->right; }
            }
            return node ? node->page : nullptr;
        }
    };
    struct Metrics { uint64_t encoded_bytes = 0, rebuilt_pages = 0, directory_nodes = 0, compared_dirty_bytes = 0; };
private:
    View _view;
    Metrics _metrics;
    static constexpr uint64_t OFFSET = 1469598103934665603ULL;
    static uint64_t mix(uint64_t h, uint64_t value) { return economy_hash_u64(h, value); }
    static uint64_t empty() { return mix(mix(OFFSET, 0x454d505459ULL), HASH_VERSION); }
    static uint64_t digest(const std::shared_ptr<const Node> &node) { return node ? node->digest : empty(); }
    std::shared_ptr<const Node> branch(std::shared_ptr<const Node> left, std::shared_ptr<const Node> right) {
        if (!left && !right) return {};
        auto node = std::make_shared<Node>();
        node->left = std::move(left); node->right = std::move(right);
        node->digest = mix(mix(mix(OFFSET, 0x4e4f4445ULL), digest(node->left)), digest(node->right));
        ++_metrics.directory_nodes;
        return node;
    }
    std::shared_ptr<const Node> replace(const std::shared_ptr<const Node> &old,
        uint64_t span, uint64_t index, std::shared_ptr<const Page> page) {
        if (span == 1) {
            if (!page) return {};
            auto node = std::make_shared<Node>();
            node->page = std::move(page); node->digest = node->page->digest;
            ++_metrics.directory_nodes;
            return node;
        }
        auto left = old ? old->left : nullptr;
        auto right = old ? old->right : nullptr;
        if (index < span / 2) left = replace(left, span / 2, index, std::move(page));
        else right = replace(right, span / 2, index - span / 2, std::move(page));
        return branch(std::move(left), std::move(right));
    }
public:
    View view() const { return _view; }
    Metrics metrics() const noexcept { return _metrics; }
    template<class T> static constexpr EconomyFieldEncoding encoding_for() {
        constexpr unsigned width_id = sizeof(T) == 1 ? 0 : sizeof(T) == 2 ? 1 : sizeof(T) == 4 ? 2 : 3;
        return static_cast<EconomyFieldEncoding>(width_id + (std::is_signed<T>::value ? 4 : 0));
    }
    template<class T> View update(const std::vector<T> &values, const EconomyColumnChange &change,
        EconomyFieldEncoding encoding = encoding_for<T>()) {
        static_assert(std::is_integral<T>::value && !std::is_same<T, bool>::value, "integral columns only");
        static_assert(sizeof(T) <= sizeof(uint64_t), "unsupported canonical field width");
        if (!change.field.domain || !change.field.column) throw std::logic_error("economy_page_field_invalid");
        if (change.lanes != values.size()) throw std::logic_error("economy_page_shape_mismatch");
        if (encoding != encoding_for<T>() && !(encoding == EconomyFieldEncoding::CanonicalRecord && sizeof(T) == 1))
            throw std::logic_error("economy_page_encoding_invalid");
        if (_view.width && (!(_view.field == change.field) || _view.width != sizeof(T) || _view.encoding != encoding))
            throw std::logic_error("economy_page_identity_mismatch");
        _metrics = {};
        _view.field = change.field; _view.width = sizeof(T); _view.encoding = encoding;
        const uint64_t per_page = PAGE_BYTES / sizeof(T);
        const uint64_t pages = values.size() / per_page + (values.size() % per_page != 0);
        const uint64_t old_pages = _view.lanes / per_page + (_view.lanes % per_page != 0);
        uint64_t capacity = 1;
        while (capacity < pages) capacity *= 2;
        // Process shrink removals before dropping directory levels, so later
        // growth cannot resurrect bytes from a previously removed lane.
        for (uint64_t index : change.pages) {
            if (index < pages || index >= _view.capacity) continue;
            _view.root = replace(_view.root, _view.capacity, index, {});
        }
        while (_view.capacity < capacity) {
            _view.root = branch(_view.root, {}); _view.capacity *= 2;
        }
        while (_view.capacity > capacity) {
            _view.root = _view.root ? _view.root->left : nullptr; _view.capacity /= 2;
        }
        for (uint64_t index : change.pages) {
            if (index >= pages) continue;
            const uint64_t first = index * per_page;
            const uint64_t count = std::min<uint64_t>(per_page, values.size() - first);
            const auto previous = _view.page_at(index);
            if (previous && previous->bytes.size() == count * sizeof(T)) {
                bool same = true;
                for (uint64_t lane = 0; lane < count && same; ++lane) {
                    uint64_t value = static_cast<typename std::make_unsigned<T>::type>(values[first + lane]);
                    for (size_t byte = 0; byte < sizeof(T); ++byte) {
                        ++_metrics.compared_dirty_bytes;
                        if (previous->bytes[lane * sizeof(T) + byte] != static_cast<uint8_t>(value)) {
                            same = false; break;
                        }
                        value >>= 8;
                    }
                }
                if (same) continue;
            }
            auto page = std::make_shared<Page>();
            page->bytes.reserve(static_cast<size_t>(count * sizeof(T)));
            uint64_t h = mix(mix(mix(mix(mix(mix(OFFSET, 0x4c454146ULL), HASH_VERSION), change.field.domain), change.field.column), index), count * sizeof(T));
            h = mix(mix(h, sizeof(T)), static_cast<uint8_t>(encoding));
            for (uint64_t lane = first; lane < first + count; ++lane) {
                uint64_t value = static_cast<typename std::make_unsigned<T>::type>(values[lane]);
                for (size_t byte = 0; byte < sizeof(T); ++byte) {
                    page->bytes.push_back(static_cast<uint8_t>(value)); value >>= 8;
                }
            }
            for (uint8_t byte : page->bytes) h = (h ^ byte) * 1099511628211ULL;
            page->digest = h;
            _metrics.encoded_bytes += page->bytes.size(); ++_metrics.rebuilt_pages;
            _view.root = replace(_view.root, capacity, index, std::move(page));
        }
        _view.lanes = values.size();
        for (uint64_t index = old_pages; index < pages; ++index) {
            if (!_view.page_at(index)) throw std::logic_error("economy_page_new_lane_unregistered");
        }
        if (pages && _view.page_at(pages - 1)->bytes.size() !=
            (values.size() - (pages - 1) * per_page) * sizeof(T))
            throw std::logic_error("economy_page_tail_unregistered");
        uint64_t h = mix(mix(mix(mix(mix(mix(OFFSET, 0x524f4f54ULL), HASH_VERSION), change.field.domain), change.field.column), sizeof(T)), values.size());
        h = mix(h, static_cast<uint8_t>(encoding));
        _view.root_hash = mix(h, digest(_view.root));
        return _view;
    }
    template<class T> static View rebuild(const std::vector<T> &values, EconomyFieldId id,
        EconomyFieldEncoding encoding = encoding_for<T>()) {
        EconomyColumnChange change; change.field = id; change.lanes = values.size();
        const uint64_t per_page = PAGE_BYTES / sizeof(T);
        const uint64_t pages = values.size() / per_page + (values.size() % per_page != 0);
        for (uint64_t index = 0; index < pages; ++index) change.pages.push_back(index);
        EconomyPagedColumn column;
        return column.update(values, change, encoding);
    }
};

} // namespace pk
