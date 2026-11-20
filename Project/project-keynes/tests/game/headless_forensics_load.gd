extends Node

## R4-4 / R4-5 / R4-6：`--load-forensics <dir>` 只读加载入口。
## 依据：docs/plans/runtime-fault-infrastructure-plan.md §7.3 / §7.5。
##
## 由 GameFlowService 按 `PK_FORENSICS_LOAD=1` 挂到 root（见
## scripts/game/game_flow_service.gd 的 `_attach_headless_runner`）。
##
## 用法：
##   $env:PK_FORENSICS_LOAD = "1"
##   $env:PK_FORENSICS_DIR  = "<forensics dir>"   # 必需，含 country.pkcn + economy.pkec
##   $env:PK_FORENSICS_DAYS = "1"
##   $env:PK_FORENSICS_REPEAT = "1"               # 可选：整套恢复+推进跑两遍比对 state_hash
##   $env:PK_FORENSICS_CELLS  = "6400"            # 可选：pkcn 头读不出 cell_count 时的兜底
##   $env:PK_FORENSICS_SEED   = "20260101"        # 可选：configure 用 seed（默认工程默认值）
##   $env:PK_FORENSICS_SELFCHECK = "1"            # 可选：本进程先现场写一对快照再加载它
##   $env:PK_FORENSICS_CAPTURE_DAYS = "2"         # 可选：自检写包前先推进几天
##   $env:PK_SAVE_DIR = "<scratch>"               # 建议：本入口全程不写档
##   godot --headless --path Project/project-keynes
##
## 为什么不再 `begin_new_game`：那条路会跑 gameplay start，把经济 bootstrap 掉；而
## `begin_country_restore()` 的前置是 `economy->country_restore_allowed()`
## （= `!_bootstrapped`，见 gdext/src/world_ext_country.cpp），所以新开局世界永远
## 无法接受 PKCN 流式恢复。这里按 tests/economy/economy_cadence_runtime_test.gd 的
## `_boot()` 套路，只用 configure 造一个「与快照同 cell 数的合成世界」：
## `CountryTestHelper.configure_all_technologies()` + `ext.configure_economy()`，
## 都不置 `_bootstrapped`，因此恢复被允许，也不需要地图/gameplay start。
##
## 恢复顺序（生产口径）：PKCN 流式 begin→feed(4 MiB)→end → PKEC 流式 begin→feed→end
## （若 economy.pkec 是 `ECP2` 单块则走 `restore_economy_ecp2`）。PKEC 流是按
## **record** 组帧的（16 字节头 + payload，头里带 payload_bytes），所以 feed 必须按
## record 边界切；按固定大小切会把 record 头截断成 `save_chunk_header_invalid`。
##
## 推动：不走 WorldRuntimeHost，直接调 `ext.run_economy_slice({"day_index": day})`
## 把经济 epoch 推到 day+1，判据是 `fatal=false` 且提交审计零误差。
##
## `PK_FORENSICS_SELFCHECK=1`：本进程先用同一套生产写包接口（begin_*_forensics_save
## → read_*_save_chunk → end_*_save）现场产出一对 country.pkcn + economy.pkec，再
## 用上面的加载路径读回来。仓库里的 2026-11-18 批快照是**另一个构建**写的
## （country.pkcn 头里的 catalog_hash 与当前编译出的 catalog 不同，解码处
## `country_runtime_persistence.cpp::decode_save` 会返回 `catalog_hash_mismatch`），
## 所以同构建自检是当前唯一能端到端验证「可加载」的入口。
##
## 只读契约：关自动存档（tool-local 覆盖，不改玩家设置）、全程不调任何 save 接口、
## 退出不写玩家槽位。
##
## 退出码：0 = 恢复成功且推进到目标日、非 fatal、审计零误差；1 = 任一条不成立。

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyProfilePath := "res://data/economy/default_economy.tres"

