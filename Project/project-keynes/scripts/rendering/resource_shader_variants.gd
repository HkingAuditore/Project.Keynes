extends RefCounted

## Single source for resource runtime and menu warmup shader variants.

const MAP_VISUAL_TILED_DEFINE := "#define MAP_VISUAL_TILED\n"

const WEB_MIN_QUALITY_DEFINE := "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n"

const WEB_MIN_DEFINE := "#define PK_WEB_RESOURCE_MIN\n"

const WEB_PASS_SURFACE_DEFINE := "#define PK_RES_WEB_PASS_SURFACE\n"

const WEB_PASS_GEOLOGY_DEFINE := "#define PK_RES_WEB_PASS_GEOLOGY\n"

const RESOURCE_SHADER = preload("res://shaders/resource_impostor.gdshader")

static func web_min_active() -> bool:
	return DCFeatureFlags.is_compatibility_renderer()


static func shader_variant_prefix(tiled: bool, cloud_shadow_direct: bool = false) -> String:
	var prefix := MAP_VISUAL_TILED_DEFINE if tiled else ""
	if web_min_active():
		prefix += WEB_MIN_QUALITY_DEFINE + WEB_MIN_DEFINE + WEB_PASS_SURFACE_DEFINE
	if cloud_shadow_direct:
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	return prefix


static func geology_variant_prefix(tiled: bool, cloud_shadow_direct: bool = false) -> String:
	var prefix := MAP_VISUAL_TILED_DEFINE if tiled else ""
	if web_min_active():
		prefix += WEB_MIN_QUALITY_DEFINE + WEB_MIN_DEFINE + WEB_PASS_GEOLOGY_DEFINE
	if cloud_shadow_direct:
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	return prefix


static func warmup_prefix() -> String:
	return shader_variant_prefix(false) if web_min_active() else ""


static func geology_warmup_prefix() -> String:
	return geology_variant_prefix(false) if web_min_active() else ""


static func compose_shader_code(source: Shader) -> String:
	if source == null:
		return ""
	return warmup_prefix() + source.code


static func web_warmup_shader_codes() -> Dictionary:
	if not web_min_active():
		return {}
	var source := RESOURCE_SHADER
	if source == null:
		return {}
	var body := String(source.code)
	return {
		"resource_impostor": warmup_prefix() + body,
		"resource_impostor_geology": geology_warmup_prefix() + body,
	}
