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

## `.pkinc` 事故包生产者。必须 preload 而不是等调用方注入：fatal 现场只有一次
## 落盘机会，不能再依赖"外部有没有把模块接上"。
const IncidentBundle = preload("res://scripts/game/incident_bundle.gd")

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
	"money_stage_diagnostics",
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
	# 主线程真正必须停推的域，以及其中只被"授权窗口"挡住的那部分。只看
	# authoritative_domain_mask 无法区分"worker 已拥有"和"worker 正在挡住"，
	# 请求了却永远拿不到的域会静默地永久丢失。
	"main_thread_suppressed_domain_mask", "authority_window_domain_mask",
	"authority_window_blocker",
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
	return _capture_with_report(reason, generator, clock, extra)[0]


## capture() 的内部形态：除了 payload，还把**原始** economy report 交回去。
## get_economy_report() 会复制整份诊断（很重），而 economy fatal 的观察点后面
## 还要拿同一份 report 喂 incident_bundle 写 .pkinc —— 整条链路只取一次。
static func _capture_with_report(reason: String, generator, clock,
		extra: Dictionary = {}) -> Array:
	var payload := {
		"reason": reason,
		"captured_at": Time.get_datetime_string_from_system(),
		"engine": {
			"debug_build": OS.is_debug_build(),
			"headless": DisplayServer.get_name() == "headless",
			"process_frames": Engine.get_process_frames(),
			# 构建标识：这条 fatal 是哪一版二进制产生的。C++ 侧由 PK_BUILD_ID
			# 注入，未注入时留空即可 —— 取证路径上不允许 push_error。
			"build_id": "",
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
		return [payload, {}]
	var economy := _report(generator, "get_economy_report")
	payload["engine"]["build_id"] = String(economy.get("build_id", ""))
	payload["economy"] = _pick(economy, ECONOMY_SCENE_KEYS)
	payload["economy_conservation"] = _pick(economy, ECONOMY_CONSERVATION_KEYS)
	payload["country"] = _pick(_report(generator, "get_country_report"),
		COUNTRY_SCENE_KEYS)
	# 权威 mask 和 worker 状态只在 thread report 里，而"哪个域是 ACTIVE"恰恰
	# 决定了跨域 fast path 走不走 —— 没有它就无法判断一次边界拒绝是否合理。
	payload["runtime_thread"] = _pick(
		_report(generator, "get_runtime_thread_report"), RUNTIME_THREAD_KEYS)
	return [payload, economy]


## 落盘并打印单行标记。返回 tmp 下那份的绝对路径（失败时返回空串）。
static func dump(payload: Dictionary, tag: String) -> String:
	# Web：整份 payload（含 economy 快照）JSON.stringify ×2 + duplicate(true) +
	# 把数 MB 文本打进浏览器控制台，实测单次 45s（主线程整帧卡住）。浏览器里也
	# 写不了 res:// 那份，落盘价值为零。这里只发一条轻量事件，随后立即返回。
	if OS.has_feature("web"):
		WebTelemetry.emit("forensics_skipped", {"tag": tag, "keys": payload.size()})
		return ""
	var text := JSON.stringify(payload)
	var log_payload := payload.duplicate(true)
	print("[runtime-forensics/%s] %s" % [tag, JSON.stringify(log_payload)])
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
	var captured := _capture_with_report(reason, generator, clock, extra)
	var payload: Dictionary = captured[0]
	var economy_report: Dictionary = captured[1]
	if tag == "economy_fatal":
		# 全量快照按需（R4-7）：40 MB 的 PKEC 现场玩家发不出来，`.pkinc` 才是
		# 能发出来的那一份。历史上每来一次 fatal 就写一份全量，tmp/ 里堆到
		# 131 份 / 1.07 GB 而没有任何一份被打开过。默认只写 `.pkinc`；
		# 要全量就显式 PK_FORENSICS_FULL=1，或由调用方传 extra.full_snapshot
		# （GM 面板手动导出走这条路）。跳过的占位保留键名，免得下游 KeyError。
		if _full_snapshot_enabled(extra):
			payload["economic_snapshots"] = _dump_economic_snapshots(generator,
				payload, tag)
		else:
			payload["economic_snapshots"] = {
				"skipped": true,
				"reason": "full_snapshot_disabled",
				"enable": "%s=1" % FULL_SNAPSHOT_ENV,
			}
		payload["incident_bundle"] = _write_incident_bundle(reason, generator,
			clock, tag, payload, economy_report)
	if _should_print_economy_trace(tag):
		_print_economy_trace(payload, tag)
	return dump(payload, tag)


## 全量快照的显式开关（见 capture_and_dump 里的说明）。
const FULL_SNAPSHOT_ENV := "PK_FORENSICS_FULL"


## 是否写全量 PKEC/PKCN 现场：环境变量优先，其次是调用方显式请求。
static func _full_snapshot_enabled(extra: Dictionary) -> bool:
	if extra is Dictionary and bool(extra.get("full_snapshot", false)):
		return true
	return OS.get_environment(FULL_SNAPSHOT_ENV) == "1"


## economy fatal 之后追加写 `.pkinc` 事故包。
## 复用 _capture_with_report 已经取到的 economy report，不再第二次调用
## get_economy_report()；cell 切片由 incident_bundle 通过 facade 自行采集。
static func _write_incident_bundle(reason: String, generator, clock, tag: String,
		payload: Dictionary, economy_report: Dictionary) -> Dictionary:
	var context := {
		"generator": generator,
		"economy_report": economy_report,
		"reason": reason,
		"kind": "fatal",
		"captured_at": String(payload.get("captured_at", "")),
		"producer": "runtime_forensics.gd",
	}
	if clock != null:
		context["day"] = clock.day_index()
	var source: Dictionary = payload.get("context", {}) \
		if payload.get("context") is Dictionary else {}
	# 世界尺寸/种子只有 host 侧知道（MapGenerator 不暴露地图），调用方通过
	# extra["world"] 传进来；其余事件字段按需透传。
	for key in ["world", "hashes", "witness", "cell", "type_id", "assert_id",
			"force_injected", "commands"]:
		if source.has(key):
			context[key] = source[key]
	var result: Dictionary = IncidentBundle.write(context)
	print("[runtime-forensics/%s/incident-bundle] ok=%s bytes=%s truncated=%s path=%s reason=%s" % [
		tag,
		str(result.get("ok", false)),
		str(result.get("bytes", 0)),
		JSON.stringify(result.get("truncated", [])),
		String(result.get("path", "")),
		String(result.get("reason", "")),
	])
	return result


static func _should_print_economy_trace(tag: String) -> bool:
	return tag == "economy_fatal" or tag == "runtime_worker_fault" or tag == "stall"


## 发生经济 fatal 或 worker 暂停时，把经济状态和阶段账目打印到 Godot
## 输出面板；正常模拟期间不会逐帧输出追踪日志。
static func _print_economy_trace(payload: Dictionary, tag: String) -> void:
	for line in _build_economy_trace_lines(payload, tag):
		print(line)


static func _build_economy_trace_lines(payload: Dictionary, tag: String) -> PackedStringArray:
	var economy: Dictionary = payload.get("economy", {})
	var conservation: Dictionary = payload.get("economy_conservation", {})
	var lines := PackedStringArray()
	if economy.is_empty() and conservation.is_empty():
		lines.append("[runtime-forensics/%s/economy] report_unavailable=true" % tag)
		return lines
	lines.append("[runtime-forensics/%s/economy] fatal=%s reason=%s day=%s epoch=%s stage=%s executed=%s substage=%s audit_incomplete=%s audit_incomplete_reason=%s audit_mode=%s population_error=%s money_error=%s goods_error=%s" % [
		tag,
		str(economy.get("fatal", false)),
		str(economy.get("fatal_reason", "")),
		str(economy.get("current_day", -1)),
		str(economy.get("epoch_id", -1)),
		str(economy.get("stage", "unknown")),
		str(economy.get("executed_stage", "unknown")),
		str(economy.get("executed_substage", "")),
		str(conservation.get("audit_incomplete", "unknown")),
		str(conservation.get("audit_incomplete_reason", "")),
		str(conservation.get("closing_audit_mode", "unknown")),
		str(conservation.get("population_error", "unknown")),
		str(conservation.get("money_error", "unknown")),
		str(conservation.get("goods_error", "unknown")),
	])
	lines.append("[runtime-forensics/%s/money-ledger] open=%s close=%s expected=%s error=%s mint=%s burn=%s cohort_open=%s cohort_close=%s country_open=%s country_close=%s escrow_open=%s escrow_close=%s producer_support=%s bullion=%s" % [
		tag,
		str(conservation.get("money_open", "unknown")),
		str(conservation.get("money_close", "unknown")),
		str(conservation.get("money_expected", "unknown")),
		str(conservation.get("money_error", "unknown")),
		str(conservation.get("explicit_money_mint", "unknown")),
		str(conservation.get("explicit_money_burn", "unknown")),
		str(conservation.get("opening_cohort_funds", "unknown")),
		str(conservation.get("closing_cohort_funds", "unknown")),
		str(conservation.get("opening_country_cash", "unknown")),
		str(conservation.get("closing_country_cash", "unknown")),
		str(conservation.get("opening_escrow_cash", "unknown")),
		str(conservation.get("closing_escrow_cash", "unknown")),
		str(conservation.get("producer_support_money_issued", "unknown")),
		str(conservation.get("bullion_money_issued", "unknown")),
	])
	var fatal_context = economy.get("fatal_context", {})
	if fatal_context is Dictionary and not fatal_context.is_empty():
		lines.append("[runtime-forensics/%s/fatal-context] %s" % [tag,
			JSON.stringify(fatal_context)])
	var stage_rows = conservation.get("money_stage_diagnostics", [])
	var first_nonzero_stage: Dictionary = {}
	for row in stage_rows:
		if not row is Dictionary:
			continue
		if first_nonzero_stage.is_empty() and int(row.get("diff", 0)) != 0:
			first_nonzero_stage = row
		lines.append("[runtime-forensics/%s/money-stage] day=%s epoch=%s where=%s stage=%s executed=%s substage=%s diff=%s delta=%s money=%s expected=%s cohort=%s country=%s escrow=%s mint=%s burn=%s" % [
			tag,
			str(row.get("day", -1)),
			str(row.get("epoch_id", -1)),
			str(row.get("where", "")),
			str(row.get("stage", "unknown")),
			str(row.get("executed_stage", "unknown")),
			str(row.get("substage", "")),
			str(row.get("diff", "unknown")),
			str(row.get("delta", "unknown")),
			str(row.get("money_now", "unknown")),
			str(row.get("money_expected", "unknown")),
			str(row.get("cohort_funds", "unknown")),
			str(row.get("country_cash", "unknown")),
			str(row.get("escrow_cash", "unknown")),
			str(row.get("explicit_money_mint", "unknown")),
			str(row.get("explicit_money_burn", "unknown")),
		])
	if first_nonzero_stage.is_empty():
		lines.append("[runtime-forensics/%s/money-first-observed] unavailable=true stage_rows=%d" % [
			tag, stage_rows.size()])
	else:
		lines.append("[runtime-forensics/%s/money-first-observed] day=%s where=%s stage=%s executed=%s substage=%s diff=%s delta=%s" % [
			tag,
			str(first_nonzero_stage.get("day", -1)),
			str(first_nonzero_stage.get("where", "")),
			str(first_nonzero_stage.get("stage", "unknown")),
			str(first_nonzero_stage.get("executed_stage", "unknown")),
			str(first_nonzero_stage.get("substage", "")),
			str(first_nonzero_stage.get("diff", "unknown")),
			str(first_nonzero_stage.get("delta", "unknown")),
		])
	for account in conservation.get("money_audit_candidate_accounts", []):
		if account is Dictionary:
			lines.append("[runtime-forensics/%s/money-candidate] %s" % [tag,
				JSON.stringify(account)])
	return lines


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
	var country = generator.get_country_facade() \
		if generator != null and generator.has_method("get_country_facade") else null
	var economy = generator.get_economy_facade() \
		if generator != null and generator.has_method("get_economy_facade") else null
	if country == null or economy == null \
			or country.world_ext() == null or economy.world_ext() == null:
		result["error"] = "world_ext_unavailable"
		return result
	var epoch_active := bool(payload.get("economy", {}).get("epoch_active", false))
	result["epoch_active"] = epoch_active
	result["snapshot_boundary"] = "half_open_epoch" if epoch_active else "committed_boundary"
	result["forensics_only"] = true
	result["files"]["country.pkcn"] = _write_native_save_stream(
		country, root.path_join("country.pkcn"), 4 * 1024 * 1024)
	result["files"]["economy.pkec"] = _write_native_save_stream(
		economy, root.path_join("economy.pkec"), 4 * 1024 * 1024)
	# 可恢复性不能硬编码 false：C++ 只有在 begin_forensics_save 真的返回了
	# generation/state_hash 时才敢说"这份快照能加载回去"。两份都声明可恢复，
	# 整组才算可恢复；C++ 还没给出时如实落 false/0，但键必须存在。
	var country_file: Dictionary = result["files"].get("country.pkcn", {})
	var economy_file: Dictionary = result["files"].get("economy.pkec", {})
	result["restore_eligible"] = bool(country_file.get("restore_eligible", false)) \
		and bool(economy_file.get("restore_eligible", false))
	result["native_generation"] = int(economy_file.get("native_generation", 0))
	result["native_state_hash"] = int(economy_file.get("native_state_hash", 0))
	result["native_schema_version"] = int(economy_file.get("native_schema_version", 0))
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
			"restore_eligible": result["restore_eligible"],
			"native_generation": result["native_generation"],
			"native_state_hash": result["native_state_hash"],
			"native_schema_version": result["native_schema_version"],
		}, "\t"))
		manifest.close()
	else:
		result["manifest_error"] = "manifest_open_failed"
	return result


