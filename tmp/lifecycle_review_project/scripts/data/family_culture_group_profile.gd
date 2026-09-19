class_name FamilyCultureGroupProfile
extends Resource

@export var stable_id: StringName = &"default"
@export var display_name: String = ""
@export_enum("CITY_SURNAME_SUFFIX", "CITY_SEPARATOR_SURNAME", "CITY_SURNAME")
var naming_format: String = "CITY_SURNAME_SUFFIX"
@export var separator: String = "-"
@export var suffix: String = "氏"
@export var surname_ids: PackedStringArray = PackedStringArray()
@export var surname_text: PackedStringArray = PackedStringArray()
@export var weights: PackedInt32Array = PackedInt32Array()
