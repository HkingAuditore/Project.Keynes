#pragma once
#include "economy_owned_column.h"
#include <array>
#include <atomic>

namespace pk {
// A record codec visits explicit persisted fields. Padding and transient
// members are never inspected. Overloads are defined beside the record schema.
template<class T> struct EconomyRecordCodec {
    struct Bytes {
        std::array<uint8_t, 512> data{};
        size_t size = 0;
        template<class Scalar> void operator()(Scalar value) {
            static_assert(std::is_integral<Scalar>::value && !std::is_same<Scalar, bool>::value,
                "canonical records require explicit integral fields");
            if (size + sizeof(Scalar) > data.size()) throw std::length_error("economy_record_width_exceeded");
            uint64_t bits = static_cast<typename std::make_unsigned<Scalar>::type>(value);
            for (size_t byte = 0; byte < sizeof(Scalar); ++byte) { data[size++] = static_cast<uint8_t>(bits); bits >>= 8; }
        }
        template<class Scalar, size_t N> void operator()(const std::array<Scalar, N> &values) {
            for (auto value : values) (*this)(value);
        }
    };
    static Bytes encode(const T &record) {
        Bytes result;
        economy_visit_record(record, result);
        return result;
    }
};

// Sparse records retain their contiguous compute representation, while the
// canonical byte column is updated only by the writer that owns a row guard.
// Immutable commit pages consume this column; no structure padding is hashed.
template<class T> class EconomyTrackedRecords {
    std::vector<T> _rows;
    EconomyOwnedColumn<uint8_t> _bytes;
    size_t _width;
    std::atomic<size_t> _guards{0};
    void require_idle() const {
        if (_guards.load(std::memory_order_acquire)) throw std::logic_error("economy_record_structure_during_write");
    }
    void encode_row(size_t row, EconomyWorkerChanges *sink = nullptr) {
        const auto encoded = EconomyRecordCodec<T>::encode(_rows.at(row));
        if (encoded.size != _width) throw std::logic_error("economy_record_schema_width_changed");
        const size_t first = row * _width;
        bool changed = false;
        for (size_t i = 0; i < _width; ++i) if (_bytes[first + i] != encoded.data[i]) { changed = true; break; }
        if (!changed) return;
        _bytes.write_values(first, encoded.data.data(), _width, sink);
    }
    void synchronize(size_t first) {
        if (_rows.size() > SIZE_MAX / _width) throw std::overflow_error("economy_record_size_overflow");
        _bytes.resize(_rows.size() * _width);
        for (size_t row = first; row < _rows.size(); ++row) encode_row(row);
    }
public:
    using value_type = T;
    using const_iterator = typename std::vector<T>::const_iterator;
    explicit EconomyTrackedRecords(EconomyFieldDescriptor field)
        : _bytes(field), _width(EconomyRecordCodec<T>::encode(T{}).size) {
        if (! _width || field.width != 1 || field.encoding != EconomyFieldEncoding::CanonicalRecord)
            throw std::logic_error("economy_record_descriptor_invalid");
    }
    EconomyTrackedRecords(const EconomyTrackedRecords &other) : EconomyTrackedRecords(other._bytes.descriptor()) {
        assign(other._rows);
    }
    EconomyTrackedRecords(EconomyTrackedRecords &&other) : EconomyTrackedRecords(other._bytes.descriptor()) {
        *this = std::move(other);
    }
    EconomyTrackedRecords &operator=(const EconomyTrackedRecords &other) {
        if (this != &other) assign(other._rows);
        return *this;
    }
    EconomyTrackedRecords &operator=(EconomyTrackedRecords &&other) {
        if (this == &other) return *this;
        require_idle(); other.require_idle();
        _rows = std::move(other._rows); _bytes = std::move(other._bytes);
        other._rows.clear(); other._bytes.clear(); return *this;
    }
    EconomyTrackedRecords &operator=(const std::vector<T> &rows) { assign(rows); return *this; }
    const std::vector<T> &values() const noexcept { return _rows; }
    operator const std::vector<T> &() const noexcept { return _rows; }
    const T &operator[](size_t row) const { return _rows.at(row); }
    const T &front() const { return _rows.front(); }
    const T &back() const { return _rows.back(); }
    const T *data() const noexcept { return _rows.data(); }
    size_t size() const noexcept { return _rows.size(); }
    bool empty() const noexcept { return _rows.empty(); }
    auto begin() const noexcept { return _rows.cbegin(); }
    auto end() const noexcept { return _rows.cend(); }
    auto rbegin() const noexcept { return _rows.crbegin(); }
    auto rend() const noexcept { return _rows.crend(); }
    ChangeRegistry &registry() noexcept { return _bytes.registry(); }
    const EconomyOwnedColumn<uint8_t> &canonical_column() const { require_idle(); return _bytes; }
    size_t record_width() const noexcept { return _width; }
    void reserve(size_t count) { require_idle(); _rows.reserve(count); }
    void clear() { resize(0); }
    void resize(size_t count) {
        if (count == size()) return;
        require_idle(); const size_t first = std::min(count, size()); _rows.resize(count); synchronize(first);
    }
    void assign(const std::vector<T> &rows) {
        require_idle(); _rows = rows; synchronize(0);
        _bytes.registry().reorder(_bytes.field_id(), 0, _bytes.size());
    }
    template<class Iterator> void assign(Iterator first, Iterator last) {
        require_idle(); _rows.assign(first, last); synchronize(0);
        _bytes.registry().reorder(_bytes.field_id(), 0, _bytes.size());
    }
    void push_back(const T &row) { require_idle(); const size_t first = size(); _rows.push_back(row); synchronize(first); }
    void pop_back() { if (empty()) throw std::out_of_range("economy_record_pop_empty"); resize(size() - 1); }
    void write_record(size_t index, const T &record, EconomyWorkerChanges *sink = nullptr) {
        _rows.at(index) = record; encode_row(index, sink);
    }
    class WriteRange {
        EconomyTrackedRecords *_owner;
        size_t _first, _count;
        EconomyWorkerChanges *_sink;
    public:
        WriteRange(EconomyTrackedRecords &owner, size_t first, size_t count, EconomyWorkerChanges *sink)
            : _owner(&owner), _first(first), _count(count), _sink(sink) {
            if (first > owner.size() || count > owner.size() - first) throw std::out_of_range("economy_record_range_invalid");
            ++owner._guards;
        }
        WriteRange(const WriteRange &) = delete;
        WriteRange &operator=(const WriteRange &) = delete;
        WriteRange(WriteRange &&other) noexcept : _owner(other._owner), _first(other._first), _count(other._count), _sink(other._sink) {
            other._owner = nullptr;
        }
        T *data() { return _count ? _owner->_rows.data() + _first : nullptr; }
        T &operator[](size_t index) {
            if (index >= _count) throw std::out_of_range("economy_record_guard_lane_invalid");
            return _owner->_rows[_first + index];
        }
        ~WriteRange() {
            if (!_owner) return;
            for (size_t index = _first; index < _first + _count; ++index) _owner->encode_row(index, _sink);
            --_owner->_guards;
        }
    };
    WriteRange write_range(size_t first, size_t count, EconomyWorkerChanges *sink = nullptr) {
        return WriteRange(*this, first, count, sink);
    }
    WriteRange edit_row(size_t row, EconomyWorkerChanges *sink = nullptr) { return write_range(row, 1, sink); }
    template<class Iterator> const_iterator insert(const_iterator position, Iterator first, Iterator last) {
        require_idle(); const size_t index = position - begin();
        _rows.insert(_rows.begin() + index, first, last); synchronize(index);
        _bytes.registry().reorder(_bytes.field_id(), index * _width, _bytes.size() - index * _width);
        return begin() + index;
    }
    const_iterator erase(const_iterator first, const_iterator last) {
        require_idle(); const size_t index = first - begin();
        _rows.erase(_rows.begin() + index, _rows.begin() + (last - begin())); synchronize(index);
        _bytes.registry().reorder(_bytes.field_id(), index * _width, _bytes.size() - index * _width);
        return begin() + index;
    }
    const_iterator erase(const_iterator row) { return erase(row, row + 1); }
    void swap(std::vector<T> &rows) {
        require_idle(); _rows.swap(rows); synchronize(0);
        _bytes.registry().reorder(_bytes.field_id(), 0, _bytes.size());
    }
    template<class Compare> void sort_range(size_t first, size_t count, Compare compare) {
        require_idle();
        if (first > size() || count > size() - first) throw std::out_of_range("economy_record_sort_range_invalid");
        std::sort(_rows.begin() + first, _rows.begin() + first + count, compare);
        for (size_t row = first; row < first + count; ++row) encode_row(row);
        _bytes.registry().reorder(_bytes.field_id(), first * _width, count * _width);
    }
    template<class Compare> void sort(Compare compare) { sort_range(0, size(), compare); }
    template<class Predicate> void erase_if(Predicate predicate) {
        require_idle();
        const auto first = std::find_if(_rows.begin(), _rows.end(), predicate);
        if (first == _rows.end()) return;
        const size_t index = first - _rows.begin();
        // Match std::remove_if: the already matched first row is not tested twice.
        auto write = first;
        for (auto read = first + 1; read != _rows.end(); ++read)
            if (!predicate(*read)) *write++ = std::move(*read);
        _rows.erase(write, _rows.end()); synchronize(index);
        _bytes.registry().reorder(_bytes.field_id(), index * _width, _bytes.size() - index * _width);
    }
};
} // namespace pk
