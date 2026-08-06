#pragma once

#include <cstdint>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace pk::binary_codec {

template <typename T>
inline void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i) {
        out.push_back(static_cast<uint8_t>(
            (bits >> (i * 8)) & static_cast<U>(0xff)));
    }
}

template <typename T>
inline bool read_le(const std::vector<uint8_t> &in, size_t &cursor,
                    T &value) {
    if (cursor + sizeof(T) > in.size()) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(in[cursor++]) << (i * 8);
    value = static_cast<T>(bits);
    return true;
}

inline void append_string(std::vector<uint8_t> &out,
                          const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

inline bool read_string(const std::vector<uint8_t> &in, size_t &cursor,
                        std::string &value) {
    uint32_t length = 0;
    if (!read_le(in, cursor, length) || cursor + length > in.size())
        return false;
    value.assign(reinterpret_cast<const char *>(in.data() + cursor), length);
    cursor += length;
    return true;
}

inline void append_id_table(std::vector<uint8_t> &out,
                            const std::vector<std::string> &ids) {
    append_le<uint32_t>(out, static_cast<uint32_t>(ids.size()));
    for (const std::string &id : ids) append_string(out, id);
}

inline bool read_id_table(const std::vector<uint8_t> &in, size_t &cursor,
                          std::vector<std::string> &ids) {
    uint32_t count = 0;
    if (!read_le(in, cursor, count) || count > 1000000U) return false;
    ids.clear();
    ids.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        std::string value;
        if (!read_string(in, cursor, value)) return false;
        ids.push_back(std::move(value));
    }
    return true;
}

} // namespace pk::binary_codec
