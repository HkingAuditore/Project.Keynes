extends SceneTree

## R3-3 / R3-4：离线重放一份 `.pkinc` 事故包。
##
## 契约唯一真相：`docs/runtime/incident-bundle-schema.md`（schema v1）。本脚本是
## 消费者，不生产包：解 zip → 校验 MANIFEST.schema 与每个成员的 sha256 →
## 组装 incident 字典 → 交给 `DCWorldExt::economy_replay_incident()`（R3-1/R3-2，
## C++ 侧并行落地）→ 打印 `[incident-replay/result]`。
##
## 用法：
##   godot --headless --path Project/project-keynes \
##     --script res://tests/runtime/incident_replay.gd \
##     -- --incident tmp/incidents/x.pkinc [--emit-fixture] [--json]
##
## 退出码（与包契约 §4 对齐）：0 reproduced / 1 not reproduced / 2 包或环境问题。
## **缺绑定不是失败**：`economy_replay_incident` 还没落地时打印
## `missing_binding:economy_replay_incident` 并 exit 2（环境问题，不是「没复现」）。
##
## 传给 C++ 的字典形状（这里定死，方便两侧独立实现）：
##   `incident.json` 的字段全部置顶（assert_id/reason/kind/stage/day/epoch_id/
##   type_id/force_injected/world_id/build_id/captured_at），`cell` 换成 cell.json 的
##   切片字典（R3-1 的 `replay_incident` 就按 `incident["cell"]` 取切片，切片里自带
##   `cell` 索引），失败格索引另存 `cell_index`；再加 `witness`（witness.json）、
##   `cell_slice`（同 `cell` 的别名）、`commands`、`world`、`hashes`，以及把切片数组
##   平铺出来的 `cohorts` / `merchants` / `buildings` / `pending_construction` /
##   `market_lanes`（两种读法都能拿到，避免为键名吵架）。

## n-1 兼容：schema 升级到 pkinc/2 时消费者仍要能读 pkinc/1（包契约 §3.3）。
const ACCEPTED_SCHEMAS := ["pkinc/1", "pkinc/2"]
const REQUIRED_MEMBERS := [
	"incident.json", "witness.json", "cell.json", "world.json", "hashes.txt",
]
const TEXT_MEMBERS := ["hashes.txt"]
const CELL_ARRAYS := [
	"cohorts", "merchants", "buildings", "pending_construction", "market_lanes",
]

