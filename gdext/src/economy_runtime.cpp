#include "economy_runtime.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
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
constexpr uint16_t SAVE_SECTION_END = 7;

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
    const Signature &source_signature = _signatures[_population.signature_id[source]];
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
    if (source_population == 1) {
        _population.signature_id[source] = static_cast<uint32_t>(merchant_signature);
    } else {
        const int64_t funds_share = mul_div_sat(_population.funds[source], 1,
                                                source_population, _saturation_count);
        const int32_t destination = _population.allocate_slot(
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
        const uint8_t *has_river, const std::vector<const float *> &resources,
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
    for (int32_t cell = 0; cell < count; ++cell) {
        _building_elevation_q16[cell] = elevation != nullptr ? quantize_q16(elevation[cell]) : 0;
        _building_terrain[cell] = terrain != nullptr ? terrain[cell] : 0;
        _building_landform[cell] = landform != nullptr ? landform[cell] : 0;
        _building_vegetation[cell] = vegetation != nullptr ? vegetation[cell] : 0;
        _building_is_water[cell] = is_water != nullptr ? is_water[cell] : 0;
        _building_has_river[cell] = has_river != nullptr ? has_river[cell] : 0;
    }
    _resource_snapshot.assign(static_cast<size_t>(count) * resources.size(), 0);
    for (size_t r = 0; r < resources.size(); ++r) {
        const float *src = resources[r];
        if (src == nullptr) continue;
        for (int32_t cell = 0; cell < count; ++cell) {
            const double value = std::isfinite(src[cell]) ? std::max(0.0, static_cast<double>(src[cell])) : 0.0;
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
    _merchant_profession_stable_id = dict_string(profile, "merchant_profession_id", "merchant");
    const std::string runtime_mode = dict_string(profile, "market_runtime_mode", "PROBE");
    _market_runtime_mode = runtime_mode == "OFF" ? 0 : (runtime_mode == "PROBE" ? 1 : 2);
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
    _good_max_price_rise_q16 = packed_i32(catalog, "good_max_price_rise_q16");
    _good_max_price_fall_q16 = packed_i32(catalog, "good_max_price_fall_q16");
    _good_merchant_buy_factor_q16 = packed_i32(catalog, "good_merchant_buy_factor_q16");
    const size_t goods = _good_ids.size();
    if (_good_default_price.size() != goods || _good_default_stock.size() != goods ||
        _good_min_price.size() != goods || _good_max_price.size() != goods ||
        _good_price_adjust_q16.size() != goods ||
        _good_demand_price_elasticity_q16.size() != goods ||
        _good_demand_ema_alpha_q16.size() != goods ||
        _good_target_inventory_days_q16.size() != goods ||
        _good_inventory_weight_q16.size() != goods ||
        _good_shortage_weight_q16.size() != goods ||
        _good_max_price_rise_q16.size() != goods ||
        _good_max_price_fall_q16.size() != goods ||
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
            _good_merchant_buy_factor_q16[i] < 0 ||
            _good_merchant_buy_factor_q16[i] > Q16_ONE) {
            error = "good_parameter_out_of_range";
            return false;
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
        need_env.size() != need_count || need_variant_offsets.size() != need_count + 1 ||
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
            variants_count <= 0 || variants_count > MAX_VARIANTS_PER_NEED) {
            error = "market_v2_need_entry_invalid";
            return false;
        }
        _needs[n] = {need_stable[n], need_priority[n], variants_begin, variants_count,
                     need_base[n], need_wealth_elasticity[n], need_wealth_min[n],
                     need_wealth_max[n], need_env[n]};
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
    _catalog_hash = dict_num<int64_t>(catalog, "market_catalog_hash",
                                      dict_num<int64_t>(catalog, "catalog_hash", 0));
    _building_catalog_hash = dict_num<int64_t>(catalog, "building_catalog_hash", 1);
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
        _building_resources.clear();
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
    const std::vector<int32_t> employee_offsets = packed_i32(catalog, "building_employee_offsets");
    const std::vector<int32_t> construction_offsets = packed_i32(catalog, "building_construction_offsets");
    const std::vector<int32_t> input_offsets = packed_i32(catalog, "building_input_offsets");
    const std::vector<int32_t> output_offsets = packed_i32(catalog, "building_output_offsets");
    const std::vector<int32_t> resource_offsets = packed_i32(catalog, "building_resource_offsets");
    const std::vector<int32_t> condition_offsets = packed_i32(catalog, "building_condition_offsets");
    auto offsets_valid = [&](const std::vector<int32_t> &v) {
        return v.size() == types + 1 && !v.empty() && v.front() == 0 &&
               std::is_sorted(v.begin(), v.end());
    };
    if (owner_prof.size() != types || owner_slots.size() != types || wages.size() != types ||
        construction_days.size() != types || behavior_ids.size() != types ||
        behavior_versions.size() != types || !offsets_valid(employee_offsets) ||
        !offsets_valid(construction_offsets) || !offsets_valid(input_offsets) ||
        !offsets_valid(output_offsets) || !offsets_valid(resource_offsets) ||
        !offsets_valid(condition_offsets)) {
        error = "building_type_column_size_mismatch";
        return false;
    }
    const std::vector<int32_t> employee_prof = packed_i32(catalog, "building_employee_profession_ids");
    const std::vector<int64_t> employee_slots = packed_i64(catalog, "building_employee_slots");
    const std::vector<int32_t> construction_goods = packed_i32(catalog, "building_construction_good_ids");
    const std::vector<int64_t> construction_qty = packed_i64(catalog, "building_construction_quantities");
    const std::vector<int32_t> input_goods = packed_i32(catalog, "building_input_good_ids");
    const std::vector<int64_t> input_qty = packed_i64(catalog, "building_input_quantities");
    const std::vector<int32_t> output_goods = packed_i32(catalog, "building_output_good_ids");
    const std::vector<int64_t> output_qty = packed_i64(catalog, "building_output_quantities");
    const std::vector<int32_t> resource_ids = packed_i32(catalog, "building_production_resource_ids");
    const std::vector<int64_t> resource_qty = packed_i64(catalog, "building_production_resource_quantities");
    const std::vector<int32_t> condition_opcodes = packed_i32(catalog, "building_condition_opcodes");
    const std::vector<int32_t> condition_signals = packed_i32(catalog, "building_condition_signals");
    const std::vector<int32_t> condition_compares = packed_i32(catalog, "building_condition_compares");
    const std::vector<int32_t> condition_refs = packed_i32(catalog, "building_condition_references");
    const std::vector<int64_t> condition_values = packed_i64(catalog, "building_condition_values");
    if (employee_offsets.back() != static_cast<int32_t>(employee_prof.size()) ||
        employee_slots.size() != employee_prof.size() ||
        construction_offsets.back() != static_cast<int32_t>(construction_goods.size()) ||
        construction_qty.size() != construction_goods.size() ||
        input_offsets.back() != static_cast<int32_t>(input_goods.size()) ||
        input_qty.size() != input_goods.size() ||
        output_offsets.back() != static_cast<int32_t>(output_goods.size()) ||
        output_qty.size() != output_goods.size() ||
        resource_offsets.back() != static_cast<int32_t>(resource_ids.size()) ||
        resource_qty.size() != resource_ids.size() ||
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
            employee_slots[i] <= 0) {
            error = "building_employee_role_invalid";
            return false;
        }
        _building_employee_roles[i] = {employee_prof[i], employee_slots[i]};
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
    for (size_t i = 0; i < resource_ids.size(); ++i) {
        if (resource_ids[i] < 0 || resource_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            resource_qty[i] <= 0) {
            error = "building_production_resource_invalid";
            return false;
        }
        _building_resources[i] = {resource_ids[i], resource_qty[i]};
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
            owner_slots[i] <= 0 || wages[i] < 0 || construction_days[i] < 0 ||
            behavior_ids[i] < 0 || behavior_ids[i] > 1 || behavior_versions[i] != 1) {
            error = "building_type_entry_invalid";
            return false;
        }
        _building_types[i] = {
            owner_prof[i], owner_slots[i], wages[i],
            employee_offsets[i], employee_offsets[i + 1] - employee_offsets[i],
            construction_offsets[i], construction_offsets[i + 1] - construction_offsets[i],
            input_offsets[i], input_offsets[i + 1] - input_offsets[i],
            output_offsets[i], output_offsets[i + 1] - output_offsets[i],
            resource_offsets[i], resource_offsets[i + 1] - resource_offsets[i],
            condition_offsets[i], condition_offsets[i + 1] - condition_offsets[i],
            construction_days[i], behavior_ids[i], behavior_versions[i]};
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
    rebuild_building_cell_offsets();
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

int64_t NativeEconomyRuntime::credit_local_merchants(int32_t cell, int64_t amount) {
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
    }
    return distributed;
}

int64_t NativeEconomyRuntime::debit_local_merchants(int32_t cell, int64_t amount) {
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
    }
    return distributed;
}

int64_t NativeEconomyRuntime::pay_building_wages(int32_t cell, int32_t owner_slot,
                                                  int32_t profession_id,
                                                  int64_t filled_jobs,
                                                  int64_t wage_per_employee_per_day) {
    if (filled_jobs <= 0 || wage_per_employee_per_day <= 0 || owner_slot < 0) return 0;
    const int64_t daily_due = saturating_mul(filled_jobs, wage_per_employee_per_day,
                                             _saturation_count);
    const int64_t due = saturating_mul(daily_due, std::max(1, _epoch_days),
                                       _saturation_count);
    int64_t total_employed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (_signatures[signature].profession_id == profession_id) {
            total_employed = saturating_add(total_employed,
                _population.employee_employed[slot], _saturation_count);
        }
    });
    if (total_employed <= 0) {
        _building_wages_unpaid = saturating_add(_building_wages_unpaid, due,
                                                _saturation_count);
        return 0;
    }
    const int64_t paid = std::min(due, std::max<int64_t>(0, _population.funds[owner_slot]));
    touch_accounting_slot(owner_slot);
    _population.funds[owner_slot] -= paid;
    _population.epoch_expense[owner_slot] = saturating_add(
        _population.epoch_expense[owner_slot], paid, _saturation_count);
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
    });
    _building_wages_paid = saturating_add(_building_wages_paid, distributed,
                                          _saturation_count);
    _building_wages_unpaid = saturating_add(_building_wages_unpaid, due - distributed,
                                            _saturation_count);
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
    if (credit_local_merchants(cell, total_cost) != total_cost) {
        error = "building_construction_has_no_merchant_owner";
        return false;
    }
    _pending_construction.push_back({cell, type_id, owner_signature, count,
        _sample_day + type.construction_days, cmd.sequence});
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
    _buildings[group_id].count -= count;
    return true;
}

