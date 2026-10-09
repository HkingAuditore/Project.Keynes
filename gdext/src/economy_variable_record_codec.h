#pragma once
#include "economy_tracked_records.h"
#include <string>

namespace pk {
// Canonical UTF-8 strings and collections carry an explicit 64-bit length.
// Each schema visitor fixes field order and scalar widths; no Variant or
// engine object is retained by this encoder.
template<class T> struct EconomyVariableRecordCodec {
    static constexpr bool VARIABLE_WIDTH = true;
    struct Bytes {
        std::vector<uint8_t> data;
        size_t size = 0;
        template<class Scalar, typename std::enable_if<std::is_integral<Scalar>::value, int>::type = 0>
        void operator()(Scalar value) {
            if constexpr (std::is_same<Scalar, bool>::value) data.push_back(value ? 1 : 0);
            else {
                uint64_t bits = static_cast<typename std::make_unsigned<Scalar>::type>(value);
                for (size_t byte = 0; byte < sizeof(Scalar); ++byte) { data.push_back(static_cast<uint8_t>(bits)); bits >>= 8; }
            }
            size = data.size();
        }
        void operator()(const std::string &value) {
            (*this)(static_cast<uint64_t>(value.size()));
            data.insert(data.end(), value.begin(), value.end()); size = data.size();
        }
        template<class Value> void operator()(const std::vector<Value> &values) {
            (*this)(static_cast<uint64_t>(values.size()));
            for (const auto &value : values) (*this)(value);
        }
        template<class Value, size_t N> void operator()(const std::array<Value, N> &values) {
            for (const auto &value : values) (*this)(value);
        }
        template<class A, class B> void operator()(const std::pair<A, B> &value) {
            (*this)(value.first); (*this)(value.second);
        }
        template<class Value, typename std::enable_if<!std::is_integral<Value>::value, int>::type = 0>
        auto operator()(const Value &value) -> decltype(value.visit_persisted(*this), void()) {
            value.visit_persisted(*this);
        }
    };
    static Bytes encode(const T &record) {
        Bytes result;
        result(record);
        return result;
    }
};
template<class T> using EconomyTrackedVariableRecords = EconomyTrackedRecords<T, EconomyVariableRecordCodec<T>>;
} // namespace pk
