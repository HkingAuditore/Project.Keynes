class_name TechnologyDomainProfile
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var semantic_icon: StringName = &"country.technology"
@export var accent: Color = Color.WHITE
@export_range(0, 10000, 1) var default_weight_bp: int = 2500
@export_range(0, 255, 1) var sort_order: int = 0
