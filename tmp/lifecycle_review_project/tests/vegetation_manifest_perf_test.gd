extends SceneTree

const PerfRecorderScript := preload("res://scripts/ui/perf_recorder.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var native_ext: Object = ClassDB.instantiate("DCWorldExt") \
		if ClassDB.class_exists("DCWorldExt") else null
	_expect("native family-cell encoder is present in the loaded GDExtension",
		native_ext != null and native_ext.has_method("encode_detail_scatter_family_cells"))
	if native_ext != null and native_ext.has_method("encode_detail_scatter_family_cells"):
		var empty_report = native_ext.call("encode_detail_scatter_family_cells", {"requests": []})
		_expect("native family-cell encoder returns the tagged batch contract",
			empty_report is Dictionary
			and str(empty_report.get("path", "")) == "gdext_family_cells"
			and int(empty_report.get("request_count", -1)) == 0)

	var manifest = load("res://data/visual/world_decoration_manifest.tres")
	var layers: Array = manifest.valid_layers() if manifest != null else []
	_expect("default manifest has exactly 20 profiles", layers.size() == 20)
	var has_seagrass := false
	var family_counts := {}
	for profile in layers:
		if profile != null and str(profile.resource_path).contains("seagrass"):
			has_seagrass = true
		if profile != null and profile.has_method("resolved_render_family"):
			var family := int(profile.resolved_render_family())
			family_counts[family] = int(family_counts.get(family, 0)) + 1
	_expect("default manifest excludes seagrass rendering profile", not has_seagrass)
	_expect("20 profiles map to the five declared render families",
		int(family_counts.get(1, 0)) == 4
		and int(family_counts.get(2, 0)) == 4
		and int(family_counts.get(3, 0)) == 6
		and int(family_counts.get(4, 0)) == 4
		and int(family_counts.get(5, 0)) == 2)

	var recorder = PerfRecorderScript.new()
	var row := {"tick_idx": 9}
	var lut := PackedByteArray([1, 2, 3, 4])
	recorder._merge_breakdowns(row, {
		"atlas": {
			"_tick_idx": 9,
			"weather_lut": lut,
			"lut_refresh_ms": 0.75,
			"lut_path": "native",
		}
	})
	_expect("LUT payload is replaced by scalar size/hash/version summary",
		not row.has("bd_atlas_weather_lut")
		and int(row.get("bd_atlas_weather_lut_size", -1)) == 4
		and row.has("bd_atlas_weather_lut_hash")
		and int(row.get("bd_atlas_weather_lut_summary_version", 0)) == 1)
	_expect("LUT scalar diagnostics remain intact",
		is_equal_approx(float(row.get("bd_atlas_lut_refresh_ms", 0.0)), 0.75)
		and str(row.get("bd_atlas_lut_path", "")) == "native")
	print("=== vegetation manifest/perf: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
