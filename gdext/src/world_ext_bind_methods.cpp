#include "world_ext.h"

namespace pk {

void DCWorldExt::_bind_methods() {
    using namespace godot;
    _bind_core_methods();
    _bind_runtime_methods();
    _bind_climate_methods();
    _bind_economy_methods();
    _bind_country_methods();
    _bind_military_methods();
    _bind_effect_methods();
    _bind_modifier_methods();
    _bind_ideology_methods();
    _bind_trigger_methods();
    _bind_events_methods();
    _bind_generation_methods();
    _bind_bake_encoders_methods();
    _bind_visual_methods();
    _bind_demo_methods();
}

} // namespace pk
