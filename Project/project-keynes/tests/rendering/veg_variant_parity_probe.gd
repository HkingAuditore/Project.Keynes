extends SceneTree

## Headless 变体指纹探针：菜单期预热源码 vs 运行期真正会编的源码。
##
## 为什么需要：Compatibility/WebGL2 上 shader 只在「赋值 Shader.code」时真编。前缀差
## 一个**同长度**宏（MOBILE_QUALITY_LOW ↔ MOBILE_QUALITY_MID）驱动缓存就不命中，而这
## 类错误完全静默 —— 长度一样、只有 hash 不同，肉眼读源码永远看不出来。
##
## 用法（桌面 headless 即可复现，不需要浏览器 / 不需要起服务器）：
##   Godot_v4.6.2-stable_win64.exe --headless --path Project/project-keynes \
##       --script res://tests/rendering/veg_variant_parity_probe.gd
##
## 输出：
##   [0] 源码长度与相关常量
##   [1] web_warmup_shader_codes() 每条 len:hash，并与"改动前的硬编码字面量"对照
##       （证明预热串本身没变，修的是运行期）
##   [2] tier(0/1/2) × tiled · world(null/非 null) × force 全组合的前缀 len:hash
##   [3] 用浏览器实测的运行期 fp 反查它对应哪个组合（284:2668251923 命中哪一格）
##   [4] 改动后运行期 web 真正会走的格子 vs 预热清单 → 逐条 PARITY OK/FAIL
##   [5] 桌面分支回归：`_shader_quality_define_prefix()` 在非 web 上逐字节不变
##
## 真源不变量：前缀由 `ShrubLayer.web_define_prefix()` 生成，本探针直接调它，不自己
## 抄一份宏串 —— 抄出来的模型只能骗自己（这正是原来那个 bug 的成因）。

const ShrubLayerScript = preload("res://scripts/rendering/shrub_layer.gd")
const WorldDataScript = preload("res://scripts/geography/world_data.gd")

## 浏览器实测的运行期指纹（2026-10-31，进世界后 material_variant 事件）。
const OBS_RUNTIME := {
	"veg_body": "284:2668251923",
	"veg_shadow": "261:1526245626",
	"veg_family": "312:1080355568",
}
## 同一轮 warmup_plan / warmup_shader 里报出的预热指纹。
const OBS_WARMED := {
	"veg_body": "284:2751745859",
	"veg_shadow": "261:1704305450",
	"veg_family": "312:1080355568",
}

var _failures: Array[String] = []


class FakeLayout extends RefCounted:
	var mode: String = "tiled"


class FakeTiles extends RefCounted:
	var ready: bool = true
	var layout: Object = null


func _init() -> void:
	_run()
	if _failures.is_empty():
		print("\n[probe] ALL CHECKS PASSED")
		quit(0)
	else:
		print("\n[probe] FAILURES:")
		for f in _failures:
			print("  - %s" % f)
			push_error("[veg-parity] %s" % f)
		quit(1)


func _run() -> void:
	var body_code := String(ShrubLayerScript._SHADER_CODE)
	var shadow_code := String(ShrubLayerScript._SHADOW_SHADER_CODE)
	print("=== [0] source sizes ===")
	print("  _SHADER_CODE        len=%d hash=%d" % [body_code.length(), body_code.hash()])
	print("  _SHADOW_SHADER_CODE len=%d hash=%d" % [shadow_code.length(), shadow_code.hash()])
	print("  PK_WEB_ENABLE_VEG_NEAR_FORMS=%s  PK_WEB_VEG_NEAR_FULL_FORMS=%s  WEB_SHADER_QUALITY_TIER=%d" % [
		str(ShrubLayerScript.PK_WEB_ENABLE_VEG_NEAR_FORMS),
		str(ShrubLayerScript.PK_WEB_VEG_NEAR_FULL_FORMS),
		int(ShrubLayerScript.WEB_SHADER_QUALITY_TIER)])
	print("  OS.has_feature(web)=%s (probe 跑在桌面上，web 分支靠显式参数枚举)" % [
		str(OS.has_feature("web"))])

	var warm := _dump_warmup(body_code, shadow_code)
	var combos := _dump_combos()
	_reverse_lookup(combos, warm)
	_check_runtime_parity(warm, body_code, shadow_code)
	_check_desktop_bytes()
	_dump_tier_macros()


