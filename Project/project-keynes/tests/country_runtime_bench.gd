extends SceneTree

const CELL_COUNT := 100000
const COUNTRY_COUNT := 512
const GOOD_COUNT := 200
const TECHNOLOGY_COUNT := 4096
const ROUNDS := 10

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELL_COUNT)
	ext.register_component(&"cell_country_slot", 1, 1, false)
	var catalog := {
		"good_ids": _ids("good.synthetic.", GOOD_COUNT),
		"technology_ids": _ids("tech.synthetic.", TECHNOLOGY_COUNT),
	}
	var configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"country_max_commands_per_slice": 131072,
	}, CELL_COUNT, 991)
	if not bool(configured.get("ok", false)):
		_fail("configure", configured)
		return
	var water := PackedByteArray()
	water.resize(CELL_COUNT)
	water.fill(0)
	var boot: Dictionary = ext.bootstrap_country({}, water)
	if not bool(boot.get("ok", false)):
		_fail("bootstrap", boot)
		return

	var creates := _empty_batch()
	for slot in range(1, COUNTRY_COUNT):
		creates.opcodes.append(1)
		creates.effective_days.append(0)
		creates.sequences.append(slot)
		creates.target_handles.append(0)
		creates.cell_indices.append(slot)
		creates.aux_i32.append(-1)
		creates.stable_ids.append("country.synthetic.%04d" % slot)
		creates.display_names.append("Synthetic %04d" % slot)
	ext.submit_country_commands(creates)
	var create_report: Dictionary = ext.run_country_slice({"day_index": 0})
	if not bool(create_report.get("ok", false)):
		_fail("create countries", create_report)
		return

	var handles := PackedInt64Array()
	for cell in range(COUNTRY_COUNT):
		handles.append(int(ext.get_country_cell_summary(cell).country_handle))
	var samples := PackedFloat64Array()
	var preflight_samples := PackedFloat64Array()
	var apply_samples := PackedFloat64Array()
	var publish_samples := PackedFloat64Array()
	for round_index in range(ROUNDS):
		var transfers := _empty_batch()
		for cell in range(COUNTRY_COUNT, CELL_COUNT):
			transfers.opcodes.append(3)
			transfers.effective_days.append(round_index + 1)
			transfers.sequences.append(cell)
			transfers.target_handles.append(handles[1 + ((cell + round_index) % (COUNTRY_COUNT - 1))])
			transfers.cell_indices.append(cell)
			transfers.aux_i32.append(-1)
			transfers.stable_ids.append("")
			transfers.display_names.append("")
		ext.submit_country_commands(transfers)
		var report: Dictionary = {}
		for continuation in range(16):
			report = ext.run_country_slice({"day_index": round_index + 1})
			if bool(report.get("done", false)):
				break
		if not bool(report.get("ok", false)):
			_fail("territory round", report)
			return
		samples.append(float(report.get("elapsed_ms", 0.0)))
		preflight_samples.append(float(report.get("command_preflight_ms", 0.0)))
		apply_samples.append(float(report.get("command_apply_ms", 0.0)))
		publish_samples.append(float(report.get("aggregate_publish_ms", 0.0)))
	samples.sort()
	preflight_samples.sort()
	apply_samples.sort()
	publish_samples.sort()
	var p95_index: int = mini(samples.size() - 1, int(ceil(samples.size() * 0.95)) - 1)
	var p95: float = samples[p95_index]
	var memory_bytes := int(ext.get_country_report().get("memory_bytes", 0))
	var idle_start := Time.get_ticks_usec()
	for i in range(10000):
		ext.country_should_run(1000)
	var idle_ms := float(Time.get_ticks_usec() - idle_start) / 1000.0 / 10000.0
	print("country bench cells=%d countries=%d goods=%d tech=%d p95=%.3fms preflight=%.3fms apply=%.3fms publish=%.3fms memory=%.2fMB idle=%.6fms" % [
		CELL_COUNT, COUNTRY_COUNT, GOOD_COUNT, TECHNOLOGY_COUNT, p95,
		preflight_samples[p95_index], apply_samples[p95_index], publish_samples[p95_index],
		float(memory_bytes) / 1048576.0, idle_ms])
	var passed := p95 < 5.0 and memory_bytes < 8 * 1024 * 1024 and idle_ms < 0.05
	quit(0 if passed else 1)

func _ids(prefix: String, count: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(count):
		out.append("%s%04d" % [prefix, i])
	return out

func _empty_batch() -> Dictionary:
	return {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(),
		"aux_i32": PackedInt32Array(),
		"stable_ids": PackedStringArray(),
		"display_names": PackedStringArray(),
	}

func _fail(stage: String, report: Dictionary) -> void:
	push_error("country bench %s failed: %s" % [stage, report])
	quit(1)
