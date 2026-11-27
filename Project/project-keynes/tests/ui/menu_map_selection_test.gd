extends SceneTree

## 选择不兼容的地图后，开始按钮不能再提交上一次成功读取的地图。
const MapFile := preload("res://scripts/geography/pkmap_io.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := "user://menu_map_selection_%d.pkmap" % OS.get_process_id()
	var written := MapFile.write_pkmap(path, {"width": 20, "height": 16, "n_cells": 320, "seed": 42}, {})
	if not written.ok:
		quit(1)
		return
	change_scene_to_file("res://scenes/main_menu.tscn")
	await scene_changed
	var menu := current_scene
	menu.call("_show_new_game")
	var source := menu.get_node("%MapSourceOption") as OptionButton
	source.select(1)
	source.item_selected.emit(1)
	menu.call("_apply_pkmap_path", path)
	var accepted: bool = menu.get("_pkmap_path") == path and "20 × 16" in menu.get_node("%PkmapMetaLabel").text

	var header: Dictionary = written.header.duplicate()
	header.generator_hash = "obsolete"
	var header_bytes := JSON.stringify(header).to_utf8_buffer()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(MapFile.PKMAP_MAGIC.to_ascii_buffer())
	file.store_32(MapFile.FORMAT_VERSION)
	file.store_32(header_bytes.size())
	file.store_buffer(header_bytes)
	file.close()
	menu.call("_apply_pkmap_path", path)
	var refused: bool = menu.get("_pkmap_path") == "" and "不兼容" in menu.get_node("%PkmapMetaLabel").text
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("[menu-map-selection] compatible=", accepted, " refused_replacement=", refused)
	quit(0 if accepted and refused else 1)