const DEFAULT_DAYS := 1
## 与 runtime_forensics.gd 写包时的分块宽度一致（全量快照 4 MiB 一块）。
const RESTORE_CHUNK_BYTES := 4 * 1024 * 1024
const DEFAULT_SEED := 20260101
## 单次 economy slice 循环上限：只读复现卡死也必须收口，不能挂着进程。
const MAX_SLICES_PER_DAY := 20000
## country.pkcn 头布局（gdext/src/country_runtime_persistence.cpp::encode_save）：
## u32 magic "PKCN" / u32 schema / u64 catalog_hash / u64 generation /
## i64 committed_day / u64 submit_order / i32 cell_count / i32 country_count ...
const COUNTRY_SAVE_MAGIC := 0x4E434B50
const COUNTRY_HEADER_BYTES := 48
const COUNTRY_CELL_COUNT_OFFSET := 40
const COUNTRY_COMMITTED_DAY_OFFSET := 24
## PKEC 流记录帧：u32 magic / u16 schema / u16 section / u32 records / u32 payload_bytes。
const PKEC_SAVE_MAGIC := 0x43454B50
const PKEC_RECORD_HEADER_BYTES := 16
const PKEC_RECORD_PAYLOAD_OFFSET := 12

var _game_save: Node
var _failures := PackedStringArray()
var _result := {
	"ok": false,
	"restored": false,
	"restored_country": false,
	"restored_economy": false,
	"start_day": -1,
	"end_day": -1,
	"advanced_days": 0,
	"fatal": false,
	"fatal_reason": "",
	"state_hash": 0,
	"state_hash_before": 0,
	"state_hash_after": 0,
	"country_state_hash": "",
	"reason": "",
}
var _finished := false
var _country_bytes := PackedByteArray()
var _economy_bytes := PackedByteArray()
var _cells := 0
var _seed := DEFAULT_SEED
var _days := DEFAULT_DAYS


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var dir := _env("PK_FORENSICS_DIR", "")
	_days = int(_env("PK_FORENSICS_DAYS", str(DEFAULT_DAYS)))
	var repeat := _env("PK_FORENSICS_REPEAT", "0") == "1"
	var selfcheck := _env("PK_FORENSICS_SELFCHECK", "0") == "1"
	if selfcheck and dir.is_empty():
		dir = "tmp/forensics_selfcheck"
	_result["dir"] = dir
	_result["requested_days"] = _days
	print("[forensics-load] dir=%s days=%d repeat=%s selfcheck=%s" % [
		dir, _days, repeat, selfcheck])
	if dir.is_empty():
		_fail("forensics_dir_missing")
		_finish()
		return
	if _days <= 0:
		_fail("days_must_be_positive")
		_finish()
		return
	# 相对路径按「仓库根」解析：Godot 的 FileAccess 相对的是可执行文件目录，不是
	# 调用方 shell 的 CWD。
	dir = _resolve_dir(dir)
	_result["dir"] = dir
	# 自检模式：本进程先按生产写包接口现场产出 country.pkcn + economy.pkec，再按
	# 本入口加载它们。用来在没有「同构建玩家快照」的情况下验证加载链路本身。
	if selfcheck:
		_result["mode"] = "selfcheck_capture"
		if not _capture_pair(dir):
			_finish()
			return
		dir = _resolve_dir(dir)
		_result["dir"] = dir
	else:
		_result["mode"] = "snapshot"
	if not _read_members(dir):
		_finish()
		return
	if not _enter_read_only():
		_finish()
		return
	_cells = _resolve_cell_count()
	_seed = int(_env("PK_FORENSICS_SEED", str(DEFAULT_SEED)))
	_result["cells"] = _cells
	_result["seed"] = _seed
	if _cells <= 0:
		_fail("cell_count_unknown:pkcn_header_unparsable")
		_finish()
		return
	print("[forensics-load] cells=%d seed=%d country=%d B economy=%d B" % [
		_cells, _seed, _country_bytes.size(), _economy_bytes.size()])

	var first := await _cycle("first")
	# 没有 summary 说明 _cycle 中途被脚本错误打断：必须算失败，不能因为
	# `_failures` 恰好为空就 --green。
	if first == null or not first.has("ok"):
		_fail("cycle_incomplete")
		_finish()
		return
	_result["restored"] = bool(first.get("restored", false))
	# 失败时 summary 里没有这两个键：退回 _cycle() 写进结果的分段事实，
	# 「国家恢复成功、经济恢复失败」必须能和「两条都没成」区分开。
	_result["restored_country"] = bool(first.get("restored_country",
		_result.get("first_restored_country", false)))
	_result["restored_economy"] = bool(first.get("restored_economy",
		_result.get("first_restored_economy", false)))
	_result["state_hash_before"] = int(first.get("state_hash_before", 0))
	_result["state_hash_after"] = int(first.get("state_hash_after", 0))
	_result["state_hash"] = int(first.get("state_hash_after", 0))
	_result["country_state_hash"] = String(first.get("country_state_hash", ""))
	_result["start_day"] = int(first.get("start_day", -1))
	_result["end_day"] = int(first.get("end_day", -1))
	_result["advanced_days"] = int(first.get("advanced_days", 0))
	if bool(first.get("ok", false)) and int(first.get("advanced_days", 0)) != _days:
		# 推进天数没跑满就绝不报成功：`advanced_days` 是最容易悄悄变 0 的字段。
		_fail("advanced_days_mismatch:%d/%d" % [
			int(first.get("advanced_days", 0)), _days])
	if not bool(first.get("ok", false)):
		_finish()
		return
	if repeat:
		var second := await _cycle("repeat")
		var stable := bool(second.get("ok", false)) \
			and int(second.get("state_hash_after", 0)) \
				== int(first.get("state_hash_after", 0)) \
			and String(second.get("country_state_hash", "")) \
				== String(first.get("country_state_hash", ""))
		_result["repeat"] = {
			"ok": bool(second.get("ok", false)),
			"state_hash_after": int(second.get("state_hash_after", 0)),
			"country_state_hash": String(second.get("country_state_hash", "")),
		}
		_result["state_hash_stable"] = stable
		if not bool(second.get("ok", false)):
			_fail("state_hash_not_stable")
	_finish()


