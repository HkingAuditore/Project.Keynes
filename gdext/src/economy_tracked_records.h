#pragma once
#include "economy_owned_column.h"
#include <array>
#include <atomic>

namespace pk {
// A record codec visits explicit persisted fields. Padding and transient
// members are never inspected. Overloads are defined beside the record schema.
template<class T> struct EconomyRecordCodec {
    static constexpr bool VARIABLE_WIDTH = false;
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
    template<class Record, class Visitor> static auto visit(const Record &record, Visitor &visitor, int)
        -> decltype(record.visit_persisted(visitor), void()) { record.visit_persisted(visitor); }
    template<class Record, class Visitor> static void visit(const Record &record, Visitor &visitor, long) {
        economy_visit_record(record, visitor);
    }
    static Bytes encode(const T &record) {
        Bytes result;
        if constexpr (std::is_integral<T>::value && !std::is_same<T, bool>::value) result(record);
        else visit(record, result, 0);
        return result;
    }
};

// Sparse records retain their contiguous compute representation, while the
// canonical byte column is updated only by the writer that owns a row guard.
// Immutable commit pages consume this column; no structure padding is hashed.
template<class T, class Codec = EconomyRecordCodec<T>> class EconomyTrackedRecords {
    std::vector<T> _rows;
    EconomyOwnedColumn<uint8_t> _bytes;
    size_t _width;
    std::vector<size_t> _offsets;
    std::atomic<size_t> _guards{0};
    void require_idle() const {
        if (_guards.load(std::memory_order_acquire)) economy_tracking_failure("economy_record_structure_during_write", _bytes.descriptor().name);
    }
    void check_row(size_t row) const {
        if (row >= _rows.size()) economy_tracking_range_failure("economy_record_lane_invalid", _bytes.descriptor().name, row, _rows.size());
    }
    void encode_row(size_t row, EconomyWorkerChanges *sink = nullptr) {
        check_row(row); const auto encoded = Codec::encode(_rows[row]);
        if constexpr (Codec::VARIABLE_WIDTH) {
            if (_offsets.at(row + 1) - _offsets.at(row) != encoded.size + 8) {
                if (sink) throw std::logic_error("economy_variable_record_parallel_resize");
                synchronize(row); return;
            }
            _bytes.write_values(_offsets[row] + 8, encoded.data.data(), encoded.size, sink);
            return;
        }
        if (encoded.size != _width) throw std::logic_error("economy_record_schema_width_changed");
        const size_t first = row * _width;
        bool changed = false;
        for (size_t i = 0; i < _width; ++i) if (_bytes[first + i] != encoded.data[i]) { changed = true; break; }
        if (!changed) return;
        _bytes.write_values(first, encoded.data.data(), _width, sink);
    }
    void synchronize(size_t first) {
        if constexpr (Codec::VARIABLE_WIDTH) {
            _offsets.resize(_rows.size() + 1);
            if (first == 0) _offsets[0] = 0;
            std::vector<uint8_t> suffix;
            for (size_t row = first; row < _rows.size(); ++row) {
                const auto encoded = Codec::encode(_rows[row]);
                if (encoded.size > SIZE_MAX - suffix.size() - 8) throw std::overflow_error("economy_record_size_overflow");
                uint64_t length = encoded.size;
                for (size_t byte = 0; byte < 8; ++byte) { suffix.push_back(static_cast<uint8_t>(length)); length >>= 8; }
                suffix.insert(suffix.end(), encoded.data.begin(), encoded.data.begin() + encoded.size);
                if (_offsets[first] > SIZE_MAX - suffix.size()) throw std::overflow_error("economy_record_size_overflow");
                _offsets[row + 1] = _offsets[first] + suffix.size();
            }
            _bytes.resize(_offsets.back());
            _bytes.write_values(_offsets[first], suffix.data(), suffix.size());
            return;
        }
        if (_rows.size() > SIZE_MAX / _width) throw std::overflow_error("economy_record_size_overflow");
        _bytes.resize(_rows.size() * _width);
        for (size_t row = first; row < _rows.size(); ++row) encode_row(row);
    }
public:
    using value_type = T;
    using const_iterator = typename std::vector<T>::const_iterator;
    explicit EconomyTrackedRecords(EconomyFieldDescriptor field)
        : _bytes(field), _width(Codec::encode(T{}).size) {
        if constexpr (Codec::VARIABLE_WIDTH) { _width = 0; _offsets.push_back(0); }
        if ((!_width && !Codec::VARIABLE_WIDTH) || field.width != 1 || field.encoding != EconomyFieldEncoding::CanonicalRecord)
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
        _rows = std::move(other._rows); _bytes = std::move(other._bytes); _offsets = std::move(other._offsets);
        if constexpr (Codec::VARIABLE_WIDTH) other._offsets.assign(1, 0);
        other._rows.clear(); other._bytes.clear(); return *this;
    }
    EconomyTrackedRecords &operator=(const std::vector<T> &rows) { assign(rows); return *this; }
    const std::vector<T> &values() const noexcept { return _rows; }
    operator const std::vector<T> &() const noexcept { return _rows; }
    const T &operator[](size_t row) const { check_row(row); return _rows[row]; }
    const T &read_at(size_t row, const char *source, int line) const {
        if (row >= _rows.size()) {
            std::fprintf(stderr, "[economy-record-reader] source=%s line=%d\n", source, line);
            std::fflush(stderr);
        }
        check_row(row); return _rows[row];
    }
    const T &front() const { return _rows.front(); }
    const T &back() const { return _rows.back(); }
    const T *data() const noexcept { return _rows.data(); }
    size_t size() const noexcept { return _rows.size(); }
    size_t capacity() const noexcept { return _rows.capacity(); }
    size_t canonical_memory_bytes() const noexcept { return _bytes.capacity() + _offsets.capacity() * sizeof(size_t); }
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
        check_row(index); _rows[index] = record; encode_row(index, sink);
    }
    class WriteRange {
        EconomyTrackedRecords *_owner;
        size_t _first, _count;
        EconomyWorkerChanges *_sink;
    public:
        WriteRange(EconomyTrackedRecords &owner, size_t first, size_t count, EconomyWorkerChanges *sink)
            : _owner(&owner), _first(first), _count(count), _sink(sink) {
            if (first > owner.size() || count > owner.size() - first) economy_tracking_range_failure("economy_record_range_invalid", owner._bytes.descriptor().name, first, owner.size());
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
        const size_t offset = Codec::VARIABLE_WIDTH ? _offsets.at(index) : index * _width;
        _bytes.registry().reorder(_bytes.field_id(), offset, _bytes.size() - offset);
        return begin() + index;
    }
    const_iterator erase(const_iterator first, const_iterator last) {
        require_idle(); const size_t index = first - begin();
        _rows.erase(_rows.begin() + index, _rows.begin() + (last - begin())); synchronize(index);
        const size_t offset = Codec::VARIABLE_WIDTH ? _offsets.at(index) : index * _width;
        _bytes.registry().reorder(_bytes.field_id(), offset, _bytes.size() - offset);
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
        if (count < 2) return;
        std::sort(_rows.begin() + first, _rows.begin() + first + count, compare);
        if constexpr (Codec::VARIABLE_WIDTH) {
            synchronize(first);
            _bytes.registry().reorder(_bytes.field_id(), _offsets[first], _offsets[first + count] - _offsets[first]);
        } else {
            for (size_t row = first; row < first + count; ++row) encode_row(row);
            _bytes.registry().reorder(_bytes.field_id(), first * _width, count * _width);
        }
    }
    template<class Compare> void sort(Compare compare) { sort_range(0, size(), compare); }
    template<class Compare> void stable_sort(Compare compare) {
        require_idle(); if (size() < 2) return;
        std::stable_sort(_rows.begin(), _rows.end(), compare); synchronize(0);
        _bytes.registry().reorder(_bytes.field_id(), 0, _bytes.size());
    }
    template<class Predicate> const_iterator stable_partition(Predicate predicate) {
        require_idle();
        if (empty()) return begin();
        const auto split = std::stable_partition(_rows.begin(), _rows.end(), predicate);
        const size_t index = split - _rows.begin(); synchronize(0);
        _bytes.registry().reorder(_bytes.field_id(), 0, _bytes.size());
        return begin() + index;
    }
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
        const size_t offset = Codec::VARIABLE_WIDTH ? _offsets.at(index) : index * _width;
        _bytes.registry().reorder(_bytes.field_id(), offset, _bytes.size() - offset);
    }
};
} // namespace pk