bool NativeEconomyRuntime::run_building_employment_cell(int32_t cell, std::string &) {
    thread_local std::vector<int64_t> demand;
    thread_local std::vector<int64_t> available;
    thread_local std::vector<int64_t> fill;
    const int32_t professions = static_cast<int32_t>(_profession_ids.size());
    demand.assign(professions, 0);
    available.assign(professions, 0);
    fill.assign(professions, 0);
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        _population.owner_employed[slot] = 0;
        _population.employee_employed[slot] = 0;
    });
    const int32_t first = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t last = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
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
                    saturating_mul(group.count, role.slots_per_building, _saturation_count),
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
                const int64_t role_demand = saturating_mul(group.count, role.slots_per_building,
                                                           _saturation_count);
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
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        _unemployed_population = saturating_add(_unemployed_population,
            std::max<int64_t>(0, _population.population[slot] - _population.owner_employed[slot] -
                                  _population.employee_employed[slot]), _saturation_count);
    });
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
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        ++_processed_building_groups;
        group.last_capacity_q16 = 0;
        group.last_input = group.last_output = group.last_sold = group.last_discarded = 0;
        group.last_resource = group.last_revenue = 0;
        const BuildingType &type = _building_types[group.type_id];
        const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
        if (owner_slot < 0) continue;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            pay_building_wages(cell, owner_slot, role.profession_id,
                _building_employee_filled[group.employee_fill_begin + r],
                type.wage_per_employee_per_day);
        }
        const int64_t owner_demand = saturating_mul(group.count, type.owner_slots_per_building,
                                                    _saturation_count);
        int64_t scale_q16 = owner_demand > 0
            ? std::min<int64_t>(Q16_ONE, mul_div_sat(group.filled_owner, Q16_ONE,
                                                     owner_demand, _saturation_count)) : 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t role_demand = saturating_mul(group.count, role.slots_per_building,
                                                       _saturation_count);
            const int64_t role_fill = _building_employee_filled[group.employee_fill_begin + r];
            const int64_t role_scale = role_demand > 0
                ? std::min<int64_t>(Q16_ONE, mul_div_sat(role_fill, Q16_ONE, role_demand,
                                                         _saturation_count)) : Q16_ONE;
            scale_q16 = std::min(scale_q16, role_scale);
        }
        const int64_t building_days = saturating_mul(group.count, std::max(1, _epoch_days),
                                                     _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const GoodAmount &item = _building_inputs[type.input_begin + i];
            const int64_t base = saturating_mul(building_days, item.quantity, _saturation_count);
            if (base > 0) scale_q16 = std::min(scale_q16,
                mul_div_sat(_market.stock[_market.index(market, item.good_id)], Q16_ONE,
                            base, _saturation_count));
        }
        if (type.behavior_id == 1) {
            for (int32_t i = 0; i < type.resource_count; ++i) {
                const ResourceAmount &item = _building_resources[type.resource_begin + i];
                const int64_t base = saturating_mul(building_days, item.quantity, _saturation_count);
                const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
                if (base > 0) scale_q16 = std::min(scale_q16,
                    mul_div_sat(_resource_remaining[idx], Q16_ONE, base, _saturation_count));
            }
        }
        int64_t unit_input_cost = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const GoodAmount &item = _building_inputs[type.input_begin + i];
            unit_input_cost = saturating_add(unit_input_cost,
                mul_div_sat(item.quantity, _market.price[_market.index(market, item.good_id)],
                            GOODS_SCALE, _saturation_count), _saturation_count);
        }
        const int64_t base_cost = saturating_mul(building_days, unit_input_cost, _saturation_count);
        if (base_cost > 0) scale_q16 = std::min(scale_q16,
            mul_div_sat(std::max<int64_t>(0, _population.funds[owner_slot]), Q16_ONE,
                        base_cost, _saturation_count));
        scale_q16 = std::clamp<int64_t>(scale_q16, 0, Q16_ONE);
        group.last_capacity_q16 = scale_q16;
        touch_accounting_slot(owner_slot);
        int64_t actual_cost = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const GoodAmount &item = _building_inputs[type.input_begin + i];
            const int64_t qty = mul_div_sat(
                saturating_mul(building_days, item.quantity, _saturation_count),
                scale_q16, Q16_ONE, _saturation_count);
            _market.stock[_market.index(market, item.good_id)] -= qty;
            group.last_input = saturating_add(group.last_input, qty, _saturation_count);
            _production_inputs_consumed = saturating_add(_production_inputs_consumed, qty,
                                                         _saturation_count);
            actual_cost = saturating_add(actual_cost,
                mul_div_sat(qty, _market.price[_market.index(market, item.good_id)],
                            GOODS_SCALE, _saturation_count), _saturation_count);
        }
        if (actual_cost > _population.funds[owner_slot]) {
            error = "building_input_cost_preflight_drift";
            return false;
        }
        _population.funds[owner_slot] -= actual_cost;
        _population.epoch_expense[owner_slot] = saturating_add(
            _population.epoch_expense[owner_slot], actual_cost, _saturation_count);
        if (credit_local_merchants(cell, actual_cost) != actual_cost) {
            error = "building_input_has_no_merchant_owner";
            return false;
        }
        if (type.behavior_id == 1) {
            for (int32_t i = 0; i < type.resource_count; ++i) {
                const ResourceAmount &item = _building_resources[type.resource_begin + i];
                const int64_t qty = mul_div_sat(
                    saturating_mul(building_days, item.quantity, _saturation_count),
                    scale_q16, Q16_ONE, _saturation_count);
                const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
                _resource_remaining[idx] -= qty;
                _resource_deltas[idx] = saturating_sub(_resource_deltas[idx], qty, _saturation_count);
                group.last_resource = saturating_add(group.last_resource, qty, _saturation_count);
            }
        }
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            const int64_t qty = mul_div_sat(
                saturating_mul(building_days, item.quantity, _saturation_count),
                scale_q16, Q16_ONE, _saturation_count);
            if (qty > 0) offers.push_back({item.good_id, owner_slot, g, qty});
            group.last_output = saturating_add(group.last_output, qty, _saturation_count);
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
        const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
            _market.price[_market.index(market, offer.good)],
            _good_merchant_buy_factor_q16[offer.good], Q16_ONE, _saturation_count));
        int64_t merchant_cash = 0;
        for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
            merchant_cash = saturating_add(merchant_cash,
                std::max<int64_t>(0, _population.funds[_merchant_slots[k]]), _saturation_count);
        }
        const int64_t affordable_qty = mul_div_sat(merchant_cash, GOODS_SCALE, buy_price,
                                                   _saturation_count);
        const int64_t sold = std::min(offer.qty, affordable_qty);
        const int64_t payment = mul_div_sat(sold, buy_price, GOODS_SCALE, _saturation_count);
        const int64_t paid = debit_local_merchants(cell, payment);
        if (paid != payment) {
            error = "merchant_purchase_payment_drift";
            return false;
        }
        touch_accounting_slot(offer.owner_slot);
        _population.funds[offer.owner_slot] = saturating_add(
            _population.funds[offer.owner_slot], paid, _saturation_count);
        _population.epoch_income[offer.owner_slot] = saturating_add(
            _population.epoch_income[offer.owner_slot], paid, _saturation_count);
        _market.stock[_market.index(market, offer.good)] = saturating_add(
            _market.stock[_market.index(market, offer.good)], sold, _saturation_count);
        group.last_sold = saturating_add(group.last_sold, sold, _saturation_count);
        group.last_discarded = saturating_add(group.last_discarded, offer.qty - sold,
                                              _saturation_count);
        group.last_revenue = saturating_add(group.last_revenue, paid, _saturation_count);
        _production_output_stock = saturating_add(_production_output_stock, sold,
                                                  _saturation_count);
        _production_output_discarded = saturating_add(_production_output_discarded,
                                                       offer.qty - sold, _saturation_count);
        _producer_revenue = saturating_add(_producer_revenue, paid, _saturation_count);
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
    _population.clear(cell_count);
    _market.clear();
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
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
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
    out["approximation_model"] = "frozen_sample_linear_v1";
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
    _building_wages_paid = 0;
    _building_wages_unpaid = 0;
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
    _opening_totals = _closing_totals;
    _sample_day = day_index;
    _current_day = day_index;
    _epoch_active = true;
    ++_epoch_id;
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
    switch (cmd.opcode) {
        case COMMAND_TRANSFER_TO_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_ledger";
                return false;
            }
            touch_accounting_slot(slot);
            const int64_t amount = std::min(std::max<int64_t>(0, cmd.i64_0),
                                            std::max<int64_t>(0, _treasury_cash));
            _treasury_cash = saturating_sub(_treasury_cash, amount, _saturation_count);
            _population.funds[slot] = saturating_add(_population.funds[slot], amount, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], amount, _saturation_count);
            break;
        }
        case COMMAND_MINT_TO_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_mint";
                return false;
            }
            touch_accounting_slot(slot);
            _population.funds[slot] = saturating_add(_population.funds[slot], cmd.i64_0, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], cmd.i64_0, _saturation_count);
            _explicit_money_mint = saturating_add(_explicit_money_mint, cmd.i64_0, _saturation_count);
            break;
        }
        case COMMAND_BURN_FROM_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_burn";
                return false;
            }
            touch_accounting_slot(slot);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            _explicit_money_burn = saturating_add(_explicit_money_burn, amount, _saturation_count);
            break;
        }
        case COMMAND_ADD_STOCK: {
            const int64_t idx = _market.index(cmd.i32_0, cmd.i32_1);
            _market.stock[idx] = saturating_add(_market.stock[idx], cmd.i64_0, _saturation_count);
            _explicit_stock_delta = saturating_add(_explicit_stock_delta, cmd.i64_0, _saturation_count);
            break;
        }
        case COMMAND_REMOVE_STOCK: {
            const int64_t idx = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _market.stock[idx]));
            _market.stock[idx] -= amount;
            _explicit_stock_delta = saturating_sub(_explicit_stock_delta, amount, _saturation_count);
            break;
        }
        case COMMAND_ADD_POPULATION: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_population_adjust";
                return false;
            }
            touch_accounting_slot(slot);
            const int64_t before = _population.population[slot];
            const int64_t after = std::max<int64_t>(0, saturating_add(before, cmd.i64_0,
                                                                      _saturation_count));
            const int64_t actual_delta = after - before;
            _population.population[slot] = after;
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
            break;
        }
        case COMMAND_TRANSFER_FROM_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_transfer";
                return false;
            }
            touch_accounting_slot(slot);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            _treasury_cash = saturating_add(_treasury_cash, amount, _saturation_count);
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
    for (int32_t slot : slots) touch_accounting_slot(slot);
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

    const auto formula_start = Clock::now();
    // Price and environment are frozen for the whole market tick. Compile the
    // variant side once per market instead of repeating it for every cohort.
    build_demand_basis(market, environment_sample_for_cell(market),
                       variant_score_cache, variant_price_cache,
                       need_score_sum_cache, need_composite_cache,
                       need_environment_cache, sat);
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
    }
    result.merchant_count += merchant_end - merchant_begin;
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
        const int64_t target = mul_div_sat(ema, _good_target_inventory_days_q16[good],
                                           Q16_ONE, sat);
        const int64_t gap = std::clamp<int64_t>(
            mul_div_sat(target - _market.stock[idx], Q16_ONE,
                        std::max<int64_t>(GOODS_SCALE, target), sat), -Q16_ONE, Q16_ONE);
        const int64_t shortage = good_demand[good] <= 0 ? 0 : std::clamp<int64_t>(
            Q16_ONE - mul_div_sat(good_sales[good], Q16_ONE, good_demand[good], sat),
            0, Q16_ONE);
        _market.last_shortage_q16[idx] = static_cast<uint16_t>(
            std::min<int64_t>(Q16_ONE - 1, shortage));
        int64_t pressure = saturating_add(
            mul_div_sat(gap, _good_inventory_weight_q16[good], Q16_ONE, sat),
            mul_div_sat(shortage, _good_shortage_weight_q16[good], Q16_ONE, sat), sat);
        int64_t change_q16 = mul_div_sat(pressure, _good_price_adjust_q16[good], Q16_ONE, sat);
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
        _market.price[idx] = static_cast<int32_t>(bounded);
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
    if (cmd.opcode == 0) {
        const int64_t estate_funds = _population.funds[source];
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, estate_funds, _saturation_count);
        _treasury_cash = saturating_add(_treasury_cash, estate_funds,
                                        _saturation_count);
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
        _structural_touched_cells.push_back(source_cell);
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

    const int32_t destination = _population.allocate_slot(cmd.cell, static_cast<uint32_t>(cmd.signature));
    if (destination < 0) {
        error = "structural_destination_allocation_failed";
        return false;
    }
    touch_accounting_slot(destination);
    const int64_t destination_pop_before = _population.population[destination];
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
    _closing_totals.treasury_cash = _treasury_cash;
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds + _opening_totals.treasury_cash;
    const int64_t money_close = _closing_totals.cohort_funds + _closing_totals.treasury_cash;
    const int64_t money_expected = money_open + _explicit_money_mint - _explicit_money_burn;
    _closing_totals.goods_stock = saturating_add(
        _closing_totals.goods_stock,
        saturating_sub(_production_output_stock, _production_inputs_consumed,
                       _saturation_count), _saturation_count);
    const int64_t goods_expected = _opening_totals.goods_stock + _explicit_stock_delta +
                                   _production_output_stock - _consumed_goods -
                                   _construction_goods_consumed - _production_inputs_consumed;
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
    _publish_ms += elapsed_ms(start);
    return true;
}

