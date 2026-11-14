extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _world_setup_config(host) -> Dictionary:
	if not Engine.has_meta(host.WORLD_SETUP_META):
		return {}
	var raw = Engine.get_meta(host.WORLD_SETUP_META)
	if raw is Dictionary and String((raw as Dictionary).get("source", "")) == "world_setup":
		return raw as Dictionary
	return {}



func _apply_world_setup_base_config(host) -> void:
	var config = host._world_setup_config()
	if config.is_empty():
		return
	var base = config.get("base", {})
	if not (base is Dictionary):
		return
	host.map_width = clampi(int((base as Dictionary).get("map_width", host.map_width)),
		10, DCFeatureFlags.max_map_width())
	host.map_height = clampi(int((base as Dictionary).get("map_height", host.map_height)),
		8, DCFeatureFlags.max_map_height())
	host.initial_seed = max(0, int((base as Dictionary).get("initial_seed", host.initial_seed)))
	host.sea_level = clampf(float((base as Dictionary).get("sea_level", host.sea_level)), 0.1, 0.8)
	host.num_continents = clampi(int((base as Dictionary).get("num_continents", host.num_continents)), 1, 8)
	host.continent_size = clampf(float((base as Dictionary).get("continent_size", host.continent_size)), 0.2, 0.9)
	host.river_count = clampi(int((base as Dictionary).get("river_count", host.river_count)), 0, 30)
	host.generate_test_economy_data = bool((base as Dictionary).get(
		"generate_test_economy_data", host.generate_test_economy_data))
	var requested_population_scale = int((base as Dictionary).get(
		"test_economy_population_scale", host.test_economy_population_scale))
	host.test_economy_population_scale = requested_population_scale \
		if requested_population_scale in [0, 1, 10, 100, 1000] else 0
	var render = config.get("render", {})
	if render is Dictionary:
		host.render_quality_mode = clampi(int((render as Dictionary).get(
			"render_quality_mode", host.render_quality_mode
		)), -1, 2)
		if host.render_quality_mode >= 0:
			host.visual_quality = host.render_quality_mode
			host.mobile_quality_tier = host.render_quality_mode
		host.mobile_terrain_horizon_enabled = bool((render as Dictionary).get(
			"mobile_terrain_horizon_enabled", host.mobile_terrain_horizon_enabled
		))



func _default_climate_profile_path(host) -> String:
	return host.DEFAULT_CLIMATE_PROFILE_PATH



func _load_runtime_climate_profile(host) -> ClimateProfile:
	var profile_path = host._default_climate_profile_path()
	var profile = ResourceLoader.load(profile_path, "Resource") as ClimateProfile
	if profile == null and profile_path != host.DEFAULT_CLIMATE_PROFILE_PATH:
		push_warning("[WorldSetup] ClimateProfile '%s' missing; falling back to '%s'."
			% [profile_path, host.DEFAULT_CLIMATE_PROFILE_PATH])
		profile_path = host.DEFAULT_CLIMATE_PROFILE_PATH
		profile = ResourceLoader.load(profile_path, "Resource") as ClimateProfile
	if profile != null:
		profile = profile.duplicate(true) as ClimateProfile
	else:
		push_warning("[WorldSetup] default ClimateProfile missing; using in-memory defaults.")
		profile = ClimateProfile.new()
	profile.set_meta(&"source_path", profile_path)
	return profile



