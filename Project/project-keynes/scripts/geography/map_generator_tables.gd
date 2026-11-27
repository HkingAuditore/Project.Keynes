extends RefCounted

const MAPGEN_REQUIRED_NATIVE_METHODS := [
	"run_native_world_generate_full_pass",
	"run_native_world_generate_base_pass",
	"run_native_world_generate_post_base_pass",
	"run_bake_geometry_fields_pass",
]

const _RUNTIME_CLIMATE_ROUND_REQUIRED_LANES: Array = [
	"is_water", "cover", "ema_initialized", "elevation", "base_moisture",
	"lat_norm", "temp_baseline_year", "temp", "temp_30d", "temp_365d",
	"thermal_energy", "snowpack",
]

const BIO_LOG_CLASS_NAMES := [
	"none", "open_food", "wetland_food", "highland_food", "open_grazer",
	"forest_grazer", "dry_grazer", "cold_grazer", "tropical", "fiber_open",
	"fiber_wet", "fiber_forest",
]

const LOADING_TAIL_STAGE_RULES := [
	["resource", "resources"],
	["bio", "ecology_bind"],
	["economy", "gameplay_bind"],
	["country", "gameplay_bind"],
	["ideology", "gameplay_bind"],
	["settlement", "gameplay_bind"],
	["modifier", "gameplay_bind"],
	["trigger", "gameplay_bind"],
	["effect", "gameplay_bind"],
	["native_daily", "runtime_bind"],
	["sus", "runtime_bind"],
	["topology", "runtime_bind"],
]

const WEATHER_VITALITY_PENALTY: Dictionary = {
	WeatherType.WT.DROUGHT: 0.004,
	WeatherType.WT.BLIZZARD: 0.002,
	WeatherType.WT.HEATWAVE: 0.003,
	WeatherType.WT.STORM: 0.001,
	WeatherType.WT.MONSOON: 0.001,
}
