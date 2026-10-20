extends SceneTree

const ViewModel = preload("res://scripts/ui/annual_report_view_model.gd")
const ProfileScript = preload("res://scripts/annual/annual_report_profile.gd")
var failures: int = 0

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		failures += 1

func _run() -> void:
	var ext = ClassDB.instantiate("DCWorldExt")
	_expect("native annual API exists", ext != null and ext.has_method("annual_report_self_test"))
	if ext != null:
		var native: Dictionary = ext.annual_report_self_test()
		_expect("native totals, dedupe, reward, save checksum and survival cap", bool(native.get("ok", false)))
		if not bool(native.get("ok", false)):
			print(native)
	var raw := fixture()
	var model: Dictionary = ViewModel.build(raw)
	var text: String = model.get("full_text", "")
	_expect("nine data chapters", model.get("chapters", []).size() == 9)
	_expect("copy includes scoring and chapter titles", text.contains("发展考核") and text.contains("GDP 增长") and text.contains("资源与年度问题"))
	_expect("every chapter carries a one-line data label",
		model.chapters.all(func(chapter: Dictionary) -> bool: return not String(chapter.get("lead", "")).is_empty()))
	_expect("copy drops method notes", not text.contains("口径") and not text.contains("满分目标"))
	_expect("first year does not invent prior GDP", model.chapters[1].rows[0].previous == "无可比数据")
	_expect("percentage changes use percentage points", text.contains("个百分点"))
	_expect("title includes year and country", String(model.title).contains("第 1 年") and model.country_name == raw.country_name)
	_expect("reward renders exact points", model.reward_text == "48")
	_expect("cut-paper era artwork selected", String(model.art_path).ends_with("stone.png"))
	var partial: Dictionary = raw.duplicate(true)
	partial.complete = false
	partial.grade = "—"
	partial.reward_q16 = 0
	var partial_model: Dictionary = ViewModel.build(partial)
	_expect("partial year keeps grade and reward blank",
		String(partial_model.chapters[8].figures[1].text) == "—"
		and String(partial_model.chapters[8].figures[2].text) == "0")
	var negative: Dictionary = raw.duplicate(true)
	negative.totals.gdp = -50000
	var previous: Dictionary = raw.duplicate(true)
	previous.totals.gdp = 0
	_expect("zero baseline has no false percent", ViewModel.build(negative, previous).chapters[1].rows[0].rate == "无可比数据")
	_expect("all 11 illustrations exist", _all_art_exists())
	var compiled: Dictionary = ProfileScript.new().compile_native(TechnologyCatalog.compile_native_catalog(), {"offer_cost_q16": 393216, "offer_cost_growth_percent": 120, "offer_cost_max_q16": 1000000000000})
	_expect("profile compiles dense technology equivalents", compiled.technology_equivalents_q16.size() > 0 and compiled.era_milestones.size() == 11)
	# ── 纸本长卷所需的派生量（图表与账簿不能靠格式化字符串反解） ──────────────
	var gdp_row: Dictionary = model.chapters[1].rows[0]
	_expect("row exposes normalized raw value", is_equal_approx(float(gdp_row.get("value", -1.0)), 12850.0) and gdp_row.get("has_baseline") == false)
	_expect("first year reports no baseline", model.get("has_previous") == false and model.chapters[1].get("has_previous") == false)
	_expect("chapter figures are structured", model.chapters[1].get("figures", []).size() == 3 and model.chapters[1].figures[0].has("text"))
	_expect("grade bands cover the full axis", model.get("grade_bands", []).size() == 7 and float(model.grade_bands[0].min) == 94.0)
	_expect("tax parts drop zero entries", model.get("tax_parts", []).size() == 4 and float(model.get("tax_total", 0.0)) > 0.0)
	_expect("monthly visual keeps twelve slots", model.chapters[1].get("visuals", []).size() == 1 and model.chapters[1].visuals[0].get("gdp", PackedFloat64Array()).size() == 12)
	_expect("satisfaction visual is a radar", String(model.chapters[2].visuals[0].get("kind", "")) == "radar")
	var score_kinds: Array = []
	for visual in model.chapters[8].get("visuals", []):
		score_kinds.append(String(visual.get("kind", "")))
	_expect("scoring chapter ships parts and ruler", score_kinds.has("score_parts") and score_kinds.has("grade_ruler"))
	var with_previous: Dictionary = raw.duplicate(true)
	with_previous.totals = raw.totals.duplicate(true)
	with_previous.totals.gdp = 100000000
	var prior: Dictionary = {"totals": {"gdp": 100000000}, "closing": {}}
	var compared: Dictionary = ViewModel.build(with_previous, prior)
	_expect("comparable year keeps baseline columns", compared.get("has_previous") == true and compared.chapters[1].rows[0].get("has_baseline") == true)
	print("annual_report_test: %d failures" % failures)
	quit(0 if failures == 0 else 1)