## 一次完整流程：configure-only 合成世界 → PKCN 恢复 → PKEC 恢复 → 推进 N 天。
## 第二步只比 state_hash；`PK_FORENSICS_REPEAT=1` 时用来验证「两次加载一致」。
func _cycle(label: String) -> Dictionary:
	var ext: Object = _build_configured_ext()
	if ext == null:
		return _cycle_failed(label, "configure_only_world_failed")
	_result["%s_configure" % label] = {
		"country_configured": true, "economy_configured": true,
	}

	# --- PKCN：先于 PKEC（生产恢复顺序）-------------------------------------
	var country := _restore_country(ext)
	_result["%s_restored_country" % label] = bool(country.get("ok", false))
	if not bool(country.get("ok", false)):
		_release(ext)
		return _cycle_failed(label, "country_restore_rejected:%s" % _reason_of(country))
	var country_hash := ""
	if ext.has_method("get_country_report"):
		country_hash = str(ext.get_country_report().get("state_hash", ""))
	# --- PKEC：流式（PKEC 分块）或单块 ECP2 --------------------------------
	var economy := _restore_economy(ext)
	_result["%s_restored_economy" % label] = bool(economy.get("ok", false))
	if not bool(economy.get("ok", false)):
		_release(ext)
		return _cycle_failed(label, "economy_restore_rejected:%s" % _reason_of(economy))
	var hash_before := _economy_hash(ext)
	print("[forensics-load/%s] restored country_hash=%s economy_hash=%d" % [
		label, country_hash, hash_before])

	# --- 推进 N 天：直接驱动 economy epoch，不经 WorldRuntimeHost -----------
	var report: Dictionary = ext.get_economy_report()
	var start_day := int(report.get("current_day", -1))
	if start_day < 0:
		start_day = int(report.get("newest_state_day", 0))
	var advanced := _advance(ext, start_day)
	var summary := {
		"ok": bool(advanced.get("ok", false)),
		"restored": true,
		"restored_country": true,
		"restored_economy": true,
		"start_day": start_day,
		"end_day": int(advanced.get("end_day", start_day)),
		"advanced_days": int(advanced.get("advanced_days", 0)),
		"state_hash_before": hash_before,
		"state_hash_after": _economy_hash(ext),
		"country_state_hash": country_hash,
		"reason": String(advanced.get("reason", "")),
	}
	_result["%s_restore" % label] = {
		"country_generation": int(country.get("generation", 0)),
		# 用 str() 而不是 String()：恢复字典里的值可能缺键/为 null，
		# String(null) 会抛 "Invalid call 'String' constructor" 并把整轮结果打断。
		"country_state_hash": str(country.get("state_hash", "")),
		"economy_cells": int(economy.get("restored_cells", 0)),
		"economy_pages": int(economy.get("restored_pages", 0)),
		"economy_markets": int(economy.get("restored_markets", 0)),
	}
	if not bool(summary["ok"]):
		_fail("%s:%s" % [label, str(summary["reason"])])
	_release(ext)
	return summary