static func _write_native_save_stream(facade, path: String,
		chunk_bytes: int) -> Dictionary:
	var begun: Dictionary = facade.begin_forensics_save(chunk_bytes)
	if not bool(begun.get("ok", false)):
		return {"ok": false, "reason": String(begun.get("reason", "begin_failed"))}
	var file := FileAccess.open(path, FileAccess.WRITE)
	var bytes_written := 0
	var write_error := ""
	if file == null:
		write_error = "snapshot_file_open_failed:%s" % error_string(FileAccess.get_open_error())
	while true:
		var chunk: PackedByteArray = facade.read_forensics_save_chunk(chunk_bytes)
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
	var ended: Dictionary = facade.end_forensics_save()
	if not write_error.is_empty():
		return {"ok": false, "reason": write_error, "bytes": bytes_written}
	return {"ok": bool(ended.get("ok", false)), "path": path,
		"bytes": bytes_written, "reason": String(ended.get("reason", "")),
		"native_schema_version": int(begun.get("schema_version", 0)),
		"native_state_hash": int(begun.get("state_hash", 0)),
		"native_generation": int(begun.get("generation", 0)),
		# begin/end 任一侧给出 restore_eligible 都算数；C++ 还没实现时如实 false。
		"restore_eligible": bool(begun.get("restore_eligible",
			ended.get("restore_eligible", false)))}


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
