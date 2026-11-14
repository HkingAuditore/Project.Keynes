#pragma once

#include "ideology_runtime.h"
#include "ideology_opinion_bridge.h"
#include "runtime_ideology_draw_kernel.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace pk {
using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x44494b50U; // PKID
constexpr uint32_t SAVE_END = 0x21444e45U;

// ── plan §11.5: the execution-contract version vector ───────────────────────
//
// One constant per rule the plan names. The hash over these is what makes an old save
// REFUSED when execution semantics move (`cell_program_execution_contract_mismatch`)
// instead of being silently reinterpreted under different rules.
//
// BUMP THE MATCHING CONSTANT WHEN THE RULE CHANGES. That is the entire contract: a rule
// change without a bump lets an old archive load under rules it was not written for.
constexpr int32_t kExecutionSemanticsVersion = 1;  // the vector itself changed shape
constexpr int32_t kProgramBackendVersion = 1;      // which programs are derived vs instance
constexpr int32_t kSelectorUnboundedVersion = 1;   // the 32-cap removal semantics
constexpr int32_t kSourceCountDecodeVersion = 1;   // kind-16 low-five-bit source count
constexpr int32_t kEvaluatorVersion = 1;           // magnitude / merge / rounding rules
// A copier card (copy_left_programs) at level >= 2 scales the programs it copies by
// 1.2x. ONE definition, used by BOTH backends, because I01 says a program's behaviour
// must not depend on which backend took it -- an earlier version spelled 78643 inline in
// the instance branch only, so a derived copier silently dropped its level-2 bonus.
constexpr int32_t kCopierLevelTwoScaleQ16 = 78643;  // 1.2 * 65536
constexpr int32_t kEligibilityVersion = 1;         // §9.3: eligible_from_day = D + 1
constexpr int32_t MAX_IDEOLOGIES = 65536;
constexpr int32_t MAX_LEVELS = 1000000;
constexpr int32_t MAX_GATES = 65536;
constexpr int64_t TRADE_MONEY_SCALE = 10000;
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &started) {
    return std::chrono::duration<double, std::milli>(Clock::now() - started).count();
}

constexpr auto command_less = [](const auto &a, const auto &b) {
    return std::tie(a.effective_day, a.source_priority, a.producer_id,
                    a.sequence, a.submit_order) <
        std::tie(b.effective_day, b.source_priority, b.producer_id,
                 b.sequence, b.submit_order);
};