func _apply_runtime_climate_profile(host, generator: MapGenerator) -> void:
	if generator == null:
		return
	var profile = host._load_runtime_climate_profile()
	var config = host._world_setup_config()
	var climate_overrides: Dictionary = {}
	if not config.is_empty():
		var climate = config.get("climate", {})
		if climate is Dictionary:
			var profile_props = {}
			for prop in profile.get_property_list():
				profile_props[String(prop.get("name", ""))] = true
			for name in (climate as Dictionary).keys():
				var key = String(name)
				if not host.WORLD_SETUP_CLIMATE_FIELDS.has(key):
					continue
				if not profile_props.has(key):
					push_warning("[WorldSetup] ClimateProfile has no property '%s'; skipped." % key)
					continue
				profile.set(key, (climate as Dictionary)[name])
				climate_overrides[key] = true
	if OS.has_feature("mobile"):
		if not climate_overrides.has("native_daily_sim_stride") \
				and profile.get("native_daily_sim_stride") != null:
			profile.native_daily_sim_stride = host.MOBILE_NATIVE_DAILY_STRIDE_DAYS
		if not climate_overrides.has("native_daily_commit_lag_budget_days") \
				and profile.get("native_daily_commit_lag_budget_days") != null:
			profile.native_daily_commit_lag_budget_days = host.MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS
		if not climate_overrides.has("native_daily_sea_ice_spread_dt_cap_days") \
				and profile.get("native_daily_sea_ice_spread_dt_cap_days") != null:
			profile.native_daily_sea_ice_spread_dt_cap_days = float(host.MOBILE_NATIVE_DAILY_STRIDE_DAYS)
		if not climate_overrides.has("natural_resource_daily_stride") \
				and profile.get("natural_resource_daily_stride") != null:
			profile.natural_resource_daily_stride = maxi(
				int(profile.natural_resource_daily_stride),
				host.MOBILE_NATURAL_RESOURCE_STRIDE_DAYS
			)
		if not climate_overrides.has("dynamic_visual_atlas_upload_stride") \
				and profile.get("dynamic_visual_atlas_upload_stride") != null:
			profile.dynamic_visual_atlas_upload_stride = maxi(
				int(profile.dynamic_visual_atlas_upload_stride),
				host.MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE
			)
		if not climate_overrides.has("weather_field_advect_steps") \
				and profile.get("weather_field_advect_steps") != null:
			profile.weather_field_advect_steps = mini(
				int(profile.weather_field_advect_steps),
				host.MOBILE_WEATHER_FIELD_ADVECT_STEPS
			)
	generator.climate_profile = profile
	var split_weather = false
	if profile.get("native_daily_split_weather_node_enabled") != null:
		split_weather = bool(profile.native_daily_split_weather_node_enabled)
	var wind_period = -1
	if profile.get("ocean_daily_wind_period_ticks") != null:
		wind_period = int(profile.ocean_daily_wind_period_ticks)
	var native_stride = -1
	if profile.get("native_daily_sim_stride") != null:
		native_stride = int(profile.native_daily_sim_stride)
	var native_budget = -1
	if profile.get("native_daily_commit_lag_budget_days") != null:
		native_budget = int(profile.native_daily_commit_lag_budget_days)
	var natural_resource_stride = -1
	if profile.get("natural_resource_daily_stride") != null:
		natural_resource_stride = int(profile.natural_resource_daily_stride)
	var dynamic_visual_stride = -1
	if profile.get("dynamic_visual_atlas_upload_stride") != null:
		dynamic_visual_stride = int(profile.dynamic_visual_atlas_upload_stride)
	var weather_advect_steps = -1
	if profile.get("weather_field_advect_steps") != null:
		weather_advect_steps = int(profile.weather_field_advect_steps)
	print("[WorldSetup] ClimateProfile path=%s mobile=%s split_weather=%s wind_period=%d native_stride=%d native_budget=%d natres_stride=%d dyn_visual_stride=%d weather_advect_steps=%d"
		% [String(profile.get_meta(&"source_path", "<in-memory>")), str(OS.has_feature("mobile")),
			str(split_weather), wind_period, native_stride, native_budget,
			natural_resource_stride, dynamic_visual_stride, weather_advect_steps])



func _return_to_world_setup(host) -> void:
	host.get_tree().change_scene_to_file(host.WORLD_SETUP_SCENE_PATH)

# ─── 时间 UI 绑定 ───────────────────────────────────────────────────────