void NativeEconomyRuntime::fail(const std::string &reason) {
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
                _structural_commands.insert(_structural_commands.end(),
                                             market_result.structural_commands.begin(),
                                             market_result.structural_commands.end());
                ++work_done;
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
    cap(_market_cell_offsets); cap(_market_cells);
    cap(_signatures); cap(_plans); cap(_rules); cap(_rule_params); cap(_pending_commands);
    cap(_epoch_commands); cap(_structural_commands); cap(_committed_cells);
    cap(_staging_cells); cap(_structural_touched_cells);
    cap(_building_types); cap(_building_employee_roles); cap(_building_construction_goods);
    cap(_building_inputs); cap(_building_outputs); cap(_building_resources);
    cap(_building_conditions); cap(_buildings); cap(_building_cell_offsets);
    cap(_building_active_cells);
    cap(_building_employee_filled);
    cap(_pending_construction); cap(_resource_snapshot); cap(_resource_remaining);
    cap(_resource_deltas);
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
    out["building_wages_paid"] = _building_wages_paid;
    out["building_wages_unpaid"] = _building_wages_unpaid;
    out["last_building_rejection_reason"] = String(_last_building_rejection_reason.c_str());
    out["population_error"] = _epoch_active ? 0 : _closing_totals.population - population_expected;
    out["money_error"] = _epoch_active ? 0
        : money_close - (money_open + _explicit_money_mint - _explicit_money_burn);
    out["goods_error"] = _epoch_active ? 0
        : _closing_totals.goods_stock -
              (_opening_totals.goods_stock + _explicit_stock_delta +
               _production_output_stock - _consumed_goods -
               _construction_goods_consumed - _production_inputs_consumed);
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
    out["approximation_version"] = 1;
    out["approximation_model"] = "frozen_sample_linear_v1";
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
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const CellSummary &summary = _committed_cells[cell_idx];
    out["ok"] = true;
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
    out["epoch_id"] = _epoch_id;
    if (_epoch_active || _fatal) {
        out["busy"] = _epoch_active;
        return out;
    }
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
    out["demand_preview_basis"] = "committed_economy_current_environment_daily";
    out["demand_preview_environment_ready"] = sample.ready;
    out["demand_preview_saturation_count"] = preview_saturation_count;
    return out;
}