template <typename T> void append_le(std::vector<uint8_t> &out, T value) {
    const auto *ptr = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), ptr, ptr + sizeof(T));
}
template <typename T> bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > size) return false;
    std::memcpy(&value, data + cursor, sizeof(T)); cursor += sizeof(T); return true;
}
template <typename T> void append_vec(std::vector<uint8_t> &out, const std::vector<T> &items) {
    append_le<uint64_t>(out, static_cast<uint64_t>(items.size()));
    if (!items.empty()) {
        const auto *ptr = reinterpret_cast<const uint8_t *>(items.data());
        out.insert(out.end(), ptr, ptr + sizeof(T) * items.size());
    }
}
template <typename T> bool read_vec(const uint8_t *data, size_t size, size_t &cursor,
                                    std::vector<T> &items, uint64_t limit) {
    uint64_t count = 0;
    if (!read_le(data, size, cursor, count) || count > limit ||
        count > (size - cursor) / sizeof(T)) return false;
    items.resize(static_cast<size_t>(count));
    if (count != 0) std::memcpy(items.data(), data + cursor, sizeof(T) * count);
    cursor += sizeof(T) * static_cast<size_t>(count); return true;
}
// Length-prefixed string. Used by the applied-basis rows (plan §18.2), whose two
// string fields are the only variable-length members of a row.
void append_string(std::vector<uint8_t> &out, const std::string &text) {
    append_le<uint32_t>(out, static_cast<uint32_t>(text.size()));
    if (!text.empty())
        out.insert(out.end(), text.begin(), text.end());
}
bool read_string(const uint8_t *data, size_t size, size_t &cursor,
                 std::string &text, uint32_t limit) {
    text.clear();
    uint32_t length = 0;
    if (!read_le(data, size, cursor, length) || length > limit ||
            length > size - cursor) return false;
    text.assign(reinterpret_cast<const char *>(data + cursor),
                static_cast<size_t>(length));
    cursor += static_cast<size_t>(length);
    return true;
}
// 1e-6 quantisation for the applied-basis terms digest. Mirrors
// `DerivedCellFront::content_digest` (derived_cell_layer.h): a digest over raw
// double bits would refuse a save for a last-bit difference no fold can observe.
int64_t basis_quantise(double value) {
    if (!std::isfinite(value)) return 0;
    return static_cast<int64_t>(std::llround(value * 1000000.0));
}
PackedInt32Array i32s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt32Array());
    return value.get_type() == Variant::PACKED_INT32_ARRAY ? static_cast<PackedInt32Array>(value) : PackedInt32Array();
}
PackedInt64Array i64s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedInt64Array());
    return value.get_type() == Variant::PACKED_INT64_ARRAY ? static_cast<PackedInt64Array>(value) : PackedInt64Array();
}
PackedByteArray u8s(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedByteArray());
    return value.get_type() == Variant::PACKED_BYTE_ARRAY ? static_cast<PackedByteArray>(value) : PackedByteArray();
}
PackedStringArray strings(const Dictionary &dict, const char *key) {
    Variant value = dict.get(key, PackedStringArray());
    return value.get_type() == Variant::PACKED_STRING_ARRAY ? static_cast<PackedStringArray>(value) : PackedStringArray();
}
Dictionary fail(const std::string &reason) { Dictionary out; out["ok"] = false; out["reason"] = String(reason.c_str()); return out; }
uint64_t mix(uint64_t h, const void *data, size_t n) { const auto *p = static_cast<const uint8_t *>(data); for (size_t i=0;i<n;++i) { h ^= p[i]; h *= 1099511628211ULL; } return h; }
template <typename T> uint64_t mixv(uint64_t h, T value) { return mix(h, &value, sizeof(T)); }
int32_t popcount64(uint64_t value) {
    int32_t count = 0;
    while (value != 0) {
        value &= value - 1;
        ++count;
    }
    return count;
}
uint64_t splitmix64(uint64_t &state) { uint64_t z = (state += 0x9e3779b97f4a7c15ULL); z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL; z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL; return z ^ (z >> 31U); }
// The identity of an Effect program as carried by EffectInstanceRef. One
// definition because two call sites hash it: the reconciler that stamps the ref
// and the report that labels it with a domain. A second copy would be a silent
// divergence the moment either side is touched.
uint64_t effect_program_hash(const std::string &program) {
    return mix(1469598103934665603ULL, program.data(), program.size());
}
// Digest of "which columns this instance conditions on, and what they read".
// Deliberately excludes the day and the revision: two reconciles that see the
// same world have to produce the same digest, otherwise the publish gate in
// reconcile_effect_activations() would never close.
uint64_t metric_publish_digest(const MetricMask &mask,
                               const std::vector<int64_t> &values) {
    uint64_t digest = 1469598103934665603ULL;
    for (int32_t word = 0; word < MetricMask::WORD_COUNT; ++word)
        digest = mixv(digest, mask.word(word));
    const int32_t count = static_cast<int32_t>(values.size()) < MetricMask::CAPACITY
        ? static_cast<int32_t>(values.size()) : MetricMask::CAPACITY;
    for (int32_t id = 0; id < count; ++id) {
        if (!mask.test(id)) continue;
        digest = mixv(digest, values[static_cast<size_t>(id)]);
    }
    return digest;
}
int64_t add_sat(int64_t a, int64_t b) { if (b > 0 && a > std::numeric_limits<int64_t>::max() - b) return std::numeric_limits<int64_t>::max(); if (b < 0 && a < std::numeric_limits<int64_t>::min() - b) return std::numeric_limits<int64_t>::min(); return a+b; }
int64_t mul_sat(int64_t a, int64_t b) {
    if (a == 0 || b == 0) return 0;
    if (a == -1 && b == std::numeric_limits<int64_t>::min())
        return std::numeric_limits<int64_t>::max();
    if (b == -1 && a == std::numeric_limits<int64_t>::min())
        return std::numeric_limits<int64_t>::max();
    if (a > 0) {
        if (b > 0 && a > std::numeric_limits<int64_t>::max() / b)
            return std::numeric_limits<int64_t>::max();
        if (b < 0 && b < std::numeric_limits<int64_t>::min() / a)
            return std::numeric_limits<int64_t>::min();
    } else {
        if (b > 0 && a < std::numeric_limits<int64_t>::min() / b)
            return std::numeric_limits<int64_t>::min();
        if (b < 0 && a < std::numeric_limits<int64_t>::max() / b)
            return std::numeric_limits<int64_t>::max();
    }
    return a * b;
}

}
} // namespace pk
