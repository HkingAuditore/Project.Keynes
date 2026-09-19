extends SceneTree

# B8 P0 contracts.
#
# 1. Canonical Climate stage order: the worker kernel's declared/actual order and
#    the production native-daily graph order are the same contract. Before this,
#    a one-sided reorder only showed up as a numerical divergence weeks later.
# 2. Field-writer ledger: every parity field must declare its production writer
#    and the main-thread path that has to be suppressed once the worker owns the
#    domain. The parity table stays the single definition of the field set; the
#    ledger is checked against it so it cannot silently go stale.

const LEDGER_PATH := "tools/runtime/climate_field_ownership.json"
const FIELD_POLICY_PATH := "tools/runtime/authority-stage-c-field-policy.json"

# 无条件执行链的顺序锚点。数组顺序就是要求的下标顺序。
const ORDER_ANCHORS: Array[String] = [
	"climate_pass_a", "climate_pass_b", "ocean_water", "ocean_land",
	"wind_air", "wind_surface", "sea_ice", "transpiration",
	"weather_field", "weather_commit", "weather_distribute",
	"weather_summary", "weather_cyclone", "runtime_hydrology",
	"stage_b_after_hydrology",
]

const REQUIRED_CONDITIONAL_HOSTS: Array[String] = [
	"weather_stage_b",
]

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("checks: %d, failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("runtime climate stage order contract: PASS")
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % label)


func _repo_path(relative: String) -> String:
	var project_root := ProjectSettings.globalize_path("res://").path_join("../..")
	return project_root.simplify_path().path_join(relative)


func _load_json(relative: String) -> Dictionary:
	var path := _repo_path(relative)
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		_expect("readable JSON: %s" % relative, false)
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_expect("parseable JSON object: %s" % relative, false)
		return {}
	return parsed


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available", false)
		return
	var ext := DCWorldExt.new()
	_check_stage_order(ext)
	_check_ownership_ledger(ext)
	_check_wait_api(ext)


func _check_stage_order(ext: Object) -> void:
	print("=== climate stage order contract ===")
	_expect("runtime_climate_stage_order_contract_test is exported",
		ext.has_method("runtime_climate_stage_order_contract_test"))
	if not ext.has_method("runtime_climate_stage_order_contract_test"):
		return
	var report: Dictionary = ext.runtime_climate_stage_order_contract_test()
	var code := String(report.get("code", ""))
	_expect("stage order contract passes (%s)" % code,
		bool(report.get("ok", false)))
	if not bool(report.get("ok", false)):
		return

	var canonical := String(report.get("canonical_order", ""))
	var names := canonical.split(">", false)
	_expect("canonical order has one entry per real stage (%d)" % names.size(),
		names.size() == 14)
	_expect("canonical order starts with the round",
		names.size() > 0 and names[0] == "PASS_A")
	_expect("canonical order ends with the fallback tail",
		names.size() > 0 and names[names.size() - 1] == "STAGE_B_AFTER_HYDROLOGY")
	# B8-1 的核心断言：stage_b 三段必须排在 WEATHER 之后。
	var weather_index := names.find("WEATHER")
	var albedo_index := names.find("ALBEDO")
	var vegetation_index := names.find("VEGETATION_DYNAMICS")
	var feedback_index := names.find("CLIMATE_FEEDBACK")
	_expect("WEATHER is in the canonical order", weather_index >= 0)
	_expect("stage_b albedo runs after WEATHER",
		weather_index >= 0 and albedo_index > weather_index)
	_expect("stage_b vegetation runs after albedo",
		albedo_index >= 0 and vegetation_index > albedo_index)
	_expect("stage_b feedback runs after vegetation",
		vegetation_index >= 0 and feedback_index > vegetation_index)

	var positions: Dictionary = report.get("graph_positions", {})
	var previous := -1
	for anchor in ORDER_ANCHORS:
		_expect("production graph exposes %s" % anchor, positions.has(anchor))
		if not positions.has(anchor):
			continue
		var index := int(positions[anchor])
		_expect("production node %s has a valid index" % anchor, index >= 0)
		_expect("production order keeps %s after its predecessor" % anchor,
			index > previous)
		previous = index

	var conditional: Dictionary = report.get("conditional_early_hosts", {})
	for host in REQUIRED_CONDITIONAL_HOSTS:
		_expect("conditional early host %s is reported" % host,
			conditional.has(host))

	# 每个 canonical stage 都要能映射到宿主节点（或明确报告 -1）。
	var hosts: Array = report.get("stage_hosts", [])
	_expect("stage_hosts covers every canonical stage (%d)" % hosts.size(),
		hosts.size() == names.size() - 1)
	var seen_stages := {}
	for row in hosts:
		var stage_name := String(row.get("stage", ""))
		_expect("stage host row carries a stage name", stage_name != "")
		_expect("stage host row %s is unique" % stage_name,
			not seen_stages.has(stage_name))
		seen_stages[stage_name] = true
	print("canonical: %s" % canonical)


