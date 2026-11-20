extends RefCounted

## 调用方一律用 preload 引用本文件，不要依赖 class_name 全局注册：新脚本在编辑器
## 重新扫描之前不在 global_script_class_cache 里，无头跑测试会整片 Parse Error。
## （同 runtime_forensics.gd 顶部注释。）

## `.pkinc` 事故包的**采集**半边（schema v1）：把运行时的 generator / facade /
## 原生查询摊平成「成员数据」，之后的裁剪与打包只读这份快照。
##
## 与 incident_bundle.gd（组装 / 裁剪 / 落盘）拆开是因为单文件顶到了 size ratchet
## 的 800 行阈值：采集要认识运行时对象，打包只认字典与字节，两者的改动理由不同。
##
## 契约唯一真相是 docs/runtime/incident-bundle-schema.md，本文件不自行改字段名。
## 原则：只用 facade 已存在的公开查询方法，拿不到的字段如实记 missing，绝不造假数据。

# 采集上限：单格数据本身也要有界，否则一份异常现场能把窗口撑爆。
const MAX_COHORTS := 64
const MAX_MERCHANTS := 32
const MAX_BUILDINGS := 96
const MAX_PENDING := 32
const MAX_MARKET_LANES := 96
const MAX_RECENT_DAYS := 8
const MAX_COMMAND_ROWS := 128


# ---------------------------------------------------------------------------
# 采集
# ---------------------------------------------------------------------------

## 把上下文摊平成「成员数据」，之后的裁剪与打包只读这份快照。
## context 可选键：
##   generator / economy_report / country_report / clock       运行时对象
##   reason / kind / stage / day / epoch_id / cell / type_id    事件字段
##   assert_id / force_injected / producer                      台账字段
##   world / hashes / witness / cell_slice / commands           调用方已备好的数据
static func collect(context: Dictionary) -> Dictionary:
	var notes: Array = []
	var generator = context.get("generator", null)
	var report: Dictionary = _as_dict(context.get("economy_report", {}))
	if report.is_empty():
		report = _report(generator, "get_economy_report")
	var country_report: Dictionary = _as_dict(context.get("country_report", {}))
	if country_report.is_empty():
		country_report = _report(generator, "get_country_report")
	var fatal_context := _as_dict(report.get("fatal_context", {}))

	var world := _collect_world(context, generator, report, country_report, notes)
	var build_id := String(report.get("build_id", context.get("build_id", "")))
	var captured_at := String(context.get("captured_at",
		Time.get_datetime_string_from_system()))
	var day := int(context.get("day", report.get("current_day", -1)))
	var epoch_id := int(context.get("epoch_id", report.get("epoch_id", day)))
	var cell := _resolve_cell(context, fatal_context)
	var type_id := _resolve_type_id(context, fatal_context)
	var reason := String(context.get("reason", report.get("fatal_reason", "")))
	if reason.is_empty():
		reason = "unknown"
	var fatal := bool(report.get("fatal", false))
	var kind := String(context.get("kind", "fatal" if fatal else "manual"))
	var stage := String(context.get("stage", report.get("stage", "")))
	var assert_id := String(context.get("assert_id",
		fatal_context.get("assert_id", "")))
	var force_injected := bool(context.get("force_injected",
		fatal_context.get("force_injected", false)))
	var world_id := "%d|%dx%d" % [
		int(world.get("seed", 0)), int(world.get("width", 0)),
		int(world.get("height", 0))]

	var incident := {
		"assert_id": assert_id,
		"reason": reason,
		"kind": kind,
		"stage": stage,
		"day": day,
		"epoch_id": epoch_id,
		"build_id": build_id,
		"world_id": world_id,
		"captured_at": captured_at,
		"cell": cell,
		"type_id": type_id,
		"force_injected": force_injected,
	}
	var witness := _collect_witness(context, fatal_context, notes)
	var cell_slice: Dictionary = _as_dict(context.get("cell_slice", {}))
	if cell_slice.is_empty():
		cell_slice = _collect_cell(generator, cell, notes)
	var commands: Dictionary = _as_dict(context.get("commands", {}))
	if commands.is_empty():
		commands = _collect_commands(report, epoch_id, notes)
	var hashes := _collect_hashes(context, generator, report, country_report, notes)
	return {
		"ok": true,
		"reason": "",
		"incident": incident,
		"witness": witness,
		"cell_slice": cell_slice,
		"commands": commands,
		"world": world,
		"hashes": hashes,
		"notes": notes,
		"producer": String(context.get("producer", "runtime_forensics.gd")),
		"stamp": captured_at.replace(":", "").replace("-", "").replace("T", "_"),
	}