Dictionary NativeEconomyRuntime::market_cell_snapshot(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const int32_t market = _market.cell_to_market[cell_idx];
    out["ok"] = true;
    out["market_id"] = market;
    out["epoch_id"] = _epoch_id;
    if (_epoch_active || _fatal) {
        out["busy"] = _epoch_active;
        return out;
    }
    PackedStringArray good_ids;
    PackedInt64Array stock;
    PackedInt64Array demand_ema;
    PackedInt32Array price;
    PackedInt32Array shortage_q16;
    for (int32_t g = 0; g < _market.good_count; ++g) {
        good_ids.push_back(String(_good_ids[g].c_str()));
        stock.push_back(_market.stock[_market.index(market, g)]);
        price.push_back(_market.price[_market.index(market, g)]);
        demand_ema.push_back(_market.demand_ema[_market.index(market, g)]);
        shortage_q16.push_back(_market.last_shortage_q16[_market.index(market, g)]);
    }
    out["good_ids"] = good_ids;
    out["stock"] = stock;
    out["price"] = price;
    out["demand_ema"] = demand_ema;
    out["shortage_q16"] = shortage_q16;
    PackedInt64Array merchant_handles;
    PackedInt64Array merchant_population;
    PackedInt64Array merchant_funds;
    for (int32_t k = _merchant_offsets[cell_idx]; k < _merchant_offsets[cell_idx + 1]; ++k) {
        const int32_t slot = _merchant_slots[k];
        merchant_handles.push_back(static_cast<int64_t>(_population.handle_for_slot(slot)));
        merchant_population.push_back(_population.population[slot]);
        merchant_funds.push_back(_population.funds[slot]);
    }
    out["merchant_handles"] = merchant_handles;
    out["merchant_population"] = merchant_population;
    out["merchant_funds"] = merchant_funds;
    return out;
}

