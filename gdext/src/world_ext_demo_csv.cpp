#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <functional>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif


#include "world_ext_internal.h"

namespace pk {
using namespace godot;

namespace {

inline void pk_csv_append_int(std::string &out, int64_t v) {
    char buf[32];
    auto res = std::to_chars(buf, buf + sizeof(buf), v);
    if (res.ec == std::errc()) {
        out.append(buf, res.ptr);
    }
}

inline void pk_csv_append_float(std::string &out, float v) {
    if (!std::isfinite(v)) {
        return;
    }
    char buf[64];
    const int n = std::snprintf(buf, sizeof(buf), "%.6f", double(v));
    if (n <= 0) {
        return;
    }
    int end = n;
    while (end > 0 && buf[end - 1] == '0') {
        --end;
    }
    if (end > 0 && buf[end - 1] == '.') {
        --end;
    }
    if (end <= 0 || (end == 1 && buf[0] == '-')) {
        out.push_back('0');
        return;
    }
    out.append(buf, buf + end);
}

struct TileCsvFieldRef {
    enum Kind : int {
        F32 = 0,
        I32 = 1,
        U8 = 2,
    };

    Kind kind = F32;
    PackedFloat32Array f32;
    PackedInt32Array i32;
    PackedByteArray u8;
    const float *f32_ptr = nullptr;
    const int32_t *i32_ptr = nullptr;
    const uint8_t *u8_ptr = nullptr;
};

} // anonymous namespace

godot::PackedByteArray DCWorldExt::encode_tile_csv_rows(godot::Dictionary knobs) {
    using godot::Array;
    using godot::CharString;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::Variant;

    auto fail = []() -> PackedByteArray {
        return PackedByteArray();
    };

    if (!knobs.has("row_start") || !knobs.has("fixed_suffix") ||
        !knobs.has("cell_count") || !knobs.has("q_arr") ||
        !knobs.has("r_arr") || !knobs.has("s_arr") || !knobs.has("arrays")) {
        return fail();
    }

    const int row_start = int(knobs["row_start"]);
    const int cell_start = std::max(0, int(knobs.get("cell_start", 0)));
    const int cell_count = int(knobs["cell_count"]);
    const int cell_stride = std::max(1, int(knobs.get("cell_stride", 1)));
    if (row_start < 0 || cell_count <= 0 || cell_start >= cell_count) {
        return fail();
    }

    const String fixed_suffix = knobs.get("fixed_suffix", String());
    const CharString fixed_utf8 = fixed_suffix.utf8();
    const char *fixed_data = fixed_utf8.get_data();
    const int fixed_len = fixed_utf8.length();

    PackedInt32Array q_arr = knobs["q_arr"];
    PackedInt32Array r_arr = knobs["r_arr"];
    PackedInt32Array s_arr = knobs["s_arr"];
    if (q_arr.size() < cell_count || r_arr.size() < cell_count || s_arr.size() < cell_count) {
        return fail();
    }
    const int32_t * const q_ptr = q_arr.ptr();
    const int32_t * const r_ptr = r_arr.ptr();
    const int32_t * const s_ptr = s_arr.ptr();

    Array arrays = knobs["arrays"];
    std::vector<TileCsvFieldRef> fields;
    fields.reserve(size_t(arrays.size()));
    for (int i = 0; i < arrays.size(); ++i) {
        const Variant v = arrays[i];
        TileCsvFieldRef ref;
        switch (v.get_type()) {
            case Variant::PACKED_FLOAT32_ARRAY:
                ref.kind = TileCsvFieldRef::F32;
                ref.f32 = v;
                if (ref.f32.size() < cell_count) return fail();
                ref.f32_ptr = ref.f32.ptr();
                break;
            case Variant::PACKED_INT32_ARRAY:
                ref.kind = TileCsvFieldRef::I32;
                ref.i32 = v;
                if (ref.i32.size() < cell_count) return fail();
                ref.i32_ptr = ref.i32.ptr();
                break;
            case Variant::PACKED_BYTE_ARRAY:
                ref.kind = TileCsvFieldRef::U8;
                ref.u8 = v;
                if (ref.u8.size() < cell_count) return fail();
                ref.u8_ptr = ref.u8.ptr();
                break;
            default:
                return fail();
        }
        fields.push_back(ref);
    }

    const int rows = ((cell_count - cell_start - 1) / cell_stride) + 1;
    const size_t estimated = size_t(rows) *
        (size_t(std::max(0, fixed_len)) + 32u + size_t(fields.size()) * 12u);
    std::string text;
    text.reserve(estimated);

    int row_idx = row_start;
    for (int cell_idx = cell_start; cell_idx < cell_count; cell_idx += cell_stride, ++row_idx) {
        pk_csv_append_int(text, row_idx);
        if (fixed_len > 0) {
            text.append(fixed_data, fixed_data + fixed_len);
        }
        text.push_back(',');
        pk_csv_append_int(text, cell_idx);
        text.push_back(',');
        pk_csv_append_int(text, q_ptr[cell_idx]);
        text.push_back(',');
        pk_csv_append_int(text, r_ptr[cell_idx]);
        text.push_back(',');
        pk_csv_append_int(text, s_ptr[cell_idx]);
        for (const TileCsvFieldRef &field : fields) {
            text.push_back(',');
            switch (field.kind) {
                case TileCsvFieldRef::F32:
                    pk_csv_append_float(text, field.f32_ptr[cell_idx]);
                    break;
                case TileCsvFieldRef::I32:
                    pk_csv_append_int(text, field.i32_ptr[cell_idx]);
                    break;
                case TileCsvFieldRef::U8:
                    pk_csv_append_int(text, int(field.u8_ptr[cell_idx]));
                    break;
            }
        }
        text.push_back('\n');
    }

    if (text.empty()) {
        return fail();
    }

    PackedByteArray out;
    out.resize(int(text.size()));
    std::memcpy(out.ptrw(), text.data(), text.size());
    return out;
}

} // namespace pk
