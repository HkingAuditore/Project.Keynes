extends SceneTree

const TerrainBakerScript = preload("res://scripts/rendering/bakers/terrain_baker.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	var baker := MapBaker.new()
	baker._init_noise(20260728)
	var x := 137.25
	var y := 89.75
	var wrap_period := 512.0
	var hex_size := 8.0
	var reference: float = TerrainBakerScript.terrain_detail_bake_scalar(
		baker._detail_noise, baker._ridge_noise, x, y, wrap_period, hex_size, 0.70, 1.30)
	for biome in [
		TerrainType.TERRAIN.FOREST,
		TerrainType.TERRAIN.DESERT,
		TerrainType.TERRAIN.MOUNTAIN,
		TerrainType.TERRAIN.SWAMP,
		TerrainType.TERRAIN.SNOW,
		TerrainType.TERRAIN.OCEAN,
	]:
		var value: float = TerrainBakerScript.terrain_detail_bake_scalar(
			baker._detail_noise, baker._ridge_noise, x, y, wrap_period, hex_size, 0.70, 1.30)
		_expect(is_equal_approx(reference, value),
			"macro signal is biome-independent for %s" % TerrainType.terrain_name(int(biome)))
	var wrapped: float = TerrainBakerScript.terrain_detail_bake_scalar(
		baker._detail_noise, baker._ridge_noise, x + wrap_period, y, wrap_period, hex_size, 0.70, 1.30)
	_expect(absf(reference - wrapped) < 0.00001, "macro signal is continuous across world wrap")
	_expect(reference >= 0.70 and reference <= 1.30, "macro signal stays inside encoding range")
	print("=== terrain detail continuity: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
