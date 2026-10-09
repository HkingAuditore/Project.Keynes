#pragma once

#include "economy_hash.h"
#include <algorithm>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <memory>
#include <type_traits>
#include <vector>

namespace pk {
template<class T> class EconomyTrackedColumn;

inline bool runtime_chunk_hash_enabled() noexcept {
    static const bool enabled = [] {
        const char *value = std::getenv("PK_ECONOMY_HASH_V2");
        return !value || std::strcmp(value, "0") != 0;
    }();
    return enabled;
}

inline bool runtime_hash_migration_enabled() noexcept {
    const char *value = std::getenv("PK_SAVE_MIGRATE");
    return value && std::strcmp(value, "1") == 0;
}

// Canonical integral columns, 4KiB leaves, immutable source pages. Comparing
// source bytes is the conservative fallback for writers not yet dirty-tracked.
// It never assumes an untracked write did not happen.
class RuntimeChunkHash {
public:
    static constexpr size_t PAGE_BYTES = 4096;
    static constexpr uint32_t VERSION = 2;
    struct Page { std::vector<uint8_t> source; uint64_t digest = 0; };
    struct Metrics { uint64_t compared_bytes = 0, copied_bytes = 0, rebuilt_pages = 0, reused_pages = 0; };
    using Pages = std::vector<std::shared_ptr<const Page>>;
    const Pages &pages() const noexcept { return _pages; }
    Metrics metrics() const noexcept { return _metrics; }
    Metrics cumulative_metrics() const noexcept { return _cumulative_metrics; }
    size_t memory_bytes() const noexcept {
        size_t bytes = _tree.capacity() * sizeof(uint64_t) + _pages.capacity() * sizeof(std::shared_ptr<const Page>);
        for (const auto &page : _pages) if (page) bytes += sizeof(Page) + page->source.capacity();
        return bytes;
    }
    void clear() {
        _pages.clear(); _tree.clear(); _lanes = 0; _width = 0;
        _metrics = {}; _cumulative_metrics = {};
        _tracked_owner = nullptr; _tracked_revision = 0;
    }

    template<class T>
    uint64_t update(const EconomyTrackedColumn<T> &values, uint32_t domain, uint32_t column) {
        const uint64_t revision = values.mutation_revision();
        if (_tracked_owner == &values && _tracked_revision == revision &&
            _domain == domain && _column == column && _width == sizeof(T) &&
            _lanes == values.size() && !_tree.empty()) {
            _metrics = {};
            _metrics.reused_pages = _pages.size();
            _cumulative_metrics.reused_pages += _pages.size();
            const char *verify = std::getenv("PK_ECONOMY_HASH_VERIFY");
            if (verify && std::strcmp(verify, "1") == 0 &&
                _last_root != rebuild(values.values(), domain, column)) {
                std::fprintf(stderr, "economy_tracked_hash_mismatch domain=%u column=%u\n", domain, column);
                std::abort();
            }
            return _last_root;
        }
        const bool complete_dirty = _tracked_owner == &values &&
            _tracked_revision >= values.hash_consumed_revision();
        const auto dirty = values.take_hash_pages();
        const uint64_t result = update_impl(values.values(), domain, column,
            complete_dirty ? &dirty : nullptr);
        _tracked_owner = &values; _tracked_revision = revision;
        return result;
    }

