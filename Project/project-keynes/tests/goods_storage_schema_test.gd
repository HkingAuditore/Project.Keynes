extends SceneTree

# goods_storage_schema_test.gd
# 验收物资 GoodProfile + per-cell DataCore storage schema。
#
# Headless:
#   godot --headless --script tests/goods_storage_schema_test.gd --quit

var _checks: int = 0
var _failures: int = 0

const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== goods storage schema test ===")
	_test_profiles_and_schema()
	_test_map_defaults_and_snapshot()
	_test_dcworld_write_and_serialize()
	_test_dcworld_ext_bind_table()
	_test_legacy_missing_fields_deserialize()
	_finish()


func _test_profiles_and_schema() -> void:
	GoodProfileRegistryScript.ensure_loaded()
	var profiles: Array = GoodProfileRegistryScript.ordered()
	_expect("loads 4 GoodProfile resources", profiles.size() == 4)
	_expect("profile_by_id fur works", GoodProfileRegistryScript.profile_by_id(&"fur") != null)
	_expect("profile_by_id grain works", GoodProfileRegistryScript.profile_by_id(&"grain") != null)

	for p in profiles:
		var id: String = String(p.get("id"))
		var qty_field: String = GoodProfileRegistryScript.quantity_map_field(p)
		var price_field: String = GoodProfileRegistryScript.price_map_field(p)
		var qty_cpp: String = GoodProfileRegistryScript.quantity_cpp_name(p)
		var price_cpp: String = GoodProfileRegistryScript.price_cpp_name(p)
		_expect("%s quantity map field exists" % id, qty_field == "goods_%s_qty_arr" % id)
		_expect("%s price map field exists" % id, price_field == "goods_%s_price_arr" % id)
		_expect("%s quantity cpp name exists" % id, qty_cpp == "cell_goods_%s_qty" % id)
		_expect("%s price cpp name exists" % id, price_cpp == "cell_goods_%s_price" % id)
		_expect("%s default price is 1.0" % id, is_equal_approx(float(p.get("default_price")), 1.0))

	var knobs: Dictionary = GoodProfileRegistryScript.build_storage_knobs()
	_expect("storage knobs good_count=4", int(knobs.get("good_count", -1)) == 4)
	_expect("storage knobs quantity slots=4", (knobs.get("quantity_slots", PackedStringArray()) as PackedStringArray).size() == 4)
	_expect("storage knobs price slots=4", (knobs.get("price_slots", PackedStringArray()) as PackedStringArray).size() == 4)


func _test_map_defaults_and_snapshot() -> void:
	var map: MapData = _build_map(5)
	GoodProfileRegistryScript.initialize_map_storage_defaults(map)

	for p in GoodProfileRegistryScript.ordered():
		var id: String = String(p.get("id"))
		var qty_arr: PackedFloat32Array = map.get(GoodProfileRegistryScript.quantity_map_field(p))
		var price_arr: PackedFloat32Array = map.get(GoodProfileRegistryScript.price_map_field(p))
		_expect("%s qty array size=5" % id, qty_arr.size() == 5)
		_expect("%s price array size=5" % id, price_arr.size() == 5)
		_expect("%s qty default 0" % id, _all_f32_equal(qty_arr, 0.0))
		_expect("%s price default 1" % id, _all_f32_equal(price_arr, 1.0))

	map.goods_fur_qty_arr[2] = 3.5
	var nonzero: Array = GoodProfileRegistryScript.cell_goods_snapshot(map, 2, false)
	_expect("snapshot excludes zero goods", nonzero.size() == 1)
	if nonzero.size() == 1:
		_expect("snapshot fur id", String(nonzero[0].get("id", "")) == "fur")
		_expect("snapshot fur quantity", is_equal_approx(float(nonzero[0].get("quantity", 0.0)), 3.5))
		_expect("snapshot fur price", is_equal_approx(float(nonzero[0].get("price", 0.0)), 1.0))
	var all_goods: Array = GoodProfileRegistryScript.cell_goods_snapshot(map, 2, true)
	_expect("snapshot include_zero has all goods", all_goods.size() == 4)


