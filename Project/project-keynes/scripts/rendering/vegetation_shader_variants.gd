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


static func web_warmup_shader_codes() -> Dictionary:
	# [2026-10-31 修正 1] 这里原来硬编码 `#define MAP_VISUAL_TILED`，注释说"Compatibility
	# 渲染器在 web 上强制 tiled"——**这是错的**：map_baker 在 web 上直接把 visual_tiles
	# 置 null（`map_baker.gd` 的 web 分支），运行期 `_visual_tiles_active()` 恒 false。
	#
	# [2026-10-31 修正 2 · 同长不同 hash] 前缀以前是**手抄**的档位串：
	#   "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n" + near
	# 手抄的是 LOW，而运行期 `_shader_quality_define_prefix()` 读 `_mobile_quality_tier`
	# ——它在 `_ready()` 早编时还是初值 1(MID)。LOW / MID 两条宏串长度完全相同
	# （各 27 字节 ×2 = 54 字节，`#define <18 字符宏>` 换行）、内容不同，于是预热与
	# 运行期 fp 长度一样、hash 不一样，驱动缓存必然不命中
	# （实测 veg_body 预热 284:2751745859 / 运行期 284:2668251923）。
	# 现在：web 档位在 `_shader_quality_define_prefix()` 里钉死 LOW
	# （`WEB_SHADER_QUALITY_TIER`），而这里的源码也由**同一个** `web_define_prefix()`
	# 生成 —— 两边不再有第二份手抄串可以漂移。
	#
	# 要给哪几格：运行期会编 **两份** body/shadow —— `_ready()` 早编那一次
	# （`_world == null`）和 `setup()` 之后那一次（`_world != null`）。现在
	# 近景 form 已打开，两格都必须预热（label 用 body / body_setup）。
	#
	# tiled=false 是 web 上的运行期真值（见修正 1）；若哪天 web 也走 visual_tiles，
	# 这里必须跟着加一份 tiled 变体。
	var tiled := false
	var out := {}
	var high_prefix := web_define_prefix(WEB_SHADER_QUALITY_TIER, false, true, false, true)
	out["body_high"] = high_prefix + _SHADER_CODE
	out["shadow_high"] = high_prefix + _SHADOW_SHADER_CODE
	out["family_high"] = high_prefix + "#define PK_SKIP_HORIZON_SHADOWS\n#define DETAIL_FAMILY_BATCH\n" + _SHADER_CODE
	for world_known in [false, true]:
		var prefix := web_define_prefix(WEB_SHADER_QUALITY_TIER, tiled, world_known)
		var suffix := "" if not world_known else "_setup"
		_put_warmup_code(out, "body" + suffix, prefix + _SHADER_CODE)
		_put_warmup_code(out, "shadow" + suffix, prefix + _SHADOW_SHADER_CODE)
	# 家族批次材质：前缀来自 `_family_batch_define_prefix()`，再叠 `DETAIL_FAMILY_BATCH`。
	# web 且近景 form 打开、且家族批次还没上屏时它走 `_shader_quality_define_prefix(true)`
	# （档位 + FAR_ONLY）；其余情况与运行期前缀相同。configure() 建材质时 `_world`
	# 已就绪，所以取 world_known=true。
	# 这是第三份真正会被绘制的变体：以前没预热，它是在"第一次画出家族批次"那一帧
	# 真编的（`material_variant` 指纹里的 veg_family MISS）。
	var family_prefix := web_define_prefix(
		WEB_SHADER_QUALITY_TIER, tiled, true, PK_WEB_ENABLE_VEG_NEAR_FORMS)
	out["family"] = family_prefix + "#define DETAIL_FAMILY_BATCH\n" + _SHADER_CODE
	# A family can later become visible and restore its near-form program.
	# Prewarm that exact program as well as the initially suppressed one.
	if PK_WEB_ENABLE_VEG_NEAR_FORMS:
		var near_prefix := web_define_prefix(WEB_SHADER_QUALITY_TIER, tiled, true)
		_put_warmup_code(out, "family_near",
			near_prefix + "#define DETAIL_FAMILY_BATCH\n" + _SHADER_CODE)
	return out


static func _put_warmup_code(out: Dictionary, key: String, code: String) -> void:
	for existing in out.keys():
		if String(out[existing]) == code:
			return
	out[key] = code
