extends SceneTree


func _initialize() -> void:
	var failures := PackedStringArray()
	var view_model := CellInspectorViewModel.new()
	var info_panel := InfoPanelController.new({})
	var cases := [
		[0.00, "极寒"],
		[0.06, "严寒"],
		[0.20, "寒冷"],
		[0.30, "凉爽"],
		[0.40, "温和"],
		[0.55, "温暖"],
		[0.75, "炎热"],
		[0.90, "酷热"],
	]

	for temperature_band_case in cases:
		var sample_temp := float(temperature_band_case[0])
		var expected_band := String(temperature_band_case[1])
		if view_model._temperature_band(sample_temp) != expected_band:
			failures.append("view model mismatch at %.2f" % sample_temp)
		if info_panel._temperature_band(sample_temp) != expected_band:
			failures.append("info panel mismatch at %.2f" % sample_temp)

	if failures.is_empty():
		print("[temperature-band-ui] PASS")
		quit(0)
		return
	for failure in failures:
		push_error("[temperature-band-ui] FAIL: %s" % failure)
	quit(1)
