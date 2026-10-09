#pragma once
#include "economy_hash.h"
#include <memory>
#include <cstdint>

namespace pk {
// Fixed binary key order, immutable nodes and a typed missing-node digest.
// Replacing a leaf copies its path; retaining a root pins the old directory.
template<class Value> class EconomyHashDirectory {
public:
    struct Node {
        std::shared_ptr<const Node> left, right;
        std::shared_ptr<const Value> value;
        uint64_t digest = 0;
    };
    using Root = std::shared_ptr<const Node>;
private:
    static constexpr uint64_t OFFSET = 1469598103934665603ULL;
    uint64_t _tag;
    uint64_t _copied_nodes = 0;
    uint64_t mix(uint64_t hash, uint64_t value) const { return economy_hash_u64(hash, value); }
    Root replace_at(const Root &old, int bit, uint64_t key, std::shared_ptr<const Value> value, uint64_t digest) {
        if (bit < 0) {
            if (!value) return {};
            if (old && old->value == value && old->digest == digest) return old;
            auto node = std::make_shared<Node>(); node->value = std::move(value);
            node->digest = digest; ++_copied_nodes; return node;
        }
        Root left = old ? old->left : nullptr, right = old ? old->right : nullptr;
        if (key & (uint64_t(1) << bit)) right = replace_at(right, bit - 1, key, std::move(value), digest);
        else left = replace_at(left, bit - 1, key, std::move(value), digest);
        if (!left && !right) return {};
        if (old && old->left == left && old->right == right) return old;
        auto node = std::make_shared<Node>(); node->left = std::move(left); node->right = std::move(right);
        node->digest = mix(mix(mix(mix(OFFSET, _tag), static_cast<uint64_t>(bit)), root_hash(node->left)), root_hash(node->right));
        ++_copied_nodes; return node;
    }
public:
    explicit EconomyHashDirectory(uint64_t type_tag) : _tag(type_tag) {}
    uint64_t empty_hash() const { return mix(mix(mix(OFFSET, _tag), 0x454d505459ULL), 3); }
    uint64_t root_hash(const Root &root) const { return root ? root->digest : empty_hash(); }
    Root replace(const Root &root, uint64_t key, std::shared_ptr<const Value> value, uint64_t value_digest) {
        const uint64_t digest = mix(mix(mix(OFFSET, _tag ^ 0x4c454146ULL), key), value_digest);
        return replace_at(root, 63, key, std::move(value), digest);
    }
    static std::shared_ptr<const Value> at(Root root, uint64_t key) {
        for (int bit = 63; root && bit >= 0; --bit)
            root = key & (uint64_t(1) << bit) ? root->right : root->left;
        return root ? root->value : nullptr;
    }
    uint64_t copied_nodes() const noexcept { return _copied_nodes; }
};
} // namespace pk
