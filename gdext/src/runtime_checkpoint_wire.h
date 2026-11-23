#pragma once

#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace pk {

struct CheckpointWriter {
    std::vector<uint8_t> bytes;

    template<class T>
    bool field(T value) {
        const uint64_t bits = static_cast<uint64_t>(value);
        for (size_t i = 0; i < sizeof(T); ++i)
            bytes.push_back(static_cast<uint8_t>(bits >> (8u * i)));
        return true;
    }

    template<class Container, class Visit>
    bool rows(const Container &rows, Visit visit) {
        field(static_cast<uint32_t>(rows.size()));
        for (const auto &row : rows) visit(*this, row);
        return true;
    }
};

struct CheckpointReader {
    const uint8_t *data = nullptr;
    size_t size = 0;
    size_t cursor = 0;

    template<class T>
    bool field(T &value) {
        if (sizeof(T) > size - cursor) return false;
        uint64_t bits = 0;
        for (size_t i = 0; i < sizeof(T); ++i)
            bits |= uint64_t(data[cursor++]) << (8u * i);
        value = static_cast<T>(bits);
        return true;
    }

    template<class Container, class Visit>
    bool rows(Container &rows, Visit visit) {
        uint32_t count = 0;
        if (!field(count) || count > size - cursor) return false;
        for (uint32_t i = 0; i < count; ++i) {
            typename Container::value_type row{};
            if (!visit(*this, row)) return false;
            rows.push_back(std::move(row));
        }
        return true;
    }
};

inline constexpr auto checkpoint_scalar = [](auto &io, auto &value) {
    return io.field(value);
};

} // namespace pk
