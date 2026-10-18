#include "world_ext.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;

// Pure numeric upload baker. No runtime, Object, map or worker access.
Dictionary DCWorldExt::bake_trade_visual_paths(const Dictionary &snapshot,
        int map_width, double hex_size) const {
    Dictionary out;
    out["ok"] = false;
    if (map_width <= 0 || !std::isfinite(hex_size) || hex_size <= 0) return out;
    const PackedInt32Array offsets = snapshot.get("route_offsets", PackedInt32Array());
    const PackedInt32Array cells = snapshot.get("route_cells", PackedInt32Array());
    const PackedByteArray modes = snapshot.get("edge_modes", PackedByteArray());
    if (offsets.is_empty() || offsets.size() > 33 || modes.size() != cells.size() ||
        offsets[0] != 0 || offsets[offsets.size() - 1] != cells.size()) return out;
    std::vector<float> pixels(1024 * 32 * 4, 0.0f);
    PackedInt32Array counts;
    PackedFloat32Array lengths;
    const float stride = static_cast<float>(std::sqrt(3.0) * hex_size);
    const float wrap = stride * map_width;
    const int32_t *cell_ptr = cells.ptr();
    for (int64_t r = 0; r + 1 < offsets.size(); ++r) {
        const int32_t begin = offsets[r], end = offsets[r + 1];
        if (begin < 0 || end < begin || end > cells.size() || end - begin > 1024) return out;
        float distance = 0.0f, previous_x = 0.0f, previous_y = 0.0f;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t cell = cell_ptr[i];
            // Float payload packs 4*cell+mode exactly up to the 200k-cell target.
            if (cell < 0 || cell >= 4'000'000 || modes[i] > 1) return out;
            const int32_t row = cell / map_width, col = cell % map_width;
            float x = stride * (col + 0.5f * (row & 1));
            const float y = static_cast<float>(hex_size * 1.5 * row);
            if (i > begin) {
                x += std::round((previous_x - x) / wrap) * wrap;
                distance += std::hypot(x - previous_x, y - previous_y);
            }
            float *pixel = pixels.data() + (r * 1024 + i - begin) * 4;
            pixel[0] = x; pixel[1] = y; pixel[2] = distance;
            pixel[3] = static_cast<float>(cell * 4 + modes[i]);
            previous_x = x; previous_y = y;
        }
        counts.push_back(end - begin); lengths.push_back(distance);
    }
    PackedByteArray bytes;
    bytes.resize(static_cast<int64_t>(pixels.size() * sizeof(float)));
    std::memcpy(bytes.ptrw(), pixels.data(), static_cast<size_t>(bytes.size()));
    out["ok"] = true; out["path_bytes"] = bytes;
    out["point_counts"] = counts; out["path_lengths"] = lengths;
    return out;
}
} // namespace pk
