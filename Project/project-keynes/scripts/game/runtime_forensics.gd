extends RefCounted

## 调用方一律用 preload 引用本文件，不要依赖 class_name 全局注册：新脚本在编辑器
## 重新扫描之前不在 global_script_class_cache 里，无头跑测试会整片 Parse Error。

## 运行时事故现场取证。
##
## 一次 fatal 或一次卡死，玩家和 AI 能拿到的全部证据就是这里写出来的文件。
## 过去只有 money_conservation_failed 会落盘，而且字段集是钱专用的，所以任何
## 别的停机原因都只会看到一份钱的报表 —— 真正的 stage、命令、边界状态全都不在
## 里面。这个模块把"抓现场"和"谁触发"解耦：fatal 和 watchdog 用同一份取证。
##
## 落盘位置：
##   user://diagnostics/<tag>_<时间戳>.json   逐次留存
##   <repo>/tmp/runtime_forensics_<tag>.json  最新一次，方便 agent 直接读
##
## 两份内容相同。tmp 那份固定文件名，因为 AI 工具链按固定路径读取。

const REPO_TMP_RELATIVE := "..\\..\\tmp"
const DIAGNOSTICS_DIR := "user://diagnostics"

## 经济守恒三项在 epoch 半开时没有意义。C++ 侧已经把它们清零并给出
## audit_incomplete，这里保留键名是为了让旧的分析脚本不至于 KeyError。
const ECONOMY_CONSERVATION_KEYS := [
	"population_error", "money_error", "goods_error",
	"audit_incomplete", "audit_incomplete_reason",
	"money_open", "money_close", "money_expected",
	"explicit_money_mint", "explicit_money_burn",
	"opening_cohort_funds", "closing_cohort_funds",
	"opening_country_cash", "closing_country_cash",
	"opening_escrow_cash", "closing_escrow_cash",
	"opening_expedition_funds", "closing_expedition_funds",
	"producer_support_money_issued", "bullion_money_issued",
	"closing_audit_mode", "closing_audit_incremental_this_epoch",
	"closing_audit_runtime_disabled", "closing_audit_mismatches",
	"closing_audit_mismatch_ledger", "closing_audit_mismatch_lane",
	"closing_audit_full_verifications", "closing_audit_fast_paths",
	"incremental_closing_population", "incremental_closing_cohort_funds",
	"incremental_closing_country_cash", "incremental_closing_escrow_cash",
	"incremental_closing_goods_stock", "incremental_closing_country_goods",
	"incremental_closing_transit_goods", "incremental_closing_expedition_goods",
	"opening_audit_fast_paths", "opening_audit_full_verifications",
	"opening_goods_stock", "closing_goods_stock",
	"opening_country_goods", "closing_country_goods",
	"opening_expedition_goods", "closing_expedition_goods",
	"opening_transit_goods", "closing_transit_goods",
	"explicit_stock_delta", "production_output_stock",
	"production_output_discarded", "production_output_retained",
	"consumed_goods", "owner_output_consumed",
	"construction_goods_consumed", "production_inputs_consumed",
	"maintenance_goods_consumed", "cycle_flow_discarded",
	"bullion_stock_consumed", "country_research_goods_consumed",
	"goods_expected", "saturation_count",
	"goods_audit_candidate_lanes",
	"money_audit_candidate_accounts",
]

## 定位一次停机真正需要的东西：哪个 stage、哪条命令、哪些边界开着。
const ECONOMY_SCENE_KEYS := [
	"fatal", "fatal_reason", "fatal_context",
	"stage", "executed_stage", "executed_substage",
	"epoch_active", "epoch_id", "current_day",
	"last_completed_sample_day", "sample_day", "newest_state_day",
	"pending_input", "yield_reason",
	"fiscal_reservation_continuation_active",
	"fiscal_reservation_continuation_phase",
	"fiscal_reservation_last_error",
	"country_research_procurement_continuation_phase",
	"country_research_procurement_last_error",
	"epoch_begin_post_fiscal_pending", "epoch_begin_pending_day",
]

const COUNTRY_SCENE_KEYS := [
	"bootstrapped", "authority_owner", "worker_authoritative",
	"plan_active", "waiting_for_peer", "pending_intents",
	"session_epoch", "generation", "fault", "fault_reason",
	"day", "last_committed_day", "state_hash",
]

