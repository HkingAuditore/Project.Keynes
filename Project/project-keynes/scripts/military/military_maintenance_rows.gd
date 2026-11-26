extends RefCounted

## Formats published military maintenance rows and their summary.

# ---- 实物维护（docs/plans/military-physical-maintenance.md D7 / S4-6）----
## 维护对象的两类：建筑组（`object_id` = 目录 `state_buildings` 稠密下标）
## 与装备组（`object_id` = 兵种稠密下标）。
const MAINTENANCE_KIND_BUILDING := 0
const MAINTENANCE_KIND_EQUIPMENT := 1
const MAINTENANCE_KIND_NAMES := {0: "建筑", 1: "装备"}
## `shortage_reason`：0 无 / 1 缺货 / 2 预算不足 / 3 运输未到。
const MAINTENANCE_REASON_TEXT := ["—", "缺货", "预算不足", "运输未到"]
## `days_cover_x10 == -1`：该行没有需求，可用天数无意义。
const MAINTENANCE_NO_DEMAND := -1
## 排序用的「无需求」哨兵：比任何真实天数都大，保证短缺行排在最前。
const MAINTENANCE_NO_DEMAND_SORT := 0x7FFFFFFF
## 维护缓存的槽：无参原生方法一次回全表，所有国家共用这一份。
const MAINTENANCE_ALL_COUNTRIES := -1
## 原生字段名在 D7 契约与任务书里各写了一次（`daily_need` vs `daily_need_goods`
## 等），两条都认。这是本次 UI 侧唯一的字段名假设，已列进交付说明请原生侧核对。
const MAINTENANCE_FIELD_ALIASES := {
	"country_slot": ["country_slot"],
	"cell": ["cell"],
	"kind": ["kind"],
	"object_id": ["object_id"],
	"units": ["units"],
	"daily_need_goods": ["daily_need_goods", "daily_need"],
	"stock_goods": ["stock_goods", "stock"],
	"inbound_goods": ["inbound_goods", "inbound"],
	"ratio_bp": ["ratio_bp"],
	"days_cover_x10": ["days_cover_x10"],
	"disrepair": ["disrepair"],
	"shortage_reason": ["shortage_reason", "reason"],
}

## 纯函数：把维护快照整形为 `{rows: [...], summary: {...}}`，不碰原生、不留状态，
## 所以测试可以直接喂合成字典（tests/military/military_maintenance_view_model_test.gd）。
##
## `rows` 接受两种形状：
##   1. 原生发布的平行字典：`{country_slot: PackedInt32Array, ...}`（或带 `rows` 数组）；
##   2. 已解码的行数组：`[{country_slot: 1, kind: 0, object_id: 3, ...}, ...]`。
##
## `catalog` 是编译后的军事目录（`state_buildings` / `units`）。`object_id` 是稠密
## 下标，这里解析成稳定 id + 显示名；越界时 id 留空、名字写「建筑 · #n」。
##
## 排序：可用天数升序（短缺在前），再按稳定 id、国家、地块（后两项只为确定性，
## 同一 id 可能出现在多个地块）。`days_cover_x10 == -1`（无需求）不是短缺，排最后。
static func shape_maintenance(rows, catalog: Dictionary) -> Dictionary:
	var shaped: Array = []
	for raw in _decode_maintenance_rows(rows):
		shaped.append(_shape_maintenance_row(raw, catalog))
	shaped.sort_custom(func(a, b) -> bool:
		var days_a := _maintenance_sort_days(int(a.get("days_cover_x10",
			MAINTENANCE_NO_DEMAND)))
		var days_b := _maintenance_sort_days(int(b.get("days_cover_x10",
			MAINTENANCE_NO_DEMAND)))
		if days_a != days_b:
			return days_a < days_b
		var id_a := String(a.get("id", ""))
		var id_b := String(b.get("id", ""))
		if id_a != id_b:
			return id_a < id_b
		if int(a.get("country_slot", -1)) != int(b.get("country_slot", -1)):
			return int(a.get("country_slot", -1)) < int(b.get("country_slot", -1))
		return int(a.get("cell", -1)) < int(b.get("cell", -1)))
	return {"rows": shaped, "summary": _summarize_maintenance(shaped)}


## `shortage_reason` → 展示文案（0 — / 1 缺货 / 2 预算不足 / 3 运输未到）。
static func maintenance_reason_text(reason: int) -> String:
	if reason < 0 or reason >= MAINTENANCE_REASON_TEXT.size():
		return String(MAINTENANCE_REASON_TEXT[0])
	return String(MAINTENANCE_REASON_TEXT[reason])


