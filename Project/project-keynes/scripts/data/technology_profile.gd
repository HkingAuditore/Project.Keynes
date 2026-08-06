class_name TechnologyProfile
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var era_id: StringName = &""
@export var domain_id: StringName = &""
@export_range(0, 1000000000000, 1) var cost_points: int = 0
@export var prerequisite_ids: PackedStringArray = PackedStringArray()
## Optional data-driven gates. prerequisite_ids remains the compatibility
## shorthand for ALL_OF(TECH_COMPLETED(...)).
@export var reveal_condition: Resource
@export var research_condition: Resource
@export var milestone_candidate_ids: PackedStringArray = PackedStringArray()
@export_range(0, 4, 1) var milestone_required_count: int = 0
@export var is_milestone: bool = false
@export var is_era_key: bool = false
@export var modifier_definition_ids: PackedStringArray = PackedStringArray()
@export var effect_summary: String = ""
@export var semantic_icon: StringName = &"country.technology"
@export var ui_column: int = 0
@export var ui_row: int = 0
