extends RefCounted

## 调用方一律用 preload 引用本文件，不要依赖 class_name 全局注册：新脚本在编辑器
## 重新扫描之前不在 global_script_class_cache 里，无头跑测试会整片 Parse Error。
## （同 runtime_forensics.gd 顶部注释。）

## `.pkinc` 事故包生产者（schema v1）。
##
## 契约唯一真相是 docs/runtime/incident-bundle-schema.md，本文件不自行改字段名。
## 目标：玩家只发一个 < 200 KB 的 zip，我们就能拿到复现根因所需的全部输入，
## 不需要 40 MB 的存档。所以这里只装标量、哈希与「失败格」的切片；
## 任何全图/全人口明细都算违约。
##
## 成员写入顺序（schema §2.2）：MANIFEST.json 必须第一个进包，但它必须等所有
## 成员的 sha256 都算完才能生成 —— 于是内容先在内存里备齐，最后统一落盘。
##
## 体积控制两级：
##   > 200 KB 起诉裁（cell.json 的 market_lanes/pending_construction → commands.json
##   → cell.json 剩余明细），> 2 MB 是硬上限，裁剪项一律记进 MANIFEST.truncated。
##
## 落盘位置与 runtime_forensics.gd 的 tmp 快照同源：
##   桌面：<repo>/tmp/incidents/<stamp>_<reason>.pkinc
##   移动：user://incidents/<stamp>_<reason>.pkinc

## schema 版本。升级到 pkinc/2 时消费者仍须能读 pkinc/1（n-1 兼容）。
const SCHEMA_VERSION := "pkinc/1"
const MANIFEST_NAME := "MANIFEST.json"
## 成员写入顺序，MANIFEST.json 由 _write_zip 单独排在最前。
const MEMBER_ORDER := [
	"incident.json", "witness.json", "cell.json",
	"commands.json", "world.json", "hashes.txt",
]
## 除 MANIFEST 外必须存在的成员（commands.json 是可选的，schema §2.7）。
const REQUIRED_MEMBERS := [
	"incident.json", "witness.json", "cell.json", "world.json", "hashes.txt",
]

const SOFT_LIMIT_BYTES := 200 * 1024
const HARD_LIMIT_BYTES := 2 * 1024 * 1024
## schema §2.4：单格切片 ≤ 64 KB。
const CELL_LIMIT_BYTES := 64 * 1024
## 默认保留最近 10 份（checklist R2-4）。
const KEEP_BUNDLES := 10

## 裁剪阶梯。数字越大裁得越狠；每一步只丢掉一块可选内容，其余成员保持完整。
const TRIM_NONE := 0
const TRIM_MARKET_LANES := 1
const TRIM_PENDING_CONSTRUCTION := 2
const TRIM_COMMANDS := 3
const TRIM_BUILDINGS := 4
const TRIM_CELL := 5
const TRIM_MAX := TRIM_CELL

## 采集半边（场景切片）拆到独立文件，见 incident_cell_slice.gd 顶部说明。
const IncidentCellSlice = preload("res://scripts/game/incident_cell_slice.gd")



## 只要汇总，不落盘。返回结构与 write() 相同，path 为空串。
## bytes 是按未压缩成员体积算的上界（真实 zip 只会更小）。
static func build(context: Dictionary) -> Dictionary:
	var collected := IncidentCellSlice.collect(context)
	if not bool(collected.get("ok", false)):
		return {"ok": false, "path": "", "bytes": 0, "members": [],
			"truncated": [], "reason": String(collected.get("reason", "collect_failed"))}
	var level := TRIM_NONE
	var assembled := _assemble(collected, level)
	var total := _estimated_bytes(assembled)
	# 200 KB 用未压缩体积判：压缩后必然更小，宁可多裁一点也不要超限。
	while total > SOFT_LIMIT_BYTES and level < TRIM_MAX:
		level += 1
		assembled = _assemble(collected, level)
		total = _estimated_bytes(assembled)
	return {
		"ok": true, "path": "", "bytes": total,
		"members": _member_names(assembled),
		"truncated": assembled.get("truncated", []),
		"reason": "",
	}