## configure-only 合成世界。照 tests/economy/economy_cadence_runtime_test.gd 的
## `_new_ext()` / `_boot()`：先建 6400 格实体并登记经济日算读取的组件槽，再
## configure_country（含全科技）+ bootstrap_country，最后 configure_economy。
## 全程不 bootstrap 经济（`_bootstrapped` 保持 false）——这正是 PKCN 恢复的前置。
func _build_configured_ext() -> Object:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("missing_binding:DCWorldExt")
		return null
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(_cells)
	var climate := PackedFloat32Array()
	climate.resize(_cells)
	climate.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, climate)
	var zeros := PackedByteArray()
	zeros.resize(_cells)
	zeros.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zeros)

	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		_fail("economy_catalog_compile_failed:%s" % String(
			compiled.get("reason", "unknown")))
		return null
	var catalog: Dictionary = compiled.duplicate(true)
	catalog.erase("ok")
	# 目录规模指纹：恢复被 catalog_hash_mismatch 拒绝时，拿它和 country.pkcn 头里的
	# good/profession/building/technology/signal 计数逐一对比，就能分清「快照来自
	# 另一个构建」还是「本进程配置错了」。
	_result["catalog_counts"] = {
		"goods": _array_size(catalog, "good_ids"),
		"professions": _array_size(catalog, "profession_ids"),
		"buildings": _array_size(catalog, "building_type_ids"),
		"technologies": _array_size(catalog, "technology_ids"),
		"research_signals": _array_size(catalog, "research_signal_ids"),
	}
	# 等价于 CountryTestHelper.configure_all_technologies()，但保留 configure 的
	# 返回字典：`catalog_hash` 就在里面，恢复被 catalog_hash_mismatch 拒绝时要靠它
	# 判断「是快照太旧」还是「本进程配置错了」。
	var starting := PackedStringArray()
	for id in catalog.get("technology_ids", PackedStringArray()):
		starting.append(id)
	var water := PackedByteArray()
	water.resize(_cells)
	water.fill(0)
	var country_configured: Dictionary = ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": starting,
	}, _cells, _seed)
	_result["country_configure"] = _pick(country_configured,
		["ok", "catalog_hash", "cell_count", "country_count", "good_count",
		"profession_count", "building_count", "technology_count",
		"research_signal_count", "reason", "code"])
	if not bool(country_configured.get("ok", false)) \
			or not bool(ext.bootstrap_country({}, water).get("ok", false)):
		_fail("country_configure_failed:%s" % _reason_of(country_configured))
		return null
	var profile_resource = load(EconomyProfilePath)
	if profile_resource == null:
		_fail("economy_profile_missing:%s" % EconomyProfilePath)
		return null
	# 不覆盖 profile 的默认值：只做 Resource → native Dictionary 的转换。
	var profile: Dictionary = profile_resource.to_native_profile()
	var configured: Dictionary = ext.configure_economy(catalog, profile, _cells, _seed)
	if not bool(configured.get("ok", false)):
		_fail("economy_configure_failed:%s" % _reason_of(configured))
		return null
	# 生产 configure 的同一收尾（economy_facade_configuration.gd）：只在配置成功后
	# 尽力配置 worker 自然资源通道；失败不致命。
	if ext.has_method("configure_economy_natural_resources"):
		var natural: Dictionary = ext.configure_economy_natural_resources(
			ResourceProfileRegistry.build_pass_knobs())
		if not bool(natural.get("ok", false)):
			print("[forensics-load] warn: natural resources not configured: %s" % str(
				natural.get("code", "")))
	return ext


## PKCN 流式恢复：begin → feed(4 MiB) → end。返回 end_restore 的字典。
func _restore_country(ext: Object) -> Dictionary:
	for method in ["begin_country_restore", "feed_country_restore_chunk",
			"end_country_restore"]:
		if not ext.has_method(method):
			return {"ok": false, "reason": "missing_binding:%s" % method}
	var begun: Dictionary = ext.begin_country_restore()
	if not bool(begun.get("ok", false)):
		return begun
	var cursor := 0
	var chunks := 0
	while cursor < _country_bytes.size():
		var chunk := _country_bytes.slice(cursor, mini(
			cursor + RESTORE_CHUNK_BYTES, _country_bytes.size()))
		var fed: Dictionary = ext.feed_country_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return fed
		cursor += RESTORE_CHUNK_BYTES
		chunks += 1
	_result["country_chunks"] = chunks
	return ext.end_country_restore()


