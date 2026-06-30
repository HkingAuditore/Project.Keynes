extends SceneTree

# 校验 InfoPanelController.refresh_resource_lines 的读取/格式化路径：
#   registry.ordered() → reserve_map_field → MapData.res_*_reserve_arr[idx] → 文本
# 不依赖完整场景：手搭一个最小 VBox + history Label + HexCell + MapData。

const InfoPanelControllerScript = preload("res://scripts/ui/info_panel_controller.gd")


func _initialize() -> void:
	var failures := PackedStringArray()

	# ── 最小 UI 容器：vbox 作为 history 的父节点，供懒创建 _resource_label 挂载
	var root := Node.new()
	get_root().add_child(root)
	var vbox := VBoxContainer.new()
	root.add_child(vbox)
	var history := Label.new()
	vbox.add_child(history)

	# ── 最小 MapData（1 cell 陆地），手种储量
	var map := MapData.new(1, 1)
	map.res_biomass_reserve_arr.resize(1)
	map.res_iron_ore_reserve_arr.resize(1)
	map.res_biomass_reserve_arr[0] = 0.42
	map.res_iron_ore_reserve_arr[0] = 0.20

	# ── 陆地 cell（landform = 平原），index 0
	var cell := HexCell.new(0, 0)
	cell.index = 0
	cell.landform = LandformType.LF.PLAIN

	var ctrl = InfoPanelControllerScript.new({ "history": history })
	ctrl.set_current_map(map)
	ctrl.set_selected_cell(cell)
	ctrl.set_view_adapter(null)
	ctrl.refresh_resource_lines()

	var label = ctrl._resource_label
	if label == null:
		failures.append("resource label was not created")
	else:
		var txt: String = label.text
		print("[panel-res] label.text =\n%s" % txt)
		if not txt.contains("自然资源储量"):
			failures.append("missing header 自然资源储量")
		# biomass: land_only renewable, expect 储量百分比可见
		if not txt.contains("0.420"):
			failures.append("missing biomass reserve 0.420 (got: %s)" % txt)
		if not txt.contains("0.200"):
			failures.append("missing iron reserve 0.200 (got: %s)" % txt)
		# 数据驱动顺序应至少含 2 种资源（biomass + iron）
		var profiles: Array = ResourceProfileRegistry.ordered()
		for p in profiles:
			var name_cn: String = String(p.display_name) if String(p.display_name) != "" else String(p.id)
			if not txt.contains(name_cn):
				failures.append("missing resource name '%s'" % name_cn)

	# ── 水域 cell：land_only 资源应显示"水域不可用"，而非 0%
	var water_cell := HexCell.new(0, 0)
	water_cell.index = 0
	water_cell.landform = LandformType.LF.OCEAN
	ctrl.set_selected_cell(water_cell)
	ctrl.refresh_resource_lines()
	var wtxt: String = ctrl._resource_label.text
	print("[panel-res] water label.text =\n%s" % wtxt)
	if not wtxt.contains("水域不可用"):
		# 仅当存在 land_only 资源时才要求；biomass 即 land_only
		failures.append("water cell should mark land_only resource unavailable (got: %s)" % wtxt)

	if failures.is_empty():
		print("[panel-res] PASS — resource lines read path OK")
		quit(0)
	else:
		for f in failures:
			push_error("[panel-res] FAIL: %s" % f)
			print("[panel-res] FAIL: %s" % f)
		quit(1)
