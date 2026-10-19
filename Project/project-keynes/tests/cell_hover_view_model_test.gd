extends SceneTree

## 悬停数据层：标题/归属/人口/资源四条取值链，以及缓存与 pending 边界。

const TIMBER_TECH := "tech.deadwood_collection"
const IRON_TECH := "tech.iron_ore_identification"
const STONE_TECH := "tech.ground_stone_tools"
const FISH_TECH := "tech.coastal_fishing"

var _failures: Array[String] = []
var _economy: HoverEconomyFacade
var _country: HoverCountryFacade
var _generator: HoverGenerator
var _map: MapData
var _clock: WorldClock
var _inspector: CellInspectorViewModel
var _view_model: CellHoverViewModel


class HoverEconomyFacade extends RefCounted:
	var calls := 0
	var payloads: Dictionary = {}
	var busy_cells: Dictionary = {}

	func population_cell_summary(cell_idx: int) -> Dictionary:
		calls += 1
		if busy_cells.has(cell_idx):
			return {"ok": false, "busy": true}
		return payloads.get(cell_idx, {"ok": true, "population": 0})


class HoverCountryFacade extends RefCounted:
	var calls := 0
	var tech_ids := PackedStringArray()
	var owned := true

	func cell_summary(_cell_idx: int) -> Dictionary:
		calls += 1
		return {
			"ok": true, "owned": owned, "country_name": "大秦", "country_handle": 1,
		}

	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "technology_ids": tech_ids}


class HoverGenerator extends RefCounted:
	var economy := HoverEconomyFacade.new()
	var country := HoverCountryFacade.new()

	func get_economy_facade():
		return economy

	func get_country_facade():
		return country

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 0}


func _initialize() -> void:
	_economy = HoverEconomyFacade.new()
	_country = HoverCountryFacade.new()
	_generator = HoverGenerator.new()
	_generator.economy = _economy
	_generator.country = _country
	_clock = WorldClock.new()
	_clock.auto_start = false

	_test_climate_zones()
	_build_world(PackedStringArray())
	_test_invalid_index()
	_test_unidentified_resources()
	_test_settled_cell()
	_test_unsettled_cell()
	_test_ocean_cell()
	_test_tag_dedupe()
	_test_pending_population()
	_test_cache_and_day_rollover()
	_test_eviction()

	if _failures.is_empty():
		print("[cell-hover-view-model] PASS")
		quit(0)
	else:
		for message in _failures:
			printerr("[cell-hover-view-model] FAIL: %s" % message)
		quit(1)


func _build_world(tech_ids: PackedStringArray) -> void:
	_country.tech_ids = tech_ids
	_country.calls = 0
	_economy.calls = 0
	_map = MapData.new(2, 3)
	# 0=温带平原+聚落 1=海洋 2=无人陆地 3=待定 4=温带草原（验证纸签去重）
	_map.terrain_arr = PackedByteArray([
		TerrainType.TERRAIN.PLAIN, TerrainType.TERRAIN.OCEAN,
		TerrainType.TERRAIN.PLAIN, TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.STEPPE])
	_map.landform_arr = PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.OCEAN,
		LandformType.LF.PLAIN, LandformType.LF.PLAIN, LandformType.LF.PLAIN])
	_map.is_water_arr = PackedByteArray([0, 1, 0, 0, 0])
	_map.vegetation_arr = PackedByteArray([
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.NONE,
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.TEMPERATE_GRASSLAND,
		VegetationType.VEG.TEMPERATE_GRASSLAND])
	_map.cover_arr = PackedByteArray([CoverType.CV.NONE, CoverType.CV.NONE,
		CoverType.CV.NONE, CoverType.CV.NONE, CoverType.CV.NONE])
	_map.temp_arr = PackedFloat32Array([0.52, 0.52, 0.52, 0.52, 0.52])
	_map.cell_lat_norm_arr = PackedFloat32Array([0.72, 0.72, 0.72, 0.72, 0.72])
	_map.country_slot_arr = PackedInt32Array([1, -1, 1, 1, 1])
	_map.resource_habitat_mask_arr = PackedByteArray([1, 2 | 8, 1, 1, 1])
	_map.res_timber_reserve_arr = PackedFloat32Array([12500.0, 0.0, 0.0, 0.0, 0.0])
	_map.res_iron_ore_reserve_arr = PackedFloat32Array([10000.0, 0.0, 0.0, 0.0, 0.0])
	_map.res_stone_reserve_arr = PackedFloat32Array([4000.0, 0.0, 0.0, 0.0, 0.0])
	_map.res_marine_fish_reserve_arr = PackedFloat32Array([0.0, 9000.0, 0.0, 0.0, 0.0])

	_economy.payloads = {
		0: {"ok": true, "population": 12450, "settlement_name_active": true,
			"settlement_name": "长安", "prosperity_name": "乡村"},
		2: {"ok": true, "population": 0, "settlement_name_active": false,
			"settlement_name": "", "prosperity_name": "无人区"},
		3: {"ok": true, "population": 640, "settlement_name_active": true,
			"settlement_name": "陈仓", "prosperity_name": "小镇"},
		4: {"ok": true, "population": 0, "settlement_name_active": false,
			"settlement_name": "", "prosperity_name": "无人区"},
	}
	_economy.busy_cells = {}

	_inspector = CellInspectorViewModel.new()
	_inspector.set_context(_map, _generator, null, _clock, 0.42, 22.0)
	_view_model = CellHoverViewModel.new()
	_view_model.set_context(_map, _generator, _inspector, _clock)
	_clock.current_day = 1.0