## 采集 → 裁剪 → 落盘 → 保留策略。失败时 ok=false 并给出 reason，不抛错。
static func write(context: Dictionary) -> Dictionary:
	var collected := IncidentCellSlice.collect(context)
	if not bool(collected.get("ok", false)):
		return {"ok": false, "path": "", "bytes": 0, "members": [],
			"truncated": [], "reason": String(collected.get("reason", "collect_failed"))}
	var dir_path := incidents_dir()
	if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
		return {"ok": false, "path": "", "bytes": 0, "members": [],
			"truncated": [], "reason": "incidents_directory_create_failed:%s" % dir_path}
	var file_path := dir_path.path_join(_file_name(collected))
	# 裁剪看的是真实 zip 体积（deflate 之后），不是未压缩估算：估算只在 build()
	# 里用，落盘时以磁盘上的实际长度为准，避免为了保守而丢掉本可保留的明细。
	var level := TRIM_NONE
	var assembled := _assemble(collected, level)
	while true:
		var manifest_text := _manifest_text(assembled)
		var write_error := _write_zip(file_path, manifest_text,
			assembled.get("members", {}))
		if not write_error.is_empty():
			return {"ok": false, "path": "", "bytes": 0, "members": [],
				"truncated": assembled.get("truncated", []),
				"reason": write_error}
		var size := _file_size(file_path)
		if size <= SOFT_LIMIT_BYTES or level >= TRIM_MAX:
			_enforce_retention(dir_path)
			return {
				"ok": true, "path": file_path, "bytes": size,
				"members": _member_names(assembled),
				"truncated": assembled.get("truncated", []),
				"reason": "",
			}
		level += 1
		assembled = _assemble(collected, level)
	return {"ok": false, "path": "", "bytes": 0, "members": [],
		"truncated": assembled.get("truncated", []),
		"reason": "trim_ladder_exhausted"}


## 事故包目录（返回真实 OS 路径，GM 面板要直接显示）。
static func incidents_dir() -> String:
	if _is_mobile():
		return ProjectSettings.globalize_path("user://incidents")
	# res:// 是 Project/project-keynes，repo 根在它上面两层。
	return ProjectSettings.globalize_path("res://").path_join(
		"..\\..\\tmp").path_join("incidents").simplify_path()


static func _is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") \
		or OS.has_feature("ios")


# ---------------------------------------------------------------------------
# 组装 / 裁剪 / 落盘
# ---------------------------------------------------------------------------

static func _assemble(collected: Dictionary, level: int) -> Dictionary:
	var truncated: Array = []
	var members := {}
	members["incident.json"] = collected.get("incident", {})
	members["witness.json"] = collected.get("witness", {})
	members["world.json"] = collected.get("world", {})
	var cell_slice: Dictionary = _as_dict(collected.get("cell_slice", {})).duplicate(true)
	if level < TRIM_CELL:
		if level >= TRIM_MARKET_LANES and cell_slice.has("market_lanes"):
			cell_slice.erase("market_lanes")
			truncated.append("cell.json:market_lanes")
		if level >= TRIM_PENDING_CONSTRUCTION \
				and cell_slice.has("pending_construction"):
			cell_slice.erase("pending_construction")
			truncated.append("cell.json:pending_construction")
		if level >= TRIM_BUILDINGS and cell_slice.has("buildings"):
			cell_slice.erase("buildings")
			truncated.append("cell.json:buildings")
		cell_slice = _shrink_cell(cell_slice, truncated)
		members["cell.json"] = cell_slice
	else:
		truncated.append("cell.json")
	var commands: Dictionary = _as_dict(collected.get("commands", {}))
	if level >= TRIM_COMMANDS and not commands.is_empty():
		truncated.append("commands.json")
	else:
		members["commands.json"] = commands
	members["hashes.txt"] = _hashes_text(collected.get("hashes", {}))
	return {"members": members, "truncated": truncated,
		"notes": collected.get("notes", []),
		"producer": collected.get("producer", "runtime_forensics.gd")}


## 单格切片自身也要 ≤ 64 KB：先砍 market_lanes 的尾部，再砍建筑组。
static func _shrink_cell(cell_slice: Dictionary, truncated: Array) -> Dictionary:
	if _text_bytes(cell_slice) <= CELL_LIMIT_BYTES:
		return cell_slice
	for limit in [32, 16, 8, 0]:
		if cell_slice.has("market_lanes"):
			var lanes: Array = cell_slice.market_lanes
			if lanes.size() > limit:
				cell_slice["market_lanes"] = lanes.slice(0, limit)
				if not truncated.has("cell.json:market_lanes"):
					truncated.append("cell.json:market_lanes")
		if _text_bytes(cell_slice) <= CELL_LIMIT_BYTES:
			return cell_slice
	for limit in [24, 8, 0]:
		if cell_slice.has("buildings"):
			var rows: Array = cell_slice.buildings
			if rows.size() > limit:
				cell_slice["buildings"] = rows.slice(0, limit)
				if not truncated.has("cell.json:buildings"):
					truncated.append("cell.json:buildings")
		if _text_bytes(cell_slice) <= CELL_LIMIT_BYTES:
			return cell_slice
	return cell_slice


static func _manifest_text(assembled: Dictionary) -> String:
	var members: Dictionary = assembled.get("members", {})
	var files: Array = []
	var build_id := ""
	for name in MEMBER_ORDER:
		if not members.has(name):
			continue
		var bytes := _text_bytes(members[name])
		if name == "incident.json":
			build_id = String(_as_dict(members[name]).get("build_id", ""))
		files.append({
			"name": name,
			"bytes": bytes,
			"sha256": _sha256_hex(members[name]),
		})
	# hashes.txt 是纯文本，其余成员都按 JSON 记账，这里统一用成员真实字节数。
	var manifest := {
		"schema": SCHEMA_VERSION,
		"created_at": Time.get_datetime_string_from_system(),
		"producer": String(assembled.get("producer", "runtime_forensics.gd")),
		"build_id": build_id,
		"files": files,
		"truncated": assembled.get("truncated", []),
		"notes": assembled.get("notes", []),
	}
	return _json_text(manifest)


