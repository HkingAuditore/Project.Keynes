#include "map_overlay_input_publication.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <array>
#include <cstring>

namespace pk {
namespace {
using namespace godot;

constexpr const char *READER = "_map_overlay_input_reader";
constexpr const char *TRACK_WIND = "_map_overlay_tracks_wind";
constexpr const char *WIND = "_map_overlay_wind_publication";
constexpr std::array<const char *, 3> WIND_FIELDS = {
    "wind_x_arr", "wind_y_arr", "wind_speed_arr",
};
constexpr std::array<const char *, 1> ELEVATION_FIELDS = {"elevation_arr"};

template <size_t N>
Array read_lanes(Object *map, const std::array<const char *, N> &fields) {
    Array lanes;
    for (const char *field : fields) {
        const Variant value = map->get(field);
        if (value.get_type() != Variant::PACKED_FLOAT32_ARRAY) return {};
        // Construct a native packed handle before handing it back to script.
        // Script aliases alone share a mutable Variant, even for indexed edits.
        const PackedFloat32Array lane = value;
        lanes.push_back(lane);
    }
    return lanes;
}

bool lanes_match(const Array &a, const Array &b, bool compare_bytes) {
    if (a.size() != b.size() || a.is_empty()) return false;
    for (int64_t i = 0; i < a.size(); ++i) {
        const PackedFloat32Array left = a[i];
        const PackedFloat32Array right = b[i];
        if (left.size() != right.size()) return false;
        if (left.ptr() != right.ptr() && (!compare_bytes ||
                std::memcmp(left.ptr(), right.ptr(), left.size() * sizeof(float)) != 0)) {
            return false;
        }
    }
    return true;
}

Dictionary read_map_overlay_inputs(Object *map, bool wind, int64_t cells, const Dictionary &previous) {
    if (cells <= 0) return {};
    const Array lanes = wind ? read_lanes(map, WIND_FIELDS) : read_lanes(map, ELEVATION_FIELDS);
    if (lanes.is_empty()) return {};
    for (int64_t i = 0; i < lanes.size(); ++i) {
        const PackedFloat32Array lane = lanes[i];
        if (lane.size() != cells) return {};
    }

    int64_t solve_id = 0;
    if (wind) {
        const Dictionary installed = map->get_meta(WIND, Dictionary());
        // A native or script edit after writeback can detach any of the three
        // lanes. The solver tag describes only the values actually installed.
        if (lanes_match(lanes, installed.get("lanes", Array()), false))
            solve_id = installed.get("solve_id", 0);
    }
    const int64_t previous_solve = previous.get("solve_id", 0);
    const bool same_solve = solve_id > 0 && solve_id == previous_solve;
    Dictionary out;
    out["same"] = same_solve || lanes_match(lanes, previous.get("lanes", Array()), true);
    out["lanes"] = lanes;
    out["solve_id"] = solve_id;
    return out;
}
} // namespace

void bind_map_overlay_input_reader(godot::Object *map) {
    map->set_meta(READER, callable_mp_static(&read_map_overlay_inputs));
    if (map->has_meta(WIND)) map->remove_meta(WIND);
}

void publish_map_overlay_wind(godot::Object *map, int64_t solve_id, int64_t solve_day) {
    if (!map->has_meta(TRACK_WIND)) return;
    if (solve_id <= 0) {
        if (map->has_meta(WIND)) map->remove_meta(WIND);
        return;
    }
    godot::Dictionary installed;
    installed["lanes"] = read_lanes(map, WIND_FIELDS);
    installed["solve_id"] = solve_id;
    installed["solve_day"] = solve_day;
    map->set_meta(WIND, installed);
}
} // namespace pk
