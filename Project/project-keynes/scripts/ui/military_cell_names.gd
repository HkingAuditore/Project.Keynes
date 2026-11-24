extends RefCounted


## Region name of a cell. Territory names are authored by the world generator
## (MapGenerator.region_name_for_cell); the owner name comes from Country. A bare
## index is the last resort, so a missing name in production stays visible.
static func zone_name(host, cell: int) -> String:
	if cell < 0:
		return "—"
	var region := _region_name(host, cell)
	var owner: String = host.cell_owner_name(cell)
	# A region with no authored name is said out loud ("青川国境内"): falling
	# through to the fixture's cell table here is exactly how a production
	# "地块 1467" would look like a real name.
	if not region.is_empty():
		return "%s·%s" % [region, owner] if not owner.is_empty() else region
	return "%s境内" % owner if not owner.is_empty() else cell_name(host, cell)


## 作者写的地区名；空串表示这一格没有地区名。
static func _region_name(host, cell: int) -> String:
	if cell < 0:
		return ""
	if host._generator != null and host._generator.has_method("region_name_for_cell"):
		var region := String(host._generator.call("region_name_for_cell", cell)).strip_edges()
		if not region.is_empty():
			return region
	# Fixture/offline stand-in for the generator's region names.
	return String(host._as_dict(host._as_dict(host._model.get("military", null)).get(
		"region_names", null)).get(cell, ""))


## 具名聚落的名字（Economy 权威）。空串表示这一格没有具名聚落。
##
## 割地表用**它**判断「这一格有没有自己的名字」，不能用 `cell_name(host)`：后者在
## 没有聚落名时会退回地区名，那样每个格子都会被当成「有名字」。
static func settlement_name(host, cell: int) -> String:
	if cell < 0:
		return ""
	return String(host._cell_names.get(cell, ""))


## 具名聚落名表的条数。诊断用：0 表示这次刷新还没拿到 Economy 的聚落快照
## （读视图在 worker 侧排队），此时面板写地区名而不是空白。
static func cell_name_count(host) -> int:
	return host._cell_names.size()


## 面板上写的地块名：具名聚落 > 地区名 > 「地块 N」。
##
## 以前没有聚落名的格子一律写「未命名地块」，于是兵营行、训练行与割地表全在重复
## 同一句半截话——既不是名字，也不提供定位信息。现在最差也给序号。
static func cell_name(host, cell: int) -> String:
	if cell < 0:
		return "—"
	var settlement := settlement_name(host, cell)
	if not settlement.is_empty():
		return settlement
	var region := _region_name(host, cell)
	if not region.is_empty():
		return region
	return "地块 %d" % cell
