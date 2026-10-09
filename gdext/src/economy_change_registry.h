#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace pk {

struct EconomyFieldId {
    uint32_t domain = 0, column = 0;
    uint64_t key() const noexcept { return (uint64_t(domain) << 32) | column; }
    bool operator==(EconomyFieldId other) const noexcept { return key() == other.key(); }
};

enum class EconomyFieldEncoding : uint8_t { U8, U16, U32, U64, I8, I16, I32, I64, CanonicalRecord };
enum class EconomyChangeConsumer : uint8_t { Hash, Audit, Publish, Count };
enum class EconomyAuditRole : uint8_t { None, Population, Cash, Goods };

struct EconomyFieldDescriptor {
    EconomyFieldId id;
    const char *name = nullptr;
    EconomyFieldEncoding encoding = EconomyFieldEncoding::U8;
    uint32_t width = 1;
    EconomyAuditRole audit_role = EconomyAuditRole::None;
};

class EconomyFieldCatalog {
    std::map<uint64_t, EconomyFieldDescriptor> _fields;
public:
    void add(EconomyFieldDescriptor field) {
        if (!field.id.domain || !field.id.column || !field.name || !field.width ||
            4096 % field.width != 0 || !_fields.emplace(field.id.key(), field).second)
            throw std::logic_error("economy_field_catalog_invalid_or_duplicate");
    }
    const EconomyFieldDescriptor &at(EconomyFieldId id) const { return _fields.at(id.key()); }
    const std::map<uint64_t, EconomyFieldDescriptor> &fields() const noexcept { return _fields; }
};

struct EconomyColumnChange {
    EconomyFieldId field;
    uint64_t lanes = 0, structure_revision = 0;
    bool structure_changed = false;
    std::vector<uint64_t> pages;
};

struct EconomyChangeBatch {
    uint64_t revision = 0;
    std::vector<EconomyColumnChange> columns;
};

// Worker tasks own these sinks. Only the coordinator mutates the registry.
struct EconomyWorkerChanges {
    struct Range { EconomyFieldId field; uint64_t first, count; };
    struct Preimage { EconomyFieldId field; uint64_t lane, bits; };
    std::vector<Range> ranges;
    std::vector<Preimage> preimages;
    void capture_before(EconomyFieldId id, uint64_t lane, uint64_t bits) {
        preimages.push_back({id, lane, bits});
    }
    void touch(EconomyFieldId id, uint64_t first, uint64_t count) {
        if (!count) return;
        if (!ranges.empty() && ranges.back().field == id &&
            ranges.back().first + ranges.back().count == first) {
            ranges.back().count += count;
        } else ranges.push_back({id, first, count});
    }
    void clear() { ranges.clear(); preimages.clear(); }
};

struct EconomyAuditChanges {
    struct Preimage { uint64_t lane, bits; };
    std::vector<Preimage> preimages;
    bool requires_full_reference = false;
};

