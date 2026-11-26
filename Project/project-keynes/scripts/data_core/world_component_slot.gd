extends RefCounted
var name: StringName
var dtype: int
var stride: int = 1
var track_prev: bool = false
var external_ref: bool = false  # true = 由 bind_map_data() 挂入的外部数组（rebind 时刷新）
var arr_f32: PackedFloat32Array = PackedFloat32Array()
var arr_f32_prev: PackedFloat32Array = PackedFloat32Array()
var arr_f32_y: PackedFloat32Array = PackedFloat32Array()
var arr_f32_y_prev: PackedFloat32Array = PackedFloat32Array()
var arr_f32_z: PackedFloat32Array = PackedFloat32Array()
var arr_f32_z_prev: PackedFloat32Array = PackedFloat32Array()
var arr_i32: PackedInt32Array = PackedInt32Array()
var arr_u8: PackedByteArray = PackedByteArray()
