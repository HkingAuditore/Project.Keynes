#pragma once

#include "effect_runtime.h"
#include "runtime_effect_pod.h"
#include "world_ext.h"
#include "parallel_dispatcher.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_set>

namespace pk {

using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x46454b50U; // PKEF
constexpr uint32_t SAVE_END = 0x21444e45U;
constexpr int32_t MAX_DEFINITIONS = 65536;
constexpr int32_t MAX_METRICS = 65536;
constexpr int32_t MAX_INSTRUCTIONS = 1048576;
constexpr int32_t MAX_COMMANDS = 1048576;
constexpr int32_t MAX_STACK = 256;
} // namespace

// Shared across the effect_runtime*.cpp translation units: one registry.

inline std::unordered_map<std::string, EffectRuntime::BehaviorFn> &behavior_registry() {
    static std::unordered_map<std::string, EffectRuntime::BehaviorFn> registry;
    return registry;
}
inline std::unordered_map<uint64_t, EffectRuntime::BehaviorFn> &behavior_hash_registry() {
    static std::unordered_map<uint64_t, EffectRuntime::BehaviorFn> registry;
    return registry;
}
inline std::mutex &behavior_registry_mutex() {
    static std::mutex mutex;
    return mutex;
}

namespace {

inline uint64_t behavior_id_hash(const std::string &behavior_id) {
    // Match RuntimeEffectPodAuthority::hash_text FNV-1a 64.
    uint64_t hash = 1469598103934665603ull;
    for (unsigned char character : behavior_id) {
        hash ^= static_cast<uint64_t>(character);
        hash *= 1099511628211ull;
    }
    return hash == 0 ? 1ull : hash;
}

template <typename T>
inline void append_le(std::vector<uint8_t> &out, T value) {
    const uint8_t *ptr = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), ptr, ptr + sizeof(T));
}

template <typename T>
inline bool read_le(const uint8_t *bytes, size_t size, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > size) return false;
    std::memcpy(&value, bytes + cursor, sizeof(T));
    cursor += sizeof(T);
    return true;
}

inline void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

inline bool read_string(const uint8_t *bytes, size_t size, size_t &cursor,
                 std::string &value) {
    uint32_t length = 0;
    if (!read_le(bytes, size, cursor, length) || length > 1024 * 1024U ||
        cursor + length > size) return false;
    value.assign(reinterpret_cast<const char *>(bytes + cursor), length);
    cursor += length;
    return true;
}

inline uint64_t fnv_mix(uint64_t hash, const void *data, size_t size) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

inline uint64_t fnv_string(uint64_t hash, const std::string &value) {
    const uint64_t length = static_cast<uint64_t>(value.size());
    hash = fnv_mix(hash, &length, sizeof(length));
    return fnv_mix(hash, value.data(), value.size());
}

template <typename T>
inline uint64_t fnv_value(uint64_t hash, T value) {
    return fnv_mix(hash, &value, sizeof(T));
}

inline PackedInt32Array get_i32(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt32Array());
    return value.get_type() == Variant::PACKED_INT32_ARRAY
        ? static_cast<PackedInt32Array>(value) : PackedInt32Array();
}

inline PackedInt64Array get_i64(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt64Array());
    return value.get_type() == Variant::PACKED_INT64_ARRAY
        ? static_cast<PackedInt64Array>(value) : PackedInt64Array();
}

inline PackedByteArray get_u8(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedByteArray());
    return value.get_type() == Variant::PACKED_BYTE_ARRAY
        ? static_cast<PackedByteArray>(value) : PackedByteArray();
}

inline PackedStringArray get_strings(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedStringArray());
    return value.get_type() == Variant::PACKED_STRING_ARRAY
        ? static_cast<PackedStringArray>(value) : PackedStringArray();
}

inline int32_t i32_at(const PackedInt32Array &values, int32_t index, int32_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

inline int64_t i64_at(const PackedInt64Array &values, int32_t index, int64_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

inline uint8_t u8_at(const PackedByteArray &values, int32_t index, uint8_t fallback) {
    return index >= 0 && index < values.size() ? values[index] : fallback;
}

inline std::string string_at(const PackedStringArray &values, int32_t index) {
    if (index < 0 || index >= values.size()) return {};
    return String(values[index]).utf8().get_data();
}

inline Dictionary failure(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = reason;
    return out;
}

inline int64_t saturating_add(int64_t a, int64_t b) {
    if (b > 0 && a > std::numeric_limits<int64_t>::max() - b)
        return std::numeric_limits<int64_t>::max();
    if (b < 0 && a < std::numeric_limits<int64_t>::min() - b)
        return std::numeric_limits<int64_t>::min();
    return a + b;
}

inline int64_t saturating_sub(int64_t a, int64_t b) {
    if (b > 0 && a < std::numeric_limits<int64_t>::min() + b)
        return std::numeric_limits<int64_t>::min();
    if (b < 0 && a > std::numeric_limits<int64_t>::max() + b)
        return std::numeric_limits<int64_t>::max();
    return a - b;
}

inline int64_t mul_q16(int64_t a, int64_t b) {
    const long double value = static_cast<long double>(a) * static_cast<long double>(b) /
        static_cast<long double>(EffectRuntime::Q16_ONE);
    if (value > static_cast<long double>(std::numeric_limits<int64_t>::max()))
        return std::numeric_limits<int64_t>::max();
    if (value < static_cast<long double>(std::numeric_limits<int64_t>::min()))
        return std::numeric_limits<int64_t>::min();
    return static_cast<int64_t>(std::floor(value));
}

inline int64_t floor_div(int64_t a, int64_t b) {
    if (b == 0) return 0;
    int64_t q = a / b;
    int64_t r = a % b;
    if (r != 0 && ((r > 0) != (b > 0))) --q;
    return q;
}

inline uint64_t make_hash(uint64_t instance_id, uint32_t generation,
                   uint64_t fire_sequence, uint32_t command_index) {
    uint64_t hash = 1469598103934665603ULL;
    hash = fnv_value(hash, instance_id);
    hash = fnv_value(hash, generation);
    hash = fnv_value(hash, fire_sequence);
    hash = fnv_value(hash, command_index);
    return hash;
}

inline uint64_t splitmix64_next(uint64_t &state) {
    uint64_t z = (state += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31U);
}


} // namespace

// Native command validation is shared by catalog compilation and the runtime
// restore path.  Keep the declaration primitive-only so this common header
// does not expose Country/Economy/Modifier API types.
bool native_command_shape_valid(int32_t action, int32_t domain, int32_t opcode,
                                int32_t target_resolver, int32_t duration_days,
                                int32_t stacks, int64_t value,
                                std::string &reason);

} // namespace pk
