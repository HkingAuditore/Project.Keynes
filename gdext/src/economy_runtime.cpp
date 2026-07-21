#include "economy_runtime.h"
#include "country_runtime.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <type_traits>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

thread_local NativeEconomyRuntime::ProductionResult *
    NativeEconomyRuntime::_production_result_sink = nullptr;

namespace {

using Clock = std::chrono::steady_clock;
constexpr int64_t PRODUCER_SUPPORT_PRICE_NUMERATOR = 1;
constexpr int64_t PRODUCER_SUPPORT_PRICE_DENOMINATOR = 5;
constexpr int32_t PRICE_NUMERIC_GUARD_MIN = 1;
constexpr int32_t PRICE_NUMERIC_GUARD_MAX = std::numeric_limits<int32_t>::max();

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

std::string to_utf8(const String &value) {
    const CharString bytes = value.utf8();
    return std::string(bytes.get_data(), static_cast<size_t>(bytes.length()));
}

std::string dict_string(const Dictionary &d, const char *key,
                        const std::string &fallback = {}) {
    const StringName k(key);
    if (!d.has(k)) return fallback;
    return to_utf8(static_cast<String>(d[k]));
}

template <typename T>
T dict_num(const Dictionary &d, const char *key, T fallback) {
    const StringName k(key);
    if (!d.has(k)) return fallback;
    const Variant v = d[k];
    if constexpr (std::is_same_v<T, int64_t>) return static_cast<int64_t>(v);
    if constexpr (std::is_same_v<T, int32_t>) return static_cast<int32_t>(static_cast<int64_t>(v));
    if constexpr (std::is_same_v<T, bool>) return static_cast<bool>(v);
    return fallback;
}

std::vector<std::string> packed_strings(const Dictionary &d, const char *key) {
    std::vector<std::string> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_STRING_ARRAY) return out;
    const PackedStringArray src = d[k];
    out.reserve(src.size());
    for (int i = 0; i < src.size(); ++i) out.push_back(to_utf8(src[i]));
    return out;
}

std::vector<int32_t> packed_i32(const Dictionary &d, const char *key) {
    std::vector<int32_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_INT32_ARRAY) return out;
    const PackedInt32Array src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int32_t));
    return out;
}

std::vector<int64_t> packed_i64(const Dictionary &d, const char *key) {
    std::vector<int64_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_INT64_ARRAY) return out;
    const PackedInt64Array src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int64_t));
    return out;
}

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i) {
        out.push_back(static_cast<uint8_t>((bits >> (i * 8)) & static_cast<U>(0xff)));
    }
}

template <typename T>
bool read_le(const std::vector<uint8_t> &in, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > in.size()) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i) {
        bits |= static_cast<U>(in[cursor++]) << (i * 8);
    }
    value = static_cast<T>(bits);
    return true;
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_string(const std::vector<uint8_t> &in, size_t &cursor, std::string &value) {
    uint32_t length = 0;
    if (!read_le(in, cursor, length) || cursor + length > in.size()) return false;
    value.assign(reinterpret_cast<const char *>(in.data() + cursor), length);
    cursor += length;
    return true;
}

void append_id_table(std::vector<uint8_t> &out, const std::vector<std::string> &ids) {
    append_le<uint32_t>(out, static_cast<uint32_t>(ids.size()));
    for (const std::string &id : ids) append_string(out, id);
}

bool read_id_table(const std::vector<uint8_t> &in, size_t &cursor,
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

constexpr uint32_t SAVE_MAGIC = 0x43454b50U; // "PKEC" little endian
constexpr uint16_t SAVE_SECTION_HEADER = 0;
constexpr uint16_t SAVE_SECTION_PAGES = 1;
constexpr uint16_t SAVE_SECTION_MARKETS = 2;
constexpr uint16_t SAVE_SECTION_CELLS = 3;
constexpr uint16_t SAVE_SECTION_COMMANDS = 4;
constexpr uint16_t SAVE_SECTION_BUILDINGS = 5;
constexpr uint16_t SAVE_SECTION_CONSTRUCTION = 6;
constexpr uint16_t SAVE_SECTION_AUDIT = 7;
constexpr uint16_t SAVE_SECTION_SIGNALS = 8;
constexpr uint16_t SAVE_SECTION_LABOR_SIGNALS = 9;
constexpr uint16_t SAVE_SECTION_TRADE_ORDERS = 10;
constexpr uint16_t SAVE_SECTION_TRADE_FLOWS = 11;
constexpr uint16_t SAVE_SECTION_END = 12;
constexpr uint16_t SAVE_SECTION_END_V10 = 10;

constexpr uint32_t EVENT_ARCHIVE_MAGIC = 0x4a454b50U; // "PKEJ" little endian
constexpr uint16_t EVENT_ARCHIVE_VERSION = 3;
constexpr uint16_t EVENT_ARCHIVE_HEADER = 0;
constexpr uint16_t EVENT_ARCHIVE_EVENTS = 1;
constexpr uint16_t EVENT_ARCHIVE_END = 2;

PackedByteArray make_save_chunk(uint16_t section, uint32_t records,
                                const std::vector<uint8_t> &payload) {
    std::vector<uint8_t> bytes;
    bytes.reserve(16 + payload.size());
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<uint16_t>(bytes, static_cast<uint16_t>(NativeEconomyRuntime::SCHEMA_VERSION));
    append_le<uint16_t>(bytes, section);
    append_le<uint32_t>(bytes, records);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    PackedByteArray out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

PackedByteArray make_event_archive_chunk(uint16_t section, uint32_t records,
                                         const std::vector<uint8_t> &payload) {
    std::vector<uint8_t> bytes;
    bytes.reserve(16 + payload.size());
    append_le<uint32_t>(bytes, EVENT_ARCHIVE_MAGIC);
    append_le<uint16_t>(bytes, EVENT_ARCHIVE_VERSION);
    append_le<uint16_t>(bytes, section);
    append_le<uint32_t>(bytes, records);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    PackedByteArray out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

uint64_t magnitude_i64(int64_t v) {
    return v >= 0 ? static_cast<uint64_t>(v)
                  : static_cast<uint64_t>(-(v + 1)) + 1ULL;
}

int64_t clamp_i64_from_unsigned(uint64_t magnitude, bool negative, int64_t &sat) {
    constexpr uint64_t POS_MAX = static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
    constexpr uint64_t NEG_MAX = POS_MAX + 1ULL;
    if ((!negative && magnitude > POS_MAX) || (negative && magnitude > NEG_MAX)) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    if (negative) {
        if (magnitude == NEG_MAX) return std::numeric_limits<int64_t>::min();
        return -static_cast<int64_t>(magnitude);
    }
    return static_cast<int64_t>(magnitude);
}

bool signed_mul_div_rem(int64_t a, int64_t b, int64_t positive_divisor,
                        int64_t &quotient_out, int64_t &remainder_out) {
    if (positive_divisor <= 0) return false;
    const bool negative = (a < 0) ^ (b < 0);
    const uint64_t ua = magnitude_i64(a);
    const uint64_t ub = magnitude_i64(b);
    const uint64_t ud = static_cast<uint64_t>(positive_divisor);
    uint64_t quotient = 0;
    uint64_t remainder = 0;
#if defined(_MSC_VER) && defined(_M_X64)
    uint64_t hi = 0;
    const uint64_t lo = _umul128(ua, ub, &hi);
    if (hi >= ud) return false;
    quotient = _udiv128(hi, lo, ud, &remainder);
#else
    const unsigned __int128 product = static_cast<unsigned __int128>(ua) * ub;
    const unsigned __int128 q = product / ud;
    if (q > static_cast<unsigned __int128>(std::numeric_limits<uint64_t>::max())) return false;
    quotient = static_cast<uint64_t>(q);
    remainder = static_cast<uint64_t>(product % ud);
#endif
    const uint64_t limit = static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) +
                           (negative ? 1ULL : 0ULL);
    if (quotient > limit) return false;
    if (negative) {
        quotient_out = quotient == limit ? std::numeric_limits<int64_t>::min()
                                         : -static_cast<int64_t>(quotient);
        remainder_out = -static_cast<int64_t>(remainder);
    } else {
        quotient_out = static_cast<int64_t>(quotient);
        remainder_out = static_cast<int64_t>(remainder);
    }
    return true;
}

} // namespace

// ─── PopulationStore ───────────────────────────────────────────────────

void NativeEconomyRuntime::PopulationStore::clear(int32_t cells) {
    cell_first_page.assign(std::max(0, cells), -1);
    page_next.clear();
    page_cell.clear();
    free_pages.clear();
    active.clear();
    signature_id.clear();
    generation.clear();
    population.clear();
    funds.clear();
    epoch_income.clear();
    epoch_expense.clear();
    epoch_in_kind_income.clear();
    income_ema.clear();
    needs_satisfaction.clear();
    worst_need_id.clear();
    flags.clear();
    demography_residual.clear();
    owner_employed.clear();
    employee_employed.clear();
    active_count = 0;
    high_water_slots = 0;
}

int32_t NativeEconomyRuntime::PopulationStore::allocate_page(int32_t cell) {
    int32_t page = -1;
    if (!free_pages.empty()) {
        page = free_pages.back();
        free_pages.pop_back();
        page_cell[page] = cell;
        page_next[page] = -1;
        const int32_t base = page * PAGE_SIZE;
        std::fill(active.begin() + base, active.begin() + base + PAGE_SIZE, uint8_t{0});
    } else {
        page = static_cast<int32_t>(page_next.size());
        page_next.push_back(-1);
        page_cell.push_back(cell);
        const size_t next_size = static_cast<size_t>(page + 1) * PAGE_SIZE;
        active.resize(next_size, 0);
        signature_id.resize(next_size, 0);
        generation.resize(next_size, 1);
        population.resize(next_size, 0);
        funds.resize(next_size, 0);
        epoch_income.resize(next_size, 0);
        epoch_expense.resize(next_size, 0);
        epoch_in_kind_income.resize(next_size, 0);
        income_ema.resize(next_size, 0);
        needs_satisfaction.resize(next_size, static_cast<uint16_t>(Q16_ONE - 1));
        worst_need_id.resize(next_size, std::numeric_limits<uint16_t>::max());
        flags.resize(next_size, 0);
        demography_residual.resize(next_size, 0);
        owner_employed.resize(next_size, 0);
        employee_employed.resize(next_size, 0);
        high_water_slots = static_cast<int64_t>(next_size);
    }
    if (cell_first_page[cell] < 0) {
        cell_first_page[cell] = page;
    } else {
        int32_t tail = cell_first_page[cell];
        while (page_next[tail] >= 0) tail = page_next[tail];
        page_next[tail] = page;
    }
    return page;
}

int32_t NativeEconomyRuntime::PopulationStore::find_signature(int32_t cell, uint32_t signature) const {
    int32_t result = -1;
    for_each_in_cell(cell, [&](int32_t slot) {
        if (result < 0 && signature_id[slot] == signature) result = slot;
    });
    return result;
}

int32_t NativeEconomyRuntime::PopulationStore::allocate_slot(int32_t cell, uint32_t signature) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return -1;
    const int32_t existing = find_signature(cell, signature);
    if (existing >= 0) return existing;
    if (cell_first_page[cell] < 0) allocate_page(cell);
    for (int32_t p = cell_first_page[cell]; p >= 0; p = page_next[p]) {
        const int32_t base = p * PAGE_SIZE;
        for (int32_t lane = 0; lane < PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (active[slot] != 0) continue;
            active[slot] = 1;
            signature_id[slot] = signature;
            population[slot] = 0;
            funds[slot] = 0;
            epoch_income[slot] = 0;
            epoch_expense[slot] = 0;
            epoch_in_kind_income[slot] = 0;
            income_ema[slot] = 0;
            needs_satisfaction[slot] = static_cast<uint16_t>(Q16_ONE - 1);
            worst_need_id[slot] = std::numeric_limits<uint16_t>::max();
            flags[slot] = 0;
            demography_residual[slot] = 0;
            owner_employed[slot] = 0;
            employee_employed[slot] = 0;
            ++active_count;
            return slot;
        }
    }
    const int32_t page = allocate_page(cell);
    const int32_t slot = page * PAGE_SIZE;
    active[slot] = 1;
    signature_id[slot] = signature;
    population[slot] = 0;
    funds[slot] = 0;
    epoch_income[slot] = 0;
    epoch_expense[slot] = 0;
    epoch_in_kind_income[slot] = 0;
    income_ema[slot] = 0;
    needs_satisfaction[slot] = static_cast<uint16_t>(Q16_ONE - 1);
    worst_need_id[slot] = std::numeric_limits<uint16_t>::max();
    flags[slot] = 0;
    demography_residual[slot] = 0;
    owner_employed[slot] = 0;
    employee_employed[slot] = 0;
    worst_need_id[slot] = std::numeric_limits<uint16_t>::max();
    ++active_count;
    return slot;
}

bool NativeEconomyRuntime::PopulationStore::valid_handle(uint64_t handle, int32_t &slot_out) const {
    const uint32_t slot = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (slot >= active.size() || active[slot] == 0 || generation[slot] != gen) return false;
    slot_out = static_cast<int32_t>(slot);
    return true;
}

uint64_t NativeEconomyRuntime::PopulationStore::handle_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(generation.size()) || active[slot] == 0) return 0;
    return (static_cast<uint64_t>(generation[slot]) << 32) | static_cast<uint32_t>(slot);
}

void NativeEconomyRuntime::PopulationStore::release_slot(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(active.size()) || active[slot] == 0) return;
    active[slot] = 0;
    population[slot] = 0;
    funds[slot] = 0;
    epoch_income[slot] = 0;
    epoch_expense[slot] = 0;
    epoch_in_kind_income[slot] = 0;
    income_ema[slot] = 0;
    demography_residual[slot] = 0;
    owner_employed[slot] = 0;
    employee_employed[slot] = 0;
    generation[slot] = generation[slot] == std::numeric_limits<uint32_t>::max()
                           ? 1u
                           : generation[slot] + 1u;
    --active_count;
}

void NativeEconomyRuntime::PopulationStore::reclaim_empty_pages(int32_t cell) {
    if (cell < 0 || cell >= static_cast<int32_t>(cell_first_page.size())) return;
    int32_t previous = -1;
    int32_t page = cell_first_page[cell];
    while (page >= 0) {
        const int32_t next = page_next[page];
        const int32_t base = page * PAGE_SIZE;
        bool any = false;
        for (int32_t lane = 0; lane < PAGE_SIZE; ++lane) any |= active[base + lane] != 0;
        if (!any) {
            if (previous < 0) cell_first_page[cell] = next;
            else page_next[previous] = next;
            page_next[page] = -1;
            page_cell[page] = -1;
            free_pages.push_back(page);
        } else {
            previous = page;
        }
        page = next;
    }
}

void NativeEconomyRuntime::MarketStore::clear() {
    market_count = 0;
    good_count = 0;
    stock.clear();
    price.clear();
    demand_ema.clear();
    last_shortage_q16.clear();
    cell_to_market.clear();
}

bool NativeEconomyRuntime::is_merchant_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0) return false;
    const uint32_t signature = _population.signature_id[slot];
    return signature < _signatures.size() &&
           _signatures[signature].profession_id == _merchant_profession_id;
}

void NativeEconomyRuntime::touch_accounting_slot(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0) return;
    constexpr uint16_t ACCOUNTING_EPOCH_BIT = 0x8000u;
    const uint16_t expected = (_epoch_id & 1LL) != 0 ? ACCOUNTING_EPOCH_BIT : 0u;
    if ((_population.flags[slot] & ACCOUNTING_EPOCH_BIT) == expected) return;
    _population.epoch_income[slot] = 0;
    _population.epoch_expense[slot] = 0;
    _population.epoch_in_kind_income[slot] = 0;
    _population.flags[slot] = static_cast<uint16_t>(
        (_population.flags[slot] & ~ACCOUNTING_EPOCH_BIT) | expected);
}

bool NativeEconomyRuntime::ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                                      std::string &error) {
    int32_t source = -1;
    int64_t source_population = -1;
    int64_t total_population = 0;
    bool has_merchant = false;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        total_population = saturating_add(total_population, _population.population[slot],
                                          _saturation_count);
        if (is_merchant_slot(slot)) has_merchant = true;
        if (!is_merchant_slot(slot) &&
            (_population.population[slot] > source_population ||
             (_population.population[slot] == source_population && slot < source))) {
            source = slot;
            source_population = _population.population[slot];
        }
    });
    if (total_population <= 0 || has_merchant) return true;
    if (source < 0 || source_population <= 0) {
        error = "merchant_invariant_source_missing";
        return false;
    }
    const int32_t source_signature_id = static_cast<int32_t>(_population.signature_id[source]);
    const Signature &source_signature = _signatures[source_signature_id];
    int32_t merchant_signature = -1;
    for (int32_t i = 0; i < static_cast<int32_t>(_signatures.size()); ++i) {
        if (_signatures[i].profession_id == _merchant_profession_id &&
            _signatures[i].ethnicity_id == source_signature.ethnicity_id) {
            merchant_signature = i;
            break;
        }
    }
    if (merchant_signature < 0) {
        error = "merchant_signature_missing_for_ethnicity";
        return false;
    }
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    const int64_t source_funds_before = _population.funds[source];
    int32_t destination = source;
    int64_t funds_share = 0;
    if (source_population == 1) {
        _population.signature_id[source] = static_cast<uint32_t>(merchant_signature);
    } else {
        funds_share = mul_div_sat(_population.funds[source], 1,
                                  source_population, _saturation_count);
        destination = _population.allocate_slot(
            cell, static_cast<uint32_t>(merchant_signature));
        if (destination < 0) {
            error = "merchant_slot_allocation_failed";
            return false;
        }
        touch_accounting_slot(destination);
        _population.population[source] -= 1;
        _population.funds[source] -= funds_share;
        _population.population[destination] = saturating_add(
            _population.population[destination], 1, _saturation_count);
        _population.funds[destination] = saturating_add(
            _population.funds[destination], funds_share, _saturation_count);
    }
    if (_epoch_active) {
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cell)) {
            if (source_population == 1) {
                legs.push_back({FIELD_COHORT_SIGNATURE, SUBJECT_COHORT, source_handle, -1,
                                source_signature_id, merchant_signature});
            } else {
                const int64_t destination_handle = static_cast<int64_t>(
                    _population.handle_for_slot(destination));
                legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                                source_population, source_population - 1});
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                                source_funds_before, _population.funds[source]});
                legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                                destination_handle, -1, 0,
                                _population.population[destination]});
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                                destination_handle, -1, 0,
                                _population.funds[destination]});
            }
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), cell,
                     SUBJECT_COHORT, source_handle, merchant_signature, 1,
                     1, funds_share, source_population, merchant_signature,
                     legs.empty() ? nullptr : &legs);
    }
    ++repair_count;
    return true;
}

bool NativeEconomyRuntime::rebuild_merchant_ranges(std::string &error) {
    _merchant_primary_slot.assign(_cell_count, -1);
    _merchant_offsets.assign(_cell_count + 1, 0);
    _merchant_slots.clear();
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) _merchant_slots.push_back(slot);
        });
        _merchant_offsets[cell + 1] = static_cast<int32_t>(_merchant_slots.size());
        if (_merchant_offsets[cell + 1] > _merchant_offsets[cell]) {
            _merchant_primary_slot[cell] = _merchant_slots[_merchant_offsets[cell]];
        } else {
            int64_t population = 0;
            _population.for_each_in_cell(cell, [&](int32_t slot) {
                population = saturating_add(population, _population.population[slot],
                                            _saturation_count);
            });
            if (population > 0) {
                error = "merchant_invariant_broken";
                return false;
            }
        }
    }
    return true;
}

bool NativeEconomyRuntime::capture_environment(int64_t day_index, const float *temperature,
                                               const float *moisture, const float *snow_cover,
                                               const float *weather_intensity, int32_t count,
                                               std::string &error) {
    if (!_configured || count != _cell_count || temperature == nullptr || moisture == nullptr ||
        snow_cover == nullptr || weather_intensity == nullptr) {
        error = "economy_environment_snapshot_invalid";
        return false;
    }
    auto quantize = [](float value) -> int32_t {
        if (!std::isfinite(value)) return 0;
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(std::llround(std::clamp(value, 0.0f, 1.0f) * Q16_ONE)),
            0, Q16_ONE));
    };
    _environment_temperature_q16.resize(count);
    _environment_moisture_q16.resize(count);
    _environment_snow_q16.resize(count);
    _environment_weather_q16.resize(count);
    uint64_t hash = 1469598103934665603ULL;
    auto mix = [&](uint32_t value) {
        for (int32_t b = 0; b < 4; ++b) {
            hash ^= static_cast<uint8_t>((value >> (b * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
    };
    for (int32_t i = 0; i < count; ++i) {
        _environment_temperature_q16[i] = quantize(temperature[i]);
        _environment_moisture_q16[i] = quantize(moisture[i]);
        _environment_snow_q16[i] = quantize(snow_cover[i]);
        _environment_weather_q16[i] = quantize(weather_intensity[i]);
        mix(static_cast<uint32_t>(_environment_temperature_q16[i]));
        mix(static_cast<uint32_t>(_environment_moisture_q16[i]));
        mix(static_cast<uint32_t>(_environment_snow_q16[i]));
        mix(static_cast<uint32_t>(_environment_weather_q16[i]));
    }
    _environment_day = day_index;
    _environment_hash = static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
    return true;
}

bool NativeEconomyRuntime::capture_building_context(
        int64_t day_index, const float *elevation, const uint8_t *terrain,
        const uint8_t *landform, const uint8_t *vegetation, const uint8_t *is_water,
        const uint8_t *has_river, const int32_t *neighbor_indices,
        const std::vector<const float *> &resources,
        const std::vector<const float *> &resource_changes,
        int32_t count, std::string &error) {
    if (!_configured || count != _cell_count ||
        resources.size() != _resource_ids.size()) {
        error = "building_context_snapshot_invalid";
        return false;
    }
    auto quantize_q16 = [](float value) -> int32_t {
        if (!std::isfinite(value)) return 0;
        const double scaled = static_cast<double>(value) * static_cast<double>(Q16_ONE);
        return static_cast<int32_t>(std::clamp<double>(
            std::llround(scaled), std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max()));
    };
    _building_elevation_q16.resize(count);
    _building_terrain.resize(count);
    _building_landform.resize(count);
    _building_vegetation.resize(count);
    _building_is_water.resize(count);
    _building_has_river.resize(count);
    _building_neighbors.assign(static_cast<size_t>(count) * 6, -1);
    for (int32_t cell = 0; cell < count; ++cell) {
        _building_elevation_q16[cell] = elevation != nullptr ? quantize_q16(elevation[cell]) : 0;
        _building_terrain[cell] = terrain != nullptr ? terrain[cell] : 0;
        _building_landform[cell] = landform != nullptr ? landform[cell] : 0;
        _building_vegetation[cell] = vegetation != nullptr ? vegetation[cell] : 0;
        _building_is_water[cell] = is_water != nullptr ? is_water[cell] : 0;
        _building_has_river[cell] = has_river != nullptr ? has_river[cell] : 0;
        if (neighbor_indices != nullptr) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = neighbor_indices[cell * 6 + direction];
                _building_neighbors[static_cast<size_t>(cell) * 6 + direction] =
                    neighbor >= 0 && neighbor < count && neighbor != cell ? neighbor : -1;
            }
        }
    }
    if (resource_changes.size() != resources.size()) {
        error = "building_resource_change_shape_invalid";
        return false;
    }
    _resource_snapshot.assign(static_cast<size_t>(count) * resources.size(), 0);
    for (size_t r = 0; r < resources.size(); ++r) {
        const float *src = resources[r];
        const float *change = resource_changes[r];
        if (src == nullptr) continue;
        for (int32_t cell = 0; cell < count; ++cell) {
            const double reserve = std::isfinite(src[cell])
                ? static_cast<double>(src[cell]) : 0.0;
            const double pending = change != nullptr && std::isfinite(change[cell])
                ? static_cast<double>(change[cell]) : 0.0;
            const double value = std::max(0.0, reserve + std::min(0.0, pending));
            _resource_snapshot[r * static_cast<size_t>(count) + cell] =
                static_cast<int64_t>(std::min<double>(
                    value * static_cast<double>(GOODS_SCALE),
                    static_cast<double>(std::numeric_limits<int64_t>::max())));
        }
    }
    _building_context_day = day_index;
    return true;
}

bool NativeEconomyRuntime::capture_trade_topology(
        const int32_t *neighbor_indices, const uint8_t *terrain,
        const uint8_t *trade_passable_lut, const int32_t *trade_move_cost_lut,
        int32_t count, uint64_t generation, std::string &error) {
    if (!_configured || count != _cell_count || neighbor_indices == nullptr ||
        terrain == nullptr || trade_passable_lut == nullptr ||
        trade_move_cost_lut == nullptr) {
        error = "trade_topology_snapshot_invalid";
        return false;
    }
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u32 = [&](uint32_t value) {
        for (int32_t b = 0; b < 4; ++b) {
            hash ^= static_cast<uint8_t>((value >> (b * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
    };
    std::vector<int32_t> neighbors(static_cast<size_t>(count) * 6, -1);
    std::vector<uint8_t> passable(static_cast<size_t>(count), 0);
    std::vector<int32_t> enter_cost(static_cast<size_t>(count), 0);
    for (int32_t cell = 0; cell < count; ++cell) {
        const uint8_t terrain_id = terrain[cell];
        passable[cell] = trade_passable_lut[terrain_id] != 0 ? 1 : 0;
        enter_cost[cell] = passable[cell] != 0 ? trade_move_cost_lut[terrain_id] : 0;
        if (passable[cell] != 0 && enter_cost[cell] <= 0) {
            error = "trade_passable_cell_has_nonpositive_cost";
            return false;
        }
        mix_u32(passable[cell]);
        mix_u32(static_cast<uint32_t>(enter_cost[cell]));
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = neighbor_indices[cell * 6 + direction];
            const int32_t valid = neighbor >= 0 && neighbor < count && neighbor != cell
                ? neighbor : -1;
            neighbors[static_cast<size_t>(cell) * 6 + direction] = valid;
            mix_u32(static_cast<uint32_t>(valid));
        }
    }
    const uint64_t normalized_hash = (hash & 0x7fffffffffffffffULL) | 1ULL;
    // The normalized content hash is authoritative. Callers may refresh their
    // own generation for unrelated map state; identical trade topology must
    // not throw away an incremental plan. A real content change always advances
    // our internal generation even when the caller reuses a stale token.
    if (_trade_topology.ready && _trade_topology.topology_hash == normalized_hash) return true;
    if (_trade_topology.ready) {
        ++_trade_topology_content_change_count;
        ++_trade_plan_reset_count;
        _trade_last_plan_reset_reason = "normalized_topology_changed";
    } else {
        _trade_last_plan_reset_reason = "initial_topology_capture";
    }
    const uint64_t resolved_generation = std::max<uint64_t>(
        _trade_topology.topology_generation + 1, generation != 0 ? generation : 1);
    _trade_topology.neighbors.swap(neighbors);
    _trade_topology.passable.swap(passable);
    _trade_topology.enter_cost.swap(enter_cost);
    _trade_topology.component.assign(static_cast<size_t>(count), -1);
    _trade_topology.topology_hash = normalized_hash;
    _trade_topology.topology_generation = resolved_generation;
    _trade_topology.component_country_hash = 0;
    _trade_topology.ready = true;
    _trade_plan.clear_transient();
    return true;
}

bool NativeEconomyRuntime::drain_building_resource_deltas(std::vector<int64_t> &out) {
    if (!_resource_deltas_ready) return false;
    _last_published_resource_deltas = _resource_deltas;
    out = _resource_deltas;
    _resource_deltas_ready = false;
    std::fill(_resource_deltas.begin(), _resource_deltas.end(), int64_t{0});
    return true;
}

int32_t NativeEconomyRuntime::sample_environment_curve(int32_t curve_id, int32_t cell) const {
    if (curve_id < 0) return Q16_ONE;
    if (curve_id >= static_cast<int32_t>(_environment_curves.size()) || cell < 0 ||
        cell >= _cell_count) return 0;
    return sample_environment_curve(curve_id, environment_sample_for_cell(cell));
}

int32_t NativeEconomyRuntime::sample_environment_curve(
        int32_t curve_id, const EnvironmentSample &sample) const {
    if (curve_id < 0) return Q16_ONE;
    if (curve_id >= static_cast<int32_t>(_environment_curves.size())) return 0;
    const EnvironmentCurve &curve = _environment_curves[curve_id];
    int32_t signal = 0;
    switch (curve.signal_id) {
        case 0: signal = sample.temperature_q16; break;
        case 1: signal = sample.moisture_q16; break;
        case 2: signal = sample.snow_q16; break;
        case 3: signal = sample.weather_q16; break;
        default: return 0;
    }
    const int64_t scaled = static_cast<int64_t>(std::clamp(signal, 0, static_cast<int32_t>(Q16_ONE))) *
                           (ENV_CURVE_SAMPLES - 1);
    const int32_t lo = std::min(ENV_CURVE_SAMPLES - 1,
                                static_cast<int32_t>(scaled / Q16_ONE));
    const int32_t hi = std::min(ENV_CURVE_SAMPLES - 1, lo + 1);
    const int64_t frac = scaled - static_cast<int64_t>(lo) * Q16_ONE;
    return static_cast<int32_t>(curve.values_q16[lo] +
        ((static_cast<int64_t>(curve.values_q16[hi] - curve.values_q16[lo]) * frac) >> 16));
}

NativeEconomyRuntime::EnvironmentSample NativeEconomyRuntime::environment_sample_for_cell(
        int32_t cell) const {
    EnvironmentSample sample;
    if (cell < 0 || cell >= _cell_count ||
        _environment_temperature_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_moisture_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_snow_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_weather_q16.size() != static_cast<size_t>(_cell_count)) {
        return sample;
    }
    sample.temperature_q16 = _environment_temperature_q16[cell];
    sample.moisture_q16 = _environment_moisture_q16[cell];
    sample.snow_q16 = _environment_snow_q16[cell];
    sample.weather_q16 = _environment_weather_q16[cell];
    sample.ready = _environment_day >= 0;
    return sample;
}

NativeEconomyRuntime::EnvironmentSample NativeEconomyRuntime::environment_sample_from_float(
        float temperature, float moisture, float snow_cover, float weather_intensity,
        bool ready) {
    auto quantize = [](float value, int32_t fallback) -> int32_t {
        if (!std::isfinite(value)) return fallback;
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(std::llround(std::clamp(value, 0.0f, 1.0f) * Q16_ONE)),
            0, Q16_ONE));
    };
    EnvironmentSample sample;
    sample.temperature_q16 = quantize(temperature, Q16_ONE / 2);
    sample.moisture_q16 = quantize(moisture, Q16_ONE / 2);
    sample.snow_q16 = quantize(snow_cover, 0);
    sample.weather_q16 = quantize(weather_intensity, 0);
    sample.ready = ready;
    return sample;
}

int64_t NativeEconomyRuntime::variant_unit_price(int32_t market, int32_t variant_id,
                                                  int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || variant_id < 0 ||
        variant_id >= static_cast<int32_t>(_variants.size())) return 1;
    const VariantChoice &variant = _variants[variant_id];
    int64_t unit_price = 0;
    for (int32_t c = 0; c < variant.component_count; ++c) {
        const NeedComponent &component = _components[variant.component_begin + c];
        unit_price = saturating_add(
            unit_price,
            mul_div_sat(component.qty_per_need,
                        _market.price[_market.index(market, component.good_id)],
                        GOODS_SCALE, sat), sat);
    }
    return std::max<int64_t>(1, unit_price);
}

void NativeEconomyRuntime::build_demand_basis(
        int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) const {
    variant_scores.assign(_variants.size(), 0);
    variant_prices.assign(_variants.size(), 1);
    need_score_sums.assign(_needs.size(), 0);
    need_composites.assign(_needs.size(), 0);
    need_environment.assign(_needs.size(), Q16_ONE);
    for (int32_t need_index = 0; need_index < static_cast<int32_t>(_needs.size()); ++need_index) {
        const Need &need = _needs[need_index];
        int64_t score_sum = 0;
        int64_t preference_sum = 0;
        need_environment[need_index] =
            sample_environment_curve(need.quantity_env_curve, sample);
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            bool technology_available = true;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                technology_available &= good_available(market, component.good_id, true);
            }
            if (!technology_available) continue;
            const int64_t unit_price = variant_unit_price(market, variant_id, sat);
            const int64_t price_ratio = mul_div_sat(
                variant.reference_unit_price, Q16_ONE, unit_price, sat);
            int64_t score = mul_div_sat(
                variant.preference_q16,
                pow_q16(std::max<int64_t>(1, price_ratio),
                        variant.price_elasticity_q16, sat), Q16_ONE, sat);
            score = mul_div_sat(score,
                sample_environment_curve(variant.preference_env_curve, sample), Q16_ONE, sat);
            score = std::max<int64_t>(0, score);
            variant_prices[variant_id] = unit_price;
            variant_scores[variant_id] = score;
            score_sum = saturating_add(score_sum, score, sat);
            preference_sum = saturating_add(
                preference_sum, std::max<int32_t>(1, variant.preference_q16), sat);
        }
        need_score_sums[need_index] = score_sum;
        const int64_t raw_composite = score_sum > 0
            ? mul_div_sat(score_sum, Q16_ONE, std::max<int64_t>(1, preference_sum), sat)
            : 0;
        need_composites[need_index] = raw_composite > 0
            ? std::clamp<int64_t>(pow_q16(
                std::max<int64_t>(1, raw_composite),
                need.price_quantity_elasticity_q16, sat),
                need.price_quantity_floor_q16, Q16_ONE * 2)
            : 0;
    }
}

int64_t NativeEconomyRuntime::desired_need_units(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0 || need_index < 0 ||
        need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const uint32_t signature_id = _population.signature_id[slot];
    if (signature_id >= _signatures.size()) return 0;
    const Signature &signature = _signatures[signature_id];
    const Need &need = _needs[need_index];
    const int64_t population = std::max<int64_t>(0, _population.population[slot]);
    if (population <= 0) return 0;
    const int64_t wealth_pc = std::max<int64_t>(0, _population.funds[slot]) / population;
    const int64_t wealth_ratio_q16 = mul_div_sat(
        wealth_pc, Q16_ONE, _wealth_reference_per_capita, sat);
    int64_t wealth_factor = pow_q16(std::max<int64_t>(1, wealth_ratio_q16),
                                    need.wealth_elasticity_q16, sat);
    wealth_factor = std::clamp<int64_t>(wealth_factor,
                                        need.wealth_min_q16, need.wealth_max_q16);
    int64_t desired = saturating_mul(population, need.base_qty_per_person, sat);
    desired = saturating_mul(desired, std::max(1, dt_days), sat);
    desired = mul_div_sat(desired, wealth_factor, Q16_ONE, sat);
    desired = mul_div_sat(desired, environment_factor_q16, Q16_ONE, sat);
    const int64_t ethnicity_factor = _ethnicity_need_factor_q16[
        static_cast<size_t>(signature.ethnicity_id) * _need_ids.size() + need.stable_id];
    desired = mul_div_sat(desired, ethnicity_factor, Q16_ONE, sat);
    desired = mul_div_sat(desired, composite_factor_q16, Q16_ONE, sat);
    return std::max<int64_t>(0, desired);
}

int64_t NativeEconomyRuntime::survival_required_units(
        int32_t slot, int32_t stable_need_id, int32_t dt_days,
        const EnvironmentSample &sample, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0 || stable_need_id < 0 ||
        stable_need_id >= static_cast<int32_t>(_survival_required_need_indices.size())) return 0;
    const int32_t need_index = _survival_required_need_indices[stable_need_id];
    if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const uint32_t signature_id = _population.signature_id[slot];
    if (signature_id >= _signatures.size()) return 0;
    const Signature &signature = _signatures[signature_id];
    const Need &need = _needs[need_index];
    const int64_t population = std::max<int64_t>(0, _population.population[slot]);
    if (population <= 0) return 0;
    int64_t required = saturating_mul(population, need.base_qty_per_person, sat);
    required = saturating_mul(required, std::max(1, dt_days), sat);
    required = mul_div_sat(required,
        sample_environment_curve(need.quantity_env_curve, sample), Q16_ONE, sat);
    const int64_t ethnicity_factor = _ethnicity_need_factor_q16[
        static_cast<size_t>(signature.ethnicity_id) * _need_ids.size() + stable_need_id];
    required = mul_div_sat(required, ethnicity_factor, Q16_ONE, sat);
    return std::max<int64_t>(0, required);
}

// ─── Fixed point / formula registry ────────────────────────────────────

int64_t NativeEconomyRuntime::saturating_add(int64_t a, int64_t b, int64_t &sat) {
    if (b > 0 && a > std::numeric_limits<int64_t>::max() - b) {
        ++sat;
        return std::numeric_limits<int64_t>::max();
    }
    if (b < 0 && a < std::numeric_limits<int64_t>::min() - b) {
        ++sat;
        return std::numeric_limits<int64_t>::min();
    }
    return a + b;
}

int64_t NativeEconomyRuntime::saturating_sub(int64_t a, int64_t b, int64_t &sat) {
    if (b == std::numeric_limits<int64_t>::min()) {
        if (a >= 0) {
            ++sat;
            return std::numeric_limits<int64_t>::max();
        }
        return a - b;
    }
    return saturating_add(a, -b, sat);
}

int64_t NativeEconomyRuntime::saturating_mul(int64_t a, int64_t b, int64_t &sat) {
    if (a == 0 || b == 0) return 0;
    const bool negative = (a < 0) ^ (b < 0);
    const uint64_t ua = magnitude_i64(a);
    const uint64_t ub = magnitude_i64(b);
    if (ua > std::numeric_limits<uint64_t>::max() / ub) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    return clamp_i64_from_unsigned(ua * ub, negative, sat);
}

int64_t NativeEconomyRuntime::mul_div_sat(int64_t a, int64_t b, int64_t divisor,
                                          int64_t &sat) {
    if (divisor == 0) {
        ++sat;
        return ((a < 0) ^ (b < 0)) ? std::numeric_limits<int64_t>::min()
                                    : std::numeric_limits<int64_t>::max();
    }
    const bool negative = (a < 0) ^ (b < 0) ^ (divisor < 0);
    const uint64_t ua = magnitude_i64(a);
    const uint64_t ub = magnitude_i64(b);
    const uint64_t ud = magnitude_i64(divisor);
    if (ua == 0 || ub == 0) return 0;
    // The overwhelming majority of economy operands fit in 64-bit before
    // division. Avoid the much slower platform 128/64 divide in that case;
    // the wide path remains the exact overflow-safe fallback.
    if (ua <= std::numeric_limits<uint64_t>::max() / ub) {
        const uint64_t quotient = (ua * ub) / ud;
        return clamp_i64_from_unsigned(quotient, negative, sat);
    }
#if defined(_MSC_VER) && defined(_M_X64)
    uint64_t hi = 0;
    const uint64_t lo = _umul128(ua, ub, &hi);
    if (hi >= ud) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    uint64_t remainder = 0;
    const uint64_t quotient = _udiv128(hi, lo, ud, &remainder);
    return clamp_i64_from_unsigned(quotient, negative, sat);
#else
    const unsigned __int128 product = static_cast<unsigned __int128>(ua) * ub;
    const unsigned __int128 quotient = product / ud;
    const unsigned __int128 limit = static_cast<unsigned __int128>(
        negative ? static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) + 1ULL
                 : static_cast<uint64_t>(std::numeric_limits<int64_t>::max()));
    if (quotient > limit) {
        ++sat;
        return negative ? std::numeric_limits<int64_t>::min()
                        : std::numeric_limits<int64_t>::max();
    }
    return clamp_i64_from_unsigned(static_cast<uint64_t>(quotient), negative, sat);
#endif
}

int64_t NativeEconomyRuntime::pow_q16(int64_t ratio_q16, int64_t exponent_q16,
                                      int64_t &sat) {
    if (ratio_q16 <= 0) return exponent_q16 <= 0 ? Q16_ONE : 0;
    uint64_t x_q32 = static_cast<uint64_t>(ratio_q16) << 16;
    int32_t integer_log = 0;
    while (x_q32 < (1ULL << 32)) {
        x_q32 <<= 1;
        --integer_log;
        if (integer_log < -31) return 0;
    }
    while (x_q32 >= (2ULL << 32)) {
        x_q32 >>= 1;
        ++integer_log;
        if (integer_log > 31) break;
    }
    uint32_t fractional_log = 0;
    for (int32_t bit = 15; bit >= 0; --bit) {
#if defined(_MSC_VER) && defined(_M_X64)
        uint64_t hi = 0;
        const uint64_t lo = _umul128(x_q32, x_q32, &hi);
        x_q32 = (hi << 32) | (lo >> 32);
#else
        x_q32 = static_cast<uint64_t>((static_cast<unsigned __int128>(x_q32) * x_q32) >> 32);
#endif
        if (x_q32 >= (2ULL << 32)) {
            x_q32 >>= 1;
            fractional_log |= 1U << bit;
        }
    }
    const int64_t log_q16 = static_cast<int64_t>(integer_log) * Q16_ONE + fractional_log;
    const int64_t exponent_value = mul_div_sat(log_q16, exponent_q16, Q16_ONE, sat);
    int64_t integer_exp = exponent_value / Q16_ONE;
    int64_t fractional_exp = exponent_value % Q16_ONE;
    if (fractional_exp < 0) {
        fractional_exp += Q16_ONE;
        --integer_exp;
    }
    static constexpr uint64_t EXP2_FRAC_Q32[16] = {
        6074001000ULL, 5107605667ULL, 4683695048ULL, 4485121744ULL,
        4389014833ULL, 4341736423ULL, 4318288544ULL, 4306612134ULL,
        4300785774ULL, 4297875550ULL, 4296421177ULL, 4295694175ULL,
        4295330720ULL, 4295149004ULL, 4295058149ULL, 4295012722ULL,
    };
    uint64_t out_q32 = 1ULL << 32;
    for (int32_t i = 0; i < 16; ++i) {
        if ((fractional_exp & (1LL << (15 - i))) == 0) continue;
#if defined(_MSC_VER) && defined(_M_X64)
        uint64_t hi = 0;
        const uint64_t lo = _umul128(out_q32, EXP2_FRAC_Q32[i], &hi);
        out_q32 = (hi << 32) | (lo >> 32);
#else
        out_q32 = static_cast<uint64_t>(
            (static_cast<unsigned __int128>(out_q32) * EXP2_FRAC_Q32[i]) >> 32);
#endif
    }
    if (integer_exp >= 0) {
        if (integer_exp >= 31 || out_q32 > (std::numeric_limits<uint64_t>::max() >> integer_exp)) {
            ++sat;
            return std::numeric_limits<int64_t>::max();
        }
        out_q32 <<= integer_exp;
    } else {
        if (integer_exp <= -63) return 0;
        out_q32 >>= -integer_exp;
    }
    return clamp_i64_from_unsigned(out_q32 >> 16, false, sat);
}

void NativeEconomyRuntime::formula_fixed_per_capita(const FormulaBatchInput &in,
                                                     int64_t *out, int64_t &sat) {
    const int64_t base_qty = in.param_count > 0 ? std::max<int64_t>(0, in.params[0]) : 0;
    const int64_t epoch_qty = saturating_mul(base_qty, std::max(1, in.dt_days), sat);
    for (int32_t i = 0; i < in.count; ++i) {
        out[i] = saturating_mul(in.population[i], epoch_qty, sat);
    }
}

void NativeEconomyRuntime::formula_income_price_linear(const FormulaBatchInput &in,
                                                        int64_t *out, int64_t &sat) {
    // params: base qty/person/day(qty scale), reference income/person/day,
    // income weight Q16, reference price, price elasticity Q16,
    // min factor Q16, max factor Q16.
    const int64_t base_qty = in.param_count > 0 ? std::max<int64_t>(0, in.params[0]) : 0;
    const int64_t ref_income = in.param_count > 1 ? std::max<int64_t>(1, in.params[1]) : MONEY_SCALE;
    const int64_t income_weight = in.param_count > 2 ? in.params[2] : Q16_ONE;
    const int64_t ref_price = in.param_count > 3 ? std::max<int64_t>(1, in.params[3]) : MONEY_SCALE;
    const int64_t price_elasticity = in.param_count > 4 ? in.params[4] : Q16_ONE;
    const int64_t min_factor = in.param_count > 5 ? std::max<int64_t>(0, in.params[5]) : 0;
    const int64_t max_factor = in.param_count > 6 ? std::max<int64_t>(min_factor, in.params[6]) : Q16_ONE * 4;
    for (int32_t i = 0; i < in.count; ++i) {
        const int64_t pop = std::max<int64_t>(1, in.population[i]);
        const int64_t income_pc = in.income_ema[i] / pop;
        int64_t income_factor = saturating_add(
            Q16_ONE, mul_div_sat(income_pc - ref_income, income_weight, ref_income, sat), sat);
        int64_t price_factor = saturating_sub(
            Q16_ONE, mul_div_sat(static_cast<int64_t>(in.price) - ref_price,
                                price_elasticity, ref_price, sat), sat);
        income_factor = std::clamp(income_factor, min_factor, max_factor);
        price_factor = std::clamp(price_factor, min_factor, max_factor);
        int64_t qty = saturating_mul(in.population[i], base_qty, sat);
        qty = saturating_mul(qty, std::max(1, in.dt_days), sat);
        qty = mul_div_sat(qty, income_factor, Q16_ONE, sat);
        out[i] = mul_div_sat(qty, price_factor, Q16_ONE, sat);
    }
}

NativeEconomyRuntime::NativeEconomyRuntime() {
    register_builtin_formulas();
    _trade_orders.clear();
}

NativeEconomyRuntime::~NativeEconomyRuntime() = default;

void NativeEconomyRuntime::register_builtin_formulas() {
    _formulas.clear();
    _formula_by_id.clear();
    auto add = [&](const char *id, int32_t version, int32_t min_params,
                   int32_t max_params, FormulaBatchFn fn) {
        const int32_t index = static_cast<int32_t>(_formulas.size());
        _formulas.push_back({id, version, min_params, max_params, fn});
        _formula_by_id[id] = index;
    };
    add("fixed_per_capita", 1, 1, 1, &NativeEconomyRuntime::formula_fixed_per_capita);
    add("income_price_linear", 1, 1, 7, &NativeEconomyRuntime::formula_income_price_linear);
}

bool NativeEconomyRuntime::configure_profile(const Dictionary &profile, std::string &error) {
    _cells_per_slice = std::clamp(dict_num<int32_t>(profile, "cells_per_slice", 256), 1, 65536);
    _auto_slice_by_scale = dict_num<bool>(profile, "auto_slice_by_scale", true);
    const int32_t configured_building_cells = dict_num<int32_t>(
        profile, "building_cells_per_slice", 0);
    _auto_building_slice_by_scale = configured_building_cells <= 0;
    _building_cells_per_slice = _auto_building_slice_by_scale
        ? 256
        : std::clamp(configured_building_cells, 1, 65536);
    _building_groups_per_slice = std::clamp(dict_num<int32_t>(
        profile, "building_groups_per_slice", 512), 1, 65536);
    _commands_per_slice = std::clamp(dict_num<int32_t>(profile, "commands_per_slice", 16384), 1, 1 << 20);
    // Five-day cadence is fixed. World scale changes the rolling workset, not
    // the economic period or feedback delay.
    _configured_epoch_days = ROLLING_PHASE_COUNT;
    _min_epoch_days = ROLLING_PHASE_COUNT;
    _max_epoch_days = ROLLING_PHASE_COUNT;
    _configured_target_cohorts_per_slice = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "market_target_cohorts_per_slice", 0),
        0, 1000000);
    _target_cohorts_per_slice = _configured_target_cohorts_per_slice > 0
        ? _configured_target_cohorts_per_slice : 30000;
    _max_rules_per_plan = std::clamp(dict_num<int32_t>(profile, "max_rules_per_plan", MAX_RULES_PER_PLAN), 1, MAX_RULES_PER_PLAN);
    _worker_enabled = dict_num<bool>(profile, "worker_enabled", true);
    _worker_market_threshold = std::clamp(
        dict_num<int32_t>(profile, "worker_market_threshold", 64), 1, 100000);
    _worker_tasks_hint = std::clamp(dict_num<int32_t>(profile, "worker_tasks_hint", 0), 0, 16);
    _wealth_reference_per_capita = std::max<int64_t>(1, dict_num<int64_t>(
        profile, "wealth_reference_per_capita", MONEY_SCALE * 10));
    _living_cost_base_plan_stable_id =
        dict_string(profile, "living_cost_base_plan_id", "survival_household");
    _starvation_satisfaction_threshold_q16 = std::clamp(
        dict_num<int32_t>(profile, "starvation_satisfaction_threshold_q16",
            dict_num<int32_t>(profile, "survival_work_threshold_q16", Q16_ONE / 2)),
        1, static_cast<int32_t>(Q16_ONE));
    _survival_production_target_q16 = std::clamp(
        dict_num<int32_t>(profile, "survival_production_target_q16", Q16_ONE),
        _starvation_satisfaction_threshold_q16, static_cast<int32_t>(Q16_ONE));
    _starvation_death_rate_q32 = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "starvation_death_rate_q32", Q32_ONE / 200),
        0, Q32_ONE);
    _wage_ema_alpha_q16 = std::clamp(
        dict_num<int32_t>(profile, "wage_ema_alpha_q16", 8192), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_max_rise_q16_per_day = std::clamp(
        dict_num<int32_t>(profile, "wage_max_rise_q16_per_day", 1311), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_max_fall_q16_per_day = std::clamp(
        dict_num<int32_t>(profile, "wage_max_fall_q16_per_day", 1311), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_income_cap_ratio_q16 = std::max(0,
        dict_num<int32_t>(profile, "wage_income_cap_ratio_q16", 78643));
    _employee_profit_share_q16 = std::clamp(
        dict_num<int32_t>(profile, "employee_profit_share_q16", 16384), 0,
        static_cast<int32_t>(Q16_ONE));
    _building_severe_loss_threshold_q16 = std::clamp(
        dict_num<int32_t>(profile, "building_severe_loss_threshold_q16", -16384),
        -static_cast<int32_t>(Q16_ONE), 0);
    _building_severe_loss_cycles = std::clamp(
        dict_num<int32_t>(profile, "building_severe_loss_cycles", 3), 1, 32);
    _building_restart_margin_q16 = std::clamp(
        dict_num<int32_t>(profile, "building_restart_margin_q16", 6554), 0,
        static_cast<int32_t>(Q16_ONE));
    _building_restart_cycles = std::clamp(
        dict_num<int32_t>(profile, "building_restart_cycles", 2), 1, 32);
    _merchant_procurement_cash_reserve_q16 = std::clamp(
        dict_num<int32_t>(profile, "merchant_procurement_cash_reserve_q16", 8192),
        0, static_cast<int32_t>(Q16_ONE));
    _merchant_market_making_days_q16 = std::clamp(
        dict_num<int32_t>(profile, "merchant_market_making_days_q16", Q16_ONE * 60),
        0, static_cast<int32_t>(Q16_ONE * 120));
    _merchant_profession_stable_id = dict_string(profile, "merchant_profession_id", "merchant");
    _unemployed_profession_stable_id = dict_string(profile, "unemployed_profession_id", "unemployed");
    const std::string runtime_mode = dict_string(profile, "market_runtime_mode", "PROBE");
    _market_runtime_mode = runtime_mode == "OFF" ? 0 : (runtime_mode == "PROBE" ? 1 : 2);
    const std::string trade_mode = dict_string(profile, "trade_runtime_mode", "ACTIVE");
    _trade_runtime_mode = trade_mode == "OFF" ? 0 : (trade_mode == "ACTIVE" ? 2 : 1);
    _trade_capacity_per_merchant_q16 = std::clamp<int64_t>(dict_num<int64_t>(
        profile, "trade_capacity_per_merchant_q16", 64 * Q16_ONE), 1,
        std::numeric_limits<int32_t>::max());
    _trade_speed_cost_per_day = std::clamp(dict_num<int32_t>(
        profile, "trade_speed_cost_per_day", 4), 1, 1000000);
    _trade_min_margin_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_min_margin_q16", 3277), 0, static_cast<int32_t>(Q16_ONE));
    _trade_target_count = std::clamp(dict_num<int32_t>(
        profile, "trade_target_count", 4), 1, 8);
    _trade_signal_pairs_per_slice = std::clamp(dict_num<int32_t>(
        profile, "trade_signal_pairs_per_slice", 4096), 256, 1 << 20);
    _trade_route_searches_per_slice = std::clamp(dict_num<int32_t>(
        profile, "trade_route_searches_per_slice", 32), 1, 256);
    _trade_max_route_expansions = std::clamp(dict_num<int32_t>(
        profile, "trade_max_route_expansions", 8192), 64, 1000000);
    _trade_route_cache_entries = std::clamp(dict_num<int32_t>(
        profile, "trade_route_cache_entries", 16384), 64, 1 << 22);
    _trade_max_signals = std::clamp(dict_num<int32_t>(
        profile, "trade_max_signals", 32768), 64, 1 << 20);
    _trade_max_candidates = std::clamp(dict_num<int32_t>(
        profile, "trade_max_candidates", 8192), 16, 1 << 20);
    _trade_max_orders = std::clamp(dict_num<int32_t>(
        profile, "trade_max_orders", 4096), 16, 1 << 20);
    _trade_flow_ema_alpha_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_flow_ema_alpha_q16", 8192), 0, static_cast<int32_t>(Q16_ONE));
    _trade_max_stock_share_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_max_stock_share_q16", 16384), 1, static_cast<int32_t>(Q16_ONE));
    _trade_export_floor_days = std::clamp(dict_num<int32_t>(
        profile, "trade_export_floor_days", 5), 1, 365);
    _trade_export_inventory_fraction_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_export_inventory_fraction_q16", 32768), 0,
        static_cast<int32_t>(Q16_ONE));
    _trade_import_fill_fraction_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_import_fill_fraction_q16", 32768), 0,
        static_cast<int32_t>(Q16_ONE));
    _trade_response_days = std::clamp(dict_num<int32_t>(
        profile, "trade_response_days", 15), 1, 365);
    _investment_review_days = std::clamp(dict_num<int32_t>(
        profile, "investment_review_days", 10), 1, 3650);
    _investment_min_shortage_q16 = std::clamp(dict_num<int32_t>(
        profile, "investment_min_shortage_q16", 8192), 0,
        static_cast<int32_t>(Q16_ONE));
    _investment_min_utilization_q16 = std::clamp(dict_num<int32_t>(
        profile, "investment_min_utilization_q16", 42598), 0,
        static_cast<int32_t>(Q16_ONE));
    _investment_max_payback_days = std::clamp(dict_num<int32_t>(
        profile, "investment_max_payback_days", 365), 1, 36500);
    _investment_operating_cycles = std::clamp(dict_num<int32_t>(
        profile, "investment_operating_cycles", 2), 1, 12);
    _resource_min_reserve_q16 = std::clamp(dict_num<int32_t>(
        profile, "resource_min_reserve_q16", 22938), 0,
        static_cast<int32_t>(Q16_ONE));
    _resource_safe_harvest_q16 = std::clamp(dict_num<int32_t>(
        profile, "resource_safe_harvest_q16", 32768), 0,
        static_cast<int32_t>(Q16_ONE));
    _resource_min_horizon_days = std::clamp(dict_num<int32_t>(
        profile, "resource_min_horizon_days", 3650), 1, 365000);
    _bullion_monthly_issue_cap_q16 = std::clamp(dict_num<int32_t>(
        profile, "bullion_monthly_issue_cap_q16", 655), 0,
        static_cast<int32_t>(Q16_ONE));
    _producer_support_monthly_cap_q16 = std::clamp(dict_num<int32_t>(
        profile, "producer_support_monthly_cap_q16", 3277), 0,
        static_cast<int32_t>(Q16_ONE));
    const std::string trace_mode = dict_string(profile, "economy_trace_mode", "SELECTIVE");
    _trace_mode = trace_mode == "OFF" ? TRACE_OFF
        : (trace_mode == "SUMMARY" ? TRACE_SUMMARY
        : (trace_mode == "FULL_DEBUG" ? TRACE_FULL_DEBUG : TRACE_SELECTIVE));
    _trace_memory_budget = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "economy_trace_memory_bytes", 32LL * 1024 * 1024),
        1024 * 1024, 1024LL * 1024 * 1024);
    _trace_retention_epochs = std::clamp(
        dict_num<int32_t>(profile, "economy_trace_retention_epochs", 8), 1, 3650);
    _trace_detail_epoch_budget = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "economy_trace_detail_epoch_bytes", 8LL * 1024 * 1024),
        64 * 1024, 256LL * 1024 * 1024);
    _trace_poll_max_events = std::clamp(
        dict_num<int32_t>(profile, "economy_trace_poll_max_events", 4096), 1, 65536);
    const int64_t money_scale = dict_num<int64_t>(profile, "money_scale", MONEY_SCALE);
    const int64_t goods_scale = dict_num<int64_t>(profile, "goods_scale", GOODS_SCALE);
    const int64_t ratio_scale = dict_num<int64_t>(profile, "ratio_scale", Q16_ONE);
    const int64_t rate_scale = dict_num<int64_t>(profile, "rate_scale", Q32_ONE);
    if (money_scale != MONEY_SCALE || goods_scale != GOODS_SCALE ||
        ratio_scale != Q16_ONE || rate_scale != Q32_ONE) {
        error = "numeric_scale_mismatch";
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::cell_has_technology(int32_t cell, int32_t technology_id,
                                               bool frozen) const {
    if (cell < 0 || cell >= _cell_count || technology_id < 0 ||
        technology_id >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_words <= 0) return false;
    if (frozen && _epoch_active) {
        if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count) ||
            _epoch_country_technology_words <= 0) return false;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) return false;
        const size_t index = static_cast<size_t>(country) * _epoch_country_technology_words +
            technology_id / 64;
        return index < _epoch_country_technologies.size() &&
            (_epoch_country_technologies[index] & (uint64_t{1} << (technology_id % 64))) != 0;
    }
    const int32_t country = _country_runtime == nullptr
        ? NativeCountryRuntime::NEUTRAL_SLOT : _country_runtime->country_slot_for_cell(cell);
    return _country_runtime != nullptr && _country_runtime->has_technology(country, technology_id);
}

bool NativeEconomyRuntime::cell_has_requirements(
        int32_t cell, int32_t begin, int32_t end,
        const std::vector<int32_t> &requirements, bool frozen) const {
    if (begin < 0 || end < begin || end > static_cast<int32_t>(requirements.size())) return false;
    for (int32_t i = begin; i < end; ++i) {
        if (!cell_has_technology(cell, requirements[i], frozen)) return false;
    }
    return true;
}

bool NativeEconomyRuntime::good_available(int32_t cell, int32_t good_id, bool frozen) const {
    return good_id >= 0 && good_id + 1 < static_cast<int32_t>(_good_technology_offsets.size()) &&
        cell_has_requirements(cell, _good_technology_offsets[good_id],
            _good_technology_offsets[good_id + 1], _good_required_technologies, frozen);
}

bool NativeEconomyRuntime::profession_available(int32_t cell, int32_t profession_id,
                                                bool frozen) const {
    return profession_id >= 0 &&
        profession_id + 1 < static_cast<int32_t>(_profession_technology_offsets.size()) &&
        cell_has_requirements(cell, _profession_technology_offsets[profession_id],
            _profession_technology_offsets[profession_id + 1],
            _profession_required_technologies, frozen);
}

bool NativeEconomyRuntime::building_available(int32_t cell, int32_t type_id,
                                              bool frozen) const {
    return type_id >= 0 &&
        type_id + 1 < static_cast<int32_t>(_building_technology_offsets.size()) &&
        cell_has_requirements(cell, _building_technology_offsets[type_id],
            _building_technology_offsets[type_id + 1],
            _building_required_technologies, frozen);
}

bool NativeEconomyRuntime::building_constructible(int32_t cell, int32_t type_id,
                                                  bool frozen) const {
    if (!building_available(cell, type_id, frozen) || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_upgrade_family_indices.size()) ||
        type_id >= static_cast<int32_t>(_building_upgrade_tiers.size())) return false;
    const int32_t family = _building_upgrade_family_indices[type_id];
    if (family < 0) return true;
    const int32_t tier = _building_upgrade_tiers[type_id];
    for (int32_t candidate = 0;
         candidate < static_cast<int32_t>(_building_upgrade_family_indices.size());
         ++candidate) {
        if (_building_upgrade_family_indices[candidate] == family &&
            _building_upgrade_tiers[candidate] > tier &&
            building_available(cell, candidate, frozen)) return false;
    }
    return true;
}

bool NativeEconomyRuntime::capture_country_epoch(std::string &error) {
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63) / 64);
    if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
        _country_runtime->good_count() != static_cast<int32_t>(_good_ids.size()) ||
        _country_runtime->technology_count() != static_cast<int32_t>(_technology_ids.size())) {
        error = "country_runtime_required";
        return false;
    }
    NativeCountryRuntime::EconomySnapshot snapshot;
    if (!_country_runtime->copy_economy_snapshot(snapshot) ||
        snapshot.cell_country_slot.size() != static_cast<size_t>(_cell_count) ||
        snapshot.technology_words != _technology_words) {
        error = "country_snapshot_shape_invalid";
        return false;
    }
    _epoch_cell_country = std::move(snapshot.cell_country_slot);
    _epoch_country_technologies = std::move(snapshot.country_technologies);
    _epoch_country_count = snapshot.country_count;
    _epoch_country_technology_words = snapshot.technology_words;
    _epoch_country_generation = snapshot.generation;
    _epoch_country_hash = snapshot.state_hash;
    uint64_t topology_hash = 1469598103934665603ULL;
    for (const int32_t country : _epoch_cell_country) {
        const uint32_t value = static_cast<uint32_t>(country);
        for (int32_t byte = 0; byte < 4; ++byte) {
            topology_hash ^= static_cast<uint8_t>((value >> (byte * 8)) & 0xffU);
            topology_hash *= 1099511628211ULL;
        }
    }
    _epoch_country_topology_hash = (topology_hash & 0x7fffffffffffffffULL) | 1ULL;
    return true;
}

int32_t NativeEconomyRuntime::building_resource_access_cells(
        int32_t cell, int32_t resource_id, int32_t *out_cells, int32_t capacity) const {
    if (out_cells == nullptr || capacity <= 0 || cell < 0 || cell >= _cell_count ||
        resource_id < 0 || resource_id >= static_cast<int32_t>(_resource_ids.size())) {
        return 0;
    }
    out_cells[0] = cell;
    return 1;
}

int64_t NativeEconomyRuntime::available_resource_amount(
        const ResourceAmount &item, int32_t cell) const {
    if (cell < 0 || cell >= _cell_count || item.resource_id < 0 ||
        item.resource_id >= static_cast<int32_t>(_resource_ids.size())) return 0;
    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
    return std::max<int64_t>(0, _resource_remaining[idx]);
}

void NativeEconomyRuntime::consume_resource_amount(
        const ResourceAmount &item, int32_t cell, int64_t quantity) {
    if (cell < 0 || cell >= _cell_count || item.resource_id < 0 ||
        item.resource_id >= static_cast<int32_t>(_resource_ids.size())) return;
    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
    const int64_t taken = std::min<int64_t>(
        std::max<int64_t>(0, quantity), std::max<int64_t>(0, _resource_remaining[idx]));
    if (taken <= 0) return;
    _resource_remaining[idx] -= taken;
    _resource_deltas[idx] = saturating_sub(
        _resource_deltas[idx], taken, _saturation_count);
}

uint64_t NativeEconomyRuntime::trace_hash_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}

bool NativeEconomyRuntime::trace_detail_for_cell(int32_t cell) const {
    if (_trace_mode == TRACE_FULL_DEBUG) return true;
    return _trace_mode == TRACE_SELECTIVE && cell >= 0 &&
           ((cell < static_cast<int32_t>(_trace_cell_mask.size()) &&
             _trace_cell_mask[cell] != 0) || cell == _inspector_trace_cell);
}

void NativeEconomyRuntime::trace_record_cashflow(int32_t cell, uint64_t cohort_handle,
                                                  int32_t source, int64_t income,
                                                  int64_t expense) {
    if (_production_result_sink != nullptr) {
        if (_trace_mode != TRACE_OFF && cell >= 0 &&
            cell == _staging_events.cashflow_cell && cohort_handle != 0 &&
            (income != 0 || expense != 0)) {
            _production_result_sink->cashflow_drafts.push_back(
                {cell, {cohort_handle, source, income, expense}});
        }
        return;
    }
    if (_trace_mode == TRACE_OFF || cell < 0 || cell != _staging_events.cashflow_cell ||
        cohort_handle == 0 || (income == 0 && expense == 0)) return;
    for (CashflowEntry &entry : _staging_events.cashflows) {
        if (entry.cohort_handle != cohort_handle || entry.source != source) continue;
        entry.income = saturating_add(entry.income, income, _saturation_count);
        entry.expense = saturating_add(entry.expense, expense, _saturation_count);
        return;
    }
    _staging_events.cashflows.push_back({cohort_handle, source, income, expense});
}

void NativeEconomyRuntime::trace_reconcile_inspector_cashflows() {
    const int32_t cell = _staging_events.cashflow_cell;
    if (cell < 0 || cell >= _cell_count) return;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const uint64_t handle = _population.handle_for_slot(slot);
        int64_t recorded_income = 0;
        int64_t recorded_expense = 0;
        for (const CashflowEntry &entry : _staging_events.cashflows) {
            if (entry.cohort_handle != handle) continue;
            recorded_income = saturating_add(recorded_income, entry.income, _saturation_count);
            recorded_expense = saturating_add(recorded_expense, entry.expense, _saturation_count);
        }
        const int64_t missing_income = std::max<int64_t>(
            0, _population.epoch_income[slot] - recorded_income);
        const int64_t missing_expense = std::max<int64_t>(
            0, _population.epoch_expense[slot] - recorded_expense);
        trace_record_cashflow(cell, handle, CASHFLOW_OTHER,
                              missing_income, missing_expense);
    });
    std::sort(_staging_events.cashflows.begin(), _staging_events.cashflows.end(),
              [](const CashflowEntry &a, const CashflowEntry &b) {
                  if (a.cohort_handle != b.cohort_handle) {
                      return a.cohort_handle < b.cohort_handle;
                  }
                  return a.source < b.source;
              });
    _staging_events.cashflow_complete = true;
}

void NativeEconomyRuntime::trace_begin_epoch() {
    if (_trace_filter_pending) {
        _trace_cell_mask.swap(_pending_trace_cell_mask);
        _pending_trace_cell_mask.clear();
        _trace_filter_pending = false;
    }
    if (_inspector_trace_pending) {
        _inspector_trace_cell = _pending_inspector_trace_cell;
        _inspector_trace_pending = false;
    }
    _staging_events = {};
    _staging_events.epoch_id = _epoch_id;
    _staging_events.sample_day = _sample_day;
    _staging_events.commit_day = _sample_day < 0 ? _current_day :
        _sample_day + std::max(0, _epoch_days - 1);
    _staging_events.period_days = std::max(1, _epoch_days);
    const bool inspector_trace_due = _inspector_trace_cell >= 0 &&
        _inspector_trace_cell < _cell_count &&
        _inspector_trace_cell % ROLLING_PHASE_COUNT == _rolling_phase;
    _staging_events.cashflow_cell =
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG) &&
                inspector_trace_due
            ? _inspector_trace_cell : -1;
    if (_staging_events.cashflow_cell >= 0) {
        _staging_events.cashflows.reserve(64);
    }
    _staging_events.stream_hash = _event_stream_hash;
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.epoch_id));
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.sample_day));
    if (_trace_mode != TRACE_OFF) {
        const int64_t estimated_events = static_cast<int64_t>(_market.market_count) +
            static_cast<int64_t>(_buildings.size()) * 3 +
            static_cast<int64_t>(_pending_commands.size()) + 64;
        _staging_events.events.reserve(static_cast<size_t>(std::clamp<int64_t>(
            estimated_events, 64, 250000)));
    }
}

void NativeEconomyRuntime::trace_append(int32_t kind, int32_t stage, int32_t cell,
                                        int32_t subject_kind, int64_t subject_id,
                                        int32_t subject_i0, int32_t subject_i1,
                                        int64_t value0, int64_t value1, int64_t value2,
                                        int64_t value3, const std::vector<EventLeg> *legs,
                                        int32_t flags) {
    if (_production_result_sink != nullptr) {
        if (_trace_mode != TRACE_OFF) {
            ProductionTraceDraft draft;
            draft.kind = kind;
            draft.stage = stage;
            draft.cell = cell;
            draft.subject_kind = subject_kind;
            draft.subject_id = subject_id;
            draft.subject_i0 = subject_i0;
            draft.subject_i1 = subject_i1;
            draft.value0 = value0;
            draft.value1 = value1;
            draft.value2 = value2;
            draft.value3 = value3;
            draft.flags = flags;
            if (legs != nullptr) draft.legs = *legs;
            _production_result_sink->trace_drafts.push_back(std::move(draft));
        }
        return;
    }
    if (_trace_mode == TRACE_OFF) return;
    EventRecord event;
    event.stage = stage;
    event.kind = kind;
    event.flags = flags;
    event.cell = cell;
    event.subject_kind = subject_kind;
    event.subject_id = subject_id;
    event.subject_i0 = subject_i0;
    event.subject_i1 = subject_i1;
    event.value0 = value0;
    event.value1 = value1;
    event.value2 = value2;
    event.value3 = value3;
    if (legs != nullptr && !legs->empty()) {
        const int64_t next_bytes = static_cast<int64_t>(
            (_staging_events.legs.size() + legs->size()) * sizeof(EventLeg));
        if (next_bytes <= _trace_detail_epoch_budget) {
            event.flags |= 1; // exact detail present
            event.leg_begin = static_cast<uint32_t>(_staging_events.legs.size());
            event.leg_count = static_cast<uint32_t>(legs->size());
            _staging_events.legs.insert(_staging_events.legs.end(), legs->begin(), legs->end());
        } else {
            event.flags |= 2; // exact detail truncated
            ++_trace_detail_truncated;
        }
    }
    event.event_id = _next_event_id + static_cast<int64_t>(_staging_events.events.size());
    uint64_t hash = _staging_events.stream_hash;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.event_id));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.kind));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.cell));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.subject_id));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value0));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value1));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value2));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value3));
    for (uint32_t i = 0; i < event.leg_count; ++i) {
        const EventLeg &leg = _staging_events.legs[event.leg_begin + i];
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.field));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.subject_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.key_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.before));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.after));
    }
    _staging_events.stream_hash = hash;
    _staging_events.events.push_back(event);
}

void NativeEconomyRuntime::trace_commit_epoch(int64_t population_error,
                                              int64_t money_error,
                                              int64_t goods_error) {
    const auto start = Clock::now();
    trace_reconcile_inspector_cashflows();
    trace_append(EVENT_EPOCH_COMMITTED, static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id, -1, -1,
                 static_cast<int64_t>(_staging_events.events.size()),
                 population_error, money_error, goods_error, nullptr, 0);
    const int64_t event_count = static_cast<int64_t>(_staging_events.events.size());
    const int64_t leg_count = static_cast<int64_t>(_staging_events.legs.size());
    if (_trace_mode != TRACE_OFF) {
        _staging_events.first_event_id = _next_event_id;
        _next_event_id += event_count;
        _staging_events.last_event_id = _next_event_id - 1;
        _event_stream_hash = _staging_events.stream_hash;
        _committed_event_batches.push_back(std::move(_staging_events));
    }
    _audit_history.push_back({_epoch_id, _sample_day, _current_day, event_count, leg_count,
                              population_error, money_error, goods_error,
                              _event_stream_hash});
    while (static_cast<int32_t>(_audit_history.size()) > _trace_retention_epochs) {
        _audit_history.pop_front();
    }
    _staging_events = {};
    trace_evict_to_budget();
    _event_publish_ms += elapsed_ms(start);
}

void NativeEconomyRuntime::trace_abort_epoch() {
    if (!_staging_events.events.empty()) {
        _trace_uncommitted_discarded += static_cast<int64_t>(_staging_events.events.size());
    }
    _staging_events = {};
}

int64_t NativeEconomyRuntime::trace_memory_bytes() const {
    int64_t bytes = _staging_events.bytes();
    for (const EventBatch &batch : _committed_event_batches) bytes += batch.bytes();
    bytes += static_cast<int64_t>(_audit_history.size() * sizeof(AuditFrame));
    bytes += static_cast<int64_t>(_trace_cell_mask.capacity() +
                                  _pending_trace_cell_mask.capacity());
    return bytes;
}

void NativeEconomyRuntime::trace_evict_to_budget() {
    if (_event_archive.active) return;
    while (!_committed_event_batches.empty() &&
           (static_cast<int32_t>(_committed_event_batches.size()) > _trace_retention_epochs ||
            trace_memory_bytes() > _trace_memory_budget)) {
        const EventBatch &batch = _committed_event_batches.front();
        if (batch.last_event_id > 0) {
            if (_first_evicted_event_id == 0) _first_evicted_event_id = batch.first_event_id;
            _event_evicted_count += static_cast<int64_t>(batch.events.size());
        }
        _committed_event_batches.pop_front();
    }
}

Dictionary NativeEconomyRuntime::event_schema() const {
    Dictionary out;
    out["version"] = 4;
    out["format"] = "economy_header_and_delta_legs";
    Dictionary kinds;
    kinds["COMMAND_SETTLED"] = EVENT_COMMAND_SETTLED;
    kinds["MARKET_SETTLED"] = EVENT_MARKET_SETTLED;
    kinds["STRUCTURAL_CHANGE"] = EVENT_STRUCTURAL_CHANGE;
    kinds["CONSTRUCTION_STARTED"] = EVENT_CONSTRUCTION_STARTED;
    kinds["CONSTRUCTION_COMPLETED"] = EVENT_CONSTRUCTION_COMPLETED;
    kinds["BUILDING_DEMOLISHED"] = EVENT_BUILDING_DEMOLISHED;
    kinds["EMPLOYMENT_SETTLED"] = EVENT_EMPLOYMENT_SETTLED;
    kinds["WAGE_SETTLED"] = EVENT_WAGE_SETTLED;
    kinds["BUILDING_PRODUCTION_SETTLED"] = EVENT_BUILDING_PRODUCTION_SETTLED;
    kinds["EPOCH_COMMITTED"] = EVENT_EPOCH_COMMITTED;
    kinds["RESTORE_BOUNDARY"] = EVENT_RESTORE_BOUNDARY;
    kinds["TRADE_DISPATCHED"] = EVENT_TRADE_DISPATCHED;
    kinds["TRADE_ARRIVED"] = EVENT_TRADE_ARRIVED;
    out["kinds"] = kinds;
    Dictionary fields;
    fields["COHORT_POPULATION"] = FIELD_COHORT_POPULATION;
    fields["COHORT_FUNDS"] = FIELD_COHORT_FUNDS;
    fields["COHORT_EPOCH_INCOME"] = FIELD_COHORT_EPOCH_INCOME;
    fields["COHORT_EPOCH_EXPENSE"] = FIELD_COHORT_EPOCH_EXPENSE;
    fields["COHORT_INCOME_EMA"] = FIELD_COHORT_INCOME_EMA;
    fields["COHORT_SATISFACTION"] = FIELD_COHORT_SATISFACTION;
    fields["COHORT_WORST_NEED"] = FIELD_COHORT_WORST_NEED;
    fields["COHORT_OWNER_EMPLOYED"] = FIELD_COHORT_OWNER_EMPLOYED;
    fields["COHORT_EMPLOYEE_EMPLOYED"] = FIELD_COHORT_EMPLOYEE_EMPLOYED;
    fields["COHORT_SIGNATURE"] = FIELD_COHORT_SIGNATURE;
    fields["TREASURY_CASH"] = FIELD_TREASURY_CASH;
    fields["MARKET_STOCK"] = FIELD_MARKET_STOCK;
    fields["MARKET_PRICE"] = FIELD_MARKET_PRICE;
    fields["MARKET_DEMAND_EMA"] = FIELD_MARKET_DEMAND_EMA;
    fields["MARKET_SHORTAGE"] = FIELD_MARKET_SHORTAGE;
    fields["BUILDING_COUNT"] = FIELD_BUILDING_COUNT;
    fields["BUILDING_OWNER_FILLED"] = FIELD_BUILDING_OWNER_FILLED;
    fields["BUILDING_EMPLOYEE_FILLED"] = FIELD_BUILDING_EMPLOYEE_FILLED;
    fields["BUILDING_CAPACITY"] = FIELD_BUILDING_CAPACITY;
    fields["BUILDING_INPUT"] = FIELD_BUILDING_INPUT;
    fields["BUILDING_OUTPUT"] = FIELD_BUILDING_OUTPUT;
    fields["BUILDING_SOLD"] = FIELD_BUILDING_SOLD;
    fields["BUILDING_DISCARDED"] = FIELD_BUILDING_DISCARDED;
    fields["BUILDING_RESOURCE"] = FIELD_BUILDING_RESOURCE;
    fields["BUILDING_RESOURCE_GENERATED"] = FIELD_BUILDING_RESOURCE_GENERATED;
    fields["BUILDING_REVENUE"] = FIELD_BUILDING_REVENUE;
    fields["BUILDING_INPUT_COST"] = FIELD_BUILDING_INPUT_COST;
    fields["BUILDING_WAGES_PAID"] = FIELD_BUILDING_WAGES_PAID;
    fields["BUILDING_WAGES_DUE"] = FIELD_BUILDING_WAGES_DUE;
    fields["BUILDING_EXPECTED_REVENUE"] = FIELD_BUILDING_EXPECTED_REVENUE;
    fields["BUILDING_OPERATING_COST"] = FIELD_BUILDING_OPERATING_COST;
    fields["BUILDING_MARGIN_GAP"] = FIELD_BUILDING_MARGIN_GAP;
    fields["BUILDING_PLANNED_UTILIZATION"] = FIELD_BUILDING_PLANNED_UTILIZATION;
    fields["BUILDING_BASE_WAGES_PAID"] = FIELD_BUILDING_BASE_WAGES_PAID;
    fields["BUILDING_BASE_WAGES_DUE"] = FIELD_BUILDING_BASE_WAGES_DUE;
    fields["BUILDING_BONUS_PAID"] = FIELD_BUILDING_BONUS_PAID;
    fields["BUILDING_BONUS_DUE"] = FIELD_BUILDING_BONUS_DUE;
    fields["BUILDING_WAGE_SUSPENDED"] = FIELD_BUILDING_WAGE_SUSPENDED;
    fields["RESOURCE_DELTA"] = FIELD_RESOURCE_DELTA;
    fields["COHORT_DEMOGRAPHY_RESIDUAL"] = FIELD_COHORT_DEMOGRAPHY_RESIDUAL;
    out["fields"] = fields;
    Dictionary cashflow_sources;
    cashflow_sources["WAGES"] = CASHFLOW_WAGES;
    cashflow_sources["OWNER_OPERATIONS"] = CASHFLOW_OWNER_OPERATIONS;
    cashflow_sources["MERCHANT_HOUSEHOLD_SALES"] = CASHFLOW_MERCHANT_HOUSEHOLD;
    cashflow_sources["MERCHANT_BUSINESS_SALES"] = CASHFLOW_MERCHANT_BUSINESS;
    cashflow_sources["TRANSFER"] = CASHFLOW_TRANSFER;
    cashflow_sources["HOUSEHOLD_CONSUMPTION"] = CASHFLOW_HOUSEHOLD_CONSUMPTION;
    cashflow_sources["PRODUCTION_INPUTS"] = CASHFLOW_PRODUCTION_INPUT;
    cashflow_sources["OWNER_WAGES"] = CASHFLOW_OWNER_WAGES;
    cashflow_sources["CONSTRUCTION"] = CASHFLOW_CONSTRUCTION;
    cashflow_sources["MERCHANT_PROCUREMENT"] = CASHFLOW_MERCHANT_PROCUREMENT;
    cashflow_sources["OTHER"] = CASHFLOW_OTHER;
    cashflow_sources["PRODUCER_SUPPORT_ISSUANCE"] = CASHFLOW_PRODUCER_SUPPORT;
    out["cashflow_sources"] = cashflow_sources;
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    return out;
}

Dictionary NativeEconomyRuntime::set_trace_filter(const Dictionary &filter) {
    Dictionary out;
    std::vector<int32_t> cells = packed_i32(filter, "cells");
    std::vector<uint8_t> mask(static_cast<size_t>(std::max(0, _cell_count)), 0);
    for (int32_t cell : cells) {
        if (cell < 0 || cell >= _cell_count) {
            out["ok"] = false;
            out["reason"] = "economy_trace_cell_out_of_range";
            return out;
        }
        mask[cell] = 1;
    }
    if (_epoch_active) {
        _pending_trace_cell_mask = std::move(mask);
        _trace_filter_pending = true;
    } else {
        _trace_cell_mask = std::move(mask);
        _pending_trace_cell_mask.clear();
        _trace_filter_pending = false;
    }
    out["ok"] = true;
    out["effective_next_epoch"] = _epoch_active;
    out["cell_count"] = static_cast<int64_t>(cells.size());
    return out;
}

Dictionary NativeEconomyRuntime::set_inspector_trace_cell(int32_t cell_idx) {
    Dictionary out;
    if (cell_idx < -1 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = "economy_inspector_trace_cell_out_of_range";
        return out;
    }
    if (_epoch_active) {
        _pending_inspector_trace_cell = cell_idx;
        _inspector_trace_pending = true;
    } else {
        _inspector_trace_cell = cell_idx;
        _pending_inspector_trace_cell = cell_idx;
        _inspector_trace_pending = false;
    }
    out["ok"] = true;
    out["cell_idx"] = cell_idx;
    out["effective_next_epoch"] = _epoch_active;
    return out;
}

Dictionary NativeEconomyRuntime::poll_events(const Dictionary &opts) const {
    const StringName consumer = opts.has("consumer_id")
        ? StringName(opts["consumer_id"]) : StringName("default");
    const std::string consumer_key = to_utf8(String(consumer));
    const auto ack_it = _event_consumer_ack.find(consumer_key);
    const int64_t acked = ack_it == _event_consumer_ack.end() ? 0 : ack_it->second;
    const int64_t after = dict_num<int64_t>(opts, "after_event_id", acked);
    const int32_t max_events = std::clamp(
        dict_num<int32_t>(opts, "max_events", _trace_poll_max_events), 1, 65536);
    const int32_t kind_filter = dict_num<int32_t>(opts, "kind", 0);
    const int32_t cell_filter = dict_num<int32_t>(opts, "cell", -1);
    PackedInt64Array event_id, cause_id, epoch_id, sample_day, commit_day, subject_id;
    PackedInt32Array period_days, stage, kind, flags, cell, subject_kind, subject_i0,
        subject_i1, leg_offset, leg_count;
    PackedInt64Array value0, value1, value2, value3;
    PackedInt32Array leg_field, leg_subject_kind, leg_key_id;
    PackedInt64Array leg_subject_id, leg_before, leg_after;
    int64_t last_id = after;
    for (const EventBatch &batch : _committed_event_batches) {
        if (batch.last_event_id <= after) continue;
        for (const EventRecord &event : batch.events) {
            if (event.event_id <= after || (kind_filter > 0 && event.kind != kind_filter) ||
                (cell_filter >= 0 && event.cell != cell_filter)) continue;
            event_id.append(event.event_id); cause_id.append(event.event_id);
            epoch_id.append(batch.epoch_id); sample_day.append(batch.sample_day);
            commit_day.append(batch.commit_day); period_days.append(batch.period_days);
            stage.append(event.stage); kind.append(event.kind); flags.append(event.flags);
            cell.append(event.cell); subject_kind.append(event.subject_kind);
            subject_id.append(event.subject_id); subject_i0.append(event.subject_i0);
            subject_i1.append(event.subject_i1);
            leg_offset.append(leg_field.size()); leg_count.append(event.leg_count);
            value0.append(event.value0); value1.append(event.value1);
            value2.append(event.value2); value3.append(event.value3);
            for (uint32_t i = 0; i < event.leg_count; ++i) {
                const EventLeg &leg = batch.legs[event.leg_begin + i];
                leg_field.append(leg.field); leg_subject_kind.append(leg.subject_kind);
                leg_subject_id.append(leg.subject_id); leg_key_id.append(leg.key_id);
                leg_before.append(leg.before); leg_after.append(leg.after);
            }
            last_id = event.event_id;
            if (event_id.size() >= max_events) break;
        }
        if (event_id.size() >= max_events) break;
    }
    Dictionary out;
    out["event_id"] = event_id; out["cause_id"] = cause_id; out["epoch_id"] = epoch_id;
    out["sample_day"] = sample_day; out["commit_day"] = commit_day;
    out["period_days"] = period_days; out["stage"] = stage; out["kind"] = kind;
    out["flags"] = flags; out["cell"] = cell; out["subject_kind"] = subject_kind;
    out["subject_id"] = subject_id; out["subject_i0"] = subject_i0;
    out["subject_i1"] = subject_i1; out["leg_offset"] = leg_offset;
    out["leg_count"] = leg_count; out["value0"] = value0; out["value1"] = value1;
    out["value2"] = value2; out["value3"] = value3;
    out["leg_field"] = leg_field; out["leg_subject_kind"] = leg_subject_kind;
    out["leg_subject_id"] = leg_subject_id; out["leg_key_id"] = leg_key_id;
    out["leg_before"] = leg_before; out["leg_after"] = leg_after;
    out["count"] = event_id.size(); out["last_event_id"] = last_id;
    out["consumer_id"] = consumer;
    out["consumer_lag"] = std::max<int64_t>(0, _next_event_id - 1 - last_id);
    out["gap"] = !_committed_event_batches.empty() &&
        after < _committed_event_batches.front().first_event_id - 1;
    out["ok"] = true;
    return out;
}

Dictionary NativeEconomyRuntime::ack_events(const StringName &consumer_id,
                                            int64_t up_to_event_id) {
    const std::string key = to_utf8(String(consumer_id));
    const int64_t previous = _event_consumer_ack.count(key) ? _event_consumer_ack[key] : 0;
    const int64_t next = std::max(previous, up_to_event_id);
    _event_consumer_ack[key] = next;
    Dictionary out;
    out["ok"] = true;
    out["consumer_id"] = consumer_id;
    out["previous_event_id"] = previous;
    out["acked_event_id"] = next;
    return out;
}

Dictionary NativeEconomyRuntime::trace_report() const {
    Dictionary out;
    int64_t events = 0, legs = 0;
    for (const EventBatch &batch : _committed_event_batches) {
        events += static_cast<int64_t>(batch.events.size());
        legs += static_cast<int64_t>(batch.legs.size());
    }
    out["ok"] = true;
    out["mode"] = _trace_mode == TRACE_OFF ? "OFF" :
        (_trace_mode == TRACE_SUMMARY ? "SUMMARY" :
        (_trace_mode == TRACE_FULL_DEBUG ? "FULL_DEBUG" : "SELECTIVE"));
    out["event_count"] = events;
    out["leg_count"] = legs;
    out["batch_count"] = static_cast<int64_t>(_committed_event_batches.size());
    out["audit_frame_count"] = static_cast<int64_t>(_audit_history.size());
    out["oldest_event_id"] = _committed_event_batches.empty() ? 0 :
        _committed_event_batches.front().first_event_id;
    out["newest_event_id"] = _next_event_id - 1;
    out["next_event_id"] = _next_event_id;
    out["stream_hash"] = static_cast<int64_t>(_event_stream_hash);
    out["memory_bytes"] = trace_memory_bytes();
    out["memory_budget_bytes"] = _trace_memory_budget;
    out["evicted_event_count"] = _event_evicted_count;
    out["first_evicted_event_id"] = _first_evicted_event_id;
    out["detail_truncated_count"] = _trace_detail_truncated;
    out["uncommitted_discarded_count"] = _trace_uncommitted_discarded;
    out["filter_pending"] = _trace_filter_pending;
    out["inspector_trace_cell"] = _inspector_trace_cell;
    out["inspector_trace_pending"] = _inspector_trace_pending;
    out["event_summary_ms"] = _event_summary_ms;
    out["event_detail_ms"] = _event_detail_ms;
    out["event_publish_ms"] = _event_publish_ms;
    out["archive_active"] = _event_archive.active;
    return out;
}

Dictionary NativeEconomyRuntime::begin_event_archive(int32_t chunk_bytes) {
    Dictionary out;
    if (!_bootstrapped || _epoch_active || _event_archive.active || _save.active ||
        _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            (_epoch_active ? "archive_requires_committed_boundary" : "archive_already_active");
        return out;
    }
    _event_archive = {};
    _event_archive.active = true;
    _event_archive.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    _event_archive.batch_limit = _committed_event_batches.size();
    out["ok"] = true;
    out["chunk_bytes"] = _event_archive.chunk_bytes;
    out["batch_count"] = static_cast<int64_t>(_committed_event_batches.size());
    return out;
}

PackedByteArray NativeEconomyRuntime::read_event_archive_chunk(int32_t max_bytes) {
    if (!_event_archive.active || _event_archive.end_emitted) return {};
    const int32_t budget = std::clamp(max_bytes > 0 ? max_bytes : _event_archive.chunk_bytes,
                                      64 * 1024, 16 * 1024 * 1024);
    std::vector<uint8_t> payload;
    if (!_event_archive.header_emitted) {
        append_le<int64_t>(payload, _catalog_hash);
        append_le<int64_t>(payload, _building_catalog_hash);
        append_le<int64_t>(payload, _next_event_id);
        append_le<uint64_t>(payload, _event_stream_hash);
        append_le<int32_t>(payload, static_cast<int32_t>(_event_archive.batch_limit));
        _event_archive.header_emitted = true;
        return make_event_archive_chunk(EVENT_ARCHIVE_HEADER, 1, payload);
    }
    uint32_t records = 0;
    while (_event_archive.batch_cursor < _event_archive.batch_limit) {
        const EventBatch &batch = _committed_event_batches[_event_archive.batch_cursor];
        if (_event_archive.event_cursor >= batch.events.size()) {
            ++_event_archive.batch_cursor;
            _event_archive.event_cursor = 0;
            continue;
        }
        const EventRecord &event = batch.events[_event_archive.event_cursor];
        const size_t record_bytes = 116 + static_cast<size_t>(event.leg_count) * 40;
        if (!payload.empty() && payload.size() + record_bytes > static_cast<size_t>(budget - 16)) break;
        append_le<int64_t>(payload, event.event_id);
        append_le<int64_t>(payload, event.event_id);
        append_le<int64_t>(payload, batch.epoch_id);
        append_le<int64_t>(payload, batch.sample_day);
        append_le<int64_t>(payload, batch.commit_day);
        append_le<int32_t>(payload, batch.period_days);
        append_le<int32_t>(payload, event.stage);
        append_le<int32_t>(payload, event.kind);
        append_le<int32_t>(payload, event.flags);
        append_le<int32_t>(payload, event.cell);
        append_le<int32_t>(payload, event.subject_kind);
        append_le<int64_t>(payload, event.subject_id);
        append_le<int32_t>(payload, event.subject_i0);
        append_le<int32_t>(payload, event.subject_i1);
        append_le<uint32_t>(payload, event.leg_count);
        append_le<int64_t>(payload, event.value0);
        append_le<int64_t>(payload, event.value1);
        append_le<int64_t>(payload, event.value2);
        append_le<int64_t>(payload, event.value3);
        for (uint32_t i = 0; i < event.leg_count; ++i) {
            const EventLeg &leg = batch.legs[event.leg_begin + i];
            append_le<int32_t>(payload, leg.field);
            append_le<int32_t>(payload, leg.subject_kind);
            append_le<int64_t>(payload, leg.subject_id);
            append_le<int32_t>(payload, leg.key_id);
            append_le<int64_t>(payload, leg.before);
            append_le<int64_t>(payload, leg.after);
        }
        ++_event_archive.event_cursor;
        ++records;
    }
    if (records > 0) return make_event_archive_chunk(EVENT_ARCHIVE_EVENTS, records, payload);
    _event_archive.end_emitted = true;
    return make_event_archive_chunk(EVENT_ARCHIVE_END, 0, payload);
}

Dictionary NativeEconomyRuntime::end_event_archive() {
    Dictionary out;
    if (!_event_archive.active || !_event_archive.end_emitted) {
        out["ok"] = false;
        out["reason"] = !_event_archive.active ? "event_archive_not_active" :
            "event_archive_not_fully_read";
        return out;
    }
    _event_archive = {};
    trace_evict_to_budget();
    out["ok"] = true;
    return out;
}

bool NativeEconomyRuntime::compile_catalog(const Dictionary &catalog, std::string &error) {
    _profession_ids = packed_strings(catalog, "profession_ids");
    _ethnicity_ids = packed_strings(catalog, "ethnicity_ids");
    _good_ids = packed_strings(catalog, "good_ids");
    _plan_ids = packed_strings(catalog, "plan_ids");
    _technology_ids = packed_strings(catalog, "technology_ids");
    if (_profession_ids.empty() || _ethnicity_ids.empty() || _good_ids.empty() || _plan_ids.empty()) {
        error = "catalog_id_table_empty";
        return false;
    }
    if (_good_ids.size() > 256) {
        error = "good_count_exceeds_256";
        return false;
    }
    auto unique_sorted = [&](const std::vector<std::string> &ids, const char *name) {
        if (!std::is_sorted(ids.begin(), ids.end()) ||
            std::adjacent_find(ids.begin(), ids.end()) != ids.end()) {
            error = std::string(name) + "_ids_not_sorted_unique";
            return false;
        }
        return true;
    };
    if (!unique_sorted(_profession_ids, "profession") ||
        !unique_sorted(_ethnicity_ids, "ethnicity") ||
        !unique_sorted(_good_ids, "good") || !unique_sorted(_plan_ids, "plan") ||
        !unique_sorted(_technology_ids, "technology")) return false;
    if (_technology_ids.size() > 4096) {
        error = "technology_count_exceeds_4096";
        return false;
    }
    auto compile_technology_tags = [&](const std::vector<int32_t> &tag_offsets,
                                       const std::vector<std::string> &tags,
                                       size_t item_count,
                                       std::vector<int32_t> &offsets,
                                       std::vector<int32_t> &requirements,
                                       const char *reason) {
        if (tag_offsets.size() != item_count + 1 || tag_offsets.empty() ||
            tag_offsets.front() != 0 ||
            !std::is_sorted(tag_offsets.begin(), tag_offsets.end()) ||
            tag_offsets.back() != static_cast<int32_t>(tags.size())) {
            error = reason;
            return false;
        }
        offsets.clear(); requirements.clear(); offsets.push_back(0);
        for (size_t item = 0; item < item_count; ++item) {
            for (int32_t k = tag_offsets[item]; k < tag_offsets[item + 1]; ++k) {
                const std::string &tag = tags[k];
                if (tag.rfind("tech.", 0) != 0) continue;
                const auto it = std::lower_bound(_technology_ids.begin(), _technology_ids.end(), tag);
                if (it == _technology_ids.end() || *it != tag) {
                    error = std::string(reason) + ":" + tag;
                    return false;
                }
                requirements.push_back(static_cast<int32_t>(it - _technology_ids.begin()));
            }
            std::sort(requirements.begin() + offsets.back(), requirements.end());
            requirements.erase(std::unique(requirements.begin() + offsets.back(),
                                            requirements.end()), requirements.end());
            offsets.push_back(static_cast<int32_t>(requirements.size()));
        }
        return true;
    };

    const std::vector<int32_t> profession_tag_offsets =
        packed_i32(catalog, "profession_technology_tag_offsets");
    const std::vector<std::string> profession_tags =
        packed_strings(catalog, "profession_technology_tags");
    if (!compile_technology_tags(profession_tag_offsets, profession_tags,
            _profession_ids.size(), _profession_technology_offsets,
            _profession_required_technologies, "profession_technology_catalog_invalid")) return false;

    _good_default_price = packed_i32(catalog, "good_default_price");
    _good_default_stock = packed_i64(catalog, "good_initial_stock");
    _good_min_price = packed_i32(catalog, "good_min_price");
    _good_max_price = packed_i32(catalog, "good_max_price");
    _good_price_adjust_q16 = packed_i32(catalog, "good_price_adjust_q16");
    _good_demand_price_elasticity_q16 = packed_i32(catalog, "good_demand_price_elasticity_q16");
    _good_demand_ema_alpha_q16 = packed_i32(catalog, "good_demand_ema_alpha_q16");
    const std::vector<int32_t> good_inventory_target_ratios_q16 = packed_i32(
        catalog, "good_inventory_target_ratios_q16");
    _good_target_inventory_days_q16 = packed_i32(
        catalog, "good_target_inventory_days_q16");
    _good_inventory_weight_q16 = packed_i32(catalog, "good_inventory_weight_q16");
    _good_shortage_weight_q16 = packed_i32(catalog, "good_shortage_weight_q16");
    _good_excess_demand_weight_q16 = packed_i32(catalog, "good_excess_demand_weight_q16");
    _good_cost_anchor_weight_q16 = packed_i32(catalog, "good_cost_anchor_weight_q16");
    _good_inactive_reversion_weight_q16 = packed_i32(catalog, "good_inactive_reversion_weight_q16");
    _good_business_demand_ema_alpha_q16 = packed_i32(catalog, "good_business_demand_ema_alpha_q16");
    _good_supply_ema_alpha_q16 = packed_i32(catalog, "good_supply_ema_alpha_q16");
    _good_cost_ema_alpha_q16 = packed_i32(catalog, "good_cost_ema_alpha_q16");
    _good_max_price_rise_q16 = packed_i32(catalog, "good_max_price_rise_q16");
    _good_max_price_fall_q16 = packed_i32(catalog, "good_max_price_fall_q16");
    _good_merchant_buy_factor_q16 = packed_i32(catalog, "good_merchant_buy_factor_q16");
	const std::vector<int32_t> good_trade_enabled = packed_i32(catalog, "good_trade_enabled");
	_good_transport_load_per_unit_q16 = packed_i32(
		catalog, "good_transport_load_per_unit_q16");
	_good_category_ids = packed_strings(catalog, "good_category_ids");
	_good_storage_modes = packed_i32(catalog, "good_storage_modes");
	_good_monetary_issue_values = packed_i64(catalog, "good_monetary_issue_values");
	_good_technology_tag_offsets = packed_i32(catalog, "good_technology_tag_offsets");
	_good_technology_tags = packed_strings(catalog, "good_technology_tags");
    const size_t goods = _good_ids.size();
    if (!good_inventory_target_ratios_q16.empty()) {
        if (good_inventory_target_ratios_q16.size() != goods) {
            error = "good_inventory_target_ratio_size_mismatch";
            return false;
        }
        _good_target_inventory_days_q16.resize(goods);
        for (size_t i = 0; i < goods; ++i) {
            if (good_inventory_target_ratios_q16[i] < 0 ||
                good_inventory_target_ratios_q16[i] > Q16_ONE * 4) {
                error = "good_inventory_target_ratio_out_of_range";
                return false;
            }
            _good_target_inventory_days_q16[i] = static_cast<int32_t>(mul_div_sat(
                _merchant_market_making_days_q16,
                good_inventory_target_ratios_q16[i], Q16_ONE,
                _saturation_count));
        }
    }
    if (_good_excess_demand_weight_q16.empty())
        _good_excess_demand_weight_q16.assign(goods, Q16_ONE / 8);
    if (_good_cost_anchor_weight_q16.empty())
        _good_cost_anchor_weight_q16.assign(goods, Q16_ONE / 4);
    if (_good_inactive_reversion_weight_q16.empty())
        _good_inactive_reversion_weight_q16.assign(goods, 512);
    if (_good_business_demand_ema_alpha_q16.empty())
        _good_business_demand_ema_alpha_q16.assign(goods, Q16_ONE / 8);
    if (_good_supply_ema_alpha_q16.empty())
        _good_supply_ema_alpha_q16.assign(goods, Q16_ONE / 8);
    if (_good_cost_ema_alpha_q16.empty())
        _good_cost_ema_alpha_q16.assign(goods, Q16_ONE / 16);
    if (_good_default_price.size() != goods || _good_default_stock.size() != goods ||
        _good_min_price.size() != goods || _good_max_price.size() != goods ||
        _good_price_adjust_q16.size() != goods ||
        _good_demand_price_elasticity_q16.size() != goods ||
        _good_demand_ema_alpha_q16.size() != goods ||
        _good_target_inventory_days_q16.size() != goods ||
        _good_inventory_weight_q16.size() != goods ||
        _good_shortage_weight_q16.size() != goods ||
        _good_excess_demand_weight_q16.size() != goods ||
        _good_cost_anchor_weight_q16.size() != goods ||
        _good_inactive_reversion_weight_q16.size() != goods ||
        _good_business_demand_ema_alpha_q16.size() != goods ||
        _good_supply_ema_alpha_q16.size() != goods ||
        _good_cost_ema_alpha_q16.size() != goods ||
        _good_max_price_rise_q16.size() != goods ||
        _good_max_price_fall_q16.size() != goods ||
		_good_category_ids.size() != goods || _good_storage_modes.size() != goods ||
		_good_monetary_issue_values.size() != goods ||
		_good_technology_tag_offsets.size() != goods + 1 ||
		_good_technology_tag_offsets.empty() || _good_technology_tag_offsets.front() != 0 ||
		!std::is_sorted(_good_technology_tag_offsets.begin(), _good_technology_tag_offsets.end()) ||
		_good_technology_tag_offsets.back() != static_cast<int32_t>(_good_technology_tags.size()) ||
        (!_good_merchant_buy_factor_q16.empty() &&
         _good_merchant_buy_factor_q16.size() != goods)) {
        error = "good_parameter_size_mismatch";
        return false;
    }
    if (_good_merchant_buy_factor_q16.empty()) {
        _good_merchant_buy_factor_q16.assign(goods, 62259); // 0.95 Q16.
    }
    _good_trade_enabled.assign(goods, 1);
    if (!good_trade_enabled.empty()) {
        if (good_trade_enabled.size() != goods) {
            error = "good_trade_enabled_size_mismatch";
            return false;
        }
        for (size_t i = 0; i < goods; ++i)
            _good_trade_enabled[i] = good_trade_enabled[i] != 0 ? 1 : 0;
    }
    if (_good_transport_load_per_unit_q16.empty())
        _good_transport_load_per_unit_q16.assign(goods, Q16_ONE);
    if (_good_transport_load_per_unit_q16.size() != goods) {
        error = "good_transport_load_size_mismatch";
        return false;
    }
    if (!compile_technology_tags(_good_technology_tag_offsets, _good_technology_tags,
            goods, _good_technology_offsets, _good_required_technologies,
            "good_technology_catalog_invalid")) return false;
    for (size_t i = 0; i < goods; ++i) {
        if (_good_default_price[i] < PRICE_NUMERIC_GUARD_MIN || _good_min_price[i] < 0 ||
            _good_max_price[i] < _good_min_price[i] || _good_default_stock[i] < 0 ||
            _good_demand_price_elasticity_q16[i] <= 0 ||
            _good_excess_demand_weight_q16[i] < 0 ||
            _good_cost_anchor_weight_q16[i] < 0 ||
            _good_inactive_reversion_weight_q16[i] < 0 ||
            _good_business_demand_ema_alpha_q16[i] < 0 ||
            _good_business_demand_ema_alpha_q16[i] > Q16_ONE ||
            _good_supply_ema_alpha_q16[i] < 0 ||
            _good_supply_ema_alpha_q16[i] > Q16_ONE ||
            _good_cost_ema_alpha_q16[i] < 0 ||
            _good_cost_ema_alpha_q16[i] > Q16_ONE ||
            _good_merchant_buy_factor_q16[i] < 0 ||
			_good_merchant_buy_factor_q16[i] > Q16_ONE ||
			_good_category_ids[i].empty() || _good_storage_modes[i] < 0 ||
			_good_storage_modes[i] > 1 || _good_monetary_issue_values[i] < 0 ||
			(_good_storage_modes[i] == 1 && _good_ids[i] != "electricity") ||
			(_good_monetary_issue_values[i] > 0 && _good_ids[i] != "gold" &&
			 _good_ids[i] != "silver") || _good_transport_load_per_unit_q16[i] <= 0) {
            error = "good_parameter_out_of_range";
            return false;
        }
    }
	_cycle_flow_good_ids.clear();
	for (size_t i = 0; i < goods; ++i) {
		if (_good_storage_modes[i] == 1) {
			_cycle_flow_good_ids.push_back(static_cast<int32_t>(i));
			_good_trade_enabled[i] = 0;
		}
	}

    _need_ids = packed_strings(catalog, "need_ids");
    const std::vector<std::string> curve_ids = packed_strings(catalog, "environment_curve_ids");
    const std::vector<int32_t> curve_signals = packed_i32(catalog, "environment_curve_signal_ids");
    const std::vector<int32_t> curve_values = packed_i32(catalog, "environment_curve_values_q16");
    if (_need_ids.empty() || _need_ids.size() > 32 || curve_ids.size() != curve_signals.size() ||
        curve_values.size() != curve_ids.size() * ENV_CURVE_SAMPLES ||
        !unique_sorted(_need_ids, "need") || !unique_sorted(curve_ids, "environment_curve")) {
        error = "need_or_environment_curve_catalog_invalid";
        return false;
    }
    _survival_food_need_stable_ids.clear();
    for (const char *id : {"staple_food", "protein", "produce"}) {
        const auto found = std::lower_bound(_need_ids.begin(), _need_ids.end(), id);
        if (found == _need_ids.end() || *found != id) {
            error = std::string("survival_food_need_missing:") + id;
            return false;
        }
        _survival_food_need_stable_ids.push_back(
            static_cast<int32_t>(found - _need_ids.begin()));
    }
    _survival_staple_need_stable_id = _survival_food_need_stable_ids.front();
    const auto clothing = std::lower_bound(_need_ids.begin(), _need_ids.end(), "clothing");
    if (clothing == _need_ids.end() || *clothing != "clothing") {
        error = "survival_clothing_need_missing:clothing";
        return false;
    }
    _survival_clothing_need_stable_id =
        static_cast<int32_t>(clothing - _need_ids.begin());
    _environment_curves.resize(curve_ids.size());
    for (size_t c = 0; c < curve_ids.size(); ++c) {
        if (curve_signals[c] < 0 || curve_signals[c] > 3) {
            error = "environment_curve_signal_invalid";
            return false;
        }
        _environment_curves[c].signal_id = curve_signals[c];
        for (int32_t k = 0; k < ENV_CURVE_SAMPLES; ++k) {
            _environment_curves[c].values_q16[k] = std::max(0, curve_values[c * ENV_CURVE_SAMPLES + k]);
        }
    }

    const std::vector<int32_t> plan_offsets = packed_i32(catalog, "plan_need_offsets");
    const std::vector<int32_t> need_stable = packed_i32(catalog, "need_stable_ids");
    const std::vector<int32_t> need_living_weights =
        packed_i32(catalog, "need_living_cost_weights_q16");
    const std::vector<int32_t> need_priority = packed_i32(catalog, "need_priorities");
    const std::vector<int64_t> need_base = packed_i64(catalog, "need_base_qty_per_person");
    const std::vector<int32_t> need_wealth_elasticity = packed_i32(catalog, "need_wealth_elasticity_q16");
    const std::vector<int32_t> need_wealth_min = packed_i32(catalog, "need_wealth_min_q16");
    const std::vector<int32_t> need_wealth_max = packed_i32(catalog, "need_wealth_max_q16");
    const std::vector<int32_t> need_price_quantity_elasticity = packed_i32(
        catalog, "need_price_quantity_elasticity_q16");
    const std::vector<int32_t> need_price_quantity_floor = packed_i32(
        catalog, "need_price_quantity_floor_q16");
    const std::vector<int32_t> need_env = packed_i32(catalog, "need_quantity_env_curve_ids");
    const std::vector<int32_t> need_variant_offsets = packed_i32(catalog, "need_variant_offsets");
    const size_t need_count = need_stable.size();
    if (plan_offsets.size() != _plan_ids.size() + 1 || plan_offsets.front() != 0 ||
        plan_offsets.back() != static_cast<int32_t>(need_count) || need_priority.size() != need_count ||
        need_base.size() != need_count || need_wealth_elasticity.size() != need_count ||
        need_wealth_min.size() != need_count || need_wealth_max.size() != need_count ||
        need_price_quantity_elasticity.size() != need_count ||
        need_price_quantity_floor.size() != need_count ||
        need_env.size() != need_count ||
        need_living_weights.size() != _need_ids.size() ||
        need_variant_offsets.size() != need_count + 1 ||
        need_variant_offsets.front() != 0) {
        error = "market_v2_need_columns_invalid";
        return false;
    }
    const std::vector<int32_t> variant_preference = packed_i32(catalog, "variant_preference_q16");
    const std::vector<int32_t> variant_elasticity = packed_i32(catalog, "variant_price_elasticity_q16");
    const std::vector<int32_t> variant_env = packed_i32(catalog, "variant_preference_env_curve_ids");
    const std::vector<int32_t> variant_component_offsets = packed_i32(catalog, "variant_component_offsets");
    const size_t variant_count = variant_preference.size();
    if (need_variant_offsets.back() != static_cast<int32_t>(variant_count) ||
        variant_elasticity.size() != variant_count || variant_env.size() != variant_count ||
        variant_component_offsets.size() != variant_count + 1 || variant_component_offsets.front() != 0) {
        error = "market_v2_variant_columns_invalid";
        return false;
    }
    const std::vector<int32_t> component_goods = packed_i32(catalog, "component_good_ids");
    const std::vector<int64_t> component_qty = packed_i64(catalog, "component_qty_per_need");
    if (variant_component_offsets.back() != static_cast<int32_t>(component_goods.size()) ||
        component_qty.size() != component_goods.size()) {
        error = "market_v2_component_columns_invalid";
        return false;
    }
    _plans.resize(_plan_ids.size());
    for (size_t p = 0; p < _plans.size(); ++p) {
        const int32_t begin = plan_offsets[p];
        const int32_t count = plan_offsets[p + 1] - begin;
        if (begin < 0 || count < 0 || count > MAX_NEEDS_PER_PLAN) {
            error = "plan_need_limit_exceeded";
            return false;
        }
        _plans[p] = {begin, count};
    }
    _needs.resize(need_count);
    for (size_t n = 0; n < need_count; ++n) {
        const int32_t variants_begin = need_variant_offsets[n];
        const int32_t variants_count = need_variant_offsets[n + 1] - variants_begin;
        if (need_stable[n] < 0 || need_stable[n] >= static_cast<int32_t>(_need_ids.size()) ||
            need_base[n] < 0 || need_wealth_min[n] < 0 || need_wealth_max[n] < need_wealth_min[n] ||
            need_price_quantity_elasticity[n] < 0 ||
            need_price_quantity_elasticity[n] > Q16_ONE * 4 ||
            need_price_quantity_floor[n] < 0 || need_price_quantity_floor[n] > Q16_ONE ||
            need_env[n] < -1 || need_env[n] >= static_cast<int32_t>(_environment_curves.size()) ||
            need_living_weights[need_stable[n]] < 0 ||
            need_living_weights[need_stable[n]] > Q16_ONE ||
            variants_count <= 0 || variants_count > MAX_VARIANTS_PER_NEED) {
            error = "market_v2_need_entry_invalid";
            return false;
        }
        _needs[n] = {need_stable[n], need_priority[n], variants_begin, variants_count,
                     need_base[n], need_wealth_elasticity[n], need_wealth_min[n],
                     need_wealth_max[n], need_price_quantity_elasticity[n],
                     need_price_quantity_floor[n], need_env[n],
                     need_living_weights[need_stable[n]]};
    }
    _variants.resize(variant_count);
    for (size_t v = 0; v < variant_count; ++v) {
        const int32_t comp_begin = variant_component_offsets[v];
        const int32_t comp_count = variant_component_offsets[v + 1] - comp_begin;
        if (variant_preference[v] < 0 || variant_elasticity[v] < 0 ||
            variant_env[v] < -1 || variant_env[v] >= static_cast<int32_t>(_environment_curves.size()) ||
            comp_count <= 0 || comp_count > MAX_COMPONENTS_PER_VARIANT) {
            error = "market_v2_variant_entry_invalid";
            return false;
        }
        int64_t reference_cost = 0;
        for (int32_t k = 0; k < comp_count; ++k) {
            const int32_t component = comp_begin + k;
            if (component_goods[component] < 0 || component_goods[component] >= static_cast<int32_t>(goods) ||
                component_qty[component] <= 0) {
                error = "market_v2_component_entry_invalid";
                return false;
            }
            reference_cost = saturating_add(reference_cost,
                mul_div_sat(component_qty[component], _good_default_price[component_goods[component]],
                            GOODS_SCALE, _saturation_count), _saturation_count);
        }
        _variants[v] = {comp_begin, comp_count, variant_preference[v], variant_elasticity[v],
                        variant_env[v], std::max<int64_t>(1, reference_cost)};
    }
    _components.resize(component_goods.size());
    for (size_t c = 0; c < component_goods.size(); ++c) {
        _components[c] = {component_goods[c], component_qty[c]};
    }
    _survival_food_good_mask.assign(goods, uint8_t{0});
    _survival_staple_good_mask.assign(goods, uint8_t{0});
    _survival_clothing_good_mask.assign(goods, uint8_t{0});
    for (const Need &need : _needs) {
        const bool survival_food_need = std::find(
            _survival_food_need_stable_ids.begin(),
            _survival_food_need_stable_ids.end(), need.stable_id) !=
            _survival_food_need_stable_ids.end();
        const bool survival_clothing_need =
            need.stable_id == _survival_clothing_need_stable_id;
        if (!survival_food_need && !survival_clothing_need) continue;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const VariantChoice &variant = _variants[need.variant_begin + v];
            if (variant.component_count != 1) continue;
            const NeedComponent &component = _components[variant.component_begin];
            if (component.qty_per_need == GOODS_SCALE) {
                if (survival_food_need) {
                    _survival_food_good_mask[component.good_id] = 1;
                    if (need.stable_id == _survival_staple_need_stable_id)
                        _survival_staple_good_mask[component.good_id] = 1;
                }
                if (survival_clothing_need)
                    _survival_clothing_good_mask[component.good_id] = 1;
            }
        }
    }
    if (std::none_of(_survival_food_good_mask.begin(),
                     _survival_food_good_mask.end(), [](uint8_t value) {
                         return value != 0;
                     })) {
        error = "survival_food_good_catalog_empty";
        return false;
    }

    const std::vector<int32_t> sig_prof = packed_i32(catalog, "signature_profession_ids");
    const std::vector<int32_t> sig_eth = packed_i32(catalog, "signature_ethnicity_ids");
    const std::vector<int32_t> sig_plan = packed_i32(catalog, "signature_plan_ids");
    const std::vector<int64_t> sig_birth = packed_i64(catalog, "signature_birth_rate_q32");
    const std::vector<int64_t> sig_death = packed_i64(catalog, "signature_death_rate_q32");
    std::vector<int64_t> sig_sat_weight = packed_i64(catalog, "signature_satisfaction_birth_weight_q16");
    const size_t sig_count = sig_prof.size();
    if (sig_count == 0 || sig_eth.size() != sig_count || sig_plan.size() != sig_count ||
        sig_birth.size() != sig_count || sig_death.size() != sig_count) {
        error = "signature_table_size_mismatch";
        return false;
    }
    if (sig_sat_weight.empty()) sig_sat_weight.assign(sig_count, Q16_ONE);
    if (sig_sat_weight.size() != sig_count) {
        error = "signature_satisfaction_weight_size_mismatch";
        return false;
    }
    _signatures.resize(sig_count);
    for (size_t i = 0; i < sig_count; ++i) {
        if (sig_prof[i] < 0 || sig_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            sig_eth[i] < 0 || sig_eth[i] >= static_cast<int32_t>(_ethnicity_ids.size()) ||
            sig_plan[i] < 0 || sig_plan[i] >= static_cast<int32_t>(_plans.size()) ||
            sig_birth[i] < 0 || sig_death[i] < 0) {
            error = "signature_entry_invalid";
            return false;
        }
        _signatures[i] = {sig_prof[i], sig_eth[i], sig_plan[i], sig_birth[i], sig_death[i],
                          sig_sat_weight[i]};
    }
    _merchant_profession_id = -1;
    for (size_t p = 0; p < _profession_ids.size(); ++p) {
        if (_profession_ids[p] == _merchant_profession_stable_id) {
            _merchant_profession_id = static_cast<int32_t>(p);
            break;
        }
    }
    if (_merchant_profession_id < 0) {
        error = "merchant_profession_missing:" + _merchant_profession_stable_id;
        return false;
    }
    // The unemployed profession is optional: catalogs that predate the explicit
    // unemployment model simply leave it unresolved (-1), and the employment pass
    // falls back to the derived population - owner - employee accounting. When it
    // is present it enables the persistent unemployed-pool signatures.
    _unemployed_profession_id = -1;
    for (size_t p = 0; p < _profession_ids.size(); ++p) {
        if (_profession_ids[p] == _unemployed_profession_stable_id) {
            _unemployed_profession_id = static_cast<int32_t>(p);
            break;
        }
    }
    // Build the dense (profession, ethnicity) -> signature lookup. Deterministic:
    // signatures are the profession x ethnicity cartesian product, so at most one
    // entry per (profession, ethnicity). Any unfilled cell stays -1.
    {
        const size_t n_prof = _profession_ids.size();
        const size_t n_eth = _ethnicity_ids.size();
        _signature_by_profession_ethnicity.assign(n_prof * n_eth, -1);
        for (size_t i = 0; i < _signatures.size(); ++i) {
            const int32_t prof = _signatures[i].profession_id;
            const int32_t eth = _signatures[i].ethnicity_id;
            if (prof < 0 || eth < 0 || static_cast<size_t>(prof) >= n_prof ||
                static_cast<size_t>(eth) >= n_eth) {
                error = "signature_profession_ethnicity_out_of_range";
                return false;
            }
            const size_t idx = static_cast<size_t>(prof) * n_eth + static_cast<size_t>(eth);
            if (_signature_by_profession_ethnicity[idx] < 0) {
                _signature_by_profession_ethnicity[idx] = static_cast<int32_t>(i);
            }
        }
    }
    _ethnicity_need_factor_q16 = packed_i32(catalog, "ethnicity_need_factor_q16");
    if (_ethnicity_need_factor_q16.empty()) {
        _ethnicity_need_factor_q16.assign(_ethnicity_ids.size() * _need_ids.size(), Q16_ONE);
    }
    if (_ethnicity_need_factor_q16.size() != _ethnicity_ids.size() * _need_ids.size()) {
        error = "ethnicity_need_factor_size_mismatch";
        return false;
    }
    if (!compile_building_catalog(catalog, error)) return false;
    if (!compile_technology_tags(_building_technology_tag_offsets,
            _building_technology_tags, _building_type_ids.size(),
            _building_technology_offsets, _building_required_technologies,
            "building_technology_catalog_invalid")) return false;
    _living_cost_base_plan_id = -1;
    for (size_t p = 0; p < _plan_ids.size(); ++p) {
        if (_plan_ids[p] == _living_cost_base_plan_stable_id) {
            _living_cost_base_plan_id = static_cast<int32_t>(p);
            break;
        }
    }
    if (_living_cost_base_plan_id < 0) {
        error = "living_cost_base_plan_missing:" + _living_cost_base_plan_stable_id;
        return false;
    }
    _survival_required_need_indices.assign(_need_ids.size(), -1);
    const Plan &survival_plan = _plans[_living_cost_base_plan_id];
    for (int32_t n = 0; n < survival_plan.need_count; ++n) {
        const int32_t need_index = survival_plan.need_begin + n;
        const int32_t stable_need = _needs[need_index].stable_id;
        if (_survival_required_need_indices[stable_need] >= 0) {
            error = "survival_required_need_duplicate:" + _need_ids[stable_need];
            return false;
        }
        _survival_required_need_indices[stable_need] = need_index;
    }
    for (int32_t stable_need : _survival_food_need_stable_ids) {
        if (_survival_required_need_indices[stable_need] < 0) {
            error = "survival_required_food_missing:" + _need_ids[stable_need];
            return false;
        }
    }
    if (_survival_required_need_indices[_survival_clothing_need_stable_id] < 0) {
        error = "survival_required_clothing_missing:" +
            _need_ids[_survival_clothing_need_stable_id];
        return false;
    }
    _catalog_hash = dict_num<int64_t>(catalog, "catalog_hash", 0);
    _catalog_compat_hash_v8 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v8", 0);
    _catalog_compat_hash_v10 = dict_num<int64_t>(catalog, "catalog_compat_hash_v10", 0);
    _catalog_compat_hash_v13 = dict_num<int64_t>(catalog, "catalog_compat_hash_v13", 0);
    _catalog_compat_hash_v6 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v6", 0);
    _catalog_compat_hash_v7 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v7", 0);
    _building_catalog_hash = dict_num<int64_t>(catalog, "building_catalog_hash", 1);
    _building_catalog_compat_hash_v6 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v6", 0);
    _building_catalog_compat_hash_v7 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v7", 0);
    _building_catalog_compat_hash_v13 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v13", 0);
    if (_catalog_hash == 0) {
        error = "catalog_hash_required";
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::compile_building_catalog(const Dictionary &catalog,
                                                     std::string &error) {
    _building_type_ids = packed_strings(catalog, "building_type_ids");
	_building_upgrade_family_ids = packed_strings(catalog, "building_upgrade_family_ids");
	_building_upgrade_family_indices = packed_i32(catalog, "building_upgrade_family_indices");
	_building_upgrade_tiers = packed_i32(catalog, "building_upgrade_tiers");
    _resource_ids = packed_strings(catalog, "building_resource_ids");
    _resource_reserve_slots = packed_strings(catalog, "building_resource_reserve_slots");
    _resource_extra_slots = packed_strings(catalog, "building_resource_extra_slots");
    _resource_gen_base = packed_i64(catalog, "building_resource_gen_base");
    _resource_gen_temp = packed_i64(catalog, "building_resource_gen_temp");
    _resource_gen_moisture = packed_i64(catalog, "building_resource_gen_moisture");
    _resource_gen_self = packed_i64(catalog, "building_resource_gen_self");
    _resource_decay_base = packed_i64(catalog, "building_resource_decay_base");
    _resource_decay_temp = packed_i64(catalog, "building_resource_decay_temp");
    _resource_decay_moisture = packed_i64(catalog, "building_resource_decay_moisture");
    _resource_decay_self_q16 = packed_i32(catalog, "building_resource_decay_self_q16");
    _resource_ecology_capacity = packed_i64(catalog, "building_resource_ecology_capacity");
    _resource_ecology_growth_q16 = packed_i32(catalog, "building_resource_ecology_growth_q16");
    _resource_temp_lo_q16 = packed_i32(catalog, "building_resource_temp_lo_q16");
    _resource_temp_hi_q16 = packed_i32(catalog, "building_resource_temp_hi_q16");
    const size_t resource_count = _resource_ids.size();
    if (_resource_ids.size() != _resource_reserve_slots.size() ||
        _resource_ids.size() != _resource_extra_slots.size() ||
        _resource_gen_base.size() != resource_count ||
        _resource_gen_temp.size() != resource_count ||
        _resource_gen_moisture.size() != resource_count ||
        _resource_gen_self.size() != resource_count ||
        _resource_decay_base.size() != resource_count ||
        _resource_decay_temp.size() != resource_count ||
        _resource_decay_moisture.size() != resource_count ||
        _resource_decay_self_q16.size() != resource_count ||
        _resource_ecology_capacity.size() != resource_count ||
        _resource_ecology_growth_q16.size() != resource_count ||
        _resource_temp_lo_q16.size() != resource_count ||
        _resource_temp_hi_q16.size() != resource_count ||
        !std::is_sorted(_resource_ids.begin(), _resource_ids.end()) ||
        std::adjacent_find(_resource_ids.begin(), _resource_ids.end()) != _resource_ids.end()) {
        error = "building_resource_catalog_invalid";
        return false;
    }
    if (_building_type_ids.empty()) {
        _building_technology_tag_offsets = packed_i32(catalog, "building_technology_tag_offsets");
        _building_technology_tags = packed_strings(catalog, "building_technology_tags");
        if (_building_technology_tag_offsets.size() != 1 ||
            _building_technology_tag_offsets.front() != 0 ||
            !_building_technology_tags.empty() || !_building_upgrade_family_ids.empty() ||
            !_building_upgrade_family_indices.empty() || !_building_upgrade_tiers.empty()) {
            error = "building_technology_catalog_invalid";
            return false;
        }
        _building_types.clear();
        _building_employee_roles.clear();
        _building_construction_goods.clear();
        _building_inputs.clear();
        _building_input_candidates.clear();
        _building_outputs.clear();
        _building_output_cost_shares_q16.clear();
        _building_resources.clear();
        _building_resource_generation.clear();
        _building_conditions.clear();
        return true;
    }
    if (!std::is_sorted(_building_type_ids.begin(), _building_type_ids.end()) ||
        std::adjacent_find(_building_type_ids.begin(), _building_type_ids.end()) !=
            _building_type_ids.end() || _building_type_ids.size() > 4096) {
        error = "building_type_ids_not_sorted_unique";
        return false;
    }
    if (!std::is_sorted(_building_upgrade_family_ids.begin(),
                        _building_upgrade_family_ids.end()) ||
        std::adjacent_find(_building_upgrade_family_ids.begin(),
                           _building_upgrade_family_ids.end()) !=
            _building_upgrade_family_ids.end()) {
        error = "building_upgrade_family_ids_not_sorted_unique";
        return false;
    }
    const size_t types = _building_type_ids.size();
    const std::vector<int32_t> owner_prof = packed_i32(catalog, "building_owner_profession_ids");
    const std::vector<int64_t> owner_slots = packed_i64(catalog, "building_owner_slots");
    const std::vector<int64_t> wages = packed_i64(catalog, "building_wage_per_employee_per_day");
    const std::vector<int32_t> construction_days = packed_i32(catalog, "building_construction_days");
    const std::vector<int32_t> behavior_ids = packed_i32(catalog, "building_behavior_ids");
    const std::vector<int32_t> behavior_versions = packed_i32(catalog, "building_behavior_versions");
    const std::vector<int32_t> target_margins =
        packed_i32(catalog, "building_target_operating_margin_q16");
    const std::vector<int32_t> supply_elasticities =
        packed_i32(catalog, "building_supply_price_elasticity_q16");
	_building_kinds = packed_i32(catalog, "building_kinds");
	_building_technology_tag_offsets = packed_i32(catalog, "building_technology_tag_offsets");
	_building_technology_tags = packed_strings(catalog, "building_technology_tags");
    const std::vector<int32_t> employee_offsets = packed_i32(catalog, "building_employee_offsets");
    const std::vector<int32_t> construction_offsets = packed_i32(catalog, "building_construction_offsets");
    const std::vector<int32_t> input_offsets = packed_i32(catalog, "building_input_offsets");
    const std::vector<int32_t> output_offsets = packed_i32(catalog, "building_output_offsets");
    const std::vector<int32_t> output_cost_share_offsets =
        packed_i32(catalog, "building_output_cost_share_offsets");
    const std::vector<int32_t> resource_offsets = packed_i32(catalog, "building_resource_offsets");
    const std::vector<int32_t> generation_offsets = packed_i32(catalog, "building_resource_generation_offsets");
    const std::vector<int32_t> generation_floors = packed_i32(catalog, "building_resource_generation_floor_q16");
    const std::vector<int32_t> condition_offsets = packed_i32(catalog, "building_condition_offsets");
    auto offsets_valid = [&](const std::vector<int32_t> &v) {
        return v.size() == types + 1 && !v.empty() && v.front() == 0 &&
               std::is_sorted(v.begin(), v.end());
    };
    if (owner_prof.size() != types || owner_slots.size() != types || wages.size() != types ||
        construction_days.size() != types || behavior_ids.size() != types ||
		behavior_versions.size() != types || target_margins.size() != types ||
        supply_elasticities.size() != types || _building_kinds.size() != types ||
		_building_upgrade_family_indices.size() != types ||
		_building_upgrade_tiers.size() != types ||
		!offsets_valid(_building_technology_tag_offsets) ||
		_building_technology_tag_offsets.back() != static_cast<int32_t>(
			_building_technology_tags.size()) || !offsets_valid(employee_offsets) ||
        !offsets_valid(construction_offsets) || !offsets_valid(input_offsets) ||
        !offsets_valid(output_offsets) || !offsets_valid(resource_offsets) ||
        !offsets_valid(output_cost_share_offsets) ||
        !offsets_valid(generation_offsets) || generation_floors.size() != types ||
        !offsets_valid(condition_offsets)) {
        error = "building_type_column_size_mismatch";
        return false;
    }
    const std::vector<int32_t> employee_prof = packed_i32(catalog, "building_employee_profession_ids");
    const std::vector<int64_t> employee_slots = packed_i64(catalog, "building_employee_slots");
    const std::vector<int32_t> employee_wage_policies =
        packed_i32(catalog, "building_employee_wage_policies");
    const std::vector<int64_t> employee_reference_wages =
        packed_i64(catalog, "building_employee_reference_wages_per_day");
    const std::vector<int32_t> construction_goods = packed_i32(catalog, "building_construction_good_ids");
    const std::vector<int64_t> construction_qty = packed_i64(catalog, "building_construction_quantities");
    const std::vector<int32_t> input_goods = packed_i32(catalog, "building_input_good_ids");
    const std::vector<int64_t> input_qty = packed_i64(catalog, "building_input_quantities");
    std::vector<int32_t> input_required_q16 = packed_i32(catalog, "building_input_required_q16");
    if (input_required_q16.empty() && !input_goods.empty()) {
        input_required_q16.assign(input_goods.size(), static_cast<int32_t>(Q16_ONE));
    }
    const std::vector<int32_t> input_candidate_offsets =
        packed_i32(catalog, "building_input_candidate_offsets");
    const std::vector<int32_t> input_candidate_goods =
        packed_i32(catalog, "building_input_candidate_good_ids");
    const std::vector<int32_t> input_candidate_efficiencies =
        packed_i32(catalog, "building_input_candidate_efficiency_q16");
    const std::vector<int32_t> output_goods = packed_i32(catalog, "building_output_good_ids");
    const std::vector<int64_t> output_qty = packed_i64(catalog, "building_output_quantities");
    _building_output_cost_shares_q16 =
        packed_i32(catalog, "building_output_cost_shares_q16");
    const std::vector<int32_t> resource_ids = packed_i32(catalog, "building_production_resource_ids");
    const std::vector<int64_t> resource_qty = packed_i64(catalog, "building_production_resource_quantities");
    const std::vector<int32_t> resource_modes = packed_i32(catalog, "building_production_resource_modes");
    const std::vector<int32_t> resource_access_modes =
        packed_i32(catalog, "building_production_resource_access_modes");
    const std::vector<int32_t> generation_ids = packed_i32(catalog, "building_resource_generation_ids");
    const std::vector<int64_t> generation_qty = packed_i64(catalog, "building_resource_generation_quantities");
    const std::vector<int32_t> condition_opcodes = packed_i32(catalog, "building_condition_opcodes");
    const std::vector<int32_t> condition_signals = packed_i32(catalog, "building_condition_signals");
    const std::vector<int32_t> condition_compares = packed_i32(catalog, "building_condition_compares");
    const std::vector<int32_t> condition_refs = packed_i32(catalog, "building_condition_references");
    const std::vector<int64_t> condition_values = packed_i64(catalog, "building_condition_values");
    if (employee_offsets.back() != static_cast<int32_t>(employee_prof.size()) ||
        employee_slots.size() != employee_prof.size() ||
        employee_wage_policies.size() != employee_prof.size() ||
        employee_reference_wages.size() != employee_prof.size() ||
        construction_offsets.back() != static_cast<int32_t>(construction_goods.size()) ||
        construction_qty.size() != construction_goods.size() ||
        input_offsets.back() != static_cast<int32_t>(input_goods.size()) ||
        input_qty.size() != input_goods.size() ||
        input_required_q16.size() != input_goods.size() ||
        input_candidate_offsets.size() != input_goods.size() + 1 ||
        input_candidate_offsets.empty() || input_candidate_offsets.front() != 0 ||
        !std::is_sorted(input_candidate_offsets.begin(), input_candidate_offsets.end()) ||
        input_candidate_offsets.back() != static_cast<int32_t>(input_candidate_goods.size()) ||
        input_candidate_efficiencies.size() != input_candidate_goods.size() ||
        output_offsets.back() != static_cast<int32_t>(output_goods.size()) ||
        output_qty.size() != output_goods.size() ||
        output_cost_share_offsets.back() !=
            static_cast<int32_t>(_building_output_cost_shares_q16.size()) ||
        resource_offsets.back() != static_cast<int32_t>(resource_ids.size()) ||
        resource_qty.size() != resource_ids.size() || resource_modes.size() != resource_ids.size() ||
        resource_access_modes.size() != resource_ids.size() ||
        generation_offsets.back() != static_cast<int32_t>(generation_ids.size()) ||
        generation_qty.size() != generation_ids.size() ||
        condition_offsets.back() != static_cast<int32_t>(condition_opcodes.size()) ||
        condition_signals.size() != condition_opcodes.size() ||
        condition_compares.size() != condition_opcodes.size() ||
        condition_refs.size() != condition_opcodes.size() ||
        condition_values.size() != condition_opcodes.size()) {
        error = "building_child_column_size_mismatch";
        return false;
    }
    _building_employee_roles.resize(employee_prof.size());
    for (size_t i = 0; i < employee_prof.size(); ++i) {
        if (employee_prof[i] < 0 || employee_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            employee_slots[i] <= 0 || employee_wage_policies[i] < 0 ||
            employee_wage_policies[i] > 2 || employee_reference_wages[i] < 0 ||
            (employee_wage_policies[i] != 0 && employee_reference_wages[i] <= 0)) {
            error = "building_employee_role_invalid";
            return false;
        }
        _building_employee_roles[i] = {employee_prof[i], employee_slots[i],
                                       employee_wage_policies[i],
                                       employee_reference_wages[i]};
    }
    auto compile_goods = [&](const std::vector<int32_t> &ids, const std::vector<int64_t> &qty,
                             std::vector<GoodAmount> &dst, const char *reason) {
        dst.resize(ids.size());
        for (size_t i = 0; i < ids.size(); ++i) {
            if (ids[i] < 0 || ids[i] >= static_cast<int32_t>(_good_ids.size()) || qty[i] <= 0) {
                error = reason;
                return false;
            }
            dst[i] = {ids[i], qty[i]};
        }
        return true;
    };
    if (!compile_goods(construction_goods, construction_qty, _building_construction_goods,
                       "building_construction_good_invalid") ||
        !compile_goods(output_goods, output_qty, _building_outputs,
                       "building_output_good_invalid")) return false;
    _building_inputs.resize(input_goods.size());
    _building_input_candidates.resize(input_candidate_goods.size());
    for (size_t i = 0; i < input_goods.size(); ++i) {
        if (input_goods[i] < 0 || input_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            input_qty[i] <= 0 || input_candidate_offsets[i] >= input_candidate_offsets[i + 1] ||
            input_required_q16[i] < 0 || input_required_q16[i] > Q16_ONE) {
            error = "building_input_good_invalid";
            return false;
        }
        _building_inputs[i] = {input_goods[i], input_qty[i], input_candidate_offsets[i],
                               input_candidate_offsets[i + 1] - input_candidate_offsets[i],
                               input_required_q16[i]};
    }
    for (size_t i = 0; i < input_candidate_goods.size(); ++i) {
        if (input_candidate_goods[i] < 0 ||
            input_candidate_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            input_candidate_efficiencies[i] <= 0 ||
            input_candidate_efficiencies[i] > Q16_ONE * 4) {
            error = "building_input_candidate_invalid";
            return false;
        }
        _building_input_candidates[i] = {
            input_candidate_goods[i], input_candidate_efficiencies[i]};
    }
    _building_resources.resize(resource_ids.size());
    for (size_t i = 0; i < resource_ids.size(); ++i) {
        if (resource_ids[i] < 0 || resource_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            resource_qty[i] <= 0 || resource_modes[i] < 0 || resource_modes[i] > 1 ||
            resource_access_modes[i] != 0) {
            error = "building_production_resource_invalid";
            return false;
        }
        _building_resources[i] = {resource_ids[i], resource_qty[i], resource_modes[i],
                                  resource_access_modes[i]};
    }
    _building_resource_generation.resize(generation_ids.size());
    for (size_t i = 0; i < generation_ids.size(); ++i) {
        if (generation_ids[i] < 0 ||
            generation_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            generation_qty[i] <= 0) {
            error = "building_resource_generation_invalid";
            return false;
        }
        _building_resource_generation[i] = {generation_ids[i], generation_qty[i], 0, 0};
    }
    _building_conditions.resize(condition_opcodes.size());
    for (size_t i = 0; i < condition_opcodes.size(); ++i) {
        if (condition_opcodes[i] < 1 || condition_opcodes[i] > 4 ||
            condition_compares[i] < 0 || condition_compares[i] > 5) {
            error = "building_condition_token_invalid";
            return false;
        }
        _building_conditions[i] = {condition_opcodes[i], condition_signals[i],
                                   condition_compares[i], condition_refs[i],
                                   condition_values[i]};
    }
    _building_types.resize(types);
    std::vector<std::pair<int32_t, int32_t>> upgrade_pairs;
    upgrade_pairs.reserve(types);
    for (size_t i = 0; i < types; ++i) {
        const int32_t family = _building_upgrade_family_indices[i];
        const int32_t tier = _building_upgrade_tiers[i];
        if (family < -1 || family >= static_cast<int32_t>(_building_upgrade_family_ids.size()) ||
            (family < 0 && tier != 0) || (family >= 0 && tier <= 0)) {
            error = "building_upgrade_entry_invalid";
            return false;
        }
        if (family >= 0) upgrade_pairs.emplace_back(family, tier);
        // Route B: building_kind 2 == service (merchant post): no output, no
        // resource, behavior_id must be none(0). Kinds 0 (collector) and 1
        // (industrial) keep their original output/resource/behavior coupling.
        const bool kind_is_service = _building_kinds[i] == 2;
        if (owner_prof[i] < 0 || owner_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            owner_slots[i] <= 0 || wages[i] < 0 || construction_days[i] < 0 ||
            _building_kinds[i] < 0 || _building_kinds[i] > 2 ||
            behavior_ids[i] < 0 || behavior_ids[i] > 2 || behavior_versions[i] != 1 ||
            (!kind_is_service && output_offsets[i] == output_offsets[i + 1]) ||
			(kind_is_service && output_offsets[i] != output_offsets[i + 1]) ||
			(_building_kinds[i] == 0 && resource_offsets[i] == resource_offsets[i + 1]) ||
			(_building_kinds[i] != 0 && resource_offsets[i] != resource_offsets[i + 1]) ||
			(_building_kinds[i] == 0 && behavior_ids[i] == 0) ||
			(_building_kinds[i] == 1 && behavior_ids[i] != 0) ||
			(kind_is_service && behavior_ids[i] != 0) ||
            target_margins[i] < 0 || target_margins[i] > Q16_ONE * 4 ||
            supply_elasticities[i] < 0 || supply_elasticities[i] > Q16_ONE * 4 ||
            (output_cost_share_offsets[i + 1] - output_cost_share_offsets[i] != 0 &&
             output_cost_share_offsets[i + 1] - output_cost_share_offsets[i] !=
                 output_offsets[i + 1] - output_offsets[i]) ||
            generation_floors[i] < 0 || generation_floors[i] > Q16_ONE ||
            (behavior_ids[i] == 2 && generation_offsets[i] == generation_offsets[i + 1]) ||
            (behavior_ids[i] != 2 && generation_offsets[i] != generation_offsets[i + 1])) {
            error = "building_type_entry_invalid";
            return false;
        }
        if (owner_prof[i] == _merchant_profession_id && !kind_is_service) {
            // Route B: a service merchant post (kind 2) is a valid
            // merchant-owned building. Its no-output/no-resource/behavior-none
            // shape is already enforced above, so it bypasses the bullion
            // collector requirement. Non-service merchant buildings must still
            // be a matching gold/silver collector.
            const bool one_output = output_offsets[i + 1] - output_offsets[i] == 1;
            const bool one_resource = resource_offsets[i + 1] - resource_offsets[i] == 1;
            const int32_t output_good = one_output ? output_goods[output_offsets[i]] : -1;
            const int32_t resource = one_resource ? resource_ids[resource_offsets[i]] : -1;
            const bool gold = output_good >= 0 && _good_ids[output_good] == "gold" &&
                resource >= 0 && _resource_ids[resource] == "gold_ore";
            const bool silver = output_good >= 0 && _good_ids[output_good] == "silver" &&
                resource >= 0 && _resource_ids[resource] == "silver_ore";
            if (_building_kinds[i] != 0 || behavior_ids[i] != 1 ||
                !one_output || !one_resource ||
                generation_offsets[i] != generation_offsets[i + 1] ||
                resource_modes[resource_offsets[i]] != 0 || (!gold && !silver)) {
                error = "merchant_building_must_be_matching_bullion_collector";
                return false;
            }
        }
        int64_t explicit_share_sum = 0;
        for (int32_t s = output_cost_share_offsets[i];
             s < output_cost_share_offsets[i + 1]; ++s) {
            if (_building_output_cost_shares_q16[s] < 0) {
                error = "building_output_cost_share_invalid";
                return false;
            }
            explicit_share_sum += _building_output_cost_shares_q16[s];
        }
        if (output_cost_share_offsets[i + 1] > output_cost_share_offsets[i] &&
            explicit_share_sum != Q16_ONE) {
            error = "building_output_cost_share_sum_invalid";
            return false;
        }
        _building_types[i] = {
			_building_kinds[i], family, tier, owner_prof[i], owner_slots[i], wages[i],
            employee_offsets[i], employee_offsets[i + 1] - employee_offsets[i],
            construction_offsets[i], construction_offsets[i + 1] - construction_offsets[i],
            input_offsets[i], input_offsets[i + 1] - input_offsets[i],
            output_offsets[i], output_offsets[i + 1] - output_offsets[i],
            resource_offsets[i], resource_offsets[i + 1] - resource_offsets[i],
            generation_offsets[i], generation_offsets[i + 1] - generation_offsets[i],
            generation_floors[i],
            condition_offsets[i], condition_offsets[i + 1] - condition_offsets[i],
            construction_days[i], behavior_ids[i], behavior_versions[i],
            target_margins[i], supply_elasticities[i], output_cost_share_offsets[i],
            output_cost_share_offsets[i + 1] - output_cost_share_offsets[i]};
    }
    std::sort(upgrade_pairs.begin(), upgrade_pairs.end());
    if (std::adjacent_find(upgrade_pairs.begin(), upgrade_pairs.end()) != upgrade_pairs.end()) {
        error = "building_upgrade_family_tier_duplicate";
        return false;
    }
    return true;
}

int32_t NativeEconomyRuntime::find_cohort_slot(int32_t cell, int32_t signature_id) const {
    if (cell < 0 || cell >= _cell_count || signature_id < 0 ||
        signature_id >= static_cast<int32_t>(_signatures.size())) return -1;
    return _population.find_signature(cell, static_cast<uint32_t>(signature_id));
}

int32_t NativeEconomyRuntime::find_building_group(int32_t cell, int32_t type_id,
                                                   int32_t owner_signature_id) const {
    for (int32_t i = 0; i < static_cast<int32_t>(_buildings.size()); ++i) {
        const BuildingGroup &group = _buildings[i];
        if (group.cell == cell && group.type_id == type_id &&
            group.owner_signature_id == owner_signature_id) return i;
    }
    return -1;
}

void NativeEconomyRuntime::rebuild_building_role_storage() {
    struct SavedRole {
        int32_t cell = -1;
        int32_t type = -1;
        int32_t owner = -1;
        int32_t role = -1;
        int64_t contract = 0;
        int64_t base_living = 0;
        int64_t role_living = 0;
        int64_t local_average = 0;
    };
    struct SavedInputSelection {
        int32_t cell = -1;
        int32_t type = -1;
        int32_t owner = -1;
        int32_t input = -1;
        int32_t good = -1;
    };
    std::vector<SavedRole> saved;
    std::vector<SavedInputSelection> saved_input_selections;
    for (const BuildingGroup &group : _buildings) {
        if (group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t index = group.employee_fill_begin + r;
            if (index < 0 ||
                index >= static_cast<int32_t>(_building_role_contract_wage.size())) continue;
            saved.push_back({group.cell, group.type_id, group.owner_signature_id, r,
                _building_role_contract_wage[index],
                _building_role_base_living_cost[index],
                _building_role_living_cost[index],
                _building_role_local_average_wage[index]});
        }
        for (int32_t input = 0; input < type.input_count; ++input) {
            const int32_t index = group.last_input_selection_begin + input;
            if (index < 0 || index >= static_cast<int32_t>(
                    _building_last_input_selected_goods.size())) continue;
            const int32_t good = _building_last_input_selected_goods[index];
            if (good >= 0) saved_input_selections.push_back({
                group.cell, group.type_id, group.owner_signature_id, input, good});
        }
    }
    std::sort(saved.begin(), saved.end(), [](const SavedRole &a, const SavedRole &b) {
        return std::tie(a.cell, a.type, a.owner, a.role) <
               std::tie(b.cell, b.type, b.owner, b.role);
    });
    std::sort(saved_input_selections.begin(), saved_input_selections.end(),
              [](const SavedInputSelection &a, const SavedInputSelection &b) {
        return std::tie(a.cell, a.type, a.owner, a.input) <
               std::tie(b.cell, b.type, b.owner, b.input);
    });
    std::stable_sort(_buildings.begin(), _buildings.end(), [](const BuildingGroup &a,
                                                               const BuildingGroup &b) {
        if (a.cell != b.cell) return a.cell < b.cell;
        if (a.type_id != b.type_id) return a.type_id < b.type_id;
        return a.owner_signature_id < b.owner_signature_id;
    });
    size_t role_count = 0;
    size_t input_selection_count = 0;
    for (BuildingGroup &group : _buildings) {
        group.employee_fill_begin = static_cast<int32_t>(role_count);
        group.last_input_selection_begin = static_cast<int32_t>(input_selection_count);
        if (group.type_id >= 0 && group.type_id < static_cast<int32_t>(_building_types.size())) {
            role_count += static_cast<size_t>(_building_types[group.type_id].employee_count);
            input_selection_count += static_cast<size_t>(
                _building_types[group.type_id].input_count);
        }
    }
    _building_employee_filled.assign(role_count, 0);
    _building_last_input_selected_goods.assign(input_selection_count, -1);
    _building_role_contract_wage.assign(role_count, 0);
    _building_role_base_living_cost.assign(role_count, 0);
    _building_role_living_cost.assign(role_count, 0);
    _building_role_local_average_wage.assign(role_count, 0);
    _building_role_base_wage_due.assign(role_count, 0);
    _building_role_base_wage_paid.assign(role_count, 0);
    _building_role_bonus_due.assign(role_count, 0);
    _building_role_bonus_paid.assign(role_count, 0);
    size_t saved_cursor = 0;
    for (const BuildingGroup &group : _buildings) {
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const auto key = std::tuple(group.cell, group.type_id,
                                        group.owner_signature_id, r);
            while (saved_cursor < saved.size() &&
                   std::tie(saved[saved_cursor].cell, saved[saved_cursor].type,
                            saved[saved_cursor].owner, saved[saved_cursor].role) < key) {
                ++saved_cursor;
            }
            const int32_t index = group.employee_fill_begin + r;
            if (saved_cursor < saved.size() &&
                std::tie(saved[saved_cursor].cell, saved[saved_cursor].type,
                         saved[saved_cursor].owner, saved[saved_cursor].role) == key) {
                _building_role_contract_wage[index] = saved[saved_cursor].contract;
                _building_role_base_living_cost[index] = saved[saved_cursor].base_living;
                _building_role_living_cost[index] = saved[saved_cursor].role_living;
                _building_role_local_average_wage[index] = saved[saved_cursor].local_average;
            } else {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                _building_role_contract_wage[index] = role.reference_wage_per_day;
            }
        }
    }
    size_t input_selection_cursor = 0;
    for (const BuildingGroup &group : _buildings) {
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t input = 0; input < type.input_count; ++input) {
            const auto key = std::tuple(group.cell, group.type_id,
                                        group.owner_signature_id, input);
            while (input_selection_cursor < saved_input_selections.size() &&
                   std::tie(saved_input_selections[input_selection_cursor].cell,
                            saved_input_selections[input_selection_cursor].type,
                            saved_input_selections[input_selection_cursor].owner,
                            saved_input_selections[input_selection_cursor].input) < key) {
                ++input_selection_cursor;
            }
            if (input_selection_cursor < saved_input_selections.size() &&
                std::tie(saved_input_selections[input_selection_cursor].cell,
                         saved_input_selections[input_selection_cursor].type,
                         saved_input_selections[input_selection_cursor].owner,
                         saved_input_selections[input_selection_cursor].input) == key) {
                _building_last_input_selected_goods[
                    group.last_input_selection_begin + input] =
                        saved_input_selections[input_selection_cursor].good;
            }
        }
    }
    rebuild_building_cell_offsets();
    rebuild_market_signals();
    rebuild_labor_signals();
}

void NativeEconomyRuntime::rebuild_building_cell_offsets() {
    _building_cell_offsets.assign(static_cast<size_t>(std::max(0, _cell_count)) + 1, 0);
    _building_active_cells.clear();
    for (const BuildingGroup &group : _buildings) {
        if (group.cell >= 0 && group.cell < _cell_count && group.count > 0) {
            ++_building_cell_offsets[group.cell + 1];
        }
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _building_cell_offsets[cell + 1] += _building_cell_offsets[cell];
        if (_building_cell_offsets[cell + 1] > _building_cell_offsets[cell]) {
            _building_active_cells.push_back(cell);
        }
    }
}

void NativeEconomyRuntime::rebuild_market_signals() {
    struct SavedSignal {
        int32_t cell = -1;
        int32_t good = -1;
        int64_t business = 0;
        int64_t supply = 0;
        int64_t withdrawal = 0;
        int32_t anchor = 0;
    };
    std::vector<SavedSignal> saved;
    if (_market_signals.cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        saved.reserve(_market_signals.good_ids.size());
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            for (int32_t i = _market_signals.cell_offsets[cell];
                 i < _market_signals.cell_offsets[cell + 1]; ++i) {
                saved.push_back({cell, _market_signals.good_ids[i],
                    _market_signals.business_demand_ema[i],
                    _market_signals.offered_supply_ema[i],
                    _market_signals.realized_withdrawal_ema[i],
                    _market_signals.cost_anchor_price[i]});
            }
        }
    }
    std::vector<std::pair<int32_t, int32_t>> keys;
    for (const BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            for (int32_t c = input.candidate_begin;
                 c < input.candidate_begin + input.candidate_count; ++c)
                keys.emplace_back(group.cell, _building_input_candidates[c].good_id);
        }
        for (int32_t i = 0; i < type.output_count; ++i)
            keys.emplace_back(group.cell, _building_outputs[type.output_begin + i].good_id);
    }
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    _market_signals.clear(_cell_count);
    _market_signals.good_ids.reserve(keys.size());
    _market_signals.business_demand_ema.assign(keys.size(), 0);
    _market_signals.offered_supply_ema.assign(keys.size(), 0);
    _market_signals.realized_withdrawal_ema.assign(keys.size(), 0);
    _market_signals.cost_anchor_price.assign(keys.size(), 0);
    for (const auto &key : keys) ++_market_signals.cell_offsets[key.first + 1];
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _market_signals.cell_offsets[cell + 1] += _market_signals.cell_offsets[cell];
    size_t old_cursor = 0;
    for (size_t i = 0; i < keys.size(); ++i) {
        _market_signals.good_ids.push_back(keys[i].second);
        while (old_cursor < saved.size() &&
               std::pair(saved[old_cursor].cell, saved[old_cursor].good) < keys[i]) ++old_cursor;
        if (old_cursor < saved.size() && saved[old_cursor].cell == keys[i].first &&
            saved[old_cursor].good == keys[i].second) {
            _market_signals.business_demand_ema[i] = saved[old_cursor].business;
            _market_signals.offered_supply_ema[i] = saved[old_cursor].supply;
            _market_signals.realized_withdrawal_ema[i] = saved[old_cursor].withdrawal;
            _market_signals.cost_anchor_price[i] = saved[old_cursor].anchor;
        }
    }
    rebuild_production_input_reserves();
}

int32_t NativeEconomyRuntime::ensure_market_signal_index(int32_t cell, int32_t good) {
    if (cell < 0 || cell >= _cell_count || good < 0 || good >= _market.good_count ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return -1;
    const int32_t begin = _market_signals.cell_offsets[cell];
    const int32_t end = _market_signals.cell_offsets[cell + 1];
    const auto first = _market_signals.good_ids.begin() + begin;
    const auto last = _market_signals.good_ids.begin() + end;
    const auto it = std::lower_bound(first, last, good);
    if (it != last && *it == good) {
        return static_cast<int32_t>(it - _market_signals.good_ids.begin());
    }
    const int32_t insert_pos = static_cast<int32_t>(it - _market_signals.good_ids.begin());
    const size_t old_size = _market_signals.good_ids.size();
    _market_signals.good_ids.insert(_market_signals.good_ids.begin() + insert_pos, good);
    _market_signals.business_demand_ema.insert(
        _market_signals.business_demand_ema.begin() + insert_pos, 0);
    _market_signals.offered_supply_ema.insert(
        _market_signals.offered_supply_ema.begin() + insert_pos, 0);
    _market_signals.realized_withdrawal_ema.insert(
        _market_signals.realized_withdrawal_ema.begin() + insert_pos, 0);
    _market_signals.cost_anchor_price.insert(
        _market_signals.cost_anchor_price.begin() + insert_pos, 0);
    for (int32_t c = cell + 1; c < static_cast<int32_t>(_market_signals.cell_offsets.size()); ++c) {
        ++_market_signals.cell_offsets[c];
    }
    auto insert_i64_if_aligned = [&](std::vector<int64_t> &values) {
        if (values.size() == old_size) values.insert(values.begin() + insert_pos, 0);
    };
    auto insert_i32_if_aligned = [&](std::vector<int32_t> &values) {
        if (values.size() == old_size) values.insert(values.begin() + insert_pos, 0);
    };
    insert_i64_if_aligned(_epoch_business_demand_ema);
    insert_i64_if_aligned(_epoch_desired_business_demand);
    insert_i64_if_aligned(_epoch_funded_business_demand);
    insert_i64_if_aligned(_epoch_offered_supply_ema);
    insert_i64_if_aligned(_epoch_nonhousehold_withdrawals);
    insert_i32_if_aligned(_epoch_cost_anchor_price);
    insert_i64_if_aligned(_production_input_reserve);
    return insert_pos;
}

int32_t NativeEconomyRuntime::market_signal_index(int32_t cell, int32_t good) const {
    if (cell < 0 || cell >= _cell_count ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return -1;
    const int32_t begin = _market_signals.cell_offsets[cell];
    const int32_t end = _market_signals.cell_offsets[cell + 1];
    const auto first = _market_signals.good_ids.begin() + begin;
    const auto last = _market_signals.good_ids.begin() + end;
    const auto it = std::lower_bound(first, last, good);
    return it != last && *it == good ? static_cast<int32_t>(it - _market_signals.good_ids.begin()) : -1;
}

void NativeEconomyRuntime::rebuild_production_input_reserves(
        int32_t active_begin, int32_t active_end, bool initialize) {
    if (initialize) {
        _production_input_reserve.assign(_market_signals.good_ids.size(), 0);
        _production_input_reserved = 0;
        _production_input_reserve_shortfall = 0;
    }
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    active_begin = std::clamp<int32_t>(
        active_begin, 0, static_cast<int32_t>(active_cells.size()));
    active_end = active_end < 0
        ? static_cast<int32_t>(active_cells.size())
        : std::clamp<int32_t>(active_end, active_begin,
                              static_cast<int32_t>(active_cells.size()));
    const bool frozen = _epoch_active;
    thread_local std::vector<int32_t> selected_signals;
    thread_local std::vector<int64_t> selected_physical;
    auto input_purchase_scale_q16 = [&](const ProductionInput &input,
                                        int64_t output_scale_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return 0;
        const int64_t floor_q16 = Q16_ONE - required;
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        if (output_scale_q16 <= floor_q16) return 0;
        const int64_t delta = output_scale_q16 - floor_q16;
        return std::min<int64_t>(
            Q16_ONE, mul_div_sat(delta, Q16_ONE, required, _saturation_count));
    };
    auto soft_input_bound_q16 = [&](const ProductionInput &input,
                                    int64_t raw_capacity_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return Q16_ONE;
        raw_capacity_q16 = std::clamp<int64_t>(raw_capacity_q16, 0, Q16_ONE);
        return std::clamp<int64_t>(
            Q16_ONE - required + mul_div_sat(
                raw_capacity_q16, required, Q16_ONE, _saturation_count),
            0, Q16_ONE);
    };
    for (int32_t active = active_begin; active < active_end; ++active) {
        const int32_t cell = active_cells[active];
        const int32_t group_begin = _building_cell_offsets[cell];
        const int32_t group_end = _building_cell_offsets[cell + 1];
        for (int32_t group_index = group_begin; group_index < group_end; ++group_index) {
        const BuildingGroup &group = _buildings[group_index];
        if (group.count <= 0 || group.operating_state != 0 ||
            group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            !building_available(group.cell, group.type_id, frozen)) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t utilization_q16 = std::clamp<int64_t>(
            group.planned_utilization_q16, 0, Q16_ONE);
        if (utilization_q16 <= 0) continue;
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        const int32_t market = _market.cell_to_market[group.cell];
        bool produces_survival_food = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            produces_survival_food = produces_survival_food ||
                _survival_food_good_mask[good] != 0;
        }
        selected_signals.assign(type.input_count, -1);
        selected_physical.assign(type.input_count, 0);
        int64_t executable_q16 = Q16_ONE;
        bool household_priority_bundle = false;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            int32_t selected = -1;
            int32_t selected_signal = -1;
            int64_t selected_physical_qty = 0;
            int64_t best_capacity_q16 = -1;
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            const int64_t full_effective = saturating_mul(
                building_days, input.quantity, _saturation_count);
            const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                input, utilization_q16);
            if (purchase_scale_q16 <= 0) continue;
            const int64_t scaled_numerator = saturating_add(saturating_mul(
                full_effective, purchase_scale_q16, _saturation_count),
                Q16_ONE - 1, _saturation_count);
            const int64_t scaled_effective = scaled_numerator / Q16_ONE;
            for (int32_t c = input.candidate_begin;
                 c < input.candidate_begin + input.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (_good_storage_modes[candidate.good_id] != 0 ||
                    !good_available(group.cell, candidate.good_id, frozen)) continue;
                const int32_t signal = market_signal_index(group.cell, candidate.good_id);
                if (signal < 0 || signal >= static_cast<int32_t>(
                        _production_input_reserve.size())) continue;
                const int64_t physical_numerator = saturating_add(saturating_mul(
                    scaled_effective, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t physical = physical_numerator / candidate.efficiency_q16;
                const int64_t available = std::max<int64_t>(0,
                    _market.stock[_market.index(market, candidate.good_id)] -
                    _production_input_reserve[signal]);
                const int64_t capacity_q16 = physical > 0
                    ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                        available, Q16_ONE, physical, _saturation_count))
                    : Q16_ONE;
                const int64_t effective_price = mul_div_sat(
                    _market.price[_market.index(market, candidate.good_id)], Q16_ONE,
                    candidate.efficiency_q16, _saturation_count);
                if (capacity_q16 > best_capacity_q16 ||
                    (capacity_q16 == best_capacity_q16 &&
                     (effective_price < best_effective_price ||
                      (effective_price == best_effective_price &&
                       (selected < 0 || candidate.good_id <
                        _building_input_candidates[selected].good_id))))) {
                    selected = c;
                    selected_signal = signal;
                    selected_physical_qty = physical;
                    best_capacity_q16 = capacity_q16;
                    best_effective_price = effective_price;
                }
            }
            if (selected < 0) {
                executable_q16 = std::min<int64_t>(
                    executable_q16, soft_input_bound_q16(input, 0));
                continue;
            }
            const InputCandidate &candidate = _building_input_candidates[selected];
            selected_signals[i] = selected_signal;
            selected_physical[i] = selected_physical_qty;
            executable_q16 = std::min(executable_q16, best_capacity_q16);
            if (!produces_survival_food &&
                _survival_food_good_mask[candidate.good_id] != 0) {
                household_priority_bundle = true;
            }
        }
        // 多个候选槽可落到同一商品；按商品合并需求后再算整套配方上限，
        // 避免重复槽位预留量超过市场实存。
        for (int32_t i = 0; i < type.input_count; ++i) {
            const int32_t signal = selected_signals[i];
            if (signal < 0) continue;
            bool first_for_signal = true;
            int64_t combined_desired = 0;
            for (int32_t j = 0; j < type.input_count; ++j) {
                if (selected_signals[j] != signal) continue;
                if (j < i) first_for_signal = false;
                combined_desired = saturating_add(
                    combined_desired, selected_physical[j], _saturation_count);
            }
            if (!first_for_signal || combined_desired <= 0) continue;
            const int32_t good = _market_signals.good_ids[signal];
            const int64_t available = std::max<int64_t>(0,
                _market.stock[_market.index(market, good)] -
                _production_input_reserve[signal]);
            executable_q16 = std::min<int64_t>(executable_q16,
                std::min<int64_t>(Q16_ONE, mul_div_sat(
                    available, Q16_ONE, combined_desired, _saturation_count)));
        }
        // 家庭生存消费优先于非生存加工；此类加工只能使用家庭结算后的余量，
        // 因而整套互补投入都不提前保护。
        if (household_priority_bundle) executable_q16 = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const int32_t signal = selected_signals[i];
            const int64_t desired = selected_physical[i];
            if (signal < 0 || desired <= 0) continue;
            const int64_t reserved = mul_div_sat(
                desired, executable_q16, Q16_ONE, _saturation_count);
            _production_input_reserve[signal] = saturating_add(
                _production_input_reserve[signal], reserved, _saturation_count);
            _production_input_reserved = saturating_add(
                _production_input_reserved, reserved, _saturation_count);
            _production_input_reserve_shortfall = saturating_add(
                _production_input_reserve_shortfall,
                std::max<int64_t>(0, desired - reserved), _saturation_count);
        }
        }
    }
}

void NativeEconomyRuntime::build_demand_basis_cached(
        int32_t cell, int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count) {
        build_demand_basis(market, sample, variant_scores, variant_prices,
                           need_score_sums, need_composites, need_environment, sat);
        return;
    }
    const size_t variant_count = _variants.size();
    const size_t need_count = _needs.size();
    const size_t cells = static_cast<size_t>(_cell_count);
    if (_demand_basis_cache_day.size() != cells ||
        _demand_basis_variant_scores.size() != cells * variant_count ||
        _demand_basis_need_score_sums.size() != cells * need_count) {
        _demand_basis_cache_day.assign(
            cells, std::numeric_limits<int64_t>::min());
        _demand_basis_variant_scores.resize(cells * variant_count);
        _demand_basis_variant_prices.resize(cells * variant_count);
        _demand_basis_need_score_sums.resize(cells * need_count);
        _demand_basis_need_composites.resize(cells * need_count);
        _demand_basis_need_environment.resize(cells * need_count);
    }
    const size_t variant_offset = static_cast<size_t>(cell) * variant_count;
    const size_t need_offset = static_cast<size_t>(cell) * need_count;
    if (_demand_basis_cache_day[cell] != _sample_day) {
        build_demand_basis(market, sample, variant_scores, variant_prices,
                           need_score_sums, need_composites, need_environment, sat);
        std::copy(variant_scores.begin(), variant_scores.end(),
                  _demand_basis_variant_scores.begin() + variant_offset);
        std::copy(variant_prices.begin(), variant_prices.end(),
                  _demand_basis_variant_prices.begin() + variant_offset);
        std::copy(need_score_sums.begin(), need_score_sums.end(),
                  _demand_basis_need_score_sums.begin() + need_offset);
        std::copy(need_composites.begin(), need_composites.end(),
                  _demand_basis_need_composites.begin() + need_offset);
        std::copy(need_environment.begin(), need_environment.end(),
                  _demand_basis_need_environment.begin() + need_offset);
        _demand_basis_cache_day[cell] = _sample_day;
        return;
    }
    variant_scores.assign(
        _demand_basis_variant_scores.begin() + variant_offset,
        _demand_basis_variant_scores.begin() + variant_offset + variant_count);
    variant_prices.assign(
        _demand_basis_variant_prices.begin() + variant_offset,
        _demand_basis_variant_prices.begin() + variant_offset + variant_count);
    need_score_sums.assign(
        _demand_basis_need_score_sums.begin() + need_offset,
        _demand_basis_need_score_sums.begin() + need_offset + need_count);
    need_composites.assign(
        _demand_basis_need_composites.begin() + need_offset,
        _demand_basis_need_composites.begin() + need_offset + need_count);
    need_environment.assign(
        _demand_basis_need_environment.begin() + need_offset,
        _demand_basis_need_environment.begin() + need_offset + need_count);
}

void NativeEconomyRuntime::prepare_due_demand_basis_cache() {
    const int32_t cell_count = static_cast<int32_t>(_epoch_building_cells.size());
    if (cell_count <= 0) return;
    std::vector<int64_t> saturation_by_cell(static_cast<size_t>(cell_count), 0);
    const int32_t task_count = _worker_enabled &&
            cell_count >= _worker_market_threshold &&
            godot::WorkerThreadPool::get_singleton() != nullptr
        ? std::min<int32_t>(cell_count, _worker_tasks_hint > 0
            ? _worker_tasks_hint
            : std::clamp<int32_t>((cell_count + 127) / 128, 2, 16))
        : 1;
    auto prepare_range = [&](int32_t begin, int32_t end) {
        std::vector<int64_t> variant_scores;
        std::vector<int64_t> variant_prices;
        std::vector<int64_t> need_score_sums;
        std::vector<int64_t> need_composites;
        std::vector<int64_t> need_environment;
        for (int32_t index = begin; index < end; ++index) {
            const int32_t cell = _epoch_building_cells[index];
            const int32_t market = _market.cell_to_market[cell];
            int64_t local_saturation = 0;
            build_demand_basis(
                market, environment_sample_for_cell(cell), variant_scores,
                variant_prices, need_score_sums, need_composites,
                need_environment, local_saturation);
            const size_t variant_offset =
                static_cast<size_t>(cell) * _variants.size();
            const size_t need_offset =
                static_cast<size_t>(cell) * _needs.size();
            std::copy(variant_scores.begin(), variant_scores.end(),
                      _demand_basis_variant_scores.begin() + variant_offset);
            std::copy(variant_prices.begin(), variant_prices.end(),
                      _demand_basis_variant_prices.begin() + variant_offset);
            std::copy(need_score_sums.begin(), need_score_sums.end(),
                      _demand_basis_need_score_sums.begin() + need_offset);
            std::copy(need_composites.begin(), need_composites.end(),
                      _demand_basis_need_composites.begin() + need_offset);
            std::copy(need_environment.begin(), need_environment.end(),
                      _demand_basis_need_environment.begin() + need_offset);
            _demand_basis_cache_day[cell] = _sample_day;
            saturation_by_cell[index] = local_saturation;
        }
    };
    if (task_count > 1) {
        parallel_for_range("pk_economy_demand_basis", cell_count, task_count,
                           _worker_market_threshold, prepare_range);
    } else {
        prepare_range(0, cell_count);
    }
    for (const int64_t local_saturation : saturation_by_cell) {
        _saturation_count += local_saturation;
    }
}

void NativeEconomyRuntime::rebuild_labor_signals() {
    struct Saved {
        int32_t cell = -1;
        int32_t profession = -1;
        int64_t base_living = 0;
        int64_t role_living = 0;
        int64_t contract = 0;
        int64_t paid = 0;
        int64_t jobs = 0;
        int32_t ratio = Q16_ONE;
    };
    std::vector<Saved> saved;
    if (_labor_signals.cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            for (int32_t i = _labor_signals.cell_offsets[cell];
                 i < _labor_signals.cell_offsets[cell + 1]; ++i) {
                saved.push_back({cell, _labor_signals.profession_ids[i],
                    _labor_signals.base_living_cost[i],
                    _labor_signals.role_living_cost[i],
                    _labor_signals.contract_wage_ema[i],
                    _labor_signals.paid_wage_ema[i],
                    _labor_signals.job_days[i],
                    _labor_signals.pay_ratio_q16[i]});
            }
        }
    }
    std::vector<std::pair<int32_t, int32_t>> keys;
    for (const BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            keys.emplace_back(group.cell,
                _building_employee_roles[type.employee_begin + r].profession_id);
        }
    }
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    _labor_signals.clear(_cell_count);
    const size_t n = keys.size();
    _labor_signals.profession_ids.reserve(n);
    _labor_signals.base_living_cost.assign(n, 0);
    _labor_signals.role_living_cost.assign(n, 0);
    _labor_signals.contract_wage_ema.assign(n, 0);
    _labor_signals.paid_wage_ema.assign(n, 0);
    _labor_signals.job_days.assign(n, 0);
    _labor_signals.pay_ratio_q16.assign(n, Q16_ONE);
    for (const auto &key : keys) ++_labor_signals.cell_offsets[key.first + 1];
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _labor_signals.cell_offsets[cell + 1] += _labor_signals.cell_offsets[cell];
    size_t old = 0;
    for (size_t i = 0; i < keys.size(); ++i) {
        _labor_signals.profession_ids.push_back(keys[i].second);
        while (old < saved.size() &&
               std::pair(saved[old].cell, saved[old].profession) < keys[i]) ++old;
        if (old < saved.size() && saved[old].cell == keys[i].first &&
            saved[old].profession == keys[i].second) {
            _labor_signals.base_living_cost[i] = saved[old].base_living;
            _labor_signals.role_living_cost[i] = saved[old].role_living;
            _labor_signals.contract_wage_ema[i] = saved[old].contract;
            _labor_signals.paid_wage_ema[i] = saved[old].paid;
            _labor_signals.job_days[i] = saved[old].jobs;
            _labor_signals.pay_ratio_q16[i] = saved[old].ratio;
        }
    }
}

int32_t NativeEconomyRuntime::labor_signal_index(int32_t cell, int32_t profession) const {
    if (cell < 0 || cell >= _cell_count ||
        _labor_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return -1;
    const int32_t begin = _labor_signals.cell_offsets[cell];
    const int32_t end = _labor_signals.cell_offsets[cell + 1];
    const auto first = _labor_signals.profession_ids.begin() + begin;
    const auto last = _labor_signals.profession_ids.begin() + end;
    const auto it = std::lower_bound(first, last, profession);
    return it != last && *it == profession
        ? static_cast<int32_t>(it - _labor_signals.profession_ids.begin()) : -1;
}

int64_t NativeEconomyRuntime::living_cost_for_signature(
        int32_t cell, int32_t signature_id, int32_t plan_override, int64_t &sat) const {
    if (cell < 0 || cell >= _cell_count || signature_id < 0 ||
        signature_id >= static_cast<int32_t>(_signatures.size())) return 0;
    const Signature &signature = _signatures[signature_id];
    const int32_t plan_id = plan_override >= 0 ? plan_override : signature.plan_id;
    if (plan_id < 0 || plan_id >= static_cast<int32_t>(_plans.size())) return 0;
    const int32_t market = _market.cell_to_market[cell];
    const Plan &plan = _plans[plan_id];
    int64_t total = 0;
    for (int32_t n = 0; n < plan.need_count; ++n) {
        const int32_t need_index = plan.need_begin + n;
        const Need &need = _needs[need_index];
        if (need.living_cost_weight_q16 <= 0) continue;
        int64_t score_sum = 0;
        int64_t weighted_price = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            const int64_t unit_price = variant_unit_price(market, variant_id, sat);
            const int64_t price_ratio = mul_div_sat(
                variant.reference_unit_price, Q16_ONE, unit_price, sat);
            int64_t score = mul_div_sat(
                variant.preference_q16,
                pow_q16(std::max<int64_t>(1, price_ratio),
                        variant.price_elasticity_q16, sat), Q16_ONE, sat);
            score = mul_div_sat(score,
                sample_environment_curve(variant.preference_env_curve, cell),
                Q16_ONE, sat);
            score = std::max<int64_t>(0, score);
            score_sum = saturating_add(score_sum, score, sat);
            weighted_price = saturating_add(weighted_price,
                saturating_mul(unit_price, score, sat), sat);
        }
        int64_t quantity = saturating_mul(
            need.base_qty_per_person, need.living_cost_weight_q16, sat) >> 16;
        quantity = saturating_mul(quantity,
            sample_environment_curve(need.quantity_env_curve, cell), sat) >> 16;
        const int32_t factor_index = signature.ethnicity_id *
            static_cast<int32_t>(_need_ids.size()) + need.stable_id;
        quantity = saturating_mul(quantity,
            _ethnicity_need_factor_q16[factor_index], sat) >> 16;
        if (quantity <= 0 || score_sum <= 0) continue;
        weighted_price /= score_sum;
        total = saturating_add(total, mul_div_sat(
            quantity, weighted_price, GOODS_SCALE, sat), sat);
    }
    return std::max<int64_t>(0, total);
}

void NativeEconomyRuntime::compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count ||
        _labor_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1) ||
        _labor_signals.cell_offsets[cell] == _labor_signals.cell_offsets[cell + 1]) return;
    const int32_t ethnicity_count = static_cast<int32_t>(_ethnicity_ids.size());
    thread_local std::vector<int64_t> cache;
    thread_local std::vector<int32_t> cached_prices;
    thread_local int64_t cached_catalog_hash = 0;
    thread_local int32_t cached_temperature = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_moisture = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_snow = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_weather = std::numeric_limits<int32_t>::min();
    thread_local uint64_t cached_stock_presence = 0;
    const int32_t market = _market.cell_to_market[cell];
    const auto price_begin = _market.price.begin() +
        static_cast<int64_t>(market) * _market.good_count;
    const auto stock_begin = _market.stock.begin() +
        static_cast<int64_t>(market) * _market.good_count;
    // Living cost now depends on which goods are purchasable (stock > 0), so the
    // cache must invalidate when the in-stock set changes even if prices did not.
    // We only need the sign of each stock (a good's exact quantity does not move
    // living cost), so hash a purchasable-bitset rather than snapshotting stock.
    uint64_t stock_presence = 1469598103934665603ULL; // FNV-1a offset basis
    for (int32_t g = 0; g < _market.good_count; ++g) {
        const uint64_t bit = (*(stock_begin + g) > 0) ? 1ULL : 0ULL;
        stock_presence = (stock_presence ^ bit) * 1099511628211ULL;
    }
    const bool same_basis =
        cached_prices.size() == static_cast<size_t>(_market.good_count) &&
        cached_catalog_hash == _catalog_hash &&
        cached_temperature == _environment_temperature_q16[cell] &&
        cached_moisture == _environment_moisture_q16[cell] &&
        cached_snow == _environment_snow_q16[cell] &&
        cached_weather == _environment_weather_q16[cell] &&
        cached_stock_presence == stock_presence &&
        std::equal(cached_prices.begin(), cached_prices.end(), price_begin);
    if (!same_basis) {
        cached_prices.assign(price_begin, price_begin + _market.good_count);
        cached_catalog_hash = _catalog_hash;
        cached_temperature = _environment_temperature_q16[cell];
        cached_moisture = _environment_moisture_q16[cell];
        cached_snow = _environment_snow_q16[cell];
        cached_weather = _environment_weather_q16[cell];
        cached_stock_presence = stock_presence;
        cache.assign(_plans.size() * _ethnicity_ids.size(), -1);
    }
    auto cost = [&](int32_t signature_id, int32_t plan_override) {
        const Signature &signature = _signatures[signature_id];
        const int32_t plan_id = plan_override >= 0 ? plan_override : signature.plan_id;
        const size_t key = static_cast<size_t>(plan_id) * ethnicity_count +
                           signature.ethnicity_id;
        if (cache[key] >= 0) return cache[key];
        int64_t total = 0;
        const Plan &plan = _plans[plan_id];
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            const int64_t score_sum = need_score_sums[need_index];
            if (need.living_cost_weight_q16 <= 0 || score_sum <= 0) continue;
            // Living cost must reflect what a rational consumer would actually
            // pay to satisfy this need, not the average of every listed variant.
            // A variant whose components are out of stock (or a variant that has
            // spiked to a ceiling nobody trades at) is not a real option: the
            // consumer substitutes to a cheaper variant that is in stock (e.g.
            // gathered_plants / game_meat). We therefore aggregate ONLY over
            // in-stock variants, score-weighted for preference among the real
            // options, and clamp the result to a slack multiple of the cheapest
            // in-stock variant so a mid-priced substitute cannot inflate cost.
            int64_t avail_num = 0;      // Sum(price * score) over in-stock variants
            int64_t avail_score = 0;    // Sum(score) over in-stock variants
            int64_t avail_ref_num = 0;  // Sum(reference_price * score) over in-stock
            int64_t min_avail_price = 0; // Cheapest in-stock variant unit price
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant = need.variant_begin + v;
                // A variant is purchasable only if every component good has stock.
                const VariantChoice &vc = _variants[variant];
                bool in_stock = vc.component_count > 0;
                for (int32_t c = 0; c < vc.component_count; ++c) {
                    const NeedComponent &comp = _components[vc.component_begin + c];
                    if (_market.stock[_market.index(market, comp.good_id)] <= 0) {
                        in_stock = false;
                        break;
                    }
                }
                if (!in_stock) continue;
                const int64_t vp = variant_prices[variant];
                const int64_t vs = variant_scores[variant];
                avail_num = saturating_add(avail_num,
                    saturating_mul(vp, vs, sat), sat);
                avail_score = saturating_add(avail_score, vs, sat);
                avail_ref_num = saturating_add(avail_ref_num,
                    saturating_mul(vc.reference_unit_price, vs, sat), sat);
                if (min_avail_price == 0 || vp < min_avail_price) {
                    min_avail_price = vp;
                }
            }
            if (avail_score <= 0) {
                // Every variant of this need is out of stock: the consumer cannot
                // spend anything on it, so it contributes nothing to living cost.
                // (Wage floors should only cover goods people can actually buy;
                // an unpurchasable need does not create a real cost of living, and
                // its ghost/ceiling listing prices must not pollute the aggregate.
                // Genuine survival pressure comes from staple_food/protein having
                // no cheap in-stock substitute, which those needs handle directly.)
                continue;
            }
            int64_t weighted_price = avail_num / avail_score;
            // Clamp to 1.5x the cheapest in-stock option: consumers will not
            // pay far above the cheapest viable substitute they can actually buy.
            const int64_t price_cap = saturating_mul(
                min_avail_price, 98304 /* 1.5 in Q16 */, sat) >> 16;
            if (price_cap > 0 && weighted_price > price_cap) {
                weighted_price = price_cap;
            }
            // Essentialness cap: even if every in-stock variant is expensive, a
            // NON-essential need must not manufacture society-wide inflation. Only
            // the essential portion of a price rise feeds living cost (and thus the
            // wage floor). Essentialness is read from the need's demand floor
            // (price_quantity_floor_q16): a high floor means demand stays high even
            // when prices soar (a true necessity like staple grain, which should
            // track market price fully), while a zero floor means demand collapses
            // to nothing when prices rise (a discretionary need like protein/produce
            // with substitutes -- consumers simply stop buying, so it must not lift
            // the cost of living). floor is in [0, 0.5]; scale by 2 so a 0.5 floor
            // maps to full pass-through and 0 maps to no pass-through.
            // A free "buffer band" up to 1.5x the reference price passes through
            // unclamped: a mild price rise is normal and should be reflected even
            // for discretionary needs ("a little more expensive is fine"). Only
            // the portion ABOVE that band is throttled by essentialness, so a
            // runaway spike ("it soared, so I just stop buying") cannot inflate
            // the cost of living for a non-essential need.
            const int64_t ref_price = avail_ref_num / avail_score;
            const int64_t buffer_threshold =
                saturating_mul(ref_price, 98304 /* 1.5 in Q16 */, sat) >> 16;
            if (weighted_price > buffer_threshold && buffer_threshold > 0) {
                int64_t essential_q16 = saturating_mul(
                    need.price_quantity_floor_q16, 2, sat);
                if (essential_q16 > Q16_ONE) essential_q16 = Q16_ONE;
                if (essential_q16 < 0) essential_q16 = 0;
                const int64_t excess = weighted_price - buffer_threshold;
                const int64_t allowed_excess =
                    saturating_mul(excess, essential_q16, sat) >> 16;
                weighted_price = saturating_add(buffer_threshold, allowed_excess, sat);
            }
            int64_t quantity = saturating_mul(
                need.base_qty_per_person, need.living_cost_weight_q16, sat) >> 16;
            quantity = saturating_mul(
                quantity, need_environment[need_index], sat) >> 16;
            const int32_t factor = signature.ethnicity_id *
                static_cast<int32_t>(_need_ids.size()) + need.stable_id;
            quantity = saturating_mul(
                quantity, _ethnicity_need_factor_q16[factor], sat) >> 16;
            total = saturating_add(total, mul_div_sat(
                quantity, weighted_price, GOODS_SCALE, sat), sat);
        }
        cache[key] = std::max<int64_t>(0, total);
        return cache[key];
    };
    int64_t population_total = 0;
    int64_t general_weighted = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t population = std::max<int64_t>(0, _population.population[slot]);
        if (population <= 0) return;
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        population_total = saturating_add(population_total, population, sat);
        general_weighted = saturating_add(general_weighted, saturating_mul(
            cost(signature, _living_cost_base_plan_id), population, sat), sat);
    });
    const int64_t general = population_total > 0
        ? general_weighted / population_total : 0;
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        int64_t employed = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            if (_signatures[signature].profession_id == profession)
                employed = saturating_add(employed,
                    std::max<int64_t>(0, _population.employee_employed[slot]), sat);
        });
        int64_t weight_total = 0;
        int64_t weighted = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            if (_signatures[signature].profession_id != profession) return;
            const int64_t weight = employed > 0
                ? std::max<int64_t>(0, _population.employee_employed[slot])
                : std::max<int64_t>(0, _population.population[slot]);
            if (weight <= 0) return;
            weight_total = saturating_add(weight_total, weight, sat);
            weighted = saturating_add(weighted,
                saturating_mul(cost(signature, -1), weight, sat), sat);
        });
        _labor_signals.base_living_cost[signal] = general;
        _labor_signals.role_living_cost[signal] =
            weight_total > 0 ? weighted / weight_total : 0;
    }
}

bool NativeEconomyRuntime::prepare_cell_wages(int32_t cell, std::string &error) {
    const auto started = Clock::now();
    const int32_t begin = _building_cell_offsets[cell];
    const int32_t end = _building_cell_offsets[cell + 1];
    if (begin >= end) return true;
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        const int64_t general_cost = _labor_signals.base_living_cost[signal];
        int64_t role_cost = _labor_signals.role_living_cost[signal];
        int64_t reference_total = 0;
        int64_t reference_weight = 0;
        for (int32_t g = begin; g < end; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (!building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int64_t slots = saturating_mul(
                    group.count, role.slots_per_building, _saturation_count);
                reference_total = saturating_add(reference_total,
                    saturating_mul(slots, role.reference_wage_per_day,
                                   _saturation_count), _saturation_count);
                reference_weight = saturating_add(reference_weight, slots,
                                                  _saturation_count);
            }
        }
        const int64_t reference = reference_weight > 0
            ? reference_total / reference_weight : 0;
        if (role_cost == 0) role_cost = std::max(general_cost, reference);
        const int64_t local_average = _labor_signals.contract_wage_ema[signal] > 0
            ? _labor_signals.contract_wage_ema[signal] : reference;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (!building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            // Affordability damping is a daily-flow calculation. Historical
            // last_expected_revenue is an epoch total, so comparing it directly
            // with a per-day wage lets contract wages grow by roughly epoch_days.
            // Quote the current full-capacity daily output instead, reserve daily
            // inputs plus the configured operating margin, then divide the
            // remaining wage pool across all employee slots. This also gives a
            // suspended building a stable recovery quote instead of a zero basis.
            int64_t affordable_ceiling = 0;
            if (_wage_income_cap_ratio_q16 > 0) {
                int64_t group_employee_slots = 0;
                for (int32_t rr = 0; rr < type.employee_count; ++rr) {
                    const JobRole &rrole =
                        _building_employee_roles[type.employee_begin + rr];
                    group_employee_slots = saturating_add(group_employee_slots,
                        saturating_mul(group.count, rrole.slots_per_building,
                                       _saturation_count), _saturation_count);
                }
                const int32_t market = _market.cell_to_market[cell];
                int64_t daily_revenue_per_building = 0;
                for (int32_t output_index = 0;
                     output_index < type.output_count; ++output_index) {
                    const GoodAmount &output =
                        _building_outputs[type.output_begin + output_index];
                    int64_t settlement = _good_monetary_issue_values[output.good_id];
                    if (settlement <= 0) {
                        const int32_t output_signal = market_signal_index(
                            cell, output.good_id);
                        const int32_t output_flow = trade_flow_index(
                            cell, output.good_id, false);
                        const int64_t output_target = merchant_inventory_target(
                            market, output.good_id, output_signal,
                            output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                                output_signal] : 0,
                            output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                            output.quantity, _saturation_count);
                        const int32_t buy_factor = effective_merchant_buy_factor_q16(
                            market, output.good_id, output_target,
                            _market.stock[_market.index(market, output.good_id)],
                            _saturation_count);
                        settlement = mul_div_sat(
                            _market.price[_market.index(market, output.good_id)],
                            buy_factor, Q16_ONE, _saturation_count);
                    }
                    daily_revenue_per_building = saturating_add(
                        daily_revenue_per_building, mul_div_sat(
                            output.quantity, settlement, GOODS_SCALE,
                            _saturation_count), _saturation_count);
                }
                if (daily_revenue_per_building > 0 && group_employee_slots > 0) {
                    const int64_t daily_revenue = saturating_mul(
                        daily_revenue_per_building, group.count, _saturation_count);
                    const int64_t margin_denominator = saturating_add(
                        Q16_ONE, std::max<int32_t>(0,
                            type.target_operating_margin_q16), _saturation_count);
                    const int64_t operating_budget = mul_div_sat(
                        daily_revenue, Q16_ONE,
                        std::max<int64_t>(1, margin_denominator),
                        _saturation_count);
                    const int64_t daily_inputs = saturating_mul(
                        std::max<int64_t>(0, group.sample_unit_input_cost),
                        group.count, _saturation_count);
                    const int64_t daily_wage_pool = std::max<int64_t>(
                        0, saturating_sub(operating_budget, daily_inputs,
                                          _saturation_count));
                    const int64_t sustainable_per_employee =
                        daily_wage_pool / group_employee_slots;
                    affordable_ceiling = mul_div_sat(sustainable_per_employee,
                        _wage_income_cap_ratio_q16, Q16_ONE, _saturation_count);
                }
            }
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int32_t index = group.employee_fill_begin + r;
                int64_t floor = std::max(general_cost, role_cost);
                // Clamp the living-cost floor to the employer's ability to pay,
                // but never below the configured reference wage (so a viable
                // building still offers at least its nominal wage).
                if (affordable_ceiling > 0) {
                    const int64_t floor_cap = std::max(
                        role.reference_wage_per_day, affordable_ceiling);
                    floor = std::min(floor, floor_cap);
                }
                int64_t current = _building_role_contract_wage[index] > 0
                    ? _building_role_contract_wage[index] : role.reference_wage_per_day;
                int64_t next = role.reference_wage_per_day;
                if (role.wage_policy == 2) {
                    int64_t desired = std::max(floor, local_average);
                    // Damping also caps the target the wage chases toward, so an
                    // inflated local-average signal cannot drag wages past the
                    // employer's affordability either.
                    if (affordable_ceiling > 0) {
                        const int64_t desired_cap = std::max(
                            role.reference_wage_per_day, affordable_ceiling);
                        desired = std::min(desired, desired_cap);
                    }
                    if (desired > current) {
                        const int64_t cap = std::max<int64_t>(1, mul_div_sat(
                            current, saturating_mul(_wage_max_rise_q16_per_day,
                                                    std::max(1, _epoch_days),
                                                    _saturation_count),
                            Q16_ONE, _saturation_count));
                        next = std::min(desired, saturating_add(
                            current, cap, _saturation_count));
                    } else {
                        const int64_t cap = mul_div_sat(
                            current, saturating_mul(_wage_max_fall_q16_per_day,
                                                    std::max(1, _epoch_days),
                                                    _saturation_count),
                            Q16_ONE, _saturation_count);
                        next = std::max(desired, saturating_sub(
                            current, cap, _saturation_count));
                    }
                    next = std::max(next, floor);
                } else if (role.wage_policy == 1) {
                    next = role.reference_wage_per_day;
                } else {
                    next = 0;
                }
                _building_role_contract_wage[index] = next;
                _building_role_base_living_cost[index] = general_cost;
                _building_role_living_cost[index] = role_cost;
                _building_role_local_average_wage[index] = local_average;
            }
        }
    }
    _wage_plan_ms += elapsed_ms(started);
    return error.empty();
}

void NativeEconomyRuntime::update_cell_labor_signals(int32_t cell) {
    const auto started = Clock::now();
    const int64_t alpha = std::min<int64_t>(
        Q16_ONE, saturating_mul(_wage_ema_alpha_q16,
                                std::max(1, _epoch_days), _saturation_count));
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        int64_t jobs = 0;
        int64_t due = 0;
        int64_t paid = 0;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int32_t index = group.employee_fill_begin + r;
                jobs = saturating_add(jobs, saturating_mul(
                    _building_employee_filled[index], std::max(1, _epoch_days),
                    _saturation_count), _saturation_count);
                due = saturating_add(due, _building_role_base_wage_due[index],
                                     _saturation_count);
                paid = saturating_add(paid, _building_role_base_wage_paid[index],
                                      _saturation_count);
            }
        }
        if (jobs > 0) {
            const int64_t observed_contract = due / jobs;
            const int64_t observed_paid = paid / jobs;
            auto ema = [&](int64_t previous, int64_t observed) {
                if (previous <= 0) return observed;
                return saturating_add(previous, mul_div_sat(
                    saturating_sub(observed, previous, _saturation_count),
                    alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
            };
            _labor_signals.contract_wage_ema[signal] =
                ema(_labor_signals.contract_wage_ema[signal], observed_contract);
            _labor_signals.paid_wage_ema[signal] =
                ema(_labor_signals.paid_wage_ema[signal], observed_paid);
            _labor_signals.job_days[signal] = jobs;
            _labor_signals.pay_ratio_q16[signal] = static_cast<int32_t>(
                std::clamp<int64_t>(mul_div_sat(paid, Q16_ONE,
                    std::max<int64_t>(1, due), _saturation_count), 0, Q16_ONE));
            ++_labor_signal_updates;
        }
    }
    _labor_signal_ms += elapsed_ms(started);
}

bool NativeEconomyRuntime::prepare_building_economic_plan(
        int32_t active_begin, int32_t active_end, std::string &error) {
    constexpr int64_t DISCARD_RATE_TOLERANCE_Q16 = Q16_ONE / 100;
    constexpr int64_t HIGH_DISCARD_RATE_Q16 = Q16_ONE / 4;
    constexpr int64_t SEVERE_DISCARD_RATE_Q16 = Q16_ONE / 2;
    constexpr int64_t SHORTAGE_RECOVERY_THRESHOLD_Q16 = Q16_ONE / 8;
    constexpr int64_t STOCK_ROUNDING_TOLERANCE = 1;
    // 同一业主的生存食物产能合并计算，只保护跨过饥饿阈值所需的最低利用率。
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    active_begin = std::clamp<int32_t>(
        active_begin, 0, static_cast<int32_t>(active_cells.size()));
    active_end = std::clamp<int32_t>(
        active_end, active_begin, static_cast<int32_t>(active_cells.size()));
    thread_local std::vector<int32_t> owner_seen_cell;
    thread_local std::vector<uint8_t> owner_output_flags;
    thread_local std::vector<int64_t> owner_relevant_output;
    thread_local std::vector<int64_t> owner_floor_q16;
    thread_local std::vector<int64_t> owner_clothing_output;
    thread_local std::vector<int64_t> owner_clothing_floor_q16;
    thread_local std::vector<int32_t> touched_owners;
    owner_seen_cell.assign(_signatures.size(), -1);
    owner_output_flags.resize(_signatures.size());
    owner_relevant_output.resize(_signatures.size());
    owner_floor_q16.resize(_signatures.size());
    owner_clothing_output.resize(_signatures.size());
    owner_clothing_floor_q16.resize(_signatures.size());
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t active = active_begin; active < active_end; ++active) {
            const int32_t cell = active_cells[active];
            const int32_t begin = _building_cell_offsets[cell];
            const int32_t end = _building_cell_offsets[cell + 1];
            touched_owners.clear();
            for (int32_t g = begin; g < end; ++g) {
                const BuildingGroup &group = _buildings[g];
                if (group.count <= 0 || group.operating_state != 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                if (group.owner_signature_id < 0 || group.owner_signature_id >=
                        static_cast<int32_t>(owner_seen_cell.size())) continue;
                const int32_t owner = group.owner_signature_id;
                if (owner_seen_cell[owner] != cell) {
                    owner_seen_cell[owner] = cell;
                    owner_output_flags[owner] = 0;
                    owner_relevant_output[owner] = 0;
                    owner_floor_q16[owner] = 0;
                    owner_clothing_output[owner] = 0;
                    owner_clothing_floor_q16[owner] = 0;
                    touched_owners.push_back(owner);
                }
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[type.output_begin + i].good_id;
                    if (_survival_food_good_mask[good] != 0)
                        owner_output_flags[owner] |= 1;
                    if (_survival_staple_good_mask[good] != 0)
                        owner_output_flags[owner] |= 2;
                    if (_survival_clothing_good_mask[good] != 0)
                        owner_output_flags[owner] |= 4;
                }
            }
            for (int32_t g = begin; g < end; ++g) {
                const BuildingGroup &group = _buildings[g];
                if (group.count <= 0 || group.operating_state != 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                const int32_t owner = group.owner_signature_id;
                if (owner < 0 || owner >= static_cast<int32_t>(owner_seen_cell.size()) ||
                    owner_seen_cell[owner] != cell || (owner_output_flags[owner] & 5) == 0)
                    continue;
                const bool staple_route = (owner_output_flags[owner] & 2) != 0;
                const BuildingType &type = _building_types[group.type_id];
                int64_t group_relevant_output = 0;
                int64_t group_clothing_output = 0;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const bool relevant = staple_route
                        ? _survival_staple_good_mask[output.good_id] != 0
                        : _survival_food_good_mask[output.good_id] != 0;
                    const int64_t full_output = saturating_mul(
                        saturating_mul(group.count, std::max(1, _epoch_days),
                                       _saturation_count),
                        output.quantity, _saturation_count);
                    if (relevant) group_relevant_output = saturating_add(
                        group_relevant_output, full_output, _saturation_count);
                    if (_survival_clothing_good_mask[output.good_id] != 0)
                        group_clothing_output = saturating_add(
                            group_clothing_output, full_output, _saturation_count);
                }
                if (group_relevant_output > 0) {
                    owner_relevant_output[owner] = saturating_add(
                        owner_relevant_output[owner], group_relevant_output,
                        _saturation_count);
                }
                if (group_clothing_output > 0) {
                    owner_clothing_output[owner] = saturating_add(
                        owner_clothing_output[owner], group_clothing_output,
                        _saturation_count);
                }
            }
            const EnvironmentSample environment = environment_sample_for_cell(cell);
            for (const int32_t owner : touched_owners) {
                const int64_t full_relevant_output = owner_relevant_output[owner];
                if ((owner_output_flags[owner] & 1) == 0 || full_relevant_output <= 0)
                    continue;
                const int32_t owner_slot = find_cohort_slot(
                    cell, owner);
                if (owner_slot < 0 || _population.population[owner_slot] <= 0) continue;
                int64_t required_food = 0;
                for (int32_t stable_need : _survival_food_need_stable_ids) {
                    required_food = saturating_add(required_food,
                        survival_required_units(owner_slot, stable_need,
                            _epoch_days, environment, _saturation_count),
                        _saturation_count);
                }
                const int64_t protected_food = saturating_add(saturating_mul(
                    required_food, _survival_production_target_q16,
                    _saturation_count), Q16_ONE - 1, _saturation_count) / Q16_ONE;
                const int64_t floor_q16 = std::clamp<int64_t>(
                    saturating_add(saturating_mul(protected_food, Q16_ONE,
                        _saturation_count), full_relevant_output - 1,
                        _saturation_count) / full_relevant_output,
                    0, Q16_ONE);
                owner_floor_q16[owner] = floor_q16;
                const int64_t full_clothing_output = owner_clothing_output[owner];
                if ((owner_output_flags[owner] & 4) != 0 && full_clothing_output > 0) {
                    const int64_t required_clothing = survival_required_units(
                        owner_slot, _survival_clothing_need_stable_id,
                        _epoch_days, environment, _saturation_count);
                    owner_clothing_floor_q16[owner] = std::clamp<int64_t>(
                        saturating_add(saturating_mul(required_clothing, Q16_ONE,
                            _saturation_count), full_clothing_output - 1,
                            _saturation_count) / full_clothing_output,
                        0, Q16_ONE);
                }
            }
            for (int32_t g = begin; g < end; ++g) {
                const BuildingGroup &group = _buildings[g];
                const int32_t owner = group.owner_signature_id;
                if (group.count <= 0 || group.operating_state != 0 ||
                    owner < 0 || owner >= static_cast<int32_t>(owner_seen_cell.size()) ||
                    owner_seen_cell[owner] != cell || owner_floor_q16[owner] <= 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                const bool staple_route = (owner_output_flags[owner] & 2) != 0;
                const BuildingType &type = _building_types[group.type_id];
                int64_t group_floor_q16 = 0;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[type.output_begin + i].good_id;
                    if (staple_route ? _survival_staple_good_mask[good] != 0
                                     : _survival_food_good_mask[good] != 0) {
                        group_floor_q16 = std::max(
                            group_floor_q16, owner_floor_q16[owner]);
                    }
                    if (_survival_clothing_good_mask[good] != 0)
                        group_floor_q16 = std::max(
                            group_floor_q16, owner_clothing_floor_q16[owner]);
                }
                _building_survival_utilization_floor_q16[g] = group_floor_q16;
            }
        }
    }
    for (int32_t active = active_begin; active < active_end; ++active) {
        const int32_t cell = active_cells[active];
        const int32_t group_begin = _building_cell_offsets[cell];
        const int32_t group_end = _building_cell_offsets[cell + 1];
        for (int32_t group_index = group_begin; group_index < group_end; ++group_index) {
        BuildingGroup &group = _buildings[group_index];
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size())) {
            error = "building_economic_plan_group_invalid";
            return false;
        }
        const BuildingType &type = _building_types[group.type_id];
        if (!building_available(group.cell, group.type_id, true)) {
            group.sample_unit_input_cost = 0;
            group.last_margin_gap_q16 = 0;
            group.planned_utilization_q16 = 0;
            group.purchase_intent_capacity_q16 = 0;
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
        const int32_t market = _market.cell_to_market[group.cell];
        int64_t input_cost = 0;
        int64_t employee_wages = 0;
        const int64_t owner_living_cost = saturating_mul(
            living_cost_for_signature(group.cell, group.owner_signature_id, -1,
                                      _saturation_count),
            type.owner_slots_per_building, _saturation_count);
        int64_t revenue = 0;
        bool inputs_available = true;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            for (int32_t c = item.candidate_begin;
                 c < item.candidate_begin + item.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_available(group.cell, candidate.good_id, true)) continue;
                const int64_t effective_price = mul_div_sat(
                    _market.price[_market.index(market, candidate.good_id)], Q16_ONE,
                    candidate.efficiency_q16, _saturation_count);
                best_effective_price = std::min(best_effective_price, effective_price);
            }
            if (best_effective_price == std::numeric_limits<int64_t>::max()) {
                if (item.required_q16 >= Q16_ONE) {
                    inputs_available = false;
                    break;
                }
                continue;
            }
            input_cost = saturating_add(input_cost, mul_div_sat(
                item.quantity, best_effective_price, GOODS_SCALE,
                _saturation_count), _saturation_count);
        }
        if (!inputs_available) {
            group.sample_unit_input_cost = 0;
            group.last_margin_gap_q16 = -Q16_ONE;
            group.planned_utilization_q16 = 0;
            group.purchase_intent_capacity_q16 = 0;
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage = role_index >= 0 &&
                role_index < static_cast<int32_t>(_building_role_contract_wage.size())
                    ? _building_role_contract_wage[role_index]
                    : role.reference_wage_per_day;
            employee_wages = saturating_add(employee_wages, saturating_mul(
                role.slots_per_building, wage,
                _saturation_count), _saturation_count);
        }
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            int64_t settlement = _good_monetary_issue_values[item.good_id];
            if (settlement <= 0) {
                const int32_t output_signal = market_signal_index(
                    group.cell, item.good_id);
                const int32_t output_flow = trade_flow_index(
                    group.cell, item.good_id, false);
                const int64_t output_target = merchant_inventory_target(
                    market, item.good_id, output_signal,
                    output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                        output_signal] : 0,
                    output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                    item.quantity, _saturation_count);
                const int32_t buy_factor = effective_merchant_buy_factor_q16(
                    market, item.good_id, output_target,
                    _market.stock[_market.index(market, item.good_id)],
                    _saturation_count);
                settlement = mul_div_sat(
                    _market.price[_market.index(market, item.good_id)],
                    buy_factor, Q16_ONE, _saturation_count);
            }
            revenue = saturating_add(revenue, mul_div_sat(
                item.quantity, settlement, GOODS_SCALE, _saturation_count),
                _saturation_count);
        }
        const int64_t operating = saturating_add(saturating_add(
            input_cost, employee_wages, _saturation_count),
            owner_living_cost, _saturation_count);
        const int64_t required = saturating_add(operating, mul_div_sat(
            operating, type.target_operating_margin_q16, Q16_ONE,
            _saturation_count), _saturation_count);
        int64_t margin_gap = required <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, required, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, required), _saturation_count);
        margin_gap = std::clamp<int64_t>(margin_gap, -Q16_ONE, Q16_ONE);
        int64_t expected_profit_margin = operating <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, operating, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, operating), _saturation_count);
        expected_profit_margin = std::clamp<int64_t>(
            expected_profit_margin, -Q16_ONE, Q16_ONE);
        group.sample_unit_input_cost = input_cost;
        group.last_margin_gap_q16 = static_cast<int32_t>(margin_gap);
        bool suspended_now = false;
        if (group.operating_state == 0) {
            if (group.last_operating_cost > 0 &&
                group.realized_profit_margin_q16 <= _building_severe_loss_threshold_q16) {
                group.severe_loss_cycles = static_cast<uint16_t>(std::min<int32_t>(
                    65535, static_cast<int32_t>(group.severe_loss_cycles) + 1));
            } else {
                group.severe_loss_cycles = 0;
            }
            if (group.severe_loss_cycles >= _building_severe_loss_cycles) {
                group.operating_state = 1;
                group.recovery_cycles = 0;
                suspended_now = true;
            }
        }
        if (group.operating_state != 0 && !suspended_now) {
            const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
            const int64_t restart_cost = saturating_mul(
                operating, std::max(1, _epoch_days), _saturation_count);
            const bool affordable = owner_slot >= 0 &&
                _population.funds[owner_slot] >= restart_cost;
            if (expected_profit_margin >= _building_restart_margin_q16 && affordable) {
                group.recovery_cycles = static_cast<uint16_t>(std::min<int32_t>(
                    65535, static_cast<int32_t>(group.recovery_cycles) + 1));
            } else {
                group.recovery_cycles = 0;
            }
            if (group.recovery_cycles >= _building_restart_cycles) {
                group.operating_state = 0;
                group.severe_loss_cycles = 0;
                group.recovery_cycles = 0;
            }
        }
        if (group.operating_state == 0) {
            int64_t utilization = group.planned_utilization_q16 > 0
                ? group.planned_utilization_q16 : Q16_ONE;
            bool produces_cycle_flow = false;
            bool produces_survival_food = false;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                if (_good_storage_modes[good] == 1) {
                    produces_cycle_flow = true;
                }
                produces_survival_food = produces_survival_food ||
                    _survival_food_good_mask[good] != 0;
            }
            const int64_t sellable_output = saturating_add(
                group.last_sold, group.last_discarded, _saturation_count);
            bool shortage_recovery = false;
            bool inventory_surplus = false;
            int64_t inventory_absorption_q16 = Q16_ONE;
            int64_t output_demand_ema = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t market_index = _market.index(market, good);
                const int32_t signal = market_signal_index(group.cell, good);
                const int64_t household_demand = _market.demand_ema[market_index];
                const int64_t business_demand = signal >= 0
                    ? _market_signals.business_demand_ema[signal] : 0;
                const int64_t total_demand = saturating_add(
                    household_demand, business_demand, _saturation_count);
                output_demand_ema = saturating_add(
                    output_demand_ema, total_demand, _saturation_count);
                const int64_t input_reserve = signal >= 0 && signal <
                        static_cast<int32_t>(_production_input_reserve.size())
                    ? _production_input_reserve[signal] : 0;
                const int64_t household_available_stock = std::max<int64_t>(
                    0, _market.stock[market_index] - input_reserve);
                const int64_t realized = signal >= 0
                    ? _market_signals.realized_withdrawal_ema[signal] : 0;
                const int64_t daily_absorption = std::max<int64_t>(
                    realized, total_demand);
                const int64_t recovery_stock_limit = std::max<int64_t>(
                    GOODS_SCALE, saturating_mul(
                        daily_absorption, std::max(1, _epoch_days),
                        _saturation_count));
                const int64_t total_shortage_q16 = total_demand <= 0 ? 0
                    : std::clamp<int64_t>(Q16_ONE - mul_div_sat(
                        realized, Q16_ONE, total_demand, _saturation_count),
                        0, Q16_ONE);
                if (household_available_stock <= recovery_stock_limit &&
                    std::max<int64_t>(_market.last_shortage_q16[market_index],
                                      total_shortage_q16) >=
                        SHORTAGE_RECOVERY_THRESHOLD_Q16) {
                    shortage_recovery = true;
                    break;
                }
                if (_good_storage_modes[good] != 0) continue;
                const int32_t flow = trade_flow_index(group.cell, good, false);
                const int64_t exports = flow >= 0
                    ? _trade_flows.export_ema[flow] : 0;
                const int64_t cold_start_supply = signal >= 0
                    ? _market_signals.offered_supply_ema[signal] : 0;
                const int64_t target = merchant_inventory_target(
                    market, good, signal, realized, exports, cold_start_supply,
                    _saturation_count);
                const int64_t stock = _market.stock[market_index];
                if (stock > target) {
                    inventory_surplus = true;
                    const int64_t absorption_q16 = target > 0
                        ? std::clamp<int64_t>(mul_div_sat(
                            target, Q16_ONE, stock, _saturation_count), 0, Q16_ONE)
                        : 0;
                    inventory_absorption_q16 = std::min(
                        inventory_absorption_q16, absorption_q16);
                }
            }
            if (group.last_output > 0 && sellable_output > 0) {
                const int64_t sell_through_q16 = std::clamp<int64_t>(mul_div_sat(
                    group.last_sold, Q16_ONE, sellable_output, _saturation_count),
                    0, Q16_ONE);
                const int64_t discard_rate_q16 = Q16_ONE - sell_through_q16;
                const int64_t target_utilization = shortage_recovery ||
                    discard_rate_q16 <= DISCARD_RATE_TOLERANCE_Q16
                        ? Q16_ONE
                        : mul_div_sat(utilization, sell_through_q16, Q16_ONE,
                                      _saturation_count);
                const int64_t inventory_target_utilization =
                    inventory_surplus && !shortage_recovery
                        ? mul_div_sat(utilization, inventory_absorption_q16,
                                      Q16_ONE, _saturation_count)
                        : Q16_ONE;
                // Income/affordability-responsive cap: produce toward the
                // expected affordable demand. market.demand_ema already folds in
                // household price & wealth elasticity (i.e. what households can
                // actually pay for), so scaling output to it curbs chronic
                // oversupply of cheap goods instead of only reacting once
                // inventory has already piled up.
                const int64_t demand_ratio_q16 = group.last_output > 0
                    ? std::clamp<int64_t>(mul_div_sat(
                        output_demand_ema, Q16_ONE,
                        group.last_output, _saturation_count), 0, Q16_ONE)
                    : Q16_ONE;
                const int64_t demand_target_utilization = !shortage_recovery
                    ? std::min<int64_t>(target_utilization, demand_ratio_q16)
                    : target_utilization;
                int64_t response_q16 = std::clamp<int64_t>(
                    type.supply_price_elasticity_q16, 0, Q16_ONE);
                // Persistent glut must contract within one or two settlement
                // cycles. Keep profile elasticity for ordinary adjustment, but
                // apply a deterministic response floor once discard is material.
                if (!shortage_recovery && discard_rate_q16 >= SEVERE_DISCARD_RATE_Q16)
                    response_q16 = Q16_ONE;
                else if (!shortage_recovery && discard_rate_q16 >= HIGH_DISCARD_RATE_Q16)
                    response_q16 = std::max<int64_t>(response_q16, 3 * Q16_ONE / 4);
                utilization = saturating_add(utilization, mul_div_sat(
                    std::min(demand_target_utilization, inventory_target_utilization) -
                        utilization,
                    response_q16, Q16_ONE,
                    _saturation_count), _saturation_count);
            } else if (shortage_recovery) {
                const int64_t response_q16 = std::clamp<int64_t>(
                    type.supply_price_elasticity_q16, 0, Q16_ONE);
                utilization = saturating_add(utilization, mul_div_sat(
                    Q16_ONE - utilization, response_q16, Q16_ONE,
                    _saturation_count), _saturation_count);
            }
            // Keep a small market probe while active. The loss state machine remains
            // the authority for a complete stop and can later restart the group.
            // Perishable producers need a larger floor: a 1/32 probe can leave an
            // otherwise viable fishing or gathering household below subsistence.
            const int64_t probe_floor_q16 = produces_cycle_flow || produces_survival_food
                ? Q16_ONE / 6 : Q16_ONE / 32;
            const int64_t survival_floor_q16 = group_index < static_cast<int32_t>(
                    _building_survival_utilization_floor_q16.size())
                ? _building_survival_utilization_floor_q16[group_index] : 0;
            group.planned_utilization_q16 = static_cast<int32_t>(
                std::clamp<int64_t>(utilization,
                    std::max(probe_floor_q16, survival_floor_q16), Q16_ONE));
        } else {
            group.planned_utilization_q16 = 0;
        }
        group.purchase_intent_capacity_q16 = 0;
        const int64_t group_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        group.last_expected_revenue = mul_div_sat(
            saturating_mul(group_days, revenue, _saturation_count),
            group.planned_utilization_q16, Q16_ONE, _saturation_count);
        if (margin_gap < 0) ++_unprofitable_building_groups;
        if (group.operating_state != 0) ++_loss_suspended_building_groups;
        _utilization_sum_q16 = saturating_add(
            _utilization_sum_q16, group.planned_utilization_q16, _saturation_count);
        }
    }
    return true;
}

NativeEconomyRuntime::PricePressure NativeEconomyRuntime::price_pressure(
        int32_t market, int32_t good, int64_t household_demand, int64_t stock,
        int64_t shortage_q16, int32_t signal_index, int64_t &sat) const {
    PricePressure out;
    out.household_demand = std::max<int64_t>(0, household_demand);
    if (signal_index >= 0) {
        const bool frozen_signals =
            _epoch_business_demand_ema.size() == _market_signals.business_demand_ema.size() &&
            _epoch_offered_supply_ema.size() == _market_signals.offered_supply_ema.size();
        out.business_demand = frozen_signals
            ? _epoch_business_demand_ema[signal_index]
            : _market_signals.business_demand_ema[signal_index];
        out.supply = frozen_signals
            ? _epoch_offered_supply_ema[signal_index]
            : _market_signals.offered_supply_ema[signal_index];
    }
    const int64_t demand = saturating_add(out.household_demand, out.business_demand, sat);
    const int64_t flow = saturating_add(demand, out.supply, sat);
    out.excess_q16 = std::clamp<int64_t>(mul_div_sat(
        saturating_sub(demand, out.supply, sat), Q16_ONE,
        std::max<int64_t>(GOODS_SCALE, flow), sat), -Q16_ONE, Q16_ONE);
    if (_good_storage_modes[good] == 0) {
        const int64_t price_inventory_days_q16 = std::min<int64_t>(
            _good_target_inventory_days_q16[good],
            saturating_mul(std::max(1, _epoch_days), Q16_ONE, sat));
        out.inventory_target = mul_div_sat(
            demand, price_inventory_days_q16, Q16_ONE, sat);
        out.inventory_q16 = std::clamp<int64_t>(mul_div_sat(
            saturating_sub(out.inventory_target, stock, sat), Q16_ONE,
            std::max<int64_t>(GOODS_SCALE, out.inventory_target), sat), -Q16_ONE, Q16_ONE);
        out.shortage_q16 = std::clamp<int64_t>(shortage_q16, 0, Q16_ONE);
    }
    const int64_t price = std::max<int64_t>(1, _market.price[_market.index(market, good)]);
    const int64_t anchor = signal_index >= 0 &&
        _epoch_cost_anchor_price.size() == _market_signals.cost_anchor_price.size()
            ? _epoch_cost_anchor_price[signal_index]
            : (signal_index >= 0 ? _market_signals.cost_anchor_price[signal_index] : 0);
    if (signal_index >= 0 && _good_monetary_issue_values[good] == 0 && anchor > 0) {
        const int64_t confidence = std::min<int64_t>(Q16_ONE, mul_div_sat(
            out.supply, Q16_ONE, std::max<int64_t>(GOODS_SCALE, demand), sat));
        out.cost_q16 = mul_div_sat(std::clamp<int64_t>(mul_div_sat(
            anchor - price, Q16_ONE, std::max<int64_t>(anchor, price), sat),
            -Q16_ONE, Q16_ONE), confidence, Q16_ONE, sat);
        if (anchor > price && demand > 0 &&
            (stock < out.inventory_target || shortage_q16 > 0)) {
            out.cost_floor_price = anchor;
        }
    }
    if (demand == 0 && out.supply == 0 && stock == 0) {
        out.idle_q16 = std::clamp<int64_t>(mul_div_sat(
            static_cast<int64_t>(_good_default_price[good]) - price, Q16_ONE,
            std::max<int64_t>(1, std::max<int64_t>(_good_default_price[good], price)), sat),
            -Q16_ONE, Q16_ONE);
    }
    out.total_q16 = 0;
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.excess_q16, _good_excess_demand_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.inventory_q16, _good_inventory_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.shortage_q16, _good_shortage_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.cost_q16, _good_cost_anchor_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.idle_q16, _good_inactive_reversion_weight_q16[good], Q16_ONE, sat), sat);
    const int64_t elasticity = std::clamp<int64_t>(
        _good_demand_price_elasticity_q16[good], Q16_ONE / 4, Q16_ONE * 4);
    const int64_t adjusted = mul_div_sat(out.total_q16, Q16_ONE, elasticity, sat);
    out.change_q16 = mul_div_sat(adjusted, _good_price_adjust_q16[good], Q16_ONE, sat);
    return out;
}

bool NativeEconomyRuntime::evaluate_building_conditions(int32_t type_id, int32_t cell) const {
    if (type_id < 0 || type_id >= static_cast<int32_t>(_building_types.size()) ||
        cell < 0 || cell >= _cell_count) return false;
    const BuildingType &type = _building_types[type_id];
    if (type.condition_count == 0) return true;
    bool stack[64]{};
    int32_t top = 0;
    auto compare = [](int64_t lhs, int32_t op, int64_t rhs) {
        switch (op) {
            case 0: return lhs == rhs;
            case 1: return lhs != rhs;
            case 2: return lhs < rhs;
            case 3: return lhs <= rhs;
            case 4: return lhs > rhs;
            case 5: return lhs >= rhs;
            default: return false;
        }
    };
    if (type.condition_count > 64) return false;
    for (int32_t i = 0; i < type.condition_count; ++i) {
        const ConditionToken &token = _building_conditions[type.condition_begin + i];
        if (token.opcode == 1) {
            int64_t lhs = 0;
            switch (token.signal) {
                case 0: lhs = _environment_temperature_q16[cell]; break;
                case 1: lhs = _environment_moisture_q16[cell]; break;
                case 2: lhs = _environment_snow_q16[cell]; break;
                case 3: lhs = _environment_weather_q16[cell]; break;
                case 4: lhs = _building_elevation_q16[cell]; break;
                case 5: lhs = _building_terrain[cell]; break;
                case 6: lhs = _building_landform[cell]; break;
                case 7: lhs = _building_vegetation[cell]; break;
                case 8: lhs = _building_is_water[cell]; break;
                case 9: lhs = _building_has_river[cell]; break;
                case 10:
                    if (token.reference < 0 || token.reference >= static_cast<int32_t>(_resource_ids.size()))
                        return false;
                    lhs = _resource_snapshot[static_cast<size_t>(token.reference) * _cell_count + cell];
                    break;
                default: return false;
            }
            if (top >= 64) return false;
            stack[top++] = compare(lhs, token.compare, token.value);
        } else if (token.opcode == 4) {
            if (top < 1) return false;
            stack[top - 1] = !stack[top - 1];
        } else {
            if (top < 2) return false;
            const bool rhs = stack[--top];
            const bool lhs = stack[top - 1];
            stack[top - 1] = token.opcode == 2 ? lhs && rhs : lhs || rhs;
        }
    }
    return top == 1 && stack[0];
}

int64_t NativeEconomyRuntime::credit_local_merchants(int32_t cell, int64_t amount,
                                                     int32_t cashflow_source,
                                                     int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    amount = std::max<int64_t>(0, amount);
    if (amount == 0 || cell < 0 || cell >= _cell_count) return 0;
    const int32_t begin = _merchant_offsets[cell];
    const int32_t end = _merchant_offsets[cell + 1];
    int64_t total_population = 0;
    for (int32_t k = begin; k < end; ++k) {
        total_population = saturating_add(total_population,
            _population.population[_merchant_slots[k]], _saturation_count);
    }
    if (total_population <= 0) return 0;
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = begin; k < end; ++k) {
        const int32_t slot = _merchant_slots[k];
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, _population.population[slot], _saturation_count);
        const int64_t next = mul_div_sat(amount, prefix, total_population, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        _population.funds[slot] = saturating_add(_population.funds[slot], share, _saturation_count);
        _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], share,
                                                        _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(slot), cashflow_source,
                              share, 0);
    }
    return distributed;
}

int64_t NativeEconomyRuntime::debit_local_merchants(int32_t cell, int64_t amount,
                                                    int32_t cashflow_source,
                                                    int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    amount = std::max<int64_t>(0, amount);
    if (amount == 0 || cell < 0 || cell >= _cell_count) return 0;
    const int32_t begin = _merchant_offsets[cell];
    const int32_t end = _merchant_offsets[cell + 1];
    int64_t total_funds = 0;
    for (int32_t k = begin; k < end; ++k) {
        total_funds = saturating_add(total_funds,
            std::max<int64_t>(0, _population.funds[_merchant_slots[k]]), _saturation_count);
    }
    const int64_t target = std::min(amount, total_funds);
    if (target <= 0) return 0;
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = begin; k < end; ++k) {
        const int32_t slot = _merchant_slots[k];
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, std::max<int64_t>(0, _population.funds[slot]),
                                _saturation_count);
        const int64_t next = mul_div_sat(target, prefix, total_funds, _saturation_count);
        const int64_t share = std::min(std::max<int64_t>(0, next - distributed),
                                       std::max<int64_t>(0, _population.funds[slot]));
        distributed = saturating_add(distributed, share, _saturation_count);
        _population.funds[slot] -= share;
        _population.epoch_expense[slot] = saturating_add(
            _population.epoch_expense[slot], share, _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(slot), cashflow_source,
                              0, share);
    }
    return distributed;
}

int64_t NativeEconomyRuntime::pay_building_wage_amount(
        int32_t cell, int32_t owner_slot, int32_t profession_id,
        int64_t filled_jobs, int64_t due, int64_t payment_cap,
        int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    if (filled_jobs <= 0 || due <= 0 || payment_cap <= 0 || owner_slot < 0) return 0;
    const bool trace_detail = trace_detail_for_cell(cell);
    const int64_t owner_handle = static_cast<int64_t>(_population.handle_for_slot(owner_slot));
    const int64_t owner_funds_before = _population.funds[owner_slot];
    const int64_t owner_expense_before = _population.epoch_expense[owner_slot];
    thread_local std::vector<int32_t> trace_slots;
    thread_local std::vector<int64_t> trace_funds;
    thread_local std::vector<int64_t> trace_income;
    trace_slots.clear(); trace_funds.clear(); trace_income.clear();
    int64_t total_employed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (_signatures[signature].profession_id == profession_id) {
            total_employed = saturating_add(total_employed,
                _population.employee_employed[slot], _saturation_count);
            if (trace_detail && _population.employee_employed[slot] > 0) {
                trace_slots.push_back(slot);
                trace_funds.push_back(_population.funds[slot]);
                trace_income.push_back(_population.epoch_income[slot]);
            }
        }
    });
    if (total_employed <= 0) {
        trace_append(EVENT_WAGE_SETTLED, static_cast<int32_t>(Stage::BUILDING_PRODUCTION),
                     cell, SUBJECT_COHORT, owner_handle, profession_id, -1,
                     filled_jobs, due, 0, due, nullptr);
        return 0;
    }
    const int64_t paid = std::min(
        std::min(due, payment_cap), std::max<int64_t>(0, _population.funds[owner_slot]));
    touch_accounting_slot(owner_slot);
    _population.funds[owner_slot] -= paid;
    _population.epoch_expense[owner_slot] = saturating_add(
        _population.epoch_expense[owner_slot], paid, _saturation_count);
    trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                          CASHFLOW_OWNER_WAGES, 0, paid);
    int64_t prefix = 0;
    int64_t distributed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (_signatures[signature].profession_id != profession_id ||
            _population.employee_employed[slot] <= 0) return;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, _population.employee_employed[slot],
                                _saturation_count);
        const int64_t next = mul_div_sat(paid, prefix, total_employed, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        _population.funds[slot] = saturating_add(_population.funds[slot], share,
                                                 _saturation_count);
        _population.epoch_income[slot] = saturating_add(
            _population.epoch_income[slot], share, _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(slot),
                              CASHFLOW_WAGES, share, 0);
    });
    std::vector<EventLeg> legs;
    if (trace_detail) {
        if (owner_funds_before != _population.funds[owner_slot]) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, owner_handle, -1,
                            owner_funds_before, _population.funds[owner_slot]});
        }
        if (owner_expense_before != _population.epoch_expense[owner_slot]) {
            legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, owner_handle, -1,
                            owner_expense_before, _population.epoch_expense[owner_slot]});
        }
        for (size_t i = 0; i < trace_slots.size(); ++i) {
            const int32_t worker_slot = trace_slots[i];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(worker_slot));
            if (trace_funds[i] != _population.funds[worker_slot]) {
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                                trace_funds[i], _population.funds[worker_slot]});
            }
            if (trace_income[i] != _population.epoch_income[worker_slot]) {
                legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                                trace_income[i], _population.epoch_income[worker_slot]});
            }
        }
    }
    trace_append(EVENT_WAGE_SETTLED, static_cast<int32_t>(Stage::BUILDING_PRODUCTION),
                 cell, SUBJECT_COHORT, owner_handle, profession_id, -1,
                 filled_jobs, due, distributed, due - distributed,
                 legs.empty() ? nullptr : &legs);
    return distributed;
}

bool NativeEconomyRuntime::apply_build_command(const Command &cmd, int32_t owner_slot,
                                                std::string &error) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    const int64_t count = cmd.i64_0;
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _population.page_cell[owner_slot / PAGE_SIZE] != cell) {
        _last_building_rejection_reason = "building_target_invalid";
        ++_rejected_commands;
        return true;
    }
    const int32_t owner_signature = static_cast<int32_t>(_population.signature_id[owner_slot]);
    const BuildingType &type = _building_types[type_id];
    if (!building_available(cell, type_id, true)) {
        _last_building_rejection_reason = "building_technology_locked";
        ++_rejected_commands;
        return true;
    }
    if (!building_constructible(cell, type_id, true)) {
        _last_building_rejection_reason = "building_tier_obsolete_for_construction";
        ++_rejected_commands;
        return true;
    }
    if (_signatures[owner_signature].profession_id != type.owner_profession_id) {
        _last_building_rejection_reason = "building_owner_profession_mismatch";
        ++_rejected_commands;
        return true;
    }
    if (!evaluate_building_conditions(type_id, cell)) {
        _last_building_rejection_reason = "building_conditions_failed";
        ++_rejected_commands;
        return true;
    }
    const int32_t market = _market.cell_to_market[cell];
    int64_t total_cost = 0;
    for (int32_t i = 0; i < type.construction_count; ++i) {
        const GoodAmount &item = _building_construction_goods[type.construction_begin + i];
        if (!good_available(cell, item.good_id, true)) {
            _last_building_rejection_reason = "building_construction_good_locked";
            ++_rejected_commands;
            return true;
        }
        const int64_t qty = saturating_mul(item.quantity, count, _saturation_count);
        const int64_t stock = _market.stock[_market.index(market, item.good_id)];
        if (stock < qty) {
            const int32_t signal = ensure_market_signal_index(cell, item.good_id);
            if (signal >= 0) {
                const int64_t shortfall = qty - stock;
                const int64_t daily_shortfall = std::max<int64_t>(
                    1, shortfall / std::max<int32_t>(1, _epoch_days));
                if (signal < static_cast<int32_t>(_market_signals.business_demand_ema.size())) {
                    _market_signals.business_demand_ema[signal] = std::max(
                        _market_signals.business_demand_ema[signal], daily_shortfall);
                }
                if (signal < static_cast<int32_t>(_epoch_nonhousehold_withdrawals.size())) {
                    _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[signal], shortfall,
                        _saturation_count);
                }
            }
            _last_building_rejection_reason = "building_construction_stock_insufficient";
            ++_rejected_commands;
            return true;
        }
        total_cost = saturating_add(total_cost,
            mul_div_sat(qty, _market.price[_market.index(market, item.good_id)],
                        GOODS_SCALE, _saturation_count), _saturation_count);
    }
    if (_population.funds[owner_slot] < total_cost) {
        _last_building_rejection_reason = "building_owner_funds_insufficient";
        ++_rejected_commands;
        return true;
    }
    std::vector<EventLeg> event_legs;
    const bool trace_detail = trace_detail_for_cell(cell);
    const int64_t owner_handle = static_cast<int64_t>(_population.handle_for_slot(owner_slot));
    const int64_t owner_funds_before = _population.funds[owner_slot];
    const int64_t owner_expense_before = _population.epoch_expense[owner_slot];
    std::vector<int32_t> merchant_trace_slots;
    std::vector<int64_t> merchant_trace_funds;
    std::vector<int64_t> merchant_trace_income;
    if (trace_detail) {
        for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
            const int32_t merchant_slot = _merchant_slots[k];
            merchant_trace_slots.push_back(merchant_slot);
            merchant_trace_funds.push_back(_population.funds[merchant_slot]);
            merchant_trace_income.push_back(_population.epoch_income[merchant_slot]);
        }
        for (int32_t i = 0; i < type.construction_count; ++i) {
            const GoodAmount &item = _building_construction_goods[type.construction_begin + i];
            const int64_t idx = _market.index(market, item.good_id);
            const int64_t qty = count > 0 && item.quantity >
                std::numeric_limits<int64_t>::max() / count
                    ? std::numeric_limits<int64_t>::max() : item.quantity * count;
            event_legs.push_back({FIELD_MARKET_STOCK, SUBJECT_MARKET, market, item.good_id,
                                  _market.stock[idx], _market.stock[idx] - qty});
        }
    }
    touch_accounting_slot(owner_slot);
    for (int32_t i = 0; i < type.construction_count; ++i) {
        const GoodAmount &item = _building_construction_goods[type.construction_begin + i];
        const int64_t qty = saturating_mul(item.quantity, count, _saturation_count);
        _market.stock[_market.index(market, item.good_id)] -= qty;
        _construction_goods_consumed = saturating_add(_construction_goods_consumed, qty,
                                                       _saturation_count);
        const int32_t signal = ensure_market_signal_index(cell, item.good_id);
        if (signal >= 0 && signal < static_cast<int32_t>(
                _epoch_nonhousehold_withdrawals.size())) {
            _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                _epoch_nonhousehold_withdrawals[signal], qty, _saturation_count);
        }
    }
    _population.funds[owner_slot] -= total_cost;
    _population.epoch_expense[owner_slot] = saturating_add(
        _population.epoch_expense[owner_slot], total_cost, _saturation_count);
    trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                          CASHFLOW_CONSTRUCTION, 0, total_cost);
    if (credit_local_merchants(cell, total_cost, CASHFLOW_MERCHANT_BUSINESS) != total_cost) {
        error = "building_construction_has_no_merchant_owner";
        return false;
    }
    _pending_construction.push_back({cell, type_id, owner_signature, count,
        _sample_day + type.construction_days, cmd.sequence});
    if (trace_detail && owner_funds_before != _population.funds[owner_slot]) {
        event_legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, owner_handle, -1,
                              owner_funds_before, _population.funds[owner_slot]});
    }
    if (trace_detail && owner_expense_before != _population.epoch_expense[owner_slot]) {
        event_legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, owner_handle, -1,
                              owner_expense_before, _population.epoch_expense[owner_slot]});
    }
    if (trace_detail) {
        for (size_t i = 0; i < merchant_trace_slots.size(); ++i) {
            const int32_t merchant_slot = merchant_trace_slots[i];
            const int64_t handle = static_cast<int64_t>(
                _population.handle_for_slot(merchant_slot));
            if (merchant_trace_funds[i] != _population.funds[merchant_slot]) {
                event_legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                                      merchant_trace_funds[i],
                                      _population.funds[merchant_slot]});
            }
            if (merchant_trace_income[i] != _population.epoch_income[merchant_slot]) {
                event_legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                                      merchant_trace_income[i],
                                      _population.epoch_income[merchant_slot]});
            }
        }
    }
    trace_append(EVENT_CONSTRUCTION_STARTED, static_cast<int32_t>(_stage),
                 cell, SUBJECT_BUILDING_GROUP, owner_signature, type_id, -1,
                 count, total_cost, _sample_day + type.construction_days, cmd.sequence,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

bool NativeEconomyRuntime::apply_demolish_command(const Command &cmd, int32_t owner_slot,
                                                   std::string &) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    const int64_t count = cmd.i64_0;
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _population.page_cell[owner_slot / PAGE_SIZE] != cell) {
        _last_building_rejection_reason = "demolish_target_invalid";
        ++_rejected_commands;
        return true;
    }
    const int32_t signature = static_cast<int32_t>(_population.signature_id[owner_slot]);
    const int32_t group_id = find_building_group(cell, type_id, signature);
    if (group_id < 0 || _buildings[group_id].count < count) {
        _last_building_rejection_reason = "demolish_owned_count_insufficient";
        ++_rejected_commands;
        return true;
    }
    const int64_t before = _buildings[group_id].count;
    _buildings[group_id].count -= count;
    std::vector<EventLeg> event_legs;
    if (trace_detail_for_cell(cell)) {
        event_legs.push_back({FIELD_BUILDING_COUNT, SUBJECT_BUILDING_GROUP, signature,
                              type_id, before, _buildings[group_id].count});
    }
    trace_append(EVENT_BUILDING_DEMOLISHED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 cell, SUBJECT_BUILDING_GROUP, signature, type_id, -1,
                 count, before, _buildings[group_id].count, cmd.sequence,
                 event_legs.empty() ? nullptr : &event_legs);
    _structural_touched_cells.push_back(cell);
    return true;
}

bool NativeEconomyRuntime::run_building_employment_cell(
        int32_t cell, bool allow_owner_job_reallocation, std::string &error) {
    if (!prepare_cell_wages(cell, error)) return false;
    // demand[p] = profession p 本周期 employee 目标之和；fill[p] = 夹紧后在岗
    // employee 之和。二者在 A1 两步逻辑中被 std::fill 重置复用（见下）。
    thread_local std::vector<int64_t> demand;
    thread_local std::vector<int64_t> fill;
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    demand.assign(professions, 0);
    fill.assign(professions, 0);
    const int32_t first = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t last = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    bool has_active_owner_vacancy = false;
    for (int32_t g = first; g < last; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.count <= 0 || group.operating_state != 0 ||
            !building_available(cell, group.type_id, true)) continue;
        const BuildingType &type = _building_types[group.type_id];
        if (type.kind == 2) continue;
        const int64_t full = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        if (group.filled_owner < full) {
            has_active_owner_vacancy = true;
            break;
        }
    }
    auto planned_role_demand = [&](const BuildingGroup &group, const JobRole &role) {
        const int64_t full = saturating_mul(group.count, role.slots_per_building,
                                            _saturation_count);
        int64_t scaled = mul_div_sat(full, group.planned_utilization_q16, Q16_ONE,
                                     _saturation_count);
        if (scaled == 0 && full > 0 && group.planned_utilization_q16 > 0) scaled = 1;
        return scaled;
    };
    auto planned_owner_demand = [&](const BuildingGroup &group, const BuildingType &type) {
        const int64_t full = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        if (group.operating_state != 0) {
            // A suspended owner remains responsible only when there is nowhere
            // productive to move. An active vacancy releases this owner through
            // the ordinary unemployed-pool transition and active-first hiring.
            return has_active_owner_vacancy ? int64_t{0}
                                            : (full > 0 ? int64_t{1} : int64_t{0});
        }
        return group.planned_utilization_q16 > 0 ? full : 0;
    };
    const bool trace_detail = trace_detail_for_cell(cell);
    // A1 迁移会 allocate/release slot，裸 slot id 会失效；trace 快照改存稳定
    // handle，事件生成时用 valid_handle 解析回当前 slot（失效则跳过该 leg）。
    thread_local std::vector<uint64_t> trace_handles;
    thread_local std::vector<int64_t> trace_owner_before;
    thread_local std::vector<int64_t> trace_employee_before;
    trace_handles.clear(); trace_owner_before.clear(); trace_employee_before.clear();
    if (trace_detail) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            trace_handles.push_back(_population.handle_for_slot(slot));
            trace_owner_before.push_back(_population.owner_employed[slot]);
            trace_employee_before.push_back(_population.employee_employed[slot]);
        });
    }
    // ================================================================
    // A1 路径：失业池增量就业（统一净增量迁移，用户 2026-07-16 拍板）
    // ----------------------------------------------------------------
    // 不变量（employment 结束时对每个非 merchant、非 unemployed 的
    //   profession|eth slot 成立）：owner_employed + employee_employed
    //   == population，即在岗 slot 里没有闲置人口；任何未被任何建筑雇佣
    //   的人都真实迁往 unemployed|eth slot（独立 cohort 身份 + plan_unemployed，
    //   消费退化为 survival food → satisfaction 掉 → starvation 自然死上升，
    //   失业惩罚由 demography 自动施加，无需硬编死亡率）。
    //
    // 两步结构（数学上等价于"消失清理 + 建筑驱动裁员 + 优先级招人"三阶段
    //   合并，但 owner/employee 在同一 slot 内自然竞争 population，无需在阶段
    //   间显式传递 slot 剩余容量）：
    //   [第1步 析出] 每个在岗 slot 按本周期 planned_utilization 目标算
    //     desired_working；surplus = population - desired_working 的部分迁往
    //     unemployed|eth。消失/不可用建筑目标为 0，其在岗人口自然全部进池。
    //     执行后所有活跃 group 的 filled_* 被夹到"目标或更少"，多余人口全在池中。
    //   [第2步 招人] unemployed 池此刻汇集了各 eth 的全部失业者（含本周期刚
    //     进池的 + 历史长期失业的）。活跃 group 按优先级
    //     (realized_profit_margin_q16 desc, planned_utilization_q16 desc,
    //      group_index asc) 跨建筑类型排序，依次把 filled_owner/filled_employee
    //     补到目标，从 unemployed|eth 真实迁回对应 profession|eth slot（受池
    //     可用量约束）。低优先级/亏损 group 招不满即长期缺人 → "先喂最赚钱"。
    //     招人跨 profession：失业 farmer 可被招为 miner（profession 是可变就业
    //     状态，架构决策4）。
    //
    // 关键工程约束：move_cohort_population 会 allocate/release slot，破坏
    //   for_each_in_cell 的页链迭代器。故所有迁移都"先只读遍历收集计划到
    //   thread_local 缓冲，遍历结束后再统一执行迁移"（学 ensure_merchant_invariant）。
    //   Route B: 商栈(merchant_post) owner 现在参与就业分配——merchant slot 的
    //   owner_employed 计入 filled_owner、纳入析出/聚合；但保底每有人 cell 至少
    //   1 个 merchant 不被裁(护住 rebuild_merchant_ranges 做市索引不变量)。
    //   emp_capacity 第一遍仍跳过 merchant(商人不做 employee，仅 owner 岗)。
    // ================================================================
    // The same authoritative release/hire path also owns cells whose last
    // building was removed. Empty ranges must release every non-merchant
    // profession cohort into unemployed instead of leaving an idle profession.
    {
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());

        // ---- 目标计算：本周期各 group 期望的 owner / 各 role employee ----
        // 用 thread_local 缓冲避免每 cell 分配。
        thread_local std::vector<int64_t> group_owner_target;      // 每 group owner 目标
        group_owner_target.assign(static_cast<size_t>(last - first), 0);
        // profession 级 employee 目标 / 在岗（跨 eth 聚合，沿用旧 employee 语义）。
        std::fill(demand.begin(), demand.end(), 0);   // demand[p] = Σ planned_role_demand
        std::fill(fill.begin(), fill.end(), 0);       // fill[p]   = Σ 当前在岗 employee
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell) continue;
            const bool active = group.count > 0 && group.operating_state == 0 &&
                                 building_available(cell, group.type_id, true);
            const BuildingType &type = _building_types[group.type_id];
            // owner 目标：不可用/count<=0 → 0（其在岗人口将全部进池）。
            const bool suspended = group.count > 0 && group.operating_state != 0 &&
                                   building_available(cell, group.type_id, true);
            const int64_t owner_target = (active || suspended)
                ? planned_owner_demand(group, type) : 0;
            group_owner_target[g - first] = owner_target;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int64_t role_target = active ? planned_role_demand(group, role) : 0;
                demand[p] = saturating_add(demand[p], role_target, _saturation_count);
                const int32_t fi = group.employee_fill_begin + r;
                fill[p] = saturating_add(fill[p],
                    std::max<int64_t>(0, _building_employee_filled[fi]), _saturation_count);
            }
        }
        // Reuse the same profitability/utilization priority for retaining incumbent
        // owners and for hiring replacements. Population can shrink after the prior
        // employment pass, so per-group target clamps alone are insufficient when
        // several groups share one owner signature.
        thread_local std::vector<int32_t> hire_order;
        thread_local std::vector<uint8_t> labor_survival_priority;
        thread_local std::vector<int32_t> labor_shortage_priority_q16;
        hire_order.clear();
        labor_survival_priority.assign(static_cast<size_t>(last - first), uint8_t{0});
        labor_shortage_priority_q16.assign(static_cast<size_t>(last - first), 0);
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true) ||
                group_owner_target[g - first] <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            const int32_t market = _market.cell_to_market[cell];
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t market_index = _market.index(market, good);
                int64_t shortage_q16 = _market.last_shortage_q16[market_index];
                const int32_t signal = market_signal_index(cell, good);
                if (signal >= 0) {
                    const int64_t business =
                        _market_signals.business_demand_ema[signal];
                    const int64_t withdrawal =
                        _market_signals.realized_withdrawal_ema[signal];
                    if (business > withdrawal && business > 0) {
                        const int64_t business_gap_q16 = std::min<int64_t>(
                            Q16_ONE, mul_div_sat(business - withdrawal, Q16_ONE,
                                business, _saturation_count));
                        shortage_q16 = std::max(shortage_q16, business_gap_q16);
                    }
                }
                const size_t local_group = static_cast<size_t>(g - first);
                labor_shortage_priority_q16[local_group] = static_cast<int32_t>(
                    std::max<int64_t>(labor_shortage_priority_q16[local_group],
                        shortage_q16));
                if (_survival_food_good_mask[good] != 0) {
                    const int64_t reserve = signal >= 0 && signal <
                            static_cast<int32_t>(_production_input_reserve.size())
                        ? _production_input_reserve[signal] : 0;
                    const int64_t household_stock = std::max<int64_t>(
                        0, _market.stock[market_index] - reserve);
                    if (household_stock <= 1 || shortage_q16 >= Q16_ONE / 8) {
                        labor_survival_priority[local_group] = 1;
                    }
                }
            }
            hire_order.push_back(g);
        }
        std::stable_sort(hire_order.begin(), hire_order.end(),
                         [&](int32_t a, int32_t b) {
            const BuildingGroup &ga = _buildings[a];
            const BuildingGroup &gb = _buildings[b];
            if ((ga.operating_state == 0) != (gb.operating_state == 0))
                return ga.operating_state == 0;
            const size_t local_a = static_cast<size_t>(a - first);
            const size_t local_b = static_cast<size_t>(b - first);
            if (labor_survival_priority[local_a] != labor_survival_priority[local_b])
                return labor_survival_priority[local_a] > labor_survival_priority[local_b];
            if (labor_shortage_priority_q16[local_a] != labor_shortage_priority_q16[local_b])
                return labor_shortage_priority_q16[local_a] >
                    labor_shortage_priority_q16[local_b];
            if (ga.realized_profit_margin_q16 != gb.realized_profit_margin_q16)
                return ga.realized_profit_margin_q16 > gb.realized_profit_margin_q16;
            if (ga.planned_utilization_q16 != gb.planned_utilization_q16)
                return ga.planned_utilization_q16 > gb.planned_utilization_q16;
            return a < b;
        });

        // ---- 第1步 析出：把超出目标的在岗人口迁往 unemployed|eth ----
        // (a) 先把每个 group 的 filled_owner / _building_employee_filled 夹到目标
        //     （裁员：filled > target 的差额释放）。employee 按 profession 稳定序
        //     在多 group 间削减（同 profession 聚合，逐 group 削到 target）。
        // (b) 再按 profession|eth slot 聚合"该 slot 应保留的在岗人口"，把
        //     population - retained 迁往 unemployed|eth。
        //
        // owner 侧夹紧（建筑驱动：每 group 独立按自身 filled-target 裁）。
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.filled_owner > group_owner_target[g - first]) {
                group.filled_owner = group_owner_target[g - first];
            }
        }
        // A cohort can lose population during household demography while its
        // building-group fill counters still describe the previous epoch. Clamp
        // the aggregate fill for each owner signature to the live cohort population
        // before deriving retained employment. Higher-priority groups retain their
        // incumbents first; any released target is eligible for normal hiring below.
        thread_local std::vector<int64_t> sig_owner_remaining;
        sig_owner_remaining.assign(_signatures.size(), 0);
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = _population.signature_id[slot];
            if (sig >= sig_owner_remaining.size()) return;
            sig_owner_remaining[sig] = saturating_add(
                sig_owner_remaining[sig],
                std::max<int64_t>(0, _population.population[slot]), _saturation_count);
        });
        for (int32_t g : hire_order) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(sig_owner_remaining.size())) {
                group.filled_owner = 0;
                continue;
            }
            int64_t &remaining = sig_owner_remaining[group.owner_signature_id];
            group.filled_owner = std::min(std::max<int64_t>(0, group.filled_owner), remaining);
            remaining -= group.filled_owner;
        }
        // employee 侧夹紧：profession p 若 Σfilled > Σtarget，按 group 稳定序
        // 从后往前削减各 role fill 到 demand。用 remaining[p] 追踪该 profession
        // 允许保留的总在岗数，逐 group 分配 min(role_filled, remaining)。
        thread_local std::vector<int64_t> emp_remaining;   // 每 profession 允许保留的在岗上限
        emp_remaining.assign(professions, 0);
        for (int32_t p = 0; p < professions; ++p) {
            emp_remaining[p] = std::min(fill[p], demand[p]);   // 裁员后保留 = min(在岗, 目标)
        }
        std::fill(fill.begin(), fill.end(), 0);   // 重算为夹紧后的实际在岗
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t cur = std::max<int64_t>(0, _building_employee_filled[fi]);
                const int64_t keep = std::min(cur, emp_remaining[p]);
                _building_employee_filled[fi] = keep;
                emp_remaining[p] -= keep;
                fill[p] = saturating_add(fill[p], keep, _saturation_count);
            }
        }

        // (b) 计算每个 profession|eth slot 夹紧后应保留的在岗人口，收集迁往池的差额。
        //     owner_retained[slot] = 该 signature 各 group filled_owner 之和；
        //     employee_retained[slot] = 该 profession 在岗 employee 按 slot 稳定序摊派。
        //     retained = owner_retained + employee_retained（A1: <= population）。
        //     surplus = population - retained → 迁往 unemployed|eth。
        //
        // 先按 signature 聚合 owner filled（owner 绑定精确 signature）。
        thread_local std::vector<int64_t> sig_owner_retained;   // 按 signature id
        sig_owner_retained.assign(_signatures.size(), 0);
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            sig_owner_retained[group.owner_signature_id] = saturating_add(
                sig_owner_retained[group.owner_signature_id],
                std::max<int64_t>(0, group.filled_owner), _saturation_count);
        }
        // employee 在岗按 profession 稳定序摊派到各 slot（同 profession 的多 eth
        // slot 按 signature_id 升序，用 cohort 可容纳量比例摊派，前缀和保确定）。
        thread_local std::vector<int64_t> emp_prefix;
        thread_local std::vector<int64_t> emp_distributed;
        thread_local std::vector<int64_t> emp_capacity;   // 每 profession 各 slot 可当 employee 的容量之和
        emp_prefix.assign(professions, 0);
        emp_distributed.assign(professions, 0);
        emp_capacity.assign(professions, 0);
        // 第一遍：算每 profession 的 employee 容量总量 = Σ(population - owner_retained)。
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            if (p == _unemployed_profession_id) return;
            const int64_t owner_here = std::min(sig_owner_retained[sig],
                std::max<int64_t>(0, _population.population[slot]));
            const int64_t cap = std::max<int64_t>(0, _population.population[slot] - owner_here);
            emp_capacity[p] = saturating_add(emp_capacity[p], cap, _saturation_count);
        });
        // 第二遍：只读收集每个 slot 的 surplus（迁往池）到缓冲，遍历后统一迁移。
        // owner_retained 按 signature 在多 slot 间也需稳定序摊派（同 signature 通常
        // 只有一个 slot；多页时按遍历序，前缀和保确定）。
        thread_local std::vector<int64_t> sig_owner_distributed;
        sig_owner_distributed.assign(_signatures.size(), 0);
        thread_local std::vector<int32_t> shed_source_slots;   // surplus 来源 slot
        thread_local std::vector<int32_t> shed_dest_eth;       // 对应 eth（→ unemployed|eth）
        thread_local std::vector<int64_t> shed_pop;            // surplus 人数
        shed_source_slots.clear(); shed_dest_eth.clear(); shed_pop.clear();
        // Route B: merchant slots are no longer skipped wholesale. A merchant
        // slot may now carry a merchant-post owner (sig_owner_retained>0) that
        // must be aggregated/right-sized like any other owner. But the market
        // maker invariant (rebuild_merchant_ranges requires >=1 merchant per
        // populated cell) forbids shedding the last merchant, so a merchant
        // slot keeps a floor of max(owner_here, 1) retained. Non-merchant slots
        // are unchanged.
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t p = _signatures[sig].profession_id;
            const int32_t eth = _signatures[sig].ethnicity_id;
            const int64_t pop = std::max<int64_t>(0, _population.population[slot]);
            if (p == _unemployed_profession_id) {
                // 失业 slot：本步不动（它是池，招人步骤才从中迁出）。
                return;
            }
            const bool merchant_here = is_merchant_slot(slot);
            // owner 在本 slot 的份额（同 signature 多 slot 时稳定序摊派）。
            const int64_t owner_here = std::min(
                std::max<int64_t>(0, sig_owner_retained[sig] - sig_owner_distributed[sig]), pop);
            sig_owner_distributed[sig] = saturating_add(sig_owner_distributed[sig],
                                                        owner_here, _saturation_count);
            if (merchant_here) {
                // 商人 slot 不做 employee（仅 owner 岗）；保底 1 个做市商不裁。
                const int64_t retained = std::min(pop,
                    std::max<int64_t>(owner_here, pop > 0 ? 1 : 0));
                _population.owner_employed[slot] = owner_here;
                _population.employee_employed[slot] = 0;
                const int64_t surplus = std::max<int64_t>(0, pop - retained);
                if (surplus > 0 && eth >= 0 && eth < n_eth) {
                    shed_source_slots.push_back(slot);
                    shed_dest_eth.push_back(eth);
                    shed_pop.push_back(surplus);
                }
                return;
            }
            // employee 在本 slot 的份额：按容量比例摊派 fill[p]。
            const int64_t cap_here = std::max<int64_t>(0, pop - owner_here);
            emp_prefix[p] = saturating_add(emp_prefix[p], cap_here, _saturation_count);
            const int64_t emp_next = emp_capacity[p] > 0
                ? mul_div_sat(fill[p], emp_prefix[p], emp_capacity[p], _saturation_count) : 0;
            const int64_t emp_here = std::max<int64_t>(0, emp_next - emp_distributed[p]);
            emp_distributed[p] = emp_next;
            const int64_t retained = std::min(pop, saturating_add(owner_here, emp_here,
                                                                   _saturation_count));
            _population.owner_employed[slot] = owner_here;
            _population.employee_employed[slot] = std::min(emp_here,
                std::max<int64_t>(0, pop - owner_here));
            const int64_t surplus = std::max<int64_t>(0, pop - retained);
            if (surplus > 0 && eth >= 0 && eth < n_eth) {
                shed_source_slots.push_back(slot);
                shed_dest_eth.push_back(eth);
                shed_pop.push_back(surplus);
            }
        });
        // 遍历外执行析出迁移（在岗 profession|eth → unemployed|eth）。
        for (size_t i = 0; i < shed_source_slots.size(); ++i) {
            const int32_t src = shed_source_slots[i];
            const int32_t dest_sig = unemployed_signature_for_ethnicity(shed_dest_eth[i]);
            if (dest_sig < 0) continue;   // 无 unemployed signature（向后兼容）：留原 slot。
            if (dest_sig == static_cast<int32_t>(_population.signature_id[src])) continue;
            bool drained = false;
            if (!move_cohort_population(src, cell, dest_sig, shed_pop[i], error, &drained)) {
                return false;
            }
        }

        // ---- 第2步 招人：按优先级从 unemployed 池增量迁回 ----
        // 优先级键：(realized_profit_margin_q16 desc, planned_utilization_q16 desc,
        //            group_index asc)。排序粒度=跨 BuildingGroup（跨建筑类型）；
        // 同 type_id+同 owner_signature 聚合的组内盈利/利用率相同，组内不排（稳定序）。
        // 池可用量：按 eth 缓存各 unemployed|eth slot 的当前人口与 slot id。
        // 招 owner 需精确 eth（group.owner_signature 的 eth）；招 employee 可跨 eth
        // （按 eth 升序取池，保确定）。招人在遍历外逐 group 执行迁移，每次迁移后
        // 重新定位池 slot（可能被 drain 释放）。
        auto pool_slot_for_eth = [&](int32_t eth) -> int32_t {
            const int32_t sig = unemployed_signature_for_ethnicity(eth);
            if (sig < 0) return -1;
            return _population.find_signature(cell, static_cast<uint32_t>(sig));
        };
        for (size_t oi = 0; oi < hire_order.size(); ++oi) {
            const int32_t g = hire_order[oi];
            BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            // --- owner 招募（精确 eth = owner_signature 的 eth）---
            const int64_t owner_target = group_owner_target[g - first];
            int64_t owner_need = std::max<int64_t>(0, owner_target - group.filled_owner);
            if (owner_need > 0 && group.owner_signature_id >= 0 &&
                group.owner_signature_id < static_cast<int32_t>(_signatures.size())) {
                const int32_t owner_eth = _signatures[group.owner_signature_id].ethnicity_id;
                const int32_t pool = pool_slot_for_eth(owner_eth);
                if (pool >= 0) {
                    const int64_t avail = std::max<int64_t>(0, _population.population[pool]);
                    const int64_t take = std::min(owner_need, avail);
                    if (take > 0 &&
                        group.owner_signature_id != static_cast<int32_t>(
                            _population.signature_id[pool])) {
                        bool drained = false;
                        if (!move_cohort_population(pool, cell, group.owner_signature_id,
                                                    take, error, &drained)) {
                            return false;
                        }
                        group.filled_owner = saturating_add(group.filled_owner, take,
                                                            _saturation_count);
                        // 迁回的人在其目标 profession|eth slot 记为在岗 owner。
                        const int32_t dest = _population.find_signature(
                            cell, static_cast<uint32_t>(group.owner_signature_id));
                        if (dest >= 0) {
                            _population.owner_employed[dest] = saturating_add(
                                _population.owner_employed[dest], take, _saturation_count);
                        }
                    }
                }
            }
            if (group.operating_state != 0) continue;
            // --- employee 招募（每 role，profession 匹配，跨 eth 按升序取池）---
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                if (!profession_available(cell, p, true)) continue;
                const int32_t fi = group.employee_fill_begin + r;
                const int64_t role_target = planned_role_demand(group, role);
                int64_t need = std::max<int64_t>(0,
                    role_target - std::max<int64_t>(0, _building_employee_filled[fi]));
                if (need <= 0) continue;
                // 目标 slot 按具体 eth 定（跨 eth 招募，按 eth 升序稳定取池）。
                for (int32_t eth = 0; eth < n_eth && need > 0; ++eth) {
                    const int32_t pool = pool_slot_for_eth(eth);
                    if (pool < 0) continue;
                    const int64_t avail = std::max<int64_t>(0, _population.population[pool]);
                    if (avail <= 0) continue;
                    const int32_t target_sig = signature_for_profession_ethnicity(p, eth);
                    if (target_sig < 0) continue;
                    if (target_sig == static_cast<int32_t>(_population.signature_id[pool]))
                        continue;
                    const int64_t take = std::min(need, avail);
                    if (take <= 0) continue;
                    bool drained = false;
                    if (!move_cohort_population(pool, cell, target_sig, take, error, &drained)) {
                        return false;
                    }
                    _building_employee_filled[fi] = saturating_add(
                        _building_employee_filled[fi], take, _saturation_count);
                    const int32_t dest = _population.find_signature(
                        cell, static_cast<uint32_t>(target_sig));
                    if (dest >= 0) {
                        _population.employee_employed[dest] = saturating_add(
                            _population.employee_employed[dest], take, _saturation_count);
                    }
                    need -= take;
                }
            }
        }

        if (allow_owner_job_reallocation) {
        // Unemployed hiring remains authoritative and runs first. Remaining
        // ACTIVE owner vacancies may then attract one incumbent owner from a
        // lower-income ACTIVE group of the same ethnicity. Targets and sources
        // are snapshotted before matching so a group cannot chain through
        // several jobs in the same employment period.
        thread_local std::vector<int64_t> projected_owner_income;
        thread_local std::vector<int32_t> owner_job_targets;
        thread_local std::vector<int32_t> owner_job_sources;
        thread_local std::vector<uint8_t> owner_job_group_used;
        projected_owner_income.assign(static_cast<size_t>(last - first), 0);
        owner_job_targets.clear();
        owner_job_sources.clear();
        owner_job_group_used.assign(static_cast<size_t>(last - first), uint8_t{0});
        int64_t local_merchant_population = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) {
                local_merchant_population = saturating_add(
                    local_merchant_population,
                    std::max<int64_t>(0, _population.population[slot]),
                    _saturation_count);
            }
        });
        for (int32_t g = first; g < last; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                group.operating_state != 0 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (type.kind == 2 || group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size())) continue;
            const int64_t income = projected_owner_income_per_day(
                group, _saturation_count);
            projected_owner_income[g - first] = income;
            const int64_t owner_target = group_owner_target[g - first];
            if (group.filled_owner < owner_target) {
                if (income > 0) owner_job_targets.push_back(g);
            }
            if (group.filled_owner > 0 && owner_target > 0) {
                const int32_t source_slot = _population.find_signature(
                    cell, static_cast<uint32_t>(group.owner_signature_id));
                if (source_slot >= 0 && _population.owner_employed[source_slot] > 0) {
                    owner_job_sources.push_back(g);
                }
            }
        }
        std::stable_sort(owner_job_targets.begin(), owner_job_targets.end(),
                         [&](int32_t a, int32_t b) {
            const int64_t income_a = projected_owner_income[a - first];
            const int64_t income_b = projected_owner_income[b - first];
            return income_a != income_b ? income_a > income_b : a < b;
        });
        std::stable_sort(owner_job_sources.begin(), owner_job_sources.end(),
                         [&](int32_t a, int32_t b) {
            const int64_t income_a = projected_owner_income[a - first];
            const int64_t income_b = projected_owner_income[b - first];
            return income_a != income_b ? income_a < income_b : a < b;
        });
        for (int32_t target_group_index : owner_job_targets) {
            if (owner_job_group_used[target_group_index - first] != 0) continue;
            BuildingGroup &target_group = _buildings[target_group_index];
            const Signature &target_signature =
                _signatures[target_group.owner_signature_id];
            const int64_t target_income =
                projected_owner_income[target_group_index - first];
            int32_t source_group_index = -1;
            int32_t source_slot = -1;
            for (int32_t candidate : owner_job_sources) {
                if (candidate == target_group_index ||
                    owner_job_group_used[candidate - first] != 0) continue;
                const BuildingGroup &source_group = _buildings[candidate];
                const Signature &source_signature =
                    _signatures[source_group.owner_signature_id];
                if (source_signature.ethnicity_id != target_signature.ethnicity_id ||
                    projected_owner_income[candidate - first] >= target_income) continue;
                const int32_t slot = _population.find_signature(
                    cell, static_cast<uint32_t>(source_group.owner_signature_id));
                if (slot < 0 || _population.owner_employed[slot] <= 0) continue;
                if (source_signature.profession_id == _merchant_profession_id &&
                    local_merchant_population <= 1) continue;
                source_group_index = candidate;
                source_slot = slot;
                break;
            }
            if (source_group_index < 0) continue;
            const int64_t source_income =
                projected_owner_income[source_group_index - first];
            const int64_t income_gain = target_income - source_income;
            const int64_t chance_q16 = std::clamp<int64_t>(mul_div_sat(
                income_gain, Q16_ONE, target_income, _saturation_count), 1, Q16_ONE);
            uint64_t roll_hash = 1469598103934665603ULL;
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_seed));
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_current_day));
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(cell));
            roll_hash = trace_hash_mix(
                roll_hash, static_cast<uint32_t>(target_group_index));
            roll_hash = trace_hash_mix(
                roll_hash, static_cast<uint32_t>(source_group_index));
            const int64_t roll_q16 = static_cast<int64_t>(
                (roll_hash >> 32) & 0xffffULL);
            if (roll_q16 >= chance_q16) {
                ++_building_owner_job_probability_skips;
                continue;
            }

            BuildingGroup &source_group = _buildings[source_group_index];
            const Signature &source_signature =
                _signatures[source_group.owner_signature_id];
            if (source_signature.profession_id != target_signature.profession_id) {
                bool source_drained = false;
                if (!move_cohort_population(source_slot, cell,
                        target_group.owner_signature_id, 1, error,
                        &source_drained)) {
                    return false;
                }
                if (!source_drained) {
                    _population.owner_employed[source_slot] = std::max<int64_t>(
                        0, _population.owner_employed[source_slot] - 1);
                }
                const int32_t destination = _population.find_signature(
                    cell, static_cast<uint32_t>(target_group.owner_signature_id));
                if (destination < 0) {
                    error = "owner_job_reallocation_destination_missing";
                    return false;
                }
                _population.owner_employed[destination] = saturating_add(
                    _population.owner_employed[destination], 1,
                    _saturation_count);
                if (source_signature.profession_id == _merchant_profession_id) {
                    local_merchant_population = std::max<int64_t>(
                        0, local_merchant_population - 1);
                }
                ++_building_owner_job_profession_changes;
            }
            source_group.filled_owner -= 1;
            target_group.filled_owner = saturating_add(
                target_group.filled_owner, 1, _saturation_count);
            owner_job_group_used[source_group_index - first] = 1;
            owner_job_group_used[target_group_index - first] = 1;
            ++_building_owner_job_reallocations;
        }
        }
    }
    int64_t local_owner = 0;
    int64_t local_employee = 0;
    int64_t local_unemployed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        local_owner = saturating_add(local_owner, _population.owner_employed[slot],
                                     _saturation_count);
        local_employee = saturating_add(local_employee, _population.employee_employed[slot],
                                        _saturation_count);
        const int64_t unemployed = std::max<int64_t>(
            0, _population.population[slot] - _population.owner_employed[slot] -
               _population.employee_employed[slot]);
        local_unemployed = saturating_add(local_unemployed, unemployed, _saturation_count);
    });
    replace_employment_metrics_for_cell(
        cell, local_owner, local_employee, local_unemployed);
    bool employment_identity_valid = true;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        if (is_merchant_slot(slot)) return;
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) {
            employment_identity_valid = false;
            return;
        }
        if (_signatures[signature].profession_id == _unemployed_profession_id) return;
        const int64_t employed = saturating_add(
            std::max<int64_t>(0, _population.owner_employed[slot]),
            std::max<int64_t>(0, _population.employee_employed[slot]),
            _saturation_count);
        if (employed != std::max<int64_t>(0, _population.population[slot])) {
            employment_identity_valid = false;
        }
    });
    if (!employment_identity_valid) {
        error = "non_unemployed_cohort_has_idle_population";
        return false;
    }
    std::vector<EventLeg> event_legs;
    if (trace_detail) {
        for (size_t i = 0; i < trace_handles.size(); ++i) {
            int32_t slot = -1;
            if (!_population.valid_handle(trace_handles[i], slot)) {
                // 该 cohort 已被 A1 迁移完全 drain（例如整职业裁光进池并释放）：
                // 记为归零 leg，subject 用快照 handle，便于审计闭合。
                if (trace_owner_before[i] != 0) {
                    event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT,
                                          static_cast<int64_t>(trace_handles[i]), -1,
                                          trace_owner_before[i], 0});
                }
                if (trace_employee_before[i] != 0) {
                    event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT,
                                          static_cast<int64_t>(trace_handles[i]), -1,
                                          trace_employee_before[i], 0});
                }
                continue;
            }
            const int64_t handle = static_cast<int64_t>(trace_handles[i]);
            if (trace_owner_before[i] != _population.owner_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_OWNER_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_owner_before[i],
                                      _population.owner_employed[slot]});
            }
            if (trace_employee_before[i] != _population.employee_employed[slot]) {
                event_legs.push_back({FIELD_COHORT_EMPLOYEE_EMPLOYED, SUBJECT_COHORT, handle,
                                      -1, trace_employee_before[i],
                                      _population.employee_employed[slot]});
            }
        }
    }
    trace_append(EVENT_EMPLOYMENT_SETTLED,
                 static_cast<int32_t>(Stage::BUILDING_EMPLOYMENT), cell,
                 SUBJECT_BUILDING_GROUP, cell, first, last - first,
                 local_owner, local_employee, local_unemployed, last - first,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

void NativeEconomyRuntime::replace_employment_metrics_for_cell(
        int32_t cell, int64_t owner_jobs, int64_t employee_jobs,
        int64_t unemployed_population) {
    if (cell < 0 || cell >= _cell_count) return;
    const size_t cells = static_cast<size_t>(_cell_count);
    if (_employment_metrics_epoch_by_cell.size() != cells) {
        _employment_metrics_epoch_by_cell.assign(
            cells, std::numeric_limits<int64_t>::min());
        _employment_owner_jobs_by_cell.assign(cells, 0);
        _employment_employee_jobs_by_cell.assign(cells, 0);
        _employment_unemployed_by_cell.assign(cells, 0);
    }
    const size_t index = static_cast<size_t>(cell);
    if (_employment_metrics_epoch_by_cell[index] == _epoch_id) {
        _filled_owner_jobs = saturating_sub(
            _filled_owner_jobs, _employment_owner_jobs_by_cell[index],
            _saturation_count);
        _filled_employee_jobs = saturating_sub(
            _filled_employee_jobs, _employment_employee_jobs_by_cell[index],
            _saturation_count);
        _unemployed_population = saturating_sub(
            _unemployed_population, _employment_unemployed_by_cell[index],
            _saturation_count);
    }
    _employment_metrics_epoch_by_cell[index] = _epoch_id;
    _employment_owner_jobs_by_cell[index] = std::max<int64_t>(0, owner_jobs);
    _employment_employee_jobs_by_cell[index] = std::max<int64_t>(0, employee_jobs);
    _employment_unemployed_by_cell[index] = std::max<int64_t>(
        0, unemployed_population);
    _filled_owner_jobs = saturating_add(
        _filled_owner_jobs, _employment_owner_jobs_by_cell[index],
        _saturation_count);
    _filled_employee_jobs = saturating_add(
        _filled_employee_jobs, _employment_employee_jobs_by_cell[index],
        _saturation_count);
    _unemployed_population = saturating_add(
        _unemployed_population, _employment_unemployed_by_cell[index],
        _saturation_count);
}

bool NativeEconomyRuntime::reconcile_building_employment_after_population_change(
        const std::vector<int32_t> &affected_cells, std::string &error) {
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    thread_local std::vector<int32_t> priority;
    thread_local std::vector<int64_t> sig_population;
    thread_local std::vector<int64_t> sig_owner_filled;
    thread_local std::vector<int64_t> sig_owner_distributed;
    thread_local std::vector<int64_t> profession_capacity;
    thread_local std::vector<int64_t> profession_filled;
    thread_local std::vector<int64_t> profession_prefix;
    thread_local std::vector<int64_t> profession_distributed;

    thread_local std::vector<int32_t> stable_cells;
    stable_cells.assign(affected_cells.begin(), affected_cells.end());
    std::sort(stable_cells.begin(), stable_cells.end());
    stable_cells.erase(std::unique(stable_cells.begin(), stable_cells.end()),
                       stable_cells.end());

    for (int32_t cell : stable_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        const int32_t first = _building_cell_offsets[cell];
        const int32_t last = _building_cell_offsets[cell + 1];
        sig_population.assign(_signatures.size(), 0);
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t sig = _population.signature_id[slot];
            if (sig < sig_population.size()) {
                sig_population[sig] = saturating_add(sig_population[sig],
                    std::max<int64_t>(0, _population.population[slot]), _saturation_count);
            }
        });

        priority.clear();
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true)) {
                group.filled_owner = 0;
                if (group.type_id >= 0 &&
                    group.type_id < static_cast<int32_t>(_building_types.size())) {
                    const BuildingType &type = _building_types[group.type_id];
                    for (int32_t r = 0; r < type.employee_count; ++r)
                        _building_employee_filled[group.employee_fill_begin + r] = 0;
                }
                continue;
            }
            priority.push_back(g);
        }
        std::stable_sort(priority.begin(), priority.end(), [&](int32_t a, int32_t b) {
            const BuildingGroup &ga = _buildings[a];
            const BuildingGroup &gb = _buildings[b];
            if (ga.realized_profit_margin_q16 != gb.realized_profit_margin_q16)
                return ga.realized_profit_margin_q16 > gb.realized_profit_margin_q16;
            if (ga.planned_utilization_q16 != gb.planned_utilization_q16)
                return ga.planned_utilization_q16 > gb.planned_utilization_q16;
            return a < b;
        });

        sig_owner_filled.assign(_signatures.size(), 0);
        for (int32_t g : priority) {
            BuildingGroup &group = _buildings[g];
            const int32_t sig = group.owner_signature_id;
            if (sig < 0 || sig >= static_cast<int32_t>(sig_population.size())) {
                error = "building_owner_signature_invalid_after_population_change";
                return false;
            }
            const int64_t available = std::max<int64_t>(
                0, sig_population[sig] - sig_owner_filled[sig]);
            group.filled_owner = std::min(
                std::max<int64_t>(0, group.filled_owner), available);
            sig_owner_filled[sig] = saturating_add(
                sig_owner_filled[sig], group.filled_owner, _saturation_count);
        }

        profession_capacity.assign(professions, 0);
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) return;
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            if (profession == _unemployed_profession_id) return;
            const int64_t owner = std::min(sig_owner_filled[sig],
                std::max<int64_t>(0, _population.population[slot]));
            profession_capacity[profession] = saturating_add(
                profession_capacity[profession],
                std::max<int64_t>(0, _population.population[slot] - owner),
                _saturation_count);
        });
        profession_filled.assign(professions, 0);
        for (int32_t g : priority) {
            BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t index = group.employee_fill_begin + r;
                const int64_t available = std::max<int64_t>(
                    0, profession_capacity[role.profession_id] -
                        profession_filled[role.profession_id]);
                _building_employee_filled[index] = std::min(
                    std::max<int64_t>(0, _building_employee_filled[index]), available);
                profession_filled[role.profession_id] = saturating_add(
                    profession_filled[role.profession_id],
                    _building_employee_filled[index], _saturation_count);
            }
        }

        sig_owner_distributed.assign(_signatures.size(), 0);
        profession_prefix.assign(professions, 0);
        profession_distributed.assign(professions, 0);
        int64_t owner_after = 0;
        int64_t employee_after = 0;
        int64_t unemployed_after = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t sig = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t profession = _signatures[sig].profession_id;
            const int64_t population = std::max<int64_t>(0, _population.population[slot]);
            const int64_t owner = std::min(population, std::max<int64_t>(
                0, sig_owner_filled[sig] - sig_owner_distributed[sig]));
            sig_owner_distributed[sig] = saturating_add(
                sig_owner_distributed[sig], owner, _saturation_count);
            int64_t employee = 0;
            if (!is_merchant_slot(slot) && profession != _unemployed_profession_id) {
                const int64_t capacity = std::max<int64_t>(0, population - owner);
                profession_prefix[profession] = saturating_add(
                    profession_prefix[profession], capacity, _saturation_count);
                const int64_t next = profession_capacity[profession] > 0
                    ? mul_div_sat(profession_filled[profession],
                        profession_prefix[profession], profession_capacity[profession],
                        _saturation_count) : 0;
                employee = std::min(capacity, std::max<int64_t>(
                    0, next - profession_distributed[profession]));
                profession_distributed[profession] = next;
            }
            _population.owner_employed[slot] = owner;
            _population.employee_employed[slot] = employee;
            owner_after = saturating_add(owner_after, owner, _saturation_count);
            employee_after = saturating_add(employee_after, employee, _saturation_count);
            unemployed_after = saturating_add(unemployed_after,
                std::max<int64_t>(0, population - owner - employee), _saturation_count);
        });
        replace_employment_metrics_for_cell(
            cell, owner_after, employee_after, unemployed_after);
    }
    return true;
}

bool NativeEconomyRuntime::run_building_production_cell(
        int32_t cell, ProductionResult &result, std::string &error) {
    ProductionResult *previous_sink = _production_result_sink;
    _production_result_sink = &result;
    int64_t &_saturation_count = result.saturation_count;
    int64_t &_processed_building_groups = result.processed_building_groups;
    int64_t &_merchant_procurement_budget = result.merchant_procurement_budget;
    int64_t &_merchant_procurement_opportunity = result.merchant_procurement_opportunity;
    int64_t &_merchant_procurement_allocated = result.merchant_procurement_allocated;
    int64_t &_merchant_procurement_unspent_allocated = result.merchant_procurement_unspent_allocated;
    int64_t &_merchant_procurement_reserved = result.merchant_procurement_reserved;
    int64_t &_merchant_procurement_spent = result.merchant_procurement_spent;
    int64_t &_owner_working_capital_allocated = result.owner_working_capital_allocated;
    int64_t &_working_capital_scale_error_bound_q16 =
        result.working_capital_scale_error_bound_q16;
    int64_t &_building_resource_capacity_checks =
        result.building_resource_capacity_checks;
    int64_t &_building_resource_limited_groups = result.building_resource_limited_groups;
    int64_t &_building_resource_capacity_limited_groups =
        result.building_resource_capacity_limited_groups;
    int64_t &_building_resource_generated = result.building_resource_generated;
    int64_t &_building_resource_consumed = result.building_resource_consumed;
    int64_t &_production_inputs_consumed = result.production_inputs_consumed;
    int64_t &_production_output_stock = result.production_output_stock;
    int64_t &_production_output_discarded = result.production_output_discarded;
    int64_t &_production_output_supported = result.production_output_supported;
    int64_t &_producer_revenue = result.producer_revenue;
    int64_t &_producer_support_money_issued = result.producer_support_money_issued;
    int64_t &_explicit_money_mint = result.explicit_money_mint;
    int64_t &_bullion_money_issued = result.bullion_money_issued;
    int64_t &_bullion_stock_consumed = result.bullion_stock_consumed;
    int64_t &_gold_accepted = result.gold_accepted;
    int64_t &_silver_accepted = result.silver_accepted;
    int64_t &_gold_money_issued = result.gold_money_issued;
    int64_t &_silver_money_issued = result.silver_money_issued;
    int64_t &_cycle_flow_produced = result.cycle_flow_produced;
    int64_t &_cycle_flow_consumed = result.cycle_flow_consumed;
    int64_t &_cycle_flow_discarded = result.cycle_flow_discarded;
    int64_t &_building_wages_paid = result.building_wages_paid;
    int64_t &_building_wages_unpaid = result.building_wages_unpaid;
    int64_t &_building_base_wages_paid = result.building_base_wages_paid;
    int64_t &_building_base_wages_due = result.building_base_wages_due;
    int64_t &_building_bonus_paid = result.building_bonus_paid;
    int64_t &_building_bonus_due = result.building_bonus_due;
    int64_t &_wage_suspended_building_groups = result.wage_suspended_building_groups;
    int64_t &_desired_business_demand = result.desired_business_demand;
    int64_t &_funded_business_demand = result.funded_business_demand;
    int64_t &_unfunded_business_demand = result.unfunded_business_demand;
    int64_t &_market_signal_updates = result.market_signal_updates;
    double &_market_signal_ms = result.market_signal_ms;
    std::vector<OwnerRetainedOutput> &_owner_retained_outputs = result.retained_outputs;
    struct Offer {
        int32_t good = -1;
        int32_t owner_slot = -1;
        int32_t group = -1;
        int64_t qty = 0;
        int64_t retained = 0;
        int64_t sellable = 0;
    };
    thread_local std::vector<Offer> offers;
    offers.clear();
    const int32_t market = _market.cell_to_market[cell];
    const int32_t begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    int64_t merchant_opening_cash = 0;
    for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
        merchant_opening_cash = saturating_add(merchant_opening_cash,
            std::max<int64_t>(0, _population.funds[_merchant_slots[k]]), _saturation_count);
    }
    int64_t merchant_procurement_remaining = mul_div_sat(
        merchant_opening_cash, Q16_ONE - _merchant_procurement_cash_reserve_q16,
        Q16_ONE, _saturation_count);
    _merchant_procurement_budget = saturating_add(
        _merchant_procurement_budget, merchant_procurement_remaining, _saturation_count);
    _merchant_procurement_reserved = saturating_add(
        _merchant_procurement_reserved,
        merchant_opening_cash - merchant_procurement_remaining, _saturation_count);
    const bool trace_detail = trace_detail_for_cell(cell);
    thread_local std::vector<int32_t> trace_cell_slots;
    thread_local std::vector<int64_t> trace_cell_funds;
    thread_local std::vector<int64_t> trace_cell_income;
    thread_local std::vector<int64_t> trace_cell_expense;
    thread_local std::vector<int64_t> trace_market_stock;
    thread_local std::vector<int64_t> trace_resource_delta;
    trace_cell_slots.clear(); trace_cell_funds.clear(); trace_cell_income.clear();
    trace_cell_expense.clear(); trace_market_stock.clear(); trace_resource_delta.clear();
    if (trace_detail) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            trace_cell_slots.push_back(slot);
            trace_cell_funds.push_back(_population.funds[slot]);
            trace_cell_income.push_back(_population.epoch_income[slot]);
            trace_cell_expense.push_back(_population.epoch_expense[slot]);
        });
        trace_market_stock.resize(_market.good_count);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            trace_market_stock[good] = _market.stock[_market.index(market, good)];
        }
        trace_resource_delta.resize(_resource_ids.size());
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            trace_resource_delta[resource] =
                _resource_deltas[resource * static_cast<size_t>(_cell_count) + cell];
        }
    }
    thread_local std::vector<BuildingGroup> trace_before;
    trace_before.clear();
    if (trace_detail) {
        trace_before.reserve(static_cast<size_t>(std::max(0, end - begin)));
        for (int32_t g = begin; g < end; ++g) trace_before.push_back(_buildings[g]);
    }
    auto produces_cycle_flow = [&](const BuildingType &type) {
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (_good_storage_modes[good] == 1) return true;
        }
        return false;
    };
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        group.last_capacity_q16 = 0;
        group.last_input = group.last_output = group.last_sold = group.last_discarded = 0;
        group.last_resource = group.last_revenue = 0;
        group.last_resource_generated = 0;
        group.last_input_cost = group.last_wages_paid = group.last_wages_due = 0;
        group.last_operating_cost = 0;
        group.purchase_intent_capacity_q16 = 0;
        group.last_base_wages_paid = group.last_base_wages_due = 0;
        group.last_bonus_paid = group.last_bonus_due = 0;
        group.wage_suspended = 0;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t input = 0; input < type.input_count; ++input) {
            _building_last_input_selected_goods[
                group.last_input_selection_begin + input] = -1;
        }
        if (!building_available(cell, group.type_id, true)) continue;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage_due = saturating_mul(
                saturating_mul(_building_employee_filled[role_index],
                               _building_role_contract_wage[role_index],
                               _saturation_count),
                std::max(1, _epoch_days), _saturation_count);
            _building_role_base_wage_due[role_index] = wage_due;
            _building_role_base_wage_paid[role_index] = 0;
            _building_role_bonus_due[role_index] = 0;
            _building_role_bonus_paid[role_index] = 0;
            group.last_base_wages_due = saturating_add(
                group.last_base_wages_due, wage_due, _saturation_count);
        }
        group.last_wages_due = group.last_base_wages_due;
    }
    thread_local std::vector<int32_t> payroll_owners;
    payroll_owners.clear();
    for (int32_t g = begin; g < end; ++g) {
        if (_buildings[g].count > 0 && building_available(cell, _buildings[g].type_id, true))
            payroll_owners.push_back(_buildings[g].owner_signature_id);
    }
    std::sort(payroll_owners.begin(), payroll_owners.end());
    payroll_owners.erase(std::unique(payroll_owners.begin(), payroll_owners.end()),
                         payroll_owners.end());
    thread_local std::vector<int32_t> retention_owner_slots;
    thread_local std::vector<int64_t> retention_targets;
    thread_local std::vector<int64_t> retention_used;
    thread_local std::vector<int64_t> retention_food_targets;
    thread_local std::vector<int64_t> retention_food_used;
    thread_local std::vector<uint8_t> retention_food_staple_route;
    thread_local std::vector<int64_t> retention_clothing_targets;
    thread_local std::vector<int64_t> retention_clothing_used;
    thread_local std::vector<int64_t> retention_variant_scores;
    thread_local std::vector<int64_t> retention_variant_prices;
    thread_local std::vector<int64_t> retention_need_score_sums;
    thread_local std::vector<int64_t> retention_need_composites;
    thread_local std::vector<int64_t> retention_need_environment;
    thread_local std::vector<uint8_t> retention_produced_goods;
    retention_owner_slots.assign(payroll_owners.size(), -1);
    retention_targets.assign(payroll_owners.size() * static_cast<size_t>(_market.good_count), 0);
    retention_used.assign(retention_targets.size(), 0);
    retention_food_targets.assign(payroll_owners.size(), 0);
    retention_food_used.assign(payroll_owners.size(), 0);
    retention_food_staple_route.assign(payroll_owners.size(), uint8_t{0});
    retention_clothing_targets.assign(payroll_owners.size(), 0);
    retention_clothing_used.assign(payroll_owners.size(), 0);
    retention_produced_goods.assign(retention_targets.size(), uint8_t{0});
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        const auto owner = std::lower_bound(
            payroll_owners.begin(), payroll_owners.end(), group.owner_signature_id);
        if (owner == payroll_owners.end() || *owner != group.owner_signature_id) continue;
        const size_t owner_index = static_cast<size_t>(owner - payroll_owners.begin());
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            retention_produced_goods[
                owner_index * static_cast<size_t>(_market.good_count) + good] = 1;
        }
    }
    const EnvironmentSample retention_environment = environment_sample_for_cell(cell);
    build_demand_basis_cached(cell, market, retention_environment,
                       retention_variant_scores, retention_variant_prices,
                       retention_need_score_sums, retention_need_composites,
                       retention_need_environment, _saturation_count);
    for (size_t owner = 0; owner < payroll_owners.size(); ++owner) {
        const int32_t owner_slot = find_cohort_slot(cell, payroll_owners[owner]);
        retention_owner_slots[owner] = owner_slot;
        if (owner_slot < 0) continue;
        const uint32_t signature_id = _population.signature_id[owner_slot];
        if (signature_id >= _signatures.size()) continue;
        const Signature &signature = _signatures[signature_id];
        const Plan &plan = _plans[signature.plan_id];
        const int64_t population = std::max<int64_t>(0, _population.population[owner_slot]);
        bool produces_survival_food = false;
        bool produces_staple_food = false;
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const size_t index = owner * static_cast<size_t>(_market.good_count) + good;
            if (retention_produced_goods[index] != 0 &&
                _survival_food_good_mask[good] != 0) {
                produces_survival_food = true;
                produces_staple_food = produces_staple_food ||
                    _survival_staple_good_mask[good] != 0;
            }
        }
        const int64_t temperature_exposure_q16 = std::clamp<int64_t>(
            (Q16_ONE / 2 - retention_environment.temperature_q16) * 2,
            0, Q16_ONE);
        const int64_t cold_exposure_q16 = std::max<int64_t>(
            temperature_exposure_q16,
            std::clamp<int64_t>(retention_environment.snow_q16, 0, Q16_ONE));
        int64_t clothing_retention_q16 = 0;
        if (cold_exposure_q16 > Q16_ONE - _survival_production_target_q16) {
            clothing_retention_q16 = Q16_ONE - mul_div_sat(
                Q16_ONE - _survival_production_target_q16,
                Q16_ONE, cold_exposure_q16, _saturation_count);
        }
        int64_t survival_food_desired = 0;
        int64_t produced_food_desired = 0;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            const int32_t stable_need = need.stable_id;
            const bool survival_food = std::find(
                _survival_food_need_stable_ids.begin(),
                _survival_food_need_stable_ids.end(), stable_need) !=
                _survival_food_need_stable_ids.end();
            const int64_t ordinary_desired = desired_need_units(
                owner_slot, need_index, _epoch_days,
                retention_need_environment[need_index],
                retention_need_composites[need_index], _saturation_count);
            if (survival_food) {
                const int64_t food_desired = survival_required_units(
                    owner_slot, stable_need, _epoch_days,
                    retention_environment, _saturation_count);
                survival_food_desired = saturating_add(
                    survival_food_desired, food_desired,
                    _saturation_count);
            }
            int64_t desired = ordinary_desired;
            if (stable_need == _survival_clothing_need_stable_id &&
                population > 0 && clothing_retention_q16 > 0) {
                const int64_t full_desired = survival_required_units(
                    owner_slot, stable_need, _epoch_days,
                    retention_environment, _saturation_count);
                desired = std::max<int64_t>(desired, mul_div_sat(
                    full_desired, clothing_retention_q16, Q16_ONE,
                    _saturation_count));
                retention_clothing_targets[owner] = std::max<int64_t>(
                    retention_clothing_targets[owner], desired);
            }
            const int64_t score_sum = retention_need_score_sums[need_index];
            if (desired <= 0 || score_sum <= 0) continue;
            int64_t score_prefix = 0;
            int64_t allocated = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                const VariantChoice &variant = _variants[variant_id];
                score_prefix = saturating_add(
                    score_prefix, retention_variant_scores[variant_id], _saturation_count);
                const int64_t next = mul_div_sat(
                    desired, score_prefix, score_sum, _saturation_count);
                const int64_t units = std::max<int64_t>(0, next - allocated);
                allocated = next;
                if (units <= 0) continue;
                // 复合 variant：逐组件判定。业主自家产出的组件自留，
                // 未产出的组件正常走市场购买，不再要求"产齐全部才可自用"。
                for (int32_t c = 0; c < variant.component_count; ++c) {
                    const NeedComponent &component = _components[
                        variant.component_begin + c];
                    const size_t index = owner * static_cast<size_t>(
                        _market.good_count) + component.good_id;
                    if (retention_produced_goods[index] == 0) continue;
                    const int64_t quantity = mul_div_sat(
                        units, component.qty_per_need, GOODS_SCALE,
                        _saturation_count);
                    if (survival_food) {
                        produced_food_desired = saturating_add(
                            produced_food_desired, quantity, _saturation_count);
                    } else {
                        retention_targets[index] = saturating_add(
                            retention_targets[index], quantity, _saturation_count);
                    }
                }
            }
        }
        if (produces_survival_food && population > 0) {
            // Staple output may satisfy the other survival-food needs through
            // emergency substitution, so retain against the complete healthy
            // food basket rather than the staple row alone.
            const int64_t desired = survival_food_desired;
            const int64_t numerator = saturating_add(saturating_mul(
                desired, _survival_production_target_q16,
                _saturation_count), Q16_ONE - 1, _saturation_count);
            retention_food_targets[owner] = std::max<int64_t>(
                numerator / Q16_ONE, produced_food_desired);
            retention_food_staple_route[owner] = produces_staple_food ? 1 : 0;
        }
    }
    const bool has_cell_signals =
        _market_signals.cell_offsets.size() == static_cast<size_t>(_cell_count + 1);
    const int32_t cell_signal_begin = has_cell_signals
        ? _market_signals.cell_offsets[cell] : 0;
    const int32_t cell_signal_end = has_cell_signals
        ? _market_signals.cell_offsets[cell + 1] : 0;
    const size_t cell_signal_count = static_cast<size_t>(
        std::max(0, cell_signal_end - cell_signal_begin));
    thread_local std::vector<int64_t> retained_by_signal;
    retained_by_signal.assign(cell_signal_count, 0);
    auto physical_input_quantity = [&](int64_t effective,
                                       const InputCandidate &candidate) -> int64_t {
        int64_t physical = mul_div_sat(
            effective, Q16_ONE, candidate.efficiency_q16, _saturation_count);
        if (mul_div_sat(physical, candidate.efficiency_q16, Q16_ONE,
                        _saturation_count) < effective)
            physical = saturating_add(physical, 1, _saturation_count);
        return physical;
    };
    auto soft_input_bound_q16 = [&](const ProductionInput &input,
                                    int64_t raw_capacity_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return Q16_ONE;
        raw_capacity_q16 = std::clamp<int64_t>(raw_capacity_q16, 0, Q16_ONE);
        return std::clamp<int64_t>(
            Q16_ONE - required + mul_div_sat(
                raw_capacity_q16, required, Q16_ONE, _saturation_count),
            0, Q16_ONE);
    };
    auto input_purchase_scale_q16 = [&](const ProductionInput &input,
                                        int64_t output_scale_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return 0;
        const int64_t floor_q16 = Q16_ONE - required;
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        if (output_scale_q16 <= floor_q16) return 0;
        const int64_t delta = output_scale_q16 - floor_q16;
        return std::min<int64_t>(
            Q16_ONE, mul_div_sat(delta, Q16_ONE, required, _saturation_count));
    };
    auto scaled_input_quantity = [&](int64_t full_physical,
                                     int64_t purchase_scale_q16) -> int64_t {
        purchase_scale_q16 = std::clamp<int64_t>(purchase_scale_q16, 0, Q16_ONE);
        if (full_physical <= 0 || purchase_scale_q16 <= 0) return 0;
        const int64_t numerator = saturating_mul(
            full_physical, purchase_scale_q16, _saturation_count);
        return std::max<int64_t>(1, saturating_add(
            numerator, Q16_ONE - 1, _saturation_count) / Q16_ONE);
    };
    auto select_input_candidate = [&](const ProductionInput &input,
                                      bool require_stock,
                                      int64_t effective_required) -> int32_t {
        int32_t best = -1;
        int64_t best_capacity_q16 = -1;
        int64_t best_effective_price = std::numeric_limits<int64_t>::max();
        for (int32_t c = input.candidate_begin;
             c < input.candidate_begin + input.candidate_count; ++c) {
            const InputCandidate &candidate = _building_input_candidates[c];
            if (!good_available(cell, candidate.good_id, true)) continue;
            if (require_stock &&
                _market.stock[_market.index(market, candidate.good_id)] <= 0) continue;
            int64_t capacity_q16 = Q16_ONE;
            if (require_stock && effective_required > 0) {
                const int64_t physical_required = physical_input_quantity(
                    effective_required, candidate);
                capacity_q16 = physical_required > 0 ? std::min<int64_t>(
                    Q16_ONE, mul_div_sat(
                        _market.stock[_market.index(market, candidate.good_id)],
                        Q16_ONE, physical_required, _saturation_count)) : Q16_ONE;
            }
            const int64_t effective_price = mul_div_sat(
                _market.price[_market.index(market, candidate.good_id)], Q16_ONE,
                candidate.efficiency_q16, _saturation_count);
            if (capacity_q16 > best_capacity_q16 ||
                (capacity_q16 == best_capacity_q16 &&
                 (effective_price < best_effective_price ||
                  (effective_price == best_effective_price &&
                   (best < 0 || candidate.good_id <
                    _building_input_candidates[best].good_id))))) {
                best = c;
                best_capacity_q16 = capacity_q16;
                best_effective_price = effective_price;
            }
        }
        return best;
    };
    auto desired_scale_for_group = [&](const BuildingGroup &group,
                                       const BuildingType &type) -> int64_t {
        const int64_t owner_demand = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        int64_t scale = owner_demand > 0 ? std::min<int64_t>(Q16_ONE, mul_div_sat(
            group.filled_owner, Q16_ONE, owner_demand, _saturation_count)) : 0;
        scale = std::min<int64_t>(scale, group.planned_utilization_q16);
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t demand = saturating_mul(
                group.count, role.slots_per_building, _saturation_count);
            const int64_t filled = _building_employee_filled[group.employee_fill_begin + r];
            scale = std::min<int64_t>(scale, demand > 0 ? std::min<int64_t>(
                Q16_ONE, mul_div_sat(filled, Q16_ONE, demand, _saturation_count)) : Q16_ONE);
        }
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            if (select_input_candidate(item, false, saturating_mul(
                    building_days, item.quantity, _saturation_count)) < 0) {
                scale = std::min<int64_t>(scale, soft_input_bound_q16(item, 0));
            }
        }
        return std::clamp<int64_t>(scale, 0, Q16_ONE);
    };
    auto group_input_cost_at_scale = [&](const BuildingGroup &group,
                                         const BuildingType &type,
                                         int64_t output_scale_q16,
                                         bool require_stock) -> int64_t {
        int64_t total_cost = 0;
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        for (int32_t input_index = 0; input_index < type.input_count; ++input_index) {
            const ProductionInput &item = _building_inputs[type.input_begin + input_index];
            const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                item, output_scale_q16);
            if (purchase_scale_q16 <= 0) continue;
            const int64_t effective = saturating_mul(
                building_days, item.quantity, _saturation_count);
            const int32_t selected = select_input_candidate(item, require_stock, effective);
            if (selected < 0) return std::numeric_limits<int64_t>::max();
            const InputCandidate &candidate = _building_input_candidates[selected];
            const int64_t qty = scaled_input_quantity(
                physical_input_quantity(effective, candidate), purchase_scale_q16);
            total_cost = saturating_add(total_cost, mul_div_sat(
                qty, _market.price[_market.index(market, candidate.good_id)],
                GOODS_SCALE, _saturation_count), _saturation_count);
        }
        return total_cost;
    };

    struct WorkingCapitalCandidate {
        int32_t group = -1;
        int64_t score_q16 = 0;
        int64_t desired_cost = 0;
        bool critical = false;
    };
    thread_local std::vector<WorkingCapitalCandidate> candidates;
    std::fill(_building_funded_capacity_q16.begin() + begin,
              _building_funded_capacity_q16.begin() + end, 0);
    std::fill(_building_working_capital_allocated.begin() + begin,
              _building_working_capital_allocated.begin() + end, 0);
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        if (owner_slot < 0) continue;
        int64_t wage_commitment = 0;
        int64_t expected_revenue = 0;
        int64_t filled_owner = 0;
        candidates.clear();
        candidates.reserve(static_cast<size_t>(std::max(0, end - begin)));
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature || group.count <= 0 ||
                group.operating_state != 0 || !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            wage_commitment = saturating_add(
                wage_commitment, group.last_base_wages_due, _saturation_count);
            expected_revenue = saturating_add(
                expected_revenue, group.last_expected_revenue, _saturation_count);
            filled_owner = saturating_add(filled_owner, group.filled_owner, _saturation_count);
            const int64_t desired_scale = desired_scale_for_group(group, type);
            group.purchase_intent_capacity_q16 = desired_scale;
            const int64_t desired_cost = group_input_cost_at_scale(
                group, type, desired_scale, false);
            int64_t survival_pressure = 0;
            int64_t ordinary_pressure = 0;
            int64_t downstream_pressure = 0;
            bool critical = false;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t idx = _market.index(market, good);
                const int64_t shortage = std::clamp<int64_t>(
                    _market.last_shortage_q16[idx], 0, Q16_ONE);
                const bool survival = _survival_food_good_mask[good] != 0 ||
                    _survival_clothing_good_mask[good] != 0;
                if (survival) {
                    survival_pressure = std::max(survival_pressure, shortage);
                    critical = true;
                } else {
                    ordinary_pressure = std::max(ordinary_pressure, shortage);
                }
                const int32_t signal = market_signal_index(cell, good);
                if (signal >= 0) {
                    const int64_t demand = _market_signals.business_demand_ema[signal];
                    const int64_t stock = _market.stock[idx];
                    if (demand > 0) {
                        downstream_pressure = std::max<int64_t>(downstream_pressure,
                            std::clamp<int64_t>(mul_div_sat(
                                std::max<int64_t>(0, demand - stock), Q16_ONE,
                                std::max<int64_t>(1, demand), _saturation_count), 0, Q16_ONE));
                        critical = true;
                    }
                }
            }
            const int64_t contribution = std::clamp<int64_t>(
                Q16_ONE + group.last_margin_gap_q16, -Q16_ONE, 2 * Q16_ONE);
            const int64_t score = saturating_add(saturating_add(
                4 * survival_pressure, 3 * downstream_pressure, _saturation_count),
                saturating_add(2 * ordinary_pressure, contribution, _saturation_count),
                _saturation_count);
            if (desired_cost > 0 && desired_cost != std::numeric_limits<int64_t>::max() &&
                (score > 0 || critical)) {
                candidates.push_back({g, score, desired_cost, critical});
            }
        }
        const int64_t owner_cash = std::max<int64_t>(0, _population.funds[owner_slot]);
        // Household clearing already protected this period's input float before
        // paying livelihood. Reserve only the wage gap here; holding livelihood
        // a second time permanently cuts the same owner's funded capacity.
        const int64_t wage_cash_gap = std::max<int64_t>(
            0, saturating_sub(wage_commitment, expected_revenue, _saturation_count));
        int64_t budget = std::max<int64_t>(
            0, owner_cash - std::min(owner_cash, wage_cash_gap));
        std::stable_sort(candidates.begin(), candidates.end(),
            [](const WorkingCapitalCandidate &a, const WorkingCapitalCandidate &b) {
                if (a.score_q16 != b.score_q16) return a.score_q16 > b.score_q16;
                return a.group < b.group;
            });
        auto allocate = [&](WorkingCapitalCandidate &candidate, int64_t target) {
            const int64_t current = _building_working_capital_allocated[candidate.group];
            const int64_t grant = std::min<int64_t>(budget, std::max<int64_t>(0, target - current));
            _building_working_capital_allocated[candidate.group] += grant;
            budget -= grant;
            _owner_working_capital_allocated = saturating_add(
                _owner_working_capital_allocated, grant, _saturation_count);
        };
        for (WorkingCapitalCandidate &candidate : candidates) {
            if (budget <= 0) break;
            if (candidate.critical) allocate(candidate, std::max<int64_t>(
                1, (candidate.desired_cost + 3) / 4));
        }
        for (WorkingCapitalCandidate &candidate : candidates) {
            if (budget <= 0) break;
            allocate(candidate, candidate.desired_cost);
        }
    }
    int64_t cell_opening_cash = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        cell_opening_cash = saturating_add(cell_opening_cash,
            std::max<int64_t>(0, _population.funds[slot]), _saturation_count);
    });
    int64_t producer_support_remaining = mul_div_sat(mul_div_sat(
        cell_opening_cash, _producer_support_monthly_cap_q16, Q16_ONE,
        _saturation_count), std::max(1, _epoch_days), 30, _saturation_count);
    auto process_phase = [&](bool cycle_flow_phase) -> bool {
        offers.clear();
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true)) continue;
            if (group.operating_state != 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (produces_cycle_flow(type) != cycle_flow_phase) continue;
            ++_processed_building_groups;
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            int64_t intent_scale_q16 = desired_scale_for_group(group, type);
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days), _saturation_count);
            const int64_t group_budget = g < static_cast<int32_t>(
                _building_working_capital_allocated.size())
                ? _building_working_capital_allocated[g] : 0;
            auto clamp_scale_to_group_budget = [&](int64_t output_scale_q16,
                                                   bool require_stock) -> int64_t {
                if (group_input_cost_at_scale(group, type, output_scale_q16,
                                              require_stock) <= group_budget) {
                    return output_scale_q16;
                }
                int64_t lo = 0;
                int64_t hi = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
                // Keep the allocation conservative. Eight probes leave at most
                // 1/256 of the requested utilization interval unresolved.
                for (int iter = 0; iter < 8; ++iter) {
                    const int64_t mid = (lo + hi + 1) / 2;
                    if (group_input_cost_at_scale(group, type, mid, require_stock) <= group_budget) lo = mid;
                    else hi = mid - 1;
                }
                _working_capital_scale_error_bound_q16 = std::max<int64_t>(
                    _working_capital_scale_error_bound_q16,
                    std::max<int64_t>(0, hi - lo));
                return lo;
            };
            int64_t scale_q16 = intent_scale_q16;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                const int32_t selected = select_input_candidate(item, true, effective);
                if (selected < 0) {
                    scale_q16 = std::min<int64_t>(
                        scale_q16, soft_input_bound_q16(item, 0));
                    continue;
                }
                const InputCandidate &candidate = _building_input_candidates[selected];
                const int64_t physical = physical_input_quantity(effective, candidate);
                int64_t raw_capacity_q16 = Q16_ONE;
                if (physical > 0) {
                    raw_capacity_q16 = std::min<int64_t>(Q16_ONE, mul_div_sat(
                        _market.stock[_market.index(market, candidate.good_id)], Q16_ONE,
                        physical, _saturation_count));
                }
                scale_q16 = std::min<int64_t>(
                    scale_q16, soft_input_bound_q16(item, raw_capacity_q16));
            }
            scale_q16 = clamp_scale_to_group_budget(scale_q16, true);
            const int64_t non_resource_scale_q16 = std::clamp<int64_t>(
                scale_q16, 0, Q16_ONE);
            bool resource_limited = false;
            bool resource_capacity_limited = false;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    if (base <= 0) continue;
                    if (item.mode == 1) ++_building_resource_capacity_checks;
                    const int64_t resource_scale = mul_div_sat(
                        available_resource_amount(item, cell), Q16_ONE, base, _saturation_count);
                    if (resource_scale < intent_scale_q16 || resource_scale < scale_q16)
                        resource_limited = true;
                    if (item.mode == 1 &&
                        (resource_scale < intent_scale_q16 || resource_scale < scale_q16)) {
                        resource_capacity_limited = true;
                    }
                    scale_q16 = std::min(scale_q16, resource_scale);
                }
            }
            intent_scale_q16 = std::clamp<int64_t>(intent_scale_q16, 0, Q16_ONE);
            scale_q16 = std::clamp<int64_t>(scale_q16, 0, Q16_ONE);
            if (resource_limited) ++_building_resource_limited_groups;
            if (resource_capacity_limited) ++_building_resource_capacity_limited_groups;
            group.purchase_intent_capacity_q16 = intent_scale_q16;
            group.last_capacity_q16 = scale_q16;
            _building_funded_capacity_q16[g] = scale_q16;
            if (type.behavior_id == 2) {
                const int64_t generation_scale_q16 = std::min<int64_t>(
                    non_resource_scale_q16,
                    std::max<int64_t>(scale_q16, type.generation_floor_q16));
                for (int32_t i = 0; i < type.generation_count; ++i) {
                    const ResourceAmount &item =
                        _building_resource_generation[type.generation_begin + i];
                    const int64_t qty = mul_div_sat(saturating_mul(
                        building_days, item.quantity, _saturation_count),
                        generation_scale_q16, Q16_ONE, _saturation_count);
                    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
                    _resource_deltas[idx] = saturating_add(
                        _resource_deltas[idx], qty, _saturation_count);
                    group.last_resource_generated = saturating_add(
                        group.last_resource_generated, qty, _saturation_count);
                    _building_resource_generated = saturating_add(
                        _building_resource_generated, qty, _saturation_count);
                }
            }
            if (scale_q16 == 0) continue;
            touch_accounting_slot(owner_slot);
            int64_t actual_cost = 0;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                    item, scale_q16);
                if (purchase_scale_q16 <= 0) continue;
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                const int32_t selected = select_input_candidate(item, true, effective);
                if (selected < 0) {
                    error = "building_input_candidate_selection_drift";
                    return false;
                }
                const InputCandidate &candidate = _building_input_candidates[selected];
                _building_last_input_selected_goods[
                    group.last_input_selection_begin + i] = candidate.good_id;
                const int64_t full_physical = physical_input_quantity(effective, candidate);
                const int64_t qty = scaled_input_quantity(
                    full_physical, purchase_scale_q16);
                _market.stock[_market.index(market, candidate.good_id)] -= qty;
                const int32_t signal = market_signal_index(cell, candidate.good_id);
                if (signal >= 0 && signal < static_cast<int32_t>(
                        _epoch_nonhousehold_withdrawals.size())) {
                    _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[signal], qty, _saturation_count);
                }
                actual_cost = saturating_add(actual_cost, mul_div_sat(
                    qty, _market.price[_market.index(market, candidate.good_id)],
                    GOODS_SCALE, _saturation_count), _saturation_count);
                group.last_input = saturating_add(group.last_input, qty, _saturation_count);
                _production_inputs_consumed = saturating_add(
                    _production_inputs_consumed, qty, _saturation_count);
                if (_good_storage_modes[candidate.good_id] == 1) {
                    _cycle_flow_consumed = saturating_add(
                        _cycle_flow_consumed, qty, _saturation_count);
                }
            }
            if (actual_cost > group_budget || actual_cost > _population.funds[owner_slot]) {
                error = "building_input_cost_preflight_drift";
                return false;
            }
            _population.funds[owner_slot] -= actual_cost;
            group.last_input_cost = actual_cost;
            group.last_operating_cost = saturating_add(
                actual_cost, group.last_wages_due, _saturation_count);
            _population.epoch_expense[owner_slot] = saturating_add(
                _population.epoch_expense[owner_slot], actual_cost, _saturation_count);
            trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                                  CASHFLOW_PRODUCTION_INPUT, 0, actual_cost);
            if (credit_local_merchants(cell, actual_cost,
                                       CASHFLOW_MERCHANT_BUSINESS,
                                       &_saturation_count) != actual_cost) {
                error = "building_input_has_no_merchant_owner";
                return false;
            }
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    if (item.mode == 1) continue;
                    const int64_t qty = mul_div_sat(saturating_mul(
                        building_days, item.quantity, _saturation_count),
                        scale_q16, Q16_ONE, _saturation_count);
                    consume_resource_amount(item, cell, qty);
                    group.last_resource = saturating_add(
                        group.last_resource, qty, _saturation_count);
                    _building_resource_consumed = saturating_add(
                        _building_resource_consumed, qty, _saturation_count);
                }
            }
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &item = _building_outputs[type.output_begin + i];
                const int64_t qty = mul_div_sat(saturating_mul(
                    building_days, item.quantity, _saturation_count),
                    scale_q16, Q16_ONE, _saturation_count);
                if (qty > 0) offers.push_back({item.good_id, owner_slot, g, qty, 0, qty});
                group.last_output = saturating_add(
                    group.last_output, qty, _saturation_count);
            }
        }
        std::stable_sort(offers.begin(), offers.end(), [](const Offer &a, const Offer &b) {
            if (a.good != b.good) return a.good < b.good;
            return a.group < b.group;
        });
        thread_local std::vector<int64_t> sellable_by_good;
        thread_local std::vector<int64_t> quota_by_good;
        thread_local std::vector<int64_t> purchase_value_by_good;
        thread_local std::vector<int64_t> budget_by_good;
        thread_local std::vector<int64_t> spent_by_good;
        thread_local std::vector<int64_t> weight_by_good;
        thread_local std::vector<int32_t> buy_factor_by_good;
        thread_local std::vector<int32_t> touched_goods;
        const size_t good_count = static_cast<size_t>(_market.good_count);
        sellable_by_good.resize(good_count);
        quota_by_good.resize(good_count);
        purchase_value_by_good.resize(good_count);
        budget_by_good.resize(good_count);
        spent_by_good.resize(good_count);
        weight_by_good.resize(good_count);
        buy_factor_by_good.resize(good_count);
        touched_goods.clear();
        int32_t last_touched = -1;
        for (Offer &offer : offers) {
            for (size_t owner = 0; owner < retention_owner_slots.size(); ++owner) {
                if (retention_owner_slots[owner] != offer.owner_slot) continue;
                const size_t index = owner * static_cast<size_t>(_market.good_count) + offer.good;
                if (_survival_food_good_mask[offer.good] != 0) {
                    if (retention_food_staple_route[owner] == 0 ||
                        _survival_staple_good_mask[offer.good] != 0) {
                        offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                            0, retention_food_targets[owner] - retention_food_used[owner]));
                        retention_food_used[owner] = saturating_add(
                            retention_food_used[owner], offer.retained, _saturation_count);
                    }
                } else if (_survival_clothing_good_mask[offer.good] != 0) {
                    offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                        0, retention_clothing_targets[owner] -
                            retention_clothing_used[owner]));
                    retention_clothing_used[owner] = saturating_add(
                        retention_clothing_used[owner], offer.retained,
                        _saturation_count);
                } else {
                    offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                        0, retention_targets[index] - retention_used[index]));
                    retention_used[index] = saturating_add(
                        retention_used[index], offer.retained, _saturation_count);
                }
                break;
            }
            offer.sellable = offer.qty - offer.retained;
            if (offer.retained > 0) {
                _owner_retained_outputs.push_back(
                    {offer.owner_slot, offer.good, offer.group, offer.retained});
                const int32_t signal = market_signal_index(cell, offer.good);
                if (signal >= cell_signal_begin && signal < cell_signal_end) {
                    const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
                    retained_by_signal[local_signal] = saturating_add(
                        retained_by_signal[local_signal], offer.retained, _saturation_count);
                }
            }
            if (_good_monetary_issue_values[offer.good] <= 0 && offer.sellable > 0) {
                sellable_by_good[offer.good] = saturating_add(
                    sellable_by_good[offer.good], offer.sellable, _saturation_count);
                if (offer.good != last_touched) {
                    // Offers are sorted by good. Reset only the sparse goods
                    // touched by this cell instead of clearing every catalog good.
                    sellable_by_good[offer.good] = offer.sellable;
                    quota_by_good[offer.good] = 0;
                    purchase_value_by_good[offer.good] = 0;
                    budget_by_good[offer.good] = 0;
                    spent_by_good[offer.good] = 0;
                    weight_by_good[offer.good] = 0;
                    buy_factor_by_good[offer.good] = 0;
                    touched_goods.push_back(offer.good);
                    last_touched = offer.good;
                }
            }
        }
        int64_t total_weight = 0;
        int64_t total_purchase_value = 0;
        for (int32_t good : touched_goods) {
            const int32_t signal = market_signal_index(cell, good);
            const int64_t realized = signal >= 0
                ? _market_signals.realized_withdrawal_ema[signal] : 0;
            const int32_t flow = trade_flow_index(cell, good, false);
            const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
            const int64_t cold_start_supply = sellable_by_good[good] /
                std::max(1, _epoch_days);
            const int64_t target = merchant_inventory_target(
                market, good, signal, realized, exports, cold_start_supply,
                _saturation_count);
            if (_good_storage_modes[good] == 1) {
                // Cycle-flow goods cannot persist as inventory. Let the producer
                // attempt a low-price same-cycle clearing/support pass before the
                // remaining transient stock is discarded at the cell boundary.
                quota_by_good[good] = std::max<int64_t>(0, sellable_by_good[good]);
            } else {
                quota_by_good[good] = std::min<int64_t>(
                    sellable_by_good[good], std::max<int64_t>(
                        0, target - _market.stock[_market.index(market, good)]));
            }
            buy_factor_by_good[good] = effective_merchant_buy_factor_q16(
                market, good, target,
                _market.stock[_market.index(market, good)], _saturation_count);
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                _market.price[_market.index(market, good)],
                buy_factor_by_good[good], Q16_ONE, _saturation_count));
            const int64_t base_weight = mul_div_sat(
                quota_by_good[good], buy_price, GOODS_SCALE, _saturation_count);
            purchase_value_by_good[good] = base_weight;
            total_purchase_value = saturating_add(
                total_purchase_value, base_weight, _saturation_count);
            int64_t priority_q16 = Q16_ONE;
            if (_survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0) {
                priority_q16 = saturating_add(
                    priority_q16, 2 * Q16_ONE, _saturation_count);
            }
            const int64_t market_index = _market.index(market, good);
            priority_q16 = saturating_add(priority_q16, mul_div_sat(
                std::clamp<int64_t>(_market.last_shortage_q16[market_index],
                                    0, Q16_ONE),
                2 * Q16_ONE, Q16_ONE, _saturation_count),
                _saturation_count);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _production_input_reserve.size())) {
                const int64_t reserve = std::max<int64_t>(
                    0, _production_input_reserve[signal]);
                const int64_t stock = std::max<int64_t>(
                    0, _market.stock[market_index]);
                if (reserve > stock) {
                    priority_q16 = saturating_add(priority_q16, mul_div_sat(
                        reserve - stock, 2 * Q16_ONE,
                        std::max<int64_t>(1, reserve), _saturation_count),
                        _saturation_count);
                }
            }
            weight_by_good[good] = mul_div_sat(
                base_weight, priority_q16, Q16_ONE, _saturation_count);
            total_weight = saturating_add(
                total_weight, weight_by_good[good], _saturation_count);
        }
        const int64_t allocated_budget = std::min(
            merchant_procurement_remaining, total_purchase_value);
        _merchant_procurement_opportunity = saturating_add(
            _merchant_procurement_opportunity, total_purchase_value, _saturation_count);
        _merchant_procurement_allocated = saturating_add(
            _merchant_procurement_allocated, allocated_budget, _saturation_count);
        // Weighted procurement is a capped allocation: no good can use more
        // cash than its current inventory gap is worth. A single proportional
        // pass used to over-allocate high-priority goods beyond that cap and
        // strand the unused cash while other genuine gaps went unfunded. Peel
        // off capped goods, then redistribute their excess deterministically
        // among the remaining gaps without changing inventory targets.
        int64_t remaining_budget = allocated_budget;
        int64_t remaining_weight = total_weight;
        while (remaining_budget > 0 && remaining_weight > 0) {
            bool capped_any = false;
            for (int32_t good : touched_goods) {
                const int64_t weight = weight_by_good[good];
                const int64_t cap = purchase_value_by_good[good];
                if (weight <= 0 || cap <= 0) continue;
                const int64_t share = mul_div_sat(
                    remaining_budget, weight, remaining_weight,
                    _saturation_count);
                if (share < cap) continue;
                budget_by_good[good] = cap;
                remaining_budget = std::max<int64_t>(
                    0, remaining_budget - cap);
                remaining_weight = std::max<int64_t>(
                    0, remaining_weight - weight);
                weight_by_good[good] = 0;
                capped_any = true;
            }
            if (!capped_any) break;
        }
        int64_t weight_prefix = 0;
        int64_t budget_distributed = 0;
        for (int32_t good : touched_goods) {
            const int64_t weight = weight_by_good[good];
            if (weight <= 0 || remaining_weight <= 0) continue;
            weight_prefix = saturating_add(
                weight_prefix, weight, _saturation_count);
            const int64_t next = mul_div_sat(
                remaining_budget, weight_prefix, remaining_weight,
                _saturation_count);
            const int64_t share = std::max<int64_t>(
                0, next - budget_distributed);
            budget_by_good[good] = std::min<int64_t>(
                purchase_value_by_good[good], share);
            budget_distributed = next;
        }
        int64_t assigned = 0;
        for (int32_t good : touched_goods) {
            assigned = saturating_add(
                assigned, budget_by_good[good], _saturation_count);
        }
        int64_t rounding_remainder = std::max<int64_t>(
            0, allocated_budget - assigned);
        for (int32_t good : touched_goods) {
            if (rounding_remainder <= 0) break;
            const int64_t headroom = std::max<int64_t>(
                0, purchase_value_by_good[good] - budget_by_good[good]);
            const int64_t extra = std::min<int64_t>(
                headroom, rounding_remainder);
            budget_by_good[good] += extra;
            rounding_remainder -= extra;
        }
        for (const Offer &offer : offers) {
            BuildingGroup &group = _buildings[offer.group];
            const int64_t issue_value = _good_monetary_issue_values[offer.good];
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                _market.price[_market.index(market, offer.good)],
                std::max<int32_t>(1, buy_factor_by_good[offer.good]),
                Q16_ONE, _saturation_count));
            int64_t sold = offer.sellable;
            int64_t paid = 0;
            int64_t supported = 0;
            int64_t support_paid = 0;
            if (issue_value > 0) {
                paid = mul_div_sat(sold, issue_value, GOODS_SCALE, _saturation_count);
                _explicit_money_mint = saturating_add(
                    _explicit_money_mint, paid, _saturation_count);
                _bullion_money_issued = saturating_add(
                    _bullion_money_issued, paid, _saturation_count);
                if (_good_ids[offer.good] == "gold") {
                    _gold_accepted = saturating_add(_gold_accepted, sold, _saturation_count);
                    _gold_money_issued = saturating_add(
                        _gold_money_issued, paid, _saturation_count);
                } else {
                    _silver_accepted = saturating_add(_silver_accepted, sold, _saturation_count);
                    _silver_money_issued = saturating_add(
                        _silver_money_issued, paid, _saturation_count);
                }
                // Bullion mint is the primary sink for monetary goods (gold/silver):
                // the whole sellable batch is absorbed by the money system every epoch.
                // Feed this back into the withdrawal signal so the utilization planner
                // (see prepare_building_economic_plan inventory-absorption path) does
                // not treat mint-cleared bullion as unsellable inventory and throttle
                // production to the probe floor. Without this, demand_ema stays 0,
                // target inventory collapses to ~0, stock >> target, and util decays.
                const int32_t bullion_signal = market_signal_index(cell, offer.good);
                if (bullion_signal >= 0 && bullion_signal < static_cast<int32_t>(
                        _epoch_nonhousehold_withdrawals.size())) {
                    _epoch_nonhousehold_withdrawals[bullion_signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[bullion_signal], sold,
                        _saturation_count);
                }
            } else {
                const int64_t available_budget = std::max<int64_t>(
                    0, budget_by_good[offer.good] - spent_by_good[offer.good]);
                sold = std::min(sold, quota_by_good[offer.good]);
                sold = std::min(sold, mul_div_sat(
                    available_budget, GOODS_SCALE, buy_price, _saturation_count));
                const int64_t payment = mul_div_sat(
                    sold, buy_price, GOODS_SCALE, _saturation_count);
                paid = debit_local_merchants(cell, payment,
                                             CASHFLOW_MERCHANT_PROCUREMENT,
                                             &_saturation_count);
                if (paid != payment) {
                    error = "merchant_purchase_payment_drift";
                    return false;
                }
                quota_by_good[offer.good] -= sold;
                spent_by_good[offer.good] = saturating_add(
                    spent_by_good[offer.good], paid, _saturation_count);
                merchant_procurement_remaining = std::max<int64_t>(
                    0, merchant_procurement_remaining - paid);
                _merchant_procurement_spent = saturating_add(
                    _merchant_procurement_spent, paid, _saturation_count);
                const int64_t remaining_target = std::max<int64_t>(
                    0, quota_by_good[offer.good]);
                supported = std::min<int64_t>(
                    offer.sellable - sold, remaining_target);
                if (producer_support_remaining <= 0) {
                    supported = 0;
                } else {
                    supported = std::min<int64_t>(supported, mul_div_sat(
                        producer_support_remaining,
                        GOODS_SCALE * PRODUCER_SUPPORT_PRICE_DENOMINATOR,
                        std::max<int64_t>(1, _market.price[
                            _market.index(market, offer.good)]), _saturation_count));
                }
                quota_by_good[offer.good] = std::max<int64_t>(
                    0, quota_by_good[offer.good] - supported);
                if (supported > 0) {
                    support_paid = std::max<int64_t>(1, mul_div_sat(
                        supported,
                        _market.price[_market.index(market, offer.good)],
                        GOODS_SCALE * PRODUCER_SUPPORT_PRICE_DENOMINATOR,
                        _saturation_count));
                    _explicit_money_mint = saturating_add(
                        _explicit_money_mint, support_paid, _saturation_count);
                    _producer_support_money_issued = saturating_add(
                        _producer_support_money_issued, support_paid,
                        _saturation_count);
                    _production_output_supported = saturating_add(
                        _production_output_supported, supported,
                        _saturation_count);
                    producer_support_remaining = std::max<int64_t>(
                        0, producer_support_remaining - support_paid);
                }
            }
            const int64_t total_paid = saturating_add(
                paid, support_paid, _saturation_count);
            const int64_t accepted = saturating_add(
                sold, supported, _saturation_count);
            touch_accounting_slot(offer.owner_slot);
            _population.funds[offer.owner_slot] = saturating_add(
                _population.funds[offer.owner_slot], total_paid, _saturation_count);
            _population.epoch_income[offer.owner_slot] = saturating_add(
                _population.epoch_income[offer.owner_slot], total_paid,
                _saturation_count);
            trace_record_cashflow(cell, _population.handle_for_slot(offer.owner_slot),
                                  CASHFLOW_OWNER_OPERATIONS, paid, 0);
            trace_record_cashflow(cell, _population.handle_for_slot(offer.owner_slot),
                                  CASHFLOW_PRODUCER_SUPPORT, support_paid, 0);
            _market.stock[_market.index(market, offer.good)] = saturating_add(
                _market.stock[_market.index(market, offer.good)], accepted,
                _saturation_count);
            if (issue_value > 0) {
                // Coined bullion is consumed by the money system: the sold batch
                // was minted into currency (see the issue_value branch above), so
                // it must not linger as market stock. Net stock change for these
                // goods is zero (+accepted then -sold, and supported==0 here).
                // Record the removal as an explicit goods-conservation sink so the
                // closing-stock check stays balanced. Without this, gold/silver
                // stock accrues as ghost inventory, the utilization planner reads
                // it as unsellable surplus, and throttles production to the probe
                // floor -> owner/employee targets collapse -> mines shed workers.
                _market.stock[_market.index(market, offer.good)] = saturating_sub(
                    _market.stock[_market.index(market, offer.good)], sold,
                    _saturation_count);
                _bullion_stock_consumed = saturating_add(
                    _bullion_stock_consumed, sold, _saturation_count);
            }
            group.last_sold = saturating_add(
                group.last_sold, accepted, _saturation_count);
            const int64_t unsold = offer.sellable - accepted;
            if (unsold > 0) {
                group.last_discarded = saturating_add(
                    group.last_discarded, unsold, _saturation_count);
            }
            group.last_revenue = saturating_add(
                group.last_revenue, total_paid, _saturation_count);
            _production_output_stock = saturating_add(
                _production_output_stock, accepted, _saturation_count);
            if (unsold > 0) {
                _production_output_discarded = saturating_add(
                    _production_output_discarded, unsold, _saturation_count);
            }
            _producer_revenue = saturating_add(
                _producer_revenue, total_paid, _saturation_count);
            if (_good_storage_modes[offer.good] == 1) {
                _cycle_flow_produced = saturating_add(
                    _cycle_flow_produced, accepted, _saturation_count);
            }
        }
        return true;
    };
    if (!process_phase(true) || !process_phase(false)) {
        _production_result_sink = previous_sink;
        return false;
    }

    // Production first spends only on physical inputs. Base wages are income
    // distribution and settle after the producer has sold this cycle's output.
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t g = begin; g < end; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            total_due = saturating_add(total_due, std::max<int64_t>(
                0, group.last_base_wages_due - group.last_base_wages_paid),
                _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(
                0, _population.funds[owner_slot])) : 0;
        int64_t prefix = 0;
        int64_t allocated = 0;
        int64_t owner_paid = 0;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t due = std::max<int64_t>(
                    0, _building_role_base_wage_due[role_index] -
                       _building_role_base_wage_paid[role_index]);
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap,
                    &_saturation_count);
                _building_role_base_wage_paid[role_index] = saturating_add(
                    _building_role_base_wage_paid[role_index], paid, _saturation_count);
                group.last_base_wages_paid = saturating_add(
                    group.last_base_wages_paid, paid, _saturation_count);
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
            }
        }
        _building_base_wages_paid = saturating_add(
            _building_base_wages_paid, owner_paid, _saturation_count);
        _building_base_wages_due = saturating_add(
            _building_base_wages_due, total_due, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            group.last_wages_paid = group.last_base_wages_paid;
            group.last_operating_cost = saturating_add(
                group.last_input_cost, group.last_base_wages_due, _saturation_count);
            group.wage_suspended = group.last_base_wages_paid < group.last_base_wages_due ? 1 : 0;
            if (group.wage_suspended != 0) ++_wage_suspended_building_groups;
        }
    }

    // Profit bonuses are settled after sales. They cannot retroactively stop
    // production and are excluded from the local regular-wage anchor.
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.wage_suspended != 0 || group.last_base_wages_due <= 0) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t base_cost = saturating_add(
            group.last_input_cost, group.last_base_wages_due, _saturation_count);
        const int64_t target_profit = mul_div_sat(
            base_cost, type.target_operating_margin_q16, Q16_ONE, _saturation_count);
        const int64_t excess = std::max<int64_t>(0, saturating_sub(
            saturating_sub(group.last_revenue, base_cost, _saturation_count),
            target_profit, _saturation_count));
        group.last_bonus_due = mul_div_sat(
            excess, _employee_profit_share_q16, Q16_ONE, _saturation_count);
        int64_t prefix = 0;
        int64_t allocated = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            prefix = saturating_add(prefix,
                _building_role_base_wage_due[role_index], _saturation_count);
            const int64_t next = mul_div_sat(
                group.last_bonus_due, prefix, group.last_base_wages_due,
                _saturation_count);
            _building_role_bonus_due[role_index] =
                std::max<int64_t>(0, next - allocated);
            allocated = next;
        }
    }
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t g = begin; g < end; ++g) {
            if (_buildings[g].owner_signature_id == owner_signature)
                total_due = saturating_add(
                    total_due, _buildings[g].last_bonus_due, _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(
                0, _population.funds[owner_slot])) : 0;
        int64_t prefix = 0;
        int64_t allocated = 0;
        int64_t owner_paid = 0;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t due = _building_role_bonus_due[role_index];
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap,
                    &_saturation_count);
                _building_role_bonus_paid[role_index] = paid;
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
                group.last_bonus_paid = saturating_add(
                    group.last_bonus_paid, paid, _saturation_count);
            }
            group.last_wages_due = saturating_add(
                group.last_base_wages_due, group.last_bonus_due, _saturation_count);
            group.last_wages_paid = saturating_add(
                group.last_base_wages_paid, group.last_bonus_paid, _saturation_count);
            group.last_operating_cost = saturating_add(
                saturating_add(group.last_input_cost, group.last_base_wages_due,
                               _saturation_count),
                group.last_bonus_due, _saturation_count);
        }
        _building_bonus_due = saturating_add(
            _building_bonus_due, total_due, _saturation_count);
        _building_bonus_paid = saturating_add(
            _building_bonus_paid, owner_paid, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
    }
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        const int64_t owner_livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      _saturation_count),
            std::max<int64_t>(0, group.filled_owner), _saturation_count),
            std::max(1, _epoch_days), _saturation_count);
        const int64_t realized_cost = saturating_add(saturating_add(
            group.last_input_cost, group.last_base_wages_due, _saturation_count),
            owner_livelihood, _saturation_count);
        int64_t margin = realized_cost <= 0 ? 0 : mul_div_sat(
            saturating_sub(group.last_revenue, realized_cost, _saturation_count),
            Q16_ONE, std::max<int64_t>(MONEY_SCALE, realized_cost), _saturation_count);
        group.realized_profit_margin_q16 = static_cast<int32_t>(
            std::clamp<int64_t>(margin, -Q16_ONE, Q16_ONE));
    }
    update_cell_labor_signals(cell);
    const auto signal_started = Clock::now();
    thread_local std::vector<int64_t> business_observed;
    thread_local std::vector<int64_t> supply_observed;
    thread_local std::vector<int64_t> anchor_weighted;
    thread_local std::vector<int64_t> anchor_quantity;
    business_observed.assign(cell_signal_count, 0);
    supply_observed.assign(cell_signal_count, 0);
    anchor_weighted.assign(cell_signal_count, 0);
    anchor_quantity.assign(cell_signal_count, 0);
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0 ||
            group.operating_state != 0 ||
            !building_available(cell, group.type_id, true)) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        const int64_t owner_livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      _saturation_count),
            std::max<int64_t>(0, group.filled_owner), _saturation_count),
            std::max(1, _epoch_days), _saturation_count);
        const int64_t viability_operating_cost = saturating_add(
            group.last_operating_cost, owner_livelihood, _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            const int32_t selected = select_input_candidate(item, false, 0);
            if (selected < 0) continue;
            const InputCandidate &candidate = _building_input_candidates[selected];
            const int64_t effective = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.purchase_intent_capacity_q16, Q16_ONE, _saturation_count);
            const int64_t planned = physical_input_quantity(effective, candidate);
            const int32_t signal = market_signal_index(cell, candidate.good_id);
            if (signal >= cell_signal_begin && signal < cell_signal_end) {
                const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
                business_observed[local_signal] = saturating_add(
                    business_observed[local_signal], planned, _saturation_count);
            }
            const int64_t funded_effective = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.last_capacity_q16, Q16_ONE, _saturation_count);
            const int64_t funded = physical_input_quantity(funded_effective, candidate);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(_epoch_desired_business_demand.size())) {
                    _epoch_desired_business_demand[signal] = saturating_add(
                        _epoch_desired_business_demand[signal], planned, _saturation_count);
                }
                if (signal < static_cast<int32_t>(_epoch_funded_business_demand.size())) {
                    _epoch_funded_business_demand[signal] = saturating_add(
                        _epoch_funded_business_demand[signal], funded, _saturation_count);
                }
            }
            _desired_business_demand = saturating_add(
                _desired_business_demand, planned, _saturation_count);
            _funded_business_demand = saturating_add(
                _funded_business_demand, funded, _saturation_count);
            _unfunded_business_demand = saturating_add(
                _unfunded_business_demand, std::max<int64_t>(0, planned - funded),
                _saturation_count);
        }
        int64_t reference_total = 0;
        if (type.output_cost_share_count == 0) {
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &item = _building_outputs[type.output_begin + i];
                reference_total = saturating_add(reference_total, saturating_mul(
                    item.quantity, _good_default_price[item.good_id], _saturation_count),
                    _saturation_count);
            }
        }
        int64_t prefix = 0;
        int64_t allocated_before = 0;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            const int64_t qty = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.last_capacity_q16, Q16_ONE, _saturation_count);
            const int32_t output_signal = market_signal_index(cell, item.good_id);
            if (output_signal >= cell_signal_begin && output_signal < cell_signal_end) {
                const size_t local_signal = static_cast<size_t>(output_signal - cell_signal_begin);
                supply_observed[local_signal] = saturating_add(
                    supply_observed[local_signal], qty, _saturation_count);
            }
            if (qty <= 0) continue;
            int64_t next_allocated = 0;
            if (type.output_cost_share_count > 0) {
                prefix = saturating_add(prefix,
                    _building_output_cost_shares_q16[type.output_cost_share_begin + i],
                    _saturation_count);
                next_allocated = mul_div_sat(viability_operating_cost, prefix,
                                              Q16_ONE, _saturation_count);
            } else {
                prefix = saturating_add(prefix, saturating_mul(
                    item.quantity, _good_default_price[item.good_id], _saturation_count),
                    _saturation_count);
                next_allocated = reference_total > 0 ? mul_div_sat(
                    viability_operating_cost, prefix, reference_total,
                    _saturation_count) : 0;
            }
            const int64_t allocated = std::max<int64_t>(0, next_allocated - allocated_before);
            allocated_before = next_allocated;
            if (_good_monetary_issue_values[item.good_id] > 0) continue;
            const int64_t required = saturating_add(allocated, mul_div_sat(
                allocated, type.target_operating_margin_q16, Q16_ONE,
                _saturation_count), _saturation_count);
            const int64_t settlement_unit = mul_div_sat(
                required, GOODS_SCALE, qty, _saturation_count);
            const int32_t output_flow = trade_flow_index(cell, item.good_id, false);
            const int64_t output_target = merchant_inventory_target(
                market, item.good_id, output_signal,
                output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                    output_signal] : 0,
                output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                qty / std::max(1, _epoch_days), _saturation_count);
            const int32_t buy_factor = effective_merchant_buy_factor_q16(
                market, item.good_id, output_target,
                _market.stock[_market.index(market, item.good_id)],
                _saturation_count);
            const int64_t retail_target = mul_div_sat(
                settlement_unit, Q16_ONE,
                std::max<int32_t>(1, buy_factor),
                _saturation_count);
            if (output_signal < cell_signal_begin || output_signal >= cell_signal_end)
                continue;
            const size_t local_signal = static_cast<size_t>(output_signal - cell_signal_begin);
            anchor_weighted[local_signal] = saturating_add(
                anchor_weighted[local_signal], saturating_mul(
                    retail_target, qty, _saturation_count), _saturation_count);
            anchor_quantity[local_signal] = saturating_add(
                anchor_quantity[local_signal], qty, _saturation_count);
        }
    }
    if (has_cell_signals) {
        for (int32_t signal = cell_signal_begin; signal < cell_signal_end; ++signal) {
            const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
            const int32_t good = _market_signals.good_ids[signal];
            supply_observed[local_signal] = std::max<int64_t>(
                0, supply_observed[local_signal] - retained_by_signal[local_signal]);
            const int64_t business_daily =
                business_observed[local_signal] / std::max(1, _epoch_days);
            const int64_t supply_daily =
                supply_observed[local_signal] / std::max(1, _epoch_days);
            const int64_t business_alpha = std::min<int64_t>(Q16_ONE,
                static_cast<int64_t>(_good_business_demand_ema_alpha_q16[good]) * _epoch_days);
            const int64_t supply_alpha = std::min<int64_t>(Q16_ONE,
                static_cast<int64_t>(_good_supply_ema_alpha_q16[good]) * _epoch_days);
            _market_signals.business_demand_ema[signal] = saturating_add(
                mul_div_sat(_market_signals.business_demand_ema[signal],
                            Q16_ONE - business_alpha, Q16_ONE, _saturation_count),
                mul_div_sat(business_daily, business_alpha, Q16_ONE, _saturation_count),
                _saturation_count);
            _market_signals.offered_supply_ema[signal] = saturating_add(
                mul_div_sat(_market_signals.offered_supply_ema[signal],
                            Q16_ONE - supply_alpha, Q16_ONE, _saturation_count),
                mul_div_sat(supply_daily, supply_alpha, Q16_ONE, _saturation_count),
                _saturation_count);
            if (anchor_quantity[local_signal] > 0) {
                const int64_t observed =
                    anchor_weighted[local_signal] / anchor_quantity[local_signal];
                const int64_t cost_alpha = std::min<int64_t>(Q16_ONE,
                    static_cast<int64_t>(_good_cost_ema_alpha_q16[good]) * _epoch_days);
                const int64_t old_anchor = _market_signals.cost_anchor_price[signal] > 0
                    ? _market_signals.cost_anchor_price[signal] : observed;
                const int64_t next_anchor = saturating_add(
                    mul_div_sat(old_anchor, Q16_ONE - cost_alpha, Q16_ONE, _saturation_count),
                    mul_div_sat(observed, cost_alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
                _market_signals.cost_anchor_price[signal] = static_cast<int32_t>(
                    std::clamp<int64_t>(next_anchor, PRICE_NUMERIC_GUARD_MIN,
                                        PRICE_NUMERIC_GUARD_MAX));
            }
            ++_market_signal_updates;
        }
    }
    _market_signal_ms += elapsed_ms(signal_started);
    for (int32_t good : _cycle_flow_good_ids) {
        const int64_t idx = _market.index(market, good);
        const int64_t discarded = std::max<int64_t>(0, _market.stock[idx]);
        _market.stock[idx] = 0;
        _cycle_flow_discarded = saturating_add(
            _cycle_flow_discarded, discarded, _saturation_count);
    }
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        std::vector<EventLeg> legs;
        if (trace_detail) {
            const BuildingGroup &before = trace_before[static_cast<size_t>(g - begin)];
            auto add = [&](int32_t field, int64_t old_value, int64_t new_value) {
                if (old_value != new_value) {
                    legs.push_back({field, SUBJECT_BUILDING_GROUP,
                                    group.owner_signature_id, group.type_id,
                                    old_value, new_value});
                }
            };
            add(FIELD_BUILDING_CAPACITY, before.last_capacity_q16, group.last_capacity_q16);
            add(FIELD_BUILDING_INPUT, before.last_input, group.last_input);
            add(FIELD_BUILDING_OUTPUT, before.last_output, group.last_output);
            add(FIELD_BUILDING_SOLD, before.last_sold, group.last_sold);
            add(FIELD_BUILDING_DISCARDED, before.last_discarded, group.last_discarded);
            add(FIELD_BUILDING_RESOURCE, before.last_resource, group.last_resource);
            add(FIELD_BUILDING_RESOURCE_GENERATED, before.last_resource_generated,
                group.last_resource_generated);
            add(FIELD_BUILDING_REVENUE, before.last_revenue, group.last_revenue);
            add(FIELD_BUILDING_INPUT_COST, before.last_input_cost, group.last_input_cost);
            add(FIELD_BUILDING_WAGES_PAID, before.last_wages_paid, group.last_wages_paid);
            add(FIELD_BUILDING_WAGES_DUE, before.last_wages_due, group.last_wages_due);
            add(FIELD_BUILDING_EXPECTED_REVENUE, before.last_expected_revenue,
                group.last_expected_revenue);
            add(FIELD_BUILDING_OPERATING_COST, before.last_operating_cost,
                group.last_operating_cost);
            add(FIELD_BUILDING_MARGIN_GAP, before.last_margin_gap_q16,
                group.last_margin_gap_q16);
            add(FIELD_BUILDING_PLANNED_UTILIZATION, before.planned_utilization_q16,
                group.planned_utilization_q16);
            add(FIELD_BUILDING_BASE_WAGES_PAID, before.last_base_wages_paid,
                group.last_base_wages_paid);
            add(FIELD_BUILDING_BASE_WAGES_DUE, before.last_base_wages_due,
                group.last_base_wages_due);
            add(FIELD_BUILDING_BONUS_PAID, before.last_bonus_paid,
                group.last_bonus_paid);
            add(FIELD_BUILDING_BONUS_DUE, before.last_bonus_due,
                group.last_bonus_due);
            add(FIELD_BUILDING_WAGE_SUSPENDED, before.wage_suspended,
                group.wage_suspended);
        }
        trace_append(EVENT_BUILDING_PRODUCTION_SETTLED,
                     static_cast<int32_t>(Stage::BUILDING_PRODUCTION), cell,
                     SUBJECT_BUILDING_GROUP, group.owner_signature_id,
                     group.type_id, -1, group.last_output, group.last_sold,
                     group.last_revenue, group.last_wages_paid,
                     legs.empty() ? nullptr : &legs);
    }
    if (trace_detail) {
        std::vector<EventLeg> cell_legs;
        auto add = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
            if (before != after) {
                cell_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
            }
        };
        for (size_t i = 0; i < trace_cell_slots.size(); ++i) {
            const int32_t slot = trace_cell_slots[i];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(slot));
            add(FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                trace_cell_funds[i], _population.funds[slot]);
            add(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                trace_cell_income[i], _population.epoch_income[slot]);
            add(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, handle, -1,
                trace_cell_expense[i], _population.epoch_expense[slot]);
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            add(FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good,
                trace_market_stock[good], _market.stock[_market.index(market, good)]);
        }
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            const int64_t after = _resource_deltas[
                resource * static_cast<size_t>(_cell_count) + cell];
            add(FIELD_RESOURCE_DELTA, SUBJECT_RESOURCE, cell,
                static_cast<int32_t>(resource), trace_resource_delta[resource], after);
        }
        if (!cell_legs.empty()) {
            trace_append(EVENT_BUILDING_PRODUCTION_SETTLED,
                         static_cast<int32_t>(Stage::BUILDING_PRODUCTION), cell,
                         SUBJECT_MARKET, market, -1, -1,
                         static_cast<int64_t>(cell_legs.size()), 0, 0, 0, &cell_legs);
        }
    }
    _staging_cells[cell] = build_cell_summary(cell);
    _production_result_sink = previous_sink;
    return true;
}

void NativeEconomyRuntime::merge_building_production_result(ProductionResult &result) {
    _saturation_count = saturating_add(
        _saturation_count, result.saturation_count, _saturation_count);
    auto merge = [&](int64_t &target, int64_t value) {
        target = saturating_add(target, value, _saturation_count);
    };
    merge(_processed_building_groups, result.processed_building_groups);
    merge(_merchant_procurement_budget, result.merchant_procurement_budget);
    merge(_merchant_procurement_opportunity, result.merchant_procurement_opportunity);
    merge(_merchant_procurement_allocated, result.merchant_procurement_allocated);
    merge(_merchant_procurement_unspent_allocated, result.merchant_procurement_unspent_allocated);
    merge(_merchant_procurement_reserved, result.merchant_procurement_reserved);
    merge(_merchant_procurement_spent, result.merchant_procurement_spent);
    _merchant_procurement_unspent_allocated = std::max<int64_t>(
        0, _merchant_procurement_allocated - _merchant_procurement_spent);
    merge(_owner_working_capital_allocated, result.owner_working_capital_allocated);
    _working_capital_scale_error_bound_q16 = std::max(
        _working_capital_scale_error_bound_q16,
        result.working_capital_scale_error_bound_q16);
    merge(_building_resource_capacity_checks,
          result.building_resource_capacity_checks);
    merge(_building_resource_limited_groups,
          result.building_resource_limited_groups);
    merge(_building_resource_capacity_limited_groups,
          result.building_resource_capacity_limited_groups);
    merge(_building_resource_generated, result.building_resource_generated);
    merge(_building_resource_consumed, result.building_resource_consumed);
    merge(_production_inputs_consumed, result.production_inputs_consumed);
    merge(_production_output_stock, result.production_output_stock);
    merge(_production_output_discarded, result.production_output_discarded);
    merge(_production_output_supported, result.production_output_supported);
    merge(_producer_revenue, result.producer_revenue);
    merge(_producer_support_money_issued, result.producer_support_money_issued);
    merge(_explicit_money_mint, result.explicit_money_mint);
    merge(_bullion_money_issued, result.bullion_money_issued);
    merge(_bullion_stock_consumed, result.bullion_stock_consumed);
    merge(_gold_accepted, result.gold_accepted);
    merge(_silver_accepted, result.silver_accepted);
    merge(_gold_money_issued, result.gold_money_issued);
    merge(_silver_money_issued, result.silver_money_issued);
    merge(_cycle_flow_produced, result.cycle_flow_produced);
    merge(_cycle_flow_consumed, result.cycle_flow_consumed);
    merge(_cycle_flow_discarded, result.cycle_flow_discarded);
    merge(_building_wages_paid, result.building_wages_paid);
    merge(_building_wages_unpaid, result.building_wages_unpaid);
    merge(_building_base_wages_paid, result.building_base_wages_paid);
    merge(_building_base_wages_due, result.building_base_wages_due);
    merge(_building_bonus_paid, result.building_bonus_paid);
    merge(_building_bonus_due, result.building_bonus_due);
    merge(_wage_suspended_building_groups,
          result.wage_suspended_building_groups);
    merge(_desired_business_demand, result.desired_business_demand);
    merge(_funded_business_demand, result.funded_business_demand);
    merge(_unfunded_business_demand, result.unfunded_business_demand);
    merge(_market_signal_updates, result.market_signal_updates);
    _market_signal_ms += result.market_signal_ms;
    _owner_retained_outputs.insert(
        _owner_retained_outputs.end(),
        std::make_move_iterator(result.retained_outputs.begin()),
        std::make_move_iterator(result.retained_outputs.end()));
    for (const ProductionCashflowDraft &draft : result.cashflow_drafts) {
        trace_record_cashflow(draft.cell, draft.entry.cohort_handle,
                              draft.entry.source, draft.entry.income,
                              draft.entry.expense);
    }
    for (ProductionTraceDraft &draft : result.trace_drafts) {
        trace_append(draft.kind, draft.stage, draft.cell, draft.subject_kind,
                     draft.subject_id, draft.subject_i0, draft.subject_i1,
                     draft.value0, draft.value1, draft.value2, draft.value3,
                     draft.legs.empty() ? nullptr : &draft.legs, draft.flags);
    }
}

int64_t NativeEconomyRuntime::projected_owner_income_per_day(
        const BuildingGroup &group, int64_t &sat) const {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const BuildingType &type = _building_types[group.type_id];
    const int64_t days = std::max<int64_t>(1, _epoch_days);
    const int64_t utilization = std::clamp<int64_t>(
        group.planned_utilization_q16, 0, Q16_ONE);
    const int64_t owner_jobs = saturating_mul(
        group.count, type.owner_slots_per_building, sat);
    if (owner_jobs <= 0 || utilization <= 0) return 0;
    int64_t input_cost = saturating_mul(
        saturating_mul(group.sample_unit_input_cost, group.count,
                       sat),
        days, sat);
    input_cost = mul_div_sat(input_cost, utilization, Q16_ONE,
                             sat);
    int64_t wage_cost = 0;
    for (int32_t r = 0; r < type.employee_count; ++r) {
        const JobRole &role = _building_employee_roles[type.employee_begin + r];
        const int32_t role_index = group.employee_fill_begin + r;
        const int64_t wage = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? _building_role_contract_wage[role_index]
            : role.reference_wage_per_day;
        int64_t role_cost = saturating_mul(
            saturating_mul(role.slots_per_building, group.count,
                           sat),
            saturating_mul(wage, days, sat),
            sat);
        role_cost = mul_div_sat(role_cost, utilization, Q16_ONE,
                                sat);
        wage_cost = saturating_add(wage_cost, role_cost, sat);
    }
    const int64_t owner_pool = std::max<int64_t>(0,
        saturating_sub(group.last_expected_revenue,
            saturating_add(input_cost, wage_cost, sat),
            sat));
    return owner_pool / std::max<int64_t>(1,
        saturating_mul(owner_jobs, days, sat));
}

int32_t NativeEconomyRuntime::find_entrepreneur_source(
        int32_t cell, int32_t target_signature, int64_t required_capital,
        int64_t target_income_per_day, int32_t building_type_id,
        bool &had_eligible_sponsor) const {
    had_eligible_sponsor = false;
    if (cell < 0 || cell >= _cell_count || target_signature < 0 ||
        target_signature >= static_cast<int32_t>(_signatures.size()) ||
        building_type_id < 0 ||
        building_type_id >= static_cast<int32_t>(_building_types.size()) ||
        target_income_per_day <= 0) return -1;
    const Signature &target = _signatures[target_signature];
    int32_t best_slot = -1;
    int64_t best_income_gain = std::numeric_limits<int64_t>::min();
    int64_t best_transferable = -1;
    int64_t sat = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t source_signature = static_cast<int32_t>(
            _population.signature_id[slot]);
        if (source_signature < 0 || source_signature >=
                static_cast<int32_t>(_signatures.size())) return;
        const Signature &source = _signatures[source_signature];
        if (source.ethnicity_id != target.ethnicity_id) return;
        const int64_t population = std::max<int64_t>(0,
            _population.population[slot]);
        if (population <= 0 || (is_merchant_slot(slot) && population <= 1)) return;
        const int64_t living_cost = living_cost_for_signature(
            cell, source_signature, -1, sat);
        const int64_t reserve = saturating_mul(saturating_mul(
            living_cost, population, sat), 30, sat);
        const int64_t transferable = std::max<int64_t>(
            0, _population.funds[slot] - reserve);
        if (transferable < required_capital) return;
        const int64_t income_per_capita = std::max<int64_t>(0,
            _population.income_ema[slot]) / population;
        const int64_t income_gain = target_income_per_day - income_per_capita;
        if (income_gain <= 0) return;
        had_eligible_sponsor = true;
        const int64_t chance_q16 = std::clamp<int64_t>(mul_div_sat(
            income_gain, Q16_ONE, target_income_per_day, sat), 1, Q16_ONE);
        uint64_t roll_hash = 1469598103934665603ULL;
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_seed));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_current_day));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(cell));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(building_type_id));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(source_signature));
        const int64_t roll_q16 = static_cast<int64_t>((roll_hash >> 32) & 0xffffULL);
        if (roll_q16 >= chance_q16) return;
        if (income_gain > best_income_gain ||
            (income_gain == best_income_gain && transferable > best_transferable) ||
            (income_gain == best_income_gain && transferable == best_transferable &&
             (best_slot < 0 || slot < best_slot))) {
            best_slot = slot;
            best_income_gain = income_gain;
            best_transferable = transferable;
        }
    });
    return best_slot;
}

bool NativeEconomyRuntime::run_endogenous_building_investment(
        int32_t ordinal_begin, int32_t ordinal_end, bool initialize,
        bool &population_changed, std::string &error) {
    population_changed = false;
    if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
        return true;
    if (initialize) {
        _building_investment_score_q16.assign(_buildings.size(), 0);
        _building_investment_payback_days.assign(_buildings.size(), 0);
        _building_investment_rejection.assign(_buildings.size(), 0);
        _investment_pending_by_cell_type.clear();
        _investment_existing_by_cell_type.clear();
        _investment_harvest_by_cell_resource.clear();
        _investment_pending_by_cell_type.reserve(_pending_construction.size() * 2 + 1);
        _investment_existing_by_cell_type.reserve(_buildings.size() * 2 + 1);
        _investment_harvest_by_cell_resource.reserve(_buildings.size() * 2 + 1);
    }
    struct Candidate {
        int32_t type = -1;
        int32_t target_signature = -1;
        int32_t sponsor = -1;
        int64_t required_capital = 0;
        int64_t projected_income = 0;
        int64_t shortage_q16 = 0;
        int64_t utilization_q16 = 0;
        int64_t profit_per_day = 0;
        int64_t score_q16 = 0;
        int64_t payback_days = 0;
    };
    auto better = [](const Candidate &a, const Candidate &b) {
        if (b.type < 0) return true;
        if (a.score_q16 != b.score_q16) return a.score_q16 > b.score_q16;
        if (a.payback_days != b.payback_days) return a.payback_days < b.payback_days;
        if (a.type != b.type) return a.type < b.type;
        return a.target_signature < b.target_signature;
    };
    auto cell_key = [](int32_t cell, int32_t id) -> uint64_t {
        return (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
            static_cast<uint32_t>(id);
    };
    auto mark_rejection = [&](const InvestmentExistingType *existing,
                              int32_t reason) {
        if (existing == nullptr || existing->first_group < 0) return;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_buildings.size()), existing->last_group + 1);
        for (int32_t group = existing->first_group; group < end; ++group) {
            if (_buildings[group].cell != _buildings[existing->first_group].cell ||
                _buildings[group].type_id != _buildings[existing->first_group].type_id)
                break;
            if (group < static_cast<int32_t>(_building_investment_rejection.size()))
                _building_investment_rejection[group] = reason;
        }
    };
    if (initialize) {
      for (const PendingConstruction &pending : _pending_construction) {
        _investment_pending_by_cell_type[cell_key(pending.cell, pending.type_id)] = 1;
      }
      for (int32_t g = 0; g < static_cast<int32_t>(_buildings.size()); ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        const BuildingType &type = _building_types[group.type_id];
        InvestmentExistingType &existing = _investment_existing_by_cell_type[
            cell_key(group.cell, group.type_id)];
        if (existing.first_group < 0) existing.first_group = g;
        existing.last_group = g;
        if (existing.representative_group < 0 ||
            (group.operating_state == 0 && _buildings[
                existing.representative_group].operating_state != 0))
            existing.representative_group = g;
        existing.installed_count = saturating_add(
            existing.installed_count, group.count, _saturation_count);
        if (group.operating_state == 0) {
            existing.active_count = saturating_add(
                existing.active_count, group.count, _saturation_count);
            if (group.planned_utilization_q16 > 0) {
                existing.owner_required = saturating_add(
                    existing.owner_required, saturating_mul(
                        group.count, type.owner_slots_per_building,
                        _saturation_count), _saturation_count);
            }
        } else {
            existing.suspended_count = saturating_add(
                existing.suspended_count, group.count, _saturation_count);
            if (type.owner_slots_per_building > 0) {
                existing.owner_required = saturating_add(
                    existing.owner_required, 1, _saturation_count);
            }
        }
        existing.filled_owner = saturating_add(
            existing.filled_owner, std::max<int64_t>(0, group.filled_owner),
            _saturation_count);
        existing.last_sold = saturating_add(
            existing.last_sold, std::max<int64_t>(0, group.last_sold),
            _saturation_count);
        existing.last_discarded = saturating_add(
            existing.last_discarded, std::max<int64_t>(0, group.last_discarded),
            _saturation_count);
        for (int32_t r = 0; r < type.resource_count; ++r) {
            const ResourceAmount &item = _building_resources[type.resource_begin + r];
            if (item.mode != 0 || item.resource_id < 0) continue;
            int64_t &harvest = _investment_harvest_by_cell_resource[
                cell_key(group.cell, item.resource_id)];
            harvest = saturating_add(harvest, saturating_mul(
                item.quantity, group.count, _saturation_count), _saturation_count);
        }
      }
    }
    auto resource_safe = [&](int32_t cell, int32_t type_id,
                             int64_t &minimum_life) -> bool {
        const BuildingType &type = _building_types[type_id];
        minimum_life = std::numeric_limits<int64_t>::max();
        for (int32_t edge = 0; edge < type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[type.resource_begin + edge];
            if (item.mode != 0 || item.resource_id < 0) continue;
            const int32_t resource = item.resource_id;
            const int64_t reserve = std::max<int64_t>(0, _resource_remaining[
                static_cast<size_t>(resource) * _cell_count + cell]);
            const auto harvest_it = _investment_harvest_by_cell_resource.find(
                cell_key(cell, resource));
            const int64_t total_harvest = saturating_add(
                item.quantity,
                harvest_it != _investment_harvest_by_cell_resource.end()
                    ? harvest_it->second : 0,
                _saturation_count);
            const int64_t capacity = _resource_ecology_capacity[resource];
            const int64_t growth_q16 = _resource_ecology_growth_q16[resource];
            if (capacity > 0 && growth_q16 > 0) {
                if (reserve < mul_div_sat(capacity, _resource_min_reserve_q16,
                                         Q16_ONE, _saturation_count)) return false;
                int64_t safe_yield = mul_div_sat(
                    capacity, growth_q16, 8 * Q16_ONE, _saturation_count);
                safe_yield = mul_div_sat(safe_yield, _resource_safe_harvest_q16,
                                         Q16_ONE, _saturation_count);
                if (total_harvest > safe_yield) return false;
                continue;
            }
            const int64_t lo = _resource_temp_lo_q16[resource];
            const int64_t hi = std::max<int64_t>(lo + 1, _resource_temp_hi_q16[resource]);
            const int64_t temp = std::clamp<int64_t>(mul_div_sat(
                _environment_temperature_q16[cell] - lo, Q16_ONE,
                hi - lo, _saturation_count), 0, Q16_ONE);
            const int64_t moisture = std::clamp<int64_t>(
                _environment_moisture_q16[cell], 0, Q16_ONE);
            int64_t production = saturating_add(saturating_add(
                _resource_gen_base[resource], mul_div_sat(
                    _resource_gen_temp[resource], temp, Q16_ONE, _saturation_count),
                _saturation_count), saturating_add(_resource_gen_self[resource],
                    mul_div_sat(_resource_gen_moisture[resource], moisture,
                                Q16_ONE, _saturation_count), _saturation_count),
                _saturation_count);
            production = saturating_sub(production, saturating_add(
                _resource_decay_base[resource], saturating_add(mul_div_sat(
                    _resource_decay_temp[resource], temp, Q16_ONE, _saturation_count),
                    mul_div_sat(_resource_decay_moisture[resource], moisture,
                                Q16_ONE, _saturation_count), _saturation_count),
                _saturation_count), _saturation_count);
            if (production > 0 || _resource_decay_self_q16[resource] > 0) {
                const int64_t reserve_floor = mul_div_sat(
                    reserve, _resource_min_reserve_q16, Q16_ONE, _saturation_count);
                const int64_t safe_yield = std::max<int64_t>(0, saturating_sub(
                    production, mul_div_sat(_resource_decay_self_q16[resource],
                        reserve_floor, Q16_ONE, _saturation_count), _saturation_count));
                if (total_harvest > safe_yield) return false;
            } else {
                const int64_t life = reserve / std::max<int64_t>(1, total_harvest);
                minimum_life = std::min(minimum_life, life);
                if (life < _resource_min_horizon_days) return false;
            }
        }
        return true;
    };

    const int32_t investment_cell_count = _rolling_phase < _cell_count
        ? (_cell_count - 1 - _rolling_phase) / ROLLING_PHASE_COUNT + 1 : 0;
    ordinal_begin = std::clamp(ordinal_begin, 0, investment_cell_count);
    ordinal_end = std::clamp(ordinal_end, ordinal_begin, investment_cell_count);
    for (int32_t ordinal = ordinal_begin; ordinal < ordinal_end; ++ordinal) {
        const int32_t cell = _rolling_phase + ordinal * ROLLING_PHASE_COUNT;
        if (_committed_cells[cell].population <= 0) continue;
        const int32_t investment_phase = cell % _investment_review_days;
        const int32_t current_investment_phase = static_cast<int32_t>(
            ((_current_day % _investment_review_days) + _investment_review_days) %
            _investment_review_days);
        const bool capital_review = _current_day > 0 &&
            investment_phase == current_investment_phase;
        Candidate best;
        bool eligible_but_unfunded = false;
        const int32_t market = _market.cell_to_market[cell];
        for (int32_t type_id = 0; type_id < static_cast<int32_t>(
                _building_types.size()); ++type_id) {
            const BuildingType &type = _building_types[type_id];
            // Primitive collectors have no construction bill, but still need
            // operating capital, owner livelihood, profit, and safe resources.
            if (type.kind == 2 ||
                (type.kind != 0 && type.construction_count <= 0) ||
                !building_constructible(cell, type_id, true)) continue;
            const InvestmentExistingType *existing = nullptr;
            const auto existing_it = _investment_existing_by_cell_type.find(
                cell_key(cell, type_id));
            if (existing_it != _investment_existing_by_cell_type.end()) {
                existing = &existing_it->second;
            }
            if (_investment_pending_by_cell_type.find(cell_key(cell, type_id)) !=
                    _investment_pending_by_cell_type.end()) {
                mark_rejection(existing, INVESTMENT_REJECTION_PENDING_CONSTRUCTION);
                continue;
            }
            const int32_t existing_group = existing != nullptr
                ? existing->representative_group : -1;
            const bool vacancy = existing != nullptr &&
                existing->filled_owner < existing->owner_required;
            if (vacancy) {
                mark_rejection(existing,
                    INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY);
                continue;
            }
            if (!capital_review) continue;
            if (existing != nullptr && existing->suspended_count > 0) {
                mark_rejection(existing, INVESTMENT_REJECTION_SUSPENDED_CAPACITY);
                continue;
            }
            int64_t shortage_q16 = 0;
            int64_t utilization_q16 = 0;
            bool survival_output = false;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &output = _building_outputs[type.output_begin + i];
                const int64_t index = _market.index(market, output.good_id);
                const int32_t signal = market_signal_index(cell, output.good_id);
                const int64_t demand = saturating_add(
                    _market.demand_ema[index],
                    signal >= 0 ? _market_signals.business_demand_ema[signal] : 0,
                    _saturation_count);
                const int64_t supply = signal >= 0
                    ? _market_signals.offered_supply_ema[signal] : 0;
                const int64_t output_deficit = std::max<int64_t>(
                    0, demand - supply);
                int64_t output_pressure_q16 =
                    _market.last_shortage_q16[index];
                if (output_deficit > 0 && demand > 0) {
                    output_pressure_q16 = std::max<int64_t>(
                        output_pressure_q16,
                        std::min<int64_t>(Q16_ONE, mul_div_sat(
                            output_deficit, Q16_ONE, demand,
                            _saturation_count)));
                }
                shortage_q16 = std::max<int64_t>(
                    shortage_q16, output_pressure_q16);
                if (output.quantity > 0) {
                    utilization_q16 = std::max<int64_t>(utilization_q16,
                        mul_div_sat(output_deficit,
                            Q16_ONE, output.quantity, _saturation_count));
                }
                survival_output = survival_output ||
                    _survival_food_good_mask[output.good_id] != 0 ||
                    _survival_clothing_good_mask[output.good_id] != 0;
            }
            utilization_q16 = std::clamp<int64_t>(utilization_q16, 0, Q16_ONE);
            if (existing != nullptr) {
                const int64_t offered = saturating_add(
                    existing->last_sold, existing->last_discarded,
                    _saturation_count);
                if (offered > 0) {
                    const int64_t sell_through_q16 = mul_div_sat(
                        existing->last_sold, Q16_ONE, offered,
                        _saturation_count);
                    const int64_t discard_q16 = mul_div_sat(
                        existing->last_discarded, Q16_ONE, offered,
                        _saturation_count);
                    if (sell_through_q16 < 4 * Q16_ONE / 5) {
                        mark_rejection(existing,
                            INVESTMENT_REJECTION_SELL_THROUGH);
                        continue;
                    }
                    if (discard_q16 > Q16_ONE / 10) {
                        mark_rejection(existing, INVESTMENT_REJECTION_DISCARD);
                        continue;
                    }
                }
            }
            int64_t minimum_resource_life = std::numeric_limits<int64_t>::max();
            if (type.kind == 0 && !resource_safe(cell, type_id, minimum_resource_life)) {
                ++_building_investment_blocked_resources;
                mark_rejection(existing, INVESTMENT_REJECTION_RESOURCE);
                continue;
            }
            int64_t construction_cost = 0;
            bool materials_ready = true;
            for (int32_t i = 0; i < type.construction_count; ++i) {
                const GoodAmount &item = _building_construction_goods[
                    type.construction_begin + i];
                const int64_t index = _market.index(market, item.good_id);
                construction_cost = saturating_add(construction_cost, mul_div_sat(
                    item.quantity, _market.price[index], GOODS_SCALE,
                    _saturation_count), _saturation_count);
                if (_market.stock[index] < item.quantity) {
                    materials_ready = false;
                    const int32_t signal = ensure_market_signal_index(cell, item.good_id);
                    if (signal >= 0) _market_signals.business_demand_ema[signal] = std::max(
                        _market_signals.business_demand_ema[signal],
                        std::max<int64_t>(1, (item.quantity - _market.stock[index]) /
                            std::max(1, _epoch_days)));
                }
            }
            if (!materials_ready) {
                ++_building_investment_blocked_materials;
                mark_rejection(existing, INVESTMENT_REJECTION_MATERIALS);
                continue;
            }
            int64_t daily_input_cost = 0;
            int64_t input_coverage_bound_q16 = Q16_ONE;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &input = _building_inputs[type.input_begin + i];
                int64_t best_price = std::numeric_limits<int64_t>::max();
                int64_t best_coverage_q16 = -1;
                for (int32_t c = input.candidate_begin;
                     c < input.candidate_begin + input.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                    if (!good_available(cell, candidate.good_id, true)) continue;
                    int64_t physical_daily = mul_div_sat(
                        input.quantity, Q16_ONE, candidate.efficiency_q16,
                        _saturation_count);
                    if (mul_div_sat(physical_daily, candidate.efficiency_q16,
                                    Q16_ONE, _saturation_count) < input.quantity) {
                        physical_daily = saturating_add(
                            physical_daily, 1, _saturation_count);
                    }
                    const int64_t input_index = _market.index(
                        market, candidate.good_id);
                    const int32_t input_signal = market_signal_index(
                        cell, candidate.good_id);
                    const int64_t reserved = input_signal >= 0 && input_signal <
                            static_cast<int32_t>(_production_input_reserve.size())
                        ? _production_input_reserve[input_signal] : 0;
                    const int64_t free_stock = std::max<int64_t>(
                        0, _market.stock[input_index] - reserved);
                    const int64_t effective_period_supply = saturating_add(
                        free_stock, saturating_mul(input_signal >= 0
                            ? _market_signals.offered_supply_ema[input_signal] : 0,
                            std::max(1, _epoch_days), _saturation_count),
                        _saturation_count);
                    const int64_t required_period = saturating_mul(
                        physical_daily, std::max(1, _epoch_days), _saturation_count);
                    const int64_t coverage_q16 = required_period > 0
                        ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                            effective_period_supply, Q16_ONE, required_period,
                            _saturation_count)) : Q16_ONE;
                    const int64_t effective_price = mul_div_sat(
                        _market.price[_market.index(market, candidate.good_id)], Q16_ONE,
                        candidate.efficiency_q16, _saturation_count);
                    if (coverage_q16 > best_coverage_q16 ||
                        (coverage_q16 == best_coverage_q16 &&
                         effective_price < best_price)) {
                        best_coverage_q16 = coverage_q16;
                        best_price = effective_price;
                    }
                }
                if (best_price == std::numeric_limits<int64_t>::max()) {
                    daily_input_cost = std::numeric_limits<int64_t>::max();
                    break;
                }
                const int64_t required_q16 = std::clamp<int64_t>(
                    input.required_q16, 0, Q16_ONE);
                const int64_t soft_bound_q16 = Q16_ONE - required_q16 +
                    mul_div_sat(std::max<int64_t>(0, best_coverage_q16),
                                required_q16, Q16_ONE, _saturation_count);
                input_coverage_bound_q16 = std::min<int64_t>(
                    input_coverage_bound_q16,
                    std::clamp<int64_t>(soft_bound_q16, 0, Q16_ONE));
                daily_input_cost = saturating_add(daily_input_cost, mul_div_sat(
                    input.quantity, best_price, GOODS_SCALE, _saturation_count),
                    _saturation_count);
            }
            if (daily_input_cost == std::numeric_limits<int64_t>::max()) {
                mark_rejection(existing, INVESTMENT_REJECTION_INPUT_CHAIN);
                continue;
            }
            utilization_q16 = std::min(utilization_q16, input_coverage_bound_q16);
            if (utilization_q16 <= 0) {
                mark_rejection(existing, INVESTMENT_REJECTION_INPUT_CHAIN);
                continue;
            }
            int64_t daily_wages = 0;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                daily_wages = saturating_add(daily_wages, saturating_mul(
                    role.slots_per_building, role.reference_wage_per_day,
                    _saturation_count), _saturation_count);
            }
            int64_t full_daily_revenue = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &output = _building_outputs[type.output_begin + i];
                const int64_t buy_price = mul_div_sat(
                    _market.price[_market.index(market, output.good_id)],
                    _good_merchant_buy_factor_q16[output.good_id], Q16_ONE,
                    _saturation_count);
                full_daily_revenue = saturating_add(full_daily_revenue, mul_div_sat(
                    output.quantity, buy_price, GOODS_SCALE, _saturation_count),
                    _saturation_count);
            }
            const int64_t daily_revenue = mul_div_sat(
                full_daily_revenue, utilization_q16, Q16_ONE,
                _saturation_count);
            const int64_t daily_variable_cost = mul_div_sat(saturating_add(
                daily_input_cost, daily_wages, _saturation_count), utilization_q16,
                Q16_ONE, _saturation_count);
            for (int32_t ethnicity = 0; ethnicity < static_cast<int32_t>(
                    _ethnicity_ids.size()); ++ethnicity) {
                const int32_t target_signature = signature_for_profession_ethnicity(
                    type.owner_profession_id, ethnicity);
                if (target_signature < 0) continue;
                const int64_t living_cost = living_cost_for_signature(
                    cell, target_signature, -1, _saturation_count);
                const int64_t owner_livelihood = saturating_mul(
                    living_cost, std::max<int64_t>(1,
                        type.owner_slots_per_building), _saturation_count);
                const int64_t daily_operating_cost = saturating_add(
                    daily_variable_cost, owner_livelihood, _saturation_count);
                const int64_t required_revenue = saturating_add(
                    daily_operating_cost, mul_div_sat(daily_operating_cost,
                        type.target_operating_margin_q16, Q16_ONE,
                        _saturation_count), _saturation_count);
                const int64_t daily_profit = saturating_sub(
                    daily_revenue, daily_operating_cost, _saturation_count);
                if (daily_revenue < daily_operating_cost) {
                    mark_rejection(existing,
                        INVESTMENT_REJECTION_OWNER_LIVELIHOOD);
                    continue;
                }
                if (daily_revenue < required_revenue || daily_profit <= 0) {
                    mark_rejection(existing,
                        INVESTMENT_REJECTION_TARGET_MARGIN);
                    continue;
                }
                const int64_t margin_q16 = daily_operating_cost > 0
                    ? mul_div_sat(daily_profit, Q16_ONE,
                        daily_operating_cost, _saturation_count)
                    : Q16_ONE;
                const int64_t projected_owner_income = saturating_sub(
                    daily_revenue, daily_variable_cost, _saturation_count) /
                    std::max<int64_t>(1, type.owner_slots_per_building);
                const int64_t required_capital = saturating_add(construction_cost,
                    saturating_add(saturating_mul(daily_input_cost,
                        _investment_operating_cycles * std::max(1, _epoch_days),
                        _saturation_count), saturating_add(saturating_mul(
                            daily_wages, std::max(1, _epoch_days), _saturation_count),
                            saturating_mul(owner_livelihood, 30,
                                _saturation_count),
                            _saturation_count), _saturation_count), _saturation_count);
                const int64_t payback = daily_profit > 0
                    ? (required_capital + daily_profit - 1) / daily_profit
                    : std::numeric_limits<int64_t>::max();
                if (payback > _investment_max_payback_days) {
                    mark_rejection(existing, INVESTMENT_REJECTION_PAYBACK);
                    continue;
                }
                bool had_eligible_sponsor = false;
                const int32_t sponsor = find_entrepreneur_source(
                    cell, target_signature, required_capital,
                    std::max<int64_t>(1, projected_owner_income), type_id,
                    had_eligible_sponsor);
                if (sponsor < 0) {
                    if (had_eligible_sponsor) {
                        ++_building_investment_probability_skips;
                        mark_rejection(existing,
                            INVESTMENT_REJECTION_PROBABILITY);
                    } else {
                        eligible_but_unfunded = true;
                        mark_rejection(existing,
                            INVESTMENT_REJECTION_SPONSOR_CAPITAL);
                    }
                    continue;
                }
                if ((_good_ids.size() > 0) && type.kind == 0) {
                    int64_t projected_issue = 0;
                    for (int32_t i = 0; i < type.output_count; ++i) {
                        const GoodAmount &output = _building_outputs[type.output_begin + i];
                        projected_issue = saturating_add(projected_issue, mul_div_sat(
                            saturating_mul(output.quantity, 30, _saturation_count),
                            _good_monetary_issue_values[output.good_id], GOODS_SCALE,
                            _saturation_count), _saturation_count);
                    }
                    const int64_t opening_money = saturating_add(
                        _opening_totals.cohort_funds,
                        saturating_add(_opening_totals.country_cash,
                            _opening_totals.escrow_cash, _saturation_count),
                        _saturation_count);
                    if (projected_issue > 0 && (opening_money <= 0 ||
                        mul_div_sat(projected_issue, Q16_ONE, opening_money,
                                    _saturation_count) > _bullion_monthly_issue_cap_q16 ||
                        minimum_resource_life < _resource_min_horizon_days)) {
                        ++_building_investment_blocked_resources;
                        mark_rejection(existing, INVESTMENT_REJECTION_RESOURCE);
                        continue;
                    }
                }
                Candidate candidate;
                candidate.type = type_id;
                candidate.target_signature = target_signature;
                candidate.sponsor = sponsor;
                candidate.required_capital = required_capital;
                candidate.projected_income = projected_owner_income;
                candidate.shortage_q16 = shortage_q16;
                candidate.utilization_q16 = utilization_q16;
                candidate.profit_per_day = daily_profit;
                candidate.payback_days = payback;
                candidate.score_q16 = saturating_add(
                    (survival_output ? 4 : 2) * shortage_q16,
                    saturating_add(3 * std::max<int64_t>(0,
                        utilization_q16 - _investment_min_utilization_q16),
                        margin_q16, _saturation_count), _saturation_count);
                if (existing_group >= 0) {
                    mark_rejection(existing, INVESTMENT_REJECTION_NONE);
                    for (int32_t group = existing->first_group;
                         group <= existing->last_group; ++group) {
                        if (_buildings[group].cell != cell ||
                            _buildings[group].type_id != type_id) break;
                        _building_investment_score_q16[group] = candidate.score_q16;
                        _building_investment_payback_days[group] = payback;
                    }
                }
                if (better(candidate, best)) best = candidate;
            }
        }
        if (best.type < 0) {
            if (capital_review && eligible_but_unfunded)
                ++_building_investment_blocked_sponsor_capital;
            continue;
        }
        ++_building_investment_candidates;
        const int64_t source_funds_before = _population.funds[best.sponsor];
        const int64_t source_population_before = _population.population[best.sponsor];
        const int64_t source_handle = _population.handle_for_slot(best.sponsor);
        const bool profession_transition = static_cast<int32_t>(
            _population.signature_id[best.sponsor]) != best.target_signature;
        const int32_t target_before_slot = find_cohort_slot(cell, best.target_signature);
        const int64_t target_funds_before = target_before_slot >= 0
            ? _population.funds[target_before_slot] : 0;
        const int64_t target_population_before = target_before_slot >= 0
            ? _population.population[target_before_slot] : 0;
        bool source_drained = false;
        if (profession_transition && !move_cohort_population(
                best.sponsor, cell, best.target_signature, 1, error,
                &source_drained)) return false;
        population_changed = population_changed || profession_transition;
        const int32_t owner_slot = profession_transition
            ? find_cohort_slot(cell, best.target_signature) : best.sponsor;
        if (owner_slot < 0 || owner_slot >= static_cast<int32_t>(
                _population.active.size()) || _population.active[owner_slot] == 0) {
            error = "building_investment_owner_transition_failed";
            return false;
        }
        if (profession_transition && !source_drained) {
            const int64_t carried = _population.funds[owner_slot] - target_funds_before;
            const int64_t correction = best.required_capital - carried;
            if (correction > 0 && _population.funds[best.sponsor] < correction) {
                error = "building_investment_capital_preflight_drift";
                return false;
            }
            if (correction < 0 && _population.funds[owner_slot] < -correction) {
                error = "building_investment_capital_refund_preflight_drift";
                return false;
            }
            touch_accounting_slot(best.sponsor);
            touch_accounting_slot(owner_slot);
            _population.funds[best.sponsor] = saturating_sub(
                _population.funds[best.sponsor], correction, _saturation_count);
            _population.funds[owner_slot] = saturating_add(
                _population.funds[owner_slot], correction, _saturation_count);
            if (_population.funds[best.sponsor] != source_funds_before -
                    best.required_capital) {
                error = "building_investment_capital_transfer_drift";
                return false;
            }
        }
        if (profession_transition) {
            ++_building_owner_mobility;
            _building_investment_capital_transferred = saturating_add(
                _building_investment_capital_transferred, best.required_capital,
                _saturation_count);
        }
        if (profession_transition && trace_detail_for_cell(cell)) {
            const int64_t target_handle = _population.handle_for_slot(owner_slot);
            std::vector<EventLeg> legs;
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                source_handle, -1, source_population_before,
                source_drained ? 0 : _population.population[best.sponsor]});
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                source_handle, -1, source_funds_before,
                source_drained ? 0 : _population.funds[best.sponsor]});
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                target_handle, -1, target_population_before,
                _population.population[owner_slot]});
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                target_handle, -1, target_funds_before,
                _population.funds[owner_slot]});
            trace_append(EVENT_STRUCTURAL_CHANGE,
                static_cast<int32_t>(Stage::BUILDING_COMMIT), cell,
                SUBJECT_COHORT, target_handle, best.type, -1,
                best.required_capital, source_handle, target_handle,
                -(_epoch_id * std::max<int64_t>(1, _cell_count) + cell + 1),
                &legs);
        }
        Command command;
        command.opcode = COMMAND_BUILD;
        command.effective_day = _current_day;
        command.sequence = -(_epoch_id * std::max<int64_t>(1, _cell_count) + cell + 1);
        command.target_handle = _population.handle_for_slot(owner_slot);
        command.i32_0 = cell;
        command.i32_1 = best.type;
        command.i64_0 = 1;
        const size_t pending_before = _pending_construction.size();
        const int64_t consumed_before = _construction_goods_consumed;
        if (!apply_build_command(command, owner_slot, error)) return false;
        if (_pending_construction.size() != pending_before + 1) {
            error = "building_investment_preflight_drift";
            return false;
        }
        const int64_t consumed = _construction_goods_consumed - consumed_before;
        _publish_accum.goods_stock = saturating_sub(
            _publish_accum.goods_stock, consumed, _saturation_count);
        ++_building_investments_started;
        _investment_pending_by_cell_type[cell_key(cell, best.type)] = 1;
    }
    return true;
}

bool NativeEconomyRuntime::commit_ready_construction(std::vector<int32_t> &changed_cells) {
    bool changed = false;
    for (const PendingConstruction &pending : _pending_construction) {
        if (pending.ready_day > _current_day) continue;
        changed = true;
        changed_cells.push_back(pending.cell);
        const int32_t existing = find_building_group(pending.cell, pending.type_id,
                                                     pending.owner_signature_id);
        const int64_t before_count = existing >= 0 ? _buildings[existing].count : 0;
        if (existing >= 0) {
            _buildings[existing].count = saturating_add(_buildings[existing].count,
                                                        pending.count, _saturation_count);
        } else {
            BuildingGroup group;
            group.cell = pending.cell;
            group.type_id = pending.type_id;
            group.owner_signature_id = pending.owner_signature_id;
            group.count = pending.count;
            _buildings.push_back(group);
        }
        const int64_t after_count = existing >= 0 ? _buildings[existing].count
                                                   : _buildings.back().count;
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(pending.cell)) {
            legs.push_back({FIELD_BUILDING_COUNT, SUBJECT_BUILDING_GROUP,
                            pending.owner_signature_id, pending.type_id,
                            before_count, after_count});
        }
        trace_append(EVENT_CONSTRUCTION_COMPLETED,
                     static_cast<int32_t>(Stage::BUILDING_COMMIT), pending.cell,
                     SUBJECT_BUILDING_GROUP, pending.owner_signature_id,
                     pending.type_id, -1, pending.count, before_count,
                     after_count, pending.sequence,
                     legs.empty() ? nullptr : &legs);
    }
    const size_t pending_before = _pending_construction.size();
    _pending_construction.erase(std::remove_if(_pending_construction.begin(),
                                               _pending_construction.end(),
        [&](const PendingConstruction &p) { return p.ready_day <= _current_day; }),
        _pending_construction.end());
    changed = changed || _pending_construction.size() != pending_before;
    const size_t buildings_before = _buildings.size();
    _buildings.erase(std::remove_if(_buildings.begin(), _buildings.end(),
                                    [&](const BuildingGroup &g) {
                                        if (g.count > 0) return false;
                                        changed_cells.push_back(g.cell);
                                        return true;
                                    }),
                     _buildings.end());
    changed = changed || _buildings.size() != buildings_before;
    if (changed) rebuild_building_role_storage();
    return changed;
}

Dictionary NativeEconomyRuntime::configure(const Dictionary &catalog, const Dictionary &profile,
                                           int32_t cell_count, int64_t seed) {
    reset("reconfigure");
    Dictionary out;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    if (cell_count <= 0 || cell_count > 100000) {
        out["ok"] = false;
        out["reason"] = "cell_count_out_of_range";
        return out;
    }
    std::string error;
    if (!configure_profile(profile, error) || !compile_catalog(catalog, error)) {
        reset(String(error.c_str()));
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    _cell_count = cell_count;
    _seed = seed;
    _trace_cell_mask.assign(cell_count, 0);
    _pending_trace_cell_mask.clear();
    _trace_filter_pending = false;
    _inspector_trace_cell = -1;
    _pending_inspector_trace_cell = -1;
    _inspector_trace_pending = false;
    _population.clear(cell_count);
    _market.clear();
    _market_signals.clear(cell_count);
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _cell_last_settlement_day.clear();
    _cell_settlement_generation.clear();
    _cell_price_stock_gen.clear();
    _cell_owner_cash_gen.clear();
    _cell_population_gen.clear();
    _cell_building_structure_gen.clear();
    _cell_technology_gen.clear();
    _cell_resource_gen.clear();
    _cell_trade_gen.clear();
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _pending_construction.clear();
    _investment_pending_by_cell_type.clear();
    _investment_existing_by_cell_type.clear();
    _investment_harvest_by_cell_resource.clear();
    _investment_employment_cells.clear();
    _building_context_day = -1;
    _committed_cells.assign(cell_count, {});
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63) / 64);
    if (_country_runtime == nullptr || !_country_runtime->economy_available()) {
        reset("country_runtime_required");
        out["ok"] = false;
        out["reason"] = "country_runtime_required";
        return out;
    }
    _configured = true;
    _stage = Stage::IDLE;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash;
    out["cell_count"] = _cell_count;
    out["good_count"] = static_cast<int32_t>(_good_ids.size());
    out["signature_count"] = static_cast<int32_t>(_signatures.size());
    out["building_type_count"] = static_cast<int32_t>(_building_types.size());
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    out["rate_scale"] = Q32_ONE;
    return out;
}

Dictionary NativeEconomyRuntime::bootstrap(const Dictionary &population_packet,
                                           const Dictionary &market_packet) {
    Dictionary out;
    out["path"] = "ECONOMY_GRAPH";
    if (!_configured || _epoch_active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" : "epoch_in_flight";
        return out;
    }
    _bootstrapped = false;
    _population.clear(_cell_count);
    _market.clear();
    _market_signals.clear(_cell_count);
    _labor_signals.clear(_cell_count);
    _trade_plan.clear_transient();
    _trade_active_keys.clear();
    _trade_signal_clock_keys.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    _trade_orders.clear();
    _trade_flows.clear();
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _building_role_contract_wage.clear();
    _building_role_base_living_cost.clear();
    _building_role_living_cost.clear();
    _building_role_local_average_wage.clear();
    _building_role_base_wage_due.clear();
    _building_role_base_wage_paid.clear();
    _building_role_bonus_due.clear();
    _building_role_bonus_paid.clear();
    _pending_construction.clear();
    _investment_pending_by_cell_type.clear();
    _investment_existing_by_cell_type.clear();
    _investment_harvest_by_cell_resource.clear();
    _investment_employment_cells.clear();
    std::string country_error;
    if (!capture_country_epoch(country_error)) {
        out["ok"] = false;
        out["reason"] = country_error.c_str();
        return out;
    }

    const std::vector<int32_t> cells = packed_i32(population_packet, "cell_indices");
    const std::vector<int32_t> signatures = packed_i32(population_packet, "signature_ids");
    const std::vector<int64_t> populations = packed_i64(population_packet, "population");
    const std::vector<int64_t> funds = packed_i64(population_packet, "funds");
    if (cells.size() != signatures.size() || cells.size() != populations.size() ||
        cells.size() != funds.size()) {
        out["ok"] = false;
        out["reason"] = "population_packet_size_mismatch";
        return out;
    }
    std::vector<size_t> bootstrap_order(cells.size());
    std::iota(bootstrap_order.begin(), bootstrap_order.end(), size_t{0});
    std::stable_sort(bootstrap_order.begin(), bootstrap_order.end(), [&](size_t a, size_t b) {
        if (cells[a] != cells[b]) return cells[a] < cells[b];
        if (signatures[a] != signatures[b]) return signatures[a] < signatures[b];
        return a < b;
    });
    for (size_t i : bootstrap_order) {
        if (cells[i] < 0 || cells[i] >= _cell_count || signatures[i] < 0 ||
            signatures[i] >= static_cast<int32_t>(_signatures.size()) || populations[i] < 0 ||
            funds[i] < 0) {
            out["ok"] = false;
            out["reason"] = "population_packet_entry_invalid";
            _population.clear(_cell_count);
            return out;
        }
        if (populations[i] == 0) continue;
        const int32_t slot = _population.allocate_slot(cells[i], static_cast<uint32_t>(signatures[i]));
        if (slot < 0) {
            out["ok"] = false;
            out["reason"] = "population_page_allocation_failed";
            _population.clear(_cell_count);
            return out;
        }
        _population.population[slot] = saturating_add(_population.population[slot], populations[i], _saturation_count);
        _population.funds[slot] = saturating_add(_population.funds[slot], funds[i], _saturation_count);
    }

    int64_t merchant_repairs = 0;
    std::string merchant_error;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (!ensure_merchant_invariant(cell, merchant_repairs, merchant_error)) {
            out["ok"] = false;
            out["reason"] = String(merchant_error.c_str());
            _population.clear(_cell_count);
            return out;
        }
    }
    if (!rebuild_merchant_ranges(merchant_error)) {
        out["ok"] = false;
        out["reason"] = String(merchant_error.c_str());
        return out;
    }

    int32_t market_count = dict_num<int32_t>(market_packet, "market_count", _cell_count);
    if (market_count != _cell_count) {
        out["ok"] = false;
        out["reason"] = "market_v2_requires_one_market_per_cell";
        return out;
    }
    _market.market_count = market_count;
    _market.good_count = static_cast<int32_t>(_good_ids.size());
    const int64_t matrix_size = static_cast<int64_t>(market_count) * _market.good_count;
    if (matrix_size <= 0 || matrix_size > 25000000LL) {
        out["ok"] = false;
        out["reason"] = "market_matrix_capacity_exceeded";
        return out;
    }
    _market.stock.resize(static_cast<size_t>(matrix_size));
    _market.price.resize(static_cast<size_t>(matrix_size));
    _market.demand_ema.assign(static_cast<size_t>(matrix_size), 0);
    _market.last_shortage_q16.assign(static_cast<size_t>(matrix_size), 0);
    _market.cell_to_market.resize(_cell_count);
    for (int32_t c = 0; c < _cell_count; ++c) _market.cell_to_market[c] = c % market_count;
    for (int32_t m = 0; m < market_count; ++m) {
        for (int32_t g = 0; g < _market.good_count; ++g) {
            const int64_t idx = _market.index(m, g);
            _market.stock[idx] = 0;
            _market.price[idx] = _good_default_price[g];
        }
    }

    std::vector<int32_t> cell_to_market = packed_i32(market_packet, "cell_to_market");
    if (!cell_to_market.empty()) {
        if (cell_to_market.size() != static_cast<size_t>(_cell_count)) {
            out["ok"] = false;
            out["reason"] = "cell_to_market_size_mismatch";
            return out;
        }
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            if (cell_to_market[cell] != cell) {
                out["ok"] = false;
                out["reason"] = "market_v2_requires_identity_cell_mapping";
                return out;
            }
        }
        _market.cell_to_market.swap(cell_to_market);
    }
    std::vector<int64_t> stock = packed_i64(market_packet, "stock");
    std::vector<int32_t> price = packed_i32(market_packet, "price");
    if (market_packet.has("market_cash")) {
        out["ok"] = false;
        out["reason"] = "market_cash_removed_in_schema_v2";
        return out;
    }
    if (!stock.empty()) {
        if (stock.size() != static_cast<size_t>(matrix_size) ||
            std::any_of(stock.begin(), stock.end(), [](int64_t v) { return v < 0; })) {
            out["ok"] = false;
            out["reason"] = "market_stock_invalid";
            return out;
        }
        _market.stock.swap(stock);
    }
    if (!price.empty()) {
        if (price.size() != static_cast<size_t>(matrix_size)) {
            out["ok"] = false;
            out["reason"] = "market_price_size_mismatch";
            return out;
        }
        for (int32_t m = 0; m < market_count; ++m) {
            for (int32_t g = 0; g < _market.good_count; ++g) {
                const int64_t idx = _market.index(m, g);
                if (price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                    price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                    out["ok"] = false;
                    out["reason"] = "market_price_out_of_range";
                    return out;
                }
            }
        }
        _market.price.swap(price);
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }

    const std::vector<int32_t> building_cells = packed_i32(market_packet, "building_cells");
    const std::vector<int32_t> building_types = packed_i32(market_packet, "building_type_ids");
    const std::vector<int32_t> building_owners = packed_i32(market_packet, "building_owner_signature_ids");
    const std::vector<int64_t> building_counts = packed_i64(market_packet, "building_counts");
    if (building_cells.size() != building_types.size() ||
        building_cells.size() != building_owners.size() ||
        building_cells.size() != building_counts.size()) {
        out["ok"] = false;
        out["reason"] = "building_bootstrap_column_size_mismatch";
        return out;
    }
    for (size_t i = 0; i < building_cells.size(); ++i) {
        if (building_cells[i] < 0 || building_cells[i] >= _cell_count ||
            building_types[i] < 0 || building_types[i] >= static_cast<int32_t>(_building_types.size()) ||
            building_owners[i] < 0 || building_owners[i] >= static_cast<int32_t>(_signatures.size()) ||
            building_counts[i] <= 0 ||
            _signatures[building_owners[i]].profession_id !=
                _building_types[building_types[i]].owner_profession_id) {
            out["ok"] = false;
            out["reason"] = "building_bootstrap_entry_invalid";
            return out;
        }
        const int32_t existing = find_building_group(building_cells[i], building_types[i],
                                                     building_owners[i]);
        if (existing >= 0) {
            _buildings[existing].count = saturating_add(_buildings[existing].count,
                                                        building_counts[i], _saturation_count);
        } else {
            BuildingGroup group;
            group.cell = building_cells[i];
            group.type_id = building_types[i];
            group.owner_signature_id = building_owners[i];
            group.count = building_counts[i];
            _buildings.push_back(group);
        }
    }
    rebuild_building_role_storage();

    if (_configured_target_cohorts_per_slice == 0) {
        _target_cohorts_per_slice = _population.active_count <= 500000 ? 4000
            : (_population.active_count <= 2000000 ? 12000 : 30000);
    }
    if (_auto_slice_by_scale) {
        _cells_per_slice = std::clamp(_market.market_count, 1, 128);
    }
    if (_auto_building_slice_by_scale) _building_cells_per_slice = 256;
    _epoch_days = choose_epoch_days(_population.active_count);
    _commit_lag_budget_days = std::max(0, _epoch_days - 1);
    _last_committed_day = -1;
    _cell_last_settlement_day.resize(_cell_count);
    _cell_settlement_generation.assign(_cell_count, 0);
    _cell_price_stock_gen.assign(_cell_count, 0);
    _cell_owner_cash_gen.assign(_cell_count, 0);
    _cell_population_gen.assign(_cell_count, 0);
    _cell_building_structure_gen.assign(_cell_count, 0);
    _cell_technology_gen.assign(_cell_count, 0);
    _cell_resource_gen.assign(_cell_count, 0);
    _cell_trade_gen.assign(_cell_count, 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _cell_last_settlement_day[cell] =
            static_cast<int64_t>(cell % ROLLING_PHASE_COUNT) - ROLLING_PHASE_COUNT;
    }
    _settlement_watermark = -ROLLING_PHASE_COUNT;
    _settlement_newest_day = -1;
    _settlement_max_age_days = ROLLING_PHASE_COUNT - 1;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _epoch_id = 0;
    _bootstrapped = true;
    _fatal = false;
    _fatal_reason.clear();
    rebuild_committed_summaries();
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    if (_worker_enabled && _population.active_count >= _worker_market_threshold &&
        godot::WorkerThreadPool::get_singleton() != nullptr) {
        const int warm_tasks = _worker_tasks_hint > 0 ? _worker_tasks_hint : 16;
        auto warm_worker = [](int32_t begin, int32_t end) {
            volatile uint32_t local = 0;
            for (int32_t i = begin; i < end; ++i) local ^= static_cast<uint32_t>(i);
            (void)local;
        };
        parallel_for_range("pk_economy_warmup", 1024, warm_tasks, 1, warm_worker);
    }
    out["ok"] = true;
    out["cohort_count"] = _population.active_count;
    out["market_count"] = _market.market_count;
    out["good_count"] = _market.good_count;
    out["epoch_days"] = _epoch_days;
    out["market_cycle_days"] = _epoch_days;
    out["market_configured_cycle_days"] = _configured_epoch_days;
    out["market_min_cycle_days"] = _min_epoch_days;
    out["markets_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    out["approximation_model"] = "rolling_cell_settlement_v15";
    out["settlement_phase_count"] = ROLLING_PHASE_COUNT;
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = merchant_repairs;
    out["building_group_count"] = static_cast<int64_t>(_buildings.size());
    out["memory_bytes"] = memory_bytes();
    return out;
}

Dictionary NativeEconomyRuntime::submit_commands(const Dictionary &batch) {
    Dictionary out;
    if (!_bootstrapped || _fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                                         : (_fatal ? "economy_fatal" : "save_restore_active");
        return out;
    }
    const std::vector<int32_t> opcodes = packed_i32(batch, "opcodes");
    const std::vector<int64_t> days = packed_i64(batch, "effective_days");
    const std::vector<int64_t> sequences = packed_i64(batch, "sequences");
    const std::vector<int64_t> handles = packed_i64(batch, "target_handles");
    const std::vector<int32_t> i32_0 = packed_i32(batch, "i32_0");
    const std::vector<int32_t> i32_1 = packed_i32(batch, "i32_1");
    const std::vector<int64_t> i64_0 = packed_i64(batch, "i64_0");
    const std::vector<int64_t> i64_1 = packed_i64(batch, "i64_1");
    const size_t n = opcodes.size();
    if (days.size() != n || sequences.size() != n || handles.size() != n ||
        i32_0.size() != n || i32_1.size() != n || i64_0.size() != n || i64_1.size() != n) {
        out["ok"] = false;
        out["reason"] = "command_batch_size_mismatch";
        return out;
    }
    if (_pending_commands.size() + n > 1000000ULL) {
        out["ok"] = false;
        out["reason"] = "command_queue_capacity_exceeded";
        return out;
    }
    // Preflight the whole batch before mutating the queue.
    for (size_t i = 0; i < n; ++i) {
        if (opcodes[i] < COMMAND_TRANSFER_TO_COHORT || opcodes[i] > COMMAND_MARKET_GOOD_TO_COUNTRY ||
            days[i] < 0 || sequences[i] < 0 ||
            (i64_0[i] < 0 && opcodes[i] != COMMAND_ADD_POPULATION)) {
            out["ok"] = false;
            out["reason"] = "command_entry_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (opcodes[i] != COMMAND_ADD_STOCK && opcodes[i] != COMMAND_REMOVE_STOCK &&
            opcodes[i] != COMMAND_COUNTRY_GOOD_TO_MARKET &&
            opcodes[i] != COMMAND_MARKET_GOOD_TO_COUNTRY) {
            int32_t slot = -1;
            if (!_population.valid_handle(static_cast<uint64_t>(handles[i]), slot)) {
                out["ok"] = false;
                out["reason"] = "stale_or_invalid_cohort_handle";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_REMOVE_STOCK ||
             opcodes[i] == COMMAND_COUNTRY_GOOD_TO_MARKET ||
             opcodes[i] == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
            (i32_0[i] < 0 || i32_0[i] >= _market.market_count || i32_1[i] < 0 ||
             i32_1[i] >= _market.good_count)) {
            out["ok"] = false;
            out["reason"] = "command_market_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
            _merchant_primary_slot[i32_0[i]] < 0) {
            out["ok"] = false;
            out["reason"] = "cannot_add_stock_without_local_merchant";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_MOVE_POPULATION &&
             (i32_0[i] < 0 || i32_0[i] >= _cell_count)) ||
            (opcodes[i] == COMMAND_CHANGE_SIGNATURE &&
             (i32_0[i] < 0 || i32_0[i] >= static_cast<int32_t>(_signatures.size())))) {
            out["ok"] = false;
            out["reason"] = "command_structural_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if ((opcodes[i] == COMMAND_BUILD || opcodes[i] == COMMAND_DEMOLISH) &&
            (i32_0[i] < 0 || i32_0[i] >= _cell_count || i32_1[i] < 0 ||
             i32_1[i] >= static_cast<int32_t>(_building_types.size()) || i64_0[i] <= 0)) {
            out["ok"] = false;
            out["reason"] = "command_building_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
    }
    for (size_t i = 0; i < n; ++i) {
        _pending_commands.push_back({opcodes[i], days[i], sequences[i],
                                     static_cast<uint64_t>(handles[i]), i32_0[i], i32_1[i],
                                     i64_0[i], i64_1[i], _next_submit_order++});
    }
    out["ok"] = true;
    out["accepted"] = static_cast<int64_t>(n);
    out["queued"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

int32_t NativeEconomyRuntime::choose_epoch_days(int64_t cohorts) {
    const int64_t rolling_markets = (_market.market_count + ROLLING_PHASE_COUNT - 1) /
        ROLLING_PHASE_COUNT;
    const int64_t rolling_cohorts = (cohorts + ROLLING_PHASE_COUNT - 1) /
        ROLLING_PHASE_COUNT;
    const int64_t market_cell_slices = rolling_markets <= 0 ? 0 :
        (rolling_markets + std::max(1, _cells_per_slice) - 1) /
            std::max(1, _cells_per_slice);
    const int64_t market_cohort_slices = rolling_cohorts <= 0 ? 0 :
        (rolling_cohorts + std::max<int64_t>(1, _target_cohorts_per_slice) - 1) /
            std::max<int64_t>(1, _target_cohorts_per_slice);
    _estimated_market_slices_per_epoch = static_cast<int32_t>(std::clamp<int64_t>(
        std::max<int64_t>({1, market_cell_slices, market_cohort_slices}), 1,
        std::numeric_limits<int32_t>::max()));

    const int64_t building_ranges = std::max<int64_t>(0,
        (estimate_building_ranges() + ROLLING_PHASE_COUNT - 1) /
            ROLLING_PHASE_COUNT);
    _estimated_building_slices_per_epoch = static_cast<int32_t>(
        std::min<int64_t>(std::numeric_limits<int32_t>::max(), building_ranges * 4));
    // Two planning passes, employment and production consume four building
    // ranges. The fixed allowance covers ledger/dispatch/structural/publish
    // boundaries that cannot always fuse with a range-bearing call.
    constexpr int64_t FIXED_STAGE_MARGIN = 4;
    const int64_t raw_total = static_cast<int64_t>(
        _estimated_market_slices_per_epoch) +
        _estimated_building_slices_per_epoch + FIXED_STAGE_MARGIN;
    // SUS may legitimately budget-skip economy while native climate/visual
    // work occupies the frame. Reserve deterministic slack for that known
    // scheduler boundary; cadence never reads wall time or frame duration.
    const int64_t estimated_total = raw_total;
    _estimated_total_slices_per_epoch = static_cast<int32_t>(std::clamp<int64_t>(
        estimated_total, 1, std::numeric_limits<int32_t>::max()));

    _workload_cycle_clamped = false;
    _workload_deadline_feasible = true;
    return ROLLING_PHASE_COUNT;
}

int32_t NativeEconomyRuntime::building_slice_end(int32_t active_begin) const {
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    const int32_t active_count = static_cast<int32_t>(active_cells.size());
    active_begin = std::clamp(active_begin, 0, active_count);
    const int32_t cell_limit = std::min(active_count,
        active_begin + std::max(1, _building_cells_per_slice));
    int32_t end = active_begin;
    int64_t groups = 0;
    while (end < cell_limit) {
        const int32_t cell = active_cells[end];
        const int64_t cell_groups = _building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count + 1)
            ? _building_cell_offsets[cell + 1] - _building_cell_offsets[cell] : 0;
        if (end > active_begin && groups + cell_groups > _building_groups_per_slice)
            break;
        groups += cell_groups;
        ++end;
    }
    return end;
}

int32_t NativeEconomyRuntime::estimate_building_ranges() const {
    int32_t ranges = 0;
    int32_t cursor = 0;
    const int32_t active_count = static_cast<int32_t>(_building_active_cells.size());
    while (cursor < active_count) {
        const int32_t end = building_slice_end(cursor);
        cursor = std::max(cursor + 1, end);
        ++ranges;
    }
    return ranges;
}

bool NativeEconomyRuntime::should_run(int64_t day_index) const {
    // PROBE is deliberately non-authoritative. It may be exercised by explicit
    // focused tests/benchmarks, but the production scheduler must not mutate the
    // committed market until the ACTIVE performance gate has passed.
    if (!_bootstrapped || _fatal || _save.active || _restore.active || _market_runtime_mode != 2)
        return false;
    // A running frozen cycle is intentionally isolated from live country
    // changes. A new cycle, however, must wait until every due country command
    // for this day has committed at country_daily priority 255.
    if (!_epoch_active && _country_runtime != nullptr &&
        _country_runtime->should_run(day_index))
        return false;
    return _epoch_active || day_index > _last_committed_day ||
           trade_planner_should_run();
}

bool NativeEconomyRuntime::trade_planner_should_run() const {
    return _market_runtime_mode == 2 && _trade_runtime_mode != 0 &&
           _trade_plan.phase != TradePlanStore::IDLE;
}

bool NativeEconomyRuntime::rebuild_trade_components(std::string &error) {
    if (!_trade_topology.ready ||
        _trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6 ||
        _trade_topology.passable.size() != static_cast<size_t>(_cell_count) ||
        _epoch_cell_country.size() != static_cast<size_t>(_cell_count)) {
        error = "trade_topology_or_country_snapshot_not_ready";
        return false;
    }
    if (_trade_topology.component_country_hash == _epoch_country_topology_hash &&
        _trade_topology.component.size() == static_cast<size_t>(_cell_count)) return true;
    _trade_topology.component.assign(static_cast<size_t>(_cell_count), -1);
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(std::min(_cell_count, 65536)));
    int32_t next_component = 0;
    for (int32_t seed = 0; seed < _cell_count; ++seed) {
        const int32_t country = _epoch_cell_country[seed];
        if (country < 0 || _trade_topology.passable[seed] == 0 ||
            _trade_topology.component[seed] >= 0) continue;
        queue.clear();
        queue.push_back(seed);
        _trade_topology.component[seed] = next_component;
        for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
            const int32_t cell = queue[cursor];
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _trade_topology.neighbors[
                    static_cast<size_t>(cell) * 6 + direction];
                if (neighbor < 0 || _trade_topology.passable[neighbor] == 0 ||
                    _epoch_cell_country[neighbor] != country ||
                    _trade_topology.component[neighbor] >= 0) continue;
                _trade_topology.component[neighbor] = next_component;
                queue.push_back(neighbor);
            }
        }
        ++next_component;
    }
    _trade_topology.component_country_hash = _epoch_country_topology_hash;
    std::fill(_trade_plan.route_cache_keys.begin(),
              _trade_plan.route_cache_keys.end(), std::numeric_limits<uint64_t>::max());
    return true;
}

bool NativeEconomyRuntime::begin_trade_plan(std::string &error) {
    if (_trade_runtime_mode == 0 || !_trade_topology.ready || _market.market_count <= 0 ||
        _market.good_count <= 0) return true;
    if (!rebuild_trade_components(error)) return false;
    _trade_plan.phase = TradePlanStore::SCAN;
    _trade_plan.scan_cursor = 0;
    _trade_plan.route_cursor = 0;
    std::sort(_trade_active_keys.begin(), _trade_active_keys.end());
    _trade_active_keys.erase(std::unique(_trade_active_keys.begin(), _trade_active_keys.end()),
                             _trade_active_keys.end());
    _trade_plan.scan_cells.clear();
    _trade_plan.scan_goods.clear();
    _trade_plan.scan_inbound.clear();
    _trade_plan.scan_cells.reserve(_trade_active_keys.size());
    _trade_plan.scan_goods.reserve(_trade_active_keys.size());
    _trade_plan.scan_inbound.assign(_trade_active_keys.size(), 0);
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        const int32_t destination = _trade_orders.destinations[order];
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            const uint64_t key = (static_cast<uint64_t>(
                static_cast<uint32_t>(destination)) << 32) |
                static_cast<uint32_t>(_trade_orders.line_goods[line]);
            const auto it = std::lower_bound(_trade_active_keys.begin(),
                                             _trade_active_keys.end(), key);
            if (it == _trade_active_keys.end() || *it != key) continue;
            const size_t index = static_cast<size_t>(it - _trade_active_keys.begin());
            _trade_plan.scan_inbound[index] = saturating_add(
                _trade_plan.scan_inbound[index], _trade_orders.line_quantities[line],
                _saturation_count);
        }
    }
    if (!_trade_active_keys.empty()) {
        const size_t signal_count = _trade_active_keys.size();
        const uint64_t day = static_cast<uint64_t>(std::max<int64_t>(0, _sample_day));
        const size_t rotation = static_cast<size_t>(
            (day * static_cast<uint64_t>(std::max(1, _trade_max_signals))) %
            static_cast<uint64_t>(signal_count));
        std::vector<int64_t> rotated_inbound;
        rotated_inbound.reserve(signal_count);
        for (size_t offset = 0; offset < signal_count; ++offset) {
            const size_t index = (rotation + offset) % signal_count;
            const uint64_t key = _trade_active_keys[index];
            _trade_plan.scan_cells.push_back(static_cast<int32_t>(key >> 32));
            _trade_plan.scan_goods.push_back(static_cast<int32_t>(key & 0xffffffffU));
            rotated_inbound.push_back(_trade_plan.scan_inbound[index]);
        }
        _trade_plan.scan_inbound.swap(rotated_inbound);
    }
    _trade_plan.scan_total = static_cast<int64_t>(_trade_plan.scan_cells.size());
    _trade_plan.country_topology_hash = _epoch_country_topology_hash;
    _trade_plan.topology_generation = _trade_topology.topology_generation;
    _trade_plan.sources.clear();
    _trade_plan.destinations.clear();
    _trade_plan.working_candidates.clear();
    _trade_plan.distance.assign(static_cast<size_t>(_cell_count), 0);
    _trade_plan.distance_stamp.assign(static_cast<size_t>(_cell_count), 0);
    _trade_plan.target_signal.assign(static_cast<size_t>(_cell_count), -1);
    _trade_plan.target_stamp.assign(static_cast<size_t>(_cell_count), 0);
    _trade_plan.heap.clear();
    size_t cache_size = 1;
    while (cache_size < static_cast<size_t>(_trade_route_cache_entries)) cache_size <<= 1;
    _trade_plan.route_cache_keys.assign(cache_size, std::numeric_limits<uint64_t>::max());
    _trade_plan.route_cache_costs.assign(cache_size, -1);
    return true;
}

int32_t NativeEconomyRuntime::estimate_trade_price(
        int32_t market, int32_t good, int64_t stock_after, int64_t &sat) const {
    const int64_t index = _market.index(market, good);
    const int32_t signal = market_signal_index(market, good);
    const PricePressure pressure = price_pressure(
        market, good, _market.demand_ema[index], std::max<int64_t>(0, stock_after),
        _market.last_shortage_q16[index], signal, sat);
    const int64_t change = std::clamp<int64_t>(pressure.change_q16,
        -static_cast<int64_t>(_good_max_price_fall_q16[good]),
        static_cast<int64_t>(_good_max_price_rise_q16[good]));
    const int64_t period_change = saturating_mul(change, std::max(1, _epoch_days), sat);
    int64_t next = saturating_add(_market.price[index], mul_div_sat(
        _market.price[index], period_change, Q16_ONE, sat), sat);
    if (pressure.cost_floor_price > _market.price[index]) {
        const int64_t max_rise_period = saturating_mul(
            _good_max_price_rise_q16[good], std::max(1, _epoch_days), sat);
        const int64_t max_cost_price = saturating_add(_market.price[index], mul_div_sat(
            _market.price[index], max_rise_period, Q16_ONE, sat), sat);
        next = std::max(next, std::min<int64_t>(
            pressure.cost_floor_price, max_cost_price));
    }
    return static_cast<int32_t>(std::clamp<int64_t>(
        next, PRICE_NUMERIC_GUARD_MIN, PRICE_NUMERIC_GUARD_MAX));
}

int64_t NativeEconomyRuntime::trade_relief_pressure_q16(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return 0;
    const int64_t index = _market.index(market, good);
    int64_t pressure = 0;
    const bool survival_good =
        (good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
         _survival_food_good_mask[good] != 0) ||
        (good < static_cast<int32_t>(_survival_clothing_good_mask.size()) &&
         _survival_clothing_good_mask[good] != 0);
    if (survival_good) {
        pressure = std::max<int64_t>(pressure,
            std::clamp<int64_t>(_market.last_shortage_q16[index], 0, Q16_ONE));
    }
    const int32_t signal = market_signal_index(market, good);
    if (signal >= 0 && signal < static_cast<int32_t>(
            _epoch_desired_business_demand.size())) {
        const int64_t desired = _epoch_desired_business_demand[signal];
        const int64_t funded = signal < static_cast<int32_t>(
            _epoch_funded_business_demand.size())
            ? _epoch_funded_business_demand[signal] : 0;
        if (desired > funded) {
            pressure = std::max<int64_t>(pressure, std::clamp<int64_t>(
                mul_div_sat(desired - funded, Q16_ONE,
                            std::max<int64_t>(1, desired), sat), 0, Q16_ONE));
        }
    }
    if (signal >= 0 && signal < static_cast<int32_t>(
            _production_input_reserve.size())) {
        const int64_t reserve = std::max<int64_t>(0, _production_input_reserve[signal]);
        const int64_t stock = std::max<int64_t>(0, _market.stock[index]);
        if (reserve > stock) {
            pressure = std::max<int64_t>(pressure, std::clamp<int64_t>(
                mul_div_sat(reserve - stock, Q16_ONE, std::max<int64_t>(1, reserve), sat),
                0, Q16_ONE));
        }
    }
    return pressure;
}

int64_t NativeEconomyRuntime::trade_local_stock_target(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return 0;
    const int64_t index = _market.index(market, good);
    int64_t demand = _market.demand_ema[index];
    const int32_t signal = market_signal_index(market, good);
    if (signal >= 0) demand = saturating_add(
        demand, _market_signals.business_demand_ema[signal], sat);
    const int64_t relief_q16 = trade_relief_pressure_q16(market, good, sat);
    if (relief_q16 > 0) {
        const int64_t relief_base = std::max<int64_t>(demand, GOODS_SCALE);
        demand = saturating_add(demand,
            mul_div_sat(relief_base, relief_q16, Q16_ONE, sat), sat);
    }
    int64_t target = mul_div_sat(
        demand, _good_target_inventory_days_q16[good], Q16_ONE, sat);
    target = mul_div_sat(target, _trade_import_fill_fraction_q16, Q16_ONE, sat);
    if (signal >= 0 && signal < static_cast<int32_t>(
            _production_input_reserve.size())) {
        target = std::max(target, _production_input_reserve[signal]);
    }
    return std::max<int64_t>(0, target);
}

int64_t NativeEconomyRuntime::trade_export_floor(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return 0;
    const int32_t signal = market_signal_index(market, good);
    const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->trade_flow_index(
        market, good, false);
    const int64_t realized = signal >= 0
        ? _market_signals.realized_withdrawal_ema[signal] : 0;
    const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
    const int64_t stock = _market.stock[_market.index(market, good)];
    const int64_t merchant_target = merchant_inventory_target(
        market, good, signal, realized, exports, 0, sat);
    int64_t floor = mul_div_sat(
        merchant_target, _trade_export_inventory_fraction_q16, Q16_ONE, sat);
    floor = std::max(floor, saturating_mul(
        realized, _trade_export_floor_days, sat));
    if (signal >= 0 && signal < static_cast<int32_t>(_production_input_reserve.size())) {
        floor = std::max(floor, _production_input_reserve[signal]);
    }
    return std::clamp<int64_t>(floor, 0, std::max<int64_t>(0, stock));
}

int64_t NativeEconomyRuntime::profitable_trade_quantity(
        int32_t source, int32_t destination, int32_t good,
        int64_t max_quantity, bool relief_route, int32_t &source_price,
        int32_t &destination_price, int64_t &profit, int64_t &margin_q16,
        int64_t &sat) const {
    source_price = destination_price = 0;
    profit = margin_q16 = 0;
    if (max_quantity <= 0) return 0;
    const int64_t source_stock = _market.stock[_market.index(source, good)];
    const int64_t destination_stock = _market.stock[_market.index(destination, good)];
    auto quote = [&](int64_t quantity, int32_t &quoted_source,
                     int32_t &quoted_destination, int64_t &quoted_profit,
                     int64_t &quoted_margin) {
        quoted_source = estimate_trade_price(
            source, good, source_stock - quantity, sat);
        quoted_destination = estimate_trade_price(
            destination, good, destination_stock + quantity, sat);
        const int64_t spread = static_cast<int64_t>(quoted_destination) - quoted_source;
        quoted_margin = spread <= 0 ? 0 : mul_div_sat(
            spread, Q16_ONE, std::max<int64_t>(1, quoted_source), sat);
        quoted_profit = spread <= 0 ? 0 : std::max<int64_t>(1, mul_div_sat(
            quantity, spread, GOODS_SCALE, sat));
        return relief_route ? spread >= 0
            : (spread > 0 && quoted_margin >= _trade_min_margin_q16);
    };
    int64_t low = 1;
    int64_t high = max_quantity;
    int64_t best = 0;
    while (low <= high) {
        const int64_t mid = low + (high - low) / 2;
        int32_t quoted_source = 0;
        int32_t quoted_destination = 0;
        int64_t quoted_profit = 0;
        int64_t quoted_margin = 0;
        if (quote(mid, quoted_source, quoted_destination,
                  quoted_profit, quoted_margin)) {
            best = mid;
            source_price = quoted_source;
            destination_price = quoted_destination;
            profit = quoted_profit;
            margin_q16 = quoted_margin;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    if (best > 0 && best != max_quantity) {
        quote(best, source_price, destination_price, profit, margin_q16);
    }
    return best;
}

int64_t NativeEconomyRuntime::merchant_inventory_target(
        int32_t market, int32_t good, int32_t signal_index,
        int64_t realized_withdrawal,
        int64_t export_ema, int64_t cold_start_daily_supply, int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count || _good_storage_modes[good] != 0) return 0;
    const int64_t index = _market.index(market, good);
    int64_t feasible_daily = _market.demand_ema[index];
    if (signal_index >= 0) feasible_daily = saturating_add(
        feasible_daily, _market_signals.business_demand_ema[signal_index], sat);
    int64_t protected_daily = std::max<int64_t>(
        std::max<int64_t>(0, realized_withdrawal), feasible_daily);
    // Preserve the configured inventory-day target and add a smoothed
    // producer-income floor. This avoids procurement collapsing solely
    // because a short demand EMA window dipped while producers stayed active.
    int64_t smoothed_supply = std::max<int64_t>(0, cold_start_daily_supply);
    if (signal_index >= 0 && signal_index < static_cast<int32_t>(
            _market_signals.offered_supply_ema.size())) {
        smoothed_supply = std::max<int64_t>(smoothed_supply,
            _market_signals.offered_supply_ema[signal_index]);
    }
    const bool survival_good = _survival_food_good_mask[good] != 0 ||
        _survival_clothing_good_mask[good] != 0;
    protected_daily = std::max<int64_t>(protected_daily,
        smoothed_supply / (survival_good ? 2 : 4));
    if (protected_daily == 0 && export_ema <= 0) {
        protected_daily = std::max<int64_t>(0, cold_start_daily_supply);
    }
    const int64_t relief_q16 = trade_relief_pressure_q16(market, good, sat);
    if (relief_q16 > 0) {
        const int64_t relief_base = std::max<int64_t>(
            std::max<int64_t>(protected_daily, feasible_daily),
            std::max<int64_t>(GOODS_SCALE, cold_start_daily_supply));
        protected_daily = saturating_add(protected_daily,
            mul_div_sat(relief_base, relief_q16, Q16_ONE, sat), sat);
    }
    int64_t target = mul_div_sat(saturating_add(
        protected_daily, std::max<int64_t>(0, export_ema), sat),
        _good_target_inventory_days_q16[good], Q16_ONE, sat);
    if (signal_index >= 0 && signal_index < static_cast<int32_t>(
            _production_input_reserve.size())) {
        target = std::max(target, _production_input_reserve[signal_index]);
    }
    return std::max<int64_t>(0, target);
}

int32_t NativeEconomyRuntime::effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const {
    if (good < 0 || good >= _market.good_count || market < 0 ||
        market >= _market.market_count) return 0;
    const int64_t base = std::clamp<int64_t>(
        _good_merchant_buy_factor_q16[good], 0, Q16_ONE);
    int64_t pressure = std::clamp<int64_t>(
        _market.last_shortage_q16[_market.index(market, good)], 0, Q16_ONE);
    if (target > 0 && stock < target) {
        pressure = std::max<int64_t>(pressure, std::clamp<int64_t>(
            mul_div_sat(target - stock, Q16_ONE, target, sat), 0, Q16_ONE));
    }
    return static_cast<int32_t>(std::clamp<int64_t>(saturating_add(
        base, mul_div_sat(Q16_ONE - base, pressure, Q16_ONE, sat), sat),
        base, Q16_ONE));
}

int32_t NativeEconomyRuntime::cached_trade_route_cost(
        int32_t source, int32_t destination, int32_t country, int32_t &expansions) {
    expansions = 0;
    if (source == destination) return 0;
    if (source < 0 || destination < 0 || source >= _cell_count || destination >= _cell_count ||
        _trade_plan.route_cache_keys.empty() || _trade_topology.component[source] < 0 ||
        _trade_topology.component[source] != _trade_topology.component[destination] ||
        _epoch_cell_country[source] != country || _epoch_cell_country[destination] != country)
        return -1;
    const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(source)) << 32) |
                         static_cast<uint32_t>(destination);
    const size_t mask = _trade_plan.route_cache_keys.size() - 1;
    size_t slot = static_cast<size_t>((key ^ (key >> 33) ^ (key >> 17)) & mask);
    for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
        if (_trade_plan.route_cache_keys[slot] == key) {
            ++_trade_route_cache_hits;
            return _trade_plan.route_cache_costs[slot];
        }
        if (_trade_plan.route_cache_keys[slot] == std::numeric_limits<uint64_t>::max()) break;
    }
    ++_trade_route_cache_misses;
    if (++_trade_plan.search_stamp == 0) {
        std::fill(_trade_plan.distance_stamp.begin(), _trade_plan.distance_stamp.end(), 0);
        _trade_plan.search_stamp = 1;
    }
    const uint32_t stamp = _trade_plan.search_stamp;
    auto greater_node = [](const auto &a, const auto &b) {
        return a.first != b.first ? a.first > b.first : a.second > b.second;
    };
    _trade_plan.heap.clear();
    _trade_plan.distance[source] = 0;
    _trade_plan.distance_stamp[source] = stamp;
    _trade_plan.heap.push_back({0, source});
    std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
    int32_t result = -1;
    while (!_trade_plan.heap.empty() && expansions < _trade_max_route_expansions) {
        std::pop_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        const auto current = _trade_plan.heap.back();
        _trade_plan.heap.pop_back();
        const int32_t cell = current.second;
        if (_trade_plan.distance_stamp[cell] != stamp ||
            current.first != _trade_plan.distance[cell]) continue;
        ++expansions;
        if (cell == destination) {
            result = current.first > std::numeric_limits<int32_t>::max()
                ? -1 : static_cast<int32_t>(current.first);
            break;
        }
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || _trade_topology.passable[neighbor] == 0 ||
                _epoch_cell_country[neighbor] != country) continue;
            const int64_t next = current.first + _trade_topology.enter_cost[neighbor];
            if (_trade_plan.distance_stamp[neighbor] == stamp &&
                _trade_plan.distance[neighbor] <= next) continue;
            _trade_plan.distance_stamp[neighbor] = stamp;
            _trade_plan.distance[neighbor] = next;
            _trade_plan.heap.push_back({next, neighbor});
            std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        }
    }
    _trade_route_expansions += expansions;
    slot = static_cast<size_t>((key ^ (key >> 33) ^ (key >> 17)) & mask);
    for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
        if (_trade_plan.route_cache_keys[slot] == std::numeric_limits<uint64_t>::max() ||
            _trade_plan.route_cache_keys[slot] == key) break;
    }
    _trade_plan.route_cache_keys[slot] = key;
    _trade_plan.route_cache_costs[slot] = result;
    return result;
}

bool NativeEconomyRuntime::route_trade_source(int32_t source_index, std::string &error) {
    if (source_index < 0 || source_index >= static_cast<int32_t>(_trade_plan.sources.size())) {
        error = "trade_source_cursor_invalid";
        return false;
    }
    const TradeSignal &source = _trade_plan.sources[source_index];
    int32_t accepted = 0;
    auto append_candidate = [&](const TradeSignal &destination, int32_t route_cost) {
        record_trade_signal_attempt(
            destination.cell, source.good, TRADE_SIGNAL_DIAG_NONE);
        int64_t sat = 0;
        const int64_t requested_quantity = std::min(
            source.quantity, destination.quantity);
        if (requested_quantity <= 0 || route_cost <= 0) return false;
        const int64_t relief_q16 = trade_relief_pressure_q16(
            destination.cell, source.good, sat);
        const bool relief_route = relief_q16 >= Q16_ONE / 8;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        int64_t profit = 0;
        int64_t margin_q16 = 0;
        const int64_t quantity = profitable_trade_quantity(
            source.cell, destination.cell, source.good, requested_quantity,
            relief_route, source_price, destination_price, profit,
            margin_q16, sat);
        if (quantity <= 0) {
            int32_t unit_source = 0;
            int32_t unit_destination = 0;
            int64_t unit_profit = 0;
            int64_t unit_margin = 0;
            profitable_trade_quantity(source.cell, destination.cell, source.good,
                1, true, unit_source, unit_destination, unit_profit,
                unit_margin, sat);
            if (unit_destination <= unit_source) {
                ++_trade_rejected_no_spread;
                record_trade_signal_attempt(destination.cell, source.good,
                    TRADE_SIGNAL_DIAG_NO_SPREAD);
            } else {
                ++_trade_rejected_margin;
                record_trade_signal_attempt(destination.cell, source.good,
                    TRADE_SIGNAL_DIAG_MARGIN);
            }
            ++_trade_rejected_profit;
            return false;
        }
        if (quantity < requested_quantity) ++_trade_quantity_profit_clips;
        const int64_t load = mul_div_sat(quantity,
            _good_transport_load_per_unit_q16[source.good], GOODS_SCALE, sat);
        const int64_t capacity = saturating_mul(load, route_cost, sat);
        if (capacity <= 0) {
            ++_trade_rejected_profit;
            return false;
        }
        if (relief_route) ++_trade_relief_candidates;
        if (relief_route && profit <= 0) {
            profit = std::max<int64_t>(1, mul_div_sat(
                mul_div_sat(quantity, std::max<int64_t>(1, source_price),
                            GOODS_SCALE, sat),
                std::max<int64_t>(1, relief_q16), Q16_ONE, sat));
        }
        TradeCandidate candidate;
        candidate.source = source.cell;
        candidate.destination = destination.cell;
        candidate.good = source.good;
        candidate.country = source.country;
        candidate.route_cost = route_cost;
        candidate.source_price = source_price;
        candidate.destination_price = destination_price;
        candidate.quantity = quantity;
        candidate.expected_profit = profit;
        candidate.capacity_work = capacity;
        candidate.density_q16 = mul_div_sat(profit, Q16_ONE, capacity, sat);
        candidate.signal_age_days = destination.age_days;
        candidate.topology_generation = _trade_topology.topology_generation;
        candidate.country_topology_hash = _epoch_country_topology_hash;
        if (static_cast<int32_t>(_trade_plan.working_candidates.size()) <
            _trade_max_candidates) {
            _trade_plan.working_candidates.push_back(candidate);
            ++_trade_candidates_generated;
            return true;
        }
        return false;
    };
    if (_trade_plan.route_cache_keys.empty() ||
        _trade_topology.component[source.cell] < 0) return true;
    if (++_trade_plan.search_stamp == 0) {
        std::fill(_trade_plan.distance_stamp.begin(), _trade_plan.distance_stamp.end(), 0);
        std::fill(_trade_plan.target_stamp.begin(), _trade_plan.target_stamp.end(), 0);
        _trade_plan.search_stamp = 1;
    }
    const uint32_t stamp = _trade_plan.search_stamp;
    const size_t mask = _trade_plan.route_cache_keys.size() - 1;
    int32_t pending_targets = 0;
    for (int32_t d = 0; d < static_cast<int32_t>(_trade_plan.destinations.size()); ++d) {
        const TradeSignal &destination = _trade_plan.destinations[d];
        if (destination.good != source.good || destination.country != source.country ||
            destination.cell == source.cell ||
            _trade_topology.component[source.cell] !=
                _trade_topology.component[destination.cell]) continue;
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(source.cell)) << 32) |
            static_cast<uint32_t>(destination.cell);
        size_t slot = static_cast<size_t>(
            (key ^ (key >> 33) ^ (key >> 17)) & mask);
        bool found = false;
        int32_t cached_cost = -1;
        for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
            if (_trade_plan.route_cache_keys[slot] == key) {
                found = true;
                cached_cost = _trade_plan.route_cache_costs[slot];
                break;
            }
            if (_trade_plan.route_cache_keys[slot] ==
                std::numeric_limits<uint64_t>::max()) break;
        }
        if (found) {
            ++_trade_route_cache_hits;
            if (cached_cost > 0 && accepted < _trade_target_count &&
                append_candidate(destination, cached_cost)) ++accepted;
            else if (cached_cost <= 0) record_trade_signal_attempt(
                destination.cell, source.good, TRADE_SIGNAL_DIAG_ROUTE);
            continue;
        }
        ++_trade_route_cache_misses;
        _trade_plan.target_stamp[destination.cell] = stamp;
        _trade_plan.target_signal[destination.cell] = d;
        ++pending_targets;
    }
    if (accepted >= _trade_target_count || pending_targets == 0) return true;
    auto greater_node = [](const auto &a, const auto &b) {
        return a.first != b.first ? a.first > b.first : a.second > b.second;
    };
    _trade_plan.heap.clear();
    _trade_plan.distance[source.cell] = 0;
    _trade_plan.distance_stamp[source.cell] = stamp;
    _trade_plan.heap.push_back({0, source.cell});
    std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
    int32_t expansions = 0;
    while (!_trade_plan.heap.empty() && expansions < _trade_max_route_expansions &&
           accepted < _trade_target_count && pending_targets > 0) {
        std::pop_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        const auto current = _trade_plan.heap.back();
        _trade_plan.heap.pop_back();
        const int32_t cell = current.second;
        if (_trade_plan.distance_stamp[cell] != stamp ||
            _trade_plan.distance[cell] != current.first) continue;
        ++expansions;
        if (_trade_plan.target_stamp[cell] == stamp) {
            _trade_plan.target_stamp[cell] = 0;
            --pending_targets;
            const int32_t destination_index = _trade_plan.target_signal[cell];
            const int32_t route_cost = current.first > std::numeric_limits<int32_t>::max()
                ? -1 : static_cast<int32_t>(current.first);
            if (route_cost > 0) {
                const uint64_t key =
                    (static_cast<uint64_t>(static_cast<uint32_t>(source.cell)) << 32) |
                    static_cast<uint32_t>(cell);
                size_t slot = static_cast<size_t>(
                    (key ^ (key >> 33) ^ (key >> 17)) & mask);
                size_t insert_slot = slot;
                for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
                    insert_slot = slot;
                    if (_trade_plan.route_cache_keys[slot] ==
                            std::numeric_limits<uint64_t>::max() ||
                        _trade_plan.route_cache_keys[slot] == key) break;
                }
                _trade_plan.route_cache_keys[insert_slot] = key;
                _trade_plan.route_cache_costs[insert_slot] = route_cost;
                if (destination_index >= 0 && destination_index <
                        static_cast<int32_t>(_trade_plan.destinations.size()) &&
                    append_candidate(_trade_plan.destinations[destination_index], route_cost))
                    ++accepted;
            }
        }
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || _trade_topology.passable[neighbor] == 0 ||
                _epoch_cell_country[neighbor] != source.country) continue;
            const int64_t next = current.first + _trade_topology.enter_cost[neighbor];
            if (_trade_plan.distance_stamp[neighbor] == stamp &&
                _trade_plan.distance[neighbor] <= next) continue;
            _trade_plan.distance_stamp[neighbor] = stamp;
            _trade_plan.distance[neighbor] = next;
            _trade_plan.heap.push_back({next, neighbor});
            std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        }
    }
    _trade_route_expansions += expansions;
    if (accepted == 0 && expansions >= _trade_max_route_expansions) {
        ++_trade_rejected_route;
        for (const TradeSignal &destination : _trade_plan.destinations) {
            if (destination.good == source.good &&
                destination.country == source.country)
                record_trade_signal_attempt(destination.cell, source.good,
                    TRADE_SIGNAL_DIAG_ROUTE);
        }
    }
    return true;
}

bool NativeEconomyRuntime::run_trade_planner_slice(
        int64_t &work_done, std::string &error) {
    const auto started = Clock::now();
    if (_trade_plan.phase == TradePlanStore::SCAN) {
        const int64_t end = std::min(_trade_plan.scan_total,
            _trade_plan.scan_cursor + _trade_signal_pairs_per_slice);
        for (; _trade_plan.scan_cursor < end; ++_trade_plan.scan_cursor) {
            const int32_t market = _trade_plan.scan_cells[_trade_plan.scan_cursor];
            const int32_t good = _trade_plan.scan_goods[_trade_plan.scan_cursor];
            ++work_done;
            if (_good_trade_enabled[good] == 0 || _good_storage_modes[good] != 0 ||
                market < 0 || market >= _cell_count ||
                !good_available(market, good, true) ||
                _trade_topology.passable[market] == 0 ||
                _trade_topology.component[market] < 0) continue;
            const int32_t country = _epoch_cell_country[market];
            if (country < 0 || _merchant_offsets[market] >= _merchant_offsets[market + 1])
                continue;
            const int64_t index = _market.index(market, good);
            int64_t sat = 0;
            const int64_t target = trade_local_stock_target(market, good, sat);
            const int64_t export_floor = trade_export_floor(market, good, sat);
            const int64_t stock = _market.stock[index];
            if (stock > export_floor && static_cast<int32_t>(_trade_plan.sources.size()) <
                    _trade_max_signals) {
                const int64_t cap = mul_div_sat(
                    stock, _trade_max_stock_share_q16, Q16_ONE, sat);
                const int64_t quantity = std::min(stock - export_floor, cap);
                if (quantity > 0) _trade_plan.sources.push_back(
                    {market, good, country, _market.price[index], quantity, 0});
            } else if (target > stock + _trade_plan.scan_inbound[_trade_plan.scan_cursor] &&
                       static_cast<int32_t>(_trade_plan.destinations.size()) <
                           _trade_max_signals) {
                const int32_t signal_clock = ensure_trade_signal_clock_index(market, good);
                if (signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_first_seen_day.size()) &&
                    _trade_signal_first_seen_day[signal_clock] < 0) {
                    _trade_signal_first_seen_day[signal_clock] = _sample_day;
                    _trade_signal_first_dispatch_day[signal_clock] = -1;
                    _trade_signal_last_attempt_day[signal_clock] = -1;
                    _trade_signal_last_rejection_reason[signal_clock] =
                        TRADE_SIGNAL_DIAG_NONE;
                    _trade_signal_deadline_reported[signal_clock] = 0;
                }
                const int64_t first_seen = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_first_seen_day.size())
                    ? _trade_signal_first_seen_day[signal_clock] : -1;
                const int32_t age = first_seen >= 0 ? static_cast<int32_t>(
                    std::clamp<int64_t>(_sample_day - first_seen, 0,
                                        std::numeric_limits<int32_t>::max())) : 0;
                _trade_signal_max_age_days = std::max<int64_t>(
                    _trade_signal_max_age_days, age);
                int32_t response_priority = 0;
                if (signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_last_attempt_day.size()) &&
                    _trade_signal_last_attempt_day[signal_clock] >= 0) {
                    response_priority = 1;
                }
                if (signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_first_dispatch_day.size()) &&
                    _trade_signal_first_dispatch_day[signal_clock] >= 0) {
                    response_priority = 2;
                }
                _trade_plan.destinations.push_back(
                    {market, good, country, _market.price[index],
                     target - stock - _trade_plan.scan_inbound[_trade_plan.scan_cursor], age,
                     response_priority});
            }
        }
        if (_trade_plan.scan_cursor >= _trade_plan.scan_total) {
            std::stable_sort(_trade_plan.sources.begin(), _trade_plan.sources.end(),
                [](const TradeSignal &a, const TradeSignal &b) {
                    if (a.country != b.country) return a.country < b.country;
                    if (a.good != b.good) return a.good < b.good;
                    if (a.price != b.price) return a.price < b.price;
                    if (a.quantity != b.quantity) return a.quantity > b.quantity;
                    return a.cell < b.cell;
                });
            std::stable_sort(_trade_plan.destinations.begin(), _trade_plan.destinations.end(),
                [](const TradeSignal &a, const TradeSignal &b) {
                    if (a.country != b.country) return a.country < b.country;
                    if (a.good != b.good) return a.good < b.good;
                    if (a.response_priority != b.response_priority)
                        return a.response_priority < b.response_priority;
                    if (a.age_days != b.age_days) return a.age_days > b.age_days;
                    if (a.price != b.price) return a.price > b.price;
                    if (a.quantity != b.quantity) return a.quantity > b.quantity;
                    return a.cell < b.cell;
                });
            for (const TradeSignal &destination : _trade_plan.destinations) {
                const auto source = std::lower_bound(
                    _trade_plan.sources.begin(), _trade_plan.sources.end(), destination,
                    [](const TradeSignal &candidate, const TradeSignal &wanted) {
                        if (candidate.country != wanted.country)
                            return candidate.country < wanted.country;
                        return candidate.good < wanted.good;
                    });
                if (source == _trade_plan.sources.end() ||
                    source->country != destination.country ||
                    source->good != destination.good) {
                    record_trade_signal_attempt(destination.cell, destination.good,
                                                TRADE_SIGNAL_DIAG_STOCK);
                }
            }
            // A dense world can expose thousands of tiny surplus cells for one
            // good. Routing every source makes a five-day planner take years to
            // complete while adding little economic value. Keep the strongest
            // deterministic per-country/good pools, then let the existing
            // nearest-target Dijkstra and profit clipping choose actual routes.
            auto keep_group_limit = [](std::vector<TradeSignal> &signals,
                                       int32_t limit) {
                if (signals.empty() || limit <= 0) return;
                std::vector<TradeSignal> kept;
                kept.reserve(signals.size());
                int32_t last_country = std::numeric_limits<int32_t>::min();
                int32_t last_good = std::numeric_limits<int32_t>::min();
                int32_t count = 0;
                for (const TradeSignal &signal : signals) {
                    if (signal.country != last_country || signal.good != last_good) {
                        last_country = signal.country;
                        last_good = signal.good;
                        count = 0;
                    }
                    if (count++ < limit) kept.push_back(signal);
                }
                signals.swap(kept);
            };
            keep_group_limit(_trade_plan.sources, 4);
            keep_group_limit(_trade_plan.destinations, 8);
            _trade_plan.phase = TradePlanStore::ROUTE;
            _trade_plan.route_cursor = 0;
        }
    } else if (_trade_plan.phase == TradePlanStore::ROUTE) {
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_trade_plan.sources.size()),
            _trade_plan.route_cursor + _trade_route_searches_per_slice);
        for (; _trade_plan.route_cursor < end; ++_trade_plan.route_cursor) {
            if (!route_trade_source(_trade_plan.route_cursor, error)) return false;
            ++work_done;
        }
        if (_trade_plan.route_cursor >= static_cast<int32_t>(_trade_plan.sources.size())) {
            std::stable_sort(_trade_plan.working_candidates.begin(),
                _trade_plan.working_candidates.end(), [](const TradeCandidate &a,
                                                         const TradeCandidate &b) {
                    if (a.signal_age_days != b.signal_age_days)
                        return a.signal_age_days > b.signal_age_days;
                    if (a.density_q16 != b.density_q16) return a.density_q16 > b.density_q16;
                    if (a.expected_profit != b.expected_profit)
                        return a.expected_profit > b.expected_profit;
                    if (a.route_cost != b.route_cost) return a.route_cost < b.route_cost;
                    if (a.source != b.source) return a.source < b.source;
                    if (a.destination != b.destination) return a.destination < b.destination;
                    return a.good < b.good;
                });
            _trade_plan.ready_candidates.swap(_trade_plan.working_candidates);
            _trade_plan.phase = TradePlanStore::IDLE;
            ++_trade_plan.completed_scans;
        }
    }
    _trade_plan_ms += elapsed_ms(started);
    return true;
}

int32_t NativeEconomyRuntime::trade_signal_clock_index(
        int32_t cell, int32_t good) const {
    const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
        static_cast<uint32_t>(good);
    const auto it = std::lower_bound(
        _trade_signal_clock_keys.begin(), _trade_signal_clock_keys.end(), key);
    return it != _trade_signal_clock_keys.end() && *it == key
        ? static_cast<int32_t>(it - _trade_signal_clock_keys.begin()) : -1;
}

int32_t NativeEconomyRuntime::ensure_trade_signal_clock_index(
        int32_t cell, int32_t good) {
    const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
        static_cast<uint32_t>(good);
    const auto it = std::lower_bound(
        _trade_signal_clock_keys.begin(), _trade_signal_clock_keys.end(), key);
    if (it != _trade_signal_clock_keys.end() && *it == key)
        return static_cast<int32_t>(it - _trade_signal_clock_keys.begin());
    const int32_t index = static_cast<int32_t>(it - _trade_signal_clock_keys.begin());
    _trade_signal_clock_keys.insert(it, key);
    _trade_signal_first_seen_day.insert(
        _trade_signal_first_seen_day.begin() + index, -1);
    _trade_signal_first_dispatch_day.insert(
        _trade_signal_first_dispatch_day.begin() + index, -1);
    _trade_signal_last_attempt_day.insert(
        _trade_signal_last_attempt_day.begin() + index, -1);
    _trade_signal_last_rejection_reason.insert(
        _trade_signal_last_rejection_reason.begin() + index, TRADE_SIGNAL_DIAG_NONE);
    _trade_signal_deadline_reported.insert(
        _trade_signal_deadline_reported.begin() + index, 0);
    return index;
}

void NativeEconomyRuntime::record_trade_signal_attempt(
        int32_t cell, int32_t good, int32_t reason) {
    const int32_t index = ensure_trade_signal_clock_index(cell, good);
    if (index < 0 || index >= static_cast<int32_t>(
            _trade_signal_last_attempt_day.size())) return;
    _trade_signal_last_attempt_day[index] = _sample_day;
    _trade_signal_last_rejection_reason[index] = reason;
}

void NativeEconomyRuntime::refresh_trade_response_diagnostics() {
    _trade_signal_max_age_days = 0;
    _trade_response_deadline_misses = 0;
    _trade_unresolved_no_attempt = 0;
    _trade_unresolved_no_spread = 0;
    _trade_unresolved_margin = 0;
    _trade_unresolved_route = 0;
    _trade_unresolved_stock = 0;
    _trade_unresolved_capacity = 0;
    _trade_unresolved_cash = 0;
    _trade_unresolved_order_cap = 0;
    _trade_unresolved_no_attempt = 0;
    _trade_unresolved_no_spread = 0;
    _trade_unresolved_margin = 0;
    _trade_unresolved_route = 0;
    _trade_unresolved_stock = 0;
    _trade_unresolved_capacity = 0;
    _trade_unresolved_cash = 0;
    _trade_unresolved_order_cap = 0;
    const size_t count = std::min({
        _trade_signal_first_seen_day.size(),
        _trade_signal_first_dispatch_day.size(),
        _trade_signal_deadline_reported.size(),
    });
    for (size_t index = 0; index < count; ++index) {
        const int64_t first_seen = _trade_signal_first_seen_day[index];
        if (first_seen < 0) continue;
        const int64_t age = std::max<int64_t>(0, _sample_day - first_seen);
        _trade_signal_max_age_days = std::max(_trade_signal_max_age_days, age);
        if (_trade_signal_first_dispatch_day[index] >= 0 ||
            age <= _trade_response_days) continue;
        ++_trade_response_deadline_misses;
        switch (_trade_signal_last_rejection_reason[index]) {
            case TRADE_SIGNAL_DIAG_NO_SPREAD: ++_trade_unresolved_no_spread; break;
            case TRADE_SIGNAL_DIAG_MARGIN: ++_trade_unresolved_margin; break;
            case TRADE_SIGNAL_DIAG_ROUTE: ++_trade_unresolved_route; break;
            case TRADE_SIGNAL_DIAG_STOCK: ++_trade_unresolved_stock; break;
            case TRADE_SIGNAL_DIAG_CAPACITY: ++_trade_unresolved_capacity; break;
            case TRADE_SIGNAL_DIAG_CASH: ++_trade_unresolved_cash; break;
            case TRADE_SIGNAL_DIAG_ORDER_CAP: ++_trade_unresolved_order_cap; break;
            default: ++_trade_unresolved_no_attempt; break;
        }
        if (_trade_signal_deadline_reported[index] == 0) {
            _trade_signal_deadline_reported[index] = 1;
            ++_trade_response_deadline_misses_cumulative;
        }
    }
}

int32_t NativeEconomyRuntime::trade_flow_index(
        int32_t cell, int32_t good, bool create) {
    size_t lo = 0;
    size_t hi = _trade_flows.cells.size();
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;
        if (_trade_flows.cells[mid] < cell ||
            (_trade_flows.cells[mid] == cell && _trade_flows.goods[mid] < good))
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo < _trade_flows.cells.size() && _trade_flows.cells[lo] == cell &&
        _trade_flows.goods[lo] == good) return static_cast<int32_t>(lo);
    if (!create) return -1;
    if (static_cast<int32_t>(_trade_flows.cells.size()) >= _trade_max_signals)
        return -1;
    const auto pos = static_cast<std::ptrdiff_t>(lo);
    _trade_flows.cells.insert(_trade_flows.cells.begin() + pos, cell);
    _trade_flows.goods.insert(_trade_flows.goods.begin() + pos, good);
    _trade_flows.import_ema.insert(_trade_flows.import_ema.begin() + pos, 0);
    _trade_flows.export_ema.insert(_trade_flows.export_ema.begin() + pos, 0);
    _trade_flows.period_import.insert(_trade_flows.period_import.begin() + pos, 0);
    _trade_flows.period_export.insert(_trade_flows.period_export.begin() + pos, 0);
    return static_cast<int32_t>(lo);
}

void NativeEconomyRuntime::update_trade_flow_ema() {
    int64_t sat = 0;
    const int64_t alpha = std::min<int64_t>(Q16_ONE, saturating_mul(
        _trade_flow_ema_alpha_q16, std::max(1, _epoch_days), sat));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        const int64_t observed_import = _trade_flows.period_import[i] /
            std::max(1, _epoch_days);
        const int64_t observed_export = _trade_flows.period_export[i] /
            std::max(1, _epoch_days);
        _trade_flows.import_ema[i] = saturating_add(
            _trade_flows.import_ema[i], mul_div_sat(
                observed_import - _trade_flows.import_ema[i], alpha, Q16_ONE, sat), sat);
        _trade_flows.export_ema[i] = saturating_add(
            _trade_flows.export_ema[i], mul_div_sat(
                observed_export - _trade_flows.export_ema[i], alpha, Q16_ONE, sat), sat);
        _trade_flows.period_import[i] = 0;
        _trade_flows.period_export[i] = 0;
    }
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

int64_t NativeEconomyRuntime::credit_trade_sellers(int32_t order_index, int64_t amount) {
    if (order_index < 0 || order_index >= _trade_orders.size() || amount <= 0) return 0;
    const int32_t begin = _trade_orders.seller_offsets[order_index];
    const int32_t end = _trade_orders.seller_offsets[order_index + 1];
    int64_t total_weight = 0;
    std::vector<std::pair<int32_t, int64_t>> valid;
    valid.reserve(static_cast<size_t>(std::max(0, end - begin)));
    for (int32_t i = begin; i < end; ++i) {
        int32_t slot = -1;
        if (!_population.valid_handle(_trade_orders.seller_handles[i], slot) ||
            !is_merchant_slot(slot) ||
            _population.page_cell[slot / PAGE_SIZE] != _trade_orders.sources[order_index])
            continue;
        const int64_t weight = std::max<int64_t>(1, _trade_orders.seller_weights[i]);
        valid.push_back({slot, weight});
        total_weight = saturating_add(total_weight, weight, _saturation_count);
    }
    if (valid.empty() || total_weight <= 0) {
        return credit_local_merchants(_trade_orders.sources[order_index], amount,
                                      CASHFLOW_MERCHANT_BUSINESS);
    }
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (const auto &entry : valid) {
        const int32_t slot = entry.first;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, entry.second, _saturation_count);
        const int64_t next = mul_div_sat(amount, prefix, total_weight, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        _population.funds[slot] = saturating_add(
            _population.funds[slot], share, _saturation_count);
        _population.epoch_income[slot] = saturating_add(
            _population.epoch_income[slot], share, _saturation_count);
        trace_record_cashflow(_trade_orders.sources[order_index],
            _population.handle_for_slot(slot), CASHFLOW_MERCHANT_BUSINESS, share, 0);
    }
    return distributed;
}

void NativeEconomyRuntime::rebuild_trade_arrival_buckets() {
    _trade_orders.arrival_bucket_days.clear();
    _trade_orders.arrival_bucket_offsets.assign(1, 0);
    _trade_orders.arrival_bucket_orders.clear();
    std::vector<int32_t> order_indices(static_cast<size_t>(_trade_orders.size()));
    std::iota(order_indices.begin(), order_indices.end(), 0);
    std::stable_sort(order_indices.begin(), order_indices.end(), [&](int32_t a, int32_t b) {
        if (_trade_orders.arrival_days[a] != _trade_orders.arrival_days[b])
            return _trade_orders.arrival_days[a] < _trade_orders.arrival_days[b];
        return _trade_orders.ids[a] < _trade_orders.ids[b];
    });
    int64_t current_day = std::numeric_limits<int64_t>::min();
    for (const int32_t order : order_indices) {
        const int64_t day = _trade_orders.arrival_days[order];
        if (_trade_orders.arrival_bucket_days.empty() || day != current_day) {
            if (!_trade_orders.arrival_bucket_days.empty())
                _trade_orders.arrival_bucket_offsets.push_back(
                    static_cast<int32_t>(_trade_orders.arrival_bucket_orders.size()));
            _trade_orders.arrival_bucket_days.push_back(day);
            current_day = day;
        }
        _trade_orders.arrival_bucket_orders.push_back(order);
    }
    if (!_trade_orders.arrival_bucket_days.empty())
        _trade_orders.arrival_bucket_offsets.push_back(
            static_cast<int32_t>(_trade_orders.arrival_bucket_orders.size()));
    _trade_orders.arrival_buckets_dirty = false;
}

void NativeEconomyRuntime::compact_trade_orders(const std::vector<uint8_t> &remove) {
    if (remove.size() != _trade_orders.ids.size()) return;
    TradeOrderStore next;
    next.clear();
    next.next_id = _trade_orders.next_id;
    for (int32_t i = 0; i < _trade_orders.size(); ++i) {
        if (remove[i] != 0) continue;
        next.ids.push_back(_trade_orders.ids[i]);
        next.sources.push_back(_trade_orders.sources[i]);
        next.destinations.push_back(_trade_orders.destinations[i]);
        next.countries.push_back(_trade_orders.countries[i]);
        next.departure_days.push_back(_trade_orders.departure_days[i]);
        next.arrival_days.push_back(_trade_orders.arrival_days[i]);
        next.cash_escrow.push_back(_trade_orders.cash_escrow[i]);
        next.capacity_work.push_back(_trade_orders.capacity_work[i]);
        next.states.push_back(_trade_orders.states[i]);
        next.cargo_delivered.push_back(_trade_orders.cargo_delivered[i]);
        for (int32_t line = _trade_orders.line_offsets[i];
             line < _trade_orders.line_offsets[i + 1]; ++line) {
            next.line_goods.push_back(_trade_orders.line_goods[line]);
            next.line_quantities.push_back(_trade_orders.line_quantities[line]);
            next.line_unit_prices.push_back(_trade_orders.line_unit_prices[line]);
        }
        next.line_offsets.push_back(static_cast<int32_t>(next.line_goods.size()));
        for (int32_t seller = _trade_orders.seller_offsets[i];
             seller < _trade_orders.seller_offsets[i + 1]; ++seller) {
            next.seller_handles.push_back(_trade_orders.seller_handles[seller]);
            next.seller_weights.push_back(_trade_orders.seller_weights[seller]);
        }
        next.seller_offsets.push_back(static_cast<int32_t>(next.seller_handles.size()));
    }
    _trade_orders = std::move(next);
    rebuild_trade_arrival_buckets();
}

bool NativeEconomyRuntime::settle_due_trade_orders(std::string &error) {
    const auto started = Clock::now();
    if (_trade_orders.arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    std::vector<uint8_t> remove(static_cast<size_t>(_trade_orders.size()), 0);
    for (int32_t bucket = 0;
         bucket < static_cast<int32_t>(_trade_orders.arrival_bucket_days.size()) &&
         _trade_orders.arrival_bucket_days[bucket] <= _sample_day; ++bucket) {
      for (int32_t position = _trade_orders.arrival_bucket_offsets[bucket];
           position < _trade_orders.arrival_bucket_offsets[bucket + 1]; ++position) {
        const int32_t order = _trade_orders.arrival_bucket_orders[position];
        if (order < 0 || order >= _trade_orders.size()) {
            error = "trade_arrival_bucket_invalid";
            return false;
        }
        if (_trade_orders.cargo_delivered[order] == 0) {
            const int32_t destination = _trade_orders.destinations[order];
            if (destination < 0 || destination >= _market.market_count) {
                error = "trade_order_destination_invalid";
                return false;
            }
            int64_t delivered = 0;
            for (int32_t line = _trade_orders.line_offsets[order];
                 line < _trade_orders.line_offsets[order + 1]; ++line) {
                const int32_t good = _trade_orders.line_goods[line];
                const int64_t quantity = _trade_orders.line_quantities[line];
                if (good < 0 || good >= _market.good_count || quantity <= 0) {
                    error = "trade_order_line_invalid";
                    return false;
                }
                const int64_t index = _market.index(destination, good);
                _market.stock[index] = saturating_add(
                    _market.stock[index], quantity, _saturation_count);
                delivered = saturating_add(delivered, quantity, _saturation_count);
                const int32_t flow = trade_flow_index(destination, good, true);
                if (flow >= 0) _trade_flows.period_import[flow] = saturating_add(
                    _trade_flows.period_import[flow], quantity, _saturation_count);
            }
            _trade_orders.cargo_delivered[order] = 1;
            _trade_settlement_lag_days = std::max<int64_t>(_trade_settlement_lag_days,
                _sample_day - _trade_orders.arrival_days[order]);
            trace_append(EVENT_TRADE_ARRIVED, static_cast<int32_t>(Stage::TRADE_SETTLE),
                destination, SUBJECT_TRADE_ORDER, _trade_orders.ids[order],
                _trade_orders.sources[order], destination, delivered,
                _trade_orders.cash_escrow[order], _trade_orders.departure_days[order],
                _trade_orders.arrival_days[order], nullptr);
            ++_trade_orders_arrived;
        }
        const int64_t escrow = _trade_orders.cash_escrow[order];
        const int64_t credited = escrow == 0 ? 0 : credit_trade_sellers(order, escrow);
        if (credited == escrow) {
            _trade_orders.cash_escrow[order] = 0;
            remove[order] = 1;
        } else {
            _trade_orders.states[order] = TradeOrderStore::WAITING_RECEIVER;
            ++_trade_unclaimed_orders;
        }
      }
    }
    if (std::any_of(remove.begin(), remove.end(), [](uint8_t value) { return value != 0; }))
        compact_trade_orders(remove);
    _trade_settle_ms += elapsed_ms(started);
    return true;
}

bool NativeEconomyRuntime::dispatch_trade_candidates(std::string &error) {
    const auto started = Clock::now();
    // A full global route scan may span hundreds of fixed five-day cycles on
    // a populated map. Publish the deterministic chunk accumulated since the
    // prior settlement instead of withholding every profitable route until
    // the final source is visited. Dispatch revalidates price, stock, cash,
    // capacity and topology below, so partial publication remains conservative
    // while the stable route cursor provides eventual fairness.
    if (_trade_plan.ready_candidates.empty() &&
        !_trade_plan.working_candidates.empty()) {
        _trade_plan.ready_candidates.swap(_trade_plan.working_candidates);
        std::stable_sort(_trade_plan.ready_candidates.begin(),
            _trade_plan.ready_candidates.end(), [](const TradeCandidate &a,
                                                    const TradeCandidate &b) {
                if (a.signal_age_days != b.signal_age_days)
                    return a.signal_age_days > b.signal_age_days;
                if (a.density_q16 != b.density_q16)
                    return a.density_q16 > b.density_q16;
                if (a.expected_profit != b.expected_profit)
                    return a.expected_profit > b.expected_profit;
                if (a.route_cost != b.route_cost) return a.route_cost < b.route_cost;
                if (a.source != b.source) return a.source < b.source;
                if (a.destination != b.destination)
                    return a.destination < b.destination;
                return a.good < b.good;
            });
    }
    std::vector<int64_t> country_capacity(static_cast<size_t>(
        std::max(0, _epoch_country_count)), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t country = _epoch_cell_country[cell];
        if (country < 0 || country >= _epoch_country_count) continue;
        int64_t merchant_population = 0;
        for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k)
            merchant_population = saturating_add(merchant_population,
                _population.population[_merchant_slots[k]], _saturation_count);
        country_capacity[country] = saturating_add(country_capacity[country],
            saturating_mul(merchant_population, _trade_capacity_per_merchant_q16,
                           _saturation_count), _saturation_count);
    }
    _trade_capacity_available = std::accumulate(
        country_capacity.begin(), country_capacity.end(), int64_t{0});
    std::vector<TradeCandidate> accepted;
    std::vector<int32_t> merchant_funds_touched;
    accepted.reserve(std::min<int32_t>(static_cast<int32_t>(
        _trade_plan.ready_candidates.size()),
        std::max(0, _trade_max_orders - _trade_orders.size())));
    merchant_funds_touched.reserve(accepted.capacity());
    for (const TradeCandidate &candidate : _trade_plan.ready_candidates) {
        if (candidate.source < 0 || candidate.destination < 0 ||
            candidate.good < 0 || candidate.good >= _market.good_count ||
            candidate.country < 0 || candidate.country >= _epoch_country_count ||
            candidate.topology_generation != _trade_topology.topology_generation ||
            candidate.country_topology_hash != _epoch_country_topology_hash ||
            _epoch_cell_country[candidate.source] != candidate.country ||
            _epoch_cell_country[candidate.destination] != candidate.country) {
            ++_trade_rejected_route;
            if (candidate.destination >= 0 && candidate.good >= 0)
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_ROUTE);
            continue;
        }
        if (candidate.expected_profit <= 0 || candidate.quantity <= 0) {
            ++_trade_rejected_profit;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        TradeCandidate clipped = candidate;
        const int64_t market_index = _market.index(candidate.source, candidate.good);
        int64_t target_sat = 0;
        const int64_t local_stock_target = trade_export_floor(
            candidate.source, candidate.good, target_sat);
        _saturation_count = saturating_add(
            _saturation_count, target_sat, _saturation_count);
        int64_t reserved_stock = 0;
        int64_t reserved_cash = 0;
        if (_trade_runtime_mode == 1) {
            for (const TradeCandidate &prior : accepted) {
                if (prior.source == candidate.source && prior.good == candidate.good)
                    reserved_stock += prior.quantity;
                if (prior.destination == candidate.destination)
                    reserved_cash += mul_div_sat(prior.quantity, prior.source_price,
                                                GOODS_SCALE, _saturation_count);
            }
        }
        clipped.quantity = std::min(clipped.quantity,
            std::max<int64_t>(0, _market.stock[market_index] -
                local_stock_target - reserved_stock));
        int64_t sat = 0;
        const int64_t unit_work = saturating_mul(
            _good_transport_load_per_unit_q16[candidate.good],
            candidate.route_cost, sat);
        const int64_t capacity_quantity = mul_div_sat(
            country_capacity[candidate.country], GOODS_SCALE,
            std::max<int64_t>(1, unit_work), sat);
        clipped.quantity = std::min(clipped.quantity, capacity_quantity);
        if (clipped.quantity <= 0) {
            if (_market.stock[market_index] <= local_stock_target + reserved_stock) {
                ++_trade_rejected_stock;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_STOCK);
            } else {
                ++_trade_rejected_capacity;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CAPACITY);
            }
            continue;
        }
        const int64_t destination_index = _market.index(
            candidate.destination, candidate.good);
        clipped.source_price = estimate_trade_price(candidate.source, candidate.good,
            _market.stock[market_index] - clipped.quantity, sat);
        clipped.destination_price = estimate_trade_price(
            candidate.destination, candidate.good,
            _market.stock[destination_index] + clipped.quantity, sat);
        int64_t available_cash = 0;
        for (int32_t k = _merchant_offsets[candidate.destination];
             k < _merchant_offsets[candidate.destination + 1]; ++k)
            available_cash = saturating_add(available_cash,
                _population.funds[_merchant_slots[k]], sat);
        available_cash = std::max<int64_t>(0, available_cash - reserved_cash);
        if (clipped.source_price > 0) {
            clipped.quantity = std::min(clipped.quantity, mul_div_sat(
                available_cash, GOODS_SCALE, clipped.source_price, sat));
        }
        if (clipped.quantity <= 0) {
            ++_trade_rejected_cash;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_CASH);
            continue;
        }
        const int64_t relief_q16 = trade_relief_pressure_q16(
            candidate.destination, candidate.good, sat);
        const bool relief_route = relief_q16 >= Q16_ONE / 8;
        const int64_t before_profit_clip = clipped.quantity;
        int64_t margin_q16 = 0;
        clipped.quantity = profitable_trade_quantity(
            candidate.source, candidate.destination, candidate.good,
            clipped.quantity, relief_route, clipped.source_price,
            clipped.destination_price, clipped.expected_profit,
            margin_q16, sat);
        if (clipped.quantity <= 0) {
            ++_trade_rejected_profit;
            ++_trade_rejected_margin;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        if (clipped.quantity < before_profit_clip) ++_trade_quantity_profit_clips;
        clipped.capacity_work = mul_div_sat(
            clipped.quantity, unit_work, GOODS_SCALE, sat);
        if (relief_route && clipped.expected_profit <= 0) {
            clipped.expected_profit = std::max<int64_t>(1, mul_div_sat(
                mul_div_sat(clipped.quantity, std::max<int64_t>(1, clipped.source_price),
                            GOODS_SCALE, sat),
                std::max<int64_t>(1, relief_q16), Q16_ONE, sat));
        }
        clipped.density_q16 = clipped.capacity_work <= 0 ? 0 : mul_div_sat(
            clipped.expected_profit, Q16_ONE, clipped.capacity_work, sat);
        if (clipped.capacity_work <= 0) {
            ++_trade_rejected_profit;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        const int64_t purchase_cash = mul_div_sat(
            clipped.quantity, clipped.source_price, GOODS_SCALE, sat);
        if (available_cash < purchase_cash) {
            ++_trade_rejected_cash;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_CASH);
            continue;
        }
        if (country_capacity[candidate.country] < clipped.capacity_work) {
            ++_trade_rejected_capacity;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_CAPACITY);
            continue;
        }
        if (_market.stock[market_index] - local_stock_target - reserved_stock <
                clipped.quantity) {
            ++_trade_rejected_stock;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_STOCK);
            continue;
        }
        if (_trade_runtime_mode == 2 &&
            _trade_orders.size() + static_cast<int32_t>(accepted.size()) >=
                _trade_max_orders) {
            ++_trade_rejected_order_cap;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_ORDER_CAP);
            break;
        }
        country_capacity[candidate.country] -= clipped.capacity_work;
        _trade_capacity_used = saturating_add(_trade_capacity_used,
            clipped.capacity_work, _saturation_count);
        ++_trade_candidates_accepted;
        if (_trade_runtime_mode == 1) {
            accepted.push_back(clipped);
            continue;
        }
        const int64_t debited = debit_local_merchants(
            candidate.destination, purchase_cash, CASHFLOW_MERCHANT_PROCUREMENT);
        if (debited != purchase_cash) {
            error = "trade_cash_reservation_failed";
            return false;
        }
        _market.stock[market_index] -= clipped.quantity;
        // Household settlement already contributed its closing totals. Move the
        // dispatched value from those local totals into trade escrow/transit so
        // the later conservation audit counts it exactly once.
        _publish_accum.goods_stock = saturating_sub(
            _publish_accum.goods_stock, clipped.quantity, _saturation_count);
        _publish_accum.cohort_funds = saturating_sub(
            _publish_accum.cohort_funds, purchase_cash, _saturation_count);
        merchant_funds_touched.push_back(candidate.destination);
        accepted.push_back(clipped);
        record_trade_signal_attempt(candidate.destination, candidate.good,
            TRADE_SIGNAL_DIAG_DISPATCHED);
        const int32_t destination_signal = trade_signal_clock_index(
            candidate.destination, candidate.good);
        if (_trade_runtime_mode == 2 && destination_signal >= 0 &&
            destination_signal < static_cast<int32_t>(_trade_signal_first_seen_day.size()) &&
            destination_signal < static_cast<int32_t>(_trade_signal_first_dispatch_day.size()) &&
            _trade_signal_first_seen_day[destination_signal] >= 0 &&
            _trade_signal_first_dispatch_day[destination_signal] < 0) {
            _trade_signal_first_dispatch_day[destination_signal] = _sample_day;
            _trade_first_dispatch_delay_max_days = std::max<int64_t>(
                _trade_first_dispatch_delay_max_days,
                std::max<int64_t>(0, _sample_day -
                    _trade_signal_first_seen_day[destination_signal]));
        }
        const int32_t flow = trade_flow_index(candidate.source, candidate.good, true);
        if (flow >= 0) _trade_flows.period_export[flow] = saturating_add(
            _trade_flows.period_export[flow], clipped.quantity, _saturation_count);
    }
    _trade_plan.ready_candidates.clear();
    std::sort(merchant_funds_touched.begin(), merchant_funds_touched.end());
    merchant_funds_touched.erase(std::unique(merchant_funds_touched.begin(),
        merchant_funds_touched.end()), merchant_funds_touched.end());
    for (const int32_t cell : merchant_funds_touched) {
        if (cell >= 0 && cell < _cell_count) _staging_cells[cell] = build_cell_summary(cell);
    }
    if (_trade_runtime_mode != 2 || accepted.empty()) {
        _trade_dispatch_ms += elapsed_ms(started);
        return true;
    }
    auto arrival_for = [&](const TradeCandidate &candidate) {
        const int64_t raw_days = std::max<int64_t>(1,
            (candidate.route_cost + _trade_speed_cost_per_day - 1) /
                _trade_speed_cost_per_day);
        // Transport is a daily authority transaction. Local markets consume
        // the delivered stock on their next rolling settlement, but cargo must
        // not wait for or align to that five-day cadence.
        return _sample_day + raw_days;
    };
    std::stable_sort(accepted.begin(), accepted.end(), [&](const TradeCandidate &a,
                                                           const TradeCandidate &b) {
        if (a.source != b.source) return a.source < b.source;
        if (a.destination != b.destination) return a.destination < b.destination;
        const int64_t arrival_a = arrival_for(a);
        const int64_t arrival_b = arrival_for(b);
        if (arrival_a != arrival_b) return arrival_a < arrival_b;
        return a.good < b.good;
    });
    size_t cursor = 0;
    while (cursor < accepted.size()) {
        const TradeCandidate &first = accepted[cursor];
        const int64_t arrival = arrival_for(first);
        const size_t begin = cursor;
        while (cursor < accepted.size() && cursor - begin < 16 &&
               accepted[cursor].source == first.source &&
               accepted[cursor].destination == first.destination &&
               arrival_for(accepted[cursor]) == arrival) ++cursor;
        _trade_orders.ids.push_back(_trade_orders.next_id++);
        _trade_orders.sources.push_back(first.source);
        _trade_orders.destinations.push_back(first.destination);
        _trade_orders.countries.push_back(first.country);
        _trade_orders.departure_days.push_back(_sample_day);
        _trade_orders.arrival_days.push_back(arrival);
        _trade_orders.states.push_back(TradeOrderStore::IN_TRANSIT);
        _trade_orders.cargo_delivered.push_back(0);
        int64_t cash = 0;
        int64_t capacity = 0;
        for (size_t i = begin; i < cursor; ++i) {
            const TradeCandidate &candidate = accepted[i];
            int64_t sat = 0;
            const int64_t line_cash = mul_div_sat(
                candidate.quantity, candidate.source_price, GOODS_SCALE, sat);
            cash = saturating_add(cash, line_cash, _saturation_count);
            capacity = saturating_add(capacity, candidate.capacity_work, _saturation_count);
            _trade_orders.line_goods.push_back(candidate.good);
            _trade_orders.line_quantities.push_back(candidate.quantity);
            _trade_orders.line_unit_prices.push_back(candidate.source_price);
        }
        _trade_orders.cash_escrow.push_back(cash);
        _trade_orders.capacity_work.push_back(capacity);
        _trade_orders.line_offsets.push_back(
            static_cast<int32_t>(_trade_orders.line_goods.size()));
        for (int32_t k = _merchant_offsets[first.source];
             k < _merchant_offsets[first.source + 1]; ++k) {
            const int32_t slot = _merchant_slots[k];
            _trade_orders.seller_handles.push_back(_population.handle_for_slot(slot));
            _trade_orders.seller_weights.push_back(
                std::max<int64_t>(1, _population.population[slot]));
        }
        _trade_orders.seller_offsets.push_back(
            static_cast<int32_t>(_trade_orders.seller_handles.size()));
        trace_append(EVENT_TRADE_DISPATCHED,
            static_cast<int32_t>(Stage::TRADE_DISPATCH), first.source,
            SUBJECT_TRADE_ORDER, _trade_orders.ids.back(), first.source,
            first.destination, static_cast<int64_t>(cursor - begin), cash,
            capacity, arrival, nullptr);
        ++_trade_orders_dispatched;
        _trade_orders.arrival_buckets_dirty = true;
    }
    if (_trade_orders.arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    _trade_dispatch_ms += elapsed_ms(started);
    return true;
}

int64_t NativeEconomyRuntime::trade_transit_goods() const {
    int64_t total = 0;
    int64_t sat = 0;
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        if (_trade_orders.cargo_delivered[order] != 0) continue;
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line)
            total = saturating_add(total, _trade_orders.line_quantities[line], sat);
    }
    return total;
}

int64_t NativeEconomyRuntime::trade_escrow_cash() const {
    int64_t total = 0;
    int64_t sat = 0;
    for (int64_t cash : _trade_orders.cash_escrow)
        total = saturating_add(total, cash, sat);
    return total;
}

void NativeEconomyRuntime::clear_epoch_metrics() {
    _epoch_business_demand_ema.clear();
    _epoch_desired_business_demand.clear();
    _epoch_funded_business_demand.clear();
    _epoch_offered_supply_ema.clear();
    _epoch_nonhousehold_withdrawals.clear();
    _epoch_cost_anchor_price.clear();
    _owner_retained_outputs.clear();
    // Persistent sparse key set: each rolling phase contributes its changed
    // markets, so a planner generation covers the whole world without a dense
    // market x good scan.
    _cell_cursor = 0;
    _command_cursor = 0;
    _structural_cursor = 0;
    _building_cell_cursor = 0;
    _building_plan_phase = 0;
    _building_commit_phase = 0;
    _investment_population_changed = false;
    _investment_employment_cells.clear();
    _processed_cells = 0;
    _processed_cohorts = 0;
    _processed_rules = 0;
    _processed_needs = 0;
    _processed_variants = 0;
    _processed_components = 0;
    _processed_commands = 0;
    _rejected_commands = 0;
    _merchant_repairs = 0;
    _price_cap_hits = 0;
    _price_cost_anchor_hits = 0;
    _price_inactive_reversions = 0;
    _continuation_slices = 0;
    _processed_building_groups = 0;
    _filled_owner_jobs = 0;
    _filled_employee_jobs = 0;
    _unemployed_population = 0;
    _construction_goods_consumed = 0;
    _building_investment_candidates = 0;
    _building_owner_mobility = 0;
    _building_owner_job_reallocations = 0;
    _building_owner_job_profession_changes = 0;
    _building_owner_job_probability_skips = 0;
    _building_investments_started = 0;
    _building_investment_blocked_funds = 0;
    _building_investment_blocked_materials = 0;
    _building_investment_blocked_sponsor_capital = 0;
    _building_investment_blocked_resources = 0;
    _building_investment_probability_skips = 0;
    _building_investment_capital_transferred = 0;
    _trade_signal_max_age_days = 0;
    _trade_first_dispatch_delay_max_days = 0;
    _trade_response_deadline_misses = 0;
    _desired_business_demand = 0;
    _funded_business_demand = 0;
    _unfunded_business_demand = 0;
    _owner_working_capital_allocated = 0;
    _working_capital_scale_error_bound_q16 = 0;
    _production_inputs_consumed = 0;
    _production_output_stock = 0;
    _production_output_discarded = 0;
    _production_output_retained = 0;
    _production_output_supported = 0;
    _owner_output_consumed = 0;
    _producer_revenue = 0;
	_producer_support_money_issued = 0;
	_bullion_money_issued = 0;
	_bullion_stock_consumed = 0;
	_gold_accepted = 0;
	_silver_accepted = 0;
	_gold_money_issued = 0;
	_silver_money_issued = 0;
	_cycle_flow_produced = 0;
	_cycle_flow_consumed = 0;
	_cycle_flow_discarded = 0;
    _building_wages_paid = 0;
    _building_wages_unpaid = 0;
    _building_base_wages_paid = 0;
    _building_base_wages_due = 0;
    _building_bonus_paid = 0;
    _building_bonus_due = 0;
    _wage_suspended_building_groups = 0;
    _loss_suspended_building_groups = 0;
    _merchant_procurement_budget = 0;
    _merchant_procurement_opportunity = 0;
    _merchant_procurement_allocated = 0;
    _merchant_procurement_unspent_allocated = 0;
    _merchant_procurement_reserved = 0;
    _merchant_procurement_spent = 0;
    _owner_working_capital_reserved = 0;
    _production_input_reserved = 0;
    _production_input_reserve_shortfall = 0;
    _labor_signal_updates = 0;
    _building_resource_generated = 0;
    _building_resource_consumed = 0;
    _building_resource_limited_groups = 0;
    _unprofitable_building_groups = 0;
    _zero_utilization_building_groups = 0;
    _utilization_sum_q16 = 0;
    _market_signal_updates = 0;
    _building_resource_capacity_checks = 0;
    _building_resource_capacity_limited_groups = 0;
    _last_building_rejection_reason.clear();
    _worker_tasks = 1;
    _production_worker_tasks = 1;
    _formula_ms = 0.0;
    _clear_ms = 0.0;
    _ledger_ms = 0.0;
    _fallback_ms = 0.0;
    _merchant_settle_ms = 0.0;
    _price_ms = 0.0;
    _structure_ms = 0.0;
    _publish_ms = 0.0;
    _employment_ms = 0.0;
    _production_ms = 0.0;
    _production_merge_ms = 0.0;
    _building_plan_ms = 0.0;
    _investment_ms = 0.0;
    _market_signal_ms = 0.0;
    _wage_plan_ms = 0.0;
    _labor_signal_ms = 0.0;
    _trade_settle_ms = 0.0;
    _trade_dispatch_ms = 0.0;
    _prepare_ms = 0.0;
    _audit_ms = 0.0;
    _watermark_ms = 0.0;
    _trade_capacity_available = 0;
    _trade_capacity_used = 0;
    _trade_settlement_lag_days = 0;
    _trade_orders_dispatched = 0;
    _trade_orders_arrived = 0;
    _trade_unclaimed_orders = 0;
    _event_summary_ms = 0.0;
    _event_detail_ms = 0.0;
    _event_publish_ms = 0.0;
    _explicit_money_mint = 0;
    _explicit_money_burn = 0;
    _external_population_delta = 0;
    _explicit_stock_delta = 0;
    _consumed_goods = 0;
    _births = 0;
    _deaths = 0;
    _saturation_count = 0;
    _structural_touched_cells.clear();
    _population_changed_cells.clear();
    _structural_funds_to_treasury = 0;
    _publish_accum = {};
    _staging_cells = _committed_cells;
    _resource_remaining = _resource_snapshot;
    _resource_deltas.assign(_resource_snapshot.size(), 0);
    if (_last_published_resource_deltas.size() != _resource_snapshot.size())
        _last_published_resource_deltas.assign(_resource_snapshot.size(), 0);
    _resource_deltas_ready = false;
}

bool NativeEconomyRuntime::start_epoch(int64_t day_index, std::string &error) {
    if (!_bootstrapped || _fatal || _epoch_active) {
        error = "epoch_start_state_invalid";
        return false;
    }
    if (day_index <= _last_committed_day) return true;
    // All failure-prone checks happen here, before any state mutation.
    if (_market.good_count != static_cast<int32_t>(_good_ids.size()) ||
        _market.cell_to_market.size() != static_cast<size_t>(_cell_count) ||
        _market.stock.size() != static_cast<size_t>(_market.market_count) * _market.good_count ||
        _market_cell_offsets.size() != static_cast<size_t>(_market.market_count + 1)) {
        error = "market_shape_invariant_broken";
        return false;
    }
    if (_environment_day != day_index || _environment_temperature_q16.size() !=
            static_cast<size_t>(_cell_count)) {
        error = "same_day_environment_not_captured";
        return false;
    }
    if (!_building_types.empty() && (_building_context_day != day_index ||
        _building_elevation_q16.size() != static_cast<size_t>(_cell_count) ||
        _building_neighbors.size() != static_cast<size_t>(_cell_count) * 6 ||
        _resource_snapshot.size() != _resource_ids.size() * static_cast<size_t>(_cell_count))) {
        error = "same_day_building_context_not_captured";
        return false;
    }
    if (_merchant_primary_slot.size() != static_cast<size_t>(_cell_count)) {
        error = "merchant_index_shape_invalid";
        return false;
    }
    const size_t cache_cells = static_cast<size_t>(_cell_count);
    const size_t cache_variants = cache_cells * _variants.size();
    const size_t cache_needs = cache_cells * _needs.size();
    if (_demand_basis_cache_day.size() != cache_cells)
        _demand_basis_cache_day.assign(
            cache_cells, std::numeric_limits<int64_t>::min());
    _demand_basis_variant_scores.resize(cache_variants);
    _demand_basis_variant_prices.resize(cache_variants);
    _demand_basis_need_score_sums.resize(cache_needs);
    _demand_basis_need_composites.resize(cache_needs);
    _demand_basis_need_environment.resize(cache_needs);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_committed_cells[cell].population > 0 && _merchant_primary_slot[cell] < 0) {
            error = "merchant_invariant_broken_before_cycle";
            return false;
        }
    }
    const auto prepare_started = Clock::now();
    clear_epoch_metrics();
    if (!capture_country_epoch(error)) return false;
    _rolling_phase = static_cast<int32_t>(
        ((day_index % ROLLING_PHASE_COUNT) + ROLLING_PHASE_COUNT) %
        ROLLING_PHASE_COUNT);
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    for (int32_t market = 0; market < _market.market_count; ++market) {
        if (market % ROLLING_PHASE_COUNT != _rolling_phase) continue;
        _epoch_market_ids.push_back(market);
        for (int32_t k = _market_cell_offsets[market];
             k < _market_cell_offsets[market + 1]; ++k) {
            _epoch_settlement_cells.push_back(_market_cells[k]);
        }
    }
    for (const int32_t cell : _building_active_cells) {
        if (cell % ROLLING_PHASE_COUNT == _rolling_phase)
            _epoch_building_cells.push_back(cell);
    }
    _rolling_due_cells = static_cast<int32_t>(_epoch_settlement_cells.size());
    _rolling_processed_cells = 0;
    _rolling_deferred_cells = 0;
    _building_survival_utilization_floor_q16.assign(_buildings.size(), 0);
    _building_owner_livelihood_credit.assign(_buildings.size(), 0);
    _production_input_reserve.assign(_market_signals.good_ids.size(), 0);
    _epoch_business_demand_ema = _market_signals.business_demand_ema;
    _epoch_desired_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_funded_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_offered_supply_ema = _market_signals.offered_supply_ema;
    _epoch_nonhousehold_withdrawals.assign(_market_signals.good_ids.size(), 0);
    _epoch_cost_anchor_price = _market_signals.cost_anchor_price;
    const auto audit_started = Clock::now();
    _opening_totals = audit_totals();
    _audit_ms += elapsed_ms(audit_started);
    _sample_day = day_index;
    _current_day = day_index;
    _epoch_active = true;
    _prepare_ms = elapsed_ms(prepare_started);
    ++_epoch_id;
    trace_begin_epoch();
    _epoch_commands.clear();
    auto due_end = std::stable_partition(_pending_commands.begin(), _pending_commands.end(),
                                         [&](const Command &c) { return c.effective_day <= day_index; });
    _epoch_commands.assign(_pending_commands.begin(), due_end);
    _pending_commands.erase(_pending_commands.begin(), due_end);
    std::stable_sort(_epoch_commands.begin(), _epoch_commands.end(), [](const Command &a, const Command &b) {
        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
        if (a.sequence != b.sequence) return a.sequence < b.sequence;
        if (a.opcode != b.opcode) return a.opcode < b.opcode;
        if (a.target_handle != b.target_handle) return a.target_handle < b.target_handle;
        if (a.i32_0 != b.i32_0) return a.i32_0 < b.i32_0;
        if (a.i32_1 != b.i32_1) return a.i32_1 < b.i32_1;
        if (a.i64_0 != b.i64_0) return a.i64_0 < b.i64_0;
        if (a.i64_1 != b.i64_1) return a.i64_1 < b.i64_1;
        return a.submit_order < b.submit_order;
    });
    _epoch_commands.erase(std::remove_if(_epoch_commands.begin(), _epoch_commands.end(),
                                         [&](const Command &cmd) {
        const bool targets_cohort = cmd.opcode != COMMAND_ADD_STOCK &&
                                    cmd.opcode != COMMAND_REMOVE_STOCK &&
                                    cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                                    cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY;
        int32_t slot = -1;
        if (targets_cohort && !_population.valid_handle(cmd.target_handle, slot)) {
            ++_rejected_commands;
            return true;
        }
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK ||
             cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
             cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= _market.market_count || cmd.i32_1 < 0 ||
             cmd.i32_1 >= _market.good_count)) {
            ++_rejected_commands;
            return true;
        }
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
            _merchant_primary_slot[cmd.i32_0] < 0) {
            ++_rejected_commands;
            return true;
        }
        if ((cmd.opcode == COMMAND_MOVE_POPULATION &&
             (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count)) ||
            (cmd.opcode == COMMAND_CHANGE_SIGNATURE &&
             (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(_signatures.size())))) {
            ++_rejected_commands;
            return true;
        }
        if ((cmd.opcode == COMMAND_BUILD || cmd.opcode == COMMAND_DEMOLISH) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count || cmd.i32_1 < 0 ||
             cmd.i32_1 >= static_cast<int32_t>(_building_types.size()) || cmd.i64_0 <= 0)) {
            ++_rejected_commands;
            return true;
        }
        return false;
    }), _epoch_commands.end());
    _stage = _buildings.empty() ? Stage::TRADE_SETTLE : Stage::BUILDING_PLAN;
    return true;
}

bool NativeEconomyRuntime::apply_command(const Command &cmd, std::string &error) {
    int32_t slot = -1;
    int32_t event_cell = -1;
    int64_t settled_value = 0;
    std::vector<EventLeg> event_legs;
    auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
        if (before != after && trace_detail_for_cell(event_cell)) {
            event_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
        }
    };
    switch (cmd.opcode) {
        case COMMAND_TRANSFER_TO_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_ledger";
                return false;
            }
            event_cell = _population.page_cell[slot / PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : _country_runtime->country_handle_for_cell(event_cell));
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
            const int64_t amount = _country_runtime == nullptr ? 0
                : _country_runtime->transfer_cash_to_cohort(country_handle, std::max<int64_t>(0, cmd.i64_0));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t funds_before = _population.funds[slot];
            const int64_t income_before = _population.epoch_income[slot];
            _population.funds[slot] = saturating_add(_population.funds[slot], amount, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, amount, 0);
            settled_value = amount;
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, _country_runtime->total_cash());
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, _population.epoch_income[slot]);
            break;
        }
        case COMMAND_MINT_TO_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_mint";
                return false;
            }
            event_cell = _population.page_cell[slot / PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t funds_before = _population.funds[slot];
            const int64_t income_before = _population.epoch_income[slot];
            _population.funds[slot] = saturating_add(_population.funds[slot], cmd.i64_0, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], cmd.i64_0, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, cmd.i64_0, 0);
            _explicit_money_mint = saturating_add(_explicit_money_mint, cmd.i64_0, _saturation_count);
            settled_value = cmd.i64_0;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, _population.epoch_income[slot]);
            break;
        }
        case COMMAND_BURN_FROM_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_burn";
                return false;
            }
            event_cell = _population.page_cell[slot / PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            const int64_t funds_before = _population.funds[slot];
            const int64_t expense_before = _population.epoch_expense[slot];
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            _explicit_money_burn = saturating_add(_explicit_money_burn, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, _population.epoch_expense[slot]);
            break;
        }
        case COMMAND_ADD_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = _market.stock[idx];
            _market.stock[idx] = saturating_add(_market.stock[idx], cmd.i64_0, _saturation_count);
            _explicit_stock_delta = saturating_add(_explicit_stock_delta, cmd.i64_0, _saturation_count);
            settled_value = _market.stock[idx] - stock_before;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, _market.stock[idx]);
            break;
        }
        case COMMAND_REMOVE_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = _market.stock[idx];
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _market.stock[idx]));
            _market.stock[idx] -= amount;
            _explicit_stock_delta = saturating_sub(_explicit_stock_delta, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, _market.stock[idx]);
            break;
        }
        case COMMAND_COUNTRY_GOOD_TO_MARKET: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !_country_runtime->valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t before = _market.stock[index];
            const int64_t moved = _country_runtime->transfer_good_to_market(
                static_cast<int64_t>(cmd.target_handle), cmd.i32_1, cmd.i64_0);
            _market.stock[index] = saturating_add(_market.stock[index], moved, _saturation_count);
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, _market.stock[index]);
            break;
        }
        case COMMAND_MARKET_GOOD_TO_COUNTRY: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !_country_runtime->valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t before = _market.stock[index];
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, _market.stock[index]));
            const int64_t moved = _country_runtime->transfer_good_from_market(
                static_cast<int64_t>(cmd.target_handle), cmd.i32_1, offered);
            _market.stock[index] -= moved;
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, _market.stock[index]);
            break;
        }
        case COMMAND_ADD_POPULATION: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_population_adjust";
                return false;
            }
            event_cell = _population.page_cell[slot / PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t before = _population.population[slot];
            const int64_t after = std::max<int64_t>(0, saturating_add(before, cmd.i64_0,
                                                                      _saturation_count));
            const int64_t actual_delta = after - before;
            _population.population[slot] = after;
            settled_value = actual_delta;
            add_leg(FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1, before, after);
            _external_population_delta = saturating_add(_external_population_delta, actual_delta,
                                                        _saturation_count);
            if (after == 0) {
                const int32_t cell = _population.page_cell[slot / PAGE_SIZE];
                _structural_commands.push_back({0, slot, cell,
                                                static_cast<int32_t>(_population.signature_id[slot]),
                                                0, 0, cmd.sequence});
            }
            break;
        }
        case COMMAND_MOVE_POPULATION:
        case COMMAND_CHANGE_SIGNATURE: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_structure_queue";
                return false;
            }
            event_cell = _population.page_cell[slot / PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t requested = cmd.i64_0 <= 0 ? _population.population[slot] : cmd.i64_0;
            _structural_commands.push_back({cmd.opcode, slot,
                                            cmd.opcode == COMMAND_MOVE_POPULATION
                                                ? cmd.i32_0
                                                : _population.page_cell[slot / PAGE_SIZE],
                                            cmd.opcode == COMMAND_CHANGE_SIGNATURE
                                                ? cmd.i32_0
                                                : static_cast<int32_t>(_population.signature_id[slot]),
                                            requested, 0, cmd.sequence});
            settled_value = requested;
            break;
        }
        case COMMAND_TRANSFER_FROM_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_transfer";
                return false;
            }
            event_cell = _population.page_cell[slot / PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : _country_runtime->country_handle_for_cell(event_cell));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            const int64_t funds_before = _population.funds[slot];
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
            const int64_t expense_before = _population.epoch_expense[slot];
            const int64_t amount = _country_runtime == nullptr ? 0
                : _country_runtime->transfer_cash_from_cohort(country_handle, offered);
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, _country_runtime->total_cash());
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, _population.epoch_expense[slot]);
            break;
        }
        case COMMAND_BUILD: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_build";
                return false;
            }
            return apply_build_command(cmd, slot, error);
        }
        case COMMAND_DEMOLISH: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_demolish";
                return false;
            }
            return apply_demolish_command(cmd, slot, error);
        }
        default:
            error = "unsupported_command_opcode";
            return false;
    }
    trace_append(EVENT_COMMAND_SETTLED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 event_cell, SUBJECT_COMMAND, cmd.sequence, cmd.opcode, cmd.i32_1,
                 cmd.opcode, settled_value, cmd.i64_0, cmd.i64_1,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

bool NativeEconomyRuntime::process_market_cell(int32_t market, MarketResult &result,
                                              std::string &error) {
    struct NeedState {
        int32_t local_cohort = -1;
        int32_t need_index = -1;
        int64_t desired_units = 0;
        int64_t filled_units = 0;
    };
    struct ComponentRef {
        int32_t order = -1;
        int64_t required_qty = 0;
        int64_t qty_per_need = 0;
    };
    thread_local std::vector<int32_t> slots;
    thread_local std::vector<NeedState> need_states;
    thread_local std::vector<BundleOrder> primary_orders;
    thread_local std::vector<BundleOrder> fallback_orders;
    thread_local std::vector<int64_t> cohort_spend;
    thread_local std::vector<int64_t> cohort_desired;
    thread_local std::vector<int64_t> cohort_filled;
    thread_local std::vector<int64_t> cohort_food_required;
    thread_local std::vector<int64_t> cohort_food_filled;
    thread_local std::vector<int64_t> cohort_subsistence_food_filled;
    thread_local std::vector<int64_t> cohort_staple_required;
    thread_local std::vector<int64_t> cohort_staple_filled;
    thread_local std::vector<int64_t> cohort_clothing_required;
    thread_local std::vector<int64_t> cohort_clothing_filled;
    thread_local std::vector<int64_t> cohort_working_capital_reserve;
    thread_local std::vector<int64_t> production_input_floor;
    thread_local std::vector<int64_t> good_demand;
    thread_local std::vector<int64_t> good_sales;
    thread_local std::vector<int64_t> pass_sales;
    thread_local std::vector<int64_t> pass_demand;
    thread_local std::vector<int64_t> opening_stock;
    thread_local std::vector<int64_t> trace_funds_before;
    thread_local std::vector<int64_t> trace_income_before;
    thread_local std::vector<int64_t> trace_expense_before;
    thread_local std::vector<int64_t> trace_income_ema_before;
    thread_local std::vector<uint16_t> trace_satisfaction_before;
    thread_local std::vector<uint16_t> trace_worst_need_before;
    thread_local std::vector<int32_t> trace_price_before;
    thread_local std::vector<int64_t> trace_demand_ema_before;
    thread_local std::vector<uint16_t> trace_shortage_before;
    thread_local std::vector<int32_t> good_counts;
    thread_local std::vector<int32_t> good_offsets;
    thread_local std::vector<int32_t> good_cursor;
    thread_local std::vector<ComponentRef> component_refs;
    thread_local std::vector<int64_t> variant_score_cache;
    thread_local std::vector<int64_t> variant_price_cache;
    thread_local std::vector<int64_t> need_score_sum_cache;
    thread_local std::vector<int64_t> need_composite_cache;
    thread_local std::vector<int64_t> need_environment_cache;
    thread_local std::vector<int64_t> cohort_worst_q16;
    thread_local std::vector<uint16_t> cohort_worst_need;
    thread_local std::vector<int64_t> expected_births_q32_by_ethnicity;
    int64_t &sat = result.saturation_count;
    bool population_changed = false;
    if (market < 0 || market >= _market.market_count) {
        error = "household_market_out_of_range";
        return false;
    }
    if (_market_cell_offsets.size() != static_cast<size_t>(_market.market_count + 1)) {
        error = "market_cell_range_missing";
        return false;
    }
    slots.clear();
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t market_cell = _market_cells[k];
        _population.for_each_in_cell(market_cell, [&](int32_t slot) { slots.push_back(slot); });
    }
    const int32_t cohort_count = static_cast<int32_t>(slots.size());
    const bool trace_detail = trace_detail_for_cell(market);
    result.cashflows.clear();
    need_states.clear();
    primary_orders.clear();
    fallback_orders.clear();
    cohort_spend.assign(cohort_count, 0);
    cohort_desired.assign(cohort_count, 0);
    cohort_filled.assign(cohort_count, 0);
    cohort_food_required.assign(cohort_count, 0);
    cohort_food_filled.assign(cohort_count, 0);
    cohort_subsistence_food_filled.assign(cohort_count, 0);
    cohort_staple_required.assign(cohort_count, 0);
    cohort_staple_filled.assign(cohort_count, 0);
    cohort_clothing_required.assign(cohort_count, 0);
    cohort_clothing_filled.assign(cohort_count, 0);
    expected_births_q32_by_ethnicity.assign(_ethnicity_ids.size(), 0);
    result.retained_consumed_by_good.assign(_market.good_count, 0);
    cohort_working_capital_reserve.assign(cohort_count, 0);
    production_input_floor.assign(_market.good_count, 0);
    good_demand.assign(_market.good_count, 0);
    good_sales.assign(_market.good_count, 0);
    opening_stock.resize(_market.good_count);
    for (int32_t good = 0; good < _market.good_count; ++good) {
        opening_stock[good] = _market.stock[_market.index(market, good)];
    }
    for (int32_t k = _market_cell_offsets[market];
         k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        if (_market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
            continue;
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            if (signal >= static_cast<int32_t>(_production_input_reserve.size())) continue;
            const int32_t good = _market_signals.good_ids[signal];
            production_input_floor[good] = saturating_add(
                production_input_floor[good], _production_input_reserve[signal], sat);
        }
    }
    if (trace_detail) {
        trace_funds_before.resize(cohort_count);
        trace_income_before.resize(cohort_count);
        trace_expense_before.resize(cohort_count);
        trace_income_ema_before.resize(cohort_count);
        trace_satisfaction_before.resize(cohort_count);
        trace_worst_need_before.resize(cohort_count);
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            trace_funds_before[local] = _population.funds[slot];
            trace_income_before[local] = _population.epoch_income[slot];
            trace_expense_before[local] = _population.epoch_expense[slot];
            trace_income_ema_before[local] = _population.income_ema[slot];
            trace_satisfaction_before[local] = _population.needs_satisfaction[slot];
            trace_worst_need_before[local] = _population.worst_need_id[slot];
        }
        trace_price_before.resize(_market.good_count);
        trace_demand_ema_before.resize(_market.good_count);
        trace_shortage_before.resize(_market.good_count);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            trace_price_before[good] = _market.price[idx];
            trace_demand_ema_before[good] = _market.demand_ema[idx];
            trace_shortage_before[good] = _market.last_shortage_q16[idx];
        }
    }
    for (int32_t slot : slots) touch_accounting_slot(slot);

    // Household clearing must not consume the physical-input float needed to
    // start the next production period. Output is sold after inputs are bought,
    // so an owner cohort with no protected working capital cannot self-recover.
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) continue;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.count <= 0 || group.operating_state != 0 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (type.input_count <= 0 || group.sample_unit_input_cost <= 0) continue;
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            const auto local_it = std::find(slots.begin(), slots.end(), owner_slot);
            if (local_it == slots.end()) continue;
            const int32_t local = static_cast<int32_t>(local_it - slots.begin());
            const int64_t owner_demand = saturating_mul(
                group.count, type.owner_slots_per_building, sat);
            const int64_t owner_scale_q16 = owner_demand > 0
                ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                    group.filled_owner, Q16_ONE, owner_demand, sat)) : 0;
            const int64_t operation_scale_q16 = std::min<int64_t>(
                owner_scale_q16, std::clamp<int64_t>(
                    group.planned_utilization_q16, 0, Q16_ONE));
            const int64_t full_period_cost = saturating_mul(
                saturating_mul(group.sample_unit_input_cost, group.count, sat),
                std::max(1, _epoch_days), sat);
            const int64_t reserve = mul_div_sat(
                full_period_cost, operation_scale_q16, Q16_ONE, sat);
            cohort_working_capital_reserve[local] = saturating_add(
                cohort_working_capital_reserve[local], reserve, sat);
            result.owner_working_capital_reserved = saturating_add(
                result.owner_working_capital_reserved, reserve, sat);
        }
    }

    const auto formula_start = Clock::now();
    // Price and environment are frozen for the whole market tick. Compile the
    // variant side once per market instead of repeating it for every cohort.
    const EnvironmentSample market_environment = environment_sample_for_cell(market);
    build_demand_basis_cached(market, market, market_environment,
                       variant_score_cache, variant_price_cache,
                       need_score_sum_cache, need_composite_cache,
                       need_environment_cache, sat);
    compute_cell_living_costs_from_basis(
        market, variant_score_cache, variant_price_cache,
        need_score_sum_cache, need_environment_cache, sat);
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const uint32_t signature_id = _population.signature_id[slot];
        if (signature_id >= _signatures.size()) {
            error = "cohort_signature_invalid";
            return false;
        }
        const Signature &signature = _signatures[signature_id];
        const Plan &plan = _plans[signature.plan_id];
        const int64_t population = std::max<int64_t>(0, _population.population[slot]);
        if (population <= 0) continue;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            // Frozen-sample approximation: calculate the whole market cycle
            // from the cohort/price/environment state captured at sample_day.
            const int64_t survival_required = survival_required_units(
                slot, need.stable_id, _epoch_days, market_environment, sat);
            if (std::find(_survival_food_need_stable_ids.begin(),
                          _survival_food_need_stable_ids.end(), need.stable_id) !=
                _survival_food_need_stable_ids.end()) {
                cohort_food_required[local] = saturating_add(
                    cohort_food_required[local], survival_required, sat);
                if (need.stable_id == _survival_staple_need_stable_id) {
                    cohort_staple_required[local] = saturating_add(
                        cohort_staple_required[local], survival_required, sat);
                }
            } else if (need.stable_id == _survival_clothing_need_stable_id) {
                cohort_clothing_required[local] = saturating_add(
                    cohort_clothing_required[local], survival_required, sat);
            }
            const int64_t score_sum = need_score_sum_cache[need_index];
            if (score_sum <= 0) continue;
            const int64_t ordinary_desired = desired_need_units(
                slot, need_index, _epoch_days, need_environment_cache[need_index],
                need_composite_cache[need_index], sat);
            const int64_t desired = std::max(ordinary_desired, survival_required);
            if (desired <= 0) continue;
            const int32_t state_index = static_cast<int32_t>(need_states.size());
            need_states.push_back({local, need_index, desired, 0});
            cohort_desired[local] = saturating_add(cohort_desired[local], desired, sat);
            int64_t prefix_score = 0;
            int64_t allocated = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                prefix_score = saturating_add(prefix_score, variant_score_cache[variant_id], sat);
                const int64_t next = mul_div_sat(desired, prefix_score, score_sum, sat);
                const int64_t units = std::max<int64_t>(0, next - allocated);
                allocated = next;
                if (units > 0) {
                    primary_orders.push_back({local, slot, state_index, variant_id,
                                              need.priority, units, 0, 0,
                                              variant_price_cache[variant_id]});
                }
            }
            ++result.processed_needs;
            result.processed_variants += need.variant_count;
        }
    }
    auto retained_begin = [&](int32_t owner_slot, int32_t good_id) {
        return std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(),
            std::pair<int32_t, int32_t>{owner_slot, good_id},
            [](const OwnerRetainedOutput &entry, const std::pair<int32_t, int32_t> &key) {
                return std::pair<int32_t, int32_t>{entry.owner_slot, entry.good_id} < key;
        });
    };
    auto record_in_kind_value = [&](int32_t owner_slot, int32_t good_id,
                                    int32_t building_group, int64_t quantity) {
        if (quantity <= 0 || owner_slot < 0 || good_id < 0 ||
            good_id >= _market.good_count ||
            owner_slot >= static_cast<int32_t>(_population.active.size()) ||
            _population.active[owner_slot] == 0) return;
        const int32_t page = owner_slot / PAGE_SIZE;
        if (page < 0 || page >= static_cast<int32_t>(_population.page_cell.size())) return;
        const int32_t cell = _population.page_cell[page];
        if (cell < 0 || cell >= static_cast<int32_t>(_market.cell_to_market.size())) return;
        const int32_t market = _market.cell_to_market[cell];
        if (market < 0 || market >= _market.market_count) return;
        const int64_t price = _market.price[_market.index(market, good_id)];
        const int64_t value = mul_div_sat(quantity, price, GOODS_SCALE, sat);
        _population.epoch_in_kind_income[owner_slot] = saturating_add(
            _population.epoch_in_kind_income[owner_slot], value, sat);
        if (building_group >= 0) {
            result.building_in_kind_credits.push_back({building_group, value});
        }
        result.retained_consumed_by_good[good_id] = saturating_add(
            result.retained_consumed_by_good[good_id], quantity, sat);
    };
    for (BundleOrder &order : primary_orders) {
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t retained_capacity = order.desired_units;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            int64_t quantity = 0;
            auto found = retained_begin(order.slot, component.good_id);
            while (found != _owner_retained_outputs.end() &&
                   found->owner_slot == order.slot &&
                   found->good_id == component.good_id) {
                quantity = saturating_add(quantity, found->quantity, sat);
                ++found;
            }
            retained_capacity = std::min(retained_capacity, mul_div_sat(
                quantity, GOODS_SCALE, component.qty_per_need, sat));
        }
        if (retained_capacity <= 0) continue;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            int64_t remaining = mul_div_sat(
                retained_capacity, component.qty_per_need, GOODS_SCALE, sat);
            auto found = retained_begin(order.slot, component.good_id);
            while (remaining > 0 && found != _owner_retained_outputs.end() &&
                   found->owner_slot == order.slot &&
                   found->good_id == component.good_id) {
                const int64_t used = std::min(remaining, found->quantity);
                found->quantity -= used;
                remaining -= used;
                record_in_kind_value(order.slot, component.good_id,
                                     found->building_group, used);
                ++found;
            }
            const int64_t used = mul_div_sat(
                retained_capacity, component.qty_per_need, GOODS_SCALE, sat) - remaining;
            result.retained_output_consumed = saturating_add(
                result.retained_output_consumed, used, sat);
        }
        need_states[order.need_index].filled_units = saturating_add(
            need_states[order.need_index].filled_units, retained_capacity, sat);
        order.desired_units -= retained_capacity;
    }
    // Exact plan variants consume retained output first. Any remaining
    // producer-retained food then acts as emergency calories across the three
    // survival food needs; preference still affects ordinary satisfaction, but
    // a hunter or fisher can live from the food it physically produced.
    for (int32_t local = 0; local < cohort_count; ++local) {
        int64_t food_filled = 0;
        for (const NeedState &state : need_states) {
            if (state.local_cohort != local) continue;
            const int32_t stable_need = _needs[state.need_index].stable_id;
            if (std::find(_survival_food_need_stable_ids.begin(),
                          _survival_food_need_stable_ids.end(), stable_need) ==
                _survival_food_need_stable_ids.end()) continue;
            food_filled = saturating_add(food_filled, state.filled_units, sat);
        }
        int64_t remaining = std::max<int64_t>(0, mul_div_sat(
            cohort_food_required[local], _survival_production_target_q16,
            Q16_ONE, sat) - food_filled);
        if (remaining <= 0) continue;
        auto entry = std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(), slots[local],
            [](const OwnerRetainedOutput &value, int32_t owner_slot) {
                return value.owner_slot < owner_slot;
            });
        while (remaining > 0 && entry != _owner_retained_outputs.end() &&
               entry->owner_slot == slots[local]) {
            if (entry->good_id >= 0 &&
                entry->good_id < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                _survival_food_good_mask[entry->good_id] != 0) {
                const int64_t used = std::min(remaining, entry->quantity);
                entry->quantity -= used;
                remaining -= used;
                record_in_kind_value(slots[local], entry->good_id,
                                     entry->building_group, used);
                cohort_subsistence_food_filled[local] = saturating_add(
                    cohort_subsistence_food_filled[local], used, sat);
                result.retained_output_consumed = saturating_add(
                    result.retained_output_consumed, used, sat);
            }
            ++entry;
        }
    }
    result.formula_ms += elapsed_ms(formula_start);

    auto budget_orders = [&](std::vector<BundleOrder> &orders, bool use_remaining) {
        thread_local std::vector<int64_t> budget_committed;
        budget_committed.assign(cohort_count, 0);
        size_t begin = 0;
        while (begin < orders.size()) {
            const int32_t local = orders[begin].local_cohort;
            const int32_t priority = orders[begin].priority;
            size_t end = begin + 1;
            while (end < orders.size() && orders[end].local_cohort == local &&
                   orders[end].priority == priority) ++end;
            int64_t remaining = std::max<int64_t>(
                0, _population.funds[slots[local]] -
                    cohort_working_capital_reserve[local] -
                    (use_remaining ? cohort_spend[local] : 0) -
                    budget_committed[local]);
            int64_t total_cost = 0;
            for (size_t i = begin; i < end; ++i) {
                total_cost = saturating_add(total_cost,
                    mul_div_sat(orders[i].desired_units, orders[i].unit_price,
                                GOODS_SCALE, sat), sat);
            }
            if (total_cost <= remaining) {
                for (size_t i = begin; i < end; ++i) orders[i].funded_units = orders[i].desired_units;
            } else if (remaining > 0 && total_cost > 0) {
                int64_t cost_prefix = 0;
                int64_t allocated_cost = 0;
                for (size_t i = begin; i < end; ++i) {
                    cost_prefix = saturating_add(cost_prefix,
                        mul_div_sat(orders[i].desired_units, orders[i].unit_price,
                                    GOODS_SCALE, sat), sat);
                    const int64_t next = mul_div_sat(cost_prefix, remaining, total_cost, sat);
                    const int64_t share = std::max<int64_t>(0, next - allocated_cost);
                    allocated_cost = next;
                    orders[i].funded_units = std::min(orders[i].desired_units,
                        mul_div_sat(share, GOODS_SCALE, orders[i].unit_price, sat));
                }
            }
            int64_t committed = 0;
            for (size_t i = begin; i < end; ++i) {
                committed = saturating_add(committed, mul_div_sat(
                    orders[i].funded_units, orders[i].unit_price,
                    GOODS_SCALE, sat), sat);
            }
            budget_committed[local] = saturating_add(
                budget_committed[local], committed, sat);
            begin = end;
        }
    };

    auto clear_orders = [&](std::vector<BundleOrder> &orders) -> bool {
        good_counts.assign(_market.good_count, 0);
        pass_demand.assign(_market.good_count, 0);
        for (const BundleOrder &order : orders) {
            if (order.funded_units <= 0) continue;
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                ++good_counts[component.good_id];
                const int64_t required = mul_div_sat(order.funded_units,
                                                     component.qty_per_need, GOODS_SCALE, sat);
                pass_demand[component.good_id] = saturating_add(
                    pass_demand[component.good_id], required, sat);
                good_demand[component.good_id] = saturating_add(
                    good_demand[component.good_id], required, sat);
                ++result.processed_components;
            }
        }
        bool abundant = true;
        for (int32_t good = 0; good < _market.good_count; ++good) {
            abundant &= std::max<int64_t>(0,
                _market.stock[_market.index(market, good)] -
                    production_input_floor[good]) >= pass_demand[good];
        }
        if (abundant) {
            for (BundleOrder &order : orders) {
                order.filled_units = order.funded_units;
                if (order.filled_units <= 0) continue;
                const int64_t spend = mul_div_sat(order.filled_units, order.unit_price,
                                                  GOODS_SCALE, sat);
                cohort_spend[order.local_cohort] = saturating_add(
                    cohort_spend[order.local_cohort], spend, sat);
                need_states[order.need_index].filled_units = saturating_add(
                    need_states[order.need_index].filled_units, order.filled_units, sat);
            }
            for (int32_t good = 0; good < _market.good_count; ++good) {
                const int64_t idx = _market.index(market, good);
                _market.stock[idx] -= pass_demand[good];
                good_sales[good] = saturating_add(good_sales[good], pass_demand[good], sat);
                result.consumed_goods = saturating_add(result.consumed_goods,
                                                       pass_demand[good], sat);
            }
            return true;
        }
        good_offsets.assign(_market.good_count + 1, 0);
        good_cursor.assign(_market.good_count, 0);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            good_offsets[good + 1] = good_offsets[good] + good_counts[good];
            good_cursor[good] = good_offsets[good];
        }
        component_refs.assign(good_offsets.back(), {});
        for (int32_t o = 0; o < static_cast<int32_t>(orders.size()); ++o) {
            BundleOrder &order = orders[o];
            order.filled_units = order.funded_units;
            if (order.funded_units <= 0) continue;
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                const int64_t required = mul_div_sat(order.funded_units,
                                                     component.qty_per_need, GOODS_SCALE, sat);
                component_refs[good_cursor[component.good_id]++] =
                    {o, required, component.qty_per_need};
            }
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            int64_t total = 0;
            for (int32_t k = good_offsets[good]; k < good_offsets[good + 1]; ++k) {
                total = saturating_add(total, component_refs[k].required_qty, sat);
            }
            const int64_t available = std::min<int64_t>(
                std::max<int64_t>(0, _market.stock[_market.index(market, good)] -
                    production_input_floor[good]), total);
            int64_t demand_prefix = 0;
            int64_t filled_prefix = 0;
            for (int32_t k = good_offsets[good]; k < good_offsets[good + 1]; ++k) {
                ComponentRef &ref = component_refs[k];
                demand_prefix = saturating_add(demand_prefix, ref.required_qty, sat);
                const int64_t next = total > 0
                    ? mul_div_sat(demand_prefix, available, total, sat) : 0;
                const int64_t allocated_qty = std::max<int64_t>(0, next - filled_prefix);
                filled_prefix = next;
                const int64_t bundle_capacity = mul_div_sat(
                    allocated_qty, GOODS_SCALE, ref.qty_per_need, sat);
                orders[ref.order].filled_units = std::min(
                    orders[ref.order].filled_units, bundle_capacity);
            }
        }
        pass_sales.assign(_market.good_count, 0);
        for (BundleOrder &order : orders) {
            if (order.filled_units <= 0) continue;
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                const int64_t used = mul_div_sat(order.filled_units,
                                                 component.qty_per_need, GOODS_SCALE, sat);
                pass_sales[component.good_id] = saturating_add(pass_sales[component.good_id],
                                                               used, sat);
            }
            const int64_t spend = mul_div_sat(order.filled_units, order.unit_price,
                                              GOODS_SCALE, sat);
            cohort_spend[order.local_cohort] = saturating_add(
                cohort_spend[order.local_cohort], spend, sat);
            need_states[order.need_index].filled_units = saturating_add(
                need_states[order.need_index].filled_units, order.filled_units, sat);
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            const int64_t used = std::min(pass_sales[good], _market.stock[idx]);
            _market.stock[idx] -= used;
            good_sales[good] = saturating_add(good_sales[good], used, sat);
            result.consumed_goods = saturating_add(result.consumed_goods, used, sat);
        }
        return false;
    };

    const auto clear_start = Clock::now();
    budget_orders(primary_orders, false);
    const bool primary_inventory_abundant = clear_orders(primary_orders);
    result.clear_ms += elapsed_ms(clear_start);

    const auto fallback_start = Clock::now();
    // A fallback is a stock-substitution mechanism, not a second budget pass.
    // If every primary bundle was available, any unmet amount is budget-only.
    if (!primary_inventory_abundant) for (int32_t state_index = 0;
         state_index < static_cast<int32_t>(need_states.size()); ++state_index) {
        NeedState &state = need_states[state_index];
        const int64_t unmet = std::max<int64_t>(0, state.desired_units - state.filled_units);
        if (unmet <= 0) continue;
        const Need &need = _needs[state.need_index];
        int64_t score_sum = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            bool available = true;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                available &= _market.stock[_market.index(market, component.good_id)] >
                    production_input_floor[component.good_id];
            }
            if (!available) continue;
            const int64_t score = variant_score_cache[variant_id];
            if (score <= 0) continue;
            score_sum = saturating_add(score_sum, score, sat);
        }
        int64_t score_prefix = 0;
        int64_t allocated = 0;
        for (int32_t v = 0; v < need.variant_count && score_sum > 0; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            bool available = true;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                available &= _market.stock[_market.index(market, component.good_id)] >
                    production_input_floor[component.good_id];
            }
            if (!available || variant_score_cache[variant_id] <= 0) continue;
            score_prefix = saturating_add(score_prefix, variant_score_cache[variant_id], sat);
            const int64_t next = mul_div_sat(unmet, score_prefix, score_sum, sat);
            const int64_t units = std::max<int64_t>(0, next - allocated);
            allocated = next;
            if (units > 0) fallback_orders.push_back({
                state.local_cohort, slots[state.local_cohort], state_index, variant_id,
                need.priority, units, 0, 0, variant_price_cache[variant_id]});
        }
    }
    if (!primary_inventory_abundant) {
        budget_orders(fallback_orders, true);
        clear_orders(fallback_orders);
    }
    for (int32_t slot : slots) {
        auto entry = std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(), slot,
            [](const OwnerRetainedOutput &value, int32_t owner_slot) {
                return value.owner_slot < owner_slot;
            });
        while (entry != _owner_retained_outputs.end() && entry->owner_slot == slot) {
            result.retained_output_discarded = saturating_add(
                result.retained_output_discarded, entry->quantity, sat);
            if (entry->quantity > 0 && entry->building_group >= 0 &&
                entry->building_group < static_cast<int32_t>(_buildings.size())) {
                _buildings[entry->building_group].last_discarded = saturating_add(
                    _buildings[entry->building_group].last_discarded,
                    entry->quantity, sat);
            }
            entry->quantity = 0;
            ++entry;
        }
    }
    result.fallback_ms += elapsed_ms(fallback_start);

    const auto merchant_start = Clock::now();
    int64_t revenue = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const int64_t spend = std::min(cohort_spend[local], std::max<int64_t>(
            0, _population.funds[slot] - cohort_working_capital_reserve[local]));
        _population.funds[slot] -= spend;
        _population.epoch_expense[slot] = saturating_add(
            _population.epoch_expense[slot], spend, sat);
        if (trace_detail && spend > 0) {
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_HOUSEHOLD_CONSUMPTION, 0, spend});
        }
        revenue = saturating_add(revenue, spend, sat);
    }
    const int32_t merchant_begin = _merchant_offsets[market];
    const int32_t merchant_end = _merchant_offsets[market + 1];
    int64_t merchant_population = 0;
    for (int32_t k = merchant_begin; k < merchant_end; ++k) {
        merchant_population = saturating_add(merchant_population,
            _population.population[_merchant_slots[k]], sat);
    }
    if (revenue > 0 && merchant_population <= 0) {
        error = "market_revenue_has_no_merchant_owner";
        return false;
    }
    int64_t population_prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = merchant_begin; k < merchant_end; ++k) {
        const int32_t slot = _merchant_slots[k];
        population_prefix = saturating_add(population_prefix, _population.population[slot], sat);
        const int64_t next = merchant_population > 0
            ? mul_div_sat(revenue, population_prefix, merchant_population, sat) : 0;
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        _population.funds[slot] = saturating_add(_population.funds[slot], share, sat);
        _population.epoch_income[slot] = saturating_add(
            _population.epoch_income[slot], share, sat);
        if (trace_detail && share > 0) {
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_MERCHANT_HOUSEHOLD, share, 0});
        }
    }
    result.merchant_count += merchant_end - merchant_begin;
    result.revenue = revenue;
    cohort_worst_q16.assign(cohort_count, Q16_ONE - 1);
    cohort_worst_need.assign(cohort_count, std::numeric_limits<uint16_t>::max());
    cohort_filled.assign(cohort_count, 0);
    for (const NeedState &state : need_states) {
        const int32_t local = state.local_cohort;
        cohort_filled[local] = saturating_add(cohort_filled[local], state.filled_units, sat);
        const int32_t stable_need = _needs[state.need_index].stable_id;
        if (std::find(_survival_food_need_stable_ids.begin(),
                      _survival_food_need_stable_ids.end(), stable_need) !=
            _survival_food_need_stable_ids.end()) {
            cohort_food_filled[local] = saturating_add(
                cohort_food_filled[local], state.filled_units, sat);
            if (stable_need == _survival_staple_need_stable_id) {
                cohort_staple_filled[local] = saturating_add(
                    cohort_staple_filled[local], state.filled_units, sat);
            }
        } else if (stable_need == _survival_clothing_need_stable_id) {
            cohort_clothing_filled[local] = saturating_add(
                cohort_clothing_filled[local], state.filled_units, sat);
        }
        const int64_t satisfaction = state.desired_units <= 0
            ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(state.filled_units, Q16_ONE,
                                              state.desired_units, sat), 0, Q16_ONE - 1);
        if (satisfaction < cohort_worst_q16[local]) {
            cohort_worst_q16[local] = satisfaction;
            cohort_worst_need[local] = static_cast<uint16_t>(_needs[state.need_index].stable_id);
        }
    }
    int64_t remaining_market_population = 0;
    for (int32_t slot : slots) remaining_market_population = saturating_add(
        remaining_market_population, std::max<int64_t>(0, _population.population[slot]), sat);
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        cohort_food_filled[local] = saturating_add(
            cohort_food_filled[local], cohort_subsistence_food_filled[local], sat);
        const int64_t balanced_food_q16 = cohort_food_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_food_filled[local], Q16_ONE, cohort_food_required[local], sat),
                0, Q16_ONE - 1);
        const int64_t staple_q16 = cohort_staple_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_staple_filled[local], Q16_ONE, cohort_staple_required[local], sat),
                0, Q16_ONE - 1);
        // 主食单独覆盖最低热量生存；蛋白质与蔬果仍可通过综合膳食补足缺口。
        const int64_t food_q16 = std::max(staple_q16, balanced_food_q16);
        const int64_t clothing_q16 = cohort_clothing_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_clothing_filled[local], Q16_ONE,
                cohort_clothing_required[local], sat), 0, Q16_ONE - 1);
        const int32_t cell = _population.page_cell[slot / PAGE_SIZE];
        const int64_t temperature_q16 = cell >= 0 && cell < _cell_count
            ? _environment_temperature_q16[cell] : Q16_ONE / 2;
        const int64_t snow_q16 = cell >= 0 && cell < _cell_count
            ? _environment_snow_q16[cell] : 0;
        const int64_t temperature_exposure_q16 = std::clamp<int64_t>(
            (Q16_ONE / 2 - temperature_q16) * 2, 0, Q16_ONE);
        const int64_t cold_exposure_q16 = std::max<int64_t>(
            temperature_exposure_q16, std::clamp<int64_t>(snow_q16, 0, Q16_ONE));
        const int64_t clothing_deficit_q16 = Q16_ONE - clothing_q16;
        const int64_t cold_clothing_ceiling_q16 = Q16_ONE - mul_div_sat(
            cold_exposure_q16, clothing_deficit_q16, Q16_ONE, sat);
        const int64_t survival_q16 = std::min(food_q16, cold_clothing_ceiling_q16);
        _population.needs_satisfaction[slot] = static_cast<uint16_t>(survival_q16);
        _population.worst_need_id[slot] = cohort_worst_need[local];
        const int64_t net_income = saturating_sub(_population.epoch_income[slot],
                                                  _population.epoch_expense[slot], sat);
        const int64_t daily_net_income = net_income / std::max(1, _epoch_days);
        const int64_t income_alpha_q16 = std::min<int64_t>(
            Q16_ONE, static_cast<int64_t>(_epoch_days) * (Q16_ONE / 8));
        _population.income_ema[slot] = saturating_add(
            mul_div_sat(_population.income_ema[slot], Q16_ONE - income_alpha_q16,
                        Q16_ONE, sat),
            mul_div_sat(daily_net_income, income_alpha_q16, Q16_ONE, sat), sat);

        const uint32_t signature_id = _population.signature_id[slot];
        const Signature &signature = _signatures[signature_id];
        if (signature.ethnicity_id >= 0 && signature.ethnicity_id <
                static_cast<int32_t>(expected_births_q32_by_ethnicity.size())) {
            // u16 satisfaction tops out at Q16_ONE - 1; treat that encoded
            // ceiling as fully satisfied for the calibrated birth attractor.
            const int64_t birth_satisfaction_q16 = survival_q16 >= Q16_ONE - 1
                ? Q16_ONE : std::clamp<int64_t>(survival_q16, 0, Q16_ONE);
            const int64_t birth_weight_q16 = std::clamp<int64_t>(
                signature.satisfaction_birth_weight_q16, 0, Q16_ONE);
            const int64_t birth_reduction_q16 = mul_div_sat(
                birth_weight_q16, Q16_ONE - birth_satisfaction_q16, Q16_ONE, sat);
            const int64_t birth_factor_q16 = std::clamp<int64_t>(
                Q16_ONE - birth_reduction_q16, 0, Q16_ONE);
            const int64_t effective_birth_rate_q32 = mul_div_sat(
                std::max<int64_t>(0, signature.birth_rate_q32), birth_factor_q16,
                Q16_ONE, sat);
            const int64_t expected_births_q32 = saturating_mul(
                saturating_mul(std::max<int64_t>(0, _population.population[slot]),
                               effective_birth_rate_q32, sat),
                std::max(1, _epoch_days), sat);
            expected_births_q32_by_ethnicity[signature.ethnicity_id] = saturating_add(
                expected_births_q32_by_ethnicity[signature.ethnicity_id],
                expected_births_q32, sat);
        }
        const int64_t survival_deficit = std::max<int64_t>(
            0, _starvation_satisfaction_threshold_q16 - survival_q16);
        const int64_t starvation_rate_q32 = mul_div_sat(
            _starvation_death_rate_q32, survival_deficit,
            _starvation_satisfaction_threshold_q16, sat);
        const int64_t effective_death_rate_q32 = saturating_add(
            signature.death_rate_q32, starvation_rate_q32, sat);
        int64_t death_numerator_q32 = saturating_add(
            _population.demography_residual[slot], saturating_mul(
                saturating_mul(std::max<int64_t>(0, _population.population[slot]),
                               effective_death_rate_q32, sat),
                std::max(1, _epoch_days), sat), sat);
        int64_t deaths = death_numerator_q32 / Q32_ONE;
        const int64_t population_before = std::max<int64_t>(0, _population.population[slot]);
        const int64_t market_survivor_floor = remaining_market_population <= population_before ? 1 : 0;
        deaths = std::clamp<int64_t>(deaths, 0,
            std::max<int64_t>(0, population_before - market_survivor_floor));
        _population.demography_residual[slot] = deaths >= population_before
            ? 0 : death_numerator_q32 % Q32_ONE;
        if (deaths > 0) {
            _population.population[slot] -= deaths;
            population_changed = true;
            remaining_market_population -= deaths;
            result.deaths = saturating_add(result.deaths, deaths, sat);
            if (_population.population[slot] == 0) {
                const int32_t cell = _population.page_cell[slot / PAGE_SIZE];
                result.structural_commands.push_back({
                    0, slot, cell, static_cast<int32_t>(signature_id), 0, 0, _epoch_id});
            }
        }
    }
    const int32_t birth_cell = _market_cell_offsets[market] <
            _market_cell_offsets[market + 1]
        ? _market_cells[_market_cell_offsets[market]] : market;
    if (population_changed) result.population_changed_cells.push_back(birth_cell);
    for (int32_t ethnicity = 0; ethnicity <
            static_cast<int32_t>(expected_births_q32_by_ethnicity.size()); ++ethnicity) {
        const int64_t expected_q32 = expected_births_q32_by_ethnicity[ethnicity];
        if (expected_q32 <= 0) continue;
        int64_t births = expected_q32 / Q32_ONE;
        const uint64_t fraction_q32 = static_cast<uint64_t>(expected_q32 % Q32_ONE);
        if (fraction_q32 > 0) {
            uint64_t roll_hash = 1469598103934665603ULL;
            roll_hash = trace_hash_mix(roll_hash, 0x4249525448ULL); // "BIRTH"
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_seed));
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_sample_day));
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(birth_cell));
            roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(ethnicity));
            const uint64_t roll_q32 = roll_hash & 0xffffffffULL;
            if (roll_q32 < fraction_q32) ++births;
        }
        if (births <= 0) continue;
        const int32_t unemployed_signature = unemployed_signature_for_ethnicity(ethnicity);
        if (unemployed_signature < 0) {
            error = "birth_unemployed_signature_missing";
            return false;
        }
        result.births = saturating_add(result.births, births, sat);
        result.structural_commands.push_back({
            STRUCTURAL_BIRTH, -1, birth_cell, unemployed_signature,
            births, 0, _epoch_id});
    }
    result.merchant_settle_ms += elapsed_ms(merchant_start);

    const auto price_start = Clock::now();
    for (int32_t good = 0; good < _market.good_count; ++good) {
        const int64_t idx = _market.index(market, good);
        const int64_t old_ema = _market.demand_ema[idx];
        const int64_t daily_demand = good_demand[good] / std::max(1, _epoch_days);
        const int64_t alpha = std::min<int64_t>(Q16_ONE,
            static_cast<int64_t>(std::clamp<int32_t>(
                _good_demand_ema_alpha_q16[good], 0, Q16_ONE)) * _epoch_days);
        const int64_t ema = saturating_add(
            mul_div_sat(old_ema, Q16_ONE - alpha, Q16_ONE, sat),
            mul_div_sat(daily_demand, alpha, Q16_ONE, sat), sat);
        _market.demand_ema[idx] = ema;
        const int32_t signal_index = market_signal_index(market, good);
        if (signal_index >= 0) {
            const int64_t nonhousehold = signal_index < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())
                ? _epoch_nonhousehold_withdrawals[signal_index] : 0;
            const int64_t observed_daily = saturating_add(
                saturating_add(good_sales[good], nonhousehold, sat),
                result.retained_consumed_by_good[good], sat) /
                std::max(1, _epoch_days);
            const int64_t old_withdrawal =
                _market_signals.realized_withdrawal_ema[signal_index];
            _market_signals.realized_withdrawal_ema[signal_index] = saturating_add(
                mul_div_sat(old_withdrawal, Q16_ONE - alpha, Q16_ONE, sat),
                mul_div_sat(observed_daily, alpha, Q16_ONE, sat), sat);
        }
        const int64_t shortage = good_demand[good] <= 0 ? 0 : std::clamp<int64_t>(
            Q16_ONE - mul_div_sat(good_sales[good], Q16_ONE, good_demand[good], sat),
            0, Q16_ONE);
        _market.last_shortage_q16[idx] = static_cast<uint16_t>(
            std::min<int64_t>(Q16_ONE - 1, shortage));
        const PricePressure pressure = price_pressure(
            market, good, ema, _market.stock[idx], shortage, signal_index, sat);
        if (pressure.cost_q16 != 0) ++result.price_cost_anchor_hits;
        if (pressure.idle_q16 != 0) ++result.price_inactive_reversions;
        int64_t change_q16 = pressure.change_q16;
        const int64_t unclamped = change_q16;
        change_q16 = std::clamp<int64_t>(change_q16,
            -static_cast<int64_t>(_good_max_price_fall_q16[good]),
            static_cast<int64_t>(_good_max_price_rise_q16[good]));
        // First-order frozen-pressure integration. This is intentionally
        // linear rather than N calls to pow/price feedback. Per-period change
        // guards keep the approximation deterministic and cheap.
        const int64_t period_change_q16 = saturating_mul(change_q16, _epoch_days, sat);
        int64_t next_price = saturating_add(_market.price[idx],
            mul_div_sat(_market.price[idx], period_change_q16, Q16_ONE, sat), sat);
        if (pressure.cost_floor_price > _market.price[idx]) {
            const int64_t max_rise_period_q16 = saturating_mul(
                _good_max_price_rise_q16[good], _epoch_days, sat);
            const int64_t max_cost_price = saturating_add(_market.price[idx], mul_div_sat(
                _market.price[idx], max_rise_period_q16, Q16_ONE, sat), sat);
            next_price = std::max(next_price, std::min<int64_t>(
                pressure.cost_floor_price, max_cost_price));
        }
        const int64_t bounded = std::clamp<int64_t>(
            next_price, PRICE_NUMERIC_GUARD_MIN, PRICE_NUMERIC_GUARD_MAX);
        if (unclamped != change_q16 || bounded != next_price) ++result.price_cap_hits;
        if (_market.price[idx] != bounded) ++result.changed_prices;
        _market.price[idx] = static_cast<int32_t>(bounded);
        const int32_t flow_index = trade_flow_index(market, good, false);
        if (_good_trade_enabled[good] != 0 && _good_storage_modes[good] == 0 &&
            (_market.stock[idx] > 0 || ema > 0 || shortage > 0 || signal_index >= 0 ||
             flow_index >= 0)) {
            result.trade_active_goods.push_back(good);
        }
    }
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.revenue));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.consumed_goods));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.changed_prices));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.price_cap_hits));
    if (trace_detail) {
        auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                           int32_t key_id, int64_t before, int64_t after) {
            if (before != after) result.trace_legs.push_back(
                {field, subject_kind, subject_id, key_id, before, after});
        };
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(slot));
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                    trace_funds_before[local], _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                    trace_income_before[local], _population.epoch_income[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, handle, -1,
                    trace_expense_before[local], _population.epoch_expense[slot]);
            add_leg(FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, handle, -1,
                    trace_income_ema_before[local], _population.income_ema[slot]);
            add_leg(FIELD_COHORT_SATISFACTION, SUBJECT_COHORT, handle, -1,
                    trace_satisfaction_before[local], _population.needs_satisfaction[slot]);
            add_leg(FIELD_COHORT_WORST_NEED, SUBJECT_COHORT, handle, -1,
                    trace_worst_need_before[local], _population.worst_need_id[slot]);
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good,
                    opening_stock[good], _market.stock[idx]);
            add_leg(FIELD_MARKET_PRICE, SUBJECT_MARKET, market, good,
                    trace_price_before[good], _market.price[idx]);
            add_leg(FIELD_MARKET_DEMAND_EMA, SUBJECT_MARKET, market, good,
                    trace_demand_ema_before[good], _market.demand_ema[idx]);
            add_leg(FIELD_MARKET_SHORTAGE, SUBJECT_MARKET, market, good,
                    trace_shortage_before[good], _market.last_shortage_q16[idx]);
        }
    }
    result.price_ms += elapsed_ms(price_start);
    result.processed_cohorts += cohort_count;
    result.processed_rules += result.processed_components;
    finalize_market_result(market, result);
    return true;
}

bool NativeEconomyRuntime::commit_structural(const StructuralCommand &cmd,
                                             std::string &error) {
    if (cmd.opcode == STRUCTURAL_BIRTH) {
        if (cmd.cell < 0 || cmd.cell >= _cell_count || cmd.signature < 0 ||
            cmd.signature >= static_cast<int32_t>(_signatures.size()) ||
            cmd.population <= 0 || _signatures[cmd.signature].profession_id !=
                _unemployed_profession_id) {
            error = "structural_birth_target_invalid";
            return false;
        }
        const int32_t destination = _population.allocate_slot(
            cmd.cell, static_cast<uint32_t>(cmd.signature));
        if (destination < 0) {
            error = "structural_birth_allocation_failed";
            return false;
        }
        touch_accounting_slot(destination);
        const int64_t population_before = _population.population[destination];
        _population.population[destination] = saturating_add(
            population_before, cmd.population, _saturation_count);
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            static_cast<int64_t>(_population.handle_for_slot(destination)), -1,
                            population_before, _population.population[destination]});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT,
                     static_cast<int64_t>(_population.handle_for_slot(destination)),
                     cmd.signature, cmd.cell, cmd.population, 0, cmd.cell, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    if (cmd.source_slot < 0 || cmd.source_slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[cmd.source_slot] == 0) {
        // A prior command may have consumed/released the same source. Stable
        // sequence semantics make the remaining command a deterministic no-op.
        return true;
    }
    const int32_t source = cmd.source_slot;
    const int32_t source_cell = _population.page_cell[source / PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    if (cmd.opcode == STRUCTURAL_REMOVE_EMPTY) {
        const int64_t estate_funds = _population.funds[source];
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : _country_runtime->country_handle_for_cell(source_cell);
        const int64_t treasury_before = _country_runtime == nullptr ? 0
            : _country_runtime->total_cash();
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(source_cell)) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                            estate_funds, 0});
            legs.push_back({FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                            treasury_before, treasury_before});
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, estate_funds, _saturation_count);
        const int64_t moved = _country_runtime == nullptr ? 0
            : _country_runtime->transfer_cash_from_cohort(country_handle, estate_funds);
        if (moved != estate_funds) {
            error = "country_treasury_estate_transfer_failed";
            return false;
        }
        // A demography command can drain a cohort after the employment stage.
        // Remove its stale lane counts before releasing the slot; the committed
        // reconciliation pass below then clips the corresponding group fills.
        _filled_owner_jobs = saturating_sub(_filled_owner_jobs,
            std::max<int64_t>(0, _population.owner_employed[source]), _saturation_count);
        _filled_employee_jobs = saturating_sub(_filled_employee_jobs,
            std::max<int64_t>(0, _population.employee_employed[source]), _saturation_count);
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
        _structural_touched_cells.push_back(source_cell);
        if (legs.size() > 1) legs[1].after = _country_runtime->total_cash();
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                     SUBJECT_COHORT, source_handle, 0, -1,
                     0, estate_funds, source_cell, -1,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    if (cmd.cell < 0 || cmd.cell >= _cell_count || cmd.signature < 0 ||
        cmd.signature >= static_cast<int32_t>(_signatures.size())) {
        error = "structural_target_invalid";
        return false;
    }
    if (!profession_available(cmd.cell, _signatures[cmd.signature].profession_id, true)) {
        ++_rejected_commands;
        return true;
    }
    if (cmd.cell == source_cell &&
        cmd.signature == static_cast<int32_t>(_population.signature_id[source])) return true;
    return move_cohort_population(source, cmd.cell, cmd.signature, cmd.population, error);
}

bool NativeEconomyRuntime::move_cohort_population(int32_t source, int32_t dest_cell,
                                                  int32_t dest_signature,
                                                  int64_t requested_pop,
                                                  std::string &error,
                                                  bool *source_drained_out) {
    if (source_drained_out != nullptr) *source_drained_out = false;
    const int32_t source_cell = _population.page_cell[source / PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    const int32_t cmd_cell = dest_cell;
    const int32_t cmd_signature = dest_signature;
    const int64_t source_pop = std::max<int64_t>(0, _population.population[source]);
    const int64_t move_pop = std::min(std::max<int64_t>(0, requested_pop), source_pop);
    if (move_pop == 0) return true;
    _structural_touched_cells.push_back(source_cell);
    _structural_touched_cells.push_back(cmd_cell);
    const int64_t move_funds = move_pop == source_pop
                                   ? _population.funds[source]
                                   : mul_div_sat(_population.funds[source], move_pop, source_pop,
                                                 _saturation_count);
    const int64_t move_income = move_pop == source_pop
                                    ? _population.epoch_income[source]
                                    : mul_div_sat(_population.epoch_income[source], move_pop, source_pop,
                                                  _saturation_count);
    const int64_t move_expense = move_pop == source_pop
                                     ? _population.epoch_expense[source]
                                     : mul_div_sat(_population.epoch_expense[source], move_pop, source_pop,
                                                   _saturation_count);
    const int64_t move_in_kind = move_pop == source_pop
                                     ? _population.epoch_in_kind_income[source]
                                     : mul_div_sat(_population.epoch_in_kind_income[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_ema = move_pop == source_pop
                                 ? _population.income_ema[source]
                                 : mul_div_sat(_population.income_ema[source], move_pop, source_pop,
                                               _saturation_count);
    const int64_t move_residual = move_pop == source_pop
                                      ? _population.demography_residual[source]
                                      : mul_div_sat(_population.demography_residual[source], move_pop,
                                                    source_pop, _saturation_count);
    const uint16_t move_satisfaction = _population.needs_satisfaction[source];

    const int64_t source_population_before = _population.population[source];
    const int64_t source_funds_before = _population.funds[source];
    const int64_t source_income_before = _population.epoch_income[source];
    const int64_t source_expense_before = _population.epoch_expense[source];
    const int64_t source_ema_before = _population.income_ema[source];
    const int64_t source_residual_before = _population.demography_residual[source];

    const int32_t destination = _population.allocate_slot(cmd_cell, static_cast<uint32_t>(cmd_signature));
    if (destination < 0) {
        error = "structural_destination_allocation_failed";
        return false;
    }
    const int64_t destination_pop_before = _population.population[destination];
    const int64_t destination_funds_before = _population.funds[destination];
    const int64_t destination_income_before = _population.epoch_income[destination];
    const int64_t destination_expense_before = _population.epoch_expense[destination];
    const int64_t destination_ema_before = _population.income_ema[destination];
    const int64_t destination_residual_before = _population.demography_residual[destination];
    touch_accounting_slot(destination);
    const int64_t destination_handle = static_cast<int64_t>(
        _population.handle_for_slot(destination));
    _population.population[destination] = saturating_add(destination_pop_before, move_pop,
                                                         _saturation_count);
    _population.funds[destination] = saturating_add(_population.funds[destination], move_funds,
                                                    _saturation_count);
    _population.epoch_income[destination] = saturating_add(
        _population.epoch_income[destination], move_income, _saturation_count);
    _population.epoch_expense[destination] = saturating_add(
        _population.epoch_expense[destination], move_expense, _saturation_count);
    _population.epoch_in_kind_income[destination] = saturating_add(
        _population.epoch_in_kind_income[destination], move_in_kind, _saturation_count);
    _population.income_ema[destination] = saturating_add(_population.income_ema[destination],
                                                         move_ema, _saturation_count);
    _population.demography_residual[destination] = saturating_add(
        _population.demography_residual[destination], move_residual, _saturation_count);
    const int64_t satisfaction_weighted = saturating_add(
        mul_div_sat(_population.needs_satisfaction[destination], destination_pop_before, 1,
                    _saturation_count),
        mul_div_sat(move_satisfaction, move_pop, 1, _saturation_count), _saturation_count);
    _population.needs_satisfaction[destination] = static_cast<uint16_t>(
        _population.population[destination] > 0
            ? std::clamp<int64_t>(satisfaction_weighted / _population.population[destination],
                                  0, Q16_ONE - 1)
            : Q16_ONE - 1);

    _population.population[source] -= move_pop;
    _population.funds[source] -= move_funds;
    _population.epoch_income[source] -= move_income;
    _population.epoch_expense[source] -= move_expense;
    _population.epoch_in_kind_income[source] -= move_in_kind;
    _population.income_ema[source] -= move_ema;
    _population.demography_residual[source] -= move_residual;
    if (_population.population[source] == 0) {
        // Any rounding residue is money, not an implicit burn.
        const int64_t residue_funds = _population.funds[source];
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, residue_funds, _saturation_count);
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : _country_runtime->country_handle_for_cell(source_cell);
        const int64_t moved = _country_runtime == nullptr ? 0
            : _country_runtime->transfer_cash_from_cohort(country_handle, residue_funds);
        if (moved != residue_funds) {
            error = "country_treasury_residue_transfer_failed";
            return false;
        }
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
        if (source_drained_out != nullptr) *source_drained_out = true;
    }
    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(source_cell) || trace_detail_for_cell(cmd_cell)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                        source_population_before, source_population_before - move_pop});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                        source_funds_before, source_funds_before - move_funds});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, source_handle, -1,
                        source_income_before, source_income_before - move_income});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, source_handle, -1,
                        source_expense_before, source_expense_before - move_expense});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, source_handle, -1,
                        source_ema_before, source_ema_before - move_ema});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        source_handle, -1, source_residual_before,
                        source_residual_before - move_residual});
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, destination_handle, -1,
                        destination_pop_before, _population.population[destination]});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, destination_handle, -1,
                        destination_funds_before, _population.funds[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, destination_handle, -1,
                        destination_income_before, _population.epoch_income[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, destination_handle, -1,
                        destination_expense_before, _population.epoch_expense[destination]});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, destination_handle, -1,
                        destination_ema_before, _population.income_ema[destination]});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        destination_handle, -1, destination_residual_before,
                        _population.demography_residual[destination]});
    }
    trace_append(EVENT_STRUCTURAL_CHANGE,
                 static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                 SUBJECT_COHORT, source_handle, cmd_signature, cmd_cell,
                 move_pop, move_funds, source_cell, cmd_cell,
                 legs.empty() ? nullptr : &legs);
    return true;
}

NativeEconomyRuntime::AuditTotals NativeEconomyRuntime::audit_totals() const {
    AuditTotals totals;
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        if (_population.active[slot] == 0) continue;
        totals.population += _population.population[slot];
        totals.cohort_funds += _population.funds[slot];
    }
    totals.country_cash = _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
    totals.goods_stock = std::accumulate(_market.stock.begin(), _market.stock.end(), int64_t{0});
    totals.transit_goods = trade_transit_goods();
    totals.escrow_cash = trade_escrow_cash();
    totals.goods_stock += totals.transit_goods;
    if (_country_runtime != nullptr) {
        for (int32_t good = 0; good < _market.good_count; ++good)
            totals.goods_stock += _country_runtime->total_good(good);
    }
    return totals;
}

void NativeEconomyRuntime::rebuild_committed_summaries() {
    _committed_cells.assign(_cell_count, {});
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _committed_cells[cell] = build_cell_summary(cell);
    }
}

NativeEconomyRuntime::CellSummary NativeEconomyRuntime::build_cell_summary(int32_t cell) const {
    CellSummary summary;
    int64_t satisfaction_weighted = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        ++summary.cohort_count;
        summary.population += _population.population[slot];
        summary.funds += _population.funds[slot];
        summary.epoch_income += _population.epoch_income[slot];
        summary.epoch_expense += _population.epoch_expense[slot];
        satisfaction_weighted += static_cast<int64_t>(_population.needs_satisfaction[slot]) *
                                 _population.population[slot];
    });
    summary.satisfaction_q16 = summary.population > 0
                                   ? static_cast<int32_t>(std::clamp<int64_t>(
                                         satisfaction_weighted / summary.population, 0, Q16_ONE - 1))
                                   : static_cast<int32_t>(Q16_ONE - 1);
    return summary;
}

void NativeEconomyRuntime::finalize_market_result(int32_t market, MarketResult &result) {
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        const CellSummary summary = build_cell_summary(cell);
        _staging_cells[cell] = summary;
        result.closing_population = saturating_add(result.closing_population, summary.population,
                                                   result.saturation_count);
        result.closing_cohort_funds = saturating_add(result.closing_cohort_funds, summary.funds,
                                                     result.saturation_count);
    }
    for (int32_t good = 0; good < _market.good_count; ++good) {
        result.closing_goods_stock = saturating_add(
            result.closing_goods_stock, _market.stock[_market.index(market, good)],
            result.saturation_count);
    }
}

bool NativeEconomyRuntime::rebuild_market_cell_ranges(std::string &error) {
    if (_market.market_count <= 0 ||
        _market.cell_to_market.size() != static_cast<size_t>(_cell_count)) {
        error = "market_cell_mapping_shape_invalid";
        return false;
    }
    _market_cell_offsets.assign(_market.market_count + 1, 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t market = _market.cell_to_market[cell];
        if (market < 0 || market >= _market.market_count) {
            error = "cell_to_market_entry_invalid";
            return false;
        }
        ++_market_cell_offsets[market + 1];
    }
    for (int32_t market = 0; market < _market.market_count; ++market) {
        _market_cell_offsets[market + 1] += _market_cell_offsets[market];
    }
    _market_cells.assign(_cell_count, -1);
    std::vector<int32_t> cursor(_market_cell_offsets.begin(), _market_cell_offsets.end() - 1);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t market = _market.cell_to_market[cell];
        _market_cells[cursor[market]++] = cell;
    }
    return true;
}

bool NativeEconomyRuntime::publish_epoch(std::string &error) {
    const auto start = Clock::now();
    std::sort(_structural_touched_cells.begin(), _structural_touched_cells.end());
    _structural_touched_cells.erase(
        std::unique(_structural_touched_cells.begin(), _structural_touched_cells.end()),
        _structural_touched_cells.end());
    int64_t merchant_repairs = 0;
    for (int32_t cell : _structural_touched_cells) {
        if (!ensure_merchant_invariant(cell, merchant_repairs, error)) return false;
        int64_t population = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            population = saturating_add(population, _population.population[slot],
                                        _saturation_count);
        });
        if (population == 0) {
            const int32_t market = _market.cell_to_market[cell];
            for (int32_t good = 0; good < _market.good_count; ++good) {
                if (_market.stock[_market.index(market, good)] > 0) {
                    error = "empty_cell_cannot_retain_owned_stock";
                    return false;
                }
            }
        }
    }
    _merchant_repairs = saturating_add(_merchant_repairs, merchant_repairs,
                                       _saturation_count);
    if (!_structural_touched_cells.empty() && !rebuild_merchant_ranges(error)) return false;
    for (int32_t cell : _structural_touched_cells) {
        if (cell >= 0 && cell < _cell_count) _staging_cells[cell] = build_cell_summary(cell);
    }
    // During the v15 migration the authoritative audit is recomputed after the
    // due-cell transaction. This keeps daily trade/treasury legs exact while
    // the incremental aggregate cache is validated against production worlds.
    const auto audit_started = Clock::now();
    _closing_totals = audit_totals();
    _audit_ms += elapsed_ms(audit_started);
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds +
        _opening_totals.country_cash + _opening_totals.escrow_cash;
    const int64_t money_close = _closing_totals.cohort_funds +
        _closing_totals.country_cash + _closing_totals.escrow_cash;
    const int64_t money_expected = money_open + _explicit_money_mint - _explicit_money_burn;
    const int64_t goods_expected = _opening_totals.goods_stock + _explicit_stock_delta +
                                   _production_output_stock + _production_output_retained -
                                   _consumed_goods - _owner_output_consumed -
								   _construction_goods_consumed - _production_inputs_consumed -
								   _cycle_flow_discarded - _bullion_stock_consumed;
    if (_closing_totals.population != population_expected) {
        error = "population_conservation_failed";
        return false;
    }
    if (money_close != money_expected) {
        error = "money_conservation_failed";
        return false;
    }
    if (_closing_totals.goods_stock != goods_expected) {
        error = "goods_conservation_failed";
        return false;
    }
    _committed_cells.swap(_staging_cells);
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        _cell_last_settlement_day[cell] = _sample_day;
        ++_cell_settlement_generation[cell];
        ++_cell_price_stock_gen[cell];
        ++_cell_owner_cash_gen[cell];
        ++_cell_population_gen[cell];
        ++_cell_resource_gen[cell];
    }
    _rolling_processed_cells = static_cast<int32_t>(_epoch_settlement_cells.size());
    _rolling_deferred_cells = std::max(0, _rolling_due_cells - _rolling_processed_cells);
    const auto watermark_started = Clock::now();
    _settlement_watermark = _sample_day;
    _settlement_newest_day = _sample_day;
    bool have_populated = false;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_committed_cells[cell].population <= 0) continue;
        if (!have_populated) {
            _settlement_watermark = _cell_last_settlement_day[cell];
            _settlement_newest_day = _cell_last_settlement_day[cell];
            have_populated = true;
        } else {
            _settlement_watermark = std::min(
                _settlement_watermark, _cell_last_settlement_day[cell]);
            _settlement_newest_day = std::max(
                _settlement_newest_day, _cell_last_settlement_day[cell]);
        }
    }
    _settlement_max_age_days = have_populated
        ? std::max<int64_t>(0, _sample_day - _settlement_watermark) : 0;
    _watermark_ms += elapsed_ms(watermark_started);
    _last_committed_day = _sample_day;
    _commit_day = _current_day;
    _epoch_active = false;
    _resource_deltas_ready = std::any_of(_resource_deltas.begin(), _resource_deltas.end(),
                                         [](int64_t value) { return value != 0; });
    _epoch_commands.clear();
    _structural_commands.clear();
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    update_trade_flow_ema();
    refresh_trade_response_diagnostics();
    if (_trade_runtime_mode != 0 && _trade_topology.ready &&
        (_trade_plan.phase == TradePlanStore::IDLE ||
         _trade_plan.country_topology_hash != _epoch_country_topology_hash ||
         _trade_plan.topology_generation != _trade_topology.topology_generation)) {
        if (!begin_trade_plan(error)) return false;
    }
    _stage = _trade_plan.phase == TradePlanStore::IDLE
        ? Stage::AGGREGATE_PUBLISH : Stage::TRADE_PLANNING;
    trace_commit_epoch(0, 0, 0);
    _publish_ms += elapsed_ms(start);
    return true;
}

void NativeEconomyRuntime::fail(const std::string &reason) {
    trace_abort_epoch();
    _fatal = true;
    _fatal_reason = reason;
    _epoch_active = false;
    _stage = Stage::FATAL;
}

Dictionary NativeEconomyRuntime::run_slice(const Dictionary &ctx) {
    const auto slice_start = Clock::now();
    // Report planner wall time for this native slice only. The planner can run
    // before start_epoch(), so epoch metric resets cannot own this counter.
    _trade_plan_ms = 0.0;
    Dictionary out;
    const int64_t day_index = dict_num<int64_t>(ctx, "day_index", _current_day < 0 ? 0 : _current_day);
    _current_day = std::max(_current_day, day_index);
    int64_t work_done = 0;
    int32_t cursor_start = 0;
    int32_t cursor_end = 0;
    std::string error;
    if (!_bootstrapped || _fatal) {
        out = report();
        out["done"] = true;
        out["work_done"] = 0;
        out["elapsed_ms"] = elapsed_ms(slice_start);
        return out;
    }
    if (!_epoch_active) {
        if (!should_run(day_index)) {
            out = report();
            out["done"] = true;
            out["work_done"] = 0;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        const bool cycle_due = day_index > _last_committed_day;
        if (cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) {
                fail(error);
                out = report();
                out["done"] = true;
                out["work_done"] = work_done;
                out["elapsed_ms"] = elapsed_ms(slice_start);
                return out;
            }
            // Advance one bounded planner slice every day, then settle the due
            // phase in the same native call. Planning never delays local cadence.
            _stage = Stage::EPOCH_BEGIN;
        }
        if (!cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) fail(error);
            if (!_fatal && _trade_plan.phase == TradePlanStore::IDLE)
                _stage = Stage::IDLE;
            out = report();
            out["done"] = true;
            out["work_done"] = work_done;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        _stage = Stage::EPOCH_BEGIN;
        if (!start_epoch(day_index, error)) {
            fail(error);
            out = report();
            out["done"] = true;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
    }
    ++_continuation_slices;

    // Continue through cheap stage boundaries in one call. A call performs at
    // most one command, building, cell, and structural range.
    bool command_range_used = false;
    bool cell_range_used = false;
    bool structural_range_used = false;
    bool building_range_used = false;
    while (_epoch_active && !_fatal) {
        if (_stage == Stage::BUILDING_PLAN) {
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = building_slice_end(_building_cell_cursor);
            if (_building_plan_phase == 0) {
                if (!prepare_building_economic_plan(
                        _building_cell_cursor, end, error)) {
                    fail(error.empty() ? "building_plan_failed" : error);
                }
            } else {
                rebuild_production_input_reserves(
                    _building_cell_cursor, end, false);
            }
            if (!_fatal) {
                work_done += end - _building_cell_cursor;
                _building_cell_cursor = end;
            }
            cursor_end = _building_cell_cursor;
            _building_plan_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal || _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size())) break;
            _building_cell_cursor = 0;
            if (_building_plan_phase == 0) {
                _building_plan_phase = 1;
            } else {
                _building_plan_phase = 0;
                _stage = Stage::TRADE_SETTLE;
            }
            break;
        }
        if (_stage == Stage::TRADE_SETTLE) {
            if (!settle_due_trade_orders(error)) {
                fail(error);
                break;
            }
            _stage = Stage::LEDGER_APPLY;
            continue;
        }
        if (_stage == Stage::LEDGER_APPLY) {
            const auto start = Clock::now();
            cursor_start = _command_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_epoch_commands.size()),
                                                  _command_cursor + _commands_per_slice);
            for (; _command_cursor < end; ++_command_cursor) {
                if (!apply_command(_epoch_commands[_command_cursor], error)) {
                    fail(error);
                    break;
                }
                ++_processed_commands;
                ++work_done;
            }
            cursor_end = _command_cursor;
            _ledger_ms += elapsed_ms(start);
            command_range_used = true;
            if (_fatal || _command_cursor < static_cast<int32_t>(_epoch_commands.size())) break;
            _stage = _buildings.empty()
                ? Stage::HOUSEHOLD_MARKET : Stage::BUILDING_EMPLOYMENT;
            if (cell_range_used) break;
            continue;
        }
        if (_stage == Stage::TRADE_DISPATCH) {
            if (!dispatch_trade_candidates(error)) {
                fail(error);
                break;
            }
            _stage = Stage::STRUCTURAL_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_EMPLOYMENT) {
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = building_slice_end(_building_cell_cursor);
            for (; _building_cell_cursor < end; ++_building_cell_cursor) {
                if (!run_building_employment_cell(
                        _epoch_building_cells[_building_cell_cursor], true, error)) {
                    fail(error.empty() ? "building_employment_failed" : error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _building_cell_cursor;
            _employment_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal || _building_cell_cursor < static_cast<int32_t>(_epoch_building_cells.size())) break;
            _building_cell_cursor = 0;
            prepare_due_demand_basis_cache();
            _stage = Stage::BUILDING_PRODUCTION;
            break;
        }
        if (_stage == Stage::BUILDING_PRODUCTION) {
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = building_slice_end(_building_cell_cursor);
            const int32_t cell_count = end - _building_cell_cursor;
            _building_funded_capacity_q16.resize(_buildings.size(), 0);
            _building_working_capital_allocated.resize(_buildings.size(), 0);
            std::vector<ProductionResult> results(static_cast<size_t>(cell_count));
            int64_t estimated_groups = 0;
            bool disjoint_markets = true;
            for (int32_t relative = 0; relative < cell_count; ++relative) {
                const int32_t cell = _epoch_building_cells[
                    _building_cell_cursor + relative];
                estimated_groups += _building_cell_offsets[cell + 1] -
                    _building_cell_offsets[cell];
                disjoint_markets = disjoint_markets &&
                    _market.cell_to_market[cell] == cell;
            }
            const int32_t production_default_tasks = static_cast<int32_t>(
                std::clamp<int64_t>((estimated_groups + 127) / 128, 2, 16));
            _production_worker_tasks = _worker_enabled && disjoint_markets &&
                    cell_count >= _worker_market_threshold &&
                    estimated_groups >= _worker_market_threshold &&
                    godot::WorkerThreadPool::get_singleton() != nullptr
                ? std::min(cell_count, _worker_tasks_hint > 0
                    ? _worker_tasks_hint : production_default_tasks)
                : 1;
            auto run_cells = [&](int32_t range_begin, int32_t range_end) {
                for (int32_t relative = range_begin; relative < range_end; ++relative) {
                    ProductionResult &result = results[relative];
                    std::string production_error;
                    result.ok = run_building_production_cell(
                        _epoch_building_cells[_building_cell_cursor + relative],
                        result, production_error);
                    result.error = std::move(production_error);
                }
            };
            if (_production_worker_tasks > 1) {
                parallel_for_range("pk_economy_building_production", cell_count,
                                   _production_worker_tasks,
                                   _worker_market_threshold, run_cells);
            } else {
                run_cells(0, cell_count);
            }
            const auto merge_started = Clock::now();
            for (int32_t relative = 0; relative < cell_count; ++relative) {
                ProductionResult &result = results[relative];
                merge_building_production_result(result);
                if (!result.ok && !_fatal) {
                    fail(result.error.empty() ? "building_production_failed"
                                               : result.error);
                }
                if (result.ok) ++work_done;
            }
            _production_merge_ms += elapsed_ms(merge_started);
            if (!_fatal) _building_cell_cursor = end;
            cursor_end = _building_cell_cursor;
            _production_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal || _building_cell_cursor < static_cast<int32_t>(_epoch_building_cells.size())) break;
            _building_cell_cursor = 0;
            std::stable_sort(_owner_retained_outputs.begin(), _owner_retained_outputs.end(),
                [](const OwnerRetainedOutput &a, const OwnerRetainedOutput &b) {
                    if (a.owner_slot != b.owner_slot) return a.owner_slot < b.owner_slot;
                    if (a.good_id != b.good_id) return a.good_id < b.good_id;
                    return a.building_group < b.building_group;
                });
            size_t retained_write = 0;
            for (const OwnerRetainedOutput &entry : _owner_retained_outputs) {
                if (entry.quantity <= 0) continue;
                if (retained_write > 0 &&
                    _owner_retained_outputs[retained_write - 1].owner_slot == entry.owner_slot &&
                    _owner_retained_outputs[retained_write - 1].good_id == entry.good_id &&
                    _owner_retained_outputs[retained_write - 1].building_group ==
                        entry.building_group) {
                    _owner_retained_outputs[retained_write - 1].quantity = saturating_add(
                        _owner_retained_outputs[retained_write - 1].quantity,
                        entry.quantity, _saturation_count);
                } else {
                    _owner_retained_outputs[retained_write++] = entry;
                }
            }
            _owner_retained_outputs.resize(retained_write);
            _stage = Stage::HOUSEHOLD_MARKET;
            break;
        }
        if (_stage == Stage::HOUSEHOLD_MARKET) {
            cursor_start = _cell_cursor;
            const int32_t begin = _cell_cursor;
            int32_t end = begin;
            int64_t slice_cohorts = 0;
            if (_auto_slice_by_scale) {
                // Cohort count, not cell count, is the dominant cost. Stop at
                // a deterministic cohort budget so unevenly populated cells do
                // not create an accidental long slice.
                while (end < static_cast<int32_t>(_epoch_market_ids.size()) &&
                       end - begin < _cells_per_slice &&
                       (end == begin || slice_cohorts < _target_cohorts_per_slice)) {
                    const int32_t market = _epoch_market_ids[end];
                    for (int32_t k = _market_cell_offsets[market];
                         k < _market_cell_offsets[market + 1]; ++k) {
                        slice_cohorts += _committed_cells[_market_cells[k]].cohort_count;
                    }
                    ++end;
                }
            } else {
                end = std::min<int32_t>(static_cast<int32_t>(_epoch_market_ids.size()),
                                        begin + _cells_per_slice);
            }
            const int32_t market_count = end - begin;
            std::vector<MarketResult> results(static_cast<size_t>(market_count));
            int64_t estimated_cohorts = 0;
            for (int32_t relative_market = begin; relative_market < end; ++relative_market) {
                const int32_t market = _epoch_market_ids[relative_market];
                for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
                    estimated_cohorts += _committed_cells[_market_cells[k]].cohort_count;
                }
            }
            const int64_t parallel_work = std::max<int64_t>(market_count, estimated_cohorts);
            const int32_t economy_default_tasks = static_cast<int32_t>(
                std::clamp<int64_t>((parallel_work + 127) / 128, 2, 16));
            _worker_tasks = _worker_enabled && market_count >= _worker_market_threshold &&
                                    parallel_work >= _worker_market_threshold &&
                                    godot::WorkerThreadPool::get_singleton() != nullptr
                                ? std::min(market_count,
                                           _worker_tasks_hint > 0 ? _worker_tasks_hint
                                                                  : economy_default_tasks)
                                : 1;
            auto run_markets = [&](int32_t range_begin, int32_t range_end) {
                for (int32_t relative = range_begin; relative < range_end; ++relative) {
                    MarketResult &market_result = results[relative];
                    std::string market_error;
                    market_result.ok = process_market_cell(
                        _epoch_market_ids[begin + relative], market_result, market_error);
                    market_result.error = std::move(market_error);
                }
            };
            if (_worker_tasks > 1) {
                parallel_for_range("pk_economy_markets", market_count, _worker_tasks,
                                   _worker_market_threshold, run_markets);
            } else {
                run_markets(0, market_count);
            }
            for (int32_t relative = 0; relative < market_count; ++relative) {
                const int32_t market = _epoch_market_ids[begin + relative];
                MarketResult &market_result = results[relative];
                if (!market_result.ok) {
                    fail(market_result.error.empty() ? "household_market_internal_failure"
                                                     : market_result.error);
                    break;
                }
                _processed_cells += _market_cell_offsets[market + 1] -
                                    _market_cell_offsets[market];
                _processed_cohorts = saturating_add(_processed_cohorts,
                                                    market_result.processed_cohorts,
                                                    _saturation_count);
                _processed_rules = saturating_add(_processed_rules,
                                                  market_result.processed_rules,
                                                  _saturation_count);
                _saturation_count = saturating_add(_saturation_count,
                                                   market_result.saturation_count,
                                                   _saturation_count);
                _consumed_goods = saturating_add(_consumed_goods, market_result.consumed_goods,
                                                 _saturation_count);
                _production_output_retained = saturating_add(
                    _production_output_retained, market_result.retained_output_consumed,
                    _saturation_count);
                _owner_output_consumed = saturating_add(
                    _owner_output_consumed, market_result.retained_output_consumed,
                    _saturation_count);
                _production_output_discarded = saturating_add(
                    _production_output_discarded, market_result.retained_output_discarded,
                    _saturation_count);
                _owner_working_capital_reserved = saturating_add(
                    _owner_working_capital_reserved,
                    market_result.owner_working_capital_reserved, _saturation_count);
                for (const BuildingInKindCredit &credit :
                        market_result.building_in_kind_credits) {
                    if (credit.building_group < 0 || credit.building_group >=
                            static_cast<int32_t>(_building_owner_livelihood_credit.size()))
                        continue;
                    _building_owner_livelihood_credit[credit.building_group] = saturating_add(
                        _building_owner_livelihood_credit[credit.building_group],
                        credit.frozen_value, _saturation_count);
                }
                _births = saturating_add(_births, market_result.births, _saturation_count);
                _deaths = saturating_add(_deaths, market_result.deaths, _saturation_count);
                _population_changed_cells.insert(_population_changed_cells.end(),
                    market_result.population_changed_cells.begin(),
                    market_result.population_changed_cells.end());
                _publish_accum.population = saturating_add(
                    _publish_accum.population, market_result.closing_population, _saturation_count);
                _publish_accum.cohort_funds = saturating_add(
                    _publish_accum.cohort_funds, market_result.closing_cohort_funds,
                    _saturation_count);
                _publish_accum.goods_stock = saturating_add(
                    _publish_accum.goods_stock, market_result.closing_goods_stock,
                    _saturation_count);
                _formula_ms += market_result.formula_ms;
                _clear_ms += market_result.clear_ms;
                _processed_needs = saturating_add(_processed_needs, market_result.processed_needs,
                                                  _saturation_count);
                _processed_variants = saturating_add(_processed_variants,
                                                     market_result.processed_variants,
                                                     _saturation_count);
                _processed_components = saturating_add(_processed_components,
                                                       market_result.processed_components,
                                                       _saturation_count);
                _fallback_ms += market_result.fallback_ms;
                _merchant_settle_ms += market_result.merchant_settle_ms;
                _price_ms += market_result.price_ms;
                _merchant_repairs = saturating_add(_merchant_repairs,
                                                   market_result.merchant_repairs,
                                                   _saturation_count);
                _price_cap_hits = saturating_add(_price_cap_hits,
                                                 market_result.price_cap_hits,
                                                 _saturation_count);
                _price_cost_anchor_hits = saturating_add(
                    _price_cost_anchor_hits, market_result.price_cost_anchor_hits,
                    _saturation_count);
                _price_inactive_reversions = saturating_add(
                    _price_inactive_reversions, market_result.price_inactive_reversions,
                    _saturation_count);
                _structural_commands.insert(_structural_commands.end(),
                                             market_result.structural_commands.begin(),
                                             market_result.structural_commands.end());
                for (const int32_t good : market_result.trade_active_goods) {
                    _trade_active_keys.push_back(
                        (static_cast<uint64_t>(static_cast<uint32_t>(market)) << 32) |
                        static_cast<uint32_t>(good));
                    const int32_t signal_clock = ensure_trade_signal_clock_index(market, good);
                    if (signal_clock < 0 || signal_clock >= static_cast<int32_t>(
                            _trade_signal_first_seen_day.size())) continue;
                    int64_t signal_sat = 0;
                    const int64_t target = trade_local_stock_target(
                        market, good, signal_sat);
                    const int64_t stock = _market.stock[_market.index(market, good)];
                    const bool needs_trade = target > stock ||
                        trade_relief_pressure_q16(market, good, signal_sat) > 0;
                    _saturation_count = saturating_add(
                        _saturation_count, signal_sat, _saturation_count);
                    if (needs_trade) {
                        if (_trade_signal_first_seen_day[signal_clock] < 0) {
                            _trade_signal_first_seen_day[signal_clock] = _sample_day;
                            _trade_signal_first_dispatch_day[signal_clock] = -1;
                            _trade_signal_last_attempt_day[signal_clock] = -1;
                            _trade_signal_last_rejection_reason[signal_clock] =
                                TRADE_SIGNAL_DIAG_NONE;
                            _trade_signal_deadline_reported[signal_clock] = 0;
                        }
                    } else {
                        _trade_signal_first_seen_day[signal_clock] = -1;
                        _trade_signal_first_dispatch_day[signal_clock] = -1;
                        _trade_signal_deadline_reported[signal_clock] = 0;
                    }
                }
                ++work_done;
            }
            if (!_fatal && _trace_mode != TRACE_OFF) {
                const auto event_start = Clock::now();
                for (int32_t relative = 0; relative < market_count; ++relative) {
                    const int32_t market = _epoch_market_ids[begin + relative];
                    MarketResult &market_result = results[relative];
                    if (market == _staging_events.cashflow_cell) {
                        for (const CashflowEntry &entry : market_result.cashflows) {
                            trace_record_cashflow(market, entry.cohort_handle,
                                entry.source, entry.income, entry.expense);
                        }
                    }
                    trace_append(EVENT_MARKET_SETTLED,
                                 static_cast<int32_t>(Stage::HOUSEHOLD_MARKET), market,
                                 SUBJECT_MARKET, market, -1, -1,
                                 market_result.revenue, market_result.consumed_goods,
                                 market_result.changed_prices,
                                 static_cast<int64_t>(market_result.mutation_hash),
                                 market_result.trace_legs.empty() ? nullptr :
                                     &market_result.trace_legs);
                }
                _event_summary_ms += elapsed_ms(event_start);
            }
            _cell_cursor = end;
            cursor_end = _cell_cursor;
            cell_range_used = true;
            if (_fatal || _cell_cursor < static_cast<int32_t>(_epoch_market_ids.size()))
                break;
            // Owner-retained goods settle through household needs and therefore
            // have no cash leg. Their frozen retail value offsets only the
            // owner's livelihood charge in realized profitability.
            for (const int32_t cell : _epoch_building_cells) {
                if (cell < 0 || cell >= _cell_count ||
                    _building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
                    continue;
                for (int32_t g = _building_cell_offsets[cell];
                     g < _building_cell_offsets[cell + 1]; ++g) {
                    BuildingGroup &group = _buildings[g];
                    const int64_t livelihood = saturating_mul(saturating_mul(
                        living_cost_for_signature(cell, group.owner_signature_id, -1,
                                                  _saturation_count),
                        std::max<int64_t>(0, group.filled_owner), _saturation_count),
                        std::max(1, _epoch_days), _saturation_count);
                    const int64_t credit = g < static_cast<int32_t>(
                            _building_owner_livelihood_credit.size())
                        ? std::min<int64_t>(livelihood,
                            _building_owner_livelihood_credit[g]) : 0;
                    const int64_t realized_cost = saturating_add(saturating_add(
                        group.last_input_cost, group.last_base_wages_due,
                        _saturation_count), livelihood - credit, _saturation_count);
                    const int64_t margin = realized_cost <= 0
                        ? (group.last_revenue > 0 ? Q16_ONE : 0)
                        : mul_div_sat(saturating_sub(
                            group.last_revenue, realized_cost, _saturation_count),
                            Q16_ONE, std::max<int64_t>(MONEY_SCALE, realized_cost),
                            _saturation_count);
                    group.realized_profit_margin_q16 = static_cast<int32_t>(
                        std::clamp<int64_t>(margin, -Q16_ONE, Q16_ONE));
                }
            }
            for (const int32_t cell : _epoch_settlement_cells) {
                const int32_t market = _market.cell_to_market[cell];
                for (int32_t signal = _market_signals.cell_offsets[cell];
                     signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
                    if (signal >= static_cast<int32_t>(
                            _production_input_reserve.size())) continue;
                    const int32_t good = _market_signals.good_ids[signal];
                    _production_input_reserve_shortfall = saturating_add(
                        _production_input_reserve_shortfall, std::max<int64_t>(0,
                            _production_input_reserve[signal] -
                                _market.stock[_market.index(market, good)]),
                        _saturation_count);
                }
            }
            std::stable_sort(_structural_commands.begin(), _structural_commands.end(),
                             [](const StructuralCommand &a, const StructuralCommand &b) {
                if (a.cell != b.cell) return a.cell < b.cell;
                const int32_t a_phase = a.opcode == STRUCTURAL_BIRTH ? 1 : 0;
                const int32_t b_phase = b.opcode == STRUCTURAL_BIRTH ? 1 : 0;
                if (a_phase != b_phase) return a_phase < b_phase;
                if (a.signature != b.signature) return a.signature < b.signature;
                if (a.sequence != b.sequence) return a.sequence < b.sequence;
                return a.source_slot < b.source_slot;
            });
            // Export only after every local household has settled. Keep this as
            // a separate continuation slice so route/candidate arbitration does
            // not extend the already expensive household-market slice.
            _stage = Stage::TRADE_DISPATCH;
            break;
        }
        if (_stage == Stage::STRUCTURAL_COMMIT) {
            const auto start = Clock::now();
            cursor_start = _structural_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_structural_commands.size()),
                                                  _structural_cursor + _commands_per_slice);
            for (; _structural_cursor < end; ++_structural_cursor) {
                if (!commit_structural(_structural_commands[_structural_cursor], error)) {
                    fail(error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _structural_cursor;
            _structure_ms += elapsed_ms(start);
            structural_range_used = true;
            if (_fatal || _structural_cursor < static_cast<int32_t>(_structural_commands.size()))
                break;
            int64_t merchant_repairs = 0;
            for (const int32_t cell : _structural_touched_cells) {
                if (!ensure_merchant_invariant(cell, merchant_repairs, error)) {
                    fail(error.empty() ? "merchant_repair_after_structure_failed" : error);
                    break;
                }
            }
            if (_fatal) break;
            _merchant_repairs = saturating_add(
                _merchant_repairs, merchant_repairs, _saturation_count);
            if (!_structural_touched_cells.empty() && !rebuild_merchant_ranges(error)) {
                fail(error.empty() ? "merchant_range_rebuild_after_structure_failed" : error);
                break;
            }
            _population_changed_cells.insert(_population_changed_cells.end(),
                _structural_touched_cells.begin(), _structural_touched_cells.end());
            if (!_population_changed_cells.empty() &&
                !reconcile_building_employment_after_population_change(
                    _population_changed_cells, error)) {
                fail(error.empty() ? "building_employment_reconcile_failed" : error);
                break;
            }
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::WAIT_COMMIT) {
            // Kept only for v14 trace compatibility; rolling transactions never
            // wait for a global commit boundary.
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_COMMIT) {
            const auto investment_started = Clock::now();
            if (_building_commit_phase == 0) {
                _investment_employment_cells.clear();
                commit_ready_construction(_investment_employment_cells);
                _investment_population_changed = false;
                _building_cell_cursor = 0;
                _building_commit_phase = 1;
            }
            if (_building_commit_phase == 1) {
                const int32_t investment_cell_count = _rolling_phase < _cell_count
                    ? (_cell_count - 1 - _rolling_phase) / ROLLING_PHASE_COUNT + 1 : 0;
                cursor_start = _building_cell_cursor;
                const int32_t end = std::min<int32_t>(
                    investment_cell_count,
                    _building_cell_cursor + _building_cells_per_slice);
                bool population_changed = false;
                if (!run_endogenous_building_investment(
                        _building_cell_cursor, end, _building_cell_cursor == 0,
                        population_changed, error)) {
                    fail(error.empty() ? "building_investment_failed" : error);
                    break;
                }
                _investment_population_changed =
                    _investment_population_changed || population_changed;
                work_done += end - _building_cell_cursor;
                _building_cell_cursor = end;
                cursor_end = _building_cell_cursor;
                building_range_used = true;
                _investment_ms += elapsed_ms(investment_started);
                if (_building_cell_cursor < investment_cell_count) break;
                _building_commit_phase = 2;
                break;
            }
            if (_building_commit_phase == 2) {
                const bool completed_investment = commit_ready_construction(
                    _investment_employment_cells);
                _investment_employment_cells.insert(
                    _investment_employment_cells.end(),
                    _structural_touched_cells.begin(),
                    _structural_touched_cells.end());
                if ((_investment_population_changed || completed_investment ||
                     !_investment_employment_cells.empty()) &&
                    !reconcile_building_employment_after_population_change(
                        _investment_employment_cells, error)) {
                    fail(error.empty() ? "building_investment_reconcile_failed" : error);
                    break;
                }
                _investment_pending_by_cell_type.clear();
                _investment_existing_by_cell_type.clear();
                _investment_harvest_by_cell_resource.clear();
                _investment_ms += elapsed_ms(investment_started);
                _building_cell_cursor = 0;
                _building_commit_phase = 0;
                _stage = Stage::AGGREGATE_PUBLISH;
                continue;
            }
        }
        if (_stage == Stage::AGGREGATE_PUBLISH) {
            if (!publish_epoch(error)) fail(error);
            break;
        }
        break;
    }
    out = report();
    out["done"] = !_epoch_active;
    out["work_done"] = work_done;
    out["cursor_start"] = cursor_start;
    out["cursor_end"] = cursor_end;
    out["elapsed_ms"] = elapsed_ms(slice_start);
    out["command_range_used"] = command_range_used;
    out["cell_range_used"] = cell_range_used;
    out["structural_range_used"] = structural_range_used;
    out["building_range_used"] = building_range_used;
    return out;
}

const char *NativeEconomyRuntime::stage_name() const {
    switch (_stage) {
        case Stage::IDLE: return "idle";
        case Stage::EPOCH_BEGIN: return "epoch_begin";
        case Stage::LEDGER_APPLY: return "ledger_apply";
        case Stage::HOUSEHOLD_MARKET: return "household_market";
        case Stage::STRUCTURAL_COMMIT: return "structural_commit";
        case Stage::WAIT_COMMIT: return "wait_commit";
        case Stage::BUILDING_EMPLOYMENT: return "building_employment";
        case Stage::BUILDING_PRODUCTION: return "building_production";
        case Stage::BUILDING_COMMIT: return "building_commit";
        case Stage::AGGREGATE_PUBLISH: return "aggregate_publish";
        case Stage::FATAL: return "fatal";
        case Stage::TRADE_SETTLE: return "trade_settle";
        case Stage::TRADE_DISPATCH: return "trade_dispatch";
        case Stage::TRADE_PLANNING: return "trade_planning";
        case Stage::BUILDING_PLAN: return "building_plan";
    }
    return "unknown";
}

int32_t NativeEconomyRuntime::stage_progress_q16() const {
    if (!_epoch_active) return _fatal ? 0 : static_cast<int32_t>(Q16_ONE - 1);
    switch (_stage) {
        case Stage::BUILDING_PLAN: {
            const int64_t phase_base = _building_plan_phase == 0 ? 0 : Q16_ONE / 20;
            const int64_t phase_progress =
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 20)) /
                std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size()));
            return static_cast<int32_t>(phase_base + phase_progress);
        }
        case Stage::LEDGER_APPLY:
            return static_cast<int32_t>(Q16_ONE / 10 +
                (_epoch_commands.empty() ? Q16_ONE / 10
                                         : (static_cast<int64_t>(_command_cursor) * (Q16_ONE / 10)) /
                                               static_cast<int64_t>(_epoch_commands.size())));
        case Stage::TRADE_SETTLE: return static_cast<int32_t>(Q16_ONE / 40);
        case Stage::TRADE_DISPATCH: return static_cast<int32_t>(Q16_ONE * 4 / 5);
        case Stage::BUILDING_EMPLOYMENT:
            return static_cast<int32_t>(Q16_ONE / 5 +
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 10)) /
                    std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size())));
        case Stage::BUILDING_PRODUCTION:
            return static_cast<int32_t>(Q16_ONE * 3 / 10 +
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 5)) /
                    std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size())));
        case Stage::HOUSEHOLD_MARKET:
            return static_cast<int32_t>(Q16_ONE / 2 +
                (static_cast<int64_t>(_cell_cursor) * (Q16_ONE * 3 / 10)) /
                    std::max(1, _market.market_count));
        case Stage::STRUCTURAL_COMMIT:
            return static_cast<int32_t>(Q16_ONE * 4 / 5 +
                (_structural_commands.empty() ? Q16_ONE / 10
                                              : (static_cast<int64_t>(_structural_cursor) *
                                                 (Q16_ONE / 10)) /
                                                    static_cast<int64_t>(_structural_commands.size())));
        case Stage::WAIT_COMMIT: return static_cast<int32_t>(Q16_ONE * 17 / 20);
        case Stage::BUILDING_COMMIT: {
            const int32_t investment_cell_count = _rolling_phase < _cell_count
                ? (_cell_count - 1 - _rolling_phase) / ROLLING_PHASE_COUNT + 1 : 0;
            const int64_t phase_progress = _building_commit_phase <= 0 ? 0
                : (_building_commit_phase >= 2 ? Q16_ONE / 20
                    : (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 20)) /
                        std::max(1, investment_cell_count));
            return static_cast<int32_t>(Q16_ONE * 9 / 10 + phase_progress);
        }
        case Stage::AGGREGATE_PUBLISH: return static_cast<int32_t>(Q16_ONE * 19 / 20);
        default: return 0;
    }
}

int64_t NativeEconomyRuntime::memory_bytes() const {
    int64_t bytes = 0;
    auto cap = [&](const auto &v) { bytes += static_cast<int64_t>(v.capacity() * sizeof(typename std::decay_t<decltype(v)>::value_type)); };
    cap(_population.cell_first_page); cap(_population.page_next); cap(_population.page_cell);
    cap(_population.free_pages); cap(_population.active); cap(_population.signature_id);
    cap(_population.generation); cap(_population.population); cap(_population.funds);
    cap(_population.epoch_income); cap(_population.epoch_expense);
    cap(_population.epoch_in_kind_income); cap(_population.income_ema);
    cap(_population.needs_satisfaction); cap(_population.worst_need_id);
    cap(_population.flags); cap(_population.demography_residual);
    cap(_population.owner_employed); cap(_population.employee_employed);
    cap(_market.stock); cap(_market.price); cap(_market.demand_ema);
    cap(_market.last_shortage_q16); cap(_market.cell_to_market);
    cap(_market_signals.cell_offsets); cap(_market_signals.good_ids);
    cap(_market_signals.business_demand_ema); cap(_market_signals.offered_supply_ema);
    cap(_market_signals.realized_withdrawal_ema);
    cap(_market_signals.cost_anchor_price);
    cap(_epoch_business_demand_ema); cap(_epoch_desired_business_demand);
    cap(_epoch_funded_business_demand); cap(_epoch_offered_supply_ema);
    cap(_epoch_cost_anchor_price);
    cap(_epoch_nonhousehold_withdrawals);
    cap(_production_input_reserve);
    cap(_cell_last_settlement_day); cap(_cell_settlement_generation);
    cap(_cell_price_stock_gen); cap(_cell_owner_cash_gen); cap(_cell_population_gen);
    cap(_cell_building_structure_gen); cap(_cell_technology_gen);
    cap(_cell_resource_gen); cap(_cell_trade_gen);
    cap(_epoch_market_ids); cap(_epoch_settlement_cells); cap(_epoch_building_cells);
    cap(_employment_metrics_epoch_by_cell); cap(_employment_owner_jobs_by_cell);
    cap(_employment_employee_jobs_by_cell); cap(_employment_unemployed_by_cell);
    cap(_building_survival_utilization_floor_q16);
    cap(_building_funded_capacity_q16); cap(_building_working_capital_allocated);
    cap(_building_owner_livelihood_credit);
    cap(_building_investment_score_q16); cap(_building_investment_payback_days);
    cap(_building_investment_rejection); cap(_trade_active_keys);
    cap(_investment_employment_cells);
    bytes += static_cast<int64_t>(_investment_pending_by_cell_type.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(uint8_t));
    bytes += static_cast<int64_t>(_investment_existing_by_cell_type.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(InvestmentExistingType));
    bytes += static_cast<int64_t>(_investment_harvest_by_cell_resource.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int64_t));
    cap(_trade_signal_clock_keys); cap(_trade_signal_first_seen_day);
    cap(_trade_signal_first_dispatch_day); cap(_trade_signal_last_attempt_day);
    cap(_trade_signal_last_rejection_reason); cap(_trade_signal_deadline_reported);
    cap(_owner_retained_outputs);
    cap(_trade_topology.neighbors); cap(_trade_topology.passable);
    cap(_trade_topology.enter_cost); cap(_trade_topology.component);
    cap(_trade_plan.sources); cap(_trade_plan.destinations);
    cap(_trade_plan.scan_cells); cap(_trade_plan.scan_goods); cap(_trade_plan.scan_inbound);
    cap(_trade_plan.working_candidates); cap(_trade_plan.ready_candidates);
    cap(_trade_plan.distance); cap(_trade_plan.distance_stamp);
    cap(_trade_plan.target_signal); cap(_trade_plan.target_stamp);
    cap(_trade_plan.heap); cap(_trade_plan.route_cache_keys);
    cap(_trade_plan.route_cache_costs);
    cap(_trade_orders.ids); cap(_trade_orders.sources); cap(_trade_orders.destinations);
    cap(_trade_orders.countries); cap(_trade_orders.departure_days);
    cap(_trade_orders.arrival_days); cap(_trade_orders.cash_escrow);
    cap(_trade_orders.capacity_work); cap(_trade_orders.states);
    cap(_trade_orders.cargo_delivered); cap(_trade_orders.line_offsets);
    cap(_trade_orders.line_goods); cap(_trade_orders.line_quantities);
    cap(_trade_orders.line_unit_prices); cap(_trade_orders.seller_offsets);
    cap(_trade_orders.seller_handles); cap(_trade_orders.seller_weights);
    cap(_trade_orders.arrival_bucket_days);
    cap(_trade_orders.arrival_bucket_offsets);
    cap(_trade_orders.arrival_bucket_orders);
    cap(_trade_flows.cells); cap(_trade_flows.goods); cap(_trade_flows.import_ema);
    cap(_trade_flows.export_ema); cap(_trade_flows.period_import);
    cap(_trade_flows.period_export);
    cap(_labor_signals.cell_offsets); cap(_labor_signals.profession_ids);
    cap(_labor_signals.base_living_cost); cap(_labor_signals.role_living_cost);
    cap(_labor_signals.contract_wage_ema); cap(_labor_signals.paid_wage_ema);
    cap(_labor_signals.job_days); cap(_labor_signals.pay_ratio_q16);
    cap(_market_cell_offsets); cap(_market_cells);
    cap(_signatures); cap(_plans); cap(_survival_required_need_indices);
    cap(_rules); cap(_rule_params); cap(_pending_commands);
    cap(_epoch_commands); cap(_structural_commands); cap(_committed_cells);
    cap(_staging_cells); cap(_structural_touched_cells); cap(_population_changed_cells);
    cap(_demand_basis_cache_day); cap(_demand_basis_variant_scores);
    cap(_demand_basis_variant_prices); cap(_demand_basis_need_score_sums);
    cap(_demand_basis_need_composites); cap(_demand_basis_need_environment);
    cap(_building_types); cap(_building_employee_roles); cap(_building_construction_goods);
	cap(_building_upgrade_family_ids); cap(_building_upgrade_family_indices);
	cap(_building_upgrade_tiers);
    cap(_building_inputs); cap(_building_input_candidates);
    cap(_building_outputs); cap(_building_resources);
	cap(_building_output_cost_shares_q16);
	cap(_cycle_flow_good_ids);
    cap(_building_resource_generation);
    cap(_building_conditions); cap(_buildings); cap(_building_cell_offsets);
    cap(_building_active_cells);
    cap(_building_employee_filled);
    cap(_building_last_input_selected_goods);
    cap(_building_role_contract_wage); cap(_building_role_base_living_cost);
    cap(_building_role_living_cost); cap(_building_role_local_average_wage);
    cap(_building_role_base_wage_due); cap(_building_role_base_wage_paid);
    cap(_building_role_bonus_due); cap(_building_role_bonus_paid);
    cap(_pending_construction); cap(_resource_snapshot); cap(_resource_remaining);
    cap(_resource_gen_base); cap(_resource_gen_temp); cap(_resource_gen_moisture);
    cap(_resource_gen_self); cap(_resource_decay_base); cap(_resource_decay_temp);
    cap(_resource_decay_moisture); cap(_resource_decay_self_q16);
    cap(_resource_ecology_capacity); cap(_resource_ecology_growth_q16);
    cap(_resource_temp_lo_q16); cap(_resource_temp_hi_q16);
    cap(_resource_deltas); cap(_last_published_resource_deltas);
    cap(_building_elevation_q16); cap(_building_terrain);
    cap(_building_landform); cap(_building_vegetation); cap(_building_is_water);
    cap(_building_has_river); cap(_building_neighbors);
    bytes += trace_memory_bytes();
    return bytes;
}

Dictionary NativeEconomyRuntime::report() const {
    Dictionary out;
    const int64_t age_days = _epoch_active
        ? std::max<int64_t>(0, _current_day - _sample_day)
        : _settlement_max_age_days;
    const int64_t deadline_day = _sample_day;
    const bool commit_due = _epoch_active && _current_day >= deadline_day;
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds +
        _opening_totals.country_cash + _opening_totals.escrow_cash;
    const int64_t money_close = _closing_totals.cohort_funds +
        _closing_totals.country_cash + _closing_totals.escrow_cash;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["configured"] = _configured;
    out["bootstrapped"] = _bootstrapped;
    out["epoch_active"] = _epoch_active;
    out["epoch_id"] = _epoch_id;
    out["epoch_days"] = _epoch_days;
    out["sample_day"] = _sample_day;
    out["current_day"] = _current_day;
    out["commit_day"] = _commit_day;
    out["age_days"] = age_days;
    out["stage"] = stage_name();
    out["progress_q16"] = stage_progress_q16();
    out["building_plan_phase"] = _stage == Stage::BUILDING_PLAN
        ? _building_plan_phase : -1;
    out["building_commit_phase"] = _stage == Stage::BUILDING_COMMIT
        ? _building_commit_phase : -1;
    out["processed_cells"] = _processed_cells;
    out["processed_cohorts"] = _processed_cohorts;
    out["processed_rules"] = _processed_rules;
    out["processed_commands"] = _processed_commands;
    out["rejected_commands"] = _rejected_commands;
    out["formula_ms"] = _formula_ms;
    out["clear_ms"] = _clear_ms;
    out["ledger_ms"] = _ledger_ms;
    out["processed_needs"] = _processed_needs;
    out["processed_variants"] = _processed_variants;
    out["processed_components"] = _processed_components;
    out["fallback_ms"] = _fallback_ms;
    out["merchant_settle_ms"] = _merchant_settle_ms;
    out["price_ms"] = _price_ms;
    out["structure_ms"] = _structure_ms;
    out["publish_ms"] = _publish_ms;
    out["building_employment_ms"] = _employment_ms;
    out["building_production_ms"] = _production_ms;
    out["building_production_merge_ms"] = _production_merge_ms;
    out["building_plan_ms"] = _building_plan_ms;
    out["building_investment_ms"] = _investment_ms;
    out["working_capital_scale_error_bound_q16"] =
        _working_capital_scale_error_bound_q16;
    out["market_signal_ms"] = _market_signal_ms;
    out["wage_plan_ms"] = _wage_plan_ms;
    out["labor_signal_ms"] = _labor_signal_ms;
    out["trade_plan_ms"] = _trade_plan_ms;
    out["trade_settle_ms"] = _trade_settle_ms;
    out["trade_dispatch_ms"] = _trade_dispatch_ms;
    out["prepare_ms"] = _prepare_ms;
    out["audit_ms"] = _audit_ms;
    out["watermark_ms"] = _watermark_ms;
    out["event_summary_ms"] = _event_summary_ms;
    out["event_detail_ms"] = _event_detail_ms;
    out["event_publish_ms"] = _event_publish_ms;
    out["event_stream_hash"] = static_cast<int64_t>(_event_stream_hash);
    out["economy_event_newest_id"] = _next_event_id - 1;
    out["economy_event_last_batch_count"] = _committed_event_batches.empty() ? 0 :
        static_cast<int64_t>(_committed_event_batches.back().events.size());
    out["economy_trace_memory_bytes"] = trace_memory_bytes();
    out["economy_trace_detail_truncated"] = _trace_detail_truncated;
    out["worker_tasks"] = _worker_tasks;
    out["building_production_worker_tasks"] = _production_worker_tasks;
    out["settlement_mode"] = "rolling_five_phase";
    out["settlement_phase"] = _rolling_phase;
    out["settlement_phase_count"] = ROLLING_PHASE_COUNT;
    out["due_cells"] = _rolling_due_cells;
    out["processed_due_cells"] = _rolling_processed_cells;
    out["deferred_cells"] = _rolling_deferred_cells;
    out["settlement_watermark"] = _settlement_watermark;
    out["newest_state_day"] = _settlement_newest_day;
    out["max_state_age_days"] = _settlement_max_age_days;
    out["rolling_deadline_violations"] = _rolling_deadline_violations;
    out["worker_enabled"] = _worker_enabled;
    out["worker_market_threshold"] = _worker_market_threshold;
    out["markets_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["building_groups_per_slice"] = _building_groups_per_slice;
    out["auto_slice_by_scale"] = _auto_slice_by_scale;
    out["memory_bytes"] = memory_bytes();
    out["cohort_count"] = _population.active_count;
    out["market_count"] = _market.market_count;
    out["good_count"] = _market.good_count;
    out["building_type_count"] = static_cast<int64_t>(_building_types.size());
    out["building_group_count"] = static_cast<int64_t>(_buildings.size());
    out["pending_construction_count"] = static_cast<int64_t>(_pending_construction.size());
    out["processed_building_groups"] = _processed_building_groups;
    out["filled_owner_jobs"] = _filled_owner_jobs;
    out["filled_employee_jobs"] = _filled_employee_jobs;
    out["unemployed_population"] = _unemployed_population;
    out["construction_goods_consumed"] = _construction_goods_consumed;
    out["building_investment_model"] = "endogenous_owner_investment_v5";
    out["building_investment_candidates"] = _building_investment_candidates;
    out["building_owner_mobility"] = _building_owner_mobility;
    out["building_owner_job_reallocations"] =
        _building_owner_job_reallocations;
    out["building_owner_job_profession_changes"] =
        _building_owner_job_profession_changes;
    out["building_owner_job_probability_skips"] =
        _building_owner_job_probability_skips;
    out["building_investments_started"] = _building_investments_started;
    out["building_investment_blocked_funds"] =
        _building_investment_blocked_funds;
    out["building_investment_blocked_materials"] =
        _building_investment_blocked_materials;
    out["building_investment_blocked_sponsor_capital"] =
        _building_investment_blocked_sponsor_capital;
    out["building_investment_blocked_resources"] =
        _building_investment_blocked_resources;
    out["building_investment_probability_skips"] =
        _building_investment_probability_skips;
    out["building_investment_capital_transferred"] =
        _building_investment_capital_transferred;
    out["desired_business_demand"] = _desired_business_demand;
    out["funded_business_demand"] = _funded_business_demand;
    out["unfunded_business_demand"] = _unfunded_business_demand;
    out["owner_working_capital_allocated"] = _owner_working_capital_allocated;
    out["production_inputs_consumed"] = _production_inputs_consumed;
    out["production_output_stock"] = _production_output_stock;
    out["production_output_discarded"] = _production_output_discarded;
    out["production_output_retained"] = _production_output_retained;
    out["production_output_supported"] = _production_output_supported;
    out["owner_output_consumed"] = _owner_output_consumed;
    out["producer_revenue"] = _producer_revenue;
	out["producer_support_money_issued"] = _producer_support_money_issued;
	out["producer_support_price_numerator"] = PRODUCER_SUPPORT_PRICE_NUMERATOR;
	out["producer_support_price_denominator"] = PRODUCER_SUPPORT_PRICE_DENOMINATOR;
	out["bullion_money_issued"] = _bullion_money_issued;
	out["bullion_stock_consumed"] = _bullion_stock_consumed;
	out["gold_accepted"] = _gold_accepted;
	out["silver_accepted"] = _silver_accepted;
	out["gold_money_issued"] = _gold_money_issued;
	out["silver_money_issued"] = _silver_money_issued;
	out["cycle_flow_produced"] = _cycle_flow_produced;
	out["cycle_flow_consumed"] = _cycle_flow_consumed;
	out["cycle_flow_discarded"] = _cycle_flow_discarded;
    out["building_wages_paid"] = _building_wages_paid;
    out["building_wages_unpaid"] = _building_wages_unpaid;
    out["building_base_wages_due"] = _building_base_wages_due;
    out["building_base_wages_paid"] = _building_base_wages_paid;
    out["building_bonus_due"] = _building_bonus_due;
    out["building_bonus_paid"] = _building_bonus_paid;
    out["wage_suspended_building_groups"] = _wage_suspended_building_groups;
    out["loss_suspended_building_groups"] = _loss_suspended_building_groups;
    out["merchant_procurement_budget"] = _merchant_procurement_budget;
    out["merchant_procurement_opportunity"] = _merchant_procurement_opportunity;
    out["merchant_procurement_allocated"] = _merchant_procurement_allocated;
    out["merchant_procurement_unspent_allocated"] = _merchant_procurement_unspent_allocated;
    out["merchant_procurement_reserved"] = _merchant_procurement_reserved;
    out["merchant_procurement_spent"] = _merchant_procurement_spent;
    out["production_input_reserved"] = _production_input_reserved;
    out["production_input_reserve_shortfall"] =
        _production_input_reserve_shortfall;
    out["owner_working_capital_reserved"] = _owner_working_capital_reserved;
    out["building_severe_loss_threshold_q16"] = _building_severe_loss_threshold_q16;
    out["building_severe_loss_cycles"] = _building_severe_loss_cycles;
    out["building_restart_margin_q16"] = _building_restart_margin_q16;
    out["building_restart_cycles"] = _building_restart_cycles;
    out["merchant_procurement_cash_reserve_q16"] =
        _merchant_procurement_cash_reserve_q16;
    out["merchant_market_making_days_q16"] = _merchant_market_making_days_q16;
    out["labor_signal_edges"] =
        static_cast<int64_t>(_labor_signals.profession_ids.size());
    out["labor_signal_updates"] = _labor_signal_updates;
    out["building_resource_generated"] = _building_resource_generated;
    out["building_resource_consumed"] = _building_resource_consumed;
    out["building_resource_net_delta"] =
        _building_resource_generated - _building_resource_consumed;
    out["building_resource_limited_groups"] = _building_resource_limited_groups;
    out["market_signal_edges"] = static_cast<int64_t>(_market_signals.good_ids.size());
    out["market_signal_updates"] = _market_signal_updates;
    out["trade_runtime_mode"] = _trade_runtime_mode == 0 ? "OFF"
        : (_trade_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["trade_topology_ready"] = _trade_topology.ready;
    out["trade_topology_generation"] = static_cast<int64_t>(
        _trade_topology.topology_generation);
    out["trade_topology_hash"] = static_cast<int64_t>(
        _trade_topology.topology_hash);
    // Compatibility key retained for CSV/UI readers; this is now the stable
    // frozen border hash rather than the country's treasury mutation generation.
    out["trade_country_generation"] = static_cast<int64_t>(
        _trade_topology.component_country_hash);
    out["trade_country_topology_hash"] = static_cast<int64_t>(
        _epoch_country_topology_hash);
    out["trade_plan_phase"] = _trade_plan.phase == TradePlanStore::SCAN ? "SCAN"
        : (_trade_plan.phase == TradePlanStore::ROUTE ? "ROUTE" : "IDLE");
    out["trade_scan_cursor"] = _trade_plan.scan_cursor;
    out["trade_scan_total"] = _trade_plan.scan_total;
    out["trade_scan_progress_q16"] = _trade_plan.scan_total <= 0 ? 0
        : static_cast<int64_t>(std::min<int64_t>(Q16_ONE,
            (_trade_plan.scan_cursor * Q16_ONE) / _trade_plan.scan_total));
    out["trade_completed_scans"] = _trade_plan.completed_scans;
    out["trade_route_cursor"] = _trade_plan.route_cursor;
    out["trade_route_total"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_plan_reset_count"] = _trade_plan_reset_count;
    out["trade_topology_content_change_count"] =
        _trade_topology_content_change_count;
    out["trade_last_plan_reset_reason"] = String(
        _trade_last_plan_reset_reason.c_str());
    out["trade_source_signals"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_destination_signals"] = static_cast<int64_t>(
        _trade_plan.destinations.size());
    out["trade_ready_candidates"] = static_cast<int64_t>(
        _trade_plan.ready_candidates.size());
    out["trade_signal_max_age_days"] = _trade_signal_max_age_days;
    out["trade_first_dispatch_delay_max_days"] =
        _trade_first_dispatch_delay_max_days;
    out["trade_response_deadline_misses"] = _trade_response_deadline_misses;
    out["trade_response_deadline_misses_cumulative"] =
        _trade_response_deadline_misses_cumulative;
    out["trade_unresolved_no_attempt"] = _trade_unresolved_no_attempt;
    out["trade_unresolved_no_spread"] = _trade_unresolved_no_spread;
    out["trade_unresolved_margin"] = _trade_unresolved_margin;
    out["trade_unresolved_route"] = _trade_unresolved_route;
    out["trade_unresolved_stock"] = _trade_unresolved_stock;
    out["trade_unresolved_capacity"] = _trade_unresolved_capacity;
    out["trade_unresolved_cash"] = _trade_unresolved_cash;
    out["trade_unresolved_order_cap"] = _trade_unresolved_order_cap;
    out["trade_route_expansions"] = _trade_route_expansions;
    out["trade_route_cache_hits"] = _trade_route_cache_hits;
    out["trade_route_cache_misses"] = _trade_route_cache_misses;
    out["trade_candidates_generated"] = _trade_candidates_generated;
    out["trade_candidates_accepted"] = _trade_candidates_accepted;
    out["trade_rejected_profit"] = _trade_rejected_profit;
    out["trade_rejected_no_spread"] = _trade_rejected_no_spread;
    out["trade_rejected_margin"] = _trade_rejected_margin;
    out["trade_quantity_profit_clips"] = _trade_quantity_profit_clips;
    out["trade_relief_candidates"] = _trade_relief_candidates;
    out["trade_rejected_capacity"] = _trade_rejected_capacity;
    out["trade_rejected_stock"] = _trade_rejected_stock;
    out["trade_rejected_cash"] = _trade_rejected_cash;
    out["trade_rejected_route"] = _trade_rejected_route;
    out["trade_rejected_order_cap"] = _trade_rejected_order_cap;
    out["trade_orders_in_flight"] = _trade_orders.size();
    out["trade_arrival_bucket_count"] = static_cast<int64_t>(
        _trade_orders.arrival_bucket_days.size());
    out["trade_orders_dispatched"] = _trade_orders_dispatched;
    out["trade_orders_arrived"] = _trade_orders_arrived;
    out["trade_unclaimed_orders"] = _trade_unclaimed_orders;
    out["trade_capacity_available"] = _trade_capacity_available;
    out["trade_capacity_used"] = _trade_capacity_used;
    out["trade_capacity_utilization_q16"] = _trade_capacity_available <= 0 ? 0
        : std::min<int64_t>(Q16_ONE,
            (_trade_capacity_used * Q16_ONE) / _trade_capacity_available);
    out["trade_transit_goods"] = trade_transit_goods();
    out["trade_escrow_cash"] = trade_escrow_cash();
    out["trade_settlement_lag_days"] = _trade_settlement_lag_days;
    out["price_cost_anchor_hits"] = _price_cost_anchor_hits;
    out["price_inactive_reversions"] = _price_inactive_reversions;
    out["unprofitable_building_groups"] = _unprofitable_building_groups;
    out["zero_utilization_building_groups"] = _zero_utilization_building_groups;
    out["average_planned_utilization_q16"] = _buildings.empty() ? Q16_ONE :
        _utilization_sum_q16 / static_cast<int64_t>(_buildings.size());
    out["building_resource_capacity_checks"] = _building_resource_capacity_checks;
    out["building_resource_capacity_limited_groups"] =
        _building_resource_capacity_limited_groups;
    out["last_building_rejection_reason"] = String(_last_building_rejection_reason.c_str());
    out["population_error"] = _epoch_active ? 0 : _closing_totals.population - population_expected;
    out["money_error"] = _epoch_active ? 0
        : money_close - (money_open + _explicit_money_mint - _explicit_money_burn);
    out["goods_error"] = _epoch_active ? 0
        : _closing_totals.goods_stock -
              (_opening_totals.goods_stock + _explicit_stock_delta +
               _production_output_stock + _production_output_retained -
               _consumed_goods - _owner_output_consumed -
			   _construction_goods_consumed - _production_inputs_consumed -
			   _cycle_flow_discarded - _bullion_stock_consumed);
    out["saturation_count"] = _saturation_count;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    out["fatal"] = _fatal;
    out["commit_lag_budget_days"] = _commit_lag_budget_days;
    out["commit_over_budget"] = _epoch_active && age_days > _commit_lag_budget_days;
    out["commit_due"] = commit_due;
    out["boundary_continuation_required"] = false;
    out["cycle_deadline_day"] = deadline_day;
    out["days_until_commit"] = _epoch_active
        ? std::max<int64_t>(0, deadline_day - _current_day) : 0;
    out["market_cycle_days"] = _epoch_days;
    out["market_configured_cycle_days"] = _configured_epoch_days;
    out["market_min_cycle_days"] = _min_epoch_days;
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["market_max_cycle_days"] = _max_epoch_days;
    out["market_cells_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    out["approximation_version"] = 15;
    out["approximation_model"] = "rolling_cell_settlement_v15";
    out["starvation_satisfaction_threshold_q16"] =
        _starvation_satisfaction_threshold_q16;
    out["survival_production_target_q16"] = _survival_production_target_q16;
    out["starvation_death_rate_q32"] = _starvation_death_rate_q32;
    out["births"] = _births;
    out["deaths"] = _deaths;
    out["period_transactions"] = true;
    out["max_command_latency_days"] = _epoch_days;
    out["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    out["catalog_hash"] = _catalog_hash;
    out["building_catalog_hash"] = _building_catalog_hash;
    out["environment_day"] = _environment_day;
    out["environment_hash"] = _environment_hash;
    out["country_schema_version"] = NativeCountryRuntime::SCHEMA_VERSION;
    out["country_generation"] = static_cast<int64_t>(_epoch_country_generation);
    out["country_state_hash"] = static_cast<int64_t>(_epoch_country_hash);
    out["country_commands_due"] = _country_runtime != nullptr &&
        _country_runtime->should_run(_current_day);
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = _merchant_repairs;
    out["price_cap_hits"] = _price_cap_hits;
    out["price_runtime_bounds"] = "numeric_guard_only";
    out["price_numeric_guard_min"] = PRICE_NUMERIC_GUARD_MIN;
    out["price_numeric_guard_max"] = PRICE_NUMERIC_GUARD_MAX;
    out["continuation_slices"] = _continuation_slices;
    out["market_runtime_mode"] = _market_runtime_mode == 0 ? "OFF" :
                                   (_market_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    return out;
}

Dictionary NativeEconomyRuntime::population_cell_summary(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const CellSummary summary = build_cell_summary(cell_idx);
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
    out["survival_satisfaction_q16"] = summary.satisfaction_q16;
    out["epoch_id"] = _epoch_id;
    return out;
}

Dictionary NativeEconomyRuntime::population_cell_snapshot(int32_t cell_idx) const {
    return population_cell_snapshot_impl(cell_idx, environment_sample_for_cell(cell_idx));
}

Dictionary NativeEconomyRuntime::population_cell_snapshot(
        int32_t cell_idx, float temperature, float moisture, float snow_cover,
        float weather_intensity, bool environment_ready) const {
    EnvironmentSample sample = environment_sample_from_float(
        temperature, moisture, snow_cover, weather_intensity, environment_ready);
    if (!environment_ready) {
        const EnvironmentSample frozen = environment_sample_for_cell(cell_idx);
        if (frozen.ready) sample = frozen;
    }
    return population_cell_snapshot_impl(cell_idx, sample);
}

Dictionary NativeEconomyRuntime::population_cell_snapshot_impl(
        int32_t cell_idx, const EnvironmentSample &sample) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    // Selected-cell queries run synchronously between native slices. Build the
    // bounded cell summary from the current SoA so UI never needs a global
    // cohort snapshot or waits for the next commit boundary.
    const CellSummary summary = build_cell_summary(cell_idx);
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
    out["survival_satisfaction_q16"] = summary.satisfaction_q16;
    out["epoch_id"] = _epoch_id;
    PackedInt64Array handles;
    PackedInt32Array signatures;
    PackedInt32Array professions;
    PackedInt32Array ethnicities;
    PackedInt64Array populations;
    PackedInt64Array funds;
    PackedInt64Array incomes;
    PackedInt64Array expenses;
    PackedInt64Array in_kind_income;
    PackedInt64Array cash_expense_coverage_q16;
    PackedInt64Array livelihood_coverage_q16;
    PackedInt64Array income_ema;
    PackedInt32Array satisfaction;
    PackedInt32Array worst_need_ids;
    PackedByteArray merchant_flags;
    PackedInt64Array owner_employed;
    PackedInt64Array employee_employed;
    PackedInt64Array unemployed;
    std::vector<int32_t> slots;
    _population.for_each_in_cell(cell_idx, [&](int32_t slot) { slots.push_back(slot); });
    for (int32_t slot : slots) {
        handles.push_back(static_cast<int64_t>(_population.handle_for_slot(slot)));
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        signatures.push_back(signature);
        professions.push_back(_signatures[signature].profession_id);
        ethnicities.push_back(_signatures[signature].ethnicity_id);
        populations.push_back(_population.population[slot]);
        funds.push_back(_population.funds[slot]);
        incomes.push_back(_population.epoch_income[slot]);
        expenses.push_back(_population.epoch_expense[slot]);
        const int64_t in_kind = _population.epoch_in_kind_income[slot];
        in_kind_income.push_back(in_kind);
        int64_t diagnostic_sat = 0;
        cash_expense_coverage_q16.push_back(_population.epoch_expense[slot] > 0
            ? mul_div_sat(_population.epoch_income[slot], Q16_ONE,
                          _population.epoch_expense[slot], diagnostic_sat) : Q16_ONE);
        const int64_t livelihood_income = saturating_add(
            _population.epoch_income[slot], in_kind, diagnostic_sat);
        const int64_t livelihood_expense = saturating_add(
            _population.epoch_expense[slot], in_kind, diagnostic_sat);
        livelihood_coverage_q16.push_back(livelihood_expense > 0
            ? mul_div_sat(livelihood_income, Q16_ONE,
                          livelihood_expense, diagnostic_sat) : Q16_ONE);
        income_ema.push_back(_population.income_ema[slot]);
        satisfaction.push_back(_population.needs_satisfaction[slot]);
        worst_need_ids.push_back(_population.worst_need_id[slot] == std::numeric_limits<uint16_t>::max()
                                     ? -1 : _population.worst_need_id[slot]);
        merchant_flags.push_back(is_merchant_slot(slot) ? 1 : 0);
        owner_employed.push_back(_population.owner_employed[slot]);
        employee_employed.push_back(_population.employee_employed[slot]);
        unemployed.push_back(std::max<int64_t>(0, _population.population[slot] -
            _population.owner_employed[slot] - _population.employee_employed[slot]));
    }
    out["handles"] = handles;
    out["signature_ids"] = signatures;
    out["profession_ids"] = professions;
    out["ethnicity_ids"] = ethnicities;
    out["populations"] = populations;
    out["funds_by_cohort"] = funds;
    out["epoch_income_by_cohort"] = incomes;
    out["epoch_expense_by_cohort"] = expenses;
    out["epoch_in_kind_income_by_cohort"] = in_kind_income;
    out["cash_expense_coverage_by_cohort_q16"] = cash_expense_coverage_q16;
    out["livelihood_coverage_by_cohort_q16"] = livelihood_coverage_q16;
    out["income_ema_by_cohort"] = income_ema;
    out["satisfaction_by_cohort_q16"] = satisfaction;
    out["survival_satisfaction_by_cohort_q16"] = satisfaction;
    out["worst_need_ids"] = worst_need_ids;
    out["merchant_flags"] = merchant_flags;
    out["owner_employed_by_cohort"] = owner_employed;
    out["employee_employed_by_cohort"] = employee_employed;
    out["unemployed_by_cohort"] = unemployed;
    const EventBatch *settlement_batch = nullptr;
    for (auto it = _committed_event_batches.rbegin();
         it != _committed_event_batches.rend(); ++it) {
        if (it->cashflow_complete && it->cashflow_cell == cell_idx) {
            settlement_batch = &(*it);
            break;
        }
    }
    PackedStringArray cashflow_source_ids;
    cashflow_source_ids.push_back("wages");
    cashflow_source_ids.push_back("owner_operations");
    cashflow_source_ids.push_back("merchant_household_sales");
    cashflow_source_ids.push_back("merchant_business_sales");
    cashflow_source_ids.push_back("transfer");
    cashflow_source_ids.push_back("household_consumption");
    cashflow_source_ids.push_back("production_inputs");
    cashflow_source_ids.push_back("owner_wages");
    cashflow_source_ids.push_back("construction");
    cashflow_source_ids.push_back("merchant_procurement");
    cashflow_source_ids.push_back("other");
    cashflow_source_ids.push_back("producer_support_issuance");
    out["settlement_cashflow_source_stable_ids"] = cashflow_source_ids;
    out["settlement_detail_available"] = settlement_batch != nullptr;
    out["settlement_detail_pending"] = settlement_batch == nullptr &&
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG) &&
        (_inspector_trace_cell == cell_idx ||
         (_inspector_trace_pending && _pending_inspector_trace_cell == cell_idx));
    PackedInt32Array settlement_offsets;
    PackedInt32Array settlement_source_indices;
    PackedInt64Array settlement_income;
    PackedInt64Array settlement_expense;
    PackedInt64Array settlement_income_by_cohort;
    PackedInt64Array settlement_expense_by_cohort;
    int64_t settlement_saturation = 0;
    settlement_offsets.push_back(0);
    for (int32_t slot : slots) {
        const uint64_t handle = _population.handle_for_slot(slot);
        int64_t total_income = 0;
        int64_t total_expense = 0;
        if (settlement_batch != nullptr) {
            for (const CashflowEntry &entry : settlement_batch->cashflows) {
                if (entry.cohort_handle != handle ||
                    (entry.income == 0 && entry.expense == 0)) continue;
                settlement_source_indices.push_back(entry.source - 1);
                settlement_income.push_back(entry.income);
                settlement_expense.push_back(entry.expense);
                total_income = saturating_add(total_income, entry.income,
                                              settlement_saturation);
                total_expense = saturating_add(total_expense, entry.expense,
                                               settlement_saturation);
            }
        }
        settlement_income_by_cohort.push_back(total_income);
        settlement_expense_by_cohort.push_back(total_expense);
        settlement_offsets.push_back(settlement_source_indices.size());
    }
    out["settlement_cashflow_offsets"] = settlement_offsets;
    out["settlement_cashflow_source_indices"] = settlement_source_indices;
    out["settlement_cashflow_income"] = settlement_income;
    out["settlement_cashflow_expense"] = settlement_expense;
    out["settlement_income_by_cohort"] = settlement_income_by_cohort;
    out["settlement_expense_by_cohort"] = settlement_expense_by_cohort;
    if (settlement_batch != nullptr) {
        out["settlement_epoch_id"] = settlement_batch->epoch_id;
        out["settlement_sample_day"] = settlement_batch->sample_day;
        out["settlement_commit_day"] = settlement_batch->commit_day;
        out["settlement_period_days"] = settlement_batch->period_days;
        out["settlement_snapshot_source"] = "committed_trace";
    }
    PackedStringArray profession_stable_ids;
    for (const std::string &id : _profession_ids) profession_stable_ids.push_back(String(id.c_str()));
    PackedStringArray ethnicity_stable_ids;
    for (const std::string &id : _ethnicity_ids) ethnicity_stable_ids.push_back(String(id.c_str()));
    out["profession_stable_ids"] = profession_stable_ids;
    out["ethnicity_stable_ids"] = ethnicity_stable_ids;
    PackedStringArray demand_good_stable_ids;
    for (const std::string &id : _good_ids) {
        demand_good_stable_ids.push_back(String(id.c_str()));
    }
    PackedInt32Array demand_good_offsets;
    PackedInt32Array demand_good_indices;
    PackedInt64Array demand_per_capita_daily;
    PackedStringArray demand_need_stable_ids;
    for (const std::string &id : _need_ids) {
        demand_need_stable_ids.push_back(String(id.c_str()));
    }
    PackedInt32Array demand_need_offsets;
    PackedInt32Array demand_need_indices;
    PackedInt32Array demand_need_variant_offsets;
    PackedInt32Array demand_variant_component_offsets;
    PackedInt32Array demand_component_good_indices;
    PackedInt64Array demand_component_per_capita_daily;
    demand_good_offsets.push_back(0);
    demand_need_offsets.push_back(0);
    demand_need_variant_offsets.push_back(0);
    demand_variant_component_offsets.push_back(0);
    const int32_t market = _market.cell_to_market[cell_idx];
    std::vector<int64_t> variant_scores;
    std::vector<int64_t> variant_prices;
    std::vector<int64_t> need_score_sums;
    std::vector<int64_t> need_composites;
    std::vector<int64_t> need_environment;
    std::vector<int64_t> good_quantities(_market.good_count, 0);
    int64_t preview_saturation_count = 0;
    build_demand_basis(market, sample, variant_scores, variant_prices,
                       need_score_sums, need_composites, need_environment,
                       preview_saturation_count);
    for (int32_t slot : slots) {
        std::fill(good_quantities.begin(), good_quantities.end(), int64_t{0});
        const int64_t population = std::max<int64_t>(1, _population.population[slot]);
        const uint32_t signature_id = _population.signature_id[slot];
        if (signature_id < _signatures.size()) {
            const Signature &signature = _signatures[signature_id];
            const Plan &plan = _plans[signature.plan_id];
            for (int32_t n = 0; n < plan.need_count; ++n) {
                const int32_t need_index = plan.need_begin + n;
                const Need &need = _needs[need_index];
                const int64_t score_sum = need_score_sums[need_index];
                if (score_sum <= 0) continue;
                const int64_t desired = desired_need_units(
                    slot, need_index, 1, need_environment[need_index],
                    need_composites[need_index], preview_saturation_count);
                if (desired <= 0) continue;
                demand_need_indices.push_back(need.stable_id);
                int64_t prefix_score = 0;
                int64_t allocated = 0;
                for (int32_t v = 0; v < need.variant_count; ++v) {
                    const int32_t variant_id = need.variant_begin + v;
                    prefix_score = saturating_add(prefix_score, variant_scores[variant_id],
                                                  preview_saturation_count);
                    const int64_t next = mul_div_sat(desired, prefix_score, score_sum,
                                                     preview_saturation_count);
                    const int64_t units = std::max<int64_t>(0, next - allocated);
                    allocated = next;
                    const VariantChoice &variant = _variants[variant_id];
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const NeedComponent &component =
                            _components[variant.component_begin + c];
                        const int64_t quantity = units > 0
                            ? mul_div_sat(units, component.qty_per_need, GOODS_SCALE,
                                          preview_saturation_count)
                            : 0;
                        good_quantities[component.good_id] = saturating_add(
                            good_quantities[component.good_id], quantity,
                            preview_saturation_count);
                        demand_component_good_indices.push_back(component.good_id);
                        demand_component_per_capita_daily.push_back(quantity / population);
                    }
                    demand_variant_component_offsets.push_back(
                        demand_component_good_indices.size());
                }
                demand_need_variant_offsets.push_back(
                    demand_variant_component_offsets.size() - 1);
            }
        }
        demand_need_offsets.push_back(demand_need_indices.size());
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t per_capita = good_quantities[good] / population;
            if (per_capita <= 0) continue;
            demand_good_indices.push_back(good);
            demand_per_capita_daily.push_back(per_capita);
        }
        demand_good_offsets.push_back(demand_good_indices.size());
    }
    out["demand_good_offsets"] = demand_good_offsets;
    out["demand_good_indices"] = demand_good_indices;
    out["demand_per_capita_daily"] = demand_per_capita_daily;
    out["demand_good_stable_ids"] = demand_good_stable_ids;
    out["demand_need_stable_ids"] = demand_need_stable_ids;
    out["demand_need_offsets"] = demand_need_offsets;
    out["demand_need_indices"] = demand_need_indices;
    out["demand_need_variant_offsets"] = demand_need_variant_offsets;
    out["demand_variant_component_offsets"] = demand_variant_component_offsets;
    out["demand_component_good_indices"] = demand_component_good_indices;
    out["demand_component_per_capita_daily"] = demand_component_per_capita_daily;
    out["demand_preview_basis"] = _epoch_active
        ? "live_slice_economy_current_environment_daily"
        : "committed_economy_current_environment_daily";
    out["demand_preview_environment_ready"] = sample.ready;
    out["demand_preview_saturation_count"] = preview_saturation_count;
    return out;
}

Dictionary NativeEconomyRuntime::market_cell_snapshot(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const int32_t market = _market.cell_to_market[cell_idx];
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["market_id"] = market;
    out["epoch_id"] = _epoch_id;
    PackedStringArray good_ids;
    PackedInt64Array stock;
    PackedInt64Array demand_ema;
    PackedInt64Array business_demand_ema;
    PackedInt64Array desired_business_demand;
    PackedInt64Array funded_business_demand;
    PackedInt64Array unfunded_business_demand;
    PackedInt64Array offered_supply_ema;
    PackedInt64Array realized_withdrawal_ema;
    PackedInt64Array production_input_reserve;
    PackedInt64Array household_available_stock;
    PackedInt64Array merchant_inventory_target;
    PackedInt64Array merchant_procurement_shortfall;
    PackedInt64Array trade_export_safety_stock;
    PackedInt64Array trade_import_fill_target;
    PackedInt32Array trade_relief_pressure_values_q16;
    PackedInt32Array trade_signal_age_days;
    PackedInt32Array trade_first_dispatch_delay_days;
    PackedInt64Array trade_last_attempt_day;
    PackedInt32Array trade_last_rejection_reason;
    PackedByteArray trade_deadline_exceeded;
    PackedInt32Array cost_anchor_price;
    PackedInt32Array price;
    PackedInt32Array shortage_q16;
    PackedInt32Array pressure_excess_q16;
    PackedInt64Array price_inventory_target;
    PackedInt32Array pressure_inventory_q16;
    PackedInt32Array pressure_shortage_q16;
    PackedInt32Array pressure_cost_q16;
    PackedInt32Array pressure_idle_q16;
    PackedInt32Array pressure_total_q16;
    PackedInt32Array price_change_q16;
	PackedByteArray trade_enabled;
	PackedInt32Array transport_load_per_unit_q16;
	PackedInt64Array trade_import_ema;
	PackedInt64Array trade_export_ema;
	PackedInt64Array trade_inbound;
	PackedInt64Array trade_outbound;
	PackedStringArray category_ids;
	PackedInt32Array storage_modes;
	PackedInt64Array monetary_issue_values;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
	PackedByteArray technology_available;
	technology_tag_offsets.push_back(0);
    int64_t snapshot_saturation = 0;
    std::vector<int64_t> inbound(static_cast<size_t>(_market.good_count), 0);
    std::vector<int64_t> outbound(static_cast<size_t>(_market.good_count), 0);
    int64_t next_arrival = -1;
    int64_t inbound_escrow = 0;
    int64_t outbound_escrow = 0;
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        const bool destination_order = _trade_orders.destinations[order] == cell_idx;
        const bool source_order = _trade_orders.sources[order] == cell_idx;
        const bool is_inbound = destination_order &&
            _trade_orders.cargo_delivered[order] == 0;
        const bool is_outbound = source_order &&
            _trade_orders.cargo_delivered[order] == 0;
        if (!destination_order && !source_order) continue;
        if ((is_inbound || is_outbound) &&
            (next_arrival < 0 || _trade_orders.arrival_days[order] < next_arrival))
            next_arrival = _trade_orders.arrival_days[order];
        if (destination_order) inbound_escrow += _trade_orders.cash_escrow[order];
        if (source_order) outbound_escrow += _trade_orders.cash_escrow[order];
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            const int32_t good = _trade_orders.line_goods[line];
            if (is_inbound) inbound[good] += _trade_orders.line_quantities[line];
            if (is_outbound) outbound[good] += _trade_orders.line_quantities[line];
        }
    }
    for (int32_t g = 0; g < _market.good_count; ++g) {
        good_ids.push_back(String(_good_ids[g].c_str()));
        technology_available.push_back(good_available(cell_idx, g, false) ? 1 : 0);
        stock.push_back(_market.stock[_market.index(market, g)]);
        price.push_back(_market.price[_market.index(market, g)]);
        demand_ema.push_back(_market.demand_ema[_market.index(market, g)]);
        shortage_q16.push_back(_market.last_shortage_q16[_market.index(market, g)]);
        const int32_t signal = market_signal_index(cell_idx, g);
        business_demand_ema.push_back(signal >= 0 ?
            _market_signals.business_demand_ema[signal] : 0);
        const int64_t desired_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_desired_business_demand.size())
            ? _epoch_desired_business_demand[signal] : 0;
        const int64_t funded_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_funded_business_demand.size())
            ? _epoch_funded_business_demand[signal] : 0;
        desired_business_demand.push_back(desired_business);
        funded_business_demand.push_back(funded_business);
        unfunded_business_demand.push_back(std::max<int64_t>(
            0, desired_business - funded_business));
        offered_supply_ema.push_back(signal >= 0 ?
            _market_signals.offered_supply_ema[signal] : 0);
        const int64_t realized = signal >= 0 ?
            _market_signals.realized_withdrawal_ema[signal] : 0;
        realized_withdrawal_ema.push_back(realized);
        const int64_t input_reserve = signal >= 0 && signal <
                static_cast<int32_t>(_production_input_reserve.size())
            ? _production_input_reserve[signal] : 0;
        production_input_reserve.push_back(input_reserve);
        household_available_stock.push_back(std::max<int64_t>(0,
            _market.stock[_market.index(market, g)] - input_reserve));
        const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->trade_flow_index(
            cell_idx, g, false);
        const int64_t export_ema = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
        const int64_t inventory_target = this->merchant_inventory_target(
            market, g, signal, realized, export_ema,
            signal >= 0 ? _market_signals.offered_supply_ema[signal] : 0,
            snapshot_saturation);
        merchant_inventory_target.push_back(inventory_target);
        merchant_procurement_shortfall.push_back(std::max<int64_t>(
            0, inventory_target - _market.stock[_market.index(market, g)]));
        trade_export_safety_stock.push_back(trade_export_floor(
            market, g, snapshot_saturation));
        trade_import_fill_target.push_back(trade_local_stock_target(
            market, g, snapshot_saturation));
        trade_relief_pressure_values_q16.push_back(static_cast<int32_t>(
            this->trade_relief_pressure_q16(market, g, snapshot_saturation)));
        const int32_t signal_clock = trade_signal_clock_index(cell_idx, g);
        const int64_t first_seen = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                _trade_signal_first_seen_day.size())
            ? _trade_signal_first_seen_day[signal_clock] : -1;
        const int64_t first_dispatch = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                _trade_signal_first_dispatch_day.size())
            ? _trade_signal_first_dispatch_day[signal_clock] : -1;
        trade_signal_age_days.push_back(first_seen >= 0 ? static_cast<int32_t>(
            std::clamp<int64_t>(_sample_day - first_seen, 0,
                                std::numeric_limits<int32_t>::max())) : 0);
        trade_first_dispatch_delay_days.push_back(
            first_seen >= 0 && first_dispatch >= first_seen
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    first_dispatch - first_seen, 0,
                    std::numeric_limits<int32_t>::max())) : -1);
        trade_last_attempt_day.push_back(signal_clock >= 0 && signal_clock <
                static_cast<int32_t>(_trade_signal_last_attempt_day.size())
            ? _trade_signal_last_attempt_day[signal_clock] : -1);
        trade_last_rejection_reason.push_back(signal_clock >= 0 && signal_clock <
                static_cast<int32_t>(_trade_signal_last_rejection_reason.size())
            ? _trade_signal_last_rejection_reason[signal_clock] :
                TRADE_SIGNAL_DIAG_NONE);
        trade_deadline_exceeded.push_back(first_seen >= 0 && first_dispatch < 0 &&
            _sample_day - first_seen > _trade_response_days ? 1 : 0);
        cost_anchor_price.push_back(signal >= 0 ?
            _market_signals.cost_anchor_price[signal] : 0);
        const PricePressure pressure = price_pressure(
            market, g, _market.demand_ema[_market.index(market, g)],
            _market.stock[_market.index(market, g)],
            _market.last_shortage_q16[_market.index(market, g)], signal,
            snapshot_saturation);
        pressure_excess_q16.push_back(static_cast<int32_t>(pressure.excess_q16));
        price_inventory_target.push_back(pressure.inventory_target);
        pressure_inventory_q16.push_back(static_cast<int32_t>(pressure.inventory_q16));
        pressure_shortage_q16.push_back(static_cast<int32_t>(pressure.shortage_q16));
        pressure_cost_q16.push_back(static_cast<int32_t>(pressure.cost_q16));
        pressure_idle_q16.push_back(static_cast<int32_t>(pressure.idle_q16));
        pressure_total_q16.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            pressure.total_q16, std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max())));
        price_change_q16.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            pressure.change_q16, std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max())));
		trade_enabled.push_back(_good_trade_enabled[g]);
		transport_load_per_unit_q16.push_back(_good_transport_load_per_unit_q16[g]);
		trade_import_ema.push_back(flow >= 0 ? _trade_flows.import_ema[flow] : 0);
		trade_export_ema.push_back(flow >= 0 ? _trade_flows.export_ema[flow] : 0);
		trade_inbound.push_back(inbound[g]);
		trade_outbound.push_back(outbound[g]);
		category_ids.push_back(String(_good_category_ids[g].c_str()));
		storage_modes.push_back(_good_storage_modes[g]);
		monetary_issue_values.push_back(_good_monetary_issue_values[g]);
		for (int32_t k = _good_technology_tag_offsets[g];
			 k < _good_technology_tag_offsets[g + 1]; ++k) {
			technology_tags.push_back(String(_good_technology_tags[k].c_str()));
		}
		technology_tag_offsets.push_back(technology_tags.size());
    }
    out["good_ids"] = good_ids;
    out["stock"] = stock;
    out["price"] = price;
    out["demand_ema"] = demand_ema;
    out["business_demand_ema"] = business_demand_ema;
    out["desired_business_demand"] = desired_business_demand;
    out["funded_business_demand"] = funded_business_demand;
    out["unfunded_business_demand"] = unfunded_business_demand;
    out["offered_supply_ema"] = offered_supply_ema;
    out["realized_withdrawal_ema"] = realized_withdrawal_ema;
    out["production_input_reserve"] = production_input_reserve;
    out["household_available_stock"] = household_available_stock;
    out["merchant_inventory_target"] = merchant_inventory_target;
    out["merchant_procurement_shortfall"] = merchant_procurement_shortfall;
    out["trade_export_safety_stock"] = trade_export_safety_stock;
    out["trade_import_fill_target"] = trade_import_fill_target;
    out["trade_relief_pressure_q16"] = trade_relief_pressure_values_q16;
    out["trade_signal_age_days"] = trade_signal_age_days;
    out["trade_first_dispatch_delay_days"] = trade_first_dispatch_delay_days;
    out["trade_last_attempt_day"] = trade_last_attempt_day;
    out["trade_last_rejection_reason"] = trade_last_rejection_reason;
    out["trade_deadline_exceeded"] = trade_deadline_exceeded;
    out["cost_anchor_price"] = cost_anchor_price;
    out["shortage_q16"] = shortage_q16;
    out["price_pressure_excess_q16"] = pressure_excess_q16;
    out["price_inventory_target"] = price_inventory_target;
    out["price_pressure_inventory_q16"] = pressure_inventory_q16;
    out["price_pressure_shortage_q16"] = pressure_shortage_q16;
    out["price_pressure_cost_q16"] = pressure_cost_q16;
    out["price_pressure_idle_q16"] = pressure_idle_q16;
    out["price_pressure_total_q16"] = pressure_total_q16;
    out["price_change_q16"] = price_change_q16;
    out["price_preview_saturation_count"] = snapshot_saturation;
	out["good_category_ids"] = category_ids;
	out["good_storage_modes"] = storage_modes;
	out["good_monetary_issue_values"] = monetary_issue_values;
	out["good_technology_tag_offsets"] = technology_tag_offsets;
	out["good_technology_tags"] = technology_tags;
	out["good_technology_available"] = technology_available;
	out["good_trade_enabled"] = trade_enabled;
	out["good_transport_load_per_unit_q16"] = transport_load_per_unit_q16;
	out["trade_import_ema"] = trade_import_ema;
	out["trade_export_ema"] = trade_export_ema;
	out["trade_inbound"] = trade_inbound;
	out["trade_outbound"] = trade_outbound;
	out["trade_next_arrival_day"] = next_arrival;
	out["trade_inbound_escrow_cash"] = inbound_escrow;
	out["trade_outbound_escrow_cash"] = outbound_escrow;
    PackedInt64Array merchant_handles;
    PackedInt64Array merchant_population;
    PackedInt64Array merchant_funds;
    // Merchant CSR is rebuilt only after structural commit. Scan this one
    // selected cell so a live query remains valid between structural slices.
    _population.for_each_in_cell(cell_idx, [&](int32_t slot) {
        if (!is_merchant_slot(slot)) return;
        merchant_handles.push_back(static_cast<int64_t>(_population.handle_for_slot(slot)));
        merchant_population.push_back(_population.population[slot]);
        merchant_funds.push_back(_population.funds[slot]);
    });
    out["merchant_handles"] = merchant_handles;
    out["merchant_population"] = merchant_population;
    out["merchant_funds"] = merchant_funds;
    return out;
}

Dictionary NativeEconomyRuntime::building_cell_snapshot(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["epoch_id"] = _epoch_id;
    out["period_days"] = std::max(1, _epoch_days);
    PackedStringArray type_ids;
    PackedInt64Array type_counts;
    PackedInt64Array wage_per_employee_per_day;
    PackedInt32Array target_operating_margin_q16;
    PackedInt32Array supply_price_elasticity_q16;
	PackedInt32Array building_kinds;
	PackedInt32Array upgrade_family_indices;
	PackedInt32Array upgrade_tiers;
	PackedInt32Array highest_available_tiers;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
	PackedByteArray technology_available;
	PackedByteArray construction_available;
	technology_tag_offsets.push_back(0);
    type_counts.resize(static_cast<int64_t>(_building_types.size()));
    type_counts.fill(0);
    for (const std::string &id : _building_type_ids) type_ids.push_back(String(id.c_str()));
    for (const BuildingType &type : _building_types) {
        wage_per_employee_per_day.push_back(type.wage_per_employee_per_day);
        target_operating_margin_q16.push_back(type.target_operating_margin_q16);
        supply_price_elasticity_q16.push_back(type.supply_price_elasticity_q16);
    }
	for (size_t i = 0; i < _building_types.size(); ++i) {
		building_kinds.push_back(_building_types[i].kind);
		upgrade_family_indices.push_back(_building_upgrade_family_indices[i]);
		upgrade_tiers.push_back(_building_upgrade_tiers[i]);
		technology_available.push_back(building_available(
			cell_idx, static_cast<int32_t>(i), false) ? 1 : 0);
		construction_available.push_back(building_constructible(
			cell_idx, static_cast<int32_t>(i), false) ? 1 : 0);
		int32_t highest_tier = 0;
		const int32_t family = _building_upgrade_family_indices[i];
		if (family >= 0) {
			for (size_t candidate = 0; candidate < _building_types.size(); ++candidate) {
				if (_building_upgrade_family_indices[candidate] == family &&
					building_available(cell_idx, static_cast<int32_t>(candidate), false)) {
					highest_tier = std::max(highest_tier, _building_upgrade_tiers[candidate]);
				}
			}
		}
		highest_available_tiers.push_back(highest_tier);
		for (int32_t k = _building_technology_tag_offsets[i];
			 k < _building_technology_tag_offsets[i + 1]; ++k) {
			technology_tags.push_back(String(_building_technology_tags[k].c_str()));
		}
		technology_tag_offsets.push_back(technology_tags.size());
	}
    PackedInt32Array group_type_ids;
    PackedInt32Array owner_signature_ids;
    PackedInt64Array group_counts;
    PackedInt64Array owner_capacity;
    PackedInt64Array owner_required;
    PackedInt64Array projected_owner_income;
    PackedInt64Array filled_owner;
    PackedInt64Array owner_openings;
    PackedInt32Array employee_fill_offsets;
    PackedInt32Array employee_profession_ids;
    PackedInt64Array employee_required;
    PackedInt64Array employee_filled;
    PackedInt32Array employee_wage_policies;
    PackedInt64Array employee_reference_wages;
    PackedInt64Array employee_contract_wages;
    PackedInt64Array employee_base_living_cost;
    PackedInt64Array employee_role_living_cost;
    PackedInt64Array employee_local_average_wage;
    PackedInt64Array employee_base_wage_due;
    PackedInt64Array employee_base_wage_paid;
    PackedInt64Array employee_bonus_due;
    PackedInt64Array employee_bonus_paid;
    PackedInt64Array capacity_q16;
    PackedInt64Array purchase_intent_capacity_q16;
    PackedInt64Array funded_capacity_q16;
    PackedInt64Array owner_working_capital_allocated;
    PackedInt64Array owner_livelihood_in_kind_credit;
    PackedInt64Array investment_score_q16;
    PackedInt64Array investment_payback_days;
    PackedInt32Array investment_rejection_reason;
    PackedInt32Array realized_profit_margin_q16;
    PackedInt32Array severe_loss_cycles;
    PackedInt32Array recovery_cycles;
    PackedByteArray operating_state;
    PackedInt64Array last_input;
    PackedInt64Array last_output;
    PackedInt64Array last_sold;
    PackedInt64Array last_discarded;
    PackedInt64Array last_retained;
    PackedInt64Array last_resource;
    PackedInt64Array last_resource_generated;
    PackedInt64Array last_revenue;
    PackedInt64Array last_input_cost;
    PackedInt64Array last_wages_paid;
    PackedInt64Array last_wages_due;
    PackedInt64Array last_expected_revenue;
    PackedInt64Array last_operating_cost;
    PackedInt32Array last_margin_gap_q16;
    PackedInt32Array planned_utilization_q16;
    PackedInt64Array last_base_wages_due;
    PackedInt64Array last_base_wages_paid;
    PackedInt64Array last_bonus_due;
    PackedInt64Array last_bonus_paid;
    PackedByteArray wage_suspended;
    PackedInt32Array group_input_selected_offsets;
    PackedInt32Array group_input_selected_good_ids;
    employee_fill_offsets.push_back(0);
    group_input_selected_offsets.push_back(0);
    const int32_t group_begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell_idx] : 0;
    const int32_t group_end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell_idx + 1] : 0;
    for (int32_t group_idx = group_begin; group_idx < group_end; ++group_idx) {
        const BuildingGroup &group = _buildings[group_idx];
        if (group.cell != cell_idx || group.count <= 0) continue;
        type_counts.set(group.type_id, type_counts[group.type_id] + group.count);
        const BuildingType &type = _building_types[group.type_id];
        int64_t snapshot_sat = 0;
        const int64_t full_owner_capacity = saturating_mul(
            group.count, type.owner_slots_per_building, snapshot_sat);
        const int64_t planned_owner_required = group.planned_utilization_q16 > 0
            ? full_owner_capacity : 0;
        group_type_ids.push_back(group.type_id);
        owner_signature_ids.push_back(group.owner_signature_id);
        group_counts.push_back(group.count);
        owner_capacity.push_back(full_owner_capacity);
        owner_required.push_back(planned_owner_required);
        projected_owner_income.push_back(projected_owner_income_per_day(
            group, snapshot_sat));
        filled_owner.push_back(group.filled_owner);
        owner_openings.push_back(std::max<int64_t>(
            0, planned_owner_required - group.filled_owner));
        capacity_q16.push_back(group.last_capacity_q16);
        purchase_intent_capacity_q16.push_back(group.purchase_intent_capacity_q16);
        funded_capacity_q16.push_back(group_idx < static_cast<int32_t>(
            _building_funded_capacity_q16.size())
            ? _building_funded_capacity_q16[group_idx] : group.last_capacity_q16);
        owner_working_capital_allocated.push_back(group_idx < static_cast<int32_t>(
            _building_working_capital_allocated.size())
            ? _building_working_capital_allocated[group_idx] : 0);
        owner_livelihood_in_kind_credit.push_back(group_idx < static_cast<int32_t>(
            _building_owner_livelihood_credit.size())
            ? _building_owner_livelihood_credit[group_idx] : 0);
        investment_score_q16.push_back(group_idx < static_cast<int32_t>(
            _building_investment_score_q16.size())
            ? _building_investment_score_q16[group_idx] : 0);
        investment_payback_days.push_back(group_idx < static_cast<int32_t>(
            _building_investment_payback_days.size())
            ? _building_investment_payback_days[group_idx] : 0);
        investment_rejection_reason.push_back(group_idx < static_cast<int32_t>(
            _building_investment_rejection.size())
            ? _building_investment_rejection[group_idx] : 0);
        realized_profit_margin_q16.push_back(group.realized_profit_margin_q16);
        severe_loss_cycles.push_back(group.severe_loss_cycles);
        recovery_cycles.push_back(group.recovery_cycles);
        operating_state.push_back(group.operating_state);
        last_input.push_back(group.last_input);
        last_output.push_back(group.last_output);
        last_sold.push_back(group.last_sold);
        last_discarded.push_back(group.last_discarded);
        last_retained.push_back(std::max<int64_t>(
            0, group.last_output - group.last_sold - group.last_discarded));
        last_resource.push_back(group.last_resource);
        last_resource_generated.push_back(group.last_resource_generated);
        last_revenue.push_back(group.last_revenue);
        last_input_cost.push_back(group.last_input_cost);
        last_wages_paid.push_back(group.last_wages_paid);
        last_wages_due.push_back(group.last_wages_due);
        last_expected_revenue.push_back(group.last_expected_revenue);
        last_operating_cost.push_back(group.last_operating_cost);
        last_margin_gap_q16.push_back(group.last_margin_gap_q16);
        planned_utilization_q16.push_back(group.planned_utilization_q16);
        last_base_wages_due.push_back(group.last_base_wages_due);
        last_base_wages_paid.push_back(group.last_base_wages_paid);
        last_bonus_due.push_back(group.last_bonus_due);
        last_bonus_paid.push_back(group.last_bonus_paid);
        wage_suspended.push_back(group.wage_suspended);
        for (int32_t input = 0; input < type.input_count; ++input) {
            const int32_t index = group.last_input_selection_begin + input;
            group_input_selected_good_ids.push_back(
                index >= 0 && index < static_cast<int32_t>(
                    _building_last_input_selected_goods.size())
                    ? _building_last_input_selected_goods[index] : -1);
        }
        group_input_selected_offsets.push_back(group_input_selected_good_ids.size());
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            employee_profession_ids.push_back(role.profession_id);
            const int32_t role_index = group.employee_fill_begin + r;
            employee_wage_policies.push_back(role.wage_policy);
            employee_reference_wages.push_back(role.reference_wage_per_day);
            employee_contract_wages.push_back(_building_role_contract_wage[role_index]);
            employee_base_living_cost.push_back(
                _building_role_base_living_cost[role_index]);
            employee_role_living_cost.push_back(
                _building_role_living_cost[role_index]);
            employee_local_average_wage.push_back(
                _building_role_local_average_wage[role_index]);
            employee_base_wage_due.push_back(
                _building_role_base_wage_due[role_index]);
            employee_base_wage_paid.push_back(
                _building_role_base_wage_paid[role_index]);
            employee_bonus_due.push_back(_building_role_bonus_due[role_index]);
            employee_bonus_paid.push_back(_building_role_bonus_paid[role_index]);
            const int64_t full_required = saturating_mul(
                group.count, role.slots_per_building, snapshot_sat);
            int64_t planned_required = mul_div_sat(
                full_required, group.planned_utilization_q16, Q16_ONE, snapshot_sat);
            if (planned_required == 0 && full_required > 0 &&
                group.planned_utilization_q16 > 0) planned_required = 1;
            employee_required.push_back(planned_required);
            employee_filled.push_back(_building_employee_filled[group.employee_fill_begin + r]);
        }
        employee_fill_offsets.push_back(employee_profession_ids.size());
    }
    PackedInt32Array construction_types;
    PackedInt32Array construction_owners;
    PackedInt64Array construction_counts;
    PackedInt64Array construction_ready_days;
    for (const PendingConstruction &pending : _pending_construction) {
        if (pending.cell != cell_idx) continue;
        construction_types.push_back(pending.type_id);
        construction_owners.push_back(pending.owner_signature_id);
        construction_counts.push_back(pending.count);
        construction_ready_days.push_back(pending.ready_day);
    }
    out["building_type_ids"] = type_ids;
    out["building_counts_by_type"] = type_counts;
    out["wage_per_employee_per_day_by_type"] = wage_per_employee_per_day;
    out["target_operating_margin_q16_by_type"] = target_operating_margin_q16;
    out["supply_price_elasticity_q16_by_type"] = supply_price_elasticity_q16;
	out["building_kinds"] = building_kinds;
	PackedStringArray upgrade_family_ids;
	for (const std::string &id : _building_upgrade_family_ids)
		upgrade_family_ids.push_back(String(id.c_str()));
	out["building_upgrade_family_ids"] = upgrade_family_ids;
	out["building_upgrade_family_indices"] = upgrade_family_indices;
	out["building_upgrade_tiers"] = upgrade_tiers;
	out["building_highest_available_tiers"] = highest_available_tiers;
	out["building_technology_tag_offsets"] = technology_tag_offsets;
	out["building_technology_tags"] = technology_tags;
	out["building_technology_available"] = technology_available;
	out["building_construction_available"] = construction_available;
    out["group_type_ids"] = group_type_ids;
    out["owner_signature_ids"] = owner_signature_ids;
    out["group_counts"] = group_counts;
    out["owner_capacity"] = owner_capacity;
    out["owner_required"] = owner_required;
    out["projected_owner_income_per_day"] = projected_owner_income;
    out["filled_owner"] = filled_owner;
    out["owner_openings"] = owner_openings;
    out["employee_fill_offsets"] = employee_fill_offsets;
    out["employee_profession_ids"] = employee_profession_ids;
    out["employee_required"] = employee_required;
    out["employee_filled"] = employee_filled;
    out["employee_wage_policies"] = employee_wage_policies;
    out["employee_reference_wages_per_day"] = employee_reference_wages;
    out["employee_contract_wages_per_day"] = employee_contract_wages;
    out["employee_base_living_cost_per_day"] = employee_base_living_cost;
    out["employee_role_living_cost_per_day"] = employee_role_living_cost;
    out["employee_local_average_wage_per_day"] = employee_local_average_wage;
    out["employee_base_wage_due"] = employee_base_wage_due;
    out["employee_base_wage_paid"] = employee_base_wage_paid;
    out["employee_bonus_due"] = employee_bonus_due;
    out["employee_bonus_paid"] = employee_bonus_paid;
    out["capacity_q16"] = capacity_q16;
    out["purchase_intent_capacity_q16"] = purchase_intent_capacity_q16;
    out["funded_capacity_q16"] = funded_capacity_q16;
    out["owner_working_capital_allocated"] = owner_working_capital_allocated;
    out["owner_livelihood_in_kind_credit"] = owner_livelihood_in_kind_credit;
    out["investment_score_q16"] = investment_score_q16;
    out["investment_payback_days"] = investment_payback_days;
    out["investment_rejection_reason"] = investment_rejection_reason;
    out["realized_profit_margin_q16"] = realized_profit_margin_q16;
    out["severe_loss_cycles"] = severe_loss_cycles;
    out["recovery_cycles"] = recovery_cycles;
    out["operating_state"] = operating_state;
    out["last_input"] = last_input;
    out["last_output"] = last_output;
    out["last_sold"] = last_sold;
    out["last_discarded"] = last_discarded;
    out["last_retained"] = last_retained;
    out["last_resource"] = last_resource;
    out["last_resource_generated"] = last_resource_generated;
    out["last_revenue"] = last_revenue;
    out["last_input_cost"] = last_input_cost;
    out["last_wages_paid"] = last_wages_paid;
    out["last_wages_due"] = last_wages_due;
    out["last_expected_revenue"] = last_expected_revenue;
    out["last_operating_cost"] = last_operating_cost;
    out["last_margin_gap_q16"] = last_margin_gap_q16;
    out["planned_utilization_q16"] = planned_utilization_q16;
    out["last_base_wages_due"] = last_base_wages_due;
    out["last_base_wages_paid"] = last_base_wages_paid;
    out["last_bonus_due"] = last_bonus_due;
    out["last_bonus_paid"] = last_bonus_paid;
    out["wage_suspended"] = wage_suspended;
    out["group_input_selected_offsets"] = group_input_selected_offsets;
    out["group_input_selected_good_ids"] = group_input_selected_good_ids;
    PackedInt32Array labor_professions;
    PackedInt64Array labor_contract_ema;
    PackedInt64Array labor_paid_ema;
    PackedInt64Array labor_base_cost;
    PackedInt64Array labor_role_cost;
    PackedInt64Array labor_job_days;
    PackedInt32Array labor_pay_ratio;
    for (int32_t i = _labor_signals.cell_offsets[cell_idx];
         i < _labor_signals.cell_offsets[cell_idx + 1]; ++i) {
        labor_professions.push_back(_labor_signals.profession_ids[i]);
        labor_contract_ema.push_back(_labor_signals.contract_wage_ema[i]);
        labor_paid_ema.push_back(_labor_signals.paid_wage_ema[i]);
        labor_base_cost.push_back(_labor_signals.base_living_cost[i]);
        labor_role_cost.push_back(_labor_signals.role_living_cost[i]);
        labor_job_days.push_back(_labor_signals.job_days[i]);
        labor_pay_ratio.push_back(_labor_signals.pay_ratio_q16[i]);
    }
    out["labor_market_profession_ids"] = labor_professions;
    out["labor_market_contract_wage_ema"] = labor_contract_ema;
    out["labor_market_paid_wage_ema"] = labor_paid_ema;
    out["labor_market_base_living_cost"] = labor_base_cost;
    out["labor_market_role_living_cost"] = labor_role_cost;
    out["labor_market_job_days"] = labor_job_days;
    out["labor_market_pay_ratio_q16"] = labor_pay_ratio;
    out["construction_type_ids"] = construction_types;
    out["construction_owner_signature_ids"] = construction_owners;
    out["construction_counts"] = construction_counts;
    out["construction_ready_days"] = construction_ready_days;
    return out;
}

Dictionary NativeEconomyRuntime::trade_orders_for_cell(
        int32_t cell_idx, int32_t offset, int32_t limit) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    offset = std::max(0, offset);
    limit = std::clamp(limit, 1, 256);
    int32_t total = 0;
    PackedInt64Array order_ids;
    PackedInt32Array directions;
    PackedInt32Array sources;
    PackedInt32Array destinations;
    PackedInt32Array countries;
    PackedInt64Array departure_days;
    PackedInt64Array arrival_days;
    PackedInt64Array cash_escrow;
    PackedInt64Array capacity_work;
    PackedByteArray states;
    PackedByteArray cargo_delivered;
    PackedInt32Array line_offsets;
    PackedInt32Array line_goods;
    PackedInt64Array line_quantities;
    PackedInt32Array line_unit_prices;
    line_offsets.push_back(0);
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        const bool outbound = _trade_orders.sources[order] == cell_idx;
        const bool inbound = _trade_orders.destinations[order] == cell_idx;
        if (!outbound && !inbound) continue;
        if (total++ < offset || order_ids.size() >= limit) continue;
        order_ids.push_back(_trade_orders.ids[order]);
        directions.push_back(outbound ? -1 : 1);
        sources.push_back(_trade_orders.sources[order]);
        destinations.push_back(_trade_orders.destinations[order]);
        countries.push_back(_trade_orders.countries[order]);
        departure_days.push_back(_trade_orders.departure_days[order]);
        arrival_days.push_back(_trade_orders.arrival_days[order]);
        cash_escrow.push_back(_trade_orders.cash_escrow[order]);
        capacity_work.push_back(_trade_orders.capacity_work[order]);
        states.push_back(_trade_orders.states[order]);
        cargo_delivered.push_back(_trade_orders.cargo_delivered[order]);
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            line_goods.push_back(_trade_orders.line_goods[line]);
            line_quantities.push_back(_trade_orders.line_quantities[line]);
            line_unit_prices.push_back(_trade_orders.line_unit_prices[line]);
        }
        line_offsets.push_back(line_goods.size());
    }
    out["ok"] = true;
    out["offset"] = offset;
    out["limit"] = limit;
    out["total"] = total;
    out["has_more"] = offset + order_ids.size() < total;
    out["order_ids"] = order_ids;
    out["directions"] = directions;
    out["source_cells"] = sources;
    out["destination_cells"] = destinations;
    out["country_slots"] = countries;
    out["departure_days"] = departure_days;
    out["arrival_days"] = arrival_days;
    out["cash_escrow"] = cash_escrow;
    out["capacity_work"] = capacity_work;
    out["states"] = states;
    out["cargo_delivered"] = cargo_delivered;
    out["line_offsets"] = line_offsets;
    out["line_good_ids"] = line_goods;
    out["line_quantities"] = line_quantities;
    out["line_unit_prices"] = line_unit_prices;
    return out;
}

Dictionary NativeEconomyRuntime::fixed_math_probe(const Dictionary &vectors) const {
    Dictionary out;
    const std::vector<int64_t> a = packed_i64(vectors, "a");
    const std::vector<int64_t> b = packed_i64(vectors, "b");
    const std::vector<int64_t> divisors = packed_i64(vectors, "divisors");
    if (a.size() != b.size() || a.size() != divisors.size()) {
        out["ok"] = false;
        out["reason"] = "fixed_math_vector_size_mismatch";
        return out;
    }
    PackedInt64Array results;
    results.resize(static_cast<int64_t>(a.size()));
    int64_t saturation_count = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        results.set(static_cast<int64_t>(i), mul_div_sat(a[i], b[i], divisors[i],
                                                        saturation_count));
    }
    out["ok"] = true;
    out["results"] = results;
    out["saturation_count"] = saturation_count;
    return out;
}

int64_t NativeEconomyRuntime::state_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u64 = [&](uint64_t value) {
        for (int i = 0; i < 8; ++i) {
            hash ^= static_cast<uint8_t>((value >> (i * 8)) & 0xffULL);
            hash *= 1099511628211ULL;
        }
    };
    mix_u64(static_cast<uint64_t>(_trade_runtime_mode != 2 &&
        _catalog_compat_hash_v10 != 0 ? _catalog_compat_hash_v10 : _catalog_hash));
    mix_u64(static_cast<uint64_t>(_building_catalog_hash));
    mix_u64(static_cast<uint64_t>(_cell_count));
    mix_u64(static_cast<uint64_t>(_epoch_id));
    mix_u64(static_cast<uint64_t>(_epoch_days));
    mix_u64(static_cast<uint64_t>(_last_committed_day));
    mix_u64(static_cast<uint64_t>(_environment_day));
    mix_u64(static_cast<uint64_t>(_environment_hash));
    mix_u64(static_cast<uint64_t>(_country_runtime == nullptr ? 0 : _country_runtime->state_hash()));
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        mix_u64(static_cast<uint64_t>(_cell_last_settlement_day[cell]));
        mix_u64(_cell_settlement_generation[cell]);
        mix_u64(_cell_price_stock_gen[cell]);
        mix_u64(_cell_owner_cash_gen[cell]);
        mix_u64(_cell_population_gen[cell]);
        mix_u64(_cell_building_structure_gen[cell]);
        mix_u64(_cell_technology_gen[cell]);
        mix_u64(_cell_resource_gen[cell]);
        mix_u64(_cell_trade_gen[cell]);
    }
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        if (_population.active[slot] == 0) continue;
        mix_u64(slot);
        mix_u64(_population.generation[slot]);
        mix_u64(_population.signature_id[slot]);
        mix_u64(static_cast<uint64_t>(_population.population[slot]));
        mix_u64(static_cast<uint64_t>(_population.funds[slot]));
        mix_u64(static_cast<uint64_t>(_population.epoch_income[slot]));
        mix_u64(static_cast<uint64_t>(_population.epoch_expense[slot]));
        mix_u64(static_cast<uint64_t>(_population.income_ema[slot]));
        mix_u64(_population.needs_satisfaction[slot]);
        mix_u64(_population.worst_need_id[slot]);
        mix_u64(_population.flags[slot]);
        mix_u64(static_cast<uint64_t>(_population.demography_residual[slot]));
        mix_u64(static_cast<uint64_t>(_population.owner_employed[slot]));
        mix_u64(static_cast<uint64_t>(_population.employee_employed[slot]));
    }
    for (int32_t mapping : _market.cell_to_market) mix_u64(static_cast<uint32_t>(mapping));
    for (int64_t value : _market.stock) mix_u64(static_cast<uint64_t>(value));
    for (int32_t value : _market.price) mix_u64(static_cast<uint32_t>(value));
    for (int64_t value : _market.demand_ema) mix_u64(static_cast<uint64_t>(value));
    for (uint16_t value : _market.last_shortage_q16) mix_u64(value);
    for (const Command &cmd : _pending_commands) {
        mix_u64(static_cast<uint32_t>(cmd.opcode));
        mix_u64(static_cast<uint64_t>(cmd.effective_day));
        mix_u64(static_cast<uint64_t>(cmd.sequence));
        mix_u64(cmd.target_handle);
        mix_u64(static_cast<uint32_t>(cmd.i32_0));
        mix_u64(static_cast<uint32_t>(cmd.i32_1));
        mix_u64(static_cast<uint64_t>(cmd.i64_0));
        mix_u64(static_cast<uint64_t>(cmd.i64_1));
    }
    for (const BuildingGroup &group : _buildings) {
        mix_u64(static_cast<uint32_t>(group.cell));
        mix_u64(static_cast<uint32_t>(group.type_id));
        mix_u64(static_cast<uint32_t>(group.owner_signature_id));
        mix_u64(static_cast<uint64_t>(group.count));
        mix_u64(static_cast<uint64_t>(group.filled_owner));
        mix_u64(static_cast<uint64_t>(group.last_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_input));
        mix_u64(static_cast<uint64_t>(group.last_output));
        mix_u64(static_cast<uint64_t>(group.last_sold));
        mix_u64(static_cast<uint64_t>(group.last_discarded));
        mix_u64(static_cast<uint64_t>(group.last_resource));
        mix_u64(static_cast<uint64_t>(group.last_resource_generated));
        mix_u64(static_cast<uint64_t>(group.last_revenue));
        mix_u64(static_cast<uint64_t>(group.last_input_cost));
        mix_u64(static_cast<uint64_t>(group.last_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_expected_revenue));
        mix_u64(static_cast<uint64_t>(group.last_operating_cost));
        mix_u64(static_cast<uint32_t>(group.last_margin_gap_q16));
        mix_u64(static_cast<uint32_t>(group.planned_utilization_q16));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_bonus_paid));
        mix_u64(static_cast<uint64_t>(group.last_bonus_due));
        mix_u64(group.wage_suspended);
        mix_u64(static_cast<uint64_t>(group.purchase_intent_capacity_q16));
        mix_u64(static_cast<uint32_t>(group.realized_profit_margin_q16));
        mix_u64(group.severe_loss_cycles);
        mix_u64(group.recovery_cycles);
        mix_u64(group.operating_state);
    }
    for (int32_t value : _market_signals.cell_offsets) mix_u64(static_cast<uint32_t>(value));
    for (size_t i = 0; i < _market_signals.good_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_market_signals.good_ids[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.business_demand_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.offered_supply_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.realized_withdrawal_ema[i]));
        mix_u64(static_cast<uint32_t>(_market_signals.cost_anchor_price[i]));
    }
    for (int64_t value : _building_employee_filled) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_contract_wage) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_base_living_cost) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_living_cost) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_local_average_wage) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_base_wage_due) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_base_wage_paid) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_bonus_due) mix_u64(static_cast<uint64_t>(value));
    for (int64_t value : _building_role_bonus_paid) mix_u64(static_cast<uint64_t>(value));
    for (int32_t value : _labor_signals.cell_offsets) mix_u64(static_cast<uint32_t>(value));
    for (size_t i = 0; i < _labor_signals.profession_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_labor_signals.profession_ids[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.base_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.role_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.contract_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.paid_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.job_days[i]));
        mix_u64(static_cast<uint32_t>(_labor_signals.pay_ratio_q16[i]));
    }
    for (const PendingConstruction &pending : _pending_construction) {
        mix_u64(static_cast<uint32_t>(pending.cell));
        mix_u64(static_cast<uint32_t>(pending.type_id));
        mix_u64(static_cast<uint32_t>(pending.owner_signature_id));
        mix_u64(static_cast<uint64_t>(pending.count));
        mix_u64(static_cast<uint64_t>(pending.ready_day));
        mix_u64(static_cast<uint64_t>(pending.sequence));
    }
    if (_trade_runtime_mode == 2 || !_trade_orders.ids.empty() ||
        !_trade_flows.cells.empty()) {
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        mix_u64(static_cast<uint64_t>(_trade_orders.ids[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.sources[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.destinations[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.countries[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.departure_days[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.arrival_days[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.cash_escrow[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.capacity_work[order]));
        mix_u64(_trade_orders.states[order]);
        mix_u64(_trade_orders.cargo_delivered[order]);
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            mix_u64(static_cast<uint32_t>(_trade_orders.line_goods[line]));
            mix_u64(static_cast<uint64_t>(_trade_orders.line_quantities[line]));
            mix_u64(static_cast<uint32_t>(_trade_orders.line_unit_prices[line]));
        }
        for (int32_t seller = _trade_orders.seller_offsets[order];
             seller < _trade_orders.seller_offsets[order + 1]; ++seller) {
            mix_u64(_trade_orders.seller_handles[seller]);
            mix_u64(static_cast<uint64_t>(_trade_orders.seller_weights[seller]));
        }
    }
    mix_u64(static_cast<uint64_t>(_trade_orders.next_id));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_trade_flows.cells[i]));
        mix_u64(static_cast<uint32_t>(_trade_flows.goods[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.import_ema[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.export_ema[i]));
    }
    }
    return static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
}

Dictionary NativeEconomyRuntime::reset(const String &reason) {
    _configured = false;
    _bootstrapped = false;
    _epoch_active = false;
    _fatal = false;
    _fatal_reason.clear();
    _stage = Stage::IDLE;
    _cell_count = 0;
    _catalog_hash = 0;
    _catalog_compat_hash_v6 = 0;
    _catalog_compat_hash_v7 = 0;
    _catalog_compat_hash_v8 = 0;
    _catalog_compat_hash_v10 = 0;
    _building_catalog_hash = 0;
    _building_catalog_compat_hash_v6 = 0;
    _epoch_id = 0;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _last_committed_day = -1;
    _next_submit_order = 1;
    _next_event_id = 1;
    _event_stream_hash = 1469598103934665603ULL;
    _event_evicted_count = 0;
    _first_evicted_event_id = 0;
    _trace_detail_truncated = 0;
    _trace_uncommitted_discarded = 0;
    _opening_totals = {};
    _closing_totals = {};
    clear_epoch_metrics();
    _population.clear(0);
    _market.clear();
    _market_signals.clear(0);
    _trade_topology.clear();
    _trade_plan.clear_transient();
    _trade_plan_reset_count = 0;
    _trade_topology_content_change_count = 0;
    _trade_last_plan_reset_reason = "none";
    _trade_orders.clear();
    _trade_flows.clear();
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _committed_cells.clear();
    _staging_cells.clear();
    _structural_touched_cells.clear();
    _population_changed_cells.clear();
    _publish_accum = {};
    _structural_funds_to_treasury = 0;
    _market_cell_offsets.clear();
    _market_cells.clear();
    _merchant_primary_slot.clear();
    _merchant_offsets.clear();
    _merchant_slots.clear();
    _trace_cell_mask.clear();
    _pending_trace_cell_mask.clear();
    _trace_filter_pending = false;
    _inspector_trace_cell = -1;
    _pending_inspector_trace_cell = -1;
    _inspector_trace_pending = false;
    _staging_events = {};
    _committed_event_batches.clear();
    _audit_history.clear();
    _event_consumer_ack.clear();
    _event_archive = {};
    _environment_temperature_q16.clear();
    _environment_moisture_q16.clear();
    _environment_snow_q16.clear();
    _environment_weather_q16.clear();
    _building_elevation_q16.clear();
    _building_terrain.clear();
    _building_landform.clear();
    _building_vegetation.clear();
    _building_is_water.clear();
    _building_has_river.clear();
    _building_neighbors.clear();
    _resource_snapshot.clear();
    _resource_remaining.clear();
    _resource_deltas.clear();
    _last_published_resource_deltas.clear();
    _epoch_cell_country.clear();
    _epoch_country_technologies.clear();
    _epoch_country_count = 0;
    _epoch_country_technology_words = 0;
    _epoch_country_generation = 0;
    _epoch_country_hash = 0;
    _epoch_country_topology_hash = 0;
    _technology_words = 0;
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _cell_last_settlement_day.clear();
    _cell_settlement_generation.clear();
    _cell_price_stock_gen.clear();
    _cell_owner_cash_gen.clear();
    _cell_population_gen.clear();
    _cell_building_structure_gen.clear();
    _cell_technology_gen.clear();
    _cell_resource_gen.clear();
    _cell_trade_gen.clear();
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _employment_metrics_epoch_by_cell.clear();
    _employment_owner_jobs_by_cell.clear();
    _employment_employee_jobs_by_cell.clear();
    _employment_unemployed_by_cell.clear();
    _demand_basis_cache_day.clear();
    _demand_basis_variant_scores.clear();
    _demand_basis_variant_prices.clear();
    _demand_basis_need_score_sums.clear();
    _demand_basis_need_composites.clear();
    _demand_basis_need_environment.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _pending_construction.clear();
    _building_context_day = -1;
    _resource_deltas_ready = false;
    _environment_day = -1;
    _environment_hash = 0;
    _save = {};
    _restore = {};
    Dictionary out;
    out["ok"] = true;
    out["reason"] = reason;
    return out;
}

Dictionary NativeEconomyRuntime::begin_save(int32_t chunk_bytes) {
    Dictionary out;
    if (!_bootstrapped || _epoch_active || _fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                         : (_epoch_active ? "save_requires_committed_boundary"
                         : (_fatal ? "economy_fatal" : "save_restore_already_active"));
        return out;
    }
    if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
        _country_runtime->should_run(_last_committed_day)) {
        out["ok"] = false;
        out["reason"] = "save_requires_idle_country_runtime";
        return out;
    }
    _save = {};
    _save.active = true;
    _save.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    out["ok"] = true;
    out["chunk_bytes"] = _save.chunk_bytes;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash;
    out["committed_day"] = _last_committed_day;
    return out;
}

PackedByteArray NativeEconomyRuntime::read_save_chunk(int32_t max_bytes) {
    if (!_save.active || _save.end_emitted) return {};
    const int32_t budget = std::clamp(max_bytes > 0 ? max_bytes : _save.chunk_bytes,
                                      64 * 1024, 16 * 1024 * 1024);
    std::vector<uint8_t> payload;
    if (_save.section == SAVE_SECTION_HEADER) {
        append_le<int32_t>(payload, _cell_count);
        append_le<int32_t>(payload, _market.market_count);
        append_le<int32_t>(payload, _market.good_count);
        append_le<int32_t>(payload, static_cast<int32_t>(_population.page_next.size()));
        append_le<int64_t>(payload, _population.active_count);
        append_le<int32_t>(payload, _epoch_days);
        append_le<int64_t>(payload, _last_committed_day);
        append_le<int64_t>(payload, _epoch_id);
        append_le<int32_t>(payload, NativeCountryRuntime::SCHEMA_VERSION);
        append_le<uint64_t>(payload, _country_runtime->generation());
        append_le<uint64_t>(payload, static_cast<uint64_t>(_country_runtime->state_hash()));
        append_le<int64_t>(payload, _seed);
        append_le<int64_t>(payload, _catalog_hash);
        append_le<int64_t>(payload, _building_catalog_hash);
        append_le<int32_t>(payload, static_cast<int32_t>(_buildings.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_pending_construction.size()));
        append_le<int64_t>(payload, _environment_day);
        append_le<int64_t>(payload, _environment_hash);
        append_le<uint64_t>(payload, _next_submit_order);
        append_le<int64_t>(payload, MONEY_SCALE);
        append_le<int64_t>(payload, GOODS_SCALE);
        append_le<int64_t>(payload, Q16_ONE);
        append_le<int64_t>(payload, Q32_ONE);
        append_le<int32_t>(payload, static_cast<int32_t>(_pending_commands.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_audit_history.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_market_signals.good_ids.size()));
        append_le<int32_t>(payload,
                           static_cast<int32_t>(_labor_signals.profession_ids.size()));
        append_le<int64_t>(payload, _next_event_id);
        append_le<uint64_t>(payload, _event_stream_hash);
        append_le<int32_t>(payload, _trade_orders.size());
        append_le<int32_t>(payload, static_cast<int32_t>(_trade_flows.cells.size()));
        append_le<int64_t>(payload, _trade_orders.next_id);
        append_le<int32_t>(payload, _trade_runtime_mode);
        append_le<int64_t>(payload, _trade_capacity_per_merchant_q16);
        append_le<int32_t>(payload, _trade_speed_cost_per_day);
        append_le<int32_t>(payload, _trade_min_margin_q16);
        append_le<int32_t>(payload, _trade_target_count);
        append_le<int32_t>(payload, _trade_signal_pairs_per_slice);
        append_le<int32_t>(payload, _trade_route_searches_per_slice);
        append_le<int32_t>(payload, _trade_max_route_expansions);
        append_le<int32_t>(payload, _trade_route_cache_entries);
        append_le<int32_t>(payload, _trade_max_signals);
        append_le<int32_t>(payload, _trade_max_candidates);
        append_le<int32_t>(payload, _trade_max_orders);
        append_le<int32_t>(payload, _trade_flow_ema_alpha_q16);
        append_le<int32_t>(payload, _trade_max_stock_share_q16);
        append_le<int32_t>(payload, _building_severe_loss_threshold_q16);
        append_le<int32_t>(payload, _building_severe_loss_cycles);
        append_le<int32_t>(payload, _building_restart_margin_q16);
        append_le<int32_t>(payload, _building_restart_cycles);
        append_le<int32_t>(payload, _merchant_procurement_cash_reserve_q16);
        append_le<int32_t>(payload, _merchant_market_making_days_q16);
        append_le<int32_t>(payload, _trade_export_floor_days);
        append_le<int32_t>(payload, _trade_export_inventory_fraction_q16);
        append_le<int32_t>(payload, _trade_import_fill_fraction_q16);
        append_le<int32_t>(payload, _trade_response_days);
        append_le<int32_t>(payload, _investment_review_days);
        append_le<int32_t>(payload, _investment_min_shortage_q16);
        append_le<int32_t>(payload, _investment_min_utilization_q16);
        append_le<int32_t>(payload, _investment_max_payback_days);
        append_le<int32_t>(payload, _investment_operating_cycles);
        append_le<int32_t>(payload, _resource_min_reserve_q16);
        append_le<int32_t>(payload, _resource_safe_harvest_q16);
        append_le<int32_t>(payload, _resource_min_horizon_days);
        append_le<int32_t>(payload, _bullion_monthly_issue_cap_q16);
        append_le<int32_t>(payload, _producer_support_monthly_cap_q16);
        append_id_table(payload, _profession_ids);
        append_id_table(payload, _ethnicity_ids);
        append_id_table(payload, _good_ids);
        append_id_table(payload, _plan_ids);
        ++_save.section;
        return make_save_chunk(SAVE_SECTION_HEADER, 1, payload);
    }
    if (_save.section == SAVE_SECTION_PAGES) {
        const int32_t record_bytes = 12 + PAGE_SIZE * 79;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_population.page_next.size()),
                                              _save.page_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.page_cursor)) * record_bytes);
        const int32_t begin = _save.page_cursor;
        for (; _save.page_cursor < end; ++_save.page_cursor) {
            const int32_t page = _save.page_cursor;
            append_le<int32_t>(payload, page);
            append_le<int32_t>(payload, _population.page_next[page]);
            append_le<int32_t>(payload, _population.page_cell[page]);
            const int32_t base = page * PAGE_SIZE;
            for (int32_t lane = 0; lane < PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                append_le<uint8_t>(payload, _population.active[slot]);
                append_le<uint32_t>(payload, _population.signature_id[slot]);
                append_le<uint32_t>(payload, _population.generation[slot]);
                append_le<int64_t>(payload, _population.population[slot]);
                append_le<int64_t>(payload, _population.funds[slot]);
                append_le<int64_t>(payload, _population.epoch_income[slot]);
                append_le<int64_t>(payload, _population.epoch_expense[slot]);
                append_le<int64_t>(payload, _population.income_ema[slot]);
                append_le<uint16_t>(payload, _population.needs_satisfaction[slot]);
                append_le<uint16_t>(payload, _population.worst_need_id[slot]);
                append_le<uint16_t>(payload, _population.flags[slot]);
                append_le<int64_t>(payload, _population.demography_residual[slot]);
                append_le<int64_t>(payload, _population.owner_employed[slot]);
                append_le<int64_t>(payload, _population.employee_employed[slot]);
            }
        }
        if (_save.page_cursor >= static_cast<int32_t>(_population.page_next.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_PAGES,
                               static_cast<uint32_t>(_save.page_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_MARKETS) {
        const int32_t record_bytes = 4 + _market.good_count * 22;
        const int32_t max_records = std::max(1, (budget - 16) / std::max(1, record_bytes));
        const int32_t end = std::min(_market.market_count, _save.market_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.market_cursor)) * record_bytes);
        const int32_t begin = _save.market_cursor;
        for (; _save.market_cursor < end; ++_save.market_cursor) {
            const int32_t market = _save.market_cursor;
            append_le<int32_t>(payload, market);
            for (int32_t good = 0; good < _market.good_count; ++good) {
                const int64_t idx = _market.index(market, good);
                append_le<int64_t>(payload, _market.stock[idx]);
                append_le<int32_t>(payload, _market.price[idx]);
                append_le<int64_t>(payload, _market.demand_ema[idx]);
                append_le<uint16_t>(payload, _market.last_shortage_q16[idx]);
            }
        }
        if (_save.market_cursor >= _market.market_count) ++_save.section;
        return make_save_chunk(SAVE_SECTION_MARKETS,
                               static_cast<uint32_t>(_save.market_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CELLS) {
        const int32_t record_bytes = 68;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min(_cell_count, _save.cell_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.cell_cursor)) * record_bytes);
        const int32_t begin = _save.cell_cursor;
        for (; _save.cell_cursor < end; ++_save.cell_cursor) {
            append_le<int32_t>(payload, _save.cell_cursor);
            append_le<int32_t>(payload, _market.cell_to_market[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_temperature_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_moisture_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_snow_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_weather_q16[_save.cell_cursor]);
            append_le<int64_t>(payload, _cell_last_settlement_day[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_settlement_generation[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_price_stock_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_owner_cash_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_population_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_building_structure_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_technology_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_resource_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_trade_gen[_save.cell_cursor]);
            append_le<int32_t>(payload, _save.cell_cursor % ROLLING_PHASE_COUNT);
        }
        if (_save.cell_cursor >= _cell_count) ++_save.section;
        return make_save_chunk(SAVE_SECTION_CELLS,
                               static_cast<uint32_t>(_save.cell_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_COMMANDS) {
        constexpr int32_t record_bytes = 60;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_pending_commands.size()),
                                              _save.command_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.command_cursor)) * record_bytes);
        const int32_t begin = _save.command_cursor;
        for (; _save.command_cursor < end; ++_save.command_cursor) {
            const Command &cmd = _pending_commands[_save.command_cursor];
            append_le<int32_t>(payload, cmd.opcode);
            append_le<int64_t>(payload, cmd.effective_day);
            append_le<int64_t>(payload, cmd.sequence);
            append_le<uint64_t>(payload, cmd.target_handle);
            append_le<int32_t>(payload, cmd.i32_0);
            append_le<int32_t>(payload, cmd.i32_1);
            append_le<int64_t>(payload, cmd.i64_0);
            append_le<int64_t>(payload, cmd.i64_1);
            append_le<uint64_t>(payload, cmd.submit_order);
        }
        if (_save.command_cursor >= static_cast<int32_t>(_pending_commands.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_COMMANDS,
                               static_cast<uint32_t>(_save.command_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_BUILDINGS) {
        const int32_t max_records = std::max(1, (budget - 16) / 1024);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_buildings.size()),
                                              _save.building_cursor + max_records);
        const int32_t begin = _save.building_cursor;
        for (; _save.building_cursor < end; ++_save.building_cursor) {
            const BuildingGroup &group = _buildings[_save.building_cursor];
            append_le<int32_t>(payload, group.cell);
            append_le<int32_t>(payload, group.type_id);
            append_le<int32_t>(payload, group.owner_signature_id);
            append_le<int64_t>(payload, group.count);
            append_le<int64_t>(payload, group.filled_owner);
            append_le<int64_t>(payload, group.last_capacity_q16);
            append_le<int64_t>(payload, group.last_input);
            append_le<int64_t>(payload, group.last_output);
            append_le<int64_t>(payload, group.last_sold);
            append_le<int64_t>(payload, group.last_discarded);
            append_le<int64_t>(payload, group.last_resource);
            append_le<int64_t>(payload, group.last_resource_generated);
            append_le<int64_t>(payload, group.last_revenue);
            append_le<int64_t>(payload, group.last_input_cost);
            append_le<int64_t>(payload, group.last_wages_paid);
            append_le<int64_t>(payload, group.last_wages_due);
            append_le<int64_t>(payload, group.last_expected_revenue);
            append_le<int64_t>(payload, group.last_operating_cost);
            append_le<int32_t>(payload, group.last_margin_gap_q16);
            append_le<int32_t>(payload, group.planned_utilization_q16);
            append_le<int64_t>(payload, group.last_base_wages_paid);
            append_le<int64_t>(payload, group.last_base_wages_due);
            append_le<int64_t>(payload, group.last_bonus_paid);
            append_le<int64_t>(payload, group.last_bonus_due);
            append_le<uint8_t>(payload, group.wage_suspended);
            append_le<int64_t>(payload, group.purchase_intent_capacity_q16);
            append_le<int32_t>(payload, group.realized_profit_margin_q16);
            append_le<uint16_t>(payload, group.severe_loss_cycles);
            append_le<uint16_t>(payload, group.recovery_cycles);
            append_le<uint8_t>(payload, group.operating_state);
            const int32_t roles = _building_types[group.type_id].employee_count;
            append_le<int32_t>(payload, roles);
            for (int32_t r = 0; r < roles; ++r) {
                const int32_t index = group.employee_fill_begin + r;
                append_le<int64_t>(payload, _building_employee_filled[index]);
                append_le<int64_t>(payload, _building_role_contract_wage[index]);
                append_le<int64_t>(payload, _building_role_base_living_cost[index]);
                append_le<int64_t>(payload, _building_role_living_cost[index]);
                append_le<int64_t>(payload, _building_role_local_average_wage[index]);
                append_le<int64_t>(payload, _building_role_base_wage_due[index]);
                append_le<int64_t>(payload, _building_role_base_wage_paid[index]);
                append_le<int64_t>(payload, _building_role_bonus_due[index]);
                append_le<int64_t>(payload, _building_role_bonus_paid[index]);
            }
        }
        if (_save.building_cursor >= static_cast<int32_t>(_buildings.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_BUILDINGS,
                               static_cast<uint32_t>(_save.building_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CONSTRUCTION) {
        constexpr int32_t record_bytes = 36;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_pending_construction.size()),
                                              _save.construction_cursor + max_records);
        const int32_t begin = _save.construction_cursor;
        for (; _save.construction_cursor < end; ++_save.construction_cursor) {
            const PendingConstruction &pending = _pending_construction[_save.construction_cursor];
            append_le<int32_t>(payload, pending.cell);
            append_le<int32_t>(payload, pending.type_id);
            append_le<int32_t>(payload, pending.owner_signature_id);
            append_le<int64_t>(payload, pending.count);
            append_le<int64_t>(payload, pending.ready_day);
            append_le<int64_t>(payload, pending.sequence);
        }
        if (_save.construction_cursor >= static_cast<int32_t>(_pending_construction.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_CONSTRUCTION,
                               static_cast<uint32_t>(_save.construction_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_AUDIT) {
        constexpr int32_t record_bytes = 72;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_audit_history.size()),
                                              _save.audit_cursor + max_records);
        const int32_t begin = _save.audit_cursor;
        for (; _save.audit_cursor < end; ++_save.audit_cursor) {
            const AuditFrame &frame = _audit_history[static_cast<size_t>(_save.audit_cursor)];
            append_le<int64_t>(payload, frame.epoch_id);
            append_le<int64_t>(payload, frame.sample_day);
            append_le<int64_t>(payload, frame.commit_day);
            append_le<int64_t>(payload, frame.event_count);
            append_le<int64_t>(payload, frame.leg_count);
            append_le<int64_t>(payload, frame.population_error);
            append_le<int64_t>(payload, frame.money_error);
            append_le<int64_t>(payload, frame.goods_error);
            append_le<uint64_t>(payload, frame.stream_hash);
        }
        if (_save.audit_cursor >= static_cast<int32_t>(_audit_history.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_AUDIT,
                               static_cast<uint32_t>(_save.audit_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_SIGNALS) {
        constexpr int32_t record_bytes = 36;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_market_signals.good_ids.size()),
            _save.signal_cursor + max_records);
        const int32_t begin = _save.signal_cursor;
        int32_t cell = 0;
        while (cell + 1 < static_cast<int32_t>(_market_signals.cell_offsets.size()) &&
               _market_signals.cell_offsets[cell + 1] <= begin) ++cell;
        for (; _save.signal_cursor < end; ++_save.signal_cursor) {
            while (cell + 1 < static_cast<int32_t>(_market_signals.cell_offsets.size()) &&
                   _market_signals.cell_offsets[cell + 1] <= _save.signal_cursor) ++cell;
            append_le<int32_t>(payload, cell);
            append_le<int32_t>(payload, _market_signals.good_ids[_save.signal_cursor]);
            append_le<int64_t>(payload,
                               _market_signals.business_demand_ema[_save.signal_cursor]);
            append_le<int64_t>(payload,
                               _market_signals.offered_supply_ema[_save.signal_cursor]);
            append_le<int64_t>(payload,
                               _market_signals.realized_withdrawal_ema[_save.signal_cursor]);
            append_le<int32_t>(payload,
                               _market_signals.cost_anchor_price[_save.signal_cursor]);
        }
        if (_save.signal_cursor >= static_cast<int32_t>(_market_signals.good_ids.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_SIGNALS,
                               static_cast<uint32_t>(_save.signal_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_LABOR_SIGNALS) {
        constexpr int32_t record_bytes = 52;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_labor_signals.profession_ids.size()),
            _save.labor_signal_cursor + max_records);
        const int32_t begin = _save.labor_signal_cursor;
        int32_t cell = 0;
        while (cell + 1 < static_cast<int32_t>(_labor_signals.cell_offsets.size()) &&
               _labor_signals.cell_offsets[cell + 1] <= begin) ++cell;
        for (; _save.labor_signal_cursor < end; ++_save.labor_signal_cursor) {
            while (cell + 1 < static_cast<int32_t>(_labor_signals.cell_offsets.size()) &&
                   _labor_signals.cell_offsets[cell + 1] <=
                       _save.labor_signal_cursor) ++cell;
            const int32_t i = _save.labor_signal_cursor;
            append_le<int32_t>(payload, cell);
            append_le<int32_t>(payload, _labor_signals.profession_ids[i]);
            append_le<int64_t>(payload, _labor_signals.base_living_cost[i]);
            append_le<int64_t>(payload, _labor_signals.role_living_cost[i]);
            append_le<int64_t>(payload, _labor_signals.contract_wage_ema[i]);
            append_le<int64_t>(payload, _labor_signals.paid_wage_ema[i]);
            append_le<int64_t>(payload, _labor_signals.job_days[i]);
            append_le<int32_t>(payload, _labor_signals.pay_ratio_q16[i]);
        }
        if (_save.labor_signal_cursor >=
            static_cast<int32_t>(_labor_signals.profession_ids.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_LABOR_SIGNALS,
            static_cast<uint32_t>(_save.labor_signal_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_TRADE_ORDERS) {
        const int32_t begin = _save.trade_order_cursor;
        const int32_t end = std::min(_trade_orders.size(), begin + 1);
        for (; _save.trade_order_cursor < end; ++_save.trade_order_cursor) {
            const int32_t order = _save.trade_order_cursor;
            append_le<int64_t>(payload, _trade_orders.ids[order]);
            append_le<int32_t>(payload, _trade_orders.sources[order]);
            append_le<int32_t>(payload, _trade_orders.destinations[order]);
            append_le<int32_t>(payload, _trade_orders.countries[order]);
            append_le<int64_t>(payload, _trade_orders.departure_days[order]);
            append_le<int64_t>(payload, _trade_orders.arrival_days[order]);
            append_le<int64_t>(payload, _trade_orders.cash_escrow[order]);
            append_le<int64_t>(payload, _trade_orders.capacity_work[order]);
            append_le<uint8_t>(payload, _trade_orders.states[order]);
            append_le<uint8_t>(payload, _trade_orders.cargo_delivered[order]);
            const int32_t line_count = _trade_orders.line_offsets[order + 1] -
                _trade_orders.line_offsets[order];
            const int32_t seller_count = _trade_orders.seller_offsets[order + 1] -
                _trade_orders.seller_offsets[order];
            append_le<int32_t>(payload, line_count);
            append_le<int32_t>(payload, seller_count);
            for (int32_t line = _trade_orders.line_offsets[order];
                 line < _trade_orders.line_offsets[order + 1]; ++line) {
                append_le<int32_t>(payload, _trade_orders.line_goods[line]);
                append_le<int64_t>(payload, _trade_orders.line_quantities[line]);
                append_le<int32_t>(payload, _trade_orders.line_unit_prices[line]);
            }
            for (int32_t seller = _trade_orders.seller_offsets[order];
                 seller < _trade_orders.seller_offsets[order + 1]; ++seller) {
                append_le<uint64_t>(payload, _trade_orders.seller_handles[seller]);
                append_le<int64_t>(payload, _trade_orders.seller_weights[seller]);
            }
        }
        if (_save.trade_order_cursor >= _trade_orders.size()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_TRADE_ORDERS,
            static_cast<uint32_t>(_save.trade_order_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_TRADE_FLOWS) {
        constexpr int32_t record_bytes = 40;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.trade_flow_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_trade_flows.cells.size()), begin + max_records);
        for (; _save.trade_flow_cursor < end; ++_save.trade_flow_cursor) {
            const int32_t flow = _save.trade_flow_cursor;
            append_le<int32_t>(payload, _trade_flows.cells[flow]);
            append_le<int32_t>(payload, _trade_flows.goods[flow]);
            append_le<int64_t>(payload, _trade_flows.import_ema[flow]);
            append_le<int64_t>(payload, _trade_flows.export_ema[flow]);
            append_le<int64_t>(payload, _trade_flows.period_import[flow]);
            append_le<int64_t>(payload, _trade_flows.period_export[flow]);
        }
        if (_save.trade_flow_cursor >= static_cast<int32_t>(_trade_flows.cells.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_TRADE_FLOWS,
            static_cast<uint32_t>(_save.trade_flow_cursor - begin), payload);
    }
    _save.end_emitted = true;
    return make_save_chunk(SAVE_SECTION_END, 0, payload);
}

Dictionary NativeEconomyRuntime::end_save() {
    Dictionary out;
    if (!_save.active) {
        out["ok"] = false;
        out["reason"] = "save_not_active";
        return out;
    }
    if (!_save.end_emitted) {
        out["ok"] = false;
        out["reason"] = "save_stream_not_fully_read";
        return out;
    }
    _save = {};
    out["ok"] = true;
    return out;
}

Dictionary NativeEconomyRuntime::begin_restore() {
    Dictionary out;
    if (!_configured || _epoch_active || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "configure_catalog_before_restore"
                         : (_epoch_active ? "restore_requires_committed_boundary"
                                          : "save_restore_already_active");
        return out;
    }
    _restore = {};
    _restore.active = true;
    _bootstrapped = false;
    _population.clear(_cell_count);
    _market.clear();
    _market_signals.clear(_cell_count);
    _labor_signals.clear(_cell_count);
    _trade_plan.clear_transient();
    _trade_signal_clock_keys.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    _trade_orders.clear();
    _trade_flows.clear();
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _building_role_contract_wage.clear();
    _building_role_base_living_cost.clear();
    _building_role_living_cost.clear();
    _building_role_local_average_wage.clear();
    _building_role_base_wage_due.clear();
    _building_role_base_wage_paid.clear();
    _building_role_bonus_due.clear();
    _building_role_bonus_paid.clear();
    _pending_construction.clear();
    _committed_cells.assign(_cell_count, {});
    _cell_last_settlement_day.assign(_cell_count, -ROLLING_PHASE_COUNT);
    _cell_settlement_generation.assign(_cell_count, 0);
    _cell_price_stock_gen.assign(_cell_count, 0);
    _cell_owner_cash_gen.assign(_cell_count, 0);
    _cell_population_gen.assign(_cell_count, 0);
    _cell_building_structure_gen.assign(_cell_count, 0);
    _cell_technology_gen.assign(_cell_count, 0);
    _cell_resource_gen.assign(_cell_count, 0);
    _cell_trade_gen.assign(_cell_count, 0);
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    return out;
}

bool NativeEconomyRuntime::decode_restore_chunk(const std::vector<uint8_t> &bytes,
                                                std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0;
    uint16_t schema = 0;
    uint16_t section = 0;
    uint32_t records = 0;
    uint32_t payload_bytes = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, schema) ||
        !read_le(bytes, cursor, section) || !read_le(bytes, cursor, records) ||
        !read_le(bytes, cursor, payload_bytes) || magic != SAVE_MAGIC ||
        payload_bytes != bytes.size() - cursor ||
        (_restore.header_seen && schema != _restore.schema_version)) {
        error = "save_chunk_header_invalid";
        return false;
    }
    if (schema != SCHEMA_VERSION && schema != 14 && schema != 13 && schema != 12 &&
        schema != 11 && schema != 10) {
        error = schema >= 2 && schema <= 9
            ? "legacy_countryless_economy_save_unsupported"
            : "economy_save_schema_unsupported";
        return false;
    }
    if (schema == 10 && _trade_runtime_mode == 2) {
        error = "active_trade_rejects_v10_economy_save";
        return false;
    }
    if (!_restore.header_seen && section != SAVE_SECTION_HEADER) {
        error = "save_header_chunk_required_first";
        return false;
    }
    if (section == SAVE_SECTION_HEADER) {
        if (_restore.header_seen || records != 1) {
            error = "duplicate_or_invalid_save_header";
            return false;
        }
        int32_t saved_cells = 0, markets = 0, goods = 0, pages = 0, epoch_days = 0,
                pending_count = 0, building_count = 0, construction_count = 0,
                audit_count = 0, signal_count = 0, labor_signal_count = 0;
        int64_t active_count = 0, last_day = 0, epoch_id = 0, seed = 0,
                catalog_hash = 0, money_scale = 0, goods_scale = 0, ratio_scale = 0,
                rate_scale = 0, environment_day = -1, environment_hash = 0,
                building_catalog_hash = 0;
        int32_t country_schema = 0;
        uint64_t country_generation = 0, country_hash = 0;
        uint64_t next_submit = 0;
        int64_t next_event_id = 1;
        uint64_t event_stream_hash = 1469598103934665603ULL;
        int32_t trade_order_count = 0, trade_flow_count = 0, saved_trade_mode = 0;
        int64_t next_trade_order_id = 1, saved_trade_capacity = 0;
        int32_t saved_trade_speed = 0, saved_trade_margin = 0,
                saved_trade_targets = 0, saved_trade_signal_budget = 0,
                saved_trade_route_budget = 0, saved_trade_expansions = 0,
                saved_trade_cache = 0, saved_trade_signals = 0,
                saved_trade_candidates = 0,
                saved_trade_orders = 0, saved_trade_alpha = 0,
                saved_trade_stock_share = 0;
        int32_t saved_loss_threshold = -16384, saved_loss_cycles = 3,
                saved_restart_margin = 6554, saved_restart_cycles = 2,
                saved_merchant_reserve = 16384,
                saved_market_making_days = Q16_ONE;
        int32_t saved_trade_export_days = 5,
                saved_trade_export_fraction = 32768,
                saved_trade_import_fraction = 32768,
                saved_trade_response_days = 15,
                saved_investment_review_days = 10,
                saved_investment_shortage = 8192,
                saved_investment_utilization = 42598,
                saved_investment_payback_days = 365,
                saved_investment_cycles = 2,
                saved_resource_reserve = 22938,
                saved_resource_harvest = 32768,
                saved_resource_horizon = 3650,
                saved_bullion_cap = 655,
                saved_support_cap = 3277;
        std::vector<std::string> professions, ethnicities, good_ids, plan_ids;
        if (!read_le(bytes, cursor, saved_cells) || !read_le(bytes, cursor, markets) ||
            !read_le(bytes, cursor, goods) || !read_le(bytes, cursor, pages) ||
            !read_le(bytes, cursor, active_count) || !read_le(bytes, cursor, epoch_days) ||
            !read_le(bytes, cursor, last_day) || !read_le(bytes, cursor, epoch_id) ||
            !read_le(bytes, cursor, country_schema) ||
            !read_le(bytes, cursor, country_generation) ||
            !read_le(bytes, cursor, country_hash) || !read_le(bytes, cursor, seed) ||
            !read_le(bytes, cursor, catalog_hash)) {
            error = "save_header_payload_truncated";
            return false;
        }
        if (!read_le(bytes, cursor, building_catalog_hash) ||
            !read_le(bytes, cursor, building_count) ||
            !read_le(bytes, cursor, construction_count)) {
            error = "save_building_header_payload_truncated";
            return false;
        }
        if (
            !read_le(bytes, cursor, environment_day) || !read_le(bytes, cursor, environment_hash) ||
            !read_le(bytes, cursor, next_submit) ||
            !read_le(bytes, cursor, money_scale) || !read_le(bytes, cursor, goods_scale) ||
            !read_le(bytes, cursor, ratio_scale) || !read_le(bytes, cursor, rate_scale) ||
            !read_le(bytes, cursor, pending_count) ||
            !read_le(bytes, cursor, audit_count) ||
            !read_le(bytes, cursor, signal_count) ||
            !read_le(bytes, cursor, labor_signal_count) ||
            !read_le(bytes, cursor, next_event_id) ||
            !read_le(bytes, cursor, event_stream_hash)) {
            error = "save_header_payload_truncated";
            return false;
        }
        if (schema >= 11 && (!read_le(bytes, cursor, trade_order_count) ||
            !read_le(bytes, cursor, trade_flow_count) ||
            !read_le(bytes, cursor, next_trade_order_id) ||
            !read_le(bytes, cursor, saved_trade_mode) ||
            !read_le(bytes, cursor, saved_trade_capacity) ||
            !read_le(bytes, cursor, saved_trade_speed) ||
            !read_le(bytes, cursor, saved_trade_margin) ||
            !read_le(bytes, cursor, saved_trade_targets) ||
            !read_le(bytes, cursor, saved_trade_signal_budget) ||
            !read_le(bytes, cursor, saved_trade_route_budget) ||
            !read_le(bytes, cursor, saved_trade_expansions) ||
            !read_le(bytes, cursor, saved_trade_cache) ||
            !read_le(bytes, cursor, saved_trade_signals) ||
            !read_le(bytes, cursor, saved_trade_candidates) ||
            !read_le(bytes, cursor, saved_trade_orders) ||
            !read_le(bytes, cursor, saved_trade_alpha) ||
            !read_le(bytes, cursor, saved_trade_stock_share))) {
            error = "save_trade_header_payload_truncated";
            return false;
        }
        if (schema >= 12 && (!read_le(bytes, cursor, saved_loss_threshold) ||
            !read_le(bytes, cursor, saved_loss_cycles) ||
            !read_le(bytes, cursor, saved_restart_margin) ||
            !read_le(bytes, cursor, saved_restart_cycles) ||
            !read_le(bytes, cursor, saved_merchant_reserve) ||
            !read_le(bytes, cursor, saved_market_making_days))) {
            error = "save_business_policy_header_payload_truncated";
            return false;
        }
        if (schema >= 14 && (!read_le(bytes, cursor, saved_trade_export_days) ||
            !read_le(bytes, cursor, saved_trade_export_fraction) ||
            !read_le(bytes, cursor, saved_trade_import_fraction) ||
            !read_le(bytes, cursor, saved_trade_response_days) ||
            !read_le(bytes, cursor, saved_investment_review_days) ||
            !read_le(bytes, cursor, saved_investment_shortage) ||
            !read_le(bytes, cursor, saved_investment_utilization) ||
            !read_le(bytes, cursor, saved_investment_payback_days) ||
            !read_le(bytes, cursor, saved_investment_cycles) ||
            !read_le(bytes, cursor, saved_resource_reserve) ||
            !read_le(bytes, cursor, saved_resource_harvest) ||
            !read_le(bytes, cursor, saved_resource_horizon) ||
            !read_le(bytes, cursor, saved_bullion_cap) ||
            !read_le(bytes, cursor, saved_support_cap))) {
            error = "save_dynamic_policy_header_payload_truncated";
            return false;
        }
        if (!read_id_table(bytes, cursor, professions) || !read_id_table(bytes, cursor, ethnicities) ||
            !read_id_table(bytes, cursor, good_ids) || !read_id_table(bytes, cursor, plan_ids) ||
            cursor != bytes.size()) {
            error = "save_header_payload_truncated";
            return false;
        }
        const bool market_hash_ok = schema == 10
            ? (_catalog_compat_hash_v10 != 0 && catalog_hash == _catalog_compat_hash_v10)
            : (schema == 13 ? (_catalog_compat_hash_v13 != 0 &&
                catalog_hash == _catalog_compat_hash_v13) : catalog_hash == _catalog_hash);
        const bool building_hash_ok = schema == 13
            ? (_building_catalog_compat_hash_v13 != 0 &&
               building_catalog_hash == _building_catalog_compat_hash_v13)
            : building_catalog_hash == _building_catalog_hash;
        if (saved_cells != _cell_count || markets <= 0 || markets > _cell_count ||
            goods != static_cast<int32_t>(_good_ids.size()) || pages < 0 || active_count < 0 ||
            active_count > static_cast<int64_t>(pages) * PAGE_SIZE ||
            pending_count < 0 || pending_count > 1000000 ||
            audit_count < 0 || audit_count > 3650 || signal_count < 0 ||
            signal_count > 10000000 || labor_signal_count < 0 ||
            labor_signal_count > 10000000 || next_event_id <= 0 ||
            trade_order_count < 0 || trade_order_count > _trade_max_orders ||
            trade_flow_count < 0 || trade_flow_count > _trade_max_signals ||
            next_trade_order_id <= 0 ||
            !market_hash_ok || money_scale != MONEY_SCALE ||
            goods_scale != GOODS_SCALE || ratio_scale != Q16_ONE || rate_scale != Q32_ONE ||
            professions != _profession_ids || ethnicities != _ethnicity_ids ||
            good_ids != _good_ids || plan_ids != _plan_ids) {
            error = "save_catalog_scale_or_capacity_mismatch";
            return false;
        }
        if (schema >= 11 && (saved_trade_mode != _trade_runtime_mode ||
            saved_trade_capacity != _trade_capacity_per_merchant_q16 ||
            saved_trade_speed != _trade_speed_cost_per_day ||
            saved_trade_margin != _trade_min_margin_q16 ||
            saved_trade_targets != _trade_target_count ||
            saved_trade_signal_budget != _trade_signal_pairs_per_slice ||
            saved_trade_route_budget != _trade_route_searches_per_slice ||
            saved_trade_expansions != _trade_max_route_expansions ||
            saved_trade_cache != _trade_route_cache_entries ||
            saved_trade_signals != _trade_max_signals ||
            saved_trade_candidates != _trade_max_candidates ||
            saved_trade_orders != _trade_max_orders ||
            saved_trade_alpha != _trade_flow_ema_alpha_q16 ||
            saved_trade_stock_share != _trade_max_stock_share_q16)) {
            error = "save_trade_profile_mismatch";
            return false;
        }
        const bool policy_matches =
            saved_loss_threshold == _building_severe_loss_threshold_q16 &&
            saved_loss_cycles == _building_severe_loss_cycles &&
            saved_restart_margin == _building_restart_margin_q16 &&
            saved_restart_cycles == _building_restart_cycles &&
            saved_merchant_reserve == _merchant_procurement_cash_reserve_q16 &&
            saved_market_making_days == _merchant_market_making_days_q16;
        if ((schema >= 12 && !policy_matches) ||
            (schema == 11 && _trade_runtime_mode == 2 && !policy_matches)) {
            error = "save_business_policy_profile_mismatch";
            return false;
        }
        const bool dynamic_policy_matches =
            saved_trade_export_days == _trade_export_floor_days &&
            saved_trade_export_fraction == _trade_export_inventory_fraction_q16 &&
            saved_trade_import_fraction == _trade_import_fill_fraction_q16 &&
            saved_trade_response_days == _trade_response_days &&
            saved_investment_review_days == _investment_review_days &&
            saved_investment_shortage == _investment_min_shortage_q16 &&
            saved_investment_utilization == _investment_min_utilization_q16 &&
            saved_investment_payback_days == _investment_max_payback_days &&
            saved_investment_cycles == _investment_operating_cycles &&
            saved_resource_reserve == _resource_min_reserve_q16 &&
            saved_resource_harvest == _resource_safe_harvest_q16 &&
            saved_resource_horizon == _resource_min_horizon_days &&
            saved_bullion_cap == _bullion_monthly_issue_cap_q16 &&
            saved_support_cap == _producer_support_monthly_cap_q16;
        if (schema >= 14 && !dynamic_policy_matches) {
            error = "save_dynamic_policy_profile_mismatch";
            return false;
        }
        if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
            country_schema != NativeCountryRuntime::SCHEMA_VERSION ||
            country_generation != _country_runtime->generation() ||
            country_hash != static_cast<uint64_t>(_country_runtime->state_hash())) {
            error = "economy_country_restore_order_or_hash_mismatch";
            return false;
        }
        if (!building_hash_ok ||
            building_count < 0 || building_count > 10000000 || construction_count < 0 ||
            construction_count > 1000000) {
            error = "save_building_catalog_or_capacity_mismatch";
            return false;
        }
        _restore.schema_version = schema;
        _restore.expected_pages = pages;
        _restore.expected_commands = pending_count;
        _restore.expected_buildings = building_count;
        _restore.expected_construction = construction_count;
        _restore.expected_audits = audit_count;
        _restore.expected_signals = signal_count;
        _restore.expected_labor_signals = labor_signal_count;
        _restore.expected_trade_orders = trade_order_count;
        _restore.expected_trade_flows = trade_flow_count;
        _next_event_id = next_event_id;
        _event_stream_hash = event_stream_hash;
        _audit_history.clear();
        _committed_event_batches.clear();
        _event_consumer_ack.clear();
        _population.clear(_cell_count);
        _population.page_next.assign(pages, -1);
        _population.page_cell.assign(pages, -1);
        const size_t slots = static_cast<size_t>(pages) * PAGE_SIZE;
        _population.active.assign(slots, 0);
        _population.signature_id.assign(slots, 0);
        _population.generation.assign(slots, 1);
        _population.population.assign(slots, 0);
        _population.funds.assign(slots, 0);
        _population.epoch_income.assign(slots, 0);
        _population.epoch_expense.assign(slots, 0);
        _population.epoch_in_kind_income.assign(slots, 0);
        _population.income_ema.assign(slots, 0);
        _population.needs_satisfaction.assign(slots, static_cast<uint16_t>(Q16_ONE - 1));
        _population.worst_need_id.assign(slots, std::numeric_limits<uint16_t>::max());
        _population.flags.assign(slots, 0);
        _population.demography_residual.assign(slots, 0);
        _population.owner_employed.assign(slots, 0);
        _population.employee_employed.assign(slots, 0);
        _population.active_count = active_count;
        _population.high_water_slots = static_cast<int64_t>(slots);
        _market.market_count = markets;
        _market.good_count = goods;
        _market.stock.assign(static_cast<size_t>(markets) * goods, 0);
        _market.price.assign(static_cast<size_t>(markets) * goods, 0);
        _market.demand_ema.assign(static_cast<size_t>(markets) * goods, 0);
        _market.last_shortage_q16.assign(static_cast<size_t>(markets) * goods, 0);
        _market.cell_to_market.assign(_cell_count, -1);
        _market_signals.clear(_cell_count);
        _market_signals.good_ids.reserve(signal_count);
        _market_signals.business_demand_ema.reserve(signal_count);
        _market_signals.offered_supply_ema.reserve(signal_count);
        _market_signals.realized_withdrawal_ema.reserve(signal_count);
        _market_signals.cost_anchor_price.reserve(signal_count);
        _labor_signals.clear(_cell_count);
        _labor_signals.profession_ids.reserve(labor_signal_count);
        _labor_signals.base_living_cost.reserve(labor_signal_count);
        _labor_signals.role_living_cost.reserve(labor_signal_count);
        _labor_signals.contract_wage_ema.reserve(labor_signal_count);
        _labor_signals.paid_wage_ema.reserve(labor_signal_count);
        _labor_signals.job_days.reserve(labor_signal_count);
        _labor_signals.pay_ratio_q16.reserve(labor_signal_count);
        _trade_orders.clear();
        _trade_orders.next_id = next_trade_order_id;
        _trade_orders.ids.reserve(trade_order_count);
        _trade_flows.clear();
        _trade_flows.cells.reserve(trade_flow_count);
        _environment_temperature_q16.assign(_cell_count, 0);
        _environment_moisture_q16.assign(_cell_count, 0);
        _environment_snow_q16.assign(_cell_count, 0);
        _environment_weather_q16.assign(_cell_count, 0);
        _environment_day = environment_day;
        _environment_hash = environment_hash;
        _epoch_days = epoch_days;
        _commit_lag_budget_days = std::max(0, epoch_days - 1);
        if (_auto_slice_by_scale) {
            _cells_per_slice = std::max(1, (markets + std::max(1, epoch_days) - 1) /
                                               std::max(1, epoch_days));
        }
        if (_auto_building_slice_by_scale) {
            _building_cells_per_slice = std::min(
                512, std::max(1, _cells_per_slice / 4));
        }
        _last_committed_day = last_day;
        _commit_day = last_day;
        _sample_day = last_day;
        _current_day = last_day;
        _epoch_id = epoch_id;
        _seed = seed;
        _next_submit_order = next_submit;
        _pending_commands.reserve(pending_count);
        _buildings.clear();
        _building_cell_offsets.clear();
        _building_active_cells.clear();
        _buildings.reserve(building_count);
        _pending_construction.clear();
        _pending_construction.reserve(construction_count);
        _restore.header_seen = true;
        return true;
    }
    if (section == SAVE_SECTION_PAGES) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t page = -1, next = -1, cell = -1;
            if (!read_le(bytes, cursor, page) || !read_le(bytes, cursor, next) ||
                !read_le(bytes, cursor, cell) || page != _restore.restored_pages ||
                page < 0 || page >= _restore.expected_pages) {
                error = "save_page_record_invalid";
                return false;
            }
            _population.page_next[page] = next;
            _population.page_cell[page] = cell;
            const int32_t base = page * PAGE_SIZE;
            for (int32_t lane = 0; lane < PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                if (!read_le(bytes, cursor, _population.active[slot]) ||
                    !read_le(bytes, cursor, _population.signature_id[slot]) ||
                    !read_le(bytes, cursor, _population.generation[slot]) ||
                    !read_le(bytes, cursor, _population.population[slot]) ||
                    !read_le(bytes, cursor, _population.funds[slot]) ||
                    !read_le(bytes, cursor, _population.epoch_income[slot]) ||
                    !read_le(bytes, cursor, _population.epoch_expense[slot]) ||
                    !read_le(bytes, cursor, _population.income_ema[slot]) ||
                    !read_le(bytes, cursor, _population.needs_satisfaction[slot]) ||
                    !read_le(bytes, cursor, _population.worst_need_id[slot]) ||
                    !read_le(bytes, cursor, _population.flags[slot]) ||
                    !read_le(bytes, cursor, _population.demography_residual[slot]) ||
                    !read_le(bytes, cursor, _population.owner_employed[slot]) ||
                    !read_le(bytes, cursor, _population.employee_employed[slot])) {
                    error = "save_page_payload_truncated";
                    return false;
                }
            }
            ++_restore.restored_pages;
        }
    } else if (section == SAVE_SECTION_MARKETS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t market = -1;
            if (!read_le(bytes, cursor, market) || market != _restore.restored_markets ||
                market < 0 || market >= _market.market_count) {
                error = "save_market_record_invalid";
                return false;
            }
            for (int32_t good = 0; good < _market.good_count; ++good) {
                const int64_t idx = _market.index(market, good);
                if (!read_le(bytes, cursor, _market.stock[idx]) ||
                    !read_le(bytes, cursor, _market.price[idx]) ||
                    !read_le(bytes, cursor, _market.demand_ema[idx]) ||
                    !read_le(bytes, cursor, _market.last_shortage_q16[idx])) {
                    error = "save_market_payload_truncated";
                    return false;
                }
            }
            ++_restore.restored_markets;
        }
    } else if (section == SAVE_SECTION_CELLS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1, market = -1;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, market) ||
                cell != _restore.restored_cells || cell < 0 || cell >= _cell_count) {
                error = "save_cell_market_record_invalid";
                return false;
            }
            if (!read_le(bytes, cursor, _environment_temperature_q16[cell]) ||
                !read_le(bytes, cursor, _environment_moisture_q16[cell]) ||
                !read_le(bytes, cursor, _environment_snow_q16[cell]) ||
                !read_le(bytes, cursor, _environment_weather_q16[cell])) {
                error = "save_cell_environment_record_invalid";
                return false;
            }
            if (schema >= 15) {
                int32_t saved_phase = -1;
                if (!read_le(bytes, cursor, _cell_last_settlement_day[cell]) ||
                    !read_le(bytes, cursor, _cell_settlement_generation[cell]) ||
                    !read_le(bytes, cursor, _cell_price_stock_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_owner_cash_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_population_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_building_structure_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_technology_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_resource_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_trade_gen[cell]) ||
                    !read_le(bytes, cursor, saved_phase) ||
                    saved_phase != cell % ROLLING_PHASE_COUNT) {
                    error = "save_cell_rolling_state_invalid";
                    return false;
                }
            }
            _market.cell_to_market[cell] = market;
            ++_restore.restored_cells;
        }
    } else if (section == SAVE_SECTION_COMMANDS) {
        for (uint32_t record = 0; record < records; ++record) {
            Command cmd;
            if (!read_le(bytes, cursor, cmd.opcode) || !read_le(bytes, cursor, cmd.effective_day) ||
                !read_le(bytes, cursor, cmd.sequence) || !read_le(bytes, cursor, cmd.target_handle) ||
                !read_le(bytes, cursor, cmd.i32_0) || !read_le(bytes, cursor, cmd.i32_1) ||
                !read_le(bytes, cursor, cmd.i64_0) || !read_le(bytes, cursor, cmd.i64_1) ||
                !read_le(bytes, cursor, cmd.submit_order)) {
                error = "save_command_payload_truncated";
                return false;
            }
            _pending_commands.push_back(cmd);
            ++_restore.restored_commands;
        }
    } else if (section == SAVE_SECTION_BUILDINGS) {
        for (uint32_t record = 0; record < records; ++record) {
            BuildingGroup group;
            int32_t roles = 0;
            if (!read_le(bytes, cursor, group.cell) || !read_le(bytes, cursor, group.type_id) ||
                !read_le(bytes, cursor, group.owner_signature_id) ||
                !read_le(bytes, cursor, group.count) ||
                !read_le(bytes, cursor, group.filled_owner) ||
                !read_le(bytes, cursor, group.last_capacity_q16) ||
                !read_le(bytes, cursor, group.last_input) ||
                !read_le(bytes, cursor, group.last_output) ||
                !read_le(bytes, cursor, group.last_sold) ||
                !read_le(bytes, cursor, group.last_discarded) ||
                !read_le(bytes, cursor, group.last_resource) ||
                !read_le(bytes, cursor, group.last_resource_generated) ||
                !read_le(bytes, cursor, group.last_revenue) ||
                !read_le(bytes, cursor, group.last_input_cost) ||
                !read_le(bytes, cursor, group.last_wages_paid) ||
                !read_le(bytes, cursor, group.last_wages_due) ||
                !read_le(bytes, cursor, group.last_expected_revenue) ||
                !read_le(bytes, cursor, group.last_operating_cost) ||
                !read_le(bytes, cursor, group.last_margin_gap_q16) ||
                !read_le(bytes, cursor, group.planned_utilization_q16) ||
                !read_le(bytes, cursor, group.last_base_wages_paid) ||
                !read_le(bytes, cursor, group.last_base_wages_due) ||
                !read_le(bytes, cursor, group.last_bonus_paid) ||
                !read_le(bytes, cursor, group.last_bonus_due) ||
                !read_le(bytes, cursor, group.wage_suspended)) {
                error = "save_building_record_invalid";
                return false;
            }
            if (_restore.schema_version >= 12 &&
                (!read_le(bytes, cursor, group.purchase_intent_capacity_q16) ||
                 !read_le(bytes, cursor, group.realized_profit_margin_q16) ||
                 !read_le(bytes, cursor, group.severe_loss_cycles) ||
                 !read_le(bytes, cursor, group.recovery_cycles) ||
                 !read_le(bytes, cursor, group.operating_state))) {
                error = "save_building_business_state_payload_truncated";
                return false;
            }
            if (!read_le(bytes, cursor, roles) || group.cell < 0 || group.cell >= _cell_count ||
                group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()) ||
                group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                group.count <= 0 || roles != _building_types[group.type_id].employee_count ||
                group.purchase_intent_capacity_q16 < 0 ||
                group.purchase_intent_capacity_q16 > Q16_ONE ||
                group.operating_state > 1) {
                error = "save_building_record_invalid";
                return false;
            }
            group.employee_fill_begin = static_cast<int32_t>(_building_employee_filled.size());
            for (int32_t r = 0; r < roles; ++r) {
                int64_t value = 0;
                if (!read_le(bytes, cursor, value) || value < 0) {
                    error = "save_building_role_payload_invalid";
                    return false;
                }
                _building_employee_filled.push_back(value);
                const JobRole &role = _building_employee_roles[
                    _building_types[group.type_id].employee_begin + r];
                int64_t contract = role.reference_wage_per_day;
                int64_t base_living = 0;
                int64_t role_living = 0;
                int64_t local_average = 0;
                int64_t base_due = 0;
                int64_t base_paid = 0;
                int64_t bonus_due = 0;
                int64_t bonus_paid = 0;
                if (!read_le(bytes, cursor, contract) ||
                     !read_le(bytes, cursor, base_living) ||
                     !read_le(bytes, cursor, role_living) ||
                     !read_le(bytes, cursor, local_average) ||
                     !read_le(bytes, cursor, base_due) ||
                     !read_le(bytes, cursor, base_paid) ||
                     !read_le(bytes, cursor, bonus_due) ||
                     !read_le(bytes, cursor, bonus_paid)) {
                    error = "save_building_role_wage_payload_invalid";
                    return false;
                }
                if (contract < 0 || base_living < 0 || role_living < 0 ||
                    local_average < 0 || base_due < 0 || base_paid < 0 ||
                    bonus_due < 0 || bonus_paid < 0 || base_paid > base_due ||
                    bonus_paid > bonus_due) {
                    error = "save_building_role_wage_value_invalid";
                    return false;
                }
                _building_role_contract_wage.push_back(contract);
                _building_role_base_living_cost.push_back(base_living);
                _building_role_living_cost.push_back(role_living);
                _building_role_local_average_wage.push_back(local_average);
                _building_role_base_wage_due.push_back(base_due);
                _building_role_base_wage_paid.push_back(base_paid);
                _building_role_bonus_due.push_back(bonus_due);
                _building_role_bonus_paid.push_back(bonus_paid);
            }
            _buildings.push_back(group);
            ++_restore.restored_buildings;
        }
    } else if (section == SAVE_SECTION_CONSTRUCTION) {
        for (uint32_t record = 0; record < records; ++record) {
            PendingConstruction pending;
            if (!read_le(bytes, cursor, pending.cell) || !read_le(bytes, cursor, pending.type_id) ||
                !read_le(bytes, cursor, pending.owner_signature_id) ||
                !read_le(bytes, cursor, pending.count) ||
                !read_le(bytes, cursor, pending.ready_day) ||
                !read_le(bytes, cursor, pending.sequence) || pending.cell < 0 ||
                pending.cell >= _cell_count || pending.type_id < 0 ||
                pending.type_id >= static_cast<int32_t>(_building_types.size()) ||
                pending.owner_signature_id < 0 ||
                pending.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                pending.count <= 0) {
                error = "save_construction_record_invalid";
                return false;
            }
            _pending_construction.push_back(pending);
            ++_restore.restored_construction;
        }
    } else if (section == SAVE_SECTION_AUDIT) {
        for (uint32_t record = 0; record < records; ++record) {
            AuditFrame frame;
            if (!read_le(bytes, cursor, frame.epoch_id) ||
                !read_le(bytes, cursor, frame.sample_day) ||
                !read_le(bytes, cursor, frame.commit_day) ||
                !read_le(bytes, cursor, frame.event_count) ||
                !read_le(bytes, cursor, frame.leg_count) ||
                !read_le(bytes, cursor, frame.population_error) ||
                !read_le(bytes, cursor, frame.money_error) ||
                !read_le(bytes, cursor, frame.goods_error) ||
                !read_le(bytes, cursor, frame.stream_hash) ||
                frame.event_count < 0 || frame.leg_count < 0) {
                error = "save_audit_record_invalid";
                return false;
            }
            _audit_history.push_back(frame);
            ++_restore.restored_audits;
        }
    } else if (section == SAVE_SECTION_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t good = -1;
            int64_t business = 0;
            int64_t supply = 0;
            int64_t realized = 0;
            int32_t anchor = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, business) || !read_le(bytes, cursor, supply) ||
                (_restore.schema_version >= 12 && !read_le(bytes, cursor, realized)) ||
                !read_le(bytes, cursor, anchor) || cell < 0 || cell >= _cell_count ||
                good < 0 || good >= _market.good_count || business < 0 || supply < 0 ||
                realized < 0 ||
                anchor < 0 || (anchor != 0 &&
                    (anchor < PRICE_NUMERIC_GUARD_MIN ||
                     anchor > PRICE_NUMERIC_GUARD_MAX)) ||
                (_restore.last_signal_cell > cell) ||
                (_restore.last_signal_cell == cell && _restore.last_signal_good >= good)) {
                error = "save_market_signal_record_invalid";
                return false;
            }
            _restore.last_signal_cell = cell;
            _restore.last_signal_good = good;
            ++_market_signals.cell_offsets[cell + 1];
            _market_signals.good_ids.push_back(good);
            _market_signals.business_demand_ema.push_back(business);
            _market_signals.offered_supply_ema.push_back(supply);
            _market_signals.realized_withdrawal_ema.push_back(realized);
            _market_signals.cost_anchor_price.push_back(anchor);
            ++_restore.restored_signals;
        }
    } else if (section == SAVE_SECTION_LABOR_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t profession = -1;
            int64_t base_living = 0;
            int64_t role_living = 0;
            int64_t contract = 0;
            int64_t paid = 0;
            int64_t jobs = 0;
            int32_t ratio = 0;
            if (!read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, profession) ||
                !read_le(bytes, cursor, base_living) ||
                !read_le(bytes, cursor, role_living) ||
                !read_le(bytes, cursor, contract) ||
                !read_le(bytes, cursor, paid) ||
                !read_le(bytes, cursor, jobs) ||
                !read_le(bytes, cursor, ratio) ||
                cell < 0 || cell >= _cell_count || profession < 0 ||
                profession >= static_cast<int32_t>(_profession_ids.size()) ||
                base_living < 0 || role_living < 0 || contract < 0 || paid < 0 ||
                jobs < 0 || ratio < 0 || ratio > Q16_ONE ||
                _restore.last_labor_cell > cell ||
                (_restore.last_labor_cell == cell &&
                 _restore.last_labor_profession >= profession)) {
                error = "save_labor_signal_record_invalid";
                return false;
            }
            _restore.last_labor_cell = cell;
            _restore.last_labor_profession = profession;
            ++_labor_signals.cell_offsets[cell + 1];
            _labor_signals.profession_ids.push_back(profession);
            _labor_signals.base_living_cost.push_back(base_living);
            _labor_signals.role_living_cost.push_back(role_living);
            _labor_signals.contract_wage_ema.push_back(contract);
            _labor_signals.paid_wage_ema.push_back(paid);
            _labor_signals.job_days.push_back(jobs);
            _labor_signals.pay_ratio_q16.push_back(ratio);
            ++_restore.restored_labor_signals;
        }
    } else if (schema >= 11 && section == SAVE_SECTION_TRADE_ORDERS) {
        for (uint32_t record = 0; record < records; ++record) {
            int64_t id = 0, departure = 0, arrival = 0, cash = 0, capacity = 0;
            int32_t source = -1, destination = -1, country = -1;
            uint8_t state = 0, delivered = 0;
            int32_t line_count = 0, seller_count = 0;
            if (!read_le(bytes, cursor, id) || !read_le(bytes, cursor, source) ||
                !read_le(bytes, cursor, destination) || !read_le(bytes, cursor, country) ||
                !read_le(bytes, cursor, departure) || !read_le(bytes, cursor, arrival) ||
                !read_le(bytes, cursor, cash) || !read_le(bytes, cursor, capacity) ||
                !read_le(bytes, cursor, state) || !read_le(bytes, cursor, delivered) ||
                !read_le(bytes, cursor, line_count) ||
                !read_le(bytes, cursor, seller_count) || id <= 0 ||
                (!_trade_orders.ids.empty() && id <= _trade_orders.ids.back()) ||
                source < 0 || source >= _cell_count || destination < 0 ||
                destination >= _cell_count || source == destination || country < 0 ||
                departure < 0 || arrival < departure || cash < 0 || capacity <= 0 ||
                state > TradeOrderStore::WAITING_RECEIVER || delivered > 1 ||
                (state == TradeOrderStore::IN_TRANSIT && delivered != 0) ||
                (state == TradeOrderStore::WAITING_RECEIVER && delivered == 0) ||
                line_count <= 0 || line_count > 16 || seller_count < 0 ||
                seller_count > 1000000) {
                error = "save_trade_order_record_invalid";
                return false;
            }
            _trade_orders.ids.push_back(id);
            _trade_orders.sources.push_back(source);
            _trade_orders.destinations.push_back(destination);
            _trade_orders.countries.push_back(country);
            _trade_orders.departure_days.push_back(departure);
            _trade_orders.arrival_days.push_back(arrival);
            _trade_orders.cash_escrow.push_back(cash);
            _trade_orders.capacity_work.push_back(capacity);
            _trade_orders.states.push_back(state);
            _trade_orders.cargo_delivered.push_back(delivered);
            for (int32_t line = 0; line < line_count; ++line) {
                int32_t good = -1, price = 0;
                int64_t quantity = 0;
                if (!read_le(bytes, cursor, good) ||
                    !read_le(bytes, cursor, quantity) ||
                    !read_le(bytes, cursor, price) || good < 0 ||
                    good >= _market.good_count || _good_trade_enabled[good] == 0 ||
                    quantity <= 0 || price < PRICE_NUMERIC_GUARD_MIN ||
                    price > PRICE_NUMERIC_GUARD_MAX) {
                    error = "save_trade_order_line_invalid";
                    return false;
                }
                _trade_orders.line_goods.push_back(good);
                _trade_orders.line_quantities.push_back(quantity);
                _trade_orders.line_unit_prices.push_back(price);
            }
            _trade_orders.line_offsets.push_back(
                static_cast<int32_t>(_trade_orders.line_goods.size()));
            for (int32_t seller = 0; seller < seller_count; ++seller) {
                uint64_t handle = 0;
                int64_t weight = 0;
                if (!read_le(bytes, cursor, handle) ||
                    !read_le(bytes, cursor, weight) || handle == 0 || weight <= 0) {
                    error = "save_trade_order_seller_invalid";
                    return false;
                }
                _trade_orders.seller_handles.push_back(handle);
                _trade_orders.seller_weights.push_back(weight);
            }
            _trade_orders.seller_offsets.push_back(
                static_cast<int32_t>(_trade_orders.seller_handles.size()));
            ++_restore.restored_trade_orders;
        }
    } else if (schema >= 11 && section == SAVE_SECTION_TRADE_FLOWS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1, good = -1;
            int64_t import_ema = 0, export_ema = 0, period_import = 0,
                    period_export = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, import_ema) ||
                !read_le(bytes, cursor, export_ema) ||
                !read_le(bytes, cursor, period_import) ||
                !read_le(bytes, cursor, period_export) || cell < 0 ||
                cell >= _cell_count || good < 0 || good >= _market.good_count ||
                import_ema < 0 || export_ema < 0 || period_import < 0 ||
                period_export < 0 || (!_trade_flows.cells.empty() &&
                    (_trade_flows.cells.back() > cell ||
                     (_trade_flows.cells.back() == cell &&
                      _trade_flows.goods.back() >= good)))) {
                error = "save_trade_flow_record_invalid";
                return false;
            }
            _trade_flows.cells.push_back(cell);
            _trade_flows.goods.push_back(good);
            _trade_flows.import_ema.push_back(import_ema);
            _trade_flows.export_ema.push_back(export_ema);
            _trade_flows.period_import.push_back(period_import);
            _trade_flows.period_export.push_back(period_export);
            ++_restore.restored_trade_flows;
        }
    } else if ((schema >= 11 && section == SAVE_SECTION_END) ||
               (schema == 10 && section == SAVE_SECTION_END_V10)) {
        if (records != 0 || payload_bytes != 0) {
            error = "save_end_chunk_invalid";
            return false;
        }
        _restore.end_seen = true;
    } else {
        error = "save_section_unknown";
        return false;
    }
    if (cursor != bytes.size()) {
        error = "save_chunk_record_count_mismatch";
        return false;
    }
    return true;
}

Dictionary NativeEconomyRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    Dictionary out;
    if (!_restore.active || _restore.failed || _restore.end_seen || chunk.is_empty()) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                                            : (_restore.end_seen ? "restore_end_already_seen"
                                                                 : "restore_chunk_empty"));
        return out;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(chunk.size()));
    std::memcpy(bytes.data(), chunk.ptr(), bytes.size());
    std::string error;
    if (!decode_restore_chunk(bytes, error)) {
        _restore.failed = true;
        _restore.error = error;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    out["ok"] = true;
    out["header_seen"] = _restore.header_seen;
    out["end_seen"] = _restore.end_seen;
    out["restored_pages"] = _restore.restored_pages;
    out["restored_markets"] = _restore.restored_markets;
    out["restored_cells"] = _restore.restored_cells;
    out["restored_commands"] = _restore.restored_commands;
    out["restored_audits"] = _restore.restored_audits;
    out["restored_signals"] = _restore.restored_signals;
    out["restored_labor_signals"] = _restore.restored_labor_signals;
    out["restored_trade_orders"] = _restore.restored_trade_orders;
    out["restored_trade_flows"] = _restore.restored_trade_flows;
    return out;
}

Dictionary NativeEconomyRuntime::end_restore() {
    Dictionary out;
    if (!_restore.active || _restore.failed || !_restore.header_seen || !_restore.end_seen) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                         : (!_restore.header_seen ? "restore_header_missing" : "restore_end_missing"));
        return out;
    }
    if (_restore.restored_pages != _restore.expected_pages ||
        _restore.restored_markets != _market.market_count ||
        _restore.restored_cells != _cell_count ||
        _restore.restored_commands != _restore.expected_commands ||
        _restore.restored_buildings != _restore.expected_buildings ||
        _restore.restored_construction != _restore.expected_construction ||
        _restore.restored_audits != _restore.expected_audits ||
        _restore.restored_signals != _restore.expected_signals ||
        _restore.restored_labor_signals != _restore.expected_labor_signals ||
        _restore.restored_trade_orders != _restore.expected_trade_orders ||
        _restore.restored_trade_flows != _restore.expected_trade_flows) {
        out["ok"] = false;
        out["reason"] = "restore_section_incomplete";
        return out;
    }
    std::vector<uint8_t> referenced(_population.page_next.size(), 0);
    int64_t actual_active = 0;
    for (int32_t page = 0; page < static_cast<int32_t>(_population.page_next.size()); ++page) {
        const int32_t cell = _population.page_cell[page];
        const int32_t next = _population.page_next[page];
        if (cell < -1 || cell >= _cell_count || next < -1 ||
            next >= static_cast<int32_t>(_population.page_next.size()) ||
            (next >= 0 && _population.page_cell[next] != cell)) {
            out["ok"] = false;
            out["reason"] = "restore_page_chain_invalid";
            return out;
        }
        if (next >= 0) referenced[next] = 1;
        if (cell < 0) _population.free_pages.push_back(page);
        const int32_t base = page * PAGE_SIZE;
        for (int32_t lane = 0; lane < PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (_population.active[slot] == 0) continue;
            if (cell < 0 || _population.signature_id[slot] >= _signatures.size() ||
                _population.generation[slot] == 0 || _population.population[slot] <= 0 ||
                _population.funds[slot] < 0) {
                out["ok"] = false;
                out["reason"] = "restore_cohort_record_invalid";
                return out;
            }
            ++actual_active;
        }
    }
    _population.cell_first_page.assign(_cell_count, -1);
    for (int32_t page = 0; page < static_cast<int32_t>(_population.page_next.size()); ++page) {
        const int32_t cell = _population.page_cell[page];
        if (cell < 0 || referenced[page] != 0) continue;
        if (_population.cell_first_page[cell] >= 0) {
            out["ok"] = false;
            out["reason"] = "restore_multiple_page_chain_heads";
            return out;
        }
        _population.cell_first_page[cell] = page;
    }
    std::vector<uint8_t> visited(_population.page_next.size(), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        int32_t steps = 0;
        for (int32_t page = _population.cell_first_page[cell]; page >= 0;
             page = _population.page_next[page]) {
            if (++steps > static_cast<int32_t>(_population.page_next.size()) || visited[page] != 0) {
                out["ok"] = false;
                out["reason"] = "restore_page_chain_cycle";
                return out;
            }
            visited[page] = 1;
        }
    }
    for (int32_t page = 0; page < static_cast<int32_t>(_population.page_next.size()); ++page) {
        if (_population.page_cell[page] >= 0 && visited[page] == 0) {
            out["ok"] = false;
            out["reason"] = "restore_unreachable_page";
            return out;
        }
    }
    if (actual_active != _population.active_count) {
        out["ok"] = false;
        out["reason"] = "restore_active_count_mismatch";
        return out;
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_market.cell_to_market[cell] < 0 || _market.cell_to_market[cell] >= _market.market_count) {
            out["ok"] = false;
            out["reason"] = "restore_cell_market_invalid";
            return out;
        }
        std::vector<uint32_t> signatures;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            signatures.push_back(_population.signature_id[slot]);
        });
        std::sort(signatures.begin(), signatures.end());
        if (std::adjacent_find(signatures.begin(), signatures.end()) != signatures.end()) {
            out["ok"] = false;
            out["reason"] = "restore_duplicate_cell_signature";
            return out;
        }
    }
    for (int32_t market = 0; market < _market.market_count; ++market) {
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            if (_market.stock[idx] < 0 || _market.demand_ema[idx] < 0 ||
                _market.price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                _market.price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                out["ok"] = false;
                out["reason"] = "restore_market_value_invalid";
                return out;
            }
        }
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    int64_t restore_merchant_repairs = 0;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (!ensure_merchant_invariant(cell, restore_merchant_repairs, market_range_error)) {
            out["ok"] = false;
            out["reason"] = String(market_range_error.c_str());
            return out;
        }
    }
    if (!rebuild_merchant_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    for (const Command &cmd : _pending_commands) {
        int32_t slot = -1;
        const bool market_target = cmd.opcode == COMMAND_ADD_STOCK ||
            cmd.opcode == COMMAND_REMOVE_STOCK ||
            cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
            cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY;
        const bool target_ok = market_target
            ? (cmd.i32_0 >= 0 && cmd.i32_0 < _market.market_count &&
               cmd.i32_1 >= 0 && cmd.i32_1 < _market.good_count &&
               ((cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                 cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY) ||
                (_country_runtime != nullptr && _country_runtime->valid_handle(
                    static_cast<int64_t>(cmd.target_handle)))))
            : _population.valid_handle(cmd.target_handle, slot);
        if (cmd.opcode < COMMAND_TRANSFER_TO_COHORT ||
            cmd.opcode > COMMAND_MARKET_GOOD_TO_COUNTRY ||
            !target_ok || cmd.effective_day < 0 || cmd.sequence < 0 ||
            (cmd.i64_0 < 0 && cmd.opcode != COMMAND_ADD_POPULATION)) {
            out["ok"] = false;
            out["reason"] = "restore_command_invalid";
            return out;
        }
    }
    for (const BuildingGroup &group : _buildings) {
        if (_signatures[group.owner_signature_id].profession_id !=
                _building_types[group.type_id].owner_profession_id ||
            group.filled_owner < 0 || group.filled_owner >
                group.count * _building_types[group.type_id].owner_slots_per_building ||
            group.last_input_cost < 0 || group.last_wages_paid < 0 ||
            group.last_wages_due < 0 || group.last_expected_revenue < 0 ||
            group.last_operating_cost < 0 || group.planned_utilization_q16 < 0 ||
            group.planned_utilization_q16 > Q16_ONE ||
            group.last_resource_generated < 0 ||
            group.last_base_wages_paid < 0 || group.last_base_wages_due < 0 ||
            group.last_bonus_paid < 0 || group.last_bonus_due < 0 ||
            group.last_base_wages_paid > group.last_base_wages_due ||
            group.last_bonus_paid > group.last_bonus_due ||
            group.wage_suspended > 1 || group.operating_state > 1 ||
            group.purchase_intent_capacity_q16 < 0 ||
            group.purchase_intent_capacity_q16 > Q16_ONE) {
            out["ok"] = false;
            out["reason"] = "restore_building_owner_or_job_invalid";
            return out;
        }
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            if (role_index < 0 ||
                role_index >= static_cast<int32_t>(_building_role_contract_wage.size()) ||
                _building_role_contract_wage[role_index] < 0 ||
                _building_role_base_living_cost[role_index] < 0 ||
                _building_role_living_cost[role_index] < 0 ||
                _building_role_local_average_wage[role_index] < 0 ||
                _building_role_base_wage_paid[role_index] < 0 ||
                _building_role_base_wage_due[role_index] <
                    _building_role_base_wage_paid[role_index] ||
                _building_role_bonus_paid[role_index] < 0 ||
                _building_role_bonus_due[role_index] <
                    _building_role_bonus_paid[role_index]) {
                out["ok"] = false;
                out["reason"] = "restore_building_role_wage_invalid";
                return out;
            }
            const int64_t filled = _building_employee_filled[role_index];
            const int64_t required = group.count *
                _building_employee_roles[type.employee_begin + r].slots_per_building;
            if (filled < 0 || filled > required) {
                out["ok"] = false;
                out["reason"] = "restore_building_employee_job_invalid";
                return out;
            }
        }
    }
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        if (_population.active[slot] == 0) continue;
        if (_population.owner_employed[slot] < 0 || _population.employee_employed[slot] < 0 ||
            _population.owner_employed[slot] + _population.employee_employed[slot] >
                _population.population[slot]) {
            out["ok"] = false;
            out["reason"] = "restore_cohort_employment_invalid";
            return out;
        }
    }
    rebuild_building_cell_offsets();
    if (_auto_slice_by_scale)
        _cells_per_slice = std::clamp(_market.market_count, 1, 128);
    if (_auto_building_slice_by_scale) _building_cells_per_slice = 256;
    choose_epoch_days(_population.active_count);
    _epoch_days = ROLLING_PHASE_COUNT;
    _commit_lag_budget_days = ROLLING_PHASE_COUNT - 1;
    if (_restore.schema_version < 15) {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            const int64_t phase = cell % ROLLING_PHASE_COUNT;
            const int64_t delta = ((_last_committed_day - phase) %
                ROLLING_PHASE_COUNT + ROLLING_PHASE_COUNT) %
                ROLLING_PHASE_COUNT;
            _cell_last_settlement_day[cell] = _last_committed_day - delta;
        }
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _market_signals.cell_offsets[cell + 1] += _market_signals.cell_offsets[cell];
    rebuild_market_signals();
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _labor_signals.cell_offsets[cell + 1] += _labor_signals.cell_offsets[cell];
    rebuild_labor_signals();
    std::string country_restore_error;
    if (!capture_country_epoch(country_restore_error)) {
        out["ok"] = false;
        out["reason"] = country_restore_error.c_str();
        return out;
    }
    if ((!_trade_orders.ids.empty() &&
         _trade_orders.next_id <= _trade_orders.ids.back()) ||
        _trade_orders.line_offsets.size() != _trade_orders.ids.size() + 1 ||
        _trade_orders.seller_offsets.size() != _trade_orders.ids.size() + 1) {
        out["ok"] = false;
        out["reason"] = "restore_trade_order_index_invalid";
        return out;
    }
    _bootstrapped = true;
    _fatal = false;
    _fatal_reason.clear();
    _epoch_active = false;
    _stage = Stage::AGGREGATE_PUBLISH;
    _trade_topology.clear();
    _trade_plan.clear_transient();
    rebuild_trade_arrival_buckets();
    rebuild_committed_summaries();
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    _settlement_watermark = _last_committed_day;
    _settlement_newest_day = _last_committed_day;
    bool have_populated = false;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_committed_cells[cell].population <= 0) continue;
        if (!have_populated) {
            _settlement_watermark = _cell_last_settlement_day[cell];
            _settlement_newest_day = _cell_last_settlement_day[cell];
            have_populated = true;
        } else {
            _settlement_watermark = std::min(
                _settlement_watermark, _cell_last_settlement_day[cell]);
            _settlement_newest_day = std::max(
                _settlement_newest_day, _cell_last_settlement_day[cell]);
        }
    }
    _settlement_max_age_days = have_populated
        ? std::max<int64_t>(0, _last_committed_day - _settlement_watermark) : 0;
    const int32_t restored_pages = _restore.restored_pages;
    const int32_t restored_commands = _restore.restored_commands;
    const int32_t restored_buildings = _restore.restored_buildings;
    const int32_t restored_schema = _restore.schema_version;
    _restore = {};
    trace_begin_epoch();
    trace_append(EVENT_RESTORE_BOUNDARY,
                 static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id, SCHEMA_VERSION, -1,
                 restored_pages, restored_commands, restored_buildings,
                 _last_committed_day, nullptr);
    trace_commit_epoch(0, 0, 0);
    out["ok"] = true;
    out["restored_pages"] = restored_pages;
    out["restored_commands"] = restored_commands;
    out["restored_buildings"] = restored_buildings;
    out["restored_trade_orders"] = _trade_orders.size();
    out["restored_trade_flows"] = static_cast<int64_t>(_trade_flows.cells.size());
    out["cohort_count"] = _population.active_count;
    out["state_hash_catalog"] = _catalog_hash;
    out["migration"] = restored_schema == 14
        ? "v14_rolling_phase_bootstrap" : "none";
    return out;
}

} // namespace pk
