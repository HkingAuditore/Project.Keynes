#include "world_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

using namespace godot;

void DCWorldExt::_bind_bake_encoders_methods() {
    // Bake-time static texture encoders: C++ byte payload, GD texture upload.
    ClassDB::bind_method(
        D_METHOD("encode_bake_height_tex_data", "knobs"),
        &DCWorldExt::encode_bake_height_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_terrain_normal_tex_data", "knobs"),
        &DCWorldExt::encode_bake_terrain_normal_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_horizon_tex_data", "knobs"),
        &DCWorldExt::encode_bake_horizon_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_r8_tex_data", "knobs"),
        &DCWorldExt::encode_bake_r8_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_flow_tex_data", "knobs"),
        &DCWorldExt::encode_bake_flow_tex_data);
    ClassDB::bind_method(
        D_METHOD("encode_bake_enum_atlas_payload", "knobs"),
        &DCWorldExt::encode_bake_enum_atlas_payload);
    ClassDB::bind_method(
        D_METHOD("encode_bake_upwelling_tex_data", "knobs"),
        &DCWorldExt::encode_bake_upwelling_tex_data);
}

} // namespace pk
