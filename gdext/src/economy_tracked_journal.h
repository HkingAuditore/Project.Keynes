#pragma once
#include "economy_tracked_records.h"
#include <unordered_map>

namespace pk {
// Retain the source journal's lookup and read iteration semantics. Canonical
// row indices are a transient adapter; keyed hashing uses key_at(row), never
// their insertion order. Neither indices nor cache bytes are authority saves.
template<class Key, class Record> class EconomyTrackedJournal {
    std::unordered_map<Key, Record> _records;
    std::unordered_map<Key, size_t> _indices;
    std::vector<Key> _keys;
    ChangeRegistry _changes;
    EconomyFieldDescriptor _field;
    std::unordered_map<Key, std::shared_ptr<const std::vector<uint8_t>>> _payloads;
    size_t _width;
    std::atomic<size_t> _guards{0};
    void require_idle() const {
        if (_guards.load(std::memory_order_acquire)) economy_tracking_failure("economy_journal_structure_during_write", _field.name);
    }
    void encode(Key key) {
        const auto encoded = EconomyRecordCodec<Record>::encode(_records.at(key));
        if (encoded.size != _width) throw std::logic_error("economy_journal_schema_width_changed");
        std::vector<uint8_t> bytes(encoded.data.begin(), encoded.data.begin() + encoded.size);
        const auto old = _payloads.find(key);
        if (old != _payloads.end() && *old->second == bytes) return;
        _payloads[key] = std::make_shared<const std::vector<uint8_t>>(std::move(bytes));
        _changes.touch_key(_field.id, static_cast<uint64_t>(key));
    }
public:
    static constexpr bool INDEXED_KEYS = false;
    using const_iterator = typename std::unordered_map<Key, Record>::const_iterator;
    explicit EconomyTrackedJournal(EconomyFieldDescriptor field)
        : _field(field), _width(EconomyRecordCodec<Record>::encode(Record{}).size) {
        if (!_width || field.width != 1 || field.encoding != EconomyFieldEncoding::CanonicalRecord)
            throw std::logic_error("economy_journal_descriptor_invalid");
        _field.layout = EconomyFieldLayout::KeyedRows; _changes.register_field(_field);
    }
    EconomyTrackedJournal(const EconomyTrackedJournal &other) : EconomyTrackedJournal(other._field) {
        *this = other;
    }
    EconomyTrackedJournal(EconomyTrackedJournal &&other) : EconomyTrackedJournal(other._field) {
        *this = std::move(other);
    }
    EconomyTrackedJournal &operator=(const EconomyTrackedJournal &other) {
        if (this == &other) return *this;
        require_idle(); other.require_idle();
        clear(); _records = other._records; _indices = other._indices; _keys = other._keys; _payloads = other._payloads;
        _changes.set_keyed_size(_field.id, size());
        for (auto key : _keys) _changes.touch_key(_field.id, static_cast<uint64_t>(key));
        return *this;
    }
    EconomyTrackedJournal &operator=(EconomyTrackedJournal &&other) {
        if (this == &other) return *this;
        require_idle(); other.require_idle();
        for (auto key : other._keys) other._changes.touch_key(other._field.id, static_cast<uint64_t>(key));
        clear(); _records = std::move(other._records); _indices = std::move(other._indices);
        _keys = std::move(other._keys); _payloads = std::move(other._payloads);
        _changes.set_keyed_size(_field.id, size());
        for (auto key : _keys) _changes.touch_key(_field.id, static_cast<uint64_t>(key));
        other.clear(); return *this;
    }
    size_t size() const noexcept { return _records.size(); }
    bool empty() const noexcept { return _records.empty(); }
    const_iterator begin() const noexcept { return _records.cbegin(); }
    const_iterator end() const noexcept { return _records.cend(); }
    const_iterator find(Key key) const { return _records.find(key); }
    const Record &at(Key key) const { return _records.at(key); }
    Key key_at(size_t row) const { return _keys.at(row); }
    size_t record_width() const noexcept { return _width; }
    bool contains_key(uint64_t key) const { return _records.find(static_cast<Key>(key)) != _records.end(); }
    std::vector<uint64_t> all_keys() const {
        std::vector<uint64_t> result; result.reserve(size());
        for (auto key : _keys) result.push_back(static_cast<uint64_t>(key));
        std::sort(result.begin(), result.end()); return result;
    }
    const EconomyFieldDescriptor &descriptor() const noexcept { return _field; }
    std::shared_ptr<const std::vector<uint8_t>> row_page(uint64_t key) const {
        require_idle(); return _payloads.at(static_cast<Key>(key));
    }
    size_t canonical_memory_bytes() const noexcept {
        size_t bytes = _keys.capacity() * sizeof(Key) + _indices.size() *
            (sizeof(std::pair<const Key, size_t>) + 2 * sizeof(void *));
        for (const auto &entry : _payloads) bytes += entry.second->capacity() + sizeof(entry) + 2 * sizeof(void *);
        return bytes;
    }
    ChangeRegistry &registry() noexcept { return _changes; }
    void clear() {
        require_idle(); for (auto key : _keys) _changes.touch_key(_field.id, static_cast<uint64_t>(key));
        _records.clear(); _indices.clear(); _keys.clear(); _payloads.clear(); _changes.set_keyed_size(_field.id, 0);
    }
    size_t erase(Key key) {
        const auto found = _records.find(key);
        if (found == _records.end()) return 0;
        require_idle();
        const size_t index = _indices.at(key);
        const Key last = _keys.back();
        if (index + 1 != _keys.size()) { _keys[index] = last; _indices.at(last) = index; }
        _keys.pop_back(); _indices.erase(key); _records.erase(found); _payloads.erase(key);
        _changes.touch_key(_field.id, static_cast<uint64_t>(key));
        _changes.set_keyed_size(_field.id, size());
        return 1;
    }
    std::pair<const_iterator, bool> emplace(Key key, const Record &record) {
        const auto found = _records.find(key);
        if (found != _records.end()) return {found, false};
        if (_keys.size() == SIZE_MAX / _width) throw std::overflow_error("economy_journal_size_overflow");
        const auto inserted = _records.emplace(key, record);
        _indices.emplace(key, _keys.size()); _keys.push_back(key);
        _changes.set_keyed_size(_field.id, size()); encode(key);
        return {inserted.first, true};
    }
    void write_record(Key key, const Record &record) {
        const auto found = _records.find(key);
        if (found == _records.end()) { emplace(key, record); return; }
        found->second = record; encode(key);
    }
    class Edit {
        EconomyTrackedJournal *_owner;
        Key _key;
    public:
        Edit(EconomyTrackedJournal &owner, Key key) : _owner(&owner), _key(key) {
            (void)owner._records.at(key); ++owner._guards;
        }
        Edit(const Edit &) = delete;
        Edit &operator=(const Edit &) = delete;
        Edit(Edit &&other) noexcept : _owner(other._owner), _key(other._key) { other._owner = nullptr; }
        Record &get() { return _owner->_records.at(_key); }
        ~Edit() {
            if (!_owner) return;
            _owner->encode(_key); --_owner->_guards;
        }
    };
    Edit edit(Key key) { return Edit(*this, key); }
};
} // namespace pk
