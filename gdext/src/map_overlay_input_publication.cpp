#include "map_overlay_input_publication.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <array>

namespace pk {
namespace {
using namespace godot;

constexpr const char *READER = "_map_overlay_input_reader";
constexpr const char *TRACK_WIND = "_map_overlay_tracks_wind";
constexpr const char *WIND = "_map_overlay_wind_publication";
constexpr const char *ELEVATION = "_map_overlay_elevation_publication";
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

bool same_storage(const Array &a, const Array &b) {
    if (a.size() != b.size() || a.is_empty()) return false;
    for (int64_t i = 0; i < a.size(); ++i) {
        const PackedFloat32Array left = a[i];
        const PackedFloat32Array right = b[i];
        if (left.size() != right.size() || left.ptr() != right.ptr()) return false;
    }
    return true;
}

void publish(Object *map, const char *name, const Array &lanes,
             const MapOverlayInputSignature &signature) {
    PackedInt64Array words;
    for (const uint64_t word : signature.words) words.append(static_cast<int64_t>(word));
    Dictionary installed;
    installed["lanes"] = lanes;
    installed["signature"] = words;
    map->set_meta(name, installed);
}

Dictionary read_map_overlay_inputs(Object *map, bool wind, int64_t cells, const Dictionary &previous) {
    if (cells <= 0) return {};
    const Array lanes = wind ? read_lanes(map, WIND_FIELDS) : read_lanes(map, ELEVATION_FIELDS);
    if (lanes.is_empty()) return {};
    for (int64_t i = 0; i < lanes.size(); ++i) {
        const PackedFloat32Array lane = lanes[i];
        if (lane.size() != cells) return {};
    }

    const Dictionary installed = map->get_meta(wind ? WIND : ELEVATION, Dictionary());
    // An edit outside the publisher detaches storage and invalidates its key.
    PackedInt64Array signature;
    if (same_storage(lanes, installed.get("lanes", Array())))
        signature = installed.get("signature", PackedInt64Array());
    const PackedInt64Array previous_signature = previous.get("signature", PackedInt64Array());
    const bool storage_matches = same_storage(lanes, previous.get("lanes", Array()));
    const bool keys_available = signature.size() == 2 && previous_signature.size() == 2 &&
        cells == static_cast<int64_t>(previous.get("cells", 0));
    if (storage_matches && signature.is_empty()) signature = previous_signature;
    Dictionary out;
    out["same"] = storage_matches || (keys_available && signature == previous_signature);
    out["change_known"] = storage_matches || keys_available;
    out["lanes"] = lanes;
    out["signature"] = signature;
    out["cells"] = cells;
    return out;
}
} // namespace

void bind_map_overlay_input_reader(godot::Object *map) {
    map->set_meta(READER, callable_mp_static(&read_map_overlay_inputs));
    if (map->has_meta(WIND)) map->remove_meta(WIND);
    publish_map_overlay_elevation(map);
}

void publish_map_overlay_elevation(godot::Object *map) {
    const Array lanes = read_lanes(map, ELEVATION_FIELDS);
    if (lanes.is_empty()) return;
    const Dictionary installed = map->get_meta(ELEVATION, Dictionary());
    if (same_storage(lanes, installed.get("lanes", Array()))) return;
    const PackedFloat32Array elevation = lanes[0];
    MapOverlayInputSignature signature;
    for (int64_t i = 0; i < elevation.size(); ++i) signature.add(elevation[i]);
    publish(map, ELEVATION, lanes, signature);
}

void publish_map_overlay_wind(godot::Object *map,
                              const std::optional<MapOverlayInputSignature> &signature) {
    if (!map->has_meta(TRACK_WIND)) return;
    if (!signature) {
        if (map->has_meta(WIND)) map->remove_meta(WIND);
        return;
    }
    publish(map, WIND, read_lanes(map, WIND_FIELDS), *signature);
}
} // namespace pk
