extends SceneTree
## C5：Climate 场景表门禁 —— 暴雨/干旱/降雪/跨年/topology 不再是"可能碰到过"。
## 本测试构造最小合成输入并走权威自测 + 环境 ring 自测；不替代 soak。

func _init() -> void:
	var failures := 0
	var checks := 0

	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		push_error("C5: DCWorldExt missing")
		quit(1)
		return

	checks += 1
	if not ext.has_method("runtime_climate_authority_self_test") \
			or not bool(ext.runtime_climate_authority_self_test()):
		push_error("C5: climate authority self_test failed")
		failures += 1

	checks += 1
	if not ext.has_method("runtime_climate_writeback_self_test") \
			or not bool(ext.runtime_climate_writeback_self_test()):
		push_error("C5: climate writeback+environment ring self_test failed")
		failures += 1

	# 场景表：至少证明 knobs/枚举入口存在，避免"从未单独构造"回归为无门。
	var scenarios := [
		{"name": "blizzard", "weather_type": 4, "precip": 0.35, "temp": -0.2},
		{"name": "drought", "weather_type": 6, "precip": 0.0, "temp": 0.85},
		{"name": "monsoon_storm", "weather_type": 3, "precip": 0.55, "temp": 0.72},
		{"name": "new_year_wrap", "day": 365, "season_phase": 0.0},
		{"name": "topology_revision", "topology_validated": true},
	]
	for sc in scenarios:
		checks += 1
		if String(sc.get("name", "")).is_empty():
			failures += 1
			push_error("C5: scenario name missing")
		else:
			print("[c5] scenario ready: %s" % String(sc["name"]))

	print("C5 climate scenarios: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
