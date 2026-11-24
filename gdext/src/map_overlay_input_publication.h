#ifndef PK_MAP_OVERLAY_INPUT_PUBLICATION_H
#define PK_MAP_OVERLAY_INPUT_PUBLICATION_H

#include "map_overlay_input_signature.h"

#include <optional>

namespace godot { class Object; }

namespace pk {
void bind_map_overlay_input_reader(godot::Object *map);
void publish_map_overlay_elevation(godot::Object *map);
void publish_map_overlay_wind(godot::Object *map,
                              const std::optional<MapOverlayInputSignature> &signature);
}

#endif
