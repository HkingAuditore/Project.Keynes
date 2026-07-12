#include "economy_runtime.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
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

namespace {

using Clock = std::chrono::steady_clock;

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
constexpr uint16_t SAVE_SECTION_END = 10;

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

bool NativeEconomyRuntime::drain_building_resource_deltas(std::vector<int64_t> &out) {
    if (!_resource_deltas_ready) return false;
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
        need_composites[need_index] = score_sum > 0
            ? mul_div_sat(score_sum, Q16_ONE, std::max<int64_t>(1, preference_sum), sat)
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
    _commands_per_slice = std::clamp(dict_num<int32_t>(profile, "commands_per_slice", 16384), 1, 1 << 20);
    _configured_epoch_days = std::clamp(
        dict_num<int32_t>(profile, "market_cycle_days", 5), 0, 3650);
    _max_epoch_days = std::clamp(
        dict_num<int32_t>(profile, "market_max_cycle_days", 365), 1, 3650);
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
    _treasury_cash = dict_num<int64_t>(profile, "treasury_cash", 0);
    _wealth_reference_per_capita = std::max<int64_t>(1, dict_num<int64_t>(
        profile, "wealth_reference_per_capita", MONEY_SCALE * 10));
    _living_cost_base_plan_stable_id =
        dict_string(profile, "living_cost_base_plan_id", "subsistence_household");
    _wage_ema_alpha_q16 = std::clamp(
        dict_num<int32_t>(profile, "wage_ema_alpha_q16", 8192), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_max_rise_q16_per_day = std::clamp(
        dict_num<int32_t>(profile, "wage_max_rise_q16_per_day", 6554), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_max_fall_q16_per_day = std::clamp(
        dict_num<int32_t>(profile, "wage_max_fall_q16_per_day", 1311), 0,
        static_cast<int32_t>(Q16_ONE));
    _employee_profit_share_q16 = std::clamp(
        dict_num<int32_t>(profile, "employee_profit_share_q16", 16384), 0,
        static_cast<int32_t>(Q16_ONE));
    _merchant_profession_stable_id = dict_string(profile, "merchant_profession_id", "merchant");
    const std::string runtime_mode = dict_string(profile, "market_runtime_mode", "PROBE");
    _market_runtime_mode = runtime_mode == "OFF" ? 0 : (runtime_mode == "PROBE" ? 1 : 2);
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

int32_t NativeEconomyRuntime::gather_resource_cells(
        int32_t cell, int32_t access_mode, int32_t *out_cells, int32_t capacity) const {
    if (out_cells == nullptr || capacity <= 0 || cell < 0 || cell >= _cell_count) return 0;
    int32_t count = 0;
    out_cells[count++] = cell;
    if (access_mode != 1 || _building_neighbors.size() != static_cast<size_t>(_cell_count) * 6) {
        return count;
    }
    for (int32_t direction = 0; direction < 6 && count < capacity; ++direction) {
        const int32_t neighbor = _building_neighbors[static_cast<size_t>(cell) * 6 + direction];
        if (neighbor < 0 || neighbor >= _cell_count) continue;
        bool duplicate = false;
        for (int32_t i = 0; i < count; ++i) {
            if (out_cells[i] == neighbor) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) out_cells[count++] = neighbor;
    }
    return count;
}

int32_t NativeEconomyRuntime::building_resource_access_cells(
        int32_t cell, int32_t resource_id, int32_t *out_cells, int32_t capacity) const {
    if (resource_id < 0 || resource_id >= static_cast<int32_t>(_resource_adjacent_access.size())) {
        return 0;
    }
    return gather_resource_cells(cell, _resource_adjacent_access[resource_id] != 0 ? 1 : 0,
                                 out_cells, capacity);
}

int64_t NativeEconomyRuntime::available_resource_amount(
        const ResourceAmount &item, int32_t cell) const {
    int32_t cells[7];
    const int32_t source_count = gather_resource_cells(cell, item.access_mode, cells, 7);
    int64_t total = 0;
    for (int32_t i = 0; i < source_count; ++i) {
        const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cells[i];
        const int64_t value = std::max<int64_t>(0, _resource_remaining[idx]);
        if (total > std::numeric_limits<int64_t>::max() - value) {
            return std::numeric_limits<int64_t>::max();
        }
        total += value;
    }
    return total;
}

void NativeEconomyRuntime::consume_resource_amount(
        const ResourceAmount &item, int32_t cell, int64_t quantity) {
    int32_t cells[7];
    const int32_t source_count = gather_resource_cells(cell, item.access_mode, cells, 7);
    int64_t remaining = std::max<int64_t>(0, quantity);
    for (int32_t i = 0; i < source_count && remaining > 0; ++i) {
        const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cells[i];
        const int64_t taken = std::min<int64_t>(remaining, std::max<int64_t>(0, _resource_remaining[idx]));
        if (taken <= 0) continue;
        _resource_remaining[idx] -= taken;
        _resource_deltas[idx] = saturating_sub(_resource_deltas[idx], taken, _saturation_count);
        remaining -= taken;
    }
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
    _staging_events.cashflow_cell =
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG)
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
    out["version"] = 2;
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
        !unique_sorted(_good_ids, "good") || !unique_sorted(_plan_ids, "plan")) return false;

    _good_default_price = packed_i32(catalog, "good_default_price");
    _good_default_stock = packed_i64(catalog, "good_initial_stock");
    _good_min_price = packed_i32(catalog, "good_min_price");
    _good_max_price = packed_i32(catalog, "good_max_price");
    _good_price_adjust_q16 = packed_i32(catalog, "good_price_adjust_q16");
    _good_demand_price_elasticity_q16 = packed_i32(catalog, "good_demand_price_elasticity_q16");
    _good_demand_ema_alpha_q16 = packed_i32(catalog, "good_demand_ema_alpha_q16");
    _good_target_inventory_days_q16 = packed_i32(catalog, "good_target_inventory_days_q16");
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
	_good_category_ids = packed_strings(catalog, "good_category_ids");
	_good_storage_modes = packed_i32(catalog, "good_storage_modes");
	_good_monetary_issue_values = packed_i64(catalog, "good_monetary_issue_values");
	_good_technology_tag_offsets = packed_i32(catalog, "good_technology_tag_offsets");
	_good_technology_tags = packed_strings(catalog, "good_technology_tags");
    const size_t goods = _good_ids.size();
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
    for (size_t i = 0; i < goods; ++i) {
        if (_good_default_price[i] < 0 || _good_min_price[i] < 0 ||
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
			 _good_ids[i] != "silver")) {
            error = "good_parameter_out_of_range";
            return false;
        }
    }
	_cycle_flow_good_ids.clear();
	for (size_t i = 0; i < goods; ++i) {
		if (_good_storage_modes[i] == 1) {
			_cycle_flow_good_ids.push_back(static_cast<int32_t>(i));
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
    const std::vector<int32_t> need_env = packed_i32(catalog, "need_quantity_env_curve_ids");
    const std::vector<int32_t> need_variant_offsets = packed_i32(catalog, "need_variant_offsets");
    const size_t need_count = need_stable.size();
    if (plan_offsets.size() != _plan_ids.size() + 1 || plan_offsets.front() != 0 ||
        plan_offsets.back() != static_cast<int32_t>(need_count) || need_priority.size() != need_count ||
        need_base.size() != need_count || need_wealth_elasticity.size() != need_count ||
        need_wealth_min.size() != need_count || need_wealth_max.size() != need_count ||
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
            need_env[n] < -1 || need_env[n] >= static_cast<int32_t>(_environment_curves.size()) ||
            need_living_weights[need_stable[n]] < 0 ||
            need_living_weights[need_stable[n]] > Q16_ONE ||
            variants_count <= 0 || variants_count > MAX_VARIANTS_PER_NEED) {
            error = "market_v2_need_entry_invalid";
            return false;
        }
        _needs[n] = {need_stable[n], need_priority[n], variants_begin, variants_count,
                     need_base[n], need_wealth_elasticity[n], need_wealth_min[n],
                     need_wealth_max[n], need_env[n],
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
    _ethnicity_need_factor_q16 = packed_i32(catalog, "ethnicity_need_factor_q16");
    if (_ethnicity_need_factor_q16.empty()) {
        _ethnicity_need_factor_q16.assign(_ethnicity_ids.size() * _need_ids.size(), Q16_ONE);
    }
    if (_ethnicity_need_factor_q16.size() != _ethnicity_ids.size() * _need_ids.size()) {
        error = "ethnicity_need_factor_size_mismatch";
        return false;
    }
    if (!compile_building_catalog(catalog, error)) return false;
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
    _catalog_hash = dict_num<int64_t>(catalog, "market_catalog_hash",
                                      dict_num<int64_t>(catalog, "catalog_hash", 0));
    _catalog_compat_hash_v6 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v6", 0);
    _catalog_compat_hash_v7 = dict_num<int64_t>(catalog, "market_catalog_compat_hash_v7", 0);
    _building_catalog_hash = dict_num<int64_t>(catalog, "building_catalog_hash", 1);
    _building_catalog_compat_hash_v6 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v6", 0);
    _building_catalog_compat_hash_v7 =
        dict_num<int64_t>(catalog, "building_catalog_compat_hash_v7", 0);
    if (_catalog_hash == 0) {
        error = "catalog_hash_required";
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::compile_building_catalog(const Dictionary &catalog,
                                                     std::string &error) {
    _building_type_ids = packed_strings(catalog, "building_type_ids");
    _resource_ids = packed_strings(catalog, "building_resource_ids");
    _resource_reserve_slots = packed_strings(catalog, "building_resource_reserve_slots");
    _resource_extra_slots = packed_strings(catalog, "building_resource_extra_slots");
    if (_resource_ids.size() != _resource_reserve_slots.size() ||
        _resource_ids.size() != _resource_extra_slots.size() ||
        !std::is_sorted(_resource_ids.begin(), _resource_ids.end()) ||
        std::adjacent_find(_resource_ids.begin(), _resource_ids.end()) != _resource_ids.end()) {
        error = "building_resource_catalog_invalid";
        return false;
    }
    if (_building_type_ids.empty()) {
        _building_types.clear();
        _building_employee_roles.clear();
        _building_construction_goods.clear();
        _building_inputs.clear();
        _building_outputs.clear();
        _building_output_cost_shares_q16.clear();
        _building_resources.clear();
        _building_resource_generation.clear();
        _resource_adjacent_access.assign(_resource_ids.size(), uint8_t{0});
        _building_conditions.clear();
        return true;
    }
    if (!std::is_sorted(_building_type_ids.begin(), _building_type_ids.end()) ||
        std::adjacent_find(_building_type_ids.begin(), _building_type_ids.end()) !=
            _building_type_ids.end() || _building_type_ids.size() > 4096) {
        error = "building_type_ids_not_sorted_unique";
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
        !compile_goods(input_goods, input_qty, _building_inputs,
                       "building_input_good_invalid") ||
        !compile_goods(output_goods, output_qty, _building_outputs,
                       "building_output_good_invalid")) return false;
    _building_resources.resize(resource_ids.size());
    _resource_adjacent_access.assign(_resource_ids.size(), uint8_t{0});
    for (size_t i = 0; i < resource_ids.size(); ++i) {
        if (resource_ids[i] < 0 || resource_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            resource_qty[i] <= 0 || resource_modes[i] < 0 || resource_modes[i] > 1 ||
            resource_access_modes[i] < 0 || resource_access_modes[i] > 1) {
            error = "building_production_resource_invalid";
            return false;
        }
        _building_resources[i] = {resource_ids[i], resource_qty[i], resource_modes[i],
                                  resource_access_modes[i]};
        if (resource_access_modes[i] == 1) {
            _resource_adjacent_access[resource_ids[i]] = 1;
        }
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
    for (size_t i = 0; i < types; ++i) {
        if (owner_prof[i] < 0 || owner_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
			owner_slots[i] != 1 || wages[i] < 0 || construction_days[i] < 0 ||
			_building_kinds[i] < 0 || _building_kinds[i] > 1 ||
            behavior_ids[i] < 0 || behavior_ids[i] > 2 || behavior_versions[i] != 1 ||
			output_offsets[i] == output_offsets[i + 1] ||
			(_building_kinds[i] == 0 && resource_offsets[i] == resource_offsets[i + 1]) ||
			(_building_kinds[i] == 1 && resource_offsets[i] != resource_offsets[i + 1]) ||
			(_building_kinds[i] == 0 && behavior_ids[i] == 0) ||
			(_building_kinds[i] == 1 && behavior_ids[i] != 0) ||
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
			_building_kinds[i], owner_prof[i], owner_slots[i], wages[i],
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
    std::vector<SavedRole> saved;
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
    }
    std::sort(saved.begin(), saved.end(), [](const SavedRole &a, const SavedRole &b) {
        return std::tie(a.cell, a.type, a.owner, a.role) <
               std::tie(b.cell, b.type, b.owner, b.role);
    });
    std::stable_sort(_buildings.begin(), _buildings.end(), [](const BuildingGroup &a,
                                                               const BuildingGroup &b) {
        if (a.cell != b.cell) return a.cell < b.cell;
        if (a.type_id != b.type_id) return a.type_id < b.type_id;
        return a.owner_signature_id < b.owner_signature_id;
    });
    size_t role_count = 0;
    for (BuildingGroup &group : _buildings) {
        group.employee_fill_begin = static_cast<int32_t>(role_count);
        if (group.type_id >= 0 && group.type_id < static_cast<int32_t>(_building_types.size())) {
            role_count += static_cast<size_t>(_building_types[group.type_id].employee_count);
        }
    }
    _building_employee_filled.assign(role_count, 0);
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
                    _market_signals.cost_anchor_price[i]});
            }
        }
    }
    std::vector<std::pair<int32_t, int32_t>> keys;
    for (const BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t i = 0; i < type.input_count; ++i)
            keys.emplace_back(group.cell, _building_inputs[type.input_begin + i].good_id);
        for (int32_t i = 0; i < type.output_count; ++i)
            keys.emplace_back(group.cell, _building_outputs[type.output_begin + i].good_id);
    }
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    _market_signals.clear(_cell_count);
    _market_signals.good_ids.reserve(keys.size());
    _market_signals.business_demand_ema.assign(keys.size(), 0);
    _market_signals.offered_supply_ema.assign(keys.size(), 0);
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
            _market_signals.cost_anchor_price[i] = saved[old_cursor].anchor;
        }
    }
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
    const int32_t market = _market.cell_to_market[cell];
    const auto price_begin = _market.price.begin() +
        static_cast<int64_t>(market) * _market.good_count;
    const bool same_basis =
        cached_prices.size() == static_cast<size_t>(_market.good_count) &&
        cached_catalog_hash == _catalog_hash &&
        cached_temperature == _environment_temperature_q16[cell] &&
        cached_moisture == _environment_moisture_q16[cell] &&
        cached_snow == _environment_snow_q16[cell] &&
        cached_weather == _environment_weather_q16[cell] &&
        std::equal(cached_prices.begin(), cached_prices.end(), price_begin);
    if (!same_basis) {
        cached_prices.assign(price_begin, price_begin + _market.good_count);
        cached_catalog_hash = _catalog_hash;
        cached_temperature = _environment_temperature_q16[cell];
        cached_moisture = _environment_moisture_q16[cell];
        cached_snow = _environment_snow_q16[cell];
        cached_weather = _environment_weather_q16[cell];
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
            int64_t weighted_price = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant = need.variant_begin + v;
                weighted_price = saturating_add(weighted_price,
                    saturating_mul(variant_prices[variant],
                                   variant_scores[variant], sat), sat);
            }
            weighted_price /= score_sum;
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
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession) continue;
                const int32_t index = group.employee_fill_begin + r;
                const int64_t floor = std::max(general_cost, role_cost);
                int64_t current = _building_role_contract_wage[index] > 0
                    ? _building_role_contract_wage[index] : role.reference_wage_per_day;
                int64_t next = role.reference_wage_per_day;
                if (role.wage_policy == 2) {
                    const int64_t desired = std::max(floor, local_average);
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

bool NativeEconomyRuntime::prepare_building_economic_plan(std::string &error) {
    const auto started = Clock::now();
    for (BuildingGroup &group : _buildings) {
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size())) {
            error = "building_economic_plan_group_invalid";
            return false;
        }
        const BuildingType &type = _building_types[group.type_id];
        const int32_t market = _market.cell_to_market[group.cell];
        int64_t input_cost = 0;
        int64_t employee_wages = 0;
        int64_t revenue = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const GoodAmount &item = _building_inputs[type.input_begin + i];
            input_cost = saturating_add(input_cost, mul_div_sat(
                item.quantity, _market.price[_market.index(market, item.good_id)],
                GOODS_SCALE, _saturation_count), _saturation_count);
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
            if (settlement <= 0) settlement = mul_div_sat(
                _market.price[_market.index(market, item.good_id)],
                _good_merchant_buy_factor_q16[item.good_id], Q16_ONE,
                _saturation_count);
            revenue = saturating_add(revenue, mul_div_sat(
                item.quantity, settlement, GOODS_SCALE, _saturation_count),
                _saturation_count);
        }
        const int64_t operating = saturating_add(input_cost, employee_wages, _saturation_count);
        const int64_t required = saturating_add(operating, mul_div_sat(
            operating, type.target_operating_margin_q16, Q16_ONE,
            _saturation_count), _saturation_count);
        int64_t margin_gap = required <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, required, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, required), _saturation_count);
        margin_gap = std::clamp<int64_t>(margin_gap, -Q16_ONE, Q16_ONE);
        group.sample_unit_input_cost = input_cost;
        group.last_margin_gap_q16 = static_cast<int32_t>(margin_gap);
        // Profitability is diagnostic and bonus input. Losses no longer reduce
        // employment or planned utilization while the owner can fund payroll.
        group.planned_utilization_q16 = static_cast<int32_t>(Q16_ONE);
        const int64_t group_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        group.last_expected_revenue = saturating_mul(group_days, revenue, _saturation_count);
        if (margin_gap < 0) ++_unprofitable_building_groups;
        _utilization_sum_q16 = saturating_add(_utilization_sum_q16, Q16_ONE,
                                               _saturation_count);
    }
    _building_plan_ms += elapsed_ms(started);
    return true;
}

