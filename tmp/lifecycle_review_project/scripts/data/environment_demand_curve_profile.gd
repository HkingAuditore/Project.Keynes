class_name EnvironmentDemandCurveProfile
extends Resource

## signal_id: temperature, moisture, snow_cover, weather_intensity.
## values_q16 contains exactly 17 samples over normalized [0, 1].
@export var id: StringName = &""
@export_enum("temperature", "moisture", "snow_cover", "weather_intensity") var signal_id: String = "temperature"
@export var values_q16: PackedInt32Array = PackedInt32Array([
	65536, 65536, 65536, 65536, 65536, 65536, 65536, 65536, 65536,
	65536, 65536, 65536, 65536, 65536, 65536, 65536, 65536,
])