Dictionary NativeEconomyRuntime::building_cell_snapshot(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    out["ok"] = true;
    out["epoch_id"] = _epoch_id;
    if (_epoch_active || _fatal) {
        out["busy"] = _epoch_active;
        return out;
    }
    PackedStringArray type_ids;
    PackedInt64Array type_counts;
    PackedInt64Array wage_per_employee_per_day;
    type_counts.resize(static_cast<int64_t>(_building_types.size()));
    type_counts.fill(0);
    for (const std::string &id : _building_type_ids) type_ids.push_back(String(id.c_str()));
    for (const BuildingType &type : _building_types) {
        wage_per_employee_per_day.push_back(type.wage_per_employee_per_day);
    }
    PackedInt32Array group_type_ids;
    PackedInt32Array owner_signature_ids;
    PackedInt64Array group_counts;
    PackedInt64Array filled_owner;
    PackedInt32Array employee_fill_offsets;
    PackedInt32Array employee_profession_ids;
    PackedInt64Array employee_required;
    PackedInt64Array employee_filled;
    PackedInt64Array capacity_q16;
    PackedInt64Array last_input;
    PackedInt64Array last_output;
    PackedInt64Array last_sold;
    PackedInt64Array last_discarded;
    PackedInt64Array last_resource;
    PackedInt64Array last_revenue;
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
        last_revenue.push_back(group.last_revenue);
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            employee_profession_ids.push_back(role.profession_id);
            employee_required.push_back(group.count * role.slots_per_building);
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
    out["group_type_ids"] = group_type_ids;
    out["owner_signature_ids"] = owner_signature_ids;
    out["group_counts"] = group_counts;
    out["filled_owner"] = filled_owner;
    out["employee_fill_offsets"] = employee_fill_offsets;
    out["employee_profession_ids"] = employee_profession_ids;
    out["employee_required"] = employee_required;
    out["employee_filled"] = employee_filled;
    out["capacity_q16"] = capacity_q16;
    out["last_input"] = last_input;
    out["last_output"] = last_output;
    out["last_sold"] = last_sold;
    out["last_discarded"] = last_discarded;
    out["last_resource"] = last_resource;
    out["last_revenue"] = last_revenue;
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
        mix_u64(static_cast<uint64_t>(group.last_revenue));
    }
    for (int64_t value : _building_employee_filled) mix_u64(static_cast<uint64_t>(value));
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
    _building_catalog_hash = 0;
    _epoch_id = 0;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _last_committed_day = -1;
    _treasury_cash = 0;
    _next_submit_order = 1;
    _opening_totals = {};
    _closing_totals = {};
    clear_epoch_metrics();
    _population.clear(0);
    _market.clear();
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
            append_le<int64_t>(payload, group.last_revenue);
            const int32_t roles = _building_types[group.type_id].employee_count;
            append_le<int32_t>(payload, roles);
            for (int32_t r = 0; r < roles; ++r) {
                append_le<int64_t>(payload, _building_employee_filled[group.employee_fill_begin + r]);
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
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
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
        (schema != 2 && schema != SCHEMA_VERSION) || payload_bytes != bytes.size() - cursor ||
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
                pending_count = 0, building_count = 0, construction_count = 0;
        int64_t active_count = 0, last_day = 0, epoch_id = 0, treasury = 0, seed = 0,
                catalog_hash = 0, money_scale = 0, goods_scale = 0, ratio_scale = 0,
                rate_scale = 0, environment_day = -1, environment_hash = 0,
                building_catalog_hash = 0;
        uint64_t next_submit = 0;
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
            !read_id_table(bytes, cursor, professions) || !read_id_table(bytes, cursor, ethnicities) ||
            !read_id_table(bytes, cursor, good_ids) || !read_id_table(bytes, cursor, plan_ids) ||
            cursor != bytes.size()) {
            error = "save_header_payload_truncated";
            return false;
        }
        if (saved_cells != _cell_count || markets <= 0 || markets > _cell_count ||
            goods != static_cast<int32_t>(_good_ids.size()) || pages < 0 || active_count < 0 ||
            active_count > static_cast<int64_t>(pages) * PAGE_SIZE ||
            pending_count < 0 || pending_count > 1000000 ||
            (schema >= 3 && catalog_hash != _catalog_hash) || money_scale != MONEY_SCALE ||
            goods_scale != GOODS_SCALE || ratio_scale != Q16_ONE || rate_scale != Q32_ONE ||
            professions != _profession_ids || ethnicities != _ethnicity_ids ||
            good_ids != _good_ids || plan_ids != _plan_ids) {
            error = "save_catalog_scale_or_capacity_mismatch";
            return false;
        }
        if (schema >= 3 && (building_catalog_hash != _building_catalog_hash ||
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
                !read_le(bytes, cursor, group.last_revenue) ||
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
    } else if (section == (_restore.schema_version == 2 ? uint16_t{5} : SAVE_SECTION_END)) {
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
        _restore.restored_construction != _restore.expected_construction) {
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
                group.count * _building_types[group.type_id].owner_slots_per_building) {
            out["ok"] = false;
            out["reason"] = "restore_building_owner_or_job_invalid";
            return out;
        }
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int64_t filled = _building_employee_filled[group.employee_fill_begin + r];
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
    out["ok"] = true;
    out["restored_pages"] = restored_pages;
    out["restored_commands"] = restored_commands;
    out["restored_buildings"] = restored_buildings;
    out["cohort_count"] = _population.active_count;
    out["state_hash_catalog"] = _catalog_hash;
    return out;
}

} // namespace pk
