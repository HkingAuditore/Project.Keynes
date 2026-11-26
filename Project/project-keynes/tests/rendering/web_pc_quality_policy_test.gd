extends SceneTree

const GraphicsQualitySettings := preload("res://scripts/game/graphics_quality_settings.gd")
const GraphicsOptionsScene := preload("res://scenes/ui/graphics_quality_options.tscn")
const MobileUIScalingScript := preload("res://scripts/ui/mobile_ui_scaling.gd")
const RendererShaderWater := preload("res://scripts/rendering/renderer_shader_water.gd")
const RendererDetailLayers := preload("res://scripts/rendering/renderer_detail_layers.gd")
const ShrubScatter := preload("res://scripts/rendering/shrub/scatter.gd")
const BuildingVisualAssets := preload("res://scripts/rendering/building_visual_assets.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_platform_split()
	_check_warmup_and_shader_boot()
	_check_layer_and_shadow_policies()
	_check_graphics_options_ui()
	_check_web_hidpi_ui_scaling()
	_check_export_preset_and_downgrade_contracts()
	_cleanup_meta()
	print("web pc quality policy: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _cleanup_meta() -> void:
	for key in [DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, &"pk_web_pc_high_boot"]:
		if Engine.has_meta(key):
			Engine.remove_meta(key)
	DCFeatureFlags.reset_web_platform_cache()


func _check_platform_split() -> void:
	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, false)
	_expect("PC-Web override marks mobile_web false", not DCFeatureFlags.is_mobile_web())
	if not OS.has_feature("mobile"):
		_expect("PC-Web is not treated as a limited mobile render platform",
			not DCFeatureFlags.is_limited_render_platform())

	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, true)
	_expect("Mobile-Web override marks mobile_web true", DCFeatureFlags.is_mobile_web())
	_expect("Mobile-Web is treated as a limited render platform",
		DCFeatureFlags.is_limited_render_platform())
	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, false)


func _check_warmup_and_shader_boot() -> void:
	Engine.set_meta("pk_web_pc_high_boot", true)
	var pc_codes := WebShaderWarmup._collect_codes()
	var pc_labels := PackedStringArray()
	for entry in pc_codes:
		pc_labels.append(String(entry.get("label", "")))
	_expect("PC-Web warmup includes high terrain, water, vegetation and building shadow programs",
		pc_labels.has("world_map_high")
		and pc_labels.has("world_water_high")
		and pc_labels.has("building_shadow")
		and pc_labels.has("veg_body_high")
		and pc_labels.has("veg_shadow_high")
		and pc_labels.has("world_map")
		and pc_labels.has("world_water_web"))

	Engine.set_meta("pk_web_pc_high_boot", false)
	var mobile_codes := WebShaderWarmup._collect_codes()
	var mobile_labels := PackedStringArray()
	for entry in mobile_codes:
		mobile_labels.append(String(entry.get("label", "")))
	_expect("Mobile-Web warmup omits expensive _high programs while keeping shared shaders",
		not mobile_labels.has("world_map_high")
		and not mobile_labels.has("world_water_high")
		and not mobile_labels.has("veg_body_high")
		and mobile_labels.has("world_map")
		and mobile_labels.has("world_water_web")
		and mobile_labels.has("building_shadow"))


func _check_layer_and_shadow_policies() -> void:
	var renderer := HexRenderer.new()
	var shrub := ShrubLayer.new()
	var cloud := CloudShadowField.new()
	var trade := TradeActivityLayer.new()
	var military := MilitaryArmyTokenLayer.new()

	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, false)
	if not OS.has_feature("mobile"):
		_expect("PC-Web keeps all vegetation detail layers",
			not RendererDetailLayers._platform_limited_vegetation_render(renderer))
		_expect("PC-Web uses desktop vegetation scatter caps",
			not ShrubScatter._limited_platform_density_tier(shrub))
	cloud._visual_quality = 2
	cloud._mobile_tier = "MOBILE_QUALITY_LOW"
	_expect("PC-Web high cloud shadow uses full strength on composite pass",
		is_equal_approx(cloud._strength_for_quality(), CloudShadowField.CLOUD_SHADOW_STRENGTH_HIGH) \
		or (not OS.has_feature("web") and is_equal_approx(cloud._strength_for_quality(), CloudShadowField.CLOUD_SHADOW_STRENGTH_LOW)))
	_expect("PC-Web high cloud shadow field resolution is 1024x512",
		CloudShadowField.resolution_for_quality(2, DCFeatureFlags.is_limited_render_platform()) == Vector2i(1024, 512))
	trade.set_quality(2)
	_expect("PC-Web high trade layer uses full desktop caps", not trade._low_quality())
	_expect("PC-Web disables building min shader cut", not BuildingVisualAssets.web_building_min_active())

	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, true)
	_expect("Mobile-Web trims vegetation detail layers",
		RendererDetailLayers._platform_limited_vegetation_render(renderer))
	_expect("Mobile-Web uses mobile vegetation scatter caps",
		ShrubScatter._limited_platform_density_tier(shrub))
	_expect("Mobile-Web cloud shadow field resolution drops to 256x128",
		CloudShadowField.resolution_for_quality(2, DCFeatureFlags.is_limited_render_platform()) == Vector2i(256, 128))
	_expect("Mobile-Web trade layer uses low caps", trade._low_quality())

	military.free()
	trade.free()
	cloud.free()
	shrub.free()
	renderer.free()
	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, false)