var _result := {
	"reproduced": false,
	"assert_id": "",
	"reason": "",
	"diff": [],
}
var _json_only := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_json_only = bool(args.get("json", false))
	var requested := String(args.get("incident", ""))
	if requested.is_empty():
		_finish(2, "missing_argument:--incident")
		return
	var path := _resolve_path(requested)
	if path.is_empty():
		_finish(2, "incident_bundle_not_found:%s" % requested)
		return
	_note("[incident-replay] bundle=%s" % path)
	var bundle := _read_bundle(path)
	if not bool(bundle.get("ok", false)):
		_finish(2, String(bundle.get("reason", "bundle_unreadable")))
		return
	var incident: Dictionary = bundle["incident"]
	_result["bundle"] = path
	_result["schema"] = String(bundle["schema"])
	_result["assert_id"] = String(incident.get("assert_id", ""))
	_result["reason"] = String(incident.get("reason", ""))
	_result["build_id"] = String(incident.get("build_id", ""))
	_result["day"] = int(incident.get("day", -1))
	_result["cell"] = int(incident.get("cell", -1))
	_result["members"] = bundle["members"]
	_result["members_verified"] = int(bundle.get("members_verified", 0))
	_note("[incident-replay] schema=%s reason=%s day=%d cell=%d members=%d" % [
		_result["schema"], _result["reason"], _result["day"], _result["cell"],
		int(bundle["members"])])

	var incident_input := _build_incident_input(path, String(bundle["schema"]),
		incident, bundle["witness"], bundle["cell"], bundle["commands"],
		bundle["world"], bundle["hashes"])

	# --emit-fixture 与 C++ 绑定无关：只要能读到 cell.json 就能产出片段，
	# 所以放在调用绑定之前，缺绑定时也能落一份可用于回归的夹具。
	if bool(args.get("emit_fixture", false)):
		_emit_fixture(path, incident_input)

	var binding := _replay_binding()
	if binding.has("reason"):
		# 绑定缺失：环境问题。不要把 missing_binding 混进 reproduced=false。
		_note("[incident-replay] %s" % String(binding["reason"]))
		_finish(2, String(binding["reason"]))
		return
	var ext: Object = binding["world_ext"]
	var outcome: Variant = ext.call("economy_replay_incident", incident_input)
	if not outcome is Dictionary:
		_finish(2, "replay_result_not_dictionary")
		return
	var replay: Dictionary = outcome
	if not replay.has("reproduced"):
		# 绑定存在但形状不对：这是版本不匹配（环境问题），不是「没复现」。
		_finish(2, "replay_result_contract_missing_reproduced")
		return

	var reproduced := bool(replay.get("reproduced", false))
	_result["reproduced"] = reproduced
	if not String(replay.get("assert_id", "")).is_empty():
		_result["assert_id"] = String(replay["assert_id"])
	_result["replay_reason"] = String(replay.get("reason", ""))
	_result["diff"] = replay.get("diff", [])
	# uncompared 必须一起透出：判据里排除了哪些字段是审计信息，藏起来就等于
	# 悄悄放宽「逐字段严格相等」（见 economy_invariant_probe.cpp 的比较段注释）。
	for key in ["witness_before", "witness_after", "expected_reason", "ok",
			"error", "detail", "missing", "assert_fired", "reason_actual",
			"assert_id_actual", "build_id_actual", "uncompared", "fixture_notes"]:
		if replay.has(key):
			_result[key] = replay[key]
	_note("[incident-replay] reproduced=%s replay_reason=%s diff=%d" % [
		reproduced, _result["replay_reason"],
		(_result["diff"] as Array).size() if _result["diff"] is Array else -1])
	if not String(replay.get("detail", "")).is_empty():
		_note("[incident-replay] detail=%s" % String(replay["detail"]))
	if replay.get("missing", []) is Array and not (replay["missing"] as Array).is_empty():
		_note("[incident-replay] missing=%s" % JSON.stringify(replay["missing"]))
	_finish(0 if reproduced else 1)


