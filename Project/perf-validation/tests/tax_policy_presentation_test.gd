extends SceneTree

const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")


class EmptyCellEconomyFacade extends RefCounted:
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
			"profession_ids": PackedInt32Array(),
			"profession_stable_ids": PackedStringArray(["artisan", "engineer"]),
		}


func _init() -> void:
	var policy := {
		"ok": true,
		"profession_ids": PackedStringArray(["artisan", "engineer"]),
		"good_ids": PackedStringArray(["clothing", "grain", "automobiles"]),
		"building_type_ids": PackedStringArray(["adobe_yard", "advanced_chip_fab"]),
	}

	# Direct content tags are alternatives. One clothing route is enough, while
	# a good with an unrelated technology remains hidden from consumption tax.
	var direct := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.wild_flax_collection"]))
	var direct_consumption := _ids(direct, "consumption")
	assert(direct_consumption.has("clothing"), "alternative direct tech should unlock clothing")
	assert(not direct_consumption.has("grain"), "uncompleted good tech must stay hidden")

	# Building direct tags use ANY semantics, while required tags use ALL.
	var adobe_only := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.adobe_making"]))
	assert(not _ids(adobe_only, "business").has("adobe_yard"),
		"building support technology must not be skipped")
	var adobe_ready := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray(["tech.adobe_making", "tech.earth_building"]))
	assert(_ids(adobe_ready, "business").has("adobe_yard"),
		"building should unlock when direct and required techs are complete")

	# A native availability mask is authoritative for the live country view and
	# must remove catalog entries even when their static tags look complete.
	var masked := CountryViewModelScript.present_tax_policy(policy,
		PackedStringArray([
			"tech.wild_flax_collection", "tech.household_landholding",
			"tech.internal_combustion", "tech.adobe_making", "tech.earth_building",
		]), {
			"profession": {"artisan": true},
			"good": {"grain": true},
			"building": {"adobe_yard": true},
		})
	assert(_ids(masked, "income").has("artisan") and
			not _ids(masked, "income").has("engineer"),
		"profession availability mask leaked an unavailable class")
	assert(_ids(masked, "consumption").has("grain") and
			not _ids(masked, "consumption").has("clothing"),
		"good availability mask leaked an unavailable good")
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
	quit()


func _ids(presentation: Dictionary, page: String) -> Dictionary:
	var result := {}
	var rows: Array = (presentation.get(page, {}) as Dictionary).get("unlocked", [])
	for row_value in rows:
		result[String((row_value as Dictionary).get("id", ""))] = true
	return result
