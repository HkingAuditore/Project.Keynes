#pragma once

// _Slot mirrors the GDScript-side internal slot dict in `data_core/world.gd`.
//
// One Slot per registered component. The relevant typed PackedArray (f32/i32/u8)
// holds the COW reference to the underlying buffer; when `bind_map_data()` runs,
// the GDScript `MapData.temp_arr` (etc.) is assigned into `arr_f32`, which keeps
// both sides on the same physical memory page — C++ hot loops can call
// `arr_f32.ptrw()` and write directly while the GDScript renderer keeps reading
// the same `map.temp_arr`.

#include <cstdint>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pk {

enum class SlotDType : int32_t {
    F32 = 0,
    I32 = 1,
    U8  = 2,
};

struct Slot {
    godot::StringName name;
    SlotDType         dtype = SlotDType::F32;
    int32_t           stride = 1;            // 1 = scalar, 2 = vec2 (e.g. wind), 3 = vec3
    bool              track_prev = false;    // mirror DCComponentIds tracking flag

    // Backing storage. Exactly one of these is "live" depending on `dtype`.
    // PackedArrays are COW — assigning here from GDScript shares the buffer.
    godot::PackedFloat32Array arr_f32;
    godot::PackedInt32Array   arr_i32;
    godot::PackedByteArray    arr_u8;

    // True if the buffer was injected by an external owner (e.g. MapData).
    // When `external_ref == true`, DCWorldExt MUST NOT resize this array
    // (would break the COW alias and silently desync from GDScript).
    bool external_ref = false;
};

} // namespace pk
