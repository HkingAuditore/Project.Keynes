class_name CountryProfile
extends Resource

@export_enum("OFF", "PROBE", "ACTIVE") var country_runtime_mode: String = "ACTIVE"
## ACTIVE defaults to the lightweight report.  PROBE remains full diagnostic;
## this switch is for explicit debug/A-B runs without changing authority.
@export var country_full_diagnostics: bool = false
@export var country_light_report_enabled: bool = true
@export var country_pending_queue_enabled: bool = true
@export_range(1, 1048576, 1) var country_max_commands_per_slice: int = 65536
@export_range(65536, 16777216, 65536) var save_chunk_bytes: int = 4194304
@export var starting_technology_ids: PackedStringArray = PackedStringArray()

func to_native_profile() -> Dictionary:
	return {
		"country_runtime_mode": country_runtime_mode,
		"country_full_diagnostics": country_full_diagnostics,
		"country_light_report_enabled": country_light_report_enabled,
		"country_pending_queue_enabled": country_pending_queue_enabled,
		"country_max_commands_per_slice": country_max_commands_per_slice,
		"starting_technology_ids": starting_technology_ids,
	}