func _test_dcworld_write_and_serialize() -> void:
	var map: MapData = _build_map(5)
	GoodProfileRegistryScript.initialize_map_storage_defaults(map)
	var world: DCWorld = DCWorld.new()
	world.bind_map_data(map)

	var fur = GoodProfileRegistryScript.profile_by_id(&"fur")
	var qty_cid: int = world.component_id(fur.get("quantity_component"))
	var price_cid: int = world.component_id(fur.get("price_component"))
	_expect("fur qty component bound", qty_cid >= 0)
	_expect("fur price component bound", price_cid >= 0)
	world.write_f32_indexed(qty_cid, PackedInt32Array([1, 3]), PackedFloat32Array([2.5, 7.0]))
	world.write_f32_indexed(price_cid, PackedInt32Array([1]), PackedFloat32Array([4.25]))
	_expect("write_f32_indexed qty readback", is_equal_approx(world.read_f32(qty_cid, 3), 7.0))
	_expect("write_f32_indexed price readback", is_equal_approx(world.read_f32(price_cid, 1), 4.25))
	_expect("MapData shares qty slot", is_equal_approx(map.goods_fur_qty_arr[3], 7.0))

	var snap: Dictionary = world.serialize()
	var cells: Dictionary = snap.get("cells", {})
	_expect("serialize includes fur qty", cells.has("cell_goods_fur_qty"))
	_expect("serialize includes fur price", cells.has("cell_goods_fur_price"))
	if cells.has("cell_goods_fur_qty"):
		var qty_saved: PackedFloat32Array = cells["cell_goods_fur_qty"]
		_expect("serialized fur qty value", is_equal_approx(qty_saved[3], 7.0))


func _test_dcworld_ext_bind_table() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return
	var map: MapData = _build_map(3)
	GoodProfileRegistryScript.initialize_map_storage_defaults(map)
	_expect("DCWorldExt bind_map_data succeeds", bool(ext.call("bind_map_data", map)))
	var qty_cid: int = int(ext.call("component_id", &"cell_goods_fur_qty"))
	var price_cid: int = int(ext.call("component_id", &"cell_goods_fur_price"))
	_expect("DCWorldExt fur qty slot bound", qty_cid >= 0)
	_expect("DCWorldExt fur price slot bound", price_cid >= 0)
	if qty_cid < 0 or price_cid < 0:
		return
	var price_snap: PackedFloat32Array = ext.call("snapshot_f32", price_cid)
	_expect("DCWorldExt price snapshot size=3", price_snap.size() == 3)
	_expect("DCWorldExt price default visible", price_snap.size() == 3 and is_equal_approx(price_snap[0], 1.0))
	ext.call("write_f32_indexed", qty_cid, PackedInt32Array([2]), PackedFloat32Array([9.0]))
	_expect("DCWorldExt write_f32_indexed readback", is_equal_approx(float(ext.call("read_f32", qty_cid, 2)), 9.0))


func _test_legacy_missing_fields_deserialize() -> void:
	var map: MapData = _build_map(4)
	GoodProfileRegistryScript.initialize_map_storage_defaults(map)
	var world: DCWorld = DCWorld.new()
	world.bind_map_data(map)

	var fur = GoodProfileRegistryScript.profile_by_id(&"fur")
	var qty_cid: int = world.component_id(fur.get("quantity_component"))
	var price_cid: int = world.component_id(fur.get("price_component"))
	var legacy: Dictionary = world.serialize()
	var cells: Dictionary = legacy.get("cells", {})
	for key in cells.keys():
		if String(key).begins_with("cell_goods_"):
			cells.erase(key)
	legacy["cells"] = cells

	world.deserialize(legacy)
	_expect("legacy missing goods qty keeps default", is_equal_approx(world.read_f32(qty_cid, 0), 0.0))
	_expect("legacy missing goods price keeps default", is_equal_approx(world.read_f32(price_cid, 0), 1.0))


func _build_map(n: int) -> MapData:
	var map := MapData.new(n, 1)
	for i in range(n):
		map.set_cell(HexCell.new(i, 0))
	map.init_soa_from_bake()
	return map


func _all_f32_equal(arr: PackedFloat32Array, value: float) -> bool:
	for v in arr:
		if not is_equal_approx(v, value):
			return false
	return true


func _finish() -> void:
	print("  -> checks=%d  failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== goods storage schema test PASS ===")
	else:
		printerr("=== goods storage schema test FAIL: %d failures ===" % _failures)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)


func _skip(label: String) -> void:
	print("  [SKIP] %s" % label)
