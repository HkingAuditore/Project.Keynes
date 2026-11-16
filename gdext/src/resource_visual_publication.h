#pragma once

#include <cstring>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pk {
// MapData presentation flags: 1 abundance/occupancy, 2 remembered climate,
// 4 placement inputs (water domain and elevation).
// This is a publication notification, not another full-array change detector.
// The listener only queues work; it cannot sample an unfinished flush batch.
inline void notify_resource_visual_publication(godot::Object *map,
                                               const char *property) {
    int flags = 0;
    if (std::strncmp(property, "res_", 4) == 0 &&
            std::strstr(property, "_reserve_arr") != nullptr)
        flags = 1;
    else if (std::strcmp(property, "bio_occupancy_bits_arr") == 0 ||
             std::strcmp(property, "resource_habitat_mask_arr") == 0)
        flags = 3;
    else if (std::strcmp(property, "visible_arr") == 0)
        flags = 7;
    else if (std::strcmp(property, "temp_arr") == 0 ||
             std::strcmp(property, "moisture_arr") == 0 ||
             std::strcmp(property, "snow_cover_arr") == 0 ||
             std::strcmp(property, "vegetation_vitality_arr") == 0)
        flags = 2;
    else if (std::strcmp(property, "is_water_arr") == 0 ||
             std::strcmp(property, "elevation_arr") == 0)
        flags = 4;
    if (flags == 0 || map == nullptr) return;
    const godot::StringName signal("resource_visual_inputs_changed");
    if (map->has_signal(signal))
        map->emit_signal(signal, flags, godot::PackedInt32Array());
}
} // namespace pk
