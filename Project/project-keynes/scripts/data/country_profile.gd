class_name CountryProfile
extends Resource

@export_enum("OFF", "PROBE", "ACTIVE") var country_runtime_mode: String = "ACTIVE"
@export_range(1, 1048576, 1) var country_max_commands_per_slice: int = 65536
@export_range(65536, 16777216, 65536) var save_chunk_bytes: int = 4194304
@export var starting_technology_ids: PackedStringArray = PackedStringArray()

func to_native_profile() -> Dictionary:
	return {
		"country_runtime_mode": country_runtime_mode,
		"country_max_commands_per_slice": country_max_commands_per_slice,
		"starting_technology_ids": starting_technology_ids,
	}