## zip → 校验 → 解析。失败时 reason 必须点名具体成员（契约 §2.1：不允许只说包损坏）。
func _read_bundle(path: String) -> Dictionary:
	var reader := ZIPReader.new()
	var open_error := reader.open(path)
	if open_error != OK:
		return {"ok": false, "reason": "bundle_not_zip:%d:%s" % [open_error,
			error_string(open_error)]}
	var names := reader.get_files()
	if names.is_empty():
		reader.close()
		return {"ok": false, "reason": "bundle_empty"}
	var manifest_bytes := _member(reader, names, "MANIFEST.json")
	if manifest_bytes.is_empty():
		reader.close()
		return {"ok": false, "reason": "missing_member:MANIFEST.json"}
	var manifest := _parse_json(manifest_bytes, "MANIFEST.json")
	if manifest.has("__error"):
		reader.close()
		return {"ok": false, "reason": String(manifest["__error"])}
	var schema := String(manifest.get("schema", ""))
	if schema not in ACCEPTED_SCHEMAS:
		reader.close()
		return {"ok": false, "reason": "unsupported_schema:%s" % schema}

	# MANIFEST.files 必须覆盖每个成员，且 sha256 / 字节数都要对上。
	var checks: Array = []
	var declared_value: Variant = manifest.get("files", [])
	var declared: Array = declared_value if declared_value is Array else []
	var missing := PackedStringArray()
	var mismatched := PackedStringArray()
	for entry in declared:
		if not entry is Dictionary:
			reader.close()
			return {"ok": false, "reason": "manifest_entry_invalid"}
		var name := String(entry.get("name", ""))
		var bytes := _member(reader, names, name)
		var check := {"name": name, "declared_bytes": int(entry.get("bytes", -1)),
			"actual_bytes": bytes.size()}
		if bytes.is_empty():
			missing.append(name)
			check["ok"] = false
			checks.append(check)
			continue
		var digest := _sha256(bytes)
		var expected := String(entry.get("sha256", "")).to_lower()
		check["sha256"] = digest
		check["sha256_ok"] = digest == expected
		check["bytes_ok"] = bytes.size() == int(entry.get("bytes", -1))
		check["ok"] = bool(check["sha256_ok"]) and bool(check["bytes_ok"])
		checks.append(check)
		if not bool(check["sha256_ok"]):
			mismatched.append(name)
	if not missing.is_empty():
		reader.close()
		return {"ok": false, "reason": "missing_member:%s" % ", ".join(missing)}
	if not mismatched.is_empty():
		reader.close()
		return {"ok": false, "reason": "sha256_mismatch:%s" % ", ".join(mismatched)}

	# 必需成员：即使 MANIFEST 没声明也必须存在（否则消费方只会读到空对象）。
	for name in REQUIRED_MEMBERS:
		if not name in names:
			reader.close()
			return {"ok": false, "reason": "missing_member:%s" % name}

	var incident := _parse_json(_member(reader, names, "incident.json"),
		"incident.json")
	if incident.has("__error"):
		reader.close()
		return {"ok": false, "reason": String(incident["__error"])}
	if String(incident.get("reason", "")).is_empty():
		# 契约 §2.2：assert_id 可以为空（台账未登记），reason 必须非空。
		reader.close()
		return {"ok": false, "reason": "incident_reason_missing"}
	var witness := _parse_json(_member(reader, names, "witness.json"),
		"witness.json")
	if witness.has("__error"):
		reader.close()
		return {"ok": false, "reason": String(witness["__error"])}
	var cell := _parse_json(_member(reader, names, "cell.json"), "cell.json")
	if cell.has("__error"):
		reader.close()
		return {"ok": false, "reason": String(cell["__error"])}
	var world := _parse_json(_member(reader, names, "world.json"), "world.json")
	if world.has("__error"):
		reader.close()
		return {"ok": false, "reason": String(world["__error"])}
	var commands := {}
	if "commands.json" in names:
		commands = _parse_json(_member(reader, names, "commands.json"),
			"commands.json")
		if commands.has("__error"):
			reader.close()
			return {"ok": false, "reason": String(commands["__error"])}
	var hashes := _parse_hashes(_member(reader, names, "hashes.txt"))
	reader.close()
	# 逐成员明细只在人读模式打印；单行结果里只留汇总，避免把机读结果撑成
	# 十几行（CI 解析器只认这一行）。
	for check in checks:
		_note("[incident-replay/member] %s bytes=%d sha256=%s" % [
			String(check.get("name", "")), int(check.get("actual_bytes", -1)),
			"ok" if bool(check.get("ok", false)) else "MISMATCH"])
	return {"ok": true, "schema": schema, "incident": incident,
		"witness": witness, "cell": cell, "commands": commands,
		"world": world, "hashes": hashes, "members": names.size(),
		"members_verified": checks.size()}


func _member(reader: ZIPReader, names: PackedStringArray, name: String) -> PackedByteArray:
	if not name in names:
		return PackedByteArray()
	return reader.read_file(name)


func _parse_json(bytes: PackedByteArray, member: String) -> Dictionary:
	if bytes.is_empty():
		return {"__error": "member_empty:%s" % member}
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return {"__error": "json_parse_failed:%s:%s" % [member,
			json.get_error_message()]}
	if not json.data is Dictionary:
		return {"__error": "json_not_object:%s" % member}
	return json.data


## hashes.txt：每行 `key=value`，空行与 `#` 注释跳过。
func _parse_hashes(bytes: PackedByteArray) -> Dictionary:
	var out := {}
	if bytes.is_empty():
		return out
	for line in bytes.get_string_from_utf8().split("\n"):
		var text := line.strip_edges()
		if text.is_empty() or text.begins_with("#"):
			continue
		var at := text.find("=")
		if at <= 0:
			continue
		out[text.substr(0, at).strip_edges()] = text.substr(at + 1).strip_edges()
	return out


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func _build_incident_input(path: String, schema: String, incident: Dictionary,
		witness: Dictionary, cell: Dictionary, commands: Dictionary,
		world: Dictionary, hashes: Dictionary) -> Dictionary:
	var out := incident.duplicate(true)
	out["schema"] = schema
	out["bundle"] = path
	out["witness"] = witness
	# R3-1 的 replay_incident 用 `incident["cell"]` 取失败格切片（它自己会再读切片里
	# 的 `cell` 索引），所以这里必须放字典而不是 incident.json 的那个整数。
	out["cell_index"] = int(incident.get("cell", -1))
	out["cell"] = cell
	out["cell_slice"] = cell
	out["commands"] = commands
	out["world"] = world
	out["hashes"] = hashes
	# 切片数组同时平铺一份：不同消费者对键名的读法不一致时都能拿到。
	for key in CELL_ARRAYS:
		out[key] = cell.get(key, [])
	return out


