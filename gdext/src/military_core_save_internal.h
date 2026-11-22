#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk {

namespace {

constexpr uint16_t kSection_HeaderEnd = 0;
constexpr uint16_t kSection_Counters = 1;
constexpr uint16_t kSection_Pending = 2;
constexpr uint16_t kSection_Lots = 3;
constexpr uint16_t kSection_Training = 4;
constexpr uint16_t kSection_Armies = 5;
constexpr uint16_t kSection_PathArena = 6;
constexpr uint16_t kSection_Templates = 7;
constexpr uint16_t kSection_Stocks = 8;
constexpr uint16_t kSection_Shipments = 9;
constexpr uint16_t kSection_Engagements = 10;
constexpr uint16_t kSection_Wars = 11;
constexpr uint16_t kSection_Truces = 12;
constexpr uint16_t kSection_Reparations = 13;
constexpr uint16_t kSection_BattleLog = 14;
constexpr uint16_t kSection_Areas = 15;
constexpr uint16_t kSection_Policies = 16;
constexpr uint16_t kSection_CellStates = 17;
constexpr uint16_t kSection_Controller = 18;
constexpr uint16_t kSection_Ledger = 19;
constexpr uint16_t kSection_Events = 20;
constexpr uint16_t kSection_Ai = 21;
constexpr uint16_t kSection_IndexContinuation = 22;
constexpr uint16_t kSection_Exploration = 23;
// 24: paid-but-unsettled purchase orders (physical maintenance design §2 D7).
// A row exists between the PROCURE_GOOD emission and the real fill receipt, so
// it MUST survive a save: losing it would leave a treasury already debited with
// nobody to hand the goods to.
constexpr uint16_t kSection_PurchaseOrders = 24;
// 25: physical maintenance objects (design D2/D3). The fixed-point carry and the
// 5-day window MUST survive a save: restoring without them would silently
// forgive or double-count a shortage, and the disrepair verdict would reset to
// "fine" on every load.
constexpr uint16_t kSection_Maintenance = 25;
constexpr uint16_t kSection_BudgetEnvelope = 26;
constexpr uint16_t kSection_End = 0xFFFF;

// Sanity caps so a corrupt length can never trigger an enormous allocation.
constexpr uint32_t kMaxRows = 4u * 1024u * 1024u;

class Writer {
public:
    std::vector<uint8_t> out;

    void u8(uint8_t v) { out.push_back(v); }
    void u16(uint16_t v) {
        out.push_back((uint8_t)(v & 0xFF));
        out.push_back((uint8_t)(v >> 8));
    }
    void u32(uint32_t v) {
        for (int i = 0; i < 4; ++i) out.push_back((uint8_t)((v >> (8 * i)) & 0xFF));
    }
    void u64(uint64_t v) {
        for (int i = 0; i < 8; ++i) out.push_back((uint8_t)((v >> (8 * i)) & 0xFF));
    }
    void i8(int8_t v) { u8((uint8_t)v); }
    void i16(int16_t v) { u16((uint16_t)v); }
    void i32(int32_t v) { u32((uint32_t)v); }
    void i64(int64_t v) { u64((uint64_t)v); }
    void begin(uint16_t id) {
        u16(id);
        u32(0);   // patched by end()
        _patch.push_back(out.size() - 4);
    }
    void end() {
        const size_t patch = _patch.back();
        _patch.pop_back();
        const uint32_t len = (uint32_t)(out.size() - patch - 4);
        for (int i = 0; i < 4; ++i) out[patch + (size_t)i] = (uint8_t)((len >> (8 * i)) & 0xFF);
    }

private:
    std::vector<size_t> _patch;
};

class Reader {
public:
    Reader(const uint8_t *data, size_t size) : _data(data), _size(size) {}

    bool ok() const { return _ok; }
    size_t pos() const { return _pos; }
    size_t remaining() const { return _ok ? _size - _pos : 0; }
    size_t section_remaining() const { return _section_end > _pos ? _section_end - _pos : 0; }
    bool need(size_t n) {
        if (!_ok || _pos + n > _size) {
            _ok = false;
            return false;
        }
        return true;
    }
    uint8_t u8() {
        if (!need(1)) return 0;
        return _data[_pos++];
    }
    uint16_t u16() {
        if (!need(2)) return 0;
        const uint16_t v = (uint16_t)(_data[_pos] | ((uint16_t)_data[_pos + 1] << 8));
        _pos += 2;
        return v;
    }
    uint32_t u32() {
        if (!need(4)) return 0;
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= (uint32_t)_data[_pos + (size_t)i] << (8 * i);
        _pos += 4;
        return v;
    }
    uint64_t u64() {
        if (!need(8)) return 0;
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= (uint64_t)_data[_pos + (size_t)i] << (8 * i);
        _pos += 8;
        return v;
    }
    int8_t i8() { return (int8_t)u8(); }
    int16_t i16() { return (int16_t)u16(); }
    int32_t i32() { return (int32_t)u32(); }
    int64_t i64() { return (int64_t)u64(); }
    uint32_t open_section() {
        const uint16_t id = u16();
        const uint32_t len = u32();
        if (!_ok) return 0;
        if (id == kSection_End) {   // END carries a checksum (magic ^ size), not a length
            _section_end = _pos;
            return id;
        }
        if (len > remaining()) {
            _ok = false;
            return 0;
        }
        _section_end = _pos + len;
        return id;
    }
    void close_section() {
        if (!_ok) return;
        if (_pos != _section_end) {
            // Tolerate forward-compatible extra bytes inside a section.
            if (_section_end > _pos) _pos = _section_end;
        }
    }

private:
    const uint8_t *_data = nullptr;
    size_t _size = 0;
    size_t _pos = 0;
    size_t _section_end = 0;
    bool _ok = true;
};

} // namespace

} // namespace pk