## world.json：尺寸/种子/编目哈希/国家数。拿不到的键保留中性默认值并记 missing。
static func _collect_world(context: Dictionary, generator, report: Dictionary,
		country_report: Dictionary, notes: Array) -> Dictionary:
	var source: Dictionary = _as_dict(context.get("world", {}))
	var seed_value := int(source.get("seed", 0))
	var width := int(source.get("width", 0))
	var height := int(source.get("height", 0))
	if generator != null:
		if seed_value == 0:
			var generator_seed = generator.get("_last_seed")
			if generator_seed != null:
				seed_value = int(generator_seed)
	if seed_value == 0:
		notes.append("missing:world.seed")
	if width <= 0 or height <= 0:
		notes.append("missing:world.width")
		notes.append("missing:world.height")
	var formal_start := bool(source.get("formal_start", false))
	if not source.has("formal_start"):
		# 正式开局标记没有运行时事实来源（C++/GDScript 都没有这个键），
		# 不让 collector 猜：如实记 missing，值留 false。
		notes.append("missing:world.formal_start")
	var catalog_hashes := _as_dict(source.get("catalog_hashes", {}))
	if not catalog_hashes.has("economy"):
		catalog_hashes["economy"] = int(report.get("catalog_hash", 0))
	if not catalog_hashes.has("country"):
		catalog_hashes["country"] = int(country_report.get("catalog_hash", 0))
	var country_count := int(source.get("country_count",
		country_report.get("country_count", 0)))
	return {
		"seed": seed_value,
		"width": width,
		"height": height,
		"formal_start": formal_start,
		"catalog_hashes": catalog_hashes,
		"country_count": country_count,
	}


## hashes.txt：state_hash / economy_state_hash / ledger_hash / catalog_hash。
static func _collect_hashes(context: Dictionary, _generator, report: Dictionary,
		country_report: Dictionary, notes: Array) -> Dictionary:
	var source: Dictionary = _as_dict(context.get("hashes", {}))
	var state_hash := int(source.get("state_hash",
		country_report.get("state_hash", 0)))
	var economy_state_hash := int(source.get("economy_state_hash", 0))
	if not source.has("economy_state_hash"):
		# get_economy_state_hash() 是 economy 模块的原生绑定，economy_facade 没有
		# 包装它，scripts/game 直接调会越过模块访问边界（CI 的
		# check_script_native_access 会拦）。调用方可以从 context.hashes 传真实值；
		# 拿不到时按 schema §2.7 的样例写 0，并如实记 missing。
		notes.append("missing:hashes.economy_state_hash")
	var ledger_hash := int(source.get("ledger_hash", 0))
	if not source.has("ledger_hash"):
		# 经济运行时的账本哈希只存在于 POD/恢复校验内部，没有公开查询方法；
		# 不新增 C++ 绑定，这里只能如实写 0。
		notes.append("missing:hashes.ledger_hash")
	var catalog_hash := int(source.get("catalog_hash",
		report.get("catalog_hash", report.get("building_catalog_hash", 0))))
	return {
		"state_hash": state_hash,
		"economy_state_hash": economy_state_hash,
		"ledger_hash": ledger_hash,
		"catalog_hash": catalog_hash,
	}


## witness.json：优先用台账声明的 witness（C++ fatal_context_report 的 witness 键），
## 没有就退化成 fatal_context 里的扁平标量子集（schema §2.3）。
static func _collect_witness(context: Dictionary, fatal_context: Dictionary,
		notes: Array) -> Dictionary:
	var witness: Dictionary = _as_dict(context.get("witness", {}))
	if witness.is_empty():
		witness = _as_dict(fatal_context.get("witness", {}))
	if not witness.is_empty():
		return witness
	for key in fatal_context.keys():
		var value = fatal_context[key]
		if value is Dictionary or value is Array:
			continue
		if value is PackedInt32Array or value is PackedInt64Array \
				or value is PackedStringArray or value is PackedByteArray:
			continue
		witness[String(key)] = value
	if witness.is_empty():
		notes.append("missing:witness")
	else:
		notes.append("witness_source:fatal_context_flat")
	return witness


