#pragma once

#include "runtime_ideology_pod.h"
#include <cstddef>
#include <type_traits>

namespace pk {

namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr uint32_t SAVE_MAGIC = 0x32504449u; // IDP2
constexpr uint32_t SAVE_END = 0x21444e45u;
constexpr uint32_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;
// Matches NativeIdeologyRuntime::MAX_ERA_INDEX so a command accepted by the
// main runtime can never be rejected by the worker (or vice versa).
constexpr int32_t kMaxEraIndex = 63;

template <typename T, bool = std::is_enum_v<std::remove_cv_t<T>>>
struct raw_type { using type = std::remove_cv_t<T>; };
template <typename T>
struct raw_type<T, true> { using type = std::underlying_type_t<std::remove_cv_t<T>>; };

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using Raw = typename raw_type<T>::type;
    using U = std::make_unsigned_t<Raw>;
    U bits = static_cast<U>(static_cast<Raw>(value));
    for (size_t i = 0; i < sizeof(Raw); ++i) {
        out.push_back(static_cast<uint8_t>(bits & static_cast<U>(0xffu)));
        bits >>= 8u;
    }
}

template <typename T>
bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    using Raw = typename raw_type<T>::type;
    using U = std::make_unsigned_t<Raw>;
    if (data == nullptr || cursor > size || size - cursor < sizeof(Raw)) return false;
    U bits = 0;
    for (size_t i = 0; i < sizeof(Raw); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(Raw);
    value = static_cast<T>(static_cast<Raw>(bits));
    return true;
}

uint64_t hash_bytes(uint64_t hash, const void *data, size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

template <typename T>
uint64_t hash_value(uint64_t hash, const T &value) {
    return hash_bytes(hash, &value, sizeof(value));
}

template <typename T>
uint64_t hash_vector(uint64_t hash, const std::vector<T> &values) {
    hash = hash_value(hash, static_cast<uint64_t>(values.size()));
    for (const T &value : values) hash = hash_value(hash, value);
    return hash;
}

uint64_t hash_text_vector(uint64_t hash, const std::vector<std::string> &values) {
    hash = hash_value(hash, static_cast<uint64_t>(values.size()));
    for (const std::string &value : values)
        hash = hash_bytes(hash, value.data(), value.size());
    return hash;
}

template <typename T>
void append_vector(std::vector<uint8_t> &out, const std::vector<T> &values) {
    append_le<uint32_t>(out, static_cast<uint32_t>(values.size()));
    for (const T value : values) append_le<T>(out, value);
}

template <typename T>
bool read_vector(const uint8_t *data, size_t size, size_t &cursor,
                 std::vector<T> &out, uint32_t limit) {
    uint32_t count = 0;
    if (!read_le(data, size, cursor, count) || count > limit) return false;
    out.resize(count);
    for (T &value : out) if (!read_le(data, size, cursor, value)) return false;
    return true;
}

void rebuild_active_idea_ids(RuntimeIdeologyPodCountryState &country) {
    country.active_idea_ids.clear();
    country.active_idea_ids.reserve(country.ideas.size());
    for (uint32_t ideology_id = 0; ideology_id < country.ideas.size(); ++ideology_id) {
        if (country.ideas[ideology_id].location != RuntimeIdeologyPodLocation::INACTIVE)
            country.active_idea_ids.push_back(ideology_id);
    }
}

} // namespace

} // namespace pk
