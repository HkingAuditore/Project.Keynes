#pragma once

#include <cstring>
#include <string>
#include <type_traits>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk::variant_helpers {

inline std::string to_utf8(const godot::String &value) {
    const godot::CharString bytes = value.utf8();
    return std::string(bytes.get_data(), static_cast<size_t>(bytes.length()));
}

inline godot::String from_utf8(const std::string &value) {
    return godot::String::utf8(value.data(),
                               static_cast<int64_t>(value.size()));
}

inline std::string dict_string(const godot::Dictionary &d, const char *key,
                               const std::string &fallback = {}) {
    const godot::StringName k(key);
    if (!d.has(k)) return fallback;
    return to_utf8(static_cast<godot::String>(d[k]));
}

template <typename T>
inline T dict_num(const godot::Dictionary &d, const char *key, T fallback) {
    const godot::StringName k(key);
    if (!d.has(k)) return fallback;
    const godot::Variant v = d[k];
    if constexpr (std::is_same_v<T, int64_t>)
        return static_cast<int64_t>(v);
    if constexpr (std::is_same_v<T, int32_t>)
        return static_cast<int32_t>(static_cast<int64_t>(v));
    if constexpr (std::is_same_v<T, bool>) return static_cast<bool>(v);
    if constexpr (std::is_same_v<T, double>) return static_cast<double>(v);
    if constexpr (std::is_same_v<T, float>)
        return static_cast<float>(static_cast<double>(v));
    return fallback;
}

inline std::vector<std::string> packed_strings(const godot::Dictionary &d,
                                               const char *key) {
    std::vector<std::string> out;
    const godot::StringName k(key);
    if (!d.has(k) || d[k].get_type() != godot::Variant::PACKED_STRING_ARRAY)
        return out;
    const godot::PackedStringArray src = d[k];
    out.reserve(src.size());
    for (int i = 0; i < src.size(); ++i) out.push_back(to_utf8(src[i]));
    return out;
}

inline std::vector<int32_t> packed_i32(const godot::Dictionary &d,
                                       const char *key) {
    std::vector<int32_t> out;
    const godot::StringName k(key);
    if (!d.has(k) || d[k].get_type() != godot::Variant::PACKED_INT32_ARRAY)
        return out;
    const godot::PackedInt32Array src = d[k];
    out.resize(src.size());
    if (!out.empty())
        std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int32_t));
    return out;
}

inline std::vector<int64_t> packed_i64(const godot::Dictionary &d,
                                       const char *key) {
    std::vector<int64_t> out;
    const godot::StringName k(key);
    if (!d.has(k) || d[k].get_type() != godot::Variant::PACKED_INT64_ARRAY)
        return out;
    const godot::PackedInt64Array src = d[k];
    out.resize(src.size());
    if (!out.empty())
        std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int64_t));
    return out;
}

} // namespace pk::variant_helpers
