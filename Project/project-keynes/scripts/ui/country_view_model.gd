class_name CountryViewModel
extends RefCounted

const FiscalProjection = preload("res://scripts/ui/country_fiscal_projection.gd")

const MilitaryProjection = preload("res://scripts/ui/country_military_projection.gd")

const SectionSnapshots = preload("res://scripts/ui/country_section_snapshots.gd")

const CountryCatalogPresentation = preload("res://scripts/ui/country_catalog_presentation.gd")

const MaintenancePresentation = preload("res://scripts/ui/military_maintenance_presentation.gd")

const IdeologyPresentation = preload("res://scripts/ui/country_ideology_presentation.gd")

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceProfileRegistryScript = preload(
	"res://scripts/data/resource_profile_registry.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

# Catalog content (display names, icons, technology requirements) is static for
# the whole session; the cache is built once so daily refreshes cost nothing.

var _generator = null
## 会话地图（`MapData`）：军事/外交章的领土镜像、邻接与视野都从它读。
var _map = null
var _section_cache: Dictionary = {}
var _section_cache_revisions: Dictionary = {}
var _static_catalog_cache: Dictionary = {}
var _ideology_catalog_cache: Dictionary = {}
var _ideology_catalog_facade = null
var _political_regime_catalog_cache: Dictionary = {}
var _political_regime_catalog_facade = null
var _military_catalog_cache: Dictionary = {}
var _military_catalog_facade = null
## 具名聚落名表（cell -> 名字）与它对应的 Economy 结算 revision。
## 军事面板每行都要写地块名，而原生只给「有名字的聚落」这一份权威名单；按 revision
## 增量维护，名字没变时每次刷新只有一次空读，不会把 2400 格扫一遍。
var _cell_names: Dictionary = {}
var _cell_names_revision := -1
var _economy_history := EconomyHistoryBuffer.new()
## 国库收支的逐日趋势。与产值账本一样按已提交日采样，面板关闭时也继续走。
var _fiscal_history := EconomyFiscalHistory.new()
var _gdp_ledger: EconomyGdpLedger = null
var _strata_table: SocialStrataTable

## `map` 是会话的 `MapData`。必须显式传入：`MapGenerator` 没有公开的 map getter，
## 而军事/外交章要读领土镜像（`country_slot_arr`）、邻接与视野数组。
func set_context(generator, map = null) -> void:
	_generator = generator
	_map = map
	_section_cache.clear()
	_section_cache_revisions.clear()
	_ideology_catalog_cache.clear()
	_ideology_catalog_facade = null
	_political_regime_catalog_cache.clear()
	_political_regime_catalog_facade = null
	_military_catalog_cache.clear()
	_military_catalog_facade = null
	_economy_history.reset()
	_fiscal_history.reset()

## 年度产值账本由 GameUIManager 持有并推进；这里只持有引用，供卷宗横幅读取。
func set_gdp_ledger(ledger: EconomyGdpLedger) -> void:
	_gdp_ledger = ledger

func gdp_ledger() -> EconomyGdpLedger:
	return _gdp_ledger

func economy_history() -> EconomyHistoryBuffer:
	return _economy_history

func fiscal_history() -> EconomyFiscalHistory:
	return _fiscal_history

## 每个已提交日推进一次国库收支序列。财政快照用来拆分税种，国库现金用来
## 校准多日结算造成的真实净变化；两者都不做逐格聚合，面板关闭时也继续采样。
func sample_fiscal_history(committed_day: int = -1) -> bool:
	var context := _country_context()
	if not bool(context.get("ok", false)):
		return false
	var facade = context.facade
	if facade == null:
		return false
	var handle := int(context.country_handle)
	var fiscal: Dictionary = {}
	if facade.has_method("fiscal_snapshot"):
		fiscal = facade.fiscal_snapshot(handle)
	# 国家摘要已经带同一份权威国库现金；只有旧快照缺字段时才查一次国库，
	# 避免为了一个标量每日搬运整份物资清单。
	var treasury_cash := int(context.summary.get("cash", -1))
	if treasury_cash < 0 and facade.has_method("treasury_snapshot"):
		var treasury: Dictionary = facade.treasury_snapshot(handle)
		if bool(treasury.get("ok", false)) and treasury.has("cash"):
			treasury_cash = int(treasury.get("cash", 0))
	return _fiscal_history.sample(handle, fiscal, treasury_cash, committed_day)

func strata_table() -> SocialStrataTable:
	if _strata_table == null:
		_strata_table = SocialStrataTable.load_default()
	return _strata_table

## 每个经济提交批次调用一次；同一已提交日只记录一个趋势点。
func sample_economy_history() -> bool:
	var context := _country_context()
	if not bool(context.get("ok", false)) or _generator == null \
			or not _generator.has_method("get_economy_facade"):
		return false
	return _economy_history.sample(_generator.get_economy_facade(),
		int(context.country_handle), int(context.summary.get("cash", 0)), strata_table())

func invalidate_cache(domains: int = -1) -> void:
	if domains < 0:
		_section_cache.clear()
		_section_cache_revisions.clear()
		return
	if (domains & 1) != 0:
		_section_cache.erase("technology")
		_section_cache_revisions.erase("technology")
	if (domains & 2) != 0:
		_section_cache.erase("economy")
		_section_cache_revisions.erase("economy")
	if (domains & 4) != 0:
		_section_cache.erase("politics")
		_section_cache_revisions.erase("politics")
	if (domains & 8) != 0:
		_section_cache.erase("military")
		_section_cache_revisions.erase("military")
	if (domains & 16) != 0:
		_section_cache.erase("diplomacy")
		_section_cache_revisions.erase("diplomacy")

func cached_section(section_id: String) -> Dictionary:
	return _section_cache.get(section_id, {})

func build_static_catalog() -> Dictionary:
	if _static_catalog_cache.is_empty():
		var technology_definitions := TechnologyCatalogScript.public_definitions()
		var lanes := TechnologyCatalogScript.public_lane_metadata()
		var application_definitions := CountryCatalogPresentation._application_definitions(
			TechnologyCatalogScript.public_application_intersections(), lanes)
		var combined_definitions: Array = technology_definitions.duplicate(true)
		combined_definitions.append_array(application_definitions)
		var visual_edges: Array = TechnologyCatalogScript.public_visual_edges()
		visual_edges.append_array(
			TechnologyCatalogScript.public_application_visual_edges())
		_static_catalog_cache = {
			"technology_definitions": combined_definitions,
			"technology_research_definition_count": technology_definitions.size(),
			"technology_application_definitions": application_definitions,
			"technology_eras": TechnologyCatalogScript.public_era_metadata(),
			"technology_domains": TechnologyCatalogScript.public_domain_metadata(),
			"technology_visual_edges": visual_edges,
			"technology_lanes": lanes,
			"research_signal_definitions": ResearchSignalCatalogScript.public_metadata(),
		}
	return _static_catalog_cache


func player_completed_technology_ids() -> PackedStringArray:
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return PackedStringArray()
	var start_report: Dictionary = _generator.gameplay_start_report()
	var start_cell := int(start_report.get("cell", -1))
	var facade = _generator.get_country_facade()
	if not bool(start_report.get("ok", false)) or facade == null or start_cell < 0 \
			or not facade.has_method("snapshot"):
		return PackedStringArray()
	var summary: Dictionary = facade.cell_summary(start_cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return PackedStringArray()
	var snapshot: Dictionary = facade.snapshot(int(summary.get("country_handle", 0)))
	if not bool(snapshot.get("ok", false)):
		return PackedStringArray()
	return snapshot.get("technology_ids", PackedStringArray())

# Lightweight player research states for HUD completion toasts. Avoids building the
# full technology workspace model when the country panel is closed.
func player_research_states() -> PackedInt32Array:
	var context := _country_context()
	if not bool(context.get("ok", false)):
		return PackedInt32Array()
	var facade = context.facade
	if facade == null or not facade.has_method("research_snapshot"):
		return PackedInt32Array()
	var research: Dictionary = facade.research_snapshot(int(context.country_handle))
	var states = research.get("technology_states", null)
	return states if states is PackedInt32Array else PackedInt32Array()

func _build_full_legacy(section_id: String = "technology") -> Dictionary:
	var normalized_section := "politics" if section_id == "ideology" else section_id
	if normalized_section not in ["technology", "economy", "politics", "military", "diplomacy"]:
		normalized_section = "technology"
	if _section_cache.has(normalized_section):
		return _section_cache[normalized_section]
	# Keep the pre-snapshot path intentionally verbose for debug/A-B comparison.
	# It must not call the compact section bridge, otherwise the fallback would
	# measure the same query contract as the production event-driven path.
	var context := _country_context()
	if not bool(context.get("ok", false)):
		return _unavailable_model(String(context.get("reason", "国家数据暂不可用")))
	var facade = context.facade
	var economy_facade = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	var country_handle := int(context.country_handle)
	var start_cell := int(context.start_cell)
	var summary: Dictionary = context.summary
	var research: Dictionary = facade.research_snapshot(country_handle) \
		if facade.has_method("research_snapshot") else {}
	research["research_signal_snapshot"] = facade.research_signal_snapshot(
		country_handle) if facade.has_method("research_signal_snapshot") else {}
	var tax_policy: Dictionary = facade.tax_policy_snapshot(country_handle) \
		if facade.has_method("tax_policy_snapshot") else {}
	var fiscal: Dictionary = facade.fiscal_snapshot(country_handle) \
		if facade.has_method("fiscal_snapshot") else {}
	var trade_summary: Dictionary = economy_facade.country_trade_snapshot(
		country_handle, "summary", 0, 1) if economy_facade != null and \
		economy_facade.has_method("country_trade_snapshot") else {
			"ok": false, "reason": "country trade API unavailable"}
	var country_snapshot: Dictionary = facade.snapshot(country_handle) \
		if facade.has_method("snapshot") else {}
	var tax_availability := _tax_availability(economy_facade, start_cell)
	var ideology := _ideology_model(country_handle)
	var politics_snapshot: Dictionary = facade.political_regime_snapshot(country_handle) \
		if facade.has_method("political_regime_snapshot") else {}
	var politics := build_politics_snapshot(country_handle,
		{"politics": politics_snapshot})
	var treasury := _treasury_model(facade, country_handle)
	var treasury_available := bool(treasury.get("available", false))
	var cash := int(treasury.get("cash", 0)) if treasury_available \
		else int(summary.get("cash", 0))
	research["country_cash"] = cash
	var development := _development_model(country_handle, research)
	var revision_components := {
		"country_state_version": int(summary.get("state_version", 0)),
		"country_generation": int(facade.report().get("generation", 0)),
	}
	var model := {
		"available": true,
		"country_name": String(summary.get("country_name", "未命名国家")),
		"country_id": String(summary.get("country_id", "")),
		"territory_count": int(summary.get("territory_count", 0)),
		"cash": cash,
		"nonzero_good_count": int(treasury.get("nonzero_good_count", 0)) \
			if treasury_available else int(summary.get("nonzero_good_count", 0)),
		"technology_count": int(summary.get("technology_count", 0)),
		"country_handle": country_handle,
		"country_state_version": int(summary.get("state_version", 0)),
		"country_generation": int(facade.report().get("generation", 0)),
		"revision": int(summary.get("state_version", 0)),
		"revision_components": revision_components,
		"economy_trade_revision": int(trade_summary.get("revision", 0)),
		"economy_class_opinion_revision": 0,
		"ideology_support_revision": int(ideology.get("snapshot", {}).get(
			"support_revision", 0)),
		"country_facade": facade,
		"treasury": treasury,
		"tax_policy": tax_policy,
		"tax_presentation": present_tax_policy(tax_policy,
			country_snapshot.get("technology_ids", PackedStringArray()),
			tax_availability),
		"fiscal": fiscal,
		"trade_summary": trade_summary,
		"economy_facade": economy_facade,
		"current_day": int(facade.report().get("last_committed_day", -1)),
		"research": research,
		"development": development,
		"ideology": ideology,
		"politics": politics.get("politics", {}),
		"procurement": procurement_model(economy_facade, country_handle),
	}
	if normalized_section == "technology":
		model.merge(build_static_catalog(), true)
	if normalized_section == "economy":
		# 国库页的军费板块读 `model["military"]`；经济章以前不装配这一段，
		# 于是板块永远「暂不可用」。只装它要的那两项读数（见函数注释）。
		build_military_spending_model(country_handle, model)
	if normalized_section in ["military", "diplomacy"]:
		model["good_ids"] = _good_stable_ids()
		build_military_model(country_handle, model)
	if normalized_section == "diplomacy":
		build_diplomacy_model(country_handle, model, facade)
	_section_cache[normalized_section] = model
	_section_cache_revisions[normalized_section] = revision_components
	return model

func build_legacy(section_id: String = "technology") -> Dictionary:
	# Explicit A/B/debug entry point. Production event-driven callers use build().
	return _build_full_legacy(section_id)

func _country_context() -> Dictionary:
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return {"ok": false, "reason": "国家数据尚未就绪"}
	var start_report: Dictionary = _generator.gameplay_start_report()
	var start_cell := int(start_report.get("cell", -1))
	var facade = _generator.get_country_facade()
	if not bool(start_report.get("ok", false)) or facade == null or start_cell < 0:
		return {"ok": false, "reason": "当前会话没有可用的玩家国家"}
	var summary: Dictionary = facade.cell_summary(start_cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return {"ok": false, "reason": "玩家国家数据暂不可用"}
	return {
		"ok": true,
		"start_cell": start_cell,
		"facade": facade,
		"summary": summary,
		"country_handle": int(summary.get("country_handle", 0)),
	}

func _section_mask(section_id: String) -> int:
	# 军事没有原生 country_ui_snapshot 分片（它走自己的 facade），给 0 表示
	# 「不需要国家快照」，国家壳数据仍由 summary 提供。外交同理：它读的是
	# 领土镜像 + 军事快照，不读国家快照分片。
	return int({"technology": 1, "economy": 2, "politics": 12, "ideology": 12, "military": 0,
		"diplomacy": 0}.get(section_id, 1))

func build_summary_snapshot(country_handle: int, summary: Dictionary,
		ui_snapshot: Dictionary = {}) -> Dictionary:
	return SectionSnapshots.build_summary_snapshot(self, country_handle, summary, ui_snapshot)


func build_technology_snapshot(country_handle: int, facade,
		ui_snapshot: Dictionary) -> Dictionary:
	return SectionSnapshots.build_technology_snapshot(self, country_handle, facade, ui_snapshot)


func build_economy_snapshot(country_handle: int, facade, economy_facade,
		ui_snapshot: Dictionary, start_cell: int) -> Dictionary:
	return SectionSnapshots.build_economy_snapshot(self, country_handle, facade, economy_facade, ui_snapshot, start_cell)


func build_ideology_snapshot(country_handle: int, ui_snapshot: Dictionary) -> Dictionary:
	return SectionSnapshots.build_ideology_snapshot(self, country_handle, ui_snapshot)


func build_politics_snapshot(country_handle: int, ui_snapshot: Dictionary) -> Dictionary:
	return SectionSnapshots.build_politics_snapshot(self, country_handle, ui_snapshot)


func _present_profession_ids(country_handle: int):
	return SectionSnapshots._present_profession_ids(self, country_handle)


static func _present_political_regime(snapshot: Dictionary,
		catalog: Dictionary, present_professions = null) -> Dictionary:
	return SectionSnapshots._present_political_regime(snapshot, catalog, present_professions)


func build(section_id: String = "technology") -> Dictionary:
	var normalized_section := "politics" if section_id == "ideology" else section_id
	if normalized_section not in ["technology", "economy", "politics", "military", "diplomacy"]:
		normalized_section = "technology"
	if _section_cache.has(normalized_section):
		return _section_cache[normalized_section]
	var context := _country_context()
	if not bool(context.get("ok", false)):
		var unavailable := _unavailable_model(String(context.get("reason", "国家数据暂不可用")))
		# 军事面板有自己的一条数据通路（军事 facade + 它自己的国家槽），
		# 国家壳没就绪时也不能整段消失：面板要能说清「军事机构尚未接通」。
		if normalized_section in ["military", "diplomacy"]:
			unavailable["military"] = _unavailable_military_section(0,
				String(context.get("reason", "国家数据暂不可用")))
			if normalized_section == "diplomacy":
				unavailable["diplomacy"] = _unavailable_diplomacy_section(
					String(context.get("reason", "国家数据暂不可用")))
		return unavailable
	var facade = context.facade
	var country_handle := int(context.country_handle)
	var ui_snapshot: Dictionary = facade.ui_snapshot(country_handle,
		_section_mask(normalized_section)) if facade.has_method("ui_snapshot") else {}
	var summary_snapshot := build_summary_snapshot(country_handle,
		context.summary, ui_snapshot)
	var economy_facade = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	var section_snapshot: Dictionary = {}
	match normalized_section:
		"technology":
			section_snapshot = build_technology_snapshot(country_handle, facade, ui_snapshot)
		"economy":
			section_snapshot = build_economy_snapshot(country_handle, facade,
				economy_facade, ui_snapshot, int(context.start_cell))
		"politics":
			section_snapshot = build_politics_snapshot(country_handle, ui_snapshot)
		"military":
			# 军事自成一个模型源：CountryViewModel 只负责装配，军事自己的展示
			# 逻辑在 MilitaryViewModel 里。这里先把模型占位放好，装配在
			# merge 之后（需要 model 本身带 good_ids/country_handle 才能查名字）。
			section_snapshot = {}
		"diplomacy":
			# 外交同理：名单/档案/战事都由 DiplomacyViewModel 算，这里只占位。
			section_snapshot = {}
	var treasury: Dictionary = section_snapshot.get("treasury", {})
	var treasury_available := bool(treasury.get("available", false))
	var cash := int(treasury.get("cash", 0)) if treasury_available \
		else int(context.summary.get("cash", 0))
	var model := summary_snapshot.duplicate(false)
	model["cash"] = cash
	model["nonzero_good_count"] = int(treasury.get("nonzero_good_count", 0)) \
		if treasury_available else int(context.summary.get("nonzero_good_count", 0))
	model["country_facade"] = facade
	model["economy_facade"] = economy_facade
	if normalized_section == "economy":
		model["economy_history"] = _economy_history
		model["fiscal_history"] = _fiscal_history
		model["gdp_ledger"] = _gdp_ledger
		model["strata_table"] = strata_table()
	model.merge(section_snapshot, true)
	if normalized_section in ["technology", "economy"]:
		model["procurement"] = procurement_model(economy_facade, country_handle)
	if normalized_section == "technology":
		var research: Dictionary = model.get("research", {})
		research["country_cash"] = cash
		model["research"] = research
		model.merge(build_static_catalog(), true)
	if normalized_section == "economy":
		# 与事件驱动的 `build()` 同源：国库页的军费板块要 `model["military"]`。
		build_military_spending_model(country_handle, model)
	if normalized_section in ["military", "diplomacy"]:
		# 军事面板需要 dense good id → 稳定 id 的对照表来给装备类别起名。
		model["good_ids"] = _good_stable_ids()
		build_military_model(country_handle, model)
	if normalized_section == "diplomacy":
		build_diplomacy_model(country_handle, model, facade)
	_section_cache[normalized_section] = model
	_section_cache_revisions[normalized_section] = model.get(
		"revision_components", {}).duplicate(false)
	return model

## 「军事一起不可用」的兜底段：国家壳都没就绪时也要给军事面板一个可读原因。
func _unavailable_military_section(country_handle: int, reason: String) -> Dictionary:
	return {
		"available": false,
		"reason": "军事数据暂不可用（%s）" % reason if not reason.is_empty()
			else "军事数据暂不可用",
		"facade": null,
		"country_handle": country_handle,
	}

## 军事章节的模型。军事面板有自己的视图模型（MilitaryViewModel），这里只负责
## 把「国家上下文 + 军事 facade + 目录 + 快照」装成它认识的那一份，并在
## 会话没有军事绑定时给出可恢复的原因，而不是让面板读空。
##
## 查询都发生在打开/每日刷新那一刻（走 GameUIManager 的 200ms 合并窗口），
## 不进任何热循环；`query_ms` 只用于诊断打印。
func build_military_model(country_handle: int, model: Dictionary) -> Dictionary:
	return MilitaryProjection.build_military_model(self, country_handle, model)


func _cell_name_table() -> Dictionary:
	return MilitaryProjection._cell_name_table(self)


func build_military_spending_model(country_handle: int, model: Dictionary) -> Dictionary:
	return MilitaryProjection.build_military_spending_model(self, country_handle, model)


func _military_maintenance_model(facade, country_handle: int) -> Dictionary:
	return MilitaryProjection._military_maintenance_model(self, facade, country_handle)


static func military_spending_model(snapshot: Dictionary,
		maintenance: Dictionary = {}) -> Dictionary:
	return MilitaryProjection.military_spending_model(snapshot, maintenance)


static func maintenance_detail_rows(rows) -> Array:
	return MilitaryProjection.maintenance_detail_rows(rows)


static func goods_text(milli: int) -> String:
	return MilitaryProjection.goods_text(milli)


static func cover_days_text(days_cover_x10: int) -> String:
	return MilitaryProjection.cover_days_text(days_cover_x10)


static func maintenance_signature(rows: Array, summary: Dictionary) -> int:
	return MilitaryProjection.maintenance_signature(rows, summary)


func build_diplomacy_model(country_handle: int, model: Dictionary, facade) -> Dictionary:
	return MilitaryProjection.build_diplomacy_model(self, country_handle, model, facade)


func _unavailable_diplomacy_section(reason: String) -> Dictionary:
	return MilitaryProjection._unavailable_diplomacy_section(self, reason)


func military_dossier_context(country_handle: int) -> Dictionary:
	return MilitaryProjection.military_dossier_context(self, country_handle)


func _merge_military_catalog(native_catalog: Dictionary, view: Dictionary) -> Dictionary:
	return MilitaryProjection._merge_military_catalog(self, native_catalog, view)


static func _good_stable_ids() -> PackedStringArray:
	return MilitaryProjection._good_stable_ids()


func _tax_availability(economy_facade, cell: int) -> Dictionary:
	var availability := {}
	if economy_facade == null or cell < 0:
		return availability

	if economy_facade.has_method("market_cell_snapshot"):
		var market: Dictionary = economy_facade.market_cell_snapshot(cell)
		var good_ids: PackedStringArray = market.get("good_ids", PackedStringArray())
		var good_available: PackedByteArray = market.get(
			"good_technology_available", PackedByteArray())
		if bool(market.get("ok", false)) and good_ids.size() == good_available.size():
			var goods := {}
			for index in range(good_ids.size()):
				if good_available[index] != 0:
					goods[String(good_ids[index])] = true
			availability["good"] = goods

	if economy_facade.has_method("building_cell_snapshot"):
		var buildings: Dictionary = economy_facade.building_cell_snapshot(cell)
		var building_ids: PackedStringArray = buildings.get(
			"building_type_ids", PackedStringArray())
		var building_available: PackedByteArray = buildings.get(
			"building_technology_available", PackedByteArray())
		if bool(buildings.get("ok", false)) \
				and building_ids.size() == building_available.size():
			var building_filter := {}
			for index in range(building_ids.size()):
				if building_available[index] != 0:
					building_filter[String(building_ids[index])] = true
			availability["building"] = building_filter

	var professions := {}
	var population_valid := false
	if economy_facade.has_method("population_cell_snapshot"):
		var population: Dictionary = economy_facade.population_cell_snapshot(cell)
		var population_profession_ids: PackedInt32Array = population.get(
			"profession_ids", PackedInt32Array())
		var populations: PackedInt64Array = population.get("populations", PackedInt64Array())
		var profession_stable_ids: PackedStringArray = population.get(
			"profession_stable_ids", PackedStringArray())
		# An empty profession row set is still an authoritative snapshot: it means
		# this cell currently has no cohorts, not that the population query failed.
		population_valid = bool(population.get("ok", false)) \
				and not profession_stable_ids.is_empty()
		if population_valid:
			for row in range(mini(population_profession_ids.size(), populations.size())):
				if populations[row] <= 0:
					continue
				var profession_index := int(population_profession_ids[row])
				if profession_index >= 0 and profession_index < profession_stable_ids.size():
					professions[String(profession_stable_ids[profession_index])] = true

	# A profession is tax-relevant once it exists in the country or is a role of
	# a building whose complete native technology/dependency gate is open.
	if availability.has("building"):
		var building_content := CountryCatalogPresentation._tax_content("building")
		for raw_building_id in (availability["building"] as Dictionary).keys():
			var building_item: Dictionary = building_content.get(String(raw_building_id), {})
			if building_item.is_empty():
				continue
			var owner_profession := String(building_item.get("owner_profession_id", ""))
			if not owner_profession.is_empty():
				professions[owner_profession] = true
			var employee_professions: PackedStringArray = building_item.get(
				"employee_profession_ids", PackedStringArray())
			for profession_id in employee_professions:
				professions[String(profession_id)] = true
	if population_valid or availability.has("building"):
		availability["profession"] = professions
	return availability

func _development_model(country_handle: int, research: Dictionary) -> Dictionary:
	const era_ids := DevelopmentAchievementCatalogScript.ERA_IDS
	var definitions: Array[Dictionary] = DevelopmentAchievementCatalogScript.definitions()
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	var technology_definitions: Array = TechnologyCatalogScript.public_definitions()
	var highest_era := 0
	for index in range(mini(states.size(), technology_definitions.size())):
		if int(states[index]) <= 0:
			continue
		var era_index := era_ids.find(String((technology_definitions[index] as Dictionary).get("era_id", "")))
		if era_index >= 0:
			highest_era = maxi(highest_era, era_index)
	var progress_by_signal := {}
	var trigger = _generator.get_trigger_facade() \
		if _generator != null and _generator.has_method("get_trigger_facade") else null
	if trigger != null and trigger.has_method("development_progress"):
		for era_index in range(highest_era + 1):
			var raw: Dictionary = trigger.development_progress(country_handle, String(era_ids[era_index]))
			if not bool(raw.get("ok", false)):
				continue
			var metric_ids: PackedInt32Array = raw.get("metric_ids", PackedInt32Array())
			var values: PackedInt64Array = raw.get("current_values", PackedInt64Array())
			var qualifiers: PackedInt64Array = raw.get("qualifier_thresholds", PackedInt64Array())
			var consecutive: PackedInt64Array = raw.get("consecutive_days", PackedInt64Array())
			var target_days: PackedInt32Array = raw.get("target_days", PackedInt32Array())
			var completed: PackedInt32Array = raw.get("completed", PackedInt32Array())
			for cursor in range(metric_ids.size()):
				var metric_index := int(metric_ids[cursor])
				if metric_index < 0 or metric_index >= definitions.size():
					continue
				var definition: Dictionary = definitions[metric_index]
				progress_by_signal[String(definition.get("signal_id", ""))] = {
					"metric_id": metric_index,
					"current_value": int(values[cursor]) if cursor < values.size() else 0,
					"qualifier_threshold": int(qualifiers[cursor]) if cursor < qualifiers.size() else int(definition.get("qualifier_threshold", 0)),
					"consecutive_days": int(consecutive[cursor]) if cursor < consecutive.size() else 0,
					"target_days": int(target_days[cursor]) if cursor < target_days.size() else int(definition.get("duration_days", 1)),
					"completed": int(completed[cursor]) if cursor < completed.size() else 0,
				}
	# A completed permanent signal remains explainable even if its Trigger state
	# has been compacted or the cold query is temporarily unavailable.
	var signal_snapshot: Dictionary = research.get("research_signal_snapshot", {})
	var signal_ids: PackedInt32Array = signal_snapshot.get("signal_ids", PackedInt32Array())
	var signal_metadata: Array = ResearchSignalCatalogScript.public_metadata()
	for signal_index in signal_ids:
		if signal_index < 0 or signal_index >= signal_metadata.size():
			continue
		var signal_id := String((signal_metadata[signal_index] as Dictionary).get("id", ""))
		if signal_id.begins_with("development.") and not progress_by_signal.has(signal_id):
			progress_by_signal[signal_id] = {"completed": 1}
	# Development progress is explained only by the selected technology gates.
	return {"ok": true, "progress_by_signal": progress_by_signal}

func _ideology_model(country_handle: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_ideology_facade"):
		return {"available": false, "reason": "理念事务暂不可用。"}
	var facade = _generator.get_ideology_facade()
	if facade == null or not facade.has_method("is_configured") or not facade.is_configured():
		return {"available": false, "reason": "理念事务尚未就绪。"}
	var snapshot: Dictionary = facade.snapshot(country_handle)
	var catalog: Dictionary = facade.catalog_view()
	if not bool(snapshot.get("ok", false)) or not bool(catalog.get("ok", false)):
		return {"available": false, "reason": ideology_player_reason(String(snapshot.get("reason",
			catalog.get("reason", "理念数据暂不可用。"))))}
	return _decorate_ideology({
		"available": true, "facade": facade, "snapshot": snapshot, "catalog": catalog,
	}, country_handle)

func _decorate_ideology(ideology: Dictionary, country_handle: int) -> Dictionary:
	var snapshot: Dictionary = ideology.snapshot.duplicate()
	snapshot["offer_eligibility"] = ideology.facade.preview_offer_eligibility(country_handle)
	ideology["snapshot"] = snapshot
	ideology["presentation"] = present_ideology(snapshot, ideology.catalog)
	return ideology

static func present_ideology(snapshot: Dictionary, catalog: Dictionary) -> Dictionary:
	return IdeologyPresentation.present_ideology(snapshot, catalog)


static func present_ideology_card(metadata: Dictionary, level: int = 0,
		effect_row: Dictionary = {}) -> Dictionary:
	return IdeologyPresentation.present_ideology_card(metadata, level, effect_row)

static func ideology_player_reason(reason: String) -> String:
	return IdeologyPresentation.ideology_player_reason(reason)

## 国家购买预算快照（EconomyFacade.country_procurement_snapshot）。原生接口缺席或
## 查询失败时返回 {available: false}，UI 退回按国库现金估算，不显示实付分项。
static func procurement_model(economy_facade, country_handle: int) -> Dictionary:
	return FiscalProjection.procurement_model(economy_facade, country_handle)


static func present_procurement(snapshot: Dictionary) -> Dictionary:
	return FiscalProjection.present_procurement(snapshot)


func _treasury_model(facade, country_handle: int) -> Dictionary:
	return FiscalProjection._treasury_model(self, facade, country_handle)


static func present_treasury(snapshot: Dictionary) -> Dictionary:
	return FiscalProjection.present_treasury(snapshot)


static func present_tax_policy(tax_policy: Dictionary, completed_technologies,
		availability: Dictionary = {}) -> Dictionary:
	return FiscalProjection.present_tax_policy(tax_policy, completed_technologies, availability)


static func _present_tax_policy(tax_policy: Dictionary, completed_technologies,
		availability: Dictionary) -> Dictionary:
	return FiscalProjection._present_tax_policy(tax_policy, completed_technologies, availability)


static func _present_items(ids: PackedStringArray, kind: String,
		completed: Dictionary, allow_tradeable: bool = false,
		tradeable_only: bool = false, available_ids: Dictionary = {},
		enforce_available: bool = false) -> Dictionary:
	return FiscalProjection._present_items(ids, kind, completed, allow_tradeable, tradeable_only, available_ids, enforce_available)


func _unavailable_treasury(reason: String) -> Dictionary:
	return FiscalProjection._unavailable_treasury(self, reason)


static func _unavailable_treasury_static(reason: String) -> Dictionary:
	return FiscalProjection._unavailable_treasury_static(reason)


func _unavailable_model(reason: String) -> Dictionary:
	return {
		"available": false,
		"country_name": "国家事务",
		"reason": reason,
		"territory_count": 0,
		"cash": 0,
		"nonzero_good_count": 0,
		"technology_count": 0,
		"treasury": _unavailable_treasury(reason),
	}