    template<class T>
    uint64_t update(const std::vector<T> &values, uint32_t domain, uint32_t column) {
        _tracked_owner = nullptr;
        return update_impl(values, domain, column, nullptr);
    }

private:
    template<class T>
    uint64_t update_impl(const std::vector<T> &values, uint32_t domain, uint32_t column,
        const std::vector<uint64_t> *dirty) {
        static_assert(std::is_integral<T>::value, "canonical integral column required");
        constexpr size_t width = sizeof(T);
        constexpr size_t per_page = PAGE_BYTES / width;
        const size_t count = (values.size() + per_page - 1) / per_page;
        const bool reshape = values.size() != _lanes || _width != width ||
            _domain != domain || _column != column || _tree.empty();
        _metrics = {};
        if (reshape) {
            _pages.assign(count, {});
            _leaf_capacity = 1;
            while (_leaf_capacity < count) _leaf_capacity *= 2;
            _tree.assign(_leaf_capacity * 2, mix(OFFSET, EMPTY));
            _lanes = values.size(); _width = width; _domain = domain; _column = column;
        }
        const size_t iterations = reshape || !dirty ? count : dirty->size();
        for (size_t cursor = 0; cursor < iterations; ++cursor) {
            const size_t block = reshape || !dirty ? cursor : static_cast<size_t>((*dirty)[cursor]);
            if (block >= count) continue;
            const size_t begin = block * per_page;
            const size_t lanes = std::min(per_page, values.size() - begin);
            const size_t bytes = lanes * width;
            const auto *source = reinterpret_cast<const uint8_t *>(values.data() + begin);
            _metrics.compared_bytes += bytes;
            if (_pages[block] && _pages[block]->source.size() == bytes &&
                std::memcmp(source, _pages[block]->source.data(), bytes) == 0) {
                ++_metrics.reused_pages;
                continue;
            }
            auto page = std::make_shared<Page>();
            page->source.assign(source, source + bytes);
            uint64_t hash = mix(mix(mix(mix(mix(mix(OFFSET, LEAF), VERSION), domain), column), block), bytes);
            for (size_t lane = begin; lane < begin + lanes; ++lane) {
                using Unsigned = typename std::make_unsigned<T>::type;
                uint64_t value = static_cast<Unsigned>(values[lane]);
                for (size_t byte = 0; byte < width; ++byte) {
                    hash = (hash ^ static_cast<uint8_t>(value)) * PRIME;
                    value >>= 8;
                }
            }
            page->digest = hash;
            _pages[block] = std::move(page);
            _tree[_leaf_capacity + block] = hash;
            if (!reshape) {
                for (size_t node = (_leaf_capacity + block) / 2; node != 0; node /= 2)
                    _tree[node] = parent(_tree[node * 2], _tree[node * 2 + 1]);
            }
            ++_metrics.rebuilt_pages;
            _metrics.copied_bytes += bytes;
        }
        if (reshape) {
            for (size_t node = _leaf_capacity - 1; node != 0; --node)
                _tree[node] = parent(_tree[node * 2], _tree[node * 2 + 1]);
        }
        _cumulative_metrics.compared_bytes += _metrics.compared_bytes;
        _cumulative_metrics.copied_bytes += _metrics.copied_bytes;
        _cumulative_metrics.rebuilt_pages += _metrics.rebuilt_pages;
        _cumulative_metrics.reused_pages += _metrics.reused_pages;
        const uint64_t root = mix(mix(mix(mix(mix(mix(mix(OFFSET, ROOT), VERSION), domain), column), width), values.size()), _tree[1]);
        static const bool verify = [] {
            const char *value = std::getenv("PK_ECONOMY_HASH_VERIFY");
            return value && std::strcmp(value, "1") == 0;
        }();
        if (verify && !_reference && root != rebuild(values, domain, column)) {
            std::fprintf(stderr, "economy_chunk_hash_mismatch domain=%u column=%u lanes=%zu\n",
                domain, column, values.size());
            std::abort();
        }
        _last_root = root;
        return root;
    }

public:
    template<class T>
    static uint64_t rebuild(const std::vector<T> &values, uint32_t domain, uint32_t column) {
        RuntimeChunkHash reference;
        reference._reference = true;
        return reference.update(values, domain, column);
    }
private:
    static constexpr uint64_t OFFSET = 1469598103934665603ULL, PRIME = 1099511628211ULL;
    static constexpr uint64_t LEAF = 0x4c454146, ROOT = 0x524f4f54, EMPTY = 0x454d5054, NODE = 0x4e4f4445;
    static uint64_t mix(uint64_t hash, uint64_t value) { return economy_hash_u64(hash, value); }
    static uint64_t parent(uint64_t left, uint64_t right) { return mix(mix(mix(OFFSET, NODE), left), right); }
    Pages _pages;
    std::vector<uint64_t> _tree;
    size_t _lanes = 0, _width = 0, _leaf_capacity = 1;
    uint32_t _domain = 0, _column = 0;
    Metrics _metrics;
    Metrics _cumulative_metrics;
    bool _reference = false;
    const void *_tracked_owner = nullptr;
    uint64_t _tracked_revision = 0, _last_root = 0;
};
} // namespace pk
