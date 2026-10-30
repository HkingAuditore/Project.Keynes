@tool
extends EditorPlugin

class CatalogExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "LoadingCatalogPrebake"

	func _export_begin(_features: PackedStringArray,_debug: bool,_path: String,_flags: int) -> void:
		var baker = load("res://tools/loading_catalog_bake.gd")
		var err: Error = baker.bake()
		if err != OK:
			push_error("Loading catalog export bake failed: "+error_string(err))
			# Force source compilation if an export proceeds after a bake error.
			add_file("res://data/loading_catalog_v1/sources.json", "{}".to_utf8_buffer(),false)
			return
		for filename in ["economy.res","effect.res","effect_extensions.res","display.res","technology.res","research.res","sources.json"]:
			var path: String = "res://data/loading_catalog_v1/"+str(filename)
			add_file(path,FileAccess.get_file_as_bytes(path),false)

var _catalog_export: CatalogExport

func _enter_tree() -> void:
	_catalog_export=CatalogExport.new()
	add_export_plugin(_catalog_export)
	if OS.get_environment("PK_PREBAKE_DIAG") == "1":
		var baker = load("res://tools/loading_catalog_bake.gd")
		baker.call_deferred("diagnose")

func _exit_tree() -> void:
	remove_export_plugin(_catalog_export)