## 探测 R3-2 的绑定。返回 {world_ext} 或 {reason}。
func _replay_binding() -> Dictionary:
	if not ClassDB.class_exists("DCWorldExt"):
		return {"reason": "missing_binding:DCWorldExt"}
	var ext: Object = DCWorldExt.new()
	var method := "economy_replay_incident"
	var bound := ClassDB.class_has_method("DCWorldExt", method) \
		or ext.has_method(method)
	if not bound:
		return {"reason": "missing_binding:%s" % method}
	return {"world_ext": ext}


# ---------------------------------------------------------------------------
# --emit-fixture：cell.json → 可独立编译的 C++ 片段（R3-4）
# ---------------------------------------------------------------------------

func _emit_fixture(bundle_path: String, incident_input: Dictionary) -> void:
	var snippet := _fixture_cpp(bundle_path, incident_input)
	var fixture_path := bundle_path.get_basename() + ".fixture.cpp"
	var file := FileAccess.open(fixture_path, FileAccess.WRITE)
	if file == null:
		_result["fixture_error"] = "fixture_open_failed:%s" % error_string(
			FileAccess.get_open_error())
		return
	file.store_string(snippet)
	file.close()
	_result["fixture_path"] = ProjectSettings.globalize_path(fixture_path)
	# --json 时只留单行结果，片段只落文件（否则 stdout 不再是纯 JSON）。
	if not _json_only:
		print(snippet)
	_note("[incident-replay] fixture=%s" % _result["fixture_path"])