## PKEC 恢复：`ECP2` magic 走生产 `restore_economy_ecp2`，否则走分块流式
## （runtime_forensics 写出的就是后者）。
##
## 关键：PKEC 流是按 **record** 组帧的（每个 record = 16 字节头 + payload，头里
## 自带 payload_bytes，见 economy_runtime_persistence_read.cpp::decode_restore_chunk）。
## 生产侧 feed 的粒度就是 record，所以这里必须按 record 边界切分；按固定 4 MiB
## 切会把 record 头拦腰截断，得到 `save_chunk_header_invalid`。
func _restore_economy(ext: Object) -> Dictionary:
	var ecp2 := _economy_bytes.size() >= 4 and _economy_bytes[0] == 0x45 \
		and _economy_bytes[1] == 0x43 and _economy_bytes[2] == 0x50 \
		and _economy_bytes[3] == 0x32
	_result["economy_restore_path"] = "ecp2" if ecp2 else "pkec_stream"
	if ecp2 and ext.has_method("restore_economy_ecp2"):
		return ext.restore_economy_ecp2(_economy_bytes)
	for method in ["begin_economy_restore", "feed_economy_restore_chunk",
			"end_economy_restore"]:
		if not ext.has_method(method):
			return {"ok": false, "reason": "missing_binding:%s" % method}
	var begun: Dictionary = ext.begin_economy_restore()
	if not bool(begun.get("ok", false)):
		return begun
	var cursor := 0
	var chunks := 0
	var last_fed := {}
	while cursor < _economy_bytes.size():
		if _economy_bytes.size() - cursor < PKEC_RECORD_HEADER_BYTES:
			return {"ok": false, "reason": "pkec_record_header_truncated_at:%d" % cursor}
		if _economy_bytes.decode_u32(cursor) != PKEC_SAVE_MAGIC:
			return {"ok": false, "reason": "pkec_record_magic_invalid_at:%d" % cursor}
		var payload_bytes := int(_economy_bytes.decode_u32(
			cursor + PKEC_RECORD_PAYLOAD_OFFSET))
		var total := PKEC_RECORD_HEADER_BYTES + payload_bytes
		if cursor + total > _economy_bytes.size():
			return {"ok": false, "reason": "pkec_record_size_invalid_at:%d" % cursor}
		var fed: Dictionary = ext.feed_economy_restore_chunk(
			_economy_bytes.slice(cursor, cursor + total))
		if not bool(fed.get("ok", false)):
			return fed
		last_fed = fed
		cursor += total
		chunks += 1
	_result["economy_chunks"] = chunks
	var ended: Dictionary = ext.end_economy_restore()
	# 恢复规模在 **feed** 的返回里（restored_pages/cells/markets），end_restore 只给
	# ok/reason 与最终计数校验；把最后一次 feed 的累计值并进来，避免结果里出现
	# 误导性的 0。
	for key in ["restored_pages", "restored_markets", "restored_cells",
			"restored_commands", "restored_buildings", "restored_persons"]:
		if last_fed.has(key) and not ended.has(key):
			ended[key] = last_fed[key]
	return ended


## 推进 N 天：`run_economy_slice` 是 economy 侧的 epoch/day 入口（与
## economy_cadence_runtime_test.gd 的 `_run_day()` 同一用法），不依赖 WorldRuntimeHost。
## 加载成功后追加一次提交审计：能推一天但账本有误差不算通过。
func _advance(ext: Object, start_day: int) -> Dictionary:
	var ran := _run_days(ext, start_day, _days)
	var end_day := int(ran.get("end_day", start_day))
	var advanced := int(ran.get("advanced_days", 0))
	if not bool(ran.get("ok", false)):
		return ran
	var audit: Dictionary = {}
	if ext.has_method("get_economy_committed_audit_report"):
		audit = ext.get_economy_committed_audit_report()
	_result["audit"] = {
		"available": bool(audit.get("available", false)),
		"population_error": int(audit.get("population_error", 0)),
		"money_error": int(audit.get("money_error", 0)),
		"goods_error": int(audit.get("goods_error", 0)),
		"audit_incomplete": bool(audit.get("audit_incomplete", true)),
	}
	var audit_ok := bool(audit.get("available", false)) \
		and int(audit.get("population_error", 0)) == 0 \
		and int(audit.get("money_error", 0)) == 0 \
		and int(audit.get("goods_error", 0)) == 0 \
		and not bool(audit.get("audit_incomplete", true))
	if not audit_ok:
		return {"ok": false, "reason": "ledger_audit_failed", "end_day": end_day,
			"advanced_days": advanced}
	return {"ok": true, "reason": "", "end_day": end_day,
		"advanced_days": advanced}