func _all_art_exists() -> bool:
	for era in ViewModel.ERA_IDS:
		if not ResourceLoader.exists("res://assets/ui/annual_chronicle/%s.png" % era):
			return false
	return true

static func fixture() -> Dictionary:
	return {"ok": true, "id": 1, "year": 0, "country_name": "河湾共同体", "era": 0,
		"complete": true, "grade": "S", "grade_index": 1, "score_bp": 9000,
		"reward_q16": 48 * 65536, "reward_settled": true,
		"quality_average": PackedInt64Array([60000, 64000, 62000, 60000]),
		"score_parts": PackedInt64Array([1900, 1950, 1400, 1350, 640, 480, 400, 240, 240, 400]),
		"opening": {"population": 20, "buildings": 6, "satisfaction": 50000, "survival": 55000,
			"tiers": PackedInt64Array([0, 1, 0, 0, 0, 0, 0, 0])},
		"closing": {"population": 46, "buildings": 18, "tiers": PackedInt64Array([0, 2, 0, 0, 0, 0, 0, 0]),
			"towns": [{"cell": 17, "tier": 1, "population": 46, "buildings": 18}],
			"professions": [], "resources": []},
		"totals": {"gdp": 128500000, "population": 46, "employed": 44, "buildings": 18,
			"built": 12, "territory": 2, "settlements": 2, "technologies": 8,
			"satisfaction": 60000, "survival": 64000, "utilization": 57000,
			"wages": 25000000, "wages_due": 25000000, "treasury": 3870000,
			"trade_value": 8750000, "trade_quantity": 315000, "trade_orders": 28, "income_tax": 3260000, "consumption_tax": 850000, "business_tax": 1450000, "import_tax": 125000, "export_tax": 0, "subsidies": 325000, "producer_support": 180000, "research_purchased": 16000, "research_consumed": 12000, "household_income": 48500000, "household_expense": 42400000, "funds": 65200000, "families": 6, "persons": 7, "pending_buildings": 3, "suspended": 0, "removed": 0, "job_capacity": 50, "output": 2160000, "sold": 1840000, "discarded": 16000, "resource_extracted": 524000, "climate_loss": 24000, "settlements_founded": 1, "settlements_lost": 0, "settlements_upgraded": 1, "settlements_downgraded": 0, "births": 27, "deaths": 1, "revenue": 182000000, "input_cost": 41000000,
			"maintenance": 12500000, "profit": 103500000},
		"new_technologies": PackedInt64Array([0, 1, 2]), "industry_totals": [], "resource_totals": [],
		"monthly_gdp": PackedInt64Array([1000000, 2000000, 3000000, 5000000, 7000000, 9000000, 11000000, 12500000, 14000000, 18000000, 21000000, 25000000]),
		"monthly_population": PackedInt64Array([20, 22, 24, 26, 29, 31, 34, 36, 38, 41, 43, 46])}