# ─── [1] 菜单期预热清单 ────────────────────────────────────────────────────
func _dump_warmup(body_code: String, shadow_code: String) -> Dictionary:
	print("\n=== [1] web_warmup_shader_codes() ===")
	var codes := ShrubLayerScript.web_warmup_shader_codes()
	var keys: Array = codes.keys()
	keys.sort()
	for key in keys:
		var code := String(codes[key])
		var label := "veg_" + String(key)
		print("  %-8s %s" % [String(key), _fp(code)])
		print("           head=%s" % code.substr(0, 88).replace("\n", "|"))
		if OBS_WARMED.has(label):
			var want := String(OBS_WARMED[label])
			var ok := want == _fp(code)
			print("           observed_warmed=%s  %s" % [want, "MATCH" if ok else "DIFF"])
			if not ok:
				_failures.append("预热 %s fp 与浏览器记录不符：%s != %s" % [label, _fp(code), want])

	# 改动前的硬编码字面量：证明"预热串本身没变"，变的是运行期。
	print("  --- 改动前的手抄字面量（历史对照，应与此轮预热逐字相同） ---")
	var old_prefix := "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
	var old_near := ""
	if not ShrubLayerScript.PK_WEB_ENABLE_VEG_NEAR_FORMS:
		old_near = "#define PK_VEG_FAR_ONLY\n"
	elif not ShrubLayerScript.PK_WEB_VEG_NEAR_FULL_FORMS:
		old_near = "#define PK_VEG_NEAR_MIN\n"
	var old := {
		"body": old_prefix + old_near + body_code,
		"shadow": old_prefix + old_near + shadow_code,
		"family": old_prefix + "#define PK_VEG_FAR_ONLY\n#define DETAIL_FAMILY_BATCH\n" + body_code,
	}
	for key in old.keys():
		var same := String(old[key]) == String(codes.get(key, ""))
		print("  %-8s %s  vs new %s  %s" % [String(key), _fp(String(old[key])),
			_fp(String(codes.get(key, ""))), "IDENTICAL" if same else "CHANGED"])
		if not same:
			_failures.append("预热 %s 串被改动了（本轮不应改预热字面量语义）" % String(key))
	return codes


# ─── [2] 运行期前缀全组合 ──────────────────────────────────────────────────
func _dump_combos() -> Dictionary:
	print("\n=== [2] runtime prefix combos: ShrubLayer.web_define_prefix(tier, tiled, world, force) ===")
	print("  tier tiled world force | body            | shadow          | family          | fam_shadow")
	var out := {}
	for tier in [0, 1, 2]:
		for tiled in [false, true]:
			for world_known in [false, true]:
				for force in [false, true]:
					var prefix := String(ShrubLayerScript.web_define_prefix(
						tier, tiled, world_known, force))
					var row := {
						"prefix": prefix,
						"body": _fp(prefix + String(ShrubLayerScript._SHADER_CODE)),
						"shadow": _fp(prefix + String(ShrubLayerScript._SHADOW_SHADER_CODE)),
						"family": _fp(prefix + "#define DETAIL_FAMILY_BATCH\n"
							+ String(ShrubLayerScript._SHADER_CODE)),
						"family_shadow": _fp(prefix + "#define DETAIL_FAMILY_BATCH\n"
							+ String(ShrubLayerScript._SHADOW_SHADER_CODE)),
					}
					print("   %s   %-5s %-5s %-5s | %-15s | %-15s | %-15s | %s" % [
						str(tier), str(tiled), str(world_known), str(force),
						row["body"], row["shadow"], row["family"], row["family_shadow"]])
					out[_combo_key(tier, tiled, world_known, force)] = row
	return out


