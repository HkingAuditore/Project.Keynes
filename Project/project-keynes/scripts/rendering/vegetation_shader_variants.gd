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
		# 回退档：只走远景 LOD（fragment 只调 vf_far），编译器把 vegetation_forms
		# 里的近景 form 函数整段丢掉。这就是"挡回 45s 卡死"的那一版行为。
		return "#define PK_VEG_FAR_ONLY\n"
	if not world_known:
		# _ready() 早编：此刻还没有 world，先给几毫秒的远景变体，把近景预算留给
		# setup()。这份同样是运行期会真编的一份，所以预热必须把它也列进去
		# （见 web_warmup_shader_codes() 的 world_known=false 那格）。
		return "#define PK_VEG_FAR_ONLY\n"
	if PK_WEB_VEG_NEAR_FULL_FORMS:
		# 全量档：与桌面同款，17 个 form 全编（仅在确认不再卡顿时打开）。
		return ""
	# 默认档：PK_VEG_NEAR_MIN，只编译阔叶/针叶/灌木/草丛 4 个主力家族，
	# 其余 form 在 fragment 里直接落到 vf_far（详见 vegetation_forms.gdshaderinc）。
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
