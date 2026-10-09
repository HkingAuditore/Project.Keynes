#pragma once

#include "economy_change_registry.h"
#include "economy_hash.h"
#include "economy_row_write_lease.h"
#include <cstring>
#include <atomic>
#include <type_traits>
#include <utility>

namespace pk {

// No mutable vector conversion, element reference or iterator is exposed.
// Writers declare their scalar or guarded range, keeping hot data contiguous.
template<class T> class EconomyTrackedColumn {
    static_assert(std::is_integral<T>::value && !std::is_same<T, bool>::value, "integral columns only");
    std::vector<T> _values;
    ChangeRegistry *_registry;
    EconomyFieldId _field;
    ChangeRegistry::WriterHandle _writer;
    EconomyAuditRole _audit_role;
    std::atomic<size_t> _active_guards{0};
    mutable uint64_t _hash_consumed_revision = 0;
    void require_idle() const {
        if (_active_guards.load(std::memory_order_acquire)) throw std::logic_error("economy_column_structure_during_write");
    }
    void capture_before(size_t index, T value, EconomyWorkerChanges *sink) {
        if (_audit_role == EconomyAuditRole::None) return;
        const uint64_t bits = static_cast<typename std::make_unsigned<T>::type>(value);
        if (sink) sink->capture_before(_field, index, bits);
        else _registry->capture_before(_writer, index, bits);
    }
public:
    using value_type = T;
    EconomyTrackedColumn(ChangeRegistry &registry, EconomyFieldDescriptor descriptor)
        : _registry(&registry), _field(descriptor.id), _audit_role(descriptor.audit_role) {
        if (descriptor.width != sizeof(T)) throw std::logic_error("economy_column_width_invalid");
        constexpr unsigned width_id = sizeof(T) == 1 ? 0 : sizeof(T) == 2 ? 1 : sizeof(T) == 4 ? 2 : 3;
        constexpr auto encoding = static_cast<EconomyFieldEncoding>(width_id + (std::is_signed<T>::value ? 4 : 0));
        if (descriptor.encoding != encoding &&
            !(descriptor.encoding == EconomyFieldEncoding::CanonicalRecord && sizeof(T) == 1))
            throw std::logic_error("economy_column_encoding_invalid");
        _writer = registry.register_field(descriptor);
    }
    EconomyTrackedColumn(const EconomyTrackedColumn &) = delete;
    EconomyTrackedColumn &operator=(const EconomyTrackedColumn &other) {
        if (this != &other) assign(other.values());
        return *this;
    }
    const std::vector<T> &values() const noexcept { return _values; }
    EconomyFieldId field_id() const noexcept { return _field; }
    const EconomyFieldDescriptor &descriptor() const { return _registry->catalog().at(_field); }
    uint64_t mutation_revision() const { return _registry->mutation_revision(_writer); }
    uint64_t hash_consumed_revision() const noexcept { return _hash_consumed_revision; }
    std::vector<uint64_t> take_hash_pages() const {
        auto result = _registry->take_pages(_field, EconomyChangeConsumer::Hash);
        _hash_consumed_revision = mutation_revision();
        return result;
    }
    operator const std::vector<T> &() const noexcept { return _values; }
    const T *data() const noexcept { return _values.data(); }
    const T &operator[](size_t index) const { return _values.at(index); }
    size_t size() const noexcept { return _values.size(); }
    bool empty() const noexcept { return _values.empty(); }
    size_t capacity() const noexcept { return _values.capacity(); }
    using const_iterator = typename std::vector<T>::const_iterator;
    auto begin() const noexcept { return _values.cbegin(); }
    auto end() const noexcept { return _values.cend(); }
    auto rbegin() const noexcept { return _values.crbegin(); }
    auto rend() const noexcept { return _values.crend(); }
    const T &front() const { return _values.front(); }
    const T &back() const { return _values.back(); }
    bool operator==(const std::vector<T> &other) const { return _values == other; }
    bool operator!=(const std::vector<T> &other) const { return _values != other; }
    bool operator==(const EconomyTrackedColumn &other) const { return _values == other._values; }
    bool operator!=(const EconomyTrackedColumn &other) const { return _values != other._values; }
    void reserve(size_t capacity) { require_idle(); _values.reserve(capacity); }
    void clear() { resize(0); }
    void push_back(T value) {
        require_idle(); _values.push_back(value); _registry->reshape(_field, size());
    }
    void pop_back() {
        require_idle();
        if (empty()) throw std::out_of_range("economy_column_pop_empty");
        _values.pop_back(); _registry->reshape(_field, size());
    }
    const_iterator insert(const_iterator position, T value) {
        require_idle();
        const size_t index = static_cast<size_t>(position - begin());
        _values.insert(_values.begin() + index, value); _registry->reshape(_field, size());
        _registry->reorder(_field, index, size() - index);
        return begin() + index;
    }
    template<class Iterator> const_iterator insert(const_iterator position, Iterator first, Iterator last) {
        require_idle();
        const size_t index = static_cast<size_t>(position - begin());
        _values.insert(_values.begin() + index, first, last);
        _registry->reshape(_field, size()); _registry->reorder(_field, index, size() - index);
        return begin() + index;
    }
    const_iterator erase(const_iterator position) {
        const size_t index = static_cast<size_t>(position - begin());
        erase(index, 1); return begin() + index;
    }
    EconomyTrackedColumn &operator=(const std::vector<T> &values) { assign(values); return *this; }
    void move_from(EconomyTrackedColumn &other) {
        require_idle(); other.require_idle();
        _values = std::move(other._values);
        _registry->reshape(_field, size()); _registry->reorder(_field, 0, size());
        other._values.clear(); other._registry->reshape(other._field, 0);
    }
    void assign(size_t count, T value) {
        require_idle(); _values.assign(count, value); _registry->reshape(_field, count);
        _registry->reorder(_field, 0, count);
    }
    template<class Iterator> void assign(Iterator first, Iterator last) {
        require_idle(); _values.assign(first, last); _registry->reshape(_field, size());
        _registry->reorder(_field, 0, size());
    }
    void swap(std::vector<T> &other) {
        require_idle(); _values.swap(other); _registry->reshape(_field, size());
        _registry->reorder(_field, 0, size());
    }
    void write_scalar(size_t index, T value, EconomyWorkerChanges *sink = nullptr) {
        T &target = _values.at(index);
        if (target == value) return;
        capture_before(index, target, sink);
        target = value;
        if (sink) sink->touch(_field, index, 1);
        else _registry->touch(_writer, index, 1);
    }
    void write_values(size_t first, const T *values, size_t count, EconomyWorkerChanges *sink = nullptr) {
        if (first > size() || count > size() - first || (count && !values))
            throw std::out_of_range("economy_column_write_values_invalid");
        for (size_t index = 0; index < count;) {
            if (_values[first + index] == values[index]) { ++index; continue; }
            const size_t start = index;
            do {
                capture_before(first + index, _values[first + index], sink);
                _values[first + index] = values[index]; ++index;
            } while (index < count && _values[first + index] != values[index]);
            if (sink) sink->touch(_field, first + start, index - start);
            else _registry->touch(_writer, first + start, index - start);
        }
    }
    void resize(size_t size, T value = T{}) {
        if (size == _values.size()) return;
        require_idle(); _values.resize(size, value); _registry->reshape(_field, size);
    }
    void assign(const std::vector<T> &values) {
        require_idle(); _values = values; _registry->reshape(_field, _values.size());
        _registry->reorder(_field, 0, _values.size());
    }
    void erase(size_t first, size_t count) {
        require_idle();
        if (first > size() || count > size() - first) throw std::out_of_range("economy_column_erase_invalid");
        if (!count) return;
        _values.erase(_values.begin() + first, _values.begin() + first + count);
        _registry->reshape(_field, size());
        _registry->reorder(_field, first, size() - first);
    }
    class WriteRange {
        EconomyTrackedColumn *_owner;
        size_t _first;
        std::vector<T> _before;
        EconomyWorkerChanges *_sink;
    public:
        WriteRange(EconomyTrackedColumn &owner, size_t first, size_t count, EconomyWorkerChanges *sink)
            : _owner(&owner), _first(first), _sink(sink) {
            if (first > owner.size() || count > owner.size() - first)
                throw std::out_of_range("economy_column_write_range_invalid");
            _before.assign(owner._values.begin() + first, owner._values.begin() + first + count);
            ++owner._active_guards;
        }
        WriteRange(const WriteRange &) = delete;
        WriteRange &operator=(const WriteRange &) = delete;
        WriteRange(WriteRange &&other) noexcept : _owner(other._owner), _first(other._first),
            _before(std::move(other._before)), _sink(other._sink) { other._owner = nullptr; }
        T *data() { return _before.empty() ? nullptr : _owner->_values.data() + _first; }
        size_t size() const noexcept { return _before.size(); }
        ~WriteRange() {
            if (!_owner) return;
            for (size_t index = 0; index < _before.size();) {
                if (_before[index] == _owner->_values[_first + index]) { ++index; continue; }
                const size_t start = index++;
                while (index < _before.size() && _before[index] != _owner->_values[_first + index]) ++index;
                for (size_t changed = start; changed < index; ++changed)
                    _owner->capture_before(_first + changed, _before[changed], _sink);
                if (_sink) _sink->touch(_owner->_field, _first + start, index - start);
                else _owner->_registry->touch(_owner->_writer, _first + start, index - start);
            }
            --_owner->_active_guards;
        }
    };
    WriteRange write_range(size_t first, size_t count, EconomyWorkerChanges *sink = nullptr) {
        return WriteRange(*this, first, count, sink);
    }
    void fill_range(size_t first, size_t count, T value, EconomyWorkerChanges *sink = nullptr) {
        if (!count) return;
        auto guard = write_range(first, count, sink);
        std::fill(guard.data(), guard.data() + count, value);
    }
    T &borrow_row(size_t index, EconomyRowWriteLease &lease) {
        T &value = _values.at(index);
        // Claim the preimage before another write through an overlapping row
        // lease or scalar entry. An unchanged lease contributes a zero delta.
        capture_before(index, value, lease.sink());
        uint64_t before = 0;
        std::memcpy(&before, &value, sizeof(T));
        lease.add(this, index, before, [](void *pointer, size_t lane, uint64_t bits, EconomyWorkerChanges *sink) {
            auto &column = *static_cast<EconomyTrackedColumn *>(pointer);
            T previous{};
            std::memcpy(&previous, &bits, sizeof(T));
            if (previous != column._values[lane]) {
                if (sink) sink->touch(column._field, lane, 1);
                else column._registry->touch(column._writer, lane, 1);
            }
            --column._active_guards;
        });
        ++_active_guards;
        return value;
    }
};

template<bool ByteHash, class T>
uint64_t economy_hash_lanes(uint64_t hash, const EconomyTrackedColumn<T> &values) {
    return economy_hash_lanes<ByteHash>(hash, values.values());
}

} // namespace pk
