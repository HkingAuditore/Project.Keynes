# Pure building catalog compiler. It owns only temporary arrays while compiling.
extends RefCounted

const Steps = preload("res://scripts/economy/economy_building_catalog_compile_steps.gd")

static func compile(
		profiles: Array, climate_profiles: Array, profession_index: Dictionary,
		good_index: Dictionary, good_storage_modes: PackedInt32Array,
		good_monetary_issue_values: PackedInt64Array,
		good_substitution_category_offsets: PackedInt32Array,
		good_substitution_category_ids: PackedStringArray,
		good_quality_levels: PackedInt32Array,
		good_efficiencies_q16: PackedInt32Array,
		profession_state_service_only: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return Steps.compile.call(null, profiles, climate_profiles, profession_index, good_index, good_storage_modes, good_monetary_issue_values, good_substitution_category_offsets, good_substitution_category_ids, good_quality_levels, good_efficiencies_q16, profession_state_service_only)

static func compile_cooperative(context,
		profiles: Array, climate_profiles: Array, profession_index: Dictionary,
		good_index: Dictionary, good_storage_modes: PackedInt32Array,
		good_monetary_issue_values: PackedInt64Array,
		good_substitution_category_offsets: PackedInt32Array,
		good_substitution_category_ids: PackedStringArray,
		good_quality_levels: PackedInt32Array,
		good_efficiencies_q16: PackedInt32Array,
		profession_state_service_only: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return await Steps.compile(context, profiles, climate_profiles, profession_index, good_index, good_storage_modes, good_monetary_issue_values, good_substitution_category_offsets, good_substitution_category_ids, good_quality_levels, good_efficiencies_q16, profession_state_service_only)