func _cell(index: int, terrain := -1, landform := -1) -> HexCell:
	var cell := HexCell.new(0, 0)
	cell.index = index
	if terrain >= 0:
		cell.terrain = terrain
	if landform >= 0:
		cell.landform = landform
	return cell


func _test_climate_zones() -> void:
	var cases := {0.50: "热带", 0.62: "副热带", 0.72: "温带", 0.83: "副极地", 0.95: "极地"}
	for lat in cases:
		var zone := CellHoverViewModel.climate_zone_name(float(lat))
		if zone != String(cases[lat]):
			_failures.append("纬度 %.2f 应为 %s，实际 %s" % [float(lat), String(cases[lat]), zone])


func _test_invalid_index() -> void:
	var pop_before := _economy.calls
	var country_before := _country.calls
	var payload := _view_model.build(_cell(-1))
	if bool(payload.get("ok", true)):
		_failures.append("index<0 应返回 !ok")
	if _economy.calls != pop_before or _country.calls != country_before:
		_failures.append("index<0 不得触发任何 facade 调用")


func _test_unidentified_resources() -> void:
	var payload := _view_model.build(_cell(0))
	var rows: Array = payload.get("resources", [])
	if not rows.is_empty():
		_failures.append("空科技集下不应暴露任何受科技门槛限制的资源")
	if String(payload.get("resource_note", "")) != "当前科技尚未识别此地资源":
		_failures.append("空科技集的空态文案不对: %s" % payload.get("resource_note", ""))


func _test_settled_cell() -> void:
	_build_world(PackedStringArray([TIMBER_TECH, IRON_TECH, STONE_TECH, FISH_TECH]))
	var payload := _view_model.build(_cell(0))
	if String(payload.get("title", "")) != "长安":
		_failures.append("有聚落格标题应为城名，实际 %s" % payload.get("title", ""))
	if String(payload.get("title_kind", "")) != "settlement":
		_failures.append("有聚落格 title_kind 应为 settlement")
	if String(payload.get("country_name", "")) != "大秦":
		_failures.append("归属应为大秦，实际 %s" % payload.get("country_name", ""))
	if String(payload.get("population_text", "")) != "1.2万":
		_failures.append("人口应紧凑成 1.2万，实际 %s" % payload.get("population_text", ""))
	if not bool(payload.get("settled", false)):
		_failures.append("有聚落格 settled 应为真")
	if String(payload.get("settlement_tier", "")) != "乡村":
		_failures.append("聚落等级应为乡村")
	var rows: Array = payload.get("resources", [])
	if rows.size() != CellHoverViewModel.RESOURCE_TOP_N:
		_failures.append("陆地格应给出 3 项资源，实际 %d" % rows.size())
	if not rows.is_empty() and String((rows[0] as Dictionary).get("id", "")) != "timber":
		_failures.append("首位资源应为密度最高的木材，实际 %s"
			% (rows[0] as Dictionary).get("id", ""))
	var tags: Array = payload.get("tags", [])
	if tags.size() != 2:
		_failures.append("地形与地貌同为平原时纸签应去重为 2 枚，实际 %d" % tags.size())
	if String((tags[tags.size() - 1] as Dictionary).get("name", "")) != "温带":
		_failures.append("最后一枚纸签应为气候带，实际 %s"
			% (tags[tags.size() - 1] as Dictionary).get("name", ""))


