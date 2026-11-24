#ifndef PK_MAP_OVERLAY_INPUT_PUBLICATION_H
#define PK_MAP_OVERLAY_INPUT_PUBLICATION_H

#include <cstdint>

namespace godot { class Object; }

namespace pk {
void bind_map_overlay_input_reader(godot::Object *map);
void publish_map_overlay_wind(godot::Object *map, int64_t solve_id, int64_t solve_day);
}

#endif