NativeEconomyRuntime::PricePressure NativeEconomyRuntime::price_pressure(
        int32_t market, int32_t good, int64_t household_demand, int64_t stock,
        int64_t shortage_q16, int32_t signal_index, int64_t &sat) const {
    PricePressure out;
    out.household_demand = std::max<int64_t>(0, household_demand);
    if (signal_index >= 0) {
        out.business_demand = _market_signals.business_demand_ema[signal_index];
        out.supply = _market_signals.offered_supply_ema[signal_index];
    }
    const int64_t demand = saturating_add(out.household_demand, out.business_demand, sat);
    const int64_t flow = saturating_add(demand, out.supply, sat);
    out.excess_q16 = std::clamp<int64_t>(mul_div_sat(
        saturating_sub(demand, out.supply, sat), Q16_ONE,
        std::max<int64_t>(GOODS_SCALE, flow), sat), -Q16_ONE, Q16_ONE);
    if (_good_storage_modes[good] == 0) {
        const int64_t target = mul_div_sat(
            demand, _good_target_inventory_days_q16[good], Q16_ONE, sat);
        out.inventory_q16 = std::clamp<int64_t>(mul_div_sat(
            saturating_sub(target, stock, sat), Q16_ONE,
            std::max<int64_t>(GOODS_SCALE, target), sat), -Q16_ONE, Q16_ONE);
        out.shortage_q16 = std::clamp<int64_t>(shortage_q16, 0, Q16_ONE);
    }
    const int64_t price = std::max<int64_t>(1, _market.price[_market.index(market, good)]);
    if (signal_index >= 0 && _good_monetary_issue_values[good] == 0 &&
        _market_signals.cost_anchor_price[signal_index] > 0) {
        const int64_t anchor = _market_signals.cost_anchor_price[signal_index];
        const int64_t confidence = std::min<int64_t>(Q16_ONE, mul_div_sat(
            out.supply, Q16_ONE, std::max<int64_t>(GOODS_SCALE, demand), sat));
        out.cost_q16 = mul_div_sat(std::clamp<int64_t>(mul_div_sat(
            anchor - price, Q16_ONE, std::max<int64_t>(anchor, price), sat),
            -Q16_ONE, Q16_ONE), confidence, Q16_ONE, sat);
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
                                                     int32_t cashflow_source) {
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
                                                    int32_t cashflow_source) {
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
        int64_t filled_jobs, int64_t due, int64_t payment_cap) {
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
        const int64_t qty = saturating_mul(item.quantity, count, _saturation_count);
        if (_market.stock[_market.index(market, item.good_id)] < qty) {
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
    trace_append(EVENT_CONSTRUCTION_STARTED, static_cast<int32_t>(Stage::LEDGER_APPLY),
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
    return true;
}

bool NativeEconomyRuntime::run_building_employment_cell(int32_t cell, std::string &error) {
    if (!prepare_cell_wages(cell, error)) return false;
    thread_local std::vector<int64_t> demand;
    thread_local std::vector<int64_t> available;
    thread_local std::vector<int64_t> fill;
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    demand.assign(professions, 0);
    available.assign(professions, 0);
    fill.assign(professions, 0);
    const int32_t first = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t last = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    auto planned_role_demand = [&](const BuildingGroup &group, const JobRole &role) {
        const int64_t full = saturating_mul(group.count, role.slots_per_building,
                                            _saturation_count);
        int64_t scaled = mul_div_sat(full, group.planned_utilization_q16, Q16_ONE,
                                     _saturation_count);
        if (scaled == 0 && full > 0 && group.planned_utilization_q16 > 0) scaled = 1;
        return scaled;
    };
    const bool trace_detail = trace_detail_for_cell(cell);
    thread_local std::vector<int32_t> trace_slots;
    thread_local std::vector<int64_t> trace_owner_before;
    thread_local std::vector<int64_t> trace_employee_before;
    trace_slots.clear(); trace_owner_before.clear(); trace_employee_before.clear();
    if (trace_detail) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            trace_slots.push_back(slot);
            trace_owner_before.push_back(_population.owner_employed[slot]);
            trace_employee_before.push_back(_population.employee_employed[slot]);
        });
    }
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        _population.owner_employed[slot] = 0;
        _population.employee_employed[slot] = 0;
    });
    for (int32_t g = first; g < last; ++g) {
        if (_buildings[g].cell == cell && _buildings[g].count > 0) {
            _buildings[g].filled_owner = 0;
            const BuildingType &type = _building_types[_buildings[g].type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                _building_employee_filled[_buildings[g].employee_fill_begin + r] = 0;
            }
        }
    }
    if (first < last) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            int64_t total_owner_demand = 0;
            for (int32_t g = first; g < last; ++g) {
                BuildingGroup &group = _buildings[g];
                if (group.cell != cell || group.count <= 0 || group.owner_signature_id != signature) continue;
                const BuildingType &type = _building_types[group.type_id];
                total_owner_demand = saturating_add(total_owner_demand,
                    saturating_mul(group.count, type.owner_slots_per_building, _saturation_count),
                    _saturation_count);
            }
            const int64_t total_fill = std::min(_population.population[slot], total_owner_demand);
            int64_t prefix = 0;
            int64_t distributed = 0;
            for (int32_t g = first; g < last; ++g) {
                BuildingGroup &group = _buildings[g];
                if (group.cell != cell || group.count <= 0 || group.owner_signature_id != signature) continue;
                const BuildingType &type = _building_types[group.type_id];
                prefix = saturating_add(prefix,
                    saturating_mul(group.count, type.owner_slots_per_building, _saturation_count),
                    _saturation_count);
                const int64_t next = total_owner_demand > 0
                    ? mul_div_sat(total_fill, prefix, total_owner_demand, _saturation_count) : 0;
                group.filled_owner = std::max<int64_t>(0, next - distributed);
                distributed = next;
            }
            _population.owner_employed[slot] = total_fill;
            _filled_owner_jobs = saturating_add(_filled_owner_jobs, total_fill, _saturation_count);
        });
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t profession = _signatures[signature].profession_id;
            available[profession] = saturating_add(available[profession],
                std::max<int64_t>(0, _population.population[slot] - _population.owner_employed[slot]),
                _saturation_count);
        });
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                demand[role.profession_id] = saturating_add(demand[role.profession_id],
                    planned_role_demand(group, role),
                    _saturation_count);
            }
        }
        std::vector<int64_t> prefix(professions, 0);
        std::vector<int64_t> distributed(professions, 0);
        for (int32_t g = first; g < last; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int32_t p = role.profession_id;
                const int64_t role_demand = planned_role_demand(group, role);
                prefix[p] = saturating_add(prefix[p], role_demand, _saturation_count);
                const int64_t total = std::min(available[p], demand[p]);
                const int64_t next = demand[p] > 0
                    ? mul_div_sat(total, prefix[p], demand[p], _saturation_count) : 0;
                const int64_t role_fill = std::max<int64_t>(0, next - distributed[p]);
                distributed[p] = next;
                _building_employee_filled[group.employee_fill_begin + r] = role_fill;
                fill[p] = saturating_add(fill[p], role_fill, _saturation_count);
            }
        }
        std::fill(prefix.begin(), prefix.end(), 0);
        std::fill(distributed.begin(), distributed.end(), 0);
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            const int32_t p = _signatures[signature].profession_id;
            const int64_t cohort_available = std::max<int64_t>(
                0, _population.population[slot] - _population.owner_employed[slot]);
            prefix[p] = saturating_add(prefix[p], cohort_available, _saturation_count);
            const int64_t next = available[p] > 0
                ? mul_div_sat(fill[p], prefix[p], available[p], _saturation_count) : 0;
            _population.employee_employed[slot] = std::max<int64_t>(0, next - distributed[p]);
            distributed[p] = next;
            _filled_employee_jobs = saturating_add(_filled_employee_jobs,
                _population.employee_employed[slot], _saturation_count);
        });
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
        _unemployed_population = saturating_add(_unemployed_population, unemployed,
                                                _saturation_count);
    });
    std::vector<EventLeg> event_legs;
    if (trace_detail) {
        for (size_t i = 0; i < trace_slots.size(); ++i) {
            const int32_t slot = trace_slots[i];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(slot));
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

bool NativeEconomyRuntime::run_building_production_cell(int32_t cell, std::string &error) {
    struct Offer { int32_t good = -1; int32_t owner_slot = -1; int32_t group = -1; int64_t qty = 0; };
    thread_local std::vector<Offer> offers;
    offers.clear();
    const int32_t market = _market.cell_to_market[cell];
    const int32_t begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
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
        group.last_base_wages_paid = group.last_base_wages_due = 0;
        group.last_bonus_paid = group.last_bonus_due = 0;
        group.wage_suspended = 0;
        const BuildingType &type = _building_types[group.type_id];
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
        if (_buildings[g].count > 0)
            payroll_owners.push_back(_buildings[g].owner_signature_id);
    }
    std::sort(payroll_owners.begin(), payroll_owners.end());
    payroll_owners.erase(std::unique(payroll_owners.begin(), payroll_owners.end()),
                         payroll_owners.end());
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t g = begin; g < end; ++g) {
            if (_buildings[g].owner_signature_id == owner_signature)
                total_due = saturating_add(total_due,
                    _buildings[g].last_base_wages_due, _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(0, _population.funds[owner_slot])) : 0;
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
                const int64_t due = _building_role_base_wage_due[role_index];
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap);
                _building_role_base_wage_paid[role_index] = paid;
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
                group.last_base_wages_paid = saturating_add(
                    group.last_base_wages_paid, paid, _saturation_count);
            }
        }
        const bool suspended = owner_paid < total_due;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature) continue;
            group.wage_suspended = suspended ? 1 : 0;
            if (suspended) ++_wage_suspended_building_groups;
            group.last_wages_paid = group.last_base_wages_paid;
            group.last_operating_cost = group.last_base_wages_due;
        }
        _building_base_wages_due = saturating_add(
            _building_base_wages_due, total_due, _saturation_count);
        _building_base_wages_paid = saturating_add(
            _building_base_wages_paid, owner_paid, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
    }
    auto process_phase = [&](bool cycle_flow_phase) -> bool {
        offers.clear();
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0) continue;
            if (group.wage_suspended != 0) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (produces_cycle_flow(type) != cycle_flow_phase) continue;
            ++_processed_building_groups;
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            const int64_t owner_demand = saturating_mul(
                group.count, type.owner_slots_per_building, _saturation_count);
            int64_t scale_q16 = owner_demand > 0
                ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                    group.filled_owner, Q16_ONE, owner_demand, _saturation_count)) : 0;
            scale_q16 = std::min<int64_t>(scale_q16, group.planned_utilization_q16);
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t role_demand = saturating_mul(
                    group.count, role.slots_per_building, _saturation_count);
                const int64_t role_fill = _building_employee_filled[group.employee_fill_begin + r];
                const int64_t role_scale = role_demand > 0
                    ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                        role_fill, Q16_ONE, role_demand, _saturation_count)) : Q16_ONE;
                scale_q16 = std::min(scale_q16, role_scale);
            }
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days), _saturation_count);
            for (int32_t i = 0; i < type.input_count; ++i) {
                const GoodAmount &item = _building_inputs[type.input_begin + i];
                const int64_t base = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                if (base > 0) scale_q16 = std::min(scale_q16, mul_div_sat(
                    _market.stock[_market.index(market, item.good_id)], Q16_ONE,
                    base, _saturation_count));
            }
            const int64_t base_cost = saturating_mul(
                building_days, group.sample_unit_input_cost, _saturation_count);
            if (base_cost > 0) scale_q16 = std::min(scale_q16, mul_div_sat(
                std::max<int64_t>(0, _population.funds[owner_slot]), Q16_ONE,
                base_cost, _saturation_count));
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
                    if (resource_scale < scale_q16) resource_limited = true;
                    if (item.mode == 1 && resource_scale < scale_q16) {
                        resource_capacity_limited = true;
                    }
                    scale_q16 = std::min(scale_q16, resource_scale);
                }
            }
            scale_q16 = std::clamp<int64_t>(scale_q16, 0, Q16_ONE);
            if (resource_limited) ++_building_resource_limited_groups;
            if (resource_capacity_limited) ++_building_resource_capacity_limited_groups;
            group.last_capacity_q16 = scale_q16;
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
            touch_accounting_slot(owner_slot);
            const int64_t actual_cost = mul_div_sat(
                base_cost, scale_q16, Q16_ONE, _saturation_count);
            for (int32_t i = 0; i < type.input_count; ++i) {
                const GoodAmount &item = _building_inputs[type.input_begin + i];
                const int64_t qty = mul_div_sat(saturating_mul(
                    building_days, item.quantity, _saturation_count),
                    scale_q16, Q16_ONE, _saturation_count);
                _market.stock[_market.index(market, item.good_id)] -= qty;
                group.last_input = saturating_add(group.last_input, qty, _saturation_count);
                _production_inputs_consumed = saturating_add(
                    _production_inputs_consumed, qty, _saturation_count);
                if (_good_storage_modes[item.good_id] == 1) {
                    _cycle_flow_consumed = saturating_add(
                        _cycle_flow_consumed, qty, _saturation_count);
                }
            }
            if (actual_cost > _population.funds[owner_slot]) {
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
                                       CASHFLOW_MERCHANT_BUSINESS) != actual_cost) {
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
                if (qty > 0) offers.push_back({item.good_id, owner_slot, g, qty});
                group.last_output = saturating_add(
                    group.last_output, qty, _saturation_count);
            }
        }
        std::stable_sort(offers.begin(), offers.end(), [&](const Offer &a, const Offer &b) {
            const int32_t pa = _market.price[_market.index(market, a.good)];
            const int32_t pb = _market.price[_market.index(market, b.good)];
            if (pa != pb) return pa > pb;
            if (a.good != b.good) return a.good < b.good;
            return a.group < b.group;
        });
        for (const Offer &offer : offers) {
            BuildingGroup &group = _buildings[offer.group];
            const int64_t issue_value = _good_monetary_issue_values[offer.good];
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                _market.price[_market.index(market, offer.good)],
                _good_merchant_buy_factor_q16[offer.good], Q16_ONE, _saturation_count));
            int64_t sold = offer.qty;
            int64_t paid = 0;
            if (issue_value > 0) {
                paid = mul_div_sat(sold, issue_value, GOODS_SCALE, _saturation_count);
                _explicit_money_mint = saturating_add(
                    _explicit_money_mint, paid, _saturation_count);
                _anchored_money_issued = saturating_add(
                    _anchored_money_issued, paid, _saturation_count);
                if (_good_ids[offer.good] == "gold") {
                    _gold_accepted = saturating_add(_gold_accepted, sold, _saturation_count);
                    _gold_money_issued = saturating_add(
                        _gold_money_issued, paid, _saturation_count);
                } else {
                    _silver_accepted = saturating_add(_silver_accepted, sold, _saturation_count);
                    _silver_money_issued = saturating_add(
                        _silver_money_issued, paid, _saturation_count);
                }
            } else {
                int64_t merchant_cash = 0;
                for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
                    merchant_cash = saturating_add(merchant_cash,
                        std::max<int64_t>(0, _population.funds[_merchant_slots[k]]),
                        _saturation_count);
                }
                sold = std::min(offer.qty, mul_div_sat(
                    merchant_cash, GOODS_SCALE, buy_price, _saturation_count));
                const int64_t payment = mul_div_sat(
                    sold, buy_price, GOODS_SCALE, _saturation_count);
                paid = debit_local_merchants(cell, payment,
                                             CASHFLOW_MERCHANT_PROCUREMENT);
                if (paid != payment) {
                    error = "merchant_purchase_payment_drift";
                    return false;
                }
            }
            touch_accounting_slot(offer.owner_slot);
            _population.funds[offer.owner_slot] = saturating_add(
                _population.funds[offer.owner_slot], paid, _saturation_count);
            _population.epoch_income[offer.owner_slot] = saturating_add(
                _population.epoch_income[offer.owner_slot], paid, _saturation_count);
            trace_record_cashflow(cell, _population.handle_for_slot(offer.owner_slot),
                                  CASHFLOW_OWNER_OPERATIONS, paid, 0);
            _market.stock[_market.index(market, offer.good)] = saturating_add(
                _market.stock[_market.index(market, offer.good)], sold, _saturation_count);
            group.last_sold = saturating_add(group.last_sold, sold, _saturation_count);
            group.last_discarded = saturating_add(
                group.last_discarded, offer.qty - sold, _saturation_count);
            group.last_revenue = saturating_add(group.last_revenue, paid, _saturation_count);
            _production_output_stock = saturating_add(
                _production_output_stock, sold, _saturation_count);
            _production_output_discarded = saturating_add(
                _production_output_discarded, offer.qty - sold, _saturation_count);
            _producer_revenue = saturating_add(_producer_revenue, paid, _saturation_count);
            if (_good_storage_modes[offer.good] == 1) {
                _cycle_flow_produced = saturating_add(
                    _cycle_flow_produced, sold, _saturation_count);
            }
        }
        return true;
    };
    if (!process_phase(true) || !process_phase(false)) return false;

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
            ? std::min(total_due, std::max<int64_t>(0, _population.funds[owner_slot])) : 0;
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
                    _building_employee_filled[role_index], due, cap);
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
    update_cell_labor_signals(cell);
    const auto signal_started = Clock::now();
    thread_local std::vector<int64_t> business_observed;
    thread_local std::vector<int64_t> supply_observed;
    thread_local std::vector<int64_t> anchor_weighted;
    thread_local std::vector<int64_t> anchor_quantity;
    business_observed.assign(_market.good_count, 0);
    supply_observed.assign(_market.good_count, 0);
    anchor_weighted.assign(_market.good_count, 0);
    anchor_quantity.assign(_market.good_count, 0);
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        if (group.wage_suspended != 0) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const GoodAmount &item = _building_inputs[type.input_begin + i];
            const int64_t planned = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.planned_utilization_q16, Q16_ONE, _saturation_count);
            business_observed[item.good_id] = saturating_add(
                business_observed[item.good_id], planned, _saturation_count);
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
            supply_observed[item.good_id] = saturating_add(
                supply_observed[item.good_id], qty, _saturation_count);
            if (qty <= 0) continue;
            int64_t next_allocated = 0;
            if (type.output_cost_share_count > 0) {
                prefix = saturating_add(prefix,
                    _building_output_cost_shares_q16[type.output_cost_share_begin + i],
                    _saturation_count);
                next_allocated = mul_div_sat(group.last_operating_cost, prefix,
                                              Q16_ONE, _saturation_count);
            } else {
                prefix = saturating_add(prefix, saturating_mul(
                    item.quantity, _good_default_price[item.good_id], _saturation_count),
                    _saturation_count);
                next_allocated = reference_total > 0 ? mul_div_sat(
                    group.last_operating_cost, prefix, reference_total,
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
            const int64_t retail_target = mul_div_sat(
                settlement_unit, Q16_ONE,
                std::max<int32_t>(1, _good_merchant_buy_factor_q16[item.good_id]),
                _saturation_count);
            anchor_weighted[item.good_id] = saturating_add(
                anchor_weighted[item.good_id], saturating_mul(
                    retail_target, qty, _saturation_count), _saturation_count);
            anchor_quantity[item.good_id] = saturating_add(
                anchor_quantity[item.good_id], qty, _saturation_count);
        }
    }
    if (_market_signals.cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            const int32_t good = _market_signals.good_ids[signal];
            const int64_t business_daily = business_observed[good] / std::max(1, _epoch_days);
            const int64_t supply_daily = supply_observed[good] / std::max(1, _epoch_days);
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
            if (anchor_quantity[good] > 0) {
                const int64_t observed = anchor_weighted[good] / anchor_quantity[good];
                const int64_t cost_alpha = std::min<int64_t>(Q16_ONE,
                    static_cast<int64_t>(_good_cost_ema_alpha_q16[good]) * _epoch_days);
                const int64_t old_anchor = _market_signals.cost_anchor_price[signal] > 0
                    ? _market_signals.cost_anchor_price[signal] : observed;
                const int64_t next_anchor = saturating_add(
                    mul_div_sat(old_anchor, Q16_ONE - cost_alpha, Q16_ONE, _saturation_count),
                    mul_div_sat(observed, cost_alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
                _market_signals.cost_anchor_price[signal] = static_cast<int32_t>(
                    std::clamp<int64_t>(next_anchor, _good_min_price[good],
                                        _good_max_price[good]));
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
    return true;
}

void NativeEconomyRuntime::commit_ready_construction() {
    bool changed = false;
    for (const PendingConstruction &pending : _pending_construction) {
        if (pending.ready_day > _current_day) continue;
        changed = true;
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
                                    [](const BuildingGroup &g) { return g.count <= 0; }),
                     _buildings.end());
    changed = changed || _buildings.size() != buildings_before;
    if (changed) rebuild_building_role_storage();
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
    _building_employee_filled.clear();
    _pending_construction.clear();
    _building_context_day = -1;
    _committed_cells.assign(cell_count, {});
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
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
    _building_role_contract_wage.clear();
    _building_role_base_living_cost.clear();
    _building_role_living_cost.clear();
    _building_role_local_average_wage.clear();
    _building_role_base_wage_due.clear();
    _building_role_base_wage_paid.clear();
    _building_role_bonus_due.clear();
    _building_role_bonus_paid.clear();
    _pending_construction.clear();

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
                if (price[idx] < _good_min_price[g] || price[idx] > _good_max_price[g]) {
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
    if (market_packet.has("treasury_cash")) {
        _treasury_cash = dict_num<int64_t>(market_packet, "treasury_cash", _treasury_cash);
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
    _epoch_days = choose_epoch_days(_population.active_count);
    _commit_lag_budget_days = std::max(0, _epoch_days - 1);
    if (_auto_slice_by_scale) {
        _cells_per_slice = std::max(1, (_market.market_count + _epoch_days - 1) /
                                           _epoch_days);
    }
    _last_committed_day = -_epoch_days;
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
    out["markets_per_slice"] = _cells_per_slice;
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["approximation_model"] = "frozen_sample_adaptive_price_v2";
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
        if (opcodes[i] < COMMAND_TRANSFER_TO_COHORT || opcodes[i] > COMMAND_DEMOLISH ||
            days[i] < 0 || sequences[i] < 0 ||
            (i64_0[i] < 0 && opcodes[i] != COMMAND_ADD_POPULATION)) {
            out["ok"] = false;
            out["reason"] = "command_entry_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (opcodes[i] != COMMAND_ADD_STOCK && opcodes[i] != COMMAND_REMOVE_STOCK) {
            int32_t slot = -1;
            if (!_population.valid_handle(static_cast<uint64_t>(handles[i]), slot)) {
                out["ok"] = false;
                out["reason"] = "stale_or_invalid_cohort_handle";
                out["index"] = static_cast<int64_t>(i);
                return out;
            }
        }
        if ((opcodes[i] == COMMAND_ADD_STOCK || opcodes[i] == COMMAND_REMOVE_STOCK) &&
            (i32_0[i] < 0 || i32_0[i] >= _market.market_count || i32_1[i] < 0 ||
             i32_1[i] >= _market.good_count)) {
            out["ok"] = false;
            out["reason"] = "command_market_target_invalid";
            out["index"] = static_cast<int64_t>(i);
            return out;
        }
        if (opcodes[i] == COMMAND_ADD_STOCK && _merchant_primary_slot[i32_0[i]] < 0) {
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

int32_t NativeEconomyRuntime::choose_epoch_days(int64_t cohorts) const {
    if (_configured_epoch_days > 0) {
        return std::min(_configured_epoch_days, _max_epoch_days);
    }
    if (!_auto_slice_by_scale || cohorts <= 0) return 1;
    const int64_t days = (cohorts + _target_cohorts_per_slice - 1) /
                         _target_cohorts_per_slice;
    return static_cast<int32_t>(std::clamp<int64_t>(days, 1, _max_epoch_days));
}

bool NativeEconomyRuntime::should_run(int64_t day_index) const {
    // PROBE is deliberately non-authoritative. It may be exercised by explicit
    // focused tests/benchmarks, but the production scheduler must not mutate the
    // committed market until the ACTIVE performance gate has passed.
    if (!_bootstrapped || _fatal || _save.active || _restore.active || _market_runtime_mode != 2)
        return false;
    return _epoch_active || day_index - _last_committed_day >= _epoch_days;
}

void NativeEconomyRuntime::clear_epoch_metrics() {
    _cell_cursor = 0;
    _command_cursor = 0;
    _structural_cursor = 0;
    _building_cell_cursor = 0;
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
    _production_inputs_consumed = 0;
    _production_output_stock = 0;
    _production_output_discarded = 0;
    _producer_revenue = 0;
	_anchored_money_issued = 0;
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
    _building_plan_ms = 0.0;
    _market_signal_ms = 0.0;
    _wage_plan_ms = 0.0;
    _labor_signal_ms = 0.0;
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
    _structural_funds_to_treasury = 0;
    _publish_accum = {};
    _staging_cells = _committed_cells;
    _resource_remaining = _resource_snapshot;
    _resource_deltas.assign(_resource_snapshot.size(), 0);
    _resource_deltas_ready = false;
}

bool NativeEconomyRuntime::start_epoch(int64_t day_index, std::string &error) {
    if (!_bootstrapped || _fatal || _epoch_active) {
        error = "epoch_start_state_invalid";
        return false;
    }
    if (day_index - _last_committed_day < _epoch_days) return true;
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
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_committed_cells[cell].population > 0 && _merchant_primary_slot[cell] < 0) {
            error = "merchant_invariant_broken_before_cycle";
            return false;
        }
    }
    clear_epoch_metrics();
    if (!prepare_building_economic_plan(error)) return false;
    _opening_totals = _closing_totals;
    _sample_day = day_index;
    _current_day = day_index;
    _epoch_active = true;
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
                                    cmd.opcode != COMMAND_REMOVE_STOCK;
        int32_t slot = -1;
        if (targets_cohort && !_population.valid_handle(cmd.target_handle, slot)) {
            ++_rejected_commands;
            return true;
        }
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= _market.market_count || cmd.i32_1 < 0 ||
             cmd.i32_1 >= _market.good_count)) {
            ++_rejected_commands;
            return true;
        }
        if (cmd.opcode == COMMAND_ADD_STOCK && _merchant_primary_slot[cmd.i32_0] < 0) {
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
    _stage = Stage::LEDGER_APPLY;
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
            const int64_t amount = std::min(std::max<int64_t>(0, cmd.i64_0),
                                            std::max<int64_t>(0, _treasury_cash));
            const int64_t treasury_before = _treasury_cash;
            const int64_t funds_before = _population.funds[slot];
            const int64_t income_before = _population.epoch_income[slot];
            _treasury_cash = saturating_sub(_treasury_cash, amount, _saturation_count);
            _population.funds[slot] = saturating_add(_population.funds[slot], amount, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, amount, 0);
            settled_value = amount;
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, _treasury_cash);
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
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            const int64_t funds_before = _population.funds[slot];
            const int64_t treasury_before = _treasury_cash;
            const int64_t expense_before = _population.epoch_expense[slot];
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            _treasury_cash = saturating_add(_treasury_cash, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, _treasury_cash);
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
    int64_t &sat = result.saturation_count;
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
    good_demand.assign(_market.good_count, 0);
    good_sales.assign(_market.good_count, 0);
    opening_stock.resize(_market.good_count);
    for (int32_t good = 0; good < _market.good_count; ++good) {
        opening_stock[good] = _market.stock[_market.index(market, good)];
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

    const auto formula_start = Clock::now();
    // Price and environment are frozen for the whole market tick. Compile the
    // variant side once per market instead of repeating it for every cohort.
    build_demand_basis(market, environment_sample_for_cell(market),
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
            const int64_t score_sum = need_score_sum_cache[need_index];
            if (score_sum <= 0) continue;
            const int64_t desired = desired_need_units(
                slot, need_index, _epoch_days, need_environment_cache[need_index],
                need_composite_cache[need_index], sat);
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
    result.formula_ms += elapsed_ms(formula_start);

    auto budget_orders = [&](std::vector<BundleOrder> &orders, bool use_remaining) {
        size_t begin = 0;
        while (begin < orders.size()) {
            const int32_t local = orders[begin].local_cohort;
            const int32_t priority = orders[begin].priority;
            size_t end = begin + 1;
            while (end < orders.size() && orders[end].local_cohort == local &&
                   orders[end].priority == priority) ++end;
            int64_t remaining = std::max<int64_t>(0, _population.funds[slots[local]] -
                                                       (use_remaining ? cohort_spend[local] : 0));
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
            abundant &= _market.stock[_market.index(market, good)] >= pass_demand[good];
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
                std::max<int64_t>(0, _market.stock[_market.index(market, good)]), total);
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
                available &= _market.stock[_market.index(market, component.good_id)] > 0;
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
                available &= _market.stock[_market.index(market, component.good_id)] > 0;
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
    result.fallback_ms += elapsed_ms(fallback_start);

    const auto merchant_start = Clock::now();
    int64_t revenue = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const int64_t spend = std::min(cohort_spend[local],
                                       std::max<int64_t>(0, _population.funds[slot]));
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
        const int64_t satisfaction = state.desired_units <= 0
            ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(state.filled_units, Q16_ONE,
                                              state.desired_units, sat), 0, Q16_ONE - 1);
        if (satisfaction < cohort_worst_q16[local]) {
            cohort_worst_q16[local] = satisfaction;
            cohort_worst_need[local] = static_cast<uint16_t>(_needs[state.need_index].stable_id);
        }
    }
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        _population.needs_satisfaction[slot] = static_cast<uint16_t>(
            cohort_desired[local] <= 0 ? Q16_ONE - 1 : std::clamp<int64_t>(
                mul_div_sat(cohort_filled[local], Q16_ONE, cohort_desired[local], sat),
                0, Q16_ONE - 1));
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
        const int64_t shortage = good_demand[good] <= 0 ? 0 : std::clamp<int64_t>(
            Q16_ONE - mul_div_sat(good_sales[good], Q16_ONE, good_demand[good], sat),
            0, Q16_ONE);
        _market.last_shortage_q16[idx] = static_cast<uint16_t>(
            std::min<int64_t>(Q16_ONE - 1, shortage));
        const int32_t signal_index = market_signal_index(market, good);
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
        // linear rather than N calls to pow/price feedback; absolute profile
        // bounds make the approximation deterministic and cheap.
        const int64_t period_change_q16 = saturating_mul(change_q16, _epoch_days, sat);
        int64_t next_price = saturating_add(_market.price[idx],
            mul_div_sat(_market.price[idx], period_change_q16, Q16_ONE, sat), sat);
        const int64_t bounded = std::clamp<int64_t>(next_price,
                                                    _good_min_price[good], _good_max_price[good]);
        if (unclamped != change_q16 || bounded != next_price) ++result.price_cap_hits;
        if (_market.price[idx] != bounded) ++result.changed_prices;
        _market.price[idx] = static_cast<int32_t>(bounded);
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
    if (cmd.source_slot < 0 || cmd.source_slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[cmd.source_slot] == 0) {
        // A prior command may have consumed/released the same source. Stable
        // sequence semantics make the remaining command a deterministic no-op.
        return true;
    }
    const int32_t source = cmd.source_slot;
    const int32_t source_cell = _population.page_cell[source / PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    if (cmd.opcode == 0) {
        const int64_t estate_funds = _population.funds[source];
        const int64_t treasury_before = _treasury_cash;
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(source_cell)) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                            estate_funds, 0});
            legs.push_back({FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                            treasury_before, treasury_before});
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, estate_funds, _saturation_count);
        _treasury_cash = saturating_add(_treasury_cash, estate_funds,
                                        _saturation_count);
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
        _structural_touched_cells.push_back(source_cell);
        if (legs.size() > 1) legs[1].after = _treasury_cash;
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
    if (cmd.cell == source_cell &&
        cmd.signature == static_cast<int32_t>(_population.signature_id[source])) return true;
    const int64_t source_pop = std::max<int64_t>(0, _population.population[source]);
    const int64_t move_pop = std::min(std::max<int64_t>(0, cmd.population), source_pop);
    if (move_pop == 0) return true;
    _structural_touched_cells.push_back(source_cell);
    _structural_touched_cells.push_back(cmd.cell);
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

    const int32_t destination = _population.allocate_slot(cmd.cell, static_cast<uint32_t>(cmd.signature));
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
    _population.income_ema[source] -= move_ema;
    _population.demography_residual[source] -= move_residual;
    if (_population.population[source] == 0) {
        // Any rounding residue is money, not an implicit burn.
        const int64_t residue_funds = _population.funds[source];
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, residue_funds, _saturation_count);
        _treasury_cash = saturating_add(_treasury_cash, residue_funds,
                                        _saturation_count);
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
    }
    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(source_cell) || trace_detail_for_cell(cmd.cell)) {
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
                 SUBJECT_COHORT, source_handle, cmd.signature, cmd.cell,
                 move_pop, move_funds, source_cell, cmd.cell,
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
    totals.treasury_cash = _treasury_cash;
    totals.goods_stock = std::accumulate(_market.stock.begin(), _market.stock.end(), int64_t{0});
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
    _closing_totals = _publish_accum;
    _closing_totals.cohort_funds = saturating_sub(
        _closing_totals.cohort_funds, _structural_funds_to_treasury, _saturation_count);
	_closing_totals.cohort_funds = saturating_add(
		_closing_totals.cohort_funds, _anchored_money_issued, _saturation_count);
    _closing_totals.treasury_cash = _treasury_cash;
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds + _opening_totals.treasury_cash;
    const int64_t money_close = _closing_totals.cohort_funds + _closing_totals.treasury_cash;
    const int64_t money_expected = money_open + _explicit_money_mint - _explicit_money_burn;
    _closing_totals.goods_stock = saturating_add(
        _closing_totals.goods_stock,
		saturating_sub(saturating_sub(_production_output_stock,
			_production_inputs_consumed, _saturation_count), _cycle_flow_discarded,
                       _saturation_count), _saturation_count);
    const int64_t goods_expected = _opening_totals.goods_stock + _explicit_stock_delta +
                                   _production_output_stock - _consumed_goods -
								   _construction_goods_consumed - _production_inputs_consumed -
								   _cycle_flow_discarded;
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
    _last_committed_day = _sample_day;
    _commit_day = _current_day;
    _epoch_active = false;
    _resource_deltas_ready = std::any_of(_resource_deltas.begin(), _resource_deltas.end(),
                                         [](int64_t value) { return value != 0; });
    _epoch_commands.clear();
    _structural_commands.clear();
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
    // most one command range, one cell range and one structural range.
    bool command_range_used = false;
    bool cell_range_used = false;
    bool structural_range_used = false;
    bool building_range_used = false;
    while (_epoch_active && !_fatal) {
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
            _stage = Stage::HOUSEHOLD_MARKET;
            if (cell_range_used) break;
            continue;
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
                while (end < _market.market_count &&
                       end - begin < _cells_per_slice &&
                       (end == begin || slice_cohorts < _target_cohorts_per_slice)) {
                    for (int32_t k = _market_cell_offsets[end];
                         k < _market_cell_offsets[end + 1]; ++k) {
                        slice_cohorts += _committed_cells[_market_cells[k]].cohort_count;
                    }
                    ++end;
                }
            } else {
                end = std::min(_market.market_count, begin + _cells_per_slice);
            }
            const int32_t market_count = end - begin;
            std::vector<MarketResult> results(static_cast<size_t>(market_count));
            int64_t estimated_cohorts = 0;
            for (int32_t market = begin; market < end; ++market) {
                for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
                    estimated_cohorts += _committed_cells[_market_cells[k]].cohort_count;
                }
            }
            const int64_t parallel_work = std::max<int64_t>(market_count, estimated_cohorts);
            _worker_tasks = _worker_enabled && market_count >= _worker_market_threshold &&
                                    parallel_work >= _worker_market_threshold &&
                                    godot::WorkerThreadPool::get_singleton() != nullptr
                                ? std::min(market_count,
                                           _worker_tasks_hint > 0 ? _worker_tasks_hint
                                                                  : parallel_default_n_tasks(
                                                                        static_cast<int>(std::min<int64_t>(
                                                                            parallel_work,
                                                                            std::numeric_limits<int>::max()))))
                                : 1;
            auto run_markets = [&](int32_t range_begin, int32_t range_end) {
                for (int32_t relative = range_begin; relative < range_end; ++relative) {
                    MarketResult &market_result = results[relative];
                    std::string market_error;
                    market_result.ok = process_market_cell(begin + relative, market_result, market_error);
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
                const int32_t market = begin + relative;
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
                _births = saturating_add(_births, market_result.births, _saturation_count);
                _deaths = saturating_add(_deaths, market_result.deaths, _saturation_count);
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
                ++work_done;
            }
            if (!_fatal && _trace_mode != TRACE_OFF) {
                const auto event_start = Clock::now();
                for (int32_t relative = 0; relative < market_count; ++relative) {
                    const int32_t market = begin + relative;
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
            if (_fatal || _cell_cursor < _market.market_count) break;
            std::stable_sort(_structural_commands.begin(), _structural_commands.end(),
                             [](const StructuralCommand &a, const StructuralCommand &b) {
                if (a.cell != b.cell) return a.cell < b.cell;
                if (a.signature != b.signature) return a.signature < b.signature;
                if (a.sequence != b.sequence) return a.sequence < b.sequence;
                return a.source_slot < b.source_slot;
            });
            _stage = Stage::STRUCTURAL_COMMIT;
            if (structural_range_used) break;
            continue;
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
            if (_fatal || _structural_cursor < static_cast<int32_t>(_structural_commands.size())) break;
            _stage = _buildings.empty() ? Stage::WAIT_COMMIT : Stage::BUILDING_EMPLOYMENT;
            continue;
        }
        if (_stage == Stage::BUILDING_EMPLOYMENT) {
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_building_active_cells.size()),
                                                  _building_cell_cursor + _cells_per_slice);
            for (; _building_cell_cursor < end; ++_building_cell_cursor) {
                if (!run_building_employment_cell(_building_active_cells[_building_cell_cursor], error)) {
                    fail(error.empty() ? "building_employment_failed" : error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _building_cell_cursor;
            _employment_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal || _building_cell_cursor < static_cast<int32_t>(_building_active_cells.size())) break;
            _building_cell_cursor = 0;
            _stage = Stage::WAIT_COMMIT;
            continue;
        }
        if (_stage == Stage::WAIT_COMMIT) {
            const int64_t deadline_day = _sample_day + std::max(0, _epoch_days - 1);
            if (_current_day < deadline_day) break;
            _stage = _buildings.empty() ? Stage::BUILDING_COMMIT : Stage::BUILDING_PRODUCTION;
            continue;
        }
        if (_stage == Stage::BUILDING_PRODUCTION) {
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_building_active_cells.size()),
                                                  _building_cell_cursor + _cells_per_slice);
            for (; _building_cell_cursor < end; ++_building_cell_cursor) {
                if (!run_building_production_cell(_building_active_cells[_building_cell_cursor], error)) {
                    fail(error.empty() ? "building_production_failed" : error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _building_cell_cursor;
            _production_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal || _building_cell_cursor < static_cast<int32_t>(_building_active_cells.size())) break;
            _building_cell_cursor = 0;
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_COMMIT) {
            commit_ready_construction();
            _stage = Stage::AGGREGATE_PUBLISH;
            continue;
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
    }
    return "unknown";
}

int32_t NativeEconomyRuntime::stage_progress_q16() const {
    if (!_epoch_active) return _fatal ? 0 : static_cast<int32_t>(Q16_ONE - 1);
    switch (_stage) {
        case Stage::LEDGER_APPLY:
            return static_cast<int32_t>(Q16_ONE / 10 +
                (_epoch_commands.empty() ? Q16_ONE / 10
                                         : (static_cast<int64_t>(_command_cursor) * (Q16_ONE / 10)) /
                                               static_cast<int64_t>(_epoch_commands.size())));
        case Stage::HOUSEHOLD_MARKET:
            return static_cast<int32_t>(Q16_ONE / 5 +
                (static_cast<int64_t>(_cell_cursor) * (Q16_ONE * 3 / 5)) /
                    std::max(1, _market.market_count));
        case Stage::STRUCTURAL_COMMIT:
            return static_cast<int32_t>(Q16_ONE * 4 / 5 +
                (_structural_commands.empty() ? Q16_ONE / 10
                                              : (static_cast<int64_t>(_structural_cursor) *
                                                 (Q16_ONE / 10)) /
                                                    static_cast<int64_t>(_structural_commands.size())));
        case Stage::BUILDING_EMPLOYMENT:
            return static_cast<int32_t>(Q16_ONE * 4 / 5 +
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 20)) /
                    std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size())));
        case Stage::WAIT_COMMIT: return static_cast<int32_t>(Q16_ONE * 17 / 20);
        case Stage::BUILDING_PRODUCTION:
            return static_cast<int32_t>(Q16_ONE * 17 / 20 +
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 10)) /
                    std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size())));
        case Stage::BUILDING_COMMIT: return static_cast<int32_t>(Q16_ONE * 19 / 20);
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
    cap(_population.epoch_income); cap(_population.epoch_expense); cap(_population.income_ema);
    cap(_population.needs_satisfaction); cap(_population.worst_need_id);
    cap(_population.flags); cap(_population.demography_residual);
    cap(_population.owner_employed); cap(_population.employee_employed);
    cap(_market.stock); cap(_market.price); cap(_market.demand_ema);
    cap(_market.last_shortage_q16); cap(_market.cell_to_market);
    cap(_market_signals.cell_offsets); cap(_market_signals.good_ids);
    cap(_market_signals.business_demand_ema); cap(_market_signals.offered_supply_ema);
    cap(_market_signals.cost_anchor_price);
    cap(_labor_signals.cell_offsets); cap(_labor_signals.profession_ids);
    cap(_labor_signals.base_living_cost); cap(_labor_signals.role_living_cost);
    cap(_labor_signals.contract_wage_ema); cap(_labor_signals.paid_wage_ema);
    cap(_labor_signals.job_days); cap(_labor_signals.pay_ratio_q16);
    cap(_market_cell_offsets); cap(_market_cells);
    cap(_signatures); cap(_plans); cap(_rules); cap(_rule_params); cap(_pending_commands);
    cap(_epoch_commands); cap(_structural_commands); cap(_committed_cells);
    cap(_staging_cells); cap(_structural_touched_cells);
    cap(_building_types); cap(_building_employee_roles); cap(_building_construction_goods);
    cap(_building_inputs); cap(_building_outputs); cap(_building_resources);
	cap(_building_output_cost_shares_q16);
	cap(_cycle_flow_good_ids);
    cap(_building_resource_generation);
    cap(_building_conditions); cap(_buildings); cap(_building_cell_offsets);
    cap(_building_active_cells);
    cap(_building_employee_filled);
    cap(_building_role_contract_wage); cap(_building_role_base_living_cost);
    cap(_building_role_living_cost); cap(_building_role_local_average_wage);
    cap(_building_role_base_wage_due); cap(_building_role_base_wage_paid);
    cap(_building_role_bonus_due); cap(_building_role_bonus_paid);
    cap(_pending_construction); cap(_resource_snapshot); cap(_resource_remaining);
    cap(_resource_deltas); cap(_building_elevation_q16); cap(_building_terrain);
    cap(_building_landform); cap(_building_vegetation); cap(_building_is_water);
    cap(_building_has_river); cap(_building_neighbors); cap(_resource_adjacent_access);
    bytes += trace_memory_bytes();
    return bytes;
}