# ─── [3] 反查：浏览器实测 fp 对应哪个组合 ───────────────────────────────────
func _reverse_lookup(combos: Dictionary, warm: Dictionary) -> void:
	print("\n=== [3] reverse lookup (browser-observed fps) ===")
	for label in OBS_RUNTIME.keys():
		var want := String(OBS_RUNTIME[label])
		var pass_key := String(label).substr(4)  # veg_body -> body
		var hits: Array = []
		for key in combos.keys():
			if String(combos[key][pass_key]) == want:
				hits.append(key)
		print("  %s runtime fp=%s (%s)" % [String(label), want,
			"== warmed" if want == String(OBS_WARMED[label]) else "!= warmed"])
		if hits.is_empty():
			print("     no combo matches → 差异不在前缀里（源码本身不同）")
			_failures.append("%s 的运行期 fp %s 无法由任何前缀组合复现" % [String(label), want])
		for key in hits:
			print("     <- %s  prefix=%s" % [String(key),
				String(combos[key]["prefix"]).replace("\n", "|")])
		var warm_fp := _fp(String(warm.get(pass_key, "")))
		var warm_hits: Array = []
		for key in combos.keys():
			if String(combos[key][pass_key]) == warm_fp:
				warm_hits.append(key)
		print("     预热那一份 fp=%s <- %s" % [warm_fp,
			", ".join(warm_hits) if not warm_hits.is_empty() else "NO COMBO"])


# ─── [4] 改动后：运行期真正走的格子 == 预热清单 ─────────────────────────────
func _check_runtime_parity(warm: Dictionary, body_code: String, shadow_code: String) -> void:
	print("\n=== [4] post-fix runtime cells vs warmup plan ===")
	var tier := int(ShrubLayerScript.WEB_SHADER_QUALITY_TIER)
	var tiled := false  # web: map_baker 把 visual_tiles 置 null → 恒 false
	# 运行期会编的三格（web）：
	#   _ready() 早编：world=null   → world_known=false
	#   setup() 之后 ：world!=null  → world_known=true
	#   家族批次材质：configure() 时 world 已就绪；force 取决于 PK_WEB_ENABLE_VEG_NEAR_FORMS
	var expect := {
		"body": web_prefix(tier, tiled, false) + body_code,
		"shadow": web_prefix(tier, tiled, false) + shadow_code,
		"body_setup": web_prefix(tier, tiled, true) + body_code,
		"shadow_setup": web_prefix(tier, tiled, true) + shadow_code,
		"family": web_prefix(tier, tiled, true,
			bool(ShrubLayerScript.PK_WEB_ENABLE_VEG_NEAR_FORMS)) + "#define DETAIL_FAMILY_BATCH\n"
			+ body_code,
	}
	# 去重后的 label 关系：若 body 与 body_setup 相同，运行期两份都会命中同一个预热项。
	for key in ["body", "shadow", "body_setup", "shadow_setup", "family"]:
		var code := String(expect[key])
		var fp := _fp(code)
		var matched: Array = []
		for wkey in warm.keys():
			if String(warm[wkey]) == code:
				matched.append("veg_" + String(wkey))
		var status := "PARITY OK  (warmed as %s)" % ", ".join(matched) \
			if not matched.is_empty() else "MISS — 这一格没有预热"
		print("  %-12s fp=%s  %s" % [key, fp, status])
		if matched.is_empty():
			_failures.append("运行期格子 %s fp=%s 不在预热清单里" % [key, fp])
	# 交叉核对：早编格与 setup 格是否同一份（决定是否需要两个 label）。
	var early_body := _fp(String(expect["body"]))
	var setup_body := _fp(String(expect["body_setup"]))
	print("  early vs setup body: %s (%s)" % [early_body,
		"IDENTICAL → 只需预热一份" if early_body == setup_body else "DIFFER → 两份都必须预热"])


# ─── [5] 桌面分支回归：非 web 前缀逐字节不变 ────────────────────────────────
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


# ─── [6] 同长不同 hash 的直观证据 ───────────────────────────────────────────
func _dump_tier_macros() -> void:
	print("\n=== [6] tier macros: LOW vs MID (same length, different hash) ===")
	for tier in [0, 1, 2]:
		var s := String(ShrubLayerScript.quality_tier_defines(tier))
		print("  tier=%d len=%d hash=%d  %s" % [tier, s.length(), s.hash(),
			s.replace("\n", "|")])


func web_prefix(tier: int, tiled: bool, world_known: bool, force: bool = false) -> String:
	return String(ShrubLayerScript.web_define_prefix(tier, tiled, world_known, force))


func _fp(code: String) -> String:
	return "%d:%d" % [code.length(), code.hash()]


func _combo_key(tier: int, tiled: bool, world_known: bool, force: bool) -> String:
	return "tier=%d tiled=%s world=%s force=%s" % [
		tier, "T" if tiled else "F", "ne" if world_known else "null", "T" if force else "F"]