func _check_graphics_options_ui() -> void:
	var options := GraphicsOptionsScene.instantiate()
	root.add_child(options)
	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, false)
	options.configure({})
	var preset := options.get_node_or_null("RenderQuality") as OptionButton
	var map_scale := options.get_node_or_null("MapRenderScale") as OptionButton
	var cloud := options.get_node_or_null("CloudShadow") as OptionButton
	_expect("graphics options expose custom preset and detail fields on all platforms",
		preset != null and preset.item_count == 5 and map_scale != null and cloud != null)
	if map_scale != null and cloud != null and not OS.has_feature("mobile"):
		_expect("PC-Web auto defaults to 100% map render scale and cloud shadow enabled",
			int(map_scale.get_selected_metadata()) == 100 and bool(cloud.get_selected_metadata()))

	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, true)
	options.configure({})
	if map_scale != null and cloud != null:
		_expect("Mobile-Web auto defaults to 75% map render scale and cloud shadow disabled",
			int(map_scale.get_selected_metadata()) == 75 and not bool(cloud.get_selected_metadata()))
	options.free()
	Engine.set_meta(DCFeatureFlags.WEB_MOBILE_OVERRIDE_META, false)


func _check_web_hidpi_ui_scaling() -> void:
	var scaling := MobileUIScalingScript.new()
	root.add_child(scaling)
	var prev_size := DisplayServer.window_get_size()
	var prev_mode := root.content_scale_mode
	var prev_factor := root.content_scale_factor

	# Refuse invalid/negative web_dpr overrides by falling back cleanly.
	scaling.set_qa_override({"profile": "desktop", "web_dpr": -2.0})
	_expect("negative web_dpr override is refused and falls back to 1.0",
		is_equal_approx(scaling._resolve_web_dpr(), 1.0))

	# Refuse runaway web_dpr > 4.0 by clamping.
	scaling.set_qa_override({"profile": "desktop", "web_dpr": 9.0})
	_expect("excessive web_dpr override is clamped to 4.0",
		is_equal_approx(scaling._resolve_web_dpr(), 4.0))

	# Verify fit_cap math directly against window size: never crushes logical viewport below 1600x960.
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		win = Vector2i(1600, 960)
	scaling.set_qa_override({"profile": "desktop", "web_dpr": 2.0})
	scaling.configure(100)
	var expected_cap := maxf(1.0, minf(float(win.x) / 1600.0, float(win.y) / 960.0))
	var expected_scale := clampf(minf(2.0, expected_cap), 1.0, 4.0)
	_expect("HiDPI desktop-web device_scale matches fit-capped DPR without shrinking below 1600x960",
		is_equal_approx(scaling.total_scale(), expected_scale)
		and root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED)

	scaling.clear_qa_override()
	scaling.free()
	root.content_scale_mode = prev_mode
	root.content_scale_factor = prev_factor
	if prev_size.x > 0 and prev_size.y > 0 and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(prev_size)


func _check_export_preset_and_downgrade_contracts() -> void:
	var preset_text := FileAccess.get_file_as_string("res://export_presets.cfg")
	var web_idx := preset_text.find("name=\"Web\"")
	_expect("Web export preset exists", web_idx >= 0)
	if web_idx >= 0:
		var next_preset := preset_text.find("[preset.3]", web_idx)
		var web_block := preset_text.substr(web_idx,
			(next_preset - web_idx) if next_preset > web_idx else -1)
		_expect("Web preset ships 1024 prebaked terrain materials",
			not web_block.contains("assets/textures/loading_prebaked_v1/material_1024_*"))
		_expect("Web preset configures adaptive PC-Web HiDPI (max 2.0) and Mobile-Web DPR=1",
			web_block.contains("[pk-web-dpi-policy]")
			and web_block.contains("window.__pkIsMobileWeb")
			and web_block.contains("2.0"))

	var downgrade_py := FileAccess.get_file_as_string("res://../../tools/web_tex_downgrade.py")
	if downgrade_py.is_empty():
		var abs_py := ProjectSettings.globalize_path("res://").path_join("../../tools/web_tex_downgrade.py").simplify_path()
		downgrade_py = FileAccess.get_file_as_string(abs_py)
	_expect("web_tex_downgrade.py preserves full-size terrain materials and map sprites by default",
		downgrade_py.contains("RES_STUB_TARGETS: list[str] = []")
		and downgrade_py.contains("\"PK_WEB_RESOURCE_ART_SCALE\", 1.0")
		and downgrade_py.contains("\"PK_WEB_TRADE_VEHICLE_SCALE\", 1.0"))


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