func _run_days(ext: Object, start_day: int, days: int) -> Dictionary:
	if not ext.has_method("run_economy_slice"):
		return {"ok": false, "reason": "missing_binding:run_economy_slice",
			"end_day": start_day, "advanced_days": 0}
	var advanced := 0
	for index in range(days):
		var day := start_day + index + 1
		var slices := 0
		var done := false
		var fatal := false
		var fatal_reason := ""
		while slices < MAX_SLICES_PER_DAY:
			var slice: Dictionary = ext.call("run_economy_slice",
				{"day_index": day})
			slices += 1
			if bool(slice.get("fatal", false)):
				fatal = true
				fatal_reason = String(slice.get("fatal_reason",
					slice.get("stage", "unknown")))
				break
			if bool(slice.get("done", false)):
				done = true
				break
		print("[forensics-load] day=%d slices=%d done=%s fatal=%s" % [
			day, slices, done, fatal])
		if fatal:
			_result["fatal"] = true
			_result["fatal_reason"] = fatal_reason
			_result["fatal_day"] = day
			return {"ok": false, "reason": "economy_fatal:%s" % fatal_reason,
				"end_day": day, "advanced_days": advanced}
		if not done:
			return {"ok": false, "reason": "day_slice_budget_exhausted:%d" % day,
				"end_day": day, "advanced_days": advanced}
		advanced += 1
	return {"ok": true, "reason": "", "end_day": start_day + advanced,
		"advanced_days": advanced}


func _economy_hash(ext: Object) -> int:
	if ext.has_method("get_economy_state_hash"):
		return int(ext.get_economy_state_hash())
	return int(ext.get_economy_report().get("state_hash", 0))


## country.pkcn 头里读 cell_count / committed_day。读不出就退到 PK_FORENSICS_CELLS。
func _resolve_cell_count() -> int:
	var from_header := _peek_country_header()
	if from_header.has("cells") and int(from_header["cells"]) > 0:
		_result["country_header"] = from_header
		_result["cells_source"] = "country.pkcn"
		return int(from_header["cells"])
	var override := int(_env("PK_FORENSICS_CELLS", "0"))
	_result["cells_source"] = "env" if override > 0 else "unavailable"
	return override


## 只挑字典里的标量键，避免把大数组写进单行结果。
func _pick(source: Dictionary, keys: Array) -> Dictionary:
	var out := {}
	for key in keys:
		if source.has(key):
			var value: Variant = source[key]
			if value is Array or value is Dictionary \
					or value is PackedStringArray or value is PackedInt32Array:
				continue
			out[key] = value
	return out


func _array_size(source: Dictionary, key: String) -> int:
	var value: Variant = source.get(key, [])
	return value.size() if value is PackedStringArray or value is Array else -1