Dictionary NativeEconomyRuntime::report() const {
    Dictionary out;
    const int64_t age_days = _epoch_active ? std::max<int64_t>(0, _current_day - _sample_day) : 0;
    const int64_t deadline_day = _sample_day < 0
        ? -1 : _sample_day + std::max(0, _epoch_days - 1);
    const bool commit_due = _epoch_active && _current_day >= deadline_day;
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds + _opening_totals.treasury_cash;
    const int64_t money_close = _closing_totals.cohort_funds + _closing_totals.treasury_cash;
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
    out["building_plan_ms"] = _building_plan_ms;
    out["market_signal_ms"] = _market_signal_ms;
    out["wage_plan_ms"] = _wage_plan_ms;
    out["labor_signal_ms"] = _labor_signal_ms;
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
    out["worker_enabled"] = _worker_enabled;
    out["worker_market_threshold"] = _worker_market_threshold;
    out["markets_per_slice"] = _cells_per_slice;
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
    out["production_inputs_consumed"] = _production_inputs_consumed;
    out["production_output_stock"] = _production_output_stock;
    out["production_output_discarded"] = _production_output_discarded;
    out["producer_revenue"] = _producer_revenue;
	out["anchored_money_issued"] = _anchored_money_issued;
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
               _production_output_stock - _consumed_goods -
			   _construction_goods_consumed - _production_inputs_consumed -
			   _cycle_flow_discarded);
    out["saturation_count"] = _saturation_count;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    out["fatal"] = _fatal;
    out["commit_lag_budget_days"] = _commit_lag_budget_days;
    out["commit_over_budget"] = _epoch_active && age_days > _commit_lag_budget_days;
    out["commit_due"] = commit_due;
    out["cycle_deadline_day"] = deadline_day;
    out["days_until_commit"] = _epoch_active
        ? std::max<int64_t>(0, deadline_day - _current_day) : 0;
    out["market_cycle_days"] = _epoch_days;
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["market_max_cycle_days"] = _max_epoch_days;
    out["approximation_version"] = 2;
    out["approximation_model"] = "frozen_sample_adaptive_price_v2";
    out["period_transactions"] = true;
    out["max_command_latency_days"] = _epoch_days;
    out["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    out["catalog_hash"] = _catalog_hash;
    out["building_catalog_hash"] = _building_catalog_hash;
    out["environment_day"] = _environment_day;
    out["environment_hash"] = _environment_hash;
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = _merchant_repairs;
    out["price_cap_hits"] = _price_cap_hits;
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
    out["snapshot_source"] = _epoch_active ? "live_slice" : "committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const CellSummary summary = build_cell_summary(cell_idx);
    out["ok"] = true;
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
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
    out["snapshot_source"] = _epoch_active ? "live_slice" : "committed";
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
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
    out["epoch_id"] = _epoch_id;
    PackedInt64Array handles;
    PackedInt32Array signatures;
    PackedInt32Array professions;
    PackedInt32Array ethnicities;
    PackedInt64Array populations;
    PackedInt64Array funds;
    PackedInt64Array incomes;
    PackedInt64Array expenses;
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
    out["income_ema_by_cohort"] = income_ema;
    out["satisfaction_by_cohort_q16"] = satisfaction;
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
    demand_good_offsets.push_back(0);
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
                    if (units <= 0) continue;
                    const VariantChoice &variant = _variants[variant_id];
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const NeedComponent &component =
                            _components[variant.component_begin + c];
                        const int64_t quantity = mul_div_sat(
                            units, component.qty_per_need, GOODS_SCALE,
                            preview_saturation_count);
                        good_quantities[component.good_id] = saturating_add(
                            good_quantities[component.good_id], quantity,
                            preview_saturation_count);
                    }
                }
            }
        }
        const int64_t population = std::max<int64_t>(1, _population.population[slot]);
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
    out["snapshot_source"] = _epoch_active ? "live_slice" : "committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const int32_t market = _market.cell_to_market[cell_idx];
    out["ok"] = true;
    out["market_id"] = market;
    out["epoch_id"] = _epoch_id;
    PackedStringArray good_ids;
    PackedInt64Array stock;
    PackedInt64Array demand_ema;
    PackedInt64Array business_demand_ema;
    PackedInt64Array offered_supply_ema;
    PackedInt32Array cost_anchor_price;
    PackedInt32Array price;
    PackedInt32Array shortage_q16;
    PackedInt32Array pressure_excess_q16;
    PackedInt32Array pressure_inventory_q16;
    PackedInt32Array pressure_shortage_q16;
    PackedInt32Array pressure_cost_q16;
    PackedInt32Array pressure_idle_q16;
    PackedInt32Array pressure_total_q16;
    PackedInt32Array price_change_q16;
	PackedStringArray category_ids;
	PackedInt32Array storage_modes;
	PackedInt64Array monetary_issue_values;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
	technology_tag_offsets.push_back(0);
    int64_t snapshot_saturation = 0;
    for (int32_t g = 0; g < _market.good_count; ++g) {
        good_ids.push_back(String(_good_ids[g].c_str()));
        stock.push_back(_market.stock[_market.index(market, g)]);
        price.push_back(_market.price[_market.index(market, g)]);
        demand_ema.push_back(_market.demand_ema[_market.index(market, g)]);
        shortage_q16.push_back(_market.last_shortage_q16[_market.index(market, g)]);
        const int32_t signal = market_signal_index(cell_idx, g);
        business_demand_ema.push_back(signal >= 0 ?
            _market_signals.business_demand_ema[signal] : 0);
        offered_supply_ema.push_back(signal >= 0 ?
            _market_signals.offered_supply_ema[signal] : 0);
        cost_anchor_price.push_back(signal >= 0 ?
            _market_signals.cost_anchor_price[signal] : 0);
        const PricePressure pressure = price_pressure(
            market, g, _market.demand_ema[_market.index(market, g)],
            _market.stock[_market.index(market, g)],
            _market.last_shortage_q16[_market.index(market, g)], signal,
            snapshot_saturation);
        pressure_excess_q16.push_back(static_cast<int32_t>(pressure.excess_q16));
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
    out["offered_supply_ema"] = offered_supply_ema;
    out["cost_anchor_price"] = cost_anchor_price;
    out["shortage_q16"] = shortage_q16;
    out["price_pressure_excess_q16"] = pressure_excess_q16;
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
    out["snapshot_source"] = _epoch_active ? "live_slice" : "committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    out["ok"] = true;
    out["epoch_id"] = _epoch_id;
    out["period_days"] = std::max(1, _epoch_days);
    PackedStringArray type_ids;
    PackedInt64Array type_counts;
    PackedInt64Array wage_per_employee_per_day;
    PackedInt32Array target_operating_margin_q16;
    PackedInt32Array supply_price_elasticity_q16;
	PackedInt32Array building_kinds;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
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
		for (int32_t k = _building_technology_tag_offsets[i];
			 k < _building_technology_tag_offsets[i + 1]; ++k) {
			technology_tags.push_back(String(_building_technology_tags[k].c_str()));
		}
		technology_tag_offsets.push_back(technology_tags.size());
	}
    PackedInt32Array group_type_ids;
    PackedInt32Array owner_signature_ids;
    PackedInt64Array group_counts;
    PackedInt64Array filled_owner;
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
    PackedInt64Array last_input;
    PackedInt64Array last_output;
    PackedInt64Array last_sold;
    PackedInt64Array last_discarded;
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
    employee_fill_offsets.push_back(0);
    const int32_t group_begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell_idx] : 0;
    const int32_t group_end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell_idx + 1] : 0;
    for (int32_t group_idx = group_begin; group_idx < group_end; ++group_idx) {
        const BuildingGroup &group = _buildings[group_idx];
        if (group.cell != cell_idx || group.count <= 0) continue;
        type_counts.set(group.type_id, type_counts[group.type_id] + group.count);
        group_type_ids.push_back(group.type_id);
        owner_signature_ids.push_back(group.owner_signature_id);
        group_counts.push_back(group.count);
        filled_owner.push_back(group.filled_owner);
        capacity_q16.push_back(group.last_capacity_q16);
        last_input.push_back(group.last_input);
        last_output.push_back(group.last_output);
        last_sold.push_back(group.last_sold);
        last_discarded.push_back(group.last_discarded);
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
        const BuildingType &type = _building_types[group.type_id];
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
            int64_t snapshot_sat = 0;
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
	out["building_technology_tag_offsets"] = technology_tag_offsets;
	out["building_technology_tags"] = technology_tags;
    out["group_type_ids"] = group_type_ids;
    out["owner_signature_ids"] = owner_signature_ids;
    out["group_counts"] = group_counts;
    out["filled_owner"] = filled_owner;
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
    out["last_input"] = last_input;
    out["last_output"] = last_output;
    out["last_sold"] = last_sold;
    out["last_discarded"] = last_discarded;
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
    mix_u64(static_cast<uint64_t>(_catalog_hash));
    mix_u64(static_cast<uint64_t>(_building_catalog_hash));
    mix_u64(static_cast<uint64_t>(_cell_count));
    mix_u64(static_cast<uint64_t>(_epoch_id));
    mix_u64(static_cast<uint64_t>(_epoch_days));
    mix_u64(static_cast<uint64_t>(_last_committed_day));
    mix_u64(static_cast<uint64_t>(_environment_day));
    mix_u64(static_cast<uint64_t>(_environment_hash));
    mix_u64(static_cast<uint64_t>(_treasury_cash));
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
    }
    for (int32_t value : _market_signals.cell_offsets) mix_u64(static_cast<uint32_t>(value));
    for (size_t i = 0; i < _market_signals.good_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_market_signals.good_ids[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.business_demand_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.offered_supply_ema[i]));
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
    _building_catalog_hash = 0;
    _building_catalog_compat_hash_v6 = 0;
    _epoch_id = 0;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _last_committed_day = -1;
    _treasury_cash = 0;
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
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _committed_cells.clear();
    _staging_cells.clear();
    _structural_touched_cells.clear();
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
    _resource_adjacent_access.clear();
    _resource_snapshot.clear();
    _resource_remaining.clear();
    _resource_deltas.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
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
        append_le<int64_t>(payload, _treasury_cash);
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
        constexpr int32_t record_bytes = 24;
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
        constexpr int32_t record_bytes = 28;
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
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
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
        (schema != 2 && schema != 3 && schema != 4 && schema != 5 && schema != 6 &&
         schema != 7 &&
         schema != SCHEMA_VERSION) ||
        payload_bytes != bytes.size() - cursor ||
        (_restore.header_seen && schema != _restore.schema_version)) {
        error = "save_chunk_header_invalid";
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
        int64_t active_count = 0, last_day = 0, epoch_id = 0, treasury = 0, seed = 0,
                catalog_hash = 0, money_scale = 0, goods_scale = 0, ratio_scale = 0,
                rate_scale = 0, environment_day = -1, environment_hash = 0,
                building_catalog_hash = 0;
        uint64_t next_submit = 0;
        int64_t next_event_id = 1;
        uint64_t event_stream_hash = 1469598103934665603ULL;
        std::vector<std::string> professions, ethnicities, good_ids, plan_ids;
        if (!read_le(bytes, cursor, saved_cells) || !read_le(bytes, cursor, markets) ||
            !read_le(bytes, cursor, goods) || !read_le(bytes, cursor, pages) ||
            !read_le(bytes, cursor, active_count) || !read_le(bytes, cursor, epoch_days) ||
            !read_le(bytes, cursor, last_day) || !read_le(bytes, cursor, epoch_id) ||
            !read_le(bytes, cursor, treasury) || !read_le(bytes, cursor, seed) ||
            !read_le(bytes, cursor, catalog_hash)) {
            error = "save_header_payload_truncated";
            return false;
        }
        if (schema >= 3 && (!read_le(bytes, cursor, building_catalog_hash) ||
            !read_le(bytes, cursor, building_count) ||
            !read_le(bytes, cursor, construction_count))) {
            error = "save_building_header_payload_truncated";
            return false;
        }
        if (
            !read_le(bytes, cursor, environment_day) || !read_le(bytes, cursor, environment_hash) ||
            !read_le(bytes, cursor, next_submit) ||
            !read_le(bytes, cursor, money_scale) || !read_le(bytes, cursor, goods_scale) ||
            !read_le(bytes, cursor, ratio_scale) || !read_le(bytes, cursor, rate_scale) ||
            !read_le(bytes, cursor, pending_count) ||
            (schema >= 6 && (!read_le(bytes, cursor, audit_count) ||
                             (schema >= 7 && !read_le(bytes, cursor, signal_count)) ||
                             (schema >= 8 && !read_le(bytes, cursor, labor_signal_count)) ||
                             !read_le(bytes, cursor, next_event_id) ||
                             !read_le(bytes, cursor, event_stream_hash))) ||
            !read_id_table(bytes, cursor, professions) || !read_id_table(bytes, cursor, ethnicities) ||
            !read_id_table(bytes, cursor, good_ids) || !read_id_table(bytes, cursor, plan_ids) ||
            cursor != bytes.size()) {
            error = "save_header_payload_truncated";
            return false;
        }
        const bool market_hash_ok = catalog_hash == _catalog_hash ||
            (schema == 7 && _catalog_compat_hash_v7 != 0 &&
             catalog_hash == _catalog_compat_hash_v7) ||
            (schema < 7 && _catalog_compat_hash_v6 != 0 &&
             catalog_hash == _catalog_compat_hash_v6);
        const bool building_hash_ok = building_catalog_hash == _building_catalog_hash ||
            (schema == 7 && _building_catalog_compat_hash_v7 != 0 &&
             building_catalog_hash == _building_catalog_compat_hash_v7) ||
            (schema < 7 && _building_catalog_compat_hash_v6 != 0 &&
             building_catalog_hash == _building_catalog_compat_hash_v6);
        if (saved_cells != _cell_count || markets <= 0 || markets > _cell_count ||
            goods != static_cast<int32_t>(_good_ids.size()) || pages < 0 || active_count < 0 ||
            active_count > static_cast<int64_t>(pages) * PAGE_SIZE ||
            pending_count < 0 || pending_count > 1000000 ||
            audit_count < 0 || audit_count > 3650 || signal_count < 0 ||
            signal_count > 10000000 || labor_signal_count < 0 ||
            labor_signal_count > 10000000 || next_event_id <= 0 ||
            (schema >= 3 && !market_hash_ok) || money_scale != MONEY_SCALE ||
            goods_scale != GOODS_SCALE || ratio_scale != Q16_ONE || rate_scale != Q32_ONE ||
            professions != _profession_ids || ethnicities != _ethnicity_ids ||
            good_ids != _good_ids || plan_ids != _plan_ids) {
            error = "save_catalog_scale_or_capacity_mismatch";
            return false;
        }
        if (schema >= 3 && (!building_hash_ok ||
            building_count < 0 || building_count > 10000000 || construction_count < 0 ||
            construction_count > 1000000)) {
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
        _market_signals.cost_anchor_price.reserve(signal_count);
        _labor_signals.clear(_cell_count);
        _labor_signals.profession_ids.reserve(labor_signal_count);
        _labor_signals.base_living_cost.reserve(labor_signal_count);
        _labor_signals.role_living_cost.reserve(labor_signal_count);
        _labor_signals.contract_wage_ema.reserve(labor_signal_count);
        _labor_signals.paid_wage_ema.reserve(labor_signal_count);
        _labor_signals.job_days.reserve(labor_signal_count);
        _labor_signals.pay_ratio_q16.reserve(labor_signal_count);
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
        _last_committed_day = last_day;
        _commit_day = last_day;
        _sample_day = last_day;
        _current_day = last_day;
        _epoch_id = epoch_id;
        _treasury_cash = treasury;
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
                    (_restore.schema_version >= 3 &&
                     (!read_le(bytes, cursor, _population.owner_employed[slot]) ||
                      !read_le(bytes, cursor, _population.employee_employed[slot])))) {
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
    } else if (_restore.schema_version >= 3 && section == SAVE_SECTION_BUILDINGS) {
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
                (_restore.schema_version >= 5 &&
                    !read_le(bytes, cursor, group.last_resource_generated)) ||
                !read_le(bytes, cursor, group.last_revenue) ||
                (_restore.schema_version >= 4 &&
                    (!read_le(bytes, cursor, group.last_input_cost) ||
                     !read_le(bytes, cursor, group.last_wages_paid))) ||
                (_restore.schema_version >= 7 &&
                    (!read_le(bytes, cursor, group.last_wages_due) ||
                     !read_le(bytes, cursor, group.last_expected_revenue) ||
                     !read_le(bytes, cursor, group.last_operating_cost) ||
                     !read_le(bytes, cursor, group.last_margin_gap_q16) ||
                     !read_le(bytes, cursor, group.planned_utilization_q16))) ||
                (_restore.schema_version >= 8 &&
                    (!read_le(bytes, cursor, group.last_base_wages_paid) ||
                     !read_le(bytes, cursor, group.last_base_wages_due) ||
                     !read_le(bytes, cursor, group.last_bonus_paid) ||
                     !read_le(bytes, cursor, group.last_bonus_due) ||
                     !read_le(bytes, cursor, group.wage_suspended))) ||
                !read_le(bytes, cursor, roles) || group.cell < 0 || group.cell >= _cell_count ||
                group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()) ||
                group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                group.count <= 0 || roles != _building_types[group.type_id].employee_count) {
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
                if (_restore.schema_version >= 8 &&
                    (!read_le(bytes, cursor, contract) ||
                     !read_le(bytes, cursor, base_living) ||
                     !read_le(bytes, cursor, role_living) ||
                     !read_le(bytes, cursor, local_average) ||
                     !read_le(bytes, cursor, base_due) ||
                     !read_le(bytes, cursor, base_paid) ||
                     !read_le(bytes, cursor, bonus_due) ||
                     !read_le(bytes, cursor, bonus_paid))) {
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
    } else if (_restore.schema_version >= 3 && section == SAVE_SECTION_CONSTRUCTION) {
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
    } else if (_restore.schema_version >= 6 && section == SAVE_SECTION_AUDIT) {
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
    } else if (_restore.schema_version >= 7 && section == SAVE_SECTION_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t good = -1;
            int64_t business = 0;
            int64_t supply = 0;
            int32_t anchor = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, business) || !read_le(bytes, cursor, supply) ||
                !read_le(bytes, cursor, anchor) || cell < 0 || cell >= _cell_count ||
                good < 0 || good >= _market.good_count || business < 0 || supply < 0 ||
                anchor < 0 || (anchor != 0 &&
                    (anchor < _good_min_price[good] || anchor > _good_max_price[good])) ||
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
            _market_signals.cost_anchor_price.push_back(anchor);
            ++_restore.restored_signals;
        }
    } else if (_restore.schema_version >= 8 &&
               section == SAVE_SECTION_LABOR_SIGNALS) {
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
    } else if (section == (_restore.schema_version == 2 ? uint16_t{5} :
                           (_restore.schema_version < 6 ? uint16_t{7} :
                            (_restore.schema_version < 7 ? uint16_t{8} :
                             (_restore.schema_version < 8 ? uint16_t{9} :
                              SAVE_SECTION_END))))) {
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
        _restore.restored_labor_signals != _restore.expected_labor_signals) {
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
                _market.price[idx] < _good_min_price[good] ||
                _market.price[idx] > _good_max_price[good]) {
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
        const bool target_ok = cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK
                                   ? (cmd.i32_0 >= 0 && cmd.i32_0 < _market.market_count &&
                                      cmd.i32_1 >= 0 && cmd.i32_1 < _market.good_count)
                                   : _population.valid_handle(cmd.target_handle, slot);
        if (cmd.opcode < COMMAND_TRANSFER_TO_COHORT || cmd.opcode > COMMAND_DEMOLISH ||
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
            group.wage_suspended > 1) {
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
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _market_signals.cell_offsets[cell + 1] += _market_signals.cell_offsets[cell];
    rebuild_market_signals();
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _labor_signals.cell_offsets[cell + 1] += _labor_signals.cell_offsets[cell];
    rebuild_labor_signals();
    _bootstrapped = true;
    _fatal = false;
    _fatal_reason.clear();
    _epoch_active = false;
    _stage = Stage::AGGREGATE_PUBLISH;
    rebuild_committed_summaries();
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    const int32_t restored_pages = _restore.restored_pages;
    const int32_t restored_commands = _restore.restored_commands;
    const int32_t restored_buildings = _restore.restored_buildings;
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
    out["cohort_count"] = _population.active_count;
    out["state_hash_catalog"] = _catalog_hash;
    return out;
}

} // namespace pk