func _fixture_cpp(bundle_path: String, incident: Dictionary) -> String:
	var assert_id := String(incident.get("assert_id", ""))
	var reason := String(incident.get("reason", ""))
	var label := assert_id if not assert_id.is_empty() else reason
	var symbol := "k" + _pascal(assert_id if not assert_id.is_empty() else reason)
	var witness: Dictionary = incident.get("witness", {})
	var cell: Dictionary = incident.get("cell_slice", {})
	var lines := PackedStringArray()
	lines.append("// fixture: %s from %s" % [label, bundle_path])
	lines.append("// Generated by tests/runtime/incident_replay.gd --emit-fixture at %s (R3-4)." %
		Time.get_datetime_string_from_system())
	lines.append("// Review by hand, then merge into gdext/src/economy_invariant_probe.cpp.")
	lines.append("// The snippet defines its own POD rows, so it compiles as a standalone TU.")
	lines.append("// reason=%s stage=%s kind=%s" % [
		reason, String(incident.get("stage", "")), String(incident.get("kind", ""))])
	lines.append("// world=%s" % JSON.stringify(incident.get("world", {})))
	lines.append("// hashes=%s" % JSON.stringify(incident.get("hashes", {})))
	# 自带 include，片段可以单独编译（MSVC `cl /Zs`、gcc `-fsyntax-only`）。
	lines.append("#include <cstdint>")
	lines.append("")
	lines.append("namespace pk_fixture {")
	lines.append("")
	lines.append("struct WitnessField { const char *name; int64_t i64; double f64; };")
	lines.append("struct CohortRow { int64_t signature; int64_t population; int64_t funds; int64_t employed; int64_t satisfaction; int64_t profession; };")
	lines.append("struct MerchantRow { int64_t slot; int64_t cash; };")
	lines.append("struct BuildingRow { int64_t type_id; int64_t units; int64_t filled_owner; int64_t debt_principal; };")
	lines.append("struct PendingConstructionRow { int64_t type_id; int64_t units; int64_t required_good; int64_t required_qty; int64_t stock; };")
	lines.append("struct MarketLaneRow { int64_t good_id; int64_t price; int64_t stock; };")
	lines.append("")
	lines.append("struct FixtureRow {")
	lines.append("\tconst char *assert_id;")
	lines.append("\tconst char *reason;")
	lines.append("\tconst char *stage;")
	lines.append("\tint64_t day;")
	lines.append("\tint64_t epoch_id;")
	lines.append("\tint64_t cell;")
	lines.append("\tconst WitnessField *witness;")
	lines.append("\tint64_t witness_count;")
	lines.append("\tconst CohortRow *cohorts;")
	lines.append("\tint64_t cohort_count;")
	lines.append("\tconst MerchantRow *merchants;")
	lines.append("\tint64_t merchant_count;")
	lines.append("\tconst BuildingRow *buildings;")
	lines.append("\tint64_t building_count;")
	lines.append("\tconst PendingConstructionRow *pending_construction;")
	lines.append("\tint64_t pending_count;")
	lines.append("\tconst MarketLaneRow *market_lanes;")
	lines.append("\tint64_t market_lane_count;")
	lines.append("};")
	lines.append("")

	# witness：整数进 i64，浮点进 f64，字符串/其余类型只写注释（保持可编译）。
	var witness_rows := PackedStringArray()
	var witness_notes := PackedStringArray()
	for key in witness.keys():
		var value: Variant = witness[key]
		if value is bool:
			witness_rows.append("\t{\"%s\", %d, 0.0}," % [key, 1 if value else 0])
		elif value is int:
			witness_rows.append("\t{\"%s\", %d, 0.0}," % [key, int(value)])
		elif value is float:
			# JSON 数字统一解析成 float，整数 witness 要靠「是否整值」还原到 i64，
			# 否则台账声明的 i32/i64 字段在夹具里全变成 double。
			var as_float := float(value)
			if is_equal_approx(as_float, floorf(as_float)) \
					and absf(as_float) < 9.2e18:
				witness_rows.append("\t{\"%s\", %d, 0.0}," % [key, int(as_float)])
			else:
				witness_rows.append("\t{\"%s\", 0, %s}," % [key,
					String.num(as_float, 6)])
		else:
			witness_notes.append("// witness str %s=%s" % [key,
				_c_string(str(value))])
	lines.append("static const WitnessField k%sWitness[] = {" % symbol.substr(1))
	if witness_rows.is_empty():
		lines.append("\t{\"\", 0, 0.0},")
	else:
		lines.append_array(witness_rows)
	lines.append("};")
	lines.append("")
	for note in witness_notes:
		lines.append(note)
	if not witness_notes.is_empty():
		lines.append("")

	lines.append("static const CohortRow k%sCohorts[] = {" % symbol.substr(1))
	lines.append_array(_cohort_rows(_array(cell, "cohorts")))
	lines.append("};")
	lines.append("static const MerchantRow k%sMerchants[] = {" % symbol.substr(1))
	lines.append_array(_merchant_rows(_array(cell, "merchants")))
	lines.append("};")
	lines.append("static const BuildingRow k%sBuildings[] = {" % symbol.substr(1))
	lines.append_array(_building_rows(_array(cell, "buildings")))
	lines.append("};")
	lines.append("static const PendingConstructionRow k%sPending[] = {" % symbol.substr(1))
	lines.append_array(_pending_rows(_array(cell, "pending_construction")))
	lines.append("};")
	lines.append("static const MarketLaneRow k%sMarketLanes[] = {" % symbol.substr(1))
	lines.append_array(_market_lane_rows(_array(cell, "market_lanes")))
	lines.append("};")
	lines.append("")
	lines.append("static const FixtureRow %s = {" % symbol)
	lines.append("\t\"%s\"," % _c_string(assert_id))
	lines.append("\t\"%s\"," % _c_string(reason))
	lines.append("\t\"%s\"," % _c_string(String(incident.get("stage", ""))))
	lines.append("\t%d," % int(incident.get("day", -1)))
	lines.append("\t%d," % int(incident.get("epoch_id", -1)))
	lines.append("\t%d," % int(incident.get("cell", -1)))
	lines.append("\tk%sWitness, %d," % [symbol.substr(1), witness.size()])
	lines.append("\tk%sCohorts, %d," % [symbol.substr(1),
		_array(cell, "cohorts").size()])
	lines.append("\tk%sMerchants, %d," % [symbol.substr(1),
		_array(cell, "merchants").size()])
	lines.append("\tk%sBuildings, %d," % [symbol.substr(1),
		_array(cell, "buildings").size()])
	lines.append("\tk%sPending, %d," % [symbol.substr(1),
		_array(cell, "pending_construction").size()])
	lines.append("\tk%sMarketLanes, %d," % [symbol.substr(1),
		_array(cell, "market_lanes").size()])
	lines.append("};")
	lines.append("")
	lines.append("} // namespace pk_fixture")
	lines.append("")
	return "\n".join(lines)


func _array(source: Dictionary, key: String) -> Array:
	var value: Variant = source.get(key, [])
	return value if value is Array else []