## 自检写包：配置好的合成世界 → （bootstrap 经济，写包前置）→ 推进若干天 →
## 按 runtime_forensics.gd 的同一套接口写出 country.pkcn / economy.pkec。
## 目的：在没有「同构建玩家快照」时证明本入口的加载链路本身可用。
func _capture_pair(dir: String) -> bool:
	var absolute := _ensure_dir(dir)
	if absolute.is_empty():
		_fail("selfcheck_dir_create_failed:%s" % dir)
		return false
	_cells = int(_env("PK_FORENSICS_CELLS", "6400"))
	_seed = int(_env("PK_FORENSICS_SEED", str(DEFAULT_SEED)))
	_result["cells"] = _cells
	_result["seed"] = _seed
	var ext: Object = _build_configured_ext()
	if ext == null:
		return false
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var signature := 0
	var keys: Variant = compiled.get("signature_keys", PackedStringArray())
	if keys is PackedStringArray:
		var found: int = (keys as PackedStringArray).find("merchant|default")
		signature = found if found >= 0 else 0
	# economy 的 begin_save 要求已 bootstrap（`economy_not_bootstrapped`）。
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([20]),
		"funds": PackedInt64Array([100000]),
	}, {})
	if not bool(boot.get("ok", false)):
		_fail("selfcheck_economy_bootstrap_failed:%s" % _reason_of(boot))
		_release(ext)
		return false
	var report: Dictionary = ext.get_economy_report()
	var day := int(report.get("current_day", -1))
	if day < 0:
		day = int(report.get("newest_state_day", -1))
	var capture_days := int(_env("PK_FORENSICS_CAPTURE_DAYS", "2"))
	var ran := _run_days(ext, day, capture_days)
	if not bool(ran.get("ok", false)):
		_fail("selfcheck_capture_days_failed:%s" % String(ran.get("reason", "")))
		_release(ext)
		return false
	var country_written := _write_stream(ext, "country",
		absolute.path_join("country.pkcn"))
	if not bool(country_written.get("ok", false)):
		_fail("selfcheck_country_capture_failed:%s" % _reason_of(country_written))
		_release(ext)
		return false
	var economy_written := _write_stream(ext, "economy",
		absolute.path_join("economy.pkec"))
	if not bool(economy_written.get("ok", false)):
		_fail("selfcheck_economy_capture_failed:%s" % _reason_of(economy_written))
		_release(ext)
		return false
	_result["selfcheck_capture"] = {
		"country_bytes": int(country_written.get("bytes", 0)),
		"economy_bytes": int(economy_written.get("bytes", 0)),
		"days": int(ran.get("advanced_days", 0)),
		"day": int(ran.get("end_day", -1)),
	}
	print("[forensics-load/selfcheck] captured country=%d B economy=%d B at day=%d" % [
		int(country_written.get("bytes", 0)), int(economy_written.get("bytes", 0)),
		int(ran.get("end_day", -1))])
	_release(ext)
	return true


## 按生产写包接口把一条流写到文件（country / economy 同一形状）。
func _write_stream(ext: Object, domain: String, path: String) -> Dictionary:
	var begin_method := "begin_%s_forensics_save" % domain
	var read_method := "read_%s_save_chunk" % domain
	var end_method := "end_%s_save" % domain
	for method in [begin_method, read_method, end_method]:
		if not ext.has_method(method):
			return {"ok": false, "reason": "missing_binding:%s" % method}
	var begun: Dictionary = ext.call(begin_method, RESTORE_CHUNK_BYTES)
	if not bool(begun.get("ok", false)):
		return begun
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "reason": "file_open_failed:%s" % error_string(
			FileAccess.get_open_error())}
	var written := 0
	while true:
		var chunk: PackedByteArray = ext.call(read_method, RESTORE_CHUNK_BYTES)
		if chunk.is_empty():
			break
		file.store_buffer(chunk)
		if file.get_error() != OK:
			file.close()
			return {"ok": false, "reason": "file_write_failed:%s" % error_string(
				file.get_error())}
		written += chunk.size()
	file.close()
	var ended: Dictionary = ext.call(end_method)
	if not bool(ended.get("ok", false)):
		return ended
	return {"ok": true, "bytes": written}


func _ensure_dir(dir: String) -> String:
	var absolute := dir
	if not absolute.is_absolute_path():
		var repo_root := ProjectSettings.globalize_path("res://").path_join("..")
		repo_root = repo_root.path_join("..").simplify_path()
		absolute = repo_root.path_join(dir).simplify_path()
	if DirAccess.make_dir_recursive_absolute(absolute) != OK:
		return ""
	return absolute


func _peek_country_header() -> Dictionary:
	if _country_bytes.size() < COUNTRY_HEADER_BYTES:
		return {}
	if _country_bytes.decode_u32(0) != COUNTRY_SAVE_MAGIC:
		return {}
	return {
		"schema": _country_bytes.decode_u32(4),
		"generation": _country_bytes.decode_u64(16),
		"committed_day": _country_bytes.decode_s64(COUNTRY_COMMITTED_DAY_OFFSET),
		"cells": _country_bytes.decode_s32(COUNTRY_CELL_COUNT_OFFSET),
		"countries": _country_bytes.decode_s32(44),
	}


