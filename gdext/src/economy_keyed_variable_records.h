#pragma once
#include "economy_variable_record_codec.h"
#include <memory>

namespace pk {
// Indexed compute rows and independently encoded immutable row payloads.
// A string/list length change never encodes unrelated following rows.
template<class T> class EconomyKeyedVariableRecords {
    std::vector<T> _rows;
    std::vector<std::shared_ptr<const std::vector<uint8_t>>> _encoded;
    ChangeRegistry _changes;
    EconomyFieldDescriptor _field;
    std::atomic<size_t> _guards{0};
    uint64_t _encoded_rows = 0, _encoded_bytes = 0;
    static EconomyFieldDescriptor keyed(EconomyFieldDescriptor field) {
        field.layout = EconomyFieldLayout::KeyedRows;
        if (field.width != 1 || field.encoding != EconomyFieldEncoding::CanonicalRecord)
            throw std::logic_error("economy_keyed_record_descriptor_invalid");
        return field;
    }
    void require_idle() const {
        if (_guards.load(std::memory_order_acquire)) economy_tracking_failure("economy_record_structure_during_write", _field.name);
    }
    void check_row(size_t row) const {
        if (row >= _rows.size()) economy_tracking_range_failure("economy_record_lane_invalid", _field.name, row, _rows.size());
    }
    void encode_row(size_t row, EconomyWorkerChanges *sink = nullptr) {
        check_row(row);
        auto value = EconomyVariableRecordCodec<T>::encode(_rows[row]);
        if (_encoded.at(row) && *_encoded[row] == value.data) return;
        _encoded_bytes += value.data.size(); ++_encoded_rows;
        _encoded[row] = std::make_shared<const std::vector<uint8_t>>(std::move(value.data));
        if (sink) sink->touch(_field.id, row, 1);
        else _changes.touch_key(_field.id, row);
    }
    void synchronize(size_t first) {
        _encoded.resize(_rows.size()); _changes.reshape(_field.id, _rows.size());
        for (size_t row = first; row < _rows.size(); ++row) encode_row(row);
    }
public:
    static constexpr bool INDEXED_KEYS = true;
    using value_type = T;
    using const_iterator = typename std::vector<T>::const_iterator;
    explicit EconomyKeyedVariableRecords(EconomyFieldDescriptor field) : _field(keyed(field)) {
        _changes.register_field(_field);
    }
    EconomyKeyedVariableRecords(const EconomyKeyedVariableRecords &other) : EconomyKeyedVariableRecords(other._field) { assign(other._rows); }
    EconomyKeyedVariableRecords(EconomyKeyedVariableRecords &&other) : EconomyKeyedVariableRecords(other._field) { *this = std::move(other); }
    EconomyKeyedVariableRecords &operator=(const EconomyKeyedVariableRecords &other) {
        if (this != &other) assign(other._rows); return *this;
    }
    EconomyKeyedVariableRecords &operator=(EconomyKeyedVariableRecords &&other) {
        if (this == &other) return *this;
        require_idle(); other.require_idle(); _rows = std::move(other._rows); _encoded = std::move(other._encoded);
        _changes.reshape(_field.id, size()); _changes.mark_all(_field.id); other.clear(); return *this;
    }
    EconomyKeyedVariableRecords &operator=(const std::vector<T> &rows) { assign(rows); return *this; }
    const std::vector<T> &values() const noexcept { return _rows; }
    operator const std::vector<T> &() const noexcept { return _rows; }
    const T &operator[](size_t row) const { check_row(row); return _rows[row]; }
    const T &front() const { return _rows.front(); }
    const T &back() const { return _rows.back(); }
    const T *data() const noexcept { return _rows.data(); }
    size_t size() const noexcept { return _rows.size(); }
    size_t capacity() const noexcept { return _rows.capacity(); }
    bool empty() const noexcept { return _rows.empty(); }
    bool contains_key(uint64_t key) const noexcept { return key < _rows.size(); }
    std::vector<uint64_t> all_keys() const {
        std::vector<uint64_t> keys; keys.reserve(size());
        for (uint64_t key = 0; key < size(); ++key) keys.push_back(key);
        return keys;
    }
    auto begin() const noexcept { return _rows.cbegin(); }
    auto end() const noexcept { return _rows.cend(); }
    auto rbegin() const noexcept { return _rows.crbegin(); }
    auto rend() const noexcept { return _rows.crend(); }
    ChangeRegistry &registry() noexcept { return _changes; }
    const EconomyFieldDescriptor &descriptor() const noexcept { return _field; }
    std::shared_ptr<const std::vector<uint8_t>> row_page(size_t row) const { require_idle(); check_row(row); return _encoded.at(row); }
    uint64_t encoded_rows() const noexcept { return _encoded_rows; }
    uint64_t encoded_bytes() const noexcept { return _encoded_bytes; }
    size_t canonical_memory_bytes() const noexcept {
        size_t bytes = _encoded.capacity() * sizeof(_encoded[0]);
        for (const auto &row : _encoded) if (row) bytes += row->capacity();
        return bytes;
    }
    void reserve(size_t count) { require_idle(); _rows.reserve(count); _encoded.reserve(count); }
    void clear() { resize(0); }
    void resize(size_t count) {
        if (count == size()) return;
        require_idle(); const size_t first = std::min(count, size()); _rows.resize(count); synchronize(first);
    }
    void assign(const std::vector<T> &rows) { require_idle(); _rows = rows; synchronize(0); _changes.reorder(_field.id, 0, size()); }
    template<class Iterator> void assign(Iterator first, Iterator last) {
        require_idle(); _rows.assign(first, last); synchronize(0); _changes.reorder(_field.id, 0, size());
    }
    void push_back(const T &row) { require_idle(); const size_t first = size(); _rows.push_back(row); synchronize(first); }
    void pop_back() { if (empty()) throw std::out_of_range("economy_record_pop_empty"); resize(size() - 1); }
    void write_record(size_t index, const T &record, EconomyWorkerChanges *sink = nullptr) {
        check_row(index); _rows[index] = record; encode_row(index, sink);
    }
    class WriteRange {
        EconomyKeyedVariableRecords *_owner;
        size_t _first, _count;
        EconomyWorkerChanges *_sink;
    public:
        WriteRange(EconomyKeyedVariableRecords &owner, size_t first, size_t count, EconomyWorkerChanges *sink)
            : _owner(&owner), _first(first), _count(count), _sink(sink) {
            if (first > owner.size() || count > owner.size() - first) economy_tracking_range_failure("economy_record_range_invalid", owner._field.name, first, owner.size());
            ++owner._guards;
        }
        WriteRange(const WriteRange &) = delete;
        WriteRange &operator=(const WriteRange &) = delete;
        WriteRange(WriteRange &&other) noexcept : _owner(other._owner), _first(other._first), _count(other._count), _sink(other._sink) { other._owner = nullptr; }
        T *data() { return _count ? _owner->_rows.data() + _first : nullptr; }
        T &operator[](size_t index) { if (index >= _count) throw std::out_of_range("economy_record_guard_lane_invalid"); return _owner->_rows[_first + index]; }
        ~WriteRange() {
            if (!_owner) return;
            for (size_t row = _first; row < _first + _count; ++row) _owner->encode_row(row, _sink);
            --_owner->_guards;
        }
    };
    WriteRange write_range(size_t first, size_t count, EconomyWorkerChanges *sink = nullptr) { return WriteRange(*this, first, count, sink); }
    WriteRange edit_row(size_t row, EconomyWorkerChanges *sink = nullptr) { return write_range(row, 1, sink); }
    template<class Iterator> const_iterator insert(const_iterator position, Iterator first, Iterator last) {
        require_idle(); const size_t index = position - begin(); _rows.insert(_rows.begin() + index, first, last);
        synchronize(index); _changes.reorder(_field.id, index, size() - index); return begin() + index;
    }
    const_iterator insert(const_iterator position, const T &row) {
        require_idle(); const size_t index = position - begin(); _rows.insert(_rows.begin() + index, row);
        synchronize(index); _changes.reorder(_field.id, index, size() - index); return begin() + index;
    }
    const_iterator erase(const_iterator first, const_iterator last) {
        require_idle(); const size_t index = first - begin(); _rows.erase(_rows.begin() + index, _rows.begin() + (last - begin()));
        synchronize(index); _changes.reorder(_field.id, index, size() - index); return begin() + index;
    }
    const_iterator erase(const_iterator row) { return erase(row, row + 1); }
    void swap(std::vector<T> &rows) { require_idle(); _rows.swap(rows); synchronize(0); _changes.reorder(_field.id, 0, size()); }
    template<class Compare> void sort(Compare compare) {
        require_idle(); if (size() < 2) return; std::sort(_rows.begin(), _rows.end(), compare); synchronize(0); _changes.reorder(_field.id, 0, size());
    }
    template<class Compare> void stable_sort(Compare compare) {
        require_idle(); if (size() < 2) return; std::stable_sort(_rows.begin(), _rows.end(), compare); synchronize(0); _changes.reorder(_field.id, 0, size());
    }
    template<class Predicate> void erase_if(Predicate predicate) {
        require_idle(); const auto first = std::find_if(_rows.begin(), _rows.end(), predicate); if (first == _rows.end()) return;
        const size_t index = first - _rows.begin(); auto write = first;
        for (auto read = first + 1; read != _rows.end(); ++read) if (!predicate(*read)) *write++ = std::move(*read);
        _rows.erase(write, _rows.end()); synchronize(index); _changes.reorder(_field.id, index, size() - index);
    }
};
} // namespace pk
