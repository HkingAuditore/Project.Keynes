extends SceneTree

const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")


class EmptyCellEconomyFacade extends RefCounted:
	var cohort_professions := PackedInt32Array()
	var cohort_populations := PackedInt64Array()
	func market_cell_snapshot(_cell: int) -> Dictionary:
		return {
			"ok": true,
			"good_ids": PackedStringArray(["grain"]),
			"good_technology_available": PackedByteArray([1]),
		}

	func building_cell_snapshot(_cell: int) -> Dictionary:
		return {
			"ok": true,
			"building_type_ids": PackedStringArray(["adobe_yard"]),
			"building_technology_available": PackedByteArray([1]),
		}

	func population_cell_snapshot(_cell: int) -> Dictionary:
		return {
			"ok": true,
			"profession_ids": cohort_professions,
			"populations": cohort_populations,
			"profession_stable_ids": PackedStringArray(["artisan", "engineer", "merchant"]),
		}


func _init() -> void:
	var policy := {
		"ok": true,
		"profession_ids": PackedStringArray(["artisan", "engineer"]),
		"good_ids": PackedStringArray(["clothing", "grain", "automobiles", "electricity"]),
		"building_type_ids": PackedStringArray(["adobe_yard", "advanced_chip_fab"]),
	}

	# Direct content tags are alternatives. One clothing route is enough, while
	# a good with an unrelated technology remains hidden from consumption tax.
	var direct := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.hide_scraping"]))
	var direct_consumption := _ids(direct, "consumption")
	assert(direct_consumption.has("clothing"), "alternative direct tech should unlock clothing")
	assert(not direct_consumption.has("grain"), "uncompleted good tech must stay hidden")
	for kind in ["import", "export"]:
		var tariff_ids := _ids(direct, kind)
		assert(tariff_ids.has("clothing"), "unlocked tradeable good must appear in tariffs")
		assert(not tariff_ids.has("grain") and not tariff_ids.has("automobiles"),
			"tradeability must not bypass tariff technology requirements")

	# Building direct tags use ANY semantics, while required tags use ALL.
	var adobe_only := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.adobe_making"]))
	assert(not _ids(adobe_only, "business").has("adobe_yard"),
		"building support technology must not be skipped")
	var adobe_ready := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.adobe_making", "tech.gathering"]))
	assert(_ids(adobe_ready, "business").has("adobe_yard"),
		"building should unlock when direct and required techs are complete")
	assert(_ids(direct, "income").is_empty(),
		"missing availability must not expose professions from locked buildings")
	assert(_ids(adobe_ready, "income").has("artisan") and
			not _ids(adobe_ready, "income").has("engineer"),
		"fallback must derive professions from unlocked building roles")
	var advanced_ready := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.machine_learning", "tech.industrial_chemistry",
			"tech.specialty_alloys"]))
	assert(_ids(advanced_ready, "income").has("engineer"),
		"newly unlocked building employee roles must become visible")
	var no_professions := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.adobe_making", "tech.gathering"]), {"profession": {}})
	assert(_ids(no_professions, "income").is_empty(),
		"an authoritative empty profession mask must override fallback roles")

	# A native availability mask is authoritative for the live country view and
	# must remove catalog entries even when their static tags look complete.
	var masked := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray([
			"tech.hide_scraping", "tech.household_landholding",
			"tech.robotic_manufacturing", "tech.electric_generation",
			"tech.adobe_making", "tech.gathering",
		]), {
			"profession": {"artisan": true},
			"good": {"grain": true, "electricity": true},
			"building": {"adobe_yard": true},
		})
	assert(_ids(masked, "income").has("artisan") and
			not _ids(masked, "income").has("engineer"),
		"profession availability mask leaked an unavailable class")
	assert(_ids(masked, "consumption").has("grain") and
			not _ids(masked, "consumption").has("clothing"),
		"good availability mask leaked an unavailable good")
	for kind in ["import", "export"]:
		var tariff_ids := _ids(masked, kind)
		assert(tariff_ids.has("grain") and not tariff_ids.has("clothing") and
				not tariff_ids.has("automobiles"),
			"tariff pages must honor the native good availability mask")
		assert(not tariff_ids.has("electricity"),
			"available nontradeable goods must stay hidden from tariffs")
	var no_goods := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.hide_scraping"]), {"good": {}})
	assert(_ids(no_goods, "import").is_empty() and _ids(no_goods, "export").is_empty(),
		"an authoritative empty availability mask must hide all tariff goods")
	assert(_ids(masked, "business").has("adobe_yard") and
			not _ids(masked, "business").has("advanced_chip_fab"),
		"building availability mask leaked an unavailable building")

	# An empty cell still has an authoritative population snapshot. Its available
	# building roles must remain visible without reopening the full profession list.
	var view_model := CountryViewModelScript.new()
	var empty_cell_availability: Dictionary = view_model._tax_availability(
		EmptyCellEconomyFacade.new(), 0)
	assert(empty_cell_availability.has("profession") and
			(empty_cell_availability["profession"] as Dictionary).has("artisan") and
			not (empty_cell_availability["profession"] as Dictionary).has("engineer"),
		"empty population snapshots must keep building owner roles without leaking classes")
	var residual_cohorts := EmptyCellEconomyFacade.new()
	residual_cohorts.cohort_professions = PackedInt32Array([1, 1, 2])
	residual_cohorts.cohort_populations = PackedInt64Array([0, 0, 50])
	var residual_availability: Dictionary = view_model._tax_availability(residual_cohorts, 0)
	var residual_professions: Dictionary = residual_availability.get("profession", {})
	assert(not residual_professions.has("engineer") and residual_professions.has("merchant")
			and residual_professions.has("artisan"),
		"zero population rows must not unlock classes; live cohorts and building roles must remain")
	print("[PASS] tax policy unlock filtering, fallback professions and residual cohorts")
	quit()


func _ids(presentation: Dictionary, page: String) -> Dictionary:
	var result := {}
	var rows: Array = (presentation.get(page, {}) as Dictionary).get("unlocked", [])
	for row_value in rows:
		result[String((row_value as Dictionary).get("id", ""))] = true
	return result