const RUNTIME_THREAD_KEYS := [
	"simulation_host_state", "state", "fault_code", "worker_fault_count",
	"authoritative_domain_mask", "requested_authority_mask",
	"climate_worker_authoritative", "country_worker_authoritative",
	"simulation_committed_day", "committed_day", "climate_committed_day",
	"generation", "state_hash",
	"economy_authority_fault_paused",
	"economy_authority_last_committed_generation",
	# 请求了权威却没授予时，答案在这几个阻塞原因里。
	"simulation_worker_blocker", "simulation_worker_ready", "coverage_blocker",
	"active_gate_blocked", "completion_gate_missing_domain_mask",
	"missing_domain_mask", "economy_pod_active_ready", "economy_stage_ops_prelude_ready",
	"economy_yield_reason", "economy_stage_name", "economy_substage_name",
	"economy_input_requested_day", "environment_ring_pending",
	"day_stall_reason_mask", "day_stall_day", "day_stall_peer_ms",
	"country_worker_plan_active", "country_worker_waiting_for_peer",
	# ACTIVE Events 拒绝一个包时整天重试，环满后表现为 climate capacity 卡死。
	"events_pod_ready", "events_pod_fallback_reason",
	"events_pod_event_count", "events_pod_ack_count",
	"events_pod_rejected_count", "events_failed_day",
]


## 抓一次现场。generator 可以为 null（世界还没就绪时也要能落盘）。
static func capture(reason: String, generator, clock,
		extra: Dictionary = {}) -> Dictionary:
	var payload := {
		"reason": reason,
		"captured_at": Time.get_datetime_string_from_system(),
		"engine": {
			"debug_build": OS.is_debug_build(),
			"headless": DisplayServer.get_name() == "headless",
			"process_frames": Engine.get_process_frames(),
		},
	}
	if not extra.is_empty():
		payload["context"] = extra.duplicate(true)
	if clock != null:
		payload["clock"] = {
			"day_index": clock.day_index(),
			"paused": clock.paused,
			"speed_multiplier": clock.speed_multiplier,
		}
	if generator == null:
		return payload
	var economy := _report(generator, "get_economy_report")
	payload["economy"] = _pick(economy, ECONOMY_SCENE_KEYS)
	payload["economy_conservation"] = _pick(economy, ECONOMY_CONSERVATION_KEYS)
	payload["country"] = _pick(_report(generator, "get_country_report"),
		COUNTRY_SCENE_KEYS)
	# 权威 mask 和 worker 状态只在 thread report 里，而"哪个域是 ACTIVE"恰恰
	# 决定了跨域 fast path 走不走 —— 没有它就无法判断一次边界拒绝是否合理。
	payload["runtime_thread"] = _pick(
		_report(generator, "get_runtime_thread_report"), RUNTIME_THREAD_KEYS)
	return payload


## 落盘并打印单行标记。返回 tmp 下那份的绝对路径（失败时返回空串）。
static func dump(payload: Dictionary, tag: String) -> String:
	var text := JSON.stringify(payload)
	print("[runtime-forensics/%s] %s" % [tag, text])
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(DIAGNOSTICS_DIR))
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace(
		"-", "").replace("T", "_") + "_%d" % Time.get_ticks_usec()
	var user_file := FileAccess.open(
		"%s/%s_%s.json" % [DIAGNOSTICS_DIR, tag, stamp], FileAccess.WRITE)
	if user_file != null:
		user_file.store_string(text)
		user_file.close()
	var abs_path := ProjectSettings.globalize_path("res://").path_join(
		"%s\\runtime_forensics_%s.json" % [REPO_TMP_RELATIVE, tag]).simplify_path()
	var abs_file := FileAccess.open(abs_path, FileAccess.WRITE)
	if abs_file == null:
		return ""
	abs_file.store_string(text)
	abs_file.close()
	print("[runtime-forensics/%s] wrote %s" % [tag, abs_path])
	return abs_path


static func capture_and_dump(reason: String, generator, clock, tag: String,
		extra: Dictionary = {}) -> String:
	var payload := capture(reason, generator, clock, extra)
	if tag == "economy_fatal":
		payload["economic_snapshots"] = _dump_economic_snapshots(generator,
			payload, tag)
	return dump(payload, tag)