## cell.json：失败格切片。只用 facade 已存在的公开查询方法，不新增 C++ 绑定。
static func _collect_cell(generator, cell: int, notes: Array) -> Dictionary:
	var out := {"cell": cell}
	if cell < 0:
		notes.append("missing:cell")
		return out
	var economy = _facade(generator, "get_economy_facade")
	if economy == null:
		notes.append("missing:economy_facade")
		return out

	# 人口/阶层行。include_details=false 跳过需求预览与逐笔结算明细，
	# 那些数组对定位 fatal 没有帮助，只会把包撑大。
	var population := _call(economy, "population_cell_snapshot", [cell, false])
	if not bool(population.get("ok", false)):
		notes.append("missing:cohorts")
	else:
		var rows: Array = []
		var signatures: PackedInt32Array = _packed_i32(population.get("signature_ids"))
		var professions: PackedInt32Array = _packed_i32(population.get("profession_ids"))
		var populations: PackedInt64Array = _packed_i64(population.get("populations"))
		var funds: PackedInt64Array = _packed_i64(population.get("funds_by_cohort"))
		var satisfaction: PackedInt32Array = _packed_i32(
			population.get("satisfaction_by_cohort_q16"))
		var owner_employed: PackedInt64Array = _packed_i64(
			population.get("owner_employed_by_cohort"))
		var employee_employed: PackedInt64Array = _packed_i64(
			population.get("employee_employed_by_cohort"))
		var merchant_flags := PackedByteArray()
		if population.get("merchant_flags") is PackedByteArray:
			merchant_flags = population.get("merchant_flags")
		var handles: PackedInt64Array = _packed_i64(population.get("handles"))
		var count := mini(populations.size(), MAX_COHORTS)
		var merchants: Array = []
		for index in range(count):
			var employed := _at_i64(owner_employed, index) + _at_i64(employee_employed, index)
			rows.append({
				"signature": _at_i32(signatures, index),
				"population": _at_i64(populations, index),
				"funds": _at_i64(funds, index),
				"employed": employed,
				"satisfaction": _q16_percent(_at_i32(satisfaction, index)),
				"profession": _at_i32(professions, index),
			})
			var is_merchant := index < merchant_flags.size() and merchant_flags[index] != 0
			if is_merchant and merchants.size() < MAX_MERCHANTS:
				merchants.append({
					"slot": index,
					"handle": _at_i64(handles, index),
					"cash": _at_i64(funds, index),
				})
		out["cohorts"] = rows
		out["merchants"] = merchants
		notes.append("extension:cohorts.satisfaction=percent_from_q16")
		notes.append("extension:merchants.handle")
		if populations.size() > count:
			notes.append("missing:cohorts.truncated_at_%d" % MAX_COHORTS)

	# 建筑组：type/units/filled_owner/债务。
	var buildings := _call(economy, "building_cell_snapshot", [cell])
	if not bool(buildings.get("ok", false)):
		notes.append("missing:buildings")
	else:
		var group_types: PackedInt32Array = _packed_i32(buildings.get("group_type_ids"))
		var group_counts: PackedInt64Array = _packed_i64(buildings.get("group_counts"))
		var filled_owner: PackedInt64Array = _packed_i64(buildings.get("filled_owner"))
		var debt: PackedInt64Array = _packed_i64(
			buildings.get("merchant_debt_principal"))
		var owners: PackedInt32Array = _packed_i32(
			buildings.get("owner_signature_ids"))
		var group_rows: Array = []
		var group_total := mini(group_types.size(), MAX_BUILDINGS)
		for index in range(group_total):
			group_rows.append({
				"type_id": _at_i32(group_types, index),
				"units": _at_i64(group_counts, index),
				"filled_owner": _at_i64(filled_owner, index),
				"debt_principal": _at_i64(debt, index),
				"owner_signature": _at_i32(owners, index),
			})
		out["buildings"] = group_rows
		notes.append("extension:buildings.owner_signature")
		# 在建工程。requirement 明细（required_good/required_qty/stock）
		# 没有任何公开查询方法，只能省略。
		var construction_types: PackedInt32Array = _packed_i32(
			buildings.get("construction_type_ids"))
		var construction_counts: PackedInt64Array = _packed_i64(
			buildings.get("construction_counts"))
		var construction_ready: PackedInt64Array = _packed_i64(
			buildings.get("construction_ready_days"))
		var construction_owners: PackedInt32Array = _packed_i32(
			buildings.get("construction_owner_signature_ids"))
		var pending_rows: Array = []
		var pending_total := mini(construction_types.size(), MAX_PENDING)
		for index in range(pending_total):
			pending_rows.append({
				"type_id": _at_i32(construction_types, index),
				"units": _at_i64(construction_counts, index),
				"ready_day": _at_i64(construction_ready, index),
				"owner_signature": _at_i32(construction_owners, index),
			})
		out["pending_construction"] = pending_rows
		notes.append("missing:pending_construction.required_good")
		notes.append("missing:pending_construction.required_qty")
		notes.append("missing:pending_construction.stock")
		notes.append("extension:pending_construction.ready_day")

	# 该格所属市场的 lane：good/price/stock。good_id 用编目索引（= good_ids 下标）。
	var market := _call(economy, "market_cell_snapshot", [cell])
	if not bool(market.get("ok", false)):
		notes.append("missing:market_lanes")
	else:
		var good_ids: PackedStringArray = market.get("good_ids",
			PackedStringArray()) if market.get("good_ids") is PackedStringArray \
			else PackedStringArray()
		var prices: PackedInt32Array = _packed_i32(market.get("price"))
		var stocks: PackedInt64Array = _packed_i64(market.get("stock"))
		var lanes: Array = []
		var lane_total := mini(mini(good_ids.size(), prices.size()),
			mini(stocks.size(), MAX_MARKET_LANES))
		for index in range(lane_total):
			lanes.append({
				"good_id": index,
				"good": good_ids[index],
				"price": _at_i32(prices, index),
				"stock": _at_i64(stocks, index),
			})
		out["market_lanes"] = lanes
		notes.append("interpretation:market_lanes.good_id=good_index")
		notes.append("extension:market_lanes.good")
		if good_ids.size() > lane_total:
			notes.append("missing:market_lanes.truncated_at_%d" % MAX_MARKET_LANES)
	return out


