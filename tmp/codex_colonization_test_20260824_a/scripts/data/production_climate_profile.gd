class_name ProductionClimateProfile
extends Resource

@export var id: StringName = &""
@export_range(0.0, 1.0, 0.001) var temperature_opt: float = 0.5
@export_range(0.001, 1.0, 0.001) var temperature_tolerance: float = 1.0
@export_range(0.0, 1.0, 0.001) var water_opt: float = 0.5
@export_range(0.001, 1.0, 0.001) var water_tolerance: float = 1.0
@export_range(0, 65536, 1) var exposure_q16: int = 65536
@export_range(0, 65536, 1) var floor_q16: int = 0