static func _dump_economic_snapshots(generator, payload: Dictionary,
		tag: String) -> Dictionary:
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace(
		"-", "").replace("T", "_")
	var root := ProjectSettings.globalize_path("res://").path_join(
		"%s\\runtime_snapshots_%s_%s" % [REPO_TMP_RELATIVE, tag, stamp]
		).simplify_path()
	var result := {"directory": root, "files": {}}
	if DirAccess.make_dir_recursive_absolute(root) != OK:
		result["error"] = "snapshot_directory_create_failed"
		return result
	var ext = generator.get_data_core_world_ext() \
		if generator != null and generator.has_method("get_data_core_world_ext") else null
	if ext == null:
		result["error"] = "world_ext_unavailable"
		return result
	var epoch_active := bool(payload.get("economy", {}).get("epoch_active", false))
	result["epoch_active"] = epoch_active
	result["snapshot_boundary"] = "half_open_epoch" if epoch_active else "committed_boundary"
	result["forensics_only"] = true
	result["restore_eligible"] = false
	result["files"]["country.pkcn"] = _write_native_save_stream(
		ext, "country", root.path_join("country.pkcn"), 4 * 1024 * 1024)
	result["files"]["economy.pkec"] = _write_native_save_stream(
		ext, "economy", root.path_join("economy.pkec"), 4 * 1024 * 1024)
	var manifest := FileAccess.open(root.path_join("manifest.json"), FileAccess.WRITE)
	if manifest != null:
		manifest.store_string(JSON.stringify({
			"reason": payload.get("reason", ""),
			"captured_at": payload.get("captured_at", ""),
			"economy": payload.get("economy", {}),
			"files": result["files"],
			"epoch_active": epoch_active,
			"snapshot_boundary": result["snapshot_boundary"],
			"forensics_only": true,
			"restore_eligible": false,
		}, "\t"))
		manifest.close()
	else:
		result["manifest_error"] = "manifest_open_failed"
	return result


static func _write_native_save_stream(ext, domain: String, path: String,
		chunk_bytes: int) -> Dictionary:
	var begin_method := "begin_country_forensics_save" if domain == "country" \
		else "begin_economy_forensics_save"
	var read_method := "read_country_save_chunk" if domain == "country" \
		else "read_economy_save_chunk"
	var end_method := "end_country_save" if domain == "country" \
		else "end_economy_save"
	if not ext.has_method(begin_method) or not ext.has_method(read_method) \
			or not ext.has_method(end_method):
		return {"ok": false, "reason": "native_forensics_save_api_unavailable"}
	var begun: Dictionary = ext.call(begin_method, chunk_bytes)
	if not bool(begun.get("ok", false)):
		return {"ok": false, "reason": String(begun.get("reason", "begin_failed"))}
	var file := FileAccess.open(path, FileAccess.WRITE)
	var bytes_written := 0
	var write_error := ""
	if file == null:
		write_error = "snapshot_file_open_failed:%s" % error_string(FileAccess.get_open_error())
	while true:
		var chunk: PackedByteArray = ext.call(read_method, chunk_bytes)
		if chunk.is_empty():
			break
		if file != null and write_error.is_empty():
			file.store_buffer(chunk)
			if file.get_error() != OK:
				write_error = "snapshot_file_write_failed:%s" % error_string(file.get_error())
			else:
				bytes_written += chunk.size()
	if file != null:
		file.close()
	var ended: Dictionary = ext.call(end_method)
	if not write_error.is_empty():
		return {"ok": false, "reason": write_error, "bytes": bytes_written}
	return {"ok": bool(ended.get("ok", false)), "path": path,
		"bytes": bytes_written, "reason": String(ended.get("reason", "")),
		"native_schema_version": int(begun.get("schema_version", 0)),
		"native_state_hash": int(begun.get("state_hash", 0)),
		"native_generation": int(begun.get("generation", 0))}


static func _report(generator, method: String) -> Dictionary:
	if generator == null or not generator.has_method(method):
		return {}
	var value = generator.call(method)
	return value if value is Dictionary else {}


static func _pick(source: Dictionary, keys: Array) -> Dictionary:
	var out := {}
	for key in keys:
		if source.has(key):
			out[key] = source[key]
	return out