class ChangeRegistry {
    struct Entry {
        EconomyColumnChange current;
        uint32_t width = 0;
        uint64_t mutation_revision = 0;
        EconomyAuditRole audit_role = EconomyAuditRole::None;
        uint64_t audit_epoch = 1;
        std::vector<uint64_t> audit_stamps;
        EconomyAuditChanges audit;
        std::vector<uint64_t> stamps;
        std::vector<uint8_t> consumer_pending;
        std::array<std::vector<uint64_t>, static_cast<size_t>(EconomyChangeConsumer::Count)> consumer_pages;
    };
    std::map<uint64_t, Entry> _entries;
    EconomyFieldCatalog _catalog;
    std::deque<EconomyChangeBatch> _sealed;
    uint64_t _epoch = 1, _revision = 0;
    std::array<uint64_t, static_cast<size_t>(EconomyChangeConsumer::Count)> _cursors{};
public:
    ChangeRegistry() = default;
    ChangeRegistry(const ChangeRegistry &) = delete;
    ChangeRegistry &operator=(const ChangeRegistry &) = delete;
    ChangeRegistry(ChangeRegistry &&) = delete;
    ChangeRegistry &operator=(ChangeRegistry &&) = delete;
    class WriterHandle {
        friend class ChangeRegistry;
        const ChangeRegistry *_owner = nullptr;
        Entry *_entry = nullptr;
        WriterHandle(const ChangeRegistry *owner, Entry *entry) : _owner(owner), _entry(entry) {}
    public:
        WriterHandle() = default;
    };
    WriterHandle register_field(EconomyFieldDescriptor field, uint64_t lanes = 0) {
        if (!field.id.domain || !field.id.column || !field.width || 4096 % field.width)
            throw std::logic_error("economy_change_field_invalid");
        Entry entry;
        entry.width = field.width;
        entry.audit_role = field.audit_role;
        entry.current.field = field.id;
        entry.current.lanes = lanes;
        _catalog.add(field);
        const auto inserted = _entries.emplace(field.id.key(), std::move(entry));
        if (!inserted.second)
            throw std::logic_error("economy_change_field_duplicate");
        return WriterHandle(this, &inserted.first->second);
    }
    void touch_pages(EconomyFieldId id, uint64_t first, uint64_t count) {
        touch_pages(WriterHandle(this, &_entries.at(id.key())), first, count);
    }
    void capture_before(WriterHandle writer, uint64_t lane, uint64_t bits) {
        if (writer._owner != this || !writer._entry) throw std::logic_error("economy_change_writer_invalid");
        auto &entry = *writer._entry;
        if (entry.audit_role == EconomyAuditRole::None) return;
        if (lane >= entry.current.lanes) throw std::out_of_range("economy_audit_preimage_lane_invalid");
        if (entry.audit_stamps.size() <= lane) entry.audit_stamps.resize(static_cast<size_t>(lane + 1), 0);
        if (entry.audit_stamps[lane] == entry.audit_epoch) return;
        entry.audit_stamps[lane] = entry.audit_epoch;
        entry.audit.preimages.push_back({lane, bits});
    }
    void capture_before(EconomyFieldId id, uint64_t lane, uint64_t bits) {
        capture_before(WriterHandle(this, &_entries.at(id.key())), lane, bits);
    }
    EconomyAuditChanges take_audit(EconomyFieldId id) {
        auto &entry = _entries.at(id.key());
        EconomyAuditChanges result;
        result.preimages.swap(entry.audit.preimages);
        result.requires_full_reference = entry.audit.requires_full_reference;
        entry.audit.requires_full_reference = false;
        if (++entry.audit_epoch == 0) {
            std::fill(entry.audit_stamps.begin(), entry.audit_stamps.end(), 0);
            entry.audit_epoch = 1;
        }
        return result;
    }
    void touch_pages(WriterHandle writer, uint64_t first, uint64_t count) {
        if (writer._owner != this || !writer._entry) throw std::logic_error("economy_change_writer_invalid");
        auto &entry = *writer._entry;
        if (!count) return;
        ++entry.mutation_revision;
        if (first > UINT64_MAX - count) throw std::overflow_error("economy_dirty_range_overflow");
        const uint64_t end = first + count;
        if (end > entry.stamps.size()) entry.stamps.resize(static_cast<size_t>(end), 0);
        if (end > entry.consumer_pending.size()) entry.consumer_pending.resize(static_cast<size_t>(end), 0);
        for (uint64_t page = first; page < end; ++page) {
            for (size_t consumer = 0; consumer < entry.consumer_pages.size(); ++consumer) {
                const uint8_t bit = static_cast<uint8_t>(1u << consumer);
                if (entry.consumer_pending[page] & bit) continue;
                entry.consumer_pending[page] |= bit;
                entry.consumer_pages[consumer].push_back(page);
            }
            if (entry.stamps[page] == _epoch) continue;
            entry.stamps[page] = _epoch;
            entry.current.pages.push_back(page);
        }
    }
    void touch(EconomyFieldId id, uint64_t first, uint64_t count) {
        touch(WriterHandle(this, &_entries.at(id.key())), first, count);
    }
    void touch(WriterHandle writer, uint64_t first, uint64_t count) {
        if (!count) return;
        if (writer._owner != this || !writer._entry) throw std::logic_error("economy_change_writer_invalid");
        const auto &entry = *writer._entry;
        if (first > entry.current.lanes || count > entry.current.lanes - first)
            throw std::out_of_range("economy_dirty_lane_range_invalid");
        const uint64_t per_page = 4096 / entry.width;
        touch_pages(writer, first / per_page, (first + count - 1) / per_page - first / per_page + 1);
    }
    void reshape(EconomyFieldId id, uint64_t lanes) {
        auto &entry = _entries.at(id.key());
        const uint64_t old = entry.current.lanes;
        if (old == lanes) return;
        ++entry.mutation_revision;
        entry.current.lanes = lanes;
        entry.current.structure_changed = true;
        if (entry.audit_role != EconomyAuditRole::None) entry.audit.requires_full_reference = true;
        ++entry.current.structure_revision;
        const uint64_t per_page = 4096 / entry.width;
        const uint64_t first = std::min(old, lanes) / per_page;
        const uint64_t end = std::max(old, lanes) / per_page +
            (std::max(old, lanes) % per_page != 0);
        if (end > first) touch_pages(id, first, end - first);
    }
    void reorder(EconomyFieldId id, uint64_t first, uint64_t count) {
        auto &entry = _entries.at(id.key());
        ++entry.current.structure_revision;
        entry.current.structure_changed = true;
        if (entry.audit_role != EconomyAuditRole::None) entry.audit.requires_full_reference = true;
        ++entry.mutation_revision;
        touch(id, first, count);
    }
    void mark_all(EconomyFieldId id) {
        const auto lanes = _entries.at(id.key()).current.lanes;
        touch(id, 0, lanes);
    }
    void merge(const EconomyWorkerChanges &sink, uint32_t domain = 0) {
        for (const auto &before : sink.preimages) {
            if (domain && before.field.domain != domain) continue;
            capture_before(WriterHandle(this, &_entries.at(before.field.key())), before.lane, before.bits);
        }
        for (const auto &range : sink.ranges) {
            if (domain && range.field.domain != domain) continue;
            touch(range.field, range.first, range.count);
        }
    }
    EconomyChangeBatch seal() {
        EconomyChangeBatch batch;
        batch.revision = ++_revision;
        for (auto &pair : _entries) {
            auto &current = pair.second.current;
            if (current.pages.empty() && !current.structure_changed) continue;
            std::sort(current.pages.begin(), current.pages.end());
            batch.columns.push_back(current);
            current.pages.clear();
            current.structure_changed = false;
        }
        _sealed.push_back(batch);
        if (++_epoch == 0) {
            for (auto &pair : _entries) std::fill(pair.second.stamps.begin(), pair.second.stamps.end(), 0);
            _epoch = 1;
        }
        return batch;
    }
    const std::deque<EconomyChangeBatch> &pending() const noexcept { return _sealed; }
    const EconomyFieldCatalog &catalog() const noexcept { return _catalog; }
    uint64_t mutation_revision(EconomyFieldId id) const { return _entries.at(id.key()).mutation_revision; }
    uint64_t mutation_revision(WriterHandle writer) const {
        if (writer._owner != this || !writer._entry) throw std::logic_error("economy_change_writer_invalid");
        return writer._entry->mutation_revision;
    }
    std::vector<uint64_t> take_pages(EconomyFieldId id, EconomyChangeConsumer consumer) {
        auto &entry = _entries.at(id.key());
        const size_t index = static_cast<size_t>(consumer);
        if (index >= entry.consumer_pages.size()) throw std::out_of_range("economy_change_consumer_invalid");
        std::vector<uint64_t> result;
        result.swap(entry.consumer_pages[index]);
        const uint8_t bit = static_cast<uint8_t>(1u << index);
        for (uint64_t page : result) entry.consumer_pending[page] &= static_cast<uint8_t>(~bit);
        std::sort(result.begin(), result.end());
        return result;
    }
    uint64_t revision() const noexcept { return _revision; }
    uint64_t cursor(EconomyChangeConsumer consumer) const { return _cursors.at(static_cast<size_t>(consumer)); }
    void acknowledge(EconomyChangeConsumer consumer, uint64_t revision) {
        auto &cursor = _cursors.at(static_cast<size_t>(consumer));
        if (revision < cursor || revision > _revision)
            throw std::logic_error("economy_change_cursor_invalid");
        cursor = revision;
        const uint64_t minimum = *std::min_element(_cursors.begin(), _cursors.end());
        while (!_sealed.empty() && _sealed.front().revision <= minimum) _sealed.pop_front();
    }
};

} // namespace pk