static func _write_zip(path: String, manifest_text: String,
		members: Dictionary) -> String:
	var packer := ZIPPacker.new()
	var open_error := packer.open(path)
	if open_error != OK:
		return "zip_open_failed:%s" % error_string(open_error)
	var payloads := {"MANIFEST.json": manifest_text}
	payloads.merge(members, true)
	# MANIFEST.json 固定第一个写入（schema §2.2）；之后按 MEMBER_ORDER 顺序，
	# 便于消费者流式读取。
	var order: Array = [MANIFEST_NAME]
	order.append_array(MEMBER_ORDER)
	for name in order:
		if not payloads.has(name):
			continue
		if packer.start_file(String(name)) != OK:
			packer.close()
			return "zip_start_file_failed:%s" % String(name)
		if packer.write_file(_utf8_bytes(payloads[name])) != OK:
			packer.close()
			return "zip_write_file_failed:%s" % String(name)
		if packer.close_file() != OK:
			packer.close()
			return "zip_close_file_failed:%s" % String(name)
	var close_error := packer.close()
	if close_error != OK:
		return "zip_close_failed:%s" % error_string(close_error)
	return ""


## 保留策略：只留最近 KEEP_BUNDLES 份。文件名前缀是 YYYYMMDD_HHMMSS，字典序即时间序。
static func _enforce_retention(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var names: Array = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.ends_with(".pkinc"):
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	if names.size() <= KEEP_BUNDLES:
		return
	names.sort()
	while names.size() > KEEP_BUNDLES:
		var oldest: String = names.pop_front()
		DirAccess.remove_absolute(dir_path.path_join(oldest))


static func _file_name(collected: Dictionary) -> String:
	var stamp := String(collected.get("stamp", ""))
	if stamp.is_empty():
		stamp = Time.get_datetime_string_from_system().replace(":", "").replace(
			"-", "").replace("T", "_")
	var reason := String(_as_dict(collected.get("incident", {})).get("reason", "unknown"))
	reason = _sanitize_file_token(reason)
	var name := "%s_%s.pkinc" % [stamp, reason]
	if FileAccess.file_exists(incidents_dir().path_join(name)):
		# 同一秒内重复触发（fatal 复抓、GM 连点）不能覆盖上一份现场。
		name = "%s_%s_%d.pkinc" % [stamp, reason, Time.get_ticks_usec()]
	return name


static func _sanitize_file_token(value: String) -> String:
	var out := ""
	for index in range(value.length()):
		var ch := value[index]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
				or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		else:
			out += "_"
	if out.is_empty():
		return "unknown"
	return out.substr(0, 96)


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

static func _hashes_text(hashes: Dictionary) -> String:
	# 纯文本 key=value 每行一个（schema §2.7）。
	return "\n".join([
		"state_hash=%d" % int(hashes.get("state_hash", 0)),
		"economy_state_hash=%d" % int(hashes.get("economy_state_hash", 0)),
		"ledger_hash=%d" % int(hashes.get("ledger_hash", 0)),
		"catalog_hash=%d" % int(hashes.get("catalog_hash", 0)),
	]) + "\n"


static func _json_text(value) -> String:
	return JSON.stringify(_sanitize(value))


## JSON 不允许 NaN/Infinity（schema §1）；把非有限浮点压成 0.0。
static func _sanitize(value):
	if value is float:
		return value if is_finite(value) else 0.0
	if value is Dictionary:
		var out := {}
		for key in value.keys():
			out[key] = _sanitize(value[key])
		return out
	if value is Array:
		var out: Array = []
		for item in value:
			out.append(_sanitize(item))
		return out
	return value


static func _text_bytes(value) -> int:
	return _utf8_bytes(value).size()


static func _utf8_bytes(value) -> PackedByteArray:
	if value is String:
		return value.to_utf8_buffer()
	return _json_text(value).to_utf8_buffer()


static func _sha256_hex(value) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(_utf8_bytes(value))
	return context.finish().hex_encode()


static func _estimated_bytes(assembled: Dictionary) -> int:
	var members: Dictionary = assembled.get("members", {})
	var total := _text_bytes(_manifest_text(assembled))
	for name in members.keys():
		total += _text_bytes(members[name])
	return total


static func _member_names(assembled: Dictionary) -> Array:
	var names: Array = []
	var members: Dictionary = assembled.get("members", {})
	for name in MEMBER_ORDER:
		if members.has(name):
			names.append(name)
	return names


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file.close()
	return size



static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}