func _cohort_rows(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in rows:
		if not row is Dictionary:
			continue
		out.append(("\t{%d, %d, %d, %d, %d, %d}," % [
			int(row.get("signature", 0)), int(row.get("population", 0)),
			int(row.get("funds", 0)), int(row.get("employed", 0)),
			int(row.get("satisfaction", 0)), int(row.get("profession", 0))]))
	# 空列表也要留一个元素：C++ 里零长数组字面量不是标准写法。
	if out.is_empty():
		out.append("\t{0, 0, 0, 0, 0, 0},")
	return out


func _merchant_rows(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in rows:
		if not row is Dictionary:
			continue
		out.append("\t{%d, %d}," % [int(row.get("slot", 0)),
			int(row.get("cash", 0))])
	if out.is_empty():
		out.append("\t{0, 0},")
	return out


func _building_rows(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in rows:
		if not row is Dictionary:
			continue
		out.append(("\t{%d, %d, %d, %d}," % [
			int(row.get("type_id", 0)), int(row.get("units", 0)),
			int(row.get("filled_owner", 0)), int(row.get("debt_principal", 0))]))
	if out.is_empty():
		out.append("\t{0, 0, 0, 0},")
	return out


func _pending_rows(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in rows:
		if not row is Dictionary:
			continue
		out.append(("\t{%d, %d, %d, %d, %d}," % [
			int(row.get("type_id", 0)), int(row.get("units", 0)),
			int(row.get("required_good", 0)), int(row.get("required_qty", 0)),
			int(row.get("stock", 0))]))
	if out.is_empty():
		out.append("\t{0, 0, 0, 0, 0},")
	return out


func _market_lane_rows(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for row in rows:
		if not row is Dictionary:
			continue
		out.append("\t{%d, %d, %d}," % [int(row.get("good_id", 0)),
			int(row.get("price", 0)), int(row.get("stock", 0))])
	if out.is_empty():
		out.append("\t{0, 0, 0},")
	return out


## "INV-ECON-0042" → "InvEcon0042"（数字段原样保留）。
func _pascal(text: String) -> String:
	var out := ""
	for part in text.replace("_", "-").split("-", false):
		if part.is_empty():
			continue
		out += part.substr(0, 1).to_upper() + part.substr(1).to_lower()
	return out if not out.is_empty() else "Unknown"


## C++ 字符串字面量转义：只允许可打印 ASCII，其余一律 \xNN。
func _c_string(text: String) -> String:
	var out := ""
	for index in text.length():
		var code := text.unicode_at(index)
		if code >= 32 and code < 127 and code != 34 and code != 92:
			out += String.chr(code)
		else:
			out += "\\x%02x" % (code & 0xFF)
	return out


# ---------------------------------------------------------------------------

func _parse_args(user_args: PackedStringArray) -> Dictionary:
	var out := {}
	var index := 0
	while index < user_args.size():
		var token := String(user_args[index])
		var value := ""
		if token.contains("="):
			value = token.substr(token.find("=") + 1)
			token = token.substr(0, token.find("="))
		match token:
			"--incident":
				if value.is_empty() and index + 1 < user_args.size():
					index += 1
					value = String(user_args[index])
				out["incident"] = value
			"--emit-fixture":
				out["emit_fixture"] = true
			"--json":
				out["json"] = true
			_:
				pass
		index += 1
	return out


## 相对路径按进程 CWD 解析；CWD 不在仓库根时再按 res:// 往上两级兜底。
func _resolve_path(path: String) -> String:
	if FileAccess.file_exists(path):
		return path
	var repo_root := ProjectSettings.globalize_path("res://").path_join("..")
	repo_root = repo_root.path_join("..").simplify_path()
	var candidate := repo_root.path_join(path).simplify_path()
	if FileAccess.file_exists(candidate):
		return candidate
	return ""


func _note(text: String) -> void:
	if not _json_only:
		print(text)


## 单行机读结果。前缀不要改：验收命令与 CI 按这个前缀解析。
## `reason` 字段在成功复现时保留事故包的 reason（它才是「哪个断言」的答案），
## 包/环境问题的原因写进 `error`。
func _finish(exit_code: int, error: String = "") -> void:
	if not error.is_empty():
		_result["error"] = error
		if String(_result["reason"]).is_empty():
			_result["reason"] = error
	_result["exit_code"] = exit_code
	print("[incident-replay/result] %s" % JSON.stringify(_result))
	quit(exit_code)
