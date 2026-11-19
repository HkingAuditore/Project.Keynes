extends SceneTree

const MapCountryInitializer := preload("res://scripts/country/map_country_initializer.gd")
const IdeologyCatalog := preload("res://scripts/ideology/ideology_catalog.gd")


func _initialize() -> void:
	var start_failure := MapCountryInitializer._ideology_catalog_request_failure(
		ERR_CANT_CREATE, true, null)
	var null_result_failure := MapCountryInitializer._ideology_catalog_request_failure(
		OK, true, null)
	var loaded := ResourceLoader.load(IdeologyCatalog.DEFAULT_PATH, "Resource") as Resource
	var threaded_result_used := loaded != null and IdeologyCatalog.load_default(loaded) == loaded
	var ok := not start_failure.is_empty() and not null_result_failure.is_empty() \
		and threaded_result_used
	print("ideology catalog load contract: ", ok)
	quit(0 if ok else 1)
