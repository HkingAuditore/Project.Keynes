extends SceneTree
const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Observations = preload("res://scripts/rendering/resource_visual_observations.gd")
# Independent original dictionary path, including the original band boundaries.
class Reference:
	extends RefCounted
	var rows: Dictionary = {}
	var revision := 0
	var cell_count := 0
	var styles: Array[Dictionary] = []

	func configure(count: int) -> void:
		cell_count = count
		styles = Catalog.entries()
		rows.clear()
		revision += 1

	# Called only with a published MapData and a currently visible cell. Bands are
	# presentation quantities; they never change reserves or the occupancy bitset.
	func observe(map: MapData, cell: int, allowed: PackedByteArray, gm: bool = false) -> bool:
		if cell < 0 or cell >= cell_count or allowed.size() != styles.size():
			return false
		if not gm and (cell >= map.visible_arr.size() or map.visible_arr[cell] == 0):
			return false
		var previous: Dictionary = rows.get(cell, {})
		var old: PackedByteArray = previous.get("bands", PackedByteArray())
		var bands := PackedByteArray()
		bands.resize(styles.size())
		var occupancy := int(map.bio_occupancy_bits_arr[cell]) if cell < map.bio_occupancy_bits_arr.size() else 0
		var habitat := int(map.resource_habitat_mask_arr[cell]) if cell < map.resource_habitat_mask_arr.size() else 0
		for i in styles.size():
			if allowed[i] == 0:
				continue
			var e := styles[i]
			if int(e.bit) >= 0:
				bands[i] = 2 if (occupancy & (1 << int(e.bit))) != 0 else 0
			elif e.profile != null and (int(e.habitat_mask) == 0 or (habitat & int(e.habitat_mask)) != 0):
				# Schema lookup and profile normalization are cold catalog work. Never
				# rescan the component schema for each visible cell and resource.
				var values = map.get(e.reserve_field)
				var reserve := float(values[cell]) if values != null and cell < values.size() else 0.0
				var ratio := maxf(0.0, reserve) / maxf(0.0001, float(e.reference))
				var old_band := int(old[i]) if i < old.size() else 0
				bands[i] = abundance_band(ratio, old_band)
		var changed := old != bands
		if changed or previous.is_empty():
			rows[cell] = {"bands": bands, "climate": _climate(map, cell)}
		else:
			previous["climate"] = _climate(map, cell)
		if changed:
			revision += 1
		return changed

	## Climate publication does not rebuild the 51-entry abundance row or geometry.
	## Unknown visible cells still need their first full observation.
	func observe_climate(map: MapData, cell: int, gm: bool = false) -> bool:
		if cell < 0 or cell >= cell_count or not rows.has(cell):
			return false
		if not gm and (cell >= map.visible_arr.size() or map.visible_arr[cell] == 0):
			return false
		var climate := _climate(map, cell)
		if rows[cell].climate == climate:
			return false
		rows[cell].climate = climate
		return true

	static func _climate(map: MapData, cell: int) -> Color:
		return Color(_value(map.temp_arr, cell, 0.5), _value(map.moisture_arr, cell, 0.5),
			_value(map.snow_cover_arr, cell, 0.0), _value(map.vegetation_vitality_arr, cell, 1.0))

	static func abundance_band(ratio: float, previous: int = 0) -> int:
		if ratio <= 0.000001:
			return 0
		var band := 1
		for boundary in [0.25, 0.70, 1.50]:
			if ratio >= float(boundary):
				band += 1
		if previous > 0 and previous != band:
			var limits := [0.0, 0.25, 0.70, 1.50, INF]
			if ratio >= float(limits[previous - 1]) * 0.9 and ratio <= float(limits[previous]) * 1.1:
				return previous
		return band


	static func _value(values: PackedFloat32Array, cell: int, fallback: float) -> float:
		return clampf(values[cell], 0.0, 1.0) if cell < values.size() else fallback

var checks := 0
var failures := 0
func _init() -> void:
	call_deferred("run")
func run() -> void:
	var map := Fixtures.make_map(4, 4)
	var actual := Observations.new()
	var reference := Reference.new()
	actual.configure(map.cell_count())
	reference.configure(map.cell_count())
	_expect("typed catalog matches original observation across changes", _compare_sequence(map, actual, reference, 20261115))
	# ResourceProfile normalization was already configure-time catalog data.
	# Reconfiguration must derive fresh references, not preserve a prior cache.
	var resource: ResourceProfile = actual.styles[20].profile
	var original_base := resource.init_base
	resource.init_base = original_base + 777.0
	actual.configure(map.cell_count())
	reference.configure(map.cell_count())
	_expect("reconfigure refreshes profile-derived normalization", _compare_sequence(map, actual, reference, 20261116))
	resource.init_base = original_base
	actual.configure(map.cell_count())
	reference.configure(map.cell_count())
	_expect("restored catalog starts with cleared memory and original rules", actual.rows.is_empty() and _compare_sequence(map, actual, reference, 20261117))
	print("resource visual observation reference: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _compare_sequence(map: MapData, actual, reference, seed_value: int) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var thresholds := [-0.1, 0.0, 0.000001, 0.224, 0.25, 0.275, 0.629, 0.70, 0.77, 1.35, 1.50, 1.65, 4.0]
	var allowed := Catalog.presence_mask(actual.styles)
	for sample in 240:
		var cell := sample % map.cell_count()
		map.visible_arr[cell] = 0 if sample % 7 == 0 else 1
		map.bio_occupancy_bits_arr[cell] = rng.randi_range(0, (1 << 20) - 1)
		map.resource_habitat_mask_arr[cell] = rng.randi_range(0, 0xfff)
		map.temp_arr[cell] = rng.randf_range(-0.25, 1.25)
		map.moisture_arr[cell] = rng.randf_range(-0.25, 1.25)
		for style in actual.styles:
			if style.profile == null:
				continue
			var values := PackedFloat32Array()
			# Include empty and short published columns, preserving fallback 0.
			values.resize(map.cell_count() if sample % 5 != 0 else sample % 4)
			values.fill(float(thresholds[sample % thresholds.size()]) * float(style.reference))
			map.set(style.reserve_field, values)
		var gm := sample % 13 == 0
		var changed: bool = actual.observe(map, cell, allowed, gm)
		if changed != reference.observe(map, cell, allowed, gm) or actual.rows != reference.rows or actual.revision != reference.revision:
			return false
		map.temp_arr[cell] = rng.randf_range(-0.25, 1.25)
		if actual.observe_climate(map, cell, gm) != reference.observe_climate(map, cell, gm) or actual.rows != reference.rows:
			return false
	return true

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[%s] %s" % ["PASS" if condition else "FAIL", label])
