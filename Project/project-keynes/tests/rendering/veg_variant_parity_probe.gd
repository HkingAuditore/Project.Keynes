extends SceneTree

## Compare current production runtime programs with the boot warmup plan.
## Historical browser fingerprints are observations, not a source-code contract.
const ShrubLayerScript = preload("res://scripts/rendering/shrub_layer.gd")
const Variants = preload("res://scripts/rendering/vegetation_shader_variants.gd")
const WorldDataScript = preload("res://scripts/geography/world_data.gd")
var _failures: Array[String] = []

class FakeLayout extends RefCounted:
	var mode := "tiled"
class FakeTiles extends RefCounted:
	var ready := true
	var layout: Object

func _init() -> void:
	var warm := ShrubLayerScript.web_warmup_shader_codes()
	_expect("layer forwards the current shared warmup plan", warm == Variants.web_warmup_shader_codes())
	var unique := {}
	for code in warm.values():
		_expect("warmup programs are unique", not unique.has(String(code)))
		unique[String(code)] = true
	for tier in [0, 1, 2]:
		for tiled in [false, true]:
			for known in [false, true]:
				for force in [false, true]:
					for high in [false, true]:
						var prefix := ShrubLayerScript.web_define_prefix(tier, tiled, known, force, high)
						_expect("runtime and shared prefixes agree", prefix == Variants.web_define_prefix(tier, tiled, known, force, high))
						_expect("web branch is explicit", prefix.contains("#define PK_WEB_VEGETATION\n"))
						_expect("tile macro follows the actual layout", prefix.contains("#define MAP_VISUAL_TILED\n") == tiled)
						var pc: bool = high and known and not force
						_expect("PC forms only apply to the visible HIGH program", prefix.contains("#define PK_WEB_PC_HIGH\n") == pc)
						_expect("forced distant forms retain their gate", not force or prefix.contains("#define PK_VEG_FAR_ONLY\n"))
						var batch := Variants.family_prefix(prefix)
						_expect("PC family programs release the horizon texture slot", batch.contains("#define PK_SKIP_HORIZON_SHADOWS\n") == pc)
						# Web boot uses the fixed LOW tier and a non-tiled map. Both
						# early/ready worlds and hidden/visible family batches occur.
						if tier == ShrubLayerScript.WEB_SHADER_QUALITY_TIER and not tiled:
							for source in [prefix + Variants._SHADER_CODE,
								prefix + Variants._SHADOW_SHADER_CODE,
								prefix + "#define DETAIL_FAMILY_BATCH\n" + Variants._SHADOW_SHADER_CODE,
								batch + "#define DETAIL_FAMILY_BATCH\n" + Variants._SHADER_CODE]:
								_expect("a boot runtime variant is present byte-for-byte in warmup", unique.has(source))
	var wrong := Variants.web_define_prefix(1, false, false) + Variants._SHADER_CODE
	_expect("a same-length MID prefix cannot pass the LOW parity check", not unique.has(wrong))
	_check_desktop_bytes()
	print("vegetation variant parity: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)

func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)
		push_error(label)

func _fp(code: String) -> String:
	return "%d:%d" % [code.length(), code.hash()]

func _check_desktop_bytes() -> void:
	print("\n=== [5] desktop (non-web) prefix regression ===")
	var layer = ShrubLayerScript.new()
	# 改动前的行为（逐字节）：非 (mobile|web) → 只有 tiled 前缀。
	var cases := [
		{"name": "world=null            ", "world": null, "tiles": null},
		{"name": "world no tiles        ", "world": WorldDataScript.new(), "tiles": null},
		{"name": "world tiled ready     ", "world": WorldDataScript.new(), "tiles": "tiled"},
		{"name": "world tiled not ready ", "world": WorldDataScript.new(), "tiles": "not_ready"},
		{"name": "world legacy mode     ", "world": WorldDataScript.new(), "tiles": "legacy"},
	]
	for tier in [0, 1, 2]:
		for c in cases:
			var world = c["world"]
			if world != null and c["tiles"] != null:
				var tiles := FakeTiles.new()
				var layout := FakeLayout.new()
				if String(c["tiles"]) == "not_ready":
					tiles.ready = false
				elif String(c["tiles"]) == "legacy":
					layout.mode = "legacy"
				tiles.layout = layout
				world.visual_tiles = tiles
			layer._world = world
			layer._mobile_quality_tier = tier
			var got := String(layer._shader_quality_define_prefix())
			var want := "#define MAP_VISUAL_TILED\n" \
				if (world != null and world.visual_tiles != null
					and bool(world.visual_tiles.ready)
					and String(world.visual_tiles.layout.mode) == "tiled") else ""
			var ok := got == want and not got.contains("MOBILE_QUALITY_")
			print("  tier=%d %s -> %s  %s" % [tier, String(c["name"]),
				"\"\"" if got.is_empty() else got.replace("\n", "|"), "OK" if ok else "FAIL"])
			if not ok:
				_failures.append("桌面前缀被改动：tier=%d %s got=%s want=%s"
					% [tier, String(c["name"]), got, want])
	layer.free()

	# 真建一次桌面材质：桌面拿到的必须是"裸源码"（无档位宏 / 无 tiled / 无 form 档），
	# 与改动前逐字节相同。
	var layer2 = ShrubLayerScript.new()
	layer2._ensure_resources()
	var got_body := String(layer2._material.shader.code)
	var got_shadow := String(layer2._shadow_material.shader.code)
	var got_family := String(layer2.detail_family_material(null).shader.code)
	var want_family := "#define DETAIL_FAMILY_BATCH\n" \
		+ String(ShrubLayerScript._SHADER_CODE)
	var body_ok := got_body == String(ShrubLayerScript._SHADER_CODE)
	var shadow_ok := got_shadow == String(ShrubLayerScript._SHADOW_SHADER_CODE)
	var family_ok := got_family == want_family
	print("  material body   == raw source : %s (%s)" % [
		"OK" if body_ok else "FAIL", _fp(got_body)])
	print("  material shadow == raw source : %s (%s)" % [
		"OK" if shadow_ok else "FAIL", _fp(got_shadow)])
	print("  material family == DETAIL+raw : %s (%s)" % [
		"OK" if family_ok else "FAIL", _fp(got_family)])
	if not body_ok:
		_failures.append("桌面 body 材质源码被改动（应等于裸源码）")
	if not shadow_ok:
		_failures.append("桌面 shadow 材质源码被改动（应等于裸源码）")
	if not family_ok:
		_failures.append("桌面 family 材质源码被改动（应等于 DETAIL_FAMILY_BATCH + 裸源码）")
	layer2.free()