func _check_ownership_ledger(ext: Object) -> void:
	print("=== climate field ownership ledger ===")
	var ledger := _load_json(LEDGER_PATH)
	if ledger.is_empty():
		return
	_expect("ledger schema is ClimateFieldOwnershipLedger",
		String(ledger.get("schema", "")) == "ClimateFieldOwnershipLedger")
	_expect("ledger schema_version is 1",
		int(ledger.get("schema_version", 0)) == 1)
	var allowed_writers: Array = ledger.get("allowed_active_writers", [])
	var allowed_suppression: Array = ledger.get("allowed_suppression", [])
	_expect("ledger declares allowed writers", allowed_writers.size() > 0)
	_expect("ledger declares allowed suppression tokens",
		allowed_suppression.size() > 0)

	if not ext.has_method("get_runtime_climate_parity_fields"):
		_expect("get_runtime_climate_parity_fields is exported", false)
		return
	var fields: Dictionary = ledger.get("fields", {})
	var table: Array = ext.get_runtime_climate_parity_fields()
	var table_names := {}
	for entry in table:
		var name := String(entry.get("name", ""))
		table_names[name] = true
		_expect("parity field %s has a ledger entry" % name, fields.has(name))
		if not fields.has(name):
			continue
		var row: Dictionary = fields[name]
		_expect("ledger %s records the parity stage" % name,
			String(row.get("parity_stage", "")) == String(entry.get("stage_name", "")))
		_expect("ledger %s records the element kind" % name,
			String(row.get("kind", "")) == String(entry.get("kind", "")))
		_expect("ledger %s records comparability" % name,
			String(row.get("comparability", "")) ==
				String(entry.get("comparability", "")))
		_expect("ledger %s records the MapData array" % name,
			String(row.get("map_data_array", "")) ==
				String(entry.get("map_data_array", "")))
		var writer := String(row.get("active_writer", ""))
		_expect("ledger %s uses an allowed writer (%s)" % [name, writer],
			allowed_writers.has(writer))
		_expect("ledger %s records worker ownership" % name,
			row.has("worker_owned"))
		var suppression: Array = row.get("suppression", [])
		_expect("ledger %s records a suppression list" % name,
			suppression.size() > 0)
		for token in suppression:
			_expect("ledger %s suppression token %s is allowed" % [name, token],
				allowed_suppression.has(String(token)))
		if String(entry.get("comparability", "")) == "comparable":
			_expect("comparable field %s declares map write-back" % name,
				bool(row.get("writeback", false)))
	for name in fields.keys():
		_expect("ledger entry %s still exists in the parity table" % name,
			table_names.has(String(name)))

	# 尚未迁移的字段必须与 C2 field policy 对得上，防止"待办"两处各写一份。
	var policy := _load_json(FIELD_POLICY_PATH)
	var policy_fields: Dictionary = policy.get("fields", {})
	var extras: Dictionary = ledger.get("extra_policy_fields", {})
	for name in extras.keys():
		_expect("extra policy field %s exists in authority-stage-c-field-policy" % name,
			policy_fields.has(String(name)))
		var row: Dictionary = extras[name]
		_expect("extra policy field %s records a target phase" % name,
			String(row.get("target_phase", "")) != "")
	print("ledger fields: %d parity + %d extra" % [fields.size(), extras.size()])


func _check_wait_api(ext: Object) -> void:
	# B8 P3：等待接口必须存在，且在"没有 worker"这种终止条件下立刻返回一个带
	# code 的失败，而不是挂住主线程。真正的无限等在 world_runtime_host 的循环里，
	# 这里只锁住"不会静默阻塞"这条契约。
	print("=== climate wait api contract ===")
	_expect("wait_climate_consumed is exported",
		ext.has_method("wait_climate_consumed"))
	if not ext.has_method("wait_climate_consumed"):
		return
	var no_worker: Dictionary = ext.wait_climate_consumed(1, 0)
	_expect("wait without a worker returns ok=false",
		not bool(no_worker.get("ok", true)))
	_expect("wait without a worker names a terminal code",
		String(no_worker.get("code", "")) in [
			"runtime_worker_not_started", "climate_wait_worker_stopped",
			"climate_wait_worker_faulted", "climate_wait_authority_revoked",
		])
	_expect("wait without a worker reports the consumed cursor",
		no_worker.has("consumed_generation"))