func _wire_time_ui(host) -> void:
	host._debug_btn.pressed.connect(host.toggle_debug_console)
	host._regen_btn.pressed.connect(host.regenerate_debug_map)
	host._fit_btn.pressed.connect(host.fit_debug_map)
	host._setup_btn.pressed.connect(host._return_to_world_setup)
	host._pause_btn.toggled.connect(host._on_pause_toggled)
	host._ensure_speed_preset_buttons()
	host._sync_speed_buttons()



func _ensure_speed_preset_buttons(host) -> void:
	var hbox: HBoxContainer = host._topbar_hbox()
	if hbox == null:
		return
	var insert_idx: int = host._pause_btn.get_index() + 1
	for speed_value in host.SPEED_PRESETS:
		var speed: float = float(speed_value)
		var btn: Button = host._existing_speed_button(speed)
		if btn == null:
			btn = Button.new()
			btn.name = host._speed_button_node_name(speed)
			btn.layout_mode = 2
			hbox.add_child(btn)
		hbox.move_child(btn, insert_idx)
		insert_idx += 1
		btn.text = host._speed_button_label(speed)
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(maxf(btn.custom_minimum_size.x, 48.0), maxf(btn.custom_minimum_size.y, 32.0))
		btn.pressed.connect(host._on_speed_preset_pressed.bind(speed))
		host._speed_buttons[int(speed)] = btn



func _existing_speed_button(host, speed: float) -> Button:
	if is_equal_approx(speed, 1.0):
		return host._x1_btn
	if is_equal_approx(speed, 5.0):
		return host._x5_btn
	if is_equal_approx(speed, 20.0):
		return host._x20_btn
	var hbox: HBoxContainer = host._topbar_hbox()
	if hbox == null:
		return null
	return hbox.get_node_or_null(host._speed_button_node_name(speed)) as Button



func _topbar_hbox(host) -> HBoxContainer:
	var hbox: HBoxContainer = host.get_node_or_null("UI/TopBar/HBox") as HBoxContainer
	if hbox != null:
		return hbox
	return host.get_node_or_null("UI/TopBar/MobileTopBarScroll/HBox") as HBoxContainer



static func _speed_button_node_name(host, speed: float) -> String:
	return "X%dBtn" % int(speed)



static func _speed_button_label(host, speed: float) -> String:
	return "x%d" % int(speed)



func _on_speed_preset_pressed(host, speed: float) -> void:
	host._set_speed(speed)



func _sync_speed_buttons(host) -> void:
	if host._world_clock == null:
		return
	for speed_key in host._speed_buttons.keys():
		var btn: Button = host._speed_buttons[speed_key] as Button
		if btn == null:
			continue
		btn.set_pressed_no_signal(is_equal_approx(float(speed_key), host._world_clock.speed_multiplier))


func _sync_pause_btn(host) -> void:
	host._pause_btn.set_pressed_no_signal(host._world_clock.paused)


func _set_speed(host, s: float) -> void:
	host._world_clock.set_speed(s)
	host._world_clock.pause(false)
	host._sync_pause_btn()
	host._sync_speed_buttons()
	host._sync_clock_running_to_weather_layer()

# Fast-tick perf opt (A)：速度档变更回调——按速度区间把 weather_refresh_stride
# 调成低速→1 / 中速→4 / 高速→8，让加速档位下 refresh_daily 的反馈链 + 重烘焙
# 按 stride 跳日执行，显著降低单帧热路径开销。

func _sync_clock_running_to_weather_layer(host) -> void:
	if host._renderer == null:
		return
	if host._renderer.has_method("set_clock_running"):
		host._renderer.set_clock_running(not host._world_clock.paused)
	var wl = host._renderer.get_node_or_null("WeatherLayer")
	if wl != null and wl.has_method("set_clock_running"):
		wl.set_clock_running(not host._world_clock.paused)
	var fl = host._renderer.get_node_or_null("FogOfWarLayer")
	if fl != null and fl.has_method("set_clock_running"):
		fl.set_clock_running(not host._world_clock.paused)

# ─── WorldClock 信号回调 ─────────────────────────────────────────────────

