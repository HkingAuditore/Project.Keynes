# 临时探针：读用户 autosave.pksv，对比"检查器植被(facade)" vs "散布层植被(vegetation_arr)"。
extends SceneTree

const TARGET_CELL := 1516

func _init() -> void:
	var repo := SaveRepository.new()
	var res: Dictionary = repo.load_slot("autosave")
	if not bool(res.get("ok", false)):
		print("[SAVEPROBE] load failed")
		quit(1)
		return
	var sections: Dictionary = res.get("section_bytes", {})

	# 1) 玩家视角与新游戏配置
	var pv = bytes_to_var(sections.get("player_view", PackedByteArray()))
	print("[SAVEPROBE] player_view=%s" % str(pv))
	var ngc = bytes_to_var(sections.get("new_game_config", PackedByteArray()))
	if ngc is Dictionary:
		print("[SAVEPROBE] new_game_config.base=%s" % str((ngc as Dictionary).get("base", {})))

	# 2) environment 段结构（找 SoA 数组）
	var env = bytes_to_var(sections.get("environment", PackedByteArray()))
	if env is Dictionary:
		var arr_keys := []
		for k in (env as Dictionary).keys():
			var v = (env as Dictionary)[k]
			if v is PackedByteArray or v is PackedFloat32Array or v is PackedInt32Array:
				arr_keys.append("%s:%s(%d)" % [k, type_string(typeof(v)).left(12), (v as Array).size() if v is Array else (v as PackedByteArray).size() if v is PackedByteArray else (v as PackedFloat32Array).size() if v is PackedFloat32Array else (v as PackedInt32Array).size()])
		print("[SAVEPROBE] env arrays (%d):" % arr_keys.size())
		for line in arr_keys:
			print("    %s" % line)

	# 3) dynamic_world.cells 结构
	var dw = bytes_to_var(sections.get("dynamic_world", PackedByteArray()))
	if dw is Dictionary:
		var cells = (dw as Dictionary).get("cells", [])
		print("[SAVEPROBE] dynamic_world n_cells=%s cells_type=%s" % [
			str((dw as Dictionary).get("n_cells", "?")), type_string(typeof(cells))])
		if cells is Array and not (cells as Array).is_empty():
			var c0 = (cells as Array)[0]
			print("[SAVEPROBE] cell[0] type=%s value=%s" % [type_string(typeof(c0)), str(c0).left(400)])
			if TARGET_CELL < (cells as Array).size():
				print("[SAVEPROBE] cell[1516]=%s" % str((cells as Array)[TARGET_CELL]).left(600))
	quit(0)
