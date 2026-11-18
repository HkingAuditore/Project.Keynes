extends RefCounted

# The packed 2D instances use eight transform floats followed by color and custom data.
const STRIDE := 16
const FOOTPRINT := &"fog_draw_footprint"
const PASS := &"fog_draw_pass"
const REST_RECT := &"fog_draw_rest_rect"
const STYLE_MAXIMA := &"fog_draw_style_maxima"

enum Kind {
	VEGETATION, VEGETATION_SHADOW, FAMILY_SHADOW, RESOURCE,
	BUILDING_BODY, BUILDING_DECAL, BUILDING_SHADOW,
}

class Footprint:
	var centers: Rect2
	var max_axis: float


## Record bounds at upload, while the transforms are already on the CPU.
## Wrap copies share the same MultiMesh and apply their own canvas transform.
static func upload(batch: MultiMesh, buffer: PackedFloat32Array, kind: Kind,
		same_geometry: MultiMesh = null) -> void:
	batch.buffer = buffer
	batch.set_meta(PASS, kind)
	if kind == Kind.RESOURCE:
		batch.remove_meta(REST_RECT)
		return
	var footprint := measure(buffer, batch.instance_count) if same_geometry == null \
		else _get_footprint(same_geometry)
	batch.set_meta(FOOTPRINT, footprint)


static func measure(buffer: PackedFloat32Array, count: int) -> Footprint:
	if count <= 0 or buffer.size() < count * STRIDE:
		return null
	var lower := Vector2(INF, INF)
	var upper := Vector2(-INF, -INF)
	var longest_axis_squared := 0.0
	for base in range(0, count * STRIDE, STRIDE):
		var center := Vector2(buffer[base + 3], buffer[base + 7])
		var x := Vector2(buffer[base], buffer[base + 4])
		var y := Vector2(buffer[base + 1], buffer[base + 5])
		if not center.is_finite() or not x.is_finite() or not y.is_finite():
			return null
		lower = lower.min(center)
		upper = upper.max(center)
		longest_axis_squared = maxf(longest_axis_squared, maxf(x.length_squared(), y.length_squared()))
	var result := Footprint.new()
	result.centers = Rect2(lower, upper - lower)
	result.max_axis = sqrt(longest_axis_squared)
	return result


static func _get_footprint(batch: MultiMesh) -> Footprint:
	return batch.get_meta(FOOTPRINT) if batch.has_meta(FOOTPRINT) else null


static func local_rect(item: MultiMeshInstance2D) -> Rect2:
	var batch := item.multimesh
	if batch == null or batch.mesh == null or not batch.has_meta(PASS):
		return Rect2()
	var material := item.material as ShaderMaterial
	if material == null:
		return Rect2()
	var kind: int = batch.get_meta(PASS)
	if kind == Kind.RESOURCE:
		return _resource_rect(batch, material)
	var footprint := _get_footprint(batch)
	if footprint == null or not is_finite(footprint.max_axis):
		return Rect2()
	# The shader uses world-space scale/length for custom projections. The
	# layer and wrap instances only translate; leave other outer poses to Godot.
	var pose := item.global_transform
	if pose.x != Vector2.RIGHT or pose.y != Vector2.DOWN:
		return Rect2()

	var radius := _reach(kind, batch.mesh, material, footprint.max_axis)
	if radius <= 0.0 or not is_finite(radius):
		return Rect2()
	return footprint.centers.grow(radius)


static func _resource_rect(batch: MultiMesh, material: ShaderMaterial) -> Rect2:
	# Outside the resource lens, its vertex only shrinks or collapses the
	# base geometry. Reuse Godot's bounds and refresh them after each upload.
	if _param_abs(material, &"lens_amount", 0.0) != 0.0:
		return Rect2()
	if not batch.has_meta(REST_RECT):
		var box := batch.get_aabb()
		batch.set_meta(REST_RECT, Rect2(Vector2(box.position.x, box.position.y),
			Vector2(box.size.x, box.size.y)))
	return batch.get_meta(REST_RECT)


static func _reach(kind: Kind, mesh: Mesh, material: ShaderMaterial, axis: float) -> float:
	match kind:
		Kind.VEGETATION:
			# vegetation_impostor vertex scales its mesh about the instance center.
			var size := maxf(_param_abs(material, &"vitality_size_min", 0.34),
				_param_abs(material, &"vitality_size_max", 1.08))
			var floor_size := _param_abs(material, &"snow_size_floor", 0.0)
			var style := _style_maxima(material)
			var rect := mesh.get_aabb()
			var vertex := rect.position.abs().max(rect.end.abs())
			return axis * (vertex.x + vertex.y) * maxf(1.0, maxf(size, maxf(floor_size, style.z)))
		Kind.VEGETATION_SHADOW, Kind.FAMILY_SHADOW:
			# vegetation_shadow vertex reaches projection + foot along the sun,
			# plus up to 1.45 foot across it. The mesh is a unit disc.
			var foot := _param_abs(material, &"shadow_foot_radius", 0.55)
			var length_scale := _param_abs(material, &"shadow_length_scale", 1.0)
			if kind == Kind.FAMILY_SHADOW:
				var style := _style_maxima(material)
				if style.x < 0.0:
					return 0.0
				foot = style.x
				length_scale = style.y
			var reach := _param_abs(material, &"shadow_max_len", 3.6) * length_scale
			return sqrt(2.0) * axis * (reach + 2.45 * foot)
		Kind.BUILDING_BODY:
			# building_compound vertex includes windmill sails, the 0.9 margin,
			# and the roof lift with BF_HEIGHT_RANGE = 16.0.
			var sails := maxf(1.35, 2.4 * axis) + 0.1
			var lift := 16.0 * _param_abs(material, &"oblique", 0.30)
			return 2.0 * (maxf(sails, axis) + 0.9 + lift)
		Kind.BUILDING_DECAL:
			return 2.0 * (axis + 0.12)
		Kind.BUILDING_SHADOW:
			# building_shadow vertex uses SHADOW_MARGIN=0.45, at most 1.08
			# round-footprint expansion, and SHADOW_MAX_REACH=5.0.
			return 2.0 * (1.08 * (axis + 0.45) + 5.0)
	return 0.0


static func _param_abs(material: ShaderMaterial, name: StringName, default: float) -> float:
	var value: Variant = material.get_shader_parameter(name)
	return absf(float(value)) if value != null else default


static func _style_maxima(material: ShaderMaterial) -> Vector3:
	var style: Variant = material.get_shader_parameter(&"detail_style_lut")
	if style is Texture2D and style.has_meta(STYLE_MAXIMA):
		return style.get_meta(STYLE_MAXIMA)
	return Vector3(-1.0, -1.0, 0.0)