## 需求加权满足率：`Σ(need × ratio) / Σneed`，整数除法；没有需求时为 0。
static func _summarize_maintenance(rows: Array) -> Dictionary:
	var need := 0
	var stock := 0
	var inbound := 0
	var weighted := 0
	var disrepair_rows := 0
	var shortage_rows := 0
	for raw in rows:
		var row: Dictionary = raw
		var row_need := maxi(0, int(row.get("daily_need_goods", 0)))
		need += row_need
		stock += maxi(0, int(row.get("stock_goods", 0)))
		inbound += maxi(0, int(row.get("inbound_goods", 0)))
		weighted += row_need * clampi(int(row.get("ratio_bp", 0)), 0, 10000)
		if int(row.get("disrepair", 0)) != 0:
			disrepair_rows += 1
		if int(row.get("shortage_reason", 0)) != 0:
			shortage_rows += 1
	return {
		"rows": rows.size(),
		"need_goods": need,
		"stock_goods": stock,
		"inbound_goods": inbound,
		"weighted_ratio_bp": clampi(weighted / need, 0, 10000) if need > 0 else 0,
		"disrepair_rows": disrepair_rows,
		"shortage_rows": shortage_rows,
	}


static func _maintenance_sort_days(days_cover_x10: int) -> int:
	return MAINTENANCE_NO_DEMAND_SORT if days_cover_x10 < 0 else days_cover_x10


static func _decode_maintenance_rows(rows) -> Array:
	if rows is Array:
		var decoded: Array = []
		for raw in (rows as Array):
			if raw is Dictionary:
				decoded.append(raw)
		return decoded
	if not rows is Dictionary:
		return []
	var raw_rows = (rows as Dictionary).get("rows", null)
	if raw_rows is Array:
		return _decode_maintenance_rows(raw_rows)
	if (rows as Dictionary).is_empty():
		return []
	return _decode_parallel_maintenance(rows as Dictionary)


## 平行数组 → 行字典。取各数组长度的最大值：缺一条数组不该把整张表截断。
static func _decode_parallel_maintenance(raw: Dictionary) -> Array:
	var columns := {}
	var count := 0
	for field in MAINTENANCE_FIELD_ALIASES:
		var values = _first_present(raw, MAINTENANCE_FIELD_ALIASES[field])
		columns[field] = values
		if values is Array:
			count = maxi(count, (values as Array).size())
		elif values is PackedInt32Array:
			count = maxi(count, (values as PackedInt32Array).size())
		elif values is PackedInt64Array:
			count = maxi(count, (values as PackedInt64Array).size())
		elif values is PackedByteArray:
			count = maxi(count, (values as PackedByteArray).size())
	var out: Array = []
	for index in range(count):
		var row := {}
		for field in columns:
			var values = columns[field]
			row[field] = int(values[index]) \
				if values != null and index < values.size() else 0
		out.append(row)
	return out


static func _first_present(raw: Dictionary, keys: Array):
	for key in keys:
		if raw.has(key):
			return raw[key]
	return null


static func _shape_maintenance_row(raw: Dictionary, catalog: Dictionary) -> Dictionary:
	var kind := int(raw.get("kind", MAINTENANCE_KIND_BUILDING))
	var object_id := int(raw.get("object_id", -1))
	var kind_name := String(MAINTENANCE_KIND_NAMES.get(kind, ""))
	var identity := _maintenance_identity(catalog, kind, object_id)
	var name := String(identity.get("name", ""))
	if name.is_empty():
		name = "%s · #%d" % [kind_name if not kind_name.is_empty() else "对象", object_id]
	var reason := int(raw.get("shortage_reason", 0))
	return {
		"country_slot": int(raw.get("country_slot", -1)),
		"cell": int(raw.get("cell", -1)),
		"kind": kind,
		"kind_name": kind_name,
		"object_id": object_id,
		"id": String(identity.get("id", "")),
		"name": name,
		"units": maxi(0, int(raw.get("units", 0))),
		"daily_need_goods": maxi(0, int(raw.get("daily_need_goods", 0))),
		"stock_goods": maxi(0, int(raw.get("stock_goods", 0))),
		"inbound_goods": maxi(0, int(raw.get("inbound_goods", 0))),
		"ratio_bp": clampi(int(raw.get("ratio_bp", 0)), 0, 10000),
		"days_cover_x10": int(raw.get("days_cover_x10", MAINTENANCE_NO_DEMAND)),
		"disrepair": 1 if int(raw.get("disrepair", 0)) != 0 else 0,
		"shortage_reason": reason,
		"reason_text": maintenance_reason_text(reason),
	}


## 稠密下标 → `{id, name}`。`units` 在编译目录里是数组；地块档案那边缓存的是
## 「下标 → 行」字典，两种都认，免得同一份解析写两遍。
static func _maintenance_identity(catalog: Dictionary, kind: int,
		object_id: int) -> Dictionary:
	var key := "state_buildings" if kind == MAINTENANCE_KIND_BUILDING else "units"
	var table = catalog.get(key, null)
	var row = null
	if table is Array:
		if object_id >= 0 and object_id < (table as Array).size():
			row = (table as Array)[object_id]
	elif table is Dictionary:
		row = (table as Dictionary).get(object_id, null)
	if not row is Dictionary:
		return {"id": "", "name": ""}
	var id := String((row as Dictionary).get("id", "")).strip_edges()
	var name := String((row as Dictionary).get("name", "")).strip_edges()
	return {"id": id, "name": name if not name.is_empty() else id}