## 只读会话：关自动存档、记录存档目录，且此后不调用任何 save 接口。
func _enter_read_only() -> bool:
	_result["readonly"] = true
	_result["writes_saves"] = false
	_game_save = get_tree().root.get_node_or_null("GameSave")
	if _game_save == null:
		_result["autosave_disabled"] = true
		return true
	# tool-local 覆盖，和 headless_save_replay.gd 一样：不改玩家持久化的设置项。
	_game_save.set("_autosave_enabled", false)
	var still_enabled := bool(_game_save.call("is_autosave_enabled")) \
		if _game_save.has_method("is_autosave_enabled") else false
	_result["autosave_disabled"] = not still_enabled
	var repository = _game_save.get("_repository")
	_result["save_dir"] = String(repository.get("_save_dir")) if repository != null \
		else ""
	if still_enabled:
		# 关不掉自动存档的构建里，本入口仍然不主动写档，但必须报出来。
		_fail("readonly_autosave_not_disabled")
		return false
	if _result["save_dir"] == "user://saves":
		_result["save_dir_is_player_default"] = true
	return true


## 把 `tmp/...` 这类相对目录解析成真的存在的绝对目录。
func _resolve_dir(path: String) -> String:
	if _dir_has_forensics_member(path):
		return path
	var repo_root := ProjectSettings.globalize_path("res://").path_join("..")
	repo_root = repo_root.path_join("..").simplify_path()
	var candidate := repo_root.path_join(path).simplify_path()
	if _dir_has_forensics_member(candidate):
		return candidate
	return path


func _dir_has_forensics_member(path: String) -> bool:
	return FileAccess.file_exists(path.path_join("country.pkcn")) \
		or FileAccess.file_exists(path.path_join("economy.pkec"))


func _read_members(dir: String) -> bool:
	var country_path := dir.path_join("country.pkcn")
	var economy_path := dir.path_join("economy.pkec")
	var missing := PackedStringArray()
	if not FileAccess.file_exists(country_path):
		missing.append("country.pkcn")
	if not FileAccess.file_exists(economy_path):
		missing.append("economy.pkec")
	if not missing.is_empty():
		_fail("missing_member:%s" % ", ".join(missing))
		return false
	_country_bytes = FileAccess.get_file_as_bytes(country_path)
	_economy_bytes = FileAccess.get_file_as_bytes(economy_path)
	_result["members"] = {
		"country.pkcn": _country_bytes.size(),
		"economy.pkec": _economy_bytes.size(),
	}
	if _country_bytes.is_empty():
		_fail("member_empty:country.pkcn")
		return false
	if _economy_bytes.is_empty():
		_fail("member_empty:economy.pkec")
		return false
	return true


func _cycle_failed(label: String, reason: String) -> Dictionary:
	var blocker := _blocker_of(reason)
	if not blocker.is_empty():
		_result["blocked_by"] = blocker
		reason = "%s[%s]" % [reason, blocker]
	_fail("%s:%s" % [label, reason])
	return {"ok": false, "reason": reason, "restored": false}


func _blocker_of(reason: String) -> String:
	if reason.contains("missing_binding:"):
		return "missing_binding"
	if reason.contains("country_restore_must_precede_economy_bootstrap"):
		return "r4_world_not_restore_prepared"
	if reason.contains("restore_requires_ecp2") or reason.contains("ecp2_"):
		return "r4_snapshot_format"
	return ""


func _reason_of(report: Dictionary) -> String:
	for key in ["reason", "restore_rejected_reason", "code", "fatal_reason"]:
		if not String(report.get(key, "")).is_empty():
			return String(report[key])
	return "unknown"


func _release(ext: Object) -> void:
	# 只释放引用：DCWorldExt 的实体/SoA 在引用归零时由 native 侧回收，不额外调停接口
	# （本入口从未 start_runtime_worker，没有 worker 需要停）。
	if ext == null:
		return
	if ext.has_method("request_runtime_stop"):
		# 没起 worker 时是安全的 no-op；保险起见只调一次。
		ext.call("request_runtime_stop")


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name).strip_edges()
	return value if not value.is_empty() else fallback


func _fail(reason: String) -> void:
	_failures.append(reason)
	push_error("[forensics-load] %s" % reason)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_result["failures"] = _failures
	_result["ok"] = _failures.is_empty()
	_result["reason"] = "" if _failures.is_empty() else ", ".join(_failures)
	# 单行机读结果。前缀不要改：验收与包装脚本按这个前缀解析。
	print("[forensics-load/result] %s" % JSON.stringify(_result))
	get_tree().quit(0 if _failures.is_empty() else 1)