func _test_tag_dedupe() -> void:
	var payload := _view_model.build(_cell(4))
	var tags: Array = payload.get("tags", [])
	if tags.size() != 3:
		_failures.append("「温带草原」应保留三枚纸签，实际 %d" % tags.size())
		return
	var climate := String((tags[2] as Dictionary).get("name", ""))
	if climate != "温和":
		_failures.append("地形名已含气候带时应只补温度档，实际 %s" % climate)


func _test_unsettled_cell() -> void:
	var payload := _view_model.build(_cell(2))
	if String(payload.get("title_kind", "")) != "landform":
		_failures.append("无人格标题应回落到地貌")
	if String(payload.get("population_text", "")) != "无人定居":
		_failures.append("无人格人口文案应为无人定居，实际 %s"
			% payload.get("population_text", ""))
	if String(payload.get("settlement_tier", "")) != "":
		_failures.append("无人格不应显示「无人区」徽记")


func _test_ocean_cell() -> void:
	var payload := _view_model.build(_cell(1))
	if not bool(payload.get("is_water", false)):
		_failures.append("海洋格 is_water 应为真")
	var rows: Array = payload.get("resources", [])
	var ids: Array[String] = []
	for row in rows:
		ids.append(String((row as Dictionary).get("id", "")))
	if ids.has("timber"):
		_failures.append("海洋格不应出现木材")
	if not ids.has("marine_fish"):
		_failures.append("海洋格应出现海洋鱼类，实际 %s" % str(ids))
	if String(payload.get("country_name", "")) != "无主海域":
		_failures.append("无主海洋应显示无主海域，实际 %s" % payload.get("country_name", ""))
	var tags: Array = payload.get("tags", [])
	if tags.size() > 2:
		_failures.append("水面地形/地貌同名时应只出 2 枚纸签，实际 %d" % tags.size())


func _test_pending_population() -> void:
	_build_world(PackedStringArray([TIMBER_TECH, IRON_TECH, STONE_TECH]))
	var cell := _cell(3)
	_view_model.build(cell)
	_economy.busy_cells = {3: true}
	_clock.current_day = 2.0
	var payload := _view_model.build(cell)
	if bool(payload.get("population_pending", false)):
		# inspector 的缓存里已有第 1 天的好值，应直接沿用而不是报 pending。
		_failures.append("有上一份好值时应沿用，不该标记 pending")
	if int(payload.get("population", 0)) != 640:
		_failures.append("pending 时应沿用上一份人口 640，实际 %d"
			% int(payload.get("population", 0)))


func _test_cache_and_day_rollover() -> void:
	_build_world(PackedStringArray([TIMBER_TECH, IRON_TECH, STONE_TECH]))
	var cell := _cell(0)
	_view_model.build(cell)
	var pop_calls := _economy.calls
	var country_calls := _country.calls
	_view_model.build(cell)
	_view_model.build(cell)
	if _economy.calls != pop_calls or _country.calls != country_calls:
		_failures.append("同一 cache_key 连查应命中缓存（population %d→%d, country %d→%d）" % [
			pop_calls, _economy.calls, country_calls, _country.calls])
	_economy.payloads[0]["population"] = 20000
	_clock.current_day = 2.0
	var rolled := _view_model.build(cell)
	if String(rolled.get("population_text", "")) != "2万":
		_failures.append("跨日应重新取数，实际 %s" % rolled.get("population_text", ""))
	if _economy.calls <= pop_calls:
		_failures.append("跨日应重新查询人口")


func _test_eviction() -> void:
	_build_world(PackedStringArray([TIMBER_TECH, IRON_TECH, STONE_TECH]))
	for i in range(300):
		_view_model.build(_cell(i))
	var stats := _view_model.debug_stats()
	if int(stats.get("payload_entries", 0)) > CellHoverViewModel.PAYLOAD_LIMIT:
		_failures.append("payload 缓存应封顶 %d，实际 %d" % [
			CellHoverViewModel.PAYLOAD_LIMIT, int(stats.get("payload_entries", 0))])
