extends SceneTree

class MockFacade:
	extends RefCounted
	var revision := 1

	func named_settlement_snapshot() -> Dictionary:
		return {
			"ok": true,
			"revision": revision,
			"full_snapshot": true,
			"cell_indices": PackedInt32Array([0, 1]),
			"prosperity_tiers": PackedByteArray([5, 2]),
			"name_active": PackedByteArray([1, 1]),
			"settlement_names": PackedStringArray(["临江市", "青禾村"]),
		}

	func settlement_delta(_since_revision: int) -> Dictionary:
		revision += 1
		return {
			"ok": true,
			"revision": revision,
			"full_snapshot": false,
			"cell_indices": PackedInt32Array([0]),
			"prosperity_tiers": PackedByteArray([1]),
			"name_active": PackedByteArray([0]),
			"settlement_names": PackedStringArray([""]),
		}


var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var map := MapData.new(2, 1)
	map.set_cell(HexCell.new(0, 0))
	map.set_cell(HexCell.new(1, 0))
	map._build_indices()
	map.visible_arr = PackedByteArray([1, 1])
	var holder := Node2D.new()
	root.add_child(holder)
	var camera := Camera2D.new()
	holder.add_child(camera)
	camera.zoom = Vector2(0.4, 0.4)
	var facade := MockFacade.new()
	var layer := SettlementLabelLayer.new()
	holder.add_child(layer)
	layer.configure(map, camera, facade, 22.0,
		HexUtils.wrap_period_x(map.width, 22.0), false)
	layer._rebuild_visible_labels()
	_expect("远景只显示城市以上", _visible_count(layer) == 1 and
		layer._pool[0].text == "临江市")
	_expect("桌面标签池上限为 128", layer._pool.size() == 128)
	camera.zoom = Vector2(1.2, 1.2)
	layer._rebuild_visible_labels()
	_expect("屏幕碰撞稳定剔除重叠标签", _visible_count(layer) == 1)
	map.visible_arr[0] = 0
	layer.set_fog_enabled(true)
	layer.mark_visibility_dirty()
	layer._rebuild_visible_labels()
	_expect("迷雾只隐藏当前不可见聚居地",
		_visible_count(layer) == 1 and layer._pool[0].text == "青禾村")
	layer.sync_from_runtime()
	_expect("增量可释放地名", not layer._settlements.has(0) and
		layer._settlements.has(1))
	print("=== settlement label layer %s: checks=%d failures=%d ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)


func _visible_count(layer: SettlementLabelLayer) -> int:
	var count := 0
	for label in layer._pool:
		if label.visible:
			count += 1
	return count


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