## commands.json：该 epoch 的命令子集 + 最近 N 天诊断。
## structural/ledger 命令队列没有任何公开查询方法，只能留空数组并记 missing。
static func _collect_commands(report: Dictionary, epoch_id: int,
		notes: Array) -> Dictionary:
	var rows: Array = []
	var diagnostics = report.get("money_stage_diagnostics", [])
	if diagnostics is Array:
		# 取最近的若干天：这些行本来就按 day 递增，从尾部往前收集不同 day。
		var seen_days: Array = []
		var index: int = (diagnostics as Array).size() - 1
		while index >= 0 and rows.size() < MAX_COMMAND_ROWS:
			var row = diagnostics[index]
			index -= 1
			if not row is Dictionary:
				continue
			var day := int(row.get("day", -1))
			if not seen_days.has(day):
				if seen_days.size() >= MAX_RECENT_DAYS:
					break
				seen_days.append(day)
			rows.push_front({
				"day": day,
				"epoch_id": int(row.get("epoch_id", -1)),
				"where": String(row.get("where", "")),
				"stage": String(row.get("stage", "")),
				"executed_stage": String(row.get("executed_stage", "")),
				"substage": String(row.get("substage", "")),
				"diff": int(row.get("diff", 0)),
				"delta": int(row.get("delta", 0)),
				"money_now": int(row.get("money_now", 0)),
				"money_expected": int(row.get("money_expected", 0)),
				"cohort_funds": int(row.get("cohort_funds", 0)),
				"country_cash": int(row.get("country_cash", 0)),
			})
	if rows.is_empty():
		notes.append("missing:commands.recent_days")
	notes.append("missing:commands.structural")
	notes.append("missing:commands.ledger")
	notes.append("extension:commands.recent_days")
	return {
		"epoch": epoch_id,
		"structural": [],
		"ledger": [],
		"recent_days": rows,
	}


static func _resolve_cell(context: Dictionary, fatal_context: Dictionary) -> int:
	if context.has("cell"):
		return int(context.cell)
	for key in ["construction_row", "investment_row"]:
		var row := _as_dict(fatal_context.get(key, {}))
		if row.has("cell"):
			return int(row.cell)
	return -1


static func _resolve_type_id(context: Dictionary, fatal_context: Dictionary) -> int:
	if context.has("type_id"):
		return int(context.type_id)
	for key in ["construction_row", "investment_row"]:
		var row := _as_dict(fatal_context.get(key, {}))
		if row.has("type_id"):
			return int(row.type_id)
	return -1



# ---------------------------------------------------------------------------
# 小工具（本文件私有的取值/取整辅助，打包侧另有一份 _as_dict）
# ---------------------------------------------------------------------------

static func _facade(generator, method: String):
	if generator == null or not generator.has_method(method):
		return null
	return generator.call(method)


static func _report(generator, method: String) -> Dictionary:
	if generator == null or not generator.has_method(method):
		return {}
	return _as_dict(generator.call(method))


static func _call(target, method: String, args: Array) -> Dictionary:
	if target == null or not target.has_method(method):
		return {}
	var value = target.callv(method, args)
	return _as_dict(value)


static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}


static func _packed_i32(value) -> PackedInt32Array:
	return value if value is PackedInt32Array else PackedInt32Array()


static func _packed_i64(value) -> PackedInt64Array:
	return value if value is PackedInt64Array else PackedInt64Array()


static func _at_i32(values: PackedInt32Array, index: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else 0


static func _at_i64(values: PackedInt64Array, index: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else 0


## 运行时满意度是 Q16 定点（0..65536），schema 样例是百分数，这里统一换算。
static func _q16_percent(value: int) -> int:
	return int(round(float(value) * 100.0 / 65536.0))
