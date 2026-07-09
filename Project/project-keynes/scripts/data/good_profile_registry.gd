# good_profile_registry.gd
# Single-point accessor for all GoodProfile definitions.
#
# 顺序即权威：`_PROFILE_PATHS` 的下标是未来经济 C++ pass 的物资索引。
# 本文件只提供数据层访问、默认库存/价格初始化和冷路径 snapshot。

class_name GoodProfileRegistry

const _GoodProfileScript = preload("res://scripts/data/good_profile.gd")

const _PROFILE_PATHS: Array = [
	"res://data/goods/fur.tres",
	"res://data/goods/mutton.tres",
	"res://data/goods/coal.tres",
	"res://data/goods/grain.tres",
]

static var _ordered: Array = [] # Array[GoodProfile]
static var _by_id: Dictionary = {}
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_ordered.clear()
	_by_id.clear()
	for path in _PROFILE_PATHS:
		var res = ResourceLoader.load(path, "Resource")
		if res == null:
			push_warning("GoodProfileRegistry: failed to load %s" % path)
			continue
		var id_value := StringName(String(res.get("id")))
		if String(id_value) == "":
			push_warning("GoodProfileRegistry: %s has empty id; skipped" % path)
			continue
		_ordered.append(res)
		_by_id[id_value] = res


static func ordered() -> Array:
	ensure_loaded()
	return _ordered


static func count() -> int:
	ensure_loaded()
	return _ordered.size()


static func profile_by_id(id_value):
	ensure_loaded()
	var id_key := StringName(String(id_value))
	return _by_id.get(id_key, null)


static func quantity_map_field(p) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.get("quantity_component"))
	return String(e.get("map_field", "")) if not e.is_empty() else ""


static func price_map_field(p) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.get("price_component"))
	return String(e.get("map_field", "")) if not e.is_empty() else ""


static func quantity_cpp_name(p) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.get("quantity_component"))
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


static func price_cpp_name(p) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.get("price_component"))
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


static func build_storage_knobs() -> Dictionary:
	ensure_loaded()
	var quantity_slots := PackedStringArray()
	var price_slots := PackedStringArray()
	var default_prices := PackedFloat32Array()
	var ids := PackedStringArray()
	for p in _ordered:
		var qty_cpp: String = quantity_cpp_name(p)
		var price_cpp: String = price_cpp_name(p)
		if qty_cpp == "" or price_cpp == "":
			push_warning("GoodProfileRegistry: good '%s' has incomplete schema entry; skipped" % String(p.get("id")))
			continue
		ids.append(String(p.get("id")))
		quantity_slots.append(qty_cpp)
		price_slots.append(price_cpp)
		default_prices.append(float(p.get("default_price")))
	return {
		"good_count": quantity_slots.size(),
		"ids": ids,
		"quantity_slots": quantity_slots,
		"price_slots": price_slots,
		"default_prices": default_prices,
	}


static func initialize_map_storage_defaults(map_ref) -> void:
	if map_ref == null:
		return
	ensure_loaded()
	var n: int = map_ref.cell_count() if map_ref.has_method("cell_count") else 0
	for p in _ordered:
		var qty_field: String = quantity_map_field(p)
		var price_field: String = price_map_field(p)
		if qty_field != "":
			var qty_arr: PackedFloat32Array = _get_f32_array(map_ref, qty_field)
			if qty_arr.size() != n:
				qty_arr.resize(n)
			qty_arr.fill(0.0)
			map_ref.set(qty_field, qty_arr)
		if price_field != "":
			var price_arr: PackedFloat32Array = _get_f32_array(map_ref, price_field)
			if price_arr.size() != n:
				price_arr.resize(n)
			price_arr.fill(float(p.get("default_price")))
			map_ref.set(price_field, price_arr)


static func cell_goods_snapshot(map_ref, cell_idx: int, include_zero: bool = false) -> Array:
	var out: Array = []
	if map_ref == null or cell_idx < 0:
		return out
	var n: int = map_ref.cell_count() if map_ref.has_method("cell_count") else 0
	if cell_idx >= n:
		return out
	ensure_loaded()
	for p in _ordered:
		var qty_arr: PackedFloat32Array = _get_f32_array(map_ref, quantity_map_field(p))
		var price_arr: PackedFloat32Array = _get_f32_array(map_ref, price_map_field(p))
		var qty: float = qty_arr[cell_idx] if cell_idx < qty_arr.size() else 0.0
		if not include_zero and is_equal_approx(qty, 0.0):
			continue
		var price: float = price_arr[cell_idx] if cell_idx < price_arr.size() else float(p.get("default_price"))
		out.append({
			"id": p.get("id"),
			"display_name": p.get("display_name"),
			"icon": p.get("icon"),
			"quantity": qty,
			"price": price,
		})
	return out


static func _get_f32_array(map_ref, field: String) -> PackedFloat32Array:
	if field == "" or map_ref == null:
		return PackedFloat32Array()
	var v: Variant = map_ref.get(field)
	return v if v is PackedFloat32Array else PackedFloat32Array()
