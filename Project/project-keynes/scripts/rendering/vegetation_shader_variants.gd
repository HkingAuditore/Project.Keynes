extends RefCounted

## Constructs the identical vegetation runtime and warmup shader sources. Compilation caches remain on the layer.

const PK_WEB_ENABLE_VEG_NEAR_FORMS := true

const PK_WEB_VEG_NEAR_FULL_FORMS := false

const WEB_SHADER_QUALITY_TIER := 0

const _SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"
#define VF_CROWN_ART
#include "res://shaders/include/vegetation_impostor.gdshaderinc"
"""

const _SHADOW_SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"
#include "res://shaders/include/vegetation_shadow.gdshaderinc"
"""

static func quality_tier_defines(tier: int) -> String:
	match tier:
		0:
			return "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"
		2:
			return "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n"
		_:
			return "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n"


static func web_form_defines(world_known: bool) -> String:
	if not PK_WEB_ENABLE_VEG_NEAR_FORMS:
		# 轻量档用单张物种贴图，省去簇布局和法线采样。
		return "#define PK_VEG_FAR_ONLY\n"
	if not world_known:
		# _ready() 早编：此刻还没有 world，先给几毫秒的远景变体，把近景预算留给
		# setup()。这份同样是运行期会真编的一份，所以预热必须把它也列进去
		# （见 web_warmup_shader_codes() 的 world_known=false 那格）。
		return "#define PK_VEG_FAR_ONLY\n"
	if PK_WEB_VEG_NEAR_FULL_FORMS:
		# 完整光照档，形态沿用同一图集。
		return ""
	# 默认档：LOW 使用图集颜色和轮廓，MID/HIGH 追加法线光照。
	return "#define PK_VEG_NEAR_MIN\n"


static func web_define_prefix(tier: int, tiled: bool, world_known: bool,
		force_far_only: bool = false, pc_high: bool = false) -> String:
	var prefix := "#define MAP_VISUAL_TILED\n" if tiled else ""
	if pc_high and world_known and not force_far_only:
		# Full PC forms, 3px near LOD and analytic soft shadows; no mobile cuts.
		return prefix + "#define PK_WEB_VEGETATION\n#define PK_WEB_PC_HIGH\n"
	prefix += "#define PK_WEB_VEGETATION\n" + quality_tier_defines(tier)
	# force_far_only：调用方自己保证这份材质暂时不上屏（家族批次材质），先用最省的档。
	if force_far_only:
		return prefix + "#define PK_VEG_FAR_ONLY\n"
	return prefix + web_form_defines(world_known)


static func family_prefix(prefix: String) -> String:
	# The style LUT takes a texture slot. Release the horizon sampler for
	# visible PC forms too, including the transition out of the hidden batch.
	if prefix.contains("#define PK_WEB_PC_HIGH\n"):
		return prefix + "#define PK_SKIP_HORIZON_SHADOWS\n"
	return prefix


static func web_warmup_shader_codes() -> Dictionary:
	var out := {}
	for pc_high in [false, true]:
		for world_known in [false, true]:
			var prefix := web_define_prefix(WEB_SHADER_QUALITY_TIER, false, world_known, false, pc_high)
			var suffix := "_high" if pc_high and world_known else "_setup" if world_known else ""
			_put_warmup_code(out, "body" + suffix, prefix + _SHADER_CODE)
			_put_warmup_code(out, "shadow" + suffix, prefix + _SHADOW_SHADER_CODE)
			_put_warmup_code(out, "family_shadow" + suffix,
				prefix + "#define DETAIL_FAMILY_BATCH\n" + _SHADOW_SHADER_CODE)
			for force_far in [false, PK_WEB_ENABLE_VEG_NEAR_FORMS]:
				var batch := family_prefix(web_define_prefix(
					WEB_SHADER_QUALITY_TIER, false, world_known, force_far, pc_high))
				_put_warmup_code(out, "family" + suffix + ("_far" if force_far else ""),
					batch + "#define DETAIL_FAMILY_BATCH\n" + _SHADER_CODE)
	return out


static func _put_warmup_code(out: Dictionary, key: String, code: String) -> void:
	for existing in out.keys():
		if String(out[existing]) == code:
			return
	out[key] = code


static var _compiled_shader_variants: Dictionary = {}
static var _shader_compile_stats: Dictionary = {}
static var _shader_compile_reported: Dictionary = {}

static func _compiled_shader(code: String, pass_tag: String = "body") -> Shader:
	var cached := _compiled_shader_variants.get(code) as Shader
	if cached != null:
		return cached
	var t0_usec := Time.get_ticks_usec()
	var shader := Shader.new()
	shader.code = code
	# 运行期真实要编的那一份的指纹。和菜单期 warmup_shader 的 fp 对账，命中 = 这份
	# 已经预热过（驱动缓存里有）；MISS = 它会在游戏里编，那就是冻结帧的根因。
	WebTelemetry.note_variant("veg_" + pass_tag, code)
	_record_shader_compile(pass_tag, code, float(Time.get_ticks_usec() - t0_usec) / 1000.0)
	_compiled_shader_variants[code] = shader
	return shader


static func _record_shader_compile(pass_tag: String, code: String, elapsed_ms: float) -> void:
	var key := "%s|%d|%d" % [pass_tag, code.length(), code.hash()]
	var record: Dictionary = _shader_compile_stats.get(key, {})
	record["s"] = pass_tag
	record["ms"] = float(record.get("ms", 0.0)) + elapsed_ms
	record["n"] = int(record.get("n", 0)) + 1
	record["h"] = code.hash()
	record["l"] = code.length()
	# 档位/变体从代码本身读，避免上报时 _world / tier 已经变了。
	record["near"] = "full"
	if code.contains("#define PK_VEG_FAR_ONLY"):
		record["near"] = "far"
	elif code.contains("#define PK_VEG_NEAR_MIN"):
		record["near"] = "min"
	record["tiled"] = code.contains("#define MAP_VISUAL_TILED")
	_shader_compile_stats[key] = record




static func _bind_crown_art(mat: ShaderMaterial) -> void:
	var art := ResourceArtLibrary.shared()
	var bound := art.crown != null and art.crown_normal != null
	mat.set_shader_parameter("crown_art_bound", bound)
	if bound:
		mat.set_shader_parameter("crown_art", art.crown)
		mat.set_shader_parameter("crown_normal_art", art.crown_normal)
